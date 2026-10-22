import Foundation

struct DirectHostRequests {
    private var line = Data()
    private var discarding = false

    mutating func receive(_ data: Data) -> [Int] {
        var requests: [Int] = []
        for byte in data {
            if byte == 10 {
                if !discarding {
                    let text = String(decoding: line, as: UTF8.self)
                    for prefix in ["NEWT_REQUEST:", "PIPPINVR_REQUEST:"] where text.hasPrefix(prefix) {
                        let suffix = String(text.dropFirst(prefix.count))
                        if let request = Int(suffix), String(request) == suffix,
                           (1...4).contains(request) || request >= 100 {
                            requests.append(request)
                        }
                    }
                }
                line.removeAll(keepingCapacity: true)
                discarding = false
            } else if !discarding {
                if line.count < 4096 { line.append(byte) } else { line.removeAll(keepingCapacity: true); discarding = true }
            }
        }
        return requests
    }
}
