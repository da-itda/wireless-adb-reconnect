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

/// 화면 언어: OS의 첫 번째 선호 언어가 한국어면 한국어, 그 밖의 언어는 모두 영어 (WAR_LANG=ko|en 으로 강제 — 스냅샷용)
let isKorean: Bool = {
    if let forced = ProcessInfo.processInfo.environment["WAR_LANG"] { return forced == "ko" }
    return Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
}()
func L(_ ko: String, _ en: String) -> String { isKorean ? ko : en }
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

    private func addCause(_ c: String) {
        if !causes.contains(c) { causes.append(c); log(L("  원인 후보: ", "  Possible cause: ") + c) }
    }

    // MARK: 메인 루틴

    func revive() -> (ok: Bool, message: String) {
        serverLock.lock(); defer { serverLock.unlock() }
        log(L("===== 다시 붙이기 시작", "===== Reconnect started"))
        causes = []
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
            if !ownsServer { addCause(L("adb 서버를 다른 프로그램(\(owner.chain))이 띄움 → 그 프로그램에 로컬 네트워크 권한이 없으면 휴대폰에 못 붙음", "Another program (\(owner.chain)) started the adb server → it can't reach the phone without Local Network permission")) }
        } else {
            log(L("진단: adb 서버 꺼져 있음", "Diagnosis: adb server not running"))
        }
        if before.contains(where: { $0.state == "offline" }) { addCause(L("기기가 offline 상태로 남아 있음", "Device is stuck offline")) }
        if before.contains(where: { $0.state == "unauthorized" }) { addCause(L("휴대폰에서 디버깅 허용 필요 (unauthorized)", "Allow debugging on the phone (unauthorized)")) }

        var phone = findPhone()
        log(L("진단: 휴대폰 = ", "Diagnosis: phone = ") + "\(phone)")
        switch phone {
        case .found(let a): lastAddr = a
        case .unreachable: addCause(L("휴대폰은 보이지만 이 앱에서 접속 불가 → 로컬 네트워크 권한 또는 네트워크(VPN 등) 문제", "Phone is visible but unreachable from this app → Local Network permission or network (VPN, etc.)"))
        case .permissionDenied: addCause(L("이 앱에 로컬 네트워크 권한 없음 → 시스템 설정 > 개인정보 보호 및 보안 > 로컬 네트워크에서 허용", "This app has no Local Network permission → allow it in System Settings > Privacy & Security > Local Network"))
        case .notFound: addCause(L("휴대폰이 보이지 않음 → 무선 디버깅 꺼짐 / 화면 꺼짐·절전 / 다른 Wi‑Fi", "Phone not visible → wireless debugging off / screen off or power saving / different Wi‑Fi"))
        }

        // 2) 시도 순서: 끊지 않는 방법 → 기억한 방법 → 나머지
        var order: [Strategy] = []
        if before.contains(where: { $0.state == "offline" }) { order.append(.reconnectOffline) }
        if ownsServer, case .found = phone { order.append(.connectOnly) }
        let quick = order.count
        if phone != .permissionDenied { order += [.ownServer, .ownServerBonjour] }
        if phone != .notFound { order.append(.terminalNoItda) }
        if let w = winner, let i = order.firstIndex(of: w), i > quick {
            order.remove(at: i); order.insert(w, at: quick)
        }
        log(L("시도 순서: ", "Order: ") + "\(order.map(\.title))")

        // 3) 순서대로 시도, 붙으면 종료
        for s in order {
            log(L("▶ 시도: ", "▶ Trying: ") + s.title)
            if attempt(s, phone: phone) {
                winner = s
                if let d = connected(), d.isIPPort { lastAddr = d.serial }
                return finish(true, L("다시 붙었어요 — ", "Reconnected — ") + s.title)
            }
            log(L("  실패: ", "  Failed: ") + s.title)
            if s == .ownServer, phone == .notFound {
                phone = findPhone(timeout: 4)    // 그 사이 휴대폰이 깨어났는지 다시 확인
            }
        }

        var needsPermission = causes.contains { $0.contains("로컬 네트워크 권한") || $0.contains("Local Network permission") }
        if case .unreachable = phone { needsPermission = true }
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
            if l.contains("no route to host") { addCause(L("No route to host → adb 서버를 띄운 프로그램에 로컬 네트워크 권한 없음 (또는 다른 네트워크)", "No route to host → the program running the adb server has no Local Network permission (or different network)")) }
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

/// 메뉴 막대 상태 아이콘: 사용자 심볼(지그재그 선 + 양 끝 점). 선은 메뉴 막대 글자색, 점은 상태색
enum LinkState { case connected, disconnected, working }

func statusImage(_ state: LinkState) -> NSImage {
    let dot: NSColor = state == .connected ? NSColor(srgbRed: 0.24, green: 0.86, blue: 0.52, alpha: 1)
        : state == .disconnected ? NSColor(srgbRed: 0.87, green: 0.24, blue: 0.24, alpha: 1)
        : NSColor(srgbRed: 0.98, green: 0.70, blue: 0.20, alpha: 1)
    // 원본 1034×841 좌표(위→아래)를 22×18로 줄여 그린다 — 가는 선 버전(선 1.7pt, 점 지름 약 6pt)
    // (굵은 버전: 24×18, 선 2.4pt, 점 8pt, 여백 1.5pt — 2026-10-15 비교 후 사용자가 가는 버전 선택)
    let img = NSImage(size: NSSize(width: 22, height: 18), flipped: true) { _ in
        let k: CGFloat = 22.0 / 1034.0
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * k, y: y * k) }
        dot.setFill()
        NSBezierPath(ovalIn: NSRect(x: 138 * k - 3.1, y: 703 * k - 3.1, width: 6.2, height: 6.2)).fill()
        NSBezierPath(ovalIn: NSRect(x: 885 * k - 3.3, y: 148 * k - 3.3, width: 6.6, height: 6.6)).fill()
        let line = NSBezierPath()
        line.move(to: pt(148, 703)); line.line(to: pt(210, 295)); line.line(to: pt(808, 700)); line.line(to: pt(884, 140))
        line.lineWidth = 1.7
        line.lineCapStyle = .round
        line.lineJoinStyle = .miter
        NSColor.labelColor.setStroke()
        line.stroke()
        return true
    }
    img.isTemplate = false
    img.accessibilityDescription = appShortName
    return img
}

/// 메뉴 맨 위: 지금 상태와 기기
final class StatusHeader: NSView {
    let dot = NSView()
    let title = NSTextField(labelWithString: L("확인 중…", "Checking…"))
    let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 58))
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.frame = NSRect(x: 14, y: 11, width: 36, height: 36)
        dot.frame = NSRect(x: 60, y: 33, width: 8, height: 8)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 74, y: 29, width: 196, height: 17)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 60, y: 11, width: 210, height: 15)
        [icon, dot, title, detail].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ state: LinkState, _ title: String, _ detail: String) {
        dot.layer?.backgroundColor = (state == .connected ? NSColor.systemGreen : state == .disconnected ? NSColor.systemRed : NSColor.systemOrange).cgColor
        self.title.stringValue = title
        self.detail.stringValue = detail
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let reviver = Reviver()
    let queue = DispatchQueue(label: "revive")
    var item: NSStatusItem!
    let header = StatusHeader()
    let methodLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let reviveItem = NSMenuItem(title: L("지금 다시 붙이기", "Reconnect now"), action: #selector(reviveNow), keyEquivalent: "r")
    let loginItem = NSMenuItem(title: L("로그인할 때 자동 실행", "Launch at login"), action: #selector(toggleLogin), keyEquivalent: "")
    var busy = false
    var setupWindow: NSWindow?
    var pairWindow: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = statusImage(.working)
        let menu = NSMenu()
        let headerItem = NSMenuItem()
        headerItem.view = header
        menu.addItem(headerItem)
        methodLine.isEnabled = false
        menu.addItem(methodLine)
        menu.addItem(.separator())
        reviveItem.target = self; menu.addItem(reviveItem)
        menu.addItem(withTitle: L("휴대폰 페어링…", "Pair phone…"), action: #selector(showPair), keyEquivalent: "p").target = self
        menu.addItem(withTitle: L("진단 보기", "Diagnostics"), action: #selector(openLog), keyEquivalent: "l").target = self
        menu.addItem(.separator())
        loginItem.target = self; menu.addItem(loginItem)
        menu.addItem(withTitle: L("설정…", "Settings…"), action: #selector(showSetup), keyEquivalent: ",").target = self
        menu.addItem(withTitle: L("로컬 네트워크 권한 열기", "Open Local Network settings"), action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("종료 (adb 서버도 종료)", "Quit (stops adb server)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
        Notifier.shared.onRetry = { [weak self] in self?.reviveNow() }
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

    func applicationWillTerminate(_ n: Notification) { reviver.shutdown() }

    func show(_ state: LinkState, _ title: String, _ detail: String) {
        item.button?.image = statusImage(state)
        header.show(state, title, detail)
    }

    @objc func reviveNow() {
        guard !busy else { return }
        busy = true
        reviveItem.isEnabled = false
        show(.working, L("다시 붙이는 중…", "Reconnecting…"), L("원인을 찾고 순서대로 시도하고 있어요", "Finding the cause and trying fixes"))
        let started = Date()
        queue.async {
            let r = self.reviver.revive()
            let d = self.reviver.connected()
            let secs = max(1, Int(Date().timeIntervalSince(started).rounded()))
            if r.ok {
                Notifier.shared.post(ok: true, title: L("다시 연결됐어요", "Reconnected"), body: "\(d?.model ?? d?.serial ?? L("휴대폰", "Phone")) · " + L("\(secs)초 걸렸어요", "took \(secs)s"))
            } else {
                Notifier.shared.post(ok: false, title: L("연결하지 못했어요", "Couldn't reconnect"), body: r.message)
            }
            DispatchQueue.main.async {
                self.busy = false
                self.reviveItem.isEnabled = true
                self.refresh()
            }
        }
    }

    func refresh() {
        guard !busy else { return }
        queue.async {
            let d = self.reviver.connected()
            let w = self.reviver.winner?.title
            let addr = self.reviver.lastAddr.map { String($0.split(separator: ":").first ?? "") }
            DispatchQueue.main.async {
                guard !self.busy else { return }
                if let d {
                    self.show(.connected, L("연결됨", "Connected"), "\(d.model ?? L("휴대폰", "Phone")) · " + L("무선", "Wireless") + (addr.map { " · \($0)" } ?? ""))
                } else {
                    self.show(.disconnected, L("연결 안 됨", "Disconnected"), L("⌘R 또는 앱 아이콘을 누르면 다시 붙여요", "Press ⌘R or open the app to reconnect"))
                }
                self.methodLine.title = L("마지막 성공 방법: ", "Last working fix: ") + (w ?? "-")
                self.loginItem.state = AppInstall.loginItemEnabled ? .on : .off
            }
        }
    }

    @objc func showSetup() {
        UserDefaults.standard.set(true, forKey: "setupShown")
        if setupWindow == nil {
            setupWindow = makeSetupWindow(reviver: reviver, onAdbReady: { [weak self] in self?.reviveNow() },
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
