import Foundation
import Network
import NetworkExtension
import CoreLocation

// ---------------------------------------------------------------------------
// Picks the internal or external URL of a server for the current network,
// and reports network changes so the web view can switch.
//
// Rules (first match wins):
//  1. Only one URL configured -> that URL.
//  2. Not on Wi-Fi or Ethernet (cellular only) -> external.
//  3. Home Wi-Fi names configured and the current Wi-Fi name can be read -> internal if it matches, else external.
//  4. Home Wi-Fi names configured but the name can't be read: https internal URL -> probe (TLS proves
//     who answers); http internal URL -> external (can't tell a look-alike address on another network).
//  5. No Wi-Fi names -> internal if it answers within 2.5 s, else external.
// Reading the Wi-Fi name needs location permission AND the "Access Wi-Fi Information"
// entitlement (paid Apple Developer account). Without them rules 4/5 apply.
// ---------------------------------------------------------------------------

enum Route: String { case `internal` = "Internal", external = "External" }

final class ConnectionManager: NSObject, CLLocationManagerDelegate {
    static let shared = ConnectionManager()

    /// Called on the main queue when the network changed (debounced).
    var onNetworkChange: (() -> Void)?

    private let monitor = NWPathMonitor()
    private var path: Network.NWPath?
    private var lastSignature: String?
    private var debounce: DispatchWorkItem?
    private let location = CLLocationManager()
    private var afterAuthorization: [() -> Void] = []

    func start() {
        location.delegate = self
        monitor.pathUpdateHandler = { [weak self] p in
            DispatchQueue.main.async { self?.pathChanged(p) }
        }
        monitor.start(queue: DispatchQueue(label: "kirocrew.path"))
    }

    private func pathChanged(_ p: Network.NWPath) {
        let first = path == nil
        path = p
        let sig = "\(p.status)|" + p.availableInterfaces.map { "\($0.type)-\($0.name)" }.joined(separator: ",")
        guard sig != lastSignature else { return }
        lastSignature = sig
        guard !first else { return }   // the first update is the starting state, not a change
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.onNetworkChange?() }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    private var onLocalInterface: Bool {
        guard let p = path else { return true }   // unknown yet: let the probe decide
        return p.usesInterfaceType(.wifi) || p.usesInterfaceType(.wiredEthernet)
    }

    // MARK: Wi-Fi name

    var locationStatusText: String {
        switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return "Location allowed"
        case .denied, .restricted: return "Location denied (Settings > Kiro Crew > Location)"
        default: return "Location not asked yet"
        }
    }

    /// Asks for "While Using" location once (needed by iOS to read the Wi-Fi name), then calls back.
    func requestLocationIfNeeded(_ done: @escaping () -> Void) {
        if location.authorizationStatus == .notDetermined {
            afterAuthorization.append(done)
            location.requestWhenInUseAuthorization()
        } else { done() }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard m.authorizationStatus != .notDetermined else { return }
        let pending = afterAuthorization; afterAuthorization = []
        pending.forEach { $0() }
    }

    /// Current Wi-Fi name, or nil (not on Wi-Fi, no permission, no entitlement, simulator).
    func currentSSID(_ done: @escaping (String?) -> Void) {
        NEHotspotNetwork.fetchCurrent { n in DispatchQueue.main.async { done(n?.ssid) } }
    }

    // MARK: Choosing the URL

    func resolve(_ s: ServerConfig, done: @escaping (URL?, Route) -> Void) {
        guard let inside = s.internalURL else { done(s.externalURL, .external); return }
        guard let outside = s.externalURL else { done(inside, .internal); return }
        guard onLocalInterface else { done(outside, .external); return }
        let probeThenPick = { [weak self] in
            self?.probe(inside, server: s) { ok in done(ok ? inside : outside, ok ? .internal : .external) }
        }
        if s.homeSSIDs.isEmpty { probeThenPick(); return }
        currentSSID { ssid in
            if let ssid { s.homeSSIDs.contains(ssid) ? done(inside, .internal) : done(outside, .external) }
            else if inside.scheme?.lowercased() == "https" { probeThenPick() }
            else { done(outside, .external) }
        }
    }

    /// Does the internal URL answer? A certificate the user has not trusted yet still counts as
    /// "answers", so the web view can show the trust prompt.
    private func probe(_ url: URL, server: ServerConfig, done: @escaping (Bool) -> Void) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2.5
        cfg.waitsForConnectivity = false
        let delegate = ProbeDelegate(server: server)
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2.5)
        req.httpMethod = "HEAD"
        session.dataTask(with: req) { _, resp, _ in
            let ok = resp != nil || delegate.sawUntrustedCert
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async { done(ok) }
        }.resume()
    }
}

/// Applies the same trust rules as the web view to the reachability probe.
private final class ProbeDelegate: NSObject, URLSessionDelegate {
    let server: ServerConfig
    private(set) var sawUntrustedCert = false
    init(server: ServerConfig) { self.server = server }

    func urlSession(_ s: URLSession, didReceive ch: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch TrustStore.shared.outcome(for: ch, server: server) {
        case .useDefault: completionHandler(.performDefaultHandling, nil)
        case .use(let cred): completionHandler(.useCredential, cred)
        case .untrusted: sawUntrustedCert = true; completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
