# Working on Balabro

Balabro runs on the Mac and on Windows. Every feature a player can see or use works on both apps, in the same change.

## Where code goes

- `Sources/BalabroCore` holds the coaching logic and every string the player sees, next to the types it describes. `Sources/BalabroEngine` holds what both apps run: the runtimes, the processes, the update check, the stats page.
- The Mac app (`Sources/Balabro`) and the Windows app (`windows/Balabro.Windows`) only draw and click. When a view needs a new word, number or rule, add it to the core or the engine, and have both apps read it from there. `ViewJSON.swift`, `StatsPage` and `PilotView.title` show the pattern.
- `Sources/BalabroEngine/Platform.swift` is the only place where the two systems differ.

## The wire

The Windows app runs `balabro-engine` and talks to it in JSON lines, written in `Sources/BalabroEngine/HostLink.swift` and read in `windows/Balabro.Windows/Wire.cs`. A feature that needs a new line gets:

1. A golden file in `Tests/BalabroEngineTests/Fixtures/wire/`, built from the real fixtures in `Tests/BalabroCoreTests/Fixtures` where it can be.
2. A Swift test in `Tests/BalabroEngineTests/WireTests.swift` that writes the line and compares it with the file.
3. A C# record and a test in `windows/Balabro.Windows.Tests/WireTests.cs` that decodes the file. That suite fails until every golden file has a test.

## Check both apps

- Run `swift test` and `dotnet test windows/Balabro.Windows.sln`. On a Mac, the C# tests can't run, so check they compile with `dotnet build windows/Balabro.Windows.sln -p:EnableWindowsTargeting=true`, and say that they still need a Windows run.
- The panel's states for visual checks are in `PreviewState.all` (`Sources/BalabroEngine/PreviewState.swift`). Add a state when a feature changes what the panel shows. Render them on both and compare the images side by side. On the Mac, run `swift run Balabro --render-previews <folder>`. On Windows, run `Balabro.exe --render-previews <folder>` from a built zip's folder, which reads `balabro-engine --print-preview-views`.

## Build and run

- **Mac.** `swift run Balabro --saves-root <folder>` runs from source against a saves folder. `scripts/make-app.sh <version>` builds `dist/Balabro.app` and its zip.
- **Windows.** `scripts/make-windows.ps1 <version>` builds `dist/Balabro-<version>-windows-x64.zip`. Run it from a shell where `swift` works, which on Windows means the Swift toolchain plus Visual Studio's C++ build tools, set up by the toolchain's environment script. It also needs the .NET 8 SDK.

[`design/RATIONALE.md`](design/RATIONALE.md) explains the core, and [`design/WINDOWS.md`](design/WINDOWS.md) explains the split between the engine and the two apps.
