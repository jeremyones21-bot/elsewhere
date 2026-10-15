import Foundation

/// One attached iPhone, as reported by elsewhere-helper.
struct Device: Decodable, Identifiable, Equatable {
    enum State: String, Decodable {
        case trust, devmode, tunnel, preparing, ready, error
    }
    let udid: String
    let name: String
    let ios: String
    let state: State
    let detail: String?
    var id: String { udid }
}

/// Runs the bundled Go helper and talks to it over stdin/stdout, one JSON object per line.
/// The helper owns the USB/tunnel side; this class only relays commands and device lists.
@MainActor
final class HelperBridge {
    var onDevices: (([Device], String?) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<Void, Error>] = [:]
    private var stopping = false

    struct HelperError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func start() {
        guard process == nil else { return }
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "elsewhere-helper") else {
            onDevices?([], "The helper is missing from the app bundle.")
            return
        }
        let p = Process()
        p.executableURL = url
        p.arguments = [Store.supportDir.path]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            Task { @MainActor in self?.receive(chunk) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.terminated() }
        }
        do {
            try p.run()
        } catch {
            onDevices?([], "Couldn't start the helper: \(error.localizedDescription)")
            return
        }
        process = p
        input = inPipe.fileHandleForWriting
    }

    /// Closing stdin tells the helper to put the phone back and exit.
    func stop() {
        stopping = true
        try? input?.close()
        // The helper gives up on unresponsive phones after 2s; don't wait on it much longer.
        let deadline = Date().addingTimeInterval(3)
        while let p = process, p.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if let p = process, p.isRunning { p.terminate() }
    }

    func setLocation(udid: String, lat: Double, lon: Double) async throws {
        try await send(["cmd": "set", "udid": udid, "lat": lat, "lon": lon])
    }

    func resetLocation(udid: String) async throws {
        try await send(["cmd": "reset", "udid": udid])
    }

    private func send(_ body: [String: Any]) async throws {
        guard let input else { throw HelperError(message: "Helper isn't running.") }
        let id = nextID
        nextID += 1
        var msg = body
        msg["id"] = id
        var line = try JSONSerialization.data(withJSONObject: msg)
        line.append(0x0A)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            waiting[id] = c
            do { try input.write(contentsOf: line) } catch {
                waiting[id] = nil
                c.resume(throwing: error)
            }
        }
    }

    private func receive(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(Data(line))
        }
    }

    private struct Event: Decodable {
        let type: String
        let devices: [Device]?
        let error: String?
        let id: Int?
        let ok: Bool?
    }

    private func handle(_ line: Data) {
        guard let e = try? JSONDecoder().decode(Event.self, from: line) else { return }
        switch e.type {
        case "devices":
            onDevices?(e.devices ?? [], e.error)
        case "result":
            guard let id = e.id, let c = waiting.removeValue(forKey: id) else { return }
            if e.ok == true { c.resume() } else { c.resume(throwing: HelperError(message: e.error ?? "Failed.")) }
        default:
            break
        }
    }

    private func terminated() {
        process = nil
        input = nil
        for c in waiting.values { c.resume(throwing: HelperError(message: "Helper stopped.")) }
        waiting.removeAll()
        guard !stopping else { return }
        onDevices?([], nil)
        // Crashed or killed: bring it back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
    }
}
