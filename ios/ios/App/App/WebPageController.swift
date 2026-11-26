import UIKit
import WebKit

// ---------------------------------------------------------------------------
// The full-screen web page (one instance; it hosts the shared web view while on screen):
//
//   ‹ (back to Sessions)   title (two lines; in a chat: tap for the session menu)   ···
//   web view (composer at the bottom safe area; the page shrinks above the keyboard)
//
// ··· holds Search, Session Tools, Session Options, Reload, Share, Copy Link, Open in Browser,
// Pair This Phone (unpaired, server supports it) and Server Settings.
// Back: from a chat always the Sessions list. On other pages, drill-ins inside the page
// (Settings › a section, Bots › a bot, Inbox › an item) go back inside the page first: by the
// page's history, or (a drill-in that replaced the entry) to the page that was opened.
// ---------------------------------------------------------------------------

final class WebPageController: UIViewController {
    private unowned let shell: NativeShellController
    private var web: KiroCrewViewController { shell.web }
    private let container = UIView()
    private let titleButton = TitleButton()
    private var bottomToSafeArea: NSLayoutConstraint!
    private var bottomToView: NSLayoutConstraint!
    private var background = Theme.lastBackground
    private(set) var pageTitle = "Kiro Crew"
    private var preparedTitle: String?
    /// A title that stays until the next page is opened (the docked terminal over a page).
    private var pinnedTitle: String?
    private var hasSessionMenu = false
    private var hasSessionMore = false
    /// The history entry the native side opened; Back inside the page never goes past it.
    private var entryItem: WKBackForwardListItem?
    private var entryPath: String?
    private var entryPending = true

    init(shell: NativeShellController) {
        self.shell = shell
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.titleView = titleButton
        titleButton.addAction(UIAction { [weak self] _ in self?.titleTapped() }, for: .touchUpInside)
        updateMenu()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = background
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)
        bottomToSafeArea = container.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        bottomToView = container.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomToSafeArea,
        ])
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        applyTheme(background)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        attachWeb()
        titleChanged()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshSessionControls()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if navigationController?.isNavigationBarHidden == true { navigationController?.setNavigationBarHidden(false, animated: animated) }
    }

    /// Takes the shared web view from wherever it is (parked in the shell) into this page.
    private func attachWeb() {
        guard web.parent !== self else { return }
        if web.parent != nil { web.willMove(toParent: nil); web.view.removeFromSuperview(); web.removeFromParent() }
        addChild(web)
        web.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(web.view)
        NSLayoutConstraint.activate([
            web.view.topAnchor.constraint(equalTo: container.topAnchor),
            web.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            web.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        web.didMove(toParent: self)
    }

    // MARK: Opening

    /// Title to show until the page reports its own (the row the user tapped).
    func prepare(title: String?) {
        preparedTitle = title.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
        if let t = preparedTitle { pageTitle = t; applyTitle() }
    }

    /// The native side is about to open `path`: Back inside the page starts from there.
    func willOpen(_ path: String) {
        entryPending = true
        entryItem = nil; entryPath = nil
        pinnedTitle = nil
        hasSessionMenu = false; hasSessionMore = false
        updateBack()
        updateMenu()
    }

    // MARK: Route, title

    private var currentPath: String? { shell.currentPath }
    private var isChat: Bool { NativeShellController.isChat(currentPath) }

    func pinTitle(_ t: String) { pinnedTitle = t; pageTitle = t; applyTitle() }

    func routeChanged() {
        if entryPending, shell.currentURL != nil, let item = web.webView?.backForwardList.currentItem {
            entryPending = false
            entryItem = item
            entryPath = currentPath
        }
        titleChanged()
        updateBack()
        updateMenu()
        // The chat page draws its header a moment after the route changes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refreshSessionControls() }
    }

    func titleChanged() {
        var t = web.webView?.title ?? ""
        if let r = t.range(of: #"^\((\d+)\)\s*"#, options: .regularExpression) { t.removeSubrange(r) }
        // "<page> — Kiro Crew", "<session> — Chat — Kiro Crew": keep the first part.
        for sep in [" — ", " – ", " | "] where t.contains(sep) {
            var parts = t.components(separatedBy: sep)
            parts.removeLast()                                        // product name
            if parts.count > 1, parts.last.map({ $0.count <= 20 && !$0.contains(" ") }) == true { parts.removeLast() }   // section
            t = parts.joined(separator: sep)
        }
        t = plainText(t, 200).trimmingCharacters(in: .whitespacesAndNewlines)
        let routeName = currentPath.flatMap { NativeShellController.routeTitle(path: $0, query: nil) }
        if t.isEmpty || t == "Kiro Crew" {
            // Keep the tapped row's title while a chat loads; else the route's own name.
            t = (isChat ? preparedTitle : nil) ?? routeName ?? preparedTitle ?? "Kiro Crew"
        } else {
            preparedTitle = nil
        }
        pageTitle = String((pinnedTitle ?? t).prefix(120))
        applyTitle()
        refreshSessionControls()
    }

    private func applyTitle() {
        let fg: UIColor = Theme.isDark(background) ? .white : .black
        titleButton.set(title: pageTitle, color: fg, menu: isChat && hasSessionMenu)
        titleButton.accessibilityIdentifier = isChat ? "session-title" : "page-title"
        navigationItem.title = pageTitle   // for the back menu / accessibility
    }

    private func titleTapped() {
        guard isChat && hasSessionMenu else { return }
        Haptics.play("light")
        web.bridgeJS?.press(.sessionMenu)
    }

    /// Asks the page which chat controls it has (a session is open), then updates the bar.
    private func refreshSessionControls() {
        guard isChat, let b = web.bridgeJS else {
            if hasSessionMenu || hasSessionMore { hasSessionMenu = false; hasSessionMore = false; applyTitle(); updateMenu() }
            return
        }
        b.has(.sessionMenu) { [weak self] menu in
            b.has(.sessionMore) { more in
                guard let self, self.isChat else { return }
                guard menu != self.hasSessionMenu || more != self.hasSessionMore else { return }
                self.hasSessionMenu = menu; self.hasSessionMore = more
                self.applyTitle()
                self.updateMenu()
            }
        }
    }

    // MARK: Bar items

    func updateMenu() {
        var page: [UIMenuElement] = [
            UIAction(title: "Search", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in self?.web.bridgeJS?.openCommandBar() },
        ]
        if isChat && hasSessionMore {
            page.append(UIAction(title: "Session Tools…", image: UIImage(systemName: "rectangle.3.group")) { [weak self] _ in
                self?.web.bridgeJS?.press(.sessionMore)
            })
        }
        if isChat && hasSessionMenu {
            page.append(UIAction(title: "Session Options…", image: UIImage(systemName: "text.bubble")) { [weak self] _ in
                self?.web.bridgeJS?.press(.sessionMenu)
            })
        }
        let link: [UIMenuElement] = [
            UIAction(title: "Reload", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.web.reloadPage() },
            UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.share() },
            UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { [weak self] _ in
                if let u = self?.web.shareableURL { UIPasteboard.general.url = u; Haptics.play("success") }
            },
            UIAction(title: "Open in Browser", image: UIImage(systemName: "safari")) { [weak self] _ in
                if let u = self?.web.shareableURL { UIApplication.shared.open(u) }   // the user's default browser
            },
        ]
        var server: [UIMenuElement] = []
        if let s = ServerStore.shared.active, shell.pairingSupported == true, !DeviceAuth.isPaired(serverID: s.id) {
            server.append(UIAction(title: "Pair This Phone…", image: UIImage(systemName: "iphone.badge.checkmark")) { [weak self] _ in
                self?.shell.startPairing()
            })
        }
        server.append(UIAction(title: "Server Settings…", image: UIImage(systemName: "server.rack")) { [weak self] _ in
            self?.web.presentSettings()
        })
        let menu = UIMenu(children: [
            UIMenu(title: "", options: .displayInline, children: page),
            UIMenu(title: "", options: .displayInline, children: link),
            UIMenu(title: "", options: .displayInline, children: server),
        ])
        let more = navigationItem.rightBarButtonItems?.first ?? UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: menu)
        more.menu = menu
        more.accessibilityLabel = "More"; more.accessibilityIdentifier = "nav-more"
        navigationItem.rightBarButtonItems = [more]
    }

    /// Back by the page's own history: a drill-in pushed after the page that was opened.
    private var historyBack: Bool {
        guard let w = web.webView, let path = currentPath, !isChat,
              let entry = entryItem, w.backForwardList.currentItem !== entry,
              w.backForwardList.backList.contains(where: { $0 === entry }),
              let back = w.backForwardList.backItem, web.isActiveServer(back.url) else { return false }
        return NativeShellController.section(for: back.url.path.isEmpty ? "/" : back.url.path) == NativeShellController.section(for: path)
    }

    /// A drill-in that replaced the history entry (Settings › a section): one level up is the
    /// page that was opened.
    private var parentBack: String? {
        guard !isChat, let path = currentPath, let entry = entryPath, entry != "/", path.hasPrefix(entry + "/") else { return nil }
        return entry
    }

    /// Back inside the page (drill-ins outside a chat), else the system Back (pops).
    func updateBack() {
        guard historyBack || parentBack != nil else {
            if navigationItem.leftBarButtonItem != nil { navigationItem.leftBarButtonItem = nil }
            return
        }
        guard navigationItem.leftBarButtonItem == nil else { return }
        let b = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"), style: .plain, target: self, action: #selector(webBack))
        b.accessibilityLabel = "Back"; b.accessibilityIdentifier = "nav-back"
        navigationItem.leftBarButtonItem = b
    }

    @objc private func webBack() {
        if historyBack { web.goBack() } else if let p = parentBack { web.open(path: p) }
    }

    private func share() {
        guard let u = web.shareableURL else { return }
        let a = UIActivityViewController(activityItems: [u], applicationActivities: nil)
        a.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
        web.topPresenter.present(a, animated: true)
    }

    // MARK: Theme

    func applyTheme(_ c: UIColor) {
        background = c
        guard isViewLoaded else { return }
        let dark = Theme.isDark(c)
        view.backgroundColor = c
        container.backgroundColor = c
        let fg: UIColor = dark ? .white : .black
        let a = UINavigationBarAppearance()
        a.configureWithOpaqueBackground()
        a.backgroundColor = c
        a.shadowColor = dark ? UIColor.white.withAlphaComponent(0.08) : UIColor.black.withAlphaComponent(0.08)
        a.titleTextAttributes = [.foregroundColor: fg]
        navigationItem.standardAppearance = a
        navigationItem.scrollEdgeAppearance = a
        navigationItem.compactAppearance = a
        applyTitle()
    }

    // MARK: Keyboard: keep the composer above it

    @objc private func keyboardWillChange(_ n: Notification) {
        guard let info = n.userInfo, let endScreen = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              view.window != nil else { return }
        let end = view.convert(endScreen, from: nil)
        let hiding = n.name == UIResponder.keyboardWillHideNotification
        let overlap = hiding ? 0 : max(0, view.bounds.maxY - end.minY)
        let up = overlap > view.safeAreaInsets.bottom
        // Landscape with the keyboard up leaves too little height: the bar steps aside for the composer.
        let hideBar = up && traitCollection.verticalSizeClass == .compact
        if navigationController?.isNavigationBarHidden != hideBar, navigationController?.topViewController === self {
            navigationController?.setNavigationBarHidden(hideBar, animated: true)
        }
        bottomToSafeArea.isActive = !up
        bottomToView.constant = -overlap
        bottomToView.isActive = up
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
        UIView.animate(withDuration: duration, delay: 0, options: UIView.AnimationOptions(rawValue: curve << 16), animations: {
            self.view.layoutIfNeeded()
        }, completion: { _ in
            // The web app is a fixed-height layout with its own scrollers: undo WebKit's scroll of the
            // whole page (it would push the header off screen) when the page fits the view.
            guard let sv = self.web.webView?.scrollView, sv.contentSize.height <= sv.bounds.height + 1 else { return }
            if sv.contentOffset != .zero { sv.setContentOffset(.zero, animated: false) }
        })
    }
}

/// Navigation bar title: up to two lines (shrinks a little before truncating), optional chevron
/// when it opens the session menu.
final class TitleButton: UIControl {
    private let label = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down",
                                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 2
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        label.lineBreakMode = .byTruncatingTail
        label.isUserInteractionEnabled = false
        chevron.isUserInteractionEnabled = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [label, chevron])
        stack.spacing = 4
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .header
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Fills the space between the bar's items.
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.layoutFittingExpandedSize.width, height: 44) }

    func set(title: String, color: UIColor, menu: Bool) {
        label.text = title   // plain text, never HTML
        label.textColor = color
        chevron.tintColor = color.withAlphaComponent(0.6)
        chevron.isHidden = !menu
        isEnabled = menu
        accessibilityLabel = title
        accessibilityTraits = menu ? [.header, .button] : .header
        accessibilityHint = menu ? "Session options" : nil
    }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.5 : 1 } }
}
