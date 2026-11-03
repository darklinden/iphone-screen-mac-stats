//
//  FlipClockLabel.swift
//  FlipClock
//
//  Created by Liu Chuan on 2018/6/3.
//  Copyright © 2018年 LC. All rights reserved.
//
//  从 flipClock 复制。改动：把 `ThemeManager.sharedInstance.currentTheme`
//  换成由 `FlipClockItem` 注入的 `currentTextColor` / `currentBackgroundColor`
//  （见 docs/design.md 的「从 flipClock 复用与改动」表）。
//

import UIKit


/// 下一个label开始值
private let NextLabelStartValue: CGFloat = 0.01


class FlipClockLabel: UIView {

    //MARK: Attribute
    
    /// 单次翻转动画的时长（秒）
    private let flipDuration: CFTimeInterval = 0.5

    /// 本次翻转动画的起始时间（CACurrentMediaTime 基准）
    private var animationStart: CFTimeInterval = 0

    /// 是否正在执行翻转动画（由 FlipClockView 的统一调度器读取）
    private(set) var isAnimating: Bool = false

    /// 上一帧的折叠状态，避免每帧重复写 UILabel
    private var lastFolded: Bool?

    /// 上一帧 nextLabel 的可见性，避免每帧重复写 isHidden
    private var lastNextVisible: Bool?
    
    /// 字体
    var font: UIFont? {
        didSet {
            timeLabel.font = font
            foldLabel.font = font
            nextLabel.font = font
        }
    }
    
    /// 当前文字颜色（由 `FlipClockItem.updateLabelThemeColor(_:)` 注入，不再读全局单例）
    var currentTextColor: UIColor? {
        didSet {
            timeLabel.textColor = currentTextColor
            foldLabel.textColor = currentTextColor
            nextLabel.textColor = currentTextColor
        }
    }
    /// 当前背景色（由 `FlipClockItem.updateLabelThemeColor(_:)` 注入，不再读全局单例）
    var currentBackgroundColor: UIColor? {
        didSet {
            timeLabel.backgroundColor = currentBackgroundColor
            foldLabel.backgroundColor = currentBackgroundColor
            nextLabel.backgroundColor = currentBackgroundColor
        }
    }
    
    /// 文字对齐方式 （默认，居左对齐）
    var textAlignment: NSTextAlignment = .left {
        didSet {
            timeLabel.textAlignment = textAlignment
            foldLabel.textAlignment = textAlignment
            nextLabel.textAlignment = textAlignment
        }
    }
    
    //MARK: Lazy loading
    
    /// 当前时间label
    private lazy var timeLabel: UILabel = {
        let timeLabel = UILabel()
        configLabel(timeLabel)
        return timeLabel
    }()
    
    /// 翻转动画label
    private lazy var foldLabel: UILabel = {
        let foldLabel = UILabel()
        configLabel(foldLabel)
        return foldLabel
    }()
    
    /// 下一个时间label
    private lazy var nextLabel: UILabel = {
        let nextLabel = UILabel()
        configLabel(nextLabel)
        return nextLabel
    }()
    
    /// 放置label的容器
    private lazy var labelContainer: UIView = {
        let labelContainer = UIView()
        return labelContainer
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
extension FlipClockLabel {
    
    /** 布局尺寸必须在 layoutSubViews 中, 否则获取的 size 不正确 **/
    override func layoutSubviews() {
        super.layoutSubviews()
        labelContainer.frame = self.bounds
        timeLabel.frame = labelContainer.bounds
        nextLabel.frame = labelContainer.bounds
        foldLabel.frame = labelContainer.bounds
    }
}

// MARK: - Configuration
extension FlipClockLabel {
    
    /// 配置UI
    private func configUI() {
        addSubview(labelContainer)
        labelContainer.addSubview(timeLabel)
        labelContainer.addSubview(nextLabel)
        labelContainer.addSubview(foldLabel)
    }
    
    /// 配置UILabel
    ///
    /// - Parameter label: UILabel
    private func configLabel(_ label: UILabel) {
        //label.textAlignment = .center
        label.font = UIFont(name: "HelveticaNeue-CondensedBold", size: 200)
        label.layer.masksToBounds = true
        label.textColor = currentTextColor
        label.backgroundColor = currentBackgroundColor
    }

    /// 更新时间
    ///
    /// - Parameters:
    ///   - time: 时间
    ///   - nextTime: 下一个时间
    public func updateTime(_ time: Int, nextTime: Int) {
        timeLabel.text = "\(time)"
        foldLabel.text = "\(time)"
        nextLabel.text = "\(nextTime)"
        nextLabel.layer.transform = nextLabelStartTransform()
        nextLabel.isHidden = true
        foldLabel.layer.transform = CATransform3DIdentity
        lastFolded = nil
        lastNextVisible = nil
        /* 以真实时间为基准，动画时长不再随帧率漂移。
           由 FlipClockView 的统一 CADisplayLink 驱动 step(now:)。*/
        animationStart = CACurrentMediaTime()
        isAnimating = true
    }
}

//MARK: - Animations
extension FlipClockLabel {
    
    /// 下一个label开始动画 默认label起始角度
    ///
    /// - Returns: CATransform3D
    private func nextLabelStartTransform() -> CATransform3D {
        var t: CATransform3D = CATransform3DIdentity
        t.m34 = CGFloat.leastNormalMagnitude
        t = CATransform3DRotate(t, CGFloat(.pi * Double(NextLabelStartValue)), -1, 0, 0)
        return t
    }
    
    /// 由 FlipClockView 的统一调度器驱动一帧
    ///
    /// - Parameter now: 当前时间（CACurrentMediaTime 基准）
    /// - Returns: true 表示动画尚未结束，仍需继续调度
    @discardableResult
    func step(now: CFTimeInterval) -> Bool {
        let elapsed = (now - animationStart) / flipDuration
        /* 末帧必须也落到 progress = 1（旋转 360° ≡ 原始朝向）。
           30fps 下最后一帧通常停在 0.93 左右，若直接结束，foldLabel 会一直保持
           约 12° 的倾角直到下一秒 updateTime 才被拉平。*/
        let progress = CGFloat(min(max(elapsed, 0), 1))
        
        var t: CATransform3D = CATransform3DIdentity
        t.m34 = CGFloat.leastNormalMagnitude
        
        // 绕x轴进行翻转
        t = CATransform3DRotate(t, .pi * progress, -1, 0, 0)
        let folded = progress >= 0.5
        if folded {
            // 当翻转到和屏幕垂直时，翻转y和z轴
            t = CATransform3DRotate(t, .pi, 0, 0, 1)
            t = CATransform3DRotate(t, .pi, 0, 1, 0)
        }
        foldLabel.layer.transform = t
        
        // 当翻转到和屏幕垂直时，切换动画label的字（只在跨过中点时写一次）
        if folded != lastFolded {
            foldLabel.text = folded ? nextLabel.text : timeLabel.text
            lastFolded = folded
        }
        
        // 当翻转到指定角度时，显示下一秒的时间（只在可见性变化时写一次）
        let nextVisible = progress > NextLabelStartValue
        if nextVisible != lastNextVisible {
            nextLabel.isHidden = !nextVisible
            lastNextVisible = nextVisible
        }
        
        let finished = elapsed >= 1
        if finished {
            isAnimating = false
        }
        return !finished
    }
    
}
