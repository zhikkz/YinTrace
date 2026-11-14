// YinTrace extension; GNU AGPL-3.0-only, Copyright (C) 2026 zhikkz.
#import <Foundation/Foundation.h>
#if __has_include(<onnxruntime_objc/ort_session.h>)
#import <onnxruntime_objc/ort_session.h>
#else
#import "ort_session.h"
#endif
NS_ASSUME_NONNULL_BEGIN
@interface SessionOptionsHelper : NSObject
+ (BOOL)disableCpuArena:(ORTSessionOptions *)options error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
