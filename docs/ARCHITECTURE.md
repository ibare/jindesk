# Jindesk 아키텍처

학교 자료를 격리된 headless Claude Code(`claude -p`)로 읽어 정리하고, 그 결과를 학생이 공부하는 화면으로 펼치는 Mac 앱이다. 작업은 학생 맥에서 돈다.

## 원칙

원칙끼리 부딪치면 소프트웨어 구조의 엄밀함보다 자료의 충실도와 학습 최신성을 먼저 둔다(`DECISIONS.md` 19).

1. **결정적인 일은 러너가, 판단은 에이전트가.** 입력 고정(내용 해시), 산출물 검증과 배치, 계산으로 하는 확인은 러너 코드가 한다. 에이전트는 작업 공간을 읽고 `out/`, `work/`에만 쓴다.
2. **에이전트에게는 모델 토큰 외의 자격 증명을 주지 않는다.**
3. **재현할 수 있게 남긴다.** 입력의 내용 해시, 작업 지침의 버전과 빌드 정보, 모델, 사용량을 기록에 남긴다.
4. **기록은 덧붙이기만 한다.** 원시 산출물(원시 개념 엔트리, 작업 기록, 학생의 코멘트)은 고치지 않는다. 정리층(정리된 개념, 학습 페이지, 곁 층, 목차)은 다시 만든다.
5. **자료에 있는 것과 보탠 것을 나눈다.** 주장마다 자료와 쪽을 단다. 출처가 없는 설명은 "보충"으로 보인다.
6. **그림은 에이전트가 코드로 짠다.** 그래프, 실험, 회로 같은 그림과 인터랙션은 에이전트가 HTML·JS 로 직접 짜고, 앱에는 블록 틀과 공통 부품만 든다. 엄밀성 검사는 글에 두고, 그림은 돌아가는지만 본다.
7. **영어가 원문, 한국어는 문단 곁에.** 학습 페이지는 영어로 쓰고, 한국어는 단위마다 곁 층으로 둔다.
8. **바뀐 곳만 다시, 요구는 남긴다.** 단위마다 id, 판, 어디서 왔는지의 해시가 있다. 요구는 데이터로 남는다.
9. **파일이 원본이다.** YAML, JSONL, JSON 파일이 원본이고 화면은 그것을 조합해 그린다. SQLite 는 다시 만들 수 있는 색인이다.
10. **쓰는 사람과 고치는 사람이 다르다.** 학생이 쓰고 관리자가 고친다. 관리자가 고친 것은 릴리즈로 학생 맥에 간다. 학생의 기록은 관리자가 학생 맥이나 백업에서 직접 본다.

## 전체 구조

```
Jindesk.app (학생 맥)
  화면 (SwiftUI) ── 학습 페이지는 WKWebView 안의 번들 렌더러가 그린다
  │  작업 요청 (종류 + 입력)
  ▼
엔진 (JindeskKit)
  Engine/     작업 관리자(종류별 대기열, 사용량 미루기, 잠금), 설정, 작업 모델, 지침
  Agent/      claude -p 실행, 이벤트 해석, 깨어 있던 시간 상한, 학생 독자 시험
  Guard/      외부 호출 검사 (jindesk-guard 훅이 쓴다)
  Process/    자식 프로세스(프로세스 그룹), 자식 환경, 도구 찾기
  Config/     데이터 폴더, 키체인
  Sources/    자료 처리: PPT → PDF, 쪽 나누기, 글자층, 이미지
  Library/    목차·엔트리·개념·페이지·곁 층·용어 어휘 읽기와 쓰기, 해시와 id
  Jobs/       에이전트 작업(자료 읽기, 개념 정리, 학습 페이지 만들기, 번역): 작업 공간 준비, 실행, 러너 검사와 고쳐 쓰기, 반영, 남은 일 계산
  Pages/      화면에 넘길 페이지 조합 (페이지 + 곁 층 + 코멘트 + 용어 + 관점)
  Checks/     글 검사(주장 장부, 출처 대조, 수식 파싱, 풀이 단계 계산), 그림 블록 실행 확인과 라이브러리 받아 두기
  Index/      SQLite 색인 (캐시에 둔다)
  Backup/     백업 만들기와 되살리기
  Update/     Sparkle 연결, 작업 중 설치 미루기
  Migration/  스키마 버전, 마이그레이션 실행과 검증
  Util/       YAML, JSON, 해시, 원자적 쓰기
  │
  ├─ claude -p (작업마다 격리된 작업 공간)
  └─ 데이터 폴더 ~/Jindesk/ · 캐시 · 작업 공간 (DATA.md)
```

앱 번들 하나에 앱, 명령줄 모드, 훅 실행 파일, 작업 지침, 렌더러가 함께 들어간다.

```
Jindesk.app/Contents/
  MacOS/Jindesk              앱. 인자를 주면 명령줄 모드 (jindesk doctor, jindesk migrate --check …)
  MacOS/jindesk-guard        외부 호출 검사 훅
  Resources/jobs/<종류>/INSTRUCTIONS.md, jobs/build.json   작업 지침과 지침마다의 커밋·미커밋 여부
  Resources/renderer/        학습 페이지 렌더러 (JS, CSS, KaTeX 와 글꼴), 그림 블록 틀과 공통 부품
  Resources/schemas/         데이터 파일 스키마 (JSON Schema)
  Frameworks/Sparkle.framework
```

## 실행 구조 (모든 작업 공통)

Assayer 의 실행 구조를 그대로 따른다. 다른 점만 적는다.

- **작업 정의.** 작업 종류 하나는 `prepare(input, context)`와 `PreparedJob.run(context)`다. 엔진은 작업 종류를 몰라도 대기열, 상태, 취소, 실행 기록(`run.json`)을 처리한다.
- **대기열.** 종류마다 따로 있다(`JOBS.md`의 대기열 표). 자리가 찬 대기열의 작업은 건너뛰고 뒤의 작업을 먼저 시작한다. 작업마다 따로 취소한다.
- **사용량 미루기.** 에이전트 출력(stream-json)의 `rate_limit_event`에서 5시간·주간 사용률을 읽는다. 5시간 사용률이 기준(기본 90%) 이상이면 새 작업을 시작하지 않고 그 창이 초기화될 때까지 미룬다.
- **잠금.** 작업이 하나라도 도는 동안 데이터 폴더의 `meta/.lock`(프로세스 id 를 적는다)을 쥔다. 앱과 명령줄 모드가 같은 폴더에서 함께 쓰지 않게 한다. 백업 만들기와 마이그레이션도 이 잠금을 잡는다. 주인 프로세스가 없는 잠금은 풀린 것으로 본다.
- **에이전트 실행.** `~/Library/Application Support/com.mintae.Jindesk/work/<작업 id>/workspace/`를 작업 디렉터리로 `claude -p --restricted`를 띄운다. 별도 프로세스 그룹으로 띄워 취소·시간 초과·앱 종료 때 그룹째 정리한다.
  - **인증:** 키체인의 Claude 토큰을 자식 프로세스에만 `CLAUDE_CODE_OAUTH_TOKEN`으로 넘긴다. 자식 환경에서 `CLAUDE*`, `ANTHROPIC*`, `GH_*`, `GITHUB_*`를 지우고, PATH 와 UTF-8 로캘을 채운다.
  - **격리:** `CLAUDE_CONFIG_DIR`를 `work/<작업 id>/claude-config/`로 둬서 `~/.claude`의 지침, 메모리, 설정이 보이지 않게 한다. 자동 메모리도 끈다.
  - **권한:** 도구는 Read/Grep/Glob/Write/Edit 이고, `dontAsk` 모드에서 쓰기는 `out/`, `work/`만 허용한다. 웹 도구(WebSearch/WebFetch)는 관점 붙이기의 레퍼런스 찾기에만 준다.
  - **외부 호출 검사:** 웹 호출 직전에 `jindesk-guard` 훅이 돈다. 로컬·사설망 주소를 조회하면 막는다. 웹 조회가 이 맥에서 바로 나가므로, 막지 않으면 이 맥의 다른 서비스에 닿을 수 있다. 검사하지 못하면 막고, 훅 설정의 `"onFailure": "block"`으로 훅이 뜨지 못해도 막는다. 그래서 claude 2.1.295 이상이 필요하다. 모든 외부 호출은 `work/<작업 id>/external.jsonl`에 남는다.
  - **시간 상한:** 깨어 있던 시간만 센다. 작업 중에는 자리를 비워 생기는 잠자기를 막는다.
- **설정.** 모델(기본 `claude-opus-5-5`), effort(`high`), 최대 턴, 예산, 시간 상한, 동시 실행 수는 관리자가 정하는 값이다. 학생 화면에는 보이지 않고 "관리자 설정"에 둔다.
- **업데이트.** 작업이 돌고 있으면 업데이트를 설치하지 않는다. 다시 켠 뒤에는 마이그레이션을 마치고 나서 대기열을 연다(`UPDATES.md`, `MIGRATION.md`).
- **비정상 종료.** 앱이 비정상 종료하면 다음에 켤 때 실행 중이던 작업을 중단됨으로 고친다.

## 화면

```
사이드바        목록                    학습 페이지                          인스펙터
오늘            과목의 강의 계획 목차    영어 원문 문단 · 블록                출처 (자료와 쪽)
과목            항목마다 개념             문단 끝: 한 · 쉽게 · ✎ · ↻           관점
모아 보기       자료 있음 ● / 없음 ○     곁 층(한국어, 쉽게)은 문단 아래       먼저 알아야 할 것
작업            목차 밖 · 확인할 것       코멘트 스레드도 문단 아래            과목 사이 연결
                                                                              이 페이지의 코멘트
```

자세한 것은 `PAGES.md`, 화면 시안은 `prototype/index.html`.

## Assayer 에서 가져오는 것

Assayer 의 코드를 옮겨 와 고친다. 공유 패키지로 떼지는 않는다(두 앱이 따로 바뀐다). 이 리포가 공개이므로 옮겨 온 코드도 공개된다.

| Assayer (`mac/`) | Jindesk 에서 | 바꿀 점 |
|---|---|---|
| `AssayerKit/Agent/AgentRunner.swift`, `StreamEvents.swift` | `Agent/` | 그대로. 작업마다 도구 목록과 모델 값을 받는다 |
| `AssayerKit/Agent/AwakeTimer.swift` | `Agent/` | 그대로 |
| `AssayerKit/Agent/Readability.swift` | `Agent/ReaderTest.swift` | 학생 독자 시험. 독자 수준(MYP 10, DP SL, DP HL)을 받고, "슬라이드 3 참고"처럼 원래 자료가 있어야만 통하는 말을 기계적으로 찾는다 |
| `AssayerKit/Guard/*`, `AssayerGuard/` | `Guard/`, `JindeskGuard/` | 금지어 검사를 뺀다. 로컬·사설망 주소 막기와 기록만 남긴다 (`DECISIONS.md` 24) |
| `AssayerKit/Process/*` | `Process/` | 그대로. 도구 찾기에서 `gh`, `git`을 빼고 Keynote, LibreOffice(`soffice`)를 더한다 |
| `AssayerKit/Config/Keychain.swift` | `Config/` | 그대로. 서비스 이름 `com.mintae.Jindesk` |
| `AssayerKit/Config/DataRoot.swift` | `Config/DataFolder.swift` | 데이터 폴더 고르기와 기억. iCloud 동기화 폴더 경고를 더한다 |
| `AssayerKit/Config/DotEnv.swift` | 가져오지 않는다 | `.env`를 쓰지 않는다 |
| `AssayerKit/Engine/*` | `Engine/` | 대기열 종류와 잠금 위치를 바꾼다. 지침 넣기(`InstructionSource`, `build.json`)는 그대로 |
| `AssayerKit/Environment/EnvironmentCheck.swift` | `Engine/Doctor.swift` | claude 위치와 버전, 토큰이 키체인에 있는지(값은 읽지 않는다), Keynote, 데이터 폴더, 캐시를 본다 |
| `AssayerKit/Util/*` | `Util/` | 그대로. YAML 쓰기 규칙을 `DATA.md`에 맞춘다. 읽기는 Yams |
| `AssayerKit/Catalog/CatalogVerify.swift`, `PatternVisual.swift` | 참고만 | 격리 시험 왕복은 글의 격리 검증, 조각을 공통 틀에 넣는 방식은 그림 블록 틀의 본보기로 쓴다 |
| `AssayerKit/Git/`, `Catalog/`, `Jobs/`, `Records/` | 가져오지 않는다 | |
| `AssayerKitTests/ReplayTests` | `JindeskKitTests/` | 후처리와 마이그레이션을 지난 작업 공간·백업으로 다시 해 글자 단위로 견주는 시험의 본보기 |
| `Assayer/Debug/SnapshotDriver.swift` | `Jindesk/Debug/` | 화면을 PNG 로 찍는 장면만 바꾼다 |
| `project.yml` (XcodeGen) | `mac/project.yml` | 서명을 Developer ID 로, Sparkle 패키지를 더한다 |
| `scripts/install.sh` | `mac/scripts/release.sh` | 서명, 공증, Sparkle 서명, 릴리즈 올리기 (`UPDATES.md`) |

## 저장소 배치

```
docs/                       설계 문서
jobs/<종류>/INSTRUCTIONS.md 작업 지침. 빌드할 때 앱 번들에 들어간다. 내용을 바꾸면 파일 위의 버전을 올린다
renderer/                   학습 페이지 렌더러. 번들 JS·CSS, KaTeX, 글 블록 렌더러, 그림 블록 틀과 공통 부품
schemas/<스키마 버전>/       데이터 파일의 JSON Schema. 러너 검증과 마이그레이션이 쓴다
mac/
  project.yml               XcodeGen 정의 (Jindesk.xcodeproj 는 생성물이라 커밋하지 않는다)
  JindeskKit/               엔진
  JindeskGuard/             외부 호출 검사 훅
  Jindesk/                  앱 (화면, WKWebView, 메뉴 막대, 명령줄 모드)
  JindeskKitTests/          엔진 시험
  scripts/release.sh        릴리즈
```

## 보안과 개인정보

- 학생의 데이터는 학생 맥의 데이터 폴더에만 있다.
- 이 리포는 공개다. 리포와 릴리즈에는 학생의 자료, 기록, 이름이 들어가지 않는다.
- Sparkle 의 EdDSA 비밀 키와 공증 자격 증명은 관리자 맥의 키체인에만 있다.
- 에이전트의 웹 호출은 레퍼런스 찾기 한 곳뿐이고, 로컬 주소 검사를 거친다. 검색어와 조회 주소에 학교나 단원 이름이 들어가도 막지 않는다(`DECISIONS.md` 24). 러너는 그림 블록을 만들 때 그 그림이 부르는 라이브러리를 받는다.
