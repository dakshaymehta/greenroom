# Getting Started

This guide walks through deploying your Cloudflare Worker, building the macOS app, and running Greenroom for the first time.

## Prerequisites

| Requirement            | Version        | Notes                                          |
| ---------------------- | -------------- | ---------------------------------------------- |
| **macOS**              | 14.2+ (Sonoma) | Required for ScreenCaptureKit audio capture    |
| **Xcode**              | 16+            | Swift 5.9+, macOS 14.2 SDK                     |
| **Node.js**            | 18+            | For Cloudflare Worker tooling (Wrangler)       |
| **Cloudflare account** | Free tier      | [Sign up](https://dash.cloudflare.com/sign-up) |

### API Keys

| Service        | Required | Purpose                             | Get a key                                               |
| -------------- | -------- | ----------------------------------- | ------------------------------------------------------- |
| **Anthropic**  | Yes      | Claude AI responses                 | [console.anthropic.com](https://console.anthropic.com/) |
| **AssemblyAI** | Yes      | Real-time transcription             | [assemblyai.com](https://www.assemblyai.com/)           |
| **Exa**        | No       | Web search for Gary's fact-checking | [exa.ai](https://exa.ai/)                               |

Without the Exa key, everything works normally — Gary just won't be able to verify claims with live web search.

## Step 1: Deploy the Cloudflare Worker

The Worker is a lightweight API proxy. It holds your API keys as Cloudflare secrets so they never ship inside the app binary. It has three routes:

- `POST /chat` — proxies requests to Claude
- `POST /transcribe-token` — fetches short-lived AssemblyAI WebSocket tokens
- `POST /exa-search` — proxies web search queries to Exa

### Automated Setup

```bash
chmod +x scripts/setup.sh
./scripts/setup.sh
```

The script walks you through login, secrets, and deployment. If you prefer to do it manually:

### Manual Setup

```bash
cd worker
npm install
```

Log in to Cloudflare (opens a browser):

```bash
npx wrangler login
```

Set your API keys as secrets. Wrangler will prompt you to paste each key:

```bash
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put EXA_API_KEY
```

Deploy:

```bash
npm run deploy
```

Wrangler prints the deployed URL:

```
Published greenroom-worker (x.xx sec)
  https://greenroom-worker.<your-subdomain>.workers.dev
```

Save this URL.

### Verify the Worker

Test that the Worker is reachable and can fetch an AssemblyAI token:

```bash
curl -s -X POST https://greenroom-worker.<your-subdomain>.workers.dev/transcribe-token | python3 -m json.tool
```

Expected response:

```json
{
  "token": "eyJ..."
}
```

If you get an error, check:

- The Worker URL is correct (no trailing slash)
- Your `ASSEMBLYAI_API_KEY` secret is set correctly
- The Worker is deployed (check the Cloudflare dashboard)

### Local Development (Optional)

For local Worker development, create `worker/.dev.vars` (this file is gitignored):

```
ANTHROPIC_API_KEY=sk-ant-...
ASSEMBLYAI_API_KEY=...
EXA_API_KEY=...
```

Then run:

```bash
cd worker
npm run dev
```

The local Worker runs at `http://localhost:8787`.

## Step 2: Build the App

```bash
open Greenroom/Greenroom.xcodeproj
```

1. In Xcode, select the **Greenroom** target
2. Under **Signing & Capabilities**, set your signing team
3. Press **Cmd+R** to build and run

The sidebar window will appear with all four persona lanes showing "Listening..."

## Step 3: Configure

1. Click the **gear icon** in the sidebar footer to open Settings
2. Paste your Worker URL into the **Worker URL** field
3. Adjust other settings if desired (see below)
4. Close the settings panel

## Step 4: Grant Permissions

On first run, macOS will prompt for two permissions:

### Screen Recording

Required to capture system audio (what's playing through your speakers). Go to **System Settings > Privacy & Security > Screen Recording** and enable Greenroom.

You may need to restart the app after granting this permission.

### Microphone

Required to capture your microphone input. The standard macOS microphone permission dialog will appear on first launch.

## Step 5: Start Listening

Once the Worker URL is configured and permissions are granted:

1. Start playing audio (a podcast, a video call, music — anything)
2. The sidebar status indicator will show **LIVE** with a pulsing green dot
3. The transcript strip below the header will show text as speech is recognized
4. Within 15 seconds (one tick interval), persona responses will start appearing

## What to Expect

- **Gary** will only speak when someone states a verifiable fact
- **Fred** will fire a sound effect when the moment calls for it (punchlines, bad takes, dramatic reveals)
- **Jackie** will drop a one-liner when she has a genuinely good joke
- **The Troll** will push back when someone makes a challengeable claim

All four personas return `null` when they have nothing to say. Quiet ticks are normal — it means nobody had anything worth adding.

## Settings Reference

| Setting        | Default           | Range         | Description                               |
| -------------- | ----------------- | ------------- | ----------------------------------------- |
| Worker URL     | —                 | —             | Your Cloudflare Worker URL                |
| Model          | Claude Sonnet 4   | Sonnet / Opus | Claude model for persona responses        |
| Tick Interval  | 15s               | 5–60s         | How often the AI processes new transcript |
| Context Window | 2 min             | 1–5 min       | How much prior transcript the AI can see  |
| SFX Muted      | Off               | —             | Mute Fred's sound effects                 |
| SFX Volume     | 70%               | 0–100%        | Volume for sound effects                  |
| Float on Top   | On                | —             | Keep the sidebar above other windows      |

## Troubleshooting

### "No Worker URL configured"

You haven't entered your Worker URL in Settings. Click the gear icon and paste the URL from your Wrangler deploy output.

### Sidebar shows OFFLINE

The app hasn't started listening yet. This usually means the Worker URL is missing or the transcription connection failed. Check:

1. Worker URL is set in Settings
2. Worker is deployed and reachable (test with the curl command above)
3. AssemblyAI API key is valid

### "Transcription failed to connect"

The app couldn't fetch a token from your Worker or couldn't open the AssemblyAI WebSocket. Common causes:

- Worker URL is wrong or has a trailing slash
- `ASSEMBLYAI_API_KEY` secret isn't set on the Worker
- Network connectivity issue

### No transcript text appearing

- Check that **Screen Recording** permission is granted in System Settings
- Check that **Microphone** permission is granted
- Make sure audio is actually playing — the transcript strip should update within a few seconds of speech
- You may need to restart the app after granting Screen Recording permission

### Persona responses aren't appearing

- Wait at least one tick interval (default 15s) after speech starts
- Check that your Anthropic API key is valid and has credits
- If the sidebar shows an error after a few ticks, check the Xcode console for details

### Fred's sound effects aren't playing

- Check that SFX isn't muted (the speaker icon on Fred's lane)
- Check the SFX volume in Settings
- Make sure your system volume is up

### "System audio lost — running on mic only"

Screen Recording permission was revoked while the app was running. Re-enable it in System Settings and restart the app.
