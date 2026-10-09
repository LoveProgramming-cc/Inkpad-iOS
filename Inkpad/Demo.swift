#if DEBUG
import UIKit

/// Sample notebooks for trying the app out: launch with the -demo argument.
enum Demo {
    static func populate(_ store: Store) {
        if ProcessInfo.processInfo.arguments.contains("-resetPrefs") {
            // A clean slate for the UI tests: the same notebooks every time.
            for entry in store.entries(store.root) + store.trashed() { try? FileManager.default.removeItem(at: entry.url) }
        }
        guard store.entries(store.root).isEmpty else { return }
        func wave(_ x0: Double, _ y: Double, _ n: Int, _ amp: Double) -> [Pt] {
            (0..<n).map { i in Pt(x: x0 + Double(i) * 4, y: y + sin(Double(i) / 4) * amp, p: 0.35 + 0.3 * sin(Double(i) / 9)) }
        }
        let doc = Document(template: PageTemplate(paper: "ruled"))
        let page = doc.pages[0]
        var items: [Item] = []
        for row in 0..<6 {
            items.append(Stroke("fountain", RGB(0.05, 0.1, 0.35), 1.6, wave(60, 94 + Double(row) * 44, 70 + row * 8, 7)))
        }
        items.append(Stroke("hl", RGB(1.0, 0.88, 0.3), 14, [Pt(x: 60, y: 138), Pt(x: 300, y: 138)]))
        items.append(Shape("rect", 340, 380, 520, 480, RGB(0.94, 0.24, 0.24), 2))
        items.append(Shape("arrow", 200, 430, 330, 430, RGB(0.94, 0.24, 0.24), 2))
        items.append(TextItem(70, 400, "Inkpad on iPad\n与桌面版共用同一格式", 16, .black, wrap: 240))
        items.append(TextItem(360, 540, "便签", 13, RGB(0.16, 0.15, 0.12), wrap: 170, bg: RGB(1.0, 0.93, 0.55)))
        doc.addItems(page, items)
        doc.perform(.pages(removed: [], added: [(1, Page(595, 842, paper: "grid"))]))
        doc.coverSpec = ("ribbon", coverColors[2])
        try? doc.save(to: store.root.appendingPathComponent("课堂笔记.inkpad"))
        _ = try? store.newNotebook(store.root, PageTemplate(paper: "dots", color: paperColors[1].1), name: "草稿")
        // A PDF to write on: the notebook above, exported.
        let pdf = FileManager.default.temporaryDirectory.appendingPathComponent("demo.pdf")
        if (try? exportPDF(doc, to: pdf)) != nil, let data = try? Data(contentsOf: pdf) {
            _ = try? store.importPDF(store.root, name: "讲义", data: data)
        }
        if let folder = try? store.newFolder(store.root, "课程") {
            _ = try? store.newNotebook(folder, PageTemplate(paper: "cornell"), name: "线性代数", cover: ("band", coverColors[3]))
        }
    }
}
#endif
