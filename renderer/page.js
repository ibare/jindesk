// 학습 페이지 렌더러. Swift 가 조합한 페이지(JSON)를 받아 그린다 (docs/PAGES.md 의 렌더러).
// 받는 것: window.jindesk.render(page). 보내는 것: webkit.messageHandlers.jindesk.postMessage({ type, … }).
//   openSource { source, page }   출처 칩을 눌렀다
//   openConcept { id }            앞뒤 개념 지도의 이웃이나 개념 카드를 눌렀다
//   openMap { concept }           앞뒤 개념 지도의 "개념 지도에서 보기"를 눌렀다
// page.readOnly 이면(폰 앱) 쓰는 단추(코멘트 남기기·지우기, 다시 만들기, 새 판 받아들이기)를 그리지 않는다.
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

  // 코멘트 스레드: 단위 아래에 열린다. 메모, 질문(물어보기가 답한다), 이상해요.
  var current = null, openThreads = {};
  // 읽기 전용 보기(폰 앱)가 아닌가 (docs/PAGES.md 의 읽기 전용)
  function canWrite() { return !(current && current.readOnly); }
  function plain(text) { return String(text || "").replace(/\\[()\[\]]/g, "").replace(/\s+/g, " ").trim().slice(0, 120); }

  function threadNode(unitID, rev, quote, unit) {
    var list = ((current && current.comments) || {})[unitID] || [];
    var t = el("div", "thread");
    list.forEach(function (c) {
      var item = el("div", "cm");
      var head = el("div", "cm-head");
      head.appendChild(el("span", "kind " + c.kind, esc(c.label)));
      head.appendChild(el("time", null, esc(String(c.at).slice(5, 16).replace("T", " "))));
      if (canWrite()) {
        var del = el("button", "cm-del", "지우기");
        del.type = "button";
        del.addEventListener("click", function () { post({ type: "deleteComment", id: c.id }); });
        head.appendChild(del);
      }
      item.appendChild(head);
      if (c.old) item.appendChild(el("div", "cm-old", "이전 판에 단 코멘트 · “" + esc(c.quote) + "”"));
      item.appendChild(el("div", "cm-text", esc(c.text)));
      (c.replies || []).forEach(function (r) {
        var rep = paraBlock({ id: r.id, text: r.en, ko: r.ko, prov: r.supplementary ? "added" : (r.src && r.src.length ? "source" : null), src: r.src || [], noComments: true });
        rep.classList.add("reply");
        item.appendChild(rep);
      });
      if (c.waiting) item.appendChild(el("div", "cm-waiting", "답을 쓰는 중이에요…"));
      if (canWrite() && c.kind === "flag" && unit && unit.regen && unit.regen.length) {
        var send = el("button", "cm-regen", "다시 만들기로 보내기");
        send.type = "button";
        send.addEventListener("click", function () {
          post({ type: "openRegen", unit: unitID, rev: rev || 1, ops: unit.regen.map(function (r) { return r.op; }), quote: quote, fromComment: c.id, note: c.text });
        });
        item.appendChild(send);
      }
      t.appendChild(item);
    });
    if (!canWrite()) return t;
    // 코멘트는 메모만 남긴다 (DECISIONS 30). 이미 남긴 질문과 이상해요는 위 목록에서 읽는다.
    var form = el("div", "cm-form");
    var area = document.createElement("textarea");
    area.rows = 2;
    area.placeholder = "나를 위한 메모";
    var send = el("button", "cm-send", "남기기");
    send.type = "button";
    send.addEventListener("click", function () {
      var text = area.value.trim();
      if (!text) return;
      post({ type: "comment", unit: unitID, rev: rev || 1, quote: quote, kind: "memo", text: text });
      area.value = "";
      send.textContent = "남겼어요";
      setTimeout(function () { send.textContent = "남기기"; }, 1500);
    });
    form.appendChild(area);
    form.appendChild(send);
    t.appendChild(form);
    return t;
  }

  function commentButton(unit, wrap) {
    var unitID = unit.commentUnit || unit.id;
    var list = ((current && current.comments) || {})[unitID] || [];
    // 읽기 전용이면 코멘트가 있는 단위에만 읽는 단추를 단다
    if (!canWrite() && !list.length) return null;
    var b = el("button", "g-cm" + (list.length ? " has" : ""), list.length ? "✎ " + list.length : "✎");
    b.type = "button";
    b.title = "코멘트";
    var thread = null;
    function open() {
      thread = threadNode(unitID, unit.rev, plain(unit.text), unit);
      wrap.appendChild(thread);
      openThreads[unitID] = true;
      b.setAttribute("aria-expanded", "true");
    }
    b.addEventListener("click", function () {
      if (thread) { thread.remove(); thread = null; delete openThreads[unitID]; b.setAttribute("aria-expanded", "false"); }
      else open();
    });
    if (openThreads[unitID]) setTimeout(open, 0);
    return b;
  }

  // 다시 만들기: ↻ 를 누르면 앱이 방식을 고르는 시트를 연다
  function regenButton(unit, label) {
    var b = el("button", "g-rg", label || "↻");
    b.type = "button";
    b.title = "다시 만들기";
    b.addEventListener("click", function () {
      post({ type: "openRegen", unit: unit.commentUnit || unit.id, rev: unit.rev || 1, ops: (unit.regen || []).map(function (r) { return r.op; }), quote: plain(unit.text || unit.caption || "") });
    });
    return b;
  }

  // 요구의 상태 ("↻ 더 쉽게 · 요청함"), 후보가 있으면 견주기
  function directiveBadges(unit, wrap) {
    (unit.directives || []).forEach(function (d) {
      if (d.status === "applied" || d.status === "accepted") return;
      var row = el("div", "dir " + d.status);
      row.appendChild(el("span", "dir-label", "↻ " + esc(d.label) + " · " + esc(d.statusLabel)));
      if (d.status === "candidate" && canWrite()) {
        var open = el("button", "dir-open", "새 판 · 비교");
        open.type = "button";
        var panel = null;
        open.addEventListener("click", function () {
          if (panel) { panel.remove(); panel = null; return; }
          panel = comparePanel(unit, d);
          row.insertAdjacentElement("afterend", panel);
        });
        row.appendChild(open);
      }
      wrap.appendChild(row);
    });
  }

  function comparePanel(unit, d) {
    var p = el("div", "compare");
    p.appendChild(el("div", "cmp-head", "새 판 후보 · " + esc(d.label) + (d.note ? " — " + esc(d.note) : "")));
    var body = el("div", "cmp-body");
    (d.candidate || []).forEach(function (c) {
      if (c.figure) {
        var f = document.createElement("iframe");
        f.className = "fig-frame";
        f.setAttribute("sandbox", "allow-scripts");
        f.src = c.figure;
        body.appendChild(f);
      }
      if (c.title) body.appendChild(el("div", "blk-title", prose(c.title, false)));
      if (c.tex) body.appendChild(el("div", "step-math", math(c.tex, true)));
      if (c.text) body.appendChild(el("div", "en", prose(c.text, false)));
    });
    p.appendChild(body);
    if (d.checks && d.checks.length) p.appendChild(el("div", "cmp-checks", d.checks.map(function (c) { return "✓ " + esc(c); }).join(" · ")));
    var row = el("div", "cmp-actions");
    var accept = el("button", "cmp-accept", "새 판 받아들이기");
    accept.type = "button";
    accept.addEventListener("click", function () { post({ type: "acceptDirective", id: d.id }); });
    var keep = el("button", "cmp-keep", "지금 판 유지");
    keep.type = "button";
    keep.addEventListener("click", function () { post({ type: "keepDirective", id: d.id }); });
    row.appendChild(accept);
    row.appendChild(keep);
    p.appendChild(row);
    return p;
  }

  // 곁 설명 (쉽게, 자세히): 단위 아래에 펼친다. 영어와 그 한국어
  function sideButton(unit, kind, label, wrap) {
    var layer = unit[kind];
    var b = el("button", "g-side", label);
    b.type = "button";
    b.setAttribute("aria-expanded", "false");
    var panel = null;
    b.addEventListener("click", function () {
      if (panel) { panel.remove(); panel = null; b.setAttribute("aria-expanded", "false"); return; }
      panel = el("div", "side " + kind);
      panel.appendChild(el("span", "side-label", label + " · 곁 설명" + (layer.stale ? " (원문이 바뀌어 다시 만드는 중)" : "")));
      var inner = paraBlock({ id: (unit.commentUnit || unit.id) + "-" + kind, text: layer.en, ko: layer.ko, src: [], noComments: true });
      panel.appendChild(inner);
      wrap.appendChild(panel);
      b.setAttribute("aria-expanded", "true");
    });
    return b;
  }

  // 영어 글 + 출처 칩 + 한 단추 + 코멘트 단추 + 한국어
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
    if (unit.easy) pc.appendChild(sideButton(unit, "easy", "쉽게", wrap));
    if (unit.detail) pc.appendChild(sideButton(unit, "detail", "자세히", wrap));
    var cb = unit.noComments ? null : commentButton(unit, wrap);
    if (cb) pc.appendChild(cb);
    if (canWrite() && unit.regen && unit.regen.length) pc.appendChild(regenButton(unit));
    host.appendChild(pc);
    wrap.appendChild(en);
    if (ko) wrap.appendChild(ko);
    if (!unit.noComments) directiveBadges(unit, wrap);
    return wrap;
  }

  // 그림 블록: 블록마다 iframe 하나에서 블록 틀과 함께 돈다. 한 그림이 깨지거나 멈춰도 페이지의 나머지는 살아 있다.
  function figureNode(unit) {
    var f = el("figure", "blk fig");
    f.id = unit.id;
    var head = el("div", "blk-head");
    head.appendChild(el("span", "blk-kind", "Figure"));
    head.appendChild(el("span", "blk-title", esc(unit.figure.title)));
    if (canWrite() && unit.regen && unit.regen.length) { var rg = regenButton(unit, "↻ 다시 만들기"); rg.classList.add("blk-regen"); head.appendChild(rg); }
    f.appendChild(head);
    var frame = document.createElement("iframe");
    frame.className = "fig-frame";
    frame.setAttribute("sandbox", "allow-scripts");
    frame.title = unit.figure.title;
    frame.src = unit.figure.src;
    f.appendChild(frame);
    if (unit.caption) {
      var cap = paraBlock({ id: unit.id + "-caption", commentUnit: unit.id, rev: unit.rev, text: unit.caption, ko: unit.ko, koStale: unit.koStale, src: [], easy: unit.easy, directives: unit.directives });
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

  // 풀이 블록: 단계마다 수식과 이유. "한 단계씩"을 누르면 하나씩 펼친다. 단계마다 한국어가 붙는다.
  function derivationNode(unit, steps) {
    var b = el("div", "blk deriv");
    b.id = unit.id;
    var head = el("div", "blk-head");
    head.appendChild(el("span", "blk-kind", "Worked solution"));
    if (unit.prov === "added") head.appendChild(el("span", "prov add", "보충"));
    head.appendChild(el("span", "blk-title", prose(unit.derivation.title, false).replace(/^<p>|<\/p>$/g, "")));
    var toggle = el("button", "step-toggle", "한 단계씩");
    toggle.type = "button";
    head.appendChild(toggle);
    if (canWrite() && unit.regen && unit.regen.length) { var rg = regenButton(unit, "↻ 다시 만들기"); rg.classList.add("blk-regen"); head.appendChild(rg); }
    b.appendChild(head);
    directiveBadges(unit, b);
    var list = el("ol", "steps");
    steps.forEach(function (s, i) {
      var li = el("li", "step");
      li.id = s.id;
      li.appendChild(el("div", "step-math", math(s.tex || "", true)));
      if (s.text) {
        var why = paraBlock({ id: s.id + "-why", commentUnit: s.id, rev: s.rev, text: s.text, ko: s.ko, koStale: s.koStale, src: [], regen: s.regen, directives: s.directives, easy: s.easy });
        why.classList.add("why");
        li.appendChild(why);
      }
      list.appendChild(li);
    });
    b.appendChild(list);
    var shown = steps.length;
    var next = el("button", "step-next", "다음 단계");
    next.type = "button";
    next.hidden = true;
    function paint() {
      Array.prototype.forEach.call(list.children, function (li, i) { li.classList.toggle("later", i >= shown); });
      next.hidden = shown >= steps.length;
    }
    toggle.addEventListener("click", function () {
      var stepping = b.classList.toggle("stepping");
      shown = stepping ? 1 : steps.length;
      toggle.textContent = stepping ? "모두 보기" : "한 단계씩";
      paint();
    });
    next.addEventListener("click", function () { shown += 1; paint(); });
    b.appendChild(next);
    return b;
  }

  // 확인 문제: 문제를 먼저 보이고, 누르면 답과 풀이가 펼쳐진다
  function checkNode(unit) {
    var d = el("details", "check");
    d.id = unit.id;
    var summary = el("summary");
    summary.appendChild(el("span", "blk-kind", "Check"));
    d.appendChild(summary);
    var q = paraBlock({ id: unit.id + "-q", commentUnit: unit.id, rev: unit.rev, text: unit.text, ko: unit.ko, koStale: unit.koStale, prov: unit.prov, src: [], regen: unit.regen, directives: unit.directives, easy: unit.easy });
    q.classList.add("question");
    summary.appendChild(q);
    var ans = el("div", "ans");
    ans.appendChild(el("div", "answer", "<b>Answer</b> " + prose(unit.answer || "", false).replace(/^<p>|<\/p>$/g, "")));
    if (unit.solution) ans.appendChild(el("div", "solution", prose(unit.solution, false)));
    d.appendChild(ans);
    return d;
  }

  function unitNode(unit) {
    if (unit.kind === "check") return checkNode(unit);
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

  // 개념 카드: 누르면 그 개념의 페이지로 간다. 아직 없는 개념은 이름만 보인다.
  function linkSection(art, title, list, withNote) {
    if (!list || !list.length) return;
    var s = el("section", "links");
    s.appendChild(el("h2", null, esc(title)));
    list.forEach(function (l) {
      var card = el(l.missing || !l.id ? "div" : "button", "linkcard" + (l.missing ? " missing" : ""));
      if (card.tagName === "BUTTON") {
        card.type = "button";
        card.addEventListener("click", function () { post({ type: "openConcept", id: l.id }); });
      }
      card.appendChild(el("span", "lc-title", esc(l.title) + (l.missing ? " <small>아직 없음</small>" : "")));
      if (l.subject) card.appendChild(el("span", "lc-subject", esc(l.subject)));
      if (withNote && l.note) card.appendChild(el("span", "lc-note", prose(l.note, false).replace(/^<p>|<\/p>$/g, "")));
      s.appendChild(card);
    });
    art.appendChild(s);
  }

  // 앞뒤 개념 지도 (PAGES.md 의 개념 지도 · 학습 페이지 머리): 이 개념의 바로 앞(선수 개념)과 바로 다음 개념만 그린다.
  // 이웃을 누르면 그 개념의 페이지로 가고, 새 페이지에서는 누른 노드가 있던 자리에서 가운데로 옮겨 온다.
  var FOLD = 5, SVG = "http://www.w3.org/2000/svg", travel = null, edgeWatch = null;

  function nodeTip(n, side) {
    var tips = [];
    if (n.kind === "missing") tips.push("아직 정리되지 않은 개념이에요");
    else if (!n.hasPage) tips.push("학습 페이지를 만드는 중이에요");
    if (n.beyond) tips.push((side === "before" ? "먼저 알아야 할 것이 " : "이어지는 개념이 ") + n.beyond + "개 더 있어요");
    return tips.join("\n");
  }

  function mapNode(n, side) {
    var center = side === "center", go = !center && n.kind !== "missing" && n.id;
    var b = el(go ? "button" : "div", "nm " + (center ? "center" : n.kind));
    if (go) b.type = "button";
    if (n.id) b.setAttribute("data-id", n.id);
    if (n.beyond) b.setAttribute("data-beyond", String(n.beyond));
    var top = "";
    if (n.kind === "other" && n.subject) top += '<b class="nm-subj">' + esc(n.subject) + "</b>";
    if (n.code) top += '<span class="nm-code">' + esc(n.code) + "</span>";
    top += center ? "지금 보는 개념" : n.kind === "missing" ? "아직 없는 개념" : esc(n.titleKo || "");
    b.appendChild(el("span", "nm-top", top));
    b.appendChild(el("span", "nm-title", esc(n.title)));
    if (!center && n.kind !== "missing") b.appendChild(el("i", "nm-dot" + (n.hasPage ? " on" : "")));
    if (!center) b.title = nodeTip(n, side);
    if (go) {
      b.addEventListener("click", function () { goTo(n.id, b); });
      ["mouseenter", "focus"].forEach(function (e) { b.addEventListener(e, function () { hot(b, true); }); });
      ["mouseleave", "blur"].forEach(function (e) { b.addEventListener(e, function () { hot(b, false); }); });
    }
    return b;
  }

  // 한쪽에 다섯이 넘으면 넷만 보인다. 떠나온 개념은 접지 않는다 (돌아갈 길)
  function mapColumn(side, caption, list, empty) {
    var col = el("div", "nbr-col " + side);
    col.appendChild(el("div", "nbr-cap", caption));
    var stack = el("div", "nbr-stack");
    if (!list.length) stack.appendChild(el("div", "nbr-none", empty));
    var limit = list.length > FOLD ? FOLD - 1 : list.length, folded = 0;
    list.forEach(function (n, i) {
      var node = mapNode(n, side);
      if (i >= limit && !(travel && n.id === travel.from)) { node.hidden = true; folded++; }
      stack.appendChild(node);
    });
    if (folded) {
      var more = el("button", "nbr-more", folded + "개 더 보기");
      more.type = "button";
      more.addEventListener("click", function () {
        Array.prototype.forEach.call(stack.querySelectorAll(".nm[hidden]"), function (x) { x.hidden = false; });
        more.remove();
      });
      stack.appendChild(more);
    }
    col.appendChild(stack);
    return col;
  }

  function neighborMap(page) {
    var before = page.before || [], after = page.after || [];
    if (!before.length && !after.length) return null;
    var s = el("section", "nbr");
    s.setAttribute("aria-label", "앞뒤 개념");
    var head = el("div", "nbr-head");
    head.appendChild(el("h2", null, "앞뒤 개념"));
    var all = el("button", "nbr-all", "개념 지도에서 보기");
    all.type = "button";
    all.addEventListener("click", function () { post({ type: "openMap", concept: page.concept }); });
    head.appendChild(all);
    s.appendChild(head);
    var grid = el("div", "nbr-grid");
    var svg = document.createElementNS(SVG, "svg");
    svg.setAttribute("class", "nbr-edges");
    svg.setAttribute("aria-hidden", "true");
    grid.appendChild(svg);
    grid.appendChild(mapColumn("before", "먼저 알아야 할 것", before, "먼저 알아야 할 개념이 없어요"));
    var mid = el("div", "nbr-col mid");
    mid.appendChild(el("div", "nbr-cap", ""));
    var stack = el("div", "nbr-stack");
    stack.appendChild(mapNode({ id: page.concept, title: page.title, code: page.code, kind: "concept" }, "center"));
    mid.appendChild(stack);
    grid.appendChild(mid);
    grid.appendChild(mapColumn("after", "이어서 배울 것", after, "아직 이어지는 개념이 없어요"));
    s.appendChild(grid);
    return s;
  }

  // 화살표: 선수 개념 → 이 개념 → 다음 개념. 옮겨 오는 동안의 transform 에 흔들리지 않게 레이아웃 자리(offset)로 잰다.
  // 더 이어지는 개념이 있으면 노드 바깥으로 짧은 점선을 단다. 폭이 좁아 위아래로 쌓으면 화살표를 그리지 않는다.
  function drawEdges(grid) {
    var svg = grid.querySelector(".nbr-edges"), center = grid.querySelector(".nm.center");
    if (!svg || !center) return;
    while (svg.firstChild) svg.removeChild(svg.firstChild);
    if (getComputedStyle(svg).display === "none") return;
    svg.setAttribute("viewBox", "0 0 " + grid.clientWidth + " " + grid.clientHeight);
    function box(n) { return { l: n.offsetLeft, r: n.offsetLeft + n.offsetWidth, y: n.offsetTop + n.offsetHeight / 2 }; }
    function line(d, cls, id) {
      var p = document.createElementNS(SVG, "path");
      p.setAttribute("d", d);
      p.setAttribute("class", cls);
      if (id) p.setAttribute("data-for", id);
      svg.appendChild(p);
    }
    function curve(x1, y1, x2, y2) {
      var k = (x2 - x1) / 2;
      return "M" + x1 + " " + y1 + " C" + (x1 + k) + " " + y1 + " " + (x2 - k) + " " + y2 + " " + x2 + " " + y2 +
        " M" + (x2 - 6) + " " + (y2 - 4) + " L" + x2 + " " + y2 + " L" + (x2 - 6) + " " + (y2 + 4);
    }
    function stubs(x, y, count, dir) {
      var d = "", k = Math.min(count, 3);
      for (var i = 0; i < k; i++) d += "M" + x + " " + y + " L" + (x + dir * 13) + " " + (y + (i - (k - 1) / 2) * 7) + " ";
      return d;
    }
    var c = box(center);
    Array.prototype.forEach.call(grid.querySelectorAll(".before .nm:not([hidden])"), function (n) {
      var b = box(n), id = n.getAttribute("data-id");
      line(curve(b.r + 1, b.y, c.l - 2, c.y), "e before", id);
      if (n.hasAttribute("data-beyond")) line(stubs(b.l - 1, b.y, +n.getAttribute("data-beyond"), -1), "stub", id);
    });
    Array.prototype.forEach.call(grid.querySelectorAll(".after .nm:not([hidden])"), function (n) {
      var b = box(n), id = n.getAttribute("data-id");
      line(curve(c.r + 1, c.y, b.l - 2, b.y), "e after", id);
      if (n.hasAttribute("data-beyond")) line(stubs(b.r + 1, b.y, +n.getAttribute("data-beyond"), 1), "stub", id);
    });
  }

  function watchEdges(section) {
    if (edgeWatch) edgeWatch.disconnect();
    edgeWatch = null;
    if (!section) return;
    var grid = section.querySelector(".nbr-grid");
    edgeWatch = new ResizeObserver(function () { drawEdges(grid); });
    edgeWatch.observe(grid);
  }

  // 노드에 올리면 그 노드의 화살표만 짙게
  function hot(node, on) {
    var grid = node.closest(".nbr-grid");
    if (!grid) return;
    grid.classList.toggle("hovering", on);
    var id = node.getAttribute("data-id");
    Array.prototype.forEach.call(grid.querySelectorAll(".nbr-edges [data-for]"), function (p) {
      if (p.getAttribute("data-for") === id) p.classList.toggle("hot", on);
    });
  }

  function goTo(id, node) {
    var center = document.querySelector(".nbr .nm.center");
    travel = { id: id, rect: node.getBoundingClientRect(), from: current && current.concept, fromRect: center && center.getBoundingClientRect(), at: Date.now() };
    node.classList.add("going");
    post({ type: "openConcept", id: id });
  }

  // 누른 노드는 있던 자리에서 가운데로, 떠나온 개념은 가운데에서 제자리로 옮겨 온다. 나머지 노드와 화살표는 뒤따라 나타난다.
  function arrive(section) {
    var t = travel;
    travel = null;
    if (!t || !section || !current || current.concept !== t.id || Date.now() - t.at > 3000) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    var moves = [[section.querySelector(".nm.center"), t.rect]];
    if (t.from && t.fromRect) moves.push([section.querySelector('.nm[data-id="' + CSS.escape(t.from) + '"]:not([hidden])'), t.fromRect]);
    moves = moves.filter(function (m) { return m[0]; });
    section.classList.add("arriving");
    moves.forEach(function (m) {
      var n = m[0], from = m[1], to = n.getBoundingClientRect();
      n.classList.add("moving");
      n.style.transform = "translate(" + (from.left + from.width / 2 - to.left - to.width / 2) + "px, " + (from.top + from.height / 2 - to.top - to.height / 2) + "px)";
    });
    section.getBoundingClientRect();
    requestAnimationFrame(function () {
      section.classList.remove("arriving");
      section.classList.add("settling");
      moves.forEach(function (m) { m[0].style.transform = ""; });
      // page.css 의 .settling 전환(가장 늦게 끝나는 것 0.65초)이 끝난 뒤에 거둔다. 먼저 거두면 단추 노드의 이동이 끊긴다
      setTimeout(function () {
        section.classList.remove("settling");
        moves.forEach(function (m) { m[0].classList.remove("moving"); });
      }, 800);
    });
  }

  function render(page) {
    var same = current && current.concept === page.concept;
    var keepY = window.scrollY;
    if (!same) openThreads = {};
    current = page;
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
    (page.facets || []).forEach(function (g) {
      g.values.forEach(function (v) { meta.appendChild(el("span", "chip facet", '<small>' + esc(g.label) + '</small> ' + esc(v))); });
    });
    var count = el("span", "open-count");
    count.hidden = true;
    meta.appendChild(count);
    art.appendChild(meta);
    var around = neighborMap(page);
    if (around) art.appendChild(around);
    var units = el("div", "units");
    if (!page.units || !page.units.length) units.appendChild(el("div", "empty", "아직 페이지가 없어요. 개념 정리가 끝나면 만들어집니다."));
    var list = page.units || [];
    for (var i = 0; i < list.length; i++) {
      var u = list[i];
      if (u.kind === "block" && u.derivation) {
        var steps = [];
        while (i + 1 < list.length && list[i + 1].kind === "step" && list[i + 1].parent === u.id) steps.push(list[++i]);
        units.appendChild(derivationNode(u, steps));
      } else if (u.kind !== "step") {
        units.appendChild(unitNode(u));
      }
    }
    art.appendChild(units);
    // 먼저 알아야 할 것은 머리의 앞뒤 개념 지도에 있다. 다 읽고 이어 갈 곳만 아래에 다시 둔다.
    linkSection(art, "이어서 배울 것", page.after, false);
    linkSection(art, "과목 사이 연결", page.links, true);
    if (page.references && page.references.length) {
      var rs = el("section", "refs");
      rs.appendChild(el("h2", null, "더 볼 자료"));
      page.references.forEach(function (r) {
        var b = el("button", "ref");
        b.type = "button";
        b.appendChild(el("span", "ref-title", esc(r.title)));
        b.appendChild(el("span", "ref-kind", esc(r.kind)));
        if (r.why) b.appendChild(el("span", "ref-why", esc(r.why)));
        b.addEventListener("click", function () { post({ type: "openURL", url: r.url }); });
        rs.appendChild(b);
      });
      art.appendChild(rs);
    }
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
    // 같은 개념을 다시 그릴 때(코멘트를 단 뒤 등)는 읽던 자리를 지킨다
    window.scrollTo(0, same ? keepY : 0);
    watchEdges(around);
    arrive(around);
    // 화면 찍기: 코멘트 스레드와 새 판 비교를 펼치고 그 자리로 내려 연다
    if (page.debug) {
      // 앞뒤 개념 지도: 좁은 폭으로 그리거나, 한 개념에서 이웃을 눌러 옮겨 간다
      if (page.debug.narrow) art.style.maxWidth = page.debug.narrow + "px";
      if (page.debug.openMap) setTimeout(function () { var a = document.querySelector(".nbr-all"); if (a) a.click(); }, 300);
      if (page.debug.walk && page.debug.walk[0] === page.concept) {
        setTimeout(function () {
          var n = document.querySelector('.nbr .nm[data-id="' + CSS.escape(page.debug.walk[1]) + '"]');
          if (n) n.click();
        }, 300);
      }
      if (page.debug.openThreads) Array.prototype.forEach.call(document.querySelectorAll(".g-cm.has"), function (b) { b.click(); });
      if (page.debug.openCompare) Array.prototype.forEach.call(document.querySelectorAll(".dir-open"), function (b) { b.click(); });
      if (page.debug.openEasy) Array.prototype.forEach.call(document.querySelectorAll(".g-side"), function (b) { b.click(); });
      if (page.debug.scrollTo) setTimeout(function () { var t = document.querySelector(page.debug.scrollTo); if (t) t.scrollIntoView({ block: "start" }); }, 400);
    }
    // 그림 블록까지 내려 연다 (화면 찍기)
    if (page.scrollToFigure) {
      var fig = document.querySelector("figure.fig");
      if (fig) setTimeout(function () { fig.scrollIntoView({ block: "start" }); }, 300);
    }
  }

  // 렌더러 오류는 앱에 알린다 (앱이 기록에 남긴다)
  window.addEventListener("error", function (e) { post({ type: "error", message: String(e.message) + " (" + e.lineno + ")" }); });
  window.jindesk = {
    render: function (page) {
      try { render(page); } catch (e) { post({ type: "error", message: String(e && e.stack ? e.stack : e) }); throw e; }
    },
  };
  document.addEventListener("DOMContentLoaded", function () { post({ type: "ready" }); });
})();
