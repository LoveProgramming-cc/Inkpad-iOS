# 项目交接说明（给下一位 AI 助手和以后的自己）

写于 2026-11-02，换设备前。以前的对话记录不会保留，以这份文件、`README.md` 和 git 历史为准。

## 目标

- 把 GNOME 版手写笔记应用 **Inkpad** 移植成 Apple 平台的原生应用：iPad 为主，也支持 iPhone 和 Mac（Mac Catalyst）。Swift 编写，画布用 UIKit，界面用 SwiftUI。
- **完全对等**：GNOME 版有的功能都要移植，不用逐个询问要不要。界面要照原版的颜色、图标和布局复刻，不用系统默认控件代替。
- 两边使用同一种 `.inkpad` 文件格式和同一套 Google Drive 同步协议，必须互相兼容。在 Linux 上写的笔记要能在 iPad 上接着写，反过来也一样。
- 一个平台上修的问题，如果另一个平台也有，两边一起改。

## 仓库

| 项目 | 位置 |
| --- | --- |
| iOS / iPadOS / Mac | 本仓库，GitHub `LoveProgramming-cc/Inkpad-iOS` |
| GNOME（Linux，Python + GTK） | GitHub `LoveProgramming-cc/Inkpad-gnome`；在 Linux 电脑上运行，改完要 `git pull` |
| 旧的参考代码（只读，不要修改） | `~/Documents/programming/AI/Claude/Claude AI's Gnome Software/Notes`、`~/Downloads/Notes` |

## 规矩（用户明确要求过的）

- 用**中文**回复用户。
- 提交信息里**不加任何 AI 合作者 / 贡献者署名**（例如 `Co-Authored-By`）。原因是原作作者的情况比较复杂。
- 在 GNOME 仓库里提交时使用 `git -c user.name=LoveProgramming-cc`，推送用 `git push origin HEAD`。
- 不要使用或输入用户的 Apple ID 账号和密码。
- 不要开启 `tools/auto_renew.sh on`。
- 不要读取用户真实的笔记内容（Google Drive 里的 Inkpad 文件夹、`~/Documents/Inkpad`），涉及隐私。测试请用合成数据。

## 设备与工具

- 用户的设备：Mac（MacBook Air）、Koen 的 iPad（iPad Air M2）、Koen 的 iPhone，偶尔还有 hongyu 的 iPad（iPad Air M3）。Linux 桌面上运行 GNOME 版。
- 签名用的是**免费 Apple ID**，每次签名只有效 7 天：
  - `tools/install.sh` 编译并安装到设备。用法：`--all` 装所有在线设备，`--list` 只列设备，`<名称或 UDID>` 装指定设备，`--renew` 先作废旧签名、重新签满 7 天。
  - Xcode 更新后的第一次编译要好几分钟，期间几乎没有输出，属于正常现象。
  - 设备必须解锁，并且和 Mac 在同一个 Wi-Fi 下（或用线连接）。
- Mac 版：`tools/build_mac.sh` 生成 `dist/Inkpad.app`，然后替换 `/Applications/Inkpad.app`。
- 测试：`InkpadTests`（单元测试）和 `InkpadUITests`（界面测试），在 iPad Pro 11 模拟器上运行。
  - 界面测试要求模拟器是**全屏**模式（设置 › 多任务与手势），在窗口模式下点击坐标会偏。
  - 界面测试每次只跑一个（`-only-testing`），跑完执行 `pkill -f "simctl diagnose"`。
- 排查输入问题：在应用里打开 设置 › 高级 › 记录输入日志，日志写到应用"文稿"目录下的 `input.log`。可以用下面的命令从 iPad 取回来：
  `xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer --domain-identifier com.koen.inkpad --source Documents/input.log --destination input.log`
- iPad 的"文件"App 和 Mac 访达的设备页里都能看到 Inkpad 文件夹（已开启 `UIFileSharingEnabled`）。

## 历史（大致按时间）

1. **2026-10-09**：首个版本，覆盖 iPad / iPhone / Mac。之后逐项追平 GNOME 版的功能和界面，包括笔、荧光笔、胶带、橡皮、套索选择、尺子、激光笔、文本框、PDF、并排翻页、小地图、笔的工具盘、Google Drive 同步和按笔画合并等。
2. **同步间隔**：打开笔记本后会定时同步，间隔可以在设置里调（5 秒到 5 分钟），两个版本都有。
3. **涂抹删除（来回划掉笔画）**：
   - 原来的判定太敏感，连笔写 "tro" 也会被删，所以改成按笔画的范围大小调整转角门槛。
   - 后来发现大范围的直线来回划又不触发，于是加了"直线来回划"的判定。
   - 设置里新增"宽松的涂抹删除"，默认关闭，打开后使用旧的判定方式。
   - 用合成笔迹测试：正常书写被误删约 3%（主要是一笔写成的 m、M、W），涂抹被识别出约 91%。两个版本的判定方式一致，测试样本在 `InkpadTests/ScribbleSamples.swift`。
4. **签名与安装**：
   - `install.sh` 新增 `--renew`。
   - 新版 Xcode 的设备列表不再把真机标为 "physical"，脚本因此一台设备都找不到，已修复。
   - 中途按 Ctrl-C 时，会把移开的旧签名文件放回原处。
5. **iPad 上的几个问题**（2026-10 下旬）：
   - 选中笔画后的颜色选择改成和桌面版一样的 5 列色块网格。
   - 选区靠近屏幕顶端时，选项条不再被顶部的浮动工具条挡住，放不下就移到选区下方。两个版本都改了。
   - iPad 窗口模式下，顶栏会给左上角的窗口按钮（红绿灯）让出位置。
   - **窗口不在最前时，手指滑动一次之后就再也滑不动，必须用笔画一下才能恢复**：
     - 原因：输入日志显示，这种滑动结束后，页面的手势和系统的窗口手势都停在"已结束"状态，不再复位。
     - 修法：每次手指滑动页面时，同时作为一次不画任何东西的笔画走完（见 `CanvasTools.swift` 的 `StrokeGesture` 里的 `idle`），手指抬起时所有手势就复位了。
     - 已在真机上确认修好（提交 `9f94316`）。

## 尚未完成 / 已知问题

- 左右翻页的界面测试 `testZSideBySidePaging` 在打开设置后找不到"用手指书写"开关。点选与长按菜单的测试 `testZZSelectByTapAndPressMenu` 也会失败，撤掉相关改动后同样失败。推测是模拟器转了方向造成的，或者是新加的测试 `testZZSelectionNearTheTop` 移动了测试笔记的位置。还没有查清楚。
- hongyu 的 iPad 已经很久没有装上新版了（一直不在线）。
- iPhone 版和 Mac 版的一些面板在窄屏上可能排不下；Mac 上的鼠标书写和 Google 登录没有实际操作验证过。
- 免费签名每 7 天到期，到期后需要运行 `tools/install.sh --renew --all`。
