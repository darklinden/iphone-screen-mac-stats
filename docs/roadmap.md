# 实施顺序

每个里程碑都以一条**可验证的验收标准**收尾。上一步的验收没过，不进下一步。

## M0 — 骨架与契约冻结

建 `server/`（SwiftPM 可执行 target）、`ios/`（Xcode 工程，从 flipClock 复制所需文件）、仓库根的 `Makefile`。

**验收**：`make server` 能编译出可执行文件并打印 `hello`；`make ios` 能在模拟器里跑起来。（`hello` 是当时的脚手架，M1 起 `make server` 改成跑真正的采集循环，`make server ARGS=--dump` 看读数。）

**已完成**。`make server` 编译通过；`make ios` 在 iPhone 16 模拟器（iOS 18.6）上编译、安装、启动成功，截图确认只渲染横屏。真机验证归 M6。

## M1 — 采集跑通

按 [design.md](design.md) 的「采集实现映射」表实现全部 5 项采集，接上 `--dump`。

**验收**：终端跑 `server --dump`，一边用浏览器播视频、一边 `dd` 写大文件，肉眼看到 GPU / 网络 / 磁盘读数跟着动；全部空闲时 CPU 掉到个位数。**每一项指标都必须至少见过一次非零值**（速率项在第一次采样后为 `null` 不算通过）。

**已完成**。5 项都见过非零值：空闲 CPU 6.6–8%、负载下 20.2%；GPU 0% → 96–99%（Metal 计算负载）→ 回落 0%；MEM 11.6–12.0 GB；磁盘 R 22.2 MB/s、W 19.0 MB/s；网络 en0 在局域网 ping 洪泛下 ↓186 → 320 KB/s、↑2.0 → 134.3 KB/s。首帧速率项显示 `--`。

> 两点保留，都跟「验收是不是照原样跑的」有关：
>
> 1. 验收里写的 `dd` 在本会话不可用，磁盘读写是走别的写入路径看到的非零值，没照原样跑。
> 2. **`--iface en0` 能否看见走代理出去的公网流量，尚未确认。** 本机公网流量经 `utun4`（`128.0/1 → 198.18.0.0`），en0 目前只在局域网流量下验过。若公网流量确实不上 en0，[design.md](design.md) 的「只统计 en0」会低估网络读数，需要重新考虑——顺带一提，design.md 的排除名单写的是 `utun0-3`，本机实际有 `utun4`。

## M2 — HTTP 端点

`NWListener` + 最小 HTTP/1.1，读最新采样槽位。

**验收**：`curl -s localhost:8737/api/stats | python3 -m json.tool` 输出符合 [protocol.md](protocol.md)；连打 20 次不崩、不漏连接；`seq` 递增；`curl -i localhost:8737/nope` 返回 `404` 与纯文本 `not found`；**畸形请求行打不崩进程**。

> 最后一条是事后补的：原验收只打 `/api/stats` 和 `/nope`，漏掉了 request-target 为单个 `?` 的请求行——它会让 `String.split` 切出空数组、下标越界 trap 掉整个进程。服务端监听 `0.0.0.0` 且不鉴权，局域网内谁都能触发。

**已完成**。原验收之外还实测了三条：局域网 IP 路径 `http://<Mac 的局域网 IP>:8737/api/stats`（这才是 iPhone 走的真实路径，只测 `localhost` 测不出监听范围的问题）；`--dump` 与 HTTP 共存、`--freeze-after` 与 HTTP 共存（冻结后仍 `200` 且 `seq` 不动，M4 验「停更」依赖它）；半截请求 5 秒后被关掉、`lsof` 无残留连接。协议只定义了 `200` / `404`；实现另有三个正常不可达的兜底状态码，都不在契约内：请求行畸形回 `400`，JSON 编码失败回 `500`，采样槽位为空回 `503`（listener 在首帧就绪后才起，正常到不了）。

## M3 — 客户端骨架

翻页时钟在 `ios/` 里跑起来：横屏、年月日与星期都在、没有底部工具栏、没有音效。

**验收**：真机上时钟走时准确、翻页动画流畅；长按 2 秒能弹出设置页。

**已完成（仅模拟器）**。翻页时钟跑起来了：横屏、`星期二`、`2026年11月3日`、无底部工具栏、无音效（源码与产物里都没有 `SoundManager` / `AudioToolbox` / `.wav`）；长按 2 秒弹出设置占位页（用 `CGEvent` 合成按下→保持 2.6 秒→抬起实测，不是从代码推断）。`ios/` 现有 11 个 Swift 文件 1097 行。

> **验收还欠一条**：「真机上时钟走时准确、翻页动画流畅」**还没正式验**。M6 已把 App 装到真机并跑起来（实机画面见 M6 的截图记录），但「走时准不准、动画顺不顺」是主观判断，留到 M7 整日验收一起看。
>
> 另外记一笔：`design.md` 的复用表原先漏了 `Localizations/` 目录，导致中文本地化没搬进来——星期显示 `Tues`、日期显示 `11 / 3 / 2026`，**真机是中文也一样**。已补进复用表并修好。

## M4 — 指标区渲染

`MetricsPanelView` + 1 Hz 轮询 + 失联 / 停更 / 未配置三种状态。

**验收**：真机上指标区每秒更新，三种故障态逐一见证——
- **失联**：拔掉 Mac 网线，3 秒内指标区变暗并显示 `--`、角落标 `失联`、时钟继续走；插回网线，3 秒内自动恢复。
- **停更**：服务端带 `--freeze-after 10` 启动，10 秒后角落应标 `停更` 而不是 `失联`。
- **未配置**：清掉 App 的 `UserDefaults` 重开，指标区显示 `未配置服务器`，时钟照常走。

**已完成（仅模拟器）**。`MetricsPanelView` 343 行、`StatsPoller` 214 行、`StatsModels` 64 行、`ServerConfig` 36 行，`DashboardViewController` 扩到 127 行；`ios/` 现共 15 个 Swift 文件 1797 行。

三条故障态在 iPhone 16 模拟器上逐一见证（**编排者独立复核过，不是采信实现者的自述**）：

- **失联**：kill 掉服务端后 `失联 3s` 首现于 **2.63 秒**（≤3 秒达标）；期间秒位跨 8.1 秒走满 8 秒，**时钟照常走**；重启服务端后**首帧 1.46 秒**标签即消失。
- **停更**：`--freeze-after 10` 启动，**12.67 秒**时角落出现 `停更 3s`，全程未出现「失联」。
- **未配置**：清掉 `serverHost` / `serverPort` 后重开，指标区居中显示 `未配置服务器`，时钟照常走。

验收之外，另用一个**假服务端**做了确定性验证（比抢时间窗可靠）：只把 `gpu.util` / `disk.read_bps` / `net.tx_bps` 置 `null`，则这三项显示 `--`，而 CPU 42% / MEM 76% / DISK W 3.0 MB/s / NET ↓ 8.0 MB/s 照常渲染，**且不出现故障标签**；把 `seq` 从 100 打到 5，面板照常渲染，**既无失联也无停更**。

> **验收还欠一条**：原文要求「**真机上**」，但 `make ios` 的 destination 是 iOS 模拟器。真机渲染、性能、字号，以及**本地网络权限弹窗**那条路径（TN3179 明说模拟器不支持），都要等 M6 上真机后重验。
>
> **两处排查记录**，写下来免得日后被当成缺陷重复追：
>
> 1. 曾怀疑 `FlipClockView` 会画到自己 `bounds` 之外压住指标区。**实测不成立**：时钟带顶边 `y = 480px`（160pt）以上非黑像素数为 **0**，卡片纵向落在 174–378pt，安稳待在 160–393pt 的带内。`DashboardViewController` 里那句 `flipClock.clipsToBounds = true` 无害，但它修的不是一个真实存在的问题——**别把它当「修复 M3 缺陷」记。**
> 2. 曾怀疑「失联」计数以约 2 秒为台阶跳变（并猜是 `StatsPoller` 的 `inFlight` 守卫跳过了 tick）。**是采样混叠，不是缺陷**：以 0.61 秒间隔采样时计数严格每秒 +1；以 1.265 秒间隔采样出现的 +2 跳变，用 `floor(t − a)`、`a ∈ (9.98, 10.20]` 即可同时拟合全部观测点。

## M5 — 设置页

IP / 端口输入 + 测试连接。

**验收**：改成错误 IP 后「测试连接」显示失败；改回正确 IP 后显示成功；杀掉 App 重开，配置还在。

**已完成（仅模拟器）**。改动只有两个文件：`ServerConfig.swift` 36 → 57 行（新增 `save(to:)` / `clear(from:)`），`SettingsViewController.swift` 52 → 462 行（纯代码 UIKit）；`ios/` 现共 15 个 Swift 文件 2228 行。规格见 [design.md](design.md) 的「设置入口」。

- 「测试连接」用**输入框当前值**（不是已保存值），超时 3 秒；失败文案分得开：超时 / 连接被拒 / 无法解析主机名 / 本机网络不可用 / 连接中断 / 地址非法 / 非 200（带状态码）/ 响应无法解析。
- 非法输入（空 IP、端口不在 `1...65535`）**提示且不写入**，不做静默回落 8737。校验责任在设置页，`ServerConfig.save` 自身不校验。
- 仓库内 `.storyboard` / `.xib` 数量为 **0**——[design.md](design.md) 复用表里「复制 `SettingController.storyboard`」那条**已在 M5 推翻**，理由见该表。

> **验收还欠一条**：原文的「杀掉 App 重开，配置还在」在模拟器上验过（容器 plist 落盘），**真机仍待 M6**。真机还要额外验一件事：**本地网络权限弹窗**（TN3179 明说模拟器不支持）——那是真机上「测试连接」会失败而模拟器上不会的唯一原因。
>
> **测试环境坑（务必记住）**：验配置读写**不要**用 `xcrun simctl spawn booted defaults`。它操作的是模拟器的**全局 domain**，不是应用的沙盒 `UserDefaults`——应用已配置时那个 domain 是空的，往里写值应用也读不到。正确路径是 `xcrun simctl get_app_container booted com.darklinden.screenstats data` 下的 `Library/Preferences/com.darklinden.screenstats.plist`。
>
> 隔离实验（[verify_defaults_precedence.png](images/verify_defaults_precedence.png)）：容器 plist 存好值、全局 domain 存坏值 `10.9.9.9`，副屏**仍是活数据**——**容器赢**。全局 domain 只在容器**没有该键**时才起兜底作用（此条为推断，未做隔离实验）。

## M6 — 部署与常亮

服务端 launchd 自启（`com.darklinden.screenstats.server`）；客户端开引导式访问、系统自动锁定设为永不；续签 launchd 任务（`com.darklinden.screenstats.resign`）上线。

**验收**：Mac 重启后不手动做任何事，`curl` 就能拿到数据。把续签任务的周期临时改成 5 分钟，确认它真的能重新签名、重装、并让 App 重新打开。

**已完成（客户端人工清单除外）。** 新增 `launchd/` 下两个 plist 模板、`resign.sh`、根目录的 `start.sh` / `stop.sh`，`Makefile` 加了 `service-*` 与 `service-resign-*` 两组目标。

**服务端自启**——`com.darklinden.screenstats.server`，`RunAtLoad` + `KeepAlive`，跑的是 `~/Library/Application Support/iphone-screen-stats/screenstats` 这份**安装副本**，不是 `build/` 里的产物（否则一次 `make clean` 服务就没了）。编排者亲测复核，不是采信实现者自述：`state = running`、`runs = 1`、`curl` 的 `seq` 78 → 80 递增、日志里 `HTTP 监听 0.0.0.0:8737`。

**起停接口是 `start.sh` / `stop.sh`**，它们是 `make service-install` / `make service-stop` 的薄包装，逻辑一份都没重复。之所以是脚本而不是只留 make 目标：写 `~/Library` 和 `launchctl bootstrap` 这两步在 agent 沙箱里会被挡住，必须由人执行。`service-stop` 用 `launchctl bootout` 而不是 `kill`——`KeepAlive = true` 会把被 kill 的进程立刻拉起来。

**续签**——`resign.sh` + `com.darklinden.screenstats.resign`。逻辑：算本地 profile 的剩余寿命，超过阈值（默认 3 天）就空转退出；否则把旧 profile 移进废纸篓 → `make ios-device-build`（Xcode 会去要一张新的）→ `ios-deploy` 装上 → `pymobiledevice3 developer dvt launch` 拉起。空转路径与续签路径都实测过。完整一轮（约 24 秒）：

```
19:30:08  收到 --force，无条件重新签名
19:30:08  旧 profile 已移入废纸篓：9b9d86f0-…
19:30:16  重新构建并签名：成功
19:30:23    [100%] Installed package …/ScreenStats.app
19:30:23  用 DVT 拉起 App
19:30:32    已在跑，pid=6795
19:30:32  完成：已重新签名、重装并拉起 App
```

拉起之后 15 秒再查，pid 仍是 6795。**成功判据是 pid，不是任何命令的退出码。**

> **三条实测记录**，都是踩过的坑，别再重走：
>
> 1. **`xcrun devicectl` 装不了这台机器。** 它是 CoreDevice 栈，只服务 iOS 17+；这台是 iOS 15.8.8，用 CoreDevice 自己的 UUID 和 40 位 UDID 都报 `com.apple.dt.CoreDeviceError error 1000 (device not found)`。改用 **`ios-deploy`**（`brew install ios-deploy`，走老的 MobileDevice 栈），同一台机器装得上、拉得起来。这是本项目**唯一一个开发机上的第三方依赖**——服务端仍然零依赖。
> 2. **`xcodebuild -allowProvisioningUpdates` 不会主动续期一张还有效的 profile**，它会直接复用本地的。要逼它去要新的，必须先把本地 profile 移走。实验：移走 `5c92186c` 后构建，目录里出现了全新的 `e38d5723`，创建时间就是构建那一刻。`resign.sh` 的第 2 步就是干这个。
> 3. **`ios-deploy` 的退出码不可信。** 装成功且拉起成功时，`--justlaunch` 返回 **1**、`--noninteractive` 返回 **137**，而输出里明明白白写着 `success`。判据只能看输出：`[100%] Installed package <路径>` = 装成功。（这个坑一开始真的踩了：脚本按退出码判断，于是报「装到真机没成功」而实际已经装好并拉起。）
> 4. **ios-deploy 拉起的 App 活不过命令退出，拉起必须改用 DVT。** 这条是整个 M6 里最贵的一个坑。ios-deploy 是**用调试器**（lldb + debugserver）启动 App 的，调试会话一结束 App 就被系统回收，三种模式全试过：`--justlaunch` → pid `-1`；`-I` 非交互 → 附加期间 pid 6681 活着，杀掉 ios-deploy 后 pid `-1`；`-N/--nolldb` → 根本不启动 App，只起 debugserver 监听。`safequit` 里确实规规矩矩调了 `process.Detach()`，没用——这是 iOS 的固有行为，不是 bug。用户看到的现象是「**闪一下就回主屏**」，手动点图标则正常。
>    **可行解是 `pymobiledevice3 developer dvt launch <bundle id>`**：DVT 就是 Xcode / Instruments 那条启动线，不挂调试器，命令退出后 App 照常跑（实测 pid 稳定存活 30 秒以上）。加上它之后，续签链路才第一次真正做到「重新签名 → 重装 → App 自己回到前台」。
>    走这条路之前试过并**排除**的：从 Mac 给设备的 SpringBoard 发 `SBSLaunchApplicationWithIdentifier`——`com.apple.springboard.services` 在 iOS 15.8.8 上**根本不存在**（`InvalidServiceError`），`com.apple.springboardservices` 连得上但发启动命令会被直接掐断连接；`pymobiledevice3` 自带的 springboard 服务只有 icon / wallpaper / orientation；`insidegui/launchapp` 明确写了 jailbreak only；`xcrun devicectl` 只服务 iOS 17+。**所以「让 App 注册 URL scheme、再由 Mac 打开」这条路虽然机制上成立（SpringBoard 启动的 App 不经调试器、确实能活），但缺一个能发起该调用的 Mac 侧工具，最终没走——也不需要走，因为 DVT 直接按 bundle id 启动就够了，App 一行都不用改。**（这条决定的完整记录，含排除项与推翻条件，见 [ADR-0005](adr/0005-ios-deploy-install-plus-dvt-launch.md)。）
> 5. **这台机器的 `mktemp` 是 GNU 的，BSD 的 `-t PREFIX` 写法会直接报错。** coreutils 的 `gnubin` 在 PATH 里盖住了 BSD 工具（`date` 也一样被盖）。GNU `mktemp` 要求模板里至少 3 个 `X`，`mktemp -t screenstats-install` 于是失败（`too few X's in template`），临时文件变量成了空串，`grep` 一个空文件名 → 报「装失败」而其实装得好好的。**脚本里一律用显式模板 `mktemp "${TMPDIR:-/tmp}/名字.XXXXXX"`，别用 `-t`。** `resign.sh` 一开始因为自己显式设了 PATH（不含 gnubin）而侥幸没事，那是运气不是设计。
> 6. **`~/Library/Application Support/...` 路径里有空格。** Makefile 的 recipe 里引用 `$(PYMOBILEDEVICE3)` 时忘了加引号，shell 按空格切开，命令直接找不到。凡是指向这个目录的变量，在 shell 里一律加引号。
>
> 另外记一笔**机型**：一开始是四个间接来源——`xcrun xcdevice list` 报的型号 `A1662/A1723/A1724`、DDI 目录名 `iPhone8,4`、`ios-deploy` 报的 `N69uAP`、以及 iOS 15.8.8 本身就是 A9/A10 机型的末班车——都指向 **iPhone SE 第一代**，**不是**文档里一直写的 SE2。后来用 `pymobiledevice3 developer screenshot` 抓了一张实机截图，**直接量出 640 × 1136 px @2x = 320 × 568 pt**，彻底定死。`design.md` 的界面规格（原本按 667×375 写的）已按真实机型改正。

> **还没做的**：客户端人工清单——引导式访问开关 + 三击启动、系统自动锁定设为「永不」、首次连局域网时点「允许」（本地网络权限弹窗，TN3179 明说模拟器测不到）；真机上的故障态验收（M4 欠的）；以及**真·重启测试**——本条验收写的是「Mac 重启后不手动做任何事」，本次只做到 `launchctl bootout` + `bootstrap` 的等价验证，真重启留到 M7。

## M7 — 端到端验收

**验收**：连续使用一整天，副屏没有出现过「回到桌面」「指标停更」「时钟停走」中的任何一种；手机电池区域摸起来不烫手。
