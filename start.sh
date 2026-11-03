#!/usr/bin/env bash
#
# 启动（首次则安装）服务端 launchd 自启服务。
#
# 为什么要有这个脚本：agent 会话的沙箱写不了 ~/Library、也 bootstrap 不了 launchd，
# 所以这一步必须由你在自己的终端里跑。脚本本身不重复任何逻辑，只包一层 Makefile。
#
# 用法：  ./start.sh
#
set -euo pipefail

# 脚本就在仓库根，cd 到它自己所在的目录即可（用绝对路径调用也不会跑偏）。
cd "$(dirname "$0")"

echo "==> 安装并加载 launchd 服务"
make service-install

echo
echo "==> 等它真的开始出数据（最多 10 秒）"
for _ in $(seq 1 20); do
    if curl -fsS --max-time 1 http://127.0.0.1:8737/api/stats >/dev/null 2>&1; then
        echo "OK：8737 已经在出数据"
        echo
        curl -s http://127.0.0.1:8737/api/stats | python3 -m json.tool | head -25
        echo
        echo "==> launchd 状态（前 15 行）"
        launchctl print "gui/$(id -u)/com.darklinden.screenstats.server" 2>&1 | head -15
        exit 0
    fi
    sleep 0.5
done

echo "！！10 秒内没拿到数据，按顺序排查：" >&2
echo "   make service-status       # launchd 怎么看这个服务" >&2
echo "   make service-logs         # 服务自己的日志" >&2
echo "   lsof -nP -iTCP:8737       # 端口是不是被别的东西占了（比如前台 make server）" >&2
exit 1
