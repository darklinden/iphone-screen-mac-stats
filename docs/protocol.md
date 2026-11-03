# 线协议

服务端与客户端之间只有这一个契约。任何一端改动它，另一端必须同步。

## 端点

```
GET http://{host}:{port}/api/stats
```

- 无请求体、无参数、无鉴权（只在局域网监听）
- 响应 `200 OK`，`Content-Type: application/json; charset=utf-8`
- 响应头带 `Cache-Control: no-store` 与 `Connection: close`
- 服务端读不到某一项时，该项为 `null`，**整体仍是 200**
- 其它路径或方法返回 `404`，响应体是纯文本 `not found`

## 响应

```json
{
  "seq": 10231,
  "ts": 1762151234.123,
  "cpu":  { "total": 0.62 },
  "gpu":  { "util": 0.31 },
  "mem":  { "total_bytes": 17179869184, "used_bytes": 12195217408 },
  "disk": { "read_bps": 13002342, "write_bps": 3251200 },
  "net":  { "iface": "en0", "rx_bps": 8598323, "tx_bps": 419430 }
}
```

## 字段

| 字段 | 类型 | 单位 / 范围 | 说明 |
|---|---|---|---|
| `seq` | Int | 从 0 起单调递增 | 服务端每次采样 +1。客户端用它判失联与停更 |
| `ts` | Double | Unix 秒 | 服务端墙钟，仅供参考 |
| `cpu.total` | Double \| null | 0.0–1.0 | 全部核心的平均占用 |
| `gpu.util` | Double \| null | 0.0–1.0 | GPU 设备利用率 |
| `mem.total_bytes` | Int | 字节 | 物理内存总量 |
| `mem.used_bytes` | Int \| null | 字节 | 已用（公式见 [design.md](design.md)） |
| `disk.read_bps` | Int \| null | 字节/秒 | 内置盘读速率 |
| `disk.write_bps` | Int \| null | 字节/秒 | 内置盘写速率 |
| `net.iface` | String | | 被统计的接口名 |
| `net.rx_bps` | Int \| null | 字节/秒 | 接收速率 |
| `net.tx_bps` | Int \| null | 字节/秒 | 发送速率 |

## 约定

- 百分比一律 **0.0–1.0 的 Double**，不是 0–100。
- 速率一律 **bytes/s 的 Int**，不是 KB/s；单位换算由客户端做。
- **读不到就用 `null`，不要用 0 冒充。** `0` 是「确实是 0」，`null` 是「读不到」，客户端对这两者显示不同（`0%` vs `--`）。
- 第一次采样时所有速率字段是 `null`（没有前值可差分）。
- **`seq` 在服务端重启后归零**，不做持久化。客户端发现 `seq` 变小即视为服务端重启，重置基线，**不**判失联。
- 新增字段一律**增量**添加；客户端必须容忍未知字段。

## 手工验证

```sh
curl -s http://192.168.1.199:8737/api/stats | python3 -m json.tool
```

连续拉两次，`seq` 必须递增；中间 `sleep 2`，两次的 `seq` 差值应当约等于 2。
