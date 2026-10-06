# VoxSign · iOS Client

A native, voice-first iOS client for VoxSign — a hands-free, chat-driven AI harness that turns
short spoken commands into executed, verifiable file operations. Built with SwiftUI, **zero
third-party dependencies** (pure Foundation / URLSession / SwiftUI / Speech).

Default UI language is **English**; a **Simplified Chinese (zh-Hans)** language pack is bundled as
the only localized resource.

> This repository is the open-source iOS client subtree. It speaks the VoxSign
> [INTERACT-v1](docs/v4-design-spec.md) REST + SSE protocol; the backend harness lives in a
> separate repository.

---

## Features

- **Voice-first chat.** Press-and-hold the mic to speak; recognized text is editable before send.
  Falls back to the keyboard when speech recognition is unavailable (e.g. Simulator, denied permission).
- **Real SSE-driven execution.** A live event stream drives a seven-stage exec card
  (Intent → Domain → Risk → Confirm Gate → Execute → Verify → Attribution) and the decision points.
- **One decision point per screen.** `need_ask` shows candidate buttons; `need_confirm` shows a red
  confirm card; `canceled`/`interrupted` surface an error bar.
- **Receipts & undo.** Each completed task renders a four-line receipt (Action / File / Result / Undo);
  reversible tasks expose an Undo action that calls the backend rollback endpoint.
- **Interruptible.** Say "stop" (or "halt" / "freeze" / "hold on" / "cut it") to raise a red system
  bar showing what applied, what was aborted, and Continue / Undo actions.
- **Multi-session filing.** Left drawer with history sessions sorted by recency; swipe to file /
  unfile / delete; sessions are grouped into Roles and Domains.
- **Multi-machine.** One-tap switch between the VoxSign cloud and self-hosted Harness servers
  (IP address or machine code).
- **Offline-safe delivery.** Submissions queue locally and resend with backoff once connectivity returns.

---

## Architecture

```
VoxSign/
├── App/                 App entry (@main), Info.plist permissions
├── Core/                Pure logic (no UI / networking) — fully unit-tested
│   ├── Models.swift      Value types: TaskView / Receipt / Badge / DecisionPoint / SystemBarInfo
│   ├── VSLogic.swift    State machine, receipt parsing, undo verdict, badges, decision routing, roles, interrupt bar
│   ├── SSEParser.swift  SSE framing, typed events, lastSeq, reconnect ?after=
│   └── ...
├── Net/                 APIClient, AuthService, SettingsStore, SSEClient, DeliveryQueue, ConnectivityService
├── Speech/              SpeechRecognizer (SFSpeechRecognizer + AVAudioEngine), VoiceOutputService (TTS)
├── State/               AppModel orchestration, SessionStore persistence
├── Views/               SwiftUI views (chat flow, decision zone, input bar, settings, session drawer, ...)
├── en.lproj/            Localizable.strings — English (default)
└── zh-Hans.lproj/       Localizable.strings — Simplified Chinese (the only localized CJK resource)
VoxSignTests/            XCTest unit tests (logic layer, SSE, badges, sessions, attachments, queue)
VoxSignUITests/          XCUITest ad-hoc acceptance / screenshot helpers
DevCheck/                macOS command-line logic assertions (not in any Xcode target)
docs/                    Design specs
```

### The nine interaction elements

| # | Element | Where it lives |
|---|---|---|
| 1 | Chat flow: user right blue bubble (waveform for voice); harness left white bubble; typing dots | `MessageViews.swift`, `RootView.swift` |
| 2 | Lightweight badges: intent / domain / risk | `VSLogic.compressBadges`, `MessageViews.swift BadgeView` |
| 3 | Live exec card scrolling through the seven stages | `VSLogic.execStages`, driven by SSE `stage` events |
| 4 | Receipt card: Action / File / Result / Undo + undo action | `VSLogic.parseReceipt` / `extractUndo`, `ReceiptCardView` |
| 5 | Red interrupt system bar ("stop" → applied / aborted / undoable) | `VSLogic.interruptSystemBar`, `SystemBarView` |
| 6 | Mic input bar with editable transcript, keyboard fallback | `SpeechRecognizer.swift`, `InputBarView.swift` |
| 7 | Multi-role collapsible bar (Planner / Executor / Verifier) | `RoleBarView`, `AppModel.syncRole` |
| 8 | Candidate buttons / strong confirm; one decision point per screen | `VSLogic.nextDecisionPoint`, `DecisionZoneView` |
| 9 | Server settings (address + token); client-side `request_id` idempotency | `SettingsStore.swift`, `SettingsView.swift` |

---

## Build

Requirements: Xcode 15+ (built and verified on Xcode 27), an iOS Simulator runtime.

```bash
# From the repository root:
xcodebuild -project VoxSign.xcodeproj -scheme VoxSign \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Run the unit tests in Xcode (⌘U) or:

```bash
xcodebuild test -project VoxSign.xcodeproj -scheme VoxSign \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

The pure logic layer can also be exercised directly on macOS without the Simulator:

```bash
cd DevCheck
swiftc -o /tmp/vscheck DevLogicCheck.swift \
  ../VoxSign/Core/Models.swift ../VoxSign/Core/VSLogic.swift ../VoxSign/Core/SSEParser.swift
/tmp/vscheck
```

---

## Running against a backend

1. Launch the VoxSign Harness server (see the backend repository).
2. On first launch, open **Settings** (top-right ⚙). By default the app uses **VoxSign Cloud**.
   To point at a self-hosted server, switch to **Self-hosted** → **Add server**, enter the
   `http://<host>:<port>` URL and the Bearer token, then **Save and check connection**.
3. Pair the device and the server on the same network; if AP isolation blocks direct access, the
   cloud relay can bridge it.

---

## Localization

All user-facing strings are routed through `NSLocalizedString`. English is the development and
default language; Simplified Chinese ships in `zh-Hans.lproj/Localizable.strings`. To add another
language, create a new `<lang>.lproj/Localizable.strings` and add the region to
`VoxSign.xcodeproj/project.pbxproj` (`knownRegions`).

---

## License

See the backend repository for licensing. This client is provided as the iOS surface of the VoxSign
system.
