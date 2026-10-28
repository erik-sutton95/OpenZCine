/// A single explicit endpoint-to-endpoint pass through bounded command sizes.
enum FocusRackPreparation {
    static func supports(span: Int) -> Bool { (1...10_000).contains(span) }

    static func make(signedSteps: Int) throws -> FocusRackMovementPlan {
        guard signedSteps != .min, supports(span: abs(signedSteps)) else {
            throw FocusRackError.invalidConfiguration
        }
        let sign = signedSteps < 0 ? -1 : 1
        var remaining = abs(signedSteps)
        var chunks: [Int] = []
        for quantum in [1, 2, 3, 4, 6, 8, 10, 12] where quantum <= remaining {
            chunks.append(sign * quantum)
            remaining -= quantum
        }
        while remaining > 0 {
            let quantum = min(12, remaining)
            chunks.append(sign * quantum)
            remaining -= quantum
        }
        return .init(
            signedSteps: signedSteps, chunks: chunks,
            offsets: Array(repeating: 0, count: chunks.count), duration: 0, delay: 0,
            minimumDuration: 0, maximumDuration: nil, estimatedDuration: nil)
    }
}
