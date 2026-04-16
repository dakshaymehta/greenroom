# Greenroom

> AI production staff for your live show.

<video src="https://github.com/dakshaymehta/greenroom/releases/download/v0.1.0/greenroom-demo.mp4" width="100%" autoplay loop muted playsinline></video>

<img width="4604" height="2160" alt="image" src="https://github.com/user-attachments/assets/6e681349-5d0a-4a1b-9322-352096823c55" />


Greenroom is a native macOS sidebar that watches your podcast, stream, or live show in real time and reacts through four AI personas — a fact-checker, a sound engineer, a comedy writer, and a resident troll. It captures system audio and your microphone, transcribes speech via AssemblyAI, sends transcript chunks to Claude every 15 seconds, and displays structured responses in a dark, broadcast-style sidebar. A dedicated transcript viewer highlights the exact lines each persona reacted to so the product stays legible and trustworthy while the conversation is moving.

BYOK (Bring Your Own Keys) — you deploy a tiny Cloudflare Worker with your own API keys. No keys ship in the app. No backend to trust.

## The Production Staff

| Persona       | Role           | What They Do                                                                                                                             |
| ------------- | -------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| **Gary**      | Fact-Checker   | Catches factual errors. Can verify claims via Exa web search in real time. Calm, precise, citation-ready.                                |
| **Fred**      | Sound Engineer | Plays sound effects — rimshot, airhorn, sad trombone, and 9 others. Fires at exactly the right moment. Also provides background context. |
| **Jackie**    | Comedy Writer  | Writes quick one-liners about whatever's being discussed. Wordplay, callbacks, subversions. Only speaks when the joke is actually good.  |
| **The Troll** | Chaos Agent    | Snarky, cynical devil's advocate. Challenges assumptions, pokes at weak arguments, asks the uncomfortable questions.                     |

Every persona response includes a "trigger quote" — the exact snippet of conversation that prompted the reaction.

example: <img width="4604" height="2160" alt="image" src="https://github.com/user-attachments/assets/7bdaba6a-06c2-499b-a12a-6268f9a5a24e" />


## How It Works

```
                      ┌─────────────────┐
   System Audio ──────┤                 │
   (ScreenCaptureKit) │   Audio Mixer   ├──── AssemblyAI ──── Transcript
   Microphone ────────┤   (16kHz mono)  │     (WebSocket)      Buffer
   (AVAudioEngine)    └─────────────────┘
                                                                 │
                                                          every ~15s
                                                                 │
                                                                 ▼
                     ┌──────────────┐              ┌──────────────────┐
                     │   Sidebar    │◄─────────────┤  Claude (via CF  │
                     │  (WKWebView) │  persona     │     Worker)      │
                     └──────────────┘  updates     └────────┬─────────┘
                            │                               │
                            │                        ┌──────┴──────┐
                     ┌──────┴──────┐                 │  Exa Search │
                     │ Fred's SFX  │                 │ (fact-check) │
                     │ (AVAudioPlayer)               └─────────────┘
                     └─────────────┘
```

**Listen** — System audio and mic are captured, mixed to 16kHz mono PCM, and streamed to AssemblyAI over WebSocket for real-time transcription.

**Think** — Every ~15 seconds, the engine sends new transcript text (plus recent context) to Claude with a single structured prompt. Claude decides which personas have something worth saying and returns JSON.

**React** — Persona responses appear in the sidebar with slide-up animations. Fred's sound effects play immediately. Gary's fact-checks can trigger a follow-up Exa web search for sourced verification. The transcript viewer keeps a rolling context log and marks the lines each persona latched onto.

## Quick Start

### Prerequisites

- macOS 14.2+ (Sonoma)
- Xcode 16+
- Node.js 18+
- Free [Cloudflare account](https://dash.cloudflare.com/sign-up)
- API keys:
  - [Anthropic](https://console.anthropic.com/) (Claude) — **required**
  - [AssemblyAI](https://www.assemblyai.com/) (transcription) — **required**
  - [Exa](https://exa.ai/) (web search for fact-checking) — optional

### 1. Deploy the Worker

```bash
cd worker
npm install
npx wrangler login
```

Set your API keys as Cloudflare secrets:

```bash
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put EXA_API_KEY          # optional — enables Gary's web search
```

Deploy:

```bash
npm run deploy
```

Wrangler will print your Worker URL:

```
https://greenroom-worker.<your-subdomain>.workers.dev
```

Save this URL — you'll paste it into the app.

### 2. Build the App

```bash
open Greenroom/Greenroom.xcodeproj
```

1. Set your signing team under **Signing & Capabilities**
2. Press **Cmd+R** to build and run

### 3. Configure

1. Click the gear icon in the sidebar footer to open **Settings**
2. Paste your Worker URL
3. Grant **Screen Recording** and **Microphone** permissions when prompted
4. The sidebar will show **LIVE** — you're running

### Verify Your Worker

```bash
curl -s -X POST https://greenroom-worker.<your-subdomain>.workers.dev/transcribe-token | python3 -m json.tool
```

A successful response returns a token object:

```json
{ "token": "eyJ..." }
```

Or use the automated setup script:

```bash
chmod +x scripts/setup.sh
./scripts/setup.sh
```

## Configuration

All settings are accessible from the gear icon in the sidebar.

| Setting            | Default         | Description                                         |
| ------------------ | --------------- | --------------------------------------------------- |
| **Worker URL**     | —               | Your deployed Cloudflare Worker URL                 |
| **Model**          | Claude Sonnet 4 | Claude model for persona responses (Sonnet or Opus) |
| **Tick Interval**  | 15s             | How often the AI processes new transcript (5–60s)   |
| **Context Window** | 2 min           | How far back the AI can see for context (1–5 min)   |
| **SFX Muted**      | Off             | Mute Fred's sound effects                           |
| **SFX Volume**     | 70%             | Volume for Fred's sound effects                     |
| **Float on Top**   | On              | Keep the sidebar above other windows                |

## Architecture

Greenroom uses a two-layer hybrid architecture:

- **Swift layer** — audio capture (ScreenCaptureKit + AVAudioEngine), transcription (AssemblyAI WebSocket), AI orchestration (Claude API), sound effects (AVAudioPlayer)
- **WebView layer** — sidebar UI (vanilla HTML/CSS/JS in a WKWebView), persona lanes, animations, controls

The two layers communicate through a bidirectional bridge: Swift pushes persona updates and transcript text into JS via `evaluateJavaScript`, and JS sends user actions (mute, pause, settings) back to Swift via `WKScriptMessageHandler`.

For a deep dive, see [docs/architecture.md](docs/architecture.md).

## Customize Personas

Persona prompts live in `PersonaPrompts.swift`. You can edit personalities, add new personas, or change the output format. See [docs/personas.md](docs/personas.md) for a walkthrough.

## Contributing

See [docs/contributing.md](docs/contributing.md) for development setup, code style, and PR guidelines.

## For AI Agents

If you're an AI coding agent (Claude Code, Cursor, Copilot, Gemini CLI, etc.) pointed at this repo, read `AGENTS.md` (or its symlink `CLAUDE.md`) for architecture, build instructions, and code style.

**To get the app running from scratch:**

```bash
# 1. Deploy the Cloudflare Worker (needs API keys as interactive input)
cd worker && npm install
npx wrangler login
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler deploy
# Note the printed URL

# 2. Build the app (do NOT use xcodebuild — open in Xcode)
open Greenroom/Greenroom/Greenroom.xcodeproj
# Set signing team, Cmd+R to build and run

# 3. Configure: paste Worker URL in Settings (gear icon), grant permissions
```

**Key constraints for agents:**

- Do NOT run `xcodebuild` from the terminal — it invalidates TCC permissions
- The Xcode project has a triple-nested structure: `Greenroom/Greenroom/Greenroom/` contains the Swift source
- Sidebar UI lives at `Greenroom/Greenroom/Greenroom/sidebar/` as the single source of truth for both bundle builds and Xcode debug runs
- All text rendering in the sidebar uses `textContent` — never `innerHTML`
- Swift code style: optimize for clarity over concision, `@MainActor` for UI, async/await

## License

MIT — Dakshay Mehta
