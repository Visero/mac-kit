import AppKit
import SwiftUI
import Combine
import ApplicationServices

struct ScrollOptions: Equatable {
    var enabled = true
    var mouse = true
    var trackpad = false
    var vertical = true
    var horizontal = false

    func applies(to device: Int) -> Bool {
        enabled && ((device == 1 && mouse) || (device == 2 && trackpad))
    }
}

final class ScrollReversal: ObservableObject {
    @Published private(set) var options: ScrollOptions
    @Published private(set) var active = false
    @Published private(set) var status = "尚未启用"
    @Published private(set) var conflict = false
    @Published private(set) var lastDevice = "等待滚动"
    private let defaults: UserDefaults
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var started = false
    private var recentDevice = 0
    private var refreshDeviceTime = Date.distantPast

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func saved(_ key: String, fallback: Bool) -> Bool {
            defaults.object(forKey: "MacKit.scroll." + key) == nil ? fallback : defaults.bool(forKey: "MacKit.scroll." + key)
        }
        options = ScrollOptions(enabled: saved("enabled", fallback: true), mouse: saved("mouse", fallback: true),
                                trackpad: saved("trackpad", fallback: false), vertical: saved("vertical", fallback: true),
                                horizontal: saved("horizontal", fallback: false))
    }

    func set(_ field: String, value: Bool) {
        switch field {
        case "enabled": options.enabled = value
        case "mouse": options.mouse = value
        case "trackpad": options.trackpad = value
        case "vertical": options.vertical = value
        case "horizontal": options.horizontal = value
        default: return
        }
        defaults.set(value, forKey: "MacKit.scroll." + field)
        if started { refresh() }
    }

    func start() {
        guard !started else { return }
        started = true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 1
    }

    func stop() {
        timer?.invalidate(); timer = nil; started = false
        removeTap()
    }

    private func removeTap() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil; active = false
    }

    static func conflictingToolIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            let id = ($0.bundleIdentifier ?? "").lowercased()
            let name = ($0.localizedName ?? "").lowercased()
            return !$0.isTerminated && (id.contains("scrollreverser") || name == "scroll reverser")
        }
    }

    func refresh() {
        // 不改其他工具的配置；发现同时运行的 Scroll Reverser 时暂停本工具，防止抵消。
        conflict = Self.conflictingToolIsRunning()
        guard options.enabled else { removeTap(); status = "已关闭"; return }
        guard options.mouse || options.trackpad, options.vertical || options.horizontal else {
            removeTap(); status = "请选择设备和滚动方向"; return
        }
        guard !conflict else { removeTap(); status = "已暂停：Scroll Reverser 正在运行，避免双重反转"; return }
        guard AXIsProcessTrusted() else {
            removeTap(); status = "等待辅助功能权限"; return
        }
        guard MKScrollDeviceAPIAvailable() else {
            removeTap(); status = "当前系统不支持可靠的设备识别，未修改滚动"; return
        }
        if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            active = true; status = "已启用"; return
        }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let engine = Unmanaged<ScrollReversal>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if engine.options.enabled, let tap = engine.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                if type == .scrollWheel {
                    let device = Int(MKScrollDeviceKind(event))
                    if engine.recentDevice != device || Date().timeIntervalSince(engine.refreshDeviceTime) > 1 {
                        engine.recentDevice = device; engine.refreshDeviceTime = Date()
                        engine.lastDevice = device == 1 ? "鼠标" : (device == 2 ? "触控板" : "未识别（保持原样）")
                    }
                    ScrollReversal.transform(event, device: device, options: engine.options)
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            active = false; status = "无法拦截滚动，请检查辅助功能权限后重试"; return
        }
        tap = newTap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: newTap, enable: true)
        active = true; status = "已启用"
    }

    static func transform(_ event: CGEvent, device: Int, options: ScrollOptions) {
        guard options.applies(to: device) else { return }
        // 先保存所有 delta；设置 line delta 会改变系统内部的 point/fixed 值。
        let verticalFields: [CGEventField] = [.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1]
        let horizontalFields: [CGEventField] = [.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2]
        let v = verticalFields.map { event.getIntegerValueField($0) }
        let h = horizontalFields.map { event.getIntegerValueField($0) }
        let vf = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let hf = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        func negated(_ value: Int64) -> Int64 { value == Int64.min ? Int64.max : -value }
        if options.vertical {
            event.setIntegerValueField(verticalFields[0], value: negated(v[0]))
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -vf)
            event.setIntegerValueField(verticalFields[1], value: negated(v[1]))
        }
        if options.horizontal {
            event.setIntegerValueField(horizontalFields[0], value: negated(h[0]))
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -hf)
            event.setIntegerValueField(horizontalFields[1], value: negated(h[1]))
        }
        MKScrollReverseHID(event, options.vertical, options.horizontal)
    }
}

struct ScrollSettingsPage: View {
    @ObservedObject var engine: ScrollReversal
    private func row(_ title: String, symbol: String, field: String, value: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 18)
            Text(title).font(.system(size: 13))
            Spacer()
            GlassSwitch(isOn: Binding(get: { value }, set: { engine.set(field, value: $0) }))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11).fill(.quaternary.opacity(0.4)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("启用滚动反转", symbol: "arrow.up.arrow.down", field: "enabled", value: engine.options.enabled)
            Text(engine.status).font(.system(size: 11)).foregroundStyle(engine.active ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text("设备").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                row("反转鼠标", symbol: "computermouse", field: "mouse", value: engine.options.mouse)
                row("反转触控板", symbol: "rectangle.and.hand.point.up.left", field: "trackpad", value: engine.options.trackpad)
            }
            Text("方向").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                row("垂直滚动", symbol: "arrow.up.arrow.down", field: "vertical", value: engine.options.vertical)
                row("水平滚动", symbol: "arrow.left.arrow.right", field: "horizontal", value: engine.options.horizontal)
            }
            HStack {
                Text("最近来源：\(engine.lastDevice)").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("重新检查") { engine.refresh() }.controlSize(.small)
            }
            Text("默认只反转鼠标的垂直滚动，触控板和水平滚动不变。未识别或软件合成的事件保持原样；不修改系统自然滚动设置。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !AXIsProcessTrusted() {
                Button("打开辅助功能设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }.buttonStyle(.bordered).controlSize(.small)
                Text("在系统辅助功能中允许 MacKit，授权后自动启用。关闭本功能或退出 MacKit 即恢复原滚动。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

func runScrollStatus() -> Never {
    let engine = ScrollReversal()
    print("滚动反转：\(engine.options.enabled ? "开启" : "关闭")，鼠标：\(engine.options.mouse)，触控板：\(engine.options.trackpad)，垂直：\(engine.options.vertical)，水平：\(engine.options.horizontal)")
    print("辅助功能权限：\(AXIsProcessTrusted() ? "已授权" : "未授权")")
    print("设备识别接口：\(MKScrollDeviceAPIAvailable() ? "可用" : "不可用")")
    print("冲突工具：\(ScrollReversal.conflictingToolIsRunning() ? "Scroll Reverser 正在运行，MacKit 不启用反转" : "未检测到 Scroll Reverser")")
    exit(0)
}

func runScrollCheck() -> Never {
    let suite = "MacKit-Scroll-Test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let engine = ScrollReversal(defaults: defaults)
    var success = true
    func check(_ value: Bool) { if !value { success = false } }
    check(engine.options == ScrollOptions())
    for device in [0, 1, 2] {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 3, wheel2: 5, wheel3: 0)!
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 24)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 40)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 3.25)
        let originalH = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        ScrollReversal.transform(event, device: device, options: engine.options)
        check(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == (device == 1 ? -24 : 24))
        check(event.getIntegerValueField(.scrollWheelEventDeltaAxis2) == originalH)
        check(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 40)
        check(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) == (device == 1 ? -3.25 : 3.25))
        check(MKScrollDeviceKind(event) == 0)
    }
    let disabledEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 7, wheel2: 0, wheel3: 0)!
    var disabledOptions = engine.options
    disabledOptions.enabled = false
    ScrollReversal.transform(disabledEvent, device: 1, options: disabledOptions)
    check(disabledEvent.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 7)
    engine.set("enabled", value: false)
    let restored = ScrollReversal(defaults: defaults)
    check(!restored.options.enabled && !restored.options.trackpad)
    engine.set("enabled", value: true)
    engine.set("horizontal", value: true)
    engine.set("trackpad", value: true)
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: -4, wheel2: 6, wheel3: 0)!
    ScrollReversal.transform(event, device: 2, options: engine.options)
    check(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 4)
    check(event.getIntegerValueField(.scrollWheelEventDeltaAxis2) == -6)
    defaults.removePersistentDomain(forName: suite)
    print(success ? "✓ 默认只鼠标垂直反转、触控板与未知事件不变、双轴反转、精确 delta 与设置持久化通过" : "✗ 滚动反转自检失败")
    print("设备识别接口：\(MKScrollDeviceAPIAvailable() ? "可用" : "不可用，运行时保持原样")")
    exit(success ? 0 : 1)
}
