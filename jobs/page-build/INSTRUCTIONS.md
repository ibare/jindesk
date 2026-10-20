# 학습 페이지 만들기 지침

지침 버전: `0.9`

이 문서는 학습 페이지 에이전트가 따르는 유일한 지침이다. 에이전트는 개념 하나의 원문(`input/concept.yaml`)으로 학생이 공부할 페이지를 짠다. 문단의 글은 원문 단위의 글을 러너가 그대로 넣는다. 에이전트가 정하는 것은 문단의 차례, 그 사이에 둘 수식 블록과 그림 블록과 강조 상자, 한국어 제목이다. 그림 블록은 에이전트가 HTML·JavaScript 로 직접 짠다. 외국어를 배우는 과목이면 7장이 앞의 장보다 먼저다.

## 1. 원칙

1. **원문이 기준이다.** 문단은 원문 단위 하나에 하나다. 문단 글을 고쳐 쓰지 않는다(러너가 원문 글을 넣는다). 원문에 없는 수치나 주장을 강조 상자에 더하지 않는다.
2. **영어로 쓴다.** 강조 상자의 글, 수식, 그림 안의 글자와 설명은 영어다. 한국어는 `title_ko` 하나뿐이다. 한자, 일본어를 쓰지 않는다.
3. **원래 자료 없이 읽혀야 한다.** "slide 3", "see the diagram above" 같은 말을 쓰지 않는다.
4. **덜어 내는 쪽을 고른다.** 블록과 상자는 학생이 그 자리에서 멈춰 볼 것이 있을 때만 둔다. 문단을 되풀이하는 상자는 두지 않는다.
5. **질문하지 않는다.** 무인으로 돈다.

## 2. 작업 공간

```
input/request.md      개념 id, 제목, 과목, 학년·수준, 원문 단위 id 목록, 이 개념이 나온 자료가 밝힌 학습 목표
input/concept.yaml    개념 원문: 단위(id, 글, 조건, 주장과 출처), 기호
input/page.yaml       이전 페이지 (request.md 에 있다고 적혀 있을 때만). 다시 만들 때 이전 구성을 참고한다
input/glossary.yaml   용어 어휘 (아직 없으면 terms 가 비어 있다)
out/page.json         페이지 구성
out/figures/          그림 블록의 HTML 조각
```

## 3. 단위 종류

| `kind` | 무엇 | 쓰는 것 |
|---|---|---|
| `para` | 원문 단위 하나의 문단 | `from`만. 글은 러너가 넣는다 |
| `block` | 따로 선 수식 (`block.type`은 `math`) | `from`, `block.tex` |
| `block` | 풀이 (`block.type`은 `derivation`) | `from`, `block.title`, `block.steps`, `block.vars`, `block.check` (3.1) |
| `block` | 그림 (`block.type`은 `figure`) | `from`, `block.file`, `block.title`, `caption` (4장) |
| `check` | 확인 문제 | `from`, `question`, `answer`, `solution`, `verify` (3.2) |
| `note` | 강조 상자 | `from`, `note`, `text`, `prov` |

- 원문 단위마다 `para`가 꼭 하나 있다. 빠지거나 둘이면 러너 검사에서 틀린다.
- `from`은 그 단위가 기대는 원문 단위 id 다. 블록과 상자도 가장 가까운 원문 단위를 `from`으로 둔다.
- **글 속의 수식.** 문단, 상자, 단계의 까닭, 확인 문제, 그림 설명(`caption`)에 나오는 수식은 모두 `\( … \)`(선 수식은 `\[ … \]`) 안에 TeX 로 쓴다. `7^(-1)`, `log_7(x)`, `sqrt(8)`처럼 글자로 쓰면 그려지지 않는다.
- **수식 블록(`math`).** 학생이 외우고 쓸 핵심 공식을 문단 뒤에 따로 세워 둘 때 쓴다. 문단 안에 이미 `\[ … \]`로 선 수식을 되풀이하지 않는다. `tex`는 TeX 이고 `\[ \]`로 감싸지 않는다. KaTeX 가 그리는 명령만 쓴다. JSON 안이므로 역슬래시는 두 번 쓴다.
- **강조 상자(`note`).** `note` 값은 셋 가운데 하나다.
  - `misconception`: 원문이 짚은 흔한 실수. 무엇이 틀렸고 왜 틀렸는지 한두 문장.
  - `key-idea`: 이 개념에서 꼭 가져갈 한 가지. 원문의 주장을 짧게 다시 말한다.
  - `command-term`: 원문에 나온 IB 명령어(예: "Show that", "Hence")가 무엇을 요구하는지.
- `prov`는 상자의 내용이 원문에 있으면 `source`, 원문 밖 일반 지식이면 `added`다. 명령어 설명은 대개 `added`다. `added`인 상자는 화면에 "보충"으로 보인다.

### 3.1 풀이 블록 (`derivation`)

원문 단위에 풀이한 예제가 있으면, 그 풀이를 한 단계씩 보이는 풀이 블록을 그 문단 뒤에 둔다. 문단은 그대로 둔다.

- 단계는 원문의 풀이를 따른다. 원문에 없는 풀이를 새로 만들지 않는다.
- 단계마다 `tex`(그 단계의 식. 등식 전체를 써도 된다)와 `why`(그렇게 하는 까닭, 영어 한 문장)를 쓴다. `why`가 없는 단계가 있으면 러너 검사에서 틀린다.
- **계산 검사.** 러너가 계산으로 확인할 수 있게 한다. 하나 이상은 있어야 한다.
  - 단계에 `expr`(계산할 수 있는 식)를 주면, 이웃한 `expr` 단계를 `vars`의 범위 안 표본 값에 넣어 같은 값인지 계산한다. 식을 정리하는 풀이에 쓴다.
  - 등식을 푸는 풀이는 `check.equation`(처음 등식)과 `check.solution`(답)을 준다. 러너가 답을 넣어 등식이 성립하는지 계산한다.
  - `\approx`로 반올림한 단계는 적힌 자리 수 안에서 같으면 된다.
  - `expr`의 문법: 수, 변수, `+ - * / ^`, 괄호, `sqrt ln log(x) log(x, b) exp abs sin cos tan asin acos atan`, 상수 `pi e`. `log(x)`는 밑이 10, `log(x, b)`는 밑이 b 다. 곱하기는 반드시 `*`로 적는다(`2*x`).

```json
{ "kind": "block", "from": "u4", "block": {
  "type": "derivation", "title": "Solve \\(2^x = 17\\)",
  "steps": [
    { "tex": "2^x = 17", "why": "Start from the equation." },
    { "tex": "x = \\log_2 17", "why": "Rewrite it in logarithmic form.", "expr": "log(17, 2)" },
    { "tex": "x = \\frac{\\log 17}{\\log 2}", "why": "Change to base 10 so a calculator can evaluate it.", "expr": "log(17)/log(2)" },
    { "tex": "x \\approx 4.09", "why": "Round to 3 significant figures.", "expr": "4.09" }
  ],
  "check": { "equation": "2^x = 17", "solution": { "x": "log(17, 2)" } }
} }
```

### 3.2 확인 문제 (`check`)

페이지 끝에 한두 개 둔다. 방금 읽은 것을 바로 써 보는 짧은 문제다.

- `input/request.md`의 학습 목표 가운데 이 개념에 해당하는 목표마다, 그 목표를 연습하는 문제를 하나 이상 둔다. 목표가 해석·비교·추론·설명을 요구하면 계산만 시키지 않고 그것을 묻는다(예: "값 하나가 바뀌면 평균과 표준편차는 어떻게 되는가, 왜 그런가", "두 집단을 비교하라"). 그런 문제의 `answer`와 `solution`에는 해석과 까닭을 쓴다. 해당하는 목표가 많으면 문제가 셋 이상이어도 된다. 목표가 여러 개념을 묶어 말하면 이 개념이 맡는 부분만 묻는다. 다른 개념의 내용은 그 개념의 페이지가 묻는다.

- 원문 단위의 내용만으로 풀 수 있어야 한다. 원문의 예제와 같은 모양에 수만 바꾼 문제가 좋다.
- 평가 과제(형성평가, 총괄평가)의 문제를 옮기지 않는다.
- `question`, `answer`(짧게), `solution`(한두 줄 풀이)을 영어로 쓴다. 답을 계산으로 확인할 수 있으면 `verify`를 준다: `{ "expr": "log(64, 4)", "equals": "3" }`.
- 자료에 없는 새 문제이므로 화면에는 "보충"으로 보인다.

## 4. 그림 블록

그래프, 조작해 보는 실험, 작도, 데이터 표처럼 보고 만지면 이해가 달라지는 것을 그림 블록으로 짠다. 종류는 정해져 있지 않다.

- **언제 두나.** 학생이 직접 바꿔 보며 규칙을 보는 것이 글보다 나을 때 둔다. 예: 밑을 바꾸며 지수 함수의 그래프가 어떻게 변하는지, 두 그래프의 교점이 방정식의 해라는 것, 값을 넣어 보며 성질이 성립하는지. 페이지에 하나나 둘이면 된다. 글을 그림으로 되풀이하거나 꾸미기만 하는 그림은 두지 않는다.
- **무엇을 그리나.** 그 블록이 기대는 원문 단위(`from`)가 말하는 것을 그린다. 원문에 없는 수치나 주장을 더하지 않는다. 원문에 예가 있으면(예: \(2^x = 17\)) 그 예로 시작한다.
- **파일.** `out/figures/<이름>.html`에 HTML 조각 하나를 쓴다. `<html>`, `<head>`, `<body>` 없이 요소, `<style>`, `<script>`, SVG, Canvas 를 쓴다. 러너가 블록 틀의 `<div id="figure">` 안에 넣는다.
- **라이브러리.** 필요하면 CDN 에서 판을 정확히 적어 부른다: `https://cdn.jsdelivr.net/npm/d3@7.9.0/+esm`, `https://cdnjs.cloudflare.com/ajax/libs/...`, `https://unpkg.com/...`. ES 모듈은 `<script type="module">`에서 `import`한다. 러너가 처음 검사할 때 그 파일들을 받아 두고, 보일 때는 받아 둔 사본을 쓴다. 그래서:
  - 바깥 파일은 처음 열 때 모두 부른다. 조작한 뒤에야 부르는 파일은 받아 두지 못한다.
  - 데이터 API, 글꼴 서비스, 지도 타일처럼 그때그때 받는 것은 쓰지 않는다.
- **공통 부품.** 블록 틀에 `window.JD`와 KaTeX(`katex`)가 있다. 쓰지 않아도 된다.
  - `JD.colors()`: `ink`, `ink2`, `ink3`, `line`, `paper`, `paper2`, `accent`, `good`, `bad`, `series`(색 여섯). 밝은 화면과 어두운 화면에 맞는 값이다. 화면이 바뀌면 다시 읽도록 그릴 때마다 부른다.
  - CSS 변수: `--ink`(글자), `--ink-2`(덜 진한 글자, 눈금 숫자), `--ink-3`(옅은 글자, 보조선), `--line`(격자), `--paper`, `--paper-2`, `--accent`, `--good`, `--bad`, `--s1`…`--s6`(계열 색). 축 눈금과 축 이름에는 `--ink-2` 보다 옅은 색을 쓰지 않는다.
  - `JD.slider(부모, { label, min, max, step, value, unit, format, oninput })`: 이름과 값이 붙은 슬라이더. 만든 `input`을 돌려준다.
  - `JD.math(요소)`: 요소 안의 `\( … \)`를 KaTeX 로 그린다. `JD.math(요소, tex, display)`는 그 수식을 그린다.
  - `JD.graph(부모, { x: [아래, 위], y: [아래, 위], height, xLabel, yLabel, grid })`: 눈금과 격자가 있는 좌표 평면(SVG). `g.draw(function (g) { … })` 안에서 `g.fn(x => 2 ** x, { color, label, dash, from, to })`, `g.point(x, y, { label })`, `g.hline(y)`, `g.vline(x)`, `g.segment(x1, y1, x2, y2, { dash, label })`, `g.area(f, a, b)`, `g.text(x, y, "…")`로 그린다. 조작이 바뀌면 `g.redraw()`. 너비와 밝은·어두운 화면이 바뀌면 저절로 다시 그린다. `g.fromX(px)`, `g.fromY(py)`는 끌기 조작에 쓴다.
  - `JD.player(부모, { duration, onFrame: function (t) { … } })`: 재생·멈춤·되감기와 진행 막대. `t`는 0 에서 1. 움직임 줄이기면 마지막 장면만 보인다.
  - `JD.onResize(함수)`: 너비가 바뀌면 다시 그린다.
  - `JD.reducedMotion`: 움직임 줄이기 설정.
  - 클래스: `jd-controls`(조작 칸 격자), `jd-row`(가로로 놓기), `jd-note`(작은 설명 글), `jd-readout`(값 읽기 칸). 값 읽기 칸은 `<div class="jd-readout"><div><small>x</small><b>4.09</b></div><div><small>y</small><b>17</b></div></div>`처럼 칸마다 `div`를 둔다. 문장은 `<p class="jd-note">`에 쓴다.
- **모양.**
  - 너비는 부모에 맞춘다. 고정 너비를 쓰지 않는다(대개 700px 안팎, 좁아질 수 있다). 높이는 480px 안쪽.
  - 색은 테마 색으로 쓴다. 밝은 화면과 어두운 화면 모두에서 보여야 한다.
  - 그림 안의 글자, 축 이름, 조작의 이름은 영어다.
  - 움직임 줄이기 설정이면 움직임을 멈추고 마지막 장면을 보인다.
  - `localStorage`, 쿠키, 팝업, 바깥 링크를 쓰지 않는다.
- **`caption`.** 그림을 어떻게 보고 만지는지 한두 문장(영어). 번역된다.
- **검사.** 러너가 화면 밖 웹 보기(너비 720px)에서 블록 틀에 넣어 연다. 스크립트 오류가 없고, 3초 안에 무언가 그려지고, 그 뒤에도 응답해야 한다. 처음 장면에서 보이는 글자(이름표, 설명)끼리 겹치지 않아야 한다. 틀리면 오류 내용을 받고 한 번 고쳐 쓴다. 그래도 틀리면 그 그림 블록만 빠지고 페이지는 만들어진다. 그림이 내용에 맞는지는 검사하지 않는다. 글이 기준이고, 그림이 이상하면 학생이 알린다.

## 5. `out/page.json`

```json
{
  "title_ko": "로그의 법칙",
  "units": [
    { "kind": "para", "from": "u1" },
    { "kind": "para", "from": "u2" },
    { "kind": "block", "from": "u2", "block": { "type": "math", "tex": "\\log_a(xy) = \\log_a x + \\log_a y" } },
    { "kind": "note", "from": "u2", "note": "misconception", "prov": "source", "text": "\\(\\log_a(x + y)\\) is not \\(\\log_a x + \\log_a y\\): the product rule needs a product inside the logarithm." },
    { "kind": "para", "from": "u3" },
    { "kind": "block", "from": "u3", "block": { "type": "figure", "file": "product-rule-check.html", "title": "Check the product law with numbers" }, "caption": "Move the sliders for x and y and compare the two sides of the product law." }
  ]
}
```

- `title_ko`: 개념 제목의 한국어. 어휘에 있는 용어는 그 한국어를 쓴다. 한국 교과서에서 쓰는 말을 고른다.
- `units`: 페이지에 보일 차례. 대개 원문 단위의 차례를 따른다.

## 6. 러너 검사

틀리면 같은 세션에서 문제 목록을 받고 한 번 고쳐 쓴다. 그래도 틀리면 이 페이지는 이번에 만들지 않는다.

- 원문 단위마다 `para`가 하나씩 있다. `from`이 원문 단위 id 다.
- `note` 값과 `prov` 값이 정해진 것이다.
- 풀이 블록의 단계마다 수식이 파싱되고, 계산 검사(`expr`, `check`)가 맞는다. 확인 문제의 `verify`가 맞는다.
- 그림 블록의 파일이 있고 HTML 조각이다. 제목과 설명이 영어다. 화면 밖 웹 보기에서 돌아간다(4장의 검사).
- 영어 칸에 한글, 한자, 일본어가 없다. `title_ko`는 한국어다.
- 모든 수식이 KaTeX 로 파싱된다. 글 속에 TeX 밖에 글자로 쓴 수식(`7^(-1)`, `log_7`, `sqrt(`)이 없다.
- **학습 목표 시험.** 도구 없는 판정자가 페이지 전체를 읽고, 이 개념에 해당하는 학습 목표마다 그것을 연습하는 확인 문제가 있는지 본다. 목표가 해석·설명을 요구하는데 계산 문제만 있으면 없는 것이다. 없으면 빠진 것과 함께 받아 한 번 고쳐 쓴다.

## 7. 언어 습득 과목

`input/request.md`에 "과목 갈래: 언어 습득"이 있으면 학생이 목표 언어(예: Spanish)를 배우는 과목이다. 원문 단위는 문법 요점, 낱말 세트, 표현 묶음, 글 종류 가운데 하나를 설명한다. 이 장이 앞의 장과 다르면 이 장을 따른다.

- **확인 문제(3.2).** 학습 목표 가운데 이 개념에 해당하는 것마다 목표 언어를 쓰거나 읽는 문제를 둔다. 모양은 넷 가운데 고른다.
  - **활용:** 형태를 쓴다. 예: "Give the *yo* form of *comer* in the preterite." 답 *comí*.
  - **문장 만들기:** 주어진 낱말이나 문장 틀로 문장을 쓴다. 예: "Use *ir a* + infinitive to say one thing you will do this weekend."
  - **고쳐 쓰기:** 틀린 문장을 고치거나, 시제와 인칭을 바꿔 쓴다.
  - **짧은 읽기:** 목표 언어로 된 두세 문장을 주고 뜻이나 형태를 묻는다.

  문제의 지시는 영어이고, 문제 속 글과 답은 목표 언어다. 답이 여럿일 수 있는 문제(문장 만들기)는 `answer`에 본보기 하나를 쓰고, `solution`에 맞는 답의 조건(써야 할 형태, 일치)을 쓴다. 주제 내용의 까닭이나 해석을 묻는 문제("Why is recycling important?")는 두지 않는다. `verify`는 쓰지 않는다.
- **강조 상자.** `misconception`은 자주 틀리는 형태와 헷갈리는 짝(*ser*/*estar*, *por*/*para*, 성·수 일치, 뜻이 다른 비슷한 낱말)이다. `key-idea`는 형태 규칙 한 줄이다.
- **블록.** 수식 블록과 풀이 블록은 쓰지 않는다. 그림 블록은 형태가 바뀌는 모양을 보고 만질 때 둔다. 예: 동사를 고르면 인칭마다 어미가 바뀌는 것을 강조해 보이는 활용표, 문장 틀에 낱말을 바꿔 끼워 보는 문장 만들기. 그림 안의 목표 언어는 원문 단위의 철자 그대로 쓴다. 설명과 조작 이름은 영어다.
- **`title_ko`.** 문법 이름은 한국에서 외국어 문법을 가르칠 때 쓰는 말로 쓴다(예: "규칙 동사의 단순과거", "환경 낱말", "의견 말하기"). 목표 언어 낱말이 이름이면 그대로 둔다(예: "ser 와 estar").
