var Personas = (function () {
  var MAX_HISTORY = 50;
  var MAX_VISIBLE = 1;
  var IDLE_DELAY_MS = 3600;

  var history = {
    gary: [],
    fred: [],
    jackie: [],
    troll: [],
  };

  var idleTimers = {};
  var showConfidence = false;

  var PERSONA_COPY = {
    gary: {
      descriptor: "Checks claims against live sources.",
      idleBadge: "Ready",
      idleDetail: "Checks claims against live sources.",
      idleSignal: "Waiting to verify",
      thinkingBadge: "Checking",
      thinkingDetail: "Verifies checkable claims and keeps the sources close.",
      thinkingSignal: "Scanning for a factual cue",
      placeholder: "No factual claim worth checking yet.",
    },
    fred: {
      descriptor: "Tracks timing, tone, and cue-worthy shifts.",
      idleBadge: "Ready",
      idleDetail: "Tracks timing, tone, and cue-worthy shifts.",
      idleSignal: "Watching the beat",
      thinkingBadge: "Timing",
      thinkingDetail: "Tracks tone, timing, and cue-worthy shifts in the room.",
      thinkingSignal: "Timing the moment",
      placeholder: "No cue worth scoring yet.",
    },
    jackie: {
      descriptor: "Finds setups worth sharpening.",
      idleBadge: "Ready",
      idleDetail: "Finds setups worth sharpening.",
      idleSignal: "No clean punchline yet",
      thinkingBadge: "Writing",
      thinkingDetail: "Looks for setups that can turn into something sharper.",
      thinkingSignal: "Building a line",
      placeholder: "No punchline worth keeping yet.",
    },
    troll: {
      descriptor: "Pressure-tests weak logic.",
      idleBadge: "Ready",
      idleDetail: "Pressure-tests weak logic.",
      idleSignal: "No pressure point yet",
      thinkingBadge: "Circling",
      thinkingDetail: "Pushes on weak assumptions and sloppy logic.",
      thinkingSignal: "Testing the argument",
      placeholder: "No weak spot worth pressing yet.",
    },
  };

  function initClickToExpand() {
    var headers = document.querySelectorAll(".persona-header");
    for (var i = 0; i < headers.length; i++) {
      headers[i].addEventListener("click", handleHeaderClick);
    }

    var personas = Object.keys(PERSONA_COPY);
    for (var j = 0; j < personas.length; j++) {
      syncLaneState(personas[j], "idle", null);
      syncLaneOccupancy(personas[j]);
      ensurePlaceholder(personas[j]);
    }
  }

  function setShowConfidence(show) {
    showConfidence = !!show;
  }

  function updatePersona(persona, data) {
    var lane = getLane(persona);
    if (!lane) return;

    if (data === null || data === undefined) {
      clearIdleTimer(persona);
      syncLaneState(persona, "idle", getLatestData(persona));
      syncLaneOccupancy(persona);
      ensurePlaceholder(persona);
      return;
    }

    history[persona].push({
      data: data,
      timestamp: Date.now(),
    });

    if (history[persona].length > MAX_HISTORY) {
      history[persona] = history[persona].slice(-MAX_HISTORY);
    }

    syncLaneOccupancy(persona);

    var container = getMessageContainer(persona);
    if (!container) return;

    removePlaceholder(container);

    if (lane.classList.contains("expanded")) {
      rebuildHistory(persona);
    } else {
      markVisibleMessagesOld(container);
      container.appendChild(buildMessageBubble(persona, data, false));
      trimVisibleBubbles(container);
    }

    syncLaneState(persona, "active", data);
    scheduleIdle(persona);
  }

  function setAllThinking() {
    var personas = Object.keys(PERSONA_COPY);
    for (var i = 0; i < personas.length; i++) {
      clearIdleTimer(personas[i]);
      syncLaneState(personas[i], "thinking", getLatestData(personas[i]));
    }
  }

  function handleHeaderClick(event) {
    if (event.target.closest(".mute-toggle")) return;

    var lane = event.currentTarget.closest(".persona-lane");
    if (!lane) return;

    var persona = lane.getAttribute("data-persona");
    var shouldExpand = !lane.classList.contains("expanded");

    collapseAllLanesExcept(shouldExpand ? lane : null);

    if (shouldExpand) {
      lane.classList.add("expanded");
      rebuildHistory(persona);
    } else {
      lane.classList.remove("expanded");
      var container = getMessageContainer(persona);
      if (container) {
        trimVisibleBubbles(container);
        ensurePlaceholder(persona);
      }
    }

    document.body.classList.toggle(
      "has-expanded-lane",
      !!document.querySelector(".persona-lane.expanded"),
    );
  }

  function collapseAllLanesExcept(activeLane) {
    var lanes = document.querySelectorAll(".persona-lane");
    for (var i = 0; i < lanes.length; i++) {
      var lane = lanes[i];
      if (lane === activeLane) continue;

      lane.classList.remove("expanded");
      var persona = lane.getAttribute("data-persona");
      var container = getMessageContainer(persona);
      if (container) {
        trimVisibleBubbles(container);
        ensurePlaceholder(persona);
      }
    }
  }

  function rebuildHistory(persona) {
    var container = getMessageContainer(persona);
    if (!container) return;

    while (container.firstChild) {
      container.removeChild(container.firstChild);
    }

    var entries = history[persona];
    if (!entries.length) {
      syncLaneOccupancy(persona);
      ensurePlaceholder(persona);
      return;
    }

    for (var i = 0; i < entries.length; i++) {
      var isHistorical = i !== entries.length - 1;
      container.appendChild(buildMessageBubble(persona, entries[i].data, isHistorical));
    }

    container.scrollTop = container.scrollHeight;
  }

  function trimVisibleBubbles(container) {
    var bubbles = container.querySelectorAll(".message-bubble");
    while (bubbles.length > MAX_VISIBLE) {
      container.removeChild(bubbles[0]);
      bubbles = container.querySelectorAll(".message-bubble");
    }
  }

  function ensurePlaceholder(persona) {
    if (history[persona].length > 0) return;

    var container = getMessageContainer(persona);
    if (!container) return;

    var existingPlaceholder = container.querySelector(".message-bubble.placeholder");
    if (existingPlaceholder) return;

    var placeholder = document.createElement("div");
    placeholder.className = "message-bubble placeholder";
    placeholder.textContent = PERSONA_COPY[persona].placeholder;
    container.appendChild(placeholder);
  }

  function removePlaceholder(container) {
    var placeholder = container.querySelector(".message-bubble.placeholder");
    if (placeholder) {
      container.removeChild(placeholder);
    }
  }

  function markVisibleMessagesOld(container) {
    var activeBubbles = container.querySelectorAll(".message-bubble:not(.old):not(.placeholder)");
    for (var i = 0; i < activeBubbles.length; i++) {
      activeBubbles[i].classList.add("old");
    }
  }

  function syncLaneState(persona, state, data) {
    var lane = getLane(persona);
    if (!lane) return;

    lane.classList.remove("state-idle", "state-thinking", "state-active");
    lane.classList.add("state-" + state);

    var badge = lane.querySelector(".persona-state-badge");
    var detail = lane.querySelector(".persona-state-detail");
    var signal = lane.querySelector(".persona-signal-label");
    var count = lane.querySelector(".persona-response-count");

    var copy = resolveCopy(persona, state, data);

    if (badge) badge.textContent = copy.badge;
    if (detail) detail.textContent = copy.detail;
    if (signal) signal.textContent = copy.signal;
    if (count) count.textContent = padCount(history[persona].length);
  }

  function syncLaneOccupancy(persona) {
    var lane = getLane(persona);
    if (!lane) return;

    var hasResponse = history[persona].length > 0;
    lane.classList.toggle("has-response", hasResponse);
    lane.classList.toggle("is-empty", !hasResponse);
  }

  function resolveCopy(persona, state, data) {
    var defaults = PERSONA_COPY[persona];
    var latest = getLatestData(persona);

    if (state === "thinking") {
      return {
        badge: defaults.thinkingBadge,
        detail: defaults.descriptor,
        signal: defaults.thinkingSignal,
      };
    }

    if (state === "active" && data) {
      return {
        badge: activeBadge(persona, data),
        detail: defaults.descriptor,
        signal: activeSignal(persona, data),
      };
    }

    return {
      badge: defaults.idleBadge,
      detail: defaults.descriptor,
      signal: latest ? "Last: " + activeSignal(persona, latest) : defaults.idleSignal,
    };
  }

  function activeBadge(persona, data) {
    if (persona === "gary") {
      if (data.verdict) return humanizeVerdict(data.verdict);
      if (Array.isArray(data.sources) && data.sources.length) return "Sourced";
      if (data.searchQuery) return "Checking";
      return "Watching";
    }

    if (persona === "fred") return "Cue ready";
    if (persona === "jackie") return "Riff ready";
    return "Pushback";
  }

  function activeDetail(persona, data) {
    var quote = formatQuotedTrigger(data && data.trigger, 40);

    if (persona === "gary") {
      if (Array.isArray(data.sources) && data.sources.length) {
        return "Checked " + quote + " against live reporting";
      }
      if (data.searchQuery) {
        return "Running a live check on " + quote;
      }
      return "Watching " + quote;
    }

    if (persona === "fred") return "Timed for " + quote;
    if (persona === "jackie") return "Built from " + quote;
    return "Pressing on " + quote;
  }

  function activeSignal(persona, data) {
    if (persona === "gary") {
      var verdict = humanizeVerdict(data && data.verdict);

      if (data && data.sourceNote) return data.sourceNote;
      if (data && Array.isArray(data.sources) && data.sources.length) {
        return (
          data.sources.length +
          " linked source" +
          (data.sources.length === 1 ? "" : "s")
        );
      }
      if (verdict) return verdict;
      if (data && data.searchQuery) return "Searching for independent confirmation";
      if (data && typeof data.confidence === "number") {
        return Math.round(data.confidence * 100) + "% confidence";
      }
      return "No solid source yet";
    }

    if (persona === "fred") {
      return data && data.effect ? "Cue: " + humanizeText(data.effect) : "Cue selected";
    }

    if (persona === "jackie") return "Found a punchline";
    return "Found a pressure point";
  }

  function buildMessageBubble(persona, data, isHistorical) {
    var bubble = document.createElement("div");
    bubble.className = "message-bubble";
    if (isHistorical) {
      bubble.classList.add("old");
    }

    var metaItems = buildMetaItems(persona, data);
    if (metaItems.length) {
      var metaRow = document.createElement("div");
      metaRow.className = "message-meta-row";
      for (var i = 0; i < metaItems.length; i++) {
        metaRow.appendChild(buildPill(metaItems[i]));
      }
      bubble.appendChild(metaRow);
    }

    if (data && data.trigger) {
      var reaction = document.createElement("div");
      reaction.className = "message-reaction";

      var reactionLabel = document.createElement("span");
      reactionLabel.className = "message-reaction-label";
      reactionLabel.textContent = persona === "gary" ? "Claim" : "Picked up";

      var reactionText = document.createElement("span");
      reactionText.className = "message-reaction-text";
      reactionText.textContent = formatQuotedTrigger(data.trigger, 78);

      reaction.appendChild(reactionLabel);
      reaction.appendChild(reactionText);
      bubble.appendChild(reaction);
    }

    var bodyText = buildBodyText(persona, data);
    if (bodyText) {
      var body = document.createElement("div");
      body.className = "message-body";
      body.textContent = bodyText;
      bubble.appendChild(body);
    }

    var secondaryText = buildSecondaryText(persona, data);
    if (secondaryText) {
      var secondary = document.createElement("div");
      secondary.className = "message-secondary";
      secondary.textContent = secondaryText;
      bubble.appendChild(secondary);
    }

    if (persona === "gary" && Array.isArray(data.sources) && data.sources.length) {
      bubble.appendChild(buildSourceList(data.sources));
    }

    return bubble;
  }

  function buildMetaItems(persona, data) {
    var items = [];

    if (persona === "gary") {
      if (data.verdict) {
        items.push({
          label: humanizeVerdict(data.verdict),
          className: "verdict-" + sanitizeToken(data.verdict),
        });
      }

      if (showConfidence && typeof data.confidence === "number") {
        items.push({
          label: Math.round(data.confidence * 100) + "% confidence",
          className: "confidence",
        });
      }

      if (Array.isArray(data.sources) && data.sources.length) {
        items.push({
          label: data.sources.length + " sources",
          className: "search",
        });
      } else if (data.searchQuery) {
        items.push({
          label: "Live check",
          className: "search",
        });
      }
    }

    if (persona === "fred" && data.effect) {
      items.push({
        label: humanizeText(data.effect),
        className: "effect",
      });
    }

    return items;
  }

  function buildPill(item) {
    var pill = document.createElement("span");
    pill.className = "message-pill";
    if (item.className) {
      pill.classList.add(item.className);
    }
    pill.textContent = item.label;
    return pill;
  }

  function buildBodyText(persona, data) {
    if (persona === "fred") {
      if (data.context) return data.context;
      if (data.effect) return "Fred queued " + humanizeText(data.effect) + " for this beat.";
      return "";
    }

    return data.text || "";
  }

  function buildSecondaryText(persona, data) {
    if (persona !== "gary") return "";

    if (data.sourceNote) {
      return data.sourceNote;
    }

    if (Array.isArray(data.sources) && data.sources.length) {
      return (
        data.sources.length +
        " linked source" +
        (data.sources.length === 1 ? "" : "s")
      );
    }

    if (data.searchQuery) {
      return "Checking this claim against live sources";
    }

    return "";
  }

  function buildSourceList(sources) {
    var list = document.createElement("div");
    list.className = "message-source-list";

    for (var i = 0; i < sources.length && i < 3; i++) {
      var source = sources[i];
      var chip = document.createElement("button");
      chip.type = "button";
      chip.className = "message-source-chip";
      chip.title = source.title + " — " + source.url;
      chip.setAttribute("aria-label", "Open source: " + source.title);
      chip.addEventListener("click", function (event) {
        var target = event.currentTarget;
        if (!target || !target.dataset || !target.dataset.url) return;
        postSidebarAction({
          action: "openSource",
          url: target.dataset.url,
        });
      });
      chip.dataset.url = source.url;

      var host = document.createElement("strong");
      host.textContent = source.host;

      var title = document.createElement("span");
      title.textContent = truncate(source.title, 34);

      chip.appendChild(host);
      chip.appendChild(title);
      list.appendChild(chip);
    }

    return list;
  }

  function scheduleIdle(persona) {
    clearIdleTimer(persona);
    idleTimers[persona] = window.setTimeout(function () {
      syncLaneState(persona, "idle", getLatestData(persona));
    }, IDLE_DELAY_MS);
  }

  function clearIdleTimer(persona) {
    if (idleTimers[persona]) {
      window.clearTimeout(idleTimers[persona]);
      idleTimers[persona] = null;
    }
  }

  function getLatestData(persona) {
    var entries = history[persona];
    if (!entries.length) return null;
    return entries[entries.length - 1].data;
  }

  function getLane(persona) {
    return document.querySelector('.persona-lane[data-persona="' + persona + '"]');
  }

  function getMessageContainer(persona) {
    var lane = getLane(persona);
    return lane ? lane.querySelector(".persona-messages") : null;
  }

  function postSidebarAction(message) {
    if (
      window.greenroom &&
      typeof window.greenroom.postAction === "function"
    ) {
      window.greenroom.postAction(message);
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
        return humanizeText(verdict || "");
    }
  }

  function humanizeText(text) {
    if (!text) return "";

    var words = String(text).replace(/[_-]+/g, " ").split(" ");
    for (var i = 0; i < words.length; i++) {
      if (!words[i]) continue;
      words[i] = words[i].charAt(0).toUpperCase() + words[i].slice(1);
    }
    return words.join(" ");
  }

  function sanitizeToken(value) {
    return String(value || "")
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "");
  }

  function formatQuotedTrigger(text, maxLength) {
    if (!text) return "\u201cthe latest moment\u201d";
    return "\u201c" + truncate(String(text), maxLength) + "\u201d";
  }

  function truncate(text, maxLength) {
    if (!text || text.length <= maxLength) return text || "";
    return text.slice(0, maxLength - 1) + "\u2026";
  }

  function padCount(value) {
    var number = Math.max(0, value || 0);
    return number < 10 ? "0" + number : String(number);
  }

  return {
    initClickToExpand: initClickToExpand,
    updatePersona: updatePersona,
    setAllThinking: setAllThinking,
    setShowConfidence: setShowConfidence,
  };
})();
