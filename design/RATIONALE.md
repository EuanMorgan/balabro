# Balabro design: a pure coach state machine behind a thin shell

## Problem

Balabro watches the player's Balatro run through the game's own `save.jkr` and coaches each decision with Opus 5.5 through the user's logged-in `claude` CLI. Several facts from the game's code make the shape less obvious than "watch file, call Claude":

- `save_run()` only queues a save. The save thread writes at most every 5 s on macOS (`globals.lua:52`), or sooner when the game stage changes, and it keeps only the newest queued table. So writes get merged, and the app can start partway through a run. Any rule that works out a decision by comparing a save with the one before it breaks.
- The write isn't atomic (`love.filesystem.write`), so a read can catch half a file.
- Balatro has no run ID. The seed, deck and stake are the closest thing, and a player can replay a seed.
- The save shows that a shop pack is opening (`ACTION={type="use_card",card=<sort_id>}`) but never shows the cards in it. Packs from skip tags leave no trace beyond the tag itself.
- The save holds things the player can't see: the deck's draw order and the faces of face-down cards. Coaching on those would be cheating.
- The CLI keeps the conversation. A turn killed halfway must not leave that conversation in a broken state.
- A Finder-launched app has neither `~/.local/bin` on PATH nor the `CLAUDE_CONFIG_DIR` the user sets in `~/.zshrc`.
- The repo is public, so the game's font, text and art load at runtime from the user's install.

## Usage (caller's view)

The player's view, as in the README:

> Open Balabro. A small dark panel appears; drag it to a corner. Start or continue a run in Balatro. Each time you draw a hand, enter or reroll the shop, open a pack or reach a blind select, the panel shows **Do this now** within a few seconds, with **Why** folded underneath. Press ⌃⌥Space to ask a follow-up such as "why keep the 6?". Grant Screen Recording the first time a pack opens, so the coach can see the cards.

The shell's view. There is one call site per kind of input, and none of them knows the coaching rules:

```swift
// SaveWatcher yields CoachEvents. The runtime feeds them to the pure reducer and performs the effects.
for await event in SaveWatcher(root: balatroDir).events() { send(event) }

private func send(_ event: CoachEvent) {
    let effects = coach.reduce(&state, event)   // all policy lives here
    view = state.view                           // the overlay observes this, nothing else
    effects.forEach(perform)                    // .startTurn, .cancelTurn, .captureGameWindow, .save
}

// The overlay's question box and the global shortcut:
runtime.ask("why keep the 6?", withScreenshot: false)
```

The test's view. Policy is checked with real saves and no mocks:

```swift
var state = CoachState(restoring: [])
_ = coach.reduce(&state, .saveWritten(try snap("02-hand")))
let effects = coach.reduce(&state, .saveWritten(try snap("03-hand-after-discard")))
#expect(effects.contains(.cancelTurn(TurnID(0))))
```

## Shape

**Two targets.** `BalabroCore` is pure: save decoding, the domain model, decision detection, the coach reducer, prompt text, the CLI's command line and output format, and advice parsing. It has no AppKit, no `Process` and no file watching. `Balabro` is the executable shell: FSEvents, the `claude` process, ScreenCaptureKit, the hotkey, the panel and the JSON run store. To follow data from input to output you read three files: `SaveFile.swift`, `Coach.swift` and `CoachRuntime.swift`.

**One boundary for game bytes** (per boundary-discipline). `SaveFile.decode(_:profile:)` is the only public entry. It inflates raw DEFLATE (Apple's `COMPRESSION_ZLIB` is raw RFC 1951, the same format LÖVE writes). It also accepts plain `return {...}` text, as the game's own `get_compressed` does, which lets tests pass literals. It parses with an internal `LuaLiteral` and maps the result to `RunSnapshot`. `LuaValue` is `internal`, so no code outside the core can build on raw Lua. The same parser reads `en-us.lua` into `GameText`. `.incomplete` is the one error that means "the file is still being written; retry".

**The types rule out hidden information.** `RunSnapshot.deck` is a `DeckComposition`, a count of each card, so draw order never gets past the boundary. A face-down card in the hand is `HandCard.faceDown` and carries nothing. Neither can be leaked by accident, because there's nothing to leak.

**A decision is worked out from one snapshot, never from a comparison with the previous one.** `Decision.detect(in:text:)` uses the save's `STATE` plus two pack signals: a shop `ACTION`, or an unapplied pack tag at blind select. It returns `nil` for round end, game over and unknown states. Merged writes and a start partway through a run therefore change nothing.

**Same prompt means same decision.** `Decision.fingerprint` is the SHA-256 of the prompt text Claude would receive. Duplicate writes, FSEvents reporting one write twice, and a restart that rereads the save are all dropped by one comparison against the in-flight turn, the waiting decision or `RunRecord.lastCoached`. There's no separate list of "fields that matter" to keep in step with the prompt (no hand-synced list).

**Run identity.** `RunIdentity` is the profile (from the file path), the seed, the deck and the stake. `ProgressClock` holds counters the game only increases within a run: round, hands played, cards discarded, rerolls and purchases. If the identity matches but a counter went down, the player is replaying the seed, and the `RunKey` replay number goes up by one. A deleted `save.jkr` ends the current run. On restart, the run reattaches by the same rule.

**The conversation only moves forward on a completed turn.** This is the load-bearing decision. Each turn runs `claude -p ... --resume <head> --fork-session`. `head` is the session after the last completed turn, and only `.done` moves it. I checked this on CLI 2.1.312: the forked turn remembered the earlier one and reported a new session ID (the fixtures are in `Tests/.../claude-stream`). So cancelling a stale turn, a crash halfway through a turn, or a quit leaves the conversation exactly as it was, and every transition is safe to repeat. The first turn of a run has no `--resume` at all.

**Concurrency policy, in types.** `CoachState.Activity` is `idle`, `capturing(id, purpose)` or `running(turn)`, so two `claude` processes at once can't be represented. When a new decision arrives during a decision turn, the old turn is cancelled, because its board no longer exists. A new decision never cancels a question the player typed. It waits in `waitingDecision`, and the newest one wins. Questions asked while the coach is busy are joined into `queuedQuestion` and run before any waiting decision. Output from a cancelled turn is ignored by matching `TurnID`, and a stale screenshot by matching `CaptureID`. Failures don't retry on their own, because "not logged in" would loop. The overlay offers Retry.

**Follow-ups.** A question doesn't replace the advice. `CoachState.view` takes the newest decision's answer as the plan and shows every question since then under it, so the next decision clears them. A reply is plain text. Only a reply that changes what to do adds a `**Do this now:**` block, which replaces the plan's steps and reasons. The steps stay pinned at the top of the panel, and everything under them scrolls.

**Scores.** The score so far, the target and your money come from the save, so they are exact. What a hand will score comes from Claude in a `**Score:**` block, because working it out in the app would mean reimplementing every joker. Those numbers are only as right as Claude's maths.

**Stats.** All-time totals come from the game's `profile.jkr`, which goes back further than Balabro. The game forgets a run when it ends, so `RunRecord.summary` keeps one, updated on every save. A removed save also happens when a run is abandoned, so a summary says how far a run got and whether it won, not that it lost.

**Updates.** `Updater` reads GitHub's release list at launch and every 6 hours, because `/releases/latest` leaves out pre-releases. A release counts only if it has `Balabro-<version>.zip` attached. Clicking **Update** downloads the zip, checks the bundle id, the version and the signature, swaps the app and reopens it once the old process has exited. Being offline shows nothing. A failed install offers the release page instead.

**Booster packs.** A `.openPack` decision returns `.captureGameWindow(id, after: 1.8 s)` instead of starting a turn. The shell captures the largest Balatro window (bundle `com.Balatro.localthunk`) with ScreenCaptureKit, scales it so the long edge is at most 1568 px, and sends it back as `.screenshot(id, png:)`. The turn then carries the PNG as a base64 image block in the stream-json stdin line, so it needs no tool and no temp file. If Screen Recording is denied, the turn still runs, with text telling Claude to ask the player to list the cards, and the overlay shows a permission banner. A follow-up can also attach a screenshot.

**The CLI command line** (`ClaudeInvocation`, pure and tested):
`-p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --model claude-opus-5-5 --system-prompt <coach prompt> --tools "" --strict-mcp-config --setting-sources "" --disable-slash-commands [--resume <head> --fork-session]`.
The system prompt replaces Claude Code's coding prompt and sets the old chat's format. `--tools ""`, `--strict-mcp-config` and `--setting-sources ""` skip the user's MCP servers, hooks and CLAUDE.md (2.8 s against 9.5 s) but keep the subscription login, which `--bare` drops. Arguments go to `Process` as an array, so the empty `""` survives. The working directory is fixed at `~/Library/Application Support/Balabro/conversations`, because `--resume` only finds sessions filed under the current folder. Stdin always gets exactly one line and is then closed.

**Finding `claude` from Finder.** `ClaudeLocator` checks, in order: a saved override, then the user's login shell (`$SHELL -l -i -c` printing `command -v claude`, `$CLAUDE_CONFIG_DIR` and `$PATH` between record-separator characters, with a 5 s timeout), then the usual install paths. It checks the result with `claude --version` and saves it, so the probe runs once. `-i` is needed because this user sets `CLAUDE_CONFIG_DIR` in `.zshrc`.

**Overlay.** An `NSPanel` with `.nonactivatingPanel`, `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, the app's `.accessory` policy (`LSUIElement`) and the `.screenSaver` level. It shows over Balatro's fullscreen window without taking focus from the game. The panel uses the felt colour (`#374244`) with chip blue (`#009DFF`) and mult red (`#FE5F55`) as the only accents. The headline and labels use the game's `m6x11plus.ttf`, unzipped from the user's `Balatro.love` with `/usr/bin/unzip -p` and registered for this process only. Font sizes are whole multiples of 11 px. The advice body uses the system font for readability. "Do this now" comes first and large, and "Why" starts folded. `Advice(markdown:)` parses partial streams, so step 1 shows as soon as it arrives. The global shortcut uses Carbon `RegisterEventHotKey`, which needs no Accessibility permission and doesn't pass the keystroke on to the game.

**Persistence.** `RunRecord` holds the key, progress, `head`, `lastCoached` and the transcript. It is the only state that survives a restart, written whole and atomically on each `.save` effect. `CoachState.view` is computed and never stored.

**Build and release.** There is no Xcode project. `scripts/make-app.sh <version>` builds a universal release binary with SwiftPM, puts together `Balabro.app` from `Packaging/Info.plist`, ad-hoc signs it with `codesign --sign -`, checks the signature, and zips it with `ditto`. I ran it once: it produced a universal (arm64 and x86_64), ad-hoc signed `.app` that passes `codesign --verify --strict`. `gh release create` stays a manual step.

**Tests** (Swift Testing, all on `BalabroCore`, through public API only). The fixtures are the twelve real saves from `tools/driver/run.sh` and the two recorded CLI streams. Expected values are read off the files and off the driver's pack screenshot by hand: the hand `K♥ K♣ 7♠ 6♥ 5♠ 3♠ 3♦ 2♦`, `p_buffoon_normal_2`, the session IDs, and `"PLUM"`. The suites cover decoding, decision kinds for every save, fingerprint equality, every policy rule in the reducer, the stream decoder, the command line, and advice parsing. They are marked `.disabled("sketch")` until their bodies exist.

**What it deliberately doesn't do:** read `settings.jkr` (the profile whose save was just written is the active one), keep a zip reader, compute joker numbers itself (Claude fills `#1#` from `liveValues`), or retry failed turns automatically.

**Interface depth.** The public surface the shell uses is `SaveFile.decode`, `Coach.reduce`, `CoachState.view`, `ClaudeInvocation` and `StreamDecoder`. Behind them sit the Lua grammar, the mapping of every save path, decision rules, duplicate dropping, run identity and replay detection, the cancel and queue policy, the fork-from-head rule, and screenshot sequencing. The shell carries out four effects and decides nothing.

## Synthesis decision

Four runners sketched the app: Opus, Fable, Sonnet and Haiku. This Opus candidate is the base. It is the only one that works out a decision from one snapshot alone, so the game's 5 s write throttle and an app that starts partway through a run can't confuse it. The others compared each save with the one before. Its pure `Coach.reduce` state machine also keeps every policy rule in one file, and its forking rule makes cancelling a turn safe without repair logic.

Grafted from the others:

- From Sonnet and Haiku, `--disable-slash-commands` on every turn.
- From Sonnet's `balabro-dump`, a `--print-prompt <save.jkr>` mode on the app binary, so a real save can be checked without the overlay. It is a flag, not a separate target.
- From Fable and Sonnet, decode errors that name the path, such as `GAME.current_round.hands_left`. `SaveFileError.unexpectedShape(path:)` already has room for it.

Rejected:

- Sonnet's three modules. Two targets with `internal` types already keep raw Lua out of the shell.
- Fable's own zip reader for `Balatro.love`. `/usr/bin/unzip -p` does the same job.
- Haiku's rule that never cancels a running turn. With forking, cancelling is safe, and stale advice is the worse outcome.
- The tag-triggered GitHub Actions release in Fable and Sonnet. Hosted runners may not have Swift 6.4, and a local `scripts/make-app.sh` plus `gh release create` is enough.

Checked after synthesis. `--resume <head> --fork-session` keeps the prompt cache: on Sonnet with an 8,400-token prefix, the two forked turns read 7,838 and 8,444 cached tokens. Haiku's earlier zero was below its minimum cacheable length. A base64 PNG sent as a stream-json image block works on the subscription login: Haiku named both jokers in the driver's pack screenshot.

## Tradeoffs accepted

- We accept one orphaned session file per cancelled turn under `<configDir>/projects/` in exchange for a conversation that a cancel or crash can never corrupt.
- We accept that cancelled turns still use some of the subscription in exchange for advice that never describes a board the player has already left.
- We accept a full game state in every decision prompt, so the conversation grows by about 1 to 2 thousand tokens per decision, in exchange for prompts that don't depend on history and fingerprints that are exact. The CLI compacts the conversation once it gets long.
- We accept a 1.8 s fixed wait before the pack screenshot in exchange for not tracking animation state.
- We accept a self-signed certificate, which keeps Screen Recording across updates but still needs Open Anyway on first launch, in exchange for shipping without a Developer ID.
- We accept that a joker's text arrives as a template plus raw numbers in exchange for not copying `card.lua`'s per-joker code.

## Alternatives considered

- **Plain `--resume <id>` (or `--session-id` then `--resume`) with no fork.** The surface is the same, but a turn killed halfway can leave a user message with no reply in the session, and the next turn inherits it. Cancelling would then need repair logic or a rule against cancelling. Forking from the last completed turn removes the question.
- **Let a stale turn finish, then run the newest decision.** It's simpler to reason about, but the player waits behind advice for a hand they've already discarded. Opus turns take tens of seconds, so that wait is the main experience problem.
- **The app owns the transcript and sends the history each turn with no CLI session.** This is fully transactional, but it moves conversation storage and trimming into the app and may lose prompt caching. It's a bigger interface for the same result.
- **Comparing each save with the previous one to classify decisions.** This breaks when the game merges writes, which the 5 s throttle guarantees, and when the app starts partway through a run.

## Open questions and risks

- Does a held pack tag always fire on the very next blind choice (`tag.lua:206`)? If not, rule 2 in `Decision.detect` can announce a pack that isn't opening.
- Is the `.screenSaver` level enough over LÖVE's fullscreen window, and does `.fullScreenAuxiliary` work when Balatro uses a non-Space fullscreen?
- Is 1.8 s right for every pack size, including Mega packs?
- The test fixtures contain game strings such as card labels and `"Red Deck"` inside the saves. Is that acceptable in a public repo, or should they be cut down? The driver's PNG is game art and is not committed.
- Should the coach comment on round end or game over? This design treats both as "no decision".

## Next implementation step

Implement `LuaLiteral.parse` and `SaveFile.decode`, then turn on `SaveFileTests` against the twelve driver saves.
