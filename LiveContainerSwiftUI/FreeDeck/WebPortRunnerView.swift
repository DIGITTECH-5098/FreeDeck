//
//  WebPortRunnerView.swift
//  LiveContainerSwiftUI
//
//  A web port is a game or app the FreeDeck server serves at
//  {base}/webport/{id}/. This page runs one full-screen in a WKWebView
//  with inline media, back/forward gestures and the user agent
//  "FreeDeck", and gives it controllers three ways:
//
//  * a `freedeck` script message handler, so page JavaScript can post
//    messages to the native side (haptics, logging);
//  * physical game controllers — MFi, Xbox, PlayStation — observed through
//    GameController and turned into 'freedeck-gamepad' CustomEvents
//    dispatched at window, exactly like the standard gamepad events a page
//    would get from a browser;
//  * a translucent virtual gamepad (d-pad, two sticks, A/B/X/Y, LB/RB,
//    start/menu) that injects the same events, toggleable from the toolbar.
//
//  Everything the page needs to keep — localStorage, IndexedDB — lives in
//  WKWebsiteDataStore, which the toolbar's cache button explains and can
//  clear. All types are defined here; nothing else in the app is needed.
//

import Foundation
import GameController
import SwiftUI
import UIKit
import WebKit

// MARK: - Gamepad events

/// What goes to the page as the detail of a 'freedeck-gamepad' event:
/// {index, id, buttons: {a: true, …}, axes: {dpad: [x, y], …}} with axis
/// y positive upwards, as gamepad axes conventionally go.
struct FreeDeckGamepadEvent: Codable, Equatable {
    var index: Int = 0
    var id: String = "FreeDeck Gamepad"
    var buttons: [String: Bool] = [:]
    var axes: [String: [Double]] = [:]
}

/// Accumulates the virtual pad's state so every change is sent as a full
/// snapshot, the way a real gamepad reports itself.
final class FreeDeckGamepadState {
    private var buttons: [String: Bool] = [:]
    private var axes: [String: [Double]] = [:]
    /// The id the page sees for the virtual pad.
    var eventID = "FreeDeck Virtual Gamepad"
    var onChange: ((FreeDeckGamepadEvent) -> Void)?

    func setButton(_ name: String, pressed: Bool) {
        guard buttons[name] != pressed else { return }
        buttons[name] = pressed
        emit()
    }

    func setAxis(_ name: String, x: Double, y: Double) {
        axes[name] = [x, y]
        emit()
    }

    private func emit() {
        onChange?(FreeDeckGamepadEvent(index: 1, id: eventID, buttons: buttons, axes: axes))
    }
}

/// Owns the controller plumbing and the evaluateJavaScript dispatch to the
/// page. Controllers report on their own queues, so every hop to the web
/// view goes through the main queue.
final class FreeDeckGamepadBridge {
    weak var webView: WKWebView?

    private var observerTokens: [NSObjectProtocol] = []

    // MARK: Controllers

    /// Begins watching for controllers and configures the ones already
    /// attached. Safe to call repeatedly.
    func startControllerDiscovery() {
        guard observerTokens.isEmpty else { return }
        let center = NotificationCenter.default

        observerTokens.append(center.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            self?.configure(controller)
        })
        observerTokens.append(center.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { _ in
            // Nothing to undo: the controller is gone and its handlers go
            // with it. The page keeps the last state, which is what a
            // browser does too.
        })

        GCController.controllers().forEach { configure($0) }
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    func stopControllerDiscovery() {
        observerTokens.forEach { NotificationCenter.default.removeObserver($0) }
        observerTokens.removeAll()
        GCController.stopWirelessControllerDiscovery()
    }

    /// Wires one extended gamepad to send a full snapshot on every change:
    /// d-pad and both thumbsticks as axes, A/B/X/Y, LB/RB and
    /// options (= start) / menu as buttons.
    private func configure(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        let eventID = controller.vendorName ?? "Game Controller"

        gamepad.valueChangedHandler = { [weak self] gamepad, _ in
            var event = FreeDeckGamepadEvent(index: 0, id: eventID)
            event.buttons = [
                "a": gamepad.buttonA.isPressed,
                "b": gamepad.buttonB.isPressed,
                "x": gamepad.buttonX.isPressed,
                "y": gamepad.buttonY.isPressed,
                "lb": gamepad.leftShoulder.isPressed,
                "rb": gamepad.rightShoulder.isPressed,
                // The Xbox "view"/"menu" pair and the PlayStation
                // "options"/"touchpad" pair land here: options is start,
                // menu is menu.
                "start": gamepad.buttonOptions?.isPressed ?? false,
                "menu": gamepad.buttonMenu.isPressed
            ]
            event.axes = [
                "dpad": [Double(gamepad.dpad.xAxis.value), Double(-gamepad.dpad.yAxis.value)],
                "leftStick": [
                    Double(gamepad.leftThumbstick.xAxis.value),
                    Double(-gamepad.leftThumbstick.yAxis.value)
                ],
                "rightStick": [
                    Double(gamepad.rightThumbstick.xAxis.value),
                    Double(-gamepad.rightThumbstick.yAxis.value)
                ]
            ]
            self?.send(event)
        }
    }

    // MARK: Dispatch to the page

    /// Fires window.dispatchEvent(new CustomEvent('freedeck-gamepad', …))
    /// with the event as its detail. Callable from any thread.
    func send(_ event: FreeDeckGamepadEvent) {
        guard let webView,
              let data = try? JSONEncoder().encode(event),
              let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        let script = "window.dispatchEvent(new CustomEvent('freedeck-gamepad', {detail: \(json)}));"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }
}

// MARK: - Model

/// The page's model: where it loads from, what the toolbar shows, and the
/// overlay's knobs. Plain ObservableObject — every UI-affecting change
/// happens on the main queue already.
final class FreeDeckWebPortModel: ObservableObject {
    let webPortID: String
    let baseURL: URL
    let title: String

    let bridge = FreeDeckGamepadBridge()
    let virtualGamepad = FreeDeckGamepadState()

    @Published var isLoading = true
    @Published var currentURL: URL?
    @Published var lastError: String?
    @Published var showsVirtualGamepad = false
    @Published var overlayOpacity = 0.75
    @Published var showsCacheStatus = false
    @Published var showsGamepadSettings = false
    @Published var cacheRecords: [String] = []

    weak var webView: WKWebView?

    init(webPortID: String, baseURL: URL, title: String) {
        self.webPortID = webPortID
        self.baseURL = baseURL
        self.title = title
        virtualGamepad.onChange = { [weak self] event in
            self?.bridge.send(event)
        }
    }

    /// {base}/webport/{id}/ — trailing slash included, as servers route it.
    var startURL: URL {
        let base = baseURL.absoluteString
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: "\(trimmed)/webport/\(webPortID)/") ?? baseURL
    }

    func reload() {
        isLoading = true
        if currentURL == nil {
            webView?.load(URLRequest(url: startURL))
        } else {
            webView?.reload()
        }
    }

    func openInSafari() {
        let url = currentURL ?? startURL
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    /// Fills cacheRecords with what the web view has stored per origin, for
    /// the cache status sheet.
    func loadCacheSummary() {
        WKWebsiteDataStore.default().fetchDataRecords(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()
        ) { [weak self] records in
            DispatchQueue.main.async {
                self?.cacheRecords = records.map(\.displayName)
            }
        }
    }

    func clearWebsiteData() {
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.cacheRecords = []
            }
        }
    }
}

// MARK: - Web view plumbing

/// WKUserContentController keeps its message handlers strongly, which would
/// close a retain cycle through the coordinator; this forwards and forgets.
final class FreeDeckWeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Navigation state into the model, and the JS→native side of the bridge.
final class FreeDeckWebPortCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let model: FreeDeckWebPortModel

    init(model: FreeDeckWebPortModel) {
        self.model = model
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        model.isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        model.isLoading = false
        model.currentURL = webView.url
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        model.isLoading = false
        model.lastError = error.localizedDescription
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        model.isLoading = false
        model.lastError = error.localizedDescription
    }

    // MARK: WKScriptMessageHandler

    /// Messages from page JavaScript:
    ///   {type: "log", message: "..."}    → NSLog
    ///   {type: "haptic"}                 → a medium impact tap
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "freedeck" else { return }
        let body = message.body as? [String: Any]
        switch body?["type"] as? String {
        case "log":
            let text = body?["message"] as? String ?? ""
            NSLog("[FreeDeck WebPort] %@", text)
        case "haptic", "haptics":
            DispatchQueue.main.async {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        default:
            break
        }
    }
}

/// The WKWebView itself: inline media, back/forward gestures, the user
/// agent "FreeDeck", and the 'freedeck' message handler.
struct FreeDeckWebView: UIViewRepresentable {
    @ObservedObject var model: FreeDeckWebPortModel

    func makeCoordinator() -> FreeDeckWebPortCoordinator {
        FreeDeckWebPortCoordinator(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(
            FreeDeckWeakScriptMessageHandler(target: context.coordinator),
            name: "freedeck"
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = "FreeDeck"
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator

        model.webView = webView
        model.bridge.webView = webView
        model.bridge.startControllerDiscovery()

        webView.load(URLRequest(url: model.startURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // The URL never changes after creation; progress and errors flow
        // through the coordinator instead.
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: FreeDeckWebPortCoordinator) {
        uiView.navigationDelegate = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "freedeck")
        coordinator.modelDidDetach()
    }
}

private extension FreeDeckWebPortCoordinator {
    /// Called when the web view goes away, so nothing keeps driving it.
    func modelDidDetach() {
        model.bridge.stopControllerDiscovery()
        model.bridge.webView = nil
        model.webView = nil
    }
}

// MARK: - Virtual gamepad

/// One press-and-hold button of the overlay.
struct FreeDeckVirtualButton: View {
    let label: String
    let onPress: (Bool) -> Void

    @State private var isPressed = false

    var body: some View {
        Text(label)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .frame(width: 52, height: 52)
            .background(Circle().fill(Color.white.opacity(isPressed ? 0.45 : 0.18)))
            .foregroundStyle(.white)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        onPress(true)
                    }
                    .onEnded { _ in
                        isPressed = false
                        onPress(false)
                    }
            )
    }
}

/// A drag-driven thumbstick reporting x and y in -1…1, y positive up.
struct FreeDeckVirtualStick: View {
    let size: CGFloat
    let label: String
    let onMove: (Double, Double) -> Void

    @State private var knob: CGSize = .zero

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.15))
                .frame(width: size, height: size)
            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: size * 0.42, height: size * 0.42)
                .offset(knob)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let radius = size / 2
                    let x = max(-1, min(1, value.translation.width / radius))
                    let y = max(-1, min(1, value.translation.height / radius))
                    knob = CGSize(width: x * radius, height: y * radius)
                    onMove(Double(x), Double(-y))
                }
                .onEnded { _ in
                    knob = .zero
                    onMove(0, 0)
                }
        )
    }
}

/// A d-pad: dragging a direction presses it, diagonals included.
struct FreeDeckVirtualDPad: View {
    let onMove: (Double, Double) -> Void

    @State private var x: Double = 0
    @State private var y: Double = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.15))
                .frame(width: 34, height: 98)
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.15))
                .frame(width: 98, height: 34)
            Image(systemName: "plus")
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(width: 108, height: 108)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let deadZone: CGFloat = 12
                    var nextX: Double = 0
                    var nextY: Double = 0
                    if abs(value.translation.width) > deadZone {
                        nextX = value.translation.width > 0 ? 1 : -1
                    }
                    if abs(value.translation.height) > deadZone {
                        // Screen y grows downwards; gamepad y grows up.
                        nextY = value.translation.height > 0 ? -1 : 1
                    }
                    guard nextX != x || nextY != y else { return }
                    x = nextX
                    y = nextY
                    onMove(nextX, nextY)
                }
                .onEnded { _ in
                    x = 0
                    y = 0
                    onMove(0, 0)
                }
        )
    }
}

/// The whole overlay: shoulder buttons up top, d-pad and left stick on the
/// face buttons' left, right stick on their right, start/menu along the
/// bottom. Every control sends the same snapshots the physical controllers
/// do.
struct FreeDeckVirtualGamepadView: View {
    let state: FreeDeckGamepadState
    var opacity: Double

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                FreeDeckVirtualButton(label: "LB") { state.setButton("lb", pressed: $0) }
                Spacer()
                FreeDeckVirtualButton(label: "RB") { state.setButton("rb", pressed: $0) }
            }

            HStack(alignment: .bottom) {
                VStack(spacing: 16) {
                    FreeDeckVirtualDPad { x, y in
                        state.setAxis("dpad", x: x, y: y)
                    }
                    FreeDeckVirtualStick(size: 96, label: "L") { x, y in
                        state.setAxis("leftStick", x: x, y: y)
                    }
                }

                Spacer()

                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        FreeDeckVirtualButton(label: "X") { state.setButton("x", pressed: $0) }
                        FreeDeckVirtualButton(label: "B") { state.setButton("b", pressed: $0) }
                    }
                    HStack(spacing: 12) {
                        FreeDeckVirtualButton(label: "Y") { state.setButton("y", pressed: $0) }
                        FreeDeckVirtualButton(label: "A") { state.setButton("a", pressed: $0) }
                    }
                    FreeDeckVirtualStick(size: 96, label: "R") { x, y in
                        state.setAxis("rightStick", x: x, y: y)
                    }
                }
            }

            HStack {
                FreeDeckVirtualButton(label: "\u{2630}") { state.setButton("menu", pressed: $0) }
                Spacer()
                FreeDeckVirtualButton(label: "\u{25B6}") { state.setButton("start", pressed: $0) }
            }
        }
        .padding(24)
        .opacity(opacity)
    }
}

// MARK: - WebPortRunnerView

/// Full-screen runner for one web port, with the virtual gamepad on top
/// and the toolbar: reload, open in Safari, cache status and gamepad
/// settings.
struct WebPortRunnerView: View {
    @StateObject private var model: FreeDeckWebPortModel

    init(webPortID: String, baseURL: URL, title: String) {
        _model = StateObject(wrappedValue: FreeDeckWebPortModel(
            webPortID: webPortID,
            baseURL: baseURL,
            title: title
        ))
    }

    var body: some View {
        ZStack {
            FreeDeckWebView(model: model)
                .ignoresSafeArea()

            if model.showsVirtualGamepad {
                VStack {
                    Spacer()
                    FreeDeckVirtualGamepadView(
                        state: model.virtualGamepad,
                        opacity: model.overlayOpacity
                    )
                }
                .allowsHitTesting(true)
            }

            if model.isLoading {
                ProgressView()
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }

                Button {
                    model.openInSafari()
                } label: {
                    Image(systemName: "safari")
                }

                Button {
                    model.showsVirtualGamepad.toggle()
                } label: {
                    Image(systemName: "gamecontroller")
                }
                .tint(model.showsVirtualGamepad ? .accentColor : .secondary)

                Button {
                    model.loadCacheSummary()
                    model.showsCacheStatus = true
                } label: {
                    Image(systemName: "internaldrive")
                }

                Button {
                    model.showsGamepadSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $model.showsCacheStatus) {
            cacheStatusSheet
        }
        .sheet(isPresented: $model.showsGamepadSettings) {
            gamepadSettingsSheet
        }
        .alert(
            "Web Port",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }

    // MARK: Sheets

    private var cacheStatusSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("Pages keep their own data in WKWebView's store: localStorage, IndexedDB, cookies and caches survive relaunches and are kept per origin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Origins with stored data") {
                    if model.cacheRecords.isEmpty {
                        Text("Nothing stored yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.cacheRecords, id: \.self) { name in
                            Text(name)
                        }
                    }
                }
                Section {
                    Button("Clear All Website Data", role: .destructive) {
                        model.clearWebsiteData()
                    }
                }
            }
            .navigationTitle("Cache")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.showsCacheStatus = false }
                }
            }
        }
    }

    private var gamepadSettingsSheet: some View {
        NavigationStack {
            Form {
                Section("Virtual Gamepad") {
                    Toggle("Show Overlay", isOn: $model.showsVirtualGamepad)
                    Slider(value: $model.overlayOpacity, in: 0.2...1.0) {
                        Text("Opacity")
                    }
                }
                Section("Mapping") {
                    Text("Physical controllers (MFi, Xbox, PlayStation) and the overlay both send 'freedeck-gamepad' events at window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("D-pad and thumbsticks arrive in detail.axes as dpad, leftStick and rightStick ([x, y], y positive up).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Buttons arrive in detail.buttons: a, b, x, y, lb, rb, start (options) and menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("JavaScript can postMessage to the 'freedeck' handler with {type: \"haptic\"} or {type: \"log\", message: \"…\"}.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Gamepad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.showsGamepadSettings = false }
                }
            }
        }
    }
}
