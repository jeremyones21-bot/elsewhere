import MapKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var search = PlaceSearch()

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 360)
        } detail: {
            MapPane(search: search)
        }
        .searchable(text: $search.query, placement: .toolbar, prompt: "Search for a place or address")
        .searchSuggestions {
            ForEach(search.results, id: \.self) { r in
                Button {
                    pick(r)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title)
                        if !r.subtitle.isEmpty {
                            Text(r.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .onSubmit(of: .search) { pick(nil) }
    }

    private func pick(_ r: MKLocalSearchCompletion?) {
        Task {
            guard let place = await search.resolve(r) else {
                model.status = "No match for \u{201C}\(search.query)\u{201D}."
                return
            }
            model.place(place)
            model.fly(to: place.coordinate)
            search.query = ""
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: Bookmark?
    @State private var newName = ""

    var body: some View {
        @Bindable var model = model
        List {
            Section("iPhone") {
                DeviceSection()
            }

            Section("Mode") {
                Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                    ForEach(Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.playing || model.working)
            }

            if model.mode == .route {
                RouteSection()
            }

            Section {
                if model.library.bookmarks.isEmpty {
                    Text("Nothing saved yet.").foregroundStyle(.secondary)
                }
                ForEach(model.library.bookmarks) { b in
                    Button {
                        model.load(place: b.place, route: b.route)
                    } label: {
                        Label(b.name, systemImage: b.route == nil ? "mappin" : "point.topleft.down.to.point.bottomright.curvepath")
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Rename…") { newName = b.name; renaming = b }
                        Button("Delete", role: .destructive) { model.deleteBookmark(b) }
                    }
                }
            } header: {
                HStack {
                    Text("Bookmarks")
                    Spacer()
                    Button {
                        model.addBookmark()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help(model.mode == .fixed ? "Bookmark the pin" : "Bookmark this route")
                    .disabled(model.mode == .fixed ? model.pin == nil : model.currentSpec == nil)
                }
            }

            HistorySection()
        }
        .listStyle(.sidebar)
        .alert("Rename Bookmark", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let r = renaming { model.renameBookmark(r, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

struct DeviceSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let problem = model.helperProblem {
            Text(problem).foregroundStyle(.secondary)
        }
        if model.devices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No iPhone connected")
                Text("Plug your iPhone into this Mac with a cable and unlock it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }
        ForEach(model.devices) { d in
            Button {
                model.selectedUDID = d.udid
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(color(d.state))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(d.name).fontWeight(d.udid == model.selectedUDID ? .semibold : .regular)
                            Spacer()
                            if !d.ios.isEmpty {
                                Text("iOS \(d.ios)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        if d.state != .ready, let detail = d.detail, !detail.isEmpty {
                            Text(detail).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if d.state == .preparing || d.state == .tunnel {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func color(_ s: Device.State) -> Color {
        switch s {
        case .ready: .green
        case .error: .red
        case .trust, .devmode: .orange
        case .tunnel, .preparing: .yellow
        }
    }
}

struct RouteSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("Route") {
            Picker("Speed", selection: $model.travel) {
                ForEach(Travel.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(model.playing)
            .onChange(of: model.travel) { model.invalidateRoute() }

            Picker("Clicking the map sets", selection: $model.placing) {
                Text("Start").tag(RouteSlot.start)
                Text("Waypoint").tag(RouteSlot.waypoint)
                Text("End").tag(RouteSlot.end)
            }
            .disabled(model.playing)

            stop("Start", model.start, tint: .green)
            ForEach(Array(model.waypoints.enumerated()), id: \.element.id) { i, w in
                HStack {
                    Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 14)
                    Text(w.name).lineLimit(1)
                    Spacer()
                    Button {
                        model.removeWaypoint(w)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.playing)
                }
            }
            stop("End", model.end, tint: .red)

            Toggle("Stay at end", isOn: $model.stayAtEnd)
                .disabled(model.playing)

            if model.start != nil || model.end != nil {
                Button("Clear Route") { model.clearRoute() }
                    .buttonStyle(.link)
                    .disabled(model.playing)
            }
        }
    }

    private func stop(_ label: String, _ p: Place?, tint: Color) -> some View {
        HStack {
            Circle().fill(tint).frame(width: 8, height: 8).frame(width: 14)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(p?.name ?? "Click the map").lineLimit(1)
                .foregroundStyle(p == nil ? .tertiary : .primary)
        }
    }
}

struct HistorySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let entries = model.mode == .fixed ? model.library.history : model.library.routeHistory
        Section {
            if entries.isEmpty {
                Text("No history yet.").foregroundStyle(.secondary)
            }
            ForEach(entries.prefix(model.mode == .fixed ? 50 : 20)) { e in
                Button {
                    model.load(place: e.place, route: e.route)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(e)).lineLimit(1)
                        Text(e.date, format: .relative(presentation: .named))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Remove", role: .destructive) { model.deleteHistory(e) }
                }
            }
        } header: {
            HStack {
                Text(model.mode == .fixed ? "History" : "Route History")
                Spacer()
                if !entries.isEmpty {
                    Button("Clear") { model.clearHistory() }.buttonStyle(.borderless).font(.caption)
                }
            }
        }
    }

    private func title(_ e: HistoryEntry) -> String {
        if let p = e.place { return p.name }
        if let r = e.route {
            let stops = r.waypoints.isEmpty ? "" : " · \(r.waypoints.count) stop\(r.waypoints.count == 1 ? "" : "s")"
            return "\(r.travel.label): \(r.start.name) → \(r.end.name)\(stops)"
        }
        return "—"
    }
}

// MARK: - Map

struct MapPane: View {
    @Environment(AppModel.self) private var model
    let search: PlaceSearch

    var body: some View {
        @Bindable var model = model
        MapReader { proxy in
            Map(position: $model.camera) {
                if model.mode == .fixed, let pin = model.pin {
                    Marker(model.pinName.isEmpty ? "Pin" : model.pinName, systemImage: "mappin", coordinate: pin)
                        .tint(.red)
                }
                if model.mode == .route {
                    if !model.routeLine.isEmpty {
                        MapPolyline(coordinates: model.routeLine)
                            .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    }
                    if let s = model.start {
                        Marker("Start", coordinate: s.coordinate).tint(.green)
                    }
                    ForEach(Array(model.waypoints.enumerated()), id: \.element.id) { i, w in
                        Marker("\(i + 1)", monogram: Text("\(i + 1)"), coordinate: w.coordinate).tint(.gray)
                    }
                    if let e = model.end {
                        Marker("End", coordinate: e.coordinate).tint(.red)
                    }
                }
                if let here = model.playhead ?? model.simulated {
                    Annotation("iPhone", coordinate: here, anchor: .center) {
                        PhoneDot()
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .mapControls {
                MapZoomStepper()
                MapCompass()
                MapScaleView()
            }
            .onTapGesture(coordinateSpace: .local) { pt in
                if let c = proxy.convert(pt, from: .local) { model.tapped(c) }
            }
            .onMapCameraChange(frequency: .onEnd) { ctx in
                search.bias(to: ctx.region)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ActionBar()
        }
        .navigationTitle(model.device?.name ?? "Elsewhere")
    }
}

/// The phone's simulated position: a plain blue dot with a white rim, like Maps.
struct PhoneDot: View {
    var body: some View {
        Circle()
            .fill(Color.blue)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
    }
}

struct ActionBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                info
                Spacer(minLength: 12)
                buttons
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    @ViewBuilder private var info: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch model.mode {
            case .fixed:
                if let pin = model.pin {
                    Text(model.pinName.isEmpty ? "Dropped pin" : model.pinName).lineLimit(1)
                    Text(AppModel.coordinateText(pin))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit().textSelection(.enabled)
                } else {
                    Text("Click the map or search to drop a pin.").foregroundStyle(.secondary)
                }
            case .route:
                if model.routeLength > 0 {
                    let left = max(0, model.routeLength - model.travelled)
                    Text(model.playing
                         ? "\(AppModel.distanceText(model.travelled)) of \(AppModel.distanceText(model.routeLength))"
                         : "\(AppModel.distanceText(model.routeLength)) by \(model.travel.label.lowercased())")
                        .monospacedDigit()
                    Text("\(duration(left / model.travel.speed)) \(model.playing ? "left" : "at \(speedText)")")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else if model.currentSpec == nil {
                    Text("Set a start and an end on the map.").foregroundStyle(.secondary)
                } else {
                    Text("Preview the route to see it on the map.").foregroundStyle(.secondary)
                }
            }
            if let s = model.status {
                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        let ready = model.deviceReady
        switch model.mode {
        case .fixed:
            Button("Reset Location") { Task { await model.resetLocation() } }
                .disabled(!ready || model.working)
            Button {
                Task { await model.changeLocation() }
            } label: {
                if model.working { ProgressView().controlSize(.small).frame(width: 110) }
                else { Text("Change Location").frame(minWidth: 110) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!ready || model.pin == nil || model.working)
        case .route:
            if model.playing {
                Button("Reset Location") { model.stopPlayback(reset: true) }
                Button("Stop Route") { model.stopPlayback(reset: false) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button {
                    Task { await model.previewRoute() }
                } label: {
                    if model.calculating { ProgressView().controlSize(.small).frame(width: 90) }
                    else { Text("Preview Route").frame(minWidth: 90) }
                }
                .disabled(model.currentSpec == nil || model.calculating || model.previewCooldown)
                Button("Start Route") { model.startRoute() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!ready || !model.routeIsPreviewed)
            }
        }
    }

    private var speedText: String {
        let f = MeasurementFormatter()
        f.unitOptions = .naturalScale
        f.numberFormatter.maximumFractionDigits = 0
        let mps = Measurement(value: model.travel.speed, unit: UnitSpeed.metersPerSecond)
        let local = Locale.current.measurementSystem == .us ? mps.converted(to: .milesPerHour) : mps.converted(to: .kilometersPerHour)
        return f.string(from: local)
    }

    private func duration(_ s: Double) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = s >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: s) ?? ""
    }
}
