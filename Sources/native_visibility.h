//
//  native_visibility.h
//  MacKit
//
//  macOS 27 起菜单栏由 MenuBarAgent 托管，旧的「撑宽分隔条」不再把邻居挤出屏幕。
//  27 的「考核模式」私有框架 MenuBarClientCore 提供白名单式可见性限制：
//  只保留白名单里的 App 与系统项，其余由系统自己隐藏并重排。
//

#ifndef MB_NATIVE_VISIBILITY_H
#define MB_NATIVE_VISIBILITY_H

#include <stdbool.h>
#import <Foundation/Foundation.h>

/// 当前系统是否提供该私有框架且接口可用（macOS 27+）
bool MBVisibilityAvailable(void);

/// 激活限制：只让系统项和 bundleIDs 里的 App 可见。
/// 成功时通过 handle 返回一个不透明句柄，用完必须 MBVisibilityRelease。
void MBVisibilityActivate(NSArray<NSNumber *> *systemItems,
                          NSArray<NSString *> *bundleIDs,
                          void (^completion)(void *_Nullable handle, NSError * _Nullable error));

/// 解除限制并释放句柄
void MBVisibilityRelease(void * _Nullable handle);

#endif /* MB_NATIVE_VISIBILITY_H */
