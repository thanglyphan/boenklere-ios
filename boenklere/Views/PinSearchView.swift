import SwiftUI
import MapKit
import CoreLocation

struct PinSearchView: View {
    let onAddressSelected: (AddressSuggestion) -> Void
    @Environment(\.dismiss) var dismiss
    @StateObject private var addressSearch = KartverketAddressSearch()
    @StateObject private var locationManager = PinSearchLocationManager()
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isLoading = false
    @State private var suggestions: [AddressSuggestion] = []
    @State private var hasInitializedPosition = false
    
    var body: some View {
        ZStack {
            // Map
            Map(position: $cameraPosition)
                .onMapCameraChange(frequency: .onEnd) { context in
                    let center = context.camera.centerCoordinate
                    fetchAddresses(latitude: center.latitude, longitude: center.longitude)
                }
                .ignoresSafeArea(edges: .top)
            
            // Fixed pin in center
            VStack {
                Image(systemName: "mappin")
                    .font(.system(size: 40))
                    .foregroundColor(.red)
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 2)
                
                // Pin shadow/dot
                Ellipse()
                    .fill(.black.opacity(0.2))
                    .frame(width: 12, height: 6)
                    .offset(y: -4)
            }
            .offset(y: -20) // Adjust to align pin point with center
            
            // Address list at bottom
            VStack {
                Spacer()
                addressListView
            }
            
            // Close button at top
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(width: 36, height: 36)
                            .background(.regularMaterial, in: Circle())
                    }
                    .padding(.leading, 16)
                    .padding(.top, 60)
                    
                    Spacer()
                }
                Spacer()
            }
        }
        .onAppear {
            locationManager.requestLocation()
        }
        .onChange(of: locationManager.location) { _, newLocation in
            if let location = newLocation, !hasInitializedPosition {
                hasInitializedPosition = true
                cameraPosition = .region(MKCoordinateRegion(
                    center: location.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))
            }
        }
    }
    
    private var addressListView: some View {
        VStack(spacing: 0) {
            // Handle
            Capsule()
                .fill(Color(.systemGray3))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 12)
            
            if isLoading {
                HStack {
                    ProgressView()
                        .padding(.trailing, 8)
                    Text("Henter adresser...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 20)
            } else if suggestions.isEmpty {
                Text("Flytt kartet for å finne adresser")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(suggestions) { suggestion in
                        Button {
                            onAddressSelected(suggestion)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.title2)
                                
                                Text(suggestion.displayText)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                    .multilineTextAlignment(.leading)
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                        }
                        
                        if suggestion != suggestions.last {
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 34)
    }
    
    private func fetchAddresses(latitude: Double, longitude: Double) {
        isLoading = true
        Task {
            let results = await addressSearch.reverseGeocode(latitude: latitude, longitude: longitude)
            await MainActor.run {
                suggestions = results
                isLoading = false
            }
        }
    }
}

// Separate location manager for PinSearchView to avoid conflicts
private class PinSearchLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var location: CLLocation?
    
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }
    
    func requestLocation() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.first {
            self.location = location
            manager.stopUpdatingLocation()
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("PinSearchLocationManager error: \(error.localizedDescription)")
    }
}

#Preview {
    PinSearchView { suggestion in
        print("Selected: \(suggestion.displayText)")
    }
}
