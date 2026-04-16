var Greenroom = (function () {
  var WORKSPACE_EXPANDED_THRESHOLD = 680;
  var isPaused = false;
  var statusMode = "offline";
  var lastTranscript = "";
  var lastErrorMessage = "";
  var transcriptWindowVisible = false;
  var transcriptContext = emptyTranscriptContext();
  var lastFocusedSegmentID = null;

  function emptyTranscriptContext() {
    return {
      lines: [],
      focusedSegmentID: null,
      liveDraft: null,
    };
  }

  function init() {
    Personas.initClickToExpand();
    setupControls();
    installLayoutObserver();
    syncStatusPresentation();
    syncTranscriptPresentation();
    syncTranscriptWindowButton();
    renderTranscriptContext(true);
  }

  function setupControls() {
    var muteButton = document.getElementById("fred-mute");
    if (muteButton) {
      muteButton.addEventListener("click", function (event) {
        event.stopPropagation();
        muteButton.classList.toggle("muted");
        postToNative({
          action: "toggleFredMute",
          muted: muteButton.classList.contains("muted"),
        });
      });
    }

    var pauseButton = document.getElementById("btn-pause");
    if (pauseButton) {
      pauseButton.addEventListener("click", function () {
        isPaused = !isPaused;
        pauseButton.classList.toggle("active", isPaused);
        pauseButton.textContent = isPaused ? "\u25B6" : "\u23F8";
        document.body.classList.toggle("is-paused", isPaused);
        syncStatusPresentation();
        syncTranscriptPresentation();
        postToNative({ action: "togglePause", paused: isPaused });
      });
    }

    var settingsButton = document.getElementById("btn-settings");
    if (settingsButton) {
      settingsButton.addEventListener("click", function () {
        postToNative({ action: "openSettings" });
      });
    }

    var layoutButton = document.getElementById("btn-layout");
    if (layoutButton) {
      layoutButton.addEventListener("click", function () {
        postToNative({ action: "toggleWorkspaceMode" });
      });
    }

    var transcriptButton = document.getElementById("btn-transcript");
    if (transcriptButton) {
      transcriptButton.addEventListener("click", function () {
        postToNative({ action: "openTranscriptViewer" });
      });
    }
  }

  function installLayoutObserver() {
    syncWorkspaceMode();
    window.addEventListener("resize", syncWorkspaceMode);
  }

  function syncWorkspaceMode() {
    var isExpanded = window.innerWidth >= WORKSPACE_EXPANDED_THRESHOLD;
    document.body.classList.toggle("workspace-expanded", isExpanded);

    var layoutButton = document.getElementById("btn-layout");
    if (layoutButton) {
      layoutButton.classList.toggle("active", isExpanded);
    }
  }

  function postToNative(message) {
    if (
      window.webkit &&
      window.webkit.messageHandlers &&
      window.webkit.messageHandlers.greenroom
    ) {
      window.webkit.messageHandlers.greenroom.postMessage(message);
    }
  }

  function onPersonaUpdate(responses) {
    if (isPaused) return;

    var personas = ["gary", "fred", "jackie", "troll"];
    for (var index = 0; index < personas.length; index++) {
      var persona = personas[index];
      var data = responses && responses.hasOwnProperty(persona) ? responses[persona] : null;
      Personas.updatePersona(persona, data);
    }
  }

  function onTickStart() {
    if (!isPaused) {
      Personas.setAllThinking();
    }
  }

  function onTranscriptUpdate(text) {
    var transcriptText = document.getElementById("transcript-text");
    if (!transcriptText) return;

    var displayText = typeof text === "string" ? text.trim() : "";
    if (displayText.length > 320) {
      displayText = displayText.substring(0, 320) + "\u2026";
    }

    lastTranscript = displayText;
    if (displayText.length > 0) {
      lastErrorMessage = "";
    }

    document.body.classList.toggle("has-transcript", displayText.length > 0);

    transcriptText.classList.add("fading");
    window.setTimeout(function () {
      transcriptText.textContent = displayText || fallbackTranscriptCopy();
      transcriptText.classList.remove("fading");
      syncTranscriptPresentation();
    }, 90);
  }

  function onTranscriptContextUpdate(snapshot) {
    transcriptContext = normalizeTranscriptContext(snapshot);
    renderTranscriptContext(false);
  }

  function normalizeTranscriptContext(snapshot) {
    if (!snapshot || typeof snapshot !== "object") {
      return emptyTranscriptContext();
    }

    return {
      lines: Array.isArray(snapshot.lines) ? snapshot.lines : [],
      focusedSegmentID: snapshot.focusedSegmentID || null,
      liveDraft: snapshot.liveDraft || null,
    };
  }

  function renderTranscriptContext(isInitialRender) {
    var contextList = document.getElementById("context-list");
    var emptyState = document.getElementById("context-empty");
    if (!contextList || !emptyState) return;

    var lines = transcriptContext.lines || [];
    var liveDraft = transcriptContext.liveDraft;
    var hasContent = lines.length > 0 || !!liveDraft;

    emptyState.hidden = hasContent;
    contextList.hidden = !hasContent;

    if (!hasContent) {
      contextList.replaceChildren();
      return;
    }

    var shouldStickToBottom = isNearBottom(contextList);
    var nextChildren = [];

    for (var index = 0; index < lines.length; index++) {
      nextChildren.push(buildContextLine(lines[index]));
    }

    if (liveDraft && liveDraft.text) {
      nextChildren.push(buildLiveDraftLine(liveDraft));
    }

    contextList.replaceChildren.apply(contextList, nextChildren);

    var focusedID = transcriptContext.focusedSegmentID;
    var shouldPinToLiveEdge = shouldStickToBottom || !!liveDraft;

    if (shouldPinToLiveEdge) {
      contextList.scrollTop = contextList.scrollHeight;
    } else if (focusedID && focusedID !== lastFocusedSegmentID) {
      var focusedLine = contextList.querySelector(
        '.context-line[data-line-id="' + cssEscape(focusedID) + '"]'
      );
      if (focusedLine) {
        focusedLine.scrollIntoView({
          block: "center",
          behavior: isInitialRender ? "auto" : "smooth",
        });
      }
    }

    lastFocusedSegmentID = focusedID;
  }

  function buildContextLine(line) {
    var contextLine = document.createElement("article");
    contextLine.className = "context-line";
    contextLine.setAttribute("data-line-id", line.id || "");

    var highlights = Array.isArray(line.highlights) ? line.highlights : [];
    if (highlights.length > 0) {
      contextLine.classList.add("has-highlights");
      contextLine.style.setProperty("--line-accent", accentColorForHighlight(highlights[highlights.length - 1]));
    }

    if (line.id && line.id === transcriptContext.focusedSegmentID) {
      contextLine.classList.add("is-focused");
    }

    var mainRow = document.createElement("div");
    mainRow.className = "context-line-main";

    var time = document.createElement("div");
    time.className = "context-time";
    time.textContent = formatTimestamp(line.timestamp);

    var body = document.createElement("div");
    body.className = "context-body";
    body.textContent = line.text || "";

    mainRow.appendChild(time);
    mainRow.appendChild(body);
    contextLine.appendChild(mainRow);

    if (highlights.length > 0) {
      var highlightRow = document.createElement("div");
      highlightRow.className = "context-highlights";

      for (var index = 0; index < highlights.length; index++) {
        highlightRow.appendChild(buildContextHighlightChip(highlights[index]));
      }

      contextLine.appendChild(highlightRow);
    }

    return contextLine;
  }

  function buildLiveDraftLine(liveDraft) {
    var contextLine = document.createElement("article");
    contextLine.className = "context-line live-draft";
    contextLine.style.setProperty("--line-accent", "rgba(127, 177, 255, 0.92)");

    var liveRow = document.createElement("div");
    liveRow.className = "context-live-row";

    var livePill = document.createElement("span");
    livePill.className = "context-live-pill";
    livePill.textContent = "Live";

    liveRow.appendChild(livePill);
    contextLine.appendChild(liveRow);

    var mainRow = document.createElement("div");
    mainRow.className = "context-line-main";

    var time = document.createElement("div");
    time.className = "context-time";
    time.textContent = formatTimestamp(liveDraft.timestamp);

    var body = document.createElement("div");
    body.className = "context-body";
    body.textContent = liveDraft.text || "";

    mainRow.appendChild(time);
    mainRow.appendChild(body);
    contextLine.appendChild(mainRow);

    return contextLine;
  }

  function buildContextHighlightChip(highlight) {
    var chip = document.createElement("div");
    var persona = sanitizeToken(highlight.persona);
    chip.className = "context-highlight-chip " + persona;
    chip.title = buildHighlightTitle(highlight);

    var name = document.createElement("strong");
    name.textContent = highlight.displayName || humanizePersona(persona);

    var summary = document.createElement("span");
    summary.textContent = summarizeHighlight(highlight);

    chip.appendChild(name);
    chip.appendChild(summary);
    return chip;
  }

  function summarizeHighlight(highlight) {
    var reactionText = truncate(String(highlight.reactionText || ""), 88);

    if (sanitizeToken(highlight.persona) === "gary") {
      var verdict = humanizeVerdict(highlight.verdict);
      if (verdict && reactionText) {
        return verdict + ": " + reactionText;
      }
      if (reactionText) {
        return reactionText;
      }
      if (verdict) {
        return verdict;
      }
    }

    if (reactionText) {
      return reactionText;
    }

    if (highlight.trigger) {
      return "Picked up " + formatQuotedTrigger(highlight.trigger, 44);
    }

    return "Reacted to this line";
  }

  function buildHighlightTitle(highlight) {
    var parts = [];

    if (highlight.displayName) {
      parts.push(highlight.displayName);
    }

    if (highlight.reactionText) {
      parts.push(highlight.reactionText);
    }

    if (highlight.sourceNote) {
      parts.push("Sources: " + highlight.sourceNote);
    } else if (Array.isArray(highlight.sources) && highlight.sources.length) {
      parts.push(
        highlight.sources.length + " linked source" + (highlight.sources.length === 1 ? "" : "s")
      );
    }

    return parts.join("\n");
  }

  function accentColorForHighlight(highlight) {
    switch (sanitizeToken(highlight && highlight.persona)) {
      case "gary":
        return "rgba(127, 177, 255, 0.92)";
      case "fred":
        return "rgba(138, 195, 158, 0.92)";
      case "jackie":
        return "rgba(237, 200, 111, 0.92)";
      case "troll":
        return "rgba(239, 151, 148, 0.92)";
      default:
        return "rgba(255, 255, 255, 0.35)";
    }
  }

  function setLiveStatus(live) {
    statusMode = live ? "live" : "offline";
    if (live) {
      lastErrorMessage = "";
    }
    syncStatusPresentation();
    syncTranscriptPresentation();
  }

  function setErrorStatus(message) {
    statusMode = "error";
    lastErrorMessage = message || "";
    syncStatusPresentation();
    syncTranscriptPresentation();
  }

  function setTranscriptWindowVisible(isVisible) {
    transcriptWindowVisible = !!isVisible;
    syncTranscriptWindowButton();
  }

  function setShowConfidence(show) {
    Personas.setShowConfidence(show);
  }

  function syncTranscriptWindowButton() {
    var transcriptButton = document.getElementById("btn-transcript");
    if (!transcriptButton) return;

    transcriptButton.classList.toggle("active", transcriptWindowVisible);
  }

  function syncStatusPresentation() {
    var indicator = document.getElementById("live-indicator");
    if (!indicator) return;

    var label = indicator.querySelector(".status-label");
    indicator.classList.remove("live", "error");
    document.body.classList.remove("status-live", "status-offline", "status-error");

    if (statusMode === "live") {
      indicator.classList.add("live");
      document.body.classList.add("status-live");
      if (label) label.textContent = isPaused ? "Paused" : "Active";
      indicator.title = "";
      return;
    }

    if (statusMode === "error") {
      indicator.classList.add("error");
      document.body.classList.add("status-error");
      if (label) label.textContent = "Attention";
      indicator.title = lastErrorMessage;
      return;
    }

    document.body.classList.add("status-offline");
    if (label) label.textContent = "Standby";
    indicator.title = "";
  }

  function syncTranscriptPresentation() {
    var transcriptMode = document.getElementById("transcript-mode");
    if (!transcriptMode) return;

    var modeText = "";
    var modeKind = "hidden";
    var title = "";
    var isVisible = false;

    if (statusMode === "error") {
      modeText = "Issue";
      modeKind = "error";
      title = lastErrorMessage;
      isVisible = true;
    } else if (statusMode === "live" && isPaused) {
      modeText = "Paused";
      modeKind = "paused";
      isVisible = true;
    }

    transcriptMode.textContent = modeText;
    transcriptMode.dataset.mode = modeKind;
    transcriptMode.title = title;
    transcriptMode.hidden = !isVisible;
  }

  function fallbackTranscriptCopy() {
    if (statusMode === "live") {
      return "Listening for live speech...";
    }

    if (statusMode === "error" && lastErrorMessage) {
      return lastErrorMessage;
    }

    return "Waiting for audio...";
  }

  function isNearBottom(element) {
    if (!element) return true;
    var distanceFromBottom = element.scrollHeight - element.scrollTop - element.clientHeight;
    return distanceFromBottom < 72;
  }

  function formatTimestamp(timestampSeconds) {
    if (typeof timestampSeconds !== "number") return "";

    return new Date(timestampSeconds * 1000).toLocaleTimeString([], {
      hour: "numeric",
      minute: "2-digit",
      second: "2-digit",
    });
  }

  function humanizePersona(persona) {
    switch (sanitizeToken(persona)) {
      case "gary":
        return "Gary";
      case "fred":
        return "Fred";
      case "jackie":
        return "Jackie";
      case "troll":
        return "The Troll";
      default:
        return "";
    }
  }

  function humanizeVerdict(verdict) {
    switch (sanitizeToken(verdict)) {
      case "confirmed":
        return "Confirmed";
      case "contradicted":
        return "Contradicted";
      case "context":
        return "Needs context";
      case "unclear":
        return "Still unclear";
      default:
        return "";
    }
  }

  function formatQuotedTrigger(text, maxLength) {
    if (!text) return "\u201cthis line\u201d";
    return "\u201c" + truncate(String(text), maxLength) + "\u201d";
  }

  function sanitizeToken(value) {
    return String(value || "")
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "");
  }

  function truncate(text, maxLength) {
    if (!text || text.length <= maxLength) return text || "";
    return text.slice(0, maxLength - 1) + "\u2026";
  }

  function cssEscape(value) {
    if (window.CSS && typeof window.CSS.escape === "function") {
      return window.CSS.escape(value);
    }

    return String(value).replace(/"/g, '\\"');
  }

  return {
    init: init,
    onPersonaUpdate: onPersonaUpdate,
    onTickStart: onTickStart,
    onTranscriptUpdate: onTranscriptUpdate,
    onTranscriptContextUpdate: onTranscriptContextUpdate,
    setLiveStatus: setLiveStatus,
    setErrorStatus: setErrorStatus,
    setTranscriptWindowVisible: setTranscriptWindowVisible,
    setShowConfidence: setShowConfidence,
    postAction: postToNative,
  };
})();

window.greenroom = Greenroom;

document.addEventListener("DOMContentLoaded", function () {
  Greenroom.init();
});
