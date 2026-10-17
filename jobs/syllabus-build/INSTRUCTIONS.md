# 목차 만들기 지침

지침 버전: `0.1`

이 문서는 목차 만들기 에이전트가 따르는 유일한 지침이다. 에이전트는 한 과목의 근거 문서로 강의 계획 목차를 만든다. 근거 문서는 과목 가이드, 공개 과목 요약, 선생님의 과정·단원 안내, MYP 단원 안내(unit plan) 같은 것이다. 목차는 학생의 개념을 항목마다 묶어 보이는 틀이 된다.

## 1. 원칙

1. **근거 문서에 있는 것만 쓴다.** 항목마다 그 항목을 확인한 근거 문서의 쪽을 단다. 기억에 기대어 문서에 없는 항목을 더하지 않는다.
2. **코드는 문서의 표기를 따른다.** IB 가 쓰는 코드(예: `A.1`, `R1.3`, `AHL 5.12`)가 있으면 그대로 쓴다. 문서에 코드가 없으면(MYP 단원 등) 짧은 코드를 짓는다(`U1`, `U2` …).
3. **이미 쓰인 코드를 없애지 않는다.** `input/request.md`의 "이미 쓰인 항목 코드"는 엔트리와 개념이 가리키는 코드다. 목차에서 사라지면 안 된다. 이름이나 코드가 바뀌었으면 새 항목에 `renamed_from`을 단다.
4. **영어로 쓴다.** 항목 제목과 MYP 단원 정보는 영어다. 기록(`out/report.md`)만 한국어다.
5. **질문하지 않는다.** 무인으로 돈다. 판단이 갈리면 가장 그럴듯한 쪽을 고르고 기록에 적는다.

## 2. 작업 공간

```
input/request.md                과목, 학년·수준, 근거 문서 목록, 이미 쓰인 코드, 목차 밖 개념
input/sources/<자료 id>/index.md 근거 문서의 쪽 목록
input/sources/<자료 id>/pages/   쪽 이미지(.png)와 글자층(.txt). 뜻은 쪽 이미지로 읽는다
input/syllabus.yaml             지금 목차 (있을 때만)
out/                            여기에만 쓴다
```

## 3. 목차의 모양

- **DP.** 과목 가이드의 주제(Topic)와 하위 주제를 항목으로 쓴다. 주제는 위 항목, 하위 주제는 그 아래 항목이다(`A` > `A.1`). `level`은 `SL+HL`(SL·HL 모두) 또는 `HL`(HL 만)이다.
- **MYP.** 단원 하나가 항목 하나다. 단원 안내에 있으면 `myp`에 핵심 개념(key concept), 관련 개념(related concepts), 글로벌 맥락(global context), 탐구 진술(statement of inquiry)을 문서의 표현대로 옮긴다. 수준이 나뉘면(Standard, Extended) `level`에 적는다.
- 지금 목차가 있으면, 새 근거 문서의 항목을 더해 넓힌다. 이미 있는 항목은 그대로 둔다.

## 4. 목차 밖 개념 넣기

`input/request.md`의 "목차 밖 개념" 가운데 새 목차의 한 항목에 분명히 드는 것은 `placements`에 `{ "concept": "<개념 id>", "item": "<항목 코드>" }`로 적는다. 러너가 그 개념을 그 항목으로 옮긴다. 애매하면 넣지 않는다.

## 5. `out/syllabus.json`

```json
{
  "programme": "MYP",
  "items": [
    {
      "code": "U2", "title": "Logarithms", "level": "Extended", "src": ["20260901-9b1e44aa#p1"],
      "myp": {
        "key_concept": "Form", "related_concepts": ["Equivalence", "Representation"],
        "global_context": "Scientific and technical innovation",
        "statement_of_inquiry": "Representing quantities in equivalent forms helps us solve problems efficiently."
      },
      "children": []
    }
  ],
  "placements": [{ "concept": "extended-math/unplaced/laws-of-logarithms", "item": "U2" }]
}
```

| 필드 | 무엇 |
|---|---|
| `programme` | `MYP`, `DP` 가운데 하나. 알 수 없으면 `null` |
| `items` | 항목 나무. 항목마다 `code`, `title`, `level`(없으면 생략), `src`(근거 문서의 쪽, `<자료 id>#p<쪽>`), `children` |
| `renamed_from` | 이 항목의 옛 코드 (코드가 바뀌었을 때만) |
| `myp` | MYP 단원 정보 (MYP 일 때만) |
| `placements` | 목차 밖 개념을 넣을 항목 |

## 6. `out/report.md`

한국어로 짧게 쓴다. 근거 문서마다 무엇을 얻었는지, 만든 항목 수, 바뀐 코드와 까닭, 옮긴 개념, 판단이 갈린 곳.

## 7. 러너 검사

틀리면 같은 세션에서 문제 목록을 받고 한 번 고쳐 쓴다. 그래도 틀리면 목차를 쓰지 않는다.

- 코드가 겹치지 않는다.
- 항목마다 근거 문서에 있는 쪽이 달렸다.
- `level`이 정해진 값(`SL`, `HL`, `SL+HL`, `Standard`, `Extended`, `Standard+Extended`)이다.
- 이미 쓰인 코드가 사라지지 않았다. 바뀌었으면 `renamed_from`이 있다.
- `placements`의 개념이 목차 밖 개념이고, 항목이 목차에 있다.
- 제목에 한글, 한자, 일본어가 없다.
