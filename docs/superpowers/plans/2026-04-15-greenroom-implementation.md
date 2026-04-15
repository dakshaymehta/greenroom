# Greenroom Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Greenroom — a native macOS app with a WebView sidebar showing 4 AI personas that provide live commentary on a show by listening to system audio + microphone.

**Architecture:** Hybrid Swift + WebView. Swift handles audio capture (ScreenCaptureKit + AVAudioEngine), transcription (AssemblyAI streaming), AI orchestration (Claude via Cloudflare Worker), and sound effects. A WKWebView hosts the sidebar UI (HTML/CSS/JS) with 4 persona lanes. BYOK — each user deploys their own Cloudflare Worker with their own API keys.

**Tech Stack:** Swift/SwiftUI, AppKit (NSWindow, NSPanel), ScreenCaptureKit, AVAudioEngine, WKWebView, HTML/CSS/JS (vanilla), Cloudflare Workers (TypeScript), Claude API, AssemblyAI API.

**Spec:** `docs/superpowers/specs/2026-04-15-greenroom-design.md`

**Reference codebase:** Lore (at `../tutor/`) — borrow patterns for AssemblyAI streaming, audio capture, Cloudflare Worker proxy.

---

## File Map

### Swift Layer (`Greenroom/Greenroom/`)

| File                                        | Responsibility                                                                           |
| ------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `App/GreenroomApp.swift`                    | App entry point, `@main`, scene definition                                               |
| `App/GreenroomAppDelegate.swift`            | `NSApplicationDelegate`, creates window + coordinator                                    |
| `App/GreenroomCoordinator.swift`            | Central orchestrator — owns audio, transcription, AI engine, bridge. Runs the tick loop. |
| `Audio/SystemAudioCaptureEngine.swift`      | ScreenCaptureKit `SCStream` for system audio, `excludesCurrentProcessAudio`              |
| `Audio/MicrophoneCaptureEngine.swift`       | `AVAudioEngine` for host mic input                                                       |
| `Audio/AudioMixer.swift`                    | Mixes system + mic streams on a serial queue, AGC normalization                          |
| `Audio/AudioFormatConverter.swift`          | Converts any audio format to PCM16 mono 16kHz                                            |
| `Transcription/TranscriptionProvider.swift` | Protocol for swappable transcription backends                                            |
| `Transcription/AssemblyAIProvider.swift`    | Websocket streaming to AssemblyAI, token management                                      |
| `Transcription/TranscriptBuffer.swift`      | Rolling 5-min buffer, extracts chunks + context windows                                  |
| `AI/ClaudeAPIClient.swift`                  | Non-streaming JSON POST to Cloudflare Worker `/chat`                                     |
| `AI/PersonaPrompts.swift`                   | System prompt text for all 4 personas + output format instructions                       |
| ~~`AI/PersonaResponse.swift`~~              | _(Types live in `Bridge/BridgeMessages.swift` — no separate file needed)_                |
| `AI/GreenroomEngine.swift`                  | Response-gated tick timer, calls Claude, dispatches to bridge + SFX                      |
| `SoundEffects/SoundEffectLibrary.swift`     | Effect name → file path mapping, enum of valid effects                                   |
| `SoundEffects/SoundEffectEngine.swift`      | `AVAudioPlayer` playback, volume control, mute toggle                                    |
| `Bridge/BridgeMessages.swift`               | Message types for Swift ↔ JS communication                                               |
| `Bridge/WebViewBridge.swift`                | `WKScriptMessageHandler`, JS evaluation, bidirectional messaging                         |
| `Window/GreenroomWindowController.swift`    | `NSWindow` lifecycle, float-on-top, frame autosave                                       |
| `Window/GreenroomSettingsPanel.swift`       | Non-modal `NSPanel` with SwiftUI settings form                                           |
| `Utilities/DesignTokens.swift`              | Color constants, sizing tokens                                                           |
| `Resources/Info.plist`                      | App metadata, permissions descriptions                                                   |
| `Resources/Greenroom.entitlements`          | App Sandbox, audio input, network                                                        |

### Tests (`Greenroom/GreenroomTests/`)

| File                            | What it tests                                          |
| ------------------------------- | ------------------------------------------------------ |
| `TranscriptBufferTests.swift`   | Buffer storage, chunk extraction, context windowing    |
| `PersonaResponseTests.swift`    | JSON parsing — full, partial, null personas, malformed |
| `SoundEffectLibraryTests.swift` | Effect name mapping, unknown effect handling           |
| `BridgeMessagesTests.swift`     | Message serialization/deserialization                  |
| `GreenroomEngineTests.swift`    | Tick timer logic with mocked dependencies              |

### Sidebar UI (`sidebar/`)

| File                | Responsibility                                                   |
| ------------------- | ---------------------------------------------------------------- |
| `index.html`        | Page structure — header, 4 persona lanes, footer                 |
| `styles.css`        | Dark theme, persona colors, bubble styling, animations           |
| `sinewave.js`       | Canvas-based sine wave per persona (active/idle/thinking states) |
| `personas.js`       | Persona lane rendering, message updates, history expansion       |
| `app.js`            | Bridge listener, state management, dispatches to personas.js     |
| `assets/gary.png`   | Gary avatar (placeholder for v1)                                 |
| `assets/fred.png`   | Fred avatar                                                      |
| `assets/jackie.png` | Jackie avatar                                                    |
| `assets/troll.png`  | Troll avatar                                                     |

### Cloudflare Worker (`worker/`)

| File            | Responsibility                                                         |
| --------------- | ---------------------------------------------------------------------- |
| `src/index.ts`  | Routes: `/chat` (Claude proxy), `/transcribe-token` (AssemblyAI token) |
| `wrangler.toml` | Worker config, secret bindings                                         |
| `package.json`  | Dependencies (minimal — just wrangler)                                 |

### Root Files

| File                      | Responsibility                                                     |
| ------------------------- | ------------------------------------------------------------------ |
| `README.md`               | Hero content, BYOK setup, Cloudflare deployment guide, quick start |
| `LICENSE`                 | MIT, Dakshay Mehta                                                 |
| `AGENTS.md`               | Agent instructions for the codebase                                |
| `CLAUDE.md`               | Symlink to AGENTS.md                                               |
| `.gitignore`              | Xcode, macOS, Node artifacts                                       |
| `docs/architecture.md`    | Architecture deep-dive                                             |
| `docs/getting-started.md` | Full setup + first-run guide                                       |
| `docs/personas.md`        | Persona customization guide                                        |
| `docs/contributing.md`    | Contribution guide                                                 |

---

## Task 1: Project Scaffold

**Files:**

- Create: `.gitignore`
- Create: `LICENSE`
- Create: `AGENTS.md`
- Create: `CLAUDE.md` (symlink)

- [ ] **Step 1: Create .gitignore**

Standard Xcode + macOS + Node ignores. Include `build/`, `DerivedData/`, `*.xcuserstate`, `node_modules/`, `.wrangler/`, `worker/.dev.vars`, `.DS_Store`.

- [ ] **Step 2: Create LICENSE**

MIT license, copyright 2026 Dakshay Mehta.

- [ ] **Step 3: Create AGENTS.md**

Minimal initial version covering: overview (macOS app, hybrid Swift + WebView, 4 personas), architecture bullet points (deployment target macOS 14.2+, SwiftUI + AppKit, Claude via BYOK Worker, AssemblyAI, ScreenCaptureKit + AVAudioEngine, WKWebView sidebar, AVAudioPlayer SFX), build instructions (open Xcode project, Cmd+R), code style (clarity over concision, comments explain "why", @MainActor for UI, async/await), and "do not" rules (no xcodebuild from terminal, no unasked features).

- [ ] **Step 4: Create CLAUDE.md symlink**

```bash
ln -s AGENTS.md CLAUDE.md
```

- [ ] **Step 5: Commit scaffold**

```bash
git add .gitignore LICENSE AGENTS.md CLAUDE.md
git commit -m "Add project scaffold — gitignore, MIT license, agent instructions"
```

---

## Task 2: Cloudflare Worker

**Files:**

- Create: `worker/package.json`
- Create: `worker/wrangler.toml`
- Create: `worker/src/index.ts`

**Reference:** `../tutor/worker/src/index.ts` for the `/chat` and `/transcribe-token` route patterns.

- [ ] **Step 1: Create worker/package.json**

Name: `greenroom-worker`, private, scripts for `dev` (wrangler dev) and `deploy` (wrangler deploy), devDependency on `wrangler@^4.0.0`.

- [ ] **Step 2: Create worker/wrangler.toml**

Name: `greenroom-worker`, main: `src/index.ts`, compatibility_date `2025-01-01`. Comments listing the required secrets: `ANTHROPIC_API_KEY`, `ASSEMBLYAI_API_KEY`.

- [ ] **Step 3: Create worker/src/index.ts**

Two routes:

**`POST /chat`**: Reads request body as text, forwards to `https://api.anthropic.com/v1/messages` with headers `x-api-key` (from `env.ANTHROPIC_API_KEY`), `anthropic-version: 2023-06-01`, `Content-Type: application/json`. Returns upstream response body and status. Add CORS headers.

**`POST /transcribe-token`**: GET request to `https://streaming.assemblyai.com/v3/token?expires_in_seconds=480` with `authorization` header set to `env.ASSEMBLYAI_API_KEY`. Returns the token JSON with CORS headers.

**OPTIONS handler** for CORS preflight: returns 200 with `Access-Control-Allow-Origin: *`, `Access-Control-Allow-Methods: POST, OPTIONS`, `Access-Control-Allow-Headers: Content-Type`.

Type the `Env` interface with `ANTHROPIC_API_KEY: string` and `ASSEMBLYAI_API_KEY: string`.

Error handling: try/catch around each route, log errors, return 500 with JSON error body.

- [ ] **Step 4: Create worker/README.md**

Brief README covering: what the Worker does, required secrets, deployment commands, how to verify it's running (`curl -X POST https://your-worker.workers.dev/transcribe-token`).

- [ ] **Step 5: Install dependencies**

```bash
cd worker && npm install
```

- [ ] **Step 6: Commit Worker**

```bash
git add worker/
git commit -m "Add Cloudflare Worker proxy for Claude and AssemblyAI"
```

---

## Task 3: Sidebar UI — HTML Structure & Dark Theme

**Files:**

- Create: `sidebar/index.html`
- Create: `sidebar/styles.css`
- Create: `sidebar/app.js`
- Create: `sidebar/personas.js`
- Create: `sidebar/sinewave.js`
- Create: `sidebar/assets/` (placeholder avatars)

Build the sidebar UI first — it can be developed and tested in any browser before the Swift layer exists.

- [ ] **Step 1: Create sidebar/index.html**

Structure:

- `<header id="status-bar">` with logo text "GREENROOM" and live/offline indicator span
- `<main id="persona-container">` with 4 `<section class="persona-lane">` elements, each containing:
  - `.persona-header` with `<img>` avatar (with onerror hide), name span, role span
  - Fred's header also has a `.mute-toggle` button
  - `.persona-messages` div with a placeholder bubble
  - `<canvas class="sine-wave">` with `data-persona` attribute
- `<footer id="controls">` with settings and pause buttons
- Script tags loading sinewave.js, personas.js, app.js in order

- [ ] **Step 2: Create sidebar/styles.css**

CSS custom properties for the dark theme:

- `--bg-primary: #0D0D0D`, `--bg-secondary: #1A1A1A`, `--bg-bubble: #252525`
- `--text-primary: #E5E5E5`, `--text-secondary: #999`, `--text-muted: #666`
- Persona accents: `--gary-accent: #4A9EFF`, `--fred-accent: #4ADE80`, `--jackie-accent: #FBBF24`, `--troll-accent: #F87171`
- System font stack, 14px base, antialiased
- Flexbox column layout filling viewport height
- Status bar with mono font, letter-spacing, green pulse-dot animation for LIVE
- Persona lanes with subtle border-bottom separator
- Message bubbles: rounded, left border in persona accent color, slide-up animation
- `.old` bubbles at 50% opacity
- SFX indicator styled as small pill in Fred's accent color
- Canvas sine waves at 20px height, full width
- Mute toggle button with hover state, `.muted` class dims the icon
- Footer controls centered with hover transitions
- `.persona-lane.expanded .persona-messages`: max-height 300px, overflow-y auto, scrollable history view
- Click handler on `.persona-lane` toggles `.expanded` class (added in personas.js)
- Custom scrollbar (4px, subtle thumb)

- [ ] **Step 3: Create sidebar/sinewave.js**

IIFE module `SineWave` with:

- `init()`: queries all `.sine-wave` canvases, stores by persona name from `data-persona`, sets initial state to `idle`, starts `requestAnimationFrame` draw loop, handles window resize
- `setState(persona, state)`: updates state for a persona (`active`, `idle`, `thinking`)
- `draw(timestamp)`: for each canvas, clears and draws:
  - `idle`: flat horizontal line in `#333`
  - `active`: sine wave in persona accent color, amplitude 35% of height, moderate frequency
  - `thinking`: faster smaller sine wave, amplitude 15%
- Accent color map: `gary: '#4A9EFF'`, `fred: '#4ADE80'`, `jackie: '#FBBF24'`, `troll: '#F87171'`
- Handles devicePixelRatio for retina displays

- [ ] **Step 4: Create sidebar/personas.js**

IIFE module `Personas` with:

- `history` object tracking past messages per persona (max 50)
- `updatePersona(persona, data)`: if data is null, set sine wave to idle and return. Otherwise:
  - Set sine wave to `active`
  - Find the persona lane's `.persona-messages` container
  - Mark existing non-old bubbles with `.old` class
  - Create new `.message-bubble` div using safe DOM methods:
    - If Fred with effect: create `.sfx-indicator` span with `textContent` set to effect name
    - Set message text via `textContent` (not innerHTML — avoid XSS)
  - Append bubble, trim to last 5 visible (when not expanded)
  - Store in history
  - setTimeout to reset sine wave to idle after 3s
- `setThinking(persona)`: set sine wave to `thinking` state
- `setAllThinking()`: set all 4 personas to thinking
- Use `document.createTextNode` and `textContent` for all user-visible content — never innerHTML
- `initClickToExpand()`: add click handlers on `.persona-header` elements that toggle `.expanded` class on the parent `.persona-lane`. When expanded, show full scrollable history from the `history` object instead of trimming to 5.

- [ ] **Step 5: Create sidebar/app.js**

IIFE module `Greenroom` exposed as `window.greenroom`:

- `init()`: calls `SineWave.init()`, sets up control button listeners
- `onPersonaUpdate(responses)`: iterates `['gary', 'fred', 'jackie', 'troll']`, calls `Personas.updatePersona` for each. Skips if paused.
- `onTickStart()`: calls `Personas.setAllThinking()` if not paused
- `setLiveStatus(live)`: toggles indicator text and class (`live`/`offline`)
- `setErrorStatus(message)`: sets indicator to error state
- Control setup:
  - Fred mute toggle: toggles `.muted` class, sends `{action: 'toggleFredMute', muted: bool}` to Swift via `window.webkit.messageHandlers.greenroom.postMessage()`
  - Pause button: toggles pause state, swaps icon between pause/play, sends `{action: 'togglePause', paused: bool}`
  - Settings button: sends `{action: 'openSettings'}`
- DOMContentLoaded listener calls `Greenroom.init()`

- [ ] **Step 6: Create placeholder avatar assets**

Create `sidebar/assets/` directory with 4 minimal placeholder PNGs (can be 1x1 transparent — avatars use `onerror` to hide if missing).

- [ ] **Step 7: Test sidebar in browser**

Open `sidebar/index.html` directly. Verify dark theme, 4 lanes, sine waves animate. Test JS API in console:

```javascript
greenroom.setLiveStatus(true);
greenroom.onTickStart();
greenroom.onPersonaUpdate({
  gary: { text: "Test fact check", confidence: 0.9 },
  fred: { effect: "rimshot", context: "Test context" },
  jackie: { text: "Test joke" },
  troll: null,
});
```

- [ ] **Step 8: Commit sidebar UI**

```bash
git add sidebar/
git commit -m "Add sidebar UI — dark theme, 4 persona lanes, sine wave animations"
```

---

## Task 4: Xcode Project & App Entry Point

**Files:**

- Create: `Greenroom/Greenroom.xcodeproj/` (via Xcode)
- Create: `Greenroom/Greenroom/App/GreenroomApp.swift`
- Create: `Greenroom/Greenroom/App/GreenroomAppDelegate.swift`
- Create: `Greenroom/Greenroom/Resources/Info.plist`
- Create: `Greenroom/Greenroom/Resources/Greenroom.entitlements`
- Create: `Greenroom/Greenroom/Window/GreenroomWindowController.swift`

- [ ] **Step 1: Create the Xcode project**

Xcode → File → New → Project → macOS → App. Product Name: `Greenroom`, Org ID: `com.dakshaymehta`, Interface: SwiftUI, Language: Swift. Location: `greenroom/Greenroom/`. Set deployment target to macOS 14.2.

- [ ] **Step 2: Configure Info.plist**

Add `NSMicrophoneUsageDescription` and `NSScreenCaptureUsageDescription` with clear user-facing explanations.

- [ ] **Step 3: Configure entitlements**

Enable App Sandbox, `com.apple.security.device.audio-input`, `com.apple.security.network.client`.

- [ ] **Step 4: Write GreenroomApp.swift**

`@main` struct with `@NSApplicationDelegateAdaptor(GreenroomAppDelegate.self)`. Body contains a `Settings { EmptyView() }` scene (main window is managed by the delegate, not SwiftUI scenes).

- [ ] **Step 5: Write GreenroomAppDelegate.swift**

`NSApplicationDelegate` that creates `GreenroomWindowController` in `applicationDidFinishLaunching`. Returns `true` from `applicationShouldTerminateAfterLastWindowClosed`.

- [ ] **Step 6: Write GreenroomWindowController.swift**

Creates an `NSWindow` (320x700, titled "Greenroom", resizable, min size 280x400, frame autosave name). Content view is a `WKWebView` with transparent background. Loads `sidebar/index.html` from the app bundle (sidebar/ added as folder reference). Development fallback: resolves path relative to `#file` for Xcode debug runs.

- [ ] **Step 7: Add sidebar/ as a folder reference in Xcode**

Drag `sidebar/` into the Xcode project navigator as a **folder reference** (blue folder icon). This copies the entire directory into the app bundle preserving structure.

- [ ] **Step 8: Build and run**

Cmd+R. Verify window appears with dark sidebar UI, 4 persona lanes render, window is resizable and remembers position. Xcode auto-creates `Assets.xcassets` with the project — add a placeholder AppIcon if needed.

- [ ] **Step 9: Commit**

```bash
git add Greenroom/
git commit -m "Add Xcode project with WKWebView hosting sidebar UI"
```

---

## Task 5: WebView Bridge

**Files:**

- Create: `Greenroom/Greenroom/Bridge/BridgeMessages.swift`
- Create: `Greenroom/Greenroom/Bridge/WebViewBridge.swift`
- Test: `Greenroom/GreenroomTests/BridgeMessagesTests.swift`

- [ ] **Step 1: Write BridgeMessages tests**

Test `PersonaUpdate` serialization to JSON (verify all 4 persona keys present, null handling). Test `SidebarAction` deserialization from JSON (action string, optional muted/paused bools).

- [ ] **Step 2: Run tests — should fail** (types don't exist yet)

- [ ] **Step 3: Write BridgeMessages.swift**

`PersonaUpdate` (Codable): 4 optional persona response structs. `toJSONString()` method.

- `GaryResponse`: `text: String`, `confidence: Double?` (optional, default nil)
- `FredResponse`: `effect: String?`, `context: String?` (at least one present when non-null)
- `JackieResponse`: `text: String`
- `TrollResponse`: `text: String`
- `SidebarAction` (Codable): `action: String`, `muted: Bool?`, `paused: Bool?`

- [ ] **Step 4: Run tests — should pass**

- [ ] **Step 5: Write WebViewBridge.swift**

`WKScriptMessageHandler` implementation:

- `attach(to:)` registers message handler named "greenroom"
- Swift → JS methods: `sendPersonaUpdate(_:)`, `sendTickStart()`, `setLiveStatus(_:)`, `setErrorStatus(_:)` — all call `webView.evaluateJavaScript` with the corresponding `greenroom.*` function
- JS → Swift: `userContentController(_:didReceive:)` parses message body as dict, decodes to `SidebarAction`, calls `onSidebarAction` callback
- `onSidebarAction: ((SidebarAction) -> Void)?` callback property

- [ ] **Step 6: Wire bridge into GreenroomWindowController**

Add `WebViewBridge` property. After creating webView, call `bridge.attach(to: webView)`. Set `bridge.onSidebarAction` to log actions.

- [ ] **Step 7: Build and run — verify bridge**

Check Xcode console for `[Greenroom] Sidebar initialized` from JS. Click Fred's mute toggle, verify `SidebarAction` logged in Swift.

- [ ] **Step 8: Commit**

```bash
git add Greenroom/
git commit -m "Add WebView bridge for Swift <-> JS communication"
```

---

## Task 6: Persona Response Parsing & Prompts

**Files:**

- Create: `Greenroom/Greenroom/AI/PersonaPrompts.swift`
- Test: `Greenroom/GreenroomTests/PersonaResponseTests.swift`

- [ ] **Step 1: Write PersonaResponse tests**

Test cases using the `PersonaUpdate` type from BridgeMessages:

- Full response: all 4 personas non-null, verify all fields parse
- Partial: gary non-null, rest null
- All null: all 4 null
- Gary without confidence: verify `confidence` is nil
- Fred with only effect (no context)
- Fred with only context (no effect)

- [ ] **Step 2: Run tests — should pass** (PersonaUpdate already defined in BridgeMessages)

- [ ] **Step 3: Write PersonaPrompts.swift**

`enum PersonaPrompts` with:

- `masterSystemPrompt` static string: defines all 4 personas, their personalities, rules (null when nothing to say, keep responses short, valid effect names), and the exact JSON output format
- `buildUserMessage(newTranscript:contextWindow:)` static method: builds the user message with `[RECENT CONTEXT]` and `[NEW — RESPOND TO THIS]` sections

- [ ] **Step 4: Commit**

```bash
git add Greenroom/
git commit -m "Add persona prompts and response parsing tests"
```

---

## Task 7: Transcript Buffer

**Files:**

- Create: `Greenroom/Greenroom/Transcription/TranscriptBuffer.swift`
- Test: `Greenroom/GreenroomTests/TranscriptBufferTests.swift`

- [ ] **Step 1: Write TranscriptBuffer tests**

- `testAppendAndExtractChunk`: append text, mark boundary, append more, extract — verify new vs context
- `testEmptyBufferReturnsEmptyChunk`: fresh buffer returns empty strings
- `testBufferTruncatesOldContent`: add old-timestamped text beyond storage window, verify it's pruned
- `testMultipleTickBoundaries`: 3 ticks, verify only latest is "new"

- [ ] **Step 2: Run tests — should fail**

- [ ] **Step 3: Write TranscriptBuffer.swift**

`TranscriptBuffer` class with:

- `TimestampedText` private struct (text + timestamp)
- `segments` array, `lastTickBoundaryIndex` int
- `init(maxStorageDurationSeconds:)` defaulting to 300 (5 min)
- `append(_:at:)` — adds segment, calls `pruneOldSegments()`
- `markTickBoundary()` — sets boundary to current segment count
- `extractChunk(contextWindowSeconds:)` — returns `Chunk(newText:contextText:)` where new = after boundary, context = before boundary within window
- `pruneOldSegments()` — removes segments older than max storage, adjusts boundary index

- [ ] **Step 4: Run tests — should pass**

- [ ] **Step 5: Commit**

```bash
git add Greenroom/
git commit -m "Add TranscriptBuffer with rolling window and chunk extraction"
```

---

## Task 8: Sound Effect Library & Engine

**Files:**

- Create: `Greenroom/Greenroom/SoundEffects/SoundEffectLibrary.swift`
- Create: `Greenroom/Greenroom/SoundEffects/SoundEffectEngine.swift`
- Test: `Greenroom/GreenroomTests/SoundEffectLibraryTests.swift`

- [ ] **Step 1: Write SoundEffectLibrary tests**

- Valid effect name returns correct file name
- Unknown effect name returns nil
- `allEffectNames` has exactly 12 entries

- [ ] **Step 2: Run tests — should fail**

- [ ] **Step 3: Write SoundEffectLibrary.swift**

`enum SoundEffectLibrary` with private static dict mapping 12 effect names to `sfx_*.mp3` file names. Static `fileName(for:)` and `allEffectNames` computed property.

- [ ] **Step 4: Run tests — should pass**

- [ ] **Step 5: Write SoundEffectEngine.swift**

`SoundEffectEngine` class with `AVAudioPlayer`, `volume: Float` (default 0.7), `isMuted: Bool`. `play(effectName:)` looks up file in `SoundEffectLibrary`, finds URL in bundle's `Sounds` subdirectory, plays via `AVAudioPlayer`. Unknown names logged and ignored. `stop()` method.

- [ ] **Step 6: Source and add 12 sound effect .mp3 files**

Create `Greenroom/Greenroom/SoundEffects/Sounds/` directory and add all 12 .mp3 files: `sfx_rimshot.mp3`, `sfx_ba_dum_tss.mp3`, `sfx_laugh_track.mp3`, `sfx_wrong_buzzer.mp3`, `sfx_sad_trombone.mp3`, `sfx_crickets.mp3`, `sfx_dun_dun_dun.mp3`, `sfx_airhorn.mp3`, `sfx_dramatic_sting.mp3`, `sfx_ding.mp3`, `sfx_applause.mp3`, `sfx_chef_kiss.mp3`. Source from royalty-free libraries (freesound.org, etc.) — keep each under 3 seconds. Add the Sounds/ folder to the Xcode project as a folder reference so files are copied to the app bundle.

- [ ] **Step 6: Commit**

```bash
git add Greenroom/
git commit -m "Add sound effect library and playback engine"
```

---

## Task 9: Claude API Client

**Files:**

- Create: `Greenroom/Greenroom/AI/ClaudeAPIClient.swift`

- [ ] **Step 1: Write ClaudeAPIClient.swift**

`ClaudeAPIClient` class:

- Reads `workerBaseURL` and `selectedModel` from `UserDefaults`
- `sendRequest(systemPrompt:messages:model:)` async throws → `PersonaUpdate?` — `model` parameter defaults to the UserDefaults value (Sonnet 4.6 if unset, Opus 4.6 as option)
- Builds JSON body with `model`, `max_tokens: 1024`, `system`, `messages`
- POSTs to `{workerBaseURL}/chat`
- Parses Claude's response: extracts `content[0].text`, decodes as `PersonaUpdate`
- Returns nil on parse failure (logs raw text)
- `ClaudeAPIError` enum: `noWorkerURL`, `invalidURL`, `invalidResponse`, `apiError(statusCode:body:)`, `unexpectedFormat`
- Default model: `claude-sonnet-4-6-20250514`
- 30 second timeout

- [ ] **Step 2: Commit**

```bash
git add Greenroom/
git commit -m "Add Claude API client for non-streaming persona requests"
```

---

## Task 10: Greenroom Engine (Orchestration Loop)

**Files:**

- Create: `Greenroom/Greenroom/AI/GreenroomEngine.swift`

- [ ] **Step 1: Write GreenroomEngine.swift**

`GreenroomEngine` class — the central brain:

- Owns `ClaudeAPIClient`, `TranscriptBuffer`, `SoundEffectEngine`
- `bridge: WebViewBridge?` property (set by window controller)
- `tickIntervalSeconds` and `contextWindowSeconds` read from UserDefaults with sensible defaults
- `isPaused` flag, `consecutiveFailures` counter
- `start()`: creates repeating `Timer` at tick interval, sets live status
- `stop()`: invalidates timer, sets offline status
- `onTranscriptText(_:)`: appends to buffer
- `tick()`: response-gated (skip if `isRequestInFlight`), extracts chunk from buffer, marks boundary, skips if no new text, sets `isRequestInFlight`, sends tick start to bridge, builds messages array with conversation history, calls Claude async, on success: sends update to bridge + plays Fred SFX + updates history, on failure: increments failures, shows error after 3 consecutive
- `conversationHistory`: array of message dicts, trimmed to last 3 cycles (6 messages)
- `updateSoundEffectsMuted(_:)` and `updateSoundEffectsVolume(_:)` for settings integration

- [ ] **Step 2: Write GreenroomEngineTests.swift**

Test: `Greenroom/GreenroomTests/GreenroomEngineTests.swift`

Test cases (using the engine's public interface, no mocking needed for pure logic):

- `testTickSkipsWhenPaused`: set `isPaused = true`, call `tick()` (via exposing for testing), verify no request made
- `testConversationHistoryTrimming`: manually append 10 history entries, verify only last 6 remain (3 cycles)
- `testConsecutiveFailuresCounting`: verify counter increments and resets correctly

- [ ] **Step 2: Commit**

```bash
git add Greenroom/
git commit -m "Add GreenroomEngine — response-gated tick loop with history"
```

---

## Task 11: System Audio Capture

**Files:**

- Create: `Greenroom/Greenroom/Audio/SystemAudioCaptureEngine.swift`
- Create: `Greenroom/Greenroom/Audio/AudioFormatConverter.swift`

- [ ] **Step 1: Write SystemAudioCaptureEngine.swift**

Uses `SCStream` for audio-only capture:

- `start()` async: get `SCShareableContent`, get primary display, configure `SCStreamConfiguration` with `capturesAudio = true`, `sampleRate = 16000`, `channelCount = 1`, `excludesCurrentProcessAudio = true` (prevents SFX feedback loop)
- Create `SCContentFilter` with the display
- Private `AudioStreamOutput` class implementing `SCStreamOutput` — forwards `.audio` type sample buffers to `onAudioBuffer` callback
- `stop()` async: stop capture
- Error enum for no display / permission denied

- [ ] **Step 2: Write AudioFormatConverter.swift**

Static utility enum:

- `convertToPCM16Data(sampleBuffer: CMSampleBuffer) -> Data?`: extracts raw audio bytes from CMBlockBuffer
- `convertToPCM16Data(pcmBuffer: AVAudioPCMBuffer) -> Data?`: converts float32 channel data to Int16 PCM (clamp to [-1, 1], multiply by Int16.max)

- [ ] **Step 3: Commit**

```bash
git add Greenroom/
git commit -m "Add system audio capture via ScreenCaptureKit and format converter"
```

---

## Task 12: Microphone Capture & Audio Mixer

**Files:**

- Create: `Greenroom/Greenroom/Audio/MicrophoneCaptureEngine.swift`
- Create: `Greenroom/Greenroom/Audio/AudioMixer.swift`

- [ ] **Step 1: Write MicrophoneCaptureEngine.swift**

Uses `AVAudioEngine`:

- `start()`: install tap on `inputNode` (bus 0, bufferSize 4096, format pcmFloat32 mono 16kHz), convert buffers to PCM16 via `AudioFormatConverter`, call `onAudioData` callback on main actor
- `stop()`: remove tap, stop engine

- [ ] **Step 2: Write AudioMixer.swift**

Serial dispatch queue mixer with basic AGC:

- Serial `DispatchQueue` for thread safety
- `receiveSystemAudio(_:)` and `receiveMicrophoneAudio(_:)` both normalize then forward data to `onMixedAudio` callback
- Basic RMS-based AGC: compute RMS of each incoming buffer, scale toward a target RMS level (~0.1 for PCM16 normalized range). This prevents the host's mic from drowning out system audio in transcription.
- Both sources feed independently — AssemblyAI handles interleaved multi-speaker audio

- [ ] **Step 3: Commit**

```bash
git add Greenroom/
git commit -m "Add microphone capture and audio mixer"
```

---

## Task 13: AssemblyAI Transcription Provider

**Files:**

- Create: `Greenroom/Greenroom/Transcription/TranscriptionProvider.swift`
- Create: `Greenroom/Greenroom/Transcription/AssemblyAIProvider.swift`

**Reference:** `../tutor/leanring-buddy/AssemblyAIStreamingTranscriptionProvider.swift`

- [ ] **Step 1: Write TranscriptionProvider.swift**

Protocol with `start(workerBaseURL:onText:onError:)` async throws, `feedAudio(_:)`, `stop()`.

- [ ] **Step 2: Write AssemblyAIProvider.swift**

Borrow patterns from Lore's provider:

- **Shared URLSession** (static, long-lived — avoids Code 57 connection pool corruption)
- **Token fetch**: POST to `{workerBaseURL}/transcribe-token`, cache for 400s
- **Websocket URL**: `wss://streaming.assemblyai.com/v3/ws` with query params: `sample_rate=16000`, `encoding=pcm_s16le`, `format_turns=true`, `speech_model=u3-rt-pro`, `language_detection=true`, `token=TOKEN`
- **feedAudio**: base64-encode PCM16 data, send as JSON `{"audio":"<base64>"}`
- **receiveMessages**: recursive receive loop, handle message types:
  - `turn` with `end_of_turn=true`: call `onText` with finalized transcript + space
  - `error`: log and call `onError`
- **stop**: cancel websocket with `.normalClosure`
- **Auto-reconnect**: when the websocket drops unexpectedly (receive error while `isRunning`), trigger exponential backoff reconnection (1s, 2s, 4s, max 30s). During reconnection, audio is buffered locally (the `feedAudio` calls accumulate in a queue). On reconnect, flush buffered audio. After 60 seconds of failed reconnections, call `onError` with a persistent failure and stop retrying (user must click Retry).
- **Status notifications**: call a `onStatusChange` callback with states: `.connected`, `.reconnecting`, `.failed` — the coordinator forwards these to the bridge for the status bar indicator.
- `TranscriptionError` enum for invalid URL, token fetch failure, server error

- [ ] **Step 3: Commit**

```bash
git add Greenroom/
git commit -m "Add AssemblyAI streaming transcription provider"
```

---

## Task 14: Coordinator — Wire Everything Together

**Files:**

- Create: `Greenroom/Greenroom/App/GreenroomCoordinator.swift`
- Modify: `Greenroom/Greenroom/App/GreenroomAppDelegate.swift`
- Modify: `Greenroom/Greenroom/Window/GreenroomWindowController.swift`

- [ ] **Step 1: Write GreenroomCoordinator.swift**

Owns all subsystems and wires them:

- Properties: `engine`, `systemAudioEngine`, `microphoneEngine`, `audioMixer`, `transcriptionProvider`
- `startListening()` async:
  1. Check Worker URL is set (show error if not)
  2. Wire audioMixer.onMixedAudio → transcriptionProvider.feedAudio
  3. Wire systemAudioEngine.onAudioBuffer → AudioFormatConverter → audioMixer.receiveSystemAudio
  4. Wire microphoneEngine.onAudioData → audioMixer.receiveMicrophoneAudio
  5. Start transcription (wire onText → engine.onTranscriptText)
  6. Start system audio (try, log if unavailable)
  7. Start mic (try, log if unavailable)
  8. Start engine tick loop
- `stopListening()` async: stop engine, transcription, both audio engines
- **Permission revocation handling**: `SystemAudioCaptureEngine` and `MicrophoneCaptureEngine` should each expose an `onStreamLost: (() -> Void)?` callback. The coordinator monitors these: if system audio is lost, continue with mic only and notify bridge ("System audio lost — mic only"). If mic is lost, continue with system audio only. If both are lost, pause the session and show a permission re-request flow.
- **First-run detection**: on `startListening()`, if Worker URL is empty, auto-open the Settings Panel with the Worker URL field focused and show a "Welcome" message in the sidebar via the bridge (e.g., `greenroom.setErrorStatus("Set your Worker URL in Settings to get started")`). Do not silently fail.

- [ ] **Step 2: Update GreenroomAppDelegate**

Create coordinator, pass to window controller. On first launch (check a `hasLaunchedBefore` UserDefaults flag), auto-open the Settings Panel after showing the window.

- [ ] **Step 3: Update GreenroomWindowController**

Accept coordinator in init. Wire `coordinator.engine.bridge = bridge`. Wire sidebar action handler: mute → engine, pause → engine, settings → open settings panel. Auto-start listening on window appear (only if Worker URL is set).

- [ ] **Step 4: Build and verify compilation**

App should compile and show sidebar. Full pipeline works once Worker URL is configured.

- [ ] **Step 5: Commit**

```bash
git add Greenroom/
git commit -m "Add GreenroomCoordinator wiring audio -> transcription -> AI -> UI"
```

---

## Task 15: Settings Panel

**Files:**

- Create: `Greenroom/Greenroom/Window/GreenroomSettingsPanel.swift`
- Create: `Greenroom/Greenroom/Utilities/DesignTokens.swift`

- [ ] **Step 1: Write DesignTokens.swift**

`enum DesignTokens` with `Colors` sub-enum: gary/fred/jackie/troll accent NSColors.

- [ ] **Step 2: Write GreenroomSettingsPanel.swift**

Non-modal `NSPanel` hosting a SwiftUI `SettingsFormView` via `NSHostingView`:

- Connection section: Worker URL text field + help text about BYOK
- AI section: model picker (Picker with two options: "Claude Sonnet 4.6" / "Claude Opus 4.6", backed by `@AppStorage("selectedModel")`), tick interval slider (5-60s), context window slider (1-5 min), show confidence toggle (for Gary's confidence indicator)
- Sound Effects section: mute toggle, volume slider
- Window section: float-on-top toggle, sidebar width slider (280-500px — sends a resize message to the window controller)
- All backed by `@AppStorage` for automatic UserDefaults persistence
- Show Confidence setting: pass to the WebView via bridge so the UI can toggle Gary's confidence display. Add a `greenroom.setShowConfidence(bool)` JS function and handle in personas.js.

- [ ] **Step 3: Wire settings button**

In window controller, handle `openSettings` action from bridge to show settings panel.

- [ ] **Step 4: Commit**

```bash
git add Greenroom/
git commit -m "Add settings panel — Worker URL, AI interval, SFX controls"
```

---

## Task 16: Documentation

**Files:**

- Create: `README.md`
- Create: `docs/architecture.md`
- Create: `docs/getting-started.md`
- Create: `docs/personas.md`
- Create: `docs/contributing.md`
- Create: `scripts/setup.sh`

- [ ] **Step 1: Write README.md**

Must include:

- One-line pitch: "AI production staff for your live show"
- Feature list: 4 personas with descriptions
- Screenshot/GIF placeholder
- **Quick Start (BYOK)** — prominently placed, step by step:
  1. Clone repo
  2. Deploy Cloudflare Worker:
     ```
     cd worker && npm install
     npx wrangler login
     npx wrangler secret put ANTHROPIC_API_KEY
     npx wrangler secret put ASSEMBLYAI_API_KEY
     npx wrangler deploy
     ```
     Note the deployed URL.
  3. Build in Xcode: open `Greenroom/Greenroom.xcodeproj`, set signing, Cmd+R
  4. Settings → paste Worker URL
  5. Grant Screen Recording + Microphone permissions
  6. Start listening — play your show
- Architecture diagram (ASCII art from spec)
- Configuration reference table
- License: MIT, Dakshay Mehta
- Link to detailed docs

- [ ] **Step 2: Write docs/getting-started.md**

Expanded setup walkthrough:

- Prerequisites: macOS 14.2+, Xcode 16+, Node.js 18+, free Cloudflare account
- Detailed Worker deployment with verification curl command
- Xcode build with signing instructions
- Permission setup walkthrough
- Troubleshooting: Worker URL errors, "no audio" issues, permission problems

- [ ] **Step 3: Write docs/architecture.md**

Architecture deep-dive for contributors: two-layer design, audio pipeline, AI engine tick loop, WebView bridge, sound effects, data flow diagram.

- [ ] **Step 4: Write docs/personas.md**

How to edit persona prompts in `PersonaPrompts.swift`, how to add a new persona (add to prompts + BridgeMessages + HTML lane + CSS accent), design guidelines for good personas.

- [ ] **Step 5: Write docs/contributing.md**

Dev setup, code style (clarity > concision, comments explain "why"), PR guidelines, testing expectations.

- [ ] **Step 6: Create scripts/setup.sh**

Shell script that automates first-time Worker setup: `cd worker && npm install`, prompts for `npx wrangler login`, `npx wrangler secret put ANTHROPIC_API_KEY`, `npx wrangler secret put ASSEMBLYAI_API_KEY`, `npx wrangler deploy`, then prints the deployed URL. Make executable: `chmod +x scripts/setup.sh`.

> **Note:** "Session summary on stop" from the spec is deferred from v1 — it's marked "(optional)" in the spec. Can be added as a future enhancement.

- [ ] **Step 6: Commit**

```bash
git add README.md docs/
git commit -m "Add documentation — README with BYOK setup, architecture, persona, and contributing guides"
```

---

## Task 17: Final Integration Testing

- [ ] **Step 1: Run all unit tests**

Cmd+U in Xcode. All should pass: TranscriptBufferTests, PersonaResponseTests, SoundEffectLibraryTests, BridgeMessagesTests.

- [ ] **Step 2: Build and run full app**

Cmd+R. Verify:

- Window appears with dark sidebar
- Settings panel opens from gear icon
- Worker URL entry works
- Live indicator turns green after starting
- Playing YouTube produces transcript + persona responses after ~15s
- Fred SFX play (if not muted)
- Mute / pause toggles work
- Window remembers position on relaunch

- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "Greenroom v0.1.0 — first working version"
```
