public enum ContractVersions {
    public static let specificationCommit = "86712f28d867d7a56de5cc19039c4dde7260dfc5"
    public static let ruleset = "ss-rules-001"
    public static let content = "civic-seam-content-001"
    public static let arena = "civic-seam-arena-001"
    public static let replaySchema = "runtime-kernel-001"
    public static let cameraPlacement = "camera-placement-001"
    public static let animation = "animation-civic-seam-001"
    public static let clipMetadata = "clip-metadata-001"
    public static let proceduralVFX = "procedural-vfx-001"
    public static let ambientMotion = "ambient-motion-001"
}

public struct ReplayIdentity: Equatable, Sendable {
    public let rulesetVersion: String
    public let contentVersion: String
    public let arenaVersion: String
    public let replaySchemaVersion: String

    public init(
        rulesetVersion: String,
        contentVersion: String,
        arenaVersion: String,
        replaySchemaVersion: String
    ) {
        self.rulesetVersion = rulesetVersion
        self.contentVersion = contentVersion
        self.arenaVersion = arenaVersion
        self.replaySchemaVersion = replaySchemaVersion
    }

    public static let current = ReplayIdentity(
        rulesetVersion: ContractVersions.ruleset,
        contentVersion: ContractVersions.content,
        arenaVersion: ContractVersions.arena,
        replaySchemaVersion: ContractVersions.replaySchema
    )
}

public enum ContractCompatibility: Equatable, Sendable {
    case compatible
    case incompatible(expected: ReplayIdentity, received: ReplayIdentity)
}

public extension ReplayIdentity {
    func compatibility() -> ContractCompatibility {
        self == .current
            ? .compatible
            : .incompatible(expected: .current, received: self)
    }
}
