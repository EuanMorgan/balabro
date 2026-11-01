using System;

namespace Balabro.Windows;

/// Watches which window has the foreground. When the scorer's hidden game copy grabs it as it opens,
/// the guard hands it back to the window that had it, so the player's game keeps the keyboard.
/// Each change also re-asserts the panel's topmost place.
internal sealed class ForegroundGuard : IDisposable
{
    private readonly Native.WinEventDelegate _callback;
    private readonly IntPtr _hook;
    private readonly Func<bool> _copyMayHaveFocus;
    private readonly Action _onChange;
    private readonly bool _enabled;
    private IntPtr _last;

    /// `copyMayHaveFocus` is true while "play for me" runs, whose copy is meant to be seen.
    public ForegroundGuard(Func<bool> copyMayHaveFocus, Action onChange, bool enabled)
    {
        (_copyMayHaveFocus, _onChange, _enabled) = (copyMayHaveFocus, onChange, enabled);
        _callback = OnForeground;
        _hook = Native.SetWinEventHook(Native.EVENT_SYSTEM_FOREGROUND, Native.EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, _callback, 0, 0,
            Native.WINEVENT_OUTOFCONTEXT | Native.WINEVENT_SKIPOWNPROCESS);
        if (_hook == IntPtr.Zero) Log.Write("Couldn't watch the foreground window");
        _last = Native.GetForegroundWindow();
    }

    private void OnForeground(IntPtr hook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        if (hwnd == IntPtr.Zero) return;
        _onChange();
        if (!GameCapture.IsBalabroCopy(hwnd))
        {
            _last = hwnd;
            return;
        }
        if (!_enabled || _copyMayHaveFocus() || _last == IntPtr.Zero || !Native.IsWindow(_last)) return;
        var back = Native.ForceForeground(_last);
        Log.Write($"A game copy took the foreground; gave it back to \"{Native.WindowTitle(_last)}\": {(back ? "done" : "refused")}");
    }

    public void Dispose()
    {
        if (_hook != IntPtr.Zero) Native.UnhookWinEvent(_hook);
    }
}
