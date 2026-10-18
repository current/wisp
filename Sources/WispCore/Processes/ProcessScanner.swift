import Foundation

public struct ProcessTable: Sendable {
    public init() {}
}

final class ProcessScanner {
    func scan(network: Bool) -> ProcessTable { ProcessTable() }
}
