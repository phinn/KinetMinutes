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
    var libraryWC: LibraryWindowController?
    var settingsWC: SettingsWindowController?
    let store = MeetingStore.shared
    let recorder = MeetingRecorder.shared
    let pipeline = MinutesPipeline.shared
    var detector: MeetingDetector?
    private var statusMenuItem: NSMenuItem?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar app
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // F08 (1.1): refresh Pro entitlement first so the menu shows the right
        // state and the price string is ready before first menu open.
        Task { @MainActor in
            await Licensing.shared.refresh()
            await Licensing.shared.loadPrice()
            buildStatusMenu()
        }
        store.migrateIfNeeded()
        store.seedDemoMeetingIfNeeded()   // review notes 承诺的 pre-seeded demo meeting(90 秒复测路径依赖它)
        MeetingRecorder.recoverOrphanedMeetings()   // F03: crash recovery — finalize meetings left mid-flight
        // any recovered meetings can now be re-processed from the library
        for m in store.allMeetings() where m.status == "ready_to_process" {
            store.update(m.id, status: "processing")
            Task.detached { await MinutesPipeline.shared.process(meetingID: m.id) }
        }
        recorder.onLevelChange = { [weak self] level in self?.scheduleStatusRefresh() }
        pipeline.onStateChange = { [weak self] in self?.scheduleStatusRefresh() }
        buildStatusMenu()
        updateIcon(recording: false, level: 0)

        detector = MeetingDetector { [weak self] appName in
            self?.autoStartMeeting(sourceApp: appName)
        }
        detector?.start()

        // Debug: auto-fill search box to verify filter pipeline headlessly (KM_AUTO_SEARCH="Maya")
        if let q = ProcessInfo.processInfo.environment["KM_AUTO_SEARCH"], !q.isEmpty {
            NSLog("[KMApp] auto search branch entered: %@", q)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                NSLog("[KMApp] posting KMAutoSearch")
                NotificationCenter.default.post(name: Notification.Name("KMAutoSearch"), object: q)
            }
        }
        // Debug: auto-open the settings window (KM_AUTO_SETTINGS=1)
        if ProcessInfo.processInfo.environment["KM_AUTO_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openSettings()
            }
        }
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

    /// 1.2: transcribe-only recording — free, unlimited, no LLM notes.
    @objc func toggleTranscribeOnly() {
        if recorder.isRecording {
            finishMeeting()
        } else {
            startMeeting(sourceApp: "Manual", transcribeOnly: true)
        }
    }

    func autoStartMeeting(sourceApp: String) {
        guard !recorder.isRecording else { return }
        // auto-record follows the last used mode; default to full notes.
        startMeeting(sourceApp: sourceApp, transcribeOnly: UserDefaults.standard.bool(forKey: "autoTranscribeOnly"))
    }

    private func startMeeting(sourceApp: String, transcribeOnly: Bool = false) {
        let meeting = store.createMeeting(sourceApp: sourceApp, transcribeOnly: transcribeOnly)
        recorder.start(meetingID: meeting.id)
        notify(title: L10n.string("Recording started"),
               body: transcribeOnly
                ? String(format: L10n.string("Recording from %@. Transcript will be ready when the recording ends."), sourceApp)
                : String(format: L10n.string("Recording from %@. Notes will be ready when the meeting ends."), sourceApp))
        refreshStatusMenu()
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

        // 1.2: recording state flips the primary item into Stop (was a
        // forever-"Start Recording" dead-end before). TO entry hidden while
        // recording — both toggles finish the same way.
        let recording = recorder.isRecording
        let toggle = NSMenuItem(
            title: L10n.string(recording ? "Stop & Generate Notes" : "Start Recording"),
            action: #selector(toggleRecording), keyEquivalent: "r")
        toggle.target = self
        menu.addItem(toggle)

        if !recording {
            // 1.2: free & unlimited transcript-only recording
            let to = NSMenuItem(title: L10n.string("Start Transcribe-Only"), action: #selector(toggleTranscribeOnly), keyEquivalent: "t")
            to.target = self
            menu.addItem(to)
        }

        let library = NSMenuItem(title: L10n.string("Meeting Library…"), action: #selector(openLibrary), keyEquivalent: "l")
        library.target = self
        menu.addItem(library)

        // F08 (1.1): lifetime unlock menu items (hidden once Pro is active).
        if Licensing.shared.isPro {
            let pro = NSMenuItem(title: L10n.string("Pro Active ✓"), action: nil, keyEquivalent: "")
            pro.state = .on
            menu.addItem(pro)
        } else {
            var upTitle = L10n.string("Upgrade to Pro…")
            if let price = Licensing.shared.priceString, !price.isEmpty { upTitle += "  (\(price))" }
            let up = NSMenuItem(title: upTitle, action: #selector(upgradePro), keyEquivalent: "")
            up.target = self
            menu.addItem(up)
            let rs = NSMenuItem(title: L10n.string("Restore Purchase"), action: #selector(restorePro), keyEquivalent: "")
            rs.target = self
            menu.addItem(rs)
        }

        let privacy = NSMenuItem(title: L10n.string("Privacy…"), action: #selector(openPrivacy), keyEquivalent: "p")
        privacy.target = self
        menu.addItem(privacy)

        // 1.3: settings window (default mode / model management / quota)
        let settings = NSMenuItem(title: L10n.string("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

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

    /// MUST be reached on the main thread only (touches statusItem.button —
    /// NSStatusItem lazily creates its status-bar window on first .button
    /// access, and doing that off-main corrupts Autolayout → abort at launch
    /// when orphan recovery fires the pipeline from Task.detached).
    /// Callers on arbitrary queues go through `scheduleStatusRefresh()`.
    /// Which structural shape the status menu is in — rebuild only on change
    /// so the 0.3 s level heartbeat retitles instead of re-arming the menu
    /// (reassigning statusItem.menu while the menu is open glitches AppKit).
    private enum MenuShape: Equatable { case idle, recording, processing }
    private var menuShape: MenuShape = .idle

    func refreshStatusMenu() {
        let shape: MenuShape = recorder.isRecording ? .recording : (pipeline.isProcessing ? .processing : .idle)
        if shape != menuShape {
            menuShape = shape
            buildStatusMenu()
        }
        if recorder.isRecording, let mid = recorder.currentMeetingID, let m = store.meeting(id: mid) {
            statusMenuItem?.title = String(format: L10n.string("Recording — %@ (%@)"), m.title, recorder.elapsedString)
        } else if pipeline.isProcessing {
            statusMenuItem?.title = L10n.string("Generating notes…")
        } else {
            statusMenuItem?.title = L10n.string("Standby — no meeting")
        }
        updateIcon(recording: recorder.isRecording, level: recorder.lastLevel)
    }

    /// Thread-safe hop: pipeline/level callbacks may fire from background
    /// queues; coalesce onto the main thread (idempotent, cheap when already
    /// on main because the hop is synchronous).
    func scheduleStatusRefresh() {
        if Thread.isMainThread { refreshStatusMenu(); return }
        DispatchQueue.main.async { [weak self] in self?.refreshStatusMenu() }
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
        if libraryWC == nil {
            let wc = LibraryWindowController()
            libraryWC = wc
            libraryWindow = wc.window
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

    /// 1.3: settings window — default mode, ASR model, quota.
    @objc func openSettings() {
        if settingsWC == nil { settingsWC = SettingsWindowController() }
        settingsWC?.show()
    }

    // F08 (1.1): lifetime unlock via StoreKit 2 non-consumable.
    @objc func upgradePro() {
        Task { @MainActor in
            await Licensing.shared.purchase()
            refreshStatusMenu()
            if case .failed(let msg) = Licensing.shared.purchaseState {
                let a = NSAlert()
                a.messageText = L10n.string("Purchase Failed")
                a.informativeText = msg
                a.runModal()
            }
        }
    }

    @objc func restorePro() {
        Task { @MainActor in
            await Licensing.shared.restore()
            refreshStatusMenu()
            let a = NSAlert()
            a.messageText = Licensing.shared.isPro ? L10n.string("Pro Active ✓") : L10n.string("No purchases found")
            a.runModal()
        }
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
