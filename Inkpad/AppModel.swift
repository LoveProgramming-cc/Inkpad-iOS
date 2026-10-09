import SwiftUI

struct DialogBox: Identifiable {
    let id = UUID()
    let view: AnyView
    let width: CGFloat
    let height: CGFloat?
}

/// One notebook open in the editor: the document, its canvas and its autosave.
@MainActor
final class EditorSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var doc: Document
    @Published var url: URL
    @Published var page = 0
    @Published var tick = 0          // bumped whenever pages, bookmarks or the undo state change
    @Published var hasSelection = false
    @Published var zoom = 100        // per cent, as the status pill shows it
    let canvas: CanvasView
    var onError: ((String) -> Void)?
    var onToast: ((String) -> Void)?

    private var listener: UUID?
    private var saveTimer: Timer?
    private let saveQueue = DispatchQueue(label: "inkpad.save")
    private var signature: String?   // what the file looked like when this app last wrote or read it
    /// While a sync is working on this very file nothing is written to it; edits wait in memory.
    var suspended = false

    init(url: URL) throws {
        let loaded = try Document.load(url)
        doc = loaded
        self.url = url
        canvas = CanvasView(doc: loaded, tools: ToolState.shared)
        canvas.initialPage = ToolState.shared.p.lastPages[loaded.id] ?? 0
        canvas.memo = ToolState.shared.p.views[loaded.id]   // where it was being looked at last time
        signature = Self.sign(url)
        canvas.onPage = { [weak self] in self?.page = $0 }
        canvas.onZoom = { [weak self] in self?.zoom = $0 }
        canvas.onToast = { [weak self] in self?.onToast?($0) }
        canvas.onSelection = { [weak self] in self?.hasSelection = self?.canvas.sel != nil }
        attach()
    }

    var title: String { url.deletingPathExtension().lastPathComponent }

    private static func sign(_ url: URL) -> String? {
        guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        return "\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)/\(v.fileSize ?? 0)"
    }

    private func attach() {
        listener = doc.listen { [weak self] event in
            guard let self else { return }
            switch event {
            case .state, .pages, .meta:
                self.tick += 1
                if self.doc.modified { self.scheduleSave() }
            default:
                break
            }
        }
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.save() }
        }
    }

    /// Write the notebook if it changed. The file is written off the main thread unless
    /// `wait` asks for it to be on disk before this returns.
    func save(wait: Bool = false) {
        saveTimer?.invalidate()
        saveTimer = nil
        guard doc.modified, !suspended else {
            if wait { saveQueue.sync {} }
            return
        }
        let snap = doc.snapshot()
        let url = url, doc = doc
        doc.savedRev = snap.rev
        let write = { () -> String? in
            do {
                try Document.write(snap, to: url)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        if wait {
            var failure: String?
            saveQueue.sync { failure = write() }
            finishSave(doc, url, failure)
        } else {
            saveQueue.async {
                let failure = write()
                DispatchQueue.main.async { self.finishSave(doc, url, failure) }
            }
        }
    }

    private func finishSave(_ doc: Document, _ url: URL, _ failure: String?) {
        if let failure {
            doc.savedRev = -1   // still to be written
            onError?(trf("自动保存失败：%s", failure))
        } else if url == self.url {
            signature = Self.sign(url)
        }
    }

    func close() {
        canvas.cancelOp()
        save(wait: true)
        ToolState.shared.p.lastPages[doc.id] = page
        if let memo = canvas.viewMemo() { ToolState.shared.remember(view: memo, of: doc.id) }
    }

    /// The file was renamed or moved (by the user here, or by a sync).
    func moved(to new: URL) {
        url = new
        doc.url = new
        signature = Self.sign(new)
    }

    /// Whether something other than this editor has written the file.
    var changedOnDisk: Bool { Self.sign(url) != signature }

    /// Take in what a sync wrote to the file: load it again, or, when there are edits
    /// here that it does not have, fold it into them item by item.
    func absorb() throws {
        let loaded = try Document.load(url)
        if doc.modified {
            canvas.cancelOp()
            canvas.clearSelection()
            merge(doc, loaded)
            signature = Self.sign(url)
            tick += 1
            scheduleSave()
            return
        }
        if let listener { doc.listeners[listener] = nil }
        doc = loaded
        signature = Self.sign(url)
        canvas.setDocument(loaded)
        attach()
        tick += 1
    }
}

@MainActor
final class AppModel: ObservableObject {
    let store = Store()
    let tools = ToolState.shared
    private let auth = GoogleAuth()

    @Published var session: EditorSession?
    @Published var libraryTick = 0
    @Published var toast: String?
    @Published var libraryAction: String?      // "new-notebook" or "new-board", for the library to carry out
    @Published var toastButton: String?        // a toast can offer one thing to do, as "Undo" after a move
    var toastAction: (() -> Void)?
    var moveUndo: [[(URL, URL)]] = []          // moves in the library, each a list of (where it was, where it went)
    var moveRedo: [[(URL, URL)]] = []
    @Published var alert: String?
    @Published var showSettings = false
    @Published var dialog: DialogBox?   // the dialog card over everything, if one is up
    var settingsOpen: Bool { showSettings }   // the settings sheet shows alerts itself while it is up

    /// Show a dialog card in the middle of the window.
    func present<V: View>(_ view: V, width: CGFloat = 820, height: CGFloat? = 600) {
        dialog = DialogBox(view: AnyView(view), width: width, height: height)
    }

    func dismissDialog() { dialog = nil }
    @Published var connected = GoogleAccount.connected
    @Published var syncing = false
    @Published var syncFraction = 0.0
    @Published var syncText = ""
    @Published var syncError: String?
    @Published var lastSync: Date?

    private var toastTimer: Timer?
    private var syncTask: Task<Void, Never>?

    init() {
        lastSync = LibrarySync.lastSync(store.root)
        // Every ten minutes while the library is showing, as the desktop does.
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.session == nil, UIApplication.shared.applicationState == .active else { return }
                self.sync(quiet: true)
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demo") { Demo.populate(store) }
        if let shots = ProcessInfo.processInfo.environment["INKPAD_SNAPSHOT"] {
            // The window's own picture of itself, every few seconds: for looking at the Mac
            // version where the screen cannot be captured. INKPAD_OPEN opens a notebook first.
            var n = 0
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
                    n += 1
                    if n == 2, let name = ProcessInfo.processInfo.environment["INKPAD_OPEN"] {
                        if name.hasPrefix("action:") { self.perform(shortcut: String(name.dropFirst(7))) } else if name == "settings" { self.showSettings = true } else { self.open(self.store.root.appendingPathComponent(name)) }
                    }
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                    try? image.pngData()?.write(to: URL(fileURLWithPath: shots).appendingPathComponent("shot\(n).png"))
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-fakeAccount") {
            // A signed-in account that cannot reach anything, to see the screens a real one shows.
            try? GoogleAccount.saveClient(id: "test.apps.googleusercontent.com", secret: "none")
            Keychain.set("google_token", ["refresh_token": "none"])
            try? LibrarySync.saveJSON(store.root.appendingPathComponent(".sync.json"), ["root": "1AbCdEfGhIjKlMnOpQrStUvWxYz", "last": Date().timeIntervalSince1970])
            connected = GoogleAccount.connected
        }
        #endif
    }

    func show(_ text: String, button: String? = nil, action: (() -> Void)? = nil) {
        toast = text
        toastButton = button
        toastAction = action
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: button == nil ? 2.5 : 5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.toast = nil }
        }
    }

    func refreshLibrary() { libraryTick += 1 }

    // MARK: notebooks

    func open(_ url: URL) {
        do {
            let s = try EditorSession(url: url)
            s.onError = { [weak self] in self?.show($0) }
            s.onToast = { [weak self] in self?.show($0) }
            session = s
            let rel = store.rel(url)
            if !rel.hasPrefix(".") {
                tools.p.recent = Array(([rel] + tools.p.recent.filter { $0 != rel }).prefix(8))
                Shortcuts.refresh(recent: recentPaths())
            }
        } catch {
            alert = tr("无法打开笔记本") + "\n" + error.localizedDescription
        }
    }

    /// The notebooks opened last that are still where they were.
    func recentPaths() -> [String] {
        tools.p.recent.filter { FileManager.default.fileExists(atPath: store.root.appendingPathComponent($0).path) }
    }

    /// Something was chosen from the menu of the app's icon.
    func perform(shortcut action: String) {
        dismissDialog()
        showSettings = false
        if action.hasPrefix("open:") {
            let url = store.root.appendingPathComponent(String(action.dropFirst(5)))
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            if session?.url.standardizedFileURL == url.standardizedFileURL { return }
            if session != nil { closeEditor() }
            open(url)
        } else {
            if session != nil { closeEditor() }
            libraryAction = action   // the library asks for the paper, as its New button does
        }
    }

    func closeEditor() {
        session?.close()
        session = nil
        refreshLibrary()
        sync(quiet: true)
    }

    /// A file handed to the app from outside: a notebook or a PDF.
    func openExternal(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        closeIfOpen()
        do {
            if store.contains(url) && url.pathExtension == "inkpad" {
                open(url)
            } else if url.pathExtension.lowercased() == "pdf" {
                open(try store.importPDF(store.root, name: url.deletingPathExtension().lastPathComponent, data: Data(contentsOf: url)))
            } else if url.pathExtension.lowercased() == "goodnotes" {
                let (new, stats) = try store.importGoodnotes(store.root, source: url)
                open(new)
                show(goodnotesSummary(stats))
            } else {
                open(try store.importNotebook(url, into: store.root))
            }
            refreshLibrary()
        } catch {
            alert = tr("无法打开文件") + "\n" + error.localizedDescription
        }
    }

    private func closeIfOpen() {
        if session != nil {
            session?.close()
            session = nil
        }
    }

    // MARK: sync

    func connect() {
        Task {
            do {
                try await auth.authorize()
                connected = GoogleAccount.connected
                show(tr("已连接"))
                sync(quiet: false)
            } catch {
                alert = error.localizedDescription
            }
        }
    }

    func disconnect() {
        Task {
            await GoogleAccount.disconnect()
            connected = false
            show(tr("已断开连接"))
        }
    }

    /// Merge the library with Google Drive. A notebook open in the editor is left alone,
    /// unless `includeOpen` says nobody is writing in it (the app is in the background).
    func sync(quiet: Bool, includeOpen: Bool = false) {
        connected = GoogleAccount.connected
        guard connected else {
            if !quiet { alert = tr("尚未连接 Google Drive") }
            return
        }
        guard !syncing else { return }
        syncing = true
        syncFraction = 0
        syncText = ""
        syncError = nil
        let root = store.root
        var skip: [URL] = []
        if let session {
            session.save(wait: true)
            if includeOpen { session.suspended = true } else { skip = [session.url] }
        }
        let background = UIApplication.shared.beginBackgroundTask(withName: "sync") { [weak self] in self?.syncTask?.cancel() }
        let pace = Pace()
        syncTask = Task {
            var summary: SyncSummary?
            var failure: String?
            do {
                summary = try await Task.detached(priority: .utility) {
                    try await LibrarySync.sync(root: root, drive: GoogleDrive(), skip: skip, folder: GoogleAccount.folderID) { fraction, text in
                        // A transfer reports every few kilobytes; the screen need not hear of each.
                        guard pace.due(fraction) else { return }
                        Task { @MainActor in
                            self.syncFraction = fraction
                            self.syncText = text
                        }
                    }
                }.value
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
            }
            syncing = false
            syncTask = nil
            lastSync = LibrarySync.lastSync(root)
            store.reloadMeta()
            refreshLibrary()
            session?.suspended = false
            followOpenNotebook()
            session?.save()
            if let failure {
                syncError = failure
                if !quiet { alert = trf("同步失败：%s", failure) }
            } else if let s = summary, !quiet {
                show(s == SyncSummary() ? tr("已是最新") : trf("上传 %d，下载 %d，合并 %d", s.up, s.down, s.merged))
            }
            UIApplication.shared.endBackgroundTask(background)
        }
    }

    /// After a sync the open notebook may have been replaced, merged, moved or deleted.
    private func followOpenNotebook() {
        guard let session else { return }
        if !FileManager.default.fileExists(atPath: session.url.path) {
            let id = session.doc.id
            if let new = LibrarySync.scan(store.root).0.values.first(where: { (try? Notebook.id(of: $0)) == id }) {
                session.moved(to: new)
            } else {
                // Deleted on another device: it is in the trash here now.
                self.session = nil
                show(tr("已删除"))
            }
            return
        }
        if session.changedOnDisk {
            do {
                try session.absorb()
                show(tr("此笔记本已在其他设备上更改，已重新载入"))
            } catch {
                alert = tr("无法打开笔记本") + "\n" + error.localizedDescription
            }
        }
    }

    /// Run a job that talks to Drive while nothing else may sync (the storage manager's).
    func withDrive<T>(_ job: @escaping (GoogleDrive, @escaping (Double, String) -> Void) async throws -> T) async throws -> T {
        guard !syncing else { throw DriveError(tr("正在同步，请等同步结束后再试")) }
        syncing = true
        syncFraction = 0
        defer {
            syncing = false
            refreshLibrary()
        }
        return try await Task.detached(priority: .utility) {
            try await job(GoogleDrive()) { fraction, text in
                Task { @MainActor in
                    self.syncFraction = fraction
                    self.syncText = text
                }
            }
        }.value
    }

    func phaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            session?.save(wait: true)
            sync(quiet: true, includeOpen: true)
        case .active:
            if connected, !syncing, Date().timeIntervalSince(lastSync ?? .distantPast) > 120 { sync(quiet: true) }
        default:
            session?.save()
        }
    }
}

/// Lets a progress report through ten times a second at most (and always the last one).
final class Pace: @unchecked Sendable {
    private var last = 0.0
    private let lock = NSLock()

    func due(_ fraction: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        if fraction < 1, now - last < 0.1 { return false }
        last = now
        return true
    }
}
