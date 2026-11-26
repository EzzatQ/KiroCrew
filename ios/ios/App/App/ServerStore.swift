import Foundation

// ---------------------------------------------------------------------------
// Server settings: one or more Kiro Crew servers, each with an optional
// internal (home network) URL and external (anywhere) URL, and optional extra
// sign-in hosts (an identity provider the server redirects to).
// Only non-secret settings live here (UserDefaults). Certificates, keys and
// device sign-in tokens live in the Keychain (TrustStore.swift, DeviceAuth.swift).
// ---------------------------------------------------------------------------

/// The app's bundle identifier; Keychain service names and quick-action types derive from it,
/// so changing the bundle id in Xcode is the only change needed for your own build.
let appIdentifier = Bundle.main.bundleIdentifier ?? "kirocrew"

let urlKey = "kirocrew.serverURL"          // legacy single-URL key, kept in sync with the active server
let serverURLPlaceholder = "https://kirocrew.example.com"
let lanURLPlaceholder = "http://192.168.1.10:5476"

/// Sign-in (identity provider) hosts that may stay inside the app for every server, when a
/// tapped link goes there. Redirects and form posts stay in the app anyway; add your own
/// provider per server in Server Settings > Sign-in hosts.
let commonSignInHosts = ["okta.com", "oktapreview.com", "microsoftonline.com", "login.live.com", "auth0.com",
                         "accounts.google.com", "onelogin.com", "duosecurity.com", "jumpcloud.com"]

/// Plain http is allowed only for private-network hosts (home LAN server). Everything else must be https.
func isLocalHost(_ host: String?) -> Bool {
    guard let h = host?.lowercased() else { return false }
    // Loopback by name: a Kiro Crew server reached on 127.0.0.1 redirects pages to its canonical "localhost".
    if h == "localhost" || h.hasSuffix(".local") { return true }
    let p = h.split(separator: ".").compactMap { Int($0) }
    guard p.count == 4, h.split(separator: ".").count == 4 else { return false }
    return p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1]))
}

func isAllowedServer(_ u: URL) -> Bool {
    let s = u.scheme?.lowercased()
    return u.host?.isEmpty == false && (s == "https" || (s == "http" && isLocalHost(u.host)))
}

/// "host:port" (default port filled in). Trust decisions are scoped to these exact endpoints.
func endpointKey(host: String, port: Int) -> String { "\(host.lowercased()):\(port)" }
func endpointKey(_ url: URL) -> String? {
    guard let h = url.host, !h.isEmpty else { return nil }
    return endpointKey(host: h, port: url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443))
}

/// Same scheme, host and port.
func sameOrigin(_ a: URL, _ b: URL) -> Bool {
    a.scheme?.lowercased() == b.scheme?.lowercased() && endpointKey(a) != nil && endpointKey(a) == endpointKey(b)
}

/// A host name the user typed for "sign-in hosts": lower case, no scheme/path, at least one dot.
func normalizedHost(_ raw: String) -> String? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
    s = String(s.prefix { $0 != "/" && $0 != ":" && $0 != "?" && $0 != "#" })
    while s.hasPrefix(".") || s.hasPrefix("*") { s.removeFirst() }
    let ok = s.contains(".") && s.count <= 253 && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
    return ok ? s : nil
}

struct ServerConfig: Codable, Equatable {
    var id = UUID().uuidString
    var name = ""
    var externalURL: URL?
    var internalURL: URL?
    /// Wi-Fi names (SSIDs) of the home network. Empty = decide by "does the internal URL answer?".
    var homeSSIDs: [String] = []
    /// Display name of the imported client certificate. The identity itself is in the Keychain.
    var clientCertName: String?
    /// Extra hosts (and their subdomains) whose tapped links stay in the app: the server's sign-in provider.
    var signInHosts: [String] = []

    var displayName: String { name.isEmpty ? ((externalURL ?? internalURL)?.host ?? "Server") : name }
    var urls: [URL] { [internalURL, externalURL].compactMap { $0 } }
    var endpoints: Set<String> { Set(urls.compactMap(endpointKey)) }
    func owns(_ space: URLProtectionSpace) -> Bool { endpoints.contains(endpointKey(host: space.host, port: space.port)) }

    init(name: String = "") { self.name = name }

    private enum CodingKeys: String, CodingKey {
        case id, name, externalURL, internalURL, homeSSIDs, clientCertName, signInHosts
    }

    /// Tolerates settings saved by earlier versions (missing keys get defaults).
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        externalURL = try c.decodeIfPresent(URL.self, forKey: .externalURL)
        internalURL = try c.decodeIfPresent(URL.self, forKey: .internalURL)
        homeSSIDs = try c.decodeIfPresent([String].self, forKey: .homeSSIDs) ?? []
        clientCertName = try c.decodeIfPresent(String.self, forKey: .clientCertName)
        if let hosts = try c.decodeIfPresent([String].self, forKey: .signInHosts) {
            signInHosts = hosts
        } else {
            // Settings saved before per-server sign-in hosts existed: none extra (add them in Server Settings).
            signInHosts = []
        }
    }
}

final class ServerStore {
    static let shared = ServerStore()
    private let serversKey = "kirocrew.servers"
    private let activeKey = "kirocrew.activeServer"
    private let defaults = UserDefaults.standard

    private(set) var servers: [ServerConfig] = []
    private(set) var activeID: String?

    private init() {
        if let data = defaults.data(forKey: serversKey),
           let list = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            servers = list
            activeID = defaults.string(forKey: activeKey)
            save()   // writes migrated fields (signInHosts)
        } else if let raw = defaults.string(forKey: urlKey), let u = URL(string: raw), isAllowedServer(u) {
            // Migrate the single saved URL from earlier versions.
            var s = ServerConfig(name: "Kiro Crew")
            if isLocalHost(u.host) { s.internalURL = u } else { s.externalURL = u }
            servers = [s]
            activeID = s.id
            save()
        }
        if active == nil { activeID = servers.first?.id }
    }

    var active: ServerConfig? { servers.first { $0.id == activeID } ?? servers.first }

    func server(id: String) -> ServerConfig? { servers.first { $0.id == id } }

    func upsert(_ s: ServerConfig) {
        if let i = servers.firstIndex(where: { $0.id == s.id }) { servers[i] = s } else { servers.append(s) }
        if activeID == nil { activeID = s.id }
        save()
    }

    func remove(id: String) {
        if let s = server(id: id) {
            // Revoke this phone's device sign-in on the server (best effort; uses the server's certificate
            // settings), then wipe its Keychain items and cookies.
            Task {
                await DeviceAuth.shared.unpair(server: s, origin: nil)
                TrustStore.shared.removeAll(serverID: id)
            }
        } else {
            TrustStore.shared.removeAll(serverID: id)
        }
        servers.removeAll { $0.id == id }
        if activeID == id { activeID = servers.first?.id }
        save()
    }

    func setActive(id: String) { activeID = id; save() }

    private func save() {
        defaults.set(try? JSONEncoder().encode(servers), forKey: serversKey)
        defaults.set(activeID, forKey: activeKey)
        defaults.set((active?.externalURL ?? active?.internalURL)?.absoluteString, forKey: urlKey)
    }
}
