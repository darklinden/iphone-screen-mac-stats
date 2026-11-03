# iphone-screen-stats —— 仓库唯一的命令入口。
# 里程碑与验收标准见 docs/roadmap.md。

SHELL := /bin/bash
ROOT  := $(CURDIR)
BUILD := $(ROOT)/build

# --- 服务端 -----------------------------------------------------------------

SERVER_PKG   := server
SERVER_BIN   := $(BUILD)/server/debug/screenstats
SWIFT_CACHE  := $(BUILD)/modulecache
# --disable-sandbox：本包零依赖，SwiftPM 自带的 manifest 沙箱没有实际保护作用，
#                    而在已经被沙箱包裹的环境里它反而会失败（sandbox_apply: Operation not permitted）。
# --cache-path / *_MODULE_CACHE_PATH：把缓存留在 build/ 里，不污染 ~/Library。
SWIFT        := CLANG_MODULE_CACHE_PATH=$(SWIFT_CACHE) SWIFT_MODULE_CACHE_PATH=$(SWIFT_CACHE) \
                swift build --package-path $(SERVER_PKG) --scratch-path $(BUILD)/server \
                --cache-path $(BUILD)/swiftpm-cache --disable-sandbox
SWIFT_RELEASE := CLANG_MODULE_CACHE_PATH=$(SWIFT_CACHE) SWIFT_MODULE_CACHE_PATH=$(SWIFT_CACHE) \
                 swift build -c release --package-path $(SERVER_PKG) --scratch-path $(BUILD)/server \
                 --cache-path $(BUILD)/swiftpm-cache --disable-sandbox
SERVER_RELEASE_BIN := $(BUILD)/server/release/screenstats

# --- 服务端自启（launchd，用户级 LaunchAgent） --------------------------------
# 服务指向的是 Application Support 下的安装副本，不是 build/ 里的产物：
# make clean 会清空 build/，指向那里等于服务随一次 clean 消失。
# plist 由 launchd/*.plist.in 渲染，仓库里不出现硬编码的 /Users/... 路径。
SERVICE_LABEL := com.darklinden.screenstats.server
SERVICE_UID   := $(shell id -u)
INSTALL_DIR   := $(HOME)/Library/Application Support/iphone-screen-stats
INSTALLED_BIN := $(INSTALL_DIR)/screenstats
LOG_DIR       := $(HOME)/Library/Logs/iphone-screen-stats
LOG_FILE      := $(LOG_DIR)/server.log
PLIST_TMPL    := $(ROOT)/launchd/$(SERVICE_LABEL).plist.in
PLIST         := $(HOME)/Library/LaunchAgents/$(SERVICE_LABEL).plist
LOGS_LINES   ?= 50

# --- 客户端续签（launchd，用户级 LaunchAgent） --------------------------------
# 免费账号的 provisioning profile 只有 7 天寿命，过期后手机上的 App 直接起不来。
# 这个任务定期检查剩余寿命，快到期就重新签名 + 重装 + 拉起（见 resign.sh）。
RESIGN_LABEL  := com.darklinden.screenstats.resign
RESIGN_TMPL   := $(ROOT)/launchd/$(RESIGN_LABEL).plist.in
RESIGN_PLIST  := $(HOME)/Library/LaunchAgents/$(RESIGN_LABEL).plist
RESIGN_SH     := $(ROOT)/resign.sh
RESIGN_LOG    := $(LOG_DIR)/resign.log
# 检查周期（秒），默认一天。验收时改成 300 看它每 5 分钟跑一次。
RESIGN_INTERVAL ?= 86400
# 传给 resign.sh 的额外参数。空着 = 正常模式（没到期就空转）；
# 验收时用 RESIGN_ARGS=--force 强制每次重新签名 + 重装。
RESIGN_ARGS ?=

# pymobiledevice3 装在 Application Support 下的稳定 venv 里（不在 build/，否则 make clean 会清掉）。
# resign.sh 用它启动 App：`pymobiledevice3 developer dvt launch` 走的是 Xcode/Instruments
# 那条启动线，**不挂调试器**，所以命令退出后 App 能活。ios-deploy 不行——它是用调试器
# 启动的，命令一退 App 就被系统回收（--justlaunch / -I / -N 三种都实测过）。
RESIGN_VENV    := $(INSTALL_DIR)/venv
PYMOBILEDEVICE3 := $(RESIGN_VENV)/bin/pymobiledevice3

# --- 客户端 -----------------------------------------------------------------

IOS_PROJECT := ios/ScreenStats.xcodeproj
IOS_SCHEME  := ScreenStats
IOS_BUNDLE  := com.darklinden.screenstats
IOS_DD      := $(BUILD)/ios
IOS_APP     := $(IOS_DD)/Build/Products/Debug-iphonesimulator/ScreenStats.app

# 目标机是 iPhone SE2，但 Xcode 16.4 只带 iOS 18 的模拟器运行时，先用 iPhone 16 顶替。
# 本机 18.3.1 与 18.6 各有一台同名设备，所以 destination 必须带 OS=latest，
# 否则 xcodebuild 会选 18.3.1、simctl 会选 18.6，编译目标和安装目标不是同一台。
SIM ?= iPhone 16

.DEFAULT_GOAL := help
.PHONY: help server server-build server-release ios ios-build ios-device ios-device-build \
        service-install service-start service-stop service-status service-logs service-uninstall \
        service-resign-install service-resign-stop service-resign-status service-resign-logs \
        service-resign-uninstall resign-deps \
        clean

help:
	@echo "make server          编译并在前台运行采集服务端（Ctrl-C 退出）"
	@echo "make server ARGS=--dump   同上，另外每秒打印一行人类可读的采样"
	@echo "make ios             编译客户端并装进模拟器跑起来（SIM=<设备名> 换模拟器）"
	@echo "make ios-device      编译客户端并装进真机跑起来（真机必须插在 USB 上）"
	@echo "make ios-device-build  只编译真机版，不安装"
	@echo "make server-release  release 构建服务端并安装到 ~/Library/Application Support/iphone-screen-stats/"
	@echo "make service-install 安装并加载 launchd 自启服务（$(SERVICE_LABEL)）"
	@echo "make service-start   启动服务（未加载则先加载）"
	@echo "make service-stop    卸载服务（launchctl bootout；KeepAlive 下 kill 会被立刻拉起）"
	@echo "make service-status  查看服务的 launchd 状态"
	@echo "make service-logs    打印服务日志最后 $(LOGS_LINES) 行（LOGS_LINES=N 可改）"
	@echo "make service-uninstall  卸载服务并把 plist 移进废纸篓（安装的二进制与日志保留）"
	@echo "make service-resign-install   安装并加载客户端续签任务（每 $(RESIGN_INTERVAL) 秒检查一次）"
	@echo "make service-resign-stop      卸载续签任务"
	@echo "make service-resign-status    查看续签任务的 launchd 状态"
	@echo "make service-resign-logs      打印续签任务日志最后 $(LOGS_LINES) 行"
	@echo "make service-resign-uninstall 卸载续签任务并把 plist 移进废纸篓"
	@echo "make resign-deps     把 pymobiledevice3 装进 Application Support 下的 venv（续签启动 App 要用）"
	@echo "make clean           清掉 build/ 下的全部产物"

# --- 服务端 -----------------------------------------------------------------

server-build:
	$(SWIFT)

server: server-build
	$(SERVER_BIN) $(ARGS)

# release 构建 + 安装到 Application Support。服务跑的是这份安装副本，与 build/ 解耦。
server-release:
	$(SWIFT_RELEASE)
	@mkdir -p "$(INSTALL_DIR)"
	install -m 0755 "$(SERVER_RELEASE_BIN)" "$(INSTALLED_BIN)"
	@echo "已安装服务端：$(INSTALLED_BIN)"

# --- 客户端 -----------------------------------------------------------------

ios-build:
	xcodebuild \
		-project $(IOS_PROJECT) \
		-scheme $(IOS_SCHEME) \
		-configuration Debug \
		-destination 'platform=iOS Simulator,name=$(SIM),OS=latest' \
		-derivedDataPath $(IOS_DD) \
		CODE_SIGNING_ALLOWED=NO \
		build

ios: ios-build
	@# bootstatus -b 自带「没启动就启动」，不需要先跑一遍 simctl boot 再吞掉它的报错。
	@xcrun simctl bootstatus "$(SIM)" -b
	open -a Simulator
	xcrun simctl install "$(SIM)" "$(IOS_APP)"
	xcrun simctl launch "$(SIM)" $(IOS_BUNDLE)

# --- 客户端（真机） -----------------------------------------------------------

# 真机版必须签名，走 DEVELOPMENT_TEAM = LBSBA5HK8X（免费账号，profile 7 天过期）。
# UDID 用 `xcrun xcdevice list` 查——devicectl 看不到 iOS 15 的机器，查不出来。
IOS_DEVICE_UDID ?= e7fba5418946ae08f8e9978c9b1fe446dea67faf
IOS_DEV_APP     := $(IOS_DD)/Build/Products/Debug-iphoneos/ScreenStats.app

# 真机操作分两个工具，**别混用**：
#   装   → ios-deploy（brew，/opt/homebrew/bin）。devicectl 属于 CoreDevice 栈，只服务
#          iOS 17+，本机这台是 iOS 15.8.8，用 CoreDevice UUID 和 40 位 UDID 都报
#          `com.apple.dt.CoreDeviceError error 1000 (device not found)`（2026-11-03 实测）。
#   拉起 → pymobiledevice3 developer dvt launch，也就是 Xcode / Instruments 那条线，不挂调试器。
#          **不能用 ios-deploy 拉起**：它是拿调试器启动 App 的，命令一退 App 就被系统回收，
#          --justlaunch / -I / -N 三种模式全留不住（2026-11-03 实测）。详见 docs/roadmap.md M6。
IOS_DEPLOY ?= ios-deploy

ios-device-build:
	xcodebuild \
		-project $(IOS_PROJECT) \
		-scheme $(IOS_SCHEME) \
		-configuration Debug \
		-destination 'platform=iOS,id=$(IOS_DEVICE_UDID)' \
		-derivedDataPath $(IOS_DD) \
		-allowProvisioningUpdates \
		-allowProvisioningDeviceRegistration \
		build

ios-device: ios-device-build resign-deps
	@# ios-deploy 装成功时退出码也是 1，不能让它决定成败——判据看输出里的 `Installed package`。
	@# 临时文件用显式模板：本机 PATH 里 coreutils 的 gnubin 会盖住 BSD mktemp，
	@# 而 GNU mktemp 不认 BSD 的 `-t PREFIX` 写法（会报 "too few X's"）。
	@out=$$(mktemp "$${TMPDIR:-/tmp}/screenstats-install.XXXXXX"); \
	$(IOS_DEPLOY) --id $(IOS_DEVICE_UDID) --bundle "$(IOS_DEV_APP)" --no-wifi --justlaunch > $$out 2>&1 || true; \
	if grep -q "Installed package" $$out; then \
		echo "已安装：$(IOS_DEV_APP)"; \
	else \
		echo "装失败。输出末尾 15 行："; tail -n 15 $$out; trash $$out 2>/dev/null; exit 1; \
	fi; \
	trash $$out 2>/dev/null || true
	@# 拉起走 DVT：ios-deploy 那一下拉起来的 App 在它退出时就被系统回收了。
	"$(PYMOBILEDEVICE3)" developer dvt launch $(IOS_BUNDLE)

# --- 服务端自启（launchd） ----------------------------------------------------

# 从模板渲染 plist。sed 用 | 作分隔符，路径里的 / 不必转义。
$(PLIST): $(PLIST_TMPL)
	@mkdir -p "$(dir $(PLIST))" "$(LOG_DIR)"
	sed -e 's|__BIN__|$(INSTALLED_BIN)|g' -e 's|__LOG__|$(LOG_FILE)|g' "$(PLIST_TMPL)" > "$(PLIST)"

service-install: server-release $(PLIST)
	@# 先卸掉旧实例：bootstrap 一个已加载的 label 会报 "service already loaded"。
	@launchctl bootout gui/$(SERVICE_UID)/$(SERVICE_LABEL) >/dev/null 2>&1 || true
	launchctl bootstrap gui/$(SERVICE_UID) "$(PLIST)"
	@echo "已加载：gui/$(SERVICE_UID)/$(SERVICE_LABEL)"

service-start:
	@if launchctl print gui/$(SERVICE_UID)/$(SERVICE_LABEL) >/dev/null 2>&1; then \
		launchctl kickstart gui/$(SERVICE_UID)/$(SERVICE_LABEL); \
	else \
		launchctl bootstrap gui/$(SERVICE_UID) "$(PLIST)"; \
	fi

# 必须 bootout 而不是 kill：plist 里 KeepAlive = true，被 kill 的进程会被 launchd 立刻拉起。
service-stop:
	@launchctl bootout gui/$(SERVICE_UID)/$(SERVICE_LABEL) 2>/dev/null \
		|| echo "未加载：$(SERVICE_LABEL)"

service-status:
	@launchctl print gui/$(SERVICE_UID)/$(SERVICE_LABEL)

service-logs:
	@test -f "$(LOG_FILE)" || { echo "还没有日志：$(LOG_FILE)"; exit 1; }
	@tail -n $(LOGS_LINES) "$(LOG_FILE)"

# 只卸服务、只动 plist；安装的二进制与日志留在原地，方便再次 service-install。
service-uninstall:
	@launchctl bootout gui/$(SERVICE_UID)/$(SERVICE_LABEL) >/dev/null 2>&1 || true
	@if [ -f "$(PLIST)" ]; then \
		command -v trash >/dev/null || { echo "PATH 里没有 trash，请自己把 $(PLIST) 拖进废纸篓"; exit 1; }; \
		trash "$(PLIST)" && echo "已移进废纸篓：$(PLIST)"; \
	else \
		echo "没有 plist：$(PLIST)"; \
	fi

# --- 客户端续签（launchd） ----------------------------------------------------

# 装 pymobiledevice3 到稳定 venv。已经装过就跳过，不做无谓的 pip 往返。
resign-deps:
	@if [ -x "$(PYMOBILEDEVICE3)" ]; then \
		echo "pymobiledevice3 已在：$(PYMOBILEDEVICE3)"; \
	else \
		echo "创建 venv 并安装 pymobiledevice3（需要网络）..."; \
		python3 -m venv "$(RESIGN_VENV)"; \
		"$(RESIGN_VENV)/bin/pip" install --quiet --upgrade pip; \
		"$(RESIGN_VENV)/bin/pip" install --quiet pymobiledevice3; \
		echo "已安装：$(PYMOBILEDEVICE3)"; \
	fi

# 每次都重新渲染 plist：RESIGN_INTERVAL / RESIGN_ARGS 变了必须生效，
# 而 make 的文件依赖看不见命令行变量。
service-resign-install: resign-deps
	@mkdir -p "$(dir $(RESIGN_PLIST))" "$(LOG_DIR)"
	sed -e 's|__RESIGN_SH__|$(RESIGN_SH)|g' \
	    -e 's|__LOG__|$(RESIGN_LOG)|g' \
	    -e 's|__INTERVAL__|$(RESIGN_INTERVAL)|g' \
	    -e 's|__ARGS__|$(RESIGN_ARGS)|g' \
	    "$(RESIGN_TMPL)" > "$(RESIGN_PLIST)"
	@launchctl bootout gui/$(SERVICE_UID)/$(RESIGN_LABEL) >/dev/null 2>&1 || true
	launchctl bootstrap gui/$(SERVICE_UID) "$(RESIGN_PLIST)"
	@echo "已加载：gui/$(SERVICE_UID)/$(RESIGN_LABEL)（每 $(RESIGN_INTERVAL) 秒检查一次）"

service-resign-stop:
	@launchctl bootout gui/$(SERVICE_UID)/$(RESIGN_LABEL) 2>/dev/null \
		|| echo "未加载：$(RESIGN_LABEL)"

service-resign-status:
	@launchctl print gui/$(SERVICE_UID)/$(RESIGN_LABEL)

service-resign-logs:
	@test -f "$(RESIGN_LOG)" || { echo "还没有日志：$(RESIGN_LOG)"; exit 1; }
	@tail -n $(LOGS_LINES) "$(RESIGN_LOG)"

service-resign-uninstall:
	@launchctl bootout gui/$(SERVICE_UID)/$(RESIGN_LABEL) >/dev/null 2>&1 || true
	@if [ -f "$(RESIGN_PLIST)" ]; then \
		command -v trash >/dev/null || { echo "PATH 里没有 trash，请自己把 $(RESIGN_PLIST) 拖进废纸篓"; exit 1; }; \
		trash "$(RESIGN_PLIST)" && echo "已移进废纸篓：$(RESIGN_PLIST)"; \
	else \
		echo "没有 plist：$(RESIGN_PLIST)"; \
	fi

# --- 清理 -------------------------------------------------------------------

# 只清 build/ 这一处产物，不碰源码。build/ 已在 .gitignore 里。
# 走 trash 而不是 rm：本项目的铁律是不做真正的删除。
clean:
	@test -d "$(BUILD)" || { echo "没有 build/，无需清理"; exit 0; }
	@command -v trash >/dev/null || { echo "PATH 里没有 trash，请自己把 build/ 拖进废纸篓"; exit 1; }
	find "$(BUILD)" -mindepth 1 -maxdepth 1 -exec trash {} +
