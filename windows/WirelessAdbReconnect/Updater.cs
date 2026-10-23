using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using WinForms = System.Windows.Forms;
using static WirelessAdbReconnect.Lang;

namespace WirelessAdbReconnect
{
    /// 앱 안 업데이트: 일주일에 한 번 GitHub 최신 릴리스를 확인하고, 메뉴에서 누르면 받아서 exe를 바꾼 뒤 다시 실행한다.
    /// 받은 exe는 SHA256SUMS.txt와 맞고, Authenticode 서명이 유효하며 게시자가 같을 때만 바꾼다.
    class Updater
    {
        const string Repo = "da-itda/wireless-adb-reconnect";
        /// 지금 exe에 서명이 없을 때(개발 빌드) 기대하는 게시자 (EV 코드 서명 CN)
        const string Publisher = "LaonCross Inc.";
        static readonly TimeSpan Week = TimeSpan.FromDays(7);

        public enum Kind { Unknown, Checking, Latest, Available, Installing }
        public Kind State { get; private set; }
        public string Latest { get; private set; }
        /// 지금 버전 (WAR_FAKE_VERSION=1.0.0 처럼 낮춰서 업데이트를 시험할 수 있다 — 개발용)
        public readonly string Current = Environment.GetEnvironmentVariable("WAR_FAKE_VERSION") is string f && f.Length > 0 ? f : AppVersion;
        public event Action Changed;

        public static string AppVersion
        {
            get { var v = typeof(Updater).Assembly.GetName().Version; return $"{v.Major}.{v.Minor}.{v.Build}"; }
        }

        public Updater()
        {
            Latest = Settings.Get("updateLatest");
            State = Latest == null ? Kind.Unknown : IsNewer(Latest, Current) ? Kind.Available : Kind.Latest;
        }

        void Set(Kind k) { State = k; Changed?.Invoke(); }

        /// "1.2.0" < "1.10.0" 처럼 숫자로 비교
        public static bool IsNewer(string a, string b)
        {
            int[] P(string s) => s.Split('.').Select(x => int.TryParse(x, out var n) ? n : 0).ToArray();
            var x1 = P(a); var y1 = P(b);
            for (var i = 0; i < Math.Max(x1.Length, y1.Length); i++)
            {
                var p = i < x1.Length ? x1[i] : 0; var q = i < y1.Length ? y1[i] : 0;
                if (p != q) return p > q;
            }
            return false;
        }

        /// 마지막 확인에서 일주일이 지났으면 확인 (실행할 때와 한 시간마다 부른다)
        public void CheckIfDue()
        {
            DateTime.TryParse(Settings.Get("updateCheckedAt"), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var last);
            if (DateTime.UtcNow - last.ToUniversalTime() >= Week) _ = Check();
        }

        /// UI 스레드에서 부른다 (await 뒤도 UI 스레드라 Changed를 바로 화면에 반영해도 된다)
        public async Task Check()
        {
            if (State == Kind.Checking || State == Kind.Installing) return;
            var before = State;
            Set(Kind.Checking);
            string latest = null;
            try { latest = await Task.Run(() => FetchLatest()); }
            catch (Exception e) { Log.Write(L("업데이트 확인 실패: ", "Update check failed: ") + e.Message); }
            if (latest == null) { Set(before == Kind.Checking ? Kind.Unknown : before); return; }
            Settings.Set("updateLatest", latest);
            Settings.Set("updateCheckedAt", DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture));
            Latest = latest;
            Log.Write(L("업데이트 확인: 지금 ", "Update check: current ") + Current + L(", 최신 ", ", latest ") + latest);
            Set(IsNewer(latest, Current) ? Kind.Available : Kind.Latest);
        }

        /// 받아서 지금 exe 자리에 넣는다. 실패하면 오류 문구, 성공하면 null (→ 부른 쪽이 새 exe를 띄우고 끝낸다)
        public async Task<string> Install()
        {
            if (State != Kind.Available) return null;
            var v = Latest;
            Set(Kind.Installing);
            try { await Task.Run(() => DownloadAndReplace(v, WinForms.Application.ExecutablePath)); return null; }
            catch (Exception e)
            {
                Log.Write(L("업데이트 실패: ", "Update failed: ") + e.Message);
                Set(Kind.Available);
                return e.Message;
            }
        }

        static WebClient Client()
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            var wc = new WebClient { Encoding = Encoding.UTF8 };
            wc.Headers[HttpRequestHeader.UserAgent] = "WirelessADBReconnect/" + AppVersion;
            return wc;
        }

        public static string FetchLatest()
        {
            using (var wc = Client())
            {
                wc.Headers[HttpRequestHeader.Accept] = "application/vnd.github+json";
                var m = Regex.Match(wc.DownloadString($"https://api.github.com/repos/{Repo}/releases/latest"), "\"tag_name\"\\s*:\\s*\"v?([^\"]+)\"");
                return m.Success ? m.Groups[1].Value : null;
            }
        }

        /// 받기 → 체크섬 → 서명 확인 → 지금 exe를 .old로 옮기고(실행 중이어도 이름은 바꿀 수 있다) 새 exe를 제자리에 (실패하면 되돌림)
        public static void DownloadAndReplace(string v, string target)
        {
            var name = $"WirelessADBReconnect-{v}-windows.exe";
            var url = $"https://github.com/{Repo}/releases/download/v{v}/";
            var dir = Path.Combine(Path.GetTempPath(), "wireless-adb-reconnect-update");
            Directory.CreateDirectory(dir);
            var exe = Path.Combine(dir, name);
            Log.Write(L("업데이트 받는 중: ", "Downloading update: ") + url + name);
            try
            {
                string sums;
                using (var wc = Client())
                {
                    wc.DownloadFile(url + name, exe);
                    sums = wc.DownloadString(url + "SHA256SUMS.txt");
                }
                string hash;
                using (var sha = SHA256.Create())
                using (var s = File.OpenRead(exe))
                    hash = BitConverter.ToString(sha.ComputeHash(s)).Replace("-", "").ToLowerInvariant();
                var line = sums.Split('\n').Select(l => l.Trim()).FirstOrDefault(l => l.EndsWith(" " + name));
                if (line == null || !line.StartsWith(hash + " "))
                    throw new Exception(L("받은 파일의 체크섬이 맞지 않아요", "Checksum of the download doesn't match"));
                var expected = SignerName(target) ?? Publisher;
                if (!SignatureValid(exe) || SignerName(exe) != expected)
                    throw new Exception(L("서명이 이 앱의 게시자가 아니에요", "The update isn't signed by this app's publisher"));

                var old = target + ".old";
                if (File.Exists(old)) File.Delete(old);
                File.Move(target, old);
                try { File.Copy(exe, target); }
                catch { File.Move(old, target); throw; }
                Log.Write(L("업데이트 설치: ", "Update installed: ") + $"{AppVersion} → {v}");
            }
            finally { try { File.Delete(exe); } catch { } }
        }

        static string SignerName(string file)
        {
            try { return new X509Certificate2(X509Certificate.CreateFromSignedFile(file)).GetNameInfo(X509NameType.SimpleName, false); }
            catch { return null; }
        }

        // ---------- Authenticode (WinVerifyTrust) ----------

        static readonly Guid GenericVerifyV2 = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct WinTrustFileInfo
        {
            public uint cbStruct;
            public string pcwszFilePath;
            public IntPtr hFile;
            public IntPtr pgKnownSubject;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct WinTrustData
        {
            public uint cbStruct;
            public IntPtr pPolicyCallbackData, pSIPClientData;
            public uint dwUIChoice, fdwRevocationChecks, dwUnionChoice;
            public IntPtr pFile;
            public uint dwStateAction;
            public IntPtr hWVTStateData, pwszURLReference;
            public uint dwProvFlags, dwUIContext;
            public IntPtr pSignatureSettings;
        }

        [DllImport("wintrust.dll", CharSet = CharSet.Unicode)]
        static extern int WinVerifyTrust(IntPtr hwnd, [MarshalAs(UnmanagedType.LPStruct)] Guid action, ref WinTrustData data);

        /// 서명이 유효한지 (창 없이, 인증서 폐기 확인은 하지 않음)
        static bool SignatureValid(string file)
        {
            var info = new WinTrustFileInfo { cbStruct = (uint)Marshal.SizeOf<WinTrustFileInfo>(), pcwszFilePath = file };
            var pInfo = Marshal.AllocHGlobal(Marshal.SizeOf<WinTrustFileInfo>());
            try
            {
                Marshal.StructureToPtr(info, pInfo, false);
                var data = new WinTrustData
                {
                    cbStruct = (uint)Marshal.SizeOf<WinTrustData>(),
                    dwUIChoice = 2,          // WTD_UI_NONE
                    fdwRevocationChecks = 0, // WTD_REVOKE_NONE
                    dwUnionChoice = 1,       // WTD_CHOICE_FILE
                    pFile = pInfo,
                    dwStateAction = 1,       // WTD_STATEACTION_VERIFY
                };
                var r = WinVerifyTrust(IntPtr.Zero, GenericVerifyV2, ref data);
                data.dwStateAction = 2;      // WTD_STATEACTION_CLOSE
                WinVerifyTrust(IntPtr.Zero, GenericVerifyV2, ref data);
                return r == 0;
            }
            finally
            {
                Marshal.DestroyStructure<WinTrustFileInfo>(pInfo);
                Marshal.FreeHGlobal(pInfo);
            }
        }
    }
}
