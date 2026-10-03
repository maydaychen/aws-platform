import Foundation
import SotoCore
import SotoS3

enum UserFacingError {
    static func requiresSSOLogin(_ error: Error) -> Bool {
        if let error = error as? AWSSSOCredentialError {
            switch error.code {
            case "tokenCacheNotFound", "tokenExpired", "clientRegistrationExpired", "invalidTokenFormat":
                return true
            case "getRoleCredentialsFailed":
                return error.message.hasPrefix("HTTP 401:")
            default:
                return false
            }
        }
        let code = (error as? AWSResponseError)?.errorCode ?? (error as? AWSErrorType)?.errorCode
        return ["ExpiredToken", "ExpiredTokenException", "InvalidClientTokenId", "InvalidToken"].contains(code ?? "")
    }

    static func loginMessage(for error: Error, profileName: String) -> String {
        if let error = error as? AWSCLICredentialProvider.ExportError {
            return error.localizedDescription
        }
        if requiresSSOLogin(error) {
            return "AWS credentials are missing, expired or invalid. For an SSO profile, choose SSO Login; otherwise check the profile credentials."
        }
        if let error = error as? AWSSSOCredentialError {
            switch error.code {
            case "configFileNotFound", "profileNotFound", "ssoConfigMissing", "ssoSessionNotFound":
                return "SSO configuration is missing or incomplete for `\(profileName)`. Check the profile and its sso-session in the AWS config file."
            case "getRoleCredentialsFailed" where error.message.hasPrefix("HTTP 403:"):
                return "SSO access denied. Check that your user has access to this profile's account and role."
            case "tokenRefreshFailed":
                return "Unable to refresh the SSO session. Check your network and retry, or use SSO Login to authorize again."
            default:
                return "Unable to obtain SSO credentials. Check your network, SSO configuration and account permissions, then retry."
            }
        }
        if String(reflecting: type(of: error)).contains("ConfigFileLoader.ConfigFileError") {
            return "AWS profile configuration or credentials are missing or invalid for `\(profileName)`. Check the AWS config and credentials files."
        }
        let code = (error as? AWSResponseError)?.errorCode ?? (error as? AWSErrorType)?.errorCode
        if ["AccessDenied", "AccessDeniedException", "UnauthorizedException", "ForbiddenException"].contains(code ?? "") {
            return "AWS access denied. Check the selected account, role and IAM permissions."
        }
        if error is URLError {
            return "Unable to connect to AWS. Check your network, proxy and endpoint settings, then retry."
        }
        return "AWS connection validation failed for `\(profileName)`. Check your network, region and credentials, then retry."
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
