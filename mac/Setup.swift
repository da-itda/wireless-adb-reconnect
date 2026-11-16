// 설치 마법사 · 휴대폰 페어링 화면 (SwiftUI) — 디자인 시안: https://claude.ai/artifact/AcexxtvRGVUCuaJBxK7k8q
// 마법사: ① adb 준비 → ② 앱 설치(응용 프로그램 폴더·로그인 시 실행) → ③ 로컬 네트워크 허용 → ④ 휴대폰 페어링 → ⑤ 완료
// 이미 된 단계(adb 있음, 응용 프로그램 폴더에 있음, 이미 허용됨, 이미 연결됨)는 "건너뜀"으로 표시하고 넘어간다.
// 페어링: QR 내용 WIFI:T:ADB;S:<이름>;P:<비밀번호>;; → 휴대폰이 그 이름으로 _adb-tls-pairing 을 알림 → adb pair
import AppKit
import CoreImage
import ServiceManagement
import SwiftUI

let platformToolsDir = supportDir.appendingPathComponent("platform-tools")
let applicationsAppURL = URL(fileURLWithPath: "/Applications/\(appName).app")

// MARK: - 색 (시안과 같은 값)

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    static let navy = Color(hex: 0x0F2233), navy2 = Color(hex: 0x1B3549), navyDone = Color(hex: 0x2A4A5F)
    static let brand = Color(hex: 0x3DDC84), onBrand = Color(hex: 0x0B1F14), brandText = Color(hex: 0x0F7A45)
    static let mint = Color(hex: 0xF1FCF6), mint2 = Color(hex: 0xE8F9F0)
    static let ink = Color(hex: 0x13202B), ink2 = Color(hex: 0x33424F), muted = Color(hex: 0x5B6874)
    static let line = Color(hex: 0xE3E8ED), line2 = Color(hex: 0xC9D2DA), soft = Color(hex: 0xF6F8FA)
    static let side1 = Color(hex: 0xDCE6EE), side2 = Color(hex: 0x9FB2C2), side3 = Color(hex: 0x7F95A8), sideRing = Color(hex: 0x4A6378)
    static let danger = Color(hex: 0xC93A3A)
}

// MARK: - 설치 동작

enum AppInstall {
    static var isInApplications: Bool { Bundle.main.bundleURL.path.hasPrefix("/Applications/") }

    static var loginItemEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            log(L("로그인 항목 ", "Login item ") + (on ? L("등록", "registered") : L("해제", "unregistered")) + ": \(SMAppService.mainApp.status.rawValue)")
        } catch {
            log(L("로그인 항목 변경 실패: ", "Login item change failed: ") + "\(error)")
        }
        if on, SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    /// 제거: 로그인 항목 해제, 설정 초기화, 앱을 휴지통으로 (설치한 adb·기록은 남김)
    static func uninstall() {
        try? SMAppService.mainApp.unregister()
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        let app = isInApplications ? Bundle.main.bundleURL : applicationsAppURL
        if FileManager.default.fileExists(atPath: app.path) { try? FileManager.default.trashItem(at: app, resultingItemURL: nil) }
        log(L("제거 완료: 로그인 항목 해제, 설정 초기화, 휴지통으로 → ", "Uninstalled: login item removed, settings reset, moved to Trash → ") + app.path)
    }

    /// 응용 프로그램 폴더로 복사한 뒤 그쪽을 실행하고 지금 앱은 끝낸다
    static func moveToApplicationsAndRelaunch() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: applicationsAppURL.path) { try fm.removeItem(at: applicationsAppURL) }
        try fm.copyItem(at: Bundle.main.bundleURL, to: applicationsAppURL)
        log(L("응용 프로그램 폴더로 복사: ", "Copied to Applications: ") + applicationsAppURL.path)
        // 지금 앱이 끝나야 새 앱이 adb 서버를 가질 수 있으므로, 잠시 뒤에 연다
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n '\(applicationsAppURL.path)' --args --after-move"]
        try p.run()
        NSApp.terminate(nil)
    }

    /// Google 공식 platform-tools(약 15MB)를 받아 Application Support/<앱>/platform-tools 에 푼다
    static func installPlatformTools(done: @escaping (String?) -> Void) {
        let url = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!
        URLSession.shared.downloadTask(with: url) { tmp, _, err in
            guard let tmp, err == nil else { done(L("다운로드 실패: ", "Download failed: ") + (err?.localizedDescription ?? "")); return }
            let zip = supportDir.appendingPathComponent("platform-tools.zip")
            try? FileManager.default.removeItem(at: zip)
            do { try FileManager.default.moveItem(at: tmp, to: zip) } catch { done("\(error)"); return }
            try? FileManager.default.removeItem(at: platformToolsDir)
            let r = run("/usr/bin/ditto", ["-x", "-k", zip.path, supportDir.path], timeout: 60)
            try? FileManager.default.removeItem(at: zip)
            let ok = FileManager.default.isExecutableFile(atPath: platformToolsDir.appendingPathComponent("adb").path)
            log((ok ? L("adb 설치 완료: ", "adb installed: ") : L("adb 설치 실패: ", "adb install failed: ")) + "\(platformToolsDir.path) \(r.out)")
            done(ok ? nil : L("압축 풀기 실패: ", "Unzip failed: ") + r.out)
        }.resume()
    }

    /// Homebrew가 있으면 터미널에서 brew로, 없으면 다운로드 페이지
    static func installAndroidStudio() -> Bool {
        if let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let script = "tell application \"Terminal\" to do script \"\(brew) install --cask android-studio\""
            run("/usr/bin/osascript", ["-e", script, "-e", "tell application \"Terminal\" to activate"], timeout: 10)
            return true
        }
        NSWorkspace.shared.open(URL(string: "https://developer.android.com/studio")!)
        return false
    }
}

// MARK: - 페어링 (QR · 코드)

final class PairModel: ObservableObject {
    /// confirm: adb를 다시 띄워야 해서 연결된 다른 기기가 잠깐 끊긴다 — 계속할지 묻는 중
    enum Kind { case waiting, working, success, error, confirm }
    @Published var status = L("adb 서버 준비 중…", "Preparing adb server…")
    @Published var kind = Kind.working
    @Published var codeMode = false
    @Published var addr = ""
    @Published var code = ""
    let reviver: Reviver
    let name = "adbreconnect-" + PairModel.random(6)
    let password = PairModel.random(10)
    let qr: NSImage
    var onPaired: () -> Void = {}
    /// 페어링해서 연결된 휴대폰 (ro.serialno)
    @Published var pairedId: String?
    private var cancelled = false
    private var started = false
    /// 창을 열 때 이미 목록에 있던 휴대폰 — 이 휴대폰들이 붙은 것은 '페어링됨'으로 치지 않는다
    private let knownAtOpen: Set<String>
    private let confirmSem = DispatchSemaphore(value: 0)
    private var confirmed = false

    init(reviver: Reviver) {
        self.reviver = reviver
        knownAtOpen = Set(reviver.store.all.map(\.id))
        qr = PairModel.qrImage("WIFI:T:ADB;S:\(name);P:\(password);;")
    }

    func start() {
        guard !started else { return }
        started = true
        DispatchQueue.global().async { self.watchQR() }
    }

    func stop() { cancelled = true; confirmSem.signal() }

    /// 'adb를 다시 시작해도 될까요?'에서 계속
    func confirmRestart() { confirmed = true; confirmSem.signal() }

    private let prepareLock = NSLock()

    /// 앱이 서버를 소유하지 않는데 다른 기기가 연결돼 있으면, 서버를 다시 띄우기 전에 묻는다 (false = 멈춤)
    private func prepareServer() -> Bool {
        prepareLock.lock(); defer { prepareLock.unlock() }    // QR 대기와 코드 입력이 함께 묻지 않게
        guard !cancelled else { return false }
        switch reviver.prepareForPairing() {
        case .ready: return true
        case .failed:
            set(L("adb를 찾을 수 없어요. 설정에서 adb를 설치해 주세요.", "adb not found. Install it from Settings."), .error); return false
        case .needsConfirm(let names):
            if confirmed { break }
            let who = names.isEmpty ? L("연결된 기기", "Connected devices") : names.joined(separator: ", ")
            set(L("페어링하려면 adb를 다시 시작해야 해요. {0}이(가) 잠깐 끊겼다가 다시 연결돼요.", "Pairing needs to restart adb. {0} will disconnect briefly and reconnect.", who), .confirm)
            confirmSem.wait()
            guard confirmed, !cancelled else { return false }
        }
        set(L("adb 다시 시작하는 중…", "Restarting adb…"), .working)
        _ = reviver.restartAndReconnectAll()
        return true
    }

    /// 창을 연 뒤 새로 붙은 휴대폰 (id를 알면 그 휴대폰만)
    private func newlyConnected(_ id: String?) -> String? {
        newlyConnectedPhone(connected: reviver.connectedIds(), knownAtOpen: knownAtOpen, forgotten: reviver.forgottenIds, target: id)
    }

    private func paired(_ id: String) {
        reviver.store.setEnabled(id, true)
        DispatchQueue.main.async { self.pairedId = id; self.onPaired() }
    }

    private func set(_ s: String, _ k: Kind) {
        DispatchQueue.main.async { self.status = s; self.kind = k }
    }

    private func watchQR() {
        guard prepareServer() else { return }
        set(L("휴대폰을 기다리는 중… QR을 찍으면 자동으로 연결돼요", "Waiting for your phone… it connects as soon as you scan the QR"), .waiting)
        let deadline = Date().addingTimeInterval(300)
        var lastTried: String?
        while !cancelled && Date() < deadline {
            // 목록에 없던 휴대폰이 그 사이 붙었으면(이미 페어링돼 있던 휴대폰) 페어링할 필요 없음
            if let id = newlyConnected(nil) {
                set(L("이미 페어링되어 있어서 연결됐어요", "Already paired — connected"), .success)
                paired(id)
                return
            }
            // 페어링 중에 휴대폰 IP가 바뀌면 옛 주소가 남아 있을 수 있다 → 접속되는 주소가 보일 때까지 기다렸다 다시 시도
            if let svc = reviver.mdnsServices().first(where: { $0.name == name && $0.type.hasPrefix("_adb-tls-pairing") }),
               svc.addr != lastTried {
                let parts = svc.addr.split(separator: ":")
                if parts.count == 2, run("/usr/bin/nc", ["-z", "-G", "2", String(parts[0]), String(parts[1])], timeout: 4).code != 0 {
                    log(L("페어링 주소 접속 안 됨 → 새 주소 기다림: ", "Pairing address unreachable → waiting for a new one: ") + svc.addr)
                    set(L("휴대폰 주소를 다시 찾는 중… (Wi‑Fi가 바뀌었을 수 있어요)", "Looking for the phone again… (its Wi‑Fi may have changed)"), .working)
                } else {
                    lastTried = svc.addr
                    if pair(svc.addr, password) { return }
                    set(L("페어링 실패 — 다시 시도하는 중이에요. 휴대폰의 QR 화면을 닫지 마세요", "Pairing failed — retrying. Keep the QR screen open on your phone"), .error)
                }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        if !cancelled { set(L("시간이 지났어요. 창을 닫고 다시 열어 주세요.", "Timed out. Close this window and open it again."), .error) }
    }

    func pairWithCode() {
        let a = addr.trimmingCharacters(in: .whitespaces), c = code.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty, !c.isEmpty else { set(L("IP 주소:포트와 코드를 입력해 주세요.", "Enter the IP address:port and the code."), .error); return }
        DispatchQueue.global().async { if self.prepareServer() { _ = self.pair(a, c) } }
    }

    @discardableResult
    private func pair(_ addr: String, _ secret: String) -> Bool {
        set(L("페어링 중… ", "Pairing… ") + addr, .working)
        let out = reviver.adbIfRunning(["pair", addr, secret], timeout: 30)?.out ?? ""
        log(L("페어링 ", "Pairing ") + "\(addr): \(out)")
        guard out.contains("Successfully paired") else { set(L("페어링 실패: ", "Pairing failed: ") + out, .error); return false }
        set(L("페어링 완료! 연결하는 중…", "Paired! Connecting…"), .working)
        // 어느 휴대폰인지는 출력의 guid로 안다 (못 읽으면 창을 연 뒤 새로 붙은 휴대폰)
        let id = pairedPhoneId(fromPairOutput: out)
        if let id {
            reviver.unforget(id)
            if reviver.store.phone(id) != nil { reviver.store.setEnabled(id, true) }
        }
        // 앱의 adb 서버는 저절로 붙지 않는다 → 휴대폰이 알리는 연결 주소로 직접 붙인다
        func connectAddr() -> String? {
            if let a = reviver.mdnsServices().first(where: { $0.type.hasPrefix("_adb-tls-connect") && (id == nil || phoneId(fromMdnsName: $0.name) == id) })?.addr { return a }
            if let id, case .found(let a) = findPhone(id: id, timeout: 4) { return a }
            return nil
        }
        var ok = false
        for _ in 0..<5 where !ok && !cancelled {
            if let a = connectAddr() {
                log(L("페어링 후 연결 ", "Connecting after pairing ") + a + ": " + (reviver.adbIfRunning(["connect", a], timeout: 12)?.out ?? ""))
                ok = waitUntil(5) { self.newlyConnected(id) != nil }
            } else {
                Thread.sleep(forTimeInterval: 2)
            }
        }
        if ok, let got = newlyConnected(id) {
            set(L("연결됐어요", "Connected"), .success)
            paired(got)
        } else {
            set(L("페어링은 됐지만 아직 연결되지 않았어요. 메뉴 막대에서 '기기 다시 연결하기'를 눌러 주세요.", "Paired, but not connected yet. Choose 'Reconnect device' in the menu bar."), .error)
        }
        return true
    }

    static func random(_ n: Int) -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<n).map { _ in chars.randomElement()! })
    }

    static func qrImage(_ text: String) -> NSImage {
        let f = CIFilter(name: "CIQRCodeGenerator")!
        f.setValue(text.data(using: .utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        let out = f.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

// MARK: - 마법사 상태

final class SetupModel: ObservableObject {
    enum Step: Int, CaseIterable { case adb, install, network, pair, done }
    @Published var step: Step = .adb
    @Published var skipped: Set<Step> = []
    @Published var useStudio = false
    @Published var busy = false
    @Published var message: String?
    @Published var wantLogin = true
    /// 2단계 스위치 '화면 미러링(scrcpy)도 설치' — Homebrew가 있고 scrcpy가 없을 때만 켤 수 있음
    @Published var wantMirror = false
    let hasScrcpy = ScreenMirror.isInstalled
    let hasBrew = ScreenMirror.brewPath() != nil
    /// 완료 화면에 보여 줄 연결된 휴대폰 (nil = 연결 안 됨)
    @Published var phone: KnownPhone?
    /// ③ 로컬 네트워크 권한 (단계에 있는 동안 2초마다 확인)
    @Published var network: LocalNetwork.Status = LocalNetwork.last
    private var networkTimer: Timer?
    /// 완료 화면에 보여 줄 IP (스냅샷에서는 예시 주소)
    var shownIP: String? { isPreview ? "192.168.0.10" : phone?.lastAddr?.split(separator: ":").first.map(String.init) }
    let reviver: Reviver
    let pair: PairModel
    var onAdbReady: () -> Void = {}
    var close: () -> Void = {}

    /// 스냅샷용 (네트워크 확인 등 실제 동작은 하지 않음)
    let isPreview: Bool

    init(reviver: Reviver, connected: KnownPhone? = nil, preview: Step? = nil, startAt: Step? = nil) {
        self.reviver = reviver
        isPreview = preview != nil
        pair = PairModel(reviver: reviver)
        phone = connected
        wantLogin = AppInstall.loginItemEnabled || !UserDefaults.standard.bool(forKey: "setupShown") || UserDefaults.standard.bool(forKey: "wantLogin")
        if reviver.adb != nil { skipped.insert(.adb) }
        // 설치 단계: 응용 프로그램 폴더에 있어도 scrcpy가 없고 아직 묻지 않았으면 보여 준다 ('미러링도 설치' 스위치)
        let mirrorDeclined = UserDefaults.standard.bool(forKey: "mirrorDeclined")
        if AppInstall.isInApplications && (hasScrcpy || mirrorDeclined) && startAt != .install { skipped.insert(.install) }
        wantMirror = hasScrcpy || (hasBrew && !mirrorDeclined)
        if LocalNetwork.last == .allowed { skipped.insert(.network) }
        // 이미 연결됐거나, 이 Mac에서 무선으로 붙은 적이 있으면(=페어링됨) 페어링 단계는 건너뜀
        if phone != nil || (preview == nil && (!reviver.store.all.isEmpty || reviver.store.legacyWinner != nil)) { skipped.insert(.pair) }
        if let startAt { skipped.remove(startAt) }
        if preview == nil {
            // adb에 물어보는 데 몇 초 걸릴 수 있어 창을 먼저 띄운다
            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                let p = SetupModel.connectedPhone(self.reviver, preferring: nil)
                DispatchQueue.main.async { if self.phone == nil { self.phone = p } }
            }
        }
        step = preview ?? startAt ?? Step.allCases.first { $0 != .done && !skipped.contains($0) } ?? .done
        pair.onPaired = { [weak self] in
            guard let self else { return }
            self.phone = self.pair.pairedId.flatMap(self.reviver.store.phone)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.step = .done }
        }
    }

    /// 연결된 휴대폰 — 방금 페어링한 휴대폰이 있으면 그것, 없으면 목록에서 연결된 첫 휴대폰
    static func connectedPhone(_ reviver: Reviver, preferring id: String?) -> KnownPhone? {
        let ids = reviver.connectedIds()
        let target = id.flatMap { ids.contains($0) ? $0 : nil } ?? reviver.store.all.first { ids.contains($0.id) }?.id
        return target.flatMap(reviver.store.phone)
    }

    func next() {
        let all = Step.allCases
        var i = all.firstIndex(of: step)! + 1
        while i < all.count - 1 && skipped.contains(all[i]) { i += 1 }
        step = all[min(i, all.count - 1)]
        if step == .done {
            let paired = pair.pairedId
            DispatchQueue.global().async {
                let p = SetupModel.connectedPhone(self.reviver, preferring: paired)
                DispatchQueue.main.async { self.phone = p }
            }
        }
    }

    func back() {
        let all = Step.allCases
        var i = all.firstIndex(of: step)! - 1
        while i > 0 && skipped.contains(all[i]) { i -= 1 }
        if i >= 0 { step = all[i] }
    }

    var canGoBack: Bool {
        Step.allCases.prefix(while: { $0 != step }).contains { !skipped.contains($0) }
    }

    // ③ 로컬 네트워크 — 확인을 시작하면 처음엔 macOS가 '허용 / 허용 안 함' 창을 띄운다
    func watchNetwork() {
        guard networkTimer == nil else { return }
        checkNetwork()
        networkTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkNetwork() }
    }

    func stopNetwork() { networkTimer?.invalidate(); networkTimer = nil }

    private func checkNetwork() {
        LocalNetwork.check(timeout: 1.8) { [weak self] s in
            guard let self, s != .unknown || self.network == .unknown else { return }
            let became = s == .allowed && self.network != .allowed
            self.network = s
            if s == .allowed { self.stopNetwork() }
            // 이 단계에서 허용하면 잠깐 보여 주고 넘어간다
            if became, self.step == .network {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if self.step == .network { self.next() } }
            }
        }
    }

    func openNetworkHelp() { NetworkHelp.shared.show(onAllowed: onAdbReady) }

    // ① adb
    func installAdb() {
        if useStudio {
            let viaBrew = AppInstall.installAndroidStudio()
            message = viaBrew ? L("터미널에서 Android Studio를 설치하고 있어요. 끝나면 Android Studio를 한 번 실행해 설정을 마친 뒤 '다시 확인'을 눌러 주세요.", "Installing Android Studio in Terminal. When done, open Android Studio once to finish setup, then press 'Check again'.")
                              : L("다운로드 페이지를 열었어요. 설치하고 Android Studio를 한 번 실행한 뒤 '다시 확인'을 눌러 주세요.", "Opened the download page. Install it, open Android Studio once, then press 'Check again'.")
            return
        }
        busy = true
        message = L("adb를 받는 중이에요…", "Downloading adb…")
        AppInstall.installPlatformTools { err in
            DispatchQueue.main.async {
                self.busy = false
                if let err { self.message = L("설치하지 못했어요: ", "Couldn't install: ") + err; return }
                self.message = nil
                self.recheck()
            }
        }
    }

    func recheck() {
        reviver.refreshAdb()
        if reviver.adb != nil { onAdbReady(); next() } else { message = L("아직 adb를 찾지 못했어요.", "adb still not found.") }
    }

    // ② 설치 — '미러링도 설치'가 켜져 있고 scrcpy가 없으면 먼저 Homebrew로 받고, 그다음 앱 설치를 이어 간다
    func install() {
        UserDefaults.standard.set(wantLogin, forKey: "wantLogin")
        if wantMirror && !ScreenMirror.isInstalled {
            busy = true
            message = L("scrcpy를 설치하는 중이에요… (Homebrew, 1~5분)", "Installing scrcpy… (Homebrew, 1–5 min)")
            ScreenMirror.installWithBrew { err in
                DispatchQueue.main.async {
                    self.busy = false
                    if let err { self.message = L("scrcpy를 설치하지 못했어요 (앱은 계속 설치할 수 있어요): ", "Couldn't install scrcpy (you can still continue): ") + err; return }
                    self.message = nil
                    UserDefaults.standard.set(false, forKey: "mirrorDeclined")
                    self.installApp()
                }
            }
            return
        }
        if !wantMirror && !ScreenMirror.isInstalled { UserDefaults.standard.set(true, forKey: "mirrorDeclined") }
        installApp()
    }

    private func installApp() {
        if AppInstall.isInApplications {
            if wantLogin != AppInstall.loginItemEnabled { AppInstall.setLoginItem(wantLogin) }
            next()
            return
        }
        do { try AppInstall.moveToApplicationsAndRelaunch() } catch { message = L("옮기지 못했어요: ", "Couldn't move the app: ") + error.localizedDescription }
    }
}

// MARK: - 공통 모양

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(.onBrand)
            .padding(.horizontal, 22)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.brand.opacity(configuration.isPressed ? 0.8 : 1)))
            .opacity(enabled ? 1 : 0.5)
    }
}

struct OutlineButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.ink2)
            .padding(.horizontal, 18)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(configuration.isPressed ? Color.soft : .white))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.line2))
    }
}

struct TextButton: ButtonStyle {
    var color = Color.muted
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13)).foregroundColor(color.opacity(configuration.isPressed ? 0.6 : 1))
            .padding(.vertical, 10).padding(.horizontal, 4).contentShape(Rectangle())
    }
}

struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct CheckBadge: View {
    var filled = false
    var body: some View {
        ZStack {
            Circle().fill(filled ? Color.brand : Color.navyDone).frame(width: 22, height: 22)
            Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundColor(filled ? .onBrand : .brand)
        }
    }
}

struct PulseDot: View {
    @State private var on = false
    var color = Color.brand
    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10)
            .overlay(Circle().stroke(color, lineWidth: 2).scaleEffect(on ? 2.4 : 1).opacity(on ? 0 : 0.7))
            .onAppear { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { on = true } }
    }
}

// MARK: - 마법사 화면

struct SetupView: View {
    @ObservedObject var m: SetupModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(m: m)
            Group {
                switch m.step {
                case .adb: AdbStep(m: m)
                case .install: InstallStep(m: m)
                case .network: NetworkStep(m: m)
                case .pair: PairStep(m: m, pair: m.pair)
                case .done: DoneStep(m: m)
                }
            }
            .padding(EdgeInsets(top: 32, leading: 36, bottom: 28, trailing: 36))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white)
        }
        .frame(width: 760, height: 486)
        .foregroundColor(.ink)
        .environment(\.colorScheme, .light)
    }
}

struct Sidebar: View {
    @ObservedObject var m: SetupModel
    let titles: [(SetupModel.Step, String)] = [(.adb, L("adb 준비", "Get adb")), (.install, L("앱 설치", "Install")), (.network, L("네트워크 허용", "Local Network")), (.pair, L("휴대폰 페어링", "Pair phone")), (.done, L("완료", "Done"))]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44).padding(-2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(appShortName).font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                    Text(L("무선 ADB 자동 재연결", "Auto-reconnect")).font(.system(size: 11)).foregroundColor(.side2)
                }
            }
            VStack(spacing: 6) {
                ForEach(titles, id: \.0) { step, title in row(step, title) }
            }
            Spacer(minLength: 0)
            Text(L("이미 있는 단계는 건너뜁니다", "Steps already done are skipped"))
                .font(.system(size: 11)).foregroundColor(.side3)
                .frame(height: 44, alignment: .leading)
        }
        .padding(EdgeInsets(top: 24, leading: 20, bottom: 28, trailing: 20))
        .frame(width: 216, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.navy)
    }

    @ViewBuilder func row(_ step: SetupModel.Step, _ title: String) -> some View {
        let current = m.step == step
        let done = step.rawValue < m.step.rawValue || (step == .done && current)
        HStack(spacing: 10) {
            if done { CheckBadge(filled: step == .done) }
            else if current {
                ZStack {
                    Circle().fill(Color.brand).frame(width: 22, height: 22)
                    Text("\(step.rawValue + 1)").font(.system(size: 12, weight: .bold)).foregroundColor(.onBrand)
                }
            } else {
                ZStack {
                    Circle().stroke(Color.sideRing).frame(width: 21, height: 21)
                    Text("\(step.rawValue + 1)").font(.system(size: 12)).foregroundColor(.side2)
                }
            }
            Text(title).font(.system(size: 13, weight: current ? .semibold : .regular))
                .foregroundColor(current ? .white : done ? .side1 : .side2)
            Spacer(minLength: 0)
            if m.skipped.contains(step) && step != .done {
                Text(L("건너뜀", "Skipped")).font(.system(size: 11)).foregroundColor(.side3)
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(current ? Color.navy2 : .clear))
    }
}

struct StepHeader: View {
    let eyebrow: String, title: String
    var desc: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow).font(.system(size: 12, weight: .semibold)).foregroundColor(.brandText)
            Text(title).font(.system(size: 22, weight: .bold))
            if let desc { Text(desc).font(.system(size: 13)).foregroundColor(.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct ChoiceCard: View {
    let selected: Bool, title: String, detail: String
    var badge: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().stroke(selected ? Color.brandText : Color.line2, lineWidth: 1.5).frame(width: 16, height: 16)
                    if selected { Circle().fill(Color.brandText).frame(width: 8, height: 8) }
                }.padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(.ink)
                        if let badge {
                            Text(badge).font(.system(size: 11, weight: .bold)).foregroundColor(.onBrand)
                                .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Color.brand))
                        }
                    }
                    Text(detail).font(.system(size: 13)).foregroundColor(.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.mint : .white))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.brand : Color.line2, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AdbStep: View {
    @ObservedObject var m: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepHeader(eyebrow: L("1 / 4단계", "Step 1 of 4"), title: L("adb를 준비할게요", "Let's get adb"),
                       desc: L("이 Mac에서 adb를 찾지 못했어요. 앱에 필요한 건 adb뿐이라 가벼운 설치를 추천해요.", "adb wasn't found on this Mac. The app only needs adb, so the lightweight install is recommended."))
            VStack(spacing: 10) {
                ChoiceCard(selected: !m.useStudio, title: L("adb만 설치", "Install adb only"), detail: L("Google 공식 platform-tools · 약 15MB · 1분 이내", "Google's official platform-tools · ~15 MB · under a minute"), badge: L("추천", "Recommended")) { m.useStudio = false }
                ChoiceCard(selected: m.useStudio, title: L("Android Studio 설치", "Install Android Studio"), detail: L("앱 개발도 한다면 · 1GB 이상 · 설치 후 한 번 실행해야 adb가 생겨요", "If you also build apps · 1 GB+ · open it once after install to get adb")) { m.useStudio = true }
            }
            if let msg = m.message {
                HStack(spacing: 8) {
                    if m.busy { ProgressView().controlSize(.small) }
                    Text(msg).font(.system(size: 12)).foregroundColor(.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button(L("이미 설치했어요 · 다시 확인", "Already installed · Check again")) { m.recheck() }.buttonStyle(TextButton())
                Spacer()
                Button(m.useStudio ? L("Android Studio 설치", "Install Android Studio") : L("설치하고 계속", "Install & continue")) { m.installAdb() }
                    .buttonStyle(PrimaryButton()).disabled(m.busy)
            }.frame(height: 44)
        }
    }
}

struct InstallStep: View {
    @ObservedObject var m: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepHeader(eyebrow: L("2 / 4단계", "Step 2 of 4"), title: AppInstall.isInApplications ? L("설치되어 있어요", "Installed") : L("앱을 설치할게요", "Install the app"),
                       desc: AppInstall.isInApplications ? L("자동 실행을 바꾸거나, 화면 미러링(scrcpy)을 추가로 설치할 수 있어요.", "Change launch at login, or add screen mirroring (scrcpy).")
                                                         : L("설치하면 메뉴 막대에 머물면서 무선 연결이 끊기면 바로 다시 붙여요.", "It stays in the menu bar and reconnects as soon as wireless debugging drops."))
            HStack(spacing: 12) {
                Image(systemName: "folder").font(.system(size: 17)).foregroundColor(.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("설치 위치", "Location")).font(.system(size: 13, weight: .semibold))
                    Text(AppInstall.isInApplications ? L("응용 프로그램 폴더 · 이미 설치됨", "Applications folder · already installed") : L("응용 프로그램 폴더 (지금: ", "Applications folder (now in: ") + Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent + ")")
                        .font(.system(size: 13)).foregroundColor(.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.soft))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line))
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("로그인할 때 자동 실행", "Launch at login")).font(.system(size: 14, weight: .semibold))
                    Text(L("Mac을 켜면 알아서 휴대폰을 붙여요", "Connects your phone automatically when you log in")).font(.system(size: 12)).foregroundColor(.muted)
                }
                Spacer()
                Toggle("", isOn: $m.wantLogin).toggleStyle(.switch).tint(.brandText).labelsHidden()
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line))
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("화면 미러링(scrcpy)도 설치", "Also install screen mirroring (scrcpy)")).font(.system(size: 14, weight: .semibold))
                    Text(m.hasScrcpy ? L("이미 설치됨 · 메뉴 '화면 미러링 시작하기'(⌘M)", "Already installed · menu 'Start screen mirroring' (⌘M)")
                         : m.hasBrew ? L("휴대폰 화면을 Mac에 띄우고 조작 · Homebrew로 설치 · 1~5분", "See and control your phone on the Mac · via Homebrew · 1–5 min")
                                     : L("Homebrew(brew.sh)가 필요해요 · 설치 후 설정에서 켤 수 있어요", "Needs Homebrew (brew.sh) · turn on later in Settings"))
                        .font(.system(size: 12)).foregroundColor(.muted)
                }
                Spacer()
                Toggle("", isOn: $m.wantMirror).toggleStyle(.switch).tint(.brandText).labelsHidden().disabled(m.hasScrcpy || !m.hasBrew)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line))
            if let msg = m.message {
                HStack(spacing: 8) {
                    if m.busy { ProgressView().controlSize(.small) }
                    Text(msg).font(.system(size: 12)).foregroundColor(m.busy ? .ink2 : .danger).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            HStack {
                if m.canGoBack { Button(L("이전", "Back")) { m.back() }.buttonStyle(TextButton()).disabled(m.busy) }
                Spacer()
                Button(AppInstall.isInApplications && !(m.wantMirror && !m.hasScrcpy) ? L("계속", "Continue") : L("설치하고 계속", "Install & continue")) { m.install() }
                    .buttonStyle(PrimaryButton()).disabled(m.busy)
            }.frame(height: 44)
        }
    }
}

struct NetworkStep: View {
    @ObservedObject var m: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepHeader(eyebrow: L("3 / 4단계", "Step 3 of 4"), title: L("로컬 네트워크를 허용해 주세요", "Allow Local Network access"),
                       desc: L("같은 Wi‑Fi에 있는 휴대폰을 찾고 다시 붙이려면 macOS의 로컬 네트워크 권한이 필요해요.", "macOS Local Network permission is needed to find your phone on the same Wi‑Fi and reconnect it."))
            HStack(spacing: 12) {
                switch m.network {
                case .allowed:
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundColor(.brandText)
                    Text(L("허용되어 있어요", "Allowed")).font(.system(size: 14, weight: .semibold))
                case .denied:
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 18)).foregroundColor(Color(hex: 0xE8890C))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("아직 허용되지 않았어요", "Not allowed yet")).font(.system(size: 14, weight: .semibold))
                        Text(L("macOS가 묻는 창이 떴다면 '허용'을 눌러 주세요. 창이 없었다면 전에 '허용 안 함'을 누른 거예요 — 시스템 설정에서 켜 주세요.", "If macOS asks, click 'Allow'. If nothing appeared, it was denied before — turn it on in System Settings."))
                            .font(.system(size: 12)).foregroundColor(.muted).fixedSize(horizontal: false, vertical: true)
                    }
                case .unknown:
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("확인하는 중…", "Checking…")).font(.system(size: 14, weight: .semibold))
                        Text(L("macOS가 묻는 창이 뜨면 '허용'을 눌러 주세요.", "If macOS asks, click 'Allow'.")).font(.system(size: 12)).foregroundColor(.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 12).fill(m.network == .allowed ? Color.mint : Color.soft))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(m.network == .allowed ? Color.brand : Color.line))
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle").foregroundColor(.muted)
                Text(L("휴대폰과 주고받는 것은 adb 연결뿐이고, 같은 Wi‑Fi 밖으로는 나가지 않아요.", "Only the adb connection to your phone uses it, and it stays on your Wi‑Fi."))
                    .font(.system(size: 12)).foregroundColor(.ink2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.soft))
            Spacer(minLength: 0)
            HStack {
                if m.canGoBack { Button(L("이전", "Back")) { m.back() }.buttonStyle(TextButton()) }
                Spacer()
                if m.network != .allowed {
                    Button(L("나중에 하기", "Later")) { m.next() }.buttonStyle(TextButton())
                    Button(L("시스템 설정에서 켜기", "Turn on in System Settings")) { m.openNetworkHelp() }.buttonStyle(OutlineButton())
                } else {
                    Button(L("계속", "Continue")) { m.next() }.buttonStyle(PrimaryButton())
                }
            }.frame(height: 44)
        }
        .onAppear { if !m.isPreview { m.watchNetwork() } }
        .onDisappear { m.stopNetwork() }
    }
}

struct PairContent: View {
    @ObservedObject var pair: PairModel
    var autoStart = true
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 24) {
                Image(nsImage: pair.qr).interpolation(.none).resizable().frame(width: 188, height: 188)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.white).shadow(color: Color.navy.opacity(0.08), radius: 9, y: 6))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.line))
                VStack(alignment: .leading, spacing: 14) {
                    numbered(1) { boldText(L("휴대폰과 이 Mac을 **같은 Wi‑Fi**에 연결", "Connect your phone and this Mac to the **same Wi‑Fi**")) }
                    numbered(2) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("휴대폰에서 무선 디버깅 열기", "On the phone, open Wireless debugging"))
                            Text(L("설정 › 개발자 옵션 › 무선 디버깅", "Settings › Developer options › Wireless debugging")).font(.system(size: 12)).foregroundColor(.ink2)
                                .padding(.horizontal, 8).padding(.vertical, 4).background(RoundedRectangle(cornerRadius: 6).fill(Color.soft))
                        }
                    }
                    numbered(3) { boldText(L("**QR 코드로 기기 페어링**을 눌러 왼쪽 QR 찍기", "Tap **Pair device with QR code** and scan this QR")) }
                }
            }
            if pair.codeMode {
                HStack(spacing: 8) {
                    TextField(L("IP 주소:포트", "IP address:port"), text: $pair.addr).textFieldStyle(.roundedBorder).frame(width: 170)
                    TextField(L("6자리 코드", "6-digit code"), text: $pair.code).textFieldStyle(.roundedBorder).frame(width: 100)
                    Button(L("페어링", "Pair")) { pair.pairWithCode() }
                }
            }
            HStack(spacing: 10) {
                switch pair.kind {
                case .waiting: PulseDot()
                case .working: ProgressView().controlSize(.small)
                case .success: Image(systemName: "checkmark.circle.fill").foregroundColor(.brandText)
                case .error: Image(systemName: "exclamationmark.circle.fill").foregroundColor(.danger)
                case .confirm: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Color(hex: 0xE8890C))
                }
                Text(pair.status).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(pair.kind == .error ? .danger : Color(hex: 0x0F5132))
                Spacer(minLength: 0)
                if pair.kind == .confirm {
                    Button(L("계속", "Continue")) { pair.confirmRestart() }.buttonStyle(OutlineButton())
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(pair.kind == .error ? Color(hex: 0xFDF1F1) : .mint))
        }
        .font(.system(size: 13))
        .onAppear { if autoStart { pair.start() } }
    }

    /// "… **굵게** …" — 언어마다 굵은 부분의 자리가 달라서 문장 하나로 번역한다
    func boldText(_ s: String) -> Text {
        Text((try? AttributedString(markdown: s)) ?? AttributedString(s))
    }

    func numbered<V: View>(_ n: Int, @ViewBuilder _ content: () -> V) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundColor(.brandText)
                .frame(width: 22, height: 22).background(Circle().fill(Color.mint2))
            content().lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PairStep: View {
    @ObservedObject var m: SetupModel
    @ObservedObject var pair: PairModel
    var autoStart = true
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(eyebrow: L("4 / 4단계 · 처음 한 번만", "Step 4 of 4 · first time only"), title: L("휴대폰으로 QR을 찍어 주세요", "Scan the QR with your phone"))
            PairContent(pair: pair, autoStart: autoStart)
            Spacer(minLength: 0)
            HStack {
                Button(pair.codeMode ? L("QR로 하기", "Use QR code") : L("QR 대신 페어링 코드로 하기", "Use a pairing code instead")) { pair.codeMode.toggle() }
                    .buttonStyle(TextButton(color: .brandText))
                Spacer()
                Button(L("이미 페어링했어요 · 건너뛰기", "Already paired · Skip")) { m.next() }.buttonStyle(OutlineButton())
            }.frame(height: 44)
        }
    }
}

struct DoneStep: View {
    @ObservedObject var m: SetupModel
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.mint2).frame(width: 72, height: 72)
                Circle().fill(m.phone != nil ? Color.brand : Color(hex: 0xF4B740)).frame(width: 52, height: 52)
                Image(systemName: m.phone != nil ? "checkmark" : "wifi").font(.system(size: 22, weight: .heavy)).foregroundColor(.onBrand)
            }.padding(.top, 8)
            VStack(spacing: 6) {
                Text(m.phone != nil ? L("연결됐어요", "Connected") : L("준비됐어요", "All set")).font(.system(size: 24, weight: .bold))
                Text(m.phone != nil ? L("이제 무선 연결이 끊기면 원인을 찾아 다시 붙여요.", "From now on, when wireless debugging drops it finds the cause and reconnects.")
                                     : L("휴대폰에서 무선 디버깅을 켜면 알아서 연결해요.", "Turn on Wireless debugging on your phone and it connects automatically."))
                    .font(.system(size: 13)).foregroundColor(.muted)
            }
            HStack(spacing: 14) {
                Image(systemName: "candybarphone").font(.system(size: 24)).foregroundColor(.ink2).frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.phone?.name ?? L("휴대폰", "Phone")).font(.system(size: 14, weight: .semibold))
                    Text(m.phone != nil ? L("무선", "Wireless") + (m.shownIP.map { " · " + $0 } ?? "") : L("아직 연결 안 됨", "Not connected yet"))
                        .font(.system(size: 12)).foregroundColor(.muted)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(m.phone != nil ? Color.brand : Color.danger).frame(width: 8, height: 8)
                    Text(m.phone != nil ? L("연결됨", "Connected") : L("끊김", "Disconnected")).font(.system(size: 12, weight: .semibold))
                        .foregroundColor(m.phone != nil ? .brandText : .danger)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line))
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle").foregroundColor(.muted)
                Text(L("끊기면 메뉴 막대의 아이콘을 누르거나, 앱을 다시 열기만 하면 돼요. 아이콘의 전파가 회색이면 연결, 빨강이면 끊김이에요.", "If it drops, click the menu bar icon or just open the app again. Gray waves = connected, red = disconnected.")
                     + (ScreenMirror.isInstalled ? L(" 메뉴의 '화면 미러링 시작하기'(⌘M)으로 휴대폰 화면을 띄울 수 있어요.", " 'Start screen mirroring' (⌘M) in the menu shows your phone's screen.") : ""))
                    .font(.system(size: 12)).foregroundColor(.ink2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.soft))
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(L("완료", "Done")) { m.close() }.buttonStyle(PrimaryButton())
            }.frame(height: 44)
        }
    }
}

/// 메뉴에서 여는 페어링 창 (마법사 없이)
struct PairWindowView: View {
    @ObservedObject var pair: PairModel
    var autoStart = true
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(eyebrow: L("휴대폰 페어링 · 이 Mac에서 처음 한 번", "Pair phone · once per Mac"), title: L("휴대폰으로 QR을 찍어 주세요", "Scan the QR with your phone"))
            PairContent(pair: pair, autoStart: autoStart)
            HStack {
                Button(pair.codeMode ? L("QR로 하기", "Use QR code") : L("QR 대신 페어링 코드로 하기", "Use a pairing code instead")) { pair.codeMode.toggle() }
                    .buttonStyle(TextButton(color: .brandText))
                Spacer()
                Button(pair.kind == .success ? L("완료", "Done") : L("닫기", "Close")) { close() }
                    .buttonStyle(pair.kind == .success ? AnyButtonStyle(PrimaryButton()) : AnyButtonStyle(OutlineButton()))
            }.frame(height: 44)
        }
        .padding(EdgeInsets(top: 28, leading: 32, bottom: 24, trailing: 32))
        .frame(width: 560)
        .background(Color.white)
        .foregroundColor(.ink)
        .environment(\.colorScheme, .light)
    }
}

// MARK: - 미러링 옵션 창

/// ScreenMirror의 설정(UserDefaults)을 그대로 쓴다. 바꾸면 onChange (패널의 '화질: …'을 다시 그림)
final class MirrorOptionsModel: ObservableObject {
    let mirror: ScreenMirror
    var onChange: () -> Void = {}
    var openLog: () -> Void = {}
    var openSetup: () -> Void = {}
    let hasScrcpy = ScreenMirror.isInstalled

    init(mirror: ScreenMirror) { self.mirror = mirror }

    func binding<T>(_ key: ReferenceWritableKeyPath<ScreenMirror, T>) -> Binding<T> {
        Binding(get: { self.mirror[keyPath: key] },
                set: { self.objectWillChange.send(); self.mirror[keyPath: key] = $0; self.onChange() })
    }
}

struct MirrorOptionsView: View {
    @ObservedObject var m: MirrorOptionsModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(eyebrow: L("화면 미러링 · scrcpy", "Screen mirroring · scrcpy"), title: L("미러링 옵션", "Mirroring options"),
                       desc: L("모든 휴대폰에 같이 쓰이고, 다음 미러링부터 적용돼요.", "Used for every phone. Changes apply the next time you start mirroring."))
            if !m.hasScrcpy {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundColor(.danger)
                    Text(L("scrcpy가 설치되어 있지 않아요", "scrcpy is not installed")).font(.system(size: 13))
                    Spacer(minLength: 0)
                    Button(L("설정에서 설치", "Install in Settings")) { m.openSetup() }.buttonStyle(OutlineButton())
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0xFDF1F1)))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L("화질", "Quality")).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 10) {
                    ForEach(MirrorQuality.allCases, id: \.self) { q in qualityCard(q) }
                }
            }
            VStack(spacing: 0) {
                optionRow(L("소리도 전송", "Forward audio"), L("휴대폰 소리를 이 Mac에서 재생", "Play the phone's sound on this Mac"), \.audio)
                Divider()
                optionRow(L("창을 항상 위에", "Window always on top"), L("미러링 창이 다른 창에 가려지지 않게", "Keep the mirroring window above other windows"), \.alwaysOnTop)
                Divider()
                optionRow(L("미러링 중 폰 화면 끄기", "Turn phone screen off"), L("이 Mac에서는 계속 보이고 조작돼요", "Still visible and usable from this Mac"), \.turnScreenOff)
                Divider()
                optionRow(L("동영상으로 녹화", "Record to a video"), L("Movies 폴더에 .mp4로 저장", "Saved as an .mp4 in your Movies folder"), \.record)
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line))
            HStack {
                Button(L("미러링 로그 보기", "Mirroring log")) { m.openLog() }.buttonStyle(TextButton(color: .brandText))
                Spacer()
                Button(L("완료", "Done")) { close() }.buttonStyle(OutlineButton())
            }.frame(height: 44)
        }
        .padding(EdgeInsets(top: 28, leading: 32, bottom: 24, trailing: 32))
        .frame(width: 520)
        .background(Color.soft)
        .foregroundColor(.ink)
        .environment(\.colorScheme, .light)
    }

    func qualityCard(_ q: MirrorQuality) -> some View {
        let selected = m.mirror.quality == q
        let detail: String
        switch q {
        case .low: detail = L("4 Mbps · 느린 Wi‑Fi", "4 Mbps · slow Wi‑Fi")
        case .normal: detail = L("8 Mbps · 대부분", "8 Mbps · most cases")
        case .high: detail = L("16 Mbps · 빠른 Wi‑Fi", "16 Mbps · fast Wi‑Fi")
        }
        return Button { m.binding(\.quality).wrappedValue = q } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(q.shortTitle).font(.system(size: 14, weight: .semibold)).foregroundColor(.ink)
                Text(detail).font(.system(size: 12)).foregroundColor(.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.mint : .white))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.brand : Color.line2, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func optionRow(_ title: String, _ detail: String, _ key: ReferenceWritableKeyPath<ScreenMirror, Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundColor(.muted)
            }
            Spacer()
            Toggle(title, isOn: m.binding(key)).toggleStyle(.switch).tint(.brandText).labelsHidden()
        }
        .padding(.vertical, 10)
    }
}

// MARK: - 창 만들기

private final class ObserverBox { var token: NSObjectProtocol? }

private func hostWindow<V: View>(_ view: V, title: String, onClose: @escaping () -> Void) -> NSWindow {
    let host = NSHostingView(rootView: view)
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled, .closable],
                     backing: .buffered, defer: false)
    w.title = title
    w.isReleasedWhenClosed = false
    w.appearance = NSAppearance(named: .aqua)
    w.contentView = host
    let box = ObserverBox()
    box.token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
        if let t = box.token { NotificationCenter.default.removeObserver(t) }
        onClose()
    }
    return w
}

func makeSetupWindow(reviver: Reviver, startAt: SetupModel.Step? = nil, onAdbReady: @escaping () -> Void, onClose: @escaping () -> Void) -> NSWindow {
    let m = SetupModel(reviver: reviver, startAt: startAt)
    m.onAdbReady = onAdbReady
    let w = hostWindow(SetupView(m: m), title: appName + L(" 설정", " Settings")) { m.pair.stop(); m.stopNetwork(); onClose() }
    m.close = { [weak w] in w?.close() }
    return w
}

func makeMirrorWindow(model: MirrorOptionsModel, onClose: @escaping () -> Void) -> NSWindow {
    var window: NSWindow?
    let w = hostWindow(MirrorOptionsView(m: model, close: { window?.close() }), title: L("미러링 옵션 — ", "Mirroring options — ") + appShortName) { onClose() }
    window = w
    return w
}

func makePairWindow(reviver: Reviver, onClose: @escaping () -> Void) -> NSWindow {
    let pair = PairModel(reviver: reviver)
    var window: NSWindow?
    let w = hostWindow(PairWindowView(pair: pair, close: { window?.close() }), title: L("휴대폰 페어링 — ", "Pair phone — ") + appShortName) { pair.stop(); onClose() }
    window = w
    return w
}

// MARK: - (개발용) 화면을 PNG로 저장: --snapshot <폴더>  — adb 서버는 건드리지 않음

func saveSnapshots(to dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let r = Reviver()
    func save<V: View>(_ view: V, _ name: String, appearance: NSAppearance.Name = .aqua) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
    }
    let phone = KnownPhone(id: "R5CR10XXXX", name: "Galaxy Z Flip", android: "15", mdnsName: nil, lastAddr: "192.168.0.10:37215",
                           winner: nil, enabled: true, addedAt: Date())
    for step in SetupModel.Step.allCases {
        let m = SetupModel(reviver: r, connected: step == .done ? phone : nil, preview: step)
        m.skipped = step == .adb ? [] : [.adb]
        let view: AnyView = step == .pair ? AnyView(HStack(spacing: 0) { Sidebar(m: m); PairStep(m: m, pair: m.pair, autoStart: false)
            .padding(EdgeInsets(top: 32, leading: 36, bottom: 28, trailing: 36)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color.white) }
            .frame(width: 760, height: 486).foregroundColor(.ink).environment(\.colorScheme, .light)) : AnyView(SetupView(m: m))
        save(view, "setup-\(step.rawValue + 1).png")
    }
    save(PairWindowView(pair: PairModel(reviver: r), autoStart: false, close: {}), "pair-window.png")
    save(MirrorOptionsView(m: MirrorOptionsModel(mirror: ScreenMirror()), close: {}), "mirror-window.png")
    // 로컬 네트워크 도우미 창 (시스템 설정 옆) — 밝게·어둡게, 기다리는 중 / 허용됨
    for dark in [false, true] {
        for allowed in [false, true] {
            let hm = NetworkHelpModel()
            hm.allowed = allowed
            save(NetworkHelpView(m: hm).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light),
                 "network-help-\(allowed ? "allowed" : "waiting")-\(dark ? "dark" : "light").png", appearance: dark ? .darkAqua : .aqua)
        }
    }

    // 메뉴 막대 아이콘 (연결됨·끊김·다시 붙이는 중) — 밝은/어두운 메뉴 막대, 2배 크기
    for (name, appearance, bg) in [("menubar-light.png", NSAppearance.Name.aqua, NSColor(white: 0.93, alpha: 1)),
                                   ("menubar-dark.png", NSAppearance.Name.darkAqua, NSColor(white: 0.17, alpha: 1))] {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 192, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 96, height: 24)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            bg.setFill(); NSRect(x: 0, y: 0, width: 96, height: 24).fill()
            for (i, s) in [LinkState.connected, .disconnected, .working].enumerated() {
                statusImage(s).draw(in: NSRect(x: 6 + i * 30, y: 3, width: 24, height: 18))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
    }

    // 카드형 패널 — 밝게·어둡게 × 연결됨 / 옵션 펼침 / 끊김 + 권한 문제 / 다시 붙이는 중 + 업데이트
    let pm = ScreenMirror()
    let galaxy = PhoneRow(id: "R5CR10XXXX", name: "Galaxy Z Flip", android: "15", addr: "192.168.0.10:37215",
                          state: .connected(since: Date().addingTimeInterval(-12 * 60)), mirroring: false)
    let pixel = PhoneRow(id: "4A1B2XXXX", name: "Pixel 8", android: "16", addr: "192.168.0.21:41235", state: .dropped, mirroring: false)
    func two(_ m: PanelModel, _ a: PhoneRow, _ b: PhoneRow) {
        m.phones = [a, b]; m.enabledCount = 2
        m.connectedCount = [a, b].filter { if case .connected = $0.state { return true }; return false }.count
        m.overall = m.connectedCount == 2 ? .allConnected : .someDropped
    }
    var both = pixel; both.state = .connected(since: Date().addingTimeInterval(-3 * 60))
    var mirroring = galaxy; mirroring.mirroring = true
    let states: [(String, (PanelModel) -> Void)] = [
        ("connected", { $0.link = .connected; two($0, galaxy, both) }),
        ("mirroring", { $0.link = .connected; two($0, mirroring, both); $0.mirroring = true; $0.expanded = galaxy.id }),
        ("disconnected", { $0.link = .disconnected; two($0, galaxy, pixel); $0.restartOffer = true }),
        ("working", { $0.link = .working; $0.status = L("연결하는 중…", "Connecting…"); two($0, galaxy, pixel); $0.busyIds = [pixel.id]; $0.update = .available("1.5.0") }),
    ]
    for dark in [false, true] {
        for (name, setup) in states {
            let m = PanelModel(mirror: pm)
            m.appVersion = "1.4.1"; m.adbVersion = "36.0.0"
            setup(m)
            let view = PanelView(m: m, solid: dark ? Color(white: 0.17) : Color(white: 0.985))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                .padding(20).background(dark ? Color(hex: 0x2B3440) : Color(hex: 0xC9DDF0))
                .environment(\.colorScheme, dark ? .dark : .light)
            save(view, "panel-\(name)-\(dark ? "dark" : "light").png", appearance: dark ? .darkAqua : .aqua)
        }
    }
}
