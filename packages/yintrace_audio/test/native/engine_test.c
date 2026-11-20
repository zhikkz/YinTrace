// Native tests for the YinTrace audio core. Build & run with
//   tool/run_native_tests.sh
#define _DEFAULT_SOURCE
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
static void sleep_ms(int ms) { Sleep(ms); }
#else
#include <unistd.h>
static void sleep_ms(int ms) { usleep(ms * 1000); }
#endif

#include "../../src/yt_audio.h"
#include "../../src/yt_monitor.h"  // YT_MONITOR_CEILING, yt_soft_clip
// The sample-rate bridge of the iOS device (plain C, tested here).
#define MA_NO_ENGINE
#define MA_NO_NODE_GRAPH
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_GENERATION
#include "../../src/miniaudio.h"
#include "../../src/yt_rate_bridge.h"

static int failures = 0;
#define CHECK(cond)                                                    \
  do {                                                                 \
    if (!(cond)) {                                                     \
      fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
      failures++;                                                      \
    }                                                                  \
  } while (0)

static void test_mix_seek_loop(void) {
  char err[256] = {0};
  yt_engine* e = yt_engine_create(44100, YT_MODE_OFFLINE, 0, err, sizeof err);
  CHECK(e != NULL);
  // Track 0: mono ramp, track 1: stereo constant.
  const int n = 1000;
  float* mono = malloc(sizeof(float) * n);
  float* stereo = malloc(sizeof(float) * n * 2);
  for (int i = 0; i < n; i++) {
    mono[i] = (float)i / n * 0.5f;
    stereo[2 * i] = 0.25f;
    stereo[2 * i + 1] = -0.25f;
  }
  CHECK(yt_engine_load_track_pcm(e, 0, mono, n, 1) == 0);
  CHECK(yt_engine_load_track_pcm(e, 1, stereo, n / 2, 2) == 0);
  CHECK(yt_engine_length(e) == n);
  yt_engine_set_track_gain(e, 1, 0.5f);

  float out[2 * 256];
  float in[256];
  for (int i = 0; i < 256; i++) in[i] = (float)i;

  // Not playing: silence, capture tagged as not playing.
  yt_engine_render(e, out, in, 256);
  CHECK(fabsf(out[0]) < 1e-6f && fabsf(out[511]) < 1e-6f);
  CHECK(yt_engine_position(e) == 0);
  float cap[4096];
  int64_t song = -1, clock = -1;
  int32_t flags = -1;
  int got = yt_engine_read_capture(e, cap, 4096, &song, &clock, &flags);
  CHECK(got == 256 && flags == 0 && clock == 0 && cap[10] == 10.0f);
  CHECK(yt_engine_read_capture(e, cap, 4096, &song, &clock, &flags) == 0);

  yt_engine_set_playing(e, 1);
  yt_engine_seek(e, 100);
  CHECK(yt_engine_position(e) == 100);
  yt_engine_render(e, out, in, 256);
  // frame 0 of this block = song frame 100
  float expectL = 100.0f / n * 0.5f + 0.25f * 0.5f;
  float expectR = 100.0f / n * 0.5f - 0.25f * 0.5f;
  CHECK(fabsf(out[0] - expectL) < 1e-3f);
  CHECK(fabsf(out[1] - expectR) < 1e-3f);
  // frame 450 is past the stereo track (500 frames)? no: 100+255=355 < 500.
  CHECK(yt_engine_position(e) == 356);
  got = yt_engine_read_capture(e, cap, 4096, &song, &clock, &flags);
  CHECK(got == 256 && song == 100 && clock == 256 && flags == YT_CAPTURE_FLAG_PLAYING);

  // Loop [300, 400): next block of 256 frames wraps twice.
  yt_engine_set_loop(e, 300, 400);
  yt_engine_render(e, out, in, 256);
  // 356 -> 400 (44 frames), then 300->400 (100), then 300->400 (100), then 300->312 (12)
  int64_t songs[8];
  int lens[8];
  int blocks = 0;
  while ((got = yt_engine_read_capture(e, cap, 4096, &song, &clock, &flags)) > 0 && blocks < 8) {
    songs[blocks] = song;
    lens[blocks] = got;
    blocks++;
  }
  CHECK(blocks == 4);
  if (blocks == 4) {
    CHECK(songs[0] == 356 && lens[0] == 44);
    CHECK(songs[1] == 300 && lens[1] == 100);
    CHECK(songs[2] == 300 && lens[2] == 100);
    CHECK(songs[3] == 300 && lens[3] == 12);
  }
  CHECK(yt_engine_position(e) == 312);
  // Output continuity at the wrap: frame 44 of the block = song frame 300.
  float e300 = 300.0f / n * 0.5f + 0.25f * 0.5f;
  CHECK(fabsf(out[2 * 44] - e300) < 1e-3f);

  // Disable loop, play to the end.
  yt_engine_set_loop(e, 0, 0);
  yt_engine_seek(e, 900);
  CHECK(yt_engine_end_count(e) == 0);
  yt_engine_render(e, out, in, 256);
  CHECK(yt_engine_is_playing(e) == 0);
  CHECK(yt_engine_end_count(e) == 1);
  CHECK(yt_engine_position(e) == 1000);
  // last 156 frames silent
  CHECK(fabsf(out[2 * 200]) < 1e-6f);
  got = yt_engine_read_capture(e, cap, 4096, &song, &clock, &flags);
  CHECK(got == 100 && song == 900 && flags == YT_CAPTURE_FLAG_PLAYING);
  got = yt_engine_read_capture(e, cap, 4096, &song, &clock, &flags);
  CHECK(got == 156 && flags == 0);

  // Monitor gain mixes the mic in while playing (see test_monitoring).
  yt_engine_seek(e, 0);
  yt_engine_set_track_gain(e, 0, 0);
  yt_engine_set_track_gain(e, 1, 0);
  yt_engine_set_playing(e, 1);
  yt_engine_set_monitor_gain(e, 1.0f);
  for (int i = 0; i < 256; i++) in[i] = 0.1f * sinf(2.0f * 3.14159265f * 440.0f * i / 44100.0f);
  yt_engine_render(e, out, in, 256);
  CHECK(fabsf(out[2 * 200]) > 1e-4f && out[2 * 200] == out[2 * 200 + 1]);
  yt_engine_flush_capture(e);
  CHECK(yt_engine_read_capture(e, cap, 4096, &song, &clock, &flags) == 0);

  // Overrun accounting: render ~8 s without reading.
  for (int i = 0; i < 1400; i++) yt_engine_render(e, out, in, 256);
  CHECK(yt_engine_capture_overruns(e) > 0);

  yt_engine_unload_track(e, 0);
  CHECK(yt_engine_length(e) == 500);
  yt_engine_destroy(e);
  free(mono);
  free(stereo);
}

static void test_big_block_split(void) {
  char err[256] = {0};
  yt_engine* e = yt_engine_create(44100, YT_MODE_OFFLINE, 0, err, sizeof err);
  float* in = calloc(10000, sizeof(float));
  yt_engine_render(e, NULL, in, 10000);
  float cap[4096];
  int64_t song, clock;
  int32_t flags;
  int total = 0, blocks = 0, got;
  while ((got = yt_engine_read_capture(e, cap, 4096, &song, &clock, &flags)) > 0) {
    CHECK(clock == total);
    total += got;
    blocks++;
  }
  CHECK(total == 10000 && blocks == 3);
  free(in);
  yt_engine_destroy(e);
}

static void test_null_device(void) {
  char err[256] = {0};
  yt_engine* e = yt_engine_create(44100, YT_MODE_DUPLEX, 1, err, sizeof err);
  if (e == NULL) {
    fprintf(stderr, "null device: %s\n", err);
    failures++;
    return;
  }
  float* tone = malloc(sizeof(float) * 44100);
  for (int i = 0; i < 44100; i++) tone[i] = 0.2f * sinf(2.0f * 3.14159265f * 440.0f * i / 44100.0f);
  yt_engine_load_track_pcm(e, 0, tone, 44100, 1);
  yt_engine_set_playing(e, 1);
  CHECK(yt_engine_start(e) == 0);
  sleep_ms(300);
  int64_t pos = yt_engine_position(e);
  CHECK(pos > 4410 && pos < 44100);
  float cap[4096];
  int64_t song, clock;
  int32_t flags;
  int total = 0, got;
  while ((got = yt_engine_read_capture(e, cap, 4096, &song, &clock, &flags)) > 0) total += got;
  CHECK(total > 4410);
  printf("null device: position=%lld captured=%d period=%d\n", (long long)pos, total,
         yt_engine_period_frames(e));
  CHECK(yt_engine_stop(e) == 0);
  yt_engine_destroy(e);
  free(tone);
}

static void test_decode(const char* path, int expect_frames_approx) {
  char err[256] = {0};
  int64_t frames = 0;
  float* pcm = yt_decode_file(path, 44100, 2, &frames, err, sizeof err);
  if (pcm == NULL) {
    fprintf(stderr, "decode %s failed: %s\n", path, err);
    failures++;
    return;
  }
  // 440 Hz tone: count zero crossings on the left channel.
  int zc = 0;
  for (int64_t i = 1; i < frames; i++) {
    if ((pcm[2 * (i - 1)] < 0) != (pcm[2 * i] < 0)) zc++;
  }
  double seconds = (double)frames / 44100.0;
  double freq = zc / 2.0 / seconds;
  printf("decode %s: frames=%lld freq~%.1f\n", path, (long long)frames, freq);
  CHECK(llabs(frames - expect_frames_approx) < 4096);
  CHECK(fabs(freq - 440.0) < 5.0);
  // mono files are duplicated to both channels
  CHECK(fabsf(pcm[2 * 1000] - pcm[2 * 1000 + 1]) < 1e-4f);
  yt_free(pcm);

  pcm = yt_decode_file(path, 16000, 1, &frames, err, sizeof err);
  CHECK(pcm != NULL);
  if (pcm) {
    CHECK(llabs(frames - (int64_t)expect_frames_approx * 16000 / 44100) < 4096);
    yt_free(pcm);
  }
}

#ifdef __APPLE__
static void test_aac_roundtrip(const char* dir) {
  char path[1024];
  snprintf(path, sizeof path, "%s/roundtrip.m4a", dir);
  const int n = 44100 * 2;
  float* pcm = malloc(sizeof(float) * n * 2);
  for (int i = 0; i < n; i++) {
    float v = 0.3f * sinf(2.0f * 3.14159265f * 440.0f * i / 44100.0f);
    pcm[2 * i] = v;
    pcm[2 * i + 1] = v;
  }
  CHECK(yt_encode_m4a(path, pcm, n, 44100, 2, 160000) == 0);
  free(pcm);
  test_decode(path, n);
}
#endif

static void test_audio_interruption(void) {
  char err[256];
  yt_engine* e = yt_engine_create(44100, YT_MODE_OFFLINE, 0, err, sizeof err);
  CHECK(e != NULL);
  float track[1024 * 2], input[128], out[128 * 2], capture[4096];
  for (int i = 0; i < 1024 * 2; i++) track[i] = 0.2f;
  for (int i = 0; i < 128; i++) input[i] = 0.1f;
  CHECK(yt_engine_load_track_pcm(e, 0, track, 1024, 2) == 0);
  yt_engine_set_playing(e, 1);
  yt_engine_render(e, out, input, 128);
  yt_engine_flush_capture(e);
  int64_t position = yt_engine_position(e), song, clock;
  int32_t flags;
  yt_engine_signal_audio_event(e, YT_EVENT_STOPPED);
  CHECK(yt_engine_is_playing(e) == 0);
  yt_engine_render(e, out, input, 128);
  CHECK(yt_engine_position(e) == position);
  for (int i = 0; i < 128 * 2; i++) CHECK(out[i] == 0);
  CHECK(yt_engine_read_capture(e, capture, 4096, &song, &clock, &flags) == 0);
  yt_engine_signal_audio_event(e, YT_EVENT_INTERRUPTION_ENDED);
  CHECK(yt_engine_take_audio_events(e) == (YT_EVENT_STOPPED | YT_EVENT_INTERRUPTION_ENDED));
  CHECK(yt_engine_take_audio_events(e) == 0);
  CHECK(yt_engine_start(e) == 0);
  CHECK(yt_engine_is_playing(e) == 0);
  yt_engine_set_playing(e, 1);
  yt_engine_render(e, out, input, 128);
  CHECK(yt_engine_position(e) == position + 128);
  CHECK(yt_engine_read_capture(e, capture, 4096, &song, &clock, &flags) == 128);

  // iOS announces route changes when playback and recording start: they are
  // reported but must not stop anything.
  yt_engine_signal_audio_event(e, YT_EVENT_ROUTE_CHANGED);
  CHECK(yt_engine_is_playing(e) == 1);
  yt_engine_render(e, out, input, 128);
  CHECK(yt_engine_position(e) == position + 256);
  CHECK(out[0] != 0);
  CHECK(yt_engine_read_capture(e, capture, 4096, &song, &clock, &flags) == 128);
  CHECK(yt_engine_take_audio_events(e) == YT_EVENT_ROUTE_CHANGED);

  // Headphones unplugged: silenced at once, like an interruption.
  yt_engine_signal_audio_event(e, YT_EVENT_ROUTE_CHANGED | YT_EVENT_DEVICE_LOST);
  CHECK(yt_engine_is_playing(e) == 0);
  yt_engine_render(e, out, input, 128);
  CHECK(yt_engine_position(e) == position + 256);
  for (int i = 0; i < 128 * 2; i++) CHECK(out[i] == 0);
  CHECK(yt_engine_read_capture(e, capture, 4096, &song, &clock, &flags) == 0);
  CHECK(yt_engine_take_audio_events(e) == (YT_EVENT_ROUTE_CHANGED | YT_EVENT_DEVICE_LOST));
  yt_engine_destroy(e);
}

// The monitor's high-pass removes DC, so the monitor tests drive it with a
// tone (or noise) and compare levels, not single samples. The tone's period
// is 128 frames, so a 256-frame callback holds whole periods.
#define MON_FRAMES 256
#define MON_TRACK_FRAMES (44100 * 4)
static unsigned noise_seed = 1;

// `rms`: the signal's RMS level (linear).
static void mic_signal(float* x, int n, int start, float rms, int noise) {
  for (int i = 0; i < n; i++) {
    if (noise) {
      noise_seed = noise_seed * 1664525u + 1013904223u;
      x[i] = rms * 1.7320508f * ((float)(noise_seed >> 8) / 8388608.0f - 1.0f);
    } else {
      x[i] = rms * 1.4142136f * sinf(2.0f * 3.14159265f * (float)((start + i) % 128) / 128.0f);
    }
  }
}

typedef struct {
  double rms;       // of the left channel minus `base`, over the last callbacks
  float peak;       // largest |sample| of the whole output
  int ears_equal;   // both channels identical throughout
} heard;

// Renders `blocks` callbacks with the mic at `rms` and measures the last
// `measure` of them.
static heard listen(yt_engine* e, float rms, int noise, int blocks, int measure, float base) {
  static int t = 0;
  float in[MON_FRAMES], out[2 * MON_FRAMES];
  heard h = {0, 0, 1};
  double acc = 0;
  for (int b = 0; b < blocks; b++) {
    mic_signal(in, MON_FRAMES, t, rms, noise);
    t += MON_FRAMES;
    yt_engine_render(e, out, in, MON_FRAMES);
    for (int i = 0; i < MON_FRAMES; i++) {
      if (out[2 * i] != out[2 * i + 1]) h.ears_equal = 0;
      if (fabsf(out[2 * i]) > h.peak) h.peak = fabsf(out[2 * i]);
      const double v = out[2 * i] - base;
      if (b >= blocks - measure) acc += v * v;
    }
  }
  h.rms = sqrt(acc / (measure * MON_FRAMES));
  yt_engine_flush_capture(e);
  return h;
}

// One silent callback while paused: the monitor starts clean when it resumes.
static void pause_briefly(yt_engine* e) {
  float out[2 * MON_FRAMES], in[MON_FRAMES] = {0};
  yt_engine_set_playing(e, 0);
  yt_engine_render(e, out, in, MON_FRAMES);
  yt_engine_set_playing(e, 1);
}

// The left channel of `blocks` callbacks of a quiet tone from phase 0.
static void record_quiet(yt_engine* e, int blocks, float* dst) {
  float in[MON_FRAMES], out[2 * MON_FRAMES];
  for (int b = 0; b < blocks; b++) {
    mic_signal(in, MON_FRAMES, b * MON_FRAMES, 0.005f, 0);
    yt_engine_render(e, out, in, MON_FRAMES);
    for (int i = 0; i < MON_FRAMES; i++) dst[b * MON_FRAMES + i] = out[2 * i];
  }
  yt_engine_flush_capture(e);
}

static double db(double v) { return 20.0 * log10(v); }

static yt_engine* monitor_engine(float track_gain) {
  static float track[MON_TRACK_FRAMES];
  for (int i = 0; i < MON_TRACK_FRAMES; i++) track[i] = 0.1f;
  char err[256];
  yt_engine* e = yt_engine_create(44100, YT_MODE_OFFLINE, 0, err, sizeof err);
  CHECK(e != NULL && yt_engine_monitor_available(e));
  CHECK(yt_engine_load_track_pcm(e, 0, track, MON_TRACK_FRAMES, 1) == 0);
  yt_engine_set_track_gain(e, 0, track_gain);
  return e;
}

static void test_monitoring(void) {
  yt_engine* e = monitor_engine(1.0f);
  float in[MON_FRAMES], out[2 * MON_FRAMES], capture[4096];
  int64_t song, clock;
  int32_t flags;
  yt_engine_set_playing(e, 1);
  yt_engine_render(e, out, NULL, MON_FRAMES);
  const float track = out[0];  // the track alone
  CHECK(fabsf(track - 0.1f) < 1e-3f);

  // Off by default: only the track is heard.
  heard h = listen(e, 0.05f, 0, 2, 2, track);
  CHECK(h.rms == 0.0 && h.ears_equal);

  // Both ears hear the input in this very callback, mixed with the track.
  yt_engine_set_monitor_gain(e, 1.0f);
  mic_signal(in, MON_FRAMES, 0, 0.05f, 0);
  yt_engine_render(e, out, in, MON_FRAMES);
  double acc = 0;
  int same = 1;
  for (int i = MON_FRAMES / 2; i < MON_FRAMES; i++) {
    acc += fabs(out[2 * i] - track);
    same = same && out[2 * i] == out[2 * i + 1];
  }
  CHECK(acc > 0.1 && same);
  // The capture is the dry mic: no high-pass, compression or gain.
  CHECK(yt_engine_read_capture(e, capture, 4096, &song, &clock, &flags) == MON_FRAMES);
  CHECK(flags == YT_CAPTURE_FLAG_PLAYING && memcmp(capture, in, sizeof in) == 0);

  // Below the limiter the level follows the gain exactly (the compressor
  // reads the mic before the gain).
  yt_engine_set_track_gain(e, 0, 0.0f);
  yt_engine_set_monitor_gain(e, 4.0f);
  pause_briefly(e);
  const double g4 = listen(e, 0.007f, 0, 20, 2, 0.0f).rms;
  yt_engine_set_monitor_gain(e, 8.0f);
  h = listen(e, 0.007f, 0, 4, 2, 0.0f);
  CHECK(fabs(h.rms / g4 - 2.0) < 0.01 && h.ears_equal);
  printf("monitor: -43 dBFS tone at gain 4 -> %.1f dBFS\n", db(g4));

  // Compression: 20 dB between a quiet (-40 dBFS) and a loud (-20 dBFS)
  // phrase become about 13.
  yt_engine_set_monitor_gain(e, 4.0f);
  pause_briefly(e);
  const double quiet = listen(e, 0.01f, 0, 40, 4, 0.0f).rms;
  pause_briefly(e);
  const double loud = listen(e, 0.1f, 0, 40, 4, 0.0f).rms;
  printf("monitor: -40/-20 dBFS in -> %.1f/%.1f dBFS out\n", db(quiet), db(loud));
  CHECK(fabs(db(quiet / (0.01 * 4.0))) < 0.5);  // below the threshold: plain gain
  CHECK(db(loud / quiet) > 10.0 && db(loud / quiet) < 15.0);

  // Room noise below the expander threshold stays down; a soft voice above
  // it gets the plain gain.
  pause_briefly(e);
  const double noise = listen(e, 0.001f, 1, 80, 40, 0.0f).rms;
  pause_briefly(e);
  const double soft = listen(e, 0.0056f, 0, 40, 4, 0.0f).rms;
  printf("monitor: -60 dBFS noise %+.1f dB, -45 dBFS tone %+.1f dB vs plain gain\n",
         db(noise / (0.001 * 4.0)), db(soft / (0.0056 * 4.0)));
  CHECK(db(noise / (0.001 * 4.0)) < -6.0);
  CHECK(fabs(db(soft / (0.0056 * 4.0))) < 1.0);

  // Full-scale input at the highest gain: the voice is limited to the
  // ceiling, and with a loud track the sum still stays below full scale.
  yt_engine_set_monitor_gain(e, YT_MONITOR_MAX_GAIN);
  h = listen(e, 0.7071068f, 0, 40, 4, 0.0f);
  CHECK(h.peak <= YT_MONITOR_CEILING + 1e-6f && h.rms > 0.3 && h.ears_equal);
  h = listen(e, 0.5773503f, 1, 40, 4, 0.0f);  // uniform noise, +-1
  CHECK(h.peak <= YT_MONITOR_CEILING + 1e-6f && h.ears_equal);
  yt_engine_set_track_gain(e, 0, 9.0f);  // the track at 0.9
  h = listen(e, 0.7071068f, 0, 40, 4, 0.0f);
  CHECK(h.peak <= YT_BUS_CEILING + 1e-6f && h.peak > 0.85f && h.ears_equal);  // the mix limiter
  yt_engine_set_track_gain(e, 0, 1.0f);
  // The mix limiter recovers to exactly unity within about 0.7 s.
  yt_engine_set_monitor_gain(e, 0.0f);
  listen(e, 0.0f, 0, 200, 1, track);

  // Pause mutes immediately.
  yt_engine_set_monitor_gain(e, 4.0f);
  CHECK(listen(e, 0.05f, 0, 4, 1, track).rms > 0.01);
  yt_engine_set_playing(e, 0);
  CHECK(listen(e, 0.05f, 0, 1, 1, 0.0f).peak == 0.0f);
  // Mute at the natural end, mid-block.
  yt_engine_set_playing(e, 1);
  yt_engine_seek(e, MON_TRACK_FRAMES - 8);
  mic_signal(in, 64, 0, 0.05f, 0);
  yt_engine_render(e, out, in, 64);
  int silent = 1;
  for (int i = 2 * 8; i < 2 * 64; i++) silent = silent && out[i] == 0.0f;
  CHECK(silent && fabsf(out[0] - track) < 1e-2f);
  CHECK(yt_engine_is_playing(e) == 0);
  yt_engine_flush_capture(e);

  // Route changes disarm before Dart polls.
  yt_engine_seek(e, 0);
  yt_engine_set_playing(e, 1);
  CHECK(listen(e, 0.05f, 0, 2, 1, track).rms > 0.01);
  yt_engine_signal_audio_event(e, YT_EVENT_ROUTE_CHANGED);
  CHECK(listen(e, 0.05f, 0, 1, 1, track).rms == 0.0);
  // A lost device silences everything; restarting does not restore the mic.
  yt_engine_set_monitor_gain(e, 4.0f);
  yt_engine_signal_audio_event(e, YT_EVENT_DEVICE_LOST);
  CHECK(listen(e, 0.05f, 0, 1, 1, 0.0f).peak == 0.0f);
  CHECK(yt_engine_start(e) == 0);
  yt_engine_set_playing(e, 1);
  CHECK(listen(e, 0.05f, 0, 2, 2, track).rms == 0.0);
  yt_engine_take_audio_events(e);

  // Invalid gains cannot poison the output: they turn the monitor off.
  const float bad[] = {NAN, INFINITY, -1.0f};
  for (int i = 0; i < 3; i++) {
    yt_engine_set_monitor_gain(e, 4.0f);
    yt_engine_set_monitor_gain(e, bad[i]);
    h = listen(e, 0.05f, 0, 2, 2, track);
    CHECK(h.rms == 0.0 && h.ears_equal);
  }

  // Free practice: heard while capturing only when asked for.
  yt_engine_set_playing(e, 0);
  yt_engine_set_monitor_gain(e, 4.0f);
  CHECK(listen(e, 0.05f, 0, 2, 1, 0.0f).peak == 0.0f);
  yt_engine_set_monitor_while_capturing(e, 1);
  CHECK(listen(e, 0.05f, 0, 4, 1, 0.0f).rms > 0.01);
  yt_engine_set_monitor_while_capturing(e, 0);
  yt_engine_destroy(e);

  // Gains above the highest are capped; each run starts clean, so equal
  // gains give identical output.
  static float a[8 * MON_FRAMES], b[8 * MON_FRAMES];
  const float gains[] = {YT_MONITOR_MAX_GAIN, 1000.0f, YT_MONITOR_MAX_GAIN * 0.5f};
  double rms[3];
  for (int g = 0; g < 3; g++) {
    e = monitor_engine(0.0f);
    yt_engine_set_playing(e, 1);
    yt_engine_set_monitor_gain(e, gains[g]);
    record_quiet(e, 8, g == 1 ? b : a);
    const float* x = g == 1 ? b : a;
    acc = 0;
    for (int i = 4 * MON_FRAMES; i < 8 * MON_FRAMES; i++) acc += (double)x[i] * x[i];
    rms[g] = sqrt(acc / (4 * MON_FRAMES));
    if (g == 1) CHECK(memcmp(a, b, sizeof a) == 0);
    yt_engine_destroy(e);
  }
  CHECK(rms[0] > 0.05 && fabs(rms[2] / rms[0] - 0.5) < 1e-3);

  // No stale state: after a loud phrase and a pause, or after the gain was
  // cleared and set again between two callbacks (a stop or route change the
  // audio thread never saw), the monitor sounds exactly like a new engine.
  yt_engine* fresh = monitor_engine(0.0f);
  yt_engine_set_playing(fresh, 1);
  yt_engine_set_monitor_gain(fresh, 4.0f);
  record_quiet(fresh, 8, a);
  yt_engine_destroy(fresh);
  float first = 0, steady = 0;
  for (int i = 0; i < 16; i++) first = fmaxf(first, fabsf(a[i]));
  for (int i = 7 * MON_FRAMES; i < 8 * MON_FRAMES; i++) steady = fmaxf(steady, fabsf(a[i]));
  CHECK(steady > 0.02f && first < 0.05f * steady);  // it fades in, no burst
  e = monitor_engine(0.0f);
  yt_engine_set_playing(e, 1);
  yt_engine_set_monitor_gain(e, 4.0f);
  listen(e, 0.3f, 0, 20, 1, 0.0f);
  pause_briefly(e);
  record_quiet(e, 8, b);
  CHECK(memcmp(a, b, sizeof a) == 0);
  listen(e, 0.3f, 0, 20, 1, 0.0f);
  yt_engine_signal_audio_event(e, YT_EVENT_ROUTE_CHANGED);
  yt_engine_set_monitor_gain(e, 4.0f);
  record_quiet(e, 8, b);
  CHECK(memcmp(a, b, sizeof a) == 0);
  yt_engine_destroy(e);

  // A null/unknown output never opens live monitoring.
  char err[256];
  e = yt_engine_create(44100, YT_MODE_DUPLEX, 1, err, sizeof err);
  CHECK(e != NULL && !yt_engine_monitor_available(e));
  static float short_track[256];
  for (int i = 0; i < 256; i++) short_track[i] = 0.1f;
  CHECK(yt_engine_load_track_pcm(e, 0, short_track, 256, 1) == 0);
  yt_engine_set_monitor_gain(e, 1.0f);
  yt_engine_set_playing(e, 1);
  mic_signal(in, 64, 0, 0.3f, 0);
  yt_engine_render(e, out, in, 64);
  CHECK(fabsf(out[14] - 0.1f) < 1e-3f && fabsf(out[100] - 0.1f) < 1e-3f);
  yt_engine_set_playing(e, 0);
  yt_engine_set_monitor_while_capturing(e, 1);
  yt_engine_set_monitor_gain(e, 1.0f);
  yt_engine_render(e, out, in, 64);
  silent = 1;
  for (int i = 0; i < 128; i++) silent = silent && out[i] == 0.0f;
  CHECK(silent);
  yt_engine_destroy(e);
}

static void test_soft_clip(void) {
  // The last resort after the mix limiter: transparent up to the knee,
  // then smooth, monotonic, symmetric and never full scale.
  CHECK(yt_soft_clip(0.45f) == 0.45f && yt_soft_clip(-0.9f) == -0.9f);
  CHECK(fabsf(yt_soft_clip(0.9001f) - 0.9001f) < 1e-6f);  // slope 1 at the knee
  float last = YT_SOFT_CLIP_KNEE;
  const float loud[] = {0.95f, 1.2f, 3.0f, 10.0f, 1000.0f};
  for (int g = 0; g < 5; g++) {
    const float y = yt_soft_clip(loud[g]);
    CHECK(y > last && y < 1.0f && y < loud[g] && yt_soft_clip(-loud[g]) == -y);
    last = y;
  }
  CHECK(yt_soft_clip(INFINITY) == 1.0f && yt_soft_clip(-INFINITY) == -1.0f);
  CHECK(yt_soft_clip(NAN) == 0.0f);
}

// Tracks plus the monitor go through a limiter at YT_BUS_CEILING: bit for
// bit below it, at most the ceiling above it (both channels by the same
// gain), and back to exactly unity once the mix is quiet again.
static void test_bus_limiter(void) {
  char err[256];
  yt_engine* e = yt_engine_create(44100, YT_MODE_OFFLINE, 0, err, sizeof err);
  CHECK(e != NULL);
  enum { N = 3 * 44100 };  // longer than the test plays
  static float track[2 * N], out[2 * 512];
  for (int i = 0; i < N; i++) {
    const float v = 0.5f * sinf(2.0f * 3.14159265f * 110.0f * i / 44100.0f);
    track[2 * i] = v;
    track[2 * i + 1] = -0.5f * v;
  }
  CHECK(yt_engine_load_track_pcm(e, 0, track, N, 2) == 0);
  yt_engine_set_playing(e, 1);
  // Quiet: untouched (as stored, int16).
  yt_engine_render(e, out, NULL, 512);
  int exact = 1;
  for (int i = 0; i < 512; i++) {
    const float l = (float)(int16_t)lrintf(track[2 * i] * 32767.0f) / 32768.0f;
    exact &= fabsf(out[2 * i] - l) <= 1.0f / 32768.0f;  // one LSB of the int16 track
  }
  CHECK(exact);
  // Three times too loud: limited, the channels keep their balance.
  yt_engine_set_track_gain(e, 0, 5.0f);
  float peak = 0.0f;
  int balanced = 1;
  for (int b = 0; b < 20; b++) {
    yt_engine_render(e, out, NULL, 512);
    for (int i = 0; i < 512; i++) {
      peak = fmaxf(peak, fmaxf(fabsf(out[2 * i]), fabsf(out[2 * i + 1])));
      if (fabsf(out[2 * i]) > 0.05f) balanced &= fabsf(out[2 * i + 1] / out[2 * i] + 0.5f) < 1e-3f;
    }
  }
  CHECK(peak <= YT_BUS_CEILING + 1e-6f && peak > 0.85f);
  CHECK(balanced);
  // Quiet again: within a second the gain is exactly 1 again.
  yt_engine_set_track_gain(e, 0, 1.0f);
  for (int b = 0; b < 80; b++) yt_engine_render(e, out, NULL, 512);
  const int64_t pos = yt_engine_position(e);
  yt_engine_render(e, out, NULL, 512);
  exact = 1;
  for (int i = 0; i < 512; i++) {
    const float l = (float)(int16_t)lrintf(track[2 * ((pos + i) % N)] * 32767.0f) / 32768.0f;
    exact &= fabsf(out[2 * i] - l) <= 1.0f / 32768.0f;  // one LSB of the int16 track
  }
  CHECK(exact);
  yt_engine_destroy(e);
}

static void test_track_offset(void) {
  char err[256];
  yt_engine* e = yt_engine_create(44100, YT_MODE_OFFLINE, 0, err, sizeof err);
  CHECK(e != NULL);
  static float a[1000], b[200], out[600 * 2];
  for (int i = 0; i < 1000; i++) a[i] = 0.1f;
  for (int i = 0; i < 200; i++) b[i] = 0.25f;
  CHECK(yt_engine_load_track_pcm(e, 0, a, 1000, 1) == 0);
  CHECK(yt_engine_load_track_pcm(e, 1, b, 200, 1) == 0);
  yt_engine_set_track_offset(e, 1, 1100);  // after track 0 has ended
  CHECK(yt_engine_length(e) == 1300);
  yt_engine_seek(e, 900);
  yt_engine_set_playing(e, 1);
  yt_engine_render(e, out, NULL, 600);
  CHECK(fabsf(out[0] - 0.1f) < 1e-3);           // frame 900: track 0 only
  CHECK(out[2 * 100] == 0 && out[2 * 199] == 0);  // 1000..1099: silence
  CHECK(fabsf(out[2 * 200] - 0.25f) < 1e-3);    // 1100: track 1 starts
  CHECK(fabsf(out[2 * 399 + 1] - 0.25f) < 1e-3);
  CHECK(out[2 * 400] == 0);                     // 1300: the end
  CHECK(yt_engine_is_playing(e) == 0);
  // Starting inside the offset track.
  yt_engine_seek(e, 1250);
  yt_engine_set_playing(e, 1);
  yt_engine_render(e, out, NULL, 10);
  CHECK(fabsf(out[0] - 0.25f) < 1e-3);
  // A negative offset skips the track's beginning.
  float ramp[300];
  for (int i = 0; i < 300; i++) ramp[i] = (float)i / 1000.0f;
  CHECK(yt_engine_load_track_pcm(e, 2, ramp, 300, 1) == 0);
  yt_engine_set_track_gain(e, 0, 0);
  yt_engine_set_track_gain(e, 1, 0);
  yt_engine_set_track_offset(e, 2, -100);
  yt_engine_seek(e, 0);
  yt_engine_set_playing(e, 1);
  yt_engine_render(e, out, NULL, 10);
  CHECK(fabsf(out[0] - 0.1f) < 2e-3);  // track frame 100 at song frame 0
  CHECK(fabsf(out[2 * 9] - 0.109f) < 2e-3);
  // Loading a track resets its offset.
  yt_engine_unload_track(e, 2);
  CHECK(yt_engine_load_track_pcm(e, 1, b, 200, 1) == 0);
  CHECK(yt_engine_length(e) == 1000);
  yt_engine_destroy(e);
}

// The engine at 44.1 kHz inside 48 kHz device callbacks (most iPhones): every
// callback gets exactly its frames, the tone keeps its pitch without clicks,
// capture stays continuous and tagged, and the microphone reaches the
// capture (and the monitor) with well under a millisecond of extra delay.
static void test_rate_bridge(void) {
  char err[256];
  yt_engine* e = yt_engine_create(44100, YT_MODE_OFFLINE, 0, err, sizeof err);
  CHECK(e != NULL);
  const int track_frames = 44100 * 4;
  float* track = malloc(sizeof(float) * track_frames);
  for (int i = 0; i < track_frames; i++) track[i] = 0.5f * sinf(2.0f * 3.14159265f * 1000.0f * i / 44100.0f);
  CHECK(yt_engine_load_track_pcm(e, 0, track, track_frames, 1) == 0);
  yt_engine_set_playing(e, 1);

  yt_rate_bridge b;
  CHECK(yt_rate_bridge_init(&b, 44100, 48000, 4096));
  // Callback sizes iOS uses: 256 frames, odd sizes after a route change,
  // 4096 while the screen is locked.
  const ma_uint32 sizes[] = {256, 256, 256, 255, 257, 512, 4096, 256, 470, 256, 128};
  const int nsizes = (int)(sizeof(sizes) / sizeof(sizes[0]));
  float* out = malloc(sizeof(float) * 4096 * 2);
  float* mic = malloc(sizeof(float) * 4096);
  float* cap = malloc(sizeof(float) * 4096);
  long long device_frames = 0, captured = 0, crossings = 0, clicks = 0;
  long long impulse_at = -1, impulse_seen = -1;
  int64_t next_song = 0;
  int tags_ok = 1;
  float last = 0.0f;
  for (int k = 0; device_frames < 48000 * 3; k++) {
    ma_uint32 n = sizes[k % nsizes];
    for (ma_uint32 i = 0; i < n; i++) mic[i] = 0.0f;
    if (impulse_at < 0 && device_frames > 48000) {
      impulse_at = device_frames;
      mic[0] = 1.0f;
    }
    yt_rate_bridge_render(&b, e, out, mic, n);
    for (ma_uint32 i = 0; i < n; i++) {
      float v = out[2 * i];
      if (out[2 * i] != out[2 * i + 1]) clicks++;
      if ((last < 0) != (v < 0)) crossings++;
      // A 1 kHz sine at 0.5 moves at most ~0.066 per 48 kHz sample.
      if (fabsf(v - last) > 0.09f) clicks++;
      last = v;
    }
    device_frames += n;
    int64_t song, clock;
    int32_t flags;
    int got;
    while ((got = yt_engine_read_capture(e, cap, 4096, &song, &clock, &flags)) > 0) {
      if (song != next_song) tags_ok = 0;
      for (int i = 0; i < got; i++) {
        if (impulse_seen < 0 && fabsf(cap[i]) > 0.05f) impulse_seen = captured + i;
      }
      next_song = song + got;
      captured += got;
    }
  }
  double seconds = device_frames / 48000.0;
  double freq = crossings / 2.0 / seconds;
  printf("rate bridge: %.2f s, %lld engine frames, tone %.1f Hz, under/overflows %u/%u, mic delay %.2f ms\n",
         seconds, captured, freq, b.underflows, b.overflows,
         (impulse_seen - impulse_at * 44100.0 / 48000.0) / 44.1);
  CHECK(fabs(freq - 1000.0) < 2.0);
  CHECK(clicks == 0);
  CHECK(tags_ok);
  CHECK(llabs(captured - (long long)llround(device_frames * 44100.0 / 48000.0)) < 32);
  CHECK(b.underflows == 0 && b.overflows == 0);
  CHECK(impulse_seen >= 0);
  // The impulse arrives where it was sung, give or take the prefill.
  double delay_ms = (impulse_seen - impulse_at * 44100.0 / 48000.0) / 44.1;
  CHECK(delay_ms > -0.1 && delay_ms < 0.6);
  CHECK(yt_engine_position(e) == captured);

  yt_rate_bridge_uninit(&b);
  // A callback bigger than the bridge was made for stays silent.
  CHECK(yt_rate_bridge_init(&b, 44100, 48000, 256));
  for (int i = 0; i < 1024; i++) out[i] = 1.0f;
  yt_rate_bridge_render(&b, e, out, mic, 512);
  int silent = 1;
  for (int i = 0; i < 1024; i++) silent &= out[i] == 0.0f;
  CHECK(silent);
  yt_rate_bridge_uninit(&b);
  // A slower device (32 kHz, some USB headsets) and silence in.
  CHECK(yt_rate_bridge_init(&b, 44100, 32000, 1024));
  for (int k = 0; k < 400; k++) yt_rate_bridge_render(&b, e, out, k % 2 ? mic : NULL, 256);
  CHECK(b.underflows == 0 && b.overflows == 0);
  yt_rate_bridge_uninit(&b);
  CHECK(!yt_rate_bridge_init(&b, 44100, 0, 256));
  free(out);
  free(mic);
  free(cap);
  free(track);
  yt_engine_destroy(e);
}

static void test_audio_log(void) {
  char buf[4096];
  CHECK(yt_audio_log(buf, sizeof buf) == 0);
  for (int i = 0; i < 30; i++) {
    char line[32];
    snprintf(line, sizeof line, "line %d", i);
    yt_audio_log_add(line);
  }
  int32_t n = yt_audio_log(buf, sizeof buf);
  CHECK(n == (int32_t)strlen(buf));
  CHECK(strncmp(buf, "line 6\n", 7) == 0);  // the last 24, oldest first
  CHECK(strstr(buf, "line 29\n") != NULL);
  CHECK(strstr(buf, "line 5\n") == NULL);
  // A line longer than a slot is cut before a character, never inside one.
  char long_line[400] = "";
  for (int i = 0; i < 60; i++) strcat(long_line, "\xe9\x9f\xb3");  // 音
  yt_audio_log_add(long_line);
  n = yt_audio_log(buf, sizeof buf);
  const char* last = buf;
  for (const char* p = buf; *p; p++) {
    if (*p == '\n' && p[1] != '\0') last = p + 1;
  }
  size_t len = strcspn(last, "\n");
  CHECK(len > 90 && len % 3 == 0);
  // Too small a buffer: whole lines only, still terminated.
  CHECK(yt_audio_log(buf, 12) <= 11);
  CHECK(strlen(buf) <= 11);
}

int main(int argc, char** argv) {
  CHECK(yt_api_version() == YT_API_VERSION);
  test_mix_seek_loop();
  test_big_block_split();
  test_null_device();
  test_audio_interruption();
  test_monitoring();
  test_soft_clip();
  test_bus_limiter();
  test_rate_bridge();
  test_audio_log();
  test_track_offset();
  for (int i = 1; i + 1 < argc; i += 2) test_decode(argv[i], atoi(argv[i + 1]));
#ifdef __APPLE__
  test_aac_roundtrip(getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
#endif
  char err[64];
  int64_t frames;
  CHECK(yt_decode_file("/nonexistent.mp3", 44100, 2, &frames, err, sizeof err) == NULL);
  CHECK(yt_encode_m4a("/tmp/x.m4a", NULL, 0, 44100, 2, 128000) < 0);
  // Excluding from backups succeeds on an existing file (a no-op outside
  // Apple platforms).
  {
    char marker[1024];
    snprintf(marker, sizeof marker, "%s/yt_backup_test", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    FILE* f = fopen(marker, "w");
    CHECK(f != NULL);
    if (f) fclose(f);
    CHECK(yt_exclude_from_backup(marker) == 0);
    remove(marker);
  }
  {
    // Device facts for the benchmark report.
    char model[64];
    int32_t n = yt_device_model(model, sizeof model);
    CHECK(n >= 0 && n < (int32_t)sizeof model && (int32_t)strlen(model) == n);
    char tiny[2];
    CHECK(yt_device_model(tiny, sizeof tiny) <= 1);
    int32_t thermal = yt_thermal_state();
    CHECK(thermal >= -1 && thermal <= 3);
#ifdef __APPLE__
    printf("device model %s, %lld bytes, thermal state %d\n", model, (long long)yt_physical_memory(), thermal);
    CHECK(n > 0);
    CHECK(yt_physical_memory() > 0);
    CHECK(thermal >= 0);
#else
    CHECK(n == 0 && model[0] == '\0');
    CHECK(yt_physical_memory() == -1);
    CHECK(thermal == -1);
#endif
  }
#ifndef __APPLE__
  // No AAC encoder outside Apple platforms: callers fall back to WAV.
  float one[2] = {0, 0};
  CHECK(yt_encode_m4a("/tmp/x.m4a", one, 1, 44100, 2, 128000) == -1);
#endif
  if (failures == 0) printf("ALL NATIVE TESTS PASSED\n");
  return failures == 0 ? 0 : 1;
}
