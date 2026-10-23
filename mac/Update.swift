// 앱 안 업데이트: 일주일에 한 번 GitHub 최신 릴리스를 확인하고, 메뉴에서 누르면 받아서 바꾼 뒤 다시 실행한다.
// 받은 zip은 SHA256SUMS.txt와 맞는지, 같은 개발자(Team ID)·같은 번들 ID·Apple 공증인지 확인한 뒤에만 바꾼다.
import AppKit
import CryptoKit

let releaseRepo = "da-itda/wireless-adb-reconnect"

/// "1.2.0" < "1.10.0" 처럼 숫자로 비교
func isNewer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
        let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
        if p != q { return p > q }
    }
    return false
}

final class Updater {
    enum State: Equatable { case unknown, checking, latest, available(String), installing(String) }

    /// 지금 버전 (WAR_FAKE_VERSION=1.0.0 처럼 낮춰서 업데이트를 시험할 수 있다 — 개발용)
    let current = ProcessInfo.processInfo.environment["WAR_FAKE_VERSION"]
        ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    private(set) var state: State = .unknown
    var onChange: () -> Void = {}
    private let defaults = UserDefaults.standard
    private static let week: TimeInterval = 7 * 24 * 3600

    init() {
        if let v = defaults.string(forKey: "updateLatest") { state = isNewer(v, than: current) ? .available(v) : .latest }
    }

    private func set(_ s: State) { state = s; onChange() }

    /// 마지막 확인에서 일주일이 지났으면 확인 (실행할 때와 한 시간마다 부른다)
    func checkIfDue() {
        let last = defaults.object(forKey: "updateCheckedAt") as? Date ?? .distantPast
        if Date().timeIntervalSince(last) >= Updater.week { check() }
    }

    func check() {
        switch state { case .checking, .installing: return; default: break }
        let before = state
        set(.checking)
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(releaseRepo)/releases/latest")!, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("WirelessADBReconnect/\(current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            var latest: String?
            if let data, (resp as? HTTPURLResponse)?.statusCode == 200,
               let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = j["tag_name"] as? String {
                latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            }
            DispatchQueue.main.async {
                guard let latest else {
                    log(L("업데이트 확인 실패: ", "Update check failed: ") + (err?.localizedDescription ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"))
                    self.set(before == .checking ? .unknown : before)
                    return
                }
                self.defaults.set(latest, forKey: "updateLatest")
                self.defaults.set(Date(), forKey: "updateCheckedAt")
                log(L("업데이트 확인: 지금 ", "Update check: current ") + self.current + L(", 최신 ", ", latest ") + latest)
                self.set(isNewer(latest, than: self.current) ? .available(latest) : .latest)
            }
        }.resume()
    }

    func install() {
        guard case .available(let v) = state else { return }
        set(.installing(v))
        DispatchQueue.global().async {
            let r = self.downloadAndReplace(v)
            DispatchQueue.main.async {
                switch r {
                case .success(let backup): self.relaunch(removing: backup)
                case .failure(let e):
                    log(L("업데이트 실패: ", "Update failed: ") + e.message)
                    self.set(.available(v))
                    Notifier.shared.post(ok: false, title: L("업데이트하지 못했어요", "Couldn't update"), body: e.message)
                }
            }
        }
    }

    struct Failure: Error { let message: String }

    /// 받기 → 체크섬 → 풀기 → 서명·공증 확인 → 지금 앱을 백업 이름으로 옮기고 새 앱을 제자리에 (실패하면 되돌림)
    private func downloadAndReplace(_ v: String) -> Result<URL, Failure> {
        let fm = FileManager.default
        let base = "https://github.com/\(releaseRepo)/releases/download/v\(v)/"
        let name = "WirelessADBReconnect-\(v)-mac.zip"
        let dir = fm.temporaryDirectory.appendingPathComponent("wireless-adb-reconnect-update")
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let zip = dir.appendingPathComponent(name), sums = dir.appendingPathComponent("SHA256SUMS.txt")
        log(L("업데이트 받는 중: ", "Downloading update: ") + base + name)
        if let e = download(base + name, to: zip) ?? download(base + "SHA256SUMS.txt", to: sums) {
            return .failure(Failure(message: L("받지 못했어요: ", "Download failed: ") + e))
        }
        guard let data = try? Data(contentsOf: zip, options: .mappedIfSafe), let list = try? String(contentsOf: sums, encoding: .utf8),
              let line = list.split(separator: "\n").first(where: { $0.hasSuffix(" " + name) }),
              line.split(separator: " ").first?.lowercased() == SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
        else { return .failure(Failure(message: L("받은 파일의 체크섬이 맞지 않아요", "Checksum of the download doesn't match"))) }

        let x = dir.appendingPathComponent("x")
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, x.path], timeout: 120).code == 0,
              let newApp = (try? fm.contentsOfDirectory(at: x, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "app" })
        else { return .failure(Failure(message: L("압축을 풀지 못했어요", "Couldn't unzip the update"))) }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path], timeout: 60).code == 0,
              let mine = teamID(Bundle.main.bundleURL), teamID(newApp) == mine,
              Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier
        else { return .failure(Failure(message: L("서명이 이 앱과 같은 개발자가 아니에요", "The update isn't signed by the same developer"))) }
        guard run("/usr/sbin/spctl", ["--assess", "--type", "execute", newApp.path], timeout: 60).code == 0
        else { return .failure(Failure(message: L("Apple 공증을 확인하지 못했어요", "Couldn't verify Apple notarization"))) }

        // 실행 중인 앱도 옮길 수 있다 → 다시 실행할 때까지 백업으로 두었다가 지운다
        let target = Bundle.main.bundleURL
        let backup = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).old")
        try? fm.removeItem(at: backup)
        do { try fm.moveItem(at: target, to: backup) } catch {
            return .failure(Failure(message: L("앱을 바꿀 수 없어요 (폴더 권한): ", "Can't replace the app (folder permission): ") + target.deletingLastPathComponent().path))
        }
        do { try fm.moveItem(at: newApp, to: target) } catch {
            try? fm.moveItem(at: backup, to: target)
            return .failure(Failure(message: L("새 앱을 넣지 못해 원래대로 되돌렸어요", "Couldn't place the new app; restored the old one")))
        }
        log(L("업데이트 설치: ", "Update installed: ") + "\(current) → \(v)")
        return .success(backup)
    }

    private func download(_ url: String, to dest: URL) -> String? {
        let sem = DispatchSemaphore(value: 0)
        var e: String?
        URLSession.shared.downloadTask(with: URL(string: url)!) { tmp, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let tmp, code == 200 {
                do { try FileManager.default.moveItem(at: tmp, to: dest) } catch { e = "\(error.localizedDescription)" }
            } else { e = err?.localizedDescription ?? "HTTP \(code)" }
            sem.signal()
        }.resume()
        sem.wait()
        return e
    }

    private func teamID(_ app: URL) -> String? {
        run("/usr/bin/codesign", ["-dv", app.path], timeout: 30).out.split(separator: "\n")
            .first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst("TeamIdentifier=".count)) }
            .flatMap { $0 == "not set" ? nil : $0 }
    }

    /// 지금 앱이 끝나면(adb 서버도 함께) 새 앱을 연다
    private func relaunch(removing backup: URL) {
        let target = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; rm -rf '\(backup.path)'; /usr/bin/open '\(target)'"]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// 메뉴 항목 자리에 도는 동그라미 + 글자 (업데이트 확인·설치 중)
final class SpinnerMenuView: NSView {
    init(_ text: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        autoresizingMask = .width
        let spin = NSProgressIndicator(frame: NSRect(x: 4, y: 3, width: 16, height: 16))
        spin.style = .spinning
        spin.controlSize = .small
        spin.startAnimation(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .menuFont(ofSize: 0)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 22, y: 3, width: 210, height: 16)
        addSubview(spin)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }
}
