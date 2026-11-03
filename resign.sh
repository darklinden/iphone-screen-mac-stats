#!/usr/bin/env bash
#
# 客户端续签：检查 provisioning profile 的剩余寿命，快到期就重新签名 + 重装 + 拉起 App。
#
# 为什么需要它：免费开发者账号的 provisioning profile 只有 7 天寿命，过期后手机上
# 的 App 直接起不来，副屏变黑。手动做法是每周开 Xcode 按一次 ⌘R，这个脚本把它自动化。
#
# 由 launchd 任务 com.darklinden.screenstats.resign 定期调用（见 launchd/），也可以手动跑：
#
#   ./resign.sh            没到期就空转
#   ./resign.sh --force    无条件重新签名 + 重装（验收用）
#
set -euo pipefail

# launchd 给的 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin，ios-deploy 在 Homebrew 下，
# 不显式加进来会找不到。
# 另外注意：本机 PATH 里的 `date` 和 `mktemp` 都被 coreutils 的 gnubin 盖成了 GNU 版，
# BSD 的 `date -j` 和 `mktemp -t PREFIX` 都不可用。所以日期运算全交给 python3，
# 临时文件一律用显式模板（`XXXXXX`），不用 `-t`。
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# pymobiledevice3 装在 Application Support 下的稳定 venv 里（由 Makefile 的 resign-deps 装）。
# 这个路径要和 Makefile 的 INSTALL_DIR 保持一致。
export PATH="$HOME/Library/Application Support/iphone-screen-stats/venv/bin:$PATH"

cd "$(dirname "$0")"

BUNDLE_ID="com.darklinden.screenstats"
APP_ID="LBSBA5HK8X.$BUNDLE_ID"
DEVICE_UDID="${IOS_DEVICE_UDID:-e7fba5418946ae08f8e9978c9b1fe446dea67faf}"
APP="build/ios/Build/Products/Debug-iphoneos/ScreenStats.app"
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

# 剩余寿命低于这个天数就重新签。默认 3 天——比 7 天留出余量，万一某次没成
# （手机没插、Mac 睡着、keychain 锁着），后面每天还有机会补。
THRESHOLD_DAYS="${RESIGN_THRESHOLD_DAYS:-3}"

FORCE="${1:-}"
[ "$FORCE" = "--force" ] || FORCE=""

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# 列出本地所有属于本 App ID 的 profile，每行「路径<TAB>到期时间戳」。
# 用 python 而不是 plutil：`security cms -D` 的输出是多行 plist，
# 走管道喂给 plutil 不如直接在 python 里解。
matching_profiles() {
    python3 - "$PROFILE_DIR" "$APP_ID" <<'PY'
import glob, os, plistlib, subprocess, sys

profile_dir, app_id = sys.argv[1], sys.argv[2]
for path in sorted(glob.glob(os.path.join(profile_dir, "*.mobileprovision"))):
    try:
        raw = subprocess.run(["security", "cms", "-D", "-i", path],
                             capture_output=True, check=True).stdout
        pl = plistlib.loads(raw)
    except Exception:
        continue
    if (pl.get("Entitlements") or {}).get("application-identifier") != app_id:
        continue
    exp = pl.get("ExpirationDate")
    print("%s\t%d" % (path, int(exp.timestamp()) if exp else -1))
PY
}

# --- 1. 判断要不要动手 -------------------------------------------------------

if [ -n "$FORCE" ]; then
    log "收到 --force，无条件重新签名"
else
    first_line="$(matching_profiles | head -1)"
    if [ -z "$first_line" ]; then
        log "本地没有 $APP_ID 的 profile，按已过期处理"
        left_days=-1
    else
        exp_epoch="${first_line##*	}"
        left_days=$(( (exp_epoch - $(date +%s)) / 86400 ))
    fi
    log "profile 剩余寿命 ${left_days} 天（阈值 ${THRESHOLD_DAYS} 天）"
    if [ "$left_days" -gt "$THRESHOLD_DAYS" ]; then
        log "还没到期，跳过"
        exit 0
    fi
    log "接近或已经到期，开始续签"
fi

# --- 2. 逼 Xcode 发一张新 profile --------------------------------------------

# 本地 profile 还有效时，`xcodebuild -allowProvisioningUpdates` 会直接复用它、
# 不会主动续期（2026-11-03 实测）。把旧的移走，Xcode 才会去要新的——
# 同一次实验里新 profile 确实被建出来了（UUID 与创建时间都变了）。
old_profiles="$(matching_profiles | cut -f1)"
if [ -n "$old_profiles" ]; then
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if ! trash "$p"; then
            log "失败：移不走旧 profile $p（后面可能拿到同一张，续签就不算真的完成）"
            exit 1
        fi
        log "旧 profile 已移入废纸篓：$(basename "$p")"
    done <<< "$old_profiles"
fi

# --- 3. 重新签名（会自动向 Apple 要新 profile）--------------------------------

# xcodebuild 的输出有几百行，全灌进 launchd 日志就没法看了。成功时只留一行，
# 失败时把末尾 25 行吐出来——足够定位。
log "重新构建并签名"
build_log="$(mktemp "${TMPDIR:-/tmp}/screenstats-resign-build.XXXXXX")"
if ! make ios-device-build > "$build_log" 2>&1; then
    log "失败：重新签名没成功，输出末尾 25 行："
    tail -n 25 "$build_log" | while IFS= read -r line; do log "  $line"; done
    trash "$build_log" 2>/dev/null || true
    exit 1
fi
trash "$build_log" 2>/dev/null || true
log "重新构建并签名：成功"

# --- 4. 装到真机并拉起 -------------------------------------------------------

# 装用 ios-deploy。它的退出码不可信（装成功时 --justlaunch 返回 1），判据看输出里的
# `[100%] Installed package <路径>`。顺带一提，它这一下也会把 DeveloperDiskImage 挂上，
# 下面 DVT 启动正需要那个。
log "装到真机 $DEVICE_UDID"
deploy_log="$(mktemp "${TMPDIR:-/tmp}/screenstats-resign-deploy.XXXXXX")"
ios-deploy --id "$DEVICE_UDID" --bundle "$APP" --no-wifi --justlaunch > "$deploy_log" 2>&1 || true

installed=0
if grep -q "Installed package" "$deploy_log"; then installed=1; fi

if [ "$installed" -ne 1 ]; then
    log "失败：没装上（installed=$installed）。输出末尾 15 行："
    tail -n 15 "$deploy_log" | while IFS= read -r line; do log "  $line"; done
    trash "$deploy_log" 2>/dev/null || true
    exit 1
fi
grep -E "Installed package" "$deploy_log" | while IFS= read -r line; do log "  $line"; done
trash "$deploy_log" 2>/dev/null || true

# 拉起**不能**用 ios-deploy：它是拿调试器启动 App 的，命令一退 App 就被系统回收
# （--justlaunch / -I / -N 三种模式都实测过，全部死在 detach 那一刻）。
# 改用 DVT——也就是 Xcode / Instruments 那条启动线，不挂调试器，命令退出后 App 照常跑
# （实测 pid 稳定存活 30 秒以上）。
log "用 DVT 拉起 App"
if ! pymobiledevice3 developer dvt launch "$BUNDLE_ID" > /dev/null 2>&1; then
    log "失败：DVT 拉起没成功（DeveloperDiskImage 挂上了吗？试试 pymobiledevice3 mounter auto-mount）"
    exit 1
fi

# 成功判据看 pid，不看任何命令的退出码。
sleep 3
pid="$(ios-deploy --id "$DEVICE_UDID" --bundle_id "$BUNDLE_ID" --get_pid 2>/dev/null | tr -d '\n' | sed 's/.*pid: *//')"
case "$pid" in
    ''|'-1'|*[!0-9]*)
        log "失败：拉起后 App 不在跑（pid='$pid'）"
        exit 1
        ;;
esac
log "  已在跑，pid=$pid"

log "完成：已重新签名、重装并拉起 App"
