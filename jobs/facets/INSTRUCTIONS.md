# 관점 붙이기 지침

지침 버전: `0.1`

이 문서는 관점 붙이기 에이전트가 따르는 유일한 지침이다. 이 작업은 두 가지를 한다. 프롬프트가 어느 쪽인지 알린다.

1. **관점.** 개념 여러 개에 IB 의 관점(명령어, 핵심 개념, 관련 개념, 글로벌 맥락, 과학의 본성, TOK)을 붙인다. 웹을 쓰지 않는다.
2. **레퍼런스 찾기.** 개념마다 학생이 볼 만한 대표 공개 자료를 셋까지 찾는다. 웹 검색과 웹 조회를 쓴다.

## 1. 원칙

1. **개념의 글에 근거한다.** 관점은 `input/concepts/`의 개념 원문을 읽고 붙인다. 억지로 채우지 않는다. 맞는 값이 없으면 빈 목록이다.
2. **정해진 목록에서 고른다.** 명령어, 핵심 개념, 글로벌 맥락, TOK 는 아래 목록의 표기 그대로 쓴다.
3. **영어로 쓴다.** 관련 개념과 NOS 값은 영어다.
4. **질문하지 않는다.** 무인으로 돈다.

## 2. 관점

`input/request.md`에 개념 키(`k01` …)와 제목, 이 과목의 관련 개념·NOS 어휘가 있다. 개념 원문은 `input/concepts/k01.yaml`이다.

| 관점 | 값 | 개수 |
|---|---|---|
| `command_terms` | 이 개념에서 학생이 하게 되는 일의 IB 명령어: Analyse, Annotate, Apply, Calculate, Classify, Comment, Compare, Compare and contrast, Construct, Contrast, Deduce, Define, Demonstrate, Derive, Describe, Design, Determine, Discuss, Distinguish, Draw, Estimate, Evaluate, Examine, Explain, Explore, Formulate, Hence, Hence or otherwise, Identify, Integrate, Interpret, Investigate, Justify, Label, List, Measure, Outline, Plot, Predict, Prove, Show, Show that, Sketch, Solve, State, Suggest, Summarize, To what extent, Verify, Write down | 0~5 |
| `key_concepts` | MYP 핵심 개념: Aesthetics, Change, Communication, Communities, Connections, Creativity, Culture, Development, Form, Global interactions, Identity, Logic, Perspective, Relationships, Systems, Time, place and space | 0~2 |
| `related_concepts` | 과목의 관련 개념 (예: 수학의 Equivalence, Generalization, Representation). 어휘에 맞는 값이 있으면 그 표기를 쓴다 | 0~4 |
| `global_contexts` | MYP 글로벌 맥락: Identities and relationships, Orientation in space and time, Personal and cultural expression, Scientific and technical innovation, Globalization and sustainability, Fairness and development | 0~1 |
| `nos` | 과학 과목일 때 과학의 본성 주제 (예: Models, Evidence, Measurement and uncertainty). 과학이 아니면 빈 목록 | 0~2 |
| `tok` | TOK 지식 영역과 주제: Mathematics, Natural sciences, Human sciences, History, The arts, Knowledge and the knower, Knowledge and technology, Knowledge and language | 0~2 |

`out/facets.json`:

```json
{ "concepts": {
  "k01": { "command_terms": ["Solve", "Show that"], "key_concepts": ["Form"], "related_concepts": ["Equivalence"], "global_contexts": [], "nos": [], "tok": ["Mathematics"] }
} }
```

## 3. 레퍼런스 찾기

`input/request.md`에 개념 키와 제목, 첫 문단이 있다.

- 개념마다 학생이 이 개념을 다시 공부할 때 볼 만한 공개 자료를 셋까지 찾는다. 영상, 설명 글, 조작해 보는 시뮬레이션, 연습 문제 묶음 같은 것이다.
- 믿을 만한 곳을 고른다(대학, 교육 기관, 잘 알려진 교육 사이트). 광고 위주의 페이지, 로그인이 필요한 페이지는 고르지 않는다.
- **반드시 WebFetch 로 열어 보고** 내용이 그 개념을 다루는지 확인한 주소만 적는다. 열어 보지 않은 주소는 러너가 버린다.
- 검색어에는 개념의 일반 용어만 쓴다.
- 맞는 자료를 찾지 못하면 빈 목록이다. 억지로 채우지 않는다.

`out/references.json`:

```json
{
  "k01": [{ "url": "https://…", "title": "…", "kind": "video", "why": "Shows the product law with worked examples." }],
  "k02": []
}
```

`kind`는 `video`, `article`, `interactive`, `practice` 가운데 하나다. `why`는 영어 한 문장이다.

## 4. 러너 검사

- 관점 값이 정해진 목록에 있고 개수가 범위 안이다. 틀리면 같은 세션에서 한 번 고쳐 쓴다.
- 레퍼런스는 `https://` 주소이고, 이 실행의 이벤트 기록에서 WebFetch 가 성공한 주소만 받는다.
