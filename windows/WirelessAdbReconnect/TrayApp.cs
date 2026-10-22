using System;
using System.Diagnostics;
using System.Drawing;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;
using static WirelessAdbReconnect.Lang;

namespace WirelessAdbReconnect
{
    /// 작업 표시줄 트레이에 상주: 아이콘 초록=연결됨, 빨강=끊김
    /// 아이콘 더블클릭·exe 다시 실행 → 다시 붙이기, 결과는 앱 아이콘 알림으로
    class TrayApp : ApplicationContext
    {
        readonly Reviver reviver = new Reviver();
        readonly NotifyIcon tray = new NotifyIcon();
        Icon iconOn, iconOff;   // 트레이: 회색 전파 = 연결됨, 빨강 = 끊김 (작업 표시줄 밝기에 맞춤)
        readonly SynchronizationContext ui = SynchronizationContext.Current;
        readonly ToolStripMenuItem statusItem = new ToolStripMenuItem(L("확인 중…", "Checking…")) { Enabled = false };
        readonly ToolStripMenuItem detailItem = new ToolStripMenuItem("") { Enabled = false };
        readonly ToolStripMenuItem methodItem = new ToolStripMenuItem("") { Enabled = false };
        readonly ToolStripMenuItem reviveItem = new ToolStripMenuItem(L("지금 다시 붙이기", "Reconnect now"));
        readonly ToolStripMenuItem autoItem = new ToolStripMenuItem(L("로그인할 때 자동 실행", "Launch at login")) { CheckOnClick = true };
        readonly Mirror mirror = new Mirror();
        readonly ToolStripMenuItem mirrorItem = new ToolStripMenuItem(L("화면 미러링 시작", "Start screen mirroring"));
        readonly ToolStripMenuItem mirrorOptions = new ToolStripMenuItem(L("미러링 옵션", "Mirroring options"));
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 10000 };
        bool busy, lastOk = true, dialogOpen, shownOk = true;
        bool mirrorPending;   // 다시 붙이는 중에 --mirror 가 오면 끝난 뒤 미러링

        public TrayApp(EventWaitHandle reviveSignal, EventWaitHandle mirrorSignal, bool mirrorAtStart = false)
        {
            LoadTrayIcons();
            // 작업 표시줄을 밝게/어둡게 바꾸면 아이콘 몸체 색도 바꾼다
            SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;

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
            mirrorItem.Click += (s, e) => MirrorNow();
            menu.Items.Add(mirrorItem);
            BuildMirrorOptions();
            menu.Items.Add(mirrorOptions);
            mirror.Exited += (code, byUser) => ui.Post(_ =>
            {
                // 사용자가 창을 닫거나 메뉴에서 중지한 경우는 조용히. 그 밖(연결 끊김 등)은 알림.
                if (!byUser && code != 0)
                    tray.ShowBalloonTip(8000, L("미러링이 끊겼어요", "Mirroring stopped"),
                        L("무선 연결이 끊겼을 수 있어요. '화면 미러링 시작'을 다시 누르면 먼저 다시 붙이고 미러링해요.", "Wireless debugging may have dropped. Choose 'Start screen mirroring' again to reconnect and mirror."), ToolTipIcon.None);
                Refresh();
            }, null);
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

            // 이미 실행 중일 때 exe를 다시 실행하면 → 다시 붙이기, --mirror 로 실행하면 → 미러링
            new Thread(() =>
            {
                var handles = new WaitHandle[] { reviveSignal, mirrorSignal };
                while (true)
                {
                    var i = WaitHandle.WaitAny(handles);
                    if (i == 0) ui.Post(_ => ReviveNow(), null);
                    else ui.Post(_ => MirrorNow(), null);
                }
            }) { IsBackground = true }.Start();

            if (mirrorAtStart) MirrorNow(); else ReviveNow();
        }

        // ---------- 화면 미러링 (scrcpy) ----------

        void BuildMirrorOptions()
        {
            mirrorOptions.DropDownItems.Clear();
            foreach (var (value, title) in Mirror.Qualities)
            {
                var v = value;
                var item = new ToolStripMenuItem(title) { Checked = mirror.Quality == v };
                item.Click += (s, e) => { mirror.Quality = v; BuildMirrorOptions(); };
                mirrorOptions.DropDownItems.Add(item);
            }
            mirrorOptions.DropDownItems.Add(new ToolStripSeparator());
            void Toggle(string title, Func<bool> get, Action<bool> set)
            {
                var item = new ToolStripMenuItem(title) { Checked = get() };
                item.Click += (s, e) => { set(!get()); BuildMirrorOptions(); };
                mirrorOptions.DropDownItems.Add(item);
            }
            Toggle(L("소리도 전송", "Forward audio"), () => mirror.Audio, v => mirror.Audio = v);
            Toggle(L("창을 항상 위에", "Window always on top"), () => mirror.AlwaysOnTop, v => mirror.AlwaysOnTop = v);
            Toggle(L("미러링 중 폰 화면 끄기", "Turn phone screen off"), () => mirror.TurnScreenOff, v => mirror.TurnScreenOff = v);
            Toggle(L("동영상으로 녹화 (비디오 폴더)", "Record to Videos folder"), () => mirror.Record, v => mirror.Record = v);
            mirrorOptions.DropDownItems.Add(new ToolStripSeparator());
            mirrorOptions.DropDownItems.Add(L("미러링 로그 보기", "Mirroring log"), null, (s, e) => { try { Process.Start(new ProcessStartInfo(Paths.MirrorLog) { UseShellExecute = true }); } catch { } });
            mirrorOptions.DropDownItems.Add(new ToolStripMenuItem(L("옵션은 다음 미러링부터 적용돼요", "Options apply to the next mirroring session")) { Enabled = false });
        }

        /// 미러링 시작/중지. 끊겨 있으면 먼저 다시 붙인 뒤 띄운다.
        void MirrorNow()
        {
            if (mirror.IsRunning) { mirror.Stop(); Refresh(); return; }
            if (!Mirror.IsInstalled)
            {
                tray.ShowBalloonTip(6000, L("scrcpy가 필요해요", "scrcpy is required"),
                    L("설정 창에서 '화면 미러링(scrcpy)도 설치'를 켜 주세요.", "Turn on 'Also install screen mirroring (scrcpy)' in Settings."), ToolTipIcon.None);
                ShowDialog(new SetupWindow(reviver, Installer.IsRunningInstalled, startAt: SetupWindow.Step.Install));
                return;
            }
            if (busy) { mirrorPending = true; return; }
            busy = true;
            reviveItem.Enabled = false; mirrorItem.Enabled = false;
            statusItem.Text = L("미러링 준비 중…", "Preparing mirroring…");
            detailItem.Text = L("휴대폰 연결을 확인하고 있어요", "Checking the phone connection");
            Task.Run(() =>
            {
                var d = reviver.Connected();
                string fail = null;
                if (d == null)
                {
                    Log.Write(L("미러링 전 다시 붙이기", "Reconnecting before mirroring"));
                    var r = reviver.Revive();
                    d = r.ok ? reviver.Connected() : null;
                    if (d == null) fail = r.message;
                }
                if (d != null)
                {
                    var r = mirror.Start(reviver.Adb, d.Serial, (d.Model ?? L("휴대폰", "Phone")) + " - " + AppInfo.Short);
                    if (!r.ok) fail = r.message;
                }
                return fail;
            }).ContinueWith(t =>
            {
                var fail = t.Status == TaskStatus.RanToCompletion ? t.Result : L("오류: ", "Error: ") + t.Exception?.GetBaseException().Message;
                ui.Post(_ =>
                {
                    if (fail != null) tray.ShowBalloonTip(8000, L("미러링을 시작하지 못했어요", "Couldn't start mirroring"), fail, ToolTipIcon.None);
                    busy = false;
                    reviveItem.Enabled = true; mirrorItem.Enabled = true;
                    mirrorPending = false;
                    Refresh();
                }, null);
            });
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
                    if (mirrorPending) { mirrorPending = false; MirrorNow(); }
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
                    shownOk = d != null;
                    tray.Icon = shownOk ? iconOn : iconOff;
                    statusItem.Text = d != null ? L("● 연결됨", "● Connected") : L("● 연결 안 됨", "● Disconnected");
                    detailItem.Text = d != null ? $"{d.Model ?? L("휴대폰", "Phone")} · " + L("무선", "Wireless") + (ip != null ? " · " + ip : "") + (mirror.IsRunning ? L(" · 미러링 중", " · Mirroring") : "") : L("아이콘을 더블클릭하면 다시 붙여요", "Double-click the icon to reconnect");
                    mirrorItem.Text = mirror.IsRunning ? L("화면 미러링 중지", "Stop screen mirroring") : L("화면 미러링 시작", "Start screen mirroring");
                    tray.Text = d != null ? AppInfo.Short + L(" — 연결됨", " — connected") : AppInfo.Short + L(" — 끊김 (더블클릭: 다시 붙이기)", " — disconnected (double-click to reconnect)");
                    methodItem.Text = L("마지막 성공 방법: ", "Last working fix: ") + (w.HasValue ? Reviver.Title(w.Value) : "-");
                    autoItem.Enabled = Installer.IsInstalled;
                    autoItem.Checked = Installer.AutoStart;
                }, null);
            });
        }

        void LoadTrayIcons()
        {
            var on = iconOn; var off = iconOff;
            iconOn = AppIcon.Tray(true, SystemInformation.SmallIconSize);
            iconOff = AppIcon.Tray(false, SystemInformation.SmallIconSize);
            on?.Dispose(); off?.Dispose();
        }

        void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
        {
            if (e.Category != UserPreferenceCategory.General) return;
            ui.Post(_ =>
            {
                LoadTrayIcons();
                tray.Icon = shownOk ? iconOn : iconOff;
            }, null);
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
            SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
            tray.Visible = false;
            mirror.Stop();
            reviver.Shutdown();
            ExitThread();
        }
    }
}
