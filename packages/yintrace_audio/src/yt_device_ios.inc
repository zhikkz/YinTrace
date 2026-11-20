// iOS full-duplex device for the practice engine: one RemoteIO unit.
// Included from yt_audio.c after struct yt_engine (iOS only, Objective-C).
//
// miniaudio's Core Audio duplex runs two RemoteIO units and hands the input
// to the output callback through a ring buffer that starts two periods full,
// so the live monitor reached the headphones about four periods (~46 ms at
// 512 frames) plus the hardware after it was sung. Here the output callback
// pulls the microphone of the same cycle with AudioUnitRender on the input
// element: one period in, one period out. The capture blocks are then tagged
// with the song frame rendered in the same callback, which is exactly what
// the latency compensation (input + output latency + two IO buffers)
// assumes.
//
// The unit runs at the hardware's sample rate (most iPhones keep 48 kHz
// whatever an app prefers, and RemoteIO is not reliable converting on the
// input side); yt_rate_bridge.h converts to and from the engine's 44.1 kHz
// in the callback. When the hardware rate changes (another route), the next
// start builds the unit again at the new rate; until then RemoteIO converts.
//
// Threads: the render callback runs on the real-time I/O thread and only
// touches engine atomics and preallocated buffers. Start, stop, rebuild and
// teardown run on the control thread (the Dart isolate). Notification
// observers (interruptions, media services reset) only set flags and signal
// engine events.

#include "yt_rate_bridge.h"

// Frames per callback at most: 4096 while the screen is locked, more when
// RemoteIO converts after a route changed the hardware rate (QA1777).
#define YT_RIO_MAX_FRAMES 8192
#define YT_RIO_OUTPUT_BUS 0
#define YT_RIO_INPUT_BUS 1

typedef struct {
  yt_engine* engine;
  AudioUnit unit;
  ma_uint32 device_rate;  // the unit's client rate (the hardware's when built)
  int bridged;            // device_rate differs from the engine's
  yt_rate_bridge bridge;
  float* input;   // mono microphone at the device rate, YT_RIO_MAX_FRAMES
  float* output;  // interleaved stereo scratch, YT_RIO_MAX_FRAMES
  volatile ma_uint32 input_errors;  // cycles without the microphone (audio thread)
  volatile ma_int32 last_input_error;
  volatile ma_uint32 frames;        // size of the last cycle
  volatile ma_uint32 restart;       // the system stopped the I/O (an interruption)
  volatile ma_uint32 rebuild;       // media services were reset: the unit is dead
} yt_rio;

// Renders `frames` device frames of engine output (with this cycle's
// microphone) into interleaved stereo `out`.
static void yt_rio_run_engine(yt_rio* r, float* out, UInt32 frames) {
  if (r->bridged) {
    yt_rate_bridge_render(&r->bridge, r->engine, out, r->input, frames);
  } else {
    yt_engine_render(r->engine, out, r->input, (int32_t)frames);
  }
}

static OSStatus yt_rio_render(void* ref, AudioUnitRenderActionFlags* flags, const AudioTimeStamp* ts,
                              UInt32 bus, UInt32 frames, AudioBufferList* io) {
  yt_rio* r = (yt_rio*)ref;
  (void)bus;
  (void)flags;
  if (io == NULL) return noErr;
  if (frames == 0 || frames > YT_RIO_MAX_FRAMES) {
    for (UInt32 b = 0; b < io->mNumberBuffers; b++) {
      if (io->mBuffers[b].mData != NULL) memset(io->mBuffers[b].mData, 0, io->mBuffers[b].mDataByteSize);
    }
    return noErr;
  }

  // The microphone of this very cycle.
  AudioBufferList in;
  in.mNumberBuffers = 1;
  in.mBuffers[0].mNumberChannels = 1;
  in.mBuffers[0].mDataByteSize = frames * (UInt32)sizeof(float);
  in.mBuffers[0].mData = r->input;
  AudioUnitRenderActionFlags in_flags = 0;
  OSStatus st = AudioUnitRender(r->unit, &in_flags, ts, YT_RIO_INPUT_BUS, frames, &in);
  if (st != noErr) {
    // No input this cycle (the route has none yet, the unit is restarting):
    // silence keeps the capture stream and its song tags continuous.
    memset(r->input, 0, (size_t)frames * sizeof(float));
    ma_atomic_fetch_add_32(&r->input_errors, 1);
    ma_atomic_store_i32(&r->last_input_error, (ma_int32)st);
  }
  ma_atomic_store_32(&r->frames, frames);

  // The client format is interleaved stereo float: one buffer, two channels.
  if (io->mNumberBuffers == 1 && io->mBuffers[0].mNumberChannels == 2 && io->mBuffers[0].mData != NULL &&
      io->mBuffers[0].mDataByteSize >= frames * 2 * (UInt32)sizeof(float)) {
    yt_rio_run_engine(r, (float*)io->mBuffers[0].mData, frames);
    return noErr;
  }
  yt_rio_run_engine(r, r->output, frames);
  for (UInt32 b = 0; b < io->mNumberBuffers; b++) {
    float* dst = (float*)io->mBuffers[b].mData;
    UInt32 ch = io->mBuffers[b].mNumberChannels;
    if (dst == NULL || ch == 0) continue;
    UInt32 n = io->mBuffers[b].mDataByteSize / (ch * (UInt32)sizeof(float));
    if (n > frames) n = frames;
    // Non-interleaved: buffer b is channel b. Interleaved with more channels:
    // left and right first, the rest silent.
    for (UInt32 i = 0; i < n; i++) {
      for (UInt32 c = 0; c < ch; c++) {
        UInt32 src = io->mNumberBuffers > 1 ? b : c;
        dst[i * ch + c] = src < 2 ? r->output[2 * i + src] : 0.0f;
      }
    }
  }
  return noErr;
}

// Called by Core Audio (any thread) whenever the unit starts or stops.
static void yt_rio_running_changed(void* ref, AudioUnit unit, AudioUnitPropertyID id, AudioUnitScope scope,
                                   AudioUnitElement element) {
  yt_rio* r = (yt_rio*)ref;
  (void)id;
  (void)scope;
  (void)element;
  UInt32 running = 0;
  UInt32 size = sizeof(running);
  if (AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running,
                           &size) != noErr) {
    return;
  }
  // `running_requested` stays set until the control thread asks to stop, so
  // a stop we asked for is never mistaken for the system's, however late
  // Core Audio reports it.
  if (!running && ma_atomic_load_32(&r->engine->running_requested)) {
    yt_audio_log_add("device: stopped by the system");
    ma_atomic_store_32(&r->restart, 1);
    yt_engine_signal_audio_event(r->engine, YT_EVENT_STOPPED);
  }
}

// The hardware's current rate in Hz (0 when unknown).
static ma_uint32 yt_rio_hardware_rate(void) {
  double rate = [AVAudioSession sharedInstance].sampleRate;
  return rate >= 8000.0 && rate <= 384000.0 ? (ma_uint32)lround(rate) : 0;
}

static void yt_rio_teardown(yt_rio* r) {
  if (r->unit != NULL) {
    AudioOutputUnitStop(r->unit);
    AudioUnitRemovePropertyListenerWithUserData(r->unit, kAudioOutputUnitProperty_IsRunning, yt_rio_running_changed,
                                                r);
    AudioUnitUninitialize(r->unit);
    AudioComponentInstanceDispose(r->unit);
    r->unit = NULL;
  }
  if (r->bridged) yt_rate_bridge_uninit(&r->bridge);
  r->bridged = 0;
}

// Creates and initializes the unit with client formats at `rate`. Returns a
// short reason on failure.
static const char* yt_rio_create_unit(yt_rio* r, ma_uint32 rate) {
  AudioComponentDescription desc;
  memset(&desc, 0, sizeof(desc));
  desc.componentType = kAudioUnitType_Output;
  desc.componentSubType = kAudioUnitSubType_RemoteIO;
  desc.componentManufacturer = kAudioUnitManufacturer_Apple;
  AudioComponent component = AudioComponentFindNext(NULL, &desc);
  if (component == NULL) return "no RemoteIO component";
  AudioUnit unit = NULL;
  if (AudioComponentInstanceNew(component, &unit) != noErr || unit == NULL) return "cannot create RemoteIO";

  const char* failed = NULL;
  UInt32 one = 1;
  if (AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, YT_RIO_INPUT_BUS, &one,
                           sizeof(one)) != noErr) {
    failed = "cannot enable input";
  }
  if (!failed && AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
                                      YT_RIO_OUTPUT_BUS, &one, sizeof(one)) != noErr) {
    failed = "cannot enable output";
  }
  // Float formats on the app side of both elements, at the hardware rate.
  AudioStreamBasicDescription out_fmt, in_fmt;
  yt_client_format(&out_fmt, (double)rate, 2);
  yt_client_format(&in_fmt, (double)rate, 1);
  if (!failed && AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, YT_RIO_OUTPUT_BUS,
                                      &out_fmt, sizeof(out_fmt)) != noErr) {
    failed = "output format rejected";
  }
  if (!failed && AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, YT_RIO_INPUT_BUS,
                                      &in_fmt, sizeof(in_fmt)) != noErr) {
    failed = "input format rejected";
  }
  UInt32 max_frames = YT_RIO_MAX_FRAMES;
  if (!failed && AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                      &max_frames, sizeof(max_frames)) != noErr) {
    failed = "cannot set the slice size";
  }
  if (!failed) {
    // The input is rendered into our own buffer (an optimisation only).
    UInt32 zero = 0;
    AudioUnitSetProperty(unit, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, YT_RIO_INPUT_BUS,
                         &zero, sizeof(zero));
    AURenderCallbackStruct cb;
    cb.inputProc = yt_rio_render;
    cb.inputProcRefCon = r;
    if (AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, YT_RIO_OUTPUT_BUS,
                             &cb, sizeof(cb)) != noErr) {
      failed = "cannot set the render callback";
    }
  }
  if (!failed && AudioUnitAddPropertyListener(unit, kAudioOutputUnitProperty_IsRunning, yt_rio_running_changed, r) !=
                     noErr) {
    failed = "cannot watch the running state";
  }
  if (!failed && AudioUnitInitialize(unit) != noErr) failed = "cannot initialize RemoteIO";
  if (failed) {
    AudioUnitRemovePropertyListenerWithUserData(unit, kAudioOutputUnitProperty_IsRunning, yt_rio_running_changed, r);
    AudioComponentInstanceDispose(unit);
    return failed;
  }
  r->unit = unit;
  return NULL;
}

static void yt_rio_log_route(yt_rio* r, const char* what) {
  AVAudioSession* session = [AVAudioSession sharedInstance];
  char line[112];
  snprintf(line, sizeof(line), "rio: %s at %u Hz (hw %.0f), io %.1f ms, in %.1f ms, out %.1f ms", what,
           (unsigned)r->device_rate, session.sampleRate, session.IOBufferDuration * 1000.0,
           session.inputLatency * 1000.0, session.outputLatency * 1000.0);
  yt_audio_log_add(line);
}

// Builds the unit (and the rate bridge) for the hardware's current rate.
static const char* yt_rio_setup(yt_rio* r) {
  const ma_uint32 engine_rate = (ma_uint32)r->engine->sample_rate;
  ma_uint32 rate = yt_rio_hardware_rate();
  if (rate == 0) rate = engine_rate;
  r->device_rate = rate;
  const char* failed = yt_rio_create_unit(r, rate);
  if (failed != NULL) return failed;
  if (rate != engine_rate) {
    if (!yt_rate_bridge_init(&r->bridge, engine_rate, rate, YT_RIO_MAX_FRAMES)) {
      yt_rio_teardown(r);
      return "cannot convert the sample rate";
    }
    r->bridged = 1;
  }
  return NULL;
}

static void yt_rio_free(yt_rio* r) {
  if (r == NULL) return;
  free(r->input);
  free(r->output);
  free(r);
}

static int yt_platform_device_init(yt_engine* e) {
  yt_rio* r = (yt_rio*)calloc(1, sizeof(yt_rio));
  if (r == NULL) return 0;
  r->engine = e;
  r->input = (float*)calloc(YT_RIO_MAX_FRAMES, sizeof(float));
  r->output = (float*)calloc(YT_RIO_MAX_FRAMES * 2, sizeof(float));
  if (r->input == NULL || r->output == NULL) {
    yt_rio_free(r);
    return 0;
  }
  const char* failed = NULL;
  @autoreleasepool {
    failed = yt_rio_setup(r);
    if (failed == NULL) yt_rio_log_route(r, "ready");
  }
  if (failed != NULL) {
    // miniaudio runs the device instead (the latency of before).
    char line[112];
    snprintf(line, sizeof(line), "rio: %s, using miniaudio duplex", failed);
    yt_audio_log_add(line);
    yt_rio_free(r);
    return 0;
  }
  e->platform_device = r;
  return 1;
}

static int32_t yt_platform_device_start(yt_engine* e) {
  yt_rio* r = (yt_rio*)e->platform_device;
  @autoreleasepool {
    // After a media services reset the old unit no longer works; after a
    // route change to another hardware rate a new unit avoids RemoteIO's
    // own conversion.
    ma_uint32 rate = yt_rio_hardware_rate();
    int reset = ma_atomic_exchange_32(&r->rebuild, 0) != 0;
    if (reset || r->unit == NULL || (rate != 0 && rate != r->device_rate)) {
      ma_atomic_store_32(&e->running_requested, 0);
      yt_rio_teardown(r);
      ma_atomic_store_32(&r->restart, 0);
      const char* failed = yt_rio_setup(r);
      if (failed != NULL) {
        char line[112];
        snprintf(line, sizeof(line), "rio: %s", failed);
        yt_audio_log_add(line);
        ma_atomic_store_32(&r->rebuild, 1);  // try again on the next start
        return -2;
      }
      yt_rio_log_route(r, reset ? "rebuilt" : "new rate");
    }
  }
  if (ma_atomic_exchange_32(&r->restart, 0)) {
    // The system stopped the I/O (an interruption): stop the unit for real
    // so that starting it is not a no-op on a unit that thinks it runs.
    ma_atomic_store_32(&e->running_requested, 0);
    AudioOutputUnitStop(r->unit);
  }
  ma_atomic_store_32(&e->running_requested, 1);
  OSStatus st = AudioOutputUnitStart(r->unit);
  if (st != noErr) {
    ma_atomic_store_32(&e->running_requested, 0);
    char line[64];
    snprintf(line, sizeof(line), "rio: start failed (%d)", (int)st);
    yt_audio_log_add(line);
    return -2;
  }
  return 0;
}

static int32_t yt_platform_device_stop(yt_engine* e) {
  yt_rio* r = (yt_rio*)e->platform_device;
  ma_atomic_store_32(&e->running_requested, 0);
  OSStatus st = r->unit != NULL ? AudioOutputUnitStop(r->unit) : noErr;
  ma_uint32 missed = ma_atomic_exchange_32(&r->input_errors, 0);
  if (missed > 0) {
    char line[96];
    snprintf(line, sizeof(line), "rio: %u cycles without the microphone (last error %d)", (unsigned)missed,
             (int)ma_atomic_load_i32(&r->last_input_error));
    yt_audio_log_add(line);
  }
  if (r->bridged && (r->bridge.underflows > 0 || r->bridge.overflows > 0)) {
    // Read after the unit stopped, so the audio thread is not writing them.
    char line[96];
    snprintf(line, sizeof(line), "rio: rate bridge under/overflows %u/%u", (unsigned)r->bridge.underflows,
             (unsigned)r->bridge.overflows);
    yt_audio_log_add(line);
    r->bridge.underflows = 0;
    r->bridge.overflows = 0;
  }
  return st == noErr ? 0 : -2;
}

static void yt_platform_device_uninit(yt_engine* e) {
  yt_rio* r = (yt_rio*)e->platform_device;
  if (r == NULL) return;
  ma_atomic_store_32(&e->running_requested, 0);
  yt_rio_teardown(r);
  e->platform_device = NULL;
  yt_rio_free(r);
}

static int32_t yt_platform_device_period_frames(yt_engine* e) {
  yt_rio* r = (yt_rio*)e->platform_device;
  double seconds = [AVAudioSession sharedInstance].IOBufferDuration;
  if (seconds > 0) return (int32_t)lround(seconds * (double)e->sample_rate);
  ma_uint32 frames = ma_atomic_load_32(&r->frames);
  return r->device_rate > 0 ? (int32_t)((ma_uint64)frames * (ma_uint64)e->sample_rate / r->device_rate) : 0;
}

// Observers (yt_platform_apple.inc), under the route lock.
static void yt_platform_device_interrupted(yt_engine* e, int began) {
  yt_rio* r = (yt_rio*)e->platform_device;
  if (r == NULL) return;  // miniaudio reports its own interruptions
  if (began) {
    ma_atomic_store_32(&r->restart, 1);
    yt_engine_signal_audio_event(e, YT_EVENT_STOPPED);
  } else {
    yt_engine_signal_audio_event(e, YT_EVENT_INTERRUPTION_ENDED);
  }
}

static void yt_platform_device_media_reset(yt_engine* e) {
  yt_rio* r = (yt_rio*)e->platform_device;
  if (r == NULL) return;
  ma_atomic_store_32(&r->rebuild, 1);
  yt_engine_signal_audio_event(e, YT_EVENT_STOPPED);
}
