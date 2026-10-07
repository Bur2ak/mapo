import SwiftUI

/// Üçüncü taraf lisansları (App/Resources/ThirdPartyNotices.txt, scripts/gen-notices.py).
struct NoticesView: View {
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .frame(minWidth: 560, minHeight: 480)
        .task {
            if let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
               let s = try? String(contentsOf: url, encoding: .utf8) {
                text = s
            }
        }
    }
}
