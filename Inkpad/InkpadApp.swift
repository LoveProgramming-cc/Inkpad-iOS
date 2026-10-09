import SwiftUI

@main
struct InkpadApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppModel()
    @ObservedObject private var tools = ToolState.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .tint(Theme.accent)
                .preferredColorScheme(tools.p.theme == "light" ? .light : tools.p.theme == "dark" ? .dark : nil)
                .onOpenURL { app.openExternal($0) }
                .onChange(of: phase) { _, new in app.phaseChanged(new) }
                .task { app.sync(quiet: true) }
                .task {
                    // What was chosen from the app icon's menu, now and from here on.
                    Shortcuts.handler = { action in app.perform(shortcut: action) }
                    Shortcuts.refresh(recent: app.recentPaths())
                    if let action = Shortcuts.pending {
                        Shortcuts.pending = nil
                        app.perform(shortcut: action)
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ZStack {
            if let session = app.session {
                EditorView(session: session)
                    .id(session.id)
                    .transition(.opacity)
            } else {
                LibraryView()
                    .transition(.opacity)
            }
            if let dialog = app.dialog {
                // A dialog card in the middle of the window, as on the desktop.
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .onTapGesture { app.dismissDialog() }
                    .transition(.opacity)
                GeometryReader { geo in
                    dialog.view
                        .frame(width: min(dialog.width, geo.size.width - 32), height: dialog.height.map { min($0, geo.size.height - 32) })
                        .fixedSize(horizontal: false, vertical: dialog.height == nil)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .id(dialog.id)
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: app.session?.id)
        .animation(.easeOut(duration: 0.16), value: app.dialog?.id)
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                // Adwaita's toast: a dark rounded slab near the bottom edge.
                HStack(spacing: 14) {
                    Text(toast)
                    if let label = app.toastButton {
                        Button(label) {
                            app.toast = nil
                            app.toastAction?()
                        }
                        .buttonStyle(.plain)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 28)
                        .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, app.toastButton == nil ? 11 : 7)
                    .background(Color(white: 0.16).opacity(0.94), in: Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
                    .padding(.bottom, 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: app.toast)
        .sheet(isPresented: $app.showSettings) {
            SettingsView()
                .environmentObject(app)
                .tint(Theme.accent)
                .preferredColorScheme(ToolState.shared.p.theme == "light" ? .light : ToolState.shared.p.theme == "dark" ? .dark : nil)
                .alert(tr("操作失败"), isPresented: Binding(get: { app.alert != nil && app.showSettings }, set: { if !$0 { app.alert = nil } })) {
                    Button(tr("好")) {}
                } message: {
                    Text(app.alert ?? "")
                }
        }
        .alert(tr("操作失败"), isPresented: Binding(get: { app.alert != nil && !app.showSettings }, set: { if !$0 { app.alert = nil } })) {
            Button(tr("好")) {}
        } message: {
            Text(app.alert ?? "")
        }
    }
}
