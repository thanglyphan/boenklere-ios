import Foundation

struct KartverketResponse: Codable {
    let adresser: [KartverketAddress]
}

struct KartverketAddress: Codable {
    let adressetekst: String
    let postnummer: String?
    let poststed: String?
    let kommunenavn: String?
    let representasjonspunkt: KartverketPoint?
}

struct KartverketPoint: Codable {
    let lat: Double
    let lon: Double
}

struct AddressSuggestion: Identifiable, Equatable {
    let id = UUID()
    let displayText: String
    let latitude: Double
    let longitude: Double
    
    static func == (lhs: AddressSuggestion, rhs: AddressSuggestion) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
class KartverketAddressSearch: ObservableObject {
    @Published var results: [AddressSuggestion] = []
    @Published var isSearching = false
    
    private var searchTask: Task<Void, Never>?
    
    func search(query: String) {
        searchTask?.cancel()
        
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            results = []
            return
        }
        
        searchTask = Task {
            isSearching = true
            defer { isSearching = false }
            
            do {
                let suggestions = try await fetchAddresses(query: query)
                if !Task.isCancelled {
                    results = suggestions
                }
            } catch {
                if !Task.isCancelled {
                    print("Kartverket address search error: \(error.localizedDescription)")
                    results = []
                }
            }
        }
    }
    
    private func fetchAddresses(query: String) async throws -> [AddressSuggestion] {
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return []
        }
        
        let urlString = "https://ws.geonorge.no/adresser/v1/sok?sok=\(encodedQuery)&fuzzy=true&treffPerSide=5"
        guard let url = URL(string: urlString) else {
            return []
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(KartverketResponse.self, from: data)
        
        return response.adresser.compactMap { address -> AddressSuggestion? in
            guard let point = address.representasjonspunkt else {
                return nil
            }
            
            var displayText = address.adressetekst
            if let postnummer = address.postnummer, let poststed = address.poststed,
               !postnummer.isEmpty, !poststed.isEmpty {
                displayText += ", \(postnummer) \(poststed)"
            } else if let kommunenavn = address.kommunenavn, !kommunenavn.isEmpty {
                displayText += ", \(kommunenavn)"
            }
            
            return AddressSuggestion(
                displayText: displayText,
                latitude: point.lat,
                longitude: point.lon
            )
        }
    }
    
    func reverseGeocode(latitude: Double, longitude: Double) async -> [AddressSuggestion] {
        let urlString = "https://ws.geonorge.no/adresser/v1/punktsok?lat=\(latitude)&lon=\(longitude)&radius=500&treffPerSide=3"
        guard let url = URL(string: urlString) else {
            return []
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(KartverketResponse.self, from: data)
            
            return response.adresser.compactMap { address -> AddressSuggestion? in
                guard let point = address.representasjonspunkt else {
                    return nil
                }
                
                var displayText = address.adressetekst
                if let postnummer = address.postnummer, let poststed = address.poststed,
                   !postnummer.isEmpty, !poststed.isEmpty {
                    displayText += ", \(postnummer) \(poststed)"
                } else if let kommunenavn = address.kommunenavn, !kommunenavn.isEmpty {
                    displayText += ", \(kommunenavn)"
                }
                
                return AddressSuggestion(
                    displayText: displayText,
                    latitude: point.lat,
                    longitude: point.lon
                )
            }
        } catch {
            print("Kartverket reverse geocode error: \(error.localizedDescription)")
            return []
        }
    }
}
