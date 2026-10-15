import MapKit
import Observation

/// Address autocomplete backed by MapKit, biased toward whatever region the map shows.
@MainActor
@Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    var query = "" {
        didSet {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                results = []
            } else {
                completer.queryFragment = query
            }
        }
    }
    var results: [MKLocalSearchCompletion] = []

    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func bias(to region: MKCoordinateRegion?) {
        if let region { completer.region = region }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let r = completer.results
        MainActor.assumeIsolated { results = Array(r.prefix(8)) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { results = [] }
    }

    /// Turns a suggestion (or raw text) into a coordinate.
    func resolve(_ completion: MKLocalSearchCompletion?) async -> Place? {
        let req: MKLocalSearch.Request
        if let completion {
            req = MKLocalSearch.Request(completion: completion)
        } else {
            req = MKLocalSearch.Request()
            req.naturalLanguageQuery = query
        }
        guard let item = try? await MKLocalSearch(request: req).start().mapItems.first else { return nil }
        let name = completion?.title ?? item.name ?? query
        return Place(name: name, item.placemark.coordinate)
    }
}
