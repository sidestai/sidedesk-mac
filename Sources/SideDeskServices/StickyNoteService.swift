import Foundation
import SideDeskCore

/// 全局便签管理服务（对应 C# `Services.StickyNoteService`，#339：静态门面改实例服务）。
///
/// 主存储 SQLite（`local_global_note` 表，见 `LocalDbService.loadGlobalNotes/saveGlobalNotes`）；
/// db 尚未建立（首启未完成导入）时暂用旧 `sticky-notes.json`，db 就绪后的下次保存自动迁入并只留作备份。
///
/// **推迟到后续批次**（依赖尚未移植的服务）：
/// - `SyncToMemory`（#430 `MemoryStoreService.Ingest`：入库 AI 记忆，幂等，失败不影响便签存储）
/// - `Delete` 里的 `NoteImageService.DeleteNoteImages`（#216 回收便签孤儿图片）
public final class StickyNoteService {

    private let filePath: String
    private var notes: [StickyNote] = []
    private var loaded = false
    private let lock = NSLock()

    public init() {
        let folder = AppPaths.dataDir
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        filePath = (folder as NSString).appendingPathComponent("sticky-notes.json")
    }

    // MARK: - 惰性加载

    private func ensureLoaded() {
        lock.lock(); defer { lock.unlock() }
        if loaded { return }
        loaded = true
        if LocalDbService.dbExists {
            let dbNotes = LocalDbService.loadGlobalNotes()
            if !dbNotes.isEmpty { notes = dbNotes; return }
            // 表为空：从旧 JSON 一次性迁入（迁入后 JSON 仅作备份，不再读写）
            let fileNotes = loadFromFile()
            if !fileNotes.isEmpty { LocalDbService.saveGlobalNotes(fileNotes) }
            notes = fileNotes
            return
        }
        notes = loadFromFile()
    }

    private func loadFromFile() -> [StickyNote] {
        guard let data = FileManager.default.contents(atPath: filePath),
              let list = try? SideDeskJSON.decoder().decode([StickyNote].self, from: data)
        else { return [] }
        return list
    }

    // MARK: - 持久化

    public func Save() {
        lock.lock()
        let snapshot = notes
        lock.unlock()
        if LocalDbService.dbExists {
            LocalDbService.saveGlobalNotes(snapshot)
            return
        }
        // db 不可用/未建立：退回旧 JSON 存储
        if let data = try? SideDeskJSON.encoder().encode(snapshot) {
            try? data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        }
    }

    // MARK: - CRUD

    public func GetAll() -> [StickyNote] {
        ensureLoaded()
        lock.lock(); defer { lock.unlock() }
        return notes.sorted { $0.UpdatedAt > $1.UpdatedAt }
    }

    public func Add(_ note: StickyNote) {
        ensureLoaded()
        lock.lock()
        notes.append(note)
        lock.unlock()
        // SyncToMemory(note)   // 推迟：MemoryStoreService
        Save()
    }

    public func Update(_ note: StickyNote) {
        ensureLoaded()
        lock.lock()
        if let existing = notes.first(where: { $0.Id == note.Id }) {
            existing.Content = note.Content
            existing.UpdatedAt = Date()
            // SyncToMemory(existing)   // 推迟：MemoryStoreService
        }
        lock.unlock()
        Save()
    }

    public func Delete(_ id: String) {
        ensureLoaded()
        lock.lock()
        notes.removeAll { $0.Id == id }
        lock.unlock()
        // NoteImageService.DeleteNoteImages(.StickyNote, id)   // 推迟：图片回收
        Save()
    }

    /// 按 Id 查便签；不存在返回 nil。
    public func GetById(_ id: String) -> StickyNote? {
        ensureLoaded()
        lock.lock(); defer { lock.unlock() }
        return notes.first { $0.Id == id }
    }
}
