/// Spawn fairness for T407 / `enemies-encounters-001` / `arena.md` §8.
/// Never run a flood from `ArenaManifest.bundled()` — only from spawn attempts and content CI.
public enum SpawnFairness {
    public static let retryIntervalTicks = 30
    public static let timeoutTicks = 300

    public struct LethalVolume: Equatable, Sendable {
        public var center: VecQ8
        public var radius: Int

        public init(center: VecQ8, radius: Int) {
            self.center = center
            self.radius = radius
        }
    }

    public static func rank(_ sockets: [ArenaPoint], player: VecQ8) -> [ArenaPoint] {
        sockets.sorted { a, b in
            let da = player.distanceSquared(to: VecI(x: a.x, y: a.y).asQ8)
            let db = player.distanceSquared(to: VecI(x: b.x, y: b.y).asQ8)
            if da != db { return da > db }
            return (a.id ?? "").utf8LessThan(b.id ?? "")
        }
    }

    public static func viewportBox(player: VecQ8, heading: VecQ8, bounds: ArenaManifest.Bounds) -> AABB {
        let view = PresentationCamera.follow(
            player: VecI(x: player.x.unitsTruncated, y: player.y.unitsTruncated),
            heading: heading,
            bounds: bounds
        )
        return AABB(
            center: view.center,
            halfSize: VecI(x: PresentationCamera.visibleWidth / 2, y: PresentationCamera.visibleHeight / 2)
        )
    }

    /// First valid authored socket, or `nil` to defer. Offscreen sockets win; on-screen sockets
    /// are only used as the spec's "visibly delivered" exception when no offscreen candidate exists.
    /// Declared offscreen margin is absent from `combat-content-002`; do not invent one (T406 / D-021).
    public static func select(
        sockets: [ArenaPoint],
        player: VecQ8,
        heading: VecQ8,
        archetypeRadius: Int,
        manifest: ArenaManifest,
        closedGateIDs: Set<String>,
        extraSolids: [AABB] = [],
        lethalVolumes: [LethalVolume] = []
    ) -> ArenaPoint? {
        let bounds = ArenaReachability.boundsBox(manifest)
        let solids = ArenaReachability.boxes(manifest, closedGateIDs: closedGateIDs, extraSolids: extraSolids)
        let alley = ArenaReachability.zone(manifest, id: "Z-01")?.aabb
        let view = viewportBox(player: player, heading: heading, bounds: manifest.boundsUnits)
        let playerPoint = VecI(x: player.x.unitsTruncated, y: player.y.unitsTruncated)
        let flood = ArenaReachability.flood(
            from: playerPoint,
            radius: PlayerBody.radiusUnits,
            manifest: manifest,
            closedGateIDs: closedGateIDs,
            extraSolids: extraSolids
        )

        var offscreen: [ArenaPoint] = []
        var delivered: [ArenaPoint] = []
        for socket in rank(sockets, player: player) {
            let point = VecI(x: socket.x, y: socket.y)
            guard isFair(
                point: point,
                archetypeRadius: archetypeRadius,
                player: player,
                bounds: bounds,
                solids: solids,
                spawnAlley: alley,
                flood: flood,
                lethalVolumes: lethalVolumes
            ) else { continue }
            let body = Circle(center: point.asQ8, radiusUnits: archetypeRadius)
            if body.penetrates(view) {
                delivered.append(socket)
            } else {
                offscreen.append(socket)
            }
        }
        return offscreen.first ?? delivered.first
    }

    public static func isFair(
        point: VecI,
        archetypeRadius: Int,
        player: VecQ8,
        bounds: AABB,
        solids: [AABB],
        spawnAlley: AABB?,
        flood: ArenaReachability.Flood,
        lethalVolumes: [LethalVolume]
    ) -> Bool {
        let center = point.asQ8
        let body = Circle(center: center, radiusUnits: archetypeRadius)
        guard ArenaReachability.isWalkable(point, radius: archetypeRadius, bounds: bounds, solids: solids) else {
            return false
        }
        if let spawnAlley, body.penetrates(spawnAlley) { return false }
        let combined = Int64(PlayerBody.radiusUnits + archetypeRadius) * Q8.scale
        if player.distanceSquared(to: center) <= combined * combined { return false }
        if !flood.containsPoint(point) { return false }
        for volume in lethalVolumes {
            let reach = Int64(archetypeRadius + volume.radius) * Q8.scale
            if center.distanceSquared(to: volume.center) < reach * reach { return false }
        }
        return true
    }

    /// Point-in-solid sockets. Pinned `civic-seam-arena-002.json` defects; do not rewrite coordinates.
    public static func socketsBlockedByPermanentSolids(_ manifest: ArenaManifest) -> [String] {
        let solids = manifest.permanentSolids
        var ids: [String] = []
        for socket in manifest.enemySpawnSockets.values.flatMap({ $0 }) {
            let point = VecI(x: socket.x, y: socket.y)
            if solids.contains(where: { $0.aabb.contains(point) }) {
                ids.append(socket.id ?? "\(socket.x),\(socket.y)")
            }
        }
        return ids.sorted { $0.utf8LessThan($1) }
    }

    /// Encounter-zone leaks. Authored sockets remain the approved region; do not reject at spawn time.
    public static func socketsOutsideEncounterZone(
        _ manifest: ArenaManifest,
        content: CombatContent
    ) -> [String] {
        var ids: [String] = []
        for (encounter, sockets) in manifest.enemySpawnSockets {
            guard let zoneId = content.encounters[encounter]?.zone,
                  let zone = ArenaReachability.zone(manifest, id: zoneId)
            else { continue }
            for socket in sockets {
                let point = VecI(x: socket.x, y: socket.y)
                if !zone.aabb.contains(point) {
                    ids.append(socket.id ?? "\(socket.x),\(socket.y)")
                }
            }
        }
        return ids.sorted { $0.utf8LessThan($1) }
    }
}
