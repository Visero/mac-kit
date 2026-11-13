import Cocoa
import Carbon.HIToolbox
import ApplicationServices
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 配置模型

struct HotkeyBinding: Codable, Equatable {
    var key: String
    var modifiers: [String]
    var target: String
}

struct Config: Codable {
    var hotkeys: [HotkeyBinding]
}

// MARK: - 键码表（US 布局虚拟键码）

enum KeyCodes {
    static let map: [String: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "equal": 24, "=": 24,
        "9": 25, "7": 26, "minus": 27, "-": 27, "8": 28, "0": 29,
        "rightbracket": 30, "]": 30, "o": 31, "u": 32, "leftbracket": 33, "[": 33,
        "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38,
        "quote": 39, "'": 39, "k": 40, "semicolon": 41, ";": 41,
        "backslash": 42, "\\": 42, "comma": 43, ",": 43, "slash": 44, "/": 44,
        "n": 45, "m": 46, "period": 47, ".": 47, "tab": 48, "space": 49,
        "grave": 50, "`": 50, "delete": 51, "backspace": 51, "escape": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121
    ]

    /// NSEvent.keyCode → config.json 里使用的键名
    static func name(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 0: return "a"
        case 1: return "s"
        case 2: return "d"
        case 3: return "f"
        case 4: return "h"
        case 5: return "g"
        case 6: return "z"
        case 7: return "x"
        case 8: return "c"
        case 9: return "v"
        case 11: return "b"
        case 12: return "q"
        case 13: return "w"
        case 14: return "e"
        case 15: return "r"
        case 16: return "y"
        case 17: return "t"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "equal"
        case 25: return "9"
        case 26: return "7"
        case 27: return "minus"
        case 28: return "8"
        case 29: return "0"
        case 30: return "rightbracket"
        case 31: return "o"
        case 32: return "u"
        case 33: return "leftbracket"
        case 34: return "i"
        case 35: return "p"
        case 36: return "return"
        case 37: return "l"
        case 38: return "j"
        case 39: return "quote"
        case 40: return "k"
        case 41: return "semicolon"
        case 42: return "backslash"
        case 43: return "comma"
        case 44: return "slash"
        case 45: return "n"
        case 46: return "m"
        case 47: return "period"
        case 48: return "tab"
        case 49: return "space"
        case 50: return "grave"
        case 51: return "delete"
        case 53: return "escape"
        case 96: return "f5"
        case 97: return "f6"
        case 98: return "f7"
        case 99: return "f3"
        case 100: return "f8"
        case 101: return "f9"
        case 103: return "f11"
        case 109: return "f10"
        case 111: return "f12"
        case 115: return "home"
        case 116: return "pageup"
        case 118: return "f4"
        case 119: return "end"
        case 120: return "f2"
        case 121: return "pagedown"
        case 122: return "f1"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default: return nil
        }
    }

    static func canonicalModifier(_ name: String) -> String? {
        switch name.lowercased() {
        case "command", "cmd", "⌘": return "command"
        case "option", "alt", "opt", "⌥": return "option"
        case "control", "ctrl", "⌃": return "control"
        case "shift", "⇧": return "shift"
        default: return nil
        }
    }

    static func canonicalModifiers(_ names: [String]) -> [String] {
        let set = Set(names.compactMap(canonicalModifier))
        return ["command", "option", "control", "shift"].filter { set.contains($0) }
    }

    static func carbonModifiers(_ names: [String]) -> UInt32 {
        var mods: UInt32 = 0
        for name in names {
            switch name.lowercased() {
            case "command", "cmd", "⌘": mods |= UInt32(cmdKey)
            case "option", "alt", "opt", "⌥": mods |= UInt32(optionKey)
            case "control", "ctrl", "⌃": mods |= UInt32(controlKey)
            case "shift", "⇧": mods |= UInt32(shiftKey)
            default: break
            }
        }
        return mods
    }

    static func display(_ names: [String]) -> String {
        var out = ""
        for name in names.map({ $0.lowercased() }) {
            switch name {
            case "command", "cmd", "⌘": out += "⌘"
            case "option", "alt", "opt", "⌥": out += "⌥"
            case "control", "ctrl", "⌃": out += "⌃"
            case "shift", "⇧": out += "⇧"
            default: break
            }
        }
        return out
    }

    static func keyLabel(_ key: String) -> String {
        switch key.lowercased() {
        case "return", "enter": return "↩"
        case "space": return "Space"
        case "tab": return "⇥"
        case "delete", "backspace": return "⌫"
        case "escape": return "⎋"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "home": return "Home"
        case "end": return "End"
        case "pageup": return "PageUp"
        case "pagedown": return "PageDown"
        case "equal", "=": return "="
        case "minus", "-": return "-"
        case "comma", ",": return ","
        case "period", ".": return "."
        case "slash", "/": return "/"
        case "semicolon", ";": return ";"
        case "quote", "'": return "'"
        case "backslash", "\\": return "\\"
        case "leftbracket", "[": return "["
        case "rightbracket", "]": return "]"
        case "grave", "`": return "`"
        default: return key.uppercased()
        }
    }

    static func label(_ binding: HotkeyBinding) -> String {
        "\(display(binding.modifiers))\(keyLabel(binding.key))"
    }
}

// MARK: - 日志

enum Log {
    static let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/mac-kit.log")

    static func write(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
        FileHandle.standardError.write(data)
    }
}

// MARK: - 应用查找

enum AppResolver {
    static let appDirs = [
        "/Applications",
        "/System/Applications",
        "/Applications/Utilities",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices",
        NSHomeDirectory() + "/Applications"
    ]

    /// target 支持三种写法：应用名、bundle id、完整路径
    static func resolve(_ target: String) -> URL? {
        let trimmed = target.trimmingCharacters(in: .whitespaces)

        if trimmed.contains("/") {
            let path = (trimmed as NSString).expandingTildeInPath
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }

        if trimmed.contains(".") {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) {
                return url
            }
        }

        let name = trimmed.hasSuffix(".app") ? String(trimmed.dropLast(4)) : trimmed
        for dir in appDirs {
            let path = "\(dir)/\(name).app"
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    static func displayName(_ target: String) -> String {
        if target == ShortcutConfiguration.screenSaver { return "启动屏幕保护程序" }
        guard let url = resolve(target) else { return target }
        let bundle = Bundle(url: url)
        let info = bundle?.localizedInfoDictionary ?? bundle?.infoDictionary
        if let name = info?["CFBundleDisplayName"] as? String, !name.isEmpty { return name }
        if let name = info?["CFBundleName"] as? String, !name.isEmpty { return name }
        return url.deletingPathExtension().lastPathComponent
    }
}

// MARK: - 图标（亮/暗两套，随系统外观切换）

enum AppIconAsset {
    static func named(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }

    static func forAppearance(_ appearance: NSAppearance) -> NSImage? {
        var image: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            image = NSImage(named: NSImage.Name("MacKit")) ?? named("MacKit")
        }
        return image
    }
}

// MARK: - 外观偏好（UserDefaults）

enum Preferences {
    private static let menuBarKey = "showMenuBarIcon"
    private static let dockKey = "showDockIcon"

    static var showMenuBarIcon: Bool {
        get {
            if UserDefaults.standard.object(forKey: menuBarKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: menuBarKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: menuBarKey) }
    }

    static var showDockIcon: Bool {
        get { UserDefaults.standard.bool(forKey: dockKey) }
        set { UserDefaults.standard.set(newValue, forKey: dockKey) }
    }

    private static let selfHotkeyKey = "selfHotkeyEnabled"

    /// ⌘⌥K 打开设置窗口，默认开启
    static var selfHotkeyEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: selfHotkeyKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: selfHotkeyKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: selfHotkeyKey) }
    }

    private static let collapseOnLaunchKey = "collapseMenuBarOnLaunch"

    /// 启动时自动折叠菜单栏图标
    static var collapseOnLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: collapseOnLaunchKey) }
        set { UserDefaults.standard.set(newValue, forKey: collapseOnLaunchKey) }
    }

    private static let hiddenAppsKey = "menuBarHiddenBundleIDs"

    /// macOS 27 方案下要隐藏的 App（bundle id）；其余运行中的 App 保持可见
    static var hiddenBundleIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: hiddenAppsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: hiddenAppsKey) }
    }

    private static let toggleItemKey = "menuBarToggleVisible"
    private static let separatorItemKey = "menuBarSeparatorVisible"

    /// 是否显示折叠用的箭头按钮 / 分隔线
    static var menuBarToggleVisible: Bool {
        get {
            if UserDefaults.standard.object(forKey: toggleItemKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: toggleItemKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: toggleItemKey) }
    }

    static var menuBarSeparatorVisible: Bool {
        get {
            if UserDefaults.standard.object(forKey: separatorItemKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: separatorItemKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: separatorItemKey) }
    }

    private static let autoUpdateKey = "autoUpdateCheck"
    private static let lastUpdateKey = "lastUpdateCheck"
    private static let quitWhitelistKey = "quitAllWhitelist"

    /// 一键关闭所有 App 时豁免的 bundle id / 路径
    static var quitAllWhitelist: [String] {
        get { UserDefaults.standard.stringArray(forKey: quitWhitelistKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: quitWhitelistKey) }
    }

    /// 自动检查更新，默认开启
    static var autoUpdateCheck: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoUpdateKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: autoUpdateKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoUpdateKey) }
    }

    static var lastUpdateCheck: Date? {
        get { UserDefaults.standard.object(forKey: lastUpdateKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastUpdateKey) }
    }

    private static let orderKey = "sidebarOrder"

    /// 侧栏顺序；读不到或数量不对时回落到默认顺序
    static var sidebarOrder: [SettingsPage] {
        get {
            let raw = UserDefaults.standard.stringArray(forKey: orderKey) ?? []
            let items = raw.compactMap { SettingsPage(rawValue: $0) }
            let missing = SettingsPage.allCases.filter { !items.contains($0) }
            let order = items + missing
            return order.count == SettingsPage.allCases.count ? order : SettingsPage.allCases
        }
        set {
            UserDefaults.standard.set(newValue.map { $0.rawValue }, forKey: orderKey)
        }
    }
}

// MARK: - 清理范围

enum HistoryRange: String, CaseIterable, Identifiable {
    case today
    case twoDays
    case week
    case month
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "今天"
        case .twoDays: return "今天和昨天"
        case .week: return "一周"
        case .month: return "一个月"
        case .all: return "全部"
        }
    }

    /// 起始时间；nil 表示全部
    var cutoff: Date? {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        switch self {
        case .today: return startOfToday
        case .twoDays: return calendar.date(byAdding: .day, value: -1, to: startOfToday)
        case .week: return calendar.date(byAdding: .day, value: -7, to: startOfToday)
        case .month: return calendar.date(byAdding: .month, value: -1, to: startOfToday)
        case .all: return nil
        }
    }
}

// MARK: - 记录清理（Safari 浏览记录 / 最近使用文件）

enum RecordCleaner {
    struct Result {
        let message: String
        let needsFullDiskAccess: Bool
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private static var safariHistoryFiles: [URL] {
        let dir = home.appendingPathComponent("Library/Safari", isDirectory: true)
        return ["History.db", "History.db-wal", "History.db-shm"].map { dir.appendingPathComponent($0) }
    }

    private static var recentFileLists: [URL] {
        let fm = FileManager.default
        let base = home.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist", isDirectory: true)
        var urls = [
            base.appendingPathComponent("com.apple.LSSharedFileList.RecentDocuments.sfl3"),
            base.appendingPathComponent("com.apple.LSSharedFileList.RecentApplications.sfl3"),
            base.appendingPathComponent("com.apple.LSSharedFileList.RecentHosts.sfl3")
        ]
        let perApp = base.appendingPathComponent("com.apple.LSSharedFileList.ApplicationRecentDocuments", isDirectory: true)
        if let items = try? fm.contentsOfDirectory(at: perApp, includingPropertiesForKeys: nil) {
            urls.append(contentsOf: items.filter { $0.pathExtension == "sfl3" })
        }
        return urls
    }

    static var safariIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Safari" }
    }

    /// 删除一组文件；返回 (删除数量, 权限错误列表)
    private static func remove(_ urls: [URL]) -> (deleted: Int, firstError: String?) {
        var deleted = 0
        var firstError: String?
        for url in urls {
            do {
                try FileManager.default.removeItem(at: url)
                deleted += 1
            } catch {
                let ns = error as NSError
                // 文件不存在（4）/ 目录不存在（260）不算失败
                if ns.domain == NSCocoaErrorDomain && (ns.code == 4 || ns.code == 260) { continue }
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        return (deleted, firstError)
    }

    private static func isPermissionError(_ message: String?) -> Bool {
        guard let message = message else { return false }
        return message.contains("权限") || message.contains("denied") || message.contains("permitted")
    }

    private static var safariDir: URL { home.appendingPathComponent("Library/Safari", isDirectory: true) }
    private static var sharedFileListDir: URL {
        home.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist", isDirectory: true)
    }

    /// 目录能否读取；TCC 拦截时连目录都读不到
    private static func accessError(_ dir: URL) -> String? {
        do {
            _ = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static var historyDB: URL { safariDir.appendingPathComponent("History.db") }

    static func sqlite(_ sql: String, db: URL? = nil) -> (output: String?, error: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [(db ?? historyDB).path, sql]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return (nil, error.localizedDescription)
        }
        process.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus != 0 {
            return (out, (err?.isEmpty == false) ? err : "sqlite3 退出码 \(process.terminationStatus)")
        }
        return (out, nil)
    }

    /// 按时间范围删 Safari 历史（visit_time 用 2001-01-01 起的秒数）
    private static func clearSafariHistory(range: HistoryRange) -> (message: String, needsFDA: Bool) {
        if safariIsRunning {
            return ("Safari 浏览记录：Safari 正在运行，先退出 Safari（运行中的记录会被写回）", false)
        }
        if accessError(safariDir) != nil {
            return ("Safari 浏览记录：没有访问权限", true)
        }

        if range == .all {
            let outcome = remove(safariHistoryFiles)
            if let error = outcome.firstError {
                return ("Safari 浏览记录：\(error)", isPermissionError(error))
            }
            return outcome.deleted > 0
                ? ("Safari 浏览记录：已全部清空", false)
                : ("Safari 浏览记录：没有可清空的记录", false)
        }

        guard FileManager.default.fileExists(atPath: historyDB.path) else {
            return ("Safari 浏览记录：没有可清空的记录", false)
        }
        guard let cutoff = range.cutoff else {
            return ("Safari 浏览记录：范围无效", false)
        }
        let (deleted, deleteError) = deleteHistory(db: historyDB, cutoff: cutoff)
        if let deleteError = deleteError {
            return ("Safari 浏览记录：清理失败（\(deleteError)）", isPermissionError(deleteError))
        }
        guard deleted > 0 else {
            return ("Safari 浏览记录：\(range.title)没有记录", false)
        }
        return ("Safari 浏览记录：已清空「\(range.title)」的 \(deleted) 条", false)
    }

    /// 优雅退出 Safari，等它真的退出（最多约 5 秒）后回调
    static func quitSafari(attempt: Int = 0, completion: @escaping () -> Void) {
        guard safariIsRunning else {
            completion()
            return
        }
        if attempt > 20 {
            completion()
            return
        }
        if attempt == 0 {
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == "com.apple.Safari" }?
                .terminate()
            Log.write("请求退出 Safari")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            quitSafari(attempt: attempt + 1, completion: completion)
        }
    }

    /// 删除 visit_time >= cutoff 的记录，并清掉因此变空的 history_items
    static func deleteHistory(db: URL, cutoff: Date) -> (deleted: Int, error: String?) {
        let stamp = Int(cutoff.timeIntervalSinceReferenceDate.rounded())
        let (countText, countError) = sqlite("SELECT COUNT(*) FROM history_visits WHERE visit_time >= \(stamp);", db: db)
        if let countError = countError { return (0, countError) }
        let count = Int(countText ?? "") ?? 0
        guard count > 0 else { return (0, nil) }
        let (_, deleteError) = sqlite("""
        BEGIN;
        DELETE FROM history_visits WHERE visit_time >= \(stamp);
        DELETE FROM history_items WHERE id NOT IN (SELECT DISTINCT history_item FROM history_visits);
        COMMIT;
        """, db: db)
        if let deleteError = deleteError { return (count, deleteError) }
        return (count, nil)
    }

    static func clear(safariHistory: Bool, recentFiles: Bool, range: HistoryRange) -> Result {
        var lines: [String] = []
        var needsFDA = false

        if safariHistory {
            let result = clearSafariHistory(range: range)
            lines.append(result.message)
            needsFDA = needsFDA || result.needsFDA
        }

        if recentFiles {
            if accessError(sharedFileListDir) != nil {
                lines.append("最近使用文件记录：没有访问权限")
                needsFDA = true
            } else {
                let outcome = remove(recentFileLists)
                if let error = outcome.firstError {
                    lines.append("最近使用文件记录：\(error)")
                    if isPermissionError(error) { needsFDA = true }
                } else if outcome.deleted > 0 {
                    lines.append("最近使用文件记录：已清空 \(outcome.deleted) 项（重启 Finder 后列表刷新）")
                } else {
                    lines.append("最近使用文件记录：没有可清空的记录")
                }
            }
        }

        if needsFDA {
            lines.append("需要在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」里勾选 MacKit 后重试")
        }
        return Result(message: lines.joined(separator: "\n"), needsFullDiskAccess: needsFDA)
    }

    /// 只读自检：列出清空操作会碰到哪些文件，不删除任何东西
    static func describeTargets() -> [String] {
        var lines: [String] = []
        lines.append("Safari 运行中: \(safariIsRunning ? "是" : "否")")
        if let error = accessError(safariDir) {
            lines.append("Safari 记录目录: 无法访问（\(error)）→ 需要完全磁盘访问权限")
        } else {
            lines.append("Safari 记录目录: 可访问")
            for url in safariHistoryFiles {
                let exists = FileManager.default.fileExists(atPath: url.path)
                lines.append("  \(exists ? "存在" : "不存在")  \(url.lastPathComponent)")
            }
        }
        lines.append("最近使用目录: \(sharedFileListDir.path)")
        if let error = accessError(sharedFileListDir) {
            lines.append("  无法访问（\(error)）")
        } else {
            let files = recentFileLists
            let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
            lines.append("  可访问，待清理 \(existing.count) 项")
            for url in existing.prefix(10) {
                lines.append("    \(url.lastPathComponent)")
            }
        }
        return lines
    }
}

// MARK: - 界面数据模型

final class MacKitModel: ObservableObject {
    struct Row: Identifiable {
        let id = UUID()
        let index: Int
        let keys: String
        let target: String
        let name: String
        let resolved: String
        let ok: Bool
    }

    @Published var rows: [Row] = []
    @Published var status: String = "就绪"
    @Published var loginItemEnabled: Bool = false
    @Published var icon: NSImage? = NSApp.applicationIconImage
    @Published var showMenuBarIcon: Bool = Preferences.showMenuBarIcon
    @Published var showDockIcon: Bool = Preferences.showDockIcon

    /// iCloud 文件夹同步；由 AppDelegate 注入读写当前配置的闭包。
    let syncEngine: MacKitCloudSyncEngine
    let clipboard: ClipboardHistory
    let scrollReversal = ScrollReversal()

    init(clipboard: ClipboardHistory = ClipboardHistory(), syncEngine: MacKitCloudSyncEngine = MacKitCloudSyncEngine()) {
        self.clipboard = clipboard
        self.syncEngine = syncEngine
    }

    // 设置窗口的侧栏选中项 / 清空确认弹窗
    @Published var page: SettingsPage = .tools
    @Published var showClearConfirm: Bool = false

    // 侧栏顺序（可拖动），记住用户排的次序
    @Published var pageOrder: [SettingsPage] = Preferences.sidebarOrder {
        didSet {
            Preferences.sidebarOrder = pageOrder
            onSidebarOrderChanged()
        }
    }
    @Published var draggingPage: SettingsPage?
    @Published var selfHotkeyEnabled: Bool = Preferences.selfHotkeyEnabled

    // 菜单栏图标折叠
    @Published var menuBarCollapsed: Bool = false
    @Published var collapseOnLaunch: Bool = Preferences.collapseOnLaunch
    @Published var menuBarToggleVisible: Bool = Preferences.menuBarToggleVisible
    @Published var hiddenBundleIDs: [String] = Preferences.hiddenBundleIDs

    struct AppEntry: Identifiable, Hashable {
        let id: String
        let name: String
    }

    @Published var runningApps: [AppEntry] = []

    func refreshRunningApps() {
        let own = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .compactMap { app -> AppEntry? in
                guard let id = app.bundleIdentifier,
                      id != own,
                      !id.hasPrefix("com.apple.") else { return nil }
                return AppEntry(id: id, name: app.localizedName ?? id)
            }
        var seen = Set<String>()
        runningApps = apps
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // 一键关闭所有 App：普通前台 App + 白名单豁免
    struct QuitApp: Identifiable, Hashable {
        let id: String
        let name: String
        let path: String
    }

    @Published var quitWhitelist: [String] = Preferences.quitAllWhitelist
    @Published var quitCandidates: [QuitApp] = []
    @Published var quitStatus: String = ""
    @Published var quitTargetCount: Int = 0
    @Published var quitTargetIDs: [String] = []
    @Published var showQuitAllConfirm: Bool = false

    private static let finderBundleID = "com.apple.finder"

    private func quitIdentifier(for app: NSRunningApplication) -> String? {
        if let id = app.bundleIdentifier, !id.isEmpty { return id }
        if let path = app.bundleURL?.path, !path.isEmpty { return path }
        return nil
    }

    private func isQuitCandidate(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular, !app.isTerminated else { return false }
        guard let id = quitIdentifier(for: app) else { return false }
        return id != Bundle.main.bundleIdentifier && id != Self.finderBundleID
    }

    private var quitTargets: [NSRunningApplication] {
        let whitelist = Set(quitWhitelist)
        return NSWorkspace.shared.runningApplications.filter { app in
            guard isQuitCandidate(app), let id = quitIdentifier(for: app) else { return false }
            return !whitelist.contains(id)
        }
    }

    func refreshQuitCandidates() {
        var seen = Set<String>()
        quitCandidates = NSWorkspace.shared.runningApplications
            .filter { isQuitCandidate($0) }
            .compactMap { app -> QuitApp? in
                guard let id = quitIdentifier(for: app) else { return nil }
                return QuitApp(
                    id: id,
                    name: app.localizedName ?? id,
                    path: app.bundleURL?.path ?? ""
                )
            }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func toggleQuitWhitelist(_ id: String) {
        if let index = quitWhitelist.firstIndex(of: id) {
            quitWhitelist.remove(at: index)
        } else {
            quitWhitelist.append(id)
        }
        Preferences.quitAllWhitelist = quitWhitelist
        onQuitWhitelistChanged()
    }

    /// 应用来自同步文件夹的设置；此时不应再把它当成新的本机改动。
    func applySyncedPreferences(sidebarOrder: [SettingsPage], quitWhitelist: [String]) {
        if pageOrder != sidebarOrder { pageOrder = sidebarOrder }
        if self.quitWhitelist != quitWhitelist { self.quitWhitelist = quitWhitelist }
        Preferences.quitAllWhitelist = quitWhitelist
    }

    func requestQuitAllApps() {
        refreshQuitCandidates()
        let targets = quitTargets
        quitTargetCount = targets.count
        quitTargetIDs = targets.compactMap { quitIdentifier(for: $0) }
        guard !targets.isEmpty else {
            quitStatus = "没有需要关闭的 App"
            return
        }
        quitStatus = ""
        showQuitAllConfirm = true
    }

    func confirmQuitAllApps() {
        let ids = Set(quitTargetIDs)
        let whitelist = Set(quitWhitelist)
        let targets = NSWorkspace.shared.runningApplications.filter { app in
            guard isQuitCandidate(app), let id = quitIdentifier(for: app) else { return false }
            return ids.contains(id) && !whitelist.contains(id)
        }
        quitTargetIDs = []
        guard !targets.isEmpty else {
            quitStatus = "没有需要关闭的 App"
            return
        }

        var requested = 0
        var failed = 0
        var names: [String] = []
        for app in targets {
            if app.terminate() {
                requested += 1
                names.append(app.localizedName ?? app.bundleIdentifier ?? "未知 App")
            } else {
                failed += 1
            }
        }

        if failed == 0 {
            quitStatus = "已向 \(requested) 个 App 发送退出请求"
        } else {
            quitStatus = "已向 \(requested) 个 App 发送退出请求，\(failed) 个未能退出"
        }
        Log.write("一键关闭 App：\(quitStatus)")
        if !names.isEmpty {
            Log.write("关闭目标：\(names.joined(separator: "、"))")
        }
        refreshQuitCandidates()
    }
    @Published var menuBarSeparatorVisible: Bool = Preferences.menuBarSeparatorVisible

    // 更新检查
    @Published var autoUpdateCheck: Bool = Preferences.autoUpdateCheck
    @Published var updateStatus: String = ""
    @Published var availableUpdate: UpdateChecker.Release?
    private var dragStartIndex = 0
    private let sidebarRowHeight: CGFloat = 34

    func dragSidebarItem(_ item: SettingsPage, translation: CGFloat) {
        guard let index = pageOrder.firstIndex(of: item) else { return }
        if draggingPage != item {
            draggingPage = item
            dragStartIndex = index
        }
        let steps = Int((translation / sidebarRowHeight).rounded())
        let target = min(max(dragStartIndex + steps, 0), pageOrder.count - 1)
        guard target != index else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            pageOrder.move(fromOffsets: IndexSet(integer: index), toOffset: target > index ? target + 1 : target)
        }
    }

    func endSidebarDrag() {
        draggingPage = nil
    }

    // 常用工具：清理记录
    @Published var clearSafariHistory: Bool = true
    @Published var historyRange: HistoryRange = .today
    @Published var clearRecentFiles: Bool = true
    @Published var toolsStatus: String = ""
    @Published var toolsNeedsFullDiskAccess: Bool = false
    @Published var toolsLastRun: Date?
    @Published var showQuitSafariConfirm: Bool = false

    /// 点「清空」后的入口：Safari 在跑就先问要不要退
    func requestClearRecords() {
        guard clearSafariHistory || clearRecentFiles else {
            toolsStatus = "先勾选要清理的选项"
            return
        }
        if clearSafariHistory && RecordCleaner.safariIsRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.showQuitSafariConfirm = true
            }
        } else {
            clearSelectedRecords()
        }
    }

    func quitSafariAndClear() {
        toolsStatus = "正在退出 Safari…"
        RecordCleaner.quitSafari { [weak self] in
            self?.clearSelectedRecords()
        }
    }

    func clearSelectedRecords() {
        guard clearSafariHistory || clearRecentFiles else {
            toolsStatus = "先勾选要清理的选项"
            return
        }
        let result = RecordCleaner.clear(
            safariHistory: clearSafariHistory,
            recentFiles: clearRecentFiles,
            range: historyRange
        )
        toolsStatus = result.message
        toolsNeedsFullDiskAccess = result.needsFullDiskAccess
        toolsLastRun = Date()
    }

    var onReload: () -> Void = {}
    var onSidebarOrderChanged: () -> Void = {}
    var onQuitWhitelistChanged: () -> Void = {}
    var onToggleLogin: () -> Void = {}
    var onOpenConfig: () -> Void = {}
    var onOpenLog: () -> Void = {}
    var onBatchEditShortcuts: () -> Void = {}
    var onAddShortcut: (String, [String], String) -> String? = { _, _, _ in nil }
    var onDeleteShortcut: (Int) -> Void = { _ in }
    var onQuit: () -> Void = {}
    var onCloseWindow: () -> Void = {}
    var onToggleMenuBarIcon: () -> Void = {}
    var onToggleDockIcon: () -> Void = {}
    var onToggleSelfHotkey: () -> Void = {}
    var onCheckUpdate: () -> Void = {}
    var onToggleAutoUpdate: () -> Void = {}
    var onOpenUpdate: () -> Void = {}
    var onToggleMenuBarCollapse: () -> Void = {}
    var onToggleCollapseOnLaunch: () -> Void = {}
    var onToggleMenuBarToggleVisible: () -> Void = {}
    var onToggleKeepApp: (String) -> Void = { _ in }
    var onToggleMenuBarSeparatorVisible: () -> Void = {}
}

// MARK: - SwiftUI 界面

enum SettingsPage: String, CaseIterable, Identifiable {
    case tools
    case launcher
    case menuBar
    case clipboard
    case scroll
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tools: return "常用工具"
        case .launcher: return "快捷启动"
        case .menuBar: return "状态栏隐藏"
        case .clipboard: return "剪贴板"
        case .scroll: return "滚动反转"
        case .settings: return "基础设置"
        }
    }

    var symbol: String {
        switch self {
        case .tools: return "wand.and.stars"
        case .launcher: return "command"
        case .menuBar: return "menubar.rectangle"
        case .clipboard: return "doc.on.clipboard"
        case .scroll: return "arrow.up.arrow.down"
        case .settings: return "gearshape"
        }
    }
}

final class SettingsViewState: ObservableObject {
    @Published var showAddShortcut = false
    @Published var showQuitWhitelist = false
}

struct SettingsView: View {
    @ObservedObject var model: MacKitModel
    @StateObject private var viewState = SettingsViewState()

    private var page: SettingsPage { model.page }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 178)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
            detail
        }
        .frame(width: 720, height: 620)
        .sheet(isPresented: $viewState.showAddShortcut) {
            AddShortcutView(
                onAdd: { key, modifiers, target in
                    model.onAddShortcut(key, modifiers, target)
                },
                onCancel: {
                    viewState.showAddShortcut = false
                }
            )
        }
        .sheet(isPresented: $viewState.showQuitWhitelist) {
            QuitWhitelistView(model: model) {
                viewState.showQuitWhitelist = false
            }
        }
        .alert("清空这些记录？", isPresented: $model.showClearConfirm) {
            Button("清空", role: .destructive) { model.requestClearRecords() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("Safari 浏览记录和最近使用文件记录，清空后无法恢复。")
        }

    }

    // MARK: 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            identity

            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.pageOrder) { item in
                    navItem(item)
                        .gesture(
                            DragGesture(minimumDistance: 3)
                                .onChanged { value in
                                    model.dragSidebarItem(item, translation: value.translation.height)
                                }
                                .onEnded { _ in model.endSidebarDrag() }
                        )
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 2) {
                Text("v\(UpdateChecker.currentVersion)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("⌥⌘, 随时打开设置")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 10)
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 18)
        .padding(.bottom, 24)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var identity: some View {
        HStack(spacing: 10) {
            if let icon = model.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1.5)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("MacKit")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("快捷键启动器")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    private func navItem(_ item: SettingsPage) -> some View {
        let selected = page == item
        return Button {
            model.page = item
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? AnyShapeStyle(.quaternary.opacity(0.9)) : AnyShapeStyle(Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(model.draggingPage == item ? 0.45 : 1)
        .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
    }

    // MARK: 右侧内容

    private var detail: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(page.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                if page == .clipboard {
                    Spacer()
                    Text(model.clipboard.hotkeyStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("打开历史") { model.clipboard.onOpen() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            if page == .clipboard {
                // 整页只有一个滚动区域：设置、置顶和历史都能到达，标题和底部不被挤出窗口。
                ScrollView(.vertical, showsIndicators: true) {
                    ClipboardSettingsPage(history: model.clipboard)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 6)
                        .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .accessibilityIdentifier("clipboardSettingsScroll")
            } else {
                switch page {
                case .tools: toolsPage
                case .launcher: launcherPage
                case .menuBar: menuBarPage
                case .clipboard: EmptyView()
                case .scroll: ScrollSettingsPage(engine: model.scrollReversal)
                case .settings: appSettingsPage
                }
                Spacer(minLength: 0)
            }

            footer.fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var launcherPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("快捷键")
            shortcutList
        }
    }

    @ViewBuilder
    private var menuBarPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("折叠")

            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Label("当前状态", systemImage: model.menuBarCollapsed ? "chevron.right.circle" : "chevron.left.circle")
                        .font(.system(size: 13))
                    Spacer()
                    Text(model.menuBarCollapsed ? "已折叠" : "已展开")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button {
                        model.onToggleMenuBarCollapse()
                    } label: {
                        Label(model.menuBarCollapsed ? "展开" : "折叠",
                              systemImage: model.menuBarCollapsed ? "chevron.right" : "chevron.left")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.quaternary.opacity(0.4))
                )

                settingRow("启动时折叠", symbol: "arrow.uturn.left", isOn: Binding(
                    get: { model.collapseOnLaunch },
                    set: { _ in model.onToggleCollapseOnLaunch() }
                ))
            }

            if MenuBarHider.usesNativeEngine {
                sectionLabel("需要隐藏的 App")
                keepAppsList
                Text("勾选的 App 图标会被隐藏，其余保留；时钟、Wi-Fi、控制中心等系统项始终保留。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }

            sectionLabel("菜单栏上的按钮")
            VStack(spacing: 6) {
                settingRow("显示折叠箭头", symbol: "chevron.left", isOn: Binding(
                    get: { model.menuBarToggleVisible },
                    set: { _ in model.onToggleMenuBarToggleVisible() }
                ))
                if !MenuBarHider.usesNativeEngine {
                    settingRow("显示分隔线", symbol: "minus", isOn: Binding(
                        get: { model.menuBarSeparatorVisible },
                        set: { _ in model.onToggleMenuBarSeparatorVisible() }
                    ))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                if MenuBarHider.usesNativeEngine {
                    Label("macOS 27 方案：由系统按白名单隐藏图标，任意显示器、刘海屏都有效", systemImage: "info.circle")
                } else {
                    Label("⌘ 拖动菜单栏上的细线，把它放到「想隐藏的图标」和「箭头」之间", systemImage: "info.circle")
                }
                Label("隐藏按钮后，仍可从「偏好设置…」进入状态栏隐藏页，或用 ⌘⌥K 打开主界面", systemImage: "info.circle")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var keepAppsList: some View {
        let content = VStack(spacing: 4) {
            if model.runningApps.isEmpty {
                Text("没有可选的 App")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
            ForEach(model.runningApps) { app in
                HStack(spacing: 10) {
                    Text(app.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    GlassSwitch(isOn: Binding(
                        get: { model.hiddenBundleIDs.contains(app.id) },
                        set: { _ in model.onToggleKeepApp(app.id) }
                    ))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.quaternary.opacity(0.3))
                )
            }
        }

        if model.runningApps.count > 6 {
            ScrollView { content }
                .frame(height: 176)
        } else {
            content
        }
    }

    private var appSettingsPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("应用")
            settingsRows

            sectionLabel("同步")
            MacKitSyncSettingsCard(engine: model.syncEngine)

            sectionLabel("关于")
            updateRows

            sectionLabel("配置与日志")
            configurationActions
        }
    }

    private var configurationActions: some View {
        HStack(spacing: 8) {
            maintenanceButton("重新加载配置", action: model.onReload)
            maintenanceButton("配置文件", action: model.onOpenConfig)
            maintenanceButton("打开日志", action: model.onOpenLog)
        }
    }

    private func maintenanceButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        )
    }

    private var quitAllCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("关闭所有 App", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 13))
                Spacer(minLength: 6)
                Text("白名单 \(model.quitWhitelist.count) 个")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button {
                    model.refreshQuitCandidates()
                    viewState.showQuitWhitelist = true
                } label: {
                    Text("管理白名单…")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    model.requestQuitAllApps()
                } label: {
                    Label("全部关闭", systemImage: "power")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            }

            Text("只关闭普通 App；Finder、MacKit 自身始终保留。白名单内的 App 不会被关闭。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            if !model.quitStatus.isEmpty {
                Text(model.quitStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        )
    }

    private var updateRows: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                settingsLabel("版本 \(UpdateChecker.currentVersion)", symbol: "info.circle")
                Spacer(minLength: 8)
                Text(model.updateStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(model.availableUpdate == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button("检查更新") {
                    model.onCheckUpdate()
                }
                .font(.system(size: 11))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
            )

            HStack(spacing: 10) {
                settingsLabel("自动检查更新", symbol: "clock.arrow.circlepath")
                Spacer(minLength: 8)
                GlassSwitch(isOn: Binding(
                    get: { model.autoUpdateCheck },
                    set: { _ in model.onToggleAutoUpdate() }
                ))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
            )

            if let update = model.availableUpdate {
                HStack {
                    Spacer()
                    Button("下载 \(update.version)") {
                        model.onOpenUpdate()
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }

    private func settingsLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 18, height: 18)
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var toolsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("清理记录")

            VStack(spacing: 6) {
                toolCard(
                    "Safari 浏览记录",
                    subtitle: "删除本机 Safari 历史记录，需要完全磁盘访问权限",
                    symbol: "safari",
                    isOn: $model.clearSafariHistory
                ) {
                    historyRangeRow
                }
                toolRow(
                    "最近使用文件记录",
                    subtitle: "清空「最近使用」列表和各 App 的最近文件",
                    symbol: "clock.arrow.circlepath",
                    isOn: $model.clearRecentFiles
                )
            }

            HStack {
                Button {
                    model.showClearConfirm = true
                } label: {
                    Label("一键清空记录", systemImage: "trash")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!model.clearSafariHistory && !model.clearRecentFiles)

                Spacer()
            }

            if !model.toolsStatus.isEmpty {
                Text(model.toolsStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(model.toolsNeedsFullDiskAccess ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if model.toolsNeedsFullDiskAccess {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "lock.shield")
                        Text("这两个目录受系统保护，先在「隐私与安全性 → 完全磁盘访问权限」里勾选 MacKit，然后重启 App")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("打开完全磁盘访问权限设置", systemImage: "gearshape")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                }
            }

            Text("清空后无法恢复；Finder 的最近列表重启 Finder 后刷新。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            sectionLabel("批量关闭")
            quitAllCard
                .alert("关闭所有 App？", isPresented: $model.showQuitAllConfirm) {
                    Button("关闭", role: .destructive) { model.confirmQuitAllApps() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("将关闭 \(model.quitTargetCount) 个 App，白名单中的 \(model.quitWhitelist.count) 个会保留。未保存的内容可能弹出保存提示。")
                }
        }
        .alert("Safari 正在运行", isPresented: $model.showQuitSafariConfirm) {
            Button("退出 Safari 并清空", role: .destructive) { model.quitSafariAndClear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清空浏览记录前需要先退出 Safari，否则运行中的记录会被写回。")
        }
    }

    private var historyRangeRow: some View {
        HStack(spacing: 0) {
            Text("范围")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 0)

            HStack(spacing: 2) {
                ForEach(HistoryRange.allCases) { range in
                    let selected = model.historyRange == range
                    Button {
                        model.historyRange = range
                    } label: {
                        Text(range.title)
                            .font(.system(size: 11, weight: selected ? .medium : .regular))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selected ? AnyShapeStyle(Color.primary.opacity(0.14)) : AnyShapeStyle(Color.clear))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )

            Spacer(minLength: 0)
        }
        .padding(.leading, 30)
        .padding(.bottom, 2)
        .transition(.opacity)
    }

    private func toolCard<Extra: View>(
        _ title: String,
        subtitle: String,
        symbol: String,
        isOn: Binding<Bool>,
        @ViewBuilder extra: () -> Extra
    ) -> some View {
        VStack(spacing: 8) {
            toolRowContent(title, subtitle: subtitle, symbol: symbol, isOn: isOn)
            if isOn.wrappedValue {
                extra()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        )
    }

    private func toolRow(_ title: String, subtitle: String, symbol: String, isOn: Binding<Bool>) -> some View {
        toolRowContent(title, subtitle: subtitle, symbol: symbol, isOn: isOn)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
            )
    }

    private func toolRowContent(_ title: String, subtitle: String, symbol: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            GlassSwitch(isOn: isOn)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if page == .clipboard {
                HStack(spacing: 10) {
                    Text(footerText).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("退出") { model.onQuit() }.controlSize(.small)
                }
            } else {
                Text(footerText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                actions
            }
        }
    }

    private var footerText: String {
        switch page {
        case .tools: return toolsFooterText
        case .settings: return "修改即时生效"
        case .launcher: return model.status
        case .menuBar: return "点箭头即可折叠 / 展开"
        case .clipboard: return "⌥Space 打开历史；回车复制，↑↓ 选择，Esc 关闭"
        case .scroll: return "设置仅保存在本机，关闭后恢复原滚动方向"
        }
    }

    private var toolsFooterText: String {
        guard let last = model.toolsLastRun else { return "勾选后点「一键清空记录」" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "上次清空：\(formatter.string(from: last))"
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .kerning(0.6)
    }

    @ViewBuilder
    private var shortcutList: some View {
        let content = VStack(spacing: 6) {
            if model.rows.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "command")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("还没有快捷键")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("点下方「添加快捷键」，选择 App 后按下组合键即可。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.quaternary.opacity(0.25))
                )
            }

            ForEach(model.rows) { row in
                HStack(spacing: 12) {
                    Text(row.keys)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .frame(minWidth: 58, minHeight: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(.quaternary)
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Text(row.resolved)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: row.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(row.ok ? Color.green : Color.orange)
                    Button {
                        model.onDeleteShortcut(row.index)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("移除这个快捷键")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.quaternary.opacity(0.4))
                )
            }
        }

        if model.rows.count > 8 {
            ScrollView { content }
                .frame(maxHeight: 360)
        } else {
            content
        }
    }

    private var settingsRows: some View {
        VStack(spacing: 4) {
            settingRow("登录时自动启动", symbol: "power", isOn: Binding(
                get: { model.loginItemEnabled },
                set: { _ in model.onToggleLogin() }
            ), verticalPadding: 6)
            settingRow("显示菜单栏图标", symbol: "menubar.rectangle", isOn: Binding(
                get: { model.showMenuBarIcon },
                set: { _ in model.onToggleMenuBarIcon() }
            ), verticalPadding: 6)
            settingRow("显示 Dock 图标", symbol: "dock.rectangle", isOn: Binding(
                get: { model.showDockIcon },
                set: { _ in model.onToggleDockIcon() }
            ), verticalPadding: 6)
            settingRow("⌘⌥K 打开设置窗口", symbol: "keyboard", isOn: Binding(
                get: { model.selfHotkeyEnabled },
                set: { _ in model.onToggleSelfHotkey() }
            ), verticalPadding: 6)

            if !model.showMenuBarIcon && !model.showDockIcon {
                Label("两者都已隐藏，用 ⌥⌘, 打开这个窗口", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
        }
    }

    private func settingRow(_ title: String, symbol: String, isOn: Binding<Bool>, verticalPadding: CGFloat = 8) -> some View {
        HStack {
            Label(title, systemImage: symbol)
                .font(.system(size: 13))
            Spacer()
            GlassSwitch(isOn: isOn)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        )
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if page == .launcher {
                Button {
                    viewState.showAddShortcut = true
                } label: {
                    Label("添加快捷键", systemImage: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderedProminent)

                Button("批量编辑") { model.onBatchEditShortcuts() }
                    .font(.system(size: 12))
                    .buttonStyle(.bordered)

                Button {
                    model.onReload()
                } label: {
                    Label("重新加载", systemImage: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            Button("退出") { model.onQuit() }
                .font(.system(size: 12))
                .buttonStyle(.bordered)
        }
    }
}

// MARK: - 关闭白名单

private struct QuitWhitelistView: View {
    @ObservedObject var model: MacKitModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("关闭白名单")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text("勾选要保留运行的 App；MacKit 和 Finder 始终保留。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()

            ScrollView {
                VStack(spacing: 4) {
                    if model.quitCandidates.isEmpty {
                        Text("当前没有运行中的 App")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                    }

                    ForEach(model.quitCandidates) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Text(app.id)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            GlassSwitch(isOn: Binding(
                                get: { model.quitWhitelist.contains(app.id) },
                                set: { _ in model.toggleQuitWhitelist(app.id) }
                            ))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(.quaternary.opacity(0.3))
                        )
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack {
                Text("已豁免 \(model.quitWhitelist.count) 个 App")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 540)
        .onAppear { model.refreshQuitCandidates() }
    }
}

// MARK: - 添加快捷键

private final class AddShortcutViewState: ObservableObject {
    @Published var appURL: URL?
    @Published var key = ""
    @Published var modifiers: [String] = []
    @Published var error = ""
}

private struct AddShortcutView: View {
    var onAdd: (String, [String], String) -> String?
    var onCancel: () -> Void

    @StateObject private var state = AddShortcutViewState()

    private var appName: String {
        guard let url = state.appURL else { return "未选择应用" }
        let bundle = Bundle(url: url)
        let info = bundle?.localizedInfoDictionary ?? bundle?.infoDictionary
        if let name = info?["CFBundleDisplayName"] as? String, !name.isEmpty { return name }
        if let name = info?["CFBundleName"] as? String, !name.isEmpty { return name }
        return url.deletingPathExtension().lastPathComponent
    }

    private var modifierOK: Bool {
        !Set(KeyCodes.canonicalModifiers(state.modifiers))
            .isDisjoint(with: ["command", "option", "control"])
    }

    private var canAdd: Bool {
        state.appURL != nil && !state.key.isEmpty && modifierOK
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("添加快捷键")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("选择一个应用，再按下想使用的组合键。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                if let appURL = state.appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 36, height: 36)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.tertiary)
                        .frame(width: 36, height: 36)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(appName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(state.appURL?.path ?? "选择一个 .app")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button("选择…") { chooseApp() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("快捷键")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                KeyRecorderBox(
                    key: $state.key,
                    modifiers: $state.modifiers,
                    onChange: { state.error = "" }
                )
                Text("至少包含 ⌘、⌥ 或 ⌃ 中的一个；点击上方按键区域后直接按下组合键。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            if !state.error.isEmpty {
                Label(state.error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("添加") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "选择要启动的应用"
        panel.prompt = "选择"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            state.appURL = url
            state.error = ""
        }
    }

    private func submit() {
        guard let url = state.appURL else {
            state.error = "先选择一个应用"
            return
        }
        guard !state.key.isEmpty, modifierOK else {
            state.error = "快捷键至少需要 ⌘、⌥ 或 ⌃ 中的一个"
            return
        }
        let target = Bundle(url: url)?.bundleIdentifier ?? url.path
        if let message = onAdd(state.key, state.modifiers, target) {
            state.error = message
        } else {
            onCancel()
        }
    }
}

private struct KeyRecorderBox: View {
    @Binding var key: String
    @Binding var modifiers: [String]
    var onChange: () -> Void

    private var label: String {
        guard !key.isEmpty else { return "" }
        return "\(KeyCodes.display(modifiers))\(KeyCodes.keyLabel(key))"
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.quaternary.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

            HStack(spacing: 8) {
                if key.isEmpty {
                    Text("点击后按下组合键…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    Text(label)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                }
                Spacer(minLength: 0)
                Image(systemName: "keyboard")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)

            KeyCaptureRepresentable { newKey, newModifiers in
                key = newKey
                modifiers = newModifiers
                onChange()
            }
        }
        .frame(height: 44)
    }
}

private struct KeyCaptureRepresentable: NSViewRepresentable {
    var onCapture: (String, [String]) -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
    }
}

private final class KeyCaptureNSView: NSView {
    var onCapture: ((String, [String]) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let key = KeyCodes.name(for: event.keyCode) else {
            NSSound.beep()
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: [String] = []
        if flags.contains(.control) { modifiers.append("control") }
        if flags.contains(.option) { modifiers.append("option") }
        if flags.contains(.command) { modifiers.append("command") }
        if flags.contains(.shift) { modifiers.append("shift") }
        onCapture?(key, modifiers)
    }
}

/// 自绘开关：胶囊底 + 圆形滑块，跟着系统强调色走，未开启时是半透明灰
struct GlassSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Capsule(style: .continuous)
            .fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.18)))
            .frame(width: 40, height: 23)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .padding(2.5)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, x: 0, y: 1)
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.85), value: isOn)
            .contentShape(Capsule())
            .onTapGesture { isOn.toggle() }
    }
}

// MARK: - 设置窗口

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: MacKitModel
    var onClose: (() -> Void)?

    init(model: MacKitModel) {
        self.model = model

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "MacKit"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false

        super.init(window: window)

        let host = NSHostingView(rootView: SettingsView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false

        let background = SettingsBackgroundView()
        background.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(background)
        container.addSubview(host)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            background.topAnchor.constraint(equalTo: container.topAnchor),
            background.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        window.contentView = container
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    func present() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// macOS 26+ 用 Liquid Glass（NSGlassEffectView），更早的系统回退到毛玻璃
final class SettingsBackgroundView: NSView {
    private var glass: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        if #available(macOS 26.0, *) {
            let effect = NSGlassEffectView()
            effect.style = .regular
            effect.cornerRadius = 0
            if #available(macOS 27.0, *) {
                effect.effectIsInteractive = true
            }
            addSubview(effect)
            effect.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                effect.leadingAnchor.constraint(equalTo: leadingAnchor),
                effect.trailingAnchor.constraint(equalTo: trailingAnchor),
                effect.topAnchor.constraint(equalTo: topAnchor),
                effect.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            glass = effect
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            addSubview(effect)
            effect.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                effect.leadingAnchor.constraint(equalTo: leadingAnchor),
                effect.trailingAnchor.constraint(equalTo: trailingAnchor),
                effect.topAnchor.constraint(equalTo: topAnchor),
                effect.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }
}

// MARK: - 全局快捷键

private let hotKeySignature: OSType = 0x4150_4C4E // 'APLN'
private let settingsHotKeyID: UInt32 = 0xF000   // 保留 id：⌥⌘, 打开设置窗口
private let selfHotKeyID: UInt32 = 0xF001       // 保留 id：⌘⌥K 打开设置窗口
private let clipboardHotKeyID: UInt32 = 0xF002 // ⌥Space 剪贴板
private let clipboardEntryHotKeyBase: UInt32 = 0xE100 // 剪贴板条目自定义快捷键

private let hotKeyCallback: EventHandlerUPP = { _, event, userData in
    guard let userData = userData else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return noErr }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    DispatchQueue.main.async {
        delegate.fire(id: id)
    }
    return noErr
}

// MARK: - macOS 27 菜单栏可见性（私有框架桥接）

enum NativeVisibility {
    static var isAvailable: Bool { MBVisibilityAvailable() }

    final class Assertion {
        private var handle: UnsafeMutableRawPointer?

        init(_ handle: UnsafeMutableRawPointer) {
            self.handle = handle
        }

        func invalidate() {
            guard let handle = handle else { return }
            MBVisibilityRelease(handle)
            self.handle = nil
        }

        deinit {
            invalidate()
        }
    }

    /// 只保留系统项和这些 App 的菜单栏图标
    static func activate(keep bundleIDs: [String], completion: @escaping (Result<Assertion, Error>) -> Void) {
        let systemItems = (0..<64).map { NSNumber(value: $0) }
        MBVisibilityActivate(systemItems, bundleIDs) { assertion, error in
            if let assertion = assertion {
                completion(.success(Assertion(assertion)))
            } else {
                completion(.failure(error ?? NSError(domain: "MacKit", code: 1)))
            }
        }
    }
}

// MARK: - 菜单栏图标折叠（类似 Hidden Bar）

/// 一条可 ⌘ 拖动的分隔线 + 一个箭头：分隔线左侧的图标在折叠时被顶出屏幕
final class MenuBarHider {
    let separator: NSStatusItem
    let toggle: NSStatusItem
    private(set) var isCollapsed = false

    var onToggle: (() -> Void)?
    /// 原生方案下要隐藏的 App
    var hiddenBundleIDs: [String] = []
    /// 当前运行中的 App（用于推算白名单：没被勾选隐藏的都保留）
    var runningBundleIDs: () -> [String] = { [] }

    private var assertion: NativeVisibility.Assertion?
    private let separatorWidth: CGFloat = 8
    private let expandedWidth: CGFloat = 10000

    /// macOS 27 起用系统可见性白名单，老系统仍用撑宽分隔条
    static var usesNativeEngine: Bool { NativeVisibility.isAvailable }

    init() {
        separator = NSStatusBar.system.statusItem(withLength: 8)
        separator.autosaveName = "MacKitHiddenSeparatorTS"
        if let button = separator.button {
            button.image = Self.separatorImage()
            button.toolTip = "⌘ 拖动这条细线，划分要折叠的图标"
        }

        toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggle.autosaveName = "MacKitHiderToggleTS"
        if let button = toggle.button {
            button.image = Self.chevron(collapsed: false)
            button.toolTip = "折叠菜单栏图标"
        }

        // 两个 item 建好之后再挂 target，避免 init 里提前使用 self
        separator.button?.target = self
        separator.button?.action = #selector(toggleFromSeparator)
        toggle.button?.target = self
        toggle.button?.action = #selector(toggleFromSeparator)
    }

    private static func separatorImage() -> NSImage {
        let size = NSSize(width: 1, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func chevron(collapsed: Bool) -> NSImage? {
        let name = collapsed ? "chevron.right" : "chevron.left"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: collapsed ? "展开菜单栏图标" : "折叠菜单栏图标")
        image?.isTemplate = true
        return image
    }

    func setCollapsed(_ collapsed: Bool) {
        guard Self.usesNativeEngine else {
            isCollapsed = collapsed
            separator.length = collapsed ? expandedWidth : separatorWidth
            applyIcon()
            return
        }

        if collapsed {
            guard assertion == nil else { return }
            let keep = allowedBundleIDs()
            NativeVisibility.activate(keep: keep) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let assertion):
                    self.assertion = assertion
                    self.isCollapsed = true
                    Log.write("已隐藏其它菜单栏图标（保留 \(keep.count) 个）")
                case .failure(let error):
                    self.isCollapsed = false
                    Log.write("隐藏菜单栏图标失败：\(error.localizedDescription)")
                }
                self.applyIcon()
                self.onToggle?()
            }
        } else {
            assertion?.invalidate()
            assertion = nil
            isCollapsed = false
            Log.write("已恢复菜单栏图标")
            applyIcon()
            onToggle?()
        }
    }

    /// 白名单 = 运行中且没被勾选隐藏的 App，加上自己
    private func allowedBundleIDs() -> [String] {
        var allowed = runningBundleIDs().filter { !hiddenBundleIDs.contains($0) }
        if let own = Bundle.main.bundleIdentifier, !allowed.contains(own) {
            allowed.append(own)
        }
        return allowed
    }

    private func applyIcon() {
        toggle.button?.image = Self.chevron(collapsed: isCollapsed)
        toggle.button?.toolTip = isCollapsed ? "展开菜单栏图标" : "折叠菜单栏图标"
    }

    /// 退出前解除限制，避免菜单栏停在被隐藏的状态
    func reset() {
        assertion?.invalidate()
        assertion = nil
        isCollapsed = false
    }

    func toggleCollapsed() {
        setCollapsed(!isCollapsed)
        onToggle?()
    }

    @objc private func toggleFromSeparator() {
        toggleCollapsed()
    }
}

// MARK: - 检查更新（GitHub Release）

enum UpdateChecker {
    struct Release {
        let version: String
        let pageURL: URL
        let notes: String?
    }

    struct CheckError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let repo = "Visero/mac-kit"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    private static func request(_ path: String, completion: @escaping (Data?, Int, Error?) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)\(path)") else {
            completion(nil, 0, CheckError(message: "地址无效"))
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MacKit/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, response, error in
            completion(data, (response as? HTTPURLResponse)?.statusCode ?? 0, error)
        }.resume()
    }

    /// 优先读最新 Release；没有 Release 时退回 tags。`nil` 表示仓库还没有任何版本。
    static func check(completion: @escaping (Result<Release?, Error>) -> Void) {
        request("/releases/latest") { data, code, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            if code == 200, let data = data, let release = parseRelease(data) {
                completion(.success(release))
                return
            }
            guard code == 404 else {
                completion(.failure(CheckError(message: "GitHub 返回 \(code)")))
                return
            }
            request("/tags") { data, code, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard code == 200, let data = data,
                      let tags = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                      let name = tags.first?["name"] as? String else {
                    completion(.success(nil))
                    return
                }
                let page = URL(string: "https://github.com/\(repo)/releases")!
                completion(.success(Release(version: name, pageURL: page, notes: nil)))
            }
        }
    }

    static func parseRelease(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/\(repo)/releases")!
        return Release(version: tag, pageURL: page, notes: json["body"] as? String)
    }

    private static func components(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .map { part in Int(part.prefix(while: { $0.isNumber })) ?? 0 }
    }

    /// 远端版本是否比本地新（逐段比较数字）
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let remoteParts = components(remote)
        let localParts = components(local)
        for index in 0..<max(remoteParts.count, localParts.count) {
            let remotePart = index < remoteParts.count ? remoteParts[index] : 0
            let localPart = index < localParts.count ? localParts[index] : 0
            if remotePart != localPart { return remotePart > localPart }
        }
        return false
    }
}

// MARK: - 开机自启（LaunchAgent）

enum LoginAgent {
    static let label = "com.kaix.mac-kit"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// 拉起自己时带上 --login，登录时不弹设置窗口
    static func install() throws {
        // 清掉旧版 SMAppService 的注册，避免两套自启同时生效
        if #available(macOS 13.0, *), SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        }
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, "--login"],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: plistURL)
        // 已经加载过就先卸载，下次登录生效；不立即 bootstrap，避免当场再起一个实例
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
    }

    static func remove() {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    private static func launchctl(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var bindingsByID: [UInt32: HotkeyBinding] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private var lastMessage = "就绪"
    private var appearanceObservation: NSKeyValueObservation?
    private var updateTimer: Timer?
    private var hider: MenuBarHider?
    private var settingsHotKeyRef: EventHotKeyRef?
    private var selfHotKeyRef: EventHotKeyRef?
    private var clipboardHotKeyRef: EventHotKeyRef?
    private var entryHotKeyRefs: [EventHotKeyRef] = []
    private var entryIDsByHotKey: [UInt32: String] = [:]
    private var clipboardPanel: ClipboardPanelController?
    private var settingsWindow: SettingsWindowController?
    private var shortcutBatchEditor: ShortcutBatchEditor?
    private let model = MacKitModel()
    private var config = Config(hotkeys: [])

    private let configURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("mac-kit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    /// 开机自启由 LaunchAgent 带 --login 拉起；手动打开（Finder / Dock / open）不会有这个参数
    private var launchedAtLogin: Bool { CommandLine.arguments.contains("--login") }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 已在运行时再点 Dock 图标 / 再次打开，把设置窗口带到前台
        openSettings()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("启动 MacKit \(Bundle.main.bundleIdentifier ?? "-")")
        applyIcon(for: NSApp.effectiveAppearance)
        observeAppearance()
        setupStatusItem()
        setupMenuBarHider()
        installCarbonHandler()
        registerSettingsHotKey()
        if Preferences.selfHotkeyEnabled { _ = registerSelfHotKey() }
        wireModel()
        registerClipboardHotKey()
        model.clipboard.start()
        refreshClipboardShortcuts()
        model.scrollReversal.start()
        applyPresentation()
        loadConfig()
        rebuildMenu()
        scheduleUpdateChecks()
        model.syncEngine.startIfEnabled()


        if CommandLine.arguments.contains("--clipboard") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.openClipboard() }
        }
        let forceSettings = CommandLine.arguments.contains("--settings")
        if forceSettings || (!launchedAtLogin && !CommandLine.arguments.contains("--clipboard")) {
            Log.write("手动打开，显示设置窗口")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.openSettings()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.syncEngine.flushOnTerminate()
        model.clipboard.stop()
        model.scrollReversal.stop()
        if let ref = clipboardHotKeyRef { UnregisterEventHotKey(ref) }
        unregisterEntryHotKeys()
        unregisterAll()
        if let ref = settingsHotKeyRef { UnregisterEventHotKey(ref) }
        unregisterSelfHotKey()
        hider?.reset()
    }

    // MARK: 图标

    private func applyIcon(for appearance: NSAppearance) {
        guard let image = AppIconAsset.forAppearance(appearance) else {
            Log.write("图标资源缺失")
            return
        }
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        Log.write("应用图标：\(isDark ? "dark" : "light")")
        // 新系统直接使用 actool 图标栈，保留系统外边距和外观选择。
        // 手动覆盖只用于不支持 Icon Composer 的旧版 macOS。
        if #available(macOS 26.0, *),
           Bundle.main.url(forResource: "Assets", withExtension: "car") != nil {
            NSApp.applicationIconImage = nil
        } else {
            NSApp.applicationIconImage = image
        }
        NSApp.dockTile.display()
        model.icon = image
    }

    private func observeAppearance() {
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, change in
            guard let appearance = change.newValue else { return }
            DispatchQueue.main.async {
                self?.applyIcon(for: appearance)
            }
        }

        DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyIcon(for: NSApp.effectiveAppearance)
        }
    }

    // MARK: 模型回调

    private func wireModel() {
        model.clipboard.onOpen = { [weak self] in self?.openClipboard() }
        model.clipboard.onShortcutsChanged = { [weak self] in self?.refreshClipboardShortcuts() }
        model.onReload = { [weak self] in
            self?.loadConfig()
            self?.rebuildMenu()
            self?.model.syncEngine.noteLocalChange()
        }
        model.onSidebarOrderChanged = { [weak self] in self?.model.syncEngine.noteLocalChange() }
        model.onQuitWhitelistChanged = { [weak self] in self?.model.syncEngine.noteLocalChange() }
        model.syncEngine.snapshotProvider = { [weak self] in
            guard let self else {
                return MacKitSyncSnapshot(hotkeys: [], sidebarOrder: [], quitWhitelist: [])
            }
            return MacKitSyncSnapshot(
                hotkeys: self.config.hotkeys,
                sidebarOrder: self.model.pageOrder.map(\.rawValue),
                quitWhitelist: self.model.quitWhitelist
            )
        }
        model.syncEngine.applyRemote = { [weak self] record in
            guard let self else { return "MacKit 未就绪" }
            return self.applySyncedSettings(record)
        }
        model.onToggleLogin = { [weak self] in self?.toggleLoginItem() }
        model.onOpenConfig = { [weak self] in self?.openConfig() }
        model.onOpenLog = { [weak self] in self?.openLog() }
        model.onBatchEditShortcuts = { [weak self] in self?.openBatchEditor() }
        model.onAddShortcut = { [weak self] key, modifiers, target in
            guard let self = self else { return "MacKit 未就绪" }
            return self.addShortcut(key: key, modifiers: modifiers, target: target)
        }
        model.onDeleteShortcut = { [weak self] index in self?.deleteShortcut(at: index) }
        model.onQuit = { NSApp.terminate(nil) }
        model.onCloseWindow = { [weak self] in self?.settingsWindow?.close() }
        model.onToggleMenuBarIcon = { [weak self] in self?.toggleMenuBarIcon() }
        model.onToggleDockIcon = { [weak self] in self?.toggleDockIcon() }
        model.onToggleSelfHotkey = { [weak self] in self?.toggleSelfHotkey() }
        model.onCheckUpdate = { [weak self] in self?.checkForUpdates(manual: true) }
        model.onToggleAutoUpdate = { [weak self] in self?.toggleAutoUpdate() }
        model.onOpenUpdate = { [weak self] in self?.openUpdatePage() }
        model.onToggleMenuBarCollapse = { [weak self] in self?.toggleMenuBarCollapse() }
        model.onToggleCollapseOnLaunch = { [weak self] in self?.toggleCollapseOnLaunch() }
        model.onToggleMenuBarToggleVisible = { [weak self] in self?.toggleMenuBarToggleItem() }
        model.onToggleMenuBarSeparatorVisible = { [weak self] in self?.toggleMenuBarSeparatorItem() }
        model.onToggleKeepApp = { [weak self] bundleID in self?.toggleHiddenApp(bundleID) }
    }

    // MARK: 菜单栏图标折叠

    private func setupMenuBarHider() {
        let hider = MenuBarHider()
        hider.onToggle = { [weak self] in
            guard let self = self, let hider = self.hider else { return }
            self.model.menuBarCollapsed = hider.isCollapsed
            Log.write(hider.isCollapsed ? "折叠菜单栏图标" : "展开菜单栏图标")
            self.rebuildMenu()
        }
        hider.hiddenBundleIDs = Preferences.hiddenBundleIDs
        hider.runningBundleIDs = {
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        }
        self.hider = hider
        if Preferences.collapseOnLaunch { hider.setCollapsed(true) }
        hider.toggle.isVisible = Preferences.menuBarToggleVisible
        hider.separator.isVisible = MenuBarHider.usesNativeEngine ? false : Preferences.menuBarSeparatorVisible
        model.menuBarCollapsed = hider.isCollapsed
        model.collapseOnLaunch = Preferences.collapseOnLaunch
        model.menuBarToggleVisible = Preferences.menuBarToggleVisible
        model.menuBarSeparatorVisible = Preferences.menuBarSeparatorVisible
    }

    private func toggleMenuBarCollapse() {
        hider?.toggleCollapsed()
        model.menuBarCollapsed = hider?.isCollapsed ?? false
        rebuildMenu()
    }

    private func toggleCollapseOnLaunch() {
        Preferences.collapseOnLaunch.toggle()
        model.collapseOnLaunch = Preferences.collapseOnLaunch
        lastMessage = Preferences.collapseOnLaunch ? "启动时自动折叠菜单栏" : "启动时不折叠菜单栏"
        Log.write(lastMessage)
        syncModel()
        rebuildMenu()
    }

    private func toggleMenuBarToggleItem() {
        Preferences.menuBarToggleVisible.toggle()
        model.menuBarToggleVisible = Preferences.menuBarToggleVisible
        hider?.toggle.isVisible = Preferences.menuBarToggleVisible
        lastMessage = Preferences.menuBarToggleVisible ? "已显示折叠箭头" : "已隐藏折叠箭头"
        Log.write(lastMessage)
        syncModel()
        rebuildMenu()
    }

    private func toggleMenuBarSeparatorItem() {
        Preferences.menuBarSeparatorVisible.toggle()
        model.menuBarSeparatorVisible = Preferences.menuBarSeparatorVisible
        hider?.separator.isVisible = Preferences.menuBarSeparatorVisible
        lastMessage = Preferences.menuBarSeparatorVisible ? "已显示分隔线" : "已隐藏分隔线"
        Log.write(lastMessage)
        syncModel()
        rebuildMenu()
    }

    private func toggleHiddenApp(_ bundleID: String) {
        var hidden = Preferences.hiddenBundleIDs
        if let index = hidden.firstIndex(of: bundleID) {
            hidden.remove(at: index)
        } else {
            hidden.append(bundleID)
        }
        Preferences.hiddenBundleIDs = hidden
        model.hiddenBundleIDs = hidden
        hider?.hiddenBundleIDs = hidden
        // 已经隐藏时改名单，先展开再重新折叠，让改动立即生效
        if model.menuBarCollapsed {
            hider?.setCollapsed(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.hider?.setCollapsed(true)
            }
        }
    }

    // MARK: 检查更新

    private func scheduleUpdateChecks() {
        model.autoUpdateCheck = Preferences.autoUpdateCheck
        model.updateStatus = "尚未检查"

        if Preferences.autoUpdateCheck {
            let last = Preferences.lastUpdateCheck ?? .distantPast
            if Date().timeIntervalSince(last) > 6 * 3600 {
                // 启动后稍等再查，不抢启动时的资源
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                    self?.checkForUpdates(manual: false)
                }
            }
        }

        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            guard Preferences.autoUpdateCheck else { return }
            self?.checkForUpdates(manual: false)
        }
    }

    func checkForUpdates(manual: Bool) {
        if manual { model.updateStatus = "正在检查…" }
        Log.write("检查更新（\(manual ? "手动" : "自动")）")
        UpdateChecker.check { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                Preferences.lastUpdateCheck = Date()
                switch result {
                case .success(let release):
                    if let release = release, UpdateChecker.isNewer(release.version, than: UpdateChecker.currentVersion) {
                        self.model.availableUpdate = release
                        self.model.updateStatus = "发现新版本 \(release.version)"
                        self.lastMessage = "有新版本 \(release.version)"
                        Log.write("发现新版本 \(release.version)")
                    } else {
                        self.model.availableUpdate = nil
                        self.model.updateStatus = release == nil ? "仓库还没有发布版本" : "已是最新"
                        Log.write("已是最新（远端 \(release?.version ?? "无")）")
                    }
                case .failure(let error):
                    self.model.updateStatus = "检查失败，稍后重试"
                    Log.write("检查更新失败：\(error.localizedDescription)")
                }
                self.rebuildMenu()
            }
        }
    }

    private func toggleAutoUpdate() {
        Preferences.autoUpdateCheck.toggle()
        model.autoUpdateCheck = Preferences.autoUpdateCheck
        lastMessage = Preferences.autoUpdateCheck ? "已开启自动检查更新" : "已关闭自动检查更新"
        Log.write(lastMessage)
        syncModel()
        rebuildMenu()
    }

    private func openUpdatePage() {
        guard let release = model.availableUpdate else { return }
        NSWorkspace.shared.open(release.pageURL)
    }

    // MARK: 菜单栏图标

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "command", accessibilityDescription: "MacKit")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "MacKit — 快捷键启动 App"
        }
    }

    // MARK: 菜单栏 / Dock 可见性

    private func applyPresentation() {
        statusItem.isVisible = Preferences.showMenuBarIcon
        NSApp.setActivationPolicy(Preferences.showDockIcon ? .regular : .accessory)
        model.showMenuBarIcon = Preferences.showMenuBarIcon
        model.showDockIcon = Preferences.showDockIcon
        if Preferences.showDockIcon {
            // 切到 regular 后 Dock 会重新读取 bundle 图标，这里再压一次运行时图标
            applyIcon(for: NSApp.effectiveAppearance)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.applyIcon(for: NSApp.effectiveAppearance)
            }
        }
    }

    private func toggleMenuBarIcon() {
        Preferences.showMenuBarIcon.toggle()
        applyPresentation()
        lastMessage = Preferences.showMenuBarIcon ? "已显示菜单栏图标" : "已隐藏菜单栏图标"
        Log.write(lastMessage)
        syncModel()
    }

    private func toggleDockIcon() {
        Preferences.showDockIcon.toggle()
        applyPresentation()
        lastMessage = Preferences.showDockIcon ? "已显示 Dock 图标" : "已隐藏 Dock 图标"
        Log.write(lastMessage)
        syncModel()
    }

    // MARK: Carbon 事件

    private func installCarbonHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyCallback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        if status != noErr {
            Log.write("安装事件处理器失败: \(status)")
        }
    }

    private func registerSettingsHotKey() {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: settingsHotKeyID)
        let status = RegisterEventHotKey(
            UInt32(KeyCodes.map[","]!),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref = ref {
            settingsHotKeyRef = ref
            Log.write("注册设置热键 ⌥⌘,")
        } else {
            Log.write("注册设置热键失败 status=\(status)（可能被占用）")
        }
    }

    private func registerClipboardHotKey() {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: hotKeySignature, id: clipboardHotKeyID)
        let result = RegisterEventHotKey(49, UInt32(optionKey), id, GetApplicationEventTarget(), 0, &ref)
        if result == noErr, let ref {
            clipboardHotKeyRef = ref
            model.clipboard.hotkeyStatus = "⌥Space"
        } else {
            model.clipboard.hotkeyStatus = "⌥Space 被占用"
        }
    }

    private func openClipboard() {
        if clipboardPanel == nil { clipboardPanel = ClipboardPanelController(history: model.clipboard) }
        clipboardPanel?.show()
    }

    private func unregisterAll() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        bindingsByID.removeAll()
        nextID = 1
    }

    // MARK: 配置

    private func loadConfig() {
        unregisterAll()

        if !FileManager.default.fileExists(atPath: configURL.path) {
            writeDefaultConfig()
        }

        guard let data = try? Data(contentsOf: configURL) else {
            lastMessage = "读取配置失败"
            Log.write("读取配置失败: \(configURL.path)")
            syncModel()
            return
        }

        do {
            let loaded = try JSONDecoder().decode(Config.self, from: data)
            config = loaded
            var registered = 0
            var rows: [MacKitModel.Row] = []
            for (index, binding) in loaded.hotkeys.enumerated() {
                let ok = register(binding)
                if ok { registered += 1 }
                let resolved = AppResolver.resolve(binding.target)?.path ?? "未找到"
                rows.append(.init(
                    index: index,
                    keys: KeyCodes.label(binding),
                    target: binding.target,
                    name: AppResolver.displayName(binding.target),
                    resolved: resolved,
                    ok: ok
                ))
                Log.write("\(ok ? "注册" : "注册失败") \(KeyCodes.label(binding)) → \(binding.target)")
            }
            lastMessage = "已注册 \(registered)/\(loaded.hotkeys.count) 个快捷键"
            Log.write(lastMessage)
            model.rows = rows
        } catch {
            lastMessage = "配置格式错误: \(error.localizedDescription)"
            Log.write(lastMessage)
        }
        syncModel()
    }

    private func syncModel() {
        model.status = lastMessage
        model.loginItemEnabled = isLoginItemEnabled()
        model.selfHotkeyEnabled = Preferences.selfHotkeyEnabled
    }

    private func defaultConfig() -> Config {
        ShortcutConfiguration.defaults
    }

    private func writeDefaultConfig() {
        let config = defaultConfig()
        self.config = config
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            try? data.write(to: configURL)
            Log.write("已生成默认配置: \(configURL.path)")
        }
    }

    private func openBatchEditor() {
        if let editor = shortcutBatchEditor, editor.window?.isVisible == true {
            editor.window?.makeKeyAndOrderFront(nil)
            return
        }
        let editor = ShortcutBatchEditor(config: config) { [weak self] text in
            guard let self else { return "MacKit 未就绪" }
            return self.applyBatchConfiguration(text)
        }
        shortcutBatchEditor = editor
        editor.present()
    }

    private func applyBatchConfiguration(_ text: String) -> String? {
        let candidate: Config
        do { candidate = try ShortcutConfiguration.parse(text) }
        catch { return error.localizedDescription }
        let currentKeys = Set(config.hotkeys.map(ShortcutConfiguration.identity))
        for binding in candidate.hotkeys where !currentKeys.contains(ShortcutConfiguration.identity(binding)) {
            if !isShortcutAvailable(binding) { return "\(KeyCodes.label(binding)) 已被系统或其他 App 占用，未修改配置" }
        }
        let old = config
        unregisterAll()
        for binding in candidate.hotkeys {
            guard register(binding) else {
                unregisterAll()
                for existing in old.hotkeys { _ = register(existing) }
                return "\(KeyCodes.label(binding)) 注册失败，已恢复原配置"
            }
        }
        do {
            let data = Data(ShortcutConfiguration.json(candidate).utf8)
            // 每次只留一份上次配置，用于撤销批量编辑。
            if let oldData = try? Data(contentsOf: configURL) {
                try oldData.write(to: configURL.appendingPathExtension("previous"), options: .atomic)
            }
            try data.write(to: configURL, options: .atomic)
        } catch {
            unregisterAll()
            for existing in old.hotkeys { _ = register(existing) }
            return "保存失败，原配置未改变：\(error.localizedDescription)"
        }
        config = candidate
        loadConfig()
        model.syncEngine.noteLocalChange()
        lastMessage = "已应用 \(candidate.hotkeys.count) 条快捷键"
        syncModel()
        rebuildMenu()
        return nil
    }

    /// 写入 config.json 并重新注册；返回值是给界面显示的错误
    private func saveConfig(_ newConfig: Config, notifySync: Bool = true) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(newConfig)
            try data.write(to: configURL, options: .atomic)
        } catch {
            let message = "保存配置失败: \(error.localizedDescription)"
            Log.write(message)
            return message
        }
        config = newConfig
        loadConfig()
        if notifySync { model.syncEngine.noteLocalChange() }
        return nil
    }

    /// 把同步文件夹里的设置应用到本机；不会反向标记成本机新改动。
    private func applySyncedSettings(_ record: MacKitSyncRecord) -> String? {
        let order = normalizedSidebarOrder(record.sidebarOrder)
        if let error = saveConfig(Config(hotkeys: record.hotkeys), notifySync: false) {
            return error
        }
        model.applySyncedPreferences(sidebarOrder: order, quitWhitelist: record.quitWhitelist)
        rebuildMenu()
        Log.write("iCloud 同步：已应用远端设置（快捷键 \(record.hotkeys.count) 条）")
        return nil
    }

    private func normalizedSidebarOrder(_ raw: [String]) -> [SettingsPage] {
        let items = raw.compactMap { SettingsPage(rawValue: $0) }
        let missing = SettingsPage.allCases.filter { !items.contains($0) }
        let order = items + missing
        return order.count == SettingsPage.allCases.count ? order : SettingsPage.allCases
    }

    private func validateShortcut(key: String, modifiers: [String], target: String, excluding index: Int? = nil) -> String? {
        let normalizedKey = key.lowercased()
        guard KeyCodes.map[normalizedKey] != nil else { return "不支持这个按键" }
        guard AppResolver.resolve(target) != nil else { return "找不到这个应用，请重新选择" }

        let modifierSet = Set(KeyCodes.canonicalModifiers(modifiers))
        guard !modifierSet.isDisjoint(with: ["command", "option", "control"]) else {
            return "快捷键至少需要 ⌘、⌥ 或 ⌃ 中的一个"
        }

        let settingsCombo = Set(["command", "option"])
        if modifierSet == Set(["option"]), KeyCodes.map[normalizedKey] == 49 {
            return "⌥Space 用于打开剪贴板历史"
        }
        if modifierSet == settingsCombo && normalizedKey == "," {
            return "⌥⌘, 是打开设置窗口的固定热键"
        }
        if modifierSet == settingsCombo && normalizedKey == "k" {
            return "⌘⌥K 是打开设置窗口的固定热键"
        }

        for (offset, binding) in config.hotkeys.enumerated() where offset != index {
            let sameKey = binding.key.lowercased() == normalizedKey
            let sameModifiers = Set(KeyCodes.canonicalModifiers(binding.modifiers)) == modifierSet
            if sameKey && sameModifiers {
                return "这个组合已经绑定到 \(AppResolver.displayName(binding.target))"
            }
        }
        return nil
    }

    private func isShortcutAvailable(_ binding: HotkeyBinding) -> Bool {
        guard let code = KeyCodes.map[binding.key.lowercased()] else { return false }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: nextID)
        let status = RegisterEventHotKey(
            UInt32(code),
            KeyCodes.carbonModifiers(binding.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref = ref else { return false }
        UnregisterEventHotKey(ref)
        return true
    }

    private func addShortcut(key: String, modifiers: [String], target: String) -> String? {
        if let error = validateShortcut(key: key, modifiers: modifiers, target: target) {
            return error
        }

        let binding = HotkeyBinding(key: key.lowercased(), modifiers: modifiers, target: target)
        guard isShortcutAvailable(binding) else {
            return "这个组合已被系统或其他 App 占用"
        }

        var newConfig = config
        newConfig.hotkeys.append(binding)
        if let error = saveConfig(newConfig) {
            return error
        }

        lastMessage = "已添加 \(KeyCodes.label(binding)) → \(AppResolver.displayName(target))"
        Log.write(lastMessage)
        syncModel()
        rebuildMenu()
        return nil
    }

    private func deleteShortcut(at index: Int) {
        guard config.hotkeys.indices.contains(index) else { return }
        let removed = config.hotkeys[index]
        var newConfig = config
        newConfig.hotkeys.remove(at: index)
        if let error = saveConfig(newConfig) {
            lastMessage = error
            Log.write(error)
            syncModel()
            rebuildMenu()
            return
        }

        lastMessage = "已移除 \(KeyCodes.label(removed)) → \(AppResolver.displayName(removed.target))"
        Log.write(lastMessage)
        syncModel()
        rebuildMenu()
    }

    private func register(_ binding: HotkeyBinding) -> Bool {
        guard let code = KeyCodes.map[binding.key.lowercased()] else { return false }
        let modifiers = KeyCodes.carbonModifiers(binding.modifiers)
        let id = nextID
        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(code), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref = ref else { return false }
        hotKeyRefs.append(ref)
        bindingsByID[id] = binding
        nextID += 1
        return true
    }

    @discardableResult
    private func registerSelfHotKey() -> Bool {
        unregisterSelfHotKey()
        hider?.reset()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: selfHotKeyID)
        let status = RegisterEventHotKey(
            UInt32(KeyCodes.map["k"]!),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref = ref else {
            Log.write("注册 ⌘⌥K 失败 status=\(status)（可能被占用）")
            return false
        }
        selfHotKeyRef = ref
        Log.write("注册 ⌘⌥K 打开设置窗口")
        return true
    }

    private func unregisterSelfHotKey() {
        if let ref = selfHotKeyRef {
            UnregisterEventHotKey(ref)
            selfHotKeyRef = nil
        }
    }

    private func toggleSelfHotkey() {
        if Preferences.selfHotkeyEnabled {
            unregisterSelfHotKey()
        hider?.reset()
            Preferences.selfHotkeyEnabled = false
            lastMessage = "已关闭 ⌘⌥K"
        } else {
            Preferences.selfHotkeyEnabled = true
            if registerSelfHotKey() {
                lastMessage = "已开启 ⌘⌥K"
            } else {
                Preferences.selfHotkeyEnabled = false
                lastMessage = "⌘⌥K 注册失败，可能被其他 App 占用"
            }
        }
        Log.write(lastMessage)
        syncModel()
        rebuildMenu()
    }

    // MARK: 触发

    func fire(id: UInt32) {
        if let entryID = entryIDsByHotKey[id] { activateClipboardEntry(entryID); return }
        if id == clipboardHotKeyID { openClipboard(); return }
        if id == settingsHotKeyID || id == selfHotKeyID {
            openSettings()
            return
        }
        guard let binding = bindingsByID[id] else { return }
        launch(binding.target)
    }

    /// 为带自定义快捷键的剪贴板条目注册全局热键。
    func refreshClipboardShortcuts() {
        unregisterEntryHotKeys()
        var offset: UInt32 = 0
        for entry in model.clipboard.entries {
            guard let key = entry.shortcutKey?.lowercased(),
                  let modifiers = entry.shortcutModifiers, !modifiers.isEmpty,
                  let code = KeyCodes.map[key] else { continue }
            let id = clipboardEntryHotKeyBase + offset
            offset += 1
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: id)
            let status = RegisterEventHotKey(UInt32(code), KeyCodes.carbonModifiers(modifiers), hotKeyID,
                                             GetApplicationEventTarget(), 0, &ref)
            guard status == noErr, let ref else {
                Log.write("剪贴板快捷键被占用：\(entry.shortcutLabel ?? key)")
                continue
            }
            entryHotKeyRefs.append(ref)
            entryIDsByHotKey[id] = entry.id
        }
        if !entryIDsByHotKey.isEmpty { Log.write("已注册 \(entryIDsByHotKey.count) 个剪贴板快捷键") }
    }

    private func unregisterEntryHotKeys() {
        for ref in entryHotKeyRefs { UnregisterEventHotKey(ref) }
        entryHotKeyRefs.removeAll()
        entryIDsByHotKey.removeAll()
    }

    private func activateClipboardEntry(_ id: String) {
        guard let entry = model.clipboard.entry(id: id), model.clipboard.copy(entry) else { return }
        guard model.clipboard.autoPaste, AXIsProcessTrusted(),
              let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front.processIdentifier else { return }
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.postToPid(front.processIdentifier)
            up?.postToPid(front.processIdentifier)
        }
    }

    private func launch(_ target: String) {
        guard let url = AppResolver.resolve(target) else {
            lastMessage = "找不到应用: \(target)"
            Log.write(lastMessage)
            syncModel()
            rebuildMenu()
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = target == ShortcutConfiguration.screenSaver
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.lastMessage = "打开 \(target) 失败: \(error.localizedDescription)"
                } else {
                    self?.lastMessage = "已打开 \(target)"
                }
                Log.write(self?.lastMessage ?? "")
                self?.syncModel()
                self?.rebuildMenu()
            }
        }
    }

    // MARK: 菜单

    private func rebuildMenu() {
        let menu = Self.makeStatusMenu(target: self)
        statusItem.menu = menu
    }

    /// 状态栏只提供主界面入口和退出；设置统一留在主界面。
    static func makeStatusMenu(target: AnyObject?) -> NSMenu {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "偏好设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command, .option]
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.target = target
        menu.addItem(settings)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 MacKit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = target
        menu.addItem(quitItem)
        return menu
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let controller = SettingsWindowController(model: model)
            settingsWindow = controller
        }
        syncModel()
        model.refreshRunningApps()
        settingsWindow?.present()
    }

    @objc private func reloadConfig() {
        loadConfig()
        rebuildMenu()
        model.syncEngine.noteLocalChange()
    }

    @objc private func openConfig() {
        if !FileManager.default.fileExists(atPath: configURL.path) {
            writeDefaultConfig()
        }
        NSWorkspace.shared.open(configURL)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: 开机自启

    private func isLoginItemEnabled() -> Bool { LoginAgent.isEnabled }

    private func toggleLoginItem() {
        if LoginAgent.isEnabled {
            LoginAgent.remove()
            lastMessage = "已取消开机自启"
        } else {
            do {
                try LoginAgent.install()
                lastMessage = "已开启开机自启"
            } catch {
                lastMessage = "设置开机自启失败: \(error.localizedDescription)"
            }
        }
        Log.write(lastMessage)
        syncModel()
        rebuildMenu()
    }

}

// MARK: - 自检模式

func runStatusMenuCheck() -> Never {
    _ = NSApplication.shared
    let menu = AppDelegate.makeStatusMenu(target: nil)
    let actions = menu.items.filter { !$0.isSeparatorItem }
    guard actions.map(\.title) == ["偏好设置…", "退出 MacKit"],
          actions.allSatisfy({ $0.action != nil }),
          actions.first?.keyEquivalentModifierMask == [.command, .option] else {
        print("✗ 状态栏菜单不符合精简配置")
        exit(1)
    }
    print("✓ 状态栏菜单仅保留偏好设置和退出")
    print("✓ 设置快捷键 ⌥⌘,，配置、日志、更新及开机自启统一在主界面")
    exit(0)
}

func runCheck() -> Never {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let url = support.appendingPathComponent("mac-kit", isDirectory: true).appendingPathComponent("config.json")
    if !FileManager.default.fileExists(atPath: url.path) {
        print("配置文件不存在: \(url.path)")
        exit(1)
    }
    guard let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(Config.self, from: data) else {
        print("配置文件解析失败")
        exit(1)
    }
    _ = NSApplication.shared
    var ok = 0
    for binding in config.hotkeys {
        guard let code = KeyCodes.map[binding.key.lowercased()] else {
            print("✗ \(binding.key) 不是支持的键名")
            continue
        }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: hotKeySignature, id: UInt32(ok + 1))
        let status = RegisterEventHotKey(UInt32(code), KeyCodes.carbonModifiers(binding.modifiers), id, GetApplicationEventTarget(), 0, &ref)
        let resolved = AppResolver.resolve(binding.target)?.path ?? "未找到"
        if status == noErr, let ref = ref {
            UnregisterEventHotKey(ref)
            ok += 1
            print("✓ \(KeyCodes.label(binding)) → \(binding.target)  (\(resolved))")
        } else {
            print("✗ \(KeyCodes.label(binding)) → \(binding.target)  注册失败 status=\(status)")
        }
    }
    let appearance = NSApp.effectiveAppearance
    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let icon = AppIconAsset.forAppearance(appearance)
    print("当前外观: \(isDark ? "dark" : "light")，图标: \(icon == nil ? "缺失" : "已加载")（Assets.car / MacKit.icns）")
    print("\(ok)/\(config.hotkeys.count) 个快捷键可用")
    exit(ok == config.hotkeys.count ? 0 : 2)
}

// MARK: - 界面快照（--snapshot 输出 PNG，便于离线检查排版）

@MainActor
func renderSnapshot(to path: String, page: SettingsPage = .launcher) -> Never {
    _ = NSApplication.shared
    let demo = CommandLine.arguments.contains("--demo")
    if demo { NSApp.appearance = NSAppearance(named: .darkAqua) }
    let demoDefaults = UserDefaults(suiteName: "MacKit-Demo-Settings-\(UUID().uuidString)")!
    let model = MacKitModel(clipboard: demo ? makeDemoClipboardHistory() : ClipboardHistory(),
                            syncEngine: MacKitCloudSyncEngine(defaults: demo ? demoDefaults : .standard))
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("mac-kit", isDirectory: true)
        .appendingPathComponent("config.json")

    let snapshotConfig: Config? = demo ? ShortcutConfiguration.defaults : (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
    if let config = snapshotConfig {
        model.rows = config.hotkeys.enumerated().map { index, binding in
            let resolved = AppResolver.resolve(binding.target)
            return MacKitModel.Row(
                index: index,
                keys: KeyCodes.label(binding),
                target: binding.target,
                name: AppResolver.displayName(binding.target),
                resolved: resolved?.path ?? "未找到",
                ok: resolved != nil
            )
        }
        model.status = "已注册 \(config.hotkeys.count)/\(config.hotkeys.count) 个快捷键"
    }
    model.icon = AppIconAsset.forAppearance(NSApp.effectiveAppearance)
    model.updateStatus = "已是最新"
    if page == .menuBar {
        model.runningApps = [
            MacKitModel.AppEntry(id: "com.apple.Safari", name: "Safari"),
            MacKitModel.AppEntry(id: "com.tencent.xinWeChat", name: "微信"),
            MacKitModel.AppEntry(id: "com.github.wez.wezterm", name: "WezTerm"),
            MacKitModel.AppEntry(id: "app.yuxino.mimi", name: "mimi")
        ]
        model.hiddenBundleIDs = ["com.tencent.xinWeChat", "app.yuxino.mimi"]
    }
    if page == .tools {
        if CommandLine.arguments.contains("--fda") {
            model.toolsStatus = "Safari 浏览记录：没有访问权限\n最近使用文件记录：没有访问权限"
            model.toolsNeedsFullDiskAccess = true
        } else {
            model.toolsStatus = "Safari 浏览记录：已清空「今天」的 37 条\n最近使用文件记录：已清空 12 项（重启 Finder 后列表刷新）"
        }
    }

    if page == .clipboard && !demo { model.clipboard.start() }
    model.page = page
    let view = SettingsView(model: model)
        .background(
            LinearGradient(
                colors: [Color(red: 0.36, green: 0.40, blue: 0.50), Color(red: 0.09, green: 0.10, blue: 0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

    if page == .clipboard {
        // ImageRenderer 不支持 TextField 等 AppKit 控件，改为真实 HostingView 离屏渲染。
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 620)
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                print("saved \(path)")
                exit(0)
            }
        }
        print("render failed")
        exit(1)
    }
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, demo ? .dark : (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)))
    renderer.scale = 2
    if let image = renderer.nsImage,
       let tiff = image.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
        print("saved \(path)")
    } else {
        print("render failed")
    }
    exit(0)
}

// MARK: - 登录项自检（--login-on / --login-off / --login-status）

func runLoginToggle(_ action: String) -> Never {
    switch action {
    case "--login-on":
        do {
            try LoginAgent.install()
            print("已写入 \(LoginAgent.plistURL.path)")
        } catch {
            print("失败: \(error.localizedDescription)")
        }
    case "--login-off":
        LoginAgent.remove()
        print("已移除 \(LoginAgent.plistURL.path)")
    default:
        break
    }
    print("自启状态: \(LoginAgent.isEnabled ? "开启" : "关闭")")
    exit(0)
}

// MARK: - 菜单栏隐藏自检（--visibility-test，隐藏 12 秒后自动恢复）

func runVisibilityTest() -> Never {
    print("原生引擎可用: \(NativeVisibility.isAvailable)")
    guard NativeVisibility.isAvailable else {
        print("当前系统不支持：需要 macOS 27 及以上")
        exit(1)
    }
    let hidden = Preferences.hiddenBundleIDs
    let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
    var keep = running.filter { !hidden.contains($0) }
    if let own = Bundle.main.bundleIdentifier, !keep.contains(own) { keep.append(own) }
    print("要隐藏: \(hidden.joined(separator: ", "))")
    print("保留 \(keep.count) 个 App")
    var done = false
    NativeVisibility.activate(keep: keep) { result in
        switch result {
        case .success(let assertion):
            print("已激活可见性限制，12 秒后恢复（其它第三方图标应消失）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                assertion.invalidate()
                print("已恢复")
                done = true
            }
        case .failure(let error):
            print("激活失败：\(error.localizedDescription)")
            done = true
        }
    }
    while !done {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    exit(0)
}

// MARK: - 版本与更新自检（--version / --update-check）

func runVersionCheck() -> Never {
    print("MacKit \(UpdateChecker.currentVersion)")
    exit(0)
}

func runUpdateCheck() -> Never {
    print("当前版本 \(UpdateChecker.currentVersion)")
    print("版本比较自检: v1.2.0>1.0 → \(UpdateChecker.isNewer("v1.2.0", than: "1.0"))"
          + "，1.0>v1.2.0 → \(UpdateChecker.isNewer("1.0", than: "v1.2.0"))"
          + "，v1.0.1>v1.0 → \(UpdateChecker.isNewer("v1.0.1", than: "v1.0"))")
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0
    UpdateChecker.check { result in
        switch result {
        case .success(let release):
            if let release = release {
                let newer = UpdateChecker.isNewer(release.version, than: UpdateChecker.currentVersion)
                print("远端最新: \(release.version) → \(newer ? "有更新" : "已是最新")")
                print("页面: \(release.pageURL.absoluteString)")
            } else {
                print("远端还没有发布版本（Release / Tag 都为空）")
            }
        case .failure(let error):
            print("检查失败：\(error.localizedDescription)")
            exitCode = 1
        }
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 25)
    exit(exitCode)
}

/// 用一段真实格式的 GitHub Release JSON 验证解析链路（--update-fixture）
func runUpdateFixtureTest() -> Never {
    let json = """
    {"tag_name":"v1.4.2","html_url":"https://github.com/Visero/mac-kit/releases/tag/v1.4.2","body":"- 修复若干问题"}
    """
    guard let release = UpdateChecker.parseRelease(Data(json.utf8)) else {
        print("解析失败")
        exit(1)
    }
    let newer = UpdateChecker.isNewer(release.version, than: UpdateChecker.currentVersion)
    print("解析到 \(release.version)，比当前 \(UpdateChecker.currentVersion) 新: \(newer)")
    print("页面: \(release.pageURL.absoluteString)")
    print("更新说明: \(release.notes ?? "无")")
    exit(newer ? 0 : 1)
}

// MARK: - 时间范围自检（--range-test，用临时库验证，不动真实历史）

func runRangeTest() -> Never {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("mac-kit-range-base.db")
    try? fm.removeItem(at: base)

    _ = RecordCleaner.sqlite("""
    CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT);
    CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL);
    """, db: base)

    let startOfToday = Calendar.current.startOfDay(for: Date())
    let samples: [(String, TimeInterval)] = [
        ("今天 +1h", 3600),
        ("昨天 -5h", -5 * 3600),
        ("3 天前", -3 * 86400),
        ("10 天前", -10 * 86400),
        ("20 天前", -20 * 86400),
        ("40 天前", -40 * 86400)
    ]
    let visits = samples.enumerated().map { index, sample in
        let time = startOfToday.addingTimeInterval(sample.1).timeIntervalSinceReferenceDate
        return "(\(index + 1), \(index + 1), \(time))"
    }
    let items = samples.enumerated().map { "(\($0.offset + 1), 'https://example.com/\($0.offset)')" }
    _ = RecordCleaner.sqlite("""
    INSERT INTO history_visits (id, history_item, visit_time) VALUES \(visits.joined(separator: ","));
    INSERT INTO history_items (id, url) VALUES \(items.joined(separator: ","));
    """, db: base)

    print("样本: " + samples.map { $0.0 }.joined(separator: "、"))
    for range in HistoryRange.allCases where range != .all {
        let work = fm.temporaryDirectory.appendingPathComponent("mac-kit-range-test.db")
        try? fm.removeItem(at: work)
        try? fm.copyItem(at: base, to: work)
        guard let cutoff = range.cutoff else { continue }
        let (deleted, error) = RecordCleaner.deleteHistory(db: work, cutoff: cutoff)
        let (left, _) = RecordCleaner.sqlite("SELECT COUNT(*) FROM history_visits;", db: work)
        print("\(range.title): 删除 \(deleted) 条，剩余 \(left ?? "?") 条\(error == nil ? "" : "，错误: \(error!)")")
        try? fm.removeItem(at: work)
    }
    let (all, _) = RecordCleaner.sqlite("SELECT COUNT(*) FROM history_visits;", db: base)
    print("全部: 共 \(all ?? "?") 条")
    try? fm.removeItem(at: base)
    exit(0)
}

// MARK: - 清理目标自检（--tools-check，只读）

func runToolsCheck() -> Never {
    for line in RecordCleaner.describeTargets() {
        print(line)
    }
    exit(0)
}

// MARK: - 入口

let app = NSApplication.shared
if CommandLine.arguments.contains("--print-default-shortcuts") {
    print(ShortcutConfiguration.json(ShortcutConfiguration.defaults))
    exit(0)
}
if CommandLine.arguments.contains("--shortcut-config-check") { runShortcutConfigurationCheck() }
if CommandLine.arguments.contains("--scroll-status") { runScrollStatus() }
if CommandLine.arguments.contains("--scroll-check") { runScrollCheck() }
if CommandLine.arguments.contains("--clipboard-check") { runClipboardCheck() }
if CommandLine.arguments.contains("--clipboard-snapshot") { runClipboardSnapshot() }
if CommandLine.arguments.contains("--menu-check") { runStatusMenuCheck() }
if CommandLine.arguments.contains("--check") {
    runCheck()
}

if CommandLine.arguments.contains("--tools-check") {
    runToolsCheck()
}

if CommandLine.arguments.contains("--range-test") {
    runRangeTest()
}

if CommandLine.arguments.contains("--visibility-test") { runVisibilityTest() }
if CommandLine.arguments.contains("--version") { runVersionCheck() }
if CommandLine.arguments.contains("--update-check") { runUpdateCheck() }
if CommandLine.arguments.contains("--update-fixture") { runUpdateFixtureTest() }

for flag in ["--login-on", "--login-off", "--login-status"] where CommandLine.arguments.contains(flag) {
    runLoginToggle(flag)
}

if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
    let path = CommandLine.arguments[index + 1]
    var page = SettingsPage.launcher
    if let p = CommandLine.arguments.firstIndex(of: "--page"),
       CommandLine.arguments.count > p + 1,
       let parsed = SettingsPage(rawValue: CommandLine.arguments[p + 1]) {
        page = parsed
    }
    Task { @MainActor in
        renderSnapshot(to: path, page: page)
    }
    RunLoop.main.run()
}

if let index = CommandLine.arguments.firstIndex(of: "--open"), CommandLine.arguments.count > index + 1 {
    let target = CommandLine.arguments[index + 1]
    guard let url = AppResolver.resolve(target) else {
        print("✗ 找不到应用: \(target)")
        exit(1)
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
        if let error = error {
            print("✗ 打开失败: \(error.localizedDescription)")
            exit(1)
        }
        print("✓ 已打开 \(target)  (\(url.path))")
        exit(0)
    }
    RunLoop.main.run()
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
