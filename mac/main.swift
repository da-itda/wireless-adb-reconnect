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
/// macOS 13~15는 로컬 네트워크 화면, macOS 27은 바로 가는 주소가 없어 '개인정보 보호 및 보안' 첫 화면이 열린다 (NetworkHelp가 안내)
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
    var onRestart: () -> Void = {}

    func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        let retry = UNNotificationAction(identifier: "retry", title: L("다시 시도", "Try again"))
        let logs = UNNotificationAction(identifier: "log", title: L("진단 보기", "Diagnostics"))
        let restart = UNNotificationAction(identifier: "restart", title: L("adb 재시작하고 모두 다시 연결", "Restart adb and reconnect all"))
        c.setNotificationCategories([UNNotificationCategory(identifier: "fail", actions: [retry, logs], intentIdentifiers: []),
                                     UNNotificationCategory(identifier: "restart", actions: [restart, logs], intentIdentifiers: [])])
        c.requestAuthorization(options: [.alert, .sound]) { ok, err in
            log(L("알림 권한: ", "Notification permission: ") + (ok ? L("허용", "allowed") : L("없음", "denied")) + " \(err.map { "\($0)" } ?? "")")
        }
    }

    /// restart: 실패 알림에 'adb 재시작하고 모두 다시 연결' 버튼
    func post(ok: Bool, title: String, body: String, restart: Bool = false) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            guard s.authorizationStatus == .authorized || s.authorizationStatus == .provisional else {
                DispatchQueue.main.async { Toast.show(title: title, body: body, ok: ok) }
                return
            }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            c.sound = ok ? nil : .default
            if !ok { c.categoryIdentifier = restart ? "restart" : "fail" }
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

    // 실패 알림: "다시 시도" → 다시 붙이기, "adb 재시작…" → 모두 다시 연결, 알림 자체나 "진단 보기" → 진단 로그
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler handler: @escaping () -> Void) {
        let failed = ["fail", "restart"].contains(response.notification.request.content.categoryIdentifier)
        DispatchQueue.main.async {
            if response.actionIdentifier == "retry" { self.onRetry() }
            else if response.actionIdentifier == "restart" { self.onRestart() }
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

/// id가 있으면 그 휴대폰의 광고만 본다 (없으면 처음 보이는 휴대폰)
func findPhone(id: String?, timeout: TimeInterval = 8) -> PhoneResult {
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
        guard conn == nil else { return }
        let match = results.lazy.compactMap { r -> (NWEndpoint, String)? in
            guard case .service(let name, _, _, _) = r.endpoint, id == nil || phoneId(fromMdnsName: name) == id else { return nil }
            return (r.endpoint, name)
        }.first
        guard let (endpoint, name) = match else { return }
        log(L("  mDNS: 휴대폰 발견 ", "  mDNS: found phone ") + name)
        seen = name
        let c = NWConnection(to: endpoint, using: tcp)
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
                if c.currentPath?.unsatisfiedReason == .localNetworkDenied { denied = true; finish(.permissionDenied); return }
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

// 1.4.0까지 있던 '터미널에서 서버 실행'(권한 없을 때 터미널의 권한을 빌림)은 터미널 창이 떠서 뺐다 (2026-11-10 사용자 요청)
// → 권한이 없으면 연결하지 않고 권한 안내(도우미 창)를 보여 준다
extension Strategy {
    var title: String {
        switch self {
        case .reconnectOffline: return L("offline 기기 재연결", "Reconnect offline device")
        case .connectOnly: return L("서버 유지 + IP:포트 직접 연결", "Keep server, connect to IP:port")
        case .ownServer: return L("앱이 adb 서버 재시작", "Restart adb server (owned by app)")
        case .ownServerBonjour: return L("앱이 adb 서버 재시작 (macOS mDNS 백엔드)", "Restart adb server (macOS mDNS backend)")
        }
    }
}

struct ReviveResult {
    let ok: Bool
    let message: String
    /// 다른 기기가 연결돼 있어 서버 재시작을 건너뜀 → 'adb 재시작하고 모두 다시 연결' 제안
    let restartSkipped: Bool
}

final class Reviver {
    private var _adb: String?
    var adb: String? { cacheLock.lock(); defer { cacheLock.unlock() }; return _adb }
    private(set) var server: Process?       // 앱이 소유한 nodaemon 서버 (serverLock 안에서만)
    private var _needsPermission = false
    /// 마지막 다시 붙이기에서 macOS가 로컬 네트워크를 거부했는지 → 메뉴·패널의 권한 안내를 보여 줌
    /// (접속 시간 초과처럼 권한인지 알 수 없는 실패로는 켜지 않는다)
    var needsPermission: Bool { cacheLock.lock(); defer { cacheLock.unlock() }; return _needsPermission }
    private func setNeedsPermission(_ v: Bool) { cacheLock.lock(); _needsPermission = v; cacheLock.unlock() }
    /// 권한이 다시 켜진 것을 확인했을 때 (이미 연결돼 있으면 다시 붙이기를 하지 않아 거기서는 풀리지 않음)
    func permissionAllowed() { setNeedsPermission(false) }
    /// 서버를 끄고 다시 띄우는 사이에 다른 스레드가 adb를 부르면 adb가 자기 데몬을 띄운다
    /// → adb를 부르는 쪽은 함께(read), 서버를 바꾸는 쪽은 혼자(write)
    private let serverRW: UnsafeMutablePointer<pthread_rwlock_t> = {
        let p = UnsafeMutablePointer<pthread_rwlock_t>.allocate(capacity: 1)
        pthread_rwlock_init(p, nil)
        return p
    }()
    /// 다시 붙이기와 페어링이 동시에 서버를 띄우지 않게 (서버를 바꾸는 작업은 한 번에 하나)
    private let serverLock = NSRecursiveLock()
    let store = PhoneStore()
    /// adb serial → ro.serialno (IP:포트 serial은 휴대폰에 물어봐야 안다)
    private var idCache: [String: String] = [:]
    /// 이번 실행에서 이름·버전을 이미 물어본 휴대폰
    private var described: Set<String> = []
    /// 이번 실행에서 '목록에서 지우기'한 휴대폰 — adb가 저절로 다시 붙여도 목록에 넣지 않고 끊는다
    private var forgotten: Set<String> = []
    private let cacheLock = NSLock()

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

    func refreshAdb() {
        let found = Reviver.findAdb()
        cacheLock.lock(); if _adb != found { _adb = found }; cacheLock.unlock()
    }

    private func changingServer<T>(_ body: () -> T) -> T {
        pthread_rwlock_wrlock(serverRW); defer { pthread_rwlock_unlock(serverRW) }
        return body()
    }

    /// 서버가 떠 있을 때만 adb를 부른다 (없으면 adb가 제 데몬을 띄우므로). 서버를 바꾸는 중이면 끝날 때까지 기다린다
    func adbIfRunning(_ args: [String], timeout: TimeInterval) -> (code: Int32, out: String)? {
        guard let adb else { return nil }
        pthread_rwlock_rdlock(serverRW); defer { pthread_rwlock_unlock(serverRW) }
        return portOpen() ? run(adb, args, timeout: timeout) : nil
    }

    /// adb mdns services → (이름, 종류, IP:포트)
    func mdnsServices() -> [(name: String, type: String, addr: String)] {
        guard let r = adbIfRunning(["mdns", "services"], timeout: 6) else { return [] }
        return r.out.split(separator: "\n").compactMap { line in
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            return f.count >= 3 && f[1].hasPrefix("_adb") ? (f[0], f[1], f[2]) : nil
        }
    }

    /// 페어링 등에서 쓰기 전에 앱 소유 서버를 준비한다
    func ensureServer() -> Bool {
        serverLock.lock(); defer { serverLock.unlock() }
        refreshAdb()
        guard adb != nil else { return false }
        if ownsServer { return true }
        guard changingServer({ stopServer(); return startOwnServer() }) else { return false }
        enforceOff()
        return true
    }

    enum PairingServer { case ready, needsConfirm([String]), failed }

    /// 페어링 전: 앱 서버가 아니면 다시 띄워야 하는데, 연결된 기기가 있으면 먼저 묻는다
    func prepareForPairing() -> PairingServer {
        serverLock.lock(); defer { serverLock.unlock() }
        refreshAdb()
        guard adb != nil else { return .failed }
        if ownsServer { return .ready }
        let list = devices().list
        if list.contains(where: { $0.state == "device" }) {
            let names = phones().groups.filter(\.isConnected).map { store.phone($0.id)?.name ?? $0.id }
            return .needsConfirm(names)
        }
        return ensureServer() ? .ready : .failed
    }

    var ownsServer: Bool {
        guard let s = server, s.isRunning else { return false }
        return serverOwner()?.pid == s.processIdentifier
    }

    // 서버가 없을 때 `adb devices`를 부르면 이 자리에서 서버가 떠버리므로 포트부터 확인
    func devices() -> (list: [Device], versionMismatch: Bool) {
        guard let out = adbIfRunning(["devices", "-l"], timeout: 5)?.out else { return ([], false) }
        let list: [Device] = out.split(separator: "\n").dropFirst().compactMap { line in
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count >= 2 else { return nil }
            let model = f.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: "-") }
            return Device(serial: String(f[0]), state: String(f[1]), model: model)
        }
        return (list, out.contains("doesn't match this client"))
    }

    /// 무선 기기를 휴대폰별로 묶는다. 처음 연결된 휴대폰은 목록에 넣는다
    func phones() -> (devices: [Device], groups: [PhoneDevices]) {
        let list = devices().list
        let groups = groupWireless(list) { serial in resolveId(serial, state: list.first { $0.serial == serial }?.state) }
        for g in groups where g.isConnected { remember(g) }
        return (list, groups)
    }

    func connectedIds() -> Set<String> { Set(phones().groups.filter(\.isConnected).map(\.id)) }

    /// 연결된 그 휴대폰의 adb 기기 (모델 이름·serial)
    func connectedDevice(_ id: String) -> Device? {
        phones().groups.first { $0.id == id }.flatMap { g in g.serials.first { $0.serial == g.anySerial } }
    }

    /// 연결된 첫 무선 휴대폰
    func firstConnected() -> (id: String, device: Device)? {
        guard let g = phones().groups.first(where: \.isConnected), let d = g.serials.first(where: { $0.serial == g.anySerial }) else { return nil }
        return (g.id, d)
    }

    /// "36.0.0" (adb version 둘째 줄 "Version 36.0.0-13206524")
    func adbVersion() -> String? {
        guard let adb else { return nil }
        return run(adb, ["version"], timeout: 5).out.split(separator: "\n").first { $0.hasPrefix("Version ") }
            .map { String($0.dropFirst(8).split(separator: "-").first ?? "") }
    }

    private func resolveId(_ serial: String, state: String?) -> String? {
        if let id = phoneId(fromMdnsName: serial) { return id }
        cacheLock.lock(); let cached = idCache[serial]; cacheLock.unlock()
        if let cached { return cached }
        guard state == "device" else { return idForSavedAddress(serial, phones: store.all) }
        guard let r = adbIfRunning(["-s", serial, "shell", "getprop", "ro.serialno"], timeout: 5), r.code == 0, !r.out.isEmpty else { return nil }
        cacheLock.lock(); idCache[serial] = r.out; cacheLock.unlock()
        return r.out
    }

    private func remember(_ g: PhoneDevices) {
        cacheLock.lock()
        let skip = forgotten.contains(g.id) || (described.contains(g.id) && store.phone(g.id) != nil)
        cacheLock.unlock()
        guard !skip, let serial = g.anySerial else { return }
        func shell(_ args: [String]) -> String? {
            guard let r = adbIfRunning(["-s", serial, "shell"] + args, timeout: 5) else { return nil }
            return r.code == 0 && !r.out.isEmpty && r.out != "null" ? r.out : nil
        }
        let mdns = g.serials.first(where: \.isMdnsName).map { $0.serial.components(separatedBy: "._adb").first ?? $0.serial }
        let addr = g.serials.first(where: \.isIPPort)?.serial ?? mdns.flatMap { m in mdnsServices().first { $0.name == m }?.addr }
        let name = shell(["settings", "get", "global", "device_name"]) ?? g.serials.compactMap(\.model).first ?? g.id
        let p = store.seen(id: g.id, name: name, android: shell(["getprop", "ro.build.version.release"]), mdnsName: mdns, addr: addr)
        cacheLock.lock(); described.insert(g.id); cacheLock.unlock()
        log(L("휴대폰: ", "Phone: ") + "\(p.name) (\(p.id))" + (p.enabled ? "" : L(" — 꺼 둠", " — switched off")))
    }

    /// 목록에서 지운다. 이번 실행 동안은 다시 붙어도 목록에 넣지 않고 끊는다
    func forget(_ id: String) {
        cacheLock.lock(); forgotten.insert(id); described.remove(id); cacheLock.unlock()
        store.forget(id)
    }

    var forgottenIds: Set<String> { cacheLock.lock(); defer { cacheLock.unlock() }; return forgotten }

    /// 페어링처럼 사용자가 직접 추가한 휴대폰은 다시 목록에 넣는다
    func unforget(_ id: String) {
        cacheLock.lock(); forgotten.remove(id); cacheLock.unlock()
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

    // MARK: 한 휴대폰 다시 붙이기

    /// id가 ""이면 아직 목록이 비어 있을 때(1.4.1에서 올라온 직후) — 예전처럼 아무 무선 휴대폰이나
    private func isConnected(_ id: String) -> Bool {
        let groups = phones().groups
        return id.isEmpty ? groups.contains(where: \.isConnected) : groups.contains { $0.id == id && $0.isConnected }
    }

    private func savedAddr(_ id: String) -> String? { id.isEmpty ? store.legacyAddr : store.phone(id)?.lastAddr }

    /// stillWanted가 false가 되면(사용자가 꺼 둠) 다음 방법으로 넘어가기 전에 멈춘다
    func revive(_ id: String, stillWanted: () -> Bool) -> ReviveResult {
        serverLock.lock(); defer { serverLock.unlock() }
        let name = id.isEmpty ? L("휴대폰", "Phone") : store.phone(id)?.name ?? id
        func note(_ s: String) { log("[\(name)] " + s) }
        var causes: [String] = []
        func cause(_ c: String) { if !causes.contains(c) { causes.append(c); note(L("  원인 후보: ", "  Possible cause: ") + c) } }
        func finish(_ ok: Bool, _ msg: String, restartSkipped: Bool = false) -> ReviveResult {
            if !ok && causes.count > 1 { note(L("원인 후보 전체:", "All possible causes:") + "\n  - " + causes.joined(separator: "\n  - ")) }
            note(L("결과: ", "Result: ") + msg)
            return ReviveResult(ok: ok, message: msg, restartSkipped: restartSkipped)
        }

        note(L("===== 다시 붙이기 시작", "===== Reconnect started"))
        refreshAdb()
        guard adb != nil else { return finish(false, L("adb를 찾을 수 없어요. 설정에서 adb를 설치해 주세요.", "adb not found. Install it from Settings.")) }

        // 1) 진단
        let (list, mismatch) = devices()
        if mismatch { cause(L("adb 버전 불일치 → 다른 adb(Android Studio 등)가 서버를 띄움", "adb version mismatch → another adb (Android Studio, etc.) started the server")) }
        note(L("진단: 기기 = ", "Diagnosis: devices = ") + "\(list.map { "\($0.serial)(\($0.state))" })")
        let groups = phones().groups
        let mine = id.isEmpty ? groups.first : groups.first { $0.id == id }
        if mine?.isConnected == true { return finish(true, L("이미 연결되어 있어요", "Already connected")) }
        if let owner = serverOwner() {
            let owns = owner.pid == server?.processIdentifier
            note(L("진단: adb 서버 소유 = ", "Diagnosis: adb server owner = ") + (owns ? L("이 앱", "this app") : owner.chain))
            if !owns { cause(L("adb 서버를 다른 프로그램({0})이 띄움 → 그 프로그램에 로컬 네트워크 권한이 없으면 휴대폰에 못 붙음", "Another program ({0}) started the adb server → it can't reach the phone without Local Network permission", owner.chain)) }
        } else {
            note(L("진단: adb 서버 꺼져 있음", "Diagnosis: adb server not running"))
        }
        if mine?.isOffline == true { cause(L("기기가 offline 상태로 남아 있음", "Device is stuck offline")) }
        if list.contains(where: { $0.state == "unauthorized" }) { cause(L("휴대폰에서 디버깅 허용 필요 (unauthorized)", "Allow debugging on the phone (unauthorized)")) }

        var phone = findPhone(id: id.isEmpty ? nil : id)
        note(L("진단: 휴대폰 = ", "Diagnosis: phone = ") + "\(phone)")
        setNeedsPermission(phone == .permissionDenied)
        switch phone {
        case .found(let a): if !id.isEmpty { store.update(id) { $0.lastAddr = a } }
        case .unreachable: cause(L("휴대폰이 Wi‑Fi에 보이지만 응답하지 않음 → 휴대폰 화면을 켜거나 무선 디버깅을 껐다 켜 주세요 (VPN도 확인)", "Phone is visible on Wi‑Fi but not responding → wake the phone or turn wireless debugging off and on (check VPN too)"))
        case .permissionDenied: cause(L("이 앱에 로컬 네트워크 권한 없음 → 시스템 설정 > 개인정보 보호 및 보안 > 로컬 네트워크에서 허용", "This app has no Local Network permission → allow it in System Settings > Privacy & Security > Local Network"))
        case .notFound: cause(L("휴대폰이 보이지 않음 → 무선 디버깅 꺼짐 / 화면 꺼짐·절전 / 다른 Wi‑Fi", "Phone not visible → wireless debugging off / screen off or power saving / different Wi‑Fi"))
        }

        // 2) 시도 순서 (다른 기기가 연결돼 있으면 서버를 재시작하지 않는다)
        let others = otherDevicesConnected(list, excluding: mine?.serials.map(\.serial) ?? [])
        let winner = id.isEmpty ? store.legacyWinner : store.phone(id)?.winner
        // 어느 휴대폰인지 모르는 offline 무선 기기도 있으면 reconnect offline (연결된 기기는 끊지 않는다)
        let strayOffline = list.contains { d in d.isWireless && d.state == "offline" && !groups.contains { $0.serials.contains(d) } }
        let plan = fixOrder(isOffline: (mine?.isOffline ?? false) || strayOffline, othersConnected: others,
                            permissionDenied: phone == .permissionDenied, winner: winner)
        if plan.restartSkipped { note(L("다른 기기가 연결돼 있어 adb 서버는 재시작하지 않음", "Another device is connected → not restarting the adb server")) }
        note(L("시도 순서: ", "Order: ") + "\(plan.order.map(\.title))")

        // 3) 순서대로 시도, 붙으면 종료
        for s in plan.order {
            guard stillWanted() else { return finish(false, L("꺼 둬서 멈췄어요", "Stopped — switched off")) }
            note(L("▶ 시도: ", "▶ Trying: ") + s.title)
            if attempt(s, id: id, phone: phone, cause: cause) {
                guard stillWanted() else {
                    disconnect(id)
                    return finish(false, L("꺼 둬서 멈췄어요", "Stopped — switched off"))
                }
                let target = id.isEmpty ? phones().groups.first(where: \.isConnected)?.id : id
                if let target {
                    let addr = phones().groups.first { $0.id == target }?.serials.first(where: \.isIPPort)?.serial
                    store.update(target) { $0.winner = s; if let addr { $0.lastAddr = addr } }
                }
                return finish(true, L("다시 붙었어요 — ", "Reconnected — ") + s.title)
            }
            note(L("  실패: ", "  Failed: ") + s.title)
            if s == .ownServer, phone == .notFound {
                phone = findPhone(id: id.isEmpty ? nil : id, timeout: 4)    // 그 사이 휴대폰이 깨어났는지 다시 확인
            }
        }
        if plan.restartSkipped {
            cause(L("다른 기기가 연결돼 있어 adb를 재시작하지 않았어요 → 'adb 재시작하고 모두 다시 연결'", "adb wasn't restarted because another device is connected → 'Restart adb and reconnect all'"))
        }
        return finish(false, causes.first ?? L("원인을 찾지 못했어요 — 진단 보기를 확인해 주세요", "Unknown cause — check Diagnostics"),
                      restartSkipped: plan.restartSkipped)
    }

    private func attempt(_ s: Strategy, id: String, phone: PhoneResult, cause: (String) -> Void) -> Bool {
        guard let adb else { return false }
        switch s {
        case .reconnectOffline:
            run(adb, ["reconnect", "offline"], timeout: 10)
            return waitUntil(5) { isConnected(id) }
        case .connectOnly:
            // 서버가 없으면 `adb connect`가 데몬을 띄우므로 앱 서버부터 (연결된 기기가 없으니 끊길 것도 없다)
            if !portOpen() { guard changingServer({ startOwnServer() }) else { return false } }
            return connectCandidates(id: id, phone: phone, cause: cause)
        case .ownServer, .ownServerBonjour:
            guard changingServer({ stopServer(); return startOwnServer(bonjour: s == .ownServerBonjour) }) else { return false }
            let ok = connectCandidates(id: id, phone: phone, cause: cause, askAdb: true)
            enforceOff()
            return ok
        }
    }

    /// adb가 mDNS로 찾은 그 휴대폰의 주소 (id가 ""이면 처음 보이는 휴대폰)
    private func adbMdnsAddr(_ id: String) -> String? {
        mdnsServices().first { $0.type.hasPrefix("_adb-tls-connect") && (id.isEmpty || phoneId(fromMdnsName: $0.name) == id) }?.addr
    }

    /// askAdb: 서버를 막 다시 띄웠을 때 — adb의 mDNS 탐색 결과도 후보로 (그 백엔드로 찾게 하는 게 3·4번 방법의 목적)
    private func connectCandidates(id: String, phone: PhoneResult, cause: (String) -> Void, askAdb: Bool = false) -> Bool {
        guard let adb else { return false }
        var addrs: [String] = []
        if case .found(let a) = phone { addrs.append(a) }
        if askAdb, waitUntil(3, { adbMdnsAddr(id) != nil }), let a = adbMdnsAddr(id), !addrs.contains(a) { addrs.append(a) }
        if let a = savedAddr(id), !addrs.contains(a) { addrs.append(a) }
        for a in addrs {
            let out = run(adb, ["connect", a], timeout: 12).out
            log("  adb connect \(a): \(out)")
            let l = out.lowercased()
            if l.contains("no route to host") { cause(L("No route to host → adb 서버를 띄운 프로그램에 로컬 네트워크 권한 없음 (또는 다른 네트워크)", "No route to host → the program running the adb server has no Local Network permission (or different network)")) }
            if l.contains("connection refused") { cause(L("Connection refused → 무선 디버깅 포트가 바뀌었거나 꺼짐", "Connection refused → wireless debugging port changed or turned off")) }
            if l.contains("authenticat") { cause(L("인증 실패 → 이 Mac과 페어링이 안 됨. 메뉴의 '휴대폰 페어링'으로 다시 페어링하세요", "Authentication failed → this Mac isn't paired. Use 'Pair phone' in the menu")) }
            if l.contains("timed out") { cause(L("시간 초과 → 휴대폰 절전 / 다른 Wi‑Fi / VPN 경로", "Timed out → phone asleep / different Wi‑Fi / VPN route")) }
            if waitUntil(3, { isConnected(id) }) { return true }
        }
        return false
    }

    // MARK: 여러 휴대폰

    /// 켜 둔 휴대폰 중 끊긴 것을 목록 순서대로. 목록이 비어 있으면 예전처럼 한 대
    func reviveAll(stillWanted: (String) -> Bool) -> [(id: String, result: ReviveResult)] {
        let list = store.all
        if list.isEmpty { return [("", revive("", stillWanted: { true }))] }
        var results: [(id: String, result: ReviveResult)] = []
        for p in list where p.enabled && stillWanted(p.id) {
            if connectedIds().contains(p.id) { continue }    // 앞의 휴대폰을 붙이다 서버가 다시 떠서 저절로 붙었을 수 있다
            results.append((p.id, revive(p.id) { stillWanted(p.id) }))
        }
        return results
    }

    /// 사용자가 누를 때만: 서버를 다시 띄우고 켜 둔 휴대폰을 모두 다시 붙인다 (다른 휴대폰도 잠깐 끊긴다)
    func restartAndReconnectAll() -> [(id: String, result: ReviveResult)] {
        serverLock.lock(); defer { serverLock.unlock() }
        log(L("===== adb 재시작하고 모두 다시 연결", "===== Restart adb and reconnect all"))
        refreshAdb()
        let wanted = store.all.filter(\.enabled)
        guard let adb, changingServer({ stopServer(); return startOwnServer() }) else {
            return wanted.map { ($0.id, ReviveResult(ok: false, message: L("adb 서버를 띄우지 못했어요", "Couldn't start the adb server"), restartSkipped: false)) }
        }
        _ = waitUntil(3) { !mdnsServices().isEmpty }
        for p in wanted where !connectedIds().contains(p.id) {
            var addrs: [String] = []
            if case .found(let a) = findPhone(id: p.id, timeout: 4) { addrs.append(a) }
            if let a = adbMdnsAddr(p.id), !addrs.contains(a) { addrs.append(a) }
            if let a = p.lastAddr, !addrs.contains(a) { addrs.append(a) }
            for a in addrs {
                log("  [\(p.name)] adb connect \(a): " + run(adb, ["connect", a], timeout: 12).out)
                if waitUntil(3, { connectedIds().contains(p.id) }) { break }
            }
        }
        enforceOff()
        let connected = connectedIds()
        return wanted.map { p in
            let ok = connected.contains(p.id)
            log("  [\(p.name)] " + (ok ? L("연결됨", "connected") : L("연결 못 함", "not connected")))
            return (p.id, ReviveResult(ok: ok, message: ok ? L("다시 붙었어요", "Reconnected") : L("연결하지 못했어요 — 진단 보기를 확인해 주세요", "Couldn't reconnect — check Diagnostics"), restartSkipped: false))
        }
    }

    /// 그 휴대폰의 모든 serial(mDNS 이름, IP:포트)을 끊는다
    func disconnect(_ id: String, also addr: String? = nil) {
        var targets = phones().groups.first { $0.id == id }?.serials.map(\.serial) ?? []
        if let a = addr ?? store.phone(id)?.lastAddr, !targets.contains(a) { targets.append(a) }
        for t in targets {
            guard let r = adbIfRunning(["disconnect", t], timeout: 5) else { return }
            log("  adb disconnect \(t): " + r.out)
        }
    }

    /// 꺼 둔(또는 이번 실행에서 지운) 휴대폰이 붙어 있으면 끊는다 — 끊기만 하고 붙이지는 않는다
    @discardableResult
    func enforceOff() -> [String] {
        cacheLock.lock(); let gone = forgotten; cacheLock.unlock()
        let ids = phones().groups.filter { g in g.isConnected && (gone.contains(g.id) || store.phone(g.id)?.enabled == false) }.map(\.id)
        for id in ids {
            log(L("꺼 둔 휴대폰이 다시 붙어서 끊음: ", "Switched-off phone reconnected by adb, disconnecting: ") + (store.phone(id)?.name ?? id))
            disconnect(id)
        }
        return ids
    }

    /// changingServer 안에서만 부른다
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

    /// changingServer 안에서만 부른다
    func startOwnServer(bonjour: Bool = false) -> Bool {
        guard let adb else { return false }
        let env = ownServerEnv(bonjour: bonjour)
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
    var store: PhoneStore { reviver.store }
    /// adb를 바꾸는 작업(다시 붙이기·끊기·재시작·미러링 시작)은 이 줄에서 하나씩 — 누른 순서대로 기다린다
    let queue = DispatchQueue(label: "revive")
    /// 10초마다 상태 보기(읽기만) — 오래 걸리는 다시 붙이기 중에도 행이 갱신되게 따로 돈다
    let statusQueue = DispatchQueue(label: "status")
    var item: NSStatusItem!
    /// 끊긴 휴대폰이 있을 때만 누를 수 있다
    let reviveItem = NSMenuItem(title: L("확인 중…", "Checking…"), action: #selector(reconnectAllClicked), keyEquivalent: "r")
    let loginItem = NSMenuItem(title: L("로그인할 때 자동 실행", "Launch at login"), action: #selector(toggleLogin), keyEquivalent: "")
    let permissionItem = NSMenuItem(title: L("로컬 네트워크 권한 열기", "Open Local Network settings"), action: #selector(openSettings), keyEquivalent: "")
    let mirror = ScreenMirror()
    let mirrorItem = NSMenuItem(title: L("화면 미러링 시작하기", "Start screen mirroring"), action: #selector(mirrorClicked), keyEquivalent: "m")
    let optionsItem = NSMenuItem(title: L("미러링 옵션…", "Mirroring options…"), action: #selector(showMirrorOptions), keyEquivalent: "")
    let updater = Updater()
    let updateItem = NSMenuItem(title: "", action: #selector(updateClicked), keyEquivalent: "")
    /// 오른쪽 클릭 메뉴의 휴대폰별 하위 메뉴
    private var phoneMenuItems: [NSMenuItem] = []
    /// 작업 중인 휴대폰 (같은 휴대폰에 작업이 여럿 줄 서 있을 수 있어 개수로 센다). "" = 전체
    private var busyCounts: [String: Int] = [:]
    private var refreshing = false
    /// 연결된 시각 (패널의 'n분째 연결')
    private var connectedSince: [String: Date] = [:]
    private var lastGroups: [PhoneDevices] = []
    /// 권한 안내가 떠 있는 동안 refresh마다 권한이 다시 켜졌는지 본다
    private var checkingPermission = false
    var setupWindow: NSWindow?
    var pairWindow: NSWindow?
    var mirrorWindow: NSWindow?
    /// 오른쪽 클릭 메뉴 (왼쪽 클릭은 카드형 패널)
    let classicMenu = NSMenu()
    lazy var panelModel = PanelModel(mirror: mirror)
    var panel: MenuPanel!

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
        optionsItem.target = self; menu.addItem(optionsItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: L("설정…", "Settings…"), action: #selector(showSetup), keyEquivalent: ",").target = self
        menu.addItem(withTitle: L("진단 보기", "Diagnostics"), action: #selector(openLog), keyEquivalent: "l").target = self
        updateItem.target = self; menu.addItem(updateItem)
        menu.addItem(withTitle: L("종료 (adb 서버도 종료)", "Quit (stops adb server)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.button?.target = self
        item.button?.action = #selector(statusClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        panelModel.appVersion = updater.current
        panelModel.act = { [weak self] in self?.panelAction($0) }
        panel = MenuPanel(model: panelModel)
        apply([])
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
        Notifier.shared.onRetry = { [weak self] in self?.reconnectAll() }
        Notifier.shared.onRestart = { [weak self] in self?.restartAll() }
        mirror.onExit = { [weak self] code, byUser in self?.mirrorDidExit(code: code, byUser: byUser) }
        Notifier.shared.setup()

        // 옮긴 직후: 미리 고른 '로그인 시 자동 실행' 적용
        if CommandLine.arguments.contains("--after-move"), UserDefaults.standard.bool(forKey: "wantLogin") {
            AppInstall.setLoginItem(true)
        }
        // 처음이거나(응용 프로그램 폴더 밖) adb가 없으면 설치 마법사, 옮긴 직후엔 이어서
        let firstRun = !AppInstall.isInApplications && !UserDefaults.standard.bool(forKey: "setupShown")
        if reviver.adb == nil || firstRun || CommandLine.arguments.contains("--after-move") { showSetup() }
        if reviver.adb != nil, installedOrSetup() { reconnectAll() }
        if CommandLine.arguments.contains("--network-help") { openSettings() }   // (개발용) 도우미 창 바로 열기
    }

    /// 응용 프로그램 폴더 밖(다운로드 폴더, 빌드 폴더 등)에서는 로컬 네트워크를 쓰지 않는다
    /// — 그 위치용 항목이 권한 목록에 따로 생기기 때문. 대신 설치 단계를 연다
    func installedOrSetup() -> Bool {
        if AppInstall.isInApplications { return true }
        log(L("응용 프로그램 폴더 밖에서 실행 중 → 연결하지 않고 설치 단계를 엶: ", "Running outside Applications → not connecting, opening the install step: ") + Bundle.main.bundleURL.path)
        openSetup(step: .install)
        return false
    }

    // 이미 실행 중일 때 앱 아이콘을 다시 누르면 → 다시 붙이기
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reconnectAll(); return false
    }

    func applicationWillTerminate(_ n: Notification) { mirror.stop(); reviver.shutdown() }

    // MARK: 작업 줄

    /// ids: 그동안 회전 표시할 휴대폰 (nil = 전체)
    private func enqueue(_ ids: [String]?, _ work: @escaping () -> Void) {
        let keys = ids ?? [""]
        keys.forEach { busyCounts[$0, default: 0] += 1 }
        updateBusy()
        queue.async {
            work()
            DispatchQueue.main.async {
                keys.forEach { self.busyCounts[$0, default: 1] -= 1; if self.busyCounts[$0] == 0 { self.busyCounts[$0] = nil } }
                self.updateBusy()
                self.refresh()
            }
        }
    }

    private func updateBusy() {
        panelModel.allBusy = busyCounts[""] != nil
        panelModel.busyIds = Set(busyCounts.keys.filter { !$0.isEmpty })
        updateStatus()
    }

    private func wanted(_ id: String) -> Bool { store.phone(id)?.enabled == true }

    // MARK: 다시 붙이기

    @objc func reconnectAllClicked() { reconnectAll() }

    func reconnectAll() {
        guard installedOrSetup() else { return }
        let started = Date()
        enqueue(nil) {
            let rs = self.reviver.reviveAll { self.wanted($0) }
            self.report(rs, started: started)
        }
    }

    func reconnect(_ id: String) {
        guard installedOrSetup() else { return }
        let started = Date()
        enqueue([id]) {
            let r = self.reviver.revive(id) { self.wanted(id) }
            self.report([(id, r)], started: started)
        }
    }

    /// 사용자가 눌렀을 때만 — 다른 휴대폰도 잠깐 끊긴다
    func restartAll() {
        guard installedOrSetup() else { return }
        panelModel.restartOffer = false
        let started = Date()
        enqueue(nil) { self.report(self.reviver.restartAndReconnectAll(), started: started) }
    }

    func setEnabled(_ id: String, _ on: Bool) {
        store.setEnabled(id, on)
        apply(lastGroups)
        if on { reconnect(id); return }
        if mirror.phoneId == id { mirror.stop() }
        enqueue([id]) { self.reviver.disconnect(id) }
    }

    func forget(_ id: String) {
        if mirror.phoneId == id { mirror.stop() }
        let addr = store.phone(id)?.lastAddr
        reviver.forget(id)
        apply(lastGroups)
        enqueue([]) { self.reviver.disconnect(id, also: addr) }
    }

    private func name(_ id: String) -> String {
        if id.isEmpty { return reviver.firstConnected().map { store.phone($0.id)?.name ?? $0.device.model ?? $0.id } ?? L("휴대폰", "Phone") }
        return store.phone(id)?.name ?? id
    }

    /// 결과 알림 — 여러 대면 하나로 묶는다. 꺼서 멈춘 휴대폰은 알리지 않는다
    private func report(_ rs: [(id: String, result: ReviveResult)], started: Date) {
        let denied = reviver.needsPermission
        let ok = rs.filter { $0.result.ok && ($0.id.isEmpty || wanted($0.id)) }
        let failed = rs.filter { !$0.result.ok && ($0.id.isEmpty || wanted($0.id)) }
        DispatchQueue.main.async {
            if denied { LocalNetwork.last = .denied } else if !ok.isEmpty { LocalNetwork.last = .allowed }
            if failed.contains(where: \.result.restartSkipped) { self.panelModel.restartOffer = true }
        }
        let secs = max(1, Int(Date().timeIntervalSince(started).rounded()))
        let okNames = ok.map { name($0.id) }.joined(separator: ", ")
        if let f = failed.first {
            var body = f.result.message
            if !ok.isEmpty { body += " (" + L("다시 연결됨: ", "reconnected: ") + okNames + ")" }
            let names = failed.map { name($0.id) }.joined(separator: ", ")
            Notifier.shared.post(ok: false, title: L("{0} 연결하지 못했어요", "Couldn't reconnect {0}", names), body: body,
                                 restart: failed.contains(where: \.result.restartSkipped))
        } else if !ok.isEmpty {
            Notifier.shared.post(ok: true, title: L("다시 연결됐어요", "Reconnected"), body: okNames + " · " + L("{0}초 걸렸어요", "took {0}s", secs))
        }
    }

    // MARK: 상태

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        statusQueue.async {
            let groups = self.reviver.phones().groups
            // 꺼 둔(또는 지운) 휴대폰을 adb가 저절로 다시 붙였으면 끊는다 — 붙이지는 않는다
            let stray = groups.contains { g in g.isConnected && self.store.phone(g.id)?.enabled != true }
            DispatchQueue.main.async {
                self.refreshing = false
                self.apply(groups)
                if stray { self.queue.async { self.reviver.enforceOff() } }
                let needs = self.reviver.needsPermission
                self.permissionItem.isHidden = !needs
                self.panelModel.needsPermission = needs
                if needs { self.recheckPermission() }
                self.loginItem.state = AppInstall.loginItemEnabled ? .on : .off
            }
        }
    }

    /// 저장된 목록 + 마지막으로 본 adb 상태 → 패널 행, 아이콘, 메뉴 (main)
    private func apply(_ groups: [PhoneDevices]) {
        lastGroups = groups
        let connected = Set(groups.filter(\.isConnected).map(\.id))
        for id in connectedSince.keys where !connected.contains(id) { connectedSince[id] = nil }
        for id in connected where connectedSince[id] == nil { connectedSince[id] = Date() }
        let phones = store.all
        panelModel.phones = phones.map { p in
            let g = groups.first { $0.id == p.id }
            let state: PhoneRow.State = !p.enabled ? .off : connected.contains(p.id) ? .connected(since: connectedSince[p.id] ?? Date()) : .dropped
            return PhoneRow(id: p.id, name: p.name, android: p.android, addr: g?.serials.first(where: \.isIPPort)?.serial ?? p.lastAddr,
                            state: state, mirroring: mirror.isRunning && mirror.phoneId == p.id)
        }
        panelModel.overall = overall(phones: phones, connectedIds: connected)
        panelModel.enabledCount = phones.filter(\.enabled).count
        panelModel.connectedCount = phones.filter { $0.enabled && connected.contains($0.id) }.count
        if panelModel.overall == .allConnected { panelModel.restartOffer = false }
        updateStatus()
        updateMirrorItem()
        rebuildPhoneMenus()
    }

    /// 메뉴 막대 아이콘·툴팁·'다시 연결' 항목
    private func updateStatus() {
        let m = panelModel
        let working = m.allBusy || !m.busyIds.isEmpty
        let summary = m.overall == .noPhones ? L("기기 다시 연결하기", "Reconnect device")
            : L("{0}/{1}대 연결됨", "{0} of {1} connected", m.connectedCount, m.enabledCount)
        let state: LinkState = working ? .working : m.overall == .allConnected ? .connected : .disconnected
        let title = working ? L("연결하는 중…", "Connecting…") : summary
        item?.button?.image = statusImage(state)
        item?.button?.toolTip = "\(appShortName) — \(title)"
        reviveItem.title = working ? title : m.overall == .allConnected ? summary : L("끊긴 기기 다시 연결하기", "Reconnect dropped devices")
        reviveItem.isEnabled = !working && m.overall != .allConnected
        m.link = state
        m.status = title
    }

    // MARK: 오른쪽 클릭 메뉴의 휴대폰별 하위 메뉴

    private func rebuildPhoneMenus() {
        phoneMenuItems.forEach(classicMenu.removeItem)
        phoneMenuItems = []
        let rows = panelModel.phones
        guard !rows.isEmpty, let anchor = classicMenu.items.firstIndex(of: optionsItem) else { return }
        var items: [NSMenuItem] = [.separator()]
        for row in rows {
            let detail: String
            switch row.state {
            case .connected: detail = row.mirroring ? L("미러링 중", "Mirroring") : L("연결됨", "Connected")
            case .dropped: detail = L("끊김", "Disconnected")
            case .off: detail = L("꺼 둠", "Off")
            }
            let top = NSMenuItem(title: "\(row.name) — \(detail)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            func add(_ title: String, _ sel: Selector, enabled: Bool = true, on: Bool = false) {
                let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
                i.target = self; i.representedObject = row.id; i.isEnabled = enabled; i.state = on ? .on : .off
                sub.addItem(i)
            }
            let busy = panelModel.busyIds.contains(row.id) || panelModel.allBusy
            add(L("연결 유지", "Keep connected"), #selector(menuToggle(_:)), on: row.state != .off)
            add(L("다시 연결", "Reconnect"), #selector(menuReconnect(_:)), enabled: row.state == .dropped && !busy)
            add(row.mirroring ? L("화면 미러링 중지", "Stop screen mirroring") : L("화면 미러링", "Screen mirroring"), #selector(menuMirror(_:)),
                enabled: row.state != .off && (!mirror.isRunning || row.mirroring))
            sub.addItem(.separator())
            add(L("목록에서 지우기", "Forget"), #selector(menuForget(_:)))
            top.submenu = sub
            items.append(top)
        }
        for (i, it) in items.enumerated() { classicMenu.insertItem(it, at: anchor + 1 + i) }
        phoneMenuItems = items
    }

    @objc private func menuToggle(_ s: NSMenuItem) { if let id = s.representedObject as? String { setEnabled(id, !wanted(id)) } }
    @objc private func menuReconnect(_ s: NSMenuItem) { if let id = s.representedObject as? String { reconnect(id) } }
    @objc private func menuMirror(_ s: NSMenuItem) { if let id = s.representedObject as? String { mirrorPhone(id) } }
    @objc private func menuForget(_ s: NSMenuItem) { if let id = s.representedObject as? String { forget(id) } }

    // MARK: 화면 미러링 (scrcpy)

    @objc func openMirrorLog() { NSWorkspace.shared.open(mirrorLogURL) }

    /// ⌘M: 미러링 중이면 중지, 아니면 마지막에 미러링한 휴대폰(없으면 연결된 첫 휴대폰)
    @objc func mirrorClicked() {
        if mirror.isRunning { mirror.stop(); apply(lastGroups); return }
        let connected = Set(lastGroups.filter(\.isConnected).map(\.id))
        if let id = mirrorTarget(phones: store.all, connectedIds: connected, lastMirrored: store.lastMirrored) {
            mirrorPhone(id)
        } else if store.all.isEmpty {
            mirrorPhone("")
        } else {
            Toast.show(title: L("켜 둔 휴대폰이 없어요", "No phone is switched on"), body: L("패널에서 휴대폰을 켜 주세요.", "Switch a phone on in the panel."), ok: false)
        }
    }

    /// 그 휴대폰을 미러링 (다른 휴대폰을 미러링 중이면 무시, 같은 휴대폰이면 중지). 끊겨 있으면 그 휴대폰만 먼저 다시 붙인다
    /// id가 ""이면 목록이 빈 경우 — 연결된 아무 휴대폰
    func mirrorPhone(_ id: String) {
        if mirror.isRunning {
            if mirror.phoneId == id { mirror.stop(); apply(lastGroups) }
            return
        }
        guard installedOrSetup() else { return }
        guard ScreenMirror.isInstalled else {
            Toast.show(title: L("scrcpy가 필요해요", "scrcpy is required"),
                       body: L("설정 창에서 '화면 미러링(scrcpy)도 설치'를 켜 주세요.", "Turn on 'Also install screen mirroring (scrcpy)' in Settings."), ok: false)
            openSetup(step: .install)
            return
        }
        mirrorItem.isEnabled = false
        enqueue(id.isEmpty ? nil : [id]) {
            var target = id
            if target.isEmpty {
                if self.reviver.firstConnected() == nil { self.report(self.reviver.reviveAll { _ in true }, started: Date()) }
                target = self.reviver.firstConnected()?.id ?? ""
            } else if !self.reviver.connectedIds().contains(target) {
                log(L("미러링 전 다시 붙이기", "Reconnecting before mirroring"))
                let r = self.reviver.revive(target) { self.wanted(target) }
                if !r.ok { self.report([(target, r)], started: Date()) }
            }
            if !target.isEmpty, let d = self.reviver.connectedDevice(target), let adb = self.reviver.adb {
                let r = self.mirror.start(adb: adb, serial: d.serial, title: self.name(target) + " · " + appShortName, phoneId: target)
                if r.ok { self.store.lastMirrored = target }
                else { Notifier.shared.post(ok: false, title: L("미러링을 시작하지 못했어요", "Couldn't start mirroring"), body: r.message) }
            }
            DispatchQueue.main.async { self.mirrorItem.isEnabled = true }
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
        case .reconnectAll: reconnectAll()
        case .restartAll: restartAll()
        case .reconnect(let id): reconnect(id)
        case .setEnabled(let id, let on): setEnabled(id, on)
        case .forget(let id): forget(id)
        case .mirror(let id):
            if !mirror.isRunning { panel.close() }
            mirrorPhone(id)
        case .copyAddress(let id):
            if let addr = panelModel.phones.first(where: { $0.id == id })?.addr {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(addr, forType: .string)
            }
        case .pair: panel.close(); showPair()
        case .mirrorOptions: panel.close(); showMirrorOptions()
        case .diagnostics: panel.close(); openLog()
        case .permission: panel.close(); openSettings()
        case .update: updateClicked()
        case .settings: panel.close(); showSetup()
        case .quit: NSApp.terminate(nil)
        }
    }

    @objc func showSetup() { openSetup(step: nil) }

    func openSetup(step: SetupModel.Step?) {
        UserDefaults.standard.set(true, forKey: "setupShown")
        if setupWindow == nil {
            setupWindow = makeSetupWindow(reviver: reviver, startAt: step, onAdbReady: { [weak self] in self?.reconnectAll() },
                                          onClose: { [weak self] in self?.setupWindow = nil; self?.refresh() })
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.center()
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showPair() {
        guard installedOrSetup() else { return }
        if pairWindow == nil {
            pairWindow = makePairWindow(reviver: reviver, onClose: { [weak self] in self?.pairWindow = nil; self?.refresh() })
        }
        NSApp.activate(ignoringOtherApps: true)
        pairWindow?.center()
        pairWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showMirrorOptions() {
        if mirrorWindow == nil {
            let model = MirrorOptionsModel(mirror: mirror)
            model.onChange = { [weak self] in self?.panelModel.objectWillChange.send() }
            model.openLog = { [weak self] in self?.openMirrorLog() }
            model.openSetup = { [weak self] in self?.mirrorWindow?.close(); self?.openSetup(step: .install) }
            mirrorWindow = makeMirrorWindow(model: model, onClose: { [weak self] in self?.mirrorWindow = nil })
        }
        NSApp.activate(ignoringOtherApps: true)
        mirrorWindow?.center()
        mirrorWindow?.makeKeyAndOrderFront(nil)
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
    /// 시스템 설정을 열고 옆에 도우미 창 → 허용되면 안내를 지우고 다시 연결
    @objc func openSettings() { NetworkHelp.shared.show { [weak self] in self?.permissionAllowed(); self?.reconnectAll() } }

    /// 시스템 설정에서 스위치를 켠 것을 알아채면 안내를 지운다
    func recheckPermission() {
        guard !checkingPermission else { return }
        checkingPermission = true
        LocalNetwork.check(timeout: 2) { [weak self] s in
            self?.checkingPermission = false
            if s == .allowed { self?.permissionAllowed() }
        }
    }

    func permissionAllowed() {
        log(L("로컬 네트워크 허용 확인 → 권한 안내 지움", "Local Network allowed → cleared the permission notice"))
        queue.async {
            self.reviver.permissionAllowed()
            DispatchQueue.main.async { self.permissionItem.isHidden = true; self.panelModel.needsPermission = false }
        }
    }
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
// (개발용) 로컬 네트워크 권한 상태를 로그에 남기고 끝: open -n <앱> --args --check-network
// 터미널에서 실행 파일을 바로 띄우면 터미널의 권한이 확인되므로 open으로 띄운다
if CommandLine.arguments.contains("--check-network") {
    app.setActivationPolicy(.prohibited)
    LocalNetwork.check(timeout: 5) { s in log(L("로컬 네트워크 확인: ", "Local Network check: ") + "\(s)"); exit(0) }
    app.run()
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
