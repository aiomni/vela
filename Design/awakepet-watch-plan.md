# AwakePet 智能值守与合盖运行

2026-10-28 更新：Agent 活跃判断现默认采用 `caffeinate` 子进程或最近约 60 秒进程树平均 CPU 达 2% 的规则，设置中可切换为进程存在即保活。下文 2026-10-19 的记录反映当时版本的策略与验收。

2026-10-28 更新：合盖模式同时持有显示器和系统断言，开盖时阻止空闲熄屏，合盖时仍按原方案保持系统运行。内置显示器合盖后由系统关闭；锁屏行为仍受系统与管理策略控制。

逐项证据和剩余验收见 [awakepet-watch-acceptance.md](awakepet-watch-acceptance.md)。

状态：Agent 自动值守、断言自检、低电量与热保护已实现。合盖模式按用户选择沿用 Bulchimbeon 的无常驻守护进程方案，以按次管理员授权和临时恢复监视运行。管理员实机检查已验证正常停止、主程序强制结束、心跳超时、授权取消、原值 1 与真实合盖后的运行和恢复；真实电源切换已验证电池事件触发的恢复路径。用户接受测试专用阈值与模拟热状态作为低电量、过热路径的验收证据；真实低电量和过热仍未实测。重启自动恢复不属于此方案的保证，见下方限制。

## 用户行为

- 手动模式默认保持显示器唤醒；Agent 自动值守默认允许显示器睡眠并保持系统运行。
- 保持方式由菜单栏和设置页共用同一持久选择，包括合盖模式。实际进入合盖值守时，macOS 弹出管理员授权。Agent 进入静默待命、低电量退出、过热暂停、故障或正常停止后恢复普通合盖睡眠；当前 Agent 值守不会自行再次进入合盖，重新开启值守时才会再次请求授权。
- 登录启动不恢复合盖值守。定时手动模式需要输入监控权限；Agent 检测只查看当前用户的本机进程。
- 当前默认要求 `caffeinate` 子进程或最近约 60 秒进程树平均 CPU 不低于 2%；无工具 headless 会话不计入。首次 CPU 判定需累积 60 秒采样，`caffeinate` 子进程则立即生效。设置中可改为进程存在即保活，以覆盖低 CPU 的远端等待；在此模式下常驻后台 Agent 会持续保活。
- `PreventUserIdleDisplaySleep` 对应显示器模式；`PreventUserIdleSystemSleep` 对应系统模式。合盖模式同时持有两种断言，另用 `pmset -a disablesleep 1` 阻止合盖睡眠。

## 临时管理员命令

`Sources/AwakePet/LidServiceClient.swift` 读取 `pmset -g` 的 `SleepDisabled`。若原值为 1，AwakePet 不修改它。若原值为 0，则通过 `/usr/bin/osascript` 的 `with administrator privileges` 执行固定命令。root 监视进程先脱离授权进程组，再执行 `pmset -a disablesleep 1`，成功后才向主程序报告 PID。命令的变量仅有本进程 PID、程序生成的 UUID 路径和固定的 30 秒租约时长；不运行用户可编辑的脚本文件。主程序约每 5 秒原子更新单调时钟租约；监视进程每 2 秒检查主进程 PID、创建时间、会话目录和租约新鲜度，避免 PID 重用或应用卡住延长会话。值守结束删除该目录；应用崩溃、无心跳超过 30 秒时监视进程恢复 `pmset -a disablesleep 0`。正常停止等待回读确认；失败时再次请求管理员授权恢复，并在下次启动提示检查。

主程序记录监视进程的 PID、启动时间和带有会话目录的命令行；每次心跳核对同一进程且排除僵尸状态，以免 PID 被重用后误判为仍受保护。管理员授权命令由应用跟踪；退出时若授权弹窗尚未结束，终止对应的 `osascript` 子进程。

主程序异常退出或租约超时后，监视进程恢复 `SleepDisabled=0`，再移除会话的 `lease` 文件及空目录。测试覆盖了父进程退出和心跳超时后的目录清理。

若完整应用退出时授权或合盖恢复操作仍在进行，退出流程终止待授权子进程后再回读 `SleepDisabled`，最多等待 5 秒确认普通睡眠恢复。仅在未确认时留下下次启动警告，避免用户取消或尚未批准授权时出现误报。

主程序每 5 秒确认 `SleepDisabled` 和监视进程仍在；失效即停止宣称合盖保护有效，并退出本次值守。退出应用时等待合盖恢复。低电量和危急过热先于 Agent 扫描及合盖心跳进入状态机；扫描进行中出现安全事件时也可抢先释放，旧扫描结果不能重新开启会话。两条路径共用释放与恢复动作。

电源信息变化由 `IOPSNotificationCreateRunLoopSource` 直接触发安全检查；5 秒值守定时器同时提供兜底。热状态变化由 `ProcessInfo.thermalStateDidChangeNotification` 触发，并由同一定时器兜底。电源回调运行在主线程，退出时移除通知源。

若临时 root 监视进程本身崩溃而主程序继续运行，下一次心跳会检测到失效，停止值守并尝试重新取得管理员授权以恢复睡眠。没有常驻特权服务时，监视进程崩溃且主程序或授权流程也不可用的组合故障无法保证自动恢复；此时需要管理员按下述命令检查和恢复。该限制与重启限制一样，不应描述为已达到特权 helper 崩溃时的无条件恢复保证。

## 打包

`scripts/build-app.sh` 默认用 `codesign --sign - --options runtime --timestamp=none` 签署单个 `.app`。`SIGNING_IDENTITY` 可为 AwakePet 指定有效证书；原本给 LockLab 用的 `.signing-identity.local` 不影响 AwakePet。包中没有 LaunchDaemon 或特权 helper。ad-hoc 签名没有 Apple 公证，首次打开可能需要用户在系统设置中允许。

## 重启限制

`pmset` 手册说明设置保存在系统级持久偏好中。临时 root 恢复监视进程在重启时终止，不能保证重启后、登录前恢复 `SleepDisabled`。用户明确选择维持 Bulchimbeon 式的无常驻守护进程方案，不安装开机恢复任务。因此若合盖值守期间重启或断电，开机后必须先运行 `pmset -g` 检查 `SleepDisabled`；若仍为 1，由管理员运行 `sudo pmset -a disablesleep 0`，确认回读为 0，再按普通合盖睡眠使用机器。程序正常退出、崩溃和心跳超时的恢复保证不延伸到重启后的登录前阶段。

## 验收

自动检查：`swift build -c release --product AwakePet`、`AwakePet --self-test`、`AwakePet --watch-policy-test`、打包后 `codesign --verify --deep --strict`。`--self-test` 回归手动唤醒、空闲计时、快捷键和桌宠等既有行为；值守检查用非特权假 `pmset` 执行真实监视命令，验证停止、父进程退出与心跳超时后恢复、持续心跳时保持会话、异常退出后清理会话目录，以及开启命令失败或授权完成前主程序已不存在时拒绝修改设置。

`AwakePet --power-safety-sample` 只读当前 IOKit 电池来源和系统热状态，可与 `pmset -g batt` 对照；当前电量正常不等于已验证低电量退出，当前热状态正常也不等于已验证过热暂停。

`AwakePet --diagnose-watch-live` 对当前用户的 Agent 进程间隔 60 秒采样，输出名称、PID、匹配依据及 CPU 活动，不输出完整命令行。

管理员实机检查已覆盖授权取消、原值 0 和 1、正常停止、`kill -9` 主程序、授权弹窗打开时退出、外部改动 `SleepDisabled` 与真实合盖运行。低电量按用户接受的真实电源切换加测试阈值验收；过热按注入危急热状态加状态机冷却计时验收。这些测试没有制造真实低电量、真实系统过热，也不证明任何网络或远端任务在合盖后持续可用。重启后的设置按上述限制检查，不视为自动恢复测试。

`scripts/verify-lid-live.sh` 要求基线 `SleepDisabled=0`，通过 `--lid-live-test` 运行实际授权命令，检查正常停止、`kill -9` 后 12 秒内恢复，以及停止心跳后 40 秒内恢复并确认新建的会话目录消失。`--timeout-only` 只运行最后一轮；`--cancel-only` 在用户取消管理员弹窗后检查未改变设置；`--pending-auth-only` 在管理员弹窗保持打开时让客户端主动退出授权等待并检查清理；`--preexisting-only` 临时置 1，验证 AwakePet 不覆盖原值后恢复测试前的 0；`--battery-only` 用仅限测试的 100% 阈值，在真实 AC 转电池事件后驱动 `DutyEngine` 释放断言并恢复合盖睡眠；`--thermal-only` 注入测试专用的危急热状态，检查相同的断言及合盖恢复链路；`--external-only` 从测试脚本外部恢复 `SleepDisabled=0`，检查应用心跳发现保护失效并退出。脚本保留日志，并在失败或中断时尝试管理员授权恢复。运行前需退出普通 AwakePet 实例，且有人在桌面完成系统管理员弹窗。测试用阈值和模拟热状态不修改用户偏好；用户已接受它们作为本次验收替代场景，不代表真实低电量或过热实测。

2026-10-19 实机记录：在管理员授权后，正常停止检查记录 `LID_READY` 与 `LID_RESTORED`，并回读 `SleepDisabled=0`；强制结束检查记录 `LID_READY`，`kill -9` 后 12 秒内回读 `SleepDisabled=0`。脚本退出码为 0，日志在 `.build/lid-live-check-20261019-135622/`。测试结束后没有 AwakePet 进程，系统值仍为 0。

2026-10-19 真实合盖记录：从 `dist/AwakePet.app` 手动启用合盖模式并批准管理员弹窗，确认 `SleepDisabled=1`、AwakePet 持有 `PreventUserIdleSystemSleep`、root 恢复监视进程在运行。合盖期间 `ioreg` 报 `AppleClamshellState=Yes`，`.build/lid-physical-20261019-1407.log` 以约 2 秒间隔连续记录 90 秒的主进程与设置状态；用户开盖后确认机器继续运行。正常退出后回读 `SleepDisabled=0`，无残留 AwakePet 或监视进程。测试前 60 分钟保持时长曾临时设为无限以避开输入监控授权差异，结束后已恢复 60 分钟。

2026-10-19 心跳超时实机记录：运行 `scripts/verify-lid-live.sh --timeout-only`，管理员授权后记录 `LID_READY` 并回读 `SleepDisabled=1`；测试程序保留主进程但不刷新租约，40 秒内由 root 监视进程恢复 `SleepDisabled=0`。脚本退出码为 0，日志在 `.build/lid-live-check-20261019-142125/`；结束后无残留 AwakePet 或监视进程。

2026-10-19 电源接口只读核对：本机 `pmset -g batt` 显示外接电源、内置电池 100%；`AwakePet --power-safety-sample` 从 IOKit 读取 `percent=100 onBattery=false`，热状态为 `nominal`，与系统当前状态一致。这只验证了正常状态的数据读取，尚未验证低电量或过热时的真实回调与恢复。

2026-10-19 授权取消尝试：`scripts/verify-lid-live.sh --cancel-only` 的日志 `.build/lid-live-check-20261019-144415/cancel.log` 已出现 `LID_READY`，因此本次授权在取消检查前已完成，可能沿用了系统缓存，不能算取消路径通过。脚本终止测试进程后，root 恢复监视将 `SleepDisabled` 恢复为 0，无残留进程。需在系统实际显示新的合盖授权弹窗时重试。

2026-10-19 授权取消复查：用户在合盖启用管理员弹窗中点“取消”，`scripts/verify-lid-live.sh --cancel-only` 记录 `LID_OPEN_FAILED`，退出码为 0；前后 `SleepDisabled=0`，没有残留 AwakePet 或恢复监视进程。日志在 `.build/lid-live-check-20261019-144754/cancel.log`。

2026-10-19 Agent 实际采样：`--diagnose-watch-live` 找到 5 个 Codex 进程，6 秒窗口的最高 CPU 为 1.6%，旧的 2% 阈值将它们判为空闲。这一结果证明本机进程读取和 CPU 差值计算工作正常，也说明仅凭 CPU 无法确认远端等待中的任务是否仍在进行。用户随后明确选择优先保活，策略改为进程存在即保持运行；CPU 数值保留在诊断中。

2026-10-19 原值 1 实机检查：`scripts/verify-lid-live.sh --preexisting-only` 临时把 `SleepDisabled` 设为 1；AwakePet 输出 `LID_READY` 和 `LID_RESTORED`，开启与结束后回读均维持 1。脚本随后恢复测试前的 0，退出码 0，日志在 `.build/lid-live-check-20261019-145358/preexisting.log`；无残留进程。

2026-10-19 电池事件实机检查：在接电源且 `SleepDisabled=0` 时运行 `scripts/verify-lid-live.sh --battery-only`，批准合盖会话后读取到 `SleepDisabled=1`；用户拔掉电源，IOKit 查询报电池供电、100%，测试专用阈值 100% 使 `DutyEngine` 输出释放断言及恢复合盖设置，日志记录 `LID_BATTERY_RESTORED percent=100`。脚本退出码 0，日志在 `.build/lid-live-check-20261019-145831/battery.log`；随后系统回读 `SleepDisabled=0`、无残留进程，用户重新接回电源。该版本测试通过轮询读取 IOKit，没有验证新增的电源通知回调；回调版实机检查待运行。该结果也未验证电量降至产品阈值 10–50% 的场景。

2026-10-19 热暂停恢复链路检查：运行 `scripts/verify-lid-live.sh --thermal-only`，在已启用合盖设置和系统断言的测试进程中注入危急热状态，`DutyEngine` 输出释放与恢复效果，日志记录 `LID_THERMAL_RESTORED`。脚本退出码 0，日志在 `.build/lid-live-check-20261019-150208/thermal.log`；`SleepDisabled=0`，无残留进程。系统并未真实过热，这不能证明真实热状态通知或冷却恢复的运行时表现。

2026-10-19 外部设置修改检查：运行 `scripts/verify-lid-live.sh --external-only`，启动合盖会话并回读 `SleepDisabled=1` 后，由测试脚本单独执行 `pmset -a disablesleep 0`。应用心跳检测到设置失效，日志记录 `LID_EXTERNAL_STOPPED`；脚本退出码 0，日志在 `.build/lid-live-check-20261019-150717/external.log`，结束后 `SleepDisabled=0`、无残留进程。

2026-10-19 监视进程身份核对后的心跳超时复查：从最新签名包运行 `scripts/verify-lid-live.sh --timeout-only`，记录 `LID_READY pid=79370`，停发心跳后脚本在 40 秒内确认 `SleepDisabled=0`，退出码 0；日志在 `.build/lid-live-check-20261019-151704/timeout.log`。结束后无残留测试进程或授权子进程。最新签名包的 `--watch-policy-test` 通过，`codesign --verify --deep --strict` 通过。

2026-10-19 待授权客户端清理检查：用户保持管理员弹窗打开，运行 `scripts/verify-lid-live.sh --pending-auth-only`。客户端记录 `LID_PENDING_AUTH_READY`，8 秒后调用与应用退出共用的 `LidServiceClient.disconnect()`，终止 `osascript` 授权子进程并记录 `LID_PENDING_AUTH_CLEANED`；脚本退出码 0，日志在 `.build/lid-live-check-20261019-152302/pending-auth.log`。检查后 `SleepDisabled=0`，无残留 AwakePet、监视进程或授权子进程；重新打包后的 `--watch-policy-test`、`--self-test` 与签名校验通过。该测试覆盖客户端清理路径，尚未覆盖完整应用菜单退出流程。

2026-10-19 完整应用待授权退出检查：用户将保持时长临时改为无限、从菜单栏开启合盖值守，并保持管理员弹窗未操作。进程 `82773` 的 `osascript` 子进程 `84358` 存在且 `SleepDisabled=0`；通过应用菜单“退出 AwakePet”后约 8 秒，两进程均结束、`SleepDisabled=0`。重新打开应用时却出现“未能确认恢复”警告，属于误报；已改为退出时主动回读设置后才决定是否留警告。

2026-10-19 修复后的客户端清理复查：`--pending-auth-only` 通过，记录 `LID_PENDING_AUTH_READY` 与 `LID_PENDING_AUTH_CLEANED`，`SleepDisabled=0`，无残留进程；日志在 `.build/lid-live-check-20261019-153923/pending-auth.log`。包含连续 120 秒冷却计时重置检查的 `--watch-policy-test` 通过。

2026-10-19 完整应用误报复查：从最新签名包打开 AwakePet，用户将保持时长设为无限并在合盖授权弹窗中保持不操作。应用 PID `85895` 与授权子进程 PID `85923` 运行时 `SleepDisabled=0`；通过应用菜单退出后两进程均消失，设置仍为 0。重新打开应用时直接显示桌宠，没有恢复警告。测试后从设置窗口将保持时长恢复为 1 小时（偏好值 60），退出应用并再次确认无残留进程、`SleepDisabled=0`。最新签名包 `--watch-policy-test` 与 `codesign --verify --deep --strict` 通过；`--self-test` 的非画面项目通过，当前桌面遮挡使实时画面项目未判定，先前可见桌面检查曾通过。

2026-10-19 会话目录清理：审查发现监视进程恢复设置后直接 `rmdir`，但目录中的 `lease` 文件使删除失败。本机 `/tmp` 留有五个旧测试目录，内均仅有 `lease`，且无合盖或授权进程、`SleepDisabled=0`；已清除。监视命令现先删除 `lease` 再删除目录；`--watch-policy-test` 新增父进程退出和心跳超时后目录消失的检查并通过，最新包重新签署。

2026-10-19 电源通知回调实机检查：新增 `IOPSNotificationCreateRunLoopSource`，应用在电源变化时立即执行安全检查，仍保留 5 秒轮询兜底。测试命令 `scripts/verify-lid-live.sh --battery-only` 改为仅凭该回调识别 AC 转电池；用户批准管理员授权并拔电后，日志记录 `LID_BATTERY_READY pid=91472` 与 `LID_BATTERY_RESTORED percent=100`，脚本退出码 0，日志在 `.build/lid-live-check-20261019-160452/battery.log`。`SleepDisabled=0`、无残留进程，用户随后重新接回电源，`pmset -g batt` 回到 AC Power。最新包的 `--watch-policy-test`、完整 `--self-test` 和签名校验通过。测试阈值仍为仅限测试的 100%，不等于真实低电量验收。

2026-10-19 临时目录清理实机复查：从最新签名包运行 `scripts/verify-lid-live.sh --timeout-only`，用户批准管理员弹窗后日志记录 `LID_READY pid=91787`；心跳超时后脚本在 40 秒内确认 `SleepDisabled=0`，并确认新建的 `/private/tmp/awakepet-lid-501-*` 会话目录已消失。脚本退出码 0，日志在 `.build/lid-live-check-20261019-160606/timeout.log`。测试结束后仍为 AC Power、`SleepDisabled=0`，无残留 AwakePet、授权或监视进程。

参考：[Bulchimbeon 构建脚本](https://github.com/s3onghyun/bulchimbeon/blob/main/scripts/build-app.sh)、[合盖安全说明](https://github.com/s3onghyun/bulchimbeon/blob/main/SECURITY.md)。
