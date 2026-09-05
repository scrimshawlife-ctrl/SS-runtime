import Foundation

/// Resolves a clip's frames to delivered files, and answers honestly when a
/// frame is not backed.
///
/// `legacy-admission.md` makes partial coverage a defined state: an unbacked
/// frame ID falls back to the authored blockout, and the renderer MUST NOT
/// substitute a frame from another role, direction, or clip. This type is where
/// that rule is enforced, so no call site has to remember it.
public struct ClipFrameLibrary: Sendable {
    public struct Clip: Equatable, Sendable {
        public var clipId: String
        public var actorRole: String
        public var directions: [String]
        public var framesPerSecond: Int
        public var loop: Bool
        public var anchor: VecI
        /// Frame IDs in contract order, `directions.count` groups of equal size.
        public var frameIds: [String]

        public var framesPerDirection: Int {
            directions.isEmpty ? frameIds.count : frameIds.count / directions.count
        }
    }

    public private(set) var clips: [String: Clip]
    /// Asset ID to delivered file name, for admitted frames only.
    public private(set) var deliveredPaths: [String: String]

    public init(clips: [String: Clip], deliveredPaths: [String: String]) {
        self.clips = clips
        self.deliveredPaths = deliveredPaths
    }

    /// Loads the clip contract and pairs it with the accepted catalog entries.
    public static func bundled() throws -> ClipFrameLibrary {
        try make(
            clipJSON: SpecBundle.contract("clip-metadata-001"),
            catalog: AssetCatalog.bundled()
        )
    }

    static func make(clipJSON: Data, catalog: AssetCatalog) throws -> ClipFrameLibrary {
        guard let root = try? JSONSerialization.jsonObject(with: clipJSON) as? [String: Any],
              let rawClips = root["clips"] as? [[String: Any]]
        else {
            throw AssetCatalogError.invalidJSON
        }

        var clips: [String: Clip] = [:]
        for raw in rawClips {
            guard let clipId = raw["clipId"] as? String,
                  let actorRole = raw["actorRole"] as? String,
                  let frameIds = raw["frameIds"] as? [String],
                  let fps = raw["framesPerSecond"] as? Int,
                  let loop = raw["loop"] as? Bool
            else {
                throw AssetCatalogError.invalidJSON
            }
            let anchorRaw = raw["anchor"] as? [String: Int] ?? [:]
            clips[clipId] = Clip(
                clipId: clipId,
                actorRole: actorRole,
                directions: raw["directions"] as? [String] ?? [],
                framesPerSecond: fps,
                loop: loop,
                anchor: VecI(x: anchorRaw["x"] ?? 0, y: anchorRaw["y"] ?? 0),
                frameIds: frameIds
            )
        }

        // Only an admitted, accepted sprite contributes a file.
        var delivered: [String: String] = [:]
        for entry in catalog.entries
        where (entry.admissionDecision == .adaptedAdmitted
            || entry.admissionDecision == .originalAccepted)
            && entry.record.productionStatus == .accepted
            && entry.record.kind == .sprite
        {
            if let path = entry.record.runtimePath {
                delivered[entry.record.assetId] = path
            }
        }
        return ClipFrameLibrary(clips: clips, deliveredPaths: delivered)
    }

    // MARK: - Queries

    public func clip(_ clipId: String) -> Clip? { clips[clipId] }

    /// Frame IDs for one direction of a clip, in contract order.
    public func frameIds(clipId: String, direction: String?) -> [String] {
        guard let clip = clips[clipId] else { return [] }
        guard let direction, !clip.directions.isEmpty else { return clip.frameIds }
        guard let index = clip.directions.firstIndex(of: direction) else { return [] }
        let per = clip.framesPerDirection
        let start = index * per
        guard start + per <= clip.frameIds.count else { return [] }
        return Array(clip.frameIds[start..<(start + per)])
    }

    /// Delivered file names for one direction, or `nil` when the clip is not
    /// fully backed. All-or-nothing on purpose: a half-delivered animation would
    /// otherwise pop between real frames and gaps.
    public func deliveredFrames(clipId: String, direction: String?) -> [String]? {
        let ids = frameIds(clipId: clipId, direction: direction)
        guard !ids.isEmpty else { return nil }
        var paths: [String] = []
        paths.reserveCapacity(ids.count)
        for id in ids {
            guard let path = deliveredPaths[id] else { return nil }
            paths.append(path)
        }
        return paths
    }

    public func isBacked(clipId: String, direction: String? = nil) -> Bool {
        deliveredFrames(clipId: clipId, direction: direction) != nil
    }

    /// Backed frame count over the whole contract, for evidence and reporting.
    public var coverage: (backed: Int, total: Int) {
        let total = clips.values.reduce(0) { $0 + $1.frameIds.count }
        let backed = clips.values.reduce(0) { sum, clip in
            sum + clip.frameIds.filter { deliveredPaths[$0] != nil }.count
        }
        return (backed, total)
    }

    /// Compass direction for a facing vector, using the clip contract's letters.
    ///
    /// Authoritative headings are clockwise-positive with `+y` toward the south
    /// of the sprite sheet, so a positive `y` component faces `s`.
    public static func direction(forFacing facing: VecQ8) -> String {
        let x = facing.x.raw
        let y = facing.y.raw
        if x == 0 && y == 0 { return "s" }
        if abs(x) >= abs(y) {
            return x > 0 ? "e" : "w"
        }
        return y > 0 ? "s" : "n"
    }
}
