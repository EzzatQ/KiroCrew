import UIKit
import AVFoundation
import VisionKit

// ---------------------------------------------------------------------------
// Signing in from the phone (shown instead of the web app's error page when the active
// server answers GET /api/auth/me with 401/403):
//  - SignInCardView: "Sign in to Kiro Crew" · <server host> · Scan QR code · Pair this phone
//    (only if the server offers device pairing) · Paste sign-in link.
//  - QRScannerViewController: VisionKit DataScannerViewController where available,
//    AVCaptureMetadataOutput otherwise. Reads the dashboard's "Sign in with mobile" QR code.
//  - SignInLink.check: a scanned / pasted link is used only if its origin is one of the
//    active server's configured URLs (another address can be added after the user confirms).
// Links are credentials: never logged, never stored.
// ---------------------------------------------------------------------------

enum SignInLink {
    enum Result { case ours(URL), otherOrigin(URL, origin: URL), invalid }

    static func check(_ raw: String, server: ServerConfig) -> Result {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 4096, !t.contains(where: { $0.isWhitespace }), let u = URL(string: t), isAllowedServer(u),
              u.user == nil, u.password == nil, let o = originString(u), let origin = URL(string: o) else { return .invalid }
        if server.urls.contains(where: { sameOrigin($0, u) }) { return .ours(u) }
        return .otherOrigin(u, origin: origin)
    }
}

// MARK: - Sign-in card

final class SignInCardView: UIView {
    var onScan: () -> Void = {}
    var onPair: () -> Void = {}
    var onPaste: () -> Void = {}
    var onSignInAgain: () -> Void = {}
    var onShowPage: () -> Void = {}
    var onSettings: () -> Void = {}

    private let subtitle = UILabel()
    private let scan = UIButton(type: .system)
    private let pair = UIButton(type: .system)
    private let paste = UIButton(type: .system)
    private let again = UIButton(type: .system)
    private let hint = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemGroupedBackground
        accessibilityViewIsModal = true

        let logo = UIImageView(image: UIImage(named: "Logo") ?? UIImage(systemName: "bubble.left.and.bubble.right.fill"))
        logo.contentMode = .scaleAspectFit
        logo.layer.cornerRadius = 16; logo.layer.cornerCurve = .continuous; logo.clipsToBounds = true
        let title = UILabel()
        title.text = "Sign in to Kiro Crew"
        title.font = .preferredFont(forTextStyle: .title1).withTraits(.traitBold)
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center; title.numberOfLines = 0
        title.accessibilityTraits = .header
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.adjustsFontForContentSizeCategory = true
        subtitle.textColor = .secondaryLabel
        subtitle.textAlignment = .center; subtitle.numberOfLines = 0

        style(again, "Sign In Again", "iphone.badge.checkmark", filled: true, id: "signin-again") { [weak self] in self?.onSignInAgain() }
        style(scan, "Scan QR Code", "qrcode.viewfinder", filled: true, id: "signin-scan") { [weak self] in self?.onScan() }
        style(pair, "Pair This Phone", "iphone.badge.checkmark", filled: false, id: "signin-pair") { [weak self] in self?.onPair() }
        style(paste, "Paste Sign-in Link", "doc.on.clipboard", filled: false, id: "signin-paste") { [weak self] in self?.onPaste() }

        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.adjustsFontForContentSizeCategory = true
        hint.textColor = .secondaryLabel
        hint.textAlignment = .center; hint.numberOfLines = 0
        hint.text = "On a computer signed in to Kiro Crew, open Settings › Connect your phone and scan its sign-in QR code."

        let showPage = UIButton(type: .system)
        showPage.setTitle("Use the Server's Sign-in Page", for: .normal)
        showPage.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        showPage.titleLabel?.adjustsFontForContentSizeCategory = true
        showPage.accessibilityIdentifier = "signin-show-page"
        showPage.addAction(UIAction { [weak self] _ in self?.onShowPage() }, for: .touchUpInside)
        let settings = UIButton(type: .system)
        settings.setTitle("Server Settings", for: .normal)
        settings.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        settings.titleLabel?.adjustsFontForContentSizeCategory = true
        settings.addAction(UIAction { [weak self] _ in self?.onSettings() }, for: .touchUpInside)
        let links = UIStackView(arrangedSubviews: [showPage, settings])
        links.axis = .vertical; links.spacing = 2

        let buttons = UIStackView(arrangedSubviews: [again, scan, pair, paste])
        buttons.axis = .vertical; buttons.spacing = 12
        let stack = UIStackView(arrangedSubviews: [logo, title, subtitle, buttons, hint, links])
        stack.axis = .vertical; stack.alignment = .fill; stack.spacing = 14
        stack.setCustomSpacing(28, after: subtitle)
        stack.setCustomSpacing(20, after: buttons)
        stack.setCustomSpacing(20, after: hint)

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        let g = scroll.contentLayoutGuide, f = scroll.frameLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: g.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: g.bottomAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: f.centerYAnchor).withPriority(.defaultLow),
            stack.leadingAnchor.constraint(equalTo: f.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: f.trailingAnchor, constant: -32),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            g.heightAnchor.constraint(greaterThanOrEqualTo: f.heightAnchor),
            logo.heightAnchor.constraint(equalToConstant: 72),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private static func config(_ title: String, _ symbol: String, filled: Bool) -> UIButton.Configuration {
        var cfg: UIButton.Configuration = filled ? .filled() : .tinted()
        cfg.title = title
        cfg.image = UIImage(systemName: symbol)
        cfg.imagePadding = 8
        cfg.cornerStyle = .large
        cfg.buttonSize = .large
        return cfg
    }

    private func style(_ b: UIButton, _ title: String, _ symbol: String, filled: Bool, id: String, _ action: @escaping () -> Void) {
        b.configuration = Self.config(title, symbol, filled: filled)
        b.accessibilityIdentifier = id
        b.addAction(UIAction { _ in Haptics.play("light"); action() }, for: .touchUpInside)
    }

    /// `paired`: this phone is paired but signed out here (kept its pairing): "Sign In Again" first.
    func configure(host: String, canPair: Bool, paired: Bool) {
        subtitle.text = host   // plain text
        again.isHidden = !paired
        pair.isHidden = !canPair || paired
        scan.configuration = Self.config("Scan QR Code", "qrcode.viewfinder", filled: !paired)
    }
}

private extension UIFont {
    func withTraits(_ t: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let d = fontDescriptor.withSymbolicTraits(t) else { return self }
        return UIFont(descriptor: d, size: 0)
    }
}

extension NSLayoutConstraint {
    func withPriority(_ p: UILayoutPriority) -> NSLayoutConstraint { priority = p; return self }
}

// MARK: - "Signed out — Pair again" banner

final class SignedOutBanner: UIControl {
    var onTap: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemOrange
        let icon = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
        icon.tintColor = .black
        let label = UILabel()
        label.text = "Signed out — Pair again"
        label.font = .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .black
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = .black
        let stack = UIStackView(arrangedSubviews: [icon, label, chevron])
        stack.spacing = 8; stack.alignment = .center
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
        ])
        addAction(UIAction { [weak self] _ in self?.onTap() }, for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityLabel = "Signed out. Pair again"
        accessibilityTraits = .button
        accessibilityIdentifier = "signed-out-banner"
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.7 : 1 } }
}

// MARK: - QR scanner

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: (String) -> Void = { _ in }
    var onPaste: () -> Void = {}
    private var session: AVCaptureSession?
    private var preview: AVCaptureVideoPreviewLayer?
    private var dataScanner: UIViewController?
    private var done = false
    private let message = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Scan QR Code"
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Paste Link", style: .plain, target: self, action: #selector(pasteLink))

        message.text = "Point the camera at the sign-in QR code on your computer (Kiro Crew › Settings › Connect your phone)."
        message.textColor = .white
        message.numberOfLines = 0
        message.textAlignment = .center
        message.font = .preferredFont(forTextStyle: .callout)
        message.adjustsFontForContentSizeCategory = true
        message.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(message)
        NSLayoutConstraint.activate([
            message.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 8),
            message.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -8),
            message.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard session == nil, dataScanner == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { ok ? self.start() : self.unavailable("Camera access is off. Allow it in Settings › Kiro Crew › Camera, or paste the link instead.") }
            }
        default:
            unavailable("Camera access is off. Allow it in Settings › Kiro Crew › Camera, or paste the link instead.")
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stop()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    private func start() {
        if #available(iOS 16.0, *), DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
            let s = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                              recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                              isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
            s.delegate = DataScannerBridge.shared
            DataScannerBridge.shared.onCode = { [weak self] code in self?.found(code) }
            addChild(s)
            s.view.translatesAutoresizingMaskIntoConstraints = false
            view.insertSubview(s.view, at: 0)
            NSLayoutConstraint.activate([
                s.view.topAnchor.constraint(equalTo: view.topAnchor), s.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                s.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), s.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            s.didMove(toParent: self)
            dataScanner = s
            try? s.startScanning()
            return
        }
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else {
            unavailable("No camera is available here. Paste the sign-in link instead.")
            return
        }
        let s = AVCaptureSession()
        let output = AVCaptureMetadataOutput()
        guard s.canAddInput(input), s.canAddOutput(output) else { unavailable("The camera could not be started."); return }
        s.addInput(input)
        s.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        if output.availableMetadataObjectTypes.contains(.qr) { output.metadataObjectTypes = [.qr] }
        let p = AVCaptureVideoPreviewLayer(session: s)
        p.videoGravity = .resizeAspectFill
        p.frame = view.bounds
        view.layer.insertSublayer(p, at: 0)
        preview = p
        session = s
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }

    private func stop() {
        if let s = session { DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() } }
        if #available(iOS 16.0, *), let d = dataScanner as? DataScannerViewController { d.stopScanning() }
    }

    private func unavailable(_ text: String) {
        message.text = text
        message.font = .preferredFont(forTextStyle: .body)
    }

    func metadataOutput(_ o: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from c: AVCaptureConnection) {
        guard let code = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        found(code)
    }

    private func found(_ code: String) {
        guard !done else { return }
        done = true
        Haptics.play("success")
        stop()
        onCode(code)   // never logged
    }

    @objc private func cancel() { stop(); dismiss(animated: true) }
    @objc private func pasteLink() { stop(); onPaste() }
}

/// DataScannerViewControllerDelegate lives in a separate object so the controller itself can
/// still be used on iOS 15 (where VisionKit's scanner does not exist).
@available(iOS 16.0, *)
private final class DataScannerBridge: NSObject, DataScannerViewControllerDelegate {
    static let shared = DataScannerBridge()
    var onCode: (String) -> Void = { _ in }

    func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
        for item in items {
            if case .barcode(let b) = item, let v = b.payloadStringValue { onCode(v); return }
        }
    }
    func dataScanner(_ s: DataScannerViewController, didTapOn item: RecognizedItem) {
        if case .barcode(let b) = item, let v = b.payloadStringValue { onCode(v) }
    }
}
