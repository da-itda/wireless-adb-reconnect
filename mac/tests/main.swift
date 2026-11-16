import Foundation

var failures = 0
func check(_ c: Bool, _ name: String) {
    if !c { failures += 1; print("FAIL \(name)") }
}

func testPhoneIdFromMdnsName() {
    check(phoneId(fromMdnsName: "adb-R5CR10ABCD-AbC12x._adb-tls-connect._tcp") == "R5CR10ABCD", "full service name")
    check(phoneId(fromMdnsName: "adb-R5CR10ABCD-AbC12x") == "R5CR10ABCD", "bare name")
    check(phoneId(fromMdnsName: "adb-emu-5554-xyz123") == "emu-5554", "serial with dash")
    check(phoneId(fromMdnsName: "192.168.0.21:41235") == nil, "ip:port")
    check(phoneId(fromMdnsName: "adb-nosuffix") == nil, "no suffix")
}

func testGroupsDuplicateSerials() {
    let ds = [Device(serial: "adb-AAA-x1._adb-tls-connect._tcp", state: "device"),
              Device(serial: "192.168.0.21:41235", state: "device"),
              Device(serial: "adb-BBB-y2._adb-tls-connect._tcp", state: "offline"),
              Device(serial: "USB123", state: "device")]
    let g = groupWireless(ds) { $0 == "192.168.0.21:41235" ? "AAA" : phoneId(fromMdnsName: $0) }
    check(g.map(\.id) == ["AAA", "BBB"], "grouped ids")
    check(g.count == 2 && g[0].serials.count == 2 && g[0].isConnected, "AAA has both serials")
    check(g.first?.anySerial == "adb-AAA-x1._adb-tls-connect._tcp", "prefers mDNS serial")
    check(g.count == 2 && !g[1].isConnected && g[1].isOffline, "BBB offline")
}

func testUnresolvedSerialIsSkipped() {
    let ds = [Device(serial: "192.168.0.30:5555", state: "unauthorized")]
    check(groupWireless(ds) { _ in nil }.isEmpty, "unresolved dropped")
}

func testOtherDevicesConnected() {
    let ds = [Device(serial: "adb-AAA-x1._adb-tls-connect._tcp", state: "offline"), Device(serial: "USB123", state: "device")]
    check(otherDevicesConnected(ds, excluding: ["adb-AAA-x1._adb-tls-connect._tcp"]), "usb counts as other")
    check(!otherDevicesConnected([ds[0]], excluding: [ds[0].serial]), "only itself")
}


func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "war-test-\(UUID())")! }

func testSeenAddsEnabledInOrder() {
    let s = PhoneStore(defaults: freshDefaults())
    s.seen(id: "AAA", name: "Pixel 8", android: "15", mdnsName: nil, addr: "1.2.3.4:5")
    s.seen(id: "BBB", name: "Galaxy", android: nil, mdnsName: nil, addr: nil)
    check(s.all.map(\.id) == ["AAA", "BBB"] && s.all.allSatisfy(\.enabled), "added, enabled, ordered")
    s.seen(id: "AAA", name: "Pixel 8", android: nil, mdnsName: "adb-AAA-x", addr: nil)
    check(s.phone("AAA")?.android == "15" && s.phone("AAA")?.lastAddr == "1.2.3.4:5", "nil does not overwrite")
    check(s.phone("AAA")?.mdnsName == "adb-AAA-x", "mdnsName updated")
}

func testPersistsAcrossInstances() {
    let d = freshDefaults()
    PhoneStore(defaults: d).seen(id: "AAA", name: "P", android: nil, mdnsName: nil, addr: nil)
    let s2 = PhoneStore(defaults: d); s2.setEnabled("AAA", false)
    check(PhoneStore(defaults: d).phone("AAA")?.enabled == false, "saved")
}

func testMigratesLegacyKeysOnce() {
    let d = freshDefaults()
    d.set("10.0.0.2:4000", forKey: "lastAddr"); d.set("ownServer", forKey: "winner"); d.set("Old Name", forKey: "lastPhoneName")
    let s = PhoneStore(defaults: d)
    check(s.legacyAddr == "10.0.0.2:4000" && s.legacyWinner == .ownServer, "legacy readable before first phone")
    let p = s.seen(id: "AAA", name: "", android: nil, mdnsName: nil, addr: nil)
    check(p.lastAddr == "10.0.0.2:4000" && p.winner == .ownServer && p.name == "Old Name", "adopted")
    check(d.string(forKey: "lastAddr") == nil && d.string(forKey: "winner") == nil, "legacy removed")
    check(s.seen(id: "BBB", name: "B", android: nil, mdnsName: nil, addr: nil).winner == nil, "only first phone adopts")
}

func testForget() {
    let s = PhoneStore(defaults: freshDefaults())
    s.seen(id: "AAA", name: "P", android: nil, mdnsName: nil, addr: nil); s.setEnabled("AAA", false); s.forget("AAA")
    check(s.all.isEmpty, "forgotten")
    check(s.seen(id: "AAA", name: "P", android: nil, mdnsName: nil, addr: nil).enabled, "re-added enabled")
}

func testCorruptStoreLoadsEmpty() {
    let d = freshDefaults(); d.set(Data("not json".utf8), forKey: "phones"); d.set("10.0.0.2:4000", forKey: "lastAddr")
    let s = PhoneStore(defaults: d)
    check(s.all.isEmpty && s.legacyAddr == "10.0.0.2:4000", "corrupt -> empty, legacy kept")
}

func testLastMirrored() {
    let d = freshDefaults()
    PhoneStore(defaults: d).lastMirrored = "AAA"
    check(PhoneStore(defaults: d).lastMirrored == "AAA", "last mirrored saved")
}


func phone(_ id: String, enabled: Bool) -> KnownPhone {
    KnownPhone(id: id, name: id, android: nil, mdnsName: nil, lastAddr: nil, winner: nil, enabled: enabled, addedAt: Date())
}

func testFixOrderAloneMatchesToday() {
    let r = fixOrder(isOffline: false, othersConnected: false, permissionDenied: false, winner: nil)
    check(r.order == [.connectOnly, .ownServer, .ownServerBonjour] && !r.restartSkipped, "all fixes")
}

func testRuleASkipsRestartWhenOnlyUsbConnected() {
    let r = fixOrder(isOffline: true, othersConnected: true, permissionDenied: false, winner: .ownServer)
    check(r.order == [.reconnectOffline, .connectOnly] && r.restartSkipped, "no restart, offer shown")
}

func testWinnerMovesForward() {
    let r = fixOrder(isOffline: true, othersConnected: false, permissionDenied: false, winner: .ownServerBonjour)
    check(r.order == [.reconnectOffline, .ownServerBonjour, .connectOnly, .ownServer], "winner after offline")
}

func testPermissionDeniedNoRestartNoOffer() {
    let r = fixOrder(isOffline: false, othersConnected: true, permissionDenied: true, winner: nil)
    check(r.order == [.connectOnly] && !r.restartSkipped, "permission case")
}

func testOverall() {
    let a = phone("AAA", enabled: true), b = phone("BBB", enabled: false)
    check(overall(phones: [], connectedIds: []) == .noPhones, "empty")
    check(overall(phones: [a, b], connectedIds: ["AAA"]) == .allConnected, "off phone ignored")
    check(overall(phones: [a], connectedIds: []) == .someDropped, "dropped")
    check(overall(phones: [b], connectedIds: []) == .allConnected, "none enabled")
}

func testMirrorTarget() {
    let a = phone("AAA", enabled: true), b = phone("BBB", enabled: true), c = phone("CCC", enabled: false)
    check(mirrorTarget(phones: [a, b], connectedIds: ["AAA", "BBB"], lastMirrored: "BBB") == "BBB", "last mirrored connected")
    check(mirrorTarget(phones: [a, b], connectedIds: ["BBB"], lastMirrored: "AAA") == "BBB", "first connected")
    check(mirrorTarget(phones: [a, b], connectedIds: [], lastMirrored: "BBB") == "BBB", "last mirrored enabled")
    check(mirrorTarget(phones: [c, a], connectedIds: [], lastMirrored: "CCC") == "AAA", "skips off")
    check(mirrorTarget(phones: [c], connectedIds: [], lastMirrored: nil) == nil, "nothing")
}

func testPairedPhoneId() {
    check(pairedPhoneId(fromPairOutput: "Successfully paired to 192.168.0.21:37000 [guid=adb-R5CR10ABCD-AbC12x]") == "R5CR10ABCD", "guid")
    check(pairedPhoneId(fromPairOutput: "Failed: Wrong password or connection was dropped.") == nil, "failure")
}


func testOwnServerEnvTurnsOffAutoConnect() {
    check(ownServerEnv(bonjour: false) == ["ADB_MDNS_AUTO_CONNECT": "0"], "auto-connect off")
    check(ownServerEnv(bonjour: true) == ["ADB_MDNS_AUTO_CONNECT": "0", "ADB_MDNS_OPENSCREEN": "0"], "bonjour backend too")
}

func testOfflineIpPortMatchesSavedAddress() {
    var a = phone("AAA", enabled: true); a.lastAddr = "10.0.0.5:4000"
    check(idForSavedAddress("10.0.0.5:4000", phones: [a]) == "AAA", "matched by saved address")
    check(idForSavedAddress("10.0.0.6:4000", phones: [a]) == nil, "unknown address")
    check(idForSavedAddress("adb-AAA-x._adb-tls-connect._tcp", phones: [a]) == nil, "not ip:port")
}

func testNewlyConnectedSkipsKnownAndForgotten() {
    check(newlyConnectedPhone(connected: ["AAA", "BBB"], knownAtOpen: ["AAA"], forgotten: [], target: nil) == "BBB", "new phone")
    check(newlyConnectedPhone(connected: ["CCC"], knownAtOpen: [], forgotten: ["CCC"], target: nil) == nil, "forgotten is not new")
    check(newlyConnectedPhone(connected: ["AAA"], knownAtOpen: ["AAA"], forgotten: [], target: "AAA") == "AAA", "target by guid")
    check(newlyConnectedPhone(connected: ["BBB"], knownAtOpen: [], forgotten: [], target: "AAA") == nil, "target not connected")
}

let tests: [() -> Void] = [
    testPhoneIdFromMdnsName, testGroupsDuplicateSerials, testUnresolvedSerialIsSkipped, testOtherDevicesConnected,
    testSeenAddsEnabledInOrder, testPersistsAcrossInstances, testMigratesLegacyKeysOnce, testForget, testCorruptStoreLoadsEmpty,
    testLastMirrored, testFixOrderAloneMatchesToday, testRuleASkipsRestartWhenOnlyUsbConnected, testWinnerMovesForward,
    testPermissionDeniedNoRestartNoOffer, testOverall, testMirrorTarget, testPairedPhoneId,
    testOwnServerEnvTurnsOffAutoConnect, testOfflineIpPortMatchesSavedAddress, testNewlyConnectedSkipsKnownAndForgotten,
]
tests.forEach { $0() }
print("\(failures) failed")
exit(failures == 0 ? 0 : 1)
