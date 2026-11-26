import UIKit
import Security
import LocalAuthentication
import WebKit
import SafariServices
import CoreImage

// ---------------------------------------------------------------------------
// Device pairing (OAuth 2.0 Device Authorization Grant, RFC 8628) with rotating
// refresh tokens (RFC 6749 §6 / RFC 9700) and revocation (RFC 7009).
//
// Only active when the server advertises `device_authorization_endpoint` in
// GET <origin>/.well-known/oauth-authorization-server (JSON). Otherwise nothing here runs
// and the app behaves as before (sign in inside the web view).
//
// Rules:
//  - The refresh token lives ONLY in the Keychain (this device only, never synced), optionally
//    behind Face ID / passcode (.userPresence). It is cached in memory for this launch so
//    Face ID is asked at most once per launch. Never in UserDefaults, URLs or logs.
//  - A rotated refresh token is written to the Keychain BEFORE the new access token is used.
//  - Refreshes for one server are serialized (a parallel refresh would reuse the old token,
//    which the server treats as theft and revokes the grant).
//  - Tokens are sent only to the server's own configured origins: endpoints from the metadata
//    must be on one of the server's URLs, and are called on the origin being loaded.
//  - The access token (5 min) is only used once, to have the server set its normal session
//    cookies (POST /api/auth/device-session), which are then put into the web view's cookie store.
//  - Requests use the same certificate rules as the web view (TrustStore), never follow
//    redirects, and do not share cookies with anything.
// ---------------------------------------------------------------------------

/// Extension point for other sign-in integrations (for example an organisation's own single
/// sign-on). Runs before every load of a server page, after device sign-in; may set cookies in
/// WKWebsiteDataStore.default(). Nothing is registered by default.
enum SignInHooks {
    @MainActor static var beforeLoad: ((ServerConfig, URL) async -> Void)?
}

extension Notification.Name {
    /// The server rejected this phone's refresh token (revoked / expired / reused). userInfo["serverID"].
    static let deviceAuthNeedsPairing = Notification.Name("kirocrew.deviceAuthNeedsPairing")
}

struct AuthMetadata {
    let deviceEndpoint: URL
    let tokenEndpoint: URL
    let revocationEndpoint: URL?
}

struct DeviceCode {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    /// verification_uri with the code filled in (RFC 8628 §3.3.1), for the QR code.
    let verificationURIComplete: String
    let interval: Int
    let expiresIn: Int
}

enum PollResult {
    case pending, slowDown, success, denied, expired
    case failed(String)
}

enum DeviceAuthError: LocalizedError {
    case unsupported, badResponse, server(String), keychain
    var errorDescription: String? {
        switch self {
        case .unsupported: return "This server does not offer device sign-in."
        case .badResponse: return "The server sent an unexpected answer."
        case .server(let s): return s
        case .keychain: return "Could not save the sign-in in the Keychain."
        }
    }
}

actor DeviceAuth {
    static let shared = DeviceAuth()
    static let clientID = "kirocrew-ios"
    private static let tokenService = appIdentifier + ".device-refresh"   // account = serverID; secret
    private static let metaService = appIdentifier + ".device-meta"       // account = serverID; device name only

    private var metadataCache: [String: AuthMetadata] = [:]
    private var negativeCache: [String: Date] = [:]
    private var tokenCache: [String: String] = [:]
    private var chains: [String: Task<Void, Never>] = [:]

    // MARK: Pairing state (no secrets, no prompts)

    nonisolated static func isPaired(serverID: String) -> Bool {
        Keychain.get(service: metaService, account: serverID) != nil
    }

    nonisolated static func pairedName(serverID: String) -> String? { pairedInfo(serverID: serverID)?["name"] }
    /// The server's id for this phone's grant (as shown in its Devices list).
    nonisolated static func pairedGrant(serverID: String) -> String? { pairedInfo(serverID: serverID)?["grant"] }
    private nonisolated static func pairedInfo(serverID: String) -> [String: String]? {
        guard let d = Keychain.get(service: metaService, account: serverID),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return nil }
        return o
    }

    /// RFC 8628 client_name: printable ASCII only, at most 80 characters.
    nonisolated static func clientName(_ raw: String) -> String {
        let mapped = raw.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
        let ascii = String(mapped.unicodeScalars.filter { (0x20...0x7E).contains($0.value) }.map(Character.init))
        let t = ascii.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "iPhone" : String(t.prefix(80))
    }

    // MARK: Discovery

    /// The server's OAuth metadata if it offers the device grant; nil otherwise (cached per origin).
    func metadata(origin: URL, server: ServerConfig) async -> AuthMetadata? {
        guard let key = originString(origin), server.urls.contains(where: { sameOrigin($0, origin) }) else { return nil }
        if let m = metadataCache[key] { return m }
        if let t = negativeCache[key], Date().timeIntervalSince(t) < 60 { return nil }
        guard let url = Self.url(origin, "/.well-known/oauth-authorization-server") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await Self.send(req, server: server), resp.statusCode == 200,
              (resp.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("json"),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dev = Self.endpoint(o["device_authorization_endpoint"], origin: origin, server: server),
              let tok = Self.endpoint(o["token_endpoint"], origin: origin, server: server) else {
            negativeCache[key] = Date()
            return nil
        }
        if let grants = o["grant_types_supported"] as? [String],
           !grants.contains("urn:ietf:params:oauth:grant-type:device_code") {
            negativeCache[key] = Date()
            return nil
        }
        let m = AuthMetadata(deviceEndpoint: dev, tokenEndpoint: tok,
                             revocationEndpoint: Self.endpoint(o["revocation_endpoint"], origin: origin, server: server))
        metadataCache[key] = m
        return m
    }

    /// An endpoint from the metadata, accepted only if it is on one of this server's configured
    /// URLs; it is then called on the origin being used (same server, same path).
    private static func endpoint(_ v: Any?, origin: URL, server: ServerConfig) -> URL? {
        guard let s = v as? String, let u = URL(string: s), isAllowedServer(u),
              server.urls.contains(where: { sameOrigin($0, u) }) else { return nil }
        return url(origin, u.path)
    }

    private static func url(_ origin: URL, _ path: String) -> URL? {
        guard var c = URLComponents(url: origin, resolvingAgainstBaseURL: false), path.hasPrefix("/") else { return nil }
        c.path = path; c.query = nil; c.fragment = nil
        return c.url
    }

    // MARK: Pairing

    func startPairing(server: ServerConfig, origin: URL, deviceName: String) async throws -> DeviceCode {
        guard let m = await metadata(origin: origin, server: server) else { throw DeviceAuthError.unsupported }
        let (data, resp) = try await Self.send(Self.post(m.deviceEndpoint, [
            "client_id": Self.clientID, "client_name": deviceName, "scope": "dashboard",
        ]), server: server)
        guard resp.statusCode == 200, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if resp.statusCode == 403 {
                throw DeviceAuthError.server("The server does not allow pairing from this address. Pair on your home network "
                    + "or through the server's own address (not a relay)." + (Self.errorText(data).map { "\n\n" + $0 } ?? ""))
            }
            throw DeviceAuthError.server(Self.errorText(data) ?? "The server refused to start pairing (HTTP \(resp.statusCode)).")
        }
        guard let dc = o["device_code"] as? String, let uc = o["user_code"] as? String, !dc.isEmpty,
              uc.count <= 32 else { throw DeviceAuthError.badResponse }
        return DeviceCode(deviceCode: dc, userCode: plainText(uc, 32),
                          verificationURI: plainText(o["verification_uri"], 300),
                          verificationURIComplete: plainText(o["verification_uri_complete"], 500),
                          interval: max((o["interval"] as? NSNumber)?.intValue ?? 5, 1),
                          expiresIn: min(max((o["expires_in"] as? NSNumber)?.intValue ?? 600, 30), 3600))
    }

    /// Gives up a pairing request that was not approved (RFC 7009 with the device code as the
    /// token, which the server reads as "cancel this request"). Best effort; failures are ignored.
    func cancelPairing(server: ServerConfig, origin: URL, code: DeviceCode) async {
        guard let m = await metadata(origin: origin, server: server), let rev = m.revocationEndpoint else { return }
        _ = try? await Self.send(Self.post(rev, ["token": code.deviceCode, "client_id": Self.clientID]), server: server)
    }

    /// One token request for the device code. On success the refresh token is stored and the
    /// web view gets its session cookies for `origin`.
    func poll(server: ServerConfig, origin: URL, code: DeviceCode, deviceName: String) async -> PollResult {
        guard let m = await metadata(origin: origin, server: server) else { return .failed("Device sign-in is no longer offered.") }
        guard let (data, resp) = try? await Self.send(Self.post(m.tokenEndpoint, [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": code.deviceCode, "client_id": Self.clientID,
        ]), server: server) else { return .pending }   // network blip: keep polling
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if resp.statusCode == 429 { return .slowDown }
        if resp.statusCode != 200 {
            switch o?["error"] as? String {
            case "authorization_pending": return .pending
            case "slow_down": return .slowDown
            case "access_denied": return .denied
            case "expired_token": return .expired
            default: return .failed(Self.errorText(data) ?? "Pairing failed (HTTP \(resp.statusCode)).")
            }
        }
        guard let access = o?["access_token"] as? String, let refresh = o?["refresh_token"] as? String,
              !access.isEmpty, !refresh.isEmpty else { return .failed("The server sent an unexpected answer.") }
        // Keychain first, then use the access token.
        guard writeRefresh(refresh, serverID: server.id) else { return .failed(DeviceAuthError.keychain.localizedDescription) }
        var info = ["name": deviceName]
        let grant = plainText(o?["grant_id"], 100)
        if !grant.isEmpty { info["grant"] = grant }
        let meta = (try? JSONSerialization.data(withJSONObject: info)) ?? Data()
        Keychain.set(meta, service: Self.metaService, account: server.id)
        _ = await createSessions(first: origin, accessToken: access, server: server)
        return .success
    }

    // MARK: Session

    /// Makes sure the web view has a valid session for `origin`: already signed in -> nothing;
    /// else refresh (rotating) and have the server set session cookies. False if not paired,
    /// not offered, offline, or the grant is gone (then this phone needs pairing again).
    func ensureSession(server: ServerConfig, origin: URL, force: Bool) async -> Bool {
        guard Self.isPaired(serverID: server.id), server.urls.contains(where: { sameOrigin($0, origin) }) else { return false }
        if !force, await sessionValid(origin: origin, server: server) { return true }
        guard let m = await metadata(origin: origin, server: server) else { return false }
        return await serialized(server.id) {
            // Another load may have refreshed while this one waited: check again before refreshing.
            if !force, await self.sessionValid(origin: origin, server: server) { return true }
            return await self.refreshAndCreateSession(server: server, origin: origin, meta: m)
        }
    }

    private func serialized(_ key: String, _ op: @escaping () async -> Bool) async -> Bool {
        let previous = chains[key]
        let task = Task { () -> Bool in
            _ = await previous?.value
            return await op()
        }
        chains[key] = Task { _ = await task.value }
        return await task.value
    }

    private func refreshAndCreateSession(server: ServerConfig, origin: URL, meta m: AuthMetadata) async -> Bool {
        guard let rt = readRefresh(serverID: server.id) else { return false }
        let req = Self.post(m.tokenEndpoint, ["grant_type": "refresh_token", "refresh_token": rt, "client_id": Self.clientID])
        var answer = try? await Self.send(req, server: server)
        if answer == nil {
            // Lost answer (network): the server accepts the same old refresh token again for 30 s. Retry once.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            answer = try? await Self.send(req, server: server)
        }
        guard let (data, resp) = answer else { return false }
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard resp.statusCode == 200 else {
            if (o?["error"] as? String) == "invalid_grant" {
                wipeLocal(serverID: server.id)
                await Self.clearCookies(server: server)
                await MainActor.run {
                    NotificationCenter.default.post(name: .deviceAuthNeedsPairing, object: nil, userInfo: ["serverID": server.id])
                }
            }
            return false
        }
        guard let access = o?["access_token"] as? String, !access.isEmpty else { return false }
        if let next = o?["refresh_token"] as? String, !next.isEmpty, next != rt {
            // Keychain first. If that fails keep it in memory so this launch still works.
            if !writeRefresh(next, serverID: server.id) { tokenCache[server.id] = next }
        }
        return await createSessions(first: origin, accessToken: access, server: server)
    }

    /// One refresh, then session cookies on EVERY origin of the server (internal and external) with
    /// the same short-lived access token, so switching networks does not need another refresh.
    private func createSessions(first origin: URL, accessToken: String, server: ServerConfig) async -> Bool {
        let ok = await createSession(origin: origin, accessToken: accessToken, server: server)
        for other in server.urls where !sameOrigin(other, origin) {
            _ = await createSession(origin: other, accessToken: accessToken, server: server)
        }
        return ok
    }

    /// POST /api/auth/device-session with the access token; the server answers with Set-Cookie,
    /// which goes into the web view's cookie store.
    private func createSession(origin: URL, accessToken: String, server: ServerConfig) async -> Bool {
        guard let url = Self.url(origin, "/api/auth/device-session") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        guard let (_, resp) = try? await Self.send(req, server: server), (200..<300).contains(resp.statusCode) else { return false }
        var fields: [String: String] = [:]
        for (k, v) in resp.allHeaderFields { if let k = k as? String, let v = v as? String { fields[k] = v } }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !cookies.isEmpty else { return false }
        await Self.setCookies(cookies)
        return true
    }

    /// GET /api/auth/me with the web view's own cookies for this origin.
    private func sessionValid(origin: URL, server: ServerConfig) async -> Bool {
        guard let url = Self.url(origin, "/api/auth/me") else { return false }
        let cookies = await Self.cookies(for: url)
        guard !cookies.isEmpty else { return false }
        var req = URLRequest(url: url)
        for (k, v) in HTTPCookie.requestHeaderFields(with: cookies) { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (_, resp) = try? await Self.send(req, server: server) else { return false }
        return (200..<300).contains(resp.statusCode)
    }

    // MARK: Unpair

    /// Revokes the grant on the server (best effort), deletes the Keychain items and this
    /// server's cookies in the web view.
    func unpair(server: ServerConfig, origin: URL?) async {
        if let rt = readRefresh(serverID: server.id) {
            for o in ([origin].compactMap { $0 } + server.urls) {
                guard let m = await metadata(origin: o, server: server), let rev = m.revocationEndpoint else { continue }
                if let (_, resp) = try? await Self.send(Self.post(rev, [
                    "token": rt, "token_type_hint": "refresh_token", "client_id": Self.clientID,
                ]), server: server), resp.statusCode == 200 { break }
            }
        }
        wipeLocal(serverID: server.id)
        await Self.clearCookies(server: server)
    }

    /// Deleting a server: forget its pairing (also used when the grant is rejected).
    func wipeLocal(serverID: String) {
        tokenCache[serverID] = nil
        Keychain.delete(service: Self.tokenService, account: serverID)
        Keychain.delete(service: Self.metaService, account: serverID)
    }

    // MARK: Keychain (refresh token)

    private func readRefresh(serverID: String) -> String? {
        if let t = tokenCache[serverID] { return t }
        let ctx = LAContext()
        ctx.localizedReason = "Sign in to Kiro Crew"
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: Self.tokenService,
                                kSecAttrAccount as String: serverID,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne,
                                kSecUseAuthenticationContext as String: ctx]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let t = String(data: d, encoding: .utf8), !t.isEmpty else { return nil }
        tokenCache[serverID] = t
        return t
    }

    private func writeRefresh(_ token: String, serverID: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: Self.tokenService,
                                   kSecAttrAccount as String: serverID]
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = Data(token.utf8)
        var gated = false
        if AppPrefs.gateDeviceToken, LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil),
           let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .userPresence, nil) {
            q[kSecAttrAccessControl as String] = acl
            gated = true
        } else {
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        var status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess && gated {
            // No passcode / biometrics available after all: device-only item without the prompt.
            q[kSecAttrAccessControl as String] = nil
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { return false }
        tokenCache[serverID] = token
        return true
    }

    // MARK: HTTP

    private static func post(_ url: URL, _ form: [String: String]) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        r.httpBody = Data(form.map { k, v in
            (k.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + (v.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
        return r
    }

    private static func send(_ req: URLRequest, server: ServerConfig) async throws -> (Data, HTTPURLResponse) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.waitsForConnectivity = false
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        let session = URLSession(configuration: cfg, delegate: AuthSessionDelegate(server: server), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var r = req
        r.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await session.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw DeviceAuthError.badResponse }
        return (data, h)
    }

    /// OAuth error_description (plain text, capped) for messages shown to the user.
    private static func errorText(_ data: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let s = plainText(o["error_description"] ?? o["error"], 200)
        return s.isEmpty ? nil : s
    }

    // MARK: Web view cookies

    @MainActor private static func setCookies(_ cookies: [HTTPCookie]) async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for c in cookies { await store.setCookie(c) }
    }

    @MainActor private static func cookies(for url: URL) async -> [HTTPCookie] {
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        guard let host = url.host?.lowercased() else { return [] }
        let https = url.scheme?.lowercased() == "https"
        let path = url.path.isEmpty ? "/" : url.path
        return all.filter { c in
            let d = c.domain.lowercased()
            let domainOK = d.hasPrefix(".") ? (host == String(d.dropFirst()) || host.hasSuffix(d)) : host == d
            let pathOK = path.hasPrefix(c.path.isEmpty ? "/" : c.path)
            let notExpired = c.expiresDate.map { $0 > Date() } ?? true
            return domainOK && pathOK && notExpired && (!c.isSecure || https)
        }
    }

    @MainActor static func clearCookies(server: ServerConfig) async {
        let hosts = Set(server.urls.compactMap { $0.host?.lowercased() })
        let store = WKWebsiteDataStore.default().httpCookieStore
        for c in await store.allCookies() {
            let d = c.domain.lowercased()
            let bare = d.hasPrefix(".") ? String(d.dropFirst()) : d
            if hosts.contains(bare) { await store.deleteCookie(c) }
        }
    }
}

/// Same certificate rules as the web view (pins, imported CA, client certificate). Untrusted
/// certificates are refused here: the trust prompt only ever comes from the web view.
private final class AuthSessionDelegate: NSObject, URLSessionTaskDelegate {
    let server: ServerConfig
    init(server: ServerConfig) { self.server = server }

    func urlSession(_ s: URLSession, task: URLSessionTask, didReceive ch: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch TrustStore.shared.outcome(for: ch, server: server) {
        case .useDefault: completionHandler(.performDefaultHandling, nil)
        case .use(let c): completionHandler(.useCredential, c)
        case .untrusted: completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)   // never follow redirects with tokens / cookies
    }
}

// MARK: - Pairing screen

/// Shows the code to approve on a signed-in computer (tap to copy), how long it is valid, a QR
/// code of the approval page with the code filled in, and polls until approved.
/// With `approve` (right after a sign-in link): the page approves the code itself and only
/// "Pairing…" then "Paired" shows; if the server refuses, the code screen shows as usual.
/// Cancel (or Try Again) stops polling and cancels the request on the server.
final class PairingViewController: UIViewController {
    /// Called ~1.5 s after "Paired". Default: close this screen.
    var onPaired: (() -> Void)?
    /// Approves the user code with the page's own sign-in (one-scan pairing). Answer: approved.
    var approve: ((String, @escaping (Bool) -> Void) -> Void)?
    /// The request waiting for approval (cancelled on the server when the user gives up).
    private var pending: (origin: URL, code: DeviceCode)?
    private var codeViews: [UIView] = []
    private let server: ServerConfig
    private let deviceName = DeviceAuth.clientName(UIDevice.current.name)
    private let openPage = UIButton(type: .system)
    private var verificationURL: URL?
    private var task: Task<Void, Never>?
    private var countdown: Timer?
    private var deadline: Date?
    private var userCode = ""
    private let codeButton = UIButton(type: .system)
    private let copiedLabel = UILabel()
    private let expiresLabel = UILabel()
    private let qrView = UIImageView()
    private let qrCaption = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retry = UIButton(type: .system)
    private let content = UIStackView()
    private let success = UIStackView()

    init(server: ServerConfig) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Pair This Phone"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(close))

        func label(_ text: String?, _ style: UIFont.TextStyle, color: UIColor = .label) -> UILabel {
            let l = UILabel()
            l.text = text; l.numberOfLines = 0; l.textAlignment = .center; l.textColor = color
            l.font = .preferredFont(forTextStyle: style); l.adjustsFontForContentSizeCategory = true
            return l
        }
        let intro = label("On a computer signed in to Kiro Crew, open Settings › Security › Devices and enter this code:", .body)

        var cfg = UIButton.Configuration.plain()
        cfg.attributedTitle = AttributedString("––––-––––", attributes: AttributeContainer([.font: UIFont.monospacedSystemFont(ofSize: 40, weight: .semibold)]))
        cfg.baseForegroundColor = .label
        codeButton.configuration = cfg
        codeButton.titleLabel?.adjustsFontSizeToFitWidth = true
        codeButton.accessibilityIdentifier = "pairing-code"
        codeButton.accessibilityHint = "Copies the code"
        codeButton.addAction(UIAction { [weak self] _ in self?.copyCode() }, for: .touchUpInside)
        copiedLabel.text = "Tap the code to copy it"
        copiedLabel.textAlignment = .center; copiedLabel.textColor = .secondaryLabel
        copiedLabel.font = .preferredFont(forTextStyle: .caption1); copiedLabel.adjustsFontForContentSizeCategory = true
        let name = label("Shows as “\(deviceName)”", .footnote, color: .secondaryLabel)
        expiresLabel.textAlignment = .center; expiresLabel.textColor = .secondaryLabel
        expiresLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .regular)
        expiresLabel.accessibilityIdentifier = "pairing-expires"

        qrView.contentMode = .scaleAspectFit
        qrView.layer.magnificationFilter = .nearest
        qrView.backgroundColor = .white
        qrView.layer.cornerRadius = 12
        qrView.clipsToBounds = true
        qrView.isHidden = true
        qrView.isAccessibilityElement = true
        qrView.accessibilityLabel = "QR code of the approval page"
        qrCaption.text = "Or scan this with a phone or computer that is signed in to Kiro Crew."
        qrCaption.numberOfLines = 0; qrCaption.textAlignment = .center; qrCaption.textColor = .secondaryLabel
        qrCaption.font = .preferredFont(forTextStyle: .footnote); qrCaption.adjustsFontForContentSizeCategory = true
        qrCaption.isHidden = true

        statusLabel.text = "Asking the server for a code…"
        statusLabel.numberOfLines = 0; statusLabel.textAlignment = .center; statusLabel.textColor = .secondaryLabel
        statusLabel.font = .preferredFont(forTextStyle: .subheadline); statusLabel.adjustsFontForContentSizeCategory = true
        spinner.startAnimating()
        retry.setTitle("Try Again", for: .normal)
        retry.isHidden = true
        retry.addAction(UIAction { [weak self] _ in self?.start() }, for: .touchUpInside)

        openPage.setTitle("Open the Devices page", for: .normal)
        openPage.isHidden = true
        openPage.addAction(UIAction { [weak self] _ in
            guard let self, let u = self.verificationURL else { return }
            let vc = SFSafariViewController(url: u)
            vc.dismissButtonStyle = .done
            self.present(vc, animated: true)
        }, for: .touchUpInside)

        let qrWrap = UIView()
        qrView.translatesAutoresizingMaskIntoConstraints = false
        qrWrap.addSubview(qrView)
        NSLayoutConstraint.activate([
            qrView.widthAnchor.constraint(equalToConstant: 168), qrView.heightAnchor.constraint(equalToConstant: 168),
            qrView.centerXAnchor.constraint(equalTo: qrWrap.centerXAnchor),
            qrView.topAnchor.constraint(equalTo: qrWrap.topAnchor), qrView.bottomAnchor.constraint(equalTo: qrWrap.bottomAnchor),
        ])
        qrWrap.isHidden = true

        for v in [intro, codeButton, copiedLabel, name, expiresLabel, qrWrap, qrCaption, openPage, spinner, statusLabel, retry] as [UIView] {
            content.addArrangedSubview(v)
        }
        codeViews = [intro, codeButton, copiedLabel, name, expiresLabel]
        if approve != nil { codeViews.forEach { $0.isHidden = true } }
        content.axis = .vertical; content.spacing = 12; content.alignment = .fill
        content.setCustomSpacing(2, after: codeButton)
        content.setCustomSpacing(18, after: copiedLabel)
        content.setCustomSpacing(20, after: expiresLabel)

        let check = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        check.tintColor = .systemGreen
        check.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 72, weight: .regular)
        check.contentMode = .center
        let done = label("Paired — you're signed in", .title2)
        done.accessibilityIdentifier = "pairing-success"
        success.addArrangedSubview(check); success.addArrangedSubview(done)
        success.axis = .vertical; success.spacing = 16; success.alignment = .center
        success.isHidden = true

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        success.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(content)
        view.addSubview(success)
        let g = scroll.contentLayoutGuide, f = scroll.frameLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: g.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -24),
            content.leadingAnchor.constraint(equalTo: f.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: f.trailingAnchor, constant: -28),
            success.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            success.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            success.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
        ])
        start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true { stop() }
    }

    private func stop() {
        task?.cancel(); task = nil; countdown?.invalidate(); countdown = nil
        if let p = pending {
            pending = nil
            let server = server
            Task { await DeviceAuth.shared.cancelPairing(server: server, origin: p.origin, code: p.code) }
        }
    }

    @objc private func close() { stop(); dismiss(animated: true) }

    private func copyCode() {
        guard !userCode.isEmpty else { return }
        UIPasteboard.general.string = userCode
        Haptics.play("success")
        copiedLabel.text = "Copied"
        copiedLabel.textColor = .systemGreen
        UIAccessibility.post(notification: .announcement, argument: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copiedLabel.text = "Tap the code to copy it"
            self?.copiedLabel.textColor = .secondaryLabel
        }
    }

    private func setCode(_ code: String) {
        userCode = code
        var cfg = codeButton.configuration ?? .plain()
        cfg.attributedTitle = AttributedString(code, attributes: AttributeContainer([.font: UIFont.monospacedSystemFont(ofSize: 40, weight: .semibold)]))
        codeButton.configuration = cfg
        codeButton.accessibilityLabel = "Pairing code"
        codeButton.accessibilityValue = code.map(String.init).joined(separator: " ")
    }

    private func setStatus(_ s: String, busy: Bool, canRetry: Bool = false) {
        statusLabel.text = s
        busy ? spinner.startAnimating() : spinner.stopAnimating()
        retry.isHidden = !canRetry
        if canRetry { countdown?.invalidate(); expiresLabel.text = nil }
    }

    private func tick() {
        guard let d = deadline else { expiresLabel.text = nil; return }
        let left = max(0, Int(d.timeIntervalSinceNow.rounded(.up)))
        expiresLabel.text = left > 0 ? String(format: "Code expires in %d:%02d", left / 60, left % 60) : "The code expired."
        if left == 0 { countdown?.invalidate() }
    }

    private func start() {
        stop()
        setStatus(approve != nil ? "Pairing this phone…" : "Asking the server for a code…", busy: true)
        setCode("––––-––––"); userCode = ""
        qrView.isHidden = true; qrView.superview?.isHidden = true; qrCaption.isHidden = true
        let server = server, name = deviceName
        ConnectionManager.shared.resolve(server) { [weak self] origin, _ in
            guard let self, let origin else { self?.setStatus("No server URL.", busy: false); return }
            self.task = Task { [weak self] in await self?.run(server: server, origin: origin, name: name) }
        }
    }

    /// Only links on this server's own addresses are shown (never a link the server could point anywhere).
    private func ownURL(_ s: String) -> URL? {
        guard let u = URL(string: s), isAllowedServer(u), server.urls.contains(where: { sameOrigin($0, u) }) else { return nil }
        return u
    }

    private func run(server: ServerConfig, origin: URL, name: String) async {
        let code: DeviceCode
        do { code = try await DeviceAuth.shared.startPairing(server: server, origin: origin, deviceName: name) } catch {
            setStatus(error.localizedDescription, busy: false, canRetry: true); return
        }
        setCode(code.userCode)
        pending = (origin, code)
        var interval = code.interval
        deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        if let approve {
            // One-scan pairing: the page approves its own phone's request. Refused (the link's
            // claim is spent, expired, from another address, ...): no retry, show the code.
            self.approve = nil
            let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in approve(code.userCode) { c.resume(returning: $0) } }
            if Task.isCancelled { return }
            if ok { interval = 1 } else { showCodeScreen(code) }
        } else {
            showCodeScreen(code)
        }
        while !Task.isCancelled, let d = deadline, Date() < d {
            try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            if Task.isCancelled { return }
            switch await DeviceAuth.shared.poll(server: server, origin: origin, code: code, deviceName: name) {
            case .pending: if interval < code.interval { interval += 1 }; continue
            case .slowDown: interval += 5
            case .success:
                pending = nil
                countdown?.invalidate()
                Haptics.play("success")
                content.isHidden = true
                success.isHidden = false
                navigationItem.leftBarButtonItem = nil
                UIAccessibility.post(notification: .screenChanged, argument: success)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if let onPaired { onPaired() } else { dismiss(animated: true) }
                return
            case .denied: pending = nil; showCodeScreen(code); setStatus("The request was denied.", busy: false, canRetry: true); return
            case .expired: pending = nil; setStatus("The code expired.", busy: false, canRetry: true); return
            case .failed(let msg): setStatus(msg, busy: false, canRetry: true); return
            }
        }
        if !Task.isCancelled { pending = nil; setStatus("The code expired.", busy: false, canRetry: true) }
    }

    /// The code, its countdown, the QR code and the link to the approval page.
    private func showCodeScreen(_ code: DeviceCode) {
        codeViews.forEach { $0.isHidden = false }
        // The Devices page opens in a Safari sheet, which is signed in only if Safari is.
        if let u = ownURL(code.verificationURI) {
            verificationURL = u
            openPage.isHidden = false
            openPage.setTitle("Open \(u.host.map { h in u.port.map { "\(h):\($0)" } ?? h } ?? "the Devices page")\(u.path)", for: .normal)
        }
        if let u = ownURL(code.verificationURIComplete) ?? ownURL(code.verificationURI), let img = Self.qr(u.absoluteString) {
            qrView.image = img
            qrView.isHidden = false; qrView.superview?.isHidden = false; qrCaption.isHidden = false
        }
        tick()
        countdown?.invalidate()
        countdown = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        setStatus("Waiting for approval…", busy: true)
    }

    /// QR code image (CoreImage), crisp at any size.
    static func qr(_ text: String) -> UIImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
