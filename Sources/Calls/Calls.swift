import Foundation

/// Which app a mic belongs to, shared by Kagu and the KaguWatch helper. Any app that holds a mic counts as a call;
/// only Kagu itself and the Mac's own listeners ("Hey Siri", dictation, Sound Recognition) are left out.
public enum Calls {
    /// Known call apps by bundle id prefix, for a short name; their helpers report ids that start the same.
    public static let apps: [(prefix: String, name: String)] = [
        ("us.zoom", "Zoom"), ("com.microsoft.teams", "Teams"), ("com.tinyspeck.slackmacgap", "Slack"), ("com.hnc.Discord", "Discord"),
        ("com.apple.FaceTime", "FaceTime"), ("net.whatsapp.WhatsApp", "WhatsApp"), ("Cisco-Systems.Spark", "Webex"), ("com.webex.meetingmanager", "Webex"),
        ("com.apple.WebKit", "Safari"),
    ]

    /// The app behind a process using a mic: a known name ("Zoom"), else the app's bundle id with any helper suffix cut
    /// (`com.google.Chrome.helper` -> `com.google.Chrome`), so an app and its helpers count as one. Nil when it is not a call.
    public static func app(_ bundle: String) -> String? {
        if bundle == testApp { return "Test" }
        if let known = apps.first(where: { bundle.hasPrefix($0.prefix) }) { return known.name }
        // Kagu, Apple's own daemons (CoreSpeech holds the mic all day for "Hey Siri") and processes with no real bundle id.
        guard bundle != "local.recorder", !bundle.hasPrefix("com.apple."), bundle.contains(".") else { return nil }
        return bundle.range(of: ".helper", options: .caseInsensitive).map { String(bundle[..<$0.lowerBound]) } ?? bundle
    }

    /// Test aid: `KAGU_WATCH_AS_CALL=<bundle id>` names that app "Test".
    public static let testApp = ProcessInfo.processInfo.environment["KAGU_WATCH_AS_CALL"]
}
