<p align="center"><img src="docs/assets/vela.png" width="96" alt="Vela 桌面伙伴"></p>

# Vela

**Keeping watch. Keeping you connected.**  
替你值守，随时相连。

[English](README.md)

Vela 是一个原生 macOS 桌面伙伴，集保持唤醒、本机 Agent 自动值守与远程桌面于一体。你可以和桌面上的小家伙互动，也可以离开电脑，让它保持工作运行，并从其他设备接回桌面。

## 功能

- **桌面陪伴：** 拖动定位、多种形体、眼睛与表情动画、自动表情、独立唤醒／静息配色、渐变和实时 Metal 特效。隐藏桌宠不会停止其他功能。
- **保持运行：** 保持显示器唤醒、允许屏幕休眠但系统继续运行，或合盖后继续运行。支持无限时长、自定义时长，以及真实键鼠空闲后开始并在操作时重置的倒计时。
- **Agent 值守：** 检测 Claude Code、Codex、Gemini CLI、Cursor Agent、Copilot CLI、Aider、OpenCode 和自定义可执行文件名。可选“仅工作中的 Agent”或“进程存在即保活”，并提供静默宽限、低电量与过热保护。
- **远程桌面：** 使用支持 WebRTC 的浏览器或内置的 **Vela Connect** Mac 控制端连接；支持显示器与画质选择、键鼠操作、文本发送、触控模式和桌面切换手势。
- **虚拟显示器：** 创建自定义分辨率与 HiDPI 的远程屏幕。可在虚拟屏工作时关闭物理显示器，本机输入、断线和恢复机制负责恢复物理屏。
- **原生设置：** 通用、唤醒、值守、外观、远程五个页面，采用紧凑分组、Liquid Glass 导航工具栏和原生开关、滑块，支持浅色、深色、自动三种外观，自动模式跟随系统，并尊重辅助功能偏好。
- **中英双语：** 无论系统语言如何，首次默认使用英文。在主应用 **Settings → General → Language**（中文界面为“通用 → 语言”）、Vela Connect 工具栏或网页语言选择器中切换简体中文。各端独立保存选择，切换语言不重启远控会话。

## 环境要求

- macOS 26 或更高版本，以及 Swift 6 工具链／Xcode 命令行工具。
- 首次解析固定版本的 Swift Package Manager 依赖需要网络。
- 可使用的应用包需要固定代码签名证书。构建脚本优先读取 `SIGNING_IDENTITY`，其次读取 `.signing-identity.local`；不会回退到临时签名。
- 网页单元测试需要 Node.js；翻译检查与浏览器模拟服务需要 Python 3。

## 构建和运行

```sh
swift package resolve
./scripts/build-app.sh release Vela
open dist/Vela.app
```

应用包内包含原生控制端：

```text
Vela.app/Contents/Applications/VelaConnect.app
```

也可从 **设置 → 远程 → 原生控制端…**（英文为 **Open Vela Connect…**） 打开。打包脚本会签署并验证主应用、控制端及其 WebRTC framework，不执行 Apple 公证，也不自动替换 `/Applications` 中已安装的版本。

从已签名的应用包生成磁盘映像：

```sh
./scripts/create-dmg.sh dist/Vela.app dist/Vela.dmg
```

打开 DMG，将 Vela 拖入 Applications 即可安装。磁盘映像会保留应用原有的签名。

## 自动发布

[Release 工作流](.github/workflows/release.yml) 仅在推送 `v*` 版本标签时自动构建并发布，更新 `main` 不会触发构建或生成产物。也可在 Actions 手动运行，必须填写已有版本标签；勾选 `publish` 才会发布该标签的 Release。

```sh
git tag v1.2.3
git push origin v1.2.3
```

工作流校验版本，运行 Swift、Python、Node 测试，在官方 [Xcode 27 arm64 环境](https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/) 构建主应用和 Vela Connect，并将 DMG、ZIP 和 SHA-256 校验文件上传到 Actions 和 GitHub Releases。标签版本会写入两个应用；`v1.2.3-beta.1` 等标签生成预发布版本。不需要个人 GitHub Token，也不会创建、移动标签或覆盖已有 Release。

未配置签名时生成明确标记为 `unsigned` 的测试包。需要固定证书签名时，在仓库 **Settings → Secrets and variables → Actions** 配置全部三个 Secrets：

| Secret | 内容 |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | 含签名证书及私钥的 P12 文件，经 Base64 编码后的内容 |
| `MACOS_CERTIFICATE_PASSWORD` | P12 导出密码 |
| `MACOS_SIGNING_IDENTITY` | 证书 SHA-1 或签名身份名称 |

证书仅导入临时钥匙串，打包后删除。签名配置不完整或签名失败时直接终止，不会回退到临时签名。持续使用同一证书有助于保留更新后的系统权限。目前 CI 构建仅支持 Apple Silicon，未执行 Apple 公证；不会自动上传本机证书或私钥。

仅编译或检查未签名包结构：

```sh
swift build -c debug
./scripts/build-app.sh release Vela --offline-check
```

未签名结构检查包位于 `.build/offline-bundle/Vela.app`。可用 `VELA_OUTPUT_DIR` 指定签名构建的输出目录。

## 日常使用

Vela 启动时保持唤醒关闭，桌宠显示。通过菜单栏或悬停桌宠后出现的按钮，控制保持唤醒、Agent 值守、保持方式和设置。默认全局快捷键为 **Control + Option + Command + K**。

手动保活与 Agent 值守共用保持方式。“仅工作中的 Agent”通过 `caffeinate` 子进程或约 60 秒的 CPU 活动判断；低 CPU 的网络等待可选择“进程存在即保活”。检测仅针对当前用户的本机进程，不能看到远端或容器内进程。

设置包含时长、空闲阈值、Agent 静默宽限、低电量阈值、自定义 Agent、登录启动、外观与语言。重新启动时不会自动恢复手动保持唤醒；明确开启的远控会随应用启动恢复。

合盖值守会请求管理员授权，临时管理 `pmset disablesleep`。临时监视进程在正常停止、应用退出或心跳异常后恢复原设置。它不是常驻系统服务，无法在系统重启后、登录前继续恢复。如果合盖值守期间发生重启或断电，开机后应检查 `pmset -g`，必要时使用 `sudo pmset -a disablesleep 0` 恢复。

## 远程连接

1. 在 **设置 → 远程** 中选择“自定义密码”或当前“macOS 系统账户”，再明确开启远控。自定义密码至少 10 个字符。
2. 在被控 Mac 为 Vela 授予 **屏幕录制**和**设备控制和数据访问**权限（macOS 26 中称为“辅助功能”），入口位于 **设置 → 远程**。**输入监控**权限单独在 **设置 → 唤醒** 中管理。如系统请求本地网络权限，也需要允许；按系统提示退出并重新打开应用。
3. 使用设置页显示的实际地址，通常为 `https://IP:8443`。监听范围可选仅局域网或所有 IPv4/IPv6 接口；后者包含可达的 VPN 接口。IPv6 地址须加方括号，例如 `https://[fd00::1234]:8443`。仅展示稳定、就绪的 IPv6 地址；排除临时隐私地址和状态不可用的地址，避免正常轮换触发证书更新。同时排除未指定、多播及链路本地 IPv6 地址，不支持链路本地作用域标识。`0.0.0.0` 和 `::` 是监听地址，不能用作连接目标。VPN 路由和访问策略须允许 HTTPS 与 WebRTC 媒体。地址变化可能更新证书，需要重新核对并信任。
4. Vela Connect 首次连接时核对主机证书的 SHA-256 指纹。使用浏览器时，先导出公开证书，通过可信方式传送、核对并导入控制设备的信任库，再输入密码。不要复制私钥。
5. 连接后选择显示器，按需使用屏幕键盘和鼠标工具。一次仅允许一个控制者。修改认证方式或访问密码会撤销已有会话。

**浏览器设备记忆：**输入密码时可勾选“记住此设备 30 天”。之后在同一浏览器配置中刷新或重新打开同一主机地址，可免输访问密码；普通“断开”保留授权。如需移除，断开后展开“主机设置 → 忘记此设备”，或取消勾选。被控端“设置 → 远程 → 断开所有会话”、更改认证方式或 Vela 自定义访问密码、关闭远控、更换主机证书都会撤销浏览器授权。授权最长 30 天，普通重启 Vela 可保留，不保存密码。清除 Cookie、无痕浏览、更换访问地址或浏览器配置后可能需要重新输入密码。记住浏览器不会解除 macOS 锁屏；系统锁屏仍需输入当前 Mac 密码。原生 Vela Connect 的行为不变。

系统账户模式仅接受运行 Vela 的本机账户，密码交给 macOS 验证且不保存。不支持 Touch ID 或 Apple ID 密码。普通锁屏时，远控显示真正的 macOS 锁屏画面，可点击系统密码框并输入 Mac 密码解锁；不覆盖 FileVault 或开机首次登录前的阶段。

远控要求通过局域网或 VPN 直接可达，不自动配置路由器转发、云中继、公共 STUN 或 TURN。HTTPS 提供网页与信令；WebRTC 协商媒体端口，优先使用 UDP。

## 传输画质

主机沿用 ScreenCaptureKit、VideoToolbox 硬件 H.264/HEVC 和 WebRTC。网页与 Vela Connect 均提供“自动”“文字清晰”“动态流畅”偏好，并保留原有分辨率上限。“自动”按控制端窗口的实际像素尺寸适配；“文字清晰”在带宽不足时优先降低帧率；“动态流畅”允许更早降低分辨率。主机在持续受限后降档，在确认恢复后逐级升档，普通画质调整不需要重连。

两端均支持“适应窗口”、100% 逐像素显示，以及 150% / 200% / 400% 放大查看。缩放会保留正在查看的位置；放大时按所选源画质请求细节，不再仅按窗口大小缩小采集，但仍遵守分辨率上限和网络自适应。可拖动滚动条，或按住 Alt/Option 滚动来平移本地画面。手机端可像放大图片一样，用双指捏合放大手指间的局部，再用双指移动视野。单指鼠标操作、实体键盘和屏幕键盘持续可用，无需切换查看模式。“适应窗口”时双指平移仍滚动远程内容；鼠标滚轮始终控制远程电脑。放大无法恢复采集或传输中已经丢失的细节。

画面停止变化后，会在有限时间内补充细节帧，随后回到低频刷新。网页“画质”面板显示实际编码、采集与接收尺寸、可用时的编码/解码耗时及自适应状态。静止桌面的低码率属于正常现象。

两端的“无损文字增强”默认关闭。启用后，仅在画面稳定、网络未受限且带宽估计充足时，从 RGB 采集生成有大小限制的 PNG 图块。H.264 帧内身份信息确保图块与接收到的视频匹配；不兼容的浏览器继续使用视频。图块流量最多占估计带宽的 10%，且不超过 2 Mbps，大桌面可能只覆盖部分区域。频繁变化的画面可能推迟增强。切换语言会保留连接与选项。

Vela 已为固定版本 WebRTC 154.0.0 的 H.265 SDP/RTP 支持补充硬件 VideoToolbox 编解码适配器。Vela Connect 先验证合成 4K 画面的适配器回环；主机也必须验证通过且接收端明确支持，才启用 HEVC。浏览器还需具有 WebRTC H.265 Main 能力，并通过硬件高效 WebRTC 解码能力检测。任一端不支持、协商或初始化失败，或会话恢复之外连续六秒没有解码进展时，均保留 H.264 回退。界面按实际 RTP 统计显示编码。HEVC 使用 8 位 Main 配置；启用无损增强时切换至 H.264。验证结果与限制见 [HEVC 验收记录](Design/vela-hevc-end-to-end-2026-11-04.md)。

## 虚拟屏与物理屏

在网页 **显示** 面板创建并选择虚拟屏。提供 18 个预设，其中 13 个竖屏尺寸按手机、平板和高清分组，也支持自定义尺寸。手机可先选 **1080 × 2400** 并开启 **HiDPI**，对应 540 × 1200 的逻辑桌面。总像素上限为 3840 × 2160，支持竖屏。HiDPI 下每个方向的逻辑尺寸为像素尺寸的一半，至少需要横屏 640 × 480 或竖屏 480 × 640 的逻辑桌面；实际接收尺寸以 **画质** 面板为准。

确认虚拟屏画面正常后，在 **物理屏** 面板关闭 Mac 内屏和外接物理显示器。远程输入继续在虚拟屏工作；本机键盘、鼠标、触控板或“恢复所有物理屏”按钮可以恢复。断线时先恢复物理屏，再关闭虚拟屏。

关闭物理屏不等于密码锁定。真正的系统锁屏会恢复物理屏，并切换采集到系统锁屏画面；解锁后返回先前选择的桌面屏幕。显示器管理依赖运行时检测的私有接口，macOS 更新可能影响其可用性；显示拓扑变化时的窗口移动由 macOS 管理。

## 开发与检查

```sh
swift test
node --test Tests/WebClient/*.test.cjs
python3 scripts/check-localization.py
.build/debug/Vela --watch-policy-test
.build/debug/Vela --self-test
```

原生自检会短暂创建真实电源断言与测试窗口，并在结束后释放，使用隔离的偏好和远控设置。实时 Metal 检查需要可见桌面；窗口被遮挡时，会明确报告未能判定。

无需改变真实桌面状态的浏览器模拟测试：

```sh
python3 Tests/WebClient/mock-server.py --port 8769
```

在全新浏览器上下文打开 `http://127.0.0.1:8769`，分别加载 `/language-tests.js`、`/session-tests.js`、`/touch-tests.js`，调用 `runLocalizationChecks()`、`runPrivateSessionChecks()`、`runTouchChecks()`。语言检查应在全新页面首先运行。这些模拟会替换 WebRTC 与 API 调用，不会控制真实 Mac。

英文 [AGENTS.md](AGENTS.md) 说明架构、翻译约定和开发流程；[TESTING.txt](TESTING.txt) 说明额外测试与现场操作边界。

## 兼容性与当前限制

- Vela 保留原有 `app.aiomni.awakepet` 和 `app.aiomni.awakepet.remoteviewer` bundle ID，以维持签名身份和系统权限。应使用同一签名证书；改变安装路径仍可能触发系统重新批准。
- 已有 `~/Library/Application Support/AwakePet/RemoteControl` 数据会原地复用，包括证书和运行锁。全新安装使用 `~/Library/Application Support/Vela/RemoteControl`。更名本身不会重置密码或重新生成证书。
- 尚不包含音频、文件传输、剪贴板同步、云中继或登录前访问。远控本身不阻止合盖睡眠。
- 保留原有桌宠造型、全部表情与动画序列。运行 `python3 scripts/check-companion.py` 可检查资源完整性。素材来源及上游使用限制记录在应用包随附的 [ThirdPartyNotices.txt](Resources/ThirdPartyNotices.txt) 中；Vela 不会为这些素材重新授权。
- `Design/` 中的旧文档保留历史开发与验收记录，可能出现旧产品名与已被替代的行为描述。
