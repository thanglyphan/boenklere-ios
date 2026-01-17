import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authManager: AuthenticationManager

    var body: some View {
        MainMapView()
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthenticationManager())
}
