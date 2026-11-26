import UIKit
import WebKit
import UserNotifications

// ---------------------------------------------------------------------------
// Bridge between the Kiro Crew web app and the native shell.
//
// Security rules (every message, every time):
//  - Only messages from the MAIN frame whose security origin is the server origin
//    currently in use are accepted. Everything else is dropped (and answered with an error).
//  - Page data is untrusted: only small typed values are read (numbers, short strings, paths
//    matching ^/(?!/)). Nothing from the page is evaluated or put into HTML.
//  - Native -> page calls use callAsyncJavaScript with ARGUMENTS (never string-built JS).
//  - The page never sees tokens: device sign-in only sets cookies (DeviceAuth.swift).
//
// Pieces:
//  - WebBridge: user script (window.electronAPI subset, painted/theme reports,
//    window.Notification polyfill, html.kc-native class + narrow CSS), handlers
//    "kcNative" (with reply) and "kirocrewAuth".
//  - UIFilter: WKUIDelegate in front of Capacitor's; camera/mic only for the server origin.
//  - DownloadManager: WKDownload -> temporary file -> share sheet (Save to Files, AirDrop...).
// ---------------------------------------------------------------------------

/// "scheme://host[:port]" exactly like `location.origin` (default port omitted).
func originString(_ u: URL) -> String? {
    guard let s = u.scheme?.lowercased(), let h = u.host?.lowercased(), !h.isEmpty else { return nil }
    let def = s == "https" ? 443 : (s == "http" ? 80 : -1)
    if let p = u.port, p != def { return "\(s)://\(h):\(p)" }
    return "\(s)://\(h)"
}

func matches(_ o: WKSecurityOrigin, _ u: URL) -> Bool {
    guard let s = u.scheme?.lowercased(), let h = u.host?.lowercased() else { return false }
    let def = s == "https" ? 443 : (s == "http" ? 80 : 0)
    let op = o.port == 0 ? def : o.port
    let up = u.port ?? def
    return o.protocol.lowercased() == s && o.host.lowercased() == h && op == up
}

/// Plain text from the page / server: string only, control characters removed, length capped.
func plainText(_ v: Any?, _ max: Int) -> String {
    guard let s = v as? String else { return "" }
    let clean = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" })
    return String(clean.prefix(max))
}

/// In-app paths only: "/x/y?z", never "//host" or anything with a scheme, whitespace or backslash.
func isSafeAppPath(_ p: String) -> Bool {
    guard p.count <= 512, p.hasPrefix("/"), !p.hasPrefix("//") else { return false }
    return !p.contains(where: { $0 == "\\" || $0.isWhitespace || $0.isNewline || ($0.asciiValue.map { $0 < 0x20 || $0 == 0x7f } ?? false) })
}

protocol WebBridgeDelegate: AnyObject {
    /// The server origin currently loaded (internal or external URL in use), if any.
    var bridgeServerURL: URL? { get }
    func bridgePainted()
    func bridgeBadge(_ count: Int)
    func bridgeTheme(_ color: UIColor)
    func bridgeAuth(_ type: String)
}

final class WebBridge: NSObject, WKScriptMessageHandlerWithReply, WKScriptMessageHandler {
    weak var delegate: WebBridgeDelegate?
    private weak var webView: WKWebView?
    static let handlerName = "kcNative"
    static let authHandlerName = "kirocrewAuth"

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        let ucc = webView.configuration.userContentController
        ucc.addScriptMessageHandler(self, contentWorld: .page, name: Self.handlerName)
        ucc.add(self, contentWorld: .page, name: Self.authHandlerName)
    }

    /// Replaces all user scripts (this also drops Capacitor's own bridge script, which this app
    /// does not use: no plugins, and it would otherwise be injected into every main-frame page,
    /// sign-in hosts included). Called before each load so the origin allowlist is current.
    func installScripts(origins: [String]) {
        guard let ucc = webView?.configuration.userContentController else { return }
        ucc.removeAllUserScripts()
        ucc.removeScriptMessageHandler(forName: "bridge")   // Capacitor's handler; nothing here uses it
        let data = (try? JSONSerialization.data(withJSONObject: origins)) ?? Data("[]".utf8)
        let list = String(data: data, encoding: .utf8) ?? "[]"
        let css = (try? JSONSerialization.data(withJSONObject: [Self.css], options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        let src = "(function(){var ORIGINS=\(list);var CSS=\(css)[0];\n" + Self.script + "\n})();"
        ucc.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    }

    // MARK: Origin check

    private func trusted(_ m: WKScriptMessage) -> Bool {
        guard m.frameInfo.isMainFrame, let u = delegate?.bridgeServerURL else { return false }
        return matches(m.frameInfo.securityOrigin, u)
    }

    // MARK: Messages

    func userContentController(_ ucc: WKUserContentController, didReceive m: WKScriptMessage) {
        guard m.name == Self.authHandlerName, trusted(m), let body = m.body as? [String: Any],
              let type = body["type"] as? String, ["reauth", "logout", "signin"].contains(type) else { return }
        delegate?.bridgeAuth(type)
    }

    func userContentController(_ ucc: WKUserContentController, didReceive m: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard trusted(m), let body = m.body as? [String: Any], let type = body["type"] as? String else {
            replyHandler(nil, "denied"); return
        }
        switch type {
        case "painted":
            delegate?.bridgePainted(); replyHandler(true, nil)
        case "badge":
            let n = (body["count"] as? NSNumber)?.intValue ?? 0
            delegate?.bridgeBadge(min(max(n, 0), 99_999)); replyHandler(true, nil)
        case "theme":
            if let s = body["bg"] as? String, let c = Theme.parseCSSColor(s) { delegate?.bridgeTheme(c) }
            replyHandler(true, nil)
        case "haptic":
            Haptics.play(body["kind"] as? String ?? ""); replyHandler(true, nil)
        case "notifyStatus":
            LocalNotifications.status { replyHandler($0, nil) }
        case "notifyPermission":
            LocalNotifications.request { replyHandler($0, nil) }
        case "notify":
            let title = plainText(body["title"], 200)
            let text = plainText(body["body"], 1000)
            let tag = plainText(body["tag"], 100)
            let path = (body["path"] as? String).flatMap { isSafeAppPath($0) ? $0 : nil }
            LocalNotifications.post(title: title, body: text, tag: tag, path: path)
            replyHandler(true, nil)
        default:
            replyHandler(nil, "unknown")
        }
    }


    // MARK: Native -> page

    /// Navigates the single-page app to an in-app path without a reload. Uses the web app's own
    /// onNavigate hook when it registered one, else pushState + popstate (React Router listens).
    func navigate(_ path: String, completion: @escaping (Bool) -> Void) {
        guard isSafeAppPath(path), let w = webView else { completion(false); return }
        let js = """
        if (window.__kcNav && window.__kcNav(p)) return true;
        var idx = (history.state && typeof history.state.idx === 'number') ? history.state.idx + 1 : 0;
        history.pushState({usr: null, key: Math.random().toString(36).slice(2, 10), idx: idx}, '', p);
        dispatchEvent(new PopStateEvent('popstate', {state: history.state}));
        return true;
        """
        w.callAsyncJavaScript(js, arguments: ["p": path], in: nil, in: .page) { r in
            if case .success = r { completion(true) } else { completion(false) }
        }
    }

    /// Opens the web app's Command Bar (search everything) with its own ⌘K shortcut.
    func openCommandBar() {
        let js = "document.dispatchEvent(new KeyboardEvent('keydown', {key: 'k', code: 'KeyK', metaKey: true, bubbles: true, cancelable: true})); return true;"
        webView?.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page, completionHandler: nil)
    }

    /// Opens the web app's docked terminal (a panel over the current page, not a page of its own:
    /// the /terminal route only redirects). Uses the nav item when the page has it, else the
    /// web app's own toggle shortcut (Ctrl+`). Does nothing if the terminal is already open.
    func openTerminal(completion: @escaping (Bool) -> Void) {
        guard let w = webView else { completion(false); return }
        let js = """
        // The web app keeps closed terminals warm off screen: "open" means one on screen.
        const shown = () => [...document.querySelectorAll('.xterm')].some(e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.right > 0 && r.left < innerWidth; });
        if (shown()) return true;
        const item = document.querySelector('[data-ui-location="shell.terminal"]');
        if (item) { item.click(); }
        else { document.dispatchEvent(new KeyboardEvent('keydown', {key: '`', code: 'Backquote', ctrlKey: true, bubbles: true, cancelable: true})); }
        for (let i = 0; i < 10 && !shown(); i++) await new Promise(r => setTimeout(r, 150));
        return shown();
        """
        w.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { r in
            if case .success(let v) = r { completion((v as? Bool) == true) } else { completion(false) }
        }
    }

    /// Closes the docked terminal if one is on screen (same toggle as opening it).
    func closeTerminal() {
        let js = """
        const shown = [...document.querySelectorAll('.xterm')].some(e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.right > 0 && r.left < innerWidth; });
        if (shown) document.dispatchEvent(new KeyboardEvent('keydown', {key: '`', code: 'Backquote', ctrlKey: true, bubbles: true, cancelable: true}));
        return shown;
        """
        webView?.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page, completionHandler: nil)
    }

    /// Back via the web app's onHistoryStep hook when present; else WebKit history.
    func historyBack() {
        guard let w = webView else { return }
        w.callAsyncJavaScript("return !!(window.__kcHistoryStep && window.__kcHistoryStep(-1));",
                              arguments: [:], in: nil, in: .page) { [weak w] r in
            if case .success(let v) = r, (v as? Bool) == true { return }
            if w?.canGoBack == true { w?.goBack() }
        }
    }

    // MARK: Native-owned web controls

    /// Web controls the native shell replaces (hidden by `css`, triggered from native buttons).
    /// Selectors are the deployed web app's own stable attributes (data-testid / data-ui-location),
    /// never page-provided text.
    enum WebControl: String {
        /// Chat: the session list drawer toggle (replaced by the Sessions screen; kept for reference).
        case sessionsToggle = "header.topbar-phone [data-testid=\"mobile-topbar-sessions-toggle\"]"
        /// Chat: the session title's options menu (native: tappable title).
        case sessionMenu = "header.topbar-phone [data-testid=\"session-title-menu\"]"
        /// Chat: the page's overflow menu (native: ··· > Session Tools).
        case sessionMore = "header.topbar-phone [data-testid=\"mobile-topbar-more\"]"

        /// Menus (Radix dropdowns) open on pointerdown, buttons on click.
        var opensMenu: Bool { self != .sessionsToggle }
    }

    /// Phone header pieces the native bars own, scoped under html.kc-native and to the phone
    /// header (`header.topbar-phone`) or the phone nav drawer only:
    ///  - logo button (opens the nav drawer) + the drawer itself, and the icon rail inside the
    ///    session / bot drawers: the Sessions screen, Apps menu and ··· > Search cover them;
    ///  - notifications bell: the Sessions list's Inbox button (badge);
    ///  - chat: sessions toggle + the sessions drawer (also opened by a left-edge swipe, which is
    ///    the native Back here), session title menu trigger, ⋯ trigger: native ‹ Sessions, native
    ///    title (tap for the session menu), native ··· menu. Triggered via `press(_:)`.
    /// When nothing else is left in the header (no other button, no input such as the inline
    /// rename field, no Bots thread header), the header row collapses to 0 height. Anything the
    /// web app adds there later (update pill, offline strip, ...) keeps the row visible.
    static let css: String = {
        let hidden = [
            "[data-ui-location=\"shell.mobile-menu\"]",
            "[data-ui-location=\"shell.notifications\"]",
            "[data-testid=\"mobile-topbar-sessions-toggle\"]",
            "[data-testid=\"session-title-menu\"]",
            "[data-testid=\"mobile-topbar-more\"]",
        ]
        let hide = hidden.map { "html.kc-native header.topbar-phone \($0)" }.joined(separator: ",")
        let others = "input,textarea,select,[contenteditable=\"true\"],[data-testid=\"member-thread-header\"],button:not(\(hidden.joined(separator: ",")))"
        let shell = "html.kc-native [data-testid=\"dashboard-shell\"]"
        return [
            "\(hide){display:none!important}",
            "html.kc-native header.topbar-phone:not(:has(:is(\(others)))){height:0!important;min-height:0!important;padding:0!important;"
                + "border:0!important;box-shadow:none!important;background:transparent!important;pointer-events:none!important}",
            "\(shell):has(> header.topbar-phone):not(:has(> header.topbar-phone :is(\(others)))){grid-template-rows:0 minmax(0,1fr)!important}",
            "\(shell):has(> header.topbar-phone) > [data-testid=\"nav-backdrop\"],"
                + "\(shell):has(> header.topbar-phone) > nav[role=\"navigation\"]{display:none!important}",
            // The phone's icon rail inside the session / bot drawers (Sessions, Bots, Schedule, apps, Settings, Search).
            "html.kc-native [data-testid=\"mobile-nav-rail\"]{display:none!important}",
            // The chat's sessions drawer (the Sessions screen replaces it) and its backdrop.
            "html.kc-native [data-testid=\"sessions-backdrop\"],"
                + "html.kc-native :has(> [data-testid=\"mobile-split-drawer\"]){display:none!important;pointer-events:none!important}",
        ].joined(separator: "\n")
    }()

    /// Triggers one of the hidden web controls. Returns false if the page does not have it.
    func press(_ c: WebControl, completion: ((Bool) -> Void)? = nil) {
        guard let w = webView else { completion?(false); return }
        let js = """
        const el = document.querySelector(sel);
        if (!el) return false;
        if (menu) {
          const o = {bubbles: true, cancelable: true, button: 0, buttons: 1, pointerType: 'mouse', isPrimary: true};
          el.dispatchEvent(new PointerEvent('pointerdown', o));
          el.dispatchEvent(new PointerEvent('pointerup', Object.assign({}, o, {buttons: 0})));
        } else {
          el.click();
        }
        return true;
        """
        w.callAsyncJavaScript(js, arguments: ["sel": c.rawValue, "menu": c.opensMenu], in: nil, in: .page) { r in
            if case .success(let v) = r { completion?((v as? Bool) == true) } else { completion?(false) }
        }
    }

    /// Whether the page currently has the control (e.g. the chat page with a session open).
    func has(_ c: WebControl, completion: @escaping (Bool) -> Void) {
        guard let w = webView else { completion(false); return }
        w.callAsyncJavaScript("return !!document.querySelector(sel);", arguments: ["sel": c.rawValue], in: nil, in: .page) { r in
            if case .success(let v) = r { completion((v as? Bool) == true) } else { completion(false) }
        }
    }

    /// Tells the page's Notification polyfill the current permission (after the user decided in
    /// the app's own settings), so the page does not need a reload.
    func notificationPermissionChanged(_ p: String) {
        guard p == "granted" || p == "denied" || p == "default" else { return }
        webView?.callAsyncJavaScript("if (window.__kcSetNotifyPermission) window.__kcSetNotifyPermission(p); return true;",
                                     arguments: ["p": p], in: nil, in: .page, completionHandler: nil)
    }

    // MARK: Script

    // Runs at document start in every main frame, but does nothing unless the page origin is one
    // of the configured server origins (ORIGINS). The native side checks the origin again.
    private static let script = #"""
    if (ORIGINS.indexOf(location.origin) < 0) return;
    if (window.__kcNativeInstalled) return;
    window.__kcNativeInstalled = true;
    var H = window.webkit && window.webkit.messageHandlers;
    if (!H || !H.kcNative) return;
    var post = function (m) { try { return H.kcNative.postMessage(m); } catch (e) { return Promise.reject(e); } };
    var swallow = function (p) { if (p && p.catch) p.catch(function () {}); };

    document.documentElement.classList.add('kc-native');
    try {
      var st = document.createElement('style');
      st.id = 'kc-native-style';
      st.textContent = CSS;
      document.documentElement.appendChild(st);
    } catch (e) {}

    // window.electronAPI subset (the web app calls each one only if present).
    var navCbs = [], histCbs = [];
    var sub = function (list) {
      return function (cb) {
        if (typeof cb !== 'function') return function () {};
        list.push(cb);
        return function () { var i = list.indexOf(cb); if (i >= 0) list.splice(i, 1); };
      };
    };
    if (!window.electronAPI) {
      try {
        Object.defineProperty(window, 'electronAPI', { configurable: false, writable: false, value: Object.freeze({
          setBadgeCount: function (n) { n = Number(n); if (isFinite(n)) swallow(post({ type: 'badge', count: Math.max(0, Math.floor(n)) })); },
          onNavigate: sub(navCbs),
          onHistoryStep: sub(histCbs)
        }) });
      } catch (e) {}
    }
    window.__kcNav = function (p) {
      if (!navCbs.length) return false;
      navCbs.slice().forEach(function (cb) { try { cb(p); } catch (e) {} });
      return true;
    };
    window.__kcHistoryStep = function (d) {
      if (!histCbs.length) return false;
      histCbs.slice().forEach(function (cb) { try { cb(d); } catch (e) {} });
      return true;
    };

    // Page background -> native bars. body uses background: var(--bg) with a .25s transition.
    var themeTimer = null;
    var reportTheme = function () {
      clearTimeout(themeTimer);
      themeTimer = setTimeout(function () {
        try {
          var bg = getComputedStyle(document.body || document.documentElement).backgroundColor;
          swallow(post({ type: 'theme', bg: String(bg || '') }));
        } catch (e) {}
      }, 320);
    };

    // First paint: #root got children.
    var painted = false;
    var watchRoot = function () {
      var r = document.getElementById('root');
      if (!r) { swallow(post({ type: 'painted' })); return; }
      var check = function () {
        if (painted || !r.firstElementChild) return;
        painted = true;
        if (mo) mo.disconnect();
        swallow(post({ type: 'painted' }));
        reportTheme();
      };
      var mo = new MutationObserver(check);
      mo.observe(r, { childList: true });
      check();
    };
    document.addEventListener('DOMContentLoaded', function () {
      watchRoot();
      reportTheme();
      try {
        new MutationObserver(reportTheme).observe(document.documentElement,
          { attributes: true, attributeFilter: ['class', 'data-theme', 'style'] });
      } catch (e) {}
    });

    // window.Notification -> iOS local notifications (while the app is running).
    if (!('Notification' in window)) {
      var perm = 'default';
      var N = function (title, opts) {
        opts = opts || {};
        this.title = String(title == null ? '' : title);
        this.body = String(opts.body == null ? '' : opts.body);
        this.tag = String(opts.tag == null ? '' : opts.tag);
        this.data = opts.data;
        this.onclick = null; this.onclose = null; this.onerror = null; this.onshow = null;
        if (perm === 'granted') {
          var path = (opts.data && typeof opts.data.url === 'string') ? opts.data.url : '';
          swallow(post({ type: 'notify', title: this.title, body: this.body, tag: this.tag, path: path }));
        }
      };
      N.prototype.close = function () {};
      N.prototype.addEventListener = function () {};
      N.prototype.removeEventListener = function () {};
      Object.defineProperty(N, 'permission', { get: function () { return perm; } });
      // iOS asks the user only for a call made while handling the user's own tap or key press
      // (like Safari): the web app also calls requestPermission() by itself when new notifications
      // arrive, and that must not put the system prompt over the app on first launch. Otherwise
      // the call answers with the current state. The app's own Settings (Notifications) asks too.
      // (navigator.userActivation is not usable here: the app's own script calls into the page
      // count as user activation in WKWebView.)
      var GESTURES = ['click', 'pointerup', 'mouseup', 'touchend', 'keydown', 'keyup', 'change', 'input', 'submit'];
      var userGesture = function () {
        try { var ev = window.event; return !!(ev && ev.isTrusted && GESTURES.indexOf(ev.type) >= 0); } catch (e) { return false; }
      };
      N.requestPermission = function (cb) {
        var done = function () { if (typeof cb === 'function') { try { cb(perm); } catch (e) {} } return perm; };
        if (perm !== 'default' || !userGesture()) return Promise.resolve(perm).then(done);
        return post({ type: 'notifyPermission' }).then(function (r) {
          if (r === 'granted' || r === 'denied') perm = r;
          return done();
        }, done);
      };
      window.Notification = N;
      window.__kcSetNotifyPermission = function (p) { if (p === 'granted' || p === 'denied' || p === 'default') perm = p; };
      post({ type: 'notifyStatus' }).then(function (r) { if (r === 'granted' || r === 'denied') perm = r; }, function () {});
    }

    // Small hooks the web app can use later: window.kcNative.haptic('success' | 'warning' | 'error' | 'light').
    try {
      Object.defineProperty(window, 'kcNative', { configurable: false, writable: false, value: Object.freeze({
        haptic: function (k) { swallow(post({ type: 'haptic', kind: String(k || '') })); },
        reauth: function () { try { H.kirocrewAuth.postMessage({ type: 'reauth' }); } catch (e) {} }
      }) });
    } catch (e) {}
    """#
}

// MARK: - Haptics

enum Haptics {
    static func play(_ kind: String) {
        switch kind {
        case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "selection": UISelectionFeedbackGenerator().selectionChanged()
        case "light": UIImpactFeedbackGenerator(style: .light).impactOccurred()
        default: break
        }
    }
}

// MARK: - Local notifications + badge

enum LocalNotifications {
    /// Path to open when a notification is tapped (set by the shell).
    static var onOpenPath: ((String) -> Void)?

    static func status(_ done: @escaping (String) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let r: String
            switch s.authorizationStatus {
            case .authorized, .provisional, .ephemeral: r = "granted"
            case .denied: r = "denied"
            default: r = "default"
            }
            DispatchQueue.main.async { done(r) }
        }
    }

    static func request(_ done: @escaping (String) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            DispatchQueue.main.async { done(ok ? "granted" : "denied") }
        }
    }

    static func post(title: String, body: String, tag: String, path: String?) {
        let c = UNMutableNotificationContent()
        c.title = title.isEmpty ? "Kiro Crew" : title
        c.body = body
        c.sound = .default
        if let path { c.userInfo = ["path": path] }
        if !tag.isEmpty { c.threadIdentifier = tag }
        let id = tag.isEmpty ? UUID().uuidString : "tag-" + tag
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    /// App icon badge. Uses the badge permission only; never prompts on its own.
    static func setBadge(_ n: Int) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            guard s.badgeSetting == .enabled else { return }
            DispatchQueue.main.async {
                if #available(iOS 16.0, *) {
                    UNUserNotificationCenter.current().setBadgeCount(n)
                } else {
                    UIApplication.shared.applicationIconBadgeNumber = n
                }
            }
        }
    }
}

// MARK: - UI delegate filter

/// Sits in front of Capacitor's WKUIDelegate (alerts/confirm/prompt stay Capacitor's).
final class UIFilter: NSObject, WKUIDelegate {
    var inner: (NSObjectProtocol & WKUIDelegate)?
    /// The server URL in use (internal or external), if any.
    var serverURL: () -> URL?
    /// True if the URL belongs to the active server (either of its URLs).
    var isServerURL: (URL) -> Bool
    var openExternal: (URL) -> Void = { UIApplication.shared.open($0) }

    init(inner: (NSObjectProtocol & WKUIDelegate)?, serverURL: @escaping () -> URL?, isServerURL: @escaping (URL) -> Bool) {
        self.inner = inner; self.serverURL = serverURL; self.isServerURL = isServerURL
    }
    override func responds(to s: Selector!) -> Bool { super.responds(to: s) || (inner?.responds(to: s) ?? false) }
    override func forwardingTarget(for s: Selector!) -> Any? { inner?.responds(to: s) == true ? inner : super.forwardingTarget(for: s) }

    /// Camera / microphone: only the server origin in use (and only from frames of that origin).
    /// iOS still asks the user for camera / microphone access the first time.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard let u = serverURL(), matches(origin, u), matches(frame.securityOrigin, u) else { decisionHandler(.deny); return }
        decisionHandler(.grant)
    }

    func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    /// window.open / target=_blank: the server's own pages open in place, everything else in Safari.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        let scheme = url.scheme?.lowercased() ?? ""
        if isServerURL(url) && isAllowedServer(url) { webView.load(action.request) }
        else if scheme == "https" || scheme == "http" || scheme == "mailto" { openExternal(url) }
        return nil
    }
}

// MARK: - Downloads

final class DownloadManager: NSObject, WKDownloadDelegate {
    var presenter: () -> UIViewController? = { nil }
    var server: () -> ServerConfig? = { nil }
    private var files: [ObjectIdentifier: URL] = [:]

    static func shouldDownload(_ r: WKNavigationResponse) -> Bool {
        guard r.isForMainFrame else { return false }
        if let h = r.response as? HTTPURLResponse,
           let cd = h.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(), cd.hasPrefix("attachment") {
            return true
        }
        return !r.canShowMIMEType
    }

    private static func safeName(_ s: String) -> String {
        var n = (s as NSString).lastPathComponent
        n = String(n.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != ":" && $0 != "\\" })
        n = n.trimmingCharacters(in: .whitespaces)
        if n.isEmpty || n == "." || n == ".." || n.hasPrefix(".") { n = "download" + n }
        return String(n.prefix(120))
    }

    func download(_ d: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(Self.safeName(suggestedFilename))
            files[ObjectIdentifier(d)] = url
            completionHandler(url)
        } catch { completionHandler(nil) }
    }

    func download(_ d: WKDownload, didReceive ch: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch TrustStore.shared.outcome(for: ch, server: server()) {
        case .useDefault: completionHandler(.performDefaultHandling, nil)
        case .use(let c): completionHandler(.useCredential, c)
        case .untrusted: completionHandler(.cancelAuthenticationChallenge, nil)   // the web view prompts for trust, not downloads
        }
    }

    func downloadDidFinish(_ d: WKDownload) {
        guard let url = files.removeValue(forKey: ObjectIdentifier(d)), let p = presenter() else { return }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        share.popoverPresentationController?.sourceView = p.view
        share.popoverPresentationController?.sourceRect = CGRect(x: p.view.bounds.midX, y: p.view.bounds.midY, width: 1, height: 1)
        p.present(share, animated: true)
    }

    func download(_ d: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let url = files.removeValue(forKey: ObjectIdentifier(d)) {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        guard let p = presenter() else { return }
        let a = UIAlertController(title: "Download failed", message: error.localizedDescription, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        p.present(a, animated: true)
    }
}
