import SpriteKit
import SurveillanceCore

/// Environment textures, loaded once and looked up by asset ID.
///
/// The App-side twin of `SpriteLibrary`: `EnvironmentLibrary` in the core owns
/// what is delivered and the all-or-nothing rule, and this owns the textures.
@MainActor
final class EnvironmentTextures {
    private let library: EnvironmentLibrary
    private var textures: [String: SKTexture] = [:]

    let coverage: (backed: Int, total: Int)

    init() {
        let library = (try? EnvironmentLibrary.bundled())
            ?? EnvironmentLibrary(declaredIds: [], deliveredPaths: [:])
        self.library = library
        coverage = library.coverage
    }

    /// Whether the ground plane can be tiled. False leaves the authored fill.
    var hasGround: Bool { library.isBacked(.ground) }

    /// Ground tile IDs in contract order, for deterministic surface choice.
    var groundIds: [String] { library.ids(in: .ground) }

    /// Art for an arena solid, or nil when the solid group is not fully backed.
    func solidTexture(solidId: String) -> SKTexture? {
        texture(assetId: EnvironmentLibrary.solidAssetId(forSolidId: solidId))
    }

    /// Whether both fog layers are delivered. False leaves the air clear,
    /// which is the honest fallback: half a fog system is a rendering fault the
    /// player would read as one.
    var hasFog: Bool { library.isBacked(.fog) }

    /// Housing art for a Camera, or nil when the camera group is not fully
    /// backed — in which case no Camera gets a housing, rather than some.
    func cameraTexture(for family: HousingFamily) -> SKTexture? {
        texture(assetId: EnvironmentLibrary.cameraAssetId(for: family))
    }

    func texture(assetId: String) -> SKTexture? {
        if let cached = textures[assetId] { return cached }
        guard let path = library.path(for: assetId),
              let url = RuntimeAssetBundle.url(forFile: path),
              let image = UIImage(contentsOfFile: url.path)
        else { return nil }
        let texture = SKTexture(image: image)
        // visual-language-001: nearestNeighbor, so authored pixels stay crisp.
        texture.filteringMode = .nearest
        textures[assetId] = texture
        return texture
    }
}
