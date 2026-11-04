import FileSaverDartApi
import Foundation

@testable import file_saver_ffi

/// A message posted to the Dart port, decoded from its `Dart_CObject` array.
enum PortValue: Equatable {
    case null
    case int(Int64)
    case string(String)
}

/// Records the messages a `ProgressReporter` posts, standing in for
/// `FileSaver_PostCObject_DL`. Thread-safe.
final class RecordingPort {
    private let lock = NSLock()
    private var _messages: [[PortValue]] = []

    var messages: [[PortValue]] {
        lock.lock()
        defer { lock.unlock() }
        return _messages
    }

    /// The byte counts of the progress messages posted, in order.
    var progress: [Int64] {
        messages.compactMap { message in
            guard message.first == .int(1), case .int(let bytes) = message[1] else { return nil }
            return bytes
        }
    }

    func post(_ port: Int64, _ message: UnsafeMutablePointer<Dart_CObject>) -> Bool {
        let array = message.pointee.value.as_array
        let values = (0..<array.length).map { Self.decode(array.values[$0]!.pointee) }
        lock.lock()
        _messages.append(values)
        lock.unlock()
        return true
    }

    private static func decode(_ object: Dart_CObject) -> PortValue {
        switch object.type {
        case Dart_CObject_kInt64: return .int(object.value.as_int64)
        case Dart_CObject_kString: return .string(String(cString: object.value.as_string))
        default: return .null
        }
    }
}
