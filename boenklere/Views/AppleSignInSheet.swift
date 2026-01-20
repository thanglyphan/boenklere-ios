import SwiftUI
import AuthenticationServices

struct AppleSignInSheet: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @Environment(\.dismiss) private var dismiss
    var message: String?

    @State private var acceptedTerms = false
    @State private var acceptedPrivacy = false
    @State private var selectedDocument: TermsDocument?
    @State private var contentHeight: CGFloat = 0

    private var canSignIn: Bool {
        acceptedTerms && acceptedPrivacy
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Logg inn i Boenklere for å få tilgang til alle funksjoner")
                .font(.headline)
                .multilineTextAlignment(.leading)

            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }

            termsToggleRow(
                isOn: $acceptedTerms,
                prefix: "Jeg aksepterer",
                linkText: "bruksvilkår",
                suffix: "til boenklere",
                document: .termsOfUse
            )

            termsToggleRow(
                isOn: $acceptedPrivacy,
                prefix: "Jeg aksepterer",
                linkText: "personvern",
                suffix: "til boenklere",
                document: .privacy
            )

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                switch result {
                case .success(let authorization):
                    Task { @MainActor in
                        authManager.handleAuthorization(authorization)
                        dismiss()
                    }
                case .failure(let error):
                    Task { @MainActor in
                        authManager.handleAuthorizationError(error)
                    }
                }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(!canSignIn)
            .allowsHitTesting(canSignIn)
            .opacity(canSignIn ? 1 : 0.5)

            if let errorMessage = authManager.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(24)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
            }
        )
        .frame(maxWidth: .infinity)
        .onPreferenceChange(ContentHeightKey.self) { height in
            if abs(height - contentHeight) > 1 {
                contentHeight = height
            }
        }
        .presentationDetents(contentHeight > 0 ? [.height(contentHeight + 24)] : [.medium])
        .sheet(item: $selectedDocument) { document in
            TermsModal(document: document)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private func termsToggleRow(
        isOn: Binding<Bool>,
        prefix: String,
        linkText: String,
        suffix: String,
        document: TermsDocument
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                isOn.wrappedValue.toggle()
            } label: {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(isOn.wrappedValue ? .blue : .secondary)
                    .alignmentGuide(.firstTextBaseline) { dimension in
                        dimension[VerticalAlignment.center]
                    }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(prefix)
                        .font(.subheadline)
                        .foregroundColor(.primary)

                    Button {
                        selectedDocument = document
                    } label: {
                        Text(linkText)
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)

                    Text(suffix)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
