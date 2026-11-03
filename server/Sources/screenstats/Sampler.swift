import Foundation

/// 1 Hz 采样循环。
///
/// 采集与 HTTP 解耦：循环只往 `latestSample` 这个「最新采样槽位」里写，请求来了读那个槽位。
/// 这样采集节奏与请求节奏互不干扰，多个客户端也不会让采集重复跑（docs/design.md 的「架构」）。
final class Sampler {
    private let options: Options

    private let cpu = CPUReader()
    private let ram = RAMReader()
    private let gpu = GPUReader()
    private let disk = DiskReader()
    private let net: NetReader

    /// 最新采样槽位。采集线程写、HTTP 连接队列读，所以读写都要过 `latestLock`。
    private let latestLock = NSLock()
    private var latestSample: Sample?

    /// 第一帧就绪的信号。`main` 要等它才起 listener，避免请求拿到半截数据。
    private let firstSampleReady = DispatchSemaphore(value: 0)

    /// 从 0 起，每采样一次 +1；服务端重启后归零（docs/protocol.md）。
    private var seq = 0

    init(options: Options) {
        self.options = options
        self.net = NetReader(iface: options.iface)
    }

    /// 线程安全的快照。拿不到时返回 nil，绝不返回写了一半的数据。
    func snapshot() -> Sample? {
        latestLock.lock()
        defer { latestLock.unlock() }
        return latestSample
    }

    /// 阻塞到第一帧写入槽位。`main` 在起 `NWListener` 之前调它。
    func waitForFirstSample() {
        firstSampleReady.wait()
    }

    /// 跑采样循环，不返回。
    ///
    /// M2 起它在后台线程上跑（`main` 里开 `Thread`），主线程留给 `NWListener`。
    func run() {
        let start = monotonicNanoseconds()
        var tick = 0

        while true {
            if let freezeAfter = options.freezeAfter, tick >= freezeAfter {
                // 采集循环停住，latest 停在最后一帧 —— 客户端应判「停更」而不是「失联」。
                // 只停采集、不退进程，M2 起 HTTP 监听还在跑。
                while true { Thread.sleep(forTimeInterval: 60) }
            }

            let sample = sampleOnce()
            latestLock.lock()
            latestSample = sample
            latestLock.unlock()
            if tick == 0 {
                firstSampleReady.signal()
            }

            if options.dump {
                print(Dump.line(for: sample))
                fflush(stdout)
            }

            tick += 1
            sleepUntil(start + UInt64(tick) * 1_000_000_000)
        }
    }

    /// 采一帧。任何一项读不到就是 nil，不拿 0 顶替。
    private func sampleOnce() -> Sample {
        let cpuTotal = cpu.read()
        let gpuUtil = gpu.read()
        let memUsed = ram.readUsed()
        let diskRates = disk.read()
        let netRates = net.read()

        let sample = Sample(
            seq: seq,
            ts: Date().timeIntervalSince1970,
            cpuTotal: cpuTotal,
            gpuUtil: gpuUtil,
            memTotalBytes: ram.totalBytes,
            memUsedBytes: memUsed,
            diskReadBps: diskRates.readBps,
            diskWriteBps: diskRates.writeBps,
            netIface: net.iface,
            netRxBps: netRates?.rxBps,
            netTxBps: netRates?.txBps
        )
        seq += 1
        return sample
    }

    /// 睡到指定时刻，避免 `sleep(1)` 累积漂移。
    private func sleepUntil(_ deadline: UInt64) {
        let now = monotonicNanoseconds()
        guard deadline > now else { return }
        Thread.sleep(forTimeInterval: Double(deadline - now) / 1_000_000_000)
    }
}
