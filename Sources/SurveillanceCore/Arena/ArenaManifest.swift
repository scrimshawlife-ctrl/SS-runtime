import Foundation

public enum HousingFamily: String, Equatable, Sendable, Codable, CaseIterable {
    case municipalDome
    case storefrontCamera
    case trafficReader
    case ornamentalCivicCamera
    case temporarySensorMast
}

public struct ArenaPoint: Equatable, Sendable, Codable {
    public var id: String?
    public var x: Int
    public var y: Int
    public var headingMilliDegrees: Int?
}

public struct NamedRect: Equatable, Sendable, Codable {
    public var id: String
    public var name: String?
    public var owner: String?
    public var encounterId: String?
    public var center: VecI
    public var halfSize: VecI
    public var initiallyClosed: Bool?

    public var aabb: AABB { AABB(center: center, halfSize: halfSize) }
}

public struct CameraSocket: Equatable, Sendable, Codable {
    public var socketId: String
    public var zoneId: String
    public var position: VecI
    public var headingMilliDegrees: Int
    public var rangeUnits: Int
    public var fieldAngleMilliDegrees: Int
    public var allowedHousingFamilies: [HousingFamily]
    public var tutorialEligible: Bool
    public var returnVisible: Bool
    public var enabled: Bool
    public var incompatibleSocketIds: [String]
}

public struct StandardCameraGeometry: Equatable, Sendable, Codable {
    public var mountCollisionRadiusUnits: Int
    public var hitRadiusUnits: Int
    public var fieldOriginOffset: VecI
    public var targetAnchorOffset: VecI
}

public struct ExtractionRegion: Equatable, Sendable, Codable {
    public var center: VecI
    public var halfSize: VecI
    public var countdownTicks: Int
    public var leaveRule: String

    public var aabb: AABB { AABB(center: center, halfSize: halfSize) }
}

public struct ViewportSpec: Equatable, Sendable, Codable {
    public var baselineWorldWidth: Int
    public var baselineWorldHeight: Int
    public var deadZoneWidth: Int
    public var deadZoneHeight: Int
    public var maximumLookAheadUnits: Int
}

public struct CaptainEmitter: Equatable, Sendable, Codable {
    public var id: String
    public var x: Int
    public var y: Int
    public var headingMilliDegrees: Int
    public var rangeUnits: Int
    public var fieldAngleMilliDegrees: Int

    public var position: VecI { VecI(x: x, y: y) }
}

public struct Decoration: Equatable, Sendable, Codable {
    public var id: String
    public var assetId: String
    public var center: VecI
    /// 1000 = native size. Motifs are landmarks and are placed scaled down.
    /// Absent in the contract means native, so it decodes as optional.
    public var scalePermille: Int?

    public var scale: Int { scalePermille ?? 1000 }

    public init(id: String, assetId: String, center: VecI, scalePermille: Int? = nil) {
        self.id = id
        self.assetId = assetId
        self.center = center
        self.scalePermille = scalePermille
    }
}

public struct ArenaManifest: Equatable, Sendable, Codable {
    public var schemaVersion: String
    public var arenaVersion: String
    public var cellSizeUnits: Int
    public var gridSizeCells: VecIWidthHeight
    public var boundsUnits: Bounds
    public var standardCameraGeometry: StandardCameraGeometry
    public var playerSpawn: ArenaPoint
    public var zones: [NamedRect]
    /// Non-collidable authored dressing. `civic-seam-001` §5a: presentation
    /// only, and a decoration may never overlap a permanent solid — it would
    /// suggest cover where none exists.
    ///
    /// Optional so a spec baseline predating the field still decodes; absent
    /// simply means an undressed arena. Read through `placedDecorations`.
    public var decorations: [Decoration]?

    public var placedDecorations: [Decoration] { decorations ?? [] }
    public var permanentSolids: [NamedRect]
    public var gates: [NamedRect]
    public var encounterTriggers: [NamedRect]
    public var enemySpawnSockets: [String: [ArenaPoint]]
    public var eliteSpawn: ArenaPoint
    public var bossSpawn: ArenaPoint
    public var extractionPressureSockets: [ArenaPoint]
    public var captainCameraEmitters: [CaptainEmitter]
    public var cameraSockets: [CameraSocket]
    public var extraction: ExtractionRegion
    public var viewport: ViewportSpec

    public struct VecIWidthHeight: Equatable, Sendable, Codable {
        public var width: Int
        public var height: Int
    }

    public struct Bounds: Equatable, Sendable, Codable {
        public var minX: Int
        public var minY: Int
        public var maxX: Int
        public var maxY: Int

        public var aabb: AABB {
            AABB(
                center: VecI(x: (minX + maxX) / 2, y: (minY + maxY) / 2),
                halfSize: VecI(x: (maxX - minX) / 2, y: (maxY - minY) / 2)
            )
        }
    }

    public static func bundled() throws -> ArenaManifest {
        let data = BundledResource.data(name: "civic-seam-arena-001", subdirectory: "contracts")
        return try ArenaLoader.decodeAndValidate(data)
    }

    public var solidsForCollision: [(id: String, box: AABB)] {
        permanentSolids.map { ($0.id, $0.aabb) }
    }
}

public enum ArenaValidationError: Equatable, Sendable {
    case schema
    case identity
    case counts
    case bounds
    case duplicateID(String)
    case cameraPlacement
}

public enum ArenaLoader {
    public static func decodeAndValidate(_ data: Data) throws -> ArenaManifest {
        let decoder = JSONDecoder()
        let manifest: ArenaManifest
        do {
            manifest = try decoder.decode(ArenaManifest.self, from: data)
        } catch {
            throw ArenaValidationError.schema
        }
        try validate(manifest)
        return manifest
    }

    public static func validate(_ manifest: ArenaManifest) throws {
        guard manifest.schemaVersion == "arena-manifest-001" else { throw ArenaValidationError.identity }
        guard manifest.arenaVersion == ContractVersions.arena else { throw ArenaValidationError.identity }
        guard manifest.cellSizeUnits == 64 else { throw ArenaValidationError.counts }
        guard manifest.gridSizeCells.width == 36, manifest.gridSizeCells.height == 24 else {
            throw ArenaValidationError.counts
        }
        guard manifest.boundsUnits.maxX == 2304, manifest.boundsUnits.maxY == 1536 else {
            throw ArenaValidationError.counts
        }
        guard manifest.zones.count == 7,
              manifest.permanentSolids.count == 14,
              manifest.gates.count == 5,
              manifest.cameraSockets.count == 18
        else {
            throw ArenaValidationError.counts
        }

        var ids = Set<String>()
        func unique(_ id: String) throws {
            if ids.contains(id) { throw ArenaValidationError.duplicateID(id) }
            ids.insert(id)
        }
        for zone in manifest.zones { try unique(zone.id) }
        for solid in manifest.permanentSolids { try unique(solid.id) }
        for gate in manifest.gates { try unique(gate.id) }
        for socket in manifest.cameraSockets { try unique(socket.socketId) }

        let enabled = manifest.cameraSockets.filter(\.enabled)
        guard enabled.count == 18 else { throw ArenaValidationError.counts }
        let byZone = Dictionary(grouping: enabled, by: \.zoneId)
        guard byZone["Z-02"]?.count == 4,
              byZone["Z-03"]?.count == 3,
              byZone["Z-04"]?.count == 4,
              byZone["Z-05"]?.count == 4,
              byZone["Z-06"]?.count == 3
        else {
            throw ArenaValidationError.counts
        }

        guard ArenaReachability.geometryInBounds(manifest) else { throw ArenaValidationError.bounds }
        guard ArenaReachability.viewportMatchesContract(manifest) else { throw ArenaValidationError.bounds }
        guard ArenaReachability.spawnAlleyProtected(manifest) else { throw ArenaValidationError.bounds }
        guard ArenaReachability.diagonalSpine(manifest) else { throw ArenaValidationError.bounds }
        guard CivicSeamIdentity.zoneNamesMatchContract(manifest) else { throw ArenaValidationError.identity }
        guard CameraPlacement.manifestPoolIsValid(manifest.cameraSockets) else {
            throw ArenaValidationError.cameraPlacement
        }
        // Existence only. Full enumeration and fairness BFS stay in content CI (CP-010).
        guard CameraPlacement.hasCompleteCompatibleSet(manifest.cameraSockets) else {
            throw ArenaValidationError.cameraPlacement
        }
    }
}

extension ArenaValidationError: Error {}
