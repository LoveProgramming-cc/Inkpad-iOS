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
    static func cloudFolder(_ state: inout [String: Any], _ drive: DriveAPI, wanted: String) async throws -> String {
        if (state["folder_set"] as? String ?? "") != wanted {
            state = ["folder_set": wanted]
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
            try await drive.download(file, to: target)
            let now = relPath(target, root)
            // It is a live notebook again, on both sides, with what the cloud holds.
            entry["deleted"] = false
            entry["trashed"] = false
            entry["path"] = now
            entry["ts"] = Date().timeIntervalSince1970
            items[nid] = entry
            known[nid] = ["path": now, "trashed": false, "md5": entry["md5"] as? String ?? ""]
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
    static func sync(root: URL, drive: DriveAPI, skip: [URL] = [], folder: String = "", progress: ((Double, String) -> Void)? = nil) async throws -> SyncSummary {
        let fm = FileManager.default
        let root = root.standardizedFileURL
        let report = progress ?? { _, _ in }
        report(0, tr("正在读取云端目录…"))
        let statePath = root.appendingPathComponent(".sync.json")
        var state = loadJSON(statePath)
        // What was remembered about the cloud is checked against what is really there: the folder
        // may be another one now, or have been deleted on Drive, and so may any of the files in it.
        let rootID = try await cloudFolder(&state, drive, wanted: folder)
        // id -> {'path', 'trashed', 'md5'} when both sides last agreed
        var known = state["items"] as? [String: [String: Any]] ?? [:]
        let trashDir = root.appendingPathComponent(".trash", isDirectory: true)
        try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        var summary = SyncSummary()

        let inFolder = try await drive.children(rootID)
        let live = Set(inFolder.map(\.id))
        var indexID = state["index"] as? String
        if indexID == nil || !live.contains(indexID!) { indexID = inFolder.first { $0.name == indexName }?.id }
        var cloud: [String: Any] = [:]
        if let indexID { cloud = try await drive.getJSON(indexID) }
        // id -> {'path', 'trashed', 'md5', 'file', 'deleted', 'ts'}
        var items: [String: Ref] = [:]
        for (nid, value) in cloud["items"] as? [String: Any] ?? [:] { items[nid] = Ref(value as? [String: Any] ?? [:]) }
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
            // The file itself says what is in it. The index may be behind: a device that was cut
            // off after an upload never got to write it down.
            if let file = entry.file, let md5 = actual[file] { entry.d["md5"] = md5 }
        }
        /// The index as this sync has it now.
        func index() -> [String: Any] {
            var out = cloud
            out["items"] = items.mapValues { $0.d }
            return out
        }
        var read = cloud          // the index as it was read, to tell later what others changed
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
            if indexID == nil { indexID = try await drive.find(indexName, parent: rootID) }
            var latest: [String: Any] = [:]
            if let indexID { latest = try await drive.getJSON(indexID) }
            var out = index()
            for part in ["items", "folders"] {
                var ours = out[part] as? [String: Any] ?? [:]
                let was = read[part] as? [String: Any] ?? [:], began = mineWas[part] as? [String: Any] ?? [:]
                for (key, value) in latest[part] as? [String: Any] ?? [:] where !same(value, was[key]) && same(ours[key], began[key]) {
                    ours[key] = value
                    if part == "items" { items[key] = Ref(value as? [String: Any] ?? [:]) }
                }
                out[part] = ours
            }
            if num((latest["meta"] as? [String: Any])?["ts"]) > num((out["meta"] as? [String: Any])?["ts"]) { out["meta"] = latest["meta"] }
            indexID = try await drive.putJSON(indexName, out, parent: rootID, fileID: indexID)
            state["index"] = indexID
            cloud = out
            read = out
            mineWas = out
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
        for entry in found {
            var here = entry
            guard var nid = try? Notebook.id(of: here.url) else { continue }   // not a readable notebook; leave it alone
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

        /// Upload a local notebook's content and record it in the index entry.
        func push(_ nid: String, _ entry: Ref, _ mine: String) async throws {
            let here = local[nid]!
            let (fileID, theirs) = try await drive.upload(here.url, name: (here.rel as NSString).lastPathComponent,
                                                          parent: rootID, fileID: entry.file)
            entry.d["file"] = fileID
            entry.d["md5"] = theirs ?? mine
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
            var base = before?["md5"] as? String                // what both sides last agreed on
            var mineSent = before?["sent"] as? Bool ?? false    // ...which this device had written
            for _ in 0..<5 {
                let mine = try md5(path)
                if mine == entry.md5 { return }
                guard let file = entry.file else {
                    try await push(nid, entry, mine)
                    return
                }
                if let base, entry.md5 == base {
                    // Only this device has changed it, as far as was known when the sync began.
                    // Another may have sent its own version since; uploading now would wipe that out.
                    let now = try await drive.md5(file)
                    if now == nil || now == base {
                        try await push(nid, entry, mine)
                        return
                    }
                    entry.d["md5"] = now
                    continue
                }
                let theirs = path.appendingPathExtension("theirs")
                try await drive.download(file, to: theirs)
                entry.d["md5"] = try md5(theirs)
                let taken: Bool = try fileLock.withLock {
                    let untouched = try base != nil && md5(path) == base
                    var replace = untouched && !mineSent   // nothing here that the cloud's version lacks
                    if !replace {
                        do {
                            let hereDoc = try Document.load(path), theirDoc = try Document.load(theirs)
                            if untouched {
                                // The cloud's version ought to be a later one of what this device sent.
                                // If another device wrote over that without having seen it, it is not;
                                // then what was written here is put back into it.
                                if merge(theirDoc, hereDoc) == (0, 0, 0, 0) {
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
                        summary.down += 1
                    }
                    return replace
                }
                if taken { return }
                base = entry.md5   // what is here now has all of that version in it
                mineSent = false
            }
            throw DriveError(trf("“%s”在同步时一直被其它设备更改，请稍后再同步", path.lastPathComponent))
        }

        let ids = Set(local.keys).union(items.keys).union(known.keys).sorted()
        let steps = Double(ids.count + 2)
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
                try await push(nid, entry!, md5(here.url))
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
                try await drive.download(file, to: target)
                local[nid] = Local(url: target, rel: entry.trashed ? target.lastPathComponent : relPath(target, root), inTrash: entry.trashed)
                summary.down += 1
            } else if let here, let entry {
                let mine = try md5(here.url)
                let unchanged = before != nil && mine == beforeMD5
                var content = true
                if entry.deleted {
                    if here.inTrash || unchanged {
                        // Deleted elsewhere and not edited here since: follow, into the trash.
                        try place(nid, here.rel, true)
                        known[nid] = nil
                        if !here.inTrash { summary.removed += 1 }
                        continue
                    }
                    try await push(nid, entry, mine)   // edited after the deletion: the edit wins
                    content = false
                }
                if content && mine != entry.md5 {
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
        return summary
    }
}
