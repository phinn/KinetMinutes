// AppDelegate.swift — KinetMinutes entry
// Menu-bar resident meeting notes app. Local-only: record → transcribe (WhisperKit)
// → summarize (local LLM) → store (SQLite). Audio never leaves the Mac.

import Cocoa
import UserNotifications
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var libraryWindow: NSWindow?
    let store = MeetingStore.shared
    let recorder = MeetingRecorder.shared
    let pipeline = MinutesPipeline.shared
    var detector: MeetingDetector?
    private var statusMenuItem: NSMenuItem?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar app
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        store.migrateIfNeeded()
        store.seedDemoMeetingIfNeeded()   // review notes 承诺的 pre-seeded demo meeting(90 秒复测路径依赖它)
        MeetingRecorder.recoverOrphanedMeetings()   // F03: crash recovery — finalize meetings left mid-flight
        // any recovered meetings can now be re-processed from the library
        for m in store.allMeetings() where m.status == "ready_to_process" {
            store.update(m.id, status: "processing")
            Task.detached { await MinutesPipeline.shared.process(meetingID: m.id) }
        }
        recorder.onLevelChange = { [weak self] level in self?.updateIcon(recording: self?.recorder.isRecording ?? false, level: level) }
        pipeline.onStateChange = { [weak self] in self?.refreshStatusMenu() }
        buildStatusMenu()
        updateIcon(recording: false, level: 0)

        detector = MeetingDetector { [weak self] appName in
            self?.autoStartMeeting(sourceApp: appName)
        }
        detector?.start()

        // Debug screenshot helper: auto-open the library window on launch
        if ProcessInfo.processInfo.environment["KM_AUTO_OPEN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openLibrary()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let f = self?.libraryWindow?.frame {
                        NSLog("KM_WINDOW_FRAME %f %f %f %f", f.origin.x, f.origin.y, f.size.width, f.size.height)
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder.stopSaving()
    }

    // MARK: - Meeting lifecycle

    @objc func toggleRecording() {
        if recorder.isRecording {
            finishMeeting()
        } else {
            startMeeting(sourceApp: "Manual")
        }
    }

    func autoStartMeeting(sourceApp: String) {
        guard !recorder.isRecording else { return }
        startMeeting(sourceApp: sourceApp)
    }

    private func startMeeting(sourceApp: String) {
        do {
            let meeting = store.createMeeting(sourceApp: sourceApp)
            try recorder.start(meetingID: meeting.id)
            notify(title: L10n.string("Recording started"),
                   body: String(format: L10n.string("Recording from %@. Notes will be ready when the meeting ends."), sourceApp))
            refreshStatusMenu()
        } catch {
            notify(title: L10n.string("Cannot start recording"), body: error.localizedDescription)
        }
    }

    func finishMeeting() {
        guard let meetingID = recorder.stopSaving() else { return }
        refreshStatusMenu()
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.pipeline.process(meetingID: meetingID)
            await MainActor.run { self?.refreshStatusMenu() }
        }
    }

    // MARK: - Status item

    func updateIcon(recording: Bool, level: Float) {
        guard let button = statusItem.button else { return }
        if recording {
            // 1-4 bars by level
            let n = max(1, min(4, Int(level * 12)))
            let bars = ["▁", "▃", "▅", "▆"][max(0, n - 1)]
            button.title = "🎙\(bars)"
        } else if pipeline.isProcessing {
            button.title = "⚙️"
        } else {
            button.title = "🗓"
        }
    }

    func buildStatusMenu() {
        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: L10n.string("Standby — no meeting"), action: nil, keyEquivalent: "")
        menu.addItem(statusMenuItem!)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: L10n.string("Start Recording"), action: #selector(toggleRecording), keyEquivalent: "r")
        toggle.target = self
        menu.addItem(toggle)

        let library = NSMenuItem(title: L10n.string("Meeting Library…"), action: #selector(openLibrary), keyEquivalent: "l")
        library.target = self
        menu.addItem(library)

        let privacy = NSMenuItem(title: L10n.string("Privacy…"), action: #selector(openPrivacy), keyEquivalent: "p")
        privacy.target = self
        menu.addItem(privacy)

        menu.addItem(.separator())
        let auto = NSMenuItem(title: L10n.string("Auto-record when a meeting app opens"), action: #selector(toggleAutoRecord), keyEquivalent: "")
        auto.target = self
        auto.state = UserDefaults.standard.bool(forKey: "autoRecord") ? .on : .off
        menu.addItem(auto)

        // F01: optional launch-at-login (SMAppService, macOS 13+)
        let login = NSMenuItem(title: L10n.string("Launch at Login"), action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.string("Quit KinetMinutes"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    func refreshStatusMenu() {
        if recorder.isRecording, let mid = recorder.currentMeetingID, let m = store.meeting(id: mid) {
            statusMenuItem?.title = String(format: L10n.string("Recording — %@ (%@)"), m.title, recorder.elapsedString)
        } else if pipeline.isProcessing {
            statusMenuItem?.title = L10n.string("Generating notes…")
        } else {
            statusMenuItem?.title = L10n.string("Standby — no meeting")
        }
        updateIcon(recording: recorder.isRecording, level: recorder.lastLevel)
    }

    @objc func toggleAutoRecord() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: "autoRecord"), forKey: "autoRecord")
        buildStatusMenu()
    }

    // F01: launch at login via SMAppService
    @objc func toggleLoginItem() {
        let svc = SMAppService.mainApp
        do {
            switch svc.status {
            case .enabled: try svc.unregister()
            case .notRegistered: try svc.register()
            case .requiresApproval:
                try svc.register()   // user approves in System Settings; state picks up next check
            case .notFound: break
            @unknown default: break
            }
        } catch {
            notify(title: L10n.string("Cannot start recording"), body: error.localizedDescription)
        }
        buildStatusMenu()
    }

    @objc func openLibrary() {
        if libraryWindow == nil {
            libraryWindow = LibraryWindowController().window
        }
        libraryWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openPrivacy() {
        if libraryWindow == nil { openLibrary() }
        NotificationCenter.default.post(name: .showPrivacyPane, object: nil)
        libraryWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

extension Notification.Name {
    static let showPrivacyPane = Notification.Name("showPrivacyPane")
    static let meetingsChanged = Notification.Name("meetingsChanged")
}
