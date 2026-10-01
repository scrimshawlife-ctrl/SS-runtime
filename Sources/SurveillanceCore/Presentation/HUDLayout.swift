public enum Handedness: String, Equatable, Sendable, Codable, CaseIterable {
    case right
    case left
}

public enum HUDScaleSetting: Int, Equatable, Sendable, CaseIterable, Codable {
    case standard = 1000
    case large = 1150
    case extraLarge = 1300
}

public struct HUDLayoutValidation: Equatable, Sendable {
    public var clippedElements: [String]
    public var controlsMeetTouchTarget: Bool
    public var allInsideSafeCanvas: Bool

    public init(clippedElements: [String], controlsMeetTouchTarget: Bool, allInsideSafeCanvas: Bool) {
        self.clippedElements = clippedElements
        self.controlsMeetTouchTarget = controlsMeetTouchTarget
        self.allInsideSafeCanvas = allInsideSafeCanvas
    }
}

public struct HUDRect: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var meetsTouchTarget: Bool { width >= 44 && height >= 44 }

    public func reflected(acrossX axis: Int = 422) -> HUDRect {
        HUDRect(x: axis * 2 - x, y: y, width: width, height: height)
    }
}

/// hud-tutorial-001 reference canvas. Layout is presentation-only.
public enum HUDLayout {
    public static let referenceWidth = 844
    public static let referenceHeight = 390
    /// plan.md §10 iPhone SE 3rd generation landscape safe canvas.
    public static let seClassSafeWidth = 667
    public static let seClassSafeHeight = 375

    public static func scale(safeWidth: Int, safeHeight: Int) -> Int {
        Int(min(
            IntMath.mulDivHalfAway(Int64(safeWidth), 1000, Int64(referenceWidth)),
            IntMath.mulDivHalfAway(Int64(safeHeight), 1000, Int64(referenceHeight))
        ))
    }

    public static func validate(
        safeWidth: Int,
        safeHeight: Int,
        handedness: Handedness,
        hudScale: HUDScaleSetting
    ) -> HUDLayoutValidation {
        var clipped: [String] = []
        var controlsOk = true
        for (name, rect) in controlRects(handedness: handedness) {
            let mapped = mapControlRect(rect, safeWidth: safeWidth, safeHeight: safeHeight)
            if mapped.x < 0 || mapped.y < 0 ||
                mapped.x + mapped.width > safeWidth ||
                mapped.y + mapped.height > safeHeight
            {
                clipped.append(name)
            }
            if !mapped.meetsTouchTarget {
                controlsOk = false
            }
        }
        return HUDLayoutValidation(
            clippedElements: clipped.sorted(),
            controlsMeetTouchTarget: controlsOk,
            allInsideSafeCanvas: clipped.isEmpty
        )
    }

    public static func informationalScalePermille(safeWidth: Int, safeHeight: Int, hudScale: HUDScaleSetting) -> Int {
        let canvasPermille = scale(safeWidth: safeWidth, safeHeight: safeHeight)
        return Int(IntMath.mulDivHalfAway(Int64(canvasPermille), Int64(hudScale.rawValue), 1000))
    }

    /// hud-tutorial-001: "HUD scale setting multiplies non-control HUD ...;
    /// controls remain at least their baseline size", and "Every interactive
    /// rectangle is at least 44 x 44 points". So a control scales with the
    /// canvas but never below its authored size, and never below the touch
    /// target. It grows about its own centre so the anchor does not drift.
    public static let minimumTouchTargetPoints = 44

    public static func mapControlRect(_ rect: HUDRect, safeWidth: Int, safeHeight: Int) -> HUDRect {
        var mapped = mapReferenceRect(
            rect,
            safeWidth: safeWidth,
            safeHeight: safeHeight,
            hudScale: .standard,
            informational: false
        )
        let baselineWidth = max(rect.width, minimumTouchTargetPoints)
        let baselineHeight = max(rect.height, minimumTouchTargetPoints)
        if mapped.width < baselineWidth {
            mapped.x -= (baselineWidth - mapped.width) / 2
            mapped.width = baselineWidth
        }
        if mapped.height < baselineHeight {
            mapped.y -= (baselineHeight - mapped.height) / 2
            mapped.height = baselineHeight
        }
        if mapped.width > safeWidth { mapped.width = safeWidth }
        if mapped.height > safeHeight { mapped.height = safeHeight }
        if mapped.x + mapped.width > safeWidth { mapped.x = safeWidth - mapped.width }
        if mapped.y + mapped.height > safeHeight { mapped.y = safeHeight - mapped.height }
        if mapped.x < 0 { mapped.x = 0 }
        if mapped.y < 0 { mapped.y = 0 }
        return mapped
    }

    public static func mapReferenceRect(
        _ rect: HUDRect,
        safeWidth: Int,
        safeHeight: Int,
        hudScale: HUDScaleSetting,
        informational: Bool
    ) -> HUDRect {
        let canvasPermille = scale(safeWidth: safeWidth, safeHeight: safeHeight)
        let elementPermille = informational
            ? Int(IntMath.mulDivHalfAway(Int64(canvasPermille), Int64(hudScale.rawValue), 1000))
            : canvasPermille
        let canvasW = Int(IntMath.mulDivHalfAway(Int64(referenceWidth), Int64(canvasPermille), 1000))
        let canvasH = Int(IntMath.mulDivHalfAway(Int64(referenceHeight), Int64(canvasPermille), 1000))
        let offsetX = (safeWidth - canvasW) / 2
        let offsetY = (safeHeight - canvasH) / 2
        return HUDRect(
            x: offsetX + scaledCoordinate(rect.x, permille: elementPermille),
            y: offsetY + scaledCoordinate(rect.y, permille: elementPermille),
            width: scaledCoordinate(rect.width, permille: elementPermille),
            height: scaledCoordinate(rect.height, permille: elementPermille)
        )
    }

    private static func scaledCoordinate(_ value: Int, permille: Int) -> Int {
        Int(IntMath.mulDivHalfAway(Int64(value), Int64(permille), 1000))
    }

    private static func controlRects(handedness: Handedness) -> [(String, HUDRect)] {
        [
            ("stick", stick(handedness: handedness)),
            ("dodge", dodge(handedness: handedness)),
            ("pause", pause())
        ]
    }

    public static func stick(handedness: Handedness) -> HUDRect {
        reflect(HUDRect(x: 104, y: 286, width: 144, height: 144), handedness)
    }

    public static func dodge(handedness: Handedness) -> HUDRect {
        reflect(HUDRect(x: 760, y: 286, width: 88, height: 88), handedness)
    }

    public static func pause() -> HUDRect { HUDRect(x: 806, y: 36, width: 44, height: 44) }
    public static func playerIntegrity() -> HUDRect { HUDRect(x: 24, y: 24, width: 220, height: 20) }
    public static func exposureBar() -> HUDRect { HUDRect(x: 422, y: 26, width: 300, height: 24) }
    public static func detectionLabel() -> HUDRect { HUDRect(x: 422, y: 54, width: 180, height: 24) }
    public static func combatObjective() -> HUDRect { HUDRect(x: 24, y: 58, width: 300, height: 48) }
    public static func cameraObjective() -> HUDRect { HUDRect(x: 24, y: 110, width: 180, height: 28) }
    public static func bossIntegrity() -> HUDRect { HUDRect(x: 422, y: 82, width: 360, height: 24) }
    public static func extractionCountdown() -> HUDRect { HUDRect(x: 422, y: 134, width: 220, height: 56) }
    public static func upgradeBadge() -> HUDRect { HUDRect(x: 760, y: 88, width: 64, height: 64) }
    public static func tutorialCard() -> HUDRect { HUDRect(x: 422, y: 318, width: 520, height: 56) }
    public static func tamperSpike() -> HUDRect { HUDRect(x: 642, y: 26, width: 120, height: 24) }

    public static let tamperCopy = "+\(ExposureState.tamperSpike) TAMPER"
    public static let integrityNotchCount = 3
    public static let integrityNotchPersistTicks: UInt64 = 90
    public static let firstEncounterCameraCopy = "MOVE TOWARD A CAMERA TO SHOOT IT • DESTRUCTION ADDS EXPOSURE"

    public static func integrityNotchFilled(integrity: Int, index: Int) -> Bool {
        index >= 0 && index < integrityNotchCount && index < max(0, integrity)
    }

    public static func extractionSeconds(_ remainingTicks: Int) -> Int {
        remainingTicks <= 0 ? 0 : (remainingTicks + 59) / 60
    }

    public static let cameraObjectiveTotal = 8
    public static let networkBlackoutAccolade = "NETWORK BLACKOUT 8/8"

    public static func cameraObjectiveVisible(destroyed: Int, damaged: Bool, pinned: Bool = false) -> Bool {
        pinned || damaged || destroyed > 0
    }

    public static func cameraObjectiveCopy(destroyed: Int, complete: Bool) -> String {
        complete ? networkBlackoutAccolade : "CAM \(destroyed)/\(cameraObjectiveTotal)"
    }

    /// Terminal surface geometry, in safe-rectangle points.
    ///
    /// Not part of the `hud-tutorial-001` layout table: that table describes HUD
    /// elements present during play, and this is a shell surface shown once the
    /// run is over. It is centred on the safe rectangle rather than authored on
    /// the 844x390 reference canvas, matching the upgrade overlay.
    public static func terminalPanel(safeWidth: Int, safeHeight: Int) -> HUDRect {
        HUDRect(
            x: safeWidth / 2 - terminalPanelWidth / 2,
            y: safeHeight / 2 - terminalPanelHeight / 2,
            width: terminalPanelWidth,
            height: terminalPanelHeight
        )
    }

    /// The restart control: the only thing on screen that restarts a run.
    ///
    /// Sized at or above `minimumTouchTargetPoints` in both axes — if this rect
    /// were wrong the player would be stranded on the terminal surface with no
    /// way out, so its geometry is pinned by tests.
    public static func terminalRestart(safeWidth: Int, safeHeight: Int) -> HUDRect {
        let panel = terminalPanel(safeWidth: safeWidth, safeHeight: safeHeight)
        return HUDRect(
            x: panel.x + panel.width / 2 - terminalButtonWidth / 2,
            y: panel.y + panel.height - terminalButtonHeight - terminalButtonInset,
            width: terminalButtonWidth,
            height: terminalButtonHeight
        )
    }

    /// `run-shell.md` § 4 / § 11: the Share control, beside Restart.
    ///
    /// Restart stays the primary control and stays centred on the safe
    /// rectangle; Share takes the space to its right on the same row. Neither
    /// moves with handedness. Sized at or above `minimumTouchTargetPoints`.
    public static func terminalShare(safeWidth: Int, safeHeight: Int) -> HUDRect {
        let panel = terminalPanel(safeWidth: safeWidth, safeHeight: safeHeight)
        let restart = terminalRestart(safeWidth: safeWidth, safeHeight: safeHeight)
        return HUDRect(
            x: restart.x + restart.width + terminalButtonGap,
            y: restart.y,
            width: panel.x + panel.width - terminalButtonInset - (restart.x + restart.width + terminalButtonGap),
            height: terminalButtonHeight
        )
    }

    /// Vertical centre of the outcome title, in safe-rectangle points.
    public static func terminalTitleCentreY(safeWidth: Int, safeHeight: Int) -> Int {
        terminalPanel(safeWidth: safeWidth, safeHeight: safeHeight).y + 34
    }

    /// Vertical centre of run card row `index` (§ 11), in safe-rectangle points.
    public static func terminalCardRowCentreY(_ index: Int, safeWidth: Int, safeHeight: Int) -> Int {
        terminalPanel(safeWidth: safeWidth, safeHeight: safeHeight).y + 68 + index * terminalCardRowHeight
    }

    /// Room for every § 11 row: date, time, cameras, peak detection, ghost.
    public static let terminalCardRowCapacity = 5
    public static let terminalCardRowHeight = 22
    public static let terminalCardInset = 48

    public static let terminalPanelWidth = 460
    public static let terminalPanelHeight = 262
    public static let terminalButtonWidth = 200
    public static let terminalButtonHeight = 52
    static let terminalButtonInset = 20
    static let terminalButtonGap = 12

    /// Copy for a finished run.
    ///
    /// audio-haptics-001 already names these outcomes for its accessibility
    /// captions ("Run complete", "Player down"); these reuse those words rather
    /// than inventing terminal copy. hud-tutorial-001: copy is uppercase in
    /// visual presentation and sentence case for VoiceOver.
    ///
    /// Returns nil for a live run, so the surface cannot appear mid-run.
    public static func terminalCopy(for outcome: RunOutcome) -> String? {
        switch outcome {
        case .success: return "RUN COMPLETE"
        case .failure: return "PLAYER DOWN"
        case .invalid: return "RUN INVALID"
        case .playing, .upgradeSelectionPending: return nil
        }
    }

    public static let lockedExtractionCopy = "DEFEAT THE CURRENT AUTHORITY"
    public static let phoenixStepsOpenCopy = "PHOENIX STEPS OPEN"

    /// hud-tutorial-001 §Exact copy: current graph node, locked Extraction contact, or armed Extraction.
    public static func combatObjectiveCopy(
        node: CombatAuthorityNode,
        extractionArmed: Bool,
        insideLockedExtraction: Bool
    ) -> String {
        if extractionArmed { return phoenixStepsOpenCopy }
        if insideLockedExtraction { return lockedExtractionCopy }
        switch node {
        case .mobA: return "MOB ENCOUNTER A"
        case .mobB: return "MOB ENCOUNTER B"
        case .mobC: return "MOB ENCOUNTER C"
        case .improperSearchDaemon: return "IMPROPER SEARCH DAEMON"
        case .algorithmicModerate: return "ALGORITHMIC MODERATE"
        case .extraction: return phoenixStepsOpenCopy
        }
    }

    private static func reflect(_ rect: HUDRect, _ handedness: Handedness) -> HUDRect {
        handedness == .left ? rect.reflected() : rect
    }
}

public enum TutorialPhase: Equatable, Sendable {
    case move
    case field
    case contact
    case cameraDamage
    case upgrade
    case complete
}

public struct TutorialState: Equatable, Sendable {
    /// hud-tutorial-001: a card's visual duration is measured per card, so the
    /// counter restarts whenever the phase does.
    public var phase: TutorialPhase {
        didSet { if phase != oldValue { phaseVisibleTicks = 0 } }
    }
    public var displacementUnits: Int
    public var fieldTicks: Int
    public var noContactTicks: Int
    public var cameraEligibleTicks: Int
    public var lockdownPreempts: Bool
    /// hud-tutorial-001: "Higher safety messages (lethal warning, Lockdown,
    /// Extraction) temporarily replace it without changing tutorial progress."
    /// Lockdown has its own flag above; this carries the Extraction pair.
    ///
    /// The lethal warning is deliberately absent: the specs name it as a
    /// preemptor and as audio priority 1, but no contract gives it HUD copy,
    /// and inventing a string here would be inventing product intent.
    public var extractionPreempts: ExtractionPrompt?
    /// Ticks the current card has been presented, capped so the counter cannot
    /// run away on a long phase.
    public private(set) var phaseVisibleTicks: Int

    /// The two Extraction messages the copy table defines.
    public enum ExtractionPrompt: Equatable, Sendable {
        /// Player is in contact with a locked Extraction: show the prerequisite.
        case lockedContact
        /// Extraction is armed and open.
        case armed
    }

    /// hud-tutorial-001: "Each card has a maximum visual duration of 300 ticks,
    /// but its completion condition remains authoritative where specified."
    public static let maxCardTicks = 300

    public init() {
        phase = .move
        displacementUnits = 0
        fieldTicks = 0
        noContactTicks = 0
        cameraEligibleTicks = 0
        lockdownPreempts = false
        extractionPreempts = nil
        phaseVisibleTicks = 0
    }

    /// True when `copy` is a safety message rather than a tutorial card.
    ///
    /// The tutorial setting hides tutorial cards. It must never hide Lockdown
    /// or Extraction, which share the same card but are not tutorial content.
    public var copyIsSafetyMessage: Bool {
        lockdownPreempts || extractionPreempts != nil
    }

    /// Advance the current card's visual duration by one presented tick.
    public mutating func notePresentedTick() {
        if phaseVisibleTicks < Self.maxCardTicks { phaseVisibleTicks += 1 }
    }

    public var copy: String {
        // Safety messages are read before the cap: the maximum visual duration
        // governs tutorial cards, and a Lockdown that expired off-screen after
        // five seconds would be a safety regression, not a tutorial one.
        if lockdownPreempts { return "LOCKDOWN" }
        if let extractionPreempts {
            switch extractionPreempts {
            case .lockedContact: return HUDLayout.lockedExtractionCopy
            case .armed: return HUDLayout.phoenixStepsOpenCopy
            }
        }
        // The card retires once it has had its maximum visual duration. The
        // phase is untouched, so the completion condition stays authoritative.
        if phaseVisibleTicks >= Self.maxCardTicks { return "" }
        switch phase {
        case .move: return "MOVE"
        case .field: return "CAMERA FIELDS RAISE EXPOSURE"
        case .contact: return "BREAK LINE OF SIGHT TO RECOVER"
        case .cameraDamage: return HUDLayout.firstEncounterCameraCopy
        case .upgrade: return "CHOOSE ONE COUNTERMEASURE"
        case .complete: return ""
        }
    }

    public mutating func noteDisplacement(_ units: Int) {
        displacementUnits += max(0, units)
        if phase == .move, displacementUnits >= 96 {
            phase = .field
        }
    }

    public mutating func noteCameraInViewport() {
        guard phase == .field else { return }
        fieldTicks += 1
        if fieldTicks >= 60 { phase = .contact }
    }

    public mutating func noteContact(_ contacting: Bool) {
        if phase == .field, contacting {
            phase = .contact
        }
        if phase == .contact {
            if contacting {
                noContactTicks = 0
            } else {
                noContactTicks += 1
                if noContactTicks >= 30 { phase = .cameraDamage }
            }
        }
    }

    public mutating func noteCameraTargetable() {
        if phase == .contact || phase == .field {
            phase = .cameraDamage
        }
        if phase == .cameraDamage {
            cameraEligibleTicks += 1
            if cameraEligibleTicks >= 300 { phase = .upgrade }
        }
    }

    public mutating func noteCameraImpact() {
        if phase == .cameraDamage { phase = .upgrade }
    }

    public mutating func noteMobAComplete() {
        phase = .upgrade
    }

    public mutating func noteUpgradeSelected() {
        if phase == .upgrade { phase = .complete }
    }
}

/// The world camera (`arena-layout.md` "Camera and viewport framing").
///
/// D-094 (arena `-004`) tightened the framing from 896 × 414 to 704 × 326
/// world units, so every actor draws about 27% larger. Presentation only:
/// the simulation's own view tests use `RulesViewport`, which keeps the
/// pre-D-094 box so no rule changes.
public struct PresentationCamera: Equatable, Sendable {
    public static let visibleWidth = 704
    public static let visibleHeight = 326
    public static let deadZoneWidth = 76
    public static let deadZoneHeight = 50
    public static let maxLookAhead = 76
    /// Look-ahead actually applied along the heading; within `maxLookAhead`.
    public static let lookAhead = 48

    public var center: VecI

    public static func follow(player: VecI, heading: VecQ8, bounds: ArenaManifest.Bounds) -> PresentationCamera {
        PresentationCamera(
            center: centre(
                player: player,
                heading: heading,
                bounds: bounds,
                width: visibleWidth,
                height: visibleHeight
            )
        )
    }

    /// Follow arithmetic for a view of any size: look-ahead along the
    /// heading's x sign, then clamped so the view stays inside the arena.
    static func centre(player: VecI, heading: VecQ8, bounds: ArenaManifest.Bounds, width: Int, height: Int) -> VecI {
        let look = heading != .zero ? min(maxLookAhead, lookAhead) : 0
        let dirX = heading.x.raw >= 0 ? 1 : -1
        var x = player.x + dirX * look
        var y = player.y
        let halfW = width / 2
        let halfH = height / 2
        x = min(max(x, bounds.minX + halfW), bounds.maxX - halfW)
        y = min(max(y, bounds.minY + halfH), bounds.maxY - halfH)
        return VecI(x: x, y: y)
    }

    /// True when `point` lies inside the view centred on `center`.
    public static func contains(_ point: VecI, center: VecI) -> Bool {
        abs(point.x - center.x) <= visibleWidth / 2 && abs(point.y - center.y) <= visibleHeight / 2
    }
}

/// The view box the simulation's rules test against: spawn fairness
/// (`arena.md` § 8, "outside the current viewport") and the T1 tutorial's
/// "Camera in view" trigger.
///
/// D-094 is presentation only and states that the viewport change touches
/// no rule. These two tests are authoritative (they reach the digest), so
/// they keep the pre-D-094 896 × 414 box rather than following the camera.
/// The 704 × 326 view always lies inside this box (same follow, smaller
/// half-sizes, both clamped to the arena), so a socket outside it is also
/// outside what the player sees: the offscreen-spawn guarantee only gets
/// stricter.
public enum RulesViewport {
    public static let width = 896
    public static let height = 414

    public static func box(player: VecI, heading: VecQ8, bounds: ArenaManifest.Bounds) -> AABB {
        AABB(
            center: PresentationCamera.centre(player: player, heading: heading, bounds: bounds, width: width, height: height),
            halfSize: VecI(x: width / 2, y: height / 2)
        )
    }
}
