# Balabro on two computers: a sync folder, and Claude told the run so far

## Problem

The owner plays one Steam account on a Mac and a Windows PC and switches between them. Steam Cloud carries the game's saves and all-time profile, so a run started on one computer carries on on the other. Balabro's own data doesn't follow it:

- **Run records** (`runs/*.json`): each run's transcript, the stats summary and `head`, the Claude session after the last completed turn.
- **The bot's results** (`pilot/results.json`).
- **The goal** (win or naneinf), kept in `UserDefaults`.

`head` can't follow the run anyway. A Claude Code session lives in `~/.claude/projects/<cwd>/` on the computer that made it, and `--resume` looks only there.

## Usage

The owner, once on each computer: click **Sync with another computer…** in the Mac menu bar or the Windows tray, and pick a folder a sync service keeps the same on both. On this Mac that's iCloud Drive. On Windows, iCloud for Windows puts it at `%USERPROFILE%\iCloudDrive`. OneDrive and Dropbox work the same way. Balabro uses `<folder>/Balabro/`.

Both apps call the same engine function:

```swift
let machine = try await engine.machine.syncing(with: folder)   // nil stops syncing
```

The Windows app reaches it with one line, and restarts the engine when the answer comes back:

```json
{"type":"setSyncFolder","path":"C:\\Users\\player\\iCloudDrive"}
{"type":"syncFolderSet","path":"C:\\Users\\player\\iCloudDrive","error":null}
```

## Shape

**What's shared and what isn't.** `runs/`, `pilot/results.json` and `settings.json` are shared. Everything else stays in the data folder: the game and bot caches, Claude's conversations folders, logs, the saved claude location, the window position, and `machine.json`. `machine.json` holds a random ID for this computer and the chosen folder:

```json
{"machine":"7946D992-6DFF-4421-880A-491D98ECB47F","syncFolder":"/Users/owner/Library/Mobile Documents/com~apple~CloudDocs"}
```

With no folder chosen, the shared files stay in the data folder, as before.

**`SharedFiles` is the one place the shared files are read and written.** `RunStore`, `PilotResults` and `Settings` all go through it, so the iCloud rule below lives in one spot.

**Switching merges, and never deletes.** Choosing a folder copies each run the folder lacks. For a run in both, it keeps the copy with more progress, by the same `ProgressClock` comparison the coach uses to spot a replay. On a tie it keeps the newer file. It joins the bot's results without repeats, and keeps the folder's `settings.json` if it has one. Stopping copies the folder's runs back the same way, and the folder's goal with them. The data folder's copies stay, so stopping never loses history. A copied run keeps its file date, which the stats show as when it was last played.

**A switch restarts the engine.** The Mac app shuts the engine down, switches, and builds a new `Engine` and panel. The Windows engine shuts its coach and bot down, switches, and answers, and the app starts a new `balabro-engine.exe`. Either way nothing from the old place is left running to write there.

**Claude's memory follows the run as text.** A run record now says which computer made its `head` (`headMachine`). Records from before have none and count as this computer's. When a turn would fork from a `head` made elsewhere, `Coach` starts a new conversation instead. Its first message is the run so far, from the record's transcript, then the usual prompt. After that turn, `head` and `headMachine` are this computer's. A new conversation gets the current system prompt, so it isn't told the rules changed. `Coach` stays pure: the engine passes it the ID from `machine.json`.

The run so far is the newest exchanges that fit in 12,000 characters. A long run's transcript is about 60,000 characters across 130 exchanges, measured on the owner's runs, and an exchange is about 450. So 12,000 is about the last two antes, which holds the current plan and the questions about it, at about 3,000 tokens on one turn.

**iCloud on the Mac.** iCloud Drive drops the contents of files it thinks are unused. On macOS 27, measured with `brctl evict`, the file keeps its name and reads fetch it again, blocking on the network. `Platform.download` asks for every not-downloaded file at once with `startDownloadingUbiquitousItem(at:)` and waits up to 10 s. A file still missing after that is neither read nor written until the next launch, so a run started here without its history can't replace the other computer's copy. Windows cloud folders fetch a file when it's opened, so there `download` returns at once.

**Two computers open at once.** Both may write the same run file. The last writer wins, written atomically as before. The README says to open Balabro on one computer at a time.

## Tradeoffs accepted

- We accept the owner picking a folder in exchange for no server, no account and no sync code of our own.
- We accept a new conversation that hears a summary rather than the real session in exchange for nothing Claude-specific crossing computers.
- We accept last-writer-wins on a run in exchange for no locking across computers. One Balabro open at a time avoids it.
- We accept a restart on every switch in exchange for no live re-pointing of the coach, the bot and the stats.

## Open questions and risks

- Older iCloud Drive replaced an evicted file with a hidden `.<name>.icloud` placeholder. Only macOS 27 was checked, and Balabro runs on macOS 14 and later. On a Mac that still makes placeholders, an evicted run is missing at launch, and the coach starts a new record for it that conflicts in iCloud.
- The path where a file stays not downloaded for the whole 10 s, such as offline, hasn't run for real.
- The Windows tray's items and the engine restart have run against a real engine, by `SyncTrayTests` with `BALABRO_TEST_ENGINE` set. The folder picker and the warning box themselves haven't, because that test stands in for them. The wire lines are tested on both sides.
