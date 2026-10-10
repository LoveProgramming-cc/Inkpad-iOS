import UIKit
import CryptoKit

let goneLimit = 20000
let notebookExt = ".inkpad"

enum Action {
    case items(Page, removed: [(Int, Item)], added: [(Int, Item)])
    case pages(removed: [(Int, Page)], added: [(Int, Page)])
    case template(Page, old: PageTemplate, new: PageTemplate)
}

enum DocEvent {
    case added(Page, [Item])   // a pure append
    case dirty(Page, Box?)     // anything else on one page
    case pages                 // structure changes
    case meta                  // bookmarks and outline
    case state                 // the undo or saved state may have changed
}

/// Everything needed to write the file, as immutable data safe to hand to a thread.
struct Snapshot {
    let json: Data
    let pages: [(String, Data)]
    let pdfs: [Data]
    let images: [Data]
    let cover: Data
    let rev: Int
    let id: String
}

/// Held while a notebook file is compared with what is expected to be there and then replaced:
/// by an editor saving it, and by a sync putting another device's version in its place. Without
/// it either of the two could write over what the other had only just written.
let fileLock = NSRecursiveLock()

/// What tells one writing of a file from the next, or nil when there is no file.
func fileSign(_ url: URL) -> String? {
    guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]), let size = v.fileSize else { return nil }
    return "\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)/\(size)"
}

/// The file is no longer the one that the document was read from or last written to.
struct FileChanged: Error {}

func md5Hex(_ text: String) -> String {
    Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Pages plus an undo history.
final class Document {
    var pages: [Page]
    var url: URL?
    var rev = 0
    var savedRev = 0
    private(set) var undoStack: [Action] = []
    private(set) var redoStack: [Action] = []
    var listeners: [UUID: (DocEvent) -> Void] = [:]
    private var coverCache: Data?
    var id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()   // stable across renames and moves; what sync tracks
    var gonePages = Set<String>()         // ids of pages removed from the document
    var coverSpec: (String, RGB)?         // (style, colour) of a designed cover; nil shows the first page

    init(template: PageTemplate? = nil) {
        pages = [template.map { Page(template: $0) } ?? Page()]
    }

    var modified: Bool { rev != savedRev }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    @discardableResult
    func listen(_ fn: @escaping (DocEvent) -> Void) -> UUID {
        let key = UUID()
        listeners[key] = fn
        return key
    }

    func emit(_ event: DocEvent) {
        switch event {
        case .pages: coverCache = nil
        case .added(let page, _), .dirty(let page, _): if page === pages.first { coverCache = nil }
        default: break
        }
        for fn in Array(listeners.values) { fn(event) }
    }

    /// Mark a change that is not on the undo stack (bookmarks, outline).
    func touch() {
        rev += 1
        emit(.meta)
        emit(.state)
    }

    // MARK: undo

    func perform(_ action: Action) {
        apply(action, forward: true)
        push(action)
    }

    /// Note what an action changed: the page is dirty, and removed items leave tombstones.
    private func mark(_ action: Action, forward: Bool = true) {
        switch action {
        case .items(let page, let removed, let added):
            let (out, into) = forward ? (removed, added) : (added, removed)
            page.rev += 1
            let kept = Set(into.map { ObjectIdentifier($0.1) })
            for (_, it) in out where !kept.contains(ObjectIdentifier(it)) { page.gone.insert(it.id) }
            for (_, it) in into { page.gone.remove(it.id) }
        case .pages(let removed, let added):
            let (out, into) = forward ? (removed, added) : (added, removed)
            for (_, page) in out { gonePages.insert(page.id) }
            for (_, page) in into { gonePages.remove(page.id) }
        case .template(let page, _, _):
            page.rev += 1
        }
    }

    /// Record an action whose effect is already applied.
    func push(_ action: Action) {
        mark(action)
        undoStack.append(action)
        if undoStack.count > 300 { undoStack.removeFirst(undoStack.count - 300) }
        redoStack.removeAll()
        rev += 1
        emit(.state)
    }

    func undo() {
        guard let action = undoStack.popLast() else { return }
        apply(action, forward: false)
        mark(action, forward: false)
        redoStack.append(action)
        rev += 1
        emit(.state)
    }

    func redo() {
        guard let action = redoStack.popLast() else { return }
        apply(action, forward: true)
        mark(action, forward: true)
        undoStack.append(action)
        rev += 1
        emit(.state)
    }

    func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    private func apply(_ action: Action, forward: Bool) {
        switch action {
        case .items(let page, let removed, let added):
            let (out, into) = forward ? (removed, added) : (added, removed)
            let before = page.items.count
            let gone = Set(out.map { ObjectIdentifier($0.1) })
            if !gone.isEmpty { page.items.removeAll { gone.contains(ObjectIdentifier($0)) } }
            for (index, it) in into.sorted(by: { $0.0 < $1.0 }) {
                page.items.insert(it, at: min(index, page.items.count))
            }
            if out.isEmpty, !into.isEmpty, into.map(\.0).min()! >= before {
                emit(.added(page, into.map(\.1)))
            } else {
                var rect: Box?
                for (_, it) in out + into { rect = union(rect, it.bbox) }
                emit(.dirty(page, rect))
            }
        case .pages(let removed, let added):
            let (out, into) = forward ? (removed, added) : (added, removed)
            let gone = Set(out.map { ObjectIdentifier($0.1) })
            pages.removeAll { gone.contains(ObjectIdentifier($0)) }
            for (index, page) in into.sorted(by: { $0.0 < $1.0 }) {
                pages.insert(page, at: min(index, pages.count))
            }
            emit(.pages)
        case .template(let page, let old, let new):
            let t = forward ? new : old
            page.w = t.w; page.h = t.h; page.paper = t.paper; page.color = t.color
            emit(.pages)
            emit(.dirty(page, nil))
        }
    }

    private func indexes(_ page: Page) -> [ObjectIdentifier: Int] {
        var index: [ObjectIdentifier: Int] = [:]
        for (i, it) in page.items.enumerated() { index[ObjectIdentifier(it)] = i }
        return index
    }

    func addItems(_ page: Page, _ items: [Item]) {
        let n = page.items.count
        perform(.items(page, removed: [], added: items.enumerated().map { (n + $0.offset, $0.element) }))
    }

    func removeItems(_ page: Page, _ items: [Item]) {
        let index = indexes(page)
        let removed = items.compactMap { it in index[ObjectIdentifier(it)].map { ($0, it) } }
        if !removed.isEmpty { perform(.items(page, removed: removed, added: [])) }
    }

    func replaceItems(_ page: Page, _ olds: [Item], _ news: [Item]) {
        let index = indexes(page)
        let pairs = zip(olds, news).compactMap { o, n in index[ObjectIdentifier(o)].map { ($0, o, n) } }.sorted { $0.0 < $1.0 }
        perform(.items(page, removed: pairs.map { ($0.0, $0.1) }, added: pairs.map { ($0.0, $0.2) }))
    }

    /// Record an edit made directly on page.items, given the list from before it.
    func pushDiff(_ page: Page, _ before: [Item]) {
        let now = Set(page.items.map { ObjectIdentifier($0) })
        let old = Set(before.map { ObjectIdentifier($0) })
        let removed = before.enumerated().filter { !now.contains(ObjectIdentifier($0.element)) }.map { ($0.offset, $0.element) }
        let added = page.items.enumerated().filter { !old.contains(ObjectIdentifier($0.element)) }.map { ($0.offset, $0.element) }
        if !removed.isEmpty || !added.isEmpty { push(.items(page, removed: removed, added: added)) }
    }

    // MARK: pdf

    static func pdfPages(_ data: Data) throws -> [Page] {
        let pdf = try PdfDoc(data)
        return (0..<pdf.nPages).map { i in
            let (w, h) = pdf.pageSize(i)
            return Page(w, h, pdf: pdf, pdfPage: i)
        }
    }

    static func fromPDF(_ data: Data) throws -> Document {
        let doc = Document()
        doc.pages = try pdfPages(data)
        doc.rev = 1   // not on disk yet
        return doc
    }

    // MARK: file format: zip of document.json + pages, embedded pdfs, images, cover

    func setCover(_ spec: (String, RGB)?) {
        coverSpec = spec
        coverCache = nil
        touch()
    }

    func cover() -> Data {
        if let coverCache { return coverCache }
        var png: Data?
        if let coverSpec {
            png = renderCover(coverSpec, title: displayName).pngData()
        } else if let page = pages.first {
            let snap = page.snap
            let b = snap.box
            // A board's content can have any shape; show it centred on a sheet of its paper.
            let image = page.board ? pageImage(snap, scale: 0, size: (300, 400)) : pageImage(snap, scale: 300 / max(b.w, b.h))
            png = image.pngData()
        }
        coverCache = png ?? Data()
        return coverCache!
    }

    // The file is a zip:
    //   document.json    the page list (id, size, paper, background, bookmark, ...) and what
    //                    was removed from it
    //   pages/<id>.json  one page's items, each with a permanent id, and the ids of the items
    //                    that were removed from the page
    //   pdf/N.pdf, img/N.png, cover.png, id
    // Pages are separate so that only a changed page is serialised again, and items have ids
    // and leave tombstones so that two versions of a notebook can be merged item by item.

    func snapshot() -> Snapshot {
        let ctx = SaveCtx()
        var pdfs: [PdfDoc] = []
        var list: [[String: Any]] = []
        var blobs: [(String, Data)] = []
        for page in pages {
            var d: [String: Any] = ["id": page.id, "w": page.w, "h": page.h, "paper": page.paper, "color": page.color.list]
            if page.board { d["board"] = true }
            if let pdf = page.pdf {
                var n = pdfs.firstIndex { $0 === pdf }
                if n == nil {
                    pdfs.append(pdf)
                    n = pdfs.count - 1
                }
                d["pdf"] = n!
                d["pdf_page"] = page.pdfPage
                d["rot"] = page.rot
            }
            if page.bookmark { d["bookmark"] = true }
            if let outline = page.outline, !outline.isEmpty { d["outline"] = outline }
            list.append(d)
            let hasImage = page.items.contains { $0.kind == "i" }
            if page.blob == nil || page.blob!.rev != page.rev || hasImage {
                let items = page.items.map { it -> [String: Any] in
                    var data = it.toJSON(ctx)
                    data["id"] = it.id
                    return data
                }
                // Tombstones are only needed until every device has seen the removal; cap them.
                let gone = Array(page.gone.sorted().suffix(goneLimit))
                let data = (try? JSONSerialization.data(withJSONObject: ["items": items, "gone": gone])) ?? Data("{}".utf8)
                page.blob = (page.rev, data)
            }
            blobs.append((page.id, page.blob!.data))
        }
        var meta: [String: Any] = ["format": "inkpad", "version": 3, "pages": list, "id": id,
                                   "gone": Array(gonePages.sorted().suffix(goneLimit))]
        if let coverSpec { meta["cover"] = [coverSpec.0, coverSpec.1.list] as [Any] }
        let json = (try? JSONSerialization.data(withJSONObject: meta)) ?? Data()
        return Snapshot(json: json, pages: blobs, pdfs: pdfs.map(\.data), images: ctx.images.map(\.data),
                        cover: cover(), rev: rev, id: id)
    }

    /// Write the file and return its fileSign(). With `expect`, the sign the file had when it
    /// was last read or written, FileChanged is thrown if something else has written it since.
    @discardableResult
    static func write(_ snap: Snapshot, to url: URL, expect: String?) throws -> String? {
        try fileLock.withLock {
            if let expect, fileSign(url) != expect { throw FileChanged() }
            try write(snap, to: url)
            return fileSign(url)
        }
    }

    static func write(_ snap: Snapshot, to url: URL) throws {
        let z = try ZipWriter(url: url)
        do {
            try z.add("document.json", snap.json)
            for (pageID, blob) in snap.pages { try z.add("pages/\(pageID).json", blob) }
            try z.add("id", snap.id, compress: false)
            try z.add("cover.png", snap.cover, compress: false)
            for (i, data) in snap.pdfs.enumerated() { try z.add("pdf/\(i).pdf", data, compress: false) }   // stored: PDFs are already compressed
            for (i, data) in snap.images.enumerated() { try z.add("img/\(i).png", data, compress: false) }
            try z.finish()
        } catch {
            z.abandon()
            throw error
        }
    }

    func save(to target: URL? = nil) throws {
        guard let dest = target ?? url else { throw ZipError("no file") }
        url = dest   // the cover shows the name
        let snap = snapshot()
        try Self.write(snap, to: dest)
        savedRev = snap.rev
        emit(.state)
    }

    static func load(_ url: URL) throws -> Document {
        let z = try ZipReader(url: url)
        guard let meta = try JSONSerialization.jsonObject(with: z.read("document.json")) as? [String: Any],
              meta["format"] as? String == "inkpad" else { throw ZipError(tr("不是 Inkpad 文档")) }
        var pdfs: [PdfDoc] = []
        while z.has("pdf/\(pdfs.count).pdf") { pdfs.append(try PdfDoc(z.read("pdf/\(pdfs.count).pdf"))) }
        var images: [ImageData] = []
        while z.has("img/\(images.count).png") { images.append(ImageData(try z.read("img/\(images.count).png"))) }
        let doc = Document()
        doc.id = meta["id"] as? String ?? doc.id
        doc.pages = []
        for (n, any) in (meta["pages"] as? [Any] ?? []).enumerated() {
            guard let d = any as? [String: Any] else { continue }
            let page = Page(num(d["w"], 595), num(d["h"], 842), paper: d["paper"] as? String ?? "blank",
                            color: RGB(json: d["color"], default: .white), board: d["board"] as? Bool ?? false)
            if let n = (d["pdf"] as? NSNumber)?.intValue, pdfs.indices.contains(n) {
                page.pdf = pdfs[n]
                page.pdfPage = Int(num(d["pdf_page"]))
                page.rot = Int(num(d["rot"]))
            }
            page.bookmark = d["bookmark"] as? Bool ?? false
            page.outline = d["outline"] as? String
            // Files from before version 3 have no ids. They are derived from the content, so
            // that two devices opening the same old file agree on them.
            page.id = d["id"] as? String ?? String(md5Hex("\(doc.id)/\(n)").prefix(16))
            var content: [String: Any] = ["items": d["items"] ?? [Any]()]
            if z.has("pages/\(page.id).json"),
               let c = try JSONSerialization.jsonObject(with: z.read("pages/\(page.id).json")) as? [String: Any] {
                content = c
            }
            for any in content["items"] as? [Any] ?? [] {
                guard let data = any as? [String: Any], let item = itemFromJSON(data, images) else { continue }
                if let id = data["id"] as? String { item.id = id }
                page.items.append(item)
            }
            page.gone = Set(content["gone"] as? [String] ?? [])
            doc.pages.append(page)
        }
        if doc.pages.isEmpty { doc.pages = [Page()] }
        doc.gonePages = Set(meta["gone"] as? [String] ?? [])
        doc.url = url
        if let cover = meta["cover"] as? [Any], !cover.isEmpty {
            // Older files stored a bare colour.
            if let style = cover[0] as? String, cover.count > 1 {
                doc.coverSpec = (style, RGB(json: cover[1]))
            } else {
                doc.coverSpec = ("simple", RGB(json: cover))
            }
        }
        return doc
    }

    var displayName: String {
        url.map { $0.deletingPathExtension().lastPathComponent } ?? tr("未命名笔记")
    }
}

// MARK: merging

/// Fold another version of the same notebook into mine, item by item.
///
/// A page or an item that either side removed stays removed; everything else that either
/// side has is kept. Where both have a page, its settings are mine. Returns what changed
/// in mine: (pages added, pages removed, items added, items removed).
@discardableResult
func merge(_ mine: Document, _ theirs: Document) -> (Int, Int, Int, Int) {
    let gonePages = mine.gonePages.union(theirs.gonePages)
    var counts = (0, 0, 0, 0)
    var byID = Dictionary(mine.pages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    // Their new pages go after the page they follow on their side.
    var previous: String?
    for page in theirs.pages {
        if byID[page.id] != nil {
            previous = page.id
            continue
        }
        if !gonePages.contains(page.id) {
            let at = mine.pages.firstIndex { $0.id == previous }.map { $0 + 1 } ?? mine.pages.count
            mine.pages.insert(page, at: at)
            byID[page.id] = page
            counts.0 += 1
        }
        previous = page.id
    }
    let before = mine.pages.count
    let kept = mine.pages.filter { !gonePages.contains($0.id) }
    mine.pages = kept.isEmpty ? Array(mine.pages.prefix(1)) : kept
    counts.1 = before - mine.pages.count
    let other = Dictionary(theirs.pages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var changed = false
    for page in mine.pages {
        guard let their = other[page.id], their !== page else { continue }
        let gone = page.gone.union(their.gone)
        let have = Set(page.items.map(\.id))
        let new = their.items.filter { !have.contains($0.id) && !gone.contains($0.id) }
        let keptItems = page.items.filter { !gone.contains($0.id) }
        counts.2 += new.count
        counts.3 += page.items.count - keptItems.count
        if !new.isEmpty || keptItems.count != page.items.count || gone != page.gone {
            page.items = keptItems + new
            page.gone = gone
            page.rev += 1
            changed = true
        }
    }
    if changed || gonePages != mine.gonePages || counts != (0, 0, 0, 0) {
        mine.gonePages = gonePages
        mine.clearHistory()
        mine.rev += 1
        mine.emit(.pages)
    }
    return counts
}

// MARK: notebook ids

enum Notebook {
    /// The stable id of a notebook file, giving it one if it predates ids.
    static func id(of url: URL) throws -> String {
        let z = try ZipReader(url: url)
        if z.has("id") { return String(decoding: try z.read("id"), as: UTF8.self) }
        let new = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try setID(url, new)
        return new
    }

    /// Give a notebook file a different id (a file copied by hand shares its original's).
    static func setID(_ url: URL, _ new: String) throws {
        let src = try ZipReader(url: url)
        let dst = try ZipWriter(url: url)
        do {
            var done = Set<String>()
            for entry in src.entries.reversed() where done.insert(entry.name).inserted {
                if entry.name == "id" { continue }
                if entry.name == "document.json",
                   var meta = try JSONSerialization.jsonObject(with: src.read(entry.name)) as? [String: Any] {
                    meta["id"] = new
                    try dst.add("document.json", JSONSerialization.data(withJSONObject: meta))
                } else {
                    try dst.addRaw(entry.name, method: entry.method, crc: entry.crc, size: entry.size, raw: src.raw(entry))
                }
            }
            try dst.add("id", new, compress: false)
            try dst.finish()
        } catch {
            dst.abandon()
            throw error
        }
    }

    static func cover(of url: URL) -> UIImage? {
        guard let z = try? ZipReader(url: url), let data = try? z.read("cover.png") else { return nil }
        return UIImage(data: data)
    }
}

// MARK: export

/// Vector PDF: ink stays as paths, imported PDF pages keep their text and vectors.
func exportPDF(_ doc: Document, to url: URL, pages: [Int]? = nil, paper: Bool = true, ink: Bool = true) throws {
    let chosen = (pages ?? Array(doc.pages.indices)).map { doc.pages[$0].snap }
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
    try renderer.writePDF(to: url) { ctx in
        for page in chosen {
            let b = page.box
            // PDF pages cannot be larger than 200 inches; a sprawling whiteboard is scaled to fit.
            let k = min(1.0, 14400 / max(b.w, b.h))
            ctx.beginPage(withBounds: CGRect(x: 0, y: 0, width: b.w * k, height: b.h * k), pageInfo: [:])
            let g = ctx.cgContext
            g.scaleBy(x: k, y: k)
            g.translateBy(x: -b.x0, y: -b.y0)
            renderPage(g, page, printing: true, paper: paper, ink: ink)
        }
    }
}
