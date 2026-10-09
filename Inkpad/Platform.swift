import UIKit

/// What differs between the iPad, the iPhone and the Mac (where the app runs as Mac Catalyst).
enum Platform {
    #if targetEnvironment(macCatalyst)
    static let isMac = true
    #else
    static let isMac = false
    #endif
    static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// Where the library is kept. On the Mac the documents folder is the user's own, shared
    /// with everything else they have: the library gets a folder of its own inside it, the
    /// same one the desktop app uses.
    static var libraryRoot: URL {
        // INKPAD_LIBRARY puts it somewhere else, for trying things out without touching the real one.
        if let other = ProcessInfo.processInfo.environment["INKPAD_LIBRARY"], !other.isEmpty { return URL(fileURLWithPath: other, isDirectory: true) }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return isMac ? docs.appendingPathComponent("Inkpad", isDirectory: true) : docs
    }

    /// The library's place as the user would look for it.
    static var libraryPlace: String {
        if isMac { return (libraryRoot.path as NSString).abbreviatingWithTildeInPath }
        return tr(isPhone ? "“文件”App › 我的 iPhone › Inkpad" : "“文件”App › 我的 iPad › Inkpad")
    }

    /// Where the sign-in for Google Drive is kept, as the user would be told.
    static var secretsPlace: String {
        isMac ? (Keychain.folder.path as NSString).abbreviatingWithTildeInPath : tr("本机钥匙串")
    }

    /// Show the library folder: in the Finder, or in the Files app.
    static func revealLibrary() {
        if isMac {
            UIApplication.shared.open(libraryRoot)
        } else if let url = URL(string: "shareddocuments://" + (libraryRoot.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")) {
            UIApplication.shared.open(url)
        }
    }
}
