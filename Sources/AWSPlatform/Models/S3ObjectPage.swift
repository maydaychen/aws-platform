import Foundation

struct S3ObjectPage {
    let objects: [S3ObjectModel]
    var nextContinuationToken: String? = nil
}

struct S3Breadcrumb: Identifiable, Equatable {
    let name: String
    let prefix: String

    var id: Data { Data(prefix.utf8) }
    var isRoot: Bool { prefix.isEmpty }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    static func path(for prefix: String) -> [S3Breadcrumb] {
        var result = [S3Breadcrumb(name: "", prefix: "")]
        var start = prefix.startIndex
        // S3 prefixes are literal keys, not filesystem paths. Keep every slash.
        for index in prefix.unicodeScalars.indices where prefix.unicodeScalars[index] == "/" {
            let end = prefix.unicodeScalars.index(after: index)
            result.append(.init(name: String(prefix[start..<index]), prefix: String(prefix[..<end])))
            start = end
        }
        if start < prefix.endIndex {
            result.append(.init(name: String(prefix[start...]), prefix: prefix))
        }
        return result
    }
}

enum S3PaginationError: LocalizedError {
    case invalidContinuation

    var errorDescription: String? {
        "S3 returned an invalid page token. Retry this page or refresh the directory."
    }
}
