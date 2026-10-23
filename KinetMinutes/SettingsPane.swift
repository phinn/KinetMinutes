// SettingsPane.swift — 1.3 settings panel: default recording mode, ASR model
// management (download/status), free-quota display. Pure AppKit, same style
// as PrivacyPane. Four-language strings via L10n table.

import Cocoa
import LocalLLMKitTranscription

final class SettingsPane: NSView {
    // Model variants offered in the UI. Pipeline reads "whisperModel" per run,
    // so switching applies immediately (already-recorded audio is unaffected).
    static let variants: [(id: String, label: String)] = [
        ("large-v3-turbo", "large-v3-turbo — Recommended (≈1.5 GB)"),
        ("large-v3",       "large-v3 — Most accurate (≈3 GB)"),
        ("small",          "small — Light (≈500 MB)"),
        ("base",           "base — Fastest (≈150 MB)"),
    ]

    // MARK: - Recording mode row
    private let modeLabel = sectionLabel("Recording mode")
    private let modeSegment = NSSegmentedControl(labels: [L10n.string("Full meeting notes"), L10n.string("Transcript only")],
                                                 trackingMode: .selectOne, target: nil, action: nil)
    private let modeHint = hintLabel("Mode hint")

    // MARK: - Model row
    private let modelLabel = sectionLabel("Transcription model")
    private let modelPop = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelStatus = hintLabel("")
    private let modelProgress = NSProgressIndicator(frame: .zero)
    private let downloadBtn = NSButton(title: L10n.string("Download"), target: nil, action: nil)
    private var downloadTask: Task<Void, Never>?

    // MARK: - Quota row
    private let quotaLabel = sectionLabel("AI notes this month")
    private let quotaValue = NSTextField(wrappingLabelWithString: "")
    private let quotaHint = hintLabel("Quota hint")
    private let modelHint = hintLabel("Model hint")

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 430))

        downloadBtn.target = self
        downloadBtn.action = #selector(downloadTapped)
        downloadBtn.bezelStyle = .rounded
        modelProgress.isIndeterminate = false
        modelProgress.minValue = 0
        modelProgress.maxValue = 1
        modelProgress.translatesAutoresizingMaskIntoConstraints = false
        modelProgress.widthAnchor.constraint(equalToConstant: 200).isActive = true
        modelProgress.isHidden = true

        let current = UserDefaults.standard.string(forKey: "whisperModel") ?? "large-v3-turbo"
        for v in Self.variants {
            let item = NSMenuItem(title: v.label, action: nil, keyEquivalent: "")
            item.representedObject = v.id
            modelPop.menu?.addItem(item)
            if v.id == current { modelPop.select(item) }
        }
        modelPop.target = self
        modelPop.action = #selector(modelChanged)

        modeSegment.target = self
        modeSegment.action = #selector(modeChanged)
        modeSegment.selectedSegment = UserDefaults.standard.bool(forKey: "autoTranscribeOnly") ? 1 : 0

        let modelRow = NSStackView(views: [modelPop, downloadBtn, modelStatus, modelProgress])
        modelRow.orientation = .horizontal
        modelRow.alignment = .centerY
        modelRow.spacing = 10

        let stack = NSStackView(views: [
            modeLabel, modeSegment, modeHint,
            modelLabel, modelRow, modelHint,
            quotaLabel, quotaValue, quotaHint,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(20, after: modeHint)
        stack.setCustomSpacing(20, after: modelHint)
        stack.setCustomSpacing(20, after: quotaValue)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])

        refreshModelStatus()
        refreshQuota()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Actions

    @objc private func modeChanged() {
        // "Full meeting notes" = no tag; auto-record honors this at start time.
        UserDefaults.standard.set(modeSegment.selectedSegment == 1, forKey: "autoTranscribeOnly")
    }

    @objc private func modelChanged() {
        guard let v = modelPop.selectedItem?.representedObject as? String else { return }
        UserDefaults.standard.set(v, forKey: "whisperModel")
        refreshModelStatus()
    }

    @objc private func downloadTapped() {
        guard downloadTask == nil,
              let v = modelPop.selectedItem?.representedObject as? String else { return }
        downloadBtn.isEnabled = false
        modelProgress.isHidden = false
        modelProgress.doubleValue = 0
        modelStatus.stringValue = L10n.string("Downloading…")
        let endpoint = UserDefaults.standard.string(forKey: "hfEndpoint")
        downloadTask = Task { [weak self] in
            do {
                let _ = try await WhisperKitTranscriptionProvider.download(
                    model: v, endpoint: endpoint) { frac in
                        Task { @MainActor in self?.modelProgress.doubleValue = frac }
                    }
                await MainActor.run {
                    self?.downloadTask = nil
                    self?.refreshModelStatus()
                }
            } catch {
                await MainActor.run {
                    self?.downloadTask = nil
                    self?.modelProgress.isHidden = true
                    self?.downloadBtn.isEnabled = true
                    self?.modelStatus.stringValue = L10n.string("Download failed")
                }
            }
        }
    }

    // MARK: - State refresh

    private func refreshModelStatus() {
        let v = UserDefaults.standard.string(forKey: "whisperModel") ?? "large-v3-turbo"
        let store = WhisperModelStore()
        if downloadTask != nil { return }   // download UI owns the status label
        if store.isDownloaded(v) {
            let mb = ByteCountFormatter.string(fromByteCount: Self.folderSize(store.localFolder(for: v)), countStyle: .file)
            modelStatus.stringValue = L10n.string("Downloaded") + " (\(mb))"
        } else {
            modelStatus.stringValue = L10n.string("Not downloaded")
        }
        downloadBtn.isHidden = store.isDownloaded(v)
        modelProgress.isHidden = downloadTask == nil
    }

    private func refreshQuota() {
        if MinutesPipeline.isPro() {
            quotaValue.stringValue = L10n.string("Unlimited — Pro active")
        } else {
            let used = MinutesPipeline.notesUsedThisMonth()
            quotaValue.stringValue = L10n.string("%d of %d used", used, MinutesPipeline.freeMonthlyLimit)
        }
    }

    private static func folderSize(_ url: URL) -> Int64 {
        guard let e = try? FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    private static func sectionLabel(_ key: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: L10n.string(key))
        l.font = .systemFont(ofSize: 14, weight: .semibold)
        return l
    }
    private static func hintLabel(_ key: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: L10n.string(key))
        l.textColor = .secondaryLabelColor
        l.font = .systemFont(ofSize: 12)
        l.preferredMaxLayoutWidth = 420
        return l
    }
}

// MARK: - Window controller (AppDelegate opens/closes)

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 430),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = L10n.string("Settings…")
        w.contentView = SettingsPane()
        w.center()
        w.isReleasedWhenClosed = false
        self.init(window: w)
    }

    func show() {
        // Recreate the pane so model/quota state is fresh on every open.
        window?.contentView = SettingsPane()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
