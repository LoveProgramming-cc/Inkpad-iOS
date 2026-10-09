import XCTest
@testable import Inkpad

final class ModelTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("inkpad-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// The same points, packed by the desktop app's pack_points().
    func testPackedPointsMatchDesktop() {
        let pts = [Pt(x: 100.123, y: 200.456, p: 0.5), Pt(x: 101.005, y: 199.995, p: 0.73), Pt(x: 50.0, y: -12.345, p: 0.0),
                   Pt(x: 50000000.25, y: 50000000.75, p: 1.0), Pt(x: 49999990.115, y: 50000003.125, p: 0.2)]
        let packed = "HVpkO98HWUA730+Nlw5pQAAAgLABW7rXT+PLAgCi+q6gJbrcr6Al/+kP2gMz"
        XCTAssertEqual(packPoints(pts), packed)
        let back = unpackPoints(packed)
        let expect: [(Double, Double, Double)] = [(100.123, 200.456, 0.5019607843137255), (101.0, 200.0, 0.7294117647058823),
                                                  (50.0, -12.34, 0.0), (50000000.25, 50000000.75, 1.0), (49999990.12, 50000003.12, 0.2)]
        XCTAssertEqual(back.count, expect.count)
        for (a, b) in zip(back, expect) {
            XCTAssertEqual(a.x, b.0, accuracy: 1e-9)
            XCTAssertEqual(a.y, b.1, accuracy: 1e-9)
            XCTAssertEqual(a.p, b.2, accuracy: 1e-9)
        }
        XCTAssertEqual(packPoints([]), "")
        XCTAssertTrue(unpackPoints("").isEmpty)
    }

    func testZipRoundTrip() throws {
        let url = dir.appendingPathComponent("a.zip")
        let big = Data((0..<200_000).map { UInt8(($0 / 7) % 251) })
        let z = try ZipWriter(url: url)
        try z.add("hello.txt", "hello")
        try z.add("big.bin", big)
        try z.add("stored/名.bin", big, compress: false)
        try z.add("empty", Data())
        try z.finish()
        let r = try ZipReader(url: url)
        XCTAssertEqual(Set(r.names), ["hello.txt", "big.bin", "stored/名.bin", "empty"])
        XCTAssertEqual(String(decoding: try r.read("hello.txt"), as: UTF8.self), "hello")
        XCTAssertEqual(try r.read("big.bin"), big)
        XCTAssertEqual(r.entry("big.bin")?.method, 8)
        XCTAssertEqual(try r.read("stored/名.bin"), big)
        XCTAssertEqual(try r.read("empty"), Data())
    }

    func sampleDocument() -> Document {
        let doc = Document(template: PageTemplate(w: 595, h: 842, paper: "grid", color: RGB(0.976, 0.965, 0.902)))
        let page = doc.pages[0]
        let stroke = Stroke("fountain", RGB(0.1, 0.2, 0.3), 1.6, [Pt(x: 10, y: 10, p: 0.2), Pt(x: 60, y: 40, p: 0.8), Pt(x: 120, y: 30, p: 0.5)], sens: 1.2)
        let tape = Stroke("tape", RGB(0.96, 0.82, 0.36), 16, [Pt(x: 50, y: 300), Pt(x: 200, y: 300)])
        tape.open = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }
        doc.addItems(page, [stroke, tape,
                            Shape("arrow", 20, 100, 200, 180, RGB(1, 0, 0), 2),
                            TextItem(40, 400, "你好 Inkpad", 18, .black, wrap: 300),
                            TextItem(300, 400, "note", 13, RGB(0.16, 0.15, 0.12), wrap: 170, bg: RGB(1, 0.93, 0.55)),
                            ImageItem(100, 500, 80, 60, ImageData(image.pngData()!))])
        let second = page.blankLike()
        second.bookmark = true
        second.outline = "第二页"
        doc.perform(.pages(removed: [], added: [(1, second)]))
        doc.addItems(second, [Stroke("hl", RGB(1, 0.88, 0.3), 14, [Pt(x: 5, y: 5), Pt(x: 100, y: 5)], dash: 1)])
        return doc
    }

    func testDocumentRoundTrip() throws {
        let doc = sampleDocument()
        doc.coverSpec = ("band", RGB(0.17, 0.27, 0.45))
        let url = dir.appendingPathComponent("笔记.inkpad")
        try doc.save(to: url)
        XCTAssertFalse(doc.modified)
        XCTAssertEqual(try Notebook.id(of: url), doc.id)
        XCTAssertNotNil(Notebook.cover(of: url))

        let back = try Document.load(url)
        XCTAssertEqual(back.id, doc.id)
        XCTAssertEqual(back.pages.count, 2)
        XCTAssertEqual(back.pages.map(\.id), doc.pages.map(\.id))
        XCTAssertEqual(back.pages[0].paper, "grid")
        XCTAssertEqual(back.pages[0].color.g, 0.965, accuracy: 1e-9)
        XCTAssertEqual(back.pages[0].items.map(\.id), doc.pages[0].items.map(\.id))
        XCTAssertEqual(back.pages[0].items.map(\.kind), ["s", "s", "h", "t", "t", "i"])
        let s = back.pages[0].items[0] as! Stroke
        XCTAssertEqual(s.tool, "fountain")
        XCTAssertEqual(s.sens, 1.2, accuracy: 1e-9)
        XCTAssertEqual(s.pts.count, 3)
        XCTAssertEqual(s.pts[1].x, 60, accuracy: 0.01)
        XCTAssertTrue((back.pages[0].items[1] as! Stroke).open)
        XCTAssertEqual((back.pages[0].items[3] as! TextItem).text, "你好 Inkpad")
        XCTAssertEqual((back.pages[0].items[4] as! TextItem).bg, RGB(1, 0.93, 0.55))
        XCTAssertNotNil((back.pages[0].items[5] as! ImageItem).source.image)
        XCTAssertTrue(back.pages[1].bookmark)
        XCTAssertEqual(back.pages[1].outline, "第二页")
        XCTAssertEqual((back.pages[1].items[0] as! Stroke).dash, 1)
        XCTAssertEqual(back.coverSpec?.0, "band")

        try Notebook.setID(url, "feedfacefeedfacefeedfacefeedface")
        XCTAssertEqual(try Notebook.id(of: url), "feedfacefeedfacefeedfacefeedface")
        XCTAssertEqual(try Document.load(url).id, "feedfacefeedfacefeedfacefeedface")
        XCTAssertEqual(try Document.load(url).pages[0].items.count, 6)
    }

    func testUndoLeavesTombstones() {
        let doc = Document()
        let page = doc.pages[0]
        let a = Stroke("ball", .black, 1, [Pt(x: 0, y: 0), Pt(x: 5, y: 5)])
        let b = Stroke("ball", .black, 1, [Pt(x: 9, y: 0), Pt(x: 5, y: 5)])
        doc.addItems(page, [a, b])
        doc.removeItems(page, [a])
        XCTAssertEqual(page.items.count, 1)
        XCTAssertTrue(page.gone.contains(a.id))
        doc.undo()
        XCTAssertEqual(page.items.map(\.id), [a.id, b.id])
        XCTAssertFalse(page.gone.contains(a.id))
        doc.undo()
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertTrue(page.gone.contains(a.id) && page.gone.contains(b.id))
        doc.redo()
        XCTAssertEqual(page.items.count, 2)
        XCTAssertTrue(doc.canUndo && doc.canRedo)
    }

    func testMergeItemByItem() throws {
        let doc = sampleDocument()
        let url = dir.appendingPathComponent("m.inkpad")
        try doc.save(to: url)
        let mine = try Document.load(url), theirs = try Document.load(url)
        // I delete the arrow and add a stroke; they delete the tape, add a stroke and a page.
        let arrow = mine.pages[0].items[2]
        mine.removeItems(mine.pages[0], [arrow])
        let myNew = Stroke("ball", .black, 1, [Pt(x: 1, y: 1), Pt(x: 2, y: 2)])
        mine.addItems(mine.pages[0], [myNew])
        let tape = theirs.pages[0].items[1]
        theirs.removeItems(theirs.pages[0], [tape])
        let theirNew = Stroke("ball", .black, 1, [Pt(x: 3, y: 3), Pt(x: 4, y: 4)])
        theirs.addItems(theirs.pages[0], [theirNew])
        let extra = theirs.pages[0].blankLike()
        theirs.perform(.pages(removed: [], added: [(1, extra)]))
        let counts = merge(mine, theirs)
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.2, 1)
        XCTAssertEqual(counts.3, 1)
        XCTAssertEqual(mine.pages.map(\.id), [doc.pages[0].id, extra.id, doc.pages[1].id])
        let ids = Set(mine.pages[0].items.map(\.id))
        XCTAssertTrue(ids.contains(myNew.id) && ids.contains(theirNew.id))
        XCTAssertFalse(ids.contains(arrow.id) || ids.contains(tape.id))
        XCTAssertEqual(mine.pages[0].items.count, 6)
    }

    func testGeometry() {
        var zigzag: [Pt] = []
        for i in 0..<60 { zigzag.append(Pt(x: i % 20 < 10 ? Double(i % 10) * 6 : 60 - Double(i % 10) * 6, y: 50 + Double(i) * 0.2)) }
        XCTAssertTrue(Geom.isScribble(zigzag))
        let line = (0..<30).map { Pt(x: Double($0) * 3, y: 10) }
        XCTAssertFalse(Geom.isScribble(line))
        XCTAssertEqual(Geom.recognizeShape(line)?.kind, "line")
        let circle = (0...40).map { Pt(x: 100 + 40 * cos(Double($0) / 40 * 2 * .pi), y: 100 + 40 * sin(Double($0) / 40 * 2 * .pi)) }
        XCTAssertEqual(Geom.recognizeShape(circle)?.kind, "ellipse")
        let target = Stroke("ball", .black, 1, [Pt(x: 5, y: 52), Pt(x: 55, y: 58)])
        XCTAssertEqual(Geom.scribbleTargets(zigzag, [target]).count, 1)
        let cut = Geom.eraseRuns(line, 45, 0, 45, 20, 4)
        XCTAssertEqual(cut?.runs.count, 2)
        XCTAssertEqual(Geom.lassoPick(circle, [Stroke("ball", .black, 1, [Pt(x: 90, y: 100), Pt(x: 110, y: 100)])]).count, 1)
        XCTAssertEqual(Geom.lassoPick(circle, [Stroke("ball", .black, 1, [Pt(x: 300, y: 100), Pt(x: 310, y: 100)])]).count, 0)
    }

    func testRendering() throws {
        let doc = sampleDocument()
        let image = pageImage(doc.pages[0].snap, scale: 1)
        XCTAssertEqual(image.size.width, 595)
        let pdf = dir.appendingPathComponent("out.pdf")
        try exportPDF(doc, to: pdf)
        // An exported PDF comes back as page backgrounds of the same size.
        let imported = try Document.fromPDF(Data(contentsOf: pdf))
        XCTAssertEqual(imported.pages.count, 2)
        XCTAssertEqual(imported.pages[0].w, 595, accuracy: 0.5)
        XCTAssertEqual(imported.pages[0].h, 842, accuracy: 0.5)
        let saved = dir.appendingPathComponent("pdf.inkpad")
        try imported.save(to: saved)
        let back = try Document.load(saved)
        XCTAssertNotNil(back.pages[1].pdf)
        XCTAssertEqual(back.pages[1].pdfPage, 1)
        XCTAssertTrue(back.pages[0].pdf === back.pages[1].pdf)
        XCTAssertEqual(pageImage(back.pages[0].rotated(1).snap, scale: 0.5).size.width, 421, accuracy: 1)
        for style in coverStyles { XCTAssertEqual(renderCover((style, coverColors[1]), title: "封面").size.height, 300) }
        let board = Document(template: PageTemplate(paper: "dots", board: true))
        XCTAssertTrue(board.pages[0].board)
        XCTAssertEqual(board.pages[0].box.w, 800)
        XCTAssertFalse(board.cover().isEmpty)
    }
}
