import Foundation

enum ConflictResolution: Int {
    case autoRename = 0
    case overwrite = 1
    case fail = 2
    case skip = 3

    static func fromInt(_ value: Int) -> ConflictResolution {
        return ConflictResolution(rawValue: value) ?? .autoRename
    }
}
