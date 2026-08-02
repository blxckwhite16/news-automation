# News Automation — 설계 문서

## 1. 프로젝트 목적

> 국내 주요 산업의 상장기업 뉴스를 자동 수집하고, AI를 활용해 관련 기업, 이벤트 유형, 예상 영향 방향과 중요도를 구조화하여 지속적으로 축적되는 데이터셋을 구축한다.

이 프로젝트는 자동매매 시스템이 아니며, 특정 개인의 보유 종목을 위한 도구도 아니다. 목표는 산업 대표기업 중심의 뉴스 인텔리전스 데이터셋을 지속적으로 쌓아 향후 분석에 활용하는 것이다.

## 2. MVP 범위

**포함**
- 하루 1회 배치 수집 (n8n 스케줄 트리거)
- Companies 시트의 active=TRUE 기업만 수집 대상
- URL 해시 기준 중복 제거 (한계는 7절 참고)
- AI 요약, 이벤트 분류, 영향 방향/중요도 산출 (구조화된 JSON)
- Google Sheets 저장 (Companies / Raw_News / AI_Analysis / Run_Log 4개 시트 분리)
- 회사당 반드시 1개의 처리 결과가 남도록 보장하는 오류 격리 아키텍처 (관련 기사 0건/신규 기사 0건/고중요도 기사 0건/API 실패 등 모든 경우 포함, 8.2절 참고)
- 실행 종료 후 Telegram으로 1회 발송하는 일일 요약 알림 (건별 실시간 알림이 아니라, 실행 전체에 대한 산업별 그룹화 + Priority 상위 기사 발췌 요약, 8.3절 참고)

**제외 (백로그, 10절 참고)**
- 건별 실시간 알림(기사 저장 즉시 개별 발송), 자동매매
- 다중 뉴스 소스 (NAVER Search API 단일 소스 유지)
- DART 공시 연동, 주가 데이터 연동, 대시보드
- 공통 피드 수집 방식 (전환 기준 도달 전까지는 기업별 API 조회 유지, 7절 참고)
- 제목/출처/발행시각 결합 보조 중복 판별 (7절 참고)

## 3. 시스템 아키텍처

```
[n8n Schedule Trigger] (매일 1회)
        |
        v
[Companies 시트 조회] (active = TRUE)
        |
        v
[기업별 Loop — 회사당 반드시 결과 1개 보장]
   - NAVER Search API 검색 (기업명 중심 검색식)
   - 관련성 필터 (제목/설명 매칭, 티커는 보조 신호) — 0건이면 즉시 결과 확정
   - Raw_News 기존 article_id 조회 -> 신규/중복 판별 — 신규 0건이면 즉시 결과 확정
   - Raw_News 저장 (AI 분석 이전에 원본부터 저장, 실패 시에도 결과 확정)
   - 중요도 사전 점수화 (키워드 기반) -> 임계값 미만은 Gemini 호출 생략, 0건이면 즉시 결과 확정
   - Gemini API 호출 (임계값 이상만)
   - JSON 파싱/검증 (category/sentiment enum 값 검증, company_name/industry/importance는 입력값으로 재결합)
   - AI_Analysis 저장 (검증 통과 시, 실패 시에도 결과 확정)
   - 위 모든 경로가 결국 회사당 결과 1개로 합류 (오류 격리 아키텍처, 8.2절 참고)
        |
        v
[실행 통계 집계] -> [Run_Log 저장 (error_summary 포함)] -> [Telegram 일일 요약 발송]
```

핵심 원칙:
1. 필터링과 중복 제거는 AI 호출 이전에 수행해 비용을 아낀다.
2. 신규 기사는 AI 분석 성공 여부와 무관하게 Raw_News에 먼저 저장해, Gemini API 호출이 실패해도 원본은 보존되고 이후 재분석이 가능하다.
3. 기업별 Loop의 어떤 경로를 타든(정상 완료/각 단계 0건/각 단계 실패) 회사당 반드시 정확히 1개의 결과가 남아, Run_Log 집계와 Telegram 요약이 항상 실제 처리 대상 수와 일치하도록 보장한다.

## 4. 폴더 구조

```
news-automation/
  README.md
  docs/
    design.md              # 이 문서 — 전체 설계
  n8n/
    workflows/
      news-collector.json   # n8n 워크플로우 export (버전관리용)
  prompts/
    news-analysis-prompt.md   # AI 프롬프트 템플릿
  seed/
    companies_seed.csv        # Companies 시트 초기 데이터
```

config/companies.json은 사용하지 않는다. 관심기업 관리는 전적으로 Companies 시트에서 이루어지며, 이를 통해 워크플로우나 코드를 건드리지 않고 기업을 추가하거나 제외할 수 있다.

## 5. Google Sheets 스키마

### 5.1 Companies

| 컬럼 | 타입 | 설명 |
|---|---|---|
| company_name | 문자열 | 정식 명칭. canonical key. AI_Analysis.company_name과 정확히 일치해야 함 |
| ticker | 문자열 | 종목코드 (6자리) |
| market | 문자열 | KOSPI 또는 KOSDAQ |
| industry | 문자열 | 산업분류 |
| aliases | 문자열 | 검색 및 필터링용 별칭 (콤마 구분). 이름 계열 별칭과 종목코드를 함께 저장하되 용도는 구분됨 (6절 참고) |
| active | 불리언 | TRUE 또는 FALSE, 수집 대상 여부 |

**초기 등록 기업 (5개 산업 x 2개 = 10개)**

| company_name | ticker | market | industry | aliases | active |
|---|---|---|---|---|---|
| 삼성전자 | 005930 | KOSPI | 반도체 | 삼성전자,Samsung Electronics,005930 | TRUE |
| SK하이닉스 | 000660 | KOSPI | 반도체 | SK하이닉스,SK Hynix,000660 | TRUE |
| 현대차 | 005380 | KOSPI | 자동차 | 현대차,현대자동차,Hyundai Motor,005380 | TRUE |
| 기아 | 000270 | KOSPI | 자동차 | 기아,기아자동차,Kia,000270 | TRUE |
| NAVER | 035420 | KOSPI | 플랫폼 | 네이버,NAVER,035420 | TRUE |
| 카카오 | 035720 | KOSPI | 플랫폼 | 카카오,Kakao,035720 | TRUE |
| LG에너지솔루션 | 373220 | KOSPI | 2차전지 | LG에너지솔루션,LG Energy Solution,LGES,373220 | TRUE |
| 삼성SDI | 006400 | KOSPI | 2차전지 | 삼성SDI,Samsung SDI,006400 | TRUE |
| 한화에어로스페이스 | 012450 | KOSPI | 방산 | 한화에어로스페이스,Hanwha Aerospace,012450 | TRUE |
| LIG넥스원 | 079550 | KOSPI | 방산 | LIG넥스원,LIG Nex1,079550 | TRUE |

이 목록은 초기 예시이며, 운영 중 Companies 시트에서 자유롭게 추가하거나 비활성화(active=FALSE)할 수 있다.

### 5.2 Raw_News (원본, 불변)

기사와 기업의 조합 단위로 저장한다. 동일 기사가 여러 기업의 검색 결과에 각각 걸리면, 기업마다 별도 행이 생긴다 (5.3절 AI_Analysis와 동일한 1:N 구조).

| 컬럼 | 타입 | 설명 |
|---|---|---|
| article_id | 문자열 | 정규화된 URL의 해시값 (기사 자체를 식별) |
| company_name | 문자열 | 관련 기업 정식 명칭 |
| ticker | 문자열 | 관련 기업 종목코드 |
| industry | 문자열 | 관련 산업 |
| title | 문자열 | 기사 제목 |
| description | 문자열 | 검색 결과 요약/설명 (Gemini 분석 시 입력 텍스트로 사용) |
| source | 문자열 | 출처. MVP는 "NAVER" 고정, 향후 "DART" 등으로 확장 가능 |
| published_at | 일시 | 발행 시각 |
| collected_at | 일시 | 수집 시각 |
| url | 문자열 | 기사 URL |

**중복 판별 기준**: `article_id` 단독이 아니라 **`article_id + ticker` 조합**을 기준으로 신규/중복을 판별한다 (7.2절 참고). company_name이 아닌 ticker를 조합 키로 쓰는 이유는, 기업 표기 방식(예: 정식 명칭 표기 변경)이 바뀌어도 ticker는 고정된 식별자이기 때문이다.

**보관 정책(staging layer)**: Raw_News는 단순 임시 데이터가 아니라, 중요도 필터 기준이 바뀌거나 Gemini 분석이 실패했을 때 재분석할 수 있도록 원본을 보관하는 영역이다. 향후 정리(cleanup)를 도입하더라도 **정리 대상은 AI_Analysis에 이미 분석 결과가 남아있는 행으로 한정**하며, 중요도 사전 필터에서 제외되어 AI_Analysis에 기록이 없는 기사는 계속 보존한다. 실제 정리 주기와 구현 방식은 별도 Task로 설계한다 (10절 백로그 참고).

### 5.3 AI_Analysis (AI 분석 결과, 재생성 가능)

기업별 조회 구조를 유지하므로, AI는 매 호출마다 현재 처리 중인 company_name 하나를 기준으로 분석을 수행한다. 동일 기사가 여러 기업의 검색 결과에 각각 나타나면, 그 기사에 대해 기업별로 별도의 분석이 이루어지고 AI_Analysis에는 기업 수만큼 행이 생긴다. 즉 이 시트의 논리적 고유 키는 article_id + company_name이며, Raw_News(1행 = 1기사)와 달리 1:N 관계를 가진다.

| 컬럼 | 타입 | 설명 |
|---|---|---|
| article_id | 문자열 | Raw_News와 연결되는 키 |
| company_name | 문자열 | 분석 대상 기업. **Gemini가 생성하지 않고 입력값을 그대로 사용** (9절 참고) |
| industry | 문자열 | 관련 산업. company_name과 동일하게 입력값 그대로 사용 |
| category | 문자열(enum) | 이벤트 유형, Gemini 생성 (9절 참고) |
| ai_summary | 문자열 | AI 요약 (2~3문장), Gemini 생성 |
| sentiment | 문자열(enum) | 예상 영향 방향, Gemini 생성 (9절 참고) |
| importance | 정수 | 중요도 (1~5). **Gemini가 생성하지 않고, 중요도 사전 점수화 단계(8.1절)의 규칙 기반 점수를 그대로 사용** |
| keywords | 문자열 | 기사에 실제로 등장한 핵심 키워드 2~5개, Gemini 생성 (콤마 구분 저장) |
| reasoning | 문자열 | category/sentiment 판단 근거, Gemini 생성 |

article_id와 company_name 조합이 이미 존재하면 재분석 시 해당 행을 갱신(overwrite)하는 것을 원칙으로 하며, 이는 MVP 이후 재분석 기능을 구현할 때 그대로 적용된다.

### 5.4 Run_Log (실행 결과 기록)

오류 격리 아키텍처(회사당 정확히 1개의 결과 아이템 보장, 8.2절 참고)를 전제로 회사 단위 집계를 기록한다.

| 컬럼 | 타입 | 설명 |
|---|---|---|
| run_id | 문자열 | 실행 고유 ID. `yyyyMMdd_HHmmss` 형식 |
| started_at | 일시 | 실행 시작 시각. 루프 내 첫 단계에서 실행 범위 공유 상태(execution-scoped state)로 최초 1회만 생성해, 이후 루프 전체와 집계 단계에서 동일한 값을 조회한다 |
| finished_at | 일시 | 실행 통계 집계 시각 |
| run_status | 문자열 | `SUCCESS` / `PARTIAL_SUCCESS` / `FAILED` — 판정 기준은 아래 참고 |
| company_total | 정수 | Companies 조회(active=true)가 반환한 회사 수. 결과 아이템 수로 대체하지 않고 독립적으로 집계해 교차검증한다 |
| company_completed | 정수 | 운영 오류 없이 정상 종료한 회사 수. `COMPLETED`/`NO_RELEVANT_ARTICLES`/`NO_NEW_ARTICLES`/`NO_HIGH_IMPORTANCE_ARTICLES` 전부 포함 (이 4가지는 에러가 아닌 정상 종료 상태) |
| article_relevant | 정수 | 관련성 필터를 통과한 기사 수 합 (전체 수집 기사 수가 아님) |
| article_duplicate | 정수 | 관련 기사 중 기존 Raw_News에 이미 있던 기사 수 합 |
| article_saved | 정수 | Raw_News에 실제 신규 저장된 기사 수 합 (= article_relevant − article_duplicate) |
| article_analysis_failed | 정수 | Gemini 분석을 시도했지만 실패한 기사 수 합 (JSON 파싱 실패, enum 검증 실패, API 에러 포함) |
| company_failed | 정수 | 아래 단계 중 하나라도 실제 오류가 발생한 회사 수(기사 건수 아님, 회사당 최대 1). NAVER 검색 실패 / Raw_News 저장 실패 / Gemini 분석 실패 1건 이상 / AI_Analysis 저장 실패 / 기타 명시적 실패 |
| error_summary | 문자열 | 실패가 있었던 회사들의 `company_name: error_message`를 모은 문자열. 정합성 불일치 시 아래 형식 추가 포함 |

**run_status 판정 기준**
```
company_total === 0                                    → FAILED
company_total !== company_completed + company_failed    → FAILED (집계/흐름 누락 오류로 간주, PARTIAL_SUCCESS로 완화하지 않음)
company_failed === 0                                     → SUCCESS
0 < company_failed < company_total                       → PARTIAL_SUCCESS
company_failed === company_total                         → FAILED
```

**company_failed 판정 기준** (회사당 결과 아이템 1개당 아래 중 하나라도 해당하면 실패로 카운트)
```
result_type === 'FAILED'
OR error_message가 null/빈 문자열이 아님   (AI_Analysis 저장 실패 케이스 포함 — result_type은 COMPLETED로 유지되지만 실패로 집계)
OR article_failed > 0                        (Gemini 분석 부분 실패 케이스)
```

**정합성 불일치 처리**: `company_total !== company_completed + company_failed`인 경우(회사가 통째로 누락되는 경우), 조용히 넘어가지 않고 `run_status = FAILED`로 설정하고 `error_summary`에 company_total/company_completed/company_failed/누락 건수/가능하면 누락된 company_name을 포함한다.

error_summary는 상세 로그가 아니라 실행 결과를 한눈에 훑어볼 용도임을 원칙으로 한다.

## 6. aliases 사용 방식

aliases 컬럼의 값을 그대로 결합해 검색식으로 쓰지 않는다. 워크플로우는 aliases를 두 종류로 구분해서 사용한다.

- 이름 계열 별칭 (한글 정식명, 영문명, 일반적으로 쓰이는 약칭): 검색식 구성에 사용. 예: "삼성전자" OR "Samsung Electronics". 정식 명칭 중심으로 검색해 재현율과 정확도의 균형을 맞춘다.
- 숫자로만 이루어진 종목코드: 검색식에서는 제외한다. 숫자만으로 검색하면 무관한 결과가 섞여 노이즈가 커지기 때문이다. 대신 관련성 필터링 단계에서 기사 본문/제목에 종목코드가 함께 언급되는지 확인하는 보조 신호로만 사용한다.

## 7. 뉴스 수집과 중복 제거 방식

### 7.1 기업별 API 조회 vs 공통 피드 매칭

| 구분 | A. 기업별 API 조회 | B. 공통 피드 수집 후 매칭 |
|---|---|---|
| 호출 횟수 | 기업 수에 비례 | 고정 (기업 수 무관) |
| 관련성 정확도 | 높음 | 낮을 수 있음 (넓은 피드를 키워드로 재분류) |
| 재현율(기사 누락 위험) | 낮음 | 있음. 공통 피드가 특정 기업 기사를 안 담을 수 있음 |
| 구현 난이도 | 낮음 | 높음 (매칭 로직, 노이즈 필터링 필요) |

결정: MVP(10개 기업)는 A(기업별 API 조회)를 유지한다. 현재 규모에서는 호출량 증가가 실질적 문제가 아니며, 기업별 뉴스 누락 가능성을 낮추는 것이 데이터 품질 관점에서 더 중요하다. "기업별 API 조회" 블록은 워크플로우 내에서 하나의 캡슐화된 단위로 유지되어, 이후 B로 전환하더라도 뒤따르는 필터링/중복제거/AI분석/저장 로직은 그대로 재사용 가능하다.

전환 재검토 기준 (다음 중 하나라도 충족 시):
- 활성 기업(Companies 시트 active=TRUE) 수가 20~30개 이상으로 증가
- API 호출 실패율 또는 전체 실행 시간이 실제 운영에 지장을 줄 정도로 증가

### 7.2 중복 제거 기준과 한계

정규화한 URL(추적 파라미터 등 제거)의 해시값을 article_id로 사용한다. 다만 신규/중복 판별은 article_id 단독이 아니라 **`article_id + ticker` 조합**을 기준으로 한다.

**article_id + ticker 조합을 쓰는 이유**: article_id만으로 판별하면, 동일 기사가 여러 기업의 검색 결과에 함께 걸렸을 때 먼저 처리된 기업에게만 저장되고 나머지 기업에서는 "이미 존재함"으로 걸러져 분석 자체가 누락되는 문제가 있다. 예를 들어 두 기업이 함께 언급된 산업 기사는 두 기업 모두에게 개별적으로 분석될 필요가 있는데, article_id 단독 키로는 이것이 불가능하다. ticker를 조합해 기업별로 독립적인 신규/중복 판별이 이루어지도록 한다.

알려진 한계: URL 해시 기준 중복 제거는 동일한 원본 기사라도 추적 파라미터, 리디렉션 링크, 애그리게이터 경유 링크 등으로 다른 URL로 노출되면 같은 기사로 인식하지 못해 중복이 그대로 저장될 수 있다. MVP 단계에서는 이 한계를 감수하고 URL 해시 기준만 사용한다.

백로그: 운영 중 실제 중복률을 관찰했을 때 유의미하게 높다면, 제목과 출처와 발행 시각을 결합한 보조 중복 판별 로직을 추가하는 것을 다음 확장 과제로 남긴다.

## 8. n8n 워크플로우 설계

전체 노드 구성은 `docs/n8n-workflow-map.png`를 참고한다.

### 8.1 처리 흐름

아래는 파이프라인의 핵심 처리 단계다. 실제 프로덕션 워크플로우는 각 단계에 오류 격리 분기와 데이터 무결성 검증이 추가되어 더 많은 노드로 구성되어 있으며(8.2절), 정확한 노드 구성과 연결은 `n8n/workflows/news-collector.json`(실제 export본)을 최신 기준으로 참고한다.

1. **Schedule Trigger** — 매일 정해진 시각(08:30 Asia/Seoul) 실행
2. **Companies 조회** — active=TRUE 행만 조회
3. **기업별 Loop** — 회사당 아래 단계를 순차 수행, 오류 격리 아키텍처로 감싸여 있음 (8.2절)
4. **NAVER Search API 검색** — 이름 계열 alias 기반 검색식 (6절)
5. **관련성 필터** — 제목/설명 매칭 확인, 종목코드는 보조 신호로만 사용
6. **신규/중복 판별** — Raw_News 기존 article_id 조회 결과와 비교, 신규 기사만 다음 단계로 전달 (7.2절)
7. **Raw_News 저장** — AI 분석 이전에 원본 기사 저장
8. **중요도 사전 점수화** — 키워드 기반 스코어링으로 Gemini 호출 대상 축소
9. **Gemini API 호출** — 8단계 임계값 이상만 호출, 구조화 프롬프트 (9절 스키마)
10. **JSON 파싱/검증** — category/sentiment enum 값 검증, company_name/industry/importance는 입력값으로 재결합
11. **AI_Analysis 저장** — 검증 통과 시 분석 결과 저장
12. **실행 통계 집계 → Run_Log 저장** (5.4절)
13. **Telegram 요약 알림 발송** (8.3절)

**저장 순서에 대한 설계 원칙**: Raw_News 저장(7단계)은 반드시 Gemini API 호출(9단계)보다 앞에 둔다 — Gemini API 호출이 실패해도 원본 기사는 항상 보존되도록 하기 위함이다. 중요도 사전 점수화(8단계)도 반드시 Raw_News 저장 **뒤에** 배치한다 — Gemini 호출 여부를 줄이기 위한 필터일 뿐, Raw_News 저장 여부를 결정하는 필터가 아니기 때문이다. 이 순서를 지키지 않으면 저importance로 분류된 기사가 Raw_News에도 남지 않아 원본 데이터가 영구히 소실된다.

**중요도 사전 점수화 관련 주의사항**:
- 여기서 계산하는 점수는 실적/HBM/반도체/AI/주가 영향 등 키워드 기반 초기 휴리스틱이며, MANAGEMENT·LAWSUIT·POLICY 등 이벤트 유형은 이 키워드에 걸리지 않아 구조적으로 누락될 위험이 있다 (10절 백로그 참고).
- threshold(초기값 5)는 초기 후보군 축소 테스트용 잠정치이며, 운영 데이터를 보고 조정할 수 있다.
- 이 점수(`importance_score`)는 AI_Analysis.importance(규칙 기반이지만 최종 저장값)와 라우팅 목적이 다르므로 필드명을 구분해서 사용하고, Raw_News/AI_Analysis 시트 컬럼에는 저장하지 않는다 (라우팅 전용 임시 값).

### 8.2 오류 격리 아키텍처

파이프라인의 각 단계(관련 기사 검색, 신규 판별, 중요도 필터, Gemini 분석, 저장)는 정상적으로 0건이거나 실패할 수 있다. 관련 기사 0건, 신규 기사 0건, 고중요도 기사 0건, API 실패는 모두 에러가 아니라 정상적으로 발생 가능한 케이스다. 이 네 가지 중 하나라도 회사별 처리 결과를 조용히 누락시키면, Run_Log 집계와 Telegram 요약이 실제 처리 대상 수와 어긋나게 된다.

**원칙**: 파이프라인의 어떤 경로를 타든(정상 완료 / 각 단계 0건 / 각 단계 실패) 회사당 반드시 정확히 1개의 결과 아이템(`result_type` 포함)이 파이프라인 끝의 통합 지점에 도달하도록, 각 단계마다 조기 종료 분기를 둔다. 이 결과 아이템에는 이후 Run_Log 집계에 필요한 카운트(article_relevant, article_duplicate 등)가 필드로 직접 포함되어 있어(State Passing), 후속 단계가 이전 노드를 참조하지 않고도 결과를 조합할 수 있다.

**저장 데이터 무결성 (Fork + Merge)**: Google Sheets 저장 노드는 매핑된 컬럼만 반환하고 나머지 필드를 유실시키는 특성이 있다. 이 때문에 저장 직전 원본 전체를 별도로 보존해두었다가, 저장 성공 결과와 `article_id` 기준으로 재결합한다. 재결합 결과 건수가 저장 성공 건수와 다르면(레코드 누락) 즉시 명시적 에러를 발생시켜 조용한 데이터 유실을 방지한다. 저장 자체가 실패하는 경우에도 에러 출력을 결과 통합 지점으로 연결해, 저장 실패가 회사 전체의 결과 누락으로 이어지지 않도록 한다.

### 8.3 실행 결과 처리 (Run_Log · Telegram)

기업별 Loop가 모두 끝나면, 실행 전체에 대한 통계를 집계해 Run_Log에 1행으로 기록한다(스키마와 판정 기준은 5.4절). 이어서 이번 실행에서 새로 저장된 기사를 산업별로 그룹화하고, 그룹별 Priority 상위 기사를 선별해 Telegram으로 발송한다. 신규 저장 기사 자체가 없는 경우와, 저장은 됐지만 분석 기준(중요도 임계값)을 통과한 기사가 없는 경우는 서로 다른 안내 문구로 구분해 전달한다.

## 9. AI Prompt와 출력 스키마

**사용 모델**: Gemini API 무료 티어 모델을 사용한다. 무료 티어의 요청 한도는 시점에 따라 달라질 수 있어 특정 모델명을 이 문서에 고정하지 않으며, 현재 적용 중인 모델은 n8n 워크플로우(`n8n/workflows/news-collector.json`)의 Gemini 노드 설정에서 확인한다. 선택 기준은 기사 요약·JSON 구조화·이벤트 분류 수준의 작업에 충분한 성능과 무료 티어 요청 한도 내 동작 여부다.

n8n Gemini 노드는 별도의 구조화된 출력(response_schema) 옵션을 제공하지 않아, 응답 텍스트를 JSON으로 파싱하고 enum 값을 검증하는 별도 단계(8.1절 10단계)가 필요하다.

**입력 제약과 스키마 축소 배경**: 입력은 title + description 수준(기사 본문 아님)이다. 즉 모델이 받는 정보는 사실상 헤드라인 수준(15~20단어)뿐이다. 초기 테스트에서 이 입력만으로 "왜 중요한지", "사업적 영향", "후속 확인 사항" 같은 필드를 생성시켰더니, 입력에 없는 구체적 수치·사업부·인과관계를 모델이 지어내는 것이 확인되었다 (예: enum 목록에 없는 값을 만들어내거나, 요약을 그대로 반복하는 사례). 이 때문에 출력 스키마는 입력에 명시된 사실만으로 안정적으로 도출 가능한 필드로 한정한다.

```json
{
  "ai_summary": "string, 2~3문장, 제목/설명에 있는 사실만으로 구성",
  "category": "EARNINGS | CONTRACT | PRODUCT | POLICY | LAWSUIT | MNA | MANAGEMENT | SECURITY | MACRO | OTHER",
  "sentiment": "POSITIVE | NEGATIVE | NEUTRAL | UNKNOWN",
  "keywords": ["string"],
  "reasoning": "string, category/sentiment 판단 근거만 (사업적 영향/전망 서술 금지)"
}
```

**category와 sentiment를 enum으로 고정하는 이유**: 자유 텍스트로 받으면 표현이 매번 달라져 시트에서 집계와 필터링이 불가능해진다. 프롬프트에서 category별 판단 기준(예시)을 명시하고, JSON 파싱 단계에서 허용된 enum 값인지 재검증한다.

**CONTRACT의 정의**: 공급계약, 수주뿐 아니라 MOU, 업무협약, 전략적 제휴, 공동개발 협력 등 기업 간 협력 관계 발표를 모두 포함한다. 법적으로 계약인지 여부를 따지는 것이 아니라, 기업 이벤트를 하나의 기준으로 일관되게 분류하는 것이 목적이므로 별도의 PARTNERSHIP enum을 추가하지 않는다.

**sentiment 판단 기준**: 제목에 명시적인 긍정/부정 표현이 있을 때만 POSITIVE 또는 NEGATIVE로 판단한다. 계약 체결, 투자 검토, 조직 개편처럼 방향성이 명확하지 않은 기사는 추가로 추론하지 않고 UNKNOWN을 반환한다. 입력이 헤드라인 수준으로 제한적인 상황에서 모델이 방향성을 억지로 추측하지 않도록 하기 위함이다.

**importance를 Gemini 출력에서 제외한 이유**: (1) 중요도 사전 점수화 단계(8.1절)가 이미 규칙 기반으로 중요도를 계산하고 있어 역할이 중복되고, (2) 헤드라인 수준의 짧은 입력만으로 Gemini가 1~5점을 매기면 언론사의 제목 표현 강도나 모델의 자의적 판단에 따라 점수 일관성이 떨어질 위험이 있다. 따라서 AI_Analysis.importance는 Gemini 응답이 아니라 규칙 기반 점수를 그대로 사용한다.

**company_name/industry를 Gemini에게 생성시키지 않는 이유**: 입력값을 그대로 사용하면, "AI가 반환한 이름이 정식 명칭과 일치하는지 검증"하는 절차 자체가 필요 없어진다. Gemini가 오탈자나 별칭을 반환할 위험을 구조적으로 제거하는 방식이다.

**v1에서 제외한 필드와 사유**:
- `news_type`(속보/분석/사설 등 기사 형식 구분): 헤드라인만으로는 판단 근거(문체, 길이, 구성)가 없어 제외. 향후 기사 본문이나 추가 메타데이터를 확보하면 재검토한다.
- `why_important`, `business_impact`(사업적 영향/전망): 입력에 없는 내용을 모델이 설명하려면 결국 지어낼 수밖에 없어 제외.
- `action_item`(후속 확인이 필요한 체크포인트): 투자자문 성격이라서가 아니라, title+description만으로 후속 확인 항목을 만드는 과정에서도 입력에 없는 맥락을 추론할 가능성이 있어 v1에서는 제외. 매수/매도 등 투자 포지션 제안이 아닌 정보성 체크포인트 개념이며, 향후 본문 확보 시 재검토한다.
- `confidence`(AI 자체 신뢰도): 이번 버전에서 제외.

기사 원문(본문) 수집은 MVP 범위를 벗어나므로 현재 진행하지 않으며, 위 제외 필드들과 함께 10절 백로그에 남긴다.

## 10. 확장 로드맵 (MVP 이후 백로그)

- 중요도 사전 점수화의 키워드 세트를 이벤트 유형별(MANAGEMENT, LAWSUIT, POLICY 등)로 보완해 특정 유형 누락 편향 완화
- Raw_News cleanup 정책 구현: AI_Analysis에 분석 결과가 이미 있는 행만 정리 대상으로 삼고, 중요도 필터로 미분석된 행은 계속 보존 (5.2절 보관 정책 참고)
- 뉴스 수집을 공통 피드 방식으로 전환 (7.1절 기준 도달 시)
- 제목, 출처, 발행시각 결합 보조 중복 판별 추가 (7.2절 기준 도달 시)
- 다중 뉴스 소스 추가
- DART 공시 연동. Raw_News.source를 "DART"로 확장해 동일 파이프라인(필터, 중복제거, 저장, AI분석) 재사용
- 주가 데이터 연동. Companies.ticker와 Raw_News.published_at을 조인 키로 활용
- AI/규칙 기반 판단(category, sentiment, importance)과 실제 주가 반응 비교 분석
- 기사 원문(본문) 수집 및 news_type/why_important/business_impact/action_item 필드 재검토 (현재는 헤드라인 수준 입력으로 인한 환각 위험으로 v1 제외, 9절 참고)
- Looker Studio 또는 Tableau 대시보드
- 실시간 알림, 자동매매 (프로젝트 목적 범위 밖이므로 장기 백로그로만 유지)
- 동일 기사(URL)가 여러 기업에 매핑된 경우 Telegram Top3 선정 시 중복 노출 방지 (관련성 판단 자체는 회사별 유지, Top3 선정 직전에만 URL 기준 중복 제거)

## 11. 설계 결정 (Architecture Decisions)

프로젝트 진행 중 있었던 주요 설계 결정과 그 이유를 정리한다.

### Data Architecture

- **Raw_News / AI_Analysis 분리 저장** — 원본과 AI 분석 결과를 분리해, Gemini 분석이 실패하거나 분류 기준이 바뀌어도 원본은 항상 보존되고 재분석이 가능하도록 했다.
- **URL 해시 + ticker 조합 기반 중복 제거** — article_id(정규화 URL 해시) 단독이 아니라 ticker와 조합해 신규/중복을 판별함으로써, 여러 기업이 함께 언급된 기사도 기업별로 독립적으로 분석되도록 했다.

### Workflow Architecture

- **NAVER Search API 채택** — 최초에는 Google News RSS로 데이터 소스를 검토했으나, redirect 해석 불확실성을 피하고 공식 문서화된 API를 사용하기 위해 NAVER Search API(일 25,000회 무료 한도)로 전환했다.
- **AI 호출 전 중요도 사전 필터링** — 규칙 기반 점수로 후보를 먼저 축소해 Gemini API 호출 비용과 횟수를 줄인다. 이 필터는 Raw_News 저장 이후에만 적용되어 원본 데이터 자체는 손실되지 않는다.
- **State Passing 원칙** — 노드 간 참조(pairedItem) 대신 각 아이템이 필요한 데이터를 필드로 직접 들고 다니게 해, 분기·병합이 섞인 구조에서도 데이터 흐름의 안전성을 구조적으로 보장한다.

### AI Design

- **importance는 규칙 기반 점수 사용, Gemini 출력에서 제외 (9절)** — 헤드라인 수준 입력만으로는 AI가 매기는 점수의 일관성이 떨어질 위험이 있고, 이미 규칙 기반 스코어링과 역할이 중복되기 때문이다.
- **company_name/industry는 Gemini가 생성하지 않고 입력값 그대로 사용 (9절)** — 정식 명칭 오탈자나 별칭 반환 위험을 구조적으로 제거하기 위함이다.

### Reliability

- **Company 단위 오류 격리 (8.2절)** — 관련 기사 0건, 신규 기사 0건, 고중요도 기사 0건, API 실패를 모두 정상적으로 발생 가능한 케이스로 취급해, 회사당 정확히 1개의 결과가 항상 남도록 설계했다. Run_Log와 Telegram 요약이 실제 처리 대상 수와 항상 일치하도록 보장하는 것이 목적이다.
- **Fork + Merge 기반 저장 무결성 (8.2절)** — Google Sheets Append 노드가 매핑되지 않은 필드를 유실시키는 문제를 저장 직전 원본 보존 후 재결합으로 해결하고, 불일치 시 조용히 넘어가지 않고 명시적 에러를 발생시킨다.
- **Run_Log 무결성 우선 판정 (5.4절)** — company_total과 (company_completed + company_failed)의 합이 어긋나면 PARTIAL_SUCCESS로 완화하지 않고 FAILED로 판정해, 집계 누락을 조용히 넘기지 않는다.
