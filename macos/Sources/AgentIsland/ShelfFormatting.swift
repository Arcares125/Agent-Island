import Foundation

private let bytesPerUnit = 1024.0
private let sizeUnits = ["KB", "MB", "GB", "TB"]
/// Above this many units the fraction stops adding information ("812 MB", not "812.4 MB").
private let wholeNumberThreshold = 100.0
private let maximumTypeBadgeLength = 5

/// Compact size for a shelf card: "946 B", "12.4 KB", "2.1 GB".
/// Locale-independent by design — `String(format:)` with no locale uses POSIX.
func shelfSizeLabel(_ byteCount: Int64) -> String {
    let bytes = Double(max(byteCount, 0))
    guard bytes >= bytesPerUnit else { return "\(Int(bytes)) B" }

    var value = bytes / bytesPerUnit
    var unitIndex = 0
    while value >= bytesPerUnit, unitIndex < sizeUnits.count - 1 {
        value /= bytesPerUnit
        unitIndex += 1
    }
    let format = value >= wholeNumberThreshold ? "%.0f %@" : "%.1f %@"
    return String(format: format, value, sizeUnits[unitIndex])
}

/// Type badge for a shelf card, taken from the extension: "PDF", "PNG", "FILE".
func shelfTypeLabel(for url: URL) -> String {
    let fileExtension = url.pathExtension.uppercased()
    guard !fileExtension.isEmpty else { return "FILE" }
    return String(fileExtension.prefix(maximumTypeBadgeLength))
}

/// Retention window spelled out for the shelf's status line: "1 HOUR", "24 HOURS".
func shelfRetentionLabel(hours: Int) -> String {
    hours == 1 ? "1 HOUR" : "\(hours) HOURS"
}

/// Retention window for the settings preset buttons, where space is tight: "4H".
func shelfRetentionShortLabel(hours: Int) -> String {
    "\(hours)H"
}
