import Foundation

/// Evaluates whether the popup may appear automatically for a frontmost app and optional website host.
public struct AppFilter: Codable, Equatable, Sendable {
    public var appearAutomatically: Bool
    public var excludedBundleIDs: Set<String>
    public var includedBundleIDs: Set<String>
    public var excludedWebsiteHosts: Set<String>

    public init(
        appearAutomatically: Bool = true,
        excludedBundleIDs: Set<String> = [],
        includedBundleIDs: Set<String> = [],
        excludedWebsiteHosts: Set<String> = []
    ) {
        self.appearAutomatically = appearAutomatically
        self.excludedBundleIDs = excludedBundleIDs
        self.includedBundleIDs = includedBundleIDs
        self.excludedWebsiteHosts = excludedWebsiteHosts
    }

    public init(
        appearAutomatically: Bool = true,
        excludedBundleIDs: Set<String> = [],
        includedBundleIDs: Set<String> = [],
        excludedHosts: Set<String>
    ) {
        self.init(
            appearAutomatically: appearAutomatically,
            excludedBundleIDs: excludedBundleIDs,
            includedBundleIDs: includedBundleIDs,
            excludedWebsiteHosts: excludedHosts
        )
    }

    public var excludedHosts: Set<String> {
        get { excludedWebsiteHosts }
        set { excludedWebsiteHosts = newValue }
    }

    public func shouldAppear(bundleID: String?, websiteHost: String? = nil) -> Bool {
        guard appearAutomatically else {
            return false
        }

        let normalizedBundleID = Self.normalizeBundleID(bundleID)
        let normalizedExcludedBundles = Set(
            excludedBundleIDs.compactMap { Self.normalizeBundleID($0) }.filter { !$0.isEmpty }
        )

        if !normalizedBundleID.isEmpty && normalizedExcludedBundles.contains(normalizedBundleID) {
            return false
        }

        if let host = Self.normalizeHost(websiteHost) {
            let excludedHostsNormalized = excludedWebsiteHosts.compactMap { Self.normalizeHost($0) }
            if excludedHostsNormalized.contains(where: { Self.host(host, matchesRule: $0) }) {
                return false
            }
        }

        let normalizedIncludedBundles = Set(
            includedBundleIDs.compactMap { Self.normalizeBundleID($0) }.filter { !$0.isEmpty }
        )
        if !normalizedIncludedBundles.isEmpty {
            guard !normalizedBundleID.isEmpty else {
                return false
            }
            return normalizedIncludedBundles.contains(normalizedBundleID)
        }

        return true
    }

    private static func normalizeBundleID(_ raw: String?) -> String {
        (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func normalizeHost(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !candidate.isEmpty else { return nil }

        if candidate.contains("://"), let components = URLComponents(string: candidate), let host = components.host {
            candidate = host.lowercased()
        } else {
            if let slashIndex = candidate.firstIndex(of: "/") {
                candidate = String(candidate[..<slashIndex])
            }
            if let colonIndex = candidate.firstIndex(of: ":") {
                candidate = String(candidate[..<colonIndex])
            }
        }

        while candidate.hasPrefix(".") {
            candidate.removeFirst()
        }
        while candidate.hasSuffix(".") {
            candidate.removeLast()
        }

        return candidate.isEmpty ? nil : candidate
    }

    private static func host(_ host: String, matchesRule rule: String) -> Bool {
        host == rule || host.hasSuffix("." + rule)
    }
}
