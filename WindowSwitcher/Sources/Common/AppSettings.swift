import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Thumbnail settings
    @Published var thumbnailHeight: CGFloat {
        didSet { defaults.set(thumbnailHeight, forKey: Keys.thumbnailHeight) }
    }
    @Published var thumbnailMaxWidth: CGFloat {
        didSet { defaults.set(thumbnailMaxWidth, forKey: Keys.thumbnailMaxWidth) }
    }
    @Published var thumbnailCornerRadius: CGFloat {
        didSet { defaults.set(thumbnailCornerRadius, forKey: Keys.thumbnailCornerRadius) }
    }
    @Published var thumbnailSpacing: CGFloat {
        didSet { defaults.set(thumbnailSpacing, forKey: Keys.thumbnailSpacing) }
    }
    @Published var maxVisibleCount: Int {
        didSet { defaults.set(maxVisibleCount, forKey: Keys.maxVisibleCount) }
    }
    @Published var focusScale: CGFloat {
        didSet { defaults.set(focusScale, forKey: Keys.focusScale) }
    }
    @Published var animationDuration: TimeInterval {
        didSet { defaults.set(animationDuration, forKey: Keys.animationDuration) }
    }

    // MARK: - Mode settings
    @Published var immersiveModeEnabled: Bool {
        didSet { defaults.set(immersiveModeEnabled, forKey: Keys.immersiveModeEnabled) }
    }
    @Published var quickSwitchModeEnabled: Bool {
        didSet { defaults.set(quickSwitchModeEnabled, forKey: Keys.quickSwitchModeEnabled) }
    }
    @Published var quickSwitchHintEnabled: Bool {
        didSet { defaults.set(quickSwitchHintEnabled, forKey: Keys.quickSwitchHintEnabled) }
    }
    @Published var cyclicScrollEnabled: Bool {
        didSet { defaults.set(cyclicScrollEnabled, forKey: Keys.cyclicScrollEnabled) }
    }

    // MARK: - Gesture settings
    @Published var sensitivityLevel: Int {
        didSet { defaults.set(sensitivityLevel, forKey: Keys.sensitivityLevel) }
    }
    /// 三指同步触地检测时间窗口（秒）
    @Published var touchdownWindow: Double {
        didSet { defaults.set(touchdownWindow, forKey: Keys.touchdownWindow) }
    }
    /// 三指轻点激活沉浸预览模式
    @Published var threeFingerTapEnabled: Bool {
        didSet { defaults.set(threeFingerTapEnabled, forKey: Keys.threeFingerTapEnabled) }
    }
    /// 三指上扫激活沉浸预览模式
    @Published var threeFingerSwipeUpEnabled: Bool {
        didSet { defaults.set(threeFingerSwipeUpEnabled, forKey: Keys.threeFingerSwipeUpEnabled) }
    }
    /// 焦点居中模式：卡片对齐屏幕中心而非光标位置
    @Published var centerFocusEnabled: Bool {
        didSet { defaults.set(centerFocusEnabled, forKey: Keys.centerFocusEnabled) }
    }
    /// 焦点居中模式下，滚动停止后将最近卡片磁吸到屏幕中心的回弹效果
    @Published var centerSnapEnabled: Bool {
        didSet { defaults.set(centerSnapEnabled, forKey: Keys.centerSnapEnabled) }
    }
    /// 三指横滑「跟随手指」滑动过渡切换（快捷切换模式的行为配置）
    @Published var slidingTransitionEnabled: Bool {
        didSet { defaults.set(slidingTransitionEnabled, forKey: Keys.slidingTransitionEnabled) }
    }
    /// 滑动过渡跟手比例：offset = 手指归一化位移 × ratio × 屏宽（1.0 ≈ 手指满触控板 = 满屏）
    @Published var slidingRatio: Double {
        didSet { defaults.set(slidingRatio, forKey: Keys.slidingRatio) }
    }
    /// 滑动过渡提交阈值（屏宽比例）：|offset| ≥ threshold × 屏宽 才切换，否则回弹
    @Published var slidingCommitThreshold: Double {
        didSet { defaults.set(slidingCommitThreshold, forKey: Keys.slidingCommitThreshold) }
    }
    /// 菜单栏跟随手指渐变（横条背景截屏 + 源菜单随手指渐隐 / 目标菜单渐显）。
    /// 关闭后不创建覆盖条、不做自绘，采用原生顶栏切换动效（commit 时系统瞬间切换）。
    @Published var menuBarGradientEnabled: Bool {
        didSet { defaults.set(menuBarGradientEnabled, forKey: Keys.menuBarGradientEnabled) }
    }

    // MARK: - Elastic drag
    @Published var elasticDragEnabled: Bool {
        didSet { defaults.set(elasticDragEnabled, forKey: Keys.elasticDragEnabled) }
    }
    @Published var hintShakeEnabled: Bool {
        didSet { defaults.set(hintShakeEnabled, forKey: Keys.hintShakeEnabled) }
    }
    @Published var elasticDragMaxDisplacement: Int {
        didSet { defaults.set(elasticDragMaxDisplacement, forKey: Keys.elasticDragMaxDisplacement) }
    }

    // MARK: - Service
    @Published var serviceEnabled: Bool {
        didSet { defaults.set(serviceEnabled, forKey: Keys.serviceEnabled) }
    }

    // MARK: - Computed sensitivity multipliers
    var tapMaxDuration: TimeInterval {
        switch sensitivityLevel {
        case 0: return 0.28
        case 1: return 0.20
        case 2: return 0.15
        default: return 0.20
        }
    }

    var tapMaxDisplacement: Float {
        switch sensitivityLevel {
        case 0: return 0.06
        case 1: return 0.05
        case 2: return 0.04
        default: return 0.05
        }
    }

    var swipeMinDisplacement: Float {
        switch sensitivityLevel {
        case 0: return 0.12
        case 1: return 0.08
        case 2: return 0.05
        default: return 0.08
        }
    }

    private init() {
        defaults.register(defaults: [
            Keys.thumbnailHeight: Constants.defaultThumbnailHeight,
            Keys.thumbnailMaxWidth: Constants.defaultThumbnailMaxWidth,
            Keys.thumbnailCornerRadius: Constants.defaultThumbnailCornerRadius,
            Keys.thumbnailSpacing: Constants.defaultThumbnailSpacing,
            Keys.maxVisibleCount: Constants.defaultMaxVisibleCount,
            Keys.focusScale: Constants.defaultFocusScale,
            Keys.animationDuration: Constants.defaultAnimationDuration,
            Keys.immersiveModeEnabled: Constants.defaultImmersiveModeEnabled,
            Keys.quickSwitchModeEnabled: Constants.defaultQuickSwitchModeEnabled,
            Keys.quickSwitchHintEnabled: Constants.defaultQuickSwitchHintEnabled,
            Keys.cyclicScrollEnabled: true,
            Keys.sensitivityLevel: Constants.defaultSensitivityLevel,
            Keys.touchdownWindow: Constants.defaultTouchdownWindow,
            Keys.serviceEnabled: true,
            Keys.elasticDragEnabled: Constants.defaultElasticDragEnabled,
            Keys.hintShakeEnabled: Constants.defaultHintShakeEnabled,
            Keys.elasticDragMaxDisplacement: Constants.defaultElasticDragMaxDisplacement,
            Keys.threeFingerTapEnabled: true,
            Keys.threeFingerSwipeUpEnabled: false,
            Keys.centerFocusEnabled: false,
            Keys.centerSnapEnabled: true,
            Keys.slidingTransitionEnabled: false,
            Keys.slidingRatio: 1.0,
            Keys.slidingCommitThreshold: 0.45,
            Keys.menuBarGradientEnabled: true,
        ])

        _thumbnailHeight = .init(initialValue: defaults.double(forKey: Keys.thumbnailHeight))
        _thumbnailMaxWidth = .init(initialValue: defaults.double(forKey: Keys.thumbnailMaxWidth))
        _thumbnailCornerRadius = .init(initialValue: defaults.double(forKey: Keys.thumbnailCornerRadius))
        _thumbnailSpacing = .init(initialValue: defaults.double(forKey: Keys.thumbnailSpacing))
        _maxVisibleCount = .init(initialValue: defaults.integer(forKey: Keys.maxVisibleCount))
        _focusScale = .init(initialValue: defaults.double(forKey: Keys.focusScale))
        _animationDuration = .init(initialValue: defaults.double(forKey: Keys.animationDuration))
        _immersiveModeEnabled = .init(initialValue: defaults.bool(forKey: Keys.immersiveModeEnabled))
        _quickSwitchModeEnabled = .init(initialValue: defaults.bool(forKey: Keys.quickSwitchModeEnabled))
        _quickSwitchHintEnabled = .init(initialValue: defaults.bool(forKey: Keys.quickSwitchHintEnabled))
        _cyclicScrollEnabled = .init(initialValue: defaults.bool(forKey: Keys.cyclicScrollEnabled))
        _sensitivityLevel = .init(initialValue: defaults.integer(forKey: Keys.sensitivityLevel))
        _touchdownWindow = .init(initialValue: defaults.double(forKey: Keys.touchdownWindow))
        _serviceEnabled = .init(initialValue: defaults.bool(forKey: Keys.serviceEnabled))
        _elasticDragEnabled = .init(initialValue: defaults.bool(forKey: Keys.elasticDragEnabled))
        _hintShakeEnabled = .init(initialValue: defaults.bool(forKey: Keys.hintShakeEnabled))
        _elasticDragMaxDisplacement = .init(initialValue: defaults.integer(forKey: Keys.elasticDragMaxDisplacement))
        _threeFingerTapEnabled = .init(initialValue: defaults.bool(forKey: Keys.threeFingerTapEnabled))
        _threeFingerSwipeUpEnabled = .init(initialValue: defaults.bool(forKey: Keys.threeFingerSwipeUpEnabled))
        _centerFocusEnabled = .init(initialValue: defaults.bool(forKey: Keys.centerFocusEnabled))
        _centerSnapEnabled = .init(initialValue: defaults.bool(forKey: Keys.centerSnapEnabled))
        _slidingTransitionEnabled = .init(initialValue: defaults.bool(forKey: Keys.slidingTransitionEnabled))
        _slidingRatio = .init(initialValue: defaults.double(forKey: Keys.slidingRatio))
        _slidingCommitThreshold = .init(initialValue: defaults.double(forKey: Keys.slidingCommitThreshold))
        _menuBarGradientEnabled = .init(initialValue: defaults.bool(forKey: Keys.menuBarGradientEnabled))
    }

    func resetToDefaults() {
        thumbnailHeight = Constants.defaultThumbnailHeight
        thumbnailMaxWidth = Constants.defaultThumbnailMaxWidth
        thumbnailCornerRadius = Constants.defaultThumbnailCornerRadius
        thumbnailSpacing = Constants.defaultThumbnailSpacing
        maxVisibleCount = Constants.defaultMaxVisibleCount
        focusScale = Constants.defaultFocusScale
        animationDuration = Constants.defaultAnimationDuration
        immersiveModeEnabled = Constants.defaultImmersiveModeEnabled
        quickSwitchModeEnabled = Constants.defaultQuickSwitchModeEnabled
        quickSwitchHintEnabled = Constants.defaultQuickSwitchHintEnabled
        cyclicScrollEnabled = true
        sensitivityLevel = Constants.defaultSensitivityLevel
        touchdownWindow = Constants.defaultTouchdownWindow
        serviceEnabled = true
        elasticDragEnabled = Constants.defaultElasticDragEnabled
        hintShakeEnabled = Constants.defaultHintShakeEnabled
        elasticDragMaxDisplacement = Constants.defaultElasticDragMaxDisplacement
        threeFingerTapEnabled = true
        threeFingerSwipeUpEnabled = false
        centerFocusEnabled = false
        centerSnapEnabled = true
        slidingTransitionEnabled = false
        slidingRatio = 1.0
        slidingCommitThreshold = 0.45
        menuBarGradientEnabled = true
    }
}

// MARK: - Keys
private enum Keys {
    static let thumbnailHeight = "thumbnailHeight"
    static let thumbnailMaxWidth = "thumbnailMaxWidth"
    static let thumbnailCornerRadius = "thumbnailCornerRadius"
    static let thumbnailSpacing = "thumbnailSpacing"
    static let maxVisibleCount = "maxVisibleCount"
    static let focusScale = "focusScale"
    static let animationDuration = "animationDuration"
    static let immersiveModeEnabled = "immersiveModeEnabled"
    static let quickSwitchModeEnabled = "quickSwitchModeEnabled"
    static let quickSwitchHintEnabled = "quickSwitchHintEnabled"
    static let cyclicScrollEnabled = "cyclicScrollEnabled"
    static let sensitivityLevel = "sensitivityLevel"
    static let touchdownWindow = "touchdownWindow"
    static let threeFingerTapEnabled = "threeFingerTapEnabled"
    static let threeFingerSwipeUpEnabled = "threeFingerSwipeUpEnabled"
    static let centerFocusEnabled = "centerFocusEnabled"
    static let centerSnapEnabled = "centerSnapEnabled"
    static let slidingTransitionEnabled = "slidingTransitionEnabled"
    static let slidingRatio = "slidingRatio"
    static let slidingCommitThreshold = "slidingCommitThreshold"
    static let menuBarGradientEnabled = "menuBarGradientEnabled"
    static let serviceEnabled = "serviceEnabled"
    static let elasticDragEnabled = "elasticDragEnabled"
    static let hintShakeEnabled = "hintShakeEnabled"
    static let elasticDragMaxDisplacement = "elasticDragMaxDisplacement"
}
