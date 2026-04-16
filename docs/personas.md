# Personas

Greenroom's four personas are defined entirely by a single system prompt in `PersonaPrompts.swift`. Each persona has a distinct personality, strict rules about when to speak, and a specific JSON output shape. This guide covers how they work, how to customize them, and how to add new ones.

## How Personas Work

Every ~15 seconds, the engine sends the latest transcript chunk to Claude with a master system prompt that defines all four personas. Claude analyzes the transcript and returns a single JSON object:

```json
{
  "gary": { "trigger": "...", "text": "...", "confidence": 0.95 } | null,
  "fred": { "trigger": "...", "effect": "rimshot", "context": "..." } | null,
  "jackie": { "trigger": "...", "text": "..." } | null,
  "troll": { "trigger": "...", "text": "..." } | null
}
```

Any persona set to `null` had nothing worth saying for that tick. This is by design — quality over quantity.

## The Four Personas

### Gary — The Fact-Checker

**Personality:** Calm, precise, never editorializes. Only speaks when a verifiable factual claim has been made.

**Output fields:**

- `trigger` — the specific claim from the transcript (5-10 words)
- `text` — the fact-check response (1-2 sentences)
- `confidence` — 0.0 to 1.0 confidence score
- `search_query` — optional query to trigger live Exa web search

**Special behavior:** When `search_query` is present, the engine makes a follow-up call: it searches Exa, feeds the results back to Claude, and gets a sourced response. This happens transparently — the sidebar shows Gary's final, enriched response.

### Fred — The Sound Engineer

**Personality:** Perfect comic timing. Expresses himself through sound effects, not words. Selective — only fires when the moment genuinely calls for it.

**Output fields:**

- `trigger` — what prompted the effect
- `effect` — one of 12 valid effect names (see below)
- `context` — optional explanation of why this effect fits

**Valid effects:**

| Effect           | When to use                       |
| ---------------- | --------------------------------- |
| `rimshot`        | Classic punchline                 |
| `ba-dum-tss`     | Exaggerated punchline             |
| `wrong-buzzer`   | Incorrect statements or bad takes |
| `sad-trombone`   | Disappointment or failure         |
| `crickets`       | Awkward silence, jokes that bomb  |
| `dun-dun-dun`    | Dramatic reveals                  |
| `airhorn`        | Big announcements, hype moments   |
| `dramatic-sting` | Surprising plot twists            |
| `ding`           | Correct answer, small win         |
| `applause`       | Genuine accomplishments           |
| `laugh-track`    | Sitcom-worthy moments             |
| `chef-kiss`      | Something perfectly executed      |

**Special behavior:** The `SoundEffectEngine` plays the actual audio file from the `Sounds/` bundle directory. Unknown effect names are silently ignored.

### Jackie — The Comedy Writer

**Personality:** Sharp, quick. Loves wordplay, subversions, callbacks. Only speaks when the joke is genuinely good. Punches up, never down.

**Output fields:**

- `trigger` — what she's riffing on
- `text` — the joke (one line, two at most)

### The Troll — The Chaos Agent

**Personality:** Lovable devil's advocate. Challenges assumptions, pokes at weak arguments, asks uncomfortable questions. Plain-spoken and direct.

**Output fields:**

- `trigger` — what they're pushing back on
- `text` — the contrarian take (1-2 sentences)

## The Trigger Quote System

Every persona response includes a `trigger` field — a brief quote (5-10 words) from the transcript that shows exactly what prompted the reaction. This appears in the sidebar as a gray italic line above the response:

```
re: "the Great Wall is visible from space"
Actually, this is a common misconception...
```

This gives the host immediate context for why each persona spoke, especially useful when multiple personas react to the same tick.

## Customizing Persona Prompts

All persona definitions live in one place:

```
Greenroom/Greenroom/Greenroom/AI/PersonaPrompts.swift
```

The `masterSystemPrompt` static property contains the full system prompt. To customize a persona:

1. Open `PersonaPrompts.swift`
2. Find the persona's section in the prompt (e.g., `### Gary — The Fact-Checker`)
3. Edit the personality description, rules, or JSON shape
4. Build and run — changes take effect on the next AI tick

### Tips for Good Persona Prompts

- **Be specific about when to speak.** Vague instructions lead to personas responding every tick. "Only respond when a clear, verifiable factual claim has been made" is better than "respond to interesting facts."
- **Be specific about when to stay silent.** Explicitly say "return null if [condition]."
- **Keep output short.** These are sidebar glances, not essays. Enforce sentence limits.
- **Define the JSON shape precisely.** Include an example. Claude follows examples closely.
- **Give the persona a point of view.** "Calm, precise, never editorializes" is a clear voice. "Helpful and informative" is not.

## Adding a New Persona

Adding a fifth persona requires changes in four places:

### 1. Define the Prompt

In `PersonaPrompts.swift`, add a new section to `masterSystemPrompt`:

````swift
### NewPersona — The Role
[Personality description]

**NewPersona's rules:**
- [When to speak]
- [When to stay silent]
- [Output constraints]

**NewPersona's JSON shape:**
\```json
{ "trigger": "quote from transcript", "text": "..." }
\```
````

Update the OUTPUT FORMAT section to include the new key:

```json
{
  "gary": ... | null,
  "fred": ... | null,
  "jackie": ... | null,
  "troll": ... | null,
  "newpersona": ... | null
}
```

### 2. Add the Response Type

In `BridgeMessages.swift`, add a new response struct:

```swift
struct NewPersonaResponse: Codable {
    let trigger: String?
    let text: String
}
```

Add it to `PersonaUpdate`:

```swift
struct PersonaUpdate: Codable {
    let gary: GaryResponse?
    let fred: FredResponse?
    let jackie: JackieResponse?
    let troll: TrollResponse?
    let newpersona: NewPersonaResponse?
    // ...
}
```

### 3. Add the Sidebar Lane

In `Greenroom/Greenroom/Greenroom/sidebar/index.html`, add a new persona lane inside `#persona-container`:

```html
<section class="persona-lane" data-persona="newpersona">
  <div class="persona-header">
    <img
      class="persona-avatar"
      src="assets/newpersona.png"
      alt=""
      onerror="this.style.display = 'none'"
    />
    <span class="persona-name">NewPersona</span>
    <span class="persona-role">The Role</span>
  </div>
  <div class="persona-messages">
    <div class="message-bubble placeholder">Listening...</div>
  </div>
  <canvas class="sine-wave" data-persona="newpersona"></canvas>
</section>
```

### 4. Add the Accent Color

In `Greenroom/Greenroom/Greenroom/sidebar/styles.css`, add the accent color:

```css
:root {
  --newpersona-accent: #your-color;
}

[data-persona="newpersona"] .persona-name {
  color: var(--newpersona-accent);
}
[data-persona="newpersona"] .message-bubble {
  border-left: 2px solid var(--newpersona-accent);
}
```

In `Greenroom/Greenroom/Greenroom/sidebar/sinewave.js`, add the color to `ACCENT_COLORS`:

```js
var ACCENT_COLORS = {
  gary: "#4A9EFF",
  fred: "#4ADE80",
  jackie: "#FBBF24",
  troll: "#F87171",
  newpersona: "#YOUR_COLOR",
};
```

In `Greenroom/Greenroom/Greenroom/sidebar/personas.js`, initialize history for the new persona:

```js
var history = {
  gary: [],
  fred: [],
  jackie: [],
  troll: [],
  newpersona: [],
};
```

In `Greenroom/Greenroom/Greenroom/sidebar/app.js`, add the persona to the update loop:

```js
var personas = ["gary", "fred", "jackie", "troll", "newpersona"];
```

Optionally, add the native accent color in `DesignTokens.swift` for any future native UI that needs it.

## Design Guidelines

When designing personas, keep these principles in mind:

- **Selectivity over coverage.** A persona that speaks every tick is noise. A persona that speaks once every few minutes with something sharp is valuable.
- **Distinct voices.** Each persona should have a clearly different tone. If two personas would say similar things, one of them doesn't need to exist.
- **Brevity.** The sidebar is narrow. One or two sentences max. If it needs a paragraph, it's not a sidebar comment.
- **Trigger awareness.** Every response should clearly relate to something that was just said. The trigger quote system enforces this — design prompts that produce specific, quotable triggers.
