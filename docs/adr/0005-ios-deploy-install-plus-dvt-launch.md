# 真机部署分两个工具：ios-deploy 装，DVT 拉起

免费开发者账号的 provisioning **每 7 天过期**，过期后手机上的 App 直接起不来、副屏变黑。所以必须有自动续签，链路是三步：**重新签名 → 装到真机 → 拉起 App**。

前两步没有争议。有争议的是「装」和「拉起」**能不能共用一个工具**——答案是不能，而且这条踩了很久。

## 装：ios-deploy

`xcrun devicectl` 是 Apple 现在的官方 CLI，但它属于 CoreDevice 栈，**只服务 iOS 17+**。这台是 iOS 15.8.8，用 CoreDevice 自己的 UUID 和 40 位 UDID 都报 `com.apple.dt.CoreDeviceError error 1000 (device not found)`。

`ios-deploy`（`brew install ios-deploy`）走的是老的 MobileDevice 栈，同一台机器装得上。

## 拉起：pymobiledevice3 developer dvt launch

**`ios-deploy` 拉起的 App 活不过命令退出。** 它是用调试器（lldb + debugserver）启动 App 的，调试会话一结束 App 就被系统回收。三种模式全试过，无一例外：

| 模式 | 附加期间 | 命令退出后 |
|---|---|---|
| `--justlaunch` | — | pid `-1` |
| `-I` 非交互 | pid 6681 活着 | pid `-1` |
| `-N/--nolldb` | 根本不启动 App，只起 debugserver 监听 | pid `-1` |

`safequit` 里确实规规矩矩调了 `process.Detach()`，没用——这是 iOS 的固有行为，不是 bug。用户看到的现象是「**闪一下就回主屏**」，手动点图标则一切正常。

`pymobiledevice3 developer dvt launch` 走的是 DVT，也就是 **Xcode / Instruments 那条启动线，不挂调试器**，命令退出后 App 照常跑（实测 pid 稳定存活 30 秒以上）。它需要 DeveloperDiskImage 挂在设备上——`ios-deploy` 装的时候会顺手挂上，所以两步连着做正好。

## 排除掉的路子

- **从 Mac 给设备的 SpringBoard 发 `SBSLaunchApplicationWithIdentifier`。** 这是「不用调试器启动 App」最经典的做法，但 `com.apple.springboard.services` 在 iOS 15.8.8 上**根本不存在**（`InvalidServiceError`）；`com.apple.springboardservices` 连得上，可一发启动命令连接就被直接掐断。
- **让 App 注册 URL scheme、再由 Mac 打开。** 机制上成立（SpringBoard 启动的 App 不经调试器、确实能活），但**缺一个能发起该调用的 Mac 侧工具**：`simctl openurl` 只管模拟器，`devicectl` 只管 iOS 17+，`ios-deploy` 的完整 flag 列表里没有 openurl，`pymobiledevice3` 自带的 springboard 服务只有 icon / wallpaper / orientation，`insidegui/launchapp` 明确写了 jailbreak only。既然 DVT 直接按 bundle id 启动就够了，也就没必要再改工程加 scheme。
- **用 osascript 驱动 Xcode 按 ⌘R。** 走的是 Xcode 正常启动路径，可行；但要辅助功能权限、要 GUI 会话处于解锁状态、要 Xcode 起得来，半夜失败没人知道。
- **常驻调试会话当守护进程**（`ios-deploy -I` + launchd `KeepAlive`）。全自动，还顺带能自愈——App 一崩就重新拉起。代价是 App 永远跑在调试器下。

## 代价

- 开发机上多了**两个**第三方依赖：`ios-deploy`（brew）与 `pymobiledevice3`（装在 `~/Library/Application Support/iphone-screen-stats/venv`，由 `make resign-deps` 创建）。**服务端本身仍然零依赖**——这两个只服务真机部署。
- `ios-deploy` 的**退出码不可信**：装成功时 `--justlaunch` 返回 **1**、`--noninteractive` 返回 **137**，而输出里明明白白写着 `success`。成败只能看输出里的 `[100%] Installed package`，拉起成败只能看 pid。这个陷阱先后在 `resign.sh` 和 Makefile 的 `ios-device` 里各踩了一次。
- DVT 需要 DeveloperDiskImage 挂着。重启 Mac 后它会掉，所以「装」这一步不能省。

## 什么时候该推翻

- **Apple 把 CoreDevice 下放到更老的 iOS 版本**，或者这台设备升到 iOS 17+：`devicectl` 一个工具就能装能拉起，两个依赖可以一起去掉。
- **免费账号换成付费账号**：provisioning 变成一年，续签这件事本身就没那么急了，整条链路的复杂度可以大幅缩水。
- **`pymobiledevice3` 或 `ios-deploy` 停止维护**：DVT 那条线是 Xcode 自己在用的，`xcrun devicectl` 之外没有官方替代；届时退路是 osascript 驱动 Xcode，或者干脆退回手动每周 ⌘R。
