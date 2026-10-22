import Cocoa
import CoreGraphics
import os
import ServiceManagement

@NSApplicationMain
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    @IBOutlet private var statusMenu: NSMenu?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let prefs = UserDefaults.standard
    private let faceUnlock = FaceUnlockService()

    private let faceProfilesMenu = NSMenu()
    private let thresholdMenu = NSMenu()
    private let cameraMenu = NSMenu()

    private var displaySleep = false
    private var systemSleep = false
    private var inScreensaver = false
    private var unlockedAt = 0.0
    private var lastWakeAt = 0.0
    private var faceOperationActive = false
    private var pendingFaceUnlock: DispatchWorkItem?
    private var lockStateTimer: Timer?
    private var lastKnownLockedState: Bool?
    private var statusResetTimer: Timer?
    private var wakeUnlockTimer: Timer?
    private var postUnlockRetryTimer: Timer?
    private var systemObservers: [NSObjectProtocol] = []

    private let wakeUnlockRetryDelay: TimeInterval = 0.5
    private let wakeUnlockMaxRetries = 8
    private let logger = Logger(subsystem: "com.tonydong.macOSHello", category: "face-unlock")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        registerSystemNotifications()
        startLockStatePolling()
        checkAccessibilityPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        systemObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        systemObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func configureStatusItem() {
        statusItem.button?.image = NSImage(named: "StatusBarDisconnected")
        statusItem.button?.imageScaling = .scaleProportionallyUpOrDown
        statusItem.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(withTitle: "注册人脸...", action: #selector(enrollFace), keyEquivalent: "")
        menu.addItem(withTitle: "立即识别测试", action: #selector(verifyFaceNow), keyEquivalent: "")
        menu.addItem(.separator())

        let profilesItem = menu.addItem(withTitle: "已注册人脸", action: nil, keyEquivalent: "")
        profilesItem.submenu = faceProfilesMenu
        rebuildFaceProfilesMenu()

        let cameraItem = menu.addItem(withTitle: "摄像头", action: nil, keyEquivalent: "")
        cameraItem.submenu = cameraMenu
        cameraMenu.delegate = self
        rebuildCameraMenu()

        let thresholdItem = menu.addItem(withTitle: "相似度阈值", action: nil, keyEquivalent: "")
        thresholdItem.submenu = thresholdMenu
        rebuildThresholdMenu()

        let livenessItem = menu.addItem(withTitle: "活体检测", action: #selector(toggleFaceLiveness), keyEquivalent: "")
        livenessItem.state = faceUnlock.livenessEnabled ? .on : .off
        let autoItem = menu.addItem(withTitle: "自动人脸解锁", action: #selector(toggleAutoUnlock), keyEquivalent: "")
        autoItem.state = autoUnlockEnabled ? .on : .off

        menu.addItem(.separator())
        menu.addItem(withTitle: "设置密码...", action: #selector(setPassword), keyEquivalent: "")
        let startupItem = menu.addItem(withTitle: "开机启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        startupItem.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(withTitle: "立即锁定屏幕", action: #selector(lockScreenNow), keyEquivalent: "")
        menu.addItem(withTitle: "关于 macOSHello", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu == faceProfilesMenu { rebuildFaceProfilesMenu() }
        if menu == cameraMenu { rebuildCameraMenu() }
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

    private var launchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    private func registerSystemNotifications() {
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        let distributed = DistributedNotificationCenter.default()

        systemObservers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.displaySleep = false
            self?.lastWakeAt = Date().timeIntervalSince1970
            self?.scheduleFaceUnlock()
        })
        systemObservers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.displaySleep = true
        })
        systemObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemSleep = false
            self?.displaySleep = false
            self?.lastWakeAt = Date().timeIntervalSince1970
            self?.scheduleFaceUnlock(after: 1.0)
        })
        systemObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemSleep = true
            self?.cancelUnlockTimers()
        })
        systemObservers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.scheduleFaceUnlock(after: 0.8)
        })
        systemObservers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.cancelUnlockTimers()
        })
        systemObservers.append(center.addObserver(forName: NSNotification.Name("com.apple.screensaver.didstart"), object: nil, queue: .main) { [weak self] _ in
            self?.inScreensaver = true
            self?.scheduleFaceUnlock(after: 0.5)
        })
        systemObservers.append(center.addObserver(forName: NSNotification.Name("com.apple.screensaver.didstop"), object: nil, queue: .main) { [weak self] _ in
            self?.inScreensaver = false
        })
    }

    private func scheduleFaceUnlock(after delay: TimeInterval = 0.2) {
        guard autoUnlockEnabled, !systemSleep, !displaySleep else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingFaceUnlock = nil
            self?.unlockWithFace(requireLockedScreen: true, showResult: false)
        }
        pendingFaceUnlock?.cancel()
        pendingFaceUnlock = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func unlockWithFace(requireLockedScreen: Bool, showResult: Bool) {
        guard !faceOperationActive else { return }
        if requireLockedScreen { guard isScreenLocked() else { return } }
        faceOperationActive = true
        updateStatus("识别中")
        logger.info("开始人脸识别，要求锁屏：\(requireLockedScreen, privacy: .public)")

        Task { [weak self] in
            let result = await self?.faceUnlock.verify(timeout: 8) ?? .failure(reason: .cameraUnavailable, similarity: nil, profile: nil)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.faceOperationActive = false
                switch result {
                case .success(let similarity, let profile):
                    self.logger.info("人脸匹配成功：\(profile.name, privacy: .public)，相似度 \(self.format(similarity), privacy: .public)")
                    if requireLockedScreen {
                        self.updateStatus("识别成功，正在解锁")
                        self.tryUnlockScreen()
                    } else {
                        self.updateStatus("识别成功")
                    }
                    if showResult {
                        self.showInfo("识别成功", String(format: "%@ 的相似度 %.3f。", profile.name, similarity))
                    }
                case .failure(let reason, let similarity, _):
                    let detail = similarity.map { String(format: "，最高相似度 %.3f", $0) } ?? ""
                    self.logger.error("人脸识别失败：\(reason.message, privacy: .public)\(detail, privacy: .public)")
                    self.updateStatus("识别失败")
                    if showResult {
                        self.showInfo("识别失败", reason.message + detail)
                    }
                }
            }
        }
    }

    private func format(_ value: Float) -> String {
        String(format: "%.3f", value)
    }

    private func updateStatus(_ text: String) {
        statusItem.button?.title = text
        statusResetTimer?.invalidate()
        statusResetTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
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
                    self.scheduleFaceUnlock(after: 0.8)
                } else {
                    self.pendingFaceUnlock?.cancel()
                    self.pendingFaceUnlock = nil
                    self.cancelUnlockTimers()
                }
            }
        }
    }

    private func tryUnlockScreen(retryCount: Int = 0) {
        guard !systemSleep, !displaySleep else { return }
        guard isScreenLocked() else {
            if retryCount < wakeUnlockMaxRetries {
                scheduleWakeUnlock(after: wakeUnlockRetryDelay, retryCount: retryCount + 1)
            }
            return
        }

        wakeUnlockTimer?.invalidate()
        wakeUnlockTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self, self.isScreenLocked() else { return }
            guard let password = self.fetchPassword(warn: true) else { return }
            self.unlockedAt = Date().timeIntervalSince1970
            self.fakeKeyStrokes(password)

            if Date().timeIntervalSince1970 - self.lastWakeAt < 5, retryCount < self.wakeUnlockMaxRetries {
                self.postUnlockRetryTimer?.invalidate()
                self.postUnlockRetryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                    guard let self, self.isScreenLocked() else { return }
                    self.scheduleWakeUnlock(after: self.wakeUnlockRetryDelay, retryCount: retryCount + 1)
                }
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

        CGEvent(keyboardEventSource: source, virtualKey: 52, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 52, keyDown: false)?.post(tap: .cghidEventTap)
    }

    private func isScreenLocked() -> Bool {
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
           let locked = dict["CGSSessionScreenIsLocked"] as? Int {
            return locked == 1
        }
        return false
    }

    @objc private func enrollFace() {
        let alert = NSAlert()
        alert.messageText = "注册人脸"
        alert.informativeText = "看摄像头并缓慢左右转头，系统会在本机采集 8 个样本。"
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        nameField.placeholderString = "姓名"
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
                    self?.showInfo("注册成功", "已保存 \(profile?.name ?? name) 的人脸数据。")
                    self?.rebuildFaceProfilesMenu()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.faceOperationActive = false
                    self?.showInfo("注册失败", error.localizedDescription)
                }
            }
        }
    }

    @objc private func verifyFaceNow() {
        unlockWithFace(requireLockedScreen: false, showResult: true)
    }

    @objc private func deleteAllFaces() {
        let alert = NSAlert()
        alert.messageText = "删除所有人脸注册记录？"
        alert.informativeText = "将删除本机保存的所有人脸特征数据。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
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

    @objc private func setPassword() {
        let alert = NSAlert()
        alert.messageText = "设置登录密码"
        alert.informativeText = "密码仅保存在本机钥匙串中，用于解锁当前已登录会话。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        savePassword(field.stringValue)
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else {
            showInfo("无法设置", "此系统版本不支持应用内设置开机启动。")
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
            showInfo("设置失败", error.localizedDescription)
        }
    }

    @objc private func lockScreenNow() {
        cancelUnlockTimers()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/RemoteManagement/AppleVNCServer.bundle/Contents/Support/LockScreen.app/Contents/MacOS/LockScreen")
        try? task.run()
    }

    @objc private func showAbout() {
        AboutBox.showAboutBox()
    }

    private func rebuildFaceProfilesMenu() {
        faceProfilesMenu.removeAllItems()
        let profiles = faceUnlock.profiles
        if profiles.isEmpty {
            let item = faceProfilesMenu.addItem(withTitle: "暂无注册人脸", action: nil, keyEquivalent: "")
            item.isEnabled = false
        } else {
            for profile in profiles {
                let date = DateFormatter.localizedString(from: profile.createdAt, dateStyle: .short, timeStyle: .none)
                let item = faceProfilesMenu.addItem(withTitle: "\(profile.name)（\(date)，删除）", action: #selector(removeFaceProfile), keyEquivalent: "")
                item.representedObject = profile.id.uuidString
            }
        }
        faceProfilesMenu.addItem(.separator())
        let deleteItem = faceProfilesMenu.addItem(withTitle: "删除所有人脸", action: #selector(deleteAllFaces), keyEquivalent: "")
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
            let item = cameraMenu.addItem(withTitle: "没有可用摄像头", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return
        }
        for camera in cameras {
            let item = cameraMenu.addItem(withTitle: camera.localizedName, action: #selector(setFaceCamera), keyEquivalent: "")
            item.representedObject = camera.uniqueID
            item.state = faceUnlock.cameraID == camera.uniqueID ? .on : .off
        }
    }

    private func showInfo(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func checkAccessibilityPermission() {
        let options: CFDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(options) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.showInfo("需要辅助功能权限", "请在系统设置的隐私与安全性中允许 macOSHello 控制键盘。")
        }
    }

    private func savePassword(_ password: String) {
        guard !password.isEmpty else {
            showInfo("密码为空", "请输入有效的登录密码。")
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
        showInfo(status == errSecSuccess ? "已保存密码" : "保存失败", status == errSecSuccess ? "密码已保存到本机钥匙串。" : "钥匙串写入错误：\(status)")
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
            if warn { showInfo("尚未设置密码", "请先在菜单中设置登录密码。") }
            return nil
        }
        return password
    }
}
