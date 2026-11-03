import Foundation

/// 指标区的五种显示状态（docs/design.md 的「五种显示状态」）。
///
/// 失联与停更是**两种不同的故障**：前者是链路或服务端进程挂了，后者是服务端
/// 活着但采集循环卡住了。角落文案是排障时唯一能区分二者的线索，所以不合并。
enum MetricsState: Equatable {
    /// 最近一次请求成功且 `seq` 在前进
    case normal
    /// 连续 3 次请求失败（含非 200、解码失败）
    case unreachable(seconds: Int)
    /// 请求成功，但 `seq` 连续 3 秒没变
    case stale(seconds: Int)
    /// `ServerConfig.load()` 返回 nil
    case unconfigured
}

/// 1 Hz 轮询 `GET /api/stats`，维护上面的状态机。
///
/// 节奏与判据见 docs/design.md 的「轮询节奏」与「五种显示状态」：
/// - 间隔 1 秒，单次请求超时 0.8 秒，失败后不退避，按原节奏排下一次；
/// - 判据用 `seq` 而不是服务端 `ts`；
/// - `seq` 变小 = 服务端重启，重置基线，**不**判失联；
/// - 任何非 200 响应一律按「请求失败」处理，不为 400/500/503 加新状态。
///
/// 本类只跑网络与状态，不碰 UI；定时器在 main 队列，与时钟定时器彼此独立。
final class StatsPoller {

    /// 拿到一条成功采样的回调
    var onStats: ((StatsResponse) -> Void)?
    /// 状态回调（每个 tick 都会回调一次，便于刷新「失联 Ns」的秒数）
    var onState: ((MetricsState) -> Void)?

    /// 轮询间隔（design.md：1 秒）
    private let interval: DispatchTimeInterval = .seconds(1)
    /// 单次请求超时（design.md：0.8 秒）
    private let requestTimeout: TimeInterval = 0.8
    /// 连续失败多少次判失联
    private let failureThreshold = 3
    /// `seq` 连续多少秒没变判停更
    private let staleThreshold: TimeInterval = 3

    private let session: URLSession
    private let decoder = JSONDecoder()

    private var timer: DispatchSourceTimer?
    private var config: ServerConfig?

    /// 每次 `start()` 递增，用来丢弃配置变更前发出的旧请求的结果
    private var generation = 0
    /// 上一次请求是否还在飞；在飞就跳过本轮，避免请求叠加
    private var inFlight = false

    private var failureCount = 0
    private var firstFailureUptime: TimeInterval?
    private var lastSuccessUptime: TimeInterval?
    private var lastSeq: Int?
    private var lastSeqChangeUptime: TimeInterval?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        // 必须关掉：否则请求会一直挂着等网络可用，0.8 秒超时不会按预期触发。
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    deinit {
        stop()
    }

    // MARK: - 生命周期

    /// 启动轮询。每次都重新读一次配置，所以 M5 改完设置后调用本方法即可生效。
    func start() {
        stop()
        reset()
        config = ServerConfig.load()
        guard config != nil else {
            publish(.unconfigured)
            return
        }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        source.resume()
        timer = source
    }

    /// 停止轮询（不改变当前显示状态）
    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - 一次轮询

    private func tick() {
        guard let config = config else {
            publish(.unconfigured)
            return
        }
        // 上一次还没回来：本轮跳过。定时器节奏不变，下个整秒再试。
        guard !inFlight else { return }
        guard let url = config.statsURL else {
            recordFailure()
            return
        }

        inFlight = true
        let requestGeneration = generation
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handle(data: data, response: response, error: error, generation: requestGeneration)
            }
        }.resume()
    }

    private func handle(data: Data?, response: URLResponse?, error: Error?, generation requestGeneration: Int) {
        // 配置已经变过：这次的结果作废
        guard requestGeneration == generation else { return }
        inFlight = false

        guard error == nil,
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let data = data,
              let stats = try? decoder.decode(StatsResponse.self, from: data)
        else {
            // 网络错误、非 200、解码失败，一律按请求失败处理
            recordFailure()
            return
        }
        recordSuccess(stats)
    }

    // MARK: - 状态机

    private func recordSuccess(_ stats: StatsResponse) {
        failureCount = 0
        firstFailureUptime = nil

        let now = uptime()
        lastSuccessUptime = now

        if let last = lastSeq {
            if stats.seq == last {
                // seq 没前进：交给下面的停更判据
            } else {
                // seq 前进，或变小（服务端重启）——两种都重置基线。
                // 变小不判失联，也不判停更。
                lastSeq = stats.seq
                lastSeqChangeUptime = now
            }
        } else {
            lastSeq = stats.seq
            lastSeqChangeUptime = now
        }

        onStats?(stats)

        if let changedAt = lastSeqChangeUptime, now - changedAt >= staleThreshold {
            publish(.stale(seconds: Int(now - changedAt)))
        } else {
            publish(.normal)
        }
    }

    private func recordFailure() {
        failureCount += 1
        let now = uptime()
        if failureCount == 1 {
            firstFailureUptime = now
        }

        // 还没到 3 次：保持正常，继续显示上一份数据
        guard failureCount >= failureThreshold else {
            publish(.normal)
            return
        }

        // N = 距上一次成功有多久；从未成功过就从第一次失败算起
        let since = lastSuccessUptime ?? firstFailureUptime ?? now
        publish(.unreachable(seconds: Int(max(0, now - since))))
    }

    private func publish(_ state: MetricsState) {
        onState?(state)
    }

    private func reset() {
        generation += 1
        inFlight = false
        failureCount = 0
        firstFailureUptime = nil
        lastSuccessUptime = nil
        lastSeq = nil
        lastSeqChangeUptime = nil
    }

    /// 单调时钟，不受墙钟调整影响
    private func uptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
