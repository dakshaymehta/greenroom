// Persona management module — handles message display and history
var Personas = (function () {
  var MAX_HISTORY = 50;
  var MAX_VISIBLE = 5;
  var IDLE_DELAY_MS = 3000;

  var history = {
    gary: [],
    fred: [],
    jackie: [],
    troll: [],
  };

  var idleTimers = {};
  var showConfidence = false;

  function setShowConfidence(show) {
    showConfidence = show;
  }

  function getShowConfidence() {
    return showConfidence;
  }

  function updatePersona(persona, data) {
    if (data === null || data === undefined) {
      SineWave.setState(persona, "idle");
      return;
    }

    SineWave.setState(persona, "active");

    var lane = document.querySelector(
      '.persona-lane[data-persona="' + persona + '"]',
    );
    if (!lane) return;

    var container = lane.querySelector(".persona-messages");
    if (!container) return;

    // Remove placeholder if present
    var placeholder = container.querySelector(".message-bubble.placeholder");
    if (placeholder) {
      container.removeChild(placeholder);
    }

    // Mark existing non-old bubbles as old
    var existingBubbles = container.querySelectorAll(
      ".message-bubble:not(.old)",
    );
    for (var i = 0; i < existingBubbles.length; i++) {
      existingBubbles[i].classList.add("old");
    }

    // Build the new message bubble using safe DOM methods
    var bubble = document.createElement("div");
    bubble.classList.add("message-bubble");

    // Fred with sound effect
    if (persona === "fred" && data.effect) {
      var sfxIndicator = document.createElement("span");
      sfxIndicator.classList.add("sfx-indicator");
      sfxIndicator.textContent = "\uD83D\uDD0A " + data.effect;
      bubble.appendChild(sfxIndicator);

      if (data.context) {
        var contextNode = document.createElement("span");
        contextNode.textContent = " " + data.context;
        bubble.appendChild(contextNode);
      }
    } else if (data.text) {
      // Gary with optional confidence display
      if (
        persona === "gary" &&
        showConfidence &&
        typeof data.confidence === "number"
      ) {
        var confidencePercent = Math.round(data.confidence * 100);
        bubble.textContent = data.text + " (" + confidencePercent + "%)";
      } else {
        bubble.textContent = data.text;
      }
    }

    container.appendChild(bubble);

    // Store in history
    history[persona].push({
      data: data,
      timestamp: Date.now(),
    });

    // Trim history to max
    if (history[persona].length > MAX_HISTORY) {
      history[persona] = history[persona].slice(-MAX_HISTORY);
    }

    // Trim visible bubbles (only when not expanded)
    var isExpanded = lane.classList.contains("expanded");
    if (!isExpanded) {
      trimVisibleBubbles(container);
    }

    // Auto-scroll if expanded
    if (isExpanded) {
      container.scrollTop = container.scrollHeight;
    }

    // Reset sine wave to idle after delay
    clearIdleTimer(persona);
    idleTimers[persona] = setTimeout(function () {
      SineWave.setState(persona, "idle");
    }, IDLE_DELAY_MS);
  }

  function trimVisibleBubbles(container) {
    var bubbles = container.querySelectorAll(".message-bubble");
    while (bubbles.length > MAX_VISIBLE) {
      container.removeChild(bubbles[0]);
      bubbles = container.querySelectorAll(".message-bubble");
    }
  }

  function clearIdleTimer(persona) {
    if (idleTimers[persona]) {
      clearTimeout(idleTimers[persona]);
      idleTimers[persona] = null;
    }
  }

  function setThinking(persona) {
    SineWave.setState(persona, "thinking");
  }

  function setAllThinking() {
    var personas = ["gary", "fred", "jackie", "troll"];
    for (var i = 0; i < personas.length; i++) {
      setThinking(personas[i]);
    }
  }

  function initClickToExpand() {
    var headers = document.querySelectorAll(".persona-header");
    for (var i = 0; i < headers.length; i++) {
      headers[i].addEventListener("click", handleHeaderClick);
    }
  }

  function handleHeaderClick(event) {
    // Don't toggle if clicking mute button
    if (event.target.closest(".mute-toggle")) return;

    var lane = event.currentTarget.closest(".persona-lane");
    if (!lane) return;

    var persona = lane.getAttribute("data-persona");
    var isExpanding = !lane.classList.contains("expanded");

    lane.classList.toggle("expanded");

    if (isExpanding && persona && history[persona].length > 0) {
      // Rebuild full history in the container
      rebuildHistory(lane, persona);
    } else if (!isExpanding) {
      // Collapse: trim back to recent
      var container = lane.querySelector(".persona-messages");
      if (container) {
        trimVisibleBubbles(container);
      }
    }
  }

  function rebuildHistory(lane, persona) {
    var container = lane.querySelector(".persona-messages");
    if (!container) return;

    // Clear current contents
    while (container.firstChild) {
      container.removeChild(container.firstChild);
    }

    // Rebuild from history
    var entries = history[persona];
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i];
      var data = entry.data;
      var isLatest = i === entries.length - 1;

      var bubble = document.createElement("div");
      bubble.classList.add("message-bubble");
      if (!isLatest) {
        bubble.classList.add("old");
      }

      if (persona === "fred" && data.effect) {
        var sfxIndicator = document.createElement("span");
        sfxIndicator.classList.add("sfx-indicator");
        sfxIndicator.textContent = "\uD83D\uDD0A " + data.effect;
        bubble.appendChild(sfxIndicator);

        if (data.context) {
          var contextNode = document.createElement("span");
          contextNode.textContent = " " + data.context;
          bubble.appendChild(contextNode);
        }
      } else if (data.text) {
        if (
          persona === "gary" &&
          showConfidence &&
          typeof data.confidence === "number"
        ) {
          var confidencePercent = Math.round(data.confidence * 100);
          bubble.textContent = data.text + " (" + confidencePercent + "%)";
        } else {
          bubble.textContent = data.text;
        }
      }

      // Skip animation for rebuilt history items
      if (!isLatest) {
        bubble.style.animation = "none";
      }

      container.appendChild(bubble);
    }

    // Scroll to bottom
    container.scrollTop = container.scrollHeight;
  }

  return {
    updatePersona: updatePersona,
    setThinking: setThinking,
    setAllThinking: setAllThinking,
    initClickToExpand: initClickToExpand,
    setShowConfidence: setShowConfidence,
    getShowConfidence: getShowConfidence,
  };
})();
