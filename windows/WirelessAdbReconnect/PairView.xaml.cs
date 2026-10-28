using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using static WirelessAdbReconnect.Lang;

namespace WirelessAdbReconnect
{
    /// 휴대폰 페어링: QR(Android Studio와 같은 방식) 또는 페어링 코드
    /// QR 내용 WIFI:T:ADB;S:<이름>;P:<비밀번호>;; → 휴대폰이 찍으면 그 이름으로 _adb-tls-pairing 서비스를 알림
    /// → adb mdns services 로 찾아 adb pair <주소> <비밀번호>
    public partial class PairView : UserControl
    {
        enum Kind { Waiting, Working, Success, Error }

        Reviver reviver;
        readonly string name = "adbreconnect-" + Random(6);
        readonly string password = Random(10);
        readonly CancellationTokenSource cts = new CancellationTokenSource();
        bool started;

        /// 페어링하고 연결까지 됐을 때
        public event Action Paired;
        public bool Succeeded { get; private set; }

        public PairView()
        {
            InitializeComponent();
            try { Qr.Source = Qr_.Make($"WIFI:T:ADB;S:{name};P:{password};;"); }
            catch (Exception e) { Log.Write(L("QR 생성 실패: ", "QR generation failed: ") + e); }
        }

        internal void Attach(Reviver r) => reviver = r;

        public bool CodeMode
        {
            get => CodeRow.Visibility == Visibility.Visible;
            set => CodeRow.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
        }

        /// QR 기다리기 시작 (화면에 보일 때 한 번)
        public void Start()
        {
            if (started || reviver == null) return;
            started = true;
            Task.Run(() => WatchQr(cts.Token));
        }

        public void Stop() => cts.Cancel();

        void Set(string text, Kind kind)
        {
            Dispatcher.BeginInvoke((Action)(() =>
            {
                StatusText.Text = text;
                var error = kind == Kind.Error;
                StatusBox.Background = (Brush)FindResource(error ? "DangerSoft" : "Mint");
                StatusText.Foreground = error ? (Brush)FindResource("Danger") : new SolidColorBrush(Color.FromRgb(0x0F, 0x51, 0x32));
                Dot.Fill = (Brush)FindResource(error ? "Danger" : kind == Kind.Working ? "Muted" : "Brand");
                Pulse.Visibility = kind == Kind.Waiting ? Visibility.Visible : Visibility.Hidden;
            }));
        }

        void WatchQr(CancellationToken ct)
        {
            if (!reviver.EnsureServer()) { Set(L("adb를 찾을 수 없어요. 설정에서 adb를 설치해 주세요.", "adb not found. Install it from Settings."), Kind.Error); return; }
            Set(L("휴대폰을 기다리는 중… QR을 찍으면 자동으로 연결돼요", "Waiting for your phone… it connects as soon as you scan the QR"), Kind.Waiting);
            var deadline = DateTime.Now.AddMinutes(5);
            string lastTried = null;
            while (!ct.IsCancellationRequested && DateTime.Now < deadline)
            {
                // 이미 페어링된 휴대폰이 그 사이 붙었으면(다시 붙이기 루틴 등) 페어링할 필요 없음
                if (reviver.Connected() != null)
                {
                    Succeeded = true;
                    Set(L("이미 페어링되어 있어서 연결됐어요", "Already paired — connected"), Kind.Success);
                    Dispatcher.BeginInvoke((Action)(() => Paired?.Invoke()));
                    return;
                }
                var svc = reviver.MdnsServices().FirstOrDefault(s => s.Name == name && s.Type.StartsWith("_adb-tls-pairing"));
                // 페어링 중에 휴대폰 IP가 바뀌면(Wi‑Fi 전환 등) 옛 주소가 남아 있을 수 있다 → 접속되는 주소가 보일 때까지 기다렸다 다시 시도
                if (svc != null && svc.Address != lastTried)
                {
                    if (!Shell.TcpReachable(svc.Address))
                    {
                        Log.Write(L("페어링 주소 접속 안 됨 → 새 주소 기다림: ", "Pairing address unreachable → waiting for a new one: ") + svc.Address);
                        Set(L("휴대폰 주소를 다시 찾는 중… (Wi‑Fi가 바뀌었을 수 있어요)", "Looking for the phone again… (its Wi‑Fi may have changed)"), Kind.Working);
                    }
                    else
                    {
                        lastTried = svc.Address;
                        if (Pair(svc.Address, password)) return;
                        Set(L("페어링 실패 — 다시 시도하는 중이에요. 휴대폰의 QR 화면을 닫지 마세요", "Pairing failed — retrying. Keep the QR screen open on your phone"), Kind.Error);
                    }
                }
                Thread.Sleep(1000);
            }
            if (!ct.IsCancellationRequested) Set(L("시간이 지났어요. 창을 닫고 다시 열어 주세요.", "Timed out. Close this window and open it again."), Kind.Error);
        }

        void OnCodePair(object sender, RoutedEventArgs e)
        {
            var a = Addr.Text.Trim();
            var c = Code.Text.Trim();
            if (a.Length == 0 || c.Length == 0) { Set(L("IP 주소:포트와 코드를 입력해 주세요.", "Enter the IP address:port and the code."), Kind.Error); return; }
            CodeBtn.IsEnabled = false;
            Task.Run(() => { reviver.EnsureServer(); Pair(a, c); })
                .ContinueWith(_ => Dispatcher.BeginInvoke((Action)(() => CodeBtn.IsEnabled = true)));
        }

        bool Pair(string address, string secret)
        {
            if (!reviver.EnsureServer()) { Set(L("adb를 찾을 수 없어요.", "adb not found."), Kind.Error); return false; }
            Set(L("페어링 중… ", "Pairing… ") + address, Kind.Working);
            var r = Shell.Run(reviver.Adb, $"pair {address} {secret}", 30000);
            Log.Write(L("페어링 ", "Pairing ") + $"{address}: {r.output}");
            if (!r.output.Contains("Successfully paired")) { Set(L("페어링 실패: ", "Pairing failed: ") + r.output, Kind.Error); return false; }
            Set(L("페어링 완료! 연결하는 중…", "Paired! Connecting…"), Kind.Working);
            var ok = Shell.WaitUntil(15, () => reviver.Connected() != null);
            if (!ok)
            {
                var phone = reviver.PhoneAddr();
                if (phone != null) { Shell.Run(reviver.Adb, "connect " + phone, 12000); ok = Shell.WaitUntil(5, () => reviver.Connected() != null); }
            }
            if (ok)
            {
                Succeeded = true;
                Set(L("연결됐어요", "Connected"), Kind.Success);
                Dispatcher.BeginInvoke((Action)(() => Paired?.Invoke()));
            }
            else Set(L("페어링은 됐지만 아직 연결되지 않았어요. 트레이 메뉴의 '기기 다시 연결하기'를 눌러 주세요.", "Paired, but not connected yet. Choose 'Reconnect device' in the tray menu."), Kind.Error);
            return true;
        }

        static string Random(int n)
        {
            const string chars = "abcdefghijkmnpqrstuvwxyz23456789";
            var bytes = new byte[n];
            using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(bytes);
            return new string(bytes.Select(b => chars[b % chars.Length]).ToArray());
        }
    }

    /// QRCoder 사용은 이 클래스에만 둔다 (Program.ResolveEmbedded가 먼저 등록돼야 함)
    static class Qr_
    {
        public static BitmapSource Make(string text)
        {
            using (var gen = new QRCoder.QRCodeGenerator())
            using (var data = gen.CreateQrCode(text, QRCoder.QRCodeGenerator.ECCLevel.M))
            {
                var png = new QRCoder.PngByteQRCode(data).GetGraphic(10);
                var img = new BitmapImage();
                img.BeginInit();
                img.CacheOption = BitmapCacheOption.OnLoad;
                img.StreamSource = new MemoryStream(png);
                img.EndInit();
                img.Freeze();
                return img;
            }
        }
    }
}
