// Exporters.swift — Markdown / TXT / SRT export (NSSavePanel, user-selected path)

import AppKit
import Foundation

enum Exporters {
    static func markdown(for m: Meeting) -> String {
        var out = "# \(m.title)\n\n"
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        out += "- \(f.string(from: m.startedAt)) · \(m.sourceApp) · \(Int(m.durationSeconds / 60)) min\n\n"

        if let s = m.summary, !s.isEmpty { out += "## \(L10n.string("Summary"))\n\n\(s)\n\n" }
        let dec = m.decisions
        if !dec.isEmpty {
            out += "## \(L10n.string("Decisions"))\n\n"
            out += dec.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        let acts = m.actions
        if !acts.isEmpty {
            out += "## \(L10n.string("Action Items"))\n\n"
            out += acts.map { a in
                var line = "- [ ] \(a.task)"
                if !a.owner.isEmpty { line += " — \(a.owner)" }
                if !a.due.isEmpty { line += " (\(a.due))" }
                return line
            }.joined(separator: "\n") + "\n\n"
        }
        let segs = m.segments
        if !segs.isEmpty {
            out += "## \(L10n.string("Timeline"))\n\n"
            out += segs.map { g in "\(timeString(g.start))  \(g.text)" }.joined(separator: "\n\n") + "\n\n"
        } else if let t = m.transcript, !t.isEmpty {
            out += "## \(L10n.string("Transcript"))\n\n\(t)\n"
        }
        return out
    }

    static func txt(for m: Meeting) -> String {
        var out = "\(m.title)\n"
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        out += f.string(from: m.startedAt) + " · \(m.sourceApp)\n\n"
        if let s = m.summary { out += s + "\n\n" }
        for d in m.decisions { out += "[D] \(d)\n" }
        for a in m.actions { out += "[TODO] \(a.task) — \(a.owner) \(a.due)\n" }
        out += "\n" + (m.transcript ?? "")
        return out
    }

    static func srt(for m: Meeting) -> String {
        func stamp(_ t: Double) -> String {
            let ms = Int((t - Double(Int(t))) * 1000)
            let s = Int(t)
            return String(format: "%02d:%02d:%02d,%03d", s / 3600, s / 60 % 60, s % 60, ms)
        }
        var out = ""
        for (i, g) in m.segments.enumerated() {
            out += "\(i + 1)\n\(stamp(g.start)) --> \(stamp(g.end))\n\(g.text)\n\n"
        }
        if out.isEmpty, let t = m.transcript { return "1\n00:00:00,000 --> 00:00:05,000\n\(t)\n" }
        return out
    }

    static func save(_ content: String, name: String, ext: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.init(filenameExtension: ext) ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? content.data(using: .utf8)?.write(to: url)
    }

    /// F08 Pro: PDF export. Renders the markdown-ish content via Cocoa text
    /// system (NSAttributedString → NSPrintOperation PDF) — no deps, CJK-safe.
    static func savePDF(_ content: String, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // plain-text render of the markdown structure (headers bolded by line)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        let attr = NSMutableAttributedString()
        for line in content.components(separatedBy: "\n") {
            let bold = line.hasPrefix("#")
            let font: NSFont = bold ? .boldSystemFont(ofSize: line.hasPrefix("# ") ? 16 : 13)
                                    : .systemFont(ofSize: 11)
            attr.append(NSAttributedString(string: line + "\n", attributes: [
                .font: font, .paragraphStyle: para
            ]))
        }

        // A4-ish page, 72 dpi points
        let pageRect = NSRect(x: 0, y: 0, width: 595, height: 842)
        let margin: CGFloat = 48
        let textView = NSTextView(frame: NSRect(x: margin, y: margin,
                                                width: pageRect.width - margin * 2,
                                                height: pageRect.height - margin * 2))
        textView.textStorage?.setAttributedString(attr)

        let printInfo = NSPrintInfo()
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.topMargin = margin; printInfo.bottomMargin = margin
        printInfo.leftMargin = margin; printInfo.rightMargin = margin
        printInfo.paperSize = pageRect.size
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let op = NSPrintOperation(view: textView, printInfo: printInfo)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.run()
    }

    private static func timeString(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
