# Greenroom — Agent Instructions

This file is the **single source of truth** for all AI coding agents working on this codebase. `CLAUDE.md` is a symlink to this file — both point here.

---

## Overview

Greenroom is a macOS app that provides a live AI sidebar during shows, podcasts, and streams. It listens to audio in real time, transcribes speech, and surfaces commentary from 4 distinct AI personas — each with their own voice and perspective.

**Hybrid architecture:** Swift owns the heavy lifting (audio capture, AI calls, sound effects), and a WKWebView hosts the sidebar UI (vanilla HTML/CSS/JS). This split keeps native performance where it matters while allowing rapid UI iteration without recompiling.

---

## Architecture

| Concern               | Approach                                                                      |
| --------------------- | ----------------------------------------------------------------------------- |
| **App Type**          | Standard macOS window                                                         |
| **Deployment Target** | macOS 14.2+ (Sonoma)                                                          |
| **Framework**         | SwiftUI + AppKit bridging; `NSWindow` for main window, `NSPanel` for settings |
| **AI**                | Claude via Cloudflare Worker proxy; BYOK (bring your own key)                 |
| **Transcription**     | AssemblyAI streaming via WebSocket                                            |
| **Audio**             | ScreenCaptureKit for system audio + AVAudioEngine for mic                     |
| **Sidebar UI**        | WKWebView hosting vanilla HTML/CSS/JS                                         |
| **Sound Effects**     | AVAudioPlayer with bundled `.mp3` files                                       |

---

## Build & Run

1. Open `Greenroom/Greenroom.xcodeproj` in Xcode
2. Set your signing team under Signing & Capabilities
3. Press Cmd+R to build and run

---

## Code Style

**Optimize for clarity over concision.** A developer with zero context should immediately understand what a variable or method name means. Write more lines if it improves readability — dense one-liners are not a virtue here.

- **Clear is better than clever** — prefer explicit, descriptive names over terse ones
- **Comments explain "why", not "what"** — the code says what it does; comments say why it does it that way
- **All UI state on `@MainActor`** — any property that drives UI must be isolated to the main actor
- **`async/await` for all async operations** — no callbacks or Combine unless there is no alternative
- **SwiftUI for UI** — use AppKit bridging only when required (`NSWindow`, `NSPanel`, `WKWebView`)

---

## Do NOT

- Do not run `xcodebuild` from the terminal — always build through Xcode
- Do not add features that were not asked for — implement exactly what is specified
- Do not add docstrings or documentation comments to code you did not change
