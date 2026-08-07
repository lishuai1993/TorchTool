import SwiftUI

struct SettingsPanelView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        TabView {
            displayTab
                .tabItem { Label("显示", systemImage: "rectangle.3.group") }
            gestureTab
                .tabItem { Label("手势", systemImage: "hand.draw") }
            generalTab
                .tabItem { Label("通用", systemImage: "gearshape") }
        }
        .padding(20)
        .frame(minWidth: 400, minHeight: 440)
    }

    // MARK: - Display tab

    private var displayTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    labeledSlider("缩略图高度", value: $settings.thumbnailHeight,
                                  range: 80...400, step: 10, format: "%.0f px")
                    labeledSlider("缩略图最大宽度", value: $settings.thumbnailMaxWidth,
                                  range: 120...600, step: 10, format: "%.0f px")
                    labeledSlider("缩略图间距", value: $settings.thumbnailSpacing,
                                  range: 4...40, step: 2, format: "%.0f px")
                    labeledSlider("圆角半径", value: $settings.thumbnailCornerRadius,
                                  range: 4...30, step: 2, format: "%.0f px")
                    labeledSlider("焦点放大比例", value: $settings.focusScale,
                                  range: 1.0...1.5, step: 0.05, format: "%.2f×")
                    labeledSlider("动画速度", value: Binding<CGFloat>(
                        get: { CGFloat(settings.animationDuration) },
                        set: { settings.animationDuration = TimeInterval($0) }
                    ), range: 0.05...0.6, step: 0.05, format: "%.0f ms",
                                  valueTransform: { $0 * 1000 })
                    labeledStepper("最大显示数量", value: $settings.maxVisibleCount,
                                   range: 3...15)
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Gesture tab

    private var gestureTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            modeToggle("沉浸式预览模式 (三指轻点)",
                        isOn: $settings.immersiveModeEnabled)
            Text("三指轻点触控板，展示缩略图横排视图进行选择")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 24)

            Divider()

            modeToggle("快捷切换模式 (三指轻扫)",
                        isOn: $settings.quickSwitchModeEnabled)
            Text("三指左右轻扫触控板，直接切换窗口")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 24)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("手势灵敏度")
                    .font(.headline)
                Picker("", selection: $settings.sensitivityLevel) {
                    Text("低").tag(0)
                    Text("中").tag(1)
                    Text("高").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                labeledSlider("三指触地检测窗口",
                              value: Binding<CGFloat>(
                                  get: { CGFloat(settings.touchdownWindow * 1000) },
                                  set: { settings.touchdownWindow = Double($0) / 1000.0 }
                              ),
                              range: CGFloat(Constants.touchdownWindowMin * 1000)...CGFloat(Constants.touchdownWindowMax * 1000),
                              step: CGFloat(Constants.touchdownWindowStep * 1000),
                              format: "%.0f ms")
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - General tab

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            modeToggle("启用服务", isOn: $settings.serviceEnabled)
            Text("关闭后所有手势功能停止，菜单栏图标保留")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 24)

            Divider()

            Button("恢复默认设置") {
                settings.resetToDefaults()
            }

            Spacer()

            VStack(alignment: .leading, spacing: 4) {
                Text("所需权限")
                    .font(.headline)
                Text("• 辅助功能 — 窗口激活与事件监听")
                Text("• 屏幕录制 — 采集窗口缩略图")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func modeToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.switch)
    }

    private func labeledSlider(
        _ label: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        step: CGFloat,
        format: String,
        valueTransform: ((CGFloat) -> CGFloat)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                let displayValue = valueTransform?(value.wrappedValue) ?? value.wrappedValue
                Text(String(format: format, displayValue))
                    .font(.callout.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(
                value: value,
                in: range,
                step: step
            )
        }
    }

    private func labeledStepper(
        _ label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        HStack {
            Text(label).font(.callout)
            Spacer()
            Stepper("\(value.wrappedValue)", value: value, in: range)
                .labelsHidden()
            Text("\(value.wrappedValue)")
                .font(.callout.monospacedDigit())
                .frame(width: 30)
        }
    }
}
