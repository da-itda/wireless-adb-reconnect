using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using static WirelessAdbReconnect.Lang;

namespace WirelessAdbReconnect
{
    /// 화면 미러링 (scrcpy) — 이 앱이 소유한 adb 서버를 그대로 쓴다.
    /// scrcpy를 `ADB=<앱이 찾은 adb>` 환경변수로 실행해, scrcpy에 딸린 adb.exe가 버전 불일치로 서버를 죽이는 일을 막는다.
    /// 기기는 앱이 알고 있는 무선 serial을 `-s`로 지정 → USB가 같이 꽂혀 있어도 무선으로 미러링.
    class Mirror
    {
        public const string ScrcpyVersion = "5.0.1";
        static string Arch => RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "winarm64" : "win64";
        static string ZipUrl => $"https://github.com/Genymobile/scrcpy/releases/download/v{ScrcpyVersion}/scrcpy-{Arch}-v{ScrcpyVersion}.zip";

        Process process;
        bool stoppedByUser;
        /// scrcpy가 끝났을 때 (종료 코드, 사용자가 중지한 것인지). UI 스레드가 아님.
        public event Action<int, bool> Exited;

        public bool IsRunning { get { try { return process != null && !process.HasExited; } catch { return false; } } }

        // ---------- 설정 (settings.txt) ----------

        public static readonly (string value, string title)[] Qualities =
        {
            ("4M", L("낮음 (4M · 느린 Wi‑Fi)", "Low (4M · slow Wi‑Fi)")),
            ("8M", L("보통 (8M)", "Normal (8M)")),
            ("16M", L("높음 (16M)", "High (16M)")),
        };
        public string Quality { get => Settings.Get("mirrorQuality") ?? "8M"; set => Settings.Set("mirrorQuality", value); }
        public bool Audio { get => Settings.Get("mirrorAudio") != "0"; set => Settings.Set("mirrorAudio", value ? "1" : "0"); }
        public bool AlwaysOnTop { get => Settings.Get("mirrorOnTop") == "1"; set => Settings.Set("mirrorOnTop", value ? "1" : "0"); }
        public bool TurnScreenOff { get => Settings.Get("mirrorScreenOff") == "1"; set => Settings.Set("mirrorScreenOff", value ? "1" : "0"); }
        public bool Record { get => Settings.Get("mirrorRecord") == "1"; set => Settings.Set("mirrorRecord", value ? "1" : "0"); }
        /// 녹화 파일 저장 폴더 (내 비디오)
        public static string RecordDir => Environment.GetFolderPath(Environment.SpecialFolder.MyVideos);
        /// 설치 마법사에서 '미러링도 설치'를 끄고 지나갔는지 (다음에 2단계를 다시 보여 주지 않음)
        public static bool Declined { get => Settings.Get("mirrorDeclined") == "1"; set => Settings.Set("mirrorDeclined", value ? "1" : "0"); }

        // ---------- scrcpy 찾기 ----------

        /// 앱이 설치한 것 → 환경변수 SCRCPY → Programs\scrcpy → winget 패키지 → Program Files → PATH
        public static string Find()
        {
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var list = new List<string> { Path.Combine(Paths.Scrcpy, "scrcpy.exe") };
            var env = Environment.GetEnvironmentVariable("SCRCPY");
            if (!string.IsNullOrEmpty(env)) list.Add(env);
            list.Add(Path.Combine(local, "Programs", "scrcpy", "scrcpy.exe"));
            try
            {
                var winget = Path.Combine(local, @"Microsoft\WinGet\Packages");
                if (Directory.Exists(winget))
                    foreach (var pkg in Directory.GetDirectories(winget, "Genymobile.scrcpy*"))
                        list.AddRange(Directory.GetFiles(pkg, "scrcpy.exe", SearchOption.AllDirectories));
            }
            catch { }
            list.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "scrcpy", "scrcpy.exe"));
            var found = list.FirstOrDefault(File.Exists);
            if (found != null) return found;
            var w = Shell.Run("where", "scrcpy.exe", 5000);
            return w.code == 0 ? w.output.Split('\n').Select(s => s.Trim()).FirstOrDefault(File.Exists) : null;
        }

        public static bool IsInstalled => Find() != null;

        // ---------- 설치 (GitHub 릴리스 zip → %LOCALAPPDATA%\<앱>\scrcpy) ----------

        public static async Task Install(IProgress<int> progress)
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            var zip = Path.Combine(Path.GetTempPath(), "wireless-adb-reconnect-scrcpy.zip");
            var tmp = Path.Combine(Paths.Data, "scrcpy-new");
            Log.Write(L("scrcpy 받는 중: ", "Downloading scrcpy: ") + ZipUrl);
            using (var wc = new WebClient())
            {
                wc.Headers[HttpRequestHeader.UserAgent] = AppInfo.Exe;
                wc.DownloadProgressChanged += (s, e) => progress.Report(e.ProgressPercentage);
                await wc.DownloadFileTaskAsync(new Uri(ZipUrl), zip);
            }
            await Task.Run(() =>
            {
                if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
                ZipFile.ExtractToDirectory(zip, tmp);
                // zip 안에 scrcpy-win64-v5.0.1\ 폴더 하나가 들어 있다
                var inner = Directory.GetDirectories(tmp).FirstOrDefault(d => File.Exists(Path.Combine(d, "scrcpy.exe")))
                            ?? (File.Exists(Path.Combine(tmp, "scrcpy.exe")) ? tmp : null);
                if (inner == null) throw new Exception(L("zip 안에 scrcpy.exe가 없어요", "scrcpy.exe not found in the zip"));
                if (Directory.Exists(Paths.Scrcpy)) Directory.Delete(Paths.Scrcpy, true);
                Directory.Move(inner, Paths.Scrcpy);
                if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
                File.Delete(zip);
            });
            Log.Write(L("scrcpy 설치 완료: ", "scrcpy installed: ") + Paths.Scrcpy);
        }

        // ---------- 실행 · 중지 ----------

        /// 무선 기기(serial)로 scrcpy를 띄운다. adb는 앱이 찾은 것을 그대로 쓴다.
        public (bool ok, string message) Start(string adb, string serial, string title)
        {
            var exe = Find();
            if (exe == null) return (false, L("scrcpy가 설치되어 있지 않아요. 설정 창에서 '화면 미러링도 설치'를 켜 주세요.", "scrcpy is not installed. Turn on 'Also install screen mirroring' in Settings."));
            if (IsRunning) return (true, L("이미 미러링 중이에요.", "Already mirroring."));

            var args = new StringBuilder();
            args.Append($"-s {serial} --video-bit-rate={Quality} --window-title=\"{title}\" --stay-awake --keyboard=uhid");   // HID 키보드: 한글 입력 호환
            if (!Audio) args.Append(" --no-audio");
            if (AlwaysOnTop) args.Append(" --always-on-top");
            if (TurnScreenOff) args.Append(" --turn-screen-off");
            if (Record)
            {
                Directory.CreateDirectory(RecordDir);
                args.Append($" --record=\"{Path.Combine(RecordDir, AppInfo.Short + " " + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".mp4")}\"");
            }

            var psi = new ProcessStartInfo(exe, args.ToString())
            {
                UseShellExecute = false,
                CreateNoWindow = true,          // 콘솔 창은 숨기고 scrcpy(SDL) 창만 보이게
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
                WorkingDirectory = Path.GetDirectoryName(exe),
            };
            psi.EnvironmentVariables["ADB"] = adb;   // 앱의 adb를 쓰게 함 (서버 버전 불일치 방지)
            var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
            try
            {
                Directory.CreateDirectory(Paths.Data);
                File.AppendAllText(Paths.MirrorLog, $"\r\n===== {DateTime.Now:yyyy-MM-dd HH:mm:ss} scrcpy {args}\r\n", Encoding.UTF8);
            }
            catch { }
            DataReceivedEventHandler toLog = (s, e) => { if (e.Data != null) try { File.AppendAllText(Paths.MirrorLog, e.Data + "\r\n", Encoding.UTF8); } catch { } };
            p.OutputDataReceived += toLog;
            p.ErrorDataReceived += toLog;
            stoppedByUser = false;
            p.Exited += (s, e) =>
            {
                int code; try { code = p.ExitCode; } catch { code = -1; }
                Log.Write(L("  미러링 종료, 코드 ", "  Mirroring ended, code ") + code + (stoppedByUser ? L(" (사용자 중지)", " (stopped by user)") : ""));
                Exited?.Invoke(code, stoppedByUser);
            };
            try
            {
                p.Start();
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
            }
            catch (Exception ex)
            {
                Log.Write(L("  scrcpy 실행 실패: ", "  Failed to start scrcpy: ") + ex.Message);
                return (false, L("scrcpy를 실행하지 못했어요: ", "Couldn't start scrcpy: ") + ex.Message);
            }
            process = p;
            Log.Write(L("▶ 미러링 시작 pid ", "▶ Mirroring started pid ") + $"{p.Id} · {serial} · {exe} · ADB={adb}");
            return (true, "");
        }

        /// 창 닫기 메시지로 정상 종료(녹화 파일 마무리) → 안 끝나면 강제 종료
        public void Stop()
        {
            var p = process;
            if (p == null || !IsRunning) return;
            stoppedByUser = true;
            try
            {
                var closed = p.MainWindowHandle != IntPtr.Zero && p.CloseMainWindow();
                if (!closed || !p.WaitForExit(3000)) { p.Kill(); p.WaitForExit(2000); }
            }
            catch { }
        }
    }
}
