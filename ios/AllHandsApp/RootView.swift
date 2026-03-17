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
                .background(Color(red: 0.98, green: 0.97, blue: 0.95))
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
                .font(.system(size: 30, weight: .black, design: .rounded))
            Text("Tailscale is the default transport. Sign in, discover your server, and attach automatically.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            RoundedRectangle(cornerRadius: 24)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.11, green: 0.18, blue: 0.28), Color(red: 0.18, green: 0.42, blue: 0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(alignment: .leading) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(statusTitle)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(statusSubtitle)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                        onboardingControls
                    }
                    .padding(20)
                }
                .frame(maxWidth: .infinity, minHeight: 280)

            if !model.discoveredServers.isEmpty {
                serverList
            }

            Spacer()
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color(red: 0.95, green: 0.92, blue: 0.86), Color(red: 0.88, green: 0.91, blue: 0.95)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var onboardingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.onboardingStatus {
            case .signedOut:
                Button("Connect Tailscale") {
                    Task { await model.beginSignIn() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
            case .authInProgress:
                ProgressView()
                    .tint(.white)
                Button("I Finished Sign-In") {
                    Task { await model.completeAuthentication() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
            case .discovering:
                ProgressView("Discovering servers…")
                    .tint(.white)
                    .foregroundStyle(.white)
            case .serverSelection:
                Text("Choose a discovered server.")
                    .foregroundStyle(.white)
            case .connected:
                EmptyView()
            case .error:
                Button("Retry Tailscale Setup") {
                    Task { await model.beginSignIn() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
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
        .background(
            LinearGradient(
                colors: [Color(red: 0.95, green: 0.92, blue: 0.86), Color(red: 0.88, green: 0.91, blue: 0.95)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var sessionConfigurationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.selectedServer?.name ?? "All Hands")
                .font(.system(size: 28, weight: .black, design: .rounded))
            Text(model.selectedServer?.baseURL.absoluteString ?? "Connecting")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            TextField("Repo path", text: $model.sessionConfiguration.repoPath)
                .textFieldStyle(.roundedBorder)
            TextField("Agent command", text: $model.sessionConfiguration.agentCommand)
                .textFieldStyle(.roundedBorder)
            TextField("Agent args (space separated)", text: Binding(
                get: { model.sessionConfiguration.agentArgs.joined(separator: " ") },
                set: { model.sessionConfiguration.agentArgs = $0.split(separator: " ").map(String.init) }
            ))
            .textFieldStyle(.roundedBorder)
            HStack {
                Button("Refresh") {
                    Task { await model.loadSessions() }
                }
                .buttonStyle(.bordered)
                Button("Create Session") {
                    Task { await model.createSession() }
                }
                .buttonStyle(.borderedProminent)
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
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text(server.baseURL.absoluteString)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(server.source.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 160)
            .scrollContentBackground(.hidden)
        }
    }

    private var sessionList: some View {
        List(model.sessionStore.sessions, selection: $model.selectedSessionID) { session in
            VStack(alignment: .leading, spacing: 4) {
                Text(session.id)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                Text(session.status.uppercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(session.worktreePath)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 6)
        }
        .scrollContentBackground(.hidden)
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
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(Color.red)
            }

            if case .connected = model.onboardingStatus {
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
            return "Browsing Bonjour first, then checking the tailnet hostname fallback."
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
            return "Bonjour and MagicDNS discovery"
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
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(tagColor.opacity(0.25), lineWidth: 1)
        )
    }

    private var tagColor: Color {
        switch event.type {
        case "acp.error":
            return .red
        case "acp.patch":
            return .orange
        case "acp.call":
            return .blue
        default:
            return .green
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
