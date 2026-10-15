// 설치 마법사 · 휴대폰 페어링 화면 (SwiftUI) — 디자인 시안: https://claude.ai/artifact/AcexxtvRGVUCuaJBxK7k8q
// 마법사: ① adb 준비 → ② 앱 설치(응용 프로그램 폴더·로그인 시 실행) → ③ 휴대폰 페어링 → ④ 완료
// 이미 된 단계(adb 있음, 응용 프로그램 폴더에 있음, 이미 연결됨)는 "건너뜀"으로 표시하고 넘어간다.
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
            log("로그인 항목 \(on ? "등록" : "해제"): \(SMAppService.mainApp.status.rawValue)")
        } catch {
            log("로그인 항목 \(on ? "등록" : "해제") 실패: \(error)")
        }
        if on, SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    /// 제거: 로그인 항목 해제, 설정 초기화, 앱을 휴지통으로 (설치한 adb·기록은 남김)
    static func uninstall() {
        try? SMAppService.mainApp.unregister()
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        let app = isInApplications ? Bundle.main.bundleURL : applicationsAppURL
        if FileManager.default.fileExists(atPath: app.path) { try? FileManager.default.trashItem(at: app, resultingItemURL: nil) }
        log("제거 완료: 로그인 항목 해제, 설정 초기화, \(app.path) → 휴지통")
    }

    /// 응용 프로그램 폴더로 복사한 뒤 그쪽을 실행하고 지금 앱은 끝낸다
    static func moveToApplicationsAndRelaunch() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: applicationsAppURL.path) { try fm.removeItem(at: applicationsAppURL) }
        try fm.copyItem(at: Bundle.main.bundleURL, to: applicationsAppURL)
        log("응용 프로그램 폴더로 복사: \(applicationsAppURL.path)")
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
            guard let tmp, err == nil else { done("다운로드 실패: \(err?.localizedDescription ?? "")"); return }
            let zip = supportDir.appendingPathComponent("platform-tools.zip")
            try? FileManager.default.removeItem(at: zip)
            do { try FileManager.default.moveItem(at: tmp, to: zip) } catch { done("\(error)"); return }
            try? FileManager.default.removeItem(at: platformToolsDir)
            let r = run("/usr/bin/ditto", ["-x", "-k", zip.path, supportDir.path], timeout: 60)
            try? FileManager.default.removeItem(at: zip)
            let ok = FileManager.default.isExecutableFile(atPath: platformToolsDir.appendingPathComponent("adb").path)
            log("adb 설치 \(ok ? "완료" : "실패"): \(platformToolsDir.path) \(r.out)")
            done(ok ? nil : "압축 풀기 실패: \(r.out)")
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
    enum Kind { case waiting, working, success, error }
    @Published var status = "adb 서버 준비 중…"
    @Published var kind = Kind.working
    @Published var codeMode = false
    @Published var addr = ""
    @Published var code = ""
    let reviver: Reviver
    let name = "adbreconnect-" + PairModel.random(6)
    let password = PairModel.random(10)
    let qr: NSImage
    var onPaired: () -> Void = {}
    private var cancelled = false
    private var started = false

    init(reviver: Reviver) {
        self.reviver = reviver
        qr = PairModel.qrImage("WIFI:T:ADB;S:\(name);P:\(password);;")
    }

    func start() {
        guard !started else { return }
        started = true
        DispatchQueue.global().async { self.watchQR() }
    }

    func stop() { cancelled = true }

    private func set(_ s: String, _ k: Kind) {
        DispatchQueue.main.async { self.status = s; self.kind = k }
    }

    private func watchQR() {
        guard reviver.ensureServer() else { set("adb를 찾을 수 없어요. 설정에서 adb를 설치해 주세요.", .error); return }
        set("휴대폰을 기다리는 중… QR을 찍으면 자동으로 연결돼요", .waiting)
        let deadline = Date().addingTimeInterval(300)
        var lastTried: String?
        while !cancelled && Date() < deadline {
            // 이미 페어링된 휴대폰이 그 사이 붙었으면(다시 붙이기 루틴 등) 페어링할 필요 없음
            if reviver.connected() != nil {
                set("이미 페어링되어 있어서 연결됐어요", .success)
                DispatchQueue.main.async { self.onPaired() }
                return
            }
            // 페어링 중에 휴대폰 IP가 바뀌면 옛 주소가 남아 있을 수 있다 → 접속되는 주소가 보일 때까지 기다렸다 다시 시도
            if let svc = reviver.mdnsServices().first(where: { $0.name == name && $0.type.hasPrefix("_adb-tls-pairing") }),
               svc.addr != lastTried {
                let parts = svc.addr.split(separator: ":")
                if parts.count == 2, run("/usr/bin/nc", ["-z", "-G", "2", String(parts[0]), String(parts[1])], timeout: 4).code != 0 {
                    log("페어링 주소 \(svc.addr) 접속 안 됨 → 새 주소 기다림")
                    set("휴대폰 주소를 다시 찾는 중… (Wi‑Fi가 바뀌었을 수 있어요)", .working)
                } else {
                    lastTried = svc.addr
                    if pair(svc.addr, password) { return }
                    set("페어링 실패 — 다시 시도하는 중이에요. 휴대폰의 QR 화면을 닫지 마세요", .error)
                }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        if !cancelled { set("시간이 지났어요. 창을 닫고 다시 열어 주세요.", .error) }
    }

    func pairWithCode() {
        let a = addr.trimmingCharacters(in: .whitespaces), c = code.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty, !c.isEmpty else { set("IP 주소:포트와 코드를 입력해 주세요.", .error); return }
        DispatchQueue.global().async { _ = self.reviver.ensureServer(); _ = self.pair(a, c) }
    }

    @discardableResult
    private func pair(_ addr: String, _ secret: String) -> Bool {
        guard let adb = reviver.adb else { return false }
        set("페어링 중… \(addr)", .working)
        let out = run(adb, ["pair", addr, secret], timeout: 30).out
        log("페어링 \(addr): \(out)")
        guard out.contains("Successfully paired") else { set("페어링 실패: \(out)", .error); return false }
        set("페어링 완료! 연결하는 중…", .working)
        var ok = waitUntil(15) { self.reviver.connected() != nil }
        if !ok, let a = reviver.mdnsServices().first(where: { $0.type.hasPrefix("_adb-tls-connect") })?.addr {
            run(adb, ["connect", a], timeout: 12)
            ok = waitUntil(5) { self.reviver.connected() != nil }
        }
        if ok {
            set("연결됐어요", .success)
            DispatchQueue.main.async { self.onPaired() }
        } else {
            set("페어링은 됐지만 아직 연결되지 않았어요. 메뉴 막대에서 '지금 다시 붙이기'를 눌러 주세요.", .error)
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
    enum Step: Int, CaseIterable { case adb, install, pair, done }
    @Published var step: Step = .adb
    @Published var skipped: Set<Step> = []
    @Published var useStudio = false
    @Published var busy = false
    @Published var message: String?
    @Published var wantLogin = true
    @Published var device: Device?
    let reviver: Reviver
    let pair: PairModel
    var onAdbReady: () -> Void = {}
    var close: () -> Void = {}

    init(reviver: Reviver, connected: Device? = nil, preview: Step? = nil) {
        self.reviver = reviver
        pair = PairModel(reviver: reviver)
        device = connected ?? (preview == nil ? reviver.connected() : nil)
        wantLogin = AppInstall.loginItemEnabled || !UserDefaults.standard.bool(forKey: "setupShown") || UserDefaults.standard.bool(forKey: "wantLogin")
        if reviver.adb != nil { skipped.insert(.adb) }
        if AppInstall.isInApplications { skipped.insert(.install) }
        // 이미 연결됐거나, 이 Mac에서 무선으로 붙은 적이 있으면(=페어링됨) 페어링 단계는 건너뜀
        if device != nil || (preview == nil && reviver.winner != nil) { skipped.insert(.pair) }
        step = preview ?? Step.allCases.first { $0 != .done && !skipped.contains($0) } ?? .done
        pair.onPaired = { [weak self] in
            self?.device = self?.reviver.connected()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.step = .done }
        }
    }

    func next() {
        let all = Step.allCases
        var i = all.firstIndex(of: step)! + 1
        while i < all.count - 1 && skipped.contains(all[i]) { i += 1 }
        step = all[min(i, all.count - 1)]
        if step == .done { DispatchQueue.global().async { let d = self.reviver.connected(); DispatchQueue.main.async { self.device = d } } }
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

    // ① adb
    func installAdb() {
        if useStudio {
            let viaBrew = AppInstall.installAndroidStudio()
            message = viaBrew ? "터미널에서 Android Studio를 설치하고 있어요. 끝나면 Android Studio를 한 번 실행해 설정을 마친 뒤 '다시 확인'을 눌러 주세요."
                              : "다운로드 페이지를 열었어요. 설치하고 Android Studio를 한 번 실행한 뒤 '다시 확인'을 눌러 주세요."
            return
        }
        busy = true
        message = "adb를 받는 중이에요…"
        AppInstall.installPlatformTools { err in
            DispatchQueue.main.async {
                self.busy = false
                if let err { self.message = "설치하지 못했어요: \(err)"; return }
                self.message = nil
                self.recheck()
            }
        }
    }

    func recheck() {
        reviver.refreshAdb()
        if reviver.adb != nil { onAdbReady(); next() } else { message = "아직 adb를 찾지 못했어요." }
    }

    // ② 설치
    func install() {
        UserDefaults.standard.set(wantLogin, forKey: "wantLogin")
        if AppInstall.isInApplications {
            if wantLogin != AppInstall.loginItemEnabled { AppInstall.setLoginItem(wantLogin) }
            next()
            return
        }
        do { try AppInstall.moveToApplicationsAndRelaunch() } catch { message = "옮기지 못했어요: \(error.localizedDescription)" }
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
    let titles: [(SetupModel.Step, String)] = [(.adb, "adb 준비"), (.install, "앱 설치"), (.pair, "휴대폰 페어링"), (.done, "완료")]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44).padding(-2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(appShortName).font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                    Text("무선 ADB 자동 재연결").font(.system(size: 11)).foregroundColor(.side2)
                }
            }
            VStack(spacing: 6) {
                ForEach(titles, id: \.0) { step, title in row(step, title) }
            }
            Spacer(minLength: 0)
            Text("이미 있는 단계는 건너뜁니다")
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
                Text("건너뜀").font(.system(size: 11)).foregroundColor(.side3)
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
            StepHeader(eyebrow: "1 / 3단계", title: "adb를 준비할게요",
                       desc: "이 Mac에서 adb를 찾지 못했어요. 앱에 필요한 건 adb뿐이라 가벼운 설치를 추천해요.")
            VStack(spacing: 10) {
                ChoiceCard(selected: !m.useStudio, title: "adb만 설치", detail: "Google 공식 platform-tools · 약 15MB · 1분 이내", badge: "추천") { m.useStudio = false }
                ChoiceCard(selected: m.useStudio, title: "Android Studio 설치", detail: "앱 개발도 한다면 · 1GB 이상 · 설치 후 한 번 실행해야 adb가 생겨요") { m.useStudio = true }
            }
            if let msg = m.message {
                HStack(spacing: 8) {
                    if m.busy { ProgressView().controlSize(.small) }
                    Text(msg).font(.system(size: 12)).foregroundColor(.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button("이미 설치했어요 · 다시 확인") { m.recheck() }.buttonStyle(TextButton())
                Spacer()
                Button(m.useStudio ? "Android Studio 설치" : "설치하고 계속") { m.installAdb() }
                    .buttonStyle(PrimaryButton()).disabled(m.busy)
            }.frame(height: 44)
        }
    }
}

struct InstallStep: View {
    @ObservedObject var m: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepHeader(eyebrow: "2 / 3단계", title: "앱을 설치할게요",
                       desc: "설치하면 메뉴 막대에 머물면서 무선 연결이 끊기면 바로 다시 붙여요.")
            HStack(spacing: 12) {
                Image(systemName: "folder").font(.system(size: 17)).foregroundColor(.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text("설치 위치").font(.system(size: 13, weight: .semibold))
                    Text(AppInstall.isInApplications ? "응용 프로그램 폴더 · 이미 설치됨" : "응용 프로그램 폴더 (지금: \(Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent))")
                        .font(.system(size: 13)).foregroundColor(.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.soft))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line))
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("로그인할 때 자동 실행").font(.system(size: 14, weight: .semibold))
                    Text("Mac을 켜면 알아서 휴대폰을 붙여요").font(.system(size: 12)).foregroundColor(.muted)
                }
                Spacer()
                Toggle("", isOn: $m.wantLogin).toggleStyle(.switch).tint(.brandText).labelsHidden()
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line))
            if let msg = m.message { Text(msg).font(.system(size: 12)).foregroundColor(.danger) }
            Spacer(minLength: 0)
            HStack {
                if m.canGoBack { Button("이전") { m.back() }.buttonStyle(TextButton()) }
                Spacer()
                Button(AppInstall.isInApplications ? "계속" : "설치하고 계속") { m.install() }.buttonStyle(PrimaryButton())
            }.frame(height: 44)
        }
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
                    numbered(1) { Text("휴대폰과 이 Mac을 ") + Text("같은 Wi‑Fi").bold() + Text("에 연결") }
                    numbered(2) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("휴대폰에서 무선 디버깅 열기")
                            Text("설정 › 개발자 옵션 › 무선 디버깅").font(.system(size: 12)).foregroundColor(.ink2)
                                .padding(.horizontal, 8).padding(.vertical, 4).background(RoundedRectangle(cornerRadius: 6).fill(Color.soft))
                        }
                    }
                    numbered(3) { Text("QR 코드로 기기 페어링").bold() + Text("을 눌러 왼쪽 QR 찍기") }
                }
            }
            if pair.codeMode {
                HStack(spacing: 8) {
                    TextField("IP 주소:포트", text: $pair.addr).textFieldStyle(.roundedBorder).frame(width: 170)
                    TextField("6자리 코드", text: $pair.code).textFieldStyle(.roundedBorder).frame(width: 100)
                    Button("페어링") { pair.pairWithCode() }
                }
            }
            HStack(spacing: 10) {
                switch pair.kind {
                case .waiting: PulseDot()
                case .working: ProgressView().controlSize(.small)
                case .success: Image(systemName: "checkmark.circle.fill").foregroundColor(.brandText)
                case .error: Image(systemName: "exclamationmark.circle.fill").foregroundColor(.danger)
                }
                Text(pair.status).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(pair.kind == .error ? .danger : Color(hex: 0x0F5132))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(pair.kind == .error ? Color(hex: 0xFDF1F1) : .mint))
        }
        .font(.system(size: 13))
        .onAppear { if autoStart { pair.start() } }
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
            StepHeader(eyebrow: "3 / 3단계 · 처음 한 번만", title: "휴대폰으로 QR을 찍어 주세요")
            PairContent(pair: pair, autoStart: autoStart)
            Spacer(minLength: 0)
            HStack {
                Button(pair.codeMode ? "QR로 하기" : "QR 대신 페어링 코드로 하기") { pair.codeMode.toggle() }
                    .buttonStyle(TextButton(color: .brandText))
                Spacer()
                Button("이미 페어링했어요 · 건너뛰기") { m.next() }.buttonStyle(OutlineButton())
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
                Circle().fill(m.device != nil ? Color.brand : Color(hex: 0xF4B740)).frame(width: 52, height: 52)
                Image(systemName: m.device != nil ? "checkmark" : "wifi").font(.system(size: 22, weight: .heavy)).foregroundColor(.onBrand)
            }.padding(.top, 8)
            VStack(spacing: 6) {
                Text(m.device != nil ? "연결됐어요" : "준비됐어요").font(.system(size: 24, weight: .bold))
                Text(m.device != nil ? "이제 무선 연결이 끊기면 원인을 찾아 다시 붙여요."
                                     : "휴대폰에서 무선 디버깅을 켜면 알아서 연결해요.")
                    .font(.system(size: 13)).foregroundColor(.muted)
            }
            HStack(spacing: 14) {
                Image(systemName: "candybarphone").font(.system(size: 24)).foregroundColor(.ink2).frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.device?.model ?? "휴대폰").font(.system(size: 14, weight: .semibold))
                    Text(m.device != nil ? "무선\(m.reviver.lastAddr.map { " · " + ($0.split(separator: ":").first.map(String.init) ?? "") } ?? "")" : "아직 연결 안 됨")
                        .font(.system(size: 12)).foregroundColor(.muted)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(m.device != nil ? Color.brand : Color.danger).frame(width: 8, height: 8)
                    Text(m.device != nil ? "연결됨" : "끊김").font(.system(size: 12, weight: .semibold))
                        .foregroundColor(m.device != nil ? .brandText : .danger)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line))
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle").foregroundColor(.muted)
                Text("끊기면 메뉴 막대의 아이콘을 누르거나, 앱을 다시 열기만 하면 돼요. 아이콘이 초록이면 연결, 빨강이면 끊김이에요.")
                    .font(.system(size: 12)).foregroundColor(.ink2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.soft))
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("완료") { m.close() }.buttonStyle(PrimaryButton())
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
            StepHeader(eyebrow: "휴대폰 페어링 · 이 Mac에서 처음 한 번", title: "휴대폰으로 QR을 찍어 주세요")
            PairContent(pair: pair, autoStart: autoStart)
            HStack {
                Button(pair.codeMode ? "QR로 하기" : "QR 대신 페어링 코드로 하기") { pair.codeMode.toggle() }
                    .buttonStyle(TextButton(color: .brandText))
                Spacer()
                Button(pair.kind == .success ? "완료" : "닫기") { close() }
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

func makeSetupWindow(reviver: Reviver, onAdbReady: @escaping () -> Void, onClose: @escaping () -> Void) -> NSWindow {
    let m = SetupModel(reviver: reviver)
    m.onAdbReady = onAdbReady
    let w = hostWindow(SetupView(m: m), title: "\(appName) 설정") { m.pair.stop(); onClose() }
    m.close = { [weak w] in w?.close() }
    return w
}

func makePairWindow(reviver: Reviver, onClose: @escaping () -> Void) -> NSWindow {
    let pair = PairModel(reviver: reviver)
    var window: NSWindow?
    let w = hostWindow(PairWindowView(pair: pair, close: { window?.close() }), title: "휴대폰 페어링 — \(appShortName)") { pair.stop(); onClose() }
    window = w
    return w
}

// MARK: - (개발용) 화면을 PNG로 저장: --snapshot <폴더>  — adb 서버는 건드리지 않음

func saveSnapshots(to dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let r = Reviver()
    func save<V: View>(_ view: V, _ name: String) {
        let host = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
    }
    let phone = Device(serial: "adb-XXXX._adb-tls-connect._tcp", state: "device", model: "SM-F971N")
    for step in SetupModel.Step.allCases {
        let m = SetupModel(reviver: r, connected: step == .done ? phone : nil, preview: step)
        m.skipped = step == .adb ? [] : [.adb]
        let view: AnyView = step == .pair ? AnyView(HStack(spacing: 0) { Sidebar(m: m); PairStep(m: m, pair: m.pair, autoStart: false)
            .padding(EdgeInsets(top: 32, leading: 36, bottom: 28, trailing: 36)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color.white) }
            .frame(width: 760, height: 486).foregroundColor(.ink).environment(\.colorScheme, .light)) : AnyView(SetupView(m: m))
        save(view, "setup-\(step.rawValue + 1).png")
    }
    save(PairWindowView(pair: PairModel(reviver: r), autoStart: false, close: {}), "pair-window.png")
}
