# iphone-screen-stats

把常亮、长期插电的 iPhone SE（第一代，4 寸）变成 Mac mini 的状态副屏。仓库里有两个进程：Mac 上的 Swift 采集**服务端**（`server/`），iPhone 上的原生 iOS **客户端**（`ios/`）。两者之间只有一条 HTTP 轮询契约。术语见 [GLOSSARY.md](GLOSSARY.md)。

## 按任务找文档

| 你要做的事 | 读这个 |
|---|---|
| 改采集逻辑、加一个指标 | [docs/design.md](docs/design.md) 的「采集实现映射」 |
| 改线协议、加字段 | [docs/protocol.md](docs/protocol.md) |
| 改界面布局、动翻页时钟代码 | [docs/design.md](docs/design.md) 的「界面规格」 |
| 动手写代码 | [docs/roadmap.md](docs/roadmap.md) |
| 问某个决定为什么是这样 | [docs/adr/](docs/adr/) |

## 硬约束

- 客户端 deployment target **iOS 15.0**；目标设备是 **iPhone SE 第一代**（ProductType `iPhone8,4`，4 寸，横屏 **568×320 pt / 1136×640 px @2x**）/ iOS 15.8.8；**只支持横屏**。机型是实测出来的（`pymobiledevice3 developer screenshot` 量的分辨率），早期文档里写的「SE2 / 667×375」是错的，已全部改正。
- 客户端 bundle identifier 是 `com.darklinden.screenstats`，用**免费开发者账号**签名，provisioning **每 7 天过期**。续签由 `resign.sh` + launchd 任务 `com.darklinden.screenstats.resign` 自动做，依赖 **iPhone 长期插在 Mac mini 的 USB 口上**。真机操作分两个工具，**别混用**：**装**用 `ios-deploy`（`brew` 装在 `/opt/homebrew/bin`）；**拉起 App 必须用 `pymobiledevice3 developer dvt launch`**（装在 `~/Library/Application Support/iphone-screen-stats/venv`，由 `make resign-deps` 创建）——`ios-deploy` 是**用调试器**启动 App 的，命令一退 App 就被系统回收，根本留不住（`--justlaunch` / `-I` / `-N` 三种模式都实测过）。`xcrun devicectl` 只服务 iOS 17+，对这台 iOS 15.8.8 直接报 `CoreDeviceError error 1000`。工具链选型的完整理由（含排除项与推翻条件）见 [ADR-0005](docs/adr/0005-ios-deploy-install-plus-dvt-launch.md)；动 bundle id 或签名配置之前先读 [ADR-0001](docs/adr/0001-native-ios-app-over-web.md)。
- 服务端**只统计 `en0` 与内置启动盘**，其它接口与卷不进读数。
- 采样固定 **1 Hz**，传输固定 **HTTP 轮询**。
- 服务端**零第三方依赖**，HTTP 层用 `Network.framework` 手写。（`ios-deploy` 与 `pymobiledevice3` 是**开发机**上的真机部署工具，不算服务端依赖。）
- 百分比一律 0.0–1.0 的 Double，速率一律 bytes/s 的 Int，读不到用 `null`。细节在 [docs/protocol.md](docs/protocol.md)。
- 客户端的服务器地址**只经** `ios/ScreenStats/ServerConfig.swift` 一处读 `UserDefaults`（键名 `serverHost` / `serverPort`，端口缺省 8737）。M5 的设置页写同样两个键，别另起一套。
- 采集逻辑从 exelban/stats 的 reader **逐段照搬**，连同原注释与出处行号一起搬，方便日后对照上游。映射表在 [docs/design.md](docs/design.md)。

## 参考项目

两个仓库都只做参考，所有改动都发生在本仓库内：

- `/opt/home/Github/stats/` — exelban/stats。服务端采集逻辑照搬自它的 `Modules/*/reader*.swift`（注意 GPU 是单数的 `GPU/reader.swift`）。
- `/opt/home/Github/flipClock/` — 你自己的翻页时钟 iOS App。客户端以它为起点：把需要的文件**复制**进 `ios/` 之后再改。
  只按 [docs/design.md](docs/design.md) 「从 flipClock 复用与改动」那张表**逐个文件**复制，不要整目录 `cp -R`：`ios/ScreenStats/` 是 Xcode 的同步目录（`PBXFileSystemSynchronizedRootGroup`），丢进去的每个 `.swift` 都会自动进编译、每个资源都会自动进 bundle，而且工程里没有排除名单。整目录复制会带进 flipClock 自己的 `AppDelegate`（与本仓库的重复定义）和明确不要的 `SoundManager` + `.wav`。

## 命令

仓库根的 `Makefile` 是唯一命令入口，别绕过它直接敲 `swift build` / `xcodebuild`：

- `make server` / `make server ARGS=--dump` —— 前台跑服务端
- `make ios` / `make ios-device` —— 装进模拟器 / 真机
- `make service-install`、`service-start`、`service-stop`、`service-status`、`service-logs`、`service-uninstall` —— 服务端 launchd 自启
- `make service-resign-install` 等 —— 客户端续签任务，后缀同上一组

根目录的 `start.sh` / `stop.sh` 是 `make service-install` / `make service-stop` 的**薄包装**，逻辑一份都没重复——它们存在只是因为写 `~/Library` 和 `launchctl bootstrap` 在 agent 沙箱里会被挡住，必须由人执行。`resign.sh` 由 launchd 调用，也可以手动跑：`./resign.sh` 没到期就空转，`./resign.sh --force` 强制重签重装。
