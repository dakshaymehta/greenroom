// Sine wave animation module for persona activity indicators
var SineWave = (function () {
  var canvases = {};
  var states = {};
  var animationId = null;

  var ACCENT_COLORS = {
    gary: "#4A9EFF",
    fred: "#4ADE80",
    jackie: "#FBBF24",
    troll: "#F87171",
  };

  var IDLE_COLOR = "#333";

  function init() {
    var elements = document.querySelectorAll(".sine-wave");
    for (var i = 0; i < elements.length; i++) {
      var canvas = elements[i];
      var persona = canvas.getAttribute("data-persona");
      if (persona) {
        canvases[persona] = canvas;
        states[persona] = "idle";
        sizeCanvas(canvas);
      }
    }

    window.addEventListener("resize", handleResize);
    animationId = requestAnimationFrame(draw);
  }

  function sizeCanvas(canvas) {
    var dpr = window.devicePixelRatio || 1;
    var rect = canvas.getBoundingClientRect();
    canvas.width = rect.width * dpr;
    canvas.height = rect.height * dpr;
    var ctx = canvas.getContext("2d");
    ctx.scale(dpr, dpr);
  }

  function handleResize() {
    var personas = Object.keys(canvases);
    for (var i = 0; i < personas.length; i++) {
      sizeCanvas(canvases[personas[i]]);
    }
  }

  function setState(persona, state) {
    if (states.hasOwnProperty(persona)) {
      states[persona] = state;
    }
  }

  function draw(timestamp) {
    var personas = Object.keys(canvases);
    for (var i = 0; i < personas.length; i++) {
      var persona = personas[i];
      var canvas = canvases[persona];
      var ctx = canvas.getContext("2d");
      var rect = canvas.getBoundingClientRect();
      var width = rect.width;
      var height = rect.height;
      var state = states[persona];

      ctx.clearRect(0, 0, width, height);

      if (state === "idle") {
        drawIdleLine(ctx, width, height);
      } else if (state === "active") {
        drawSineWave(
          ctx,
          width,
          height,
          timestamp,
          ACCENT_COLORS[persona],
          0.35,
          0.04,
          0.002,
        );
      } else if (state === "thinking") {
        drawSineWave(
          ctx,
          width,
          height,
          timestamp,
          ACCENT_COLORS[persona],
          0.15,
          0.06,
          0.004,
        );
      }
    }

    animationId = requestAnimationFrame(draw);
  }

  function drawIdleLine(ctx, width, height) {
    var midY = height / 2;
    ctx.beginPath();
    ctx.moveTo(0, midY);
    ctx.lineTo(width, midY);
    ctx.strokeStyle = IDLE_COLOR;
    ctx.lineWidth = 1;
    ctx.stroke();
  }

  function drawSineWave(
    ctx,
    width,
    height,
    timestamp,
    color,
    amplitudeRatio,
    frequency,
    speed,
  ) {
    var midY = height / 2;
    var amplitude = height * amplitudeRatio;
    var phase = timestamp * speed;

    ctx.beginPath();
    ctx.moveTo(0, midY);

    for (var x = 0; x <= width; x++) {
      var y = midY + Math.sin(x * frequency + phase) * amplitude;
      ctx.lineTo(x, y);
    }

    ctx.strokeStyle = color;
    ctx.lineWidth = 1.5;
    ctx.stroke();
  }

  return {
    init: init,
    setState: setState,
  };
})();
