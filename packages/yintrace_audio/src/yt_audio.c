// YinTrace native audio core. See yt_audio.h for the API description.
//
// Build notes:
//   * On Apple platforms this file is compiled as Objective-C through the
//     forwarder in {ios,macos}/Classes/yintrace_audio.m so that miniaudio can
//     use AVFoundation and so that yt_platform_apple.inc can be compiled.
//   * Everywhere else it is compiled as plain C (see CMakeLists.txt).

#include "yt_audio.h"
#include "yt_monitor.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

#define MA_NO_ENGINE
#define MA_NO_NODE_GRAPH
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_GENERATION
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static void yt_set_err(char* err, int32_t err_len, const char* msg) {
  if (err == NULL || err_len <= 0) return;
  size_t n = strlen(msg);
  if (n >= (size_t)err_len) n = (size_t)err_len - 1;
  memcpy(err, msg, n);
  err[n] = '\0';
}

int32_t yt_api_version(void) { return YT_API_VERSION; }

void yt_free(void* ptr) { free(ptr); }

// Growable float buffer used by the decoders.
typedef struct {
  float* data;
  int64_t frames;
  int64_t capacity;  // in frames
  int32_t channels;
} yt_fbuf;

static int yt_fbuf_reserve(yt_fbuf* b, int64_t frames) {
  if (frames <= b->capacity) return 1;
  int64_t cap = b->capacity > 0 ? b->capacity : 65536;
  while (cap < frames) cap *= 2;
  float* p = (float*)realloc(b->data, (size_t)cap * (size_t)b->channels * sizeof(float));
  if (p == NULL) return 0;
  b->data = p;
  b->capacity = cap;
  return 1;
}

// Appends `n` frames with `src_channels` channels, converting to b->channels.
static int yt_fbuf_append(yt_fbuf* b, const float* src, int64_t n, int32_t src_channels) {
  if (!yt_fbuf_reserve(b, b->frames + n)) return 0;
  float* dst = b->data + b->frames * b->channels;
  if (src_channels == b->channels) {
    memcpy(dst, src, (size_t)n * (size_t)src_channels * sizeof(float));
  } else if (src_channels == 1 && b->channels == 2) {
    for (int64_t i = 0; i < n; i++) {
      dst[2 * i] = src[i];
      dst[2 * i + 1] = src[i];
    }
  } else if (src_channels >= 2 && b->channels == 1) {
    for (int64_t i = 0; i < n; i++) {
      dst[i] = 0.5f * (src[i * src_channels] + src[i * src_channels + 1]);
    }
  } else {
    // src >= 2 -> 2: keep the first two channels.
    for (int64_t i = 0; i < n; i++) {
      dst[2 * i] = src[i * src_channels];
      dst[2 * i + 1] = src[i * src_channels + 1];
    }
  }
  b->frames += n;
  return 1;
}

// ---------------------------------------------------------------------------
// Audio event log (diagnostics for test builds)
// ---------------------------------------------------------------------------

#define YT_LOG_LINES 24
#define YT_LOG_LINE 112
static ma_spinlock yt_log_lock = 0;
static char yt_log_lines[YT_LOG_LINES][YT_LOG_LINE];
static ma_uint32 yt_log_count = 0;  // lines ever added

void yt_audio_log_add(const char* line) {
  if (line == NULL) return;
  ma_spinlock_lock(&yt_log_lock);
  char* slot = yt_log_lines[yt_log_count % YT_LOG_LINES];
  size_t n = strlen(line);
  if (n >= YT_LOG_LINE) {
    n = YT_LOG_LINE - 1;
    // Cut before a UTF-8 character, not inside one.
    while (n > 0 && ((unsigned char)line[n] & 0xC0) == 0x80) n--;
  }
  memcpy(slot, line, n);
  slot[n] = '\0';
  yt_log_count++;
  ma_spinlock_unlock(&yt_log_lock);
}

int32_t yt_audio_log(char* buf, int32_t len) {
  if (buf == NULL || len <= 0) return 0;
  size_t used = 0;
  buf[0] = '\0';
  ma_spinlock_lock(&yt_log_lock);
  ma_uint32 first = yt_log_count > YT_LOG_LINES ? yt_log_count - YT_LOG_LINES : 0;
  for (ma_uint32 i = first; i < yt_log_count; i++) {
    const char* line = yt_log_lines[i % YT_LOG_LINES];
    size_t n = strlen(line);
    if (used + n + 2 > (size_t)len) break;
    memcpy(buf + used, line, n);
    used += n;
    buf[used++] = '\n';
    buf[used] = '\0';
  }
  ma_spinlock_unlock(&yt_log_lock);
  return (int32_t)used;
}

// ---------------------------------------------------------------------------
// Platform layer (Apple implementation lives in yt_platform_apple.inc)
// ---------------------------------------------------------------------------

// Route-change watching for an engine with a device (iOS: tells a lost
// headphone/Bluetooth output apart from the route reconfigurations iOS
// announces whenever a session starts playing and recording).
static void yt_platform_watch_routes(yt_engine* e);
static void yt_platform_unwatch_routes(yt_engine* e);
static int32_t yt_platform_monitor_available(void);
#if defined(__APPLE__) && defined(__OBJC__) && TARGET_OS_IOS
static void yt_update_monitor_route(yt_engine* e, int32_t available);
// The platform's own duplex device (yt_device_ios.inc) hears about
// interruptions and media services resets from the observers.
static void yt_platform_device_interrupted(yt_engine* e, int began);
static void yt_platform_device_media_reset(yt_engine* e);
#endif

#if defined(__APPLE__) && defined(__OBJC__)
#define YT_HAS_APPLE_PLATFORM 1
#include "yt_platform_apple.inc"
#else
#define YT_HAS_APPLE_PLATFORM 0
static void yt_platform_watch_routes(yt_engine* e) { (void)e; }
static void yt_platform_unwatch_routes(yt_engine* e) { (void)e; }
static int32_t yt_platform_monitor_available(void) { return 0; }
int32_t yt_mic_permission_status(void) { return 1; }
void yt_request_mic_permission(void) {}
int32_t yt_configure_session(int32_t record, int32_t measurement) {
  (void)record;
  (void)measurement;
  return 0;
}
int32_t yt_begin_latency_calibration(int32_t measurement) { return yt_configure_session(1, measurement); }
int32_t yt_end_latency_calibration(void) { return 0; }
double yt_session_latency(void) { return 0.0; }
int32_t yt_output_route(void) { return YT_OUTPUT_UNKNOWN; }
int64_t yt_available_memory(void) { return -1; }
int32_t yt_device_model(char* buf, int32_t len) {
  if (buf != NULL && len > 0) buf[0] = '\0';
  return 0;
}
int64_t yt_physical_memory(void) { return -1; }
int32_t yt_thermal_state(void) { return -1; }
int32_t yt_exclude_from_backup(const char* path) {
  (void)path;
  return 0;
}
int32_t yt_encode_m4a(const char* path, const float* data, int64_t frames,
                      int32_t sample_rate, int32_t channels, int32_t bitrate) {
  (void)path; (void)data; (void)frames; (void)sample_rate; (void)channels; (void)bitrate;
  return -1;
}
int32_t yt_share_file(const char* path) {
  (void)path;
  return -1;
}
#endif

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

static float* yt_decode_miniaudio(const char* path, int32_t sample_rate, int32_t channels,
                                  int64_t* out_frames, char* err, int32_t err_len) {
  ma_decoder_config cfg = ma_decoder_config_init(ma_format_f32, (ma_uint32)channels, (ma_uint32)sample_rate);
  cfg.resampling.algorithm = ma_resample_algorithm_linear;
  cfg.resampling.linear.lpfOrder = 8;
  ma_decoder dec;
  ma_result r = ma_decoder_init_file(path, &cfg, &dec);
  if (r != MA_SUCCESS) {
    char msg[256];
    snprintf(msg, sizeof(msg), "unsupported or unreadable audio file (miniaudio error %d)", (int)r);
    yt_set_err(err, err_len, msg);
    return NULL;
  }
  yt_fbuf b = {NULL, 0, 0, channels};
  ma_uint64 total = 0;
  if (ma_decoder_get_length_in_pcm_frames(&dec, &total) == MA_SUCCESS && total > 0) {
    yt_fbuf_reserve(&b, (int64_t)total + 4096);
  }
  const ma_uint64 chunk = 16384;
  float* tmp = (float*)malloc((size_t)chunk * (size_t)channels * sizeof(float));
  if (tmp == NULL) {
    ma_decoder_uninit(&dec);
    free(b.data);
    yt_set_err(err, err_len, "out of memory");
    return NULL;
  }
  for (;;) {
    ma_uint64 got = 0;
    r = ma_decoder_read_pcm_frames(&dec, tmp, chunk, &got);
    if (got > 0 && !yt_fbuf_append(&b, tmp, (int64_t)got, channels)) {
      free(tmp);
      ma_decoder_uninit(&dec);
      free(b.data);
      yt_set_err(err, err_len, "out of memory");
      return NULL;
    }
    if (got < chunk || r != MA_SUCCESS) break;
  }
  free(tmp);
  ma_decoder_uninit(&dec);
  if (b.frames == 0) {
    free(b.data);
    yt_set_err(err, err_len, "file contains no audio frames");
    return NULL;
  }
  *out_frames = b.frames;
  return b.data;
}

float* yt_decode_file(const char* path, int32_t sample_rate, int32_t channels,
                      int64_t* out_frames, char* err, int32_t err_len) {
  if (out_frames) *out_frames = 0;
  if (path == NULL || out_frames == NULL || sample_rate < 8000 || (channels != 1 && channels != 2)) {
    yt_set_err(err, err_len, "invalid arguments");
    return NULL;
  }
#if YT_HAS_APPLE_PLATFORM
  {
    float* p = yt_apple_decode(path, sample_rate, channels, out_frames, err, err_len);
    if (p != NULL) return p;
  }
#endif
  return yt_decode_miniaudio(path, sample_rate, channels, out_frames, err, err_len);
}

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

#define YT_CAP_RING_FRAMES (1 << 18) /* ~5.9 s at 44.1 kHz */
#define YT_CAP_META_SLOTS 4096
#define YT_CAP_MAX_BLOCK 4096

typedef struct {
  int16_t* data;  // interleaved
  int64_t frames;
  int32_t channels;
  int64_t offset;  // song frame of the first frame
} yt_track;

typedef struct {
  ma_int64 song_frame;
  ma_int64 clock_frame;
  ma_uint64 sample_start;  // absolute index into the capture sample stream
  ma_int32 frames;
  ma_int32 flags;
} yt_cap_block;

struct yt_engine {
  ma_context context;
  ma_device device;
  int has_context;
  int has_device;
  // A duplex device run by the platform layer instead of miniaudio (iOS:
  // one RemoteIO unit, see yt_device_ios.inc); NULL otherwise.
  void* platform_device;
  // Set from start until stop is asked for, so the platform device can tell
  // a stop by the system from its own.
  volatile ma_uint32 running_requested;
  int32_t mode;
  int32_t sample_rate;
  volatile ma_uint32 audio_events;
  volatile ma_uint32 capture_suspended;
  volatile ma_uint32 stopping;

  // Track table. Guarded by `track_lock` (a try-lock on the audio thread).
  volatile ma_uint32 track_lock;
  yt_track tracks[YT_MAX_TRACKS];
  volatile float gains[YT_MAX_TRACKS];
  volatile ma_int64 length;

  volatile ma_int64 position;      // written by the audio thread only
  volatile ma_int64 seek_request;  // -1 = none
  volatile ma_int64 loop_start;
  volatile ma_int64 loop_end;
  volatile ma_uint32 playing;
  volatile ma_int64 end_count;
  volatile float monitor_gain;
  volatile ma_uint32 monitor_while_capturing;
  volatile ma_uint32 monitor_route_allowed;
  yt_monitor monitor_chain;  // what the mic goes through to be heard (audio thread)
  yt_bus_limiter bus_limiter;  // keeps tracks + monitor under full scale (audio thread)
  ma_int64 clock;  // audio thread only

  // Capture ring (single producer: audio thread, single consumer: Dart).
  float* cap_samples;
  yt_cap_block cap_meta[YT_CAP_META_SLOTS];
  volatile ma_uint64 cap_meta_write;
  volatile ma_uint64 cap_meta_read;
  volatile ma_uint64 cap_sample_write;
  volatile ma_uint64 cap_sample_read;
  volatile ma_int64 cap_overruns;
};

#if YT_HAS_APPLE_PLATFORM && TARGET_OS_IOS
// Called by the route observer, never by the real-time audio callback.
static void yt_update_monitor_route(yt_engine* e, int32_t available) {
  ma_atomic_store_32(&e->monitor_route_allowed, available ? 1 : 0);
  if (!available) ma_atomic_store_f32(&e->monitor_gain, 0.0f);
}
#endif

#if YT_HAS_APPLE_PLATFORM && TARGET_OS_IOS
#include "yt_device_ios.inc"
#else
// Elsewhere miniaudio runs every device.
static int yt_platform_device_init(yt_engine* e) {
  (void)e;
  return 0;
}
static int32_t yt_platform_device_start(yt_engine* e) {
  (void)e;
  return -2;
}
static int32_t yt_platform_device_stop(yt_engine* e) {
  (void)e;
  return -2;
}
static void yt_platform_device_uninit(yt_engine* e) { (void)e; }
static int32_t yt_platform_device_period_frames(yt_engine* e) {
  (void)e;
  return 0;
}
static void yt_platform_device_maintain(yt_engine* e) { (void)e; }
#endif

static void yt_track_lock(yt_engine* e) {
  while (ma_atomic_exchange_32(&e->track_lock, 1) != 0) {
    ma_yield();
  }
}

static void yt_track_unlock(yt_engine* e) { ma_atomic_store_32(&e->track_lock, 0); }

static void yt_push_capture_block(yt_engine* e, const float* in, ma_uint32 n,
                                  ma_int64 song_frame, ma_int64 clock_frame, ma_int32 flags) {
  ma_uint64 mw = e->cap_meta_write;
  ma_uint64 mr = ma_atomic_load_64(&e->cap_meta_read);
  if (mw - mr >= YT_CAP_META_SLOTS) {
    ma_atomic_fetch_add_64((volatile ma_uint64*)&e->cap_overruns, 1);
    return;
  }
  ma_uint64 sw = e->cap_sample_write;
  ma_uint64 sr = ma_atomic_load_64(&e->cap_sample_read);
  if (sw + n - sr > YT_CAP_RING_FRAMES) {
    ma_atomic_fetch_add_64((volatile ma_uint64*)&e->cap_overruns, 1);
    return;
  }
  ma_uint64 idx = sw % YT_CAP_RING_FRAMES;
  ma_uint64 first = YT_CAP_RING_FRAMES - idx;
  if (first > n) first = n;
  memcpy(e->cap_samples + idx, in, (size_t)first * sizeof(float));
  if (first < n) memcpy(e->cap_samples, in + first, (size_t)(n - first) * sizeof(float));

  yt_cap_block* b = &e->cap_meta[mw % YT_CAP_META_SLOTS];
  b->song_frame = song_frame;
  b->clock_frame = clock_frame;
  b->sample_start = sw;
  b->frames = (ma_int32)n;
  b->flags = flags;
  ma_atomic_store_64(&e->cap_sample_write, sw + n);
  ma_atomic_store_64(&e->cap_meta_write, mw + 1);
}

static void yt_push_capture(yt_engine* e, const float* in, ma_uint32 n, ma_int64 song_frame,
                            ma_int64 clock_frame, ma_int32 flags) {
  ma_uint32 off = 0;
  while (off < n) {
    ma_uint32 m = n - off;
    if (m > YT_CAP_MAX_BLOCK) m = YT_CAP_MAX_BLOCK;
    ma_int64 song = (flags & YT_CAPTURE_FLAG_PLAYING) ? song_frame + off : song_frame;
    yt_push_capture_block(e, in + off, m, song, clock_frame + off, flags);
    off += m;
  }
}

static void yt_mix_tracks(yt_engine* e, float* out, ma_int64 pos, ma_uint32 n) {
  for (int t = 0; t < YT_MAX_TRACKS; t++) {
    const yt_track* tr = &e->tracks[t];
    if (tr->data == NULL) continue;
    float g = ma_atomic_load_f32(&e->gains[t]);
    if (g == 0.0f) continue;
    ma_int64 start = pos - tr->offset;  // track frame under the first output frame
    ma_uint32 skip = 0;
    if (start < 0) {
      if (-start >= (ma_int64)n) continue;
      skip = (ma_uint32)(-start);
      start = 0;
    }
    if (start >= tr->frames) continue;
    ma_int64 avail = tr->frames - start;
    ma_uint32 m = n - skip;
    if (avail < (ma_int64)m) m = (ma_uint32)avail;
    const float k = g / 32768.0f;
    float* o = out + (size_t)skip * 2;
    if (tr->channels == 1) {
      const int16_t* src = tr->data + start;
      for (ma_uint32 i = 0; i < m; i++) {
        float s = (float)src[i] * k;
        o[2 * i] += s;
        o[2 * i + 1] += s;
      }
    } else {
      const int16_t* src = tr->data + start * 2;
      for (ma_uint32 i = 0; i < m; i++) {
        o[2 * i] += (float)src[2 * i] * k;
        o[2 * i + 1] += (float)src[2 * i + 1] * k;
      }
    }
  }
}

void yt_engine_render(yt_engine* e, float* out, const float* in, int32_t frames) {
  if (e == NULL || frames <= 0) return;
  const ma_uint32 frame_count = (ma_uint32)frames;
  if (ma_atomic_load_32(&e->capture_suspended)) {
    if (out) memset(out, 0, (size_t)frames * 2 * sizeof(float));
    return;
  }

  // Read the playback state first so a seek queued before play is applied
  // before the first resumed buffer is mixed.
  ma_bool32 playing = ma_atomic_load_32(&e->playing) != 0;
  ma_int64 seek = ma_atomic_exchange_i64(&e->seek_request, -1);
  ma_int64 pos = e->position;
  if (seek >= 0) pos = seek;
  const ma_int64 loop_start = ma_atomic_load_i64(&e->loop_start);
  const ma_int64 loop_end = ma_atomic_load_i64(&e->loop_end);
  const ma_bool32 looping = loop_end > loop_start && loop_start >= 0;
  const float monitor = ma_atomic_load_f32(&e->monitor_gain);
  const ma_bool32 monitor_capture = ma_atomic_load_32(&e->monitor_while_capturing) != 0;
  ma_bool32 ended = MA_FALSE;

  if (out != NULL) memset(out, 0, (size_t)frame_count * 2 * sizeof(float));

  const ma_bool32 have_tracks = ma_atomic_exchange_32(&e->track_lock, 1) == 0;
  const ma_int64 length = ma_atomic_load_i64(&e->length);

  ma_uint32 done = 0;
  while (done < frame_count) {
    ma_uint32 seg = frame_count - done;
    ma_bool32 seg_playing = MA_FALSE;
    if (playing) {
      if (looping && pos >= loop_end) pos = loop_start;
      ma_int64 limit = looping ? loop_end : length;
      if (pos < limit) {
        ma_int64 avail = limit - pos;
        if ((ma_int64)seg > avail) seg = (ma_uint32)avail;
        seg_playing = MA_TRUE;
      } else if (!looping) {
        playing = MA_FALSE;
        ended = MA_TRUE;
      }
    }
    if (seg_playing && out != NULL && have_tracks) {
      yt_mix_tracks(e, out + (size_t)done * 2, pos, seg);
    }
    if (in != NULL) {
      yt_push_capture(e, in + done, seg, pos, e->clock + done,
                      seg_playing ? YT_CAPTURE_FLAG_PLAYING : 0);
    }
    // The capture above stays the dry mic; only what is heard is processed.
    if (in != NULL && out != NULL && (seg_playing || monitor_capture) && monitor > 0.0f &&
        ma_atomic_load_32(&e->monitor_route_allowed)) {
      yt_monitor* chain = &e->monitor_chain;
      // Switched off and on again between two callbacks: start clean anyway.
      if (ma_atomic_exchange_32(&chain->reset_pending, 0)) yt_monitor_idle(chain);
      yt_monitor_process(chain, in + done, out + (size_t)done * 2, seg, monitor);
    } else {
      // Muted at once; it fades in from a clean state when it is heard again.
      yt_monitor_idle(&e->monitor_chain);
    }
    if (seg_playing) pos += seg;
    done += seg;
  }

  if (have_tracks) yt_track_unlock(e);

  if (out != NULL) {
    // Loud tracks plus the monitor: limited to YT_BUS_CEILING (untouched
    // below it), then the soft clip as a last resort, exactly transparent up
    // to YT_SOFT_CLIP_KNEE.
    yt_bus_limiter_process(&e->bus_limiter, out, frame_count);
    for (ma_uint32 i = 0; i < frame_count * 2; i++) out[i] = yt_soft_clip(out[i]);
  }

  ma_atomic_store_i64(&e->position, pos);
  e->clock += frame_count;
  if (ended) {
    ma_atomic_store_32(&e->playing, 0);
    ma_atomic_fetch_add_64((volatile ma_uint64*)&e->end_count, 1);
  }
}

static void yt_data_callback(ma_device* device, void* output, const void* input, ma_uint32 frame_count) {
  yt_engine* e = (yt_engine*)device->pUserData;
  yt_engine_render(e, (float*)output, (const float*)input, (int32_t)frame_count);
}

// miniaudio already owns AVAudioSession interruption/route observers. React
// to its notifications without restarting/uninitializing inside the callback.
void yt_engine_signal_audio_event(yt_engine* e, int32_t events) {
  if (!e) return;
  if (events & (YT_EVENTS_SILENCING | YT_EVENT_ROUTE_CHANGED)) {
    ma_atomic_store_f32(&e->monitor_gain, 0.0f);
  }
  if (events & YT_EVENTS_SILENCING) {
    ma_atomic_store_32(&e->playing, 0);
    ma_atomic_store_32(&e->capture_suspended, 1);
  }
  // A counter/bitset with CAS: callbacks may arrive on different threads.
  ma_uint32 before;
  do { before = ma_atomic_load_32(&e->audio_events); }
  while (ma_atomic_compare_and_swap_32(&e->audio_events, before, before | (ma_uint32)events) != before);
}

int32_t yt_engine_take_audio_events(yt_engine* e) {
  if (e == NULL) return 0;
  // The control thread polls this every UI frame: the platform device
  // rebuilds itself here when it has to (yt_device_ios.inc).
  if (e->platform_device != NULL) yt_platform_device_maintain(e);
  return (int32_t)ma_atomic_exchange_32(&e->audio_events, 0);
}

static void yt_device_notification(const ma_device_notification* notification) {
  yt_engine* e = (yt_engine*)notification->pDevice->pUserData;
  switch (notification->type) {
    case ma_device_notification_type_interruption_began:
      yt_audio_log_add("device: interruption began");
      yt_engine_signal_audio_event(e, YT_EVENT_STOPPED);
      break;
    case ma_device_notification_type_rerouted:
      // miniaudio reports every AVAudioSession route change, including the
      // ones iOS announces when playback and recording start. The audio unit
      // keeps running through them; yt_platform_watch_routes() reports the
      // ones that mean a lost output (YT_EVENT_DEVICE_LOST).
      yt_engine_signal_audio_event(e, YT_EVENT_ROUTE_CHANGED);
      break;
    case ma_device_notification_type_stopped:
      if (!ma_atomic_load_32(&e->stopping)) {
        yt_audio_log_add("device: stopped by the system");
        yt_engine_signal_audio_event(e, YT_EVENT_STOPPED);
      }
      break;
    case ma_device_notification_type_interruption_ended:
      yt_engine_signal_audio_event(e, YT_EVENT_INTERRUPTION_ENDED);
      break;
    default: break;
  }
}

yt_engine* yt_engine_create(int32_t sample_rate, int32_t mode, int32_t use_null_backend,
                            char* err, int32_t err_len) {
  if (sample_rate < 8000 || mode < YT_MODE_PLAYBACK || mode > YT_MODE_OFFLINE) {
    yt_set_err(err, err_len, "invalid arguments");
    return NULL;
  }
  yt_engine* e = (yt_engine*)calloc(1, sizeof(yt_engine));
  if (e == NULL) {
    yt_set_err(err, err_len, "out of memory");
    return NULL;
  }
  e->mode = mode;
  e->sample_rate = sample_rate;
  e->monitor_route_allowed = mode == YT_MODE_OFFLINE ? 1 : 0;
  e->seek_request = -1;
  e->loop_start = 0;
  e->loop_end = 0;
  for (int i = 0; i < YT_MAX_TRACKS; i++) e->gains[i] = 1.0f;
  yt_monitor_init(&e->monitor_chain, (float)sample_rate);
  yt_bus_limiter_init(&e->bus_limiter, (float)sample_rate);
  e->cap_samples = (float*)calloc(YT_CAP_RING_FRAMES, sizeof(float));
  if (e->cap_samples == NULL) {
    free(e);
    yt_set_err(err, err_len, "out of memory");
    return NULL;
  }
  if (mode == YT_MODE_OFFLINE) return e;

  // Where the platform has a lower-latency duplex device, it runs practice
  // (the live monitor hears the microphone in the same cycle); miniaudio is
  // the fallback when it cannot be set up.
  if (mode == YT_MODE_DUPLEX && !use_null_backend && yt_platform_device_init(e)) {
    yt_platform_watch_routes(e);
    return e;
  }

  ma_context_config ctx_cfg = ma_context_config_init();
  // The audio session is configured by yt_configure_session().
  ctx_cfg.coreaudio.sessionCategory = ma_ios_session_category_none;
  ctx_cfg.coreaudio.noAudioSessionActivate = MA_TRUE;
  ctx_cfg.coreaudio.noAudioSessionDeactivate = MA_TRUE;
  ma_backend null_backend[1] = {ma_backend_null};
  ma_result r = ma_context_init(use_null_backend ? null_backend : NULL, use_null_backend ? 1 : 0,
                                &ctx_cfg, &e->context);
  if (r != MA_SUCCESS) {
    char msg[128];
    snprintf(msg, sizeof(msg), "audio context init failed (%d)", (int)r);
    yt_set_err(err, err_len, msg);
    free(e->cap_samples);
    free(e);
    return NULL;
  }
  e->has_context = 1;

  ma_device_type type = ma_device_type_playback;
  if (mode == YT_MODE_DUPLEX) type = ma_device_type_duplex;
  if (mode == YT_MODE_CAPTURE) type = ma_device_type_capture;
  ma_device_config cfg = ma_device_config_init(type);
  cfg.sampleRate = (ma_uint32)sample_rate;
  cfg.playback.format = ma_format_f32;
  cfg.playback.channels = 2;
  cfg.capture.format = ma_format_f32;
  cfg.capture.channels = 1;
  cfg.performanceProfile = ma_performance_profile_low_latency;
  // Recording (practice, the free tuner) asks for short periods: the live
  // monitor goes through one capture and one playback period. The same
  // values as yt_configure_session() keep the two from undoing each other.
  cfg.periodSizeInMilliseconds = mode == YT_MODE_PLAYBACK ? 10 : 5;
  cfg.dataCallback = yt_data_callback;
  cfg.notificationCallback = yt_device_notification;
  cfg.pUserData = e;
  r = ma_device_init(&e->context, &cfg, &e->device);
  if (r != MA_SUCCESS) {
    char msg[128];
    snprintf(msg, sizeof(msg), "audio device init failed (%d)", (int)r);
    yt_set_err(err, err_len, msg);
    ma_context_uninit(&e->context);
    free(e->cap_samples);
    free(e);
    return NULL;
  }
  e->has_device = 1;
  if (!use_null_backend) yt_platform_watch_routes(e);
  return e;
}

int32_t yt_engine_start(yt_engine* e) {
  if (e == NULL) return -1;
  ma_atomic_store_32(&e->capture_suspended, 0);
  if (e->platform_device != NULL) {
    if (yt_platform_device_start(e) == 0) return 0;
    ma_atomic_store_32(&e->capture_suspended, 1);
    return -2;
  }
  if (!e->has_device) return 0;
  if (ma_device_start(&e->device) == MA_SUCCESS) return 0;
  ma_atomic_store_32(&e->capture_suspended, 1);
  return -2;
}

int32_t yt_engine_stop(yt_engine* e) {
  if (e == NULL) return -1;
  ma_atomic_store_f32(&e->monitor_gain, 0.0f);
  ma_atomic_store_32(&e->playing, 0);
  ma_atomic_store_32(&e->capture_suspended, 1);
  if (e->platform_device != NULL) return yt_platform_device_stop(e);
  if (!e->has_device) return 0;
  ma_atomic_store_32(&e->stopping, 1);
  ma_result r = ma_device_stop(&e->device);
  ma_atomic_store_32(&e->stopping, 0);
  return r == MA_SUCCESS ? 0 : -2;
}

void yt_engine_destroy(yt_engine* e) {
  if (e == NULL) return;
  // Unconditional: a no-op for engines that never watched routes.
  yt_platform_unwatch_routes(e);
  yt_platform_device_uninit(e);
  if (e->has_device) ma_device_uninit(&e->device);
  if (e->has_context) ma_context_uninit(&e->context);
  for (int i = 0; i < YT_MAX_TRACKS; i++) free(e->tracks[i].data);
  free(e->cap_samples);
  free(e);
}

int32_t yt_engine_sample_rate(yt_engine* e) { return e ? e->sample_rate : 0; }

int32_t yt_engine_period_frames(yt_engine* e) {
  if (e == NULL) return 0;
  if (e->platform_device != NULL) return yt_platform_device_period_frames(e);
  if (!e->has_device) return 0;
  ma_uint32 p = e->device.playback.internalPeriodSizeInFrames;
  if (e->mode == YT_MODE_CAPTURE || p == 0) p = e->device.capture.internalPeriodSizeInFrames;
  // Report in engine frames (the device may run at a different rate).
  ma_uint32 dev_rate = e->mode == YT_MODE_CAPTURE ? e->device.capture.internalSampleRate
                                                  : e->device.playback.internalSampleRate;
  if (dev_rate == 0) return (int32_t)p;
  return (int32_t)((ma_uint64)p * (ma_uint64)e->sample_rate / dev_rate);
}

static void yt_recompute_length(yt_engine* e) {
  ma_int64 len = 0;
  for (int i = 0; i < YT_MAX_TRACKS; i++) {
    const yt_track* t = &e->tracks[i];
    if (t->data != NULL && t->offset + t->frames > len) len = t->offset + t->frames;
  }
  ma_atomic_store_i64(&e->length, len);
}

static void yt_install_track(yt_engine* e, int32_t slot, int16_t* data, int64_t frames, int32_t channels) {
  yt_track_lock(e);
  int16_t* old = e->tracks[slot].data;
  e->tracks[slot].data = data;
  e->tracks[slot].frames = frames;
  e->tracks[slot].channels = channels;
  e->tracks[slot].offset = 0;
  yt_recompute_length(e);
  yt_track_unlock(e);
  free(old);
}

void yt_engine_set_track_offset(yt_engine* e, int32_t slot, int64_t frame) {
  if (e == NULL || slot < 0 || slot >= YT_MAX_TRACKS) return;
  // Negative: the track's first -frame frames play before the song starts
  // (i.e. are skipped).
  yt_track_lock(e);
  e->tracks[slot].offset = frame;
  yt_recompute_length(e);
  yt_track_unlock(e);
}

static inline int16_t yt_f2s(float v) {
  float x = v * 32767.0f;
  if (x > 32767.0f) x = 32767.0f;
  if (x < -32768.0f) x = -32768.0f;
  return (int16_t)(x >= 0 ? x + 0.5f : x - 0.5f);
}

int32_t yt_engine_load_track_pcm(yt_engine* e, int32_t slot, const float* data, int64_t frames,
                                 int32_t channels) {
  if (e == NULL || slot < 0 || slot >= YT_MAX_TRACKS || data == NULL || frames <= 0 ||
      (channels != 1 && channels != 2)) {
    return -1;
  }
  size_t count = (size_t)frames * (size_t)channels;
  int16_t* pcm = (int16_t*)malloc(count * sizeof(int16_t));
  if (pcm == NULL) return -2;
  for (size_t i = 0; i < count; i++) pcm[i] = yt_f2s(data[i]);
  yt_install_track(e, slot, pcm, frames, channels);
  return 0;
}

int32_t yt_engine_load_track_file(yt_engine* e, int32_t slot, const char* path, char* err,
                                  int32_t err_len) {
  if (e == NULL || slot < 0 || slot >= YT_MAX_TRACKS || path == NULL) {
    yt_set_err(err, err_len, "invalid arguments");
    return -1;
  }
  int64_t frames = 0;
  float* pcm = yt_decode_file(path, e->sample_rate, 2, &frames, err, err_len);
  if (pcm == NULL) return -2;
  int32_t r = yt_engine_load_track_pcm(e, slot, pcm, frames, 2);
  free(pcm);
  return r;
}

void yt_engine_unload_track(yt_engine* e, int32_t slot) {
  if (e == NULL || slot < 0 || slot >= YT_MAX_TRACKS) return;
  yt_install_track(e, slot, NULL, 0, 0);
}

void yt_engine_set_track_gain(yt_engine* e, int32_t slot, float gain) {
  if (e == NULL || slot < 0 || slot >= YT_MAX_TRACKS) return;
  ma_atomic_store_f32(&e->gains[slot], gain);
}

int32_t yt_engine_monitor_available(yt_engine* e) {
  if (e == NULL) return 0;
  if (e->mode == YT_MODE_OFFLINE) return 1;
  return e->mode == YT_MODE_DUPLEX && ma_atomic_load_32(&e->monitor_route_allowed) &&
         yt_platform_monitor_available();
}

void yt_engine_set_monitor_gain(yt_engine* e, float gain) {
  if (e == NULL) return;
  if (!isfinite(gain) || gain < 0.0f || !yt_engine_monitor_available(e)) gain = 0.0f;
  if (gain > YT_MONITOR_MAX_GAIN) gain = YT_MONITOR_MAX_GAIN;
  // Off -> on (a stop or route change may have cleared it without the audio
  // thread noticing): ask for a clean start, before the gain can be seen.
  if (gain > 0.0f && ma_atomic_load_f32(&e->monitor_gain) == 0.0f) {
    ma_atomic_store_32(&e->monitor_chain.reset_pending, 1);
  }
  ma_atomic_store_f32(&e->monitor_gain, gain);
}

void yt_engine_set_monitor_while_capturing(yt_engine* e, int32_t enabled) {
  if (e == NULL) return;
  ma_atomic_store_32(&e->monitor_while_capturing, enabled ? 1 : 0);
}

void yt_engine_set_playing(yt_engine* e, int32_t playing) {
  if (e == NULL) return;
  ma_atomic_store_32(&e->playing, playing ? 1 : 0);
}

int32_t yt_engine_is_playing(yt_engine* e) { return e ? (int32_t)ma_atomic_load_32(&e->playing) : 0; }

void yt_engine_seek(yt_engine* e, int64_t frame) {
  if (e == NULL) return;
  if (frame < 0) frame = 0;
  ma_atomic_store_i64(&e->seek_request, frame);
}

int64_t yt_engine_position(yt_engine* e) {
  if (e == NULL) return 0;
  ma_int64 s = ma_atomic_load_i64(&e->seek_request);
  if (s >= 0) return s;
  return ma_atomic_load_i64(&e->position);
}

int64_t yt_engine_length(yt_engine* e) { return e ? ma_atomic_load_i64(&e->length) : 0; }

void yt_engine_set_loop(yt_engine* e, int64_t start, int64_t end) {
  if (e == NULL) return;
  if (end <= start || start < 0) {
    start = 0;
    end = 0;
  }
  // Disable first so the audio thread never sees a half-updated range.
  ma_atomic_store_i64(&e->loop_end, 0);
  ma_atomic_store_i64(&e->loop_start, start);
  ma_atomic_store_i64(&e->loop_end, end);
}

int64_t yt_engine_end_count(yt_engine* e) { return e ? ma_atomic_load_i64(&e->end_count) : 0; }

int32_t yt_engine_read_capture(yt_engine* e, float* out, int32_t max_frames, int64_t* out_song_frame,
                               int64_t* out_clock_frame, int32_t* out_flags) {
  if (e == NULL || out == NULL || max_frames < YT_CAP_MAX_BLOCK) return -1;
  ma_uint64 mr = e->cap_meta_read;
  ma_uint64 mw = ma_atomic_load_64(&e->cap_meta_write);
  if (mr == mw) return 0;
  const yt_cap_block b = e->cap_meta[mr % YT_CAP_META_SLOTS];
  ma_uint64 idx = b.sample_start % YT_CAP_RING_FRAMES;
  ma_uint64 n = (ma_uint64)b.frames;
  ma_uint64 first = YT_CAP_RING_FRAMES - idx;
  if (first > n) first = n;
  memcpy(out, e->cap_samples + idx, (size_t)first * sizeof(float));
  if (first < n) memcpy(out + first, e->cap_samples, (size_t)(n - first) * sizeof(float));
  if (out_song_frame) *out_song_frame = b.song_frame;
  if (out_clock_frame) *out_clock_frame = b.clock_frame;
  if (out_flags) *out_flags = b.flags;
  ma_atomic_store_64(&e->cap_sample_read, b.sample_start + n);
  ma_atomic_store_64(&e->cap_meta_read, mr + 1);
  return (int32_t)n;
}

int64_t yt_engine_capture_overruns(yt_engine* e) {
  return e ? ma_atomic_load_i64(&e->cap_overruns) : 0;
}

void yt_engine_flush_capture(yt_engine* e) {
  if (e == NULL) return;
  // Consumer-side flush: jump the read cursors to the current write cursors.
  // Load the sample cursor first: a block published between the two loads
  // is dropped, and its samples are reclaimed by the next read.
  ma_uint64 sw = ma_atomic_load_64(&e->cap_sample_write);
  ma_uint64 mw = ma_atomic_load_64(&e->cap_meta_write);
  ma_atomic_store_64(&e->cap_sample_read, sw);
  ma_atomic_store_64(&e->cap_meta_read, mw);
}
