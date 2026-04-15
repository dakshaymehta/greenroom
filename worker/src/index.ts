/**
 * Greenroom Worker — API proxy for Claude and AssemblyAI.
 *
 * BYOK model: each user deploys their own Worker with their own API keys
 * stored as Cloudflare secrets. The Greenroom macOS app stores the Worker
 * URL and calls these routes directly — no API keys ever ship in the app.
 *
 * Routes:
 *   POST /chat              → Anthropic Messages API (Claude)
 *   POST /transcribe-token  → AssemblyAI temp WebSocket token (480s)
 *   OPTIONS *               → CORS preflight
 */

// ---------------------------------------------------------------------------
// Environment bindings
// ---------------------------------------------------------------------------

/** Secrets injected by Cloudflare at runtime via `wrangler secret put`. */
interface Env {
  /** Anthropic API key for proxying Claude requests. */
  ANTHROPIC_API_KEY: string;
  /** AssemblyAI API key for fetching short-lived transcription tokens. */
  ASSEMBLYAI_API_KEY: string;
}

// ---------------------------------------------------------------------------
// CORS
// ---------------------------------------------------------------------------

/** CORS headers applied to every response and the OPTIONS preflight. */
const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

/**
 * Copies an existing Response but injects CORS headers.
 * Preserves the original status, statusText, and body untouched.
 */
function withCORS(response: Response): Response {
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(CORS_HEADERS)) {
    headers.set(key, value);
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

// ---------------------------------------------------------------------------
// Route: POST /chat
// ---------------------------------------------------------------------------

/**
 * Proxies the request body to the Anthropic Messages API.
 *
 * The app sends a fully-formed Anthropic API request body; this handler
 * adds the required auth headers and pipes the response (including SSE
 * streaming) straight back to the caller.
 */
async function handleChat(request: Request, env: Env): Promise<Response> {
  try {
    const body = await request.text();

    const upstreamResponse = await fetch(
      "https://api.anthropic.com/v1/messages",
      {
        method: "POST",
        headers: {
          "x-api-key": env.ANTHROPIC_API_KEY,
          "anthropic-version": "2023-06-01",
          "Content-Type": "application/json",
        },
        body,
      },
    );

    // Forward the upstream response body and status directly to the caller.
    // This preserves SSE streaming: the body is a ReadableStream that the
    // Worker pipes through without buffering the entire response in memory.
    return new Response(upstreamResponse.body, {
      status: upstreamResponse.status,
      headers: {
        "Content-Type":
          upstreamResponse.headers.get("Content-Type") || "application/json",
      },
    });
  } catch (error) {
    console.error("[/chat] Unhandled error:", error);
    return new Response(JSON.stringify({ error: String(error) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
}

// ---------------------------------------------------------------------------
// Route: POST /transcribe-token
// ---------------------------------------------------------------------------

/**
 * Fetches a short-lived AssemblyAI WebSocket token (expires in 480 seconds).
 *
 * The app uses this token to open a streaming transcription WebSocket
 * directly to AssemblyAI without ever holding the real API key on-device.
 * A fresh token is fetched before each push-to-talk session.
 */
async function handleTranscribeToken(
  _request: Request,
  env: Env,
): Promise<Response> {
  try {
    const upstreamResponse = await fetch(
      "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
      {
        method: "GET",
        headers: {
          authorization: env.ASSEMBLYAI_API_KEY,
        },
      },
    );

    if (!upstreamResponse.ok) {
      const errorBody = await upstreamResponse.text();
      console.error(
        `[/transcribe-token] AssemblyAI error ${upstreamResponse.status}: ${errorBody}`,
      );
      return new Response(errorBody, {
        status: upstreamResponse.status,
        headers: { "Content-Type": "application/json" },
      });
    }

    const tokenJSON = await upstreamResponse.text();
    return new Response(tokenJSON, {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (error) {
    console.error("[/transcribe-token] Unhandled error:", error);
    return new Response(JSON.stringify({ error: String(error) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
}

// ---------------------------------------------------------------------------
// Main fetch handler
// ---------------------------------------------------------------------------

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // Handle CORS preflight for all routes
    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 200,
        headers: CORS_HEADERS,
      });
    }

    const url = new URL(request.url);

    switch (url.pathname) {
      case "/chat":
        return withCORS(await handleChat(request, env));

      case "/transcribe-token":
        return withCORS(await handleTranscribeToken(request, env));

      default:
        return withCORS(
          new Response(JSON.stringify({ error: "Not found" }), {
            status: 404,
            headers: { "Content-Type": "application/json" },
          }),
        );
    }
  },
};
