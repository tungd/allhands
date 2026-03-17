import AllHandsKit
import SafariServices
import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var authenticationURL: IdentifiableURL?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailPane
                .background(AllHandsPalette.detailBackground)
        }
        .task {
            await model.bootstrap()
        }
        .onChange(of: model.pendingAuthenticationURL) { _, newValue in
            guard let newValue else {
                authenticationURL = nil
                return
            }
            authenticationURL = IdentifiableURL(url: newValue)
        }
        .sheet(item: $authenticationURL) { item in
            SafariSheet(url: item.url)
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        switch model.onboardingStatus {
        case .connected:
            connectedSidebar
        default:
            onboardingSidebar
        }
    }

    private var onboardingSidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("All Hands")
                .font(.title)
            Text("Tailscale is the default transport. The app discovers over Bonjour on the local network and falls back to Tailnet peer probing.")
                .foregroundStyle(.secondary)
            Text(statusTitle)
                .font(.headline)
            Text(statusSubtitle)
                .foregroundStyle(.secondary)
            onboardingControls

            if showsServerListInOnboarding {
                serverList
            }

            Spacer()
        }
        .padding(20)
    }

    private var onboardingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.onboardingStatus {
            case .signedOut:
                Button("Connect Tailscale") {
                    Task { await model.beginSignIn() }
                }
            case .authInProgress:
                ProgressView()
                Button("I Finished Sign-In") {
                    Task { await model.completeAuthentication() }
                }
            case .discovering:
                ProgressView("Discovering servers…")
            case .noServers:
                Button("Retry Discovery") {
                    Task { await model.retryDiscovery() }
                }
            case .serverSelection:
                Text("Choose a discovered server.")
            case .connected:
                EmptyView()
            case .error:
                Button("Retry Tailscale Setup") {
                    Task { await model.beginSignIn() }
                }
            }
        }
    }

    private var connectedSidebar: some View {
        VStack(spacing: 16) {
            sessionConfigurationPanel
            Divider()
            sessionList
        }
        .padding(20)
    }

    private var sessionConfigurationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.selectedServer?.name ?? "All Hands")
                .font(.title2)
            Text(model.selectedServer?.baseURL.absoluteString ?? "Connecting")
                .foregroundStyle(.secondary)
            Group {
                if let serverInfo = model.serverInfo {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Launch Root")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(serverInfo.launchRootPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    if model.availableAgents.isEmpty {
                        Text("No supported ACP launchers were detected on this server.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Picker("Agent", selection: $model.sessionConfiguration.agent) {
                            ForEach(model.availableAgents) { agent in
                                Text(agent.displayName).tag(agent.id)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                } else {
                    ProgressView("Loading server info…")
                }
            }
            TextField("Folder path", text: $model.sessionConfiguration.folderPath)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Refresh") {
                    Task { await model.refreshSelectedServer() }
                }
                Button("Create Session") {
                    Task { await model.createSession() }
                }
                .disabled(!model.canCreateSession)
            }
        }
    }

    private var serverList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Discovered Servers")
                .font(.headline)
            List(model.discoveredServers) { server in
                Button {
                    Task { await model.selectServer(server) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.name)
                        Text(server.baseURL.absoluteString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(server.source.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
            .frame(minHeight: 160)
        }
    }

    private var showsServerListInOnboarding: Bool {
        switch model.onboardingStatus {
        case .serverSelection:
            return true
        default:
            return !model.discoveredServers.isEmpty
        }
    }

    private var sessionList: some View {
        List(model.sessionStore.sessions, selection: $model.selectedSessionID) { session in
            VStack(alignment: .leading, spacing: 4) {
                Text(session.id)
                    .font(.body.monospaced())
                Text(session.status.uppercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(session.worktreePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 6)
        }
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.selectedSession?.id ?? detailTitle)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(detailSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isBusy {
                    ProgressView()
                }
            }

            if let inlineError = model.inlineError {
                Text(inlineError)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AllHandsPalette.errorBackground, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(AllHandsPalette.errorForeground)
            }

            if case .serverSelection = model.onboardingStatus {
                serverList
            } else if case .connected = model.onboardingStatus {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.events(for: model.selectedSessionID)) { event in
                            EventCard(event: event)
                        }
                    }
                }

                HStack(alignment: .bottom, spacing: 12) {
                    TextField("Steer the agent…", text: $model.promptText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    Button("Send") {
                        Task { await model.sendPrompt() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedSessionID == nil || model.promptText.isEmpty)
                }
            } else {
                Spacer()
            }
        }
        .padding(24)
        .onChange(of: model.selectedSessionID) { _, newValue in
            guard let newValue else { return }
            model.connectStream(for: newValue)
        }
    }

    private var statusTitle: String {
        switch model.onboardingStatus {
        case .signedOut:
            return "Connect Tailnet"
        case .authInProgress:
            return "Finish Browser Sign-In"
        case .discovering:
            return "Finding Servers"
        case .noServers:
            return "No Servers Found"
        case .serverSelection:
            return "Choose Your Host"
        case .connected:
            return "Connected"
        case .error:
            return "Connection Error"
        }
    }

    private var statusSubtitle: String {
        switch model.onboardingStatus {
        case .signedOut:
            return "Start the Tailscale auth flow and persist the node in the background."
        case .authInProgress:
            return "The app opened the Tailscale sign-in flow in your browser. Return here when it completes."
        case .discovering:
            return "Browsing Bonjour on the local network, then probing Tailnet peers for All Hands."
        case .noServers:
            return "Discovery completed, but no All Hands server responded."
        case .serverSelection:
            return "Multiple servers responded. Pick the one you want to attach to."
        case .connected:
            return "Your server is selected and ready."
        case .error(let message):
            return message
        }
    }

    private var detailTitle: String {
        switch model.onboardingStatus {
        case .signedOut:
            return "Sign In To Tailscale"
        case .authInProgress:
            return "Waiting For Authentication"
        case .discovering:
            return "Discovering Server"
        case .noServers:
            return "No Server Found"
        case .serverSelection:
            return "Select A Server"
        case .connected:
            return "Select a Session"
        case .error:
            return "Unable To Connect"
        }
    }

    private var detailSubtitle: String {
        if let server = model.selectedServer {
            return server.baseURL.absoluteString
        }

        switch model.onboardingStatus {
        case .signedOut:
            return "No active Tailscale session"
        case .authInProgress:
            return "Browser auth flow in progress"
        case .discovering:
            return "Bonjour and Tailnet discovery"
        case .noServers:
            return "No discovered hosts"
        case .serverSelection:
            return "Select from discovered hosts"
        case .connected:
            return model.selectedSession?.status ?? "Idle"
        case .error(let message):
            return message
        }
    }
}

private struct IdentifiableURL: Identifiable {
    let url: URL

    var id: String {
        url.absoluteString
    }
}

private struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

private struct EventCard: View {
    let event: StreamEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(event.type)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(tagColor)
                Spacer()
                Text("#\(event.seq)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(payloadDescription(event.payload))
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(AllHandsPalette.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(tagColor.opacity(0.25), lineWidth: 1)
        )
    }

    private var tagColor: Color {
        switch event.type {
        case "acp.error":
            return AllHandsPalette.errorForeground
        case "acp.patch":
            return AllHandsPalette.patchForeground
        case "acp.call":
            return AllHandsPalette.callForeground
        default:
            return AllHandsPalette.defaultForeground
        }
    }

    private func payloadDescription(_ payload: JSONValue) -> String {
        switch payload {
        case .string(let value):
            return value
        case .number(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        case .null:
            return "null"
        case .array(let values):
            return values.map(payloadDescription).joined(separator: "\n")
        case .object(let object):
            return object
                .sorted(by: { $0.key < $1.key })
                .map { key, value in "\(key): \(payloadDescription(value))" }
                .joined(separator: "\n")
        }
    }
}

private enum AllHandsPalette {
    static let detailBackground = Color(.sRGB, red: 0.98, green: 0.97, blue: 0.95, opacity: 1)
    static let cardBackground = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 1)
    static let errorBackground = Color(.sRGB, red: 0.96, green: 0.88, blue: 0.88, opacity: 1)
    static let errorForeground = Color(.sRGB, red: 0.72, green: 0.16, blue: 0.18, opacity: 1)
    static let patchForeground = Color(.sRGB, red: 0.84, green: 0.47, blue: 0.11, opacity: 1)
    static let callForeground = Color(.sRGB, red: 0.19, green: 0.43, blue: 0.90, opacity: 1)
    static let defaultForeground = Color(.sRGB, red: 0.19, green: 0.55, blue: 0.27, opacity: 1)
}
