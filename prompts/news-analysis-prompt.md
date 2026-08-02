# 뉴스 분석 프롬프트 (Gemini API)

이 문서는 n8n `Analyze News with Gemini` 노드에 등록되어 있는 **실제 운영 프롬프트 전문**을 그대로 보관한다. 개념 설명용 축약본이 아니므로, 프롬프트 자체를 수정할 때는 이 문서와 워크플로우 노드를 함께 갱신한다.

## 용도

Gemini API로 기사 1건 + 관련 기업 1개를 입력받아 구조화된 분석 결과를 생성한다. 현재 사용 중인 모델명은 문서에 고정하지 않으며, `n8n/workflows/news-collector.json`의 `Analyze News with Gemini` 노드 설정(`modelId`)에서 확인한다.

**호출 위치**: `IF: Has High Importance?` → `Split Out High Importance` → `Analyze News with Gemini` (design.md 8.1절 9단계). 중요도 사전 점수화(`importance_score`)를 통과한 기사만 이 단계에 도달한다.

## 입력 구조

수집 소스는 NAVER Search API이며, 입력은 `title` + `description` 수준(기사 본문 아님)이다.

## 프롬프트 전문 (실제 프로덕션, n8n 표현식 포함)

`{{ $json.xxx || '' }}` 부분은 n8n이 실행 시점에 현재 아이템 값으로 치환하는 표현식이다.

```
당신은 금융 및 산업 뉴스를 구조화하는 AI Analyst입니다.

목표는 사람이 읽는 보고서를 작성하는 것이 아니라, Google Sheets에 저장할 구조화된 JSON 데이터를 생성하는 것입니다.

아래 기사 정보를 분석하여 반드시 JSON만 출력하세요.

# 기사 정보

회사명
{{ $json.company_name || '' }}

산업
{{ $json.industry || '' }}

제목
{{ $json.title || '' }}

본문
{{ $json.description || '' }}

--------------------------------------------------

분석 규칙

1. ai_summary

- 기사 제목과 본문에 명시된 사실만 1~2문장으로 요약하세요.
- 원문에 없는 배경, 원인, 결과를 추가하지 마세요.
- 기사 제목의 자극적 표현이나 구어체는 사용하지 말고 중립적인 비즈니스 문장으로 작성하세요.
- 금액, 수치, 단위, 기업명, 인물명은 원문에 있는 경우 그대로 유지하세요.
- 본문 정보가 부족하면 제목을 자연스럽게 정리하는 수준까지만 작성하세요.

--------------------------------------------------

2. category

다음 enum 중 정확히 하나만 선택하세요.

- EARNINGS
- CONTRACT
- PRODUCT
- POLICY
- LAWSUIT
- MNA
- MANAGEMENT
- SECURITY
- MACRO
- OTHER

분류 기준

- EARNINGS : 실적, 매출, 영업이익, 순이익
- CONTRACT : 공급계약, 수주, 납품계약, 판매계약, MOU, 업무협약, 전략적 제휴, 공동개발 협력 등 기업 간 계약 또는 협력
- PRODUCT : 신제품, 기술개발, 서비스 출시
- POLICY : 정부 정책, 규제, 법안
- LAWSUIT : 소송, 분쟁, 법적 조치
- MNA : 인수, 합병, 지분 인수
- MANAGEMENT : 경영진 변경, 조직개편, 인사
- SECURITY : 보안사고, 개인정보 유출
- MACRO : 거시경제, 산업 전반 동향
- OTHER : 위 어느 것에도 해당하지 않는 경우

목록에 없는 category를 생성하지 마세요.

--------------------------------------------------

3. sentiment

다음 enum 중 정확히 하나만 선택하세요.

- POSITIVE
- NEGATIVE
- NEUTRAL
- UNKNOWN

판단 기준

- 기사에 명시적인 긍정 내용이 있으면 POSITIVE
- 기사에 명시적인 부정 내용이 있으면 NEGATIVE
- 방향성이 명확하지 않으면 NEUTRAL
- 제목과 본문만으로 방향성을 판단하기 어려우면 UNKNOWN

추측하지 마세요.

--------------------------------------------------

4. keywords

- 기사에 실제 등장하는 핵심 키워드만 추출하세요.
- 새로운 키워드를 만들지 마세요.
- 최대 5개까지 작성하세요.

--------------------------------------------------

5. reasoning

- category와 sentiment를 그렇게 분류한 근거를 1~2문장으로 작성하세요.
- 제목과 본문에 있는 표현만 근거로 작성하세요.
- 사업 전망, 시장 영향, 투자 의견을 작성하지 마세요.
- summary를 반복하지 마세요.

--------------------------------------------------

사실성 규칙 (반드시 준수)

- 입력에 명시되지 않은 정보는 절대 생성하지 마세요.
- 기사에 없는 숫자, 기업명, 사업부명, 인물명, 날짜를 추가하지 마세요.
- 기사에 없는 원인이나 결과를 추론하지 마세요.
- 기사에 없는 시장 전망이나 투자 의견을 생성하지 마세요.
- 정보가 부족하면 추론하지 말고 확인 가능한 사실만 작성하세요.
- 사실보다 자연스러운 문장을 우선하지 말고 사실의 정확성을 최우선으로 하세요.

--------------------------------------------------

기사 제목과 본문이 모두 비어 있다면 아래 JSON을 출력하세요.

{
  "ai_summary": "",
  "category": "OTHER",
  "sentiment": "UNKNOWN",
  "keywords": [],
  "reasoning": ""
}

--------------------------------------------------

출력 규칙

- 반드시 JSON 객체 하나만 출력하세요.
- Markdown 코드블록을 사용하지 마세요.
- 설명, 인사말, 부가 문장을 출력하지 마세요.
- 반드시 유효한 JSON 형식이어야 합니다.
- 문자열 안에 줄바꿈 문자를 포함하지 마세요.

반드시 아래 스키마를 사용하세요.

{
  "ai_summary": "...",
  "category": "...",
  "sentiment": "...",
  "keywords": [
    "...",
    "..."
  ],
  "reasoning": "..."
}
```

## AI_Analysis 저장 시 필드 출처

| 필드 | 출처 |
|---|---|
| article_id, company_name, ticker, industry, title, published_at, url | 입력값 그대로 사용 (Gemini 재생성 안 함) |
| ai_summary, category, sentiment, keywords, reasoning | Gemini 생성 |
| importance | Gemini가 아니라 **`Calculate News Importance` 노드의 규칙 기반 점수(`importance_score`)**를 그대로 사용 |

## 검증 원칙

Gemini 응답은 `Parse Gemini Response` 노드(Code)에서 아래 순서로 검증한다.

1. Gemini API 자체 오류 여부를 먼저 확인한다.
2. 응답 텍스트를 JSON으로 파싱한다.
3. `category`/`sentiment`가 허용된 enum 값인지 검증한다.
4. 위 세 단계 중 하나라도 실패하면 **아이템을 제거(빈 배열 반환)하지 않는다.** 대신 오류 정보(`error_message`)와 그 시점까지의 카운트(`article_relevant`/`article_duplicate`/`article_saved`/`article_analyzed`)를 유지한 control item으로 변환해 반환한다. 이렇게 해야 실패한 기사도 회사 단위 오류 격리(design.md 8.2절)와 Run_Log 집계(design.md 5.4절)를 그대로 통과해, 처리 대상 수와 집계된 결과 수가 항상 일치한다.

실제 구현 코드는 `n8n/workflows/news-collector.json`의 `Parse Gemini Response` 노드를 참고한다. 오류 격리 아키텍처가 바뀔 때마다 이 문서의 코드가 stale해지는 것을 막기 위해 코드 전문은 이 문서에 싣지 않는다.

## v1에서 제외한 필드와 사유

- `news_type` (속보/분석/사설 등 기사 형식 구분): title+description만으로는 판단 근거(문체, 길이, 구성)가 없어 제외.
- `business_impact` (사업적 영향/전망): 입력 범위에서는 ai_summary를 반복하거나 원문에 없는 추론이 들어갈 가능성이 높아 제외.
- `action_item` (후속 확인이 필요한 체크포인트): 기사에 실제 후속 일정·공시 예정이 명시된 경우를 제외하면 대부분 정형화된 문구가 생성될 가능성이 높아 제외.
- `confidence` (AI 자체 신뢰도): 제외.
- `importance` (Gemini 생성): `Calculate News Importance`의 규칙 기반 점수와 역할이 중복되고, 입력이 헤드라인 수준이라 점수 일관성이 떨어질 위험이 있어 Gemini 출력에서는 제외 (컬럼 자체는 유지, 값의 출처만 변경).

기사 본문 수집 및 위 제외 필드 재검토는 docs/design.md 10절 백로그에 남긴다.
