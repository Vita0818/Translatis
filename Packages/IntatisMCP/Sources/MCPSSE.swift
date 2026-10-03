import Foundation

struct MCPSSEEvent: Equatable, Sendable {
    let id: String?
    let event: String?
    let data: Data?
    let retryMilliseconds: Int?
}

/// State belongs to one concrete HTTP stream, never to the whole connection.
/// The bounded delivered-ID window prevents redelivery while avoiding an
/// attacker-controlled unbounded set.
final class MCPSSEStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private let limits: MCPHTTPTransportLimits
    private var lastProcessedEventIDValue: String?
    private var retryMillisecondsValue = 3_000
    private var deliveredIDs: Set<String> = []
    private var deliveredIDOrder: [String] = []
    private var totalBytes = 0

    init(limits: MCPHTTPTransportLimits) {
        self.limits = limits
    }

    var lastProcessedEventID: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastProcessedEventIDValue
    }

    var retryMilliseconds: Int {
        lock.lock()
        defer { lock.unlock() }
        return retryMillisecondsValue
    }

    func account(bytes: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        guard bytes >= 0, totalBytes <= limits.maximumSSEStreamBytes - bytes else {
            throw MCPHTTPTransportError.sseStreamTooLarge
        }
        totalBytes += bytes
    }

    /// Returns false for a redelivered event ID.
    func accept(_ event: MCPSSEEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let retry = event.retryMilliseconds {
            retryMillisecondsValue = min(
                limits.maximumRetryMilliseconds,
                max(limits.minimumRetryMilliseconds, retry))
        }

        guard let id = event.id, !id.isEmpty else { return true }
        lastProcessedEventIDValue = id
        if deliveredIDs.contains(id) {
            return false
        }
        deliveredIDs.insert(id)
        deliveredIDOrder.append(id)
        if deliveredIDOrder.count > 4_096 {
            let removalCount = deliveredIDOrder.count - 4_096
            let removed = Array(deliveredIDOrder.prefix(removalCount))
            deliveredIDOrder.removeFirst(removalCount)
            deliveredIDs.subtract(removed)
        }
        return true
    }
}

final class MCPSSEParser: @unchecked Sendable {
    private let lock = NSLock()
    private let limits: MCPHTTPTransportLimits
    private let state: MCPSSEStreamState
    private var buffer = Data()
    private var eventDataLines: [Data] = []
    private var eventID: String?
    private var eventName: String?
    private var eventRetry: Int?

    init(
        limits: MCPHTTPTransportLimits,
        state: MCPSSEStreamState
    ) {
        self.limits = limits
        self.state = state
    }

    func feed(_ data: Data) throws -> [MCPSSEEvent] {
        lock.lock()
        defer { lock.unlock() }
        try state.account(bytes: data.count)
        guard buffer.count <= limits.maximumSSEFrameBytes - data.count else {
            throw MCPHTTPTransportError.sseFrameTooLarge
        }
        buffer.append(data)

        var events: [MCPSSEEvent] = []
        while let lineRange = nextLineRange(in: buffer) {
            let line = buffer.subdata(in: 0..<lineRange.lowerBound)
            buffer.removeSubrange(0..<lineRange.upperBound)
            if let event = try consumeLine(line), state.accept(event) {
                events.append(event)
            }
        }
        return events
    }

    func finish() throws -> [MCPSSEEvent] {
        lock.lock()
        defer { lock.unlock() }
        var events: [MCPSSEEvent] = []
        if !buffer.isEmpty {
            let line = buffer
            buffer.removeAll(keepingCapacity: false)
            if let event = try consumeLine(line), state.accept(event) {
                events.append(event)
            }
        }
        if let event = try dispatchEvent(), state.accept(event) {
            events.append(event)
        }
        return events
    }

    private func consumeLine(_ raw: Data) throws -> MCPSSEEvent? {
        var line = raw
        if line.last == 0x0D { line.removeLast() }
        guard line.count <= limits.maximumSSEFrameBytes else {
            throw MCPHTTPTransportError.sseFrameTooLarge
        }
        if line.isEmpty {
            return try dispatchEvent()
        }
        if line.first == 0x3A { return nil } // comment

        let separator = line.firstIndex(of: 0x3A)
        let fieldData = separator.map { line[..<$0] } ?? line[...]
        guard let field = String(data: fieldData, encoding: .utf8) else {
            throw MCPHTTPTransportError.malformedSSE
        }
        var value = Data()
        if let separator {
            let start = line.index(after: separator)
            if start < line.endIndex {
                value = line.subdata(in: start..<line.endIndex)
                if value.first == 0x20 { value.removeFirst() }
            }
        }

        switch field {
        case "data":
            let accumulated = eventDataLines.reduce(0) { $0 + $1.count + 1 }
            guard accumulated <= limits.maximumSSEFrameBytes - value.count else {
                throw MCPHTTPTransportError.sseFrameTooLarge
            }
            eventDataLines.append(value)
        case "id":
            guard !value.contains(0),
                  let id = String(data: value, encoding: .utf8) else {
                throw MCPHTTPTransportError.malformedSSE
            }
            eventID = id
        case "event":
            guard let name = String(data: value, encoding: .utf8) else {
                throw MCPHTTPTransportError.malformedSSE
            }
            eventName = name
        case "retry":
            guard let string = String(data: value, encoding: .utf8),
                  !string.isEmpty,
                  string.allSatisfy(\.isNumber),
                  let retry = Int(string) else {
                return nil
            }
            eventRetry = retry
        default:
            break
        }
        return nil
    }

    private func dispatchEvent() throws -> MCPSSEEvent? {
        defer {
            eventDataLines.removeAll(keepingCapacity: true)
            eventID = nil
            eventName = nil
            eventRetry = nil
        }

        guard !eventDataLines.isEmpty || eventRetry != nil || eventID != nil else {
            return nil
        }
        let data: Data?
        if eventDataLines.isEmpty {
            data = nil
        } else {
            var joined = Data()
            for (index, line) in eventDataLines.enumerated() {
                if index > 0 { joined.append(0x0A) }
                joined.append(line)
            }
            guard joined.count <= limits.maximumSSEFrameBytes else {
                throw MCPHTTPTransportError.sseFrameTooLarge
            }
            data = joined
        }
        return MCPSSEEvent(
            id: eventID,
            event: eventName,
            data: data,
            retryMilliseconds: eventRetry)
    }

    private func nextLineRange(in data: Data) -> Range<Data.Index>? {
        guard let newline = data.firstIndex(of: 0x0A) else { return nil }
        return newline..<data.index(after: newline)
    }
}
