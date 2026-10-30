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
    private var continuousFaceUnlockDeadline = Date.distantPast
    private var suppressFaceUnlockUntil = Date.distantPast
    private var continuousFaceUnlockAttemptCount = 0
    private var facePresenceMissCount = 0
    private var nextFaceAttemptAt = Date.distantPast
    private var lastObservedKeyboardEventAt: TimeInterval = .infinity
    private var lastKeyboardTriggerAt: TimeInterval = 0
    private var keyboardTriggerArmedAt = Date.distantPast.timeIntervalSinceReferenceDate
    private var keyboardTriggerTimer: Timer?
    private var accessibilityRetryTimer: Timer?
    private var previewWindowController: FacePreviewWindowController?
    private var physicalInputLockUntil = Date.distantPast
    private var inputLockReleaseTimer: Timer?
    private var inputLockTap: CFMachPort?
    private var inputLockRunLoopSource: CFRunLoopSource?
    private var isEnteringPassword = false
    private var passwordAttemptCount = 0
    private var passwordVerifyTimer: Timer?

    private let wakeUnlockRetryDelay: TimeInterval = 0.5
    private let wakeUnlockMaxRetries = 8
    private let conservativeWakeSleepThreshold: TimeInterval = 60
    private let conservativeWakeUnlockDelay: TimeInterval = 1.5
    private let faceUnlockBaseRetryDelay: TimeInterval = 1.5
    private let faceUnlockMaxRetryDelay: TimeInterval = 20
    private let faceUnlockCooldownFailureCount = 6
    private let faceUnlockCooldownDelay: TimeInterval = 45
    private let facePresenceTimeout: TimeInterval = 3
    private let facePresenceBaseDelay: TimeInterval = 2
    private let facePresenceMaxDelay: TimeInterval = 60
    /// How long a key/mouse triggered session keeps polling for a face. "Always" mode keeps polling
    /// while the screen is locked and awake, `keyboard` mode stops so the camera stays untouched
    /// until the user interacts again.
    private let keyboardTriggerSessionDuration: TimeInterval = 30
    private let keyboardTriggerPollInterval: TimeInterval = 0.1
    private let keyboardTriggerDebounce: TimeInterval = 1
    private let keyboardTriggerArmingDelay: TimeInterval = 0.75
    private static let syntheticInputMarker: Int64 = 0x4D_41_43_48
    private static let physicalInputLockDuration: TimeInterval = 2
    private static let passwordMaxAttempts = 3
    private static let passwordVerifyDelay: TimeInterval = 1.5
    private let logger = Logger(subsystem: "com.tonydong.macOSHello", category: "face-unlock")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        registerSystemNotifications()
        startLockStatePolling()
        startKeyboardTriggerPolling()
        checkAccessibilityPermission()
        DispatchQueue.main.async { [weak self] in
            self?.resumeForCurrentLockState()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityRetryTimer?.invalidate()
        keyboardTriggerTimer?.invalidate()
        unlockPhysicalInput()
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                    guard let self, self.isScreenLocked(), !self.isDisplayAsleep() else { return }
                    self.startContinuousFaceUnlock(resetPenalty: true)
                }
            }
        })
        systemObservers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.displaySleep = true
            self?.stopCameraWhenDisplayIsOff()
        })
        systemObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemSleep = false
            self?.displaySleep = false
            self?.lastWakeAt = Date().timeIntervalSince1970
            self?.logger.info("系统已唤醒，安排人脸识别")
            self?.resetFaceUnlockAttempts()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.isScreenLocked(), !self.isDisplayAsleep() else { return }
                guard self.faceUnlockTriggerMode != .keyboard else { return }
                self.startContinuousFaceUnlock(resetPenalty: true)
            }
        })
        systemObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemSleep = true
            self?.lastSystemSleepStartedAt = Date().timeIntervalSince1970
            self?.stopCameraWhenSystemSleeps()
        })
        systemObservers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            if self?.faceUnlockTriggerMode == .keyboard {
                self?.prepareKeyboardTrigger()
            } else {
                self?.startContinuousFaceUnlock(resetPenalty: true)
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
                self?.startContinuousFaceUnlock(resetPenalty: true)
            }
        })
        systemObservers.append(center.addObserver(forName: NSNotification.Name("com.apple.screensaver.didstop"), object: nil, queue: .main) { [weak self] _ in
            self?.inScreensaver = false
            self?.lastScreensaverStartedAt = 0
        })
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
              !isPowerStateBlockingCamera,
              isScreenLocked(),
              !faceOperationActive,
              Date() >= suppressFaceUnlockUntil else { return }

        let secondsSinceLastEvent = Self.secondsSinceLastInputEvent
        guard secondsSinceLastEvent < lastObservedKeyboardEventAt else { return }
        lastObservedKeyboardEventAt = secondsSinceLastEvent

        let elapsedSinceLock = Date().timeIntervalSinceReferenceDate - keyboardTriggerArmedAt
        guard elapsedSinceLock >= keyboardTriggerArmingDelay else { return }
        guard Date().timeIntervalSinceReferenceDate - lastKeyboardTriggerAt >= keyboardTriggerDebounce else { return }

        lastKeyboardTriggerAt = Date().timeIntervalSinceReferenceDate
        logger.info("检测到键盘或鼠标活动，触发人脸识别")
        startContinuousFaceUnlock(forceImmediate: true)
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

    private func stopCameraWhenSystemSleeps() {
        cancelUnlockTimers()
        stopContinuousFaceUnlock()
        resetFaceUnlockAttempts()
        faceUnlock.stopCurrentOperation()
        logger.info("系统即将睡眠，停止人脸识别")
    }

    /// Live check instead of only trusting NSWorkspace notifications: those can be missed while the
    /// app is suspended, which used to leave `displaySleep` stuck at `true` forever and silently
    /// blocked every later unlock attempt.
    private func isDisplayAsleep() -> Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    private var isPowerStateBlockingCamera: Bool {
        systemSleep || displaySleep || isDisplayAsleep()
    }

    private func reconcilePowerState() {
        let asleep = isDisplayAsleep()
        var resumedFromSleep = false
        if displaySleep != asleep {
            logger.info("校正显示器状态：\(asleep ? "已关闭" : "已亮起", privacy: .public)")
            displaySleep = asleep
            if !asleep {
                resumedFromSleep = true
            }
        }
        // Timers cannot fire while the machine is really asleep, so a stale `systemSleep` flag only
        // needs a short grace period before it is safe to clear.
        if systemSleep, Date().timeIntervalSince1970 - lastSystemSleepStartedAt > 3 {
            systemSleep = false
            logger.info("校正系统休眠状态：已唤醒")
            resumedFromSleep = true
        }
        if resumedFromSleep {
            handleDisplayBecameAwake()
        }
    }

    private func handleDisplayBecameAwake() {
        resetFaceUnlockAttempts()
        guard !isPowerStateBlockingCamera else { return }
        guard autoUnlockEnabled, isScreenLocked() else { return }
        guard faceUnlockTriggerMode != .keyboard else {
            logger.info("屏幕已亮起，等待键盘或鼠标后识别人脸")
            return
        }
        startContinuousFaceUnlock(resetPenalty: true)
    }

    /// Covers launches that happen while the screen is already locked, where the original lock
    /// notification has already been delivered before this process started observing it.
    private func resumeForCurrentLockState() {
        reconcilePowerState()
        guard autoUnlockEnabled, isScreenLocked(), !isPowerStateBlockingCamera else { return }
        if faceUnlockTriggerMode == .keyboard {
            prepareKeyboardTrigger()
        } else {
            startContinuousFaceUnlock(resetPenalty: true)
        }
    }

    private func unlockWithFace(requireLockedScreen: Bool, showResult: Bool, presenceGate: Bool = false) {
        guard !faceOperationActive else { return }
        if requireLockedScreen { guard isScreenLocked() else { return } }
        faceOperationActive = true
        updateStatus(L("status_verifying"))
        logger.info("开始人脸识别，要求锁屏：\(requireLockedScreen, privacy: .public)")

        Task { [weak self] in
            guard let self else { return }
            self.logger.info("开始人脸识别，相似度阈值 \(self.format(self.faceUnlock.threshold), privacy: .public)，活体检测 \(self.faceUnlock.livenessEnabled ? "开启" : "关闭", privacy: .public)")
            let result = await self.faceUnlock.verify(
                timeout: 8,
                presenceTimeout: presenceGate ? self.facePresenceTimeout : nil
            )
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
                    self.handleAutomaticVerificationFailure(
                        reason: reason,
                        similarity: similarity,
                        requireLockedScreen: requireLockedScreen
                    )
                    if showResult {
                        let detail = similarity.map { LF("detail_max_similarity", $0) } ?? ""
                        self.showInfo(L("verify_failed_title"), reason.message + detail)
                    }
                }
            }
        }
    }

    /// Escalating retry policy for the lock screen.
    ///
    /// There is no hard attempt limit any more: recognition keeps being retried while the screen is
    /// locked and the display is awake. A "nobody in front of the camera" result is not a failure at
    /// all, it only slows down how often the camera is woken up; a real non-match increases the wait
    /// exponentially, and a short cool-down resets the ladder after repeated misses.
    private func handleAutomaticVerificationFailure(
        reason: FaceVerificationFailure,
        similarity: Float?,
        requireLockedScreen: Bool
    ) {
        guard requireLockedScreen, continuousFaceUnlockEnabled, isScreenLocked(), !isPowerStateBlockingCamera else {
            updateStatus(L("status_failed"))
            return
        }

        let detail = similarity.map { LF("detail_max_similarity", $0) } ?? ""

        if case .noFaceDetected = reason {
            facePresenceMissCount += 1
            let delay = presenceBackoffDelay(after: facePresenceMissCount)
            logger.info("摄像头前未检测到人脸（连续第 \(self.facePresenceMissCount, privacy: .public) 次），\(delay, privacy: .public) 秒后再次检测")
            updateStatus(L("status_waiting_face"))
            nextFaceAttemptAt = Date().addingTimeInterval(delay)
            scheduleContinuousFaceUnlock(after: delay)
            return
        }

        facePresenceMissCount = 0
        continuousFaceUnlockAttemptCount += 1
        logger.error(
            "人脸识别未匹配（连续第 \(self.continuousFaceUnlockAttemptCount, privacy: .public) 次）：\(reason.message, privacy: .public)\(detail, privacy: .public)"
        )

        let delay: TimeInterval
        if continuousFaceUnlockAttemptCount >= faceUnlockCooldownFailureCount {
            delay = faceUnlockCooldownDelay
            continuousFaceUnlockAttemptCount = 0
            logger.error("人脸识别连续失败 \(self.faceUnlockCooldownFailureCount, privacy: .public) 次，冷却 \(delay, privacy: .public) 秒后重新开始")
        } else {
            delay = failureBackoffDelay(after: continuousFaceUnlockAttemptCount)
        }

        updateStatus(L("status_failed_retry"))
        nextFaceAttemptAt = Date().addingTimeInterval(delay)
        scheduleContinuousFaceUnlock(after: delay)
    }

    private func failureBackoffDelay(after failures: Int) -> TimeInterval {
        let exponent = max(0, failures - 1)
        return min(faceUnlockBaseRetryDelay * pow(2, Double(exponent)), faceUnlockMaxRetryDelay)
    }

    private func presenceBackoffDelay(after misses: Int) -> TimeInterval {
        let exponent = max(0, misses - 1)
        return min(facePresenceBaseDelay * pow(2, Double(exponent)), facePresenceMaxDelay)
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
            self.reconcilePowerState()
            let locked = self.isScreenLocked()
            if self.lastKnownLockedState != locked {
                self.logger.info("检测到锁屏状态变化：\(locked ? "已锁定" : "已解锁", privacy: .public)")
                self.lastKnownLockedState = locked
                if locked {
                    if self.faceUnlockTriggerMode == .keyboard {
                        self.prepareKeyboardTrigger()
                    } else if !self.isPowerStateBlockingCamera {
                        self.startContinuousFaceUnlock(resetPenalty: true)
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

    private func startContinuousFaceUnlock(resetPenalty: Bool = false, forceImmediate: Bool = false) {
        continuousFaceUnlockEnabled = true
        if resetPenalty {
            resetFaceUnlockAttempts()
        }
        if forceImmediate {
            // An explicit key press or mouse movement means somebody is right here, so it should not
            // wait for the penalty delay built up by earlier automatic retries.
            nextFaceAttemptAt = .distantPast
        }
        lastKeyboardTriggerAt = Date().timeIntervalSinceReferenceDate
        continuousFaceUnlockDeadline = faceUnlockTriggerMode == .keyboard
            ? Date().addingTimeInterval(keyboardTriggerSessionDuration)
            : .distantFuture
        // Keep an already running penalty delay, otherwise allow a fresh attempt right away.
        let delay = max(0.5, nextFaceAttemptAt.timeIntervalSinceNow)
        scheduleContinuousFaceUnlock(after: delay)
    }

    private func stopContinuousFaceUnlock() {
        continuousFaceUnlockEnabled = false
        continuousFaceUnlockDeadline = .distantPast
    }

    private func resetFaceUnlockAttempts() {
        continuousFaceUnlockAttemptCount = 0
        facePresenceMissCount = 0
        nextFaceAttemptAt = .distantPast
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
        guard continuousFaceUnlockEnabled, autoUnlockEnabled, isScreenLocked() else {
            if !isScreenLocked() { stopContinuousFaceUnlock() }
            return
        }
        guard !isPowerStateBlockingCamera else {
            if isDisplayAsleep() { displaySleep = true }
            cancelUnlockTimers()
            stopContinuousFaceUnlock()
            faceUnlock.stopCurrentOperation()
            logger.info("屏幕已关闭，停止人脸识别")
            return
        }
        guard Date() <= continuousFaceUnlockDeadline else {
            stopContinuousFaceUnlock()
            logger.info("本次人脸识别会话结束，等待下一次触发")
            updateStatus(L("status_timeout"))
            return
        }
        guard !faceOperationActive else {
            scheduleContinuousFaceUnlock(after: 0.5)
            return
        }

        let now = Date()
        if now < suppressFaceUnlockUntil {
            scheduleContinuousFaceUnlock(after: suppressFaceUnlockUntil.timeIntervalSince(now) + 0.05)
            return
        }
        if now < nextFaceAttemptAt {
            scheduleContinuousFaceUnlock(after: nextFaceAttemptAt.timeIntervalSince(now))
            return
        }
        unlockWithFace(requireLockedScreen: true, showResult: false, presenceGate: true)
    }

    private func tryUnlockScreen(retryCount: Int = 0) {
        guard !isPowerStateBlockingCamera else { return }
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
            self.submitPassword(password)
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
        passwordVerifyTimer?.invalidate()
        passwordVerifyTimer = nil
    }

    /// Types the password once, then verifies whether the screen really unlocked. If the screen is
    /// still locked (e.g. a stray keystroke slipped in, or the field was not empty) the whole
    /// select-all / type / return sequence is repeated, which also clears any junk first.
    private func submitPassword(_ password: String) {
        passwordAttemptCount = 1
        guard enterPasswordSafely(password) else { return }
        schedulePasswordVerification(password)
    }

    private func schedulePasswordVerification(_ password: String) {
        passwordVerifyTimer?.invalidate()
        let timer = Timer(timeInterval: Self.passwordVerifyDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard self.isScreenLocked() else {
                self.logger.info("已确认解锁成功")
                return
            }
            guard self.passwordAttemptCount < Self.passwordMaxAttempts else {
                self.logger.error("连续输入 \(Self.passwordMaxAttempts) 次密码后仍未解锁，停止尝试")
                self.updateStatus(L("status_unlock_failed"))
                return
            }
            self.passwordAttemptCount += 1
            self.logger.info("屏幕仍未解锁，正在第 \(self.passwordAttemptCount) 次重试输入密码")
            if self.enterPasswordSafely(password) {
                self.schedulePasswordVerification(password)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        passwordVerifyTimer = timer
    }

    @discardableResult
    private func enterPasswordSafely(_ password: String) -> Bool {
        guard !isEnteringPassword else {
            logger.info("已在进行自动输入，忽略重复的解锁请求")
            return false
        }

        // The physical keyboard and mouse buttons are swallowed from this point on, so nothing the
        // user presses can reach (or append to) the login password field. Our own synthetic events
        // carry a marker that the event tap lets through.
        guard lockPhysicalInput(for: Self.physicalInputLockDuration) else {
            logger.error("无法锁定物理输入，已取消本次自动输入密码")
            updateStatus(L("status_unlock_failed"))
            return false
        }

        isEnteringPassword = true
        let source = CGEventSource(stateID: .hidSystemState)

        // 1. Command-A selects whatever is already in the field (stray keystrokes typed before the
        //    lock), a following Delete guarantees the field ends up empty either way.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            guard let self else { return }
            Self.postSelectAll(source: source)

            // 2. Type the password.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                self.postPasswordText(password, source: source)

                // 3. Press Return to submit.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    guard let self else { return }
                    Self.postKeyEvent(source: source, virtualKey: 36, keyDown: true, flags: [])
                    Self.postKeyEvent(source: source, virtualKey: 36, keyDown: false, flags: [])
                    self.logger.info("已发送全选、密码与回车")

                    // Release the input lock as soon as the sequence is done; the hard timeout in
                    // lockPhysicalInput(for:) stays as a backstop.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                        self?.unlockPhysicalInput()
                        self?.isEnteringPassword = false
                    }
                }
            }
        }
        return true
    }

    private static func postSelectAll(source: CGEventSource?) {
        postKeyEvent(source: source, virtualKey: 0, keyDown: true, flags: .maskCommand)   // A
        postKeyEvent(source: source, virtualKey: 0, keyDown: false, flags: .maskCommand)
        // A burst of Delete also empties the field in case the login window ignores Command-A
        // (extra deletes on an already empty field are no-ops).
        for _ in 0..<24 {
            postKeyEvent(source: source, virtualKey: 51, keyDown: true, flags: [])        // Delete
            postKeyEvent(source: source, virtualKey: 51, keyDown: false, flags: [])
        }
    }

    private func postPasswordText(_ string: String, source: CGEventSource?) {
        let characters = Array(string.utf16)
        let chunkLength = 20
        var start = 0
        while start < characters.count {
            let end = min(start + chunkLength, characters.count)
            let chunk = Array(characters[start..<end])
            chunk.withUnsafeBufferPointer { buffer in
                let event = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true)
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buffer.baseAddress)
                event?.flags = []
                event?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticInputMarker)
                event?.post(tap: .cghidEventTap)
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false)
                keyUp?.flags = []
                keyUp?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticInputMarker)
                keyUp?.post(tap: .cghidEventTap)
            }
            start = end
        }
    }

    private static func postKeyEvent(
        source: CGEventSource?,
        virtualKey: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags
    ) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: keyDown)
        event?.flags = flags
        event?.setIntegerValueField(.eventSourceUserData, value: syntheticInputMarker)
        event?.post(tap: .cghidEventTap)
    }

    @discardableResult
    private func lockPhysicalInput(for duration: TimeInterval) -> Bool {
        if inputLockTap == nil, !createInputLockTap() {
            return false
        }
        guard let tap = inputLockTap else { return false }

        // Deadline first, then enable: a physical key pressed in between is only discarded once the
        // tap is live, and the deadline is already valid by then.
        physicalInputLockUntil = Date().addingTimeInterval(duration)
        CGEvent.tapEnable(tap: tap, enable: true)

        inputLockReleaseTimer?.invalidate()
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            self?.unlockPhysicalInput()
        }
        // .common so the backstop also fires while a modal panel or menu tracking loop is running.
        RunLoop.main.add(timer, forMode: .common)
        inputLockReleaseTimer = timer

        logger.info("已临时锁定物理键盘和鼠标点击输入")
        return true
    }

    private func createInputLockTap() -> Bool {
        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
            (CGEventMask(1) << CGEventType.leftMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.leftMouseUp.rawValue) |
            (CGEventMask(1) << CGEventType.rightMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.rightMouseUp.rawValue) |
            (CGEventMask(1) << CGEventType.otherMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.otherMouseUp.rawValue) |
            (CGEventMask(1) << CGEventType.scrollWheel.rawValue)

        // .cghidEventTap also covers the login window session, which a session-level tap may miss.
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.inputLockCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("创建输入拦截器失败：缺少辅助功能权限")
            return false
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        inputLockTap = tap
        inputLockRunLoopSource = runLoopSource
        return true
    }

    private func unlockPhysicalInput() {
        physicalInputLockUntil = .distantPast
        isEnteringPassword = false
        inputLockReleaseTimer?.invalidate()
        inputLockReleaseTimer = nil
        if let inputLockTap {
            CGEvent.tapEnable(tap: inputLockTap, enable: false)
        }
    }

    private static let inputLockCallback: CGEventTapCallBack = { _, type, event, userInfo in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let userInfo {
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
                // Only re-arm while the lock is still meant to be active.
                if Date() < delegate.physicalInputLockUntil, let tap = delegate.inputLockTap {
                    if type == .tapDisabledByUserInput {
                        // The login password field turns on Secure Event Input, which the system
                        // uses to switch off every third-party event tap. Physical keystrokes can
                        // then no longer be swallowed; the password re-verification loop covers it.
                        delegate.logger.info("登录界面启用了安全输入，物理键盘无法继续拦截，将依赖校验重试")
                    }
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
        guard Date() < delegate.physicalInputLockUntil else {
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == syntheticInputMarker {
            return Unmanaged.passUnretained(event)
        }
        return nil
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
            startContinuousFaceUnlock(resetPenalty: true)
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
