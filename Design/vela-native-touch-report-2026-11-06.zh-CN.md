# Vela 远程原生触摸调研与原型验证总报告

**报告日期：2026 年 11 月 6 日（Asia/Shanghai）**

**本机环境：macOS 27.0.1，build 26A434，Apple Silicon**

**当前阶段：最小原型已完成；授权关未通过；原生触摸尚未验证。**

> **一句话结论：我们想让手机／iPad 的手指操作交给 macOS 原生触摸系统处理，而不是模拟鼠标。CoreHID 是值得验证的公开路线，但当前实验应用声明 HID entitlement 后被 AMFI 因“没有匹配的授权 profile”拒绝运行；还不能判断第三方虚拟触摸屏能否进入原生 AppKit 分发并绑定远程显示器。**

本报告是统一阅读入口。原始探针、阶段性报告和源码均保留，不覆盖历史证据。只看决策结论可先读第 1、2、6 节；复核实测结果看第 3 节与附录。

## 1. 到底要解决什么问题

### 1.1 产品目标

让手机／iPad 通过 Vela 远程控制 Mac 时，能够像触摸屏一样操作：

- 点击、拖动和滚动；
- 长按及双指缩放；
- 尽可能复用 macOS 原生控件和手势识别器，而不是在 Vela 中重写整套手势规则。

目标链路是：

```text
手机／iPad 原始触点
  → Vela 已认证、加密的连接
  → Mac 上应用持有的虚拟触摸屏
  → macOS 原生触摸分发与显示器关联
  → AppKit 控件／手势识别器
```

手机端主要传触点编号、位置、按下／移动／抬起状态；系统负责解释交互。**这是拟验证的架构，不是已经实现的端到端功能。**

本次实际原型只有本机部分：

```text
本地生成的确定性触点序列
  → CoreHID 虚拟触摸屏【创建／授权关未通过】
  → 独立 AppKit 接收窗口【窗口已能运行，触摸未验证】
```

浏览器原始触点协议、认证连接中的触点传输和 Vela 主进程集成均未新增。现有鼠标／滚动输入路径未被替换。

### 1.2 不属于这次成功标准的东西

以下现象都不能证明目标已经实现：

- 鼠标能移动、能点击或收到合成滚轮事件；
- 虚拟设备 API 存在，或程序能编译；
- 签名完整性校验通过；
- HID 设备能枚举，或显示器属性能读回；
- 收到一个鼠标／触控板来源的缩放事件。

**最低成功标准是：原生接收窗口收到真正的 `.direct` `NSTouch` 生命周期，标准滚动区域发生手指滚动，原生缩放识别器响应双指触摸，所有触点正常结束。**

即使通过，也只证明受控测试窗口的能力，不等于所有第三方应用、所有显示器布局或手机端均已兼容。本项目不需要先接入完整 Sidecar 私有会话，也不宣称自己就是 Sidecar。

验收依赖隔离、无其他输入的受控条件。当前只能做阶段／位置／生命周期相关性检查，AppKit 未提供已认证的 HID 来源身份；不能将受其他输入污染的结果当作本虚拟设备的因果证明。延迟或合并的回调也可能使对应检查保守地失败。

## 2. 当前结论：两道关卡，不要混在一起

| 关卡 | 要回答的问题 | 当前状态 |
| --- | --- | --- |
| **第一关：设备创建授权** | 普通应用能否通过合法签名，创建并使用 CoreHID 虚拟触摸屏？ | 当前签名配置未通过；AMFI 报 `-413 / No matching profile found` |
| **第二关：原生识别与显示器关联** | 创建成功后，macOS 是否把第三方 digitizer 作为直接触摸分发，并落到选中的显示器？ | 本机尚未验证；社区有显示器关联失败的反例 |

**拿到 HID 授权，只是打开第一关，不等于第二关自然成功。**

总体判断：继续保留 CoreHID 最小原型，先解决合法授权；在原生接收和显示器绑定通过前，不扩展浏览器触点协议，不承诺手机／iPad 原生触控功能可交付。

## 3. 已做了什么：按证据强度整理

### 3.1 接口与系统实现调查（11 月 4 日）

本机发现公开 CoreHID 虚拟设备 API，以及 Sidecar 相关 digitizer、原生触摸和显示器关联线索。Apple 开源头文件明确要求 Sidecar 私有事件服务的事件分发 entitlement。

初期探针打开 HID resource user client 返回 `0xe00002c2 / invalid argument`。**这个错误本身不能归因于权限不足**，也不是设备创建结果。后续改用真正的 CoreHID 初始化和签名对照，才取得了更强证据。

来源：[初期调研](<vela-native-touch-research-2026-11-04.md>)、[初期探针](<vela-native-touch-probe-2026-11-04.json>)。

### 3.2 独立最小原型（11 月 6 日）

新增独立实验目标 [VelaTouchLab](<../Sources/VelaTouchLab/main.swift>)，不进入 Vela 正常启动流程，也未通过生产打包脚本替换正式应用。

已实现：

- 双触点 touchscreen HID 描述符与完整触点报告；
- 公开 `HIDVirtualDevice` 创建、激活及输入报告接口；
- 只访问本次虚拟设备的描述符／Feature 读回检查；
- 独立 AppKit 窗口，显式允许 `.direct` 触摸，使用标准滚动区域与原生缩放识别器；
- 生命周期、阶段、位置和手势结果记录；
- 取消、终止触点及清理逻辑，且不以鼠标模拟作为原生成功证据。

实际运行结果：

| 检查 | 结果 | 能证明什么 |
| --- | --- | --- |
| 原型编译 | 通过 | SDK 调用和程序结构可构建 |
| 未带 HID entitlement 的创建探针 | `HIDVirtualDevice` 初始化返回 `nil`；执行进程 entitlement 为 false | 这次没有取得虚拟设备；缺少必要声明被独立确认 |
| 接收窗口冒烟测试 | 运行约 3 秒并退出；`.direct` 识别器与标准触摸滚动配置已创建 | 接收窗口可以运行；**不是触摸送达验证** |
| 设备激活／Feature 往返 | 未取得实际成功结果 | 检查代码已实现，但没有通过前置授权关 |
| 输入报告与原生手势 | 未实发；没有原生接受结果 | 不能宣称成功，也不能据此判定 macOS 不支持 |

`HIDVirtualDevice` 初始化失败只返回 `nil`，不提供底层 `IOReturn`。不能虚构具体内核错误，也不能断言缺少 entitlement 是所有失败原因。

来源：[原型阶段报告](<vela-corehid-touch-prototype-2026-11-06.md>)、[创建探针](<vela-corehid-touch-probe-2026-11-06.json>)、[接收窗口结果](<vela-corehid-touch-receiver-2026-11-06.json>)。

### 3.3 同构建、同证书的签名对照：当前最强本机证据

将**同一份编译产物**打包成两份独立实验应用，使用现有固定本地证书、同一实验 App ID 和同样的 hardened runtime 配置；只改变 HID entitlement 声明。

| 项目 | 不声明 HID entitlement | 声明 HID entitlement 为 true |
| --- | --- | --- |
| 构建输入 | 同一份二进制，输入哈希一致 | 同左 |
| 签名完整性／证书绑定要求 | 校验通过 | 校验通过 |
| Apple Team ID／Apple 签名链 | 无 Team ID／未通过 Apple anchor 验证 | 同左 |
| Embedded provisioning profile | 无 | 无 |
| 实际运行 | 正常退出，返回码 2，输出探针 JSON | 返回 -9／`SIGKILL`，无探针 JSON |
| CoreHID 初始化 | 返回 `nil`，实际 entitlement 为 false | **不可观察，不能填造初始化结果** |
| Input 报告 | 0，未尝试提交 | 测试入口不含输入提交；没有内部进度输出 |

对应第二份实验应用的 `amfid` 日志明确报告：

```text
AppleMobileFileIntegrityError
Code = -413
No matching profile found
```

对照已核对构建输入哈希、签名后文件与实际运行文件哈希，以及精确实验应用对应的 AMFI 日志。采集器没有主动超时杀死第二份进程。

匹配对照对应 JSON 中记录哈希的当时构建。当前源码随后补充了实发前的自有设备读回／Feature 无输入检查门禁；最终源码编译通过，但该门禁没有取得授权后实机成功结果，也未重新实发。不能把两者视为同一测试快照。

**实测结论：现有本地证书＋hardened runtime 配置不能仅靠添加该 entitlement 获得授权；macOS 拒绝这份声明，因为没有匹配的授权 profile。**

签名完整性通过与平台授权通过是两回事。这个对照也不能证明所有签名模式都会完全一样；本机没有测试“去掉 hardened runtime”路线。

来源：[完整匹配对照证据](<vela-corehid-touch-signed-comparison-2026-11-06.json>)、[授权验证报告](<vela-corehid-touch-signed-validation-2026-11-06.md>)。

### 3.4 测试通过与验证边界

- 原型阶段完整 `swift test` 通过，跳过 1 个明确可选的浏览器 harness 测试。
- 签名／无输入检查补充阶段：6 项 Swift 描述符／报告测试、5 项 Python 安全测试通过，最终原型编译通过。
- 本地化一致性、原始 companion 资产保留检查通过。
- 未执行授权后设备激活、真实 Feature 往返、原生输入实发、设备移除验收、远程触点传输或完整端到端测试。
- 未修改系统权限、证书信任、SIP／AMFI、私有 feature flag、显示器／电源状态；未安装驱动或替换正式应用。

本次“整理报告”只复核已有证据与文档链接，没有重跑上述实机实验或测试。

## 4. 到底缺什么权限

**缺的是 Apple 对“创建虚拟 HID 设备”的开发者签名授权，不是系统设置里的开关。**

具体 key：

```xml
<key>com.apple.developer.hid.virtual.device</key>
<true/>
```

可以分成三件事理解：

| 名称 | 作用 | 目前情况 |
| --- | --- | --- |
| entitlement | 应用声明“我要创建虚拟 HID 设备” | 已在一份实验签名中添加；声明本身不等于获准 |
| provisioning profile | Apple 授权哪个团队／App ID 可以使用哪些 entitlement | 实验应用没有匹配 profile；AMFI 明确拒绝 |
| 签名证书 | 证明应用归属，并与 profile 的许可匹配 | 现有固定本地证书无 Apple Team ID，不能代替 Apple 的授权 |

需要取得允许该 key 的 Apple 支持的团队签名／provisioning 组合，并对**实际创建设备的执行进程**签名。不能只给外层包装、其他 helper 或一个资源 plist 添加 key。

辅助功能／Device Control、输入监控、录屏权限、管理员／root 权限，以及 `NSIsTouchNative` 设置，都不能替代这份签名授权。CoreHID 的这个 key 也不是 Sidecar 私有事件分发 key，不应与 DriverKit 名称相近的 key 混淆。

### 4.1 社区找到的申请入口

[Stack Overflow 已接受回答](https://stackoverflow.com/a/79840890) 针对同样的 CoreHID `-413` 错误，指导登录 [Apple 申请页面](https://developer.apple.com/contact/request/system-extension/)，选择 **Virtual HID**。回答附有表单截图。

[Topti 的调查](https://github.com/Yukaii/topti/blob/main/docs/investigations/2026-04-02-corehid-entitlement.md) 记录了 **HID Virtual Device** 申请提交和等待审核；[macgip 的记录](https://github.com/leetrout/macgip/blob/main/notes/entitlements.md) 描述了开发者后台的 App ID → Capability Requests → virtual HID device 路径。

**这是社区实际使用过的申请线索，不是 Vela 已取得授权的证据。** 我们未登录开发者账户、提交申请或验证当前团队能否看到同样选项。审核时间、获批条件、Development／Developer ID 分发支持仍需 Apple 确认。

### 4.2 可直接使用的申请说明草稿

下面是准备文本，**未提交**。实际申请时应明确写出远程控制用途，不照抄其他项目“仅本地操作”的描述。

> Vela is a macOS companion with authenticated, encrypted remote desktop control. We are prototyping an app-owned virtual touchscreen using the public CoreHID HIDVirtualDevice API so raw contact identities, coordinates and phases from an authenticated phone or tablet can be interpreted by native macOS controls and gesture recognizers.
>
> We request com.apple.developer.hid.virtual.device=true for the process that creates this device. The feature is intended to be explicitly enabled, limited to the authorized controller, and cancelled on disconnect, focus/session/display changes. It is not intended to bypass TCC, account authentication or lock-screen policies.
>
> On macOS 27.0.1, our same-build local-certificate control launches without this entitlement. With the entitlement, AMFI terminates the app with AppleMobileFileIntegrityError -413: No matching profile found. Please confirm the capability request process and eligible certificate/profile combinations for development and Developer ID distribution, and whether display association/native direct-touch delivery has additional supported requirements.

## 5. 社区有没有绕过办法

结论是：**没有找到正常安全设置下、免授权、纯软件打通原生 AppKit 触摸的可复现方案。** 这是搜索结果边界，不是“所有技术可能性都不存在”的证明。

| 路线 | 社区调查结果 | 对 Vela 的价值／决策 |
| --- | --- | --- |
| 普通开发证书／取消 hardened runtime | 有 Apple Development 证书无 profile 仍被杀的记录；未找到仅改 runtime 就可靠成功的案例 | 不将重签名碰运气当方案；该变体本机未测 |
| 现成 Karabiner 签名驱动 | 支持键盘／鼠标，客户端无任意触摸屏描述符接口；还需安装、系统扩展批准及 root 服务 | 不是原生触摸的即插即用 helper；不随本次原型安装 |
| RP2040／ESP32 等 USB 硬件代理 | Mac 看到物理 HID，可绕开“应用创建虚拟 HID”的这一关 | 增加硬件；只能作为独立研究路线，不保证原生触摸 |
| HIDTouch 等 CGEvent 桥接 | 鼠标／滚动路径可用；虚拟 digitizer 仍受授权限制 | 可参考代码，不能把鼠标或合成缩放当作原生触摸 |
| 关闭 SIP／AMFI 等降低安全保护 | 有实验项目依赖此配置，不是正常授权；也没有证明本目标可交付 | 不在现有开发机执行，不作为 Vela 产品方案 |
| 正式 CoreHID 授权 | 公开 API、已有社区请求记录，不必先接完整 Sidecar | 当前优先的软件路线，但原生识别仍需独立验收 |

### 5.1 一个重要的第二关反例

[macos27-external-touch](https://github.com/glasses666/macos27-external-touch/blob/main/EVIDENCE.md) 在**相同 macOS 27.0.1／build 26A434** 上，用 Android USB HID gadget 做触屏实验。作者在启用私有开关后取得 digitizer 枚举和 MultiTouch capability，但 WindowServer 仍因缺少可用的 **`displayUUID`** 拒绝关联显示器；用户态 setter 成功不代表属性进入分发服务，最终没有原生触摸。

这是社区作者的实验，**没有在本机复现**。其“属性由驱动／提供者持有”的解释是推断，不证明换 DriverKit 或设置某个 CoreHID 属性就能解决。

它提醒我们：

- 实体 USB 桥绕开第一关，也可能继续卡第二关；
- 当前原型的 `DisplayIntegrated`／显示器 ID 属性是实验线索，不是已被支持的绑定契约；
- 社区的隐藏 feature flag 或 SIP-off 操作没有在本机执行。

社区源代码、版本、矛盾说法及访问限制详见[社区路线报告](<vela-corehid-touch-community-options-2026-11-06.md>)。

## 6. 下一步怎么做，做到哪里才算成功

### 6.1 分阶段验收，不跨关宣称成功

| 阶段 | 动作 | 通过标准 | 当前状态 |
| --- | --- | --- | --- |
| A：合法创建 | 获取匹配授权，运行创建探针 | 应用能运行，公开 CoreHID 初始化成功 | 未通过 |
| B：无输入检查 | 激活自己的设备，读回描述符／usage／elements，做 1 秒超时 Feature Get | 自有设备枚举与读回匹配，Feature 返回正确；包括清理在内 Input 报告为 0 | 检查已实现，尚未取得实际成功结果 |
| C：原生本机触摸 | 隔离桌面上执行一指滚动、双指 pinch、最终触点释放 | 4 个真实 direct-touch 生命周期；位置／阶段对应；滚动与原生缩放响应；无残留触点 | 序列与接收器已实现，未实发 |
| D：显示器关联 | 非主屏、负原点、HiDPI、Vela 虚拟屏等验证 | 触摸确实落在选中显示器，变化／移除后恢复正确 | 未验证 |
| E：远程产品集成 | 原始触点协议接入认证连接，处理断线、乱序与会话变化 | 单控制端认证、终止触点可靠、无双重手势解释、不误判物理输入 | 尚未接入 |

点击、长按、更多第三方应用、设备移除与混合物理输入等完整兼容性测试，仍需在最低滚动／缩放验收通过后补充。

### 6.2 当前建议

1. **保留独立原型，先申请 Virtual HID 授权。** 不替换正式 Vela 的证书和兼容标识。
2. **原生接收和显示器关联通过前，不扩建远程触点功能。** 保留现有认证鼠标／滚动路径，避免投入后才发现平台不支持。
3. 如果“绝不依赖 Mac 虚拟 HID 授权”是硬要求，另立 USB 硬件代理原型；明确增加硬件与显示器绑定风险，不把它包装成纯软件方案。
4. 若得到 Apple 明确答复“第三方无法进入该原生路径”，将其作为产品边界，停止把模拟鼠标称为原生触摸。

### 6.3 实发安全边界

HID 报告是**系统级输入**，不是限定在测试窗口内的事件。显示器绑定若失效，第一触点就可能落到其他 UI；检查窗口是否聚焦不能预先保证落点。

因此实发必须使用隔离、非敏感桌面，且无其他物理输入。原型有焦点／会话／显示器／几何检查、触点释放与异步 watchdog，但这些尚未完成授权后实机验收；watchdog 也不是对同步主线程／内核停滞的独立保证。

## 附录 A：原型入口与复核命令

以下是复核入口，**本次报告整理没有执行它们**。创建探针与接收窗口分别不提交 HID 输入、或不创建设备。

```sh
swift build -c debug --product VelaTouchLab
swift test --filter TouchLabCoreTests
python3 -m unittest discover -s Tests/TouchLab -p 'test_*.py'

BIN_DIR="$(swift build -c debug --show-bin-path)"
"${BIN_DIR:?}/VelaTouchLab" --probe
"${BIN_DIR:?}/VelaTouchLab" --receiver-only --duration 3
```

取得合法授权后，先使用 `--activate-probe`；只有无输入检查通过，才在隔离桌面进入 `--run --isolated-desktop`。不要把采集脚本退出 0、窗口测试退出 0，与原生触摸成功混淆。

| 文件／入口 | 用途 |
| --- | --- |
| [VelaTouchLab 入口](<../Sources/VelaTouchLab/main.swift>) | 四种独立模式及阶段验收／安全检查 |
| [虚拟设备与无输入读回](<../Sources/VelaTouchLab/VirtualTouchscreen.swift>) | CoreHID、签名声明检查、Feature 请求、无输入清理 |
| [AppKit 接收器](<../Sources/VelaTouchLab/TouchReceiver.swift>) | 真实 direct-touch 生命周期、标准滚动与原生 pinch |
| [HID 报告编码](<../Sources/TouchLabCore/TouchscreenReport.swift>) | 双触点描述符、位置边界、释放与 Feature 格式 |
| [独立签名打包工具](<../scripts/build-touch-lab.py>) | 现有固定证书、独立 UUID 目录、拒绝 ad-hoc fallback |
| [无输入签名探针采集器](<../scripts/probe-signed-touch-lab.py>) | 捕获正常退出或 SIGKILL；不接受实发模式 |
| [当前验证说明](<../TESTING.txt>) | 完整命令、模式及退出码解释 |
| [entitlement 示例](<vela-corehid-touch-entitlements.example.plist>) | 参考声明；不是授权 profile，不改变生产签名 |

## 附录 B：证据与历史报告索引

### 优先复核的本机证据

| 证据 | 内容 |
| --- | --- |
| [完整匹配签名对照](<vela-corehid-touch-signed-comparison-2026-11-06.json>) | 主证据：同构建、同配置，签名／运行哈希与 -413 对应关系 |
| [控制组实际运行](<vela-corehid-touch-control-runtime-2026-11-06.json>) | 正常退出、初始化 nil、Input 报告 0 |
| [声明 entitlement 的实际运行](<vela-corehid-touch-entitled-runtime-2026-11-06.json>) | 非采集器超时所致的 SIGKILL，无内部探针 JSON |
| [精确应用对应 AMFI 日志](<vela-corehid-touch-matched-security-2026-11-06.json>) | `AppleMobileFileIntegrityError -413 / No matching profile found` |
| [接收窗口冒烟](<vela-corehid-touch-receiver-2026-11-06.json>) | 窗口配置通过；无原生触摸接受结果 |
| [最初 CoreHID 创建探针](<vela-corehid-touch-probe-2026-11-06.json>) | 未持有必要声明、初始化 nil、无激活和输入报告 |

### 分阶段报告

- [11 月 4 日：接口、Sidecar 与公开路线调查](<vela-native-touch-research-2026-11-04.md>)。
- [11 月 6 日：最小原型与首次权限检查](<vela-corehid-touch-prototype-2026-11-06.md>)。
- [11 月 6 日：固定证书签名对照与 profile 拒绝](<vela-corehid-touch-signed-validation-2026-11-06.md>)。
- [11 月 6 日：社区方案、申请入口与硬件替代](<vela-corehid-touch-community-options-2026-11-06.md>)。

### 补充／较早证据（不优先于完整匹配对照）

- [早期系统接口探针](<vela-native-touch-probe-2026-11-04.json>)。
- [早期签名拒绝日志提取](<vela-corehid-touch-signing-denial-2026-11-06.json>)。
- [扩大范围的脱敏安全日志](<vela-corehid-touch-security-details-2026-11-06.json>)。
- [较早固定证书控制组](<vela-corehid-touch-signed-control-2026-11-06.json>)。

## 附录 C：关键公开来源与证据等级

| 来源 | 作用／限制 |
| --- | --- |
| [Apple CoreHID 虚拟设备 API](https://developer.apple.com/documentation/corehid/creatingvirtualdevices) | 公开 API 能力说明，不证明 Vela 获得授权或原生触摸识别 |
| [Apple HID entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.hid.virtual.device) | exact key 与 Boolean 类型；未完整列出申请／分发流程 |
| [Apple TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles) | macOS 受限 entitlement 的 profile allowlist 机制 |
| [Apple TN3212](https://developer.apple.com/documentation/technotes/tn3212-adopting-gesture-recognizers-for-sidecar-touch-support) | 通过手势识别器观察直接触摸，普通事件监听不是正确验收手段 |
| [Stack Overflow 相同错误回答](https://stackoverflow.com/a/79840890) | 社区已接受的申请入口线索；不是 Vela 的获批结果 |
| [Topti 授权调查](https://github.com/Yukaii/topti/blob/main/docs/investigations/2026-04-02-corehid-entitlement.md) | 近似 digitizer 项目申请等待记录；不是原生触摸成功 |
| [Karabiner 驱动](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/blob/55b60bd86f0fb57119ae1730fce9ba1e11f892c0/README.md) | 可参考的签名键鼠驱动，不提供原型所需任意触摸屏接口 |
| [同版 macOS 外接触屏实验](https://github.com/glasses666/macos27-external-touch/blob/main/EVIDENCE.md) | 社区显示器关联失败反例；未本机复现 |

**报告口径统一：已实现 ≠ 已运行；已签名 ≠ 已授权；已枚举 ≠ 已原生触摸；社区说法 ≠ 本机验证。**
