// PrivacyPane.swift — F10 privacy panel: zero-upload statement + data location + delete-all

import AppKit

final class PrivacyPane: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)

        let head = NSTextField(wrappingLabelWithString: L10n.string("Zero upload. By design."))
        head.font = .systemFont(ofSize: 17, weight: .bold)

        let body = NSTextField(wrappingLabelWithString: L10n.string("Privacy body"))
        body.textColor = .labelColor

        let loc = NSTextField(wrappingLabelWithString: L10n.string("Where your data lives"))
        loc.font = .systemFont(ofSize: 14, weight: .semibold)

        let locBody = NSTextField(wrappingLabelWithString: L10n.string("Data location body"))
        locBody.textColor = .secondaryLabelColor

        let del = NSButton(title: L10n.string("Delete all data"), target: self, action: #selector(deleteAll))
        del.bezelStyle = .rounded
        del.controlSize = .large

        let stack = NSStackView(views: [head, body, loc, locBody, del])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(24, after: body)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

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
