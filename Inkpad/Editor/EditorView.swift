import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct CanvasHost: UIViewRepresentable {
    let canvas: CanvasView

    func makeUIView(context: Context) -> CanvasView { canvas }
    func updateUIView(_ view: CanvasView, context: Context) {}
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct Shared: Identifiable {
    let id = UUID()
    let urls: [URL]
    init(url: URL) { urls = [url] }
    init(urls: [URL]) { self.urls = urls }
}

/// '1-3, 5' -> [0, 1, 2, 4]; empty means every page (nil). Throws when unreadable.
func pageRange(_ text: String, total: Int) throws -> [Int]? {
    let clean = text.replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "、", with: ",")
        .replacingOccurrences(of: "–", with: "-").trimmingCharacters(in: .whitespaces)
    if clean.isEmpty { return nil }
    var out: [Int] = []
    for part in clean.split(separator: ",", omittingEmptySubsequences: false) {
        let ends = part.trimmingCharacters(in: .whitespaces).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = Int(ends[0].trimmingCharacters(in: .whitespaces)),
              let last = ends.count > 1 ? Int(ends[1].trimmingCharacters(in: .whitespaces)) : first,
              1 <= first, first <= last, last <= total else { throw ZipError(String(part)) }
        for n in first...last where !out.contains(n - 1) { out.append(n - 1) }
    }
    return out
}

/// Buttons on the blue header: white icons, and white with blue ink when checked.
struct HeaderButtonStyle: ButtonStyle {
    var checked = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(checked ? Theme.headerInk : Color.white)
            .frame(minWidth: 38, minHeight: 34)
            .background(checked ? Color.white : Color.white.opacity(configuration.isPressed ? 0.22 : 0),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(checked ? 0.25 : 0), radius: 1.5, y: 1)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

struct EditorView: View {
    @ObservedObject var session: EditorSession
    @EnvironmentObject var app: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// A narrow window (an iPhone, or a slice of the iPad's screen): the tools get a row of their own.
    private var compact: Bool { sizeClass == .compact }
    @ObservedObject var tools = ToolState.shared

    @State private var showSide = false
    @State private var showOptions = true
    @State private var photo: PhotosPickerItem?
    @State private var pickPhoto = false
    @State private var shared: Shared?
    @State private var importingPDF = false
    @State private var prompt: Prompt?
    @State private var promptText = ""
    @State private var photoPage = false     // the picked photo becomes a page of its own
    @State private var rulerOn = false
    @State private var finding = false
    @State private var query = ""
    @State private var findAt = -1
    @State private var findCount = 0
    @FocusState private var findFocus: Bool

    private enum Prompt: Identifiable {
        case rename, goto
        case outline(Page)
        var id: String {
            switch self {
            case .rename: return "rename"
            case .goto: return "goto"
            case .outline(let page): return page.id
            }
        }
    }

    private var doc: Document { session.doc }
    private var canvas: CanvasView { session.canvas }
    private var page: Page { doc.pages[min(max(session.page, 0), doc.pages.count - 1)] }
    private var isBoard: Bool { doc.pages.first?.board ?? false }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                if showSide {
                    Sidebar(session: session, menu: pageMenu, onAdd: { addPages([doc.pages[doc.pages.count - 1].blankLike()], at: doc.pages.count) })
                        .frame(width: compact ? 250 : 290)
                        .transition(.move(edge: .leading))
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1)
                }
                ZStack {
                    CanvasHost(canvas: canvas).ignoresSafeArea(.container, edges: .bottom)
                    floating
                    if finding { findBar }
                }
                .background { shortcuts }
            }
        }
        .background(Color(Theme.canvasUI))
        .statusBarHidden()
        .onChange(of: tools.p.fingerDraw) { _, _ in canvas.applyInputSettings() }
        .onChange(of: tools.p.scrollbars) { _, _ in canvas.applyInputSettings() }
        .onChange(of: tools.p.maxZoom) { _, _ in canvas.applyInputSettings() }
        .onChange(of: tools.p.paging) { _, _ in canvas.setPaging() }
        .onChange(of: tools.p.mouseHand) { _, _ in canvas.applyInputSettings() }
        .onChange(of: tools.tool) { old, new in
            if new != "lasso" { canvas.clearSelection() }
            if new != "laser" { canvas.clearLaser() }
            if old != "eraser" { canvas.previousTool = old }
            canvas.applyInputSettings()   // a finger writes with the laser, whatever the setting
        }
        .onChange(of: tools.p.hiddenTools) { _, hidden in
            if hidden.contains(tools.tool) { tools.tool = "pen" }
            if hidden.contains("ruler") { rulerOn = false }
        }
        .onChange(of: rulerOn) { _, on in canvas.setRuler(on) }
        .onChange(of: query) { _, _ in find() }
        .onChange(of: session.tick) { _, _ in
            if finding { refind() }
        }
        .onAppear {
            canvas.onPullAdd = { side in
                // Pulled past an end: add a page like its neighbour there.
                let pages = doc.pages
                addPages([(side > 0 ? pages[pages.count - 1] : pages[0]).blankLike()], at: side > 0 ? pages.count : 0)
            }
            canvas.onSaveImage = { image in
                let url = temp("png")
                do {
                    try image.pngData()?.write(to: url)
                    shared = Shared(url: url)
                } catch {
                    app.alert = tr("导出失败") + "\n" + error.localizedDescription
                }
            }
            canvas.applyInputSettings()
            if tools.p.hiddenTools.contains(tools.tool) { tools.tool = "pen" }
        }
        .photosPicker(isPresented: $pickPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await insert(item) }
        }
        .fileImporter(isPresented: $importingPDF, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            importPDF(url)
        }
        .sheet(item: $shared) { ShareSheet(items: $0.urls) }
        .alert(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { p in
            if case .goto = p {
                TextField(trf("共 %d 页", doc.pages.count), text: $promptText).keyboardType(.numberPad)
            } else {
                TextField(tr("名称"), text: $promptText)
            }
            Button(tr("取消"), role: .cancel) {}
            Button(tr(p.id == "goto" ? "前往" : "确定")) { answer(p) }
        } message: { p in
            if case .goto = p { Text(trf("共 %d 页", doc.pages.count)) }
        }
    }

    // MARK: header

    private var header: some View {
        VStack(spacing: 0) {
            headerRow.modifier(ClearsWindowControls())
            if compact {
                ScrollView(.horizontal, showsIndicators: false) { toolGroup.padding(.horizontal, 8) }
                    .frame(height: 44)
                    .padding(.bottom, 4)
            }
        }
        .background(Theme.header.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.18)).frame(height: 1).offset(y: 1) }
        .zIndex(1)
    }

    private var headerRow: some View {
        HStack(spacing: 2) {
            Button { app.closeEditor() } label: { Icon("home") }
                .buttonStyle(HeaderButtonStyle())
                .accessibilityLabel(tr("文稿库"))
            PopButton { close in
                MenuList(items: [
                    MenuItem(tr("重命名…"), "rename") { ask(.rename, session.title) },
                    MenuItem(tr("更改封面…"), "cover") { changeCover() },
                    MenuItem(tr("导入 PDF 页面…"), "share") { importingPDF = true },
                    MenuItem(tr("立即保存"), "check_circle") {
                        session.save(wait: true)
                        app.show(tr("已保存"))
                    },
                ], close: close)
            } label: {
                HStack(spacing: 4) {
                    Text(session.title).font(.system(size: 16.5, weight: .semibold)).lineLimit(1)
                    Icon("chevron", 14)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: compact ? 130 : 200)
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(HeaderButtonStyle())
            .accessibilityLabel(tr("笔记本"))
            Rectangle().fill(.white.opacity(0.28)).frame(width: 1, height: 22).padding(.horizontal, 6)
            Button { withAnimation(.easeOut(duration: 0.18)) { showSide.toggle() } } label: { Icon("sidebar") }
                .buttonStyle(HeaderButtonStyle(checked: showSide))
                .accessibilityLabel(tr("页面、大纲与书签"))
            Button { showFind() } label: { Icon("search") }
                .buttonStyle(HeaderButtonStyle())
                .accessibilityLabel(tr("在笔记中查找 (Ctrl+F)"))

            Spacer(minLength: 6)
            if !compact {
                ViewThatFits(in: .horizontal) {
                    toolGroup
                    ScrollView(.horizontal, showsIndicators: false) { toolGroup }
                }
                Spacer(minLength: 6)
            }

            PopButton { close in
                AddPagePanel(session: session, close: close, add: addPages, more: moreTemplates, image: {
                    photoPage = true
                    pickPhoto = true
                }, importPDF: { importingPDF = true })
            } label: { Icon("page_add") }
                .buttonStyle(HeaderButtonStyle())
                .accessibilityLabel(tr("添加页面"))
            PopButton { close in
                MenuList(items: [
                    MenuItem(tr("导出为矢量 PDF…"), "share") { exportPDF() },
                    MenuItem(tr("导出当前页为图片…"), "image") { exportPNG() },
                    MenuItem(tr("导出全部页面为图片…"), "duplicate") { exportPNGAll() },
                    .line,
                    MenuItem(tr("导出为 Goodnotes（实验性）…"), "cover") { exportGoodnotes() },
                    .line,
                    MenuItem(tr("分享笔记本文件"), "cover") {
                        session.save(wait: true)
                        shared = Shared(url: session.url)
                    },
                ], close: close)
            } label: { Icon("share") }
                .buttonStyle(HeaderButtonStyle())
                .accessibilityLabel(tr("导出"))
            PopButton { close in
                PagePanel(session: session, close: close, goto: { ask(.goto, "") }, template: changeTemplate,
                          addAfter: { addPages([page.blankLike()], at: session.page + 1) }, outline: editOutline, about: about)
            } label: { Icon("more") }
                .buttonStyle(HeaderButtonStyle())
                .accessibilityLabel(tr("页面与设置"))
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
    }

    private var toolGroup: some View {
        HStack(spacing: 3) {
            ForEach(toolList.filter { $0.0 == "pen" || !tools.p.hiddenTools.contains($0.0) }, id: \.0) { id, icon, label in
                Button {
                    // Tapping the tool in hand again hides or shows its options.
                    if tools.tool == id {
                        showOptions.toggle()
                    } else {
                        tools.tool = id
                        showOptions = true
                    }
                } label: { Icon(icon) }
                    .buttonStyle(HeaderButtonStyle(checked: tools.tool == id))
                    .accessibilityLabel(tr(label))
            }
            if !tools.p.hiddenTools.contains("image") {
                Button {
                    photoPage = false
                    pickPhoto = true
                } label: { Icon("image") }
                    .buttonStyle(HeaderButtonStyle())
                    .accessibilityLabel(tr("插入图片"))
            }
            if !tools.p.hiddenTools.contains("ruler") {
                Button { rulerOn.toggle() } label: { Icon("ruler") }
                    .buttonStyle(HeaderButtonStyle(checked: rulerOn))
                    .accessibilityLabel(tr("尺子"))
            }
        }
        .padding(3)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    // MARK: bars floating over the canvas

    private var floating: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Pill {
                    Button { canvas.undo() } label: { Icon("undo") }
                        .buttonStyle(PillButtonStyle())
                        .disabled(!doc.canUndo)
                        .keyboardShortcut("z", modifiers: .command)
                        .accessibilityLabel(tr("撤销"))
                    Button { canvas.redo() } label: { Icon("redo") }
                        .buttonStyle(PillButtonStyle())
                        .disabled(!doc.canRedo)
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                        .accessibilityLabel(tr("重做"))
                }
                OptionsPill(tools: tools, clearPage: { PageOps.clear(session, page) })
                    .opacity(showOptions ? 1 : 0)
                    .allowsHitTesting(showOptions)
                    .frame(maxWidth: .infinity)
                // Balances the history pill, so that the options sit in the middle.
                if !compact { Color.clear.frame(width: 90, height: 1) }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            Spacer(minLength: 0)
            HStack {
                // A whiteboard has no edges, so it gets a map instead (the canvas draws it).
                if !isBoard {
                    StatusPill(text: "\(session.page + 1) / \(doc.pages.count) · \(session.zoom)%")
                        .allowsHitTesting(false)
                }
                Spacer()
            }
            .padding(14)
        }
    }

    // MARK: find in notebook

    private var findBar: some View {
        VStack {
            HStack {
                Spacer()
                Pill {
                    HStack(spacing: 6) {
                        Icon("search", 16).foregroundStyle(.secondary)
                        TextField(tr("查找文本框和 PDF 中的文字"), text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($findFocus)
                            .onSubmit {
                                findStep(1)
                                findFocus = true
                            }
                            .accessibilityIdentifier("find-field")
                    }
                    .padding(.horizontal, 10)
                    .frame(width: 240, height: 34)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text(findCount > 0 ? "\(findAt + 1) / \(findCount)" : query.trimmingCharacters(in: .whitespaces).isEmpty ? "" : tr("无结果"))
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 64)
                        .accessibilityIdentifier("find-count")
                    Button { findStep(-1) } label: { Icon("up", 16) }.buttonStyle(PillButtonStyle()).accessibilityLabel(tr("上一个"))
                    Button { findStep(1) } label: { Icon("down", 16) }.buttonStyle(PillButtonStyle()).accessibilityLabel(tr("下一个"))
                    Button { hideFind() } label: { Icon("close", 16) }.buttonStyle(PillButtonStyle()).accessibilityLabel(tr("关闭"))
                }
            }
            .padding(.top, 62)
            .padding(.trailing, 12)
            Spacer()
        }
    }

    private func showFind() {
        finding = true
        findFocus = true
        find()
    }

    private func hideFind() {
        finding = false
        findFocus = false
        canvas.setMarks([], current: -1)
    }

    private func hits() -> [(Int, Box)] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return doc.pages.enumerated().flatMap { i, page in findText(page, query).map { (i, $0) } }
    }

    private func find() {
        guard finding else { return }
        let marks = hits()
        findCount = marks.count
        findAt = marks.isEmpty ? -1 : 0
        canvas.setMarks(marks, current: findAt)
    }

    /// The pages changed under the search: mark the hits again, without moving the view.
    private func refind() {
        let marks = hits()
        findCount = marks.count
        findAt = marks.isEmpty ? -1 : min(max(findAt, 0), marks.count - 1)
        canvas.marks = marks
        canvas.markAt = findAt
        canvas.refreshOverlay()
    }

    private func findStep(_ step: Int) {
        guard findCount > 0 else { return }
        findAt = (findAt + step + findCount) % findCount
        canvas.setMarks(canvas.marks, current: findAt)
    }

    // MARK: keyboard

    /// The desktop's shortcuts, for a keyboard attached to the iPad (with Command for Ctrl).
    private var shortcuts: some View {
        let typing = finding || prompt != nil
        return Group {
            Button("") { showFind() }.keyboardShortcut("f", modifiers: .command)
            Button("") { canvas.redo() }.keyboardShortcut("y", modifiers: .command)
            Button("") { canvas.copySelection() }.keyboardShortcut("c", modifiers: .command).disabled(typing)
            Button("") { canvas.pasteAnything() }.keyboardShortcut("v", modifiers: .command).disabled(typing)
            Button("") {
                session.save(wait: true)
                app.show(tr("已保存"))
            }.keyboardShortcut("s", modifiers: .command)
            Button("") { exportPDF() }.keyboardShortcut("e", modifiers: .command)
            Button("") { canvas.zoomBy(1.2) }.keyboardShortcut("=", modifiers: .command)
            Button("") { canvas.zoomBy(1.2) }.keyboardShortcut("+", modifiers: .command)
            Button("") { canvas.zoomBy(1 / 1.2) }.keyboardShortcut("-", modifiers: .command)
            Button("") { canvas.fitWidth() }.keyboardShortcut("0", modifiers: .command)
            Button("") { ask(.goto, "") }.keyboardShortcut("g", modifiers: .command)
            Group {
                // The arrows turn the pages, unless they are moving the caret in some text.
                Button("") { turnPage(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { turnPage(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { turnPage(-1) }.keyboardShortcut(.pageUp, modifiers: [])
                Button("") { turnPage(1) }.keyboardShortcut(.pageDown, modifiers: [])
                Button("") { canvas.deleteSelection() }.keyboardShortcut(.delete, modifiers: [])
                Button("") { canvas.deleteSelection() }.keyboardShortcut(.deleteForward, modifiers: [])
            }
            .disabled(typing)
            Button("") {
                if finding {
                    hideFind()
                } else {
                    canvas.cancelOp()
                    canvas.clearSelection()
                }
            }.keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func turnPage(_ step: Int) {
        let i = session.page + step
        if doc.pages.indices.contains(i) { canvas.scrollToPage(i) }
    }

    // MARK: prompts

    private var promptTitle: String {
        switch prompt {
        case .rename: return tr("重命名笔记本")
        case .goto: return tr("前往页面")
        default: return tr("添加到大纲")
        }
    }

    private func ask(_ p: Prompt, _ text: String) {
        promptText = text
        prompt = p
    }

    private func answer(_ p: Prompt) {
        let text = promptText.trimmingCharacters(in: .whitespaces)
        switch p {
        case .rename:
            session.save(wait: true)
            do {
                session.moved(to: try app.store.rename(session.url, text))
                if doc.coverSpec != nil { doc.setCover(doc.coverSpec) }   // the cover carries the name
            } catch {
                app.alert = tr("重命名失败") + "\n" + error.localizedDescription
            }
        case .goto:
            if let n = Int(text) { canvas.scrollToPage(max(1, min(doc.pages.count, n)) - 1) }
        case .outline(let page):
            if !text.isEmpty {
                page.outline = text
                doc.touch()
            }
        }
    }

    private func editOutline(_ page: Page) {
        if page.outline != nil {
            page.outline = nil
            doc.touch()
        } else if let i = doc.pages.firstIndex(where: { $0 === page }) {
            ask(.outline(page), trf("第 %d 页", i + 1))
        }
    }

    // MARK: pages

    private func addPages(_ pages: [Page], at index: Int) {
        let i = max(0, min(doc.pages.count, index))
        doc.perform(.pages(removed: [], added: pages.enumerated().map { (i + $0.offset, $0.element) }))
        canvas.scrollToPage(i)
    }

    private func addIndex() -> Int {
        switch tools.p.addPos {
        case "last": return doc.pages.count
        case "before": return session.page
        default: return session.page + 1
        }
    }

    private func moreTemplates() {
        let like = page
        app.present(PaperDialog(heading: like.board ? tr("添加白板") : tr("添加页面"), action: tr("添加"), start: like.template, board: like.board, withName: false) { template, _, _ in
            addPages([Page(template: template)], at: addIndex())
        })
    }

    private func changeTemplate(_ page: Page) {
        if page.pdf != nil {
            app.show(tr("PDF 页面不能更换纸张模板"))
            return
        }
        app.present(PaperDialog(heading: tr("纸张样式"), action: tr("应用"), start: page.template, board: page.board, withName: false) { template, _, _ in
            if !page.board { tools.template = template }
            if template != page.template { doc.perform(.template(page, old: page.template, new: template)) }
        })
    }

    private func about() {
        app.present(AboutDialog(), width: 360, height: nil)
    }

    private func changeCover() {
        app.present(CoverDialog(current: doc.coverSpec, title: session.title) { doc.setCover($0) }, width: 340, height: nil)
    }

    /// The menu behind a thumbnail's dots: everything that can be done to one page.
    private func pageMenu(_ page: Page) -> [MenuItem] {
        var rows = [
            MenuItem(tr(page.bookmark ? "移除书签" : "添加书签"), page.bookmark ? "bookmark_filled" : "bookmark") {
                page.bookmark.toggle()
                doc.touch()
            },
            MenuItem(tr(page.outline != nil ? "从大纲移除" : "将页面添加到大纲…"), "outline") { editOutline(page) },
            .line,
            MenuItem(tr("拷贝页面"), "copy") {
                PageOps.clip = page.clone()
                app.show(tr("已拷贝页面"))
            },
        ]
        if let clip = PageOps.clip {
            rows.append(MenuItem(tr("粘贴页面"), "paste") { PageOps.insert(session, after: page, clip.clone()) })
        }
        rows += [
            MenuItem(tr("复制页面"), "duplicate") { PageOps.duplicate(session, page) },
            MenuItem(tr("在后面添加页面"), "page_add") { PageOps.insert(session, after: page, page.blankLike()) },
            MenuItem(tr("顺时针旋转"), "rotate_cw") { PageOps.rotate(session, page, 1) },
            MenuItem(tr("逆时针旋转"), "reset") { PageOps.rotate(session, page, 3) },
            MenuItem(tr("旋转 180°"), "syncing") { PageOps.rotate(session, page, 2) },
            MenuItem(tr("更改模板…"), "grid") { changeTemplate(page) },
            .line,
            MenuItem(tr("清除页面"), "eraser", danger: true) { PageOps.clear(session, page) },
            MenuItem(tr("删除页面"), "trash", danger: true) { PageOps.delete(session, page) },
        ]
        return rows
    }

    private func importPDF(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let pages = try Document.pdfPages(Data(contentsOf: url))
            addPages(pages, at: addIndex())
            app.show(trf("已导入 %d 页", pages.count))
        } catch {
            app.alert = tr("无法导入 PDF") + "\n" + error.localizedDescription
        }
    }

    // MARK: pictures and export

    private func insert(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
            app.alert = tr("无法读取图片")
            return
        }
        // Photos are far larger than a page needs; keep the notebook a sensible size.
        let longest = max(image.size.width, image.size.height) * image.scale
        let k = min(1, 1600 / longest)
        let size = CGSize(width: (image.size.width * image.scale * k).rounded(), height: (image.size.height * image.scale * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let png = small.pngData() else { return }
        if photoPage {
            // A page of its own for the picture, like the one it is added next to.
            photoPage = false
            let new = page.blankLike()
            let w = Double(size.width), h = Double(size.height)
            let box = new.board ? Box(new.w / 2 - 300, new.h / 2 - 220, new.w / 2 + 300, new.h / 2 + 220) : Box(0, 0, new.w, new.h)
            let k = min(box.w * 0.9 / w, box.h * 0.9 / h, 1.5)
            new.items = [ImageItem((box.x0 + box.x1 - w * k) / 2, (box.y0 + box.y1 - h * k) / 2, w * k, h * k, ImageData(png))]
            addPages([new], at: addIndex())
            return
        }
        canvas.insertImage(png, width: size.width * 0.5, height: size.height * 0.5)
    }

    private func temp(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(session.title + "." + ext)
    }

    /// Ask which pages and which layers to export, as the desktop does before every export.
    private func askExport(_ heading: String, range: Bool, then: @escaping ([Int]?, Bool, Bool) -> Void) {
        app.present(ExportDialog(heading: heading, total: range ? doc.pages.count : nil) { pages, paper, ink in then(pages, paper, ink) },
                    width: 360, height: nil)
    }

    private func share(_ make: () throws -> [URL]) {
        do {
            let urls = try make()
            // After the dialog card has gone: a sheet cannot come up underneath it.
            DispatchQueue.main.async { shared = Shared(urls: urls) }
        } catch {
            app.alert = tr("导出失败") + "\n" + error.localizedDescription
        }
    }

    private func exportPDF() {
        askExport(tr("导出为 PDF"), range: true) { pages, paper, ink in
            share {
                let url = temp("pdf")
                try Inkpad.exportPDF(doc, to: url, pages: pages, paper: paper, ink: ink)
                return [url]
            }
        }
    }

    private func exportPNG() {
        let i = session.page
        askExport(tr("导出当前页为图片"), range: false) { _, paper, ink in
            share { [try writePNG(i, paper, ink, name: "\(session.title)-\(i + 1).png")] }
        }
    }

    private func exportPNGAll() {
        askExport(tr("导出全部页面为图片"), range: true) { pages, paper, ink in
            share {
                let urls = try (pages ?? Array(doc.pages.indices)).map { try writePNG($0, paper, ink, name: String(format: "%@-%02d.png", session.title, $0 + 1)) }
                app.show(trf("已导出 %d 张图片", urls.count))
                return urls
            }
        }
    }

    private func writePNG(_ i: Int, _ paper: Bool, _ ink: Bool, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        guard let png = pageImage(doc.pages[i].snap, scale: 3, paper: paper, ink: ink).pngData() else { throw ZipError(tr("导出失败")) }
        try png.write(to: url)
        return url
    }

    private func exportGoodnotes() {
        share {
            let url = temp("goodnotes")
            try Goodnotes.save(doc, to: url, title: session.title)
            return [url]
        }
    }
}

/// Which pages and which layers to export.
struct ExportDialog: View {
    let heading: String
    let total: Int?          // the number of pages, when a range can be given
    let onOK: ([Int]?, Bool, Bool) -> Void
    @EnvironmentObject private var app: AppModel
    @State private var range = ""
    @State private var what = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading).font(.system(size: 19, weight: .bold)).frame(maxWidth: .infinity).padding(.top, 26).padding(.bottom, 6)
            if let total {
                Text(trf("页面范围（共 %d 页）", total))
                TextField(tr("全部页面；也可填 1-3,5"), text: $range)
                    .keyboardType(.numbersAndPunctuation)
                    .padding(.horizontal, 10)
                    .frame(height: 38)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .onSubmit(done)
                    .accessibilityIdentifier("export-range")
            }
            Text(tr("导出内容")).padding(.top, 4)
            Dropdown(options: [tr("笔迹和背景"), tr("仅笔迹（透明背景）"), tr("仅背景")], index: $what)
            HStack(spacing: 10) {
                Button { app.dismissDialog() } label: { Text(tr("取消")).frame(maxWidth: .infinity) }.buttonStyle(DialogButtonStyle())
                Button(action: done) { Text(tr("导出")).frame(maxWidth: .infinity) }.buttonStyle(DialogButtonStyle(suggested: true))
            }
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
        .background(Theme.windowBg)
    }

    private func done() {
        var picked: [Int]?
        if let total {
            do {
                picked = try pageRange(range, total: total)
            } catch {
                app.show(tr("页面范围无法识别，请按 1-3,5 的格式填写"))
                return
            }
        }
        app.dismissDialog()
        onOK(picked, what != 1, what != 2)
    }
}

/// What the app is, as the desktop's About window says it.
struct AboutDialog: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        VStack(spacing: 8) {
            if let icon = UIImage(named: "AppIcon") ?? Self.icon {
                Image(uiImage: icon).resizable().frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            }
            Text("Inkpad").font(.system(size: 26, weight: .heavy)).padding(.top, 6)
            Text(version).font(.system(size: 14)).foregroundStyle(Theme.accentText)
                .padding(.horizontal, 12).padding(.vertical, 3).background(Theme.accent.opacity(0.14), in: Capsule())
            Text(tr("GNOME 上的手写笔记与画板。\n支持手写笔压感、涂画以擦除、PDF 批注与矢量导出。\n笔记保存在：") + Platform.libraryPlace)
                .font(.system(size: 15)).multilineTextAlignment(.center).padding(.top, 8)
            Button { app.dismissDialog() } label: { Text(tr("好")).frame(maxWidth: .infinity) }
                .buttonStyle(DialogButtonStyle())
                .padding(.top, 14)
        }
        .padding(24)
        .background(Theme.windowBg)
    }

    /// The app's own icon, as the home screen shows it.
    static var icon: UIImage? {
        guard let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let name = (primary["CFBundleIconFiles"] as? [String])?.last else { return nil }
        return UIImage(named: name)
    }
}

/// What the page menu and the page panel can do to a page.
@MainActor
enum PageOps {
    static var clip: Page?   // a copied page

    static func insert(_ s: EditorSession, after page: Page, _ new: Page) {
        guard let i = s.doc.pages.firstIndex(where: { $0 === page }) else { return }
        s.doc.perform(.pages(removed: [], added: [(i + 1, new)]))
        s.canvas.scrollToPage(i + 1)
    }

    static func duplicate(_ s: EditorSession, _ page: Page) { insert(s, after: page, page.clone()) }

    static func rotate(_ s: EditorSession, _ page: Page, _ k: Int) {
        guard !page.board, let i = s.doc.pages.firstIndex(where: { $0 === page }) else { return }
        s.doc.perform(.pages(removed: [(i, page)], added: [(i, page.rotated(k))]))
    }

    static func clear(_ s: EditorSession, _ page: Page) {
        if !page.items.isEmpty {
            s.canvas.clearSelection()
            s.doc.removeItems(page, page.items)
        }
    }

    static func delete(_ s: EditorSession, _ page: Page) {
        guard let i = s.doc.pages.firstIndex(where: { $0 === page }) else { return }
        let added = s.doc.pages.count == 1 ? [(0, page.blankLike())] : []
        s.doc.perform(.pages(removed: [(i, page)], added: added))
    }
}

// MARK: tool options

/// The options of the chosen tool, in the pill that floats at the top of the canvas.
struct OptionsPill: View {
    @ObservedObject var tools: ToolState
    let clearPage: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Pill { content(hint: true) }
            Pill { content(hint: false) }
            ScrollView(.horizontal, showsIndicators: false) { Pill { content(hint: false) }.padding(.horizontal, 4).padding(.bottom, 16) }
        }
    }

    @ViewBuilder
    private func content(hint: Bool) -> some View {
        switch tools.tool {
        case "pen":
            dropdown(tools.p.penType == "ball" ? "ball" : tools.p.penType == "brush" ? "brush" : "fountain", nil, tr("笔设置")) { _ in PenPanel(tools: tools) }
            PillSeparator()
            penWeights
            PillSeparator()
            ColorSlots(colors: $tools.p.penColors, index: $tools.p.penColor, title: tr("笔颜色"))
        case "tape":
            group([(0, 3.5, "细"), (1, 5.5, "中"), (2, 7.5, "粗")], $tools.p.tapeW) { Mark(kind: .weight($0)) }
            PillSeparator()
            fixed(tapeColors, $tools.p.tapeColor)
            if hint {
                PillSeparator()
                note(tr("画过要遮住的内容；用手指或鼠标点一下胶带可掀开或盖回"))
            }
        case "note":
            fixed(noteColors, $tools.p.noteColor)
            if hint {
                PillSeparator()
                note(tr("点击页面放置便签，再点便签可修改"))
            }
        case "hl":
            WeightSlots(widths: $tools.p.hlWidths, slot: $tools.p.hlW, low: 3, high: 40, look: 0.34, tools: tools)
            PillSeparator()
            ColorSlots(colors: $tools.p.hlColors, index: $tools.p.hlColor, title: tr("荧光笔颜色"))
        case "eraser":
            dropdown("eraser", tr(tools.p.eraserMode == "stroke" ? "笔画" : "标准"), tr("橡皮擦设置")) { close in
                EraserPanel(tools: tools) {
                    close()
                    clearPage()
                }
            }
            PillSeparator()
            group([(0, 2.5, "小"), (1, 4.5, "中"), (2, 7, "大")], $tools.p.eraserSize) { Mark(kind: .dot($0)) }
        case "shape":
            ForEach(shapeList, id: \.0) { id, icon, label in
                Button { tools.p.shapeKind = id } label: { Icon(icon) }
                    .buttonStyle(PillButtonStyle(checked: tools.p.shapeKind == id))
                    .accessibilityLabel(tr(label))
            }
            PillSeparator()
            penWeights
            PillSeparator()
            ColorSlots(colors: $tools.p.penColors, index: $tools.p.penColor, title: tr("笔颜色"))
        case "laser":
            ForEach([("dot", "laser_dot", "点：跟随笔尖的光点"), ("trail", "laser_trail", "轨迹：画出的线约一秒后消失")], id: \.0) { id, icon, tip in
                Button { tools.p.laserMode = id } label: { Icon(icon) }
                    .buttonStyle(PillButtonStyle(checked: tools.p.laserMode == id))
                    .accessibilityLabel(tr(tip))
            }
            PillSeparator()
            fixed(laserColors, $tools.p.laserColor)
        case "text":
            group([(0, 0.6, "小"), (1, 0.85, "中"), (2, 1.15, "大")], $tools.p.textSize) { Mark(kind: .letter($0)) }
            PillSeparator()
            ColorSlots(colors: $tools.p.penColors, index: $tools.p.penColor, title: tr("笔颜色"))
        default:
            dropdown(tools.p.lassoRect ? "lasso_rect" : "lasso", tr(tools.p.lassoRect ? "长方形" : "自由"), tr("套索设置")) { _ in LassoPanel(tools: tools) }
            if hint {
                PillSeparator()
                note(tr("拖动移动 · 右下角手柄缩放"))
            }
        }
    }

    private var penWeights: some View {
        WeightSlots(widths: Binding(get: { tools.pen.widths }, set: { tools.pen.widths = $0 }),
                    slot: Binding(get: { tools.pen.slot }, set: { tools.pen.slot = $0 }), low: 0.3, high: 8, look: 1.3, tools: tools)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 13.5)).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 6).padding(.trailing, 10).fixedSize()
    }

    /// The accent-tinted button that opens a tool's settings (.drop).
    private func dropdown<P: View>(_ icon: String, _ label: String?, _ tip: String, @ViewBuilder panel: @escaping (@escaping () -> Void) -> P) -> some View {
        PopButton(content: panel) {
            HStack(spacing: 4) {
                Icon(icon)
                if let label { Text(label).font(.system(size: 15)) }
                Icon("chevron", 14)
            }
            .padding(.leading, 6)
            .padding(.trailing, 2)
        }
        .buttonStyle(PillButtonStyle(tint: Theme.accent, wide: true))
        .accessibilityLabel(tip)
    }

    /// Radio buttons for a value with three settings.
    private func group<V: View>(_ entries: [(Int, Double, String)], _ value: Binding<Int>, @ViewBuilder icon: @escaping (Double) -> V) -> some View {
        ForEach(entries, id: \.0) { i, look, tip in
            Button { value.wrappedValue = i } label: { icon(look) }
                .buttonStyle(PillButtonStyle(checked: value.wrappedValue == i))
                .accessibilityLabel(tr(tip))
        }
    }

    private func fixed(_ colors: [RGB], _ index: Binding<Int>) -> some View {
        ForEach(colors.indices, id: \.self) { i in
            Button { index.wrappedValue = i } label: { Swatch(color: colors[i]) }
                .buttonStyle(PillButtonStyle(checked: index.wrappedValue == i, round: true))
        }
    }
}

/// Thickness presets: tap to select, tap the selected one to set its width.
struct WeightSlots: View {
    @Binding var widths: [Double]
    @Binding var slot: Int
    let low: Double
    let high: Double
    let look: Double
    @ObservedObject var tools: ToolState

    var body: some View {
        ForEach(widths.indices, id: \.self) { i in
            let mark = Mark(kind: .weight(max(0.8, min(7.5, widths[i] * look))))
            if i == slot {
                PopButton { _ in
                    WidthPanel(width: $widths[i], low: low, high: high, marker: tools.tool == "hl", color: tools.tool == "hl" ? tools.hlColor : tools.penColor)
                } label: { mark }
                    .buttonStyle(PillButtonStyle(checked: true))
                    .accessibilityLabel(tr("调整粗细"))
            } else {
                Button { slot = i } label: { mark }
                    .buttonStyle(PillButtonStyle())
                    .accessibilityLabel(String(format: "%.1f pt", widths[i]))
            }
        }
    }
}

/// A stroke drawn by the same code that draws on the page.
struct StrokePreview: View {
    let tool: String
    let color: RGB
    let width: Double
    var sens = 1.0
    var dash = 0
    var amp = 7.0

    var body: some View {
        Canvas { g, size in
            let w = Double(size.width), h = Double(size.height)
            let pts = (0...60).map { i -> Pt in
                let t = Double(i) / 60
                return Pt(x: 20 + (w - 40) * t, y: h / 2 + amp * sin(t * 2 * .pi + .pi), p: 0.12 + 0.85 * sin(t * .pi))
            }
            let stroke = Stroke(tool, color, width, pts, sens: sens, dash: dash)
            g.withCGContext { stroke.draw($0, DrawEnv(onDark: true)) }
        }
    }
}

struct WidthPanel: View {
    @Binding var width: Double
    let low: Double
    let high: Double
    let marker: Bool
    let color: RGB

    var body: some View {
        Panel(title: tr("粗细"), width: 280) {
            StrokePreview(tool: marker ? "hl" : "ball", color: color, width: width).frame(height: 44)
            HStack(spacing: 6) {
                Button { width = max(low, ((width - 0.1) * 10).rounded() / 10) } label: { Icon("minus", 16).frame(width: 30, height: 30) }
                Slider(value: $width, in: low...high, step: 0.1).tint(Theme.accent)
                Button { width = min(high, ((width + 0.1) * 10).rounded() / 10) } label: { Icon("plus", 16).frame(width: 30, height: 30) }
            }
            .buttonStyle(.plain)
            Text(String(format: "%.1f pt", width)).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// Colour slots: tap to select, tap the selected one to edit or remove it, + adds one.
struct ColorSlots: View {
    @Binding var colors: [[Double]]
    @Binding var index: Int
    let title: String

    var body: some View {
        ForEach(colors.indices, id: \.self) { i in
            if i == index {
                PopButton { close in PalettePanel(colors: $colors, index: $index, title: title, add: false, close: close) } label: {
                    Swatch(color: RGB(colors[i]), chevron: true)
                }
                .buttonStyle(PillButtonStyle(checked: true, round: true))
                .accessibilityLabel(tr("更改或删除此颜色"))
            } else {
                Button { index = i } label: { Swatch(color: RGB(colors[i])) }
                    .buttonStyle(PillButtonStyle(round: true))
            }
        }
        if colors.count < 9 {
            PopButton { close in PalettePanel(colors: $colors, index: $index, title: tr("添加颜色"), add: true, close: close) } label: {
                Icon("plus", 16)
            }
            .buttonStyle(PillButtonStyle(round: true))
            .accessibilityLabel(tr("添加颜色"))
        }
    }
}

struct PalettePanel: View {
    @Binding var colors: [[Double]]
    @Binding var index: Int
    let title: String
    let add: Bool
    let close: () -> Void
    @State private var custom = Color.black
    @State private var picking = false

    private var current: RGB? { add || !colors.indices.contains(index) ? nil : RGB(colors[index]) }

    var body: some View {
        Panel(title: title, width: nil) {
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<5, id: \.self) { col in
                            let c = palette[row * 5 + col]
                            Button { choose(c) } label: { Swatch(color: c, size: 26) }
                                .buttonStyle(PillButtonStyle(checked: current.map { near($0, c) } ?? false, round: true))
                        }
                    }
                }
                GridRow {
                    ColorPicker("", selection: $custom, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 34, height: 34)
                        .accessibilityLabel(tr("自定义颜色"))
                        .onChange(of: custom) { _, new in
                            if picking { set(RGB(new)) }
                        }
                }
            }
            if !add && colors.count > 1 {
                Divider()
                Button {
                    colors.remove(at: index)
                    index = min(index, colors.count - 1)
                    close()
                } label: {
                    Text(tr("删除此颜色")).foregroundStyle(Theme.danger)
                }
                .buttonStyle(RowStyle())
            }
        }
        .onAppear {
            custom = (current ?? .black).color
            DispatchQueue.main.async { picking = true }
        }
    }

    private func near(_ a: RGB, _ b: RGB) -> Bool {
        max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b)) < 0.02
    }

    /// Put a colour in the slot (a new slot the first time, when adding).
    private func set(_ c: RGB) {
        if add && !added {
            colors.append(c.list)
            index = colors.count - 1
            added = true
        } else if colors.indices.contains(index) {
            colors[index] = c.list
        }
    }

    @State private var added = false

    private func choose(_ c: RGB) {
        set(c)
        close()
    }
}

struct PenPanel: View {
    @ObservedObject var tools: ToolState

    private var name: String { tr(penList.first { $0.0 == tools.p.penType }?.2 ?? "钢笔") }

    var body: some View {
        Panel(title: name, width: nil) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    StrokePreview(tool: tools.p.penType, color: tools.penColor, width: tools.penWidth * 1.5, sens: tools.penSens, dash: tools.pen.dash, amp: 22)
                        .frame(height: 84)
                    ChoiceRow(entries: penList.map { ($0.0, tr($0.2)) }, value: $tools.p.penType) { id in
                        Icon(penList.first { $0.0 == id }?.1 ?? "pen")
                    }
                    Divider()
                    Caption(tr("笔画样式"))
                    ChoiceRow(entries: [(0, tr("实线")), (1, tr("虚线")), (2, tr("点线"))],
                              value: Binding(get: { tools.pen.dash }, set: { tools.pen.dash = $0 })) { Mark(kind: .lineStyle($0)) }
                }
                .frame(width: 280)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ScaleRow(text: tr("笔尖"), value: Binding(
                        get: { max(0, min(100, ((tools.penWidth - 0.3) / 0.047).rounded())) },
                        set: { tools.pen.widths[tools.pen.slot] = ((0.3 + $0 * 0.047) * 100).rounded() / 100 }))
                    Text(String(format: "%.2f mm", tools.penWidth * 0.3528)).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    ScaleRow(text: tr("压力灵敏度"), value: Binding(get: { tools.pen.sens }, set: { tools.pen.sens = $0 }))
                    ScaleRow(text: tr("画笔稳定性"), value: Binding(get: { tools.pen.stab }, set: { tools.pen.stab = $0 }))
                    Divider()
                    Caption(tr("设置"))
                    SwitchRow(text: tr("长按绘制规则形状"), isOn: $tools.p.holdShape)
                    SwitchRow(text: tr("涂画以擦除"), isOn: $tools.p.scribbleErase)
                    Button {
                        tools.p.pens[tools.p.penType] = Prefs().pens[tools.p.penType]
                    } label: {
                        Icon("reset", 18).frame(width: 34, height: 30)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityLabel(tr("恢复此笔的默认设置"))
                }
                .frame(width: 280)
            }
        }
    }
}

struct EraserPanel: View {
    @ObservedObject var tools: ToolState
    let clearPage: () -> Void

    var body: some View {
        Panel(title: tr("橡皮擦")) {
            ChoiceRow(entries: [("standard", tr("标准")), ("stroke", tr("笔画"))], value: $tools.p.eraserMode) { Icon($0 == "stroke" ? "ball" : "eraser") }
            Caption(tr("标准橡皮擦只擦掉碰到的部分；笔画橡皮擦一次擦除整条笔画。"))
            Divider()
            Caption(tr("橡皮擦筛选"))
            ForEach([("pen", "pen", "笔"), ("hl", "highlighter", "荧光笔"), ("shape", "shapes", "形状")], id: \.0) { id, icon, label in
                SwitchRow(text: tr(label), icon: icon, isOn: member($tools.p.eraseFilter, id))
            }
            Caption(tr("如工具已关闭，则橡皮擦不会擦除其留下的痕迹。"))
            Divider()
            SwitchRow(text: tr("自动取消选择"), isOn: $tools.p.eraserAuto)
            Button(action: clearPage) { Text(tr("清除页面")).foregroundStyle(Theme.danger) }
                .buttonStyle(RowStyle())
                .padding(.horizontal, -12)
        }
    }
}

struct LassoPanel: View {
    @ObservedObject var tools: ToolState

    var body: some View {
        Panel(title: tr("套索选取")) {
            Caption(tr("套索类型"))
            ChoiceRow(entries: [(false, tr("自由")), (true, tr("长方形"))], value: $tools.p.lassoRect) { Icon($0 ? "lasso_rect" : "lasso") }
            Caption(tr("包含在选取区域中的内容"))
            ForEach([("ink", "手写内容"), ("image", "图像"), ("shape", "形状与箭头"), ("text", "文本框")], id: \.0) { id, label in
                SwitchRow(text: tr(label), isOn: member($tools.p.lassoFilter, id))
            }
        }
    }
}

/// Whether a name is in a list, as a switch can bind to.
private func member(_ list: Binding<[String]>, _ name: String) -> Binding<Bool> {
    Binding(get: { list.wrappedValue.contains(name) }, set: { on in
        var values = list.wrappedValue.filter { $0 != name }
        if on { values.append(name) }
        list.wrappedValue = values
    })
}

// MARK: header popovers

struct AddPagePanel: View {
    @ObservedObject var session: EditorSession
    @ObservedObject var tools = ToolState.shared
    let close: () -> Void
    let add: ([Page], Int) -> Void
    let more: () -> Void
    let image: () -> Void
    let importPDF: () -> Void

    private var page: Page { session.doc.pages[min(session.page, session.doc.pages.count - 1)] }

    private var index: Int {
        switch tools.p.addPos {
        case "last": return session.doc.pages.count
        case "before": return session.page
        default: return session.page + 1
        }
    }

    var body: some View {
        let blank = page.blankLike()
        Panel(title: tr(page.board ? "添加白板" : "添加页面"), width: 320) {
            Linked(entries: [("before", tr("在此之前")), ("after", tr("在此之后")), ("last", tr("最后一页"))], value: $tools.p.addPos)
            Caption(tr("模板"))
            Button {
                close()
                add([blank], index)
            } label: {
                VStack(spacing: 6) {
                    PageThumb(page: blank, stamp: "blank-\(blank.paper)-\(blank.color.list)-\(blank.w)x\(blank.h)-\(blank.board)")
                        .frame(width: blank.board ? 104 : 78, height: blank.board ? 78 : 104)
                        .thumb()
                    Text(tr("当前模板")).font(.subheadline)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
            VStack(spacing: 0) {
                ForEach([("更多模板…", "grid", more), ("图像…", "image", image), ("导入 PDF…", "share", importPDF)], id: \.0) { label, icon, action in
                    Button {
                        close()
                        action()
                    } label: {
                        HStack(spacing: 12) {
                            Icon(icon)
                            Text(tr(label))
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(RowStyle())
                }
            }
            .padding(.horizontal, -12)
        }
    }
}

/// The header's "more" panel: page actions as tiles, then view options and the rest.
struct PagePanel: View {
    @ObservedObject var session: EditorSession
    @EnvironmentObject var app: AppModel
    @ObservedObject var tools = ToolState.shared
    let close: () -> Void
    let goto: () -> Void
    let template: (Page) -> Void
    let addAfter: () -> Void
    let outline: (Page) -> Void
    let about: () -> Void

    private var page: Page { session.doc.pages[min(session.page, session.doc.pages.count - 1)] }

    private struct Tile: Identifiable {
        let id: String
        let icon: String
        let stays: Bool
        let action: () -> Void
    }

    private var tiles: [Tile] {
        let page = page, doc = session.doc
        var list = [
            Tile(id: page.bookmark ? "移除书签" : "书签", icon: page.bookmark ? "bookmark_filled" : "bookmark", stays: true) {
                page.bookmark.toggle()
                doc.touch()
            },
            Tile(id: "大纲", icon: "outline", stays: page.outline != nil) { outline(page) },
            Tile(id: "模板", icon: "grid", stays: false) { template(page) },
            Tile(id: "加页", icon: "page_add", stays: true, action: addAfter),
            Tile(id: "拷贝", icon: "copy", stays: true) {
                PageOps.clip = page.clone()
                session.tick += 1
            },
            Tile(id: "复制", icon: "duplicate", stays: true) { PageOps.duplicate(session, page) },
            Tile(id: "左转", icon: "reset", stays: true) { PageOps.rotate(session, page, 3) },
            Tile(id: "右转", icon: "rotate_cw", stays: true) { PageOps.rotate(session, page, 1) },
        ]
        if let clip = PageOps.clip {
            list.append(Tile(id: "粘贴", icon: "paste", stays: true) { PageOps.insert(session, after: page, clip.clone()) })
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(trf("第 %d / %d 页", session.page + 1, session.doc.pages.count)).font(.system(size: 18, weight: .bold))
                Spacer()
                Button(tr("前往…")) {
                    close()
                    goto()
                }
                .font(.subheadline)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(Color.primary.opacity(0.1), in: Capsule())
                .buttonStyle(.plain)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(tiles) { tile in
                    Button {
                        if !tile.stays { close() }
                        tile.action()
                    } label: {
                        VStack(spacing: 5) {
                            Icon(tile.icon)
                            Text(tr(tile.id)).font(.caption).lineLimit(1)
                        }
                        .padding(.top, 9)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 0) {
                zoomButton { Icon("minus", 16) } action: { session.canvas.zoomBy(1 / 1.2) }
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 34)
                zoomButton { Text(tr("适合宽度")).font(.subheadline) } action: { session.canvas.fitWidth() }
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 34)
                zoomButton { Icon("plus", 16) } action: { session.canvas.zoomBy(1.2) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.top, 4)
            VStack(spacing: 8) {
                SwitchRow(text: tr("涂画以擦除"), isOn: $tools.p.scribbleErase)
                SwitchRow(text: tr("用手指书写"), isOn: $tools.p.fingerDraw)
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 2), spacing: 2) {
                row("settings", tr("设置…")) {
                    close()
                    app.showSettings = true
                }
                row("info", tr("关于")) {
                    close()
                    about()
                }
                row("paste", tr("粘贴")) {
                    close()
                    session.canvas.pasteAnything()
                }
                Color.clear.frame(height: 1)
                row("eraser", tr("清除页面"), danger: true) { PageOps.clear(session, page) }
                row("trash", tr("删除页面"), danger: true) { PageOps.delete(session, page) }
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(width: 360)
    }

    private func zoomButton<L: View>(@ViewBuilder label: () -> L, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label().frame(maxWidth: .infinity, minHeight: 34).background(Color.primary.opacity(0.08)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ icon: String, _ text: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Icon(icon, 18)
                Text(text).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(danger ? Theme.danger : Theme.ink)
        }
        .buttonStyle(RowStyle())
    }
}

// MARK: sidebar

final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "inkpad.thumbs", qos: .utility)

    func image(_ key: String, _ make: @escaping () -> UIImage, done: @escaping (UIImage) -> Void) {
        if let hit = cache.object(forKey: key as NSString) {
            done(hit)
            return
        }
        queue.async {
            let image = make()
            self.cache.setObject(image, forKey: key as NSString)
            DispatchQueue.main.async { done(image) }
        }
    }
}

struct PageThumb: View {
    let page: Page
    let stamp: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            (page.pdf == nil ? page.color : RGB.white).color
            if let image { Image(uiImage: image).resizable().interpolation(.high) }
        }
        .task(id: stamp) {
            let snap = page.snap
            let box = snap.box
            let board = snap.board
            ThumbCache.shared.image(stamp, { board ? pageImage(snap, scale: 0, size: (372, 268)) : pageImage(snap, scale: 372 / max(box.w, box.h)) }) { image = $0 }
        }
    }
}

/// Editor sidebar: page thumbnails in two columns, outline and bookmarks.
struct Sidebar: View {
    @ObservedObject var session: EditorSession
    let menu: (Page) -> [MenuItem]
    let onAdd: () -> Void
    @State private var tab = "thumbs"

    private let width: CGFloat = 124

    var body: some View {
        let doc = session.doc
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach([("thumbs", "grid", "缩略图"), ("outline", "outline", "大纲"), ("marks", "bookmark", "书签")], id: \.0) { id, icon, tip in
                    Button { tab = id } label: {
                        Icon(icon).frame(width: 46, height: 34).background(Color.primary.opacity(tab == id ? 0.2 : 0.08)).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tr(tip))
                    if id != "marks" { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 34) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.top, 10)
            .padding(.bottom, 8)
            if tab == "thumbs" {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.fixed(width + 8), spacing: 6), GridItem(.fixed(width + 8), spacing: 6)], spacing: 6) {
                            ForEach(Array(doc.pages.enumerated()), id: \.element.id) { i, page in
                                cell(i, page).id(page.id)
                            }
                            Button(action: onAdd) {
                                VStack(spacing: 4) {
                                    Icon("plus")
                                    Text(tr(doc.pages[0].board ? "添加白板" : "添加页面")).font(.subheadline)
                                }
                                .frame(width: width, height: 150)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 12)
                    }
                    .onChange(of: session.page) { _, new in
                        if doc.pages.indices.contains(new) { withAnimation { proxy.scrollTo(doc.pages[new].id) } }
                    }
                }
            } else {
                list(tab == "outline")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebarBg)
    }

    private func cell(_ i: Int, _ page: Page) -> some View {
        let stamp = "\(page.id)-\(page.rev)-\(page.paper)-\(page.color.list)-\(page.w)x\(page.h)-\(page.rot)"
        let height = min(200, (width * (page.board ? 0.72 : page.h / page.w)).rounded())
        let shown = page.board || height < 200 ? width : (200 * page.w / page.h).rounded()
        return VStack(spacing: 0) {
            Button { session.canvas.scrollToPage(i) } label: {
                PageThumb(page: page, stamp: stamp)
                    .frame(width: shown, height: height)
                    .thumb(selected: i == session.page)
                    .overlay(alignment: .topTrailing) {
                        if page.bookmark { Icon("bookmark_filled", 18).foregroundStyle(Theme.mark) }
                    }
            }
            .buttonStyle(.plain)
            .frame(maxHeight: .infinity, alignment: .bottom)
            HStack(spacing: 0) {
                Text("\(i + 1)").font(.system(size: 13)).foregroundStyle(.secondary).padding(.leading, 6)
                Spacer()
                PopButton { close in MenuList(items: menu(page), close: close) } label: {
                    Icon("dots", 16).frame(width: 30, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("页面操作"))
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private func list(_ outline: Bool) -> some View {
        let rows = session.doc.pages.enumerated().compactMap { i, page -> (Int, String)? in
            if outline { return page.outline.map { (i, $0) } }
            return page.bookmark ? (i, trf("第 %d 页", i + 1)) : nil
        }
        return ScrollView {
            if rows.isEmpty {
                Text(tr("暂无内容")).foregroundStyle(.secondary).padding(.top, 30)
            }
            VStack(spacing: 2) {
                ForEach(rows, id: \.0) { i, text in
                    Button { session.canvas.scrollToPage(i) } label: {
                        HStack(spacing: 8) {
                            Text(text).lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\(i + 1)").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(RowStyle())
                }
            }
            .padding(.horizontal, 8)
        }
    }
}
