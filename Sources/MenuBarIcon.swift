import AppKit
import SwiftUI

/// 18pt 状态栏模板图标。只保留一种主语义，避免小尺寸下堆叠所有功能。
enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case command, toolkit, launch, clipboard, scroll
    var id: String { rawValue }
    static let preferenceKey = "MacKit.menuBarIconStyle"

    var title: String {
        switch self {
        case .command: return "经典"
        case .toolkit: return "工具箱"
        case .launch: return "快捷启动"
        case .clipboard: return "剪贴板"
        case .scroll: return "滚动控制"
        }
    }
    var meaning: String {
        switch self {
        case .command: return "⌘ 保留 MacKit 的快捷键标识"
        case .toolkit: return "工具箱代表集成的常用工具"
        case .launch: return "闪电代表一键启动与快速操作"
        case .clipboard: return "夹板代表内容复制与历史管理"
        case .scroll: return "鼠标与双向箭头代表滚动控制"
        }
    }
    static func load(from defaults: UserDefaults = .standard) -> MenuBarIconStyle {
        defaults.string(forKey: preferenceKey).flatMap(MenuBarIconStyle.init(rawValue:)) ?? .command
    }
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
    var image: NSImage {
        let style = self
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            func line(_ points: [NSPoint], closed: Bool = false, fill: Bool = false) {
                guard let first = points.first else { return }
                let path = NSBezierPath()
                path.lineWidth = 1.4
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: first)
                points.dropFirst().forEach { path.line(to: $0) }
                if closed { path.close() }
                if fill { path.fill() } else { path.stroke() }
            }
            func box(_ rect: NSRect, radius: CGFloat) {
                let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                path.lineWidth = 1.4
                path.stroke()
            }
            switch style {
            case .command:
                let symbol = NSImage(systemSymbolName: "command", accessibilityDescription: "MacKit")?
                    .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
                symbol?.draw(in: NSRect(x: 1, y: 1, width: 16, height: 16))
            case .toolkit:
                box(NSRect(x: 1.7, y: 3, width: 14.6, height: 10), radius: 2)
                line([NSPoint(x: 6, y: 13), NSPoint(x: 6, y: 15), NSPoint(x: 12, y: 15), NSPoint(x: 12, y: 13)])
                line([NSPoint(x: 2, y: 9), NSPoint(x: 7, y: 9)])
                line([NSPoint(x: 11, y: 9), NSPoint(x: 16, y: 9)])
                box(NSRect(x: 7, y: 7.5, width: 4, height: 3), radius: 0.6)
            case .launch:
                line([NSPoint(x: 10.5, y: 16), NSPoint(x: 3.6, y: 8), NSPoint(x: 8, y: 8),
                      NSPoint(x: 6.7, y: 2), NSPoint(x: 14.5, y: 10), NSPoint(x: 10, y: 10)], closed: true)
            case .clipboard:
                box(NSRect(x: 4, y: 2, width: 10, height: 12.5), radius: 1.6)
                NSColor.white.setFill()
                let clip = NSBezierPath(roundedRect: NSRect(x: 6.2, y: 13, width: 5.6, height: 2.8), xRadius: 0.8, yRadius: 0.8)
                clip.fill()
                NSColor.black.setFill()
                clip.lineWidth = 1.4
                clip.stroke()
                line([NSPoint(x: 6.5, y: 10), NSPoint(x: 11.5, y: 10)])
                line([NSPoint(x: 6.5, y: 7), NSPoint(x: 11.5, y: 7)])
            case .scroll:
                box(NSRect(x: 2.5, y: 2, width: 8, height: 14), radius: 4)
                line([NSPoint(x: 6.5, y: 13.5), NSPoint(x: 6.5, y: 10.5)])
                line([NSPoint(x: 14, y: 3.5), NSPoint(x: 14, y: 14.5)])
                line([NSPoint(x: 11.8, y: 12.2), NSPoint(x: 14, y: 14.5), NSPoint(x: 16.2, y: 12.2)])
                line([NSPoint(x: 11.8, y: 5.8), NSPoint(x: 14, y: 3.5), NSPoint(x: 16.2, y: 5.8)])
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MacKit · " + title
        return image
    }
}

struct MenuBarIconPicker: View {
    @Binding var selection: MenuBarIconStyle
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("状态栏图标").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("仅本机 · 自动适配深浅色").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(MenuBarIconStyle.allCases) { style in
                    Button { selection = style } label: {
                        VStack(spacing: 5) {
                            Image(nsImage: style.image).renderingMode(.template).frame(width: 18, height: 18)
                            Text(style.title).font(.system(size: 10)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(selection == style ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(selection == style ? Color.accentColor : Color.clear, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selection == style ? Color.accentColor : Color.primary)
                    .help(style.meaning)
                    .accessibilityLabel("状态栏图标：" + style.title)
                    .accessibilityValue(selection == style ? "已选中" : "未选中")
                    .accessibilityIdentifier("menuBarIcon-" + style.rawValue)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11).fill(.quaternary.opacity(0.4)))
    }
}

/// 不改变用户偏好的渲染/持久化自检。
func runMenuBarIconCheck() -> Never {
    let suite = "MacKit-Icon-Test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    guard MenuBarIconStyle.load(from: defaults) == .command else { exit(1) }
    defaults.set("unsupported", forKey: MenuBarIconStyle.preferenceKey)
    guard MenuBarIconStyle.load(from: defaults) == .command else { exit(1) }
    var rendered = Set<Data>()
    for style in MenuBarIconStyle.allCases {
        style.save(to: defaults)
        guard MenuBarIconStyle.load(from: UserDefaults(suiteName: suite)!) == style,
              style.image.isTemplate, style.image.size == NSSize(width: 18, height: 18) else { exit(1) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        style.image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]), rendered.insert(png).inserted else { exit(1) }
        var visible = 0
        for x in 0..<36 { for y in 0..<36 {
            if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { visible += 1 }
        } }
        guard visible > 70, visible < 1000 else { print("图标渲染异常：\(style.title)"); exit(1) }
    }
    print("✓ 5 款图标：18pt 模板、渲染非空且互异、默认回退、选择持久化通过")
    exit(0)
}
