// The process helper behind installing a fix: it must not deadlock on a chatty
// tool, must never wait on a prompt, and must stop a tool that never finishes.
import Foundation
import Testing
@testable import OnlineFixApp

@Suite
struct ShellTests {

    @Test
    func capturesOutput() {
        let result = Shell.run("/bin/echo", ["hello"])
        #expect(result.code == 0)
        #expect(result.out.contains("hello"))
        #expect(!result.timedOut)
    }

    /// A tool that fills stderr while still writing stdout used to leave the
    /// reader blocked on the wrong pipe, and the install screen sat on
    /// "Extracting…" forever.
    @Test
    func drainsBothPipes() {
        let script = #"yes "a line of noise" | head -c 500000 1>&2; echo done"#
        let result = Shell.run("/bin/sh", ["-c", script], timeout: 30)
        #expect(!result.timedOut)
        #expect(result.code == 0)
        #expect(result.out.contains("done"))
        #expect(result.err.count > 100_000)
    }

    @Test
    func stopsAToolThatNeverEnds() {
        let started = Date()
        let result = Shell.run("/bin/sleep", ["5"], timeout: 0.5)
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(started) < 4)
    }

    /// With stdin inherited, a tool that asks something would wait for an answer
    /// that never comes.
    @Test
    func neverWaitsOnInput() {
        let result = Shell.run("/bin/cat", [], timeout: 5)
        #expect(!result.timedOut)
        #expect(result.code == 1 || result.code == 0)
    }

    @Test
    func reportsOutputLines() async {
        final class Lines: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String] = []
            func add(_ line: String) {
                lock.lock(); values.append(line); lock.unlock()
            }
            func snapshot() -> [String] {
                lock.lock(); defer { lock.unlock() }; return values
            }
        }

        let lines = Lines()
        let result = await Shell.runAsync("/bin/sh", ["-c", #"printf "one\ntwo\n""#],
                                          timeout: 10) { lines.add($0) }
        #expect(result.code == 0)
        #expect(lines.snapshot().contains("one"))
        #expect(lines.snapshot().contains("two"))
    }
}
