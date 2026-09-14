import SwiftUI
import AppKit

final class Model: ObservableObject {
    @Published var settingsPage = "外观"
    let hooks = LidHooks()
    @Published var angle = 125.0
    @Published var manualAngle = 80.0
    @Published var followLid = true
    @Published var enabled = false
    @Published var starting = false
    var wantsEffect = false
    @Published var status = "桌面效果尚未开启"
    @Published var sensorStatus = "正在连接传感器"
    @Published var style = UserDefaults.standard.string(forKey: "style") ?? "Silk" { didSet { save(); refresh() } }
    @Published var smoothness = Model.setting("smoothness", fallback: 0.5) { didSet { save(); refresh() } }
    @Published var perspective = Model.setting("perspective", fallback: 1) { didSet { save(); refresh() } }
    @Published var blur = Model.setting("blur", fallback: 0.65) { didSet { save(); refresh() } }
    @Published var shadow = Model.setting("shadow", fallback: 0.4) { didSet { save(); refresh() } }
    @Published var clearAngle = Model.setting("clearAngle", fallback: 115) { didSet { save(); refresh() } }
    @Published var sound = UserDefaults.standard.bool(forKey: "sound")
    let sensor = LidSensor()
    let capture = DesktopCapture()
    let preview = DesktopRenderer()
    let overlayView = DesktopRenderer()
    var overlay: NSWindow?
    var displayID: CGDirectDisplayID?
    private var hadBend = false
    private var lastUIUpdate = 0.0
    private var sensorTimestamp: Date?
    private var watchdog: Timer?
    static func setting(_ key: String, fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    }
    init() {
        sensorStatus = sensor.status
        if let initial = sensor.readInitial() { angle = initial; sensorTimestamp = Date(); sensorStatus = "实时传感器 · \(Int(initial))°"; hooks.update(angle: initial) }
        sensor.onAngle = { [weak self] angle in
            guard let self else { return }
            self.hooks.update(angle: angle)
            let now = CACurrentMediaTime()
            if now - self.lastUIUpdate > 0.05 {
                if Int(self.angle) != Int(angle) { self.angle = angle }
                if self.sensorStatus != self.sensor.status { self.sensorStatus = self.sensor.status }
                self.lastUIUpdate = now
            }
            self.sensorTimestamp = Date()
            self.refresh()
        }
        // Built-in macOS wallpaper is only a preview until the user enables capture.
        if let url = NSWorkspace.shared.desktopImageURL(for: NSScreen.main!), let image = CIImage(contentsOf: url) {
            preview.frameImage = image
        }
        overlayView.liveAmount = { [weak self] _ in
            guard let self else { return 0 }
            return bendAmount(angle: self.sensor.latest.angle, clearAngle: self.clearAngle)
        }
        preview.liveAmount = { [weak self] _ in
            guard let self else { return 0 }
            let angle = self.followLid ? self.sensor.latest.angle : self.manualAngle
            return bendAmount(angle: angle, clearAngle: self.clearAngle)
        }
        overlayView.onSettled = { [weak self] in
            guard let self, self.overlayView.motion.settled(at: 0), self.overlayView.amount <= 0.00005 else { return }
            if self.overlay?.isVisible == true { self.hideOverlay() }
            if self.hadBend && self.sound { NSSound(named: "Pop")?.play() }
            self.hadBend = false
            self.refresh()
        }
        capture.onFrame = { [weak self] texture in
            guard let self else { return }
            self.preview.inputTexture = texture
            self.overlayView.inputTexture = texture
            if self.capture.frameCount == 1 {
                self.status = "已开启 · 已收到实时桌面画面，仅在本机处理"
            }
            if self.capture.frameCount == 1 || (self.overlayView.amount > 0.00005 && self.overlay?.isVisible != true) {
                self.refresh()
            }
        }
        capture.onError = { [weak self] message in
            self?.enabled = false
            self?.hideOverlay()
            self?.status = "桌面捕获中断：\(message)"
            Task { await self?.capture.stop() }
        }
        watchdog = .scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.enabled, let timestamp = self.sensorTimestamp, Date().timeIntervalSince(timestamp) > 5 {
                self.refresh()
                self.sensorStatus = "传感器数据已过期，已隐藏桌面效果"
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, notification.object as? NSWindow === self.preview.window else { return }
            // Event-based sensors may stay silent at rest; visibility must update capture demand itself.
            self.refresh()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            if self?.enabled == true { self?.pause(); self?.status = "显示器配置已变化，请重新开启" }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.hideOverlay() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.hooks.retryPending() }
    }
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(style, forKey: "style")
        defaults.set(smoothness, forKey: "smoothness")
        defaults.set(perspective, forKey: "perspective")
        defaults.set(blur, forKey: "blur")
        defaults.set(shadow, forKey: "shadow")
        defaults.set(clearAngle, forKey: "clearAngle")
    }
    func hideOverlay() {
        overlay?.orderOut(nil)
        overlayView.resetMotion()
        preview.presentationAllowed = true
    }
    func refresh() {
        let rawAngle = sensor.latest.angle
        let effective = followLid ? rawAngle : manualAngle
        let amount = bendAmount(angle: effective, clearAngle: clearAngle)
        for renderer in [preview, overlayView] {
            renderer.smoothness = smoothness
            renderer.perspective = perspective
            renderer.blur = blur
            renderer.shadowStrength = shadow
            renderer.style = style
        }
        // The manual slider affects the preview only; a live overlay always follows the hardware.
        let live = bendAmount(angle: rawAngle, clearAngle: clearAngle)
        overlayView.amount = live
        let fresh = sensorTimestamp.map { Date().timeIntervalSince($0) < 5 } ?? false
        let returning = overlay?.isVisible == true && !overlayView.motion.settled(at: 0)
        let wantsOverlay = enabled && fresh && (live > 0.00005 || returning)
        let previewVisible = preview.window?.isVisible == true && preview.window?.occlusionState.contains(.visible) == true && !preview.isHiddenOrHasHiddenAncestor
        // Demand precedes visibility and the first texture, so a hidden overlay can still start.
        capture.setNeedsFrames(wantsEffect && (starting || capture.frameCount == 0 || wantsOverlay || previewVisible))
        // A retained texture can be old after a long idle; show only after the latest raw frame is prepared.
        let showOverlay = wantsOverlay && capture.readyForDemand && overlayView.inputTexture != nil
        // The fullscreen effect covers the preview; do not let its drawable queue stall the display thread.
        preview.presentationAllowed = !(showOverlay && preview.window?.screen == overlay?.screen)
        preview.amount = amount
        preview.wake()
        if showOverlay {
            if overlay?.isVisible != true { overlay?.orderFrontRegardless(); overlayView.resumePresentation() }
            overlayView.wake()
            hadBend = true
        } else {
            if overlay?.isVisible == true { hideOverlay() }
            if !enabled || !fresh { hadBend = false }
        }
    }
    func start() {
        guard !enabled, !starting else { return }
        wantsEffect = true
        starting = true
        capture.setNeedsFrames(true)
        status = "正在连接桌面捕获…"
        Task { @MainActor in
            defer { starting = false }
            do {
                guard let screen = NSScreen.screens.first(where: { screen in
                    guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return false }
                    return CGDisplayIsBuiltin(id) != 0
                }), let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else {
                    status = "内建显示器当前未启用，请打开 MacBook 屏幕后重试。"; return
                }
                displayID = id
                let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.level = .floating
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
                panel.ignoresMouseEvents = true
                // Until Metal presents its first frame, leave the real desktop visible.
                panel.backgroundColor = .clear
                panel.isOpaque = false
                overlayView.layer?.isOpaque = false
                panel.hasShadow = false
                panel.contentView = overlayView
                panel.setFrame(screen.frame, display: true)
                overlay = panel
                try await capture.start(displayID: id)
                enabled = true
                status = capture.frameCount > 0 ? "已开启 · 已收到实时桌面画面，仅在本机处理" : "已连接 · 正在等待首帧桌面画面…"
                refresh()
            } catch {
                hideOverlay()
                let failure = error as NSError
                status = "桌面捕获失败（\(failure.domain)，\(failure.code)）。系统录屏开关已开启时，也可能是更新后的程序签名与已有授权记录不匹配。"
            }
        }
    }
    func pause() {
        wantsEffect = false
        enabled = false
        hideOverlay()
        hadBend = false
        status = "已暂停"
        starting = true
        Task { @MainActor in await capture.stop(); starting = false }
    }
}

struct MetalPreview: NSViewRepresentable {
    let renderer: DesktopRenderer
    func makeNSView(context: Context) -> DesktopRenderer { renderer }
    func updateNSView(_ nsView: DesktopRenderer, context: Context) { DispatchQueue.main.async { nsView.wake() } }
}
struct SettingsView: View {
    @ObservedObject var model: Model
    private var page: String { model.settingsPage }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32).accessibilityHidden(true)
                    Text("Foldy").font(.headline)
                }.padding(.bottom, 22)
                ForEach(["外观", "合盖动作", "通用", "关于"], id: \.self) { name in
                    Button { model.settingsPage = name } label: {
                        Label(name, systemImage: name == "外观" ? "circle.lefthalf.filled" : name == "合盖动作" ? "bolt" : name == "通用" ? "gearshape" : "info.circle")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(page == name ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Circle().fill(model.enabled ? .green : .secondary).frame(width: 7, height: 7)
                Text(model.enabled ? "桌面效果已开启" : "桌面效果已暂停").font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(width: 180).background(.ultraThinMaterial)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(page).font(.title2.bold())
                    if page == "外观" {
                        MetalPreview(renderer: model.preview).frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.4), lineWidth: 5))
                        HStack {
                            Text("\(Int(model.followLid ? model.angle : model.manualAngle))°").monospacedDigit().frame(width: 45)
                            Slider(value: $model.manualAngle, in: 0...150).disabled(model.followLid)
                                .accessibilityLabel("预览角度").onChange(of: model.manualAngle) { _, _ in model.refresh() }
                            Toggle("跟随屏幕", isOn: $model.followLid).toggleStyle(.switch).fixedSize()
                                .onChange(of: model.followLid) { _, _ in model.refresh() }
                        }
                        Text(model.sensorStatus).font(.caption).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 8) {
                            control("动画顺滑度", value: $model.smoothness)
                            HStack { Text("更跟手"); Spacer(); Text("更柔和") }.font(.caption).foregroundStyle(.secondary)
                            Text("越向右，角度跳变越柔和，跟随会稍慢。实时生效，并记住你的选择。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                        Picker("样式", selection: $model.style) { ForEach(["Silk", "Shade", "Frost"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                        VStack(spacing: 16) {
                            control("透视", value: $model.perspective)
                            control("渐变模糊", value: $model.blur)
                            control("阴影", value: $model.shadow)
                            HStack { Text("恢复角度").frame(width: 76, alignment: .leading); Slider(value: $model.clearAngle, in: 60...150); Text("\(Int(model.clearAngle))°").monospacedDigit().frame(width: 45) }
                        }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                        Button("用当前开度校准恢复位置") { model.clearAngle = model.sensor.latest.angle }
                            .disabled(!(60...150).contains(model.angle))
                        Text("关闭“跟随屏幕”可拖动滑块预览。实际桌面效果始终跟随铰链；达到恢复角度后自动清除。").font(.callout).foregroundStyle(.secondary)
                    } else if page == "合盖动作" {
                        LidHooksSettings(hooks: model.hooks)
                    } else if page == "通用" {
                        Toggle("恢复桌面时播放轻提示音", isOn: $model.sound).onChange(of: model.sound) { _, value in UserDefaults.standard.set(value, forKey: "sound") }
                        Text("应用驻留在菜单栏。在本窗口按 Esc，或随时从菜单栏点击“暂停”，可立即关闭效果。关闭此窗口后仍可从菜单栏打开。").foregroundStyle(.secondary)
                        Button("打开屏幕录制权限设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
                    } else {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88).accessibilityHidden(true)
                        Text("Foldy").font(.largeTitle.bold())
                        Text("随屏幕开合，让桌面轻轻折叠。")
                        Text("根据 trybendy.app 的公开演示独立实现。非官方版本，与原作者无关联。\n\n使用 MacBook 铰链传感器、ScreenCaptureKit 和 Metal 驱动的 Core Image。捕获帧只留在内存，不录制、不上传。\n\nmacOS 14+ · Apple silicon MacBook")
                            .foregroundStyle(.secondary)
                        Link("查看原作", destination: URL(string: "https://trybendy.app/")!)
                    }
                    Divider()
                    HStack {
                        Button(model.enabled ? "暂停效果" : "开启桌面效果") { model.enabled ? model.pause() : model.start() }
                            .buttonStyle(.borderedProminent).disabled(model.starting)
                        if model.starting { ProgressView().controlSize(.small) }
                    }
                    Text(model.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(26)
            }.frame(width: 540)
        }.frame(height: 700)
    }
    func control(_ label: String, value: Binding<Double>) -> some View {
        HStack { Text(label).frame(width: 76, alignment: .leading); Slider(value: value, in: 0...1).accessibilityLabel(label); Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().frame(width: 45) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: Model!
    var window: NSWindow!
    var item: NSStatusItem!
    var escapeMonitor: Any?
    var localMonitor: Any?
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        model = Model()
        if CommandLine.arguments.contains("--hooks") { model.settingsPage = "合盖动作" }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 700), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Foldy"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menuIcon = NSApp.applicationIconImage.copy() as! NSImage
        menuIcon.size = NSSize(width: 18, height: 18)
        item.button?.image = menuIcon
        item.button?.setAccessibilityLabel("Foldy")
        item.button?.toolTip = "Foldy"
        let menu = NSMenu()
        menu.addItem(withTitle: "外观设置…", action: #selector(showAppearance), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "合盖动作…", action: #selector(showHooks), keyEquivalent: "").target = self
        menu.addItem(withTitle: "暂停效果", action: #selector(pause), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Foldy", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        // AppKit routes window keyboard equivalents through the application main menu.
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem(title: "Foldy", action: nil, keyEquivalent: "")
        appMenuItem.submenu = menu.copy() as? NSMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in if event.keyCode == 53 { self?.model.pause() } }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in if event.keyCode == 53 { self?.model.pause() }; return event }
        show()
        model.hooks.retryPending()
        if CommandLine.arguments.contains("--start") { model.start() }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard let model, model.wantsEffect, !model.enabled, !model.starting, CGPreflightScreenCaptureAccess() else { return }
        model.start()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true; model.pause()
        Task { @MainActor in
            await model.hooks.guardian.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    @objc func show() { window.makeKeyAndOrderFront(nil); model.preview.resumePresentation(); model.refresh(); NSApp.activate(ignoringOtherApps: true) }
    @objc func showAppearance() { model.settingsPage = "外观"; show() }
    @objc func showHooks() { model.settingsPage = "合盖动作"; show() }
    @objc func pause() { model.pause() }
    @objc func quit() { model.pause(); NSApp.terminate(nil) }
}
