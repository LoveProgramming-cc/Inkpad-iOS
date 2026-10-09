import XCTest
@testable import Inkpad

final class GoodnotesTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("inkpad-gn-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// What was read, in the form tools/goodnotes_compat.py writes it down.
    static func dump(_ doc: Document, _ title: String, _ stats: Goodnotes.Stats) -> [String: Any] {
        let pages: [[String: Any]] = doc.pages.map { page in
            let items: [[String: Any]] = page.items.map { item in
                if let it = item as? Stroke {
                    return ["k": "s", "tool": it.tool, "color": it.color.list, "width": it.width, "sens": it.sens, "dash": it.dash,
                            "pts": it.pts.map { [$0.x, $0.y, $0.p] }]
                }
                if let it = item as? TextItem {
                    return ["k": "t", "x": it.x, "y": it.y, "text": it.text, "size": it.size, "color": it.color.list, "wrap": it.wrap,
                            "bg": it.bg.map { $0.list as Any } ?? NSNull()]
                }
                if let it = item as? Shape {
                    return ["k": "h", "shape": it.shape, "box": [it.x0, it.y0, it.x1, it.y1], "color": it.color.list, "width": it.width]
                }
                return ["k": item.kind]
            }
            return ["w": page.w, "h": page.h, "board": page.board, "pdf": page.pdf != nil, "items": items]
        }
        return ["title": title, "pages": pages,
                "stats": ["strokes": stats.strokes, "texts": stats.texts, "shapes": stats.shapes, "formulas": stats.formulas,
                          "images": stats.images, "skipped": stats.skipped]]
    }

    /// Compare two JSON-like trees; numbers to one part in a million (the desktop keeps float32
    /// values in doubles, as this app does, but the arithmetic is not in the same order everywhere).
    func assertClose(_ a: Any, _ b: Any, _ path: String = "", file: StaticString = #filePath, line: UInt = #line) {
        if let x = a as? [String: Any] {
            guard let y = b as? [String: Any] else { return XCTFail("\(path): not a dictionary", file: file, line: line) }
            XCTAssertEqual(Set(x.keys), Set(y.keys), path, file: file, line: line)
            for (key, value) in x { if let other = y[key] { assertClose(value, other, path + "/" + key, file: file, line: line) } }
        } else if let x = a as? [Any] {
            guard let y = b as? [Any], x.count == y.count else {
                return XCTFail("\(path): \(x.count) against \((b as? [Any])?.count ?? -1)", file: file, line: line)
            }
            for (n, (p, q)) in zip(x, y).enumerated() { assertClose(p, q, "\(path)[\(n)]", file: file, line: line) }
        } else if let x = a as? String {
            XCTAssertEqual(x, b as? String, path, file: file, line: line)
        } else if a is NSNull {
            XCTAssertTrue(b is NSNull, path, file: file, line: line)
        } else if let x = a as? NSNumber, let y = b as? NSNumber {
            XCTAssertEqual(x.doubleValue, y.doubleValue, accuracy: 1e-6 * max(1, abs(x.doubleValue)), path, file: file, line: line)
        } else {
            XCTFail("\(path): \(a) against \(b)", file: file, line: line)
        }
    }

    func sample() -> Document {
        let doc = Document(template: PageTemplate(paper: "grid"))
        let page = doc.pages[0]
        doc.addItems(page, [
            Stroke("ball", RGB(0.1, 0.2, 0.3), 1.6, [Pt(x: 50, y: 60), Pt(x: 80, y: 90.5), Pt(x: 120.25, y: 70)]),
            Stroke("fountain", RGB(0.8, 0.1, 0.1), 2.0, [Pt(x: 200, y: 200, p: 0.2), Pt(x: 220, y: 240, p: 0.9), Pt(x: 260, y: 250, p: 0.5)], sens: 1.2),
            Stroke("hl", RGB(1.0, 0.9, 0.2), 14, [Pt(x: 100, y: 400), Pt(x: 300, y: 400)]),
            Stroke("ball", .black, 1.2, [Pt(x: 10, y: 10)]),
            TextItem(50, 500, "not a stroke", 18, .black, wrap: 300),
            Shape("rect", 300, 500, 400, 560, RGB(0.2, 0.2, 0.8), 1.5),
        ])
        doc.perform(.pages(removed: [], added: [(1, Page(420, 595, paper: "dots"))]))
        doc.addItems(doc.pages[1], [Stroke("brush", RGB(0.2, 0.6, 0.2), 2.4, [Pt(x: 30, y: 30, p: 0.3), Pt(x: 60, y: 80, p: 0.8)], sens: 1.5)])
        return doc
    }

    /// Export and read back: the pages come back on a PDF of everything that is not ink,
    /// with the ink on top as strokes of their average width.
    func testExportReadsBack() throws {
        let url = dir.appendingPathComponent("out.goodnotes")
        let doc = sample()
        try Goodnotes.save(doc, to: url, title: "导出测试")
        let (back, title, stats) = try Goodnotes.load(url)
        XCTAssertEqual(title, "导出测试")
        XCTAssertEqual(stats, Goodnotes.Stats(strokes: 5))
        XCTAssertEqual(back.pages.count, 2)
        XCTAssertNotNil(back.pages[0].pdf, "text, shapes and paper are in the background PDF")
        XCTAssertEqual(back.pages[0].w, 595, accuracy: 0.01)
        XCTAssertEqual(back.pages[1].h, 595, accuracy: 0.01)
        let strokes = back.pages[0].items.compactMap { $0 as? Stroke }
        // The exporter numbers each stroke by how many points it has, as the desktop's does, and
        // the reader puts them in that order; a fountain pen's line comes back at its average width.
        XCTAssertEqual(strokes.map(\.tool), ["hl", "ball", "ball", "ball"])
        XCTAssertEqual(strokes[2].pts.last?.x ?? 0, 120.25, accuracy: 0.01)
        XCTAssertEqual(strokes[2].width, 1.6, accuracy: 0.01)
        XCTAssertEqual(strokes[2].color.g, 0.2, accuracy: 0.01)
        XCTAssertEqual(strokes[0].width, 14, accuracy: 0.01)
        // And it opens as a notebook.
        let store = Store(root: dir.appendingPathComponent("lib"))
        let (made, _) = try store.importGoodnotes(store.root, source: url)
        XCTAssertEqual(made.lastPathComponent, "导出测试.inkpad")
        XCTAssertEqual(try Document.load(made).pages.count, 2)
        XCTAssertThrowsError(try Goodnotes.load(dir.appendingPathComponent("missing.goodnotes")))
    }

    /// A picture in a Goodnotes page becomes a picture here.
    func testPictureIsImported() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        func enc(_ n: Int) -> [UInt8] { n < 128 ? [UInt8(n)] : [UInt8(n & 0x7f | 0x80)] + enc(n >> 7) }
        func f(_ number: Int, _ bytes: [UInt8]) -> [UInt8] { enc(number << 3 | 2) + enc(bytes.count) + bytes }
        func f(_ number: Int, _ text: String) -> [UInt8] { f(number, [UInt8](text.utf8)) }
        func fl(_ number: Int, _ value: Float) -> [UInt8] { enc(number << 3 | 5) + withUnsafeBytes(of: value.bitPattern.littleEndian) { [UInt8]($0) } }
        func rec(_ bytes: [UInt8]) -> [UInt8] { enc(bytes.count) + bytes }
        let url = dir.appendingPathComponent("pic.goodnotes")
        let z = try ZipWriter(url: url)
        try z.add("index.events.pb", Data(rec(f(1, "T") + f(2, f(2, "T") + f(8, fl(1, 1100) + fl(2, 1540)))) + rec(f(1, "PAGE00A0") + f(54, f(2, "PAGE00A0") + f(3, f(1, "T")) + f(4, f(1, "P0"))))))
        try z.add("index.notes.pb", Data(rec(f(1, "PAGE00A1") + f(2, "notes/a"))))
        try z.add("index.attachments.pb", Data(rec(f(1, "PIC") + f(2, "attachments/pic"))))
        try z.add("attachments/pic", image.jpegData(compressionQuality: 0.9)!)
        try z.add("notes/a", Data(rec(f(1, f(1, "E1") + f(2, f(1, fl(1, 110) + fl(2, 220)) + f(2, fl(1, 440) + fl(2, 220))) + f(4, "PIC")))))
        try z.finish()
        let (doc, title, stats) = try Goodnotes.load(url)
        XCTAssertEqual(title, "pic")
        XCTAssertEqual(stats, Goodnotes.Stats(images: 1))
        let picture = try XCTUnwrap(doc.pages[0].items.first as? ImageItem)
        XCTAssertEqual(picture.x, 60, accuracy: 0.01)
        XCTAssertEqual(picture.w, 240, accuracy: 0.01)
        XCTAssertEqual(picture.source.data.prefix(4), Data([0x89, 0x50, 0x4e, 0x47]), "kept as PNG")
    }

    func testRtfAndPageRanges() throws {
        XCTAssertEqual(try Goodnotes.unrtf("{\\rtf1{\\fonttbl{\\f0 X;}}\\f0 caf\\'e9 \\u20320?\\par two \\u-10179?\\u-8704?}"), "café 你\ntwo 😀")
        XCTAssertEqual(try pageRange("1-3, 5", total: 6), [0, 1, 2, 4])
        XCTAssertEqual(try pageRange("2，2、4–5", total: 6), [1, 3, 4])
        XCTAssertNil(try pageRange("  ", total: 6))
        XCTAssertThrowsError(try pageRange("0-2", total: 6))
        XCTAssertThrowsError(try pageRange("3-9", total: 6))
        XCTAssertThrowsError(try pageRange("a", total: 6))
    }

    /// A whole folder of Goodnotes documents, PDFs and notebooks comes in with its structure,
    /// and a selection of notebooks and folders goes out as one archive.
    func testFolderImportAndSelectionExport() throws {
        let fm = FileManager.default
        let source = dir.appendingPathComponent("课程资料")
        try fm.createDirectory(at: source.appendingPathComponent("第一章/.hidden"), withIntermediateDirectories: true)
        try Goodnotes.save(sample(), to: source.appendingPathComponent("手写.goodnotes"), title: "x")
        try sample().save(to: source.appendingPathComponent("第一章/笔记.inkpad"))
        try Data("not a pdf".utf8).write(to: source.appendingPathComponent("第一章/坏.pdf"))
        try Data("ignored".utf8).write(to: source.appendingPathComponent("readme.txt"))
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { $0.beginPage() }
        try pdf.write(to: source.appendingPathComponent("第一章/讲义.PDF"))

        let store = Store(root: dir.appendingPathComponent("lib"))
        var seen: [Double] = []
        let (done, failed) = try Store.importTree(source, into: store.root) { fraction, _ in seen.append(fraction) }
        XCTAssertEqual(done, 3)
        XCTAssertEqual(failed.map(\.0), ["第一章/坏.pdf"])
        XCTAssertEqual(seen.last, 1.0)
        XCTAssertEqual(LibrarySync.scan(store.root).0.keys.sorted(), ["课程资料/手写.inkpad", "课程资料/第一章/笔记.inkpad", "课程资料/第一章/讲义.inkpad"])
        let copied = store.root.appendingPathComponent("课程资料/第一章/笔记.inkpad")
        XCTAssertNotEqual(try Notebook.id(of: copied), try Notebook.id(of: source.appendingPathComponent("第一章/笔记.inkpad")), "a copy is a notebook of its own")

        let loose = try store.newNotebook(store.root, PageTemplate(), name: "单本")
        store.setFolderStyle(store.root.appendingPathComponent("课程资料"), color: folderColors[2], icon: "book")
        let zip = dir.appendingPathComponent("picked.zip")
        XCTAssertEqual(try store.exportPaths([loose, store.root.appendingPathComponent("课程资料")], to: zip), 4)
        let other = Store(root: dir.appendingPathComponent("lib2"))
        XCTAssertEqual(try other.importArchive(zip, into: other.root), 4)
        XCTAssertEqual(LibrarySync.scan(other.root).0.keys.sorted(), ["单本.inkpad", "课程资料/手写.inkpad", "课程资料/第一章/笔记.inkpad", "课程资料/第一章/讲义.inkpad"])
        XCTAssertEqual(other.folderStyle(other.root.appendingPathComponent("课程资料")).1, "book")
    }

    /// Held against the desktop app's own reader and writer; see tools/goodnotes_compat.py.
    func testAgainstDesktopCode() throws {
        guard let path = ProcessInfo.processInfo.environment["INKPAD_GN"] else {
            throw XCTSkip("set TEST_RUNNER_INKPAD_GN to run the cross-implementation test")
        }
        let base = URL(fileURLWithPath: path)
        for name in ["synthetic", "desktop"] {
            let (doc, title, stats) = try Goodnotes.load(base.appendingPathComponent(name + ".goodnotes"))
            let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent(name + ".json")))
            let mine = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: Self.dump(doc, title, stats)))
            assertClose(expected, mine, name)
        }
        // And the other way round: what this app exports, for the desktop reader to read.
        let url = base.appendingPathComponent("ios.goodnotes")
        try Goodnotes.save(sample(), to: url, title: "iPad 导出")
        let (doc, title, stats) = try Goodnotes.load(url)
        let out = Self.dump(doc, title, stats)
        try JSONSerialization.data(withJSONObject: out).write(to: base.appendingPathComponent("ios.json"))
    }
}
