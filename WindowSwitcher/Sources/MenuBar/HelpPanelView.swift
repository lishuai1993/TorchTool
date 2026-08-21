import SwiftUI

struct HelpPanelView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                gestureSection
                serviceControlSection
                modeToggleSection
                elasticDragSection
                activationSection
                quickSwitchSection
                otherSection
            }
            .padding(24)
        }
        .frame(minWidth: 460, minHeight: 480)
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

    // MARK: - 一、手势说明

    private var gestureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("一、手势说明")

            numberedItem("1.1", title: "滑动方向定义", bullets: [
                "以风向类比：手指从触控板左向右滑动称「左滑」（起点在左），从右向左滑动称「右滑」（起点在右）。",
                "方向以手指运动的起点为准，与风向命名规则一致。",
            ])
            numberedItem("1.2", title: "窗口列表模型", bullets: [
                "所有窗口按活跃时间从左向右排列，最左侧（索引 0）为最近使用的窗口。",
                "越久远未使用的窗口越靠右，列表始终保持 LRU（最近最少使用）顺序。",
            ])
            numberedItem("1.3", title: "手势操作对象", bullets: [
                "三指滑动操作的是窗口列表本身，而非一个在列表上移动的焦点指针。",
                "窗口列表随手势同方向滑动：左滑则列表右移，左侧较新的窗口进入视野（切换到上一个窗口）。",
                "右滑则列表左移，右侧较旧的窗口进入视野（切换到下一个窗口）。",
                "与 iOS 主屏幕左右滑动的交互模型一致。",
            ])
        }
    }

    // MARK: - 二、服务控制

    private var serviceControlSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("二、服务控制")

            numberedItem("2.1", title: "启动服务", bullets: [
                "启用手势引擎（MultitouchSupport 触控板监听）与窗口交互监听（Accessibility 辅助功能）。",
                "启动后三指手势开始生效，菜单栏图标恢复彩色。",
                "仅在服务未运行时可用。",
            ])
            numberedItem("2.2", title: "停止服务", bullets: [
                "停止手势引擎与窗口交互监听，关闭所有可见覆盖层。",
                "应用进程保留在后台，菜单栏图标变为灰色。",
                "之后可通过「启动服务」恢复功能；仅在服务运行时可用。",
            ])
            numberedItem("2.3", title: "重启服务", bullets: [
                "先停止再启动服务。",
                "日志会被清空，相当于一次完整的重置。",
                "适用于手势响应异常或需要清理状态的场景。",
            ])
        }
    }

    // MARK: - 三、模式开关

    private var modeToggleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("三、模式开关")

            numberedItem("3.1", title: "沉浸预览模式", bullets: [
                "开启后通过三指轻点或三指上扫弹出窗口缩略图横排视图。",
                "视图中可通过鼠标悬停、滚轮滚动、键盘方向键浏览窗口。",
                "点击或按 Enter 键切换到目标窗口。",
            ])
            numberedItem("3.2", title: "快捷切换模式", bullets: [
                "开启后三指左右轻扫直接按 LRU（最近最少使用）顺序切换窗口，无需弹出预览界面。",
                "每次滑动切换一个窗口。",
            ])
            numberedItem("3.3", title: "循环滚动", bullets: [
                "开启：到达窗口列表一端继续滑动会回绕到另一端。",
                "关闭：到达一端继续滑动会触发弹性拖拽碰壁效果。",
            ])
        }
    }

    // MARK: - 四、弹性拖拽设置

    private var elasticDragSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("四、弹性拖拽设置")

            numberedItem("4.1", title: "弹性拖拽回弹", bullets: [
                "非循环模式下，到达窗口列表边界后继续滑动，窗口跟随手指产生位移（带阻尼效果）。",
                "手指离开触控板后窗口自动回弹到原始位置。",
                "关闭则碰壁后无任何响应。",
            ])
            numberedItem("4.2", title: "提示文字抖动", bullets: [
                "碰壁时在窗口上显示提示文字（如「已到列表末尾」）。",
                "通过抖动动画提示用户已到达边界。",
            ])
            numberedItem("4.3", title: "最大偏移像素", bullets: [
                "碰壁后窗口可拖离原始位置的最大像素距离（范围 10-200px）。",
                "值越大，碰壁时可拖拽的幅度越大。",
            ])
            numberedItem("4.4", title: "减小/增大偏移", bullets: [
                "以 10px 为步长调整「最大偏移像素」的数值。",
                "点击后立即生效。",
            ])
        }
    }

    // MARK: - 五、预览模式设置

    private var activationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("五、预览模式设置")

            numberedItem("5.1", title: "三指轻点激活", bullets: [
                "开启后，三根手指同时轻点触控板即可打开沉浸预览模式的窗口缩略图视图。",
                "该手势独立于快捷切换模式。",
            ])
            numberedItem("5.2", title: "三指上扫激活", bullets: [
                "开启后，三根手指在触控板上向上滑动即可打开沉浸预览模式。",
                "与三指轻点互为补充，可根据使用习惯选择性开启。",
            ])
            numberedItem("5.3", title: "焦点居中", bullets: [
                "控制沉浸预览模式中滚动吸附的基准点。",
                "开启：窗口缩略图的中心对齐屏幕水平中线。",
                "关闭：对齐鼠标光标所在 X 坐标（跟随光标）。",
            ])
            numberedItem("5.4", title: "焦点居中回弹", bullets: [
                "仅「焦点居中」开启时生效。",
                "开启：停止滚动时，离屏幕水平中线最近的窗口缩略图自动吸附到中线位置（带回弹动画）。",
                "关闭：停止滚动即停在原位，不做磁吸。",
            ])
        }
    }

    // MARK: - 六、快切模式设置

    private var quickSwitchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("六、快切模式设置")

            numberedItem("6.1", title: "滑动过渡切换（跟随手指）", bullets: [
                "快捷切换模式的行为选项，仅在「快捷切换模式」开启且三指横滑时生效。",
                "开启：三指横滑由瞬间直切改为窗口图像跟随手指滑动，目标窗口从屏幕边缘滑入真实位置，滑动距离与手指位移联动。",
                "释放时按最终位移判定提交切换或回弹；关闭则保持瞬间直切。",
            ])
            numberedItem("6.2", title: "菜单栏跟随手指渐变（淡出淡入）", bullets: [
                "滑动过渡期间屏幕顶部菜单栏的过渡效果。",
                "开启：源应用菜单文字随手指逐渐淡出、目标应用菜单文字逐渐淡入，实现平滑衔接。",
                "关闭：不进行自绘渐变，改用系统原生菜单栏切换动效（提交切换、激活目标应用时菜单栏瞬间切换）。",
            ])
            numberedItem("6.3", title: "源窗口阴影（动态效果）", bullets: [
                "滑动过渡期间源窗口图像是否添加人工投影（阴影）。",
                "开启＝保留当前动态阴影效果；关闭＝去掉该人工投影，源窗口阴影减轻。",
                "注意：背景截图为真实桌面，自带源窗口的真实窗口投影，仅关闭此项时源窗口可能仍保留轻微的真实阴影。",
                "如需彻底无阴影，请配合开启「源窗口阴影完全移除」。",
            ])
            numberedItem("6.4", title: "源窗口阴影完全移除（与切换后一致）", bullets: [
                "开启：滑动过渡期间源窗口完全无阴影，观感与切换完成后一致。",
                "实现方式：背景截图排除源窗口（去掉其真实投影），且源窗口图像不添加人工投影。",
                "开启时「源窗口阴影（动态效果）」开关被覆盖并置灰、不可点击；关闭后恢复该开关控制。",
            ])
            numberedItem("6.5", title: "跟手比例", bullets: [
                "滑动过渡中窗口图像跟随手指的位移比例，范围 0.25～3.0，默认 1.0。",
                "值越大，手指移动同样距离时窗口图像移动得越远（跟手越灵敏）；值越小越迟钝。",
                "约 1.0 表示手指在触控板上滑过接近全程时，窗口图像移动满屏。",
                "通过「减小/增大跟手比例」以 0.05 为步长调整，点击立即生效。",
            ])
            numberedItem("6.6", title: "提交阈值", bullets: [
                "滑动过渡提交切换所需的位移门槛（屏宽比例），范围 0.20～0.80，默认 0.45。",
                "释放手指时，若窗口图像位移达到该阈值（如 0.45＝屏幕宽度 45%）则提交切换；未达到则回弹、不切换。",
                "值越大越难触发切换（需拖得更远），越小越容易。",
                "通过「减小/增大提交阈值」以 0.05 为步长调整，点击立即生效。",
            ])
            numberedItem("6.7", title: "甩动动量提交（快甩助力）", bullets: [
                "对应菜单开关：开启后（默认开启），释放手指时按最近几帧的释放速度外推一段位移作为动量助推，用「有效位移（位移＋助推）」判定提交。",
                "效果：快甩（小位移、高速度）也能完成切换；慢速拖拽速度近零、助推≈0，行为与开启前一致。",
                "助推上限＝屏宽的 50%（防止极端快甩越过多个窗口），外推时间窗口默认 0.15 秒。",
                "对应菜单按钮「减小甩动动量 (−0.05)」：以 0.05 秒步长减小外推时间窗口（下限 0.05 秒），点击立即生效。",
                "对应菜单按钮「增大甩动动量 (+0.05)」：以 0.05 秒步长增大外推时间窗口（上限 0.30 秒），点击立即生效，标签实时刷新并持久化。",
                "关闭后回到只看位移的判定（|位移| ≥ 提交阈值×屏宽）。",
            ])
        }
    }

    // MARK: - 七、其他

    private var otherSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("七、其他")

            numberedItem("7.1", title: "显示设置…", bullets: [
                "打开设置面板。",
                "可调整缩略图高度/宽度/间距、圆角半径、焦点放大比例、动画速度、最大显示数量、手势灵敏度等参数。",
            ])
            numberedItem("7.2", title: "退出", bullets: [
                "停止所有服务（手势引擎＋交互监听），隐藏覆盖层，终止应用进程。",
                "菜单栏图标从系统状态栏移除。",
                "若要重新使用，需手动启动应用。",
            ])
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .bold))
            .foregroundColor(.primary)
    }

    /// 编号条目（如「1.1 滑动方向定义」）+ 无序列表作用说明。
    private func numberedItem(_ number: String, title: String, bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(number) \(title)")
                .font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 5) {
                        Text("•")
                            .font(.system(size: 14))
                        Text(line)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 12)
        }
        .padding(.leading, 8)
    }
}
