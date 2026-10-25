import Foundation
@testable import AWSPlatform

func ebsScope(profile: String = "ebs-test", region: String = "us-east-1", account: String = "111122223333",
              role: String = "ReadOnly", config: String = "/tmp/ebs-offline-config") -> MonitoringScope {
    MonitoringScope(profile: AWSProfile(name: profile, region: region, ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
                    identity: AWSIdentity(account: account, arn: "arn:aws:iam::\(account):role/\(role)", userID: "offline"),
                    region: region, paths: AWSConfigurationPaths(environment: [
                        "AWS_CONFIG_FILE": config, "AWS_SHARED_CREDENTIALS_FILE": "/tmp/ebs-offline-credentials"
                    ]))
}

func ebsRow(_ kind: EBSResource.Kind = .volume, id: String? = nil, name: String = "production-data",
            account: String = "111122223333") -> EBSResource {
    EBSResource(id: id ?? (kind == .volume ? "vol-12345678" : "snap-12345678"), name: name, kind: kind,
                state: kind == .volume ? "available" : "completed", sizeGiB: 20, encrypted: true,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000), ownerID: account,
                volumeType: kind == .volume ? "gp3" : nil, availabilityZone: kind == .volume ? "us-east-1a" : nil,
                kmsKeyID: "arn:aws:kms:us-east-1:111122223333:key/offline-example", tags: ["Environment": "production"])
}
