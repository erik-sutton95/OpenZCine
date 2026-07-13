import Foundation

/// Canonicalizes the app-side list of hosts that already have Nikon pairing profiles.
public enum PTPIPPairedHosts {
    /// Returns a stable host key, or `nil` when the user has not entered a host.
    public static func normalizedHost(_ host: String) -> String? {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    /// Returns `true` when the host exists in the saved pair list.
    public static func contains(_ host: String, in hosts: [String]) -> Bool {
        guard let normalized = normalizedHost(host) else { return false }
        return canonicalized(hosts).contains(normalized)
    }

    /// Adds a host to the saved pair list, preserving first-seen order and removing duplicates.
    public static func adding(_ host: String, to hosts: [String]) -> [String] {
        guard let normalized = normalizedHost(host) else { return canonicalized(hosts) }
        var output = canonicalized(hosts)
        if !output.contains(normalized) {
            output.append(normalized)
        }
        return output
    }

    /// Removes a host from the saved pair list.
    public static func removing(_ host: String, from hosts: [String]) -> [String] {
        guard let normalized = normalizedHost(host) else { return canonicalized(hosts) }
        return canonicalized(hosts).filter { $0 != normalized }
    }

    /// Normalizes all hosts, drops empty entries, and keeps only the first occurrence.
    public static func canonicalized(_ hosts: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for host in hosts {
            guard let normalized = normalizedHost(host), !seen.contains(normalized) else {
                continue
            }
            seen.insert(normalized)
            output.append(normalized)
        }
        return output
    }
}
