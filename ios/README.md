# Kiro Crew for iPhone

A native iOS app for your own Kiro Crew server. It shows the server's web app
inside a native shell (navigation bar, menus, settings) and adds what a browser tab cannot:
saved servers with home/away URLs, certificate pinning, client certificates, device pairing,
Face ID, downloads to Files, quick actions and deep links.

Build instructions: [BUILD-ON-MAC.md](BUILD-ON-MAC.md).

## Features
- **Messages-style navigation (no tab bar):**
  - **Sessions** (home): the web app's own sessions list (the `/embed/sessions` page it serves for IDE
    plugins) with everything it has: folders, sorting, search, filters, unread, older sessions, row menus.
    Bar: **Settings** (gear), **Inbox** (bell, unread badge), **New session** (compose). Below: **Bots** and
    **Apps** (a menu of the web app's pages: Library of installed apps, Discover, Task Runner, Channels,
    Schedule, Artifacts, Webhooks, Customize, Terminal).
  - Tap a session: the chat opens full screen with a slim bar: **‹** back to Sessions, the full session title
    (two lines; tap it for the session menu: rename, pin, export, ...) and one **···** menu (Search, Session
    Tools, Session Options, Reload, Share, Copy Link, Open in Browser, Pair This Phone, Server Settings).
    The composer sits at the bottom; the page shrinks above the keyboard.
  - **Inbox, Bots, Settings** and app pages open the same way with ‹ back; drill-ins inside them (Settings › a
    section, Bots › a bot) go back inside the page first. The docked Terminal closes again when you go back.
    In landscape the bar steps aside while the keyboard is up.
  - On launch the last open session opens, with the Sessions list behind it. Navigation never reloads the page.
  - The web app's own phone chrome (logo menu, bell, sessions toggle and drawer, icon rail, title menu, ⋯) is hidden.
- **Native shell:** status bar and home-indicator area in the page's own colour (follows the web theme).
- **Sign in from the phone:** when the server says you are signed out, a native card replaces its error page:
  **Scan QR Code** (the dashboard's "Sign in with mobile" code; VisionKit scanner, or the camera on older iOS),
  **Pair This Phone** (if the server offers device pairing) and **Paste Sign-in Link**. Only links on one of the
  server's own URLs are opened; a link on another address can be added to the server after you confirm.
  After a QR / link sign-in the phone pairs by itself if the server offers it (one scan: the fresh sign-in
  approves this phone's own pairing request; if the server refuses, the usual code screen shows).
  The web app's own signed-out page opens this card too.
- **Several servers**, each with an **external** URL (anywhere) and an optional **internal** URL (home network).
  The app picks the internal one when it answers (or when you are on one of your home Wi-Fi names) and switches
  on network changes, keeping you on the same page.
- **No reload when you come back** to the app or close a sheet; drafts stay.
- **Launch cover** in the page colour until the web app has painted (no white flash).
- **Error screen** with Retry and Server Settings, showing which URL (internal/external) was tried.
- **Camera, microphone, photos** for attachments and voice messages (asked by iOS on first use).
- **Downloads** open the share sheet (Save to Files, AirDrop, ...).
- **Privacy:** the app content is blurred in the app switcher; optional **Face ID lock** (needs a passcode on the phone).
- **Device pairing** (when the server offers it): approve this phone once from a signed-in computer and it signs
  in by itself afterwards (Cancel on the pairing screen withdraws the request), on both URLs. The pairing screen shows the code (tap to copy), a countdown, a QR code of
  the approval page and the name the phone shows as. If the server signs the phone out, the app says so and offers
  **Pair Again**; "Not Now" leaves a **Signed out — Pair again** banner until it is fixed. Signing out on the page
  asks whether to unpair the phone too (default: keep it paired; sign in again with one tap).
- **Web notifications** become iOS notifications while the app is running, shown as banners in the foreground too.
  iOS asks for permission only when you turn notifications on (web app Settings › Notifications, or Server
  Settings › Notifications in the app), never by itself on launch.
- **Links** to other sites open in the in-app browser, or in your default browser (Server Settings › Open Links In).
- **Deep links** `kirocrew://sessions`, `kirocrew://chat/<session>`, `kirocrew://notifications`, `kirocrew://apps`;
  Home Screen quick actions and Shortcuts/Siri actions (Sessions, New Session, Inbox, Bots); Handoff of the current
  page (external URL only).

## First run
1. Start the app. It asks for your server URL, for example `https://kirocrew.example.com`, or on your home network
   `http://192.168.1.10:5476`.
2. If you are signed out, the app shows **Sign in to Kiro Crew**: scan the sign-in QR code from Kiro Crew on your
   computer (Settings › Connect your phone), paste a sign-in link, or **Pair This Phone** (only if your server
   supports device pairing; also in ··· and in Server Settings › ⓘ next to the server).
3. Optional: in Server Settings add the other URL (internal or external), home Wi-Fi names, your sign-in provider's
   host, a CA certificate or a client certificate.

## Security model
- **Transport.** Only `https://` URLs, except `http://` for private-network addresses (10.x, 172.16-31.x,
  192.168.x, 127.x, `*.local`). There is no global App Transport Security exception.
  On an `http://` home URL your traffic is not encrypted: use it only on a network you trust, and add your home
  Wi-Fi names so the app does not send your session to a look-alike address on another network.
- **Certificates.** Publicly trusted certificates work as usual. For anything else you choose, per server:
  - trust one exact certificate after checking its SHA-256 fingerprint on a prompt (pinned per host:port;
    a changed certificate is flagged and asks again), or
  - import your own CA, used as the only trust anchor for that server's own hosts (host name still checked).
  - Client certificates (.p12) for mTLS are sent only to that server's own hosts.
- **Keychain only.** Pinned certificates, CA, client identity and the device-pairing refresh token are stored in
  the Keychain, this device only (`…ThisDeviceOnly`, not synced, not in backups). Settings in UserDefaults
  contain no secrets. Tokens never appear in URLs or logs.
- **Device pairing** uses the standard OAuth 2.0 Device Authorization Grant (RFC 8628) with rotating refresh
  tokens and revocation (RFC 7009). No custom cryptography. The refresh token can be protected by Face ID /
  passcode (on by default); the server can revoke the phone at any time, and Unpair revokes it from the phone.
  Tokens are only ever sent to the server's own configured URLs, never through redirects.
- **The web page is untrusted input.** Messages from the page are accepted only from the main frame of the
  server origin in use; values are type- and length-checked; labels are shown as plain text; navigation
  requests must be plain in-app paths. Camera and microphone are granted only to the server origin.
  Capacitor's own JavaScript bridge is removed (the app uses no Capacitor plugins).
- **Links.** Tapped links to other sites open in a Safari sheet (SFSafariViewController: separate from the app's
  cookies and bridge), or in your default browser if you choose so. Redirects and form posts (sign-in) stay in the
  app; tapped links to well-known sign-in providers, or to the sign-in hosts you add per server, stay too.
- **Sign-in links and QR codes** are credentials: opened only on the server's own configured URLs (anything else
  needs your explicit confirmation to add that address to the server first), never logged or stored.
- **Sessions screen.** A second web view on the same website data (cookies) shows only the server's
  `/embed/sessions` page; other pages and sites never load there (links go to the main view or the in-app
  browser). Its message handler takes only main-frame messages from the server origin in use, and only "open
  this route" right after a tap; the route is checked and mapped natively. The app stores only the path of the
  last open session.

## Extending sign-in
`SignInHooks.beforeLoad` (DeviceAuth.swift) runs before each server page load and may set cookies in the web
view's cookie store, for an organisation's own single sign-on. Nothing is registered by default.

## Not included (needs a paid Apple Developer account)
- **Notifications while the app is closed (TODO).** Today web notifications are shown only while the app runs
  (foreground banners included). Background delivery needs APNs (paid account, `aps-environment` entitlement,
  device-token registration in the app) **and** server work (an endpoint to register the device token, and the
  server sending pushes through APNs). Nothing of this is implemented yet.
- Widgets / App Groups, and reading the Wi-Fi name (Access Wi-Fi Information).
- Cancelling a pairing code on the server: the server has no endpoint for it; Cancel stops polling and the unused
  code expires by itself.
