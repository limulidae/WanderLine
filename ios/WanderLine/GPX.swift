// GPX 檔：
// - 匯出收藏 → <wpt>（一個個單獨的地點）
// - 匯出路線 → <rte><rtept>（只留自己點的那幾個點，不存沿街道算出來的密密麻麻的線）
// - 匯入三種都讀：<wpt> 加進收藏、<rtept> 變成路線的點、只有 <trkpt>（別人錄的軌跡）就整條照走
import CoreLocation
import Foundation
import SwiftUI
import UIKit

struct GPXPoint {
    var coordinate: CLLocationCoordinate2D
    var name: String?
}

struct GPXContents {
    var waypoints: [GPXPoint] = []
    var routeName: String?
    var route: [CLLocationCoordinate2D] = []
    var trackName: String?
    var track: [CLLocationCoordinate2D] = []
}

enum GPX {
    static func parse(_ data: Data) -> GPXContents {
        let d = Delegate()
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d.out
    }

    static func favorites(_ items: [Favorite]) -> String {
        let body = items.map { f in
            "  <wpt lat=\"\(num(f.lat))\" lon=\"\(num(f.lon))\"><name>\(esc(f.name))</name></wpt>"
        }
        return wrap(body.joined(separator: "\n"))
    }

    static func route(name: String, points: [CLLocationCoordinate2D]) -> String {
        var lines = ["  <rte>", "    <name>\(esc(name))</name>"]
        lines += points.map { "    <rtept lat=\"\(num($0.latitude))\" lon=\"\(num($0.longitude))\"/>" }
        lines.append("  </rte>")
        return wrap(lines.joined(separator: "\n"))
    }

    /// 寫成暫存檔，給分享視窗用（檔名就是收藏或路線的名字）
    static func file(_ text: String, name: String) -> URL? {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let safe = name.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent((safe.isEmpty ? "WanderLine" : safe) + ".gpx")
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// 只有很密的軌跡時，只留轉彎的地方（偏差 15 公尺以內的點拿掉）
    static func simplify(_ pts: [CLLocationCoordinate2D], tolerance: Double = 15) -> [CLLocationCoordinate2D] {
        guard pts.count > 2, let o = pts.first else { return pts }
        let k = cos(o.latitude * .pi / 180)
        let xs = pts.map { ($0.longitude - o.longitude) * 111_320 * k }
        let ys = pts.map { ($0.latitude - o.latitude) * 110_540 }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var todo: [(Int, Int)] = [(0, pts.count - 1)]
        while let seg = todo.popLast() {
            let a = seg.0, b = seg.1
            guard b > a + 1 else { continue }
            let dx = xs[b] - xs[a], dy = ys[b] - ys[a]
            let len = max((dx * dx + dy * dy).squareRoot(), 0.001)
            var best = 0.0
            var idx = a
            for i in (a + 1)..<b {
                let d = abs(dy * (xs[i] - xs[a]) - dx * (ys[i] - ys[a])) / len
                if d > best { best = d; idx = i }
            }
            if best > tolerance {
                keep[idx] = true
                todo.append((a, idx))
                todo.append((idx, b))
            }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }

    private static func num(_ v: Double) -> String { String(format: "%.6f", v) }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func wrap(_ body: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            + "<gpx version=\"1.1\" creator=\"WanderLine\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
            + body + "\n</gpx>\n"
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var out = GPXContents()
        private var stack: [String] = []
        private var text = ""
        private var wpt: CLLocationCoordinate2D?
        private var wptName: String?

        private func local(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            let l = local(name)
            stack.append(l)
            text = ""
            guard let la = attributes["lat"].flatMap(Double.init), let lo = attributes["lon"].flatMap(Double.init) else { return }
            let c = CLLocationCoordinate2D(latitude: la, longitude: lo)
            switch l {
            case "trkpt": out.track.append(c)
            case "rtept": out.route.append(c)
            case "wpt": wpt = c; wptName = nil
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let l = local(name)
            let parent = stack.count >= 2 ? stack[stack.count - 2] : ""
            if l == "name" {
                let n = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !n.isEmpty {
                    switch parent {
                    case "wpt": wptName = n
                    case "rte": if out.routeName == nil { out.routeName = n }
                    case "trk": if out.trackName == nil { out.trackName = n }
                    default: break
                    }
                }
            }
            if l == "wpt", let c = wpt {
                out.waypoints.append(GPXPoint(coordinate: c, name: wptName))
                wpt = nil
            }
            if !stack.isEmpty { stack.removeLast() }
            text = ""
        }
    }
}

/// 要分享的檔案（給 .sheet(item:) 用）
struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// iOS 的分享視窗：AirDrop、LINE、存到「檔案」…
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
