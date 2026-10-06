import Foundation

/// Validates file types for saving operations.
///
/// Note: This library is a file saver, not a media player.
/// We only validate that the MIME type category matches the expected type.
/// The developer is responsible for choosing the appropriate format.
/// Files are written as raw bytes - no encoding/decoding is performed.
enum FormatValidator {

    /// Validates image format.
    /// Only checks that the MIME type is an image type.
    static func validateImageFormat(_ fileType: FileType) throws {
        guard fileType.category == .image else {
            throw FileSaverError.platformError("Expected image MIME type")
        }
    }

    /// Validates video format.
    /// Only checks that the MIME type is a video type.
    static func validateVideoFormat(_ fileType: FileType) throws {
        guard fileType.category == .video else {
            throw FileSaverError.platformError("Expected video MIME type")
        }
    }

    /// Validates audio format.
    /// Only checks that the MIME type is an audio type.
    static func validateAudioFormat(_ fileType: FileType) throws {
        guard fileType.category == .audio else {
            throw FileSaverError.platformError("Expected audio MIME type")
        }
    }
}
