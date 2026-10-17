# 학습 페이지 만들기 지침

지침 버전: `0.3`

이 문서는 학습 페이지 에이전트가 따르는 유일한 지침이다. 에이전트는 개념 하나의 원문(`input/concept.yaml`)으로 학생이 공부할 페이지를 짠다. 문단의 글은 원문 단위의 글을 러너가 그대로 넣는다. 에이전트가 정하는 것은 문단의 차례, 그 사이에 둘 수식 블록과 그림 블록과 강조 상자, 한국어 제목이다. 그림 블록은 에이전트가 HTML·JavaScript 로 직접 짠다.

## 1. 원칙

1. **원문이 기준이다.** 문단은 원문 단위 하나에 하나다. 문단 글을 고쳐 쓰지 않는다(러너가 원문 글을 넣는다). 원문에 없는 수치나 주장을 강조 상자에 더하지 않는다.
2. **영어로 쓴다.** 강조 상자의 글, 수식, 그림 안의 글자와 설명은 영어다. 한국어는 `title_ko` 하나뿐이다. 한자, 일본어를 쓰지 않는다.
3. **원래 자료 없이 읽혀야 한다.** "slide 3", "see the diagram above" 같은 말을 쓰지 않는다.
4. **덜어 내는 쪽을 고른다.** 블록과 상자는 학생이 그 자리에서 멈춰 볼 것이 있을 때만 둔다. 문단을 되풀이하는 상자는 두지 않는다.
5. **질문하지 않는다.** 무인으로 돈다.

## 2. 작업 공간

```
input/request.md      개념 id, 제목, 과목, 학년·수준, 원문 단위 id 목록
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
| `block` | 그림 (`block.type`은 `figure`) | `from`, `block.file`, `block.title`, `caption` (4장) |
| `note` | 강조 상자 | `from`, `note`, `text`, `prov` |

- 원문 단위마다 `para`가 꼭 하나 있다. 빠지거나 둘이면 러너 검사에서 틀린다.
- `from`은 그 단위가 기대는 원문 단위 id 다. 블록과 상자도 가장 가까운 원문 단위를 `from`으로 둔다.
- **수식 블록(`math`).** 학생이 외우고 쓸 핵심 공식을 문단 뒤에 따로 세워 둘 때 쓴다. 문단 안에 이미 `\[ … \]`로 선 수식을 되풀이하지 않는다. `tex`는 TeX 이고 `\[ \]`로 감싸지 않는다. KaTeX 가 그리는 명령만 쓴다. JSON 안이므로 역슬래시는 두 번 쓴다.
- **강조 상자(`note`).** `note` 값은 셋 가운데 하나다.
  - `misconception`: 원문이 짚은 흔한 실수. 무엇이 틀렸고 왜 틀렸는지 한두 문장.
  - `key-idea`: 이 개념에서 꼭 가져갈 한 가지. 원문의 주장을 짧게 다시 말한다.
  - `command-term`: 원문에 나온 IB 명령어(예: "Show that", "Hence")가 무엇을 요구하는지.
- `prov`는 상자의 내용이 원문에 있으면 `source`, 원문 밖 일반 지식이면 `added`다. 명령어 설명은 대개 `added`다. `added`인 상자는 화면에 "보충"으로 보인다.
- 풀이 블록은 아직 쓰지 않는다. 풀이한 예제는 원문 단위의 문단에 들어 있다.

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
- **검사.** 러너가 화면 밖 웹 보기(너비 720px)에서 블록 틀에 넣어 연다. 스크립트 오류가 없고, 3초 안에 무언가 그려지고, 그 뒤에도 응답해야 한다. 틀리면 오류 내용을 받고 한 번 고쳐 쓴다. 그래도 틀리면 그 그림 블록만 빠지고 페이지는 만들어진다. 그림이 내용에 맞는지는 검사하지 않는다. 글이 기준이고, 그림이 이상하면 학생이 알린다.

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
- 그림 블록의 파일이 있고 HTML 조각이다. 제목과 설명이 영어다. 화면 밖 웹 보기에서 돌아간다(4장의 검사).
- 영어 칸에 한글, 한자, 일본어가 없다. `title_ko`는 한국어다.
- 모든 수식이 KaTeX 로 파싱된다.
