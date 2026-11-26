# Build Kiro Crew for iPhone (on a Mac)

Approach: **Capacitor 8, iOS, Swift Package Manager** (no CocoaPods).
The app is a native shell (navigation bar, menus, settings) around your Kiro Crew server's web app.
See [README.md](README.md) for features and the security model.

## What you need
- A Mac with **Xcode 16 or newer** (App Store). Open it once and accept the license.
- **Node 20 or newer** (`brew install node`).
- Your phone and a USB cable (for the phone run).
- An Apple ID. A free one works, but the app stops working after **7 days**. Run it again from Xcode to renew. A paid Developer account lasts 1 year.

## Steps
1. Get this folder (`kirocrew-ios`) onto the Mac. You can skip `node_modules`.
2. In Terminal:
   ```
   cd kirocrew-ios
   npm install
   npx cap sync ios
   npx cap open ios
   ```
   Xcode opens. Wait for "Resolving Package Graph" to finish (needs internet, about 1 minute).
3. **Set your own bundle identifier.** The project ships with `com.amazon.kiro.crew` (the same id as the
   Kiro Crew desktop app), which only the official signing team can register, so personal builds need their own:
   - Xcode: click **App** (blue icon, top left) > target **App** > **Signing & Capabilities** > **Bundle Identifier**,
     for example `com.yourname.kirocrew`.
   - Also set the same value as `appId` in `capacitor.config.json` (then `npx cap sync ios`).
   - Nothing else needs to change: Keychain item names and Home Screen quick actions are derived from the bundle id.
     (Changing it later gives a fresh install: saved servers, trusted certificates and pairings do not carry over.)
4. Same screen: tick **Automatically manage signing**. Pick your **Team**.
   No team? Xcode > Settings > Accounts > **+** > add your Apple ID. Then pick "Your Name (Personal Team)".
5. **Simulator:** pick an iPhone in the top bar. Press **Run** (Cmd+R).
6. **Phone:**
   1. Plug in the phone and tap **Trust**.
   2. On the phone: Settings > Privacy & Security > **Developer Mode** > On. It restarts.
   3. In Xcode, pick your phone in the top bar. Press **Run**.
   4. First launch may say "Untrusted Developer". On the phone: Settings > General > **VPN & Device Management** > your Apple ID > **Trust**.

Command-line builds (no signing), useful for CI:
```
xcodebuild -project ios/App/App.xcodeproj -scheme App -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
xcodebuild -project ios/App/App.xcodeproj -scheme App -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## Using the app
- First launch asks for your server URL, for example `https://kirocrew.example.com` or, on your home network,
  `http://192.168.1.10:5476`. `http://` is accepted only for private-network addresses.
- **Server settings:** ··· menu (top right of any page) > **Server Settings…**, the sign-in card, or a
  two-finger hold for 1 second on a page. Add an internal (home) and an external URL, more servers, sign-in hosts,
  certificates, and device pairing there.
- **Reload:** ··· menu > Reload. **Back:** the ‹ button in the navigation bar, or swipe from the left edge
  (from a chat it always returns to the Sessions list).
- Tapped links to other sites open in a Safari sheet (Done returns to the app). Sign-in redirects stay in the app. Add your sign-in provider's host
  per server if tapped links to it should stay in the app too.
- Downloads open the share sheet (Save to Files, AirDrop, ...).

## Files you may want to edit
- App name: `capacitor.config.json` (`appName`), then `npx cap sync ios`. Also Display Name in Xcode.
- Icon: replace `ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png` (1024x1024 PNG, no transparency)
  and the in-app logo `ios/App/App/Assets.xcassets/Logo.imageset/logo-512.png`.
- Sign-in hosts allowed for every server: `commonSignInHosts` in `ios/App/App/ServerStore.swift`.
- App code: `ios/App/App/` — `NativeShellController.swift` (navigation, sign-in card, lock, deep links),
  `SessionsWebController.swift` (Sessions screen: the web app's sessions list), `WebPageController.swift` (web page
  bar, ··· menu, keyboard), `SignInViewController.swift` (sign-in card, QR scanner), `AppDelegate.swift`
  (web view, navigation rules, certificates), `WebBridge.swift` (page <-> native messages), `DeviceAuth.swift`
  (device pairing), `SettingsViewController.swift`, `ServerStore.swift`, `TrustStore.swift`, `ConnectionManager.swift`.

## Troubleshooting
- **"No such module Capacitor" / package errors:** File > Packages > **Reset Package Caches**, then **Resolve Package Versions**. Check internet.
- **"Signing requires a development team":** do step 4.
- **"Failed to register bundle identifier":** the id is taken. Pick another (step 3).
- **Phone not listed:** unlock it, tap Trust, turn on Developer Mode, try another cable.
- **App stops opening after 7 days:** free Apple ID limit. Press Run again from Xcode.
- **"Could not load":** the server is not reachable from the phone. Retry, or check the URLs in Server Settings
  (the screen shows which URL, internal or external, was used).
- **Changed `capacitor.config.json`:** run `npx cap sync ios` again.

## Not available without a paid Apple Developer account (TODO)
- Push notifications (APNs) while the app is closed (also needs server support). Today, web notifications show only
  while the app is running (as banners in the foreground too).
- Home Screen widgets / App Groups.
- Reading the Wi-Fi name (Access Wi-Fi Information) to pick the internal URL; without it the app checks whether the internal URL answers.
