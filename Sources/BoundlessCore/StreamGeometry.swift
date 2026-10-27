import CoreGraphics

/// 画面采集与编码的尺寸、码率
public enum StreamGeometry {
    /// 编码的像素尺寸：按 Retina 倍率取原生像素，取偶数（编码器要求），超出上限时等比缩小
    public static func pixelSize(points: CGSize, scale: CGFloat, maxDimension: Int = 4096) -> (width: Int, height: Int) {
        var w = Double(points.width * scale), h = Double(points.height * scale)
        let longest = max(w, h)
        if longest > Double(maxDimension) {
            let k = Double(maxDimension) / longest
            w *= k
            h *= k
        }
        func even(_ v: Double) -> Int { max(2, Int(v) & ~1) }
        return (even(w), even(h))
    }

    /// 码率：文字画面需要比普通视频更高的码率才清楚，按像素量估算。
    /// 有线按每像素 12 bit、上限 80 Mbps：终端整屏滚动时码率不够，低延迟编码会直接跳帧（实测 4 bit 时只剩 30fps）；
    /// Wi-Fi 带宽有限，按每像素 4 bit、上限 40 Mbps
    public static func bitrate(width: Int, height: Int, wired: Bool = false) -> Int {
        let estimate = Double(width * height) * (wired ? 12 : 4)
        return Int(min(max(estimate, 4_000_000), wired ? 80_000_000 : 40_000_000))
    }

    /// 采集区域（相对屏幕左上角，点）：静止时只采窗口外框的并集，这样能用原生倍率、文字和本机一样清楚；
    /// 拖动中采整屏，免得区域一直变、反复重启采集。区域只在装不下窗口或明显偏大时才换，减少重启
    public static func captureRect(windows: [CGRect], screen: CGSize, moving: Bool, current: CGRect?) -> CGRect {
        let full = CGRect(origin: .zero, size: screen)
        if moving { return full }
        guard let first = windows.first else { return current ?? full }
        let union = windows.dropFirst().reduce(first) { $0.union($1) }
        // 四周留一点余量，取整到偶数点
        let padded = union.insetBy(dx: -8, dy: -8).intersection(full)
        func down(_ v: CGFloat) -> CGFloat { (v / 2).rounded(.down) * 2 }
        func up(_ v: CGFloat) -> CGFloat { (v / 2).rounded(.up) * 2 }
        let x = down(padded.minX), y = down(padded.minY)
        let tight = CGRect(x: x, y: y, width: min(up(padded.maxX), screen.width) - x, height: min(up(padded.maxY), screen.height) - y)
        if let current, current.contains(tight), current.width * current.height <= tight.width * tight.height * 1.5 { return current }
        return tight
    }

    /// 采集倍率：能用原生倍率就用，像素超出预算时等比降下来
    public static func captureScale(points: CGSize, native: CGFloat, maxPixels: Int) -> CGFloat {
        let area = Double(points.width * points.height)
        guard area > 0 else { return native }
        return min(native, CGFloat((Double(maxPixels) / area).squareRoot()))
    }
}
