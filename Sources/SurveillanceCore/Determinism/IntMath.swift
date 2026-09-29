/// Integer helpers for authoritative simulation. No IEEE floating comparison.
public enum IntMath {
    public static func abs(_ value: Int64) -> Int64 {
        value < 0 ? 0 &- value : value
    }

    public static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let t = x % y
            x = y
            y = t
        }
        return x
    }

    /// Integer square root, flooring.
    public static func isqrt(_ n: Int64) -> Int64 {
        precondition(n >= 0)
        if n < 2 { return n }
        var x0 = n
        var x1 = (x0 + n / x0) / 2
        while x1 < x0 {
            x0 = x1
            x1 = (x0 + n / x0) / 2
        }
        return x0
    }

    /// `n / d` rounded half away from zero.
    public static func divHalfAway(_ n: Int64, _ d: Int64) -> Int64 {
        precondition(d != 0)
        let negative = (n < 0) != (d < 0)
        let an = abs(n)
        let ad = abs(d)
        let q = an / ad
        let r = an % ad
        let rounded = r * 2 >= ad ? q + 1 : q
        return negative ? 0 &- rounded : rounded
    }

    /// `(a * b) / d` rounded half away from zero using a 128-bit intermediate.
    public static func mulDivHalfAway(_ a: Int64, _ b: Int64, _ d: Int64) -> Int64 {
        precondition(d != 0)
        let sign: Int64 = ((a < 0) != (b < 0)) != (d < 0) ? -1 : 1
        let ua = UInt64(abs(a))
        let ub = UInt64(abs(b))
        let ud = UInt64(abs(d))
        let full = ua.multipliedFullWidth(by: ub)
        let (quotient, remainder) = ud.dividingFullWidth(full)
        let rounded = remainder * 2 >= ud ? quotient + 1 : quotient
        let asSigned = Int64(bitPattern: rounded)
        return sign < 0 ? 0 &- asSigned : asSigned
    }

    /// `b² − 4ac` for integer quadratics. Returns nil when negative.
    public static func quadraticDiscriminant(a: Int64, b: Int64, c: Int64) -> Int64? {
        let b2 = UInt64(abs(b)).multipliedFullWidth(by: UInt64(abs(b)))
        let acNegative = (a < 0) != (c < 0)
        let ac = UInt64(abs(a)).multipliedFullWidth(by: UInt64(abs(c)))
        let fourACOverflow = ac.high >> 62 != 0
        let fourAC = (
            high: (ac.high &<< 2) | (ac.low &>> 62),
            low: ac.low &<< 2
        )

        if acNegative {
            if fourACOverflow { return Int64.max }
            let sumLow = b2.low &+ fourAC.low
            let carry: UInt64 = sumLow < b2.low ? 1 : 0
            let sumHigh = b2.high &+ fourAC.high &+ carry
            return fitNonNegative(high: sumHigh, low: sumLow)
        }

        if fourACOverflow { return nil }
        if b2.high < fourAC.high || (b2.high == fourAC.high && b2.low < fourAC.low) {
            return nil
        }
        let borrow: UInt64 = b2.low < fourAC.low ? 1 : 0
        let diffLow = b2.low &- fourAC.low
        let diffHigh = b2.high &- fourAC.high &- borrow
        return fitNonNegative(high: diffHigh, low: diffLow)
    }

    private static func fitNonNegative(high: UInt64, low: UInt64) -> Int64 {
        if high != 0 || low > UInt64(Int64.max) { return Int64.max }
        return Int64(bitPattern: low)
    }
}

/// An exact unsigned 128-bit product of two `UInt64`s, for comparisons whose
/// sides exceed 64 bits. `Int128` needs macOS 15, above this package's floor.
struct UInt128Product: Comparable, Sendable {
    let high: UInt64
    let low: UInt64

    init(_ a: UInt64, _ b: UInt64) {
        let full = a.multipliedFullWidth(by: b)
        high = full.high
        low = full.low
    }

    private init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    /// The product times a small factor. Traps rather than wraps past 128 bits.
    func times(_ factor: UInt64) -> UInt128Product {
        let lowProduct = low.multipliedFullWidth(by: factor)
        let (highProduct, highOverflow) = high.multipliedReportingOverflow(by: factor)
        let (sum, carryOverflow) = highProduct.addingReportingOverflow(lowProduct.high)
        precondition(!highOverflow && !carryOverflow, "UInt128Product overflow")
        return UInt128Product(high: sum, low: lowProduct.low)
    }

    static func < (lhs: UInt128Product, rhs: UInt128Product) -> Bool {
        lhs.high != rhs.high ? lhs.high < rhs.high : lhs.low < rhs.low
    }
}
