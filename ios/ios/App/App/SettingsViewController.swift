import UIKit
import UniformTypeIdentifiers

// ---------------------------------------------------------------------------
// Native settings screens (··· menu > Server Settings, the sign-in card, the error screen,
// or a two-finger hold):
//  - ServerListViewController: pick the active server, add / edit / delete, reconnect,
//    app lock (Face ID), device sign-in protection, notifications, where links open.
//  - ServerEditViewController: name, external + internal URL, sign-in hosts, home Wi-Fi names,
//    trusted server certificates, CA import, client certificate (.p12) import, device pairing.
// ---------------------------------------------------------------------------

private func showAlert(_ vc: UIViewController, _ title: String, _ message: String?) {
    let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
    a.addAction(UIAlertAction(title: "OK", style: .default))
    vc.present(a, animated: true)
}

final class ServerListViewController: UITableViewController {
    var status: () -> String = { "" }
    var onChange: () -> Void = {}
    var onReconnect: () -> Void = {}
    private let store = ServerStore.shared

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Servers"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(add))
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshNotifyStatus()
        }
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); tableView.reloadData(); refreshNotifyStatus() }

    // MARK: Notifications (the only place besides the web app's own settings that asks iOS)

    private var notifyStatus = "default"

    private func refreshNotifyStatus() {
        LocalNotifications.status { [weak self] s in
            guard let self, s != self.notifyStatus else { return }
            let changed = self.isViewLoaded && self.view.window != nil && self.notifyStatus != "default"
            self.notifyStatus = s
            self.tableView.reloadSections(IndexSet(integer: 3), with: .none)
            if changed { NativeShellController.current?.notificationPermissionChanged(s) }
        }
    }

    private func notificationsTapped() {
        guard notifyStatus == "default" else {
            // Already decided: iOS only lets the user change it in the Settings app.
            let url = URL(string: {
                if #available(iOS 16.0, *) { return UIApplication.openNotificationSettingsURLString }
                return UIApplication.openSettingsURLString
            }())
            if let url { UIApplication.shared.open(url) }
            return
        }
        LocalNotifications.request { [weak self] s in
            self?.notifyStatus = s
            self?.tableView.reloadSections(IndexSet(integer: 3), with: .none)
            NativeShellController.current?.notificationPermissionChanged(s)
        }
    }

    @objc private func close() { dismiss(animated: true) }
    @objc private func add() { edit(ServerConfig(), isNew: true) }

    func edit(_ s: ServerConfig, isNew: Bool, animated: Bool = true) {
        let e = ServerEditViewController(server: s, isNew: isNew)
        e.onSave = { [weak self] in self?.onChange() }
        navigationController?.pushViewController(e, animated: animated)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 5 }
    override func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int { [store.servers.count, 1, 2, 1, 2][s] }
    override func tableView(_ tv: UITableView, titleForHeaderInSection s: Int) -> String? {
        ["Servers", "Connection", "Privacy", "Notifications", "Open Links In"][s]
    }
    override func tableView(_ tv: UITableView, titleForFooterInSection s: Int) -> String? {
        switch s {
        case 0: return "Tap a server to open it. Tap ⓘ to edit it. Swipe left to delete."
        case 1: return status()
        case 3: return "Alerts for new messages and approvals while Kiro Crew is open (also as banners while you use it), "
            + "and the unread count on the app icon. Kiro Crew asks only when you turn this on here or in the web app's settings."
        case 4: return "Links to other websites. The default browser is the one you chose in iOS Settings. "
            + "Your server's own pages and its sign-in pages always stay in Kiro Crew."
        default:
            guard AppPrefs.deviceOwnerAuthAvailable else { return "Set a passcode on this iPhone to protect device sign-in." }
            return "App lock asks for Face ID or the passcode when Kiro Crew comes back from the background. "
                + "Device sign-in protection asks once per app launch before this phone signs in by itself "
                + "(applies from the next sign-in refresh)."
        }
    }

    private func switchCell(_ text: String, on: Bool, enabled: Bool = true, _ changed: @escaping (Bool) -> Void) -> UITableViewCell {
        let c = UITableViewCell(style: .default, reuseIdentifier: nil)
        c.textLabel?.text = text
        c.textLabel?.numberOfLines = 0
        c.textLabel?.isEnabled = enabled
        c.selectionStyle = .none
        let sw = UISwitch()
        sw.isOn = on && enabled
        sw.isEnabled = enabled
        sw.addAction(UIAction { [weak sw] _ in changed(sw?.isOn ?? false) }, for: .valueChanged)
        c.accessoryView = sw
        return c
    }

    override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        if ip.section == 3 {
            let c = UITableViewCell(style: .value1, reuseIdentifier: nil)
            c.textLabel?.text = "Notifications"
            c.detailTextLabel?.text = ["granted": "On", "denied": "Off"][notifyStatus] ?? "Not set up"
            c.accessoryType = .disclosureIndicator
            return c
        }
        if ip.section == 4 {
            let c = UITableViewCell(style: .default, reuseIdentifier: nil)
            let def = ip.row == 1
            c.textLabel?.text = def ? "Default Browser" : "In-App Browser"
            c.accessoryType = AppPrefs.linksInDefaultBrowser == def ? .checkmark : .none
            c.accessibilityIdentifier = def ? "links-default-browser" : "links-in-app"
            return c
        }
        if ip.section == 2 {
            // Without a passcode iOS cannot protect anything with Face ID: off and disabled.
            let can = AppPrefs.deviceOwnerAuthAvailable
            return ip.row == 0
                ? switchCell("Lock with Face ID", on: AppPrefs.appLock, enabled: can) { AppPrefs.appLock = $0 }
                : switchCell("Face ID for device sign-in", on: AppPrefs.gateDeviceToken, enabled: can) { AppPrefs.gateDeviceToken = $0 }
        }
        let c = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard ip.section == 0 else {
            c.textLabel?.text = "Reconnect now"
            c.textLabel?.textColor = .systemBlue
            return c
        }
        let s = store.servers[ip.row]
        c.textLabel?.text = s.displayName
        c.detailTextLabel?.text = [s.externalURL.map { "External: \($0.absoluteString)" },
                                   s.internalURL.map { "Internal: \($0.absoluteString)" },
                                   DeviceAuth.isPaired(serverID: s.id) ? "Paired" : "Not paired"].compactMap { $0 }.joined(separator: "\n")
        c.detailTextLabel?.numberOfLines = 0
        c.detailTextLabel?.textColor = .secondaryLabel
        c.imageView?.image = UIImage(systemName: s.id == store.active?.id ? "checkmark.circle.fill" : "circle")
        c.accessoryType = .detailButton
        return c
    }

    override func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
        tv.deselectRow(at: ip, animated: true)
        if ip.section == 3 { notificationsTapped(); return }
        if ip.section == 4 {
            AppPrefs.linksInDefaultBrowser = ip.row == 1
            tv.reloadSections(IndexSet(integer: 4), with: .none)
            return
        }
        guard ip.section < 2 else { return }
        if ip.section == 0 { store.setActive(id: store.servers[ip.row].id); onChange() } else { onReconnect() }
        dismiss(animated: true)
    }

    override func tableView(_ tv: UITableView, accessoryButtonTappedForRowWith ip: IndexPath) {
        edit(store.servers[ip.row], isNew: false)
    }

    override func tableView(_ tv: UITableView, canEditRowAt ip: IndexPath) -> Bool { ip.section == 0 }

    override func tableView(_ tv: UITableView, commit style: UITableViewCell.EditingStyle, forRowAt ip: IndexPath) {
        guard style == .delete else { return }
        let s = store.servers[ip.row]
        let a = UIAlertController(title: "Delete \(s.displayName)?",
                                  message: "Its settings, trusted certificates, client certificate and device sign-in are removed from this phone.",
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.store.remove(id: s.id); self?.tableView.reloadData(); self?.onChange()
        })
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(a, animated: true)
    }
}

final class ServerEditViewController: UITableViewController, UIDocumentPickerDelegate {
    var onSave: () -> Void = {}
    private var server: ServerConfig
    private let isNew: Bool
    private var saved = false
    private let store = ServerStore.shared
    private let trust = TrustStore.shared
    private let conn = ConnectionManager.shared
    private var ssidNote = ""
    private enum Pick { case ca, p12 }
    private var picking: Pick?

    private lazy var nameField = makeField("e.g. Home or Work", server.name, .default)
    private lazy var externalField = makeField(serverURLPlaceholder, server.externalURL?.absoluteString, .URL)
    private lazy var internalField = makeField(lanURLPlaceholder, server.internalURL?.absoluteString, .URL)
    private lazy var ssidField = makeField("Wi-Fi names, comma separated", server.homeSSIDs.joined(separator: ", "), .default)
    private lazy var signInField = makeField("e.g. login.example.com", server.signInHosts.joined(separator: ", "), .URL)
    private enum DeviceState { case checking, unsupported, available }
    private var deviceState = DeviceState.checking

    init(server: ServerConfig, isNew: Bool) {
        self.server = server; self.isNew = isNew
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isNew ? "Add Server" : "Edit Server"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(save))
        if !isNew { checkDeviceSignIn() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // A new server that was never saved must not leave certificates behind in the Keychain.
        let leaving = isMovingFromParent || navigationController?.isBeingDismissed == true
        if leaving && isNew && !saved { trust.removeAll(serverID: server.id) }
    }

    private func makeField(_ placeholder: String, _ text: String?, _ kb: UIKeyboardType) -> UITextField {
        let f = UITextField()
        f.placeholder = placeholder; f.text = text; f.keyboardType = kb
        f.autocapitalizationType = .none; f.autocorrectionType = .no; f.clearButtonMode = .whileEditing
        f.font = .preferredFont(forTextStyle: .body); f.adjustsFontForContentSizeCategory = true
        return f
    }

    private func fieldCell(_ label: String, _ f: UITextField) -> UITableViewCell {
        let c = UITableViewCell(style: .default, reuseIdentifier: nil)
        c.selectionStyle = .none
        let l = UILabel()
        l.text = label; l.font = .preferredFont(forTextStyle: .body)
        let stack = UIStackView(arrangedSubviews: [l, f])
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        c.contentView.addSubview(stack)
        let g = c.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: g.leadingAnchor), stack.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            stack.topAnchor.constraint(equalTo: g.topAnchor), stack.bottomAnchor.constraint(equalTo: g.bottomAnchor),
            l.widthAnchor.constraint(equalToConstant: 76),
        ])
        return c
    }

    private func actionCell(_ text: String, detail: String? = nil, destructive: Bool = false) -> UITableViewCell {
        let c = UITableViewCell(style: .value1, reuseIdentifier: nil)
        c.textLabel?.text = text
        c.textLabel?.textColor = destructive ? .systemRed : .systemBlue
        c.textLabel?.numberOfLines = 0
        c.detailTextLabel?.text = detail
        return c
    }

    // MARK: Table

    override func numberOfSections(in tableView: UITableView) -> Int { 4 }
    override func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int { [4, 2, 3, deviceRows][s] }
    override func tableView(_ tv: UITableView, titleForHeaderInSection s: Int) -> String? {
        s == 3 ? (deviceRows > 0 ? "Device sign-in" : nil) : ["Server", "Home network", "Certificates"][s]
    }

    // MARK: Device sign-in (shown only when the server offers it, or this phone is already paired)

    private var paired: Bool { !isNew && DeviceAuth.isPaired(serverID: server.id) }
    private var deviceRows: Int {
        if isNew { return 0 }
        if paired { return 2 }
        return deviceState == .available ? 1 : 0
    }

    private func checkDeviceSignIn() {
        let s = server
        conn.resolve(s) { [weak self] origin, _ in
            guard let origin else { self?.deviceState = .unsupported; return }
            Task { @MainActor [weak self] in
                let m = await DeviceAuth.shared.metadata(origin: origin, server: s)
                self?.deviceState = m == nil ? .unsupported : .available
                self?.tableView.reloadData()
            }
        }
    }

    private func pairDevice() {
        guard let s = store.server(id: server.id) else { return }
        let p = PairingViewController(server: s)
        p.onPaired = { [weak self] in
            self?.tableView.reloadData()
            // Close every settings sheet and show the page, signed in.
            NativeShellController.current?.paired(serverID: s.id)
        }
        present(UINavigationController(rootViewController: p), animated: true)
    }

    private func unpairDevice(_ cell: UITableViewCell?) {
        let a = UIAlertController(title: "Unpair this phone?",
                                  message: "The server forgets this phone, and its sign-in cookies are removed from the app. "
                                      + "You can sign in on the page or pair again.",
                                  preferredStyle: .actionSheet)
        a.addAction(UIAlertAction(title: "Unpair", style: .destructive) { [weak self] _ in
            guard let self else { return }
            let s = self.server
            Task { @MainActor [weak self] in
                await DeviceAuth.shared.unpair(server: s, origin: nil)
                self?.tableView.reloadData()
            }
        })
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.popoverPresentationController?.sourceView = cell ?? view
        a.popoverPresentationController?.sourceRect = cell?.bounds ?? view.bounds
        present(a, animated: true)
    }
    override func tableView(_ tv: UITableView, titleForFooterInSection s: Int) -> String? {
        switch s {
        case 0: return "External: used anywhere (tunnel or public address). Internal: used on your home network. "
            + "Fill one or both. https:// is required; http:// only for a home-network address (192.168.x.x, 10.x.x.x, name.local). "
            + "Sign-in hosts: your server's sign-in provider, if it uses one (comma separated); links to them stay in the app."
        case 1: return "When you are on one of these Wi-Fi networks the internal URL is used. Without names, the internal URL is used "
            + "whenever it answers (2.5 s check), otherwise the external one. For an http:// internal URL, names keep the app from "
            + "sending your session to a look-alike address on someone else's network. Reading the Wi-Fi name needs location "
            + "permission and the Access Wi-Fi Information capability (paid Apple Developer account). \(ssidNote)"
        case 2: return "Kept in the Keychain on this phone only, and used only for this server's own addresses. A server "
            + "certificate that iOS does not trust is accepted only after you tap Trust on the prompt that shows its fingerprint. "
            + "Changes here apply right away."
        default:
            guard deviceRows > 0 else { return nil }
            let grant = DeviceAuth.pairedGrant(serverID: server.id).map { "\n\nGrant ID: \($0)" } ?? ""
            return paired
                ? "This phone signs in by itself. The sign-in is kept in the Keychain (this phone only) and can be removed "
                    + "here or from the server's device list (Settings › Security › Devices)." + grant
                : "Pair once and this phone signs in by itself, on both the internal and the external URL. "
                    + "You approve it on a computer where you are signed in."
        }
    }

    override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        switch (ip.section, ip.row) {
        case (0, 0): return fieldCell("Name", nameField)
        case (0, 1): return fieldCell("External", externalField)
        case (0, 2): return fieldCell("Internal", internalField)
        case (0, 3): return fieldCell("Sign-in", signInField)
        case (3, 0):
            if paired {
                let c = actionCell("Paired", detail: DeviceAuth.pairedName(serverID: server.id).map { "as “\($0)”" })
                c.textLabel?.textColor = .label
                c.selectionStyle = .none
                return c
            }
            return actionCell("Pair this phone…")
        case (3, _): return actionCell("Unpair", destructive: true)
        case (1, 0): return fieldCell("Wi-Fi", ssidField)
        case (1, _): return actionCell("Add current Wi-Fi name")
        case (2, 0):
            let n = trust.pinnedEndpoints(serverID: server.id).count
            return actionCell("Trusted server certificates", detail: "\(n)")
        case (2, 1):
            if let ca = trust.caCertificate(serverID: server.id) { return actionCell("CA certificate", detail: TrustStore.summary(ca)) }
            return actionCell("Import CA certificate…")
        default:
            if let name = server.clientCertName, trust.identity(serverID: server.id) != nil {
                return actionCell("Client certificate", detail: name)
            }
            return actionCell("Import client certificate (.p12)…")
        }
    }

    override func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
        tv.deselectRow(at: ip, animated: true)
        switch (ip.section, ip.row) {
        case (1, 1): addCurrentSSID()
        case (3, 0): if !paired { pairDevice() }
        case (3, 1): unpairDevice(tv.cellForRow(at: ip))
        case (2, 0): managePins()
        case (2, 1):
            if trust.caCertificate(serverID: server.id) == nil { pick(.ca) } else {
                replaceOrRemove("CA certificate", cell: tv.cellForRow(at: ip), replace: { self.pick(.ca) },
                                remove: { self.trust.removeCA(serverID: self.server.id) })
            }
        case (2, 2):
            if trust.identity(serverID: server.id) == nil { pick(.p12) } else {
                replaceOrRemove("Client certificate", cell: tv.cellForRow(at: ip), replace: { self.pick(.p12) },
                                remove: { self.trust.removeIdentity(serverID: self.server.id); self.server.clientCertName = nil; self.persistCertName() })
            }
        default: break
        }
    }

    // MARK: Actions

    @objc private func save() {
        view.endEditing(true)
        func parse(_ f: UITextField) -> URL?? {   // nil = invalid, .some(nil) = empty
            let raw = (f.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { return .some(nil) }
            guard let u = URL(string: raw), isAllowedServer(u) else { return nil }
            return .some(u)
        }
        guard let ext = parse(externalField), let int = parse(internalField) else {
            showAlert(self, "Check the URLs", "Each URL must start with https:// (http:// only for a home-network address like 192.168.x.x or name.local).")
            return
        }
        guard ext != nil || int != nil else { showAlert(self, "Add a URL", "Enter an external URL, an internal URL, or both."); return }
        server.name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        server.externalURL = ext
        server.internalURL = int
        server.homeSSIDs = (ssidField.text ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let rawHosts = (signInField.text ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
        let hosts = rawHosts.compactMap(normalizedHost)
        guard hosts.count == rawHosts.count else {
            showAlert(self, "Check the sign-in hosts", "Enter host names only, like login.example.com, separated by commas.")
            return
        }
        server.signInHosts = Array(Set(hosts)).sorted()
        store.upsert(server)
        if isNew { store.setActive(id: server.id) }
        saved = true
        if !server.homeSSIDs.isEmpty { conn.requestLocationIfNeeded {} }
        onSave()
        navigationController?.popViewController(animated: true)
    }

    private func addCurrentSSID() {
        conn.requestLocationIfNeeded { [weak self] in
            self?.conn.currentSSID { ssid in
                guard let self else { return }
                if let ssid {
                    var names = (self.ssidField.text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if !names.contains(ssid) { names.append(ssid) }
                    self.ssidField.text = names.joined(separator: ", ")
                    self.ssidNote = "Current Wi-Fi: \(ssid)."
                } else {
                    self.ssidNote = "Could not read the Wi-Fi name (\(self.conn.locationStatusText); not on Wi-Fi, or the app lacks the "
                        + "Access Wi-Fi Information capability). You can type the name, but it can only be checked when the app can read it."
                }
                self.tableView.reloadSections([1], with: .none)
            }
        }
    }

    private func managePins() {
        let list = trust.pinnedEndpoints(serverID: server.id)
        guard !list.isEmpty else {
            showAlert(self, "No trusted certificates", "When this server shows a certificate iOS does not trust, the app asks you before trusting it.")
            return
        }
        let a = UIAlertController(title: "Trusted server certificates", message: list.joined(separator: "\n")
                                  + "\n\nAfter removing, the app asks again the next time it connects (restart the app to drop open connections).",
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Remove All", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.trust.removePins(serverID: self.server.id); self.tableView.reloadData()
        })
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(a, animated: true)
    }

    private func replaceOrRemove(_ what: String, cell: UITableViewCell?, replace: @escaping () -> Void, remove: @escaping () -> Void) {
        let a = UIAlertController(title: what, message: nil, preferredStyle: .actionSheet)
        a.addAction(UIAlertAction(title: "Replace…", style: .default) { _ in replace() })
        a.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in remove(); self?.tableView.reloadData() })
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.popoverPresentationController?.sourceView = cell ?? view
        a.popoverPresentationController?.sourceRect = cell?.bounds ?? view.bounds
        present(a, animated: true)
    }

    /// For an existing server, keep the client certificate name in sync right away (the identity is already in the Keychain).
    private func persistCertName() {
        guard !isNew, var stored = store.server(id: server.id) else { return }
        stored.clientCertName = server.clientCertName
        store.upsert(stored)
    }

    // MARK: File import

    private func pick(_ p: Pick) {
        picking = p
        let ext: [String] = p == .p12 ? ["p12", "pfx"] : ["cer", "crt", "der", "pem"]
        let types = (p == .p12 ? [UTType.pkcs12] : [UTType.x509Certificate]) + ext.compactMap { UTType(filenameExtension: $0) }
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        vc.delegate = self
        present(vc, animated: true)
    }

    func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let p = picking else { return }
        let data = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)   // our temporary copy: don't leave key material on disk
        guard let data else { showAlert(self, "Could not read the file", nil); return }
        switch p {
        case .ca:
            do {
                let name = try trust.importCA(data, serverID: server.id)
                let fp = trust.caCertificate(serverID: server.id).map(TrustStore.sha256) ?? ""
                tableView.reloadData()
                showAlert(self, "CA certificate imported", "\(name)\n\nSHA-256:\n\(fp)\n\nIt is trusted only for this server's addresses.")
            } catch { showAlert(self, "Import failed", error.localizedDescription) }
        case .p12:
            let a = UIAlertController(title: "Certificate password", message: "Enter the password of the .p12 file.", preferredStyle: .alert)
            a.addTextField { $0.isSecureTextEntry = true; $0.placeholder = "Password" }
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            a.addAction(UIAlertAction(title: "Import", style: .default) { [weak self, weak a] _ in
                guard let self else { return }
                do {
                    let name = try self.trust.importClientP12(data, password: a?.textFields?.first?.text ?? "", serverID: self.server.id)
                    self.server.clientCertName = name
                    self.persistCertName()
                    self.tableView.reloadData()
                    showAlert(self, "Client certificate imported", "\(name)\n\nSent only to this server's addresses when they ask for it.")
                } catch { showAlert(self, "Import failed", error.localizedDescription) }
            })
            present(a, animated: true)
        }
    }
}
