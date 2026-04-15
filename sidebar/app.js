// Main application module — coordinates sidebar state and native bridge
var Greenroom = (function () {
  var isPaused = false;

  function init() {
    SineWave.init();
    Personas.initClickToExpand();
    setupControls();
  }

  function setupControls() {
    // Fred mute toggle
    var muteButton = document.getElementById("fred-mute");
    if (muteButton) {
      muteButton.addEventListener("click", function (event) {
        event.stopPropagation();
        muteButton.classList.toggle("muted");
        var isMuted = muteButton.classList.contains("muted");
        postToNative({ action: "toggleFredMute", muted: isMuted });
      });
    }

    // Pause toggle
    var pauseButton = document.getElementById("btn-pause");
    if (pauseButton) {
      pauseButton.addEventListener("click", function () {
        isPaused = !isPaused;
        pauseButton.classList.toggle("active", isPaused);
        pauseButton.textContent = isPaused ? "\u25B6" : "\u23F8";
        postToNative({ action: "togglePause", paused: isPaused });
      });
    }

    // Settings
    var settingsButton = document.getElementById("btn-settings");
    if (settingsButton) {
      settingsButton.addEventListener("click", function () {
        postToNative({ action: "openSettings" });
      });
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
    for (var i = 0; i < personas.length; i++) {
      var persona = personas[i];
      var data = responses.hasOwnProperty(persona) ? responses[persona] : null;
      Personas.updatePersona(persona, data);
    }
  }

  function onTickStart() {
    if (!isPaused) {
      Personas.setAllThinking();
    }
  }

  function setLiveStatus(live) {
    var indicator = document.getElementById("live-indicator");
    if (!indicator) return;

    var dot = indicator.querySelector(".status-dot");
    var label = indicator.querySelector(".status-label");

    indicator.classList.remove("live", "error");

    if (live) {
      indicator.classList.add("live");
      if (label) label.textContent = "LIVE";
    } else {
      if (label) label.textContent = "OFFLINE";
    }
  }

  function setErrorStatus(message) {
    var indicator = document.getElementById("live-indicator");
    if (!indicator) return;

    var label = indicator.querySelector(".status-label");

    indicator.classList.remove("live");
    indicator.classList.add("error");

    if (label) label.textContent = message || "ERROR";
  }

  function setShowConfidence(show) {
    Personas.setShowConfidence(show);
  }

  // Update the transcript strip with the latest heard text.
  // Uses a fade transition so the host sees smooth text changes.
  function onTranscriptUpdate(text) {
    var el = document.getElementById("transcript-text");
    if (!el) return;

    // Truncate to ~200 chars for compact display
    var display = typeof text === "string" ? text : "";
    if (display.length > 200) {
      display = display.substring(0, 200) + "\u2026";
    }

    // Fade out, swap text, fade back in
    el.classList.add("fading");
    setTimeout(function () {
      el.textContent = display || "Waiting for audio...";
      el.classList.remove("fading");
    }, 150);
  }

  return {
    init: init,
    onPersonaUpdate: onPersonaUpdate,
    onTickStart: onTickStart,
    onTranscriptUpdate: onTranscriptUpdate,
    setLiveStatus: setLiveStatus,
    setErrorStatus: setErrorStatus,
    setShowConfidence: setShowConfidence,
  };
})();

// Expose globally for native bridge calls
window.greenroom = Greenroom;

// Initialize on DOM ready
document.addEventListener("DOMContentLoaded", function () {
  Greenroom.init();
});
