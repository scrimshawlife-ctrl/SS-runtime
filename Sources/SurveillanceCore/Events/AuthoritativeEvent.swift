public enum EventType: String, Equatable, Sendable, CaseIterable {
    case runStarted
    case upgradeSelected
    case dodgeStarted
    case weaponFired
    case projectileHit
    case cameraIntegrityChanged
    case cameraDestroyed
    case entityDamaged
    case entityDied
    case playerDamaged
    case exposureChanged
    case detectionStateChanged
    case lockdownEntered
    case waveStarted
    case mobEncounterCompleted
    case eliteActivated
    case eliteDefeated
    case bossActivated
    case bossPhaseChanged
    case bossAttackStarted
    case bossDefeated
    case allCamerasDestroyed
    case extractionArmed
    case extractionCountdownChanged
    case extractionReset
    case runSucceeded
    case runFailed
    case diagnosticFailure
    /// D-089, appended under D-058: an unaware standard enemy became alerted.
    case enemyAlerted

    public var ordinal: Int {
        switch self {
        case .runStarted: 10
        case .upgradeSelected: 20
        case .dodgeStarted: 30
        case .weaponFired: 40
        case .projectileHit: 50
        case .cameraIntegrityChanged: 60
        case .cameraDestroyed: 70
        case .entityDamaged: 80
        case .entityDied: 90
        case .playerDamaged: 100
        case .exposureChanged: 110
        case .detectionStateChanged: 120
        case .lockdownEntered: 130
        case .waveStarted: 140
        case .mobEncounterCompleted: 150
        case .eliteActivated: 160
        case .eliteDefeated: 170
        case .bossActivated: 180
        case .bossPhaseChanged: 190
        case .bossAttackStarted: 200
        case .bossDefeated: 210
        case .allCamerasDestroyed: 220
        case .extractionArmed: 230
        case .extractionCountdownChanged: 240
        case .extractionReset: 250
        case .runSucceeded: 260
        case .runFailed: 270
        case .diagnosticFailure: 280
        case .enemyAlerted: 290
        }
    }
}

public struct AuthoritativeEvent: Equatable, Sendable {
    public var schemaVersion: String
    public var tick: UInt64
    public var phase: Int
    public var ordinal: Int
    public var sequence: Int
    public var type: EventType
    public var primaryEntityId: EntityID?
    public var secondaryEntityId: EntityID?
    public var payload: [String: CanonicalJSON]
    public var insertion: Int

    public init(
        tick: UInt64,
        phase: Int,
        type: EventType,
        primary: EntityID? = nil,
        secondary: EntityID? = nil,
        payload: [String: CanonicalJSON] = [:],
        insertion: Int
    ) {
        self.schemaVersion = "event-001"
        self.tick = tick
        self.phase = phase
        self.ordinal = type.ordinal
        self.sequence = 0
        self.type = type
        self.primaryEntityId = primary
        self.secondaryEntityId = secondary
        self.payload = payload
        self.insertion = insertion
    }

    public func canonical() -> CanonicalJSON {
        .object([
            "schemaVersion": .string(schemaVersion),
            "tick": .unsigned(tick),
            "ordinal": .integer(Int64(ordinal)),
            "sequence": .integer(Int64(sequence)),
            "type": .string(type.rawValue),
            "primaryEntityId": primaryEntityId.map { .string($0.decimalString) } ?? .null,
            "secondaryEntityId": secondaryEntityId.map { .string($0.decimalString) } ?? .null,
            "payload": .object(payload)
        ])
    }
}

public struct EventBuffer: Equatable, Sendable {
    private var pending: [AuthoritativeEvent] = []
    private var insertion = 0

    public init() {}

    public mutating func emit(
        tick: UInt64,
        phase: Int,
        type: EventType,
        primary: EntityID? = nil,
        secondary: EntityID? = nil,
        payload: [String: CanonicalJSON] = [:]
    ) {
        pending.append(
            AuthoritativeEvent(
                tick: tick,
                phase: phase,
                type: type,
                primary: primary,
                secondary: secondary,
                payload: payload,
                insertion: insertion
            )
        )
        insertion += 1
    }

    public mutating func publish() -> [AuthoritativeEvent] {
        pending.sort { lhs, rhs in
            if lhs.phase != rhs.phase { return lhs.phase < rhs.phase }
            if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
            let lp = lhs.primaryEntityId?.raw ?? 0
            let rp = rhs.primaryEntityId?.raw ?? 0
            if lp != rp { return lp < rp }
            let ls = lhs.secondaryEntityId?.raw ?? 0
            let rs = rhs.secondaryEntityId?.raw ?? 0
            if ls != rs { return ls < rs }
            return lhs.insertion < rhs.insertion
        }
        for index in pending.indices {
            pending[index].sequence = index
        }
        let published = pending
        pending.removeAll(keepingCapacity: true)
        insertion = 0
        return published
    }
}
