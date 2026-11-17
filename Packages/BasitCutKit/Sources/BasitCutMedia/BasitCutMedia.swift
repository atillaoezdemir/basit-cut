import AVFoundation
import BasitCutCore

/// Namespace for the AVFoundation layer (inspection, composition, export).
public enum BasitCutMedia {
    /// File types basit-cut offers in the import panel. Anything AVFoundation
    /// can open is accepted; unsupported files are rejected on inspection.
    public static let importableTypeIdentifiers: [String] = [
        AVFileType.mov.rawValue,
        AVFileType.mp4.rawValue,
        AVFileType.m4v.rawValue,
    ]
}
