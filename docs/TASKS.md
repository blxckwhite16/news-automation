# TASKS

범례: 🤖 Claude Code가 직접 실행 가능 (로컬 파일/명령) · 🙋 사용자 작업 필요 (Google Sheets, n8n, Google AI Studio 등 외부 UI)

**새 세션 시작 시**: 아래 문서를 순서대로 확인한 뒤 이어서 진행합니다 — [README.md](../README.md) → [docs/design.md](./design.md) → [docs/SESSION_SUMMARY.md](./SESSION_SUMMARY.md)

## Phase 0 — 프로젝트 셋업

- [x] 🤖 Git 저장소 초기화 및 기본 폴더 구조 생성 (`n8n/workflows/`, `prompts/`, `.gitignore`)
- [x] 🙋 Google Sheets 문서 생성, Companies / Raw_News / AI_Analysis / Run_Log 4개 탭과 헤더 컬럼 설정 (docs/design.md 5절 참고)
- [x] 🙋 Companies 시트에 초기 10개 기업 데이터 입력 (docs/design.md 5.1절 표 참고)
- [x] 🙋 Google Cloud 서비스 계정 생성 및 Sheets 조회/쓰기 권한 부여
- [x] 🙋 n8n에 Google Sheets Credential 등록
- [x] 🙋 Gemini API 키 발급 (Google AI Studio)
- [x] 🙋 n8n에 Gemini API Credential 등록 및 운영 모델 확정 (models/gemini-3.5-flash-lite)

## Phase 1 — 뉴스 수집

- [x] n8n Schedule Trigger 노드 구성 (매일 08:30 Asia/Seoul, Manual Trigger는 테스트용으로 별도 유지, 아직 미연결)
- [x] Companies 시트 조회 노드 구성 (active=true boolean 필터, Manual/Schedule Trigger 둘 다 연결, 10개 기업 정상 반환 확인)
- [x] Loop Over Companies 노드 구성 (Get Company List → Loop Over Items, Batch Size 1, 출력 loop/done 확인, loop-back은 후속 노드 완성 후 연결 예정)
- [x] 검색식 구성 + Google News RSS 검색 노드 구성 (Build Search Query → HTTP Request(Text) → XML 파싱 → Split Out → Clean Article Data, 여러 기업에 걸쳐 company_name/ticker/industry 매칭 정확도 검증 완료)

## Phase 2 — 필터링 & 신규/중복 판별

- [x] 관련성 필터 Code 노드 작성 (Filter Relevant Articles, aliases 매칭 검증 완료)
- [x] Raw_News 기존 article_id 조회 노드 구성 (Search Existing News, Trigger에서 병렬 실행되도록 연결, Always Output Data 활성화)
- [x] 신규/중복 판별 Code 노드 작성 (Check New Articles, URL 정규화 + 간단 hash로 article_id 생성, 중복 판별 키를 article_id 단독 → article_id+ticker 조합으로 수정해 기업 간 교차 노출 기사도 독립 분석되도록 함, 99개 신규 기사 반환 확인)

## Phase 3 — 원본 저장 & AI 분석

- [x] Raw_News append 노드 구성 (Save Raw News, 첫 실행 99건 저장, 재실행 시 기존 article_id 제외되는 round-trip 검증 완료)
- [x] 중요도 사전 점수화 + IF 노드 구성 (Calculate News Importance → If Score, Raw_News 저장 뒤에 위치, threshold=5, 99개 중 True 10 / False 89 확인)
- [x] prompts/news-analysis-prompt.md 작성 (enum 스키마 반영, docs/design.md 9절)
- [x] Gemini API 호출 노드 구성 (models/gemini-3.5-flash-lite, Filter by Importance True branch만, Analyze News with Gemini 노드)
- [x] JSON 파싱/검증 Code 노드 작성 (Parse Gemini Response, category/sentiment enum 검증, company_name/industry/importance는 입력값으로 재결합)

## Phase 4 — 분석 결과 저장 & 실행 로그

- [x] AI_Analysis append 노드 구성 (Save AI_Analysis, Loop Over Items로 loop-back 연결까지 완료)
- [x] Loop Over Items `done` 출력 누적 방식 검증 (A안 확정 — Aggregate로 회사당 결과 1개로 합친 뒤 loop-back, done 출력에 정상 누적됨을 n8n CLI 테스트 워크플로우 실행으로 확인)
- [x] 오류 격리 구현 — "Build Company Summary" 패턴으로 최종 확정: 관련 기사 0건/신규 기사 0건/고중요도 기사 0건/API 실패 등 모든 케이스에서 회사당 반드시 1개의 제어 아이템이 생성되도록 IF 트리 + 최종 통합 노드 구성. 저장 노드(Save Raw News/Save AI_Analysis)의 Google Sheets Append가 매핑 안 된 필드를 스트리핑하는 문제는 Fork+Merge(article_id 기준) 패턴으로 해결 — 노드 참조(pairedItem) 방식은 1→N 분기+부분 필터가 겹치는 구간에서 깨지는 것을 실제 프로덕션 장애(LG에너지솔루션 건)로 확인 후 폐기. 상세는 SESSION_SUMMARY.md 참고
- [x] Save Raw News / Save AI_Analysis 저장 실패 시 에러 출력 미연결로 회사 요약이 누락되던 문제 수정 (Tag: Company Failed / Tag: Save AI_Analysis Failed 노드 추가)
- [x] Run_Log 구현 완료 — 12개 컬럼 (docs/design.md 5.4절), Phase A(Fetch Naver News 실패 경로 수정) → Phase B(run_started_at, `$execution.customData` 방식) → Phase C(`Aggregate Run Stats` + `Save Run_Log`) 순서로 프로덕션 반영, DEV 통합 테스트 및 **프로덕션 실제 실행(사용자가 n8n UI에서 직접 실행)으로 Run_Log 1행 정상 기록 최종 확인** (상세는 SESSION_SUMMARY.md "Run_Log 설계 및 구현 계획" 참고)
- [x] NAVER API 키 평문 재노출 발견 및 수정 — `Fetch Naver News`를 credential 참조로 복원, 평문 키를 가진 테스트/구버전 체인(`HTTP Request (Test for Naver)` + Manual Trigger 체인, `Fetch Naver News1` + "Schedule Trigger for DEV" 체인) 25개 노드 전체 삭제. 상세는 SESSION_SUMMARY.md "보안 재발 및 정리" 참고
- [ ] NAVER API 키 재발급 (사용자가 NAVER Developer Center에서 직접 처리 예정)
- [x] 프로덕션 워크플로우 잔여 정리 완료: 고아 노드 5개 삭제, 죽은 브랜치 "Filter by Importance" 연결 해제 및 삭제 (상세는 SESSION_SUMMARY.md "프로덕션 워크플로우 정리" 참고)
- [x] Telegram 완료 알림 V1 구현 완료 — 데이터 가공(`Prepare Telegram Data`)과 렌더링(`Build Message`) 분리, 산업별 그룹핑, Priority 상위 3건, New Articles/AI Selected 지표 분리, 0건 상태 2가지 분기, ticker 0 패딩, 축소된 템플릿, 4096자 초과 자동 분할. DEV에서 4가지 상태 전부 실제 전송 검증 완료, 프로덕션 반영 완료 (상세는 SESSION_SUMMARY.md "Telegram 완료 알림" 참고)
- [ ] 종목코드(ticker) Raw_News/AI_Analysis 저장 시 숫자로 변환되는 문제 근본 수정 — Google Sheets 컬럼 서식을 일반 텍스트로 변경 필요 (핵심 저장 노드 관련 작업이라 별도 진행 권장)

## Phase 5 — 테스트 & 안정화

- [x] End-to-end 실행 테스트 — Phase 4 작업 전체에 걸쳐 DEV(테스트 스프레드시트)와 프로덕션(10개 기업 전체)에서 반복적으로 실제 실행 검증 완료 (기업 1~2개 축소보다 넓은 범위로 검증됨)
- [x] 에러 핸들링 점검 — NAVER API 실패/Raw_News 저장 실패/Gemini 분석 실패/AI_Analysis 저장 실패 각 단계별로 실제 오류 격리 동작 검증 완료 (docs/SESSION_SUMMARY.md "오류 격리 아키텍처" 참고)
- [ ] 1주일 자동 실행 모니터링 — 2026-08-02 워크플로우 활성화(active=true), 모니터링 시작. 종료 예정일 2026-08-09 전후

## Phase 6 — MVP 이후 백로그

- [ ] Telegram Top3 선정 시 동일 기사(URL) 중복 노출 방지 — 여러 기업이 언급된 동일 기사가 각 기업별로 별도 집계되어(관련성 판단은 회사별 유지가 맞음) Top3 안에서 같은 기사가 중복 노출되는 경우가 있음(예: 삼성전자·SK하이닉스가 함께 언급된 기사). `Prepare Telegram Data`에서 Top3 선정 직전에 동일 `normalized_url`(또는 `url`) 기준 중복 제거 → 남은 기사 기준으로 Priority 순 재선정하는 방식 검토. 급한 오류는 아니고 운영 중 발견한 UX 개선 사항
- [ ] 공통 피드 수집 방식 전환 검토 (활성 기업 20~30개 이상 또는 실행 성능 저하 시, docs/design.md 7.1절 기준)
- [ ] 제목/출처/발행시각 결합 보조 중복 판별 추가 (docs/design.md 7.2절 기준)
- [ ] 다중 뉴스 소스 추가
- [ ] DART 공시 연동
- [ ] 주가 데이터 연동, AI 판단-실제 시장 반응 비교 분석
- [ ] Looker Studio 또는 Tableau 대시보드
- [ ] Raw_News cleanup 정책 설계 및 구현 (AI_Analysis 있는 행만 정리 대상, 미분석 행은 보존, docs/design.md 5.2절 참고)
