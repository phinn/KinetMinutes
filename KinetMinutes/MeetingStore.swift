// MeetingStore.swift — SQLite meeting library (FTS5 search over title+notes+transcript)
// Pure sqlite3 C API (same pattern as KinetAios). Local-only storage under
// Application Support inside the sandbox container.

import Foundation
import SQLite3

struct Meeting {
    var id: Int64 = 0
    var title: String
    var sourceApp: String
    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: Double
    var audioPath: String?
    var transcript: String?
    var summary: String?
    var decisionsJSON: String?     // [String]
    var actionsJSON: String?       // [{"owner":..,"task":..,"due":..}]
    var status: String             // recording | processing | ready | failed
    var segmentsJSON: String?      // [{"start":..,"end":..,"text":..}]
    var tagsJSON: String?          // ["tag1","tag2"] (F07)

    var tags: [String] {
        guard let d = tagsJSON?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: d)) ?? []
    }

    // MARK: - Processing mode (1.2)
    // "transcribe-only" tag = transcript only, no LLM notes; absence = full mode.
    // Persisted as a tag so orphan-recovery reprocessing (ready_to_process at
    // launch) picks the right pipeline with zero schema migration.
    static let transcribeOnlyTag = "transcribe-only"
    var transcribeOnly: Bool { tags.contains(Meeting.transcribeOnlyTag) }

    var decisions: [String] {
        guard let d = decisionsJSON?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: d)) ?? []
    }
    struct ActionItem: Codable {
        var owner: String
        var task: String
        var due: String
    }
    var actions: [ActionItem] {
        guard let d = actionsJSON?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ActionItem].self, from: d)) ?? []
    }
    struct Segment: Codable {
        var start: Double
        var end: Double
        var text: String
        /// "me" | "them" | nil (single-track meetings carry no speaker label).
        /// 1.1: dual-track pipeline tags each segment by its source track.
        var speaker: String?
    }
    var segments: [Segment] {
        guard let d = segmentsJSON?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Segment].self, from: d)) ?? []
    }
}

final class MeetingStore {
    static let shared = MeetingStore()
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.kinet.minutes.store")

    var dataDir: URL {
        // Screenshot harness: isolate a throwaway library per locale.
        if let d = ProcessInfo.processInfo.environment["KM_DATA_DIR"], !d.isEmpty {
            let dir = URL(fileURLWithPath: d, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("KinetMinutes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    var audioDir: URL { dataDir.appendingPathComponent("Audio", isDirectory: true) }
    var dbPath: URL { dataDir.appendingPathComponent("meetings.db") }

    private init() {}

    func migrateIfNeeded() {
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        queue.sync {
            sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
            exec("PRAGMA journal_mode=WAL")
            exec("""
            CREATE TABLE IF NOT EXISTS meetings (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              title TEXT NOT NULL DEFAULT '',
              source_app TEXT NOT NULL DEFAULT '',
              started_at REAL NOT NULL,
              ended_at REAL,
              duration REAL NOT NULL DEFAULT 0,
              audio_path TEXT,
              transcript TEXT,
              summary TEXT,
              decisions_json TEXT,
              actions_json TEXT,
              status TEXT NOT NULL DEFAULT 'recording',
              segments_json TEXT,
              tags_json TEXT NOT NULL DEFAULT '[]'
            )
            """)
            // migrations: existing installs get the tags column (F07).
            // exec() swallows the "duplicate column" error on fresh DBs — harmless.
            var colStmt: OpaquePointer?
            sqlite3_prepare_v2(db, "PRAGMA table_info(meetings)", -1, &colStmt, nil)
            var hasTags = false
            while sqlite3_step(colStmt) == SQLITE_ROW {
                if sqlite3_column_text(colStmt, 1).map({ String(cString: $0) }) == "tags_json" { hasTags = true }
            }
            sqlite3_finalize(colStmt)
            if !hasTags { exec("ALTER TABLE meetings ADD COLUMN tags_json TEXT NOT NULL DEFAULT '[]'") }
            exec("CREATE VIRTUAL TABLE IF NOT EXISTS meetings_fts USING fts5(title, transcript, summary, content='meetings', content_rowid='id')")
            exec("CREATE TRIGGER IF NOT EXISTS meetings_ai AFTER INSERT ON meetings BEGIN INSERT INTO meetings_fts(rowid, title, transcript, summary) VALUES (new.id, new.title, new.transcript, new.summary); END")
            exec("CREATE TRIGGER IF NOT EXISTS meetings_ad AFTER DELETE ON meetings BEGIN INSERT INTO meetings_fts(meetings_fts, rowid, title, transcript, summary) VALUES ('delete', old.id, old.title, old.transcript, old.summary); END")
            exec("CREATE TRIGGER IF NOT EXISTS meetings_au AFTER UPDATE ON meetings BEGIN INSERT INTO meetings_fts(meetings_fts, rowid, title, transcript, summary) VALUES ('delete', old.id, old.title, old.transcript, old.summary); INSERT INTO meetings_fts(rowid, title, transcript, summary) VALUES (new.id, new.title, new.transcript, new.summary); END")
            // FTS was silently broken before (CREATE TABLE vs CREATE VIRTUAL TABLE);
            // rebuild so existing rows become searchable. Idempotent.
            exec("INSERT INTO meetings_fts(meetings_fts) VALUES('rebuild')")
        }
    }

    deinit { sqlite3_close_v2(db) }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func bind(_ stmt: OpaquePointer?, _ idx: Int32, _ s: String?) {
        if let s { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(stmt, idx) }
    }
    private func text(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }

    // MARK: - CRUD

    /// 1.3 P2: calendar prefill — CalendarBridge supplies the title, falling
    /// back to the default "New meeting" label when no event matches.
    func createMeeting(sourceApp: String, transcribeOnly: Bool = false, titleOverride: String? = nil) -> Meeting {
        queue.sync {
            var m = Meeting(title: titleOverride ?? defaultTitle(), sourceApp: sourceApp, startedAt: Date(), durationSeconds: 0, status: "recording")
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO meetings (title, source_app, started_at, status, tags_json) VALUES (?,?,?,?,?)", -1, &stmt, nil)
            bind(stmt, 1, m.title); bind(stmt, 2, m.sourceApp)
            sqlite3_bind_double(stmt, 3, m.startedAt.timeIntervalSince1970)
            bind(stmt, 4, m.status)
            let tags = transcribeOnly ? [Meeting.transcribeOnlyTag] : []
            let tagJSON = String(data: (try? JSONEncoder().encode(tags)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
            bind(stmt, 5, tagJSON)
            sqlite3_step(stmt); sqlite3_finalize(stmt)
            m.id = sqlite3_last_insert_rowid(db)
            return m
        }
    }

    /// 1.2: add/remove the transcribe-only tag, preserving any other tags.
    func setTranscribeOnly(_ id: Int64, _ on: Bool) {
        guard var m = meeting(id: id) else { return }
        var tags = m.tags.filter { $0 != Meeting.transcribeOnlyTag }
        if on { tags.append(Meeting.transcribeOnlyTag) }
        let json = String(data: (try? JSONEncoder().encode(tags)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        queue.sync {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "UPDATE meetings SET tags_json=? WHERE id=\(id)", -1, &stmt, nil)
            bind(stmt, 1, json)
            sqlite3_step(stmt); sqlite3_finalize(stmt)
            notifyChanged()
        }
    }

    func meeting(id: Int64) -> Meeting? {
        queue.sync { fetch("SELECT \(cols) FROM meetings WHERE id=\(id)").first }
    }

    func allMeetings(search: String? = nil) -> [Meeting] {
        queue.sync {
            if let q = search?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
                let esc = q.replacingOccurrences(of: "'", with: "''")
                return fetch("""
                SELECT \(cols) FROM meetings WHERE id IN
                  (SELECT rowid FROM meetings_fts WHERE meetings_fts MATCH '\(esc)')
                ORDER BY started_at DESC
                """)
            }
            return fetch("SELECT \(cols) FROM meetings ORDER BY started_at DESC")
        }
    }

    /// 1.2: notify observers OUTSIDE the serial queue. Observers (library
    /// reload, detail refresh) touch the store again — posting inside
    /// queue.sync deadlocks when an observer does waitUntilFinished on an
    /// operation that re-enters this same queue (sampled live in 1.2 smoke).
    private func notifyChanged() {
        DispatchQueue.global().async { [weak self] in
            NotificationCenter.default.post(name: Self.meetingsChangedNotification, object: nil)
        }
    }

    /// bridged so the async closure doesn't need `self`
    nonisolated static let meetingsChangedNotification = Notification.Name("meetingsChanged")

    func update(_ id: Int64, title: String? = nil, status: String? = nil, endedAt: Date? = nil,
                duration: Double? = nil, audioPath: String? = nil, transcript: String? = nil,
                summary: String? = nil, decisions: [String]? = nil, actions: [Meeting.ActionItem]? = nil,
                segments: [Meeting.Segment]? = nil) {
        queue.sync {
            var sets: [String] = []
            var stmt: OpaquePointer?
            if let title { sets.append("title=?"); }
            if let status { sets.append("status=?") }
            if let endedAt { sets.append("ended_at=\(endedAt.timeIntervalSince1970)") }
            if let duration { sets.append("duration=\(duration)") }
            if let audioPath { sets.append("audio_path=?") }
            if let transcript { sets.append("transcript=?") }
            if let summary { sets.append("summary=?") }
            if let decisions { sets.append("decisions_json=?") }
            if let actions { sets.append("actions_json=?") }
            if let segments { sets.append("segments_json=?") }
            guard !sets.isEmpty else { return }
            let enc: (Data?) -> String? = { $0.flatMap { String(data: $0, encoding: .utf8) } }
            let decJSON = enc(try? JSONEncoder().encode(decisions ?? []))
            let actJSON = enc(try? JSONEncoder().encode(actions ?? []))
            let segJSON = enc(try? JSONEncoder().encode(segments ?? []))
            sqlite3_prepare_v2(db, "UPDATE meetings SET \(sets.joined(separator: ",")) WHERE id=\(id)", -1, &stmt, nil)
            var i: Int32 = 1
            if let title { bind(stmt, i, title); i += 1 }
            if let status { bind(stmt, i, status); i += 1 }
            if let audioPath { bind(stmt, i, audioPath); i += 1 }
            if let transcript { bind(stmt, i, transcript); i += 1 }
            if let summary { bind(stmt, i, summary); i += 1 }
            if decisions != nil { bind(stmt, i, decJSON); i += 1 }
            if actions != nil { bind(stmt, i, actJSON); i += 1 }
            if segments != nil { bind(stmt, i, segJSON); i += 1 }
            sqlite3_step(stmt); sqlite3_finalize(stmt)
            notifyChanged()
        }
    }

    func delete(id: Int64) {
        queue.sync {
            if let m = fetch("SELECT \(cols) FROM meetings WHERE id=\(id)").first, let p = m.audioPath {
                try? FileManager.default.removeItem(atPath: p)
            }
            exec("DELETE FROM meetings WHERE id=\(id)")
        }
        notifyChanged()
    }

    // MARK: - Audio storage management (1.3)

    /// Total bytes of all meeting audio files that still exist on disk.
    /// 1.3 storage management: total bytes of ALL audio under audioDir —
    /// both tracks (meeting-N.caf + meeting-N.sys.caf) and orphaned files
    /// alike, i.e. what the folder actually costs on disk.
    func totalAudioBytes() -> Int64 {
        queue.sync {
            guard let files = try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
            return files.reduce(Int64(0)) { acc, url in
                acc + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
    }

    /// Delete every audio file under audioDir (both tracks + orphans) but
    /// KEEP meeting rows, transcripts and notes — storage keeps growing
    /// otherwise (dual tracks ≈ 0.6 GB/h). Clearing audio_path degrades
    /// timeline links to plain text, which the confirm dialog states.
    /// Returns bytes freed.
    @discardableResult
    func deleteAllAudio() -> Int64 {
        var freed: Int64 = 0
        queue.sync {
            guard let files = try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: [.fileSizeKey]) else { return }
            for url in files {
                freed += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                try? FileManager.default.removeItem(at: url)
            }
            exec("UPDATE meetings SET audio_path=NULL WHERE audio_path IS NOT NULL")
        }
        notifyChanged()
        return freed
    }

    func deleteAll() {
        let all = allMeetings()
        for m in all { delete(id: m.id) }
        // VACUUM to actually shrink the db file
        queue.sync { exec("VACUUM") }
    }

    // MARK: - helpers

    private let cols = "id,title,source_app,started_at,ended_at,duration,audio_path,transcript,summary,decisions_json,actions_json,status,segments_json,tags_json"

    private func fetch(_ sql: String) -> [Meeting] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        var out: [Meeting] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var m = Meeting(title: "", sourceApp: "", startedAt: Date(), durationSeconds: 0, status: "ready")
            m.id = sqlite3_column_int64(stmt, 0)
            m.title = text(stmt, 1) ?? ""
            m.sourceApp = text(stmt, 2) ?? ""
            m.startedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            m.endedAt = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            m.durationSeconds = sqlite3_column_double(stmt, 5)
            m.audioPath = text(stmt, 6)
            m.transcript = text(stmt, 7)
            m.summary = text(stmt, 8)
            m.decisionsJSON = text(stmt, 9)
            m.actionsJSON = text(stmt, 10)
            m.status = text(stmt, 11) ?? "ready"
            m.segmentsJSON = text(stmt, 12)
            m.tagsJSON = text(stmt, 13)
            out.append(m)
        }
        sqlite3_finalize(stmt)
        return out
    }

    // MARK: - Demo seed

    /// 首次启动插入完整 demo 数据:3 场会(周会/客户会/1on1),每场含摘要、决议、待办、时间线、逐字稿,
    /// 保证审核员无模型/无会议时也能立刻看到全流程产出,商店截图也有真实感。
    /// 只 seed 一次(UserDefaults 标记),幂等。
    func seedDemoMeetingIfNeeded() {
        let flag = "seededDemoMeeting_v3"
        let force = ProcessInfo.processInfo.environment["KM_FORCE_SEED"] == "1"
        if !force { guard !UserDefaults.standard.bool(forKey: flag) else { return } }
        queue.sync {
            // ---- locale pack ----
            let (t1, s1, d1, a1, tr1, sg1): (String, String, [String], [(String, String, String)], String, [(Int, Int, String)])
            let (t2, s2, d2, a2, tr2, sg2): (String, String, [String], [(String, String, String)], String, [(Int, Int, String)])
            let (t3, s3, d3, a3, tr3, sg3): (String, String, [String], [(String, String, String)], String, [(Int, Int, String)])
            switch L10n.preferredLanguage() {
            case "ja":
                (t1, s1, d1, a1, tr1, sg1) = Self.seed1ja(); (t2, s2, d2, a2, tr2, sg2) = Self.seed2ja(); (t3, s3, d3, a3, tr3, sg3) = Self.seed3ja()
            case "zh-Hans":
                (t1, s1, d1, a1, tr1, sg1) = Self.seed1zh(); (t2, s2, d2, a2, tr2, sg2) = Self.seed2zh(); (t3, s3, d3, a3, tr3, sg3) = Self.seed3zh()
            case "zh-Hant":
                (t1, s1, d1, a1, tr1, sg1) = Self.seed1zht(); (t2, s2, d2, a2, tr2, sg2) = Self.seed2zht(); (t3, s3, d3, a3, tr3, sg3) = Self.seed3zht()
            case "ko":
                (t1, s1, d1, a1, tr1, sg1) = Self.seed1ko(); (t2, s2, d2, a2, tr2, sg2) = Self.seed2ko(); (t3, s3, d3, a3, tr3, sg3) = Self.seed3ko()
            case "fr":
                (t1, s1, d1, a1, tr1, sg1) = Self.seed1fr(); (t2, s2, d2, a2, tr2, sg2) = Self.seed2fr(); (t3, s3, d3, a3, tr3, sg3) = Self.seed3fr()
            case "de":
                (t1, s1, d1, a1, tr1, sg1) = Self.seed1de(); (t2, s2, d2, a2, tr2, sg2) = Self.seed2de(); (t3, s3, d3, a3, tr3, sg3) = Self.seed3de()
            case "es":
                (t1, s1, d1, a1, tr1, sg1) = Self.seed1es(); (t2, s2, d2, a2, tr2, sg2) = Self.seed2es(); (t3, s3, d3, a3, tr3, sg3) = Self.seed3es()
            default:
                (t1, s1, d1, a1, tr1, sg1) = Self.seed1en(); (t2, s2, d2, a2, tr2, sg2) = Self.seed2en(); (t3, s3, d3, a3, tr3, sg3) = Self.seed3en()
            }
            let sampleName = L10n.string("Sample")
            func encActions(_ xs: [(String, String, String)]) -> String {
                let objs = xs.map { "{\"owner\":\"\($0.0)\",\"task\":\"\($0.1)\",\"due\":\"\($0.2)\"}" }
                return "[" + objs.joined(separator: ",") + "]"
            }
            func encSegs(_ xs: [(Int, Int, String)]) -> String {
                let objs = xs.map { "{\"start\":\($0.0),\"end\":\($0.1),\"text\":\"\($0.2.replacingOccurrences(of: "\"", with: "\\'"))\"}" }
                return "[" + objs.joined(separator: ",") + "]"
            }
            func encArr(_ xs: [String]) -> String {
                return "[" + xs.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\'"))\"" }.joined(separator: ",") + "]"
            }
            let now = Date()
            let meetings: [(Meeting, String, String, String)] = [
                (Meeting(title: t1, sourceApp: sampleName, startedAt: now.addingTimeInterval(-3600), endedAt: now.addingTimeInterval(-1800), durationSeconds: 1800, audioPath: nil, transcript: tr1, summary: s1, decisionsJSON: encArr(d1), actionsJSON: encActions(a1), status: "ready", segmentsJSON: encSegs(sg1)), s1, encArr(d1), encActions(a1)),
                (Meeting(title: t2, sourceApp: sampleName, startedAt: now.addingTimeInterval(-86400*2), endedAt: now.addingTimeInterval(-86400*2+2700), durationSeconds: 2700, audioPath: nil, transcript: tr2, summary: s2, decisionsJSON: encArr(d2), actionsJSON: encActions(a2), status: "ready", segmentsJSON: encSegs(sg2)), s2, encArr(d2), encActions(a2)),
                (Meeting(title: t3, sourceApp: sampleName, startedAt: now.addingTimeInterval(-86400*5), endedAt: now.addingTimeInterval(-86400*5+1500), durationSeconds: 1500, audioPath: nil, transcript: tr3, summary: s3, decisionsJSON: encArr(d3), actionsJSON: encActions(a3), status: "ready", segmentsJSON: encSegs(sg3)), s3, encArr(d3), encActions(a3)),
            ]
            for (m, _, dj, aj) in meetings {
                var stmt: OpaquePointer?
                sqlite3_prepare_v2(db, """
                    INSERT INTO meetings (title, source_app, started_at, ended_at, duration, status, summary, decisions_json, actions_json, transcript, segments_json)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?)
                    """, -1, &stmt, nil)
                bind(stmt, 1, m.title)
                bind(stmt, 2, m.sourceApp)
                sqlite3_bind_double(stmt, 3, m.startedAt.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 4, m.endedAt!.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 5, m.durationSeconds)
                bind(stmt, 6, m.status)
                bind(stmt, 7, m.summary)
                bind(stmt, 8, dj)
                bind(stmt, 9, aj)
                bind(stmt, 10, m.transcript)
                bind(stmt, 11, m.segmentsJSON)
                sqlite3_step(stmt); sqlite3_finalize(stmt)
            }
        }
        UserDefaults.standard.set(true, forKey: flag)
        notifyChanged()
    }

    // MARK: - Demo seed locale packs(截图/审核用富内容,按 UI 语言生成)

    private static func seed1en() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("Weekly Product Sync",
         "OVERVIEW\nThe team reviewed sprint progress and agreed to ship v1.0 with single-speaker transcription; diarization stays behind a feature flag. Release is targeted for the end of the month, pending the privacy copy review.\n\nKEY POINTS\n• Local transcription pipeline hit 92% accuracy on the test set\n• Diarization experiment deferred to next sprint\n• Privacy copy review assigned before submission\n• Audio retention: 30 days by default, configurable in Settings\n• v1.0 exports Markdown, TXT and SRT\n\nRISKS\n• Diarization slips again if the overlapping-speech tests keep failing\n• The privacy copy review is the only thing left before submission\n• 30-day retention may not satisfy enterprise buyers\n\nOPEN QUESTIONS\n• Does the Northwind pilot need a Windows build?\n• Who owns support once v1.0 ships?\n\nNEXT STEPS\n• Freeze feature scope and cut the release candidate on the 28th",
         ["Ship v1.0 with single-speaker mode; diarization behind a flag", "Keep on-device-only processing as the default", "Audio retention defaults to 30 days and stays user-configurable", "v1.0 ships with Markdown, TXT and SRT export only"],
         [("Maya", "Run speaker-diarization experiment", "Next sprint"), ("Ken", "Draft App Store screenshots", "Friday"),
          ("Maya", "Review privacy copy", "Before submission"), ("Phinn", "Cut the release candidate", "The 28th"),
          ("Ken", "Write the v1.0 release notes", "Thursday"), ("Maya", "Share the accuracy test report", "Tomorrow"),
          ("Phinn", "Confirm App Store pricing", "Next week")],
         """
         [00:00] Phinn: Let's start with the sprint review. The local transcription pipeline hit 92% accuracy on our test set.
         [02:30] Maya: Great. For the next sprint, I'll own the speaker-diarization experiment.
         [04:15] Ken: What's the default for audio retention? Thirty days felt right in the survey.
         [05:10] Phinn: Decision: we ship v1.0 with single-speaker mode and keep diarization behind a flag.
         [07:40] Maya: Agreed. I'll make retention configurable instead of hard-coding thirty days.
         [09:20] Ken: Export formats — Markdown, TXT and SRT are enough for launch.
         [10:05] Phinn: Decision: v1.0 ships with those three. Nothing else.
         [11:30] Ken: I'll draft the App Store screenshots by Friday, and Maya reviews the privacy copy.
         [12:20] Phinn: Release candidate on the 28th. Action items are logged — meeting adjourned.
         """,
         [(0,14,"Let's start with the sprint review. The local transcription pipeline hit 92% accuracy on our test set."),(150,186,"For the next sprint, I'll own the speaker-diarization experiment."),(255,282,"What's the default for audio retention? Thirty days felt right in the survey."),(310,352,"Decision: we ship v1.0 with single-speaker mode and keep diarization behind a flag."),(460,505,"Agreed. I'll make retention configurable instead of hard-coding thirty days."),(560,590,"Export formats — Markdown, TXT and SRT are enough for launch."),(605,630,"Decision: v1.0 ships with those three. Nothing else."),(690,725,"I'll draft the App Store screenshots by Friday, and Maya reviews the privacy copy."),(740,760,"Release candidate on the 28th. Action items are logged — meeting adjourned.")])
    }
    private static func seed2en() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("Client Kickoff — Northwind",
         "OVERVIEW\nScoped the analytics dashboard rollout for Northwind's APAC offices; phase one covers three sites with on-premise data processing.\n\nKEY POINTS\n• Phase one: Singapore, Tokyo, Sydney — starting first week of next month\n• Compliance requires all data to stay on-premise\n• Weekly checkpoint every Tuesday 10:00",
         ["Phase one = APAC offices, starting first week of next month", "All processing must remain on-premise (compliance hard requirement)"],
         [("Sarah", "Send SOW and onboarding checklist", "This week"), ("Phinn", "Prepare deployment timeline", "Next Tuesday")],
         """
         [00:00] Sarah: Thanks for joining. Let's scope the dashboard rollout for your APAC offices.
         [04:12] Phinn: Phase one covers Singapore, Tokyo and Sydney. We can start the first week of next month.
         [09:40] Sarah: Our compliance team requires all processing to stay on-premise — that's a hard requirement.
         [15:05] Phinn: Understood. Everything runs locally; nothing leaves the machines.
         [22:30] Sarah: Let's do a weekly checkpoint, Tuesdays at ten.
         """,
         [(0,16,"Thanks for joining. Let's scope the dashboard rollout for your APAC offices."),(252,300,"Phase one covers Singapore, Tokyo and Sydney. We can start the first week of next month."),(580,640,"Our compliance team requires all processing to stay on-premise — that's a hard requirement."),(905,940,"Understood. Everything runs locally; nothing leaves the machines.")])
    }
    private static func seed3en() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("1:1 with Maya",
         "OVERVIEW\nCareer growth check-in: Maya will lead the Parakeet speech-model evaluation and present findings at the next sprint review.\n\nKEY POINTS\n• Maya takes ownership of the Parakeet evaluation\n• Presentation of results at next sprint review\n• Growth path: model evaluation → on-device fine-tuning",
         ["Maya leads the Parakeet evaluation and reports at next sprint review"],
         [("Maya", "Run Parakeet evaluation and prepare findings", "Sprint review")],
         """
         [00:00] Phinn: Quick career check-in, then this week's priorities.
         [06:30] Maya: I want to go deeper on speech models — could I own the Parakeet evaluation?
         [12:10] Phinn: Absolutely. Decision: you lead the Parakeet evaluation and present at the next sprint review.
         """,
         [(0,12,"Quick career check-in, then this week's priorities."),(390,440,"I want to go deeper on speech models — could I own the Parakeet evaluation?"),(730,790,"Decision: you lead the Parakeet evaluation and present at the next sprint review.")])
    }
    private static func seed1zh() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("每周产品例会",
         "会议概览\n团队回顾了迭代进展，确定 v1.0 以单说话人转写发布；说话人分离继续藏在功能开关后面。发布目标定在月底，前提是隐私文案评审通过。\n\n要点\n• 本地转写管线在测试集上达到 92% 准确率\n• 说话人分离实验推迟到下一迭代\n• 提审前完成隐私文案评审\n• 音频默认保留 30 天，可在设置中调整\n• v1.0 只提供 Markdown、TXT、SRT 导出\n\n风险\n• 重叠语音测试集若继续不达标，说话人分离会再次顺延\n• 隐私文案评审是目前唯一的提审阻塞项\n• 30 天保留期可能不满足企业客户要求\n\n待解问题\n• Northwind 试点是否需要 Windows 版本？\n• v1.0 发布后由谁负责支持？\n\n下一步\n• 冻结功能范围，28 号切发布候选版本",
         ["v1.0 以单说话人模式发布，说话人分离放在开关后面", "默认保持纯本地处理，数据不出设备", "音频默认保留 30 天，用户可自行调整", "v1.0 只提供 Markdown、TXT、SRT 三种导出"],
         [("Maya", "跑说话人分离实验", "下一迭代"), ("Ken", "起草 App Store 截图", "周五"),
          ("Maya", "复审隐私文案", "提审前"), ("Phinn", "切发布候选版本", "28 号"),
          ("Ken", "写 v1.0 更新日志", "周四"), ("Maya", "提交准确率测试报告", "明天"),
          ("Phinn", "确认 App Store 定价", "下周")],
         """
         [00:00] Phinn: 开始迭代回顾。本地转写管线在测试集上到了 92% 准确率。
         [02:30] Maya: 好的。下一迭代我来负责说话人分离实验。
         [04:15] Ken: 音频保留默认多久？调研里大家觉得三十天比较合适。
         [05:10] Phinn: 决议：v1.0 以单说话人模式发布，说话人分离先放开关后面。
         [07:40] Maya: 同意。保留天数我做成可配置，不写死三十天。
         [09:20] Ken: 导出格式的话，Markdown、TXT、SRT 三个够首发了。
         [10:05] Phinn: 决议：v1.0 就这三种，不再加。
         [11:30] Ken: 我周五前把 App Store 截图出初稿，隐私文案 Maya 复审。
         [12:20] Phinn: 28 号切发布候选版本。待办都已记录，散会。
         """,
         [(0,14,"开始迭代回顾。本地转写管线在测试集上到了 92% 准确率。"),(150,186,"下一迭代我来负责说话人分离实验。"),(255,282,"音频保留默认多久？调研里大家觉得三十天比较合适。"),(310,352,"决议：v1.0 以单说话人模式发布，说话人分离先放开关后面。"),(460,505,"同意。保留天数我做成可配置，不写死三十天。"),(560,590,"导出格式的话，Markdown、TXT、SRT 三个够首发了。"),(605,630,"决议：v1.0 就这三种，不再加。"),(690,725,"我周五前把 App Store 截图出初稿，隐私文案 Maya 复审。"),(740,760,"28 号切发布候选版本。待办都已记录，散会。")])
    }
    private static func seed2zh() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("客户启动会 — Northwind",
         "会议概览\n确定了 Northwind 亚太办公室数据看板的落地范围:一期覆盖三个站点,全部本地化部署。\n\n要点\n• 一期:新加坡、东京、悉尼 — 下月第一周启动\n• 合规硬性要求:所有数据处理留在本地机房\n• 每周二 10:00 例会检查点",
         ["一期范围 = 亚太三办公室,下月第一周启动", "所有处理必须留在本地机房(合规硬性要求)"],
         [("Sarah", "发送 SOW 与入职清单", "本周"), ("Phinn", "准备部署时间表", "下周二")],
         """
         [00:00] Sarah: 感谢参会,我们来定一下亚太办公室数据看板的落地范围。
         [04:12] Phinn: 一期覆盖新加坡、东京、悉尼,下月第一周可以启动。
         [09:40] Sarah: 合规团队要求所有处理必须留在本地,这是硬性要求。
         [15:05] Phinn: 明白,全部本地运行,数据不出机器。
         [22:30] Sarah: 那每周二上午十点做一次例会检查。
         """,
         [(0,16,"感谢参会,我们来定一下亚太办公室数据看板的落地范围。"),(252,300,"一期覆盖新加坡、东京、悉尼,下月第一周可以启动。"),(580,640,"合规团队要求所有处理必须留在本地,这是硬性要求。"),(905,940,"明白,全部本地运行,数据不出机器。")])
    }
    private static func seed3zh() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("与 Maya 的 1:1",
         "会议概览\n职业成长沟通:Maya 将主导 Parakeet 语音模型评测,并在下次迭代评审上汇报结论。\n\n要点\n• Maya 负责主导 Parakeet 评测\n• 评测结论在下一次迭代评审上汇报\n• 成长路径:模型评测 → 端侧微调",
         ["Maya 主导 Parakeet 评测,并在下次迭代评审汇报"],
         [("Maya", "完成 Parakeet 评测并准备汇报", "迭代评审")],
         """
         [00:00] Phinn: 先做个职业发展沟通,再过一下这周的重点。
         [06:30] Maya: 我想深入做语音模型方向,Parakeet 评测能不能由我来负责?
         [12:10] Phinn: 当然。决议:Maya 主导 Parakeet 评测,下次迭代评审汇报结论。
         """,
         [(0,12,"先做个职业发展沟通,再过一下这周的重点。"),(390,440,"我想深入做语音模型方向,Parakeet 评测能不能由我来负责?"),(730,790,"决议:Maya 主导 Parakeet 评测,下次迭代评审汇报结论。")])
    }
    // zh-Hant used to reuse the zh-Hans pack, so Traditional Chinese users
    // saw Simplified sample notes on first launch — wrong for TW/HK.
    private static func seed1zht() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("每週產品例會",
         "會議概覽\n團隊回顧了迭代進展，確定 v1.0 以單說話人轉寫發布；說話人分離繼續藏在功能開關後面。發布目標定在月底，前提是隱私文案評審通過。\n\n要點\n• 本地轉寫管線在測試集上達到 92% 準確率\n• 說話人分離實驗推遲到下一迭代\n• 提審前完成隱私文案評審\n• 音訊預設保留 30 天，可在設定中調整\n• v1.0 只提供 Markdown、TXT、SRT 匯出\n\n風險\n• 重疊語音測試集若繼續不達標，說話人分離會再次順延\n• 隱私文案評審是目前唯一的提審阻塞項\n• 30 天保留期可能不滿足企業客戶要求\n\n待解問題\n• Northwind 試點是否需要 Windows 版本？\n• v1.0 發布後由誰負責支援？\n\n下一步\n• 凍結功能範圍，28 號切發布候選版本",
         ["v1.0 以單說話人模式發布，說話人分離放在開關後面", "預設保持純本地處理，資料不出裝置", "音訊預設保留 30 天，使用者可自行調整", "v1.0 只提供 Markdown、TXT、SRT 三種匯出"],
         [("Maya", "跑說話人分離實驗", "下一迭代"), ("Ken", "起草 App Store 截圖", "週五"),
          ("Maya", "複審隱私文案", "提審前"), ("Phinn", "切發布候選版本", "28 號"),
          ("Ken", "寫 v1.0 更新日誌", "週四"), ("Maya", "提交準確率測試報告", "明天"),
          ("Phinn", "確認 App Store 定價", "下週")],
         """
         [00:00] Phinn: 開始迭代回顧。本地轉寫管線在測試集上到了 92% 準確率。
         [02:30] Maya: 好的。下一迭代我來負責說話人分離實驗。
         [04:15] Ken: 音訊保留預設多久？調研裡大家覺得三十天比較合適。
         [05:10] Phinn: 決議：v1.0 以單說話人模式發布，說話人分離先放開關後面。
         [07:40] Maya: 同意。保留天數我做成可設定，不寫死三十天。
         [09:20] Ken: 匯出格式的話，Markdown、TXT、SRT 三個夠首發了。
         [10:05] Phinn: 決議：v1.0 就這三種，不再加。
         [11:30] Ken: 我週五前把 App Store 截圖出初稿，隱私文案 Maya 複審。
         [12:20] Phinn: 28 號切發布候選版本。待辦都已記錄，散會。
         """,
         [(0,14,"開始迭代回顧。本地轉寫管線在測試集上到了 92% 準確率。"),(150,186,"下一迭代我來負責說話人分離實驗。"),(255,282,"音訊保留預設多久？調研裡大家覺得三十天比較合適。"),(310,352,"決議：v1.0 以單說話人模式發布，說話人分離先放開關後面。"),(460,505,"同意。保留天數我做成可設定，不寫死三十天。"),(560,590,"匯出格式的話，Markdown、TXT、SRT 三個夠首發了。"),(605,630,"決議：v1.0 就這三種，不再加。"),(690,725,"我週五前把 App Store 截圖出初稿，隱私文案 Maya 複審。"),(740,760,"28 號切發布候選版本。待辦都已記錄，散會。")])
    }
    private static func seed2zht() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("客戶啟動會 — Northwind",
         "會議概覽\n確定了 Northwind 亞太辦公室資料看板的落地範圍：一期覆蓋三個站點，全部本地化部署。\n\n要點\n• 一期：新加坡、東京、雪梨 — 下月第一週啟動\n• 合規硬性要求：所有資料處理留在本地機房\n• 每週二 10:00 例會檢查點",
         ["一期範圍 = 亞太三辦公室，下月第一週啟動", "所有處理必須留在本地機房（合規硬性要求）"],
         [("Sarah", "發送 SOW 與入職清單", "本週"), ("Phinn", "準備部署時間表", "下週二")],
         """
         [00:00] Sarah: 感謝參會，我們來定一下亞太辦公室資料看板的落地範圍。
         [04:12] Phinn: 一期覆蓋新加坡、東京、雪梨，下月第一週可以啟動。
         [09:40] Sarah: 合規團隊要求所有處理必須留在本地，這是硬性要求。
         [15:05] Phinn: 明白，全部本地執行，資料不出機器。
         [22:30] Sarah: 那每週二上午十點做一次例會檢查。
         """,
         [(0,16,"感謝參會，我們來定一下亞太辦公室資料看板的落地範圍。"),(252,300,"一期覆蓋新加坡、東京、雪梨，下月第一週可以啟動。"),(580,640,"合規團隊要求所有處理必須留在本地，這是硬性要求。"),(905,940,"明白，全部本地執行，資料不出機器。")])
    }
    private static func seed3zht() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("與 Maya 的 1:1",
         "會議概覽\n職涯成長溝通：Maya 將主導 Parakeet 語音模型評測，並在下次迭代評審上匯報結論。\n\n要點\n• Maya 負責主導 Parakeet 評測\n• 評測結論在下一次迭代評審上匯報\n• 成長路徑：模型評測 → 端側微調",
         ["Maya 主導 Parakeet 評測，並在下次迭代評審匯報"],
         [("Maya", "完成 Parakeet 評測並準備匯報", "迭代評審")],
         """
         [00:00] Phinn: 先做個職涯發展溝通，再過一下這週的重點。
         [06:30] Maya: 我想深入做語音模型方向，Parakeet 評測能不能由我來負責？
         [12:10] Phinn: 當然。決議：Maya 主導 Parakeet 評測，下次迭代評審匯報結論。
         """,
         [(0,12,"先做個職涯發展溝通，再過一下這週的重點。"),(390,440,"我想深入做語音模型方向，Parakeet 評測能不能由我來負責？"),(730,790,"決議：Maya 主導 Parakeet 評測，下次迭代評審匯報結論。")])
    }
    private static func seed1ja() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("週次プロダクト会議",
         "概要\nチームはスプリントの進捗を振り返り、v1.0 をシングルスピーカー文字起こしでリリースすることに合意。話者分離は機能フラグの内側に残します。リリースは今月末を目標に、プライバシー文面のレビュー完了が条件です。\n\n要点\n• ローカル文字起こしはテストセットで 92% の精度に到達\n• 話者分離の実験は次スプリントへ\n• 申請前にプライバシー文面をレビュー\n• 音声の保持は既定 30 日、設定で変更可能\n• v1.0 の書き出しは Markdown・TXT・SRT の3形式\n\nリスク\n• 重なり合う音声のテストが通らない場合、話者分離は再び先送り\n• プライバシー文面のレビューが申請前の唯一のブロッカー\n• 30日の保持期間では企業顧客の要件を満たせない可能性\n\n未解決の論点\n• Northwind のパイロットに Windows 版は必要か\n• v1.0 リリース後のサポートは誰が担当するか\n\n次のステップ\n• 機能範囲を凍結し、28日にリリース候補版を作成",
         ["v1.0 はシングルスピーカーモードでリリースし、話者分離はフラグの内側に置く", "端末内処理のみを既定として維持する", "音声の保持は既定 30 日とし、ユーザーが変更できる", "v1.0 の書き出しは Markdown・TXT・SRT の3形式のみ"],
         [("Maya", "話者分離実験の実施", "次スプリント"), ("Ken", "App Store スクリーンショットの作成", "金曜"),
          ("Maya", "プライバシー文面のレビュー", "申請前"), ("Phinn", "リリース候補版の作成", "28日"),
          ("Ken", "v1.0 のリリースノート作成", "木曜"), ("Maya", "精度テストのレポート共有", "明日"),
          ("Phinn", "App Store の価格を確定", "来週")],
         """
         [00:00] Phinn: スプリントレビューを始めます。ローカル文字起こしの精度はテストセットで 92% に到達しました。
         [02:30] Maya: 次のスプリントでは、私が話者分離の実験を担当します。
         [04:15] Ken: 音声の保持は既定でどれくらいにしますか。調査では30日が妥当でした。
         [05:10] Phinn: 決定事項。v1.0 はシングルスピーカーモードで出し、話者分離はフラグの内側に。
         [07:40] Maya: 同意です。保持期間は30日を固定にせず、設定で変えられるようにします。
         [09:20] Ken: 書き出しは Markdown・TXT・SRT の3形式で初回は十分かと。
         [10:05] Phinn: 決定事項。v1.0 はその3形式のみ。それ以上は足しません。
         [11:30] Ken: 金曜までに App Store のスクリーンショットを用意します。文面は Maya が確認。
         [12:20] Phinn: 28日にリリース候補版を作成。アクション項目は記録済み、散会します。
         """,
         [(0,14,"スプリントレビューを始めます。ローカル文字起こしの精度はテストセットで 92% に到達しました。"),(150,186,"次のスプリントでは、私が話者分離の実験を担当します。"),(255,282,"音声の保持は既定でどれくらいにしますか。調査では30日が妥当でした。"),(310,352,"決定事項。v1.0 はシングルスピーカーモードで出し、話者分離はフラグの内側に。"),(460,505,"同意です。保持期間は30日を固定にせず、設定で変えられるようにします。"),(560,590,"書き出しは Markdown・TXT・SRT の3形式で初回は十分かと。"),(605,630,"決定事項。v1.0 はその3形式のみ。それ以上は足しません。"),(690,725,"金曜までに App Store のスクリーンショットを用意します。文面は Maya が確認。"),(740,760,"28日にリリース候補版を作成。アクション項目は記録済み、散会します。")])
    }
    private static func seed2ja() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("キックオフミーティング — Northwind",
         "概要\nNorthwind のアジア太平洋オフィス向けダッシュボード展開の範囲を確定。フェーズ1は3拠点、すべてオンプレミスで運用します。\n\n要点\n• フェーズ1:シンガポール・東京・シドニー 来月第1週開始\n• コンプライアンス要件:すべての処理をオンプレミスに維持\n• 毎週火曜 10:00 に定例チェック",
         ["フェーズ1 = アジア太平洋3拠点、来月第1週に開始", "すべての処理はオンプレミス維持(コンプライアンス上の必須要件)"],
         [("Sarah", "SOW とオンボーディングチェックリストの送付", "今週"), ("Phinn", "デプロイ時間表の作成", "来週火曜")],
         """
         [00:00] Sarah: ご参加ありがとうございます。アジア太平洋オフィス向けダッシュボードの範囲を決めましょう。
         [04:12] Phinn: フェーズ1はシンガポール・東京・シドニーです。来月第1週に開始できます。
         [09:40] Sarah: コンプライアンスチームはすべての処理をオンプレミスに留めることを必須としています。
         [15:05] Phinn: 承知しました。すべてローカルで実行され、データは端末の外に出ません。
         [22:30] Sarah: 毎週火曜の10時に定例チェックをしましょう。
         """,
         [(0,16,"ご参加ありがとうございます。アジア太平洋オフィス向けダッシュボードの範囲を決めましょう。"),(252,300,"フェーズ1はシンガポール・東京・シドニーです。来月第1週に開始できます。"),(580,640,"コンプライアンスチームはすべての処理をオンプレミスに留めることを必須としています。"),(905,940,"承知しました。すべてローカルで実行され、データは端末の外に出ません。")])
    }
    private static func seed3ja() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("Maya との 1:1",
         "概要\nキャリア面談:Maya が Parakeet 音声モデルの評価を主導し、次回スプリントレビューで結果を報告します。\n\n要点\n• Maya が Parakeet 評価を主導\n• 結果は次回スプリントレビューで報告\n• 成長パス:モデル評価 → 端末側ファインチューニング",
         ["Maya が Parakeet 評価を主導し、次回スプリントレビューで報告"],
         [("Maya", "Parakeet 評価の実施と報告準備", "スプリントレビュー")],
         """
         [00:00] Phinn: まずキャリアの面談から、その後に今週の優先事項を。
         [06:30] Maya: 音声モデルを深くやりたいです。Parakeet の評価を私が担当してもいいですか?
         [12:10] Phinn: もちろん。決定:Maya が Parakeet 評価を主導し、次回スプリントレビューで報告します。
         """,
         [(0,12,"まずキャリアの面談から、その後に今週の優先事項を。"),(390,440,"音声モデルを深くやりたいです。Parakeet の評価を私が担当してもいいですか?"),(730,790,"決定:Maya が Parakeet 評価を主導し、次回スプリントレビューで報告します。")])
    }

    private static func seed1ko() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("주간 제품 싱크",
         "개요\n팀은 스프린트 진행 상황을 검토했고, 단일 화자 받아쓰기로 v1.0을 출시하기로 했습니다. 화자 구분은 기능 플래그 뒤에 둡니다. 출시 목표는 이번 달 말이며, 개인정보 문구 검토가 조건입니다.\n\n핵심\n• 로컬 받아쓰기 파이프라인이 테스트 세트에서 92% 정확도 달성\n• 화자 구분 실험은 다음 스프린트로 연기\n• 제출 전 개인정보 문구 검토 배정\n• 오디오 보관은 기본 30일, 설정에서 변경 가능\n• v1.0 내보내기는 Markdown·TXT·SRT 세 가지\n\n리스크\n• 겹치는 음성 테스트가 계속 실패하면 화자 구분은 또 연기됩니다\n• 개인정보 문구 검토가 제출 전 유일한 차단 요인입니다\n• 30일 보관은 기업 고객 요구를 충족하지 못할 수 있습니다\n\n미해결 질문\n• Northwind 파일럿에 Windows 빌드가 필요한가요?\n• v1.0 출시 후 지원은 누가 맡나요?\n\n다음 단계\n• 기능 범위를 동결하고 28일에 출시 후보 버전 빌드",
         ["단일 화자 모드로 v1.0 출시, 화자 구분은 플래그 뒤에 유지", "기본값은 온디바이스 처리만 유지", "오디오 보관은 기본 30일, 사용자가 변경 가능", "v1.0 내보내기는 Markdown·TXT·SRT 세 가지만"],
         [("Maya", "화자 구분 실험 실행", "다음 스프린트"), ("Ken", "App Store 스크린샷 초안 작성", "금요일"),
          ("Maya", "개인정보 문구 검토", "제출 전"), ("Phinn", "출시 후보 버전 빌드", "28일"),
          ("Ken", "v1.0 릴리스 노트 작성", "목요일"), ("Maya", "정확도 테스트 보고서 공유", "내일"),
          ("Phinn", "App Store 가격 확정", "다음 주")],
         """
         [00:00] Phinn: 스프린트 리뷰부터 시작하죠. 로컬 받아쓰기 파이프라인이 테스트 세트에서 92% 정확도를 기록했습니다.
         [02:30] Maya: 좋네요. 다음 스프린트에서는 제가 화자 구분 실험을 맡겠습니다.
         [04:15] Ken: 오디오 보관 기본값은 어떻게 할까요? 설문에서는 30일이 적당했습니다.
         [05:10] Phinn: 결정: v1.0은 단일 화자 모드로 출시하고 화자 구분은 플래그 뒤에 둡니다.
         [07:40] Maya: 동의합니다. 보관 기간은 30일로 고정하지 말고 설정에서 바꿀 수 있게 하죠.
         [09:20] Ken: 내보내기는 Markdown·TXT·SRT 세 가지면 충분할 것 같습니다.
         [10:05] Phinn: 결정: v1.0은 그 세 가지만. 더 늘리지 않습니다.
         [11:30] Ken: 금요일까지 App Store 스크린샷 초안을 만들고, Maya가 개인정보 문구를 검토합니다.
         [12:20] Phinn: 28일에 출시 후보 버전을 빌드합니다. 할 일은 정리됐고, 회의를 마칩니다.
         """,
         [(0,14,"스프린트 리뷰부터 시작하죠. 로컬 받아쓰기 파이프라인이 테스트 세트에서 92% 정확도를 기록했습니다."),(150,186,"다음 스프린트에서는 제가 화자 구분 실험을 맡겠습니다."),(255,282,"오디오 보관 기본값은 어떻게 할까요? 설문에서는 30일이 적당했습니다."),(310,352,"결정: v1.0은 단일 화자 모드로 출시하고 화자 구분은 플래그 뒤에 둡니다."),(460,505,"동의합니다. 보관 기간은 30일로 고정하지 말고 설정에서 바꿀 수 있게 하죠."),(560,590,"내보내기는 Markdown·TXT·SRT 세 가지면 충분할 것 같습니다."),(605,630,"결정: v1.0은 그 세 가지만. 더 늘리지 않습니다."),(690,725,"금요일까지 App Store 스크린샷 초안을 만들고, Maya가 개인정보 문구를 검토합니다."),(740,760,"28일에 출시 후보 버전을 빌드합니다. 할 일은 정리됐고, 회의를 마칩니다.")])
    }
    private static func seed2ko() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("고객 킥오프 — Northwind",
         "개요\nNorthwind 아시아태평양 지사의 분석 대시보드 도입 범위를 확정했습니다. 1단계는 3개 사이트이며 모든 데이터는 온프레미스에서 처리합니다.\n\n핵심\n• 1단계: 싱가포르, 도쿄, 시드니 — 다음 달 첫째 주 시작\n• 규정상 모든 데이터는 온프레미스에 보관\n• 매주 화요일 10:00 정기 점검",
         ["1단계 = 아시아태평양 3개 지사, 다음 달 첫째 주 시작", "모든 처리는 온프레미스 유지(규정상 필수)"],
         [("Sarah", "SOW와 온보딩 체크리스트 발송", "이번 주"), ("Phinn", "배포 일정 준비", "다음 주 화요일")],
         """
         [00:00] Sarah: 참석해 주셔서 감사합니다. 아시아태평양 지사 대시보드 도입 범위를 정하죠.
         [04:12] Phinn: 1단계는 싱가포르, 도쿄, 시드니입니다. 다음 달 첫째 주에 시작할 수 있습니다.
         [09:40] Sarah: 규정팀은 모든 처리가 온프레미스에 머물러야 한다고 요구합니다.
         [15:05] Phinn: 이해했습니다. 모든 것이 로컬에서 실행되고 데이터는 기기 밖으로 나가지 않습니다.
         [22:30] Sarah: 매주 화요일 10시에 점검 회의를 하죠.
         """,
         [(0,16,"참석해 주셔서 감사합니다. 아시아태평양 지사 대시보드 도입 범위를 정하죠."),(252,300,"1단계는 싱가포르, 도쿄, 시드니입니다. 다음 달 첫째 주에 시작할 수 있습니다."),(580,640,"규정팀은 모든 처리가 온프레미스에 머물러야 한다고 요구합니다."),(905,940,"모든 것이 로컬에서 실행되고 데이터는 기기 밖으로 나가지 않습니다.")])
    }
    private static func seed3ko() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("Maya와 1:1",
         "개요\n커리어 점검: Maya가 Parakeet 음성 모델 평가를 맡고 다음 스프린트 리뷰에서 결과를 발표합니다.\n\n핵심\n• Maya가 Parakeet 평가 담당\n• 결과는 다음 스프린트 리뷰에서 공유\n• 성장 경로: 모델 평가 → 온디바이스 파인튜닝",
         ["Maya가 Parakeet 평가를 맡고 다음 스프린트 리뷰에서 보고"],
         [("Maya", "Parakeet 평가 실행 및 결과 준비", "스프린트 리뷰")],
         """
         [00:00] Phinn: 커리어 이야기부터 시작하고, 이번 주 우선순위를 정하죠.
         [06:30] Maya: 음성 모델을 더 깊이 하고 싶어요. 제가 Parakeet 평가를 맡아도 될까요?
         [12:10] Phinn: 물론이죠. 결정: Maya가 Parakeet 평가를 맡고 다음 스프린트 리뷰에서 발표합니다.
         """,
         [(0,12,"커리어 이야기부터 시작하고, 이번 주 우선순위를 정하죠."),(390,440,"음성 모델을 더 깊이 하고 싶어요. 제가 Parakeet 평가를 맡아도 될까요?"),(730,790,"결정: Maya가 Parakeet 평가를 맡고 다음 스프린트 리뷰에서 발표합니다.")])
    }

    private static func seed1fr() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("Synchro produit hebdomadaire",
         "APERÇU\nL'équipe a revu l'avancement du sprint et validé la sortie de la v1.0 avec transcription mono-locuteur ; la diarisation reste derrière un flag. La sortie vise la fin du mois, sous réserve de la relecture des textes de confidentialité.\n\nPOINTS CLÉS\n• Le pipeline de transcription local atteint 92 % de précision sur le jeu de test\n• L'expérience de diarisation est reportée au prochain sprint\n• Relecture des textes de confidentialité avant soumission\n• Conservation audio : 30 jours par défaut, réglable dans les réglages\n• La v1.0 exporte en Markdown, TXT et SRT\n\nRISQUES\n• La diarisation glisse encore si les tests de chevauchement échouent\n• La relecture des textes est le seul frein avant la soumission\n• 30 jours de conservation peuvent ne pas suffire aux entreprises\n\nQUESTIONS OUVERTES\n• Le pilote Northwind a-t-il besoin d'une version Windows ?\n• Qui assure le support après la v1.0 ?\n\nPROCHAINES ÉTAPES\n• Figer le périmètre et produire la version candidate le 28",
         ["Sortir la v1.0 en mono-locuteur ; diarisation derrière un flag", "Conserver le traitement 100 % local par défaut", "La conservation audio est de 30 jours par défaut et reste réglable", "La v1.0 n'exporte qu'en Markdown, TXT et SRT"],
         [("Maya", "Lancer l'expérience de diarisation", "Prochain sprint"), ("Ken", "Préparer les captures App Store", "Vendredi"),
          ("Maya", "Relire les textes de confidentialité", "Avant soumission"), ("Phinn", "Figer la version candidate", "Le 28"),
          ("Ken", "Rédiger les notes de version v1.0", "Jeudi"), ("Maya", "Partager le rapport de précision", "Demain"),
          ("Phinn", "Valider le prix App Store", "Semaine prochaine")],
         """
         [00:00] Phinn: Commençons par la revue du sprint. Le pipeline de transcription local atteint 92 % de précision sur notre jeu de test.
         [02:30] Maya: Parfait. Pour le prochain sprint, je prends l'expérience de diarisation.
         [04:15] Ken: Quelle conservation audio par défaut ? Trente jours semblait juste dans l'enquête.
         [05:10] Phinn: Décision : on sort la v1.0 en mono-locuteur et la diarisation reste derrière un flag.
         [07:40] Maya: D'accord. Je rends la durée réglable au lieu de la figer à trente jours.
         [09:20] Ken: En export, Markdown, TXT et SRT suffisent pour le lancement.
         [10:05] Phinn: Décision : la v1.0 sort avec ces trois formats. Rien de plus.
         [11:30] Ken: Je prépare les captures App Store pour vendredi, et Maya relit les textes de confidentialité.
         [12:20] Phinn: Version candidate le 28. Les actions sont notées, réunion terminée.
         """,
         [(0,14,"Commençons par la revue du sprint. Le pipeline de transcription local atteint 92 % de précision sur notre jeu de test."),(150,186,"Pour le prochain sprint, je prends l'expérience de diarisation."),(255,282,"Quelle conservation audio par défaut ? Trente jours semblait juste dans l'enquête."),(310,352,"Décision : on sort la v1.0 en mono-locuteur et la diarisation reste derrière un flag."),(460,505,"D'accord. Je rends la durée réglable au lieu de la figer à trente jours."),(560,590,"En export, Markdown, TXT et SRT suffisent pour le lancement."),(605,630,"Décision : la v1.0 sort avec ces trois formats. Rien de plus."),(690,725,"Je prépare les captures App Store pour vendredi, et Maya relit les textes de confidentialité."),(740,760,"Version candidate le 28. Les actions sont notées, réunion terminée.")])
    }
    private static func seed2fr() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("Lancement client — Northwind",
         "APERÇU\nCadrage du déploiement du tableau de bord analytique pour les bureaux APAC de Northwind ; la phase un couvre trois sites avec traitement sur site.\n\nPOINTS CLÉS\n• Phase un : Singapour, Tokyo, Sydney — première semaine du mois prochain\n• La conformité exige que toutes les données restent sur site\n• Point hebdomadaire chaque mardi à 10 h",
         ["Phase un = bureaux APAC, première semaine du mois prochain", "Tout le traitement doit rester sur site (exigence de conformité)"],
         [("Sarah", "Envoyer le SOW et la checklist d'onboarding", "Cette semaine"), ("Phinn", "Préparer le calendrier de déploiement", "Mardi prochain")],
         """
         [00:00] Sarah: Merci d'être là. Cadrons le déploiement du tableau de bord pour vos bureaux APAC.
         [04:12] Phinn: La phase un couvre Singapour, Tokyo et Sydney. On peut démarrer la première semaine du mois prochain.
         [09:40] Sarah: Notre équipe conformité exige que tout le traitement reste sur site.
         [15:05] Phinn: Compris. Tout tourne en local, rien ne quitte les machines.
         [22:30] Sarah: Faisons un point hebdomadaire, le mardi à dix heures.
         """,
         [(0,16,"Merci d'être là. Cadrons le déploiement du tableau de bord pour vos bureaux APAC."),(252,300,"La phase un couvre Singapour, Tokyo et Sydney. On peut démarrer la première semaine du mois prochain."),(580,640,"Notre équipe conformité exige que tout le traitement reste sur site."),(905,940,"Compris. Tout tourne en local, rien ne quitte les machines.")])
    }
    private static func seed3fr() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("1:1 avec Maya",
         "APERÇU\nPoint carrière : Maya pilotera l'évaluation du modèle vocal Parakeet et présentera les résultats à la prochaine revue de sprint.\n\nPOINTS CLÉS\n• Maya prend la responsabilité de l'évaluation Parakeet\n• Présentation des résultats à la prochaine revue de sprint\n• Évolution : évaluation de modèle → fine-tuning sur appareil",
         ["Maya pilote l'évaluation Parakeet et rend compte à la revue de sprint"],
         [("Maya", "Réaliser l'évaluation Parakeet et préparer les résultats", "Revue de sprint")],
         """
         [00:00] Phinn: Un point carrière rapide, puis les priorités de la semaine.
         [06:30] Maya: J'aimerais approfondir les modèles vocaux. Puis-je prendre l'évaluation Parakeet ?
         [12:10] Phinn: Bien sûr. Décision : tu pilotes l'évaluation Parakeet et tu présentes à la prochaine revue.
         """,
         [(0,12,"Un point carrière rapide, puis les priorités de la semaine."),(390,440,"J'aimerais approfondir les modèles vocaux. Puis-je prendre l'évaluation Parakeet ?"),(730,790,"Décision : tu pilotes l'évaluation Parakeet et tu présentes à la prochaine revue.")])
    }

    private static func seed1de() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("Wöchentlicher Produktabgleich",
         "ÜBERBLICK\nDas Team hat den Sprint-Fortschritt geprüft und v1.0 mit Einzelsprecher-Transkription freigegeben; die Sprechertrennung bleibt hinter einem Flag. Die Veröffentlichung ist für Monatsende geplant, sofern die Datenschutztexte durch sind.\n\nKERNPUNKTE\n• Lokale Transkriptions-Pipeline erreicht 92 % Genauigkeit im Testset\n• Sprechertrennungs-Experiment auf den nächsten Sprint verschoben\n• Datenschutztexte vor der Einreichung prüfen\n• Audio-Aufbewahrung: 30 Tage standardmäßig, in den Einstellungen änderbar\n• v1.0 exportiert Markdown, TXT und SRT\n\nRISIKEN\n• Die Sprechertrennung verschiebt sich erneut, wenn die Überlappungstests scheitern\n• Die Textprüfung ist der einzige Blocker vor der Einreichung\n• 30 Tage Aufbewahrung reichen Unternehmen womöglich nicht\n\nOFFENE FRAGEN\n• Braucht der Northwind-Pilot eine Windows-Version?\n• Wer übernimmt den Support nach v1.0?\n\nNÄCHSTE SCHRITTE\n• Umfang einfrieren und am 28. den Release Candidate bauen",
         ["v1.0 mit Einzelsprecher-Modus ausliefern; Sprechertrennung hinter einem Flag", "Standardmäßig nur lokale Verarbeitung beibehalten", "Audio bleibt 30 Tage, bleibt aber vom Nutzer einstellbar", "v1.0 exportiert ausschließlich Markdown, TXT und SRT"],
         [("Maya", "Sprechertrennungs-Experiment durchführen", "Nächster Sprint"), ("Ken", "App-Store-Screenshots entwerfen", "Freitag"),
          ("Maya", "Datenschutztexte prüfen", "Vor der Einreichung"), ("Phinn", "Release-Kandidat bauen", "Am 28."),
          ("Ken", "Release Notes für v1.0 schreiben", "Donnerstag"), ("Maya", "Genauigkeitsbericht teilen", "Morgen"),
          ("Phinn", "App-Store-Preis bestätigen", "Nächste Woche")],
         """
         [00:00] Phinn: Beginnen wir mit dem Sprint-Review. Die lokale Transkriptions-Pipeline erreicht 92 % Genauigkeit im Testset.
         [02:30] Maya: Sehr gut. Im nächsten Sprint übernehme ich das Sprechertrennungs-Experiment.
         [04:15] Ken: Wie lange soll Audio standardmäßig bleiben? In der Umfrage klangen 30 Tage richtig.
         [05:10] Phinn: Entscheidung: Wir liefern v1.0 mit Einzelsprecher-Modus aus und behalten die Sprechertrennung hinter einem Flag.
         [07:40] Maya: Einverstanden. Ich mache die Dauer einstellbar, statt sie auf 30 Tage festzunageln.
         [09:20] Ken: Beim Export reichen Markdown, TXT und SRT für den Start.
         [10:05] Phinn: Entscheidung: v1.0 kommt mit diesen drei Formaten. Mehr nicht.
         [11:30] Ken: Ich entwerfe die App-Store-Screenshots bis Freitag, Maya prüft die Datenschutztexte.
         [12:20] Phinn: Release-Kandidat am 28. Aufgaben sind notiert, Besprechung beendet.
         """,
         [(0,14,"Beginnen wir mit dem Sprint-Review. Die lokale Transkriptions-Pipeline erreicht 92 % Genauigkeit im Testset."),(150,186,"Im nächsten Sprint übernehme ich das Sprechertrennungs-Experiment."),(255,282,"Wie lange soll Audio standardmäßig bleiben? In der Umfrage klangen 30 Tage richtig."),(310,352,"Entscheidung: Wir liefern v1.0 mit Einzelsprecher-Modus aus und behalten die Sprechertrennung hinter einem Flag."),(460,505,"Einverstanden. Ich mache die Dauer einstellbar, statt sie auf 30 Tage festzunageln."),(560,590,"Beim Export reichen Markdown, TXT und SRT für den Start."),(605,630,"Entscheidung: v1.0 kommt mit diesen drei Formaten. Mehr nicht."),(690,725,"Ich entwerfe die App-Store-Screenshots bis Freitag, Maya prüft die Datenschutztexte."),(740,760,"Release-Kandidat am 28. Aufgaben sind notiert, Besprechung beendet.")])
    }
    private static func seed2de() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("Kunden-Kickoff — Northwind",
         "ÜBERBLICK\nUmfang für die Einführung des Analyse-Dashboards in den APAC-Büros von Northwind festgelegt; Phase eins umfasst drei Standorte mit lokaler Datenverarbeitung.\n\nKERNPUNKTE\n• Phase eins: Singapur, Tokio, Sydney — ab der ersten Woche des nächsten Monats\n• Compliance verlangt, dass alle Daten vor Ort bleiben\n• Wöchentlicher Checkpoint dienstags um 10:00",
         ["Phase eins = APAC-Büros, ab der ersten Woche des nächsten Monats", "Jede Verarbeitung muss vor Ort bleiben (Compliance-Vorgabe)"],
         [("Sarah", "SOW und Onboarding-Checkliste senden", "Diese Woche"), ("Phinn", "Einführungszeitplan vorbereiten", "Nächsten Dienstag")],
         """
         [00:00] Sarah: Danke fürs Kommen. Legen wir den Umfang für das Dashboard in Ihren APAC-Büros fest.
         [04:12] Phinn: Phase eins umfasst Singapur, Tokio und Sydney. Wir können in der ersten Woche des nächsten Monats starten.
         [09:40] Sarah: Unser Compliance-Team verlangt, dass alle Verarbeitung vor Ort bleibt.
         [15:05] Phinn: Verstanden. Alles läuft lokal, nichts verlässt die Geräte.
         [22:30] Sarah: Machen wir einen wöchentlichen Checkpoint, dienstags um zehn.
         """,
         [(0,16,"Danke fürs Kommen. Legen wir den Umfang für das Dashboard in Ihren APAC-Büros fest."),(252,300,"Phase eins umfasst Singapur, Tokio und Sydney. Wir können in der ersten Woche des nächsten Monats starten."),(580,640,"Unser Compliance-Team verlangt, dass alle Verarbeitung vor Ort bleibt."),(905,940,"Verstanden. Alles läuft lokal, nichts verlässt die Geräte.")])
    }
    private static func seed3de() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("1:1 mit Maya",
         "ÜBERBLICK\nKarrieregespräch: Maya übernimmt die Evaluierung des Parakeet-Sprachmodells und stellt die Ergebnisse im nächsten Sprint-Review vor.\n\nKERNPUNKTE\n• Maya übernimmt die Parakeet-Evaluierung\n• Vorstellung der Ergebnisse im nächsten Sprint-Review\n• Entwicklungspfad: Modell-Evaluierung → Fine-Tuning auf dem Gerät",
         ["Maya leitet die Parakeet-Evaluierung und berichtet im Sprint-Review"],
         [("Maya", "Parakeet-Evaluierung durchführen und Ergebnisse vorbereiten", "Sprint-Review")],
         """
         [00:00] Phinn: Kurzes Karrieregespräch, dann die Prioritäten dieser Woche.
         [06:30] Maya: Ich möchte bei Sprachmodellen tiefer einsteigen. Kann ich die Parakeet-Evaluierung übernehmen?
         [12:10] Phinn: Absolut. Entscheidung: Du leitest die Parakeet-Evaluierung und stellst sie im nächsten Sprint-Review vor.
         """,
         [(0,12,"Kurzes Karrieregespräch, dann die Prioritäten dieser Woche."),(390,440,"Ich möchte bei Sprachmodellen tiefer einsteigen. Kann ich die Parakeet-Evaluierung übernehmen?"),(730,790,"Entscheidung: Du leitest die Parakeet-Evaluierung und stellst sie im nächsten Sprint-Review vor.")])
    }

    private static func seed1es() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("Sincronización semanal",
         "RESUMEN\nEl equipo revisó el avance del sprint y acordó lanzar la v1.0 con transcripción de un solo hablante; la diarización queda tras un flag. El lanzamiento se apunta a fin de mes, siempre que pase la revisión de los textos de privacidad.\n\nPUNTOS CLAVE\n• El pipeline de transcripción local alcanza un 92 % de precisión en el conjunto de prueba\n• El experimento de diarización se pospone al próximo sprint\n• Revisión de los textos de privacidad antes del envío\n• Retención de audio: 30 días por defecto, ajustable en Ajustes\n• La v1.0 exporta Markdown, TXT y SRT\n\nRIESGOS\n• La diarización se retrasa otra vez si fallan las pruebas de solapamiento\n• La revisión de textos es el único bloqueo antes del envío\n• 30 días de retención pueden no bastar a las empresas\n\nPREGUNTAS ABIERTAS\n• ¿El piloto de Northwind necesita una versión para Windows?\n• ¿Quién da soporte tras la v1.0?\n\nPRÓXIMOS PASOS\n• Congelar el alcance y cortar la versión candidata el 28",
         ["Lanzar la v1.0 en modo de un solo hablante; diarización tras un flag", "Mantener el procesamiento solo en el dispositivo por defecto", "La retención de audio es de 30 días por defecto y el usuario puede cambiarla", "La v1.0 solo exporta en Markdown, TXT y SRT"],
         [("Maya", "Ejecutar el experimento de diarización", "Próximo sprint"), ("Ken", "Preparar las capturas de App Store", "Viernes"),
          ("Maya", "Revisar los textos de privacidad", "Antes del envío"), ("Phinn", "Cortar la versión candidata", "El 28"),
          ("Ken", "Escribir las notas de la v1.0", "Jueves"), ("Maya", "Compartir el informe de precisión", "Mañana"),
          ("Phinn", "Confirmar el precio en App Store", "Próxima semana")],
         """
         [00:00] Phinn: Empecemos con la revisión del sprint. El pipeline de transcripción local alcanza un 92 % de precisión en el conjunto de prueba.
         [02:30] Maya: Genial. Para el próximo sprint me encargo del experimento de diarización.
         [04:15] Ken: ¿Cuánto audio guardamos por defecto? En la encuesta treinta días parecía lo justo.
         [05:10] Phinn: Decisión: lanzamos la v1.0 en modo de un solo hablante y dejamos la diarización tras un flag.
         [07:40] Maya: De acuerdo. Dejo la retención configurable en vez de fijarla en treinta días.
         [09:20] Ken: Para exportar, Markdown, TXT y SRT bastan en el lanzamiento.
         [10:05] Phinn: Decisión: la v1.0 sale con esos tres formatos. Nada más.
         [11:30] Ken: Preparo las capturas de App Store para el viernes y Maya revisa los textos de privacidad.
         [12:20] Phinn: Versión candidata el 28. Tareas registradas, reunión terminada.
         """,
         [(0,14,"Empecemos con la revisión del sprint. El pipeline de transcripción local alcanza un 92 % de precisión en el conjunto de prueba."),(150,186,"Para el próximo sprint me encargo del experimento de diarización."),(255,282,"¿Cuánto audio guardamos por defecto? En la encuesta treinta días parecía lo justo."),(310,352,"Decisión: lanzamos la v1.0 en modo de un solo hablante y dejamos la diarización tras un flag."),(460,505,"De acuerdo. Dejo la retención configurable en vez de fijarla en treinta días."),(560,590,"Para exportar, Markdown, TXT y SRT bastan en el lanzamiento."),(605,630,"Decisión: la v1.0 sale con esos tres formatos. Nada más."),(690,725,"Preparo las capturas de App Store para el viernes y Maya revisa los textos de privacidad."),(740,760,"Versión candidata el 28. Tareas registradas, reunión terminada.")])
    }
    private static func seed2es() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("Inicio de cliente — Northwind",
         "RESUMEN\nDefinimos el alcance del despliegue del panel de analítica para las oficinas APAC de Northwind; la fase uno cubre tres sedes con procesamiento local.\n\nPUNTOS CLAVE\n• Fase uno: Singapur, Tokio, Sídney — primera semana del próximo mes\n• El cumplimiento exige que todos los datos permanezcan en local\n• Punto de control semanal los martes a las 10:00",
         ["Fase uno = oficinas APAC, primera semana del próximo mes", "Todo el procesamiento debe permanecer en local (requisito de cumplimiento)"],
         [("Sarah", "Enviar el SOW y la lista de incorporación", "Esta semana"), ("Phinn", "Preparar el calendario de despliegue", "Próximo martes")],
         """
         [00:00] Sarah: Gracias por venir. Definamos el alcance del panel para sus oficinas APAC.
         [04:12] Phinn: La fase uno cubre Singapur, Tokio y Sídney. Podemos empezar la primera semana del próximo mes.
         [09:40] Sarah: Nuestro equipo de cumplimiento exige que todo el procesamiento sea local.
         [15:05] Phinn: Entendido. Todo se ejecuta en local y nada sale de los equipos.
         [22:30] Sarah: Hagamos un punto de control semanal, los martes a las diez.
         """,
         [(0,16,"Gracias por venir. Definamos el alcance del panel para sus oficinas APAC."),(252,300,"La fase uno cubre Singapur, Tokio y Sídney. Podemos empezar la primera semana del próximo mes."),(580,640,"Nuestro equipo de cumplimiento exige que todo el procesamiento sea local."),(905,940,"Entendido. Todo se ejecuta en local y nada sale de los equipos.")])
    }
    private static func seed3es() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("1:1 con Maya",
         "RESUMEN\nRevisión de carrera: Maya liderará la evaluación del modelo de voz Parakeet y presentará los resultados en la próxima revisión de sprint.\n\nPUNTOS CLAVE\n• Maya asume la evaluación de Parakeet\n• Presentación de resultados en la próxima revisión de sprint\n• Ruta de crecimiento: evaluación de modelos → ajuste fino en el dispositivo",
         ["Maya lidera la evaluación de Parakeet e informa en la revisión de sprint"],
         [("Maya", "Ejecutar la evaluación de Parakeet y preparar resultados", "Revisión de sprint")],
         """
         [00:00] Phinn: Una revisión rápida de carrera y luego las prioridades de la semana.
         [06:30] Maya: Quiero profundizar en los modelos de voz. ¿Puedo encargarme de la evaluación de Parakeet?
         [12:10] Phinn: Por supuesto. Decisión: lideras la evaluación de Parakeet y la presentas en la próxima revisión.
         """,
         [(0,12,"Una revisión rápida de carrera y luego las prioridades de la semana."),(390,440,"Quiero profundizar en los modelos de voz. ¿Puedo encargarme de la evaluación de Parakeet?"),(730,790,"Decisión: lideras la evaluación de Parakeet y la presentas en la próxima revisión.")])
    }

    private func defaultTitle() -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = "MMM d HH:mm"
        return f.string(from: Date())
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
