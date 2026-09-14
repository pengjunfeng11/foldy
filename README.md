# Foldy 0.4.7

Foldy 是一个 macOS 菜单栏应用：读取 MacBook 的屏幕开合角度，让实时桌面随合盖产生透视、渐变模糊和明暗变化，也可以在合盖时触发脚本或发送飞书通知。

使用 Swift、AppKit、SwiftUI、ScreenCaptureKit 和 Metal 实现。参考 [Bendy](https://trybendy.app/) 与 [iphone-duo](https://github.com/chuspeeism/iphone-duo)，非官方版本。

## 下载与安装

**[下载 Foldy 0.4.7 DMG（Apple Silicon）](https://github.com/pengjunfeng11/foldy/releases/download/v0.4.7/Foldy-0.4.7-macOS-arm64.dmg)** · [发行说明与 SHA-256 校验文件](https://github.com/pengjunfeng11/foldy/releases/tag/v0.4.7)

需要 macOS 14 或更新版本及 Apple Silicon MacBook。下载后打开 DMG，将 Foldy 拖到「Applications」，再从「应用程序」打开；使用安装包无需安装 Xcode 或自行编译。真实开合效果取决于机型是否提供铰链角度传感器。

这是预览版本，采用 ad-hoc 签名，尚未经过 Apple 公证。若 macOS 拦截打开，请先确认下载来源，再按 [Apple 的应用打开说明](https://support.apple.com/en-lamr/102445) 在「系统设置 → 隐私与安全性」为此应用选择「仍要打开」。首次使用桌面效果需要录屏许可；飞书通知和任务守护为可选功能，需各自完成账号连接或管理员授权。

## 环境与构建

- Apple Silicon、macOS 14 或更新版本。
- 真实开合控制需要可读取铰链角度的 MacBook；其他机型的传感器兼容性需实测。
- 安装 Xcode Command Line Tools。应用使用系统 SDK，无第三方 Swift 依赖；飞书连接会另行安装所需 CLI 和 Python 运行环境。

```sh
bash build.sh
open .build/Foldy.app
```

构建产物为 `.build/Foldy.app`，构建脚本同时运行基础自检。日常使用可退出旧版后，将完整应用复制到「应用程序」。不要覆盖或重新签名正在运行的应用。

## 桌面效果

1. 打开 Foldy，点击「开启桌面效果」，在 macOS 系统设置中允许屏幕录制，然后退出并重新打开应用。
2. 将屏幕打开到日常使用的位置，点击「用当前开度校准恢复位置」。
3. 调整透视、模糊、阴影与「动画顺滑度」。更高的顺滑度会缓和角度跳变，也会增加跟随过渡时间。

支持 Silk、Shade、Frost 三种样式。关闭「跟随屏幕」可手动预览角度；实际桌面效果仍跟随真实铰链。菜单栏可暂停或退出，设置窗口中可用 Esc 暂停、⌘Q 退出。

桌面变形需要读取实时画面，只作用于内建屏幕，不捕获声音，不保存或上传桌面帧。动画由显示时钟独立驱动；隐藏效果时停止纹理准备和重复绘制，但系统捕获连接仍可能保留。帧率和延迟取决于硬件及系统负载，不保证所有环境达到参考视频的表现。

当前构建采用 ad-hoc 签名，尚非 Apple 公证发行包。更新后二进制签名变化，macOS 可能仍保留旧版录屏授权，导致开关已打开却捕获失败。请先退出所有 Foldy 进程，在系统设置中为实际使用的新版应用重新授权，再打开它；系统可能要求 Touch ID 或密码。界面仅在收到真实桌面帧后显示捕获成功。

## 合盖动作

在「合盖动作」中启用功能。默认降至 20° 触发一次，打开到 60° 以上后重新就绪；触发角度可调。这些动作不依赖桌面效果或录屏权限。

**自定义脚本**：选择可执行脚本，合盖时会收到 `close` 参数及 `BENDY_EVENT`、`BENDY_EVENT_ID`、`BENDY_ANGLE` 环境变量。脚本在后台执行，最长 30 秒。仅启用合盖脚本不会阻止系统休眠，快速合盖可能中断执行。

**飞书通知**：点击「安装并连接飞书」，按界面完成官方 CLI 安装及飞书授权。没有现成 Bot 时使用官方应用创建向导；新用户需要登录自己的账号，并受所在组织的应用与权限策略约束。连接会绑定当前登录者作为收件人，源码和安装包不包含开发者账号或密钥。

通知包含 Codex 任务与额度摘要。任务状态来自本机 Hook 和回合元数据，不读取聊天正文，不调用模型生成摘要；缺失、陈旧或不兼容的数据会显示未知。额度不可用时也不会当作零额度。未发送成功的合盖事件可在开盖或下次启动时重试，结果不确定且超过幂等窗口时保留待核对，避免盲目重发。首次新账号从授权到通知送达仍需实际验收。

为兼容早期 Bendy Replica 配置，内部 bundle ID、可执行文件名与 `BENDY_*` 环境变量保留旧标识。飞书账号配置、Hook 状态及待发队列只保存在使用者本机，不应提交到源码仓库。

## 任务守护

「任务守护：有任务时合盖继续运行」每 5 秒在后台检查本机 Codex 任务。检测到运行中的任务后，由系统助手执行固定命令 `pmset -a disablesleep 1`，提前防止合盖打断任务；等待人工输入或授权的任务不算正在运行。

首次点击「安装并授权任务守护」需要本人完成 macOS 管理员验证。助手只提供守护续期、恢复和状态查询，不接受任意管理员命令；它绑定当前用户与应用代码签名，更新签名后可能需要重新安装授权。

- 任务结束、关闭功能、退出应用或达到最长守护时间后，恢复开始前的休眠设置。
- 默认最长 30 分钟，可调 5–120 分钟；可选择仅接通电源时守护。
- 原本已全局禁睡时，默认仍恢复到禁睡状态。只有显式勾选「安装时恢复正常休眠，由 Foldy 按任务管理」才将初始状态改回正常休眠。
- 助手保存恢复记录，并在连接断开、续期超时或服务重启后恢复；状态暂时不可读时最多保留 30 秒。异常退出可能遗留任务状态，因此仍受最长守护时间限制。

**验证范围**：任务判断、守护策略、安装校验和助手恢复逻辑已有离线检查；系统助手实机安装及真实合盖防休眠的完整验收尚未确认。构建或离线检查通过不代表此功能已经在某台电脑启用。

## 检查

基础、状态与配置检查：

```sh
.build/Foldy.app/Contents/MacOS/BendyReplica --self-test
python3 Scripts/bendy_hooks.py self-test
python3 Scripts/setup_check.py
python3 Scripts/guardian_check.py
python3 Scripts/guardian-install-check.py
```

守护策略与助手检查使用模拟系统设置，不更改真实休眠配置：

```sh
xcrun swiftc -DGUARDIAN_POLICY_CHECK Sources/TaskGuardian.swift Scripts/guardian-policy-check.swift -o /tmp/foldy-guardian-policy-check
/tmp/foldy-guardian-policy-check
xcrun swiftc -O -swift-version 5 Sources/GuardianProtocol.swift Sources/GuardianHelper.swift Scripts/guardian-helper-check.swift -o /tmp/foldy-guardian-helper-check
codesign --force --sign - /tmp/foldy-guardian-helper-check
/tmp/foldy-guardian-helper-check
```

图形与传感器检查需要图形会话和相应硬件；实时捕获检查会显示桌面效果并需要录屏许可：

```sh
.build/Foldy.app/Contents/MacOS/BendyReplica --render-test
.build/Foldy.app/Contents/MacOS/BendyReplica --idle-render-test
.build/Foldy.app/Contents/MacOS/BendyReplica --capture-demand-test
.build/Foldy.app/Contents/MacOS/BendyReplica --capture-texture-test
.build/Foldy.app/Contents/MacOS/BendyReplica --sensor-test
.build/Foldy.app/Contents/MacOS/BendyReplica --tracking-test --full-screen
.build/Foldy.app/Contents/MacOS/BendyReplica --overlay-test --live-capture
```

## 源码与参考

- `Sources/Core.swift`、`Sources/Renderer.swift`：铰链传感器、运动插值、实时捕获与 Metal 渲染。
- `Sources/App.swift`、`Sources/Hooks.swift`：设置、菜单栏、桌面覆盖层及合盖事件。
- `Sources/TaskGuardian.swift`、`Sources/GuardianHelper.swift`：任务守护与系统助手。
- `Sources/FeishuConnection.swift`、`Scripts/foldy_setup.py`、`Scripts/bendy_hooks.py`：飞书连接、Codex 状态及通知。

投影、渐变模糊及暗化着色器改编自 [chuspeeism/iphone-duo](https://github.com/chuspeeism/iphone-duo)，保留其 MIT 声明于 [THIRD_PARTY_NOTICES](Assets/THIRD_PARTY_NOTICES.txt)。HID 协议参考 [LidAngle](https://github.com/deepakness/LidAngle) 和 [LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor)。不包含 Apple 模型或图片。
