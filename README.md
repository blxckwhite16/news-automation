# News Automation

국내 주요 산업의 상장기업 뉴스를 자동으로 수집하고, AI가 구조화하여 Google Sheets에 축적하는 개인 프로젝트입니다.

이 프로젝트는 자동매매 시스템이 아니며, 특정 개인의 보유 종목을 위한 도구도 아닙니다. 목표는 산업 대표기업 중심의 뉴스 인텔리전스 데이터셋을 지속적으로 쌓아 향후 분석에 활용하는 것입니다.

## Workflow Overview

아래는 실제 실행된 프로덕션 워크플로우의 n8n 캔버스입니다. 초록 체크는 정상 완료된 노드, 각 화살표의 숫자는 해당 구간을 실제로 통과한 아이템 수입니다 — 다이어그램이 아니라 실행 결과 스크린샷입니다.

![News Automation Workflow v1.1.0](docs/n8n-workflow-map_v1.1.0.png)

50개 노드로 구성되어 있으며, 단순 수집을 넘어 회사 단위 오류 격리·저장 데이터 무결성·실행 로그·기사 단위 재시도까지 포함합니다.

## 주요 기능

- 하루 1회 관심기업(Companies 시트에서 관리) 관련 뉴스 자동 수집 (NAVER Search API)
- URL 해시 기준 중복 제거
- AI 요약 및 이벤트 분류 (구조화된 JSON)
- Google Sheets에 원본(Raw_News)과 AI 분석(AI_Analysis) 데이터 분리 저장
- 회사당 반드시 1개의 처리 결과가 남도록 보장하는 오류 격리
- 실행 결과를 Run_Log에 기록 (실행당 정확히 1행)
- 실행 종료 후 Telegram으로 일일 요약 알림 발송

## 핵심 설계

- **Company 단위 오류 격리** — 관련 기사 0건, API 실패 등 모든 경우에도 회사당 정확히 1개의 결과가 남도록 보장
- **Raw_News / AI_Analysis 분리** — 원본과 AI 분석 결과를 분리 저장해 재분석 시에도 원본은 항상 보존
- **AI 호출 전 중요도 필터링** — 규칙 기반 점수로 후보를 먼저 줄여 Gemini API 호출을 최소화
- **Fork + Merge 기반 데이터 무결성** — 저장 단계의 필드 유실 문제를 원본 보존 + 재결합으로 해결, 불일치 시 명시적 에러 발생
- **Run_Log 무결성 판정** — 집계가 어긋나면 조용히 넘어가지 않고 FAILED로 판정
- **Telegram 일일 요약** — 산업별 그룹화와 Priority 상위 기사 발췌로 실행 결과 요약 발송
- **기사 단위 순차 재시도** — Gemini API 호출을 회사당 배치가 아니라 기사 1건 단위로 순차 처리해, rate limit 발생 시 실패한 기사만 정확히 재시도되도록 보장
- **무인 실행 신뢰성** — 로컬 환경(Windows 절전/최대절전)에서도 재시작 없이 안전하게 배포하고 트리거를 재무장하는 운영 구조

각 설계의 배경과 근거는 [docs/design.md](./docs/design.md) 11절 "설계 결정"을 참고하세요.

## Reliability Engineering

v1.1.0은 기능 확장이 아니라, 무인 실행이 실제로 매일 안정적으로 도는지를 확인하고 다지는 데 집중한 릴리즈입니다.

**재시도와 속도 제어**
- Gemini 호출을 회사당 배치가 아니라 기사 1건 단위로 분리해, 실패한 기사만 정확히 재시도되도록 개선
- 기사 호출 사이에 대기 시간을 두어 API 요청 제한(rate limit) 발생 가능성을 완화
- 일부 기사만 실패해도 그 오류 메시지가 회사 단위 요약과 Run_Log까지 보존되도록 수정

**배포와 무인 실행 안정성**
- 프로덕션 배포 순서를 `REST API deactivate → CLI import → REST API activate`로 재설계 — 이 순서가 지켜지지 않으면 트리거가 조용히 재등록되지 않는 경우가 있음을 확인
- 이미 등록된 스케줄러로 판정되어 트리거 등록이 조용히 건너뛰어지는 상황을 배포 실패 조건으로 감지하도록 배포 스크립트를 강화
- Windows 최대절전 복귀 후 인스턴스 전체가 아니라 대상 워크플로우 하나만 다시 무장(rearm)시키는 절차 도입
- rearm 실행 전 Windows 호스트와 WSL의 시간 동기화 상태를 확인해, 어긋난 상태로 트리거가 잘못된 시각 기준으로 재등록되는 것을 방지

**검증 범위**
최대절전 → 자동 기상 → 시간 동기화 확인 → rearm → Schedule Trigger 발동 → Run_Log 기록 → Telegram 수신까지 전체 경로를 실제로 앞당긴 시각으로 종단간(E2E) 실행해 확인했습니다. 절전 복귀 과정에서 시스템 시계 지연이 관측되긴 했으나, 이번에 실제로 있었던 장애의 직접 원인이라고 단정하지는 않습니다 — 트리거 등록 스킵 문제 하나만으로 이미 설명되는 장애였기 때문입니다. Rate limit(429) 발생 시 재시도 3회·15초 간격이 끝까지 도는 전체 사이클은 구조적으로는 검증됐지만, 실제 429가 자연 발생한 상태에서 끝까지 실측된 적은 아직 없습니다.

자세한 원인 분석과 설계 근거는 [docs/design.md](./docs/design.md) 8.4~8.6절을 참고하세요.

## 시스템 아키텍처

```
Schedule Trigger (매일 1회)
  → Companies 조회 (active=TRUE)
  → 기업별 Loop
      NAVER Search API 검색 → 관련성 필터 → 신규/중복 판별
      → Raw_News 저장 → 중요도 필터 → Gemini 분석 → AI_Analysis 저장
      (오류 격리로 항상 회사당 결과 1개 보장)
  → 실행 통계 집계 → Run_Log 저장 → Telegram 요약 발송
```

전체 아키텍처와 각 단계의 설계 근거는 [docs/design.md](./docs/design.md) 3절·8절을 참고하세요.

## 기술 스택

- **n8n** — 워크플로우 자동화
- **Gemini API** — AI 기반 뉴스 요약 및 이벤트 분류 (무료 티어)
- **Google Sheets API** — 데이터 저장
- **Telegram Bot API** — 실행 완료 알림
- **Docker / WSL2** — 실행 환경

세부 모델 및 API 스펙은 [docs/design.md](./docs/design.md)에서 관리합니다.

## 데이터 저장 구조

Google Sheets 4개 탭에 역할을 분리해 저장합니다.

- Companies
- Raw_News
- AI_Analysis
- Run_Log

초기 Companies 데이터는 `seed/companies_seed.csv`로 채울 수 있으며, 컬럼 단위 상세 스키마는 [docs/design.md](./docs/design.md) 5절을 참고하세요.

## 재현 참고

완전한 설치형 오픈소스가 아니라 개인 운영 중인 자동화 파이프라인입니다. `n8n/workflows/news-collector.json`은 **참고용 export**이며, credential 재연결과 환경별 설정 없이는 바로 실행되지 않습니다.

**필요한 것**
- n8n 인스턴스
- Google Cloud 서비스 계정 (Google Sheets API)
- Gemini API 키
- NAVER Search API 키
- Telegram Bot

**설정 방법**
- workflow import 후 credential 4개(Google Sheets / Gemini / NAVER / Telegram)를 각자 환경에 맞게 재연결하고, Google Sheets `documentId`와 Telegram `chatId`를 재설정해야 합니다.
- Google Sheets 스키마는 [docs/design.md](./docs/design.md) 5절에 문서화되어 있습니다.
- `.env`는 사용하지 않습니다 — 설정은 n8n Credential과 Companies 시트에서 관리합니다.

**제한사항**
- 1인 운영 환경에서만 검증되었으며, 멀티테넌트 사용을 고려해 만들어지지 않았습니다.
- Gemini 무료 티어 요청 한도는 계정/시점에 따라 달라질 수 있습니다.

## 프로젝트 구조

```text
news-automation/
├── README.md
├── .gitignore
├── docs/
│   ├── design.md
│   ├── TASKS.md
│   └── n8n-workflow-map_v1.1.0.png
├── n8n/
│   └── workflows/
│       └── news-collector.json
├── prompts/
│   └── news-analysis-prompt.md
├── scripts/
│   ├── deploy-production-workflow.sh   # 프로덕션 배포 전용 wrapper (참고용 — $HOME 기준 기본 경로, 환경변수로 재정의 가능)
│   └── rearm-news-collector-trigger.sh # 절전 복귀 후 트리거 재무장 스크립트 (참고용)
└── seed/
    └── companies_seed.csv
```

## 현재 상태 및 향후 개선

핵심 파이프라인(뉴스 수집 → 필터링/신규 판별 → 원본·AI 분석 저장 → 오류 격리 → Run_Log 기록 → Telegram 알림)이 모두 구현되어 매일 자동 실행 중입니다. 로컬 환경(Windows 절전 → 자동 기상 → 컨테이너 준비 → 트리거 재무장 → 실행 → 알림 수신)까지 이어지는 전체 무인 실행 경로를 실제로 종단간(E2E) 검증했습니다 — 설계 근거는 [docs/design.md](./docs/design.md) 8.4·8.5절을 참고하세요.

향후 개선 항목(Telegram 중복 기사 노출 방지, ticker 저장 형식 수정, 다중 뉴스 소스 확장 등) 전체 목록은 [docs/TASKS.md](./docs/TASKS.md)를 참고하세요.

## 상세 문서

- [docs/design.md](./docs/design.md) — 전체 아키텍처, 스키마, 설계 결정
- [docs/TASKS.md](./docs/TASKS.md) — 진행 상황 체크리스트
- [prompts/news-analysis-prompt.md](./prompts/news-analysis-prompt.md) — 실제 프로덕션 Gemini 프롬프트
- [n8n/workflows/news-collector.json](./n8n/workflows/news-collector.json) — 프로덕션 워크플로우 export (참고용 — credential 재연결, documentId/chatId 재설정 필요)
