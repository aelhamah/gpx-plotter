(function () {
  "use strict";

  var data = window.GPXNAV_PREVIEW;
  var still = document.getElementById("still");
  var video = document.getElementById("video");
  var caption = document.getElementById("caption");
  var args = document.getElementById("args");
  var meta = document.getElementById("meta");
  var banner = document.getElementById("banner");
  var groups = document.getElementById("groups");
  var walkthrough = document.getElementById("walkthrough");

  if (!data || !data.scenes || !data.scenes.length) {
    caption.textContent = "No scenes were captured.";
    return;
  }

  // "walkthrough" rather than a mangled id so that #walkthrough is a real
  // deep link: show() writes that hash and indexOf reads it back, and no scene
  // id collides with it.
  var VIDEO = { id: "walkthrough", group: "Walkthrough", label: "Walkthrough", file: null };
  var order = (data.video ? [VIDEO] : []).concat(data.scenes);
  var current = -1;

  // Captures are read at roughly phone-preview size, so the next frame is
  // almost always wanted before it is. Two deep is where it stops paying.
  var warmed = {};

  function preload(index) {
    var scene = order[index];
    if (!scene || !scene.file || warmed[scene.file]) return;
    warmed[scene.file] = true;
    var img = new Image();
    img.src = scene.file;
  }

  function show(index) {
    if (index < 0 || index >= order.length) return;
    current = index;
    var scene = order[index];

    if (scene.file) {
      video.pause();
      video.hidden = true;
      still.hidden = false;
      still.src = scene.file;
      still.alt = scene.label;
      caption.textContent = scene.label;
      args.textContent = scene.args || "";
    } else {
      still.hidden = true;
      video.hidden = false;
      if (video.dataset.src !== data.video) {
        video.dataset.src = data.video;
        video.src = data.video;
      }
      video.play().catch(function () {});
      caption.textContent = "Walkthrough";
      args.textContent = "recordVideo over the main flow";
    }

    Array.prototype.forEach.call(document.querySelectorAll(".scene"), function (el) {
      el.setAttribute("aria-current", el.dataset.index === String(index) ? "true" : "false");
    });

    preload(index + 1);
    preload(index + 2);

    var id = scene.file ? scene.id : "walkthrough";
    if (window.location.hash !== "#" + id) {
      history.replaceState(null, "", "#" + id);
    }
  }

  function build() {
    if (data.video) {
      walkthrough.hidden = false;
      walkthrough.dataset.index = "0";
    }

    var lastGroup = null;
    order.forEach(function (scene, index) {
      if (scene === VIDEO) return;

      if (scene.group !== lastGroup) {
        lastGroup = scene.group;
        var heading = document.createElement("div");
        heading.className = "group__title";
        heading.textContent = scene.group;
        groups.appendChild(heading);
      }

      var button = document.createElement("button");
      button.className = "scene";
      button.type = "button";
      button.dataset.index = String(index);

      var label = document.createElement("span");
      label.className = "scene__label";
      label.textContent = scene.label;
      button.appendChild(label);

      if (scene.args) {
        var hint = document.createElement("span");
        hint.className = "scene__hint";
        hint.textContent = scene.args;
        button.appendChild(hint);
      }

      button.addEventListener("click", function () { show(index); });
      groups.appendChild(button);
    });
  }

  function renderMeta() {
    [
      ["Branch", data.branch],
      ["Commit", data.commit],
      ["Device", data.device],
      ["iOS", data.runtime],
      ["Xcode", data.xcode],
      ["Captured", data.capturedAt]
    ].forEach(function (pair) {
      if (!pair[1]) return;
      var span = document.createElement("span");
      var key = document.createElement("b");
      key.textContent = pair[0] + " ";
      span.appendChild(key);
      span.appendChild(document.createTextNode(pair[1]));
      meta.appendChild(span);
    });

    if (data.demoTiles) {
      var note = document.createElement("div");
      note.className = "banner";
      note.textContent =
        "Captured without a MapTiler key, so the map is MapLibre's keyless demo " +
        "basemap: tiles only go to zoom 6 and the app disables its terrain " +
        "overlays. The relief, slope and 3D scenes show that explanation, not a " +
        "rendering fault.";
      banner.appendChild(note);
    }
  }

  function step(delta) {
    show((current + delta + order.length) % order.length);
  }

  // Index of the first still, which is where the `w` key returns to.
  function firstScene() {
    return data.video ? 1 : 0;
  }

  function indexOf(id) {
    for (var i = 0; i < order.length; i++) {
      if (order[i].id === id) return i;
    }
    return -1;
  }

  document.addEventListener("keydown", function (event) {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.key === "ArrowRight" || event.key === "ArrowDown") { step(1); event.preventDefault(); }
    else if (event.key === "ArrowLeft" || event.key === "ArrowUp") { step(-1); event.preventDefault(); }
    else if (event.key === "w" || event.key === "W") {
      if (!data.video) return;
      show(current === 0 ? firstScene() : 0);
    }
  });

  walkthrough.addEventListener("click", function () { show(0); });

  renderMeta();
  build();

  var requested = indexOf(window.location.hash.replace("#", ""));
  show(requested === -1 ? firstScene() : requested);
})();