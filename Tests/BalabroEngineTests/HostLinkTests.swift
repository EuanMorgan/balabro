import BalabroEngine
import Foundation
import Testing

@MainActor
@Suite
struct HostLinkTests {
    /// A Balatro whose window hangs `PrintWindow` never lets the app answer, and the coach mustn't wait for it.
    @Test func screenshotTheAppNeverSendsIsNil() async throws {
        let toEngine = Pipe(), fromEngine = Pipe()
        let host = HostLink(input: toEngine.fileHandleForReading, output: fromEngine.fileHandleForWriting, captureLimit: .milliseconds(200))
        var sent = LineReader.lines(from: fromEngine.fileHandleForReading).makeAsyncIterator()
        let listening = Task { await host.listen { _ in } }
        // Without a limit, closing stdin is what ends the wait, so the elapsed time shows which one did.
        let hangUp = Task {
            try? await Task.sleep(for: .seconds(3))
            try? toEngine.fileHandleForWriting.close()
        }
        defer { hangUp.cancel() }

        let started = ContinuousClock.now
        #expect(await host.screenshot() == nil)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(await sent.next() == #"{"id":0,"type":"capture"}"#)

        try toEngine.fileHandleForWriting.write(contentsOf: Data(#"{"type":"screenshot","id":0,"png":"AAAA"}"#.utf8 + [0x0A]))
        async let next = host.screenshot()
        #expect(await sent.next() == #"{"id":1,"type":"capture"}"#)
        try toEngine.fileHandleForWriting.write(contentsOf: Data(#"{"type":"screenshot","id":1,"png":"iVBO"}"#.utf8 + [0x0A]))
        #expect(await next == Data([0x89, 0x50, 0x4E]))

        try toEngine.fileHandleForWriting.close()
        await listening.value
    }
}
