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
            Keys.serviceEnabled: true,
            Keys.elasticDragEnabled: Constants.defaultElasticDragEnabled,
            Keys.hintShakeEnabled: Constants.defaultHintShakeEnabled,
            Keys.elasticDragMaxDisplacement: Constants.defaultElasticDragMaxDisplacement,
            Keys.threeFingerTapEnabled: true,
            Keys.threeFingerSwipeUpEnabled: false,
            Keys.centerFocusEnabled: false,
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
        _serviceEnabled = .init(initialValue: defaults.bool(forKey: Keys.serviceEnabled))
        _elasticDragEnabled = .init(initialValue: defaults.bool(forKey: Keys.elasticDragEnabled))
        _hintShakeEnabled = .init(initialValue: defaults.bool(forKey: Keys.hintShakeEnabled))
        _elasticDragMaxDisplacement = .init(initialValue: defaults.integer(forKey: Keys.elasticDragMaxDisplacement))
        _threeFingerTapEnabled = .init(initialValue: defaults.bool(forKey: Keys.threeFingerTapEnabled))
        _threeFingerSwipeUpEnabled = .init(initialValue: defaults.bool(forKey: Keys.threeFingerSwipeUpEnabled))
        _centerFocusEnabled = .init(initialValue: defaults.bool(forKey: Keys.centerFocusEnabled))
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
        serviceEnabled = true
        elasticDragEnabled = Constants.defaultElasticDragEnabled
        hintShakeEnabled = Constants.defaultHintShakeEnabled
        elasticDragMaxDisplacement = Constants.defaultElasticDragMaxDisplacement
        threeFingerTapEnabled = true
        threeFingerSwipeUpEnabled = false
        centerFocusEnabled = false
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
    static let threeFingerTapEnabled = "threeFingerTapEnabled"
    static let threeFingerSwipeUpEnabled = "threeFingerSwipeUpEnabled"
    static let centerFocusEnabled = "centerFocusEnabled"
    static let serviceEnabled = "serviceEnabled"
    static let elasticDragEnabled = "elasticDragEnabled"
    static let hintShakeEnabled = "hintShakeEnabled"
    static let elasticDragMaxDisplacement = "elasticDragMaxDisplacement"
}
