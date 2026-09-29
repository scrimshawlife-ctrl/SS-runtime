/// `run-shell.md` § 11 (D-081): the run card under the terminal outcome, and
/// the plain-text summary Share sends.
///
/// Presentation only: it reads a terminal `WorldState` and never writes one.
/// It carries no seed, receipt, or identifier, so neither the panel nor the
/// share text can leak one (RS-016).
public struct RunCard: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let label: String
        public let value: String
    }

    /// The game's name, which § 11 puts in the share text.
    public static let gameName = "Surveillance Survivor"

    public let rows: [Row]

    /// - Parameters:
    ///   - state: the finished run.
    ///   - dateLabel: the Daily Run's UTC date, `YYYY-MM-DD`. Nil only for a
    ///     debug harness run that did not start from the title; the row is
    ///     omitted rather than invented.
    ///   - bestTicks: the stored best on this seed *before* this run, if any.
    ///   - storesBest: false when this run cannot become the stored best (a
    ///     debug-seeded harness run), so the card never claims `NEW BEST` for
    ///     a run that was not stored.
    public init(state: WorldState, dateLabel: String?, bestTicks: UInt64?, storesBest: Bool = true) {
        var rows: [Row] = []
        if let dateLabel {
            rows.append(Row(label: "DATE", value: dateLabel))
        }
        rows.append(Row(label: "TIME", value: Self.clock(ticks: state.tick)))
        var cameras = "\(state.destructions.count)/\(HUDLayout.cameraObjectiveTotal)"
        if state.networkBlackout { cameras += " NETWORK BLACKOUT" }
        rows.append(Row(label: "CAMERAS", value: cameras))
        rows.append(Row(label: "PEAK DETECTION", value: Self.peakDetection(state).rawValue.uppercased()))
        if let ghost = Self.ghostValue(state: state, bestTicks: bestTicks, storesBest: storesBest) {
            rows.append(Row(label: "GHOST", value: ghost))
        }
        self.rows = rows
    }

    /// § 11 share text: the game's name and the same rows, nothing else.
    public var shareText: String {
        ([Self.gameName] + rows.map { "\($0.label) \($0.value)" }).joined(separator: "\n")
    }

    public func value(for label: String) -> String? {
        rows.first { $0.label == label }?.value
    }

    // MARK: - Row sources

    /// Elapsed ticks as `m:ss` at 60 Hz. Partial seconds are truncated.
    public static func clock(ticks: UInt64) -> String {
        let seconds = ticks / 60
        let minutes = seconds / 60
        let remainder = seconds % 60
        return "\(minutes):" + (remainder < 10 ? "0" : "") + "\(remainder)"
    }

    /// The highest Detection State reached. Lockdown latches, so a run that
    /// entered it peaked there; otherwise the peak Exposure projects it.
    public static func peakDetection(_ state: WorldState) -> DetectionState {
        state.exposure.lockdownEntered ? .lockdown : DetectionState.projected(state.exposure.peak)
    }

    /// Success only (RS-017): `NEW BEST` when this run replaces the stored best,
    /// otherwise the gap to it. Nil on failure, where a shorter run would read
    /// as "faster", and nil when there is no best to compare with.
    static func ghostValue(state: WorldState, bestTicks: UInt64?, storesBest: Bool) -> String? {
        guard state.outcome == .success else { return nil }
        if storesBest, state.outcome == .success, bestTicks.map({ state.tick < $0 }) ?? true {
            return "NEW BEST"
        }
        guard let bestTicks else { return nil }
        if state.tick >= bestTicks {
            return "+" + clock(ticks: state.tick - bestTicks)
        }
        return "-" + clock(ticks: bestTicks - state.tick)
    }
}
