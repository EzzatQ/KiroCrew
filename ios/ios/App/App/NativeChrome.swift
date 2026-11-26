import UIKit
import LocalAuthentication

// ---------------------------------------------------------------------------
// Native chrome pieces used by NativeShellController:
//  - Theme: page background colour -> bar colours, status bar style, light/dark.
//  - CoverView: launch cover (logo + spinner) shown until the page has painted.
//  - ErrorView: full-screen "Could not load" screen (Retry / Server settings).
//  - AppPrefs: app-wide settings (app lock, device sign-in protection, where links open).
//  - PrivacyShield: blur shown while the app is inactive, optional Face ID lock.
// ---------------------------------------------------------------------------

enum Theme {
    /// Kiro Crew's dark page background (`--bg`), used until the page reports its own.
    static let defaultBackground = UIColor(red: 0x0d / 255.0, green: 0x0f / 255.0, blue: 0x12 / 255.0, alpha: 1)

    /// The server page's background from the last run (used for the launch cover), else the default.
    static var lastBackground: UIColor {
        get {
            guard let a = UserDefaults.standard.array(forKey: "kirocrew.lastBackground") as? [Double], a.count == 3 else { return defaultBackground }
            return UIColor(red: a[0], green: a[1], blue: a[2], alpha: 1)
        }
        set {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, al: CGFloat = 0
            guard newValue.getRed(&r, green: &g, blue: &b, alpha: &al) else { return }
            UserDefaults.standard.set([Double(r), Double(g), Double(b)], forKey: "kirocrew.lastBackground")
        }
    }

    static func luminance(_ c: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getRed(&r, green: &g, blue: &b, alpha: &a) else {
            var w: CGFloat = 0
            return c.getWhite(&w, alpha: &a) ? w : 0
        }
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
    static func isDark(_ c: UIColor) -> Bool { luminance(c) < 0.5 }

    /// Parses the CSS colour strings getComputedStyle returns: "rgb(r, g, b)" / "rgba(r, g, b, a)".
    /// Anything else (or a transparent colour) returns nil. Input is untrusted page data.
    static func parseCSSColor(_ s: String) -> UIColor? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.count <= 64, t.hasPrefix("rgb"), let open = t.firstIndex(of: "("), let close = t.lastIndex(of: ")"),
              open < close else { return nil }
        let parts = t[t.index(after: open)..<close]
            .replacingOccurrences(of: "/", with: ",")
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .compactMap { Double($0) }
        guard parts.count >= 3, parts[0...2].allSatisfy({ (0...255).contains($0) }) else { return nil }
        let alpha = parts.count >= 4 ? parts[3] : 1
        guard alpha > 0.5 else { return nil }
        return UIColor(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: 1)
    }
}

// MARK: - Launch cover

/// Same colour as the page, with the app logo and a spinner. Hides the white/blank flash
/// between launch and the web app's first paint.
final class CoverView: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let logo = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.defaultBackground
        logo.image = UIImage(named: "Logo") ?? UIImage(systemName: "bubble.left.and.bubble.right.fill")
        logo.contentMode = .scaleAspectFit
        logo.layer.cornerRadius = 18
        logo.layer.cornerCurve = .continuous
        logo.clipsToBounds = true
        logo.tintColor = .white
        spinner.color = .lightGray
        spinner.startAnimating()
        let stack = UIStackView(arrangedSubviews: [logo, spinner])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 80), logo.heightAnchor.constraint(equalToConstant: 80),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "Loading Kiro Crew"
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(background: UIColor) {
        backgroundColor = background
        spinner.color = Theme.isDark(background) ? .lightGray : .darkGray
    }
}

// MARK: - Error screen

final class ErrorView: UIView {
    var onRetry: () -> Void = {}
    var onSettings: () -> Void = {}
    private var content: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(message: String, detail: String) {
        content?.removeFromSuperview()
        let v: UIView
        if #available(iOS 17.0, *) {
            var cfg = UIContentUnavailableConfiguration.empty()
            cfg.image = UIImage(systemName: "wifi.exclamationmark")
            cfg.text = "Could not load"
            cfg.secondaryText = message + (detail.isEmpty ? "" : "\n\n" + detail)
            var retry = UIButton.Configuration.filled()
            retry.title = "Retry"
            cfg.button = retry
            cfg.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.onRetry() }
            var settings = UIButton.Configuration.plain()
            settings.title = "Server Settings"
            cfg.secondaryButton = settings
            cfg.secondaryButtonProperties.primaryAction = UIAction { [weak self] _ in self?.onSettings() }
            v = UIContentUnavailableView(configuration: cfg)
        } else {
            v = legacyContent(message: message, detail: detail)
        }
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            v.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            v.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
        ])
        content = v
        UIAccessibility.post(notification: .screenChanged, argument: v)
    }

    private func legacyContent(message: String, detail: String) -> UIView {
        let img = UIImageView(image: UIImage(systemName: "wifi.exclamationmark"))
        img.tintColor = .secondaryLabel
        img.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44)
        let title = UILabel()
        title.text = "Could not load"; title.font = .preferredFont(forTextStyle: .title2); title.adjustsFontForContentSizeCategory = true
        let body = UILabel()
        body.text = message + (detail.isEmpty ? "" : "\n\n" + detail)
        body.numberOfLines = 0; body.textAlignment = .center; body.textColor = .secondaryLabel
        body.font = .preferredFont(forTextStyle: .body); body.adjustsFontForContentSizeCategory = true
        let retry = UIButton(type: .system)
        retry.setTitle("Retry", for: .normal)
        retry.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        retry.addAction(UIAction { [weak self] _ in self?.onRetry() }, for: .touchUpInside)
        let settings = UIButton(type: .system)
        settings.setTitle("Server Settings", for: .normal)
        settings.addAction(UIAction { [weak self] _ in self?.onSettings() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [img, title, body, retry, settings])
        stack.axis = .vertical; stack.alignment = .center; stack.spacing = 14
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 32, bottom: 0, trailing: 32)
        let wrap = UIView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: wrap.leadingAnchor), stack.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
        ])
        return wrap
    }
}

// MARK: - Privacy shield / app lock

enum AppPrefs {
    private static let lockKey = "kirocrew.appLock"
    private static let gateKey = "kirocrew.deviceTokenFaceID"
    private static let linksKey = "kirocrew.linksInDefaultBrowser"
    /// Links to other sites: false = in-app browser (Safari sheet, default), true = the user's
    /// default browser (UIApplication.open). Sign-in hosts always stay in the web view.
    static var linksInDefaultBrowser: Bool {
        get { UserDefaults.standard.bool(forKey: linksKey) }
        set { UserDefaults.standard.set(newValue, forKey: linksKey) }
    }
    /// Face ID / passcode can be used on this phone (a passcode is set).
    static var deviceOwnerAuthAvailable: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) }
    /// Ask for Face ID / passcode when the app comes back from the background.
    static var appLock: Bool {
        get { UserDefaults.standard.bool(forKey: lockKey) }
        set { UserDefaults.standard.set(newValue, forKey: lockKey) }
    }
    /// Protect the device sign-in (refresh token) Keychain item with Face ID / passcode. Default ON.
    static var gateDeviceToken: Bool {
        get { UserDefaults.standard.object(forKey: gateKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: gateKey) }
    }
}

final class PrivacyShield: UIView {
    var onUnlock: () -> Void = {}
    private let unlock = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        blur.frame = bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(blur)
        let logo = UIImageView(image: UIImage(systemName: "lock.fill"))
        logo.tintColor = .secondaryLabel
        logo.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40)
        unlock.setTitle("Unlock Kiro Crew", for: .normal)
        unlock.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        unlock.addAction(UIAction { [weak self] _ in self?.onUnlock() }, for: .touchUpInside)
        unlock.isHidden = true
        let stack = UIStackView(arrangedSubviews: [logo, unlock])
        stack.axis = .vertical; stack.alignment = .center; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func setLocked(_ locked: Bool) { unlock.isHidden = !locked }
}
