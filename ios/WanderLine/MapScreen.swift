import MapKit
import SwiftUI
import UniformTypeIdentifiers

enum PanelTab: String, CaseIterable, Identifiable {
    case point, route
    var id: String { rawValue }
    var label: String { self == .point ? "定點" : "路線" }
}

struct MapScreen: View {
    @StateObject private var engine = Engine.shared
    @StateObject private var routes = RouteStore.shared
    @AppStorage("speedKmh") private var speed = 4.5
    @AppStorage("snapToStreets") private var snapToStreets = true
    @AppStorage("wobble") private var wobble = true
    @AppStorage("walkMode") private var modeRaw = WalkMode.once.rawValue

    // 一打開先看手機現在的位置；拿不到位置時才用台北
    @State private var camera: MapCameraPosition = .userLocation(fallback: .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 25.0418, longitude: 121.5654), latitudinalMeters: 1200, longitudinalMeters: 1200)))
    @State private var tab: PanelTab = .point
    @State private var picked: CLLocationCoordinate2D?
    @State private var waypoints: [CLLocationCoordinate2D] = []
    @State private var snapped: [CLLocationCoordinate2D]?
    @State private var fixedName: String?          // 匯入的 GPX 或存過的路線（整條照走，不能拖點）
    @State private var snapping = false
    @State private var snapNote: String?
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var showSetup = false
    @State private var showGPX = false
    @State private var showSave = false
    @State private var saveName = ""
    // 讓地點出現在「看得到的地圖」正中央（扣掉上面搜尋列、下面面板）
    @State private var mapFrame: CGRect = .zero
    @State private var searchFrame: CGRect = .zero
    @State private var panelFrame: CGRect = .zero
    @State private var mapProxy: MapProxy?
    @State private var pendingCenter: CLLocationCoordinate2D?
    @State private var lastRegion: MKCoordinateRegion?

    private var mode: WalkMode { WalkMode(rawValue: modeRaw) ?? .once }
    private var path: [CLLocationCoordinate2D] {
        if fixedName != nil { return snapped ?? [] }
        return snapToStreets ? (snapped ?? waypoints) : waypoints
    }

    var body: some View {
        ZStack(alignment: .top) {
            map
            VStack(spacing: 8) {
                searchBar
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { searchFrame = $0 }
                if !results.isEmpty { resultList }
                if let err = engine.lastError { errorBanner(err) }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
        .overlay(alignment: .bottomTrailing) { locateButton }
        .safeAreaInset(edge: .bottom) {
            panel.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { panelFrame = $0 }
        }
        .sheet(isPresented: $showSetup) { SetupScreen() }
        .fileImporter(isPresented: $showGPX, allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml, .xml, .data]) { r in
            if case .success(let url) = r { importGPX(url) }
        }
        .alert("幫這條路線取個名字", isPresented: $showSave) {
            TextField("名字", text: $saveName)
            Button("存") { if !saveName.isEmpty { routes.save(name: saveName, path: path) } }
            Button("取消", role: .cancel) {}
        }
        .onAppear { if !PairingStore.exists { showSetup = true } }
    }

    // MARK: - 地圖

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera) {
                UserAnnotation()
                if tab == .point, let p = picked {
                    Marker("要去的地方", coordinate: p).tint(.red)
                }
                if tab == .route {
                    if !waypoints.isEmpty && fixedName == nil && snapToStreets {
                        MapPolyline(coordinates: waypoints).stroke(.blue.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [4, 6]))
                    }
                    if path.count >= 2 { MapPolyline(coordinates: path).stroke(.blue, lineWidth: 5) }
                    ForEach(Array(waypoints.enumerated()), id: \.offset) { i, c in
                        Annotation("", coordinate: c) { waypointDot(i) }
                    }
                }
                if let p = engine.position {
                    Annotation("假位置", coordinate: p) {
                        Circle().fill(.blue).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                            .shadow(radius: 2)
                    }
                }
            }
            .mapControls { MapCompass(); MapScaleView() }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mapFrame = $0 }
            .onAppear { mapProxy = proxy }
            .onMapCameraChange(frequency: .onEnd) { ctx in nudgeIntoView(ctx.region) }
            .onTapGesture { pt in
                guard let c = proxy.convert(pt, from: .local) else { return }
                results = []
                if tab == .point {
                    picked = c
                } else {
                    if fixedName != nil { fixedName = nil; snapped = nil }
                    waypoints.append(c)
                    resnap()
                }
            }
        }
    }

    /// 右下角的圓形按鈕：地圖回到手機目前的位置（在改位置時就是假位置）
    private var locateButton: some View {
        Button {
            if let c = CLLocationManager().location?.coordinate {
                center(on: c, meters: nil)
            } else {
                withAnimation { camera = .userLocation(fallback: camera) }
            }
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 48, height: 48)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
        }
        .accessibilityLabel("回到目前位置")
        .padding(.trailing, 14)
        .padding(.bottom, 10)
    }

    private func waypointDot(_ i: Int) -> some View {
        let first = i == 0, last = i == waypoints.count - 1 && waypoints.count > 1
        return Text("\(i + 1)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(first || last ? .white : .black)
            .frame(width: 22, height: 22)
            .background(Circle().fill(first ? Color.green : last ? Color.red : Color.white))
            .overlay(Circle().stroke(.blue, lineWidth: 2))
            .onLongPressGesture {
                waypoints.remove(at: i)
                resnap()
            }
    }

    // MARK: - 搜尋

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜尋地點或輸入座標（25.03, 121.56）", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { search() }
                if !query.isEmpty {
                    Button { query = ""; results = [] } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            Button { showSetup = true } label: {
                Image(systemName: "gearshape.fill")
                    .padding(11)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var resultList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(results.prefix(6), id: \.self) { item in
                Button {
                    goAfterKeyboard(item.placemark.coordinate)
                    results = []
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name ?? "").font(.subheadline.weight(.semibold))
                        Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8).padding(.horizontal, 12)
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.footnote)
            Spacer()
            Button { engine.lastError = nil } label: { Image(systemName: "xmark").font(.footnote) }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onTapGesture { showSetup = true }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        if let c = Self.parseCoordinate(q) {
            results = []
            goAfterKeyboard(c)
            return
        }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        MKLocalSearch(request: req).start { resp, _ in
            results = resp?.mapItems ?? []
        }
    }

    /// 收起鍵盤（下面的面板會跟著降回去）再移地圖，正中央才算得準
    private func goAfterKeyboard(_ c: CLLocationCoordinate2D) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { go(to: c) }
    }

    private func go(to c: CLLocationCoordinate2D) {
        center(on: c, meters: 600)
        if tab == .point { picked = c }
    }

    /// 把地圖移到 c，並讓 c 落在「看得到的地圖」正中央：先跳過去，等地圖停好再微調，
    /// 不管地圖有沒有延伸到面板後面都準。meters = nil 表示保持目前的縮放。
    private func center(on c: CLLocationCoordinate2D, meters: Double?) {
        pendingCenter = c
        if let meters {
            camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: meters, longitudinalMeters: meters))
        } else if let r = lastRegion {
            camera = .region(MKCoordinateRegion(center: c, span: r.span))
        } else {
            camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: 1200, longitudinalMeters: 1200))
        }
    }

    private func nudgeIntoView(_ region: MKCoordinateRegion) {
        lastRegion = region
        guard let c = pendingCenter else { return }
        pendingCenter = nil
        guard let proxy = mapProxy, mapFrame.height > 0, let pt = proxy.convert(c, to: .local) else { return }
        let top = max(mapFrame.minY, searchFrame.maxY) - mapFrame.minY
        let bottom = (panelFrame.height > 0 ? min(mapFrame.maxY, panelFrame.minY) : mapFrame.maxY) - mapFrame.minY
        let dy = (top + bottom) / 2 - pt.y
        let dx = mapFrame.width / 2 - pt.x
        guard abs(dy) > 4 || abs(dx) > 4 else { return }
        let latPerPt = region.span.latitudeDelta / mapFrame.height
        let lonPerPt = region.span.longitudeDelta / mapFrame.width
        let newCenter = CLLocationCoordinate2D(latitude: region.center.latitude + dy * latPerPt,
                                               longitude: region.center.longitude - dx * lonPerPt)
        withAnimation(.easeOut(duration: 0.25)) {
            camera = .region(MKCoordinateRegion(center: newCenter, span: region.span))
        }
    }

    /// 看得懂的座標寫法：「25.060106, 121.582061」「25.06，121.58」（全形逗號）、「25.06 121.58」、
    /// 「25.06°N 121.58°E」、「N25.06 E121.58」、Google 地圖網址裡的「@25.06,121.58,17z」「q=25.06,121.58」
    static func parseCoordinate(_ raw: String) -> CLLocationCoordinate2D? {
        var s = raw
        for (a, b) in [("，", ","), ("、", ","), ("　", " "), ("．", "."), ("－", "-"), ("°", " "), ("º", " ")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        // 網址：取 @ 或 q= / ll= / query= 後面的兩個數字
        if let r = s.range(of: #"(@|[?&](q|ll|query|center)=)(-?\d+(\.\d+)?),\s*(-?\d+(\.\d+)?)"#, options: .regularExpression) {
            s = String(s[r]).replacingOccurrences(of: #"^(@|[?&](q|ll|query|center)=)"#, with: "", options: .regularExpression)
        } else if s.contains("://") {
            return nil
        }
        let upper = s.uppercased()
        // 只能有數字、正負號、小數點、逗號、空白和 N/S/E/W，其他字（地名）就交給地點搜尋
        guard upper.range(of: #"^[\d\s.,+\-NSEW]+$"#, options: .regularExpression) != nil else { return nil }
        let nums = upper.matches(of: /-?\d+(?:\.\d+)?/).compactMap { Double($0.output) }
        guard nums.count == 2 else { return nil }
        var lat = nums[0], lon = nums[1]
        // 寫成「121.5 E 25.0 N」這種經度在前的
        if let ei = upper.firstIndex(where: { $0 == "E" || $0 == "W" }), let ni = upper.firstIndex(where: { $0 == "N" || $0 == "S" }), ei < ni {
            swap(&lat, &lon)
        }
        if upper.contains("S") { lat = -abs(lat) }
        if upper.contains("W") { lon = -abs(lon) }
        guard abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: - 下方面板

    private var panel: some View {
        VStack(spacing: 10) {
            Picker("", selection: $tab) {
                ForEach(PanelTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            if tab == .point { pointPanel } else { routePanel }

            HStack {
                Circle().fill(engine.position != nil ? Color.green : Color.secondary).frame(width: 8, height: 8)
                Text(engine.position.map { String(format: "目前假位置 %.5f, %.5f", $0.latitude, $0.longitude) } ?? "現在是真實位置")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                // 不鎖住：App 被關掉重開後，手機可能還停在假位置，這時也要能按
                Button { Task { await engine.restore() } } label: {
                    Label("停止模擬", systemImage: "location.slash.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(.orange)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    private var pointPanel: some View {
        VStack(spacing: 10) {
            Text(picked.map { String(format: "%.6f, %.6f", $0.latitude, $0.longitude) } ?? "點地圖選一個地方")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .center, spacing: 14) {
                Button {
                    if let p = picked { Task { await engine.teleport(to: p) } }
                } label: {
                    Label(engine.busy ? "連線中…" : "移到這裡", systemImage: "location.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(picked == nil || engine.busy)
                dpad
            }
        }
    }

    /// 按住會一直走（每步 3 公尺）
    private var dpad: some View {
        let s = 3.0
        return VStack(spacing: 2) {
            arrow("chevron.up") { await engine.nudge(northMeters: s, eastMeters: 0) }
            HStack(spacing: 2) {
                arrow("chevron.left") { await engine.nudge(northMeters: 0, eastMeters: -s) }
                Color.clear.frame(width: 34, height: 34)
                arrow("chevron.right") { await engine.nudge(northMeters: 0, eastMeters: s) }
            }
            arrow("chevron.down") { await engine.nudge(northMeters: -s, eastMeters: 0) }
        }
        .disabled(engine.position == nil)
        .opacity(engine.position == nil ? 0.4 : 1)
    }

    private func arrow(_ icon: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Image(systemName: icon).font(.system(size: 14, weight: .bold)).frame(width: 34, height: 34)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonRepeatBehavior(.enabled)
        .buttonStyle(.plain)
    }

    private var routePanel: some View {
        VStack(spacing: 10) {
            HStack {
                Text(routeInfo).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("匯入 GPX", systemImage: "square.and.arrow.down") { showGPX = true }
                    Button("存這條路線", systemImage: "bookmark") { saveName = ""; showSave = true }.disabled(path.count < 2)
                    if !routes.items.isEmpty {
                        Section("存過的路線") {
                            ForEach(routes.items) { r in
                                Button(r.name) { loadFixed(r.coordinates, name: r.name) }
                            }
                        }
                        Menu("刪除存過的路線") {
                            ForEach(routes.items) { r in Button(r.name, role: .destructive) { routes.remove(r) } }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
            }
            HStack {
                Toggle("沿著街道走", isOn: $snapToStreets).onChange(of: snapToStreets) { _, _ in resnap() }
                    .disabled(fixedName != nil)
            }
            .font(.subheadline)
            HStack {
                Button("復原一點") { if !waypoints.isEmpty { waypoints.removeLast(); resnap() } }.disabled(waypoints.isEmpty)
                Button("清空") { waypoints = []; snapped = nil; fixedName = nil; snapNote = nil }.disabled(path.isEmpty && waypoints.isEmpty)
                Spacer()
                Picker("", selection: $modeRaw) { ForEach(WalkMode.allCases) { Text($0.label).tag($0.rawValue) } }
                    .pickerStyle(.menu)
                Toggle("晃", isOn: $wobble).toggleStyle(.button).font(.caption)
            }
            .font(.subheadline)
            HStack {
                Text("速度").font(.subheadline)
                Slider(value: $speed, in: 1...20, step: 0.5)
                Text(String(format: "%.1f km/h", speed)).font(.subheadline.monospacedDigit()).frame(width: 76, alignment: .trailing)
            }
            if engine.walking || engine.finished {
                VStack(spacing: 4) {
                    ProgressView(value: engine.totalMeters > 0 ? engine.doneMeters / engine.totalMeters : 0)
                    Text(walkInfo).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                if engine.walking {
                    Button(engine.paused ? "繼續" : "暫停") { engine.paused.toggle() }.buttonStyle(.bordered)
                    Button("停止", role: .destructive) { engine.stopWalk() }.buttonStyle(.bordered)
                } else {
                    Button {
                        engine.startWalk(path: path, kmh: speed, mode: mode, wobble: wobble)
                    } label: { Label("開始走", systemImage: "figure.walk").frame(maxWidth: .infinity).padding(.vertical, 4) }
                    .buttonStyle(.borderedProminent)
                    .disabled(path.count < 2 || snapping)
                }
            }
        }
    }

    private var routeInfo: String {
        if snapping { return "找沿著街道的路…" }
        if let n = snapNote { return n }
        guard path.count >= 2 else { return waypoints.isEmpty ? "在地圖上依序點路線經過的地方（長按數字刪掉）" : "再點一個地方" }
        let m = Geo.length(path)
        let min = max(1, Int((m / (speed / 3.6) / 60).rounded()))
        let what = fixedName.map { "「\($0)」" } ?? (snapToStreets && snapped != nil ? "沿街道" : "直線")
        return "\(what) \(Geo.text(m))・約 \(min) 分鐘"
    }

    private var walkInfo: String {
        if engine.walking {
            return "\(engine.paused ? "暫停中" : "走路中")・\(Geo.text(engine.doneMeters)) / \(Geo.text(engine.totalMeters))" + (engine.lap > 0 ? "・第 \(engine.lap + 1) 圈" : "")
        }
        return "走完了（\(Geo.text(engine.totalMeters))），停在終點"
    }

    // MARK: - 路線

    private func resnap() {
        snapped = nil
        snapNote = nil
        guard snapToStreets, waypoints.count >= 2, fixedName == nil else { return }
        let pts = waypoints
        snapping = true
        Task {
            do {
                let line = try await StreetRouter.walk(through: pts)
                if pts == waypoints { snapped = line }
            } catch {
                if pts == waypoints { snapNote = "找不到沿街道的路，改用直線" }
            }
            snapping = false
        }
    }

    private func loadFixed(_ coords: [CLLocationCoordinate2D], name: String) {
        guard coords.count >= 2 else { return }
        tab = .route
        waypoints = []
        snapNote = nil
        fixedName = name
        snapped = coords
        let lats = coords.map(\.latitude), lngs = coords.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lngs.min()! + lngs.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: (lats.max()! - lats.min()!) * 1.4 + 0.002, longitudeDelta: (lngs.max()! - lngs.min()!) * 1.4 + 0.002)
        withAnimation { camera = .region(MKCoordinateRegion(center: center, span: span)) }
    }

    private func importGPX(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { engine.lastError = "讀不到這個檔案"; return }
        let pts = GPX.parse(data)
        if pts.count < 2 { engine.lastError = "GPX 裡找不到路線點"; return }
        loadFixed(pts, name: url.deletingPathExtension().lastPathComponent)
    }
}

extension CLLocationCoordinate2D: @retroactive Equatable {
    public static func == (a: CLLocationCoordinate2D, b: CLLocationCoordinate2D) -> Bool {
        a.latitude == b.latitude && a.longitude == b.longitude
    }
}

/// 用 Apple 地圖的步行路線把點連起來
enum StreetRouter {
    static func walk(through pts: [CLLocationCoordinate2D]) async throws -> [CLLocationCoordinate2D] {
        var out: [CLLocationCoordinate2D] = []
        for (a, b) in zip(pts, pts.dropFirst()) {
            let req = MKDirections.Request()
            req.source = MKMapItem(placemark: MKPlacemark(coordinate: a))
            req.destination = MKMapItem(placemark: MKPlacemark(coordinate: b))
            req.transportType = .walking
            let resp = try await MKDirections(request: req).calculate()
            guard let poly = resp.routes.first?.polyline else { throw URLError(.cannotFindHost) }
            var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: poly.pointCount)
            poly.getCoordinates(&coords, range: NSRange(location: 0, length: poly.pointCount))
            // 路線從最近的路開始：補上自己點的起點和終點
            if out.isEmpty { out.append(a) }
            out.append(contentsOf: coords)
            out.append(b)
        }
        return out
    }
}

enum GPX {
    static func parse(_ data: Data) -> [CLLocationCoordinate2D] {
        let d = Delegate()
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d.track.isEmpty ? (d.route.isEmpty ? d.waypoints : d.route) : d.track
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var track: [CLLocationCoordinate2D] = []
        var route: [CLLocationCoordinate2D] = []
        var waypoints: [CLLocationCoordinate2D] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            guard let la = attributes["lat"].flatMap(Double.init), let lo = attributes["lon"].flatMap(Double.init) else { return }
            let c = CLLocationCoordinate2D(latitude: la, longitude: lo)
            switch local {
            case "trkpt": track.append(c)
            case "rtept": route.append(c)
            case "wpt": waypoints.append(c)
            default: break
            }
        }
    }
}

struct SavedRoute: Codable, Identifiable {
    var id = UUID()
    var name: String
    var points: [[Double]]
    var coordinates: [CLLocationCoordinate2D] { points.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) } }
}

@MainActor
final class RouteStore: ObservableObject {
    static let shared = RouteStore()
    @Published private(set) var items: [SavedRoute] = []
    private let key = "savedRoutes"

    init() {
        if let d = UserDefaults.standard.data(forKey: key), let v = try? JSONDecoder().decode([SavedRoute].self, from: d) { items = v }
    }

    func save(name: String, path: [CLLocationCoordinate2D]) {
        items.removeAll { $0.name == name }
        items.insert(SavedRoute(name: name, points: path.map { [$0.latitude, $0.longitude] }), at: 0)
        persist()
    }

    func remove(_ r: SavedRoute) {
        items.removeAll { $0.id == r.id }
        persist()
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
}
