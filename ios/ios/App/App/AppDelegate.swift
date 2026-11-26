import UIKit
import Capacitor
import UserNotifications

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration",
                                          sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    // Local notifications from the web app (window.Notification polyfill): show them as banners
    // while the app is in the foreground too, and open their in-app path when tapped.
    // TODO(APNs): delivery while the app is closed needs Apple Push Notification service (paid
    // developer account + aps-environment entitlement) and the server sending pushes for this
    // device (a device-token registration endpoint). Not implemented; see README "Not included".
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let p = r.notification.request.content.userInfo["path"] as? String, isSafeAppPath(p) {
            DispatchQueue.main.async { LocalNotifications.onOpenPath?(p) }
        }
        done()
    }
}

// ---------------------------------------------------------------------------
// Kiro Crew web view: opens the active server (internal or external URL,
// switched on network changes), opens outside links in Safari, keeps sign-in
// redirects in the app, asks before trusting a server certificate iOS does not
// trust, answers client-certificate (mTLS) requests, hands downloads to the
// share sheet. It is shown inside NativeShellController (Sessions screen, web page).
// Settings: ServerStore.swift, TrustStore.swift, ConnectionManager.swift,
// SettingsViewController.swift. Bridge: WebBridge.swift. Device sign-in: DeviceAuth.swift.
// ---------------------------------------------------------------------------
import WebKit
import SafariServices

typealias ChallengeReply = (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

/// Sits in front of Capacitor's own navigation delegate and forwards everything else to it.
final class NavFilter: NSObject, WKNavigationDelegate {
    var inner: (NSObjectProtocol & WKNavigationDelegate)?
    var serverHosts: () -> [String]
    /// The active server's own sign-in (identity provider) hosts, from its settings.
    var signInHosts: () -> [String] = { [] }
    /// Opens a link that leaves the app (in-app Safari sheet for web links).
    var openExternal: (URL) -> Void = { UIApplication.shared.open($0) }
    var onFail: (Error) -> Void
    var onFinish: () -> Void = {}
    /// Returns true if it handled (or will handle) the challenge.
    var onChallenge: (URLAuthenticationChallenge, @escaping ChallengeReply) -> Bool
    let downloads = DownloadManager()

    init(inner: NSObjectProtocol & WKNavigationDelegate, serverHosts: @escaping () -> [String],
         onFail: @escaping (Error) -> Void, onChallenge: @escaping (URLAuthenticationChallenge, @escaping ChallengeReply) -> Bool) {
        self.inner = inner; self.serverHosts = serverHosts; self.onFail = onFail; self.onChallenge = onChallenge
    }
    override func responds(to s: Selector!) -> Bool { super.responds(to: s) || (inner?.responds(to: s) ?? false) }
    override func forwardingTarget(for s: Selector!) -> Any? { inner?.responds(to: s) == true ? inner : super.forwardingTarget(for: s) }

    private func isInApp(_ host: String) -> Bool {
        let h = host.lowercased()
        if serverHosts().contains(where: { let s = $0.lowercased(); return h == s || h.hasSuffix("." + s) }) { return true }
        return (commonSignInHosts + signInHosts()).contains { h == $0 || h.hasSuffix("." + $0) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        let local = ["about", "blob", "data", "capacitor"].contains(scheme)
        // <a download> and blob/data downloads from the page itself.
        if action.shouldPerformDownload, local || isAllowedServer(url) { decisionHandler(.download); return }
        if local { decisionHandler(.allow); return }
        if !isAllowedServer(url) {
            if action.navigationType == .linkActivated { openExternal(url) }
            decisionHandler(.cancel); return
        }
        // Redirects and form posts (sign-in) stay in the app. Tapped links to other sites open in a Safari sheet.
        if action.navigationType == .linkActivated, let h = url.host, !isInApp(h) {
            openExternal(url); decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ w: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if DownloadManager.shouldDownload(response) { decisionHandler(.download); return }
        if inner?.webView?(w, decidePolicyFor: response, decisionHandler: decisionHandler) == nil { decisionHandler(.allow) }
    }

    func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = downloads
    }
    func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = downloads
    }

    func webView(_ w: WKWebView, didReceive ch: URLAuthenticationChallenge, completionHandler: @escaping ChallengeReply) {
        if onChallenge(ch, completionHandler) { return }
        if inner?.webView?(w, didReceive: ch, completionHandler: completionHandler) == nil {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // Cancelled loads (a new load replaced the old one) and policy-cancelled loads (link sent to Safari,
    // response turned into a download) are not failures.
    private func isRealFailure(_ e: Error) -> Bool {
        let ns = e as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return false }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return false }
        return true
    }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { if isRealFailure(e) { onFail(e) } }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { if isRealFailure(e) { onFail(e) } }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        onFinish()
        inner?.webView?(w, didFinish: n)
    }
}

final class KiroCrewViewController: CAPBridgeViewController, UIGestureRecognizerDelegate, WebBridgeDelegate {
    private var filter: NavFilter?
    private var uiFilter: UIFilter?
    private(set) var bridgeJS: WebBridge?
    private let store = ServerStore.shared
    private let conn = ConnectionManager.shared
    private var started = false
    private var resolveGeneration = 0
    private var loadGeneration = 0
    private var loadedServer: ServerConfig?   // server config the web view was last pointed at
    private var route: Route?
    private(set) var target: URL?              // configured URL (internal or external) in use
    private var triedAlternate = false
    private var trustWaiters: [String: [(Bool) -> Void]] = [:]
    private var offsetObservation: NSKeyValueObservation?
    private var lastReauth: Date?

    // Hooks for NativeShellController.
    var onLoadStart: (_ cover: Bool) -> Void = { _ in }
    var onPainted: () -> Void = {}
    var onFinish: () -> Void = {}
    var onError: (_ message: String, _ detail: String) -> Void = { _, _ in }
    var onBadge: (Int) -> Void = { _ in }
    var onTheme: (UIColor) -> Void = { _ in }
    /// The web app signed out (bridge "logout").
    var onLogout: () -> Void = {}
    /// The web app's signed-out page asks for the app's sign-in (bridge "signin").
    var onSignInRequested: () -> Void = {}
    /// True while automatic device sign-in is held for this server id (the user kept the pairing
    /// but signed out on the page).
    var holdsAutoSignIn: (String) -> Bool = { _ in false }
    /// The web view now shows another server (or the active server's settings changed).
    var onServerChanged: () -> Void = {}
    /// In-app path for the first load (the last open session), instead of the server's start page.
    var startPath: String?

    override func capacitorDidLoad() {
        // Capacitor's bridge makes its own NotificationRouter the notification-center delegate (it
        // answers "present nothing" with no plugins). Take it back so web notifications show as
        // banners in the foreground and taps open their page.
        if let app = UIApplication.shared.delegate as? UNUserNotificationCenterDelegate {
            UNUserNotificationCenter.current().delegate = app
        }
        guard let web = webView else { return }
        // Page colour until the page reports its own (NativeShellController keeps these in sync).
        view.backgroundColor = Theme.defaultBackground
        web.isOpaque = false
        web.backgroundColor = Theme.defaultBackground
        web.scrollView.backgroundColor = Theme.defaultBackground
        web.underPageBackgroundColor = Theme.defaultBackground
        web.scrollView.contentInsetAdjustmentBehavior = .never
        // The web app's left-edge drawer owns that edge; Back is the native nav bar button.
        web.allowsBackForwardNavigationGestures = false
        web.allowsLinkPreview = false

        if let inner = web.navigationDelegate {
            let f = NavFilter(inner: inner,
                              serverHosts: { [weak self] in self?.store.active?.urls.compactMap { $0.host } ?? [] },
                              onFail: { [weak self] e in self?.loadFailed(e) },
                              onChallenge: { [weak self] ch, reply in self?.handleChallenge(ch, reply) ?? false })
            f.onFinish = { [weak self] in self?.onFinish() }
            f.signInHosts = { [weak self] in self?.store.active?.signInHosts ?? [] }
            f.openExternal = { [weak self] url in self?.openExternal(url) }
            f.downloads.presenter = { [weak self] in self?.topPresenter }
            f.downloads.server = { [weak self] in self?.store.active }
            filter = f
            web.navigationDelegate = f
        }
        let u = UIFilter(inner: web.uiDelegate,
                         serverURL: { [weak self] in self?.bridgeServerURL },
                         isServerURL: { [weak self] url in self?.isActiveServer(url) ?? false })
        u.openExternal = { [weak self] url in self?.openExternal(url) }
        uiFilter = u
        web.uiDelegate = u
        hideInputAccessoryBar(web)
        // The web app is a fixed-height layout with its own scrollers. When the document fits the
        // view, keep WebKit from scrolling the whole page (it pushes the header off screen on focus).
        offsetObservation = web.scrollView.observe(\.contentOffset, options: [.new]) { sv, _ in
            guard sv.contentSize.height <= sv.bounds.height + 1, sv.contentOffset.y != 0, !sv.isDragging else { return }
            DispatchQueue.main.async { sv.contentOffset = CGPoint(x: sv.contentOffset.x, y: 0) }
        }

        let b = WebBridge(webView: web)
        b.delegate = self
        bridgeJS = b

        // Two-finger long press (1 s) opens the server settings. Scoped so it never competes with
        // WebKit's own text-selection / focus gestures (see the delegate methods below).
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(openSettings))
        lp.numberOfTouchesRequired = 2
        lp.minimumPressDuration = 1
        lp.cancelsTouchesInView = false
        lp.delaysTouchesEnded = false
        lp.delegate = self
        web.addGestureRecognizer(lp)

        conn.onNetworkChange = { [weak self] in self?.connect() }
        conn.start()
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }   // load once; later appearances (after a modal) keep the page
        started = true
        if store.active != nil { connect(force: true) } else { askForURL(message: "Enter your Kiro Crew server URL.") }
    }

    @objc private func becameActive() { if started { connect() } }

    // MARK: WebBridgeDelegate

    var bridgeServerURL: URL? {
        guard let t = target, let s = store.active, loadedServer?.id == s.id else { return nil }
        return t
    }
    func bridgePainted() { onPainted() }
    func bridgeBadge(_ count: Int) { onBadge(count) }
    func bridgeTheme(_ color: UIColor) { onTheme(color) }
    func bridgeAuth(_ type: String) {
        guard let s = store.active, let origin = target else { return }
        if type == "signin" { onSignInRequested(); return }
        if type == "reauth" {
            // The web app asks once per page after its own silent refresh failed. At most one
            // refresh + reload per minute, so a server that keeps refusing cannot cause a loop.
            if let last = lastReauth, Date().timeIntervalSince(last) < 60 { return }
            lastReauth = Date()
        }
        guard type == "reauth" else { onLogout(); return }   // logout: the shell asks about the pairing
        guard !holdsAutoSignIn(s.id) else { return }
        Task { @MainActor [weak self] in
            // Paired: reload after the attempt whether it worked or not. The web app posts `reauth` once per
            // document and otherwise stays on a 403 with no sign-in banner (the 60 s limit above stops loops).
            let paired = DeviceAuth.isPaired(serverID: s.id)
            let ok = await DeviceAuth.shared.ensureSession(server: s, origin: origin, force: true)
            if ok || paired { self?.webView?.reload() }
        }
    }

    /// Web links that leave the app open in a Safari sheet (the user stays in the app), or in the
    /// user's default browser (Server Settings › Open Links In); other schemes (mailto:, tel:, ...)
    /// go to their app. Sign-in hosts never get here (NavFilter keeps them in the web view).
    func openExternal(_ url: URL) {
        let s = url.scheme?.lowercased()
        guard s == "https" || s == "http", !AppPrefs.linksInDefaultBrowser else { UIApplication.shared.open(url); return }
        let vc = SFSafariViewController(url: url)
        vc.dismissButtonStyle = .done
        topPresenter.present(vc, animated: true)
    }

    /// Removes WebKit's Prev / Next / Done bar above the keyboard (the web app has its own controls).
    /// Done by giving the web view's content view a subclass whose inputAccessoryView is nil.
    private func hideInputAccessoryBar(_ web: WKWebView) {
        guard let content = web.scrollView.subviews.first(where: { NSStringFromClass(type(of: $0)).hasPrefix("WKContent") }) else { return }
        let base: AnyClass = type(of: content)
        let baseName = NSStringFromClass(base)
        guard !baseName.hasSuffix("_KCNoAccessory") else { return }
        let name = baseName + "_KCNoAccessory"
        var cls: AnyClass? = NSClassFromString(name)
        if cls == nil, let c = objc_allocateClassPair(base, name, 0) {
            let sel = #selector(getter: UIResponder.inputAccessoryView)
            let block: @convention(block) (AnyObject) -> AnyObject? = { _ in nil }
            if let m = class_getInstanceMethod(UIView.self, sel) {
                class_addMethod(c, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m))
            }
            objc_registerClassPair(c)
            cls = c
        }
        if let cls { object_setClass(content, cls) }
    }

    func isActiveServer(_ u: URL) -> Bool { store.active?.urls.contains { sameOrigin($0, u) } ?? false }

    // MARK: Choosing and loading the URL

    /// Picks internal/external for the current network and loads it if it differs from what is shown.
    func connect(force: Bool = false) {
        guard let server = store.active else { return }
        resolveGeneration += 1
        let gen = resolveGeneration
        #if DEBUG
        // Simulator check of the error screen: launch with -kcDebugUnreachable.
        if ProcessInfo.processInfo.arguments.contains("-kcDebugUnreachable"), let u = URL(string: "http://192.0.2.1:5476/") {
            var s = server; s.internalURL = u; s.externalURL = nil
            apply(u, route: .internal, server: s, force: true); return
        }
        #endif
        conn.resolve(server) { [weak self] url, r in
            guard let self, gen == self.resolveGeneration, let url else { return }
            self.apply(url, route: r, server: server, force: force)
        }
    }

    private func apply(_ url: URL, route r: Route, server: ServerConfig, force: Bool) {
        let current = webView?.url
        let onOurPage = current.map { c in server.urls.contains { sameOrigin($0, c) } } ?? true
        if !force {
            // Don't interrupt a sign-in on another host, and don't reload when nothing changed.
            guard onOurPage, current.map({ !sameOrigin($0, url) }) ?? true else { return }
        }
        var dest = url
        if let p = startPath, isSafeAppPath(p), let u = URL(string: p, relativeTo: url)?.absoluteURL, sameOrigin(u, url) {
            dest = u   // launch: the last open session
        } else if let c = current, onOurPage, !sameOrigin(c, url), c.path.count > 1,
           var comp = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            // Switching internal <-> external: stay on the same page.
            comp.path = c.path; comp.percentEncodedQuery = c.query; comp.fragment = c.fragment
            dest = comp.url ?? url
        }
        startPath = nil
        let coverNeeded = force || loadedServer?.id != server.id
        let changed = loadedServer != server
        route = r; target = url; loadedServer = server; triedAlternate = false
        if changed { onServerChanged() }
        load(dest, server: server, cover: coverNeeded)
    }

    /// Every load of a server page goes through here: refresh the bridge script, restore the
    /// device session cookies if this phone is paired (DeviceAuth.swift), then load.
    private func load(_ dest: URL, server: ServerConfig, cover: Bool) {
        loadGeneration += 1
        let gen = loadGeneration
        bridgeJS?.installScripts(origins: server.urls.compactMap(originString))
        onLoadStart(cover)
        let go = { [weak self] in
            guard let self, gen == self.loadGeneration else { return }
            self.webView?.load(URLRequest(url: dest))
        }
        let paired = DeviceAuth.isPaired(serverID: server.id) && !holdsAutoSignIn(server.id)
        guard paired || SignInHooks.beforeLoad != nil else { go(); return }
        Task { @MainActor in
            if paired { _ = await DeviceAuth.shared.ensureSession(server: server, origin: dest, force: false) }
            await SignInHooks.beforeLoad?(server, dest)
            go()
        }
    }

    var statusText: String {
        guard let s = store.active else { return "No server." }
        guard let r = route, let t = target, loadedServer?.id == s.id else { return "\(s.displayName): not connected yet." }
        return "\(s.displayName): using the \(r.rawValue.lowercased()) URL \(t.absoluteString)"
    }

    /// Menu "Reload": the current page if it is the server's, else reconnect.
    func reloadPage() {
        if let u = webView?.url, isAllowedServer(u), isActiveServer(u) { webView?.reload() } else { connect(force: true) }
    }

    /// Opens an in-app path (Sessions screen, Apps menu, deep links, notifications).
    func open(path: String) {
        guard isSafeAppPath(path), let s = store.active else { return }
        if let u = webView?.url, isActiveServer(u), let b = bridgeJS {
            b.navigate(path) { [weak self] ok in if !ok { self?.loadPath(path, server: s) } }
        } else {
            loadPath(path, server: s)
        }
    }

    private func loadPath(_ path: String, server: ServerConfig) {
        guard let base = target ?? server.externalURL ?? server.internalURL,
              let u = URL(string: path, relativeTo: base)?.absoluteURL, sameOrigin(u, base) else { return }
        load(u, server: server, cover: false)
    }

    func goBack() { bridgeJS?.historyBack() }

    /// A sign-in link (scanned QR code / pasted) on one of this server's own URLs: load it in the
    /// web view on that URL (the server sets its session cookie and continues to the dashboard).
    func openSignInLink(_ link: URL, server: ServerConfig) {
        guard isAllowedServer(link), let base = server.urls.first(where: { sameOrigin($0, link) }) else { return }
        let r: Route = server.internalURL.map { sameOrigin($0, link) } == true ? .internal : .external
        let changed = loadedServer != server
        route = r; target = base; loadedServer = server; triedAlternate = true
        if changed { onServerChanged() }
        bridgeJS?.installScripts(origins: server.urls.compactMap(originString))
        onLoadStart(true)
        loadGeneration += 1
        webView?.load(URLRequest(url: link))
    }

    /// The current page on the server's external URL (for sharing / Handoff), else the page itself.
    var shareableURL: URL? {
        guard let u = webView?.url, isAllowedServer(u) else { return nil }
        guard let s = store.active, let ext = s.externalURL, isActiveServer(u), !sameOrigin(u, ext),
              var c = URLComponents(url: ext, resolvingAgainstBaseURL: false) else { return u }
        c.path = u.path; c.percentEncodedQuery = u.query; c.fragment = u.fragment
        return c.url ?? u
    }

    private func loadFailed(_ error: Error) {
        let ns = error as NSError
        let failing = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        // One automatic fallback to the server's other URL (e.g. internal not reachable after all),
        // only when the failed load was for that server (not a sign-in page).
        if !triedAlternate, let s = store.active, let t = target, let i = s.internalURL, let e = s.externalURL,
           failing.map({ f in s.urls.contains { sameOrigin($0, f) } }) ?? true {
            triedAlternate = true
            let useInternal = sameOrigin(t, e)
            route = useInternal ? .internal : .external
            target = useInternal ? i : e
            load(useInternal ? i : e, server: s, cover: false)
            return
        }
        var msg = "Check the network and the server URL."
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorClientCertificateRequired:
                msg = "The server asks for a client certificate. Import one (.p12) in the server settings."
            case NSURLErrorClientCertificateRejected:
                msg = "The server rejected the client certificate. Import a valid one in the server settings."
            case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid, NSURLErrorSecureConnectionFailed:
                msg = "The server's certificate is not trusted. Trust it when asked, or import its CA in the server settings."
            case NSURLErrorNotConnectedToInternet:
                msg = "You are offline. Check Wi-Fi or mobile data."
            case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                msg = "The server did not answer. Check that it is running and that the URL is right."
            default: break
            }
        }
        showFailure(msg)
    }

    private func showFailure(_ msg: String) {
        Haptics.play("error")
        onError(msg, statusText)
    }

    // MARK: Certificates

    private func handleChallenge(_ ch: URLAuthenticationChallenge, _ reply: @escaping ChallengeReply) -> Bool {
        let method = ch.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodServerTrust || method == NSURLAuthenticationMethodClientCertificate else { return false }
        switch TrustStore.shared.outcome(for: ch, server: store.active) {
        case .useDefault: reply(.performDefaultHandling, nil)
        case .use(let cred): reply(.useCredential, cred)
        case let .untrusted(leaf, endpoint, explanation, reason):
            guard let trust = ch.protectionSpace.serverTrust, let server = store.active else { reply(.cancelAuthenticationChallenge, nil); return true }
            askToTrust(leaf: leaf, endpoint: endpoint, explanation: explanation, reason: reason, server: server) { ok in
                ok ? reply(.useCredential, URLCredential(trust: trust)) : reply(.cancelAuthenticationChallenge, nil)
            }
        }
        return true
    }

    /// Shows the certificate and asks. Only an explicit "Trust" pins this exact certificate for this host:port.
    private func askToTrust(leaf: SecCertificate, endpoint: String, explanation: String, reason: String, server: ServerConfig,
                            done: @escaping (Bool) -> Void) {
        let fp = TrustStore.sha256(leaf)
        let key = "\(server.id)|\(endpoint)|\(fp)"
        if trustWaiters[key] != nil { trustWaiters[key]?.append(done); return }   // same prompt already showing
        trustWaiters[key] = [done]
        let changed = TrustStore.shared.hasDifferentPin(than: leaf, serverID: server.id, endpoint: endpoint)
        let finish: (Bool) -> Void = { [weak self] ok in
            if ok { TrustStore.shared.pin(leaf, serverID: server.id, endpoint: endpoint) }
            let waiters = self?.trustWaiters.removeValue(forKey: key) ?? []
            waiters.forEach { $0(ok) }
            if !ok { self?.showFailure("You did not trust the server's certificate.") }
        }
        let warning = changed ? "WARNING: this is NOT the certificate you trusted before for this address. "
            + "Only continue if you replaced the server's certificate yourself.\n\n" : ""
        let a = UIAlertController(
            title: changed ? "Server certificate changed" : "Untrusted server certificate",
            message: warning + "\(endpoint)\n\n\(explanation)\n\nCertificate: \(TrustStore.summary(leaf))\nSHA-256:\n\(fp)\n\n"
                + "Trust only if this fingerprint matches your server. The app will then accept exactly this certificate, "
                + "for this address only.\n\nDetails: \(reason)",
            preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Trust This Certificate", style: .destructive) { _ in finish(true) })
        let no = UIAlertAction(title: "Don't Trust", style: .cancel) { _ in finish(false) }
        a.addAction(no)
        a.preferredAction = no
        topPresenter.present(a, animated: true)
    }

    /// Top-most view controller of the window (this controller is a child of NativeShellController).
    var topPresenter: UIViewController {
        var v: UIViewController = view.window?.rootViewController ?? self
        while let p = v.presentedViewController, !p.isBeingDismissed { v = p }
        return v
    }
    private var isPresentingSomething: Bool { (view.window?.rootViewController ?? self).presentedViewController != nil }

    // MARK: Settings

    @objc private func openSettings(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { presentSettings() }
    }

    func presentSettings(editActive: Bool = false) {
        guard !isPresentingSomething else { return }
        let list = ServerListViewController()
        list.status = { [weak self] in self?.statusText ?? "" }
        list.onChange = { [weak self] in self?.activeServerMaybeChanged() }
        list.onReconnect = { [weak self] in self?.connect(force: true) }
        let nav = UINavigationController(rootViewController: list)
        if editActive, let s = store.active { list.loadViewIfNeeded(); list.edit(s, isNew: false, animated: false) }
        topPresenter.present(nav, animated: true)
    }

    /// Reload only if the active server, or its settings, differ from what the web view shows.
    func activeServerMaybeChanged() {
        if let s = store.active, s != loadedServer { connect(force: true) }
    }

    private func askForURL(message: String) {
        guard !isPresentingSomething else { return }
        let a = UIAlertController(title: "Server URL", message: message + " It must start with https:// (http:// only for a home-network address)."
                                  + " Add an internal (home) URL and more servers later in Server Settings (··· menu).", preferredStyle: .alert)
        a.addTextField { tf in
            tf.placeholder = "\(serverURLPlaceholder) or \(lanURLPlaceholder)"
            tf.keyboardType = .URL; tf.autocapitalizationType = .none; tf.autocorrectionType = .no
            tf.clearButtonMode = .whileEditing
        }
        a.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak a] _ in
            let raw = (a?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self else { return }
            if let u = URL(string: raw), isAllowedServer(u) {
                var s = ServerConfig(name: "Kiro Crew")
                if isLocalHost(u.host) { s.internalURL = u } else { s.externalURL = u }
                self.store.upsert(s); self.store.setActive(id: s.id)
                self.connect(force: true)
            } else {
                self.askForURL(message: "That is not a valid URL.")
            }
        })
        topPresenter.present(a, animated: true)
    }

    // The two-finger hold must not interfere with WebKit's tap / focus / selection gestures:
    // it only begins with exactly two touches, and only runs alongside scrolling and zooming.
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { g.numberOfTouches == 2 }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool {
        guard let sv = webView?.scrollView else { return false }
        return o === sv.panGestureRecognizer || o === sv.pinchGestureRecognizer
    }
}
