# iphone-screen-stats

把一台常亮、长期插电的 **iPhone SE2** 变成 **Mac mini** 的状态副屏。

- 上半屏：CPU / GPU / 内存 三条百分比进度条，加磁盘读写、网络读写两组速率
- 下半屏：翻页时钟（时:分:秒）+ 年月日 + 星期几

两个进程，一个仓库：Mac 上跑一个 Swift 采集**服务端**，iPhone 上跑一个原生 iOS **客户端**，中间只有一条 `GET /api/stats` 的 1 Hz 轮询。

```
Mac mini ──[ 采集 ]──▶ 最新采样 ──[ NWListener :8737 ]──▶ iPhone ──[ 1 Hz 轮询 ]──▶ 渲染
```

## 文档

| 文档 | 内容 |
|---|---|
| [docs/design.md](docs/design.md) | 架构、采集实现映射、界面规格、失败模式 |
| [docs/protocol.md](docs/protocol.md) | 线协议契约：端点与 JSON schema |
| [docs/roadmap.md](docs/roadmap.md) | 实施顺序与每一步的验收标准 |
| [docs/adr/](docs/adr/) | 决策记录 |
| [GLOSSARY.md](GLOSSARY.md) | 本项目术语 |
| [AGENTS.md](AGENTS.md) | 给编码 agent 的仓库指南 |

## 状态

设计已冻结，代码尚未开始。从 [docs/roadmap.md](docs/roadmap.md) 的 M0 开始。
