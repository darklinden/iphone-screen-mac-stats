import Foundation

// 采集服务端：后台线程 1 Hz 采样，主线程跑 HTTP 监听。
// 里程碑与验收标准见 docs/roadmap.md，线协议见 docs/protocol.md。

let options: Options
do {
    options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error)\n\n\(usage)\n".utf8))
    exit(2)
}

// CLI 已经卡过 1...65535，这里再兜一层：`UInt16(_:)` 越界会直接崩，不能赌。
guard let port = UInt16(exactly: options.port) else {
    FileHandle.standardError.write(Data("端口超出 1...65535：\(options.port)\n".utf8))
    exit(2)
}

let sampler = Sampler(options: options)

// `run()` 阻塞不返回，放后台线程；主线程留给 `NWListener`（docs/design.md 的「架构」）。
let samplerThread = Thread { sampler.run() }
samplerThread.name = "screenstats.sampler"
samplerThread.start()

// 第一帧就绪前不起 listener，否则早到的请求只能拿到半截 JSON。
sampler.waitForFirstSample()

let server = HTTPServer(port: port, sampler: sampler)
do {
    try server.start()
} catch {
    FileHandle.standardError.write(Data("HTTP 监听启动失败：\(error)\n".utf8))
    exit(1)
}

dispatchMain()
