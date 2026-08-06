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
- [x] 오류 격리 구현 — 회사당 정확히 1개의 결과가 남도록 보장하는 "Build Company Summary" 패턴 적용, 저장 단계 필드 유실 문제는 Fork+Merge(article_id 기준)로 해결 (설계는 docs/design.md 8.2절, 구현 과정은 SESSION_SUMMARY.md 참고)
- [x] Save Raw News / Save AI_Analysis 저장 실패 시 에러 출력 미연결로 회사 요약이 누락되던 문제 수정 (Tag: Company Failed / Tag: Save AI_Analysis Failed 노드 추가)
- [x] Run_Log 구현 완료 — 12개 컬럼, 회사 단위 집계 및 무결성 우선 판정 (설계는 docs/design.md 5.4절), 프로덕션 실행으로 정상 기록 확인
- [x] NAVER API 키 평문 노출 발견 및 수정 — credential 참조로 전환, 평문 키를 가진 테스트/구버전 노드 전체 삭제 (경위는 SESSION_SUMMARY.md 참고)
- [ ] NAVER API 키 재발급 (사용자가 NAVER Developer Center에서 직접 처리 예정)
- [x] 프로덕션 워크플로우 잔여 정리 완료 — 고아 노드 및 죽은 브랜치 제거
- [x] Telegram 완료 알림 V1 구현 완료 — 산업별 그룹화, Priority 상위 3건 발췌, 데이터 가공과 렌더링 노드 분리. DEV 검증 후 프로덕션 반영 완료 (상세는 SESSION_SUMMARY.md 참고)
- [ ] 종목코드(ticker) Raw_News/AI_Analysis 저장 시 숫자로 변환되는 문제 근본 수정 — Google Sheets 컬럼 서식을 일반 텍스트로 변경 필요 (핵심 저장 노드 관련 작업이라 별도 진행 권장)

## Phase 5 — 테스트 & 안정화

- [x] End-to-end 실행 테스트 — Phase 4 작업 전체에 걸쳐 DEV(테스트 스프레드시트)와 프로덕션(10개 기업 전체)에서 반복적으로 실제 실행 검증 완료 (기업 1~2개 축소보다 넓은 범위로 검증됨)
- [x] 에러 핸들링 점검 — NAVER API 실패/Raw_News 저장 실패/Gemini 분석 실패/AI_Analysis 저장 실패 각 단계별로 실제 오류 격리 동작 검증 완료
- [x] 무인 실행 신뢰성 검증 — 애초 계획했던 "1주일 수동 관찰" 대신, 2026-08-03~08-06 사이 실제로 발생한 트리거 미등록 장애 3건을 각각 근본 원인까지 규명·수정하고, 2026-08-06 절전→기상→트리거 재무장→실행→알림 수신 전체 경로를 의도적으로 앞당긴 시각으로 E2E 실행해 검증 완료 (상세는 SESSION_SUMMARY.md 2026-08-06 참고)

## Phase 5b — GitHub v2 공개 준비 (v1.1.0 → v2)

- [ ] 🤖 `n8n/workflows/news-collector.json` 재-export + 재-sanitize — 현재 커밋된 버전은 2026-08-05 Gemini 기사 단위 재시도 구조 반영 이전 상태(48개 노드)라 실제 라이브 워크플로우(50개 노드)와 다름
- [ ] 🙋 `scripts/`(배포 wrapper, rearm 스크립트) 공개 여부 결정 — 비밀값은 없으나 컨테이너명 등 환경 종속 값 포함, 공개 시 sanitization 필요 여부 검토
- [ ] 🙋 프로젝트 `CLAUDE.md` 공개 여부 결정 — 로컬 파일 경로 등이 포함돼 있어 SESSION_SUMMARY.md와 같은 비공개 취급 권장
- [ ] 🙋 Telegram 실행 결과 스크린샷 준비 후 README "실행 결과" 섹션에 추가 (계속 보류 중)
- [ ] 🙋 GitHub Repository Description/Topics 갱신 여부 검토(현재: 배포 자동화·재시도 신뢰성 내용 미반영)
- [ ] 🙋 버전 태그(v2.0.0 등) 생성 및 커밋

## Phase 6 — MVP 이후 백로그

- [ ] Telegram Top3 선정 시 동일 기사(URL) 중복 노출 방지 — 여러 기업이 언급된 동일 기사가 각 기업별로 별도 집계되어(관련성 판단은 회사별 유지가 맞음) Top3 안에서 같은 기사가 중복 노출되는 경우가 있음(예: 삼성전자·SK하이닉스가 함께 언급된 기사). `Prepare Telegram Data`에서 Top3 선정 직전에 동일 `normalized_url`(또는 `url`) 기준 중복 제거 → 남은 기사 기준으로 Priority 순 재선정하는 방식 검토. 급한 오류는 아니고 운영 중 발견한 UX 개선 사항
- [ ] 공통 피드 수집 방식 전환 검토 (활성 기업 20~30개 이상 또는 실행 성능 저하 시, docs/design.md 7.1절 기준)
- [ ] 제목/출처/발행시각 결합 보조 중복 판별 추가 (docs/design.md 7.2절 기준)
- [ ] 다중 뉴스 소스 추가
- [ ] DART 공시 연동
- [ ] 주가 데이터 연동, AI 판단-실제 시장 반응 비교 분석
- [ ] Looker Studio 또는 Tableau 대시보드
- [ ] Raw_News cleanup 정책 설계 및 구현 (AI_Analysis 있는 행만 정리 대상, 미분석 행은 보존, docs/design.md 5.2절 참고)
