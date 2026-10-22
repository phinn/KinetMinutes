// MinutesPipeline.swift — the local pipeline: audio → WhisperKit transcript →
// local LLM structured notes (summary/decisions/actions). Zero network except
// one-time model download (WhisperKit from HF mirror-able endpoint; LLM local).
//
// 1.1 dual-track attribution (F03+): recordings carry TWO CAF files —
//   meeting-<id>.caf      mic track      → labeled [Me]
//   meeting-<id>.sys.caf  system track   → labeled [Them] (far end)
// Both tracks are transcribed separately and merged by time with echo
// suppression (mic picks up loudspeaker audio, so my own words can appear in
// the far-end track too). Attribution is structural — it comes from which
// physical track a segment was spoken into, not from voiceprint guessing —
// so it cannot silently degrade server-side. Single-track meetings (no sys
// file) keep the exact 1.0 unlabeled behavior.

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

    /// One transcript segment with its physical-track attribution.
    struct LabeledSeg {
        var start: Double
        var end: Double
        var text: String
        var speaker: String?   // "me" | "them" | nil
    }

    /// Free plan: 5 notes per calendar month. Transcription is FREE and
    /// UNLIMITED (1.2) — the wall only gates LLM notes.
    static let freeMonthlyLimit = 5

    static func notesUsedThisMonth() -> Int {
        let store = MeetingStore.shared
        let cal = Calendar.current
        return store.allMeetings().filter { m in
            // Demo seeds must never consume real quota (1.2 fix: a fresh user
            // started the month at 6/5 used and hit the wall on first use).
            m.sourceApp != "Demo" && m.status == "ready" && !m.transcribeOnly && cal.isDate(m.startedAt, equalTo: Date(), toGranularity: .month)
        }.count
    }

    /// Pro flag lives in UserDefaults ("proUnlocked"), kept fresh by
    /// Licensing (StoreKit 2 currentEntitlements at launch + Transaction.updates
    /// listener; refunds flip it on next refresh). Sync read is intentional —
    /// the free wall runs inside a background pipeline step.
    static func isPro() -> Bool {
        UserDefaults.standard.bool(forKey: "proUnlocked")
    }

    /// 1.2: generate (or regenerate) notes from an ALREADY-STORED transcript.
    /// Used by the library's "Generate Notes" button on transcribe-only
    /// meetings — no ASR rerun, straight to the LLM with the free wall.
    func generateNotes(meetingID: Int64) async {
        guard !isProcessing, let t = MeetingStore.shared.meeting(id: meetingID)?.transcript,
              !t.isEmpty else { return }
        isProcessing = true
        onStateChange?()
        defer { isProcessing = false; onStateChange?() }
        MeetingStore.shared.update(meetingID, status: "processing")
        do {
            try await finish(meetingID: meetingID, transcribeOnly: false, transcript: t)
        } catch {
            MeetingStore.shared.update(meetingID, status: "failed", summary: error.localizedDescription)
        }
    }

    func process(meetingID: Int64) async {
        guard !isProcessing else { return }
        isProcessing = true
        onStateChange?()
        defer { isProcessing = false; onStateChange?() }

        guard var m = MeetingStore.shared.meeting(id: meetingID) else { return }
        let store = MeetingStore.shared
        let sysTrack = store.audioDir.appendingPathComponent("meeting-\(meetingID).sys.caf").path
        let micTrack = m.audioPath
            ?? store.audioDir.appendingPathComponent("meeting-\(meetingID).caf").path
        let hasSys = FileManager.default.fileExists(atPath: sysTrack)
        let hasMic = FileManager.default.fileExists(atPath: micTrack)
        // Primary audio for click-to-play: system track carries the conversation
        // even when the mic stayed muted; fall back to mic.
        m.audioPath = hasSys ? sysTrack : micTrack
        guard hasSys || hasMic else { return }

        // 0. transcription-only mode: no LLM, no free wall — transcript is free
        // and unlimited (1.2 funnel: transcribe for free, pay for notes).
        let transcribeOnly = m.transcribeOnly
        if !transcribeOnly {
            m.status = "processing"
            MeetingStore.shared.update(meetingID, status: "processing")
        }

        // 1. transcribe (WhisperKit, fully offline)
        let provider = WhisperKitTranscriptionProvider(
            modelName: { UserDefaults.standard.string(forKey: "whisperModel") ?? "large-v3-turbo" },
            endpoint: { UserDefaults.standard.string(forKey: "hfEndpoint") }
        )
        do {
            // Single-track fast path — identical to 1.0 behavior, no labels.
            guard hasSys else {
                let result = try await provider.transcribe(audioURL: URL(fileURLWithPath: micTrack), language: nil)
                let segments = result.segments.map {
                    Meeting.Segment(start: $0.startTime, end: $0.endTime, text: $0.text, speaker: nil)
                }
                MeetingStore.shared.update(meetingID, transcript: result.plainText, segments: segments)
                try await finish(meetingID: meetingID, transcribeOnly: transcribeOnly, transcript: result.plainText)
                return
            }

            // Dual-track: transcribe each physical track separately (sequential —
            // one WhisperKit engine instance; concurrent calls would double the
            // CoreML weight residency on 8 GB machines for no real speedup).
            let micRes = try await provider.transcribe(audioURL: URL(fileURLWithPath: micTrack), language: nil)
            let sysRes = try await provider.transcribe(audioURL: URL(fileURLWithPath: sysTrack), language: nil)

            var me = micRes.segments.map {
                LabeledSeg(start: $0.startTime, end: $0.endTime, text: $0.text, speaker: "me")
            }
            var them = sysRes.segments.map {
                LabeledSeg(start: $0.startTime, end: $0.endTime, text: $0.text, speaker: "them")
            }

            // Degenerate guard: system tap captured silence (in-person room,
            // tap failure mid-recording) → attributing everything to "them"
            // would be wrong. Fall back to unlabeled single-track output.
            let meChars = me.reduce(0) { $0 + $1.text.count }
            let themChars = them.reduce(0) { $0 + $1.text.count }
            if themChars < max(20, meChars / 20) {
                me = me.map { LabeledSeg(start: $0.start, end: $0.end, text: $0.text, speaker: nil) }
                them = []
            }

            let merged = Self.mergeTracks(me: me, them: them)
            let transcript = Self.plainTranscript(from: merged)
            let segments = merged.map {
                Meeting.Segment(start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker)
            }
            MeetingStore.shared.update(meetingID, transcript: transcript, segments: segments)

            // 2. local LLM notes (prompt consumes the [Me]/[Them] labels)
            try await finish(meetingID: meetingID, transcribeOnly: transcribeOnly, transcript: transcript)
        } catch {
            MeetingStore.shared.update(meetingID, status: "failed", summary: error.localizedDescription)
            await MainActor.run {
                (NSApp.delegate as? AppDelegate)?.notify(title: L10n.string("Notes generation failed"), body: error.localizedDescription)
            }
        }
    }

    /// Shared tail (1.2): in transcribe-only mode the transcript is the
    /// deliverable — status ready, no LLM, no quota. In full mode the free wall
    /// lives HERE, after the transcript is safely stored, so quota exhaustion
    /// can never throw away a finished transcript (1.1 flaw: wall was step 0).
    private func finish(meetingID: Int64, transcribeOnly: Bool, transcript: String) async throws {
        guard !transcribeOnly else {
            MeetingStore.shared.update(meetingID, status: "ready")
            await MainActor.run {
                (NSApp.delegate as? AppDelegate)?.notify(
                    title: L10n.string("Transcript ready"),
                    body: L10n.string("Transcript saved. Generate AI notes anytime from the meeting."))
            }
            return
        }
        if !Self.isPro(), Self.notesUsedThisMonth() >= Self.freeMonthlyLimit {
            MeetingStore.shared.update(meetingID, status: "failed",
                                       summary: L10n.string("Free plan limit"))
            await MainActor.run {
                (NSApp.delegate as? AppDelegate)?.notify(
                    title: L10n.string("Free plan limit"),
                    body: L10n.string("You've used all %d free notes this month. Upgrade to Pro for unlimited notes.", Self.freeMonthlyLimit))
            }
            return
        }
        let notes = try await summarize(transcript: transcript)
        MeetingStore.shared.update(meetingID,
                                   status: "ready",
                                   summary: notes.summary,
                                   decisions: notes.decisions,
                                   actions: notes.actions)
        // 1.2: a TO meeting that now has real notes is a full-mode meeting —
        // drop the tag or it dodges the quota forever (counts-as-ready but
        // excluded from notesUsedThisMonth).
        MeetingStore.shared.setTranscribeOnly(meetingID, false)
        await MainActor.run {
            (NSApp.delegate as? AppDelegate)?.notify(
                title: L10n.string("Notes ready"),
                body: String(format: L10n.string("Notes for %@ are ready."),
                             MeetingStore.shared.meeting(id: meetingID)?.title ?? ""))
        }
    }

    // MARK: - dual-track merge (echo suppression)

    /// Merge mic + system segments chronologically. The mic picks up room audio
    /// (loudspeaker), so my own voice often reappears in the far-end track.
    /// Rule: whichever track's segment starts first wins the slot; a segment
    /// from the OTHER track that lies almost entirely inside the winner's time
    /// window (±0.3 s) is treated as acoustic echo and dropped. Segments from
    /// the other side that merely overlap but extend beyond are kept — that's
    /// genuine crosstalk, and hiding real speech is worse than showing overlap.
    static func mergeTracks(me: [LabeledSeg], them: [LabeledSeg]) -> [LabeledSeg] {
        var out: [LabeledSeg] = []
        var i = 0, j = 0
        let eps = 0.3
        while i < me.count || j < them.count {
            let takeMe: Bool
            if i >= me.count { takeMe = false }
            else if j >= them.count { takeMe = true }
            else { takeMe = me[i].start <= them[j].start }
            var cur = takeMe ? me[i] : them[j]
            if takeMe { i += 1 } else { j += 1 }
            // Drop near-duplicates of the winner from the other track.
            while true {
                if takeMe, j < them.count,
                   them[j].start < cur.end + eps, them[j].end <= cur.end + eps {
                    j += 1
                } else if !takeMe, i < me.count,
                          me[i].start < cur.end + eps, me[i].end <= cur.end + eps {
                    i += 1
                } else { break }
            }
            out.append(cur)
        }
        return out
    }

    /// Plain-text transcript with track labels, used for FTS + the LLM prompt:
    /// `[MM:SS] [Me] text` / `[MM:SS] [Them] text` / `[MM:SS] text` (unlabeled).
    static func plainTranscript(from segs: [LabeledSeg]) -> String {
        segs.map { s -> String in
            let t = Int(s.start)
            let stamp = String(format: "[%02d:%02d]", t / 60, t % 60)
            switch s.speaker {
            case "me": return "\(stamp) [Me] \(s.text)"
            case "them": return "\(stamp) [Them] \(s.text)"
            default: return "\(stamp) \(s.text)"
            }
        }.joined(separator: "\n")
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
        Transcript lines may carry track labels: "[Me]" = this user, "[Them]" = the other participant(s). Use labels to attribute speakers: quote the right side in the summary, and when an action's owner is not named out loud, set owner from the label of the line that took the commitment ("Me"/"我" for [Me], "Them"/"对方" for [Them]).
        """
        var modelName = UserDefaults.standard.string(forKey: "localLLMModel") ?? "qwen3:4b"
        // 1.2 self-heal: resolve the configured model against what this Ollama
        // actually has. The hardcoded default (qwen3:4b) 404s on machines that
        // pulled a different model, and the settings pane was never visited.
        if let resolved = await Self.resolveOllamaModel(configured: modelName, endpoint: "http://127.0.0.1:11434") {
            if resolved != modelName {
                modelName = resolved
                UserDefaults.standard.set(resolved, forKey: "localLLMModel")
            }
        }
        var config = LLMConfig(name: "local", endpoint: "http://127.0.0.1:11434",
                               apiKey: "", modelName: modelName)
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

    /// Ask Ollama which models exist locally. Returns a usable model name:
    /// the configured one if present, else the first qwen*, else the first
    /// installed model. Nil when Ollama is unreachable or has no models.
    static func resolveOllamaModel(configured: String, endpoint: String) async -> String? {
        guard let url = URL(string: "\(endpoint)/api/tags") else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = arr["models"] as? [[String: Any]] else { return nil }
        let names = models.compactMap { $0["name"] as? String }
        guard !names.isEmpty else { return nil }
        if names.contains(configured) { return configured }
        // exact name may carry a tag suffix mismatch (qwen2.5 vs qwen2.5:3b)
        if names.contains(where: { $0.hasPrefix(configured) }) { return names.first { $0.hasPrefix(configured) } }
        if let q = names.first(where: { $0.hasPrefix("qwen") }) { return q }
        return names.first
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
