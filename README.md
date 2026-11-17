# SLTrollFools

基于 [TrollFools](https://github.com/Lessica/TrollFools) 的个人定制分支（石榴动态注入）。

- **画面**：KFD / SLK 深色终端风（纯黑底 `#07080B`、细线卡、荧光绿 `#35E0A1`、等宽日志）
- **动效**：HGhubX 弹性体系（主弹簧 `response .42 / damping .62`、按下 0.965、逐条上浮入场、药丸 `matchedGeometryEffect` 滑移）
- **最低系统**：iOS 14.0（动效全部使用 iOS 14 可用 API）

三栏结构：**应用 / 注入 / 暂存箱**。数据层（注入引擎、暂存箱、收藏、切页刷新信号）沿用上游实现。

## 下载

在 [Releases](../../releases) 下载 `SLTrollFools-*.tipa`，用 TrollStore 直接安装。

也可以从 Actions 的构建产物 `SLTrollFools-x.y-z` 里取。

## 构建

`.github/workflows/build-tipa.yml` 在 push 到 `main` 时用 macOS runner + Theos 打包：

```bash
make package FINALPACKAGE=1
```

产物落在 `packages/*.tipa`（Theos 输出的中文名会被工作流复制并重命名为 `SLTrollFools-<版本>-<构建号>.tipa`）。

## 目录

| 路径 | 说明 |
|---|---|
| `TrollFools/KFStyle.swift` | 设计系统：配色、动效常量、24 个界面组件 |
| `TrollFools/TempHome.swift` | 主界面三个页面 + 注入/暂存数据层 |
| `TrollFools/TrollFoolsApp.swift` | App 入口，锁定深色外观 |
| `TrollFoolsTweak/` | 注入用的 Swift 运行时（dylib 侧） |
| `devkit/tipa.sh` | Theos 打包后处理：拼 Payload、签名、zip 成 tipa |

## 上游信息

In-place tweak injection with insert_dylib and ChOma.
Expected to work on all iOS versions supported by opa334's TrollStore (i.e. iOS 14.0 - 17.0).

- [ChOma](https://github.com/opa334/ChOma) by [@opa334](https://github.com/opa334) and [@alfiecg24](https://github.com/alfiecg24)
- [MachOKit](https://github.com/p-x9/MachOKit) by [@p-x9](https://github.com/p-x9)
- [insert_dylib](https://github.com/tyilo/insert_dylib) by [@tyilo](https://github.com/tyilo)

## License

See [LICENSE](LICENSE).
