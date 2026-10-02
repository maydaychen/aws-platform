import Foundation
import SotoCore
import SotoS3

enum UserFacingError {
    static func loginMessage(for error: Error, profileName: String) -> String {
        if let error = error as? AWSCLICredentialProvider.ExportError {
            return error.localizedDescription
        }
        let reflectedType = String(reflecting: type(of: error))
        let description = error.localizedDescription
        let lowercased = description.lowercased()

        if reflectedType.contains("ConfigFileLoader.ConfigFileError") {
            if lowercased.contains("missingprofile") {
                return "AWS profile `\(profileName)` was not found in `~/.aws/config` or `~/.aws/credentials`."
            }
            if lowercased.contains("invalidinifile") {
                return "AWS config file format is invalid. Check `~/.aws/config` and `~/.aws/credentials` for malformed INI content."
            }
            if lowercased.contains("missingaccesskeyid") {
                return "AWS credentials for `\(profileName)` are missing `aws_access_key_id`. Check `~/.aws/credentials` or run `aws sso login --profile \(profileName)`."
            }
            if lowercased.contains("missingsecretaccesskey") {
                return "AWS credentials for `\(profileName)` are missing `aws_secret_access_key`. Check `~/.aws/credentials` or run `aws sso login --profile \(profileName)`."
            }
            return "AWS profile configuration is invalid for `\(profileName)`. Check `~/.aws/config` and `~/.aws/credentials`."
        }

        if reflectedType.contains("AWSSSOCredentialError") || reflectedType.contains("SSOCredential") {
            return "AWS SSO login required. Run `aws sso login --profile \(profileName)` and retry."
        }

        if lowercased.contains("sso") || lowercased.contains("expired") || lowercased.contains("token") {
            return "AWS profile is not logged in. Run `aws sso login --profile \(profileName)`."
        }
        if lowercased.contains("credential") || lowercased.contains("signature") || lowercased.contains("access key") {
            return "AWS credentials are invalid or missing for `\(profileName)`. Check `~/.aws/config`, `~/.aws/credentials`, or run `aws sso login --profile \(profileName)`."
        }
        return "AWS profile validation failed for `\(profileName)`: \(error.localizedDescription)"
    }

    static func message(for error: Error) -> String {
        if let error = error as? AWSCLICredentialProvider.ExportError {
            return error.localizedDescription
        }
        if error is CancellationError {
            return "Request was cancelled."
        }

        if let error = error as? S3ErrorType {
            return s3Message(forCode: error.errorCode, detail: error.message)
        }

        if let error = error as? AWSResponseError {
            return awsResponseMessage(forCode: error.errorCode, detail: error.message)
        }

        if let error = error as? AWSErrorType {
            return awsErrorMessage(for: error)
        }

        if let error = error as? AWSRawError {
            let code = error.context.responseCode.code
            if code == 401 || code == 403 {
                return "AWS authentication failed. Run `aws sso login` for the selected profile, then retry."
            }
            if code == 429 {
                return "AWS API rate limit reached. Wait a moment and retry."
            }
            if code >= 500 {
                return "AWS service error (HTTP \(code)). Try again later."
            }
            return "AWS request failed (HTTP \(code)). Check the selected profile and region."
        }

        let description = error.localizedDescription
        let lowercased = description.lowercased()

        if lowercased.contains("expired") || lowercased.contains("sso") {
            return "AWS session expired. Run `aws sso login` for the selected profile, then retry."
        }

        if lowercased.contains("accessdenied") || lowercased.contains("unauthorized") || lowercased.contains("forbidden") {
            if lowercased.contains("getbucketlocation") || lowercased.contains("listbucket") || lowercased.contains("bucket") {
                return "S3 permission denied. Check `s3:ListAllMyBuckets`, `s3:GetBucketLocation`, and `s3:ListBucket` for this profile."
            }
            return "AWS permission denied. Check the selected profile and IAM permissions."
        }

        if lowercased.contains("nosuchbucket") {
            return "S3 bucket was not found. Refresh the bucket list and check the selected region/profile."
        }

        if lowercased.contains("credential") || lowercased.contains("signature") {
            return "AWS credentials are unavailable or invalid. Check `~/.aws/config` and `~/.aws/credentials`."
        }

        if lowercased.contains("region") || lowercased.contains("endpoint") {
            return "AWS region or endpoint mismatch. Check the selected region and resource location."
        }

        return description
    }

    private static func awsErrorMessage(for error: AWSErrorType) -> String {
        let code = error.errorCode
        let detail = error.message

        switch code {
        case "AccessDenied":
            return "AWS permission denied. Check the selected profile and IAM permissions."
        case "InvalidClientTokenId", "UnrecognizedClient":
            return "AWS credentials are invalid. Run `aws sso login` for the selected profile, then retry."
        case "MissingAuthenticationToken":
            return "AWS credentials are missing. Run `aws sso login` for the selected profile, then retry."
        case "RequestExpired":
            return "AWS credentials have expired. Run `aws sso login` for the selected profile, then retry."
        case "SignatureDoesNotMatch":
            return "AWS signature mismatch. Credentials may be corrupted. Run `aws sso login` to refresh."
        case "InvalidSignature":
            return "AWS request signature is invalid. Credentials may be expired. Run `aws sso login` to refresh."
        case "Throttling":
            return "AWS API rate limit reached. Wait a moment and retry."
        case "ServiceUnavailable", "InternalFailure":
            return "AWS service is temporarily unavailable. Try again later."
        default:
            if let detail, !detail.isEmpty {
                return "\(code): \(detail)"
            }
            return "AWS error: \(code)"
        }
    }

    private static func awsResponseMessage(forCode code: String, detail: String?) -> String {
        let normalized = code.lowercased()
        if normalized.contains("accessdenied") || normalized.contains("forbidden") {
            return "AWS permission denied. Check the selected profile and IAM permissions."
        }
        if normalized.contains("nosuchbucket") {
            return "S3 bucket was not found. Refresh the bucket list and check the selected region/profile."
        }
        if normalized.contains("authorizationheadermalformed") || normalized.contains("permanentredirect") {
            return "S3 region mismatch. Refresh bucket details and retry in the bucket's actual region."
        }
        if normalized.contains("invalidaccesskeyid") || normalized.contains("signaturedoesnotmatch") {
            return "AWS credentials are unavailable or invalid. Check `~/.aws/config` and `~/.aws/credentials`."
        }
        return detail ?? code
    }

    private static func s3Message(forCode code: String, detail: String?) -> String {
        switch code {
        case "AccessDenied":
            return "S3 permission denied. Check `s3:ListAllMyBuckets`, `s3:GetBucketLocation`, and `s3:ListBucket` for this profile."
        case "NoSuchBucket", "NotFound":
            return "S3 bucket was not found. Refresh the bucket list and check the selected region/profile."
        case "NoSuchKey":
            return "S3 object no longer exists at this path. Refresh the object list."
        case "InvalidRequest":
            return detail ?? "S3 rejected the request. This is often caused by bucket region or request parameter mismatch."
        default:
            return detail ?? "S3 request failed with code `\(code)`."
        }
    }
}
