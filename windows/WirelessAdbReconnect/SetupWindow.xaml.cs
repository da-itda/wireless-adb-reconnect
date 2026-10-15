using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;

namespace WirelessAdbReconnect
{
    /// 설치 마법사: ① adb 준비 → ② 앱 설치 → ③ 휴대폰 페어링 → ④ 완료
    /// 이미 된 단계(adb 있음, 설치됨, 이미 연결됨)는 "건너뜀"으로 표시하고 넘어간다.
    public partial class SetupWindow : Window
    {
        internal enum Step { Adb, Install, Pair, Done }
        static readonly (Step step, string title)[] Steps =
            { (Step.Adb, "adb 준비"), (Step.Install, "앱 설치"), (Step.Pair, "휴대폰 페어링"), (Step.Done, "완료") };

        readonly Reviver reviver;
        readonly bool installedMode;
        readonly HashSet<Step> skipped = new HashSet<Step>();
        Step step;
        bool busy;

        /// 완료 후 설치된 앱(트레이)을 실행할지
        public bool LaunchInstalled { get; private set; }

        internal SetupWindow(Reviver reviver, bool installedMode, Step? preview = null, Device previewDevice = null)
        {
            InitializeComponent();
            this.reviver = reviver;
            this.installedMode = installedMode;
            Title = AppInfo.Name + " 설정";
            Icon = Icons.Window();
            SideIcon.Source = Icons.Large();
            Pair.Attach(reviver);
            Pair.Paired += () => Task.Delay(800).ContinueWith(_ => Dispatcher.BeginInvoke((Action)(() => Go(Step.Done))));
            Closed += (s, e) => Pair.Stop();

            var connected = preview.HasValue ? previewDevice : reviver.Connected();
            if (reviver.Adb != null && preview != Step.Adb) skipped.Add(Step.Adb);
            if (installedMode) skipped.Add(Step.Install);
            if (connected != null) skipped.Add(Step.Pair);

            InstallWhere.Text = installedMode ? "내 프로그램 폴더 · 이미 설치됨" : "내 프로그램 폴더 (AppData\\Local\\Programs)";
            AutoStart.IsChecked = !installedMode || Installer.AutoStart;
            Desktop.IsChecked = !installedMode || Installer.DesktopShortcut;
            ChoiceAdb.Checked += (s, e) => Render();
            ChoiceStudio.Checked += (s, e) => Render();

            step = preview ?? new[] { Step.Adb, Step.Install, Step.Pair }.FirstOrDefault(x => !skipped.Contains(x));
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
                    Header3("1 / 3단계", "adb를 준비할게요", "이 PC에서 adb를 찾지 못했어요. 앱에 필요한 건 adb뿐이라 가벼운 설치를 추천해요.");
                    LeftBtn.Content = "이미 설치했어요 · 다시 확인";
                    LeftBtn.Visibility = Visibility.Visible;
                    RightBtn.Content = ChoiceStudio.IsChecked == true ? "Android Studio 설치" : "설치하고 계속";
                    RightBtn.IsEnabled = !busy;
                    break;
                case Step.Install:
                    Header3("2 / 3단계", installedMode ? "설치되어 있어요" : "앱을 설치할게요",
                        installedMode ? "자동 실행과 바로가기를 바꿀 수 있어요."
                                      : "설치하면 작업 표시줄 트레이에 머물면서 무선 연결이 끊기면 바로 다시 붙여요.");
                    LeftBtn.Content = "이전";
                    LeftBtn.Visibility = Vis(CanGoBack);
                    RightBtn.Content = installedMode ? "계속" : "설치하고 계속";
                    RightBtn.IsEnabled = true;
                    break;
                case Step.Pair:
                    Header3("3 / 3단계 · 처음 한 번만", "휴대폰으로 QR을 찍어 주세요", null);
                    LeftBtn.Content = Pair.CodeMode ? "QR로 하기" : "QR 대신 페어링 코드로 하기";
                    LeftBtn.Visibility = Visibility.Visible;
                    if (IsVisible) Pair.Start(); else Loaded += (s, e) => { if (step == Step.Pair) Pair.Start(); };
                    break;
                case Step.Done:
                    LeftBtn.Visibility = Visibility.Collapsed;
                    RightBtn.Content = "완료";
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
                    var tag = new TextBlock { Text = "건너뜀", FontSize = 11, Foreground = Res("Side3"), VerticalAlignment = VerticalAlignment.Center };
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
            DoneTitle.Text = ok ? "연결됐어요" : "준비됐어요";
            DoneDesc.Text = ok ? "이제 무선 연결이 끊기면 원인을 찾아 다시 붙여요." : "휴대폰에서 무선 디버깅을 켜면 알아서 연결해요.";
            DoneCircle.Fill = ok ? Res("Brand") : new SolidColorBrush(Color.FromRgb(0xF4, 0xB7, 0x40));
            DoneModel.Text = d?.Model ?? "휴대폰";
            var ip = reviver.LastAddr?.Split(':').FirstOrDefault();
            DoneAddr.Text = ok ? "무선" + (ip != null ? " · " + ip : "") : "아직 연결 안 됨";
            DoneDot.Fill = Res(ok ? "Brand" : "Danger");
            DoneState.Text = ok ? "연결됨" : "끊김";
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
                case Step.Install: Install(); break;
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
            else AdbMessage.Text = "아직 adb를 찾지 못했어요.";
        }

        async Task InstallAdb()
        {
            if (ChoiceStudio.IsChecked == true)
            {
                var viaWinget = Installer.InstallAndroidStudio();
                AdbMessage.Text = viaWinget
                    ? "Android Studio를 설치하고 있어요. 끝나면 Android Studio를 한 번 실행해 설정을 마친 뒤 '다시 확인'을 눌러 주세요."
                    : "다운로드 페이지를 열었어요. 설치하고 Android Studio를 한 번 실행한 뒤 '다시 확인'을 눌러 주세요.";
                return;
            }
            busy = true;
            Render();
            Progress.Visibility = Visibility.Visible;
            Progress.Value = 0;
            AdbMessage.Text = "adb를 받는 중이에요…";
            try
            {
                await Installer.InstallPlatformTools(new Progress<int>(p => { Progress.Value = p; AdbMessage.Text = $"adb를 받는 중이에요… {p}%"; }));
                AdbMessage.Text = "";
                busy = false;
                Recheck();
            }
            catch (Exception ex)
            {
                Log.Write("adb 설치 실패: " + ex);
                AdbMessage.Text = "설치하지 못했어요: " + ex.Message;
            }
            busy = false;
            Progress.Visibility = Visibility.Collapsed;
            Render();
        }

        void Install()
        {
            try
            {
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
                Log.Write("설치 실패: " + ex);
                InstallMessage.Text = "설치하지 못했어요: " + ex.Message;
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
        public PairWindow(Reviver reviver)
        {
            Title = "휴대폰 페어링 — " + AppInfo.Short;
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
            var eyebrow = new TextBlock { Text = "휴대폰 페어링 · 이 PC에서 처음 한 번", Style = (Style)FindResource("Eyebrow") };
            var title = new TextBlock { Text = "휴대폰으로 QR을 찍어 주세요", Style = (Style)FindResource("H1"), Margin = new Thickness(0, 6, 0, 18) };
            var toggle = new Button { Content = "QR 대신 페어링 코드로 하기", Style = (Style)FindResource("LinkButton"), Foreground = (Brush)FindResource("BrandText") };
            var close = new Button { Content = "닫기", Style = (Style)FindResource("OutlineButton") };
            toggle.Click += (s, e) => { pair.CodeMode = !pair.CodeMode; toggle.Content = pair.CodeMode ? "QR로 하기" : "QR 대신 페어링 코드로 하기"; };
            close.Click += (s, e) => Close();
            pair.Paired += () => { close.Content = "완료"; close.Style = (Style)FindResource("PrimaryButton"); };
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
            Loaded += (s, e) => pair.Start();
            Closed += (s, e) => pair.Stop();
        }
    }
}
