// Wireless ADB Reconnect (무선 ADB 자동 재연결) — 메뉴 막대 앱 (Mac)
// 무선 adb가 끊기면: 원인 진단 → 여러 방법을 순서대로 시도 → 붙은 방법을 기억해 다음엔 먼저 시도.
// adb 서버를 이 앱의 자식(nodaemon)으로 띄워, 이 앱의 로컬 네트워크 권한으로 휴대폰에 접속한다.
// (터미널/itda 데몬 등 권한 없는 프로그램이 띄운 서버는 휴대폰에 `No route to host`로 막힘)
import AppKit
import Network
import UserNotifications

// MARK: - 경로, 로그

let home = FileManager.default.homeDirectoryForCurrentUser
let appName = "Wireless ADB Reconnect"
let appShortName = "ADB Reconnect"

/// 화면 언어: 한국어·일본어·중국어(간체·번체), 그 밖의 언어는 모두 영어 (WAR_LANG=ko|en|ja|zh-Hans|zh-Hant 로 강제 — 스냅샷용)
/// 어느 언어를 쓸지는 macOS가 번들의 lproj 중에서 고른다 (권한 안내문 InfoPlist.strings와 같은 규칙)
let uiLang: String = ProcessInfo.processInfo.environment["WAR_LANG"] ?? Bundle.main.preferredLocalizations.first ?? "en"
let isKorean = uiLang == "ko"
/// 일본어·중국어 문구: <lang>.lproj/App.strings (assets/i18n/<lang>.strings, 영어 문구가 키)
private let translations: [String: String] = {
    guard !isKorean, uiLang != "en",
          let path = Bundle.main.path(forResource: "App", ofType: "strings", inDirectory: nil, forLocalization: uiLang) else { return [:] }
    return NSDictionary(contentsOfFile: path) as? [String: String] ?? [:]
}()
/// 한국어는 ko, 일본어·중국어는 영어 문구로 번역을 찾고(없으면 영어), 그 밖은 en. {0} {1} … 자리에 args를 넣는다
func L(_ ko: String, _ en: String, _ args: Any...) -> String {
    var s = isKorean ? ko : translations[en] ?? en
    for (i, a) in args.enumerated() { s = s.replacingOccurrences(of: "{\(i)}", with: "\(a)") }
    return s
}
let logURL = home.appendingPathComponent("Library/Logs/wireless-adb-reconnect.log")
let serverLogURL = home.appendingPathComponent("Library/Logs/wireless-adb-reconnect-server.log")
let supportDir = home.appendingPathComponent("Library/Application Support/\(appName)")
let localNetworkSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!

func log(_ msg: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let data = "\(f.string(from: Date())) \(msg)\n".data(using: .utf8)!
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: logURL)
    }
}

// MARK: - 알림 (macOS 기본 알림 = 앱 아이콘·이름으로 표시, 권한이 없으면 자체 팝업)

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    var onRetry: () -> Void = {}

    func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        let retry = UNNotificationAction(identifier: "retry", title: L("다시 시도", "Try again"))
        let logs = UNNotificationAction(identifier: "log", title: L("진단 보기", "Diagnostics"))
        c.setNotificationCategories([UNNotificationCategory(identifier: "fail", actions: [retry, logs], intentIdentifiers: [])])
        c.requestAuthorization(options: [.alert, .sound]) { ok, err in
            log(L("알림 권한: ", "Notification permission: ") + (ok ? L("허용", "allowed") : L("없음", "denied")) + " \(err.map { "\($0)" } ?? "")")
        }
    }

    func post(ok: Bool, title: String, body: String) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            guard s.authorizationStatus == .authorized || s.authorizationStatus == .provisional else {
                DispatchQueue.main.async { Toast.show(title: title, body: body, ok: ok) }
                return
            }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            c.sound = ok ? nil : .default
            if !ok { c.categoryIdentifier = "fail" }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { err in
                if err != nil { DispatchQueue.main.async { Toast.show(title: title, body: body, ok: ok) } }
            }
        }
    }

    // 메뉴 막대 앱이어도 배너가 뜨게
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound, .list])
    }

    // 실패 알림: "다시 시도" → 다시 붙이기, 알림 자체나 "진단 보기" → 진단 로그
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler handler: @escaping () -> Void) {
        let failed = response.notification.request.content.categoryIdentifier == "fail"
        DispatchQueue.main.async {
            if response.actionIdentifier == "retry" { self.onRetry() }
            else if failed { NSWorkspace.shared.open(logURL) }
        }
        handler()
    }
}

/// 화면 오른쪽 위에 앱 아이콘이 들어간 팝업을 잠깐 띄운다 (알림 권한이 없을 때)
enum Toast {
    static var panel: NSPanel?

    static func show(title: String, body: String, ok: Bool) {
        panel?.close()
        let w: CGFloat = 360, h: CGFloat = 80
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 16
        bg.layer?.masksToBounds = true
        let icon = NSImageView(frame: NSRect(x: 14, y: 16, width: 48, height: 48))
        icon.image = NSApp.applicationIconImage
        let t = NSTextField(labelWithString: title)
        t.font = .boldSystemFont(ofSize: 13)
        t.frame = NSRect(x: 74, y: 46, width: w - 88, height: 18)
        let b = NSTextField(wrappingLabelWithString: body)
        b.font = .systemFont(ofSize: 12)
        b.textColor = .secondaryLabelColor
        b.maximumNumberOfLines = 2
        b.frame = NSRect(x: 74, y: 10, width: w - 88, height: 34)
        [icon, t, b].forEach(bg.addSubview)
        p.contentView = bg

        if let s = NSScreen.main?.visibleFrame { p.setFrameOrigin(NSPoint(x: s.maxX - w - 16, y: s.maxY - h - 12)) }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; p.animator().alphaValue = 1 }
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 4 : 8)) {
            guard panel === p else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 }) {
                p.close()
                if panel === p { panel = nil }
            }
        }
    }
}

// MARK: - 명령 실행 (출력은 임시 파일로 받아 데몬이 파이프를 잡고 있어도 막히지 않게)

@discardableResult
func run(_ path: String, _ args: [String], env: [String: String] = [:], timeout: TimeInterval = 15) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: tmp.path, contents: nil)
    guard let h = try? FileHandle(forWritingTo: tmp) else { return (-1, "") }
    p.standardOutput = h; p.standardError = h
    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    do { try p.run() } catch { return (-1, "\(error)") }
    if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); _ = done.wait(timeout: .now() + 2) }
    try? h.close()
    let out = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
    try? FileManager.default.removeItem(at: tmp)
    return (p.isRunning ? -2 : p.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
}

func portOpen(_ port: UInt16 = 5037) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
}

func waitUntil(_ seconds: Int, _ cond: () -> Bool) -> Bool {
    for _ in 0..<seconds {
        if cond() { return true }
        Thread.sleep(forTimeInterval: 1)
    }
    return cond()
}

// MARK: - 휴대폰 찾기 (이 앱의 로컬 네트워크 권한도 함께 확인)

enum PhoneResult: Equatable {
    case found(String)          // "IP:포트", 이 앱에서 TCP 접속까지 성공
    case unreachable(String)    // mDNS로는 보이지만 접속 실패
    case permissionDenied       // 이 앱에 로컬 네트워크 권한 없음
    case notFound               // 무선 디버깅을 알리는 기기가 없음
}

func findPhone(timeout: TimeInterval = 8) -> PhoneResult {
    let q = DispatchQueue(label: "phone")
    let sem = DispatchSemaphore(value: 0)
    var result: PhoneResult?
    var denied = false
    var seen: String?               // mDNS로 발견한 휴대폰 이름
    var conn: NWConnection?
    func finish(_ r: PhoneResult) { if result == nil { result = r; sem.signal() } }   // q 위에서만 호출

    let tcp = NWParameters.tcp
    if let ip = tcp.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
    let browser = NWBrowser(for: .bonjour(type: "_adb-tls-connect._tcp", domain: "local."), using: NWParameters())
    browser.stateUpdateHandler = { st in
        switch st {
        case .waiting(let e), .failed(let e):
            if case .dns(let code) = e, code == -65570 { denied = true }   // kDNSServiceErr_PolicyDenied
            log(L("  mDNS 탐색 상태: ", "  mDNS browse state: ") + "\(e)")
        default: break
        }
    }
    browser.browseResultsChangedHandler = { results, _ in
        guard conn == nil, let r = results.first, case .service(let name, _, _, _) = r.endpoint else { return }
        log(L("  mDNS: 휴대폰 발견 ", "  mDNS: found phone ") + name)
        seen = name
        let c = NWConnection(to: r.endpoint, using: tcp)
        conn = c
        c.stateUpdateHandler = { s in
            switch s {
            case .ready:
                if case .hostPort(let host, let port)? = c.currentPath?.remoteEndpoint {
                    var h = "\(host)"
                    if let i = h.firstIndex(of: "%") { h = String(h[..<i]) }
                    finish(.found("\(h):\(port.rawValue)"))
                } else {
                    finish(.unreachable(name))
                }
            case .waiting(let e), .failed(let e):
                log(L("  휴대폰 접속 테스트 실패: ", "  Phone reachability test failed: ") + "\(e)")
                if case .dns(let code) = e, code == -65570 { denied = true }
                finish(.unreachable(name))
            default: break
            }
        }
        c.start(queue: q)
    }
    browser.start(queue: q)

    if sem.wait(timeout: .now() + timeout) == .timedOut, q.sync(execute: { denied }) {
        // 첫 실행이면 권한 요청 창이 떠 있는 중 → 사용자가 누를 시간을 준다
        log(L("  로컬 네트워크 권한 요청 대기 중…", "  Waiting for Local Network permission…"))
        _ = sem.wait(timeout: .now() + 25)
    }
    let r: PhoneResult = q.sync {
        if let result { return result }
        if denied { return .permissionDenied }
        if let seen { log(L("  휴대폰 접속 테스트 시간 초과", "  Phone reachability test timed out")); return .unreachable(seen) }
        return .notFound
    }
    browser.cancel(); conn?.cancel()
    return r
}

// MARK: - 전략

enum Strategy: String, CaseIterable {
    case reconnectOffline, connectOnly, ownServer, ownServerBonjour, terminalNoItda

    var title: String {
        switch self {
        case .reconnectOffline: return L("offline 기기 재연결", "Reconnect offline device")
        case .connectOnly: return L("서버 유지 + IP:포트 직접 연결", "Keep server, connect to IP:port")
        case .ownServer: return L("앱이 adb 서버 재시작", "Restart adb server (owned by app)")
        case .ownServerBonjour: return L("앱이 adb 서버 재시작 (macOS mDNS 백엔드)", "Restart adb server (macOS mDNS backend)")
        case .terminalNoItda: return L("터미널에서 서버 실행", "Start server from Terminal")
        }
    }
}

struct Device {
    let serial: String
    let state: String
    var model: String? = nil
    var isIPPort: Bool { serial.range(of: #"^\d+\.\d+\.\d+\.\d+:\d+$"#, options: .regularExpression) != nil }
    var isWireless: Bool { isIPPort || serial.contains("._adb-tls-connect.") }
}

final class Reviver {
    private(set) var adb: String?
    private(set) var server: Process?       // 앱이 소유한 nodaemon 서버
    private var causes: [String] = []
    private var permissionCause = false
    /// 마지막 다시 붙이기에서 로컬 네트워크 권한 문제가 보였는지 → 메뉴의 '로컬 네트워크 권한 열기'를 보여 줌
    private(set) var needsPermission = false
    /// 다시 붙이기와 페어링이 동시에 서버를 띄우지 않게 (서버를 바꾸는 작업은 한 번에 하나)
    private let serverLock = NSRecursiveLock()
    private let defaults = UserDefaults.standard

    var winner: Strategy? {
        get { defaults.string(forKey: "winner").flatMap(Strategy.init) }
        set { defaults.set(newValue?.rawValue, forKey: "winner") }
    }
    var lastAddr: String? {
        get { defaults.string(forKey: "lastAddr") }
        set { defaults.set(newValue, forKey: "lastAddr") }
    }

    init() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        refreshAdb()
    }

    /// Android SDK(Android Studio)의 adb를 먼저 쓴다 — 버전이 다르면 서로 서버를 죽여 연결이 끊긴다
    static func findAdb() -> String? {
        let env = ProcessInfo.processInfo.environment
        var dirs = [home.path + "/Library/Android/sdk/platform-tools"]
        dirs += [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"]].compactMap { $0 }.map { $0 + "/platform-tools" }
        dirs += [platformToolsDir.path, "/opt/homebrew/bin", "/usr/local/bin"]
        return dirs.map { $0 + "/adb" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func refreshAdb() { adb = Reviver.findAdb() }

    /// adb mdns services → (이름, 종류, IP:포트). 페어링 QR을 찍은 휴대폰을 찾을 때 사용
    func mdnsServices() -> [(name: String, type: String, addr: String)] {
        guard let adb, portOpen() else { return [] }
        return run(adb, ["mdns", "services"], timeout: 6).out.split(separator: "\n").compactMap { line in
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            return f.count >= 3 && f[1].hasPrefix("_adb") ? (f[0], f[1], f[2]) : nil
        }
    }

    /// 페어링 등에서 쓰기 전에 앱 소유 서버를 준비한다
    func ensureServer() -> Bool {
        serverLock.lock(); defer { serverLock.unlock() }
        refreshAdb()
        guard adb != nil else { return false }
        if let s = server, s.isRunning, serverOwner()?.pid == s.processIdentifier { return true }
        stopServer()
        return startOwnServer(env: [:])
    }

    // 서버가 없을 때 `adb devices`를 부르면 이 자리에서 서버가 떠버리므로 포트부터 확인
    func devices() -> [Device] {
        guard let adb, portOpen() else { return [] }
        let out = run(adb, ["devices", "-l"], timeout: 5).out
        if out.contains("doesn't match this client") { addCause(L("adb 버전 불일치 → 다른 adb(Android Studio 등)가 서버를 띄움", "adb version mismatch → another adb (Android Studio, etc.) started the server")) }
        return out.split(separator: "\n").dropFirst().compactMap { line in
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count >= 2 else { return nil }
            let model = f.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: "-") }
            return Device(serial: String(f[0]), state: String(f[1]), model: model)
        }
    }

    /// 무선으로 연결된 기기 (USB 연결은 "붙었다"로 치지 않음)
    func connected() -> Device? { devices().first { $0.state == "device" && $0.isWireless } }

    /// 패널에 보여 줄 휴대폰 이름(설정의 기기 이름, 없으면 모델)·Android 버전·IP:포트
    func phoneInfo(_ d: Device) -> (name: String, android: String?, addr: String?) {
        guard let adb else { return (d.model ?? d.serial, nil, nil) }
        func shell(_ args: [String]) -> String? {
            let r = run(adb, ["-s", d.serial, "shell"] + args, timeout: 5)
            return r.code == 0 && !r.out.isEmpty && r.out != "null" ? r.out : nil
        }
        let name = shell(["settings", "get", "global", "device_name"]) ?? d.model ?? d.serial
        let addr = d.isIPPort ? d.serial : mdnsServices().first { d.serial.hasPrefix($0.name + ".") }?.addr ?? lastAddr
        return (name, shell(["getprop", "ro.build.version.release"]), addr)
    }

    /// "36.0.0" (adb version 둘째 줄 "Version 36.0.0-13206524")
    func adbVersion() -> String? {
        guard let adb else { return nil }
        return run(adb, ["version"], timeout: 5).out.split(separator: "\n").first { $0.hasPrefix("Version ") }
            .map { String($0.dropFirst(8).split(separator: "-").first ?? "") }
    }

    /// 5037 포트를 연 프로세스와 그 부모 계보. 예) "adb ← zsh ← launchd"
    func serverOwner() -> (pid: Int32, chain: String)? {
        let out = run("/usr/sbin/lsof", ["-nP", "-iTCP:5037", "-sTCP:LISTEN", "-t"], timeout: 5).out
        guard let first = out.split(separator: "\n").first, let pid = Int32(first) else { return nil }
        var names: [String] = []
        var cur = pid
        for _ in 0..<6 where cur > 1 {
            let o = run("/bin/ps", ["-o", "ppid=,comm=", "-p", "\(cur)"], timeout: 3).out
            let parts = o.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pp = Int32(parts[0]) else { break }
            names.append((String(parts[1]) as NSString).lastPathComponent)
            if pp == 1 { names.append(L("launchd(데몬, 띄운 프로그램 불명)", "launchd (daemon, parent unknown)")) }
            cur = pp
        }
        return (pid, names.joined(separator: " ← "))
    }

    /// permission: 로컬 네트워크 권한 문제를 가리키는 원인 (→ 권한 메뉴를 보여 줌)
    private func addCause(_ c: String, permission: Bool = false) {
        if permission { permissionCause = true }
        if !causes.contains(c) { causes.append(c); log(L("  원인 후보: ", "  Possible cause: ") + c) }
    }

    // MARK: 메인 루틴

    func revive() -> (ok: Bool, message: String) {
        serverLock.lock(); defer { serverLock.unlock() }
        log(L("===== 다시 붙이기 시작", "===== Reconnect started"))
        causes = []
        permissionCause = false
        refreshAdb()
        guard adb != nil else { return finish(false, L("adb를 찾을 수 없어요. 설정에서 adb를 설치해 주세요.", "adb not found. Install it from Settings.")) }

        // 1) 진단
        let before = devices()
        log(L("진단: 기기 = ", "Diagnosis: devices = ") + "\(before.map { "\($0.serial)(\($0.state))" })")
        if let d = before.first(where: { $0.state == "device" && $0.isWireless }) {
            return finish(true, L("이미 연결되어 있어요: ", "Already connected: ") + d.serial)
        }
        let owner = serverOwner()
        let ownsServer = owner != nil && owner?.pid == server?.processIdentifier
        if let owner {
            log(L("진단: adb 서버 소유 = ", "Diagnosis: adb server owner = ") + (ownsServer ? L("이 앱", "this app") : owner.chain))
            if !ownsServer { addCause(L("adb 서버를 다른 프로그램({0})이 띄움 → 그 프로그램에 로컬 네트워크 권한이 없으면 휴대폰에 못 붙음", "Another program ({0}) started the adb server → it can't reach the phone without Local Network permission", owner.chain), permission: true) }
        } else {
            log(L("진단: adb 서버 꺼져 있음", "Diagnosis: adb server not running"))
        }
        if before.contains(where: { $0.state == "offline" }) { addCause(L("기기가 offline 상태로 남아 있음", "Device is stuck offline")) }
        if before.contains(where: { $0.state == "unauthorized" }) { addCause(L("휴대폰에서 디버깅 허용 필요 (unauthorized)", "Allow debugging on the phone (unauthorized)")) }

        var phone = findPhone()
        log(L("진단: 휴대폰 = ", "Diagnosis: phone = ") + "\(phone)")
        switch phone {
        case .found(let a): lastAddr = a
        case .unreachable: addCause(L("휴대폰은 보이지만 이 앱에서 접속 불가 → 로컬 네트워크 권한 또는 네트워크(VPN 등) 문제", "Phone is visible but unreachable from this app → Local Network permission or network (VPN, etc.)"), permission: true)
        case .permissionDenied: addCause(L("이 앱에 로컬 네트워크 권한 없음 → 시스템 설정 > 개인정보 보호 및 보안 > 로컬 네트워크에서 허용", "This app has no Local Network permission → allow it in System Settings > Privacy & Security > Local Network"), permission: true)
        case .notFound: addCause(L("휴대폰이 보이지 않음 → 무선 디버깅 꺼짐 / 화면 꺼짐·절전 / 다른 Wi‑Fi", "Phone not visible → wireless debugging off / screen off or power saving / different Wi‑Fi"))
        }

        // 2) 시도 순서: 끊지 않는 방법 → 기억한 방법 → 나머지
        var order: [Strategy] = []
        if before.contains(where: { $0.state == "offline" }) { order.append(.reconnectOffline) }
        if ownsServer, case .found = phone { order.append(.connectOnly) }
        let quick = order.count
        if phone != .permissionDenied { order += [.ownServer, .ownServerBonjour] }
        if phone != .notFound { order.append(.terminalNoItda) }
        // 터미널 폴백은 창이 뜨고 Terminal이 창을 복원하며 다시 실행해서, 기억해도 앞당기지 않는다 (앱 서버가 먼저)
        if let w = winner, w != .terminalNoItda, let i = order.firstIndex(of: w), i > quick {
            order.remove(at: i); order.insert(w, at: quick)
        }
        log(L("시도 순서: ", "Order: ") + "\(order.map(\.title))")

        // 3) 순서대로 시도, 붙으면 종료
        for s in order {
            log(L("▶ 시도: ", "▶ Trying: ") + s.title)
            if attempt(s, phone: phone) {
                winner = s
                needsPermission = s == .terminalNoItda   // 터미널로만 붙으면 앱에는 권한이 없는 것
                if let d = connected(), d.isIPPort { lastAddr = d.serial }
                return finish(true, L("다시 붙었어요 — ", "Reconnected — ") + s.title)
            }
            log(L("  실패: ", "  Failed: ") + s.title)
            if s == .ownServer, phone == .notFound {
                phone = findPhone(timeout: 4)    // 그 사이 휴대폰이 깨어났는지 다시 확인
            }
        }

        var needsPermission = permissionCause
        if case .unreachable = phone { needsPermission = true }
        self.needsPermission = needsPermission
        if needsPermission { NSWorkspace.shared.open(localNetworkSettings) }
        return finish(false, causes.first ?? L("원인을 찾지 못했어요 — 진단 보기를 확인해 주세요", "Unknown cause — check Diagnostics"))
    }

    private func finish(_ ok: Bool, _ msg: String) -> (Bool, String) {
        if !ok && causes.count > 1 { log(L("원인 후보 전체:", "All possible causes:") + "\n  - " + causes.joined(separator: "\n  - ")) }
        log(L("결과: ", "Result: ") + msg)
        return (ok, msg)
    }

    // MARK: 전략 실행

    private func attempt(_ s: Strategy, phone: PhoneResult) -> Bool {
        guard let adb else { return false }
        switch s {
        case .reconnectOffline:
            run(adb, ["reconnect", "offline"], timeout: 10)
            return waitUntil(5) { connected() != nil }
        case .connectOnly:
            return connectCandidates(phone)
        case .ownServer, .ownServerBonjour:
            stopServer()
            guard startOwnServer(env: s == .ownServerBonjour ? ["ADB_MDNS_OPENSCREEN": "0"] : [:]) else { return false }
            return waitUntil(10) { connected() != nil } || connectCandidates(phone)
        case .terminalNoItda:
            stopServer()
            guard startTerminalServer() else { return false }
            return waitUntil(10) { connected() != nil } || connectCandidates(phone)
        }
    }

    private func connectCandidates(_ phone: PhoneResult) -> Bool {
        guard let adb else { return false }
        var addrs: [String] = []
        if case .found(let a) = phone { addrs.append(a) }
        if let a = lastAddr, !addrs.contains(a) { addrs.append(a) }
        for a in addrs {
            let out = run(adb, ["connect", a], timeout: 12).out
            log("  adb connect \(a): \(out)")
            let l = out.lowercased()
            if l.contains("no route to host") { addCause(L("No route to host → adb 서버를 띄운 프로그램에 로컬 네트워크 권한 없음 (또는 다른 네트워크)", "No route to host → the program running the adb server has no Local Network permission (or different network)"), permission: true) }
            if l.contains("connection refused") { addCause(L("Connection refused → 무선 디버깅 포트가 바뀌었거나 꺼짐", "Connection refused → wireless debugging port changed or turned off")) }
            if l.contains("authenticat") { addCause(L("인증 실패 → 이 Mac과 페어링이 안 됨. 메뉴의 '휴대폰 페어링'으로 다시 페어링하세요", "Authentication failed → this Mac isn't paired. Use 'Pair phone' in the menu")) }
            if l.contains("timed out") { addCause(L("시간 초과 → 휴대폰 절전 / 다른 Wi‑Fi / VPN 경로", "Timed out → phone asleep / different Wi‑Fi / VPN route")) }
            if waitUntil(3, { connected() != nil }) { return true }
        }
        return false
    }

    func stopServer() {
        if let adb, portOpen() { run(adb, ["kill-server"], timeout: 5) }
        server?.terminate()
        server = nil
        if !waitUntil(5, { !portOpen() }), let o = serverOwner() {
            log(L("  서버가 안 꺼져서 강제 종료: ", "  Server did not stop, killing: ") + "pid \(o.pid) (\(o.chain))")
            kill(o.pid, SIGTERM)
            _ = waitUntil(3) { !portOpen() }
        }
    }

    func startOwnServer(env: [String: String]) -> Bool {
        guard let adb else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = ["nodaemon", "server"]
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        if !FileManager.default.fileExists(atPath: serverLogURL.path) {
            FileManager.default.createFile(atPath: serverLogURL.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: serverLogURL) {
            h.seekToEndOfFile(); p.standardOutput = h; p.standardError = h
        }
        p.terminationHandler = { log(L("  (앱의 adb 서버 종료, 코드 ", "  (app's adb server exited, code ") + "\($0.terminationStatus))") }
        do { try p.run() } catch { log(L("  서버 실행 실패: ", "  Failed to start server: ") + "\(error)"); return false }
        server = p
        let ok = waitUntil(5) { portOpen() }
        log(L("  앱 소유 서버 시작 pid ", "  Started app-owned server pid ") + "\(p.processIdentifier) \(env.isEmpty ? "" : "\(env)") → " + (ok ? "OK" : L("포트 안 열림", "port not open")))
        return ok
    }

    /// itda(.zshrc 자동 세션)를 끈 별도 Terminal에서 서버를 띄운다 — 앱 권한이 없을 때의 폴백
    private func startTerminalServer() -> Bool {
        guard let adb else { return false }
        let file = supportDir.appendingPathComponent("adb-server.terminal")
        let plist: [String: Any] = [
            "name": appShortName, "type": "Window Settings", "ProfileCurrentVersion": 2.07,
            "CommandString": "\(adb) nodaemon server", "RunCommandAsShell": false, "shellExitAction": 0,
        ]
        (plist as NSDictionary).write(to: file, atomically: true)
        run("/usr/bin/open", ["-n", "-a", "Terminal", "--env", "ITDA_DISABLE=1", file.path], timeout: 10)
        let ok = waitUntil(10) { portOpen() }
        if ok, let o = serverOwner() { log(L("  터미널 서버 소유: ", "  Terminal server owner: ") + o.chain) }
        return ok
    }

    func shutdown() {
        server?.terminate()
    }
}

// MARK: - 메뉴 막대 UI

/// 메뉴 막대 상태 아이콘: 사용자 심볼(안드로이드 머리 + 전파). 몸체는 검정(밝은 막대)·흰색(어두운 막대), 전파는 상태색
/// labelColor는 메뉴 막대에서 반투명 회색(#585858)으로 풀려 몸체·전파가 같은 회색이 돼서 쓰지 않는다
/// 회색 = 연결됨 (초록은 메뉴 막대에서 잘 안 보여서, 2026-10-22 사용자 결정), 빨강 = 끊김, 주황 = 다시 붙이는 중
enum LinkState { case connected, disconnected, working }

/// 모양 마스크 (assets/make_icons.sh → 앱 Resources)
let statusMasks = (body: Bundle.main.image(forResource: "status-body"), waves: Bundle.main.image(forResource: "status-waves"))

/// 그림은 16pt, 좌우 4pt·위아래 1pt를 비운다 — 다른 메뉴 막대 아이콘들과 높이·앞뒤 간격(약 22pt)을 맞춤 (2026-10-28)
func statusImage(_ state: LinkState) -> NSImage {
    let img = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { bounds in
        let rect = bounds.insetBy(dx: 4, dy: 1)
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let waves: NSColor = state == .connected ? (dark ? NSColor(white: 0.63, alpha: 1) : NSColor(white: 0.29, alpha: 1))
            : state == .disconnected ? NSColor(srgbRed: 1, green: 0.22, blue: 0.24, alpha: 1)
            : NSColor(srgbRed: 0.98, green: 0.70, blue: 0.20, alpha: 1)
        // 마스크를 그린 자리만 색으로 칠한다
        func paint(_ mask: NSImage?, _ color: NSColor) {
            guard let mask, let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            mask.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            ctx.endTransparencyLayer()
        }
        paint(statusMasks.body, dark ? .white : .black)
        paint(statusMasks.waves, waves)
        return true
    }
    img.isTemplate = false
    img.accessibilityDescription = appShortName
    return img
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let reviver = Reviver()
    let queue = DispatchQueue(label: "revive")
    var item: NSStatusItem!
    /// 연결 상태에 따라: 연결됨 · 기기 이름(누를 수 없음) / 연결하는 중… / 기기 다시 연결하기
    let reviveItem = NSMenuItem(title: L("확인 중…", "Checking…"), action: #selector(reviveNow), keyEquivalent: "r")
    let loginItem = NSMenuItem(title: L("로그인할 때 자동 실행", "Launch at login"), action: #selector(toggleLogin), keyEquivalent: "")
    let permissionItem = NSMenuItem(title: L("로컬 네트워크 권한 열기", "Open Local Network settings"), action: #selector(openSettings), keyEquivalent: "")
    let mirror = ScreenMirror()
    let mirrorItem = NSMenuItem(title: L("화면 미러링 시작하기", "Start screen mirroring"), action: #selector(mirrorNow), keyEquivalent: "m")
    let updater = Updater()
    let updateItem = NSMenuItem(title: "", action: #selector(updateClicked), keyEquivalent: "")
    let mirrorOptions = NSMenu()
    var busy = false
    var setupWindow: NSWindow?
    var pairWindow: NSWindow?
    /// 오른쪽 클릭 메뉴 (왼쪽 클릭은 카드형 패널)
    let classicMenu = NSMenu()
    lazy var panelModel = PanelModel(mirror: mirror)
    var panel: MenuPanel!
    /// 연결된 휴대폰 정보 — queue 위에서만 읽고 쓴다 (기기가 바뀔 때만 휴대폰에 다시 물어봄)
    private var phoneCache: PhoneInfo?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = statusImage(.working)
        let menu = classicMenu
        menu.autoenablesItems = false   // 항목 활성/비활성은 상태에 따라 직접 정한다
        loginItem.target = self; menu.addItem(loginItem)
        menu.addItem(withTitle: L("휴대폰 페어링…", "Pair phone…"), action: #selector(showPair), keyEquivalent: "p").target = self
        permissionItem.target = self; permissionItem.isHidden = true; menu.addItem(permissionItem)
        menu.addItem(.separator())
        reviveItem.target = self; menu.addItem(reviveItem)
        mirrorItem.target = self; menu.addItem(mirrorItem)
        let optionsItem = NSMenuItem(title: L("미러링 옵션", "Mirroring options"), action: nil, keyEquivalent: "")
        optionsItem.submenu = mirrorOptions
        buildMirrorOptions()
        menu.addItem(optionsItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: L("설정…", "Settings…"), action: #selector(showSetup), keyEquivalent: ",").target = self
        menu.addItem(withTitle: L("진단 보기", "Diagnostics"), action: #selector(openLog), keyEquivalent: "l").target = self
        updateItem.target = self; menu.addItem(updateItem)
        menu.addItem(withTitle: L("종료 (adb 서버도 종료)", "Quit (stops adb server)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.button?.target = self
        item.button?.action = #selector(statusClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        panelModel.appVersion = updater.current
        panelModel.lastName = UserDefaults.standard.string(forKey: "lastPhoneName")
        panelModel.act = { [weak self] in self?.panelAction($0) }
        panel = MenuPanel(model: panelModel)
        // adb 버전 (바닥 표시) — 다시 붙이는 동안에도 보이게 queue 밖에서
        DispatchQueue.global().async { [weak self] in
            let v = self?.reviver.adbVersion()
            DispatchQueue.main.async { self?.panelModel.adbVersion = v }
        }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
        // 업데이트: 실행할 때, 그 뒤 한 시간마다 '일주일이 지났는지' 보고 확인
        updater.onChange = { [weak self] in self?.updateUpdateItem() }
        updateUpdateItem()
        updater.checkIfDue()
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.updater.checkIfDue() }
        Notifier.shared.onRetry = { [weak self] in self?.reviveNow() }
        mirror.onExit = { [weak self] code, byUser in self?.mirrorDidExit(code: code, byUser: byUser) }
        Notifier.shared.setup()

        // 옮긴 직후: 미리 고른 '로그인 시 자동 실행' 적용
        if CommandLine.arguments.contains("--after-move"), UserDefaults.standard.bool(forKey: "wantLogin") {
            AppInstall.setLoginItem(true)
        }
        // 처음이거나(응용 프로그램 폴더 밖) adb가 없으면 설치 마법사, 옮긴 직후엔 이어서
        let firstRun = !AppInstall.isInApplications && !UserDefaults.standard.bool(forKey: "setupShown")
        if reviver.adb == nil || firstRun || CommandLine.arguments.contains("--after-move") { showSetup() }
        if reviver.adb != nil { reviveNow() }
    }

    // 이미 실행 중일 때 앱 아이콘을 다시 누르면 → 다시 붙이기
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reviveNow(); return false
    }

    func applicationWillTerminate(_ n: Notification) { mirror.stop(); reviver.shutdown() }

    // MARK: 화면 미러링 (scrcpy)

    func buildMirrorOptions() {
        mirrorOptions.removeAllItems()
        for q in MirrorQuality.allCases {
            let i = NSMenuItem(title: q.title, action: #selector(setQuality(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = q.rawValue; i.state = mirror.quality == q ? .on : .off
            mirrorOptions.addItem(i)
        }
        mirrorOptions.addItem(.separator())
        let toggles: [(String, Selector, Bool)] = [
            (L("소리도 전송", "Forward audio"), #selector(toggleAudio), mirror.audio),
            (L("창을 항상 위에", "Window always on top"), #selector(toggleOnTop), mirror.alwaysOnTop),
            (L("미러링 중 폰 화면 끄기", "Turn phone screen off"), #selector(toggleScreenOff), mirror.turnScreenOff),
            (L("동영상으로 녹화 (Movies 폴더)", "Record to Movies folder"), #selector(toggleRecord), mirror.record),
        ]
        for (t, sel, on) in toggles {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            i.target = self; i.state = on ? .on : .off
            mirrorOptions.addItem(i)
        }
        mirrorOptions.addItem(.separator())
        mirrorOptions.addItem(withTitle: L("미러링 로그 보기", "Mirroring log"), action: #selector(openMirrorLog), keyEquivalent: "").target = self
        let note = NSMenuItem(title: L("옵션은 다음 미러링부터 적용돼요", "Options apply to the next mirroring session"), action: nil, keyEquivalent: "")
        note.isEnabled = false
        mirrorOptions.addItem(note)
        panelModel.objectWillChange.send()
    }

    @objc func setQuality(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let q = MirrorQuality(rawValue: raw) { mirror.quality = q }
        buildMirrorOptions()
    }
    @objc func toggleAudio() { mirror.audio.toggle(); buildMirrorOptions() }
    @objc func toggleOnTop() { mirror.alwaysOnTop.toggle(); buildMirrorOptions() }
    @objc func toggleScreenOff() { mirror.turnScreenOff.toggle(); buildMirrorOptions() }
    @objc func toggleRecord() { mirror.record.toggle(); buildMirrorOptions() }
    @objc func openMirrorLog() { NSWorkspace.shared.open(mirrorLogURL) }

    /// 미러링 시작/중지. 끊겨 있으면 먼저 다시 붙인 뒤 띄운다.
    @objc func mirrorNow() {
        if mirror.isRunning {
            mirror.stop()
            updateMirrorItem()
            return
        }
        guard ScreenMirror.isInstalled else {
            Toast.show(title: L("scrcpy가 필요해요", "scrcpy is required"),
                       body: L("설정 창에서 '화면 미러링(scrcpy)도 설치'를 켜 주세요.", "Turn on 'Also install screen mirroring (scrcpy)' in Settings."), ok: false)
            openSetup(step: .install)
            return
        }
        guard !busy else { return }
        busy = true
        mirrorItem.isEnabled = false
        show(.working, L("미러링 준비 중…", "Preparing mirroring…"))
        queue.async {
            var d = self.reviver.connected()
            if d == nil {
                log(L("미러링 전 다시 붙이기", "Reconnecting before mirroring"))
                let r = self.reviver.revive()
                d = r.ok ? self.reviver.connected() : nil
                if d == nil { Notifier.shared.post(ok: false, title: L("연결하지 못했어요", "Couldn't reconnect"), body: r.message) }
            }
            if let d, let adb = self.reviver.adb {
                let r = self.mirror.start(adb: adb, serial: d.serial, title: (d.model ?? L("휴대폰", "Phone")) + " · " + appShortName)
                if !r.ok { Notifier.shared.post(ok: false, title: L("미러링을 시작하지 못했어요", "Couldn't start mirroring"), body: r.message) }
            }
            DispatchQueue.main.async {
                self.busy = false
                self.mirrorItem.isEnabled = true
                self.refresh()
            }
        }
    }

    func mirrorDidExit(code: Int32, byUser: Bool) {
        // 사용자가 창을 닫거나 메뉴에서 중지한 경우는 조용히. 그 밖(연결 끊김 등)은 알림.
        if !byUser && code != 0 {
            Notifier.shared.post(ok: false, title: L("미러링이 끊겼어요", "Mirroring stopped"),
                                 body: L("무선 연결이 끊겼을 수 있어요. ⌘M으로 다시 붙이고 미러링해요.", "Wireless debugging may have dropped. Press ⌘M to reconnect and mirror again."))
        }
        refresh()
    }

    func updateMirrorItem() {
        mirrorItem.title = mirror.isRunning ? L("화면 미러링 중지", "Stop screen mirroring") : L("화면 미러링 시작하기", "Start screen mirroring")
        panelModel.mirroring = mirror.isRunning
    }

    /// 메뉴 막대 아이콘 + '기기 다시 연결하기' 자리. 끊겼을 때만 누를 수 있다
    func show(_ state: LinkState, _ title: String) {
        item.button?.image = statusImage(state)
        item.button?.toolTip = "\(appShortName) — \(title)"
        reviveItem.title = title
        reviveItem.isEnabled = state == .disconnected
        panelModel.link = state
        panelModel.status = title
    }

    @objc func reviveNow() {
        guard !busy else { return }
        busy = true
        show(.working, L("연결하는 중…", "Connecting…"))
        let started = Date()
        queue.async {
            let r = self.reviver.revive()
            let d = self.reviver.connected()
            let secs = max(1, Int(Date().timeIntervalSince(started).rounded()))
            if r.ok {
                Notifier.shared.post(ok: true, title: L("다시 연결됐어요", "Reconnected"), body: "\(d?.model ?? d?.serial ?? L("휴대폰", "Phone")) · " + L("{0}초 걸렸어요", "took {0}s", secs))
            } else {
                Notifier.shared.post(ok: false, title: L("연결하지 못했어요", "Couldn't reconnect"), body: r.message)
            }
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
            }
        }
    }

    func refresh() {
        guard !busy else { return }
        queue.async {
            let d = self.reviver.connected()
            if let d {
                if self.phoneCache?.serial != d.serial {
                    let p = self.reviver.phoneInfo(d)
                    self.phoneCache = PhoneInfo(serial: d.serial, name: p.name, android: p.android, addr: p.addr, since: Date())
                }
            } else {
                self.phoneCache = nil
            }
            let info = self.phoneCache
            DispatchQueue.main.async {
                if let info {
                    self.panelModel.lastName = info.name
                    UserDefaults.standard.set(info.name, forKey: "lastPhoneName")
                }
                if self.panelModel.phone != info { self.panelModel.phone = info }
                guard !self.busy else { return }
                if let d {
                    self.show(.connected, L("연결됨 · ", "Connected · ") + (d.model ?? L("휴대폰", "Phone")) + (self.mirror.isRunning ? L(" · 미러링 중", " · Mirroring") : ""))
                } else {
                    self.show(.disconnected, L("기기 다시 연결하기", "Reconnect device"))
                }
                self.permissionItem.isHidden = !self.reviver.needsPermission
                self.panelModel.needsPermission = self.reviver.needsPermission
                self.loginItem.state = AppInstall.loginItemEnabled ? .on : .off
                self.updateMirrorItem()
            }
        }
    }

    // MARK: 카드형 패널

    /// 왼쪽 클릭 = 패널 열기/닫기, 오른쪽 클릭·control-클릭 = 예전 메뉴
    @objc func statusClicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            panel.close()
            item.menu = classicMenu
            sender.performClick(nil)
            item.menu = nil
            return
        }
        if panel.isShown { panel.close(); return }
        panelModel.now = Date()
        panel.show(below: sender)
        refresh()
    }

    func panelAction(_ a: PanelAction) {
        switch a {
        case .mirror: panel.close(); mirrorNow()
        case .reconnect: reviveNow()
        case .copyAddress:
            if let addr = panelModel.phone?.addr {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(addr, forType: .string)
            }
        case .pair: panel.close(); showPair()
        case .diagnostics: panel.close(); openLog()
        case .permission: panel.close(); openSettings()
        case .update: updateClicked()
        case .settings: panel.close(); showSetup()
        case .quit: NSApp.terminate(nil)
        case .mirrorLog: panel.close(); openMirrorLog()
        case .optionsChanged: buildMirrorOptions()
        }
    }

    @objc func showSetup() { openSetup(step: nil) }

    func openSetup(step: SetupModel.Step?) {
        UserDefaults.standard.set(true, forKey: "setupShown")
        if setupWindow == nil {
            setupWindow = makeSetupWindow(reviver: reviver, startAt: step, onAdbReady: { [weak self] in self?.reviveNow() },
                                          onClose: { [weak self] in self?.setupWindow = nil; self?.refresh() })
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.center()
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showPair() {
        if pairWindow == nil {
            pairWindow = makePairWindow(reviver: reviver, onClose: { [weak self] in self?.pairWindow = nil; self?.refresh() })
        }
        NSApp.activate(ignoringOtherApps: true)
        pairWindow?.center()
        pairWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func toggleLogin() {
        AppInstall.setLoginItem(!AppInstall.loginItemEnabled)
        loginItem.state = AppInstall.loginItemEnabled ? .on : .off
    }

    @objc func openLog() { NSWorkspace.shared.open(logURL) }

    // MARK: 업데이트

    func updateUpdateItem() {
        let v = updater.current
        panelModel.update = updater.state
        updateItem.view = nil
        switch updater.state {
        case .unknown:
            updateItem.title = L("업데이트 확인 ({0})", "Check for updates ({0})", v); updateItem.isEnabled = true
        case .latest:
            updateItem.title = L("최신 버전 ({0})", "Up to date ({0})", v); updateItem.isEnabled = false
        case .available(let n):
            updateItem.title = L("업데이트 ({0} → {1})", "Update ({0} → {1})", v, n); updateItem.isEnabled = true
        case .checking:
            updateItem.view = SpinnerMenuView(L("업데이트 확인 중…", "Checking for updates…"))
        case .installing(let n):
            updateItem.view = SpinnerMenuView(L("업데이트하는 중… ({0})", "Updating… ({0})", n))
        }
    }

    @objc func updateClicked() {
        if case .available = updater.state { updater.install() } else { updater.check() }
    }
    @objc func openSettings() { NSWorkspace.shared.open(localNetworkSettings) }
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--uninstall") {
    AppInstall.uninstall()
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    app.setActivationPolicy(.prohibited)
    saveSnapshots(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
