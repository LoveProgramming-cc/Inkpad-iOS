import UIKit

/// What a long press on the app's icon offers: a new notebook, a new whiteboard, and the
/// notebooks opened last.
enum Shortcuts {
    static var pending: String?                 // chosen before the window was up
    static var handler: ((String) -> Void)?

    /// "new-notebook", "new-board", or "open:" and a path inside the library.
    static func chosen(_ item: UIApplicationShortcutItem) {
        let action = item.type == "open" ? "open:" + (item.userInfo?["path"] as? String ?? "") : item.type
        if let handler { handler(action) } else { pending = action }
    }

    static func refresh(recent: [String]) {
        var items = [
            UIApplicationShortcutItem(type: "new-notebook", localizedTitle: tr("新建笔记本"), localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "square.and.pencil")),
            UIApplicationShortcutItem(type: "new-board", localizedTitle: tr("新建白板"), localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "rectangle.dashed")),
        ]
        for rel in recent.prefix(3) {
            let name = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
            let folder = (rel as NSString).deletingLastPathComponent
            items.append(UIApplicationShortcutItem(type: "open", localizedTitle: name, localizedSubtitle: folder.isEmpty ? nil : folder,
                                                   icon: UIApplicationShortcutIcon(systemImageName: "book.closed"),
                                                   userInfo: ["path": rel as NSString]))
        }
        UIApplication.shared.shortcutItems = items
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if let item = options.shortcutItem { Shortcuts.chosen(item) }
        #if targetEnvironment(macCatalyst)
        // On the Mac the header bar is the window's own: no title above it, and no window so
        // small that the tools do not fit.
        if let scene = scene as? UIWindowScene {
            scene.titlebar?.titleVisibility = .hidden
            scene.titlebar?.toolbar = nil
            scene.sizeRestrictions?.minimumSize = CGSize(width: 760, height: 560)
        }
        #endif
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        Shortcuts.chosen(shortcutItem)
        completionHandler(true)
    }
}
