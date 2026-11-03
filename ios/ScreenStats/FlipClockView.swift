//
//  FlipClockView.swift
//  FlipClock
//
//  Created by Liu Chuan on 2018/6/2.
//  Copyright © 2018年 LC. All rights reserved.
//
//  从 flipClock 复制，按 docs/design.md 的「从 flipClock 复用与改动」改造：
//  - 去掉底部工具栏与主题切换入口（原 :124-126 主题按钮图标、:193 工具栏创建、
//    :295 addSubview、:475-479 工具栏配色、:514-524 handleTap、:597/:606 滑入滑出 transform）
//  - `ThemeManager.sharedInstance.currentTheme` 换成注入的 `theme`
//  - 原单指滑动与单击手势（:306-308）不迁移；设置入口改由 DashboardViewController 的长按手势承担
//  - 不再 `import AudioToolbox`（副屏没有音效）

import UIKit


class FlipClockView: UIView {
    
    //MARK: - Attribute
    
    /// 创建日历对象
    var calendar = Calendar.current
    /// 日期的组件
    var dateComponent: DateComponents!
    
    /// 上一次写入 label 的星期值（避免每秒重复写 UILabel）
    private var lastWeekday: Int = -1
    
    /// 上一次写入 label 的年月日（避免每秒重复写 UILabel 与查询 Bundle）
    private var lastYearMonthDay: String = ""
    
    /// 上一次的上午/下午状态（避免每秒重建 DateFormatter）
    private var lastIsAM: Bool = false
    
    /// 正在执行翻转动画的 label（由统一调度器驱动）
    private var animatingLabels: [FlipClockLabel] = []
    
    /// 统一调度器是否已加入 RunLoop
    private var isAnimationLinkRunning = false
    
    /// 时间
    var date: Date? {
        didSet {
            //默认情况下，日历未设置语言环境。
            //如果您希望收到本地化的答案，请务必首先将locale属性设置为。Locale.autoupdatingCurrent
            calendar.locale = Locale.autoupdatingCurrent
            
            // NSDateComponents默认是24小时制式
            dateComponent = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: self.date!)
            
            // 是否上午（必须在 12 小时制换算前判断）
            let isAM = dateComponent.hour! < 12
            
            /* 12 小时制换算。
               原实现是 `if hour > 12 { hour -= 12 }`，漏了 0 点：0 点会显示 00 而不是 12。*/
            if is12HourClock {
                let hour = dateComponent.hour!
                dateComponent.hour = hour % 12 == 0 ? 12 : hour % 12
            }
            
            hourItem.time = dateComponent?.hour
            minuteItem.time = dateComponent?.minute
            secondItem.time = dateComponent?.second
            
            /* 「上午/下午」只在中午前后变一次。
               原实现只在 is12HourClock 被赋值时刷新，跨过中午后标签会一直停在旧值。*/
            if is12HourClock && isAM != lastIsAM {
                lastIsAM = isAM
                updateTimeSystemLabel()
            }
            
            /* 星期与年月日一天只变一次：值未变时不再写 UILabel（原实现每秒都写一遍）*/
            let weekday = dateComponent.weekday!
            if weekday != lastWeekday {
                lastWeekday = weekday
                weekdayLabel.text = getWeekdayWithNumber(weekday)
            }
            getYearMonthDay(year: dateComponent.year!, month: dateComponent.month!, day: dateComponent.day!)
            
            // 收集本次真正开始翻转的 label，交给统一的 CADisplayLink 驱动
            collectAnimatingLabels()
        }
    }
    
    /// 是否为十二小时制  (默认：24小时制。FALSE,)
    var is12HourClock: Bool = false {
        didSet {
            guard is12HourClock != oldValue else { return }
            // 24 小时制下不显示「上午/下午」
            updateTimeSystemLabel()
            // 立刻按新制式重绘小时数字（否则要等下一秒定时器才刷新）
            if let current = date {
                date = current
            }
        }
    }
    
    /// 是否可见工作日、普通日 。(星期天及星期六以外的) 任何一天
    var weekdayIsVisible: Bool = false {
        didSet {
            weekdayLabel.isHidden = !weekdayIsVisible
        }
    }
    
    /// 年月日是否可见
    var yearMonthDayIsVisible: Bool = false {
        didSet {
            yearToDateLabel.isHidden = !yearMonthDayIsVisible
        }
    }
    
    /// 字体
    var font: UIFont? {
        didSet {
            hourItem.font = font
            minuteItem.font = font
            secondItem.font = font
        }
    }
    
    /// 注入的配色（默认：暗黑模式）
    ///
    /// 原实现是 `flipClockTheme` + `ThemeManager.sharedInstance.currentTheme` 的全局单例，
    /// 这里改成由外部注入，见 docs/design.md 的复用表。
    var theme: ThemeProtocol = DarkTheme() {
        didSet {
            applyTheme()
        }
    }
    
    // MARK: Lazy loading
    /// 小时
    private lazy var hourItem: FlipClockItem = {
        let hour = FlipClockItem()
        hour.type = .FlipClockItemTypeHour
        return hour
    }()
    
    /// 分钟
    private lazy var minuteItem: FlipClockItem = {
        let minute = FlipClockItem()
        minute.type = .FlipClockItemTypeMinute
        return minute
    }()
    
    /// 秒
    private lazy var secondItem: FlipClockItem = {
        let second = FlipClockItem()
        second.type = .FlipClockItemTypeSecond
        return second
    }()
    
    /// 时间制式label
    private lazy var timeSystemLabel: UILabel = {
        let timeSystemLabel = UILabel(frame: CGRect(x: 20, y: 10, width: 215, height: 30))
        timeSystemLabel.textColor = theme.textColor
        timeSystemLabel.font = UIFont(name: "HelveticaNeue-CondensedBold", size: 20)
        timeSystemLabel.backgroundColor = .clear
        return timeSystemLabel
    }()
    
    /// 工作日label
    private lazy var weekdayLabel: UILabel = {
        let label = UILabel(frame: CGRect(x: 20, y: 10, width: 215, height: 30))
        label.textColor = theme.textColor
        label.isHidden = true   // 默认为：隐藏
        label.font = UIFont(name: "HelveticaNeue-CondensedBold", size: 20)
        label.backgroundColor = .clear
        return label
    }()
    
    /// 年月日label
    private lazy var yearToDateLabel: UILabel = {
        let label = UILabel(frame: CGRect(x: 20, y: 10, width: 215, height: 30))
        label.textColor = theme.textColor
        label.isHidden = true   // 默认为：隐藏
        label.font = UIFont(name: "HelveticaNeue-CondensedBold", size: 20)
        label.backgroundColor = .clear
        return label
    }()
    
    /// 翻转动画的统一调度器（所有 label 共用一个，30fps）
    private lazy var animationLink: CADisplayLink = {
        let link = CADisplayLink(target: self, selector: #selector(stepFlipAnimations))
        link.preferredFramesPerSecond = 30
        return link
    }()
    
    // MARK: - Initialization
    override init(frame: CGRect) {
        super.init(frame: frame)
        configUI()
    }
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Lifecycle
extension FlipClockView {
    
    /* 布局尺寸必须在 layoutSubViews 中, 否则获取的 size 不正确 **/
    override func layoutSubviews() {
        super.layoutSubviews()
        
        /// 间距
        let margin: CGFloat = 0.07 * bounds.size.width
        /// 每个item的宽度
        let itemW: CGFloat = (bounds.size.width - 4 * margin) / 3
        /// 每个item的Y值
        let itemY: CGFloat = (bounds.size.height - itemW) / 2
/*
        UIView.animate(withDuration: 0.25) {
            self.hourItem.frame = CGRect(x: margin, y: itemY, width: itemW, height: itemW)
            self.minuteItem.frame = CGRect(x: self.hourItem.frame.maxX + margin, y: itemY, width: itemW, height: itemW)
            self.secondItem.frame = CGRect(x: self.minuteItem.frame.maxX + margin, y: itemY, width: itemW, height: itemW)
        } completion: { (finish) in
            print("布局完成。。。")
        }
*/
        hourItem.frame = CGRect(x: margin, y: itemY, width: itemW, height: itemW)
        minuteItem.frame = CGRect(x: hourItem.frame.maxX + margin, y: itemY, width: itemW, height: itemW)
        secondItem.frame = CGRect(x: minuteItem.frame.maxX + margin, y: itemY, width: itemW, height: itemW)
        
        /* 字体大小必须跟随卡片尺寸缩放。
           原实现写死 200 / 280，只在大屏横屏（卡片宽约 215pt）下合适；
           小屏（如 4 英寸 SE，卡片宽约 136pt）数字会被裁掉左右两边。*/
        let itemFont = UIFont(name: "HelveticaNeue-CondensedBold", size: itemW * 0.88)
        if font?.pointSize != itemFont?.pointSize {
            font = itemFont
        }
        
        /* 卡片顶部标签（上午/下午、星期、日期）同样按卡片尺寸定位，
           原实现写死 frame(x: 20, y: 10, width: 215)，小屏上会溢出卡片并压在数字上。*/
        let labelFont = UIFont(name: "HelveticaNeue-CondensedBold", size: max(9, itemW * 0.085))
        let labelX = itemW * 0.08
        for label in [timeSystemLabel, weekdayLabel, yearToDateLabel] {
            label.frame = CGRect(x: labelX,
                                 y: itemW * 0.045,
                                 width: itemW - labelX * 2,
                                 height: max(12, itemW * 0.13))
            label.font = labelFont
        }
    }
    
    /* 告诉视图其窗口对象即将更改。**/
    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil {
            // 移除通知
            NotificationCenter.default.removeObserver(self)
            // 停止翻转动画调度，避免离开窗口后继续空转
            animatingLabels.removeAll()
            stopAnimationLink()
        }
    }
    
}

// MARK: - Configuration
extension FlipClockView {
    
    private func configUI() {
        addSubview(hourItem)
        addSubview(minuteItem)
        addSubview(secondItem)
        hourItem.addSubview(timeSystemLabel)
        minuteItem.addSubview(weekdayLabel)
        secondItem.addSubview(yearToDateLabel)
        
        applyTheme()
    }
    
    /// 把注入的配色应用到自身与所有子视图
    ///
    /// 原实现靠 `ThemeManager` 发通知触发 `handleNotification`，现在只有一种配色，
    /// 直接同步应用即可。
    private func applyTheme() {
        backgroundColor = theme.backgroudColor
        timeSystemLabel.textColor = theme.textColor
        weekdayLabel.textColor = theme.textColor
        yearToDateLabel.textColor = theme.textColor
        hourItem.updateLabelThemeColor(theme)
        minuteItem.updateLabelThemeColor(theme)
        secondItem.updateLabelThemeColor(theme)
    }
}

// MARK: - Convert Time Format
extension FlipClockView {
    
    /// 刷新卡片左上角的「上午/下午」标签
    ///
    /// 24 小时制下隐藏该标签（原实现切到 24 小时制时只是 print 一句，标签会残留旧的「下午」）。
    private func updateTimeSystemLabel() {
        timeSystemLabel.isHidden = !is12HourClock
        timeSystemLabel.text = is12HourClock ? convertTimeFormat() : nil
    }
    
    /// 转换时间制式 （24 - > 12小时制）
    ///
    /// - Returns: String
    private func convertTimeFormat() -> String {
        let df = DateFormatter()
        
        // 跟踪用户当前偏好的语言环境。自动更新的语言环境
        df.locale = Locale.autoupdatingCurrent
        
        // 设置时间格式
        /*
         “a”:是AM / PM指示符的ICU符号。
         它永远不可能是“ A”，因为ICU使用“A”:来表示完全不同的东西（一天中的毫秒数）。
         */
        
        df.dateFormat = "a"
        
        //df.amSymbol = "AM"
        //df.pmSymbol = "PM"
        // 指定时区
        // df.timeZone = TimeZone(identifier: "Asia/Shanghai")
        
        //设置时区: 系统当前使用的时区
        df.timeZone = TimeZone.current
        
        // 调用string方法进行转换
        return df.string(from: Date())
    }
    
    /// 根据数字获取工作日
    /// - Parameter number: 数字
    private func getWeekdayWithNumber(_ number: Int) -> String? {
        switch number {     // 使用本地化字符串
        case 1:
            return NSLocalizedString("Sun", comment: "")
        case 2:
            return NSLocalizedString("Mon", comment: "")
        case 3:
            return NSLocalizedString("Tues", comment: "")
        case 4:
            return NSLocalizedString("Wed", comment: "")
        case 5:
            return NSLocalizedString("Thur", comment: "")
        case 6:
            return NSLocalizedString("Fri", comment: "")
        case 7:
            return NSLocalizedString("Sat", comment: "")
        default:
            return ""
        }
    }
    
    /// 获取年月日 （ 区分语言环境 ）
    private func getYearMonthDay(year: Int, month: Int, day: Int) {
        /* 年月日一天只变一次：值未变时直接返回，省掉 UILabel 写入与 Bundle 查询 */
        let key = "\(year)-\(month)-\(day)"
        guard key != lastYearMonthDay else { return }
        lastYearMonthDay = key
        
        /*
         1）英式的日期：日/月/年；Day/Month/Year
         2）美式的日期：月/日/年；Month/Day/Year
         */
        
        /// 首选语言：捆绑软件中包含的首选本地化的有序列表第一个
        let preferredLang = Bundle.main.preferredLocalizations.first!
        //print("当前系统语言:\(preferredLang)")
        
        switch preferredLang {
        case "en-US", "en-CN":  // 英文
            yearToDateLabel.text = "\(month) / \(day) / \(year)"
        case "zh-Hans-US","zh-Hans-CN","zh-Hant-CN","zh-TW","zh-HK","zh-Hans":  // 中文
            yearToDateLabel.text = "\(year)年\(month)月\(day)日"
        default:
            yearToDateLabel.text = "\(month) / \(day) / \(year)"  // 默认英文
        }
    }
    
}

// MARK: - Flip Animation Driver
extension FlipClockView {
    
    /// 收集本次真正开始翻转的 label，并按需启动统一调度器
    private func collectAnimatingLabels() {
        for label in hourItem.animatingLabels + minuteItem.animatingLabels + secondItem.animatingLabels
        where !animatingLabels.contains(where: { $0 === label }) {
            animatingLabels.append(label)
        }
        startAnimationLinkIfNeeded()
    }
    
    /// 统一调度器的一帧：驱动所有正在翻转的 label
    @objc private func stepFlipAnimations() {
        let now = CACurrentMediaTime()
        animatingLabels.removeAll { !$0.step(now: now) }
        if animatingLabels.isEmpty {
            stopAnimationLink()
        }
    }
    
    /// 启动统一调度器
    private func startAnimationLinkIfNeeded() {
        guard !isAnimationLinkRunning, !animatingLabels.isEmpty else { return }
        isAnimationLinkRunning = true
        animationLink.add(to: RunLoop.main, forMode: RunLoop.Mode.common)
    }
    
    /// 停止统一调度器
    private func stopAnimationLink() {
        guard isAnimationLinkRunning else { return }
        isAnimationLinkRunning = false
        animationLink.remove(from: RunLoop.main, forMode: RunLoop.Mode.common)
    }
    
}

