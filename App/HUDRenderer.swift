import SpriteKit
import SurveillanceCore

/// Draws the `hud-tutorial-001` HUD at its authored anchors.
///
/// Every element is placed through `HUDProjector`, so the reference canvas is
/// scaled and centred inside the safe rectangle exactly as the contract
/// specifies rather than drawn at raw reference coordinates. Nodes are keyed
/// and reused; nothing is rebuilt per frame.
///
/// No gameplay state depends on points, scale, safe area, or handedness.
@MainActor
final class HUDRenderer {
    /// Font sizes and stroke widths here are authored in scene units at the
    /// pre-D-094 896-unit framing. D-094 shows 704 units across the same
    /// screen, which would draw them 27% larger; scaling by the framing
    /// ratio keeps the HUD the size it was on screen while the world zooms.
    static let framingScale = CGFloat(PresentationCamera.visibleWidth) / 896

    let root = SKNode()
    private var nodes: [String: SKNode] = [:]
    private var seen: Set<String> = []
    private var projector: HUDProjector?
    private var handedness: Handedness = .right
    private var hudScale: HUDScaleSetting = .standard

    /// Cached so touch handling and drawing agree on one geometry.
    private(set) var controlLayout: ControlLayout?

    func configure(projector: HUDProjector, handedness: Handedness, hudScale: HUDScaleSetting) {
        self.projector = projector
        self.handedness = handedness
        self.hudScale = hudScale
        controlLayout = ControlLayout.make(projector: projector, handedness: handedness)
        // Geometry changed: drop every node so nothing keeps a stale size.
        root.removeAllChildren()
        nodes = [:]
    }

    func reset() {
        root.removeAllChildren()
        nodes = [:]
    }

    // MARK: - Node reuse

    private func node<T: SKNode>(_ key: String, make: () -> T) -> T {
        seen.insert(key)
        if let existing = nodes[key] as? T { return existing }
        let created = make()
        nodes[key] = created
        root.addChild(created)
        return created
    }

    private func sweep() {
        for (key, node) in nodes where !seen.contains(key) {
            node.removeFromParent()
            nodes.removeValue(forKey: key)
        }
    }

    // MARK: - Frame

    func render(_ snap: PresentationSnapshot, cameraHUD: CameraHUDProjection, paused: Bool) {
        guard let projector else { return }
        seen = []

        drawIntegrity(snap, projector)
        drawExposure(snap, projector)
        drawDetection(snap, projector)
        drawObjectives(snap, projector)
        drawBoss(snap, projector)
        drawExtraction(snap, projector)
        drawUpgradeBadge(snap, projector)
        // A finished run has nothing left to teach, and the card would sit
        // under the terminal panel. (#64's 300-tick cap retires a stale card
        // during play; this covers a run that ends while one is still fresh.)
        if !snap.outcome.isTerminal { drawTutorial(snap, projector) }
        drawCameraNotches(cameraHUD, projector)
        drawReinforcements(projector)
        if !snap.outcome.isTerminal { drawAwarenessHint(projector) }
        drawCaptions(projector)
        drawControls(snap, projector, paused: paused)
        if snap.upgradePending {
            drawUpgradeSelection(projector)
        }
        drawTerminal(snap, projector)

        sweep()
    }

    // MARK: - Elements

    private func rect(_ element: HUDElement, _ projector: HUDProjector) -> HUDRect {
        let reference = element.topLeftReferenceRect(handedness: handedness)
        return element.isControl
            ? projector.mappedControl(reference)
            : projector.mapped(reference, hudScale: hudScale, informational: true)
    }

    /// A framed meter with a proportional fill that drains from the right.
    private func meter(
        key: String,
        element: HUDElement,
        projector: HUDProjector,
        ratio: CGFloat,
        fillColour: SKColor,
        assetId: String
    ) -> HUDRect {
        let mapped = rect(element, projector)
        let centre = projector.sceneCentre(of: mapped)
        let width = projector.sceneLength(points: mapped.width)
        let height = projector.sceneLength(points: mapped.height)

        let frame = node("\(key)-frame") { () -> SKShapeNode in
            let shape = SKShapeNode(rectOf: CGSize(width: width, height: height))
            shape.name = assetId
            shape.fillColor = .clear
            shape.strokeColor = HUDPalette.frame
            shape.lineWidth = 1 * Self.framingScale
            return shape
        }
        frame.position = centre

        let clamped = max(0, min(1, ratio))
        let fillWidth = width * clamped
        let fill = node("\(key)-fill") { () -> SKShapeNode in
            let shape = SKShapeNode()
            shape.strokeColor = .clear
            return shape
        }
        fill.path = fillWidth > 0
            ? CGPath(
                rect: CGRect(x: 0, y: -height / 2 + 1, width: fillWidth, height: height - 2),
                transform: nil
            )
            : nil
        fill.fillColor = fillColour
        fill.position = CGPoint(x: centre.x - width / 2, y: centre.y)
        return mapped
    }

    private func drawIntegrity(_ snap: PresentationSnapshot, _ projector: HUDProjector) {
        _ = meter(
            key: "integrity",
            element: .playerIntegrity,
            projector: projector,
            ratio: CGFloat(snap.playerIntegrity) / CGFloat(max(1, snap.playerMaxIntegrity)),
            // Critical at a quarter of full (25 of 100 before D-092).
            fillColour: snap.playerIntegrity * 4 <= snap.playerMaxIntegrity ? HUDPalette.critical : HUDPalette.integrity,
            assetId: RuntimeAssetRegistry.HUD.integrityFrame
        )
        label(
            key: "integrity-value",
            text: "\(snap.playerIntegrity)",
            at: CGPoint(
                x: projector.sceneCentre(of: rect(.playerIntegrity, projector)).x,
                y: projector.sceneCentre(of: rect(.playerIntegrity, projector)).y
            ),
            size: 9,
            colour: HUDPalette.text
        )
    }

    /// hud-tutorial-001: 0–1000 projection with notches at 200, 450, 700, 1000.
    private func drawExposure(_ snap: PresentationSnapshot, _ projector: HUDProjector) {
        let carrier = DetectionPresentation.carrier(for: snap.detection)
        let mapped = meter(
            key: "exposure",
            element: .exposureBar,
            projector: projector,
            ratio: CGFloat(snap.exposure) / 1000,
            fillColour: HUDPalette.exposure(for: snap.detection),
            assetId: RuntimeAssetRegistry.HUD.exposureBar
        )
        let centre = projector.sceneCentre(of: mapped)
        let width = projector.sceneLength(points: mapped.width)
        let height = projector.sceneLength(points: mapped.height)

        for threshold in [200, 450, 700, 1000] {
            let notch = node("exposure-notch-\(threshold)") { () -> SKShapeNode in
                let shape = SKShapeNode()
                shape.strokeColor = HUDPalette.frame
                shape.lineWidth = 1 * Self.framingScale
                return shape
            }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: -height / 2))
            path.addLine(to: CGPoint(x: 0, y: height / 2))
            notch.path = path
            notch.position = CGPoint(
                x: centre.x - width / 2 + width * CGFloat(threshold) / 1000,
                y: centre.y
            )
        }
        // UI-008 non-colour carrier: the bar's fill *pattern* distinguishes the
        // state without relying on hue, so grayscale and colour-vision review
        // plates still read. Drawn inside the bar rather than labelled beside
        // it, which would collide with the Detection label at y = 54.
        let marks = node("exposure-pattern") { () -> SKShapeNode in
            let shape = SKShapeNode()
            shape.fillColor = .clear
            return shape
        }
        marks.path = Self.barPattern(
            carrier.barPattern,
            width: width,
            height: height - 4
        )
        marks.position = CGPoint(x: centre.x - width / 2, y: centre.y)
        marks.strokeColor = HUDPalette.patternInk
        marks.lineWidth = 1 * Self.framingScale
    }

    /// hud-tutorial-001 §Exposure presentation bar patterns.
    private static func barPattern(_ pattern: String, width: CGFloat, height: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let half = height / 2
        let step: CGFloat
        switch pattern {
        case "slackDotted": step = 16
        case "diagonalFill": step = 10
        case "crossFill": step = 12
        case "denseChevron": step = 6
        default: step = 8
        }
        var x: CGFloat = step / 2
        while x < width {
            switch pattern {
            case "slackDotted":
                path.move(to: CGPoint(x: x, y: -1))
                path.addLine(to: CGPoint(x: x, y: 1))
            case "diagonalFill":
                path.move(to: CGPoint(x: x, y: -half))
                path.addLine(to: CGPoint(x: x + half, y: half))
            case "crossFill":
                path.move(to: CGPoint(x: x, y: -half))
                path.addLine(to: CGPoint(x: x + half, y: half))
                path.move(to: CGPoint(x: x + half, y: -half))
                path.addLine(to: CGPoint(x: x, y: half))
            case "denseChevron":
                path.move(to: CGPoint(x: x, y: -half))
                path.addLine(to: CGPoint(x: x + step / 2, y: 0))
                path.addLine(to: CGPoint(x: x, y: half))
            default:
                path.addRect(CGRect(x: x, y: -half, width: step / 2, height: height))
            }
            x += step
        }
        return path
    }

    private func drawDetection(_ snap: PresentationSnapshot, _ projector: HUDProjector) {
        let mapped = rect(.detectionLabel, projector)
        let centre = projector.sceneCentre(of: mapped)
        let carrier = DetectionPresentation.carrier(for: snap.detection)
        label(
            key: "detection",
            text: "\(detectionGlyph(carrier.iconShape)) \(snap.detection.rawValue.uppercased())",
            at: centre,
            size: 10,
            colour: snap.detection == .lockdown ? HUDPalette.critical : HUDPalette.text
        )
    }

    /// Distinct non-colour shape per state, per UI-008.
    private func detectionGlyph(_ iconShape: String) -> String {
        switch iconShape {
        case "openEye": "( )"
        case "halfEye": "(-)"
        case "bracketEye": "[o]"
        case "boxedEye": "[#]"
        case "sealedEye": "[X]"
        default: "( )"
        }
    }

    private func drawObjectives(_ snap: PresentationSnapshot, _ projector: HUDProjector) {
        // D-098: an encounter label appears when its encounter activates.
        if let objectiveCopy { label(
            key: "combat-objective",
            text: objectiveCopy,
            at: projector.sceneCentre(of: rect(.combatObjective, projector)),
            size: 10,
            colour: HUDPalette.text,
            alignment: .left,
            leftEdge: projector.sceneCentre(of: rect(.combatObjective, projector)).x
                - projector.sceneLength(points: rect(.combatObjective, projector).width) / 2
        ) }
        // Camera counter stays hidden until first Camera damage.
        if snap.cameraObjectiveVisible || pinCameraCounter {
            let mapped = rect(.cameraObjective, projector)
            label(
                key: "camera-objective",
                text: snap.cameraObjectiveCopy,
                at: projector.sceneCentre(of: mapped),
                size: 9,
                colour: snap.networkBlackout ? HUDPalette.accolade : HUDPalette.text,
                alignment: .left,
                leftEdge: projector.sceneCentre(of: mapped).x
                    - projector.sceneLength(points: mapped.width) / 2
            )
        }
    }

    private func drawBoss(_ snap: PresentationSnapshot, _ projector: HUDProjector) {
        guard let boss = snap.boss else { return }
        let mapped = meter(
            key: "boss",
            element: .bossIntegrity,
            projector: projector,
            ratio: boss.maxIntegrity > 0
                ? CGFloat(boss.integrity) / CGFloat(boss.maxIntegrity)
                : 0,
            fillColour: boss.inTransition ? HUDPalette.dim : HUDPalette.boss,
            assetId: RuntimeAssetRegistry.HUD.bossBar
        )
        let centre = projector.sceneCentre(of: mapped)
        let height = projector.sceneLength(points: mapped.height)
        label(
            key: "boss-phase",
            text: phaseCopy(boss.phase),
            at: CGPoint(x: centre.x, y: centre.y - height),
            size: 7,
            colour: HUDPalette.dim
        )
    }

    private func phaseCopy(_ phase: BossPhase) -> String {
        switch phase {
        case .publicSafety: "PUBLIC SAFETY"
        case .civilLiberties: "CIVIL LIBERTIES"
        case .temporarySafeguard: "TEMPORARY SAFEGUARD"
        case .independentReview: "INDEPENDENT REVIEW"
        }
    }

    /// Countdown only while armed; locked contact shows the prerequisite.
    private func drawExtraction(_ snap: PresentationSnapshot, _ projector: HUDProjector) {
        let mapped = rect(.extractionCountdown, projector)
        let centre = projector.sceneCentre(of: mapped)
        guard snap.extractionArmed else { return }

        let radius = projector.sceneLength(points: mapped.height) / 2
        let ring = node("extraction-ring") { () -> SKShapeNode in
            let shape = SKShapeNode()
            shape.name = RuntimeAssetRegistry.HUD.extractionRing
            shape.fillColor = .clear
            shape.strokeColor = HUDPalette.accolade
            shape.lineWidth = 3 * Self.framingScale
            return shape
        }
        // The ring uses exact tick progress; the number uses ceil(ticks / 60).
        let total = max(1, CGFloat(300))
        let progress = max(0, min(1, CGFloat(snap.extractionRemaining) / total))
        let path = CGMutablePath()
        path.addArc(
            center: .zero,
            radius: radius,
            startAngle: .pi / 2,
            endAngle: .pi / 2 - 2 * .pi * progress,
            clockwise: true
        )
        ring.path = path
        ring.position = centre

        label(
            key: "extraction-seconds",
            text: "\(snap.extractionSeconds)",
            at: centre,
            size: 18,
            colour: HUDPalette.text
        )
    }

    private func drawUpgradeBadge(_ snap: PresentationSnapshot, _ projector: HUDProjector) {
        guard let upgrade = snap.upgrade else { return }
        let mapped = rect(.upgradeBadge, projector)
        let centre = projector.sceneCentre(of: mapped)
        let size = projector.sceneLength(points: mapped.width)

        let badge = node("upgrade-badge") { () -> SKShapeNode in
            let shape = SKShapeNode(rectOf: CGSize(width: size, height: size), cornerRadius: size / 8)
            shape.name = RuntimeAssetRegistry.HUD.upgradeBadge(for: upgrade)
            shape.fillColor = HUDPalette.panel
            shape.strokeColor = HUDPalette.frame
            return shape
        }
        badge.position = centre
        let card = UpgradePresentation.card(for: upgrade)
        badge.accessibilityLabel = card.voiceOverLabel
        label(
            key: "upgrade-badge-glyph",
            text: upgradeGlyph(upgrade),
            at: centre,
            size: 14,
            colour: HUDPalette.text
        )
    }

    /// Non-colour icon per upgrade.
    private func upgradeGlyph(_ upgrade: UpgradeID) -> String {
        switch upgrade {
        case .signalJammer: "///"
        case .ricochetPulse: "<>"
        case .ghostStep: "::"
        }
    }

    /// The card shows a safety message (Lockdown, Extraction) when one is
    /// up; otherwise the one D-098 tutorial line `TutorialLineQueue` chose.
    private func drawTutorial(_ snap: PresentationSnapshot, _ projector: HUDProjector) {
        let candidate = snap.tutorialCopyIsSafetyMessage
            ? snap.tutorialCopy
            : (tutorialsEnabled ? tutorialLine : nil)
        guard let copy = candidate, !copy.isEmpty else { return }
        let mapped = rect(.tutorialCard, projector)
        let centre = projector.sceneCentre(of: mapped)
        let width = projector.sceneLength(points: mapped.width)
        let height = projector.sceneLength(points: mapped.height)

        let backdrop = node("tutorial-backdrop") { () -> SKShapeNode in
            let shape = SKShapeNode(rectOf: CGSize(width: width, height: height), cornerRadius: 4)
            shape.fillColor = HUDPalette.panel
            shape.strokeColor = HUDPalette.frame
            return shape
        }
        backdrop.position = centre
        label(key: "tutorial", text: copy, at: centre, size: 11, colour: HUDPalette.text)
    }

    /// Three notches adjacent to the current Camera target while damageable.
    private func drawCameraNotches(_ cameraHUD: CameraHUDProjection, _ projector: HUDProjector) {
        guard cameraHUD.notchesVisible else {
            if cameraHUD.tamperVisible {
                drawTamper(cameraHUD, projector)
            }
            return
        }
        let mapped = rect(.cameraObjective, projector)
        let origin = projector.sceneCentre(of: mapped)
        let step = projector.sceneLength(points: 14)

        for index in 0..<HUDLayout.integrityNotchCount {
            let filled = cameraHUD.notchFilled[index]
            let notch = node("camera-notch-\(index)") { () -> SKShapeNode in
                SKShapeNode(rectOf: CGSize(width: step * 0.6, height: step))
            }
            notch.name = filled
                ? RuntimeAssetRegistry.HUD.cameraNotchFull
                : RuntimeAssetRegistry.HUD.cameraNotchEmpty
            notch.fillColor = filled ? HUDPalette.text : .clear
            notch.strokeColor = HUDPalette.frame
            notch.position = CGPoint(
                x: origin.x + step * CGFloat(index),
                y: origin.y - step * 1.6
            )
        }
        if cameraHUD.tamperVisible {
            drawTamper(cameraHUD, projector)
        }
    }

    private func drawTamper(_ cameraHUD: CameraHUDProjection, _ projector: HUDProjector) {
        label(
            key: "tamper",
            text: cameraHUD.tamperCopy,
            at: projector.sceneCentre(of: rect(.tamperSpike, projector)),
            size: 11,
            colour: HUDPalette.accolade
        )
    }

    /// `REINFORCEMENTS +<n> • <STATE>` (hud-tutorial.md, D-083) in the slot
    /// `HeatCaptionProjector.referenceRect` names.
    private func drawReinforcements(_ projector: HUDProjector) {
        guard let copy = reinforcementCopy else { return }
        let mapped = projector.mapped(HeatCaptionProjector.referenceRect, hudScale: hudScale, informational: true)
        label(
            key: "reinforcements",
            text: copy,
            at: projector.sceneCentre(of: mapped),
            size: 11,
            colour: HUDPalette.critical
        )
    }

    /// `UNSEEN ENEMIES HOLD • STRIKE FIRST FOR DOUBLE DAMAGE` (hud-tutorial.md,
    /// D-089) in the row `AwarenessHintProjector.referenceRect` names. A
    /// tutorial hint, so the tutorial setting hides it.
    ///
    /// D-098 moved that hint into the one-line tutorial queue, so this row
    /// now carries the D-097 takedown streak (`TAKEDOWN ×3`), which is not a
    /// tutorial and ignores the tutorial setting.
    private func drawAwarenessHint(_ projector: HUDProjector) {
        guard let copy = takedownStreakCopy else { return }
        let mapped = projector.mapped(AwarenessHintProjector.referenceRect, hudScale: hudScale, informational: true)
        label(
            key: "takedown-streak",
            text: copy,
            at: projector.sceneCentre(of: mapped),
            size: 11,
            colour: HUDPalette.text
        )
    }

    /// The D-094 caption stack in a right-hand column, newest at the bottom.
    ///
    /// The layout table does not place captions, so they take the free strip
    /// under the upgrade badge — clear of the tutorial card at the bottom
    /// centre, which carries higher-priority copy and must never be occluded.
    /// `CaptionBoard` has already capped and ordered them; a safety-critical
    /// caption draws bright with a leading bar, a routine one dim without,
    /// so the class is carried by shape as well as by tone.
    private func drawCaptions(_ projector: HUDProjector) {
        guard !captions.isEmpty else { return }
        let column = projector.mapped(
            HUDRect(x: 596, y: 112, width: 224, height: 110),
            hudScale: hudScale,
            informational: true
        )
        let right = projector.scenePoint(
            fromPoints: CGPoint(x: CGFloat(column.x + column.width), y: CGFloat(column.y))
        )
        let line = projector.sceneLength(points: 13)
        for (index, caption) in captions.prefix(CaptionBoard.maxVisible).enumerated() {
            let safety = caption.captionClass == .safety
            label(
                key: "caption-\(index)",
                text: (safety ? "▌ " : "") + caption.text.uppercased(),
                at: CGPoint(x: right.x, y: right.y - line * CGFloat(index)),
                size: 8,
                colour: safety ? HUDPalette.text : HUDPalette.dim,
                alignment: .right
            )
        }
    }

    // MARK: - Controls

    private func drawControls(
        _ snap: PresentationSnapshot,
        _ projector: HUDProjector,
        paused: Bool
    ) {
        guard let layout = controlLayout else { return }

        func scene(_ rect: CGRect) -> (centre: CGPoint, size: CGSize) {
            let centre = projector.scenePoint(fromPoints: CGPoint(x: rect.midX, y: rect.midY))
            return (
                centre,
                CGSize(
                    width: projector.sceneLength(points: Int(rect.width)),
                    height: projector.sceneLength(points: Int(rect.height))
                )
            )
        }

        let stickCentre = projector.scenePoint(fromPoints: layout.stickCentre)
        let stickRadius = projector.sceneLength(points: Int(layout.stickRadius))
        let base = node("control-stick-base") { () -> SKShapeNode in
            let shape = SKShapeNode(circleOfRadius: stickRadius)
            shape.name = RuntimeAssetRegistry.HUD.stickBase
            shape.fillColor = HUDPalette.controlFill
            shape.strokeColor = HUDPalette.controlStroke
            shape.lineWidth = 2 * Self.framingScale
            return shape
        }
        base.position = stickCentre
        base.isAccessibilityElement = true
        base.accessibilityLabel = "Movement stick"

        let knob = node("control-stick-knob") { () -> SKShapeNode in
            let shape = SKShapeNode(circleOfRadius: stickRadius * 0.42)
            shape.name = RuntimeAssetRegistry.HUD.stickKnob
            shape.fillColor = HUDPalette.controlKnob
            shape.strokeColor = HUDPalette.controlStroke
            return shape
        }
        knob.position = projector.scenePoint(
            fromPoints: CGPoint(
                x: layout.stickCentre.x + knobOffsetPoints.x,
                y: layout.stickCentre.y + knobOffsetPoints.y
            )
        )

        let dodge = scene(layout.dodgeRect)
        let dodgeNode = node("control-dodge") { () -> SKShapeNode in
            let shape = SKShapeNode(circleOfRadius: dodge.size.width / 2)
            shape.name = RuntimeAssetRegistry.HUD.dodge
            shape.strokeColor = HUDPalette.controlStroke
            shape.lineWidth = 2 * Self.framingScale
            return shape
        }
        dodgeNode.position = dodge.centre
        dodgeNode.fillColor = dodgePressed ? HUDPalette.controlKnob : HUDPalette.controlFill
        dodgeNode.isAccessibilityElement = true
        dodgeNode.accessibilityLabel = "Dodge"
        label(key: "control-dodge-label", text: "DODGE", at: dodge.centre, size: 7, colour: HUDPalette.text)

        let pause = scene(layout.pauseRect)
        let pauseNode = node("control-pause") { () -> SKShapeNode in
            let shape = SKShapeNode(rectOf: pause.size, cornerRadius: 4)
            shape.name = RuntimeAssetRegistry.HUD.pause
            shape.fillColor = HUDPalette.controlFill
            shape.strokeColor = HUDPalette.controlStroke
            return shape
        }
        pauseNode.position = pause.centre
        pauseNode.isAccessibilityElement = true
        pauseNode.accessibilityLabel = paused ? "Resume" : "Pause"
        label(
            key: "control-pause-label",
            text: paused ? ">" : "||",
            at: pause.centre,
            size: 10,
            colour: HUDPalette.text
        )

        if paused {
            label(
                key: "paused-banner",
                text: "PAUSED",
                at: CGPoint(x: 0, y: 0),
                size: 20,
                colour: HUDPalette.text
            )
        }
    }

    /// Set by `GameScene` each frame from the live controller.
    var knobOffsetPoints: CGPoint = .zero
    var dodgePressed = false
    /// audio-haptics-001 §Accessibility: "Every safety-critical audio event has
    /// a visual caption/event equivalent." D-094: the visible stack from
    /// `CaptionBoard` (at most three, safety-critical first, per the caption
    /// setting); this only draws it.
    var captions: [CaptionBoard.Entry] = []
    /// D-083 heat caption from `HeatCaptionProjector`, or nil. This only draws it.
    var reinforcementCopy: String?
    /// D-089 tutorial copy from `AwarenessHintProjector`, or nil. Since D-098
    /// the hint reaches the screen through `tutorialLine`; kept for evidence.
    var awarenessHintCopy: String?
    /// D-098: the combat objective copy, nil before its encounter activates.
    var objectiveCopy: String?
    /// D-098: the one tutorial line to draw this frame, or nil.
    var tutorialLine: String?
    /// D-097: `TAKEDOWN ×n`, or nil.
    var takedownStreakCopy: String?
    /// camera-destruction.md: the Camera counter may be pinned through settings.
    var pinCameraCounter = false
    /// hud-tutorial-001: "Tutorial completion is a local setting." It governs
    /// tutorial cards only — Lockdown and Extraction share the card but are
    /// safety messages and are never suppressed by it.
    var tutorialsEnabled = true
    /// `run-shell.md` § 11: the run card, set once the run is terminal.
    var runCard: RunCard?

    /// Card geometry in safe-rectangle point space — the single source the
    /// drawing, the hit test, and any synthetic tap all read. Computing it
    /// twice is how a card ends up drawn somewhere it cannot be pressed.
    static let upgradeCardSize = CGSize(width: 200, height: 130)
    static let upgradeCardGap: CGFloat = 24

    func upgradeCardRects(projector: HUDProjector) -> [(upgrade: UpgradeID, rect: CGRect)] {
        let cards = UpgradePresentation.selectionCards()
        let width = Self.upgradeCardSize.width
        let height = Self.upgradeCardSize.height
        let gap = Self.upgradeCardGap
        let total = width * CGFloat(cards.count) + gap * CGFloat(cards.count - 1)
        let originX = CGFloat(projector.safeWidth) / 2 - total / 2
        let centreY = CGFloat(projector.safeHeight) / 2
        return cards.enumerated().map { index, card in
            (
                card.upgrade,
                CGRect(
                    x: originX + CGFloat(index) * (width + gap),
                    y: centreY - height / 2,
                    width: width,
                    height: height
                )
            )
        }
    }

    func upgradeCardCentre(for upgrade: UpgradeID, projector: HUDProjector) -> CGPoint? {
        upgradeCardRects(projector: projector)
            .first { $0.upgrade == upgrade }
            .map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) }
    }

    /// Terminal surface geometry comes from `HUDLayout`, which owns HUD layout
    /// maths and can be tested without the App target.
    private func rect(_ hud: HUDRect) -> CGRect {
        CGRect(x: CGFloat(hud.x), y: CGFloat(hud.y), width: CGFloat(hud.width), height: CGFloat(hud.height))
    }

    func terminalPanelRect(projector: HUDProjector) -> CGRect {
        rect(HUDLayout.terminalPanel(safeWidth: projector.safeWidth, safeHeight: projector.safeHeight))
    }

    /// The restart control. The only thing on screen that restarts a run.
    func terminalRestartRect(projector: HUDProjector) -> CGRect {
        rect(HUDLayout.terminalRestart(safeWidth: projector.safeWidth, safeHeight: projector.safeHeight))
    }

    func terminalRestartHit(atPoints point: CGPoint, projector: HUDProjector) -> Bool {
        terminalRestartRect(projector: projector).contains(point)
    }

    /// `run-shell.md` § 11: the Share control, beside Restart.
    func terminalShareRect(projector: HUDProjector) -> CGRect {
        rect(HUDLayout.terminalShare(safeWidth: projector.safeWidth, safeHeight: projector.safeHeight))
    }

    func terminalShareHit(atPoints point: CGPoint, projector: HUDProjector) -> Bool {
        terminalShareRect(projector: projector).contains(point)
    }

    /// Drawn once the run is over, so a finished run says so instead of looking
    /// like a game that stopped responding.
    private func drawTerminal(_ snap: PresentationSnapshot, _ projector: HUDProjector) {
        guard let title = HUDLayout.terminalCopy(for: snap.outcome) else { return }
        let panel = terminalPanelRect(projector: projector)
        let panelCentre = projector.scenePoint(fromPoints: CGPoint(x: panel.midX, y: panel.midY))

        let scrim = node("terminal-scrim") { () -> SKShapeNode in
            let shape = SKShapeNode(
                rectOf: CGSize(
                    width: projector.sceneLength(points: projector.safeWidth),
                    height: projector.sceneLength(points: projector.safeHeight)
                )
            )
            shape.fillColor = HUDPalette.scrim
            shape.strokeColor = .clear
            return shape
        }
        scrim.position = projector.scenePoint(
            fromPoints: CGPoint(x: CGFloat(projector.safeWidth) / 2, y: CGFloat(projector.safeHeight) / 2)
        )

        let backdrop = node("terminal-backdrop") { () -> SKShapeNode in
            let shape = SKShapeNode(
                rectOf: CGSize(
                    width: projector.sceneLength(points: Int(panel.width)),
                    height: projector.sceneLength(points: Int(panel.height))
                ),
                cornerRadius: 4
            )
            shape.fillColor = HUDPalette.panel
            shape.strokeColor = HUDPalette.frame
            return shape
        }
        backdrop.position = panelCentre

        let safeWidth = projector.safeWidth
        let safeHeight = projector.safeHeight
        label(
            key: "terminal-title",
            text: title,
            at: projector.scenePoint(
                fromPoints: CGPoint(
                    x: panel.midX,
                    y: CGFloat(HUDLayout.terminalTitleCentreY(safeWidth: safeWidth, safeHeight: safeHeight))
                )
            ),
            size: 18,
            colour: HUDPalette.text
        )

        // § 11 run card: label left, value right, one row per line.
        let rows = runCard?.rows ?? []
        let inset = CGFloat(HUDLayout.terminalCardInset)
        for (index, row) in rows.prefix(HUDLayout.terminalCardRowCapacity).enumerated() {
            let y = CGFloat(HUDLayout.terminalCardRowCentreY(index, safeWidth: safeWidth, safeHeight: safeHeight))
            label(
                key: "terminal-card-label-\(index)",
                text: row.label,
                at: projector.scenePoint(fromPoints: CGPoint(x: panel.minX + inset, y: y)),
                size: 11,
                colour: HUDPalette.dim,
                alignment: .left
            )
            label(
                key: "terminal-card-value-\(index)",
                text: row.value,
                at: projector.scenePoint(fromPoints: CGPoint(x: panel.maxX - inset, y: y)),
                size: 12,
                colour: row.value == "NEW BEST" || (row.label == RunCard.medalsLabel && row.value.contains("NEW"))
                    ? HUDPalette.accolade
                    : HUDPalette.text,
                alignment: .right
            )
            // § 12: five medals, each possibly `NEW`, can outgrow the row;
            // shrink that one value to fit beside its label.
            if row.label == RunCard.medalsLabel,
               let value = nodes["terminal-card-value-\(index)"] as? SKLabelNode
            {
                let room = projector.sceneLength(points: Int(panel.width - inset * 2) - 64)
                while value.frame.width > room, value.fontSize > 6 {
                    value.fontSize -= 0.5
                }
            }
        }

        drawTerminalControl(
            key: "terminal-restart",
            text: "RESTART",
            rect: terminalRestartRect(projector: projector),
            projector: projector
        )
        drawTerminalControl(
            key: "terminal-share",
            text: "SHARE",
            rect: terminalShareRect(projector: projector),
            projector: projector
        )
    }

    private func drawTerminalControl(key: String, text: String, rect button: CGRect, projector: HUDProjector) {
        let buttonCentre = projector.scenePoint(fromPoints: CGPoint(x: button.midX, y: button.midY))
        let plate = node(key) { () -> SKShapeNode in
            let shape = SKShapeNode(
                rectOf: CGSize(
                    width: projector.sceneLength(points: Int(button.width)),
                    height: projector.sceneLength(points: Int(button.height))
                ),
                cornerRadius: 3
            )
            shape.fillColor = HUDPalette.panel
            shape.strokeColor = HUDPalette.frame
            return shape
        }
        plate.position = buttonCentre
        label(key: "\(key)-label", text: text, at: buttonCentre, size: 13, colour: HUDPalette.text)
    }

    /// Three equal cards in canonical order, no default and no timeout.
    private func drawUpgradeSelection(_ projector: HUDProjector) {
        let cards = UpgradePresentation.selectionCards()
        let rects = upgradeCardRects(projector: projector)
        let cardWidth = projector.sceneLength(points: Int(Self.upgradeCardSize.width))
        let cardHeight = projector.sceneLength(points: Int(Self.upgradeCardSize.height))

        let scrim = node("upgrade-scrim") { () -> SKShapeNode in
            let shape = SKShapeNode(
                rectOf: CGSize(
                    width: projector.sceneLength(points: projector.safeWidth),
                    height: projector.sceneLength(points: projector.safeHeight)
                )
            )
            shape.fillColor = HUDPalette.scrim
            shape.strokeColor = .clear
            return shape
        }
        scrim.position = projector.scenePoint(
            fromPoints: CGPoint(
                x: CGFloat(projector.safeWidth) / 2,
                y: CGFloat(projector.safeHeight) / 2
            )
        )

        for (index, card) in cards.enumerated() {
            // Drawn at exactly the rect the hit test will read back.
            let centre = projector.scenePoint(
                fromPoints: CGPoint(x: rects[index].rect.midX, y: rects[index].rect.midY)
            )

            let backdrop = node("upgrade-card-\(card.upgrade.rawValue)") { () -> SKShapeNode in
                let shape = SKShapeNode(
                    rectOf: CGSize(width: cardWidth, height: cardHeight),
                    cornerRadius: 8
                )
                shape.fillColor = HUDPalette.panel
                shape.strokeColor = HUDPalette.frame
                shape.lineWidth = 2 * Self.framingScale
                shape.isAccessibilityElement = true
                shape.accessibilityLabel = card.voiceOverLabel
                return shape
            }
            backdrop.position = centre

            label(
                key: "upgrade-glyph-\(index)",
                text: upgradeGlyph(card.upgrade),
                at: CGPoint(x: centre.x, y: centre.y + cardHeight * 0.30),
                size: 16,
                colour: HUDPalette.text
            )
            label(
                key: "upgrade-name-\(index)",
                text: card.name.uppercased(),
                at: CGPoint(x: centre.x, y: centre.y + cardHeight * 0.08),
                size: 11,
                colour: HUDPalette.text
            )
            label(
                key: "upgrade-role-\(index)",
                text: card.role.uppercased(),
                at: CGPoint(x: centre.x, y: centre.y - cardHeight * 0.08),
                size: 8,
                colour: HUDPalette.dim
            )
            label(
                key: "upgrade-numbers-\(index)",
                text: card.numericSummary,
                at: CGPoint(x: centre.x, y: centre.y - cardHeight * 0.28),
                size: 7,
                colour: HUDPalette.dim
            )
        }
    }

    /// Which card a touch landed on, read from the same rects that were drawn.
    func upgradeCardIndex(atPoints point: CGPoint, projector: HUDProjector) -> UInt8? {
        for (upgrade, rect) in upgradeCardRects(projector: projector) where rect.contains(point) {
            return upgrade.selectionIndex
        }
        return nil
    }

    // MARK: - Text

    private func label(
        key: String,
        text: String,
        at position: CGPoint,
        size: CGFloat,
        colour: SKColor,
        alignment: SKLabelHorizontalAlignmentMode = .center,
        leftEdge: CGFloat? = nil
    ) {
        let node = node(key) { () -> SKLabelNode in
            let node = SKLabelNode(fontNamed: "Menlo-Bold")
            node.verticalAlignmentMode = .center
            return node
        }
        node.text = text
        node.fontSize = size * Self.framingScale
        node.fontColor = colour
        node.horizontalAlignmentMode = alignment
        node.position = alignment == .left && leftEdge != nil
            ? CGPoint(x: leftEdge!, y: position.y)
            : position
        node.horizontalAlignmentMode = alignment
    }
}

enum HUDPalette {
    static let text = SKColor(white: 0.95, alpha: 1)
    static let dim = SKColor(white: 0.68, alpha: 1)
    static let frame = SKColor(white: 0.80, alpha: 0.75)
    static let panel = SKColor(white: 0.16, alpha: 0.92)
    static let scrim = SKColor(white: 0.04, alpha: 0.72)
    static let integrity = SKColor(white: 0.88, alpha: 0.9)
    static let critical = SKColor(red: 0.95, green: 0.42, blue: 0.32, alpha: 0.95)
    static let boss = SKColor(white: 0.85, alpha: 0.9)
    static let accolade = SKColor(red: 0.55, green: 0.85, blue: 0.70, alpha: 1)
    static let controlFill = SKColor(white: 0.55, alpha: 0.20)
    static let controlKnob = SKColor(white: 0.85, alpha: 0.55)
    static let controlStroke = SKColor(white: 0.85, alpha: 0.55)
    static let patternInk = SKColor(white: 0.92, alpha: 0.45)

    static func exposure(for state: DetectionState) -> SKColor {
        switch state {
        case .hidden: SKColor(white: 0.55, alpha: 0.8)
        case .observed: SKColor(white: 0.68, alpha: 0.85)
        case .tracked: SKColor(red: 0.90, green: 0.78, blue: 0.35, alpha: 0.9)
        case .hunted: SKColor(red: 0.93, green: 0.58, blue: 0.30, alpha: 0.92)
        case .lockdown: SKColor(red: 0.95, green: 0.40, blue: 0.32, alpha: 0.95)
        }
    }
}
