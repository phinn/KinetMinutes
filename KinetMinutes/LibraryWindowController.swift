import AVFoundation
import AppKit
import CoreAudio

// LibraryWindowController.swift — meeting library: list + detail (notes/timeline/transcript/export)

import AppKit
import AVFoundation

final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    private var split: NSSplitView!
    private var listTableView: NSTableView!
    private var detail: DetailView!
    private var searchField: NSSearchField!
    var searchFieldForTest: NSSearchField? { searchField }

    private var autoSearchObs: NSObjectProtocol?
    private var privacyPane: PrivacyPane!
    private var settingsPane: SettingsPane!
    private var statsPane: StatsPane!

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = L10n.string("Meeting Library")
        NSLog("KM_RAW_WIN %f", win.frame.width)
        self.init(window: win)
        win.delegate = self
        buildUI()
        installToolbar()
        win.center()
        reload()
        NotificationCenter.default.addObserver(forName: .meetingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
        NotificationCenter.default.addObserver(forName: .showPrivacyPane, object: nil, queue: .main) { [weak self] _ in
            self?.showPane(.privacy)
        }
    }

    // MARK: - Right-side panes (detail / privacy / settings / stats)
    // All overlays occupy the same split slot as the detail view and swap
    // through showPane(_:), so exactly one is visible at a time.

    enum SidePane { case detail, privacy, settings, stats }
    private var currentPane: SidePane = .detail

    private func ensurePanes() {
        if privacyPane == nil { privacyPane = PrivacyPane() }
    }

    /// Swap the right side to `pane`. Settings/stats are recreated on every
    /// open so quota/model/storage state is current; privacy persists.
    func showPane(_ pane: SidePane) {
        ensurePanes()
        guard pane != currentPane || pane == .settings || pane == .stats else { return }

        // Tear down whoever currently holds the slot.
        if pane != .detail || currentPane != .detail {
            switch currentPane {
            case .detail:    if detail.superview != nil { detail.removeFromSuperview() }
            case .privacy:   privacyPane.removeFromSuperview()
            case .settings:  settingsPane?.removeFromSuperview()
            case .stats:     statsPane?.removeFromSuperview()
            }
        }

        switch pane {
        case .detail:
            if detail.superview == nil { split.addArrangedSubview(detail) }
        case .privacy:
            privacyPane.onBack = { [weak self] in self?.showPane(.detail) }
            split.addArrangedSubview(privacyPane)
        case .settings:
            let sp = SettingsPane()
            sp.onBack = { [weak self] in self?.showPane(.detail) }
            settingsPane = sp
            split.addArrangedSubview(sp)
        case .stats:
            let st = StatsPane()
            st.onBack = { [weak self] in self?.showPane(.detail) }
            statsPane = st
            split.addArrangedSubview(st)
        }
        currentPane = pane
    }

    /// Legacy path used by older call sites.
    func showDetail() { showPane(.detail) }

    // MARK: - Toolbar (settings / stats entry points)
    // Library hosts the settings & stats panes inline, so the window needs
    // visible buttons: ⚙ opens the settings pane, 📊 the stats pane.
    private static let toolbarID = "KMLibraryToolbar"

    private func installToolbar() {
        let tb = NSToolbar(identifier: Self.toolbarID)
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        tb.autosavesConfiguration = false
        window?.toolbar = tb
    }

    @objc private func toolbarSettings(_ sender: Any?) {
        showPane(currentPane == .settings ? .detail : .settings)
    }

    @objc private func toolbarStats(_ sender: Any?) {
        showPane(currentPane == .stats ? .detail : .stats)
    }

    private var meetings: [Meeting] = []

    private func buildUI() {
        guard let win = window else { return }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        win.contentView = content
        split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin

        // Left: search + table
        let left = NSView()
        searchField = NSSearchField()
        searchField.placeholderString = L10n.string("Search meetings…")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(reload)
        searchField.sendsSearchStringImmediately = true
        searchField.isContinuous = true
        searchField.delegate = self
        autoSearchObs = NotificationCenter.default.addObserver(forName: Notification.Name("KMAutoSearch"), object: nil, queue: .main) { [weak self] note in
            NSLog("[KMLib] KMAutoSearch block fired, self=%@ obj=%@", self == nil ? "nil" : "alive", note.object as? String ?? "nonstring")
            guard let q = note.object as? String, let sf = self?.searchField else { return }
            sf.stringValue = q
            self?.reload()
            NSLog("[KMLib] auto search applied: %@", q)
        }

        listTableView = NSTableView()
        let col = NSTableColumn(identifier: .init("m"))
        col.title = ""
        col.resizingMask = .autoresizingMask
        listTableView.addTableColumn(col)
        listTableView.headerView = nil
        listTableView.rowHeight = 56
        listTableView.style = .inset
        listTableView.dataSource = self
        listTableView.delegate = self
        listTableView.target = self
        listTableView.action = #selector(rowClicked)
        let scroll = NSScrollView()
        scroll.documentView = listTableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        left.addSubview(searchField)
        left.addSubview(scroll)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: left.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: left.bottomAnchor)
        ])

        // Right: detail view; privacy/settings/stats swap into the same slot
        // on demand (showPane) instead of stacking hidden panes.
        detail = DetailView()

        split.addArrangedSubview(left)
        split.addArrangedSubview(detail)
        left.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Frame-based layout: split fills content, left pane pinned at 300.
        // (Constraint-based pinning made NSWindow shrink to fit the panes — known trap.)
        split.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        split.autoresizingMask = [.width, .height]
        split.setPosition(300, ofDividerAt: 0)
        DispatchQueue.main.async { self.split.setPosition(300, ofDividerAt: 0) }
        content.addSubview(split)
        content.autoresizesSubviews = true
    }

    @objc func reload() {
        let q = searchField?.stringValue
        NSLog("[KMLib] reload q=%@", q ?? "nil")
        meetings = MeetingStore.shared.allMeetings(search: q)
        listTableView.reloadData()
        listTableView.sizeLastColumnToFit()
        if listTableView.selectedRow == -1, !meetings.isEmpty {
            listTableView.selectRowIndexes(.init(integer: 0), byExtendingSelection: false)
            detail.show(meeting: meetings[0])
        }
        if meetings.isEmpty { detail.show(meeting: nil) }
    }

    @objc private func rowClicked() {
        let row = listTableView.clickedRow
        guard row >= 0, row < meetings.count else { return }
        detail.show(meeting: meetings[row])
    }

    /// 1.2: keyboard/programmatic selection must refresh the detail pane too —
    /// rowClicked() only covers real mouse clicks (AX/arrow-key selection was a
    /// dead path before: highlight moved, detail pane stayed stale).
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = listTableView.selectedRow
        guard row >= 0, row < meetings.count else { return }
        detail.show(meeting: meetings[row])
    }

    func windowWillClose(_ notification: Notification) {
        // no-op
    }

    func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect) -> NSRect { rect }

    func windowDidResize(_ notification: Notification) {}
}

extension LibraryWindowController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        NSLog("[KMLib] controlTextDidChange: %@", searchField?.stringValue ?? "nil")
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(reload), object: nil)
        perform(#selector(reload), with: nil, afterDelay: 0.15)
    }
}

extension LibraryWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        max(1, meetings.count)  // empty-state row when none
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if meetings.isEmpty {
            let t = NSTextField(wrappingLabelWithString: L10n.string("Start your first meeting from the menu bar. Everything stays on this Mac."))
            t.textColor = .secondaryLabelColor
            t.frame = NSRect(x: 16, y: 16, width: 260, height: 80)
            let c = NSView(); c.addSubview(t); return c
        }
        let m = meetings[row]
        let cell = NSView()
        let title = NSTextField(labelWithString: m.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"
        var sub = f.string(from: m.startedAt) + " · \(m.sourceApp) · \(Int(m.durationSeconds / 60)) " + L10n.string("Minutes")
        if !m.tags.isEmpty { sub += " · " + m.tags.filter { $0 != "transcribe-only" }.map { "#\($0)" }.joined(separator: " ") }   // F07 tags (TO tag shown via badge/label below)
        if m.status == "processing" { sub += " · " + L10n.string("Generating…") }
        if m.status == "failed" { sub += " · " + L10n.string("Failed") }
        if m.transcribeOnly && !(m.summary ?? "").isEmpty && m.status != "failed" {
            sub += " · " + L10n.string("Transcript only")   // 1.2: until notes exist
        }
        let subL = NSTextField(labelWithString: sub)
        subL.font = .systemFont(ofSize: 11)
        subL.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 4, y: 32, width: 260, height: 18)
        subL.frame = NSRect(x: 4, y: 12, width: 260, height: 16)
        cell.addSubview(title); cell.addSubview(subL)
        return cell
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !meetings.isEmpty
    }
}

// F06: intercept kmplay:// link clicks (default would NSWorkspace.open an
// unregistered scheme). Returning true from the delegate method stops that.
final class TimelineTextView: NSTextView {
    var onPlayLink: ((Double) -> Void)?
}

extension DetailView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOn link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == "kmplay",
              let sec = Double(url.host ?? String(url.absoluteString.dropFirst("kmplay://".count))) else {
            return true   // swallow other links; we don't open web links from notes
        }
        play(from: sec)
        return true
    }
}

// MARK: - Detail

final class DetailView: NSView {
    private var meeting: Meeting?
    private let headerTitle = NSTextField(labelWithString: "")
    private let headerMeta = NSTextField(labelWithString: "")
    private let tabs = NSSegmentedControl(labels: [
        L10n.string("Summary"), L10n.string("Decisions"), L10n.string("Action Items"),
        L10n.string("Timeline"), L10n.string("Transcript")
    ], trackingMode: .selectOne, target: nil, action: nil)
    private let text = TimelineTextView()
    private let exportBtn = NSButton(title: L10n.string("Export"), target: nil, action: nil)
    private let deleteBtn = NSButton(title: L10n.string("Delete"), target: nil, action: nil)
    private let renameBtn = NSButton(title: L10n.string("Rename"), target: nil, action: nil)
    /// 1.2: shown on transcribe-only meetings — generates AI notes from the
    /// stored transcript (free wall applies; Pro upsell lives in the wall toast).
    private let genNotesBtn = NSButton(title: L10n.string("Generate Notes…"), target: nil, action: nil)
    /// 1.2: small badge marking transcript-only meetings in the detail header.
    private let toBadge = NSTextField(labelWithString: L10n.string("Transcript only"))
    private var player: AVAudioPlayer?   // F06: timeline click → play from timestamp

    override init(frame: NSRect) {
        super.init(frame: frame)
        tabs.segmentStyle = .texturedRounded
        tabs.target = self; tabs.action = #selector(tabChanged)
        tabs.translatesAutoresizingMaskIntoConstraints = false

        // 1.2: transcript-only affordances
        genNotesBtn.bezelStyle = .rounded
        genNotesBtn.controlSize = .small
        genNotesBtn.target = self
        genNotesBtn.action = #selector(generateNotesTapped)
        genNotesBtn.translatesAutoresizingMaskIntoConstraints = false
        genNotesBtn.isHidden = true
        toBadge.font = .systemFont(ofSize: 10, weight: .semibold)
        toBadge.textColor = .secondaryLabelColor
        toBadge.wantsLayer = true
        toBadge.layer?.cornerRadius = 4
        toBadge.layer?.masksToBounds = true
        toBadge.translatesAutoresizingMaskIntoConstraints = false
        toBadge.isHidden = true

        text.isEditable = false
        text.delegate = self
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        exportBtn.bezelStyle = .rounded
        exportBtn.target = self; exportBtn.action = #selector(exportSheet)
        exportBtn.translatesAutoresizingMaskIntoConstraints = false
        deleteBtn.bezelStyle = .rounded
        deleteBtn.target = self; deleteBtn.action = #selector(deleteMeeting)
        deleteBtn.translatesAutoresizingMaskIntoConstraints = false
        renameBtn.bezelStyle = .rounded
        renameBtn.target = self; renameBtn.action = #selector(renameMeeting)   // F07: title editable
        renameBtn.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tabs)
        addSubview(scroll)
        addSubview(exportBtn)
        addSubview(deleteBtn)
        addSubview(renameBtn)
        addSubview(genNotesBtn)
        addSubview(toBadge)
        headerTitle.font = .systemFont(ofSize: 20, weight: .bold)
        headerTitle.textColor = .labelColor
        headerTitle.lineBreakMode = .byTruncatingTail
        headerMeta.font = .systemFont(ofSize: 12)
        headerMeta.textColor = .secondaryLabelColor
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerMeta.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerTitle)
        addSubview(headerMeta)
        scroll.identifier = NSUserInterfaceItemIdentifier("scroll")
        NSLayoutConstraint.activate([
            headerTitle.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            headerTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            headerTitle.trailingAnchor.constraint(lessThanOrEqualTo: renameBtn.leadingAnchor, constant: -12),
            headerMeta.topAnchor.constraint(equalTo: headerTitle.bottomAnchor, constant: 2),
            headerMeta.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            headerMeta.trailingAnchor.constraint(lessThanOrEqualTo: renameBtn.leadingAnchor, constant: -12),
            tabs.topAnchor.constraint(equalTo: headerMeta.bottomAnchor, constant: 10),
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            exportBtn.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            exportBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            deleteBtn.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            deleteBtn.trailingAnchor.constraint(equalTo: exportBtn.leadingAnchor, constant: -8),
            renameBtn.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            renameBtn.trailingAnchor.constraint(equalTo: deleteBtn.leadingAnchor, constant: -8),
            genNotesBtn.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            genNotesBtn.trailingAnchor.constraint(equalTo: renameBtn.leadingAnchor, constant: -8),
            toBadge.centerYAnchor.constraint(equalTo: headerTitle.centerYAnchor),
            toBadge.leadingAnchor.constraint(equalTo: headerTitle.trailingAnchor, constant: 8),
            scroll.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
        _ = scroll // silence unused warning in layout
    }
    required init?(coder: NSCoder) { fatalError() }

    private var scroll: NSScrollView { subviews.first { $0.identifier?.rawValue == "scroll" } as! NSScrollView }

    func show(meeting: Meeting?) {
        self.meeting = meeting
        headerTitle.stringValue = meeting?.title ?? ""
        if let m = meeting {
            let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
            var meta = df.string(from: m.startedAt)
            if m.durationSeconds > 0 {
                let mins = Int(m.durationSeconds / 60)
                meta += " · " + (mins >= 1 ? "\(mins) 分钟" : "\(Int(m.durationSeconds)) 秒")
            }
            if !m.sourceApp.isEmpty { meta += " · " + m.sourceApp }
            headerMeta.stringValue = meta
        } else {
            headerMeta.stringValue = ""
        }
        headerTitle.isHidden = meeting == nil
        headerMeta.isHidden = meeting == nil
        tabs.isHidden = meeting == nil
        exportBtn.isHidden = meeting == nil
        deleteBtn.isHidden = meeting == nil
        renameBtn.isHidden = meeting == nil
        // 1.2: transcribe-only affordances — badge until notes exist; button
        // offers "Generate Notes" while the TO meeting has no summary yet
        // (covers: never generated / notes generation failed).
        let isTO = meeting?.transcribeOnly ?? false
        // A failed pipeline writes the error text into `summary` — that must
        // NOT count as "has notes" or the Generate button would hide forever.
        let hasNotes = !(meeting?.summary ?? "").isEmpty && meeting?.status != "failed"
        let hasTranscript = !(meeting?.transcript ?? "").isEmpty
        let busy = meeting?.status == "processing"
        let failed = meeting?.status == "failed"
        // 1.3: full-mode failures also surface the button (title = Retry);
        // success state still hides it for full-mode meetings.
        let showGen = busy || (isTO ? !hasNotes : failed)
        toBadge.isHidden = !isTO || hasNotes
        genNotesBtn.isHidden = !showGen
        genNotesBtn.isEnabled = !busy && hasTranscript
        genNotesBtn.title = busy
            ? L10n.string("Generating notes…")
            : (failed ? L10n.string("Retry") : L10n.string("Generate Notes…"))
        if meeting == nil { player?.stop(); player = nil }
        tabChanged()
    }

    @objc private func renameMeeting() {
        guard let m = meeting else { return }
        let alert = NSAlert()
        alert.messageText = L10n.string("Rename")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = m.title
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.string("OK"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                MeetingStore.shared.update(m.id, title: t)
                NotificationCenter.default.post(name: .meetingsChanged, object: nil)
            }
        }
    }

    @objc private func tabChanged() {
        guard let m = meeting else {
            text.string = L10n.string("No meetings yet")
            return
        }
        if tabs.selectedSegment < 0 { tabs.selectedSegment = 0 }
        switch tabs.selectedSegment {
        case 0:
            text.string = m.summary ?? (m.status == "processing" ? L10n.string("Generating…") : (m.status == "failed" ? L10n.string("Notes generation failed") : L10n.string("Model not downloaded yet")))
        case 1:
            text.string = m.decisions.map { "• " + $0 }.joined(separator: "\n")
        case 2:
            text.string = m.actions.map { a in "☐ \(a.task)" + (a.owner.isEmpty ? "" : " — \(a.owner)") + (a.due.isEmpty ? "" : " (\(a.due))") }.joined(separator: "\n")
        case 3:
            // F06: timestamps are click-to-play links ([MM:SS](kmplay://s))
            text.textStorage?.setAttributedString(Self.timelineAttr(from: m.segments))
        default:
            text.string = m.transcript ?? ""
        }
    }

    /// F06: build timeline with clickable [MM:SS] links that seek the audio player.
    /// 1.1: segments from the dual-track pipeline carry a speaker badge
    /// ([Me]/[Them], localized) between the timestamp and the text.
    static func timelineAttr(from segments: [Meeting.Segment]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, g) in segments.enumerated() {
            let s = Int(g.start)
            let stamp = String(format: "[%02d:%02d]", s / 60, s % 60)
            let link = NSAttributedString(string: stamp + " ", attributes: [
                .link: URL(string: "kmplay://\(g.start)")!,
                .foregroundColor: NSColor.controlAccentColor,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            ])
            out.append(link)
            if let sp = g.speaker {
                let badge: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 11),
                    .foregroundColor: sp == "me" ? NSColor.systemBlue : NSColor.systemOrange
                ]
                out.append(NSAttributedString(string: Exporters.speakerTag(sp), attributes: badge))
            }
            let body = NSAttributedString(string: g.text + (i == segments.count - 1 ? "" : "\n\n"), attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor
            ])
            out.append(body)
        }
        return out
    }

    /// F06: play the meeting audio from `seconds`; tapping a timestamp seeks here.
    private func play(from seconds: Double) {
        guard let m = meeting else { return }
        let store = MeetingStore.shared
        let sysTrack = store.audioDir.appendingPathComponent("meeting-\(m.id).sys.caf")
        let micTrack = store.audioDir.appendingPathComponent("meeting-\(m.id).caf")
        let path = FileManager.default.fileExists(atPath: sysTrack.path) ? sysTrack : micTrack
        guard FileManager.default.fileExists(atPath: path.path) else {
            (NSApp.delegate as? AppDelegate)?.notify(title: L10n.string("No audio"), body: L10n.string("Recording file not found"))
            return
        }
        if player == nil || player?.url != path {
            player = try? AVAudioPlayer(contentsOf: path)
            player?.prepareToPlay()
        }
        player?.currentTime = seconds
        player?.play()
    }

    /// 1.2: turn a transcribe-only meeting into full notes from its stored
    /// transcript — no ASR rerun. Free wall + quota enforcement run inside.
    @objc private func generateNotesTapped() {
        // 1.3: full-mode retry included. TO path: never-generated or failed;
        // full path: pipeline failure wrote error text into `summary` — rerun
        // the whole pipeline (transcript exists, so Whisper is skipped fast).
        guard let m = meeting, m.status != "processing" else { return }
        let isRetry = m.status == "failed"
        if m.transcribeOnly {
            guard isRetry || (m.summary ?? "").isEmpty else { return }   // no re-entry when notes exist
        } else {
            guard isRetry, !(m.transcript ?? "").isEmpty else { return } // retry needs a transcript to summarize
        }
        show(meeting: m)   // repaint busy state immediately
        Task {
            if isRetry && !m.transcribeOnly {
                await MinutesPipeline.shared.process(meetingID: m.id)
            } else {
                await MinutesPipeline.shared.generateNotes(meetingID: m.id)
            }
            await MainActor.run {
                if let fresh = MeetingStore.shared.meeting(id: m.id) { self.show(meeting: fresh) }
            }
        }
    }

    @objc private func exportSheet() {
        guard let m = meeting else { return }
        let menu = NSMenu()
        [("Export as Markdown", "md"), ("Export as TXT", "txt"), ("Export as SRT", "srt"), ("Export as PDF", "pdf")].forEach { label, ext in
            let it = NSMenuItem(title: L10n.string(label), action: #selector(doExport(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = ext
            menu.addItem(it)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: exportBtn.frame.minX, y: exportBtn.frame.minY - 4), in: self)
    }

    @objc private func doExport(_ sender: NSMenuItem) {
        guard let m = meeting, let ext = sender.representedObject as? String else { return }
        let safeName = m.title.replacingOccurrences(of: "/", with: "-")
        switch ext {
        case "md": Exporters.save(Exporters.markdown(for: m), name: safeName, ext: "md")
        case "srt": Exporters.save(Exporters.srt(for: m), name: safeName, ext: "srt")
        case "pdf": Exporters.savePDF(Exporters.markdown(for: m), name: safeName)   // F08: PDF via Cocoa text drawing
        default: Exporters.save(Exporters.txt(for: m), name: safeName, ext: "txt")
        }
    }

    @objc private func deleteMeeting() {
        guard let m = meeting else { return }
        let alert = NSAlert()
        alert.messageText = L10n.string("Delete")
        alert.informativeText = m.title
        alert.addButton(withTitle: L10n.string("Delete"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            MeetingStore.shared.delete(id: m.id)
            show(meeting: nil)
        }
    }
}



// MARK: - Library toolbar: settings / stats quick access

extension LibraryWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .init("settings"), .init("stats")]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .init("settings"), .init("stats")]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier.rawValue {
        case "settings":
            item.label = L10n.string("Settings")
            item.toolTip = L10n.string("Settings")
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(toolbarSettings(_:))
        case "stats":
            item.label = L10n.string("Meeting Statistics")
            item.toolTip = L10n.string("Meeting Statistics")
            item.image = NSImage(systemSymbolName: "chart.bar", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(toolbarStats(_:))
        default:
            return nil
        }
        return item
    }
}
