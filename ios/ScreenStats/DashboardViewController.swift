import UIKit

/// 副屏的根视图控制器：上 160pt 指标区（M4），下翻页时钟带（M3）。
///
/// 布局见 docs/design.md 的「界面规格」。`FlipClockView` 按自己的 `bounds` 布局，
/// 这里只负责把 `y = 160` 以下的整块区域交给它。
final class DashboardViewController: UIViewController {

    /// 指标区高度（design.md 的界面规格）
    private let metricsPanelHeight: CGFloat = 160

    /// 指标区（M4）
    private let metricsPanel = MetricsPanelView(frame: .zero)

    /// 翻页时钟
    private let flipClock = FlipClockView(frame: .zero)

    /// 1 Hz 轮询服务端（M4）；与下面的走时定时器互相独立
    private let poller = StatsPoller()

    /// 走时定时器
    private var timer: DispatchSourceTimer?

    deinit {
        NotificationCenter.default.removeObserver(self)
        timer?.cancel()
        poller.stop()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // 副屏固定暗色（design.md 的复用表：LightTheme 不进 ios/）
        overrideUserInterfaceStyle = .dark
        // 常亮副屏：禁止自动熄屏（design.md 的「常亮」）
        UIApplication.shared.isIdleTimerDisabled = true

        // 指标区：上 160pt，走网络，绝不阻塞下面的时钟
        metricsPanel.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: metricsPanelHeight)
        view.addSubview(metricsPanel)

        poller.onStats = { [weak self] stats in
            self?.metricsPanel.apply(stats)
        }
        poller.onState = { [weak self] state in
            self?.metricsPanel.setState(state)
        }
        // M5 写完 UserDefaults（serverHost / serverPort）后不需要额外通知，
        // 这里重新读一次配置即可生效。配置只有 ServerConfig 一个读取点。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleServerConfigChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )

        // 时钟带：年月日与星期都显示，用 24 小时制
        flipClock.theme = DarkTheme()
        flipClock.weekdayIsVisible = true
        flipClock.yearMonthDayIsVisible = true
        flipClock.is12HourClock = false
        flipClock.date = Date()
        // 时钟带只占 y = 160 以下；它自己的子视图可能画到边界外（M3 时上方没有内容所以看不出来），
        // 这里裁到自己的 bounds，避免盖住上面的指标区。
        flipClock.clipsToBounds = true
        view.addSubview(flipClock)

        // 设置入口：长按整个屏幕 2 秒（design.md 的「设置入口」）
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 2
        view.addGestureRecognizer(longPress)

        startTimer()
        poller.start()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        metricsPanel.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: metricsPanelHeight)
        flipClock.frame = CGRect(
            x: 0,
            y: metricsPanelHeight,
            width: view.bounds.width,
            height: max(0, view.bounds.height - metricsPanelHeight)
        )
    }

    // MARK: - 配置变更（M5 的接口）

    @objc private func handleServerConfigChange() {
        // 重新读配置、重置基线；未配置就显示「未配置服务器」
        poller.start()
    }

    override var prefersStatusBarHidden: Bool { true }

    // MARK: - 设置入口

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        // 只在手势开始时 present，避免长按期间重复触发
        guard recognizer.state == .began else { return }
        present(SettingsViewController(), animated: true)
    }

    // MARK: - 走时

    /// 启动秒表：首次触发对齐到墙钟的整秒边界，避免显示秒最多滞后 1 秒。
    private func startTimer() {
        stopTimer()
        let now = Date()
        /// 距离下一个整秒的时间
        let delay = 1 - now.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + delay, repeating: .seconds(1), leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in
            self?.flipClock.date = Date()
        }
        source.resume()
        timer = source
    }

    /// 停止秒表
    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}
