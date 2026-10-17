// 그림 블록의 공통 부품 (부품 판 1). 블록 틀이 그림 코드보다 먼저 넣는다.
// - 오류를 알린다: 러너 검사(webkit.messageHandlers.figure)와 학습 페이지(parent.postMessage)
// - 내용 높이를 학습 페이지에 알려 iframe 높이를 맞춘다
// - window.JD: 테마 색, 움직임 줄이기, 수식, 슬라이더
// 하위 호환을 지킨다. 깨지는 변경이면 부품 판을 올린다 (docs/PAGES.md 의 공통 부품 판).
(function () {
  "use strict";

  function report(message) {
    try { window.webkit.messageHandlers.figure.postMessage(message); } catch (e) { /* 학습 페이지 안에서는 없다 */ }
    try { if (window.parent !== window) window.parent.postMessage(Object.assign({ jindesk: "figure" }, message), "*"); } catch (e) { /* 무시 */ }
  }

  window.addEventListener("error", function (e) {
    var where = e.filename ? " (" + e.filename.replace(/^.*\//, "") + ":" + e.lineno + ")" : "";
    report({ type: "error", message: String(e.message || e.error || "script error") + where });
  });
  window.addEventListener("unhandledrejection", function (e) {
    var r = e.reason;
    report({ type: "error", message: "unhandled rejection: " + String(r && r.message ? r.message : r) });
  });
  var consoleError = console.error;
  console.error = function () {
    report({ type: "error", message: "console.error: " + Array.prototype.map.call(arguments, String).join(" ") });
    return consoleError.apply(console, arguments);
  };

  function sendHeight() {
    var root = document.getElementById("figure") || document.body;
    report({ type: "height", h: Math.ceil(root.getBoundingClientRect().height) + 2 });
  }

  var css = function (name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); };

  window.JD = {
    parts: 1,
    // 테마 색 (밝은 화면과 어두운 화면에 따라 바뀐다)
    color: function (name) { return css("--" + name); },
    colors: function () {
      return {
        ink: css("--ink"), ink2: css("--ink-2"), ink3: css("--ink-3"), line: css("--line"), paper: css("--paper"), paper2: css("--paper-2"),
        accent: css("--accent"), good: css("--good"), bad: css("--bad"),
        series: [css("--s1"), css("--s2"), css("--s3"), css("--s4"), css("--s5"), css("--s6")],
      };
    },
    // 움직임 줄이기 설정이면 움직임을 멈추고 마지막 장면을 보인다
    get reducedMotion() { return window.matchMedia("(prefers-reduced-motion: reduce)").matches; },
    // 요소 안의 \( … \), \[ … \] 를 KaTeX 로 그린다. tex 를 주면 그 수식을 요소에 그린다.
    math: function (el, tex, display) {
      if (tex != null) { katex.render(tex, el, { displayMode: !!display, throwOnError: false }); return el; }
      el.innerHTML = el.innerHTML.replace(/\\\(([\s\S]*?)\\\)|\\\[([\s\S]*?)\\\]/g, function (_, a, b) {
        return katex.renderToString(a != null ? a : b, { displayMode: b != null, throwOnError: false });
      });
      return el;
    },
    // 슬라이더 하나: JD.slider(부모, { label, min, max, step, value, unit, format, oninput }) → input
    slider: function (parent, o) {
      var wrap = document.createElement("div");
      wrap.className = "jd-slider";
      var label = document.createElement("label");
      var name = document.createElement("span");
      name.textContent = o.label || "";
      var out = document.createElement("output");
      var input = document.createElement("input");
      input.type = "range";
      input.min = o.min; input.max = o.max; input.step = o.step || "any"; input.value = o.value;
      var show = function () {
        var v = Number(input.value);
        out.textContent = (o.format ? o.format(v) : String(v)) + (o.unit ? " " + o.unit : "");
      };
      input.addEventListener("input", function () { show(); if (o.oninput) o.oninput(Number(input.value)); });
      show();
      label.appendChild(name);
      label.appendChild(out);
      wrap.appendChild(label);
      wrap.appendChild(input);
      parent.appendChild(wrap);
      return input;
    },
    // 크기가 바뀔 때 부른다 (그림을 다시 그릴 때)
    onResize: function (fn) {
      var timer = null;
      new ResizeObserver(function () { clearTimeout(timer); timer = setTimeout(fn, 60); }).observe(document.getElementById("figure") || document.body);
    },
  };

  document.addEventListener("DOMContentLoaded", function () {
    var root = document.getElementById("figure") || document.body;
    new ResizeObserver(sendHeight).observe(root);
    sendHeight();
    report({ type: "ready" });
  });
  window.addEventListener("load", sendHeight);
})();
