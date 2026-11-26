//
//  ServerLibraryView.swift
//  LiveContainerSwiftUI
//
//  The catalog of what the FreeDeck Linux server has on offer: a
//  searchable list of IPAs, apps and web ports, installed onto the server
//  with POST /api/install and watched through /api/tasks/{id} until the
//  server reports the job done. The server's address and bearer token live
//  in UserDefaults (`freedeck.server`, `freedeck.token`), editable from the
//  settings sheet on this page.
//
//  The client is plain async/await URLSession with tolerant decoding —
//  server builds differ in small field names (size vs size_bytes, task id
//  vs taskId), and a catalog page should not care. Every type this page
//  needs is defined here, so the file stands alone.
//

import Foundation
import SwiftUI

// MARK: - Models

/// What kind of thing a catalog entry is.
enum FreeDeckLibraryEntryType: String, Codable, CaseIterable {
    case ipa
    case app
    case webPort
    case unknown

    /// Servers spell these differently; accept the common spellings.
    init(fromRawValue raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ipa", "ios", "application/x-ios-app":
            self = .ipa
        case "app", "application", "bundle":
            self = .app
        case "webport", "web_port", "web port", "web", "html":
            self = .webPort
        default:
            self = .unknown
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(fromRawValue: (try? container.decode(String.self)) ?? "unknown")
    }

    var displayName: String {
        switch self {
        case .ipa: return "IPA"
        case .app: return "App"
        case .webPort: return "Web Port"
        case .unknown: return "Other"
        }
    }

    /// The badge color on the row.
    var badgeColor: Color {
        switch self {
        case .ipa: return .blue
        case .app: return .green
        case .webPort: return .orange
        case .unknown: return .gray
        }
    }
}

/// One entry in the server's catalog.
struct FreeDeckLibraryEntry: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let type: FreeDeckLibraryEntryType
    let sizeBytes: Int64?
    let summary: String?
    let version: String?
    /// Where the server can fetch the entry's payload from, when it says.
    let downloadURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case version
        case summary = "description"
        case size = "size"
        case sizeBytes = "size_bytes"
        case sizeCamel = "sizeBytes"
        case download = "url"
        case downloadURL = "download_url"
        case downloadAlt = "downloadURL"
    }

    init(id: String, name: String, type: FreeDeckLibraryEntryType,
         sizeBytes: Int64?, summary: String?, version: String?,
         downloadURL: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.sizeBytes = sizeBytes
        self.summary = summary
        self.version = version
        self.downloadURL = downloadURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // The id is a string on some builds and a number on others.
        if let string = try? container.decode(String.self, forKey: .id) {
            id = string
        } else if let number = try? container.decode(Int64.self, forKey: .id) {
            id = String(number)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: container, debugDescription: "entry has no id"
            )
        }

        name = (try? container.decode(String.self, forKey: .name)) ?? id
        type = (try? container.decode(FreeDeckLibraryEntryType.self, forKey: .type)) ?? .unknown
        sizeBytes = (try? container.decode(Int64.self, forKey: .sizeBytes))
            ?? (try? container.decode(Int64.self, forKey: .size))
            ?? (try? container.decode(Int64.self, forKey: .sizeCamel))
        summary = (try? container.decode(String.self, forKey: .summary)) ?? nil
        version = (try? container.decode(String.self, forKey: .version)) ?? nil
        downloadURL = (try? container.decode(String.self, forKey: .download))
            ?? (try? container.decode(String.self, forKey: .downloadURL))
            ?? (try? container.decode(String.self, forKey: .downloadAlt))
            ?? nil
    }

    var formattedSize: String? {
        guard let sizeBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// The body of POST /api/install.
struct FreeDeckInstallRequest: Codable {
    let url: String
    let name: String
    let type: String
}

/// One job on the server, as reported by GET /api/tasks/{id}.
struct FreeDeckTaskStatus: Decodable, Identifiable, Hashable {
    enum State: String {
        case pending
        case running
        case succeeded
        case failed
        case unknown

        init(fromRawValue raw: String) {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "pending", "queued", "waiting":
                self = .pending
            case "running", "installing", "in_progress", "working":
                self = .running
            case "succeeded", "success", "done", "completed", "finished":
                self = .succeeded
            case "failed", "error", "cancelled", "canceled":
                self = .failed
            default:
                self = .unknown
            }
        }

        var isFinished: Bool { self == .succeeded || self == .failed }
    }

    let id: String
    let state: State
    /// 0…1 when the server reports progress, nil when it does not.
    let progress: Double?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case id
        case state
        case status
        case progress
        case message
    }

    init(id: String, state: State, progress: Double?, message: String?) {
        self.id = id
        self.state = state
        self.progress = progress
        self.message = message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? container.decode(String.self, forKey: .id) {
            id = string
        } else if let number = try? container.decode(Int64.self, forKey: .id) {
            id = String(number)
        } else {
            id = ""
        }
        let rawState = (try? container.decode(String.self, forKey: .state))
            ?? (try? container.decode(String.self, forKey: .status))
            ?? "unknown"
        state = State(fromRawValue: rawState)

        // Progress may be 0…1 or 0…100 depending on the build.
        var rawProgress = (try? container.decode(Double.self, forKey: .progress)) ?? nil
        if let value = rawProgress, value > 1.0 {
            rawProgress = min(value / 100.0, 1.0)
        }
        progress = rawProgress
        message = (try? container.decode(String.self, forKey: .message)) ?? nil
    }
}

// MARK: - Client

enum FreeDeckServerError: LocalizedError {
    case notConfigured
    case badStatus(Int, String?)
    case unreadableReply(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No FreeDeck server is configured. Set the server address in Settings."
        case .badStatus(let code, let body):
            if let body, !body.isEmpty {
                return "The server answered \(code): \(body)"
            }
            return "The server answered \(code)."
        case .unreadableReply(let reason):
            return "The server's reply could not be read: \(reason)"
        case .transport(let reason):
            return "The server could not be reached: \(reason)"
        }
    }
}

/// The FreeDeck server API:
///   GET    {base}/api/library          — the catalog
///   GET    {base}/api/library/{id}     — one entry
///   POST   {base}/api/install          — {url, name, type} → task id
///   DELETE {base}/api/library/{id}     — remove an entry
///   GET    {base}/api/health           — liveness
///   GET    {base}/api/tasks/{id}       — install task status
/// All calls carry `Authorization: Bearer <token>` when a token is set.
struct FreeDeckServerClient {
    let baseURL: URL
    let token: String?

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    init(baseURL: URL, token: String?) {
        self.baseURL = baseURL
        self.token = token
    }

    // MARK: Endpoints

    /// GET /api/health — succeeds when the server answers 2xx.
    func health() async throws {
        _ = try await request(.get, path: "api/health", body: Optional<Data>.none)
    }

    /// GET /api/library
    func library() async throws -> [FreeDeckLibraryEntry] {
        let data = try await request(.get, path: "api/library", body: Optional<Data>.none)
        return try Self.decodeLibrary(data)
    }

    /// GET /api/library/{id}
    func entry(id: String) async throws -> FreeDeckLibraryEntry {
        let data = try await request(.get, path: "api/library/\(id)", body: Optional<Data>.none)
        do {
            return try JSONDecoder().decode(FreeDeckLibraryEntry.self, from: data)
        } catch {
            throw FreeDeckServerError.unreadableReply(error.localizedDescription)
        }
    }

    /// POST /api/install — returns the task id to poll.
    @discardableResult
    func install(url: String, name: String, type: String) async throws -> String {
        let body = try JSONEncoder().encode(FreeDeckInstallRequest(url: url, name: name, type: type))
        let data = try await request(.post, path: "api/install", body: body)
        return Self.decodeTaskID(data)
    }

    /// DELETE /api/library/{id}
    func deleteEntry(id: String) async throws {
        _ = try await request(.delete, path: "api/library/\(id)", body: Optional<Data>.none)
    }

    /// GET /api/tasks/{id}
    func task(id: String) async throws -> FreeDeckTaskStatus {
        let data = try await request(.get, path: "api/tasks/\(id)", body: Optional<Data>.none)
        do {
            return try JSONDecoder().decode(FreeDeckTaskStatus.self, from: data)
        } catch {
            throw FreeDeckServerError.unreadableReply(error.localizedDescription)
        }
    }

    /// GET {base}/webport/{id}/ — where a web port runs, also opened by
    /// WebPortRunnerView.
    func webPortURL(id: String) -> URL {
        baseURL.appendingPathComponent("webport").appendingPathComponent(id)
    }

    // MARK: Plumbing

    private enum HTTPMethod: String {
        case get = "GET"
        case post = "POST"
        case delete = "DELETE"
    }

    private func request(_ method: HTTPMethod, path: String, body: Data?) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw FreeDeckServerError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw FreeDeckServerError.unreadableReply("the reply was not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw FreeDeckServerError.badStatus(http.statusCode, body)
        }
        return data
    }

    /// The catalog is either a bare array or wrapped in an object; accept
    /// both, and the common wrapper keys.
    private static func decodeLibrary(_ data: Data) throws -> [FreeDeckLibraryEntry] {
        if let entries = try? JSONDecoder().decode([FreeDeckLibraryEntry].self, from: data) {
            return entries
        }
        struct Envelope: Decodable {
            let items: [FreeDeckLibraryEntry]?
            let entries: [FreeDeckLibraryEntry]?
            let library: [FreeDeckLibraryEntry]?
            let apps: [FreeDeckLibraryEntry]?
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            if let entries = envelope.items ?? envelope.entries ?? envelope.library ?? envelope.apps {
                return entries
            }
        }
        throw FreeDeckServerError.unreadableReply("the catalog was not in a known shape")
    }

    /// POST /api/install answers with the task id under one of a few keys,
    /// sometimes nested in a "task" object.
    private static func decodeTaskID(_ data: Data) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ""
        }
        for key in ["id", "taskId", "task_id"] {
            if let value = object[key] as? String {
                return value
            }
            if let value = object[key] as? Int {
                return String(value)
            }
        }
        if let task = object["task"] as? [String: Any] {
            for key in ["id", "taskId", "task_id"] {
                if let value = task[key] as? String {
                    return value
                }
                if let value = task[key] as? Int {
                    return String(value)
                }
            }
        }
        return ""
    }
}

// MARK: - Settings

/// The server address and token, kept in UserDefaults under the keys the
/// rest of the FreeDeck stack reads.
@MainActor
final class FreeDeckServerSettings: ObservableObject {
    static let serverDefaultsKey = "freedeck.server"
    static let tokenDefaultsKey = "freedeck.token"

    @Published var baseURLString: String {
        didSet { UserDefaults.standard.set(baseURLString, forKey: Self.serverDefaultsKey) }
    }
    @Published var token: String {
        didSet { UserDefaults.standard.set(token, forKey: Self.tokenDefaultsKey) }
    }

    init() {
        let defaults = UserDefaults.standard
        baseURLString = defaults.string(forKey: Self.serverDefaultsKey) ?? ""
        token = defaults.string(forKey: Self.tokenDefaultsKey) ?? ""
    }

    var baseURL: URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    func makeClient() throws -> FreeDeckServerClient {
        guard let baseURL else {
            throw FreeDeckServerError.notConfigured
        }
        return FreeDeckServerClient(baseURL: baseURL, token: token)
    }
}

// MARK: - View model

/// What the list shows per entry while an install runs.
struct FreeDeckInstallStatus: Equatable {
    enum Phase: Equatable {
        case idle
        case starting
        case running(Double?)
        case succeeded
        case failed(String)
    }

    var phase: Phase = .idle

    var isBusy: Bool {
        switch phase {
        case .starting, .running:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class FreeDeckLibraryViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var entries: [FreeDeckLibraryEntry] = []
    @Published private(set) var installStatuses: [String: FreeDeckInstallStatus] = [:]

    private var poller: Task<Void, Never>?

    func load(using client: FreeDeckServerClient) async {
        state = .loading
        do {
            entries = try await client.library()
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Records a failure that happened before a load could start (no server
    /// configured, for instance).
    func fail(with message: String) {
        state = .failed(message)
    }

    func status(for entry: FreeDeckLibraryEntry) -> FreeDeckInstallStatus {
        installStatuses[entry.id] ?? FreeDeckInstallStatus()
    }

    /// POSTs the install and polls /api/tasks/{id} every two seconds until
    /// the server calls it done, giving up after five minutes and leaving
    /// the row in its failed state.
    func install(_ entry: FreeDeckLibraryEntry, using client: FreeDeckServerClient) async {
        guard !status(for: entry).isBusy else { return }
        installStatuses[entry.id] = FreeDeckInstallStatus(phase: .starting)

        let taskID: String
        do {
            taskID = try await client.install(
                url: entry.downloadURL ?? entry.id,
                name: entry.name,
                type: entry.type.rawValue
            )
        } catch {
            installStatuses[entry.id] = FreeDeckInstallStatus(phase: .failed(error.localizedDescription))
            return
        }
        guard !taskID.isEmpty else {
            installStatuses[entry.id] = FreeDeckInstallStatus(phase: .failed("the server did not return a task id"))
            return
        }

        installStatuses[entry.id] = FreeDeckInstallStatus(phase: .running(nil))
        poller?.cancel()
        poller = Task { [weak self] in
            await self?.poll(taskID: taskID, entryID: entry.id, using: client)
        }
        await poller?.value
    }

    private func poll(taskID: String, entryID: String, using client: FreeDeckServerClient) async {
        var attempts = 0
        while !Task.isCancelled && attempts < 150 {
            attempts += 1
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            do {
                let status = try await client.task(id: taskID)
                switch status.state {
                case .succeeded:
                    installStatuses[entryID] = FreeDeckInstallStatus(phase: .succeeded)
                    return
                case .failed:
                    installStatuses[entryID] = FreeDeckInstallStatus(
                        phase: .failed(status.message ?? "the server reported a failure")
                    )
                    return
                case .pending, .running, .unknown:
                    installStatuses[entryID] = FreeDeckInstallStatus(phase: .running(status.progress))
                }
            } catch {
                installStatuses[entryID] = FreeDeckInstallStatus(phase: .failed(error.localizedDescription))
                return
            }
        }
        if !Task.isCancelled {
            installStatuses[entryID] = FreeDeckInstallStatus(phase: .failed("the install did not finish in time"))
        }
    }

    func delete(_ entry: FreeDeckLibraryEntry, using client: FreeDeckServerClient) async {
        do {
            try await client.deleteEntry(id: entry.id)
            entries.removeAll { $0.id == entry.id }
            installStatuses[entry.id] = nil
        } catch {
            installStatuses[entry.id] = FreeDeckInstallStatus(phase: .failed(error.localizedDescription))
        }
    }
}

// MARK: - Views

/// The server catalog: searchable rows with type badges and sizes, install
/// with live task progress, delete with confirmation, and a launch button
/// for web ports (which open in WebPortRunnerView).
struct ServerLibraryView: View {
    @StateObject private var settings = FreeDeckServerSettings()
    @StateObject private var viewModel = FreeDeckLibraryViewModel()

    @State private var searchText = ""
    @State private var showsSettings = false
    @State private var entryToDelete: FreeDeckLibraryEntry?

    var body: some View {
        content
            .navigationTitle("Server Library")
            .searchable(text: $searchText, prompt: "Search the catalog")
            .refreshable { await reload() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showsSettings) {
                FreeDeckServerSettingsView(settings: settings)
            }
            .confirmationDialog(
                entryToDelete.map { "Delete \($0.name) from the server?" } ?? "Delete?",
                isPresented: Binding(
                    get: { entryToDelete != nil },
                    set: { if !$0 { entryToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let entryToDelete, let client = try? settings.makeClient() {
                        Task { await viewModel.delete(entryToDelete, using: client) }
                    }
                    entryToDelete = nil
                }
                Button("Cancel", role: .cancel) { entryToDelete = nil }
            }
            .task {
                if viewModel.state == .idle {
                    await reload()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView("Loading catalog…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    Task { await reload() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if filteredEntries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(searchText.isEmpty
                         ? "The server's catalog is empty."
                         : "Nothing matches \u{201C}\(searchText)\u{201D}.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredEntries) { entry in
                        row(for: entry)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private var filteredEntries: [FreeDeckLibraryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.entries }
        return viewModel.entries.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.summary?.localizedCaseInsensitiveContains(query) ?? false)
                || $0.type.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    private func row(for entry: FreeDeckLibraryEntry) -> some View {
        let status = viewModel.status(for: entry)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.name)
                    .font(.headline)
                Spacer()
                Text(entry.type.displayName)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(entry.type.badgeColor.opacity(0.15))
                    .foregroundStyle(entry.type.badgeColor)
                    .clipShape(Capsule())
            }

            if let summary = entry.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                if let size = entry.formattedSize {
                    Label(size, systemImage: "internaldrive")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let version = entry.version, !version.isEmpty {
                    Label(version, systemImage: "number")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            switch status.phase {
            case .idle:
                actions(for: entry)
            case .starting:
                ProgressView("Contacting server…")
                    .font(.caption)
            case .running(let progress):
                if let progress {
                    ProgressView(value: progress) {
                        Text("Installing…").font(.caption)
                    }
                } else {
                    ProgressView("Installing…")
                        .font(.caption)
                }
            case .succeeded:
                Label("Installed", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Label(message, systemImage: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                    actions(for: entry)
                }
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                entryToDelete = entry
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func actions(for entry: FreeDeckLibraryEntry) -> some View {
        HStack(spacing: 16) {
            Button {
                if let client = try? settings.makeClient() {
                    Task { await viewModel.install(entry, using: client) }
                } else {
                    showsSettings = true
                }
            } label: {
                Label("Install to Server", systemImage: "arrow.down.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            if entry.type == .webPort, let baseURL = settings.baseURL {
                NavigationLink {
                    WebPortRunnerView(
                        webPortID: entry.id,
                        baseURL: baseURL,
                        title: entry.name
                    )
                } label: {
                    Label("Launch", systemImage: "play.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            Button(role: .destructive) {
                entryToDelete = entry
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }

    private func reload() async {
        do {
            let client = try settings.makeClient()
            await viewModel.load(using: client)
        } catch {
            viewModel.fail(with: error.localizedDescription)
        }
    }
}

// MARK: - Settings sheet

/// Base URL and bearer token, saved to UserDefaults as they are typed.
struct FreeDeckServerSettingsView: View {
    @ObservedObject var settings: FreeDeckServerSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://100.64.0.1:8080", text: $settings.baseURLString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Optional bearer token", text: $settings.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    Text("Stored as \(FreeDeckServerSettings.serverDefaultsKey) and \(FreeDeckServerSettings.tokenDefaultsKey).")
                }
            }
            .navigationTitle("Server Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
