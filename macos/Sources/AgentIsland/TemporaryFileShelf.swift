import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

struct TemporaryFileShelfItem: Identifiable, Equatable {
    let id: String
    let url: URL
    let containerURL: URL
    let createdAt: Date
    let expiresAt: Date
    let byteCount: Int64

    var displayName: String { url.lastPathComponent }
}

@MainActor
final class TemporaryFileShelf: ObservableObject {
    static let maximumItemCount = 9
    /// Retention windows offered in Settings. A day is the ceiling: these are
    /// plaintext copies parked in a temp directory, so "temporary" has to stay
    /// meaningful even at the most generous setting.
    nonisolated static let retentionHourPresets = [1, 4, 12, 24]
    nonisolated static let defaultRetentionHours = 1
    nonisolated static let maximumFileSize: Int64 = 1_073_741_824

    /// The stored value reaches us from UserDefaults, which the user can edit by
    /// hand, so it is matched against the presets rather than merely range-checked.
    nonisolated static func clampRetentionHours(_ hours: Int) -> Int {
        retentionHourPresets.contains(hours) ? hours : defaultRetentionHours
    }

    @Published private(set) var items: [TemporaryFileShelfItem] = []
    @Published private(set) var statusMessage: String
    @Published private(set) var retentionHours: Int

    var lifetime: TimeInterval { TimeInterval(retentionHours) * 60 * 60 }

    private var idleStatusMessage: String {
        "DROP FILES HERE · COPIES EXPIRE IN \(shelfRetentionLabel(hours: retentionHours))"
    }

    private let rootDirectory: URL
    private let workQueue = DispatchQueue(
        label: "com.xiao.agentisland.temporary-file-shelf",
        qos: .utility
    )
    private var pendingImportCount = 0
    private var expirationTimer: Timer?

    init(
        fileManager: FileManager = .default,
        rootDirectory: URL? = nil,
        retentionHours: Int = TemporaryFileShelf.defaultRetentionHours
    ) {
        let clamped = Self.clampRetentionHours(retentionHours)
        self.retentionHours = clamped
        self.statusMessage =
            "DROP FILES HERE · COPIES EXPIRE IN \(shelfRetentionLabel(hours: clamped))"
        self.rootDirectory = rootDirectory
            ?? fileManager.temporaryDirectory
                .appendingPathComponent("com.xiao.agentisland", isDirectory: true)
                .appendingPathComponent("file-shelf", isDirectory: true)
        prepareRootDirectory(fileManager: fileManager)
        reloadItems(fileManager: fileManager)
    }

    /// Deadlines are derived from each copy's creation time, so a new window
    /// applies to files already on the shelf as well as future drops. Shortening
    /// it therefore sweeps anything that is already past the new deadline.
    func setRetentionHours(_ hours: Int) {
        let clamped = Self.clampRetentionHours(hours)
        guard clamped != retentionHours else { return }
        retentionHours = clamped
        reloadItems()
        statusMessage = items.isEmpty
            ? idleStatusMessage
            : "COPIES NOW EXPIRE IN \(shelfRetentionLabel(hours: clamped))"
    }

    @discardableResult
    func accept(_ urls: [URL]) -> Bool {
        let candidates = urls.filter(\.isFileURL)
        guard !candidates.isEmpty else {
            statusMessage = "FILES ONLY"
            return false
        }

        let availableSlots = max(
            Self.maximumItemCount - items.count - pendingImportCount,
            0
        )
        guard availableSlots > 0 else {
            statusMessage = "SHELF FULL · REMOVE AN ITEM FIRST"
            return true
        }

        let acceptedURLs = Array(candidates.prefix(availableSlots))
        pendingImportCount += acceptedURLs.count
        statusMessage = "COPYING \(acceptedURLs.count) FILE\(acceptedURLs.count == 1 ? "" : "S")…"

        let destinationRoot = rootDirectory
        workQueue.async { [weak self] in
            let results = acceptedURLs.map {
                Self.copyTemporaryFile(from: $0, into: destinationRoot)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingImportCount = max(
                    self.pendingImportCount - acceptedURLs.count,
                    0
                )
                self.reloadItems()

                let copiedCount = results.filter(\.wasCopied).count
                if copiedCount == acceptedURLs.count {
                    self.statusMessage = "\(copiedCount) FILE\(copiedCount == 1 ? "" : "S") READY · CLICK TO COPY"
                } else if let failure = results.compactMap(\.failureMessage).first {
                    self.statusMessage = failure
                } else {
                    self.statusMessage = "SOME FILES COULD NOT BE COPIED"
                }
            }
        }
        return true
    }

    @discardableResult
    func accept(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else {
            statusMessage = "FILES ONLY"
            return false
        }

        let availableSlots = max(
            Self.maximumItemCount - items.count - pendingImportCount,
            0
        )
        guard availableSlots > 0 else {
            statusMessage = "SHELF FULL · REMOVE AN ITEM FIRST"
            return true
        }

        let acceptedProviders = Array(fileProviders.prefix(availableSlots))
        statusMessage = "RECEIVING \(acceptedProviders.count) FILE\(acceptedProviders.count == 1 ? "" : "S")…"
        for provider in acceptedProviders {
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { [weak self] item, _ in
                let fileURL = Self.fileURL(from: item)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if let fileURL {
                        _ = self.accept([fileURL])
                    } else {
                        self.statusMessage = "FILE DROP COULD NOT BE READ"
                    }
                }
            }
        }
        return true
    }

    func copyToPasteboard(_ item: TemporaryFileShelfItem) {
        guard FileManager.default.fileExists(atPath: item.url.path) else {
            reloadItems()
            statusMessage = "FILE EXPIRED OR MOVED"
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects([item.url as NSURL]) {
            statusMessage = "COPIED \(item.displayName)"
        } else {
            statusMessage = "COULD NOT COPY FILE"
        }
    }

    func remove(_ item: TemporaryFileShelfItem) {
        items.removeAll { $0.id == item.id }
        statusMessage = items.isEmpty ? idleStatusMessage : "TEMPORARY COPY REMOVED"
        scheduleExpirationTimer()

        let containerURL = item.containerURL
        workQueue.async {
            try? FileManager.default.removeItem(at: containerURL)
        }
    }

    func shutdown() {
        expirationTimer?.invalidate()
        expirationTimer = nil
        items = []

        // A normal quit clears the shelf immediately. A forced termination may
        // leave copies behind, so init also sweeps anything past its deadline.
        let destinationRoot = rootDirectory
        workQueue.sync {
            try? FileManager.default.removeItem(at: destinationRoot)
        }
    }

    private func prepareRootDirectory(fileManager: FileManager = .default) {
        do {
            if let values = try? rootDirectory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ]), values.isDirectory != true || values.isSymbolicLink == true {
                try fileManager.removeItem(at: rootDirectory)
            }
            try fileManager.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: rootDirectory.path
            )
        } catch {
            statusMessage = "TEMPORARY SHELF IS UNAVAILABLE"
        }
    }

    private func reloadItems(fileManager: FileManager = .default) {
        prepareRootDirectory(fileManager: fileManager)
        let now = Date()
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isDirectoryKey,
            .isSymbolicLinkKey
        ]
        let containers = (try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )) ?? []

        var discovered: [TemporaryFileShelfItem] = []
        for containerURL in containers {
            guard let values = try? containerURL.resourceValues(forKeys: resourceKeys),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else {
                try? fileManager.removeItem(at: containerURL)
                continue
            }

            let createdAt = values.contentModificationDate ?? .distantPast
            let expiresAt = createdAt.addingTimeInterval(lifetime)
            guard expiresAt > now else {
                try? fileManager.removeItem(at: containerURL)
                continue
            }

            let files = (try? fileManager.contentsOfDirectory(
                at: containerURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            guard let fileURL = files.first(where: { candidate in
                guard let fileValues = try? candidate.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                ) else { return false }
                return fileValues.isRegularFile == true && fileValues.isSymbolicLink != true
            }) else {
                try? fileManager.removeItem(at: containerURL)
                continue
            }

            let byteCount = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            discovered.append(
                TemporaryFileShelfItem(
                    id: containerURL.lastPathComponent,
                    url: fileURL,
                    containerURL: containerURL,
                    createdAt: createdAt,
                    expiresAt: expiresAt,
                    byteCount: Int64(byteCount)
                )
            )
        }

        discovered.sort { $0.createdAt > $1.createdAt }
        if discovered.count > Self.maximumItemCount {
            for overflowItem in discovered.dropFirst(Self.maximumItemCount) {
                try? fileManager.removeItem(at: overflowItem.containerURL)
            }
            discovered = Array(discovered.prefix(Self.maximumItemCount))
        }
        items = discovered
        scheduleExpirationTimer()
    }

    private func scheduleExpirationTimer() {
        expirationTimer?.invalidate()
        expirationTimer = nil
        guard let nextExpiration = items.map(\.expiresAt).min() else { return }

        let interval = max(nextExpiration.timeIntervalSinceNow, 0.1)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reloadItems()
                self.statusMessage = self.items.isEmpty
                    ? self.idleStatusMessage
                    : "EXPIRED FILES REMOVED"
            }
        }
        timer.tolerance = min(2, interval * 0.05)
        expirationTimer = timer
    }

    private struct CopyResult {
        let wasCopied: Bool
        let failureMessage: String?
    }

    nonisolated private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url.isFileURL ? url : nil
        }
        if let url = item as? NSURL,
           let bridgedURL = url as URL? {
            return bridgedURL.isFileURL ? bridgedURL : nil
        }
        if let data = item as? Data,
           let url = URL(dataRepresentation: data, relativeTo: nil) {
            return url.isFileURL ? url : nil
        }
        if let text = item as? String,
           let url = URL(string: text) {
            return url.isFileURL ? url : nil
        }
        return nil
    }

    nonisolated private static func copyTemporaryFile(
        from sourceURL: URL,
        into rootDirectory: URL
    ) -> CopyResult {
        let fileManager = FileManager.default
        let didAccessSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let values = try sourceURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                return CopyResult(wasCopied: false, failureMessage: "REGULAR FILES ONLY")
            }
            guard let fileSize = values.fileSize else {
                return CopyResult(wasCopied: false, failureMessage: "FILE SIZE IS UNAVAILABLE")
            }
            if Int64(fileSize) > maximumFileSize {
                return CopyResult(wasCopied: false, failureMessage: "FILE EXCEEDS 1 GB LIMIT")
            }

            if let rootValues = try? rootDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]),
               rootValues.isSymbolicLink == true {
                return CopyResult(wasCopied: false, failureMessage: "TEMPORARY SHELF IS UNAVAILABLE")
            }

            let fileSystemPath = rootDirectory.deletingLastPathComponent().path
            if let attributes = try? fileManager.attributesOfFileSystem(forPath: fileSystemPath),
               let freeBytes = (attributes[.systemFreeSize] as? NSNumber)?.int64Value,
               freeBytes < Int64(fileSize) + 268_435_456 {
                return CopyResult(wasCopied: false, failureMessage: "NOT ENOUGH FREE DISK SPACE")
            }

            try fileManager.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: rootDirectory.path
            )
            let containerURL = rootDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(
                at: containerURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )

            do {
                let fileName = sourceURL.lastPathComponent.isEmpty
                    ? "Temporary File"
                    : sourceURL.lastPathComponent
                let destinationURL = containerURL.appendingPathComponent(fileName)
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                let copiedSize = try destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard let copiedSize, Int64(copiedSize) <= maximumFileSize else {
                    try fileManager.removeItem(at: containerURL)
                    return CopyResult(wasCopied: false, failureMessage: "COPIED FILE EXCEEDS 1 GB LIMIT")
                }
                try fileManager.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: containerURL.path
                )
                return CopyResult(wasCopied: true, failureMessage: nil)
            } catch {
                try? fileManager.removeItem(at: containerURL)
                throw error
            }
        } catch {
            return CopyResult(wasCopied: false, failureMessage: "FILE COULD NOT BE COPIED")
        }
    }
}
