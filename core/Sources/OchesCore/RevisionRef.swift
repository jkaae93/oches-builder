import Foundation

/// ARC-10 generation-bound reference. Identifiers are opaque and compared by
/// UTF-8 bytes, not Swift's Unicode canonical equivalence. This value does not
/// assert that a record exists or that a storage transaction has occurred.
struct RevisionRef: Equatable, Sendable {
    let objectID: String
    let storeGeneration: String
    let revision: String

    static func == (lhs: RevisionRef, rhs: RevisionRef) -> Bool {
        lhs.objectID.utf8.elementsEqual(rhs.objectID.utf8)
            && lhs.storeGeneration.utf8.elementsEqual(rhs.storeGeneration.utf8)
            && lhs.revision.utf8.elementsEqual(rhs.revision.utf8)
    }
}
