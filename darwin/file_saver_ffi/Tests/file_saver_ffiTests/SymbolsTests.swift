import Foundation
import ObjectiveC
import XCTest

@testable import file_saver_ffi

/// How Dart finds the functions of file_saver_ffi.h: through the Objective-C
/// class `FileSaverFFISymbols`, as their names are stripped from an archived
/// app. These tests look it up the way Dart does
/// (lib/src/platforms/darwin/darwin_symbols.dart).
final class SymbolsTests: XCTestCase {
    private typealias AddressOf =
        @convention(c) (AnyClass, Selector, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?

    /// `+[FileSaverFFISymbols addressOf:]`, found by name in the runtime.
    private func addressOf(_ name: String?) throws -> UnsafeMutableRawPointer? {
        let cls = try XCTUnwrap(NSClassFromString("FileSaverFFISymbols"))
        let selector = NSSelectorFromString("addressOf:")
        let method = try XCTUnwrap(class_getClassMethod(cls, selector))
        let function = unsafeBitCast(method_getImplementation(method), to: AddressOf.self)
        guard let name else { return function(cls, selector, nil) }
        return name.withCString { function(cls, selector, $0) }
    }

    /// The functions the header declares.
    private func declaredFunctions() throws -> [String] {
        let header = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Sources/file_saver_ffi/FFI/file_saver_ffi.h")
            .standardized
        let source = try String(contentsOf: header, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"^\w[\w ]*?\**\s*\b(file_saver_\w+)\("#, options: .anchorsMatchLines)
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).map {
            String(source[Range($0.range(at: 1), in: source)!])
        }
    }

    func testGivesTheAddressOfEveryFunctionTheHeaderDeclares() throws {
        let functions = try declaredFunctions()
        XCTAssertEqual(functions.count, 16)
        // RTLD_DEFAULT: the test bundle isn't stripped.
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        for name in functions {
            let address = try addressOf(name)
            XCTAssertNotNil(address, name)
            XCTAssertEqual(address, dlsym(rtldDefault, name), name)
        }
    }

    func testGivesNothingForAnotherName() throws {
        XCTAssertNil(try addressOf("file_saver_unknown"))
        XCTAssertNil(try addressOf("file_saver"))
        XCTAssertNil(try addressOf(nil))
    }
}
