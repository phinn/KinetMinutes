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
    private let calPrefillCheck = NSButton(checkboxWithTitle: L10n.string("Prefill title from calendar"), target: nil, action: nil)
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
    /// 1.3: conversion exit on the quota row (hidden for Pro).
    private let upgradeBtn = NSButton(title: L10n.string("Upgrade to Pro…"), target: nil, action: nil)

    // MARK: - Mirror row (1.3: mainland-China HF endpoint)
    private let mirrorLabel = sectionLabel("Model download endpoint")
    private let mirrorField = NSTextField(string: "")
    private let mirrorHint = hintLabel("Endpoint hint")

    // MARK: - Storage row (1.3: audio disk usage management)
    private let storageLabel = sectionLabel("Recording storage")
    private let storageValue = NSTextField(wrappingLabelWithString: "")
    private let cleanupBtn = NSButton(title: L10n.string("Clear audio…"), target: nil, action: nil)
    private let retentionLabel = hintLabel("Audio auto-cleanup")
    private let retentionPop = NSPopUpButton(frame: .zero, pullsDown: false)
    // 1.3 P2: manual UI language
    private let langLabel = hintLabel("Interface language")
    private let langPop = NSPopUpButton(frame: .zero, pullsDown: false)

    /// [seconds or 0=off] shown as: 关 / 7 天 / 30 天 / 90 天
    static let retentionChoices: [(Int, String)] = [
        (0, "Off"), (7, "After 7 days"), (30, "After 30 days"), (90, "After 90 days"),
    ]

    /// 1.3: embedded in the library window like PrivacyPane — a Back row swaps
    /// the detail view back in (see LibraryWindowController.showSettings()).
    var onBack: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 640))

        downloadBtn.target = self
        downloadBtn.action = #selector(downloadTapped)
        downloadBtn.bezelStyle = .rounded
        modelProgress.isIndeterminate = false
        modelProgress.minValue = 0
        modelProgress.maxValue = 1
        modelProgress.translatesAutoresizingMaskIntoConstraints = false
        modelProgress.widthAnchor.constraint(equalToConstant: 120).isActive = true
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

        calPrefillCheck.state = (UserDefaults.standard.object(forKey: "prefillTitleFromCalendar") as? Bool ?? true) ? .on : .off
        calPrefillCheck.target = self
        calPrefillCheck.action = #selector(calPrefillChanged)

        // 1.3 layout: picker fills the row; download controls live on their
        // own line so status text never truncates.
        let downloadRow = NSStackView(views: [downloadBtn, modelProgress, modelStatus])
        downloadRow.orientation = .horizontal
        downloadRow.alignment = .centerY
        downloadRow.spacing = 10

        // 1.3: quota conversion exit + mirror endpoint + storage management.
        upgradeBtn.target = self
        upgradeBtn.action = #selector(upgradeTapped)
        upgradeBtn.bezelStyle = .rounded
        upgradeBtn.controlSize = .small

        mirrorField.placeholderString = "https://hf-mirror.com"
        mirrorField.target = self
        mirrorField.action = #selector(mirrorEdited)
        mirrorField.translatesAutoresizingMaskIntoConstraints = false
        mirrorField.widthAnchor.constraint(equalToConstant: 300).isActive = true

        cleanupBtn.target = self
        cleanupBtn.action = #selector(cleanupTapped)
        cleanupBtn.bezelStyle = .rounded
        cleanupBtn.controlSize = .small

        // 1.3: auto-cleanup picker — stored as days (0 = off)
        for (days, key) in Self.retentionChoices {
            let item = NSMenuItem(title: L10n.string(key), action: nil, keyEquivalent: "")
            item.representedObject = days
            retentionPop.menu?.addItem(item)
        }
        let savedDays = UserDefaults.standard.integer(forKey: "audioRetentionDays")
        let idx = Self.retentionChoices.firstIndex { $0.0 == savedDays } ?? 0
        retentionPop.selectItem(at: idx)
        retentionPop.target = self
        retentionPop.action = #selector(retentionChanged)
        retentionPop.controlSize = .small

        // 1.3 P2: interface language picker (en/ja/zh-Hans/zh-Hant/system)
        for (code, key) in [("", "System language"), ("en", "English"), ("ja", "日本語"),
                            ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"),
                            ("ko", "한국어"), ("fr", "Français"), ("de", "Deutsch"),
                            ("es", "Español")] {
            let item = NSMenuItem(title: code.isEmpty ? L10n.string(key) : key,
                                  action: nil, keyEquivalent: "")
            item.representedObject = code
            langPop.menu?.addItem(item)
        }
        let savedLang = UserDefaults.standard.string(forKey: "AppLanguage") ?? ""
        langPop.selectItem(at: max(0, langPop.indexOfItem(withRepresentedObject: savedLang)))
        langPop.target = self
        langPop.action = #selector(langChanged)
        langPop.controlSize = .small

        let quotaRow = NSStackView(views: [quotaValue, upgradeBtn])
        quotaRow.orientation = .horizontal
        quotaRow.alignment = .firstBaseline
        quotaRow.spacing = 10

        let storageRow = NSStackView(views: [storageValue, cleanupBtn])
        storageRow.orientation = .horizontal
        storageRow.alignment = .firstBaseline
        storageRow.spacing = 10

        // 1.3: auto-cleanup row (picker), sits under the storage row
        let retentionRow = NSStackView(views: [retentionLabel, retentionPop])
        retentionRow.orientation = .horizontal
        retentionRow.alignment = .centerY
        retentionRow.spacing = 10

        // 1.3 P2: language row
        let langRow = NSStackView(views: [langLabel, langPop])
        langRow.orientation = .horizontal
        langRow.alignment = .centerY
        langRow.spacing = 10

        // Embedded-pane header: Back + title (library swaps the detail pane back).
        let backBtn = KMIconButton(symbol: "chevron.left", tooltip: L10n.string("Back"))
        backBtn.target = self
        backBtn.action = #selector(backTapped)

        let title = NSTextField(labelWithString: L10n.string("Settings…").replacingOccurrences(of: "…", with: ""))
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let header = NSStackView(views: [backBtn, title])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 4

        // 1.4: each section is a rounded card on a calm canvas.
        let card1 = settingsCard([modeLabel, modeSegment, calPrefillCheck, modeHint])
        let card2 = settingsCard([modelLabel, modelPop, downloadRow, modelHint])
        let card3 = settingsCard([quotaLabel, quotaRow, quotaHint])
        let card4 = settingsCard([mirrorLabel, mirrorField, mirrorHint])
        let card5 = settingsCard([storageLabel, storageRow, retentionRow])
        let card6 = settingsCard([langRow])

        let column = NSStackView(views: [header, card1, card2, card3, card4, card5, card6])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.setCustomSpacing(18, after: header)
        column.translatesAutoresizingMaskIntoConstraints = false

        let doc = KMFlipView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(column)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            column.topAnchor.constraint(equalTo: doc.topAnchor, constant: 22),
            column.centerXAnchor.constraint(equalTo: doc.centerXAnchor),
            column.widthAnchor.constraint(equalToConstant: 620),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: doc.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -24),
            column.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -24),
        ])
        mirrorField.widthAnchor.constraint(equalToConstant: 560).isActive = true
        for v in [modeHint, modelHint, quotaHint, mirrorHint] {
            v.preferredMaxLayoutWidth = 560
        }

        mirrorField.stringValue = UserDefaults.standard.string(forKey: "hfEndpoint") ?? ""
        refreshModelStatus()
        refreshQuota()
        refreshStorage()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func settingsCard(_ views: [NSView]) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = KMTheme.hairline.cgColor
        card.layer?.backgroundColor = KMTheme.cardFill.cgColor
        let inner = NSStackView(views: views)
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 8
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            card.widthAnchor.constraint(equalToConstant: 620),
        ])
        return card
    }

    // MARK: - Actions

    /// Embedded pane: hand control back to the library detail view.
    @objc private func backTapped() { onBack?() }

    @objc private func modeChanged() {
        // "Full meeting notes" = no tag; auto-record honors this at start time.
        UserDefaults.standard.set(modeSegment.selectedSegment == 1, forKey: "autoTranscribeOnly")
    }

    @objc private func modelChanged() {
        guard let v = modelPop.selectedItem?.representedObject as? String else { return }
        UserDefaults.standard.set(v, forKey: "whisperModel")
        refreshModelStatus()
    }

    /// 1.3: mirror endpoint, trimmed; empty string = direct huggingface.co.
    /// Read lazily by the pipeline/downloader, so the next download or
    /// transcription picks it up — no restart.
    @objc private func mirrorEdited() {
        let trimmed = mirrorField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed.isEmpty ? nil : trimmed, forKey: "hfEndpoint")
    }

    /// 1.3: auto-cleanup choice; sweep runs on next app launch.
    @objc private func retentionChanged() {
        let days = retentionPop.selectedItem?.representedObject as? Int ?? 0
        UserDefaults.standard.set(days, forKey: "audioRetentionDays")
    }

    /// 1.3 P2: calendar prefill toggle (read by CalendarBridge before each start)
    @objc private func calPrefillChanged() {
        UserDefaults.standard.set(calPrefillCheck.state == .on, forKey: "prefillTitleFromCalendar")
    }

    /// 1.3 P2: manual UI language. Takes effect after relaunch (static titles).
    @objc private func langChanged() {
        let code = langPop.selectedItem?.representedObject as? String ?? ""
        L10n.appLanguageOverride = code
        let a = NSAlert()
        a.messageText = L10n.string("Restart to apply language")
        a.informativeText = L10n.string("The interface language changes after you quit and reopen KinetMinutes.")
        a.addButton(withTitle: L10n.string("Restart Now"))
        a.addButton(withTitle: L10n.string("Later"))
        if a.runModal() == .alertFirstButtonReturn {
            let url = Bundle.main.bundleURL
            NSApp.terminate {
                _ = NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
        }
    }

    /// 1.3: quota row conversion exit (hidden when Pro).
    @objc private func upgradeTapped() {
        (NSApp.delegate as? AppDelegate)?.upgradePro()
        refreshQuota()   // purchase sheet may succeed instantly (previous purchase)
    }

    /// 1.3: delete meeting audio (both tracks) but KEEP notes/transcripts.
    /// Timestamp links in old meetings degrade to plain text — stated in the
    /// confirm dialog.
    @objc private func cleanupTapped() {
        let bytes = MeetingStore.shared.totalAudioBytes()
        let mb = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let alert = NSAlert()
        alert.messageText = L10n.string("Clear audio…")
        alert.informativeText = L10n.string("%@ of recording audio will be deleted. Notes and transcripts are kept.", mb)
        alert.addButton(withTitle: L10n.string("Delete"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            let freed = MeetingStore.shared.deleteAllAudio()
            refreshStorage()
            let shown = ByteCountFormatter.string(fromByteCount: max(0, freed), countStyle: .file)
            let done = NSAlert()
            done.messageText = String(format: L10n.string("Cleared audio for %d meetings (%@ freed)"), Int(freed), shown)
            done.alertStyle = .informational
            done.runModal()
        }
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
        upgradeBtn.isHidden = MinutesPipeline.isPro()
    }

    /// 1.3: total size of every meeting's audio (mic + system tracks).
    private func refreshStorage() {
        let bytes = MeetingStore.shared.totalAudioBytes()
        storageValue.stringValue = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        cleanupBtn.isEnabled = bytes > 0
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


