# League Spell Timing Helper

Tracks enemy summoner spell (Flash) cooldowns in League of Legends and types them into in-game chat with a single hotkey.

## How it works

- **Listener** (`spell_timer_listener.ps1`) polls the LoL Live Client API (`https://127.0.0.1:2999/liveclientdata/allgamedata`) and shows a live table of enemy Flash timers. A low-level keyboard hook watches in-game chat: whatever you type between the two Enter keys is interpreted as a command (see Chat input).
- **Helper** (`spell_timer_helper.exe`) is a driver-level keyboard/mouse injector built on the [Interception](https://github.com/oblitum/Interception) driver. It types the timers into the game chat using hardware-level input, which works where normal SendKeys/clipboard paste does not (the game's in-game clipboard is separate from the Windows clipboard).
- Timers flow from listener to helper through a shared memory-mapped file (`SpellTimersMMF`), with a disk fallback (`spell_timers.txt`).

## Features

- **Flash-only tracking**: digits `1-5` record enemy Flash (slot auto-detected per champion). Hextech Flashtraption is treated as Flash. Re-recording a Flash that is still on cooldown shaves 10s off the timer instead of resetting it.
- **Manual Flash timers**: `Enter → 12158 → Enter` sets the Flash timer for enemy 1 (top) to ready at 21:58 — for teammate pings or correcting the auto timer. Position (1-5) + MMSS; sub-10-minute times need a leading zero (`10530` = 05:30). Replaces the auto timer; re-recording shaves 10s like a normal re-use.
- **Cosmic Insight toggle**: `Enter → 555 → Enter` in game chat toggles Cosmic Insight for the support (enemy 5); `111`-`555` toggle enemies 1-5 respectively.
- **Haste-aware cooldowns**: timers account for haste from Ionian Boots (+10), Crimson Lucidity (+20), and Cosmic Insight (+18).
- **In-game hotkeys** (game focused):
  - `Ctrl+Shift+V` — open chat, type timers, Ctrl+A/Ctrl+C (fills the game's in-game clipboard), send.
  - `Ctrl+V` — open chat, paste from the game clipboard, send.
- **Output format**: space-separated `MMSSpos` sorted by time descending, e.g. `2904jg 2900sp 2837top 2740ad`.
- **Game-only influence**: the helper is a pure pass-through when the game is not focused.
- **Self-managing processes**: starting either the listener or the helper starts the other if missing; quitting the listener (press `Q`) stops the helper.

## Chat input

Open chat with `Enter`, type one of the following, then `Enter` again:

| Input | Meaning |
|-------|---------|
| `5` | Record enemy 5's Flash (starts its cooldown timer) |
| `11` | Clear enemy 1's Flash and custom timers |
| `555` | Toggle Cosmic Insight for enemy 5 (support) |
| `12158` | Manual Flash timer: enemy 1 (top) ready at 21:58 |

Anything else is ignored (sent to chat as a normal message).

## Requirements

- Windows with the [Interception](https://github.com/oblitum/Interception) driver installed (services `keyboard` and `mouse`).
- League of Legends running with the Live Client API enabled.
- PowerShell 5.1 (for the listener).
- .NET Framework 4.x (for the helper; prebuilt exe included).

## Usage

1. Install the Interception driver and reboot.
2. Double-click `start_listener.cmd` (or run `spell_timer_helper.exe` — it starts the listener too).
3. In game, press `Ctrl+Shift+V` to send the timers to chat, or record manually with `Enter → digit(s) → Enter` (see Chat input).
4. Press `Q` in the listener window to quit (stops the helper as well).

## Layout

```
spell_timer_listener.ps1   main tracker (Live Client API polling, chat hook, timers)
spell_timer_helper.exe     driver-level input helper (prebuilt)
interception.dll           Interception library (BSD-3-Clause, see credits)
start_listener.cmd         launcher for the listener
build_helper.cmd           recompiles the helper from source
src/spell_timer_helper.cs  helper source
```

## Building the helper

Run `build_helper.cmd`, or:

```
"C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /r:System.Management.dll /out:spell_timer_helper.exe src\spell_timer_helper.cs
```

## Credits

- [Interception](https://github.com/oblitum/Interception) driver and library by Francisco López (Oblita), BSD-3-Clause. `interception.dll` is distributed unmodified.
- League of Legends is a trademark of Riot Games. This project is not affiliated with or endorsed by Riot Games.

## Disclaimer

For educational purposes. Using input automation in online games may violate the game's terms of service — use at your own risk.