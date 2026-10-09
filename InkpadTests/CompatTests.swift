import XCTest
@testable import Inkpad

/// Drive as a folder on disk, so that this app and the desktop app's own Python code can
/// sync with each other in a test. tools/compat.py holds the other half.
final class DirDrive: DriveAPI {
    let dir: URL
    var onBytes: ((Int64, Int64) -> Void)?

    init(_ dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private var namesURL: URL { dir.appendingPathComponent("names.json") }
    private var names: [String: String] {
        get { (LibrarySync.loadJSON(namesURL) as? [String: String]) ?? [:] }
        set { try? LibrarySync.saveJSON(namesURL, newValue) }
    }

    private func file(_ id: String) -> URL { dir.appendingPathComponent(id + ".bin") }
    private func newID() -> String { "f" + UUID().uuidString.prefix(8).lowercased() }

    func root() async throws -> String { "root" }
    func alive(_ fileID: String) async throws -> Bool { fileID == "root" || FileManager.default.fileExists(atPath: file(fileID).path) }
    func children(_ parent: String) async throws -> [DriveFile] {
        names.map { DriveFile(id: $0.key, name: $0.value, md5: nil, modified: 0) }
    }
    func find(_ name: String, parent: String) async throws -> String? { names.first { $0.value == name }?.key }
    func getJSON(_ fileID: String) async throws -> [String: Any] { LibrarySync.loadJSON(file(fileID)) }

    func putJSON(_ name: String, _ value: [String: Any], parent: String, fileID: String?) async throws -> String {
        let id = fileID ?? newID()
        try LibrarySync.saveJSON(file(id), value)
        if fileID == nil { names[id] = name }
        return id
    }

    func rename(_ fileID: String, _ name: String) async throws { names[fileID] = name }

    func upload(_ url: URL, name: String, parent: String, fileID: String?) async throws -> (String, String?) {
        let id = fileID ?? newID()
        try Data(contentsOf: url).write(to: file(id), options: .atomic)
        if fileID == nil { names[id] = name }
        return (id, try LibrarySync.md5(file(id)))
    }

    func download(_ fileID: String, to dest: URL) async throws {
        try Data(contentsOf: file(fileID)).write(to: dest, options: .atomic)
    }
}

final class CompatTests: XCTestCase {
    /// Stage 1 (before tools/compat.py has run): make a library and sync it up.
    /// Stage 2 (after): sync again and check what the desktop code did with it.
    func testSyncWithDesktopCode() async throws {
        guard let path = ProcessInfo.processInfo.environment["INKPAD_COMPAT"] else {
            throw XCTSkip("set TEST_RUNNER_INKPAD_COMPAT to run the cross-implementation test")
        }
        let base = URL(fileURLWithPath: path)
        let root = base.appendingPathComponent("ios"), cloud = base.appendingPathComponent("cloud")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let store = Store(root: root)
        let notes = root.appendingPathComponent("课程/笔记.inkpad")

        if !fm.fileExists(atPath: base.appendingPathComponent("desktop-done").path) {
            let folder = try store.newFolder(store.root, "课程")
            let doc = ModelTests().sampleDocument()
            doc.coverSpec = ("label", coverColors[3])
            try doc.save(to: folder.appendingPathComponent("笔记.inkpad"))
            try store.newNotebook(store.root, PageTemplate(paper: "dots", board: true), name: "白板")
            try store.newNotebook(store.root, PageTemplate(), name: "将被删除")
            store.toggleFavorite(notes)
            let s = try await LibrarySync.sync(root: root, drive: DirDrive(cloud))
            XCTAssertEqual(s.up, 3)
            try doc.pages[0].items.map(\.id).joined(separator: "\n").write(to: base.appendingPathComponent("ios-items.txt"), atomically: true, encoding: .utf8)
            return
        }

        // The desktop side added a stroke to the notebook, renamed the board, deleted one
        // notebook and made one of its own. Meanwhile this side writes in the notebook too.
        let mine = Stroke("ball", .black, 1.2, [Pt(x: 300, y: 700), Pt(x: 400, y: 720)])
        let doc = try Document.load(notes)
        doc.addItems(doc.pages[0], [mine])
        try doc.save()
        let s = try await LibrarySync.sync(root: root, drive: DirDrive(cloud))
        XCTAssertEqual(s.merged, 1, "edited on both sides: merged item by item")
        XCTAssertEqual(s.conflicts, 0)
        XCTAssertEqual(LibrarySync.scan(root).0.keys.sorted(), ["桌面新建.inkpad", "画板.inkpad", "课程/笔记.inkpad"])
        XCTAssertEqual(store.trashed().map(\.name), ["将被删除"])

        let merged = try Document.load(notes)
        let ids = merged.pages[0].items.map(\.id)
        let original = try String(contentsOf: base.appendingPathComponent("ios-items.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
        let theirs = try String(contentsOf: base.appendingPathComponent("desktop-item.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        // The desktop removed the arrow (the third item) as well.
        XCTAssertEqual(Set(ids), Set(original).subtracting([original[2]]).union([mine.id, theirs]))
        let added = merged.pages[0].items.first { $0.id == theirs } as? Stroke
        XCTAssertEqual(added?.tool, "brush")
        XCTAssertEqual(added?.pts.count, 3)
        XCTAssertEqual(added?.pts[1].x ?? 0, 150.5, accuracy: 0.01)
        XCTAssertEqual(merged.pages.count, 3, "the page the desktop added")
        XCTAssertEqual(merged.pages[2].paper, "grid")

        let made = try Document.load(root.appendingPathComponent("桌面新建.inkpad"))
        XCTAssertEqual(made.pages[0].paper, "cornell")
        XCTAssertEqual((made.pages[0].items.first as? TextItem)?.text, "来自桌面")
        XCTAssertEqual((made.pages[0].items.last as? Shape)?.shape, "ellipse")

        store.reloadMeta()
        XCTAssertEqual(Set(store.favorites().map(\.name)), ["笔记", "桌面新建"])
        // And nothing more to do afterwards.
        let again = try await LibrarySync.sync(root: root, drive: DirDrive(cloud))
        XCTAssertEqual(again.up + again.down + again.merged + again.moved, 0)
    }
}
