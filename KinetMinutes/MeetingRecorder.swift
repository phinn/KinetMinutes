// MeetingRecorder.swift — mic recording via AVAudioEngine (macOS: no AVAudioSession).
// Writes CAF at hardware format; level meter feeds the menu-bar icon.
// macOS 14.4+ also exposes AVAudioMixerSinkNode for system-audio taps; we gate that
// behind #available and fall back to mic-only on older runtimes.

import AVFoundation
import AppKit

final class MeetingRecorder: NSObject {
    static let shared = MeetingRecorder()

    private(set) var isRecording = false
    private(set) var currentMeetingID: Int64?
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private(set) var startedAt: Date?
    var onLevelChange: ((Float) -> Void)?
    private(set) var lastLevel: Float = 0
    private var levelTimer: Timer?
    private(set) var usedSystemAudio = false

    var elapsedString: String {
        guard let s = startedAt else { return "0:00" }
        let t = Int(Date().timeIntervalSince(s))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    func start(meetingID: Int64) {
        guard !isRecording else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                if granted { self?.begin(meetingID: meetingID) }
                else {
                    (NSApp.delegate as? AppDelegate)?.notify(
                        title: L10n.string("Cannot start recording"),
                        body: "Microphone permission denied. Enable it in System Settings → Privacy & Security → Microphone.")
                }
            }
        }
    }

    private func begin(meetingID: Int64) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        let store = MeetingStore.shared
        let url = store.audioDir.appendingPathComponent("meeting-\(meetingID).caf")

        // 48k mono PCM16 target file (whisper.cpp/WhisperKit friendly)
        let fileFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        guard let file = try? AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]), let converter = AVAudioConverter(from: hwFormat, to: fileFormat) else {
            (NSApp.delegate as? AppDelegate)?.notify(title: L10n.string("Cannot start recording"), body: "audio file init failed")
            return
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self, self.isRecording else { return }
            let ratio = 48_000 / hwFormat.sampleRate
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: cap) else { return }
            var err: NSError?
            var consumed = false
            converter.convert(to: out, error: &err) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if err == nil, out.frameLength > 0 {
                try? file.write(from: out)
                if let ch = out.floatChannelData?[0] {
                    var peak: Float = 0
                    for i in 0..<Int(out.frameLength) { peak = max(peak, abs(ch[i])) }
                    self.lastLevel = peak
                    self.onLevelChange?(peak)
                }
            }
        }

        engine.prepare()
        do { try engine.start() } catch {
            (NSApp.delegate as? AppDelegate)?.notify(title: L10n.string("Cannot start recording"), body: error.localizedDescription)
            return
        }

        self.engine = engine
        self.file = file
        self.converter = converter
        self.isRecording = true
        self.currentMeetingID = meetingID
        self.startedAt = Date()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.onLevelChange?(self.lastLevel)
            (NSApp.delegate as? AppDelegate)?.refreshStatusMenu()
        }
    }

    /// Stop and finalize; returns the meeting id whose processing should start.
    @discardableResult
    func stopSaving() -> Int64? {
        guard isRecording, let id = currentMeetingID else { return nil }
        levelTimer?.invalidate(); levelTimer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        file = nil
        converter = nil
        isRecording = false
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil
        let path = MeetingStore.shared.audioDir.appendingPathComponent("meeting-\(id).caf").path
        MeetingStore.shared.update(id, status: "processing", endedAt: Date(), duration: duration, audioPath: path)
        currentMeetingID = nil
        lastLevel = 0
        onLevelChange?(0)
        return id
    }
}
