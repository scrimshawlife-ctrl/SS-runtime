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
    /// Presentation rotation, **counter-clockwise positive**.
    ///
    /// Deliberately not a heading. The clockwise-positive milli-degree
    /// convention describes facing and targeting, and a decoration faces
    /// nothing — so this is applied directly rather than through
    /// `radians(milliDegrees:)`, which negates for that convention.
    public var rotationMilliDegrees: Int?

    public var scale: Int { scalePermille ?? 1000 }
    public var rotation: Int { rotationMilliDegrees ?? 0 }

    public init(
        id: String,
        assetId: String,
        center: VecI,
        scalePermille: Int? = nil,
        rotationMilliDegrees: Int? = nil
    ) {
        self.id = id
        self.assetId = assetId
        self.center = center
        self.scalePermille = scalePermille
        self.rotationMilliDegrees = rotationMilliDegrees
    }
}

/// One Transit Patrol member (D-091, `civic-seam-arena-004` `patrols`): a
/// standard archetype and the closed loop of waypoints it walks while
/// unaware. Decoded strictly, like the schema: every key required, no other
/// key, integer coordinates.
public struct PatrolRoute: Equatable, Sendable, Codable {
    public var id: String
    public var zoneId: String
    public var archetype: ArchetypeID
    public var waypoints: [VecI]

    public init(id: String, zoneId: String, archetype: ArchetypeID, waypoints: [VecI]) {
        self.id = id
        self.zoneId = zoneId
        self.archetype = archetype
        self.waypoints = waypoints
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private static let keys: Set<String> = ["id", "zoneId", "archetype", "waypoints"]
    private static let pointKeys: Set<String> = ["x", "y"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard Set(container.allKeys.map(\.stringValue)) == Self.keys else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "patrol keys"))
        }
        id = try container.decode(String.self, forKey: Key(stringValue: "id"))
        zoneId = try container.decode(String.self, forKey: Key(stringValue: "zoneId"))
        archetype = try container.decode(ArchetypeID.self, forKey: Key(stringValue: "archetype"))
        var list = try container.nestedUnkeyedContainer(forKey: Key(stringValue: "waypoints"))
        var points: [VecI] = []
        while !list.isAtEnd {
            let point = try list.nestedContainer(keyedBy: Key.self)
            guard Set(point.allKeys.map(\.stringValue)) == Self.pointKeys else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "waypoint keys"))
            }
            points.append(VecI(
                x: try point.decode(Int.self, forKey: Key(stringValue: "x")),
                y: try point.decode(Int.self, forKey: Key(stringValue: "y"))
            ))
        }
        waypoints = points
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(id, forKey: Key(stringValue: "id"))
        try container.encode(zoneId, forKey: Key(stringValue: "zoneId"))
        try container.encode(archetype, forKey: Key(stringValue: "archetype"))
        var list = container.nestedUnkeyedContainer(forKey: Key(stringValue: "waypoints"))
        for point in waypoints {
            var entry = list.nestedContainer(keyedBy: Key.self)
            try entry.encode(point.x, forKey: Key(stringValue: "x"))
            try entry.encode(point.y, forKey: Key(stringValue: "y"))
        }
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
    /// D-091 Transit Patrol members. Required by `civic-seam-arena-004`.
    public var patrols: [PatrolRoute]

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
        let data = BundledResource.data(name: "civic-seam-arena-004", subdirectory: "contracts")
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
    /// A `patrols` member is malformed or unfair (D-091): not a standard
    /// archetype, fewer than two waypoints, an unknown zone, or a waypoint
    /// outside its zone, inside a solid or gate, or inside an encounter trigger.
    case patrol(String)
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
        for route in manifest.patrols { try unique(route.id) }
        try validatePatrols(manifest)

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

extension ArenaLoader {
    /// The data-only fairness rules of `enemies-and-encounters.md` § Transit
    /// Patrol that need no simulation: each waypoint lies inside its zone,
    /// outside every permanent solid and gate, and outside every encounter
    /// trigger. The cone and route rules (EN-030) are proven by
    /// `PatrolFairness` in the tests.
    static func validatePatrols(_ manifest: ArenaManifest) throws {
        let standard: Set<ArchetypeID> = [
            .fogAnalyticsCloud, .cableCarCorrelator, .sutroSignalWitch, .autonomousInformant, .victorianVendor
        ]
        for route in manifest.patrols {
            guard standard.contains(route.archetype) else { throw ArenaValidationError.patrol(route.id) }
            guard route.waypoints.count >= 2 else { throw ArenaValidationError.patrol(route.id) }
            guard let zone = manifest.zones.first(where: { $0.id == route.zoneId }) else {
                throw ArenaValidationError.patrol(route.id)
            }
            for point in route.waypoints {
                let blocked = manifest.permanentSolids.contains { $0.aabb.contains(point) }
                    || manifest.gates.contains { $0.aabb.contains(point) }
                    || manifest.encounterTriggers.contains { $0.aabb.contains(point) }
                guard zone.aabb.contains(point), !blocked else { throw ArenaValidationError.patrol(route.id) }
            }
        }
    }
}

extension ArenaValidationError: Error {}
