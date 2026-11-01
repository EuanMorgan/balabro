# Balabro on Windows: one Swift engine, a Mac face and a Windows face

## Problem

Balabro is a Mac app. The owner wants the same coaching on their Windows PC: the panel over the game, follow-up questions on a global shortcut, screenshots, the scorer's private copy of the game, and "play for me". The Mac app has to keep working as it does now.

Three things stand in the way:

- **The core doesn't build off Apple platforms.** `Fingerprint` uses CryptoKit, and `SaveFile` inflates with `NSData.decompressed`, which only Apple's Foundation has. Fingerprints are stored in run records, so the SHA-256 hex must not change.
- **Half the shell is portable and half isn't.** The runtimes, the claude process, the scorer and the bot copy are Foundation plus a few POSIX calls. The panel, the shortcut, screen capture, the menu bar item and the updater are AppKit, SwiftUI, Carbon and ScreenCaptureKit, which Windows doesn't have.
- **The game is packaged differently.** On Windows, `Balatro.exe` is LÖVE's `love.exe` with the game's zip appended, so there is no `Balatro.love` to unzip and no `.app` to copy.

## What was measured on the owner's PC

Windows 11 x64, Steam Balatro at `C:\Program Files (x86)\Steam\steamapps\common\Balatro`, saves in `%APPDATA%\Balatro\<profile>\save.jkr`, Claude Code as a real `%USERPROFILE%\.local\bin\claude.exe`, `CLAUDE_CONFIG_DIR` set in the user's environment.

- `Balatro.exe` is LÖVE 11.5 with the zip appended. The zip starts 394,752 bytes in. Its 304 entries are deflate or stored.
- The first 394,752 bytes, saved as `love.exe` beside the game's DLLs, run a plain folder (`love.exe <folder>`). It isn't fused, so it saves under `%APPDATA%\LOVE\<folder name>`.
- Stdin and stdout pipes reach Lua. But `io.stdout:setvbuf("line")` acts as full buffering on Windows, so nothing arrives until the process exits. A flush after each write fixes it. Lines arrive ending in CRLF.
- The copy's window appears and takes the foreground when it starts.

## Usage

The owner on Windows:

1. Download `Balabro-<version>-windows-x64.zip` from the Actions run or a release, unzip it anywhere, and open `Balabro.exe`. SmartScreen asks once: **More info**, then **Run anyway**.
2. In Balatro, set the display to **Borderless**. No window can show over exclusive fullscreen.
3. The panel appears at the top right, and a spade icon appears in the tray. Play as usual. Press **Ctrl+Alt+Space** to ask a question, and **Escape** to go back to the game.
4. If something is wrong, run the engine from a terminal in the Balabro folder: `.\balabro-engine.exe --locate-claude`, `--print-prompt <save>`, `--print-exact-scores <save>`, `--play-for-me win`. Each part fails on its own, before any UI is involved.

The Mac app, after the change:

```swift
let engine = await Engine.start(savesRoot: savesRoot, capture: GameWindow.capturePNG)
let overlay = OverlayPanel(runtime: engine.coach, pilot: engine.pilot, updater: updater)
```

The Windows engine (`Sources/balabro-engine/main.swift`):

```swift
if let status = await EngineCommand.run(arguments) { exit(status) }
let host = HostLink(input: .standardInput, output: .standardOutput)
let engine = await Engine.start(savesRoot: savesRoot, capture: host.screenshot)
await host.serve(engine)   // returns when the Windows app closes stdin
```

## Shape

**Targets.**

| Target | Builds on | Holds |
|---|---|---|
| `BalabroCore` | everywhere | Today's core without CryptoKit or `NSData`, plus `Inflate`, `SHA256` and `ZipArchive`. |
| `BalabroEngine` | everywhere | The portable shell, moved out of `Balabro`: `CoachRuntime`, `PilotRuntime`, `ClaudeProcess`, `ClaudeLocator`, `Command`, `Scorer`, `BotProcess`, `BotInstall`, `RunStore`, `GameInstall`, `SaveWatcher`, the CLI modes. New: `Engine`, `HostLink` and its wire types, `LineReader`, `Log`, and `Platform`, the one file where the two systems differ. |
| `balabro-engine` | everywhere | The headless executable the Windows app runs. |
| `Balabro` | macOS only | The Mac face: panel, SwiftUI views, Carbon shortcut, ScreenCaptureKit, menu bar item, updater, stats window. `Package.swift` declares it only on macOS. |
| `windows/Balabro.Windows` | Windows | A WPF app in C#: the panel, the tray icon, the shortcut, window capture. It holds no coaching rules. |

**One way to read the game.** `Inflate.raw` is the only DEFLATE decoder. `SaveFile` uses it for saves, and `ZipArchive` uses it for entries. `ZipArchive` finds the end record and works out how many bytes come before the zip, so the same code reads `Balatro.love` (0 bytes) and `Balatro.exe` (394,752 bytes). It replaces `/usr/bin/unzip` on the Mac too, so the Mac runs the Windows code path every day. `SHA256.hex` replaces CryptoKit and gives the same hex, so stored fingerprints still match.

**The bot copy is the Mac recipe with one platform step.** `BotInstall.prepare` extracts the game with `ZipArchive`, appends `require "bot/main"` to `main.lua` and copies the bot's Lua, as today. Then `Platform` makes the runtime. On the Mac it copies `Balatro.app` and deletes `Balatro.love`. On Windows it copies the game's DLLs and writes the bytes before the zip as `love.exe`. The bot's Lua flushes after every line it writes, and `LineReader` drops a trailing `\r`. Both are harmless on the Mac.

**`Platform` is the only place the two systems differ.** It is one file with a `#if os(Windows)` branch and a macOS branch. It covers the data folder, the saves folder, finding the game, the claude candidates and their environment, a hard kill, and making the bot runtime. Nowhere else in the engine has `#if os`. Windows finds `claude.exe` in `%USERPROFILE%\.local\bin`, then on `Path`. A program started from Explorer already has the user's `Path` and `CLAUDE_CONFIG_DIR`, so there is no login shell to ask, and claude gets the whole inherited environment. npm's `claude.cmd` isn't supported in v1, because it can't be started without `cmd.exe` re-quoting the multi-line system prompt.

**One way each for streams, watching and logs.** `LineReader` is `BotProcess`'s `availableData` loop, shared by the claude and bot processes, because `FileHandle.bytes` is Apple-only. `SaveWatcher` polls the three `save.jkr` files every 250 ms and compares their bytes. That replaces FSEvents and its special cases. The game writes at most every 5 s, so a quarter of a second more is invisible. `Log` writes to `os.Logger` on the Mac and to `logs\engine.log` in the data folder on Windows, a file the owner can send. Settings stay in `UserDefaults`, which Foundation also has on Windows.

**The Windows app is two processes joined by JSON lines on stdin and stdout.** WPF starts `balabro-engine.exe` without a console window, inside a job object that kills the engine, claude and the bot copies when the app exits, even after a crash. Closing stdin also tells the engine to exit, the rule the bot already follows.

- The engine sends `coach` and `pilot` lines, each carrying the whole current `CoachView` or `PilotView` as JSON, and a `capture` line when a turn needs a screenshot.
- The app sends one line per player action. The actions are named after the runtime methods `OverlayView` calls today (`ask`, `retry`, `refresh`, `adviseNextRun`, `setGoal`, `playForMe`, `stopPilot`, `dismissPilot`), plus `screenshot` with the PNG in base64.
- The views are encoded with `Codable`, so a field added to a view reaches the wire with no extra edit. The text the panel shows for a problem or a score line moves out of `OverlayView` into the core, next to the types it describes. The Mac panel and the wire then use the same words.

**Why WPF.** The owner's PC can build and run it, and agents there can take screenshots of it. WPF's topmost, no-activate windows, `RegisterHotKey`, the tray icon and `PrintWindow` are well documented. Avalonia would run on the Mac too, but with a real Windows machine available that matters less than WPF's simpler Win32 handling. An HTML panel in WebView2 would add a third language for no gain.

**The rest of the Windows face.**

- **Panel.** A borderless, topmost window with `WS_EX_NOACTIVATE` and `WS_EX_TOOLWINDOW`, dragged by its title. To type a question it takes focus, and on Escape or submit it gives focus back to Balatro.
- **Shortcut.** Ctrl+Alt+Space with `RegisterHotKey`.
- **Screenshot.** `PrintWindow` with `PW_RENDERFULLCONTENT` on the largest window titled "Balatro", scaled so the long edge is at most 1568 px, as on the Mac.
- **Tray icon.** Show overlay, Move overlay to the corner, Open logs folder, Quit.
- **Font.** The game's pixel font, from the engine's extracted copy.

**Left out of the Windows v1.** Self-update (replacing a running exe needs a helper, so the README says to download the new zip). The stats window. The drawn waiting animations. Code signing. Exclusive fullscreen.

## Order of work

1. **The core builds everywhere.** `Inflate`, `SHA256` and `ZipArchive` in the core, used on the Mac in place of CryptoKit, `NSData` and `unzip`. Gate the Mac target. Add CI for the Mac and Windows. *Check:* `swift test` on the Mac and on the Windows PC, and on the Mac `--print-exact-scores` on a fixture save still prints scores.
2. **The engine.** `BalabroEngine`, `Platform`, polling, `LineReader`, `Log`, the CLI modes, `balabro-engine` and `HostLink`, and the bot's flush. *Check:* the Mac app coaches a driver run as before. On the PC, `balabro-engine.exe` finds claude, prints the prompt for the real save, prints exact scores (which builds the bot copy), and plays a run with `--play-for-me`.
3. **The Windows app.** WPF, packaging script, CI artifact and the README's Windows section. *Check:* on the PC with real Balatro, the panel shows advice, the shortcut asks a question, a pack gets its card names, and "play for me" runs.

## Synthesis decision

Four runners sketched this: Opus, Fable, Sonnet and Haiku. Sonnet was told to keep Windows all Swift, and Haiku was told to use a separate engine with a UI in another language. The others chose freely. Three of the four ended on the same shape: a Swift engine shared by both platforms, with a thin Windows face.

The base is Opus's: one `Engine`, a headless `balabro-engine`, one pure implementation each of SHA-256, DEFLATE and zip used on both platforms, the bot runtime cut from the fused exe, and the job object and hidden console for child processes.

Grafted from the others:

- From Fable, sending the existing `CoachView` and `PilotView` as JSON, so the wire is derived and never synced by hand. Also from Fable, the CLI modes in the engine, so each Windows part can be tested from a terminal before any UI exists. And `Platform` as the single place where the systems differ.
- From Haiku, WPF over Avalonia, now that a real Windows PC can run and screenshot the app.
- From the PC measurements, the bot flushing after every write and the reader dropping `\r`.

Rejected:

- Opus's `PanelFrame`, which would move every view rule into the core and redraw the Mac panel from it. It is a large change to a working Mac view. Moving only the problem and score text into the core gets the shared words without it.
- Sonnet's all-Swift Win32 panel drawn with GDI. It means writing layout, wrapping and hit testing by hand, and it is the most code that only Windows can check.
- Fable's HTML panel in WebView2. It adds a third language.
- Haiku's swift-crypto dependency. Eighty lines of SHA-256 tested against the FIPS vectors are cheaper than a package.
- Support for npm's `claude.cmd`. The owner's PC has `claude.exe`. It can come later if someone needs it.

## Tradeoffs accepted

- We accept C# in the repo in exchange for a Windows UI built on a mature toolkit, with no coaching rules in it.
- We accept about 400 lines of byte-level code (`Inflate`, `SHA256`, `ZipArchive`) in exchange for no dependency and one way to read the game on both platforms.
- We accept polling every 250 ms on the Mac in exchange for one watcher with no platform code.
- We accept a two-process Windows app in exchange for Swift keeping its own main thread, and the engine being testable from a terminal.
- We accept a Windows v1 without self-update, stats or animations in exchange for getting coaching onto the PC sooner.

## Open questions and risks

- Does the real game's `main.lua` start under the cut `love.exe`, given its Steam calls? The probe ran a test folder, not the game. Step 2's `--print-exact-scores` answers it.
- Does SDL honour `SDL_WINDOW_NO_ACTIVATION_WHEN_SHOWN`, so the bot copy's window doesn't take focus from Balatro? If not, the scorer's start steals focus once per session.
- Does Foundation's `Process` on Windows pass `--tools ""` and the multi-line system prompt intact? Step 2's claude turn on the PC answers it.
