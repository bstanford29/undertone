import AppKit
import Combine
import SwiftUI

/// A nonactivating panel that the user drags by its background. The panel
/// never becomes key or main, so a click on it cannot steal focus from the
/// frontmost app. Mouse tracking happens in `sendEvent` so the SwiftUI
/// content cannot swallow the drag.
final class DraggablePillPanel: NSPanel {
    /// Mouse-down inside the panel, with the cursor in screen coordinates.
    var onDragBegin: ((CGPoint) -> Void)?
    /// Cursor moved while the button is down.
    var onDragMove: ((CGPoint) -> Void)?
    /// Mouse-up, ending the drag.
    var onDragEnd: ((CGPoint) -> Void)?
    /// Escape pressed while dragging.
    var onDragCancel: (() -> Void)?

    private var isTracking = false

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            isTracking = true
            onDragBegin?(NSEvent.mouseLocation)
            return
        case .leftMouseDragged where isTracking:
            onDragMove?(NSEvent.mouseLocation)
            return
        case .leftMouseUp where isTracking:
            isTracking = false
            onDragEnd?(NSEvent.mouseLocation)
            return
        case .keyDown where isTracking && event.keyCode == 53:
            isTracking = false
            onDragCancel?()
            return
        default:
            break
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53, isTracking else {
            super.keyDown(with: event)
            return
        }
        isTracking = false
        onDragCancel?()
    }

    /// Stops tracking when the drag is cancelled from outside the panel,
    /// for example by the controller's Escape monitor.
    func stopTracking() {
        isTracking = false
    }
}

/// Hosts the dock's SwiftUI content and reports where the pointer is. The
/// tracking area is `.activeAlways` because the panel is never key: without
/// it the dock would only open while Undertone is the frontmost app.
final class DockTrackingView: NSView {
    /// The pointer in panel coordinates, or nil once it leaves the panel.
    var onPointer: ((CGPoint?) -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { report(event) }
    override func mouseMoved(with event: NSEvent) { report(event) }
    override func mouseExited(with event: NSEvent) { onPointer?(nil) }

    private func report(_ event: NSEvent) {
        onPointer?(convert(event.locationInWindow, from: nil))
    }
}

/// A transparent, click-through panel that never activates. It hosts the
/// drop-zone outlines shown behind the pill during a drag.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Everything the dock's views read that is not in `AppModel`: where the
/// pointer is, whether the controls are fanned out, and the drag chrome.
@MainActor
final class FlowBarChrome: ObservableObject {
    @Published var hovered: DockControl?
    @Published var open = false
    @Published var lifted = false
    @Published var pulse: CGFloat = 1.0

    var scale: CGFloat { (lifted ? 1.06 : 1.0) * pulse }
}

/// The four drop zones and which one is armed.
@MainActor
final class DropZoneChrome: ObservableObject {
    @Published var zones: [PillDropZone] = []
    @Published var armedEdge: PillEdge?
    @Published var visible = false
    /// The screen frame the zone rects are expressed in.
    @Published var screenFrame: CGRect = .zero
}

/// Shows the drop-zone outlines on the screen under the cursor while the
/// pill is dragged.
@MainActor
final class DropZoneOverlayController {
    private let chrome = DropZoneChrome()
    private let panel: OverlayPanel

    init() {
        panel = OverlayPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        // One level below the pill so the pill always draws on top.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: DropZoneOverlayView(chrome: chrome))
    }

    /// Places the overlay on `screen` and fades the zones in.
    func show(zones: [PillDropZone], on screen: NSScreen) {
        chrome.zones = zones
        chrome.armedEdge = nil
        chrome.screenFrame = screen.frame
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        chrome.visible = true
    }

    func setArmed(_ edge: PillEdge?) {
        guard chrome.armedEdge != edge else { return }
        chrome.armedEdge = edge
    }

    /// Fades the zones out, then hides the panel.
    func hide() {
        guard chrome.visible else { return }
        chrome.visible = false
        chrome.armedEdge = nil
        let panel = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }
}

/// Capsule outlines at the four docked positions, drawn in the overlay
/// panel's top-left coordinate space.
struct DropZoneOverlayView: View {
    @ObservedObject var chrome: DropZoneChrome

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(chrome.zones) { zone in
                let armed = chrome.armedEdge == zone.edge
                RoundedRectangle(cornerRadius: min(zone.rect.width, zone.rect.height) / 2, style: .continuous)
                    .fill(Color.white.opacity(armed ? 0.18 : 0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: min(zone.rect.width, zone.rect.height) / 2, style: .continuous)
                            .strokeBorder(Color.white.opacity(armed ? 0.80 : 0.35), lineWidth: 1.5)
                    )
                    .frame(width: zone.rect.width, height: zone.rect.height)
                    .scaleEffect(armed ? 1.08 : 1.0)
                    .animation(.easeOut(duration: 0.12), value: armed)
                    .offset(
                        x: zone.rect.minX - chrome.screenFrame.minX,
                        y: chrome.screenFrame.maxY - zone.rect.maxY
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(chrome.visible ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: chrome.visible)
        .allowsHitTesting(false)
    }
}

/// Turns the model plus the pointer into the one thing the dock draws.
@MainActor
enum FlowBarState {
    static func viewState(model: AppModel, hovered: DockControl?, open: Bool) -> FlowBarViewState {
        switch model.pillState {
        case .idle:
            guard open else { return .nub }
            let action = model.newNoteAction
            let label = hovered.map { FlowBarText.labelCapsuleWidth(for: $0, newNote: action) } ?? 0
            return .stack(hovered: hovered, labelWidth: label)
        case .listening:
            return .level(locked: model.dictationLocked,
                          commandWidth: model.commandMode ? FlowBarText.commandMarkerWidth() : nil)
        case .working, .inserted, .guarded, .error, .notice:
            guard let capsule = FlowBarDock.textCapsule(for: model.pillState, workingNote: model.workingNote) else {
                return .spinner
            }
            return .text(capsule, width: FlowBarText.textCapsuleWidth(capsule))
        case .recording(let elapsed):
            let isHovered = hovered == .newNote
            let width = isHovered
                ? FlowBarText.labelCapsuleWidth(for: .newNote, newNote: .stop)
                : FlowBarText.timerCapsuleWidth(FlowBarDock.timerText(elapsed))
            return .recording(elapsed: elapsed, hovered: isHovered, badgeWidth: width)
        case .meetingDetected(let detected):
            return .nudge(detected)
        }
    }
}

@MainActor
final class PillPanelController {
    private let panel: DraggablePillPanel
    private let model: AppModel
    private let chrome = FlowBarChrome()
    private let overlay = DropZoneOverlayController()
    private let tracking = DockTrackingView()
    private var stateSubscription: AnyCancellable?
    private var dockSubscription: AnyCancellable?
    private var persistentSubscription: AnyCancellable?
    private var contentSubscription: AnyCancellable?
    private var autoStopSubscription: AnyCancellable?

    private var dragState: PillDragState?
    private var dragZones: [PillDropZone] = []
    private var dragScreen: NSScreen?
    private var escapeMonitors: [Any] = []
    private var dockEscapeMonitors: [Any] = []
    /// Set while the drop animation runs so state updates do not fight it.
    private var isSettling = false

    private var intent = DockHoverIntent()
    private var openTimer: DispatchWorkItem?
    private var closeTimer: DispatchWorkItem?
    /// The panel-local point the current press started at, for click routing.
    private var pressPoint: CGPoint?

    private static let settleDuration: TimeInterval = 0.26
    private static let liftDuration: TimeInterval = 0.12
    /// The panel is placed flush with the edge; the 6 and 10 point insets in
    /// the mock are drawn inside it.
    private static let panelInset: CGFloat = 0

    init(model: AppModel) {
        self.model = model
        panel = DraggablePillPanel(
            contentRect: NSRect(origin: .zero, size: FlowBarDock.panelSize(for: .nub, edge: .bottom)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The shadow is drawn in SwiftUI so it can rise with the lift.
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: FlowBarDockView(chrome: chrome).environmentObject(model))
        hosting.autoresizingMask = [.width, .height]
        tracking.addSubview(hosting)
        hosting.frame = tracking.bounds
        panel.contentView = tracking
        tracking.onPointer = { [weak self] point in self?.pointerMoved(to: point) }

        panel.onDragBegin = { [weak self] cursor in self?.beginDrag(cursor: cursor) }
        panel.onDragMove = { [weak self] cursor in self?.moveDrag(cursor: cursor) }
        panel.onDragEnd = { [weak self] cursor in self?.endDrag(cursor: cursor) }
        panel.onDragCancel = { [weak self] in self?.cancelDrag() }
        stateSubscription = model.$pillState.sink { [weak self] state in
            MainActor.assumeIsolated { self?.pillStateChanged(to: state) }
        }
        dockSubscription = model.$pillEdge.combineLatest(model.$pillOffset).sink { [weak self] _, _ in
            MainActor.assumeIsolated { self?.update() }
        }
        persistentSubscription = model.$pillPersistent.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        // The drawn size depends on the hovered control and on the words in
        // the current capsule, so any of those changing resizes the panel.
        contentSubscription = model.$commandMode
            .combineLatest(model.$dictationLocked, model.$workingNote)
            .sink { [weak self] _, _, _ in MainActor.assumeIsolated { self?.update() } }
        // Resume makes the New note label longer than New note does, so the
        // panel has to resize when auto-stop arms it.
        autoStopSubscription = model.meetings.$lastAutoStop.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    // MARK: - Placement

    private var viewState: FlowBarViewState {
        FlowBarState.viewState(model: model, hovered: chrome.hovered, open: intent.isOpen)
    }

    private func pillStateChanged(to state: PillState) {
        // Anything but idle replaces the stack, so the hover intent must not
        // keep the fan-out alive underneath a capsule.
        if state != .idle, intent.isOpen {
            _ = intent.forceClosed()
            cancelHoverTimers()
            chrome.open = false
            chrome.hovered = nil
            removeDockEscapeMonitors()
        }
        update()
    }

    private func update() {
        guard let screen = dockingScreen() else { panel.orderOut(nil); return }
        guard model.pillPersistent || model.pillState != .idle else {
            panel.orderOut(nil)
            return
        }
        place(in: screen.visibleFrame)
        panel.orderFrontRegardless()
        syncHover()
    }

    private func place(in visibleFrame: CGRect) {
        guard !isSettling, dragState == nil else { return }
        let size = FlowBarDock.panelSize(for: viewState, edge: model.pillEdge)
        let frame = PillPlacement.frame(
            size: size, edge: model.pillEdge, offset: model.pillOffset,
            inset: Self.panelInset, in: visibleFrame
        )
        guard frame != panel.frame else { return }
        // The panel frame snaps and the SwiftUI content animates inside it.
        // Animating both fights the fan-out and clips it mid-flight.
        panel.setFrame(frame, display: true)
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Hover

    private var axis: DockAxis {
        DockAxis(edge: model.pillEdge, panelSize: panel.frame.size)
    }

    /// Re-reads the pointer after the panel resizes, since a stationary
    /// pointer gets no tracking callback when the window grows under it.
    private func syncHover() {
        let mouse = NSEvent.mouseLocation
        guard panel.frame.contains(mouse) else {
            pointerMoved(to: nil)
            return
        }
        pointerMoved(to: CGPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY))
    }

    private func pointerMoved(to point: CGPoint?) {
        guard dragState == nil else { return }
        guard let point else {
            applyHoverEffect(intent.pointerExited())
            model.setNudgeHovered(false)
            setHovered(nil)
            return
        }
        if case .meetingDetected = model.pillState {
            // Reading the card pauses its countdown, so it cannot vanish
            // mid-sentence.
            model.setNudgeHovered(FlowBarDock.nudgeRect(axis: axis).contains(point))
            setHovered(nil)
            return
        }
        model.setNudgeHovered(false)
        applyHoverEffect(intent.pointerEntered())
        guard case .recording = model.pillState else {
            let hovered = intent.isOpen
                ? FlowBarDock.control(at: point, axis: axis, hovered: chrome.hovered)
                : nil
            setHovered(hovered)
            return
        }
        let inControl = FlowBarDock.recordingControlRect(axis: axis)
            .insetBy(dx: -FlowBarMetrics.hitPadding, dy: -FlowBarMetrics.hitPadding)
            .contains(point)
        setHovered(inControl ? .newNote : nil)
    }

    private func setHovered(_ control: DockControl?) {
        guard chrome.hovered != control else { return }
        withAnimation(.easeOut(duration: reduceMotion ? FlowBarMetrics.reducedMotionFade : FlowBarMetrics.labelFadeDuration)) {
            chrome.hovered = control
        }
        update()
    }

    private func applyHoverEffect(_ effect: DockHoverIntent.Effect) {
        switch effect {
        case .none:
            break
        case .startOpenTimer:
            scheduleOpen()
        case .startCloseTimer:
            scheduleClose()
        case .cancelTimers:
            cancelHoverTimers()
        case .didOpen:
            setOpen(true)
        case .didClose:
            cancelHoverTimers()
            setOpen(false)
        }
    }

    private func scheduleOpen() {
        cancelHoverTimers()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyHoverEffect(self.intent.openTimerFired())
            }
        }
        openTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + FlowBarMetrics.hoverOpenDelay, execute: work)
    }

    private func scheduleClose() {
        cancelHoverTimers()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyHoverEffect(self.intent.closeTimerFired())
            }
        }
        closeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + FlowBarMetrics.hoverCloseDelay, execute: work)
    }

    private func cancelHoverTimers() {
        openTimer?.cancel(); openTimer = nil
        closeTimer?.cancel(); closeTimer = nil
    }

    private func setOpen(_ open: Bool) {
        guard chrome.open != open else { return }
        if open {
            // Grow the panel first so the fan-out is not clipped. `update`
            // reads the intent, which is already open, not `chrome.open`.
            update()
            withAnimation(openAnimation) { chrome.open = true }
            installDockEscapeMonitors()
        } else {
            chrome.hovered = nil
            withAnimation(closeAnimation) { chrome.open = false }
            removeDockEscapeMonitors()
            DispatchQueue.main.asyncAfter(deadline: .now() + FlowBarMetrics.collapseDuration) {
                MainActor.assumeIsolated { [weak self] in self?.update() }
            }
        }
    }

    private var openAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: FlowBarMetrics.reducedMotionFade)
            : .timingCurve(0.2, 0.9, 0.3, 1.15, duration: FlowBarMetrics.fanOutDuration)
    }

    private var closeAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: FlowBarMetrics.reducedMotionFade)
            : .easeIn(duration: FlowBarMetrics.collapseDuration)
    }

    /// Escape collapses the dock. It never stops a recording, and it never
    /// reaches the app in front while the dock is open on purpose.
    private func installDockEscapeMonitors() {
        guard dockEscapeMonitors.isEmpty else { return }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.keyCode == 53 else { return event }
            let consumed = MainActor.assumeIsolated { [weak self] () -> Bool in
                guard let self, self.intent.isOpen else { return false }
                self.collapseDock()
                return true
            }
            return consumed ? nil : event
        }) {
            dockEscapeMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.intent.isOpen else { return }
                self.collapseDock()
            }
        }) {
            dockEscapeMonitors.append(global)
        }
    }

    private func removeDockEscapeMonitors() {
        for monitor in dockEscapeMonitors { NSEvent.removeMonitor(monitor) }
        dockEscapeMonitors = []
    }

    private func collapseDock() {
        applyHoverEffect(intent.escape())
    }

    // MARK: - Clicks

    /// Runs the action for a click that never moved. Drags do not land here.
    private func handleClick(at point: CGPoint) {
        switch model.pillState {
        case .meetingDetected(let detected):
            switch FlowBarDock.nudgeAction(at: point, axis: axis) {
            case .ignore: model.ignoreDetectedMeeting()
            case .startNote: model.startDetectedMeeting(detected)
            case nil: break
            }
        case .recording:
            let hit = FlowBarDock.recordingControlRect(axis: axis)
                .insetBy(dx: -FlowBarMetrics.hitPadding, dy: -FlowBarMetrics.hitPadding)
            if hit.contains(point) { model.toggleMeetingCapture() }
        case .listening:
            model.toggleDictationFromDock()
        case .idle:
            guard intent.isOpen else {
                // A click on the nub opens the dock without waiting out the
                // hover delay.
                applyHoverEffect(intent.pointerEntered())
                applyHoverEffect(intent.openTimerFired())
                return
            }
            guard let control = FlowBarDock.control(at: point, axis: axis, hovered: chrome.hovered) else { return }
            activate(control)
        case .working, .inserted, .guarded, .error, .notice:
            break
        }
    }

    private func activate(_ control: DockControl) {
        switch control {
        case .dictate: model.toggleDictationFromDock()
        case .newNote: model.toggleMeetingCapture()
        case .scratchpad: model.toggleQuickNote()
        }
    }

    // MARK: - Drag

    private func beginDrag(cursor: CGPoint) {
        guard !isSettling else { return }
        pressPoint = CGPoint(x: cursor.x - panel.frame.minX, y: cursor.y - panel.frame.minY)
        dragState = PillDragState(originFrame: panel.frame, cursor: cursor)
    }

    private func moveDrag(cursor: CGPoint) {
        guard var state = dragState else { return }
        if !state.didMove {
            guard !PillPlacement.isClick(from: state.originCursor, to: cursor) else { return }
            state.didMove = true
            startLift()
            showDropZones()
            installEscapeMonitors()
        }
        let frame = state.frame(forCursor: cursor)
        panel.setFrame(frame, display: true)

        let center = CGPoint(x: frame.midX, y: frame.midY)
        let armed = PillPlacement.armedZone(pillCenter: center, zones: dragZones)
        if armed?.edge != state.armedEdge {
            state.armedEdge = armed?.edge
            overlay.setArmed(armed?.edge)
            if armed != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
        dragState = state
    }

    private func endDrag(cursor: CGPoint) {
        guard let state = dragState else { return }
        dragState = nil
        teardownDrag()
        guard state.didMove else {
            if let pressPoint { handleClick(at: pressPoint) }
            pressPoint = nil
            return
        }
        pressPoint = nil
        let frame = state.frame(forCursor: cursor)
        guard let screen = dragScreen ?? dockingScreen() else { return }
        let visibleFrame = screen.visibleFrame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let edge: PillEdge
        let offset: Double
        if let armedEdge = state.armedEdge {
            edge = armedEdge
            offset = 0.5
        } else {
            edge = PillPlacement.nearestEdge(center: center, in: visibleFrame)
            offset = PillPlacement.normalizedOffset(center: center, edge: edge, in: visibleFrame)
        }
        settle(edge: edge, offset: offset, in: visibleFrame)
    }

    private func cancelDrag() {
        guard let state = dragState else { return }
        dragState = nil
        pressPoint = nil
        panel.stopTracking()
        teardownDrag()
        guard state.didMove else { return }
        guard !reduceMotion else {
            panel.setFrame(state.cancelledFrame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = FlowBarMetrics.collapseDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(state.cancelledFrame, display: true)
        }
    }

    /// Animates the panel onto the chosen dock, pulses the pill, and persists
    /// the new position.
    private func settle(edge: PillEdge, offset: Double, in visibleFrame: CGRect) {
        let size = FlowBarDock.panelSize(for: viewState, edge: edge)
        let target = PillPlacement.frame(
            size: size, edge: edge, offset: offset,
            inset: Self.panelInset, in: visibleFrame
        )
        isSettling = true
        model.setPillDock(edge: edge, offset: offset)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        guard !reduceMotion else {
            panel.setFrame(target, display: true)
            isSettling = false
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.settleDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                self.isSettling = false
                self.pulse()
            }
        })
    }

    private func startLift() {
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: Self.liftDuration)) { chrome.lifted = true }
    }

    private func endLift() {
        guard chrome.lifted else { return }
        withAnimation(.easeOut(duration: Self.liftDuration)) { chrome.lifted = false }
    }

    /// The lock-in pulse: 1.0 -> 1.04 -> 1.0 over 180 ms.
    private func pulse() {
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.09)) { chrome.pulse = 1.04 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            MainActor.assumeIsolated {
                withAnimation(.easeOut(duration: 0.09)) { self.chrome.pulse = 1.0 }
            }
        }
    }

    private func showDropZones() {
        guard let screen = dockingScreen() else { return }
        dragScreen = screen
        // Zones always preview where the nub will sit, so the four outlines
        // read the same no matter which state the dock is in when it moves.
        let canonicalSize = CGSize(width: FlowBarMetrics.nubLength, height: FlowBarMetrics.nubThickness)
        dragZones = PillPlacement.dropZones(
            pillSize: canonicalSize, inset: FlowBarMetrics.nubInset, in: screen.visibleFrame,
            matchEdgeOrientation: true
        )
        overlay.show(zones: dragZones, on: screen)
    }

    private func teardownDrag() {
        endLift()
        overlay.hide()
        removeEscapeMonitors()
        dragZones = []
    }

    /// Escape cancels a drag. The panel never becomes key, so a local monitor
    /// catches Escape inside the app and a global monitor catches it while
    /// another app is frontmost.
    private func installEscapeMonitors() {
        guard escapeMonitors.isEmpty else { return }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.keyCode == 53 else { return event }
            let cancelled = MainActor.assumeIsolated { [weak self] () -> Bool in
                guard let self, self.dragState != nil else { return false }
                self.cancelDrag()
                return true
            }
            return cancelled ? nil : event
        }) {
            escapeMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.dragState != nil else { return }
                self.panel.stopTracking()
                self.cancelDrag()
            }
        }) {
            escapeMonitors.append(global)
        }
    }

    private func removeEscapeMonitors() {
        for monitor in escapeMonitors { NSEvent.removeMonitor(monitor) }
        escapeMonitors = []
    }

    /// The screen under the mouse pointer, falling back to the main screen.
    private func dockingScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

// MARK: - Colors

/// The dock's palette, straight from section 05 of the mockup.
enum FlowBarPalette {
    static let controlFill = Color(red: 0.110, green: 0.110, blue: 0.118)
    static let controlHover = Color(red: 0.227, green: 0.227, blue: 0.235)
    static let glyph = Color(red: 0.961, green: 0.961, blue: 0.969)
    static let labelFill = Color(red: 0.067, green: 0.067, blue: 0.067)
    static let amber = Color(red: 0.949, green: 0.725, blue: 0.314)
    static let nubLight = Color(red: 0.557, green: 0.557, blue: 0.576)
    static let nubDark = Color(red: 0.631, green: 0.631, blue: 0.651)
    static let cardText = Color(red: 0.784, green: 0.784, blue: 0.800)
    static let cardSub = Color(red: 0.541, green: 0.541, blue: 0.565)
    static let cardSecondaryButton = Color(red: 0.165, green: 0.165, blue: 0.173)
}

// MARK: - The dock

/// One overlay that draws the nub, the fanned-out controls, every capsule,
/// and the meeting nudge. It reads its own size, so the panel controller can
/// resize the window and the layout follows.
struct FlowBarDockView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var chrome: FlowBarChrome
    @Environment(\.colorScheme) private var colorScheme

    private var edge: PillEdge { model.pillEdge }

    /// Start, Stop, or Resume. The controller sizes the panel from the same
    /// answer, so the label capsule always fits the word it is about to draw.
    private var newNoteAction: FlowBarDock.NewNoteAction { model.newNoteAction }

    private var state: FlowBarViewState {
        FlowBarState.viewState(model: model, hovered: chrome.hovered, open: chrome.open)
    }

    var body: some View {
        GeometryReader { geometry in
            let axis = DockAxis(edge: edge, panelSize: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                content(axis: axis)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .scaleEffect(chrome.scale)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func content(axis: DockAxis) -> some View {
        switch state {
        case .nub, .stack:
            // One branch for both, so the controls keep their identity and
            // the fan-out animates instead of cutting.
            idleDock(axis: axis)
        case .level(let locked, let commandWidth):
            levelCapsule(axis: axis, locked: locked, commandWidth: commandWidth)
        case .spinner:
            spinnerCapsule(axis: axis)
        case .text(let capsule, let width):
            textCapsule(capsule, width: width, axis: axis)
        case .recording(let elapsed, let hovered, let badgeWidth):
            recording(axis: axis, elapsed: elapsed, hovered: hovered, badgeWidth: badgeWidth)
        case .nudge(let detected):
            nub(axis: axis, hidden: false)
            nudge(axis: axis, detected: detected)
        }
    }

    /// The rest state and the hover state are one view: the nub folds away
    /// while the three controls fan out of where it was.
    @ViewBuilder
    private func idleDock(axis: DockAxis) -> some View {
        let hovered = chrome.open ? chrome.hovered : nil
        let labelWidth = hovered.map { FlowBarText.labelCapsuleWidth(for: $0, newNote: newNoteAction) } ?? 0
        nub(axis: axis, hidden: chrome.open)
        stack(axis: axis, hovered: hovered, labelWidth: labelWidth)
    }

    // MARK: Nub

    private var nubFill: Color {
        (colorScheme == .dark ? FlowBarPalette.nubDark : FlowBarPalette.nubLight).opacity(0.95)
    }

    @ViewBuilder
    private func nub(axis: DockAxis, hidden: Bool) -> some View {
        let rect = FlowBarDock.nubRect(axis: axis)
        RoundedRectangle(cornerRadius: FlowBarMetrics.nubRadius, style: .continuous)
            .fill(nubFill)
            .overlay(
                RoundedRectangle(cornerRadius: FlowBarMetrics.nubRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.5)
            )
            .frame(width: rect.width, height: rect.height)
            .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
            .opacity(hidden ? 0 : 1)
            // The nub shrinks along the edge only, so it reads as folding
            // into the controls rather than sinking away.
            .scaleEffect(
                x: edge.isHorizontal ? (hidden ? 0.6 : 1) : 1,
                y: edge.isHorizontal ? 1 : (hidden ? 0.6 : 1)
            )
            .animation(.easeOut(duration: FlowBarMetrics.nubFadeDuration), value: hidden)
            .place(rect, in: axis.panelSize)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Undertone, idle")
    }

    // MARK: Stack

    @ViewBuilder
    private func stack(axis: DockAxis, hovered: DockControl?, labelWidth: CGFloat) -> some View {
        let nubCenter = center(of: FlowBarDock.nubRect(axis: axis))
        ForEach(Array(DockControl.allCases.enumerated()), id: \.element) { index, control in
            let rect = FlowBarDock.controlRect(control, axis: axis, hovered: hovered)
            let origin = CGSize(width: nubCenter.x - rect.midX, height: rect.midY - nubCenter.y)
            controlView(control, rect: rect, hovered: hovered == control)
                .opacity(chrome.open ? 1 : 0)
                .scaleEffect(chrome.open || reduceMotion ? 1 : 0.6)
                .offset(chrome.open || reduceMotion ? .zero : origin)
                .animation(fanAnimation(index: index), value: chrome.open)
                .place(rect, in: axis.panelSize)
        }
        if let hovered, labelWidth > 0 {
            let rect = FlowBarDock.labelRect(hovered, axis: axis, hovered: hovered, width: labelWidth)
            labelView(hovered, action: newNoteAction)
                .frame(width: rect.width, height: rect.height)
                .place(rect, in: axis.panelSize)
                .transition(.opacity)
        }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func fanAnimation(index: Int) -> Animation {
        guard !reduceMotion else { return .easeOut(duration: FlowBarMetrics.reducedMotionFade) }
        guard chrome.open else { return .easeIn(duration: FlowBarMetrics.collapseDuration) }
        return .timingCurve(0.2, 0.9, 0.3, 1.15, duration: FlowBarMetrics.fanOutDuration)
            .delay(Double(index) * FlowBarMetrics.fanOutStagger)
    }

    @ViewBuilder
    private func controlView(_ control: DockControl, rect: CGRect, hovered: Bool) -> some View {
        controlShape(hovered: hovered)
            .frame(width: rect.width, height: rect.height)
            .overlay(controlGlyph(control, rect: rect, hovered: hovered))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(FlowBarDock.accessibilityLabel(for: control, newNote: newNoteAction))
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func controlShape(hovered: Bool) -> some View {
        RoundedRectangle(cornerRadius: FlowBarMetrics.controlSize / 2, style: .circular)
            .fill((hovered ? FlowBarPalette.controlHover : FlowBarPalette.controlFill).opacity(0.98))
            .overlay(rim(cornerRadius: FlowBarMetrics.controlSize / 2))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .animation(.linear(duration: 0.12), value: hovered)
    }

    /// A hairline rim keeps a near-black control readable on a dark desktop.
    @ViewBuilder
    private func rim(cornerRadius: CGFloat) -> some View {
        if colorScheme == .dark {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func controlGlyph(_ control: DockControl, rect: CGRect, hovered: Bool) -> some View {
        switch control {
        case .dictate:
            Image(systemName: "mic")
                .font(.system(size: FlowBarMetrics.glyphSize, weight: .regular))
                .foregroundStyle(FlowBarPalette.glyph)
        case .newNote:
            ZStack(alignment: .topLeading) {
                Color.clear
                newNoteRing(pulsing: false)
                    .place(glyphAnchorRect(in: rect), in: rect.size)
                chevron
                    .place(chevronRect(in: rect), in: rect.size)
                    .opacity(hovered ? 0.9 : 0)
                    .animation(.easeOut(duration: FlowBarMetrics.labelFadeDuration), value: hovered)
            }
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        case .scratchpad:
            Image(systemName: "note.text")
                .font(.system(size: FlowBarMetrics.glyphSize, weight: .regular))
                .foregroundStyle(FlowBarPalette.glyph)
        }
    }

    /// The New note ring stays pinned toward the edge so the capsule grows
    /// inward on hover instead of sliding the glyph across.
    private func glyphAnchorRect(in control: CGRect) -> CGRect {
        let size = FlowBarMetrics.glyphSize
        let inset = (FlowBarMetrics.controlSize - size) / 2
        switch edge {
        case .right:
            return CGRect(x: control.width - inset - size, y: (control.height - size) / 2, width: size, height: size)
        case .left:
            return CGRect(x: inset, y: (control.height - size) / 2, width: size, height: size)
        case .bottom:
            return CGRect(x: (control.width - size) / 2, y: inset, width: size, height: size)
        case .top:
            return CGRect(x: (control.width - size) / 2, y: control.height - inset - size, width: size, height: size)
        }
    }

    private func chevronRect(in control: CGRect) -> CGRect {
        let size: CGFloat = 13
        let inset: CGFloat = 12
        switch edge {
        case .right:
            return CGRect(x: inset - size / 2, y: (control.height - size) / 2, width: size, height: size)
        case .left:
            return CGRect(x: control.width - inset - size / 2, y: (control.height - size) / 2, width: size, height: size)
        case .bottom:
            return CGRect(x: (control.width - size) / 2, y: control.height - inset - size / 2, width: size, height: size)
        case .top:
            return CGRect(x: (control.width - size) / 2, y: inset - size / 2, width: size, height: size)
        }
    }

    @ViewBuilder
    private func newNoteRing(pulsing: Bool) -> some View {
        NewNoteGlyph(pulsing: pulsing)
            .frame(width: FlowBarMetrics.glyphSize, height: FlowBarMetrics.glyphSize)
    }

    private var chevronSymbol: String {
        switch edge {
        case .right: return "chevron.left"
        case .left: return "chevron.right"
        case .bottom: return "chevron.up"
        case .top: return "chevron.down"
        }
    }

    @ViewBuilder
    private var chevron: some View {
        Image(systemName: chevronSymbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(FlowBarPalette.glyph)
    }

    @ViewBuilder
    private func labelView(_ control: DockControl, action: FlowBarDock.NewNoteAction) -> some View {
        let label = FlowBarDock.labelText(for: control, newNote: action)
        HStack(spacing: FlowBarMetrics.labelShortcutGap) {
            Text(label.title)
                .font(.system(size: FlowBarMetrics.labelFontSize, weight: .medium))
            if let shortcut = label.shortcut {
                Text(shortcut)
                    .font(.system(size: FlowBarMetrics.labelFontSize, weight: .bold))
            }
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlowBarPalette.labelFill.opacity(0.98),
                    in: RoundedRectangle(cornerRadius: FlowBarMetrics.labelAlong / 2, style: .circular))
        .overlay(rim(cornerRadius: FlowBarMetrics.labelAlong / 2))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .accessibilityHidden(true)
    }

    // MARK: Capsules

    @ViewBuilder
    private func capsuleShape(_ rect: CGRect) -> some View {
        RoundedRectangle(cornerRadius: FlowBarMetrics.capsuleDepth / 2, style: .circular)
            .fill(FlowBarPalette.controlFill.opacity(0.98))
            .overlay(rim(cornerRadius: FlowBarMetrics.capsuleDepth / 2))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .frame(width: rect.width, height: rect.height)
    }

    @ViewBuilder
    private func levelCapsule(axis: DockAxis, locked: Bool, commandWidth: CGFloat?) -> some View {
        if let rect = FlowBarDock.capsuleRect(for: state, axis: axis) {
            capsuleShape(rect)
                .overlay(levelContent(locked: locked, commandWidth: commandWidth))
                .place(rect, in: axis.panelSize)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(locked ? "Dictating, locked" : "Dictating")
        }
    }

    @ViewBuilder
    private func levelContent(locked: Bool, commandWidth: CGFloat?) -> some View {
        let core = Group {
            if edge.isHorizontal {
                HStack(spacing: 10) { levelPieces(locked: locked) }
            } else {
                VStack(spacing: 10) { levelPieces(locked: locked) }
            }
        }
        if commandWidth != nil {
            // The Command word always reads horizontally, so on a side dock
            // it sits beside the bars rather than turning with them.
            HStack(spacing: FlowBarMetrics.textCapsuleGap) {
                if edge == .left { commandMarker }
                core
                if edge != .left { commandMarker }
            }
            .padding(.horizontal, FlowBarMetrics.textCapsuleGap)
        } else {
            core
        }
    }

    @ViewBuilder
    private func levelPieces(locked: Bool) -> some View {
        Circle()
            .fill(.white)
            .frame(width: 6, height: 6)
        FlowingWaveform(level: model.listeningLevel, isHorizontal: edge.isHorizontal)
        if locked {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityLabel("Locked, tap or press Escape to stop")
        }
    }

    @ViewBuilder
    private var commandMarker: some View {
        Text(FlowBarText.commandMarker)
            .font(.system(size: FlowBarMetrics.textCapsuleFontSize, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder
    private func spinnerCapsule(axis: DockAxis) -> some View {
        if let rect = FlowBarDock.capsuleRect(for: state, axis: axis) {
            capsuleShape(rect)
                .overlay(RingSpinner())
                .place(rect, in: axis.panelSize)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Cleaning up")
        }
    }

    @ViewBuilder
    private func textCapsule(_ capsule: FlowBarTextCapsule, width: CGFloat, axis: DockAxis) -> some View {
        if let rect = FlowBarDock.capsuleRect(for: state, axis: axis) {
            RoundedRectangle(cornerRadius: FlowBarMetrics.textCapsuleThickness / 2, style: .circular)
                .fill(FlowBarPalette.controlFill.opacity(0.98))
                .overlay(rim(cornerRadius: FlowBarMetrics.textCapsuleThickness / 2))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                .frame(width: rect.width, height: rect.height)
                .overlay(
                    HStack(spacing: FlowBarMetrics.textCapsuleGap) {
                        capsuleGlyph(capsule.glyph)
                        if !capsule.text.isEmpty {
                            Text(capsule.text)
                                .font(.system(size: FlowBarMetrics.textCapsuleFontSize, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        if let mono = capsule.mono {
                            Text(mono)
                                .font(.system(size: FlowBarMetrics.monoFontSize, weight: .medium).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                    .fixedSize()
                )
                .place(rect, in: axis.panelSize)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([capsule.text, capsule.mono ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
        }
    }

    @ViewBuilder
    private func capsuleGlyph(_ glyph: FlowBarTextCapsule.Glyph) -> some View {
        switch glyph {
        case .none:
            EmptyView()
        case .check:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: FlowBarMetrics.glyphSize, height: FlowBarMetrics.glyphSize)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FlowBarPalette.amber)
                .frame(width: FlowBarMetrics.glyphSize, height: FlowBarMetrics.glyphSize)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: FlowBarMetrics.glyphSize, height: FlowBarMetrics.glyphSize)
        }
    }

    // MARK: Recording

    @ViewBuilder
    private func recording(axis: DockAxis, elapsed: TimeInterval, hovered: Bool, badgeWidth: CGFloat) -> some View {
        let control = FlowBarDock.recordingControlRect(axis: axis)
        controlShape(hovered: hovered)
            .frame(width: control.width, height: control.height)
            .overlay(newNoteRing(pulsing: true))
            .place(control, in: axis.panelSize)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(FlowBarDock.accessibilityLabel(for: .newNote, newNote: .stop))
            .accessibilityAddTraits(.isButton)

        let badge = FlowBarDock.recordingBadgeRect(axis: axis, hovered: hovered, width: badgeWidth)
        if hovered {
            labelView(.newNote, action: .stop)
                .frame(width: badge.width, height: badge.height)
                .place(badge, in: axis.panelSize)
        } else {
            Text(FlowBarDock.timerText(elapsed))
                .font(.system(size: FlowBarMetrics.monoFontSize, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .frame(width: badge.width, height: badge.height)
                .background(FlowBarPalette.labelFill.opacity(0.98),
                            in: RoundedRectangle(cornerRadius: FlowBarMetrics.timerThickness / 2, style: .circular))
                .overlay(rim(cornerRadius: FlowBarMetrics.timerThickness / 2))
                .shadow(color: .black.opacity(0.32), radius: 8, y: 3)
                .place(badge, in: axis.panelSize)
                .accessibilityLabel("Recording, \(FlowBarDock.timerText(elapsed))")
        }
    }

    // MARK: Nudge

    @ViewBuilder
    private func nudge(axis: DockAxis, detected: DetectedMeeting) -> some View {
        let rect = FlowBarDock.nudgeRect(axis: axis)
        MeetingNudgeCard(detected: detected, fraction: model.nudgeFraction, dark: colorScheme == .dark)
            .frame(width: rect.width, height: rect.height)
            .place(rect, in: axis.panelSize)
    }
}

/// A 14 point ring with one bright arc turning through it. The system's own
/// small `ProgressView` draws spokes, which reads as a beachball at this size.
struct RingSpinner: View {
    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .strokeBorder(Color.white.opacity(0.25), lineWidth: 2)
            .overlay(
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .padding(1)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
            )
            .frame(width: 14, height: 14)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spinning = true }
            }
            .accessibilityHidden(true)
    }
}

/// The New note glyph: a 16 point ring with a 6 point dot, which becomes one
/// filled pulsing dot while capture runs.
struct NewNoteGlyph: View {
    let pulsing: Bool
    @State private var small = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if pulsing {
                Circle()
                    .fill(.white)
                    .frame(width: FlowBarMetrics.recordingDot, height: FlowBarMetrics.recordingDot)
                    .opacity(small ? 0.55 : 1)
                    .scaleEffect(small ? 0.82 : 1)
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: FlowBarMetrics.recordingPulsePeriod / 2)
                            .repeatForever(autoreverses: true)) { small = true }
                    }
            } else {
                Circle()
                    .strokeBorder(FlowBarPalette.glyph, lineWidth: 2)
                    .overlay(Circle().fill(FlowBarPalette.glyph).frame(width: 6, height: 6))
                    .frame(width: FlowBarMetrics.glyphSize, height: FlowBarMetrics.glyphSize)
            }
        }
        .frame(width: FlowBarMetrics.glyphSize, height: FlowBarMetrics.glyphSize)
    }
}

/// The meeting nudge: which call, why it fired, and what happens next. Always
/// 300 by 140 on screen, whichever edge the dock is on.
struct MeetingNudgeCard: View {
    let detected: DetectedMeeting
    let fraction: Double
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                MeetingBadgeView(detected: detected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(FlowBarDock.nudgeTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(FlowBarDock.nudgeReason(for: detected))
                        .font(.system(size: 12))
                        .foregroundStyle(FlowBarPalette.cardText)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            Text(FlowBarDock.nudgeSubline)
                .font(.system(size: 11))
                .foregroundStyle(FlowBarPalette.cardSub)
                .padding(.top, 8)
            Spacer(minLength: 8)
            HStack(spacing: FlowBarMetrics.nudgeButtonGap) {
                nudgeButton("Ignore", filled: false)
                nudgeButton("Start note", filled: true)
            }
            .frame(height: FlowBarMetrics.nudgeButtonHeight)
        }
        .padding(.horizontal, FlowBarMetrics.nudgePadding)
        .padding(.top, 12)
        .padding(.bottom, FlowBarMetrics.nudgePadding)
        .frame(width: FlowBarMetrics.nudgeWidth, height: FlowBarMetrics.nudgeHeight, alignment: .topLeading)
        .background(FlowBarPalette.labelFill)
        .overlay(alignment: .bottom) {
            // How long the card has left. Hovering it pauses the countdown,
            // so the bar stops with it.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.14)
                    Color.white.frame(width: geometry.size.width * max(0, min(1, fraction)))
                }
            }
            .frame(height: 2)
        }
        // Clipped as one piece, so the drain bar cannot run past the corners.
        .clipShape(RoundedRectangle(cornerRadius: FlowBarMetrics.nudgeRadius, style: .continuous))
        .overlay {
            if dark {
                RoundedRectangle(cornerRadius: FlowBarMetrics.nudgeRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(0.40), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(FlowBarDock.nudgeTitle). \(FlowBarDock.nudgeReason(for: detected))")
    }

    @ViewBuilder
    private func nudgeButton(_ title: String, filled: Bool) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(filled ? FlowBarPalette.labelFill : FlowBarPalette.cardText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(filled ? Color(white: 0.96) : FlowBarPalette.cardSecondaryButton,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityAddTraits(.isButton)
    }
}

private extension View {
    /// Places a view at an AppKit (bottom-left origin) rect inside a
    /// top-leading SwiftUI stack of `panelSize`.
    func place(_ rect: CGRect, in panelSize: CGSize) -> some View {
        frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: panelSize.height - rect.maxY)
    }
}

private func center(of rect: CGRect) -> CGPoint {
    CGPoint(x: rect.midX, y: rect.midY)
}

struct FlowingWaveform: View {
    let level: Double
    /// `true` when docked top/bottom (bars grow vertically, laid out
    /// left-to-right). `false` on the side docks, where the same drawing
    /// is rotated 90 degrees so the bars grow horizontally, stacked
    /// top-to-bottom.
    var isHorizontal: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var smoothedLevel = 0.0
    // Preserve the timer across microphone-driven view updates.
    @State private var envelopeTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private let cyan = Color(red: 0.20, green: 0.85, blue: 1.0)
    /// Seven bars, 2 points wide, 3 points apart, 4 to 16 points tall.
    private static let barCount = 7
    private static let barWidth = 2.0
    private static let barGap = 3.0
    private static let minBarHeight = 4.0
    private static let maxBarHeight = 16.0
    static let blockLength = CGFloat(Double(barCount) * barWidth + Double(barCount - 1) * barGap)
    private static let durations: [Double] = [0.29, 0.37, 0.43, 0.31, 0.47, 0.34, 0.41]
    private static let gains: [Double] = [0.72, 0.48, 0.88, 0.60, 0.94, 0.52, 0.82]
    private static let phaseOffsets: [Double] = [0.0, 1.1, 2.2, 0.5, 3.0, 1.7, 4.0]

    var body: some View {
        let visibleLevel = smoothedLevel
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            Canvas { context, physicalSize in
                // Bars are always laid out against the flat, left-to-right
                // orientation. On the side docks the canvas itself is
                // physically transposed, so the context is rotated 90 degrees
                // first and the drawing below runs unchanged against it.
                let size: CGSize
                if isHorizontal {
                    size = physicalSize
                } else {
                    size = CGSize(width: physicalSize.height, height: physicalSize.width)
                    context.translateBy(x: physicalSize.width, y: 0)
                    context.rotate(by: .degrees(90))
                }

                let now = timeline.date.timeIntervalSinceReferenceDate
                let totalWidth = Double(Self.blockLength)
                let startX = (size.width - CGFloat(totalWidth)) / 2
                let centerY = size.height / 2

                for index in Self.durations.indices {
                    let progress = reduceMotion ? 0.5 : 0.5 + 0.5 * sin((now / Self.durations[index]) * (2 * Double.pi) + Self.phaseOffsets[index])
                    let idleBreath = Self.minBarHeight + progress * 1.2
                    let speechHeight = visibleLevel * Self.maxBarHeight * Self.gains[index] * (0.78 + progress * 0.22)
                    let height = min(Self.maxBarHeight, max(Self.minBarHeight, visibleLevel <= 0.001 ? idleBreath : idleBreath + speechHeight))
                    let x = startX + CGFloat(index) * CGFloat(Self.barWidth + Self.barGap)
                    let rect = CGRect(x: x, y: centerY - CGFloat(height) / 2, width: Self.barWidth, height: CGFloat(height))
                    let color = visibleLevel <= 0.001
                        ? Color.white.opacity(0.65 + progress * 0.20)
                        : cyan.opacity(0.72 + min(visibleLevel, 1) * 0.28)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                }
            }
        }
        .frame(width: isHorizontal ? Self.blockLength : CGFloat(Self.maxBarHeight),
               height: isHorizontal ? CGFloat(Self.maxBarHeight) : Self.blockLength)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio level")
        .accessibilityValue(targetLevel == 0 ? "silent" : "active")
        .onAppear { smoothedLevel = targetLevel }
        .onReceive(envelopeTimer) { _ in advanceEnvelope() }
        .onChange(of: level) { _, _ in
            if reduceMotion { smoothedLevel = targetLevel }
        }
        .onChange(of: reduceMotion) { _, isReduced in
            if isReduced { smoothedLevel = targetLevel }
        }
    }

    private static func displayLevel(_ level: Double) -> Double {
        guard level.isFinite, level > 0 else { return 0 }
        let decibels = 20 * log10(min(1, level))
        return min(1, max(0, (decibels + 50) / 50))
    }

    private var targetLevel: Double {
        let visible = Self.displayLevel(level)
        return visible <= 0.08 ? 0 : visible
    }

    private func advanceEnvelope() {
        let target = targetLevel
        if reduceMotion {
            smoothedLevel = target
            return
        }
        let difference = target - smoothedLevel
        guard abs(difference) > 0.0005 else {
            smoothedLevel = target
            return
        }
        let coefficient = difference > 0 ? 0.30 : 0.14
        smoothedLevel += difference * coefficient
    }
}
