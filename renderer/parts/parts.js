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
    // 좌표 평면 (SVG): JD.graph(부모, { x: [아래, 위], y: [아래, 위], height, xLabel, yLabel, grid })
    // g.draw(함수) 안에서 g.fn, g.point, g.hline, g.vline, g.segment, g.text, g.area 로 그린다.
    // 너비가 바뀌거나 밝은·어두운 화면이 바뀌면 그 함수를 다시 부른다.
    graph: function (parent, o) { return makeGraph(parent, o || {}); },
    // 재생 조작: JD.player(부모, { duration: 초, onFrame: function (t) { … } }) — t 는 0 에서 1. 움직임 줄이기면 마지막 장면만 보인다.
    player: function (parent, o) { return makePlayer(parent, o || {}); },
    // 크기가 바뀔 때 부른다 (그림을 다시 그릴 때)
    onResize: function (fn) {
      var timer = null;
      new ResizeObserver(function () { clearTimeout(timer); timer = setTimeout(fn, 60); }).observe(document.getElementById("figure") || document.body);
    },
  };

  var SVG = "http://www.w3.org/2000/svg";
  function svgEl(name, attrs, parent) {
    var e = document.createElementNS(SVG, name);
    for (var k in attrs) if (attrs[k] != null) e.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(e);
    return e;
  }

  // 보기 좋은 눈금 간격 (1, 2, 5 × 10^n)
  function niceStep(span, count) {
    var raw = span / Math.max(count, 1);
    var p = Math.pow(10, Math.floor(Math.log10(raw)));
    var f = raw / p;
    return (f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10) * p;
  }

  function fmt(v) {
    var r = Math.round(v * 1e6) / 1e6;
    return String(r).replace("-", "\u2212");
  }

  function makeGraph(parent, o) {
    var xr = o.x || [-5, 5], yr = o.y || [-5, 5];
    var height = o.height || 300;
    var m = { l: 44, r: 16, t: 14, b: 32 };
    var wrap = document.createElement("div");
    wrap.className = "jd-graph";
    parent.appendChild(wrap);
    var svg = svgEl("svg", { height: height, role: "img" }, wrap);
    var layer, width = 0, drawer = null;
    var g = {
      svg: svg,
      x: function (v) { return m.l + (v - xr[0]) / (xr[1] - xr[0]) * (width - m.l - m.r); },
      y: function (v) { return height - m.b - (v - yr[0]) / (yr[1] - yr[0]) * (height - m.t - m.b); },
      // 화면 좌표를 그래프 값으로 (끌기 조작에 쓴다)
      fromX: function (px) { return xr[0] + (px - m.l) / (width - m.l - m.r) * (xr[1] - xr[0]); },
      fromY: function (py) { return yr[0] + (height - m.b - py) / (height - m.t - m.b) * (yr[1] - yr[0]); },
      setRange: function (x, y) { if (x) xr = x; if (y) yr = y; g.redraw(); },
      fn: function (f, s) {
        s = s || {};
        var n = Math.max(200, Math.round(width)), d = "", pen = false;
        var lo = s.from != null ? s.from : xr[0], hi = s.to != null ? s.to : xr[1];
        for (var i = 0; i <= n; i++) {
          var xv = lo + (hi - lo) * i / n, yv = f(xv);
          if (!isFinite(yv) || yv < yr[0] - (yr[1] - yr[0]) || yv > yr[1] + (yr[1] - yr[0])) { pen = false; continue; }
          d += (pen ? "L" : "M") + g.x(xv).toFixed(2) + " " + g.y(yv).toFixed(2);
          pen = true;
        }
        var path = svgEl("path", { d: d, fill: "none", stroke: s.color || JD.color("s1"), "stroke-width": s.width || 2.2, "stroke-dasharray": s.dash ? "6 5" : null, "clip-path": "url(#jd-clip)" }, layer);
        if (s.label) {
          var lx = s.labelAt != null ? s.labelAt : lo + (hi - lo) * 0.85;
          g.text(lx, f(lx), s.label, { color: s.color || JD.color("s1"), dx: 6, dy: -6 });
        }
        return path;
      },
      point: function (xv, yv, s) {
        s = s || {};
        var c = svgEl("circle", { cx: g.x(xv), cy: g.y(yv), r: s.r || 5, fill: s.color || JD.color("accent"), stroke: JD.color("paper"), "stroke-width": 2 }, layer);
        if (s.label) g.text(xv, yv, s.label, { color: s.labelColor || JD.color("ink"), dx: 8, dy: -8, weight: 600 });
        return c;
      },
      hline: function (yv, s) { s = s || {}; return g.segment(xr[0], yv, xr[1], yv, s); },
      vline: function (xv, s) { s = s || {}; return g.segment(xv, yr[0], xv, yr[1], s); },
      segment: function (x1, y1, x2, y2, s) {
        s = s || {};
        var l = svgEl("line", { x1: g.x(x1), y1: g.y(y1), x2: g.x(x2), y2: g.y(y2), stroke: s.color || JD.color("ink-2"), "stroke-width": s.width || 1.5, "stroke-dasharray": s.dash ? "5 4" : null, "clip-path": "url(#jd-clip)" }, layer);
        if (s.label) g.text(x2, y2, s.label, { color: s.color, dx: 6, dy: -4 });
        return l;
      },
      area: function (f, a, b, s) {
        s = s || {};
        var d = "M" + g.x(a) + " " + g.y(0), n = 120;
        for (var i = 0; i <= n; i++) { var xv = a + (b - a) * i / n; d += "L" + g.x(xv) + " " + g.y(f(xv)); }
        d += "L" + g.x(b) + " " + g.y(0) + "Z";
        return svgEl("path", { d: d, fill: s.color || JD.color("accent"), "fill-opacity": s.opacity || 0.18, stroke: "none", "clip-path": "url(#jd-clip)" }, layer);
      },
      text: function (xv, yv, str, s) {
        s = s || {};
        var t = svgEl("text", { x: g.x(xv) + (s.dx || 0), y: g.y(yv) + (s.dy || 0), fill: s.color || JD.color("ink"), "font-size": s.size || 13, "font-weight": s.weight || 400, "text-anchor": s.anchor || "start" }, layer);
        t.textContent = str;
        return t;
      },
      draw: function (fn) { drawer = fn; g.redraw(); },
      redraw: function () {
        width = wrap.clientWidth || 600;
        svg.setAttribute("width", width);
        svg.setAttribute("viewBox", "0 0 " + width + " " + height);
        while (svg.firstChild) svg.removeChild(svg.firstChild);
        var defs = svgEl("defs", {}, svg);
        var clip = svgEl("clipPath", { id: "jd-clip" }, defs);
        svgEl("rect", { x: m.l, y: m.t, width: Math.max(0, width - m.l - m.r), height: height - m.t - m.b }, clip);
        axes();
        layer = svgEl("g", {}, svg);
        if (drawer) drawer(g);
      },
    };
    function axes() {
      var ax = svgEl("g", { "font-size": 12, fill: JD.color("ink-2") }, svg);
      var sx = niceStep(xr[1] - xr[0], Math.max(4, Math.floor(width / 70))), sy = niceStep(yr[1] - yr[0], 6);
      for (var v = Math.ceil(xr[0] / sx) * sx; v <= xr[1] + 1e-9; v += sx) {
        if (o.grid !== false) svgEl("line", { x1: g.x(v), x2: g.x(v), y1: m.t, y2: height - m.b, stroke: JD.color("line-2"), "stroke-width": 1 }, ax);
        var tx = svgEl("text", { x: g.x(v), y: height - m.b + 18, "text-anchor": "middle" }, ax);
        tx.textContent = fmt(v);
      }
      for (var w = Math.ceil(yr[0] / sy) * sy; w <= yr[1] + 1e-9; w += sy) {
        if (o.grid !== false) svgEl("line", { x1: m.l, x2: width - m.r, y1: g.y(w), y2: g.y(w), stroke: JD.color("line-2"), "stroke-width": 1 }, ax);
        var ty = svgEl("text", { x: m.l - 6, y: g.y(w) + 4, "text-anchor": "end" }, ax);
        ty.textContent = fmt(w);
      }
      var x0 = Math.min(Math.max(0, xr[0]), xr[1]), y0 = Math.min(Math.max(0, yr[0]), yr[1]);
      svgEl("line", { x1: m.l, x2: width - m.r, y1: g.y(y0), y2: g.y(y0), stroke: JD.color("ink-3"), "stroke-width": 1.2 }, ax);
      svgEl("line", { x1: g.x(x0), x2: g.x(x0), y1: m.t, y2: height - m.b, stroke: JD.color("ink-3"), "stroke-width": 1.2 }, ax);
      if (o.xLabel) { var xl = svgEl("text", { x: width - m.r, y: g.y(y0) - 6, "text-anchor": "end", "font-style": "italic" }, ax); xl.textContent = o.xLabel; }
      if (o.yLabel) { var yl = svgEl("text", { x: g.x(x0) + 6, y: m.t + 10, "font-style": "italic" }, ax); yl.textContent = o.yLabel; }
    }
    JD.onResize(g.redraw);
    window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", function () { g.redraw(); });
    return g;
  }

  function makePlayer(parent, o) {
    var row = document.createElement("div");
    row.className = "jd-row jd-player";
    var play = document.createElement("button");
    play.type = "button";
    var reset = document.createElement("button");
    reset.type = "button";
    reset.textContent = "Reset";
    var seek = document.createElement("input");
    seek.type = "range"; seek.min = 0; seek.max = 1; seek.step = "any"; seek.value = 0;
    seek.style.flex = "1";
    row.appendChild(play); row.appendChild(reset); row.appendChild(seek);
    parent.appendChild(row);
    var t = 0, running = false, last = 0, duration = (o.duration || 4) * 1000;
    function frame() { seek.value = t; if (o.onFrame) o.onFrame(t); play.textContent = running ? "Pause" : (t >= 1 ? "Replay" : "Play"); }
    function tick(now) {
      if (!running) return;
      t = Math.min(1, t + (now - last) / duration);
      last = now;
      frame();
      if (t >= 1) { running = false; frame(); return; }
      requestAnimationFrame(tick);
    }
    play.addEventListener("click", function () {
      if (JD.reducedMotion) { t = 1; frame(); return; }
      if (running) { running = false; frame(); return; }
      if (t >= 1) t = 0;
      running = true; last = performance.now(); requestAnimationFrame(tick);
    });
    reset.addEventListener("click", function () { running = false; t = 0; frame(); });
    seek.addEventListener("input", function () { running = false; t = Number(seek.value); frame(); });
    if (JD.reducedMotion) t = o.start != null ? o.start : 1;
    else t = o.start || 0;
    frame();
    return { get t() { return t; }, set: function (v) { t = v; frame(); } };
  }

  document.addEventListener("DOMContentLoaded", function () {
    var root = document.getElementById("figure") || document.body;
    new ResizeObserver(sendHeight).observe(root);
    sendHeight();
    report({ type: "ready" });
  });
  window.addEventListener("load", sendHeight);
})();
