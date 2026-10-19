import Darwin
import Foundation

/// Tiny append-only log at ~/Library/Logs/ac-menubar.log for diagnosing network issues.
enum Log {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    private static let queue = DispatchQueue(label: "ac-menubar.log")
    private static let url = directory.appendingPathComponent("ac-menubar.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Blocks until every line written so far is on disk.
    static func flush() {
        queue.sync {}
    }
}

/// Defense in depth against runaway bugs. Every 5 s, on its own queue (so a spinning main thread can't
/// stall it), it checks two limits; past either it logs, takes a stack sample and quits:
/// - memory: the physical footprint is over 1 GB (a SwiftUI update loop once reached 19.5 GB in two
///   minutes);
/// - CPU: the process has stayed over 90% of one core for 60 s, a spin that doesn't grow memory.
/// The sample, a second of call stacks from `/usr/bin/sample`, goes to
/// ~/Library/Logs/ac-menubar-sample.txt and shows where the app was stuck.
enum Watchdog {
    static let interval: TimeInterval = 5
    /// Lets macOS batch the wake-ups with other timers.
    static let leeway: DispatchTimeInterval = .seconds(2)
    static let memoryLimit: UInt64 = 1 << 30
    /// Share of one core; a multithreaded spin can exceed 1.
    static let cpuLimit = 0.9
    static let cpuWindow: TimeInterval = 60
    static let sampleDuration = 1
    /// How long to wait for `sample` before quitting anyway.
    static let sampleTimeout: TimeInterval = 3
    static let sampleURL = Log.directory.appendingPathComponent("ac-menubar-sample.txt")

    /// State for the checks, only touched on the timer's queue.
    private final class Checks: @unchecked Sendable {
        var cpu = CPUSpinDetector(limit: Watchdog.cpuLimit, window: Watchdog.cpuWindow)
    }

    private static let timer: DispatchSourceTimer = {
        let checks = Checks()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ac-menubar.watchdog", qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        timer.setEventHandler {
            if let footprint = physicalFootprint(), footprint > memoryLimit {
                quit("memory footprint \(footprint >> 20) MB is over \(memoryLimit >> 20) MB")
            }
            if let cpu = cpuTime(), let share = checks.cpu.record(cpu: cpu, at: uptime()) {
                quit("CPU at \(Int((share * 100).rounded()))% of a core for \(Int(cpuWindow)) s")
            }
        }
        timer.resume()
        return timer
    }()

    /// Safe to call more than once.
    static func start() {
        _ = timer
    }

    private static func quit(_ reason: String) -> Never {
        Log.write("watchdog: \(reason), quitting")
        let started = Date()
        if sampleSelf() {
            Log.write(String(format: "watchdog: sample written to %@ in %.1f s", sampleURL.path, Date().timeIntervalSince(started)))
        }
        Log.flush()
        exit(1)
    }

    /// Runs `sample` on this process and waits up to `sampleTimeout` for it. `-mayDie` makes it read
    /// symbols first, so the report survives the exit if it takes longer than that.
    static func sampleSelf() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(getpid()), String(sampleDuration), "-mayDie", "-file", sampleURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            Log.write("watchdog: couldn't run sample: \(error)")
            return false
        }
        guard done.wait(timeout: .now() + sampleTimeout) == .success else {
            Log.write("watchdog: sample still running after \(Int(sampleTimeout)) s")
            return false
        }
        if process.terminationStatus != 0 {
            Log.write("watchdog: sample exited with status \(process.terminationStatus)")
            return false
        }
        return true
    }

    /// The figure Activity Monitor shows as "Memory" (task_vm_info.phys_footprint).
    static func physicalFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// User plus system CPU time of all the process's threads, in seconds.
    static func cpuTime() -> TimeInterval? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        func seconds(_ t: timeval) -> TimeInterval { TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Seconds since boot, not counting sleep (CPU time doesn't advance during sleep either).
    static func uptime() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

/// Tells when a process has used more than `limit` of a core for `window` seconds straight, from
/// readings of its total CPU time.
struct CPUSpinDetector {
    let limit: Double
    let window: TimeInterval
    private var previous: (cpu: TimeInterval, time: TimeInterval)?
    private var busySince: (cpu: TimeInterval, time: TimeInterval)?

    init(limit: Double, window: TimeInterval) {
        self.limit = limit
        self.window = window
    }

    /// Takes a reading: total CPU seconds used so far, at `time` seconds on a monotonic clock. Returns
    /// the average share of a core over the busy stretch once every interval in the last `window`
    /// seconds was over the limit; nil otherwise.
    mutating func record(cpu: TimeInterval, at time: TimeInterval) -> Double? {
        defer { previous = (cpu, time) }
        guard let previous, time > previous.time else { return nil }
        guard (cpu - previous.cpu) / (time - previous.time) > limit else {
            busySince = nil
            return nil
        }
        let start = busySince ?? previous
        busySince = start
        guard time - start.time >= window else { return nil }
        return (cpu - start.cpu) / (time - start.time)
    }
}
