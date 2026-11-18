import AVFoundation

/// Metadata that matters for an archive, copied from the first clip into the
/// exported file so it doesn't look "recorded today".
public enum ArchiveMetadata {
    /// Recording date, location and camera. Identifiers that tie a file to one
    /// specific capture (e.g. the Live Photo content identifier) are left out.
    static let preservedIdentifiers: Set<AVMetadataIdentifier> = [
        .commonIdentifierCreationDate,
        .quickTimeMetadataCreationDate,
        .quickTimeUserDataCreationDate,
        .commonIdentifierLocation,
        .quickTimeMetadataLocationISO6709,
        .quickTimeUserDataLocationISO6709,
        AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.location.accuracy.horizontal"),
        .commonIdentifierMake,
        .commonIdentifierModel,
        .commonIdentifierSoftware,
        .quickTimeMetadataMake,
        .quickTimeMetadataModel,
        .quickTimeMetadataSoftware,
    ]

    /// The preserved metadata of `asset` as standalone items for a writer or
    /// export session. If the asset has no creation date but `fallbackCreationDate`
    /// is known, a creation date item is added.
    public static func items(from asset: AVAsset, fallbackCreationDate: Date?) async -> [AVMetadataItem] {
        var result: [AVMetadataItem] = []
        let all = (try? await asset.load(.metadata)) ?? []
        for item in all {
            guard let identifier = item.identifier, preservedIdentifiers.contains(identifier),
                  let value = try? await item.load(.value)
            else { continue }
            let copy = AVMutableMetadataItem()
            copy.identifier = identifier
            copy.value = value
            copy.dataType = item.dataType
            copy.extendedLanguageTag = item.extendedLanguageTag
            result.append(copy)
        }

        let hasDate = result.contains { creationDateIdentifiers.contains($0.identifier ?? .init(rawValue: "")) }
        if !hasDate, let fallbackCreationDate {
            result.append(creationDateItem(fallbackCreationDate))
        }
        return result
    }

    static let creationDateIdentifiers: Set<AVMetadataIdentifier> = [
        .commonIdentifierCreationDate, .quickTimeMetadataCreationDate, .quickTimeUserDataCreationDate,
    ]

    static func creationDateItem(_ date: Date) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataCreationDate
        item.value = ISO8601DateFormatter().string(from: date) as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }
}
