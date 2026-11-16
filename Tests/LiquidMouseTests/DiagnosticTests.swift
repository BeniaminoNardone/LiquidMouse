import Testing
@testable import LiquidMouse

struct DiagnosticTests {
    @Test(arguments: [Double.nan, .infinity, -1, 0, 61])
    func selfTestRejectsInvalidDurations(seconds: Double) {
        #expect(!SelfTest.run(seconds: seconds))
    }

    @Test(arguments: [Double.nan, .infinity, -1, 0, 2, 61])
    func benchmarkRejectsInvalidDurations(seconds: Double) {
        #expect(!PerformanceProbe.run(seconds: seconds))
    }
}
