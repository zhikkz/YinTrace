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

// Shows the system share sheet for a file (iOS). Returns 0 when the sheet
// was requested, -1 where there is none, -2 when the file does not exist.
YT_EXPORT int32_t yt_share_file(const char* path);

// ---------------------------------------------------------------------------
// Audio session / permissions (meaningful on iOS and macOS, no-ops elsewhere;
// Android asks for the microphone in YintraceAudioPlugin.java)
// ---------------------------------------------------------------------------

// 0 = not determined yet, 1 = granted, 2 = denied.
YT_EXPORT int32_t yt_mic_permission_status(void);
// Starts the asynchronous system permission prompt; poll the status.
YT_EXPORT void yt_request_mic_permission(void);
// Configures the shared audio session. `record` selects play-and-record,
// `measurement` disables system voice processing (AGC etc.) where possible.
YT_EXPORT int32_t yt_configure_session(int32_t record, int32_t measurement);
// Temporarily uses the recording session for calibration. Close the
// calibration device before ending the scope and restoring the session.
YT_EXPORT int32_t yt_begin_latency_calibration(int32_t measurement);
YT_EXPORT int32_t yt_end_latency_calibration(void);
// OS-reported input latency, output latency and I/O buffer, in seconds.
YT_EXPORT double yt_session_latency(void);
// The active output port type. Targets without a route query return UNKNOWN.
typedef enum yt_output_route_type {
  YT_OUTPUT_UNKNOWN = 0,
  YT_OUTPUT_SPEAKER = 1,
  YT_OUTPUT_WIRED = 2,
  YT_OUTPUT_USB = 3,
  YT_OUTPUT_BLUETOOTH = 4,
  YT_OUTPUT_AIRPLAY = 5,
} yt_output_route_type;
YT_EXPORT int32_t yt_output_route(void);
// Bytes this process can still allocate before the system terminates it
// (iOS: os_proc_available_memory). -1 where there is no such limit or it is
// unknown (other platforms, the simulator).
YT_EXPORT int64_t yt_available_memory(void);
// Hardware model identifier, e.g. "iPhone15,2" (Apple platforms). Writes a
// NUL-terminated string to `buf` and returns its length; 0 when unknown.
YT_EXPORT int32_t yt_device_model(char* buf, int32_t len);
// Installed physical memory in bytes; -1 when unknown.
YT_EXPORT int64_t yt_physical_memory(void);
// The system's thermal state: 0 nominal, 1 fair, 2 serious, 3 critical
// (the system slows the device down from "serious" on). -1 when unknown.
YT_EXPORT int32_t yt_thermal_state(void);

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
// The song frame at which a track's first frame plays (default 0; reset by
// loading the track). Before it the track is silent; a negative frame skips
// the track's beginning.
YT_EXPORT void yt_engine_set_track_offset(yt_engine* engine, int32_t slot, int64_t frame);
YT_EXPORT void yt_engine_set_track_gain(yt_engine* engine, int32_t slot,
                                        float gain);
// Whether this engine can monitor to a wired output (iOS headphones/USB).
// False on unsupported platforms and null devices; true offline for tests.
YT_EXPORT int32_t yt_engine_monitor_available(yt_engine* engine);
// Highest monitor gain, +24 dB. A phone mic hears singing at about
// -35..-15 dBFS RMS, 10-20 dB under a mastered accompaniment; the monitor
// chain compresses the voice and limits its peaks, so this much is safe.
#define YT_MONITOR_MAX_GAIN 16.0f
// Mixes the microphone into both output channels through the monitor chain
// (80 Hz high-pass, compressor, noise expander, peak limiter; see
// yt_monitor.h). `gain` is the linear gain after compression: 0 = off up to
// YT_MONITOR_MAX_GAIN; NaN, infinite or negative values mean off, larger
// ones are capped. Unavailable routes reject the gain. Route changes and
// stops clear it; the control thread must check the route before
// reapplying it. Captured audio stays the dry microphone.
YT_EXPORT void yt_engine_set_monitor_gain(yt_engine* engine, float gain);
// Allows monitoring during capture even when no track is playing. By
// default the gain is heard only during track playback.
YT_EXPORT void yt_engine_set_monitor_while_capturing(yt_engine* engine, int32_t enabled);

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

// Audio-device events, a bit set.
//   YT_EVENT_STOPPED: interrupted (a call, Siri, an alarm) or stopped by the
//     system. Playback and capture are silenced.
//   YT_EVENT_INTERRUPTION_ENDED: informational.
//   YT_EVENT_ROUTE_CHANGED: the audio route or its configuration changed
//     (iOS announces this when a session starts playing and recording, too).
//     Tracks keep playing; monitor gain is cleared until the route is checked.
//     The latency may differ.
//   YT_EVENT_DEVICE_LOST: headphones, a Bluetooth/USB device or AirPlay went
//     away, so the sound would now come from the phone. Playback and capture
//     are silenced at once.
//   YT_EVENT_ROUTE_PORTS_CHANGED: the active input or output ports differ.
//     On platforms that report port identities, distinguishes a new route
//     from a reconfiguration of the same ports at audio-device startup.
// signal() is for platform adapters; it atomically silences playback/capture
// for STOPPED and DEVICE_LOST. take() clears pending events. Restart only from
// the control thread, never a notification callback. After a silencing event,
// callers must ask the user to resume playback.
#define YT_EVENT_STOPPED 1
#define YT_EVENT_INTERRUPTION_ENDED 2
#define YT_EVENT_ROUTE_CHANGED 4
#define YT_EVENT_DEVICE_LOST 8
#define YT_EVENT_ROUTE_PORTS_CHANGED 16
#define YT_EVENTS_SILENCING (YT_EVENT_STOPPED | YT_EVENT_DEVICE_LOST)
YT_EXPORT void yt_engine_signal_audio_event(yt_engine* engine, int32_t events);
// Diagnostics: the last few audio-session events (iOS route changes with
// their reason, interruptions, engine signals), oldest first, one per line.
// Copies at most len-1 bytes plus a terminating NUL; returns the length.
YT_EXPORT int32_t yt_audio_log(char* buf, int32_t len);
YT_EXPORT void yt_audio_log_add(const char* line);
YT_EXPORT int32_t yt_engine_take_audio_events(yt_engine* engine);

// Runs the engine's audio callback directly (offline mode and tests).
// `out` receives interleaved stereo, `in` is mono; either may be NULL.
YT_EXPORT void yt_engine_render(yt_engine* engine, float* out, const float* in,
                                int32_t frames);

#ifdef __cplusplus
}
#endif

#endif  // YT_AUDIO_H
