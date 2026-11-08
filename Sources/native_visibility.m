//
//  native_visibility.c
//  MacKit
//
//  通过 dlopen + ObjC 运行时访问 MenuBarClientCore.framework。
//  全部符号按字符串解析：框架不存在或改了接口时返回「不可用」，不会导致启动失败。
//

#include "native_visibility.h"
#import <dlfcn.h>
#import <objc/message.h>

static NSString *const MBFrameworkPath =
    @"/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore";
static NSString *const MBConfigurationClass = @"MBAssessmentModeConfiguration";
static NSString *const MBAssertionClass = @"MBAssessmentModeAssertion";

static NSError *MBError(NSString *reason) {
    return [NSError errorWithDomain:@"MacKitNativeVisibility"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: reason}];
}

static SEL MBConfigInit(void) {
    return @selector(initWithAllowedSystemItems:allowedBundleIdentifiers:);
}
static SEL MBActivate(void) {
    return @selector(activateWithConfiguration:completionHandler:);
}
static SEL MBInvalidate(void) {
    return @selector(invalidate);
}

bool MBVisibilityAvailable(void) {
    if (!dlopen(MBFrameworkPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL)) {
        return false;
    }
    Class configuration = NSClassFromString(MBConfigurationClass);
    Class assertion = NSClassFromString(MBAssertionClass);
    return configuration && assertion
        && [configuration instancesRespondToSelector:MBConfigInit()]
        && [assertion instancesRespondToSelector:MBActivate()]
        && [assertion instancesRespondToSelector:MBInvalidate()];
}

void MBVisibilityActivate(NSArray<NSNumber *> *systemItems,
                          NSArray<NSString *> *bundleIDs,
                          void (^completion)(void *, NSError *)) {
    void (^finish)(void *, NSError *) = ^(void *handle, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(handle, error);
        });
    };

    if (!MBVisibilityAvailable()) {
        finish(nil, MBError(@"这台 Mac 不支持新的菜单栏隐藏接口（需要 macOS 27 及以上）"));
        return;
    }

    @try {
        // 两个参数都必须是 NSArray：框架内部按下标取值
        id configuration = ((id (*)(id, SEL, NSArray *, NSArray *))objc_msgSend)(
            [NSClassFromString(MBConfigurationClass) alloc],
            MBConfigInit(),
            [systemItems copy],
            [bundleIDs copy]);
        id assertion = [[NSClassFromString(MBAssertionClass) alloc] init];
        if (!configuration || !assertion) {
            finish(nil, MBError(@"无法创建菜单栏可见性配置"));
            return;
        }
        ((void (*)(id, SEL, id, void (^)(NSError *)))objc_msgSend)(
            assertion,
            MBActivate(),
            configuration,
            ^(NSError *error) {
                if (error) {
                    finish(NULL, error);
                } else {
                    // 用 +1 引用换来一个不透明句柄，释放时再平衡
                    finish((void *)CFBridgingRetain(assertion), nil);
                }
            });
    } @catch (NSException *exception) {
        finish(nil, MBError([NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]));
    }
}

void MBVisibilityRelease(void *handle) {
    if (handle == NULL) {
        return;
    }
    id assertion = CFBridgingRelease(handle);
    @try {
        if ([assertion respondsToSelector:MBInvalidate()]) {
            ((void (*)(id, SEL))objc_msgSend)(assertion, MBInvalidate());
        }
    } @catch (NSException *exception) {
        NSLog(@"MacKit: invalidate raised %@: %@", exception.name, exception.reason);
    }
}
