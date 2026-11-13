// Apple platform layer for yt_audio.c (compiled as Objective-C, ARC).
// Included only when __APPLE__ and __OBJC__ are defined.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

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
    BOOL ok;
    if (record) {
      // Speaker by default (instead of the earpiece), high quality output to
      // Bluetooth headphones while the iPhone microphone is used for input.
      AVAudioSessionCategoryOptions options = AVAudioSessionCategoryOptionDefaultToSpeaker |
                                              AVAudioSessionCategoryOptionAllowBluetoothA2DP;
      ok = [session setCategory:AVAudioSessionCategoryPlayAndRecord
                           mode:(measurement ? AVAudioSessionModeMeasurement : AVAudioSessionModeDefault)
                        options:options
                          error:&error];
    } else {
      ok = [session setCategory:AVAudioSessionCategoryPlayback
                           mode:AVAudioSessionModeDefault
                        options:0
                          error:&error];
    }
    if (!ok) return -2;
    [session setPreferredSampleRate:44100.0 error:nil];
    [session setPreferredIOBufferDuration:0.005 error:nil];
    if (![session setActive:YES error:&error]) return -3;
    return 0;
  }
#else
  (void)record;
  (void)measurement;
  return 0;
#endif
}

double yt_session_latency(void) {
#if TARGET_OS_IOS
  AVAudioSession* session = [AVAudioSession sharedInstance];
  return session.inputLatency + session.outputLatency + session.IOBufferDuration;
#else
  return 0.0;
#endif
}

#pragma clang diagnostic pop

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
