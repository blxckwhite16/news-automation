# Session Summary

> Internal working document for Claude Code session handoff.
> Not part of the public project documentation.

<!-- Last updated: 2026-08-01 -->

## Completed

세션 전체 결과 요약. 각 항목의 구현 과정·검증 상세는 괄호로 표시된 전용 절 참고.

- NAVER Search API 기반 뉴스 수집 파이프라인 구현 완료 (Google News RSS 대체)
- Company Loop 검증 완료 (SK하이닉스, 현대자동차 2개 기업 기준)
- Raw_News 저장 검증 완료
- Gemini JSON 구조화 출력 적용 (프롬프트 기반 파싱/검증, n8n 노드 자체의 response_schema 기능은 미지원)
- AI_Analysis 시트 저장 완료
- Schedule Trigger 매일 08:30(Asia/Seoul) 설정 완료
- Loop Over Items `done` 출력 누적 방식 검증 완료 (Aggregate로 회사당 결과 1개로 합친 뒤 loop-back하는 방식 확정)
- NAVER API 키 평문 노출 최초 발견 및 credential 이전 완료 (재발 및 최종 정리는 "보안 재발 및 정리" 절 참고)
- News Collector 워크플로우를 `n8n/workflows/news-collector.json`으로 export하여 버전관리 시작
- **오류 격리 아키텍처 전면 구현 및 프로덕션 반영 완료** ("오류 격리 아키텍처" 절 참고)
- **프로덕션 데이터 안전사고 발생 및 수습** — 영향 범위 식별 완료, 재발 방지 원칙 확립 (Decisions "워크플로우 편집 원칙" 참고), 삭제는 사용자가 직접 처리
- **Run_Log 구현 완료** ("Run_Log 설계 및 구현 계획" 절 참고)
- **프로덕션 워크플로우 잔여 정리 완료** ("프로덕션 워크플로우 정리" 절 참고)
- **Telegram 완료 알림 V1 구현 및 프로덕션 반영 완료** ("Telegram 완료 알림" 절 참고)

## 오류 격리 아키텍처 (이번 세션 핵심 작업)

### 문제
기존 파이프라인은 회사별로 "관련 기사 0건", "신규 기사 0건", "고중요도 기사 0건", "API 실패" 중 하나라도 발생하면 해당 회사에 대해 아무 아이템도 생성하지 않고 루프가 조용히 멈출 수 있었다. 이 네 가지는 모두 정상적으로 발생 가능한 케이스이며 에러가 아니다.

### 해결 — "Build Company Summary" 패턴
각 단계마다 조기 종료(IF) 분기를 두어, 어떤 경로를 타든 회사당 정확히 1개의 제어 아이템(`result_type` 포함)이 파이프라인 끝의 `Build Company Summary`로 도달하도록 설계. State Passing(참조가 아니라 아이템 필드로 값을 직접 들고 다니는 방식)을 기본 원칙으로 채택.

### 부속 문제 — Google Sheets Append의 필드 스트리핑
`Save Raw News` / `Save AI_Analysis`(Google Sheets Append)는 매핑된 컬럼만 출력하고 나머지 필드(`article_relevant`, `article_duplicate` 등)를 유실시킨다. 처음에는 `$('NodeName').item`/`.first()` 같은 노드 참조로 유실된 값을 복구하려 했으나, **LG에너지솔루션 건에서 실제 장애로 확인**: 1→N 분기(`Split Out High Importance`) 뒤에 부분 필터(`Count Analyzed Success`)가 오면 pairedItem lineage가 깨지면서 참조가 "가장 최근 실행" 값으로 조용히 폴백되거나(가장 위험한 케이스) 명시적 에러를 던졌다.

### 최종 채택 — Fork + Merge (article_id 기준)
저장 노드 직전에 원본 전체 필드를 가진 사본을 분기(Fork)해두고, 저장 성공 결과와 그 사본을 `article_id` 기준으로 재결합(Merge)한다. 재결합 결과의 건수가 저장 성공 건수와 다르면(= article_id 불일치로 일부 레코드가 조용히 누락되는 경우) 즉시 명시적 에러를 던진다.

**신규 노드 (Raw News 경로)**
1. `Keep Raw News Context` — `IF: No New Articles?` False 출력에서 분기, 저장 직전 원본 전체를 그대로 보존. `article_id` 누락/중복 즉시 검증
2. `Merge Raw News Context` — `Save Raw News` 성공 결과와 위 사본을 `article_id`로 재결합
3. `Validate Raw News Merge` — 저장 성공 건수 = Merge 출력 건수 검증, 불일치 시 저장 성공 건수/Merge 출력 건수/누락 건수/누락된 article_id/오류 구간을 포함해 명시적 에러

**신규 노드 (AI_Analysis 경로)** — 동일 패턴
4. `Keep AI Analysis Context`
5. `Merge AI Analysis Context`
6. `Validate AI Analysis Merge`

**저장 실패 에러 출력 미연결 문제 수정**
`Save Raw News`/`Save AI_Analysis`는 `onError: continueErrorOutput`이 설정되어 있었지만 에러 출력이 어디에도 연결되어 있지 않아, 저장 자체가 실패하면 해당 회사가 통째로 사라지는 문제가 있었다(오류 격리 작업 전체의 목적을 정면으로 깨는 지점). 추가로 연결:
7. `Tag: Company Failed` — `Save Raw News` 에러 출력 → `Build Company Summary`
8. `Tag: Save AI_Analysis Failed` — `Save AI_Analysis` 에러 출력 → `Build Company Summary`

**기존 노드 코드 단순화 (참조 제거)**
- `Prepare Importance Routing` — `$('Check New Articles').item` 참조 제거, Merge로 복원된 필드를 아이템에서 직접 읽도록 변경
- `Build Company Summary` — `$('Prepare Importance Routing').item`/`.first()` 참조 제거 (LG에너지솔루션 버그의 직접 원인이었던 코드)

### 참조(pairedItem) 안전성에 대한 명시적 범위 제한

**이번 세션에서 검증한 것은 일반 원칙이 아니다.** `Validate Raw News Merge`/`Validate AI Analysis Merge`가 사용하는 `$('Save Raw News').all()` / `$('Save  AI_Analysis ').all()` 참조와, `Tag: Company Failed`/`Tag: Save AI_Analysis Failed`가 사용하는 `$('Loop Over Items').item` 참조는 다음 조건을 모두 만족하는 **이 특정 데이터 흐름에서만** 안전이 확인되었다:
- 참조 대상 노드가 참조하는 노드의 바로 다음(1홉) 또는 같은 루프 반복 내부에 있음
- 그 사이에 1→N 분기와 부분 필터가 겹치는 구간이 없음

다른 위치에서 동일한 참조 패턴(특히 `.all()`)을 재사용할 경우, "이전에 안전했으니 안전하다"고 가정하지 말고 반드시 그 위치의 구체적인 데이터 흐름을 기준으로 별도 검증해야 한다. LG에너지솔루션 건이 정확히 "비슷해 보이지만 안전하지 않았던" 사례다.

### 검증
"News Collector"(ID `2hzQvxGKNmK6WgQW`)에 10개 신규 노드 추가, 2개 기존 노드 코드 재작성 후 프로덕션 전체 실행으로 검증: 10개 회사 전원 처리, `Build Company Summary` 정확히 10건(회사당 1건), `Validate Raw News Merge`/`Validate AI Analysis Merge` 정상 통과, 회사별 `article_relevant = article_duplicate + article_saved`, `article_failed = article_analyzed - article_analysis_success` 관계식 전원 일치 확인 (LIG넥스원 등 개별 회사 단위로 재확인).

## 보안 재발 및 정리 (이번 세션 후반)

문서 최종화 도중 프로덕션 `Fetch Naver News`(라이브 노드)에 NAVER API 키가 평문으로 재노출되어 있는 것을 발견 — 이전 세션에 credential로 이전했다고 기록되어 있었으나 실제 프로덕션 노드에는 반영되어 있지 않았음(원인 불명, 여러 차례의 export/import 과정에서 되돌아간 것으로 추정). 동일 키가 `HTTP Request (Test for Naver)`, `Fetch Naver News1` 두 노드에도 하드코딩되어 있었음. 저장소에는 커밋 이력이 없어 git 히스토리 노출은 없었음.

**조치 완료**:
- `Fetch Naver News` — `headerParameters` 평문 제거, `authentication: genericCredentialType` + `genericAuthType: httpCustomAuth` + credential `NaverApiHeaderAuth1`(NAVER Search API Header Auth)로 복원. 격리된 테스트 워크플로우로 실제 API 호출 성공 확인 (실제 기사 정상 반환)
- `HTTP Request (Test for Naver)`가 속한 Manual Trigger 체인(8개 노드, Google News RSS 실험 + Telegram 알림 실험 잔재)과 `Fetch Naver News1`이 속한 "Schedule Trigger for DEV" 체인(17개 노드, 리팩토링 이전 구조의 완전한 복제본, 테스트 스프레드시트 참조) — 총 25개 노드 전체 삭제. 삭제 전 (1) 라이브 `Schedule Trigger` 도달 노드 33개와 교집합 0개, (2) n8n 인스턴스 내 다른 워크플로우 34개 전체가 이 워크플로우를 참조하지 않음(SQLite DB 직접 조회로 확인), (3) 두 체인 모두 프로덕션 기능과 무관함을 확인 후 진행
- 삭제 후 라이브 `Schedule Trigger` 도달 노드 집합이 삭제 전과 정확히 동일한 33개임을 재확인(연결 손상 없음)
- 최종 export 기준 평문 키 완전 제거 확인, `n8n/workflows/news-collector.json`도 이 상태로 갱신(45개 노드)
- **남은 조치**: NAVER API 키 자체는 한동안 평문 노출 상태였으므로 사용자가 NAVER Developer Center에서 직접 재발급 예정 (Claude 작업 범위 아님)

**적용 중 발생한 충돌과 재발견된 위험 패턴**: 위 수정(credential 복원 + 25개 노드 삭제)을 최초 적용한 직후, 사용자가 브라우저에 열어두고 있던 이전 상태의 n8n 편집기 탭이 저장되면서 Claude의 백엔드 변경이 통째로 되돌아가는 일이 발생 — 평문 API 키와 삭제했던 25개 노드가 모두 복원됨. 원인은 "편집 직전 최신 상태를 재-export"만으로는 막을 수 없는 별도의 위험: **백엔드에서 워크플로우를 수정하는 동안 브라우저에 그 워크플로우가 열려 있으면, 이후 그 탭에서 저장(자동 저장 포함)이 발생하는 순간 백엔드 변경이 소리 없이 덮어써진다.** 이는 세션 초반의 프로덕션 데이터 안전사고와 동일한 계열의 문제(오래된 상태 기준으로 저장이 발생)이며, 이번에 "브라우저 탭 동시 편집"이라는 구체적 트리거를 하나 더 확인한 것. 재발 방지를 위해 **Claude가 백엔드에서 프로덕션 워크플로우를 수정하는 동안에는 사용자가 해당 워크플로우 편집기 탭에서 저장하지 않아야 하며, 수정 완료 후에는 반드시 새로고침으로 브라우저 상태를 동기화**해야 함 — 새로고침 확인 후 동일한 수정을 재적용해 최종 완료(44개 노드, 평문 키 0건 재확인)

## Run_Log 설계 및 구현 계획 (완료)

최종 확정 스키마(12개 컬럼)와 판정 기준은 `docs/design.md` 5.4절 참고. 구현은 아래 3단계로 진행하며, 프로덕션에는 노드 하나씩 사용자가 직접 적용.

**Phase A — Fetch Naver News 실패 경로 수정** (기존에 발견된, Save Raw News/Save AI_Analysis와 동일한 계열의 에러 출력 미연결 문제)
1. `Tag: Fetch Naver News Failed` 신규 노드 — `Fetch Naver News` 에러 출력 → 이 노드 → `Build Company Summary`. `failed_stage: 'FETCH_NAVER_NEWS'` 포함

**Phase B — `run_started_at` 생성 및 조회** (완료). 최초 설계는 10개 노드에 `run_started_at`을 필드로 threading하는 순수 State Passing 방식이었으나, 아래 이유로 `$execution.customData` 방식으로 전환해 **2개 노드만 수정**하는 것으로 확정:

- `Build Naver Query`(루프 내 첫 Code 노드) — `$execution.customData.get('run_started_at')`이 없으면 `new Date().toISOString()`으로 최초 1회만 생성해 `set()`, 이미 있으면 그대로 재사용(덮어쓰지 않음). 이 노드 자신의 출력 아이템에는 필드를 추가하지 않음(다른 브랜치로 threading할 필요가 없어졌기 때문)
- `Build Company Summary` — 최종 출력에서 `run_started_at: $execution.customData.get('run_started_at') || null`로 직접 조회

**`$execution.customData` 사용에 대한 명시적 범위 제한 (일반화 금지)**
- 이것은 execution 범위로 격리된 공유 상태를 사용하는 **예외적 선택**이며, 기본 원칙인 State Passing을 대체하는 것이 아니다
- pairedItem lineage에 의존하는 노드 참조(`$('NodeName').item`/`.first()`/`.all()`)와는 **완전히 다른 메커니즘**이다 — 실제로 1→5 분기 후 부분 필터(짝수만 남기기)를 거친 뒤에도 `$execution.customData.get()`이 정상 동작함을 별도 테스트로 확인(LG에너지솔루션 버그를 일으켰던 것과 동일한 토폴로지에서 검증). 노드 참조의 lineage 문제 자체에 영향받지 않는 구조이기 때문
- `getWorkflowStaticData('global')`과 달리 **실행 간에는 값이 유지되지 않는다** (동일 실행 내 반복 검증: 회사 10개 전원 동일 값 / 별도 실행 2회 간 값이 다름 — 둘 다 DEV에서 실제 확인). "실행 간 지속되는 저장소"로 일반화하지 않는다
- **적용 범위는 이번 `run_started_at`처럼 실행 전체에 공통인 메타데이터에 한정한다.** 기사/회사별 비즈니스 데이터(article_id, company_name, 카운트 등)는 지금까지처럼 반드시 아이템 필드로 State Passing 한다 — customData를 그런 데이터의 대체 수단으로 쓰지 않는다

**Phase C — 집계 및 저장**
1. `Aggregate Run Stats` 신규 노드 — `Loop Over Items` done 출력 뒤. 12개 컬럼 전부 계산, `company_total`은 `Get Company List` 카운트로 별도 산출(교차검증), 정합성 불일치 시 `run_status=FAILED` + `error_summary`에 상세 반영
2. `Save Run_Log` 신규 노드 (Google Sheets Append)

**Phase C 완료 (프로덕션 반영 및 DEV 통합 테스트 검증 완료).**

`company_total` 참조(`$('Get Company List').all().length`)에 대한 별도 안전성 근거: `Get Company List`는 실행당 정확히 1회만 실행되는 노드이므로, 루프 전체(1→N 분기+부분 필터 포함)를 거친 뒤 참조해도 "어느 실행 시점의 값인지" 모호함이 발생하지 않는다. 1→5 분기 후 부분 필터를 거친 토폴로지로 별도 검증 완료. 이는 기존에 검증한 "루프 내부에서 여러 번 실행되는 노드에 대한 참조 안전성"(예: Validate Merge 노드들)과는 **다른 근거**이며, "실행당 1회만 실행되는 노드에 대한 참조"라는 이 조건에서만 안전이 확인된 것으로 별도 문서화한다 — 서로 일반화해 혼용하지 않는다.

`run_status` 최종 판정 순서 (design.md 5.4절과 동일, 무결성 체크 우선):
```
1. company_total === 0                                   → FAILED
2. company_total !== company_completed + company_failed   → FAILED
3. company_failed === 0                                   → SUCCESS
4. company_completed > 0 AND company_failed > 0            → PARTIAL_SUCCESS
5. company_completed === 0 AND company_failed > 0          → FAILED
```

DEV 통합 테스트(테스트 스프레드시트) 결과: 실행 2회 각각 Run_Log 1행씩 정상 생성(총 2행), 두 실행 모두 `company_total=10`/`company_completed=10`/`run_status=SUCCESS`, `NO_NEW_ARTICLES`/`NO_HIGH_IMPORTANCE_ARTICLES`가 섞여 있어도 정상 완료, 같은 실행 내 10개 회사의 `run_started_at`이 전부 동일, `finished_at`이 `started_at`보다 항상 늦음, 두 실행의 `run_id`/`started_at`이 서로 다름 — 모두 실제 시트 데이터로 재확인.

**프로덕션 반영 중 발생한 반복 충돌 (2번째 발생)**: Phase B+C를 처음 백엔드에 반영한 직후, 사용자가 브라우저에 열어두고 있던 이전 상태의 편집기 탭이 저장되며 Phase B와 C가 모두 통째로 되돌아가는 일이 재발함(Phase A는 생존). 이전에 문서화한 "편집 중 저장하지 않기" 원칙만으로는 n8n의 자동저장을 막기에 부족함을 확인 — **이번에는 "편집 중 탭을 아예 닫기"로 재발 방지 기준을 강화**. 이후 동일한 Phase B+C 코드를 현재(사용자가 추가한 Sticky Note 포함) 상태 위에 재적용, 사용자가 n8n UI에서 직접 프로덕션을 1회 실행해 `Aggregate Run Stats` 출력값과 실제 `Run_Log` 시트에 기록된 행(1행, row_number 2)이 정확히 일치함을 최종 확인 — `run_id=20260801_130758`, `company_total=10`, `company_completed=10`, `run_status=SUCCESS`.

## 프로덕션 워크플로우 정리 (완료)

`2hzQvxGKNmK6WgQW` 워크플로우 전체 export 기준 도달성 분석 결과, A~D 전 항목 정리 완료.

- ~~C. "Schedule Trigger for DEV" 전체 체인~~ / ~~D. "When clicking 'Execute workflow'" 체인~~ — 처리 완료 (위 "보안 재발 및 정리" 절 참고, 평문 API 키 노출 문제와 함께 25개 노드 전체 삭제)
- ~~A. 완전 고아 5개~~: `Build Search Query (Google OLD)`, `HTTP Request `(trailing space), `RSS XML Parsing`, `Split Out`, `Send a text message1` — 삭제 완료. (`Build Naver Query1`은 이 시점 이전에 사용자가 이미 직접 삭제한 상태였음)
- ~~B. 죽은 브랜치~~: `Filter by Importance`(구버전) — `Calculate News Importance → Filter by Importance` 연결 해제 후 삭제 완료 (`Calculate News Importance → Prepare Importance Routing`은 유지)

삭제 전 코드 내 `$('NodeName')` 참조 전체 스캔(0건) + 연결 관계 확인 후 진행. 삭제 후 재-export로 되돌림 없이 안정적으로 반영됨을 확인(49→43개 노드), `Aggregate Run Stats`/`Save Run_Log` 등 Run_Log 관련 노드 생존 확인.

## Telegram 완료 알림 (V1 확정, 사용자 최종 승인 완료)

`Aggregate Run Stats` 뒤에 병렬 가지로 4개 노드 추가: `Aggregate Run Stats` → (기존 `Save Run_Log`와 병렬로) → `Fetch Run Articles`(AI_Analysis 전체 조회, Google Sheets Read) → `Prepare Telegram Data`(Code, 데이터 가공 전담) → `Build Message`(Code, 문자열 렌더링 전담) → `Send Telegram Message`(Telegram, `text: {{ $json.message }}`만 사용).

**데이터/표현 분리**: `Prepare Telegram Data`는 이번 실행의 기사 필터링·정렬·그룹핑·Top3 선정·상태 판정(`EMPTY`/`NEW_ONLY`/`HAS_SELECTED`)까지 전부 담당하고, 구조화된 JSON 하나만 반환한다. `Build Message`는 그 JSON을 받아 문자열만 조립한다 — 비즈니스 로직이 전혀 없다. 추후 Google Docs 등 다른 출력 형식이 필요할 때 `Prepare Telegram Data`의 출력을 그대로 재사용하고 렌더링 노드만 새로 만들면 되도록 설계.

**실전 피드백으로 발견/수정된 것**
- **`article_saved` 지표 재정의**: `Build Company Summary`/`Aggregate Run Stats`의 `article_saved`는 실제로는 "Raw_News에 신규 저장된 기사 수"였고 AI_Analysis 저장 여부와 무관했음(모든 분기에서 `Prepare Importance Routing`이 계산한 값을 그대로 물려받음). Telegram에서는 "New Articles"로 라벨만 정확히 바꾸고, 실제 "AI Selected"(AI 분석+저장까지 완료된 기사 수)는 `Aggregate Run Stats`/`Run_Log` 스키마 변경 없이 `Prepare Telegram Data`가 이미 계산해둔 "이번 실행 필터링된 기사 배열의 길이"를 그대로 사용 — 새 집계 로직 불필요
- **0건 상태를 2가지로 분리**: `New Articles=0`(신규 저장 자체가 없음) vs `New Articles>0 AND AI Selected=0`(저장은 됐지만 중요도 기준 미통과) — 서로 다른 문구로 안내
- **종목코드 0 소실 원인 확인**: Companies 시트는 `"012450"`(문자열)로 정상 보존되어 있으나, Raw_News/AI_Analysis에는 `12450`(숫자)으로 저장되어 있음을 실제 조회로 확인. `Save Raw News`/`Save AI_Analysis`는 이미 `convertFieldsToString: false`로 설정되어 있어 n8n 쪽 변환이 아니라 **Google Sheets 컬럼 셀 서식(자동)에 의한 재해석**으로 추정. 근본 수정(컬럼 서식을 일반 텍스트로 변경)은 핵심 저장 노드를 건드리는 별도 작업으로 분리, 이번에는 `Prepare Telegram Data`에서 `String(ticker).padStart(6, '0')`로 표시만 보정
- **템플릿 축소 (실제 모바일 스크린샷 기준 2차 조정 후 최종)**: Priority/Category/Sentiment를 한 줄로 통합, Headline/Summary 라벨 제거, `Read →` → `🔗 기사 보기`, "Analyst Note" 앞에 💡, 산업 구분은 대괄호 없이 `산업명 · 전체건수`, Execution Summary는 `label : value` 형식(`Companies`/`Relevant News`/`New Articles`/`AI Selected`/`Failed`). 구분선은 헤더 아래·Execution Summary 아래·같은 산업 그룹 내 기사 사이 3곳 모두 유지하되(개수·위치는 변경 없음), 실제 화면에서 가로로 길어 보인다는 피드백에 따라 길이만 20자 → 10자로 축소
- **Telegram 노드 자체 첨부 문구 중복 발견 및 수정**: 실제 수신 메시지에 우리가 만든 "Automated by n8n" 푸터 외에 n8n Telegram 노드가 기본으로 덧붙이는 "This message was sent automatically with n8n"이 함께 붙어 한 메시지에 푸터가 2개 나오는 버그를 스크린샷으로 확인. `Send Telegram Message`의 `additionalFields.appendAttribution`이 기본값(true)으로 비어있던 것이 원인 — `appendAttribution: false`로 명시 설정해 해결

**검증 (DEV, 4가지 상태 모두 실제 Telegram 전송으로 확인, 최종 템플릿 기준)**: `HAS_SELECTED`(기사 2건으로 그룹 내 구분선 동작 포함 확인) / 기존 한화에어로스페이스 데이터로 상세 블록 포맷 별도 비교 검증 / `NEW_ONLY`(신규 저장 O, AI 선정 0) / `EMPTY`(신규 저장 0) / 4096자 초과 자동 분할(합성 데이터 40건, 2개 조각 4053/1073자) / 푸터 중복 제거 확인.

**사용자가 프로덕션 실사용 중 확정과 함께 제안한 개선 아이디어(백로그로 기록, TASKS.md Phase 6)**: 동일 기사(URL)가 여러 기업에 매핑된 경우(예: 삼성전자·SK하이닉스가 함께 언급된 기사) 현재는 회사별로 각각 집계되어 Top3 안에서 같은 기사가 중복 노출될 수 있음. 관련성 판단 자체는 회사별로 유지하되, `Prepare Telegram Data`의 Top3 선정 직전 단계에서만 `normalized_url`/`url` 기준 중복 제거 후 재선정하는 방식으로 개선 검토 예정 — 급하지 않은 UX 개선 항목.

## Changed Files

- `n8n/workflows/news-collector.json` — 프로덕션 최종 상태(48개 노드)로 재-export, 평문 키 없음 확인
- `docs/design.md` — v1.3. Run_Log 스키마(5.4절) 확정, MVP 범위에 오류 격리·Telegram 알림 반영, NAVER API 전환 사실 반영, 8절에 현재 구조로의 확장 사실과 SESSION_SUMMARY.md 참조 추가
- `docs/SESSION_SUMMARY.md` — 이번 세션 전체 작업 기록 (오류 격리 아키텍처, 보안 재발 대응, Run_Log, 프로덕션 정리, Telegram 완료 알림)
- `docs/TASKS.md`, `docs/README.md` — 진행 상황 최신화

## Knowledge Added

프로젝트 산출물이 아니라, 이 프로젝트 밖에서도 재사용 가능한 일반 지식으로 워크스페이스 공용 knowledge 디렉터리에 추가함 (`ai-workspace/knowledge/`, 이 프로젝트 저장소 밖).

- `knowledge/n8n/n8n-execution-model.md` — **신규**. 이번 세션에서 실제 CLI/Integration Test로 검증한 내용을 프로젝트와 무관하게 일반화한 n8n 재사용 가능 Engineering Handbook (Core Execution Model, State Passing Pattern, Execution-scoped Shared State, Loop 설계, Error Handling, 테스트 전략, 운영 원칙)

## Decisions

프로젝트 아키텍처에 대한 확정 결정만 남긴다. 이번 세션에서만 의미가 있었던 작업 절차는 아래 "작업 환경 및 절차 메모" 참고.

- Google News RSS 대신 NAVER Search API를 최종 데이터 소스로 채택 (redirect 해석 불확실성 회피, 공식 문서화된 API, 하루 25,000회 무료 한도)
- AI_Analysis 스키마 확정: article_id/company_name/industry는 입력값 그대로 사용(Gemini 재생성 안 함), category/ai_summary/sentiment/keywords/reasoning은 Gemini 생성, importance는 Calculate Importance의 규칙 기반 점수 사용, confidence 제외
- category enum 유지(EARNINGS/CONTRACT/PRODUCT/POLICY/LAWSUIT/MNA/MANAGEMENT/SECURITY/MACRO/OTHER), CONTRACT 정의를 협력/제휴 관계까지 포괄하도록 명확화 (PARTNERSHIP enum 별도 추가 안 함)
- 오류 격리는 "Build Company Summary" 패턴(회사당 정확히 1개 제어 아이템 보장)으로 **확정**. Google Sheets Append의 필드 스트리핑 문제는 Fork+Merge(article_id 기준)로 해결, `$getWorkflowStaticData('global')`은 동시성/영속성 리스크로 기본 해법에서 제외하고 최후 보조 수단으로만 검토 대상 유지
- State Passing을 기본 원칙으로 채택, 노드 참조(`$('Node').item`/`.first()`/`.all()`)는 State Passing이 불가능할 때만 쓰는 예외 (일반 원칙은 `knowledge/n8n/n8n-execution-model.md` 2절, 이 프로젝트에서의 안전 조건 검증은 위 "참조 안전성" 절 참고)
- NAVER API 인증은 워크플로우 노드에 평문 헤더로 두지 않고 n8n Credential(`httpCustomAuth`, 이름: "NAVER Search API Header Auth")로 관리

## 작업 환경 및 절차 메모

프로젝트 아키텍처 결정이 아니라, 이 프로젝트의 개발 환경 설정과 Claude-사용자 간 작업 방식에 대한 메모. 다음 세션에서 동일한 방식으로 작업하려면 참고가 필요하지만, 위 Decisions와는 성격이 다르므로 구분해서 남긴다.

- **n8n CLI 직접 조작 방식**: n8n이 Docker 컨테이너(`n8n`)로 로컬 실행 중이며, `docker exec n8n n8n <command>`로 브라우저 UI 없이 워크플로우/크리덴셜을 import/export/execute 가능. `n8n execute --id=<id>`는 기본 Task Broker(5679 포트)가 메인 프로세스와 충돌하므로 `-e N8N_RUNNERS_BROKER_PORT=<다른 포트>`를 함께 넘겨야 함
- **워크플로우 편집·동시 저장 위험**: 편집 직전 항상 최신 상태를 다시 export한 뒤 수정하고, 백엔드로 프로덕션을 수정하는 동안에는 n8n 편집기 탭을 아예 닫아둔다 (이 프로젝트에서 실제로 두 차례 발생 — 프로덕션 데이터 안전사고, Phase B+C 반영 중 되돌림). 일반화된 원칙은 `knowledge/n8n/n8n-execution-model.md` 7절 참고
- **운영 워크플로우 변경 적용 방식**: 새로운 아키텍처(Fork+Merge 등 구조 변경)는 DEV에서 먼저 검증한 뒤 운영에는 사용자가 n8n UI에서 노드를 하나씩 직접 적용 — 사용자가 새 아키텍처를 직접 이해하며 반영하는 것이 목적. 설계가 이미 확정되고 반복적인 작업(보안 수정·Run_Log·Telegram)은 Claude가 DEV 검증 후 사용자 승인을 받아 백엔드(n8n CLI)로 직접 프로덕션에 반영. 어떤 방식으로 진행할지는 작업 성격(학습 목적 vs 합의된 설계의 반복 적용)에 따라 매번 확인

## Blockers

(현재 없음 — 오류 격리 아키텍처, Run_Log, Telegram 알림 모두 프로덕션 반영 및 검증 완료)

## Next Steps

이번 세션에서 계획했던 항목(프로덕션 정리, Run_Log, Telegram 알림)은 모두 완료됨. 남은 항목은 다음과 같음 (docs/TASKS.md Phase 6 백로그 참고):

1. NAVER API 키 재발급 (사용자가 NAVER Developer Center에서 직접 처리 예정)
2. 종목코드(ticker) Raw_News/AI_Analysis 저장 시 숫자로 변환되는 문제 근본 수정 (Google Sheets 컬럼 서식 변경 필요)
3. Telegram Top3 선정 시 동일 기사(URL) 중복 노출 방지 (급하지 않은 UX 개선)
4. Schedule Trigger 무인 실행 1주일 관찰 — 2026-08-02 워크플로우 활성화(active=true) 완료, 모니터링 시작
5. 프로덕션 데이터는 사용자가 직접 초기화 완료 (Companies는 유지, Raw_News/AI_Analysis/Run_Log는 헤더만 남기고 정리)
