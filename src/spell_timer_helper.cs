using System;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Diagnostics;

class InterceptionPaste
{
    [DllImport("interception.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr interception_create_context();
    [DllImport("interception.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern void interception_destroy_context(IntPtr context);
    [DllImport("interception.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int interception_wait(IntPtr context);
    [DllImport("interception.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int interception_send(IntPtr context, int device, ref KeyStroke stroke, uint nstroke);
    [DllImport("interception.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int interception_send(IntPtr context, int device, ref MouseStroke stroke, uint nstroke);
    [DllImport("interception.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int interception_receive(IntPtr context, int device, ref KeyStroke stroke, uint nstroke);
    [DllImport("interception.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int interception_receive(IntPtr context, int device, ref MouseStroke stroke, uint nstroke);
    [DllImport("interception.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int interception_is_keyboard(int device);
    [DllImport("interception.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int interception_is_mouse(int device);
    [DllImport("interception.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern void interception_set_filter(IntPtr context, InterceptionPredicate predicate, ushort filter);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int InterceptionPredicate(int device);

    [StructLayout(LayoutKind.Sequential)]
    struct KeyStroke
    {
        public ushort code;
        public ushort state;
        public uint information;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct MouseStroke
    {
        public ushort state;
        public ushort flags;
        public short rolling;
        public int x;
        public int y;
        public uint information;
    }

    const ushort KEY_DOWN = 0x00;
    const ushort KEY_UP = 0x01;
    const ushort FILTER_KEY_DOWN = 0x01;
    const ushort FILTER_KEY_UP = 0x02;
    const ushort FILTER_MOUSE_ALL = 0xFFFF;

    const ushort SC_CTRL = 0x1D;
    const ushort SC_V = 0x2F;
    const ushort SC_A = 0x1E;
    const ushort SC_C = 0x2E;
    const ushort SC_LSHIFT = 0x2A;
    const ushort SC_RSHIFT = 0x36;
    const ushort SC_SPACE = 0x39;
    const ushort SC_ENTER = 0x1C;

    static bool ctrlDown = false;
    static bool shiftDown = false;
    static bool swallowV = false;

    static EventWaitHandle typingFlag = null;

    static string FilePath = @"C:\League spell timing helper\spell_timers.txt";

    [DllImport("user32.dll")]
    static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    static bool GameFocused()
    {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero) return false;
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        try
        {
            return Process.GetProcessById((int)pid).ProcessName == "League of Legends";
        }
        catch { return false; }
    }

    static int CharToScan(char c)
    {
        switch (c)
        {
            case 'a': return 0x1E; case 'b': return 0x30; case 'c': return 0x2E;
            case 'd': return 0x20; case 'e': return 0x12; case 'f': return 0x21;
            case 'g': return 0x22; case 'h': return 0x23; case 'i': return 0x17;
            case 'j': return 0x24; case 'k': return 0x25; case 'l': return 0x26;
            case 'm': return 0x32; case 'n': return 0x31; case 'o': return 0x18;
            case 'p': return 0x19; case 'q': return 0x10; case 'r': return 0x13;
            case 's': return 0x1F; case 't': return 0x14; case 'u': return 0x16;
            case 'v': return 0x2F; case 'w': return 0x11; case 'x': return 0x2D;
            case 'y': return 0x15; case 'z': return 0x2C;
            case '1': return 0x02; case '2': return 0x03; case '3': return 0x04;
            case '4': return 0x05; case '5': return 0x06; case '6': return 0x07;
            case '7': return 0x08; case '8': return 0x09; case '9': return 0x0A;
            case '0': return 0x0B;
            case ' ': return SC_SPACE;
            default: return -1;
        }
    }

    static void SendKey(IntPtr ctx, int device, ushort code, ushort state)
    {
        KeyStroke ks = new KeyStroke();
        ks.code = code;
        ks.state = state;
        interception_send(ctx, device, ref ks, 1);
    }

    static void TapKey(IntPtr ctx, int device, ushort code)
    {
        SendKey(ctx, device, code, KEY_DOWN);
        Thread.Sleep(10);
        SendKey(ctx, device, code, KEY_UP);
    }

    static void TypeText(IntPtr ctx, int device, string text)
    {
        foreach (char c in text)
        {
            int sc = CharToScan(c);
            if (sc < 0) continue;
            SendKey(ctx, device, (ushort)sc, KEY_DOWN);
            Thread.Sleep(3);
            SendKey(ctx, device, (ushort)sc, KEY_UP);
            Thread.Sleep(3);
        }
    }

    static void PressCtrlCombo(IntPtr ctx, int device, ushort key)
    {
        SendKey(ctx, device, SC_CTRL, KEY_DOWN);
        Thread.Sleep(10);
        SendKey(ctx, device, key, KEY_DOWN);
        Thread.Sleep(10);
        SendKey(ctx, device, key, KEY_UP);
        Thread.Sleep(10);
        SendKey(ctx, device, SC_CTRL, KEY_UP);
        Thread.Sleep(10);
    }

    static string ReadTimers()
    {
        try
        {
            using (var mmf = MemoryMappedFile.OpenExisting("SpellTimersMMF"))
            using (var view = mmf.CreateViewAccessor())
            {
                byte[] buf = new byte[4096];
                int n = view.ReadArray(0, buf, 0, buf.Length);
                int len = 0;
                while (len < n && buf[len] != 0) len++;
                return Encoding.UTF8.GetString(buf, 0, len);
            }
        }
        catch { }
        try { return File.ReadAllText(FilePath); } catch { return ""; }
    }

    static void DoTypeAndCopy(IntPtr ctx, int device)
    {
        string text = ReadTimers();
        TapKey(ctx, device, SC_ENTER);
        Thread.Sleep(100);
        TypeText(ctx, device, text);
        PressCtrlCombo(ctx, device, SC_A);
        PressCtrlCombo(ctx, device, SC_C);
        Thread.Sleep(30);
        TapKey(ctx, device, SC_ENTER);
    }

    static void DoPaste(IntPtr ctx, int device)
    {
        TapKey(ctx, device, SC_ENTER);
        Thread.Sleep(100);
        PressCtrlCombo(ctx, device, SC_V);
        Thread.Sleep(30);
        TapKey(ctx, device, SC_ENTER);
    }

    static bool FlagSet()
    {
        return typingFlag != null && typingFlag.WaitOne(0);
    }

    static void EnsureListener()
    {
        try
        {
            using (var searcher = new System.Management.ManagementObjectSearcher(
                "SELECT ProcessId FROM Win32_Process WHERE CommandLine LIKE '%spell_timer_listener.ps1%'"))
            {
                foreach (var o in searcher.Get())
                {
                    using (o) { return; }
                }
            }
        }
        catch { }
        try
        {
            Process.Start("powershell", "-NoExit -ExecutionPolicy Bypass -File \"C:\\League spell timing helper\\spell_timer_listener.ps1\"");
            Console.WriteLine("Listener started.");
        }
        catch { }
    }

    static void Main()
    {
        EnsureListener();
        try { typingFlag = new EventWaitHandle(false, EventResetMode.ManualReset, "SpellTimersTyping"); }
        catch { typingFlag = null; }
        IntPtr ctx = interception_create_context();
        if (ctx == IntPtr.Zero) { Console.WriteLine("Failed to create context"); return; }
        interception_set_filter(ctx, interception_is_keyboard, FILTER_KEY_DOWN | FILTER_KEY_UP);
        interception_set_filter(ctx, interception_is_mouse, FILTER_MOUSE_ALL);
        Console.WriteLine("League spell timing helper running. Ctrl+Shift+V = type+copy+send timers. Ctrl+V = paste+send. Mouse blocked during flow.");
        while (true)
        {
            int device = interception_wait(ctx);
            if (interception_is_keyboard(device) != 0)
            {
                KeyStroke stroke = new KeyStroke();
                if (interception_receive(ctx, device, ref stroke, 1) <= 0) continue;

                if (!GameFocused())
                {
                    ctrlDown = false;
                    shiftDown = false;
                    swallowV = false;
                    interception_send(ctx, device, ref stroke, 1);
                    continue;
                }

                if (stroke.code == SC_CTRL)
                {
                    ctrlDown = (stroke.state == KEY_DOWN);
                    interception_send(ctx, device, ref stroke, 1);
                }
                else if (stroke.code == SC_LSHIFT || stroke.code == SC_RSHIFT)
                {
                    shiftDown = (stroke.state == KEY_DOWN);
                    interception_send(ctx, device, ref stroke, 1);
                }
                else if (stroke.code == SC_V)
                {
                    if (stroke.state == KEY_DOWN)
                    {
                        if (ctrlDown && shiftDown)
                        {
                            swallowV = true;
                            SendKey(ctx, device, SC_CTRL, KEY_UP);
                            SendKey(ctx, device, SC_LSHIFT, KEY_UP);
                            SendKey(ctx, device, SC_RSHIFT, KEY_UP);
                            try
                            {
                                if (typingFlag != null) typingFlag.Set();
                                DoTypeAndCopy(ctx, device);
                            }
                            finally
                            {
                                if (typingFlag != null) typingFlag.Reset();
                            }
                        }
                        else if (ctrlDown)
                        {
                            swallowV = true;
                            SendKey(ctx, device, SC_CTRL, KEY_UP);
                            try
                            {
                                if (typingFlag != null) typingFlag.Set();
                                DoPaste(ctx, device);
                            }
                            finally
                            {
                                if (typingFlag != null) typingFlag.Reset();
                            }
                        }
                        else
                        {
                            interception_send(ctx, device, ref stroke, 1);
                        }
                    }
                    else if (swallowV)
                    {
                        swallowV = false;
                    }
                    else
                    {
                        interception_send(ctx, device, ref stroke, 1);
                    }
                }
                else
                {
                    interception_send(ctx, device, ref stroke, 1);
                }
            }
            else
            {
                MouseStroke ms = new MouseStroke();
                if (interception_receive(ctx, device, ref ms, 1) <= 0) continue;
                if (FlagSet())
                {
                    // swallow mouse input while the flow is running
                }
                else
                {
                    interception_send(ctx, device, ref ms, 1);
                }
            }
        }
    }
}