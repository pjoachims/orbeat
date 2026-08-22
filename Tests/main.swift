import Foundation

TestRun.failures = 0
ErgsTests.run()
TrainerModeTests.run()
ZwiftTests.run()
print(TestRun.failures == 0 ? "\nALL PASS" : "\n\(TestRun.failures) FAILURES")
exit(TestRun.failures == 0 ? 0 : 1)
