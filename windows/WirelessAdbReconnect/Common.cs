using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using Microsoft.Win32;

namespace WirelessAdbReconnect
{
    static class AppInfo
    {
        public const string Name = "Wireless ADB Reconnect";
        public const string Short = "ADB Reconnect";
        public const string Korean = "무선 ADB 자동 재연결";
        public const string Exe = "WirelessADBReconnect";
    }

    /// 화면 언어: 한국어·일본어·중국어(간체·번체), 그 밖의 언어는 모두 영어 (WAR_LANG=ko|en|ja|zh-Hans|zh-Hant 로 강제 — 스냅샷용)
    static class Lang
    {
        public static readonly string Code = Detect();
        public static readonly bool Korean = Code == "ko";
        /// 일본어·중국어 문구: exe에 넣은 assets/i18n/<lang>.strings (영어 문구가 키)
        static readonly Dictionary<string, string> Table = Load(Code);

        static string Detect()
        {
            if (Environment.GetEnvironmentVariable("WAR_LANG") is string forced && forced.Length > 0) return forced;
            var c = System.Globalization.CultureInfo.CurrentUICulture;
            switch (c.TwoLetterISOLanguageName)
            {
                case "ko": return "ko";
                case "ja": return "ja";
                case "zh":
                    // zh-TW·zh-HK·zh-MO·zh-Hant → 번체, 그 밖(zh-CN·zh-SG·zh-Hans) → 간체
                    for (var x = c; x != null && x.Name.Length > 0; x = x.Parent)
                        if (x.Name == "zh-Hant" || x.Name == "zh-CHT" || x.Name == "zh-TW" || x.Name == "zh-HK" || x.Name == "zh-MO") return "zh-Hant";
                    return "zh-Hans";
                default: return "en";
            }
        }

        static Dictionary<string, string> Load(string code)
        {
            var table = new Dictionary<string, string>();
            using (var s = typeof(Lang).Assembly.GetManifestResourceStream("i18n." + code + ".strings"))
            {
                if (s == null) return table;
                var lit = "\"((?:[^\"\\\\]|\\\\.)*)\"";
                foreach (System.Text.RegularExpressions.Match m in System.Text.RegularExpressions.Regex.Matches(
                    new StreamReader(s, Encoding.UTF8).ReadToEnd(), "^" + lit + "\\s*=\\s*" + lit + "\\s*;", System.Text.RegularExpressions.RegexOptions.Multiline))
                    table[Unescape(m.Groups[1].Value)] = Unescape(m.Groups[2].Value);
            }
            return table;
        }

        static string Unescape(string s) =>
            System.Text.RegularExpressions.Regex.Replace(s, "\\\\(.)", m => m.Groups[1].Value == "n" ? "\n" : m.Groups[1].Value == "t" ? "\t" : m.Groups[1].Value);

        /// 한국어는 ko, 일본어·중국어는 영어 문구로 번역을 찾고(없으면 영어), 그 밖은 en. {0} {1} … 자리에 args를 넣는다
        public static string L(string ko, string en, params object[] args)
        {
            var s = Korean ? ko : Table.TryGetValue(en, out var t) ? t : en;
            return args.Length > 0 ? string.Format(s, args) : s;
        }

        /// 언어에 맞는 글꼴 (한자는 언어마다 모양이 달라서 일본어·중국어에 한국어 글꼴을 쓰면 안 된다)
        public static string Font(bool wpf)
        {
            switch (Code)
            {
                case "ko": return wpf ? "Malgun Gothic, Segoe UI" : "Malgun Gothic";
                case "ja": return wpf ? "Yu Gothic UI, Meiryo UI, Segoe UI" : "Yu Gothic UI";
                case "zh-Hans": return wpf ? "Microsoft YaHei UI, Segoe UI" : "Microsoft YaHei UI";
                case "zh-Hant": return wpf ? "Microsoft JhengHei UI, Segoe UI" : "Microsoft JhengHei UI";
                default: return wpf ? "Segoe UI, Malgun Gothic" : "Segoe UI";
            }
        }
    }

    /// XAML에서 언어별 문구: Text="{local:T Ko='한국어', En='English'}" (일본어·중국어는 En으로 번역을 찾는다)
    public class T : System.Windows.Markup.MarkupExtension
    {
        public string Ko { get; set; } = "";
        public string En { get; set; } = "";
        public override object ProvideValue(IServiceProvider sp) => Lang.L(Ko, En);
    }

    /// "… **굵게** …" 문장을 TextBlock에: <TextBlock local:Md.Text="{local:T …}"/> (언어마다 굵은 부분의 자리가 달라서 문장 하나로 번역한다)
    public static class Md
    {
        public static readonly System.Windows.DependencyProperty TextProperty = System.Windows.DependencyProperty.RegisterAttached(
            "Text", typeof(string), typeof(Md), new System.Windows.PropertyMetadata(null, (d, e) =>
            {
                var tb = (System.Windows.Controls.TextBlock)d;
                tb.Inlines.Clear();
                var parts = ((string)e.NewValue ?? "").Split(new[] { "**" }, StringSplitOptions.None);
                for (var i = 0; i < parts.Length; i++)
                    if (parts[i].Length > 0)
                        tb.Inlines.Add(i % 2 == 1 ? new System.Windows.Documents.Bold(new System.Windows.Documents.Run(parts[i])) : (System.Windows.Documents.Inline)new System.Windows.Documents.Run(parts[i]));
            }));
        public static void SetText(System.Windows.DependencyObject d, string v) => d.SetValue(TextProperty, v);
        public static string GetText(System.Windows.DependencyObject d) => (string)d.GetValue(TextProperty);
    }

    static class Paths
    {
        static readonly string LocalAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        public static readonly string Data = Path.Combine(LocalAppData, AppInfo.Name);
        public static readonly string Log = Path.Combine(Data, "adb-revive.log");
        public static readonly string ServerLog = Path.Combine(Data, "adb-server.log");
        public static readonly string Settings = Path.Combine(Data, "settings.txt");
        public static readonly string PlatformTools = Path.Combine(Data, "platform-tools");
        public static readonly string Scrcpy = Path.Combine(Data, "scrcpy");
        public static readonly string MirrorLog = Path.Combine(Data, "mirror.log");
        public static readonly string InstallDir = Path.Combine(LocalAppData, "Programs", AppInfo.Name);
        public static readonly string InstalledExe = Path.Combine(InstallDir, AppInfo.Exe + ".exe");
        public static readonly string SdkAdb = Path.Combine(LocalAppData, @"Android\Sdk\platform-tools\adb.exe");
    }

    static class Log
    {
        static readonly object Gate = new object();

        public static void Write(string msg)
        {
            lock (Gate)
            {
                try
                {
                    Directory.CreateDirectory(Paths.Data);
                    File.AppendAllText(Paths.Log, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {msg}\r\n", Encoding.UTF8);
                }
                catch { }
            }
        }
    }

    /// key=value 줄로 저장하는 작은 설정 파일
    static class Settings
    {
        static readonly object Gate = new object();

        static Dictionary<string, string> Load()
        {
            var d = new Dictionary<string, string>();
            try
            {
                foreach (var line in File.ReadAllLines(Paths.Settings, Encoding.UTF8))
                {
                    var i = line.IndexOf('=');
                    if (i > 0) d[line.Substring(0, i)] = line.Substring(i + 1);
                }
            }
            catch { }
            return d;
        }

        public static string Get(string key)
        {
            lock (Gate) return Load().TryGetValue(key, out var v) && v.Length > 0 ? v : null;
        }

        public static void Set(string key, string value)
        {
            lock (Gate)
            {
                var d = Load();
                d[key] = value ?? "";
                Directory.CreateDirectory(Paths.Data);
                File.WriteAllLines(Paths.Settings, d.Select(kv => kv.Key + "=" + kv.Value), Encoding.UTF8);
            }
        }
    }

    static class Shell
    {
        /// 명령을 실행하고 출력(표준 출력+오류)을 돌려준다. 시간이 넘으면 종료하고 code=-2.
        public static (int code, string output) Run(string exe, string args, int timeoutMs = 15000,
                                                    IDictionary<string, string> env = null)
        {
            var psi = new ProcessStartInfo(exe, args)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            if (env != null) foreach (var kv in env) psi.EnvironmentVariables[kv.Key] = kv.Value;
            var sb = new StringBuilder();
            try
            {
                using (var p = new Process { StartInfo = psi })
                {
                    p.OutputDataReceived += (s, e) => { if (e.Data != null) lock (sb) sb.AppendLine(e.Data); };
                    p.ErrorDataReceived += (s, e) => { if (e.Data != null) lock (sb) sb.AppendLine(e.Data); };
                    p.Start();
                    p.BeginOutputReadLine();
                    p.BeginErrorReadLine();
                    if (!p.WaitForExit(timeoutMs))
                    {
                        try { p.Kill(); } catch { }
                        lock (sb) return (-2, sb.ToString().Trim());
                    }
                    Thread.Sleep(50);   // 비동기 출력이 마저 들어오게 (데몬이 파이프를 잡고 있어도 막히지 않게 무한 대기는 안 함)
                    lock (sb) return (p.ExitCode, sb.ToString().Trim());
                }
            }
            catch (Exception e)
            {
                return (-1, e.Message);
            }
        }

        public static bool PortOpen(int port = 5037)
        {
            try
            {
                using (var c = new TcpClient())
                {
                    var t = c.ConnectAsync("127.0.0.1", port);
                    return t.Wait(400) && c.Connected;
                }
            }
            catch { return false; }
        }

        public static bool TcpReachable(string hostPort, int timeoutMs = 2500)
        {
            try
            {
                var i = hostPort.LastIndexOf(':');
                using (var c = new TcpClient())
                {
                    var t = c.ConnectAsync(hostPort.Substring(0, i), int.Parse(hostPort.Substring(i + 1)));
                    return t.Wait(timeoutMs) && c.Connected;
                }
            }
            catch { return false; }
        }

        public static bool WaitUntil(int seconds, Func<bool> cond)
        {
            for (var i = 0; i < seconds; i++)
            {
                if (cond()) return true;
                Thread.Sleep(1000);
            }
            return cond();
        }
    }

    static class AppIcon
    {
        /// app.ico = 앱 아이콘(녹색 심볼)
        public static Icon Load(Size? size = null) => Load("app.ico", size);

        /// 트레이: 전파가 회색 = 연결됨, 빨강 = 끊김 (초록은 작업 표시줄에서 잘 안 보여서).
        /// 몸체는 작업 표시줄 밝기에 맞춰 검정(light) / 흰색(dark) — tray-{ok,fail}-{light,dark}.ico
        public static Icon Tray(bool ok, Size size) => Load($"tray-{(ok ? "ok" : "fail")}-{(LightTaskbar ? "light" : "dark")}.ico", size);

        /// 작업 표시줄이 밝은 테마인지 (값이 없으면 어두움 — 예전 Windows 10 기본)
        public static bool LightTaskbar
        {
            get
            {
                try
                {
                    using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                        return k?.GetValue("SystemUsesLightTheme") is int v && v == 1;
                }
                catch { return false; }
            }
        }

        static Icon Load(string name, Size? size)
        {
            using (var s = typeof(AppIcon).Assembly.GetManifestResourceStream(name))
                return size.HasValue ? new Icon(s, size.Value) : new Icon(s);
        }

        public static Bitmap Image(int px)
        {
            using (var ico = Load(new Size(256, 256)))
                return new Bitmap(ico.ToBitmap(), px, px);
        }
    }

    static class Ui
    {
        static readonly string Face = Lang.Font(wpf: false);
        public static readonly Font Font = new Font(Face, 9.5f);
        public static readonly Font Bold = new Font(Face, 9.5f, FontStyle.Bold);
        public static readonly Font Title = new Font(Face, 15f, FontStyle.Bold);
        public static readonly Color Green = Color.FromArgb(0x1E, 0x9E, 0x5A);
        public static readonly Color Muted = Color.FromArgb(0x60, 0x66, 0x70);
    }
}
