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
    private static int _cursor = 0;
    private static bool _ctrlDown = false;
    private static bool _altDown = false;
    private static EventWaitHandle _typingFlag;

    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;
    private const int VK_BACK = 0x08;
    private const int VK_TAB = 0x09;
    private const int VK_SHIFT = 0x10;
    private const int VK_CONTROL = 0x11;
    private const int VK_MENU = 0x12;
    private const int VK_CAPITAL = 0x14;
    private const int VK_RETURN = 0x0D;
    private const int VK_ESCAPE = 0x1B;
    private const int VK_PRIOR = 0x21;
    private const int VK_NEXT = 0x22;
    private const int VK_END = 0x23;
    private const int VK_HOME = 0x24;
    private const int VK_LEFT = 0x25;
    private const int VK_UP = 0x26;
    private const int VK_RIGHT = 0x27;
    private const int VK_DOWN = 0x28;
    private const int VK_DELETE = 0x2E;
    private const int VK_LSHIFT = 0xA0;
    private const int VK_RSHIFT = 0xA1;
    private const int VK_LCONTROL = 0xA2;
    private const int VK_RCONTROL = 0xA3;
    private const int VK_LMENU = 0xA4;
    private const int VK_RMENU = 0xA5;
    private const int VK_LWIN = 0x5B;
    private const int VK_RWIN = 0x5C;

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

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool QueryFullProcessImageName(IntPtr hProcess, uint dwFlags, System.Text.StringBuilder lpExeName, ref uint lpdwSize);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr hObject);

    private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

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
        if (pid == 0) return false;
        IntPtr proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (proc == IntPtr.Zero) return false;
        try
        {
            System.Text.StringBuilder sb = new System.Text.StringBuilder(260);
            uint size = 260;
            if (!QueryFullProcessImageName(proc, 0, sb, ref size)) return false;
            return sb.ToString().EndsWith("League of Legends.exe", StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            CloseHandle(proc);
        }
    }

    private static void ResetInput()
    {
        _pending.Length = 0;
        _cursor = 0;
    }

    private static bool IsModifier(int vk)
    {
        return vk == VK_SHIFT || vk == VK_CONTROL || vk == VK_MENU
            || vk == VK_LSHIFT || vk == VK_RSHIFT || vk == VK_LCONTROL
            || vk == VK_RCONTROL || vk == VK_LMENU || vk == VK_RMENU
            || vk == VK_LWIN || vk == VK_RWIN;
    }

    private static bool IsNonText(int vk)
    {
        if (vk >= 0x70 && vk <= 0x87) { return true; } // F1-F24
        if (vk >= 0x21 && vk <= 0x28) { return true; } // pgup pgdn end home arrows
        switch (vk)
        {
            case VK_TAB: case VK_CAPITAL:
            case 0x13: case 0x2C: case 0x5D: case 0x5F:
            case 0x90: case 0x91:
                return true;
        }
        return false;
    }

    private static char MapChar(int vk)
    {
        if (vk >= 0x31 && vk <= 0x39) { return (char)vk; }
        if (vk == 0x30) { return '0'; }
        if (vk >= 0x60 && vk <= 0x69) { return (char)(vk - 0x30); }
        if (vk >= 0x41 && vk <= 0x5A) { return (char)vk; }
        if (vk == 0x20) { return ' '; }
        return '\0';
    }

    private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < 0) { return CallNextHookEx(_hook, nCode, wParam, lParam); }

        int msg = wParam.ToInt32();
        KBDLLHOOKSTRUCT k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
        int vk = (int)k.vkCode;

        if (msg == WM_KEYUP || msg == WM_SYSKEYUP)
        {
            if (vk == VK_CONTROL || vk == VK_LCONTROL || vk == VK_RCONTROL) { _ctrlDown = false; }
            if (vk == VK_MENU || vk == VK_LMENU || vk == VK_RMENU) { _altDown = false; }
            return CallNextHookEx(_hook, nCode, wParam, lParam);
        }

        if (msg != WM_KEYDOWN && msg != WM_SYSKEYDOWN) { return CallNextHookEx(_hook, nCode, wParam, lParam); }

        if (_typingFlag != null && _typingFlag.WaitOne(0)) { return CallNextHookEx(_hook, nCode, wParam, lParam); }

        if (vk == VK_CONTROL || vk == VK_LCONTROL || vk == VK_RCONTROL) { _ctrlDown = true; return CallNextHookEx(_hook, nCode, wParam, lParam); }
        if (vk == VK_MENU || vk == VK_LMENU || vk == VK_RMENU) { _altDown = true; return CallNextHookEx(_hook, nCode, wParam, lParam); }
        if (IsModifier(vk)) { return CallNextHookEx(_hook, nCode, wParam, lParam); }

        if (!IsGameFocused())
        {
            if (vk == VK_RETURN || vk == VK_ESCAPE)
            {
                _chatOpen = false;
                ResetInput();
            }
            return CallNextHookEx(_hook, nCode, wParam, lParam);
        }

        if (vk == VK_RETURN || vk == VK_ESCAPE)
        {
            if (_chatOpen)
            {
                if (_pending.Length > 0)
                {
                    Events.Enqueue(_pending.ToString());
                    EventsSignal.Set();
                }
                ResetInput();
                _chatOpen = false;
            }
            else if (vk == VK_RETURN)
            {
                _chatOpen = true;
                ResetInput();
            }
            return CallNextHookEx(_hook, nCode, wParam, lParam);
        }

        if (!_chatOpen) { return CallNextHookEx(_hook, nCode, wParam, lParam); }

        if (_ctrlDown || _altDown) { return CallNextHookEx(_hook, nCode, wParam, lParam); }

        switch (vk)
        {
            case VK_BACK:
                if (_cursor > 0) { _pending.Remove(_cursor - 1, 1); _cursor--; }
                return CallNextHookEx(_hook, nCode, wParam, lParam);
            case VK_DELETE:
                if (_cursor < _pending.Length) { _pending.Remove(_cursor, 1); }
                return CallNextHookEx(_hook, nCode, wParam, lParam);
            case VK_LEFT:
                if (_cursor > 0) { _cursor--; }
                return CallNextHookEx(_hook, nCode, wParam, lParam);
            case VK_RIGHT:
                if (_cursor < _pending.Length) { _cursor++; }
                return CallNextHookEx(_hook, nCode, wParam, lParam);
            case VK_HOME:
                _cursor = 0;
                return CallNextHookEx(_hook, nCode, wParam, lParam);
            case VK_END:
                _cursor = _pending.Length;
                return CallNextHookEx(_hook, nCode, wParam, lParam);
        }

        if (IsNonText(vk)) { return CallNextHookEx(_hook, nCode, wParam, lParam); }

        char c = MapChar(vk);
        if (c == '\0') { c = '?'; } // unmapped printable key poisons the line so it can't parse as a command
        if (_cursor < 0) { _cursor = 0; }
        if (_cursor > _pending.Length) { _cursor = _pending.Length; }
        _pending.Insert(_cursor, c);
        _cursor++;
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
    $resp = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($Uri)
        $req.Timeout = 1500
        $req.ReadWriteTimeout = 1500
        $req.KeepAlive = $true
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $raw = $sr.ReadToEnd()
        $sr.Close()
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch {
        return $null
    } finally {
        if ($null -ne $resp) { $resp.Close() }
    }
}

function Add-Event {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    $ts = Get-Date -Format "HH:mm:ss"
    [void]$eventLog.Add(@{ Text = "[$ts] $Text"; Color = $Color })
    if ($eventLog.Count -gt 12) { $eventLog.RemoveAt(0) }
    try { [System.IO.File]::AppendAllText("C:\League spell timing helper\listener.log", "[$ts] $Text`r`n") } catch { }
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
    if ($Player.summonerSpells.summonerSpellOne.displayName -match 'flash') { return 1 }
    if ($Player.summonerSpells.summonerSpellTwo.displayName -match 'flash') { return 2 }
    return 0
}

function Use-Spell {
    param($Player, [int]$SpellIdx, [double]$GameTime)
    $spell = if ($SpellIdx -eq 1) { $Player.summonerSpells.summonerSpellOne.displayName } else { $Player.summonerSpells.summonerSpellTwo.displayName }
    if ($spell -match 'flash') { $spell = "Flash" }
    $base = $baseCD[$spell]
    if ($null -eq $base) {
        Add-Event ("{0} used {1} (no base CD known)" -f $Player.summonerName, $spell) -Color DarkGray
        return
    }
    $key = "$($Player.summonerName)|$SpellIdx"
    if ($spellState.ContainsKey($key) -and $spellState[$key].readyTime -gt $GameTime) {
        $st = $spellState[$key]
        $st.readyTime = $st.readyTime - 10
        $st.wasOnCD = $true
        $ready = $st.readyTime
        Add-Event ("{0} {1} re-used - timer -10s, ready {2:00}:{3:00}" -f $Player.summonerName, $spell, [math]::Floor($ready / 60), ($ready % 60)) -Color Yellow
        Update-Clipboard
        return
    }
    if ($customTimers.ContainsKey($Player.summonerName)) {
        $crt = $customTimers[$Player.summonerName]
        if ($crt -gt $GameTime) {
            Add-Event ("{0} custom timer (ready {1:00}:{2:00}) overrides record" -f $Player.summonerName, [math]::Floor($crt / 60), ($crt % 60)) -Color DarkGray
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
    $ciAtCast = [bool]$cosmic[$Player.summonerName]
    $ciHaste = if ($ciAtCast) { 18 } else { 0 }
    $total = $base / (1 + $haste / 100.0)
    $ready = $GameTime + $total
    $spellState["$($Player.summonerName)|$SpellIdx"] = @{ readyTime = $ready; wasOnCD = $true; spellName = $spell; hasteExCI = $haste - $ciHaste; ci = $ciAtCast }
    Add-Event ("{0} used {1} - ready {2:00}:{3:00} (haste {4})" -f $Player.summonerName, $spell, [math]::Floor($ready / 60), ($ready % 60), $haste) -Color Yellow
    Update-Clipboard
}

function Process-Token([string]$tok) {
    if ($tok -match '^[1-5]$') {
        $idx = [int]$tok - 1
        if ($idx -lt $enemies.Count) {
            $p = $enemies[$idx]
            $flashSlot = Get-FlashSlot $p
            if ($flashSlot -gt 0) { Use-Spell -Player $p -SpellIdx $flashSlot -GameTime $data.gameData.gameTime }
            else { Add-Event ("{0} has no Flash" -f $p.summonerName) -Color DarkGray }
        }
    } elseif ($tok -match '^(top|jg|mid|ad|sp)$') {
        $ab = $Matches[1].ToLower()
        $p = $enemies | Where-Object { $posAbbrev[$_.position] -eq $ab } | Select-Object -First 1
        if ($null -eq $p) {
            Add-Event ("No {0} enemy found" -f $ab) -Color DarkGray
        } else {
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
            $adjustStr = ""
            $flashSlot = Get-FlashSlot $p
            if ($flashSlot -gt 0) {
                $key = "$($p.summonerName)|$flashSlot"
                if ($spellState.ContainsKey($key) -and $spellState[$key].readyTime -gt $script:gameTime) {
                    $st = $spellState[$key]
                    $base = $baseCD[$st.spellName]
                    if ($null -ne $base -and $null -ne $st.hasteExCI) {
                        $newCi = [bool]$cosmic[$p.summonerName]
                        $oldCi = if ($st.ci) { 18 } else { 0 }
                        $newCiH = if ($newCi) { 18 } else { 0 }
                        $oldTotal = $base / (1 + ($st.hasteExCI + $oldCi) / 100.0)
                        $newTotal = $base / (1 + ($st.hasteExCI + $newCiH) / 100.0)
                        $st.readyTime = $st.readyTime - ($oldTotal - $newTotal)
                        $st.ci = $newCi
                        $adjustStr = " - timer adjusted to ready {0:00}:{1:00}" -f [math]::Floor($st.readyTime / 60), ($st.readyTime % 60)
                        Update-Clipboard
                    }
                }
            }
            Add-Event ("{0} Cosmic Insight: {1} (total haste {2}){3}" -f $p.summonerName, $(if ($cosmic[$p.summonerName]) { "ON" } else { "OFF" }), $haste, $adjustStr) -Color Magenta
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
    } else {
        Add-Event ("Unrecognized input: {0}" -f $tok) -Color DarkGray
    }
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
function Test-Token([string]$tok) {
    return ($tok -match '^[1-5]$' -or $tok -match '^(top|jg|mid|ad|sp)$' -or $tok -match '^([1-5])\1\1$' -or $tok -match '^([1-5])\1$' -or $tok -match '^(\d{4})(top|jg|mid|ad|sp)$' -or $tok -match '^([1-5])(\d{4})$')
}

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
    $expired = @($customTimers.Keys | Where-Object { $customTimers[$_] -le $script:gameTime })
    foreach ($name in $expired) {
        $customTimers.Remove($name)
        Add-Event ("{0} custom timer expired" -f $name) -Color DarkGray
    }
    Update-Clipboard

    $input = ""
    while ([ChatHook]::Events.TryDequeue([ref]$input)) {
        $tokens = @($input -split '\s+' | Where-Object { $_ -ne "" })
        if ($tokens.Count -eq 0) { continue }
        $allValid = $true
        foreach ($tok in $tokens) {
            if (-not (Test-Token $tok)) { $allValid = $false; break }
        }
        if ($allValid) {
            foreach ($tok in $tokens) { Process-Token $tok }
        } else {
            Add-Event ("Ignored (not a command): {0}" -f $input) -Color DarkGray
        }
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

    try { Clear-Host } catch { }
    $gt = $data.gameData.gameTime
    Write-Host ("=== ENEMY FLASH TRACKER ===  time {0:0}:{1:00}" -f [math]::Floor($gt / 60), ($gt % 60)) -ForegroundColor Cyan
    Write-Host ("keys: 1-5 = enemy Flash, 11 = clear, 555 = cosmic (support), 12158 = manual ready (pos+MMSS), 1208ad = use time (auto CD), multi: 1208ad 1512jg, Q = quit  |  in-game: Ctrl+Shift+V = type+copy+send, Ctrl+V = paste+send, or Enter, digit(s), Enter/Esc  |  output: spell_timers.txt") -ForegroundColor DarkGray
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