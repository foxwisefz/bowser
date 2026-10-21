import Foundation
import CoreFoundation

/// WebKit can return reference graphs, including cycles. Never recursively
/// bridge its NSArray/NSDictionary values into Swift collections before checking
/// their identity and bounds (bowser-browser-06gz).
enum JavaScriptResult {
    static let maximumDepth = 64
    static let maximumValues = 100_000

    enum ConversionError: String, LocalizedError {
        case circular = "JavaScript result contains a circular reference. Return a plain object with only the fields you need."
        case depth = "JavaScript result exceeds 64 levels of nesting. Return a shallower result."
        case size = "JavaScript result exceeds 100,000 values. Return a smaller batch."
        case nonFinite = "JavaScript result contains NaN or Infinity, which cannot be sent as JSON."
        case unsupported = "JavaScript result contains a value that cannot be sent as JSON. Return plain objects, arrays, strings, finite numbers, booleans, or null."

        var errorDescription: String? { rawValue }
    }

    static func convert(_ value: Any?) throws -> Any {
        guard let value else { return NSNull() }
        var walker = Walker()
        return try walker.convert(value as AnyObject, depth: 0)
    }

    private struct Walker {
        var ancestors = Set<ObjectIdentifier>()
        var remaining = maximumValues

        mutating func convert(_ value: AnyObject, depth: Int) throws -> Any {
            guard depth <= maximumDepth else { throw ConversionError.depth }
            guard remaining > 0 else { throw ConversionError.size }
            remaining -= 1

            switch value {
            case is NSNull:
                return NSNull()
            case let number as NSNumber:
                guard number.doubleValue.isFinite else { throw ConversionError.nonFinite }
                return number
            case let string as NSString:
                return string as String
            case let date as NSDate:
                // Preserve the bridge's existing textual representation of dates.
                return String(describing: date)
            case let array as NSArray:
                let identity = ObjectIdentifier(array)
                guard ancestors.insert(identity).inserted else { throw ConversionError.circular }
                defer { ancestors.remove(identity) }
                guard array.count <= remaining else { throw ConversionError.size }
                let source = unsafeBitCast(array, to: CFArray.self)
                var result = [Any]()
                result.reserveCapacity(array.count)
                for index in 0..<array.count {
                    // Read raw references: Foundation's Any-returning accessors
                    // may bridge a child collection before we can check it.
                    let child = Unmanaged<AnyObject>.fromOpaque(CFArrayGetValueAtIndex(source, index)).takeUnretainedValue()
                    result.append(try convert(child, depth: depth + 1))
                }
                return result
            case let dictionary as NSDictionary:
                let identity = ObjectIdentifier(dictionary)
                guard ancestors.insert(identity).inserted else { throw ConversionError.circular }
                defer { ancestors.remove(identity) }
                guard dictionary.count <= remaining else { throw ConversionError.size }
                let source = unsafeBitCast(dictionary, to: CFDictionary.self)
                var keys = [UnsafeRawPointer?](repeating: nil, count: dictionary.count)
                var values = [UnsafeRawPointer?](repeating: nil, count: dictionary.count)
                CFDictionaryGetKeysAndValues(source, &keys, &values)
                var result = [String: Any]()
                result.reserveCapacity(dictionary.count)
                for index in keys.indices {
                    let key = Unmanaged<AnyObject>.fromOpaque(keys[index]!).takeUnretainedValue()
                    guard let key = key as? NSString else { throw ConversionError.unsupported }
                    let child = Unmanaged<AnyObject>.fromOpaque(values[index]!).takeUnretainedValue()
                    result[key as String] = try convert(child, depth: depth + 1)
                }
                return result
            default:
                throw ConversionError.unsupported
            }
        }
    }
}
