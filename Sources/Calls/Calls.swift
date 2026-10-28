import Foundation

/// The apps a call happens in, shared by Kagu and the KaguWatch helper.
public enum Calls {
    /// Call apps by bundle id prefix; their helpers report ids that start the same.
    public static let apps: [(prefix: String, name: String)] = [
        ("us.zoom", "Zoom"), ("com.microsoft.teams", "Teams"), ("com.tinyspeck.slackmacgap", "Slack"), ("com.hnc.Discord", "Discord"),
        ("com.apple.FaceTime", "FaceTime"), ("net.whatsapp.WhatsApp", "WhatsApp"), ("Cisco-Systems.Spark", "Webex"), ("com.webex.meetingmanager", "Webex"),
    ]
    public static func callApp(_ bundle: String) -> String? { apps.first { bundle.hasPrefix($0.prefix) }?.name ?? (bundle == testApp ? "Test" : nil) }
    /// Test aid: `KAGU_WATCH_AS_CALL=<bundle id>` counts that app as a call app.
    public static let testApp = ProcessInfo.processInfo.environment["KAGU_WATCH_AS_CALL"]
    /// Chrome and its helpers, not Canary or a web app Chrome made (those have ids of their own).
    public static func isChrome(_ bundle: String) -> Bool { bundle == "com.google.Chrome" || bundle.hasPrefix("com.google.Chrome.helper") }
}
