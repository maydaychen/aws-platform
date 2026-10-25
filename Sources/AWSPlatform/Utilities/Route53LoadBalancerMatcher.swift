import Foundation

enum Route53LoadBalancerMatcher: Sendable {
    static func matches(record: Route53Record, loadBalancer: ELBLoadBalancer) -> Bool {
        guard ["application", "network"].contains(loadBalancer.kind),
              let dnsName = loadBalancer.dnsName,
              let loadBalancerDNS = normalizedDNS(dnsName) else { return false }

        if let alias = record.alias {
            guard ["A", "AAAA"].contains(record.type),
                  let aliasDNS = normalizedDNS(alias.dnsName),
                  let canonicalZoneID = loadBalancer.canonicalHostedZoneID,
                  let loadBalancerZoneID = normalizedZoneID(canonicalZoneID),
                  let aliasZoneID = normalizedZoneID(alias.hostedZoneID),
                  loadBalancerZoneID == aliasZoneID else { return false }

            if loadBalancer.kind == "application" {
                return removingDualstackPrefix(aliasDNS) == removingDualstackPrefix(loadBalancerDNS)
            }
            guard !aliasDNS.hasPrefix("dualstack."),
                  !loadBalancerDNS.hasPrefix("dualstack.") else { return false }
            return aliasDNS == loadBalancerDNS
        }

        guard record.type == "CNAME" else { return false }
        return record.values.contains { value in
            guard let targetDNS = normalizedDNS(value) else { return false }
            if loadBalancer.kind == "application" {
                return removingDualstackPrefix(targetDNS) == removingDualstackPrefix(loadBalancerDNS)
            }
            return targetDNS == loadBalancerDNS
        }
    }

    static func targets(in record: Route53Record) -> [String] {
        if let alias = record.alias { return [alias.dnsName] }
        return record.type == "CNAME" ? record.values : []
    }

    private static func normalizedDNS(_ value: String) -> String? {
        guard value.utf8.allSatisfy({ byte in
            (65...90).contains(byte) || (97...122).contains(byte)
                || (48...57).contains(byte) || byte == 45 || byte == 46
        }) else { return nil }
        var name = value.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name.utf8.count <= 253 else { return nil }

        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63
                && label.first != "-" && label.last != "-"
        }), !(labels.count >= 2 && labels[0] == "dualstack" && labels[1] == "dualstack") else {
            return nil
        }
        return name
    }

    private static func normalizedZoneID(_ value: String) -> String? {
        guard let id = Route53HostedZone.normalizedID(value),
              id.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else {
            return nil
        }
        return id
    }

    private static func removingDualstackPrefix(_ value: String) -> String {
        value.hasPrefix("dualstack.") ? String(value.dropFirst("dualstack.".count)) : value
    }
}
