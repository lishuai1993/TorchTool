import SwiftUI

struct HelpPanelView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                serviceControlSection
                modeToggleSection
                elasticDragSection
                activationSection
                otherSection
            }
            .padding(24)
        }
        .frame(minWidth: 460, maxWidth: 560, minHeight: 520)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WindowSwitcher 帮助文档")
                .font(.title2.bold())
            Text("三指手势窗口切换工具，通过触控板手势快速切换和预览应用窗口。")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Divider()
        }
    }

    // MARK: - Service Control

    private var serviceControlSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("一、服务控制")

            helpItem(
                title: "启动服务",
                detail: "启用手势引擎（MultitouchSupport 触控板监听）和窗口交互监听（Accessibility 辅助功能）。启动后三指手势开始生效，菜单栏图标恢复彩色。仅在服务未运行时可用。"
            )
            helpItem(
                title: "停止服务",
                detail: "停止手势引擎和窗口交互监听，关闭所有可见覆盖层。应用进程保留在后台，菜单栏图标变为灰色。之后可通过「启动服务」恢复功能。仅在服务运行时可用。"
            )
            helpItem(
                title: "重启服务",
                detail: "先停止再启动服务。日志会被清空，相当于一次完整的重置。适用于手势响应异常或需要清理状态的场景。"
            )
        }
    }

    // MARK: - Mode Toggles

    private var modeToggleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("二、模式开关")

            helpItem(
                title: "沉浸预览模式",
                detail: "开启后，通过三指轻点或三指上扫触控板弹出窗口缩略图横排视图。在视图中可通过鼠标悬停、滚轮滚动、键盘方向键浏览窗口，点击或按 Enter 键切换到目标窗口。"
            )
            helpItem(
                title: "快捷切换模式",
                detail: "开启后，三指左右轻扫触控板直接按 LRU（最近最少使用）顺序切换窗口，无需弹出预览界面。每次滑动切换一个窗口。"
            )
            helpItem(
                title: "循环滚动",
                detail: "控制窗口列表到达两端时的行为：开启后到达列表一端继续滑动会回绕到另一端；关闭后到达一端继续滑动会触发弹性拖拽碰壁效果。"
            )
        }
    }

    // MARK: - Elastic Drag Settings

    private var elasticDragSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("三、弹性拖拽设置")

            helpItem(
                title: "弹性拖拽回弹",
                detail: "非循环模式下，到达窗口列表边界后继续滑动，窗口会跟随手指产生位移（带阻尼效果），手指离开触控板后窗口自动回弹到原始位置。关闭则碰壁后无任何响应。"
            )
            helpItem(
                title: "提示文字抖动",
                detail: "碰壁时在窗口上显示提示文字（如「已到列表末尾」），并通过抖动动画提示用户已到达边界。"
            )
            helpItem(
                title: "最大偏移像素",
                detail: "碰壁后窗口可拖离原始位置的最大像素距离（范围 10-200px）。值越大，碰壁时可拖拽的幅度越大。"
            )
            helpItem(
                title: "减小/增大偏移",
                detail: "以 10px 为步长调整「最大偏移像素」的数值。点击后立即生效。"
            )
        }
    }

    // MARK: - Activation Settings

    private var activationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("四、预览模式设置")

            helpItem(
                title: "三指轻点激活",
                detail: "开启后，三根手指同时轻点触控板即可打开沉浸预览模式的窗口缩略图视图。该手势独立于快捷切换模式。"
            )
            helpItem(
                title: "三指上扫激活",
                detail: "开启后，三根手指在触控板上向上滑动即可打开沉浸预览模式。与三指轻点互为补充，可根据使用习惯选择性开启。"
            )
            helpItem(
                title: "焦点居中",
                detail: "控制沉浸预览模式中滚动吸附的基准点：开启后窗口缩略图的中心会对齐屏幕水平中线；关闭后对齐鼠标光标所在 X 坐标（跟随光标）。"
            )
        }
    }

    // MARK: - Other

    private var otherSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("五、其他")

            helpItem(
                title: "显示设置…",
                detail: "打开设置面板，可调整缩略图高度/宽度/间距、圆角半径、焦点放大比例、动画速度、最大显示数量、手势灵敏度等参数。"
            )
            helpItem(
                title: "退出",
                detail: "停止所有服务（手势引擎 + 交互监听），隐藏覆盖层，终止应用进程。菜单栏图标从系统状态栏移除。若要重新使用，需手动启动应用。"
            )
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundColor(.primary)
    }

    private func helpItem(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 8)
    }
}
