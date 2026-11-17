import Foundation

/// ARC-10 generation-bound reference. Identifiers are opaque and compared by
/// UTF-8 bytes, not Swift's Unicode canonical equivalence. This value does not
/// assert that a record exists or that a storage transaction has occurred.
public struct RevisionRef: Equatable, Sendable, Codable {
    public let objectID: String
    public let storeGeneration: String
    public let revision: String

    public init(objectID: String, storeGeneration: String, revision: String) {
        self.objectID = objectID
        self.storeGeneration = storeGeneration
        self.revision = revision
    }

    public static func == (lhs: RevisionRef, rhs: RevisionRef) -> Bool {
        lhs.objectID.utf8.elementsEqual(rhs.objectID.utf8)
            && lhs.storeGeneration.utf8.elementsEqual(rhs.storeGeneration.utf8)
            && lhs.revision.utf8.elementsEqual(rhs.revision.utf8)
    }
}
