import SwiftUI
import AuthenticationServices

struct AuthenticationView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    
    var body: some View {
        ZStack {
            Color.white
                .ignoresSafeArea()
            
            VStack(spacing: 40) {
                Spacer()
                
                VStack(spacing: 16) {
                    Text("boenklere")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundColor(.black)
                    
                    Text("Navigate your world")
                        .font(.title3)
                        .foregroundColor(.black.opacity(0.6))
                }
                
                Spacer()
                
                VStack(spacing: 20) {
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        switch result {
                        case .success(let authorization):
                            handleAuthorization(authorization)
                        case .failure(let error):
                            authManager.errorMessage = error.localizedDescription
                        }
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 54)
                    .cornerRadius(12)
                    
                    if let errorMessage = authManager.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.horizontal)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 32)
                
                Spacer()
                    .frame(height: 60)
            }
        }
    }
    
    private func handleAuthorization(_ authorization: ASAuthorization) {
        if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
            let userIdentifier = appleIDCredential.user
            
            UserDefaults.standard.set(userIdentifier, forKey: "userIdentifier")
            
            authManager.userIdentifier = userIdentifier
            
            if let fullName = appleIDCredential.fullName {
                let name = [fullName.givenName, fullName.familyName]
                    .compactMap { $0 }
                    .joined(separator: " ")
                if !name.isEmpty {
                    authManager.userName = name
                    UserDefaults.standard.set(name, forKey: "userName")
                }
            }
            
            if let email = appleIDCredential.email {
                authManager.userEmail = email
                UserDefaults.standard.set(email, forKey: "userEmail")
            }

            authManager.isAuthenticated = true
            authManager.errorMessage = nil

            Task {
                do {
                    let user = try await APIService.shared.upsertUser(
                        userId: userIdentifier,
                        name: authManager.userName
                    )
                    authManager.userAddress = user.address
                    authManager.userLatitude = user.latitude
                    authManager.userLongitude = user.longitude
                    if let enabled = user.messageNotificationsEnabled {
                        authManager.messageNotificationsEnabled = enabled
                    }
                    if let enabled = user.listingNotificationsEnabled {
                        authManager.listingNotificationsEnabled = enabled
                    }
                    if let radius = user.listingNotificationRadiusKm {
                        authManager.listingNotificationRadiusKm = radius
                    }
                    if let address = user.address {
                        UserDefaults.standard.set(address, forKey: "userAddress")
                    }
                    if let latitude = user.latitude {
                        UserDefaults.standard.set(latitude, forKey: "userLatitude")
                    }
                    if let longitude = user.longitude {
                        UserDefaults.standard.set(longitude, forKey: "userLongitude")
                    }
                    if let enabled = user.messageNotificationsEnabled {
                        UserDefaults.standard.set(enabled, forKey: "messageNotificationsEnabled")
                    }
                    if let enabled = user.listingNotificationsEnabled {
                        UserDefaults.standard.set(enabled, forKey: "listingNotificationsEnabled")
                    }
                    if let radius = user.listingNotificationRadiusKm {
                        UserDefaults.standard.set(radius, forKey: "listingNotificationRadiusKm")
                    }
                    await authManager.syncDeviceTokenIfNeeded()
                } catch {
                    print("Failed to upsert user: \(error)")
                }
            }
        }
    }
}

#Preview {
    AuthenticationView()
        .environmentObject(AuthenticationManager())
}
