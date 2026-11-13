// Forwarder so CocoaPods compiles the shared C sources as Objective-C
// (needed for AVFoundation / AVAudioSession). See ../yintrace_audio.podspec.
#import "YintraceAudioPlugin.h"

#include "../../src/yt_audio.c"

@implementation YintraceAudioPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  // References the C core from the same object file as this class, so a
  // static link (use_frameworks! :linkage => :static) cannot drop it.
  (void)yt_api_version();
}
@end
