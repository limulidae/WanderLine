import CoreLocation
import SwiftUI
import UniformTypeIdentifiers

/// 第一次使用的設定：全部在手機上做完，不用電腦
struct SetupScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pairing = PairingHost.shared
    @ObservedObject private var vpn = LoopbackVPN.shared
    @StateObject private var location = LocationAuth()

    @State private var hasPairing = PairingStore.exists
    @State private var ddiReady = DiskImage.ready
    @State private var ddiProgress: Double?
    @State private var vpnBusy = false
    @State private var importing = false
    @State private var testing = false
    @State private var message: (ok: Bool, text: String)?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // 開發者模式沒有公開的檢查方法；配對要在「開發者模式」那頁做，配對好了就代表已經打開
                    step(1, "打開「開發者模式」", hasPairing ? "已經打開了。" : "設定 → 隱私權與安全性 → 開發者模式，打開後手機會重新開機。", done: hasPairing)
                    step(2, "配對這支 iPhone", pairingText, done: hasPairing) { pairingControls }
                    step(3, "加入本機 VPN", "讓 WanderLine 連到這支手機自己的開發者服務。只在手機內部繞一圈，不會連到外面，也不影響上網。系統問「加入 VPN 設定」時按「允許」。", done: vpn.installed == true) {
                        if vpn.installed != true {
                            Button {
                                vpnBusy = true
                                Task {
                                    do { try await vpn.ensureOn(); message = nil } catch { message = (false, error.localizedDescription) }
                                    vpnBusy = false
                                }
                            } label: { busyLabel("加入 VPN", busy: vpnBusy) }
                            .disabled(vpnBusy)
                        }
                    }
                    step(4, "下載開發者映像檔", "改位置的服務要用到它，約 17 MB，只要下載一次。手機重開機後 WanderLine 會自己重新掛上。", done: ddiReady) {
                        if !ddiReady {
                            if let p = ddiProgress {
                                ProgressView(value: p)
                            } else {
                                Button("下載") { downloadDDI() }
                            }
                        }
                    }
                    step(5, "允許「永遠」使用位置", location.text, done: location.status == .authorizedAlways) {
                        switch location.status {
                        case .authorizedAlways:
                            EmptyView()
                        case .notDetermined:
                            Button("允許使用位置") { location.ask() }
                        default:
                            Button("打開 WanderLine 的設定") {
                                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                            }
                        }
                    }
                } header: { Text("第一次使用（全部在手機上完成）") }

                Section {
                    Button {
                        testing = true
                        message = nil
                        Task {
                            do {
                                try await DeviceLink.shared.test()
                                message = (true, "連線成功，可以開始改位置了")
                            } catch {
                                message = (false, error.localizedDescription)
                            }
                            testing = false
                            ddiReady = DiskImage.ready
                            await vpn.refresh()
                        }
                    } label: { busyLabel("測試連線", busy: testing) }
                    .disabled(testing || !hasPairing)
                    if let m = message {
                        Label(m.text, systemImage: m.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(m.ok ? .green : .orange)
                            .font(.footnote)
                            .contextMenu {
                                // 長按：複製技術細節（回報問題用，畫面上不顯示）
                                if !m.ok && !LinkError.lastTech.isEmpty {
                                    Button("複製錯誤細節", systemImage: "doc.on.doc") { UIPasteboard.general.string = LinkError.lastTech }
                                }
                            }
                    }
                } footer: {
                    Text("第一次測試會順便掛上開發者映像檔，要有網路，可能要等十幾秒。")
                }

                Section {
                    Button("匯入配對檔") { importing = true }
                    if hasPairing {
                        Button("刪除配對檔", role: .destructive) {
                            PairingStore.remove()
                            hasPairing = false
                            pairing.reset()
                        }
                    }
                } header: { Text("其他") } footer: {
                    Text("一般不需要：上面的「配對這支 iPhone」在手機上就能完成。這裡是給已經有配對檔的人用的。")
                }

                Section {} footer: {
                    Text("WanderLine \(Self.appVersion)")
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .xml, .data, .item]) { r in
                if case .success(let url) = r {
                    do {
                        message = (true, try PairingStore.save(from: url))
                    } catch {
                        message = (false, error.localizedDescription)
                    }
                    hasPairing = PairingStore.exists
                }
            }
            .task { await vpn.refresh() }
            .onChange(of: pairing.phase) { _, phase in
                if phase == .done { hasPairing = PairingStore.exists }
            }
        }
    }

    /// 例如「0.3 (5)」：版本號（打包編號）
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    // MARK: - 配對

    private var canPairOnPhone: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    private var pairingText: String {
        guard canPairOnPhone else {
            return "這支手機的 iOS 版本不能在手機上配對，請用最下面的「匯入配對檔」。"
        }
        switch pairing.phase {
        case .idle, .failed:
            return hasPairing
                ? "已經配對好了。手機重設或改密碼後要重新配對。"
                : "按「開始配對」，再照指示到「設定」裡點一下。"
        case .waiting:
            return "現在到「設定 → 隱私權與安全性 → 開發者模式」，點「與 WanderLine 配對」。WanderLine 會在背景等你。"
        case .pin:
            return "先輸入手機密碼，再輸入下面這組數字（通知也會顯示）："
        case .done:
            return "配對完成。"
        }
    }

    @ViewBuilder private var pairingControls: some View {
        if canPairOnPhone {
            switch pairing.phase {
            case .idle:
                Button(hasPairing ? "重新配對" : "開始配對") { pairing.start() }
            case .waiting:
                HStack {
                    ProgressView()
                    Text("等待「設定」連過來…").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { pairing.cancel() }
                }
            case .pin(let code):
                HStack {
                    Text(code)
                        .font(.system(.title, design: .monospaced).weight(.bold))
                        .kerning(4)
                        .textSelection(.enabled)
                    Spacer()
                    Button("取消") { pairing.cancel() }
                }
            case .done:
                EmptyView()
            case .failed(let text):
                VStack(alignment: .leading, spacing: 6) {
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                    Button("再試一次") { pairing.start() }
                }
            }
        }
    }

    // MARK: - 其他

    private func downloadDDI() {
        ddiProgress = 0
        Task {
            do {
                try await DiskImage.download { ddiProgress = $0 }
                message = nil
            } catch {
                message = (false, error.localizedDescription)
            }
            ddiProgress = nil
            ddiReady = DiskImage.ready
        }
    }

    private func busyLabel(_ title: String, busy: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if busy { ProgressView() }
        }
    }

    private func step<Extra: View>(_ n: Int, _ title: String, _ text: String, done: Bool, showStatus: Bool = true,
                                   @ViewBuilder extra: () -> Extra = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.blue)
                if done {
                    Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(n)").font(.footnote.weight(.bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    if showStatus && done {
                        Text("完成").font(.caption).foregroundStyle(.green)
                    }
                }
                Text(text).font(.footnote).foregroundStyle(.secondary)
                extra().font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 位置權限：設定頁第 5 步用，改了權限（從系統設定回來）會自動更新
@MainActor
final class LocationAuth: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var status: CLAuthorizationStatus
    private let manager = CLLocationManager()

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    func ask() { manager.requestWhenInUseAuthorization() }

    var text: String {
        switch status {
        case .authorizedAlways: return "已經是「永遠」，切到別的 App 時也會繼續送位置。"
        case .authorizedWhenInUse: return "現在是「使用 App 時」。切到別的 App 時要繼續送位置，請到設定裡改成「永遠」。"
        case .notDetermined: return "切到別的 App 時，WanderLine 要在背景繼續送位置。先按下面的按鈕允許，之後再到設定改成「永遠」。"
        default: return "現在不允許使用位置，請到設定裡改成「永遠」。"
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in self.status = s }
    }
}
