import Foundation

enum HelperError: Error, CustomStringConvertible {
    case launchFailed(String)
    case closedUnexpectedly
    case helperError(String)

    var description: String {
        switch self {
        case .launchFailed(let message): return "Could not launch helper: \(message)"
        case .closedUnexpectedly: return "Helper process closed its output unexpectedly."
        case .helperError(let message): return message
        }
    }
}

/// Talks to the bundled .NET MppHelper over stdin/stdout, one JSON object per line.
final class HelperProcess {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private var nextId = 1

    init(executableURL: URL) throws {
        process.executableURL = executableURL
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        // Dev-time only: a framework-dependent apphost needs DOTNET_ROOT to find a
        // user-local SDK install. The shipped build publishes self-contained and won't need this.
        var environment = ProcessInfo.processInfo.environment
        environment["DOTNET_ROOT"] = NSHomeDirectory() + "/.dotnet"
        process.environment = environment
        do {
            try process.run()
        } catch {
            throw HelperError.launchFailed(error.localizedDescription)
        }
    }

    func open(path: String) throws -> OpenResult {
        let id = nextId
        nextId += 1

        let request = HelperRequest(id: id, command: "open", path: path)
        try send(request)

        let response = try receive()
        guard response.ok, let result = response.result else {
            throw HelperError.helperError(response.error ?? "Unknown helper error.")
        }
        return result
    }

    /// Starts a brand-new, empty project in the Helper (same role as `open`, but nothing read from
    /// disk) — needed before a from-scratch project can be saved, since `save` requires the Helper
    /// to already have a project loaded.
    func new() throws -> OpenResult {
        let id = nextId
        nextId += 1

        let request = HelperRequest(id: id, command: "new", path: nil)
        try send(request)

        let response = try receive()
        guard response.ok, let result = response.result else {
            throw HelperError.helperError(response.error ?? "Unknown helper error.")
        }
        return result
    }

    /// Writes the current task/resource lists to `path` as Project XML (MSPDI) — the Helper mutates
    /// the same live MPXJ project it already has in memory from `open`, so an `open` must precede this.
    func save(path: String, tasks: [TaskDto], resources: [ResourceDto], budgetCost: Double, calendars: [CalendarDto]) throws {
        let id = nextId
        nextId += 1

        let request = HelperRequest(
            id: id, command: "save", path: path, tasks: tasks, resources: resources, budgetCost: budgetCost,
            calendars: calendars)
        try send(request)

        let response = try receive()
        guard response.ok else {
            throw HelperError.helperError(response.error ?? "Unknown helper error.")
        }
    }

    func shutdown() {
        try? send(HelperRequest(id: 0, command: "exit", path: nil))
        process.waitUntilExit()
    }

    private func send(_ request: HelperRequest) throws {
        let data = try JSONEncoder().encode(request)
        let handle = stdin.fileHandleForWriting
        handle.write(data)
        handle.write("\n".data(using: .utf8)!)
    }

    private func receive() throws -> HelperResponse {
        guard let line = readLine(from: stdout.fileHandleForReading) else {
            throw HelperError.closedUnexpectedly
        }
        return try JSONDecoder().decode(HelperResponse.self, from: line)
    }

    /// Reads bytes from `handle` until a newline, since FileHandle has no line-buffered read.
    private func readLine(from handle: FileHandle) -> Data? {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                return buffer.isEmpty ? nil : buffer
            }
            if let newlineIndex = chunk.firstIndex(of: 0x0A) {
                buffer.append(chunk[chunk.startIndex..<newlineIndex])
                return buffer
            }
            buffer.append(chunk)
        }
    }
}
