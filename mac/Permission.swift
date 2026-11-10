// 로컬 네트워크 권한 — 확인하기와 켜는 곳 안내
// · macOS에는 상태를 묻는 API가 없어서 Bonjour 탐색으로 확인한다: 허용이면 ready, 거부(또는 허용 창이 떠 있는 중)면 kDNSServiceErr_PolicyDenied
// · 처음이면 탐색을 시작하는 순간 macOS가 '허용 / 허용 안 함' 창을 띄운다
// · 권한 목록은 앱 서명(번들 ID)으로 한 줄이지만, 같은 앱을 다른 위치에서 실행하면 그 위치용 줄이 따로 생긴다
//   → 응용 프로그램 폴더에 있을 때만 로컬 네트워크를 쓴다 (AppDelegate.installedOrSetup)
// · 로컬 네트워크 목록에는 + 버튼이 없어 아이콘을 끌어다 놓을 수 없다 → 설정을 열고 옆에 도우미 창을 띄워 켤 곳을 알려 준다
// · macOS 27에는 로컬 네트워크 화면으로 바로 가는 주소가 없다(개인정보 보호 및 보안 첫 화면이 열림) → 도우미가 '로컬 네트워크'를 누르게 안내
import AppKit
import Network
import SwiftUI

enum LocalNetwork {
    enum Status { case unknown, allowed, denied }

    /// 마지막으로 확인한 상태 (메인 스레드에서 읽고 쓴다)
    static var last: Status = .unknown

    /// 탐색을 잠깐 열어 보고 결과를 메인 스레드로 알린다
    static func check(timeout: TimeInterval = 3, done: @escaping (Status) -> Void = { _ in }) {
        let q = DispatchQueue(label: "localnetwork")
        let browser = NWBrowser(for: .bonjour(type: "_adb-tls-connect._tcp", domain: "local."), using: NWParameters())
        var result: Status?
        func finish(_ s: Status) {   // q 위에서만
            guard result == nil else { return }
            result = s
            browser.cancel()
            DispatchQueue.main.async { last = s; done(s) }
        }
        browser.stateUpdateHandler = { st in
            switch st {
            // ready 직후에 거부가 올 수 있어 잠깐 기다렸다가 허용으로 본다
            case .ready: q.asyncAfter(deadline: .now() + 0.7) { finish(.allowed) }
            case .waiting(let e), .failed(let e):
                if case .dns(let code) = e, code == -65570 { finish(.denied) }
            default: break
            }
        }
        browser.start(queue: q)
        q.asyncAfter(deadline: .now() + timeout) { finish(.unknown) }
    }

    static func openSettings() { NSWorkspace.shared.open(localNetworkSettings) }
}

// MARK: - 도우미 창 (시스템 설정 옆)

final class NetworkHelpModel: ObservableObject {
    @Published var allowed = false
    var openSettings: () -> Void = {}
    var close: () -> Void = {}
}

struct NetworkHelpView: View {
    @ObservedObject var m: NetworkHelpModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("로컬 네트워크를 허용해 주세요", "Allow Local Network access")).font(.system(size: 14, weight: .semibold))
                    Text(L("같은 Wi‑Fi의 휴대폰을 찾는 데 필요해요", "Needed to find your phone on Wi‑Fi")).font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                step(1, L("시스템 설정 › 개인정보 보호 및 보안에서 '로컬 네트워크'를 누르세요", "In System Settings › Privacy & Security, click 'Local Network'"))
                step(2, L("목록에서 이 앱의 스위치를 켜세요", "Turn on the switch for this app"))
                // 켤 줄의 모양
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 20, height: 20)
                    Text(appName).font(.system(size: 12))
                    Spacer(minLength: 8)
                    ZStack(alignment: .trailing) {
                        Capsule().fill(Color.accentColor).frame(width: 30, height: 18)
                        Circle().fill(Color.white).frame(width: 14, height: 14).shadow(radius: 0.5).padding(.trailing, 2)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 1.5))
                .padding(.leading, 26)
            }
            HStack(spacing: 8) {
                if m.allowed {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(Color(hex: 0x30C25B))
                    Text(L("허용됐어요 — 다시 연결할게요", "Allowed — reconnecting")).font(.system(size: 12, weight: .semibold))
                } else {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
                    Text(L("켜면 바로 알아채고 다시 연결해요", "Reconnects as soon as you turn it on")).font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 18)
            HStack {
                Button(L("설정 다시 열기", "Open Settings again")) { m.openSettings() }.disabled(m.allowed)
                Spacer()
                Button(L("닫기", "Close")) { m.close() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                .frame(width: 18, height: 18).background(Circle().fill(Color.accentColor))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 시스템 설정을 열고 그 옆에 도우미 창을 띄운 뒤, 허용될 때까지 확인한다
final class NetworkHelp {
    static let shared = NetworkHelp()
    private var window: NSPanel?
    private let model = NetworkHelpModel()
    private var timer: Timer?
    private var onAllowed: () -> Void = {}

    func show(onAllowed: @escaping () -> Void) {
        self.onAllowed = onAllowed
        model.allowed = false
        model.openSettings = { [weak self] in self?.openSettings() }
        model.close = { [weak self] in self?.close() }
        if window == nil {
            let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300), styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: true)
            w.title = appShortName
            w.isFloatingPanel = true
            w.level = .floating
            w.hidesOnDeactivate = false
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: NetworkHelpView(m: model))
            w.setContentSize(w.contentView!.fittingSize)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in self?.stop() }
            window = w
        }
        openSettings()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        log(L("로컬 네트워크 도우미 열기", "Opened Local Network helper"))
    }

    private func openSettings() {
        LocalNetwork.openSettings()
        window?.orderFrontRegardless()
        // 설정 창이 뜨는 동안 몇 번 자리를 맞춘다
        for t in [0.0, 0.6, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.place() }
        }
    }

    private func poll() {
        LocalNetwork.check(timeout: 1.8) { [weak self] s in
            guard let self, s == .allowed, !self.model.allowed, self.window?.isVisible == true else { return }
            log(L("로컬 네트워크 허용됨", "Local Network allowed"))
            self.model.allowed = true
            self.timer?.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.close()
                self.onAllowed()
            }
        }
    }

    private func stop() { timer?.invalidate(); timer = nil }

    func close() { stop(); window?.orderOut(nil) }

    /// 시스템 설정 창 오른쪽(자리가 없으면 왼쪽, 창을 못 찾으면 화면 오른쪽 아래)
    private func place() {
        guard let w = window, let v = w.contentView else { return }
        // 처음 만든 직후엔 창 크기가 아직 내용에 맞지 않아 자리 계산이 틀린다 → 먼저 맞춘다
        v.layoutSubtreeIfNeeded()
        w.setContentSize(v.fittingSize)
        let size = w.frame.size
        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        if let r = settingsWindowFrame(primaryHeight: primary.frame.height) {
            let screen = (screens.first { $0.frame.intersects(r) } ?? primary).visibleFrame
            var x = r.maxX + 12
            if x + size.width > screen.maxX { x = r.minX - 12 - size.width }
            x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
            let y = min(max(r.maxY - size.height, screen.minY + 8), screen.maxY - size.height)
            w.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            let screen = (NSScreen.main ?? primary).visibleFrame
            w.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 20, y: screen.minY + 20))
        }
        w.orderFrontRegardless()
    }

    /// 화면에 보이는 시스템 설정 창 (창 위치는 화면 기록 권한 없이 읽을 수 있다). 좌표는 Cocoa 기준으로 바꿔 돌려준다
    private func settingsWindowFrame(primaryHeight: CGFloat) -> NSRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in list where (info[kCGWindowOwnerPID as String] as? pid_t) == pid && (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let d = info[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: d), b.width > 200 else { continue }
            return NSRect(x: b.minX, y: primaryHeight - b.maxY, width: b.width, height: b.height)
        }
        return nil
    }
}
