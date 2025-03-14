import Cocoa

class Window {
    static var globalCreationCounter = Int.zero
    var cgWindowId: CGWindowID?
    var lastFocusOrder = Int.zero
    var creationOrder = Int.zero
    var title: String!
    var thumbnail: NSImage?
    var thumbnailFullSize: NSSize?
    var icon: NSImage? { get { application.icon } }
    var shouldShowTheUser = true
    var isTabbed: Bool = false
    var isHidden: Bool { get { application.isHidden } }
    var dockLabel: String? { get { application.dockLabel } }
    var isFullscreen = false
    var isMinimized = false
    var isOnAllSpaces = false
    var isWindowlessApp = false
    var position: CGPoint?
    var size: CGSize?
    var spaceId = CGSSpaceID.max
    var spaceIndex = SpaceIndex.max
    var axUiElement: AXUIElement!
    var application: Application
    var axObserver: AXObserver?
    var rowIndex: Int?
    
    var spaceIds = [UInt64]()
    var isNormal = true

    static let notifications = [
        kAXUIElementDestroyedNotification,
        kAXTitleChangedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXWindowResizedNotification,
        kAXWindowMovedNotification,
    ]

    init(_ axUiElement: AXUIElement, _ application: Application, _ wid: CGWindowID, _ axTitle: String?, _ isFullscreen: Bool, _ isMinimized: Bool, _ position: CGPoint?, _ size: CGSize?) {
        let subRole = try? axUiElement.subrole()
        self.isNormal = subRole == "AXStandardWindow"
        // TODO: make a efficient batched AXUIElementCopyMultipleAttributeValues call once for each window, and store the values
        self.axUiElement = axUiElement
        self.application = application
        cgWindowId = wid
        debugPrint("33init")
        spaceId = Spaces.currentSpaceId
        spaceIndex = Spaces.currentSpaceIndex
        self.isFullscreen = isFullscreen
        self.isMinimized = isMinimized
        self.position = position
        self.size = size
        title = bestEffortTitle(axTitle)
        Window.globalCreationCounter += 1
        creationOrder = Window.globalCreationCounter
        application.removeWindowslessAppWindow()
        checkIfFocused(application, wid)
        Logger.debug("Adding window", cgWindowId ?? "nil", title ?? "nil", application.bundleIdentifier ?? "nil")
        observeEvents()
    }

    init(_ application: Application) {
        isWindowlessApp = true
        self.application = application
        title = application.localizedName
        Window.globalCreationCounter += 1
        creationOrder = Window.globalCreationCounter
        Logger.debug(title ?? "nil", application.bundleIdentifier ?? "nil")
    }

    deinit {
        Logger.debug(title ?? "nil", application.bundleIdentifier ?? "nil")
    }

    /// some apps will not trigger AXApplicationActivated, where we usually update application.focusedWindow
    /// workaround: we check and possibly do it here
    func checkIfFocused(_ application: Application, _ wid: CGWindowID) {
        retryAxCallUntilTimeout {
            let focusedWid = try application.axUiElement?.focusedWindow()?.cgWindowId()
            if wid == focusedWid {
                application.focusedWindow = self
            }
        }
    }

    func isEqualRobust(_ otherWindowAxUiElement: AXUIElement, _ otherWindowWid: CGWindowID?) -> Bool {
        // the window can be deallocated by the OS, in which case its `CGWindowID` will be `-1`
        // we check for equality both on the AXUIElement, and the CGWindowID, in order to catch all scenarios
        return otherWindowAxUiElement == axUiElement || (cgWindowId != nil && cgWindowId != CGWindowID(bitPattern: -1) && otherWindowWid == cgWindowId)
    }

    private func observeEvents() {
        AXObserverCreate(application.pid, axObserverCallback, &axObserver)
        guard let axObserver else { return }
        for notification in Window.notifications {
            retryAxCallUntilTimeout { [weak self] in
                guard let self else { return }
                try self.axUiElement.subscribeToNotification(axObserver, notification, nil)
            }
        }
        CFRunLoopAddSource(BackgroundWork.accessibilityEventsThread.runLoop, AXObserverGetRunLoopSource(axObserver), .commonModes)
    }

    func refreshThumbnail(_ screenshot: NSImage) {
        thumbnail = screenshot
        thumbnailFullSize = screenshot.size
        if !App.app.appIsBeingUsed || !shouldShowTheUser { return }
        if let view = (ThumbnailsView.recycledViews.first { $0.window_?.cgWindowId == cgWindowId }) {
            if !view.thumbnail.isHidden {
                view.thumbnail.image = thumbnail?.copyToSeparateContexts()
                let thumbnailSize = ThumbnailView.thumbnailSize(thumbnail, false)
                view.thumbnail.setSize(thumbnailSize)
            }
            App.app.previewPanel.updateImageIfShowing(cgWindowId, screenshot, screenshot.size)
        }
    }

    func canBeClosed() -> Bool {
        return !isWindowlessApp
    }

    func close() {
        if !canBeClosed() {
            NSSound.beep()
            return
        }
        BackgroundWork.accessibilityCommandsQueue.async { [weak self] in
            guard let self else { return }
            if self.isFullscreen {
                self.axUiElement.setAttribute(kAXFullscreenAttribute, false)
            }
            if let closeButton_ = try? self.axUiElement.closeButton() {
                closeButton_.performAction(kAXPressAction)
            }
        }
    }

    func canBeMinDeminOrFullscreened() -> Bool {
        return !isWindowlessApp && !isTabbed
    }

    func minDemin() {
        if !canBeMinDeminOrFullscreened() {
            NSSound.beep()
            return
        }
        BackgroundWork.accessibilityCommandsQueue.async { [weak self] in
            guard let self else { return }
            if self.isFullscreen {
                self.axUiElement.setAttribute(kAXFullscreenAttribute, false)
                // minimizing is ignored if sent immediatly; we wait for the de-fullscreen animation to be over
                BackgroundWork.accessibilityCommandsQueue.asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
                    guard let self else { return }
                    self.axUiElement.setAttribute(kAXMinimizedAttribute, true)
                }
            } else {
                self.axUiElement.setAttribute(kAXMinimizedAttribute, !self.isMinimized)
            }
        }
    }

    func toggleFullscreen() {
        if !canBeMinDeminOrFullscreened() {
            NSSound.beep()
            return
        }
        BackgroundWork.accessibilityCommandsQueue.async { [weak self] in
            guard let self else { return }
            self.axUiElement.setAttribute(kAXFullscreenAttribute, !self.isFullscreen)
        }
    }

    func focus() {
        let bundleUrl = application.bundleURL
        if bundleUrl == App.bundleURL {
            App.shared.activate(ignoringOtherApps: true)
            App.app.window(withWindowNumber: Int(cgWindowId!))?.makeKeyAndOrderFront(nil)
            Windows.previewFocusedWindowIfNeeded()
        } else if isWindowlessApp || cgWindowId == nil || Preferences.onlyShowApplications() {
            if let bundleUrl, isWindowlessApp {
                if (try? NSWorkspace.shared.launchApplication(at: bundleUrl, configuration: [:])) == nil {
                    application.runningApplication.activate(options: .activateAllWindows)
                }
            } else {
                application.runningApplication.activate(options: .activateAllWindows)
            }
            Windows.previewFocusedWindowIfNeeded()
        } else {
            // macOS bug: when switching to a System Preferences window in another space, it switches to that space,
            // but quickly switches back to another window in that space
            // You can reproduce this buggy behaviour by clicking on the dock icon, proving it's an OS bug
            BackgroundWork.accessibilityCommandsQueue.async { [weak self] in
                guard let self else { return }
                var psn = ProcessSerialNumber()
                GetProcessForPID(self.application.pid, &psn)
                _SLPSSetFrontProcessWithOptions(&psn, self.cgWindowId!, SLPSMode.userGenerated.rawValue)
                self.makeKeyWindow(psn)
                self.axUiElement.focusWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
                    Windows.previewFocusedWindowIfNeeded()
                }
            }
        }
    }

    /// The following function was ported from https://github.com/Hammerspoon/hammerspoon/issues/370#issuecomment-545545468
    func makeKeyWindow(_ psn: ProcessSerialNumber) -> Void {
        var psn_ = psn
        var bytes1 = [UInt8](repeating: 0, count: 0xf8)
        bytes1[0x04] = 0xF8
        bytes1[0x08] = 0x01
        bytes1[0x3a] = 0x10
        var bytes2 = [UInt8](repeating: 0, count: 0xf8)
        bytes2[0x04] = 0xF8
        bytes2[0x08] = 0x02
        bytes2[0x3a] = 0x10
        memcpy(&bytes1[0x3c], &cgWindowId, MemoryLayout<UInt32>.size)
        memset(&bytes1[0x20], 0xFF, 0x10)
        memcpy(&bytes2[0x3c], &cgWindowId, MemoryLayout<UInt32>.size)
        memset(&bytes2[0x20], 0xFF, 0x10)
        [bytes1, bytes2].forEach { bytes in
            _ = bytes.withUnsafeBufferPointer { pointer in
                SLPSPostEventRecordTo(&psn_, &UnsafeMutablePointer(mutating: pointer.baseAddress)!.pointee)
            }
        }
    }

    // for some windows (e.g. Slack), the AX API doesn't return a title; we try CG API; finally we resort to the app name
    func bestEffortTitle(_ axTitle: String?) -> String {
        if let axTitle, !axTitle.isEmpty {
            return axTitle
        }
        if let cgWindowId, let cgTitle = cgWindowId.title(), !cgTitle.isEmpty {
            return cgTitle
        }
        return application.localizedName ?? ""
    }

    func isOnScreen(_ screen: NSScreen) -> Bool {
        if NSScreen.screensHaveSeparateSpaces {
            if let screenUuid = screen.uuid(), let screenSpaces = Spaces.screenSpacesMap[screenUuid] {
                debugPrint("22|",spaceId,screen,screenSpaces,title!)
                for v1 in screenSpaces {
                    for v2 in spaceIds {
                        if v1 == v2 {
                            return true
                        }
                    }
                }
                return false
//                return screenSpaces.contains { $0 == spaceId }
            }
        } else {
            let referenceWindow = referenceWindowForTabbedWindow()
            if let topLeftCorner = referenceWindow?.position, let size = referenceWindow?.size {
                var screenFrameInQuartzCoordinates = screen.frame
                screenFrameInQuartzCoordinates.origin.y = NSMaxY(NSScreen.screens[0].frame) - NSMaxY(screen.frame)
                let windowRect = CGRect(origin: topLeftCorner, size: size)
                return windowRect.intersects(screenFrameInQuartzCoordinates)
            }
        }
        return true
    }

    func referenceWindowForTabbedWindow() -> Window? {
        // if the window is tabbed, we can't know its position/size before it's focused, so we use the currently
        // visible window-tab. Its data will match the tabbed window's
        // TODO: handle the case where the app has multiple window-groups. In that case, we need to find the right
        //       window-group, instead of picking the focused one
        return isTabbed ? application.focusedWindow : self
    }

    // Determines if this window is the main application window
    func isAppMainWindow() -> Bool {
        if let element = application.axUiElement {
            var mainWindow: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &mainWindow) == .success {
                if let mainWin = mainWindow as! AXUIElement? {
                    do {
                        let w1 = try mainWin.cgWindowId()
                        let w2 = try axUiElement.cgWindowId()
                        if w1 == w2 {
                            return true
                        }
                    } catch {
                        return false
                    }
                }
            }
        }
        return false
    }
}
