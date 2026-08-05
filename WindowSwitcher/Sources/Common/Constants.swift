import Foundation

enum Constants {
    static let appName = "WindowSwitcher"

    // MARK: - Thumbnail defaults
    static let defaultThumbnailHeight: CGFloat = 180
    static let defaultThumbnailMaxWidth: CGFloat = 320
    static let defaultThumbnailCornerRadius: CGFloat = 14
    static let defaultThumbnailSpacing: CGFloat = 12
    static let defaultMaxVisibleCount: Int = 7
    static let defaultFocusScale: CGFloat = 1.2
    static let defaultAnimationDuration: TimeInterval = 0.2
    static let defaultNonFocusOpacity: Double = 0.85

    // MARK: - Overlay defaults
    static let overlayBackgroundColor = "rgba(0,0,0,0.4)"
    static let overlayBlurRadius: CGFloat = 20
    static let overlayContainerCornerRadius: CGFloat = 24
    static let overlayDismissTimeout: TimeInterval = 3.0

    // MARK: - Gesture defaults
    static let defaultTapMaxDuration: TimeInterval = 0.2       // seconds
    static let defaultTapMaxDisplacement: Float = 0.03          // normalized
    static let defaultSwipeMinDisplacement: Float = 0.08        // normalized
    static let defaultSwipeMinDuration: TimeInterval = 0.05
    static let defaultSensitivityLevel: Int = 1                 // 0=low, 1=medium, 2=high

    // MARK: - Mode defaults
    static let defaultImmersiveModeEnabled: Bool = true
    static let defaultQuickSwitchModeEnabled: Bool = true
    static let defaultQuickSwitchHintEnabled: Bool = false
    static let defaultQuickSwitchHintDuration: TimeInterval = 1.5

    // MARK: - Elastic drag defaults
    static let defaultElasticDragEnabled: Bool = true
    static let defaultHintShakeEnabled: Bool = true
    static let defaultElasticDragMaxDisplacement: Int = 50

    // MARK: - Window filter
    static let excludedAppBundleIDs: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.WindowManager",
    ]

    // MARK: - MultitouchSupport paths
    static let multitouchFrameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
}

