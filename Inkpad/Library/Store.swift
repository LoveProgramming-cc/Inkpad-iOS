import UIKit

/// A notebook or a folder in the library.
struct Entry: Identifiable, Hashable {
    let url: URL
    let isDir: Bool
    let name: String
    let mtime: Date

    var id: String { url.path }

    init(_ url: URL) {
        self.url = url
        var dir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &dir)
        isDir = dir.boolValue
        name = isDir ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

let folderColors = [RGB(0.49, 0.74, 0.99), RGB(0.36, 0.80, 0.82), RGB(0.47, 0.80, 0.52), RGB(0.98, 0.82, 0.38),
                    RGB(0.99, 0.62, 0.42), RGB(0.96, 0.52, 0.56), RGB(0.76, 0.62, 0.95), RGB(0.68, 0.70, 0.74)]

/// The library folder: notebooks, folders, a trash, and the shared favourites and folder
/// styles. The layout on disk is the desktop app's, which is what the sync works on.
final class Store {
    let root: URL
    let trashDir: URL
    let archiveDir: URL   // things deleted "for good" are kept here until the cache is cleared
    private let metaURL: URL
    private(set) var meta: [String: Any] = [:]
    private let fm = FileManager.default

    init(root: URL? = nil) {
        let base = root ?? Platform.libraryRoot
        self.root = base.standardizedFileURL
        trashDir = self.root.appendingPathComponent(".trash", isDirectory: true)
        archiveDir = self.root.appendingPathComponent(".deleted", isDirectory: true)
        metaURL = self.root.appendingPathComponent(".library.json")
        try? fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        reloadMeta()
    }

    /// Pick up favourites and folder styles that a sync brought in.
    func reloadMeta() {
        if let data = try? Data(contentsOf: metaURL), let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            meta.merge(m) { _, new in new }
        }
        if meta["favorites"] == nil { meta["favorites"] = [String]() }
        if meta["trashed"] == nil { meta["trashed"] = [String: String]() }     // trash name -> folder it came from
        if meta["folders"] == nil { meta["folders"] = [String: Any]() }        // folder -> {'color': [r, g, b], 'icon': name}
    }

    private func saveMeta() {
        meta["ts"] = Date().timeIntervalSince1970
        if let data = try? JSONSerialization.data(withJSONObject: meta) { try? data.write(to: metaURL, options: .atomic) }
    }

    private var favoritesList: [String] {
        get { meta["favorites"] as? [String] ?? [] }
        set { meta["favorites"] = newValue }
    }

    private var trashedMap: [String: String] {
        get { meta["trashed"] as? [String: String] ?? [:] }
        set { meta["trashed"] = newValue }
    }

    private var styles: [String: Any] {
        get { meta["folders"] as? [String: Any] ?? [:] }
        set { meta["folders"] = newValue }
    }

    func rel(_ url: URL) -> String {
        let path = url.standardizedFileURL.path, base = root.path
        if path == base { return "." }
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }

    func contains(_ url: URL) -> Bool { url.standardizedFileURL.path.hasPrefix(root.path + "/") }

    func entries(_ folder: URL) -> [Entry] {
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])) ?? []
        return urls.compactMap { url in
            let name = url.lastPathComponent
            if name.hasPrefix(".") { return nil }
            let entry = Entry(url)
            return entry.isDir || name.hasSuffix(notebookExt) ? entry : nil
        }
    }

    func favorites() -> [Entry] {
        favoritesList.map { root.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }.map { Entry($0) }
    }

    func isFavorite(_ url: URL) -> Bool { favoritesList.contains(rel(url)) }

    func toggleFavorite(_ url: URL) {
        let r = rel(url)
        var favs = favoritesList
        if let i = favs.firstIndex(of: r) { favs.remove(at: i) } else { favs.append(r) }
        favoritesList = favs
        saveMeta()
    }

    func folderStyle(_ url: URL) -> (RGB, String) {
        let style = styles[rel(url)] as? [String: Any] ?? [:]
        return (RGB(json: style["color"], default: folderColors[0]), style["icon"] as? String ?? "")
    }

    func setFolderStyle(_ url: URL, color: RGB? = nil, icon: String? = nil) {
        var all = styles
        var style = all[rel(url)] as? [String: Any] ?? [:]
        if let color { style["color"] = color.list }
        if let icon { style["icon"] = icon }
        all[rel(url)] = style
        styles = all
        saveMeta()
    }

    /// Every folder in the library as a tree read downwards: the root, then each folder
    /// followed at once by everything inside it.
    func folders() -> [URL] {
        var out = [root]
        func walk(_ dir: URL) {
            let subs = entries(dir).filter(\.isDir).sorted { $0.name.lowercased() < $1.name.lowercased() }
            for sub in subs {
                out.append(sub.url)
                walk(sub.url)
            }
        }
        walk(root)
        return out
    }

    static func unique(_ folder: URL, _ name: String, _ ext: String = "") -> URL {
        var url = folder.appendingPathComponent(name + ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n)\(ext)")
            n += 1
        }
        return url
    }

    private func split(_ url: URL) -> (String, String) {
        let entry = Entry(url)
        return entry.isDir ? (url.lastPathComponent, "") : (entry.name, notebookExt)
    }

    @discardableResult
    func newNotebook(_ folder: URL, _ template: PageTemplate, name: String? = nil, cover: (String, RGB)? = nil) throws -> URL {
        let fallback = template.board ? tr("未命名白板") : tr("未命名笔记")
        let clean = (name ?? "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        let url = Self.unique(folder, clean.isEmpty ? fallback : clean, notebookExt)
        let doc = Document(template: template)
        doc.coverSpec = cover
        try doc.save(to: url)
        return url
    }

    @discardableResult
    func importPDF(_ folder: URL, name: String, data: Data) throws -> URL {
        let url = Self.unique(folder, name.replacingOccurrences(of: "/", with: "-"), notebookExt)
        try Document.fromPDF(data).save(to: url)
        return url
    }

    /// Turn a .goodnotes file into a notebook; returns it and what was read.
    func importGoodnotes(_ folder: URL, source: URL) throws -> (URL, Goodnotes.Stats) {
        let (doc, title, stats) = try Goodnotes.load(source)
        let url = Self.unique(folder, title.replacingOccurrences(of: "/", with: "-"), notebookExt)
        try doc.save(to: url)
        return (url, stats)
    }

    /// Import every Goodnotes document, PDF and Inkpad notebook under a folder, keeping its
    /// folder structure. Returns how many were imported and which files failed, with why.
    static func importTree(_ source: URL, into folder: URL, progress: ((Double, String) -> Void)? = nil) throws -> (Int, [(String, String)]) {
        let fm = FileManager.default
        var found: [(URL, String)] = []
        func walk(_ dir: URL, _ rel: String) {
            let list = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let isDir = { (url: URL) in (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
            for url in list where !isDir(url) {
                let name = url.lastPathComponent.lowercased()
                if name.hasSuffix(".goodnotes") || name.hasSuffix(".pdf") || name.hasSuffix(notebookExt) {
                    found.append((url, rel.isEmpty ? url.lastPathComponent : rel + "/" + url.lastPathComponent))
                }
            }
            for url in list where isDir(url) { walk(url, rel.isEmpty ? url.lastPathComponent : rel + "/" + url.lastPathComponent) }
        }
        walk(source, "")
        let name = source.standardizedFileURL.lastPathComponent
        let top = unique(folder, name.isEmpty || name == "/" ? tr("导入") : name)
        var done = 0
        var failed: [(String, String)] = []
        for (n, (url, rel)) in found.enumerated() {
            progress?(Double(n) / Double(found.count), rel)
            let target = rel.split(separator: "/").dropLast().reduce(top) { $0.appendingPathComponent(String($1)) }
            let stem = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "/", with: "-")
            do {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                switch url.pathExtension.lowercased() {
                case "goodnotes":
                    try Goodnotes.load(url).0.save(to: unique(target, stem, notebookExt))
                case "pdf":
                    try Document.fromPDF(Data(contentsOf: url)).save(to: unique(target, stem, notebookExt))
                default:
                    let new = unique(target, stem, notebookExt)
                    try fm.copyItem(at: url, to: new)
                    try Notebook.setID(new, UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
                }
                done += 1
            } catch {
                failed.append((rel, error.localizedDescription))
            }
        }
        progress?(1.0, "")
        return (done, failed)
    }

    /// Write the given notebooks and folders (with everything below them) into one zip file.
    @discardableResult
    func exportPaths(_ urls: [URL], to dest: URL) throws -> Int {
        var count = 0
        var kept: [String: Any] = [:]
        var used = Set<String>()
        let z = try ZipWriter(url: dest)
        do {
            func walk(_ dir: URL, _ inside: String) throws {
                try z.add(inside + "/", Data(), compress: false)
                if contains(dir), let style = styles[rel(dir)] { kept[inside] = style }
                let list = entries(dir).sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
                for entry in list where !entry.isDir {
                    try z.add(inside + "/" + entry.url.lastPathComponent, Data(contentsOf: entry.url, options: .mappedIfSafe), compress: false)
                    count += 1
                }
                for entry in list where entry.isDir { try walk(entry.url, inside + "/" + entry.url.lastPathComponent) }
            }
            for url in urls {
                var top = url.lastPathComponent
                var n = 2
                while used.contains(top) {   // two selected items may share a name (favourites, trash)
                    let ext = url.pathExtension
                    top = "\(url.deletingPathExtension().lastPathComponent) \(n)" + (ext.isEmpty ? "" : "." + ext)
                    n += 1
                }
                used.insert(top)
                var dir: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &dir)
                if dir.boolValue {
                    try walk(url, top)
                } else {
                    try z.add(top, Data(contentsOf: url, options: .mappedIfSafe), compress: false)
                    count += 1
                }
            }
            try z.add(Self.archiveMeta, JSONSerialization.data(withJSONObject: ["app": "Inkpad", "folders": kept]))
            try z.finish()
        } catch {
            z.abandon()
            throw error
        }
        return count
    }

    /// Copy a notebook file from outside into a folder of the library.
    @discardableResult
    func importNotebook(_ source: URL, into folder: URL) throws -> URL {
        let url = Self.unique(folder, source.deletingPathExtension().lastPathComponent, notebookExt)
        try fm.copyItem(at: source, to: url)
        return url
    }

    @discardableResult
    func newFolder(_ folder: URL, _ name: String) throws -> URL {
        let clean = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        let url = Self.unique(folder, clean.isEmpty ? tr("新文件夹") : clean)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Keep favourites pointing at an item (and what is inside it) after a move.
    private func moved(_ old: URL, _ new: URL) {
        let oldRel = rel(old), newRel = rel(new)
        favoritesList = favoritesList.map { $0 == oldRel || $0.hasPrefix(oldRel + "/") ? newRel + $0.dropFirst(oldRel.count) : $0 }
        var all = styles
        for key in all.keys where key == oldRel || key.hasPrefix(oldRel + "/") {
            all[newRel + key.dropFirst(oldRel.count)] = all.removeValue(forKey: key)
        }
        styles = all
        saveMeta()
    }

    @discardableResult
    func rename(_ url: URL, _ name: String) throws -> URL {
        let clean = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        let (old, ext) = split(url)
        if clean.isEmpty || clean == old { return url }
        let new = Self.unique(url.deletingLastPathComponent(), clean, ext)
        try fm.moveItem(at: url, to: new)
        moved(url, new)
        return new
    }

    @discardableResult
    /// Move an item into a folder, under another name if one is given (as when a move is
    /// undone and it gets back the name it had). Returns where it is now.
    func move(_ url: URL, to folder: URL, name: String? = nil) throws -> URL {
        let (old, ext) = split(url)
        let name = name ?? old
        if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL && name == old { return url }
        let from = url.standardizedFileURL.path, to = folder.standardizedFileURL.path
        if to == from || to.hasPrefix(from + "/") { throw Goodnotes.Failure(tr("文件夹不能移动到它自己里面")) }
        let new = Self.unique(folder, name, ext)
        try fm.moveItem(at: url, to: new)
        moved(url, new)
        return new
    }

    func trash(_ url: URL) throws {
        let (name, ext) = split(url)
        let new = Self.unique(trashDir, name, ext)
        let r = rel(url)
        favoritesList = favoritesList.filter { $0 != r && !$0.hasPrefix(r + "/") }
        var map = trashedMap
        map[new.lastPathComponent] = rel(url.deletingLastPathComponent())
        trashedMap = map
        try fm.moveItem(at: url, to: new)
        saveMeta()
    }

    func trashed() -> [Entry] { entries(trashDir) }

    func restore(_ url: URL) throws {
        var map = trashedMap
        let origin = map.removeValue(forKey: url.lastPathComponent) ?? "."
        trashedMap = map
        var folder = origin == "." ? root : root.appendingPathComponent(origin).standardizedFileURL
        var dir: ObjCBool = false
        if !(fm.fileExists(atPath: folder.path, isDirectory: &dir) && dir.boolValue) || !(folder == root || contains(folder)) {
            folder = root
        }
        let (name, ext) = split(url)
        try fm.moveItem(at: url, to: Self.unique(folder, name, ext))
        saveMeta()
    }

    /// Remove something from the trash. It is kept out of sight until the cache is cleared.
    func delete(_ url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == trashDir.standardizedFileURL else {
            throw ZipError("only trashed items can be deleted")
        }
        try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        let (name, ext) = split(url)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss "
        let kept = Self.unique(archiveDir, stamp.string(from: Date()) + name, ext)
        try fm.moveItem(at: url, to: kept)
        // Where it lived before the trash, so that it can be put back there.
        var map = trashedMap
        var archived = meta["archived"] as? [String: String] ?? [:]
        archived[kept.lastPathComponent] = map.removeValue(forKey: url.lastPathComponent) ?? "."
        meta["archived"] = archived
        trashedMap = map
        saveMeta()
    }

    /// A copy next to the original. Copies are notebooks of their own, with new ids.
    @discardableResult
    func duplicate(_ url: URL) throws -> URL {
        let (name, ext) = split(url)
        let new = Self.unique(url.deletingLastPathComponent(), name + tr(" 副本"), ext)
        try fm.copyItem(at: url, to: new)
        var books = [new]
        if ext.isEmpty {
            books = (fm.enumerator(at: new, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { $0.lastPathComponent.hasSuffix(notebookExt) }
            if let style = styles[rel(url)] {
                var all = styles
                all[rel(new)] = style
                styles = all
                saveMeta()
            }
        }
        for book in books { try? Notebook.setID(book, UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()) }
        return new
    }

    /// Notebooks and folders anywhere in the library whose name contains query.
    func find(_ query: String) -> [Entry] {
        let q = query.lowercased()
        var out: [Entry] = []
        func walk(_ dir: URL) {
            for entry in entries(dir) {
                if entry.name.lowercased().contains(q) { out.append(entry) }
                if entry.isDir { walk(entry.url) }
            }
        }
        walk(root)
        return out
    }

    /// What was deleted for good and is still kept on this device.
    func archived() -> [Entry] { entries(archiveDir) }

    /// The folder (relative to the library) a deleted item would be restored to.
    func archivedOrigin(_ url: URL) -> String {
        (meta["archived"] as? [String: String])?[url.lastPathComponent] ?? "."
    }

    /// Deleted items carry a date prefix ("20261007-164500 name") so they never collide.
    static func archivedName(_ name: String) -> String {
        let parts = name.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, parts[0].count == 15, parts[0].prefix(8).allSatisfy(\.isNumber) { return String(parts[1]) }
        return name
    }

    /// Bring a permanently deleted item back to the folder it was in (recreated if need be).
    @discardableResult
    func unarchive(_ url: URL) throws -> URL {
        var map = meta["archived"] as? [String: String] ?? [:]
        let origin = map.removeValue(forKey: url.lastPathComponent) ?? "."
        meta["archived"] = map
        var folder = origin == "." || origin.isEmpty ? root : root.appendingPathComponent(origin).standardizedFileURL
        if !(folder == root || contains(folder)) { folder = root }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let (name, ext) = split(url)
        let new = Self.unique(folder, Self.archivedName(name), ext)
        try fm.moveItem(at: url, to: new)
        saveMeta()
        return new
    }

    static let archiveMeta = "inkpad-library.json"

    /// Write a folder (or the whole library) with everything below it into one zip file.
    @discardableResult
    func exportArchive(_ folder: URL, to dest: URL) throws -> Int {
        var count = 0
        var kept: [String: Any] = [:]
        let z = try ZipWriter(url: dest)
        do {
            func walk(_ dir: URL, _ rel: String) throws {
                if !rel.isEmpty {
                    try z.add(rel + "/", Data(), compress: false)
                    if let style = styles[self.rel(dir)] { kept[rel] = style }
                }
                let list = entries(dir).sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
                for entry in list where !entry.isDir {
                    let name = entry.url.lastPathComponent
                    try z.add(rel.isEmpty ? name : rel + "/" + name, Data(contentsOf: entry.url, options: .mappedIfSafe), compress: false)
                    count += 1
                }
                for entry in list where entry.isDir {
                    try walk(entry.url, rel.isEmpty ? entry.url.lastPathComponent : rel + "/" + entry.url.lastPathComponent)
                }
            }
            try walk(folder, "")
            try z.add(Self.archiveMeta, JSONSerialization.data(withJSONObject: ["app": "Inkpad", "folders": kept]))
            try z.finish()
        } catch {
            z.abandon()
            throw error
        }
        return count
    }

    /// Unpack an exported zip into folder. Existing notebooks are never overwritten.
    @discardableResult
    func importArchive(_ src: URL, into folder: URL) throws -> Int {
        let z = try ZipReader(url: src)
        var count = 0
        var kept: [String: Any] = [:]
        if let data = try? z.read(Self.archiveMeta), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            kept = json["folders"] as? [String: Any] ?? [:]
        }
        for name in z.names {
            let parts = name.split(separator: "/").map(String.init)
            if parts.isEmpty || name.hasPrefix("/") || parts.contains(where: { $0 == "." || $0 == ".." || $0.hasPrefix(".") }) { continue }
            if name.hasSuffix("/") {
                try fm.createDirectory(at: parts.reduce(folder) { $0.appendingPathComponent($1) }, withIntermediateDirectories: true)
            } else if name.hasSuffix(notebookExt) {
                let dir = parts.dropLast().reduce(folder) { $0.appendingPathComponent($1) }
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let target = Self.unique(dir, String(parts.last!.dropLast(notebookExt.count)), notebookExt)
                try z.read(name).write(to: target, options: .atomic)
                count += 1
            }
        }
        var all = styles
        for (rel, style) in kept {
            let url = rel.split(separator: "/").reduce(folder) { $0.appendingPathComponent(String($1)) }
            var dir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &dir), dir.boolValue, contains(url), all[self.rel(url)] == nil, style is [String: Any] {
                all[self.rel(url)] = style
            }
        }
        styles = all
        saveMeta()
        return count
    }

    func cacheSize() -> Int {
        var total = 0
        for case let url as URL in fm.enumerator(at: archiveDir, includingPropertiesForKeys: [.fileSizeKey])?.allObjects ?? [] {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    /// Really delete what was deleted before. Nothing in the cloud is touched.
    func clearCache() {
        try? fm.removeItem(at: archiveDir)
        meta["archived"] = [String: String]()
        saveMeta()
    }
}
