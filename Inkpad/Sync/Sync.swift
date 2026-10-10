import Foundation
import CryptoKit

/// Google Drive sync for the notebook library, the same protocol as the desktop app.
///
/// Sync is an index-driven delta merge. Every notebook has a permanent id, and one
/// small index file on Drive lists each id with its path, content hash, Drive file
/// and state. A sync downloads that index, compares it per id with the library and
/// with what both sides looked like last time, moves only the notebooks that
/// differ, then writes the index back. Deleted notebooks stay in the index as
/// tombstones, which is how a deletion reaches other devices instead of being
/// undone by them; renames and moves are just a changed path on the same id.
/// Nothing is destroyed: deletions go to the local trash, and a notebook edited on
/// both sides is merged item by item.
///
/// Two devices may well sync at the same moment, and one of them may be cut off half way
/// and go on much later with what it read before. So the index is never taken at its word
/// about a notebook's content: what counts is the checksum Drive itself reports for the
/// file, asked for again just before the file is replaced. A device that finds another
/// has been there first merges instead of overwriting, and the index is read again
/// before it is written, so that what others put in it meanwhile is kept.
///
/// A notebook's large PDFs and pictures are not part of the file that is uploaded for it.
/// They never change, and they are nearly all of a large notebook's size, so each is kept
/// on Drive once, as a file of its own named after its checksum and size, and the notebook's
/// file lists them. Writing a line in a 200 MB textbook then sends the ink, not the book.

struct DriveError: LocalizedError {
    let message: String
    var code: Int?   // the HTTP status, when Google answered with an error
    init(_ message: String, code: Int? = nil) {
        self.message = message
        self.code = code
    }
    var errorDescription: String? { message }
}

/// A file in a Drive folder, as much of it as the sync looks at.
struct DriveFile {
    let id: String
    let name: String
    let md5: String?
    let modified: Double
}

extension DriveAPI {
    func alive(_ fileID: String) async throws -> Bool { true }
}

protocol DriveAPI: AnyObject {
    /// Called with (bytes so far, total) during an upload or a download.
    var onBytes: ((Int64, Int64) -> Void)? { get set }
    func root() async throws -> String
    func find(_ name: String, parent: String) async throws -> String?
    func getJSON(_ fileID: String) async throws -> [String: Any]
    /// Create or replace a small JSON file; returns its id.
    func putJSON(_ name: String, _ value: [String: Any], parent: String, fileID: String?) async throws -> String
    func rename(_ fileID: String, _ name: String) async throws
    /// Create or replace a file; returns (id, md5).
    func upload(_ url: URL, name: String, parent: String, fileID: String?) async throws -> (String, String?)
    func download(_ fileID: String, to dest: URL) async throws
    /// The files in a folder.
    func children(_ parent: String) async throws -> [DriveFile]
    /// The checksum of a file's content as it is on Drive at this moment.
    func md5(_ fileID: String) async throws -> String?
    /// Whether a file or folder is still there, and not in the bin. (One that has been binned
    /// still answers to its id, which is why this has to be asked.)
    func alive(_ fileID: String) async throws -> Bool
}

struct SyncSummary: Equatable {
    var up = 0, down = 0, conflicts = 0, merged = 0, removed = 0, moved = 0
    var mended = 0   // notebooks found here without their PDFs and made whole again
    var meta = false
}

enum LibrarySync {
    static let rootName = "Inkpad"
    static let indexName = "_inkpad_index.json"
    static var checkpoint = 10.0   // seconds of transfers after which a sync notes, in the index, how far it has got

    /// The id of the Drive folder to sync with, checked to be there. `wanted` is the folder the
    /// user asked for, or "" for one named Inkpad at the top of their Drive. When it is not the
    /// folder this device synced with before, what was remembered about that one is dropped,
    /// so that the library is compared with the new folder from nothing.
    static func cloudFolder(_ state: inout [String: Any], _ drive: DriveAPI, wanted: String, check: Bool = true) async throws -> String {
        if (state["folder_set"] as? String ?? "") != wanted {
            state = ["folder_set": wanted]
        } else if !check, let root = state["root"] as? String, !root.isEmpty {
            return root   // taken on trust; a thorough sync looks
        }
        if !wanted.isEmpty {
            var there = false
            do {
                there = try await drive.alive(wanted)
            } catch let error as DriveError where error.code == 403 || error.code == 404 {
            }
            if !there {
                // With the drive.file permission Google shows the app only what the app itself made.
                throw DriveError(trf("无法使用文件夹 %s：它不存在、在回收站里，或者不是 Inkpad 创建的。Inkpad 只被允许访问它自己创建的文件夹；可以先留空同步一次，把生成的“Inkpad”文件夹在 Google Drive 里移到想放的位置，再把它的 ID 填到其它设备上。", wanted))
            }
            state["root"] = wanted
        } else {
            var kept = false
            if let saved = state["root"] as? String { kept = try await drive.alive(saved) }
            if !kept { state["root"] = try await drive.root() }
        }
        return state["root"] as? String ?? ""
    }

    /// The id of the folder this library last synced with, or "".
    static func cloudFolder(_ root: URL) -> String {
        loadJSON(root.appendingPathComponent(".sync.json"))["root"] as? String ?? ""
    }

    /// A folder id out of what was typed: the id itself, or the address of the folder.
    static func parseFolder(_ typed: String) throws -> String {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        for mark in ["/folders/", "id="] {
            if let at = text.range(of: mark) { text = String(text[at.upperBound...]) }
        }
        for stop in ["?", "/", "&", "#"] {
            if let at = text.range(of: stop) { text = String(text[..<at.lowerBound]) }
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if !text.isEmpty, text.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            throw DriveError(tr("这不像是 Google Drive 的文件夹 ID"))
        }
        return text
    }

    static var blobMin = 32 * 1024      // a PDF or picture at least this big is kept on Drive as a file of its own
    static let blobsName = "blobs.json"   // in an uploaded notebook: {name in the zip: name of the file on Drive}
    static let format = 3                 // of the index. 2: notebooks are uploaded without their blobs; 3: blobs named by SHA-256
    static var thoroughEvery = 6 * 3600.0 // seconds after which a sync checks the index against Drive unasked

    static func isBlob(_ e: ZipEntry) -> Bool {
        (e.name.hasPrefix("pdf/") || e.name.hasPrefix("img/")) && e.size >= blobMin
    }

    // A blob is known by the SHA-256 of its content: two that carry the same name are the same
    // bytes, as far as anyone can tell, and one that is downloaded is checked against its name.
    // (Before, in index format 2, the name was the zip's CRC-32 and the size, which is not enough
    // to say that two files are the same. Notebooks uploaded then still list those names, and
    // are read; whatever is uploaded now uses the new ones.)
    static let shaPrefix = "blob-sha256-"

    static func oldName(_ e: ZipEntry) -> String { String(format: "blob-%08x-%d", e.crc, e.size) }

    static func shaName(_ data: Data) -> String {
        shaPrefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// What was found of one blob in a notebook the last time: [CRC, size, name of the blob].
    private static func named(_ seen: [String: Any]?, _ e: ZipEntry) -> String? {
        guard let was = seen?[e.name] as? [Any], was.count == 3,
              (was[0] as? NSNumber)?.uint32Value == e.crc, (was[1] as? NSNumber)?.intValue == e.size else { return nil }
        return was[2] as? String
    }

    /// Write to `dest` the notebook as it is uploaded: without its large PDFs and pictures, and
    /// with a list of them instead. Those for which `have` is false are written next to
    /// `dest`, to be uploaded first. Returns the file's fileSign(), where each such blob was
    /// written, and what to pass as `seen` the next time.
    ///
    /// `seen` is what was found in this notebook the last time: {name in the zip: [CRC, size,
    /// name of the blob]}. A PDF that is still in the same place with the same CRC and size is
    /// the one that was there then, and is not read through again to name it; so sending a
    /// line written in a 200 MB book does not mean reading the book.
    ///
    /// The file is read once, so all of this is about one version of it even if it is saved
    /// again meanwhile.
    static func slim(_ url: URL, to dest: URL, seen: [String: Any]? = nil, have: (String) -> Bool) throws -> (stat: String, blobs: [String: URL], found: [String: Any]) {
        let stat = fileSign(url) ?? ""
        let z = try ZipReader(data: Data(contentsOf: url, options: .mappedIfSafe))
        let out = try ZipWriter(url: dest)
        var listed: [String: String] = [:], parts: [String: URL] = [:], found: [String: Any] = [:]
        do {
            var done = Set<String>()
            for e in z.entries.reversed() where done.insert(e.name).inserted && e.name != blobsName {
                if !isBlob(e) {
                    try out.addRaw(e.name, method: e.method, crc: e.crc, size: e.size, raw: z.raw(e))
                    continue
                }
                let name = try named(seen, e) ?? shaName(z.read(e.name))
                listed[e.name] = name
                found[e.name] = [NSNumber(value: e.crc), e.size, name] as [Any]
                if parts[name] == nil, !have(name) {
                    let part = dest.appendingPathExtension(name)
                    try z.read(e.name).write(to: part)
                    parts[name] = part
                }
            }
            if !listed.isEmpty { try out.add(blobsName, JSONSerialization.data(withJSONObject: listed)) }
            try out.finish()
        } catch {
            out.abandon()
            throw error
        }
        return (stat, parts, found)
    }

    /// Make a downloaded notebook whole again: its large PDFs and pictures are taken from the
    /// copy of it that is here already (`have`) where that has them, and downloaded with
    /// `fetch(name of the blob, where to)` otherwise.
    static func fatten(_ part: URL, have: URL?, seen: [String: Any]? = nil, fetch: (String, URL) async throws -> Void) async throws {
        let fm = FileManager.default
        let z = try ZipReader(url: part)
        guard z.has(blobsName) else { return }   // uploaded whole, by an earlier version
        let listed = (try JSONSerialization.jsonObject(with: z.read(blobsName)) as? [String: String]) ?? [:]
        let old = have.flatMap { try? ZipReader(url: $0) }
        let mine = (old?.entries ?? []).filter(isBlob)
        var byOld: [String: ZipEntry] = [:]
        for e in mine { byOld[oldName(e)] = e }
        var bySHA: [String: ZipEntry]?   // worked out when first asked for: it means reading every one of them
        func local(_ blob: String) throws -> ZipEntry? {
            guard blob.hasPrefix(shaPrefix) else { return byOld[blob] }
            if bySHA == nil {
                var all: [String: ZipEntry] = [:]
                // Named before and not changed since, or read through now.
                for e in mine { all[try named(seen, e) ?? shaName(old!.read(e.name))] = e }
                bySHA = all
            }
            return bySHA?[blob]
        }
        let full = part.appendingPathExtension("full")
        let out = try ZipWriter(url: full)
        do {
            for e in z.entries where e.name != blobsName {
                try out.addRaw(e.name, method: e.method, crc: e.crc, size: e.size, raw: z.raw(e))
            }
            for (name, blob) in listed.sorted(by: { $0.key < $1.key }) {
                if let old, let e = try local(blob) {
                    try out.addRaw(name, method: e.method, crc: e.crc, size: e.size, raw: old.raw(e))
                } else {
                    let tmp = full.appendingPathExtension("blob")
                    try await fetch(blob, tmp)
                    let data = try Data(contentsOf: tmp, options: .mappedIfSafe)
                    if blob.hasPrefix(shaPrefix), shaName(data) != blob {
                        throw DriveError(trf("从云端下载的 PDF 或图片（%s）内容不对，没有使用它。请再同步一次。", String(blob.prefix(24))))
                    }
                    // Stored, as the app itself writes them: they are compressed already.
                    try out.add(name, data, compress: false)
                    try? fm.removeItem(at: tmp)
                }
            }
            try out.finish()
        } catch {
            out.abandon()
            throw error
        }
        _ = try fm.replaceItemAt(part, withItemAt: full)
    }

    /// Whether a notebook in the library is one as it is uploaded, without its large PDFs and
    /// pictures. That is never meant to be: it is what a download that was cut off before those
    /// had come left behind, or what a version of the app from before they were kept apart put
    /// in place of the whole notebook. It cannot be opened, and must not be taken for a
    /// notebook that is up to date, or be sent anywhere.
    static func stripped(_ url: URL) -> Bool {
        (try? ZipReader(url: url))?.has(blobsName) ?? false
    }

    static func fetcher(_ drive: DriveAPI, _ rootID: String, _ names: @escaping () -> [String: String]) -> (String, URL) async throws -> Void {
        { blob, dest in
            var id = names()[blob]
            if id == nil { id = try await drive.find(blob, parent: rootID) }
            guard let id else {
                throw DriveError(trf("云端缺少这本笔记里的一个 PDF 或图片（%s）。请在仍有这本笔记的设备上同步一次。", blob))
            }
            try await drive.download(id, to: dest)
        }
    }

    static func md5(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = Insecure.MD5()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty { digest.update(data: block) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var out = url
        var n = 2
        while fm.fileExists(atPath: out.path) {
            out = url.deletingLastPathComponent().appendingPathComponent("\(base) \(n)\(ext)")
            n += 1
        }
        return out
    }

    static func relPath(_ url: URL, _ root: URL) -> String {
        let path = url.standardizedFileURL.path, base = root.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
    }

    /// (notebooks, folders) in the library: relative path -> file, and a set of relative paths.
    static func scan(_ root: URL) -> ([String: URL], Set<String>) {
        var files: [String: URL] = [:]
        var folders = Set<String>()
        let fm = FileManager.default
        func walk(_ dir: URL, _ prefix: String) {
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                let name = url.lastPathComponent
                if name.hasPrefix(".") { continue }
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    folders.insert(prefix + name)
                    walk(url, prefix + name + "/")
                } else if name.hasSuffix(notebookExt) {
                    files[prefix + name] = url
                }
            }
        }
        walk(root, "")
        return (files, folders)
    }

    static func loadJSON(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func saveJSON(_ url: URL, _ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: url, options: .atomic)
    }

    static func lastSync(_ root: URL) -> Date? {
        (loadJSON(root.appendingPathComponent(".sync.json"))["last"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    struct CloudDeleted: Identifiable, Equatable {
        let id: String
        let path: String
        let ts: Double
    }

    private static func index(_ root: URL, _ drive: DriveAPI, _ state: inout [String: Any], _ folder: String) async throws -> (cloud: [String: Any], rootID: String, indexID: String?) {
        let rootID = try await cloudFolder(&state, drive, wanted: folder)
        var indexID = state["index"] as? String
        if indexID == nil { indexID = try await drive.find(indexName, parent: rootID) }
        var cloud: [String: Any] = [:]
        if let indexID { cloud = try await drive.getJSON(indexID) }
        return (cloud, rootID, indexID)
    }

    /// Notebooks the index marks as deleted while their file is still on Drive.
    /// Nothing is downloaded: this only reads the index. Newest first.
    static func cloudDeleted(root: URL, drive: DriveAPI, folder: String = "") async throws -> [CloudDeleted] {
        var state = loadJSON(root.appendingPathComponent(".sync.json"))
        let (cloud, _, _) = try await index(root, drive, &state, folder)
        let items = cloud["items"] as? [String: [String: Any]] ?? [:]
        return items.compactMap { nid, entry in
            guard entry["deleted"] as? Bool == true, entry["file"] is String else { return nil }
            return CloudDeleted(id: nid, path: entry["path"] as? String ?? nid, ts: num(entry["ts"]))
        }.sorted { $0.ts > $1.ts }
    }

    /// Download the chosen deleted notebooks back to the paths they had; returns how many.
    static func cloudRestore(root: URL, drive: DriveAPI, ids: [String], folder: String = "", progress: ((Double, String) -> Void)? = nil) async throws -> Int {
        let fm = FileManager.default
        let root = root.standardizedFileURL
        let statePath = root.appendingPathComponent(".sync.json")
        var state = loadJSON(statePath)
        var (cloud, rootID, indexID) = try await index(root, drive, &state, folder)
        var items = cloud["items"] as? [String: [String: Any]] ?? [:]
        var known = state["items"] as? [String: [String: Any]] ?? [:]
        var done = 0
        var names: [String: String]?
        for (n, nid) in ids.enumerated() {
            guard var entry = items[nid], let file = entry["file"] as? String else { continue }
            let rel = entry["path"] as? String ?? nid + notebookExt
            let name = (rel as NSString).lastPathComponent
            progress?(Double(n) / Double(ids.count), name)
            drive.onBytes = { got, total in
                if total > 0 { progress?((Double(n) + Double(got) / Double(total)) / Double(ids.count), name) }
            }
            let target = unique(rel.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) })
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if names == nil {
                names = Dictionary(try await drive.children(rootID).map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
            }
            let all = names ?? [:]
            let coming = target.appendingPathExtension("part")   // whole before it is given its name in the library
            try await drive.download(file, to: coming)
            try await fatten(coming, have: nil, fetch: fetcher(drive, rootID) { all })
            try fm.moveItem(at: coming, to: target)
            let now = relPath(target, root)
            // It is a live notebook again, on both sides, with what the cloud holds.
            entry["deleted"] = false
            entry["trashed"] = false
            entry["path"] = now
            entry["ts"] = Date().timeIntervalSince1970
            items[nid] = entry
            known[nid] = ["path": now, "trashed": false, "md5": entry["md5"] as? String ?? "", "local": try md5(target)]
            done += 1
        }
        drive.onBytes = nil
        if done > 0 {
            cloud["items"] = items
            state["root"] = rootID
            state["index"] = try await drive.putJSON(indexName, cloud, parent: rootID, fileID: indexID)
            state["items"] = known
            try saveJSON(statePath, state)
        }
        progress?(1, "")
        return done
    }

    private final class Ref {
        var d: [String: Any]
        init(_ d: [String: Any] = [:]) { self.d = d }
        var deleted: Bool { d["deleted"] as? Bool ?? false }
        var trashed: Bool { d["trashed"] as? Bool ?? false }
        var md5: String? { d["md5"] as? String }
        var file: String? { d["file"] as? String }
        var path: String? { d["path"] as? String }
    }

    private struct Local {
        var url: URL
        var rel: String
        var inTrash: Bool
    }

    /// Merge the library folder with the Drive index.
    ///
    /// skip lists notebooks to leave alone (one being edited). progress(fraction, text)
    /// reports how far along the sync is: one step for reading the index, one per
    /// notebook (advancing with the bytes of its transfer) and one for the end.
    ///
    /// A sync is quick or thorough. A quick one takes the index at its word about what is on
    /// Drive, and this device's own record about which notebooks were written since the last
    /// sync: it reads the index, moves what differs and writes the index back. It is what runs
    /// on leaving a notebook and while one is open. A thorough one also lists the folder on
    /// Drive and puts right what does not fit: files deleted there, a folder that is gone, an
    /// index that is behind the files. That is done when asked for (`thorough: true`: the
    /// user's "sync now", and once when the app starts), when it has not been done for some
    /// hours, and when a quick sync comes upon something on Drive that is not there.
    ///
    /// With `only`, nothing but those notebooks is looked at, which takes a few requests and is
    /// what an open notebook is kept up to date with while it is being written in.
    static func sync(root: URL, drive: DriveAPI, skip: [URL] = [], only: [URL]? = nil, folder: String = "", thorough: Bool? = nil,
                     progress: ((Double, String) -> Void)? = nil) async throws -> SyncSummary {
        var all = thorough
        if all == nil {
            let state = loadJSON(root.standardizedFileURL.appendingPathComponent(".sync.json"))
            all = state["index"] as? String == nil || Date().timeIntervalSince1970 - num(state["checked"]) > thoroughEvery
        }
        do {
            return try await run(root: root, drive: drive, skip: skip, only: only, folder: folder, thorough: all!, progress: progress)
        } catch let error as DriveError where all == false && error.code == 404 {
            // Something was not where the index said.
            return try await run(root: root, drive: drive, skip: skip, only: only, folder: folder, thorough: true, progress: progress)
        }
    }

    private static func run(root: URL, drive: DriveAPI, skip: [URL], only: [URL]?, folder: String, thorough: Bool,
                            progress: ((Double, String) -> Void)?) async throws -> SyncSummary {
        let fm = FileManager.default
        let root = root.standardizedFileURL
        let report = progress ?? { _, _ in }
        report(0, tr("正在读取云端目录…"))
        let statePath = root.appendingPathComponent(".sync.json")
        var state = loadJSON(statePath)
        let rootID = try await cloudFolder(&state, drive, wanted: folder, check: thorough)
        // id -> {'path', 'trashed', 'md5', ...} when both sides last agreed
        var known = state["items"] as? [String: [String: Any]] ?? [:]
        let trashDir = root.appendingPathComponent(".trash", isDirectory: true)
        try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        var summary = SyncSummary()

        // A thorough sync has the folder's listing to go by; a quick one has only the index.
        let inFolder = thorough ? try await drive.children(rootID) : nil
        let live = inFolder.map { Set($0.map(\.id)) }
        var indexID = state["index"] as? String
        if let inFolder, let live {
            if indexID == nil || !live.contains(indexID!) { indexID = inFolder.first { $0.name == indexName }?.id }
        } else if indexID == nil {
            indexID = try await drive.find(indexName, parent: rootID)
        }
        var cloud: [String: Any] = [:]
        if let indexID { cloud = try await drive.getJSON(indexID) }
        if num(cloud["format"], 1) > Double(format) {
            throw DriveError(tr("云端的笔记是由更新版本的 Inkpad 同步的，请先更新这台设备上的 Inkpad"))
        }
        // The PDFs and pictures kept on Drive as files of their own are listed in the index too.
        var names = cloud["blobs"] as? [String: String] ?? [:]   // name -> Drive file
        let fetch = fetcher(drive, rootID) { names }
        var blobsSeen: [String: [String: Any]] = [:]   // id -> the blobs found in the notebook when it was sent: see slim()
        let workDir = root.appendingPathComponent(".sync", isDirectory: true)
        try? fm.removeItem(at: workDir)   // whatever a sync that was cut off left behind
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        var agreed: [String: (String, String)] = [:]   // id -> (checksum, fileSign()) of the local file that matches the cloud's version
        // id -> {'path', 'trashed', 'md5', 'file', 'deleted', 'ts'}
        var items: [String: Ref] = [:]
        for (nid, value) in cloud["items"] as? [String: Any] ?? [:] { items[nid] = Ref(value as? [String: Any] ?? [:]) }
        for part in ["items", "blobs"] where cloud[part] == nil { cloud[part] = [String: Any]() }
        let read0 = cloud         // the index as it was read, to tell later what others changed
        if let inFolder, let live {
            for (nid, entry) in items where entry.file == nil || !live.contains(entry.file!) {
                if entry.deleted {
                    entry.d["file"] = NSNull()   // still a deletion to pass on, with nothing left to restore
                } else {
                    // Listed, but its file is gone from Drive. Forgotten here, it is sent again by
                    // whichever device still has it.
                    items[nid] = nil
                }
            }
            let actual = Dictionary(inFolder.compactMap { f in f.md5.map { (f.id, $0) } }, uniquingKeysWith: { a, _ in a })
            for entry in items.values where !entry.deleted {
                // The file itself says what is in it. The index may be behind: a device that was
                // cut off after an upload never got to write it down.
                if let file = entry.file, let md5 = actual[file] { entry.d["md5"] = md5 }
            }
            // The same for the list of blobs: those that are gone are forgotten, and those that
            // are there unlisted (uploaded before the index kept this list) are taken up.
            names = names.filter { live.contains($0.value) }
            for f in inFolder where f.name.hasPrefix("blob-") && names[f.name] == nil { names[f.name] = f.id }
            state["checked"] = Date().timeIntervalSince1970
        }
        /// The index as this sync has it now.
        func index() -> [String: Any] {
            var out = cloud
            out["items"] = items.mapValues { $0.d }
            out["blobs"] = names
            return out
        }
        var read = read0
        var mended = !(index() as NSDictionary).isEqual(read0)   // whether looking at Drive showed the index to be wrong
        var mineWas = index()     // and as this sync started out with it
        var sent = Set<String>()  // ids of the notebooks this sync uploaded
        var savedAt = Date()
        var moved = 0

        func same(_ a: Any?, _ b: Any?) -> Bool {
            if let a, let b { return (a as AnyObject).isEqual(b) }
            return a == nil && b == nil
        }

        /// Write the index. It is read again first: whatever another device changed in it while
        /// this sync was running is kept, wherever this sync did not change the same thing.
        func publish() async throws {
            if indexID != nil, !mended, same(index(), mineWas) {
                state["index"] = indexID   // found, if not written: remembered all the same
                return   // nothing to write down
            }
            if indexID == nil { indexID = try await drive.find(indexName, parent: rootID) }
            var latest: [String: Any] = [:]
            if let indexID { latest = try await drive.getJSON(indexID) }
            var out = index()
            for part in ["items", "folders", "blobs"] {
                var ours = out[part] as? [String: Any] ?? [:]
                let was = read[part] as? [String: Any] ?? [:], began = mineWas[part] as? [String: Any] ?? [:]
                for (key, value) in latest[part] as? [String: Any] ?? [:] where !same(value, was[key]) && same(ours[key], began[key]) {
                    ours[key] = value
                    if part == "items" { items[key] = Ref(value as? [String: Any] ?? [:]) }
                    if part == "blobs", let id = value as? String { names[key] = id }
                }
                out[part] = ours
            }
            if num((latest["meta"] as? [String: Any])?["ts"]) > num((out["meta"] as? [String: Any])?["ts"]) { out["meta"] = latest["meta"] }
            indexID = try await drive.putJSON(indexName, out, parent: rootID, fileID: indexID)
            state["index"] = indexID
            cloud = out
            read = out
            mineWas = out
            mended = false
        }

        func abspath(_ rel: String) -> URL {
            rel.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
        }
        func now() -> Double { Date().timeIntervalSince1970 }

        // What is on this device: id -> (file, relative path, in trash?).
        let skipPaths = Set(skip.map { $0.standardizedFileURL.path })
        var skipIDs = Set<String>()
        var local: [String: Local] = [:]
        let (files, _) = scan(root)
        var found = files.sorted { $0.key < $1.key }.map { Local(url: $0.value, rel: $0.key, inTrash: false) }
        let trashNames = ((try? fm.contentsOfDirectory(atPath: trashDir.path)) ?? []).filter { $0.hasSuffix(notebookExt) }.sorted()
        found += trashNames.map { Local(url: trashDir.appendingPathComponent($0), rel: $0, inTrash: true) }
        let onlyPaths = only.map { Set($0.map { $0.standardizedFileURL.path }) }
        // A notebook that has not been written since the last sync is known by its place: it is
        // not opened to be asked who it is. This device's record of the last sync is the list of
        // what has been edited: whatever is not in it as it is now.
        var sameAs: [String: (String, String?)] = [:]
        for (nid, e) in known {
            sameAs["\(e["trashed"] as? Bool ?? false)/\(e["path"] as? String ?? "")"] = (nid, e["stat"] as? String)
        }
        var unwritten = Set<String>()
        for entry in found {
            var here = entry
            if let onlyPaths, !onlyPaths.contains(here.url.standardizedFileURL.path) { continue }
            var nid: String
            if let (was, stat) = sameAs["\(here.inTrash)/\(here.rel)"], let stat, stat == fileSign(here.url), local[was] == nil {
                nid = was
                unwritten.insert(nid)
            } else {
                guard let asked = try? Notebook.id(of: here.url) else { continue }   // not a readable notebook; leave it alone
                nid = asked
            }
            if skipPaths.contains(here.url.standardizedFileURL.path) {
                skipIDs.insert(nid)
                continue
            }
            if let other = local[nid] {
                // A copy made outside the app shares its original's id; make it a notebook of its own.
                // The original is the one still where the last sync left it, whichever was met first.
                let was = known[nid]?["path"] as? String
                if here.rel == was && other.rel != was {
                    local[nid] = here
                    here = other
                }
                nid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                try Notebook.setID(here.url, nid)
            }
            if local[nid] != nil { unwritten.remove(nid) }   // two files with one id: both are looked at
            local[nid] = here
        }

        /// Move a local notebook to where the index says it belongs.
        func place(_ nid: String, _ rel: String, _ inTrash: Bool) throws {
            let path = local[nid]!.url
            var target = inTrash ? trashDir.appendingPathComponent((rel as NSString).lastPathComponent) : abspath(rel)
            if target.standardizedFileURL.path != path.standardizedFileURL.path {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                target = unique(target)
                try fm.moveItem(at: path, to: target)
            }
            local[nid] = Local(url: target, rel: inTrash ? target.lastPathComponent : relPath(target, root), inTrash: inTrash)
        }

        /// (what stands for the content, fileSign()) of a notebook here. No notebook is read
        /// through for this: one that has not been written since the last sync is what it was
        /// then, and one that has been written is another. (Only a record from before the time
        /// of writing was kept gives nothing to go by; then the checksum is worked out, once.)
        func localMD5(_ nid: String, _ url: URL) throws -> (String, String) {
            let was = known[nid], stat = fileSign(url) ?? ""
            if let sum = was?["local"] as? String, !sum.isEmpty, was?["stat"] as? String == stat { return (sum, stat) }
            if let before = was?["stat"] as? String, !before.isEmpty { return ("written " + stat, stat) }
            return (try md5(url), stat)
        }

        /// Upload a local notebook's content and record it in the index entry.
        func push(_ nid: String, _ entry: Ref) async throws {
            let here = local[nid]!
            let slimmed = workDir.appendingPathComponent("upload")
            let (stat, blobs, found) = try slim(here.url, to: slimmed, seen: known[nid]?["blobs"] as? [String: Any]) { names[$0] != nil }
            blobsSeen[nid] = found
            for (name, part) in blobs.sorted(by: { $0.key < $1.key }) {
                // Each of these is uploaded once, whatever is written in the notebook afterwards.
                let (blobID, arrived) = try await drive.upload(part, name: name, parent: rootID, fileID: nil)
                if let arrived, try arrived != md5(part) {
                    throw DriveError(tr("上传的 PDF 或图片在云端的校验值不对，请再同步一次"))   // and it is not listed
                }
                names[name] = blobID
                try? fm.removeItem(at: part)
            }
            let (fileID, sum) = try await drive.upload(slimmed, name: (here.rel as NSString).lastPathComponent,
                                                       parent: rootID, fileID: entry.file)
            // What arrived is what was sent: only then is it written down in the index.
            let sentSum = try md5(slimmed)
            if let sum, sum != sentSum { throw DriveError(tr("上传的笔记本在云端的校验值不对，请再同步一次")) }
            let theirs = sum ?? sentSum
            try? fm.removeItem(at: slimmed)
            agreed[nid] = ("written " + stat, stat)
            cloud["format"] = format
            entry.d["file"] = fileID
            entry.d["md5"] = theirs
            entry.d["path"] = here.rel
            entry.d["trashed"] = here.inTrash
            entry.d["deleted"] = false
            entry.d["ts"] = now()
            summary.up += 1
            sent.insert(nid)
        }

        /// Make a notebook and the cloud's version of it the same, losing nothing of either.
        func settle(_ nid: String, _ entry: Ref, _ before: [String: Any]?) async throws {
            let path = local[nid]!.url
            // What both sides last agreed on: the cloud's file, and the one here that matched it.
            // (They are not the same file: the cloud's is without the notebook's PDFs and pictures.)
            var base = before?["md5"] as? String
            var baseLocal = (before?["local"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? base
            var mineSent = before?["sent"] as? Bool ?? false    // ...which this device had written
            for _ in 0..<5 {
                let (mine, stat) = try localMD5(nid, path)
                let localSame = baseLocal != nil && mine == baseLocal
                let cloudSame = base != nil && entry.md5 == base
                if mine == entry.md5 || (localSame && cloudSame) {
                    let listed = (before?["blobs"] as? [String: Any] ?? [:]).values.compactMap { ($0 as? [Any])?.last as? String }
                    if thorough, listed.contains(where: { names[$0] == nil }) {
                        try await push(nid, entry)   // a PDF or picture of it is gone from Drive: it is sent again
                        return
                    }
                    if agreed[nid] == nil { agreed[nid] = (mine, stat) }
                    return
                }
                guard let file = entry.file else {
                    try await push(nid, entry)
                    return
                }
                if cloudSame {
                    // Only this device has changed it, as far as the index says. A thorough sync
                    // asks Drive once more, in case another device sent its version this very
                    // moment; a quick one takes the index at its word. (Should two devices cross
                    // all the same, nothing is lost: the one written over sees at its next sync
                    // that the cloud's version is not its own, and merges its edits back in.)
                    let now = thorough ? try await drive.md5(file) : nil
                    if now == nil || now == base {
                        try await push(nid, entry)
                        return
                    }
                    entry.d["md5"] = now
                    continue
                }
                // Aside, so that nothing half done is left by the notebook.
                let theirs = workDir.appendingPathComponent("theirs")
                try await drive.download(file, to: theirs)
                entry.d["md5"] = try md5(theirs)
                try await fatten(theirs, have: path, seen: known[nid]?["blobs"] as? [String: Any], fetch: fetch)
                let taken: Bool = try fileLock.withLock {
                    let untouched = localSame && fileSign(path) == stat
                    var replace = untouched && !mineSent   // nothing here that the cloud's version lacks
                    if !replace {
                        do {
                            let hereDoc = try Document.load(path), theirDoc = try Document.load(theirs)
                            if untouched {
                                // The cloud's version ought to be a later one of what this device sent.
                                // If another device wrote over that without having seen it, it is not;
                                // then what was written here is put back into it.
                                if merge(theirDoc, hereDoc) == (0, 0, 0, 0, 0) {
                                    replace = true
                                } else {
                                    try theirDoc.save(to: path)
                                }
                            } else {
                                // Edited on both sides: merge the two, item by item.
                                merge(hereDoc, theirDoc)
                                try hereDoc.save(to: path)
                            }
                            if !replace {
                                try? fm.removeItem(at: theirs)
                                summary.merged += 1
                            }
                        } catch {
                            // Only if merging is not possible is the remote version kept as a notebook
                            // of its own.
                            let stem = path.deletingPathExtension().lastPathComponent + tr("（云端副本）") + notebookExt
                            let copy = unique(path.deletingLastPathComponent().appendingPathComponent(stem))
                            try fm.moveItem(at: theirs, to: copy)
                            try? Notebook.setID(copy, UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
                            summary.conflicts += 1
                        }
                    }
                    if replace {
                        _ = try fm.replaceItemAt(path, withItemAt: theirs)
                        let stat = fileSign(path) ?? ""
                        agreed[nid] = ("written " + stat, stat)
                        summary.down += 1
                    }
                    return replace
                }
                if taken { return }
                // What is here now has all of that version in it, and more.
                base = entry.md5
                baseLocal = nil
                mineSent = false
            }
            throw DriveError(trf("“%s”在同步时一直被其它设备更改，请稍后再同步", path.lastPathComponent))
        }

        let ids = only == nil ? Set(local.keys).union(items.keys).union(known.keys).sorted() : local.keys.sorted()
        let steps = Double(ids.count + 2)
        var unmended: [(String, String)] = []   // notebooks here that lack their PDFs and could not be given them back
        for (n, nid) in ids.enumerated() {
            try Task.checkCancellation()
            let here = local[nid], before = known[nid]
            var entry = items[nid]
            let name = ((here?.rel ?? entry?.path ?? "") as NSString).lastPathComponent
            report(Double(n + 1) / steps, name)
            // A transfer moves the bar smoothly through this notebook's step.
            drive.onBytes = { got, total in
                if total > 0 { report((Double(n + 1) + Double(got) / Double(total)) / steps, name) }
            }
            if skipIDs.contains(nid) { continue }
            if let here, !unwritten.contains(nid), stripped(here.url) {
                // A notebook here without its PDFs and pictures (see stripped). They are fetched
                // and it is made whole before anything else is done with it; while that is not
                // possible it is left exactly as it is, and above all not uploaded.
                do {
                    let mending = workDir.appendingPathComponent("mending")
                    try? fm.removeItem(at: mending)
                    try fm.copyItem(at: here.url, to: mending)
                    try await fatten(mending, have: nil, fetch: fetch)
                    try fileLock.withLock { _ = try fm.replaceItemAt(here.url, withItemAt: mending) }
                    summary.mended += 1
                } catch let error as DriveError {
                    unmended.append((name, error.message))
                    continue
                }
            }
            let beforeMD5 = before?["md5"] as? String
            if here == nil && entry == nil {
                known[nid] = nil
                continue
            }
            if entry == nil, let here {
                // New on this device. Something already in the trash is not worth sending.
                if here.inTrash { continue }
                entry = Ref()
                items[nid] = entry
                try await push(nid, entry!)
            } else if here == nil, let entry {
                if entry.deleted {
                    known[nid] = nil
                    continue
                }
                if before != nil && entry.md5 == beforeMD5 {
                    // Gone from this device and untouched elsewhere: leave a tombstone. The file
                    // itself stays on Drive, so a deletion can always be recovered from there.
                    entry.d["deleted"] = true
                    entry.d["ts"] = now()
                    known[nid] = nil
                    summary.removed += 1
                    continue
                }
                if entry.trashed && before == nil { continue }   // sitting in another device's trash; no need to fetch it
                guard let path = entry.path, let file = entry.file else { continue }
                var target = entry.trashed ? trashDir.appendingPathComponent((path as NSString).lastPathComponent) : abspath(path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                target = unique(target)
                // Put together aside, and moved into the library only when it is whole: a download
                // that is cut off leaves nothing there.
                let coming = workDir.appendingPathComponent("coming")
                try await drive.download(file, to: coming)
                try await fatten(coming, have: nil, fetch: fetch)
                try fm.moveItem(at: coming, to: target)
                let stat = fileSign(target) ?? ""
                agreed[nid] = ("written " + stat, stat)
                local[nid] = Local(url: target, rel: entry.trashed ? target.lastPathComponent : relPath(target, root), inTrash: entry.trashed)
                summary.down += 1
            } else if let here, let entry {
                let mine = try localMD5(nid, here.url).0
                let wasLocal = (before?["local"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? beforeMD5
                let unchanged = before != nil && mine == wasLocal
                var content = true
                if entry.deleted {
                    if here.inTrash || unchanged {
                        // Deleted elsewhere and not edited here since: follow, into the trash.
                        try place(nid, here.rel, true)
                        known[nid] = nil
                        if !here.inTrash { summary.removed += 1 }
                        continue
                    }
                    try await push(nid, entry)   // edited after the deletion: the edit wins
                    content = false
                }
                if content {
                    try await settle(nid, entry, before)
                }
                // Name, folder and trash state travel separately from the content.
                let therePath = entry.path, thereTrash = entry.trashed
                if here.rel != therePath || here.inTrash != thereTrash {
                    if let before, here.rel == before["path"] as? String, here.inTrash == (before["trashed"] as? Bool ?? false),
                       let therePath {
                        try place(nid, therePath, thereTrash)
                    } else {
                        let mineName = (here.rel as NSString).lastPathComponent
                        if let file = entry.file, mineName != ((therePath ?? "") as NSString).lastPathComponent {
                            try await drive.rename(file, mineName)
                        }
                        entry.d["path"] = here.rel
                        entry.d["trashed"] = here.inTrash
                        entry.d["ts"] = now()
                    }
                    summary.moved += 1
                }
            }
            guard let at = local[nid], let entry = items[nid] else { continue }
            entry.d["path"] = at.rel
            entry.d["trashed"] = at.inTrash
            let was = known[nid]
            known[nid] = ["path": at.rel, "trashed": at.inTrash, "md5": entry.md5 ?? ""]
            if let (sum, stat) = agreed[nid] {
                known[nid]?["local"] = sum
                known[nid]?["stat"] = stat
            } else if let sum = was?["local"] as? String, was?["md5"] as? String == entry.md5 {
                known[nid]?["local"] = sum
            }
            if let found = blobsSeen[nid] {
                known[nid]?["blobs"] = found
            } else if let found = was?["blobs"] {
                known[nid]?["blobs"] = found
            }
            if sent.contains(nid) || (was?["sent"] as? Bool == true && was?["md5"] as? String == entry.md5) {
                known[nid]?["sent"] = true   // the cloud's version is the one this device wrote
            }
            if summary.up + summary.down != moved {
                moved = summary.up + summary.down
                // Write down, in the cloud and here, what has been done so far, so that a sync
                // that is cut off goes on from there the next time.
                if Date().timeIntervalSince(savedAt) >= checkpoint {
                    try await publish()
                    state["items"] = known
                    try saveJSON(statePath, state)
                    savedAt = Date()
                }
            }
        }

        drive.onBytes = nil
        try? fm.removeItem(at: workDir)
        if only != nil {
            try await publish()
            state["items"] = known
            try saveJSON(statePath, state)
            report(1, "")
            return summary
        }
        report((steps - 1) / steps, tr("正在更新云端目录…"))
        // Folders, so that empty ones and their removal carry over too.
        var folders = cloud["folders"] as? [String: Any] ?? [:]   // relative path -> deleted?
        let seen = Set(state["folders"] as? [String] ?? [])
        var (_, localDirs) = scan(root)
        for rel in localDirs.sorted(by: { $0.count > $1.count }) {
            let visible = ((try? fm.contentsOfDirectory(atPath: abspath(rel).path)) ?? []).filter { $0 != ".DS_Store" }
            if folders[rel] as? Bool == true && seen.contains(rel) && visible.isEmpty {
                try? fm.removeItem(at: abspath(rel))
                localDirs.remove(rel)
            } else {
                folders[rel] = false
            }
        }
        for rel in folders.keys.sorted() where folders[rel] as? Bool != true && !localDirs.contains(rel) {
            if seen.contains(rel) {
                folders[rel] = true
            } else {
                try? fm.createDirectory(at: abspath(rel), withIntermediateDirectories: true)
                localDirs.insert(rel)
            }
        }
        state["folders"] = localDirs.sorted()

        // Favourites and folder styles: the newer copy wins as a whole.
        let metaPath = root.appendingPathComponent(".library.json")
        var meta = loadJSON(metaPath)
        let theirs = cloud["meta"] as? [String: Any]
        let mineTS = num(meta["ts"]), theirTS = num(theirs?["ts"])
        if let theirs, theirTS > mineTS {
            for key in ["favorites", "folders"] where theirs[key] != nil && !(theirs[key] is NSNull) { meta[key] = theirs[key] }
            meta["ts"] = theirTS
            try saveJSON(metaPath, meta)
            summary.meta = true
        } else if mineTS > theirTS {
            var shared: [String: Any] = ["ts": mineTS]
            for key in ["favorites", "folders"] { shared[key] = meta[key] ?? NSNull() }
            cloud["meta"] = shared
        }

        cloud["folders"] = folders
        try await publish()
        state["items"] = known
        state["last"] = now()
        try saveJSON(statePath, state)
        report(1, "")
        if let (name, why) = unmended.first {
            throw DriveError(trf("“%s”缺少它的 PDF 或图片，暂时无法补全：%s", name, why))
        }
        return summary
    }
}
