import SpriteKit
import SurveillanceCore
import UIKit
#if DEBUG
import os
#endif

final class GameSession {
    private(set) var simulation: Simulation
    private var cameraHUD = CameraHUDProjector()
    private var audioProjector = AudioProjector()
    /// Last tick's audio projection, consumed by the device layer.
    private(set) var audio = AudioProjection.silent
    var audioSettings: PresentationAudioSettings = .enabled
    private(set) var cameraHUDProjection = CameraHUDProjection(
        notchesVisible: false,
        notchFilled: [false, false, false],
        tamperVisible: false,
        tamperCopy: ""
    )
    private(set) var terminalReceiptStored = false
    var moveX: Int16 = 0
    var moveY: Int16 = 0
    var dodgePressed = false
    var pendingUpgradeChoice: UInt8?

    init(seed: UInt64 = 1) {
        simulation = try! Simulation.make(seed: seed)
    }

    func step() {
        let tick = simulation.state.tick + 1
        let result: TickResult
        if simulation.state.upgrade.pending {
            if let choice = pendingUpgradeChoice {
                result = simulation.step(
                    command: PlayerCommand(
                        tick: tick,
                        moveX: 0,
                        moveY: 0,
                        dodgePressed: false,
                        upgradeChoiceIndex: choice
                    )
                )
                pendingUpgradeChoice = nil
            } else {
                result = simulation.step(command: nil)
            }
        } else {
            result = simulation.step(
                command: PlayerCommand(
                    tick: tick,
                    moveX: moveX,
                    moveY: moveY,
                    dodgePressed: dodgePressed
                )
            )
        }
        applyCameraHUD(result)
        applyAudio(result)
        persistTerminalReceiptIfNeeded()
    }

    private func persistTerminalReceiptIfNeeded() {
        guard !terminalReceiptStored, simulation.state.outcome != .playing else { return }
        if (try? ReceiptStore.persistTerminalReceipt(for: simulation.state)) != nil {
            terminalReceiptStored = true
        }
    }

    func restartRun(seed: UInt64 = 1) {
        simulation = try! Simulation.make(seed: seed)
        terminalReceiptStored = false
        audioProjector.reset()
        audio = AudioProjection.silent
        pendingUpgradeChoice = nil
        moveX = 0
        moveY = 0
        dodgePressed = false
    }

    /// audio-haptics-001: presentation projects authoritative events and never
    /// feeds anything back into the simulation.
    private func applyAudio(_ result: TickResult) {
        audio = audioProjector.project(
            tick: result.tick,
            events: result.events,
            world: AudioWorldQuery.from(simulation.state),
            settings: audioSettings
        )
    }

    private func applyCameraHUD(_ result: TickResult) {
        let state = simulation.state
        let selected = Targeting.select(
            player: state.player,
            enemies: state.enemies,
            cameras: state.cameras,
            solids: state.liveSolids
        )
        var query = CameraHUDQuery.none
        if let selected, let camera = state.cameras.first(where: { $0.entityId == selected.0 }) {
            query = CameraHUDQuery(
                targetIntegrity: camera.integrity,
                damageable: camera.isDamageable,
                targeted: true,
                inRange: true,
                damaged: camera.integrity < 3
            )
        }
        cameraHUDProjection = cameraHUD.project(tick: result.tick, events: result.events, query: query)
    }

#if DEBUG
    func seedScenario(_ scenario: String) -> Bool {
        simulation.debug_seedScenario(scenario)
    }
#endif

    var snapshot: PresentationSnapshot {
        PresentationSnapshot(simulation.state)
    }
}

final class GameScene: SKScene {
    private let session = GameSession()
    private let instrumentation = RunInstrumentation()
    private let deviceRunTracker = DeviceRunTracker()
    private var terminalEvidenceStored = false
    private let renderer = WorldRenderer()
    private let cameraNode = SKCameraNode()
    private let hud = HUDRenderer()
    private let soundEngine = AudioEngine()
    private var controller = TouchController()
    private var projector: HUDProjector?
    /// player-controller-001 PC-008: pause creates no simulation ticks.
    private var runPaused = false
    /// Raised when the player presses Pause; SwiftUI owns the surface itself.
    var onPauseRequested: (() -> Void)?
    private var settings: PresentationSettings = .defaults
#if DEBUG
    private var autopilot: DebugAutopilot?
    /// The `--console-pty` stream drops on long runs; the unified log survives,
    /// so a full playthrough stays observable after the pipe closes.
    private static let autopilotLog = Logger(
        subsystem: "com.zer0state.surveillancesurvivor",
        category: "autopilot"
    )
#endif

    override func didMove(to view: SKView) {
        backgroundColor = .init(red: 0.055, green: 0.075, blue: 0.10, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.ignoresSiblingOrder = true
        size = CGSize(width: CGFloat(PresentationCamera.visibleWidth), height: CGFloat(PresentationCamera.visibleHeight))
        scaleMode = .aspectFit
        addChild(renderer.root)
        addChild(cameraNode)
        camera = cameraNode
        cameraNode.addChild(hud.root)
        view.isMultipleTouchEnabled = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.instrumentation.noteMemoryWarning()
        }
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        autopilot = DebugAutopilot.fromLaunchArguments(arguments, arena: session.simulation.state.arena)
        // `-SSSeed <scenario>` puts the simulation into a named legal late-game
        // state so the renderer can be observed there. Presentation evidence
        // only: a seeded run says nothing about balance or the acceptance gates.
        if let seedFlag = arguments.firstIndex(of: "-SSSeed"),
           arguments.index(after: seedFlag) < arguments.endIndex
        {
            let scenario = arguments[arguments.index(after: seedFlag)]
            let seeded = session.seedScenario(scenario)
            Self.autopilotLog.notice("seed \(scenario, privacy: .public) -> \(seeded, privacy: .public)")
        }
#endif
        configureHUD(for: view)
        redraw()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        if let view { configureHUD(for: view) }
    }

    /// Rebuilds the HUD projection whenever the safe rectangle can have changed.
    private func configureHUD(for view: SKView) {
        let insets = view.safeAreaInsets
        let projector = HUDProjector(
            viewSize: view.bounds.size,
            safeInsets: EdgeInsetsPoints(
                top: insets.top,
                left: insets.left,
                bottom: insets.bottom,
                right: insets.right
            ),
            sceneSize: size
        )
        self.projector = projector
        hud.configure(
            projector: projector,
            // Handedness is a local setting, not authoritative state.
            handedness: settings.handedness,
            hudScale: settings.hudScale
        )
    }

    /// Local setting; excluded from replay authority.
    private var hudScaleSetting: HUDScaleSetting { settings.hudScale }

    /// Applies presentation settings. Nothing here reaches the simulation:
    /// ER-007 requires the digest and receipt to be unchanged by a settings
    /// change, and none of these values is a simulation input.
    func apply(settings: PresentationSettings) {
        self.settings = settings
        session.audioSettings = settings.audio
        soundEngine.settings = settings.audio
        soundEngine.mix = AudioEngine.Mix(
            master: Float(settings.mix.master) / 100,
            music: Float(settings.mix.music) / 100,
            effects: Float(settings.mix.effects) / 100,
            voice: Float(settings.mix.voice) / 100,
            haptics: Float(settings.mix.haptics) / 100
        )
        hud.pinCameraCounter = settings.pinCameraCounter
        if let view { configureHUD(for: view) }
    }

    func setPaused(_ paused: Bool) {
        runPaused = paused
    }

    override func update(_ currentTime: TimeInterval) {
        instrumentation.frameTimes.recordFrame(timestamp: currentTime)
        guard !runPaused else { return }
#if DEBUG
        if autopilot != nil {
            let snapshot = session.snapshot
            // The upgrade gate is a hard blocker: the simulation refuses to
            // advance until a valid choice arrives. Reach it the way a finger
            // does, through the real hit test, so the gate is actually proven.
            if snapshot.upgradePending, session.pendingUpgradeChoice == nil {
                if let projector,
                   let tap = autopilot!.upgradeTapPoint(projector: projector, hud: hud),
                   let choice = hud.upgradeCardIndex(atPoints: tap, projector: projector)
                {
                    session.pendingUpgradeChoice = choice
                    Self.autopilotLog.notice("upgrade tap at \(tap.debugDescription, privacy: .public) -> index \(choice, privacy: .public)")
                } else {
                    Self.autopilotLog.error("upgrade overlay open but no card was hit — gate is stuck")
                }
            }
            let steer = autopilot!.command(snapshot)
            session.moveX = steer.moveX
            session.moveY = steer.moveY
            session.dodgePressed = steer.dodge
            if snapshot.tick % 60 == 0 {
                let line = """
                    tick=\(snapshot.tick) \
                    player=\(snapshot.player.x),\(snapshot.player.y) \
                    hp=\(snapshot.playerIntegrity) exposure=\(snapshot.exposure) \
                    detection=\(snapshot.detection.rawValue) \
                    enemies=\(snapshot.enemies.count) shots=\(snapshot.projectiles.count) \
                    telegraphs=\(snapshot.telegraphs.count) boss=\(snapshot.boss?.integrity ?? -1) \
                    node=\(snapshot.objectiveNode.rawValue) upgrade=\(snapshot.upgrade?.rawValue ?? "-") \
                    armed=\(snapshot.extractionArmed) outcome=\(snapshot.outcome.rawValue) \
                    music=\(soundEngine.musicState.rawValue) \
                    sprites=\(renderer.spriteCoverage.backed)/\(renderer.spriteCoverage.total)
                    """
                Self.autopilotLog.notice("\(line, privacy: .public)")
            }
            if autopilot!.stalled {
                Self.autopilotLog.error("stalled on node \(snapshot.objectiveNode.rawValue, privacy: .public)")
            }
        } else {
            applyController()
        }
#endif
        session.step()
        soundEngine.apply(session.audio)
        instrumentation.recordSimulation(session.simulation.state)
        persistDeviceEvidenceIfNeeded()
        redraw()
    }

    private func applyController() {
        let command = controller.takeCommand()
        session.moveX = command.moveX
        session.moveY = command.moveY
        session.dodgePressed = command.dodgePressed
    }

    private func persistDeviceEvidenceIfNeeded() {
        guard !terminalEvidenceStored, session.simulation.state.outcome != .playing else { return }
        terminalEvidenceStored = true
        deviceRunTracker.noteTerminalOutcome(session.simulation.state.outcome)
        let snapshot = instrumentation.evidence()
        let deviceEvidence = snapshot.makeDeviceRunEvidence(
            deviceClass: "iPhone 12",
            consecutiveCompleteRuns: deviceRunTracker.consecutiveCompleteRuns,
            atlasMemoryBytes: nil
        )
        _ = try? ReleaseEvidenceStore.exportDeviceRunEvidence(deviceEvidence)
        if deviceRunTracker.consecutiveCompleteRuns >= 3,
           let simulationCeilings = try? D021CeilingEvaluator.profileAndMeasure(),
           let settled = deviceEvidence.settledD021Ceilings(from: simulationCeilings) {
            _ = try? ReleaseEvidenceStore.exportReleaseCandidateWithBundledPlaytests(
                deviceEvidence: [deviceEvidence],
                d021DeviceProfiling: settled
            )
        }
    }

    func restartRun(seed: UInt64? = nil) {
        let nextSeed = seed ?? session.simulation.state.seed
        session.restartRun(seed: nextSeed)
        soundEngine.reset()
        renderer.reset()
        instrumentation.reset()
        terminalEvidenceStored = false
        redraw()
    }

    // MARK: - Input

    private func token(_ touch: UITouch) -> TouchController.TouchToken {
        TouchController.TouchToken(id: ObjectIdentifier(touch))
    }

    /// Touch position in safe-rectangle point space.
    private func points(_ touch: UITouch) -> CGPoint? {
        guard let projector else { return nil }
        return projector.points(fromScenePoint: touch.location(in: cameraNode))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let projector else { return }
        let snap = session.snapshot

        for touch in touches {
            guard let point = points(touch) else { continue }

            if snap.outcome != .playing {
                restartRun()
                return
            }
            // The protected selection takes every touch while it is open.
            if snap.upgradePending {
                if let choice = hud.upgradeCardIndex(atPoints: point, projector: projector) {
                    session.pendingUpgradeChoice = choice
                }
                continue
            }
            switch controller.began(token: token(touch), atPoints: point, layout: hud.controlLayout ?? .empty) {
            case .pause:
                onPauseRequested?()
            case .stick, .dodge, .none:
                break
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let layout = hud.controlLayout else { return }
        for touch in touches {
            guard let point = points(touch) else { continue }
            controller.moved(token: token(touch), toPoints: point, layout: layout)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            controller.ended(token: token(touch))
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            controller.ended(token: token(touch))
        }
    }

    private func redraw() {
        let snap = session.snapshot
        cameraNode.position = CGPoint(x: snap.camera.center.x, y: snap.camera.center.y)
        renderer.render(snap)
        hud.knobOffsetPoints = controller.knobOffset
        hud.dodgePressed = controller.dodgeTouch != nil
        hud.captions = session.audio.captions
        hud.render(snap, cameraHUD: session.cameraHUDProjection, paused: runPaused)
    }
}
