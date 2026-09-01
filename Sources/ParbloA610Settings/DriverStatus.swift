import Combine
import Foundation

/// State of the driver agent, as launchd reports it. Guessing from the process
/// list would answer a different question.
final class DriverStatus: ObservableObject {
    enum State: Equatable {
        case running
        case stopped(lastExitCode: Int?)
        case notInstalled

        /// `running` is what launchd says about the agent, and nothing more: the
        /// process is alive. Whether the tablet is plugged in and the pen answers
        /// is a different question — the line under the badge answers that one.
        var title: String {
            switch self {
            case .running: return "Driver agent is running"
            case .stopped(let code) where code == 1:
                return "Driver stopped — permissions missing"
            case .stopped: return "Driver stopped"
            case .notInstalled: return "Driver is not installed"
            }
        }

        var isHealthy: Bool { self == .running }
    }

    static let label = "com.rey.parblo-a610-craft-driver"

    @Published private(set) var state: State = .notInstalled

    func refresh() {
        state = Self.query()
    }

    func restart() {
        _ = Self.launchctl(["kickstart", "-k", Self.target])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
    }

    private static var target: String { "gui/\(getuid())/\(label)" }

    private static func query() -> State {
        parse(launchctl(["print", target]))
    }

    /// Parsing is kept apart from running: what the owner sees in the window
    /// depends on it, and running another program cannot be reproduced in a test.
    static func parse(_ output: String?) -> State {
        guard let output else { return .notInstalled }
        if output.contains("Could not find service") { return .notInstalled }
        if output.contains("state = running") { return .running }
        let code =
            output
            .split(separator: "\n")
            .first { $0.contains("last exit code") }
            .flatMap { $0.split(separator: "=").last }
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return .stopped(lastExitCode: code)
    }

    private static func launchctl(_ arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
