using System;
using System.Diagnostics;
using System.Drawing;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using static WirelessAdbReconnect.Lang;

namespace WirelessAdbReconnect
{
    /// 작업 표시줄 트레이에 상주: 아이콘 초록=연결됨, 빨강=끊김
    /// 아이콘 더블클릭·exe 다시 실행 → 다시 붙이기, 결과는 앱 아이콘 알림으로
    class TrayApp : ApplicationContext
    {
        readonly Reviver reviver = new Reviver();
        readonly NotifyIcon tray = new NotifyIcon();
        readonly Icon iconOn, iconOff;
        readonly SynchronizationContext ui = SynchronizationContext.Current;
        readonly ToolStripMenuItem statusItem = new ToolStripMenuItem(L("확인 중…", "Checking…")) { Enabled = false };
        readonly ToolStripMenuItem detailItem = new ToolStripMenuItem("") { Enabled = false };
        readonly ToolStripMenuItem methodItem = new ToolStripMenuItem("") { Enabled = false };
        readonly ToolStripMenuItem reviveItem = new ToolStripMenuItem(L("지금 다시 붙이기", "Reconnect now"));
        readonly ToolStripMenuItem autoItem = new ToolStripMenuItem(L("로그인할 때 자동 실행", "Launch at login")) { CheckOnClick = true };
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 10000 };
        bool busy, lastOk = true, dialogOpen;

        public TrayApp(EventWaitHandle reviveSignal)
        {
            iconOn = AppIcon.Load(SystemInformation.SmallIconSize);
            iconOff = AppIcon.Load(SystemInformation.SmallIconSize, red: true);

            statusItem.Font = new Font(Ui.Font, FontStyle.Bold);
            statusItem.Image = AppIcon.Image(32);
            reviveItem.Font = new Font(Ui.Font, FontStyle.Bold);
            reviveItem.ShortcutKeyDisplayString = L("더블클릭", "Double-click");
            reviveItem.Click += (s, e) => ReviveNow();
            autoItem.Checked = Installer.AutoStart;
            autoItem.Enabled = Installer.IsInstalled;
            autoItem.CheckedChanged += (s, e) => Installer.AutoStart = autoItem.Checked;

            var menu = new ContextMenuStrip { Font = Ui.Font, ShowImageMargin = true };
            menu.Items.Add(statusItem);
            menu.Items.Add(detailItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(reviveItem);
            menu.Items.Add(L("휴대폰 페어링…", "Pair phone…"), null, (s, e) => ShowDialog(new PairWindow(reviver)));
            menu.Items.Add(L("진단 보기", "Diagnostics"), null, (s, e) => OpenLog());
            menu.Items.Add(methodItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(autoItem);
            menu.Items.Add(L("설정…", "Settings…"), null, (s, e) => ShowDialog(new SetupWindow(reviver, Installer.IsRunningInstalled)));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(L("종료 (adb 서버도 종료)", "Quit (stops adb server)"), null, (s, e) => Quit());

            tray.Icon = iconOn;
            tray.Text = AppInfo.Short;
            tray.ContextMenuStrip = menu;
            tray.Visible = true;
            tray.DoubleClick += (s, e) => ReviveNow();
            tray.MouseUp += (s, e) =>
            {
                // 왼쪽 클릭에도 메뉴를 연다 (NotifyIcon의 비공개 메서드)
                if (e.Button == MouseButtons.Left)
                    typeof(NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic)?.Invoke(tray, null);
            };
            tray.BalloonTipClicked += (s, e) => { if (!lastOk) OpenLog(); };

            timer.Tick += (s, e) => Refresh();
            timer.Start();

            // 이미 실행 중일 때 exe를 다시 실행하면 → 다시 붙이기
            new Thread(() =>
            {
                while (true)
                {
                    reviveSignal.WaitOne();
                    ui.Post(_ => ReviveNow(), null);
                }
            }) { IsBackground = true }.Start();

            ReviveNow();
        }

        void ReviveNow()
        {
            if (busy) return;
            busy = true;
            reviveItem.Enabled = false;
            statusItem.Text = L("다시 붙이는 중…", "Reconnecting…");
            detailItem.Text = L("원인을 찾고 순서대로 시도하고 있어요", "Finding the cause and trying fixes");
            tray.Text = AppInfo.Short + L(" — 다시 붙이는 중…", " — reconnecting…");
            var started = DateTime.Now;
            Task.Run(() =>
            {
                var r = reviver.Revive();
                return (r.ok, r.message, device: reviver.Connected());
            }).ContinueWith(t =>
            {
                var ok = t.Status == TaskStatus.RanToCompletion && t.Result.ok;
                var message = t.Status == TaskStatus.RanToCompletion ? t.Result.message : L("오류: ", "Error: ") + t.Exception?.GetBaseException().Message;
                var d = t.Status == TaskStatus.RanToCompletion ? t.Result.device : null;
                var secs = Math.Max(1, (int)Math.Round((DateTime.Now - started).TotalSeconds));
                ui.Post(_ =>
                {
                    lastOk = ok;
                    if (ok) tray.ShowBalloonTip(5000, L("다시 연결됐어요", "Reconnected"), $"{d?.Model ?? d?.Serial ?? L("휴대폰", "Phone")} · " + L($"{secs}초 걸렸어요", $"took {secs}s"), ToolTipIcon.None);
                    else tray.ShowBalloonTip(8000, L("연결하지 못했어요", "Couldn't reconnect"), message, ToolTipIcon.None);
                    busy = false;
                    reviveItem.Enabled = true;
                    Refresh();
                }, null);
            });
        }

        void Refresh()
        {
            if (busy) return;
            Task.Run(() => reviver.Connected()).ContinueWith(t =>
            {
                var d = t.Status == TaskStatus.RanToCompletion ? t.Result : null;
                var w = reviver.Winner;
                var ip = reviver.LastAddr?.Split(':')[0];
                ui.Post(_ =>
                {
                    if (busy) return;
                    tray.Icon = d != null ? iconOn : iconOff;
                    statusItem.Text = d != null ? L("● 연결됨", "● Connected") : L("● 연결 안 됨", "● Disconnected");
                    detailItem.Text = d != null ? $"{d.Model ?? L("휴대폰", "Phone")} · " + L("무선", "Wireless") + (ip != null ? " · " + ip : "") : L("아이콘을 더블클릭하면 다시 붙여요", "Double-click the icon to reconnect");
                    tray.Text = d != null ? AppInfo.Short + L(" — 연결됨", " — connected") : AppInfo.Short + L(" — 끊김 (더블클릭: 다시 붙이기)", " — disconnected (double-click to reconnect)");
                    methodItem.Text = L("마지막 성공 방법: ", "Last working fix: ") + (w.HasValue ? Reviver.Title(w.Value) : "-");
                    autoItem.Enabled = Installer.IsInstalled;
                    autoItem.Checked = Installer.AutoStart;
                }, null);
            });
        }

        void ShowDialog(System.Windows.Window w)
        {
            if (dialogOpen) return;
            dialogOpen = true;
            try { w.ShowDialog(); } finally { dialogOpen = false; Refresh(); }
        }

        static void OpenLog()
        {
            try { Process.Start(new ProcessStartInfo(Paths.Log) { UseShellExecute = true }); } catch { }
        }

        void Quit()
        {
            timer.Stop();
            tray.Visible = false;
            reviver.Shutdown();
            ExitThread();
        }
    }
}
