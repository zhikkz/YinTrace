#
# YinTrace native audio core (miniaudio + Core Audio).
#
Pod::Spec.new do |s|
  s.name             = 'yintrace_audio'
  s.version          = '0.1.0'
  s.summary          = 'YinTrace native audio core: decoding, AAC encoding and a duplex practice engine.'
  s.description      = <<-DESC
Portable C audio core used by YinTrace through dart:ffi.
                       DESC
  s.homepage         = 'https://github.com/zhikkz/YinTrace'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'YinTrace' => 'yintrace@users.noreply.github.com' }

  # Classes/ holds a forwarder (.m) that includes ../src/yt_audio.c so that the
  # shared C sources are compiled as Objective-C (needed by AVFoundation).
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '11.0'
  s.frameworks = 'AVFoundation', 'AudioToolbox', 'CoreAudio', 'CoreFoundation'
  s.requires_arc     = true

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES', 'GCC_OPTIMIZATION_LEVEL' => '3'
  }
  s.swift_version = '5.0'
end
