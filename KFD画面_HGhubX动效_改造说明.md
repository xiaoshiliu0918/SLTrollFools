# 石榴动态注入 · 画面 KFD / 动效 HGhubX

这次不是整站换皮，是把两套东西拆开重组：

| | 来源 | 拿到了什么 |
|---|---|---|
| **画面** | 王者内核 KFD（P2 胶囊分页） | 纯黑底、细线卡、荧光绿、白色药丸分页、33pt 细体大字、彩色终端 |
| **动效** | HGhubX `src/styles/ios.css` | 按下 0.965、逐条上浮入场、药丸滑移、页面横向进出、弹窗过冲 |

上一版把画面也做成了 HGhubX 的暖纸玻璃，这一版全部推翻重做。

---

## 一、画面：一比一取自 `绘图/BBZView.mm`

色值不是肉眼估的，是直接读 `SLK_` 系列宏：

| 语义 | 宏 | 色值 |
|---|---|---|
| 底色 | `SLK_底色` | `#07080B` |
| 卡面 | `SLK_卡面` | `#0E1014` |
| 卡面 2 | `SLK_卡面2` | `#16191F` |
| 开启卡面 | `SLK_开卡` | `#0F2B22` |
| 细线 | `SLK_线` | `white @ 6.5%` |
| 主字 | `SLK_主字` | `#F2F4F8` |
| 次字 | `SLK_次字` | `#8E96AA` |
| 弱字 | `SLK_弱字` | `#61697C` |
| 极弱 | `SLK_极弱` | `#3E4552` |
| 绿 | `SLK_绿` | `#35E0A1` |
| 红 | `SLK_红` | `#FF6E78` |

结构也照搬：

- **顶栏**：32pt 圆角方块里一颗 9pt 发光绿菱（旋转 45°）+ 标题 + 8.6pt 字距 1.1 的全大写副标 + 右侧圆形按钮
- **分页**：`#0E1014` 胶囊容器 + 3pt 内边距 + 白色药丸（`#F2F4F8`）+ 深墨字（`#0A0C10`），药丸圆角 11、容器圆角 14
- **状态卡**：10pt 全大写小标题 → 33pt `light` 大字 → 细线 → 5pt 状态点 + 状态 + `·` + 副信息；开启时整卡变 `#0F2B22`，描边转绿 24%
- **终端**：`#05080C` 底、14 圆角、10.5pt 等宽；`[HH:mm:ss]` 前缀压暗，正文按关键字上色（成功绿 / 失败红）
- **主按钮**：绿底 + 深墨字、52 高、15 圆角、绿光投影
- **行卡**：32pt 图标方块（`#16191F` 底 + 绿图标）+ 13.5pt 标题 + 10.5pt 副标

三个页面（应用 / 注入 / 暂存箱）全部走这套，没有一处残留上一版的玻璃材质或暖纸色。

---

## 二、动效：HGhubX 的曲线，翻成 SwiftUI

HGhubX 是 CSS 动画，SwiftUI 没有 `cubic-bezier`，全部换算成 `spring(response:dampingFraction:)`。过冲量按二阶系统 `exp(-ζπ/√(1-ζ²))` 对齐：

| HGhubX | CSS | SwiftUI |
|---|---|---|
| 主弹簧 | `cubic-bezier(.34,1.56,.64,1)` | `.spring(response: 0.42, dampingFraction: 0.62)` |
| 软弹簧 | `cubic-bezier(.22,1.28,.36,1)` | `.spring(response: 0.5, dampingFraction: 0.80)` |
| 按下 | `scale .965` / `55ms` | `.scaleEffect(0.965)` + `.easeOut(duration: 0.055)` |
| 药丸滑移 | `transform .34s spring` | `.spring(response: 0.34, dampingFraction: 0.68)` |
| 页面进场 | `motion-page-in` 18px | `.spring(response: 0.40, dampingFraction: 0.74)` |
| 逐条入场 | `motion-rise` 14px + `.98` | `.spring(response: 0.44, dampingFraction: 0.70)` |
| 弹窗 | `motion-dialog-in` `.97→1.005→1` | `.spring(response: 0.36, dampingFraction: 0.66)` |
| 标题 | `motion-title-in` `-10→+2→0` | `.spring(response: 0.62, dampingFraction: 0.84)` |

落到界面上的具体表现：

1. **按下**：任何按钮/卡片按下瞬间缩到 `0.965`（55ms 压下去），松手用主弹簧弹回，会轻微过冲
2. **逐条入场**：每页内容按 35ms 间隔依次从 `y +14 / scale .98` 上浮，弹簧过冲到 `-2px` 再归位
3. **药丸滑移**：`matchedGeometryEffect` + 0.34s 弹簧，切页时白药丸带惯性滑过去，不是线性平移
4. **页面切换**：三页常驻，新页从 `x +18` 淡入归位，旧页往 `x -18` 退场，交叉过渡
5. **勾选**：圆点选中时 `scale 0.94 → 1` 弹一下，绿底黑勾
6. **状态卡**：目标锁定/未选切换时卡面底色、描边、大字颜色一起软过渡
7. **折叠**：插件/分类分组展开收起走主弹簧
8. **进度**：转圈用 `linear.repeatForever`，和 CSS `kf-spin` 一致

`KFDialog` 也按 `motion-dialog-in` 做了 0.97 → 1.005 → 1 的过冲进场，目前主流程用系统 Alert，需要自定义弹窗时可直接替换。

---

## 三、改了哪些文件

| 文件 | 改动 |
|---|---|
| `TrollFools/KFStyle.swift` | **新增 1006 行**，整套视觉 + 动效系统（`KFColor` / `KFMotion` / 24 个组件） |
| `TrollFools/HGStyle.swift` | **删除**（上一版 HGhubX 风格，已不再引用） |
| `TrollFools/TempHome.swift` | 三页全部重画；1–892 行数据层（`StashManager` / `ImportEngine` / `GameInjector` / `TargetSelection` / `FavoriteApps` / `TabRefreshSignal`）原样未动 |
| `TrollFools/TrollFoolsApp.swift` | 加 `.preferredColorScheme(.dark)`，整套是纯深色设计，锁深色防止系统 Alert/键盘回到浅色 |
| `TrollFools.xcodeproj/project.pbxproj` | `HGStyle.swift` → `KFStyle.swift`（4 处引用） |
| `AccentColor` | `#0065D5`（HGhubX 蓝）→ `#35E0A1`（KFD 绿） |
| `预览_KFD画面_HGhubX动效.html` | 新增，可交互预览（点分页看药丸滑移、点「重播入场动画」看逐条上浮） |

功能逻辑一行没删：

- 注入流程 `startInjection()` → `GameInjector.injectAndLaunch`
- 插件分组折叠（`UserDefaults` 持久化 `shiliu.injectCollapsed`）
- 暂存箱分类折叠 / 新建分类 / 删除确认（`shiliu.stashCollapsed`）
- 收藏置顶（`shiliu.favoriteApps`）
- 切页刷新信号 `TabRefreshSignal`（三页常驻，`onAppear` 不再触发，靠 tick 重读盘）
- 日志清空 / 复制（`UIPasteboard`）

---

## 四、兼容性

`IPHONEOS_DEPLOYMENT_TARGET = 14.0`，全部用 iOS 14 可用的 API：

- 没用 `PhaseAnimator`（17+）、`contentTransition`（16+）、`.overlay { }`（15+）、`NavigationStack`（16+）
- 玻璃模糊没用了，所以不需要 `UIVisualEffectView` 兜底（上一版为 iOS 14 专门写过 `HGBlurView`，这版删掉）
- `matchedGeometryEffect` / `LazyVStack` / `onChange(of:perform:)` 都是 14.0 起可用

---

## 五、验证情况

Windows 上没有 Swift 工具链，**没做编译验证**。已做的检查：

- 括号/中括号/圆括号全局平衡（两文件均差值 0）
- 全量符号核对：24 个 `KF*` 类型全部有定义，`KFColor` / `KFMotion` 成员无缺失引用
- 签名核对：所有 `KF*` 调用点的参数标签与定义顺序逐一比对通过
- 修掉三个已知陷阱：
  - `Text + Text` 跨行 `+` 会被解析成一元运算符 → 拆成局部变量
  - 局部变量 `body` 遮蔽 `View.body` 计算属性 → 改名 `rest`
  - `TextField` 上叠 `onTapGesture` 会抢走聚焦 → 改用 `onEditingChanged`
- 动效用 HTML 预览按同一套曲线验证过：130ms 抓帧可见逐条上浮进行中

预览页在包里 `预览_KFD画面_HGhubX动效.html`，点开就能试药丸滑移和入场动画。

Xcode 报错的话把行号和报错贴给我，直接改。
