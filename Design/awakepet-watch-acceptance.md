# AwakePet 值守验收对照

2026-10-28 更新：Agent 活跃判断改为默认按工作活动保活，设置可切换为进程存在即保活。原 2026-10-19 的实机记录仍反映当时策略；新规则的长时间真实 Agent 场景尚需实机观察。

2026-10-28 复核：`dist/AwakePet.app` 的 `--watch-policy-test`、`--self-test` 与打包脚本的签名校验均通过；最新自检中的跨进程窗口遮挡检查也通过。

2026-10-28 合盖模式更新：现同时持有显示器与系统断言，开盖时阻止空闲熄屏；`--watch-policy-test` 已验证创建、重复开启、切换模式与释放。原先的真实合盖验收发生在仅持有系统断言的版本，新组合尚未再次做真实合盖检查。

更新于 2026-10-19。实现与完整测试经过见 [awakepet-watch-plan.md](awakepet-watch-plan.md)。用户确认以无常驻服务方案交付，并接受阈值注入与真实电源切换作为低电量、过热路径的验收证据。本文件区分已验证的行为、测试替代场景和方案限制，供代码审阅使用。

| 目标 | 当前证据 | 结论 |
| --- | --- | --- |
| 保留手动唤醒、空闲计时、快捷键、桌宠 | `Sources/AwakePet/App.swift` 仍保留原有入口；最新签名包 `--self-test` 包含断言、输入、快捷键、桌宠和菜单回归，退出码 0 | 已验证 |
| Agent 自动值守、静默宽限、脱敏诊断 | `DutyEngine.swift`、`AgentMonitor.swift`；`--watch-policy-test` 覆盖进程匹配、PID 重用、60 秒 CPU 采样、`caffeinate`、headless 过滤与宽限；实机 `--diagnose-watch-live` 曾找到本机 Codex 进程 | 默认按工作活动保活；设置可切换为进程存在即保活。新规则的真实长时间 Agent 工作场景尚需实机观察 |
| 显示器与系统断言 | `PowerController.swift` 使用对应 IOKit 断言；合盖模式同时持有两种断言。`--watch-policy-test` 检查类型、实际存在、重复开启、模式切换及释放 | 自动检查通过；真实合盖复查待做 |
| 低电量退出 | `DutyEngine.swift` 的电池阈值分支先于 Agent 扫描；`PowerSafetyMonitor.swift` 读取 IOKit 并注册电源通知；`--battery-only` 在真实 AC 转电池事件和测试专用 100% 阈值下释放断言、恢复 `SleepDisabled=0`，见 `.build/lid-live-check-20261019-160452/battery.log` | 按用户接受的替代场景验收通过；产品阈值 10–50% 的真实低电量状态未实测 |
| 过热暂停与稳定冷却恢复 | `DutyEngine.swift` 在 critical 释放断言与合盖设置，连续 120 秒降至 fair 或以下后仅恢复普通系统值守；`--watch-policy-test` 验证计时被 serious 打断后重置；`--thermal-only` 在模拟 critical 下实机恢复设置，见 `.build/lid-live-check-20261019-150208/thermal.log` | 按用户接受的注入测试验收通过；真实热状态变化及冷却回调未实测 |
| 菜单栏与桌宠状态表达 | `App.swift` 按 `DutyPhase` 更新菜单、图标、提示及宠物热状态；`serious` 热状态变化时立即更新菜单详情、状态图标提示和辅助功能名称。设置页现嵌入保持方式与 Agent 值守配置，桌宠操作栏有独立的 Agent 开关；菜单栏移除快捷键设置和诊断入口。`--self-test` 验证设置回调、开关状态及菜单布局 | 新界面回归通过；热状态仍未逐一做视觉验收 |
| 显式合盖保持运行 | 菜单选项启用后请求管理员授权；真实合盖保持运行 90 秒，开盖后确认继续运行，见 `.build/lid-physical-20261019-1407.log` | 已验证当前机器与系统配置 |
| 原值保护与正常停止 | `LidServiceClient.swift` 对原值 1 不修改；`--preexisting-only`、完整应用退出与 `--lid-live-test` 实测恢复，见 `awakepet-watch-plan.md` | 已验证 |
| 主程序异常退出和心跳超时 | 临时 root 监视进程使用单调时钟租约、主程序 PID 和启动时间；`kill -9` 与最新 `--timeout-only` 实测恢复。超时检查同时确认会话目录消失，见 `.build/lid-live-check-20261019-160606/timeout.log` | 已验证 |
| 授权取消、待授权退出、外部改动 | `--cancel-only`、`--pending-auth-only`、完整应用菜单退出和 `--external-only` 的实机记录见主计划 | 已验证 |
| 打包与签名 | `scripts/build-app.sh` 支持 `SIGNING_IDENTITY`；当前 `dist/AwakePet.app` 为 ad-hoc 签名，`codesign --verify --deep --strict` 通过。2026-10-19 查询本机签名钥匙串：`security find-identity -v -p codesigning` 返回 `0 valid identities found` | 已验证包完整性；本机目前无法执行证书签名或公证 |

## 已选择的方案限制

用户选择沿用 Bulchimbeon 式的无常驻守护进程方案。当前包没有受签名和调用者校验保护的特权 helper，也不安装开机恢复任务。`pmset` 设置具有持久性，因此值守中重启或断电后无法保证登录前恢复普通合盖睡眠。临时监视进程崩溃且主程序或管理员授权不可用时，也无法保证自动恢复。这两项不满足最初目标中的无条件恢复要求，必须按 [使用说明](../USAGE.txt) 检查 `SleepDisabled` 并由管理员恢复。

## 已接受的验收边界

1. 低电量使用测试专用 100% 阈值加真实 AC 转电池事件验证通知和恢复链路；没有让机器实际耗电至产品阈值。
2. 过热使用注入的 critical 状态验证断言与合盖恢复，使用纯逻辑状态机测试连续 120 秒稳定冷却；没有人为使机器过热。
3. 无常驻服务设计不提供重启后登录前或监视进程与主程序同时失效时的自动恢复保证。此限制由用户接受；若将来需要该保证，须另行设计、签名并测试特权服务。

最终复核：最新 `dist/AwakePet.app` 的 `--self-test`、`--watch-policy-test`、`codesign --verify --deep --strict` 均退出码 0；`--power-safety-sample` 与 `pmset -g batt` 均报 AC Power、电池 100%、热状态 nominal。包为 ad-hoc 签名，本机没有有效证书签名身份。

最近一次现场核对：AC Power、电池 100%、`SleepDisabled=0`，没有 AwakePet、授权子进程、root 监视进程或残留合盖会话目录。
