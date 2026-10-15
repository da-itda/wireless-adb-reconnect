using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using WinForms = System.Windows.Forms;

namespace WirelessAdbReconnect
{
    static class Program
    {
        // 실행 방법
        //   WirelessADBReconnect.exe              설치 안 됐거나 adb가 없으면 설치 마법사, 아니면 트레이 앱
        //   WirelessADBReconnect.exe --setup      설치 마법사 강제
        //   WirelessADBReconnect.exe --uninstall  제거 (설정 > 앱에서 호출)
        //   WirelessADBReconnect.exe --diagnose   (개발용) 다시 붙이기 1회 → diagnose.txt
        //   WirelessADBReconnect.exe --install-test / --uninstall --quiet  (개발용) 창 없이 설치·제거
        //   WirelessADBReconnect.exe --snapshot <폴더>  (개발용) 화면을 PNG로 저장
        const string MutexName = @"Local\WirelessADBReconnect.Single";
        const string SignalName = @"Local\WirelessADBReconnect.Revive";

        [STAThread]
        static void Main(string[] args)
        {
            AppDomain.CurrentDomain.AssemblyResolve += ResolveEmbedded;
            WinForms.Application.EnableVisualStyles();
            WinForms.Application.SetCompatibleTextRenderingDefault(false);
            var a = args.Select(x => x.ToLowerInvariant()).ToList();

            if (a.Contains("--uninstall")) { Installer.Uninstall(a.Contains("--quiet")); return; }
            if (a.Contains("--install-test")) { Installer.Install(false, false); return; }
            if (a.Contains("--diagnose")) { Diagnose(); return; }
            InitWpf();
            if (a.Contains("--snapshot")) { Snapshot(args[a.IndexOf("--snapshot") + 1]); return; }

            using (var mutex = new Mutex(true, MutexName, out var first))
            {
                // 설치된 앱이 이미 돌고 있으면 그쪽에 "다시 붙이기"만 알리고 끝낸다
                if (!first && Installer.IsRunningInstalled && !a.Contains("--setup"))
                {
                    try { EventWaitHandle.OpenExisting(SignalName).Set(); } catch { }
                    return;
                }
                var signal = new EventWaitHandle(false, EventResetMode.AutoReset, SignalName);

                if (a.Contains("--setup") || !Installer.IsRunningInstalled || AdbLocator.Find() == null)
                {
                    var installedMode = Installer.IsRunningInstalled;
                    var reviver = new Reviver();
                    var w = new SetupWindow(reviver, installedMode);
                    w.ShowDialog();
                    reviver.Shutdown();
                    if (!installedMode)
                    {
                        if (w.LaunchInstalled && File.Exists(Paths.InstalledExe))
                        {
                            if (first) mutex.ReleaseMutex();
                            signal.Dispose();
                            Process.Start(Paths.InstalledExe);
                        }
                        return;
                    }
                    if (AdbLocator.Find() == null) return;
                }

                SynchronizationContext.SetSynchronizationContext(new WinForms.WindowsFormsSynchronizationContext());
                WinForms.Application.Run(new TrayApp(signal));
            }
        }

        /// WPF 화면용: 공통 스타일(Theme.xaml)을 앱 전체 리소스로
        static void InitWpf()
        {
            var app = new System.Windows.Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            app.Resources.MergedDictionaries.Add(new ResourceDictionary
            {
                Source = new Uri("pack://application:,,,/WirelessADBReconnect;component/Theme.xaml"),
            });
        }

        /// exe에 리소스로 넣은 DLL(QRCoder)을 불러온다 → exe 하나로 배포
        static Assembly ResolveEmbedded(object sender, ResolveEventArgs e)
        {
            var name = "deps." + new AssemblyName(e.Name).Name + ".dll";
            using (var s = typeof(Program).Assembly.GetManifestResourceStream(name))
            {
                if (s == null) return null;
                var buf = new byte[s.Length];
                s.Read(buf, 0, buf.Length);
                return Assembly.Load(buf);
            }
        }

        static void Diagnose()
        {
            var r = new Reviver();
            var (ok, message) = r.Revive();
            var devices = string.Join(", ", r.Devices().Select(d => $"{d.Serial}({d.State},{d.Model})"));
            r.Shutdown();
            File.WriteAllText(Path.Combine(Paths.Data, "diagnose.txt"), $"ok={ok}\r\n{message}\r\ndevices={devices}\r\n", Encoding.UTF8);
        }

        static void Snapshot(string dir)
        {
            Directory.CreateDirectory(dir);
            var reviver = new Reviver();
            var phone = new Device { Serial = "adb-XXXX._adb-tls-connect._tcp", State = "device", Model = "SM-F971N" };
            foreach (SetupWindow.Step step in Enum.GetValues(typeof(SetupWindow.Step)))
            {
                var w = new SetupWindow(reviver, false, step, step == SetupWindow.Step.Done ? phone : null);
                Save(w, Path.Combine(dir, $"setup-{(int)step + 1}.png"));
            }
            Save(new PairWindow(reviver), Path.Combine(dir, "pair-window.png"));
        }

        static void Save(Window w, string path)
        {
            w.WindowStartupLocation = WindowStartupLocation.Manual;
            w.Left = -5000; w.Top = -5000;
            w.ShowInTaskbar = false;
            w.ShowActivated = false;
            w.Show();
            var root = (FrameworkElement)w.Content;
            root.UpdateLayout();
            var rtb = new RenderTargetBitmap((int)Math.Ceiling(root.ActualWidth), (int)Math.Ceiling(root.ActualHeight), 96, 96, PixelFormats.Pbgra32);
            var bg = new DrawingVisual();
            using (var dc = bg.RenderOpen()) dc.DrawRectangle(Brushes.White, null, new Rect(0, 0, root.ActualWidth, root.ActualHeight));
            rtb.Render(bg);
            rtb.Render(root);
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(rtb));
            using (var f = File.Create(path)) enc.Save(f);
            w.Close();
        }
    }
}
