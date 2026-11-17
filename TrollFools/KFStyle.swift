//
//  KFStyle.swift
//  石榴动态注入
//
//  画面：王者内核 P2「胶囊分页」—— 纯黑底 / 细线卡 / 荧光绿 / 白色药丸分页
//        色值一比一取自 smobaKFD/绘图/BBZView.mm 的 SLK_ 系列宏
//  动效：HGhubX src/styles/ios.css 的弹性体系
//        按下 scale .965（55ms 入 / spring 出）
//        逐条 rise 入场（y +14 / scale .98，过冲回弹）
//        分页药丸滑移（matchedGeometry + spring .34）
//        弹窗过冲（scale .97 → 1.005 → 1）
//        标题入场（x -10 → +2 → 0，soft spring）
//
//  最低支持 iOS 14：不使用 PhaseAnimator / contentTransition / .overlay{} 等新 API
//

import SwiftUI
import UIKit

// MARK: - 调色板（对应 SLK_ 宏）

enum KFColor {

    /// SLK_底色 #07080B
    static let bg = Color(red: 7 / 255, green: 8 / 255, blue: 11 / 255)
    /// SLK_卡面 #0E1014
    static let card = Color(red: 14 / 255, green: 16 / 255, blue: 20 / 255)
    /// SLK_卡面2 #16191F
    static let card2 = Color(red: 22 / 255, green: 25 / 255, blue: 31 / 255)
    /// SLK_开卡 #0F2B22（主开关打开后的卡面）
    static let onCard = Color(red: 15 / 255, green: 43 / 255, blue: 34 / 255)
    /// SLK_线 —— 白色 6.5%
    static let line = Color.white.opacity(0.065)
    /// SLK_主字 #F2F4F8
    static let text = Color(red: 242 / 255, green: 244 / 255, blue: 248 / 255)
    /// SLK_次字 #8E96AA
    static let sub = Color(red: 142 / 255, green: 150 / 255, blue: 170 / 255)
    /// SLK_弱字 #61697C
    static let weak = Color(red: 97 / 255, green: 105 / 255, blue: 124 / 255)
    /// SLK_极弱 #3E4552
    static let faint = Color(red: 62 / 255, green: 69 / 255, blue: 82 / 255)
    /// SLK_绿 #35E0A1
    static let green = Color(red: 53 / 255, green: 224 / 255, blue: 161 / 255)
    /// SLK_红 #FF6E78
    static let red = Color(red: 255 / 255, green: 110 / 255, blue: 120 / 255)
    /// 分页选中后的字色（深墨，压在白色药丸上）
    static let ink = Color(red: 10 / 255, green: 12 / 255, blue: 16 / 255)
    /// 主按钮前景（绿底上的深字）
    static let onGreen = Color(red: 6 / 255, green: 22 / 255, blue: 17 / 255)

    static let uiGreen = UIColor(red: 53 / 255, green: 224 / 255, blue: 161 / 255, alpha: 1)
    static let uiBg = UIColor(red: 7 / 255, green: 8 / 255, blue: 11 / 255, alpha: 1)
}

// MARK: - 动效（HGhubX ios.css → SwiftUI spring）

enum KFMotion {

    /// --motion-spring: cubic-bezier(.34,1.56,.64,1)
    /// 明显回弹，用于按钮抬起、勾选、卡片状态切换
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.62)

    /// --motion-spring-soft: cubic-bezier(.22,1.28,.36,1)
    /// 轻微回弹，用于折叠、筛选、颜色过渡
    static let soft = Animation.spring(response: 0.5, dampingFraction: 0.80)

    /// 按下：transition-duration 55ms（HGhubX 的按下瞬间是接近线性的）
    static let press = Animation.easeOut(duration: 0.055)

    /// 分页药丸 / 分段指示器滑移：transform .34s var(--motion-spring)
    static let slide = Animation.spring(response: 0.34, dampingFraction: 0.68)

    /// 页面切换：motion-page-in .4s
    static let page = Animation.spring(response: 0.40, dampingFraction: 0.74)

    /// 逐条入场：motion-rise .42s
    static let rise = Animation.spring(response: 0.44, dampingFraction: 0.70)

    /// 弹窗：motion-dialog-in .36s，72% 处过冲到 1.005
    static let dialog = Animation.spring(response: 0.36, dampingFraction: 0.66)

    /// 标题：motion-title-in .62s soft
    static let title = Animation.spring(response: 0.62, dampingFraction: 0.84)

    /// 日志追加：新行从下方淡入
    static let logIn = Animation.spring(response: 0.38, dampingFraction: 0.74)
}

// MARK: - 入场动效

/// 逐条上浮入场 —— 对应 .a-rise / motion-rise
/// y +14 → 0，scale .98 → 1，弹簧自然过冲到 -2px
private struct KFRiseModifier: ViewModifier {

    let index: Int
    let enabled: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .scaleEffect(shown ? 1 : 0.98, anchor: .top)
            .onAppear {
                guard enabled else {
                    shown = true
                    return
                }
                // 每条延迟 35ms，和 HGhubX 的连续入场节奏一致
                let delay = min(Double(index), 12) * 0.035
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    withAnimation(KFMotion.rise) { shown = true }
                }
            }
    }
}

/// 标题入场 —— motion-title-in：x -10 → +2 → 0
private struct KFTitleInModifier: ViewModifier {

    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(x: shown ? 0 : -10, y: shown ? 0 : 6)
            .onAppear {
                withAnimation(KFMotion.title) { shown = true }
            }
    }
}

extension View {

    /// 逐条上浮入场
    func kfRise(_ index: Int, enabled: Bool = true) -> some View {
        modifier(KFRiseModifier(index: index, enabled: enabled))
    }

    /// 标题横向推入
    func kfTitleIn() -> some View {
        modifier(KFTitleInModifier())
    }

    /// 卡面 / 描边（细线卡，替代原来的玻璃）
    func kfCard(radius: CGFloat = 18,
                fill: Color = KFColor.card,
                bordered: Bool = true) -> some View {
        // 先裁剪再描边：行内的选中底色会被圆角一起裁掉，不会从角上溢出
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(shape.fill(fill))
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(bordered ? KFColor.line : Color.clear, lineWidth: 1)
            )
    }
}

// MARK: - 背景（纯黑 + 两处极淡光晕，对应 .glow）

struct KFBackground: View {

    var body: some View {
        ZStack {
            KFColor.bg

            // 左上：绿色微光
            RadialGradient(
                gradient: Gradient(colors: [KFColor.green.opacity(0.13), KFColor.green.opacity(0)]),
                center: UnitPoint(x: 0.18, y: -0.02),
                startRadius: 0,
                endRadius: 330
            )

            // 右上：蓝色微光
            RadialGradient(
                gradient: Gradient(colors: [
                    Color(red: 70 / 255, green: 120 / 255, blue: 1).opacity(0.11),
                    Color(red: 70 / 255, green: 120 / 255, blue: 1).opacity(0)
                ]),
                center: UnitPoint(x: 0.88, y: 0.03),
                startRadius: 0,
                endRadius: 260
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - 细线 / 分组标题

struct KFDivider: View {

    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(KFColor.line)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

/// 段落标题（大写字母 + 字距），右侧可挂操作胶囊
struct KFSectionHeader<Trailing: View>: View {

    let text: String
    let trailing: Trailing

    init(_ text: String, @ViewBuilder trailing: () -> Trailing) {
        self.text = text
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(text.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.9)
                .foregroundColor(KFColor.weak)

            Spacer(minLength: 4)

            trailing
        }
        .padding(.horizontal, 2)
    }
}

extension KFSectionHeader where Trailing == EmptyView {

    init(_ text: String) {
        self.init(text) { EmptyView() }
    }
}

// MARK: - 顶部栏（logo + 标题 + 圆形操作钮）

struct KFNavBar<Trailing: View>: View {

    let title: String
    let subtitle: String
    let trailing: Trailing

    init(_ title: String,
         subtitle: String,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {

            // 32×32 方块里一颗发光绿菱
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(KFColor.card)
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(KFColor.line, lineWidth: 1)

                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(KFColor.green)
                    .frame(width: 9, height: 9)
                    .rotationEffect(.degrees(45))
                    .shadow(color: KFColor.green.opacity(0.85), radius: 5)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(KFColor.text)
                    .lineLimit(1)

                Text(subtitle.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(1.1)
                    .foregroundColor(KFColor.faint)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            trailing
        }
        .frame(height: 62)
    }
}

extension KFNavBar where Trailing == EmptyView {

    init(_ title: String, subtitle: String) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - 白色药丸分页（P2 招牌件）

struct KFSegmented: View {

    @Binding var selection: Int
    let titles: [String]

    @Namespace private var ns

    var body: some View {
        HStack(spacing: 3) {
            ForEach(titles.indices, id: \.self) { i in
                Button {
                    guard selection != i else { return }
                    withAnimation(KFMotion.slide) { selection = i }
                } label: {
                    Text(titles[i])
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(selection == i ? KFColor.ink : KFColor.weak)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .contentShape(Rectangle())
                        .background(
                            ZStack {
                                if selection == i {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .fill(KFColor.text)
                                        .matchedGeometryEffect(id: "kf.segment", in: ns)
                                        .shadow(color: Color.black.opacity(0.35), radius: 6, y: 2)
                                }
                            }
                        )
                    // 位移动画由 withAnimation(KFMotion.slide) 驱动，
                    // 这里不再叠 .animation，否则药丸会走两套曲线
                }
                .buttonStyle(KFButtonStyle(scale: 0.97))
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(KFColor.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(KFColor.line, lineWidth: 1)
        )
    }
}

// MARK: - 按钮

/// 按下缩到 0.965（55ms 压下去 / 弹簧弹回来）—— HGhubX 的 .ios-button:active
struct KFButtonStyle: ButtonStyle {

    var scale: CGFloat = 0.965

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(
                configuration.isPressed ? KFMotion.press : KFMotion.spring,
                value: configuration.isPressed
            )
    }
}

/// 圆形图标按钮（顶栏右侧刷新等）
struct KFIconButton: View {

    let systemName: String
    var active: Bool = false
    var size: CGFloat = 32
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(active ? KFColor.green : KFColor.sub)
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(KFColor.card)
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            active ? KFColor.green.opacity(0.4) : KFColor.line,
                            lineWidth: 1
                        )
                )
                .contentShape(Circle())
        }
        .buttonStyle(KFButtonStyle(scale: 0.9))
    }
}

/// 主按钮 —— 荧光绿底 + 深墨字（对应「初始化内核」）
struct KFPrimaryButton: View {

    let title: String
    var icon: String? = nil
    var enabled: Bool = true
    var loading: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            guard enabled && !loading else { return }
            action()
        } label: {
            HStack(spacing: 7) {
                if loading {
                    KFSpinner(color: KFColor.onGreen)
                } else if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .bold))
                }

                Text(title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundColor(KFColor.onGreen)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(enabled ? KFColor.green : KFColor.card2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(
                        enabled ? KFColor.green.opacity(0.5) : KFColor.line,
                        lineWidth: 1
                    )
            )
            .shadow(color: enabled ? KFColor.green.opacity(0.22) : Color.clear,
                    radius: 14, y: 5)
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .animation(KFMotion.soft, value: enabled)
        }
        .buttonStyle(KFButtonStyle())
        .disabled(!enabled || loading)
    }
}

/// 次按钮 —— 卡面底 + 白字（对应「清除内核残留」）
struct KFSecondaryButton: View {

    let title: String
    var icon: String? = nil
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button {
            guard enabled else { return }
            action()
        } label: {
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(enabled ? KFColor.text : KFColor.weak)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(KFColor.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(KFColor.line, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(KFButtonStyle())
        .disabled(!enabled)
    }
}

/// 小胶囊（「清空」「复制」这类段落级操作）
struct KFPill: View {

    let title: String
    var icon: String? = nil
    var tint: Color = KFColor.sub
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 9.5, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundColor(tint)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(KFColor.card2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(KFColor.line, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(KFButtonStyle(scale: 0.94))
    }
}

// MARK: - 转圈

struct KFSpinner: View {

    var color: Color = KFColor.green
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 16, height: 16)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(
                Animation.linear(duration: 0.75).repeatForever(autoreverses: false),
                value: spinning
            )
            .onAppear { spinning = true }
    }
}

// MARK: - 切换开关（绿 tint）

struct KFSwitch: View {

    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: KFColor.green))
            .scaleEffect(0.9)
            .animation(KFMotion.soft, value: isOn)
    }
}

// MARK: - 勾选圆点（选中弹一下）

struct KFCheckCircle: View {

    let isOn: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isOn ? KFColor.green : KFColor.faint, lineWidth: 1.5)
                .frame(width: 20, height: 20)

            if isOn {
                Circle()
                    .fill(KFColor.green)
                    .frame(width: 20, height: 20)

                Image(systemName: "checkmark")
                    .font(.system(size: 9.5, weight: .heavy))
                    .foregroundColor(KFColor.ink)
            }
        }
        .scaleEffect(isOn ? 1 : 0.94)
        .animation(KFMotion.spring, value: isOn)
    }
}

// MARK: - 搜索框

struct KFSearchField: View {

    @Binding var text: String
    var placeholder: String = "搜索"

    @State private var focused = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(focused ? KFColor.green : KFColor.weak)

            TextField(placeholder, text: $text, onEditingChanged: { editing in
                // 直接监听编辑状态，别用 onTapGesture 抢 TextField 的点击
                focused = editing
            })
                .font(.system(size: 14))
                .foregroundColor(KFColor.text)
                .accentColor(KFColor.green)
                .autocapitalization(.none)
                .disableAutocorrection(true)

            if !text.isEmpty {
                Button {
                    withAnimation(KFMotion.soft) { text = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(KFColor.faint)
                }
                .buttonStyle(KFButtonStyle(scale: 0.86))
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(KFColor.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    focused ? KFColor.green.opacity(0.42) : KFColor.line,
                    lineWidth: 1
                )
        )
        .animation(KFMotion.soft, value: focused)
        .animation(KFMotion.soft, value: text.isEmpty)
    }
}

// MARK: - 筛选胶囊

struct KFFilterPill: View {

    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isOn ? KFColor.ink : KFColor.weak)
                .padding(.horizontal, 13)
                .frame(height: 30)
                .background(
                    Capsule()
                        .fill(isOn ? KFColor.text : KFColor.card)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isOn ? Color.clear : KFColor.line, lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(KFButtonStyle(scale: 0.94))
        .animation(KFMotion.spring, value: isOn)
    }
}

// MARK: - 空态

struct KFEmptyState: View {

    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundColor(KFColor.faint)

            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(KFColor.sub)

            Text(message)
                .font(.system(size: 11.5))
                .foregroundColor(KFColor.weak)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 20)
        .kfCard(radius: 18, fill: KFColor.card)
    }
}

// MARK: - 行卡（图标 + 标题 + 副标 + 右值）

struct KFRowCard: View {

    let icon: String
    let title: String
    var subtitle: String? = nil
    var trailing: String? = nil
    var iconTint: Color = KFColor.green

    var body: some View {
        HStack(spacing: 11) {

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(KFColor.card2)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(iconTint)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(KFColor.text)
                    .lineLimit(1)

                if let subtitle = subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundColor(KFColor.weak)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            if let trailing = trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(KFColor.faint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .kfCard(radius: 15)
    }
}

// MARK: - 终端（SYSTEM OUTPUT）

struct KFTerminal: View {

    let lines: [String]
    var maxLines: Int = 8
    var emptyText: String = "等待输出…"

    private var shown: [String] {
        Array(lines.suffix(maxLines))
    }

    /// 按关键字给整行上色：成功绿 / 失败红 / 关键步骤亮白
    private func color(for line: String) -> Color {
        let s = line.lowercased()
        if s.contains("失败") || s.contains("错误") || s.contains("error")
            || s.contains("failed") || s.contains("❌") || s.contains("✗") {
            return KFColor.red
        }
        if s.contains("完成") || s.contains("成功") || s.contains("就绪")
            || s.contains("✅") || s.contains("✓") || s.contains("已启动") {
            return KFColor.green
        }
        if s.hasPrefix("⚡") || s.hasPrefix("⚙") || s.hasPrefix("📁")
            || s.hasPrefix("📩") || s.hasPrefix("🗑") || s.hasPrefix("🧩") {
            return KFColor.text.opacity(0.92)
        }
        return KFColor.sub
    }

    /// 时间戳前缀压暗，正文按关键字上色（对应截图里的彩色终端）
    private func lineText(_ raw: String) -> Text {
        let size: CGFloat = 10.5
        if raw.hasPrefix("["), let close = raw.firstIndex(of: "]") {
            let head = String(raw[raw.startIndex...close]) + " "
            let rest = String(raw[raw.index(after: close)...])
            let headText = Text(head)
                .font(.system(size: size, design: .monospaced))
                .foregroundColor(KFColor.weak)
            let bodyText = Text(rest)
                .font(.system(size: size, design: .monospaced))
                .foregroundColor(color(for: rest))
            return headText + bodyText
        }
        return Text(raw)
            .font(.system(size: size, design: .monospaced))
            .foregroundColor(color(for: raw))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {

            if shown.isEmpty {
                Text(emptyText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(KFColor.faint)
            } else {
                ForEach(Array(shown.enumerated()), id: \.offset) { pair in
                    lineText(pair.element)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 5 / 255, green: 8 / 255, blue: 12 / 255))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(KFColor.line, lineWidth: 1)
        )
        .animation(KFMotion.logIn, value: lines.count)
    }
}

// MARK: - 状态卡（大字号 + 细线 + 状态行，对应 P2 主开关卡）

struct KFStatusCard<Accessory: View>: View {

    let caption: String
    let bigText: String
    let statusText: String
    let detailText: String
    var isActive: Bool = false
    let accessory: Accessory

    init(caption: String,
         bigText: String,
         statusText: String,
         detailText: String,
         isActive: Bool = false,
         @ViewBuilder accessory: () -> Accessory) {
        self.caption = caption
        self.bigText = bigText
        self.statusText = statusText
        self.detailText = detailText
        self.isActive = isActive
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack(alignment: .top, spacing: 8) {
                Text(caption)
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .foregroundColor(KFColor.faint)

                Spacer(minLength: 4)

                accessory
            }

            Text(bigText)
                .font(.system(size: 33, weight: .light))
                .foregroundColor(isActive ? KFColor.text : KFColor.sub)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 8)
                .scaleEffect(isActive ? 1.012 : 1, anchor: .leading)

            Rectangle()
                .fill(KFColor.line)
                .frame(height: 1)
                .padding(.top, 14)

            HStack(spacing: 6) {
                Circle()
                    .fill(isActive ? KFColor.green : KFColor.faint)
                    .frame(width: 5, height: 5)
                    .shadow(color: isActive ? KFColor.green.opacity(0.9) : Color.clear,
                            radius: 3)

                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isActive ? KFColor.green : KFColor.sub)
                    .lineLimit(1)

                Text("·")
                    .font(.system(size: 11))
                    .foregroundColor(KFColor.faint)

                Text(detailText)
                    .font(.system(size: 11))
                    .foregroundColor(KFColor.weak)
                    .lineLimit(1)
            }
            .padding(.top, 11)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isActive ? KFColor.onCard : KFColor.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    isActive ? KFColor.green.opacity(0.24) : KFColor.line,
                    lineWidth: 1
                )
        )
        .animation(KFMotion.soft, value: isActive)
    }
}

extension KFStatusCard where Accessory == EmptyView {

    init(caption: String,
         bigText: String,
         statusText: String,
         detailText: String,
         isActive: Bool = false) {
        self.init(caption: caption,
                  bigText: bigText,
                  statusText: statusText,
                  detailText: detailText,
                  isActive: isActive) { EmptyView() }
    }
}

// MARK: - 提示弹层（过冲进场，对应 motion-dialog-in）

struct KFDialog: View {

    let title: String
    let message: String
    let success: Bool
    let onClose: () -> Void

    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(shown ? 0.55 : 0)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 13) {
                ZStack {
                    Circle()
                        .fill((success ? KFColor.green : KFColor.red).opacity(0.14))
                    Image(systemName: success ? "checkmark" : "exclamationmark")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(success ? KFColor.green : KFColor.red)
                }
                .frame(width: 44, height: 44)

                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(KFColor.text)

                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundColor(KFColor.sub)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                KFPrimaryButton(title: "好") { close() }
                    .padding(.top, 3)
            }
            .padding(20)
            .frame(maxWidth: 300)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(KFColor.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(KFColor.line, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.6), radius: 30, y: 12)
            // 0% scale .97 → 72% 过冲 1.005 → 1
            .scaleEffect(shown ? 1 : 0.97)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .animation(KFMotion.dialog, value: shown)
        }
        .onAppear { shown = true }
    }

    private func close() {
        withAnimation(KFMotion.dialog) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { onClose() }
    }
}
