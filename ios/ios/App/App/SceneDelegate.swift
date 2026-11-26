import UIKit
import Capacitor

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        window?.backgroundColor = Theme.defaultBackground
        window?.rootViewController = NativeShellController()
        window?.makeKeyAndVisible()

        // Cold start from a kirocrew:// link or a Home Screen quick action.
        if let u = connectionOptions.urlContexts.first?.url, let p = DeepLink.path(from: u) { DeepLink.open(p) }
        if let item = connectionOptions.shortcutItem, let p = DeepLink.path(forShortcut: item.type) { DeepLink.open(p) }

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let u = URLContexts.first?.url, let p = DeepLink.path(from: u) { DeepLink.open(p); return }
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        guard let p = DeepLink.path(forShortcut: shortcutItem.type) else { completionHandler(false); return }
        DeepLink.open(p)
        completionHandler(true)
    }
}
