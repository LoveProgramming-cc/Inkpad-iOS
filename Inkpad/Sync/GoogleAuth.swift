import AuthenticationServices
import CryptoKit
import Network
import UIKit

/// The OAuth consent flow with PKCE.
///
/// With a "Desktop app" client (the one the desktop version uses, which has a secret) the
/// redirect goes to a one-shot loopback server inside this app, exactly as on the desktop.
/// With an "iOS" client (no secret) it comes back through the client's own URL scheme.
@MainActor
final class GoogleAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var listener: NWListener?
    private var waiting: CheckedContinuation<[String: String], Error>?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first.map { UIWindow(windowScene: $0) } ?? ASPresentationAnchor()
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard let waiting else { return }
        self.waiting = nil
        waiting.resume(with: result)
    }

    private static func urlSafe(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func random(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return urlSafe(Data(bytes))
    }

    /// Run the consent flow and store the tokens.
    func authorize() async throws {
        guard GoogleAccount.client != nil else { throw DriveError(tr("请先填写并保存凭据")) }
        let clientID = GoogleAccount.clientID, secret = GoogleAccount.clientSecret
        let verifier = Self.random(64), state = Self.random(16)
        let challenge = Self.urlSafe(Data(SHA256.hash(data: Data(verifier.utf8))))
        var redirect: String
        var scheme: String?
        if secret.isEmpty {
            scheme = clientID.split(separator: ".").reversed().joined(separator: ".")
            redirect = scheme! + ":/oauth2redirect"
        } else {
            redirect = "http://127.0.0.1:\(try await startListener())"
        }
        defer {
            listener?.cancel()
            listener = nil
            session?.cancel()
            session = nil
        }
        var url = URLComponents(string: GoogleAccount.authURI)!
        url.queryItems = [
            "client_id": clientID, "redirect_uri": redirect, "response_type": "code", "scope": GoogleAccount.scope,
            "access_type": "offline", "prompt": "consent", "state": state,
            "code_challenge": challenge, "code_challenge_method": "S256",
        ].map { URLQueryItem(name: $0.key, value: $0.value) }

        let result: [String: String] = try await withCheckedThrowingContinuation { continuation in
            waiting = continuation
            let session = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: scheme) { [weak self] callback, error in
                Task { @MainActor in
                    if let callback, let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems {
                        self?.finish(.success(Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })))
                    } else {
                        // Dismissed by hand; when the loopback server already has the code this does nothing.
                        self?.finish(.failure(DriveError(tr("授权未完成"))))
                    }
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { finish(.failure(DriveError(tr("授权未完成")))) }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                self?.finish(.failure(DriveError(tr("等待授权超时"))))
            }
        }
        guard let code = result["code"], result["state"] == state else { throw DriveError(tr("授权未完成")) }
        let token = try await GoogleAccount.post(GoogleAccount.tokenURI, [
            "client_id": clientID, "client_secret": secret, "code": code, "code_verifier": verifier,
            "grant_type": "authorization_code", "redirect_uri": redirect])
        guard token["refresh_token"] is String else { throw DriveError(tr("Google 没有返回刷新令牌，请重试")) }
        Keychain.set("google_token", nil)
        GoogleAccount.storeToken(token)
    }

    /// A one-shot HTTP server on the loopback interface; returns its port.
    private func startListener() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let head = String(decoding: data ?? Data(), as: UTF8.self).split(separator: "\r\n").first.map(String.init) ?? ""
                let parts = head.split(separator: " ")
                var query: [String: String] = [:]
                if parts.count > 1, let items = URLComponents(string: "http://127.0.0.1" + parts[1])?.queryItems {
                    for item in items { query[item.name] = item.value ?? "" }
                }
                let done = query["code"] != nil || query["error"] != nil
                let text = query["code"] != nil ? tr("授权完成，可以关闭此页面并回到 Inkpad。") : done ? tr("授权被取消。") : "Inkpad"
                let body = "<!doctype html><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>Inkpad</title>"
                    + "<body style=\"font-family:sans-serif;text-align:center;margin-top:18vh\"><h2>\(text)</h2></body>"
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                    if done {
                        Task { @MainActor in
                            self?.finish(query["code"] != nil ? .success(query) : .failure(DriveError(tr("授权未完成"))))
                        }
                    }
                })
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .main)
        }
    }
}
