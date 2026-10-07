import MapoCore
import SwiftUI

/// "GitHub'dan Ekle": connect, then pick a repository to map.
struct GitHubSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            switch model.github.state {
            case .signedOut:
                ConnectView()
            case .signingIn(let code):
                DeviceCodeView(code: code)
            case .signedIn:
                RepositoryPicker { dismiss() }
            }
        }
        .frame(width: 560, height: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Kapat") {
                    if case .signingIn = model.github.state { model.github.cancelSignIn() }
                    dismiss()
                }
            }
        }
    }
}

private struct ConnectView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.accent)
            VStack(spacing: 6) {
                Text("GitHub hesabını bağla")
                    .font(.title2.weight(.semibold))
                Text("Repoların listelenir, seçtiğin bu Mac'e indirilir ve haritası çıkarılır. Kodun hiçbir yere gönderilmez; şifren Mapo'a girilmez.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            if let error = model.github.signInError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Palette.error)
            }
            Button("GitHub ile Bağlan") { model.github.signIn() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.accent)
            Spacer()
            Text("Mapo yalnız repoları okumak ve indirmek için izin ister.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 32)
    }
}

private struct DeviceCodeView: View {
    @Environment(AppModel.self) private var model
    let code: GitHub.DeviceCode
    @State private var copied = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("GitHub'da bu kodu gir")
                .font(.title3.weight(.semibold))
            Text(code.userCode)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .tracking(4)
                .textSelection(.enabled)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            Button {
                model.github.openVerificationPage(code)
                copied = true
            } label: {
                Label(copied ? "Kod kopyalandı · GitHub açıldı" : "Kodu Kopyala ve GitHub'ı Aç", systemImage: copied ? "checkmark" : "arrow.up.right.square")
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.accent)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Onayın bekleniyor…")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            Spacer()
            Text(code.verificationURL.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .padding(.bottom, 16)
        }
    }
}

private struct RepositoryPicker: View {
    @Environment(AppModel.self) private var model
    let onAdded: () -> Void
    @State private var query = ""
    @State private var selection: GitHub.Repository.ID?

    private var filtered: [GitHub.Repository] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = model.github.repositories.filter { !$0.isArchived }
        guard !q.isEmpty else { return list }
        return list.filter { $0.fullName.lowercased().contains(q) || ($0.description?.lowercased().contains(q) ?? false) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Repo ara", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                if model.github.isLoadingRepositories {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(14)
            Divider()

            if let error = model.github.repositoriesError {
                VStack(spacing: 10) {
                    Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Tekrar Dene") { Task { await model.github.loadRepositories() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty && !model.github.isLoadingRepositories {
                Text(query.isEmpty ? "Hiç repo bulunamadı" : "Eşleşen repo yok")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered, selection: $selection) { repo in
                    RepositoryRow(repo: repo, progress: model.cloning[repo.id], added: isAdded(repo))
                        .tag(repo.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { add(repo) }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                if let login = model.github.user?.login {
                    Text("@\(login)").foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
                Button(addTitle) {
                    if let repo = selectedRepo { add(repo) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedRepo == nil || !model.cloning.isEmpty)
            }
            .padding(14)
        }
        .task { if model.github.repositories.isEmpty { await model.github.loadRepositories() } }
    }

    private var selectedRepo: GitHub.Repository? {
        model.github.repositories.first { $0.id == selection }
    }

    private var addTitle: LocalizedStringKey {
        if let repo = selectedRepo, isAdded(repo) { return "Projeye Git" }
        return "İndir ve Haritasını Çıkar"
    }

    private func isAdded(_ repo: GitHub.Repository) -> Bool {
        model.projects.contains {
            if case .github(let o, let r) = $0.source { return o == repo.owner && r == repo.name }
            return false
        }
    }

    private func add(_ repo: GitHub.Repository) {
        Task {
            await model.addFromGitHub(repo)
            onAdded()
        }
    }
}

private struct RepositoryRow: View {
    let repo: GitHub.Repository
    let progress: String?
    let added: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(repo.owner).foregroundStyle(.secondary)
                    + Text(" / ").foregroundStyle(.tertiary)
                    + Text(repo.name).fontWeight(.medium)
                    if repo.isFork {
                        Text("fork").font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }
                .lineLimit(1)
                if let d = repo.description, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let progress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(progress).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            } else if added {
                Label("Ekli", systemImage: "checkmark").font(.caption).foregroundStyle(Palette.fresh)
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    if let lang = repo.language { Text(lang).font(.caption).foregroundStyle(.secondary) }
                    if let pushed = repo.pushedAt {
                        Text(pushed, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
