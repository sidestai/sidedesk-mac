# Sidest Bar

macOS-native port of **SideDesk** — a desktop sidebar utility that lives on the edge of your screen and keeps sticky notes, todos, quick launches, check-ins and data dashboards one glance away.

The Windows original is WPF/.NET; this repo is a full rewrite in Swift (AppKit shell + SwiftUI content, built with SwiftPM). The executable and SwiftPM target are still `SidestMac`; **Sidest Bar** is the user-visible product name.

To get Windows version please visit: https://github.com/sidestai/sidedesk-win
## Features

- **Persistent side panel** — borderless non-activating `NSPanel`s pinned to the left and right screen edges at `.statusBar` level; hides off-screen and expands on hover. No Dock icon (menu-bar `NSStatusItem` only).
- **Window enforcement** — the macOS counterpart of the Windows AppBar: uses the Accessibility API to nudge other apps' windows out of the sidebar gutter, per-screen, including maximize.
- **Stay out of the way** — auto-hides while an app is in native fullscreen; global `⌥S` toggles the panel; optional `Ctrl+1…9` virtual-screen switching (off by default).
- **Cards** — group, today's todos, quick groups (shortcuts), sticky notes, signal light, check-in, and Pomodoro are fully interactive; notes / clipboard / timer / countdown / file area / data dashboard render their stored rows.
- **Sticky notes** — Markdown-rendered, with detachable desktop note windows and a rich editor.
- **Data dashboard** — variable-driven widgets; can poll a Chromium browser over the DevTools protocol (CDP) for authenticated pages.
- **Account & cloud sync** — OAuth2 authorization-code + PKCE login with a loopback redirect, encrypted sync (optional passphrase), local SQLite store and local backups.
- **Theming & i18n** — Dark / Light / follow-system base modes plus 11 selectable color themes; 13 languages (zh-CN, zh-TW, en, ja, ko, de, es, fr, it, pl, pt-BR, ru, tr) or follow the system.
- **Auto update** — Sparkle 2.x (the counterpart of Velopack on Windows), with Ed25519-signed archives.
- **Launch at login** — `SMAppService` login item.

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode command line tools with a Swift 5.9+ toolchain
- Network access on first build (`swift package resolve` downloads the Sparkle xcframework)
- **Accessibility permission** — required for window enforcement. The app prompts on launch and re-checks until you grant it. Make sure it is granted to a *stable* signing identity — run `./setup-signing.sh` (see [Release & signing](#release--signing)), otherwise macOS asks again after every rebuild.

## Build

```bash
# Debug build + local .app bundle (native arch, self-signed)
./build.sh debug

# Release build, universal (arm64 + x86_64)
./build.sh

# Run it
open dist/SidestMac.app
```

`build.sh` compiles with SwiftPM, assembles `dist/SidestMac.app` (Info.plist, app icon, localized `.lproj` display names, SPM resource bundles for languages/themes/templates), embeds `Sparkle.framework`, then signs and verifies the bundle.

Plain `swift build` also works but produces a bare executable — the panel, hotkeys, Sparkle and permissions all depend on the `.app` bundle, so use `build.sh` for anything you intend to run.

### Backend region

`Sources/SideDeskCore/Constants.swift` picks the backend/API/update domains with the same `#if API_REGION_ZH / API_REGION_EN` branches as the Windows `Constants.cs`, defaulting to the Chinese region. Unlike the .NET build there is **no command-line switch yet** — `Package.swift` defines no region flag. To ship the international build, add a setting to the targets that consume `Constants`:

```swift
.target(
    name: "SideDeskCore",
    path: "Sources/SideDeskCore",
    swiftSettings: [.define("API_REGION_EN")],
    resources: [...]
)
```

## Testing

```bash
swift test          # unit tests: SideDeskCoreTests + SideDeskServicesTests
./smoke-test.sh     # launches the built app with --test-mode and asserts its lifecycle
```

The unit tests cover the Core layer (paths, settings, logging, localization, themes, note geometry, model rules) and the Services layer (SQLite store, cloud sync payloads, encryption, OAuth loopback, backend API/WebSocket, CDP polling, card catalog). `smoke-test.sh` verifies the `--test-mode` contract: an isolated data directory, a startup log, auto-exit, and zero side effects on your real `~/Library/Application Support/SideDesk`.

## Project structure

The Swift implementation lives entirely under `Sources/` and `Tests/`; the layered split mirrors the Windows solution.

```
├── Package.swift                 SwiftPM manifest: 3 targets + 2 test targets
├── Sources/
│   ├── SideDeskCore/             Platform-agnostic foundation
│   │   ├── CompositionRoot.swift / AppContainer.swift   DI wiring
│   │   ├── Constants.swift       backend domains, region branches
│   │   ├── Framework/            AppPaths, AppSettings, Lang, ThemeManager,
│   │   │                         RuntimeLog, Motion, SystemPreferences, …
│   │   ├── Models/               sticky notes, todos, dashboards, S3/WebDAV,
│   │   │                         programs, teams, window config, AI config …
│   │   └── Resources/            langs/ (13 JSON dictionaries), themes/ (11)
│   ├── SideDeskServices/         Services layer
│   │   ├── LocalDbService*.swift SQLite persistence (settings, rows, note tree)
│   │   ├── CloudSyncService*.swift  encrypted cloud sync
│   │   ├── BackendApiClient / BackendWebSocketService / OAuthLoginService
│   │   ├── Cdp*.swift            Chrome DevTools protocol discovery + polling
│   │   ├── DataVariableService / DataTemplateManager / DataPollingService
│   │   ├── StickyNoteService / QuickGroupService / TeamService / AutoStartService
│   │   └── AddableCardCatalog.swift  the "add card" menu
│   └── SidestMac/                App shell (executable target)
│       ├── AppDelegate.swift     startup, panels, hotkeys, virtual screens
│       ├── SidePanel.swift       the edge panels (AppKit)
│       ├── SidePanelRootView.swift / BarCardsModel.swift / CardViews.swift
│       ├── WindowManager.swift   Accessibility-based window enforcement
│       ├── HoverTimer.swift      hover-to-expand
│       ├── Settings/             the 8 settings pages
│       ├── *Dialogs.swift        add todo / quick item / check-in / signal light …
│       ├── StickyDesktopWindow.swift + StickyRichEditor.swift
│       ├── TrayIcon.swift        NSStatusItem menu
│       └── UpdateService.swift   Sparkle
├── Tests/                        SideDeskCoreTests, SideDeskServicesTests
├── Resources/                    Info.plist, AppIcon.icns, entitlements, *.lproj
├── build.sh                      compile + bundle + sign + verify
├── make-release.sh               universal app → zip archive → Sparkle appcast
├── setup-signing.sh              stable self-signed dev identity
├── sparkle-setup.sh              Ed25519 keypair (public half → .sparkle-public-key)
└── smoke-test.sh                 --test-mode lifecycle assertions
```

### Legacy reference code (not built)

These directories are **not** referenced by `Package.swift` and are kept only as a readable map of the Windows behavior:

- `SideDesk.Core/`, `SideDesk.Services/`, `SideDesk.Platform.Mac/`, `SideDesk.App/` — the abandoned C#/.NET port (Phases 1–3).
- `spike-avalonia/`, `spike-avalonia-nspanel/`, `spike-ax/` — feasibility spikes for the Avalonia and Accessibility approaches.

Do not edit them to change app behavior; they are dead weight to the build.

## Ports, dialogs and settings

Sidebar panels are rendered with SwiftUI inside `NSPanel`s; every modal is a separate `NSWindowController` + `NSHostingView` window rather than a sheet, because the panels are non-activating.

Eight settings pages are ported (of the Windows sixteen):

| Page | Covers |
|------|--------|
| General | per-monitor dock side/width, hover, language (13 + system) |
| Windows | create / rename / delete sidebar windows |
| Account | login, cloud sync, sync passphrase, local backup |
| Appearance | theme picker, opacity, border color |
| Tools | launch at login, log level, open log folder |
| Data dashboard | CDP mode/port, headless browser, connection test |
| Hotkeys | `Ctrl+1…9` virtual-screen switch |
| About | Sparkle update controls |

## Configuration

- **Data directory**: `~/Library/Application Support/SideDesk` — `settings.json`, the SQLite database, logs, backups.
- **Runtime config**: `runtime-config.json` in the data directory (a default template is written on first run). Precedence is environment variable `SIDESK_<KEY>` (e.g. `SIDESK_WS_PORT`) → file → built-in default. Currently one key, `ws.port` (19191).
- **Backend URLs**: compile-time, in `Constants.swift` (`serverBaseUrl`, `updateUrl`, `homePageBaseUrl`). Point them at your own backend and rebuild.
- **Update feed**: `SUFeedURL` in `Resources/Info.plist`, overridable with `SPARKLE_FEED_URL` at build time.

## Release & signing

```bash
./setup-signing.sh        # once: stable self-signed identity "SidestMac Dev"
./sparkle-setup.sh        # once: Ed25519 keypair; writes .sparkle-public-key
./make-release.sh 0.2.0   # universal signed app + update zip + appcast.xml
```

`make-release.sh` outputs:

```
dist/SidestMac.app                          local runnable bundle
dist/updates/SidestMac-<ver>-<build>.zip    what Sparkle downloads
dist/updates/appcast.xml                    what SUFeedURL points at
```

Upload `dist/updates/` (minus `old_updates/`) to the path your feed URL implies. Release notes go in a `SidestMac-<version>.md|.html|.txt` next to the archive and Sparkle picks them up.

For a distributable build, sign with a real certificate and notarize:

```bash
SIDEMAC_SIGN_IDENTITY="Developer ID Application: … (TEAMID)" \
SIDEMAC_NOTARIZE_PROFILE=sidest-notary \
./make-release.sh 0.2.0
```

Environment variables recognized by `build.sh` / `make-release.sh`: `SIDEMAC_SIGN_IDENTITY`, `SIDEMAC_NOTARIZE_PROFILE`, `SIDEMAC_ARCH`, `SIDEMAC_VERSION`, `SIDEMAC_BUILD`, `SPARKLE_FEED_URL`, `SPARKLE_DOWNLOAD_PREFIX`, `SPARKLE_KEY_ACCOUNT`, `SPARKLE_PRIVATE_KEY_FILE`. The private half of the Sparkle key never enters the repo — losing it means every shipped install refuses future updates.

## Porting status

The Mac build is a faithful port of the sidebar core, but several Windows subsystems are deliberately **not** there yet. Don't look for them:

- **Plugin system** — no native DLL host and no WebView2/`WKWebView` equivalent. The plugin settings page and `ModuleKind` model exist only as carried-over data shapes.
- **AI assistant** — `AIConfig` / `AITool` / `DigitalEmployee` models and storage only; no LLM client, no chat UI (those cards render as placeholders).
- **Team sharing** — read-only `GET /api/team/list` client; no sharing UI.
- **Voice input** — microphone and speech-recognition usage strings are in `Info.plist`, but no `AVAudioEngine` / `SFSpeechRecognizer` code yet.
- **Placeholder cards** — AI chat, calendar, image carousel, system monitor, screen time, usage statistics, daily activity, Baidu web search, module-UI.
- **Clipboard card** shows saved items only; there is no pasteboard capture.
- **Panel geometry** follows the main screen; multi-monitor support currently covers per-screen window enforcement, not panels on secondary displays.
- **Edit mode** — no `IsEditMode`: cards append to the end of the list when added and are removed with a right-click, but there is no drag-to-reorder or drag-to-resize, and deletion has no confirmation dialog.

## License

PolyForm Shield License 1.0.0 — see [LICENSE](LICENSE).
