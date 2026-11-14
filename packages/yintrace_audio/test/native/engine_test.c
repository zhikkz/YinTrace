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

  // Monitor gain mixes the mic in.
  yt_engine_set_monitor_gain(e, 0.001f);
  yt_engine_render(e, out, in, 256);
  CHECK(fabsf(out[2 * 100] - 0.1f) < 1e-4f);
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
  yt_engine_signal_audio_event(e, 1);
  CHECK(yt_engine_is_playing(e) == 0);
  yt_engine_render(e, out, input, 128);
  CHECK(yt_engine_position(e) == position);
  for (int i = 0; i < 128 * 2; i++) CHECK(out[i] == 0);
  CHECK(yt_engine_read_capture(e, capture, 4096, &song, &clock, &flags) == 0);
  yt_engine_signal_audio_event(e, 2);
  CHECK(yt_engine_take_audio_events(e) == 3);
  CHECK(yt_engine_take_audio_events(e) == 0);
  CHECK(yt_engine_start(e) == 0);
  CHECK(yt_engine_is_playing(e) == 0);
  yt_engine_set_playing(e, 1);
  yt_engine_render(e, out, input, 128);
  CHECK(yt_engine_position(e) == position + 128);
  CHECK(yt_engine_read_capture(e, capture, 4096, &song, &clock, &flags) == 128);
  yt_engine_destroy(e);
}

int main(int argc, char** argv) {
  CHECK(yt_api_version() == YT_API_VERSION);
  test_mix_seek_loop();
  test_big_block_split();
  test_null_device();
  test_audio_interruption();
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
#ifndef __APPLE__
  // No AAC encoder outside Apple platforms: callers fall back to WAV.
  float one[2] = {0, 0};
  CHECK(yt_encode_m4a("/tmp/x.m4a", one, 1, 44100, 2, 128000) == -1);
#endif
  if (failures == 0) printf("ALL NATIVE TESTS PASSED\n");
  return failures == 0 ? 0 : 1;
}
