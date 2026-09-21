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
              segments_json TEXT
            )
            """)
            exec("CREATE TABLE IF NOT EXISTS meetings_fts USING fts5(title, transcript, summary, content='meetings', content_rowid='id')")
            exec("CREATE TRIGGER IF NOT EXISTS meetings_ai AFTER INSERT ON meetings BEGIN INSERT INTO meetings_fts(rowid, title, transcript, summary) VALUES (new.id, new.title, new.transcript, new.summary); END")
            exec("CREATE TRIGGER IF NOT EXISTS meetings_ad AFTER DELETE ON meetings BEGIN INSERT INTO meetings_fts(meetings_fts, rowid, title, transcript, summary) VALUES ('delete', old.id, old.title, old.transcript, old.summary); END")
            exec("CREATE TRIGGER IF NOT EXISTS meetings_au AFTER UPDATE ON meetings BEGIN INSERT INTO meetings_fts(meetings_fts, rowid, title, transcript, summary) VALUES ('delete', old.id, old.title, old.transcript, old.summary); INSERT INTO meetings_fts(rowid, title, transcript, summary) VALUES (new.id, new.title, new.transcript, new.summary); END")
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

    func createMeeting(sourceApp: String) -> Meeting {
        queue.sync {
            var m = Meeting(title: defaultTitle(), sourceApp: sourceApp, startedAt: Date(), durationSeconds: 0, status: "recording")
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO meetings (title, source_app, started_at, status) VALUES (?,?,?,?)", -1, &stmt, nil)
            bind(stmt, 1, m.title); bind(stmt, 2, m.sourceApp)
            sqlite3_bind_double(stmt, 3, m.startedAt.timeIntervalSince1970)
            bind(stmt, 4, m.status)
            sqlite3_step(stmt); sqlite3_finalize(stmt)
            m.id = sqlite3_last_insert_rowid(db)
            return m
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
            NotificationCenter.default.post(name: .meetingsChanged, object: nil)
        }
    }

    func delete(id: Int64) {
        queue.sync {
            if let m = fetch("SELECT \(cols) FROM meetings WHERE id=\(id)").first, let p = m.audioPath {
                try? FileManager.default.removeItem(atPath: p)
            }
            exec("DELETE FROM meetings WHERE id=\(id)")
        }
        NotificationCenter.default.post(name: .meetingsChanged, object: nil)
    }

    func deleteAll() {
        let all = allMeetings()
        for m in all { delete(id: m.id) }
        // VACUUM to actually shrink the db file
        queue.sync { exec("VACUUM") }
    }

    // MARK: - helpers

    private let cols = "id,title,source_app,started_at,ended_at,duration,audio_path,transcript,summary,decisions_json,actions_json,status,segments_json"

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
            out.append(m)
        }
        sqlite3_finalize(stmt)
        return out
    }

    // MARK: - Demo seed

    /// 首次启动插入一条完整 demo meeting,保证审核员无模型/无会议时也能立刻看到全流程产出。
    /// 只 seed 一次(UserDefaults 标记),幂等。
    func seedDemoMeetingIfNeeded() {
        let flag = "seededDemoMeeting_v1"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        queue.sync {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm"
            let start = Date().addingTimeInterval(-3600)
            let m = Meeting(
                title: L10n.string("Weekly Product Sync"),
                sourceApp: "Demo",
                startedAt: start,
                endedAt: start.addingTimeInterval(1800),
                durationSeconds: 1800,
                audioPath: nil,
                transcript: """
                [00:00] Phinn: Let's start with the sprint review. The local transcription pipeline hit 92% accuracy on our test set.
                [02:30] Maya: Great. For the next sprint, I'll own the speaker-diarization experiment.
                [05:10] Phinn: Decision: we ship v1.0 with single-speaker mode and keep diarization behind a flag.
                [08:45] Ken: I'll draft the App Store screenshots by Friday, and Maya reviews the privacy copy.
                [12:20] Phinn: Action items are logged. Meeting adjourned.
                """,
                summary: L10n.string("The team reviewed the sprint and agreed to ship v1.0 with single-speaker transcription; diarization stays behind a feature flag. This is a sample meeting pre-loaded so you can explore notes, decisions and action items before your first recording."),
                decisionsJSON: "[\"Ship v1.0 with single-speaker mode; diarization behind a flag\",\"Keep on-device-only processing as the default\"]",
                actionsJSON: "[{\"owner\":\"Maya\",\"task\":\"Run speaker-diarization experiment\",\"due\":\"Next sprint\"},{\"owner\":\"Ken\",\"task\":\"Draft App Store screenshots\",\"due\":\"Friday\"}]",
                status: "ready",
                segmentsJSON: "[{\"start\":0,\"end\":14,\"text\":\"Let's start with the sprint review. The local transcription pipeline hit 92% accuracy on our test set.\"},{\"start\":150,\"end\":186,\"text\":\"For the next sprint, I'll own the speaker-diarization experiment.\"},{\"start\":310,\"end\":352,\"text\":\"Decision: we ship v1.0 with single-speaker mode and keep diarization behind a flag.\"},{\"start\":525,\"end\":560,\"text\":\"I'll draft the App Store screenshots by Friday, and Maya reviews the privacy copy.\"}]"
            )
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
            bind(stmt, 8, m.decisionsJSON)
            bind(stmt, 9, m.actionsJSON)
            bind(stmt, 10, m.transcript)
            bind(stmt, 11, m.segmentsJSON)
            sqlite3_step(stmt); sqlite3_finalize(stmt)
        }
        UserDefaults.standard.set(true, forKey: flag)
        NotificationCenter.default.post(name: .meetingsChanged, object: nil)
    }

    private func defaultTitle() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f.string(from: Date())
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
