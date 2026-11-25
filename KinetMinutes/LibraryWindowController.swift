import AVFoundation
import AppKit

// LibraryWindowController.swift — meeting library: sidebar + detail
// (notes / decisions / action items / timeline / transcript / export)
//
// 1.4: visual overhaul — vibrancy sidebar with grouped, card-like rows;
// a focused detail header with icon actions; a capsule tab bar and a note
// card with editorial typography. Layout stays AppKit/constraint based and
// keeps every debug hook used by the screenshot/review harness.

// MARK: - Theme

enum KMTheme {
    static let amber = NSColor(srgbRed: 0.914, green: 0.647, blue: 0.290, alpha: 1)
    static let green = NSColor(srgbRed: 0.365, green: 0.612, blue: 0.427, alpha: 1)
    static let blue = NSColor(srgbRed: 0.478, green: 0.608, blue: 0.780, alpha: 1)
    static let coral = NSColor(srgbRed: 0.851, green: 0.451, blue: 0.373, alpha: 1)
    static let violet = NSColor(srgbRed: 0.545, green: 0.514, blue: 0.780, alpha: 1)
    private static let palette = [amber, blue, green, coral, violet]

    /// Stable color per meeting title/app so rows keep their identity.
    static func accent(for key: String) -> NSColor {
        let sum = key.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[abs(sum) % palette.count]
    }

    /// Pane canvas: a warm off-white that lets white cards read as cards.
    /// `windowBackgroundColor` was pure white in light mode, so every card
    /// dissolved into the background and the UI looked like a wireframe.
    static var canvas: NSColor {
        NSColor(name: "km.canvas") { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark
                ? NSColor(srgbRed: 0.106, green: 0.110, blue: 0.122, alpha: 1)
                : NSColor(srgbRed: 0.953, green: 0.949, blue: 0.937, alpha: 1)
        }
    }
    static var cardFill: NSColor {
        NSColor(name: "km.card") { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark
                ? NSColor(srgbRed: 0.145, green: 0.149, blue: 0.161, alpha: 1)
                : NSColor.white
        }
    }
    static var hairline: NSColor { NSColor.separatorColor.withAlphaComponent(0.55) }

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }
}

/// Top-aligned container for scrollable pane content.
final class KMFlipView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Small reusable controls

/// Borderless SF Symbol button with a soft hover plate — used for the
/// header's export / rename / delete actions.
final class KMIconButton: NSButton {
    private var hovering = false
    private let normalTint: NSColor

    init(symbol: String, tooltip: String, tint: NSColor = .secondaryLabelColor) {
        normalTint = tint
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        imagePosition = .imageOnly
        contentTintColor = tint
        self.toolTip = tooltip
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        wantsLayer = true
        layer?.cornerRadius = 8
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.35 } }
}

/// One pill in the detail tab bar.
final class KMTabButton: NSButton {
    var isChosen = false { didSet { refresh() } }
    private let titleText: String
    private var hovering = false

    init(title: String) {
        titleText = title
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let s = (titleText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)])
        return NSSize(width: ceil(s.width) + 24, height: 24)
    }

    private func refresh() {
        let color: NSColor = isChosen ? KMTheme.amber : .secondaryLabelColor
        attributedTitle = NSAttributedString(string: titleText, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: isChosen ? .semibold : .medium),
            .foregroundColor: color,
        ])
        if isChosen {
            layer?.backgroundColor = KMTheme.amber.withAlphaComponent(0.19).cgColor
        } else if hovering {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }
}

/// Capsule tab bar with an amber selection pill.
final class KMTabBar: NSView {
    private var buttons: [KMTabButton] = []
    private(set) var selectedIndex = 0
    var onSelect: ((Int) -> Void)?

    init(titles: [String]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        buttons = titles.enumerated().map { i, t in
            let b = KMTabButton(title: t)
            b.tag = i
            b.target = self
            b.action = #selector(tapped(_:))
            return b
        }
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        select(0)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped(_ sender: KMTabButton) { select(sender.tag, notify: true) }

    func select(_ index: Int, notify: Bool = false) {
        guard index >= 0, index < buttons.count else { return }
        selectedIndex = index
        for (i, b) in buttons.enumerated() { b.isChosen = (i == index) }
        if notify { onSelect?(index) }
    }
}

/// Tiny rounded label used for "Transcript only" and status pills.
final class KMPill: NSView {
    private let label = NSTextField(labelWithString: "")
    init(text: String = "", color: NSColor = KMTheme.amber) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        setText(text)
    }
    required init?(coder: NSCoder) { fatalError() }
    func setText(_ s: String) { label.stringValue = s }
    func setHidden(_ hidden: Bool) { isHidden = hidden }
}

/// Row selection plate: rounded amber tint + 3 pt accent bar.
final class KMRowView: NSTableRowView {
    private var hovering = false
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func drawBackground(in dirtyRect: NSRect) {
        if hovering && !isSelected {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 2), xRadius: 9, yRadius: 9).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let r = bounds.insetBy(dx: 8, dy: 2)
        let color = isEmphasized ? KMTheme.amber.withAlphaComponent(0.20)
                                 : NSColor.labelColor.withAlphaComponent(0.08)
        color.setFill()
        NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
        KMTheme.amber.setFill()
        let bar = NSRect(x: r.minX + 1, y: r.minY + 15, width: 3, height: max(0, r.height - 30))
        NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

// MARK: - Sidebar cells

final class MeetingCellView: NSView {
    private let tile = NSView()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let badge = KMPill(text: "")
    private let spinner = NSProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)

        tile.wantsLayer = true
        tile.layer?.cornerRadius = 9
        tile.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = KMTheme.amber
        icon.image = KMTheme.symbol("waveform", size: 15, weight: .semibold)
        tile.addSubview(icon)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = .systemFont(ofSize: 11)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isHidden = true

        addSubview(tile)
        addSubview(titleLabel)
        addSubview(metaLabel)
        addSubview(badge)
        addSubview(spinner)

        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 34),
            tile.heightAnchor.constraint(equalToConstant: 34),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),

            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            badge.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 6),

            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ m: Meeting) {
        let accent = KMTheme.accent(for: m.title)
        tile.layer?.backgroundColor = accent.withAlphaComponent(0.16).cgColor
        icon.contentTintColor = accent
        icon.image = KMTheme.symbol(m.transcribeOnly ? "text.alignleft" : "waveform",
                                    size: 15, weight: .semibold)
        titleLabel.stringValue = m.title

        let f = DateFormatter()
        f.locale = L10n.locale
        f.setLocalizedDateFormatFromTemplate("MMMdjm")
        var parts = [f.string(from: m.startedAt)]
        if m.durationSeconds > 0 {
            let mins = Int((m.durationSeconds / 60).rounded())
            parts.append("\(max(1, mins)) " + L10n.string("Minutes"))
        }
        if !m.sourceApp.isEmpty { parts.append(m.sourceApp) }
        metaLabel.stringValue = parts.joined(separator: "  ·  ")

        let busy = m.status == "processing"
        let showBadge = !busy && (m.transcribeOnly || m.status == "failed")
        badge.setHidden(!showBadge)
        if showBadge {
            if m.status == "failed" {
                badge.setText(L10n.string("Failed"))
                badge.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.14).cgColor
                // label color is baked into the pill's label; rebuild tint via subview lookup
                (badge.subviews.first as? NSTextField)?.textColor = .systemRed
            } else {
                badge.setText(L10n.string("Transcript only"))
                badge.layer?.backgroundColor = KMTheme.amber.withAlphaComponent(0.16).cgColor
                (badge.subviews.first as? NSTextField)?.textColor = KMTheme.amber
            }
        }
        spinner.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
}

final class KMGroupCell: NSView {
    init(title: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Library window

final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    private var split: NSSplitView!
    private var sidebar: NSVisualEffectView!
    private var rightHost: NSView!
    private var listTableView: NSTableView!
    private var searchField: NSSearchField!
    private var countLabel: NSTextField!
    private var footerLabel: NSTextField!
    private var emptyState: NSView!
    var searchFieldForTest: NSSearchField? { searchField }

    private var autoSearchObs: NSObjectProtocol?
    private var privacyPane: PrivacyPane!
    private var settingsPane: SettingsPane!
    private var statsPane: StatsPane!

    private var meetings: [Meeting] = []
    private enum Row { case header(String), meeting(Meeting) }
    private var rows: [Row] = []
    private var currentMeetingID: Int64?

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = L10n.string("Meeting Library")
        win.minSize = NSSize(width: 980, height: 620)
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
        applyScreenshotState()
    }

    // MARK: - Right-side panes (detail / privacy / settings / stats)

    enum SidePane { case detail, privacy, settings, stats }
    private var currentPane: SidePane = .detail
    private var detail: DetailView!

    private func ensurePanes() {
        if privacyPane == nil { privacyPane = PrivacyPane() }
    }

    func showPane(_ pane: SidePane) {
        ensurePanes()
        guard pane != currentPane || pane == .settings || pane == .stats else { return }

        if pane != .detail || currentPane != .detail {
            switch currentPane {
            case .detail:    detail.removeFromSuperview()
            case .privacy:   privacyPane.removeFromSuperview()
            case .settings:  settingsPane?.removeFromSuperview()
            case .stats:     statsPane?.removeFromSuperview()
            }
        }

        switch pane {
        case .detail:
            if detail.superview == nil { pin(detail, in: rightHost) }
        case .privacy:
            privacyPane.onBack = { [weak self] in self?.showPane(.detail) }
            pin(privacyPane, in: rightHost)
        case .settings:
            let sp = SettingsPane()
            sp.onBack = { [weak self] in self?.showPane(.detail) }
            settingsPane = sp
            pin(sp, in: rightHost)
        case .stats:
            let st = StatsPane()
            st.onBack = { [weak self] in self?.showPane(.detail) }
            statsPane = st
            pin(st, in: rightHost)
        }
        currentPane = pane
    }

    private func pin(_ v: NSView, in host: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            v.topAnchor.constraint(equalTo: host.topAnchor),
            v.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    /// Legacy path used by older call sites.
    func showDetail() { showPane(.detail) }

    // MARK: - Toolbar

    private static let toolbarID = "KMLibraryToolbar"

    private func installToolbar() {
        let tb = NSToolbar(identifier: Self.toolbarID)
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        tb.autosavesConfiguration = false
        window?.toolbar = tb
        window?.toolbarStyle = .unified
    }

    @objc private func toolbarSettings(_ sender: Any?) {
        showPane(currentPane == .settings ? .detail : .settings)
    }
    @objc private func toolbarStats(_ sender: Any?) {
        showPane(currentPane == .stats ? .detail : .stats)
    }
    @objc private func toolbarRecord(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.toggleRecording()
    }

    // MARK: - Layout

    private func buildUI() {
        guard let win = window else { return }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        win.contentView = content
        content.wantsLayer = true
        content.layer?.backgroundColor = KMTheme.canvas.cgColor

        split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin

        // Sidebar
        sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active

        searchField = NSSearchField()
        searchField.placeholderString = L10n.string("Search meetings…")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(reload)
        searchField.sendsSearchStringImmediately = true
        searchField.isContinuous = true
        searchField.delegate = self
        autoSearchObs = NotificationCenter.default.addObserver(forName: Notification.Name("KMAutoSearch"), object: nil, queue: .main) { [weak self] note in
            guard let q = note.object as? String, let sf = self?.searchField else { return }
            sf.stringValue = q
            self?.reload()
        }

        listTableView = NSTableView()
        let col = NSTableColumn(identifier: .init("m"))
        col.title = ""
        col.resizingMask = .autoresizingMask
        listTableView.addTableColumn(col)
        listTableView.headerView = nil
        listTableView.rowHeight = 64
        listTableView.intercellSpacing = NSSize(width: 0, height: 0)
        listTableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        listTableView.style = .plain
        listTableView.backgroundColor = .clear
        listTableView.selectionHighlightStyle = .regular
        listTableView.dataSource = self
        listTableView.delegate = self
        listTableView.target = self
        listTableView.action = #selector(rowClicked)
        let scroll = NSScrollView()
        scroll.documentView = listTableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // Header: brand mark + record shortcut
        let brandTile = NSView()
        brandTile.wantsLayer = true
        brandTile.layer?.cornerRadius = 7
        brandTile.layer?.backgroundColor = KMTheme.amber.withAlphaComponent(0.18).cgColor
        brandTile.translatesAutoresizingMaskIntoConstraints = false
        let brandIcon = NSImageView()
        brandIcon.image = KMTheme.symbol("waveform", size: 13, weight: .bold)
        brandIcon.contentTintColor = KMTheme.amber
        brandIcon.translatesAutoresizingMaskIntoConstraints = false
        brandTile.addSubview(brandIcon)
        let brand = NSTextField(labelWithString: "KinetMinutes")
        brand.font = .systemFont(ofSize: 12.5, weight: .semibold)
        brand.textColor = .labelColor
        brand.translatesAutoresizingMaskIntoConstraints = false

        let recordBtn = KMIconButton(symbol: "record.circle", tooltip: L10n.string("Start Recording"), tint: KMTheme.amber)
        recordBtn.target = self
        recordBtn.action = #selector(toolbarRecord(_:))
        recordBtn.translatesAutoresizingMaskIntoConstraints = false

        let brandSpacer = NSView()
        brandSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        brandSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let brandRow = NSStackView(views: [brandTile, brand, brandSpacer, recordBtn])
        brandRow.orientation = .horizontal
        brandRow.alignment = .centerY
        brandRow.spacing = 8
        brandRow.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: L10n.string("Meeting Library"))
        heading.font = .systemFont(ofSize: 20, weight: .bold)
        heading.translatesAutoresizingMaskIntoConstraints = false
        countLabel = NSTextField(labelWithString: "")
        countLabel.font = .systemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        let headingRow = NSStackView(views: [heading, countLabel])
        headingRow.orientation = .horizontal
        headingRow.alignment = .firstBaseline
        headingRow.spacing = 8
        headingRow.translatesAutoresizingMaskIntoConstraints = false

        footerLabel = NSTextField(labelWithString: "")
        footerLabel.font = .systemFont(ofSize: 10.5)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        let footerIcon = NSImageView()
        footerIcon.image = KMTheme.symbol("lock.fill", size: 9, weight: .semibold)
        footerIcon.contentTintColor = .tertiaryLabelColor
        footerIcon.translatesAutoresizingMaskIntoConstraints = false
        let footer = NSStackView(views: [footerIcon, footerLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 4
        footer.translatesAutoresizingMaskIntoConstraints = false

        emptyState = buildSidebarEmptyState()
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true

        sidebar.addSubview(brandRow)
        sidebar.addSubview(headingRow)
        sidebar.addSubview(searchField)
        sidebar.addSubview(scroll)
        sidebar.addSubview(footer)
        sidebar.addSubview(emptyState)

        NSLayoutConstraint.activate([
            brandTile.widthAnchor.constraint(equalToConstant: 22),
            brandTile.heightAnchor.constraint(equalToConstant: 22),
            brandIcon.centerXAnchor.constraint(equalTo: brandTile.centerXAnchor),
            brandIcon.centerYAnchor.constraint(equalTo: brandTile.centerYAnchor),

            brandRow.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 14),
            brandRow.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            brandRow.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),

            headingRow.topAnchor.constraint(equalTo: brandRow.bottomAnchor, constant: 16),
            headingRow.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            headingRow.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -16),

            searchField.topAnchor.constraint(equalTo: headingRow.bottomAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            footer.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -10),

            emptyState.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            emptyState.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -20),
            emptyState.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            emptyState.bottomAnchor.constraint(equalTo: footer.topAnchor),
        ])

        // Right: detail / panes host
        rightHost = NSView()
        rightHost.wantsLayer = true
        rightHost.layer?.backgroundColor = KMTheme.canvas.cgColor
        detail = DetailView()

        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(rightHost)
        sidebar.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        rightHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rightHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        split.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        split.autoresizingMask = [.width, .height]
        split.setPosition(310, ofDividerAt: 0)
        content.addSubview(split)
        content.autoresizesSubviews = true
        pin(detail, in: rightHost)
        DispatchQueue.main.async { self.split.setPosition(310, ofDividerAt: 0) }
    }

    private func buildSidebarEmptyState() -> NSView {
        let box = NSView()
        let icon = NSImageView()
        icon.image = KMTheme.symbol("waveform.circle", size: 40, weight: .light)
        icon.contentTintColor = KMTheme.amber.withAlphaComponent(0.75)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: L10n.string("No meetings yet"))
        title.font = .systemFont(ofSize: 13.5, weight: .semibold)
        title.alignment = .center
        let hint = NSTextField(wrappingLabelWithString: L10n.string("Start your first meeting from the menu bar. Everything stays on this Mac."))
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.preferredMaxLayoutWidth = 220
        let stack = NSStackView(views: [icon, title, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 230),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 44),
        ])
        return box
    }

    // MARK: - Data

    @objc func reload() {
        let q = searchField?.stringValue
        let keepID = currentMeetingID
        meetings = MeetingStore.shared.allMeetings(search: q)
        rows = Self.groupedRows(meetings)
        listTableView.reloadData()
        listTableView.sizeLastColumnToFit()

        countLabel.stringValue = "\(meetings.count)"
        let totalMinutes = Int((meetings.reduce(0.0) { $0 + $1.durationSeconds } / 60).rounded())
        footerLabel.stringValue = "\(meetings.count) " + L10n.string("Meetings") + "  ·  \(totalMinutes) " + L10n.string("Minutes")
        emptyState.isHidden = !meetings.isEmpty

        if meetings.isEmpty {
            if let d = detail { d.show(meeting: nil) }
            currentMeetingID = nil
            return
        }
        // Preserve selection across reloads (search / pipeline updates).
        var targetRow = rows.firstIndex { if case .meeting(let m) = $0 { return m.id == keepID }; return false }
        if targetRow == nil { targetRow = rows.firstIndex { if case .meeting = $0 { return true }; return false } }
        if let r = targetRow, listTableView.selectedRow != r {
            listTableView.selectRowIndexes(.init(integer: r), byExtendingSelection: false)
            listTableView.scrollRowToVisible(r)
        }
        if let r = targetRow, case .meeting(let m) = rows[r] {
            currentMeetingID = m.id
            detail.show(meeting: m)
        }
    }

    private static func groupedRows(_ ms: [Meeting]) -> [Row] {
        var out: [Row] = []
        let cal = Calendar.current
        var lastKey = ""
        let now = Date()
        for m in ms {
            let key: String
            if cal.isDateInToday(m.startedAt) {
                key = L10n.string("Today")
            } else if cal.isDateInYesterday(m.startedAt) {
                key = L10n.string("Yesterday")
            } else if let days = cal.dateComponents([.day], from: m.startedAt, to: now).day, days < 7 {
                key = L10n.string("This week")
            } else {
                key = L10n.string("Earlier")
            }
            if key != lastKey {
                out.append(.header(key))
                lastKey = key
            }
            out.append(.meeting(m))
        }
        return out
    }

    @objc private func rowClicked() {
        let row = listTableView.clickedRow
        guard row >= 0, row < rows.count, case .meeting(let m) = rows[row] else { return }
        currentMeetingID = m.id
        detail.show(meeting: m)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = listTableView.selectedRow
        guard row >= 0, row < rows.count, case .meeting(let m) = rows[row] else { return }
        currentMeetingID = m.id
        detail.show(meeting: m)
    }

    func windowWillClose(_ notification: Notification) {}
    func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect) -> NSRect { rect }
    func windowDidResize(_ notification: Notification) {}

    // MARK: - Screenshot harness (debug only)

    /// Env hooks used by tools/shoot_all.sh:
    ///   KM_AUTO_OPEN=1        open the library on launch
    ///   KM_AUTO_TAB=0..4      preselect a detail tab
    ///   KM_AUTO_PANE=settings|stats|privacy
    ///   KM_SNAPSHOT=/path.png render the content view and quit
    private func applyScreenshotState() {
        let env = ProcessInfo.processInfo.environment
        if let tab = env["KM_AUTO_TAB"], let i = Int(tab) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.detail.selectTab(i)
            }
        }
        if let pane = env["KM_AUTO_PANE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                switch pane {
                case "settings": self?.showPane(.settings)
                case "stats": self?.showPane(.stats)
                case "privacy": self?.showPane(.privacy)
                default: break
                }
            }
        }
        guard let path = env["KM_SNAPSHOT"], !path.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            self?.captureSnapshot(to: path)
        }
    }

    private func captureSnapshot(to path: String) {
        guard let win = window, let content = win.contentView else { return }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(nil)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        // Prefer the requested path (unsandboxed screenshot build); fall back to
        // the container temp dir when the sandboxed build blocks it.
        let direct = URL(fileURLWithPath: path)
        var url = direct
        do {
            try data.write(to: direct)
        } catch {
            let name = (path as NSString).lastPathComponent
            url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? data.write(to: url)
        }
        NSLog("KM_SNAPSHOT wrote %@ (%dx%d) data=%@", url.path, rep.pixelsWide, rep.pixelsHigh, MeetingStore.shared.dataDir.path)
        NSApp.terminate(nil)
    }
}

extension LibraryWindowController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(reload), object: nil)
        perform(#selector(reload), with: nil, afterDelay: 0.15)
    }
}

extension LibraryWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 32 }
        return 64
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        KMRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            return KMGroupCell(title: title)
        case .meeting(let m):
            let cell = MeetingCellView()
            cell.configure(m)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        return true
    }
}

// F06: intercept kmplay:// link clicks
final class TimelineTextView: NSTextView {
    var onPlayLink: ((Double) -> Void)?
}

extension DetailView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOn link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == "kmplay",
              let sec = Double(url.host ?? String(url.absoluteString.dropFirst("kmplay://".count))) else {
            return true
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
    private let statusPill = KMPill(text: "")
    private lazy var tabBar = KMTabBar(titles: [
        L10n.string("Summary"), L10n.string("Decisions"), L10n.string("Action Items"),
        L10n.string("Timeline"), L10n.string("Transcript")
    ])
    private let text = TimelineTextView()
    private let card = NSView()
    private var scroll: NSScrollView!
    private let exportBtn = KMIconButton(symbol: "square.and.arrow.up", tooltip: L10n.string("Export"))
    private let deleteBtn = KMIconButton(symbol: "trash", tooltip: L10n.string("Delete"))
    private let renameBtn = KMIconButton(symbol: "pencil", tooltip: L10n.string("Rename"))
    private let genNotesBtn = NSButton(title: L10n.string("Generate Notes…"), target: nil, action: nil)
    private let emptyView = NSView()
    private var player: AVAudioPlayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = KMTheme.canvas.cgColor

        headerTitle.font = .systemFont(ofSize: 21, weight: .bold)
        headerTitle.textColor = .labelColor
        headerTitle.lineBreakMode = .byTruncatingTail
        headerTitle.translatesAutoresizingMaskIntoConstraints = false

        headerMeta.font = .systemFont(ofSize: 11.5)
        headerMeta.textColor = .secondaryLabelColor
        headerMeta.lineBreakMode = .byTruncatingTail
        headerMeta.translatesAutoresizingMaskIntoConstraints = false

        statusPill.translatesAutoresizingMaskIntoConstraints = false
        statusPill.isHidden = true

        let metaRow = NSStackView(views: [headerMeta, statusPill])
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = 8
        metaRow.translatesAutoresizingMaskIntoConstraints = false

        tabBar.onSelect = { [weak self] _ in self?.tabChanged() }

        genNotesBtn.bezelStyle = .rounded
        genNotesBtn.controlSize = .small
        genNotesBtn.bezelColor = KMTheme.amber
        genNotesBtn.contentTintColor = .white
        genNotesBtn.target = self
        genNotesBtn.action = #selector(generateNotesTapped)
        genNotesBtn.translatesAutoresizingMaskIntoConstraints = false
        genNotesBtn.isHidden = true

        exportBtn.target = self; exportBtn.action = #selector(exportSheet)
        deleteBtn.target = self; deleteBtn.action = #selector(deleteMeeting)
        renameBtn.target = self; renameBtn.action = #selector(renameMeeting)

        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = KMTheme.hairline.cgColor
        card.layer?.backgroundColor = KMTheme.cardFill.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 22, height: 20)
        text.delegate = self
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true

        scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(scroll)

        let actions = NSStackView(views: [genNotesBtn, exportBtn, renameBtn, deleteBtn])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 4
        actions.translatesAutoresizingMaskIntoConstraints = false

        addSubview(headerTitle)
        addSubview(metaRow)
        addSubview(tabBar)
        addSubview(card)
        addSubview(actions)

        buildEmptyState()

        NSLayoutConstraint.activate([
            headerTitle.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            headerTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            headerTitle.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -16),

            metaRow.topAnchor.constraint(equalTo: headerTitle.bottomAnchor, constant: 5),
            metaRow.leadingAnchor.constraint(equalTo: headerTitle.leadingAnchor),
            metaRow.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -16),

            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            actions.topAnchor.constraint(equalTo: topAnchor, constant: 20),

            tabBar.topAnchor.constraint(equalTo: metaRow.bottomAnchor, constant: 14),
            tabBar.leadingAnchor.constraint(equalTo: headerTitle.leadingAnchor),

            card.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 12),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),

            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: card.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildEmptyState() {
        let icon = NSImageView()
        icon.image = KMTheme.symbol("waveform.circle", size: 46, weight: .ultraLight)
        icon.contentTintColor = KMTheme.amber.withAlphaComponent(0.65)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: L10n.string("No meeting selected"))
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.alignment = .center
        let hint = NSTextField(wrappingLabelWithString: L10n.string("Pick a meeting on the left, or start recording from the menu bar."))
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.preferredMaxLayoutWidth = 320
        let stack = NSStackView(views: [icon, title, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyView.addSubview(stack)
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyView)
        NSLayoutConstraint.activate([
            emptyView.leadingAnchor.constraint(equalTo: leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyView.topAnchor.constraint(equalTo: topAnchor),
            emptyView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyView.centerYAnchor, constant: -10),
            stack.widthAnchor.constraint(lessThanOrEqualTo: emptyView.widthAnchor, constant: -80),
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 50),
        ])
        emptyView.isHidden = true
    }

    func show(meeting: Meeting?) {
        self.meeting = meeting
        let hasMeeting = meeting != nil
        headerTitle.isHidden = !hasMeeting
        headerMeta.isHidden = !hasMeeting
        statusPill.isHidden = !hasMeeting
        tabBar.isHidden = !hasMeeting
        card.isHidden = !hasMeeting
        exportBtn.isHidden = !hasMeeting
        deleteBtn.isHidden = !hasMeeting
        renameBtn.isHidden = !hasMeeting
        emptyView.isHidden = hasMeeting

        guard let m = meeting else {
            headerTitle.stringValue = ""
            player?.stop(); player = nil
            return
        }
        headerTitle.stringValue = m.title
        let df = DateFormatter()
        df.locale = L10n.locale
        df.setLocalizedDateFormatFromTemplate("MMMdjm")
        var meta = df.string(from: m.startedAt)
        if m.durationSeconds > 0 {
            let mins = Int((m.durationSeconds / 60).rounded())
            meta += "  ·  " + (mins >= 1 ? "\(mins) " + L10n.string("Minutes")
                                         : "\(Int(m.durationSeconds)) " + L10n.string("Seconds"))
        }
        if !m.sourceApp.isEmpty { meta += "  ·  " + m.sourceApp }
        if m.status == "processing" { meta += "  ·  " + L10n.string("Generating…") }
        if m.status == "failed" { meta += "  ·  " + L10n.string("Failed") }
        headerMeta.stringValue = meta

        let isTO = m.transcribeOnly
        let hasNotes = !(m.summary ?? "").isEmpty && m.status != "failed"
        let hasTranscript = !(m.transcript ?? "").isEmpty
        let busy = m.status == "processing"
        let failed = m.status == "failed"
        let showGen = busy || (isTO ? !hasNotes : failed)

        statusPill.isHidden = !(isTO && !hasNotes)
        if isTO && !hasNotes { statusPill.setText(L10n.string("Transcript only")) }

        genNotesBtn.isHidden = !showGen
        genNotesBtn.isEnabled = !busy && hasTranscript
        genNotesBtn.title = busy
            ? L10n.string("Generating notes…")
            : (failed ? L10n.string("Retry") : L10n.string("Generate Notes…"))

        tabChanged()
    }

    /// Preselect a tab (screenshot harness).
    func selectTab(_ index: Int) {
        tabBar.select(index)
        tabChanged()
    }

    // MARK: - Rendering

    private static let bodyFont = NSFont.systemFont(ofSize: 13.5)
    private static let bodyColor = NSColor.labelColor

    private static func bodyStyle(spacing: CGFloat = 4) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = spacing
        p.paragraphSpacing = 2
        return p
    }

    private static func heading(_ s: String) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 16
        p.paragraphSpacing = 7
        return NSAttributedString(string: s + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.9,
            .paragraphStyle: p,
        ])
    }

    private static let headings: Set<String> = [
        "OVERVIEW", "KEY POINTS", "SUMMARY", "DECISIONS", "ACTION ITEMS",
        "会议概览", "要点", "摘要", "决议", "待办", "风险", "待解问题", "下一步",
        "會議概覽", "要點", "摘要", "決議", "待辦", "風險", "待解問題",
        "概要", "要点", "決定事項", "アクション", "リスク", "未解決の論点", "次のステップ",
        "요약", "개요", "핵심", "결정 사항", "할 일", "리스크", "미해결 질문", "다음 단계",
        "RÉSUMÉ", "APERÇU", "POINTS CLÉS", "DÉCISIONS", "ACTIONS",
        "RISQUES", "QUESTIONS OUVERTES", "PROCHAINES ÉTAPES",
        "ÜBERBLICK", "KERNPUNKTE", "ZUSAMMENFASSUNG", "ENTSCHEIDUNGEN", "AUFGABEN",
        "RISIKEN", "OFFENE FRAGEN", "NÄCHSTE SCHRITTE",
        "RESUMEN", "PUNTOS CLAVE", "DECISIONES", "TAREAS",
        "RIESGOS", "PREGUNTAS ABIERTAS", "PRÓXIMOS PASOS",
    ]

    static func styledSummary(_ raw: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = raw.components(separatedBy: "\n")
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                out.append(NSAttributedString(string: "\n"))
                continue
            }
            let asciiUpper = t.unicodeScalars.allSatisfy { $0.value < 128 }
                && t == t.uppercased()
                && t.rangeOfCharacter(from: .letters) != nil
                && t.count <= 26
            if headings.contains(t) || asciiUpper {
                out.append(heading(t))
                continue
            }
            if t.hasPrefix("•") || t.hasPrefix("-") || t.hasPrefix("*") {
                let p = NSMutableParagraphStyle()
                p.lineSpacing = 4
                p.firstLineHeadIndent = 4
                p.headIndent = 20
                p.paragraphSpacing = 6
                p.tabStops = [NSTextTab(textAlignment: .left, location: 20)]
                let marker = NSAttributedString(string: "\u{2022}\t", attributes: [
                    .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
                    .foregroundColor: KMTheme.amber,
                    .paragraphStyle: p,
                ])
                let rest = t.drop { $0 == "•" || $0 == "-" || $0 == "*" }
                    .trimmingCharacters(in: .whitespaces)
                out.append(marker)
                out.append(NSAttributedString(string: rest + "\n", attributes: [
                    .font: bodyFont,
                    .foregroundColor: bodyColor,
                    .paragraphStyle: p,
                ]))
                continue
            }
            out.append(NSAttributedString(string: t + "\n", attributes: [
                .font: bodyFont,
                .foregroundColor: bodyColor,
                .paragraphStyle: bodyStyle(),
            ]))
        }
        return out
    }

    private static func styledDecisions(_ items: [String]) -> NSAttributedString {
        guard !items.isEmpty else { return placeholder(L10n.string("No decisions captured.")) }
        let out = NSMutableAttributedString()
        for (i, d) in items.enumerated() {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 4
            p.paragraphSpacing = i == items.count - 1 ? 0 : 12
            p.firstLineHeadIndent = 2
            p.headIndent = 24
            p.tabStops = [NSTextTab(textAlignment: .left, location: 24)]
            out.append(NSAttributedString(string: "\u{2713}\t", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: KMTheme.green,
                .paragraphStyle: p,
            ]))
            out.append(NSAttributedString(string: d, attributes: [
                .font: bodyFont,
                .foregroundColor: bodyColor,
                .paragraphStyle: p,
            ]))
            if i != items.count - 1 { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }

    private static func styledActions(_ items: [Meeting.ActionItem]) -> NSAttributedString {
        guard !items.isEmpty else { return placeholder(L10n.string("No action items captured.")) }
        let out = NSMutableAttributedString()
        for (i, a) in items.enumerated() {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 3
            p.paragraphSpacing = i == items.count - 1 ? 0 : 14
            p.firstLineHeadIndent = 2
            p.headIndent = 24
            p.tabStops = [NSTextTab(textAlignment: .left, location: 24)]
            out.append(NSAttributedString(string: "\u{2610}\t", attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: p,
            ]))
            out.append(NSAttributedString(string: a.task, attributes: [
                .font: NSFont.systemFont(ofSize: 13.5, weight: .medium),
                .foregroundColor: bodyColor,
                .paragraphStyle: p,
            ]))
            var detail: [String] = []
            if !a.owner.isEmpty { detail.append(a.owner) }
            if !a.due.isEmpty { detail.append(a.due) }
            if !detail.isEmpty {
                out.append(NSAttributedString(string: "\n\t" + detail.joined(separator: "  ·  "), attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: KMTheme.amber,
                    .paragraphStyle: p,
                ]))
            }
            if i != items.count - 1 { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }

    private static func placeholder(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    /// Parse "[MM:SS] Speaker: text" transcripts into a readable page.
    static func styledTranscript(_ raw: String) -> NSAttributedString {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return placeholder(L10n.string("No transcript yet."))
        }
        let out = NSMutableAttributedString()
        let regex = try? NSRegularExpression(pattern: "^\\[(\\d{1,2}:\\d{2})\\]\\s*([^:\\n]{1,24})[:：]\\s*(.*)$")
        for line in raw.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { out.append(NSAttributedString(string: "\n")); continue }
            let ns = t as NSString
            if let m = regex?.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) {
                let stamp = ns.substring(with: m.range(at: 1))
                let speaker = ns.substring(with: m.range(at: 2))
                let body = ns.substring(with: m.range(at: 3))
                let p = NSMutableParagraphStyle()
                p.lineSpacing = 4
                p.paragraphSpacing = 10
                out.append(NSAttributedString(string: stamp + "  ", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
                    .foregroundColor: KMTheme.amber,
                    .paragraphStyle: p,
                ]))
                out.append(NSAttributedString(string: speaker + "  ", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: p,
                ]))
                out.append(NSAttributedString(string: body + "\n", attributes: [
                    .font: bodyFont,
                    .foregroundColor: bodyColor,
                    .paragraphStyle: p,
                ]))
            } else {
                out.append(NSAttributedString(string: t + "\n", attributes: [
                    .font: bodyFont,
                    .foregroundColor: bodyColor,
                    .paragraphStyle: bodyStyle(),
                ]))
            }
        }
        return out
    }

    @objc private func tabChanged() {
        guard let m = meeting else {
            apply(Self.placeholder(L10n.string("No meetings yet")))
            return
        }
        switch tabBar.selectedIndex {
        case 0:
            if let s = m.summary, !s.isEmpty, m.status != "failed" {
                apply(Self.styledSummary(s))
            } else if m.status == "processing" {
                apply(Self.placeholder(L10n.string("Generating…")))
            } else if m.status == "failed" {
                apply(Self.placeholder(L10n.string("Notes generation failed")))
            } else {
                apply(Self.placeholder(L10n.string("Model not downloaded yet") + "\n\n" + L10n.string("Choose a transcription model in Settings to enable notes.")))
            }
        case 1:
            apply(Self.styledDecisions(m.decisions))
        case 2:
            apply(Self.styledActions(m.actions))
        case 3:
            if m.segments.isEmpty {
                apply(Self.placeholder(L10n.string("No timeline yet.")))
            } else {
                apply(Self.timelineAttr(from: m.segments))
            }
        default:
            apply(Self.styledTranscript(m.transcript ?? ""))
        }
    }

    private func apply(_ attr: NSAttributedString) {
        text.textStorage?.setAttributedString(attr)
        text.scrollToBeginningOfDocument(nil)
    }

    /// F06: build timeline with clickable [MM:SS] links that seek the audio player.
    static func timelineAttr(from segments: [Meeting.Segment]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, g) in segments.enumerated() {
            let s = Int(g.start)
            let stamp = String(format: "[%02d:%02d]", s / 60, s % 60)
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 4
            p.paragraphSpacing = 12
            let link = NSAttributedString(string: stamp + "  ", attributes: [
                .link: URL(string: "kmplay://\(g.start)")!,
                .foregroundColor: KMTheme.amber,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .paragraphStyle: p,
            ])
            out.append(link)
            if let sp = g.speaker {
                let badge: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: sp == "me" ? KMTheme.blue : KMTheme.coral,
                    .paragraphStyle: p,
                ]
                out.append(NSAttributedString(string: Exporters.speakerTag(sp) + " ", attributes: badge))
            }
            let body = NSAttributedString(string: g.text + (i == segments.count - 1 ? "" : "\n"), attributes: [
                .font: NSFont.systemFont(ofSize: 13.5),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: p,
            ])
            out.append(body)
        }
        return out
    }

    // MARK: - Actions

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

    @objc private func generateNotesTapped() {
        guard let m = meeting, m.status != "processing" else { return }
        let isRetry = m.status == "failed"
        if m.transcribeOnly {
            guard isRetry || (m.summary ?? "").isEmpty else { return }
        } else {
            guard isRetry, !(m.transcript ?? "").isEmpty else { return }
        }
        show(meeting: m)
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
        case "pdf": Exporters.savePDF(Exporters.markdown(for: m), name: safeName)
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

// MARK: - Library toolbar

extension LibraryWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("record"), .flexibleSpace, .init("settings"), .init("stats")]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("record"), .flexibleSpace, .init("settings"), .init("stats")]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier.rawValue {
        case "record":
            item.label = L10n.string("Start Recording")
            item.toolTip = L10n.string("Start Recording")
            item.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(toolbarRecord(_:))
        case "settings":
            item.label = L10n.string("Settings")
            item.toolTip = L10n.string("Settings")
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(toolbarSettings(_:))
        case "stats":
            item.label = L10n.string("Meeting Statistics")
            item.toolTip = L10n.string("Meeting Statistics")
            item.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(toolbarStats(_:))
        default:
            return nil
        }
        return item
    }
}
