# 데이터

git 을 쓰지 않는다. 모든 산출물은 파일로 쓰고, 백업은 데이터 폴더를 통째로 한다. 파일이 원본이고 SQLite 는 색인이다.

## 네 곳

| 곳 | 위치 | 무엇 | 백업 |
|---|---|---|---|
| 데이터 폴더 | `~/Jindesk/` (처음 켤 때 고른다) | 원본 자료, 글자층, 기록, 정리층, 학생의 코멘트와 요구 | 통째로 |
| 캐시 | `~/Library/Caches/com.mintae.Jindesk/` | SQLite 색인, 쪽 이미지, 렌더러에 넘길 조합 결과 | 하지 않는다. 지워도 다시 만든다 |
| 앱 지원 폴더 | `~/Library/Application Support/com.mintae.Jindesk/` | `work/` 작업 공간, `backups/` 마이그레이션 전 자동 백업, `state.json` 화면 상태, `usage.json` 마지막으로 받은 계정 사용량 | 하지 않는다 |
| 키체인 | 로그인 키체인, 서비스 `com.mintae.Jindesk` | Claude 토큰 | — |

데이터 폴더의 조건은 다음과 같다.
- 앱 번들 안이면 안 된다.
- 쓸 수 있어야 한다.
- iCloud Drive 로 동기화되는 곳이면 경고한다. "데스크탑 및 문서 폴더" 동기화를 켠 `~/Documents`도 여기에 든다. 동기화가 파일을 자리표시자로 내리거나 충돌 사본을 만들 수 있기 때문이다.
- APFS 볼륨이 아니면 경고한다. 마이그레이션의 사본이 APFS 복제(clone)여야 싸다.

캐시는 Time Machine 이 기본으로 빼는 곳이라, Time Machine 을 쓰면 데이터 폴더만 백업된다.

## 데이터 폴더 배치

```
~/Jindesk/
  meta/
    schema.yaml                 스키마 버전, 마이그레이션 이력, 이 폴더를 마지막으로 연 앱 판
    .lock                       작업 중인 프로세스 id. 백업에 들어가도 해가 없다
  syllabus/<과목 id>.yaml       강의 계획 목차 (목차 만들기가 쓴다)
  sources/<자료 id>/
    original.<확장자>            받은 그대로
    source.pdf                  PPT 를 PDF 로 바꾼 것 (PDF 와 사진이면 없다)
    pages/0001.txt …            쪽마다 글자층
    index.md                    쪽 목록, 쪽마다 글자층의 길이와 만든 방법, 이어 채운 쪽 묶음. 에이전트가 먼저 읽는다
    meta.yaml                   받을 때 정해진 사실: 내용 해시, 받은 날, 쪽 수, 바꾼 방법, 글자층. 고치지 않는다
    labels.yaml                 학생이 붙인 것: 꼬리표(학년, 과목, 수준), 메모, 목차의 근거 표시. 고칠 수 있다
  records/
    runs/<YYYY-MM>.jsonl        모든 작업의 실행 요약 (작업 id, 종류, 시작·끝, 결과, 사용량, 지침 판, 모델)
    syllabus-build/<작업 id>/   근거 문서 목록, 결정, 검사 결과
    source-reading/<작업 id>/   request.md, report.md, report.first-pass.md, coverage.json
    concept-curation/<작업 id>/ plan.json, report.md, apply.json
    ask/<작업 id>/              question.json, answer.json, coverage.json
    regen/<작업 id>/            request.json, base.json, candidate.json, checks.json, decision.json
    migration/<시작 버전>-<끝 버전>/  plan.json, checks.json
  library/
    entries/<과목 id>/<항목>/<slug>.md       원시 개념 엔트리. 영어 본문과 머리말 YAML. 고치지 않는다
    concepts/<과목 id>/<항목>/<slug>/
      concept.yaml              정리된 개념 원문 (단위, 주장, 출처, 기호표)
      page.yaml                 학습 페이지 (단위, 판, 블록 명세, 요구)
      layers.yaml               곁 층 (한국어, 쉽게, 자세히)
      facets.yaml               관점
      history.jsonl             페이지 단위의 이전 판
      figures/<단위 id>-r<판>.html  그림 블록 코드. 판마다 파일 하나이고 고치지 않는다
    unplaced/<과목 id>/<slug>/  목차 밖 개념. concepts 와 같은 모양
    links/<slug>.yaml           과목 사이 연결
    glossary.yaml               용어 어휘: 영어 용어 → 한국어
    facets.yaml                 관점 어휘
    references.yaml             레퍼런스 (관점 붙이기가 찾는다)
    vendor/<호스트>/<경로>       그림 블록이 쓰는 바깥 라이브러리 사본. 그림을 만들 때 받는다
  learner/
    comments.jsonl              코멘트와 답글
    directives.jsonl            요구
    practice/<id>/              확인 문제와 푼 기록
```

경로의 `<항목>`은 강의 계획 코드를 소문자로 쓰고, 공백은 `-`로 바꾼다(`a.1`, `r1.3`, `ahl-5.12`). 경로가 바뀌어도 id 로 찾을 수 있게, 개념 id 는 `<과목 id>/<항목>/<slug>`로 파일 안에도 적는다.

목차가 없거나 목차에 없는 것은 `<항목>`을 `unplaced`로 쓴다. 엔트리는 `entries/<과목 id>/unplaced/<slug>.md`, 개념은 `unplaced/<과목 id>/<slug>/`에 두고 개념 id 는 `<과목 id>/unplaced/<slug>`다. 자료 읽기와 개념 정리가 제안한 단원·주제 이름은 `item_proposed`에 남고, 목록은 그 이름으로 묶어 보인다. MYP 처럼 단원 안내가 오기 전에는 모든 개념이 여기에 있다.

**기록과 정리층.**
- 기록: `records/`, `library/entries/`, `learner/*.jsonl`, `sources/`, `library/vendor/`. 고치지 않는다. 다만 자료의 `labels.yaml`은 학생이 꼬리표를 고치거나 합칠 때 다시 쓴다.
- 정리층: `syllabus/`, `library/concepts/`, `library/unplaced/`, `links/`, `glossary.yaml`, `facets.yaml`, `references.yaml`. 작업이 다시 만든다.
- `history.jsonl`은 정리층 폴더 안에 있지만 덧붙이기만 한다.
- `figures/`의 코드 파일도 정리층 폴더 안에 있지만 판마다 새로 쓰고 고치지 않는다.

**글자층을 데이터 폴더에 두는 까닭.** 쪽 이미지는 원본에서 언제든 같은 것을 다시 만들 수 있어 캐시에 둔다. 글자층은 만든 방법(PDFKit 글자, Vision 글자 인식)과 그 판에 따라 달라질 수 있다. 그런데 출처 대조와 검색의 기준이 되므로 한 번 만든 것을 고정해 둔다.

## 파일 형식 규칙

- **에이전트는 JSON 만 쓴다** (`out/*.json`). 러너가 스키마로 검증한 뒤 정해진 모양의 YAML 이나 JSONL 로 바꿔 쓴다. 에이전트는 데이터 폴더의 YAML 을 직접 쓰지 않는다. 예외는 그림 블록 코드(`out/figures/*.html`)다. 러너가 돌아가는지 확인한 뒤 개념 폴더의 `figures/`로 옮긴다.
- **YAML 은 러너가 쓴다.**
  - 읽기는 YAML 1.2 core 규칙(Yams)으로 한다.
  - 문자열은 늘 따옴표나 블록 스칼라로 쓴다. 맨 문자열을 쓰지 않으니 `no`, `12:30`, `010`이 다른 타입으로 읽히지 않는다.
  - 여러 줄 글과 TeX 은 블록 스칼라(`|`)로 쓴다. 이스케이프가 없어 `\frac`이 그대로 남는다.
  - 키 순서는 스키마가 정한다. 들여쓰기 2칸, 줄 끝 LF, 마지막 줄바꿈 하나, UTF-8 NFC 다.
  - 그래서 같은 값은 늘 같은 바이트가 된다. 재현 시험과 마이그레이션 대조가 글자 단위로 된다.
- **JSONL** 은 한 줄에 객체 하나다. 덧붙이기만 하고, 줄마다 `v`(줄 모양 판)를 둔다.
- **JSON** 은 작은 기계 기록이다. Assayer 의 `JSONText`처럼 키를 정렬하고 2칸 들여쓴다.
- **마크다운** 은 원시 개념 엔트리 본문에만 쓴다(머리말 YAML + 영어 본문). 정리층은 YAML 이다.
- **종류와 판.** 모든 YAML 파일은 첫 필드에 `kind`와 `v`를 둔다. 블록 명세는 블록마다 `type`과 `v`를 둔다. 스키마는 `schemas/<스키마 버전>/<kind>.schema.json`이고 앱 번들에 들어간다.

## id

| 무엇 | 모양 | 붙이는 곳 |
|---|---|---|
| 작업 id | `YYYYMMDD-HHMM-<짧은-슬러그>` (Assayer 와 같다) | 러너 |
| 자료 id | `YYYYMMDD-<내용 해시 앞 8자>` | 자료 넣기 |
| 과목 id | 과목 꼬리표에서 만든다. 영어 소문자, 숫자, `-` 이고 수준을 넣지 않는다(`physics`, `math-aa`, `extended-math`) | 자료 넣기 |
| 개념 id | `<과목 id>/<항목>/<slug>`, slug 는 영어 소문자와 `-` | 개념 정리 |
| 원문 단위 id | `u1`, `u2` … (개념 안에서 유일) | 러너 |
| 페이지 단위 id | `p1`(문단), `b1`(블록), `s1`(풀이 단계), `n1`(강조 상자), `q1`(확인 문제) … (페이지 안에서 유일) | 러너 |
| 코멘트 id | `cm-YYYYMMDD-HHMMSS-<4자>` | 앱 |
| 요구 id | `d<n>` (데이터 폴더 안에서 유일) | 앱 |

- id 는 러너나 앱이 붙인다. 에이전트가 정하지 않는다.
- 과목 꼬리표의 이름을 바꾸거나 두 값을 합치면 과목 id 도 바뀐다. 그때는 그 과목의 목차와 개념 폴더도 함께 옮긴다(꼬리표 고치기가 한다).
- 한 번 쓴 단위 id 는 그 개념 안에서 다시 쓰지 않는다. 지워진 단위의 id 도 그렇다. 그래야 코멘트와 요구가 엉뚱한 단위를 가리키지 않는다. 페이지마다 `next_id`로 센다.
- 단위를 밖에서 가리킬 때는 `<개념 id>#<단위 id>`로 쓴다. 판까지 가리키면 `…#p1@r2`다.

## 해시

- sha256 을 쓴다. 저장은 앞 16자이고, 화면과 문서 예시는 앞 4자로 줄여 보인다.
- **파일 바이트가 아니라 뜻을 해시한다.** 정해진 필드만 정규화(NFC, LF, 줄 끝 공백 제거, 키 정렬)한 JSON 으로 만들어 해시한다. 그래서 YAML 모양만 바꾸는 마이그레이션은 해시를 바꾸지 않는다.

| 대상 | 해시하는 필드 |
|---|---|
| 자료 | 원본 파일 바이트 (중복 빼기에 쓴다) |
| 쪽 | 그 쪽의 글자층 |
| 원문 단위 | `text`, `conditions`, `claims`(출처 포함) |
| 페이지 단위 | `kind`, `text` 또는 블록 명세(그림 블록은 명세에 든 코드 해시), `claims` |
| 곁 층 | `text` |

해시는 층을 잇는다.

```
자료 쪽 (자료 id#쪽, 글자층 해시)
  → 원시 엔트리 (출처: 자료 id#쪽)
    → 원문 단위 (u3, 해시 a41f)
      → 페이지 단위 (p1, 판 r2, from: u3@a41f)
        → 곁 층 (한국어, from: p1@r2, 단위 해시)
        → 코멘트 (anchor: p1, r1, 인용)
```

아래 층이 기록한 위 층 해시와 지금 위 층 해시가 다르면 그 아래 층은 낡은 것이다. 색인이 낡은 단위 목록을 계산하고, 작업이 그 단위만 다시 만든다(`REGENERATION.md`).

## 쓰기 규칙

- **원자적 쓰기.** 같은 폴더의 임시 파일에 쓰고 fsync 한 뒤 이름을 바꾼다.
- **JSONL 덧붙이기.** 줄 단위로 덧붙이고 fsync 한다. 읽을 때 마지막 줄이 깨져 있으면(쓰다 꺼짐) 그 줄만 버리고 경고한다.
- **지우기는 줄을 더해서 한다.** 학생이 코멘트를 지우면 그 줄을 지우지 않고 `kind: delete` 줄을 덧붙인다.
- **반영 직전에 기준을 다시 본다.** 정리층에 쓰는 작업은 잠금을 잡고, 쓰기 직전에 입력으로 삼은 해시가 그대로인지 다시 본다. 그사이 바뀌었으면 쓰지 않고 새 기준으로 다시 돌게 한다.
- **여러 파일을 함께 바꾸는 반영.** 예를 들어 개념 정리가 개념 둘을 합치는 경우다. 반영 계획을 `apply.json`에 먼저 쓰고 차례로 적용한다. 중간에 꺼지면 다음에 켤 때 계획을 보고 마저 하거나 되돌린다.

## 색인 (SQLite)

- 캐시의 `index.sqlite`에 둔다.
- 담는 것: 자료와 꼬리표, 개념 목록(과목, 항목, 제목, 수준, 자료 유무), 개념의 꼬리표(그 개념이 나온 자료들의 꼬리표를 모은 것), 단위 글(영어와 한국어, FTS5), 용어, 코멘트 위치, 낡은 단위 목록, 파일마다 경로·크기·수정 시각·해시.
- 원본이 아니다. 켤 때와 작업이 끝날 때 바뀐 파일(크기·수정 시각)만 다시 읽는다. 색인 스키마가 바뀌거나 깨지면 지우고 다시 만든다.
- SQLite 에만 있는 데이터는 없다. 화면 상태(펼친 번역, 읽던 자리)는 데이터가 아니므로 앱 지원 폴더의 `state.json`에 둔다. 잃어도 괜찮다.

## 백업과 되살리기

- **백업 만들기 (앱).** 순서는 다음과 같다.
  1. 잠금을 잡는다. 작업이 돌고 있으면 끝날 때까지 기다리고, 그동안 새 작업을 시작하지 않는다.
  2. 데이터 폴더를 zip 으로 만든다(`ditto -c -k --sequesterRsrc --keepParent`).
  3. 이름은 `Jindesk-백업-YYYYMMDD-HHMM.zip`, 위치는 학생이 고른다.
- **Finder 로 복사해도 된다.** 다만 작업 중이면 어긋난 사본이 될 수 있다. 작업 중일 때는 메뉴 막대와 창에 보인다.
- **되살리기.**
  1. zip 을 풀어 새 폴더로 두고 그 폴더를 데이터 폴더로 고른다.
  2. 앱이 `meta/schema.yaml`을 보고 필요하면 마이그레이션한다.
  3. 색인은 다시 만든다.
- **마이그레이션 전 자동 백업.** 앱 지원 폴더의 `backups/`에 최근 세 개를 둔다.

## 파일 예시

`meta/schema.yaml`

```yaml
kind: "schema"
v: 1
schema: 3
created: "2026-09-01T20:10:00+09:00"
last_opened_by: { app: "0.4.0", build: "41" }
history:
  - { from: 1, to: 2, app: "0.2.0", at: "2026-09-20T21:00:00+09:00", kind: "code", backup: "Jindesk-마이그레이션-1-2.zip" }
  - { from: 2, to: 3, app: "0.4.0", at: "2026-10-12T19:30:00+09:00", kind: "code+agent", backup: "Jindesk-마이그레이션-2-3.zip" }
```

`sources/20260903-3fa2c1d0/meta.yaml` (받을 때 정해진 사실. 고치지 않는다)

```yaml
kind: "source"
v: 1
id: "20260903-3fa2c1d0"
original: { name: "Kinematics slides.pptx", bytes: 4813220, sha256: "3fa2c1d0e9b14a77" }
received: "2026-09-03T17:42:00+09:00"
converted: { to: "source.pdf", by: "keynote", app_version: "14.4" }
pages: 24
text_layer: { by: "pdfkit", pages_with_text: 22, ocr: { by: "vision", pages: [5, 17] } }
build_ups: [[3, 4, 5], [9, 10]]
```

`build_ups`는 앞 쪽의 글자를 모두 담고 더해 가는 쪽들의 묶음이다(슬라이드 애니메이션을 단계마다 내보낸 PDF). 자료 읽기는 묶음의 마지막 쪽을 중심으로 읽는다.

`sources/20260903-3fa2c1d0/labels.yaml` (학생이 붙인 것. 고칠 수 있다)

```yaml
kind: "labels"
v: 1
source: "20260903-3fa2c1d0"
labels: { grade: "DP1", subject: "Physics", level: "HL" }
memo: "선생님이 A.1 마무리라고 함"
syllabus_basis: false
```

`labels`는 열린 이름-값이다. 처음 제안하는 이름은 `grade`(학년), `subject`(과목), `level`(수준)이다. 과목 id 는 `subject` 값에서 만든다(`Physics` → `physics`).

`library/entries/physics/a.1/projectile-motion.md` (자료 읽기가 쓴다. 고치지 않는다)

```markdown
---
kind: "entry"
v: 1
id: "physics/a.1/projectile-motion"
subject: "physics"
item: "A.1"
item_proposed: null
title: "Projectile motion"
source: "20260903-3fa2c1d0"
pages: [10, 11, 12]
claims:
  - { text: "horizontal velocity constant without air resistance", src: ["20260903-3fa2c1d0#p12"] }
symbols:
  - { symbol: "g", meaning: "acceleration of free fall", unit: "m s^-2" }
examples: []
misconceptions: ["The velocity is not zero at the highest point; only its vertical component is."]
recorded: "2026-09-03T18:10:00+09:00"
provenance: { job: "20260903-1801-read-kinematics-slides", instructions: { kind: "source-reading", version: "0.1", commit: "…", dirty: false }, model: "claude-opus-5-5" }
---

Without air resistance, no force acts horizontally …
```

같은 경로가 이미 있으면 `<slug>--<작업 id>.md`로 나란히 둔다. 엔트리 id 는 `entries/` 아래 경로에서 `.md`를 뗀 것이다. 개념 정리가 보류한 엔트리는 그 작업의 `records/concept-curation/<작업 id>/plan.json`의 `held`에 남고, 다음 정리가 다시 고르지 않는다.

`syllabus/physics.yaml`

```yaml
kind: "syllabus"
v: 1
subject: "physics"
sources:
  - { id: "20260901-9b1e44aa", title: "Physics subject brief" }
items:
  - code: "A"
    title: "Space, time and motion"
    children:
      - { code: "A.1", title: "Kinematics", level: "SL+HL", src: ["20260901-9b1e44aa#p2"] }
      - { code: "A.4", title: "Rigid body mechanics", level: "HL", src: ["20260901-9b1e44aa#p2"] }
confirmed: { by: "관리자", at: "2026-09-02" }
provenance: { job: "20260901-2110-syllabus-physics", instructions: { kind: "syllabus-build", version: "0.1", commit: "…", dirty: false }, model: "claude-opus-5-5" }
```

`library/concepts/physics/a.1/projectile-motion/concept.yaml`

```yaml
kind: "concept"
v: 1
id: "physics/a.1/projectile-motion"
title: "Projectile motion"
subject: "physics"
item: "A.1"
level: "SL+HL"
occurrences:                     # 러너가 계산한다
  - { entry: "physics/a.1/projectile-motion--20260903-1412", source: "20260903-3fa2c1d0", pages: [10, 11, 12, 13, 14, 15] }
prerequisites: ["sciences/speed-and-acceleration", "math/trigonometric-ratios"]
symbols:
  - { symbol: "u", meaning: "initial speed", unit: "m s^-1" }
  - { symbol: "θ", meaning: "launch angle above the horizontal" }
  - { symbol: "g", meaning: "acceleration of free fall", unit: "m s^-2" }
next_id: 6
units:
  - id: "u3"
    hash: "a41f09c2d7e8b153"
    text: |
      Without air resistance, no force acts horizontally, so the horizontal
      velocity stays constant. Vertically, gravity gives a constant downward
      acceleration g. Solve the two directions separately and link them through
      the time t.
    conditions: ["no air resistance"]
    claims:
      - { id: "c1", text: "no horizontal force", src: ["20260903-3fa2c1d0#p12"] }
      - { id: "c2", text: "horizontal velocity constant", src: ["20260903-3fa2c1d0#p12"] }
      - { id: "c3", text: "vertical acceleration g downward", src: ["20260903-3fa2c1d0#p12"] }
provenance: { job: "20260905-0930-curate-physics", instructions: { kind: "concept-curation", version: "0.1", commit: "…", dirty: false }, model: "claude-opus-5-5" }
```

`learner/comments.jsonl` (줄마다 하나)

```json
{"v":1,"id":"cm-20260920-193210-7k2p","at":"2026-09-20T19:32:10+09:00","by":"learner","kind":"ask","anchor":{"concept":"physics/a.1/projectile-motion","unit":"p1","rev":1,"quote":"Without air resistance, no force acts horizontally"},"text":"중력이 계속 당기는데 왜 수평 속도는 안 바뀌어요?"}
{"v":1,"id":"cm-20260920-193545-q81d","at":"2026-09-20T19:35:45+09:00","by":"job:ask","job":"20260920-1933-ask","kind":"answer","reply_to":"cm-20260920-193210-7k2p","text_en":"Gravity acts only vertically, so it has no horizontal component. …","text_ko":"중력은 수직으로만 작용하므로 수평 성분이 없다. …","src":["20260903-3fa2c1d0#p12"]}
{"v":1,"id":"cm-20260926-201100-m3a9","at":"2026-09-26T20:11:00+09:00","by":"learner","kind":"memo","anchor":{"concept":"physics/a.1/projectile-motion","unit":"n1","rev":1,"quote":"It is tempting to say the velocity is zero"},"text":"9월 퀴즈 3번에 나옴."}
{"v":1,"id":"cm-20261001-090000-zz01","at":"2026-10-01T09:00:00+09:00","by":"learner","kind":"delete","target":"cm-20260926-201100-m3a9"}
```

코멘트 종류는 학생이 쓰는 `memo`, `ask`, `flag`, 답글인 `answer`(물어보기 작업), 그리고 `delete`다.
