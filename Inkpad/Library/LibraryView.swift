import SwiftUI
import UniformTypeIdentifiers

final class CoverCache {
    static let shared = CoverCache()
    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "inkpad.covers", qos: .userInitiated, attributes: .concurrent)

    func cover(_ entry: Entry, done: @escaping (UIImage?) -> Void) {
        let key = "\(entry.url.path)/\(entry.mtime.timeIntervalSince1970)" as NSString
        if let hit = cache.object(forKey: key) {
            done(hit)
            return
        }
        queue.async {
            let image = Notebook.cover(of: entry.url)
            if let image { self.cache.setObject(image, forKey: key) }
            DispatchQueue.main.async { done(image) }
        }
    }
}

/// A soft two-tone folder in the given colour, with an optional glyph on the front:
/// the desktop's folder_texture, 150 x 118.
struct FolderArt: View {
    let color: RGB
    let icon: String

    var body: some View {
        Canvas { g, size in
            let w = size.width, h = size.height
            let r: CGFloat = 11, tabW = w * 0.40, tabH = h * 0.13, top = h * 0.20
            var back = Path()
            back.move(to: CGPoint(x: 0, y: h - r))
            back.addLine(to: CGPoint(x: 0, y: r))
            back.addArc(center: CGPoint(x: r, y: r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            back.addLine(to: CGPoint(x: tabW - 6, y: 0))
            back.addCurve(to: CGPoint(x: tabW + 14, y: tabH), control1: CGPoint(x: tabW + 2, y: 0), control2: CGPoint(x: tabW + 4, y: tabH))
            back.addLine(to: CGPoint(x: w - r, y: tabH))
            back.addArc(center: CGPoint(x: w - r, y: tabH + r), radius: r, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            back.addLine(to: CGPoint(x: w, y: h - r))
            back.addArc(center: CGPoint(x: w - r, y: h - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            back.addArc(center: CGPoint(x: r, y: h - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            back.closeSubpath()
            g.fill(back, with: .color(color.scaled(0.84).color))
            let front = Path(roundedRect: CGRect(x: 0, y: top, width: w, height: h - top), cornerRadius: r, style: .circular)
            let light = RGB(min(1, color.r + 0.07), min(1, color.g + 0.07), min(1, color.b + 0.07))
            g.fill(front, with: .linearGradient(Gradient(colors: [light.color, color.color]), startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: h)))
            g.stroke(front, with: .color(.white.opacity(0.35)), lineWidth: 1)
            if let glyph = Lucide.folderGlyph(icon) {
                let s = h * 0.36
                let path = Lucide.outline(glyph, size: s, weight: 1.9)
                    .applying(CGAffineTransform(translationX: (w - s) / 2, y: top + (h - top - s) / 2))
                g.fill(path, with: .color(color.scaled(0.42).color.opacity(0.78)))
            } else if !icon.isEmpty {   // an emoji chosen in an earlier version
                g.draw(Text(icon).font(.system(size: h * 0.30)), at: CGPoint(x: w / 2, y: top + (h - top) / 2))
            }
        }
        .frame(width: 150, height: 118)
        .shadow(color: .black.opacity(0.14), radius: 4, y: 4)
    }
}

/// Where the cells of the grid are, for the rubber band to pick them up.
private struct CellFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { _, new in new } }
}

/// Lets a mouse drag over the grid draw a rubber band, as on the desktop; fingers scroll.
private struct MouseBand: UIViewRepresentable {
    /// The band in the grid's coordinates (nil once it is let go), and whether a modifier key
    /// asks for it to add to what is selected.
    let onItem: (CGPoint) -> Bool
    let onChange: (CGRect?, Bool) -> Void

    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        view.onChange = onChange
        view.onItem = onItem
    }

    final class Probe: UIView {
        var onChange: ((CGRect?, Bool) -> Void)?
        var onItem: ((CGPoint) -> Bool)?
        private var off = false   // the drag began on an item: it carries the item, and bands nothing
        private weak var scroll: UIScrollView?
        private var start = CGPoint.zero

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, scroll == nil else { return }
            var view = superview
            while let v = view, !(v is UIScrollView) { view = v.superview }
            guard let found = view as? UIScrollView else { return }
            scroll = found
            // A mouse drag selects; the wheel and two fingers on a trackpad still scroll.
            found.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
            drag.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            drag.maximumNumberOfTouches = 1
            found.addGestureRecognizer(drag)
        }

        @objc private func dragged(_ g: UIPanGestureRecognizer) {
            let p = g.location(in: self)
            switch g.state {
            case .began:
                let moved = g.translation(in: self)
                start = CGPoint(x: p.x - moved.x, y: p.y - moved.y)
                // A drag that starts on an item carries the item; the rubber band is for the space between.
                off = onItem?(start) ?? false
                fallthrough
            case .changed:
                if off { return }
                let keep = !g.modifierFlags.intersection([.command, .control, .shift]).isEmpty
                onChange?(CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y)), keep)
            default:
                onChange?(nil, false)
            }
        }
    }
}

/// What a drag in the library carries; the items themselves stay in the view.
private let dragMark = "inkpad-library-items"

private extension View {
    /// As in a file manager: the item can be dragged onto a folder to be moved there.
    @ViewBuilder func dragged(_ begin: (() -> Void)?) -> some View {
        if let begin {
            onDrag {
                begin()
                return NSItemProvider(object: dragMark as NSString)
            }
        } else {
            self
        }
    }

    /// Let dragged items be dropped here, to go into the folder this stands for.
    @ViewBuilder func dropTarget(_ aimed: Binding<Bool>, _ drop: (() -> Bool)?) -> some View {
        if let drop {
            onDrop(of: [.plainText], isTargeted: aimed) { _ in drop() }
        } else {
            self
        }
    }
}

/// A step of the path, or the back button: items dropped on it go to that folder.
private struct DropSpot<Label: View>: View {
    let drop: () -> Bool
    @ViewBuilder let label: () -> Label
    @State private var aimed = false

    var body: some View {
        label()
            .background(Theme.accent.opacity(aimed ? 0.28 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent.opacity(aimed ? 1 : 0), lineWidth: 2))
            .onDrop(of: [.plainText], isTargeted: $aimed) { _ in drop() }
    }
}

private struct EntryCell: View {
    let entry: Entry
    var picked = false            // chosen, while several items are being selected
    var drag: (() -> Void)?       // called as the item is picked up to be dragged to another folder
    var drop: (() -> Bool)?       // on a folder: what was being dragged has been dropped on it
    @State private var aimed = false
    let favorite: Bool?           // nil where there are no favourites to toggle (the trash)
    let style: (RGB, String)
    let menu: [MenuItem]
    let open: () -> Void
    var openTwice: (() -> Void)?   // a folder: what a double tap does
    let star: () -> Void
    @State private var cover: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            Button(action: open) {
                Group {
                    if entry.isDir {
                        FolderArt(color: style.0, icon: style.1)
                    } else if let cover {
                        Image(uiImage: cover)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 150, maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.black.opacity(0.08), lineWidth: 1))
                            .shadow(color: .black.opacity(0.10), radius: 1, y: 1)
                            .shadow(color: .black.opacity(0.14), radius: 10, y: 8)
                    } else {
                        RoundedRectangle(cornerRadius: 5).fill(Color.white).frame(width: 150, height: 200)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.black.opacity(0.08), lineWidth: 1))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let favorite {
                        Button(action: star) {
                            Icon(favorite ? "star_filled" : "star", 18)
                                // On a cover the star has to show on paper whatever the theme is.
                                .foregroundStyle(favorite ? Theme.starOn : entry.isDir ? Color.primary.opacity(0.38) : Color.black.opacity(0.38))
                                .shadow(color: .white.opacity(entry.isDir || favorite ? 0 : 0.55), radius: 0.6)
                                .padding(5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, entry.isDir ? 28 : 4)
                        .padding(.trailing, 4)
                        .accessibilityLabel(tr(favorite ? "取消收藏" : "收藏"))
                    }
                }
                .frame(height: 200, alignment: .bottom)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { openTwice?() })
            .accessibilityIdentifier("open-" + entry.name)
            PopButton { close in MenuList(items: menu, close: close) } label: {
                HStack(spacing: 2) {
                    Text(entry.name).font(.system(size: 16)).lineLimit(1)
                    Icon("chevron", 14)
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(entry.mtime.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(width: 166)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(Theme.accent.opacity(aimed ? 0.28 : picked ? 0.18 : 0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(aimed ? 1 : picked ? 0.75 : 0), lineWidth: 2))
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 12, style: .continuous))
        .dragged(drag)
        .dropTarget($aimed, drop)
        .background(GeometryReader { geo in Color.clear.preference(key: CellFrames.self, value: [entry.id: geo.frame(in: .named("grid"))]) })
        .task(id: entry) {
            if !entry.isDir { CoverCache.shared.cover(entry) { cover = $0 } }
        }
    }
}

/// A heading over a grid of things to pick one of (folder colours, folder icons).
struct ChoiceDialog<Cell: View>: View {
    let heading: String
    let count: Int
    let columns: Int
    @ViewBuilder var cell: (Int) -> Cell
    let onPick: (Int) -> Void
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Text(heading).font(.system(size: 19, weight: .bold)).padding(.top, 24)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: 4), count: columns), spacing: 4) {
                ForEach(0..<count, id: \.self) { i in
                    Button {
                        onPick(i)
                        app.dismissDialog()
                    } label: {
                        cell(i).frame(width: 48, height: 48).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button { app.dismissDialog() } label: { Text(tr("取消")).frame(maxWidth: .infinity) }
                .buttonStyle(DialogButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
        }
        .background(Theme.windowBg)
    }
}

struct LibraryView: View {
    enum Mode: Hashable { case docs, favs, trash }

    @EnvironmentObject var app: AppModel
    @ObservedObject var tools = ToolState.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var mode = Mode.docs
    @State private var folder: URL?          // nil is the top of the library
    @State private var query = ""
    @State private var importing = false
    @State private var picking = Picking.files
    @State private var exported: ExportedFile?
    @State private var prompt: Prompt?
    @State private var promptText = ""
    @State private var deleting: Entry?
    @State private var deletingMany = false
    @State private var emptying = false
    @State private var selecting = false          // several items are being chosen
    @State private var selected = Set<String>()
    @State private var frames: [String: CGRect] = [:]
    @State private var band: CGRect?
    @State private var bandBase: Set<String>?
    @State private var busy: (Double, String)?    // a folder is being imported: how far, and at what
    @State private var gridHeight: CGFloat = 0
    @State private var cursor: String?            // the folder tapped once: a second tap soon after opens it
    @State private var tappedAt = Date.distantPast
    @State private var dragging: [URL] = []       // what is being dragged to another folder

    private enum Picking { case files, archive, folder }

    private enum Prompt: Identifiable {
        case folder
        case rename(Entry)
        var id: String { if case .rename(let e) = self { return e.id } else { return "folder" } }
    }

    private var store: Store { app.store }
    private var current: URL { folder ?? store.root }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var inside: Bool { mode == .docs && folder != nil && !searching }

    private var entries: [Entry] {
        _ = app.libraryTick
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var list: [Entry]
        switch mode {
        case .docs: list = q.isEmpty ? store.entries(current) : store.find(q)   // a search looks through every folder
        case .favs: list = store.favorites()
        case .trash: list = store.trashed()
        }
        if !q.isEmpty && mode != .docs { list = list.filter { $0.name.lowercased().contains(q) } }
        if tools.p.sort == "name" {
            return list.sorted { $0.isDir != $1.isDir ? $0.isDir : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return list.sorted { $0.mtime > $1.mtime }
    }

    private var title: String {
        switch mode {
        case .docs: return searching ? tr("搜索结果") : folder.map { $0.lastPathComponent } ?? tr("文稿")
        case .favs: return tr("收藏")
        case .trash: return tr("废纸篓")
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if sizeClass != .compact {
                side
                Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1).ignoresSafeArea()
            }
            main
        }
        .background(Theme.viewBg.ignoresSafeArea())
        .background {
            // In the library, moves of items between folders are undone and redone.
            Group {
                Button("") { undoMove() }.keyboardShortcut("z", modifiers: .command)
                Button("") { redoMove() }.keyboardShortcut("z", modifiers: [.command, .shift])
                Button("") { redoMove() }.keyboardShortcut("y", modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        .overlay { if let busy { importProgress(busy) } }
        .onAppear {
            // The folder that was open last time is where the library opens again.
            let last = tools.p.lastFolder
            var dir: ObjCBool = false
            if folder == nil, !last.isEmpty, !last.hasPrefix("."), FileManager.default.fileExists(atPath: store.root.appendingPathComponent(last).path, isDirectory: &dir), dir.boolValue {
                folder = store.root.appendingPathComponent(last)
            }
        }
        .onChange(of: folder) { _, new in
            let rel = new.map { store.rel($0) } ?? ""
            tools.p.lastFolder = rel == "." || rel.hasPrefix("..") ? "" : rel
        }
        .onChange(of: mode) { _, _ in selected = [] }
        .task(id: app.libraryAction) {
            guard let action = app.libraryAction else { return }
            app.libraryAction = nil
            mode = .docs
            if action == "new-board" { newBoard() } else { newNotebook() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: importTypes, allowsMultipleSelection: picking == .files) { result in
            guard case .success(let urls) = result, let first = urls.first else { return }
            switch picking {
            case .files: importFiles(urls)
            case .folder: importFolder(first)
            case .archive:
                let scoped = first.startAccessingSecurityScopedResource()
                defer { if scoped { first.stopAccessingSecurityScopedResource() } }
                do {
                    let count = try store.importArchive(first, into: mode == .docs ? current : store.root)
                    app.show(trf("已导入 %d 本笔记", count))
                } catch {
                    app.alert = tr("导入失败") + "\n" + error.localizedDescription
                }
                app.refreshLibrary()
            }
        }
        .sheet(item: $exported) { ShareSheet(items: [$0.url]) }
        .alert(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { p in
            TextField(tr("名称"), text: $promptText)
            Button(tr("取消"), role: .cancel) {}
            Button(tr("确定")) {
                switch p {
                case .folder: perform { try store.newFolder(current, promptText) }
                case .rename(let entry): perform { try store.rename(entry.url, promptText) }
                }
            }
        }
        .confirmationDialog(trf("永久删除“%s”？", deleting?.name ?? ""), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { entry in
            Button(tr("永久删除"), role: .destructive) { perform { try store.delete(entry.url) } }
        } message: { _ in
            Text(tr("它会从废纸篓消失，但仍保留在本机缓存和云端，直到你在设置中清理缓存。"))
        }
        .confirmationDialog(trf("永久删除 %d 项？", selected.count), isPresented: $deletingMany, titleVisibility: .visible) {
            Button(tr("永久删除"), role: .destructive) { each { try store.delete($0) } }
        } message: {
            Text(tr("它会从废纸篓消失，但仍保留在本机缓存和云端，直到你在设置中清理缓存。"))
        }
        .confirmationDialog(tr("清空废纸篓？"), isPresented: $emptying, titleVisibility: .visible) {
            Button(tr("清空"), role: .destructive) {
                perform { for entry in store.trashed() { try store.delete(entry.url) } }
            }
        } message: {
            Text(tr("其中的内容会从废纸篓消失，但仍保留在本机缓存和云端，直到你在设置中清理缓存。"))
        }
    }

    // MARK: sidebar

    private let sections: [(Mode, String, String)] = [(.docs, "documents", "文稿"), (.favs, "star", "收藏"), (.trash, "trash", "废纸篓")]

    private var side: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Inkpad")
                .font(.system(size: 27, weight: .bold))
                .tracking(-0.6)
                .padding(.horizontal, 12)
                .padding(.top, 22)
                .padding(.bottom, 26)
            ForEach(sections, id: \.0) { id, icon, label in
                let on = mode == id
                Button {
                    // Tapping the section that is already showing goes back to its top.
                    if on && id == .docs { folder = nil }
                    mode = id
                    query = ""
                } label: {
                    HStack(spacing: 14) {
                        Icon(icon, 22)
                        Text(tr(label)).font(.system(size: 18, weight: on ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Color.primary.opacity(on ? 0.10 : 0), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 250)
        .background(
            LinearGradient(stops: [.init(color: Theme.sidebarBg.mix(Theme.accent, 0.05), location: 0), .init(color: Theme.sidebarBg, location: 0.6)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea())
    }

    // MARK: main column

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if sizeClass == .compact {
                    Dropdown(options: sections.map { tr($0.2) }, index: Binding(get: { sections.firstIndex { $0.0 == mode } ?? 0 }, set: { mode = sections[$0].0 }))
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Icon("search", 16).foregroundStyle(.secondary)
                    TextField(tr("搜索"), text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !query.isEmpty {
                        Button { query = "" } label: { Icon("close", 14).foregroundStyle(.secondary) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: sizeClass == .compact ? .infinity : 220)
                .frame(height: 34)
                .background(Color.primary.opacity(0.08), in: Capsule())
                PopButton(tag: "cloud") { close in CloudPanel(close: close) } label: {
                    Icon(app.syncing ? "syncing" : "cloud")
                        .foregroundStyle(app.syncing ? Theme.accentText : app.syncError != nil ? Theme.danger : Color.primary)
                        .frame(width: 38, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Google Drive 同步"))
                Button { app.showSettings = true } label: { Icon("settings").frame(width: 38, height: 34).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tr("设置"))
            }
            .padding(.horizontal, 12)
            .frame(height: 52)

            if inside { crumbs }
            if selecting { selectionBar } else {
            HStack(spacing: 10) {
                if inside {
                    DropSpot(drop: { dropped(on: parent(of: current) ?? store.root) }) {
                        Button { folder = parent(of: current) } label: {
                            Icon("back").frame(width: 34, height: 34).background(Color.primary.opacity(0.1), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tr("返回上一级"))
                    }
                }
                Text(title).font(.system(size: sizeClass == .compact ? 26 : 36, weight: .heavy)).tracking(-0.8).lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: 8)
                if mode == .docs {
                    PopButton { close in
                        MenuList(items: [
                            MenuItem(tr("笔记本"), "cover") { newNotebook() },
                            MenuItem(tr("白板"), "board") { newBoard() },
                            MenuItem(tr("导入 PDF 或 Goodnotes…"), "share") { pick(.files) },
                            MenuItem(tr("导入整个文件夹…"), "documents") { pick(.folder) },
                            MenuItem(tr("导入存档（.zip）…"), "restore") { pick(.archive) },
                            .line,
                            MenuItem(tr("文件夹"), "documents") {
                                promptText = tr("新文件夹")
                                prompt = .folder
                            },
                        ], close: close)
                    } label: {
                        HStack(spacing: 6) {
                            Icon("plus", 16)
                            Text(tr("新建")).fixedSize()
                            Icon("chevron", 14)
                        }
                    }
                    .buttonStyle(CapsuleButtonStyle(kind: .suggested))
                    .accessibilityLabel(tr("新建"))
                }
                if mode == .trash && !store.trashed().isEmpty {
                    Button(tr("清空废纸篓")) { emptying = true }.buttonStyle(CapsuleButtonStyle(kind: .destructive))
                }
                PopButton { close in
                    MenuList(items: [
                        MenuItem(tr("日期"), tools.p.sort == "date" ? "check_circle" : "none") { tools.p.sort = "date" },
                        MenuItem(tr("名称"), tools.p.sort == "name" ? "check_circle" : "none") { tools.p.sort = "name" },
                    ], close: close)
                } label: {
                    HStack(spacing: 8) {
                        Text(tr(tools.p.sort == "name" ? "名称" : "日期")).font(.system(size: 15)).fixedSize()
                        Icon("chevron", 14)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 35)
                    .background(Color.primary.opacity(0.1), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Button { selecting = true } label: {
                    Icon("check_circle").frame(width: 35, height: 35).background(Color.primary.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("选择项目"))
            }
            .padding(.leading, sizeClass == .compact ? 16 : 34)
            .padding(.trailing, sizeClass == .compact ? 12 : 30)
            .padding(.top, 2)
            .padding(.bottom, 14)
            }

            let list = entries
            if list.isEmpty {
                VStack(spacing: 10) {
                    Text(searching ? tr("没有匹配的项目") : mode == .docs ? tr("还没有笔记") : mode == .favs ? tr("还没有收藏") : tr("废纸篓是空的"))
                        .font(.system(size: 26, weight: .heavy))
                    if mode == .docs && !searching {
                        Text(tr("点击“新建”创建笔记本，或导入一份 PDF。")).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 166, maximum: 210), spacing: 14)], alignment: .leading, spacing: 22) {
                        ForEach(list) { entry in
                            EntryCell(entry: entry, picked: selecting ? selected.contains(entry.id) : cursor == entry.id,
                                      drag: mode == .docs ? { pickUp(entry) } : nil,
                                      drop: mode == .docs && entry.isDir ? { dropped(on: entry.url) } : nil,
                                      favorite: mode == .trash ? nil : store.isFavorite(entry.url), style: store.folderStyle(entry.url),
                                      menu: menu(entry), open: { activate(entry) },
                                      openTwice: entry.isDir && !selecting && mode != .trash ? { enter(entry) } : nil, star: {
                                store.toggleFavorite(entry.url)
                                app.refreshLibrary()
                            })
                        }
                    }
                    .padding(.horizontal, sizeClass == .compact ? 10 : 26)
                    .padding(.top, 10)
                    .padding(.bottom, 30)
                    .frame(maxWidth: .infinity, minHeight: max(300, gridHeight), alignment: .topLeading)
                    .coordinateSpace(name: "grid")
                    .background(MouseBand(onItem: { p in frames.values.contains { $0.contains(p) } }) { rect, keep in banded(rect, keep) }.allowsHitTesting(false))
                    .background {
                        // A long press beside the items: undoing and redoing moves.
                        if mode == .docs, !app.moveUndo.isEmpty || !app.moveRedo.isEmpty {
                            Color.clear.contentShape(Rectangle()).contextMenu {
                                if !app.moveUndo.isEmpty { Button { undoMove() } label: { Label(tr("撤销移动"), systemImage: "arrow.uturn.backward") } }
                                if !app.moveRedo.isEmpty { Button { redoMove() } label: { Label(tr("重做移动"), systemImage: "arrow.uturn.forward") } }
                            }
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let band {
                            Rectangle().fill(Theme.accent.opacity(0.15)).overlay(Rectangle().strokeBorder(Theme.accent.opacity(0.8), lineWidth: 1))
                                .frame(width: band.width, height: band.height).offset(x: band.minX, y: band.minY).allowsHitTesting(false)
                        }
                    }
                    .onPreferenceChange(CellFrames.self) { frames = $0 }
                }
                // The space beside the items reaches to the bottom of the window: it is where a
                // mouse starts a rubber band, and where a long press undoes a move.
                .background(GeometryReader { geo in Color.clear.onAppear { gridHeight = geo.size.height }.onChange(of: geo.size.height) { _, h in gridHeight = h } })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: selecting several items

    /// Shown instead of the title bar while items are being selected.
    private var selectionBar: some View {
        let n = selected.count
        var actions: [(String, String, Bool, () -> Void)]
        if mode == .trash {
            actions = [("restore", "恢复", false, { each { try store.restore($0) } }), ("trash", "永久删除", true, { deletingMany = true })]
        } else {
            actions = [("share", "导出", false, exportSelected), ("duplicate", "复制", false, { each { try store.duplicate($0) } }),
                       ("move", "移动", false, moveSelected), ("trash", "废纸篓", true, { each { try store.trash($0) } })]
        }
        return HStack(spacing: 8) {
            Button(tr("全选")) {
                let all = Set(entries.map(\.id))
                selected = selected == all ? [] : all
            }
            .buttonStyle(CapsuleButtonStyle())
            Text(trf("已选择 %d 项", n)).foregroundStyle(.secondary).lineLimit(1).fixedSize().padding(.leading, 6)
            Spacer(minLength: 8)
            // With their names where there is room for them, as icons alone where there is not.
            ViewThatFits(in: .horizontal) {
                actionButtons(actions, n, named: true)
                actionButtons(actions, n, named: false)
            }
            Button(tr("完成")) { stopSelecting() }
                .buttonStyle(CapsuleButtonStyle(kind: .suggested))
                .padding(.leading, 10)
        }
        .padding(.leading, 34)
        .padding(.trailing, 30)
        .padding(.top, 2)
        .padding(.bottom, 14)
        .frame(minHeight: 59)
    }

    private func actionButtons(_ actions: [(String, String, Bool, () -> Void)], _ n: Int, named: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(actions, id: \.1) { icon, label, danger, action in
                Button(action: action) {
                    HStack(spacing: 6) {
                        Icon(icon, 18)
                        if named { Text(tr(label)).font(.system(size: 15, weight: .semibold)).fixedSize() }
                    }
                    .foregroundStyle(danger ? Theme.danger : Color.primary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 35)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(n == 0)
                .opacity(n == 0 ? 0.4 : 1)
                .accessibilityLabel(tr(label))
            }
        }
    }

    private func stopSelecting() {
        selecting = false
        selected = []
    }

    private var picked: [Entry] { entries.filter { selected.contains($0.id) } }

    /// Apply a store operation to every selected item, then leave selection mode.
    private func each(_ work: (URL) throws -> Void) {
        for entry in picked {
            do {
                try work(entry.url)
            } catch {
                app.alert = error.localizedDescription
                break
            }
        }
        stopSelecting()
        app.refreshLibrary()
    }

    private func moveSelected() {
        let items = picked
        app.present(FolderDialog(store: store, heading: trf("移动 %d 项到", items.count), moving: items.filter(\.isDir).map(\.url)) { dest in
            moveItems(items.map(\.url), to: dest)
        }, width: 380, height: nil)
    }

    // MARK: moving items between folders

    private func pickUp(_ entry: Entry) {
        // Dragging one of several selected items takes them all along.
        dragging = selecting && selected.contains(entry.id) ? picked.map(\.url) : [entry.url]
    }

    private func dropped(on dest: URL) -> Bool {
        let urls = dragging
        dragging = []
        guard !urls.isEmpty else { return false }
        // After the drag has ended: the item dropped on may itself be rebuilt.
        DispatchQueue.main.async { moveItems(urls, to: dest) }
        return true
    }

    /// Move items into a folder, as one step that can be undone. Items already there, and a
    /// folder asked to go inside itself, are left alone.
    private func moveItems(_ urls: [URL], to dest: URL) {
        var done: [(URL, URL)] = []
        let to = dest.standardizedFileURL.path
        for url in urls {
            let from = url.standardizedFileURL.path
            if url.deletingLastPathComponent().standardizedFileURL.path == to || to == from || to.hasPrefix(from + "/") { continue }
            do {
                done.append((url, try store.move(url, to: dest)))
            } catch {
                app.alert = error.localizedDescription
                break
            }
        }
        if !done.isEmpty {
            app.moveUndo.append(done)
            if app.moveUndo.count > 50 { app.moveUndo.removeFirst(app.moveUndo.count - 50) }
            app.moveRedo = []
            let place = to == store.root.standardizedFileURL.path ? tr("文稿") : dest.lastPathComponent
            app.show(trf("已将 %d 项移到“%s”", done.count, place), button: tr("撤销")) { undoMove() }
        }
        stopSelecting()
        app.refreshLibrary()
    }

    /// Take the last move back (or do it again): everything returns to where, and to the
    /// name, it had.
    private func replay(_ source: inout [[(URL, URL)]], _ dest: inout [[(URL, URL)]]) -> Bool {
        guard mode == .docs, let step = source.popLast() else { return false }
        var back: [(URL, URL)] = []
        let fm = FileManager.default
        for (before, after) in step.reversed() {
            var dir: ObjCBool = false
            // Changed since by something else: leave it be.
            guard fm.fileExists(atPath: after.path), fm.fileExists(atPath: before.deletingLastPathComponent().path, isDirectory: &dir), dir.boolValue else { continue }
            let name = after.hasDirectoryPath || before.pathExtension.isEmpty ? before.lastPathComponent : before.deletingPathExtension().lastPathComponent
            do {
                back.append((after, try store.move(after, to: before.deletingLastPathComponent(), name: name)))
            } catch {
                app.alert = error.localizedDescription
                break
            }
        }
        if !back.isEmpty { dest.append(back) }
        app.refreshLibrary()
        return true
    }

    private func undoMove() {
        if replay(&app.moveUndo, &app.moveRedo) { app.show(tr("已撤销移动")) }
    }

    private func redoMove() {
        if replay(&app.moveRedo, &app.moveUndo) { app.show(tr("已重做移动")) }
    }

    private func exportSelected() {
        let items = picked
        let day = Date().formatted(.iso8601.year().month().day())
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent((items.count == 1 ? items[0].name : "Inkpad " + day) + ".zip")
        do {
            app.show(trf("已导出 %d 本笔记", try store.exportPaths(items.map(\.url), to: dest)))
            stopSelecting()
            exported = ExportedFile(url: dest)
        } catch {
            app.alert = tr("导出失败") + "\n" + error.localizedDescription
        }
    }

    /// The mouse is dragging a rubber band over the grid: it selects what it touches.
    private func banded(_ rect: CGRect?, _ keep: Bool) {
        guard let rect else {
            band = nil
            if bandBase != nil {
                bandBase = nil
                if selected.isEmpty { selecting = false }
            }
            return
        }
        if bandBase == nil {
            // Holding Command or Shift adds to what is already selected.
            bandBase = keep && selecting ? selected : []
            selecting = true
        }
        band = rect
        selected = (bandBase ?? []).union(frames.filter { $0.value.intersects(rect) }.keys)
    }

    // MARK: importing

    private var importTypes: [UTType] {
        switch picking {
        case .files: return [.pdf, UTType(filenameExtension: "inkpad") ?? .data, UTType(filenameExtension: "goodnotes") ?? .data]
        case .archive: return [.zip]
        case .folder: return [.folder]
        }
    }

    private func pick(_ what: Picking) {
        picking = what
        // After the menu has gone: a picker cannot come up over a closing popover.
        DispatchQueue.main.async { importing = true }
    }

    /// Import everything in a folder, subfolders and all, behind a progress card.
    private func importFolder(_ source: URL) {
        let dest = mode == .docs ? current : store.root
        let scoped = source.startAccessingSecurityScopedResource()
        busy = (0, "")
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Store.importTree(source, into: dest) { fraction, text in Task { @MainActor in if busy != nil { busy = (fraction, text) } } } }
            }.value
            if scoped { source.stopAccessingSecurityScopedResource() }
            busy = nil
            app.refreshLibrary()
            switch result {
            case .failure(let error):
                app.alert = tr("导入失败") + "\n" + error.localizedDescription
            case .success(let (done, failed)):
                if failed.isEmpty {
                    app.show(trf("已导入 %d 本笔记", done))
                } else {
                    app.alert = trf("已导入 %d 本，%d 个文件未能导入", done, failed.count) + "\n" + failed.prefix(12).map { "\($0.0)：\($0.1)" }.joined(separator: "\n")
                }
            }
        }
    }

    private func importProgress(_ state: (Double, String)) -> some View {
        ZStack {
            Color.black.opacity(0.32).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(tr("正在导入…")).font(.system(size: 19, weight: .bold))
                ProgressView(value: state.0).tint(Theme.accent)
                Text(state.1.isEmpty ? "\(Int((state.0 * 100).rounded()))%" : state.1).font(.system(size: 14)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(26)
            .frame(width: 420)
            .background(Theme.windowBg, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        }
    }

    private func parent(of url: URL) -> URL? {
        let up = url.deletingLastPathComponent().standardizedFileURL
        return up.path == store.root.path ? nil : up
    }

    /// The way down to the open folder; each part is a button that goes there.
    private var crumbs: some View {
        let rel = store.rel(current.deletingLastPathComponent())
        let parts = rel == "." ? [] : rel.split(separator: "/").map(String.init)
        return HStack(spacing: 2) {
            DropSpot(drop: { dropped(on: store.root) }) { Button(tr("文稿")) { folder = nil }.padding(.horizontal, 4).frame(height: 24) }
            ForEach(Array(parts.enumerated()), id: \.offset) { i, name in
                let step = parts[0...i].reduce(store.root) { $0.appendingPathComponent($1) }
                Icon("chevron_right", 12).opacity(0.5)
                DropSpot(drop: { dropped(on: step) }) { Button(name) { folder = step }.padding(.horizontal, 4).frame(height: 24) }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .opacity(0.75)
        .padding(.horizontal, 32)
        .frame(height: 24)
    }

    private var promptTitle: String {
        if case .rename = prompt { return tr("重命名") }
        return tr("新建文件夹")
    }

    // MARK: actions

    private func menu(_ entry: Entry) -> [MenuItem] {
        if mode == .trash {
            return [MenuItem(tr("恢复"), "restore") { perform { try store.restore(entry.url) } },
                    MenuItem(tr("永久删除"), "trash", danger: true) { deleting = entry }]
        }
        var rows = [MenuItem(tr("重命名"), "rename") {
            promptText = entry.name
            prompt = .rename(entry)
        }]
        if entry.isDir {
            rows += [MenuItem(tr("自定义颜色"), "palette") { folderColor(entry) }, MenuItem(tr("设置图标"), "smile") { folderIcon(entry) }]
        }
        if entry.isDir {
            rows.append(MenuItem(tr("导出文件夹…"), "share") {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(entry.name + ".zip")
                do {
                    app.show(trf("已导出 %d 本笔记", try store.exportArchive(entry.url, to: dest)))
                    exported = ExportedFile(url: dest)
                } catch {
                    app.alert = tr("导出失败") + "\n" + error.localizedDescription
                }
            })
        }
        let fav = store.isFavorite(entry.url)
        rows += [
            .line,
            MenuItem(tr("移动到…"), "move") {
                app.present(FolderDialog(store: store, heading: trf("移动“%s”到", entry.name), moving: entry.isDir ? [entry.url] : []) { dest in
                    moveItems([entry.url], to: dest)
                }, width: 380, height: nil)
            },
            MenuItem(tr("复制"), "duplicate") { perform { try store.duplicate(entry.url) } },
            MenuItem(tr(fav ? "取消收藏" : "收藏"), "star") {
                store.toggleFavorite(entry.url)
                app.refreshLibrary()
            },
            .line,
            MenuItem(tr("移到废纸篓"), "trash", danger: true) { perform { try store.trash(entry.url) } },
        ]
        return rows
    }

    private func folderColor(_ entry: Entry) {
        app.present(ChoiceDialog(heading: tr("文件夹颜色"), count: folderColors.count, columns: 4, cell: { Swatch(color: folderColors[$0], size: 30) }, onPick: { i in
            store.setFolderStyle(entry.url, color: folderColors[i])
            app.refreshLibrary()
        }), width: 280, height: nil)
    }

    private func folderIcon(_ entry: Entry) {
        let names = [""] + Lucide.folderGlyphNames
        app.present(ChoiceDialog(heading: tr("文件夹图标"), count: names.count, columns: 5, cell: { i in
            Group {
                if let glyph = Lucide.folderGlyph(names[i]) {
                    Lucide.outline(glyph, size: 22).fill(.foreground).frame(width: 22, height: 22)
                } else {
                    Icon("none")
                }
            }
        }, onPick: { i in
            store.setFolderStyle(entry.url, icon: names[i])
            app.refreshLibrary()
        }), width: 320, height: nil)
    }

    private func newNotebook() {
        let here = current
        app.present(PaperDialog(heading: tr("新建笔记本"), action: tr("创建笔记本"), start: tools.template, board: false, withName: true) { template, name, cover in
            tools.template = template
            create { try store.newNotebook(here, template, name: name, cover: cover) }
        })
    }

    private func newBoard() {
        let here = current
        app.present(PaperDialog(heading: tr("新建白板"), action: tr("创建白板"), start: PageTemplate(paper: "dots", board: true), board: true, withName: true) { template, name, _ in
            create { try store.newNotebook(here, template, name: name) }
        })
    }

    private func enter(_ entry: Entry) {
        cursor = nil
        query = ""   // a folder found by searching opens as itself
        mode = .docs
        folder = entry.url
    }

    private func activate(_ entry: Entry) {
        if selecting {
            selected.formSymmetricDifference([entry.id])
            return
        }
        if mode == .trash { return }
        if entry.isDir {
            // A folder opens on a double tap; the first tap only marks it.
            let now = Date(), last = (cursor, tappedAt)
            cursor = entry.id
            tappedAt = now
            if last.0 != entry.id || now.timeIntervalSince(last.1) > 0.5 { return }
            enter(entry)
        } else {
            app.open(entry.url)
        }
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            app.alert = error.localizedDescription
        }
        app.refreshLibrary()
    }

    private func create(_ work: () throws -> URL) {
        do {
            let url = try work()
            app.refreshLibrary()
            app.open(url)
        } catch {
            app.alert = tr("无法创建") + "\n" + error.localizedDescription
        }
    }

    private func importFiles(_ urls: [URL]) {
        var last: URL?
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                if url.pathExtension.lowercased() == "pdf" {
                    last = try store.importPDF(current, name: url.deletingPathExtension().lastPathComponent, data: Data(contentsOf: url))
                } else if url.pathExtension.lowercased() == "goodnotes" {
                    let (new, stats) = try store.importGoodnotes(current, source: url)
                    last = new
                    app.show(goodnotesSummary(stats))
                } else {
                    last = try store.importNotebook(url, into: current)
                }
            } catch {
                app.alert = tr("无法导入") + "\n" + error.localizedDescription
            }
        }
        app.refreshLibrary()
        if urls.count == 1, let last { app.open(last) }
    }
}

/// What an import from Goodnotes brought in, as a line for a toast.
func goodnotesSummary(_ stats: Goodnotes.Stats) -> String {
    var text = trf("已导入 %d 笔、%d 个文本框", stats.strokes + stats.shapes, stats.texts)
    if stats.skipped > 0 { text += trf("；有 %d 个元素无法识别，已跳过", stats.skipped) }
    return text
}

/// Ask which folder to move things to: the library's folders as a tree to tap in. Only the
/// top level shows at first; the arrows open the rest. `moving` are the folders being
/// moved, which cannot go inside themselves.
struct FolderDialog: View {
    let store: Store
    let heading: String
    let onPick: (URL) -> Void
    private let folders: [URL]
    private let parents: Set<String>
    @State private var chosen: String?   // nothing to begin with, so that nothing is moved by mistake
    @State private var opened: Set<String>
    @EnvironmentObject private var app: AppModel

    init(store: Store, heading: String, moving: [URL], onPick: @escaping (URL) -> Void) {
        self.store = store
        self.heading = heading
        self.onPick = onPick
        let all = store.folders().filter { f in !moving.contains { f.path == $0.path || f.path.hasPrefix($0.path + "/") } }
        folders = all
        parents = Set(all.filter { $0.path != store.root.path }.map { $0.deletingLastPathComponent().path })
        _opened = State(initialValue: [store.root.path])
    }

    /// Whether every folder above this one is open.
    private func seen(_ folder: URL) -> Bool {
        var above = folder
        while above.path != store.root.path {
            above = above.deletingLastPathComponent()
            if !opened.contains(above.path) { return false }
        }
        return true
    }

    var body: some View {
        let shown = folders.filter(seen)
        VStack(spacing: 14) {
            Text(heading).font(.system(size: 19, weight: .bold)).multilineTextAlignment(.center).padding(.top, 26).padding(.horizontal, 24)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.path) { i, folder in
                        let rel = store.rel(folder)
                        let depth = rel == "." ? 0 : rel.split(separator: "/").count
                        HStack(spacing: 6) {
                            if rel != ".", parents.contains(folder.path) {
                                Button {
                                    opened.formSymmetricDifference([folder.path])
                                    // What is folded away cannot stay chosen.
                                    if let chosen, let at = folders.first(where: { $0.path == chosen }), !seen(at) { self.chosen = nil }
                                } label: {
                                    Icon(opened.contains(folder.path) ? "chevron" : "chevron_right", 14).frame(width: 34, height: 34).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(tr(opened.contains(folder.path) ? "收起" : "展开") + " " + folder.lastPathComponent)
                            } else {
                                Color.clear.frame(width: 34, height: 34)   // keeps the names in line
                            }
                            Icon("documents", 18)
                            Text(rel == "." ? tr("文稿") : folder.lastPathComponent).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 4 + 22 * CGFloat(depth))
                        .padding(.trailing, 10)
                        .padding(.vertical, 3)
                        .background(chosen == folder.path ? Theme.accent.opacity(0.22) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { chosen = folder.path }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("folder-" + (rel == "." ? "" : rel))
                        if i < shown.count - 1 { Divider() }
                    }
                }
                .background(Theme.cardBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.black.opacity(0.07), lineWidth: 1))
            }
            .frame(maxHeight: 360)
            .padding(.horizontal, 24)
            HStack(spacing: 10) {
                Button { app.dismissDialog() } label: { Text(tr("取消")).frame(maxWidth: .infinity) }.buttonStyle(DialogButtonStyle())
                Button {
                    app.dismissDialog()
                    if let dest = folders.first(where: { $0.path == chosen }) { onPick(dest) }
                } label: { Text(tr("移动")).frame(maxWidth: .infinity) }
                    .buttonStyle(DialogButtonStyle(suggested: true))
                    .disabled(chosen == nil)
                    .opacity(chosen == nil ? 0.5 : 1)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Theme.windowBg)
    }
}

/// The cloud button's popover: connect, or see how the sync is doing.
struct CloudPanel: View {
    @EnvironmentObject var app: AppModel
    let close: () -> Void

    var body: some View {
        Panel(title: "Google Drive", width: 280) {
            if !app.connected {
                Caption(tr("把文稿库同步到你的 Google Drive 里的“Inkpad”文件夹。应用只能访问它自己创建的文件。"))
                Button {
                    close()
                    if GoogleAccount.client == nil { app.showSettings = true } else { app.connect() }
                } label: { Text(tr("连接 Google Drive…")).frame(maxWidth: .infinity) }
                    .buttonStyle(DialogButtonStyle(suggested: true))
            } else {
                Caption(status)
                if app.syncing {
                    // The name of the notebook being moved has two lines to itself, whatever its
                    // length, so that the panel keeps its size.
                    Text(app.syncText).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38)
                    ProgressView(value: app.syncFraction).tint(Theme.accent)
                    Text("\(Int((app.syncFraction * 100).rounded()))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                Caption(tr("回到文稿库时自动同步。删除的笔记会进入废纸篓，两边都改过的会逐笔合并。"))
                Button {
                    close()
                    app.sync(quiet: false)
                } label: { Text(tr("立即同步")).frame(maxWidth: .infinity) }
                    .buttonStyle(DialogButtonStyle(suggested: true))
                    .disabled(app.syncing)
                Button {
                    close()
                    app.disconnect()
                } label: { Text(tr("断开连接")).frame(maxWidth: .infinity) }
                    .buttonStyle(DialogButtonStyle())
            }
        }
    }

    private var status: String {
        if app.syncing { return tr("正在同步…") }
        if let error = app.syncError { return tr("上次同步失败：") + error }
        if let last = app.lastSync { return tr("上次同步：") + last.formatted(date: .abbreviated, time: .shortened) }
        return tr("已连接，尚未同步")
    }
}

extension Color {
    /// This colour with a share of another mixed in.
    func mix(_ other: Color, _ share: Double) -> Color {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0, r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        let a = UIColor(self), b = UIColor(other)
        return Color(UIColor { traits in
            a.resolvedColor(with: traits).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            b.resolvedColor(with: traits).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            return UIColor(red: r1 + (r2 - r1) * share, green: g1 + (g2 - g1) * share, blue: b1 + (b2 - b1) * share, alpha: 1)
        })
    }
}
