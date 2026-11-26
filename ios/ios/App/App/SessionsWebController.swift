import UIKit
import WebKit

// ---------------------------------------------------------------------------
// Home: the web app's OWN sessions list (sorting, folders, older sessions, search, filters,
// unread, row menus) — the `/embed/sessions` page the server ships for IDE plugins — in a
// second web view that shares the main web view's cookies (WKWebsiteDataStore.default()).
// Nothing about sessions is re-implemented here.
//
// A tap on a session makes that page route to /embed/chat/<key>. The script below turns that
// route change (history.pushState / replaceState, only right after a real tap) into a message
// and keeps this view on the list; the shell opens the chat in the main web view
// (/chat?sid=<key>). The plugin's tab strip is started on its Sessions tab and hidden.
//
// Security: same rules as WebBridge. Messages only from the main frame of the server origin in
// use; the path is re-checked and mapped natively. Only the server's /embed/sessions page loads
// here; links to other pages open in the main web view, other sites in the in-app browser.
// ---------------------------------------------------------------------------

final class SessionsWebController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    weak var shell: NativeShellController?
    private var webView: WKWebView!
    private var loadedOrigin: URL?
    private var failed = false
    private var inboxItem: UIBarButtonItem!
    private var inboxCount = 0
    private var background = Theme.lastBackground
    static let handlerName = "kcSessions"

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sessions"
        navigationItem.titleView = UIView()   // the page shows its own "Sessions" header
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // the main web view's cookies (and device sign-in)
        cfg.userContentController.add(self, contentWorld: .page, name: Self.handlerName)
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.accessibilityIdentifier = "sessions-web"
        attachWeb()

        let settings = UIBarButtonItem(image: UIImage(systemName: "gearshape"), primaryAction: UIAction { [weak self] _ in
            self?.shell?.showWeb(path: "/settings", title: "Settings")
        })
        settings.accessibilityLabel = "Settings"; settings.accessibilityIdentifier = "nav-settings"
        navigationItem.leftBarButtonItem = settings
        let compose = UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"), primaryAction: UIAction { [weak self] _ in
            Haptics.play("light"); self?.shell?.newSession()
        })
        compose.accessibilityLabel = "New Session"; compose.accessibilityIdentifier = "nav-new-session"
        inboxItem = UIBarButtonItem(image: UIImage(systemName: "bell"), primaryAction: UIAction { [weak self] _ in
            self?.shell?.showWeb(path: "/notifications", title: "Inbox")
        })
        inboxItem.accessibilityIdentifier = "nav-inbox"
        navigationItem.rightBarButtonItems = [compose, inboxItem]
        setInboxBadge(inboxCount)

        let bots = toolbarButton("Bots", "person.2", id: "toolbar-bots", primary: UIAction { [weak self] _ in
            Haptics.play("selection"); self?.shell?.showWeb(path: "/members", title: "Bots")
        })
        // Apps: the web app's own pages. Installed apps are on its Library page.
        let apps = toolbarButton("Apps", "square.grid.2x2", id: "toolbar-apps", primary: nil)
        if let b = apps.customView as? UIButton {
            b.menu = UIMenu(children: Self.appPages.map { p in
                UIAction(title: p.title, image: UIImage(systemName: p.symbol)) { [weak self] _ in
                    Haptics.play("selection"); self?.shell?.showWeb(path: p.path, title: p.title)
                }
            })
            b.showsMenuAsPrimaryAction = true
        }
        toolbarItems = [bots, .flexibleSpace(), apps]
        applyTheme(background)
        load()
    }

    /// The web app's built-in pages offered under Apps (paths are routes of the web app).
    static let appPages: [(title: String, path: String, symbol: String)] = [
        ("Library", "/apps/library", "square.grid.2x2"),
        ("Discover", "/apps", "sparkle.magnifyingglass"),
        ("Task Runner", "/projects", "checklist"),
        ("Channels", "/channels", "number"),
        ("Schedule", "/schedule", "calendar"),
        ("Artifacts", "/artifacts", "doc.richtext"),
        ("Webhooks", "/webhooks", "point.3.connected.trianglepath.dotted"),
        ("Customize", "/capabilities", "slider.horizontal.3"),
        ("Terminal", "/terminal", "terminal"),
    ]

    private func toolbarButton(_ title: String, _ symbol: String, id: String, primary: UIAction?) -> UIBarButtonItem {
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline))
        cfg.title = title
        cfg.imagePadding = 6
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        let b = UIButton(configuration: cfg, primaryAction: primary)
        b.accessibilityIdentifier = id
        return UIBarButtonItem(customView: b)
    }

    /// The web view lives here while the list is on screen. Otherwise it is parked in the window
    /// behind everything (WebKit pauses pages that are not in a window), so it is ready on Back.
    private func attachWeb() {
        guard webView.superview !== view else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    /// Called by the shell while another screen is on top.
    func park(in host: UIView) {
        guard isViewLoaded, view.window == nil, webView.superview !== host else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = view.bounds.isEmpty ? host.bounds : view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.insertSubview(webView, at: 0)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        attachWeb()
        navigationController?.setToolbarHidden(false, animated: animated)
        if failed { load(force: true) }
    }

    func setInboxBadge(_ n: Int) {
        inboxCount = n
        guard let inboxItem else { return }
        if #available(iOS 26.0, *) {
            inboxItem.badge = n > 0 ? .count(n) : nil
        } else {
            inboxItem.image = UIImage(systemName: n > 0 ? "bell.badge" : "bell")
        }
        inboxItem.accessibilityLabel = n > 0 ? "Inbox, \(n) unread" : "Inbox"
    }

    func applyTheme(_ c: UIColor) {
        background = c
        guard isViewLoaded else { return }
        view.backgroundColor = c
        webView.backgroundColor = c; webView.scrollView.backgroundColor = c; webView.underPageBackgroundColor = c
        let a = UINavigationBarAppearance()
        a.configureWithOpaqueBackground()
        a.backgroundColor = c
        a.shadowColor = .clear
        a.titleTextAttributes = [.foregroundColor: Theme.isDark(c) ? UIColor.white : UIColor.black]
        navigationItem.standardAppearance = a
        navigationItem.scrollEdgeAppearance = a
        navigationItem.compactAppearance = a
    }

    // MARK: Loading

    /// Loads the list on the server origin the main web view uses (no-op if it already shows it).
    /// `force`: reload (after sign-in, pairing, Retry).
    func load(force: Bool = false) {
        loadViewIfNeeded()   // also while a chat is on top (launch), so the list is ready on Back
        guard let origin = shell?.web.bridgeServerURL, let s = ServerStore.shared.active,
              let u = URL(string: "/embed/sessions", relativeTo: origin)?.absoluteURL else { return }
        if !force, !failed, let l = loadedOrigin, sameOrigin(l, origin), webView.url != nil { return }
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        let origins = (try? JSONSerialization.data(withJSONObject: s.urls.compactMap(originString))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let css = (try? JSONSerialization.data(withJSONObject: [Self.css], options: [.fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        ucc.addUserScript(WKUserScript(source: "(function(){var ORIGINS=\(origins);var CSS=\(css)[0];\n" + Self.script + "\n})();",
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        loadedOrigin = origin
        failed = false
        webView.load(URLRequest(url: u))
    }

    /// Another server: show nothing until its page has loaded in the main web view.
    func serverChanged() {
        loadedOrigin = nil
        if isViewLoaded { webView.loadHTMLString("", baseURL: nil) }
    }

    private var serverURL: URL? { shell?.web.bridgeServerURL }

    // MARK: Messages (main frame of the server origin only)

    func userContentController(_ ucc: WKUserContentController, didReceive m: WKScriptMessage) {
        guard m.name == Self.handlerName, m.frameInfo.isMainFrame, let origin = serverURL, matches(m.frameInfo.securityOrigin, origin),
              let body = m.body as? [String: Any], body["type"] as? String == "open",
              let raw = body["path"] as? String, let path = Self.appPath(embed: raw) else { return }
        Haptics.play("selection")
        shell?.showWeb(path: path)
    }

    /// The plugin page's route -> the same thing in the app: /embed/chat/<key> -> /chat?sid=<key>,
    /// /embed/chat?crew=<id>&key=<key> (another instance's session) -> /chat?crew=<id>&crewSid=<key>.
    static func appPath(embed raw: String) -> String? {
        guard isSafeAppPath(raw), let c = URLComponents(string: raw) else { return nil }
        func q(_ n: String) -> String? { c.queryItems?.first { $0.name == n }?.value.flatMap { $0.isEmpty || $0.count > 300 ? nil : $0 } }
        func enc(_ s: String) -> String {
            var ok = CharacterSet.alphanumerics
            ok.insert(charactersIn: "-._~")
            return s.addingPercentEncoding(withAllowedCharacters: ok) ?? ""
        }
        let p = c.path
        if p == "/embed/chat" || p == "/embed/chat/" {
            if let crew = q("crew"), let key = q("key") { return "/chat?crew=\(enc(crew))&crewSid=\(enc(key))" }
            return q("sid").map { "/chat?sid=" + enc($0) }
        }
        if p.hasPrefix("/embed/chat/") {
            let key = q("sid") ?? String(p.dropFirst("/embed/chat/".count))
            guard !key.isEmpty, key.count <= 300, !key.contains("/") else { return nil }
            return "/chat?sid=" + enc(key)
        }
        if p == "/embed/settings" { return "/settings" }
        return nil
    }

    // MARK: Navigation (only the server's sessions page loads here)

    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = a.request.url else { decisionHandler(.cancel); return }
        if url.scheme?.lowercased() == "about" { decisionHandler(.allow); return }
        guard let origin = serverURL, sameOrigin(url, origin) else {
            // Sign-in pages and other sites: never here (the main web view signs in).
            if a.navigationType == .linkActivated { shell?.web.openExternal(url) }
            decisionHandler(.cancel); return
        }
        guard a.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }   // same-origin frames
        if url.path == "/embed/sessions" { decisionHandler(.allow); return }
        // Another page of the server: open it in the app (a tap), never in this view.
        if a.navigationType == .linkActivated {
            var p = url.path.isEmpty ? "/" : url.path
            if let q = url.query, !q.isEmpty { p += "?" + q }
            if let mapped = Self.appPath(embed: p) { shell?.showWeb(path: mapped) }
            else if !p.hasPrefix("/embed/"), isSafeAppPath(p) { shell?.showWeb(path: p) }
        }
        decisionHandler(.cancel)
    }

    func webView(_ w: WKWebView, didReceive ch: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let m = ch.protectionSpace.authenticationMethod
        guard m == NSURLAuthenticationMethodServerTrust || m == NSURLAuthenticationMethodClientCertificate else {
            completionHandler(.performDefaultHandling, nil); return
        }
        // Same rules as the main web view; only it asks the user to trust a certificate.
        switch TrustStore.shared.outcome(for: ch, server: ServerStore.shared.active) {
        case .useDefault: completionHandler(.performDefaultHandling, nil)
        case .use(let c): completionHandler(.useCredential, c)
        case .untrusted: completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { loadFailed(e) }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { loadFailed(e) }
    private func loadFailed(_ e: Error) {
        let ns = e as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        failed = true   // tried again when this screen shows again or the main page reloads
    }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { failed = true; if view.window != nil { load(force: true) } }

    // MARK: Page dialogs (confirm before delete, rename prompts), window.open

    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: plainText(message, 1000), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a, orElse: completionHandler)
    }

    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: plainText(message, 1000), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(a, orElse: { completionHandler(false) })
    }

    func webView(_ w: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: plainText(prompt, 1000), preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { [weak a] _ in completionHandler(a?.textFields?.first?.text) })
        present(a, orElse: { completionHandler(nil) })
    }

    private func present(_ a: UIAlertController, orElse fallback: @escaping () -> Void) {
        guard let p = shell?.web.topPresenter, view.window != nil else { fallback(); return }
        p.present(a, animated: true)
    }

    func webView(_ w: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for a: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = a.request.url, let s = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(s) {
            if let origin = serverURL, sameOrigin(url, origin), isSafeAppPath(url.path) {
                shell?.showWeb(path: Self.appPath(embed: url.path + (url.query.map { "?" + $0 } ?? "")) ?? url.path)
            } else {
                shell?.web.openExternal(url)
            }
        }
        return nil
    }

    // MARK: Page script

    /// The plugin's tab strip (the app's own navigation replaces it) and the chat side panel (a
    /// chat opens full screen in the app). If the web app changes its markup, they just show again.
    static let css = [
        #"html.kc-sessions .shrink-0:has(> * > * > * > [role="tab"][data-tab-id]){display:none!important}"#,
        #"html.kc-sessions [data-testid="side-panel-inline"]{display:none!important}"#,
    ].joined(separator: "\n")

    private static let script = #"""
    if (ORIGINS.indexOf(location.origin) < 0) return;
    var H = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kcSessions;
    if (!H || window.__kcSessionsInstalled) return;
    window.__kcSessionsInstalled = true;
    document.documentElement.classList.add('kc-native', 'kc-sessions');
    try { var st = document.createElement('style'); st.textContent = CSS; document.documentElement.appendChild(st); } catch (e) {}
    // Start the plugin page on its Sessions tab (it would restore a chat tab otherwise).
    try { sessionStorage.removeItem('kirocrew-embed-tabs'); sessionStorage.removeItem('kirocrew-embed-active-index'); } catch (e) {}
    window.__kirocrewTabs = ['']; window.__kirocrewActiveTabIndex = 0;
    // A route change away from the list counts only right after the user's own tap.
    var tapped = 0;
    ['pointerup', 'click', 'touchend', 'keyup'].forEach(function (t) {
      addEventListener(t, function (e) { if (e.isTrusted) tapped = Date.now(); }, true);
    });
    var wrap = function (name) {
      var orig = history[name];
      history[name] = function (state, title, url) {
        if (url != null) {
          var u = null;
          try { u = new URL(String(url), location.href); } catch (e) {}
          if (u && u.origin === location.origin && u.pathname !== '/embed/sessions') {
            // The app opens it (a chat in the main view); this view stays on the list.
            if (tapped && Date.now() - tapped < 5000) {
              tapped = 0;
              try { H.postMessage({ type: 'open', path: u.pathname + u.search }); } catch (e) {}
            }
            return;
          }
        }
        return orig.apply(this, arguments);
      };
    };
    wrap('pushState'); wrap('replaceState');
    """#
}
