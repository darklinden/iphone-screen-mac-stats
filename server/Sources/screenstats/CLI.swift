import Foundation

/// 服务端配置**只走命令行参数**，没有配置文件；launchd plist 里写死参数。
/// 见 docs/design.md 的「进程形态」。
struct Options {
    var dump = false
    var port = 8737
    var iface = "en0"
    /// 调试用：跑满这么多秒后停掉采集循环，用来验证客户端的「停更」状态。
    var freezeAfter: Int?
}

let usage = """
用法：screenstats [选项]

  --dump              每秒往 stdout 打印一行人类可读的采样
  --port <端口>        HTTP 监听端口（默认 8737）
  --iface <接口名>     被统计的网卡（默认 en0）
  --freeze-after <秒>  跑满这么多秒后停掉采集循环，但进程不退
  -h, --help          显示这段说明
"""

enum CLIError: Error, CustomStringConvertible {
    case unknownOption(String)
    case missingValue(String)
    case badValue(option: String, value: String)
    case portOutOfRange(String)

    var description: String {
        switch self {
        case .unknownOption(let name):
            return "不认识的选项：\(name)"
        case .missingValue(let name):
            return "\(name) 后面缺一个值"
        case .badValue(let option, let value):
            return "\(option) 的值不是正整数：\(value)"
        case .portOutOfRange(let value):
            return "--port 超出 1...65535：\(value)"
        }
    }
}

func parseArguments(_ args: [String]) throws -> Options {
    var options = Options()
    var index = 0

    while index < args.count {
        let arg = args[index]
        index += 1

        func takeValue() throws -> String {
            guard index < args.count else { throw CLIError.missingValue(arg) }
            defer { index += 1 }
            return args[index]
        }

        func takePositiveInt() throws -> Int {
            let raw = try takeValue()
            guard let value = Int(raw), value > 0 else {
                throw CLIError.badValue(option: arg, value: raw)
            }
            return value
        }

        switch arg {
        case "--dump":
            options.dump = true
        case "--port":
            let port = try takePositiveInt()
            // 端口最终要转 UInt16；在这里拦下越界值，别留到后面强转时崩。
            guard port <= 65535 else { throw CLIError.portOutOfRange(String(port)) }
            options.port = port
        case "--iface":
            options.iface = try takeValue()
        case "--freeze-after":
            options.freezeAfter = try takePositiveInt()
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            throw CLIError.unknownOption(arg)
        }
    }

    return options
}
