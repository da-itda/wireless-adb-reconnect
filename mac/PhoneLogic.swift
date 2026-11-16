// 여러 휴대폰: 구분하기, 저장 목록, 시도 순서 — Foundation만 써서 mac/tests/run.sh로 따로 시험한다
import Foundation

enum Strategy: String, CaseIterable, Codable {
    case reconnectOffline, connectOnly, ownServer, ownServerBonjour
}

struct Device: Equatable {
    let serial: String
    let state: String
    var model: String? = nil
    var isIPPort: Bool { serial.range(of: #"^\d+\.\d+\.\d+\.\d+:\d+$"#, options: .regularExpression) != nil }
    var isMdnsName: Bool { serial.contains("._adb-tls-connect.") }
    var isWireless: Bool { isIPPort || isMdnsName }
}

/// "adb-<serialno>-<suffix>[._adb-tls-connect._tcp]" → serialno (serialno 안에도 '-'가 있을 수 있어 마지막 조각만 뗀다)
func phoneId(fromMdnsName name: String) -> String? {
    let base = name.components(separatedBy: "._adb").first ?? name
    guard base.hasPrefix("adb-"), let dash = base.lastIndex(of: "-") else { return nil }
    let start = base.index(base.startIndex, offsetBy: 4)
    guard dash > start, base.index(after: dash) < base.endIndex else { return nil }
    return String(base[start..<dash])
}

/// 한 휴대폰의 adb serial들 (mDNS 이름과 IP:포트로 두 번 보일 수 있다)
struct PhoneDevices: Equatable {
    let id: String
    var serials: [Device]
    var isConnected: Bool { serials.contains { $0.state == "device" } }
    var isOffline: Bool { serials.contains { $0.state == "offline" } }
    var anySerial: String? {
        let connected = serials.filter { $0.state == "device" }
        return (connected.first { $0.isMdnsName } ?? connected.first)?.serial
    }
}

func groupWireless(_ devices: [Device], resolve: (String) -> String?) -> [PhoneDevices] {
    var groups: [PhoneDevices] = []
    for d in devices where d.isWireless {
        guard let id = resolve(d.serial) else { continue }
        if let i = groups.firstIndex(where: { $0.id == id }) { groups[i].serials.append(d) }
        else { groups.append(PhoneDevices(id: id, serials: [d])) }
    }
    return groups
}

/// 이 휴대폰 말고 연결된 기기(다른 휴대폰, USB, 에뮬레이터)가 있는지 — 있으면 서버를 재시작하지 않는다
func otherDevicesConnected(_ devices: [Device], excluding phoneSerials: [String]) -> Bool {
    devices.contains { $0.state == "device" && !phoneSerials.contains($0.serial) }
}

// MARK: - 저장된 휴대폰 목록

struct KnownPhone: Codable, Equatable {
    var id: String
    var name: String
    var android: String?
    var mdnsName: String?
    var lastAddr: String?
    var winner: Strategy?
    var enabled: Bool
    var addedAt: Date
}

/// UserDefaults "phones"(JSON). 1.4.1까지의 한 대용 값(lastAddr·winner·lastPhoneName)은 처음 저장하는 휴대폰이 넘겨받는다
final class PhoneStore {
    private let defaults: UserDefaults
    private let lock = NSRecursiveLock()
    private var phones: [KnownPhone]
    private var saved: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoded = defaults.data(forKey: "phones").flatMap { try? JSONDecoder().decode([KnownPhone].self, from: $0) }
        phones = decoded ?? []
        saved = decoded != nil
    }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    private func save() {
        if let data = try? JSONEncoder().encode(phones) { defaults.set(data, forKey: "phones") }
        saved = true
    }

    var all: [KnownPhone] { locked { phones } }

    func phone(_ id: String) -> KnownPhone? { locked { phones.first { $0.id == id } } }

    var legacyAddr: String? { locked { saved ? nil : defaults.string(forKey: "lastAddr") } }
    var legacyWinner: Strategy? { locked { saved ? nil : defaults.string(forKey: "winner").flatMap(Strategy.init) } }

    var lastMirrored: String? {
        get { defaults.string(forKey: "lastMirroredPhone") }
        set { defaults.set(newValue, forKey: "lastMirroredPhone") }
    }

    @discardableResult
    func seen(id: String, name: String, android: String?, mdnsName: String?, addr: String?) -> KnownPhone {
        locked {
            if let i = phones.firstIndex(where: { $0.id == id }) {
                if !name.isEmpty { phones[i].name = name }
                if let android { phones[i].android = android }
                if let mdnsName { phones[i].mdnsName = mdnsName }
                if let addr { phones[i].lastAddr = addr }
                save()
                return phones[i]
            }
            var p = KnownPhone(id: id, name: name, android: android, mdnsName: mdnsName, lastAddr: addr,
                               winner: nil, enabled: true, addedAt: Date())
            if !saved {
                p.lastAddr = addr ?? defaults.string(forKey: "lastAddr")
                p.winner = defaults.string(forKey: "winner").flatMap(Strategy.init)
                if name.isEmpty, let old = defaults.string(forKey: "lastPhoneName") { p.name = old }
                ["lastAddr", "winner", "lastPhoneName"].forEach(defaults.removeObject)
            }
            phones.append(p)
            save()
            return p
        }
    }

    func update(_ id: String, _ change: (inout KnownPhone) -> Void) {
        locked {
            guard let i = phones.firstIndex(where: { $0.id == id }) else { return }
            change(&phones[i])
            save()
        }
    }

    func setEnabled(_ id: String, _ on: Bool) { update(id) { $0.enabled = on } }

    func forget(_ id: String) { locked { phones.removeAll { $0.id == id }; save() } }
}

// MARK: - 판단

/// 끊지 않는 방법 → 기억한 방법 → 나머지. 다른 기기가 연결돼 있으면 서버를 재시작하는 방법은 빼고 restartSkipped로 알린다
func fixOrder(isOffline: Bool, othersConnected: Bool, permissionDenied: Bool, winner: Strategy?) -> (order: [Strategy], restartSkipped: Bool) {
    var order: [Strategy] = isOffline ? [.reconnectOffline] : []
    let quick = order.count
    order.append(.connectOnly)
    if !othersConnected && !permissionDenied { order += [.ownServer, .ownServerBonjour] }
    if let w = winner, let i = order.firstIndex(of: w), i > quick {
        order.remove(at: i); order.insert(w, at: quick)
    }
    return (order, othersConnected && !permissionDenied)
}

enum Overall: Equatable { case noPhones, allConnected, someDropped }

func overall(phones: [KnownPhone], connectedIds: Set<String>) -> Overall {
    if phones.isEmpty { return .noPhones }
    return phones.allSatisfy { !$0.enabled || connectedIds.contains($0.id) } ? .allConnected : .someDropped
}

/// ⌘M: 마지막에 미러링한 휴대폰(연결됨) → 연결된 첫 휴대폰 → 마지막 휴대폰(켜짐) → 켜진 첫 휴대폰
func mirrorTarget(phones: [KnownPhone], connectedIds: Set<String>, lastMirrored: String?) -> String? {
    let enabled = phones.filter(\.enabled)
    if let last = lastMirrored, connectedIds.contains(last) { return last }
    if let first = phones.first(where: { connectedIds.contains($0.id) }) { return first.id }
    if let last = lastMirrored, enabled.contains(where: { $0.id == last }) { return last }
    return enabled.first?.id
}

/// "Successfully paired to IP:port [guid=adb-<serialno>-<suffix>]" → serialno
func pairedPhoneId(fromPairOutput out: String) -> String? {
    guard let r = out.range(of: #"guid=adb-[^\]\s]+"#, options: .regularExpression) else { return nil }
    return phoneId(fromMdnsName: String(out[r].dropFirst(5)))
}

/// 앱이 띄우는 adb 서버의 환경. adb의 자동 연결은 끈다 — mDNS 이름으로 붙은 연결은 `adb disconnect`로 끊을 수 없어서
/// '연결 유지'를 끈 휴대폰을 끊어 둘 수 없다. 연결은 모두 앱이 `adb connect IP:포트`로 만든다
func ownServerEnv(bonjour: Bool) -> [String: String] {
    var env = ["ADB_MDNS_AUTO_CONNECT": "0"]
    if bonjour { env["ADB_MDNS_OPENSCREEN"] = "0" }
    return env
}

/// IP:포트 serial이 offline이면 휴대폰에 물어볼 수 없다 → 저장된 주소로 어느 휴대폰인지 찾는다
func idForSavedAddress(_ serial: String, phones: [KnownPhone]) -> String? {
    guard Device(serial: serial, state: "").isIPPort else { return nil }
    return phones.first { $0.lastAddr == serial }?.id
}

/// 페어링 창: 방금 페어링한 휴대폰(id를 알면 그것만). 창을 열 때 목록에 있던 휴대폰과 지운 휴대폰은 새 휴대폰이 아니다
func newlyConnectedPhone(connected: Set<String>, knownAtOpen: Set<String>, forgotten: Set<String>, target: String?) -> String? {
    if let target { return connected.contains(target) ? target : nil }
    return connected.sorted().first { !knownAtOpen.contains($0) && !forgotten.contains($0) }
}
