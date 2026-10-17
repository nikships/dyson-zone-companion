import SwiftUI

@main
struct DysonZoneApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(app: app, headphones: app.headphones, link: app.link)
        } label: {
            Image(systemName: app.headphones.isConnected ? "headphones" : "headphones.circle")
        }
        .menuBarExtraStyle(.window)

        Window("Sign in to Dyson", id: "signin") {
            SignInView(app: app)
        }
        .windowResizability(.contentSize)
    }
}

struct PanelView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var headphones: Headphones
    @ObservedObject var link: ZoneLink
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if headphones.found {
                controls
                if headphones.isConnected { audioBody }
                Button(action: headphones.toggleConnection) {
                    Text(headphones.busy ? "Working…" : headphones.isConnected ? "Disconnect" : "Connect")
                        .frame(maxWidth: .infinity)
                }
                .disabled(headphones.busy)
                .controlSize(.large)
            } else {
                Text("No paired Dyson headphones found. Pair them in System Settings > Bluetooth.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Divider()
            if app.credentials != nil {
                Button("Sign out of Dyson") { app.signOut() }.buttonStyle(.plain)
            }
            Button("Bluetooth Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
            }
            .buttonStyle(.plain)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 290)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "headphones").font(.title2)
            VStack(alignment: .leading, spacing: 1) {
                Text(headphones.name).font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(headphones.isConnected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                    Text(headphones.isConnected ? "Connected" : "Not connected")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if link.state == .ready {
                Picker("Noise control", selection: Binding(
                    get: { link.ancMode },
                    set: { if let mode = $0 { link.setANC(mode) } }
                )) {
                    ForEach([ANCMode.isolation, .conversation, .transparency]) { Text($0.shortLabel).tag(Optional($0)) }
                    if link.ancMode == .off { Text("Off").tag(Optional(ANCMode.off)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if let mode = link.ancMode { row("Mode", mode.label) }
                VStack(alignment: .leading, spacing: 6) {
                    row("Sound", link.eqMode?.label ?? "")
                    Picker("Sound", selection: Binding(
                        get: { link.eqMode },
                        set: { if let mode = $0 { link.setEQ(mode) } }
                    )) {
                        ForEach(EQMode.allCases) { Text($0.label).tag(Optional($0)) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if let percent = link.batteryPercent {
                    row("Battery", "\(percent)%\(chargingText)")
                } else if let battery = link.battery {
                    row("Battery", battery.label)
                }
                airflow
            } else {
                HStack(spacing: 6) {
                    Image(systemName: link.state == .busyElsewhere ? "iphone" : "slider.horizontal.3")
                        .foregroundStyle(.secondary)
                    Text(link.state.summary).font(.callout).foregroundStyle(.secondary)
                }
                if link.state == .needsSignIn {
                    Button("Sign in to Dyson…") {
                        openWindow(id: "signin")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .controlSize(.small)
                }
                if link.state == .busyElsewhere {
                    Text("Turn off Bluetooth on your phone, or close MyDyson, to control from this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var chargingText: String {
        switch link.chargingState {
        case 1, 2: return " (charging)"
        case 3: return " (charged)"
        default: return link.chargerPresent == true ? " (plugged in)" : ""
        }
    }

    @ViewBuilder private var airflow: some View {
        if link.fanSpeed != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Airflow").foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Auto", isOn: Binding(get: { link.fanAuto ?? false }, set: { link.setFanAuto($0) }))
                        .toggleStyle(.switch).controlSize(.small)
                }
                .font(.callout)
                Picker("Airflow", selection: Binding(
                    get: { link.fanAuto == true ? -1 : (link.fanSpeed ?? 0) },
                    set: { if $0 >= 0 { link.setFanSpeed($0) } }
                )) {
                    Text("Off").tag(0)
                    Text("Rest").tag(1)
                    Text("Light").tag(2)
                    Text("Mod").tag(3)
                    if link.fanAuto == true { Text("Auto").tag(-1) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var audioBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            row("Signal", signalText)
            row("Audio", headphones.audioMode.label)
            if headphones.audioMode.isCallMode {
                Text("Headphones are in low-quality call mode because an app is using their mic.")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(headphones.volume) }, set: { headphones.setVolume(Float($0)) }))
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }

            if !headphones.isDefaultOutput {
                Button("Use as Sound Output", action: headphones.useAsOutput).controlSize(.small)
            }

            Toggle("Keep Mac mic as input", isOn: $headphones.keepMacMic)
                .toggleStyle(.switch).controlSize(.small)
                .help("Stops macOS from switching the headphones to low-quality call audio just because they connected.")
        }
    }

    private var signalText: String {
        guard let rssi = headphones.rssi else { return "Unavailable" }
        let quality = rssi > -60 ? "Excellent" : rssi > -75 ? "Good" : "Weak"
        return "\(quality) (\(rssi) dBm)"
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.callout)
    }
}

extension AudioMode {
    var isCallMode: Bool { if case .callMode = self { return true } else { return false } }
}

extension ANCMode {
    var shortLabel: String {
        switch self {
        case .isolation: return "ANC"
        case .conversation: return "Talk"
        case .transparency: return "Aware"
        case .off: return "Off"
        }
    }
}

struct SignInView: View {
    @ObservedObject var app: AppModel
    @StateObject private var model = SignInModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to MyDyson").font(.title2.bold())
            Text("Dyson gives your account a key for the headphones. It is fetched once and kept on this Mac, and your password is never saved.")
                .font(.callout).foregroundStyle(.secondary)

            switch model.step {
            case .email:
                TextField("Email", text: $model.email).textFieldStyle(.roundedBorder)
                Button("Email me a code") { model.sendCode() }
                    .disabled(model.email.isEmpty || model.busy)
                    .keyboardShortcut(.defaultAction)
            case .code:
                Text("Enter the code Dyson emailed to \(model.email) and your MyDyson password.")
                    .font(.callout)
                TextField("Code", text: $model.code).textFieldStyle(.roundedBorder)
                SecureField("Password", text: $model.password).textFieldStyle(.roundedBorder)
                Button("Sign in") { model.verify(app) }
                    .disabled(model.code.isEmpty || model.password.isEmpty || model.busy)
                    .keyboardShortcut(.defaultAction)
            case .choose:
                Text("Which device is your Zone?").font(.callout)
                ForEach(model.candidates.indices, id: \.self) { i in
                    let d = model.candidates[i]
                    Button("\(d.name ?? d.serialNumber ?? "Device")  (\(d.serialNumber ?? ""))") { model.choose(d, app) }
                        .disabled(model.busy)
                }
            case .done:
                Label("Signed in. Controls will appear in the menu bar.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }

            if model.busy { ProgressView().controlSize(.small) }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.red) }
        }
        .padding(22)
        .frame(width: 380)
    }
}
