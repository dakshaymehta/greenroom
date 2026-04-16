# Contributing

Thanks for your interest in contributing to Greenroom. This guide covers development setup, code style, and how to submit changes.

## Development Setup

### Prerequisites

- macOS 14.2+ (Sonoma)
- Xcode 16+
- Node.js 18+ (for the Cloudflare Worker)

### Clone and Build

```bash
git clone https://github.com/your-username/greenroom.git
cd greenroom
open Greenroom/Greenroom.xcodeproj
```

Set your signing team in Xcode under **Signing & Capabilities**, then **Cmd+R** to build and run.

### Worker Setup

If you need to test Worker changes locally:

```bash
cd worker
npm install
```

Create `worker/.dev.vars` with your API keys (this file is gitignored):

```
ANTHROPIC_API_KEY=sk-ant-...
ASSEMBLYAI_API_KEY=...
EXA_API_KEY=...
```

Run the local dev server:

```bash
npm run dev
```

Set the Worker URL in the app's Settings to `http://localhost:8787`.

## Code Style

The guiding principle is **clarity over concision**. A developer with zero context should immediately understand what a variable or method name means. Write more lines if it improves readability.

### Swift

- **Clear is better than clever.** Prefer explicit, descriptive names over terse ones.
- **Comments explain "why", not "what".** The code says what it does. Comments say why.
- **All UI state on `@MainActor`.** Any property that drives UI must be isolated to the main actor.
- **`async/await` for all async work.** No callbacks or Combine unless there is no alternative.
- **SwiftUI for UI.** Use AppKit bridging only where required (`NSWindow`, `NSPanel`, `WKWebView`).

### JavaScript (Sidebar)

The sidebar uses vanilla JS with no build step. Keep it simple:

- No frameworks, no transpilation
- IIFE module pattern (see `app.js`, `personas.js`, `sinewave.js`)
- DOM manipulation via safe methods (`createElement`, `textContent`) — no `innerHTML`

### CSS

- CSS custom properties for all colors and timing values
- System font stack (`-apple-system`, `SF Pro Text`)
- Dark theme only

## Architecture Overview

Before making changes, read [docs/architecture.md](architecture.md) to understand how the pieces fit together. Key points:

- **Swift layer** owns audio capture, transcription, AI calls, and sound effects
- **WebView layer** owns the sidebar UI
- **WebViewBridge** is the seam between them — Swift pushes data in, JS sends actions out
- **GreenroomCoordinator** wires the full pipeline — nothing in the audio layer knows about transcription, and nothing in transcription knows about AI
- **Cloudflare Worker** is a thin API proxy — no business logic

## Making Changes

### Branch Naming

Use descriptive branch names:

- `feat/new-persona-type` — new feature
- `fix/socket-reconnect` — bug fix
- `refactor/audio-pipeline` — refactoring

### What to Change Where

| I want to...                        | Change this                                                                                            |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Edit persona personalities or rules | `PersonaPrompts.swift`                                                                                 |
| Add a new persona                   | See [docs/personas.md](personas.md)                                                                    |
| Change the sidebar look and feel    | `Greenroom/Greenroom/Greenroom/sidebar/styles.css`, `Greenroom/Greenroom/Greenroom/sidebar/index.html` |
| Fix audio capture issues            | `SystemAudioCaptureEngine.swift` or `MicrophoneCaptureEngine.swift`                                    |
| Change the AI tick behavior         | `GreenroomEngine.swift`                                                                                |
| Add a new Worker route              | `worker/src/index.ts`                                                                                  |
| Add a new sound effect              | Add `.mp3` to `Sounds/`, add mapping to `SoundEffectLibrary.swift`, add name to `PersonaPrompts.swift` |
| Change bridge communication         | `WebViewBridge.swift` (Swift side) + `app.js` (JS side)                                                |

### Do NOT

- Do not run `xcodebuild` from the terminal — always build through Xcode
- Do not add features that were not asked for — implement exactly what is specified
- Do not add docstrings or documentation comments to code you did not change

## Pull Requests

### Before Submitting

1. Build and run the app in Xcode — make sure it compiles cleanly
2. Test your change with a live audio source if it touches the audio or AI pipeline
3. If you changed the Worker, test locally with `npm run dev`

### PR Format

Keep the PR description clear and focused:

```
## What

[One sentence describing the change]

## Why

[Why this change is needed]

## How

[Brief description of the approach, if non-obvious]

## Testing

[How you verified it works]
```

### Review Expectations

- Small, focused PRs are easier to review and more likely to be merged
- One PR per logical change — don't bundle unrelated fixes
- If a change is large, open an issue first to discuss the approach

## Testing

Greenroom doesn't have a traditional test suite yet. The primary testing approach is:

1. **Build and run** in Xcode
2. **Play audio** (podcast, video, music) and verify the full pipeline works
3. **Check each persona** — are responses relevant and well-formatted?
4. **Test edge cases** — no audio, network disconnection, invalid Worker URL, permission denial

The Xcode project includes placeholder test targets (`GreenroomTests`, `GreenroomUITests`) for future automated tests.

## Project Structure

See [docs/architecture.md](architecture.md) for the full file structure and how each component connects.
