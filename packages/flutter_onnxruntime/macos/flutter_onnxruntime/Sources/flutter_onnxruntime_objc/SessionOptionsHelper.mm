// YinTrace extension; GNU AGPL-3.0-only, Copyright (C) 2026 zhikkz.
#if __has_include("flutter_onnxruntime_objc/SessionOptionsHelper.h")
#import "flutter_onnxruntime_objc/SessionOptionsHelper.h"
#else
#import "SessionOptionsHelper.h"
#endif
#import "ort_session_internal.h"

@implementation SessionOptionsHelper
+ (BOOL)disableCpuArena:(ORTSessionOptions *)options error:(NSError **)error {
  try {
    [options CXXAPIOrtSessionOptions].DisableCpuMemArena();
    return YES;
  } catch (const Ort::Exception& e) {
    if (error) {
      *error = [NSError errorWithDomain:@"YinTrace.ONNX" code:e.GetOrtErrorCode()
                              userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
    }
    return NO;
  }
}
@end
