using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using static WirelessAdbReconnect.Lang;

namespace WirelessAdbReconnect
{
    // 무선 adb가 끊기면: 원인 진단 → 여러 방법을 순서대로 시도 → 붙은 방법을 기억해 다음엔 먼저 시도 (Mac 앱과 같은 구조)
    // adb 서버는 이 앱이 자식(nodaemon)으로 띄우고, 앱을 끝내면 함께 끝낸다.

    enum Strategy { ReconnectOffline, ConnectOnly, OwnServer, OwnServerOpenscreen }

    class Device
    {
        public string Serial, State, Model;
        public bool IsIPPort => Regex.IsMatch(Serial, @"^\d+\.\d+\.\d+\.\d+:\d+$");
        public bool IsWireless => IsIPPort || Serial.Contains("._adb-tls-connect.");
    }

    class MdnsService
    {
        public string Name, Type, Address;
    }

    static class AdbLocator
    {
        /// Android SDK의 adb를 먼저 쓴다 — Android Studio와 버전이 다르면 서로 서버를 죽여 연결이 끊긴다
        public static string Find()
        {
            var dirs = new List<string>();
            foreach (var v in new[] { "ANDROID_HOME", "ANDROID_SDK_ROOT" })
            {
                var d = Environment.GetEnvironmentVariable(v);
                if (!string.IsNullOrEmpty(d)) dirs.Add(Path.Combine(d, "platform-tools"));
            }
            dirs.Insert(0, Path.GetDirectoryName(Paths.SdkAdb));
            dirs.Add(Paths.PlatformTools);
            dirs.AddRange((Environment.GetEnvironmentVariable("PATH") ?? "").Split(';').Where(p => p.Length > 0));
            foreach (var d in dirs)
            {
                try
                {
                    var exe = Path.Combine(d.Trim('"'), "adb.exe");
                    if (File.Exists(exe)) return exe;
                }
                catch { }
            }
            return null;
        }
    }

    class Reviver
    {
        readonly object gate = new object();
        readonly List<string> causes = new List<string>();
        Process server;     // 앱이 소유한 nodaemon 서버

        public string Adb { get; private set; } = AdbLocator.Find();
        public void RefreshAdb() => Adb = AdbLocator.Find();

        public static string Title(Strategy s)
        {
            switch (s)
            {
                case Strategy.ReconnectOffline: return L("offline 기기 재연결", "Reconnect offline device");
                case Strategy.ConnectOnly: return L("서버 유지 + IP:포트 직접 연결", "Keep server, connect to IP:port");
                case Strategy.OwnServer: return L("앱이 adb 서버 재시작", "Restart adb server (owned by app)");
                default: return L("앱이 adb 서버 재시작 (openscreen mDNS)", "Restart adb server (openscreen mDNS)");
            }
        }

        public Strategy? Winner
        {
            get => Enum.TryParse(Settings.Get("winner"), out Strategy s) ? s : (Strategy?)null;
            set => Settings.Set("winner", value?.ToString());
        }

        public string LastAddr
        {
            get => Settings.Get("lastAddr");
            set => Settings.Set("lastAddr", value);
        }

        // ---------- adb 조회 (서버가 없을 때 부르면 그 자리에서 서버가 떠버리므로 포트부터 확인) ----------

        public List<Device> Devices()
        {
            var list = new List<Device>();
            if (Adb == null || !Shell.PortOpen()) return list;
            var o = Shell.Run(Adb, "devices -l", 6000).output;
            if (o.Contains("doesn't match this client")) AddCause(L("adb 버전 불일치 → 다른 adb(Android Studio·scrcpy 등)가 서버를 띄움", "adb version mismatch → another adb (Android Studio, scrcpy, etc.) started the server"));
            foreach (var line in o.Split('\n').Skip(1))
            {
                var f = line.Split(new[] { ' ', '\t', '\r' }, StringSplitOptions.RemoveEmptyEntries);
                if (f.Length < 2) continue;
                var model = f.FirstOrDefault(x => x.StartsWith("model:"))?.Substring(6).Replace('_', '-');
                list.Add(new Device { Serial = f[0], State = f[1], Model = model });
            }
            return list;
        }

        /// 무선으로 연결된 기기 (USB 연결은 "붙었다"로 치지 않음)
        public Device Connected() => Devices().FirstOrDefault(d => d.State == "device" && d.IsWireless);

        public List<MdnsService> MdnsServices()
        {
            var list = new List<MdnsService>();
            if (Adb == null || !Shell.PortOpen()) return list;
            foreach (var line in Shell.Run(Adb, "mdns services", 6000).output.Split('\n'))
            {
                var f = line.Split(new[] { ' ', '\t', '\r' }, StringSplitOptions.RemoveEmptyEntries);
                if (f.Length >= 3 && f[1].StartsWith("_adb")) list.Add(new MdnsService { Name = f[0], Type = f[1], Address = f[2] });
            }
            return list;
        }

        public string PhoneAddr() => MdnsServices().FirstOrDefault(s => s.Type.StartsWith("_adb-tls-connect"))?.Address;

        /// 5037 포트를 연 프로세스 (pid, 실행 파일 경로)
        public (int pid, string path)? ServerOwner()
        {
            foreach (var line in Shell.Run("netstat", "-ano -p TCP", 6000).output.Split('\n'))
            {
                var f = line.Split(new[] { ' ', '\t', '\r' }, StringSplitOptions.RemoveEmptyEntries);
                if (f.Length >= 5 && f[1].EndsWith(":5037") && f[3] == "LISTENING" && int.TryParse(f[4], out var pid))
                {
                    string path;
                    try { path = Process.GetProcessById(pid).MainModule.FileName; } catch { path = "pid " + pid; }
                    return (pid, path);
                }
            }
            return null;
        }

        bool OwnsServer()
        {
            try { return server != null && !server.HasExited && ServerOwner()?.pid == server.Id; } catch { return false; }
        }

        void AddCause(string c, bool first = false)
        {
            lock (causes)
            {
                if (causes.Contains(c)) return;
                if (first) causes.Insert(0, c); else causes.Add(c);
            }
            Log.Write(L("  원인 후보: ", "  Possible cause: ") + c);
        }

        // ---------- 메인 루틴 ----------

        public (bool ok, string message) Revive()
        {
            lock (gate)
            {
                Log.Write(L("===== 다시 붙이기 시작", "===== Reconnect started"));
                lock (causes) causes.Clear();
                RefreshAdb();
                if (Adb == null) return Finish(false, L("adb를 찾을 수 없어요. 설정에서 adb를 설치해 주세요.", "adb not found. Install it from Settings."));
                Log.Write(L("진단: adb = ", "Diagnosis: adb = ") + Adb);

                // 1) 진단
                var before = Devices();
                Log.Write(L("진단: 기기 = ", "Diagnosis: devices = ") + string.Join(", ", before.Select(d => $"{d.Serial}({d.State})")));
                var already = before.FirstOrDefault(d => d.State == "device" && d.IsWireless);
                if (already != null) return Finish(true, L("이미 연결되어 있어요: ", "Already connected: ") + already.Serial);

                var owner = ServerOwner();
                var owns = OwnsServer();
                if (owner == null) Log.Write(L("진단: adb 서버 꺼져 있음", "Diagnosis: adb server not running"));
                else
                {
                    Log.Write(L("진단: adb 서버 = ", "Diagnosis: adb server = ") + (owns ? L("이 앱", "this app") : owner.Value.path));
                    if (!owns && !string.Equals(owner.Value.path, Adb, StringComparison.OrdinalIgnoreCase))
                        AddCause(L("다른 adb({0})가 서버를 띄움 → 버전이 다르면 서로 서버를 죽여 연결이 끊김 (Android Studio·scrcpy 등)", "Another adb ({0}) started the server → different versions kill each other's server (Android Studio, scrcpy, etc.)", owner.Value.path));
                }
                if (before.Any(d => d.State == "offline")) AddCause(L("기기가 offline 상태로 남아 있음", "Device is stuck offline"));
                if (before.Any(d => d.State == "unauthorized")) AddCause(L("휴대폰에서 디버깅 허용 필요 (unauthorized)", "Allow debugging on the phone (unauthorized)"));

                var phone = owns ? PhoneAddr() : null;
                if (phone != null) { Log.Write(L("진단: 휴대폰 = ", "Diagnosis: phone = ") + phone); LastAddr = phone; }

                // 2) 시도 순서: 끊지 않는 방법 → 기억한 방법 → 나머지
                var order = new List<Strategy>();
                if (before.Any(d => d.State == "offline")) order.Add(Strategy.ReconnectOffline);
                if (owns && phone != null) order.Add(Strategy.ConnectOnly);
                var quick = order.Count;
                order.Add(Strategy.OwnServer);
                order.Add(Strategy.OwnServerOpenscreen);
                var w = Winner;
                if (w.HasValue && order.IndexOf(w.Value) > quick) { order.Remove(w.Value); order.Insert(quick, w.Value); }
                Log.Write(L("시도 순서: ", "Order: ") + string.Join(" → ", order.Select(Title)));

                // 3) 순서대로 시도, 붙으면 종료
                foreach (var s in order)
                {
                    Log.Write(L("▶ 시도: ", "▶ Trying: ") + Title(s));
                    if (Attempt(s))
                    {
                        Winner = s;
                        var d = Connected();
                        if (d != null && d.IsIPPort) LastAddr = d.Serial;
                        return Finish(true, L("다시 붙었어요 — ", "Reconnected — ") + Title(s));
                    }
                    Log.Write(L("  실패: ", "  Failed: ") + Title(s));
                }

                DiagnoseNetwork();
                string top;
                lock (causes) top = causes.FirstOrDefault() ?? L("원인을 찾지 못했어요", "Unknown cause");
                return Finish(false, top + L(" (눌러서 진단 보기)", " (click for diagnostics)"));
            }
        }

        (bool, string) Finish(bool ok, string msg)
        {
            lock (causes)
                if (!ok && causes.Count > 1) Log.Write(L("원인 후보 전체:", "All possible causes:") + "\r\n  - " + string.Join("\r\n  - ", causes));
            Log.Write(L("결과: ", "Result: ") + msg);
            return (ok, msg);
        }

        /// 모든 방법이 실패했을 때: 휴대폰이 보이는지, 접속되는지, 네트워크 설정을 확인
        void DiagnoseNetwork()
        {
            var phone = PhoneAddr();
            if (phone == null)
            {
                var profile = Shell.Run("powershell", "-NoProfile -Command \"(Get-NetConnectionProfile | ForEach-Object { $_.InterfaceAlias + '=' + $_.NetworkCategory }) -join ', '\"", 10000).output;
                Log.Write(L("진단: 네트워크 프로필 = ", "Diagnosis: network profile = ") + profile);
                if (profile.Contains("Public"))
                    AddCause(L("네트워크가 '공용'으로 설정됨 → mDNS가 막혀 휴대폰을 못 찾음. 설정 > 네트워크 > 속성에서 '개인'으로 바꾸세요", "Network is set to Public → mDNS is blocked. Change it to Private in Settings > Network > Properties"), true);
                AddCause(L("휴대폰이 보이지 않음 → 휴대폰 무선 디버깅 꺼짐 / 화면 꺼짐·절전 / 다른 Wi‑Fi, 또는 방화벽이 mDNS(UDP 5353)를 막음", "Phone not visible → wireless debugging off / screen off or power saving / different Wi‑Fi, or a firewall blocks mDNS (UDP 5353)"), true);
            }
            else if (!Shell.TcpReachable(phone))
            {
                AddCause(L("휴대폰({0})은 보이지만 접속 안 됨 → 방화벽·VPN·다른 네트워크 확인", "Phone ({0}) is visible but unreachable → check firewall, VPN, network", phone), true);
            }
            else
            {
                // 보이고 접속도 되는데 adb가 거부 → 이 PC가 휴대폰과 페어링되지 않은 경우가 대부분
                AddCause(L("휴대폰({0})은 보이고 네트워크도 정상이지만 adb 연결이 거부됨 → 이 PC와 페어링이 안 됨. 트레이 메뉴 '휴대폰 페어링'으로 페어링하세요", "Phone ({0}) is reachable but adb refused → this PC isn't paired. Use 'Pair phone' in the tray menu", phone), true);
            }
        }

        bool Attempt(Strategy s)
        {
            switch (s)
            {
                case Strategy.ReconnectOffline:
                    Shell.Run(Adb, "reconnect offline", 10000);
                    return Shell.WaitUntil(5, () => Connected() != null);
                case Strategy.ConnectOnly:
                    return ConnectCandidates(PhoneAddr());
                default:
                    StopServer();
                    var env = s == Strategy.OwnServerOpenscreen ? new Dictionary<string, string> { ["ADB_MDNS_OPENSCREEN"] = "1" } : null;
                    if (!StartOwnServer(env)) return false;
                    if (Shell.WaitUntil(10, () => Connected() != null)) return true;
                    var phone = PhoneAddr();
                    Log.Write(L("  mDNS 휴대폰 = ", "  mDNS phone = ") + (phone ?? L("없음", "none")));
                    return ConnectCandidates(phone);
            }
        }

        bool ConnectCandidates(string found)
        {
            var addrs = new[] { found, LastAddr }.Where(a => !string.IsNullOrEmpty(a)).Distinct().ToList();
            foreach (var a in addrs)
            {
                var o = Shell.Run(Adb, "connect " + a, 12000).output;
                Log.Write($"  adb connect {a}: {o}");
                var l = o.ToLowerInvariant();
                if (l.Contains("connection refused") || l.Contains("actively refused")) AddCause(L("Connection refused → 무선 디버깅 포트가 바뀌었거나 꺼짐", "Connection refused → wireless debugging port changed or turned off"));
                if (l.Contains("authenticat")) AddCause(L("인증 실패 → 이 PC와 페어링이 안 됨. 트레이 메뉴 '휴대폰 페어링'으로 다시 페어링", "Authentication failed → this PC isn't paired. Use 'Pair phone' in the tray menu"));
                if (l.Contains("timed out") || l.Contains("did not properly respond")) AddCause(L("시간 초과 → 휴대폰 절전 / 다른 Wi‑Fi / VPN 경로", "Timed out → phone asleep / different Wi‑Fi / VPN route"));
                if (l.Contains("no route") || l.Contains("unreachable")) AddCause(L("경로 없음 → 휴대폰과 PC가 다른 네트워크", "No route → phone and PC are on different networks"));
                if (Shell.WaitUntil(3, () => Connected() != null)) return true;
            }
            return false;
        }

        // ---------- 서버 관리 ----------

        public void StopServer()
        {
            if (Adb != null && Shell.PortOpen()) Shell.Run(Adb, "kill-server", 6000);
            try { if (server != null && !server.HasExited) server.Kill(); } catch { }
            server = null;
            if (!Shell.WaitUntil(5, () => !Shell.PortOpen()))
            {
                var o = ServerOwner();
                if (o != null)
                {
                    Log.Write(L("  서버가 안 꺼져서 강제 종료: ", "  Server did not stop, killing: ") + $"pid {o.Value.pid} ({o.Value.path})");
                    try { Process.GetProcessById(o.Value.pid).Kill(); } catch { }
                    Shell.WaitUntil(3, () => !Shell.PortOpen());
                }
            }
        }

        bool StartOwnServer(IDictionary<string, string> env)
        {
            var psi = new ProcessStartInfo(Adb, "nodaemon server")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            if (env != null) foreach (var kv in env) psi.EnvironmentVariables[kv.Key] = kv.Value;
            var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
            DataReceivedEventHandler sink = (s, e) =>
            {
                if (e.Data == null) return;
                try { File.AppendAllText(Paths.ServerLog, e.Data + "\r\n", Encoding.UTF8); } catch { }
            };
            p.OutputDataReceived += sink;
            p.ErrorDataReceived += sink;
            p.Exited += (s, e) => Log.Write(L("  (앱의 adb 서버 종료)", "  (app's adb server exited)"));
            try
            {
                Directory.CreateDirectory(Paths.Data);
                p.Start();
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
            }
            catch (Exception e)
            {
                Log.Write(L("  서버 실행 실패: ", "  Failed to start server: ") + e.Message);
                return false;
            }
            server = p;
            var ok = Shell.WaitUntil(5, () => Shell.PortOpen());
            Log.Write(L("  앱 소유 서버 시작 pid ", "  Started app-owned server pid ") + $"{p.Id}{(env == null ? "" : " " + string.Join(",", env.Select(kv => kv.Key + "=" + kv.Value)))} → " + (ok ? "OK" : L("포트 안 열림", "port not open")));
            return ok;
        }

        /// 페어링 등에서 쓰기 전에 앱 소유 서버를 준비한다
        public bool EnsureServer()
        {
            lock (gate)
            {
                RefreshAdb();
                if (Adb == null) return false;
                if (OwnsServer()) return true;
                StopServer();
                return StartOwnServer(null);
            }
        }

        public void Shutdown()
        {
            try
            {
                if (server != null && !server.HasExited)
                {
                    Shell.Run(Adb, "kill-server", 4000);
                    if (!server.HasExited) server.Kill();
                }
            }
            catch { }
        }
    }
}
