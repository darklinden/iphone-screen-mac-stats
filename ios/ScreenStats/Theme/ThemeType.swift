//
//  ThemeType.swift
//  FlipClock
//
//  Created by Liu Chuan on 2020/12/01.
//  Copyright © 2020 LC. All rights reserved.
//

import UIKit

/// 主题类型
///
/// 从 flipClock 复制后删掉了 `.lightTheme`：副屏固定暗色，`LightTheme.swift` 没有进 `ios/`
/// （见 docs/design.md 的「从 flipClock 复用与改动」表）。
enum ThemeType {
    case darkTheme
    
    /// 主题类型所对应的主题对象
    var theme: ThemeProtocol {
        get {
            switch self {
            case .darkTheme:
                return DarkTheme()
            }
        }
    }
}
