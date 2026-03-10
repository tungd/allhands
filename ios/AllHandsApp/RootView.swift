import AllHandsKit
import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 16) {
                configurationPanel
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
        } detail: {
            detailPane
                .background(Color(red: 0.98, green: 0.97, blue: 0.95))
        }
        .task {
            await model.loadSessions()
        }
    }

    private var configurationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("All Hands")
                .font(.system(size: 28, weight: .black, design: .rounded))
            Text("ACP host + iOS client")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            TextField("Server URL", text: Binding(
                get: { model.configuration.baseURL.absoluteString },
                set: { model.configuration.baseURL = URL(string: $0) ?? model.configuration.baseURL }
            ))
            .textFieldStyle(.roundedBorder)
            TextField("Repo path", text: $model.configuration.repoPath)
                .textFieldStyle(.roundedBorder)
            TextField("Agent command", text: $model.configuration.agentCommand)
                .textFieldStyle(.roundedBorder)
            TextField("Agent args (space separated)", text: Binding(
                get: { model.configuration.agentArgs.joined(separator: " ") },
                set: { model.configuration.agentArgs = $0.split(separator: " ").map(String.init) }
            ))
            .textFieldStyle(.roundedBorder)
            Toggle("Use embedded Tailnet transport", isOn: $model.configuration.useTailnet)
            if model.configuration.useTailnet {
                SecureField("Tailscale auth key", text: $model.tailnetAuthKey)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("Refresh") {
                    Task { await model.loadSessions() }
                }
                .buttonStyle(.bordered)
                Button("Create Session") {
                    Task { await model.createSession() }
                }
                .buttonStyle(.borderedProminent)
            }
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
                    Text(model.selectedSession?.id ?? "Select a Session")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(model.selectedSession?.status ?? "Idle")
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
        }
        .padding(24)
        .onChange(of: model.selectedSessionID) { _, newValue in
            guard let newValue else { return }
            model.connectStream(for: newValue)
        }
    }
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
