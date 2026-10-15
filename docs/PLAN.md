# PLAN — Wireless ADB Reconnect (무선 ADB 자동 재연결, 옛 이름 ADB Revive)

## 목표
무선 adb가 끊겼을 때 **원인을 진단하고, 여러 방법을 순서대로 시도해, 붙은 방법을 기억**하는 실행 프로그램.
(Mac: 메뉴 막대 Swift 앱 / Windows: `.bat` + 아이콘 바로가기)

## 끊김 → 재연결 루틴에서 확인된/예상되는 원인
| # | 원인 | 진단 방법 | 대응 방법 |
|---|---|---|---|
| 1 | adb 서버를 **로컬 네트워크 권한 없는 프로그램**이 띄움 (itda 데몬, 권한 없는 앱/터미널) | 5037 포트 소유 프로세스 계보(lsof+ps), `connect` → `No route to host` | 앱이 직접 서버를 소유(nodaemon 자식) |
| 2 | **앱 자체에 로컬 네트워크 권한 없음** | NWBrowser `PolicyDenied`, 휴대폰 TCP 접속 실패 | 권한 요청/설정 화면 열기 → Terminal(itda 끔) 폴백 |
| 3 | 무선 디버깅 **포트 변경** (재부팅·토글) | mDNS로 현재 IP:포트 조회 | `adb connect <새 IP:포트>` |
| 4 | adb 내장 mDNS가 기기를 못 찾음 | 서버 재시작 후에도 기기 없음 | 서버를 macOS mDNS 백엔드(`ADB_MDNS_OPENSCREEN=0`)로 재시작 |
| 5 | 기기가 **offline**으로 남음 | `adb devices` 상태 | `adb reconnect offline` |
| 6 | 휴대폰이 무선 디버깅을 **알리지 않음** (꺼짐/절전/다른 Wi‑Fi) | mDNS 탐색 결과 없음 | 사용자 안내 (자동 해결 불가) |
| 7 | **페어링 풀림** | `connect` → 인증 실패 / unauthorized | 사용자 안내 (`adb pair` 다시) |
| 8 | **adb 버전 불일치** (Android Studio 등 다른 adb) | `doesn't match this client` | 서버 종료 후 앱이 다시 띄움 |

## 시도 순서 (붙으면 즉시 종료, 붙은 방법은 다음에 우선 시도)
1. offline 기기 재연결 (끊지 않음)
2. 서버 유지 + IP:포트 직접 연결 (앱이 서버 소유 중일 때)
3. 앱이 서버 재시작 (nodaemon) → 자동 연결 대기 → IP:포트 연결
4. 앱이 서버 재시작 (macOS mDNS 백엔드) → 동일
5. Terminal(itda 끔)에서 서버 실행 → 동일 (앱 권한이 없을 때 폴백)

## 단계 (비중)
### 1차 (완료)
- [x] 아이콘, 1차 스크립트 앱, Windows bat
- [x] Mac Swift 메뉴 막대 앱: 진단 + 전략 + 학습, 앱 아이콘 알림 (2026-10-13 무선 연결 확인)

### 2차 — Windows 앱 + 설치 화면 + 페어링 (2026-10-15~)
결정: adb·Android Studio가 이미 있으면 설치 단계를 건너뜀(2026-10-15 사용자 요청). C# WinForms(.NET Framework 4.8, exe 하나로 x64·ARM64), adb만 설치를 기본(Android Studio는 선택), 페어링 QR.
개발: Mac에서 코드 작성 → `tools/windows_pc.sh`로 PC `Documents\wireless-adb-sync`에 보내 빌드·검사.
- [x] 1. PC 개발 환경 (보내기·빌드·화면 확인 스크립트) — 5%
- [x] 2. Windows 트레이 앱: 진단·전략·학습, Windows 원인(버전 충돌·공용 네트워크·방화벽), 알림 — 35%
- [x] 3. Windows 설치 화면: adb 설치 / Android Studio 설치 / 앱 설치·바로가기·자동 실행·제거 — 20%
- [x] 4. PC에서 실제 테스트 — 15% (2026-10-15 바탕화면에서 설치→QR 페어링→트레이 자동 연결 성공, Mac과 동시 연결)
- [~] 5. Mac 설치 화면: adb 설치 / Android Studio / 응용 프로그램 폴더 / 로그인 시 실행 — 15% (구현·화면 확인. 남음: 실제 옮기기·로그인 항목 테스트)
- [x] 6. 페어링 QR (Windows·Mac) — 5% (Windows 실제 페어링 성공, Mac QR 내용 검증)
- [ ] 7. 문서 정리, 커밋 — 5%

### 3차 — 이름 변경 + 디자인 개편 + 서명 (2026-10-15~)
결정: 영어 `Wireless ADB Reconnect`(저장소 `wireless-adb-reconnect`, 짧게 `ADB Reconnect`), 한글 `무선 ADB 자동 재연결`.
아이콘: 사용자 심볼(초록=연결됨, 빨강=끊김). 디자인 시안: https://claude.ai/artifact/AcexxtvRGVUCuaJBxK7k8q
- [x] 1. 이름·경로·아이콘 교체 (Mac·Windows, 앱 아이콘 + 상태 아이콘 초록/빨강) — 15%
- [x] 2. Mac: SwiftUI 설치 마법사·페어링 화면(시안), 메뉴 상태 헤더, Developer ID 서명 — 35%
- [x] 3. Windows: WPF 설치 마법사·페어링 화면(시안), 트레이 초록/빨강 — 35%
- [x] 4. 실제 테스트 (Mac·PC, 이전 ADB Revive 제거 후 새로 설치) — 10% (2026-10-15 Mac 새 설치·옮기기·로그인 항목·연결, PC 설치·옛 앱 정리·연결 OK. Mac 기본 알림은 미해결 → TROUBLESHOOTING)
- [ ] 5. 문서(README 영어·한글), 커밋 — 5%

## 리스크
- ad-hoc 서명 앱은 다시 빌드하면 로컬 네트워크 권한을 다시 물을 수 있음
- 앱을 종료하면 앱이 띄운 adb 서버도 종료됨 (메뉴 막대에 상주)
- Windows PC에서 앱을 띄우면 휴대폰과 실제 연결됨 → 실행 전 사용자에게 알림\n- 서명 없는 exe → 첫 실행 SmartScreen 경고
