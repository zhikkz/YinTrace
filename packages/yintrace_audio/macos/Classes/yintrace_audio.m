// Forwarder so CocoaPods compiles the shared C sources as Objective-C
// (needed for AVFoundation / AVAudioSession). See ../yintrace_audio.podspec.
#include "../../src/yt_audio.c"
