// YinTrace extension; GNU AGPL-3.0-only, Copyright (C) 2026 zhikkz.
#if __has_include("flutter_onnxruntime_objc/SessionOptionsHelper.h")
#import "flutter_onnxruntime_objc/SessionOptionsHelper.h"
#else
#import "SessionOptionsHelper.h"
#endif
#import "ort_session_internal.h"
#if __has_include(<onnxruntime_objc/ort_coreml_execution_provider.h>)
#import <onnxruntime_objc/ort_coreml_execution_provider.h>
#else
#import "ort_coreml_execution_provider.h"
#endif

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

+ (BOOL)appendCoreML:(ORTSessionOptions *)options
     providerOptions:(NSDictionary<NSString *, NSString *> *)providerOptions
               error:(NSError **)error {
  return [options appendCoreMLExecutionProviderWithOptionsV2:providerOptions error:error];
}
@end
