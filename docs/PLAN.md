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
- [x] 5. 문서(README 영어·한글), 커밋 — 5%

### 4차 — 화면 미러링(scrcpy) 흡수 (2026-10-15~)
배경: `Projects/itda-android-phone/무선디버깅.app`(AppleScript + run.bash, 4월 작성)은 IP:포트를 손으로 넣고 `adb kill-server` → `adb connect` → scrcpy를 띄우는 스크립트. 이 앱이 띄운 서버를 죽여 무선 연결이 끊기는 충돌이 있었다.
결정 (2026-10-15 사용자): **A안** — 미러링을 이 앱(Mac)의 기능으로 흡수. 스크립트 앱은 `_archive/`로. 폴더 이름 `sub-project/adb-wireless` → `Projects/itda-wireless-adb-reconnect`.
원칙: scrcpy는 이 앱이 소유한 adb 서버를 그대로 쓴다 (`ADB=<앱이 찾은 adb>` 환경변수로 실행 → 버전 불일치로 서버가 죽는 일 없음). 기기는 앱이 알고 있는 무선 serial로 `-s` 지정 (USB 동시 연결 시에도 무선으로).
이번 범위 밖: Windows 미러링 (다음 후보), scrcpy 번들 배포(크기·라이선스 — Homebrew 설치 안내로 대체).

- [x] 1. 폴더 이름 변경 (`itda-wireless-adb-reconnect`) — 5%
- [x] 2. `mac/Mirror.swift`: scrcpy 찾기(`/opt/homebrew/bin`, `/usr/local/bin`, 설정 경로) · 실행(자식 Process, `ADB` env, `-s`, 옵션) · 상태 추적(실행 중/종료 코드) · 앱 종료 시 함께 종료 — 30%
- [x] 3. 메뉴: "화면 미러링 시작/중지" (⌘M). 끊겨 있으면 먼저 다시 붙인 뒤 실행. 옵션 서브메뉴(화질 6M/12M, 소리 켬/끔, 항상 위, 폰 화면 끄기, 녹화 폴더) — UserDefaults 저장 — 20%
- [x] 4. 설치 마법사: "화면 미러링" 단계 추가 (4/4, 선택) (있으면 건너뜀, Homebrew 있으면 `brew install scrcpy` 실행, 없으면 안내·다시 확인) — 15%
- [x] 5. 실제 테스트 — 15% (2026-10-15 /Applications에 1.2.0 설치 후 메뉴로: USB+무선 동시 연결에서 무선 serial로 미러링 OK, 중지 후 adb 서버 pid·무선 유지 OK, `adb disconnect` 뒤 ⌘M → "서버 유지 + IP:포트 직접 연결"로 붙고 미러링 OK, 미러링 중 끊기면 코드 2로 종료 감지 OK)
- [x] 6. 옛 스크립트 앱 `_archive/무선디버깅.app`으로 이동, 문서(README 영어·한글, TROUBLESHOOTING), 버전 1.2.0, 커밋 — 15%
- 다음 후보: 미러링 중 끊기면 자동 재연결·재시작, `--mirror` 실행 인자(Raycast 등 단축키용), Windows 미러링, 공개 릴리스 v1.2.0 (공증 zip)

수정 파일: `mac/Mirror.swift`(신규), `mac/main.swift`(메뉴·종료), `mac/Setup.swift`(마법사 단계), `mac/build_app.sh`(파일 추가·버전), README 2종, docs 2종.

리스크
- scrcpy가 다른 adb(Homebrew)를 쓰면 서버를 죽임 → `ADB` env로 앱의 adb를 강제. 그래도 죽으면 앱이 재시작 루틴으로 복구.
- Homebrew가 없는 사용자는 scrcpy 자동 설치 불가 → 안내만.
- 미러링 중 무선이 끊기면 scrcpy가 종료됨 → 종료 코드로 감지해 알림(자동 재시작은 옵션으로, 1차는 알림만).
- 앱을 종료하면 scrcpy도 종료됨 (adb 서버와 같음).

### 5차 — Windows 미러링 + 설치 2단계에서 scrcpy 함께 설치 (2026-10-15~)
결정 (2026-10-15 사용자): Windows도 미러링. scrcpy 설치는 별도 4단계가 아니라 **2단계(앱 설치)에서 "화면 미러링(scrcpy)도 설치" 스위치**로 묻는다 (Mac·Windows 공통). Mac의 4단계 '화면 미러링'은 없앤다.
Windows scrcpy 설치 방법: GitHub 릴리스 zip(`scrcpy-win64-v5.0.1.zip` 약 11MB, ARM64 PC는 `winarm64`)을 받아 `%LOCALAPPDATA%\Wireless ADB Reconnect\scrcpy\`에 푼다 — platform-tools와 같은 방식(관리자 권한·winget 불필요, 앱이 위치를 앎). 버전은 상수로 고정, 올릴 때 갱신.
미러링 원칙은 Mac과 같다: `ADB=<앱 adb>` 환경변수 + `-s <무선 serial>`. 콘솔 창 없이 실행(CreateNoWindow), SDL 창만 보임.

- [x] 1. Windows `Mirror.cs`: scrcpy 찾기(앱 폴더 → PATH → Programs\scrcpy → winget 폴더) · zip 설치(진행률) · 실행(ADB env, -s, 옵션) · 중지 · 종료 감지 — 25%
- [x] 2. Windows 트레이: "화면 미러링 시작/중지", "미러링 옵션"(화질·소리·항상 위·화면 끄기·녹화 Videos 폴더), 끊겨 있으면 먼저 재연결, 끊김 알림. `--mirror` 실행 인자(바로가기·테스트용: 실행 중이면 신호만 보냄) — 15%
- [x] 3. 마법사 2단계 스위치 "화면 미러링(scrcpy)도 설치": Windows(XAML + 설치 때 zip 받기) 10% · Mac(InstallStep 스위치, Homebrew 없으면 비활성 안내, 설치 후 옮기기; 4단계 제거) 15% — 25%
- [x] 4. 빌드·실제 테스트 — 25% (2026-10-15 PC: `--install-scrcpy`로 zip 설치 OK, 1.2.0 설치 후 `--mirror` → 미러링(D3D11) OK, 다시 `--mirror` → 중지(코드 0 사용자 중지), 서버 pid·기기 유지 OK, 마법사 2단계 스냅샷 OK. Mac: 재빌드·설치, 메뉴 시작/중지 OK, 스냅샷 OK. Mac·PC 동시 미러링 2분 이상 OK. 미검증: Mac에서 Homebrew로 scrcpy 설치 경로(이미 설치돼 있어 스위치 비활성), Windows EV 서명은 사용자 PIN 필요)
- [x] 5. 문서(README 2종, TROUBLESHOOTING), 버전 1.2.0(Windows도), 커밋 — 10%
- 다음 후보: 미러링 중 끊기면 자동 재연결·재시작, Mac `--mirror`(URL 스킴 등), 공개 릴리스 v1.2.0 (Mac 공증 zip + Windows 서명 exe)

수정 파일: `windows/.../Mirror.cs`(신규), `TrayApp.cs`, `Program.cs`, `SetupWindow.xaml(.cs)`, `Installer.cs`(zip 받기 공통화), `Common.cs`(경로), `.csproj`(버전); `mac/Setup.swift`, `mac/Mirror.swift`(설치 콜백), `mac/main.swift`(설정 열기 단계).

리스크
- Windows scrcpy zip에 adb.exe가 함께 들어 있음 → PATH에 넣지 않고 `ADB` env로 앱 adb를 강제하므로 충돌 없음.
- ARM64 Windows: `winarm64` zip 사용 (x64 에뮬레이션 불필요). 아키텍처 판별은 `RuntimeInformation.OSArchitecture`.
- 테스트 PC에서 미러링을 띄우면 실제 휴대폰 화면이 PC에 뜸 (Mac과 동시 미러링은 scrcpy 서버가 기기당 여러 개 가능하므로 문제없을 것으로 예상, 실제 확인).
- Mac 2단계에서 brew 설치는 1~5분 → 진행 메시지 표시, 끝나면 옮기기 진행.

### 6차 — 새 아이콘(안드로이드 + 전파) + v1.2.0 공개 (2026-10-22)
결정 (2026-10-22 사용자): 앱 아이콘 = 녹색 전파 심볼. 상태는 **회색 = 연결됨, 빨강 = 끊김** (초록은 실제 메뉴 막대·작업 표시줄에서 잘 안 보임).
검토 반영: 심볼 몸체가 검정이라 어두운 메뉴 막대·작업 표시줄에서 사라짐 → 몸체는 배경 밝기에 맞춰 검정/흰색, 전파만 상태색(회색은 어두운 배경에서 더 밝은 회색 `#A0A0A0`). 다시 붙이는 중(Mac)은 기존대로 주황.
원본: `assets/symbol-{green,gray,red}.png` → `assets/make_icons.sh`로 모든 아이콘 생성 (앱 아이콘 = 흰 둥근 사각형 + 녹색 심볼, Mac 메뉴 막대 마스크 2장, Windows 트레이 ico 4종).
- [x] 1. 아이콘 생성 스크립트·리소스 — 20%
- [x] 2. Mac: 메뉴 막대 아이콘(마스크 + 글자색/상태색), 메뉴 헤더 점 회색, 안내 문구, 스냅샷에 메뉴 막대 아이콘 — 15%
- [x] 3. Windows: 트레이 ico 4종(작업 표시줄 밝기 `SystemUsesLightTheme`, 테마 바꾸면 즉시 반영), 안내 문구 — 15%
- [x] 4. 빌드·확인 (Mac 빌드·스냅샷, PC 빌드·스냅샷·트레이 ico 렌더), README 스크린샷 교체 — 20%
- [x] 5. 문서, 커밋, 옛 아이콘 `_archive/old-icons-2026-10-22` — 10%
- [x] 6. 배포: Mac 공증 zip, Windows EV 서명 exe, 개인정보 검사, `public` 푸시, 릴리스 v1.2.0 — 20% (2026-10-22 완료. Mac 1.2.0 `/Applications` 교체 후 실제 메뉴 막대에서 회색 아이콘·재연결 확인. 미확인: Windows 실제 트레이 표시 — ico 렌더로만 확인)

### 7차 — 메뉴 개편 + 앱 안 업데이트 (2026-10-23~)
배경 (2026-10-23 사용자): v1.2.0 Mac 아이콘 몸체가 메뉴 막대에서 회색(`labelColor`가 `#585858`로 풀림) → 검정/흰색 고정. 확인용 새 빌드가 '터미널에서 서버 실행'을 이긴 방법으로 기억해 다시 붙일 때마다 터미널 창이 뜸 → 터미널 폴백은 앞당기지 않음.
결정 (2026-10-23 사용자): 메뉴 순서 = ✓로그인할 때 자동 실행 · 휴대폰 페어링 · 로컬 네트워크 권한 열기(권한 문제일 때만, Mac) │ 기기 다시 연결하기(연결됨이면 상태 표시) · 화면 미러링 시작하기 · 미러링 옵션 │ 설정 · 진단 보기 · 업데이트(현재 버전) · 종료. 맨 위 상태 표시·'마지막 성공 방법' 줄은 없앰. Mac·Windows 모두.
업데이트: 일주일에 한 번 GitHub 최신 릴리스 확인 → 최신이면 '최신 버전 (x.y.z)' 고정, 새 버전이면 누를 때 받기(진행 동그라미) → SHA256SUMS 확인 → 서명 확인(Mac: 같은 Team ID + 공증 / Windows: Authenticode 유효 + 같은 게시자) → 앱 교체 → 다시 실행. 실패하면 기존 앱 유지.
- [x] 0. Mac 아이콘 몸체 검정/흰색, 터미널 폴백 앞당기지 않음, 페어링 메뉴 위로 — 커밋 `90b38cb` `f936415` `3843f88`
- [x] 1. Mac 메뉴 재구성 (상태에 따라 바뀌는 다시 연결 항목, 권한 항목 숨김) — 25%
- [x] 2. Mac 업데이트 확인·설치 (`mac/Update.swift`) — 35% (실제 확인: `WAR_FAKE_VERSION=1.0.0` 사본 → 메뉴 '업데이트' → v1.2.0 공증 앱으로 교체·다시 실행)
- [x] 3. Windows 메뉴 재구성 + 업데이트 (`Updater.cs`, `--after-update <pid>`) — 30% (PC `--update-test`: 서명 없는 개발 exe → v1.2.0 서명 exe로 교체, SHA256 일치)
- [x] 4. 확인(Mac 실제 메뉴 캡처·업데이트 실제 교체, PC 빌드·업데이트 무화면 테스트), 문서, 커밋 — 10% (미확인: Windows 실제 트레이 메뉴 모양, 메뉴에서 누르는 Windows 업데이트 흐름)
- [x] 5. 배포 1.3.0 (2026-10-23 사용자 요청): Mac 공증 zip·`/Applications` 교체, Windows EV 서명 exe, 개인정보 검사, `public` 푸시, 릴리스 v1.3.0

### 8차 — 일본어·중국어 (2026-10-24~)
결정 (2026-10-24 사용자): 일본어·중국어까지만 지원, 그 밖의 언어는 영어. 중국어는 간체·번체 둘 다.
방식: 코드의 `L("한국어", "English")`는 그대로 두고, 일본어·중국어는 영어 문구를 키로 `assets/i18n/<ja|zh-Hans|zh-Hant>.strings`에서 찾음(없으면 영어). 값이 들어가는 문구는 `L("… {0}", "… {0}", 값)`. 굵은 글씨가 섞인 문장은 `**굵게**` 한 문장으로(Mac `boldText`, Windows `local:Md.Text`). Mac은 `<lang>.lproj/App.strings`(macOS가 언어 선택), Windows는 exe 리소스. 점검: `python3 tools/i18n.py check`. 휴대폰 메뉴 이름은 AOSP Settings 번역 그대로.
- [x] 1. 구조: Mac `uiLang`·`L(…, args)`, Windows `Lang.Code`·글꼴(Yu Gothic UI / YaHei UI / JhengHei UI), 권한 메뉴 판단을 문구 대신 플래그로 — 30%
- [x] 2. 번역 258개 × 3 + Mac 권한 안내문(InfoPlist) — 40%
- [x] 3. 확인: Mac·Windows 설치 마법사 스냅샷(일·간·번), Mac 실제 메뉴(일본어), PC 빌드 경고 0 — 20% (Windows 스냅샷은 페어링을 시작하지 않게 바꿈)
- [x] 4. 배포 1.3.1 (2026-10-28 사용자 요청): Mac 공증 zip·`/Applications` 교체, Windows EV 서명 exe, 개인정보 검사, `public` 푸시, 릴리스 v1.3.1 — 10%
- [ ] (선택) 원어민 검토
- [x] Mac 메뉴 막대 아이콘 16pt + 좌우 4pt 여백 (2026-10-28 사용자 요청: 다른 앱 아이콘처럼 앞뒤 간격 약 22) — 실제 메뉴 막대에서 18×18·간격 17/19 → 16×16·간격 21/23

### 9차 — 카드형 메뉴(팝오버) (2026-10-28 계획)
요청 (2026-10-28 사용자): 메뉴 막대 아이콘을 누르면 Llama 앱처럼 카드형 패널 — 머리(이름·상태 점·주소 복사·오른쪽 바로가기), 구역 제목 + 아이콘 행(제목·배지·보조 줄·오른쪽 화살표), 아래쪽 작은 버튼(설정·종료).
배치 안:
- 머리: 앱 이름 + 상태 점(회색 연결·빨강 끊김·주황 다시 붙이는 중) / `IP:포트` + 복사 / 오른쪽 링크 = 주 동작(연결됨 → 미러링, 끊김 → 다시 연결)
- 경고 행(필요할 때만): 로컬 네트워크 권한, 업데이트 있음
- 「연결된 기기」: 기기 행(모델 · Android 버전 배지 · `IP:포트 · 연결된 지 n분`), 누르면 미러링, 화살표 → 미러링 옵션
- 「미러링 옵션」: 화질(세그먼트) · 소리 · 항상 위 · 휴대폰 화면 끄기 · 녹화 토글 — 펼침 또는 하위 화면
- 「기기 추가」: 휴대폰 페어링(QR) 행
- 바닥: `v1.3.1 · adb 36.x` / [진단] [설정] [종료]. 로그인할 때 자동 실행은 설정으로
결정 (2026-10-28 사용자): **Mac만** 진행. Windows 트레이 메뉴는 그대로.
디자인 규칙 (Llama 메뉴 분석, 2026-10-29):
- 패널: 폭 약 320pt, 둥근 모서리 약 12pt, 반투명 배경(`.popover` 재질)·그림자, 화살표 없이 아이콘 바로 아래. 구역 사이는 안쪽 여백만큼 들인 가는 선
- 머리: 이름(13pt 굵게) + 상태 점 / 둘째 줄 회색 주소 + 복사 아이콘 / 오른쪽 끝 파란 글자 링크 하나(버튼 테두리 없음)
- 구역 제목: 11pt 회색, 대문자·굵게 없음
- 행: 왼쪽 28pt 원형 아이콘(옅은 회색 바탕) · 제목 13pt + 작은 테두리 배지 · 아래 11pt 회색 보조 줄 · 오른쪽 끝 기호. 마우스 올리면 행 배경 강조
- 오른쪽 끝 기호로 동작 종류를 알림: `›` 안에서 더 보기, `↓` 받기, `↗` 다른 창·시스템 설정·웹 열기
- 바닥: 왼쪽 회색 작은 글자(버전), 오른쪽 작은 테두리 버튼 2개(설정·종료). 체크 표시·토글은 패널에 두지 않음 → 설정으로
우리 앱 대응: 머리 = 앱 이름 + 점(연결 초록·끊김 빨강·다시 붙이는 중 주황; 패널은 흰 바탕이라 초록 사용) / `IP:포트` 복사 / 링크 "화면 미러링"(끊기면 "다시 연결") · 「연결된 기기」 = 기기 이름(`settings get global device_name`) + 배지 `Android 15` + "무선 · 12분째 연결" `›`(미러링 옵션) · 「도구」 = 휴대폰 페어링 `↗`, 진단 보기 `↗` · 필요할 때만 = 로컬 네트워크 권한 `↗`, 업데이트 `↓ 1.x 받기` · 바닥 = `v1.3.1 · adb 36.0.0` [설정] [종료]
구현: 지금 NSStatusItem 유지 + 테두리 없는 NSPanel(SwiftUI, NSVisualEffectView) — 왼쪽 클릭 열기, 바깥 클릭·Esc 닫기. 오른쪽 클릭은 지금 NSMenu. (MenuBarExtra는 오른쪽 클릭 메뉴를 못 둬서, NSPopover는 화살표가 생겨서 안 씀)
- [x] 1. 시안: `--snapshot`의 panel-*.png (밝게·어둡게 × 연결됨·옵션 펼침·끊김+권한·다시 붙이는 중+업데이트, 5개 언어) — 20% (2026-10-29 사용자: 시안 확인 없이 끝까지 진행·자체 테스트 후 커밋·푸시)
- [x] 2. Mac: 왼쪽 클릭 = NSPopover(SwiftUI, 바깥 누르면 닫힘), 상태 모델 하나로 묶기(연결·기기·미러링·업데이트). 오른쪽 클릭 = 지금 NSMenu 유지(키보드·손에 익은 사용자용) — 35%
- [x] 3. 기기 정보: 모델·Android 버전(getprop)·IP:포트·연결 시각, 복사 버튼 — 15%
- [x] 4. 다국어(새 문구 26개 × 일·간·번), VoiceOver·Esc·Tab, 스냅샷으로 5개 언어 확인 — 15%
- [x] 5. 실제 메뉴 막대 확인 — 15% (끊김·다시 붙이는 중 상태에서 열기/닫기(아이콘 토글·바깥 클릭·Esc), 오른쪽 클릭 예전 메뉴, 다시 연결 링크, 설정 버튼. **미확인: 연결된 상태(휴대폰 이름·Android 버전·주소 복사·미러링 옵션)** — 확인 때 휴대폰이 꺼져 있었음. 배포(버전 올림·릴리스)는 사용자 요청 때

### 공개 (2026-10-15)
- 저장소: https://github.com/da-itda/wireless-adb-reconnect (공개, MIT) · 릴리스 v1.0.0 (Mac Universal 공증 zip, Windows exe, SHA256SUMS)
- **공개 히스토리는 로컬 `main`과 별개**: 로컬 `public` 브랜치 = `origin/main`. 로컬 `main`(개인 정보가 남은 개발 기록)은 푸시하지 않는다.
- 다음 공개 방법: `git commit-tree "HEAD^{tree}" -p public -m "<메시지>"` → `git branch -f public <커밋>` → `git push origin public:main` (푸시는 사용자 요청 때만)
- v1.1.0 (2026-10-15): OS 언어 자동 — 한국어 OS는 한국어, 그 밖은 영어 (Mac `L()`·Windows `L()`/XAML `{local:T}`, 강제는 `WAR_LANG=ko|en`). README 언어별 스크린샷
- v1.1.1 (2026-10-15): Windows EV 코드 서명(게시자 LaonCross Inc., 타임스탬프) — `tools/windows_pc.sh build && tools/windows_pc.sh sign` (PC에서 토큰 PIN). Mac 재공증
- v1.2.0 (2026-10-22): 화면 미러링(scrcpy) + 새 아이콘(회색=연결됨, 빨강=끊김). Mac 공증 프로필 `NOTARY_PROFILE=clipboard-itda-notary` (같은 개발자 계정), 산출물 `dist/release-1.2.0/`
- v1.3.0 (2026-10-23): 메뉴 개편 + 앱 안 업데이트(주 1회 확인), Mac 아이콘 몸체 검정/흰색, 터미널 폴백 반복 수정. 산출물 `dist/release-1.3.0/`. 1.2.0 이하는 업데이트 기능이 없어 한 번은 직접 설치
- v1.3.1 (2026-10-28): 일본어·중국어(간체·번체), Mac 메뉴 막대 아이콘 크기·여백, 권한 메뉴 판단 플래그, 안내 속 옛 메뉴 이름. 산출물 `dist/release-1.3.1/`. 1.3.0은 메뉴의 업데이트로 받음
- 공개 전 개인정보 검사 → 통과할 때만 푸시
- 다음 후보: Mac 기본 알림 원인 분리, 홍보 글

## 리스크
- ad-hoc 서명 앱은 다시 빌드하면 로컬 네트워크 권한을 다시 물을 수 있음
- 앱을 종료하면 앱이 띄운 adb 서버도 종료됨 (메뉴 막대에 상주)
- Windows PC에서 앱을 띄우면 휴대폰과 실제 연결됨 → 실행 전 사용자에게 알림
- 서명 없는 exe → 첫 실행 SmartScreen 경고
