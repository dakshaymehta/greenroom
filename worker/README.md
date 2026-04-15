# Greenroom Worker

Cloudflare Worker that acts as an API proxy for the Greenroom macOS app.

## What it does

Greenroom uses a BYOK (Bring Your Own Keys) model — you deploy your own Worker
with your own API keys stored as Cloudflare secrets. The app stores your Worker
URL and calls it for all external API requests. No API keys ever ship inside the
app binary.

| Route                    | Upstream                            | Purpose                                              |
| ------------------------ | ----------------------------------- | ---------------------------------------------------- |
| `POST /chat`             | `api.anthropic.com/v1/messages`     | Proxy Claude chat requests (SSE streaming supported) |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Fetch a 480-second AssemblyAI WebSocket token        |
| `POST /exa-search`       | `api.exa.ai/search`                 | Neural web search for Gary's live fact-checking      |

## Required secrets

Set these before deploying:

```bash
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put EXA_API_KEY
```

## Deployment

```bash
cd worker
npm install

# Deploy to Cloudflare
npm run deploy
```

After deploying, Wrangler will print your Worker URL (e.g.
`https://greenroom-worker.<your-subdomain>.workers.dev`). Paste that URL into
Greenroom's settings.

## Local development

Create a `worker/.dev.vars` file with your keys (this file is gitignored):

```
ANTHROPIC_API_KEY=sk-ant-...
ASSEMBLYAI_API_KEY=...
```

Then run:

```bash
npm run dev
```

## Verify it's running

```bash
curl -s -X POST https://greenroom-worker.<your-subdomain>.workers.dev/transcribe-token | jq .
```

A successful response looks like:

```json
{ "token": "eyJ..." }
```
