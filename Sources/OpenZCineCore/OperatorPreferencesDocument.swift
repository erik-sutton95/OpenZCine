import Foundation

/// Retains unrecognized preferences while applying changes to known operator choices.
public struct OperatorPreferencesDocument: Sendable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }

    public func decoded() -> OperatorPreferences {
        (try? JSONDecoder().decode(OperatorPreferences.self, from: data)) ?? .defaults
    }

    public func updating(_ next: OperatorPreferences, previous: OperatorPreferences) throws -> Data {
        guard next != previous else { return data }
        guard let original = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.malformedDocument
        }
        let before = try Self.object(previous)
        let after = try Self.object(next)
        let merged = Self.merge(original: original, previous: before, next: after)
        return try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
    }

    private enum UpdateError: Error {
        case malformedDocument
    }

    private static func object(_ value: OperatorPreferences) throws -> [String: Any] {
        let encoded = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw UpdateError.malformedDocument
        }
        return object
    }

    private static func equal(_ first: Any?, _ second: Any?, key: String) -> Bool {
        if key == "enabledDispModes", let first = first as? [String], let second = second as? [String] {
            return Set(first) == Set(second)
        }
        return NSDictionary(dictionary: ["value": first ?? NSNull()])
            .isEqual(to: ["value": second ?? NSNull()])
    }

    private static func merge(original: [String: Any], previous: [String: Any], next: [String: Any]) -> [String: Any] {
        var result = original
        for (key, value) in next where !equal(previous[key], value, key: key) {
            if let before = previous[key] as? [String: Any], let after = value as? [String: Any] {
                result[key] = merge(original: original[key] as? [String: Any] ?? [:], previous: before, next: after)
            } else if let before = previous[key] as? [String], let after = value as? [String],
                      let raw = original[key] as? [String] {
                // Unknown and retired raw values stay in place beside edited known values.
                let known = Set(before)
                var remaining = after.makeIterator()
                var merged: [String] = []
                for item in raw {
                    if known.contains(item) {
                        if let replacement = remaining.next() { merged.append(replacement) }
                    } else {
                        merged.append(item)
                    }
                }
                while let item = remaining.next() { merged.append(item) }
                result[key] = merged
            } else {
                result[key] = value
            }
        }
        return result
    }
}
