import AppKit
import QuartzCore
import SwiftUI
import UserNotifications

@MainActor
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Borderless panels are otherwise pushed below the menu bar even when
        // their frame is explicitly anchored to the display edge. The compact
        // notch surface intentionally occupies that obscured top strip.
        frameRect
    }
}

@MainActor
final class IslandContainerView: NSView {
    var hoverDidChange: ((Bool) -> Void)?
    var fileDragDidChange: ((Bool) -> Void)?
    var fileDropHandler: (([URL]) -> Bool)?
    var headerSizeProvider: (() -> CGSize)?
    private(set) var bodyView: NSView?
    private(set) var headerView: NSView?
    private var islandTrackingArea: NSTrackingArea?

    func install(bodyView: NSView, headerView: NSView) {
        self.bodyView?.removeFromSuperview()
        self.headerView?.removeFromSuperview()
        self.bodyView = bodyView
        self.headerView = headerView
        addSubview(bodyView)
        addSubview(headerView, positioned: .above, relativeTo: bodyView)
        registerForDraggedTypes([.fileURL])
        needsLayout = true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else { return [] }
        fileDragDidChange?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else {
            fileDragDidChange?(false)
            return []
        }
        fileDragDidChange?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        fileDragDidChange?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        fileDragDidChange?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        let wasHandled = !urls.isEmpty && (fileDropHandler?(urls) ?? false)
        fileDragDidChange?(false)
        return wasHandled
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let values = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [NSURL]
        return values?.map { $0 as URL } ?? []
    }

    override func layout() {
        super.layout()
        bodyView?.frame = bounds

        guard let headerView, let headerSize = headerSizeProvider?() else { return }
        headerView.frame = NSRect(
            x: bounds.midX - headerSize.width / 2,
            y: bounds.maxY - headerSize.height,
            width: headerSize.width,
            height: headerSize.height
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let islandTrackingArea {
            removeTrackingArea(islandTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        islandTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        hoverDidChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hoverDidChange?(false)
    }
}

private struct PanelFrameAnimation {
    let startFrame: NSRect
    let targetFrame: NSRect
    let startTime: CFTimeInterval
    let duration: CFTimeInterval
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = IslandModel()
    private let coreClient = AgentCoreClient()
    private let volumeKeyTap = VolumeKeyTap()
    private let audioMonitor: AudioMonitoring = AudioMonitor()
    private let notificationCenter = UNUserNotificationCenter.current()
    private var panel: IslandPanel?
    private var statusItem: NSStatusItem?
    private var isPanelSuppressedForFullscreen = false
    private var lastPanelSize = CGSize.zero
    private var hoverCloseWorkItem: DispatchWorkItem?
    private var hoverOpenWorkItem: DispatchWorkItem?
    private var fullscreenEvaluationGeneration: UInt = 0
    private var frameAnimationTimer: Timer?
    private var frameAnimation: PanelFrameAnimation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.layoutDidChange = { [weak self] in
            self?.updatePanelFrame(animated: true)
            self?.updateStatusItemPresentation()
        }
        model.visibilityDidChange = { [weak self] in
            self?.applyVisibility()
        }
        model.phaseDidChange = { [weak self] previousPhase, nextPhase in
            self?.handlePhaseChange(from: previousPhase, to: nextPhase)
        }
        model.sessionDidChange = { [weak self] session, previousPhase in
            self?.handleSessionChange(session, previousPhase: previousPhase)
        }

        configurePanel()
        configureStatusItem()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspacePresentationChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspacePresentationChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        scheduleFullscreenEvaluations()
        requestNotificationPermission()
        coreClient.start(model: model)
        audioMonitor.delegate = model
        audioMonitor.start()
        model.visualizerEnabledDidChange = { [weak self] enabled in
            self?.audioMonitor.setVisualizerEnabled(enabled)
        }
        // Returns whether the tap is actually running, so the toggle can never
        // sit "on" while macOS is still drawing its own overlay.
        model.volumeHUDSuppressionDidChange = { [weak self] enabled in
            guard let self else { return false }
            guard enabled else {
                self.volumeKeyTap.stop()
                return false
            }
            if !VolumeKeyTap.hasAccessibilityPermission() {
                VolumeKeyTap.requestAccessibilityPermission()
            }
            return self.volumeKeyTap.start()
        }
        if model.suppressSystemVolumeHUD {
            _ = volumeKeyTap.start()
        }
        if model.musicVisualizerEnabled {
            audioMonitor.setVisualizerEnabled(true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopPanelFrameAnimation()
        cancelFullscreenEvaluations()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        coreClient.stop()
        volumeKeyTap.stop()
        audioMonitor.stop()
        model.temporaryFileShelf.shutdown()
    }

    private func configurePanel() {
        if let screen = targetScreen() {
            model.setNotchPresentation(notchPresentation(for: screen))
        }
        let size = model.preferredSize.cgSize
        let panel = IslandPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        let containerView = IslandContainerView(frame: NSRect(origin: .zero, size: size))
        containerView.headerSizeProvider = { [weak self] in
            self?.model.persistentHeaderSize.cgSize ?? .zero
        }
        containerView.hoverDidChange = { [weak self] isInside in
            self?.handleHoverChange(isInside)
        }
        containerView.fileDragDidChange = { [weak self] isTargeted in
            guard let self else { return }
            self.model.setFileDragTargeted(isTargeted)
            if isTargeted {
                self.hoverCloseWorkItem?.cancel()
                self.hoverCloseWorkItem = nil
                self.model.setHovered(true)
            } else if let panel = self.panel {
                self.model.setHovered(panel.frame.contains(NSEvent.mouseLocation))
            }
        }
        containerView.fileDropHandler = { [weak self] urls in
            guard let self else { return false }
            return self.model.temporaryFileShelf.accept(urls)
        }

        let bodyHostingView = NSHostingView(rootView: IslandRootView(model: model))
        let headerHostingView = NSHostingView(rootView: IslandHeaderView(model: model))
        containerView.install(bodyView: bodyHostingView, headerView: headerHostingView)
        panel.contentView = containerView

        self.panel = panel
        lastPanelSize = size
        updatePanelFrame(animated: false)
    }

    private func handleHoverChange(_ isInside: Bool) {
        if isInside {
            handleHoverIn()
        } else {
            handleHoverOut()
        }
    }

    private func handleHoverIn() {
        hoverCloseWorkItem?.cancel()
        hoverCloseWorkItem = nil

        let delay = model.hoverOpenDelay
        guard delay > 0 else {
            hoverOpenWorkItem?.cancel()
            hoverOpenWorkItem = nil
            model.setHovered(true)
            return
        }

        // Wait out the configured open delay, then confirm the cursor is still on
        // the island before expanding so a quick pass-over does not pop it open.
        hoverOpenWorkItem?.cancel()
        let openWorkItem = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            let forgivingFrame = panel.frame.insetBy(dx: -8, dy: -8)
            guard forgivingFrame.contains(NSEvent.mouseLocation) else { return }
            self.model.setHovered(true)
        }
        hoverOpenWorkItem = openWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: openWorkItem)
    }

    private func handleHoverOut() {
        hoverOpenWorkItem?.cancel()
        hoverOpenWorkItem = nil
        hoverCloseWorkItem?.cancel()
        hoverCloseWorkItem = nil

        // Resizing a window can briefly emit mouseExited. Validate the real cursor
        // position after the expand animation settles before collapsing it.
        let closeWorkItem = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            let forgivingFrame = panel.frame.insetBy(dx: -8, dy: -8)
            guard !forgivingFrame.contains(NSEvent.mouseLocation) else { return }
            self.model.setHovered(false)
        }
        hoverCloseWorkItem = closeWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + model.hoverCloseDelay, execute: closeWorkItem)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "sparkles",
                accessibilityDescription: "Agent Island"
            )
            button.toolTip = "Agent Island"
        }

        let menu = NSMenu(title: "Agent Island")
        menu.delegate = self

        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let versionItem = NSMenuItem(
            title: "Agent Island \(shortVersion) (\(buildVersion))",
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Show or Hide Island", action: #selector(toggleIsland), keyEquivalent: "i"))
        menu.addItem(NSMenuItem(title: "Pin Expanded", action: #selector(togglePinned), keyEquivalent: "p"))
        menu.addItem(.separator())

        let providerItem = NSMenuItem(title: "Agent", action: nil, keyEquivalent: "")
        let providerMenu = NSMenu(title: "Agent")
        for provider in AgentProvider.allCases {
            let option = NSMenuItem(title: provider.displayName, action: #selector(selectProvider(_:)), keyEquivalent: "")
            option.representedObject = provider.rawValue
            providerMenu.addItem(option)
        }
        providerItem.submenu = providerMenu
        menu.addItem(providerItem)

        let stateItem = NSMenuItem(title: "Preview State", action: nil, keyEquivalent: "")
        let stateMenu = NSMenu(title: "Preview State")
        let shortcuts = ["1", "2", "3", "4"]
        for (index, phase) in AgentPhase.allCases.enumerated() {
            let option = NSMenuItem(title: phase.label.capitalized, action: #selector(selectPhase(_:)), keyEquivalent: shortcuts[index])
            option.representedObject = phase.rawValue
            stateMenu.addItem(option)
        }
        stateItem.submenu = stateMenu
        menu.addItem(stateItem)

        menu.addItem(NSMenuItem(title: "Use Automatic Detection", action: #selector(resumeMonitoring), keyEquivalent: "a"))
        menu.addItem(NSMenuItem(title: "Enable Claude Live Metrics…", action: #selector(toggleClaudeMetrics), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Agent Island", action: #selector(quit), keyEquivalent: "q"))

        for menuItem in menu.items where menuItem.action != nil {
            menuItem.target = self
        }
        for submenu in menu.items.compactMap(\.submenu) {
            for menuItem in submenu.items { menuItem.target = self }
        }

        item.menu = menu
        statusItem = item
        updateStatusItemPresentation()
    }

    func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items {
            if item.title == "Pin Expanded" {
                item.state = model.isPinnedOpen ? .on : .off
            }
            if item.title == "Use Automatic Detection" {
                item.state = model.monitoringEnabled ? .on : .off
            }
            if item.action == #selector(toggleClaudeMetrics) {
                item.title = ClaudeMetricsBridge.isInstalled
                    ? "Disable Claude Live Metrics"
                    : "Enable Claude Live Metrics…"
            }
        }

        for submenu in menu.items.compactMap(\.submenu) {
            for item in submenu.items {
                guard let value = item.representedObject as? String else { continue }
                if AgentProvider(rawValue: value) != nil {
                    item.state = value == model.provider.rawValue ? .on : .off
                } else if AgentPhase(rawValue: value) != nil {
                    item.state = value == model.phase.rawValue ? .on : .off
                }
            }
        }
    }

    private func updatePanelFrame(animated: Bool) {
        guard let panel, let screen = targetScreen() else { return }
        model.setNotchPresentation(notchPresentation(for: screen))

        var size = model.preferredSize.cgSize
        size.width = min(size.width, screen.frame.width - 24)
        size.height = min(size.height, screen.frame.height - 24)
        let topEdge = model.isNotchAttached
            ? screen.frame.maxY
            : screen.visibleFrame.maxY - 5
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: topEdge - size.height
        )
        let frame = NSRect(origin: origin, size: size)
        let sizeChanged = lastPanelSize != size
        lastPanelSize = size

        // Agent heartbeat and drag-target callbacks can update labels/state while
        // an expansion is already moving toward this exact frame. Do not cancel
        // that in-flight spring merely because the requested size is unchanged.
        if animated, !sizeChanged, frameAnimation != nil {
            return
        }

        // A same-size update with no active spring still needs an exact frame in
        // case the screen origin changed. Non-animated callers always snap safely.
        guard animated, sizeChanged else {
            stopPanelFrameAnimation()
            panel.setFrame(frame, display: true)
            return
        }

        animatePanelFrame(to: frame)
    }

    private func notchPresentation(for screen: NSScreen) -> NotchPresentation? {
        let topInset = screen.safeAreaInsets.top
        guard topInset >= 24,
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else {
            return nil
        }

        let cameraWidth = rightArea.minX - leftArea.maxX
        guard cameraWidth >= 80, cameraWidth < screen.frame.width * 0.45 else {
            return nil
        }

        // The compact surface adds only two small status wings around the camera
        // housing. This keeps the app fused to the physical notch without laying a
        // wide invisible panel over normal menu-bar controls.
        let availableWingWidth = min(leftArea.width, rightArea.width)
        let wingWidth = min(max(availableWingWidth * 0.22, 76), 96)
        let compactWidth = min(cameraWidth + wingWidth * 2, 360)
        return NotchPresentation(
            cameraWidth: cameraWidth.rounded(.up),
            barHeight: topInset.rounded(.up),
            compactWidth: compactWidth.rounded(.up)
        )
    }

    private func animatePanelFrame(to targetFrame: NSRect) {
        guard let panel else { return }
        stopPanelFrameAnimation()

        let startFrame = panel.frame
        let isExpanding = targetFrame.height > startFrame.height
        frameAnimation = PanelFrameAnimation(
            startFrame: startFrame,
            targetFrame: targetFrame,
            startTime: CACurrentMediaTime(),
            duration: isExpanding ? 0.38 : 0.28
        )

        let displayRefreshRate = targetScreen()?.maximumFramesPerSecond ?? 60
        let frameRate = Double(min(max(displayRefreshRate, 60), 120))
        let timer = Timer(
            timeInterval: 1.0 / frameRate,
            target: self,
            selector: #selector(stepPanelFrameAnimation(_:)),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 1.0 / (frameRate * 4)
        RunLoop.main.add(timer, forMode: .common)
        frameAnimationTimer = timer
    }

    @objc private func stepPanelFrameAnimation(_ timer: Timer) {
        guard let panel, let animation = frameAnimation else {
            stopPanelFrameAnimation()
            return
        }

        let elapsed = CACurrentMediaTime() - animation.startTime
        if elapsed >= animation.duration {
            panel.setFrame(animation.targetFrame, display: true)
            stopPanelFrameAnimation()
            return
        }

        let normalizedTime = elapsed / animation.duration
        let progress = springProgress(at: normalizedTime)
        let frame = NSRect(
            x: interpolate(animation.startFrame.minX, animation.targetFrame.minX, progress),
            y: interpolate(animation.startFrame.minY, animation.targetFrame.minY, progress),
            width: interpolate(animation.startFrame.width, animation.targetFrame.width, progress),
            height: interpolate(animation.startFrame.height, animation.targetFrame.height, progress)
        )
        panel.setFrame(frame, display: true)
    }

    private func springProgress(at normalizedTime: Double) -> CGFloat {
        // A lightly under-damped second-order response gives the small overshoot
        // and soft settle associated with Dynamic Island, without a long bounce.
        let dampingRatio = 0.84
        let naturalFrequency = 14.0
        let dampedRoot = sqrt(1 - dampingRatio * dampingRatio)
        let dampedFrequency = naturalFrequency * dampedRoot
        let decay = exp(-dampingRatio * naturalFrequency * normalizedTime)
        let response = 1 - decay * (
            cos(dampedFrequency * normalizedTime)
                + dampingRatio / dampedRoot * sin(dampedFrequency * normalizedTime)
        )
        return CGFloat(response)
    }

    private func interpolate(_ start: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
        start + (end - start) * progress
    }

    private func stopPanelFrameAnimation() {
        frameAnimationTimer?.invalidate()
        frameAnimationTimer = nil
        frameAnimation = nil
    }

    private func targetScreen() -> NSScreen? {
        if let panelScreen = panel?.screen { return panelScreen }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func applyVisibility() {
        guard let panel else { return }
        if model.isVisible, !isPanelSuppressedForFullscreen {
            model.setAnimationsEnabled(true)
            updatePanelFrame(animated: false)
            panel.orderFrontRegardless()
        } else {
            model.setAnimationsEnabled(false)
            stopPanelFrameAnimation()
            panel.orderOut(nil)
        }
    }

    @objc private func screenConfigurationChanged() {
        updatePanelFrame(animated: false)
        scheduleFullscreenEvaluations()
    }

    @objc private func workspacePresentationChanged() {
        scheduleFullscreenEvaluations()
    }

    private func scheduleFullscreenEvaluations() {
        fullscreenEvaluationGeneration &+= 1
        let generation = fullscreenEvaluationGeneration
        evaluateFullscreenPresentation()
        applyVisibility()

        // App and Space notifications can arrive before a full-screen animation
        // has committed its final window bounds. A few short, finite rechecks catch
        // that transition without leaving a permanent polling timer running.
        for delay in [0.35, 1.1] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.fullscreenEvaluationGeneration == generation else { return }
                self.evaluateFullscreenPresentation()
            }
        }
    }

    private func cancelFullscreenEvaluations() {
        fullscreenEvaluationGeneration &+= 1
    }

    private func evaluateFullscreenPresentation() {
        let shouldSuppress = activeExternalApplicationHasFullscreenWindow()
        guard shouldSuppress != isPanelSuppressedForFullscreen else { return }
        isPanelSuppressedForFullscreen = shouldSuppress
        applyVisibility()
        updateStatusItemPresentation()
    }

    private func activeExternalApplicationHasFullscreenWindow() -> Bool {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        // Opening this menu-bar app's own menu can temporarily make it frontmost.
        // Preserve the current decision until another app becomes frontmost so a
        // menu click cannot reveal the panel over a game.
        if frontmostApplication.processIdentifier == ProcessInfo.processInfo.processIdentifier
            || frontmostApplication.bundleIdentifier == Bundle.main.bundleIdentifier {
            return isPanelSuppressedForFullscreen
        }

        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else {
            return false
        }

        let frontmostPID = Int(frontmostApplication.processIdentifier)
        return windowList.contains { windowInfo in
            guard (windowInfo[kCGWindowOwnerPID as String] as? Int) == frontmostPID,
                  (windowInfo[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
                return false
            }
            return windowBoundsCoverDisplay(bounds)
        }
    }

    private func windowBoundsCoverDisplay(_ bounds: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            let displaySize = screen.frame.size
            let widthTolerance = max(3, displaySize.width * 0.01)
            let heightTolerance = max(3, displaySize.height * 0.01)
            return abs(bounds.width - displaySize.width) <= widthTolerance
                && abs(bounds.height - displaySize.height) <= heightTolerance
        }
    }

    private func requestNotificationPermission() {
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func handlePhaseChange(from previousPhase: AgentPhase, to nextPhase: AgentPhase) {
        evaluateFullscreenPresentation()
        updateStatusItemPresentation()

        guard previousPhase != .complete,
              nextPhase == .complete,
              model.sessions.isEmpty,
              isPanelSuppressedForFullscreen else { return }
        postCompletionNotification()
    }

    private func handleSessionChange(
        _ session: AgentSessionSnapshot,
        previousPhase: AgentPhase
    ) {
        evaluateFullscreenPresentation()
        updateStatusItemPresentation()
        guard isPanelSuppressedForFullscreen else { return }

        if session.state == .complete, previousPhase != .complete {
            postSessionNotification(
                session,
                title: "\(session.provider.displayName) finished",
                fallbackBody: "Changes are ready to review."
            )
        } else if session.state == .question, previousPhase != .question {
            postSessionNotification(
                session,
                title: "\(session.provider.displayName) needs your input",
                fallbackBody: "Open the tracked session to answer."
            )
        }
    }

    private func postCompletionNotification() {
        let content = UNMutableNotificationContent()
        content.title = "\(model.provider.displayName) finished"
        if let workspacePath = model.workspacePath {
            let project = URL(fileURLWithPath: workspacePath).lastPathComponent
            content.body = project.isEmpty ? model.task : "Completed in \(project)."
        } else {
            content.body = model.task
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "agent-island-complete-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        notificationCenter.add(request)
    }

    private func postSessionNotification(
        _ session: AgentSessionSnapshot,
        title: String,
        fallbackBody: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = session.projectName == "Unknown project"
            ? fallbackBody
            : "\(session.projectName) · \(fallbackBody)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "agent-island-\(session.state.rawValue)-\(session.id)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        notificationCenter.add(request)
    }

    private func updateStatusItemPresentation() {
        guard let button = statusItem?.button else { return }
        let symbolName: String
        switch model.aggregatePhase {
        case .idle: symbolName = "moon.zzz"
        case .thinking: symbolName = "sparkles"
        case .question: symbolName = "questionmark.circle.fill"
        case .complete: symbolName = "checkmark.circle.fill"
        }

        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Agent Island: \(model.aggregatePhase.label.lowercased())"
        )
        let project = model.workspacePath.map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
        let location = project.map { " · \($0)" } ?? ""
        let fullscreenState = isPanelSuppressedForFullscreen ? " · panel hidden for full screen" : ""
        let sessionCount = model.sessions.isEmpty ? "" : " · \(model.sessions.count) sessions"
        button.toolTip = "\(model.provider.displayName) · \(model.aggregatePhase.label.lowercased())\(sessionCount)\(location)\(fullscreenState)"
    }

    @objc private func toggleIsland() {
        model.toggleVisibility()
    }

    @objc private func togglePinned() {
        model.togglePinned()
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let provider = AgentProvider(rawValue: rawValue) else { return }
        model.setProvider(provider)
    }

    @objc private func selectPhase(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let phase = AgentPhase(rawValue: rawValue) else { return }
        model.setPhase(phase)
    }

    @objc private func resumeMonitoring() {
        model.resumeAutomaticMonitoring()
    }

    @objc private func toggleClaudeMetrics() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        if ClaudeMetricsBridge.isInstalled {
            do {
                try ClaudeMetricsBridge.disable()
                showBridgeResult(
                    title: "Claude live metrics disabled",
                    message: "Claude's status-line setting was removed. The local helper and cache contain no prompts or credentials and may remain on disk."
                )
            } catch {
                showBridgeError(error)
            }
            return
        }

        let confirmation = NSAlert()
        confirmation.messageText = "Enable Claude live metrics?"
        confirmation.informativeText = "Agent Island will add a Claude Code status-line command that sends local context and rate-limit numbers to the app. It does not use an API key or send data over the network."
        confirmation.addButton(withTitle: "Enable")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        do {
            try ClaudeMetricsBridge.install()
            showBridgeResult(
                title: "Claude live metrics enabled",
                message: "Claude will update Agent Island after its next response. Restart Claude Code if the status line does not refresh."
            )
        } catch {
            showBridgeError(error)
        }
    }

    private func showBridgeResult(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showBridgeError(_ error: Error) {
        showBridgeResult(
            title: "Claude metrics were not changed",
            message: error.localizedDescription
        )
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
