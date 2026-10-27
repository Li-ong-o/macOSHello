import Cocoa
import CoreGraphics
import os
import ServiceManagement

private enum FaceUnlockTriggerMode: Int, CaseIterable {
    case keyboard
    case lockImmediately

    var title: String {
        switch self {
        case .keyboard: return L("trigger_keyboard")
        case .lockImmediately: return L("trigger_lock_immediately")
        }
    }
}

@NSApplicationMain
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    @IBOutlet private var statusMenu: NSMenu?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let prefs = UserDefaults.standard
    private let faceUnlock = FaceUnlockService()

    private let faceProfilesMenu = NSMenu()
    private let thresholdMenu = NSMenu()
    private let cameraMenu = NSMenu()
    private let triggerModeMenu = NSMenu()

    private var displaySleep = false
    private var systemSleep = false
    private var inScreensaver = false
    private var unlockedAt = 0.0
    private var lastWakeAt = 0.0
    private var lastSystemSleepStartedAt = 0.0
    private var lastScreensaverStartedAt = 0.0
    private var faceOperationActive = false
    private var pendingFaceUnlock: DispatchWorkItem?
    private var lockStateTimer: Timer?
    private var lastKnownLockedState: Bool?
    private var statusResetTimer: Timer?
    private var wakeUnlockTimer: Timer?
    private var postUnlockRetryTimer: Timer?
    private var systemObservers: [NSObjectProtocol] = []
    private var continuousFaceUnlockEnabled = false
    private var continuousFaceUnlockUntil = Date.distantPast
    private var suppressFaceUnlockUntil = Date.distantPast
    private var continuousFaceUnlockAttemptCount = 0
    private var lastObservedKeyboardEventAt: TimeInterval = .infinity
    private var lastKeyboardTriggerAt: TimeInterval = 0
    private var keyboardTriggerArmedAt = Date.distantPast.timeIntervalSinceReferenceDate
    private var keyboardTriggerTimer: Timer?
    private var accessibilityRetryTimer: Timer?
    private var previewWindowController: FacePreviewWindowController?

    private let wakeUnlockRetryDelay: TimeInterval = 0.5
    private let wakeUnlockMaxRetries = 8
    private let conservativeWakeSleepThreshold: TimeInterval = 60
    private let conservativeWakeUnlockDelay: TimeInterval = 1.5
    private let faceUnlockActiveWindow: TimeInterval = 30
    private let faceUnlockMaxAttempts = 3
    private let keyboardTriggerPollInterval: TimeInterval = 0.1
    private let keyboardTriggerDebounce: TimeInterval = 1
    private let keyboardTriggerArmingDelay: TimeInterval = 0.75
    private let logger = Logger(subsystem: "com.tonydong.macOSHello", category: "face-unlock")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        registerSystemNotifications()
        startLockStatePolling()
        startKeyboardTriggerPolling()
        checkAccessibilityPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityRetryTimer?.invalidate()
        keyboardTriggerTimer?.invalidate()
        systemObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        systemObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func configureStatusItem() {
        statusItem.button?.image = NSImage(named: "StatusBarDisconnected")
        statusItem.button?.imageScaling = .scaleProportionallyUpOrDown
        if let image = statusItem.button?.image {
            image.size = NSSize(width: 18, height: 18)
        }
        statusItem.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(withTitle: L("menu_enroll_face"), action: #selector(enrollFace), keyEquivalent: "")
        menu.addItem(withTitle: L("menu_verify_now"), action: #selector(verifyFaceNow), keyEquivalent: "")
        menu.addItem(.separator())

        let profilesItem = menu.addItem(withTitle: L("menu_registered_faces"), action: nil, keyEquivalent: "")
        profilesItem.submenu = faceProfilesMenu
        rebuildFaceProfilesMenu()

        let cameraItem = menu.addItem(withTitle: L("menu_camera"), action: nil, keyEquivalent: "")
        cameraItem.submenu = cameraMenu
        cameraMenu.delegate = self
        rebuildCameraMenu()

        let thresholdItem = menu.addItem(withTitle: L("menu_similarity_threshold"), action: nil, keyEquivalent: "")
        thresholdItem.submenu = thresholdMenu
        rebuildThresholdMenu()

        let livenessItem = menu.addItem(withTitle: L("menu_liveness"), action: #selector(toggleFaceLiveness), keyEquivalent: "")
        livenessItem.state = faceUnlock.livenessEnabled ? .on : .off
        let autoItem = menu.addItem(withTitle: L("menu_auto_unlock"), action: #selector(toggleAutoUnlock), keyEquivalent: "")
        autoItem.state = autoUnlockEnabled ? .on : .off
        let triggerItem = menu.addItem(withTitle: L("menu_trigger_mode"), action: nil, keyEquivalent: "")
        triggerItem.submenu = triggerModeMenu
        rebuildTriggerModeMenu()

        menu.addItem(.separator())
        let passwordItem = menu.addItem(withTitle: L("menu_set_password"), action: #selector(setPassword), keyEquivalent: "")
        passwordItem.state = passwordConfigured ? .on : .off
        let startupItem = menu.addItem(withTitle: L("menu_launch_at_login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        startupItem.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(withTitle: L("menu_lock_now"), action: #selector(lockScreenNow), keyEquivalent: "")
        menu.addItem(withTitle: L("menu_about"), action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("menu_quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu == faceProfilesMenu { rebuildFaceProfilesMenu() }
        if menu == cameraMenu { rebuildCameraMenu() }
        if menu == thresholdMenu { rebuildThresholdMenu() }
        if menu == triggerModeMenu { rebuildTriggerModeMenu() }
        refreshSettingMenuStates()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(enrollFace), #selector(verifyFaceNow), #selector(setPassword):
            return !faceOperationActive
        default:
            return true
        }
    }

    private var autoUnlockEnabled: Bool {
        if prefs.object(forKey: "autoFaceUnlockEnabled") == nil { return true }
        return prefs.bool(forKey: "autoFaceUnlockEnabled")
    }

    private var faceUnlockTriggerMode: FaceUnlockTriggerMode {
        FaceUnlockTriggerMode(rawValue: prefs.integer(forKey: "faceUnlockTriggerMode")) ?? .keyboard
    }

    private var launchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    private var passwordConfigured: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tonydong.macOSHello",
            kSecAttrAccount as String: "unlock",
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    private func refreshSettingMenuStates() {
        statusItem.menu?.items.forEach { item in
            switch item.action {
            case #selector(toggleFaceLiveness):
                item.state = faceUnlock.livenessEnabled ? .on : .off
            case #selector(toggleAutoUnlock):
                item.state = autoUnlockEnabled ? .on : .off
            case #selector(toggleLaunchAtLogin):
                item.state = launchAtLoginEnabled ? .on : .off
            case #selector(setPassword):
                item.state = passwordConfigured ? .on : .off
            default:
                break
            }
        }
    }

    private func registerSystemNotifications() {
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        let distributed = DistributedNotificationCenter.default()

        systemObservers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.displaySleep = false
            self?.lastWakeAt = Date().timeIntervalSince1970
            self?.logger.info("屏幕已唤醒，安排人脸识别")
            self?.resetFaceUnlockAttempts()
            if self?.faceUnlockTriggerMode != .keyboard {
                self?.scheduleFaceUnlock(after: 0.75)
            }
        })
        systemObservers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.displaySleep = true
            if self?.continuousFaceUnlockEnabled == true {
                wakeDisplay()
            }
            self?.stopCameraWhenDisplayIsOff()
        })
        systemObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemSleep = false
            self?.displaySleep = false
            self?.lastWakeAt = Date().timeIntervalSince1970
            self?.logger.info("系统已唤醒，安排人脸识别")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                if self?.faceUnlockTriggerMode != .keyboard {
                    self?.scheduleFaceUnlock(after: 1.0)
                }
            }
        })
        systemObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemSleep = true
            self?.lastSystemSleepStartedAt = Date().timeIntervalSince1970
            self?.cancelUnlockTimers()
        })
        systemObservers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            if self?.faceUnlockTriggerMode == .keyboard {
                self?.prepareKeyboardTrigger()
            } else {
                self?.startContinuousFaceUnlock()
            }
        })
        systemObservers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.pendingFaceUnlock?.cancel()
            self?.pendingFaceUnlock = nil
            self?.faceUnlock.stopCurrentOperation()
            self?.faceOperationActive = false
            self?.inScreensaver = false
            self?.lastSystemSleepStartedAt = 0
            self?.lastScreensaverStartedAt = 0
            self?.suppressFaceUnlockUntil = .distantPast
            self?.keyboardTriggerArmedAt = Date.distantPast.timeIntervalSinceReferenceDate
            self?.cancelUnlockTimers()
            self?.stopContinuousFaceUnlock()
            self?.resetFaceUnlockAttempts()
        })
        systemObservers.append(center.addObserver(forName: NSNotification.Name("com.apple.screensaver.didstart"), object: nil, queue: .main) { [weak self] _ in
            self?.inScreensaver = true
            self?.lastScreensaverStartedAt = Date().timeIntervalSince1970
            if self?.faceUnlockTriggerMode != .keyboard {
                self?.scheduleFaceUnlock(after: 0.5)
            }
        })
        systemObservers.append(center.addObserver(forName: NSNotification.Name("com.apple.screensaver.didstop"), object: nil, queue: .main) { [weak self] _ in
            self?.inScreensaver = false
            self?.lastScreensaverStartedAt = 0
        })
    }

    private func scheduleFaceUnlock(after delay: TimeInterval = 0.2) {
        guard autoUnlockEnabled, !systemSleep, !displaySleep else { return }
        guard Date() >= suppressFaceUnlockUntil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingFaceUnlock = nil
            self?.unlockWithFace(requireLockedScreen: true, showResult: false)
        }
        pendingFaceUnlock?.cancel()
        pendingFaceUnlock = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startKeyboardTriggerPolling() {
        lastObservedKeyboardEventAt = Self.secondsSinceLastInputEvent
        keyboardTriggerTimer = Timer.scheduledTimer(withTimeInterval: keyboardTriggerPollInterval, repeats: true) { [weak self] _ in
            self?.pollKeyboardTrigger()
        }
    }

    private func prepareKeyboardTrigger() {
        resetFaceUnlockAttempts()
        lastObservedKeyboardEventAt = Self.secondsSinceLastInputEvent
        keyboardTriggerArmedAt = Date().timeIntervalSinceReferenceDate
        logger.info("已锁定屏幕，等待键盘或鼠标触发人脸识别")
        updateStatus(L("status_waiting_input"))
    }

    private func pollKeyboardTrigger() {
        guard faceUnlockTriggerMode == .keyboard,
              autoUnlockEnabled,
              !systemSleep,
              !displaySleep,
              isScreenLocked(),
              !faceOperationActive,
              Date() >= suppressFaceUnlockUntil,
              continuousFaceUnlockAttemptCount < faceUnlockMaxAttempts else { return }

        let secondsSinceLastEvent = Self.secondsSinceLastInputEvent
        guard secondsSinceLastEvent < lastObservedKeyboardEventAt else { return }
        lastObservedKeyboardEventAt = secondsSinceLastEvent

        let elapsedSinceLock = Date().timeIntervalSinceReferenceDate - keyboardTriggerArmedAt
        guard elapsedSinceLock >= keyboardTriggerArmingDelay else { return }
        guard Date().timeIntervalSinceReferenceDate - lastKeyboardTriggerAt >= keyboardTriggerDebounce else { return }

        lastKeyboardTriggerAt = Date().timeIntervalSinceReferenceDate
        logger.info("检测到键盘或鼠标活动，触发人脸识别")
        startContinuousFaceUnlock()
    }

    private static var secondsSinceLastInputEvent: TimeInterval {
        let eventTypes: [CGEventType] = [
            .keyDown,
            .keyUp,
            .mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
            .leftMouseDragged,
            .rightMouseDown,
            .rightMouseUp,
            .rightMouseDragged,
            .otherMouseDown,
            .otherMouseUp,
            .otherMouseDragged,
            .scrollWheel
        ]
        let states: [CGEventSourceStateID] = [.hidSystemState, .combinedSessionState]
        return eventTypes
            .flatMap { eventType in
                states.map { state in
                    CGEventSource.secondsSinceLastEventType(state, eventType: eventType)
                }
            }
            .min() ?? .infinity
    }

    private func stopCameraWhenDisplayIsOff() {
        guard displaySleep else { return }
        cancelUnlockTimers()
        stopContinuousFaceUnlock()
        resetFaceUnlockAttempts()
        faceUnlock.stopCurrentOperation()
        logger.info("屏幕已关闭，停止人脸识别")
    }

    private func unlockWithFace(requireLockedScreen: Bool, showResult: Bool) {
        guard !faceOperationActive else { return }
        if requireLockedScreen { guard isScreenLocked() else { return } }
        faceOperationActive = true
        updateStatus(L("status_verifying"))
        logger.info("开始人脸识别，要求锁屏：\(requireLockedScreen, privacy: .public)")

        Task { [weak self] in
            if let self {
                self.logger.info("开始人脸识别，相似度阈值 \(self.format(self.faceUnlock.threshold), privacy: .public)，活体检测 \(self.faceUnlock.livenessEnabled ? "开启" : "关闭", privacy: .public)")
            }
            let result = await self?.faceUnlock.verify(timeout: 8) ?? .failure(reason: .cameraUnavailable, similarity: nil, profile: nil)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.faceOperationActive = false
                switch result {
                case .success(let similarity, let profile):
                    self.logger.info("人脸匹配成功：\(profile.name, privacy: .public)，相似度 \(self.format(similarity), privacy: .public)")
                    self.resetFaceUnlockAttempts()
                    self.suppressFaceUnlockUntil = Date().addingTimeInterval(12)
                    if requireLockedScreen {
                        self.updateStatus(L("status_success_unlocking"))
                        self.tryUnlockScreen()
                    } else {
                        self.updateStatus(L("status_success"))
                    }
                    if showResult {
                        self.showInfo(L("verify_success_title"), LF("verify_success_message", profile.name, similarity))
                    }
                case .failure(let reason, let similarity, _):
                    let detail = similarity.map { LF("detail_max_similarity", $0) } ?? ""
                    self.continuousFaceUnlockAttemptCount += 1
                    self.logger.error(
                        "人脸识别失败（第 \(self.continuousFaceUnlockAttemptCount)/\(self.faceUnlockMaxAttempts) 次）：\(reason.message, privacy: .public)\(detail, privacy: .public)"
                    )
                    if requireLockedScreen, self.isScreenLocked() {
                        if self.continuousFaceUnlockAttemptCount < self.faceUnlockMaxAttempts {
                            self.updateStatus(L("status_failed_retry"))
                            self.scheduleContinuousFaceUnlock(after: 1)
                        } else {
                            self.stopContinuousFaceUnlock()
                            self.faceUnlock.stopCurrentOperation()
                            self.updateStatus(L("status_failed_3"))
                            self.logger.error("人脸识别连续失败 3 次，已停止摄像头")
                        }
                    } else {
                        self.updateStatus(L("status_failed"))
                    }
                    if showResult {
                        self.showInfo(L("verify_failed_title"), reason.message + detail)
                    }
                }
            }
        }
    }

    private func format(_ value: Float) -> String {
        String(format: "%.3f", value)
    }

    private func updateStatus(_ text: String) {
        statusResetTimer?.invalidate()
        statusResetTimer = nil
        statusItem.button?.title = text
        guard !text.isEmpty else { return }
        statusResetTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.statusResetTimer = nil
            self?.statusItem.button?.title = ""
        }
    }

    private func startLockStatePolling() {
        lastKnownLockedState = isScreenLocked()
        lockStateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let locked = self.isScreenLocked()
            if self.lastKnownLockedState != locked {
                self.logger.info("检测到锁屏状态变化：\(locked ? "已锁定" : "已解锁", privacy: .public)")
                self.lastKnownLockedState = locked
            if locked {
                if self.faceUnlockTriggerMode == .keyboard {
                    self.prepareKeyboardTrigger()
                } else {
                    self.startContinuousFaceUnlock()
                }
            } else {
                self.faceUnlock.stopCurrentOperation()
                self.faceOperationActive = false
                self.keyboardTriggerArmedAt = Date.distantPast.timeIntervalSinceReferenceDate
                self.pendingFaceUnlock?.cancel()
                    self.pendingFaceUnlock = nil
                    self.cancelUnlockTimers()
                    self.stopContinuousFaceUnlock()
                    self.resetFaceUnlockAttempts()
                }
            }
        }
    }

    private func startContinuousFaceUnlock() {
        continuousFaceUnlockEnabled = true
        resetFaceUnlockAttempts()
        lastKeyboardTriggerAt = Date().timeIntervalSinceReferenceDate
        continuousFaceUnlockUntil = Date().addingTimeInterval(faceUnlockActiveWindow)
        scheduleContinuousFaceUnlock(after: 0.5)
    }

    private func stopContinuousFaceUnlock() {
        continuousFaceUnlockEnabled = false
        continuousFaceUnlockUntil = .distantPast
    }

    private func resetFaceUnlockAttempts() {
        continuousFaceUnlockAttemptCount = 0
    }

    private func scheduleContinuousFaceUnlock(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            self?.pendingFaceUnlock = nil
            self?.runContinuousFaceUnlockOnce()
        }
        pendingFaceUnlock?.cancel()
        pendingFaceUnlock = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runContinuousFaceUnlockOnce() {
        guard Date() >= suppressFaceUnlockUntil else { return }
        guard continuousFaceUnlockAttemptCount < faceUnlockMaxAttempts else {
            stopContinuousFaceUnlock()
            return
        }
        guard continuousFaceUnlockEnabled, autoUnlockEnabled, isScreenLocked() else {
            if !isScreenLocked() { stopContinuousFaceUnlock() }
            return
        }
        guard Date() <= continuousFaceUnlockUntil else {
            continuousFaceUnlockEnabled = false
            logger.info("持续人脸识别窗口结束")
            updateStatus(L("status_timeout"))
            return
        }
        guard !systemSleep, !displaySleep else { return }
        unlockWithFace(requireLockedScreen: true, showResult: false)
    }

    private func tryUnlockScreen(retryCount: Int = 0) {
        guard !systemSleep, !displaySleep else { return }
        guard AXIsProcessTrusted() else {
            logger.error("自动解锁停止：缺少辅助功能权限")
            updateStatus(L("status_missing_accessibility"))
            startAccessibilityPermissionRecovery()
            return
        }
        guard isScreenLocked() else {
            if retryCount < wakeUnlockMaxRetries {
                scheduleWakeUnlock(after: wakeUnlockRetryDelay, retryCount: retryCount + 1)
            }
            return
        }

        wakeUnlockTimer?.invalidate()
        let unlockDelay = conservativeWakeUnlockNeeded() ? conservativeWakeUnlockDelay : (recentlyWoke() ? 0.75 : 0.5)
        wakeUnlockTimer = Timer.scheduledTimer(withTimeInterval: unlockDelay, repeats: false) { [weak self] _ in
            guard let self, self.isScreenLocked() else { return }
            guard let password = self.fetchPassword(warn: false) else {
                self.logger.error("自动解锁停止：尚未设置登录密码")
                self.updateStatus(L("status_password_missing"))
                return
            }
            self.unlockedAt = Date().timeIntervalSince1970
            self.updateStatus(L("status_entering_password"))
            self.logger.info("正在向登录窗口输入密码")
            self.fakeKeyStrokes(password)

            // Typing again before macOS reports the screen as unlocked can append the password
            // to the login field and create multiple failed attempts.
            self.postUnlockRetryTimer?.invalidate()
            self.postUnlockRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                guard let self, self.isScreenLocked() else { return }
                self.logger.error("密码已输入但屏幕仍未解锁，停止重复输入")
                self.updateStatus(L("status_unlock_failed"))
            }
        }
    }

    private func scheduleWakeUnlock(after delay: TimeInterval, retryCount: Int) {
        wakeUnlockTimer?.invalidate()
        wakeUnlockTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.tryUnlockScreen(retryCount: retryCount)
        }
    }

    private func cancelUnlockTimers() {
        wakeUnlockTimer?.invalidate()
        wakeUnlockTimer = nil
        postUnlockRetryTimer?.invalidate()
        postUnlockRetryTimer = nil
    }

    private func fakeKeyStrokes(_ string: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        Self.postKeyEvent(source: source, virtualKey: 0, keyDown: true, flags: .maskCommand)
        Self.postKeyEvent(source: source, virtualKey: 0, keyDown: false, flags: .maskCommand)

        let characters = Array(string.utf16)
        let chunkLength = 20
        var start = 0
        while start < characters.count {
            let end = min(start + chunkLength, characters.count)
            let chunk = Array(characters[start..<end])
            chunk.withUnsafeBufferPointer { buffer in
                let event = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true)
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buffer.baseAddress)
                event?.post(tap: .cghidEventTap)
                CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
            }
            start = end
        }

        Self.postKeyEvent(source: source, virtualKey: 52, keyDown: true, flags: [])
        Self.postKeyEvent(source: source, virtualKey: 52, keyDown: false, flags: [])
    }

    private static func postKeyEvent(
        source: CGEventSource?,
        virtualKey: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags
    ) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: keyDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func isScreenLocked() -> Bool {
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
           let locked = dict["CGSSessionScreenIsLocked"] as? Int {
            return locked == 1
        }
        return false
    }

    private func recentlyWoke() -> Bool {
        Date().timeIntervalSince1970 - lastWakeAt < 5
    }

    private func conservativeWakeUnlockNeeded() -> Bool {
        guard recentlyWoke() else { return false }
        let now = Date().timeIntervalSince1970
        let sleepReference = max(lastSystemSleepStartedAt, lastScreensaverStartedAt)
        guard sleepReference > 0 else { return false }
        return now - sleepReference >= conservativeWakeSleepThreshold
    }

    @objc private func enrollFace() {
        let alert = NSAlert()
        alert.messageText = L("enroll_title")
        alert.informativeText = L("enroll_message")
        alert.addButton(withTitle: L("button_continue"))
        alert.addButton(withTitle: L("button_cancel"))
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        nameField.placeholderString = L("field_name")
        alert.accessoryView = nameField
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        faceOperationActive = true
        Task { [weak self] in
            do {
                let profile = try await self?.faceUnlock.enroll(name: name, timeout: 30)
                await MainActor.run { [weak self] in
                    self?.faceOperationActive = false
                    self?.showInfo(L("enroll_success_title"), LF("enroll_success_message", profile?.name ?? name))
                    self?.rebuildFaceProfilesMenu()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.faceOperationActive = false
                    self?.showInfo(L("enroll_failed_title"), error.localizedDescription)
                }
            }
        }
    }

    @objc private func verifyFaceNow() {
        let controller = FacePreviewWindowController(faceUnlock: faceUnlock)
        previewWindowController = controller
        controller.didFinish = { [weak self, weak controller] in
            guard let self, let controller, self.previewWindowController === controller else { return }
            self.previewWindowController = nil
        }
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func deleteAllFaces() {
        let alert = NSAlert()
        alert.messageText = L("delete_all_title")
        alert.informativeText = L("delete_all_message")
        alert.addButton(withTitle: L("button_delete"))
        alert.addButton(withTitle: L("button_cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        faceUnlock.deleteAll()
        rebuildFaceProfilesMenu()
    }

    @objc private func removeFaceProfile(_ menuItem: NSMenuItem) {
        guard let idString = menuItem.representedObject as? String, let id = UUID(uuidString: idString) else { return }
        var store = FaceEnrollmentStore()
        if let data = try? Data(contentsOf: FaceEnrollmentStore.storageURL) {
            store = (try? JSONDecoder().decode(FaceEnrollmentStore.self, from: data)) ?? store
        }
        store.profiles.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: FaceEnrollmentStore.storageURL, options: [.atomic])
        }
        rebuildFaceProfilesMenu()
    }

    @objc private func setFaceSimilarityThreshold(_ menuItem: NSMenuItem) {
        faceUnlock.threshold = Float(menuItem.tag) / 100
        rebuildThresholdMenu()
    }

    @objc private func setFaceCamera(_ menuItem: NSMenuItem) {
        prefs.set(menuItem.representedObject as? String ?? "", forKey: "faceCameraID")
        rebuildCameraMenu()
    }

    @objc private func toggleFaceLiveness() {
        let enabled = !faceUnlock.livenessEnabled
        prefs.set(enabled, forKey: "faceLivenessEnabled")
        statusItem.menu?.items.forEach { item in
            if item.action == #selector(toggleFaceLiveness) { item.state = enabled ? .on : .off }
        }
    }

    @objc private func toggleAutoUnlock() {
        let enabled = !autoUnlockEnabled
        prefs.set(enabled, forKey: "autoFaceUnlockEnabled")
        statusItem.menu?.items.forEach { item in
            if item.action == #selector(toggleAutoUnlock) { item.state = enabled ? .on : .off }
        }
    }

    @objc private func setFaceUnlockTriggerMode(_ menuItem: NSMenuItem) {
        guard let mode = FaceUnlockTriggerMode(rawValue: menuItem.tag), mode != faceUnlockTriggerMode else { return }
        prefs.set(mode.rawValue, forKey: "faceUnlockTriggerMode")
        rebuildTriggerModeMenu()
        logger.info("识别触发方式已切换为：\(mode.title, privacy: .public)")

        if mode == .keyboard {
            stopContinuousFaceUnlock()
            faceUnlock.stopCurrentOperation()
            faceOperationActive = false
            pendingFaceUnlock?.cancel()
            pendingFaceUnlock = nil
            if isScreenLocked() { prepareKeyboardTrigger() }
        } else if isScreenLocked() {
            startContinuousFaceUnlock()
        }
    }

    @objc private func setPassword() {
        let alert = NSAlert()
        alert.messageText = L("password_title")
        alert.informativeText = L("password_message")
        alert.addButton(withTitle: L("button_save"))
        alert.addButton(withTitle: L("button_cancel"))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        savePassword(field.stringValue)
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else {
            showInfo(L("startup_unsupported_title"), L("startup_unsupported_message"))
            return
        }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            statusItem.menu?.items.forEach { item in
                if item.action == #selector(toggleLaunchAtLogin) { item.state = self.launchAtLoginEnabled ? .on : .off }
            }
        } catch {
            showInfo(L("startup_failed_title"), error.localizedDescription)
        }
    }

    @objc private func lockScreenNow() {
        cancelUnlockTimers()
        let result = SACLockScreenImmediate()
        if result == noErr {
            logger.info("已请求锁定屏幕")
            updateStatus(L("status_lock_requested"))
        } else {
            logger.error("锁屏请求失败：\(result, privacy: .public)")
            updateStatus(L("status_lock_failed"))
            showInfo(L("status_lock_failed"), LF("lock_failed_message", result))
        }
    }

    @objc private func showAbout() {
        AboutBox.showAboutBox()
    }

    private func rebuildFaceProfilesMenu() {
        faceProfilesMenu.removeAllItems()
        let profiles = faceUnlock.profiles
        if profiles.isEmpty {
            let item = faceProfilesMenu.addItem(withTitle: L("no_profiles"), action: nil, keyEquivalent: "")
            item.isEnabled = false
        } else {
            for profile in profiles {
                let date = DateFormatter.localizedString(from: profile.createdAt, dateStyle: .short, timeStyle: .none)
                let item = faceProfilesMenu.addItem(withTitle: LF("profile_delete", profile.name, date), action: #selector(removeFaceProfile), keyEquivalent: "")
                item.representedObject = profile.id.uuidString
            }
        }
        faceProfilesMenu.addItem(.separator())
        let deleteItem = faceProfilesMenu.addItem(withTitle: L("delete_all"), action: #selector(deleteAllFaces), keyEquivalent: "")
        deleteItem.isEnabled = !profiles.isEmpty
    }

    private func rebuildThresholdMenu() {
        thresholdMenu.removeAllItems()
        for value in stride(from: 80, through: 95, by: 1) {
            let item = thresholdMenu.addItem(withTitle: String(format: "%.2f", Float(value) / 100), action: #selector(setFaceSimilarityThreshold), keyEquivalent: "")
            item.tag = value
            item.state = abs(faceUnlock.threshold - Float(value) / 100) < 0.001 ? .on : .off
        }
    }

    private func rebuildCameraMenu() {
        cameraMenu.removeAllItems()
        let cameras = FaceCamera.availableCameras()
        guard !cameras.isEmpty else {
            let item = cameraMenu.addItem(withTitle: L("no_cameras"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            return
        }
        for camera in cameras {
            let item = cameraMenu.addItem(withTitle: camera.localizedName, action: #selector(setFaceCamera), keyEquivalent: "")
            item.representedObject = camera.uniqueID
            item.state = faceUnlock.cameraID == camera.uniqueID ? .on : .off
        }
    }

    private func rebuildTriggerModeMenu() {
        triggerModeMenu.removeAllItems()
        for mode in FaceUnlockTriggerMode.allCases {
            let item = triggerModeMenu.addItem(withTitle: mode.title, action: #selector(setFaceUnlockTriggerMode), keyEquivalent: "")
            item.tag = mode.rawValue
            item.state = mode == faceUnlockTriggerMode ? .on : .off
        }
    }

    private func showInfo(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("button_ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func checkAccessibilityPermission() {
        let options: CFDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        logger.info("辅助功能初始状态：\(trusted)")
        guard !trusted else { return }
        updateStatus(L("status_missing_accessibility"))
        startAccessibilityPermissionRecovery()
    }

    private func startAccessibilityPermissionRecovery() {
        guard accessibilityRetryTimer == nil else { return }
        accessibilityRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if AXIsProcessTrusted() {
                self.logger.info("辅助功能权限已恢复")
                self.updateStatus(L("status_accessibility_ready"))
                self.accessibilityRetryTimer?.invalidate()
                self.accessibilityRetryTimer = nil
            }
        }
        if let timer = accessibilityRetryTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func savePassword(_ password: String) {
        guard !password.isEmpty else {
            showInfo(L("password_empty_title"), L("password_empty_message"))
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tonydong.macOSHello",
            kSecAttrAccount as String: "unlock"
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = password.data(using: .utf8) ?? Data()
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        showInfo(
            status == errSecSuccess ? L("password_saved_title") : L("password_save_failed_title"),
            status == errSecSuccess ? L("password_saved_message") : LF("keychain_error", status)
        )
    }

    private func fetchPassword(warn: Bool) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tonydong.macOSHello",
            kSecAttrAccount as String: "unlock",
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            if warn { showInfo(L("password_not_set_title"), L("password_not_set_message")) }
            return nil
        }
        return password
    }
}
