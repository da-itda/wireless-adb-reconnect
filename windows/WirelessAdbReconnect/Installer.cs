using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Threading.Tasks;
using Microsoft.Win32;
using WinForms = System.Windows.Forms;
using static WirelessAdbReconnect.Lang;

namespace WirelessAdbReconnect
{
    static class Installer
    {
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string UninstallRoot = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\";
        const string UninstallKey = UninstallRoot + AppInfo.Exe;
        const string PlatformToolsUrl = "https://dl.google.com/android/repository/platform-tools-latest-windows.zip";
        const string StudioPage = "https://developer.android.com/studio";

        static string StartMenuLink => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), AppInfo.Name + ".lnk");
        static string DesktopLink => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), AppInfo.Name + ".lnk");

        public static bool IsRunningInstalled =>
            string.Equals(Path.GetFullPath(WinForms.Application.ExecutablePath), Path.GetFullPath(Paths.InstalledExe), StringComparison.OrdinalIgnoreCase);

        public static bool IsInstalled => File.Exists(Paths.InstalledExe);

        public static bool HasDesktopShortcut => File.Exists(DesktopLink);

        // ---------- 앱 설치 / 제거 ----------

        public static void Install(bool autoStart, bool desktopShortcut)
        {
            RemoveOldAdbRevive();
            Directory.CreateDirectory(Paths.InstallDir);
            if (!IsRunningInstalled)
            {
                StopOtherInstances();
                File.Copy(WinForms.Application.ExecutablePath, Paths.InstalledExe, true);
            }
            CreateShortcut(StartMenuLink);
            DesktopShortcut = desktopShortcut;
            AutoStart = autoStart;
            using (var k = Registry.CurrentUser.CreateSubKey(UninstallKey))
            {
                k.SetValue("DisplayName", AppInfo.Name);
                k.SetValue("DisplayIcon", Paths.InstalledExe);
                k.SetValue("DisplayVersion", WinForms.Application.ProductVersion);
                k.SetValue("Publisher", AppInfo.Name);
                k.SetValue("InstallLocation", Paths.InstallDir);
                k.SetValue("UninstallString", $"\"{Paths.InstalledExe}\" --uninstall");
                k.SetValue("NoModify", 1);
                k.SetValue("NoRepair", 1);
            }
            Log.Write(L("설치 완료: ", "Installed: ") + Paths.InstalledExe);
        }

        /// 업데이트 뒤 '설정 > 앱'에 보이는 버전을 맞춘다
        public static void RecordVersion()
        {
            if (!IsRunningInstalled) return;
            using (var k = Registry.CurrentUser.OpenSubKey(UninstallKey, true)) k?.SetValue("DisplayVersion", Updater.AppVersion);
        }

        public static void Uninstall(bool quiet = false)
        {
            if (!quiet && WinForms.MessageBox.Show(L("{0}를 제거할까요?\n(설치한 adb와 기록은 남겨 둡니다)", "Uninstall {0}?\n(adb and logs are kept)", AppInfo.Name), AppInfo.Name,
                    WinForms.MessageBoxButtons.OKCancel, WinForms.MessageBoxIcon.Question) != WinForms.DialogResult.OK) return;
            StopOtherInstances();
            AutoStart = false;
            foreach (var l in new[] { StartMenuLink, DesktopLink }) try { File.Delete(l); } catch { }
            try { Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false); } catch { }
            // 실행 중인 자기 자신은 지울 수 없으니 잠시 뒤 cmd가 폴더를 지운다
            Process.Start(new ProcessStartInfo("cmd.exe", $"/c timeout /t 2 /nobreak >nul & rmdir /s /q \"{Paths.InstallDir}\"")
            { CreateNoWindow = true, UseShellExecute = false });
            Log.Write(L("제거 완료", "Uninstalled"));
            if (!quiet) WinForms.MessageBox.Show(L("제거했습니다.", "Uninstalled."), AppInfo.Name);
        }

        /// 옛 이름(ADB Revive)으로 설치된 것을 정리한다: 프로세스·자동 실행·바로가기·제거 항목·폴더
        static void RemoveOldAdbRevive()
        {
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var oldDir = Path.Combine(local, "Programs", "ADB Revive");
            using (var run = Registry.CurrentUser.OpenSubKey(RunKey, true)) run?.DeleteValue("ADB Revive", false);
            if (!Directory.Exists(oldDir) && Registry.CurrentUser.OpenSubKey(UninstallRoot + "ADBRevive") == null) return;
            foreach (var p in Process.GetProcessesByName("ADBRevive")) try { p.Kill(); p.WaitForExit(3000); } catch { }
            foreach (var l in new[] {
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "ADB Revive.lnk"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "ADB Revive.lnk") })
                try { File.Delete(l); } catch { }
            try { Registry.CurrentUser.DeleteSubKeyTree(UninstallRoot + "ADBRevive", false); } catch { }
            try { Directory.Delete(oldDir, true); } catch { }
            Log.Write(L("옛 ADB Revive 정리", "Removed old ADB Revive"));
        }

        public static bool AutoStart
        {
            get { using (var k = Registry.CurrentUser.OpenSubKey(RunKey)) return k?.GetValue(AppInfo.Name) != null; }
            set
            {
                using (var k = Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    if (value) k.SetValue(AppInfo.Name, $"\"{Paths.InstalledExe}\"");
                    else k.DeleteValue(AppInfo.Name, false);
                }
            }
        }

        public static bool DesktopShortcut
        {
            get => File.Exists(DesktopLink);
            set
            {
                if (value) CreateShortcut(DesktopLink);
                else try { File.Delete(DesktopLink); } catch { }
            }
        }

        static void StopOtherInstances()
        {
            foreach (var p in Process.GetProcessesByName(AppInfo.Exe))
            {
                if (p.Id == Process.GetCurrentProcess().Id) continue;
                try { p.Kill(); p.WaitForExit(3000); } catch { }
            }
        }

        static void CreateShortcut(string lnk)
        {
            dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
            dynamic sc = shell.CreateShortcut(lnk);
            sc.TargetPath = Paths.InstalledExe;
            sc.WorkingDirectory = Paths.InstallDir;
            sc.IconLocation = Paths.InstalledExe + ",0";
            sc.Description = L(AppInfo.Korean + " — 무선 디버깅이 끊기면 다시 붙여 줍니다", "Auto-reconnect wireless debugging (ADB over Wi-Fi)");
            sc.Save();
        }

        // ---------- adb / Android Studio 설치 ----------

        /// Google 공식 platform-tools(약 15MB)를 받아 %LOCALAPPDATA%\<앱>\platform-tools 에 푼다
        public static async Task InstallPlatformTools(IProgress<int> progress)
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            var zip = Path.Combine(Path.GetTempPath(), "wireless-adb-reconnect-platform-tools.zip");
            var tmp = Path.Combine(Paths.Data, "platform-tools-new");
            using (var wc = new WebClient())
            {
                wc.DownloadProgressChanged += (s, e) => progress.Report(e.ProgressPercentage);
                await wc.DownloadFileTaskAsync(new Uri(PlatformToolsUrl), zip);
            }
            await Task.Run(() =>
            {
                if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
                ZipFile.ExtractToDirectory(zip, tmp);
                var old = Path.Combine(Paths.PlatformTools, "adb.exe");
                if (File.Exists(old)) Shell.Run(old, "kill-server", 5000);
                if (Directory.Exists(Paths.PlatformTools)) Directory.Delete(Paths.PlatformTools, true);
                Directory.Move(Path.Combine(tmp, "platform-tools"), Paths.PlatformTools);
                Directory.Delete(tmp, true);
                File.Delete(zip);
            });
            Log.Write(L("adb 설치 완료: ", "adb installed: ") + Paths.PlatformTools);
        }

        /// winget이 있으면 winget으로, 없으면 다운로드 페이지를 연다
        public static bool InstallAndroidStudio()
        {
            if (Shell.Run("where", "winget", 5000).code == 0)
            {
                Process.Start(new ProcessStartInfo("cmd.exe",
                    "/k winget install -e --id Google.AndroidStudio --accept-package-agreements --accept-source-agreements && echo. && echo " + L("설치가 끝나면 Android Studio를 한 번 실행해 설정 마법사를 마치세요 (그때 adb가 설치됩니다).", "When done, open Android Studio once and finish the setup wizard (that installs adb)."))
                { UseShellExecute = true });
                return true;
            }
            Process.Start(new ProcessStartInfo(StudioPage) { UseShellExecute = true });
            return false;
        }
    }
}
