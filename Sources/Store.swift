import CoreLocation
import Foundation

struct Place: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var lat: Double
    var lon: Double

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

    init(name: String, _ c: CLLocationCoordinate2D) {
        self.name = name
        lat = c.latitude
        lon = c.longitude
    }

    // Explicit decoding: a field added later must not wipe saved data.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
    }
}

enum Travel: String, Codable, CaseIterable, Identifiable {
    case walking, cycling, driving
    var id: String { rawValue }
    var label: String { ["walking": "Walk", "cycling": "Cycle", "driving": "Drive"][rawValue]! }
    /// Metres per second along the route.
    var speed: Double {
        switch self {
        case .walking: 1.4
        case .cycling: 5.0
        case .driving: 13.0
        }
    }
}

struct RouteSpec: Codable, Equatable {
    var start: Place
    var end: Place
    var waypoints: [Place]
    var travel: Travel
    var stayAtEnd: Bool

    init(start: Place, end: Place, waypoints: [Place], travel: Travel, stayAtEnd: Bool) {
        self.start = start
        self.end = end
        self.waypoints = waypoints
        self.travel = travel
        self.stayAtEnd = stayAtEnd
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        start = try c.decode(Place.self, forKey: .start)
        end = try c.decode(Place.self, forKey: .end)
        waypoints = try c.decodeIfPresent([Place].self, forKey: .waypoints) ?? []
        travel = try c.decodeIfPresent(Travel.self, forKey: .travel) ?? .walking
        stayAtEnd = try c.decodeIfPresent(Bool.self, forKey: .stayAtEnd) ?? true
    }
}

struct Bookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var place: Place?
    var route: RouteSpec?

    init(name: String, place: Place? = nil, route: RouteSpec? = nil) {
        self.name = name
        self.place = place
        self.route = route
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Bookmark"
        place = try c.decodeIfPresent(Place.self, forKey: .place)
        route = try c.decodeIfPresent(RouteSpec.self, forKey: .route)
    }
}

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var place: Place?
    var route: RouteSpec?

    init(date: Date = .now, place: Place? = nil, route: RouteSpec? = nil) {
        self.date = date
        self.place = place
        self.route = route
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? .distantPast
        place = try c.decodeIfPresent(Place.self, forKey: .place)
        route = try c.decodeIfPresent(RouteSpec.self, forKey: .route)
    }
}

/// Bookmarks and history, kept in Application Support/Elsewhere/library.json.
struct Library: Codable {
    var bookmarks: [Bookmark] = []
    var history: [HistoryEntry] = []
    var routeHistory: [HistoryEntry] = []
    var lastPin: Place?

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        history = try c.decodeIfPresent([HistoryEntry].self, forKey: .history) ?? []
        routeHistory = try c.decodeIfPresent([HistoryEntry].self, forKey: .routeHistory) ?? []
        lastPin = try c.decodeIfPresent(Place.self, forKey: .lastPin)
    }
}

enum Store {
    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Elsewhere", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var file: URL { supportDir.appendingPathComponent("library.json") }

    static func load() -> Library {
        guard let data = try? Data(contentsOf: file) else { return Library() }
        do {
            return try JSONDecoder().decode(Library.self, from: data)
        } catch {
            // Keep the unreadable file rather than overwriting it on the next save.
            let backup = supportDir.appendingPathComponent("library.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: file, to: backup)
            return Library()
        }
    }

    static func save(_ lib: Library) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(lib) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
