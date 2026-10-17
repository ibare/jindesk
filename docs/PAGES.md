# 학습 페이지

개념 하나가 학습 페이지 하나다. 페이지는 `page.yaml`(단위와 블록 명세)과 `layers.yaml`(곁 층)이고, 화면은 여기에 코멘트, 용어 어휘, 관점을 더해 그때그때 조합해 그린다. 시안은 `prototype/index.html`의 "앱 화면" 탭이다.

## 단위

| 종류 | `kind` | 무엇 |
|---|---|---|
| 문단 | `para` | 영어 설명 한 문단. 원문 단위 하나에서 온다 |
| 블록 | `block` | 수식, 풀이, 그리고 그래프·실험·회로 같은 그림 (아래 블록) |
| 풀이 단계 | `step` | 풀이 블록 안의 한 단계. 단계마다 코멘트와 번역이 붙는다 |
| 강조 상자 | `note` | 흔한 오해(`misconception`), 명령어(`command-term`), 핵심(`key-idea`) |
| 확인 문제 | `check` | 문제, 풀이, 채점 기준, 답 |
| 연결 | `link` | 다른 개념(다른 과목 포함)으로 가는 카드 |

단위마다 갖는 필드는 다음과 같다.
- `id`, `rev`(판)
- `from`: 원문 단위 id 와 해시
- `text` 또는 블록 명세
- `claims`(주장과 출처), `conditions`(조건), `symbols`(쓴 기호)
- `prov`: `source`(자료에 있음) 또는 `added`(보충)
- `directives`: 적용된 요구

이 구조 덕분에 부분 다시 만들기, 번역, 코멘트가 모두 단위를 기준으로 붙는다.

## 언어

- **영어**로 쓰는 것: 모든 단위의 글, 블록 제목, 그림 안의 글자, 슬라이더 같은 조작의 이름, 확인 문제. IB 수업과 시험이 영어이기 때문이다.
- **한국어**로 쓰는 것: 앱의 메뉴와 안내, 러너 검사 줄, 시트의 설명, 곁 층의 한국어.
- **한국어는 문단 곁에 둔다.** 문서 전체를 한국어로 바꾸는 전환은 두지 않는다.
  - 단위 끝의 `한` 단추를 누르면 그 단위 바로 아래에 한국어가 펼쳐진다. 영어는 그 자리에 그대로 있다.
  - 여러 단위를 함께 펼쳐 둘 수 있다. 페이지 머리에 "한국어 N개 펼침 · 모두 접기"가 보인다.
  - 풀이 단계처럼 좁은 칸의 단위는 그 줄 아래 전체 폭에 펼친다.
- **용어 어휘.** 본문의 IB 용어는 점선 밑줄로 보이고, 포인터를 올리면(또는 초점을 주면) 한국어 뜻이 보인다. 같은 영어 용어는 늘 같은 한국어로 옮긴다(`glossary.yaml`).
- 페이지 제목 아래에는 한국어 제목을 작게 둔다.

```yaml
# library/glossary.yaml
kind: "glossary"
v: 1
terms:
  - { en: "secant", ko: "할선", aliases: ["secant line"], subjects: ["math-aa"] }
  - { en: "potential difference", ko: "전위차", aliases: ["p.d."], subjects: ["physics"] }
  - { en: "standard enthalpy of combustion", ko: "표준 연소 엔탈피", subjects: ["chemistry"] }
```

## `page.yaml`

```yaml
kind: "page"
v: 1
concept: "physics/a.1/projectile-motion"
title_ko: "투사체 운동"
next_id: 14
units:
  - id: "p1"
    rev: 2
    kind: "para"
    from: "u3@a41f09c2d7e8b153"
    prov: "source"
    text: |
      Without air resistance, no force acts horizontally, so the horizontal
      velocity stays constant. Vertically, gravity gives a constant downward
      acceleration \(g\). Solve the two directions separately and link them
      through the time \(t\).
    conditions: ["no air resistance"]
    claims:
      - { id: "c1", text: "no horizontal force", src: ["20260903-3fa2c1d0#p12"] }
      - { id: "c2", text: "horizontal velocity constant", src: ["20260903-3fa2c1d0#p12"] }
      - { id: "c3", text: "vertical acceleration g downward", src: ["20260903-3fa2c1d0#p12"] }
    symbols: ["g", "t"]
    terms: ["air resistance"]
    directives: ["d7"]
  - id: "b2"
    rev: 1
    kind: "block"
    from: "u4@77b0e1a95c3d2f60"
    block:
      type: "figure"
      v: 1
      title: "Launch at different angles and speeds"
      code: "figures/b2-r1.html"
      code_hash: "c90d3e1f7a2b4c68"
      parts: 1
    caption: |
      The ball rests at the highest point until you launch it. Compare the solid
      and dashed paths: complementary angles land at the same place.
provenance: { job: "20260905-1010-page-physics", instructions: { kind: "page-build", version: "0.1", commit: "…", dirty: false }, model: "claude-opus-5-5" }
```

## `layers.yaml`

곁 층은 단위마다 한국어(`ko`), 쉽게(`easy`), 자세히(`detail`)를 둘 수 있다. 쉽게·자세히는 영어로 쓰고 그 한국어도 함께 둔다. `from`은 어느 단위의 몇 판에서 만들었는지다. 지금 판과 다르면 낡은 것이다.

```yaml
kind: "layers"
v: 1
concept: "physics/a.1/projectile-motion"
units:
  p1:
    ko:
      from: "p1@r2"
      unit_hash: "5be2c0d4a8e91f37"
      text: |
        공기 저항이 없으면 수평 방향으로는 힘이 작용하지 않아 수평 속도가 그대로다. …
      prov: { job: "20260921-2002-translate-physics", instructions: { kind: "translation", version: "0.1" } }
    easy:
      from: "p1@r1"
      directive: "d3"
      en: |
        If we ignore air resistance, think of the two directions as two separate stories. …
      ko: |
        공기 저항을 무시하면 두 방향을 따로 떨어진 두 이야기로 생각할 수 있다. …
      checks: ["conditions kept", "claims c1-c3 kept", "no new claims", "reader MYP 10 passed"]
```

## 블록

블록은 두 갈래다. 글에 가까운 수식과 풀이는 데이터로 쓰고 글처럼 검사한다. 그 밖의 그림과 인터랙션은 에이전트가 코드로 짠다(`DECISIONS.md` 18).

### 글 블록

| `type` | 명세 | 러너 검사 | 렌더러 |
|---|---|---|---|
| `math` | TeX | KaTeX 파싱, 허용한 명령만 | 수식 |
| `derivation` | 단계마다 TeX 과 이유(`step` 단위) | 단계마다 파싱, 이웃 단계를 정의역의 표본 값에 넣어 같은 값인지 계산, 마지막 식을 값에 넣어 계산 | 한 단계씩 펼치기 |

글 블록마다 `type`과 `v`가 있다. 렌더러는 지금 판과 한 단계 전 판을 읽는다. 그보다 오래된 판은 마이그레이션으로 올린다.

### 그림 블록 (`figure`)

그래프, 실험, 회로, 분자, 반응 경로, 데이터 표, 도표처럼 보고 만지는 것은 모두 그림 블록이다. 종류를 미리 정해 두지 않는다.

**에이전트가 쓰는 것.** HTML 조각 하나다(`out/figures/<이름>.html`). `<style>`, `<script>`, SVG, Canvas 를 마음대로 쓰고, 슬라이더나 단추, 끌기 같은 조작도 그 안에서 만든다.

**라이브러리.** 미리 정해 둔 목록이 없다. 에이전트는 필요한 라이브러리(three.js, D3, Plotly 같은 것)를 CDN 주소로 마음대로 불러 쓴다(`DECISIONS.md` 19).
- 러너는 돌아가는지 확인할 때 네트워크를 열어 두고, 그 그림이 불러간 파일을 모두 데이터 폴더의 `library/vendor/<호스트>/<경로>`에 받아 둔다. 같은 주소는 한 번만 받는다.
- 그림 코드는 원래 주소 그대로 저장한다. 보일 때는 앱이 `https://` 주소를 앱 전용 주소로 바꿔 받아 둔 사본을 돌려준다. 라이브러리 안에서 다른 파일을 불러도 같은 방식으로 찾는다.
- 그래서 보는 동안에는 네트워크를 쓰지 않고, CDN 의 파일이 바뀌거나 사라져도 그림은 그대로다.

**블록 틀.** 러너가 조각을 블록 틀에 넣는다. 틀은 관리자가 만들어 앱 번들(`renderer/`)에 넣는다. 틀에는 다음이 들어 있다.
- 테마 색 변수(밝은 화면, 어두운 화면)와 글꼴
- KaTeX
- 공통 부품: 슬라이더, 좌표축과 눈금, 단위 표시 같은 것. 쓰면 모양과 조작감이 페이지마다 맞는다. 안 써도 된다
- 움직임 줄이기 설정 값
- 내용 높이를 페이지에 알려 iframe 높이를 맞추는 일

**지침으로 정하는 것.** 러너가 검사하지 않는다.
- 그림 안의 글자와 조작의 이름은 영어다.
- 색은 테마 변수로 쓴다.
- 그 블록이 온 원문 단위가 말하는 것을 그린다. 원문에 없는 수치나 주장을 더하지 않는다.
- 움직임 줄이기 설정이면 움직임을 멈추고 마지막 장면을 보인다.
- 바깥 파일(라이브러리, 글꼴, 데이터)은 처음 열 때 모두 불러온다. 조작한 뒤에야 부르는 파일은 받아 두지 못한다.

**러너 검사: 돌아가는지만 본다.** 앱 안의 화면 밖 WKWebView 에서 블록 틀에 넣어 열고 다음을 본다.
- 스크립트 오류가 없다.
- 정해진 시간(기본 3초) 안에 무언가 그려진다. 스냅샷이 배경색 한 가지가 아니다.
- 멈추지 않는다. 그 뒤 몇 초 동안 페이지가 응답한다.

틀리면 오류 내용을 주고 같은 세션을 이어 한 번 고쳐 쓰게 한다. 그래도 틀리면 그 블록만 넣지 않고 기록에 남긴다. 그림이 내용에 맞는지는 검사하지 않는다. 글이 바르게 서 있으면 학생이 이상한 그림을 알아채고 "이상해요"나 "그림 다시"로 고친다.

**저장.** 러너가 코드를 개념 폴더의 `figures/<단위 id>-r<판>.html`로 옮긴다. 판마다 파일 하나이고 고치지 않는다. 명세에는 파일 경로, 코드 해시, 쓴 공통 부품 판(`parts`)을 둔다(위 `page.yaml`의 `b2`).

**공통 부품 판.** 부품은 하위 호환을 지킨다. 깨지는 변경이 필요하면 부품 판을 올린다. 옛 판은 그 판을 쓴 그림 블록이 남아 있는 동안 번들에 두고, 그 블록들은 낡은 것으로 표시해 천천히 다시 만든다.

**실행.** 블록마다 iframe 하나에서 돈다. 한 그림이 깨지거나 멈춰도 페이지의 나머지는 살아 있다.

## 출처와 보충

- 문단과 강조 상자 앞에는 `자료` 또는 `보충` 표시가 붙는다.
- 끝에는 출처 칩("slides · 12")이 있다. 누르면 원래 자료의 그 쪽 이미지가 열리고, 이 단위가 가리키는 곳을 표시한다.
- 인스펙터에는 그 개념의 출처 자료와 쪽 범위가 있다.

## 코멘트

- 단위 끝의 `✎`를 누르면 그 단위 아래에 스레드가 열린다. 코멘트가 있으면 단추에 수가 보인다.
- **종류.**
  - 메모: 학생이 자기를 위해 남긴다.
  - 질문: 물어보기 작업이 영어로 답하고 한국어를 붙인다. 출처 칩도 단다.
  - 이상해요: 관리자가 지침을 고칠 때 본다. 부분 다시 만들기 요청으로 보낼 수도 있다.
- **자리 찾기.** 코멘트는 단위 id, 판, 인용(영어 원문의 앞부분)으로 자리를 찾는다. 단위가 새 판이 되면 "이전 판에 단 코멘트"로 보이고, 인용으로 원래 문장을 보인다.
- **인스펙터.** 그 페이지의 코멘트 목록이 있다. 누르면 그 단위로 가서 스레드를 연다.
- 데이터 모양은 `DATA.md`의 `comments.jsonl`이다.

## 렌더러

- 학습 페이지는 WKWebView 안에서 번들 렌더러(`renderer/`)가 그린다. 화면의 나머지(사이드바, 목록, 인스펙터, 시트)는 SwiftUI 다.
- **불러오기.** 렌더러는 앱 전용 주소 체계(`jindesk-page://`, `WKURLSchemeHandler`)로 앱 번들에서만 불러온다.
- **페이지 정책.** `default-src 'none'`이고 스크립트·스타일·글꼴·이미지는 그 주소 체계에서만 받는다. 네트워크를 쓰지 않는다. KaTeX 와 글꼴은 번들에 넣는다. 그림 블록의 iframe 은 인라인 스크립트와 스타일을 쓸 수 있다. 바깥 라이브러리는 만들 때 받아 둔 사본으로 불러온다(위 그림 블록의 라이브러리). 보는 동안에는 네트워크를 쓰지 않는다.
- **조합.** Swift 가 페이지를 조합해 렌더러에 JSON 하나로 넘긴다. 들어가는 것은 단위, 곁 층, 이 페이지의 코멘트, 용어, 관점, 낡은 단위 표시, 화면 상태(펼친 곳)다.
- **렌더러 → Swift.** 메시지로 보낸다(`WKScriptMessageHandler`). 메시지는 출처 열기, 곁 층 펼침 상태, 코멘트 남기기, 다시 만들기 요청, 새 판 받아들이기·유지하기다. 메시지마다 스키마로 검증한다.
- 글 블록은 렌더러가 `type`마다 모듈 하나로 그린다. 그림 블록은 블록마다 iframe 에서 블록 틀과 함께 돈다.
- 밝은 화면과 어두운 화면은 CSS 변수로 맞춘다. 블록 틀이 같은 변수를 그림 블록에 준다.
- 움직임을 줄이는 설정은 블록 틀이 그림 블록에 넘긴다.

## 화면

- **사이드바.**
  - 오늘: 다시 볼 개념, 새로 정리됨
  - 과목
  - 모아 보기: 과목 사이 연결, 원래 자료, 확인 문제, 코멘트
  - 작업: 진행 중인 작업과 미뤄진 작업
- **목록.** 고른 과목의 강의 계획 목차다.
  - 항목마다 개념이 있고, 자료가 있는 항목은 ●, 없는 항목은 ○ 다.
  - 맨 아래에 "목차 밖 · 확인할 것"이 있다.
  - 개념 이름은 영어이고, 한국어 이름은 도움말로 보인다.
- **학습 페이지.** 단위 끝에 차례로 둔다.
  - `한`: 한국어
  - `쉽게`: 곁 설명이 있을 때
  - `✎`: 코멘트
  - `↻`: 다시 만들기
  - `새 판 · 비교`: 후보가 있을 때

  블록 머리에는 "↻ 다시 만들기"가 있다.
- **인스펙터.** 출처(자료와 쪽), 관점, 먼저 알아야 할 것, 과목 사이 연결, 이 페이지의 코멘트.
- **시트.**
  - 자료 넣기: 과목, 메모, 목차의 근거 표시, 뺀 파일과 까닭
  - 다시 만들기: `REGENERATION.md`
  - 원래 자료 보기
  - 백업 만들기
  - 관리자 설정: 모델, 상한, 동시 실행 수, 금지어. 학생 화면에서는 감춘다
