// Live monitor (耳返) processing and the output safety clip.
//
// A phone mic picks up singing at roughly -35..-15 dBFS RMS while a mastered
// accompaniment plays at about -14 dBFS, so even the dry mic at unity gain
// sits 10-20 dB under the music and quiet phrases vanish. The monitor chain
// lets the user lift the voice by up to +24 dB and keeps that safe:
//
//   high-pass -> level detector -> compressor / expander -> user gain
//   -> peak limiter -> both output channels
//
//   * The 80 Hz high-pass removes handling rumble, breath pops and DC, which
//     would otherwise eat the headroom once boosted (and trigger the
//     compressor).
//   * The detector is a 5 ms mean square (the attack) followed by a 150 ms
//     release in the dB domain, so it reads close to the RMS level of a sung
//     note, holds over the gaps between syllables and settles within about
//     half a second between phrases.
//   * Above -30 dBFS a 3.5:1 soft-knee compressor narrows the singing range,
//     so a quiet phrase is lifted towards a loud one. Below -55 dBFS a 1:3
//     downward expander (at most 20 dB) keeps the boosted room noise between
//     phrases down without gating breaths and note tails above it.
//   * The user gain follows the slider with a linear ramp across each
//     callback, so dragging it does not zipper.
//   * A zero-lookahead peak limiter (instant attack, 60 ms release) keeps the
//     monitored voice at or below YT_MONITOR_CEILING, so loud singing at full
//     gain is turned down instead of clipping.
//
// Plain C11 math only: no allocation, locks or I/O. The state belongs to the
// audio thread; the control thread only raises `reset_pending` (atomically,
// in yt_audio.c). yt_monitor_init() runs once, off the audio thread.
#ifndef YT_MONITOR_H
#define YT_MONITOR_H

#include <math.h>
#include <stdint.h>

#define YT_MONITOR_HIGHPASS_HZ 80.0
#define YT_MONITOR_ATTACK_S 0.005
#define YT_MONITOR_RELEASE_S 0.15
#define YT_MONITOR_COMP_THRESHOLD_DB (-30.0f)
#define YT_MONITOR_COMP_RATIO 3.5f
#define YT_MONITOR_COMP_KNEE_DB 10.0f
#define YT_MONITOR_EXP_THRESHOLD_DB (-55.0f)
#define YT_MONITOR_EXP_RATIO 3.0f
#define YT_MONITOR_EXP_KNEE_DB 6.0f
#define YT_MONITOR_EXP_RANGE_DB 20.0f
// Peak ceiling of the monitored voice (-3 dBFS): loud enough to sit over a
// mastered accompaniment, with a little room left for the music's peaks
// before the final soft clip.
#define YT_MONITOR_CEILING 0.7f
#define YT_MONITOR_LIMIT_RELEASE_S 0.06
// The compressor/expander gain is updated every this many samples and
// interpolated linearly in between (0.36 ms at 44.1 kHz).
#define YT_MONITOR_BLOCK 16
// The detector's reading of silence.
#define YT_MONITOR_FLOOR_DB (-120.0f)

// The output safety clip leaves |x| <= this untouched.
#define YT_SOFT_CLIP_KNEE 0.9f

typedef struct {
  // Coefficients, set by yt_monitor_init().
  float hp_b0, hp_b1, hp_b2, hp_a1, hp_a2;  // 2nd-order Butterworth high-pass
  float power_coef;                          // per sample, the attack
  float release_coef;                        // per block, in the dB domain
  float limit_release;                       // per sample
  float floor_gain;                          // dynamics gain for silence
  // Audio-thread state.
  float hp_z1, hp_z2;
  float power;     // mean square of the high-passed mic
  float level_db;  // detector output
  float gain, gain_step;  // compressor/expander gain, interpolated per block
  float makeup;    // user gain as last applied
  float limit_env; // peak envelope of the limiter
  uint32_t block_left;
  uint32_t active;  // the previous call was monitoring (no reset needed)
  // Raised by the control thread when the gain is switched on again, in case
  // the audio thread never saw it off (cleared and re-set between callbacks).
  volatile uint32_t reset_pending;
} yt_monitor;

// Static compressor + expander curve: gain in dB for a detector level in dB.
// Quadratic soft knees (Giannoulis, Massberg & Reiss, JAES 2012).
static inline float yt_monitor_gain_db(float level_db) {
  float g = 0.0f;
  const float over = level_db - YT_MONITOR_COMP_THRESHOLD_DB;
  const float comp_slope = 1.0f / YT_MONITOR_COMP_RATIO - 1.0f;  // < 0
  const float ck = YT_MONITOR_COMP_KNEE_DB;
  if (2.0f * over >= ck) {
    g = comp_slope * over;
  } else if (2.0f * over > -ck) {
    const float k = over + 0.5f * ck;
    g = comp_slope * k * k / (2.0f * ck);
  }
  const float under = level_db - YT_MONITOR_EXP_THRESHOLD_DB;
  const float exp_slope = YT_MONITOR_EXP_RATIO - 1.0f;  // > 0
  const float ek = YT_MONITOR_EXP_KNEE_DB;
  float e = 0.0f;
  if (2.0f * under <= -ek) {
    e = exp_slope * under;
  } else if (2.0f * under < ek) {
    const float k = under - 0.5f * ek;
    e = -exp_slope * k * k / (2.0f * ek);
  }
  if (e < -YT_MONITOR_EXP_RANGE_DB) e = -YT_MONITOR_EXP_RANGE_DB;
  return g + e;
}

static inline float yt_monitor_db_to_gain(float db) { return powf(10.0f, db * 0.05f); }

// Forgets everything heard so far: no stale envelope, filter state or gain.
// The user gain then fades in from 0 across the next call.
static inline void yt_monitor_reset(yt_monitor* m) {
  m->hp_z1 = 0.0f;
  m->hp_z2 = 0.0f;
  m->power = 0.0f;
  m->level_db = YT_MONITOR_FLOOR_DB;
  m->gain = m->floor_gain;
  m->gain_step = 0.0f;
  m->makeup = 0.0f;
  m->limit_env = 0.0f;
  m->block_left = 0;
}

static inline void yt_monitor_init(yt_monitor* m, float sample_rate) {
  const double fs = sample_rate > 0.0f ? (double)sample_rate : 44100.0;
  // RBJ cookbook high-pass, Q = 1/sqrt(2).
  const double w0 = 2.0 * 3.14159265358979323846 * YT_MONITOR_HIGHPASS_HZ / fs;
  const double cw = cos(w0), alpha = sin(w0) / (2.0 * 0.70710678118654752);
  const double a0 = 1.0 + alpha;
  m->hp_b0 = (float)((1.0 + cw) / 2.0 / a0);
  m->hp_b1 = (float)(-(1.0 + cw) / a0);
  m->hp_b2 = m->hp_b0;
  m->hp_a1 = (float)(-2.0 * cw / a0);
  m->hp_a2 = (float)((1.0 - alpha) / a0);
  m->power_coef = (float)(1.0 - exp(-1.0 / (YT_MONITOR_ATTACK_S * fs)));
  m->release_coef = (float)(1.0 - exp(-(double)YT_MONITOR_BLOCK / (YT_MONITOR_RELEASE_S * fs)));
  m->limit_release = (float)exp(-1.0 / (YT_MONITOR_LIMIT_RELEASE_S * fs));
  m->floor_gain = yt_monitor_db_to_gain(yt_monitor_gain_db(YT_MONITOR_FLOOR_DB));
  m->active = 0;
  m->reset_pending = 0;
  yt_monitor_reset(m);
}

// The monitor is not heard in this stretch: it starts clean when it resumes.
static inline void yt_monitor_idle(yt_monitor* m) { m->active = 0; }

// Runs `n` mono mic samples through the chain and adds the result to both
// channels of the interleaved stereo `out`. `gain` is the user gain; the
// applied gain ramps to it linearly across these `n` samples.
static inline void yt_monitor_process(yt_monitor* m, const float* in, float* out, uint32_t n,
                                      float gain) {
  if (n == 0) return;
  if (!m->active) {
    yt_monitor_reset(m);
    m->active = 1;
  }
  const float b0 = m->hp_b0, b1 = m->hp_b1, b2 = m->hp_b2, a1 = m->hp_a1, a2 = m->hp_a2;
  const float power_coef = m->power_coef, limit_release = m->limit_release;
  float z1 = m->hp_z1, z2 = m->hp_z2, power = m->power;
  float dyn = m->gain, dyn_step = m->gain_step, env = m->limit_env;
  float makeup = m->makeup;
  const float makeup_step = (gain - makeup) / (float)n;
  uint32_t left = m->block_left;
  for (uint32_t i = 0; i < n; i++) {
    if (left == 0) {
      // Flush what would decay into denormals during silence.
      if (fabsf(z1) < 1e-20f) z1 = 0.0f;
      if (fabsf(z2) < 1e-20f) z2 = 0.0f;
      if (power < 1e-20f) power = 0.0f;
      if (env < 1e-20f) env = 0.0f;
      const float level = 10.0f * log10f(power + 1e-12f);
      float d = m->level_db;
      d = level > d ? level : d + m->release_coef * (level - d);
      m->level_db = d;
      dyn_step = (yt_monitor_db_to_gain(yt_monitor_gain_db(d)) - dyn) / (float)YT_MONITOR_BLOCK;
      left = YT_MONITOR_BLOCK;
    }
    left--;
    float x = in[i];
    if (!isfinite(x)) x = 0.0f;  // one bad sample must not poison the filter
    const float h = b0 * x + z1;  // transposed direct form II
    z1 = b1 * x - a1 * h + z2;
    z2 = b2 * x - a2 * h;
    power += power_coef * (h * h - power);
    dyn += dyn_step;
    makeup += makeup_step;
    float y = h * dyn * makeup;
    const float a = fabsf(y);
    env *= limit_release;
    if (a > env) env = a;
    if (env > YT_MONITOR_CEILING) y *= YT_MONITOR_CEILING / env;
    out[2 * i] += y;
    out[2 * i + 1] += y;
  }
  m->hp_z1 = z1;
  m->hp_z2 = z2;
  m->power = power;
  m->gain = dyn;
  m->gain_step = dyn_step;
  m->limit_env = env;
  m->makeup = gain;  // exactly, whatever the rounding of the ramp
  m->block_left = left;
}

// Output safety clip: exactly transparent for |x| <= YT_SOFT_CLIP_KNEE, then
// bends smoothly (continuous slope) towards full scale, which it never
// reaches. NaN becomes silence.
static inline float yt_soft_clip(float x) {
  const float a = fabsf(x);
  if (a <= YT_SOFT_CLIP_KNEE) return x;
  if (isnan(x)) return 0.0f;
  const float r = 1.0f - YT_SOFT_CLIP_KNEE;
  const float y = 1.0f - r * r / (a + r - YT_SOFT_CLIP_KNEE);
  return x < 0.0f ? -y : y;
}

#endif  // YT_MONITOR_H
