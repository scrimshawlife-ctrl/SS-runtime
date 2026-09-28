import Foundation

/// `run-shell.md` § 10.2 (D-081): the stored best run for one daily seed.
///
/// Local storage only. It carries the seed because a replay needs it; it is
/// never shown to the player and never shared (§ 11).
public struct GhostRecord: Codable, Equatable, Sendable {
    /// One recorded command. Short keys keep a several-thousand-tick run small.
    public struct Command: Codable, Equatable, Sendable {
        public var t: UInt64
        public var x: Int16
        public var y: Int16
        public var d: Bool
        public var u: UInt8?

        public init(_ command: PlayerCommand) {
            t = command.tick
            x = command.moveX
            y = command.moveY
            d = command.dodgePressed
            u = command.upgradeChoiceIndex
        }

        public var playerCommand: PlayerCommand {
            PlayerCommand(tick: t, moveX: x, moveY: y, dodgePressed: d, upgradeChoiceIndex: u)
        }
    }

    public var rulesetVersion: String
    public var contentVersion: String
    public var arenaVersion: String
    public var replaySchemaVersion: String
    public var seed: UInt64
    /// Terminal tick of the recorded run.
    public var ticks: UInt64
    /// State digest at `ticks`.
    public var digest: String
    /// Every command that advanced the run, minus neutral ones: a missing
    /// command and a neutral command step the simulation identically.
    public var commands: [Command]

    public init(
        identity: ReplayIdentity,
        seed: UInt64,
        ticks: UInt64,
        digest: String,
        commands: [PlayerCommand]
    ) {
        rulesetVersion = identity.rulesetVersion
        contentVersion = identity.contentVersion
        arenaVersion = identity.arenaVersion
        replaySchemaVersion = identity.replaySchemaVersion
        self.seed = seed
        self.ticks = ticks
        self.digest = digest
        self.commands = commands.filter { !$0.isNeutral }.map(Command.init)
    }

    /// A record of a finished live run, or nil unless it succeeded: § 10.2
    /// "the player's best successful run".
    public init?(successfulRun state: WorldState, commands: [PlayerCommand]) {
        guard state.outcome == .success else { return nil }
        self.init(
            identity: state.identity,
            seed: state.seed,
            ticks: state.tick,
            digest: state.digest(),
            commands: commands
        )
    }

    public var identity: ReplayIdentity {
        ReplayIdentity(
            rulesetVersion: rulesetVersion,
            contentVersion: contentVersion,
            arenaVersion: arenaVersion,
            replaySchemaVersion: replaySchemaVersion
        )
    }

    public var playerCommands: [PlayerCommand] { commands.map(\.playerCommand) }

    /// § 10.2 "Best means success in the fewest ticks". A stored record from
    /// another seed or Replay Identity is not a best for this run at all.
    public static func replaces(_ stored: GhostRecord?, candidateTicks: UInt64, seed: UInt64, identity: ReplayIdentity) -> Bool {
        guard let stored, stored.seed == seed, stored.identity == identity else { return true }
        return candidateTicks < stored.ticks
    }
}

extension PlayerCommand {
    var isNeutral: Bool {
        moveX == 0 && moveY == 0 && !dodgePressed && upgradeChoiceIndex == nil
    }
}

/// `run-shell.md` § 10.2: the ghost, replayed one tick for each tick of the
/// live run.
///
/// Presentation only. It owns a private `Simulation` that nothing else reads
/// or writes; the live run never sees it, so it has no collision, damage,
/// audio, haptics, targeting, or effect on any authoritative field, digest,
/// or receipt (RS-014).
public struct GhostRun: Sendable {
    public let record: GhostRecord
    private var simulation: Simulation
    private var commands: [PlayerCommand]
    private var nextCommand = 0
    /// Test seam for the mutation check: a ghost that runs ahead of the live
    /// tick must be caught by the lockstep tests. Always 0 outside tests.
    let lead: UInt64

    /// Nil when the Replay Identity or seed differs from the live run's, or
    /// when a full replay does not reproduce the stored ticks and digest.
    public init?(record: GhostRecord, liveIdentity: ReplayIdentity, liveSeed: UInt64) {
        self.init(record: record, liveIdentity: liveIdentity, liveSeed: liveSeed, lead: 0)
    }

    init?(record: GhostRecord, liveIdentity: ReplayIdentity, liveSeed: UInt64, lead: UInt64) {
        guard record.identity == liveIdentity,
              record.identity.compatibility() == .compatible,
              record.seed == liveSeed,
              record.ticks > 0
        else { return nil }
        let commands = record.playerCommands
        guard Self.commandsAreOrdered(commands, ticks: record.ticks) else { return nil }
        guard let verified = Self.replay(seed: record.seed, commands: commands, until: record.ticks),
              verified.state.tick == record.ticks,
              verified.state.digest() == record.digest
        else { return nil }
        guard let fresh = try? Simulation.make(seed: record.seed) else { return nil }
        self.record = record
        self.simulation = fresh
        self.commands = commands
        self.lead = lead
    }

    /// The ghost's current tick.
    public var tick: UInt64 { simulation.state.tick }

    /// The ghost stops at its own terminal tick (§ 10.2).
    public var finished: Bool { tick >= record.ticks || simulation.isTerminal }

    /// Terminal tick of the recorded run.
    public var terminalTick: UInt64 { record.ticks }

    /// Ghost Player position, in whole arena units.
    public var playerPosition: VecI {
        VecI(
            x: simulation.state.player.position.x.unitsTruncated,
            y: simulation.state.player.position.y.unitsTruncated
        )
    }

    /// Advances the ghost to `liveTick`, one simulation step per tick, and no
    /// further than its own terminal tick.
    public mutating func advance(to liveTick: UInt64) {
        let target = min(liveTick &+ lead, record.ticks)
        while simulation.state.tick < target, !simulation.isTerminal {
            let before = simulation.state.tick
            step()
            // A verified record never stalls; this only guards the loop.
            if simulation.state.tick == before { return }
        }
    }

    private mutating func step() {
        let next = simulation.state.tick + 1
        var command: PlayerCommand?
        if nextCommand < commands.count, commands[nextCommand].tick == next {
            command = commands[nextCommand]
            nextCommand += 1
        }
        simulation.step(command: command)
    }

    /// § 10.2 "fades out": opacity multiplier for a ghost that finished at
    /// `terminalTick`, seen from `liveTick`. 1 while running; linear to 0 over
    /// `fadeTicks`; 0 at once with Reduced Motion.
    public static let fadeTicks: UInt64 = 30

    public func fade(liveTick: UInt64, reducedMotion: Bool) -> Double {
        guard finished, liveTick > record.ticks else { return 1 }
        if reducedMotion { return 0 }
        let since = liveTick - record.ticks
        if since >= Self.fadeTicks { return 0 }
        return 1 - Double(since) / Double(Self.fadeTicks)
    }

    // MARK: - Verification

    private static func commandsAreOrdered(_ commands: [PlayerCommand], ticks: UInt64) -> Bool {
        var previous: UInt64 = 0
        for command in commands {
            guard command.tick > previous, command.tick <= ticks else { return false }
            if let choice = command.upgradeChoiceIndex, UpgradeID.from(index: choice) == nil { return false }
            previous = command.tick
        }
        return true
    }

    /// Replays `commands` from the authored initial state. Nil if the stream
    /// stalls (an upgrade gate with no recorded choice), so a damaged record
    /// can never hang the caller.
    static func replay(seed: UInt64, commands: [PlayerCommand], until ticks: UInt64) -> Simulation? {
        guard var simulation = try? Simulation.make(seed: seed) else { return nil }
        var index = 0
        while simulation.state.tick < ticks, !simulation.isTerminal {
            let next = simulation.state.tick + 1
            var command: PlayerCommand?
            if index < commands.count, commands[index].tick == next {
                command = commands[index]
                index += 1
            }
            let before = simulation.state.tick
            simulation.step(command: command)
            if simulation.state.tick == before { return nil }
        }
        return simulation
    }
}
