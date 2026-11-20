// Runs the engine (fixed at its own sample rate, 44.1 kHz) inside a device
// callback at another rate, e.g. the 48 kHz most iPhones run their hardware
// at whatever rate an app prefers. Used by the iOS duplex device
// (yt_device_ios.inc); plain C, so the native tests exercise it on any host.
//
// Each device callback brings `n` microphone frames and wants `n` output
// frames. The microphone is resampled to the engine's rate into a short
// FIFO; the engine then renders exactly as many frames as the output
// resampler needs for `n` device frames, taking the same number of
// microphone frames from the FIFO, so playback and capture stay in lockstep
// (every captured sample keeps the song frame it was heard with). Both
// directions convert by the same ratio, so the FIFO only wobbles by a frame
// or two around a small prefill: the bridge adds well under a millisecond.
//
// Real-time safe: init/uninit allocate (control thread), render does not.
// Requires miniaudio.h (declarations) and yt_audio.h before inclusion.
#ifndef YT_RATE_BRIDGE_H
#define YT_RATE_BRIDGE_H

#include <stdlib.h>
#include <string.h>

// Microphone frames (at the engine rate) kept ahead of the engine. The
// input resampler holds a frame or so back while the output side asks for a
// frame or so ahead; this covers both.
#define YT_RATE_BRIDGE_PREFILL 8u
// More than this many frames waiting means the two sides drifted apart (a
// device callback that did not ask for output): drop the oldest frames so
// the monitor's latency cannot grow.
#define YT_RATE_BRIDGE_MAX_BACKLOG 64u

typedef struct {
  ma_linear_resampler in_rs;   // microphone: device -> engine, mono
  ma_linear_resampler out_rs;  // output: engine -> device, stereo
  int has_in_rs;
  int has_out_rs;
  float* fifo;      // microphone at the engine rate
  ma_uint32 fifo_cap;
  ma_uint32 fifo_len;
  float* mic;       // microphone frames for one engine render
  float* out;       // engine output, interleaved stereo
  ma_uint32 engine_cap;  // engine frames per render at most
  ma_uint32 max_device_frames;
  ma_uint32 engine_rate;
  ma_uint32 device_rate;
  // Diagnostics, audio thread only (read them on the control thread after
  // the device has stopped).
  ma_uint32 underflows;
  ma_uint32 overflows;
} yt_rate_bridge;

static void yt_rate_bridge_uninit(yt_rate_bridge* b) {
  if (b->has_in_rs) ma_linear_resampler_uninit(&b->in_rs, NULL);
  if (b->has_out_rs) ma_linear_resampler_uninit(&b->out_rs, NULL);
  free(b->fifo);
  free(b->mic);
  free(b->out);
  memset(b, 0, sizeof(*b));
}

// Returns 1 on success. `max_device_frames` is the largest callback size.
static int yt_rate_bridge_init(yt_rate_bridge* b, ma_uint32 engine_rate, ma_uint32 device_rate,
                               ma_uint32 max_device_frames) {
  memset(b, 0, sizeof(*b));
  if (engine_rate < 8000 || device_rate < 8000 || max_device_frames == 0) return 0;
  b->engine_rate = engine_rate;
  b->device_rate = device_rate;
  b->max_device_frames = max_device_frames;
  ma_linear_resampler_config in_cfg = ma_linear_resampler_config_init(ma_format_f32, 1, device_rate, engine_rate);
  ma_linear_resampler_config out_cfg = ma_linear_resampler_config_init(ma_format_f32, 2, engine_rate, device_rate);
  b->has_in_rs = ma_linear_resampler_init(&in_cfg, NULL, &b->in_rs) == MA_SUCCESS;
  b->has_out_rs = ma_linear_resampler_init(&out_cfg, NULL, &b->out_rs) == MA_SUCCESS;
  // Engine frames per device callback, with room for the resamplers' edges.
  b->engine_cap = (ma_uint32)(((ma_uint64)max_device_frames * engine_rate + device_rate - 1) / device_rate) + 16;
  b->fifo_cap = b->engine_cap + YT_RATE_BRIDGE_MAX_BACKLOG + YT_RATE_BRIDGE_PREFILL;
  b->fifo = (float*)calloc(b->fifo_cap, sizeof(float));
  b->mic = (float*)calloc(b->engine_cap, sizeof(float));
  b->out = (float*)calloc((size_t)b->engine_cap * 2, sizeof(float));
  if (!b->has_in_rs || !b->has_out_rs || b->fifo == NULL || b->mic == NULL || b->out == NULL) {
    yt_rate_bridge_uninit(b);
    return 0;
  }
  b->fifo_len = YT_RATE_BRIDGE_PREFILL;  // silence
  return 1;
}

// One device callback: `in` holds `n` mono microphone frames at the device
// rate (NULL = silence), `out` receives `n` interleaved stereo frames.
static void yt_rate_bridge_render(yt_rate_bridge* b, yt_engine* e, float* out, const float* in, ma_uint32 n) {
  if (n == 0) return;
  if (n > b->max_device_frames) {
    memset(out, 0, (size_t)n * 2 * sizeof(float));
    return;
  }
  // 1. The microphone, converted to the engine's rate, joins the FIFO.
  if (in != NULL) {
    ma_uint64 frames_in = n;
    ma_uint64 frames_out = b->fifo_cap - b->fifo_len;
    ma_linear_resampler_process_pcm_frames(&b->in_rs, in, &frames_in, b->fifo + b->fifo_len, &frames_out);
    b->fifo_len += (ma_uint32)frames_out;
  } else {
    ma_uint64 expected = 0;
    ma_linear_resampler_get_expected_output_frame_count(&b->in_rs, n, &expected);
    ma_uint32 room = b->fifo_cap - b->fifo_len;
    ma_uint32 add = expected < room ? (ma_uint32)expected : room;
    memset(b->fifo + b->fifo_len, 0, (size_t)add * sizeof(float));
    b->fifo_len += add;
  }

  // 2. Exactly the engine frames the output resampler needs for n frames.
  ma_uint64 need = 0;
  if (ma_linear_resampler_get_required_input_frame_count(&b->out_rs, n, &need) != MA_SUCCESS) need = 0;
  ma_uint32 m = need < b->engine_cap ? (ma_uint32)need : b->engine_cap;

  // 3. As many microphone frames, oldest first.
  ma_uint32 take = m < b->fifo_len ? m : b->fifo_len;
  if (take < m) b->underflows++;
  memcpy(b->mic + (m - take), b->fifo, (size_t)take * sizeof(float));
  if (take < m) memset(b->mic, 0, (size_t)(m - take) * sizeof(float));
  b->fifo_len -= take;
  if (b->fifo_len > 0) memmove(b->fifo, b->fifo + take, (size_t)b->fifo_len * sizeof(float));
  if (b->fifo_len > YT_RATE_BRIDGE_MAX_BACKLOG) {
    ma_uint32 drop = b->fifo_len - YT_RATE_BRIDGE_PREFILL;
    memmove(b->fifo, b->fifo + drop, (size_t)(b->fifo_len - drop) * sizeof(float));
    b->fifo_len -= drop;
    b->overflows++;
  }

  // 4. The engine renders and captures in lockstep at its own rate.
  if (m > 0) yt_engine_render(e, b->out, b->mic, (int32_t)m);

  // 5. Back to the device rate.
  ma_uint64 frames_in = m;
  ma_uint64 frames_out = n;
  ma_linear_resampler_process_pcm_frames(&b->out_rs, b->out, &frames_in, out, &frames_out);
  if (frames_out < n) memset(out + frames_out * 2, 0, (size_t)(n - frames_out) * 2 * sizeof(float));
}

#endif  // YT_RATE_BRIDGE_H
