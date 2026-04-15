# Greenroom — Design Spec

> Live AI sidebar with 4 personas watching your show in real time.

**Author**: Dakshay Mehta
**Date**: 2026-04-15
**Status**: Approved
**Deployment Target**: macOS 14.2+ (Sonoma) — required for ScreenCaptureKit audio-only capture

---

## Problem

Live show hosts (podcasters, streamers, YouTube Live creators) perform alone or with limited production staff. They lack real-time fact-checking, comedic support, contextual background, and the kind of chaotic energy that a full production crew brings. The Howard Stern Show had Gary Dell'Abate (producer/fact-checker), Fred Norris (sound effects/context), Jackie Martling (comedy writer), and countless callers providing a rich backchannel. Most shows don't have that.

## Solution

**Greenroom** is a native macOS app that listens to a live show in real time and provides a sidebar with 4 AI personas offering live commentary. The host glances at it like a production monitor. Optionally, it can be captured in OBS as a viewer-facing element.

The 4 personas:

| Persona                             | Inspired By     | Role                                                                               | Output           |
| ----------------------------------- | --------------- | ---------------------------------------------------------------------------------- | ---------------- |
| **Gary** (The Fact-Checker)         | Gary Dell'Abate | Monitors conversation for factual claims, provides corrections and background data | Text             |
| **Fred** (Sound Effects & Context)  | Fred Norris     | Supplies background context and plays sound effects at key moments                 | Text + Audio SFX |
| **Jackie** (The Comedy Writer)      | Jackie Martling | Generates one-liners and jokes related to the current discussion                   | Text             |
| **The Troll** (Cynical Commentator) | N/A             | Provides snarky, cynical feedback and "troll" commentary                           | Text             |

## Architecture

### Overview

Hybrid native macOS app: Swift handles audio capture, transcription, AI orchestration, and sound effects. A WKWebView hosts the sidebar UI (HTML/CSS/JS) for fast iteration on the visual layer.

```
┌─────────────────────────────────────────────────┐
│                Greenroom.app (Swift)             │
│                                                  │
│  ┌──────────────┐    ┌────────────────────────┐  │
│  │ Audio Engine  │    │   AI Engine            │  │
│  │              │    │                        │  │
│  │ System Audio ─┼──►│ AssemblyAI Streaming ──┼──► Transcript Buffer
│  │ (ScreenCap)  │    │                        │
│  │              │    │ Claude (One-Call) ◄─────┼── Every ~15s chunk
│  │ Microphone  ─┼──►│                        │
│  │ (AVAudio)    │    │ Structured JSON ───────┼──► Per-persona responses
│  └──────────────┘    └────────┬───────────────┘  │
│                               │                  │
│  ┌──────────────┐    ┌────────▼───────────────┐  │
│  │ Sound Engine  │    │   WKWebView            │  │
│  │              │    │   (Sidebar UI)         │  │
│  │ Fred's SFX  ◄┼────┤                        │  │
│  │ AVAudioPlayer│    │  4 Persona Lanes       │  │
│  └──────────────┘    │  Sine Wave Animations  │  │
│                      │  Message Bubbles       │  │
│                      └────────────────────────┘  │
│                                                  │
│  ┌──────────────────────────────────────────┐    │
│  │ Cloudflare Worker (API Proxy)            │    │
│  │ /chat (Claude)  /transcribe-token (AAI)  │    │
│  └──────────────────────────────────────────┘    │
└─────────────────────────────────────────────────┘
```

### Two Layers

**Swift layer** — owns everything the OS cares about:

- Audio capture (system + mic)
- Audio mixing and format conversion
- AssemblyAI streaming transcription
- Claude API orchestration via Cloudflare Worker
- Sound effects playback (Fred)
- WKWebView hosting and JS bridge
- Window management and permissions

**WebView layer** — owns everything the eye sees:

- 4 persona lanes with avatars, names, message bubbles
- Sine wave activity animations
- Dark theme, broadcast-quality design
- Auto-scroll with history expansion
- Pure HTML/CSS/JS (no build step, no framework)

**Cloudflare Worker** — API proxy:

- `/chat` — Claude API proxy (no keys in the app)
- `/transcribe-token` — AssemblyAI temp token endpoint
- Forked from Lore's existing Worker (Lore is the author's macOS AI companion app — the Worker structure and AssemblyAI patterns are proven in production there)

---

## Audio Pipeline

### Inputs

**System audio** via `SCStream` (ScreenCaptureKit):

- Audio-only configuration (no video capture needed)
- Captures everything playing on the Mac: co-hosts via Zoom/Discord, media clips, music
- Requires Screen Recording permission (macOS)
- Delivers `CMSampleBuffer` audio frames

**Microphone** via `AVAudioEngine`:

- Captures the host's own voice
- Standard microphone permission
- Delivers `AVAudioPCMBuffer` frames

### Mixing

Both streams are mixed into a single PCM16 mono 16kHz stream (AssemblyAI's expected format):

1. `SCStream` delivers `CMSampleBuffer` on its own callback queue; `AVAudioEngine` delivers `AVAudioPCMBuffer` on its tap queue. The `AudioMixer` receives both asynchronously and interleaves samples into a single output buffer on a dedicated serial queue.
2. **Automatic gain control (AGC)**: The host's mic is typically much louder than system audio (co-hosts come through speakers/headphones at lower gain). The mixer applies a simple AGC step — normalizing both streams to similar RMS levels before mixing — so the transcript isn't dominated by the host's voice.
3. **Single-source fallback**: If only one permission is granted (e.g., mic but not Screen Recording, or vice versa), the app runs with that single source. Both are preferred but neither is strictly required on its own.
4. The mixed output is the "full show audio" — everything the audience would hear plus the host.

### SFX Audio Isolation

Fred's sound effects play through `AVAudioPlayer`, which outputs to the system audio device. If ScreenCaptureKit captures system audio, the SFX would loop back into the transcription pipeline (SFX gets transcribed → triggers more SFX). To prevent this, the `SystemAudioCaptureEngine` uses `SCStreamConfiguration.excludesCurrentProcessAudio = true` to exclude Greenroom's own audio output from the capture. This is a ScreenCaptureKit API available since macOS 14.2.

### Transcription

AssemblyAI streaming (same proven pattern as Lore):

1. Fetch short-lived websocket token from Cloudflare Worker (`/transcribe-token`)
2. Open websocket to AssemblyAI v3 endpoint
3. Stream mixed PCM16 audio in real time
4. Receive partial transcripts (in-progress) and final transcripts (speaker-turn complete)
5. Final transcripts accumulate in a rolling buffer

The transcript buffer stores the last **5 minutes** of finalized text (the storage window). When the AI engine requests a chunk, it extracts two pieces: the **new text** (~15 seconds since last tick) and the **context window** (configurable, default 2 minutes of preceding text for lookback). The storage window is larger than the context window so that the buffer doesn't lose text if the user increases the context setting mid-session.

---

## AI Engine

### The One-Call Pattern

Instead of 4 separate Claude calls per interval (expensive, ~4x cost), a single call handles all personas:

1. Every **~15 seconds** (configurable via settings), the latest transcript chunk is packaged
2. The chunk includes: new text (~15s) + recent context (~2 min lookback)
3. One Claude API call via the Cloudflare Worker with structured output
4. Claude responds as whichever personas have something relevant to say
5. Personas with nothing to say return `null` — no forced commentary

**Model**: Claude Sonnet 4.6 (default — fast + smart enough for real-time). Opus 4.6 as optional upgrade for higher quality.

**Non-streaming**: Since the response is a single structured JSON blob (not a chat message), the Claude call uses standard request/response (non-streaming). This simplifies JSON parsing — no need to assemble partial SSE chunks. The full response arrives in ~2-5 seconds (Sonnet) or ~5-10 seconds (Opus), which is acceptable for a 15-second tick interval.

### Structured Output Schema

```json
{
  "gary": {
    "text": "Actually, Tokyo's metro population is about 14 million, not 30 million. Greater Tokyo metro area is around 37 million though.",
    "confidence": 0.95
  },
  "fred": {
    "effect": "wrong-buzzer",
    "context": "Quick background: Tokyo proper vs. Greater Tokyo are very different numbers. Common mixup."
  },
  "jackie": {
    "text": "30 million? That's not a city, that's a country with really good public transit."
  },
  "troll": null
}
```

### Field Definitions

The top-level object always contains exactly 4 keys (`gary`, `fred`, `jackie`, `troll`). Each value is either an object or `null`. A key must not be omitted — use `null` for silence.

| Persona  | Field        | Type          | Required          | Description                            |
| -------- | ------------ | ------------- | ----------------- | -------------------------------------- |
| `gary`   | `text`       | string        | yes (if non-null) | Fact-check or background info          |
| `gary`   | `confidence` | number (0-1)  | no, default 0.8   | How confident the correction is        |
| `fred`   | `effect`     | string (enum) | no                | Sound effect name from bundled library |
| `fred`   | `context`    | string        | no                | Background context text                |
| `jackie` | `text`       | string        | yes (if non-null) | Joke or one-liner                      |
| `troll`  | `text`       | string        | yes (if non-null) | Cynical commentary                     |

**Fred can respond with `effect` only, `context` only, or both.** At least one must be present if Fred is non-null.

**Valid `effect` values** (enum, enforced in Swift parsing): `rimshot`, `ba-dum-tss`, `wrong-buzzer`, `sad-trombone`, `crickets`, `dun-dun-dun`, `airhorn`, `dramatic-sting`, `ding`, `applause`, `laugh-track`, `chef-kiss`. Unknown values are logged and ignored (no crash, no sound).

### Persona System Prompts

Each persona has a distinct system prompt. These are defined in a clean configuration layer so they can be customized or extended.

**Gary (The Fact-Checker)**:

> You are Gary, a stern but dedicated producer monitoring a live show. Your job is to catch factual errors, verify claims, and provide quick background data. You're slightly exasperated — you've heard it all before. Only respond when there's a verifiable factual claim. Be terse and accurate. If nothing to fact-check, return null.

**Fred (Sound Effects & Context)**:

> You are Fred, a brilliant but enigmatic sound engineer. You suggest perfectly-timed sound effects and provide deadpan background context. Available effects: rimshot, ba-dum-tss, wrong-buzzer, sad-trombone, crickets, dun-dun-dun, airhorn, dramatic-sting, ding, applause, laugh-track, chef-kiss. Only suggest an effect when the moment truly calls for it. Provide brief context when relevant background info would help. If nothing warrants a response, return null.

**Jackie (The Comedy Writer)**:

> You are Jackie, a comedy writer who can't resist a setup. You write quick one-liners and jokes about what's being discussed. Your style is punchy, sometimes groan-worthy, and always fast. One or two sentences max. Only respond when there's genuine comedy material in the conversation. If nothing's funny, return null.

**The Troll (Cynical Commentator)**:

> You are the Troll, a cynical commentator who provides snarky feedback. You disagree with hot takes, mock bad arguments, and offer nihilistic observations. You're not mean-spirited — you're entertainingly cynical. Short, cutting remarks only. If there's nothing worth trolling, return null.

### Conversation History

Each AI call includes:

- The master system prompt (all 4 persona definitions + output format)
- The last 3-5 persona response cycles (so personas can build on earlier commentary)
- The latest transcript chunk + context window

This gives the personas memory within a session — Gary can say "as I mentioned earlier..." and the Troll can callback to previous moments.

### Tick Timer Behavior

The AI engine runs on a **response-gated timer**, not a strict interval:

1. Timer fires every N seconds (default 15).
2. If a Claude call is already in-flight, the tick is **skipped** — no queuing, no back-to-back calls.
3. Transcript that accumulated during the skipped tick is included in the next chunk (the buffer handles this naturally).
4. If Claude responds faster than the interval, the remaining time is idle (no early fire).

This prevents runaway API costs if Claude is slow (Opus, network issues) and keeps the UX predictable — the host never sees two batches of responses arrive in rapid succession.

### Cost Estimate

Per-call token estimate (realistic, accounting for conversation history):

- System prompt (4 persona definitions + output format): ~400 tokens
- Conversation history (last 3 response cycles × ~200 tokens each): ~600 tokens
- Transcript chunk (new text + context window): ~500-1000 tokens
- **Total input: ~1500-2000 tokens per call**
- **Output: ~100-300 tokens** (most personas are null or short)

At 1 call every 15 seconds:

- 4 calls/min = 240 calls/hour
- ~480K input tokens/hour, ~48K output tokens/hour
- Sonnet 4.6: roughly **$2-4/hour** of live show
- Opus 4.6: roughly **$15-25/hour** of live show

Acceptable for a production tool. Configurable interval (5-60s) lets users trade off responsiveness vs. cost.

---

## Sidebar UI (WebView)

### Layout

The sidebar is a vertical stack of 4 persona lanes inside a dark-themed window:

```
┌──────────────────────────────────┐
│  🎙️ GREENROOM          ● LIVE   │  ← Status bar (listening indicator)
├──────────────────────────────────┤
│                                  │
│  📋 Gary Dell'Abate             │  ← Persona header (avatar + name)
│  ┌────────────────────────────┐ │
│  │ Actually, Tokyo metro is   │ │  ← Message bubble
│  │ 14M, not 30M. Greater     │ │
│  │ Tokyo area is ~37M.       │ │
│  └────────────────────────────┘ │
│  ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿  │  ← Sine wave (active)
│                                  │
├──────────────────────────────────┤
│                                  │
│  🎛️ Fred Norris        [🔊|🔇] │  ← SFX mute toggle
│  ┌────────────────────────────┐ │
│  │ 🔊 *wrong buzzer*         │ │  ← Sound effect indicator
│  │ Tokyo proper vs. Greater  │ │
│  │ Tokyo — common mixup.     │ │
│  └────────────────────────────┘ │
│  ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿  │
│                                  │
├──────────────────────────────────┤
│                                  │
│  🤣 Jackie Martling             │
│  ┌────────────────────────────┐ │
│  │ 30 million? That's not a   │ │
│  │ city, that's a country     │ │
│  │ with really good transit.  │ │
│  └────────────────────────────┘ │
│  ∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿  │
│                                  │
├──────────────────────────────────┤
│                                  │
│  🧌 The Troll                    │
│  ┌────────────────────────────┐ │
│  │        — quiet —           │ │  ← Null response (idle)
│  └────────────────────────────┘ │
│  ─────────────────────────────  │  ← Flat line (idle)
│                                  │
├──────────────────────────────────┤
│  ⚙️ Settings    ⏸️ Pause         │  ← Footer controls
└──────────────────────────────────┘
```

### Design Principles

- **Dark theme**: `#0D0D0D` background, broadcast-friendly, easy on eyes in a dim studio
- **Persona accent colors**: Each persona gets a unique muted accent (Gary: blue, Fred: green, Jackie: amber, Troll: red). Applied to sine wave, bubble border, and name label.
- **Typography**: Clean sans-serif (system font), sized for arm's-length readability (~14-16px body)
- **Width**: ~300-350px — sits alongside browser without cramping the host's main content
- **Message animations**: New messages slide up with a subtle ease-out; old messages fade to 60% opacity
- **Sine wave**: Canvas-based animation. Active = oscillating wave in persona's accent color. Idle = flat line in grey. Thinking = faster, smaller oscillation.
- **History**: Click a persona lane to expand a scrollable history of their past messages in that session
- **Minimal chrome**: No borders between lanes, just subtle spacing. The content is the star.

### Swift ↔ WebView Bridge

**Swift → JS** (sending persona responses to the UI):

```swift
// After parsing Claude's JSON response
let messageJSON = ... // serialized persona responses
webView.evaluateJavaScript("greenroom.onPersonaUpdate(\(messageJSON))")
```

**JS → Swift** (user interactions from the UI):

```javascript
// User clicks mute on Fred's sound effects
window.webkit.messageHandlers.greenroom.postMessage({
  action: "toggleFredMute",
});
```

Using `WKScriptMessageHandler` on the Swift side to receive messages.

---

## Sound Effects Engine

### Bundled Library

Sound effects are bundled as `.mp3` files in the app:

| Category    | Effects                                    |
| ----------- | ------------------------------------------ |
| Comedy      | `rimshot`, `ba-dum-tss`, `laugh-track`     |
| Negative    | `wrong-buzzer`, `sad-trombone`, `crickets` |
| Dramatic    | `dun-dun-dun`, `airhorn`, `dramatic-sting` |
| Affirmative | `ding`, `applause`, `chef-kiss`            |

### Playback

- `AVAudioPlayer` for sound effect playback
- Independent volume control (separate from system volume)
- Mute toggle visible in Fred's persona lane header
- Visual indicator when playing: waveform pulse animation + effect name label in Fred's bubble
- Effects are short (1-3 seconds) — they accent the moment, not overwhelm it

### Mapping

Claude returns an effect name string in Fred's response. Swift maps it to the corresponding bundled file:

```swift
let soundEffectFileMap: [String: String] = [
    "rimshot": "sfx_rimshot.mp3",
    "wrong-buzzer": "sfx_wrong_buzzer.mp3",
    // ...
]
```

Unknown effect names are ignored gracefully (logged but no crash).

---

## Window Management

The app is a standard macOS window (not menu bar-only like Lore). This gives it:

- A resizable, repositionable window the host places wherever they want
- Easy capture as an OBS "Window Capture" source
- Standard window controls (close, minimize, resize)
- "Float on top" toggle so it stays visible over other windows

The window hosts a single WKWebView that fills the entire content area. All chrome is in the WebView itself (the header, footer, persona lanes).

### Settings Panel

Settings (model selection, interval timing, persona toggles, sound volume) are presented in a **separate non-modal NSPanel** — not a sheet. This allows the host to adjust settings (e.g., mute Fred, change interval) while the show is running without blocking the sidebar. The settings panel floats alongside the main window and can be dismissed independently.

---

## Data Flow (End to End)

```
1. App launches
   └── Request Screen Recording + Microphone permissions

2. User clicks "Start Listening"
   ├── Start SCStream (system audio capture)
   ├── Start AVAudioEngine (microphone capture)
   ├── Open AssemblyAI websocket (via Worker token)
   └── Sidebar shows "● LIVE" indicator

3. Audio flows continuously
   ├── System audio + mic → mix → PCM16 mono 16kHz
   ├── PCM16 → AssemblyAI websocket
   └── AssemblyAI → partial/final transcripts → transcript buffer

4. Every ~15 seconds (the "tick")
   ├── Take latest transcript chunk + context window
   ├── Send to Claude via Worker (/chat)
   ├── Claude returns structured JSON (4 persona responses)
   ├── Parse responses
   ├── Send to WebView via JS bridge
   ├── WebView animates new messages into persona lanes
   └── If Fred has a sound effect → Swift plays the .mp3

5. Repeat step 4 until user pauses or stops

6. User clicks "Stop"
   ├── Close AssemblyAI websocket
   ├── Stop audio capture
   └── Sidebar shows session summary (optional)
```

---

## Project Structure

```
greenroom/
├── README.md                          # Hero screenshot, pitch, quick start
├── LICENSE                            # MIT
├── CLAUDE.md → AGENTS.md              # Symlink so both Claude Code (reads CLAUDE.md) and other AI agents (read AGENTS.md) get the same instructions
├── AGENTS.md                          # Single source of truth for all AI coding agents
├── .gitignore
│
├── docs/
│   ├── architecture.md                # Deep-dive architecture doc
│   ├── getting-started.md             # Setup + first run guide
│   ├── personas.md                    # How to customize/add personas
│   └── contributing.md                # Contribution guide
│
├── Greenroom/                         # Xcode project root
│   ├── Greenroom.xcodeproj/
│   ├── Greenroom/                     # Swift source
│   │   ├── App/
│   │   │   ├── GreenroomApp.swift             # App entry point
│   │   │   └── GreenroomAppDelegate.swift     # NSApplicationDelegate
│   │   │
│   │   ├── Audio/
│   │   │   ├── SystemAudioCaptureEngine.swift # ScreenCaptureKit system audio
│   │   │   ├── MicrophoneCaptureEngine.swift  # AVAudioEngine mic input
│   │   │   ├── AudioMixer.swift               # Mix system + mic streams
│   │   │   └── AudioFormatConverter.swift     # Convert to PCM16 mono 16kHz
│   │   │
│   │   ├── Transcription/
│   │   │   ├── TranscriptionProvider.swift    # Protocol
│   │   │   ├── AssemblyAIProvider.swift       # Streaming via websocket
│   │   │   └── TranscriptBuffer.swift         # Rolling transcript accumulator
│   │   │
│   │   ├── AI/
│   │   │   ├── GreenroomEngine.swift          # Core AI orchestration loop
│   │   │   ├── PersonaPrompts.swift           # System prompts for all personas
│   │   │   ├── PersonaResponse.swift          # Response model (Codable)
│   │   │   └── ClaudeAPIClient.swift          # Claude via Worker (non-streaming JSON)
│   │   │
│   │   ├── SoundEffects/
│   │   │   ├── SoundEffectEngine.swift        # Playback + mute + volume
│   │   │   ├── SoundEffectLibrary.swift       # Effect name → file mapping
│   │   │   └── Sounds/                        # Bundled .mp3 files
│   │   │       ├── sfx_rimshot.mp3
│   │   │       ├── sfx_wrong_buzzer.mp3
│   │   │       └── ...
│   │   │
│   │   ├── Bridge/
│   │   │   ├── WebViewBridge.swift            # WKScriptMessageHandler
│   │   │   └── BridgeMessages.swift           # Message types (Swift ↔ JS)
│   │   │
│   │   ├── Window/
│   │   │   ├── GreenroomWindowController.swift # Window lifecycle
│   │   │   └── GreenroomSettingsPanel.swift    # Settings sheet
│   │   │
│   │   ├── Resources/
│   │   │   ├── Assets.xcassets
│   │   │   └── Info.plist
│   │   │
│   │   └── Utilities/
│   │       └── DesignTokens.swift             # Colors, sizing constants
│   │
│   └── GreenroomTests/
│       ├── TranscriptBufferTests.swift
│       ├── PersonaResponseParsingTests.swift
│       └── SoundEffectLibraryTests.swift
│
├── sidebar/                           # WebView UI (no build step)
│   ├── index.html                     # Main sidebar markup
│   ├── styles.css                     # Dark theme, persona lanes, animations
│   ├── app.js                         # Main controller (bridge listener, state)
│   ├── personas.js                    # Persona lane rendering + updates
│   ├── sinewave.js                    # Canvas-based sine wave animations
│   └── assets/
│       ├── gary.png                   # Persona avatars
│       ├── fred.png
│       ├── jackie.png
│       └── troll.png
│
├── worker/                            # Cloudflare Worker (API proxy)
│   ├── src/index.ts                   # Routes: /chat, /transcribe-token
│   ├── wrangler.toml
│   ├── package.json
│   └── README.md                      # Worker-specific setup docs
│
└── scripts/
    └── setup.sh                       # First-time setup (Worker secrets, etc.)
```

---

## Open Source

- **License**: MIT
- **Author**: Dakshay Mehta
- **Repository**: `greenroom` (standalone, not a subdirectory of another project)

### Documentation Standards

- **README.md**: Hero screenshot/GIF demo, one-line pitch ("AI production staff for your live show"), feature list, quick start (3 steps), architecture overview with diagram, persona descriptions, configuration options, acknowledgments
- **docs/architecture.md**: Full architecture deep-dive — audio pipeline, AI engine, WebView bridge, data flow diagrams
- **docs/getting-started.md**: Prerequisites (macOS 14.2+, Xcode, Cloudflare account), step-by-step setup, first run walkthrough, troubleshooting common issues
- **docs/personas.md**: How to customize existing personas (edit prompts), how to add new personas (add to config + UI lane), persona design guidelines
- **docs/contributing.md**: Development setup, code style (clear naming, clarity over cleverness), PR guidelines, architecture overview for contributors

### Code Quality

- Follow Lore's naming conventions: optimize for clarity over concision
- Comments explain "why" not "what"
- Clean module boundaries: Audio, Transcription, AI, SoundEffects, Bridge, Window
- Each module can be understood independently
- Tests for parsing, buffer logic, and sound effect mapping

---

## Settings (User-Configurable)

| Setting            | Default    | Range         | Description                            |
| ------------------ | ---------- | ------------- | -------------------------------------- |
| AI Interval        | 15s        | 5-60s         | How often to send transcript to Claude |
| Model              | Sonnet 4.6 | Sonnet / Opus | Quality vs. speed/cost tradeoff        |
| Fred SFX Volume    | 70%        | 0-100%        | Sound effects volume                   |
| Fred SFX Muted     | false      | on/off        | Mute all sound effects                 |
| Float on Top       | true       | on/off        | Keep sidebar above other windows       |
| Sidebar Width      | 320px      | 280-500px     | Sidebar window width                   |
| Show Confidence    | false      | on/off        | Show Gary's confidence indicator       |
| Transcript Context | 2 min      | 1-5 min       | How much lookback context to include   |

---

## Permissions Required

| Permission       | Why                                       | macOS API                        |
| ---------------- | ----------------------------------------- | -------------------------------- |
| Screen Recording | System audio capture via ScreenCaptureKit | `SCStream`                       |
| Microphone       | Host voice capture                        | `AVAudioEngine`                  |
| Network          | API calls to Cloudflare Worker            | Standard (no special permission) |

The app should guide users through permission setup on first launch with clear explanations of why each permission is needed.

---

## Error Handling & Resilience

A live production tool must handle failures gracefully — the host can't debug mid-show.

### AssemblyAI Websocket Drops

- Auto-reconnect with exponential backoff (1s, 2s, 4s, max 30s).
- During reconnection, audio continues to buffer locally. When the websocket re-establishes, the buffered audio is flushed (AssemblyAI handles out-of-order audio gracefully).
- Sidebar shows a subtle "reconnecting..." indicator in the status bar (not per-persona — this is infrastructure).
- If reconnection fails after 60 seconds, show a persistent error state with a manual "Retry" button.

### Claude API Failures

- If a Claude call fails (network error, 429 rate limit, 529 overloaded), the tick is skipped and retried on the next interval. No immediate retry — the next tick handles it naturally.
- The sidebar shows a subtle "AI paused" indicator (persona lanes dim slightly). Personas show their last response, not an error state.
- If 3 consecutive ticks fail, show a persistent warning with the error type (rate limit vs. network vs. Worker down).

### Cloudflare Worker Unreachable

- Same retry logic as Claude failures (the Worker is the intermediary, so a Worker failure looks like a Claude failure to the app).
- The `/transcribe-token` endpoint is called once at session start. If it fails, the app cannot start listening — show a clear error with "Check your Worker deployment" guidance.

### Permission Revocation Mid-Session

- If Screen Recording permission is revoked: `SCStream` will stop delivering audio. The app detects the missing stream and falls back to mic-only mode with a notification: "System audio lost — running on microphone only."
- If Microphone permission is revoked: similarly fall back to system audio only.
- If both are revoked: pause the session and show a permission re-request flow.

### Malformed Claude Responses

- If Claude returns JSON that doesn't match the expected schema: log the raw response, skip the tick, continue. No crash, no user-visible error.
- If Claude returns non-JSON (hallucination, system error): same — log and skip.
- The `PersonaResponse` Codable model uses `decodeIfPresent` for all optional fields so partial responses are handled gracefully.

---

## App Lifecycle & Persistence

### Settings Persistence

All user settings are stored in `UserDefaults` and persist across launches. The settings table in this spec defines the defaults for first launch.

### Session State

Session state (transcript buffer, persona conversation history) is **ephemeral** — cleared on each new session start. The app does not attempt to resume a previous session on relaunch. If the user quits mid-show and relaunches, they start fresh. This is intentional: the transcript buffer and persona context are tied to a specific live show and don't carry over meaningfully.

### Window State

Window position, size, and "float on top" preference are persisted via `NSWindow.setFrameAutosaveName` so the window reappears in the same position after relaunch.

---

## Accessibility (v1 Scope)

v1 does not target full WCAG compliance, but includes baseline accessibility:

- **Keyboard navigation**: Mute toggle, pause, and settings are reachable via keyboard (Tab + Enter) in the WebView.
- **Contrast ratios**: All accent colors on the `#0D0D0D` background meet WCAG AA minimum (4.5:1 for body text). Muted accents are used for decorative elements only — message text is high-contrast white/light grey.
- **VoiceOver**: Not targeted in v1 (WebView content is dynamic and would require significant ARIA work). Noted as a future consideration.

---

## Future Considerations (Not in v1)

- **OBS Browser Source mode**: Serve the sidebar UI on a local HTTP server so OBS can load it as a browser source (no window capture needed)
- **Persona independence**: Split into 4 separate Claude calls for more authentic, uncoordinated responses
- **Voice output**: Optional TTS for personas (distinct voices)
- **Viewer interaction**: Personas react to live chat messages too
- **Transcript export**: Save the full show transcript + persona commentary as a post-show document
- **Custom personas**: User-defined characters beyond the 4 defaults
- **Multi-language**: Transcription and persona responses in other languages
