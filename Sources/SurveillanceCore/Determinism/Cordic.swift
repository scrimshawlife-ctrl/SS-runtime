/// Millidegree trigonometry. Angles are clockwise from +X as specified by civic-seam-arena-002.
public enum MilliDeg {
    public static let circle = 360_000
    public static let right = 90_000

    public static func normalize(_ milli: Int) -> Int {
        var value = milli % circle
        if value < 0 { value += circle }
        return value
    }

    public static func delta(_ from: Int, _ to: Int) -> Int {
        let diff = normalize(to - from)
        return diff <= 180_000 ? diff : diff - circle
    }

    public static func absDelta(_ a: Int, _ b: Int) -> Int {
        abs(delta(a, b))
    }
}

/// Integer CORDIC sin/cos/atan2 in millidegrees. Q15 unit vectors (32767 ≈ 1.0).
public enum Cordic {
    public static let q15: Int32 = 32_767

    /// atan(2^-i) in millidegrees.
    private static let atanTable: [Int] = [
        45_000, 26_565, 14_036, 7_125, 3_576, 1_790, 895, 448,
        224, 112, 56, 28, 14, 7, 3, 2, 1
    ]

    public static func sinCos(milliDegrees: Int) -> (sin: Int32, cos: Int32) {
        let n = MilliDeg.normalize(milliDegrees)
        var x: Int32 = 19_898
        var y: Int32 = 0
        var z = n % MilliDeg.right
        let quadrant = n / MilliDeg.right
        for i in 0..<atanTable.count {
            let d: Int32 = z >= 0 ? 1 : -1
            let xNew = x - d * (y >> i)
            let yNew = y + d * (x >> i)
            z -= Int(d) * atanTable[i]
            x = xNew
            y = yNew
        }
        let cos: Int32
        let sin: Int32
        switch quadrant {
        case 0:
            cos = x; sin = y
        case 1:
            cos = -y; sin = x
        case 2:
            cos = -x; sin = -y
        default:
            cos = y; sin = -x
        }
        return (sin: sin, cos: cos)
    }

    public static func headingUnit(milliDegrees: Int) -> (x: Int32, y: Int32) {
        let sc = sinCos(milliDegrees: milliDegrees)
        return (x: sc.cos, y: 0 &- sc.sin)
    }

    public static func atan2Milli(y: Int64, x: Int64) -> Int {
        MilliDeg.normalize(MilliDeg.circle - atan2CCWMilli(y: y, x: x)) % MilliDeg.circle
    }

    private static func atan2CCWMilli(y: Int64, x: Int64) -> Int {
        if x == 0 && y == 0 { return 0 }
        var xReg = x
        var yReg = y
        var z = 0
        if xReg < 0 {
            xReg = -xReg
            yReg = -yReg
            z = 180_000
        }
        for i in 0..<atanTable.count {
            let d = yReg >= 0 ? 1 : -1
            let xNew = xReg + Int64(d) * (yReg >> i)
            let yNew = yReg - Int64(d) * (xReg >> i)
            z += d * atanTable[i]
            xReg = xNew
            yReg = yNew
        }
        return MilliDeg.normalize(z)
    }
}
