import SwiftUI

/// Small pictures of the paper kinds, drawn once per kind, colour and shape.
final class PaperPreviews {
    static let shared = PaperPreviews()
    private var cache: [String: UIImage] = [:]

    func image(_ t: PageTemplate, height: Double = 256) -> UIImage {
        let key = "\(t.paper)-\(t.color.list)-\(t.board)-\(t.w)x\(t.h)-\(height)"
        if let hit = cache[key] { return hit }
        let image: UIImage
        if t.board {
            let snap = PageSnap(w: boardSize.0, h: boardSize.1, paper: t.paper, color: t.color, board: true, pdf: nil, pdfPage: 0, rot: 0, items: [])
            image = pageImage(snap, scale: 0, size: (Int(height * 4 / 3), Int(height)))
        } else {
            let snap = PageSnap(w: t.w, h: t.h, paper: t.paper, color: t.color, board: false, pdf: nil, pdfPage: 0, rot: 0, items: [])
            image = pageImage(snap, scale: height / max(t.w, t.h))
        }
        cache[key] = image
        return image
    }
}

/// Header-bar buttons of a dialog: plain, or the blue "suggested" one.
struct DialogButtonStyle: ButtonStyle {
    var suggested = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: suggested ? .semibold : .regular))
            .padding(.horizontal, 16)
            .frame(minHeight: 34)
            .foregroundStyle(suggested ? Color.white : Color.primary)
            .background(suggested ? Theme.accent : Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// A list to choose one of, shown as a rounded button with a chevron.
struct Dropdown: View {
    let options: [String]
    @Binding var index: Int

    var body: some View {
        PopButton { close in
            VStack(spacing: 0) {
                ForEach(options.indices, id: \.self) { i in
                    Button {
                        index = i
                        close()
                    } label: {
                        HStack {
                            Text(options[i]).fontWeight(i == index ? .semibold : .regular)
                            Spacer(minLength: 16)
                            if i == index { Icon("check_circle", 16).foregroundStyle(Theme.accentText) }
                        }
                    }
                    .buttonStyle(RowStyle())
                }
            }
            .padding(6)
            .frame(minWidth: 160)
        } label: {
            HStack(spacing: 8) {
                Text(options[min(index, options.count - 1)]).font(.system(size: 15)).fixedSize()
                Icon("chevron", 14)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Pick page size, paper colour, orientation and a template. With a name it is the
/// "new notebook" dialog, which also asks for a title and a cover; `board` is the
/// whiteboard variant: background style and colour only.
struct PaperDialog: View {
    let heading: String
    let action: String
    let board: Bool
    let withName: Bool
    let onApply: (PageTemplate, String, (String, RGB)?) -> Void

    @EnvironmentObject private var app: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var name = ""
    @State private var size: Int
    @State private var landscape: Bool
    @State private var paper: String
    @State private var color: Int
    @State private var cover: (String, RGB)?
    @FocusState private var naming: Bool

    init(heading: String, action: String, start: PageTemplate, board: Bool, withName: Bool,
         onApply: @escaping (PageTemplate, String, (String, RGB)?) -> Void) {
        self.heading = heading
        self.action = action
        self.board = board
        self.withName = withName
        self.onApply = onApply
        let (w, h) = (min(start.w, start.h), max(start.w, start.h))
        _size = State(initialValue: paperSizes.firstIndex { abs($0.1.0 - w) < 2 && abs($0.1.1 - h) < 2 } ?? 0)
        _landscape = State(initialValue: !board && start.w > start.h)
        _paper = State(initialValue: start.paper)
        _color = State(initialValue: paperColors.firstIndex { abs($0.1.r - start.color.r) + abs($0.1.g - start.color.g) + abs($0.1.b - start.color.b) < 0.05 } ?? 0)
    }

    private func template(_ kind: String) -> PageTemplate {
        let c = paperColors[color].1
        if board { return PageTemplate(w: boardSize.0, h: boardSize.1, paper: kind, color: c, board: true) }
        let (w, h) = paperSizes[size].1
        return PageTemplate(w: landscape ? h : w, h: landscape ? w : h, paper: kind, color: c)
    }

    private var groups: [(String, [(String, String)])] {
        board ? [("背景样式", boardPaperKinds.filter { $0.0 != "wide" })] : paperKinds
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(heading).font(.system(size: 16, weight: .bold))
                HStack {
                    Button(tr("取消")) { app.dismissDialog() }.buttonStyle(DialogButtonStyle())
                    Spacer()
                    Button(action) { apply() }.buttonStyle(DialogButtonStyle(suggested: true))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 48)
            Divider()
            if sizeClass == .compact {
                // A narrow window: one column, the title and cover above the papers.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if withName { side.padding(.top, 14) }
                        ScrollView(.horizontal, showsIndicators: false) { options }
                        kinds(columns: 3)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            } else {
                HStack(spacing: 0) {
                    if withName {
                        side.frame(width: 250).padding(.horizontal, 18).padding(.vertical, 16).frame(maxHeight: .infinity, alignment: .top)
                        Divider()
                    }
                    VStack(spacing: 0) {
                        options
                        Divider()
                        ScrollView { kinds(columns: 5).padding(.horizontal, 22).padding(.bottom, 16) }
                    }
                }
            }
        }
        .background(Theme.windowBg)
    }

    private var options: some View {
        HStack(spacing: 10) {
            if !board { Dropdown(options: paperSizes.map(\.0), index: $size) }
            Dropdown(options: paperColors.map { tr($0.0) }, index: $color)
            if !board { Linked(entries: [(false, tr("竖向")), (true, tr("横向"))], value: $landscape).frame(width: 150) }
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func kinds(columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groups, id: \.0) { group, kinds in
                Text(tr(group)).font(.system(size: 15, weight: .bold)).padding(.top, 14).padding(.bottom, 6)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
                    ForEach(kinds, id: \.0) { kind, label in cell(kind, label) }
                }
            }
        }
    }

    private func cell(_ kind: String, _ label: String) -> some View {
        let on = kind == paper
        let t = template(kind)
        let w: CGFloat = withName ? 84 : 96
        let shape: CGFloat = board ? 0.75 : CGFloat(t.h / t.w)
        return Button { paper = kind } label: {
            VStack(spacing: 6) {
                Image(uiImage: PaperPreviews.shared.image(t))
                    .resizable()
                    .frame(width: shape > 1 ? w : min(w, 128 / shape), height: shape > 1 ? min(128, w * shape) : min(w, 128 / shape) * shape)
                    .thumb(selected: on)
                    .frame(height: 136, alignment: .bottom)
                Text(tr(label)).font(.system(size: 14)).foregroundStyle(on ? Theme.accentText : Theme.ink)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr(label))
    }

    private var side: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("标题")).font(.system(size: 15, weight: .bold))
            TextField(tr(board ? "未命名的白板" : "无标题的笔记本"), text: $name)
                .focused($naming)
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .onSubmit { apply() }
            if !board {
                Text(tr("封面")).font(.system(size: 15, weight: .bold)).padding(.top, 14)
                CoverPicker(cover: $cover, title: name.isEmpty ? tr("笔记本") : name)
            }
            if sizeClass != .compact {
            Text(tr(board ? "背景" : "纸张样式")).font(.system(size: 15, weight: .bold)).padding(.top, 14)
            let t = template(paper)
            let shape: CGFloat = board ? 0.75 : CGFloat(t.h / t.w)
            Image(uiImage: PaperPreviews.shared.image(t, height: 400))
                .resizable()
                .frame(width: shape > 1 ? 150 : min(200, 200 / shape), height: shape > 1 ? min(200, 150 * shape) : min(200, 200 / shape) * shape)
                .thumb()
                .frame(maxWidth: .infinity, minHeight: 210, alignment: .top)
            }
        }
    }

    private func apply() {
        onApply(template(paper), name, cover)
        app.dismissDialog()
    }
}

/// Choose a cover design and colour, or none (the first page then serves as the cover).
struct CoverPicker: View {
    @Binding var cover: (String, RGB)?
    let title: String
    @State private var color = coverColors[0]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                choice(nil) {
                    Icon("none", 18).foregroundStyle(.secondary).frame(width: 36, height: 48).background(Color.white)
                }
                .accessibilityLabel(tr("用第一页作封面"))
                ForEach(coverStyles, id: \.self) { style in
                    choice(style) {
                        Image(uiImage: renderCover((style, color), title: title, w: 144, h: 192)).resizable().frame(width: 36, height: 48)
                    }
                }
            }
            HStack(spacing: 0) {
                ForEach(coverColors.indices, id: \.self) { i in
                    let c = coverColors[i]
                    Button {
                        color = c
                        if let style = cover?.0 { cover = (style, c) }
                    } label: {
                        Swatch(color: c, size: 20)
                            .padding(3)
                            .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2).opacity(c == color ? 1 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
            .opacity(cover == nil ? 0.4 : 1)
            .disabled(cover == nil)
        }
        .onAppear { if let cover { color = cover.1 } }
    }

    private func choice<V: View>(_ style: String?, @ViewBuilder content: () -> V) -> some View {
        let on = cover?.0 == style
        return Button { cover = style.map { ($0, color) } } label: {
            content()
                .thumb()
                .padding(4)
                .background(Theme.accent.opacity(on ? 0.25 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2).opacity(on ? 1 : 0))
        }
        .buttonStyle(.plain)
    }
}

/// A small alert-like card with a heading, as the desktop's cover dialog.
struct CoverDialog: View {
    let title: String
    let onDone: ((String, RGB)?) -> Void
    @EnvironmentObject private var app: AppModel
    @State private var cover: (String, RGB)?

    init(current: (String, RGB)?, title: String, onDone: @escaping ((String, RGB)?) -> Void) {
        self.title = title
        self.onDone = onDone
        _cover = State(initialValue: current)
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(tr("笔记本封面")).font(.system(size: 19, weight: .bold)).padding(.top, 26)
            Text(tr("封面显示在文稿库里。")).font(.system(size: 15)).foregroundStyle(.secondary)
            CoverPicker(cover: $cover, title: title).padding(.top, 8).padding(.horizontal, 24)
            HStack(spacing: 10) {
                Button { app.dismissDialog() } label: { Text(tr("取消")).frame(maxWidth: .infinity) }.buttonStyle(DialogButtonStyle())
                Button {
                    onDone(cover)
                    app.dismissDialog()
                } label: { Text(tr("应用")).frame(maxWidth: .infinity) }.buttonStyle(DialogButtonStyle(suggested: true))
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .background(Theme.windowBg)
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var tools = ToolState.shared
    @Environment(\.dismiss) private var dismiss
    // Filled in when the sheet appears: the view is made anew at every redraw of what is under
    // it, and reading the keychain each time kept the app too busy to show it during a sync.
    @State private var clientID = ""
    @State private var secret = ""
    @State private var importing = false
    @State private var picking = Picking.client
    @State private var exported: ExportedFile?
    @State private var cache = 0
    @State private var folderID = ""
    @State private var folderHelp = false
    @State private var changingFolder: String?   // the folder id waiting to be confirmed
    @State private var synced = ""
    @State private var savedFolder = ""
    @State private var hasClient = false
    @State private var tick = 0                  // bumped when what is kept outside the view's state changes

    private enum Picking { case client, archive }

    var body: some View {
        NavigationStack {
            Form {
                Section(tr("外观与语言")) {
                    Picker(selection: $tools.p.theme) {
                        Text(tr("跟随系统")).tag("system")
                        Text(tr("浅色")).tag("light")
                        Text(tr("深色")).tag("dark")
                    } label: {
                        Text(tr("外观"))
                        Text(tr("页面本身始终保持纸张颜色")).font(.footnote)
                    }
                    Picker(selection: $tools.p.language) {
                        Text(tr("跟随系统")).tag("auto")
                        Text("简体中文").tag("zh")
                        Text("English").tag("en")
                        Text("日本語").tag("ja")
                    } label: {
                        Text(tr("语言"))
                        if tools.p.language != startLanguage { Text(tr("重新启动应用后生效")).font(.footnote) }
                    }
                }
                Section(tr("书写")) {
                    toggle($tools.p.scribbleErase, "涂画以擦除", "在字迹上来回涂抹即可删除")
                    toggle($tools.p.scribbleLoose, "宽松的涂抹删除", "使用旧的判定方式：更容易删掉，但连笔写字时可能被当成涂抹")
                    toggle($tools.p.holdShape, "长按绘制规则形状", "画完停住片刻，笔迹变成直线、矩形或椭圆")
                    toggle($tools.p.fingerDraw, "用手指书写", "关闭时手指只用于滚动和缩放")
                    toggle($tools.p.crosshair, "显示十字光标", "关闭后书写时只显示十字中心的小圆点")
                    toggle($tools.p.mouseHand, "有手写笔时鼠标不书写", "用过手写笔之后，鼠标拖动改为移动页面，点击胶带可掀开或盖回")
                    toggle($tools.p.pencilDoubleTap, "双击 Apple Pencil 切换橡皮擦", nil)
                    toggle($tools.p.pencilSqueeze, "捏一下 Apple Pencil Pro 弹出工具盘", "工具盘出现在笔尖旁边，中间一段工具可以沿弧线滑动；再捏一下或在别处落笔即收起")
                    toggle($tools.p.eraserAuto, "自动取消选择", nil)
                    Picker(selection: $tools.p.paging) {
                        Text(tr("上下")).tag("vertical")
                        Text(tr("左右")).tag("horizontal")
                    } label: {
                        Text(tr("翻页方向"))
                        Text(tr("左右翻页时，在第一页或最后一页继续拉动可新建一页")).font(.footnote)
                    }
                    toggle($tools.p.scrollbars, "显示滚动条", nil)
                    Picker(selection: $tools.p.maxZoom) {
                        Text("600%").tag(6.0)
                        Text("1000%").tag(10.0)
                        Text("2000%").tag(20.0)
                        Text("4000%").tag(40.0)
                    } label: {
                        Text(tr("最大放大倍数"))
                        Text(tr("按屏幕上实际看到的大小计算，页面再大也能放大到这个程度")).font(.footnote)
                    }
                }
                Section {
                    TextField(tr("客户端 ID"), text: $clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(tr("客户端密钥"), text: $secret)
                    Button(tr("保存凭据")) { saveClient() }
                    Button(tr("从 JSON 凭据文件导入…")) {
                        picking = .client
                        importing = true
                    }
                    Button(tr("导出凭据为 JSON…")) { exportClient() }
                    let now = syncedFolder
                    LabeledContent {
                        Button(tr("在浏览器中打开")) {
                            if let url = URL(string: "https://drive.google.com/drive/folders/" + now) { UIApplication.shared.open(url) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(now.isEmpty)
                    } label: {
                        Text(tr("当前同步文件夹"))
                        Text(now.isEmpty ? tr("还没有同步过") : now).font(.footnote).textSelection(.enabled)
                    }
                    // How to keep the library somewhere else in Drive, folded away until it is asked
                    // for. The field itself is in here too: out in the open it is too easily
                    // changed by mistake.
                    DisclosureGroup(isExpanded: $folderHelp) {
                        HStack {
                            TextField(tr("文件夹 ID（留空：云端硬盘顶层的“Inkpad”文件夹）"), text: $folderID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .onSubmit { setFolder() }
                            if folderID.trimmingCharacters(in: .whitespaces) != savedFolder {
                                Button(tr("更改")) { setFolder() }.buttonStyle(.bordered)
                            }
                        }
                        .disabled(!hasClient)
                        Text(tr("Inkpad 只申请了“访问自己创建的文件”这一项权限，所以你在 Google Drive 里手动建的文件夹它看不到，直接填那个文件夹的 ID 会同步失败。要把笔记放进别的文件夹，这样做：\n\n1. 上面的“文件夹 ID”留空，同步一次。Inkpad 会在云端硬盘顶层建一个名为“Inkpad”的文件夹。\n\n2. 点“当前同步文件夹”右边的“在浏览器中打开”，在 Google Drive 里把这个“Inkpad”文件夹移动（拖动，或右键 → 移动）到你想放的文件夹里。移动不会改变它的 ID，这台设备不需要改任何设置。\n\n3. 在其它设备上，把“当前同步文件夹”里显示的 ID 填进“文件夹 ID”；或者在这里点“导出凭据为 JSON…”，到那台设备上用“从 JSON 凭据文件导入…”，文件夹 ID 会一起带过去。\n\n注意：其它设备必须使用同一组客户端 ID 和密钥，并登录同一个 Google 账号，否则同样看不到这个文件夹。以后如果更改“文件夹 ID”，这台设备会把全部笔记重新备份到新文件夹，其它设备也要改成同一个 ID。"))
                            .font(.footnote)
                            .textSelection(.enabled)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("如何把笔记放到云端硬盘的其它位置"))
                            Text(tr("Inkpad 只能使用它自己创建的文件夹")).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Picker(selection: $tools.p.syncEvery) {
                        Text(tr("5 秒")).tag(5.0)
                        Text(tr("10 秒")).tag(10.0)
                        Text(tr("15 秒")).tag(15.0)
                        Text(tr("30 秒")).tag(30.0)
                        Text(tr("1 分钟")).tag(60.0)
                        Text(tr("2 分钟")).tag(120.0)
                        Text(tr("5 分钟")).tag(300.0)
                    } label: {
                        Text(tr("打开的笔记本多久同步一次"))
                        Text(tr("每隔这么久查看一次其它设备写了什么；自己写的内容在停笔几秒后就会同步，与这里无关")).font(.footnote)
                    }
                    .onChange(of: tools.p.syncEvery) { _ in app.watchOpen() }
                    LabeledContent {
                    } label: {
                        Text(tr("凭据保存位置"))
                        Text(!hasClient ? tr("尚未保存") : Platform.secretsPlace).font(.footnote)
                    }
                    LabeledContent {
                        HStack(spacing: 8) {
                            if app.connected {
                                Button(tr("立即同步")) { app.sync(quiet: false) }.disabled(app.syncing)
                                Button(tr("断开连接"), role: .destructive) { app.disconnect() }
                            } else {
                                Button(tr("连接…")) { app.connect() }.disabled(!hasClient)
                            }
                        }
                        .buttonStyle(.bordered)
                    } label: {
                        Text(tr("状态"))
                        Text(status).font(.footnote).foregroundStyle(app.syncError == nil ? Color.secondary : Theme.danger)
                    }
                } header: {
                    Text(tr("Google Drive 同步"))
                } footer: {
                    Text(tr("同步使用你自己的 Google Cloud OAuth 客户端。在 Google Cloud 控制台创建“桌面应用”类型的 OAuth 客户端并启用 Google Drive API，然后把客户端 ID 和密钥填在这里（与桌面版用同一个）。应用只申请访问它自己创建的文件。"))
                }
                Section {
                    LabeledContent {
                        Button(tr("打开文件夹")) {
                            Platform.revealLibrary()
                        }
                        .buttonStyle(.bordered)
                    } label: {
                        Text(tr("文稿库位置"))
                        Text(Platform.libraryPlace).font(.footnote)
                    }
                    Button(tr("导出整个文稿库…")) { exportLibrary() }
                    Button(tr("导入存档（.zip）…")) {
                        picking = .archive
                        importing = true
                    }
                    NavigationLink(tr("管理储存空间…")) { StorageView().environmentObject(app) }
                } header: {
                    Text(tr("存储"))
                }
                Section {
                    ForEach(toolList.filter { $0.0 != "pen" } + [("image", "image", "插入图片"), ("ruler", "ruler", "尺子")], id: \.0) { id, icon, label in
                        Toggle(isOn: Binding(get: { !tools.p.hiddenTools.contains(id) }, set: { on in
                            tools.p.hiddenTools = tools.p.hiddenTools.filter { $0 != id } + (on ? [] : [id])
                        })) {
                            HStack(spacing: 10) {
                                Icon(icon)
                                Text(tr(label))
                            }
                        }
                    }
                } header: {
                    Text(tr("工具栏"))
                } footer: {
                    Text(tr("关掉不用的工具，让工具栏更清爽。"))
                }
                Section(tr("高级")) {
                    Stepper(value: $tools.p.palmMs, in: 0...1000, step: 10) {
                        Text(tr("防误触时间（毫秒）") + "  \(Int(tools.p.palmMs))")
                        Text(tr("笔离开屏幕后的这段时间内忽略手指触摸；页面在写字时乱跳就调大，手指反应迟钝就调小")).font(.footnote)
                    }
                    toggle($tools.p.inputLog, "记录输入日志", nil)
                    if tools.p.inputLog {
                        Text(trf("排查笔画丢失等问题时打开：笔和手指的事件会写入 %s", Platform.libraryPlace + " › input.log")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section(tr("关于")) {
                    LabeledContent("Inkpad") {
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    }
                }
            }
            .navigationTitle(tr("设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(tr("完成")) { dismiss() } } }
            .onAppear { cache = app.store.cacheSize() }
            .sheet(item: $exported) { ShareSheet(items: [$0.url]) }
            .onAppear {
                clientID = GoogleAccount.clientID
                secret = GoogleAccount.clientSecret
                folderID = GoogleAccount.folderID
                reload()
            }
            .onChange(of: tick) { _, _ in reload() }
            .onChange(of: app.lastSync) { _, _ in reload() }
            .alert(tr("更改同步文件夹？"), isPresented: Binding(get: { changingFolder != nil }, set: { if !$0 { changingFolder = nil } }), presenting: changingFolder) { value in
                Button(tr("取消"), role: .cancel) { folderID = GoogleAccount.folderID }
                Button(tr("更改"), role: .destructive) { applyFolder(value) }
            } message: { _ in
                Text(tr("这台设备上的全部笔记需要重新备份到新的文件夹，可能要花很长时间。原文件夹里的文件不会被移动或删除。\n\n其它设备也要填上同一个文件夹 ID（或导入从这里导出的凭据 JSON），否则它们仍然和原来的文件夹同步。\n\nInkpad 只能访问它自己创建的文件夹：填的应当是 Inkpad 生成的那个文件夹的 ID（在 Google Drive 里把它移到别处后 ID 不变）。"))
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: picking == .archive ? [.zip] : [.json]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if picking == .archive {
                    do {
                        let count = try app.store.importArchive(url, into: app.store.root)
                        app.refreshLibrary()
                        app.show(trf("已导入 %d 本笔记", count))
                    } catch {
                        app.alert = tr("导入失败") + "\n" + error.localizedDescription
                    }
                    return
                }
                do {
                    try GoogleAccount.importClient(Data(contentsOf: url))
                    clientID = GoogleAccount.clientID
                    secret = GoogleAccount.clientSecret
                    folderID = GoogleAccount.folderID
                    tick += 1
                    app.connected = GoogleAccount.connected
                    app.show(trf("凭据已保存到 %s", Platform.secretsPlace))
                } catch {
                    app.alert = error.localizedDescription
                }
            }
        }
    }

    private let startLanguage = ToolState.shared.p.language

    private func exportLibrary() {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("Inkpad " + Date().formatted(.iso8601.year().month().day()) + ".zip")
        do {
            let count = try app.store.exportArchive(app.store.root, to: dest)
            app.show(trf("已导出 %d 本笔记", count))
            exported = ExportedFile(url: dest)
        } catch {
            app.alert = tr("导出失败") + "\n" + error.localizedDescription
        }
    }

    private var status: String {
        if !app.connected { return tr("未连接") }
        if app.syncing { return tr("正在同步…") }
        if let error = app.syncError { return tr("上次同步失败：") + error }
        if let last = app.lastSync { return tr("上次同步：") + last.formatted(date: .abbreviated, time: .shortened) }
        return tr("已连接，尚未同步")
    }

    private func toggle(_ value: Binding<Bool>, _ title: String, _ subtitle: String?) -> some View {
        Toggle(isOn: value) {
            Text(tr(title))
            if let subtitle { Text(tr(subtitle)).font(.footnote) }
        }
    }

    private func saveClient() {
        do {
            try GoogleAccount.saveClient(id: clientID, secret: secret)
            app.connected = GoogleAccount.connected
            app.show(trf("凭据已保存到 %s", Platform.secretsPlace))
            tick += 1
        } catch {
            app.alert = error.localizedDescription
        }
    }

    /// The folder this library last synced with.
    private var syncedFolder: String { synced }

    /// Read again what is kept outside the view: the keychain and the sync's own notes.
    private func reload() {
        synced = LibrarySync.cloudFolder(app.store.root)
        savedFolder = GoogleAccount.folderID
        hasClient = GoogleAccount.client != nil
    }

    private func setFolder() {
        let value: String
        do {
            value = try LibrarySync.parseFolder(folderID)
        } catch {
            app.alert = error.localizedDescription
            return
        }
        folderID = value
        if value == GoogleAccount.folderID { return }
        if syncedFolder.isEmpty {
            applyFolder(value)   // nothing has been synced yet, so nothing has to be done over
        } else {
            changingFolder = value
        }
    }

    private func applyFolder(_ value: String) {
        do {
            try GoogleAccount.setFolderID(value)
            app.show(tr("同步文件夹已更改，下次同步时生效"))
            tick += 1
        } catch {
            app.alert = error.localizedDescription
        }
    }

    private func exportClient() {
        do {
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("inkpad_google_client.json")
            try GoogleAccount.exportClient().write(to: dest, options: .atomic)
            exported = ExportedFile(url: dest)
            app.show(trf("已导出到 %s（其中有客户端密钥，请妥善保管）", dest.lastPathComponent))
        } catch {
            app.alert = error.localizedDescription
        }
    }
}

struct ExportedFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// What deleted notebooks still take up, here and in the cloud, and getting them back.
struct StorageView: View {
    @EnvironmentObject var app: AppModel
    @State private var tick = 0
    @State private var cloud: [LibrarySync.CloudDeleted]?   // listed from the cloud index, once asked for
    @State private var picked = Set<String>()
    @State private var busy = ""
    @State private var clearing = false

    var body: some View {
        let store = app.store
        let entries = store.archived().sorted { $0.mtime > $1.mtime }
        Form {
            Section {
                ForEach(entries) { entry in
                    let origin = store.archivedOrigin(entry.url)
                    let place = origin == "." || origin.isEmpty ? tr("文稿") : tr("文稿 / ") + origin.replacingOccurrences(of: "/", with: " / ")
                    LabeledContent {
                        Button(tr("恢复")) {
                            do {
                                let new = try store.unarchive(entry.url)
                                app.show(trf("已恢复到 %s", store.rel(new)))
                                app.refreshLibrary()
                            } catch {
                                app.show(error.localizedDescription)
                            }
                            tick += 1
                        }
                        .buttonStyle(.bordered)
                    } label: {
                        Text(Store.archivedName(entry.name))
                        Text(trf("恢复到：%s", place)).font(.footnote)
                    }
                }
                if entries.isEmpty { Text(tr("没有已删除的项目")).foregroundStyle(.secondary) }
                Button(tr("清理缓存"), role: .destructive) { clearing = true }.disabled(entries.isEmpty)
            } header: {
                Text(tr("本机已删除的笔记"))
            } footer: {
                Text(trf("永久删除的笔记仍保留在本机，共 %s。清理只影响本机，不会删除云端的任何内容。",
                         ByteCountFormatter.string(fromByteCount: Int64(store.cacheSize()), countStyle: .file)))
            }
            Section {
                if !app.connected {
                    Text(tr("尚未连接 Google Drive")).foregroundStyle(.secondary)
                } else if !busy.isEmpty {
                    LabeledContent(busy) { ProgressView(value: app.syncFraction).frame(width: 160) }
                } else if let cloud {
                    if cloud.isEmpty { Text(tr("云端没有可还原的已删除笔记")).foregroundStyle(.secondary) }
                    ForEach(cloud) { item in
                        let folder = (item.path as NSString).deletingLastPathComponent
                        let place = folder.isEmpty ? tr("文稿") : tr("文稿 / ") + folder.replacingOccurrences(of: "/", with: " / ")
                        let when = item.ts > 0 ? Date(timeIntervalSince1970: item.ts).formatted(date: .abbreviated, time: .shortened) : ""
                        Button {
                            if picked.contains(item.id) { picked.remove(item.id) } else { picked.insert(item.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Icon(picked.contains(item.id) ? "check_circle" : "shape_ellipse")
                                    .foregroundStyle(picked.contains(item.id) ? Theme.accent : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(((item.path as NSString).lastPathComponent as NSString).deletingPathExtension).foregroundStyle(Theme.ink)
                                    Text(place + " · " + trf("删除于 %s", when)).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if !cloud.isEmpty {
                        Button(trf("下载所选的 %d 本", picked.count)) { fetch() }.disabled(picked.isEmpty)
                    }
                } else {
                    Button(tr("读取云端目录")) { list() }
                }
            } header: {
                Text(tr("云端保留的已删除笔记"))
            } footer: {
                Text(tr("在本机删除的笔记，云端的文件仍然保留，但不会自动下载回来。先读取云端目录，再选择要还原的笔记。"))
            }
        }
        .id(tick)
        .navigationTitle(tr("管理储存空间"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(tr("清理缓存？"), isPresented: $clearing, titleVisibility: .visible) {
            Button(tr("清理缓存"), role: .destructive) {
                store.clearCache()
                tick += 1
            }
        } message: {
            Text(tr("本机上已永久删除的笔记将无法再恢复。云端的内容不受影响。"))
        }
    }

    private func list() {
        let root = app.store.root
        busy = tr("正在读取云端目录…")
        Task {
            do {
                cloud = try await app.withDrive { drive, _ in try await LibrarySync.cloudDeleted(root: root, drive: drive, folder: GoogleAccount.folderID) }
            } catch {
                app.show(error.localizedDescription)
            }
            busy = ""
        }
    }

    private func fetch() {
        let root = app.store.root
        let ids = (cloud ?? []).map(\.id).filter { picked.contains($0) }
        busy = tr("正在下载…")
        Task {
            do {
                let count = try await app.withDrive { drive, progress in
                    try await LibrarySync.cloudRestore(root: root, drive: drive, ids: ids, folder: GoogleAccount.folderID, progress: progress)
                }
                cloud = (cloud ?? []).filter { !picked.contains($0.id) }
                picked = []
                app.show(trf("已从云端还原 %d 本笔记", count))
            } catch {
                app.show(error.localizedDescription)
            }
            busy = ""
        }
    }
}
