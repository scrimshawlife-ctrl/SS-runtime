import Foundation

/// Which environment assets have actually been delivered.
///
/// `visual-assets-001` §3a: environment art is not required for a run to start,
/// and an unbacked solid keeps its authored blockout. That is the same
/// all-or-nothing rule `ClipFrameLibrary` applies to clips — a half-arted level
/// is a legibility hazard rather than a partial improvement, because a player
/// cannot tell which grey rectangles are "not finished" and which are meant to
/// read as concrete.
///
/// So coverage is reported per group, and a group is either fully backed or not
/// used at all.
public struct EnvironmentLibrary: Equatable, Sendable {
    /// Delivered runtime file name by asset ID.
    public let deliveredPaths: [String: String]
    /// Every environment ID the contract names, in contract order.
    public let declaredIds: [String]

    public init(declaredIds: [String], deliveredPaths: [String: String]) {
        self.declaredIds = declaredIds
        self.deliveredPaths = deliveredPaths
    }

    /// The groups the contract is organised into, by ID prefix.
    public enum Group: String, CaseIterable, Sendable {
        case ground = "env_ground_"
        case solid = "env_solid_"
        case camera = "env_camera_"
        case prop = "env_prop_"
        case motif = "env_motif_"
        /// `civic-seam-visual-direction.md` §7. Two layers, and the pair is
        /// the unit: a ground haze with nothing above it reads as a bug
        /// rather than as weather.
        case fog = "env_fog_"
    }

    public func ids(in group: Group) -> [String] {
        declaredIds.filter { $0.hasPrefix(group.rawValue) }
    }

    /// Whether every ID in a group has been delivered.
    ///
    /// All-or-nothing: one missing ground tile leaves the whole plane on its
    /// authored fill rather than tiling five surfaces and leaving a hole.
    public func isBacked(_ group: Group) -> Bool {
        let ids = ids(in: group)
        return !ids.isEmpty && ids.allSatisfy { deliveredPaths[$0] != nil }
    }

    /// Delivered file for an ID, or nil when its group is not fully backed.
    public func path(for assetId: String) -> String? {
        guard let group = Group.allCases.first(where: { assetId.hasPrefix($0.rawValue) }),
              isBacked(group)
        else { return nil }
        return deliveredPaths[assetId]
    }

    public var coverage: (backed: Int, total: Int) {
        (deliveredPaths.keys.filter { declaredIds.contains($0) }.count, declaredIds.count)
    }

    /// Asset ID for an arena solid.
    ///
    /// The contract derives solid IDs from `permanentSolids`, so this is the one
    /// place the naming convention lives: `solid-04-civic-west` becomes
    /// `env_solid_04_civic_west`. If it ever disagrees with the contract the
    /// solid simply falls back to blockout rather than drawing the wrong art.
    public static func solidAssetId(forSolidId id: String) -> String {
        "env_" + id.replacingOccurrences(of: "-", with: "_")
    }

    /// Asset ID for a Camera housing family.
    ///
    /// Deliberately a `switch` rather than a name transform: the contract IDs
    /// are not a mechanical case conversion of the enum (`storefrontCamera` is
    /// `env_camera_storefront`, `temporarySensorMast` is
    /// `env_camera_temporary_mast`), and an exhaustive switch means a new
    /// family fails to build until someone decides what its art is called.
    ///
    /// These are the five *standard* families. The sixth in
    /// `civic-seam-visual-direction.md` §6 is the Captain Camera, which belongs
    /// to the boss rather than to the eight standard mounts.
    public static func cameraAssetId(for family: HousingFamily) -> String {
        switch family {
        case .municipalDome: "env_camera_municipal_dome"
        case .storefrontCamera: "env_camera_storefront"
        case .trafficReader: "env_camera_traffic_reader"
        case .ornamentalCivicCamera: "env_camera_ornamental_civic"
        case .temporarySensorMast: "env_camera_temporary_mast"
        }
    }

    // MARK: - Loading

    public static func bundled() throws -> EnvironmentLibrary {
        let presentation = try SpecBundle.contract("presentation-assets-001")
        guard let root = try? JSONSerialization.jsonObject(with: presentation) as? [String: Any] else {
            throw AssetCatalogError.invalidJSON
        }
        let declared = root["environmentAssetIds"] as? [String] ?? []

        let catalog = try AssetCatalog.bundled()
        var delivered: [String: String] = [:]
        for entry in catalog.entries {
            let record = entry.record
            guard declared.contains(record.assetId), let path = record.runtimePath else { continue }
            switch entry.admissionDecision {
            case .adaptedAdmitted, .originalAccepted:
                delivered[record.assetId] = path
            default:
                continue
            }
        }
        return EnvironmentLibrary(declaredIds: declared, deliveredPaths: delivered)
    }
}
