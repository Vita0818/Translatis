import Foundation
import Network

final class LocalResponsesServer: @unchecked Sendable {
    typealias Handler = @Sendable (
        _ requestIndex: Int,
        _ body: [String: Any]
    ) -> String

    private let listener: NWListener
    private let queue = DispatchQueue(
        label: "intatis.codex-runtime.responses-server")
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let handler: Handler
    private var storedRequests: [[String: Any]] = []
    private var startupError: Error?

    init(handler: @escaping Handler) throws {
        self.handler = handler
        self.listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.ready.signal()
            case .failed(let error):
                self.lock.lock()
                self.startupError = error
                self.lock.unlock()
                self.ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw LocalResponsesServerError.startupTimedOut
        }
        if let startupError {
            listener.cancel()
            throw startupError
        }
    }

    deinit {
        listener.cancel()
    }

    var baseURL: URL {
        get throws {
            guard let port = listener.port else {
                throw LocalResponsesServerError.portUnavailable
            }
            return URL(string: "http://127.0.0.1:\(port.rawValue)/v1")!
        }
    }

    func requests() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16 * 1_024 * 1_024
        ) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = self.completeRequest(in: buffer) {
                self.respond(to: connection, request: request)
                return
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }

    private func completeRequest(in data: Data) -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator),
              let header = String(
                data: data[..<range.lowerBound],
                encoding: .utf8) else {
            return nil
        }
        let contentLength = header
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1]
                .trimmingCharacters(in: .whitespaces)) }
            ?? 0
        let bodyStart = range.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        return data.subdata(in: bodyStart..<(bodyStart + contentLength))
    }

    private func respond(to connection: NWConnection, request: Data) {
        guard let body = try? JSONSerialization.jsonObject(with: request)
                as? [String: Any] else {
            send(
                status: "400 Bad Request",
                contentType: "application/json",
                body: #"{"error":"invalid json"}"#,
                to: connection)
            return
        }
        lock.lock()
        let index = storedRequests.count
        storedRequests.append(body)
        lock.unlock()
        let response = handler(index, body)
        send(
            status: "200 OK",
            contentType: "text/event-stream",
            body: response,
            to: connection)
    }

    private func send(
        status: String,
        contentType: String,
        body: String,
        to connection: NWConnection
    ) {
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(bodyData)
        connection.send(
            content: response,
            completion: .contentProcessed { _ in
                connection.cancel()
            })
    }
}

enum LocalResponsesServerError: Error {
    case startupTimedOut
    case portUnavailable
}

/// Minimal stateless Streamable HTTP MCP server used only to verify the
/// pinned App Server's native MCP publication and per-role disable overlay.
/// It implements the official initialize + tools/list path; no Intatis MCP
/// client or dynamic-tool translation participates in the probe.
final class LocalMCPServer: @unchecked Sendable {
    private struct Request {
        let method: String
        let body: Data
    }

    private let listener: NWListener
    private let queue = DispatchQueue(
        label: "intatis.codex-runtime.mcp-server")
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var startupError: Error?
    private var storedMethods: [String] = []

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.ready.signal()
            case .failed(let error):
                self.lock.lock()
                self.startupError = error
                self.lock.unlock()
                self.ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw LocalResponsesServerError.startupTimedOut
        }
        if let startupError {
            listener.cancel()
            throw startupError
        }
    }

    deinit { listener.cancel() }

    var endpoint: String {
        get throws {
            guard let port = listener.port else {
                throw LocalResponsesServerError.portUnavailable
            }
            return "http://127.0.0.1:\(port.rawValue)/mcp"
        }
    }

    func methods() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedMethods
    }

    func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 2 * 1_024 * 1_024
        ) { [weak self] data, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = self.completeRequest(in: buffer) {
                self.respond(to: connection, request: request)
                return
            }
            if complete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }

    private func completeRequest(in data: Data) -> Request? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator),
              let header = String(
                data: data[..<range.lowerBound],
                encoding: .utf8),
              let requestLine = header.components(
                separatedBy: "\r\n").first,
              let method = requestLine.split(separator: " ").first else {
            return nil
        }
        let contentLength = header
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap {
                $0.split(separator: ":", maxSplits: 1).last
                    .flatMap {
                        Int($0.trimmingCharacters(
                            in: .whitespaces))
                    }
            } ?? 0
        let bodyStart = range.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        return Request(
            method: String(method),
            body: data.subdata(
                in: bodyStart..<(bodyStart + contentLength)))
    }

    private func respond(
        to connection: NWConnection,
        request: Request
    ) {
        if request.method == "DELETE" {
            send(
                status: "200 OK",
                contentType: "application/json",
                body: Data("{}".utf8),
                to: connection)
            return
        }
        guard request.method == "POST",
              let object = try? JSONSerialization.jsonObject(
                with: request.body) as? [String: Any],
              let method = object["method"] as? String else {
            send(
                status: "405 Method Not Allowed",
                contentType: "application/json",
                body: Data("{}".utf8),
                to: connection)
            return
        }
        lock.lock()
        storedMethods.append(method)
        lock.unlock()
        guard let id = object["id"] else {
            send(
                status: "202 Accepted",
                contentType: "application/json",
                body: Data(),
                to: connection)
            return
        }
        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": "2025-06-18",
                "capabilities": [
                    "tools": ["listChanged": false],
                ],
                "serverInfo": [
                    "name": "intatis-native-mcp-probe",
                    "version": "1.0.0",
                ],
            ]
        case "tools/list":
            result = [
                "tools": [[
                    "name": "native_mcp_probe",
                    "description": "Native MCP scoping probe.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [:],
                        "additionalProperties": false,
                    ],
                ]],
            ]
        case "tools/call":
            result = [
                "content": [[
                    "type": "text",
                    "text": "native MCP probe completed",
                ]],
                "isError": false,
            ]
        default:
            result = [:]
        }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ]
        let body = (try? JSONSerialization.data(
            withJSONObject: response,
            options: [.sortedKeys])) ?? Data("{}".utf8)
        send(
            status: "200 OK",
            contentType: "application/json",
            body: body,
            to: connection)
    }

    private func send(
        status: String,
        contentType: String,
        body: Data,
        to connection: NWConnection
    ) {
        let header = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(
            content: response,
            completion: .contentProcessed { _ in
                connection.cancel()
            })
    }
}

func responsesSSE(_ payloads: [String]) -> String {
    payloads.map { "data: \($0)\n\n" }.joined()
        + "data: [DONE]\n\n"
}

func responsesMessageSSE(
    responseID: String,
    messageID: String,
    model: String,
    text: String
) -> String {
    let item = """
    {"id":"\(messageID)","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"\(text)","annotations":[]}]}
    """
    return responsesSSE([
        "{\"type\":\"response.created\",\"response\":{\"id\":\"\(responseID)\",\"status\":\"in_progress\",\"model\":\"\(model)\",\"output\":[]}}",
        "{\"type\":\"response.output_text.delta\",\"item_id\":\"\(messageID)\",\"output_index\":0,\"content_index\":0,\"delta\":\"\(text)\"}",
        "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":\(item)}",
        "{\"type\":\"response.completed\",\"response\":{\"id\":\"\(responseID)\",\"status\":\"completed\",\"model\":\"\(model)\",\"output\":[\(item)],\"usage\":{\"input_tokens\":10,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":2,\"output_tokens_details\":{\"reasoning_tokens\":0},\"total_tokens\":12}}}",
    ])
}
