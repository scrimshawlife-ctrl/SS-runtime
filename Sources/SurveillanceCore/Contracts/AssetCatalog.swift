import Foundation

public enum LegacyEvidence {
    public static let repository = "scrimshawlife-ctrl/Surveillance-Survivor"
    public static let commit = "3b20d88d6a6e1fe8f07f45f581359d371fa65d98"
}

public enum AssetKind: String, Equatable, Sendable {
    case sprite
    case atlas
    case texture
    case font
    case audio
    case music
    case vfxDefinition
    case ui
}

public enum AssetProductionStatus: String, Equatable, Sendable {
    case planned
    case inProduction
    case review
    case accepted
    case rejected
}

public enum AssetProvenance: String, Equatable, Sendable {
    case projectOriginal
    case adaptedLegacy
    case licensedThirdParty
}

public enum AssetAdmissionDecision: String, Equatable, Sendable {
    case excluded
    case rejected
    case sfCandidate
    case plannedOriginal
    /// legacy-admission.md §Bounded visual and audio admission: a legacy asset
    /// whose runtime role is unchanged, admitted through the asset-record
    /// process with a digest that matches the frozen commit.
    case adaptedAdmitted
    /// An original work that has been produced and delivered. `plannedOriginal`
    /// means the opposite — still to be made — so a delivered original needs its
    /// own decision rather than overloading the plan.
    case originalAccepted
}

public struct AssetDimensions: Equatable, Sendable {
    public var width: Int
    public var height: Int
}

public struct AssetRecord: Equatable, Sendable {
    public var schemaVersion: String
    public var assetId: String
    public var kind: AssetKind
    public var productionStatus: AssetProductionStatus
    public var runtimeRequired: Bool
    public var provenance: AssetProvenance
    public var license: String?
    public var source: String?
    public var runtimePath: String?
    public var sha256: String?
    public var dimensions: AssetDimensions?
    public var colorSpace: String?
    public var alpha: String?
    public var ownerContract: String
    public var notes: String?
}

public struct AssetCatalogEntry: Equatable, Sendable {
    public var admissionDecision: AssetAdmissionDecision
    public var record: AssetRecord
}

public struct AssetCatalog: Equatable, Sendable {
    public var schemaVersion: String
    public var legacyRepository: String
    public var legacyCommit: String
    public var specificationCommit: String
    public var entries: [AssetCatalogEntry]

    public static func bundled() throws -> AssetCatalog {
        try AssetCatalogLoader.decodeAndValidate(
            catalogJSON: BundledResource.data(name: "asset-catalog-001", subdirectory: "contracts"),
            presentationJSON: BundledResource.data(name: "presentation-assets-001", subdirectory: "contracts")
        )
    }

    public var recordsByID: [String: AssetRecord] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.record.assetId, $0.record) })
    }
}

public enum AssetCatalogError: Equatable, Sendable, Error {
    case invalidJSON
    case schemaVersion
    case identity
    case missingKey(String)
    case unexpectedKey(String)
    case invalidAssetId(String)
    case invalidSHA256(String)
    case acceptedWithoutProvenance(String)
    case excludedRuntimeRequired(String)
    case duplicateAssetId(String)
    case missingRequiredPresentationId(String)
    case plannedOriginalMismatch(String)
    case adaptedAdmittedMismatch(String)
    case originalAcceptedMismatch(String)
}

enum AssetCatalogLoader {
    private static let recordKeys: Set<String> = [
        "schemaVersion", "assetId", "kind", "productionStatus", "runtimeRequired",
        "provenance", "license", "source", "runtimePath", "sha256", "dimensions",
        "colorSpace", "alpha", "ownerContract", "notes"
    ]
    private static let catalogKeys: Set<String> = [
        "schemaVersion", "legacyRepository", "legacyCommit", "specificationCommit", "entries"
    ]
    private static let requiredRecordKeys: Set<String> = [
        "schemaVersion", "assetId", "kind", "productionStatus", "runtimeRequired",
        "provenance", "license", "source", "runtimePath", "sha256", "dimensions",
        "colorSpace", "alpha", "ownerContract"
    ]

    static func decodeAndValidate(catalogJSON: Data, presentationJSON: Data) throws -> AssetCatalog {
        guard let root = try? JSONSerialization.jsonObject(with: catalogJSON) as? [String: Any] else {
            throw AssetCatalogError.invalidJSON
        }
        try rejectUnknownKeys(root, allowed: catalogKeys)
        guard string(root, "schemaVersion") == "asset-catalog-001" else {
            throw AssetCatalogError.schemaVersion
        }
        guard string(root, "legacyRepository") == LegacyEvidence.repository,
              string(root, "legacyCommit") == LegacyEvidence.commit,
              string(root, "specificationCommit") == ContractVersions.specificationCommit
        else {
            throw AssetCatalogError.identity
        }
        guard let rawEntries = root["entries"] as? [[String: Any]] else {
            throw AssetCatalogError.invalidJSON
        }

        var entries: [AssetCatalogEntry] = []
        var seen = Set<String>()
        for rawEntry in rawEntries {
            try rejectUnknownKeys(rawEntry, allowed: ["admissionDecision", "record"])
            guard let decisionRaw = rawEntry["admissionDecision"] as? String,
                  let decision = AssetAdmissionDecision(rawValue: decisionRaw),
                  let rawRecord = rawEntry["record"] as? [String: Any]
            else {
                throw AssetCatalogError.invalidJSON
            }
            let record = try decodeRecord(rawRecord)
            if seen.contains(record.assetId) {
                throw AssetCatalogError.duplicateAssetId(record.assetId)
            }
            seen.insert(record.assetId)
            try validate(record, decision: decision)
            entries.append(AssetCatalogEntry(admissionDecision: decision, record: record))
        }

        try requirePresentationIDs(entries: entries, presentationJSON: presentationJSON)
        return AssetCatalog(
            schemaVersion: "asset-catalog-001",
            legacyRepository: LegacyEvidence.repository,
            legacyCommit: LegacyEvidence.commit,
            specificationCommit: ContractVersions.specificationCommit,
            entries: entries
        )
    }

    private static func decodeRecord(_ raw: [String: Any]) throws -> AssetRecord {
        try rejectUnknownKeys(raw, allowed: recordKeys)
        for key in requiredRecordKeys where raw[key] == nil {
            throw AssetCatalogError.missingKey(key)
        }
        guard string(raw, "schemaVersion") == "asset-record-001" else {
            throw AssetCatalogError.schemaVersion
        }
        let assetId = try nonemptyString(raw, "assetId")
        guard assetId.wholeMatch(of: /^[a-z0-9][a-zA-Z0-9_]*$/) != nil else {
            throw AssetCatalogError.invalidAssetId(assetId)
        }
        guard let kind = AssetKind(rawValue: try nonemptyString(raw, "kind")),
              let status = AssetProductionStatus(rawValue: try nonemptyString(raw, "productionStatus")),
              let provenance = AssetProvenance(rawValue: try nonemptyString(raw, "provenance")),
              let runtimeRequired = raw["runtimeRequired"] as? Bool
        else {
            throw AssetCatalogError.invalidJSON
        }
        let sha256 = optionalString(raw, "sha256")
        if let sha256, sha256.wholeMatch(of: /^[0-9a-f]{64}$/) == nil {
            throw AssetCatalogError.invalidSHA256(assetId)
        }
        return AssetRecord(
            schemaVersion: "asset-record-001",
            assetId: assetId,
            kind: kind,
            productionStatus: status,
            runtimeRequired: runtimeRequired,
            provenance: provenance,
            license: optionalString(raw, "license"),
            source: optionalString(raw, "source"),
            runtimePath: optionalString(raw, "runtimePath"),
            sha256: sha256,
            dimensions: try optionalDimensions(raw["dimensions"]),
            colorSpace: optionalString(raw, "colorSpace"),
            alpha: optionalString(raw, "alpha"),
            ownerContract: try nonemptyString(raw, "ownerContract"),
            notes: optionalString(raw, "notes")
        )
    }

    private static func validate(_ record: AssetRecord, decision: AssetAdmissionDecision) throws {
        if record.productionStatus == .accepted {
            guard let source = record.source, !source.isEmpty,
                  let runtimePath = record.runtimePath, !runtimePath.isEmpty,
                  let sha256 = record.sha256, !sha256.isEmpty,
                  let license = record.license, !license.isEmpty
            else {
                throw AssetCatalogError.acceptedWithoutProvenance(record.assetId)
            }
        }
        switch decision {
        case .excluded, .rejected, .sfCandidate:
            if record.runtimeRequired {
                throw AssetCatalogError.excludedRuntimeRequired(record.assetId)
            }
        case .originalAccepted:
            guard record.productionStatus == .accepted,
                  record.provenance == .projectOriginal,
                  record.runtimeRequired,
                  record.runtimePath?.isEmpty == false,
                  record.sha256?.isEmpty == false
            else {
                throw AssetCatalogError.originalAcceptedMismatch(record.assetId)
            }
        case .adaptedAdmitted:
            // Admission is only real with complete provenance: the accepted
            // status above already demands source, runtimePath, sha256, and
            // license, so here we only pin the shape of the decision itself.
            guard record.productionStatus == .accepted,
                  record.provenance == .adaptedLegacy,
                  record.runtimeRequired,
                  record.source?.hasPrefix("legacy://") == true
            else {
                throw AssetCatalogError.adaptedAdmittedMismatch(record.assetId)
            }
        case .plannedOriginal:
            guard record.productionStatus == .planned,
                  record.provenance == .projectOriginal,
                  record.runtimeRequired,
                  record.source == nil,
                  record.runtimePath == nil,
                  record.sha256 == nil
            else {
                throw AssetCatalogError.plannedOriginalMismatch(record.assetId)
            }
        }
        // Only an original, or a legacy asset admitted under the bounded ADAPT
        // route, may be marked runtime-required.
        if record.runtimeRequired,
           record.provenance != .projectOriginal,
           decision != .adaptedAdmitted,
           decision != .originalAccepted
        {
            throw AssetCatalogError.excludedRuntimeRequired(record.assetId)
        }
        if let runtimePath = record.runtimePath, runtimePath.hasPrefix("ArtSources/") {
            throw AssetCatalogError.excludedRuntimeRequired(record.assetId)
        }
    }

    private static func requirePresentationIDs(entries: [AssetCatalogEntry], presentationJSON: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: presentationJSON) as? [String: Any],
              let visuals = root["requiredAssetIds"] as? [String],
              let audio = root["audioEventIds"] as? [String],
              let music = root["musicAssetIds"] as? [String]
        else {
            throw AssetCatalogError.invalidJSON
        }
        // A required presentation ID is accounted for by a planned original or
        // by a legacy asset admitted under the bounded ADAPT route. Admission
        // supersedes the plan for that ID; it does not leave a hole.
        let covered = Set(
            entries
                .filter {
                    $0.admissionDecision == .plannedOriginal
                        || $0.admissionDecision == .adaptedAdmitted
                        || $0.admissionDecision == .originalAccepted
                }
                .map(\.record.assetId)
        )
        for id in visuals + audio + music {
            guard covered.contains(id) else {
                throw AssetCatalogError.missingRequiredPresentationId(id)
            }
        }
    }

    private static func rejectUnknownKeys(_ object: [String: Any], allowed: Set<String>) throws {
        if let extra = object.keys.first(where: { !allowed.contains($0) }) {
            throw AssetCatalogError.unexpectedKey(extra)
        }
    }

    private static func string(_ object: [String: Any], _ key: String) -> String? {
        object[key] as? String
    }

    private static func nonemptyString(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else {
            throw AssetCatalogError.invalidJSON
        }
        return value
    }

    private static func optionalString(_ object: [String: Any], _ key: String) -> String? {
        if object[key] is NSNull { return nil }
        return object[key] as? String
    }

    private static func optionalDimensions(_ value: Any?) throws -> AssetDimensions? {
        if value == nil || value is NSNull { return nil }
        guard let object = value as? [String: Any],
              let width = intValue(object["width"]),
              let height = intValue(object["height"]),
              width >= 1, height >= 1
        else {
            throw AssetCatalogError.invalidJSON
        }
        return AssetDimensions(width: width, height: height)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}
