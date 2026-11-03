#!/usr/bin/env bash
#
# 停掉服务端 launchd 自启服务。
#
# 必须用 launchctl bootout（make service-stop）而不是 kill：
# plist 里 KeepAlive = true，被 kill 的进程会被 launchd 立刻拉起来。
#
# 用法：  ./stop.sh
#
set -euo pipefail

# 脚本就在仓库根，cd 到它自己所在的目录即可（用绝对路径调用也不会跑偏）。
cd "$(dirname "$0")"

echo "==> 卸载 launchd 服务"
make service-stop

echo
if curl -fsS --max-time 1 http://127.0.0.1:8737/api/stats >/dev/null 2>&1; then
    echo "！！8737 还在响应，服务没停干净。" >&2
    echo "   如果这是你自己前台跑的 make server，那属于正常；否则跑 make service-status 看看。" >&2
    exit 1
fi
echo "OK：8737 已无响应，服务已停"
