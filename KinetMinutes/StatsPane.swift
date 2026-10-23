// StatsPane.swift — 1.3 P2: meeting statistics window (pure aggregate, no editing)
import AppKit

final class StatsPane: NSView {
    private let cards = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: L10n.string("no stats yet"))
    private let updated = NSTextField(labelWithString: "")
    var onBack: (() -> Void)?

    struct Row {
        let title: String; let value: String; let sub: String
    }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
        wantsLayer = true

        let backBtn = NSButton(title: L10n.string("Back"), target: nil, action: nil)
        backBtn.bezelStyle = .rounded
        backBtn.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: L10n.string("Back"))
        backBtn.imagePosition = .imageLeading
        backBtn.controlSize = .small
        backBtn.target = self
        backBtn.action = #selector(backTapped)
        backBtn.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: L10n.string("Meeting Statistics…").replacingOccurrences(of: "…", with: ""))
        title.font = .systemFont(ofSize: 17, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false

        cards.orientation = .vertical
        cards.alignment = .leading
        cards.spacing = 14
        cards.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        updated.font = NSFont.systemFont(ofSize: 11)
        updated.textColor = .tertiaryLabelColor
        updated.translatesAutoresizingMaskIntoConstraints = false

        addSubview(cards)
        addSubview(backBtn)
        addSubview(title)
        addSubview(emptyLabel)
        addSubview(updated)
        NSLayoutConstraint.activate([
            backBtn.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            backBtn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            title.centerYAnchor.constraint(equalTo: backBtn.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: backBtn.trailingAnchor, constant: 10),
            cards.topAnchor.constraint(equalTo: backBtn.bottomAnchor, constant: 24),
            cards.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            cards.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            updated.topAnchor.constraint(equalTo: cards.bottomAnchor, constant: 18),
            updated.leadingAnchor.constraint(equalTo: cards.leadingAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        refresh()
        NotificationCenter.default.addObserver(forName: .meetingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    /// Embedded pane: hand control back to the library detail view.
    @objc private func backTapped() { onBack?() }

    func refresh() {
        let ms = MeetingStore.shared.allMeetings()
        guard !ms.isEmpty else {
            cards.isHidden = true
            emptyLabel.isHidden = false
            updated.stringValue = ""
            return
        }
        cards.isHidden = false
        emptyLabel.isHidden = true

        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let startOfWeek = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!

        let total = ms.count
        let month = ms.filter { $0.startedAt >= startOfMonth }
        let week = ms.filter { $0.startedAt >= startOfWeek }
        let totalDur = ms.reduce(0.0) { $0 + $1.durationSeconds }
        let monthDur = month.reduce(0.0) { $0 + $1.durationSeconds }
        // Word count: CJK has no spaces, so count CJK chars 1:1 and latin
        // words by whitespace. Naive "max(words, chars/2)" inflated CJK text
        // and produced nonsense numbers like "899w".
        func wordCount(_ text: String) -> Int {
            var cjk = 0, latin = 0
            for ch in text {
                if ch.isLetter {
                    if ch.unicodeScalars.first!.value >= 0x4E00 { cjk += 1 }
                    else { latin += 1 }
                }
            }
            let latinWords = text.split { $0 == " " || $0 == "\n" || $0 == "\t" }
                .filter { $0.contains { $0.isLetter } }.count
            return cjk + latinWords
        }
        let monthWords = month.reduce(0) { $0 + wordCount($1.transcript ?? "") }
        let fmt = DateComponentsFormatter()
        fmt.allowedUnits = [.hour, .minute]
        fmt.unitsStyle = .abbreviated

        let rows: [Row] = [
            Row(title: L10n.string("Meetings"), value: String(total),
                sub: String(format: "%d · %@", month.count, L10n.string("This Month")) + " · " + String(week.count) + " · " + L10n.string("This week")),
            Row(title: L10n.string("Total recorded"), value: fmt.string(from: totalDur) ?? "—",
                sub: L10n.string("This Month") + ": " + (fmt.string(from: monthDur) ?? "—")),
            Row(title: L10n.string("Total notes"), value: String(ms.filter { $0.summary != nil && !($0.summary ?? "").isEmpty }.count),
                sub: String(month.filter { $0.summary != nil && !($0.summary ?? "").isEmpty }.count) + " · " + L10n.string("This Month")),
            Row(title: L10n.string("Transcript words"), value: String(monthWords),
                sub: String(format: "%@ · %@", L10n.string("This Month"), L10n.string("Meetings"))),
        ]
        cards.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // 2x2 grid: two horizontal rows; fillEqually shares the row between the
        // two cards, and an explicit width constraint pins the row to the pane
        // width (NSStackView alignment alone leaves rows at intrinsic size).
        for pair in stride(from: 0, to: rows.count, by: 2) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 14
            row.translatesAutoresizingMaskIntoConstraints = false
            for r in rows[pair..<min(pair + 2, rows.count)] { row.addArrangedSubview(Self.card(r)) }
            cards.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: cards.widthAnchor).isActive = true
        }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        updated.stringValue = L10n.string("Updated") + ": " + f.string(from: now)
    }

    /// Card = rounded layer + vertically stacked labels with an EXPLICIT height.
    /// NSBox.title was fighting the content view for space (labels overlapped);
    /// a plain layer + fixed-height stack is deterministic across macOS versions.
    private static func card(_ r: Row) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor

        let title = NSTextField(labelWithString: r.title)
        title.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        title.textColor = .secondaryLabelColor

        let value = NSTextField(labelWithString: r.value)
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .semibold)

        let sub = NSTextField(labelWithString: r.sub)
        sub.font = NSFont.systemFont(ofSize: 11)
        sub.textColor = .tertiaryLabelColor
        sub.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [title, value, sub])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false

        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: box.bottomAnchor, constant: -12),
            box.heightAnchor.constraint(equalToConstant: 92),
        ])
        return box
    }
}

final class StatsWindowController: NSWindowController {
    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = L10n.string("Meeting Statistics")
        w.contentView = StatsPane()
        w.center()
        w.isReleasedWhenClosed = false
        self.init(window: w)
    }
    func showPane() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
