using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using static WirelessAdbReconnect.Lang;

namespace WirelessAdbReconnect
{
    /// 설치 마법사: ① adb 준비 → ② 앱 설치 → ③ 휴대폰 페어링 → ④ 완료
    /// 이미 된 단계(adb 있음, 설치됨, 이미 연결됨)는 L("건너뜀", "Skipped")으로 표시하고 넘어간다.
    public partial class SetupWindow : Window
    {
        internal enum Step { Adb, Install, Pair, Done }
        static readonly (Step step, string title)[] Steps =
            { (Step.Adb, L("adb 준비", "Get adb")), (Step.Install, L("앱 설치", "Install")), (Step.Pair, L("휴대폰 페어링", "Pair phone")), (Step.Done, L("완료", "Done")) };

        readonly Reviver reviver;
        readonly bool installedMode;
        readonly HashSet<Step> skipped = new HashSet<Step>();
        Step step;
        bool busy;
        string previewIP;   // 스냅샷에서는 예시 주소

        /// 완료 후 설치된 앱(트레이)을 실행할지
        public bool LaunchInstalled { get; private set; }

        internal SetupWindow(Reviver reviver, bool installedMode, Step? preview = null, Device previewDevice = null, Step? startAt = null)
        {
            InitializeComponent();
            // 간체 글꼴(Microsoft YaHei UI)은 줄 간격이 넓어 ② 설치 단계 카드가 버튼에 닿는다 → 창을 조금 키움
            if (Lang.Code == "zh-Hans") Root.Height += 24;
            this.reviver = reviver;
            this.installedMode = installedMode;
            Title = AppInfo.Name + L(" 설정", " Settings");
            Icon = Icons.Window();
            SideIcon.Source = Icons.Large();
            Pair.Attach(reviver);
            Pair.Paired += () => Task.Delay(800).ContinueWith(_ => Dispatcher.BeginInvoke((Action)(() => Go(Step.Done))));
            Closed += (s, e) => Pair.Stop();

            if (preview.HasValue) previewIP = "192.168.0.10";
            var connected = preview.HasValue ? previewDevice : reviver.Connected();
            if (reviver.Adb != null && preview != Step.Adb) skipped.Add(Step.Adb);
            // 설치 단계: 이미 설치됐어도 scrcpy가 없고 아직 묻지 않았으면 보여 준다 ('미러링도 설치' 스위치)
            if (installedMode && (Mirror.IsInstalled || Mirror.Declined) && startAt != Step.Install) skipped.Add(Step.Install);
            if (connected != null) skipped.Add(Step.Pair);

            InstallWhere.Text = installedMode ? L("내 프로그램 폴더 · 이미 설치됨", "Programs folder · already installed") : L("내 프로그램 폴더 (AppData\\Local\\Programs)", "Programs folder (AppData\\Local\\Programs)");
            AutoStart.IsChecked = !installedMode || Installer.AutoStart;
            Desktop.IsChecked = !installedMode || Installer.DesktopShortcut;
            var hasScrcpy = preview == null && Mirror.IsInstalled;
            MirrorToggle.IsChecked = hasScrcpy || !Mirror.Declined;
            MirrorToggle.IsEnabled = !hasScrcpy;
            if (hasScrcpy) MirrorDetail.Text = L("이미 설치됨 · 트레이 메뉴 '화면 미러링 시작하기'", "Already installed · tray menu 'Start screen mirroring'");
            ChoiceAdb.Checked += (s, e) => Render();
            ChoiceStudio.Checked += (s, e) => Render();

            step = preview ?? startAt ?? new[] { Step.Adb, Step.Install, Step.Pair }.FirstOrDefault(x => !skipped.Contains(x));
            if (preview == null && skipped.Contains(step)) step = Step.Done;
            if (step == Step.Done) ShowDone(connected);
            Render();
        }

        // ---------- 이동 ----------

        void Go(Step s)
        {
            step = s;
            if (s == Step.Done) Task.Run(() => reviver.Connected()).ContinueWith(t => Dispatcher.BeginInvoke((Action)(() => ShowDone(t.Result))));
            Render();
        }

        void Next()
        {
            var i = (int)step + 1;
            while (i < (int)Step.Done && skipped.Contains((Step)i)) i++;
            Go((Step)Math.Min(i, (int)Step.Done));
        }

        bool CanGoBack => Enumerable.Range(0, (int)step).Any(i => !skipped.Contains((Step)i));

        void Back()
        {
            var i = (int)step - 1;
            while (i > 0 && skipped.Contains((Step)i)) i--;
            if (i >= 0) Go((Step)i);
        }

        // ---------- 화면 ----------

        void Render()
        {
            RenderSteps();
            AdbPanel.Visibility = Vis(step == Step.Adb);
            InstallPanel.Visibility = Vis(step == Step.Install);
            Pair.Visibility = Vis(step == Step.Pair);
            DonePanel.Visibility = Vis(step == Step.Done);
            Header.Visibility = Vis(step != Step.Done);
            SkipBtn.Visibility = Vis(step == Step.Pair);
            RightBtn.Visibility = Vis(step != Step.Pair);
            LeftBtn.Foreground = (Brush)FindResource(step == Step.Pair ? "BrandText" : "Muted");
            Desc.Visibility = Vis(step != Step.Pair);

            switch (step)
            {
                case Step.Adb:
                    Header3(L("1 / 3단계", "Step 1 of 3"), L("adb를 준비할게요", "Let's get adb"), L("이 PC에서 adb를 찾지 못했어요. 앱에 필요한 건 adb뿐이라 가벼운 설치를 추천해요.", "adb wasn't found on this PC. The app only needs adb, so the lightweight install is recommended."));
                    LeftBtn.Content = L("이미 설치했어요 · 다시 확인", "Already installed · Check again");
                    LeftBtn.Visibility = Visibility.Visible;
                    RightBtn.Content = ChoiceStudio.IsChecked == true ? L("Android Studio 설치", "Install Android Studio") : L("설치하고 계속", "Install & continue");
                    RightBtn.IsEnabled = !busy;
                    break;
                case Step.Install:
                    Header3(L("2 / 3단계", "Step 2 of 3"), installedMode ? L("설치되어 있어요", "Installed") : L("앱을 설치할게요", "Install the app"),
                        installedMode ? L("자동 실행·바로가기를 바꾸거나, 화면 미러링(scrcpy)을 추가로 설치할 수 있어요.", "Change launch at login and the shortcut, or add screen mirroring (scrcpy).")
                                      : L("설치하면 작업 표시줄 트레이에 머물면서 무선 연결이 끊기면 바로 다시 붙여요.", "It stays in the system tray and reconnects as soon as wireless debugging drops."));
                    LeftBtn.Content = L("이전", "Back");
                    LeftBtn.Visibility = Vis(CanGoBack && !busy);
                    RightBtn.Content = installedMode && Mirror.IsInstalled ? L("계속", "Continue") : L("설치하고 계속", "Install & continue");
                    RightBtn.IsEnabled = !busy;
                    break;
                case Step.Pair:
                    Header3(L("3 / 3단계 · 처음 한 번만", "Step 3 of 3 · first time only"), L("휴대폰으로 QR을 찍어 주세요", "Scan the QR with your phone"), null);
                    LeftBtn.Content = Pair.CodeMode ? L("QR로 하기", "Use QR code") : L("QR 대신 페어링 코드로 하기", "Use a pairing code instead");
                    LeftBtn.Visibility = Visibility.Visible;
                    if (previewIP != null) break;   // 스냅샷: 페어링(adb 서버)을 시작하지 않음
                    if (IsVisible) Pair.Start(); else Loaded += (s, e) => { if (step == Step.Pair) Pair.Start(); };
                    break;
                case Step.Done:
                    LeftBtn.Visibility = Visibility.Collapsed;
                    RightBtn.Content = L("완료", "Done");
                    RightBtn.IsEnabled = true;
                    break;
            }
        }

        void Header3(string eyebrow, string title, string desc)
        {
            Eyebrow.Text = eyebrow;
            Title1.Text = title;
            Desc.Text = desc ?? "";
        }

        static Visibility Vis(bool v) => v ? Visibility.Visible : Visibility.Collapsed;

        void RenderSteps()
        {
            StepList.Children.Clear();
            foreach (var (s, title) in Steps)
            {
                var current = s == step;
                var done = s < step || (s == Step.Done && current);
                var row = new DockPanel();
                row.Children.Add(Badge(s, current, done));
                if (skipped.Contains(s) && s != Step.Done)
                {
                    var tag = new TextBlock { Text = L("건너뜀", "Skipped"), FontSize = 11, Foreground = Res("Side3"), VerticalAlignment = VerticalAlignment.Center };
                    DockPanel.SetDock(tag, Dock.Right);
                    row.Children.Add(tag);
                }
                row.Children.Add(new TextBlock
                {
                    Text = title, FontSize = 13, VerticalAlignment = VerticalAlignment.Center,
                    FontWeight = current ? FontWeights.SemiBold : FontWeights.Normal,
                    Foreground = current ? Brushes.White : Res(done ? "Side1" : "Side2"),
                });
                StepList.Children.Add(new Border
                {
                    Child = row, CornerRadius = new CornerRadius(8), Padding = new Thickness(10, 9, 10, 9), Margin = new Thickness(0, 0, 0, 6),
                    Background = current ? Res("Navy2") : Brushes.Transparent,
                });
            }
        }

        UIElement Badge(Step s, bool current, bool done)
        {
            var g = new Grid { Width = 22, Height = 22, Margin = new Thickness(0, 0, 10, 0) };
            DockPanel.SetDock(g, Dock.Left);
            if (done)
            {
                var filled = s == Step.Done;
                g.Children.Add(new Ellipse { Fill = Res(filled ? "Brand" : "NavyDone") });
                g.Children.Add(new Path
                {
                    Data = Geometry.Parse("M0,4 L3.5,7.5 L10,0.5"), Stroke = Res(filled ? "OnBrand" : "Brand"), StrokeThickness = 2,
                    StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round,
                    HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                });
            }
            else
            {
                g.Children.Add(current ? new Ellipse { Fill = Res("Brand") } : new Ellipse { Stroke = Res("SideRing"), StrokeThickness = 1 });
                g.Children.Add(new TextBlock
                {
                    Text = ((int)s + 1).ToString(), FontSize = 12, FontWeight = current ? FontWeights.Bold : FontWeights.Normal,
                    Foreground = current ? Res("OnBrand") : Res("Side2"),
                    HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                });
            }
            return g;
        }

        Brush Res(string key) => (Brush)FindResource(key);

        internal void ShowDone(Device d)
        {
            var ok = d != null;
            DoneTitle.Text = ok ? L("연결됐어요", "Connected") : L("준비됐어요", "All set");
            DoneDesc.Text = ok ? L("이제 무선 연결이 끊기면 원인을 찾아 다시 붙여요.", "From now on, when wireless debugging drops it finds the cause and reconnects.") : L("휴대폰에서 무선 디버깅을 켜면 알아서 연결해요.", "Turn on Wireless debugging on your phone and it connects automatically.");
            DoneCircle.Fill = ok ? Res("Brand") : new SolidColorBrush(Color.FromRgb(0xF4, 0xB7, 0x40));
            DoneModel.Text = d?.Model ?? L("휴대폰", "Phone");
            var ip = previewIP ?? reviver.LastAddr?.Split(':').FirstOrDefault();
            DoneAddr.Text = ok ? L("무선", "Wireless") + (ip != null ? " · " + ip : "") : L("아직 연결 안 됨", "Not connected yet");
            DoneDot.Fill = Res(ok ? "Brand" : "Danger");
            DoneState.Text = ok ? L("연결됨", "Connected") : L("끊김", "Disconnected");
            DoneState.Foreground = Res(ok ? "BrandText" : "Danger");
        }

        // ---------- 버튼 ----------

        void OnLeft(object sender, RoutedEventArgs e)
        {
            switch (step)
            {
                case Step.Adb: Recheck(); break;
                case Step.Install: Back(); break;
                case Step.Pair: Pair.CodeMode = !Pair.CodeMode; Render(); break;
            }
        }

        async void OnRight(object sender, RoutedEventArgs e)
        {
            switch (step)
            {
                case Step.Adb: await InstallAdb(); break;
                case Step.Install: await Install(); break;
                case Step.Done:
                    LaunchInstalled = !installedMode;
                    Close();
                    break;
            }
        }

        void OnSkip(object sender, RoutedEventArgs e) => Next();

        void Recheck()
        {
            reviver.RefreshAdb();
            if (reviver.Adb != null) Next();
            else AdbMessage.Text = L("아직 adb를 찾지 못했어요.", "adb still not found.");
        }

        async Task InstallAdb()
        {
            if (ChoiceStudio.IsChecked == true)
            {
                var viaWinget = Installer.InstallAndroidStudio();
                AdbMessage.Text = viaWinget
                    ? L("Android Studio를 설치하고 있어요. 끝나면 Android Studio를 한 번 실행해 설정을 마친 뒤 '다시 확인'을 눌러 주세요.", "Installing Android Studio. When done, open it once to finish setup, then press 'Check again'.")
                    : L("다운로드 페이지를 열었어요. 설치하고 Android Studio를 한 번 실행한 뒤 '다시 확인'을 눌러 주세요.", "Opened the download page. Install it, open Android Studio once, then press 'Check again'.");
                return;
            }
            busy = true;
            Render();
            Progress.Visibility = Visibility.Visible;
            Progress.Value = 0;
            AdbMessage.Text = L("adb를 받는 중이에요…", "Downloading adb…");
            try
            {
                await Installer.InstallPlatformTools(new Progress<int>(p => { Progress.Value = p; AdbMessage.Text = L("adb를 받는 중이에요… ", "Downloading adb… ") + $"{p}%"; }));
                AdbMessage.Text = "";
                busy = false;
                Recheck();
            }
            catch (Exception ex)
            {
                Log.Write(L("adb 설치 실패: ", "adb install failed: ") + ex);
                AdbMessage.Text = L("설치하지 못했어요: ", "Couldn't install: ") + ex.Message;
            }
            busy = false;
            Progress.Visibility = Visibility.Collapsed;
            Render();
        }

        async Task Install()
        {
            try
            {
                // '미러링도 설치'가 켜져 있고 scrcpy가 없으면 먼저 받는다 (끄고 지나가면 다음부터 묻지 않음)
                if (MirrorToggle.IsChecked == true && !Mirror.IsInstalled)
                {
                    busy = true;
                    Render();
                    InstallProgress.Visibility = Visibility.Visible;
                    InstallProgress.Value = 0;
                    InstallMessage.Foreground = (Brush)FindResource("Ink2");
                    InstallMessage.Text = L("scrcpy를 받는 중이에요…", "Downloading scrcpy…");
                    try
                    {
                        await Mirror.Install(new Progress<int>(p => { InstallProgress.Value = p; InstallMessage.Text = L("scrcpy를 받는 중이에요… ", "Downloading scrcpy… ") + $"{p}%"; }));
                        InstallMessage.Text = "";
                        Mirror.Declined = false;
                    }
                    catch (Exception ex)
                    {
                        Log.Write(L("scrcpy 설치 실패: ", "scrcpy install failed: ") + ex);
                        InstallMessage.Foreground = (Brush)FindResource("Danger");
                        InstallMessage.Text = L("scrcpy를 설치하지 못했어요 (앱은 계속 설치할 수 있어요): ", "Couldn't install scrcpy (you can still continue): ") + ex.Message;
                        busy = false;
                        InstallProgress.Visibility = Visibility.Collapsed;
                        Render();
                        return;
                    }
                    busy = false;
                    InstallProgress.Visibility = Visibility.Collapsed;
                }
                else if (MirrorToggle.IsChecked != true && !Mirror.IsInstalled) Mirror.Declined = true;

                if (installedMode)
                {
                    Installer.AutoStart = AutoStart.IsChecked == true;
                    Installer.DesktopShortcut = Desktop.IsChecked == true;
                }
                else Installer.Install(AutoStart.IsChecked == true, Desktop.IsChecked == true);
                Next();
            }
            catch (Exception ex)
            {
                Log.Write(L("설치 실패: ", "Install failed: ") + ex);
                InstallMessage.Foreground = (Brush)FindResource("Danger");
                InstallMessage.Text = L("설치하지 못했어요: ", "Couldn't install: ") + ex.Message;
            }
        }
    }

    /// 창·사이드바 아이콘 (exe에 넣은 app.ico)
    static class Icons
    {
        public static BitmapFrame Window()
        {
            using (var s = typeof(Icons).Assembly.GetManifestResourceStream("app.ico"))
                return BitmapFrame.Create(s, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        }

        public static BitmapSource Large()
        {
            using (var s = typeof(Icons).Assembly.GetManifestResourceStream("app.ico"))
            {
                var d = new IconBitmapDecoder(s, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
                return d.Frames.OrderByDescending(f => f.PixelWidth).First();
            }
        }
    }

    /// 메뉴에서 여는 페어링 창 (마법사 없이)
    class PairWindow : Window
    {
        public PairWindow(Reviver reviver, bool autoStart = true)
        {
            Title = L("휴대폰 페어링 — ", "Pair phone — ") + AppInfo.Short;
            Icon = Icons.Window();
            SizeToContent = SizeToContent.WidthAndHeight;
            ResizeMode = ResizeMode.NoResize;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Background = Brushes.White;
            FontFamily = (FontFamily)FindResource("UiFont");
            UseLayoutRounding = true;
            TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);

            var pair = new PairView();
            pair.Attach(reviver);
            var eyebrow = new TextBlock { Text = L("휴대폰 페어링 · 이 PC에서 처음 한 번", "Pair phone · once per PC"), Style = (Style)FindResource("Eyebrow") };
            var title = new TextBlock { Text = L("휴대폰으로 QR을 찍어 주세요", "Scan the QR with your phone"), Style = (Style)FindResource("H1"), Margin = new Thickness(0, 6, 0, 18) };
            var toggle = new Button { Content = L("QR 대신 페어링 코드로 하기", "Use a pairing code instead"), Style = (Style)FindResource("LinkButton"), Foreground = (Brush)FindResource("BrandText") };
            var close = new Button { Content = L("닫기", "Close"), Style = (Style)FindResource("OutlineButton") };
            toggle.Click += (s, e) => { pair.CodeMode = !pair.CodeMode; toggle.Content = pair.CodeMode ? L("QR로 하기", "Use QR code") : L("QR 대신 페어링 코드로 하기", "Use a pairing code instead"); };
            close.Click += (s, e) => Close();
            pair.Paired += () => { close.Content = L("완료", "Done"); close.Style = (Style)FindResource("PrimaryButton"); };
            var bottom = new DockPanel { LastChildFill = false, Margin = new Thickness(0, 18, 0, 0), Height = 44 };
            DockPanel.SetDock(close, Dock.Right);
            bottom.Children.Add(toggle);
            bottom.Children.Add(close);
            var root = new StackPanel { Width = 496, Margin = new Thickness(32, 28, 32, 24) };
            root.Children.Add(eyebrow);
            root.Children.Add(title);
            root.Children.Add(pair);
            root.Children.Add(bottom);
            Content = root;
            if (autoStart) Loaded += (s, e) => pair.Start();
            Closed += (s, e) => pair.Stop();
        }
    }
}
