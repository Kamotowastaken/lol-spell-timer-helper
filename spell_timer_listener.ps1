param(
    [int]$IntervalMs = 1000
)

[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Collections.Concurrent;

public static class ChatHook
{
    public static ConcurrentQueue<string> Events = new ConcurrentQueue<string>();
    public static System.Threading.AutoResetEvent EventsSignal = new System.Threading.AutoResetEvent(false);
    private static IntPtr _hook = IntPtr.Zero;
    private static Thread _thread;
    private static uint _threadId;
    private static bool _chatOpen = false;
    private static System.Text.StringBuilder _pending = new System.Text.StringBuilder();
    private static EventWaitHandle _typingFlag;

    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int VK_RETURN = 0x0D;
    private const int VK_ESCAPE = 0x1B;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

    [DllImport("user32.dll")]
    private static extern bool PostThreadMessage(uint idThread, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY; }

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT { public uint vkCode; public uint scanCode; public uint flags; public uint time; public IntPtr dwExtraInfo; }

    private static LowLevelKeyboardProc _proc = HookCallback;

    private static bool IsGameFocused()
    {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero) return false;
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        try
        {
            System.Diagnostics.Process p = System.Diagnostics.Process.GetProcessById((int)pid);
            return p.ProcessName == "League of Legends";
        }
        catch { return false; }
    }

    private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && wParam == (IntPtr)WM_KEYDOWN)
        {
            KBDLLHOOKSTRUCT k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            if (_typingFlag != null && _typingFlag.WaitOne(0)) { return CallNextHookEx(_hook, nCode, wParam, lParam); }
            if (!IsGameFocused())
            {
                if (k.vkCode == VK_RETURN || k.vkCode == VK_ESCAPE)
                {
                    _chatOpen = false;
                    _pending.Length = 0;
                }
                return CallNextHookEx(_hook, nCode, wParam, lParam);
            }
            if (k.vkCode == VK_RETURN)
            {
                if (_chatOpen)
                {
                    if (_pending.Length > 0)
                    {
                        Events.Enqueue(_pending.ToString());
                        EventsSignal.Set();
                    }
                    _pending.Length = 0;
                    _chatOpen = false;
                }
                else
                {
                    _chatOpen = true;
                }
            }
            else if (k.vkCode == VK_ESCAPE)
            {
                _chatOpen = false;
                _pending.Length = 0;
            }
            else if (_chatOpen)
            {
                char c = '\0';
                if (k.vkCode >= 0x31 && k.vkCode <= 0x39) { c = (char)k.vkCode; }
                else if (k.vkCode == 0x30) { c = '0'; }
                else if (k.vkCode >= 0x41 && k.vkCode <= 0x5A) { c = (char)k.vkCode; }
                else if (k.vkCode == 0x20) { c = ' '; }
                if (c != '\0')
                {
                    _pending.Append(c);
                }
                else
                {
                    _pending.Length = 0;
                }
            }
        }
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    private static void ThreadProc()
    {
        _threadId = GetCurrentThreadId();
        _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, IntPtr.Zero, 0);
        if (_hook == IntPtr.Zero) { Console.WriteLine("ChatHook: SetWindowsHookEx failed"); }
        MSG msg;
        while (true)
        {
            int r = GetMessage(out msg, IntPtr.Zero, 0, 0);
            if (r <= 0) break;
        }
        if (_hook != IntPtr.Zero) UnhookWindowsHookEx(_hook);
    }

    public static void Install()
    {
        try { _typingFlag = new EventWaitHandle(false, EventResetMode.ManualReset, "SpellTimersTyping"); }
        catch { _typingFlag = null; }
        _thread = new Thread(ThreadProc);
        _thread.IsBackground = true;
        _thread.Start();
    }

    public static void Uninstall()
    {
        if (_thread != null && _threadId != 0)
        {
            PostThreadMessage(_threadId, 0x0012, IntPtr.Zero, IntPtr.Zero);
            if (!_thread.Join(2000)) _thread.Abort();
            _thread = null;
        }
    }
}
"@ -ErrorAction SilentlyContinue

$baseUrl = "https://127.0.0.1:2999/liveclientdata"
$dataUrl = "$baseUrl/allgamedata"

$baseCD = @{
    "Teleport" = 360; "Flash" = 300; "Clarity" = 240; "Cleanse" = 240; "Exhaust" = 240
    "Ghost" = 240; "Heal" = 240; "Unleashed Teleport" = 240; "Barrier" = 180; "Ignite" = 180
    "Smite" = 90; "Hextech Flashtraption" = 20; "Mark" = 80; "Garrison" = 240
}

$bootsHaste = @{ 3158 = 10; 3171 = 20 }
$positionOrder = @("TOP", "JUNGLE", "MIDDLE", "BOTTOM", "UTILITY")
$posAbbrev = @{ "TOP" = "top"; "JUNGLE" = "jg"; "MIDDLE" = "mid"; "BOTTOM" = "ad"; "UTILITY" = "sp" }

$spellState = @{}
$customTimers = @{}
$cosmic = @{}
$eventLog = New-Object System.Collections.ArrayList
$playerHaste = @{}
$gameTime = 0
$enemyByName = @{}
$lastClip = ""

function Get-Json {
    param([string]$Uri)
    try {
        $raw = (& curl.exe -k -s -m 2 $Uri 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0) { return $null }
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Add-Event {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    $ts = Get-Date -Format "HH:mm:ss"
    [void]$eventLog.Add(@{ Text = "[$ts] $Text"; Color = $Color })
    if ($eventLog.Count -gt 12) { $eventLog.RemoveAt(0) }
}

function Format-CD {
    param([double]$Seconds)
    if ($Seconds -le 0) { return "READY" }
    $m = [math]::Floor($Seconds / 60)
    $s = [math]::Floor($Seconds % 60)
    return ("{0}:{1:00}" -f $m, $s)
}

function Get-Haste {
    param($Player)
    $h = 0
    foreach ($it in $Player.items) {
        if ($bootsHaste.ContainsKey([int]$it.itemID)) { $h += $bootsHaste[[int]$it.itemID] }
    }
    if ($cosmic[$Player.summonerName]) { $h += 18 }
    return $h
}

function Get-SpellCD {
    param([string]$Key, [double]$GameTime)
    if (-not $spellState.ContainsKey($Key)) { return -1 }
    $st = $spellState[$Key]
    $remaining = $st.readyTime - $GameTime
    if ($remaining -le 0 -and $st.wasOnCD) {
        $st.wasOnCD = $false
        Add-Event ("{0} is READY" -f $st.spellName) -Color Green
        Update-Clipboard
    }
    return $remaining
}

function Update-Clipboard {
    $items = @()
    foreach ($key in $spellState.Keys) {
        $st = $spellState[$key]
        if ($st.readyTime -gt $script:gameTime) {
            $name = $key.Split('|')[0]
            $p = $script:enemyByName[$name]
            if ($null -eq $p) { continue }
            $ab = $posAbbrev[$p.position]
            if ($null -eq $ab) { $ab = "?" }
            $m = [math]::Floor($st.readyTime / 60)
            $s = [math]::Floor($st.readyTime % 60)
            $items += [pscustomobject]@{ T = $st.readyTime; S = ("{0:00}{1:00}{2}" -f $m, $s, $ab) }
        }
    }
    foreach ($name in $customTimers.Keys) {
        $rt = $customTimers[$name]
        if ($rt -le $script:gameTime) { continue }
        $p = $script:enemyByName[$name]
        if ($null -eq $p) { continue }
        $ab = $posAbbrev[$p.position]
        if ($null -eq $ab) { $ab = "?" }
        $m = [math]::Floor($rt / 60)
        $s = $rt % 60
        $items += [pscustomobject]@{ T = $rt; S = ("{0:00}{1:00}{2}" -f $m, $s, $ab) }
    }
    $items = $items | Sort-Object T -Descending
    $text = ($items | ForEach-Object { $_.S }) -join ' '
    if ($text -ne $script:lastClip) {
        $script:lastClip = $text
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text + "`0")
        if ($bytes.Length -gt 4096) { $bytes = $bytes[0..4095] }
        if ($null -ne $script:mmf) {
            try {
                $view = $script:mmf.CreateViewAccessor()
                $view.WriteArray(0, $bytes, 0, $bytes.Length)
                $view.Dispose()
            } catch {
                try { [System.IO.File]::WriteAllText("C:\League spell timing helper\spell_timers.txt", $text) } catch { }
            }
        } else {
            try { [System.IO.File]::WriteAllText("C:\League spell timing helper\spell_timers.txt", $text) } catch { }
        }
    }
}

function Get-FlashSlot {
    param($Player)
    if ($Player.summonerSpells.summonerSpellOne.displayName -eq "Flash" -or $Player.summonerSpells.summonerSpellOne.displayName -eq "Hextech Flashtraption") { return 1 }
    if ($Player.summonerSpells.summonerSpellTwo.displayName -eq "Flash" -or $Player.summonerSpells.summonerSpellTwo.displayName -eq "Hextech Flashtraption") { return 2 }
    return 0
}

function Use-Spell {
    param($Player, [int]$SpellIdx, [double]$GameTime)
    $spell = if ($SpellIdx -eq 1) { $Player.summonerSpells.summonerSpellOne.displayName } else { $Player.summonerSpells.summonerSpellTwo.displayName }
    if ($spell -eq "Hextech Flashtraption") { $spell = "Flash" }
    $base = $baseCD[$spell]
    if ($null -eq $base) {
        Add-Event ("{0} used {1} (no base CD known)" -f $Player.summonerName, $spell) -Color DarkGray
        return
    }
    $key = "$($Player.summonerName)|$SpellIdx"
    if ($spellState.ContainsKey($key) -and $spellState[$key].readyTime -gt $GameTime) {
        $ready = $spellState[$key].readyTime - 10
        $spellState[$key] = @{ readyTime = $ready; wasOnCD = $true; spellName = $spell }
        Add-Event ("{0} {1} re-used - timer -10s, ready {2:00}:{3:00}" -f $Player.summonerName, $spell, [math]::Floor($ready / 60), ($ready % 60)) -Color Yellow
        Update-Clipboard
        return
    }
    if ($customTimers.ContainsKey($Player.summonerName)) {
        $crt = $customTimers[$Player.summonerName]
        if ($crt -gt $GameTime) {
            $crt -= 10
            $customTimers[$Player.summonerName] = $crt
            Add-Event ("{0} {1} re-used - timer -10s, ready {2:00}:{3:00}" -f $Player.summonerName, $spell, [math]::Floor($crt / 60), ($crt % 60)) -Color Yellow
            Update-Clipboard
            return
        }
        $customTimers.Remove($Player.summonerName)
    }
    $haste = Get-Haste $Player
    $bootsStr = ""
    foreach ($it in $Player.items) {
        if ($bootsHaste.ContainsKey([int]$it.itemID)) { $bootsStr += " $($it.displayName)" }
    }
    $script:playerHaste[$Player.summonerName] = @{ Haste = $haste; Boots = $bootsStr.Trim() }
    $total = $base / (1 + $haste / 100.0)
    $ready = $GameTime + $total
    $spellState["$($Player.summonerName)|$SpellIdx"] = @{ readyTime = $ready; wasOnCD = $true; spellName = $spell }
    Add-Event ("{0} used {1} - ready {2:00}:{3:00} (haste {4})" -f $Player.summonerName, $spell, [math]::Floor($ready / 60), ($ready % 60), $haste) -Color Yellow
    Update-Clipboard
}

Write-Host "=== ENEMY FLASH TRACKER ===" -ForegroundColor Cyan
Write-Host "Starting helper if needed..." -ForegroundColor DarkGray

$script:mmf = $null
try { $script:mmf = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateOrOpen("SpellTimersMMF", 4096) } catch { }

$helperProc = Get-Process spell_timer_helper -ErrorAction SilentlyContinue
if ($null -eq $helperProc) {
    try {
        Start-Process -FilePath "C:\League spell timing helper\spell_timer_helper.exe" -WorkingDirectory "C:\League spell timing helper"
        Add-Event "Helper started." -Color Green
    } catch {
        Add-Event "Failed to start helper." -Color Red
    }
} else {
    Add-Event "Helper already running (pid $($helperProc.Id))."
}

$data = Get-Json $dataUrl
if ($null -eq $data) {
    Write-Host "No live game detected. Waiting for game to start..." -ForegroundColor Yellow
    Write-Host "Press Q to quit." -ForegroundColor DarkGray
    Add-Event "No live game detected. Waiting for game to start..."
    while ($null -eq $data) {
        try {
            if ([Console]::KeyAvailable) {
                $ki = [Console]::ReadKey($true)
                if ($ki.KeyChar -eq 'q') {
                    try { Stop-Process -Name spell_timer_helper -Force -ErrorAction SilentlyContinue } catch { }
                    exit
                }
            }
        } catch { }
        Start-Sleep -Milliseconds 500
        $data = Get-Json $dataUrl
    }
    Write-Host "Game detected." -ForegroundColor Green
    Add-Event "Game detected."
    } else {
        Add-Event "Game already running."
    }
    [ChatHook]::Install()
    Add-Event "Chat hook installed (Enter, digit, Enter in game chat)."

$script:lastClip = $null
try { [System.IO.File]::WriteAllText("C:\League spell timing helper\spell_timers.txt", "") } catch { }
if ($null -ne $script:mmf) {
    try {
        $view = $script:mmf.CreateViewAccessor()
        $view.WriteArray(0, [byte[]]([System.Text.Encoding]::UTF8.GetBytes("`0")), 0, 1)
        $view.Dispose()
    } catch { }
}

$waiting = $false
$misses = 0
while ($true) {
    $data = Get-Json $dataUrl
    if ($null -eq $data) {
        $misses++
        if (-not $waiting) {
            $waiting = $true
            Add-Event "Waiting for game data..."
            try { Clear-Host } catch { }
            Write-Host "=== ENEMY FLASH TRACKER ===" -ForegroundColor Cyan
            Write-Host "No live game data. Waiting for a game..." -ForegroundColor Yellow
            Write-Host "Press Q to quit." -ForegroundColor DarkGray
        } elseif ($misses -ge 10) {
            $spellState.Clear()
            $customTimers.Clear()
            $misses = 0
        }
        try {
            if ([Console]::KeyAvailable) {
                $ki = [Console]::ReadKey($true)
                if ($ki.KeyChar -eq 'q') {
                    [ChatHook]::Uninstall()
                    break
                }
            }
        } catch { }
        Start-Sleep -Seconds 1
        continue
    }
    $waiting = $false

    $mainName = $data.activePlayer.summonerName
    $myTeam = ($data.allPlayers | Where-Object { $_.summonerName -eq $mainName }).team
    $enemies = @($data.allPlayers | Where-Object { $_.team -ne $myTeam -and $_.summonerName -ne $mainName } | Sort-Object { $positionOrder.IndexOf($_.position) })

    $script:gameTime = $data.gameData.gameTime
    $script:enemyByName = @{}
    foreach ($e in $enemies) { $script:enemyByName[$e.summonerName] = $e }
    Update-Clipboard

    $input = ""
    while ([ChatHook]::Events.TryDequeue([ref]$input)) {
        foreach ($tok in ($input -split '\s+')) {
            if ($tok -eq "") { continue }
            if ($tok -match '^[1-5]$') {
                $idx = [int]$tok - 1
                if ($idx -lt $enemies.Count) {
                    $p = $enemies[$idx]
                    $flashSlot = Get-FlashSlot $p
                    if ($flashSlot -gt 0) { Use-Spell -Player $p -SpellIdx $flashSlot -GameTime $data.gameData.gameTime }
                    else { Add-Event ("{0} has no Flash" -f $p.summonerName) -Color DarkGray }
                }
            } elseif ($tok -match '^([1-5])\1\1$') {
                $idx = [int]$Matches[1] - 1
                if ($idx -lt $enemies.Count) {
                    $p = $enemies[$idx]
                    $cosmic[$p.summonerName] = -not $cosmic[$p.summonerName]
                    $haste = Get-Haste $p
                    $bootsStr = ""
                    foreach ($it in $p.items) { if ($bootsHaste.ContainsKey([int]$it.itemID)) { $bootsStr += " $($it.displayName)" } }
                    $playerHaste[$p.summonerName] = @{ Haste = $haste; Boots = $bootsStr.Trim() }
                    Add-Event ("{0} Cosmic Insight: {1} (total haste {2})" -f $p.summonerName, $(if ($cosmic[$p.summonerName]) { "ON" } else { "OFF" }), $haste) -Color Magenta
                }
            } elseif ($tok -match '^([1-5])\1$') {
                $idx = [int]$Matches[1] - 1
                if ($idx -lt $enemies.Count) {
                    $p = $enemies[$idx]
                    $flashSlot = Get-FlashSlot $p
                    $cleared = $false
                    if ($flashSlot -gt 0) {
                        $key = "$($p.summonerName)|$flashSlot"
                        if ($spellState.ContainsKey($key)) {
                            $spellState.Remove($key)
                            Add-Event ("{0} Flash timer cleared" -f $p.summonerName) -Color Cyan
                            $cleared = $true
                        }
                    }
                    if ($customTimers.ContainsKey($p.summonerName)) {
                        $customTimers.Remove($p.summonerName)
                        Add-Event ("{0} custom timer cleared" -f $p.summonerName) -Color Cyan
                        $cleared = $true
                    }
                    if ($cleared) { Update-Clipboard }
                }
            } elseif ($tok -match '^(\d{4})(top|jg|mid|ad|sp)$') {
                $utime = [int]$Matches[1]
                $um = [math]::Floor($utime / 100)
                $us = $utime % 100
                $ab = $Matches[2].ToLower()
                if ($um -gt 59 -or $us -gt 59) {
                    Add-Event ("Invalid use time: {0}" -f $tok) -Color DarkGray
                } else {
                    $p = $enemies | Where-Object { $posAbbrev[$_.position] -eq $ab } | Select-Object -First 1
                    if ($null -eq $p) {
                        Add-Event ("No {0} enemy found" -f $ab) -Color DarkGray
                    } else {
                        $flashSlot = Get-FlashSlot $p
                        if ($flashSlot -gt 0) {
                            $key = "$($p.summonerName)|$flashSlot"
                            if ($spellState.ContainsKey($key)) { $spellState.Remove($key) }
                        }
                        $useTime = $um * 60 + $us
                        $haste = Get-Haste $p
                        $total = 300 / (1 + $haste / 100.0)
                        $ready = $useTime + $total
                        $customTimers[$p.summonerName] = $ready
                        Add-Event ("{0} Flash used at {1:00}:{2:00} - ready {3:00}:{4:00} (haste {5})" -f $p.summonerName, $um, $us, [math]::Floor($ready / 60), ($ready % 60), $haste) -Color Cyan
                        Update-Clipboard
                    }
                }
            } elseif ($tok -match '^([1-5])(\d{4})$') {
                $idx = [int]$Matches[1] - 1
                $ctime = [int]$Matches[2]
                $cm = [math]::Floor($ctime / 100)
                $cs = $ctime % 100
                if ($idx -lt $enemies.Count -and $cm -le 59 -and $cs -le 59) {
                    $p = $enemies[$idx]
                    $flashSlot = Get-FlashSlot $p
                    if ($flashSlot -gt 0) {
                        $key = "$($p.summonerName)|$flashSlot"
                        if ($spellState.ContainsKey($key)) { $spellState.Remove($key) }
                    }
                    $customTimers[$p.summonerName] = $cm * 60 + $cs
                    Add-Event ("{0} Flash timer set manually: ready {1:00}:{2:00}" -f $p.summonerName, $cm, $cs) -Color Cyan
                    Update-Clipboard
                } else {
                    Add-Event ("Invalid custom timer: {0}" -f $tok) -Color DarkGray
                }
            }
        }
    }

    try {
        if ([Console]::KeyAvailable) {
            $ki = [Console]::ReadKey($true)
            $key = $ki.KeyChar
            $vk = [int]$ki.Key
            if ($key -eq 'q') {
                [ChatHook]::Uninstall()
                break
            } elseif ($vk -ge 49 -and $vk -le 53) {
                $idx = $vk - 49
                if ($idx -lt $enemies.Count) {
                    $p = $enemies[$idx]
                    $flashSlot = Get-FlashSlot $p
                    if ($flashSlot -gt 0) { Use-Spell -Player $p -SpellIdx $flashSlot -GameTime $data.gameData.gameTime }
                    else { Add-Event ("{0} has no Flash" -f $p.summonerName) -Color DarkGray }
                }
            }
        }
    } catch { }

    try { Clear-Host } catch { }
    $gt = $data.gameData.gameTime
    Write-Host ("=== ENEMY FLASH TRACKER ===  time {0:0}:{1:00}" -f [math]::Floor($gt / 60), ($gt % 60)) -ForegroundColor Cyan
    Write-Host ("keys: 1-5 = enemy Flash, 11 = clear, 555 = cosmic (support), 12158 = manual ready (pos+MMSS), 1208ad = use time (auto CD), multi: 1208ad 1512jg, Q = quit  |  in-game: Ctrl+Shift+V = type+copy+send, Ctrl+V = paste+send, or Enter, digit(s), Enter  |  output: spell_timers.txt") -ForegroundColor DarkGray
    Write-Host ""
    Write-Host ("{0,-3} {1,-8} {2,-14} {3,-24} {4}" -f "#", "POS", "CHAMP", "FLASH", "HASTE") -ForegroundColor DarkGray
    for ($i = 0; $i -lt $enemies.Count; $i++) {
        $p = $enemies[$i]
        $snap = $playerHaste[$p.summonerName]
        $haste = if ($null -ne $snap) { $snap.Haste } else { -1 }
        $flashSlot = Get-FlashSlot $p
        $cd = if ($flashSlot -gt 0) { Get-SpellCD -Key "$($p.summonerName)|$flashSlot" -GameTime $gameTime } else { -1 }
        $d = if ($cd -lt 0) { "-" } else { "Flash {0}" -f (Format-CD $cd) }
        if ($customTimers.ContainsKey($p.summonerName)) {
            $crt = $customTimers[$p.summonerName]
            $remaining = $crt - $gameTime
            if ($remaining -le 0) {
                $custStr = "Flash READY"
            } else {
                $custStr = "Flash {0}" -f (Format-CD $remaining)
            }
            $d = if ($d -eq "-") { $custStr } else { "$d  $custStr" }
        }
        $c = if ($cd -gt 0) { "Yellow" } else { "Green" }
        $hStr = if ($haste -lt 0) { "-" } else { $haste }
        $boots = if ($null -ne $snap) { $snap.Boots } else { "" }
        $ciStr = if ($cosmic[$p.summonerName]) { " +CI" } else { "" }
        Write-Host ("{0,-3} {1,-8} {2,-14} " -f ($i + 1), $p.position, $p.championName) -NoNewline -ForegroundColor White
        Write-Host ("{0,-24} " -f $d) -NoNewline -ForegroundColor $c
        Write-Host ("{0}" -f $hStr) -NoNewline -ForegroundColor DarkGray
        if ($ciStr) { Write-Host $ciStr -NoNewline -ForegroundColor Magenta }
        if ($boots) { Write-Host ("  [{0}]" -f $boots) -ForegroundColor DarkGray } else { Write-Host "" }
    }
    Write-Host ""
    Write-Host "--- recent events ---" -ForegroundColor DarkGray
    foreach ($e in $eventLog) { Write-Host $e.Text -ForegroundColor $e.Color }

    [ChatHook]::EventsSignal.WaitOne($IntervalMs) | Out-Null
}

try { Stop-Process -Name spell_timer_helper -Force -ErrorAction SilentlyContinue } catch { }