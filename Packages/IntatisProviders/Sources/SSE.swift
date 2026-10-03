import Foundation

private extension String {
    func trimmingTrailingCR() -> String {
        hasSuffix("\r") ? String(dropLast()) : self
    }
}

/// Incremental Server-Sent-Events parser. Fed arbitrary `Data` slices, it buffers
/// and emits the accumulated `data:` payload of each event when the blank-line
/// dispatch boundary is reached. Non-`data:` fields are ignored. Pure and
/// synchronous, so it is unit-tested without any network.
public final class SSEParser {
    private var buffer = Data()
    private var dataLines: [String] = []

    public init() {}

    /// Consume a chunk; returns any events completed by it (the joined `data:` text).
    public func consume(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var events: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            let line = String(decoding: lineData, as: UTF8.self).trimmingTrailingCR()
            if line.isEmpty {
                if !dataLines.isEmpty {
                    events.append(dataLines.joined(separator: "\n"))
                    dataLines.removeAll(keepingCapacity: true)
                }
            } else if line.hasPrefix("data:") {
                var value = String(line.dropFirst("data:".count))
                if value.hasPrefix(" ") { value.removeFirst() }
                dataLines.append(value)
            }
            // other SSE fields (event:, id:, retry:, comments) are ignored
        }
        return events
    }

    /// Emit any pending event at end-of-stream (some servers omit the final blank line).
    public func flush() -> [String] {
        guard !dataLines.isEmpty else { return [] }
        let event = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        return [event]
    }
}
