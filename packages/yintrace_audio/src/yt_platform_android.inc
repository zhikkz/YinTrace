// Android decoding through the NDK media APIs (libmediandk), included by
// yt_audio.c. miniaudio keeps reading WAV, FLAC and MP3; this reads AAC in
// MP4/M4A or ADTS and the other formats the platform's extractors know.
//
// The extractor's track format is handed to the decoder unchanged, so the
// platform trims the encoder delay an MP4 states (its edit list). It keeps
// the padding after the end: up to about two AAC frames of silence, which
// Core Audio leaves out. The extractor does not report the playable length.

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <media/NdkMediaCodec.h>
#include <media/NdkMediaExtractor.h>
#include <media/NdkMediaFormat.h>

// AudioFormat.ENCODING_PCM_* values reported in "pcm-encoding".
#define YT_PCM_16BIT 2
#define YT_PCM_8BIT 3
#define YT_PCM_FLOAT 4
#define YT_PCM_24BIT_PACKED 21
#define YT_PCM_32BIT 22

#define YT_CONTAINER_OTHER 0
#define YT_CONTAINER_MP4 1
#define YT_CONTAINER_ADTS 2

// MP4/M4A/3GP (an "ftyp" box first) and ADTS AAC go to the platform first:
// miniaudio could take frames of them for MP3.
static int yt_android_container(const char* path) {
  unsigned char h[8] = {0};
  FILE* f = fopen(path, "rb");
  if (f == NULL) return YT_CONTAINER_OTHER;
  size_t n = fread(h, 1, sizeof h, f);
  fclose(f);
  if (n >= 8 && memcmp(h + 4, "ftyp", 4) == 0) return YT_CONTAINER_MP4;
  if (n >= 2 && h[0] == 0xFF && (h[1] & 0xF6) == 0xF0) return YT_CONTAINER_ADTS;  // sync, layer 0
  return YT_CONTAINER_OTHER;
}

static int yt_pcm_width(int32_t encoding) {
  switch (encoding) {
    case YT_PCM_16BIT: return 2;
    case YT_PCM_8BIT: return 1;
    case YT_PCM_FLOAT: return 4;
    case YT_PCM_24BIT_PACKED: return 3;
    case YT_PCM_32BIT: return 4;
    default: return 0;
  }
}

// Converts one decoder output buffer to float and appends it.
static int yt_android_append(yt_fbuf* b, const uint8_t* data, size_t bytes, int32_t encoding,
                             int32_t src_channels, float** tmp, size_t* tmp_len) {
  int width = yt_pcm_width(encoding);
  size_t samples = bytes / (size_t)width;
  int64_t frames = (int64_t)(samples / (size_t)src_channels);
  if (frames == 0) return 1;
  samples = (size_t)frames * (size_t)src_channels;
  if (samples > *tmp_len) {
    float* p = (float*)realloc(*tmp, samples * sizeof(float));
    if (p == NULL) return 0;
    *tmp = p;
    *tmp_len = samples;
  }
  float* out = *tmp;
  for (size_t i = 0; i < samples; i++) {
    const uint8_t* s = data + i * (size_t)width;
    switch (encoding) {
      case YT_PCM_16BIT: {
        int16_t v;
        memcpy(&v, s, sizeof v);
        out[i] = (float)v / 32768.0f;
        break;
      }
      case YT_PCM_8BIT:
        out[i] = ((float)s[0] - 128.0f) / 128.0f;
        break;
      case YT_PCM_FLOAT:
        memcpy(&out[i], s, sizeof(float));
        break;
      case YT_PCM_24BIT_PACKED: {
        int32_t v = (int32_t)((uint32_t)s[0] << 8 | (uint32_t)s[1] << 16 | (uint32_t)s[2] << 24) >> 8;
        out[i] = (float)v / 8388608.0f;
        break;
      }
      default: {
        int32_t v;
        memcpy(&v, s, sizeof v);
        out[i] = (float)((double)v / 2147483648.0);
        break;
      }
    }
  }
  return yt_fbuf_append(b, out, frames, src_channels);
}

// Resamples the decoded buffer in place, the way miniaudio's decoder does
// (linear, 8th-order low-pass), keeping the duration.
static int yt_fbuf_resample(yt_fbuf* b, int32_t in_rate, int32_t out_rate) {
  if (in_rate == out_rate || b->frames == 0) return 1;
  ma_resampler_config cfg = ma_resampler_config_init(ma_format_f32, (ma_uint32)b->channels, (ma_uint32)in_rate,
                                                     (ma_uint32)out_rate, ma_resample_algorithm_linear);
  cfg.linear.lpfOrder = 8;
  ma_resampler rs;
  if (ma_resampler_init(&cfg, NULL, &rs) != MA_SUCCESS) return 0;
  int64_t want = (b->frames * (int64_t)out_rate + in_rate / 2) / in_rate;
  if (want < 1) want = 1;
  float* out = (float*)malloc((size_t)want * (size_t)b->channels * sizeof(float));
  if (out == NULL) {
    ma_resampler_uninit(&rs, NULL);
    return 0;
  }
  ma_uint64 in_n = (ma_uint64)b->frames;
  ma_uint64 got = (ma_uint64)want;
  ma_resampler_process_pcm_frames(&rs, b->data, &in_n, out, &got);
  // The filter holds back a few frames; push silence through for the tail.
  const float zeros[64] = {0};
  for (int i = 0; i < 16 && got < (ma_uint64)want; i++) {
    ma_uint64 zin = 64 / (ma_uint64)b->channels;
    ma_uint64 zout = (ma_uint64)want - got;
    ma_resampler_process_pcm_frames(&rs, zeros, &zin, out + got * (ma_uint64)b->channels, &zout);
    got += zout;
  }
  if (got < (ma_uint64)want) {
    memset(out + got * (ma_uint64)b->channels, 0, (size_t)((ma_uint64)want - got) * (size_t)b->channels * sizeof(float));
  }
  ma_resampler_uninit(&rs, NULL);
  free(b->data);
  b->data = out;
  b->frames = want;
  b->capacity = want;
  return 1;
}

static float* yt_android_decode(const char* path, int32_t sample_rate, int32_t channels,
                                int64_t* out_frames, char* err, int32_t err_len) {
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    yt_set_err(err, err_len, "cannot open audio file");
    return NULL;
  }
  AMediaExtractor* ex = AMediaExtractor_new();
  AMediaCodec* codec = NULL;
  AMediaFormat* fmt = NULL;
  int started = 0;
  float* tmp = NULL;
  size_t tmp_len = 0;
  yt_fbuf b = {NULL, 0, 0, channels};
  const char* fail = NULL;
  const char* track_mime = NULL;  // owned by fmt
  struct stat st;
  int32_t in_rate = 0, in_channels = 0, encoding = YT_PCM_16BIT;
  int64_t duration_us = 0;
  int input_done = 0;
  int idle = 0;  // turns in a row without input queued or output taken

  if (ex == NULL || fstat(fd, &st) != 0 ||
      AMediaExtractor_setDataSourceFd(ex, fd, 0, (off64_t)st.st_size) != AMEDIA_OK) {
    fail = "unsupported or unreadable audio file (Android extractor)";
    goto done;
  }
  size_t tracks = AMediaExtractor_getTrackCount(ex);
  for (size_t i = 0; i < tracks && codec == NULL; i++) {
    AMediaFormat* f = AMediaExtractor_getTrackFormat(ex, i);
    const char* mime = NULL;
    if (f != NULL && AMediaFormat_getString(f, AMEDIAFORMAT_KEY_MIME, &mime) && mime != NULL &&
        strncmp(mime, "audio/", 6) == 0) {
      codec = AMediaCodec_createDecoderByType(mime);
      if (codec != NULL && AMediaExtractor_selectTrack(ex, i) == AMEDIA_OK) {
        fmt = f;
        f = NULL;
        track_mime = mime;
      }
    }
    if (f != NULL) AMediaFormat_delete(f);
  }
  if (codec == NULL || fmt == NULL) {
    fail = "no audio track this device can decode";
    goto done;
  }

  AMediaFormat_getInt32(fmt, AMEDIAFORMAT_KEY_SAMPLE_RATE, &in_rate);
  AMediaFormat_getInt32(fmt, AMEDIAFORMAT_KEY_CHANNEL_COUNT, &in_channels);
  if (AMediaFormat_getInt64(fmt, AMEDIAFORMAT_KEY_DURATION, &duration_us) && duration_us > 0 && in_rate > 0) {
    yt_fbuf_reserve(&b, duration_us * in_rate / 1000000 + 8192);
  }
  if (AMediaCodec_configure(codec, fmt, NULL, NULL, 0) != AMEDIA_OK || AMediaCodec_start(codec) != AMEDIA_OK) {
    fail = "cannot start the Android audio decoder";
    goto done;
  }
  started = 1;

  for (;;) {
    int busy = 0;
    if (!input_done) {
      ssize_t in = AMediaCodec_dequeueInputBuffer(codec, 5000);
      if (in >= 0) {
        size_t cap = 0;
        uint8_t* buf = AMediaCodec_getInputBuffer(codec, (size_t)in, &cap);
        ssize_t n = buf != NULL ? AMediaExtractor_readSampleData(ex, buf, cap) : -1;
        if (n < 0) {
          AMediaCodec_queueInputBuffer(codec, (size_t)in, 0, 0, 0, AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
          input_done = 1;
        } else {
          int64_t t = AMediaExtractor_getSampleTime(ex);
          AMediaCodec_queueInputBuffer(codec, (size_t)in, 0, (size_t)n, (uint64_t)(t > 0 ? t : 0), 0);
          AMediaExtractor_advance(ex);
        }
        busy = 1;
      }
    }
    AMediaCodecBufferInfo info;
    ssize_t out = AMediaCodec_dequeueOutputBuffer(codec, &info, 5000);
    if (out >= 0) {
      busy = 1;
      size_t size = 0;
      uint8_t* data = AMediaCodec_getOutputBuffer(codec, (size_t)out, &size);
      int ok = 1;
      if (data != NULL && info.size > 0 && info.offset >= 0 && (size_t)info.offset + (size_t)info.size <= size) {
        if (in_rate <= 0 || in_channels <= 0 || yt_pcm_width(encoding) == 0) {
          fail = "the Android decoder reported an unsupported PCM format";
          ok = 0;
        } else if (!yt_android_append(&b, data + info.offset, (size_t)info.size, encoding, in_channels, &tmp,
                                      &tmp_len)) {
          fail = "out of memory";
          ok = 0;
        }
      }
      AMediaCodec_releaseOutputBuffer(codec, (size_t)out, false);
      if (!ok) goto done;
      if (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) break;
    } else if (out == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
      busy = 1;
      AMediaFormat* of = AMediaCodec_getOutputFormat(codec);
      if (of != NULL) {
        int32_t v = 0;
        if (AMediaFormat_getInt32(of, AMEDIAFORMAT_KEY_SAMPLE_RATE, &v) && v > 0) {
          if (b.frames > 0 && v != in_rate) fail = "the sample rate changes within the file";
          in_rate = v;
        }
        if (AMediaFormat_getInt32(of, AMEDIAFORMAT_KEY_CHANNEL_COUNT, &v) && v > 0) in_channels = v;
        if (AMediaFormat_getInt32(of, "pcm-encoding", &v)) encoding = v;
        AMediaFormat_delete(of);
      }
      if (fail != NULL) goto done;
    } else if (out == AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED) {
      busy = 1;
    } else if (out != AMEDIACODEC_INFO_TRY_AGAIN_LATER) {
      fail = "the Android audio decoder failed";
      goto done;
    }
    idle = busy ? 0 : idle + 1;
    if (idle > 2000) {  // about 10 s
      fail = "the Android audio decoder stopped responding";
      goto done;
    }
  }

  {
    char line[YT_LOG_LINE];
    snprintf(line, sizeof line, "decode: %s %d Hz x%d, %lld frames, %lld us declared",
             track_mime != NULL ? track_mime : "?", (int)in_rate, (int)in_channels, (long long)b.frames,
             (long long)duration_us);
    yt_audio_log_add(line);
  }
  if (b.frames == 0) {
    fail = "file contains no audio frames";
  } else if (!yt_fbuf_resample(&b, in_rate, sample_rate)) {
    fail = "out of memory";
  }

done:
  if (codec != NULL) {
    if (started) AMediaCodec_stop(codec);
    AMediaCodec_delete(codec);
  }
  if (fmt != NULL) AMediaFormat_delete(fmt);
  if (ex != NULL) AMediaExtractor_delete(ex);
  close(fd);
  free(tmp);
  if (fail != NULL) {
    free(b.data);
    yt_set_err(err, err_len, fail);
    return NULL;
  }
  *out_frames = b.frames;
  return b.data;
}
