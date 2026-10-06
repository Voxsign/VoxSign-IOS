//
//  SettingsView.swift
//  VoxSign
//
//  Doubao-style Settings (T3, UI redesign v3):
//  - Two connection modes: "Cloud · default" (zero-config, Google sign-in only) / "Self-hosted" (empty list by default, add your own server)
//  - Self-hosted add-server paths: IP address (LAN detection + cloud relay toggle + connectivity pre-check before save) /
//    machine code (cloud locates the machine -> same-network direct / cross-network relay -> detected then saved)
//  - Connection state: live probe of the active endpoint (green/yellow/gray) + re-probe now
//  - Voice: speak-reply toggle + rate; background: offline-queue flush
//

import SwiftUI
#if canImport(Speech)
import Speech
#endif

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: SettingsStore
    #if canImport(Speech)
    @EnvironmentObject var speech: SpeechRecognizer
    #endif
    /// T2 connectivity: live state + last error (no black-box troubleshooting on the Settings page).
    @ObservedObject var conn = ConnectivityService.shared
    /// T3 TTS settings.
    @ObservedObject var tts = VoiceOutputService.shared
    @Environment(\.dismiss) private var dismiss

    // P1 cloud: Google sign-in state.
    @State private var googleBusy = false
    @State private var googleError = ""
    @State private var showGoogleAlert = false

    // Add-server sheet (method picker -> IP / machine code).
    @State private var showAdd = false
    @State private var addStep: AddStep = .method
    // IP address form
    @State private var ipName = ""
    @State private var ipBase = ""
    @State private var ipToken = ""
    @State private var ipViaRelay = false
    @State private var ipBusy = false
    @State private var ipError = ""
    // Machine-code form
    @State private var mcCode = ""
    @State private var mcBusy = false
    @State private var mcInfo: MachineInfo?
    @State private var mcRelay = false
    @State private var mcError = ""

    private enum AddStep { case method, ip, machine }

    /// Machine-code paste cleanup: extract a XXXX-XXXX-XXXX code from pasted text (case-insensitive, uppercased), drop the rest.
    private static func extractedMachineCode(from text: String) -> String? {
        let pattern = #"\b[A-Za-z0-9]{4}-[A-Za-z0-9]{4}-[A-Za-z0-9]{4}\b"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range]).uppercased()
    }

    var body: some View {
        NavigationStack {
            Form {
                // -- Connection mode: cloud (default) / self-hosted --
                Section {
                    Picker("Connection mode", selection: $settings.mode) {
                        Text("Cloud · default").tag(ConnectionMode.cloud)
                        Text("Self-hosted").tag(ConnectionMode.selfHosted)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.mode) { _ in
                        conn.probe()
                    }
                }

                if settings.mode == .cloud {
                    cloudSection
                } else {
                    selfHostedSection
                }

                // -- Connection state --
                Section("Connection state") {
                    HStack {
                        Circle().fill(conn.state == .online ? Color.green : (conn.state == .reconnecting ? Color.yellow : Color.gray))
                            .frame(width: 8, height: 8)
                        Text(conn.state == .online ? "Connected" : (conn.state == .reconnecting ? "Reconnecting…" : "Offline"))
                        Spacer()
                        // UI v3: small latency text (Doubao-style 12.5pt gray, e.g. "Latency 42ms").
                        if conn.state == .online && conn.latencyMs > 0 {
                            Text("Latency \(conn.latencyMs)ms")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                    Button("Re-probe now") { conn.probe() }
                    if !conn.lastError.isEmpty {
                        Text(conn.lastError).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }

                // -- Voice (Doubao-style TTS) --
                Section("Speech") {
                    Toggle("Speak replies (TTS)", isOn: $tts.enabled)
                    HStack {
                        Text("Rate").font(.system(size: 13))
                        Slider(value: $tts.rate, in: 0.4...0.6, step: 0.05)
                        Text(String(format: "%.2f", tts.rate)).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Button("Play sample") { tts.speak("Hello, I am your VoxSign voice assistant.") }
                }

                // -- Background capability --
                #if canImport(Speech)
                Section("Background") {
                    Button("Flush offline queue") {
                        Task { _ = await model.flushQueue() }
                    }
                    Text("Offline queue: \(DeliveryQueue.shared.count) pending · notifications authorized=\(NotificationService.shared.authorized ? "Yes" : "No")")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                #endif

                Section {
                    Text("Cloud: the default mode, sign in with Google and go. Self-hosted: add your own Harness server (IP address or machine code).").font(.system(size: 11)).foregroundColor(.secondary)
                }

                // Version (incremented each release, so users can confirm they are on the latest build).
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersionLabel())
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                Button("Done") { dismiss() }
            }
            .sheet(isPresented: $showAdd) { addServerSheet }
            .alert("Google sign-in failed", isPresented: $showGoogleAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(googleError.isEmpty ? "Unknown error" : googleError)
            }
        }
    }

    // MARK: - Cloud view (zero-config, Google sign-in only)

    private var cloudSection: some View {
        Section {
            if let auth = settings.googleAuth {
                LabeledContent("Account") { Text(auth.email).font(.system(size: 13)) }
                LabeledContent("Plan") { Text(tierLabel(auth.tier)).font(.system(size: 13)) }
                if let u = auth.quotaUsed, let l = auth.quotaLimit {
                    LabeledContent("Today's quota") { Text("\(u) / \(l)").font(.system(size: 13)) }
                }
                if let t = auth.trialUntil, !t.isEmpty {
                    LabeledContent("Trial") { Text("until \(t)").font(.system(size: 13)) }
                }
                HStack {
                    Button("Refresh session") { refreshMe() }
                    Button("Sign out", role: .destructive) { settings.logoutGoogle() }
                }
                if !googleError.isEmpty {
                    Text(googleError).font(.system(size: 11)).foregroundColor(.red)
                }
            } else {
                Button {
                    loginGoogle()
                } label: {
                    if googleBusy {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        // UI v3: official four-color Google G (drawn in code) + sign-in text (Doubao-style centered white button).
                        HStack(spacing: 8) {
                            GoogleLogo()
                            Text("Sign in with Google")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.black.opacity(0.85))
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.white)
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.black.opacity(0.1), lineWidth: 0.5)
                        )
                    }
                }
                .disabled(googleBusy)
                if !googleError.isEmpty {
                    Text(googleError).font(.system(size: 11)).foregroundColor(.red)
                }
                Text("Cloud mode is zero-config: one-tap Google sign-in, auto-connected to the VoxSign cloud.").font(.system(size: 11)).foregroundColor(.secondary)
            }
        } header: {
            Text("Cloud")
        } footer: {
            Text("No server address or token needed")
        }
    }

    // MARK: - Self-hosted view (empty list by default + add)

    private var selfHostedSection: some View {
        Group {
            Section("Servers (self-hosted)") {
                if settings.servers.isEmpty {
                    VStack(spacing: 6) {
                        Text("No self-hosted servers yet")
                            .font(.system(size: 14, weight: .medium))
                            .padding(.top, 6)
                        Text("Add one to connect · supports IP address or machine code")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 6)
                } else {
                    ForEach(settings.servers) { srv in
                        ServerRowView(srv: srv, settings: settings, conn: conn)
                    }
                }
                Button {
                    openAddSheet()
                } label: {
                    Label("Add server", systemImage: "plus.circle")
                }
            }

            if let active = settings.servers.first(where: { $0.id == settings.activeServerID }) {
                Section("Current: \(active.name)") {
                    TextField("Name", text: Binding(
                        get: { active.name },
                        set: { v in
                            guard let i = settings.servers.firstIndex(where: { $0.id == settings.activeServerID }) else { return }
                            settings.servers[i].name = v
                        }))
                    TextField("URL http://…", text: Binding(
                        get: { active.base },
                        set: { v in
                            guard let i = settings.servers.firstIndex(where: { $0.id == settings.activeServerID }) else { return }
                            settings.servers[i].base = v
                        }))
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Bearer Token", text: Binding(
                        get: { active.token },
                        set: { v in
                            guard let i = settings.servers.firstIndex(where: { $0.id == settings.activeServerID }) else { return }
                            settings.servers[i].token = v
                        }))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if active.isMachineBound || active.usesRelay {
                        Text([active.isMachineBound ? "Machine-code bound" : nil,
                              active.usesRelay ? "Cloud relay" : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundColor(.blue)
                    }
                    HStack {
                        Button("Test connection") { model.testConnection() }
                        Button("Re-probe now") { conn.probe() }
                    }
                    if !model.statusLine.isEmpty {
                        Text(model.statusLine).font(.system(size: 12))
                    }
                }
            }
        }
    }

    // MARK: - Add-server sheet (method picker -> IP / machine code)

    private var addServerSheet: some View {
        NavigationStack {
            Group {
                switch addStep {
                case .method:
                    Form {
                        Section("Choose a method") {
                            Button {
                                addStep = .ip
                                ipName = ""; ipBase = ""; ipToken = ""; ipViaRelay = false; ipError = ""
                            } label: {
                                HStack {
                                    Label("IP address", systemImage: "network")
                                    Spacer()
                                    Text("Enter IP + port + token").font(.caption).foregroundColor(.secondary)
                                }
                            }
                            Button {
                                addStep = .machine
                                mcCode = ""; mcInfo = nil; mcRelay = false; mcError = ""
                            } label: {
                                HStack {
                                    Label("Machine code", systemImage: "number")
                                    Spacer()
                                    Text("Machine code from install; auto-located").font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                        Section {
                            Text("Self-hosted starts with an empty list; no servers are preconfigured.").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                case .ip:
                    ipAddForm
                case .machine:
                    machineAddForm
                }
            }
            .navigationTitle(addStep == .method ? "Add server" : (addStep == .ip ? "IP address" : "Machine code"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAdd = false; addStep = .method }
                }
                if addStep != .method {
                    ToolbarItem(placement: .navigation) {
                        Button("Back") { addStep = .method }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// IP-address path: LAN detection -> cloud relay toggle -> connectivity pre-check before save.
    private var ipAddForm: some View {
        Form {
            Section("Server") {
                TextField("Name (e.g. Office Mac)", text: $ipName)
                TextField("http://192.168.x.x:8897", text: $ipBase)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Bearer Token (optional)", text: $ipToken)
            }
            if isLanIP(ipBase) {
                Section {
                    Toggle("Access via cloud relay", isOn: $ipViaRelay)
                } footer: {
                    Text("Private address detected: an external phone cannot reach it directly; it will be relayed via the cloud (relay must be enabled on the LAN side).")
                }
            }
            Section {
                Button {
                    saveIP()
                } label: {
                    if ipBusy {
                        HStack {
                            ProgressView().frame(width: 16, height: 16)
                            Text("Checking connection…").frame(maxWidth: .infinity)
                        }
                    } else {
                        Text("Save and check connection").frame(maxWidth: .infinity)
                    }
                }
                .disabled(ipBusy || ipBase.isEmpty)
                if !ipError.isEmpty {
                    Text(ipError).font(.system(size: 11)).foregroundColor(.red)
                }
            }
        }
    }

    /// Machine-code path: lookup -> cloud locates -> direct/relay decision -> check then save.
    private var machineAddForm: some View {
        Form {
            Section("Machine code") {
                TextField("AB12-CD34-EF56", text: $mcCode)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .autocapitalization(.allCharacters)
                    // Paste cleanup: extract the machine code (XXXX-XXXX-XXXX) from pasted text, drop the rest, uppercase.
                    .onChange(of: mcCode) { newValue in
                        if let code = Self.extractedMachineCode(from: newValue), code != newValue {
                            mcCode = code
                        }
                    }
                Text("Enter the machine code generated at Harness install; the cloud locates this machine automatically.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            if let info = mcInfo {
                Section {
                    LabeledContent("Machine") { Text(info.name).font(.system(size: 13)) }
                    LabeledContent("Address") { Text(info.base).font(.system(size: 13)) }
                    LabeledContent("Connection") {
                        Text(mcRelay ? "Cloud relay (cross-network)" : "Direct same-network")
                            .font(.system(size: 13))
                            .foregroundColor(mcRelay ? .blue : .green)
                    }
                }
                Section {
                    Button {
                        saveMachine(info)
                    } label: {
                        if mcBusy {
                            HStack {
                                ProgressView().frame(width: 16, height: 16)
                                Text("Checking…").frame(maxWidth: .infinity)
                            }
                        } else {
                            Text("Save").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(mcBusy)
                }
            } else {
                Section {
                    Button {
                        lookupMachine()
                    } label: {
                        if mcBusy {
                            HStack {
                                ProgressView().frame(width: 16, height: 16)
                                Text("Looking up machine code…").frame(maxWidth: .infinity)
                            }
                        } else {
                            Text("Look up and bind").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(mcBusy || mcCode.isEmpty)
                }
            }
            if !mcError.isEmpty {
                Text(mcError).font(.system(size: 11)).foregroundColor(.red)
            }
        }
    }

    // MARK: - Actions

    /// Save IP path: check first (same-network direct; if relay is on, cloud reachability also counts); save only on success.
    private func saveIP() {
        ipBusy = true
        ipError = ""
        Task {
            let directOK = await APIClient.shared.healthCheck(base: ipBase)
            let relayOK = ipViaRelay ? await APIClient.shared.healthCheck(base: settings.cloudBase) : false
            ipBusy = false
            guard directOK || relayOK else {
                ipError = ipViaRelay
                    ? "Cannot connect: both the private address and the cloud relay are unreachable (confirm the server is online and relay is enabled on the LAN side)"
                    : "Cannot connect to this address (confirm the server is online and the address is correct)"
                return
            }
            settings.addServer(name: ipName.isEmpty ? "Server" : ipName,
                               base: ipBase,
                               token: ipToken,
                               viaRelay: ipViaRelay)
            conn.probe()
            showAdd = false
            addStep = .method
        }
    }

    /// Machine-code lookup: cloud locates -> direct probe -> if unreachable, flag as cross-network relay.
    private func lookupMachine() {
        mcBusy = true
        mcError = ""
        mcInfo = nil
        Task {
            do {
                let info = try await APIClient.shared.lookupMachine(code: mcCode)
                let direct = await APIClient.shared.healthCheck(base: info.base)
                mcInfo = info
                mcRelay = !direct
                if !direct {
                    mcError = "Cross-network: will be saved as \"cloud relay\" mode, relayed on demand (disconnects when idle)."
                }
            } catch {
                mcError = error.localizedDescription
            }
            mcBusy = false
        }
    }

    /// Cloud relay URL: https://voxsign.ai/relay/<machine-code> (the cloud routes by machine code to that machine's
    /// reverse connection; ports are per-service not per-machine, and all relay traffic reuses 443).
    private func relayBase(code: String) -> String {
        let cloud = settings.cloudBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(cloud)/relay/\(code)"
    }

    /// Save machine-code path: check (direct or relay channel) and save only on success.
    private func saveMachine(_ info: MachineInfo) {
        mcBusy = true
        mcError = ""
        Task {
            let saveBase = mcRelay ? relayBase(code: mcCode) : info.base
            let ok = await APIClient.shared.healthCheck(base: saveBase)
            mcBusy = false
            guard ok else {
                mcError = "Cannot connect (confirm the machine is online\(mcRelay ? " and the cloud relay is available" : ""))"
                return
            }
            settings.addServer(name: info.name,
                               base: saveBase,
                               token: info.token,
                               machineCode: mcCode,
                               viaRelay: mcRelay)
            conn.probe()
            showAdd = false
            addStep = .method
        }
    }

    /// Start Google authorization (PKCE) -> exchange for a session JWT -> cloud sign-in.
    private func loginGoogle() {
        googleBusy = true
        googleError = ""
        Task {
            defer { googleBusy = false }
            do {
                let (code, verifier) = try await AuthService.shared.authorize(base: settings.base)
                let idToken = try await AuthService.shared.exchangeIDToken(code: code, verifier: verifier)
                let result = try await APIClient.shared.loginGoogleIDToken(idToken)
                settings.setGoogleLogin(result, base: settings.base)
                conn.probe()
            } catch {
                googleError = error.localizedDescription
                showGoogleAlert = true
            }
        }
    }

    /// Refresh the session (GET /v1/me).
    private func refreshMe() {
        googleError = ""
        Task {
            do {
                let me = try await APIClient.shared.me()
                settings.refreshAuth(me)
            } catch {
                googleError = error.localizedDescription
            }
        }
    }

    private func openAddSheet() {
        addStep = .method
        showAdd = true
    }

    private func tierLabel(_ tier: String) -> String {
        switch tier {
        case "free": return "Free (within daily quota)"
        case "prime": return "Prime"
        case "enterprise": return "Enterprise"
        default: return tier
        }
    }

    private func isLanIP(_ s: String) -> Bool {
        s.range(of: #"https?://(192\.168\.|10\.|172\.(1[6-9]|2\d|3[01])\.)"#,
                options: .regularExpression) != nil
    }

    /// Version: Info.plist CFBundleShortVersionString + CFBundleVersion.
    /// The build increments each release; users can confirm they are on the latest build at the bottom of Settings.
    private func appVersionLabel() -> String {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(ver) (build \(build))"
    }
}


// MARK: - Official four-color Google G (UI v3 drawn in code, not an image)

/// Google logo for the Doubao-style sign-in button: four-color ring + white G glyph.
struct GoogleLogo: View {
    var body: some View {
        ZStack {
            // Blue ring base
            Circle().fill(Color(red: 0.259, green: 0.522, blue: 0.957)) // #4285F4
            // Yellow (top-left 90° sector)
            sector(start: .degrees(180), end: .degrees(270))
                .fill(Color(red: 0.988, green: 0.737, blue: 0.031))     // #FBBC05
            // Green (bottom-left 90° sector)
            sector(start: .degrees(90), end: .degrees(180))
                .fill(Color(red: 0.204, green: 0.659, blue: 0.325))     // #34A853
            // Red (bottom-right 90° sector)
            sector(start: .degrees(0), end: .degrees(90))
                .fill(Color(red: 0.918, green: 0.263, blue: 0.208))     // #EA4335
            // White G glyph (semibold, visually aligned to the official G position)
            Text("G")
                .font(.system(size: 17, weight: .heavy))
                .foregroundColor(.white)
                .offset(x: -1, y: 0)
        }
        .frame(width: 20, height: 20)
    }

    private func sector(start: Angle, end: Angle) -> some Shape {
        // Center at (10,10), radius 10, draw a 90° sector (SwiftUI Path angles start at 3 o'clock, clockwise positive).
        Path { p in
            p.move(to: CGPoint(x: 10, y: 10))
            p.addArc(center: CGPoint(x: 10, y: 10),
                     radius: 10,
                     startAngle: start,
                     endAngle: end,
                     clockwise: false)
            p.closeSubpath()
        }
    }
}


// MARK: - Server row (split out of the ForEach to avoid Swift type-check timeouts)

private struct ServerRowView: View {
    let srv: ServerConfig
    @ObservedObject var settings: SettingsStore
    @ObservedObject var conn: ConnectivityService

    var body: some View {
        HStack {
            Image(systemName: srv.id == settings.activeServerID ? "checkmark.circle.fill" : "circle")
                .foregroundColor(srv.id == settings.activeServerID ? .green : .gray)
            VStack(alignment: .leading, spacing: 2) {
                Text(srv.name).font(.system(size: 14, weight: .medium))
                Text(srv.base).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                // UI v3: connection-method chips — machine-code / direct / cloud relay (Doubao-style small tags).
                if srv.isMachineBound || srv.usesRelay {
                    HStack(spacing: 4) {
                        if srv.isMachineBound {
                            chip("Machine code", .blue)
                        }
                        chip(srv.usesRelay ? "Cloud relay" : "Direct same-network", srv.usesRelay ? .blue : .green)
                    }
                }
            }
            Spacer()
            if srv.id == settings.activeServerID {
                Text("Current").font(.system(size: 11)).foregroundColor(.green)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { settings.switchServer(srv.id); conn.probe() }
        .swipeActions {
            // Unbind the machine code: clear machineCode; the server entry stays (used as a normal self-hosted server).
            if srv.isMachineBound {
                Button("Unbind") { settings.unbindMachine(srv.id) }
            }
            Button("Delete", role: .destructive) { settings.removeServer(srv.id) }
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(color.opacity(0.12))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}
