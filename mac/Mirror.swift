// 화면 미러링 (scrcpy) — 이 앱이 소유한 adb 서버를 그대로 쓴다.
// scrcpy를 `ADB=<앱이 찾은 adb>` 환경변수로 실행해, 다른 adb(Homebrew 등)가 버전 불일치로 서버를 죽이는 일을 막는다.
// 기기는 앱이 알고 있는 무선 serial을 `-s`로 지정 → USB가 같이 꽂혀 있어도 무선으로 미러링.
import AppKit

let mirrorLogURL = home.appendingPathComponent("Library/Logs/wireless-adb-reconnect-mirror.log")

enum MirrorQuality: String, CaseIterable {
    case low = "4M", normal = "8M", high = "16M"
    var title: String {
        switch self {
        case .low: return L("낮음 (4M · 느린 Wi‑Fi)", "Low (4M · slow Wi‑Fi)")
        case .normal: return L("보통 (8M)", "Normal (8M)")
        case .high: return L("높음 (16M)", "High (16M)")
        }
    }
    /// 패널의 세그먼트 버튼용
    var shortTitle: String {
        switch self {
        case .low: return L("낮음", "Low")
        case .normal: return L("보통", "Normal")
        case .high: return L("높음", "High")
        }
    }
}

final class ScreenMirror {
    private(set) var process: Process?
    private var stoppedByUser = false
    private let defaults = UserDefaults.standard
    /// scrcpy가 끝났을 때 (코드, 사용자가 중지한 것인지)
    var onExit: (Int32, Bool) -> Void = { _, _ in }

    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: 설정 (UserDefaults)

    var quality: MirrorQuality {
        get { defaults.string(forKey: "mirrorQuality").flatMap(MirrorQuality.init) ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: "mirrorQuality") }
    }
    var audio: Bool {
        get { defaults.object(forKey: "mirrorAudio") == nil ? true : defaults.bool(forKey: "mirrorAudio") }
        set { defaults.set(newValue, forKey: "mirrorAudio") }
    }
    var alwaysOnTop: Bool {
        get { defaults.bool(forKey: "mirrorOnTop") }
        set { defaults.set(newValue, forKey: "mirrorOnTop") }
    }
    var turnScreenOff: Bool {
        get { defaults.bool(forKey: "mirrorScreenOff") }
        set { defaults.set(newValue, forKey: "mirrorScreenOff") }
    }
    var record: Bool {
        get { defaults.bool(forKey: "mirrorRecord") }
        set { defaults.set(newValue, forKey: "mirrorRecord") }
    }
    /// 녹화 파일 저장 폴더 (~/Movies)
    var recordDir: URL { home.appendingPathComponent("Movies") }

    // MARK: scrcpy 찾기

    static func findScrcpy() -> String? {
        let env = ProcessInfo.processInfo.environment
        var paths = [env["SCRCPY"]].compactMap { $0 }
        paths += ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"].map { $0 + "/scrcpy" }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool { findScrcpy() != nil }

    static func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Homebrew로 scrcpy 설치 (수 분 걸릴 수 있음). 끝나면 done(오류 메시지 또는 nil)
    static func installWithBrew(done: @escaping (String?) -> Void) {
        guard let brew = brewPath() else { done(L("Homebrew가 없어요.", "Homebrew is not installed.")); return }
        DispatchQueue.global().async {
            log(L("scrcpy 설치 시작 (brew)", "Installing scrcpy (brew)"))
            let r = run(brew, ["install", "scrcpy"], env: ["HOMEBREW_NO_AUTO_UPDATE": "1"], timeout: 900)
            let ok = isInstalled
            log((ok ? L("scrcpy 설치 완료", "scrcpy installed") : L("scrcpy 설치 실패: ", "scrcpy install failed: ") + String(r.out.suffix(300))))
            done(ok ? nil : L("설치하지 못했어요 (코드 ", "Couldn't install (code ") + "\(r.code)). " + String(r.out.suffix(200)))
        }
    }

    // MARK: 실행 · 중지

    /// 무선 기기(serial)로 scrcpy를 띄운다. adb는 앱이 찾은 것을 그대로 쓴다.
    func start(adb: String, serial: String, title: String) -> (ok: Bool, message: String) {
        guard let scrcpy = ScreenMirror.findScrcpy() else {
            return (false, L("scrcpy가 설치되어 있지 않아요. 설정 창에서 '화면 미러링도 설치'를 켜 주세요.", "scrcpy is not installed. Turn on 'Also install screen mirroring' in Settings."))
        }
        if isRunning { return (true, L("이미 미러링 중이에요.", "Already mirroring.")) }

        var args = ["-s", serial,
                    "--video-bit-rate=\(quality.rawValue)",
                    "--window-title=\(title)",
                    "--stay-awake",
                    "--keyboard=uhid"]            // HID 키보드: 한글 입력 호환
        if !audio { args.append("--no-audio") }
        if alwaysOnTop { args.append("--always-on-top") }
        if turnScreenOff { args.append("--turn-screen-off") }
        if record {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            let file = recordDir.appendingPathComponent("\(appShortName) \(f.string(from: Date())).mp4")
            args.append("--record=\(file.path)")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: scrcpy)
        p.arguments = args
        // ADB: 앱의 adb를 쓰게 함 (서버 버전 불일치 방지). PATH: scrcpy 폴더를 앞에 (scrcpy-server 탐색용)
        var env = ProcessInfo.processInfo.environment
        env["ADB"] = adb
        env["PATH"] = (scrcpy as NSString).deletingLastPathComponent + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        if !FileManager.default.fileExists(atPath: mirrorLogURL.path) {
            FileManager.default.createFile(atPath: mirrorLogURL.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: mirrorLogURL) {
            h.seekToEndOfFile()
            h.write("\n===== \(Date()) scrcpy \(args.joined(separator: " "))\n".data(using: .utf8)!)
            p.standardOutput = h; p.standardError = h
        }
        stoppedByUser = false
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let code = proc.terminationStatus
            log(L("  미러링 종료, 코드 ", "  Mirroring ended, code ") + "\(code)" + (self.stoppedByUser ? L(" (사용자 중지)", " (stopped by user)") : ""))
            let byUser = self.stoppedByUser
            DispatchQueue.main.async { self.onExit(code, byUser) }
        }
        do { try p.run() } catch {
            log(L("  scrcpy 실행 실패: ", "  Failed to start scrcpy: ") + "\(error)")
            return (false, L("scrcpy를 실행하지 못했어요: ", "Couldn't start scrcpy: ") + error.localizedDescription)
        }
        process = p
        log(L("▶ 미러링 시작 pid ", "▶ Mirroring started pid ") + "\(p.processIdentifier) · \(serial) · \(scrcpy) · ADB=\(adb)")
        return (true, "")
    }

    func stop() {
        guard let p = process, p.isRunning else { return }
        stoppedByUser = true
        p.terminate()                       // SIGTERM → scrcpy가 정상 종료 (녹화 파일도 마무리)
        if !waitUntil(3, { !p.isRunning }) { kill(p.processIdentifier, SIGKILL) }
    }
}
