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
    /// 滑动过渡期间源窗口是否显示人工投影（sourceView 的 NSShadow）。开启=现状动态
    /// 效果；关闭=去掉该投影——背景图已自带源窗口真实阴影，去掉可消除双重阴影光晕。
    @Published var sourceShadowEnabled: Bool {
        didSet { defaults.set(sourceShadowEnabled, forKey: Keys.sourceShadowEnabled) }
    }
    /// 源窗口阴影完全移除（与切换后一致）：开启后背景截屏排除源窗口（去掉真实投影）
    /// 且 sourceView 不添加人工阴影，滑动期间源窗口完全无阴影；关闭则沿用
    /// sourceShadowEnabled 行为。
    @Published var sourceShadowCleanEnabled: Bool {
        didSet { defaults.set(sourceShadowCleanEnabled, forKey: Keys.sourceShadowCleanEnabled) }
    }
    /// 甩动动量提交：释放时按最近几帧释放速度外推动量助推，用「有效位移＝当前位移＋
    /// 助推」判定提交，快甩（小位移、高速度）即可过阈值完成切换。慢速拖拽速度近零、
    /// 助推≈0，行为与关闭时一致。动量采样依赖跟踪期 progress 不钳制（GestureEngine 已取消）。
    @Published var momentumCommitEnabled: Bool {
        didSet { defaults.set(momentumCommitEnabled, forKey: Keys.momentumCommitEnabled) }
    }
    /// 动量助推外推时间窗口 τ（秒）：boost = clamp(v×τ, ±maxBoostPx)。
    @Published var momentumBoostWindow: Double {
        didSet { defaults.set(momentumBoostWindow, forKey: Keys.momentumBoostWindow) }
    }
    /// 动量助推上限（屏宽比例）：maxBoostPx = ratio × 屏宽。
    @Published var momentumMaxBoostRatio: Double {
        didSet { defaults.set(momentumMaxBoostRatio, forKey: Keys.momentumMaxBoostRatio) }
    }
    /// 背景 SCK 大图截取：开启=当前实现（全屏桌面快照平铺 + 菜单覆盖条材质来源）；
    /// 关闭=跳过全部背景截取（trackingBegan 预捕 / begin 消费 / 异步捕获 / 收尾落图），
    /// 透明占位直通实时桌面，源/目标区域由源快照（若开）或真实窗口兜底。
    @Published var backdropCaptureEnabled: Bool {
        didSet { defaults.set(backdropCaptureEnabled, forKey: Keys.backdropCaptureEnabled) }
    }
    /// 源窗口截取：开启=当前实现（源窗口快照盖住实时源窗口）；关闭=不截取源窗口，
    /// 源区域由背景图（若开，含冻结源）或实时桌面（背景亦关时）兜底。
    @Published var sourceCaptureEnabled: Bool {
        didSet { defaults.set(sourceCaptureEnabled, forKey: Keys.sourceCaptureEnabled) }
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
            Keys.sourceShadowEnabled: true,
            Keys.sourceShadowCleanEnabled: false,
            Keys.momentumCommitEnabled: true,
            Keys.momentumBoostWindow: 0.15,
            Keys.momentumMaxBoostRatio: 0.5,
            Keys.backdropCaptureEnabled: true,
            Keys.sourceCaptureEnabled: true,
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
        _sourceShadowEnabled = .init(initialValue: defaults.bool(forKey: Keys.sourceShadowEnabled))
        _sourceShadowCleanEnabled = .init(initialValue: defaults.bool(forKey: Keys.sourceShadowCleanEnabled))
        _momentumCommitEnabled = .init(initialValue: defaults.bool(forKey: Keys.momentumCommitEnabled))
        _momentumBoostWindow = .init(initialValue: defaults.double(forKey: Keys.momentumBoostWindow))
        _momentumMaxBoostRatio = .init(initialValue: defaults.double(forKey: Keys.momentumMaxBoostRatio))
        _backdropCaptureEnabled = .init(initialValue: defaults.bool(forKey: Keys.backdropCaptureEnabled))
        _sourceCaptureEnabled = .init(initialValue: defaults.bool(forKey: Keys.sourceCaptureEnabled))
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
        sourceShadowEnabled = true
        sourceShadowCleanEnabled = false
        momentumCommitEnabled = true
        momentumBoostWindow = 0.15
        momentumMaxBoostRatio = 0.5
        backdropCaptureEnabled = true
        sourceCaptureEnabled = true
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
    static let sourceShadowEnabled = "sourceShadowEnabled"
    static let sourceShadowCleanEnabled = "sourceShadowCleanEnabled"
    static let momentumCommitEnabled = "momentumCommitEnabled"
    static let momentumBoostWindow = "momentumBoostWindow"
    static let momentumMaxBoostRatio = "momentumMaxBoostRatio"
    static let backdropCaptureEnabled = "backdropCaptureEnabled"
    static let sourceCaptureEnabled = "sourceCaptureEnabled"
    static let serviceEnabled = "serviceEnabled"
    static let elasticDragEnabled = "elasticDragEnabled"
    static let hintShakeEnabled = "hintShakeEnabled"
    static let elasticDragMaxDisplacement = "elasticDragMaxDisplacement"
}
