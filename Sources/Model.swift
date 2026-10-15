import MapKit
import Observation
import SwiftUI

enum Mode: String, CaseIterable, Identifiable {
    case fixed, route
    var id: String { rawValue }
    var label: String { self == .fixed ? "Static" : "Route" }
}

enum RouteSlot: Hashable {
    case start, waypoint, end
}

@MainActor
@Observable
final class AppModel {
    // Devices
    var devices: [Device] = []
    var selectedUDID: String?
    var helperProblem: String?

    // Map
    var camera: MapCameraPosition = .automatic
    var mode: Mode = .fixed
    var pin: CLLocationCoordinate2D?
    var pinName = ""

    /// Where the phone currently thinks it is, if we moved it.
    var simulated: CLLocationCoordinate2D?
    var working = false
    var status: String?

    // Route setup
    var start: Place?
    var end: Place?
    var waypoints: [Place] = []
    var placing: RouteSlot = .start
    var travel: Travel = .walking
    var stayAtEnd = true

    // Route preview + playback
    var routeLine: [CLLocationCoordinate2D] = []
    var routeLength: Double = 0
    var calculating = false
    var playing = false
    var travelled: Double = 0
    private var previewedSpec: RouteSpec?
    private var lastPreview = Date.distantPast
    private var cumulative: [Double] = []
    private var tick: Timer?
    private var inFlight = false

    var library = Store.load()
    let helper = HelperBridge()

    static let maxWaypoints = 10

    init() {
        if let p = library.lastPin {
            pin = p.coordinate
            pinName = p.name
            camera = .region(MKCoordinateRegion(center: p.coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000))
        }
        helper.onDevices = { [weak self] devices, problem in
            self?.updateDevices(devices, problem)
        }
        helper.start()
    }

    // MARK: Devices

    var device: Device? { devices.first { $0.udid == selectedUDID } }
    var deviceReady: Bool { device?.state == .ready }

    private func updateDevices(_ list: [Device], _ problem: String?) {
        devices = list.sorted { $0.name < $1.name }
        helperProblem = problem
        if selectedUDID == nil || !devices.contains(where: { $0.udid == selectedUDID }) {
            selectedUDID = devices.first?.udid
        }
        if device == nil {
            simulated = nil
            if playing { stopPlayback(reset: false) }
        }
    }

    // MARK: Map input

    func tapped(_ c: CLLocationCoordinate2D) {
        place(Place(name: Self.coordinateText(c), c))
    }

    /// Search results and map clicks both land here.
    func place(_ p: Place) {
        switch mode {
        case .fixed:
            pin = p.coordinate
            pinName = p.name
        case .route:
            guard !playing else { return }
            switch placing {
            case .start:
                start = p
                placing = end == nil ? .end : .start
            case .end:
                end = p
            case .waypoint:
                if waypoints.count < Self.maxWaypoints { waypoints.append(p) }
            }
            invalidateRoute()
        }
    }

    func fly(to c: CLLocationCoordinate2D, span: Double = 3000) {
        withAnimation(.easeInOut(duration: 0.6)) {
            camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: span, longitudinalMeters: span))
        }
    }

    func setMode(_ m: Mode) {
        guard !playing, !working else { return }
        mode = m
    }

    // MARK: Static mode

    func changeLocation() async {
        guard let udid = selectedUDID, let pin, deviceReady else { return }
        working = true
        defer { working = false }
        let started = Date()
        do {
            try await helper.setLocation(udid: udid, lat: pin.latitude, lon: pin.longitude)
            simulated = pin
            status = String(format: "Moved in %.1fs", Date().timeIntervalSince(started))
            let place = Place(name: pinName.isEmpty ? Self.coordinateText(pin) : pinName, pin)
            library.lastPin = place
            library.history.insert(HistoryEntry(place: place), at: 0)
            library.history = Array(library.history.prefix(50))
            Store.save(library)
        } catch {
            status = error.localizedDescription
        }
    }

    func resetLocation() async {
        guard let udid = selectedUDID else { return }
        if playing { stopPlayback(reset: false) }
        working = true
        defer { working = false }
        do {
            try await helper.resetLocation(udid: udid)
            simulated = nil
            status = "Back to real location. The phone can take a few minutes to settle; restarting it is instant."
        } catch {
            status = error.localizedDescription
        }
    }

    // MARK: Route mode

    var currentSpec: RouteSpec? {
        guard let start, let end else { return nil }
        return RouteSpec(start: start, end: end, waypoints: waypoints, travel: travel, stayAtEnd: stayAtEnd)
    }

    var routeIsPreviewed: Bool {
        guard let spec = currentSpec, let previewedSpec, !routeLine.isEmpty else { return false }
        // Stay-at-end doesn't change the path.
        return spec.start == previewedSpec.start && spec.end == previewedSpec.end
            && spec.waypoints == previewedSpec.waypoints && spec.travel == previewedSpec.travel
    }

    var previewCooldown: Bool { Date().timeIntervalSince(lastPreview) < 2 }

    func invalidateRoute() {
        guard !playing else { return }
        if !routeIsPreviewed {
            routeLine = []
            routeLength = 0
        }
    }

    func removeWaypoint(_ p: Place) {
        waypoints.removeAll { $0.id == p.id }
        invalidateRoute()
    }

    func clearRoute() {
        guard !playing else { return }
        start = nil
        end = nil
        waypoints = []
        placing = .start
        routeLine = []
        routeLength = 0
        previewedSpec = nil
    }

    func previewRoute() async {
        guard let spec = currentSpec, !calculating else { return }
        calculating = true
        lastPreview = .now
        defer { calculating = false }
        let stops = [spec.start] + spec.waypoints + [spec.end]
        var line: [CLLocationCoordinate2D] = []
        do {
            for (a, b) in zip(stops, stops.dropFirst()) {
                let req = MKDirections.Request()
                req.source = MKMapItem(placemark: MKPlacemark(coordinate: a.coordinate))
                req.destination = MKMapItem(placemark: MKPlacemark(coordinate: b.coordinate))
                // MapKit has no cycling directions on the Mac; bike paths are closest to walking ones.
                req.transportType = spec.travel == .driving ? .automobile : .walking
                let res = try await MKDirections(request: req).calculate()
                guard let r = res.routes.first else { throw RouteError.none }
                var pts = r.polyline.coordinates
                if !line.isEmpty, !pts.isEmpty { pts.removeFirst() }
                line += pts
            }
        } catch {
            status = "Couldn't find a route: \(error.localizedDescription)"
            return
        }
        routeLine = line
        cumulative = Self.cumulativeDistances(line)
        routeLength = cumulative.last ?? 0
        previewedSpec = spec
        travelled = 0
        status = nil
        library.routeHistory.insert(HistoryEntry(route: spec), at: 0)
        library.routeHistory = Array(library.routeHistory.prefix(20))
        Store.save(library)
        fitRoute()
    }

    enum RouteError: LocalizedError {
        case none
        var errorDescription: String? { "MapKit returned no route between those points." }
    }

    func fitRoute() {
        guard !routeLine.isEmpty else { return }
        let rect = MKPolyline(coordinates: routeLine, count: routeLine.count).boundingMapRect
        withAnimation(.easeInOut(duration: 0.6)) {
            camera = .rect(rect.insetBy(dx: -rect.width * 0.15 - 500, dy: -rect.height * 0.15 - 500))
        }
    }

    var playhead: CLLocationCoordinate2D? {
        guard playing || travelled > 0, !routeLine.isEmpty else { return nil }
        return position(at: travelled)
    }

    func startRoute() {
        guard routeIsPreviewed, deviceReady, !playing else { return }
        travelled = 0
        playing = true
        status = nil
        step()
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
    }

    func stopPlayback(reset: Bool) {
        tick?.invalidate()
        tick = nil
        playing = false
        if reset { Task { await resetLocation() } }
    }

    private func step() {
        guard playing, let udid = selectedUDID else { return }
        let c = position(at: travelled)
        let finished = travelled >= routeLength
        travelled = min(routeLength, travelled + travel.speed)
        // Skip a beat rather than queue up stale points if the phone is slow to answer.
        if !inFlight {
            inFlight = true
            Task {
                defer { inFlight = false }
                do {
                    try await helper.setLocation(udid: udid, lat: c.latitude, lon: c.longitude)
                    simulated = c
                } catch {
                    status = error.localizedDescription
                }
            }
        }
        if finished {
            stopPlayback(reset: !stayAtEnd)
            status = stayAtEnd ? "Route finished. Staying at the end." : "Route finished."
        }
    }

    private func position(at d: Double) -> CLLocationCoordinate2D {
        guard routeLine.count > 1, cumulative.count == routeLine.count else { return routeLine.first ?? .init() }
        if d <= 0 { return routeLine[0] }
        if d >= routeLength { return routeLine[routeLine.count - 1] }
        // Binary search for the segment containing d.
        var lo = 0, hi = cumulative.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= d { lo = mid } else { hi = mid }
        }
        let segLen = cumulative[hi] - cumulative[lo]
        let t = segLen > 0 ? (d - cumulative[lo]) / segLen : 0
        let a = routeLine[lo], b = routeLine[hi]
        return .init(latitude: a.latitude + (b.latitude - a.latitude) * t,
                     longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    private static func cumulativeDistances(_ pts: [CLLocationCoordinate2D]) -> [Double] {
        var out = [0.0]
        for (a, b) in zip(pts, pts.dropFirst()) {
            let d = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            out.append(out.last! + d)
        }
        return out
    }

    // MARK: Bookmarks and history

    func addBookmark() {
        switch mode {
        case .fixed:
            guard let pin else { return }
            let name = pinName.isEmpty ? Self.coordinateText(pin) : pinName
            library.bookmarks.insert(Bookmark(name: name, place: Place(name: name, pin)), at: 0)
        case .route:
            guard let spec = currentSpec else { return }
            library.bookmarks.insert(Bookmark(name: "\(spec.start.name) → \(spec.end.name)", route: spec), at: 0)
        }
        Store.save(library)
    }

    func renameBookmark(_ b: Bookmark, to name: String) {
        guard let i = library.bookmarks.firstIndex(of: b), !name.isEmpty else { return }
        library.bookmarks[i].name = name
        Store.save(library)
    }

    func deleteBookmark(_ b: Bookmark) {
        library.bookmarks.removeAll { $0.id == b.id }
        Store.save(library)
    }

    func load(place: Place?, route: RouteSpec?) {
        guard !playing else { return }
        if let place {
            mode = .fixed
            pin = place.coordinate
            pinName = place.name
            fly(to: place.coordinate)
        } else if let route {
            mode = .route
            start = route.start
            end = route.end
            waypoints = route.waypoints
            travel = route.travel
            stayAtEnd = route.stayAtEnd
            placing = .start
            invalidateRoute()
            fly(to: route.start.coordinate, span: 6000)
        }
    }

    func clearHistory() {
        if mode == .fixed { library.history = [] } else { library.routeHistory = [] }
        Store.save(library)
    }

    func deleteHistory(_ e: HistoryEntry) {
        library.history.removeAll { $0.id == e.id }
        library.routeHistory.removeAll { $0.id == e.id }
        Store.save(library)
    }

    static func coordinateText(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", c.latitude, c.longitude)
    }

    static func distanceText(_ m: Double) -> String {
        let f = MKDistanceFormatter()
        f.unitStyle = .abbreviated
        return f.string(fromDistance: m)
    }
}

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var out = [CLLocationCoordinate2D](repeating: .init(), count: pointCount)
        getCoordinates(&out, range: NSRange(location: 0, length: pointCount))
        return out
    }
}
