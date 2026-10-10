import Foundation

enum AWSRegionCatalog {
    // AWS region locations; unknown/custom region codes remain usable verbatim.
    static let locations = [
        "af-south-1": "Cape Town", "ap-east-1": "Hong Kong", "ap-east-2": "Taipei",
        "ap-northeast-1": "Tokyo", "ap-northeast-2": "Seoul", "ap-northeast-3": "Osaka",
        "ap-south-1": "Mumbai", "ap-south-2": "Hyderabad",
        "ap-southeast-1": "Singapore", "ap-southeast-2": "Sydney", "ap-southeast-3": "Jakarta",
        "ap-southeast-4": "Melbourne", "ap-southeast-5": "Malaysia",
        "ap-southeast-6": "New Zealand", "ap-southeast-7": "Thailand",
        "ca-central-1": "Canada Central", "ca-west-1": "Calgary",
        "cn-north-1": "Beijing", "cn-northwest-1": "Ningxia",
        "eu-central-1": "Frankfurt", "eu-central-2": "Zurich", "eu-north-1": "Stockholm",
        "eu-south-1": "Milan", "eu-south-2": "Spain", "eu-west-1": "Ireland",
        "eu-west-2": "London", "eu-west-3": "Paris", "eusc-de-east-1": "Germany (Sovereign Cloud)",
        "il-central-1": "Tel Aviv", "me-central-1": "UAE", "me-south-1": "Bahrain",
        "mx-central-1": "Mexico Central", "sa-east-1": "São Paulo",
        "us-east-1": "N. Virginia", "us-east-2": "Ohio", "us-west-1": "N. California", "us-west-2": "Oregon",
        "us-gov-east-1": "GovCloud US East", "us-gov-west-1": "GovCloud US West"
    ]

    static func displayName(for code: String, locale: Locale) -> String {
        guard let location = locations[code] else { return code }
        return "\(L10n.text(location, locale: locale)) · \(code)"
    }
}
