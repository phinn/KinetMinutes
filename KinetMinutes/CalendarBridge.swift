// CalendarBridge.swift — 1.3 P2: prefill meeting title from the current
// calendar event. Best-effort: silently no-op on any failure (no prompt
// spam; TCC remembers denials). Calendars need the com.apple.security
// .personal-information.calendars entitlement + NSCalendarsUsageDescription.
//
// NOTE: requestAccess(to:) on macOS 14+ returns (granted:Bool, error:Error?).

import EventKit

enum CalendarBridge {
    static let store = EKEventStore()

    /// Returns the current (now-start) event title, or nil.
    static func currentEventTitle() -> String? {
        guard UserDefaults.standard.object(forKey: "prefillTitleFromCalendar") as? Bool ?? true else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var title: String?
        let ek = store
        ek.requestFullAccessToEvents { granted, _ in
            defer { sem.signal() }
            guard granted else { return }
            let pred = ek.predicateForEvents(withStart: Date(), end: Date().addingTimeInterval(60), calendars: nil)
            if let ev = ek.events(matching: pred).first {
                let t = ev.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !t.isEmpty { title = t }
            }
        }
        // bounded wait: cold TCC prompt path returns nil this run
        _ = sem.wait(timeout: .now() + 2.0)
        return title
    }
}
