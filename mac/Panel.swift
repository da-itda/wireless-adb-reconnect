// 메뉴 막대 카드형 패널 (아이콘 왼쪽 클릭) — 머리(이름·상태 점·주소 복사·링크) / 구역 제목 + 아이콘 행 / 바닥(버전·설정·종료)
// 행 오른쪽 끝 기호로 누르면 무엇이 일어나는지 알린다: › 안에서 펼침, ↗ 다른 창·시스템 설정 열기, ↓ 받기, ↻ 다시 연결
// 오른쪽 클릭(또는 control-클릭)은 예전 메뉴 그대로 (⌘R ⌘M 단축키, 로그인할 때 자동 실행 등)
import AppKit
import Combine
import SwiftUI

/// 패널에 보여 줄 휴대폰 정보 (연결될 때 한 번 휴대폰에 물어본다)
struct PhoneInfo: Equatable {
    var serial: String
    var name: String
    var android: String?
    var addr: String?
    var since: Date
}

enum PanelAction { case mirror, reconnect, copyAddress, pair, diagnostics, permission, update, settings, quit, mirrorLog, optionsChanged }

final class PanelModel: ObservableObject {
    @Published var link: LinkState = .working
    /// 다시 붙이는 중일 때 보여 줄 문구 (연결하는 중… / 미러링 준비 중…)
    @Published var status = ""
    @Published var phone: PhoneInfo?
    /// 끊겼을 때 보여 줄 마지막 기기 이름
    @Published var lastName: String?
    @Published var mirroring = false
    @Published var needsPermission = false
    @Published var update: Updater.State = .unknown
    @Published var showOptions = false
    @Published var now = Date()
    var appVersion = ""
    @Published var adbVersion: String?
    let mirror: ScreenMirror
    var act: (PanelAction) -> Void = { _ in }

    init(mirror: ScreenMirror) { self.mirror = mirror }

    /// 미러링 옵션 (ScreenMirror의 UserDefaults를 그대로 쓴다)
    func binding<T>(_ key: ReferenceWritableKeyPath<ScreenMirror, T>) -> Binding<T> {
        Binding(get: { self.mirror[keyPath: key] },
                set: { self.objectWillChange.send(); self.mirror[keyPath: key] = $0; self.act(.optionsChanged) })
    }
}

// MARK: - 모양

/// 행: 마우스를 올리면 배경을 옅게 칠한다
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { RowBody(configuration: configuration) }

    struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        @State var hover = false
        var body: some View {
            configuration.label
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(configuration.isPressed ? 0.1 : hover ? 0.06 : 0)))
                .onHover { hover = $0 }
        }
    }
}

/// 바닥의 작은 테두리 버튼 (설정·종료)
struct SmallBorderButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(configuration.isPressed ? 0.1 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.2), lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// 둥근 아이콘 자리 (옅은 회색 원 안에 기호)
struct RowIcon: View {
    var symbol: String? = nil
    var image: NSImage? = nil
    var tint: Color = .primary
    var body: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.07))
            if let image {
                Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high).frame(width: 16, height: 16)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
            }
        }
        .foregroundColor(tint)
        .frame(width: 28, height: 28)
    }
}

/// 제목(+ 배지) / 회색 보조 줄 / 오른쪽 끝 기호
struct PanelRow<Trailing: View>: View {
    let icon: RowIcon
    let title: String
    var badge: String? = nil
    let detail: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if let badge {
                        Text(badge).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.18), lineWidth: 1))
                    }
                }
                Text(detail).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing.font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary.opacity(0.8))
        }
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundColor(.secondary)
            .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 1)
    }
}

/// 구역 사이 가는 선
struct PanelDivider: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 5) }
}

// MARK: - 패널 화면

struct PanelView: View {
    @ObservedObject var m: PanelModel
    /// 스냅샷: 반투명 재질 대신 단색 바탕
    var solid: Color? = nil
    @State private var copied = false

    static let androidHead: NSImage? = {
        guard let img = statusMasks.body?.copy() as? NSImage else { return nil }
        img.isTemplate = true
        return img
    }()

    var dotColor: Color {
        switch m.link {
        case .connected: return Color(hex: 0x30C25B)
        case .disconnected: return Color(hex: 0xE5484D)
        case .working: return Color(hex: 0xF5A524)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            PanelDivider()
            deviceSection
            if m.needsPermission || isUpdateShown {
                PanelDivider()
                notices
            }
            PanelDivider()
            SectionTitle(text: L("도구", "Tools"))
            Button { m.act(.pair) } label: {
                PanelRow(icon: RowIcon(symbol: "qrcode"), title: L("휴대폰 페어링", "Pair phone"), detail: L("QR 코드로 새 기기 추가", "Add a new device with a QR code")) { Image(systemName: "arrow.up.right") }
            }.buttonStyle(RowButtonStyle())
            Button { m.act(.diagnostics) } label: {
                PanelRow(icon: RowIcon(symbol: "list.bullet.rectangle"), title: L("진단 보기", "Diagnostics"), detail: L("연결 기록과 원인", "Connection history and causes")) { Image(systemName: "arrow.up.right") }
            }.buttonStyle(RowButtonStyle())
            PanelDivider()
            footer
        }
        .padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 8)
        .frame(width: 320)
        // 반투명 재질 위에 창 배경색을 한 겹 — 뒤 화면이 복잡해도 글자가 읽히게
        .background(solid ?? Color(nsColor: .windowBackgroundColor).opacity(0.72))
    }

    // 이름 + 상태 점 / 주소 + 복사 · 오른쪽 링크
    var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(appName).font(.system(size: 13, weight: .semibold))
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                }
                HStack(spacing: 5) {
                    switch m.link {
                    case .connected:
                        if let a = m.phone?.addr {
                            Text(a).font(.system(size: 12).monospacedDigit()).foregroundColor(.secondary).textSelection(.enabled)
                            Button {
                                m.act(.copyAddress)
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                            } label: {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10.5)).foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(L("주소 복사", "Copy address"))
                            .accessibilityLabel(L("주소 복사", "Copy address"))
                        } else {
                            Text(L("무선으로 연결됨", "Connected wirelessly")).font(.system(size: 12)).foregroundColor(.secondary)
                        }
                    case .working:
                        Text(m.status).font(.system(size: 12)).foregroundColor(.secondary)
                    case .disconnected:
                        Text(L("연결 끊김", "Disconnected")).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            headerLink.padding(.top, 15)
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder var headerLink: some View {
        switch m.link {
        case .connected:
            link(m.mirroring ? L("미러링 중지", "Stop mirroring") : L("화면 미러링", "Screen mirroring"), .mirror)
        case .disconnected:
            link(L("다시 연결", "Reconnect"), .reconnect)
        case .working:
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
        }
    }

    func link(_ title: String, _ a: PanelAction) -> some View {
        Button(title) { m.act(a) }.buttonStyle(.plain).font(.system(size: 13)).foregroundColor(Color(nsColor: .linkColor))
    }

    // 연결된 기기 (› 를 누르면 미러링 옵션), 끊겼으면 다시 연결 행
    @ViewBuilder var deviceSection: some View {
        if m.link == .connected, let p = m.phone {
            SectionTitle(text: L("연결된 기기", "Connected device"))
            Button { withAnimation(.easeOut(duration: 0.15)) { m.showOptions.toggle() } } label: {
                PanelRow(icon: RowIcon(image: Self.androidHead), title: p.name, badge: p.android.map { "Android \($0)" },
                         detail: (m.mirroring ? L("미러링 중", "Mirroring") + " · " : "") + sinceText(p.since)) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(m.showOptions ? 90 : 0))
                }
            }
            .buttonStyle(RowButtonStyle())
            .help(L("미러링 옵션", "Mirroring options"))
            if m.showOptions { options }
        } else {
            SectionTitle(text: L("기기", "Device"))
            Button { m.act(.reconnect) } label: {
                PanelRow(icon: RowIcon(image: Self.androidHead, tint: .secondary), title: m.lastName ?? L("휴대폰", "Phone"),
                         detail: m.link == .working ? m.status : L("연결 끊김 · 눌러서 다시 연결", "Disconnected · click to reconnect")) {
                    if m.link == .working { ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14) }
                    else { Image(systemName: "arrow.clockwise") }
                }
            }
            .buttonStyle(RowButtonStyle())
            .disabled(m.link == .working)
        }
    }

    // 미러링 옵션 (펼침)
    var options: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("", selection: m.binding(\.quality)) {
                ForEach(MirrorQuality.allCases, id: \.self) { Text($0.shortTitle).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(maxWidth: .infinity)
            optionToggle(L("소리도 전송", "Forward audio"), \.audio)
            optionToggle(L("창을 항상 위에", "Window always on top"), \.alwaysOnTop)
            optionToggle(L("미러링 중 폰 화면 끄기", "Turn phone screen off"), \.turnScreenOff)
            optionToggle(L("동영상으로 녹화 (Movies 폴더)", "Record to Movies folder"), \.record)
            HStack {
                Text(L("옵션은 다음 미러링부터 적용돼요", "Options apply to the next mirroring session")).font(.system(size: 10.5)).foregroundColor(.secondary)
                Spacer()
                Button(L("미러링 로그", "Mirroring log")) { m.act(.mirrorLog) }.buttonStyle(.plain).font(.system(size: 10.5)).foregroundColor(Color(nsColor: .linkColor))
            }
        }
        .padding(.leading, 46).padding(.trailing, 10).padding(.top, 2).padding(.bottom, 4)
    }

    func optionToggle(_ title: String, _ key: ReferenceWritableKeyPath<ScreenMirror, Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Toggle(title, isOn: m.binding(key)).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }

    var isUpdateShown: Bool {
        switch m.update {
        case .available, .installing: return true
        default: return false
        }
    }

    // 필요할 때만: 로컬 네트워크 권한, 업데이트
    @ViewBuilder var notices: some View {
        if m.needsPermission {
            Button { m.act(.permission) } label: {
                PanelRow(icon: RowIcon(symbol: "exclamationmark.triangle.fill", tint: Color(hex: 0xE8890C)), title: L("로컬 네트워크 권한이 필요해요", "Local Network permission needed"),
                         detail: L("시스템 설정에서 이 앱을 허용", "Allow this app in System Settings")) { Image(systemName: "arrow.up.right") }
            }.buttonStyle(RowButtonStyle())
        }
        switch m.update {
        case .available(let v):
            Button { m.act(.update) } label: {
                PanelRow(icon: RowIcon(symbol: "arrow.down.circle", tint: Color(nsColor: .linkColor)), title: L("업데이트 {0}", "Update {0}", v),
                         detail: L("받아서 바꾼 뒤 다시 실행해요", "Downloads, replaces and relaunches")) { Image(systemName: "arrow.down") }
            }.buttonStyle(RowButtonStyle())
        case .installing(let v):
            PanelRow(icon: RowIcon(symbol: "arrow.down.circle", tint: Color(nsColor: .linkColor)), title: L("업데이트 {0}", "Update {0}", v),
                     detail: L("업데이트하는 중…", "Updating…")) { ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14) }
                .padding(.horizontal, 8).padding(.vertical, 5)
        default: EmptyView()
        }
    }

    // 버전 · adb 버전 / 설정 · 종료
    var footer: some View {
        HStack(spacing: 6) {
            Text("v\(m.appVersion)" + (m.adbVersion.map { " · adb \($0)" } ?? ""))
                .font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
            Spacer()
            Button(L("설정", "Settings")) { m.act(.settings) }.buttonStyle(SmallBorderButton())
            Button(L("종료", "Quit")) { m.act(.quit) }.buttonStyle(SmallBorderButton())
                .help(L("종료 (adb 서버도 종료)", "Quit (stops adb server)"))
        }
        .padding(.horizontal, 8).padding(.top, 1)
    }

    func sinceText(_ d: Date) -> String {
        let s = max(0, m.now.timeIntervalSince(d))
        if s < 60 { return L("방금 연결됨", "Connected just now") }
        if s < 3600 { return L("{0}분째 연결", "Connected for {0} min", Int(s / 60)) }
        if s < 86400 { return L("{0}시간째 연결", "Connected for {0} h", Int(s / 3600)) }
        return L("{0}일째 연결", "Connected for {0} d", Int(s / 86400))
    }
}

// MARK: - 패널 창

/// 테두리 없는 패널: 아이콘 바로 아래, 바깥을 누르거나 Esc로 닫힘
final class MenuPanel {
    final class Window: NSPanel {
        var onEscape: () -> Void = {}
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { onEscape() }
    }

    let window: Window
    let host: NSHostingView<PanelView>
    private var monitors: [Any] = []
    private var sub: AnyCancellable?
    private weak var button: NSStatusBarButton?
    var isShown: Bool { window.isVisible }

    init(model: PanelModel) {
        host = NSHostingView(rootView: PanelView(m: model))
        window = Window(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.level = .popUpMenu
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.separatorColor.cgColor
        host.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: bg.leadingAnchor), host.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
                                     host.topAnchor.constraint(equalTo: bg.topAnchor), host.bottomAnchor.constraint(equalTo: bg.bottomAnchor)])
        window.contentView = bg
        window.onEscape = { [weak self] in self?.close() }
        // 내용이 바뀌면(옵션 펼침, 알림 줄 등) 크기를 다시 맞춘다
        sub = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { if self?.isShown == true { self?.fit() } }
        }
    }

    func show(below button: NSStatusBarButton) {
        self.button = button
        fit()
        window.makeKeyAndOrderFront(nil)
        button.highlight(true)
        // 바깥(다른 앱) 클릭 → 닫기. 이 앱의 다른 창 클릭도 닫기. 아이콘 위 클릭은 statusClicked의 토글이 처리
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.onIcon == false { self?.close() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            if let self, e.window !== self.window, !self.onIcon { self.close() }
            return e
        } as Any)
    }

    /// 마우스가 메뉴 막대 아이콘 위에 있는지 (클릭 이벤트의 창으로는 가려낼 수 없음)
    private var onIcon: Bool {
        guard let button, let bw = button.window else { return false }
        return bw.convertToScreen(button.convert(button.bounds, to: nil)).contains(NSEvent.mouseLocation)
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        button?.highlight(false)
        window.orderOut(nil)
    }

    /// 내용 크기에 맞추고 위쪽을 아이콘 아래에 고정 (옵션을 펼치면 아래로 늘어남)
    func fit() {
        guard let button, let bw = button.window else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let b = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = (bw.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = b.minX - 8
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        window.setFrame(NSRect(x: x, y: b.minY - 6 - size.height, width: size.width, height: size.height), display: true)
    }
}
