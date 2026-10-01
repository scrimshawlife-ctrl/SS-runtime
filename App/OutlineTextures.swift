import CoreGraphics
import SpriteKit
import SurveillanceCore

/// D-094 faction outlines as pre-rendered textures (`animation.md` § 8b).
///
/// For each source frame an actor shows, this builds once, on the CPU, a
/// texture holding only a one-pixel ring around the frame's opaque pixels:
/// cool white and unbroken for the Player, warm red-orange and dashed for
/// enemies. The ring is padded one pixel outside the frame so it is never
/// clipped by the frame's edge. Drawing it is one extra sprite per actor and
/// no per-frame filter work; the cache is keyed by the source texture, which
/// `SpriteLibrary` loads once and keeps.
@MainActor
final class OutlineTextures {
    struct Entry {
        let texture: SKTexture
        /// Pixels of padding on every side of the source frame.
        let pad: Int
    }

    /// Outline thickness, in source pixels. Actor frames are authored at one
    /// pixel per world unit, and one world unit is about one screen point at
    /// the D-094 framing, so one pixel is the specified one-point outline.
    nonisolated static let thicknessPixels = 1
    /// Alpha at or above which a source pixel counts as part of the body.
    nonisolated static let opaqueThreshold: UInt8 = 64
    /// Largest frame this will outline; anything bigger is not an actor frame.
    nonisolated static let maxPixels = 256 * 256

    private struct Key: Hashable {
        let texture: ObjectIdentifier
        let faction: ActorContrast.Faction
    }

    private var cache: [Key: Entry] = [:]
    /// Frames that could not be outlined, so they are not retried every frame.
    private var failed: Set<Key> = []
    /// Keeps each keyed source alive, so its identifier cannot be reused.
    private var sources: [ObjectIdentifier: SKTexture] = [:]

    var count: Int { cache.count }

    func outline(for texture: SKTexture, faction: ActorContrast.Faction) -> Entry? {
        let key = Key(texture: ObjectIdentifier(texture), faction: faction)
        if let hit = cache[key] { return hit }
        guard !failed.contains(key) else { return nil }
        sources[key.texture] = texture
        guard let made = Self.make(from: texture.cgImage(), faction: faction) else {
            failed.insert(key)
            return nil
        }
        cache[key] = made
        return made
    }

    /// The outline ring for `image`, or nil when it cannot be read.
    nonisolated static func make(from image: CGImage, faction: ActorContrast.Faction) -> Entry? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width * height <= maxPixels else { return nil }
        guard let source = rgba(image) else { return nil }
        let pad = thicknessPixels
        let outWidth = width + 2 * pad
        let outHeight = height + 2 * pad
        let colour = ActorContrast.outlineColour(faction)
        let r = UInt8((colour.red * 255).rounded())
        let g = UInt8((colour.green * 255).rounded())
        let b = UInt8((colour.blue * 255).rounded())

        func opaque(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            return source[(y * width + x) * 4 + 3] >= opaqueThreshold
        }

        var out = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        for oy in 0..<outHeight {
            for ox in 0..<outWidth {
                let sx = ox - pad
                let sy = oy - pad
                if opaque(sx, sy) { continue }
                var near = false
                search: for dy in -pad...pad {
                    for dx in -pad...pad where opaque(sx + dx, sy + dy) {
                        near = true
                        break search
                    }
                }
                guard near, ActorContrast.outlinePixelOn(x: ox, y: oy, faction: faction) else { continue }
                let index = (oy * outWidth + ox) * 4
                out[index] = r
                out[index + 1] = g
                out[index + 2] = b
                out[index + 3] = 255
            }
        }
        guard let texture = texture(pixels: out, width: outWidth, height: outHeight, smooth: false) else { return nil }
        return Entry(texture: texture, pad: pad)
    }

    /// Premultiplied RGBA bytes, rows top first.
    nonisolated static func rgba(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    /// A texture from premultiplied RGBA bytes laid out like `rgba(_:)`.
    nonisolated static func texture(pixels: [UInt8], width: Int, height: Int, smooth: Bool) -> SKTexture? {
        var bytes = pixels
        let image: CGImage? = bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        guard let image else { return nil }
        let texture = SKTexture(cgImage: image)
        // Actor art is nearest-neighbour (visual-language-001); the outline
        // matches it. The shadow is soft, so it filters linearly.
        texture.filteringMode = smooth ? .linear : .nearest
        return texture
    }
}
