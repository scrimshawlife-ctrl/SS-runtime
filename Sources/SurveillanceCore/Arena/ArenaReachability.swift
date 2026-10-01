/// Grid BFS over Civic Seam collision. Presentation sprites never contribute.
public enum ArenaReachability {
    public static let gridStep = 16
    public static let criticalRadius = 64
    public static let combatRadius = 80
    public static let bossCorridorRadius = 96
    public static let cameraStandRadius = 64
    public static let consecutiveZoneIDs = ["Z-01", "Z-02", "Z-03", "Z-04", "Z-05", "Z-06", "Z-07"]

    public static func boxes(
        _ manifest: ArenaManifest,
        closedGateIDs: Set<String> = [],
        extraSolids: [AABB] = []
    ) -> [AABB] {
        var boxes = manifest.permanentSolids.map(\.aabb)
        for gate in manifest.gates where closedGateIDs.contains(gate.id) {
            boxes.append(gate.aabb)
        }
        boxes.append(contentsOf: extraSolids)
        return boxes
    }

    public static func boundsBox(_ manifest: ArenaManifest) -> AABB {
        manifest.boundsUnits.aabb
    }

    public static func isWalkable(
        _ point: VecI,
        radius: Int,
        bounds: AABB,
        solids: [AABB]
    ) -> Bool {
        let q = point.asQ8
        let clamped = Collision.clampCenter(q, radius: radius, bounds: bounds)
        if clamped.x.raw != q.x.raw || clamped.y.raw != q.y.raw { return false }
        let probe = Circle(center: q, radiusUnits: radius)
        return !solids.contains { probe.penetrates($0) }
    }

    public struct Flood: Equatable, Sendable {
        public var step: Int
        public var cols: Int
        public var rows: Int
        public var seen: [Bool]
        public var originWalkable: Bool

        public func containsGrid(x: Int, y: Int) -> Bool {
            guard x >= 0, y >= 0, x < cols, y < rows else { return false }
            return seen[y * cols + x]
        }

        public func containsPoint(_ point: VecI) -> Bool {
            guard originWalkable else { return false }
            if point.x % step == 0, point.y % step == 0 {
                return containsGrid(x: point.x / step, y: point.y / step)
            }
            return containsGrid(x: point.x / step, y: point.y / step)
                || containsGrid(x: (point.x + step - 1) / step, y: point.y / step)
                || containsGrid(x: point.x / step, y: (point.y + step - 1) / step)
        }

        public func intersects(_ box: AABB) -> Bool {
            let minGX = max(0, box.minX / step)
            let maxGX = min(cols - 1, box.maxX / step)
            let minGY = max(0, box.minY / step)
            let maxGY = min(rows - 1, box.maxY / step)
            guard minGX <= maxGX, minGY <= maxGY else { return false }
            for gy in minGY...maxGY {
                for gx in minGX...maxGX {
                    let point = VecI(x: gx * step, y: gy * step)
                    if box.contains(point), containsGrid(x: gx, y: gy) { return true }
                }
            }
            return false
        }
    }

    public static func flood(
        from start: VecI,
        radius: Int,
        manifest: ArenaManifest,
        closedGateIDs: Set<String> = [],
        extraSolids: [AABB] = []
    ) -> Flood {
        let bounds = boundsBox(manifest)
        let solids = boxes(manifest, closedGateIDs: closedGateIDs, extraSolids: extraSolids)
        let step = gridStep
        let cols = (manifest.boundsUnits.maxX / step) + 1
        let rows = (manifest.boundsUnits.maxY / step) + 1
        var seen = [Bool](repeating: false, count: cols * rows)
        func index(_ gx: Int, _ gy: Int) -> Int { gy * cols + gx }
        func walkable(_ gx: Int, _ gy: Int) -> Bool {
            guard gx >= 0, gy >= 0, gx < cols, gy < rows else { return false }
            return isWalkable(VecI(x: gx * step, y: gy * step), radius: radius, bounds: bounds, solids: solids)
        }

        var queue: [(Int, Int)] = []
        let startWalkable = isWalkable(start, radius: radius, bounds: bounds, solids: solids)
        let seeds: [(Int, Int)] = {
            var points = [(start.x / step, start.y / step)]
            if start.x % step != 0 { points.append(((start.x + step - 1) / step, start.y / step)) }
            if start.y % step != 0 { points.append((start.x / step, (start.y + step - 1) / step)) }
            return points
        }()
        for (gx, gy) in seeds where walkable(gx, gy) {
            let i = index(gx, gy)
            if !seen[i] {
                seen[i] = true
                queue.append((gx, gy))
            }
        }

        var cursor = 0
        let deltas = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        while cursor < queue.count {
            let (gx, gy) = queue[cursor]
            cursor += 1
            for (dx, dy) in deltas {
                let nx = gx + dx
                let ny = gy + dy
                guard nx >= 0, ny >= 0, nx < cols, ny < rows else { continue }
                let i = index(nx, ny)
                if seen[i] { continue }
                guard walkable(nx, ny) else { continue }
                seen[i] = true
                queue.append((nx, ny))
            }
        }
        return Flood(step: step, cols: cols, rows: rows, seen: seen, originWalkable: startWalkable || queue.isEmpty == false)
    }

    public static func zone(_ manifest: ArenaManifest, id: String) -> NamedRect? {
        manifest.zones.first { $0.id == id }
    }

    public static func consecutiveZonesConnected(_ manifest: ArenaManifest) -> Bool {
        let spawn = VecI(x: manifest.playerSpawn.x, y: manifest.playerSpawn.y)
        let reached = flood(from: spawn, radius: criticalRadius, manifest: manifest)
        guard reached.originWalkable else { return false }
        for pair in zip(consecutiveZoneIDs, consecutiveZoneIDs.dropFirst()) {
            guard let a = zone(manifest, id: pair.0), let b = zone(manifest, id: pair.1) else { return false }
            if !reached.intersects(a.aabb) || !reached.intersects(b.aabb) { return false }
        }
        return true
    }

    public static func bossCorridorClear(_ manifest: ArenaManifest) -> Bool {
        guard let court = zone(manifest, id: "Z-06") else { return false }
        let start = VecI(x: manifest.bossSpawn.x, y: manifest.bossSpawn.y)
        let reached = flood(from: start, radius: bossCorridorRadius, manifest: manifest)
        return reached.originWalkable && reached.intersects(court.aabb)
    }

    public static func reachable(
        _ point: VecI,
        from start: VecI,
        radius: Int,
        manifest: ArenaManifest,
        closedGateIDs: Set<String> = [],
        extraSolids: [AABB] = []
    ) -> Bool {
        let bounds = boundsBox(manifest)
        let solids = boxes(manifest, closedGateIDs: closedGateIDs, extraSolids: extraSolids)
        guard isWalkable(point, radius: radius, bounds: bounds, solids: solids) else { return false }
        return flood(
            from: start,
            radius: radius,
            manifest: manifest,
            closedGateIDs: closedGateIDs,
            extraSolids: extraSolids
        ).containsPoint(point)
    }

    public static func enemySocketsReachable(_ manifest: ArenaManifest) -> Bool {
        let radius = PlayerBody.radiusUnits
        for (encounterId, sockets) in manifest.enemySpawnSockets {
            guard let trigger = manifest.encounterTriggers.first(where: { $0.encounterId == encounterId }) else {
                return false
            }
            let start = trigger.center
            let reached = flood(from: start, radius: radius, manifest: manifest)
            for socket in sockets {
                let point = VecI(x: socket.x, y: socket.y)
                if !reached.containsPoint(point) { return false }
            }
        }
        return true
    }

    public static func extractionReachable(_ manifest: ArenaManifest, bossGateClosed: Bool) -> Bool {
        let spawn = VecI(x: manifest.playerSpawn.x, y: manifest.playerSpawn.y)
        let closed: Set<String> = bossGateClosed ? ["gate-boss-extraction"] : []
        return reachable(
            manifest.extraction.center,
            from: spawn,
            radius: PlayerBody.radiusUnits,
            manifest: manifest,
            closedGateIDs: closed
        )
    }

    public static func maEscapeOpen(_ manifest: ArenaManifest) -> Bool {
        guard let civic = zone(manifest, id: "Z-03") else { return false }
        let spawn = VecI(x: manifest.playerSpawn.x, y: manifest.playerSpawn.y)
        return flood(
            from: spawn,
            radius: PlayerBody.radiusUnits,
            manifest: manifest,
            closedGateIDs: ["gate-ma-forward"]
        ).intersects(civic.aabb)
    }

    public static func forwardGateID(for encounter: String) -> String? {
        switch encounter {
        case "M-A": "gate-ma-forward"
        case "M-B": "gate-mb-forward"
        case "M-C": "gate-mc-forward"
        default: nil
        }
    }

    public static func previousZoneID(for encounter: String) -> String? {
        switch encounter {
        case "M-A": "Z-02"
        case "M-B": "Z-03"
        case "M-C": "Z-04"
        default: nil
        }
    }

    /// Authored backtrack aperture with the forward gate closed. Enemies do not block the Player,
    /// so peak-density parseability is this same corridor (T407 / arena.md §6).
    /// The previous-zone AABB is inset by one cell so a trigger sitting on a shared edge
    /// (M-C / Z-04 at x=1664) cannot pass without a real interior route.
    public static func escapeApertureOpen(_ manifest: ArenaManifest, encounter: String) -> Bool {
        guard let previousID = previousZoneID(for: encounter),
              let previous = zone(manifest, id: previousID),
              let trigger = manifest.encounterTriggers.first(where: { $0.encounterId == encounter }),
              let gate = forwardGateID(for: encounter)
        else { return false }
        let inset = manifest.cellSizeUnits
        let inner = AABB(
            center: previous.center,
            halfSize: VecI(
                x: max(0, previous.halfSize.x - inset),
                y: max(0, previous.halfSize.y - inset)
            )
        )
        return flood(
            from: trigger.center,
            radius: PlayerBody.radiusUnits,
            manifest: manifest,
            closedGateIDs: [gate]
        ).intersects(inner)
    }

    public static func spawnAlleyProtected(_ manifest: ArenaManifest) -> Bool {
        guard let alley = zone(manifest, id: "Z-01") else { return false }
        if manifest.cameraSockets.contains(where: { $0.zoneId == "Z-01" || alley.aabb.contains($0.position) }) {
            return false
        }
        let hostiles =
            manifest.enemySpawnSockets.values.flatMap { $0 }
            + [manifest.eliteSpawn, manifest.bossSpawn]
        if hostiles.contains(where: { alley.aabb.contains(VecI(x: $0.x, y: $0.y)) }) {
            return false
        }
        let spawn = VecI(x: manifest.playerSpawn.x, y: manifest.playerSpawn.y)
        let solids = manifest.solidsForCollision
        for socket in manifest.cameraSockets where socket.enabled {
            let origin = CameraPlacement.fieldOrigin(socket: socket, geometry: manifest.standardCameraGeometry)
            if Collision.pointInCone(
                origin: origin,
                point: spawn.asQ8,
                headingMilli: socket.headingMilliDegrees,
                halfFieldMilli: socket.fieldAngleMilliDegrees / 2,
                rangeUnits: socket.rangeUnits
            ), Collision.lineOfFireClear(from: origin, to: spawn.asQ8, solids: solids) {
                return false
            }
        }
        return true
    }

    public static func geometryInBounds(_ manifest: ArenaManifest) -> Bool {
        let bounds = manifest.boundsUnits
        func pointOK(_ x: Int, _ y: Int) -> Bool {
            x >= bounds.minX && x <= bounds.maxX && y >= bounds.minY && y <= bounds.maxY
        }
        func rectOK(_ rect: NamedRect) -> Bool {
            pointOK(rect.aabb.minX, rect.aabb.minY) && pointOK(rect.aabb.maxX, rect.aabb.maxY)
        }
        if !pointOK(manifest.playerSpawn.x, manifest.playerSpawn.y) { return false }
        if !pointOK(manifest.eliteSpawn.x, manifest.eliteSpawn.y) { return false }
        if !pointOK(manifest.bossSpawn.x, manifest.bossSpawn.y) { return false }
        let extract = manifest.extraction.aabb
        if !pointOK(extract.minX, extract.minY) || !pointOK(extract.maxX, extract.maxY) { return false }
        if !manifest.zones.allSatisfy(rectOK) { return false }
        if !manifest.permanentSolids.allSatisfy(rectOK) { return false }
        if !manifest.gates.allSatisfy(rectOK) { return false }
        if !manifest.encounterTriggers.allSatisfy(rectOK) { return false }
        if !manifest.cameraSockets.allSatisfy({ pointOK($0.position.x, $0.position.y) }) { return false }
        let sockets = manifest.enemySpawnSockets.values.flatMap { $0 } + manifest.extractionPressureSockets
        if !sockets.allSatisfy({ pointOK($0.x, $0.y) }) { return false }
        if !manifest.captainCameraEmitters.allSatisfy({ pointOK($0.x, $0.y) }) { return false }
        return true
    }

    public static func requiredPointsClearOfSolids(_ manifest: ArenaManifest) -> Bool {
        authoredSolidOverlaps(manifest).isEmpty
    }

    public static func authoredSolidOverlaps(_ manifest: ArenaManifest) -> [String] {
        let solids = manifest.permanentSolids
        var reasons: [String] = []
        func hit(_ point: VecI, _ label: String) {
            for solid in solids where solid.aabb.contains(point) {
                reasons.append("\(label) in \(solid.id)")
            }
        }
        hit(VecI(x: manifest.playerSpawn.x, y: manifest.playerSpawn.y), "spawn")
        hit(manifest.extraction.center, "extractCenter")
        hit(VecI(x: manifest.eliteSpawn.x, y: manifest.eliteSpawn.y), "elite")
        hit(VecI(x: manifest.bossSpawn.x, y: manifest.bossSpawn.y), "boss")
        for trigger in manifest.encounterTriggers {
            hit(trigger.center, "trigger:\(trigger.id)")
        }
        for socket in manifest.enemySpawnSockets.values.flatMap({ $0 }) {
            hit(VecI(x: socket.x, y: socket.y), "socket:\(socket.id ?? "?")")
        }
        for gate in manifest.gates {
            if gate.aabb.contains(VecI(x: manifest.playerSpawn.x, y: manifest.playerSpawn.y)) {
                reasons.append("gate \(gate.id) overlaps spawn")
            }
            for socket in manifest.enemySpawnSockets.values.flatMap({ $0 }) {
                if gate.aabb.contains(VecI(x: socket.x, y: socket.y)) {
                    reasons.append("gate \(gate.id) overlaps \(socket.id ?? "?")")
                }
            }
        }
        for solid in solids where overlaps(solid.aabb, manifest.extraction.aabb) {
            reasons.append("solid \(solid.id) overlaps extraction")
        }
        return reasons.sorted()
    }

    public static func fieldOriginsInsideSolids(_ manifest: ArenaManifest) -> [String] {
        let solids = boxes(manifest)
        return manifest.cameraSockets.compactMap { socket in
            let origin = CameraPlacement.fieldOrigin(socket: socket, geometry: manifest.standardCameraGeometry)
            let point = VecI(x: origin.x.unitsTruncated, y: origin.y.unitsTruncated)
            return solids.contains(where: { $0.contains(point) }) ? socket.socketId : nil
        }.sorted()
    }

    public static func fieldOriginsOutsideSolids(_ manifest: ArenaManifest) -> Bool {
        fieldOriginsInsideSolids(manifest).isEmpty
    }

    /// `arena-layout.md` "Camera and viewport framing" (D-094, arena `-004`):
    /// 704 × 326 visible, a 76 × 50 dead zone, 76 units of look-ahead. The
    /// presentation camera carries the same numbers, so the manifest and the
    /// camera cannot disagree without failing the arena load.
    public static func viewportMatchesContract(_ manifest: ArenaManifest) -> Bool {
        let view = manifest.viewport
        return view.baselineWorldWidth == PresentationCamera.visibleWidth
            && view.baselineWorldHeight == PresentationCamera.visibleHeight
            && view.deadZoneWidth == PresentationCamera.deadZoneWidth
            && view.deadZoneHeight == PresentationCamera.deadZoneHeight
            && view.maximumLookAheadUnits == PresentationCamera.maxLookAhead
            && PresentationCamera.visibleWidth == 704
            && PresentationCamera.visibleHeight == 326
    }

    public static func diagonalSpine(_ manifest: ArenaManifest) -> Bool {
        let ids = ["Z-01", "Z-02", "Z-03", "Z-04"]
        let zones = ids.compactMap { zone(manifest, id: $0) }
        guard zones.count == 4 else { return false }
        for (previous, next) in zip(zones, zones.dropFirst()) {
            if next.center.x <= previous.center.x { return false }
            if next.center.y <= previous.center.y { return false }
        }
        return true
    }

    public static func blockedCameraStands(_ manifest: ArenaManifest, radius: Int) -> [String] {
        let bounds = boundsBox(manifest)
        let solids = boxes(manifest)
        return manifest.cameraSockets.compactMap { socket in
            isWalkable(socket.position, radius: radius, bounds: bounds, solids: solids)
                ? nil
                : socket.socketId
        }.sorted()
    }

    private static func overlaps(_ a: AABB, _ b: AABB) -> Bool {
        a.minX <= b.maxX && a.maxX >= b.minX && a.minY <= b.maxY && a.maxY >= b.minY
    }
}
