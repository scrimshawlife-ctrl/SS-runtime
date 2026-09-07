public struct SelectedCamera: Equatable, Sendable {
    public var socketId: String
    public var entityId: EntityID
    public var housingFamily: HousingFamily
    public var zoneId: String
    public var position: VecI
    public var headingMilliDegrees: Int
    public var rangeUnits: Int
    public var fieldAngleMilliDegrees: Int
    public var tutorialEligible: Bool
    public var returnVisible: Bool
    public var integrity: Int
    public var mountCollisionRadius: Int
    public var hitRadius: Int
    public var fieldOrigin: VecQ8
    public var targetAnchor: VecQ8
    public var wasDetecting: Bool
    public var incompatibleSocketIds: [String]

    public var isDestroyed: Bool { integrity <= 0 }
    public var isDamageable: Bool { integrity > 0 }

    /// Prefix of the solid ID standing for this Camera's mount footprint.
    ///
    /// The mount collides — T411 keeps the footprint after destruction — but it
    /// is never drawn as a blockout, because the housing and head art already
    /// occupy that spot and a rectangle over them is an artifact rather than a
    /// fallback. One constant, so the producer in `WorldState.liveSolids` and
    /// the renderer that skips it cannot drift apart silently.
    public static let mountSolidPrefix = "mount-"

    public var mountSolidId: String { Self.mountSolidPrefix + socketId }

    func incompatible(with other: SelectedCamera) -> Bool {
        incompatibleSocketIds.contains(other.socketId) || other.incompatibleSocketIds.contains(socketId)
    }
}

public enum CameraPlacement {
    public static let requiredByZone: [(zone: String, count: Int)] = [
        ("Z-02", 2), ("Z-03", 1), ("Z-04", 2), ("Z-05", 2), ("Z-06", 1)
    ]
    public static let minimumEnabledByZone: [(zone: String, count: Int)] = [
        ("Z-02", 4), ("Z-03", 3), ("Z-04", 4), ("Z-05", 4), ("Z-06", 3)
    ]
    /// ASCII `CAMERA01`. Placement never consumes combat, encounter, upgrade, or cosmetic RNG.
    public static let streamConstant: UInt64 = 0x4341_4D45_5241_3031

    public static func placementSeed(runSeed: UInt64) -> UInt64 {
        SplitMix64.mix(runSeed ^ streamConstant)
    }

    public static func setKey(_ sockets: [CameraSocket]) -> String {
        sockets.map(\.socketId).sorted { $0.utf8LessThan($1) }.joined(separator: ",")
    }

    public static func setKey(_ cameras: [SelectedCamera]) -> String {
        cameras.map(\.socketId).sorted { $0.utf8LessThan($1) }.joined(separator: ",")
    }

    /// Cheap manifest assertions: pool sizes, zone membership, geometry, symmetric incompatibilities.
    /// Does not run BFS or fairness floods.
    public static func manifestPoolIsValid(_ sockets: [CameraSocket]) -> Bool {
        let enabled = sockets.filter(\.enabled)
        var seen = Set<String>()
        for socket in sockets {
            if !seen.insert(socket.socketId).inserted { return false }
            if socket.headingMilliDegrees < 0 || socket.headingMilliDegrees > 359_999 { return false }
            if socket.rangeUnits < 1 { return false }
            if socket.fieldAngleMilliDegrees <= 0 || socket.fieldAngleMilliDegrees > 180_000 { return false }
            if socket.allowedHousingFamilies.isEmpty { return false }
            if Set(socket.allowedHousingFamilies).count != socket.allowedHousingFamilies.count { return false }
        }
        if enabled.contains(where: { $0.zoneId == "Z-01" || $0.zoneId == "Z-07" }) { return false }
        let allowedZones = Set(requiredByZone.map(\.zone))
        if enabled.contains(where: { !allowedZones.contains($0.zoneId) }) { return false }
        let byZone = Dictionary(grouping: enabled, by: \.zoneId)
        for (zone, need) in minimumEnabledByZone {
            if (byZone[zone]?.count ?? 0) < need { return false }
        }
        let ids = Set(sockets.map(\.socketId))
        for socket in sockets {
            for otherId in socket.incompatibleSocketIds {
                if otherId == socket.socketId { return false }
                guard let other = sockets.first(where: { $0.socketId == otherId }) else { return false }
                if !ids.contains(otherId) { return false }
                if !other.incompatibleSocketIds.contains(socket.socketId) { return false }
            }
        }
        return true
    }

    /// Quota / incompatibility / tutorial / return-visible socket sets. Housing is seed-specific and excluded.
    public static func enumerateLegalSocketSets(_ sockets: [CameraSocket]) -> [[CameraSocket]] {
        collectLegalSocketSets(sockets, limit: nil)
    }

    /// Cheap existence check for arena load. Stops at the first legal set; no fairness BFS.
    public static func hasCompleteCompatibleSet(_ sockets: [CameraSocket]) -> Bool {
        !collectLegalSocketSets(sockets, limit: 1).isEmpty
    }

    /// Runtime selected-set assertions. No BFS. Does not reject pinned field-origin coordinates.
    public static func selectedSetPassesRuntimeAsserts(_ cameras: [SelectedCamera]) -> Bool {
        guard cameras.count == 8 else { return false }
        let counts = Dictionary(grouping: cameras, by: \.zoneId).mapValues(\.count)
        for (zone, need) in requiredByZone {
            if counts[zone] != need { return false }
        }
        if !cameras.contains(where: { $0.zoneId == "Z-02" && $0.tutorialEligible }) { return false }
        if Set(cameras.map(\.housingFamily)).count < 4 { return false }
        if cameras.filter(\.returnVisible).count < 4 { return false }
        if Set(cameras.map(\.socketId)).count != 8 { return false }
        let ordered = cameras.sorted { $0.socketId.utf8LessThan($1.socketId) }
        if cameras.map(\.socketId) != ordered.map(\.socketId) { return false }
        for i in 1..<ordered.count {
            if ordered[i].entityId <= ordered[i - 1].entityId { return false }
        }
        for (i, a) in ordered.enumerated() {
            for b in ordered[(i + 1)...] where a.incompatible(with: b) {
                return false
            }
        }
        return true
    }

    public static func select(
        sockets: [CameraSocket],
        geometry: StandardCameraGeometry,
        runSeed: UInt64,
        allocator: inout EntityAllocator
    ) -> [SelectedCamera]? {
        guard manifestPoolIsValid(sockets) else { return nil }
        var rng = Xoshiro256StarStar.cameraPlacement(runSeed: runSeed)
        let enabled = sockets.filter(\.enabled).sorted { $0.socketId.utf8LessThan($1.socketId) }
        var shuffledByZone: [String: [CameraSocket]] = [:]
        for (zone, _) in requiredByZone {
            var list = enabled.filter { $0.zoneId == zone }
            rng.shuffle(&list)
            shuffledByZone[zone] = list
        }

        var housingBySocket: [String: HousingFamily] = [:]
        for socket in enabled {
            var families = socket.allowedHousingFamilies
            rng.shuffle(&families)
            housingBySocket[socket.socketId] = families[0]
        }

        guard let chosen = searchFirstLegal(
            shuffledByZone: shuffledByZone,
            housingBySocket: housingBySocket
        ) else {
            return nil
        }

        let cameras = materialize(
            chosen,
            housingBySocket: housingBySocket,
            geometry: geometry,
            allocator: &allocator
        )
        guard selectedSetPassesRuntimeAsserts(cameras) else { return nil }
        return cameras
    }

    /// Depth-first first legal set for a fixed shuffle. Search order, not Dictionary iteration, is authoritative.
    public static func searchFirstLegal(
        shuffledByZone: [String: [CameraSocket]],
        housingBySocket: [String: HousingFamily]
    ) -> [CameraSocket]? {
        search(
            zoneIndex: 0,
            selected: [],
            shuffledByZone: shuffledByZone,
            housingBySocket: housingBySocket
        )
    }

    static func materialize(
        _ chosen: [CameraSocket],
        housingBySocket: [String: HousingFamily],
        geometry: StandardCameraGeometry,
        allocator: inout EntityAllocator
    ) -> [SelectedCamera] {
        let ordered = chosen.sorted { $0.socketId.utf8LessThan($1.socketId) }
        return ordered.map { socket in
            SelectedCamera(
                socketId: socket.socketId,
                entityId: allocator.next(),
                housingFamily: housingBySocket[socket.socketId]!,
                zoneId: socket.zoneId,
                position: socket.position,
                headingMilliDegrees: socket.headingMilliDegrees,
                rangeUnits: socket.rangeUnits,
                fieldAngleMilliDegrees: socket.fieldAngleMilliDegrees,
                tutorialEligible: socket.tutorialEligible,
                returnVisible: socket.returnVisible,
                integrity: 3,
                mountCollisionRadius: geometry.mountCollisionRadiusUnits,
                hitRadius: geometry.hitRadiusUnits,
                fieldOrigin: fieldOrigin(socket: socket, geometry: geometry),
                targetAnchor: targetAnchor(socket: socket, geometry: geometry),
                wasDetecting: false,
                incompatibleSocketIds: socket.incompatibleSocketIds
            )
        }
    }

    private static func collectLegalSocketSets(_ sockets: [CameraSocket], limit: Int?) -> [[CameraSocket]] {
        let enabled = sockets.filter(\.enabled).sorted { $0.socketId.utf8LessThan($1.socketId) }
        var results: [[CameraSocket]] = []
        searchAll(
            zoneIndex: 0,
            selected: [],
            pools: Dictionary(grouping: enabled, by: \.zoneId),
            results: &results,
            limit: limit
        )
        return results
    }

    private static func searchAll(
        zoneIndex: Int,
        selected: [CameraSocket],
        pools: [String: [CameraSocket]],
        results: inout [[CameraSocket]],
        limit: Int?
    ) {
        if let limit, results.count >= limit { return }
        if zoneIndex == requiredByZone.count {
            if selected.count == 8, selected.filter(\.returnVisible).count >= 4 {
                results.append(selected.sorted { $0.socketId.utf8LessThan($1.socketId) })
            }
            return
        }
        let spec = requiredByZone[zoneIndex]
        let pool = pools[spec.zone] ?? []
        chooseAll(
            from: pool,
            need: spec.count,
            start: 0,
            picked: [],
            rest: selected,
            zoneIndex: zoneIndex,
            pools: pools,
            results: &results,
            limit: limit
        )
    }

    private static func chooseAll(
        from pool: [CameraSocket],
        need: Int,
        start: Int,
        picked: [CameraSocket],
        rest: [CameraSocket],
        zoneIndex: Int,
        pools: [String: [CameraSocket]],
        results: inout [[CameraSocket]],
        limit: Int?
    ) {
        if let limit, results.count >= limit { return }
        if picked.count == need {
            if requiredByZone[zoneIndex].zone == "Z-02",
               !picked.contains(where: \.tutorialEligible)
            {
                return
            }
            searchAll(
                zoneIndex: zoneIndex + 1,
                selected: rest + picked,
                pools: pools,
                results: &results,
                limit: limit
            )
            return
        }
        if start >= pool.count { return }
        for i in start..<pool.count {
            if let limit, results.count >= limit { return }
            let candidate = pool[i]
            if isIncompatible(candidate, with: rest + picked) { continue }
            chooseAll(
                from: pool,
                need: need,
                start: i + 1,
                picked: picked + [candidate],
                rest: rest,
                zoneIndex: zoneIndex,
                pools: pools,
                results: &results,
                limit: limit
            )
        }
    }

    private static func search(
        zoneIndex: Int,
        selected: [CameraSocket],
        shuffledByZone: [String: [CameraSocket]],
        housingBySocket: [String: HousingFamily]
    ) -> [CameraSocket]? {
        if zoneIndex == requiredByZone.count {
            return isLegal(selected, housingBySocket: housingBySocket) ? selected : nil
        }
        let spec = requiredByZone[zoneIndex]
        let pool = shuffledByZone[spec.zone] ?? []
        return choose(from: pool, need: spec.count, picked: [], rest: selected, zoneIndex: zoneIndex, shuffledByZone: shuffledByZone, housingBySocket: housingBySocket)
    }

    private static func choose(
        from pool: [CameraSocket],
        need: Int,
        picked: [CameraSocket],
        rest: [CameraSocket],
        zoneIndex: Int,
        shuffledByZone: [String: [CameraSocket]],
        housingBySocket: [String: HousingFamily]
    ) -> [CameraSocket]? {
        if picked.count == need {
            if requiredByZone[zoneIndex].zone == "Z-02",
               !picked.contains(where: \.tutorialEligible)
            {
                return nil
            }
            return search(
                zoneIndex: zoneIndex + 1,
                selected: rest + picked,
                shuffledByZone: shuffledByZone,
                housingBySocket: housingBySocket
            )
        }
        let start = picked.isEmpty ? 0 : (pool.firstIndex { $0.socketId == picked.last!.socketId } ?? -1) + 1
        if start >= pool.count { return nil }
        for i in start..<pool.count {
            let candidate = pool[i]
            let soFar = rest + picked
            if soFar.contains(where: { $0.socketId == candidate.socketId }) { continue }
            if isIncompatible(candidate, with: soFar) { continue }
            if let found = choose(
                from: pool,
                need: need,
                picked: picked + [candidate],
                rest: rest,
                zoneIndex: zoneIndex,
                shuffledByZone: shuffledByZone,
                housingBySocket: housingBySocket
            ) {
                return found
            }
        }
        return nil
    }

    private static func isIncompatible(_ candidate: CameraSocket, with selected: [CameraSocket]) -> Bool {
        let bans = Set(candidate.incompatibleSocketIds)
        return selected.contains { bans.contains($0.socketId) || $0.incompatibleSocketIds.contains(candidate.socketId) }
    }

    private static func isLegal(_ selected: [CameraSocket], housingBySocket: [String: HousingFamily]) -> Bool {
        guard selected.count == 8 else { return false }
        let families = Set(selected.map { housingBySocket[$0.socketId]! })
        let returnVisible = selected.filter(\.returnVisible).count
        return families.count >= 4 && returnVisible >= 4
    }

    public static func fieldOrigin(socket: CameraSocket, geometry: StandardCameraGeometry) -> VecQ8 {
        offsetPoint(socket.position, geometry.fieldOriginOffset, socket.headingMilliDegrees)
    }

    public static func targetAnchor(socket: CameraSocket, geometry: StandardCameraGeometry) -> VecQ8 {
        offsetPoint(socket.position, geometry.targetAnchorOffset, socket.headingMilliDegrees)
    }

    private static func offsetPoint(_ origin: VecI, _ local: VecI, _ headingMilli: Int) -> VecQ8 {
        let heading = Cordic.headingUnit(milliDegrees: headingMilli)
        // local.x is right, local.y is forward along heading.
        let fx = Int64(heading.x)
        let fy = Int64(heading.y)
        let rx = fy
        let ry = -fx
        let x = Int64(origin.x) * Q8.scale
            + IntMath.mulDivHalfAway(rx, Int64(local.x) * Q8.scale, Int64(Cordic.q15))
            + IntMath.mulDivHalfAway(fx, Int64(local.y) * Q8.scale, Int64(Cordic.q15))
        let y = Int64(origin.y) * Q8.scale
            + IntMath.mulDivHalfAway(ry, Int64(local.x) * Q8.scale, Int64(Cordic.q15))
            + IntMath.mulDivHalfAway(fy, Int64(local.y) * Q8.scale, Int64(Cordic.q15))
        return VecQ8(x: Q8(raw: x), y: Q8(raw: y))
    }
}

public enum Detection {
    public static func sampleContacts(
        cameras: inout [SelectedCamera],
        player: PlayerBody,
        tick: UInt64,
        solids: [(id: String, box: AABB)]
    ) -> [EntityID] {
        guard !player.isCameraInvisible(tick: tick) else {
            for i in cameras.indices { cameras[i].wasDetecting = false }
            return []
        }
        var contacts: [EntityID] = []
        for i in cameras.indices {
            guard cameras[i].isDamageable else {
                cameras[i].wasDetecting = false
                continue
            }
            let detecting = Collision.pointInCone(
                origin: cameras[i].fieldOrigin,
                point: player.position,
                headingMilli: cameras[i].headingMilliDegrees,
                halfFieldMilli: cameras[i].fieldAngleMilliDegrees / 2,
                rangeUnits: cameras[i].rangeUnits
            ) && Collision.lineOfFireClear(from: cameras[i].fieldOrigin, to: player.position, solids: solids)
            cameras[i].wasDetecting = detecting
            if detecting { contacts.append(cameras[i].entityId) }
        }
        contacts.sort()
        return contacts
    }
}
