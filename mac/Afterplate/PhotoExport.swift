import Photos
import AppKit
import UniformTypeIdentifiers

/// `-AfterplateExportPhotos <folder>` writes every scored photo, at the 640px
/// the classifiers see, as a JPEG named after its asset, so another image
/// model can be compared with the app's outside the app (the Photos library
/// is closed to anything but an app with Photos access). Local renditions
/// only; nothing is fetched from iCloud. Developer use; never runs otherwise.
enum PhotoExport {
    static func runIfAsked(_ identifiers: [String]) {
        guard let path = UserDefaults.standard.string(forKey: "AfterplateExportPhotos"), !path.isEmpty else { return }
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task.detached(priority: .utility) {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            var list: [PHAsset] = []
            assets.enumerateObjects { asset, _, _ in list.append(asset) }
            print("[PhotoExport] \(list.count) of \(identifiers.count) photos to \(folder.path)")
            var written = 0
            await withTaskGroup(of: Bool.self) { group in
                var next = 0
                func enqueue() {
                    guard next < list.count else { return }
                    let asset = list[next]; next += 1
                    group.addTask { await write(asset, to: folder) }
                }
                for _ in 0..<4 { enqueue() }
                for await ok in group {
                    if ok { written += 1 }
                    if written % 500 == 0 { print("[PhotoExport] \(written) written") }
                    enqueue()
                }
            }
            print("[PhotoExport] done: \(written) written")
        }
    }

    private static func write(_ asset: PHAsset, to folder: URL) async -> Bool {
        let name = asset.localIdentifier.replacingOccurrences(of: "/", with: "_") + ".jpg"
        let url = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return true }
        let image: CGImage? = await withCheckedContinuation { continuation in
            // The same request PhotoLibrary.classificationImage makes.
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 640, height: 640), contentMode: .aspectFit, options: options
            ) { image, _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
        guard let image,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
