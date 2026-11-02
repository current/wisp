import Foundation
import WispCore

/// `wisp why` as plain text: the findings in order, or that nothing is wrong.
enum WhyOutput {
    static func print(_ diagnosis: Diagnosis) {
        guard !diagnosis.isHealthy else {
            Swift.print(diagnosis.summary)
            Swift.print(diagnosis.numbers.joined(separator: ", "))
            return
        }
        for (index, finding) in diagnosis.findings.enumerated() {
            Swift.print("\(index + 1). \(finding.title)")
            if !finding.detail.isEmpty { Swift.print("   \(finding.detail)") }
        }
        Swift.print()
        Swift.print(diagnosis.numbers.joined(separator: ", "))
    }
}
