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
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        queue.sync {
            let isZH = L10n.string("Search meetings…") != "Search meetings…"
            let ja = L10n.string("Search meetings…").contains("会議") || L10n.string("Search meetings…").contains("検索")
            // ---- locale pack ----
            let (t1, s1, d1, a1, tr1, sg1): (String, String, [String], [(String, String, String)], String, [(Int, Int, String)])
            let (t2, s2, d2, a2, tr2, sg2): (String, String, [String], [(String, String, String)], String, [(Int, Int, String)])
            let (t3, s3, d3, a3, tr3, sg3): (String, String, [String], [(String, String, String)], String, [(Int, Int, String)])
            if ja {
                (t1, s1, d1, a1, tr1, sg1) = Self.seed1ja(); (t2, s2, d2, a2, tr2, sg2) = Self.seed2ja(); (t3, s3, d3, a3, tr3, sg3) = Self.seed3ja()
            } else if isZH {
                (t1, s1, d1, a1, tr1, sg1) = Self.seed1zh(); (t2, s2, d2, a2, tr2, sg2) = Self.seed2zh(); (t3, s3, d3, a3, tr3, sg3) = Self.seed3zh()
            } else {
                (t1, s1, d1, a1, tr1, sg1) = Self.seed1en(); (t2, s2, d2, a2, tr2, sg2) = Self.seed2en(); (t3, s3, d3, a3, tr3, sg3) = Self.seed3en()
            }
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
                (Meeting(title: t1, sourceApp: "Demo", startedAt: now.addingTimeInterval(-3600), endedAt: now.addingTimeInterval(-1800), durationSeconds: 1800, audioPath: nil, transcript: tr1, summary: s1, decisionsJSON: encArr(d1), actionsJSON: encActions(a1), status: "ready", segmentsJSON: encSegs(sg1)), s1, encArr(d1), encActions(a1)),
                (Meeting(title: t2, sourceApp: "Demo", startedAt: now.addingTimeInterval(-86400*2), endedAt: now.addingTimeInterval(-86400*2+2700), durationSeconds: 2700, audioPath: nil, transcript: tr2, summary: s2, decisionsJSON: encArr(d2), actionsJSON: encActions(a2), status: "ready", segmentsJSON: encSegs(sg2)), s2, encArr(d2), encActions(a2)),
                (Meeting(title: t3, sourceApp: "Demo", startedAt: now.addingTimeInterval(-86400*5), endedAt: now.addingTimeInterval(-86400*5+1500), durationSeconds: 1500, audioPath: nil, transcript: tr3, summary: s3, decisionsJSON: encArr(d3), actionsJSON: encActions(a3), status: "ready", segmentsJSON: encSegs(sg3)), s3, encArr(d3), encActions(a3)),
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
         "OVERVIEW\nThe team reviewed sprint progress and agreed to ship v1.0 with single-speaker transcription; diarization stays behind a feature flag.\n\nKEY POINTS\n• Local transcription pipeline hit 92% accuracy on the test set\n• Diarization experiment deferred to next sprint\n• Privacy copy review assigned before submission",
         ["Ship v1.0 with single-speaker mode; diarization behind a flag", "Keep on-device-only processing as the default"],
         [("Maya", "Run speaker-diarization experiment", "Next sprint"), ("Ken", "Draft App Store screenshots", "Friday")],
         """
         [00:00] Phinn: Let's start with the sprint review. The local transcription pipeline hit 92% accuracy on our test set.
         [02:30] Maya: Great. For the next sprint, I'll own the speaker-diarization experiment.
         [05:10] Phinn: Decision: we ship v1.0 with single-speaker mode and keep diarization behind a flag.
         [08:45] Ken: I'll draft the App Store screenshots by Friday, and Maya reviews the privacy copy.
         [12:20] Phinn: Action items are logged. Meeting adjourned.
         """,
         [(0,14,"Let's start with the sprint review. The local transcription pipeline hit 92% accuracy on our test set."),(150,186,"For the next sprint, I'll own the speaker-diarization experiment."),(310,352,"Decision: we ship v1.0 with single-speaker mode and keep diarization behind a flag."),(525,560,"I'll draft the App Store screenshots by Friday, and Maya reviews the privacy copy.")])
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
         "会议概览\n团队回顾了迭代进展,确定 v1.0 以单说话人转写发布;说话人分离继续藏在功能开关后面。\n\n要点\n• 本地转写管线在测试集上达到 92% 准确率\n• 说话人分离实验推迟到下一迭代\n• 提审前完成隐私文案评审",
         ["v1.0 以单说话人模式发布;说话人分离放在开关后面", "默认保持纯本地处理,数据不出设备"],
         [("Maya", "跑说话人分离实验", "下一迭代"), ("Ken", "起草 App Store 截图", "周五")],
         """
         [00:00] Phinn: 开始迭代回顾。本地转写管线在测试集上到了 92% 准确率。
         [02:30] Maya: 好的。下一迭代我来负责说话人分离实验。
         [05:10] Phinn: 决议:v1.0 以单说话人模式发布,说话人分离先放开关后面。
         [08:45] Ken: 我周五前把 App Store 截图出初稿,隐私文案 Maya 复审。
         [12:20] Phinn: 待办都已记录,散会。
         """,
         [(0,14,"开始迭代回顾。本地转写管线在测试集上到了 92% 准确率。"),(150,186,"下一迭代我来负责说话人分离实验。"),(310,352,"决议:v1.0 以单说话人模式发布,说话人分离先放开关后面。"),(525,560,"我周五前把 App Store 截图出初稿,隐私文案 Maya 复审。")])
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
    private static func seed1ja() -> (String, String, [String], [(String, String, String)], String, [(Int, Int, String)]) {
        ("週次プロダクト会議",
         "概要\nチームはスプリントの進捗を振り返り、 single-speaker 文字起こしで v1.0 をリリースすることで合意。話者分離は機能フラグの背後に維持します。\n\n要点\n• ローカル文字起こしパイプラインがテストセットで 92% の精度を達成\n• 話者分離の実験は次スプリントへ繰り越し\n• 申請前にプライバシー文面のレビューを実施",
         ["v1.0 は single-speaker モードでリリース、話者分離はフラグの背後へ", "端末内のみの処理をデフォルトで維持"],
         [("Maya", "話者分離実験の実施", "次スプリント"), ("Ken", "App Store スクリーンショットの作成", "金曜日")],
         """
         [00:00] Phinn: スプリントレビューを始めます。ローカル文字起こしの精度はテストセットで92%に到達しました。
         [02:30] Maya: 次のスプリントでは、私が話者分離の実験を担当します。
         [05:10] Phinn: 決定事項:v1.0 は single-speaker モードでリリースし、話者分離はフラグの背後に。
         [08:45] Ken: 金曜までに App Store のスクリーンショットをDraftします。プライバシー文面は Maya が確認。
         [12:20] Phinn: アクション項目は記録済み。散会します。
         """,
         [(0,14,"スプリントレビューを始めます。ローカル文字起こしの精度はテストセットで92%に到達しました。"),(150,186,"次のスプリントでは、私が話者分離の実験を担当します。"),(310,352,"決定事項:v1.0 は single-speaker モードでリリースし、話者分離はフラグの背後に。"),(525,560,"金曜までに App Store のスクリーンショットをDraftします。プライバシー文面は Maya が確認。")])
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

    private func defaultTitle() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f.string(from: Date())
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
