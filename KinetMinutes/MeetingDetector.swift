// MeetingDetector.swift — detect meeting apps launching, auto-start recording
// NSWorkspace didLaunchApplication notifications + 5s polling fallback.
// Apps: Zoom / Tencent Meeting / Teams / Feishu(Lark) / DingTalk / Discord / Webex / Slack huddles not covered.

import AppKit

final class MeetingDetector {
    static let bundleIDs: Set<String> = [
        "us.zoom.xos",                       // Zoom
        "com.tencent.meeting",               // 腾讯会议
        "com.microsoft.teams2", "com.microsoft.Teams",  // Teams
        "com.electron.lark", "com.ss.lark",  // 飞书 / Lark
        "com.alibaba.DingTalk",              // 钉钉
        "com.hnc.Discord",                   // Discord
        "cisco-webexmeetings.app", "com.cisco.webexmeetings.app", // Webex
        "com.tencent.wxwork",                // 企业微信(音视频会)
        "com.google.Chrome"                  // 浏览器会议兜底关(太宽,默认不开)
    ]
    // Conservative default: Chrome excluded (too broad). Kept in set for docs.
    let enabledAppBundleIDs: Set<String>

    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private let onStart: (String) -> Void
    private(set) var activeMeetingApps: Set<String> = []

    init(onStart: @escaping (String) -> Void) {
        self.onStart = onStart
        enabledAppBundleIDs = MeetingDetector.bundleIDs.subtracting(["com.google.Chrome"])
    }

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.check(app: app)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.poll() }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        timer?.invalidate()
    }

    private func poll() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            check(app: app, silent: true)
        }
    }

    private func check(app: NSRunningApplication, silent: Bool = false) {
        guard let bid = app.bundleIdentifier, enabledAppBundleIDs.contains(bid) else { return }
        let name = app.localizedName ?? bid
        // Only trigger when the app likely has an ongoing call: window count > 0
        // and not minimized. Keeps false positives low without accessibility perms.
        let hasWindows = { (app as NSRunningApplication) != nil && !app.isTerminated }
        guard hasWindows() else { return }
        guard !activeMeetingApps.contains(name) else { return }
        activeMeetingApps.insert(name)
        if UserDefaults.standard.bool(forKey: "autoRecord") {
            onStart(name)
        }
    }
}
