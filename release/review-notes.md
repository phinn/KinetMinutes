# Review Notes — KinetMinutes 1.0.0

> 粘贴到 ASC「App Review Information / Notes」(英文为审核主语言)

## English (paste into Notes)

KinetMinutes is a fully local AI meeting-notes app for macOS. It records
meetings (microphone), transcribes them offline with on-device Whisper models,
and generates structured notes (summary / decisions / action items) with a
local LLM. Audio never leaves the Mac.

**How to test in 90 seconds**

1. Launch the app. A 🗓 icon appears in the menu bar (top-right).
2. Click the icon → "Start Recording". macOS asks for Microphone permission —
   allow it. Speak a few sentences; the icon shows a live level meter.
3. Click the icon again → "Stop & Generate Notes".
   Note: the very first run needs a Whisper model downloaded (Settings →
   Transcription model). On a clean reviewer machine without a model, the
   meeting still appears in the Library with status "model not downloaded".
   To showcase the full offline pipeline, a demo meeting with a complete set
   of notes (summary / decisions / action items / timeline / transcript) is
   pre-seeded on first launch — open "Meeting Library…" to see it.
4. In the Library: browse the demo meeting's Summary / Decisions / Action
   Items / Timeline / Transcript tabs. Use "Export" → "Export as Markdown"
   and save anywhere (standard NSSavePanel).
5. Click the menu-bar icon → "Privacy…" to see the zero-upload statement and
   the "Delete All Data…" button (deletes every recording/transcript/note).

**Network usage**

The app makes no network requests during recording, transcription, or
summarization — all local. The only network activity is a one-time,
user-initiated download of open-source Whisper model weights (from
huggingface.co or a user-configured mirror) when the user picks a model in
Settings. Reviewers can use the app completely offline.

**Permissions model**

- Microphone (com.apple.security.device.audio-input): required to record
  meetings. Requested in context on first recording with a purpose string.
- No Apple Events, no automation, no accessibility, no screen recording.
- App Sandbox enabled. Files are written only inside the app container.

**Demo account**: not applicable — fully local, no accounts, no server.

**Data collection**: none. PrivacyInfo.xcprivacy is bundled with
NSPrivacyTracking=false, no tracking domains, no collected data types.

**Age rating questionnaire (all markets: 4+)**

| Question | Answer |
|---|---|
| Cartoon or Fantasy Violence | None |
| Realistic Violence | None |
| Profanity or Crude Humor | None |
| Mature/Suggestive Themes | None |
| Horror/Fear Themes | None |
| Medical/Treatment Information | None |
| Alcohol, Tobacco, or Drug Use | None |
| Gambling | None |
| Unrestricted Web Access | No |
| User-Generated Content | No (all content stays on device) |

**Export compliance**: ITSAppUsesNonExemptEncryption=false (standard system
crypto only; no custom encryption).
