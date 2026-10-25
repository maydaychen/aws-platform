import Foundation
import SotoLambda
import XCTest
@testable import AWSPlatform

final class LambdaReadServiceTests: XCTestCase {
    func testSDKListFixtureMapsFunctionConfigurationAndOptionalDefaults() throws {
        let response: Lambda.ListFunctionsResponse = try decode("""
        {"Functions":[{"FunctionName":"example","FunctionArn":"arn:aws:lambda:us-east-1:111122223333:function:example",
          "Runtime":"provided.al2023","State":"Active","LastUpdateStatus":"Successful","MemorySize":512,
          "Handler":"bootstrap","Role":"arn:aws:iam::111122223333:role/worker","CodeSize":2048,"Timeout":30,
          "Environment":{"Variables":{"MODE":"test"}},"VpcConfig":{"VpcId":"vpc-example"},"PackageType":"Zip"},{}]}
        """)
        let functions = (response.functions ?? []).map(LambdaResponseMapper.function)
        XCTAssertEqual(functions.count, 2)
        XCTAssertEqual(functions[0].functionName, "example")
        XCTAssertEqual(functions[0].arn, "arn:aws:lambda:us-east-1:111122223333:function:example")
        XCTAssertEqual(functions[0].runtime, "provided.al2023")
        XCTAssertEqual(functions[0].state, "Active")
        XCTAssertEqual(functions[0].lastUpdateStatus, "Successful")
        XCTAssertEqual(functions[0].environment, ["MODE": "test"])
        XCTAssertEqual(functions[0].vpcConfig, "vpc-example")
        XCTAssertEqual(functions[0].memorySize, 512)
        XCTAssertEqual(functions[0].codeSize, 2048)
        XCTAssertEqual(functions[0].timeout, 30)
        XCTAssertEqual(functions[1].functionName, "unknown")
        XCTAssertTrue(functions[1].environment.isEmpty)
        XCTAssertTrue(functions[1].codeFiles.isEmpty)
    }

    func testSDKDetailFixtureMapsConfigurationAndPartialWarnings() throws {
        let response: Lambda.GetFunctionResponse = try decode("""
        {"Configuration":{"FunctionName":"example","Description":"fixture","State":"Failed","StateReason":"test",
          "LastUpdateStatus":"Failed","Version":"4","Architectures":["arm64"],"RevisionId":"revision",
          "CodeSha256":"code-hash","ConfigSha256":"config-hash","EphemeralStorage":{"Size":1024},
          "Environment":{"Variables":{"MODE":"test"},"Error":{"ErrorCode":"AccessDenied","Message":"environment unavailable"}},
          "VpcConfig":{"VpcId":"vpc-example","SubnetIds":["subnet-example"],"SecurityGroupIds":["sg-example"],"Ipv6AllowedForDualStack":true},
          "Layers":[{"Arn":"arn:aws:lambda:us-east-1:111122223333:layer:shared:2","CodeSize":100},{}],
          "FileSystemConfigs":[{"Arn":"arn:aws:elasticfilesystem:us-east-1:111122223333:access-point/fsap-example","LocalMountPath":"/mnt/shared"}],
          "LoggingConfig":{"LogGroup":"/aws/lambda/custom","LogFormat":"JSON","ApplicationLogLevel":"INFO","SystemLogLevel":"WARN"},
          "ImageConfigResponse":{"ImageConfig":{"EntryPoint":["/app/start"],"Command":["run"],"WorkingDirectory":"/app"}},
          "SnapStart":{"ApplyOn":"PublishedVersions","OptimizationStatus":"On"}},
          "Code":{"ImageUri":"example/image:tag","ResolvedImageUri":"example/image@sha256:hash","SourceKMSKeyArn":"source-key","RepositoryType":"ECR"},
          "Concurrency":{"ReservedConcurrentExecutions":2},"Tags":{"team":"core"},
          "TagsError":{"ErrorCode":"AccessDenied","Message":"tags unavailable"}}
        """)
        let detail = try LambdaResponseMapper.detail(functionName: "selected-name", response: response)
        XCTAssertEqual(detail.functionName, "selected-name")
        XCTAssertEqual(detail.state, "Failed")
        XCTAssertEqual(detail.architectures, ["arm64"])
        XCTAssertEqual(detail.version, "4")
        XCTAssertEqual(detail.codeSHA256, "code-hash")
        XCTAssertEqual(detail.configSHA256, "config-hash")
        XCTAssertEqual(detail.ephemeralStorageMB, 1024)
        XCTAssertEqual(detail.environment, ["MODE": "test"])
        XCTAssertEqual(detail.environmentError, "environment unavailable")
        XCTAssertEqual(detail.subnetIds, ["subnet-example"])
        XCTAssertEqual(detail.securityGroupIds, ["sg-example"])
        XCTAssertEqual(detail.ipv6AllowedForDualStack, true)
        XCTAssertEqual(detail.layers.count, 1, "Missing layer ARN is omitted")
        XCTAssertEqual(detail.fileSystems.first?.localMountPath, "/mnt/shared")
        XCTAssertEqual(detail.logGroup, "/aws/lambda/custom")
        XCTAssertEqual(detail.applicationLogLevel, "INFO")
        XCTAssertEqual(detail.imageEntryPoint, ["/app/start"])
        XCTAssertEqual(detail.imageCommand, ["run"])
        XCTAssertEqual(detail.imageWorkingDirectory, "/app")
        XCTAssertEqual(detail.imageURI, "example/image:tag")
        XCTAssertEqual(detail.resolvedImageURI, "example/image@sha256:hash")
        XCTAssertEqual(detail.sourceKMSKeyARN, "source-key")
        XCTAssertEqual(detail.reservedConcurrency, 2)
        XCTAssertEqual(detail.tags, ["team": "core"])
        XCTAssertEqual(detail.warnings.count, 2)
        XCTAssertTrue(detail.warnings.contains { $0.contains("environment unavailable") })
        XCTAssertTrue(detail.warnings.contains { $0.contains("tags unavailable") })
        XCTAssertTrue(detail.eventSources.isEmpty, "Secondary sections stay lazy")
        XCTAssertTrue(detail.provisionedConcurrency.isEmpty)
    }

    func testMissingSDKConfigurationFailsInsteadOfProducingEmptyDetail() {
        XCTAssertThrowsError(try LambdaResponseMapper.detail(functionName: "example", response: .init())) {
            XCTAssertEqual($0 as? LambdaDetailError, .missingConfiguration)
        }
    }

    func testQualifiedSDKARNsRemainDistinctForAsyncURLAndConcurrencyModels() throws {
        let base = "arn:aws:lambda:us-east-1:111122223333:function:example"
        let asyncResponse: Lambda.ListFunctionEventInvokeConfigsResponse = try decode("""
        {"FunctionEventInvokeConfigs":[{"FunctionArn":"\(base):prod","MaximumEventAgeInSeconds":60,"MaximumRetryAttempts":1,
          "DestinationConfig":{"OnFailure":{"Destination":"arn:aws:sqs:us-east-1:111122223333:failures"}}},
          {"FunctionArn":"\(base):test"},{}]}
        """)
        let asyncConfigs = (asyncResponse.functionEventInvokeConfigs ?? []).compactMap {
            LambdaResponseMapper.asyncInvokeConfig($0, functionName: "example")
        }
        XCTAssertEqual(asyncConfigs.map(\.qualifier), ["prod", "test"])
        XCTAssertEqual(Set(asyncConfigs.map(\.id)).count, 2)
        XCTAssertEqual(asyncConfigs.first?.maximumEventAgeSeconds, 60)
        XCTAssertEqual(asyncConfigs.first?.maximumRetryAttempts, 1)
        XCTAssertEqual(asyncConfigs.first?.onFailureDestination, "arn:aws:sqs:us-east-1:111122223333:failures")

        let urlResponse: Lambda.ListFunctionUrlConfigsResponse = try decode("""
        {"FunctionUrlConfigs":[{"FunctionArn":"\(base):prod","FunctionUrl":"https://example.lambda-url.us-east-1.on.aws/",
          "AuthType":"AWS_IAM","InvokeMode":"RESPONSE_STREAM","CreationTime":"created","LastModifiedTime":"modified",
          "Cors":{"AllowCredentials":true,"AllowOrigins":["https://example.com"],"AllowMethods":["GET"]}}]}
        """)
        let url = try XCTUnwrap(urlResponse.functionUrlConfigs.map(LambdaResponseMapper.functionURL).first)
        XCTAssertEqual(url.id, "\(base):prod")
        XCTAssertEqual(url.authType, "AWS_IAM")
        XCTAssertEqual(url.invokeMode, "RESPONSE_STREAM")
        XCTAssertEqual(url.allowedOrigins, ["https://example.com"])
        XCTAssertEqual(url.allowedMethods, ["GET"])
        XCTAssertEqual(url.allowCredentials, true)

        let concurrencyResponse: Lambda.ListProvisionedConcurrencyConfigsResponse = try decode("""
        {"ProvisionedConcurrencyConfigs":[{"FunctionArn":"\(base):prod","RequestedProvisionedConcurrentExecutions":5,
          "AllocatedProvisionedConcurrentExecutions":4,"AvailableProvisionedConcurrentExecutions":3,"Status":"READY"},
          {"FunctionArn":"\(base):4"},{}]}
        """)
        let configs = (concurrencyResponse.provisionedConcurrencyConfigs ?? []).compactMap {
            LambdaResponseMapper.provisionedConcurrency($0, functionName: "example")
        }
        XCTAssertEqual(configs.map(\.qualifier), ["prod", "4"])
        XCTAssertEqual(Set(configs.map(\.id)).count, 2)
        XCTAssertEqual(configs.first?.requested, 5)
        XCTAssertEqual(configs.first?.allocated, 4)
        XCTAssertEqual(configs.first?.available, 3)
        XCTAssertEqual(configs.first?.status, "READY")
    }

    @MainActor
    func testAsyncPolicyParsingPreservesStatementsAndRejectsMalformedInput() async throws {
        let policy = #"{"Statement":{"Sid":"allow","Action":"lambda:InvokeFunction","Principal":"*"}}"#
        let statements = try await LambdaResponseMapper.policyStatements(from: policy)
        XCTAssertEqual(statements.map(\.statementId), ["allow"])
        do {
            _ = try await LambdaResponseMapper.policyStatements(from: "invalid")
            XCTFail("Malformed policy must fail")
        } catch { }
    }

    @MainActor
    func testPolicyParsingHonorsCancellationBeforeParsing() async {
        let request = Task { @MainActor in
            try await LambdaResponseMapper.policyStatements(from: #"{"Statement":[]}"#)
        }
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(T.self, from: Data(json.utf8))
    }
}
