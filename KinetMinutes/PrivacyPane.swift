// PrivacyPane.swift — F10 privacy panel: zero-upload statement + data location + delete-all

import AppKit

final class PrivacyPane: NSView {
    /// Embedded pane: the library window swaps the detail view back on Back.
    var onBack: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = KMTheme.canvas.cgColor

        let backBtn = KMIconButton(symbol: "chevron.left", tooltip: L10n.string("Back"))
        backBtn.target = self
        backBtn.action = #selector(backTapped)

        let title = NSTextField(labelWithString: L10n.string("Privacy"))
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let header = NSStackView(views: [backBtn, title])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 4

        let shieldTile = NSView()
        shieldTile.wantsLayer = true
        shieldTile.layer?.cornerRadius = 15
        shieldTile.layer?.backgroundColor = KMTheme.green.withAlphaComponent(0.15).cgColor
        let shield = NSImageView()
        shield.image = KMTheme.symbol("lock.shield.fill", size: 24, weight: .semibold)
        shield.contentTintColor = KMTheme.green
        shield.translatesAutoresizingMaskIntoConstraints = false
        shieldTile.addSubview(shield)
        NSLayoutConstraint.activate([
            shieldTile.widthAnchor.constraint(equalToConstant: 50),
            shieldTile.heightAnchor.constraint(equalToConstant: 50),
            shield.centerXAnchor.constraint(equalTo: shieldTile.centerXAnchor),
            shield.centerYAnchor.constraint(equalTo: shieldTile.centerYAnchor),
        ])

        let head = NSTextField(wrappingLabelWithString: L10n.string("Zero upload. By design."))
        head.font = .systemFont(ofSize: 25, weight: .bold)
        head.preferredMaxLayoutWidth = 560

        let body = NSTextField(wrappingLabelWithString: L10n.string("Privacy body"))
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 560

        let hero = NSStackView(views: [shieldTile, head, body])
        hero.orientation = .vertical
        hero.alignment = .leading
        hero.spacing = 8
        hero.setCustomSpacing(14, after: shieldTile)

        let loc = NSTextField(labelWithString: L10n.string("Where your data lives"))
        loc.font = .systemFont(ofSize: 13.5, weight: .semibold)

        let locBody = NSTextField(wrappingLabelWithString: L10n.string("Data location body"))
        locBody.font = .systemFont(ofSize: 12.5)
        locBody.textColor = .secondaryLabelColor
        locBody.preferredMaxLayoutWidth = 560

        let locCard = NSView()
        locCard.wantsLayer = true
        locCard.layer?.cornerRadius = 12
        locCard.layer?.borderWidth = 1
        locCard.layer?.borderColor = KMTheme.hairline.cgColor
        locCard.layer?.backgroundColor = KMTheme.cardFill.cgColor
        let locStack = NSStackView(views: [loc, locBody])
        locStack.orientation = .vertical
        locStack.alignment = .leading
        locStack.spacing = 6
        locStack.translatesAutoresizingMaskIntoConstraints = false
        locCard.addSubview(locStack)
        NSLayoutConstraint.activate([
            locStack.leadingAnchor.constraint(equalTo: locCard.leadingAnchor, constant: 18),
            locStack.trailingAnchor.constraint(equalTo: locCard.trailingAnchor, constant: -18),
            locStack.topAnchor.constraint(equalTo: locCard.topAnchor, constant: 16),
            locStack.bottomAnchor.constraint(equalTo: locCard.bottomAnchor, constant: -16),
            locCard.widthAnchor.constraint(equalToConstant: 600),
        ])

        let del = NSButton(title: L10n.string("Delete all data"), target: self, action: #selector(deleteAll))
        del.bezelStyle = .rounded
        del.controlSize = .large
        // `contentTintColor` is ignored by the rounded bezel; the attributed
        // title is what actually paints the destructive action red.
        del.attributedTitle = NSAttributedString(
            string: L10n.string("Delete all data"),
            attributes: [.foregroundColor: NSColor.systemRed])

        let column = NSStackView(views: [header, hero, locCard, del])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 16
        column.setCustomSpacing(26, after: header)
        column.setCustomSpacing(24, after: hero)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -26),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 660),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func backTapped() { onBack?() }

    @objc private func deleteAll() {
        let alert = NSAlert()
        alert.messageText = L10n.string("Delete everything?")
        alert.informativeText = L10n.string("This permanently removes all recordings, transcripts and notes on this Mac. This cannot be undone.")
        alert.addButton(withTitle: L10n.string("Delete all data"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        alert.alertStyle = .critical
        if alert.runModal() == .alertFirstButtonReturn {
            MeetingStore.shared.deleteAll()
        }
    }
}
