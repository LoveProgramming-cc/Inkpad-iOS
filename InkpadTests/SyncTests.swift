import XCTest
import CryptoKit
@testable import Inkpad

/// Drive kept in memory, shared by the "devices" of a test.
final class FakeDrive: DriveAPI {
    final class Cloud {
        var files: [String: (name: String, data: Data)] = [:]
        var n = 0
    }

    let cloud: Cloud
    var onBytes: ((Int64, Int64) -> Void)?
    var uploads = 0, downloads = 0

    init(_ cloud: Cloud) { self.cloud = cloud }

    static func sum(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func newID() -> String {
        cloud.n += 1
        return "file\(cloud.n)"
    }

    func root() async throws -> String { "root" }

    func find(_ name: String, parent: String) async throws -> String? {
        cloud.files.first { $0.value.name == name }?.key
    }

    func getJSON(_ fileID: String) async throws -> [String: Any] {
        let out = try JSONSerialization.jsonObject(with: cloud.files[fileID]!.data) as! [String: Any]
        if let then = afterIndex {
            afterIndex = nil
            try await then()
        }
        return out
    }

    func putJSON(_ name: String, _ value: [String: Any], parent: String, fileID: String?) async throws -> String {
        let id = fileID ?? newID()
        cloud.files[id] = (cloud.files[id]?.name ?? name, try JSONSerialization.data(withJSONObject: value))
        return id
    }

    func rename(_ fileID: String, _ name: String) async throws {
        cloud.files[fileID]!.name = name
    }

    func upload(_ url: URL, name: String, parent: String, fileID: String?) async throws -> (String, String?) {
        let id = fileID ?? newID()
        cloud.files[id] = (cloud.files[id]?.name ?? name, try Data(contentsOf: url))
        uploads += 1
        return (id, try LibrarySync.md5(url))
    }

    func download(_ fileID: String, to dest: URL) async throws {
        try cloud.files[fileID]!.data.write(to: dest, options: .atomic)
        downloads += 1
    }

    func alive(_ fileID: String) async throws -> Bool { fileID == "root" || fileID.hasPrefix("folder") || cloud.files[fileID] != nil }

    func md5(_ fileID: String) async throws -> String? {
        let out = cloud.files[fileID].map { Self.sum($0.data) }
        if let then = afterMD5 {
            afterMD5 = nil
            try await then()
        }
        return out
    }

    /// Something that another device does at a chosen moment of this one's sync.
    var afterIndex: (() async throws -> Void)?, afterMD5: (() async throws -> Void)?

    func children(_ parent: String) async throws -> [DriveFile] {
        // Ids are handed out in order, so the number in one says how new the file is.
        cloud.files.map { DriveFile(id: $0.key, name: $0.value.name, md5: Self.sum($0.value.data), modified: Double($0.key.dropFirst(4)) ?? 0) }
    }
}

final class SyncTests: XCTestCase {
    var base: URL!
    var a: URL!, b: URL!
    let cloud = FakeDrive.Cloud()

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("inkpad-sync-" + UUID().uuidString)
        a = base.appendingPathComponent("a")
        b = base.appendingPathComponent("b")
        for dir in [a!, b!] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    @discardableResult
    func sync(_ root: URL) async throws -> SyncSummary {
        try await LibrarySync.sync(root: root, drive: FakeDrive(cloud))
    }

    func books(_ root: URL) -> [String] {
        LibrarySync.scan(root).0.keys.sorted()
    }

    func addStroke(_ url: URL, x: Double) throws -> String {
        let doc = try Document.load(url)
        let stroke = Stroke("ball", .black, 1, [Pt(x: x, y: 0), Pt(x: x, y: 50)])
        doc.addItems(doc.pages[0], [stroke])
        try doc.save()
        return stroke.id
    }

    func testTwoDevices() async throws {
        let storeA = Store(root: a), storeB = Store(root: b)
        let folder = try storeA.newFolder(storeA.root, "课程")
        let note = try storeA.newNotebook(folder, PageTemplate(), name: "数学")
        try storeA.newFolder(storeA.root, "空文件夹")

        var s = try await sync(a)
        XCTAssertEqual(s.up, 1)
        s = try await sync(b)
        XCTAssertEqual(s.down, 1)
        XCTAssertEqual(books(b), ["课程/数学.inkpad"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.appendingPathComponent("空文件夹").path))
        // Nothing to do when nothing changed.
        s = try await sync(a)
        XCTAssertEqual(s, SyncSummary())
        s = try await sync(b)
        XCTAssertEqual(s, SyncSummary())

        // An edit on one side travels to the other.
        let noteB = b.appendingPathComponent("课程/数学.inkpad")
        let first = try addStroke(noteB, x: 10)
        s = try await sync(b)
        XCTAssertEqual(s.up, 1)
        s = try await sync(a)
        XCTAssertEqual(s.down, 1)
        XCTAssertEqual(try Document.load(note).pages[0].items.map(\.id), [first])

        // Edits on both sides are merged item by item.
        let mine = try addStroke(note, x: 20), theirs = try addStroke(noteB, x: 30)
        s = try await sync(a)
        XCTAssertEqual(s.up, 1)
        s = try await sync(b)
        XCTAssertEqual(s.merged, 1)
        XCTAssertEqual(s.conflicts, 0)
        XCTAssertEqual(Set(try Document.load(noteB).pages[0].items.map(\.id)), [first, mine, theirs])
        s = try await sync(a)
        XCTAssertEqual(s.down, 1)
        XCTAssertEqual(Set(try Document.load(note).pages[0].items.map(\.id)), [first, mine, theirs])
        XCTAssertEqual(books(a), ["课程/数学.inkpad"])

        // A rename is a changed path on the same id, not a new notebook.
        try storeB.rename(noteB, "高等数学")
        s = try await sync(b)
        XCTAssertEqual(s.moved, 1)
        XCTAssertEqual(s.up, 0)
        s = try await sync(a)
        XCTAssertEqual(s.moved, 1)
        XCTAssertEqual(books(a), ["课程/高等数学.inkpad"])

        // A deletion reaches the other device as a move to its trash.
        try storeA.trash(a.appendingPathComponent("课程/高等数学.inkpad"))
        s = try await sync(a)
        s = try await sync(b)
        XCTAssertEqual(books(b), [])
        XCTAssertEqual(storeB.trashed().map(\.name), ["高等数学"])

        // Restoring it brings it back on both (to the top level: this device never knew its folder).
        try storeB.restore(storeB.trashed()[0].url)
        try await sync(b)
        try await sync(a)
        XCTAssertEqual(books(a), ["高等数学.inkpad"])
        XCTAssertEqual(storeA.trashed().count, 0)

        // A removed empty folder goes away on the other side as well.
        try FileManager.default.removeItem(at: a.appendingPathComponent("空文件夹"))
        try await sync(a)
        try await sync(b)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.appendingPathComponent("空文件夹").path))

        // Favourites travel with the newer library metadata.
        storeA.toggleFavorite(a.appendingPathComponent("高等数学.inkpad"))
        try await sync(a)
        s = try await sync(b)
        XCTAssertTrue(s.meta)
        storeB.reloadMeta()
        XCTAssertEqual(storeB.favorites().map(\.name), ["高等数学"])
    }

    func testArchiveAndCloudRestore() async throws {
        let store = Store(root: a)
        let folder = try store.newFolder(store.root, "课程")
        store.setFolderStyle(folder, color: folderColors[3], icon: "book")
        try store.newNotebook(folder, PageTemplate(), name: "数学")
        let loose = try store.newNotebook(store.root, PageTemplate(), name: "散页")
        try store.newFolder(folder, "空")

        // The whole library into one zip, and out again somewhere else.
        let zip = base.appendingPathComponent("library.zip")
        XCTAssertEqual(try store.exportArchive(store.root, to: zip), 2)
        let other = Store(root: b)
        XCTAssertEqual(try other.importArchive(zip, into: other.root), 2)
        XCTAssertEqual(books(b), ["散页.inkpad", "课程/数学.inkpad"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.appendingPathComponent("课程/空").path))
        XCTAssertEqual(other.folderStyle(b.appendingPathComponent("课程")).1, "book")
        XCTAssertEqual(try other.importArchive(zip, into: other.root), 2, "importing again never overwrites")
        XCTAssertEqual(books(b).count, 4)

        // Deleted for good here, the file stays on Drive and can be fetched back.
        try await sync(a)
        let id = try Notebook.id(of: loose)
        try store.trash(loose)
        try store.delete(store.trashed()[0].url)
        XCTAssertEqual(store.archived().map { Store.archivedName($0.name) }, ["散页"])
        try await sync(a)
        let gone = try await LibrarySync.cloudDeleted(root: a, drive: FakeDrive(cloud))
        XCTAssertEqual(gone.map(\.id), [id])
        XCTAssertEqual(gone.first?.path, "散页.inkpad")
        let n = try await LibrarySync.cloudRestore(root: a, drive: FakeDrive(cloud), ids: [id])
        XCTAssertEqual(n, 1)
        XCTAssertEqual(books(a), ["散页.inkpad", "课程/数学.inkpad"])
        let after = try await LibrarySync.cloudDeleted(root: a, drive: FakeDrive(cloud))
        XCTAssertTrue(after.isEmpty)
        let s = try await sync(a)
        XCTAssertEqual(s.up + s.down + s.removed, 0, "restored on both sides: nothing left to do")

        // And the copy kept on the device comes back to where it was.
        try store.unarchive(store.archived()[0].url)
        XCTAssertEqual(books(a), ["散页 2.inkpad", "散页.inkpad", "课程/数学.inkpad"])
    }

    /// A notebook's file deleted on Drive itself: the index still lists it, but it is gone. It
    /// is forgotten, and sent again by the device that still has it.
    func testFileGoneFromDriveIsSentAgain() async throws {
        let store = Store(root: a)
        let note = try store.newNotebook(store.root, PageTemplate(), name: "数学")
        try await sync(a)
        try await sync(b)
        let index = try await FakeDrive(cloud).getJSON(cloud.files.first { $0.value.name == LibrarySync.indexName }!.key)
        let nid = try Notebook.id(of: note)
        let file = ((index["items"] as! [String: Any])[nid] as! [String: Any])["file"] as! String
        cloud.files[file] = nil

        let drive = FakeDrive(cloud)
        let s = try await LibrarySync.sync(root: b, drive: drive)
        XCTAssertEqual(s.up, 1)
        XCTAssertEqual(s.removed, 0, "not taken for a deletion")
        XCTAssertEqual(books(b), ["数学.inkpad"])
        let s2 = try await sync(a)
        XCTAssertEqual(s2.up + s2.down + s2.removed, 0)
        XCTAssertEqual(books(a), ["数学.inkpad"])
    }

    /// A sync that is cut off has written down how far it got: the next one, on any device,
    /// goes on from there.
    func testCheckpoint() async throws {
        final class Failing: DriveAPI {
            let inner: FakeDrive
            init(_ inner: FakeDrive) { self.inner = inner }
            var onBytes: ((Int64, Int64) -> Void)?
            func root() async throws -> String { try await inner.root() }
            func find(_ name: String, parent: String) async throws -> String? { try await inner.find(name, parent: parent) }
            func getJSON(_ fileID: String) async throws -> [String: Any] { try await inner.getJSON(fileID) }
            func putJSON(_ name: String, _ value: [String: Any], parent: String, fileID: String?) async throws -> String {
                try await inner.putJSON(name, value, parent: parent, fileID: fileID)
            }
            func rename(_ fileID: String, _ name: String) async throws { try await inner.rename(fileID, name) }
            func upload(_ url: URL, name: String, parent: String, fileID: String?) async throws -> (String, String?) {
                if inner.uploads == 2 { throw DriveError("the connection dropped") }
                return try await inner.upload(url, name: name, parent: parent, fileID: fileID)
            }
            func download(_ fileID: String, to dest: URL) async throws { try await inner.download(fileID, to: dest) }
            func children(_ parent: String) async throws -> [DriveFile] { try await inner.children(parent) }
            func alive(_ fileID: String) async throws -> Bool { try await inner.alive(fileID) }
            func md5(_ fileID: String) async throws -> String? { try await inner.md5(fileID) }
        }
        let store = Store(root: a)
        for name in ["一", "二", "三"] { _ = try store.newNotebook(store.root, PageTemplate(), name: name) }
        let was = LibrarySync.checkpoint
        LibrarySync.checkpoint = 0
        defer { LibrarySync.checkpoint = was }
        do {
            _ = try await LibrarySync.sync(root: a, drive: Failing(FakeDrive(cloud)))
            XCTFail("the third upload should have failed")
        } catch {}
        let index = try await FakeDrive(cloud).getJSON(cloud.files.first { $0.value.name == LibrarySync.indexName }!.key)
        XCTAssertEqual((index["items"] as? [String: Any])?.count, 2, "the two that went up are in the index already")
        let other = try await sync(b)
        XCTAssertEqual(other.down, 2)
        let rest = FakeDrive(cloud)
        let s = try await LibrarySync.sync(root: a, drive: rest)
        XCTAssertEqual(rest.uploads, 1, "only what was left")
        XCTAssertEqual(s.up, 1)
    }

    /// Asked to sync with another folder, the device forgets what it knew of the old one and
    /// compares everything again; a folder it cannot see is refused.
    func testChangingTheFolder() async throws {
        let store = Store(root: a)
        _ = try store.newNotebook(store.root, PageTemplate(), name: "数学")
        try await sync(a)
        XCTAssertEqual(LibrarySync.cloudFolder(a), "root")
        let drive = FakeDrive(cloud)
        let s = try await LibrarySync.sync(root: a, drive: drive, folder: "folder2")
        XCTAssertEqual(LibrarySync.cloudFolder(a), "folder2")
        XCTAssertEqual(s.removed, 0)
        XCTAssertEqual(books(a), ["数学.inkpad"])
        do {
            _ = try await LibrarySync.sync(root: a, drive: FakeDrive(cloud), folder: "missing")
            XCTFail("a folder that is not there cannot be synced with")
        } catch {}
        XCTAssertEqual(books(a), ["数学.inkpad"])

        XCTAssertEqual(try LibrarySync.parseFolder(" https://drive.google.com/drive/folders/1AbC-d_9?usp=sharing "), "1AbC-d_9")
        XCTAssertEqual(try LibrarySync.parseFolder("https://drive.google.com/open?id=xyz123&x=1"), "xyz123")
        XCTAssertEqual(try LibrarySync.parseFolder("1AbC"), "1AbC")
        XCTAssertEqual(try LibrarySync.parseFolder(""), "")
        XCTAssertThrowsError(try LibrarySync.parseFolder("my folder!"))
    }

    func testMovesCanBeUndone() throws {
        let store = Store(root: a)
        let folder = try store.newFolder(store.root, "课程")
        let inner = try store.newFolder(folder, "作业")
        let note = try store.newNotebook(store.root, PageTemplate(), name: "数学")
        XCTAssertThrowsError(try store.move(folder, to: inner), "a folder cannot go inside itself")
        _ = try store.newNotebook(folder, PageTemplate(), name: "数学")
        let moved = try store.move(note, to: folder)
        XCTAssertEqual(moved.lastPathComponent, "数学 2.inkpad")
        // Taken back, it has the name it had.
        let back = try store.move(moved, to: store.root, name: "数学")
        XCTAssertEqual(back.standardizedFileURL.path, note.standardizedFileURL.path)
        XCTAssertEqual(store.folders().map { store.rel($0) }, [".", "课程", "课程/作业"])
    }

    func testCopyGetsItsOwnID() async throws {
        let store = Store(root: a)
        let note = try store.newNotebook(store.root, PageTemplate(), name: "原件")
        try await sync(a)
        try FileManager.default.copyItem(at: note, to: a.appendingPathComponent("拷贝.inkpad"))
        let s = try await sync(a)
        XCTAssertEqual(s.up, 1)
        XCTAssertNotEqual(try Notebook.id(of: note), try Notebook.id(of: a.appendingPathComponent("拷贝.inkpad")))
        try await sync(b)
        XCTAssertEqual(books(b), ["原件.inkpad", "拷贝.inkpad"])
    }

    /// A new page with a stroke on it, and a stroke on the first page.
    func addPage(_ url: URL, x: Double) throws {
        let doc = try Document.load(url)
        let page = Page()
        doc.perform(.pages(removed: [], added: [(doc.pages.count, page)]))
        doc.addItems(page, [Stroke("ball", .black, 1, [Pt(x: x, y: 0), Pt(x: x, y: 50)])])
        doc.addItems(doc.pages[0], [Stroke("ball", .black, 1, [Pt(x: x + 1, y: 0), Pt(x: x + 1, y: 50)])])
        try doc.save()
    }

    func shape(_ url: URL) throws -> [Int] {
        try Document.load(url).pages.map(\.items.count)
    }

    /// Two devices each add a page and write on the first one, and their syncs overlap: one
    /// has read the index, or is about to upload, when the other syncs from start to end.
    func testOverlappingSyncsLoseNothing() async throws {
        for moment in ["index", "md5"] {
            let cloud = FakeDrive.Cloud()
            let a = base.appendingPathComponent("a-" + moment), b = base.appendingPathComponent("b-" + moment)
            for dir in [a, b] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            let store = Store(root: a)
            let mine = try store.newNotebook(store.root, PageTemplate(), name: "同一本")
            _ = try await LibrarySync.sync(root: a, drive: FakeDrive(cloud))
            _ = try await LibrarySync.sync(root: b, drive: FakeDrive(cloud))
            let theirs = b.appendingPathComponent("同一本.inkpad")
            try addPage(mine, x: 10)
            try addPage(theirs, x: 20)

            let slow = FakeDrive(cloud)
            let other: () async throws -> Void = { _ = try await LibrarySync.sync(root: b, drive: FakeDrive(cloud)) }
            if moment == "index" { slow.afterIndex = other } else { slow.afterMD5 = other }
            _ = try await LibrarySync.sync(root: a, drive: slow)
            for _ in 0..<3 {
                _ = try await LibrarySync.sync(root: a, drive: FakeDrive(cloud))
                _ = try await LibrarySync.sync(root: b, drive: FakeDrive(cloud))
            }
            XCTAssertEqual(try shape(mine), [2, 1, 1], moment)
            XCTAssertEqual(try shape(theirs), [2, 1, 1], moment)
            let last = try await LibrarySync.sync(root: a, drive: FakeDrive(cloud))
            XCTAssertEqual(last, SyncSummary(), moment)
        }
    }

    /// The editor never writes over what a sync put in the file.
    func testSaveAfterTheFileChanged() throws {
        let store = Store(root: a)
        let note = try store.newNotebook(store.root, PageTemplate(), name: "打开着")
        let open = try Document.load(note)
        let sign = fileSign(note)
        _ = try addStroke(note, x: 5)   // what a sync brings
        XCTAssertNotEqual(fileSign(note), sign)
        open.addItems(open.pages[0], [Stroke("ball", .black, 1, [Pt(x: 9, y: 0), Pt(x: 9, y: 50)])])
        XCTAssertThrowsError(try Document.write(open.snapshot(), to: note, expect: sign)) { XCTAssertTrue($0 is FileChanged) }
        merge(open, try Document.load(note))
        try Document.write(open.snapshot(), to: note, expect: fileSign(note))
        XCTAssertEqual(try shape(note), [2])
    }

    func testSkippedNotebookIsLeftAlone() async throws {
        let store = Store(root: a)
        let note = try store.newNotebook(store.root, PageTemplate(), name: "编辑中")
        let s = try await LibrarySync.sync(root: a, drive: FakeDrive(cloud), skip: [note])
        XCTAssertEqual(s.up, 0)
        let again = try await sync(a)
        XCTAssertEqual(again.up, 1)
    }
}
