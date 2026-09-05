public struct RunReceipt: Equatable, Sendable {
    public var schemaVersion: String
    public var identity: ReplayIdentity
    public var seed: UInt64
    public var outcome: RunOutcome
    public var elapsedTicks: UInt64
    public var finalDigest: String
    public var playerIntegrity: Int
    public var damageTaken: Int
    public var exposureFinal: Int
    public var exposurePeak: Int
    public var detection: DetectionState
    public var lockdownEntered: Bool
    public var damageDealt: Int
    public var defeatsByArchetype: [String: Int]
    public var camerasDestroyed: Int
    public var networkBlackout: Bool
    public var upgrade: UpgradeID?
    public var bossPhases: [String]
    public var bossDefeated: Bool
    public var combatAuthority: CombatAuthoritySnapshot
    public var extractionArmed: Bool
    public var diagnostics: [String]
    public var destructions: [CameraDestructionRecord]
    public var cameraDestructionSummary: CameraDestructionReceiptSummary
    public var cameraPlacementVersion: String
    public var placementSeed: UInt64
    public var selectedSockets: [CameraPlacementReceiptEntry]
    /// ER-007: the only part of a receipt a settings change may move. It is
    /// supplied by the presentation layer, never read from authoritative state,
    /// so no setting can reach the simulation by this route.
    public var presentation: PresentationReceiptMetadata

    public init(_ state: WorldState, presentation: PresentationReceiptMetadata = .default) {
        self.presentation = presentation
        schemaVersion = "run-receipt-001"
        identity = state.identity
        seed = state.seed
        outcome = state.outcome
        elapsedTicks = state.terminalTick ?? state.tick
        finalDigest = state.terminalDigest ?? state.digest()
        playerIntegrity = state.player.integrity
        damageTaken = state.player.damageTaken
        exposureFinal = state.exposure.exposure
        exposurePeak = state.exposure.peak
        detection = state.exposure.detectionState
        lockdownEntered = state.exposure.lockdownEntered
        damageDealt = state.combat.damageDealt
        defeatsByArchetype = state.combat.defeatsByArchetype
        camerasDestroyed = state.destructions.count
        networkBlackout = state.networkBlackout
        upgrade = state.upgrade.selected
        combatAuthority = CombatAuthoritySnapshot.project(state)
        bossPhases = combatAuthority.bossPhasesReached
        bossDefeated = combatAuthority.bossDefeated
        extractionArmed = state.extraction.armed
        diagnostics = state.diagnostic.map { [$0.rawValue] } ?? []
        destructions = state.destructions.sorted {
            if $0.tick != $1.tick { return $0.tick < $1.tick }
            return $0.cameraId < $1.cameraId
        }
        cameraDestructionSummary = CameraDestructionReceiptSummary.project(state)
        cameraPlacementVersion = ContractVersions.cameraPlacement
        placementSeed = CameraPlacement.placementSeed(runSeed: state.seed)
        selectedSockets = state.cameras
            .sorted { $0.socketId.utf8LessThan($1.socketId) }
            .map {
                CameraPlacementReceiptEntry(
                    socketId: $0.socketId,
                    cameraEntityId: $0.entityId,
                    housingFamily: $0.housingFamily
                )
            }
    }

    public func canonical() -> CanonicalJSON {
        .object([
            "schemaVersion": .string(schemaVersion),
            "identity": .object([
                "rulesetVersion": .string(identity.rulesetVersion),
                "contentVersion": .string(identity.contentVersion),
                "arenaVersion": .string(identity.arenaVersion),
                "replaySchemaVersion": .string(identity.replaySchemaVersion)
            ]),
            "seed": .unsigned(seed),
            "outcome": .string(outcome == .success ? "success" : outcome == .failure ? "failure" : "invalid"),
            "elapsedTicks": .unsigned(elapsedTicks),
            "finalDigest": .string(finalDigest),
            "player": .object([
                "finalIntegrity": .integer(Int64(playerIntegrity)),
                "damageTaken": .integer(Int64(damageTaken))
            ]),
            "exposure": .object([
                "final": .integer(Int64(exposureFinal)),
                "peak": .integer(Int64(exposurePeak)),
                "finalState": .string(detection.rawValue),
                "lockdownEntered": .bool(lockdownEntered)
            ]),
            "combat": .object([
                "damageDealt": .integer(Int64(damageDealt)),
                "defeatsByArchetype": .object(defeatsByArchetype.mapValues { .integer(Int64($0)) })
            ]),
            "objectives": .object([
                "combatAuthority": .object([
                    "mobEncountersComplete": .integer(Int64(combatAuthority.mobEncountersComplete)),
                    "mobEncountersRequired": .integer(Int64(combatAuthority.mobEncountersRequired)),
                    "currentNode": .string(combatAuthority.currentNode.rawValue),
                    "elite": .object([
                        "id": .string(EncounterDirector.eliteReceiptId),
                        "defeated": .bool(combatAuthority.eliteDefeated)
                    ]),
                    "boss": .object([
                        "id": .string(EncounterDirector.bossReceiptId),
                        "defeated": .bool(combatAuthority.bossDefeated),
                        "phasesReached": .array(combatAuthority.bossPhasesReached.map { .string($0) })
                    ]),
                    "complete": .bool(combatAuthority.complete)
                ]),
                "networkBlackout": .object([
                    "camerasDestroyed": .integer(Int64(camerasDestroyed)),
                    "camerasTotal": .integer(8),
                    "complete": .bool(networkBlackout)
                ]),
                "extractionArmed": .bool(extractionArmed)
            ]),
            "cameraDestructions": .array(destructions.map { record in
                .object([
                    "cameraId": .string(record.cameraId.decimalString),
                    "tick": .unsigned(record.tick),
                    "housingFamily": .string(record.housingFamily.rawValue),
                    "wasDetectingPlayer": .bool(record.wasDetectingPlayer),
                    "source": .string(record.source),
                    "exposureBefore": .integer(Int64(record.exposureBefore)),
                    "exposureAfter": .integer(Int64(record.exposureAfter)),
                    "triggeredLockdown": .bool(record.triggeredLockdown)
                ])
            }),
            "camerasDamaged": .integer(Int64(cameraDestructionSummary.camerasDamaged)),
            "camerasDestroyed": .integer(Int64(cameraDestructionSummary.camerasDestroyed)),
            "tamperExposureApplied": .integer(Int64(cameraDestructionSummary.tamperExposureApplied)),
            "cameraObjective": .object([
                "destroyed": .integer(Int64(cameraDestructionSummary.objectiveDestroyed)),
                "total": .integer(Int64(cameraDestructionSummary.objectiveTotal)),
                "complete": .bool(cameraDestructionSummary.objectiveComplete)
            ]),
            "upgrade": upgrade.map { .string($0.rawValue) } ?? .null,
            "boss": .object([
                "phasesReached": .array(combatAuthority.bossPhasesReached.map { .string($0) }),
                "defeated": .bool(combatAuthority.bossDefeated)
            ]),
            "diagnostics": .array(diagnostics.map { .string($0) }),
            "presentation": presentation.canonical,
            "cameraPlacement": .object([
                "version": .string(cameraPlacementVersion),
                "placementSeed": .unsigned(placementSeed),
                "selectedSockets": .array(selectedSockets.map { socket in
                    .object([
                        "socketId": .string(socket.socketId),
                        "cameraEntityId": .unsigned(socket.cameraEntityId.raw),
                        "housingFamily": .string(socket.housingFamily.rawValue)
                    ])
                })
            ])
        ])
    }
}

public struct CameraPlacementReceiptEntry: Equatable, Sendable {
    public var socketId: String
    public var cameraEntityId: EntityID
    public var housingFamily: HousingFamily
}
