#!/usr/bin/env bash
# Mac에서 Windows PC를 SSH로 다룬다 (mac-galaxy-clipboard의 tools/windows_pc.sh 방식).
#
#   tools/windows_pc.sh sync            # windows/ assets/ → PC Documents\wireless-adb-sync
#   tools/windows_pc.sh build           # PC에서 dotnet build → dist/windows/WirelessADBReconnect.exe 로 받아옴
#   tools/windows_pc.sh sign            # 빌드한 exe를 코드 서명 (바탕화면 세션, PC에서 토큰 PIN 입력) → 받아옴
#   tools/windows_pc.sh run <인자...>   # PC 세션 0에서 빌드한 exe 실행 (창 없음, 출력만)
#   tools/windows_pc.sh desktop <분> < script.ps1   # 로그인된 바탕화면 세션에서 PowerShell 실행
#   tools/windows_pc.sh ps < script.ps1 # 세션 0에서 PowerShell 실행
#
# SSH 명령은 세션 0(바탕화면 없음)에서 돈다 → 화면에 보이는 확인은 desktop(1회용 예약 작업)으로.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# PC 주소·작업 폴더는 커밋하지 않는 tools/windows_pc.env 에 둔다:
#   WINDOWS_PC=<ssh 호스트>   WINDOWS_DEV='C:\Users\<이름>\Documents\wireless-adb-sync'
[ -f "$ROOT/tools/windows_pc.env" ] && . "$ROOT/tools/windows_pc.env"
PC="${WINDOWS_PC:?tools/windows_pc.env 에 WINDOWS_PC 를 설정하세요}"
DEV="${WINDOWS_DEV:?tools/windows_pc.env 에 WINDOWS_DEV 를 설정하세요}"
EXE="$DEV\\windows\\WirelessAdbReconnect\\bin\\Release\\net48\\WirelessADBReconnect.exe"

# PowerShell을 표준 입력으로 받아 세션 0에서 실행 (cmd 따옴표 문제를 피하려고 인코딩)
ps() {
  local encoded
  encoded=$( { printf '%s\n' '$ProgressPreference="SilentlyContinue"; [Console]::OutputEncoding=[Text.Encoding]::UTF8'; cat; } \
    | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$PC" "powershell -NoProfile -NonInteractive -EncodedCommand $encoded" 2>&1 \
    | grep -v -E '^#< CLIXML|^<Objs ' || true
}

# PowerShell을 바탕화면 세션에서 1회용 예약 작업으로 실행하고 로그를 돌려받는다
desktop() {
  local minutes="$1" task="adbrevive-agent-$$" body
  body=$(cat)
  ps <<PS
\$out = '$DEV\_agent'; New-Item -ItemType Directory -Force \$out | Out-Null
\$script = "\$out\task.ps1"; \$log = "\$out\task.log"; \$done = "\$out\task.done"
Remove-Item \$log, \$done -ErrorAction SilentlyContinue
@'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
\$log = '$DEV\_agent\task.log'; \$done = '$DEV\_agent\task.done'
"session=\$((Get-Process -Id \$PID).SessionId)" | Set-Content -Encoding utf8 \$log
try { & {
$body
} *>&1 | Out-File -Append -Encoding utf8 \$log } catch { "error: \$_" | Out-File -Append -Encoding utf8 \$log }
"done" | Set-Content \$done
'@ | Set-Content -Encoding utf8 \$script
schtasks /Create /TN '$task' /TR "conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File \`"\$script\`"" /SC ONCE /ST 23:59 /IT /F 2>&1 | Out-Null
schtasks /Run /TN '$task' 2>&1 | Out-Null
\$deadline = (Get-Date).AddMinutes($minutes)
while (-not (Test-Path \$done) -and (Get-Date) -lt \$deadline) { Start-Sleep 2 }
schtasks /Delete /TN '$task' /F 2>&1 | Out-Null
if (-not (Test-Path \$done)) { 'TIMEOUT: 아직 실행 중이거나 바탕화면이 로그인되어 있지 않음' }
if (Test-Path \$log) { Get-Content \$log -Encoding utf8 -Tail 60 }
PS
}

sync() {
  cd "$ROOT"
  ssh -o BatchMode=yes "$PC" "if not exist \"$DEV\" mkdir \"$DEV\"" >/dev/null
  git ls-files -co --exclude-standard windows assets \
    | COPYFILE_DISABLE=1 tar --no-mac-metadata -czf - -T - \
    | ssh -o BatchMode=yes "$PC" "tar -xzf - -C \"$DEV\""
  echo "synced $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- windows assets || echo ' + 커밋 안 된 변경')"
}

case "${1:-}" in
  sync) sync ;;
  build)
    sync
    ps <<PS
Set-Location '$DEV'
dotnet build windows\WirelessAdbReconnect\WirelessAdbReconnect.csproj -c Release -nologo -v:q 2>&1 | Select-Object -Last 15
"build exit=\$LASTEXITCODE"
PS
    mkdir -p "$ROOT/dist/windows"
    scp -q -o BatchMode=yes "$PC:${EXE//\\//}" "$ROOT/dist/windows/WirelessADBReconnect.exe" && echo "받음: dist/windows/WirelessADBReconnect.exe"
    ;;
  sign)
    THUMB="${WINDOWS_SIGN_THUMBPRINT:?tools/windows_pc.env 에 WINDOWS_SIGN_THUMBPRINT 를 설정하세요}"
    echo "PC 화면에 토큰 PIN 창이 뜨면 입력하세요 (최대 5분 대기)"
    desktop 5 <<PS
\$cert = @(Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My | Where-Object { \$_.Thumbprint -eq '$THUMB' })[0]
if (-not \$cert) { 'ERROR: 인증서 없음'; return }
\$r = Set-AuthenticodeSignature -FilePath '$EXE' -Certificate \$cert -HashAlgorithm SHA256 -TimestampServer 'http://timestamp.digicert.com'
\$c = Get-AuthenticodeSignature -FilePath '$EXE'
"서명: \$(\$c.Status) / \$(\$c.SignerCertificate.Subject.Split(',')[0]) / 타임스탬프: \$([bool]\$c.TimeStamperCertificate)"
PS
    mkdir -p "$ROOT/dist/windows"
    scp -q -o BatchMode=yes "$PC:${EXE//\\//}" "$ROOT/dist/windows/WirelessADBReconnect.exe" && echo "받음: dist/windows/WirelessADBReconnect.exe"
    ;;
  run) shift; ps <<PS
& '$EXE' $* | Out-String
PS
    ;;
  desktop) desktop "${2:-5}" ;;
  ps) ps ;;
  *) sed -n '2,11p' "$0"; exit 2 ;;
esac
