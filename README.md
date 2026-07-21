# Agent Island

<p align="center">
  <img src="assets/codex-pet-transparent.png" alt="Codex mascot" width="84" />
  <img src="assets/claude-mascot-transparent.png" alt="Claude mascot" width="84" />
</p>

<p align="center">
  <strong>A living macOS Dynamic Island for Codex and Claude Code.</strong><br />
  Follow multiple coding agents, see what they are doing, and catch questions or completions without leaving your current app.
</p>

<p align="center">
  macOS 14+ · Native SwiftUI/AppKit · Dependency-free Rust helper · Local-first · Version 2.2.10 (build 43)
</p>

---

## Overview

Agent Island turns the MacBook camera notch into a compact status surface for agentic coding. It tracks local Codex and Claude Code sessions, presents their state through animated mascots, and expands into a multi-session dashboard when hovered.

The production application is fully native:

- **SwiftUI** renders the island, session dashboard, meters, logs, and mascot states.
- **AppKit** owns the floating panel, physical-notch measurement, fixed-header layout, hover handling, menu-bar item, full-screen behavior, and notifications.
- A small **Rust helper** detects supported local processes and tails bounded portions of local JSONL session transcripts.
- The macOS app has **no third-party Swift packages or Rust crates**.
- The production app does not use Electron, a browser engine, JavaScript, or a webview.

## Feature highlights

| Area | What Agent Island provides |
| --- | --- |
| Physical notch | Measures the current display's real safe areas and visually fuses a true-black surface with the camera housing. |
| Smooth interaction | Hovering the notch expands the panel downward while the header and top edge remain fixed. |
| Living mascots | Codex and Claude mascots use state-specific gestures for idle, thinking, needs-input, and complete. |
| Recent-agent cluster | Shows up to three recent mascots: a 20-point animated primary followed by static 14- and 12-point mascots. |
| Multi-session dashboard | Tracks up to eight recent/live transcript sessions and lets you select a stable individual session. |
| Provider fairness | Reserves up to three tracked slots for each detected provider before filling remaining slots by recency. |
| Real activity state | Uses transcript freshness and safe task/command summaries instead of treating every open process as “Thinking.” |
| Model details | Shows provider model names and real Codex or Claude effort when the transcript exposes them. |
| Semantic colors | Gives every status and Codex effort level its own consistent color while retaining provider identity colors. |
| Context and tokens | Displays context use, context limit, session tokens, usage percentage, and the next reported reset when available. |
| Latest prompt | Shows the selected session's newest normal user prompt in a bounded local-only detail card. |
| Connected detail card | Joins the selected summary row, prompt strip, safe activity sheet, changed files, and metric rail into one compact visual story. |
| Activity and files | Keeps a bounded private scroll of safe action labels and changed-file basenames. |
| One-hour file shelf | Holds up to nine dropped files as cards — real Finder icon, name, type and size — for quick paste/drag reuse, then deletes the copies automatically. |
| Music visualizer | Optional five-bar chromatic equalizer in the notch's right wing, driven by a real FFT of system audio. Off by default; costs nothing when off or silent. |
| Volume tug-of-war | Changing system volume briefly pops the island open with the Codex and Claude mascots tugging a level bar toward whoever "won" the last change. |
| In-island settings | A Settings tab for hover open/close timing and the two media toggles, persisted in `UserDefaults`. |
| Recognizable app icon | Combines the Codex and Claude mascots in one dark purple/orange macOS icon for Finder, Applications, Activity Monitor, notifications, and system UI. |
| Full-screen mode | Hides the floating island over games/full-screen apps, keeps a menu-bar status icon, and posts native completion/input notifications. |
| Native efficiency | Uses finite transitions, long mascot rest periods, cached images, bounded readers, and event-driven full-screen checks. |

## The interaction model

### Compact notch

On a MacBook with a camera notch, Agent Island measures AppKit's live `safeAreaInsets`, `auxiliaryTopLeftArea`, and `auxiliaryTopRightArea` instead of assuming one Mac model's dimensions.

The compact surface contains:

- a centered left-wing group with up to three recently active mascots;
- a readable status label such as **Working**, **Input**, or **Done**;
- the physical camera housing in the obscured center;
- a centered right-wing total such as **8 sessions**.

The newest mascot remains the largest and is the only compact mascot that animates. The second and third mascots are smaller, static cached images. More than three sessions can still be tracked—the right wing always reports the real total.

Idle sessions do not leave a distracting wide overlay. On a display without a notch, the app falls back to a top-center capsule below the menu bar.

### Expanded dashboard

Hovering the compact surface opens a content-height dashboard. The panel follows one to four closed rows, then caps the private list viewport so five to eight sessions and open detail cards scroll internally. It grows only downward from its top edge; the header does not jump, recenter, or flicker.

Each session row can show:

- project/folder name;
- Codex or Claude provider;
- model name;
- provider reasoning effort when available;
- stable eight-character session suffix;
- current state;
- latest safe activity;
- relative activity time;
- context percentage.

Selecting a row turns that row into one connected detail card with:

- provider, model, and effort summary;
- latest local user prompt;
- context meter and token total;
- recent bounded activity steps;
- changed-file basename chips.

Clicking the same row again closes its detail section while the app continues following that session. Clicking another row follows and opens the new session. A newly actionable needs-input session may still open automatically so its question is not hidden.

The footer identifies the project as **Built by Xiezy**.

### Agent states

| State | Detection behavior | Mascot behavior |
| --- | --- | --- |
| Idle | No known activity, completed grace period expired, or last non-complete activity is older than 60 seconds. | Occasional quiet breathing gesture with long rests. |
| Thinking | A recent safe transcript activity event is present. | A recognizable thinking sequence rather than a generic loading spinner. |
| Needs input | Codex `request_user_input` or Claude `AskUserQuestion` is detected. | Question-focused gesture and native notification while full-screen. |
| Complete | A task-complete event was written within the 12-second completion grace period. | Short celebration, then the session settles to idle. |

Agent Island deliberately does not use a permanent spinner or a continuously bouncing border.

## Requirements

To build the app locally:

- macOS 14 or later;
- Swift 5.10 or later;
- Rust 1.85 or later;
- Xcode or a compatible macOS Swift toolchain;
- a MacBook notch is optional—the non-notch fallback works on other displays.

Check the local toolchains:

```bash
swift --version
rustc --version
cargo --version
```

## Build and install

### 1. Build the production application

From the project root:

```bash
zsh scripts/build-app.sh
```

The script:

1. copies the transparent production mascot PNGs into the Swift resource directory;
2. builds the Rust helper in size-optimized release mode;
3. builds the native Swift executable in release mode;
4. renders native RGBA icon sizes from the combined mascot source and packages a 1024px ICNS using only Swift/AppKit;
5. assembles `dist/Agent Island.app`;
6. embeds the helper, icon, and resources;
7. removes inherited extended attributes from the local bundle;
8. applies local ad-hoc hardened-runtime signatures to the helper and app.

Build output:

```text
dist/Agent Island.app
```

### 2. Test the bundle before installation

```bash
cargo fmt --manifest-path agent-core/Cargo.toml -- --check
cargo test --manifest-path agent-core/Cargo.toml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --scratch-path .build-tests --cache-path .build/swiftpm-cache
plutil -lint macos/Info.plist
codesign --verify --deep --strict --verbose=2 "dist/Agent Island.app"
```

### 3. Install to Applications

Quit an older Agent Island instance from its menu-bar menu first, then run:

```bash
ditto "dist/Agent Island.app" "/Applications/Agent Island.app"
open "/Applications/Agent Island.app"
```

You can also drag `dist/Agent Island.app` into the Applications folder in Finder.

If Finder previously cached the generic icon from an older local build, register the exact installed bundle once, then relaunch Finder:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "/Applications/Agent Island.app"
killall Finder
```

> [!IMPORTANT]
> Local builds are ad-hoc signed for use on the same Mac. Public distribution still requires Developer ID signing, notarization, and an installer/DMG workflow.

### Build and launch without installing

```bash
zsh scripts/run-app.sh
```

This rebuilds the project and opens the bundle directly from `dist`.

## First launch and controls

Agent Island runs as a menu-bar application and does not keep a permanent Dock tile. Its combined Codex + Claude application icon is still used in Finder, the Applications folder, Activity Monitor, notifications, and other macOS system surfaces.

On first launch:

1. allow notifications if you want completion and needs-input alerts while another app is full-screen;
2. start or continue a supported Codex or Claude Code session;
3. wait for the helper's next scan—normally within five seconds for activity and within fifteen seconds for a newly created transcript;
4. hover the notch or fallback capsule to open the dashboard.

The menu-bar menu includes:

| Menu item | Function |
| --- | --- |
| Show or Hide Island | Manually hides or restores the floating panel. |
| Pin Expanded | Keeps the panel expanded until unpinned. |
| Agent | Selects Codex or Claude for manual preview mode. |
| Preview State | Previews idle, thinking, needs-input, or complete UI. |
| Use Automatic Detection | Returns from preview/manual mode to live transcript tracking. |
| Enable Claude Live Metrics… | Installs or removes the optional local Claude status-line bridge. |
| Quit Agent Island | Stops the UI and bundled helper. |

Keyboard equivalents shown in the menu include `I` for show/hide, `P` for pin, `A` for automatic detection, and `Q` for quit.

The expanded dashboard's **Settings** tab holds hover open/close timing presets and the two media toggles. All of it persists in `UserDefaults`.

## Permissions

Agent Island asks for as little as it can. Everything below is optional; the core session tracking needs **none of it**.

| Permission | Needed for | Where |
| --- | --- | --- |
| Notifications | Completion and needs-input alerts while another app is full-screen. | System Settings → Notifications → Agent Island |
| System audio capture | The music visualizer only. Never requested unless you enable that toggle. | System Settings → Privacy & Security → Screen & System Audio Recording |

Agent Island requests **no** camera, microphone, contacts, calendar, location, Full Disk Access, or Accessibility permission, and makes no network request of any kind.

> [!NOTE]
> A locally built app is **ad-hoc signed**, and macOS only reliably lists and remembers system-audio capture for apps with a stable code-signing identity. If the visualizer bars stay flat, check the Screen & System Audio Recording pane; if the app is missing there or the grant does not survive a rebuild, sign your build with a self-signed certificate (`security create-keychain` + a code-signing identity) and rebuild.

## Supported session sources

### Codex

Agent Island reads local Codex JSONL session events under the configured `CODEX_HOME`, or `~/.codex/sessions` when `CODEX_HOME` is not set.

Supported Codex data can include:

- session identity and working directory;
- token use and model context window;
- rate-limit percentage and reset time;
- model identifier and reasoning effort;
- safe task/activity events;
- changed-file basenames;
- newest normal user prompt.

### Claude Code

Agent Island reads top-level Claude Code project transcripts under `~/.claude/projects` and the separate `claude2` profile under `~/.claude2/projects`. Subagent transcript directories are intentionally skipped so delegated worker logs do not inflate the top-level session list.

A newly opened Claude Code session normally becomes uniquely trackable after the first user prompt creates or updates its JSONL transcript. Merely opening an empty Claude terminal or IDE pane may expose a process but not yet provide a session ID, project, or transcript to display.

Agent Island does not read consumer Claude website/desktop conversation history. It tracks local Claude Code transcripts and supported Claude Code processes.

### Optional Claude live metrics

Claude transcripts expose current token use but may not expose the full context limit and rate-window reset data. Choose **Enable Claude Live Metrics…** to install the local status-line bridge.

The bridge:

- writes a signed helper copy under `~/Library/Application Support/Agent Island`;
- adds a Claude Code status-line command;
- writes normalized metrics to `~/Library/Caches/com.agentisland.AgentIsland/claude-usage.json`;
- refuses to overwrite an existing custom Claude status line;
- uses atomic settings/cache writes;
- never reads an API key;
- performs no network request.

The current Claude status cache is global, so its freshest metrics attach to the newest tracked Claude session. See [Limitations](#limitations).

## Multi-session tracking

Agent Island uses transcript identity rather than only provider process identity.

- Each top-level JSONL transcript becomes a stable session candidate.
- Multiple sessions from the same provider or project can appear simultaneously.
- Session rows use an eight-character transcript suffix to distinguish otherwise identical projects.
- Manual selection is preserved while snapshots update.
- A newly actionable needs-input session may take focus so it is not missed.
- Expanded list ordering prioritizes needs-input, working, complete, then idle; recency breaks ties.
- Compact mascot ordering is purely recent-first and is capped at three visible mascots.
- The tracker retains sessions active in the last 30 minutes plus provider candidates needed to represent detected live processes.
- The final dashboard is capped at eight sessions.
- Before filling those eight slots by global recency, up to three slots are reserved for each detected provider. This prevents a busy Codex history from hiding every live Claude session, or vice versa.

Process count is supporting evidence, not exact session identity. Provider CLIs can spawn helper processes, and neither provider currently exposes a reliable transcript-to-window mapping.

## Context, tokens, and reset data

The dashboard displays only fields that the provider actually reports.

### Codex telemetry

Codex local session events can supply:

- current context tokens;
- model context-window size;
- total session tokens;
- rate-window percentage used;
- next reset timestamp;
- rate-window duration;
- model name;
- reasoning effort.

### Claude telemetry

Claude transcripts can supply current context token usage, model name, and a top-level assistant effort such as `xhigh` or `max` when emitted. The optional local status bridge can add:

- exact context-window size;
- 5-hour or 7-day usage percentage;
- next reset timestamp.

Missing values remain absent or display an em dash. Agent Island does not invent a context limit, reset time, model, or reasoning level.

### Usage meters

- Filled segments progress from a bright provider accent toward a softer/dimmer accent.
- Codex uses muted dark purple.
- Claude uses mild orange.
- Context use turns amber at 70% and red at 85%.
- Percentages accompany the boxes for precise reading.
- The panel follows the closed session rows up to its cap; longer lists, activity, and open details scroll privately instead of making the island grow indefinitely.

### Temporary file shelf

A horizontal separator below the session list leads to a fixed-height temporary file shelf. Drop regular files there when you want to reuse them in another editor, terminal, browser, or agent session without repeatedly navigating back to the source folder.

Finder drops use two native paths instead of relying on Transferable URL negotiation. The always-present AppKit island container accepts `public.file-url`, so dragging over the compact notch first expands the island; the expanded SwiftUI shelf then accepts the matching item-provider representation. While a compatible file is over the shelf, the complete shelf gently lifts, pulses purple, brightens its border, and emits a soft glow; the effect stops as soon as the drag leaves or drops.

Each dropped file becomes a card showing its **real Finder icon** (a PDF looks like a PDF, an image shows its image icon), the file name over two lines with middle truncation, and a `TYPE · SIZE` line such as `PDF · 2.2 MB`. Hovering a card lifts it, tints its border, and brings the remove button forward.

- The shelf holds **at most nine items**; it is intentionally not infinite.
- Cards scroll horizontally, so dropping more files never makes the island grow vertically.
- Agent Island copies each dropped file into its private macOS temporary directory. It never moves or deletes the original.
- Each file may be at most **1 GB** to keep disk and copy work bounded.
- Click a card to copy that temporary file to the macOS pasteboard, or drag the card into another app.
- Use the × button to remove only the temporary copy.
- Copies expire after one hour while the app is running and are also removed on a normal app quit. A later launch cleans expired remnants after a forced termination.
- File copying runs serially at utility quality-of-service, off the main UI thread. Expiry uses one timer scheduled for the next item rather than a repeating poll.

The shelf does not upload files, index their contents, or add them to agent transcripts.

## Media features

Two optional flourishes live under the island's **Settings** tab. Both are pure Swift on top of Apple's own frameworks (Core Audio, Accelerate, AppKit) and add no dependency.

### Volume tug-of-war

Enable **VOLUME POP-UP**. Changing the system output volume briefly pops the island open into a compact HUD: the Codex mascot on the left, the Claude mascot on the right, and a ten-segment level bar between them. Whichever direction you moved the volume, that mascot leans in and scales up as if it won the tug.

The peek is transient and yields to real interaction — hovering, pinning, or starting a file drag cancels it, and it never re-surfaces stale state afterwards. Volume is read through `kAudioDevicePropertyVolumeScalar`, which requires **no permission of any kind**.

### Music visualizer

Enable **MUSIC VISUALIZER** (off by default; labelled *needs audio access*). It runs in two independent tiers:

| Tier | What it does | Permission |
| --- | --- | --- |
| Detection | Listens to `kAudioDevicePropertyDeviceIsRunningSomewhere` to know whether *something* is producing sound, and shows a `♪` glyph in the notch. | None |
| Visualization | Opens a Core Audio process tap (macOS 14.2+) into a private aggregate device, captures output on the HAL thread into a lock-guarded ring buffer, runs a reusable vDSP real-FFT, and reduces it to five log-spaced, attack/decay-smoothed bars. | System audio capture |

The five bars render in the notch's right wing as translucent capsules whose hues fan across the colour wheel and rotate slowly. On a Mac without a notch there is no wing, so the same equalizer appears as a strip inside the expanded dashboard instead.

Audio is analysed **in memory, frame by frame, and discarded**. Nothing is recorded, buffered to disk, or transmitted, and the app never asks which track is playing — there is no `MediaRemote` use and no track title, artist, or artwork anywhere in the code.

> [!IMPORTANT]
> macOS process taps do not behave like the microphone: an unauthorized tap **succeeds and silently returns zeroed buffers** instead of prompting or erroring. If the bars render but never move, the tap is not authorized — see [Permissions](#permissions).

## Useful activity summaries

The activity card avoids generic labels when the transcript provides enough trustworthy metadata. A task start can appear as `Started · Make the complete color lighter`, and recognized shell work can appear as `Checking Swift build errors · swift build`, `Testing Rust · cargo test`, or `Searching for error output · rg`.

These are bounded summaries, not raw transcript dumps. For unknown commands, Agent Island shows only a sanitized executable name. Command arguments, output, file contents, credentials, and private paths remain excluded.

## Latest prompt behavior

The selected session detail can show its newest normal user-authored prompt.

Safety and scope:

- only Codex user `response_item` message/input-text events or non-meta Claude user messages are accepted;
- known internal environment/instruction records are rejected;
- Claude tool-result content is rejected;
- whitespace is normalized;
- the value is capped at 600 Unicode characters;
- only one latest prompt is kept per in-memory session reader;
- it is sent only over the private child-process pipe to the local UI;
- Agent Island does not persist a separate prompt database or transmit prompts over a network.

The prompt card is deliberately separate from the sanitized activity log.

## Privacy and security

Agent Island reads local session metadata because that is its core function, but the production boundary is intentionally narrow.

### Data displayed

- provider and safe session identifier suffix;
- project/folder name from an absolute transcript working directory;
- state and safe activity labels;
- token/context/rate-limit telemetry;
- model identifier and permitted reasoning-effort label;
- changed-file basenames;
- newest bounded normal user prompt.

### Data excluded

- assistant responses;
- hidden model reasoning;
- shell command arguments;
- tool outputs;
- diffs and file contents;
- API keys, authentication files, and credentials;
- Claude subagent transcript content;
- internal/meta/environment/instruction records in the prompt card.

### Security design

- The Rust helper makes no network requests.
- Swift and Rust production targets have no third-party dependencies.
- Transcript reads, pending lines, activity lists, changed files, session counts, prompt length, and Swift pipe buffers are bounded.
- The temporary shelf accepts only regular non-symlink files, caps them at nine items and 1 GB each, stores copies in a mode-700 temporary directory, and never removes originals.
- The packaged app resolves only its bundled signed helper; it will not substitute an executable from the current working directory.
- External commands use explicit executable paths and argument arrays rather than user-controlled shell strings.
- The optional Claude bridge refuses to replace an existing custom status line.
- Mascot assets are true alpha-channel PNG files, avoiding white image cards or remote image loading.
- The music visualizer analyses audio frame by frame in memory and discards it. No audio is recorded, written to disk, or transmitted, and the tap is only ever created while the toggle is on.
- Volume and playback detection use Core Audio properties that require no permission; the only permission-bearing path is the opt-in visualizer.
- No `MediaRemote` or now-playing API is used, so the app never learns the track, artist, artwork, or which application is producing sound.

## Full-screen behavior and notifications

When another application owns a full-screen window, Agent Island:

1. hides the floating panel so it does not cover a game or full-screen workspace;
2. disables mascot animation tasks while hidden;
3. continues lightweight transcript tracking;
4. keeps state available through its menu-bar item;
5. posts a native notification when a session completes or needs input.

Full-screen detection reacts to application activation, Space changes, and display changes. It performs one immediate evaluation plus two finite delayed checks during a transition; it does not permanently poll the system window list.

macOS can auto-hide the menu bar in full-screen mode. Move the pointer to the screen edge to reveal the menu-bar icon. Notifications do not depend on the menu bar being visible.

Notification permission can be changed later in **System Settings → Notifications → Agent Island**.

## Architecture

```text
Codex / Claude Code processes and local JSONL transcripts
                           │
                           ▼
                 Rust helper: agent-core
       process detection · bounded transcript tailing
       token/model/prompt parsing · safe activity labels
                           │
                  JSON Lines over local Pipe
                           │
                           ▼
                   AgentCoreClient.swift
          64 KiB buffer cap · JSONDecoder · main queue
                           │
                           ▼
                     IslandModel.swift
        stable selection · aggregate state · derived layout
                           │
               ┌───────────┴───────────┐
               ▼                       ▼
       IslandHeaderView          IslandRootView
      fixed NSHostingView      body NSHostingView
               └───────────┬───────────┘
                           ▼
                 IslandContainerView
              AppKit hover/layout coordination
                           │
                           ▼
                    Borderless NSPanel
```

The header and body use separate hosting views so the top edge stays fixed while only the panel's lower boundary expands.

## Performance profile

The implementation avoids permanent high-frequency work:

- helper scan interval: five seconds while tracking, eight seconds while empty;
- transcript discovery: at most once every fifteen seconds;
- helper snapshot heartbeat: every fifteen seconds when nothing changes;
- maximum tracked readers: eight;
- maximum activity entries per session: sixteen;
- maximum changed-file basenames per session: sixteen;
- initial/tail transcript read cap: 1 MiB;
- partial-line cap: 256 KiB;
- Swift protocol buffer cap: 64 KiB;
- mascot images: decoded once and cached;
- compact animations: newest mascot only;
- expanded list animations: selected row only;
- resize timer: active only for a 0.28–0.38 second transition and matched to the display refresh rate, clamped to 60–120 Hz.

Recent installed-build measurements on the same code path:

| Process | Physical footprint | Peak | CPU behavior |
| --- | ---: | ---: | --- |
| SwiftUI/AppKit app | 22.3 MiB | 24.1 MiB | Usually 0.0%; brief update/render samples around 1.3–1.4%. |
| Rust helper | 4.96 MiB | 5.76 MiB | Usually 0.0%; observed poll sample around 0.1%. |

Combined physical footprint was approximately 27.3 MiB. `ps` can report roughly 46–49 MiB UI RSS because that metric includes shared framework mappings.

### Music visualizer cost

The visualizer is the only continuously animating part of the app, so it was measured directly (`top -l N -s 2`, identical audio source):

| State | App CPU | WindowServer | RSS |
| --- | ---: | ---: | ---: |
| Visualizer off (default) | 0% | — | ~21 MB |
| On, nothing playing | ~0% | — | ~21 MB |
| On, music playing | ~5.4% of one core | ~3.6% | ~66 MB while drawing |

Roughly 1–1.5% of an Apple-silicon chip's total capacity while music plays, and nothing at all otherwise. The elevated RSS is Canvas render buffers and returns to ~21 MB within seconds of the audio stopping.

Getting there took two rounds of measurement, and both findings are worth knowing before changing this code:

- Publishing spectrum frames from an `@Published` property on the shared `IslandModel` invalidated **every** view bound to that model 30 times a second. The bar values now live in a dedicated `SpectrumStore`, so a frame invalidates only the equalizer.
- Five `Capsule` views cost far more than the FFT that fed them. Drawing all five in a single `Canvas` pass cut app CPU by a quarter and WindowServer compositing by two thirds, because one bitmap update replaces five layer-tree updates on a translucent panel.

A one-time `leaks` scan reported zero leaked bytes for the Rust helper. macOS restricted full writable-memory inspection of the signed Swift process, so the project does not claim a definitive UI leak result from that tool. The UI lifecycle audit confirms observer cleanup, weak async captures, bounded buffers, finite timers, and automatic SwiftUI task cancellation.

## Limitations

Agent Island is functional, but several integrations require provider support that is not yet available.

### No real question-answer transport yet

Needs-input detection is real. The app can focus the relevant row and notify you, but it cannot safely submit an answer back to the exact Codex or Claude session without supported provider-specific IPC.

Manual-preview answer choices demonstrate the intended interface only. They must not be described as controlling a real session.

### No exact original IDE or terminal focus

Provider transcripts do not reliably identify the original Terminal, iTerm, Warp, VS Code, Cursor, or IDE pane. The former generic **Open in Terminal** button was removed because opening a new Terminal at the project folder was misleading.

### No real Stop/interrupt control

The preview Stop button changes local preview state. It does not terminate or interrupt an actual agent task. A real implementation requires exact session-specific IPC and must never kill an inferred PID.

### Claude session creation requires a transcript

An empty newly opened Claude Code pane may not appear immediately because there is no unique transcript yet. Send the first prompt, then allow up to fifteen seconds for discovery.

### Claude live metrics cache is global

The optional status bridge stores the freshest Claude metrics globally and attaches them to the newest tracked Claude transcript. A future version should make this cache session-specific.

### Session lifecycle is heuristic

The 30-minute retention window and live provider process counts are evidence, not authoritative open/closed tab metadata. Provider layout or process changes may require parser updates.

### Local build distribution

The current build is suitable for local installation. Public distribution still needs Developer ID signing, notarization, update delivery, and an installer.

## Troubleshooting

### A Claude Code session is not visible

1. Make sure this is Claude Code, not a consumer Claude website/desktop conversation.
2. Send the session's first prompt so Claude creates a top-level project transcript.
3. Wait up to fifteen seconds.
4. Choose **Use Automatic Detection** from the Agent Island menu.
5. Confirm a transcript exists under `~/.claude/projects`, or under `~/.claude2/projects` when using the `claude2` profile.
6. Check sanitized provider detection:

   ```bash
   "/Applications/Agent Island.app/Contents/Helpers/agent-core" --list-detected
   ```

   This diagnostic prints only provider names and PIDs.

Version 2.2.2 reserves up to three bounded-list slots per detected provider, preventing eight newer Codex logs from hiding all live Claude candidates.

### The island always says Thinking

Agent Island should settle to idle when the newest non-complete activity is older than 60 seconds. Ensure automatic detection is enabled and the installed helper matches the current app bundle.

### The island does not align with the notch

- Confirm the Mac display reports a real camera safe area.
- Disconnect/reconnect an external display or relaunch the app after changing display mode.
- Non-notch displays intentionally use the below-menu-bar capsule fallback.

### The island overlays a full-screen game

Switch away from and back to the full-screen Space once so macOS emits an activation/Space event. Native full-screen windows are event-detected; unusual borderless full-display windows that emit no relevant system event may require a future fallback check.

### Notifications do not appear

Open **System Settings → Notifications → Agent Island** and allow notifications. Alerts are posted only for real complete or needs-input transitions while the floating panel is suppressed for full-screen.

### The app fails to launch after a local build

Verify the bundle:

```bash
plutil -lint "dist/Agent Island.app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "dist/Agent Island.app"
```

Then launch from Terminal to observe macOS errors:

```bash
open "dist/Agent Island.app"
```

## Development

### Rust checks

```bash
cargo fmt --manifest-path agent-core/Cargo.toml -- --check
cargo test --manifest-path agent-core/Cargo.toml
```

The current suite covers:

- Codex and Claude process classification;
- background-worker exclusion;
- provider-fair bounded session selection;
- activity-based state transitions;
- Codex and Claude usage parsing;
- changed-file privacy;
- workspace extraction;
- transcript-path omission from snapshots;
- strict model/effort metadata parsing;
- latest-prompt extraction and internal/tool-result filtering.
- prompt-aware task starts and command-purpose summaries that exclude raw arguments.

### Swift checks

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

49 unit tests cover the island model's state machine, hover/expand geometry, volume tug-of-war routing, spectrum math and smoothing, shelf formatting, and the temporary file shelf's lifecycle.

> [!TIP]
> `DEVELOPER_DIR` is required when `xcode-select -p` points at the Command Line Tools, which ship no XCTest. If `swift test` reports `no such module 'XCTest'`, that is the cause.

### Production build

```bash
zsh scripts/build-app.sh
```

## Project structure

```text
dynamic_island/
├── agent-core/
│   ├── Cargo.toml
│   └── src/main.rs
├── assets/
│   ├── agent-island-app-icon.png
│   ├── codex-pet-transparent.png
│   └── claude-mascot-transparent.png
├── macos/
│   ├── Info.plist
│   ├── Sources/AgentIsland/
│   │   ├── AgentCoreClient.swift        # helper pipe → decoded snapshots
│   │   ├── AgentIslandApp.swift
│   │   ├── AppDelegate.swift            # panel, notch metrics, menu bar, full-screen
│   │   ├── ClaudeMetricsBridge.swift    # optional local status-line bridge
│   │   ├── IslandModel.swift            # state machine + derived layout
│   │   ├── IslandViews.swift            # island, dashboard, shelf, settings
│   │   ├── AudioMonitor.swift           # volume + playback detection + process tap
│   │   ├── AudioRingBuffer.swift        # lock-guarded HAL-thread buffer
│   │   ├── SpectrumAnalyzer.swift       # reusable vDSP real-FFT
│   │   ├── SpectrumMath.swift           # bins → bars, smoothing, hue phase
│   │   ├── SoundwaveView.swift          # SpectrumStore + Canvas equalizer
│   │   ├── VolumeMath.swift             # tug direction, lit segments
│   │   ├── VolumeHUDView.swift          # mascot tug-of-war HUD
│   │   ├── ShelfFormatting.swift        # size and type labels
│   │   ├── TemporaryFileShelf.swift     # one-hour file shelf store
│   │   └── Resources/
│   └── Tests/AgentIslandTests/          # 49 unit tests
├── scripts/
│   ├── build-app.sh
│   ├── make-app-icon.swift
│   └── run-app.sh
├── Package.swift
├── LICENSE
└── README.md
```

## Versioning

Agent Island follows semantic versioning plus a monotonically increasing macOS build number.

| Change | Version example | Use when |
| --- | --- | --- |
| Patch | `2.2.1` → `2.2.2` | Bug fixes, visual corrections, or small performance improvements. |
| Minor | `2.2.2` → `2.3.0` | Backward-compatible product features. |
| Major | `2.3.0` → `3.0.0` | Breaking behavior or architecture changes. |

Every installed build also increments `CFBundleVersion`.

Current release:

```text
CFBundleShortVersionString = 2.2.10
CFBundleVersion = 43
```

## Design principles

Contributions and future changes should preserve these decisions:

- keep the top edge fixed and expand only downward;
- use true black around the physical notch;
- keep the header separate from animated body geometry;
- use expressive mascot poses, not generic spinners or border jiggle;
- keep logs and session details internally scrollable;
- show only provider data that is available truthfully;
- preserve provider fairness and stable transcript identity;
- do not claim real answer, Stop, or original-window control without safe session IPC;
- add no production dependency without a security and performance review;
- keep all readers, buffers, arrays, and displayed prompt content bounded;
- favor event-driven behavior and long animation rests for battery efficiency.

## Contributing

Issues and pull requests are welcome. Before opening a PR:

1. run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` and `cargo test --manifest-path agent-core/Cargo.toml`;
2. keep the build warning-free;
3. add tests next to the code you changed — every model change, math helper, and store belongs under `macos/Tests/AgentIslandTests`;
4. re-read [Design principles](#design-principles), especially the dependency-free rule: **no third-party Swift package or Rust crate** enters the production targets without a security and performance review.

If a change touches anything that animates continuously, measure it before and after rather than reasoning about it — see [Music visualizer cost](#music-visualizer-cost) for why.

## License

Released under the [MIT License](LICENSE).

## Credits

**Built by Xiezy.**

Codex, Claude, OpenAI, and Anthropic names, marks, and visual identities belong to their respective owners. This is an independent, unaffiliated project; it is not endorsed by or associated with either company. The mascot artwork in `assets/` is original interface art for this project and is covered by the MIT license above — the underlying trademarks are not.
