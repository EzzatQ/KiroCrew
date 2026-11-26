import Foundation
import Security
import CryptoKit

// ---------------------------------------------------------------------------
// Certificates, all in the Keychain (this device only, never synced):
//  - Pinned server certificates: one exact leaf certificate per (server, host:port),
//    saved only after the user taps "Trust" on the prompt.
//  - One CA certificate per server, imported by the user (e.g. Cloudflare Origin CA).
//    Used as the only anchor for that server's own hosts, with the normal hostname check.
//  - One client identity (certificate + private key from a .p12) per server, for mTLS.
// Nothing here applies to hosts that are not one of the server's configured URLs.
// ---------------------------------------------------------------------------

enum Keychain {
    private static func base(_ service: String, _ account: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }
    @discardableResult
    static func set(_ data: Data, service: String, account: String) -> Bool {
        SecItemDelete(base(service, account) as CFDictionary)
        var q = base(service, account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
    static func get(service: String, account: String) -> Data? {
        var q = base(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    static func delete(service: String, account: String) { SecItemDelete(base(service, account) as CFDictionary) }
    static func accounts(service: String) -> [String] {
        var q = base(service, nil)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

enum TrustError: LocalizedError {
    case badFile, wrongPassword, noIdentity, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .badFile: return "The file is not a certificate this app can read (use .cer/.crt/.der/.pem, or .p12/.pfx for a client certificate)."
        case .wrongPassword: return "The password is wrong."
        case .noIdentity: return "The .p12 file has no certificate with a private key."
        case .keychain(let s): return "Keychain error \(s)."
        }
    }
}

/// What to do with an authentication challenge.
enum ChallengeOutcome {
    case useDefault                                   // not ours / system-trusted: normal iOS handling
    case use(URLCredential)                           // pinned cert, imported CA, or client identity
    /// Ask the user. `explanation` is plain language; `reason` is iOS's own technical text.
    case untrusted(leaf: SecCertificate, endpoint: String, explanation: String, reason: String)
}

final class TrustStore {
    static let shared = TrustStore()
    private let pinService = appIdentifier + ".pinned-cert"   // account "<serverID>|<host:port>"
    private let caService = appIdentifier + ".ca-cert"        // account "<serverID>"
    private func identityLabel(_ serverID: String) -> String { "\(appIdentifier).mtls.\(serverID)" }

    // MARK: Evaluation

    func outcome(for ch: URLAuthenticationChallenge, server: ServerConfig?) -> ChallengeOutcome {
        let space = ch.protectionSpace
        guard let server, server.owns(space) else { return .useDefault }
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            guard let id = identity(serverID: server.id) else { return .useDefault }
            return .use(URLCredential(identity: id, certificates: nil, persistence: .forSession))
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = space.serverTrust else { return .useDefault }
            var err: CFError?
            if SecTrustEvaluateWithError(trust, &err) { return .useDefault }   // publicly trusted: nothing to do
            let reason = (err as Error?)?.localizedDescription ?? "The certificate is not trusted."
            let endpoint = endpointKey(host: space.host, port: space.port)
            guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return .useDefault }
            // 1. Exact certificate the user trusted for this host:port.
            if let pinned = Keychain.get(service: pinService, account: "\(server.id)|\(endpoint)"),
               pinned == SecCertificateCopyData(leaf) as Data {
                return .use(URLCredential(trust: trust))
            }
            // 2. CA the user imported for this server: only anchor, hostname still checked.
            if let ca = caCertificate(serverID: server.id) {
                SecTrustSetAnchorCertificates(trust, [ca] as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
                if SecTrustEvaluateWithError(trust, nil) { return .use(URLCredential(trust: trust)) }
            }
            return .untrusted(leaf: leaf, endpoint: endpoint,
                              explanation: Self.explain(trust: trust, leaf: leaf, host: space.host), reason: reason)
        default:
            return .useDefault
        }
    }

    // MARK: Pinned server certificates

    func pin(_ leaf: SecCertificate, serverID: String, endpoint: String) {
        Keychain.set(SecCertificateCopyData(leaf) as Data, service: pinService, account: "\(serverID)|\(endpoint)")
    }
    func hasDifferentPin(than leaf: SecCertificate, serverID: String, endpoint: String) -> Bool {
        guard let d = Keychain.get(service: pinService, account: "\(serverID)|\(endpoint)") else { return false }
        return d != SecCertificateCopyData(leaf) as Data
    }
    func pinnedEndpoints(serverID: String) -> [String] {
        Keychain.accounts(service: pinService).filter { $0.hasPrefix(serverID + "|") }.map { String($0.dropFirst(serverID.count + 1)) }
    }
    func removePins(serverID: String) {
        for e in pinnedEndpoints(serverID: serverID) { Keychain.delete(service: pinService, account: "\(serverID)|\(e)") }
    }

    // MARK: Imported CA

    /// Accepts DER (.cer/.der/.crt) or PEM. Returns the certificate summary.
    func importCA(_ data: Data, serverID: String) throws -> String {
        guard let cert = Self.certificate(from: data) else { throw TrustError.badFile }
        guard Keychain.set(SecCertificateCopyData(cert) as Data, service: caService, account: serverID) else { throw TrustError.keychain(errSecIO) }
        return Self.summary(cert)
    }
    func caCertificate(serverID: String) -> SecCertificate? {
        Keychain.get(service: caService, account: serverID).flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    }
    func removeCA(serverID: String) { Keychain.delete(service: caService, account: serverID) }

    // MARK: Client identity (mTLS)

    /// Imports a .p12/.pfx into the Keychain. The file data is not kept anywhere else.
    func importClientP12(_ data: Data, password: String, serverID: String) throws -> String {
        var items: CFArray?
        let opts = [kSecImportExportPassphrase as String: password] as CFDictionary
        let st = SecPKCS12Import(data as CFData, opts, &items)
        if st == errSecAuthFailed { throw TrustError.wrongPassword }
        guard st == errSecSuccess else { throw st == errSecDecode ? TrustError.badFile : TrustError.keychain(st) }
        guard let first = (items as? [[String: Any]])?.first, let any = first[kSecImportItemIdentity as String] else { throw TrustError.noIdentity }
        let identity = any as! SecIdentity  // CF type: the cast always succeeds when the key is present
        removeIdentity(serverID: serverID)
        let add: [String: Any] = [kSecValueRef as String: identity,
                                  kSecAttrLabel as String: identityLabel(serverID),
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {   // same identity already stored (e.g. for another server): move it here
            SecItemDelete([kSecClass as String: kSecClassIdentity, kSecValueRef as String: identity] as CFDictionary)
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw TrustError.keychain(status) }
        var cert: SecCertificate?
        SecIdentityCopyCertificate(identity, &cert)
        return cert.map(Self.summary) ?? "Client certificate"
    }
    func identity(serverID: String) -> SecIdentity? {
        let q: [String: Any] = [kSecClass as String: kSecClassIdentity,
                                kSecAttrLabel as String: identityLabel(serverID),
                                kSecReturnRef as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let out else { return nil }
        return (out as! SecIdentity)
    }
    func removeIdentity(serverID: String) {
        SecItemDelete([kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: identityLabel(serverID)] as CFDictionary)
    }

    func removeAll(serverID: String) {
        removePins(serverID: serverID); removeCA(serverID: serverID); removeIdentity(serverID: serverID)
    }

    // MARK: Helpers

    /// A short, plain-language explanation of why iOS does not trust the certificate (from the
    /// per-check results of the evaluation), plus a hint for Cloudflare Origin certificates.
    static func explain(trust: SecTrust, leaf: SecCertificate, host: String) -> String {
        var failed = Set<String>()
        if let r = SecTrustCopyResult(trust) as? [String: Any], let details = r["TrustResultDetails"] as? [[String: Any]] {
            for d in details { for (k, v) in d where (v as? Bool) == false { failed.insert(k) } }
        }
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        let selfSigned = chain.count == 1 && isSelfIssued(leaf)
        var lines: [String] = []
        if isCloudflareOrigin(chain.isEmpty ? [leaf] : chain) {
            lines.append("This is a Cloudflare Origin certificate. Only Cloudflare's proxy trusts it. Turn on Cloudflare's proxy "
                + "for this hostname (SSL mode Full (strict)) and the app, and any browser, will connect without this prompt.")
        }
        if failed.contains("SSLHostname") {
            lines.append("The certificate is for a different address, not \(host).")
        }
        if failed.contains("TemporalValidity") {
            lines.append("The certificate has expired, or is not valid yet. Check the date on the server and on this phone.")
        }
        if selfSigned {
            lines.append("The certificate is self-signed: no certificate authority vouches for it.")
        } else if !failed.isDisjoint(with: ["AnchorTrusted", "MissingIntermediate", "NonEmptySubject", "BasicConstraints"]) {
            lines.append("It was issued by a certificate authority this iPhone does not know (for example your own CA).")
        }
        if !failed.isDisjoint(with: ["ValidityPeriodMaximums", "SystemTrustValidityPeriod", "CTRequired", "WeakKeySize",
                                     "WeakSignature", "ExtendedKeyUsage", "KeyUsage"]) {
            lines.append("It does not meet Apple's rules for website certificates (for example it is valid for too long).")
        }
        if lines.isEmpty { lines.append("iOS does not trust this certificate.") }
        return lines.joined(separator: "\n\n")
    }

    /// Subject and issuer are the same name (normalized DER).
    private static func isSelfIssued(_ c: SecCertificate) -> Bool {
        guard let s = SecCertificateCopyNormalizedSubjectSequence(c), let i = SecCertificateCopyNormalizedIssuerSequence(c) else { return false }
        return (s as Data) == (i as Data)
    }

    /// Leaf or issuer names Cloudflare's Origin CA ("CloudFlare Origin SSL Certificate Authority",
    /// leaf CN "CloudFlare Origin Certificate"). Names only: this changes the wording, never the decision.
    static func isCloudflareOrigin(_ chain: [SecCertificate]) -> Bool {
        func text(_ d: CFData?) -> String {
            guard let d else { return "" }
            return String(decoding: (d as Data).map { (0x20...0x7E).contains($0) ? $0 : 0x20 }, as: UTF8.self).lowercased()
        }
        for c in chain.prefix(2) {
            let names = [text(SecCertificateCopyNormalizedIssuerSequence(c)), text(SecCertificateCopyNormalizedSubjectSequence(c)),
                         summary(c).lowercased()].joined(separator: " ")
            if names.contains("cloudflare origin ssl certificate authority") || names.contains("cloudflare origin certificate") { return true }
        }
        return false
    }

    static func summary(_ c: SecCertificate) -> String { (SecCertificateCopySubjectSummary(c) as String?) ?? "Certificate" }

    static func sha256(_ c: SecCertificate) -> String {
        SHA256.hash(data: SecCertificateCopyData(c) as Data).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func certificate(from data: Data) -> SecCertificate? {
        if let c = SecCertificateCreateWithData(nil, data as CFData) { return c }
        guard let text = String(data: data, encoding: .utf8),
              let start = text.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = text.range(of: "-----END CERTIFICATE-----", range: start.upperBound..<text.endIndex) else { return nil }
        let b64 = text[start.upperBound..<end.lowerBound].components(separatedBy: .whitespacesAndNewlines).joined()
        return Data(base64Encoded: b64).flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    }
}
