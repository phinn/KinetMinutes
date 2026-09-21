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
    private var privacyPane: PrivacyPane!

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = L10n.string("Meeting Library")
        NSLog("KM_RAW_WIN %f", win.frame.width)
        self.init(window: win)
        win.delegate = self
        buildUI()
        win.center()
        reload()
        NotificationCenter.default.addObserver(forName: .meetingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
        NotificationCenter.default.addObserver(forName: .showPrivacyPane, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.detail.removeFromSuperview()
            self.privacyPane.isHidden = false
        }
        NotificationCenter.default.addObserver(forName: .meetingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
            guard let self, self.privacyPane.superview != nil else { return }
            self.privacyPane.removeFromSuperview()
            self.privacyPane.isHidden = true
            self.split.addArrangedSubview(self.detail)
        }
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

        listTableView = NSTableView()
        let col = NSTableColumn(identifier: .init("m"))
        col.title = ""
        col.resizingMask = .autoresizingMask
        listTableView.addTableColumn(col)
        listTableView.headerView = nil
        listTableView.rowHeight = 56
        listTableView.style = .inset
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

        // Right: detail + privacy pane (privacy hidden by default)
        detail = DetailView()
        privacyPane = PrivacyPane()
        privacyPane.isHidden = true

        split.addArrangedSubview(left)
        split.addArrangedSubview(detail)
        split.addArrangedSubview(privacyPane)
        left.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        privacyPane.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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
        meetings = MeetingStore.shared.allMeetings(search: searchField?.stringValue)
        listTableView.reloadData()
        if listTableView.selectedRow == -1, !meetings.isEmpty { detail.show(meeting: meetings[0]) }
        if meetings.isEmpty { detail.show(meeting: nil) }
    }

    @objc private func rowClicked() {
        let row = listTableView.clickedRow
        guard row >= 0, row < meetings.count else { return }
        detail.show(meeting: meetings[row])
    }

    func windowWillClose(_ notification: Notification) {
        // no-op
    }

    func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect) -> NSRect { rect }

    func windowDidResize(_ notification: Notification) {}
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
        if !m.tags.isEmpty { sub += " · " + m.tags.map { "#\($0)" }.joined(separator: " ") }   // F07 tags
        if m.status == "processing" { sub += " · " + L10n.string("Generating…") }
        if m.status == "failed" { sub += " · " + L10n.string("Failed") }
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
    private let tabs = NSSegmentedControl(labels: [
        L10n.string("Summary"), L10n.string("Decisions"), L10n.string("Action Items"),
        L10n.string("Timeline"), L10n.string("Transcript")
    ], trackingMode: .momentary, target: nil, action: nil)
    private let text = TimelineTextView()
    private let exportBtn = NSButton(title: L10n.string("Export"), target: nil, action: nil)
    private let deleteBtn = NSButton(title: L10n.string("Delete"), target: nil, action: nil)
    private let renameBtn = NSButton(title: L10n.string("Rename"), target: nil, action: nil)
    private var player: AVAudioPlayer?   // F06: timeline click → play from timestamp

    override init(frame: NSRect) {
        super.init(frame: frame)
        tabs.segmentStyle = .texturedRounded
        tabs.target = self; tabs.action = #selector(tabChanged)
        tabs.translatesAutoresizingMaskIntoConstraints = false

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
        scroll.identifier = NSUserInterfaceItemIdentifier("scroll")
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            exportBtn.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            exportBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            deleteBtn.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            deleteBtn.trailingAnchor.constraint(equalTo: exportBtn.leadingAnchor, constant: -8),
            renameBtn.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            renameBtn.trailingAnchor.constraint(equalTo: deleteBtn.leadingAnchor, constant: -8),
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
        tabs.isHidden = meeting == nil
        exportBtn.isHidden = meeting == nil
        deleteBtn.isHidden = meeting == nil
        renameBtn.isHidden = meeting == nil
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
        switch tabs.selectedSegment {
        case 0:
            text.string = m.status == "processing" ? L10n.string("Generating…") :
                (m.summary ?? (m.status == "failed" ? L10n.string("Notes generation failed") : L10n.string("Model not downloaded yet")))
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
            let body = NSAttributedString(string: g.text + (i == segments.count - 1 ? "" : "\n\n"), attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor
            ])
            out.append(link); out.append(body)
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


