# 设计

## 目标

一台常亮、长期插电的 iPhone SE（第一代，4 寸）摆在 Mac mini 旁边，充当状态副屏：

- 瞥一眼就知道 Mac 现在忙不忙（CPU / GPU / 内存）
- 瞥一眼就知道有没有在读写磁盘、有没有在跑网络
- 顺带当一个翻页时钟，带年月日与星期

## 非目标

历史曲线、告警推送、多设备管理、从 iPhone 反向控制 Mac、App Store 分发、温度 / 功耗 / 风扇、内存压力等级、开机时长。

## 架构

```
┌──────────────────────── Mac mini M4 ─────────────────────────┐
│                                                              │
│  server/  (Swift 命令行可执行文件, launchd 常驻)              │
│                                                              │
│   ┌──────────────┐  1 Hz   ┌───────────────┐                 │
│   │ 采集循环      │ ──────▶ │ 最新采样槽位   │                 │
│   │ host_stat /  │         └───────┬───────┘                 │
│   │ IOKit /      │                 │ 读                      │
│   │ sysctl       │         ┌───────▼───────┐                 │
│   └──────────────┘         │ NWListener    │                 │
│                            │ HTTP :8737    │                 │
│                            └───────┬───────┘                 │
└────────────────────────────────────┼─────────────────────────┘
                                     │ GET /api/stats  (1 Hz)
                          ┌──────────▼───────────┐
                          │  iPhone SE (横屏)     │
                          │  ios/ 原生 App        │
                          │  ┌────────────────┐  │
                          │  │ MetricsPanelView│ │  上 160pt
                          │  ├────────────────┤  │
                          │  │ FlipClockView   │ │  下 160pt
                          │  └────────────────┘  │
                          └──────────────────────┘
```

采集与 HTTP 解耦：采集循环只往一个「最新采样」槽位里写，请求来了就读那个槽位。这样 1 Hz 的采集节奏与请求节奏互不干扰，多个客户端也不会让采集重复跑。

## 服务端

### 进程形态

一个纯命令行可执行文件，无 UI：

| 调用 | 行为 |
|---|---|
| `server` | 采集 + HTTP 监听 |
| `server --dump` | 同上，另外每秒往 stdout 打印一行人类可读的采样，用来在终端验证采集对不对 |
| `server --port 8737` | 覆盖监听端口 |
| `server --iface en0` | 覆盖被统计的网卡 |
| `server --freeze-after 30` | 调试用：跑满 30 秒后停掉采集循环但保持 HTTP 监听，用来验证客户端的「停更」状态 |
| `server -h` / `server --help` | 打印用法后退出 |

配置**只走命令行参数**，没有配置文件；launchd plist 里写死参数。由 `launchd` LaunchAgent 常驻，日志写 `~/Library/Logs/screenstats/server.log`。

### 采集实现映射

每项指标都从 exelban/stats 的对应 reader 照搬。下表是**唯一权威的映射**：

| 指标 | 系统 API | 照搬自 |
|---|---|---|
| CPU 总占用 | `host_statistics(HOST_CPU_LOAD_INFO)` 两次采样差分 | `stats/Modules/CPU/readers.swift:170`，比例计算 `:105-125` |
| 内存已用 | `host_statistics64(HOST_VM_INFO64)` + `vm_page_size` 换算 | `stats/Modules/RAM/readers.swift:43-58` |
| GPU 利用率 | `IOServiceMatching(kIOAcceleratorClassName)` → `PerformanceStatistics["Device Utilization %"]` | `stats/Modules/GPU/reader.swift:103,114,139` |
| 磁盘读/写 | `IORegistryEntryCreateCFProperty(kIOBlockStorageDriverStatisticsKey)` → `BytesRead` / `BytesWritten` 差分 | `stats/Modules/Disk/readers.swift:248-257` |
| 网络收/发 | `sysctl(NET_RT_IFLIST2)` → `if_msghdr2.ifm_data.ifi_ibytes` / `ifi_obytes` 差分 | `stats/Modules/Net/readers.swift:705-731` |

内存已用沿用 stats 的公式（`RAM/readers.swift:58`）：

```
used = active + inactive + speculative + wired + compressed - purgeable - external
```

GPU 那一行有兜底：stats 写的是 `stats["Device Utilization %"] as? Int ?? stats["GPU Activity(%)"]`（`GPU/reader.swift:139`）——**优先 `Device Utilization %`，没有就退到 `GPU Activity(%)`**。不同机型 key 名不一样，所以两级都要留。

本机 M4 实测（2026-11-03）：`Device Utilization %` 空闲 0，Metal 计算负载下稳定 98–99%，负载结束回落 0。**无需 sudo，无需 powermetrics。**

> 内存压力等级（stats 的 `RAMPressure` 枚举值是 `normal` / `warning` / `critical`，`stats/Kit/types.swift:439-442`）当前**不采集**——界面上没有它的位置。日后要加时按增量字段加，注意枚举值是 `warning` 不是 `warn`。

### 差分与速率

CPU、磁盘、网络都是**单调计数器**，速率由相邻两次采样求差得到：

```
rate = (counter_now - counter_prev) / (t_now - t_prev)
```

- 间隔用**单调时钟**（`mach_absolute_time` / `DispatchTime`）计算，不用墙钟。
- 计数器回绕（`now < prev`）时本次速率记 0 并跳过。
- 第一次采样没有前值，**速率字段**（磁盘、网络）为 `null`。CPU 是百分比不是速率，首帧给的是开机以来的平均值——上游 stats 也是这个行为，不要「修」成 `null`。
- 读不到与 0 是两回事：只有真的算出 0 才报 `0`，读不到一律 `null`。

### 统计范围

Mac mini M4 上有一堆接口：`en0` 有线、`en5/en6/en7` 雷雳网桥、`utun0-4` 代理隧道、`bridge100` 虚拟机网桥。全聚合会把代理和虚拟机流量混进读数。

- **网络**：只累加一个主接口，默认 `en0`，由 `--iface` 覆盖。
- **磁盘**：只统计内置启动盘（`IOBSDNameMatching` 匹配内部卷），外置卷不进读数。

> **未决**：本机公网流量走 `utun4`（路由 `128.0/1 → 198.18.0.0`），而 `en0` 目前**只在局域网流量下验过**。如果公网流量确实不上 `en0`，副屏上的网络读数会系统性偏低，这条「只统计 `en0`」就得重新考虑。本会话出站被拦截，验不了，留给能出网的环境。

### HTTP 层

零第三方依赖：`Network.framework` 的 `NWListener` 起 TCP，手写最小 HTTP/1.1。

- 只处理 `GET /api/stats`
- 其它路径或方法一律 `404`，响应体是纯文本 `not found`；另有 `400` / `500` / `503` 三个兜底状态码，见 [protocol.md](protocol.md)
- 每次响应带 `Connection: close`，不实现 keep-alive——1 Hz 一个客户端，省掉整个状态机
- 监听 `0.0.0.0:8737`，端口可配置
- 不做鉴权，理由与推翻条件见 [ADR-0004](adr/0004-no-auth-on-lan.md)

## 客户端

### 从 flipClock 复用与改动

| flipClock 里的东西 | 怎么处理 |
|---|---|
| `FlipClockLabel` + `FlipClockItem`（约 386 行） | 复制后把 `ThemeManager.sharedInstance.currentTheme` 换成注入的配色 |
| `FlipClockView`（626 行） | 复制后去掉底部工具栏与主题切换入口；日期 / 星期标签保留 |
| `Theme/` 目录（6 个文件 144 行） | 2 个是具体主题（Dark / Light），另 4 个是管理、协议、类型基础设施。留 DarkTheme 加那 4 个基础设施文件 |
| `Localizations/{zh-Hans,en}.lproj/Localizable.strings` | 复制。`.lproj` 会被同步目录自动当资源收进 bundle，**不用改工程文件**。漏了它整个界面会退化成英文：`NSLocalizedString` 拿不到翻译就原样返回 key（星期显示 `Tues`），而 `Bundle.main.preferredLocalizations` 只认 bundle 里**实际存在**的 `.lproj`，一个都没有时恒为 `["en"]`，日期也走英文分支显示 `11 / 3 / 2026`——**真机是中文也一样** |
| `BottomToolbarView` / `ClockSecondSwitch` / `Common` / `AppData` | 不进 `ios/`。前两个的调用点只在下一条要删的工具栏和 M5 的设置页里；后两个只服务 flipClock 自己的 `ViewController` / `SettingController`，都不搬进来 |
| `SettingController.storyboard` + `DisplaySettingsTableVC` | **不复制（M5 推翻此条）**。flipClock 的设置页是主题 / 显示设置 + 作者链接，与本项目要的 IP / 端口 / 测试连接毫无重叠；它的主题与秒针音恰恰是本表明确排除的东西。M5 改为纯代码 `SettingsViewController`，仓库内 **0 个 `.storyboard` / `.xib`** |
| `SoundManager` + `Assets/*.wav` | 不进 `ios/`（副屏不需要翻页音效） |
| `AppDelegate` 强制横屏 | 保留 |

flipClock 里没有 `DashboardViewController`——那个类名是**本项目的**：新建一个，取代 flipClock 的 `ViewController`，承载下面两个子视图。

### 界面规格

横屏 **568 × 320 pt**（iPhone SE 第一代，1136 × 640 px @2x；实测自 `pymobiledevice3 developer screenshot`，不是推断）。

```
┌──────────────────────────────────────────────────────────┐ y=0
│ CPU  ████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░   62%  │  10
│ GPU  ████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░   31%  │  42
│ MEM  ████████████████████░░░░░░░░░░░░░░░░░░░░░░░░   71%  │  74
│                                                          │
│ DISK        R  12.4 MB/s            W   3.1 MB/s         │ 110
│ NET         ↓   8.2 MB/s            ↑   0.4 MB/s         │ 134
├──────────────────────────────────────────────────────────┤ y=160
│                                                          │
│            ┌──────┐     ┌──────┐     ┌──────┐            │
│            │  14  │  :  │  37  │  :  │  52  │            │
│            └──────┘     └──────┘     └──────┘            │
│                        星期四      2026年11月3日          │
└──────────────────────────────────────────────────────────┘ y=320
```

`DashboardViewController` 里两个平级子视图：

| 区域 | frame | 内容 |
|---|---|---|
| 指标区 `MetricsPanelView` | `(0, 0, 568, 160)` | 3 条进度条 + 2 行数据 |
| 时钟带 `FlipClockView` | `(0, 160, 568, 160)` | 翻页时钟 |

指标区内部（高 160pt）的算术必须闭合：

```
顶部留白 10
3 × 进度条行 26 + 2 × 行距 6  = 90      → 末行结束于 100
区块间隔 10                              → 数据区起于 110
2 × 数据行 20 + 1 × 行距 4    = 44      → 末行结束于 154
底部留白 6
                                   合计 160  ✓
```

水平方向：左右各留 **12pt** 边距，其余宽度自适应，**不写死 568**。

注意这 160pt 是**排满的**：角落的故障标签（`失联 Ns` / `停更 Ns`）没有专属位置，只能挤进顶部那 10pt 留白，取 `y = 0..14`。它与 CPU 行（`y = 10..36`）在几何上重叠 4pt，但 CPU 行的文字垂直居中后落在约 `y = 14..31`，实际不相撞。动这里的任何数字之前先看这条。

`FlipClockView` 按自己的 `bounds` 布局（`FlipClockView.swift:216-257`：卡片宽 `0.24 × width` ≈ 136pt、垂直居中），所以放进 160pt 高的容器里会自动居中，**它的 `layoutSubviews` 一行都不用改**。

但「去掉底部工具栏」并不只是删一个视图，仍要动这些非布局代码：`FlipClockView.swift:193`（工具栏的创建）、`:295`（`addSubview`）、`:475-479`（主题配色）、`:514-524`（`handleTap` 里对工具栏可见性的判断）、`:597` 与 `:606`（滑入滑出的 transform），以及 `:124-126`（主题按钮图标）。设置入口改接到长按手势上。

flipClock 原有的单指滑动与单击手势（`FlipClockView.swift:306-308` 等）**不迁移**——常亮副屏上误触改亮度比调亮度有用得多。

### 进度条阈值色

| 百分比 | 颜色 |
|---|---|
| < 60% | 绿 |
| 60–85% | 黄 |
| ≥ 85% | 红 |

边界归属：**60% 归黄、85% 归红**（即绿 `< 0.60`、黄 `[0.60, 0.85)`、红 `≥ 0.85`）。进度条底槽固定暗灰，`null` 时进度条清空且不留色。

### 数值格式

- 百分比：整数 + `%`（四舍五入）
- 速率：自动换算 `B/s` → `KB/s` → `MB/s` → `GB/s`，**一律保留 1 位小数**（`B/s` 档也是，所以显示 `0.0 B/s` 而不是 `0 B/s`）
- 字段为 `null`：显示 `--`，**不显示 0**。`0.0 B/s` 与 `--` 是两回事：前者是「确实是 0」，后者是「读不到」

### 轮询节奏

- 间隔 1 秒，单次请求超时 **0.8 秒**
- 失败后**不额外退避**，按原节奏排下一次请求
- 若上一个请求在下一个整秒到来时**仍未返回**，该轮直接跳过（不叠加请求），下个整秒再试。正常路径不会触发（0.8 秒超时 < 1 秒间隔），所以这不构成退避

超时（0.8s）小于间隔（1s），所以「连续 3 次失败」最坏约 2.4 秒，能满足 [roadmap](roadmap.md) 里「3 秒内变暗」的验收。

### 五种显示状态

| 状态 | 判据 | 表现 |
|---|---|---|
| 正常 | 最近一次请求成功且 `seq` 在前进 | 正常渲染 |
| **失联** | 连续 3 次请求失败 | 指标区整体降到 40% 不透明度、数值显示 `--`、角落标 `失联 Ns`；**翻页时钟照常走** |
| **停更** | 请求成功，但 `seq` 连续 3 秒没变 | 同上，角落标 `停更 Ns` |
| 未配置 | `UserDefaults` 里没有服务器地址 | 指标区显示 `未配置服务器`，时钟照常走 |
| 单项读不到 | 该字段为 `null` | 只该项显示 `--`，其余正常 |

失联与停更是**两种不同的故障**：前者是链路或服务端进程挂了，后者是服务端活着但采集循环卡住了。角落的文案是排障时唯一能区分二者的线索，所以不合并。

判据用 `seq` 而不是服务端时间戳，避免两台机器的时钟偏差造成误判。服务端重启后 `seq` 归零，客户端发现 `seq` 变小即视为重启，重置基线，不判失联。

**`seq` 前进与 `seq` 变小都重置停更基线**，所以重启后不会残留上一个进程的停更计时。

状态文案（`失联 Ns` / `停更 Ns` / `未配置服务器`）是**硬编码中文**，不走 `Localizable.strings`。副屏固定中文，可接受；将来要做多语言得先补这里。

#### 本地网络权限也表现为失联，且**不单独处理**

从 iOS 14 起，出站 TCP 连到局域网地址需要「本地网络」权限（Apple [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) 的操作表里 `Making an outgoing TCP connection` 明确是 `yes`）——客户端连 Mac 的局域网 IP（`192.168.x.x:8737`）正落在这一条里。弹窗文案由 `Info.plist` 的 `NSLocalNetworkUsageDescription` 提供，工程里已配。

**客户端不为它加第六种状态**：权限没放行和 Mac 网线没插，在客户端看来完全一样，都是「请求失败」。它继续按 1 Hz 原节奏重试，用户在弹窗上点「允许」后下一次请求就成功，自动回到正常态。

由此产生的、**属于预期而非 bug** 的现象：

- 首次启动时会先显示几秒 `失联`——TN3179 说系统可能在用户点完弹窗之前就先拒掉触发弹窗的那次操作。
- 用户点「不允许」时会一直显示 `失联 Ns`，且**不会**自动变好，直到用户去「设置 → 隐私与安全性 → 本地网络」打开它。
- 权限弹窗只在首次需要时出现一次，之后系统记住选择。

> M4 的故障态验收**必须在真机上做**：TN3179 明说模拟器不支持本地网络隐私。

### 设置入口

常亮副屏上常驻一个齿轮很丑，所以：

- **长按 2 秒**整个屏幕唤出设置页
- 设置页字段：服务器 IP、端口，加一个「测试连接」按钮（拉一次 `/api/stats` 并显示结果）
- 配置存 `UserDefaults`，键名**冻结**为 `serverHost`（String）与 `serverPort`（Int）
- 端口缺省 **8737**；存进去的值不在 `1...65535` 内也回落 8737。`serverHost` 缺失、或去空白后为空 → **未配置**
- 读写**只允许**经过 `ios/ScreenStats/ServerConfig.swift` 这一处。其它任何地方不许直接读这两个键名——M4 与 M5 靠这一条对齐
- 设置页写完配置后不必手动通知：M4 已挂 `UserDefaults.didChangeNotification`，同进程写入会即时重读。但该通知在**发起写入的线程**投递，而重读路径会同步碰 UIKit，所以设置页**必须在主线程**写 `UserDefaults`
- 写入侧 API 与读取侧同处一个文件：`ServerConfig.save(to:)` / `ServerConfig.clear(from:)`（M5 新增），**两者同样必须在主线程调用**

设置页本身的规格（M5 定）：

- **纯代码 UIKit，不用 storyboard**（理由见「从 flipClock 复用与改动」表里那一行）。呈现用 `modalPresentationStyle = .fullScreen`——横屏只有 320pt 高，pageSheet 的卡片内缩会让键盘避让不可控
- **键盘避让是硬要求**：表单放 `UIScrollView` + 垂直 `UIStackView`，`keyboardWillChangeFrame` 时把 `contentInset.bottom` 顶到键盘上沿，并把正在编辑的控件滚进可视区。横屏高 320pt、键盘约占 160pt（**只剩一半**），不避让就会遮住输入框
- 两个输入框都挂 `UIToolbar`「完成」附件键（数字键盘没有 Return 键）；IP 框关掉自动大写 / 自动更正 / 拼写检查
- **测试连接**：`GET http://{输入框里的 host}:{输入框里的 port}/api/stats`，超时 **3 秒**（比轮询的 0.8 秒长，因为这是用户手动触发的一次性动作）。成功显示 `seq` 与 CPU / GPU；**失败必须带原因**——只写「失败」两个字在排障时没有价值。原因至少覆盖：超时 / 连接被拒 / 无法解析主机名 / 本机网络不可用 / 连接中断 / 地址非法 / 非 200（附状态码）/ 响应无法解析（区分空 body 与非 JSON）
- **校验**：IP 非空；端口必须是 `1...65535` 的整数。非法 → **提示且不写入**，不做静默回落 8737。校验责任在设置页，`ServerConfig.save` 自身不校验、原样落盘；`load` 里的 8737 回落只兜历史脏数据
- 本页**不碰** `isIdleTimerDisabled`——常亮只由副屏（`DashboardViewController`）控制

### 常亮

- 客户端 `isIdleTimerDisabled = true`
- 系统层面再把「设置 → 显示与亮度 → 自动锁定」设为**永不**（双保险）
- 开「引导式访问」锁死在 App 内，防止误触划走

## 部署与续签

**iPhone 长期插在 Mac mini 的 USB 口上**（已确认，本机 USB 总线上已枚举到该设备）。这一条线同时解决三件事：供电、常亮、每 7 天的续签。选有线而非无线是硬约束——无线安装走的是 `devicectl`，而它只服务 iOS 17+，这台是 iOS 15.8.8。

服务端：

```
~/Library/LaunchAgents/com.darklinden.screenstats.server.plist
```

客户端（免费账号，provisioning 每 7 天过期）：

- bundle identifier：`com.darklinden.screenstats`
- 一个 `launchd` 定时任务（`com.darklinden.screenstats.resign`），默认每 24 小时检查一次；本地 profile 剩余寿命低于 3 天就重新签名 + 重装 + 拉起。**装用 `ios-deploy`，拉起必须用 `pymobiledevice3 developer dvt launch`**——`ios-deploy` 是拿调试器启动 App 的，命令一退 App 就被系统回收，留不住。工具链、排除项与实测记录见 [roadmap.md](roadmap.md) 的 M6
- 失败模式的可见信号：某天早上屏幕回到桌面
- **这条 USB 线属于部署的一部分，不是随手插的充电线。** 拔掉它，7 天后签名过期且无法自动续签

## 未决项

1. CPU 每核明细当前不在协议里；需要时按增量字段添加。
2. **`en0` 能否看见经 `utun4` 出去的公网流量**——若不能，「只统计 `en0`」会低估网络读数。详见上面「统计范围」。
