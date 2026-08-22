import Foundation

/// Minimal shared test harness — no XCTest dependency, runs via test.sh.
func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    if cond {
        print("PASS  \(name)")
    } else {
        TestRun.failures += 1
        print("FAIL  \(name)  \(detail)")
    }
    fflush(stdout)   // survive crashes: see how far we got
}

enum TestRun {
    static var failures = 0
}
