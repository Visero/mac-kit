#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>

// IOKit SPI 不存在时保持原事件，不使用名称猜测设备类型。
// 设备分类规则参考 Scroll Reverser（Apache-2.0），此桥接独立实现。
typedef CFTypeRef (*CopyHIDEvent)(CGEventRef);
typedef uint64_t (*SenderID)(CFTypeRef);
typedef double (*ReadHIDFloat)(CFTypeRef, uint32_t);
typedef void (*WriteHIDFloat)(CFTypeRef, uint32_t, double);
static CopyHIDEvent copyHID;
static SenderID senderID;
static ReadHIDFloat readFloat;
static WriteHIDFloat writeFloat;
static NSMutableDictionary<NSNumber *, NSNumber *> *deviceCache;
static BOOL loaded;
static void loadInterfaces(void) {
    if (loaded) return;
    loaded = YES;
    dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
    copyHID = (CopyHIDEvent)dlsym(RTLD_DEFAULT, "CGEventCopyIOHIDEvent");
    senderID = (SenderID)dlsym(RTLD_DEFAULT, "IOHIDEventGetSenderID");
    readFloat = (ReadHIDFloat)dlsym(RTLD_DEFAULT, "IOHIDEventGetFloatValue");
    writeFloat = (WriteHIDFloat)dlsym(RTLD_DEFAULT, "IOHIDEventSetFloatValue");
    deviceCache = [NSMutableDictionary dictionary];
}

// 0 未识别；1 鼠标；2 触控板
static int kindForSender(uint64_t sender) {
    NSNumber *cached = deviceCache[@(sender)];
    if (cached) return cached.intValue;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(sender));
    if (!service) return 0;
    BOOL trackpad = NO;
    BOOL known = NO;
    io_registry_entry_t current = service;
    for (int depth = 0; depth < 4 && current; depth++) {
        CFTypeRef accel = IORegistryEntryCreateCFProperty(current, CFSTR("HIDScrollAccelerationType"), kCFAllocatorDefault, 0);
        if (accel) {
            if (CFEqual(accel, CFSTR("HIDTrackpadScrollAcceleration"))) { trackpad = YES; known = YES; }
            else if (CFEqual(accel, CFSTR("HIDMouseScrollAcceleration"))) known = YES;
            CFRelease(accel);
        }
        if (IOObjectConformsTo(current, "AppleMultitouchTrackpadHIDEventDriver")) { trackpad = YES; known = YES; }
        CFTypeRef usagePage = IORegistryEntryCreateCFProperty(current, CFSTR("PrimaryUsagePage"), kCFAllocatorDefault, 0);
        CFTypeRef usage = IORegistryEntryCreateCFProperty(current, CFSTR("PrimaryUsage"), kCFAllocatorDefault, 0);
        if (usagePage && usage && CFGetTypeID(usagePage) == CFNumberGetTypeID() && CFGetTypeID(usage) == CFNumberGetTypeID()) {
            int pageValue = 0, usageValue = 0;
            CFNumberGetValue(usagePage, kCFNumberIntType, &pageValue);
            CFNumberGetValue(usage, kCFNumberIntType, &usageValue);
            if (pageValue == 1 && usageValue == 2) known = YES;
        }
        if (usagePage) CFRelease(usagePage);
        if (usage) CFRelease(usage);
        io_registry_entry_t parent = 0;
        IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent);
        IOObjectRelease(current);
        current = parent;
    }
    if (current) IOObjectRelease(current);
    int result = trackpad ? 2 : (known ? 1 : 0);
    if (result) {
        if (deviceCache.count > 128) [deviceCache removeAllObjects];
        deviceCache[@(sender)] = @(result);
    }
    return result;
}

int MKScrollDeviceKind(CGEventRef event) {
    loadInterfaces();
    if (!event || !copyHID || !senderID) return 0;
    CFTypeRef hid = copyHID(event);
    if (!hid) return 0;
    uint64_t sender = senderID(hid);
    CFRelease(hid);
    return sender ? kindForSender(sender) : 0;
}

void MKScrollReverseHID(CGEventRef event, bool vertical, bool horizontal) {
    loadInterfaces();
    if (!copyHID || !readFloat || !writeFloat || !event) return;
    CFTypeRef hid = copyHID(event);
    if (!hid) return;
    if (vertical) writeFloat(hid, (6U << 16) | 1U, -readFloat(hid, (6U << 16) | 1U));
    if (horizontal) writeFloat(hid, (6U << 16), -readFloat(hid, (6U << 16)));
    CFRelease(hid);
}

bool MKScrollDeviceAPIAvailable(void) {
    loadInterfaces();
    return copyHID && senderID;
}
