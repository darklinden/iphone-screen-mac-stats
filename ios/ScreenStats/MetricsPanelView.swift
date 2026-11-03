import UIKit

/// 指标区：3 条进度条（CPU / GPU / MEM）+ 2 行数据（DISK / NET）。
///
/// 布局见 docs/design.md 的「界面规格」。高度 160pt 的算术必须闭合：
///
/// ```
/// 顶部留白 10
/// 3 × 进度条行 26 + 2 × 行距 6  = 90   → 末行结束于 100
/// 区块间隔 10                          → 数据区起于 110
/// 2 × 数据行 20 + 1 × 行距 4    = 44   → 末行结束于 154
/// 底部留白 6
///                               合计 160 ✓
/// ```
///
/// 宽度随 `bounds` 自适应，不写死 667。
final class MetricsPanelView: UIView {

    // MARK: - 垂直算术（design.md 的界面规格）
    private let topInset: CGFloat = 10
    private let progressRowHeight: CGFloat = 26
    private let progressRowGap: CGFloat = 6
    private let blockGap: CGFloat = 10
    private let dataRowHeight: CGFloat = 20
    private let dataRowGap: CGFloat = 4
    private let bottomInset: CGFloat = 6

    // MARK: - 水平（design.md 未规定，按对称边距取 12）
    private let sideInset: CGFloat = 12

    private let progressRows = [
        ProgressRowView(name: "CPU"),
        ProgressRowView(name: "GPU"),
        ProgressRowView(name: "MEM"),
    ]
    private let diskRow = DataRowView(name: "DISK")
    private let netRow = DataRowView(name: "NET")

    private let unconfiguredLabel = UILabel()
    private let statusLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear

        for row in progressRows { addSubview(row) }
        addSubview(diskRow)
        addSubview(netRow)

        unconfiguredLabel.text = "未配置服务器"
        unconfiguredLabel.textColor = .lightText
        unconfiguredLabel.font = .systemFont(ofSize: 20, weight: .medium)
        unconfiguredLabel.textAlignment = .center
        unconfiguredLabel.isHidden = true
        addSubview(unconfiguredLabel)

        // 角落状态：失联 / 停更。放在顶部留白区、右对齐；数值区此时显示 `--`。
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .lightText
        statusLabel.textAlignment = .right
        statusLabel.isHidden = true
        addSubview(statusLabel)

        setState(.normal)
    }

    // MARK: - 渲染

    /// 渲染一次成功的采样。单项为 `null` 时该项显示 `--`，其余正常。
    func apply(_ stats: StatsResponse) {
        progressRows[0].apply(ratio: stats.cpu?.total)
        progressRows[1].apply(ratio: stats.gpu?.util)
        progressRows[2].apply(ratio: memoryRatio(stats.mem))

        diskRow.apply(
            left: DataRowView.Value(symbol: "R", text: MetricsFormat.rate(stats.disk?.readBps)),
            right: DataRowView.Value(symbol: "W", text: MetricsFormat.rate(stats.disk?.writeBps))
        )
        netRow.apply(
            left: DataRowView.Value(symbol: "↓", text: MetricsFormat.rate(stats.net?.rxBps)),
            right: DataRowView.Value(symbol: "↑", text: MetricsFormat.rate(stats.net?.txBps))
        )
    }

    /// 切换显示状态。故障态整体降到 40% 不透明度并全显 `--`；未配置只显示一行文案。
    func setState(_ state: MetricsState) {
        switch state {
        case .unconfigured:
            setRowsHidden(true)
            unconfiguredLabel.isHidden = false
            statusLabel.isHidden = true
            alpha = 1

        case .normal:
            setRowsHidden(false)
            unconfiguredLabel.isHidden = true
            statusLabel.isHidden = true
            alpha = 1

        case .unreachable(let seconds):
            setRowsHidden(false)
            unconfiguredLabel.isHidden = true
            statusLabel.text = "失联 \(seconds)s"
            statusLabel.isHidden = false
            alpha = 0.4
            showPlaceholders()

        case .stale(let seconds):
            setRowsHidden(false)
            unconfiguredLabel.isHidden = true
            statusLabel.text = "停更 \(seconds)s"
            statusLabel.isHidden = false
            alpha = 0.4
            showPlaceholders()
        }
    }

    /// 故障态：数值全显 `--`，进度条清空
    private func showPlaceholders() {
        for row in progressRows { row.apply(ratio: nil) }
        diskRow.apply(
            left: DataRowView.Value(symbol: "R", text: "--"),
            right: DataRowView.Value(symbol: "W", text: "--")
        )
        netRow.apply(
            left: DataRowView.Value(symbol: "↓", text: "--"),
            right: DataRowView.Value(symbol: "↑", text: "--")
        )
    }

    private func setRowsHidden(_ hidden: Bool) {
        for row in progressRows { row.isHidden = hidden }
        diskRow.isHidden = hidden
        netRow.isHidden = hidden
    }

    private func memoryRatio(_ mem: StatsMem?) -> Double? {
        guard let mem, let total = mem.totalBytes, let used = mem.usedBytes, total > 0 else {
            return nil
        }
        return min(1, max(0, Double(used) / Double(total)))
    }

    // MARK: - 布局

    override func layoutSubviews() {
        super.layoutSubviews()

        let contentWidth = max(0, bounds.width - sideInset * 2)
        var y = topInset

        for (index, row) in progressRows.enumerated() {
            row.frame = CGRect(x: sideInset, y: y, width: contentWidth, height: progressRowHeight)
            y += progressRowHeight
            if index < progressRows.count - 1 { y += progressRowGap }
        }
        y += blockGap

        let dataRows = [diskRow, netRow]
        for (index, row) in dataRows.enumerated() {
            row.frame = CGRect(x: sideInset, y: y, width: contentWidth, height: dataRowHeight)
            y += dataRowHeight
            if index < dataRows.count - 1 { y += dataRowGap }
        }

        unconfiguredLabel.frame = bounds
        // 顶部留白只有 10pt：状态标签放 y = 0..14，位于进度条行内文字的**上方**，不与其重叠。
        statusLabel.frame = CGRect(x: sideInset, y: 0, width: contentWidth, height: 14)
    }
}

// MARK: - 数值格式

/// design.md 的「数值格式」与「进度条阈值色」
private enum MetricsFormat {

    /// 百分比：整数 + `%`
    static func percent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    /// 速率：自动换算 B/s → KB/s → MB/s → GB/s，保留 1 位小数；`nil` → `--`
    static func rate(_ bytesPerSecond: Int?) -> String {
        guard let bytesPerSecond else { return "--" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var value = Double(max(0, bytesPerSecond))
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }

    /// 阈值色：< 60% 绿、60–85% 黄、≥ 85% 红；`nil` 用暗灰（空进度条底色）
    static func color(for ratio: Double?) -> UIColor {
        guard let ratio else { return UIColor(white: 0.28, alpha: 1) }
        if ratio < 0.60 { return UIColor(red: 0.30, green: 0.78, blue: 0.35, alpha: 1) }
        if ratio < 0.85 { return UIColor(red: 0.95, green: 0.77, blue: 0.20, alpha: 1) }
        return UIColor(red: 0.92, green: 0.26, blue: 0.21, alpha: 1)
    }
}

// MARK: - 进度条行

/// `CPU ████████░░░░ 62%` 一行
private final class ProgressRowView: UIView {

    private let nameLabel = UILabel()
    private let track = UIView()
    private let fill = UIView()
    private let valueLabel = UILabel()

    private let barHeight: CGFloat = 14
    private let nameWidth: CGFloat = 52
    private let valueWidth: CGFloat = 64
    private let barGap: CGFloat = 10

    private var fillRatio: CGFloat = 0

    init(name: String) {
        super.init(frame: .zero)

        nameLabel.text = name
        nameLabel.font = .monospacedSystemFont(ofSize: 17, weight: .semibold)
        nameLabel.textColor = .lightText

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .regular)
        valueLabel.textColor = .lightText
        valueLabel.textAlignment = .right

        track.backgroundColor = UIColor(white: 0.22, alpha: 1)
        track.layer.cornerRadius = barHeight / 2
        track.clipsToBounds = true

        fill.layer.cornerRadius = barHeight / 2

        addSubview(nameLabel)
        addSubview(track)
        track.addSubview(fill)
        addSubview(valueLabel)

        apply(ratio: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `ratio` 为 nil（读不到）时显示 `--`、进度条清空
    func apply(ratio: Double?) {
        if let ratio {
            fillRatio = CGFloat(min(1, max(0, ratio)))
            valueLabel.text = MetricsFormat.percent(ratio)
        } else {
            fillRatio = 0
            valueLabel.text = "--"
        }
        fill.backgroundColor = MetricsFormat.color(for: ratio)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let height = bounds.height
        nameLabel.frame = CGRect(x: 0, y: 0, width: nameWidth, height: height)
        valueLabel.frame = CGRect(x: bounds.width - valueWidth, y: 0, width: valueWidth, height: height)

        let barX = nameWidth + barGap
        let barWidth = max(0, bounds.width - barX - valueWidth - barGap)
        track.frame = CGRect(x: barX, y: (height - barHeight) / 2, width: barWidth, height: barHeight)
        fill.frame = CGRect(x: 0, y: 0, width: track.bounds.width * fillRatio, height: barHeight)
    }
}

// MARK: - 数据行

/// `DISK   R 12.4 MB/s    W 3.1 MB/s` 一行
private final class DataRowView: UIView {

    struct Value {
        let symbol: String
        let text: String
    }

    private let nameLabel = UILabel()
    private let leftLabel = UILabel()
    private let rightLabel = UILabel()

    private let nameWidth: CGFloat = 52
    private let columnGap: CGFloat = 10

    init(name: String) {
        super.init(frame: .zero)

        nameLabel.text = name
        nameLabel.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        nameLabel.textColor = .lightText

        for label in [leftLabel, rightLabel] {
            label.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
            label.textColor = .lightText
        }

        addSubview(nameLabel)
        addSubview(leftLabel)
        addSubview(rightLabel)

        apply(left: Value(symbol: "R", text: "--"), right: Value(symbol: "W", text: "--"))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(left: Value, right: Value) {
        leftLabel.text = "\(left.symbol)  \(left.text)"
        rightLabel.text = "\(right.symbol)  \(right.text)"
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let height = bounds.height
        nameLabel.frame = CGRect(x: 0, y: 0, width: nameWidth, height: height)

        let start = nameWidth + columnGap
        let available = max(0, bounds.width - start)
        let columnWidth = available / 2
        leftLabel.frame = CGRect(x: start, y: 0, width: columnWidth, height: height)
        rightLabel.frame = CGRect(x: start + columnWidth, y: 0, width: columnWidth, height: height)
    }
}
