# TROUBLESHOOTING

## Mac: "기기 안 잡힘", `adb connect` → `No route to host`
- 원인: macOS 로컬 네트워크 권한. adb 서버는 자신을 띄운 프로그램의 권한을 따른다. 권한 없는 프로그램이 띄운 서버는 mDNS 탐색·휴대폰 접속이 막힌다. (`nc`, `dns-sd` 같은 Apple 기본 도구는 예외라 접속되는 것처럼 보임)
- 사례 1: `~/.zshrc`에서 **터미널 세션 관리 도구(데몬)를 자동 실행** → 터미널 명령이 그 데몬(권한 없음) 아래에서 실행됨 → 터미널에서 `adb nodaemon server &`도 실패.
- 사례 2: 스크립트 기반 .app, ad-hoc 앱이 `adb start-server`로 띄운 데몬 → 실패.
- 해결: Swift 앱이 `adb nodaemon server`를 **자식 프로세스로 소유** + Info.plist에 `NSLocalNetworkUsageDescription`/`NSBonjourServices` → 첫 실행 때 허용. (2026-10-13 성공 확인)
- 터미널 폴백(권한 없을 때 별도 Terminal 창에서 서버 실행)은 1.4.0 다음 버전에서 뺐다 — 터미널 창이 남아서 (2026-11-10 사용자 요청). 권한이 없으면 안내만 한다.
- 확인: 메뉴 막대 → 진단 로그. `adb 서버 소유 = ...` 줄에 띄운 프로그램 계보가 나옴.
- 주의: 권한 없는 프로그램이 띄운 서버가 남아 있으면 모든 adb가 그 서버를 씀 → 앱이 재시작하며 정리.

## Mac: 로컬 네트워크 권한 — 확인 방법, 목록의 중복 항목 (2026-11-10 확인, macOS 27.0.1)
- 상태를 묻는 API가 없다. Bonjour 탐색이 `ready`면 허용, `kDNSServiceErr_PolicyDenied`(-65570)면 거부(또는 허용 창이 떠 있는 중). 휴대폰 접속은 `NWPath.unsatisfiedReason == .localNetworkDenied`로 확인.
- **접속 시간 초과는 권한 문제가 아니다.** 1.4.0까지는 "휴대폰이 보이지만 접속 안 됨"을 권한 문제로 보고 경고·시스템 설정을 띄웠다. 실제 원인은 휴대폰 인증 만료·IP 변경이었다 → 이제 거부가 확인될 때만 경고.
- 권한 기록: `/Library/Preferences/com.apple.networkextension.plist`의 `NEPathRule` (읽기 가능, 쓰기는 root). 앱은 서명 ID(번들 ID)로 한 줄. **같은 ID를 다른 위치에서 실행하면 그 경로가 붙은 줄이 따로 생긴다** (예: 빌드 폴더 `dist/`의 앱).
- 그래서 앱은 응용 프로그램 폴더 밖에서는 네트워크를 쓰지 않는다(다시 연결·미러링·페어링 대신 설치 단계를 엶). 앱 내 업데이트(같은 자리에 바꿔 넣기)는 같은 줄을 다시 쓴다.
- **완전 삭제 후 재설치하면 하나로 정리된다** (2026-11-10 확인): `--uninstall`(휴지통으로) → 휴지통 비우기 → 다운로드 위치에서 열어 마법사로 설치 → 이 앱 줄이 2개(앱 + `dist/` 경로)에서 1개(허용)로. 전체 275 → 274줄. macOS가 지워진 앱의 줄을 정리한 것으로 보임.
- 기록 파일은 root로도 고칠 수 없다(`cp: Operation not permitted`, 시스템 보호). 직접 지우는 방법은 쓰지 않는다.
- 시스템 설정 목록에는 + 버튼도, 지우기 버튼도 없다. 목록은 줄의 서명 ID로 앱을 찾아 보여 줘서, 경로 붙은 줄은 그 경로의 파일을 지워도 같은 앱으로 계속 보였다(사용자 화면, 2026-11-10).
- 시스템 설정 주소: macOS 27에는 로컬 네트워크 화면 주소가 없다(`Privacy_LocalNetwork`·`privacy-localnetwork` 모두 '개인정보 보호 및 보안' 첫 화면). → 도우미 창이 '로컬 네트워크'를 누르라고 안내.
- 개발: 빌드 폴더(`dist/`)의 앱을 실행하면 경로 붙은 줄이 생긴다(지금은 폴더 밖에서는 네트워크를 안 써서 생기지 않음). 이 Mac에 설치할 때는 `INSTALL=1 ./mac/build_app.sh` → /Applications로 바꿔 넣고 빌드 폴더의 앱을 지운다.
- 개발 시험: 터미널에서 실행 파일을 바로 띄우면 **터미널의 권한**이 확인된다. `open -n "/Applications/Wireless ADB Reconnect.app" --args --check-network` → 진단 로그에 `allowed`/`denied`. 빌드 폴더의 앱으로는 하지 않는다(중복 줄이 생김).

## 무선 기기 이름이 IP:포트가 아님 (`adb-XXXX._adb-tls-connect._tcp`)
- 원인: mDNS 자동 연결된 기기라 IP:포트가 기록되지 않음.
- 해결: 스크립트가 `dns-sd`로 IP:포트를 찾아 `adb connect`한다. 수동: `dns-sd -B _adb-tls-connect._tcp` → `dns-sd -L <이름> _adb-tls-connect._tcp` → `dns-sd -G v4 <호스트>`.

## Windows: 페어링 실패 `protocol fault` / `cannot connect ... (10060)`
- 원인: 페어링 도중 휴대폰 IP가 바뀜 (예: `192.168.0.20` → `.21`). 휴대폰이 무작위 MAC 주소를 써서 Wi‑Fi/대역이 바뀌면 IP도 바뀐다. 옛 주소로 페어링을 시도해 시간 초과.
- 결과: 같은 이유로 무선 디버깅 포트·IP가 바뀌어 연결이 끊길 수 있다.
- 해결: 페어링 창이 접속되는 새 주소가 보일 때까지 기다렸다 다시 시도한다 (실패해도 5분 동안 재시도). 수동으로는 QR 창을 다시 열어 새 QR로 찍기.
- 참고: Mac과 동시에 연결해도 문제없음 (같은 휴대폰에 Mac·PC 동시 무선 연결 확인).

## Windows: "adb 연결이 거부됨 → 이 PC와 페어링이 안 됨"
- 원인: 휴대폰은 보이고 접속도 되지만 이 PC의 adb 키가 휴대폰에 등록되지 않음 (서버 로그 `SSLV3_ALERT_CERTIFICATE_UNKNOWN`).
- 해결: 트레이 메뉴 '휴대폰 페어링 (QR)'으로 한 번 페어링.

## Mac: macOS 기본 알림이 안 뜸 (`Notifications are not allowed for this application`)
- 원인 (2026-10-15 시험 앱으로 확인): macOS는 "알림 허용" 배너를 **한 번만** 오른쪽 위에 조용히 띄운다. 답하지 않고 사라지면 **거부(denied)로 기록**하고, 그 뒤로는 묻지 않고 바로 거부한다. 우리 앱은 첫 실행 때 설치 마법사와 함께 배너가 떠서 놓치기 쉬웠다.
- 참고: 응용 프로그램 폴더 밖(임시 폴더 등)에서 실행한 앱은 배너 없이 바로 거부된다 (이때는 거부로 기록되지 않음).
- 서명·공증·메뉴 막대 앱(LSUIElement)·하드닝은 원인이 아니었다 (일반 앱도 같은 결과).
- 해결: 시스템 설정 → 알림 → Wireless ADB Reconnect → **알림 허용** 켜기. 꺼져 있으면 앱은 자체 팝업으로 알린다.

## Mac: 화면 미러링(scrcpy)을 띄우면 무선 연결이 끊김 (옛 스크립트 앱)
- 원인: scrcpy가 자기 PATH의 adb(Homebrew)를 쓴다. 이 앱의 adb(Android SDK)와 버전이 다르면 scrcpy의 adb 클라이언트가 서버를 죽이고 새로 띄운다 → 앱이 소유하던 서버가 사라지고 무선 연결도 끊김. 옛 `무선디버깅.app`(run.bash)은 아예 `adb kill-server`를 먼저 호출했다.
- 해결: 앱이 scrcpy를 `ADB=<앱이 찾은 adb>` 환경변수로 실행 (`mac/Mirror.swift`). scrcpy는 이 변수를 지원한다 (`scrcpy --help` → Environment variables). 2026-10-15 확인: 미러링 시작·종료 후에도 서버 pid와 무선 기기가 그대로.
- 기기 선택: USB와 무선이 함께 붙어 있으면 `-s <무선 serial>`로 무선을 지정. 지정 안 하면 scrcpy가 "여러 기기" 오류로 멈춘다.

## Mac: 미러링 중 무선이 끊기면 scrcpy가 종료됨 (코드 2)
- 원인: scrcpy는 연결이 끊기면 스스로 끝난다 (자동 재접속 없음).
- 결과: 앱이 종료 코드를 보고 알림을 띄운다 ("미러링이 끊겼어요"). 사용자가 창을 닫거나 메뉴에서 중지한 경우(코드 0 / 사용자 중지)는 조용히 넘어간다.
- 해결: 미러링 시작을 다시 누르면 먼저 다시 붙이고(IP:포트 직접 연결 등) 미러링을 다시 띄운다. 자동 재시작은 아직 없음 (다음 후보).
- 참고 (2026-10-15): Mac·Windows 동시 미러링 테스트 중 한 번, 둘 다 거의 같은 순간에 코드 0(정상 종료)으로 끝난 일이 있었다. 사용자 중지도 아니고 연결 끊김(코드 2)도 아니어서 원인 미확인(휴대폰 쪽 이벤트로 추정). 이후 동시 미러링 2분 이상 정상, 재현 안 됨.

## Windows: `--mirror`로 실행했는데 미러링이 안 뜸 (앱이 막 시작했을 때)
- 원인: 트레이 앱이 막 시작해 다시 붙이는 중(busy)이면 `--mirror` 신호를 버렸다 (1.2.0 개발 중 확인).
- 해결: 다시 붙이기가 끝난 뒤 이어서 미러링하도록 대기열(mirrorPending)을 둠. `--mirror`로 바로 실행하면 재연결 → 미러링 순서로 진행된다.

## Windows: scrcpy 설치 위치와 adb 충돌
- scrcpy zip에는 adb.exe가 함께 들어 있다. PATH에 넣지 않고 `%LOCALAPPDATA%\Wireless ADB Reconnect\scrcpy\`에만 두며, 실행 때 `ADB` 환경변수로 앱의 adb를 강제하므로 서버 버전 충돌이 없다.
- 콘솔 창 없이(CreateNoWindow) 실행하고 scrcpy(SDL) 창만 보인다. 중지는 창 닫기 메시지(CloseMainWindow)로 보내 녹화 파일이 정상 마무리되게 한다.
