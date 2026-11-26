import UIKit
import WebKit
import LocalAuthentication
import AppIntents

// ---------------------------------------------------------------------------
// The app's root screen, Messages-style:
//
//   UINavigationController
//     SessionsWebController    the web app's own sessions list (/embed/sessions, second web view;
//                              Settings / Inbox / New session in the bar, Bots / Apps below)
//     └ WebPageController      ONE shared WKWebView, pushed for a chat (/chat?sid=...),
//                              Inbox, Bots, Settings, apps and any web page; slim bar: ‹ · title · ···
//
// The main web view (KiroCrewViewController, a CAPBridgeViewController) is created once. While
// no WebPageController is on screen it is parked behind the navigation controller (still in the
// window, so the page keeps running: badge, notifications, drafts).
//
// Also here: launch cover until first paint, full-screen error view, native sign-in card
// (signed out), "Signed out — Pair again" banner, privacy blur / optional Face ID lock,
// deep links, quick actions, Handoff, the last open session on launch.
// ---------------------------------------------------------------------------

final class NativeShellController: UIViewController, UINavigationControllerDelegate {
    static weak var current: NativeShellController?

    let web = KiroCrewViewController()
    private(set) var nav: UINavigationController!
    private let sessions = SessionsWebController()
    private(set) lazy var webPage = WebPageController(shell: self)
    private let parking = UIView()
    private let cover = CoverView()
    private let errorView = ErrorView()
    private let signIn = SignInCardView()
    private let banner = SignedOutBanner()
    private var shield: PrivacyShield?
    private(set) var background = Theme.lastBackground
    private var bridgeColorKnown = false
    private var bridgeBadgeKnown = false
    private var observations: [NSKeyValueObservation] = []
    private var pendingPath: String?
    private var firstLoadDone = false
    private var coverTimer: Timer?
    private var lockNeeded = AppPrefs.appLock
    private var lastBadge = 0
    private var authenticating = false
    private var bannerServerID: String?
    /// Server ids whose device sign-in the user kept after signing out on the page: no automatic
    /// sign-in until they ask for it (sign-in card), for this launch.
    private(set) var holdAutoSignIn: Set<String> = []
    /// Server ids where the user just signed in with a QR code or link (pair right away).
    private var linkSignIns: Set<String> = []
    /// The docked terminal was opened from Apps: close it again when going back to Sessions.
    private var terminalFromApps = false
    /// Whether the active server offers device pairing (nil = not checked yet).
    private(set) var pairingSupported: Bool?

    /// Sections of the web app, for titles and the web page's Back.
    enum Section { case sessions, bots, inbox, apps, settings }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        Self.current = self
        view.backgroundColor = background

        // The parked web view: full size, behind the navigation controller.
        parking.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(parking)
        pin(parking, to: view)
        park()

        sessions.shell = self
        nav = UINavigationController(rootViewController: sessions)
        nav.delegate = self
        nav.navigationBar.prefersLargeTitles = true
        addChild(nav)
        nav.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nav.view)
        pin(nav.view, to: view)
        nav.didMove(toParent: self)

        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = true
        banner.onTap = { [weak self] in self?.bannerTapped() }
        view.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        for v in [signIn, cover, errorView] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
            pin(v, to: view)
        }
        errorView.isHidden = true
        errorView.onRetry = { [weak self] in self?.retry() }
        errorView.onSettings = { [weak self] in self?.web.presentSettings(editActive: true) }
        signIn.isHidden = true
        signIn.onScan = { [weak self] in self?.scanSignInQR() }
        signIn.onPair = { [weak self] in self?.startPairing() }
        signIn.onPaste = { [weak self] in self?.pasteSignInLink() }
        signIn.onSignInAgain = { [weak self] in self?.signInAgainWithPairing() }
        signIn.onShowPage = { [weak self] in self?.hideSignIn(); self?.showWeb(path: nil) }
        signIn.onSettings = { [weak self] in self?.web.presentSettings(editActive: true) }

        wireWeb()
        applyTheme(background)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        nc.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(needsPairing(_:)), name: .deviceAuthNeedsPairing, object: nil)
        LocalNotifications.onOpenPath = { [weak self] p in self?.open(path: p, fromOutside: true) }

        if lockNeeded { showShield(locked: true) }
        if let p = DeepLink.takePending() { pendingPath = p }

        // Launch: the last open session, with the Sessions list behind it.
        if pendingPath == nil, let s = ServerStore.shared.active, let last = LastPage.get(serverID: s.id) {
            web.startPath = last
            webPage.prepare(title: LastPage.title(serverID: s.id))
            nav.setViewControllers([sessions, webPage], animated: false)
            sessions.loadViewIfNeeded()
            sessions.park(in: parking)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if lockNeeded && !authenticating { authenticate() }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { Theme.isDark(background) ? .lightContent : .darkContent }
    override var childForStatusBarStyle: UIViewController? { nil }
    override var childForStatusBarHidden: UIViewController? { nil }

    private func pin(_ v: UIView, to p: UIView) {
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: p.topAnchor), v.bottomAnchor.constraint(equalTo: p.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: p.leadingAnchor), v.trailingAnchor.constraint(equalTo: p.trailingAnchor),
        ])
    }

    // MARK: The shared web view: parked here, or shown in the WebPageController

    /// Moves the web view behind the navigation controller (still in the window).
    func park() {
        guard web.parent !== self else { return }
        if web.parent != nil { web.willMove(toParent: nil); web.view.removeFromSuperview(); web.removeFromParent() }
        addChild(web)
        web.view.translatesAutoresizingMaskIntoConstraints = false
        parking.addSubview(web.view)
        NSLayoutConstraint.activate([
            web.view.topAnchor.constraint(equalTo: parking.safeAreaLayoutGuide.topAnchor),
            web.view.bottomAnchor.constraint(equalTo: parking.safeAreaLayoutGuide.bottomAnchor),
            web.view.leadingAnchor.constraint(equalTo: parking.leadingAnchor),
            web.view.trailingAnchor.constraint(equalTo: parking.trailingAnchor),
        ])
        web.didMove(toParent: self)
        resignParkedFocus()
    }

    /// A parked page must not hold the keyboard (the chat's composer keeps focus otherwise).
    private func resignParkedFocus() {
        web.webView?.callAsyncJavaScript("const a = document.activeElement; if (a && a !== document.body && a.blur) a.blur(); return true;",
                                         arguments: [:], in: nil, in: .page, completionHandler: nil)
        web.view.endEditing(true)
    }

    @objc private func keyboardWillShow(_ n: Notification) {
        guard web.parent === self else { return }
        resignParkedFocus()
    }

    var webPageOnTop: Bool { nav?.topViewController === webPage }

    func navigationController(_ n: UINavigationController, willShow vc: UIViewController, animated: Bool) {
        n.setToolbarHidden(vc !== sessions, animated: animated)
        if vc === sessions, terminalFromApps { terminalFromApps = false; web.bridgeJS?.closeTerminal() }
        if !(vc is WebPageController) { web.view.endEditing(true) }
        setNeedsStatusBarAppearanceUpdate()
    }

    func navigationController(_ n: UINavigationController, didShow vc: UIViewController, animated: Bool) {
        if !n.viewControllers.contains(webPage) { park() }
        if vc !== sessions { sessions.park(in: parking) }
        updateHandoff()
    }

    /// Shows the web page (pushing it if needed) and opens `path` in it (nil: keep the page).
    /// `over`: the native screen to push it from (Apps); default keeps the stack, else Sessions.
    func showWeb(path: String?, title: String? = nil, animated: Bool = true) {
        if let path, !isSafeAppPath(path) { return }
        if let path { webPage.prepare(title: title ?? Self.routeTitle(path: path, query: nil)); webPage.willOpen(path) }
        let stack = nav.viewControllers
        if !stack.contains(webPage) {
            nav.setViewControllers([sessions, webPage], animated: animated && stack.count == 1)
        } else if stack.last !== webPage {
            nav.popToViewController(webPage, animated: animated)
        }
        if let path { open(path: path) }
    }

    func showSessionsList(animated: Bool = true) {
        if nav.presentedViewController != nil { nav.dismiss(animated: animated) }
        nav.popToRootViewController(animated: animated)
    }

    /// "New session": the web app's own route for it.
    func newSession() { showWeb(path: "/chat?new=1", title: "New Session") }

    // MARK: Web hooks

    private func wireWeb() {
        web.onLoadStart = { [weak self] cover in
            guard let self else { return }
            self.errorView.isHidden = true
            if cover { self.showCover() }
        }
        web.onPainted = { [weak self] in self?.pageReady(delay: 0) }
        web.onFinish = { [weak self] in self?.pageReady(delay: 0.3); self?.checkAuth(); self?.sessions.load() }
        web.onError = { [weak self] msg, detail in
            guard let self else { return }
            self.hideCover()
            self.errorView.show(message: msg, detail: detail)
            self.errorView.isHidden = false
        }
        web.onBadge = { [weak self] n in self?.bridgeBadgeKnown = true; self?.setBadge(n) }
        web.onTheme = { [weak self] c in self?.bridgeColorKnown = true; Theme.lastBackground = c; self?.applyTheme(c) }
        web.onLogout = { [weak self] in self?.webLoggedOut() }
        web.onSignInRequested = { [weak self] in self?.showSignIn() }
        web.holdsAutoSignIn = { [weak self] id in self?.holdAutoSignIn.contains(id) ?? false }
        web.onServerChanged = { [weak self] in self?.serverChanged() }
        web.loadViewIfNeeded()
        guard let wv = web.webView else { return }
        observations = [
            wv.observe(\.url, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async { self?.urlChanged() } },
            wv.observe(\.title, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async { self?.webPage.titleChanged() } },
            wv.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async { self?.webPage.updateBack() } },
            wv.observe(\.themeColor, options: [.new]) { [weak self] w, _ in
                DispatchQueue.main.async {
                    guard let self, !self.bridgeColorKnown, let c = w.themeColor else { return }
                    self.applyTheme(c)
                }
            },
        ]
    }

    private var firstAuthChecked = false

    private func pageReady(delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // First launch: keep the cover until we know whether the user is signed in (max 3 s),
            // so a signed-out server shows the sign-in card instead of flashing its error page.
            if !self.firstAuthChecked {
                self.checkAuth()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.hideCover() }
            } else {
                self.hideCover()
            }
            if !self.firstLoadDone {
                self.firstLoadDone = true
                if let p = self.pendingPath { self.pendingPath = nil; self.open(path: p, fromOutside: true) }
                self.sessions.load()
                self.checkPairingSupport()
                #if DEBUG
                self.debugLaunchActions()
                #endif
            }
        }
    }

    private func showCover() {
        cover.apply(background: background)
        cover.alpha = 1
        cover.isHidden = false
        coverTimer?.invalidate()
        coverTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in self?.hideCover() }
    }

    private func hideCover() {
        coverTimer?.invalidate()
        guard !cover.isHidden else { return }
        UIView.animate(withDuration: 0.2, animations: { self.cover.alpha = 0 }) { _ in self.cover.isHidden = true }
    }

    private func retry() {
        errorView.isHidden = true
        showCover()
        web.connect(force: true)
    }

    /// Another server became active (or its settings changed): forget per-server state.
    private func serverChanged() {
        pairingSupported = nil
        sessions.serverChanged()
        hideSignIn()
        updateBanner()
        firstAuthChecked = false
        checkPairingSupport()
    }

    // MARK: Route, title, badge

    var currentURL: URL? {
        guard let u = web.webView?.url, web.isActiveServer(u) else { return nil }
        return u
    }
    var currentPath: String? { currentURL.map { $0.path.isEmpty ? "/" : $0.path } }

    static func section(for path: String) -> Section {
        func under(_ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        if path == "/" || under("/chat") || under("/embed/chat") || under("/embed/sessions") { return .sessions }
        if under("/members") { return .bots }
        if under("/notifications") { return .inbox }
        if under("/settings") || under("/embed/settings") { return .settings }
        return .apps
    }

    /// The session key of the chat in the web view (?sid=), if it shows one.
    var currentSessionKey: String? {
        guard let u = currentURL, Self.isChat(u.path),
              let sid = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "sid" })?.value,
              !sid.isEmpty else { return nil }
        return sid
    }

    static func isChat(_ path: String?) -> Bool { path.map { $0 == "/chat" || $0.hasPrefix("/chat/") } ?? false }

    private var popCheck: DispatchWorkItem?

    private func urlChanged() {
        if currentURL == nil { bridgeColorKnown = false }
        webPage.routeChanged()
        updateHandoff()
        rememberPage()
        // A chat page with no session (the session was closed / deleted here): back to the list.
        popCheck?.cancel()
        if webPageOnTop, let u = currentURL, u.path == "/chat", (u.query ?? "").isEmpty {
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.webPageOnTop, let u = self.currentURL, u.path == "/chat", (u.query ?? "").isEmpty else { return }
                self.showSessionsList()
            }
            popCheck = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
        }
    }

    /// The session (or page) on screen, for the next launch. Paths only, no page content.
    private func rememberPage() {
        guard webPageOnTop, let s = ServerStore.shared.active, let u = currentURL else { return }
        var p = u.path.isEmpty ? "/" : u.path
        if let q = u.query, !q.isEmpty { p += "?" + q }
        guard currentSessionKey != nil, isSafeAppPath(p) else { return }
        LastPage.set(serverID: s.id, path: p, title: webPage.pageTitle)
    }

    /// Native titles for pages whose document title is only the product name.
    static func routeTitle(path: String, query: String?) -> String? {
        func under(_ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        let bare = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        if let known = SessionsWebController.appPages.first(where: { $0.path == bare }) { return known.title }
        if bare.hasPrefix("/apps/"), let name = bare.split(separator: "/").last, bare.split(separator: "/").count == 2 {
            // An installed app's page (its document title is the product name): "file-explorer" -> "File Explorer".
            return name.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        if under("/notifications") { return "Inbox" }
        if under("/members") { return "Bots" }
        if under("/settings") { return "Settings" }
        if bare == "/" || under("/chat") { return "Chat" }
        return nil
    }

    private func setBadge(_ n: Int) {
        lastBadge = n
        sessions.setInboxBadge(n)
        LocalNotifications.setBadge(n)
    }

    /// Re-applies the badge after the user allowed notifications in Settings.
    func notificationPermissionChanged(_ p: String) {
        web.bridgeJS?.notificationPermissionChanged(p)
        if p == "granted" { LocalNotifications.setBadge(lastBadge) }
    }

    /// Handoff: the current page, only on the server's external (reachable anywhere) URL.
    func updateHandoff() {
        guard webPageOnTop, let s = ServerStore.shared.active, let ext = s.externalURL, let u = web.shareableURL, sameOrigin(u, ext),
              u.scheme?.lowercased() == "https" else {
            userActivity?.invalidate(); userActivity = nil; return
        }
        let a = userActivity ?? NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        a.webpageURL = u
        a.title = webPage.pageTitle
        userActivity = a
        a.becomeCurrent()
    }

    #if DEBUG
    /// Simulator checks without taps: `simctl launch <udid> <bundle id> -kcDebugApps` etc.
    private func debugLaunchActions() {
        let args = ProcessInfo.processInfo.arguments
        let probe = "[typeof window.Capacitor, typeof window.electronAPI, typeof window.kcNative, typeof window.Notification, "
            + "document.documentElement.className].join('|')"
        web.webView?.evaluateJavaScript(probe) { r, _ in NSLog("KCDBG probe %@", String(describing: r ?? "nil")) }
        func later(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        if args.contains("-kcDebugBlur") {
            later(1) { [weak self] in
                self?.web.webView?.evaluateJavaScript("document.activeElement && document.activeElement.blur()")
                self?.view.endEditing(true)
            }
        }
        if let i = args.firstIndex(of: "-kcDebugOpen"), i + 1 < args.count {
            let p = args[i + 1]
            later(1.5) { [weak self] in self?.open(path: p, fromOutside: true) }
        }
        if args.contains("-kcDebugList") { later(1) { [weak self] in self?.showSessionsList(animated: false) } }
        if args.contains("-kcDebugSettings") { later(2) { [weak self] in self?.web.presentSettings(editActive: true) } }
        if args.contains("-kcDebugSignIn") { later(2) { [weak self] in self?.showSignIn() } }
        if args.contains("-kcDebugPairing") { later(2) { [weak self] in self?.startPairing() } }
        if args.contains("-kcDebugBanner") {
            later(2) { [weak self] in self?.bannerServerID = ServerStore.shared.active?.id; self?.updateBanner() }
        }
        if args.contains("-kcDebugEval") { startDebugEval() }
        if args.contains("-kcDebugSignOut"), let s = ServerStore.shared.active {
            // Signed-out checks: drop this server's cookies (as signing out on the page does).
            Task { @MainActor [weak self] in await DeviceAuth.clearCookies(server: s); self?.web.reloadPage() }
        }
    }

    /// DEBUG builds only, opt-in with -kcDebugEval: runs <Documents>/kcdebug-in.js in the page
    /// (as an async function body) and writes the JSON result to <Documents>/kcdebug-out.txt.
    /// For checking the deployed web app's DOM from the simulator.
    private func startDebugEval() {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let input = docs.appendingPathComponent("kcdebug-in.js"), output = docs.appendingPathComponent("kcdebug-out.txt")
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let js = try? String(contentsOf: input, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(at: input)
            self?.web.webView?.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { r in
                let text: String
                switch r {
                case .success(let v):
                    if JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted]) {
                        text = String(data: d, encoding: .utf8) ?? ""
                    } else { text = String(describing: v) }
                case .failure(let e): text = "ERROR: \(e)"
                }
                try? text.write(to: output, atomically: true, encoding: .utf8)
            }
        }
    }
    #endif

    // MARK: Navigation entry points

    /// In-app path. `fromOutside`: a deep link, quick action or notification (resets the stack to
    /// Sessions › page). Otherwise the web page on screen navigates (no reload).
    func open(path: String, fromOutside: Bool = false) {
        guard isSafeAppPath(path) else { return }
        guard firstLoadDone else { pendingPath = path; return }
        if fromOutside {
            if presentedViewController != nil || nav.presentedViewController != nil { dismiss(animated: false) }
            if path == "/chat" || path == "/" { showSessionsList(); return }
            if !webPageOnTop || nav.viewControllers.count > 2 {
                webPage.prepare(title: Self.routeTitle(path: path, query: nil))
                nav.setViewControllers([sessions, webPage], animated: true)
            }
        }
        webPage.willOpen(path)
        if path == "/terminal", web.webView?.url.map(web.isActiveServer) == true, let b = web.bridgeJS {
            // The docked terminal is a panel over the page on screen, not a page of its own.
            terminalFromApps = true
            webPage.pinTitle("Terminal")
            b.openTerminal { [weak self] ok in if !ok { self?.web.open(path: path) } }
            return
        }
        web.open(path: path)
    }

    // MARK: Theme

    private func applyTheme(_ c: UIColor) {
        background = c
        let style: UIUserInterfaceStyle = Theme.isDark(c) ? .dark : .light
        view.backgroundColor = c
        parking.backgroundColor = c
        web.view.backgroundColor = c
        if let w = web.webView {
            w.backgroundColor = c; w.scrollView.backgroundColor = c; w.underPageBackgroundColor = c
        }
        // Native screens follow the page's light/dark (the web view keeps the phone's own setting
        // so a web theme of "system" is not pushed around by this).
        nav?.overrideUserInterfaceStyle = style
        banner.overrideUserInterfaceStyle = style
        signIn.overrideUserInterfaceStyle = style
        errorView.overrideUserInterfaceStyle = style
        cover.apply(background: c)
        webPage.applyTheme(c)
        sessions.applyTheme(c)
        setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: Privacy blur / app lock

    @objc private func willResignActive() { if !authenticating { showShield(locked: false) } }
    @objc private func didEnterBackground() { if AppPrefs.appLock { lockNeeded = true; showShield(locked: true) } }
    @objc private func didBecomeActive() {
        if !authenticating { if lockNeeded { authenticate() } else { removeShield() } }
        if firstLoadDone { checkAuth() }
    }

    private func showShield(locked: Bool) {
        let s = shield ?? PrivacyShield(frame: view.bounds)
        s.frame = view.bounds
        s.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        s.onUnlock = { [weak self] in self?.authenticate() }
        s.setLocked(locked)
        if s.superview == nil { view.addSubview(s) }
        view.bringSubviewToFront(s)
        shield = s
    }

    private func removeShield() {
        guard let s = shield else { return }
        shield = nil
        UIView.animate(withDuration: 0.15, animations: { s.alpha = 0 }) { _ in s.removeFromSuperview() }
    }

    private func authenticate() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            lockNeeded = false; removeShield(); return   // no passcode set: nothing to check against
        }
        authenticating = true
        showShield(locked: true)
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Kiro Crew") { ok, _ in
            DispatchQueue.main.async {
                self.authenticating = false
                if ok { self.lockNeeded = false; self.removeShield() } else { self.shield?.setLocked(true) }
            }
        }
    }

    // MARK: Signed in? (GET /api/auth/me inside the page, with its own cookies)

    private var authChecking = false
    private var wasSignedOut = false

    func checkAuth() {
        guard !authChecking, ServerStore.shared.active != nil else { return }
        authChecking = true
        web.authState { [weak self] state in
            guard let self else { return }
            self.authChecking = false
            switch state {
            case .signedOut:
                self.firstAuthChecked = true
                self.wasSignedOut = true
                self.hideCover()
                self.showSignIn()
            case .signedIn:
                self.firstAuthChecked = true
                self.hideCover()
                let wasShowing = !self.signIn.isHidden
                self.hideSignIn()
                if let id = ServerStore.shared.active?.id, self.bannerServerID == id { self.bannerServerID = nil; self.updateBanner() }
                if wasShowing || self.wasSignedOut { self.sessions.load(force: true) }
                self.wasSignedOut = false
                self.pairAfterLinkSignIn()
            case .unknown:
                break   // another host (sign-in provider), offline, ...: leave things as they are
            }
        }
    }

    /// Also asked for by the web app's own signed-out page (bridge "signin").
    private func showSignIn() {
        guard let s = ServerStore.shared.active else { return }
        let paired = DeviceAuth.isPaired(serverID: s.id)
        signIn.configure(host: web.target?.host ?? (s.externalURL ?? s.internalURL)?.host ?? s.displayName,
                         canPair: pairingSupported == true && !paired, paired: paired)
        if signIn.isHidden {
            signIn.alpha = 0
            signIn.isHidden = false
            UIView.animate(withDuration: 0.2) { self.signIn.alpha = 1 }
            UIAccessibility.post(notification: .screenChanged, argument: signIn)
        }
        if pairingSupported == nil { checkPairingSupport() }
    }

    private func hideSignIn() {
        guard !signIn.isHidden else { return }
        UIView.animate(withDuration: 0.2, animations: { self.signIn.alpha = 0 }) { _ in self.signIn.isHidden = true; self.signIn.alpha = 1 }
    }

    private func checkPairingSupport(then done: (() -> Void)? = nil) {
        guard let s = ServerStore.shared.active else { return }
        ConnectionManager.shared.resolve(s) { [weak self] origin, _ in
            guard let origin else { return }
            Task { @MainActor [weak self] in
                let m = await DeviceAuth.shared.metadata(origin: origin, server: s)
                guard let self, ServerStore.shared.active?.id == s.id else { return }
                self.pairingSupported = m != nil
                self.webPage.updateMenu()
                if !self.signIn.isHidden { self.showSignIn() }
                done?()
            }
        }
    }

    // MARK: Sign-in card actions

    private func scanSignInQR() {
        guard let s = ServerStore.shared.active else { return }
        let scanner = QRScannerViewController()
        scanner.onCode = { [weak self, weak scanner] text in
            scanner?.dismiss(animated: true) { self?.handleSignInLink(text, server: s) }
        }
        scanner.onPaste = { [weak self, weak scanner] in
            scanner?.dismiss(animated: true) { self?.pasteSignInLink() }
        }
        let n = UINavigationController(rootViewController: scanner)
        n.modalPresentationStyle = .fullScreen
        web.topPresenter.present(n, animated: true)
    }

    private func pasteSignInLink() {
        guard let s = ServerStore.shared.active else { return }
        let a = UIAlertController(title: "Paste Sign-in Link",
                                  message: "Paste the one-time sign-in link from Kiro Crew on your computer "
                                      + "(Settings › Connect your phone › Create sign-in link).",
                                  preferredStyle: .alert)
        a.addTextField { tf in
            tf.placeholder = "https://…"
            tf.keyboardType = .URL; tf.autocapitalizationType = .none; tf.autocorrectionType = .no
            tf.clearButtonMode = .whileEditing
            tf.textContentType = .URL
        }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if UIPasteboard.general.hasURLs || UIPasteboard.general.hasStrings {
            a.addAction(UIAlertAction(title: "Paste from Clipboard", style: .default) { [weak self] _ in
                let text = UIPasteboard.general.url?.absoluteString ?? UIPasteboard.general.string ?? ""
                self?.handleSignInLink(text, server: s)
            })
        }
        a.addAction(UIAlertAction(title: "Sign In", style: .default) { [weak self, weak a] _ in
            self?.handleSignInLink(a?.textFields?.first?.text ?? "", server: s)
        })
        web.topPresenter.present(a, animated: true)
    }

    /// QR code or pasted text: only a link on one of this server's own URLs is loaded. A link on
    /// another address is offered to be added to the server first (after the user confirms).
    /// The link is a credential: it is never logged or stored.
    private func handleSignInLink(_ raw: String, server s: ServerConfig) {
        switch SignInLink.check(raw, server: s) {
        case .invalid:
            alert("Not a sign-in link", "This is not a Kiro Crew link. Create a sign-in link on your computer: "
                  + "Kiro Crew › Settings › Connect your phone.")
        case .ours(let u):
            loadSignInLink(u, server: s)
        case .otherOrigin(let u, let origin):
            let host = originString(origin) ?? (origin.host ?? "?")
            let local = isLocalHost(origin.host)
            let a = UIAlertController(title: "Different address",
                                      message: "This link is for \(host), which is not one of \(s.displayName)'s addresses. "
                                          + "Only continue if \(host) is your own Kiro Crew server.\n\n"
                                          + "Add it to \(s.displayName) as its \(local ? "internal (home network)" : "external") URL and sign in?",
                                      preferredStyle: .alert)
            a.addAction(UIAlertAction(title: local ? "Add as Internal URL" : "Add as External URL", style: .default) { [weak self] _ in
                guard var cur = ServerStore.shared.server(id: s.id) else { return }
                if local { cur.internalURL = origin } else { cur.externalURL = origin }
                ServerStore.shared.upsert(cur)
                self?.loadSignInLink(u, server: cur)
            })
            let cancel = UIAlertAction(title: "Cancel", style: .cancel)
            a.addAction(cancel)
            a.preferredAction = cancel
            web.topPresenter.present(a, animated: true)
        }
    }

    private func loadSignInLink(_ u: URL, server: ServerConfig) {
        linkSignIns.insert(server.id)
        holdAutoSignIn.remove(server.id)
        hideSignIn()
        web.openSignInLink(u, server: server)
    }

    private func signInAgainWithPairing() {
        guard let s = ServerStore.shared.active else { return }
        holdAutoSignIn.remove(s.id)
        hideSignIn()
        showCover()
        web.connect(force: true)
    }

    /// After a QR / link sign-in: pair this phone right away so it stays signed in (one scan).
    /// The fresh sign-in may approve exactly one pairing request made soon after it, from this
    /// phone; the pairing screen asks the page to approve it and falls back to the code if not.
    private func pairAfterLinkSignIn() {
        guard let s = ServerStore.shared.active, linkSignIns.contains(s.id) else { return }
        linkSignIns.remove(s.id)
        guard !DeviceAuth.isPaired(serverID: s.id) else { return }
        let go = { [weak self] in
            guard let self, self.pairingSupported == true, ServerStore.shared.active?.id == s.id else { return }
            self.startPairing(server: s, approveInPage: true)
        }
        if pairingSupported == nil { checkPairingSupport(then: go) } else { go() }
    }

    private func alert(_ title: String, _ message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        web.topPresenter.present(a, animated: true)
    }

    // MARK: Device pairing

    /// Opens the pairing screen for the active server (from the sign-in card, the ··· menu,
    /// the "Signed out" alert or banner).
    func startPairing(server: ServerConfig? = nil, approveInPage: Bool = false) {
        guard let s = server ?? ServerStore.shared.active else { return }
        let p = PairingViewController(server: s)
        if approveInPage { p.approve = { [weak self] code, done in self?.web.approveDevice(userCode: code, done) ?? done(false) } }
        p.onPaired = { [weak self] in self?.paired(serverID: s.id) }   // closes every sheet
        web.topPresenter.present(UINavigationController(rootViewController: p), animated: true)
    }

    /// Pairing finished: close every sheet and show the page signed in (dashboard / last session).
    func paired(serverID: String) {
        holdAutoSignIn.remove(serverID)
        if bannerServerID == serverID { bannerServerID = nil; updateBanner() }
        hideSignIn()
        let finish = { [weak self] in
            guard let self else { return }
            self.web.activeServerMaybeChanged()
            self.web.reloadPage()
            self.sessions.load(force: true)
        }
        if presentedViewController != nil { dismiss(animated: true, completion: finish) } else { finish() }
    }

    @objc private func needsPairing(_ n: Notification) {
        guard let id = n.userInfo?["serverID"] as? String, let s = ServerStore.shared.server(id: id) else { return }
        let a = UIAlertController(title: "Signed out",
                                  message: "This phone was signed out of Kiro Crew. It was removed or its sign-in expired.",
                                  preferredStyle: .alert)
        let again = UIAlertAction(title: "Pair Again", style: .default) { [weak self] _ in self?.startPairing(server: s) }
        a.addAction(again)
        a.addAction(UIAlertAction(title: "Not Now", style: .cancel) { [weak self] _ in
            self?.bannerServerID = id
            self?.updateBanner()
        })
        a.preferredAction = again
        web.topPresenter.present(a, animated: true)
    }

    private func updateBanner() {
        let show = bannerServerID != nil && bannerServerID == ServerStore.shared.active?.id
        guard show == banner.isHidden else { return }
        banner.isHidden = !show
        view.layoutIfNeeded()
        nav.additionalSafeAreaInsets.top = show ? banner.bounds.height : 0
    }

    private func bannerTapped() {
        guard let id = bannerServerID, let s = ServerStore.shared.server(id: id) else { return }
        startPairing(server: s)
    }

    // MARK: Signing out on the page

    /// The web app posted "logout". A paired phone asks whether to unpair too (default: keep the
    /// pairing, sign out here only). Either way the sign-in card follows.
    private func webLoggedOut() {
        guard let s = ServerStore.shared.active else { return }
        let origin = web.target
        guard DeviceAuth.isPaired(serverID: s.id) else {
            Task { @MainActor [weak self] in
                await DeviceAuth.clearCookies(server: s)
                self?.checkAuth()
            }
            return
        }
        holdAutoSignIn.insert(s.id)
        let a = UIAlertController(title: "Also unpair this phone?",
                                  message: "You signed out of Kiro Crew. Unpair to remove this phone from the server too; "
                                      + "Keep Paired lets you sign in again with one tap.",
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Unpair", style: .destructive) { [weak self] _ in
            Task { @MainActor [weak self] in
                await DeviceAuth.shared.unpair(server: s, origin: origin)
                self?.holdAutoSignIn.remove(s.id)
                self?.checkAuth()
                self?.webPage.updateMenu()
            }
        })
        let keep = UIAlertAction(title: "Keep Paired", style: .cancel) { [weak self] _ in
            Task { @MainActor [weak self] in
                await DeviceAuth.clearCookies(server: s)
                self?.checkAuth()
            }
        }
        a.addAction(keep)
        a.preferredAction = keep
        web.topPresenter.present(a, animated: true)
    }
}

// MARK: - Questions asked inside the page (its own cookies; nothing leaves the web view)

extension KiroCrewViewController {
    enum AuthState { case signedIn, signedOut, unknown }

    /// GET /api/auth/me inside the page: 200 signed in, 401/403 signed out, else unknown.
    func authState(_ done: @escaping (AuthState) -> Void) {
        guard let w = webView, let u = w.url, isActiveServer(u) else { done(.unknown); return }
        let js = "const r = await fetch('/api/auth/me', {credentials: 'include', headers: {Accept: 'application/json'}}); return r.status;"
        w.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            guard case .success(let v) = result, let status = (v as? NSNumber)?.intValue else { done(.unknown); return }
            if (200..<300).contains(status) { done(.signedIn) } else if status == 401 || status == 403 { done(.signedOut) } else { done(.unknown) }
        }
    }

    /// One-scan pairing: approves this phone's own pairing request with the page's fresh sign-in
    /// (POST /v1/crew/owner/device-approvals from inside the page, so its cookie and Origin are
    /// the page's). True only for a 2xx; any refusal (pair_claim_*, owner_only, ...) is final.
    func approveDevice(userCode: String, _ done: @escaping (Bool) -> Void) {
        guard let w = webView, let u = w.url, isActiveServer(u), !userCode.isEmpty, userCode.count <= 32 else { done(false); return }
        let js = """
        const r = await fetch('/v1/crew/owner/device-approvals', {method: 'POST', credentials: 'include',
          headers: {'Content-Type': 'application/json', Accept: 'application/json'},
          body: JSON.stringify({user_code: code, approve: true})});
        return r.status;
        """
        w.callAsyncJavaScript(js, arguments: ["code": userCode], in: nil, in: .page) { r in
            guard case .success(let v) = r, let status = (v as? NSNumber)?.intValue else { done(false); return }
            done((200..<300).contains(status))
        }
    }
}

// MARK: - Last open page (per server; path only)

enum LastPage {
    private static func key(_ id: String) -> String { "kirocrew.lastPage.\(id)" }
    static func get(serverID: String) -> String? {
        guard let p = UserDefaults.standard.string(forKey: key(serverID)), isSafeAppPath(p) else { return nil }
        return p
    }
    static func title(serverID: String) -> String? { UserDefaults.standard.string(forKey: key(serverID) + ".title") }
    static func set(serverID: String, path: String, title: String?) {
        UserDefaults.standard.set(path, forKey: key(serverID))
        UserDefaults.standard.set(title.map { String($0.prefix(120)) }, forKey: key(serverID) + ".title")
    }
    static func clear(serverID: String) {
        UserDefaults.standard.removeObject(forKey: key(serverID))
        UserDefaults.standard.removeObject(forKey: key(serverID) + ".title")
    }
}

// MARK: - Deep links, Home Screen quick actions, App Shortcuts

enum DeepLink {
    private static var pending: String?
    static func takePending() -> String? { defer { pending = nil }; return pending }

    static func open(_ path: String) {
        guard isSafeAppPath(path) else { return }
        if let s = NativeShellController.current { s.open(path: path, fromOutside: true) } else { pending = path }
    }

    /// kirocrew://chat/<slug> -> /chat/<slug>; kirocrew://notifications -> /notifications;
    /// kirocrew://sessions -> the Sessions list; kirocrew://apps -> the web app's Library of apps.
    static func path(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "kirocrew", let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let host = c.host ?? ""
        if host == "sessions" { return "/chat" }
        if host == "apps" && (c.path.isEmpty || c.path == "/") { return "/apps/library" }
        var p = "/" + host + (c.percentEncodedPath.hasPrefix("/") || c.percentEncodedPath.isEmpty ? "" : "/") + c.percentEncodedPath
        if p.hasSuffix("/") && p.count > 1 { p.removeLast() }
        if let q = c.percentEncodedQuery, !q.isEmpty { p += "?" + q }
        return isSafeAppPath(p) ? p : nil
    }

    /// Quick action types are "<bundle id>.sessions" etc. (Info.plist UIApplicationShortcutItems).
    static func path(forShortcut type: String) -> String? {
        guard type.hasPrefix(appIdentifier + ".") else { return nil }
        switch type.dropFirst(appIdentifier.count + 1) {
        case "sessions": return "/chat"
        case "newsession": return "/chat?new=1"
        case "inbox": return "/notifications"
        case "bots": return "/members"
        default: return nil
        }
    }
}

@available(iOS 16.0, *)
struct OpenSessionsIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Sessions"
    static var description = IntentDescription("Opens your Kiro Crew sessions.")
    static var openAppWhenRun: Bool = true
    @MainActor func perform() async throws -> some IntentResult {
        DeepLink.open("/chat")
        return .result()
    }
}

@available(iOS 16.0, *)
struct OpenInboxIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Inbox"
    static var description = IntentDescription("Opens your Kiro Crew inbox.")
    static var openAppWhenRun: Bool = true
    @MainActor func perform() async throws -> some IntentResult {
        DeepLink.open("/notifications")
        return .result()
    }
}

@available(iOS 16.0, *)
struct NewSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "New Session"
    static var description = IntentDescription("Starts a new Kiro Crew session.")
    static var openAppWhenRun: Bool = true
    @MainActor func perform() async throws -> some IntentResult {
        DeepLink.open("/chat?new=1")
        return .result()
    }
}

@available(iOS 16.0, *)
struct KiroCrewShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenSessionsIntent(), phrases: ["Open \(.applicationName) sessions", "Open sessions in \(.applicationName)"],
                    shortTitle: "Sessions", systemImageName: "bubble.left.and.bubble.right")
        AppShortcut(intent: NewSessionIntent(), phrases: ["New \(.applicationName) session", "Start a session in \(.applicationName)"],
                    shortTitle: "New Session", systemImageName: "square.and.pencil")
        AppShortcut(intent: OpenInboxIntent(), phrases: ["Open \(.applicationName) inbox", "Open my inbox in \(.applicationName)"],
                    shortTitle: "Inbox", systemImageName: "tray")
    }
}
