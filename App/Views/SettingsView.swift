import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Form {
                LabeledContent("Sürüm", value: Bundle.main.shortVersion)
            }
            .formStyle(.grouped)
            .tabItem { Label("Genel", systemImage: "gearshape") }
        }
        .frame(width: 460, height: 260)
    }
}

extension Bundle {
    var shortVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
