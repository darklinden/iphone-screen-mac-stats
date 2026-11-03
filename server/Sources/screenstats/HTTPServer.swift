import Foundation
import Network

/// 最小 HTTP/1.1 服务端：`NWListener` 起 TCP，一条请求一条连接。
///
/// 只认 `GET /api/stats`，其余一律 404（docs/protocol.md）。不实现 keep-alive：
/// 每次响应带 `Connection: close` 并主动关连接，省掉整个连接状态机。
final class HTTPServer {
    private let port: UInt16
    private let sampler: Sampler

    /// listener 的回调都跑在这条串行队列上，`connectionIndex` 与 `connections` 因此不用加锁。
    private let queue = DispatchQueue(label: "screenstats.http.listener")
    private var listener: NWListener?
    private var connectionIndex = 0
    /// 活着的连接。必须持有，否则 `HTTPConnection` 出了作用域就被释放，回调里的 weak self 全是 nil。
    private var connections: [Int: HTTPConnection] = [:]

    init(port: UInt16, sampler: Sampler) {
        self.port = port
        self.sampler = sampler
    }

    func start() throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw HTTPServerError.badPort(port)
        }

        let listener = try NWListener(using: .tcp, on: endpointPort)
        self.listener = listener

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                HTTPServer.log("HTTP 监听 0.0.0.0:\(self.port)")
            case .failed(let error):
                // 端口被占用等：给出原因并退出，不能静默卡死。
                HTTPServer.log("HTTP 监听失败：\(error)")
                exit(1)
            case .waiting(let error):
                HTTPServer.log("HTTP 监听暂不可用：\(error)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            let index = self.connectionIndex
            self.connectionIndex += 1
            let handler = HTTPConnection(
                connection: connection,
                sampler: self.sampler,
                index: index
            ) { [weak self] in
                // 回到 listener 队列再移除，保证 connections 只被这一条队列碰。
                guard let self else { return }
                self.queue.async { self.connections.removeValue(forKey: index) }
            }
            self.connections[index] = handler
            handler.start()
        }

        listener.start(queue: queue)
    }

    /// 启动信息与错误一律走 stderr：stdout 留给 `--dump` 的采样行，混在一起会破坏它的格式。
    static func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

enum HTTPServerError: Error, CustomStringConvertible {
    case badPort(UInt16)

    var description: String {
        switch self {
        case .badPort(let port): return "无法监听的端口：\(port)"
        }
    }
}

/// 一条连接：累积请求头 → 只解析请求行 → 回一个响应 → 关连接。
///
/// 每条连接一条串行队列，回调之间不会并发，`buffer` 与 `finished` 不需要额外加锁。
private final class HTTPConnection {
    /// 请求头上限。超过就当坏请求掐掉，避免半截请求无限吃内存。
    private static let maxRequestBytes = 8 * 1024
    /// 收不到完整请求头的超时。没有它，半开连接会一直占着 fd（验收要求「不漏连接」）。
    private static let timeout: TimeInterval = 5

    private let connection: NWConnection
    private let sampler: Sampler
    private let queue: DispatchQueue
    /// 连接结束时通知 server 把自己从活动表里摘掉。
    private let onFinish: () -> Void
    private var buffer = Data()
    private var finished = false

    init(connection: NWConnection, sampler: Sampler, index: Int, onFinish: @escaping () -> Void) {
        self.connection = connection
        self.sampler = sampler
        self.queue = DispatchQueue(label: "screenstats.http.connection.\(index)")
        self.onFinish = onFinish
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive()
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)

        // 到点还没回响应就取消连接。响应发完后 `finish()` 会变成空操作。
        queue.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            self?.finish()
        }
    }

    private func receive() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.maxRequestBytes
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error = error {
                HTTPServer.log("HTTP 连接读失败：\(error)")
                self.finish()
                return
            }

            if let data, !data.isEmpty {
                self.buffer.append(data)
                if let headerEnd = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                    self.respond(headerEnd: headerEnd)
                    return
                }
                if self.buffer.count > Self.maxRequestBytes {
                    self.send(
                        status: "400 Bad Request",
                        contentType: "text/plain; charset=utf-8",
                        body: Data("bad request".utf8)
                    )
                    return
                }
            }

            if isComplete {
                // 对端先关了、请求又不完整，没什么可回的。
                self.finish()
                return
            }
            self.receive()
        }
    }

    private func respond(headerEnd: Range<Data.Index>) {
        let head = buffer[..<headerEnd.lowerBound]
        guard let requestLine = String(data: head, encoding: .utf8)?
            .components(separatedBy: "\r\n").first else {
            self.badRequest()
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            self.badRequest()
            return
        }

        let method = String(parts[0])
        // query 忽略：`/api/stats?x=1` 按 `/api/stats` 处理——协议端点本来就不带参数。
        // 用 prefix(while:) 而不是 split(...)[0]：target 恰好是 `?` 时 split 会切出空数组
        // （默认 omittingEmptySubsequences），下标访问直接 trap 掉整个进程。
        let path = String(parts[1].prefix(while: { $0 != "?" }))

        guard method == "GET", path == "/api/stats" else {
            self.send(
                status: "404 Not Found",
                contentType: "text/plain; charset=utf-8",
                body: Data("not found".utf8)
            )
            return
        }

        guard let sample = sampler.snapshot() else {
            // listener 在第一帧之后才启动，正常到不了这里；真到了也绝不返回半截 JSON。
            HTTPServer.log("采样槽位还没有值，回 503")
            self.send(
                status: "503 Service Unavailable",
                contentType: "text/plain; charset=utf-8",
                body: Data("no sample yet".utf8)
            )
            return
        }

        do {
            let body = try StatsJSON.encode(sample)
            self.send(
                status: "200 OK",
                contentType: "application/json; charset=utf-8",
                body: body
            )
        } catch {
            HTTPServer.log("JSON 编码失败：\(error)")
            self.send(
                status: "500 Internal Server Error",
                contentType: "text/plain; charset=utf-8",
                body: Data("internal error".utf8)
            )
        }
    }

    private func badRequest() {
        send(
            status: "400 Bad Request",
            contentType: "text/plain; charset=utf-8",
            body: Data("bad request".utf8)
        )
    }

    private func send(status: String, contentType: String, body: Data) {
        guard !finished else { return }

        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        head += "Content-Length: \(body.count)\r\n\r\n"

        var response = Data(head.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { [weak self] error in
            if let error = error {
                HTTPServer.log("HTTP 响应发送失败：\(error)")
            }
            self?.finish()
        })
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        connection.cancel()
        onFinish()
    }
}
