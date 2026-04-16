# Architecture

Greenroom is a hybrid macOS app: Swift handles the heavy lifting (audio capture, AI calls, sound effects) while a WKWebView hosts the sidebar UI (vanilla HTML/CSS/JS). This split keeps native performance where it matters and allows rapid UI iteration without recompiling.

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        macOS App (Swift)                        │
│                                                                 │
│  ┌──────────────────┐    ┌──────────────────┐                   │
│  │ SystemAudioCapture│    │ MicrophoneCapture │                  │
│  │ Engine            │    │ Engine            │                  │
│  │ (ScreenCaptureKit)│    │ (AVAudioEngine)   │                  │
│  └────────┬─────────┘    └────────┬──────────┘                  │
│           │ CMSampleBuffer        │ PCM s16le                   │
│           ▼                       ▼                             │
│  ┌──────────────────────────────────────────┐                   │
│  │            AudioFormatConverter           │                   │
│  │     (CMSampleBuffer → PCM s16le)         │                   │
│  └────────────────────┬─────────────────────┘                   │
│                       ▼                                         │
│  ┌──────────────────────────────────────────┐                   │
│  │              AudioMixer                   │                   │
│  │   (serializes both streams via GCD)       │                   │
│  └────────────────────┬─────────────────────┘                   │
│                       │ PCM s16le                               │
│                       ▼                                         │
│  ┌──────────────────────────────────────────┐                   │
│  │        AssemblyAIProvider                 │                   │
│  │   (WebSocket to AssemblyAI v3 API)        │                   │
│  │   Token fetched via Worker proxy          │                   │
│  └────────────────────┬─────────────────────┘                   │
│                       │ completed speech turns                  │
│                       ▼                                         │
│  ┌──────────────────────────────────────────┐                   │
│  │          TranscriptBuffer                 │                   │
│  │   (rolling 5-min window, tick boundary)   │                   │
│  └────────────────────┬─────────────────────┘                   │
│                       │ new text + context                      │
│                       ▼                                         │
│  ┌──────────────────────────────────────────┐                   │
│  │           GreenroomEngine                 │                   │
│  │   (tick timer, one-call-at-a-time gate)   │                   │
│  │                                           │                   │
│  │   PersonaPrompts.buildUserMessage() ──────┼──► ClaudeAPIClient│
│  │                                           │     POST /chat    │
│  │   ◄── PersonaUpdate (decoded JSON) ───────┼──◄ (via Worker)   │
│  │                                           │                   │
│  │   if Gary has search_query: ──────────────┼──► Exa search     │
│  │     enrichGaryWithSearch() ───────────────┼──► follow-up call │
│  │                                           │                   │
│  │   conversationHistory (3 cycles max)      │                   │
│  └──────────┬────────────────┬───────────────┘                   │
│             │                │                                   │
│             ▼                ▼                                   │
│  ┌──────────────┐  ┌──────────────────┐                         │
│  │ WebViewBridge │  │ SoundEffectEngine │                        │
│  │ (Swift ↔ JS)  │  │ (AVAudioPlayer)   │                        │
│  └──────┬───────┘  └──────────────────┘                         │
│         │                                                       │
│         ▼                                                       │
│  ┌──────────────────────────────────────────┐                   │
│  │              WKWebView                    │                   │
│  │   sidebar/index.html + CSS + JS           │                   │
│  │   4 persona lanes, sine wave animations   │                   │
│  └──────────────────────────────────────────┘                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ HTTPS
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                   Cloudflare Worker (BYOK)                      │
│                                                                 │
│   POST /chat             → api.anthropic.com/v1/messages        │
│   POST /transcribe-token → streaming.assemblyai.com/v3/token    │
│   POST /exa-search       → api.exa.ai/search                   │
└─────────────────────────────────────────────────────────────────┘
```

## Audio Pipeline

### System Audio (ScreenCaptureKit)

`SystemAudioCaptureEngine` uses ScreenCaptureKit to capture all system audio from the primary display. Configuration:

- **Sample rate:** 16,000 Hz (matches AssemblyAI's preferred input)
- **Channels:** 1 (mono)
- **Format:** PCM s16le
- **Self-exclusion:** `excludesCurrentProcessAudio = true` prevents Fred's sound effects from feeding back into transcription

Requires the **Screen Recording** permission. If revoked mid-session, `onStreamLost` fires so the app can degrade gracefully.

### Microphone (AVAudioEngine)

`MicrophoneCaptureEngine` installs a tap on the audio engine's input node using the hardware's native format, then normalizes each buffer through a reusable `AVAudioConverter` into 16kHz mono PCM s16le. This avoids tap-format mismatch errors on devices whose microphones do not run at 16kHz natively.

### Audio Mixer

`AudioMixer` receives PCM data from both capture engines and forwards it to the transcription provider. Both sources feed independently via a serial GCD queue for thread safety. AssemblyAI handles interleaved multi-speaker audio well, so no sample-level mixing is needed.

## Transcription

`AssemblyAIProvider` implements the `TranscriptionProvider` protocol, which decouples the transcription backend from the rest of the pipeline.

**Token flow:**

1. App calls `POST /transcribe-token` on the Worker
2. Worker fetches a 480-second token from AssemblyAI using the server-side API key
3. Token is cached for 400 seconds (safety margin before expiry)

**WebSocket connection:**

- URL: `wss://streaming.assemblyai.com/v3/ws`
- Parameters: `sample_rate=16000`, `encoding=pcm_s16le`, `format_turns=true`, `speech_model=u3-rt-pro`, `language_detection=true`
- Audio frames are streamed as raw binary PCM bytes
- The provider waits for the initial websocket `Begin` event before audio is allowed onto the wire
- Completed speech turns (`type: "Turn"` / `type: "turn"`) are forwarded to the engine

**Socket management:** A single shared `URLSession` is reused for the app lifetime. Creating sessions per connection causes Code 57 socket errors on rapid reconnects.

## Transcript Buffer

`TranscriptBuffer` accumulates timestamped text segments with stable IDs in a rolling 5-minute window. It maintains a **tick boundary** index that separates "already sent to AI" segments from "new since last tick" segments.

On each AI tick, `extractChunk()` returns:

- **newText** — segments after the boundary (what the AI should respond to)
- **contextText** — segments before the boundary within the configurable context window (so the AI understands references)

`TranscriptContextStore` mirrors those segments for UI use and applies persona highlights by matching each persona's trigger quote back onto the most relevant transcript line. The transcript viewer window reads from this store.

## AI Engine

`GreenroomEngine` is the central orchestrator. It runs entirely on `@MainActor`.

### Tick Loop

A repeating `Timer` fires every `tickIntervalSeconds` (default: 15s). Each tick:

1. **Guard:** Skip if paused or if a request is already in flight (one-call-at-a-time gate)
2. **Extract:** Pull new text and context from the transcript buffer
3. **Skip:** If new text is empty, do nothing
4. **Build:** Construct the user message via `PersonaPrompts.buildUserMessage()`
5. **Send:** Append to conversation history, POST to Claude via the Worker
6. **Parse:** Decode the response as a `PersonaUpdate` (4 optional persona objects)
7. **Enrich:** If Gary includes a `search_query`, call Exa and make a follow-up Claude call
8. **Distribute:** Push the update to the WebView bridge; play Fred's sound effect if present

### Conversation History

The engine maintains a rolling window of the last 3 user/assistant message pairs (6 entries). This gives Claude continuity across ticks without ballooning token usage during long sessions.

### Error Handling

Errors are counted consecutively. The sidebar only shows an error status after 3+ consecutive failures, avoiding false alarms from transient network blips. A single successful response resets the counter.

### Exa Search (Gary's Fact-Checking)

When Gary's response includes a `search_query` field:

1. The engine calls `POST /exa-search` on the Worker with the query
2. The Worker proxies to Exa's neural search API, returning title/text/URL snippets
3. A follow-up Claude call includes the search results and asks for Gary's updated, sourced response
4. The enriched Gary response replaces the original; other personas keep their original responses
5. If the search fails, the original (unsourced) Gary response is used — search failure never blocks other personas

## WebView Bridge

`WebViewBridge` handles bidirectional communication between Swift and the sidebar JavaScript.

### Swift to JS

Swift calls `evaluateJavaScript()` on the WKWebView:

| Method                   | JS Function Called                   | Purpose                               |
| ------------------------ | ------------------------------------ | ------------------------------------- |
| `sendPersonaUpdate()`    | `greenroom.onPersonaUpdate(obj)`     | Push persona responses to the sidebar |
| `sendTranscriptUpdate()` | `greenroom.onTranscriptUpdate(text)` | Update the live transcript strip      |
| `sendTickStart()`        | `greenroom.onTickStart()`            | Show thinking indicators              |
| `setLiveStatus()`        | `greenroom.setLiveStatus(bool)`      | Toggle LIVE/OFFLINE indicator         |
| `setErrorStatus()`       | `greenroom.setErrorStatus(msg)`      | Show error state with message         |

### JS to Swift

The sidebar JS posts messages via `window.webkit.messageHandlers.greenroom.postMessage(...)`. The bridge receives them as `WKScriptMessage` objects, decodes them as `SidebarAction` structs, and forwards via the `onSidebarAction` callback.

Actions: `toggleFredMute`, `togglePause`, `openSettings`.

## Sound Effects Engine

`SoundEffectEngine` plays bundled `.mp3` files via `AVAudioPlayer`. `SoundEffectLibrary` maps logical effect names (used in Claude's JSON output) to on-disk filenames.

12 bundled effects: rimshot, ba-dum-tss, laugh-track, wrong-buzzer, sad-trombone, crickets, dun-dun-dun, airhorn, dramatic-sting, ding, applause, chef-kiss.

Sound effects live in a `Sounds/` subdirectory inside the app bundle. Unknown effect names from the AI are logged and silently ignored.

## Sidebar UI

The sidebar is vanilla HTML/CSS/JS loaded from `Greenroom/Greenroom/Greenroom/sidebar/index.html`:

- **4 persona lanes** — each with avatar, name, role, message bubbles, and a sine wave canvas
- **Sine wave animations** — idle (flat line), thinking (subtle wave), active (prominent wave) in each persona's accent color
- **Message history** — click a persona header to expand and scroll through past messages (up to 50 stored per persona)
- **Trigger quotes** — each message shows the transcript snippet that triggered it
- **Transcript strip** — shows the most recent heard text, fades on update
- **Controls** — settings gear, pause/play toggle, Fred mute button

## File Structure

```
greenroom/
├── Greenroom/                    # Xcode project
│   └── Greenroom/
│       ├── App/                  # Entry point, coordinator, app delegate
│       ├── AI/                   # GreenroomEngine, ClaudeAPIClient, PersonaPrompts
│       ├── Audio/                # System + mic capture, mixer, format converter
│       ├── Bridge/               # WebViewBridge, BridgeMessages (PersonaUpdate types)
│       ├── SoundEffects/         # SoundEffectEngine, SoundEffectLibrary
│       ├── Transcription/        # TranscriptBuffer, TranscriptionProvider, AssemblyAIProvider
│       ├── Window/               # WindowController, SettingsPanel
│       └── Utilities/            # DesignTokens
├── Greenroom/Greenroom/Greenroom/sidebar/  # WebView UI (loaded into WKWebView)
│   ├── index.html
│   ├── styles.css
│   ├── app.js                    # Main module, native bridge interface
│   ├── personas.js               # Persona lane rendering and history
│   ├── sinewave.js               # Canvas-based sine wave animations
│   └── assets/                   # Persona avatar images
├── worker/                       # Cloudflare Worker (BYOK API proxy)
│   ├── src/index.ts              # Route handlers for /chat, /transcribe-token, /exa-search
│   ├── wrangler.toml             # Worker configuration
│   └── package.json
├── scripts/
│   └── setup.sh                  # Automated Worker deployment script
└── docs/                         # This documentation
```
