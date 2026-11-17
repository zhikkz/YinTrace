// Apple platform layer for yt_audio.c (compiled as Objective-C, ARC).
// Included only when __APPLE__ and __OBJC__ are defined.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <sys/sysctl.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#include <os/lock.h>
#include <os/proc.h>
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

int32_t yt_mic_permission_status(void) {
#if TARGET_OS_IOS
  switch ([[AVAudioSession sharedInstance] recordPermission]) {
    case AVAudioSessionRecordPermissionGranted:
      return 1;
    case AVAudioSessionRecordPermissionDenied:
      return 2;
    default:
      return 0;
  }
#elif TARGET_OS_OSX
  switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]) {
    case AVAuthorizationStatusAuthorized:
      return 1;
    case AVAuthorizationStatusDenied:
    case AVAuthorizationStatusRestricted:
      return 2;
    default:
      return 0;
  }
#else
  return 1;
#endif
}

void yt_request_mic_permission(void) {
#if TARGET_OS_IOS
  [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
    (void)granted;
  }];
#elif TARGET_OS_OSX
  [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                           completionHandler:^(BOOL granted) {
                             (void)granted;
                           }];
#endif
}

int32_t yt_configure_session(int32_t record, int32_t measurement) {
#if TARGET_OS_IOS
  @autoreleasepool {
    AVAudioSession* session = [AVAudioSession sharedInstance];
    NSError* error = nil;
    // Speaker by default (instead of the earpiece), high quality output to
    // Bluetooth headphones while the iPhone microphone is used for input.
    AVAudioSessionCategory category =
        record ? AVAudioSessionCategoryPlayAndRecord : AVAudioSessionCategoryPlayback;
    AVAudioSessionMode mode =
        record && measurement ? AVAudioSessionModeMeasurement : AVAudioSessionModeDefault;
    AVAudioSessionCategoryOptions options =
        record ? (AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetoothA2DP)
               : 0;
    // Called before every play: change only what differs, since each change
    // makes iOS reconfigure the route of a session that may be running.
    if (![session.category isEqualToString:category] || ![session.mode isEqualToString:mode] ||
        session.categoryOptions != options) {
      if (![session setCategory:category mode:mode options:options error:&error]) return -2;
    }
    if (session.preferredSampleRate != 44100.0) [session setPreferredSampleRate:44100.0 error:nil];
    // The engine's device asks for 10 ms periods (see yt_engine_create); the
    // same value here keeps the two from undoing each other.
    if (fabs(session.preferredIOBufferDuration - 0.01) > 0.0005) {
      [session setPreferredIOBufferDuration:0.01 error:nil];
    }
    if (![session setActive:YES error:&error]) return -3;
    return 0;
  }
#else
  (void)record;
  (void)measurement;
  return 0;
#endif
}

// Route changes. iOS posts AVAudioSessionRouteChangeNotification for many
// reasons, including the category being applied and the route being
// reconfigured when a session starts playing and recording: those must not
// stop practice. Only a lost private output (headphones unplugged, Bluetooth
// disconnected) pauses, so the song does not continue from the speaker.
static int32_t yt_platform_monitor_available(void) {
#if TARGET_OS_IOS
  // Check every output: the phone speaker, Bluetooth, AirPlay, or an unknown route
  // must never receive the live microphone. USB includes wired headsets
  // and Lightning/USB-C audio adapters.
  NSArray<AVAudioSessionPortDescription*>* outputs = [[AVAudioSession sharedInstance] currentRoute].outputs;
  if (outputs.count == 0) return 0;
  for (AVAudioSessionPortDescription* port in outputs) {
    if (![port.portType isEqualToString:AVAudioSessionPortHeadphones] &&
        ![port.portType isEqualToString:AVAudioSessionPortUSBAudio]) return 0;
  }
  return 1;
#else
  return 0;
#endif
}

#if TARGET_OS_IOS
#define YT_ROUTE_WATCH_SLOTS 8
static os_unfair_lock yt_route_lock = OS_UNFAIR_LOCK_INIT;
static yt_engine* yt_route_engines[YT_ROUTE_WATCH_SLOTS];

static BOOL yt_is_private_output(AVAudioSessionPortDescription* port) {
  return ![port.portType isEqualToString:AVAudioSessionPortBuiltInSpeaker] &&
         ![port.portType isEqualToString:AVAudioSessionPortBuiltInReceiver];
}

// Whether a private output of `previous` is missing from `current`.
static BOOL yt_lost_private_output(AVAudioSessionRouteDescription* previous,
                                   AVAudioSessionRouteDescription* current) {
  for (AVAudioSessionPortDescription* old in previous.outputs) {
    if (!yt_is_private_output(old)) continue;
    BOOL kept = NO;
    for (AVAudioSessionPortDescription* now in current.outputs) {
      if ([now.UID isEqualToString:old.UID]) kept = YES;
    }
    if (!kept) return YES;
  }
  return NO;
}

static const char* yt_route_reason_name(NSInteger reason) {
  switch (reason) {
    case AVAudioSessionRouteChangeReasonNewDeviceAvailable: return "NewDeviceAvailable";
    case AVAudioSessionRouteChangeReasonOldDeviceUnavailable: return "OldDeviceUnavailable";
    case AVAudioSessionRouteChangeReasonCategoryChange: return "CategoryChange";
    case AVAudioSessionRouteChangeReasonOverride: return "Override";
    case AVAudioSessionRouteChangeReasonWakeFromSleep: return "WakeFromSleep";
    case AVAudioSessionRouteChangeReasonNoSuitableRouteForCategory: return "NoSuitableRoute";
    case AVAudioSessionRouteChangeReasonRouteConfigurationChange: return "RouteConfigurationChange";
    default: return "Unknown";
  }
}

// "12:03:04.512 " (local time).
static void yt_log_with_time(NSString* text) {
  NSDate* now = [NSDate date];
  NSDateFormatter* f = [[NSDateFormatter alloc] init];
  f.dateFormat = @"HH:mm:ss.SSS";
  NSString* line = [NSString stringWithFormat:@"%@ %@", [f stringFromDate:now], text];
  yt_audio_log_add(line.UTF8String);
}

static void yt_route_changed(NSNotification* note) {
  NSInteger reason = [note.userInfo[AVAudioSessionRouteChangeReasonKey] integerValue];
  int32_t events = YT_EVENT_ROUTE_CHANGED;
  AVAudioSessionRouteDescription* current = [[AVAudioSession sharedInstance] currentRoute];
  if (reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
    id previous = note.userInfo[AVAudioSessionRouteChangePreviousRouteKey];
    if ([previous isKindOfClass:[AVAudioSessionRouteDescription class]] &&
        yt_lost_private_output(previous, current)) {
      events |= YT_EVENT_DEVICE_LOST;
    }
  } else if (reason == AVAudioSessionRouteChangeReasonNoSuitableRouteForCategory) {
    events |= YT_EVENT_STOPPED;
  }
  NSMutableArray<NSString*>* outputs = [NSMutableArray array];
  for (AVAudioSessionPortDescription* port in current.outputs) [outputs addObject:port.portType];
  yt_log_with_time([NSString stringWithFormat:@"route %s -> %@%s", yt_route_reason_name(reason),
                                              [outputs componentsJoinedByString:@"+"],
                                              (events & YT_EVENT_DEVICE_LOST) ? " (paused: output lost)" : ""]);
  // Signalling under the lock: an engine is never destroyed while in use.
  int32_t monitor_available = yt_platform_monitor_available();
  os_unfair_lock_lock(&yt_route_lock);
  for (int i = 0; i < YT_ROUTE_WATCH_SLOTS; i++) {
    if (yt_route_engines[i] != NULL) {
      yt_update_monitor_route(yt_route_engines[i], monitor_available);
      yt_engine_signal_audio_event(yt_route_engines[i], events);
    }
  }
  os_unfair_lock_unlock(&yt_route_lock);
}

static void yt_platform_watch_routes(yt_engine* e) {
  // One observer for the life of the process, so that it can never be
  // released while a notification is being delivered on another thread.
  static dispatch_once_t once;
  static id observer, interruptions;
  dispatch_once(&once, ^{
    observer = [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
                                                                 object:nil
                                                                  queue:nil
                                                             usingBlock:^(NSNotification* note) {
                                                               yt_route_changed(note);
                                                             }];
    // Logged only (miniaudio handles interruptions).
    interruptions = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVAudioSessionInterruptionNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification* note) {
                  NSInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] integerValue];
                  BOOL suspended = [note.userInfo[AVAudioSessionInterruptionWasSuspendedKey] boolValue];
                  yt_log_with_time([NSString stringWithFormat:@"interruption %s%s",
                                                              type == AVAudioSessionInterruptionTypeBegan ? "began"
                                                                                                          : "ended",
                                                              suspended ? " (app was suspended)" : ""]);
                }];
  });
  yt_log_with_time(@"engine watching routes");
  os_unfair_lock_lock(&yt_route_lock);
  for (int i = 0; i < YT_ROUTE_WATCH_SLOTS; i++) {
    if (yt_route_engines[i] == NULL) {
      yt_route_engines[i] = e;
      yt_update_monitor_route(e, yt_platform_monitor_available());
      break;
    }
  }
  os_unfair_lock_unlock(&yt_route_lock);
}

static void yt_platform_unwatch_routes(yt_engine* e) {
  os_unfair_lock_lock(&yt_route_lock);
  for (int i = 0; i < YT_ROUTE_WATCH_SLOTS; i++) {
    if (yt_route_engines[i] == e) yt_route_engines[i] = NULL;
  }
  os_unfair_lock_unlock(&yt_route_lock);
}
#else
// macOS: miniaudio follows the default device; its reroutes are reported as
// YT_EVENT_ROUTE_CHANGED.
static void yt_platform_watch_routes(yt_engine* e) { (void)e; }
static void yt_platform_unwatch_routes(yt_engine* e) { (void)e; }
#endif

double yt_session_latency(void) {
#if TARGET_OS_IOS
  AVAudioSession* session = [AVAudioSession sharedInstance];
  return session.inputLatency + session.outputLatency + session.IOBufferDuration;
#else
  return 0.0;
#endif
}

int64_t yt_available_memory(void) {
#if TARGET_OS_IOS && !TARGET_OS_SIMULATOR
  // 0 means the process has no limit; report it as unknown.
  size_t available = os_proc_available_memory();
  return available > 0 ? (int64_t)available : -1;
#else
  return -1;
#endif
}

#pragma clang diagnostic pop

int32_t yt_device_model(char* buf, int32_t len) {
  if (buf == NULL || len <= 0) return 0;
  buf[0] = '\0';
#if TARGET_OS_OSX
  const char* key = "hw.model";  // "hw.machine" is only the CPU architecture there
#else
  const char* key = "hw.machine";  // the simulator reports the host's architecture
#endif
  size_t size = (size_t)len;
  if (sysctlbyname(key, buf, &size, NULL, 0) != 0) {
    buf[0] = '\0';
    return 0;
  }
  buf[len - 1] = '\0';
  return (int32_t)strlen(buf);
}

int64_t yt_physical_memory(void) {
  return (int64_t)[[NSProcessInfo processInfo] physicalMemory];
}

int32_t yt_thermal_state(void) {
  switch ([[NSProcessInfo processInfo] thermalState]) {
    case NSProcessInfoThermalStateNominal:
      return 0;
    case NSProcessInfoThermalStateFair:
      return 1;
    case NSProcessInfoThermalStateSerious:
      return 2;
    case NSProcessInfoThermalStateCritical:
      return 3;
  }
  return -1;
}

#if TARGET_OS_IOS
// The view controller on top of the app's window (main thread only).
static UIViewController* yt_top_view_controller(void) {
  UIWindow* window = nil;
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:[UIWindowScene class]]) continue;
    for (UIWindow* w in ((UIWindowScene*)scene).windows) {
      if (w.isKeyWindow) {
        window = w;
        break;
      }
      if (window == nil) window = w;
    }
    if (window != nil && window.isKeyWindow) break;
  }
  UIViewController* top = window.rootViewController;
  while (top.presentedViewController != nil) top = top.presentedViewController;
  return top;
}
#endif

int32_t yt_share_file(const char* path) {
#if TARGET_OS_IOS
  if (path == NULL) return -2;
  NSString* p = [NSString stringWithUTF8String:path];
  if (p == nil || ![[NSFileManager defaultManager] fileExistsAtPath:p]) return -2;
  dispatch_async(dispatch_get_main_queue(), ^{
    UIViewController* top = yt_top_view_controller();
    if (top == nil) return;
    UIActivityViewController* sheet =
        [[UIActivityViewController alloc] initWithActivityItems:@[ [NSURL fileURLWithPath:p] ]
                                          applicationActivities:nil];
    // iPad shows the sheet as a popover, which needs an anchor.
    UIPopoverPresentationController* pop = sheet.popoverPresentationController;
    if (pop != nil) {
      pop.sourceView = top.view;
      pop.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMaxY(top.view.bounds) - 80, 1, 1);
    }
    [top presentViewController:sheet animated:YES completion:nil];
  });
  return 0;
#else
  (void)path;
  return -1;
#endif
}

int32_t yt_exclude_from_backup(const char* path) {
  if (path == NULL) return -1;
  @autoreleasepool {
    NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    NSError* error = nil;
    BOOL ok = [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&error];
    return ok ? 0 : -2;
  }
}

static void yt_client_format(AudioStreamBasicDescription* f, double rate, UInt32 channels) {
  memset(f, 0, sizeof(*f));
  f->mSampleRate = rate;
  f->mFormatID = kAudioFormatLinearPCM;
  f->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
  f->mBitsPerChannel = 32;
  f->mChannelsPerFrame = channels;
  f->mFramesPerPacket = 1;
  f->mBytesPerFrame = 4 * channels;
  f->mBytesPerPacket = f->mBytesPerFrame;
}

// Decodes any format Core Audio understands (mp3, aac/m4a, alac, wav, aiff,
// caf, flac). Returns NULL on failure so the caller can fall back.
static float* yt_apple_decode(const char* path, int32_t sample_rate, int32_t channels,
                              int64_t* out_frames, char* err, int32_t err_len) {
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8*)path,
                                                         (CFIndex)strlen(path), false);
  if (url == NULL) {
    yt_set_err(err, err_len, "invalid path");
    return NULL;
  }
  ExtAudioFileRef file = NULL;
  OSStatus st = ExtAudioFileOpenURL(url, &file);
  CFRelease(url);
  if (st != noErr || file == NULL) {
    yt_set_err(err, err_len, "ExtAudioFileOpenURL failed");
    return NULL;
  }

  AudioStreamBasicDescription file_fmt;
  UInt32 size = sizeof(file_fmt);
  st = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &file_fmt);
  if (st != noErr || file_fmt.mChannelsPerFrame == 0) {
    ExtAudioFileDispose(file);
    yt_set_err(err, err_len, "cannot read file format");
    return NULL;
  }
  SInt64 file_frames = 0;
  size = sizeof(file_frames);
  ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &file_frames);

  // Decode with the file's own channel count (capped at 2) and convert
  // channels ourselves; Core Audio's default up/down-mix maps are not
  // guaranteed to duplicate mono into both channels.
  UInt32 client_channels = file_fmt.mChannelsPerFrame >= 2 ? 2 : 1;
  AudioStreamBasicDescription client;
  yt_client_format(&client, (double)sample_rate, client_channels);
  st = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
  if (st != noErr) {
    ExtAudioFileDispose(file);
    yt_set_err(err, err_len, "cannot set client format");
    return NULL;
  }

  yt_fbuf b = {NULL, 0, 0, channels};
  if (file_frames > 0 && file_fmt.mSampleRate > 0) {
    double est = (double)file_frames * (double)sample_rate / file_fmt.mSampleRate;
    yt_fbuf_reserve(&b, (int64_t)est + 8192);
  }
  const UInt32 chunk = 16384;
  float* tmp = (float*)malloc((size_t)chunk * client_channels * sizeof(float));
  if (tmp == NULL) {
    ExtAudioFileDispose(file);
    free(b.data);
    yt_set_err(err, err_len, "out of memory");
    return NULL;
  }
  for (;;) {
    AudioBufferList abl;
    abl.mNumberBuffers = 1;
    abl.mBuffers[0].mNumberChannels = client_channels;
    abl.mBuffers[0].mDataByteSize = chunk * client_channels * sizeof(float);
    abl.mBuffers[0].mData = tmp;
    UInt32 n = chunk;
    st = ExtAudioFileRead(file, &n, &abl);
    if (st != noErr) {
      free(tmp);
      ExtAudioFileDispose(file);
      free(b.data);
      yt_set_err(err, err_len, "ExtAudioFileRead failed");
      return NULL;
    }
    if (n == 0) break;
    if (!yt_fbuf_append(&b, tmp, (int64_t)n, (int32_t)client_channels)) {
      free(tmp);
      ExtAudioFileDispose(file);
      free(b.data);
      yt_set_err(err, err_len, "out of memory");
      return NULL;
    }
  }
  free(tmp);
  ExtAudioFileDispose(file);
  if (b.frames == 0) {
    free(b.data);
    yt_set_err(err, err_len, "file contains no audio frames");
    return NULL;
  }
  *out_frames = b.frames;
  return b.data;
}

int32_t yt_encode_m4a(const char* path, const float* data, int64_t frames, int32_t sample_rate,
                      int32_t channels, int32_t bitrate) {
  if (path == NULL || data == NULL || frames <= 0 || (channels != 1 && channels != 2)) return -2;
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8*)path,
                                                         (CFIndex)strlen(path), false);
  if (url == NULL) return -3;

  AudioStreamBasicDescription out_fmt;
  memset(&out_fmt, 0, sizeof(out_fmt));
  out_fmt.mFormatID = kAudioFormatMPEG4AAC;
  out_fmt.mSampleRate = (double)sample_rate;
  out_fmt.mChannelsPerFrame = (UInt32)channels;
  out_fmt.mFramesPerPacket = 1024;

  ExtAudioFileRef file = NULL;
  OSStatus st = ExtAudioFileCreateWithURL(url, kAudioFileM4AType, &out_fmt, NULL,
                                          kAudioFileFlags_EraseFile, &file);
  CFRelease(url);
  if (st != noErr || file == NULL) return -4;

  AudioStreamBasicDescription client;
  yt_client_format(&client, (double)sample_rate, (UInt32)channels);
  st = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
  if (st != noErr) {
    ExtAudioFileDispose(file);
    return -5;
  }

  if (bitrate > 0) {
    AudioConverterRef conv = NULL;
    UInt32 size = sizeof(conv);
    if (ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &conv) == noErr &&
        conv != NULL) {
      UInt32 br = (UInt32)bitrate;
      if (AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, sizeof(br), &br) == noErr) {
        CFArrayRef config = NULL;
        ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig, sizeof(config), &config);
      }
    }
  }

  const int64_t chunk = 8192;
  int64_t written = 0;
  while (written < frames) {
    int64_t n = frames - written;
    if (n > chunk) n = chunk;
    AudioBufferList abl;
    abl.mNumberBuffers = 1;
    abl.mBuffers[0].mNumberChannels = (UInt32)channels;
    abl.mBuffers[0].mDataByteSize = (UInt32)(n * channels * (int64_t)sizeof(float));
    abl.mBuffers[0].mData = (void*)(data + written * channels);
    st = ExtAudioFileWrite(file, (UInt32)n, &abl);
    if (st != noErr) {
      ExtAudioFileDispose(file);
      return -6;
    }
    written += n;
  }
  st = ExtAudioFileDispose(file);
  return st == noErr ? 0 : -7;
}
