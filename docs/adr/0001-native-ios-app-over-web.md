# 客户端做成原生 iOS App，而不是服务端吐出的网页

iPhone SE2 只当显示端，最省事的做法是 Mac 服务端直接吐一个网页，Safari 全屏打开：零签名、零过期、改 UI 立刻生效。我们仍然选了原生 App，原因有三条，且都不轻：

1. **需求本身指向 App。**「iOS 端配置服务器地址拉取数据」——网页是由服务端吐出来的，打开 URL 即可，不存在「配置服务器地址」这个动作。要填地址的客户端必然是独立出站连接的原生进程。
2. **能直接复用 `/opt/home/Github/flipClock/` 的翻页时钟。** 那是 1012 行经过小屏与动画修复的 UIKit 代码，其中 `FlipClockLabel` + `FlipClockItem` 约 386 行是自包含的翻页单元。走网页等于全部扔掉，改用 CSS 重写「上下半页 + 镜像文字修正 + 逐帧同步」。
3. **常亮副屏需要真正的 kiosk 行为。** 原生能用 `isIdleTimerDisabled` 从 App 内部禁止锁屏；网页只能去改系统的「自动锁定」设置，且拦不住误触划走。

前提已验证：Xcode 16.4 的 iPhoneOS SDK `MinimumDeploymentTarget` 允许部署到 iOS 15，目标设备 iOS 15.8.8 在支持范围内，且 flipClock 当前就在这台手机上运行。

## 代价

免费开发者账号的 provisioning **每 7 天过期**。缓解办法是 iPhone 长期插在 Mac mini 的 USB 口上，由 `launchd` 每 6 天跑一次 `xcodebuild` + `devicectl device install` 自动重装。失败模式的可见信号是「某天早上屏幕回到桌面」。

## 什么时候该推翻这个决定

如果自动续签在真机上不稳定，或者你不接受「屏幕可能某天变回桌面」，那么换网页是对的：重写 CSS 翻页动画的成本，低于长期维护一条签名流水线。
