# League Spell Timing Helper

Tracks enemy summoner spell (Flash) cooldowns in League of Legends and types them into in-game chat with a single hotkey.

## How it works

- **Listener** (`spell_timer_listener.ps1`) polls the LoL Live Client API (`https://127.0.0.1:2999/liveclientdata/allgamedata`) and shows a live table of enemy Flash timers.
- **Helper** (`spell_timer_helper.exe`) is a driver-level keyboard/mouse injector built on the [Interception](https://github.com/oblitum/Interception) driver. It types the timers into the game chat using hardware-level input, which works where normal SendKeys/clipboard paste does not (the game's in-game clipboard is separate from the Windows clipboard).
- Timers flow from listener to helper through a shared memory-mapped file (`SpellTimersMMF`), with a disk fallback (`spell_timers.txt`).

## Features

- **Flash-only tracking**: digits `1-5` record enemy Flash (slot auto-detected per champion), double digit (e.g. `11`) clears it.
- **Cosmic Insight toggle**: `Enter → 555 → Enter` in game chat toggles Cosmic Insight for the support (enemy 5); `111`-`555` toggle enemies 1-5 respectively.
- **Haste-aware cooldowns**: timers account for haste from Ionian Boots (+10), Crimson Lucidity (+20), and Cosmic Insight (+18).
- **In-game hotkeys** (game focused):
  - `Ctrl+Shift+V` — open chat, type timers, Ctrl+A/Ctrl+C (fills the game's in-game clipboard), send.
  - `Ctrl+V` — open chat, paste from the game clipboard, send.
- **Manual recording**: `Enter → digit(s) → Enter` in game chat.
- **Ctrl+number mode** (toggle: `Ctrl+Shift+C`): when enabled, plain digits in chat are converted to Ctrl+digit — pressing `5` records enemy 5 while the hook injects Ctrl so the game swallows the keypress and nothing is typed into the chat box.
- **Output format**: space-separated `posMMSS` sorted by ready time, e.g. `jg2904 sp2900 top2837 ad2740`.
- **Game-only influence**: the helper is a pure pass-through when the game is not focused.
- **Self-managing processes**: starting either the listener or the helper starts the other if missing; quitting the listener (press `Q`) stops the helper.

## Requirements

- Windows with the [Interception](https://github.com/oblitum/Interception) driver installed (services `keyboard` and `mouse`).
- League of Legends running with the Live Client API enabled.
- PowerShell 5.1 (for the listener).
- .NET Framework 4.x (for the helper; prebuilt exe included).

## Usage

1. Install the Interception driver and reboot.
2. Double-click `start_listener.cmd` (or run `spell_timer_helper.exe` — it starts the listener too).
3. In game, press `Ctrl+Shift+V` to send the timers to chat, or record manually with `Enter → digit → Enter`.
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