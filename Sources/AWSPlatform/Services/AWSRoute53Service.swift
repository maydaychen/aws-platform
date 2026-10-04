import Foundation
import SotoCore
import SotoRoute53

struct AWSRoute53Service: Sendable {
    typealias ZoneLoader = @Sendable (Route53.ListHostedZonesRequest) async throws -> Route53.ListHostedZonesResponse
    typealias DetailLoader = @Sendable (Route53.GetHostedZoneRequest) async throws -> Route53.GetHostedZoneResponse
    typealias RecordLoader = @Sendable (Route53.ListResourceRecordSetsRequest) async throws -> Route53.ListResourceRecordSetsResponse
    typealias TagLoader = @Sendable (Route53.ListTagsForResourceRequest) async throws -> Route53.ListTagsForResourceResponse

    private struct Operations: Sendable {
        let zones: ZoneLoader
        let details: DetailLoader
        let records: RecordLoader
        let tags: TagLoader
    }

    private struct RecordCursor: Hashable {
        let name: String
        let type: Route53.RRType
        let identifier: String?
    }

    private let provider: AWSServiceProvider?
    private let injected: Operations?
    private static let maximumPages = 1_000

    init(provider: AWSServiceProvider) {
        self.provider = provider
        injected = nil
    }

    init(zoneLoader: @escaping ZoneLoader, detailLoader: @escaping DetailLoader,
         recordLoader: @escaping RecordLoader, tagLoader: @escaping TagLoader) {
        provider = nil
        injected = Operations(zones: zoneLoader, details: detailLoader, records: recordLoader, tags: tagLoader)
    }

    func loadZones(scope: Route53Scope) async throws -> [Route53HostedZone] {
        do {
            let operations = try await operations(scope: scope)
            var zones: [Route53HostedZone] = []
            var ids: Set<String> = []
            var marker: String?
            var markers: Set<String> = []
            for _ in 0..<Self.maximumPages {
                try Task.checkCancellation()
                let response = try await operations.zones(.init(marker: marker, maxItems: 100))
                try Task.checkCancellation()
                for raw in response.hostedZones {
                    let zone = try Self.map(raw)
                    guard ids.insert(zone.id).inserted else { throw Route53Error.invalidResponse }
                    zones.append(zone)
                }
                guard response.isTruncated else {
                    try Task.checkCancellation()
                    return zones.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
                }
                guard let next = response.nextMarker, !next.isEmpty,
                      markers.insert(next).inserted else { throw Route53Error.incompletePagination }
                marker = next
            }
            throw Route53Error.incompletePagination
        } catch {
            throw Self.sanitized(error, operation: .zones)
        }
    }

    func loadDetails(scope: Route53Scope, zone: Route53HostedZone) async throws -> Route53ZoneDetails {
        do {
            let id = try Self.validate(zone)
            let operations = try await operations(scope: scope)
            try Task.checkCancellation()
            let response = try await operations.details(.init(id: id))
            try Task.checkCancellation()
            let returnedZone = try Self.map(response.hostedZone)
            guard returnedZone.id == id, returnedZone.name == zone.name,
                  returnedZone.isPrivate == zone.isPrivate,
                  !response.hostedZone.callerReference.isEmpty else { throw Route53Error.invalidResponse }
            let vpcs = try (response.vpCs ?? []).map { vpc in
                guard let id = vpc.vpcId, !id.isEmpty, let region = vpc.vpcRegion else {
                    throw Route53Error.invalidResponse
                }
                return Route53VPC(id: id, region: region.rawValue)
            }
            let linked = response.hostedZone.linkedService
            let fields: [(String, String?)] = [("Service principal", linked?.servicePrincipal), ("Description", linked?.description)]
            try Task.checkCancellation()
            return Route53ZoneDetails(
                zone: returnedZone, callerReference: response.hostedZone.callerReference,
                nameServers: response.delegationSet?.nameServers ?? [], delegationSetID: response.delegationSet?.id,
                vpcs: vpcs, linkedService: fields.compactMap { name, value in value.map { .init(name: name, value: $0) } }
            )
        } catch {
            throw Self.sanitized(error, operation: .details)
        }
    }

    func loadRecords(scope: Route53Scope, zone: Route53HostedZone) async throws -> [Route53Record] {
        do {
            let id = try Self.validate(zone)
            let operations = try await operations(scope: scope)
            var records: [Route53Record] = []
            var ids: Set<Route53Record.ID> = []
            var cursor: RecordCursor?
            var cursors: Set<RecordCursor> = []
            for _ in 0..<Self.maximumPages {
                try Task.checkCancellation()
                let response = try await operations.records(.init(
                    hostedZoneId: id, maxItems: 300, startRecordIdentifier: cursor?.identifier,
                    startRecordName: cursor?.name, startRecordType: cursor?.type
                ))
                try Task.checkCancellation()
                for raw in response.resourceRecordSets {
                    let record = try Self.map(raw)
                    guard ids.insert(record.id).inserted else { throw Route53Error.invalidResponse }
                    records.append(record)
                }
                guard response.isTruncated else {
                    try Task.checkCancellation()
                    return records
                }
                guard let name = response.nextRecordName, !name.isEmpty, let type = response.nextRecordType,
                      response.nextRecordIdentifier != "" else { throw Route53Error.incompletePagination }
                if let last = response.resourceRecordSets.last,
                   last.name == name, last.type == type, last.setIdentifier != nil,
                   response.nextRecordIdentifier == nil { throw Route53Error.incompletePagination }
                let next = RecordCursor(name: name, type: type, identifier: response.nextRecordIdentifier)
                guard cursors.insert(next).inserted else { throw Route53Error.incompletePagination }
                cursor = next
            }
            throw Route53Error.incompletePagination
        } catch {
            throw Self.sanitized(error, operation: .records)
        }
    }

    func loadTags(scope: Route53Scope, zone: Route53HostedZone) async throws -> [String: String] {
        do {
            let id = try Self.validate(zone)
            let operations = try await operations(scope: scope)
            try Task.checkCancellation()
            let response = try await operations.tags(.init(resourceId: id, resourceType: .hostedzone))
            try Task.checkCancellation()
            let set = response.resourceTagSet
            guard set.resourceType == .hostedzone, let returnedID = set.resourceId,
                  Route53HostedZone.normalizedID(returnedID) == id else { throw Route53Error.invalidResponse }
            var tags: [String: String] = [:]
            for tag in set.tags ?? [] {
                guard let key = tag.key, !key.isEmpty, let value = tag.value, tags[key] == nil else {
                    throw Route53Error.invalidResponse
                }
                tags[key] = value
            }
            try Task.checkCancellation()
            return tags
        } catch {
            throw Self.sanitized(error, operation: .tags)
        }
    }

    private func operations(scope: Route53Scope) async throws -> Operations {
        try Task.checkCancellation()
        _ = try scope.partition()
        if let injected { return injected }
        guard let provider else { throw Route53Error.invalidScope }
        let client = try await provider.route53Client(scope: scope)
        return Operations(
            zones: { try await client.listHostedZones($0) }, details: { try await client.getHostedZone($0) },
            records: { try await client.listResourceRecordSets($0) }, tags: { try await client.listTagsForResource($0) }
        )
    }

    private static func validate(_ zone: Route53HostedZone) throws -> String {
        try Task.checkCancellation()
        guard let id = Route53HostedZone.normalizedID(zone.id), !zone.name.isEmpty,
              zone.recordCount.map({ $0 >= 0 }) ?? true else { throw Route53Error.invalidResponse }
        return id
    }

    private static func map(_ raw: Route53.HostedZone) throws -> Route53HostedZone {
        guard let id = Route53HostedZone.normalizedID(raw.id), let isPrivate = raw.config?.privateZone else {
            throw Route53Error.invalidResponse
        }
        let zone = Route53HostedZone(id: id, name: raw.name, isPrivate: isPrivate,
                                     recordCount: raw.resourceRecordSetCount, comment: raw.config?.comment)
        _ = try validate(zone)
        return zone
    }

    private static func map(_ raw: Route53.ResourceRecordSet) throws -> Route53Record {
        guard !raw.name.isEmpty, raw.setIdentifier != "", raw.ttl.map({ $0 >= 0 }) ?? true else {
            throw Route53Error.invalidResponse
        }
        var alias: Route53Alias?
        if let target = raw.aliasTarget {
            guard !target.dnsName.isEmpty, let zoneID = Route53HostedZone.normalizedID(target.hostedZoneId) else {
                throw Route53Error.invalidResponse
            }
            alias = Route53Alias(dnsName: target.dnsName, hostedZoneID: zoneID, evaluateTargetHealth: target.evaluateTargetHealth)
        }
        var policies: [String] = []
        var fields: [Route53Field] = []
        func append(_ name: String, _ value: String?) {
            if let value { fields.append(Route53Field(name: name, value: value)) }
        }
        if let weight = raw.weight {
            policies.append("Weighted")
            append("Weight", String(weight))
        }
        if let region = raw.region {
            policies.append("Latency")
            append("Latency region", region.rawValue)
        }
        if let failover = raw.failover {
            policies.append("Failover")
            append("Failover", failover.rawValue)
        }
        if let location = raw.geoLocation {
            policies.append("Geolocation")
            append("Continent", location.continentCode)
            append("Country", location.countryCode)
            append("Subdivision", location.subdivisionCode)
        }
        if let proximity = raw.geoProximityLocation {
            policies.append("Geoproximity")
            append("Geoproximity AWS region", proximity.awsRegion)
            append("Geoproximity local zone group", proximity.localZoneGroup)
            append("Geoproximity latitude", proximity.coordinates?.latitude)
            append("Geoproximity longitude", proximity.coordinates?.longitude)
            append("Geoproximity bias", proximity.bias.map(String.init))
        }
        if let cidr = raw.cidrRoutingConfig {
            policies.append("IP-based")
            append("CIDR collection", cidr.collectionId)
            append("CIDR location", cidr.locationName)
        }
        if let multivalue = raw.multiValueAnswer {
            if multivalue { policies.append("Multivalue answer") }
            append("Multivalue answer", multivalue ? "Enabled" : "Disabled")
        }
        append("Health check ID", raw.healthCheckId)
        append("Traffic policy instance ID", raw.trafficPolicyInstanceId)
        return Route53Record(
            name: raw.name, type: raw.type.rawValue, setIdentifier: raw.setIdentifier, ttl: raw.ttl,
            values: raw.resourceRecords?.map(\.value) ?? [], alias: alias,
            routingPolicy: policies.isEmpty ? "Simple" : policies.joined(separator: ", "), routingFields: fields
        )
    }

    private enum Operation { case zones, details, records, tags }

    private static func sanitized(_ error: Error, operation: Operation) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? Route53Error { return error }
        if let error = error as? RequestError { return error }
        if error is AWSServiceError { return Route53Error.invalidScope }
        let code = (error as? AWSResponseError)?.errorCode ?? (error as? AWSErrorType)?.errorCode ?? ""
        if ["AccessDenied", "AccessDeniedException", "UnauthorizedException", "ForbiddenException"].contains(code) {
            switch operation {
            case .zones: return RequestError.listPermission
            case .details: return RequestError.detailPermission
            case .records: return RequestError.recordsPermission
            case .tags: return RequestError.tagsPermission
            }
        }
        if UserFacingError.requiresSSOLogin(error) { return RequestError.credentials }
        if error is URLError { return RequestError.network }
        switch code {
        case "Throttling", "ThrottlingException", "TooManyRequestsException", "PriorRequestNotComplete": return RequestError.throttled
        case "NoSuchHostedZone", "NoSuchResource": return RequestError.notFound
        case "InvalidPaginationToken", "InvalidNextToken", "InvalidNextTokenException": return Route53Error.incompletePagination
        default: return RequestError.failed
        }
    }

    enum RequestError: LocalizedError, Equatable {
        case listPermission, detailPermission, recordsPermission, tagsPermission, credentials, network, throttled, notFound, failed

        var errorDescription: String? {
            switch self {
            case .listPermission: return "Hosted zone access was denied. Check route53:ListHostedZones permission for the selected profile."
            case .detailPermission: return "Hosted zone details could not be read. Check route53:GetHostedZone permission for this zone."
            case .recordsPermission: return "DNS records could not be read. Check route53:ListResourceRecordSets permission for this zone."
            case .tagsPermission: return "Hosted zone tags could not be read. Check route53:ListTagsForResource permission for this zone."
            case .credentials: return "AWS credentials expired or are unavailable. Sign in to the session, select the profile again, then reload Route 53."
            case .network: return "Unable to reach Route 53. Check your network or proxy, then refresh."
            case .throttled: return "Route 53 is limiting requests. Wait a moment, then refresh manually."
            case .notFound: return "The hosted zone is no longer available to this profile. Refresh the hosted zone list."
            case .failed: return "The Route 53 request failed. Check the selected profile and service availability, then refresh."
            }
        }
    }
}
