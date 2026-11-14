// YinTrace native audio core.
//
// A small, portable C API on top of miniaudio:
//   * file decoding to float PCM (ExtAudioFile on Apple, miniaudio elsewhere)
//   * AAC (.m4a) encoding on Apple platforms
//   * a full-duplex practice engine: plays up to YT_MAX_TRACKS in-memory
//     tracks in sync and captures the microphone, tagging every captured
//     block with the song frame that was being played at that moment.
//
// Everything here is callable from Dart through dart:ffi. None of the
// functions call back into Dart; captured audio is pulled by polling
// yt_engine_read_capture().
#ifndef YT_AUDIO_H
#define YT_AUDIO_H

#include <stdint.h>

#if defined(_WIN32)
#define YT_EXPORT __declspec(dllexport)
#else
#define YT_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define YT_API_VERSION 1
#define YT_MAX_TRACKS 4

// Engine modes.
#define YT_MODE_PLAYBACK 0
#define YT_MODE_DUPLEX 1
#define YT_MODE_CAPTURE 2
// No audio device at all; drive the engine with yt_engine_render().
#define YT_MODE_OFFLINE 3

// Flags reported with each captured block.
#define YT_CAPTURE_FLAG_PLAYING 1

YT_EXPORT int32_t yt_api_version(void);
YT_EXPORT void yt_free(void* ptr);

// ---------------------------------------------------------------------------
// Decoding / encoding
// ---------------------------------------------------------------------------

// Decodes an audio file into interleaved float32 PCM at `sample_rate` with
// `channels` (1 or 2) channels. Returns a buffer that must be released with
// yt_free(), or NULL on failure (a message is written to `err`).
YT_EXPORT float* yt_decode_file(const char* path, int32_t sample_rate,
                                int32_t channels, int64_t* out_frames,
                                char* err, int32_t err_len);

// Encodes interleaved float32 PCM as AAC in an .m4a container.
// Returns 0 on success, -1 when the platform has no encoder, < -1 on error.
YT_EXPORT int32_t yt_encode_m4a(const char* path, const float* data,
                                int64_t frames, int32_t sample_rate,
                                int32_t channels, int32_t bitrate);

// Marks a file or directory as excluded from device backups (iCloud/iTunes).
// For data the app can download again. Returns 0 on success or where the
// platform has no such concept, < 0 on error.
YT_EXPORT int32_t yt_exclude_from_backup(const char* path);

// ---------------------------------------------------------------------------
// Audio session / permissions (meaningful on iOS and macOS, no-ops elsewhere)
// ---------------------------------------------------------------------------

// 0 = not determined yet, 1 = granted, 2 = denied.
YT_EXPORT int32_t yt_mic_permission_status(void);
// Starts the asynchronous system permission prompt; poll the status.
YT_EXPORT void yt_request_mic_permission(void);
// Configures the shared audio session. `record` selects play-and-record,
// `measurement` disables system voice processing (AGC etc.) where possible.
YT_EXPORT int32_t yt_configure_session(int32_t record, int32_t measurement);
// Hardware input + output latency reported by the OS, in seconds (0 if unknown).
YT_EXPORT double yt_session_latency(void);
// Bytes this process can still allocate before the system terminates it
// (iOS: os_proc_available_memory). -1 where there is no such limit or it is
// unknown (other platforms, the simulator).
YT_EXPORT int64_t yt_available_memory(void);

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

typedef struct yt_engine yt_engine;

// `use_null_backend` selects miniaudio's null device (for tests/CI).
YT_EXPORT yt_engine* yt_engine_create(int32_t sample_rate, int32_t mode,
                                      int32_t use_null_backend, char* err,
                                      int32_t err_len);
YT_EXPORT int32_t yt_engine_start(yt_engine* engine);
YT_EXPORT int32_t yt_engine_stop(yt_engine* engine);
YT_EXPORT void yt_engine_destroy(yt_engine* engine);

YT_EXPORT int32_t yt_engine_sample_rate(yt_engine* engine);
// Period size of the underlying device in frames (0 when offline).
YT_EXPORT int32_t yt_engine_period_frames(yt_engine* engine);

// Copies interleaved float32 PCM into track `slot` (stored as int16).
YT_EXPORT int32_t yt_engine_load_track_pcm(yt_engine* engine, int32_t slot,
                                           const float* data, int64_t frames,
                                           int32_t channels);
// Decodes `path` straight into track `slot`.
YT_EXPORT int32_t yt_engine_load_track_file(yt_engine* engine, int32_t slot,
                                            const char* path, char* err,
                                            int32_t err_len);
YT_EXPORT void yt_engine_unload_track(yt_engine* engine, int32_t slot);
YT_EXPORT void yt_engine_set_track_gain(yt_engine* engine, int32_t slot,
                                        float gain);
// Mixes the microphone into the output (0 = off).
YT_EXPORT void yt_engine_set_monitor_gain(yt_engine* engine, float gain);

YT_EXPORT void yt_engine_set_playing(yt_engine* engine, int32_t playing);
YT_EXPORT int32_t yt_engine_is_playing(yt_engine* engine);
YT_EXPORT void yt_engine_seek(yt_engine* engine, int64_t frame);
YT_EXPORT int64_t yt_engine_position(yt_engine* engine);
YT_EXPORT int64_t yt_engine_length(yt_engine* engine);
// Loops playback inside [start, end). Pass end <= start to disable.
YT_EXPORT void yt_engine_set_loop(yt_engine* engine, int64_t start,
                                  int64_t end);
// Number of times playback reached the end of the tracks (monotonic).
YT_EXPORT int64_t yt_engine_end_count(yt_engine* engine);

// Pops the next captured block (mono float32). Returns the number of frames
// copied into `out` (0 when nothing is pending). `out_song_frame` receives
// the song frame that was being rendered when the first sample was
// captured; `out_clock_frame` the engine's monotonic frame counter.
// `max_frames` must be >= 4096.
YT_EXPORT int32_t yt_engine_read_capture(yt_engine* engine, float* out,
                                         int32_t max_frames,
                                         int64_t* out_song_frame,
                                         int64_t* out_clock_frame,
                                         int32_t* out_flags);
YT_EXPORT int64_t yt_engine_capture_overruns(yt_engine* engine);
// Discards every pending captured block.
YT_EXPORT void yt_engine_flush_capture(yt_engine* engine);

// Audio-device events (bit 1: interrupted/rerouted/stopped, bit 2: interruption ended).
// signal() is for platform adapters; it atomically silences playback/capture.
// take() clears pending events. Restart only from the control thread, never a
// miniaudio notification callback. Callers must ask the user to resume playback.
YT_EXPORT void yt_engine_signal_audio_event(yt_engine* engine, int32_t events);
YT_EXPORT int32_t yt_engine_take_audio_events(yt_engine* engine);

// Runs the engine's audio callback directly (offline mode and tests).
// `out` receives interleaved stereo, `in` is mono; either may be NULL.
YT_EXPORT void yt_engine_render(yt_engine* engine, float* out, const float* in,
                                int32_t frames);

#ifdef __cplusplus
}
#endif

#endif  // YT_AUDIO_H
