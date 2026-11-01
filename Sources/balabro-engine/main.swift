import BalabroEngine
import Foundation

// The headless engine the Windows app runs, joined to it by JSON lines on stdin and stdout.
Platform.ignoreBrokenPipes()
let arguments = Array(CommandLine.arguments.dropFirst())
if let status = await EngineCommand.run(arguments) { exit(status) }
let host = HostLink(input: .standardInput, output: .standardOutput)
let engine = await Engine.start(savesRoot: EngineCommand.savesRoot(arguments), capture: host.screenshot)
await host.serve(engine)
await engine.shutdown()
exit(0)
