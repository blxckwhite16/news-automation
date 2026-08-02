# 뉴스 분석 프롬프트 (Gemini API)

## 용도

Gemini API(`models/gemini-3.5-flash-lite`)로 기사 1건 + 관련 기업 1개를 입력받아 구조화된 분석 결과를 생성한다. n8n 워크플로우의 "Gemini 분석" 노드(`If Score`의 True branch만 호출)에서 사용한다.

## 입력 구조

수집 소스는 NAVER Search API이며, 입력은 `title` + `description` 수준(기사 본문 아님)이다. 이 제약 때문에 출력 스키마는 입력에 명시된 사실만으로 안정적으로 도출 가능한 필드로 한정한다.

## 입력 (n8n 표현식으로 채워 넣을 값)

- `{{ $json.company_name }}`
- `{{ $json.industry }}`
- `{{ $json.title }}`
- `{{ $json.description }}`

## 프롬프트 템플릿

```
당신은 한국 금융/산업 뉴스를 구조화하는 분석가입니다.
아래 기사 제목과 설명만을 근거로, 지정된 JSON 형식으로만 응답하세요.
제목과 설명에 명시되지 않은 내용(구체적 수치, 세부 조건, 향후 일정, 사업적 파급효과 등)은 추측하지 마세요.
매수/매도, 투자 포지션 제안 등 투자자문에 해당하는 내용은 포함하지 마세요.

[관련 기업]
- 기업명: {{company_name}}
- 산업: {{industry}}

[기사]
- 제목: {{title}}
- 설명: {{description}}

[category 분류 기준 — 아래 중 정확히 하나를 대문자 그대로 반환]
- EARNINGS: 실적, 매출, 영업이익, 순이익, 흑자/적자 전환
- CONTRACT: 공급계약, 수주뿐 아니라 MOU, 업무협약, 전략적 제휴, 공동개발 협력 등 기업 간 협력 관계 발표를 모두 포함. 법적으로 계약인지 여부를 따지지 않고, 기업 간 협력/거래 관련 이벤트는 모두 CONTRACT로 분류
- PRODUCT: 신제품, 기술 개발, 출시
- POLICY: 정부 정책, 규제, 법안
- LAWSUIT: 소송, 분쟁, 법적 조치
- MNA: 인수, 합병, 지분 인수
- MANAGEMENT: 경영진 변경, 인사, 이사회 관련
- SECURITY: 보안 사고, 해킹, 개인정보 유출
- MACRO: 거시경제, 금리, 환율, 산업 전반 동향
- OTHER: 위 어디에도 해당하지 않는 경우

[sentiment 분류 기준 — 아래 중 정확히 하나를 대문자 그대로 반환]
- POSITIVE: 제목에 명시적인 긍정 표현이 있을 때만
- NEGATIVE: 제목에 명시적인 부정 표현이 있을 때만
- NEUTRAL: 긍정도 부정도 아님이 명확할 때만
- UNKNOWN: 계약 체결, 투자 검토, 조직 개편처럼 방향성이 명확하지 않을 때. 일반적인 사업 효과를 추론해서 POSITIVE/NEGATIVE로 판단하지 마세요.

[출력 필드]
- ai_summary: 제목과 설명에 있는 사실만으로 2~3문장 요약
- category: 위 목록 중 정확히 하나 (목록에 없는 값 반환 금지)
- sentiment: 위 목록 중 정확히 하나 (목록에 없는 값 반환 금지)
- keywords: 제목/설명에 실제로 등장하는 핵심 단어 2~5개 배열
- reasoning: category와 sentiment 판단 근거를 제목/설명에 있는 표현을 인용하는 수준으로 1~2문장. 사업 전망이나 영향 분석은 포함하지 마세요.

아래 JSON 형식으로만 응답하고, 다른 텍스트는 포함하지 마세요.
{
  "ai_summary": "",
  "category": "",
  "sentiment": "",
  "keywords": [],
  "reasoning": ""
}
```

## AI_Analysis 저장 시 필드 출처

| 필드 | 출처 |
|---|---|
| article_id, company_name, industry | 입력값 그대로 사용 (Gemini 재생성 안 함) |
| category, ai_summary, sentiment, keywords, reasoning | Gemini 생성 |
| importance | Gemini가 아니라 **Calculate Importance 노드의 규칙 기반 점수**를 그대로 사용 |

## JSON 파싱/검증 코드 (enum 강제)

n8n Gemini 노드에 구조화 출력(response_schema) 기능이 없어, 응답이 `content.parts[0].text`에 JSON 문자열로 온다. 목록에 없는 값(예: "Partnership")이 실제로 발생한 적이 있어, 파싱 단계에서 반드시 검증한다.

```javascript
const ALLOWED_CATEGORY = ["EARNINGS", "CONTRACT", "PRODUCT", "POLICY", "LAWSUIT", "MNA", "MANAGEMENT", "SECURITY", "MACRO", "OTHER"];
const ALLOWED_SENTIMENT = ["POSITIVE", "NEGATIVE", "NEUTRAL", "UNKNOWN"];

const raw = $input.item.json;
const input = $('If Score').item.json;

let parsed;
try {
  parsed = JSON.parse(raw.content.parts[0].text);
} catch (e) {
  return [];
}

const categoryValid = ALLOWED_CATEGORY.includes(parsed.category);
const sentimentValid = ALLOWED_SENTIMENT.includes(parsed.sentiment);

if (!categoryValid || !sentimentValid) {
  return [{
    json: {
      article_id: input.article_id,
      validation_error: `invalid category="${parsed.category}" or sentiment="${parsed.sentiment}"`
    }
  }];
}

return {
  json: {
    article_id: input.article_id,
    company_name: input.company_name,
    industry: input.industry,
    category: parsed.category,
    ai_summary: parsed.ai_summary,
    sentiment: parsed.sentiment,
    importance: input.importance_score,
    keywords: Array.isArray(parsed.keywords) ? parsed.keywords.join(', ') : '',
    reasoning: parsed.reasoning
  }
};
```

`$('If Score')`와 `importance_score`는 실제 n8n 워크플로우의 노드 이름/필드명에 맞춰 조정한다.

## v1에서 제외한 필드와 사유

- `news_type` (속보/분석/사설 등 기사 형식 구분): title+description만으로는 판단 근거(문체, 길이, 구성)가 없어 제외.
- `business_impact` (사업적 영향/전망): 입력 범위에서는 ai_summary를 반복하거나 원문에 없는 추론이 들어갈 가능성이 높아 제외.
- `action_item` (후속 확인이 필요한 체크포인트): 기사에 실제 후속 일정·공시 예정이 명시된 경우를 제외하면 대부분 정형화된 문구가 생성될 가능성이 높아 제외.
- `confidence` (AI 자체 신뢰도): 제외.
- `importance` (Gemini 생성): Calculate Importance의 규칙 기반 점수와 역할이 중복되고, 입력이 헤드라인 수준이라 점수 일관성이 떨어질 위험이 있어 Gemini 출력에서는 제외 (컬럼 자체는 유지, 값의 출처만 변경).

기사 본문 수집 및 위 제외 필드 재검토는 docs/design.md 10절 백로그에 남긴다.
