# News Automation

국내 주요 산업의 상장기업 뉴스를 자동으로 수집하고, AI가 구조화하여 Google Sheets에 축적하는 개인 프로젝트입니다.

이 프로젝트는 자동매매 시스템이 아니며, 특정 개인의 보유 종목을 위한 도구도 아닙니다. 목표는 산업 대표기업 중심의 뉴스 인텔리전스 데이터셋을 지속적으로 쌓아 향후 분석에 활용하는 것입니다.

## 하는 일

- 하루 1회 관심기업(Companies 시트에서 관리) 관련 뉴스 자동 수집 (NAVER Search API)
- URL 해시 기준 중복 제거
- AI 요약 및 이벤트 분류 (구조화된 JSON)
- Google Sheets에 원본(Raw_News)과 AI 분석(AI_Analysis) 데이터 분리 저장
- 회사당 반드시 1개의 처리 결과가 남도록 보장하는 오류 격리 (관련 기사 0건/신규 기사 0건/고중요도 기사 0건/API 실패 등 모든 경우 포함)
- 실행 결과를 Run_Log에 기록 (실행당 정확히 1행)
- 실행 종료 후 Telegram으로 일일 요약 알림 발송 (산업별 그룹화, Priority 상위 기사 발췌)

## 기술 스택

- **n8n** — 워크플로우 자동화
- **Gemini API** — AI 기반 뉴스 요약 및 이벤트 분류 (무료 티어)
- **Google Sheets API** — 데이터 저장
- **Telegram Bot API** — 실행 완료 알림
- **Docker / WSL2** — 실행 환경

세부 모델 및 API 스펙은 [docs/design.md](./docs/design.md)에서 관리합니다.

## 폴더 구조

```
news-automation/
  README.md
  .gitignore
  docs/
    design.md              # 전체 설계 문서 (아키텍처, 스키마, 워크플로우, 프롬프트 설계)
    TASKS.md                # 진행 상황 체크리스트
    SESSION_SUMMARY.md      # 개발 세션 작업 기록 (내부 참고용)
    n8n-workflow-map.png    # 워크플로우 구조 다이어그램
  n8n/
    workflows/
      news-collector.json   # n8n 워크플로우 export (버전관리용)
  prompts/
    news-analysis-prompt.md # Gemini 프롬프트 템플릿
  seed/
    companies_seed.csv      # Companies 시트 초기 데이터
```

## 초기 등록 기업 (예시, Companies 시트에서 자유롭게 추가/비활성화 가능)

| 산업 | 기업 |
|---|---|
| 반도체 | 삼성전자, SK하이닉스 |
| 자동차 | 현대차, 기아 |
| 플랫폼 | NAVER, 카카오 |
| 2차전지 | LG에너지솔루션, 삼성SDI |
| 방산 | 한화에어로스페이스, LIG넥스원 |

## 현재 상태

핵심 파이프라인(뉴스 수집 → 필터링/신규 판별 → 원본·AI 분석 저장 → 오류 격리 → Run_Log 기록 → Telegram 알림)이 모두 구현되어 있습니다. 2026-08-02부터 워크플로우를 활성화(active=true)해 매일 자동 실행 중이며, 현재 1주일 무인 실행 모니터링 기간을 거치고 있습니다. 진행 상황은 [docs/TASKS.md](./docs/TASKS.md)를 참고하세요.

## 상세 설계

전체 아키텍처, Google Sheets 스키마, n8n 워크플로우 설계, AI 프롬프트 설계, 확장 로드맵은 [docs/design.md](./docs/design.md)를 참고하세요.
