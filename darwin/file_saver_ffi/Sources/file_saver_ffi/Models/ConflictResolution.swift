import Foundation

// ConflictResolution itself is generated, in Contracts.g.swift.

extension ConflictResolution {
    /// The value Dart sent as `value`, or `.autoRename` for an unknown one.
    static func fromInt(_ value: Int) -> ConflictResolution {
        return ConflictResolution(rawValue: value) ?? .autoRename
    }
}
