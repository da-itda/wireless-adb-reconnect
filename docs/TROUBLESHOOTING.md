# TROUBLESHOOTING

## Mac: "기기 안 잡힘", `adb connect` → `No route to host`
- 원인: macOS 로컬 네트워크 권한. adb 서버는 자신을 띄운 프로그램의 권한을 따른다. 권한 없는 프로그램이 띄운 서버는 mDNS 탐색·휴대폰 접속이 막힌다. (`nc`, `dns-sd` 같은 Apple 기본 도구는 예외라 접속되는 것처럼 보임)
- 사례 1: `~/.zshrc`에서 **터미널 세션 관리 도구(데몬)를 자동 실행** → 터미널 명령이 그 데몬(권한 없음) 아래에서 실행됨 → 터미널에서 `adb nodaemon server &`도 실패.
- 사례 2: 스크립트 기반 .app, ad-hoc 앱이 `adb start-server`로 띄운 데몬 → 실패.
- 해결: Swift 앱이 `adb nodaemon server`를 **자식 프로세스로 소유** + Info.plist에 `NSLocalNetworkUsageDescription`/`NSBonjourServices` → 첫 실행 때 허용. (2026-10-13 성공 확인)
- 확인: 메뉴 막대 → 진단 로그. `adb 서버 소유 = ...` 줄에 띄운 프로그램 계보가 나옴.
- 주의: 권한 없는 프로그램이 띄운 서버가 남아 있으면 모든 adb가 그 서버를 씀 → 앱이 재시작하며 정리.

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
- 증상: 알림 허용 창이 아예 안 뜨고, 시스템 설정 > 알림 목록에도 앱이 없다 (ncprefs에 항목 없음).
- 시도 (2026-10-15, 모두 실패): ad-hoc 서명 → Developer ID 서명 → Apple 공증(Accepted, stapled) → LaunchServices 중복 등록(휴지통·dist) 제거.
- 현재: 앱 아이콘이 들어간 자체 팝업(Toast)으로 대신 알린다. 원인은 미확인 — 최소 예제 앱으로 분리 확인 필요.
