//
//  PairingManager.swift
//  LiveContainerSwiftUI
//
//  FreeDeck keeps its host pairing records the way pymobiledevice3 and
//  idevicepair leave them: a plist the user exports on a machine that has
//  paired with the device, and imports here. This file owns that import —
//  the document picker, the copy into Documents/pairing/, and the record of
//  what was imported — and everything the pairing file is for afterwards:
//
//  * LoopbackTunnelManager brings up the com.freedeck.LoopbackVPN tunnel
//    (a real NEPacketTunnelProvider lives in an app extension; this is the
//    app-side half that configures and starts it), and
//  * RemoteXPCBridge talks to whatever is listening on 127.0.0.1:5555 in
//    lockdownd style — length-prefixed plists asking for a service — and
//  * DVTLocationSpoofer sends the LocationSimulation requests over that
//    bridge, the same requests Instruments sends when you simulate a
//    location, so guest apps see coordinates of the user's choosing.
//
//  Nothing here depends on the rest of the app: the pairing record type, the
//  error type and every model are defined in this file, so it can be lifted
//  out on its own. Where the device will not coöperate — no tunnel
//  entitlement, no listener on the bridge port — the failure surfaces as a
//  message the view shows, never as a crash.
//

import Foundation
import Network
import NetworkExtension
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Pairing records

/// One imported pairing file, kept in UserDefaults alongside the copy of the
/// file itself in Documents/pairing/.
struct FreeDeckPairingRecord: Codable, Identifiable, Hashable {
    let id: String
    /// The name the copy in Documents/pairing/ was given.
    let fileName: String
    /// Path of the copy relative to the Documents directory, so the record
    /// survives the app container moving between builds.
    let relativePath: String
    let deviceName: String
    let importDate: Date
}

/// Everything that can go wrong on this page, in the user's words.
enum FreeDeckPairingError: LocalizedError {
    case notAPlist(String)
    case copyFailed(String)
    case tunnelUnavailable(String)
    case bridgeUnavailable(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAPlist(let name):
            return "\(name) is not a pairing plist — it could not be parsed."
        case .copyFailed(let reason):
            return "The pairing file could not be copied: \(reason)"
        case .tunnelUnavailable(let reason):
            return "The loopback tunnel is unavailable: \(reason)"
        case .bridgeUnavailable(let reason):
            return "The FreeDeck bridge is unavailable: \(reason)"
        case .requestFailed(let reason):
            return "The request failed: \(reason)"
        }
    }
}

/// What the inspector found in an imported file. A file is accepted as long
/// as it parses as a plist at all (host tools differ in what they include);
/// the pairing keys are only used to name the record.
struct FreeDeckPairingInspection {
    let deviceName: String
    let containsPairingKeys: Bool
}

// MARK: - PairingStore

/// The list of imported pairing files: copies in Documents/pairing/, records
/// in UserDefaults under `freedeck.pairing.records`.
final class PairingStore: ObservableObject {
    @Published private(set) var records: [FreeDeckPairingRecord] = []

    static let directoryName = "pairing"
    private static let defaultsKey = "freedeck.pairing.records"

    static var directoryURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    init() {
        records = Self.loadRecords()
    }

    // MARK: Importing

    /// Copies the picked file into Documents/pairing/ and records it. The
    /// url comes from UIDocumentPickerViewController, so it is
    /// security-scoped while we read it.
    @discardableResult
    func importPairingFile(from url: URL) throws -> FreeDeckPairingRecord {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer {
            if needsScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw FreeDeckPairingError.copyFailed(error.localizedDescription)
        }

        let inspection = try Self.inspect(data: data, fileName: url.lastPathComponent)

        do {
            try FileManager.default.createDirectory(
                at: Self.directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw FreeDeckPairingError.copyFailed(error.localizedDescription)
        }

        let destination = Self.directoryURL
            .appendingPathComponent(Self.uniqueFileName(from: url.lastPathComponent))
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw FreeDeckPairingError.copyFailed(error.localizedDescription)
        }

        let record = FreeDeckPairingRecord(
            id: UUID().uuidString,
            fileName: destination.lastPathComponent,
            relativePath: "\(Self.directoryName)/\(destination.lastPathComponent)",
            deviceName: inspection.deviceName,
            importDate: Date()
        )
        records.append(record)
        saveRecords()
        return record
    }

    // MARK: Listing and deleting

    func fileURL(for record: FreeDeckPairingRecord) -> URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(record.relativePath)
    }

    /// The record most recently imported, which is the one the tunnel and
    /// the bridge go by unless the user says otherwise.
    var mostRecentRecord: FreeDeckPairingRecord? {
        records.max(by: { $0.importDate < $1.importDate })
    }

    func delete(_ record: FreeDeckPairingRecord) {
        try? FileManager.default.removeItem(at: fileURL(for: record))
        records.removeAll { $0.id == record.id }
        saveRecords()
    }

    // MARK: Inspection

    /// Accepts anything that parses as a plist (host tools disagree on the
    /// exact keys); reads the device name from the keys pymobiledevice3 and
    /// idevicepair are known to write.
    static func inspect(data: Data, fileName: String) throws -> FreeDeckPairingInspection {
        let root: Any
        do {
            root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw FreeDeckPairingError.notAPlist(fileName)
        }

        guard let dictionary = root as? [String: Any] else {
            // Parsed, but not a dictionary: still a pairing file as far as
            // we can tell, just one we cannot name.
            return FreeDeckPairingInspection(deviceName: "Paired Device", containsPairingKeys: false)
        }

        let containsPairingKeys =
            dictionary["DeviceCertificate"] != nil || dictionary["HostID"] != nil
        let name = (dictionary["DeviceName"] as? String)
            ?? (dictionary["HostName"] as? String)
            ?? (dictionary["HostID"] as? String)
            ?? (dictionary["UniqueDeviceID"] as? String)
        return FreeDeckPairingInspection(
            deviceName: name ?? "Paired Device",
            containsPairingKeys: containsPairingKeys
        )
    }

    // MARK: Persistence

    private static func loadRecords() -> [FreeDeckPairingRecord] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return []
        }
        return (try? JSONDecoder().decode([FreeDeckPairingRecord].self, from: data)) ?? []
    }

    private func saveRecords() {
        guard let data = try? JSONEncoder().encode(records) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    /// Keeps the picker's name when it is free, adds -2, -3… when not, so
    /// two pairings of the same device do not overwrite each other.
    private static func uniqueFileName(from original: String) -> String {
        let base = (original as NSString).deletingPathExtension
        let pathExtension = (original as NSString).pathExtension
        var candidate = original
        var counter = 2
        while FileManager.default.fileExists(
            atPath: directoryURL.appendingPathComponent(candidate).path
        ) {
            candidate = pathExtension.isEmpty
                ? "\(base)-\(counter)"
                : "\(base)-\(counter).\(pathExtension)"
            counter += 1
        }
        return candidate
    }
}

// MARK: - Document picker

/// Wraps UIDocumentPickerViewController for the pairing file import. The
/// type list is deliberately loose (.data as a fallback) because
/// `.mobiledevicepairing` has no registered UTType; the extension is checked
/// after the pick instead of in the picker.
struct FreeDeckPairingDocumentPicker: UIViewControllerRepresentable {
    static let allowedExtensions = ["mobiledevicepairing", "plist"]

    var onPick: (URL) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        var contentTypes: [UTType] = [.propertyList]
        if let pairingType = UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data) {
            contentTypes.append(pairingType)
        }
        contentTypes.append(.data)

        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes,
            asCopy: false
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
        // Nothing to update: the picker is created per presentation.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: FreeDeckPairingDocumentPicker

        init(_ parent: FreeDeckPairingDocumentPicker) {
            self.parent = parent
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else {
                parent.onCancel()
                return
            }
            // Any extension goes through: the store decides what parses, and
            // host tools name their exports inconsistently.
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}

// MARK: - LoopbackTunnelManager

/// The app side of the loopback VPN. A real NEPacketTunnelProvider needs an
/// app extension (FreeDeck's is com.freedeck.LoopbackVPN); all this manager
/// does is find or build the NETunnelProviderManager for it, hand it the
/// pairing file to use, start it, and follow its status. Every step that can
/// fail — no entitlement, extension not embedded, user denial — lands in
/// `state` where the view shows it.
@MainActor
final class LoopbackTunnelManager: ObservableObject {
    enum TunnelState: Equatable {
        case idle
        case configuring
        case connecting
        case connected
        case disconnecting
        case unavailable(String)
    }

    /// Must match the Packet Tunnel Provider extension's bundle identifier.
    static let providerBundleIdentifier = "com.freedeck.LoopbackVPN"
    /// The address guests reach the tunnel's helper on; the provider decides
    /// what actually listens, but NEVPNProtocol wants a server address.
    static let serverAddress = "127.0.0.1"

    @Published private(set) var state: TunnelState = .idle

    private var manager: NETunnelProviderManager?
    private var statusTimer: Timer?

    var isConnected: Bool { state == .connected }

    var statusText: String {
        switch state {
        case .idle: return "Stopped"
        case .configuring: return "Configuring…"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnecting: return "Disconnecting…"
        case .unavailable(let reason): return "Unavailable — \(reason)"
        }
    }

    // MARK: Starting and stopping

    /// Saves the VPN configuration (creating it on first use) and starts the
    /// tunnel. `pairingFileURL` is placed in the provider configuration so
    /// the extension knows which pairing to use.
    func start(pairingFileURL: URL?) async {
        state = .configuring
        do {
            let manager = try await loadOrCreateManager()
            self.manager = manager

            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = Self.providerBundleIdentifier
            configuration.serverAddress = Self.serverAddress
            var providerConfiguration: [String: Any] = [:]
            if let pairingFileURL {
                providerConfiguration["pairingFilePath"] = pairingFileURL.path
            }
            providerConfiguration["bridgePort"] = 5555
            configuration.providerConfiguration = providerConfiguration
            manager.protocolConfiguration = configuration
            manager.localizedDescription = "FreeDeck Loopback"
            manager.isEnabled = true

            try await save(manager)
            try startTunnel(manager)
            state = .connecting
            startStatusPolling()
        } catch {
            state = .unavailable(error.localizedDescription)
        }
    }

    func stop() {
        statusTimer?.invalidate()
        statusTimer = nil
        guard let manager else {
            state = .idle
            return
        }
        state = .disconnecting
        manager.connection.stopVPNTunnel()
        state = .idle
    }

    /// Reads the connection status into `state`; called by the poll timer
    /// and safe to call from the view.
    func refreshStatus() {
        guard let manager else {
            return
        }
        switch manager.connection.status {
        case .connected:
            state = .connected
        case .connecting, .reasserting:
            state = .connecting
        case .disconnecting:
            state = .disconnecting
        case .disconnected, .invalid:
            if state == .connecting || state == .connected {
                state = .idle
            }
        @unknown default:
            break
        }
    }

    // MARK: Preferences

    /// Finds the manager saved under our description, or makes one. A
    /// description match is used instead of the bundle identifier because
    /// that lives inside the extension and is not readable from here.
    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        let managers = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[NEVPNManager], Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }

        if let existing = managers
            .compactMap({ $0 as? NETunnelProviderManager })
            .first(where: { $0.localizedDescription == "FreeDeck Loopback" })
        {
            return existing
        }
        return NETunnelProviderManager()
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func startTunnel(_ manager: NETunnelProviderManager) throws {
        guard let session = manager.connection as? NETunnelProviderSession else {
            throw FreeDeckPairingError.tunnelUnavailable(
                "the saved configuration has no tunnel session"
            )
        }
        do {
            try session.startVPNTunnel(options: nil)
        } catch {
            throw FreeDeckPairingError.tunnelUnavailable(error.localizedDescription)
        }
    }

    /// The status notification's name is not imported into the SDK's
    /// NSNotification.Name namespace reliably across versions, so the
    /// connection status is polled while the tunnel is up instead. One tick
    /// per second for the seconds a start takes is cheaper than guessing a
    /// notification name wrong.
    private func startStatusPolling() {
        statusTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatus()
            }
        }
        statusTimer = timer
    }
}

// MARK: - RemoteXPCBridge

/// A TCP stand-in for RemoteXPC: connect to 127.0.0.1:5555 (where the
/// loopback tunnel's helper listens) and exchange length-prefixed XML plists
/// — a 4-byte big-endian length, then the plist body — asking for a service
/// by name, the way lockdownd conversations are framed. Requests are
/// dictionaries with "service", "method" and optional "payload" keys.
final class RemoteXPCBridge {
    struct Configuration {
        var host: String = "127.0.0.1"
        var port: UInt16 = 5555
    }

    enum BridgeError: LocalizedError {
        case notConnected
        case connectFailed(String)
        case sendFailed(String)
        case receiveFailed(String)
        case badResponse(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Not connected to the FreeDeck bridge."
            case .connectFailed(let reason):
                return "Could not connect to the bridge: \(reason)"
            case .sendFailed(let reason):
                return "Could not send to the bridge: \(reason)"
            case .receiveFailed(let reason):
                return "Could not read from the bridge: \(reason)"
            case .badResponse(let reason):
                return "The bridge sent an unreadable reply: \(reason)"
            case .timedOut:
                return "The bridge did not answer in time."
            }
        }
    }

    var configuration: Configuration

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "freedeck.remote-xpc-bridge")

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    var isConnected: Bool {
        connection?.state == .ready
    }

    // MARK: Connection

    func connect() async throws {
        if isConnected {
            return
        }
        disconnect()

        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw BridgeError.connectFailed("port \(configuration.port) is out of range")
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(configuration.host),
            port: port,
            using: .tcp
        )
        self.connection = connection

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let box = FreeDeckContinuationBox(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.resume(with: .success(()))
                case .failed(let error):
                    box.resume(with: .failure(BridgeError.connectFailed(error.localizedDescription)))
                case .cancelled:
                    box.resume(with: .failure(BridgeError.notConnected))
                default:
                    break // .setup, .preparing, .waiting — keep waiting.
                }
            }
            connection.start(queue: queue)
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }

    // MARK: Requests

    /// Sends one request plist and returns the reply plist.
    func send(request: [String: Any]) async throws -> [String: Any] {
        guard let connection, connection.state == .ready else {
            throw BridgeError.notConnected
        }

        let body: Data
        do {
            body = try PropertyListSerialization.data(
                fromPropertyList: request,
                format: .xml,
                options: 0
            )
        } catch {
            throw BridgeError.sendFailed(error.localizedDescription)
        }

        var length = UInt32(body.count).bigEndian
        let frame = Data(bytes: &length, count: 4) + body

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let box = FreeDeckContinuationBox(continuation)
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    box.resume(with: .failure(BridgeError.sendFailed(error.localizedDescription)))
                } else {
                    box.resume(with: .success(()))
                }
            })
        }

        let replyFrame = try await receiveFrame(on: connection)
        let reply: Any
        do {
            reply = try PropertyListSerialization.propertyList(
                from: replyFrame,
                options: [],
                format: nil
            )
        } catch {
            throw BridgeError.badResponse(error.localizedDescription)
        }
        guard let dictionary = reply as? [String: Any] else {
            throw BridgeError.badResponse("the reply was not a dictionary plist")
        }
        return dictionary
    }

    // MARK: Framing

    private func receiveFrame(on connection: NWConnection) async throws -> Data {
        let header = try await receiveExactly(4, on: connection)
        // Copy before reading: Data's bytes have no alignment guarantee.
        var bigEndianLength: UInt32 = 0
        withUnsafeMutableBytes(of: &bigEndianLength) { buffer in
            _ = header.copyBytes(to: buffer, from: 0..<4)
        }
        let length = UInt32(bigEndian: bigEndianLength)
        guard length > 0, length < 64 * 1024 * 1024 else {
            throw BridgeError.badResponse("implausible frame length \(length)")
        }
        return try await receiveExactly(Int(length), on: connection)
    }

    private func receiveExactly(_ count: Int, on connection: NWConnection) async throws -> Data {
        let chunk = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            let box = FreeDeckContinuationBox(continuation)
            connection.receive(
                minimumIncompleteLength: count,
                maximumLength: max(count, 1)
            ) { data, _, isComplete, error in
                if let error {
                    box.resume(with: .failure(BridgeError.receiveFailed(error.localizedDescription)))
                } else if let data, data.count == count {
                    box.resume(with: .success(data))
                } else if isComplete {
                    box.resume(with: .failure(BridgeError.receiveFailed("the bridge closed early")))
                } else {
                    // Short but open: what arrived is all we get for now.
                    box.resume(with: .success(data ?? Data()))
                }
            }
        }
        guard chunk.count == count else {
            throw BridgeError.receiveFailed("wanted \(count) bytes, got \(chunk.count)")
        }
        return chunk
    }
}

/// Resumes a checked continuation at most once. Network callbacks can fire
/// more than once (a connection that is ready can still fail afterwards) and
/// a double resume traps.
final class FreeDeckContinuationBox<T> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else {
            return
        }
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

// MARK: - DVTLocationSpoofer

/// Sends the requests Instruments sends when it simulates a location, over
/// the bridge instead of a debugger: the LocationSimulation service with a
/// keyed-archived {latitude, longitude, altitude} payload. `stop()` puts the
/// real location back.
final class DVTLocationSpoofer {
    static let serviceName = "com.apple.instruments.server.services.LocationSimulation"
    static let simulateMethod = "simulateLocationWithLatitude:longitude:"
    static let clearMethod = "clearSimulatedLocation"

    private let bridge: RemoteXPCBridge

    init(bridge: RemoteXPCBridge) {
        self.bridge = bridge
    }

    /// Makes the device report the given coordinates until `stop()`.
    func start(latitude: Double, longitude: Double) async throws {
        let payload = try Self.archivedPayload([
            "latitude": latitude,
            "longitude": longitude,
            "altitude": 0.0
        ])
        _ = try await bridge.send(request: [
            "service": Self.serviceName,
            "method": Self.simulateMethod,
            "payload": payload
        ])
    }

    /// Drops the simulated location, letting CoreLocation report the real
    /// one again.
    func clearLocation() async throws {
        _ = try await bridge.send(request: [
            "service": Self.serviceName,
            "method": Self.clearMethod
        ])
    }

    func stop() async throws {
        try await clearLocation()
    }

    /// The instruments transport wraps its arguments as keyed archives;
    /// NSKeyedArchiver produces the same bytes without a debugger being
    /// involved.
    private static func archivedPayload(_ payload: [String: Any]) throws -> Data {
        do {
            return try NSKeyedArchiver.archivedData(
                withRootObject: payload as NSDictionary,
                requiringSecureCoding: false
            )
        } catch {
            throw FreeDeckPairingError.requestFailed(
                "the location payload could not be encoded: \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - PairingManager

/// The page's model: the pairing files, the tunnel, and the location
/// spoofer's quick control, with whatever went wrong left for the view to
/// show.
@MainActor
final class PairingManager: ObservableObject {
    let pairingStore = PairingStore()
    let tunnel = LoopbackTunnelManager()

    @Published var lastError: String?
    @Published var isImporting = false
    @Published var isSpoofing = false

    /// Built lazily from the bridge; nil until a spoof is asked for.
    private var bridge: RemoteXPCBridge?
    private var spoofer: DVTLocationSpoofer?

    /// The pairing file the tunnel is configured with: the last import.
    var activePairingFileURL: URL? {
        pairingStore.mostRecentRecord.map { pairingStore.fileURL(for: $0) }
    }

    // MARK: Importing

    func importFile(from url: URL) {
        do {
            try pairingStore.importPairingFile(from: url)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        isImporting = false
    }

    func delete(_ record: FreeDeckPairingRecord) {
        pairingStore.delete(record)
    }

    // MARK: Tunnel

    func startTunnel() async {
        await tunnel.start(pairingFileURL: activePairingFileURL)
        if case .unavailable(let reason) = tunnel.state {
            lastError = FreeDeckPairingError.tunnelUnavailable(reason).localizedDescription
        }
    }

    func stopTunnel() {
        tunnel.stop()
    }

    // MARK: Location spoofing

    func startSpoofing(latitude: Double, longitude: Double) async {
        do {
            let spoofer = try await connectedSpoofer()
            try await spoofer.start(latitude: latitude, longitude: longitude)
            isSpoofing = true
            lastError = nil
        } catch {
            isSpoofing = false
            lastError = error.localizedDescription
        }
    }

    func stopSpoofing() async {
        do {
            try await spoofer?.stop()
            isSpoofing = false
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func connectedSpoofer() async throws -> DVTLocationSpoofer {
        if let spoofer, bridge?.isConnected == true {
            return spoofer
        }
        let bridge = self.bridge ?? RemoteXPCBridge()
        self.bridge = bridge

        let spoofer = DVTLocationSpoofer(bridge: bridge)
        self.spoofer = spoofer

        // connect() suspends until the socket is ready or fails; the error
        // surfaces through lastError as every other failure does.
        try await bridge.connect()
        return spoofer
    }
}

// MARK: - PairingManagerView

/// The pairing page: import button, the list of imported pairing files, the
/// tunnel's start/stop and status, and a quick control for spoofing a
/// location over the bridge. The sections observe the objects that actually
/// publish (the store and the tunnel), since nested ObservableObjects do
/// not forward their changes.
struct PairingManagerView: View {
    @StateObject private var manager = PairingManager()
    @State private var showsImporter = false

    var body: some View {
        List {
            FreeDeckPairingFilesSection(
                store: manager.pairingStore,
                onImport: { showsImporter = true },
                onDelete: { manager.delete($0) }
            )
            FreeDeckTunnelSection(manager: manager, tunnel: manager.tunnel)
            FreeDeckLocationSection(manager: manager)
        }
        .navigationTitle("Device Pairing")
        .sheet(isPresented: $showsImporter) {
            FreeDeckPairingDocumentPicker(
                onPick: { url in
                    manager.importFile(from: url)
                    showsImporter = false
                },
                onCancel: {
                    showsImporter = false
                }
            )
            .ignoresSafeArea()
        }
        .alert(
            "Pairing",
            isPresented: Binding(
                get: { manager.lastError != nil },
                set: { if !$0 { manager.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(manager.lastError ?? "")
        }
    }
}

/// The imported pairing files, with the import button on top.
private struct FreeDeckPairingFilesSection: View {
    @ObservedObject var store: PairingStore
    var onImport: () -> Void
    var onDelete: (FreeDeckPairingRecord) -> Void

    var body: some View {
        Section {
            Button(action: onImport) {
                Label("Import Pairing File", systemImage: "square.and.arrow.down")
            }

            ForEach(store.records) { record in
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.deviceName)
                        .font(.body)
                    Text(record.fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(record.importDate, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        onDelete(record)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("Pairing Files")
        } footer: {
            Text("Pairing files from pymobiledevice3 or idevicepair (.mobiledevicepairing, .plist). The tunnel and bridge use the most recent one.")
        }
    }
}

/// The tunnel's status and its start/stop.
private struct FreeDeckTunnelSection: View {
    @ObservedObject var manager: PairingManager
    @ObservedObject var tunnel: LoopbackTunnelManager

    var body: some View {
        Section {
            HStack {
                Label("Loopback Tunnel", systemImage: "network")
                Spacer()
                Text(tunnel.statusText)
                    .foregroundStyle(.secondary)
            }

            if tunnel.isConnected {
                Button("Stop Tunnel", role: .destructive) {
                    manager.stopTunnel()
                }
            } else {
                Button("Start Tunnel") {
                    Task { await manager.startTunnel() }
                }
                .disabled(manager.pairingStore.records.isEmpty)
            }
        } header: {
            Text("Tunnel")
        } footer: {
            Text("Starts the \(LoopbackTunnelManager.providerBundleIdentifier) tunnel with the most recent pairing file. Needs the FreeDeck VPN entitlement and the tunnel extension to be embedded.")
        }
    }
}

/// The location-spoof quick control: coordinates in, simulate or clear.
private struct FreeDeckLocationSection: View {
    @ObservedObject var manager: PairingManager
    @State private var latitudeText = "37.3349"
    @State private var longitudeText = "-122.0090"

    var body: some View {
        Section {
            TextField("Latitude", text: $latitudeText)
                .keyboardType(.numbersAndPunctuation)
            TextField("Longitude", text: $longitudeText)
                .keyboardType(.numbersAndPunctuation)

            HStack {
                Button(manager.isSpoofing ? "Update Location" : "Simulate Location") {
                    Task {
                        await manager.startSpoofing(
                            latitude: Double(latitudeText) ?? 0,
                            longitude: Double(longitudeText) ?? 0
                        )
                    }
                }
                .disabled(latitudeText.isEmpty || longitudeText.isEmpty)

                Spacer()

                Button("Clear", role: .destructive) {
                    Task { await manager.stopSpoofing() }
                }
                .disabled(!manager.isSpoofing)
            }
        } header: {
            Text("Location Simulation")
        } footer: {
            Text(manager.isSpoofing
                 ? "Simulating \(latitudeText), \(longitudeText)."
                 : "Sends Instruments' LocationSimulation request over the loopback bridge.")
        }
    }
}
