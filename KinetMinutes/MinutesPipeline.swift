// MinutesPipeline.swift — the local pipeline: audio → WhisperKit transcript →
// local LLM structured notes (summary/decisions/actions). Zero network except
// one-time model download (WhisperKit from HF mirror-able endpoint; LLM local).

import Foundation
import AppKit
import LocalLLMKit
import LocalLLMKitTranscription

final class MinutesPipeline {
    static let shared = MinutesPipeline()

    private(set) var isProcessing = false
    var onStateChange: (() -> Void)?

    struct Notes {
        var summary: String
        var decisions: [String]
        var actions: [Meeting.ActionItem]
    }

    /// Free plan: 5 notes per calendar month.
    static let freeMonthlyLimit = 5

    static func notesUsedThisMonth() -> Int {
        let store = MeetingStore.shared
        let cal = Calendar.current
        return store.allMeetings().filter { m in
            m.status == "ready" && cal.isDate(m.startedAt, equalTo: Date(), toGranularity: .month)
        }.count
    }

    static func isPro() -> Bool {
        // MAS: StoreKit 2 check; Paddle website builds: license file. 1.0 ships free features
        // with the monthly wall; Pro unlock lands with 1.1. Until then treat as free.
        UserDefaults.standard.bool(forKey: "proUnlocked")
    }

    func process(meetingID: Int64) async {
        guard !isProcessing else { return }
        isProcessing = true
        onStateChange?()
        defer { isProcessing = false; onStateChange?() }

        guard var m = MeetingStore.shared.meeting(id: meetingID) else { return }

        // F03 双轨:prefer the system track (far end = meeting audio); fall back to mic.
        let store = MeetingStore.shared
        let sysTrack = store.audioDir.appendingPathComponent("meeting-\(meetingID).sys.caf").path
        let micTrack = m.audioPath
            ?? store.audioDir.appendingPathComponent("meeting-\(meetingID).caf").path
        let audioPath = FileManager.default.fileExists(atPath: sysTrack) ? sysTrack : micTrack
        m.audioPath = audioPath
        guard FileManager.default.fileExists(atPath: audioPath) else { return }

        // 0. free wall
        if !Self.isPro(), Self.notesUsedThisMonth() >= Self.freeMonthlyLimit {
            MeetingStore.shared.update(meetingID, status: "failed",
                                       summary: L10n.string("Free plan limit"))
            return
        }

        // 1. transcribe (WhisperKit, fully offline)
        let provider = WhisperKitTranscriptionProvider(
            modelName: { UserDefaults.standard.string(forKey: "whisperModel") ?? "large-v3-turbo" },
            endpoint: { UserDefaults.standard.string(forKey: "hfEndpoint") }
        )
        do {
            let result = try await provider.transcribe(audioURL: URL(fileURLWithPath: audioPath), language: nil)
            let segments: [Meeting.Segment] = result.segments.map {
                Meeting.Segment(start: $0.startTime, end: $0.endTime, text: $0.text)
            }
            MeetingStore.shared.update(meetingID, transcript: result.plainText, segments: segments)

            // 2. local LLM notes
            let notes = try await summarize(transcript: result.plainText)
            MeetingStore.shared.update(meetingID,
                                       status: "ready",
                                       summary: notes.summary,
                                       decisions: notes.decisions,
                                       actions: notes.actions)
            await MainActor.run {
                (NSApp.delegate as? AppDelegate)?.notify(
                    title: L10n.string("Notes ready"),
                    body: String(format: L10n.string("Notes for %@ are ready."), m.title))
            }
        } catch {
            MeetingStore.shared.update(meetingID, status: "failed", summary: error.localizedDescription)
            await MainActor.run {
                (NSApp.delegate as? AppDelegate)?.notify(title: L10n.string("Notes generation failed"), body: error.localizedDescription)
            }
        }
    }

    // MARK: - local LLM structured notes

    struct LLMNotes {
        var summary: String
        var decisions: [String]
        var actions: [Meeting.ActionItem]
    }

    private func summarize(transcript: String) async throws -> LLMNotes {
        // Truncate to ~24k chars head-safe for 4B-class local models.
        let t = String(transcript.prefix(24_000))
        let sys = """
        You are a meeting-notes writer. Given a raw transcript, output STRICT JSON only, no markdown fences:
        {"summary": "3-6 sentence summary in the transcript's language", "decisions": ["decision 1", ...], "actions": [{"owner": "name or 待定", "task": "...", "due": "date or empty"}...]}
        Rules: same language as the transcript; decisions = things agreed; actions = tasks with owner. If none, empty arrays.
        """
        var config = LLMConfig(name: "local", endpoint: "http://127.0.0.1:11434/v1",
                               apiKey: "", modelName: UserDefaults.standard.string(forKey: "localLLMModel") ?? "qwen3:4b")
        config.apiKeyProvider = { _ in "" }
        let provider = LLMService.provider(for: config)
        let messages = [Participant(role: "system", content: sys),
                        Participant(role: "user", content: t)]
        let stream = provider.chat(messages: messages, tools: nil, config: config)
        var text = ""
        for try await chunk in stream {
            if case .text(let s) = chunk { text += s }
        }
        return Self.parseNotes(text)
    }

    static func parseNotes(_ raw: String) -> LLMNotes {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {  // strip fences if model disobeys
            if let r = s.range(of: "\n") { s = String(s[r.upperBound...]) }
            if let r = s.range(of: "```", options: .backwards) { s = String(s[..<r.lowerBound]) }
        }
        // find first { ... last }
        if let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}") {
            s = String(s[a...b])
        } else {
            return LLMNotes(summary: raw, decisions: [], actions: [])
        }
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return LLMNotes(summary: raw, decisions: [], actions: [])
        }
        let summary = obj["summary"] as? String ?? raw
        let decisions = (obj["decisions"] as? [Any])?.compactMap { $0 as? String } ?? []
        let actions = (obj["actions"] as? [[String: Any]])?.map {
            Meeting.ActionItem(owner: $0["owner"] as? String ?? "",
                                         task: $0["task"] as? String ?? "",
                                         due: $0["due"] as? String ?? "")
        } ?? []
        return LLMNotes(summary: summary, decisions: decisions, actions: actions)
    }
}
