// 학습 페이지 렌더러. Swift 가 조합한 페이지(JSON)를 받아 그린다 (docs/PAGES.md 의 렌더러).
// 받는 것: window.jindesk.render(page). 보내는 것: webkit.messageHandlers.jindesk.postMessage({ type, … }).
//   openSource { source, page }   출처 칩을 눌렀다
//   ready                         그릴 준비가 됐다
(function () {
  "use strict";

  var NOTE_LABEL = { "misconception": "Common mistake", "key-idea": "Key idea", "command-term": "Command term" };

  function post(message) {
    try { window.webkit.messageHandlers.jindesk.postMessage(message); } catch (e) { /* 브라우저로 열었을 때 */ }
  }

  function esc(t) {
    return String(t).replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; });
  }

  function el(tag, cls, html) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (html != null) n.innerHTML = html;
    return n;
  }

  function math(tex, display) {
    try {
      return katex.renderToString(tex, { displayMode: display, throwOnError: false, strict: "ignore", trust: false });
    } catch (e) {
      return '<span class="katex-error">' + esc(tex) + "</span>";
    }
  }

  // 글을 수식과 글 조각으로 나눈다: \( … \), \[ … \]
  function split(text) {
    var out = [], re = /\\\(([\s\S]*?)\\\)|\\\[([\s\S]*?)\\\]/g, last = 0, m;
    while ((m = re.exec(text)) !== null) {
      if (m.index > last) out.push({ text: text.slice(last, m.index) });
      out.push(m[1] != null ? { tex: m[1], display: false } : { tex: m[2], display: true });
      last = re.lastIndex;
    }
    if (last < text.length) out.push({ text: text.slice(last) });
    return out;
  }

  // 용어 어휘: 페이지에서 처음 나오는 곳에 점선 밑줄과 한국어 뜻을 단다
  var terms = [], seen = {};
  function setTerms(list) {
    terms = (list || []).map(function (t) {
      var names = (t.names || [t.en]).slice().sort(function (a, b) { return b.length - a.length; });
      var pattern = names.map(function (n) { return n.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }).join("|");
      return { en: t.en, ko: t.ko, re: new RegExp("\\b(" + pattern + ")(s|es)?\\b", "i") };
    });
    seen = {};
  }

  function markTerms(html) {
    terms.forEach(function (t) {
      if (seen[t.en]) return;
      var m = t.re.exec(html);
      if (!m) return;
      // 태그 안(속성)에 걸리지 않게 앞쪽에 열린 < 가 없는지 본다
      var before = html.slice(0, m.index);
      if (before.lastIndexOf("<") > before.lastIndexOf(">")) return;
      seen[t.en] = true;
      html = before + '<dfn class="term" tabindex="0" data-ko="' + esc(t.ko) + '">' + m[0] + "</dfn>" + html.slice(m.index + m[0].length);
    });
    return html;
  }

  // 줄 안 글: 굵게, 기울임
  function inline(text, withTerms) {
    var h = esc(text).replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>").replace(/(^|[^*])\*([^*\s][^*]*)\*/g, "$1<em>$2</em>");
    return withTerms ? markTerms(h) : h;
  }

  // 글 한 단위를 HTML 로: 빈 줄로 문단을 나누고, "- " 줄은 나열이다. 수식은 KaTeX 로 그린다.
  function prose(text, withTerms) {
    var parts = split(text || ""), holders = [], flat = "";
    parts.forEach(function (p) {
      if (p.tex != null) { holders.push(math(p.tex, p.display)); flat += "\u0000" + (holders.length - 1) + "\u0000"; }
      else flat += p.text;
    });
    var blocks = flat.replace(/\r\n/g, "\n").split(/\n\s*\n/), html = "";
    blocks.forEach(function (b) {
      var lines = b.split("\n").filter(function (l) { return l.trim() !== ""; });
      if (!lines.length) return;
      if (lines.every(function (l) { return /^\s*[-•]\s+/.test(l); })) {
        html += "<ul>" + lines.map(function (l) { return "<li>" + inline(l.replace(/^\s*[-•]\s+/, ""), withTerms) + "</li>"; }).join("") + "</ul>";
      } else {
        html += "<p>" + inline(lines.join(" "), withTerms) + "</p>";
      }
    });
    return html.replace(/\u0000(\d+)\u0000/g, function (_, i) { return holders[+i]; });
  }

  function lastBlock(container) {
    var last = container.lastElementChild;
    if (last && last.tagName === "UL") last = last.lastElementChild || last;
    return last || container;
  }

  // 한국어 펼침 수와 모두 접기
  function openCount() {
    var box = document.querySelector(".open-count");
    if (!box) return;
    var open = Array.prototype.filter.call(document.querySelectorAll(".ko"), function (k) { return !k.hidden; });
    box.hidden = open.length === 0;
    box.innerHTML = "한국어 " + open.length + '개 펼침 <button type="button">모두 접기</button>';
    var b = box.querySelector("button");
    if (b) b.addEventListener("click", function () {
      open.forEach(function (k) {
        k.hidden = true;
        var t = k.parentElement.querySelector(".g-tr");
        if (t) t.setAttribute("aria-expanded", "false");
      });
      openCount();
    });
  }

  // 영어 글 + 출처 칩 + 한 단추 + 한국어
  function paraBlock(unit) {
    var wrap = el("div", "para");
    wrap.id = unit.id;
    var en = el("div", "en", prose(unit.text, true));
    var first = en.firstElementChild;
    if (first && first.tagName === "UL") first = first.firstElementChild;
    if (first && unit.prov) first.insertAdjacentHTML("afterbegin", unit.prov === "added" ? '<span class="prov add">보충</span>' : '<span class="prov src">자료</span>');
    var host = lastBlock(en);
    (unit.src || []).forEach(function (s) {
      var chip = el("button", "srcchip", esc(s.label));
      chip.type = "button";
      chip.title = s.title || "";
      chip.addEventListener("click", function () { post({ type: "openSource", source: s.source, page: s.page }); });
      host.appendChild(chip);
    });
    var pc = el("span", "pc");
    var tb = el("button", "g-tr", "한");
    tb.type = "button";
    tb.setAttribute("aria-expanded", "false");
    var ko = null;
    if (unit.ko) {
      ko = el("div", "ko" + (unit.koStale ? " stale" : ""), prose(unit.ko, false));
      ko.hidden = true;
      tb.title = "이 문단의 한국어";
      tb.addEventListener("click", function () {
        ko.hidden = !ko.hidden;
        tb.setAttribute("aria-expanded", String(!ko.hidden));
        openCount();
      });
    } else {
      tb.disabled = true;
      tb.title = "아직 한국어가 없어요";
    }
    pc.appendChild(tb);
    host.appendChild(pc);
    wrap.appendChild(en);
    if (ko) wrap.appendChild(ko);
    return wrap;
  }

  // 그림 블록: 블록마다 iframe 하나에서 블록 틀과 함께 돈다. 한 그림이 깨지거나 멈춰도 페이지의 나머지는 살아 있다.
  function figureNode(unit) {
    var f = el("figure", "blk fig");
    f.id = unit.id;
    var head = el("div", "blk-head");
    head.appendChild(el("span", "blk-kind", "Figure"));
    head.appendChild(el("span", "blk-title", esc(unit.figure.title)));
    f.appendChild(head);
    var frame = document.createElement("iframe");
    frame.className = "fig-frame";
    frame.setAttribute("sandbox", "allow-scripts");
    frame.title = unit.figure.title;
    frame.src = unit.figure.src;
    f.appendChild(frame);
    if (unit.caption) {
      var cap = paraBlock({ id: unit.id + "-caption", text: unit.caption, ko: unit.ko, koStale: unit.koStale, src: [] });
      cap.classList.add("caption");
      f.appendChild(cap);
    }
    return f;
  }

  // 그림이 알리는 내용 높이와 오류
  window.addEventListener("message", function (e) {
    var d = e.data;
    if (!d || d.jindesk !== "figure") return;
    var frame = Array.prototype.find.call(document.querySelectorAll("iframe.fig-frame"), function (f) { return f.contentWindow === e.source; });
    if (!frame) return;
    if (d.type === "height" && d.h > 0) frame.style.height = Math.min(Math.max(d.h, 60), 1200) + "px";
    if (d.type === "error" && !frame.parentElement.querySelector(".fig-error")) {
      frame.insertAdjacentElement("afterend", el("div", "fig-error", "그림을 그리다 오류가 났어요. " + esc(d.message || "")));
    }
  });

  function unitNode(unit) {
    if (unit.kind === "block" && unit.figure) return figureNode(unit);
    if (unit.kind === "block") {
      var b = el("div", "blk math");
      b.id = unit.id;
      b.appendChild(el("div", "math-display", math(unit.tex || "", true)));
      return b;
    }
    if (unit.kind === "note") {
      var n = el("div", "note " + (unit.note || ""));
      n.appendChild(el("span", "ic", esc(NOTE_LABEL[unit.note] || "Note")));
      n.appendChild(paraBlock(unit));
      return n;
    }
    return paraBlock(unit);
  }

  function render(page) {
    var root = document.getElementById("page");
    root.innerHTML = "";
    setTerms(page.terms);
    var art = el("article", "concept");
    if (page.crumb) art.appendChild(el("div", "crumb", esc(page.crumb)));
    var h = el("h1", null, esc(page.title));
    if (page.titleKo) h.appendChild(el("span", "ko-title", esc(page.titleKo)));
    art.appendChild(h);
    var meta = el("div", "meta");
    (page.chips || []).forEach(function (c) { meta.appendChild(el("span", "chip", esc(c))); });
    var count = el("span", "open-count");
    count.hidden = true;
    meta.appendChild(count);
    art.appendChild(meta);
    var units = el("div", "units");
    if (!page.units || !page.units.length) units.appendChild(el("div", "empty", "아직 페이지가 없어요. 개념 정리가 끝나면 만들어집니다."));
    (page.units || []).forEach(function (u) { units.appendChild(unitNode(u)); });
    art.appendChild(units);
    if (page.sources && page.sources.length) {
      var s = el("section", "sources");
      s.appendChild(el("h2", null, "이 개념이 나온 자료"));
      var ul = el("ul");
      page.sources.forEach(function (src) {
        var li = el("li", null, esc(src.title) + " ");
        (src.pages || []).forEach(function (p) {
          var chip = el("button", "srcchip", String(p));
          chip.type = "button";
          chip.addEventListener("click", function () { post({ type: "openSource", source: src.id, page: p }); });
          li.appendChild(chip);
        });
        ul.appendChild(li);
      });
      s.appendChild(ul);
      art.appendChild(s);
    }
    root.appendChild(art);
    // 한국어를 모두 펼친 채로 연다 (화면 찍기)
    if (page.openAll) {
      Array.prototype.forEach.call(document.querySelectorAll(".g-tr:not(:disabled)"), function (b) { b.click(); });
    }
    window.scrollTo(0, 0);
    // 그림 블록까지 내려 연다 (화면 찍기)
    if (page.scrollToFigure) {
      var fig = document.querySelector("figure.fig");
      if (fig) setTimeout(function () { fig.scrollIntoView({ block: "start" }); }, 300);
    }
  }

  window.jindesk = { render: render };
  document.addEventListener("DOMContentLoaded", function () { post({ type: "ready" }); });
})();
