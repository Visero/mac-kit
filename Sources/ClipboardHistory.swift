import AppKit
import SwiftUI
import Combine
import CryptoKit

// MARK: - 剪贴板模型（内容不进入日志）

enum ClipboardStorage: String, CaseIterable, Identifiable {
    case memory, local, iCloud
    var id: String { rawValue }
    var title: String {
        switch self {
        case .memory: return "不保存"
        case .local: return "本机保存"
        case .iCloud: return "iCloud 同步"
        }
    }
}

struct ClipboardEntry: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case text, image }
    let id: String
    let kind: Kind
    let text: String?
    let png: Data?
    var copiedAt: Double
    var editedAt: Double
    var pinned: Bool
    var source: String
    var shortcutKey: String?
    var shortcutModifiers: [String]?

    var shortcutLabel: String? {
        guard let shortcutKey, let shortcutModifiers, !shortcutModifiers.isEmpty else { return nil }
        return KeyCodes.display(shortcutModifiers) + KeyCodes.keyLabel(shortcutKey)
    }

    var title: String {
        if kind == .image { return "图片" }
        let compact = (text ?? "").components(separatedBy: .newlines).joined(separator: " ")
        return String(compact.prefix(180))
    }
    var byteCount: Int { png?.count ?? text?.utf8.count ?? 0 }
    var image: NSImage? { png.flatMap { NSImage(data: $0) } }

    static func make(text: String? = nil, png: Data? = nil, source: String = "", now: Double = Date().timeIntervalSince1970) -> ClipboardEntry? {
        let kind: Kind = png == nil ? .text : .image
        let data = png ?? Data((text ?? "").utf8)
        guard !data.isEmpty, data.count <= (kind == .image ? 5_000_000 : 200_000) else { return nil }
        if kind == .text, (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let digest = SHA256.hash(data: Data(kind.rawValue.utf8) + data).map { String(format: "%02x", $0) }.joined()
        return ClipboardEntry(id: digest, kind: kind, text: kind == .text ? text : nil,
                              png: png, copiedAt: now, editedAt: now, pinned: false, source: source)
    }
}

struct ClipboardArchive: Codable, Equatable {
    var schema = 1
    var entries: [ClipboardEntry] = []
    var deleted: [String: Double] = [:]
    var clearedAt: Double = 0

    func validated() throws -> ClipboardArchive {
        guard schema == 1, entries.count <= 500, deleted.count <= 10000,
              clearedAt.isFinite, clearedAt >= 0 else { throw ClipboardError.invalidArchive }
        for entry in entries {
            guard entry.copiedAt.isFinite, entry.editedAt.isFinite,
                  entry.copiedAt >= 0, entry.editedAt >= entry.copiedAt,
                  let canonical = ClipboardEntry.make(text: entry.text, png: entry.png, source: entry.source, now: entry.copiedAt),
                  canonical.id == entry.id, canonical.kind == entry.kind,
                  entry.kind != .image || (entry.png.flatMap { NSBitmapImageRep(data: $0) } != nil)
            else { throw ClipboardError.invalidArchive }
        }
        guard deleted.values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              entries.reduce(0, { $0 + $1.byteCount }) <= 32_000_000 else { throw ClipboardError.invalidArchive }
        return self
    }

    static func merge(_ lhs: ClipboardArchive, _ rhs: ClipboardArchive) -> ClipboardArchive {
        var out = lhs
        out.clearedAt = max(lhs.clearedAt, rhs.clearedAt)
        for (id, timestamp) in rhs.deleted { out.deleted[id] = max(timestamp, out.deleted[id] ?? 0) }
        var all: [String: ClipboardEntry] = [:]
        for entry in lhs.entries + rhs.entries {
            // 清空删除所有历史，包括置顶；重新复制（新 copiedAt）可再进入历史。
            guard entry.copiedAt > out.clearedAt,
                  entry.editedAt > (out.deleted[entry.id] ?? 0) else { continue }
            if let old = all[entry.id], old.editedAt >= entry.editedAt { continue }
            all[entry.id] = entry
        }
        out.entries = bounded(Array(all.values))
        return out
    }

    static func bounded(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        let sorted = entries.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.copiedAt != $1.copiedAt { return $0.copiedAt > $1.copiedAt }
            return $0.id < $1.id
        }
        var bytes = 0
        return Array(sorted.filter { item in
            guard bytes + item.byteCount <= 24_000_000 else { return false }
            bytes += item.byteCount
            return true
        }.prefix(200))
    }
}

enum ClipboardError: LocalizedError {
    case invalidArchive, unavailableFolder, unsafePath
    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "历史文件无法读取或格式不支持，已保留原文件。"
        case .unavailableFolder: return "请先选择一个可写的 iCloud Drive 文件夹。"
        case .unsafePath: return "历史路径不可用，或指向符号链接，未写入。"
        }
    }
}

// MARK: - 采集、存储与同步

final class ClipboardHistory: ObservableObject {
    @Published private(set) var archive = ClipboardArchive()
    @Published var query = ""
    @Published var selectedID: String?
    @Published private(set) var storage: ClipboardStorage
    @Published private(set) var paused: Bool
    @Published private(set) var autoPaste: Bool
    /// 浮层里最多显示的非置顶条数（置顶始终全部显示）。
    @Published private(set) var maxVisible: Int
    @Published private(set) var cloudFolder: String
    @Published var status = ""
    @Published var hotkeyStatus = "⌥Space"
    @Published var showClearConfirmation = false
    var onOpen: () -> Void = {}
    var onShortcutsChanged: () -> Void = {}

    private let defaults: UserDefaults
    private let board: NSPasteboard
    private let localURL: URL
    private let deviceID: String
    private var lastChange: Int
    private var timer: Timer?
    private var lastSync = Date.distantPast
    private var loadFailed = false
    private var started = false
    private let modeKey = "MacKit.clipboard.storage"
    static let privateTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
        "com.agilebits.onepassword.password", "org.nspasteboard.PasswordType"
    ]

    init(defaults: UserDefaults = .standard, board: NSPasteboard = .general, localURL: URL? = nil) {
        self.defaults = defaults
        self.board = board
        self.localURL = localURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mac-kit/clipboard/history.json")
        storage = ClipboardStorage(rawValue: defaults.string(forKey: "MacKit.clipboard.storage") ?? "") ?? .memory
        paused = defaults.bool(forKey: "MacKit.clipboard.paused")
        autoPaste = defaults.bool(forKey: "MacKit.clipboard.autoPaste")
        maxVisible = ClipboardHistory.clampedVisible(defaults.object(forKey: "MacKit.clipboard.maxVisible") as? Int ?? 9)
        cloudFolder = defaults.string(forKey: "MacKit.clipboard.cloudFolder") ?? ""
        let existing = defaults.string(forKey: "MacKit.clipboard.device")
        deviceID = existing.flatMap { UUID(uuidString: $0)?.uuidString } ?? UUID().uuidString
        // 默认不写入设置或历史；只有启用保存时才保存设备标识。
        lastChange = board.changeCount
    }

    var entries: [ClipboardEntry] { archive.entries }
    var filtered: [ClipboardEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { q.isEmpty || ($0.text ?? $0.title).localizedCaseInsensitiveContains(q) || $0.source.localizedCaseInsensitiveContains(q) }
    }
    var selection: ClipboardEntry? { filtered.first(where: { $0.id == selectedID }) ?? filtered.first }
    var storageNote: String {
        switch storage {
        case .memory: return "仅本次运行记录，退出后不保留；保存和同步默认关闭。"
        case .local: return "仅保存到这台 Mac，不参与 iCloud 同步。"
        case .iCloud: return "历史以普通 JSON 文件写入所选 iCloud 文件夹，文字和图片都会同步。"
        }
    }

    func start() {
        guard !started else { return }
        started = true
        if storage != .memory {
            defaults.set(deviceID, forKey: "MacKit.clipboard.device")
            do { archive = try readCurrent(); status = "历史已载入" }
            catch { loadFailed = true; status = error.localizedDescription }
        }
        lastChange = board.changeCount // 不采集安装前已有的剪贴板内容
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer?.tolerance = 0.15
    }

    func syncNow() { persist() }

    func stop() { timer?.invalidate(); timer = nil; started = false }
    func setPaused(_ value: Bool) {
        paused = value
        defaults.set(value, forKey: "MacKit.clipboard.paused")
        lastChange = board.changeCount
    }
    func setAutoPaste(_ value: Bool) {
        autoPaste = value
        defaults.set(value, forKey: "MacKit.clipboard.autoPaste")
    }
    func setMaxVisible(_ value: Int) {
        let clamped = ClipboardHistory.clampedVisible(value)
        guard clamped != maxVisible else { return }
        maxVisible = clamped
        defaults.set(clamped, forKey: "MacKit.clipboard.maxVisible")
    }
    static func clampedVisible(_ value: Int) -> Int { min(30, max(1, value)) }

    static func capture(_ board: NSPasteboard, source: String = "") -> ClipboardEntry? {
        let types = Set((board.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: privateTypes) else { return nil }
        // 文件 / 富文本不属于本次范围，不读取文件原件。
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) { return nil }
        if let raw = board.data(forType: .png) ?? board.data(forType: .tiff) {
            guard raw.count <= 10_000_000, let bitmap = NSBitmapImageRep(data: raw),
                  bitmap.pixelsWide <= 16000, bitmap.pixelsHigh <= 16000,
                  bitmap.pixelsWide * bitmap.pixelsHigh <= 30_000_000,
                  let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
            return ClipboardEntry.make(png: png, source: source)
        }
        if let text = board.string(forType: .string) { return ClipboardEntry.make(text: text, source: source) }
        return nil
    }

    func poll() {
        if board.changeCount != lastChange {
            lastChange = board.changeCount
            if !paused, let entry = Self.capture(board, source: NSWorkspace.shared.frontmostApplication?.localizedName ?? "") {
                insert(entry)
            }
        }
        if storage == .iCloud, Date().timeIntervalSince(lastSync) > 10 { persist() }
    }

    func insert(_ item: ClipboardEntry) {
        var item = item
        if let old = entries.first(where: { $0.id == item.id }) {
            item.pinned = old.pinned
            item.shortcutKey = old.shortcutKey
            item.shortcutModifiers = old.shortcutModifiers
        }
        archive.entries.removeAll { $0.id == item.id }
        archive.entries.append(item)
        archive.entries = ClipboardArchive.bounded(archive.entries)
        persist()
    }

    func setShortcut(_ item: ClipboardEntry, key: String?, modifiers: [String]?) {
        guard let index = archive.entries.firstIndex(where: { $0.id == item.id }) else { return }
        archive.entries[index].shortcutKey = key
        archive.entries[index].shortcutModifiers = key == nil ? nil : modifiers
        archive.entries[index].editedAt = Date().timeIntervalSince1970
        archive.entries = ClipboardArchive.bounded(archive.entries)
        persist()
        onShortcutsChanged()
    }

    func entry(id: String) -> ClipboardEntry? {
        archive.entries.first(where: { $0.id == id })
    }

    func togglePin(_ item: ClipboardEntry) {
        guard let index = archive.entries.firstIndex(where: { $0.id == item.id }) else { return }
        if !archive.entries[index].pinned, entries.filter(\.pinned).count >= 30 {
            status = "最多置顶 30 项"; return
        }
        archive.entries[index].pinned.toggle()
        archive.entries[index].editedAt = Date().timeIntervalSince1970
        archive.entries = ClipboardArchive.bounded(archive.entries)
        persist()
    }

    func delete(_ item: ClipboardEntry) {
        archive.deleted[item.id] = Date().timeIntervalSince1970
        archive.entries.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        archive.clearedAt = Date().timeIntervalSince1970
        archive.entries = []
        archive.deleted = [:]
        persist()
        lastSync = .distantPast
        status = storage == .memory ? "本次历史已清空" : "历史已清空（同步模式会同步删除）"
    }

    func moveSelection(_ delta: Int) {
        let items = filtered
        guard !items.isEmpty else { selectedID = nil; return }
        let index = items.firstIndex(where: { $0.id == selectedID }) ?? 0
        selectedID = items[max(0, min(items.count - 1, index + delta))].id
    }

    @discardableResult
    func copy(_ entry: ClipboardEntry) -> Bool {
        board.clearContents()
        let item = NSPasteboardItem()
        if let png = entry.png { item.setData(png, forType: .png) }
        else if let text = entry.text { item.setString(text, forType: .string) }
        item.setString("MacKit", forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        let ok = board.writeObjects([item])
        lastChange = board.changeCount
        status = ok ? "已复制" : "无法写入剪贴板"
        return ok
    }

    func chooseStorage(_ mode: ClipboardStorage) {
        guard mode != storage else { return }
        if mode == .iCloud, cloudFolder.isEmpty {
            chooseCloudFolder()
            return
        }
        let oldMode = storage
        let oldArchive = archive
        let oldLoadFailed = loadFailed
        storage = mode
        loadFailed = false
        do {
            if mode != .memory {
                archive = ClipboardArchive.merge(archive, try readCurrent())
                try saveCurrent()
                defaults.set(deviceID, forKey: "MacKit.clipboard.device")
            }
            defaults.set(mode.rawValue, forKey: modeKey)
            status = mode == .memory ? "已关闭持久保存；已有保存文件保留，切回对应模式可清空。" : "保存方式已更新"
        } catch {
            storage = oldMode
            archive = oldArchive
            loadFailed = oldLoadFailed
            status = error.localizedDescription
        }
    }

    func chooseCloudFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "启用同步"
        panel.message = "请选择 iCloud Drive 内的文件夹。文字和图片历史会保存到 MacKit/Clipboard，其他 Mac 需选择同一文件夹。"
        panel.directoryURL = MacKitSyncLayout.writableRoot()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setCloudFolder(url)
    }

    func setCloudFolder(_ url: URL) {
        guard FileManager.default.isWritableFile(atPath: url.path) else { status = ClipboardError.unavailableFolder.localizedDescription; return }
        let oldFolder = cloudFolder
        let oldArchive = archive
        let oldLoadFailed = loadFailed
        cloudFolder = url.path
        let oldMode = storage
        storage = .iCloud
        loadFailed = false
        do {
            archive = ClipboardArchive.merge(archive, try readCurrent())
            try saveCurrent()
            defaults.set(url.path, forKey: "MacKit.clipboard.cloudFolder")
            defaults.set(deviceID, forKey: "MacKit.clipboard.device")
            defaults.set(storage.rawValue, forKey: modeKey)
            status = "已启用文件夹同步；请选择实际 iCloud Drive 路径以跨设备同步"
        } catch {
            storage = oldMode; cloudFolder = oldFolder
            archive = oldArchive; loadFailed = oldLoadFailed
            status = error.localizedDescription
        }
    }

    private var cloudURL: URL? {
        guard !cloudFolder.isEmpty else { return nil }
        return URL(fileURLWithPath: cloudFolder).appendingPathComponent("MacKit/Clipboard", isDirectory: true)
    }

    private func readFile(_ url: URL) throws -> ClipboardArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return ClipboardArchive() }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              (values.fileSize ?? 0) <= 45_000_000 else { throw ClipboardError.unsafePath }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ClipboardArchive.self, from: data).validated()
    }

    private func checkFolder(_ folder: URL) throws {
        // 检查已存在的父目录，不跟随替代剪贴板目录的符号链接。
        var cursor = folder
        while cursor.path != "/" {
            if FileManager.default.fileExists(atPath: cursor.path) {
                let v = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
                if v.isSymbolicLink == true {
                    let destination = try FileManager.default.destinationOfSymbolicLink(atPath: cursor.path)
                    let systemAlias = (cursor.path == "/var" && destination == "private/var")
                        || (cursor.path == "/tmp" && destination == "private/tmp")
                    guard systemAlias else { throw ClipboardError.unsafePath }
                }
            }
            cursor.deleteLastPathComponent()
        }
    }

    private func readCurrent() throws -> ClipboardArchive {
        if storage == .local {
            try checkFolder(localURL.deletingLastPathComponent())
            return try readFile(localURL)
        }
        guard storage == .iCloud, let folder = cloudURL,
              FileManager.default.fileExists(atPath: cloudFolder) else {
            if storage == .memory { return ClipboardArchive() }
            throw ClipboardError.unavailableFolder
        }
        try checkFolder(folder)
        guard FileManager.default.fileExists(atPath: folder.path) else { return ClipboardArchive() }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("device-") }
        guard files.count <= 50 else { throw ClipboardError.invalidArchive }
        let total = try files.reduce(0) { partial, file in
            partial + (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        guard total <= 80_000_000 else { throw ClipboardError.invalidArchive }
        var result = ClipboardArchive()
        for file in files { result = ClipboardArchive.merge(result, try readFile(file)) }
        return result
    }

    private func saveCurrent() throws {
        let url: URL
        if storage == .local { url = localURL }
        else if storage == .iCloud, let folder = cloudURL {
            guard FileManager.default.isWritableFile(atPath: cloudFolder) else { throw ClipboardError.unavailableFolder }
            url = folder.appendingPathComponent("device-\(deviceID).json")
        } else { return }
        try checkFolder(url.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: url.path) {
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ClipboardError.unsafePath }
        }
        let data = try JSONEncoder().encode(archive)
        if let old = try? Data(contentsOf: url), old == data { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func persist() {
        guard storage != .memory, !loadFailed else { return }
        lastSync = Date()
        do {
            if storage == .iCloud { archive = ClipboardArchive.merge(archive, try readCurrent()) }
            try saveCurrent()
        } catch { status = error.localizedDescription }
    }
}
