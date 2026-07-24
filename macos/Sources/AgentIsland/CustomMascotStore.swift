import AppKit
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// User-supplied replacement artwork for the mascots — one image per provider.
///
/// Each provider keeps its own identity: a Claude session still draws the Claude
/// mascot, it is just *your* Claude mascot once you upload one. Providers without
/// an upload fall back to the bundled sprite, so the shelf can be half-customised.
@MainActor
final class CustomMascotStore: ObservableObject {
    /// Big enough for any sprite or logo, small enough that a stray 200 MB PSD is
    /// rejected rather than decoded.
    nonisolated static let maximumFileSize: Int64 = 8 * 1024 * 1024

    /// Longest edge kept on disk. Mascots draw at 16–52pt, but uploads arrive at
    /// whatever the user exported: a 4800×3600 photo decodes to ~66 MB *per image*
    /// to fill a 20pt box, because the full bitmap is rasterised regardless of the
    /// destination size. Resampling once at import caps that at about 1 MB.
    nonisolated static let maximumStoredEdge = 512

    /// Allowlist rather than "anything NSImage might open": the picker and the
    /// import path agree on exactly these, and anything else is refused by name.
    ///
    /// Every entry can carry an alpha channel. JPEG and BMP are deliberately absent
    /// — they have no transparency at all, so a mascot saved as either would paint
    /// its background as a solid block behind the sprite in the notch.
    nonisolated static let allowedContentTypes: [UTType] = [
        .png, .gif, .tiff, .webP, .heic, .heif
    ]

    /// Bumped on every import or reset. Views key their image cache on it, so a
    /// replaced mascot redraws instead of serving the previous sprite.
    @Published private(set) var revision = 0
    @Published private(set) var statusMessage: String?
    @Published private(set) var customURLs: [AgentProvider: URL] = [:]

    private let rootDirectory: URL

    init(fileManager: FileManager = .default, rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory
            ?? fileManager
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent("com.xiao.agentisland", isDirectory: true)
                .appendingPathComponent("mascots", isDirectory: true)
        prepareRootDirectory(fileManager: fileManager)
        reload(fileManager: fileManager)
    }

    func customImageURL(for provider: AgentProvider) -> URL? {
        customURLs[provider]
    }

    func hasCustomImage(for provider: AgentProvider) -> Bool {
        customURLs[provider] != nil
    }

    /// Copy `url` in as `provider`'s mascot. Returns whether it was accepted.
    @discardableResult
    func importImage(from url: URL, for provider: AgentProvider) -> Bool {
        switch Self.decodeValidImage(at: url) {
        case .failure(let message):
            statusMessage = message
            return false
        case .success(let image):
            guard let encoded = Self.encodePNG(from: image) else {
                statusMessage = "IMAGE COULD NOT BE CONVERTED"
                return false
            }
            do {
                prepareRootDirectory()
                try encoded.data.write(to: destinationURL(for: provider), options: .atomic)
            } catch {
                statusMessage = "MASCOT COULD NOT BE SAVED"
                return false
            }
            reload()
            // An allowed format can still hold a flattened image. Saying so beats
            // letting the user wonder why their mascot arrived in a box.
            let name = provider.displayName.uppercased()
            statusMessage = encoded.hasAlpha
                ? "\(name) MASCOT UPDATED"
                : "\(name) UPDATED · NO TRANSPARENCY, SO IT DRAWS ON A SOLID BACKDROP"
            return true
        }
    }

    /// Drop the upload and go back to the bundled sprite.
    func reset(_ provider: AgentProvider) {
        guard hasCustomImage(for: provider) else { return }
        try? FileManager.default.removeItem(at: destinationURL(for: provider))
        reload()
        statusMessage = "\(provider.displayName.uppercased()) MASCOT RESET"
    }

    // MARK: Validation

    private enum DecodeResult {
        case success(NSImage)
        case failure(String)
    }

    /// Read the file defensively: it comes from an open panel, so it can be any
    /// size, a symlink, or not an image at all despite its extension.
    nonisolated private static func decodeValidImage(at url: URL) -> DecodeResult {
        let didScope = url.startAccessingSecurityScopedResource()
        defer { if didScope { url.stopAccessingSecurityScopedResource() } }

        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentTypeKey
        ]) else {
            return .failure("FILE COULD NOT BE READ")
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            return .failure("REGULAR IMAGE FILES ONLY")
        }
        guard let contentType = values.contentType,
              allowedContentTypes.contains(where: contentType.conforms(to:)) else {
            return .failure("PNG, JPEG, GIF, TIFF, BMP, WEBP OR HEIC ONLY")
        }
        guard let fileSize = values.fileSize, Int64(fileSize) <= maximumFileSize else {
            return .failure("IMAGE EXCEEDS 8 MB LIMIT")
        }
        // Decoding is the real test — an allowed extension proves nothing.
        guard let data = try? Data(contentsOf: url),
              let image = NSImage(data: data),
              image.size.width > 0, image.size.height > 0 else {
            return .failure("IMAGE COULD NOT BE DECODED")
        }
        return .success(image)
    }

    /// Re-encode rather than copying the original bytes: it normalises every
    /// accepted format to one the sprite pipeline can always read, and means no
    /// user-supplied container is kept on disk verbatim.
    ///
    /// Also reports whether the artwork actually carries transparency, which is
    /// what decides between a mascot and a mascot-in-a-rectangle.
    nonisolated private static func encodePNG(
        from image: NSImage
    ) -> (data: Data, hasAlpha: Bool)? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let sized = downscaledToStorageLimit(cgImage) ?? cgImage
        let rep = NSBitmapImageRep(cgImage: sized)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return (data, rep.hasAlpha && Self.containsTransparentPixel(sized))
    }

    /// Fit inside `maximumStoredEdge`, preserving aspect ratio and alpha.
    ///
    /// Returns nil when the artwork already fits, so a hand-made sprite is stored
    /// exactly as drawn and never resampled. Unlike the bundled sprites this does
    /// not pixelate — the user's art keeps its own look, it just stops being
    /// megapixels wide.
    nonisolated private static func downscaledToStorageLimit(_ image: CGImage) -> CGImage? {
        let longestEdge = max(image.width, image.height)
        guard longestEdge > maximumStoredEdge else { return nil }

        let scale = Double(maximumStoredEdge) / Double(longestEdge)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// An alpha *channel* is not the same as an image that uses it — a flattened
    /// export keeps the channel and fills it with opaque. Sampling on a grid keeps
    /// this proportional to the image instead of scanning every pixel.
    nonisolated private static func containsTransparentPixel(_ cgImage: CGImage) -> Bool {
        let samplesPerAxis = 32
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return false }

        var pixel: UInt8 = 0
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { return false }

        for row in 0..<samplesPerAxis {
            for column in 0..<samplesPerAxis {
                let x = width * column / samplesPerAxis
                let y = height * row / samplesPerAxis
                pixel = 0
                context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
                context.draw(
                    cgImage,
                    in: CGRect(x: -CGFloat(x), y: -CGFloat(height - 1 - y),
                               width: CGFloat(width), height: CGFloat(height))
                )
                if pixel < 250 { return true }
            }
        }
        return false
    }

    // MARK: Storage

    private func destinationURL(for provider: AgentProvider) -> URL {
        rootDirectory.appendingPathComponent("\(provider.rawValue).png", isDirectory: false)
    }

    private func prepareRootDirectory(fileManager: FileManager = .default) {
        try? fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func reload(fileManager: FileManager = .default) {
        var found: [AgentProvider: URL] = [:]
        for provider in AgentProvider.allCases {
            let url = destinationURL(for: provider)
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
               values.isRegularFile == true,
               values.isSymbolicLink != true {
                Self.shrinkStoredImageIfOversized(at: url)
                found[provider] = url
            }
        }
        customURLs = found
        revision &+= 1
    }

    /// Bring artwork saved before the storage limit existed down to size.
    ///
    /// Without this the fix would only apply to the *next* upload, leaving anyone
    /// who already uploaded a photo paying the full decode cost forever. Reads the
    /// header only, so the common case (already small) costs one property fetch.
    nonisolated private static func shrinkStoredImageIfOversized(at url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) > maximumStoredEdge,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let shrunk = downscaledToStorageLimit(image),
              let data = NSBitmapImageRep(cgImage: shrunk).representation(using: .png, properties: [:])
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
