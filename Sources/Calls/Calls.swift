import Foundation

/// Which app a mic belongs to and whether Kagu asks to record it, shared by Kagu and the KaguWatch helper.
/// Browsers and call apps ask by default; any other app (a terminal, a music app) asks only once the owner
/// turns it on in Settings, where every app that used a mic is listed.
public enum Calls {
    /// Known call apps by bundle id prefix, for a short name; their helpers report ids that start the same.
    public static let apps: [(prefix: String, name: String)] = [
        ("us.zoom", "Zoom"), ("com.microsoft.teams", "Teams"), ("com.tinyspeck.slackmacgap", "Slack"), ("com.hnc.Discord", "Discord"),
        ("com.apple.FaceTime", "FaceTime"), ("net.whatsapp.WhatsApp", "WhatsApp"), ("Cisco-Systems.Spark", "Webex"), ("com.webex.meetingmanager", "Webex"),
        ("com.skype", "Skype"), ("ru.keepcoder.Telegram", "Telegram"), ("org.telegram", "Telegram"), ("org.whispersystems.signal-desktop", "Signal"),
        ("com.apple.WebKit", "Safari"),
    ]
    /// Browsers by bundle id prefix: a call in a browser tab (Meet, Zoom or Teams on the web) asks by default.
    public static let browsers = [
        "com.google.Chrome", "company.thebrowser.", "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "app.zen-browser.zen", "com.kagi.kagimacOS", "org.chromium.Chromium",
    ]

    /// The app behind a process using a mic: a known name ("Zoom"), else the app's bundle id with any helper suffix cut
    /// (`com.google.Chrome.helper` -> `com.google.Chrome`), so an app and its helpers count as one.
    /// Nil for Kagu, Apple's own daemons (CoreSpeech holds the mic all day for "Hey Siri") and processes with no real bundle id.
    public static func app(_ bundle: String) -> String? {
        if bundle == testApp { return "Test" }
        if let known = apps.first(where: { bundle.hasPrefix($0.prefix) }) { return known.name }
        guard bundle != "local.recorder", !bundle.hasPrefix("com.apple."), bundle.contains(".") else { return nil }
        return bundle.range(of: ".helper", options: .caseInsensitive).map { String(bundle[..<$0.lowerBound]) } ?? bundle
    }

    /// Asks without a choice from the owner: a known call app (its key is a name, not a bundle id) or a browser.
    public static func asksByDefault(_ app: String) -> Bool { !app.contains(".") || browsers.contains { app.hasPrefix($0) } }

    /// Kagu's settings, also from KaguWatch (a separate process with defaults of its own).
    /// (Inside Kagu its own domain is `.standard`: macOS ignores a suite named after the app's own bundle id.)
    nonisolated(unsafe) public static let defaults = Bundle.main.bundleIdentifier == "local.recorder" ? .standard : UserDefaults(suiteName: "local.recorder") ?? .standard  // UserDefaults is thread safe
    /// The owner's choice per app (the key `app` gives), when it differs from asking by default or not.
    public static let choicesKey = "callApps"
    /// Every app (the key `app` gives) that held a mic, for the list in Settings.
    public static let seenKey = "micApps"

    public static func asks(_ app: String) -> Bool {
        (defaults.dictionary(forKey: choicesKey)?[app] as? Bool) ?? asksByDefault(app)
    }

    /// Keeps the app in the Settings list; a write only when it is new.
    public static func saw(_ app: String) {
        let seen = defaults.stringArray(forKey: seenKey) ?? []
        if app != "Test", !seen.contains(app) { defaults.set(seen + [app], forKey: seenKey) }
    }

    /// Test aid: `KAGU_WATCH_AS_CALL=<bundle id>` names that app "Test".
    public static let testApp = ProcessInfo.processInfo.environment["KAGU_WATCH_AS_CALL"]
}
