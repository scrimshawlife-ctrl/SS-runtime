/// Presentation-only clip playback. Animation communicates authoritative state; it
/// never infers events from frame IDs or mutates simulation (animation.md §1, §11).
public struct ClipPlaybackQuery: Equatable, Sendable {
    public var actorRole: String
    public var currentClipId: String
    public var headingMilli: Int

    public init(actorRole: String, currentClipId: String, headingMilli: Int) {
        self.actorRole = actorRole
        self.currentClipId = currentClipId
        self.headingMilli = headingMilli
    }
}

public struct ClipPlayback: Equatable, Sendable {
    public var clipId: String
    public var direction: String
    public var frameIds: [String]
    public var anchor: ClipAnchor
    public var mirrored: Bool
    public var interrupted: Bool
    public var eventAligned: Bool
    public var fieldOffClipId: String?
    public var housingTransformLocked: Bool
}

public enum ClipAlignment {
    /// Names from `animation.md` state machines that may cancel a clip before
    /// that actor has a dedicated clip in the catalog (T601–T603).
    public static let interruptTokens: Set<String> = ["hurt", "defeat", "dodge"]

    /// Four authored facings. Angles are clockwise from +X (`civic-seam-arena-003`).
    public static func cardinalDirection(headingMilli: Int) -> String {
        let sector = ((MilliDeg.normalize(headingMilli) + 45_000) / 90_000) % 4
        switch sector {
        case 0: return "e"
        case 1: return "s"
        case 2: return "w"
        default: return "n"
        }
    }

    public static func canInterrupt(current: ClipRecord, incoming: ClipRecord) -> Bool {
        if current.isTerminal { return false }
        return current.cancelWindows.contains(incoming.clipId)
            || current.cancelWindows.contains(incoming.state)
    }

    /// Telegraph clips yield to the matching commit on the event tick (animation.md §2).
    public static func alignsCommit(current: ClipRecord, incoming: ClipRecord) -> Bool {
        current.blendOrTransition == "telegraph"
            && incoming.blendOrTransition == "cutOnEvent"
            && current.actorRole == incoming.actorRole
            && incoming.eventType != nil
    }

    public static func clip(
        matching event: AuthoritativeEvent,
        role: String,
        catalog: ClipCatalog
    ) -> ClipRecord? {
        let marked = catalog.clips.filter { $0.actorRole == role && $0.eventType == event.type }
        if marked.isEmpty { return nil }
        if marked.count == 1 { return marked[0] }
        if event.type == .cameraIntegrityChanged {
            if payloadInt(event, "after") == 1 {
                return catalog.clipsById["camera_critical_enter"]
            }
            return catalog.clipsById["camera_hit"]
        }
        if event.type == .cameraDestroyed {
            return catalog.clipsById["camera_destroy"]
        }
        return marked[0]
    }

    /// Selects the next clip from declared markers and cancel windows. Eight-direction
    /// movement projects onto the four authored facings; west is `_w_`, not a flip of east.
    public static func project(
        query: ClipPlaybackQuery,
        events: [AuthoritativeEvent],
        catalog: ClipCatalog
    ) -> ClipPlayback {
        let fallback = catalog.clips.first { $0.actorRole == query.actorRole }
        guard var clip = catalog.clipsById[query.currentClipId] ?? fallback else {
            return ClipPlayback(
                clipId: query.currentClipId,
                direction: "",
                frameIds: [],
                anchor: ClipAnchor(x: 0, y: 0),
                mirrored: false,
                interrupted: false,
                eventAligned: false,
                fieldOffClipId: nil,
                housingTransformLocked: query.actorRole == "camera"
            )
        }
        var interrupted = false
        var eventAligned = false
        var fieldOff: String?

        for event in events {
            if event.type == .cameraDestroyed, query.actorRole == "camera" {
                fieldOff = CameraPresentation.clipId(for: .fieldOff)
                eventAligned = true
            }
            guard let incoming = Self.clip(matching: event, role: query.actorRole, catalog: catalog) else {
                continue
            }
            if incoming.clipId == clip.clipId {
                eventAligned = incoming.eventType != nil
                continue
            }
            if canInterrupt(current: clip, incoming: incoming) {
                clip = incoming
                interrupted = true
                eventAligned = incoming.eventType != nil
            } else if alignsCommit(current: clip, incoming: incoming) {
                clip = incoming
                eventAligned = true
            }
        }

        let direction = clip.directions.isEmpty ? "" : cardinalDirection(headingMilli: query.headingMilli)
        return ClipPlayback(
            clipId: clip.clipId,
            direction: direction,
            frameIds: clip.frameIds(forDirection: direction),
            anchor: clip.anchor,
            mirrored: false,
            interrupted: interrupted,
            eventAligned: eventAligned,
            fieldOffClipId: fieldOff,
            housingTransformLocked: query.actorRole == "camera"
        )
    }

    private static func payloadInt(_ event: AuthoritativeEvent, _ key: String) -> Int64? {
        if case .integer(let value)? = event.payload[key] { return value }
        return nil
    }
}
