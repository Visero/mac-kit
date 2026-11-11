import Foundation
import Combine
import AppKit
import SwiftUI

// MARK: - 同步格式

enum MacKitSyncFormat {
    static let schema = 1
    static let folderName = "MacKit"
    static let settingsFile = "settings.json"
}

/// MacKit 的同步记录。`updatedAt` 是修改侧的时间戳（epoch 秒），
/// 随记录一起走，用来做 last-writer-wins 合并。
struct MacKitSyncRecord: Equatable {
    var schema: Int
    var updatedAt: Double
    var hotkeys: [HotkeyBinding]
    var sidebarOrder: [String]
    var quitWhitelist: [String]
}

extension MacKitSyncRecord: Codable {
    enum CodingKeys: String, CodingKey {
        case schema, updatedAt, hotkeys, sidebarOrder, quitWhitelist
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = (try? container.decode(Int.self, forKey: .schema)) ?? MacKitSyncFormat.schema
        updatedAt = (try? container.decode(Double.self, forKey: .updatedAt)) ?? 0
        hotkeys = (try? container.decode([HotkeyBinding].self, forKey: .hotkeys)) ?? []
        sidebarOrder = (try? container.decode([String].self, forKey: .sidebarOrder)) ?? []
        quitWhitelist = (try? container.decode([String].self, forKey: .quitWhitelist)) ?? []
    }
}

struct MacKitSyncSnapshot {
    var hotkeys: [HotkeyBinding]
    var sidebarOrder: [String]
    var quitWhitelist: [String]
}

enum MacKitSyncMerge {
    static let tieTolerance: Double = 0.5

    /// 远端必须“明显新于”本地才覆盖；时间相等时保留本地，
    /// 随后回写使两端收敛。未知 schema 不解码。
    static func merge(local: MacKitSyncRecord, remote: MacKitSyncRecord) -> MacKitSyncRecord {
        guard remote.schema == MacKitSyncFormat.schema else { return local }
        guard remote.updatedAt > local.updatedAt + tieTolerance else { return local }
        return remote
    }
}

// MARK: - 路径与文件读写

enum MacKitSyncLayout {
    static func classicICloudRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    /// macOS 也会把 iCloud Drive 挂在 `~/Library/CloudStorage` 下，
    /// 目录名可能是 “iCloud Drive” 或本地化的 “iCloud云盘-…”。
    static func cloudStorageRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let root = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return items.filter { url in
            let name = url.lastPathComponent.lowercased()
            return name.contains("icloud") && (name.contains("drive") || url.lastPathComponent.contains("云盘"))
        }
    }

    static func roots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [classicICloudRoot(home: home)] + cloudStorageRoots(home: home)
    }

    /// 优先返回经典路径；没有时回落到实际出现的 CloudStorage 目录。
    static func iCloudDriveRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        roots(home: home).first(where: { FileManager.default.fileExists(atPath: $0.path) })
            ?? classicICloudRoot(home: home)
    }

    /// 只有真实存在且可写的 iCloud Drive 才算可用，
    /// 避免把系统里只读的占位挂载当成同步位置。
    static func iCloudAvailable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        roots(home: home).contains { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return false }
            return FileManager.default.isWritableFile(atPath: url.path)
        }
    }

    static func writableRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        roots(home: home).first { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return false }
            return FileManager.default.isWritableFile(atPath: url.path)
        }
    }

    static func defaultBase() -> URL {
        writableRoot() ?? iCloudDriveRoot()
    }

    static func payloadURL(base: URL) -> URL {
        base.appendingPathComponent(MacKitSyncFormat.folderName, isDirectory: true)
    }
}

struct MacKitSyncRead<T> {
    var value: T?
    var unreadable = false
}

enum MacKitSyncIO {
    static let maximumBytes = 40_000_000

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw NSError(domain: "MacKitSync", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "同步路径不是文件夹。"])
            }
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> MacKitSyncRead<T> {
        guard exists(url) else { return MacKitSyncRead(value: nil) }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true { return MacKitSyncRead(value: nil, unreadable: true) }
        if let size = values?.fileSize, size > maximumBytes {
            return MacKitSyncRead(value: nil, unreadable: true)
        }
        guard let data = try? Data(contentsOf: url) else {
            return MacKitSyncRead(value: nil, unreadable: true)
        }
        guard let decoded = try? JSONDecoder().decode(type, from: data) else {
            return MacKitSyncRead(value: nil, unreadable: true)
        }
        return MacKitSyncRead(value: decoded)
    }

    /// 原子写入；内容未变化时不落盘。返回是否真的写入。
    @discardableResult
    static func write<T: Encodable>(_ value: T, to url: URL) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        if let existing = try? Data(contentsOf: url), existing == data { return false }

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard FileManager.default.createFile(atPath: temp.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "MacKitSync", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法写入同步文件。"])
        }
        // POSIX rename(2) 原子地创建或替换目标文件。
        guard rename(temp.path, url.path) == 0 else {
            throw NSError(domain: "MacKitSync", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "同步文件原子替换失败。"])
        }
        return true
    }
}

// MARK: - 同步引擎

final class MacKitCloudSyncEngine: ObservableObject {
    static let enabledKey = "MacKit.iCloudSyncEnabled"
    static let baseFolderKey = "MacKit.iCloudSyncBaseFolder"
    static let editedAtKey = "MacKit.iCloudSyncEditedAt"

    @Published private(set) var enabled = false
    @Published private(set) var baseFolder = ""
    @Published private(set) var iCloudAvailable = false
    @Published private(set) var busy = false
    @Published private(set) var lastError = ""
    @Published private(set) var status = "仅在本机"
    @Published private(set) var lastSync: Date?

    /// 由 AppDelegate 注入，在主线程读取当前配置。
    var snapshotProvider: (() -> MacKitSyncSnapshot)?
    /// 由 AppDelegate 注入，在主线程把远端记录应用到 config / 模型。
    var applyRemote: ((MacKitSyncRecord) -> String?)?

    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "mac-kit.cloud-sync", qos: .utility)
    private var pending: DispatchWorkItem?
    private var watcher: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    private var isApplying = false
    private var editedAt: Double = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
        baseFolder = defaults.string(forKey: Self.baseFolderKey) ?? ""
        editedAt = defaults.double(forKey: Self.editedAtKey)
        iCloudAvailable = MacKitSyncLayout.iCloudAvailable()
        if enabled { status = "等待首次同步" }
    }

    deinit {
        pollTimer?.invalidate()
        watcher?.cancel()
    }

    // MARK: 对外状态

    var payloadURL: URL? {
        guard !baseFolder.isEmpty else { return nil }
        return MacKitSyncLayout.payloadURL(base: URL(fileURLWithPath: baseFolder))
    }

    var folderDisplayPath: String { payloadURL?.path ?? "尚未选择文件夹" }

    var usesICloudDrive: Bool {
        guard !baseFolder.isEmpty else { return false }
        return MacKitSyncLayout.roots().contains { root in
            baseFolder == root.path || baseFolder.hasPrefix(root.path + "/")
        }
    }

    var statusText: String {
        guard enabled else { return "仅在本机" }
        if busy { return "同步中…" }
        if !lastError.isEmpty { return "同步待处理" }
        if let lastSync {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "已同步 · \(formatter.string(from: lastSync))"
        }
        return "等待首次同步"
    }

    // MARK: 用户操作

    func startIfEnabled() {
        guard enabled else { return }
        start()
    }

    func enable() {
        iCloudAvailable = MacKitSyncLayout.iCloudAvailable()
        if baseFolder.isEmpty {
            guard iCloudAvailable else {
                fail("未检测到可写的 iCloud Drive。请先在系统设置中开启 iCloud 云盘，或手动选择文件夹。")
                return
            }
            baseFolder = MacKitSyncLayout.defaultBase().path
            defaults.set(baseFolder, forKey: Self.baseFolderKey)
        }
        do {
            _ = try ensurePayloadDirectory()
        } catch {
            fail("无法创建同步文件夹：\(error.localizedDescription)")
            return
        }
        enabled = true
        defaults.set(true, forKey: Self.enabledKey)
        lastError = ""
        status = "等待首次同步"
        start()
    }

    func disable() {
        enabled = false
        defaults.set(false, forKey: Self.enabledKey)
        stopWatching()
        pending?.cancel()
        pending = nil
        busy = false
        status = "已关闭同步"
        lastError = ""
    }

    func refreshICloudAvailability() {
        iCloudAvailable = MacKitSyncLayout.iCloudAvailable()
    }

    func useICloudDriveDefault() {
        iCloudAvailable = MacKitSyncLayout.iCloudAvailable()
        guard iCloudAvailable else {
            fail("本机未检测到可写的 iCloud Drive。请在 系统设置 → Apple 账户 → iCloud → iCloud 云盘 中开启“同步此 Mac”。")
            return
        }
        setBaseFolder(MacKitSyncLayout.defaultBase())
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "使用此文件夹"
        panel.message = "MacKit 会在所选文件夹内创建 \(MacKitSyncFormat.folderName) 目录，只写入同步数据。"
        if !baseFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: baseFolder)
        } else if let root = MacKitSyncLayout.writableRoot() {
            panel.directoryURL = root
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setBaseFolder(url)
    }

    func setBaseFolder(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            fail("所选位置不是文件夹。")
            return
        }
        stopWatching()
        baseFolder = url.path
        defaults.set(baseFolder, forKey: Self.baseFolderKey)
        iCloudAvailable = MacKitSyncLayout.iCloudAvailable()
        if enabled { start() } else { enable() }
    }

    func syncNow() {
        guard enabled else { return }
        schedule(0)
    }

    /// 本机配置发生变化时调用；禁用同步时也会记下时间戳，
    /// 以便下次开启时以本机较新的内容为准。
    func noteLocalChange() {
        guard !isApplying else { return }
        editedAt = Date().timeIntervalSince1970
        defaults.set(editedAt, forKey: Self.editedAtKey)
        if enabled { schedule() }
    }

    /// 退出前尽力把本机最新设置写进同步文件夹。
    func flushOnTerminate() {
        guard enabled, let root = try? ensurePayloadDirectory(), let snapshot = currentSnapshot() else { return }
        let local = makeRecord(snapshot)
        queue.sync {
            _ = mergeAndWrite(local, root: root)
        }
    }

    // MARK: 调度

    private func schedule(_ delay: TimeInterval = 0.6) {
        guard enabled else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runReconcile() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func start() {
        guard enabled else { return }
        do {
            _ = try ensurePayloadDirectory()
        } catch {
            fail("无法创建同步文件夹：\(error.localizedDescription)")
            enabled = false
            defaults.set(false, forKey: Self.enabledKey)
            return
        }
        startWatching()
        schedule(0.4)
    }

    private func currentSnapshot() -> MacKitSyncSnapshot? {
        snapshotProvider?()
    }

    private func ensurePayloadDirectory() throws -> URL {
        guard let payloadURL else {
            throw NSError(domain: "MacKitSync", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "尚未选择同步文件夹。"])
        }
        let base = URL(fileURLWithPath: baseFolder)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw NSError(domain: "MacKitSync", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "同步文件夹不存在，请重新选择。"])
        }
        try MacKitSyncIO.ensureDirectory(payloadURL)
        return payloadURL
    }

    private func fail(_ message: String) {
        lastError = message
        status = "同步未完成"
        Log.write("iCloud 同步：\(message)")
    }

    private func makeRecord(_ snapshot: MacKitSyncSnapshot) -> MacKitSyncRecord {
        MacKitSyncRecord(schema: MacKitSyncFormat.schema,
                         updatedAt: editedAt,
                         hotkeys: snapshot.hotkeys,
                         sidebarOrder: snapshot.sidebarOrder,
                         quitWhitelist: snapshot.quitWhitelist)
    }

    private struct SyncPlan {
        var record: MacKitSyncRecord
        var unreadable = ""
    }

    private func runReconcile() {
        guard enabled, let snapshot = currentSnapshot(),
              let root = try? ensurePayloadDirectory() else { return }
        let local = makeRecord(snapshot)
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            let plan = self.mergeAndWrite(local, root: root)
            DispatchQueue.main.async { self.apply(plan, local: local) }
        }
    }

    private func mergeAndWrite(_ local: MacKitSyncRecord, root: URL) -> SyncPlan {
        let url = root.appendingPathComponent(MacKitSyncFormat.settingsFile)
        var plan = SyncPlan(record: local)
        let read = readRecord(url)
        if read.unreadable {
            plan.unreadable = "settings.json 无法读取，已保留原文件"
            return plan
        }
        if let remote = read.value {
            plan.record = MacKitSyncMerge.merge(local: local, remote: remote)
        }
        if read.value != plan.record, !read.unreadable {
            _ = try? MacKitSyncIO.write(plan.record, to: url)
        }
        return plan
    }

    private func readRecord(_ url: URL) -> MacKitSyncRead<MacKitSyncRecord> {
        var result = MacKitSyncIO.read(MacKitSyncRecord.self, from: url)
        if let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty {
            for version in versions {
                if let record = MacKitSyncIO.read(MacKitSyncRecord.self, from: version.url).value {
                    result.value = result.value.map {
                        MacKitSyncMerge.merge(local: $0, remote: record)
                    } ?? record
                }
                version.isResolved = true
            }
        }
        return result
    }

    private func apply(_ plan: SyncPlan, local: MacKitSyncRecord) {
        busy = false
        guard plan.unreadable.isEmpty else {
            fail(plan.unreadable)
            return
        }

        if plan.record.updatedAt > local.updatedAt + MacKitSyncMerge.tieTolerance {
            isApplying = true
            let error = applyRemote?(plan.record)
            isApplying = false
            if let error {
                fail(error)
                return
            }
            editedAt = plan.record.updatedAt
            defaults.set(editedAt, forKey: Self.editedAtKey)
        }

        lastError = ""
        lastSync = Date()
        status = "已同步"
    }

    // MARK: 监听

    private func startWatching() {
        stopWatching()
        guard let root = payloadURL else { return }
        let descriptor = open(root.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .rename, .delete, .attrib],
                queue: queue)
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                let flags = source.data
                DispatchQueue.main.async { self.schedule(0.9) }
                if flags.contains(.delete) || flags.contains(.rename) {
                    DispatchQueue.main.async { self.startWatching() }
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watcher = source
        }
        // iCloud 落盘有延迟，文件事件之后再用慢轮询兜底。
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.schedule(0)
        }
        pollTimer?.tolerance = 5
    }

    private func stopWatching() {
        pollTimer?.invalidate()
        pollTimer = nil
        watcher?.cancel()
        watcher = nil
    }
}

// MARK: - 设置卡片

struct MacKitSyncSettingsCard: View {
    @ObservedObject var engine: MacKitCloudSyncEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("iCloud 同步", systemImage: "icloud")
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                Text(engine.statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(engine.lastError.isEmpty ? Color.secondary : Color.orange)
                    .lineLimit(1)
                GlassSwitch(isOn: Binding(
                    get: { engine.enabled },
                    set: { on in on ? engine.enable() : engine.disable() }
                ))
            }

            Text(engine.enabled
                 ? "同步快捷键、侧栏顺序和关闭白名单；文件只写入 iCloud Drive 的 MacKit 文件夹。"
                 : "开启后通过 iCloud Drive 在你的 Mac 之间同步快捷键、侧栏顺序和关闭白名单。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if engine.enabled {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(engine.folderDisplayPath)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Button("立即同步") { engine.syncNow() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(engine.busy)
                }

                HStack(spacing: 7) {
                    Button("选择文件夹…") { engine.chooseFolder() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    if !engine.usesICloudDrive && engine.iCloudAvailable {
                        Button("iCloud 默认位置") { engine.useICloudDriveDefault() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Spacer()
                }
            } else if !engine.iCloudAvailable {
                HStack(spacing: 7) {
                    Text("未检测到可写的 iCloud Drive，可直接选择一个文件夹代替。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Button("选择文件夹…") { engine.chooseFolder() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if !engine.lastError.isEmpty {
                Text(engine.lastError)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        )
        .onAppear { engine.refreshICloudAvailability() }
    }
}
