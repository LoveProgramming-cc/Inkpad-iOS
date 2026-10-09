import Foundation
import Security

/// Small secrets (the OAuth client and its tokens) kept in the keychain. On the Mac they are
/// files only their owner can read, as the desktop app keeps them: a Mac app that is not
/// signed by a registered developer is not given a keychain of its own.
enum Keychain {
    private static let service = "io.github.inkpad"

    /// The folder the Mac keeps them in.
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Inkpad", isDirectory: true)
    }

    private static func file(_ key: String) -> URL { folder.appendingPathComponent(key + ".json") }

    static func get(_ key: String) -> [String: Any]? {
        if Platform.isMac {
            guard let data = try? Data(contentsOf: file(key)) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func set(_ key: String, _ value: [String: Any]?) {
        if Platform.isMac {
            let fm = FileManager.default
            try? fm.removeItem(at: file(key))
            guard let value, let data = try? JSONSerialization.data(withJSONObject: value) else { return }
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            fm.createFile(atPath: file(key).path, contents: data, attributes: [.posixPermissions: 0o600])
            return
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// The OAuth client and the signed-in account.
enum GoogleAccount {
    static let scope = "https://www.googleapis.com/auth/drive.file"
    static let authURI = "https://accounts.google.com/o/oauth2/auth"
    static let tokenURI = "https://oauth2.googleapis.com/token"

    static var client: [String: Any]? { Keychain.get("google_client") }
    static var token: [String: Any]? { Keychain.get("google_token") }
    static var connected: Bool { token?["refresh_token"] != nil && client != nil }
    static var clientID: String { client?["client_id"] as? String ?? "" }
    static var clientSecret: String { client?["client_secret"] as? String ?? "" }
    /// The Drive folder the user asked the library to be kept in, or "" for a folder named
    /// Inkpad at the top of their Drive. It is kept with the client credentials, so that the
    /// one exported file carries everything another device needs.
    static var folderID: String { client?["inkpad_folder"] as? String ?? "" }

    static func setFolderID(_ value: String) throws {
        guard var c = client else { throw DriveError(tr("请先填写并保存凭据")) }
        c["inkpad_folder"] = value
        Keychain.set("google_client", c)
    }

    /// The client credentials and the folder id, in the form the desktop app imports, for
    /// setting up another device.
    static func exportClient() throws -> Data {
        guard var c = client else { throw DriveError(tr("请先填写并保存凭据")) }
        let folder = c.removeValue(forKey: "inkpad_folder") as? String ?? ""
        return try JSONSerialization.data(withJSONObject: ["inkpad_folder": folder, "installed": c], options: [.prettyPrinted, .sortedKeys])
    }

    /// Use an OAuth client typed in by hand. Changing the client drops the current sign-in.
    static func saveClient(id: String, secret: String) throws {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines), secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasSuffix(".apps.googleusercontent.com") else {
            throw DriveError(tr("客户端 ID 应以 .apps.googleusercontent.com 结尾"))
        }
        if clientID != id { Keychain.set("google_token", nil) }
        Keychain.set("google_client", ["client_id": id, "client_secret": secret, "auth_uri": authURI, "token_uri": tokenURI,
                                       "inkpad_folder": folderID])
    }

    /// Adopt an OAuth client file downloaded from the Google Cloud console.
    static func importClient(_ data: Data) throws {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let c = (json?["installed"] ?? json?["web"]) as? [String: Any], let id = c["client_id"] as? String else {
            throw DriveError(tr("无法使用这个凭据文件"))
        }
        try saveClient(id: id, secret: c["client_secret"] as? String ?? "")
        // A file exported from Inkpad names the folder to sync with; one from Google does not,
        // and leaves that as it is here.
        if let folder = json?["inkpad_folder"] as? String { try setFolderID(folder) }
    }

    static func post(_ url: String, _ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DriveError(trf("无法连接 Google：%s", error.localizedDescription))
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw DriveError("Google (\(code)): " + String(decoding: data.prefix(300), as: UTF8.self))
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func storeToken(_ token: [String: Any], refresh: String? = nil) {
        var saved = self.token ?? [:]
        if let r = (token["refresh_token"] as? String) ?? refresh { saved["refresh_token"] = r }
        saved["access_token"] = token["access_token"]
        saved["expires_at"] = Date().timeIntervalSince1970 + num(token["expires_in"], 3600) - 60
        Keychain.set("google_token", saved)
    }

    /// Forget the account: revoke the grant (best effort) and delete the stored tokens.
    static func disconnect() async {
        if let refresh = token?["refresh_token"] as? String {
            _ = try? await post("https://oauth2.googleapis.com/revoke", ["token": refresh])
        }
        Keychain.set("google_token", nil)
    }
}

/// Drive over REST. The scope is drive.file, so the app only sees files made with the same
/// OAuth client, inside one "Inkpad" folder.
final class GoogleDrive: NSObject, DriveAPI, URLSessionTaskDelegate {
    static let api = "https://www.googleapis.com/drive/v3"
    static let uploadAPI = "https://www.googleapis.com/upload/drive/v3/files"
    static let folderMime = "application/vnd.google-apps.folder"

    var onBytes: ((Int64, Int64) -> Void)?
    private var token: [String: Any]
    private var watch: NSKeyValueObservation?

    override init() {
        token = GoogleAccount.token ?? [:]
        super.init()
    }

    private func access() async throws -> String {
        guard let refresh = token["refresh_token"] as? String, GoogleAccount.client != nil else {
            throw DriveError(tr("尚未连接 Google Drive"))
        }
        if Date().timeIntervalSince1970 >= num(token["expires_at"]) || token["access_token"] == nil {
            let fresh = try await GoogleAccount.post(GoogleAccount.tokenURI, [
                "client_id": GoogleAccount.clientID, "client_secret": GoogleAccount.clientSecret,
                "refresh_token": refresh, "grant_type": "refresh_token"])
            GoogleAccount.storeToken(fresh, refresh: refresh)
            token = GoogleAccount.token ?? token
        }
        return token["access_token"] as? String ?? ""
    }

    private func request(_ method: String, _ url: String, headers: [String: String] = [:]) async throws -> URLRequest {
        guard let u = URL(string: url) else { throw DriveError("bad url") }
        var r = URLRequest(url: u, timeoutInterval: 120)
        r.httpMethod = method
        r.setValue("Bearer " + (try await access()), forHTTPHeaderField: "Authorization")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    private func check(_ data: Data, _ response: URLResponse) throws -> HTTPURLResponse {
        let http = response as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            var detail = String(decoding: data.prefix(300), as: UTF8.self)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = (json["error"] as? [String: Any])?["message"] as? String { detail = message }
            throw DriveError("Google Drive (\(http.statusCode)): \(detail)", code: http.statusCode)
        }
        return http
    }

    private func send(_ r: URLRequest, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        var r = r
        r.httpBody = body
        do {
            let (data, response) = try await URLSession.shared.data(for: r)
            return (data, try check(data, response))
        } catch let error as DriveError {
            throw error
        } catch {
            throw DriveError(trf("无法连接 Google：%s", error.localizedDescription))
        }
    }

    private func json(_ method: String, _ url: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        let r = try await request(method, url, headers: body == nil ? [:] : ["Content-Type": "application/json"])
        let (data, _) = try await send(r, body: body.map { try! JSONSerialization.data(withJSONObject: $0) })
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func query(_ fields: [String: String]) -> String {
        var c = URLComponents()
        c.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        return (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }

    private func quoted(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    func createFolder(_ name: String, parent: String) async throws -> String {
        let made = try await json("POST", Self.api + "/files?fields=id", ["name": name, "mimeType": Self.folderMime, "parents": [parent]])
        return made["id"] as? String ?? ""
    }

    func root() async throws -> String {
        let q = "name = '\(LibrarySync.rootName)' and mimeType = '\(Self.folderMime)' and 'root' in parents and trashed = false"
        let found = try await json("GET", Self.api + "/files?" + query(["q": q, "fields": "files(id)"]))
        if let id = ((found["files"] as? [[String: Any]])?.first)?["id"] as? String { return id }
        return try await createFolder(LibrarySync.rootName, parent: "root")
    }

    func alive(_ fileID: String) async throws -> Bool {
        do {
            return try await json("GET", "\(Self.api)/files/\(fileID)?fields=trashed")["trashed"] as? Bool != true
        } catch let error as DriveError where error.code == 404 {
            return false
        }
    }

    func children(_ parent: String) async throws -> [DriveFile] {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [DriveFile] = []
        var page: String?
        repeat {
            var fields = ["q": "'\(parent)' in parents and trashed = false", "pageSize": "1000",
                          "fields": "nextPageToken, files(id, name, md5Checksum, modifiedTime)"]
            if let page { fields["pageToken"] = page }
            let found = try await json("GET", Self.api + "/files?" + query(fields))
            for f in found["files"] as? [[String: Any]] ?? [] {
                guard let id = f["id"] as? String, let name = f["name"] as? String else { continue }
                let when = (f["modifiedTime"] as? String).flatMap { stamp.date(from: $0) }?.timeIntervalSince1970 ?? 0
                out.append(DriveFile(id: id, name: name, md5: f["md5Checksum"] as? String, modified: when))
            }
            page = found["nextPageToken"] as? String
        } while page != nil
        return out
    }

    func find(_ name: String, parent: String) async throws -> String? {
        let q = "name = '\(quoted(name))' and '\(parent)' in parents and trashed = false"
        let found = try await json("GET", Self.api + "/files?" + query(["q": q, "fields": "files(id)"]))
        return ((found["files"] as? [[String: Any]])?.first)?["id"] as? String
    }

    func getJSON(_ fileID: String) async throws -> [String: Any] {
        let (data, _) = try await send(try await request("GET", "\(Self.api)/files/\(fileID)?alt=media"))
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func putJSON(_ name: String, _ value: [String: Any], parent: String, fileID: String?) async throws -> String {
        let boundary = "inkpad" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let meta: [String: Any] = fileID != nil ? [:] : ["name": name, "parents": [parent]]
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(try JSONSerialization.data(withJSONObject: meta))
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/json\r\n\r\n".utf8))
        body.append(try JSONSerialization.data(withJSONObject: value))
        body.append(Data("\r\n--\(boundary)--".utf8))
        let url = Self.uploadAPI + (fileID.map { "/" + $0 } ?? "") + "?uploadType=multipart&fields=id"
        let r = try await request(fileID != nil ? "PATCH" : "POST", url,
                                  headers: ["Content-Type": "multipart/related; boundary=" + boundary])
        let (data, _) = try await send(r, body: body)
        guard let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else {
            throw DriveError("Google Drive: no file id")
        }
        return id
    }

    func rename(_ fileID: String, _ name: String) async throws {
        _ = try await json("PATCH", "\(Self.api)/files/\(fileID)?fields=id", ["name": name])
    }

    func upload(_ url: URL, name: String, parent: String, fileID: String?) async throws -> (String, String?) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let start = fileID.map { "\(Self.uploadAPI)/\($0)?uploadType=resumable&fields=id,md5Checksum" }
            ?? Self.uploadAPI + "?uploadType=resumable&fields=id,md5Checksum"
        let meta: [String: Any] = fileID != nil ? [:] : ["name": name, "parents": [parent]]
        let begin = try await request(fileID != nil ? "PATCH" : "POST", start, headers: [
            "Content-Type": "application/json; charset=UTF-8", "X-Upload-Content-Type": "application/zip",
            "X-Upload-Content-Length": String(size)])
        let (_, response) = try await send(begin, body: try JSONSerialization.data(withJSONObject: meta))
        guard let session = response.value(forHTTPHeaderField: "Location") else { throw DriveError("Google Drive: no upload session") }
        var put = try await request("PUT", session, headers: ["Content-Type": "application/zip"])
        put.timeoutInterval = 600
        do {
            let (data, resp) = try await URLSession.shared.upload(for: put, fromFile: url, delegate: self)
            _ = try check(data, resp)
            let made = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            guard let id = made["id"] as? String else { throw DriveError("Google Drive: no file id") }
            return (id, made["md5Checksum"] as? String)
        } catch let error as DriveError {
            throw error
        } catch {
            throw DriveError(trf("无法连接 Google：%s", error.localizedDescription))
        }
    }

    func download(_ fileID: String, to dest: URL) async throws {
        let r = try await request("GET", "\(Self.api)/files/\(fileID)?alt=media")
        do {
            let (tmp, resp) = try await URLSession.shared.download(for: r, delegate: self)
            defer { try? FileManager.default.removeItem(at: tmp) }
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                _ = try check((try? Data(contentsOf: tmp)) ?? Data(), resp)
            }
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
        } catch let error as DriveError {
            throw error
        } catch {
            throw DriveError(trf("无法连接 Google：%s", error.localizedDescription))
        }
    }

    // MARK: transfer progress

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onBytes?(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        guard task is URLSessionDownloadTask else { return }
        watch = task.progress.observe(\.completedUnitCount) { [weak self] progress, _ in
            if progress.totalUnitCount > 0 { self?.onBytes?(progress.completedUnitCount, progress.totalUnitCount) }
        }
    }
}
