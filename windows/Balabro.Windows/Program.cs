using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace Balabro.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        // Before the single-copy check, so it works while the player has Balabro open.
        var render = Array.IndexOf(args, "--render-previews");
        if (render >= 0 && render + 1 < args.Length) return Previews.Render(args[render + 1], args);

        using var single = SingleCopy.Take(SingleCopy.Name, args.Contains(SingleCopy.AfterUpdateFlag));
        if (single is null)
        {
            Log.Write("Balabro is already running, so this copy exits");
            return 0;
        }
        UpdateSwap.DeleteLeftovers(AppContext.BaseDirectory);
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Write($"Crashed: {e.ExceptionObject}");
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.DispatcherUnhandledException += (_, e) =>
        {
            Log.Write($"Unhandled: {e.Exception}");
            e.Handled = true;
        };
        var shell = new Shell(args);
        app.Startup += (_, _) => shell.Start();
        app.Exit += (_, _) => shell.Dispose();
        return app.Run();
    }
}

/// Lets one Balabro run at a time.
internal static class SingleCopy
{
    public const string Name = @"Local\Balabro.Windows";
    public const string AfterUpdateFlag = "--after-update";

    /// Long enough for the old version to stop its engine, which takes up to 3 s.
    private static readonly TimeSpan OldCopyExit = TimeSpan.FromSeconds(30);

    /// Null if another copy has it. The update's old version starts its replacement before exiting, so
    /// `afterUpdate` gives that copy time to go.
    public static Mutex? Take(string name, bool afterUpdate)
    {
        var mutex = new Mutex(true, name, out var first);
        if (first) return mutex;
        if (afterUpdate)
        {
            try
            {
                if (mutex.WaitOne(OldCopyExit)) return mutex;
            }
            // The old copy was killed, or exited without letting go, either way leaving this one holding it.
            catch (AbandonedMutexException) { return mutex; }
        }
        mutex.Dispose();
        return null;
    }
}

/// Joins the panel, the engine, the tray icon and the foreground guard.
internal sealed class Shell : IDisposable
{
    private readonly EngineLink _engine;
    private readonly PanelWindow _panel;
    private readonly WindowPlacement _placement = new();
    private ForegroundGuard? _guard;
    private Forms.NotifyIcon? _tray;
    private string? _syncFolder;
    private readonly Forms.ToolStripMenuItem _syncingThrough = new() { Enabled = false, Visible = false };
    private readonly Forms.ToolStripMenuItem _stopSyncing = new("Stop syncing") { Visible = false };
    private readonly Forms.ToolStripMenuItem _stats = new() { Visible = false };
    private readonly Updater _updater;
    private readonly bool _preview;
    private StatsWindow? _statsWindow;
    private readonly Forms.ToolStripMenuItem _syncWith = new("Sync with another computer…");

    // The tray items and dialogs, for a test to drive with no dialog on the screen.
    internal Forms.ToolStripMenuItem SyncWithItem => _syncWith;
    internal Forms.ToolStripMenuItem SyncingThroughItem => _syncingThrough;
    internal Forms.ToolStripMenuItem StopSyncingItem => _stopSyncing;
    internal Forms.ToolStripMenuItem StatsItem => _stats;
    internal Func<string?, string?> PickSyncFolder { get; set; } = ShowFolderDialog;
    internal Action<string> ShowWarning { get; set; } = text => Forms.MessageBox.Show(text, "Balabro", Forms.MessageBoxButtons.OK, Forms.MessageBoxIcon.Warning);

    public Shell(string[] args)
        : this(args, new EngineLink(EngineArguments(args)), preview: false) { }

    internal Shell(string[] args, EngineLink engine, bool preview)
    {
        _engine = engine;
        _preview = preview;
        _panel = new PanelWindow(_engine.Send, preview);
        _updater = new Updater(new UpdateSite(AppContext.BaseDirectory, args.Where(a => a != SingleCopy.AfterUpdateFlag).ToList(), UpdateSite.StartProgram));
    }

    /// Only `--saves-root <path>` goes on to the engine.
    internal static string[] EngineArguments(string[] args)
    {
        var index = Array.IndexOf(args, "--saves-root");
        return index >= 0 && index + 1 < args.Length ? new[] { "--saves-root", args[index + 1] } : Array.Empty<string>();
    }

    public void Start()
    {
        Log.Write($"Balabro {Paths.Version} starting from {AppContext.BaseDirectory}");
        // A test's panel stays off the screen.
        if (_preview) (_panel.WindowStartupLocation, _panel.Left, _panel.Top) = (WindowStartupLocation.Manual, -4000, 0);
        else _placement.Restore(_panel);
        _panel.MovedOrResized += () => _placement.Save(_panel);
        _panel.Closing += (_, _) => _placement.Save(_panel);
        _panel.RestartEngine = () =>
        {
            _panel.ShowEngineProblem(null);
            _engine.Start();
        };
        _panel.InstallUpdate = async () =>
        {
            if (await _updater.Install()) Application.Current.Shutdown();
        };
        _panel.OpenPage = page => Process.Start(new ProcessStartInfo(page) { UseShellExecute = true });
        _updater.Changed += () => _panel.Show(_updater.State);
        _panel.Show();

        var dispatcher = _panel.Dispatcher;
        _engine.Received += message => dispatcher.BeginInvoke(() => Handle(message));
        _engine.Exited += code => dispatcher.BeginInvoke(() => _panel.ShowEngineProblem(code is null
            ? "Couldn't start balabro-engine.exe. It should be in the same folder as Balabro.exe."
            : "Balabro's engine stopped. The log is in the tray menu's logs folder."));
        _engine.Start();

        _guard = new ForegroundGuard(() => _panel.PilotIsActive, _panel.KeepOnTop);
        _tray = MakeTray();
    }

    private void Handle(HostMessage message)
    {
        switch (message)
        {
            case Hello hello:
                Log.Write($"Engine {hello.Version}, font {hello.FontPath ?? "none"}, syncing through {hello.SyncFolder ?? "nothing"}");
                Theme.LoadPixelFont(hello.FontPath);
                _syncFolder = hello.SyncFolder;
                _syncingThrough.Text = $"Syncing through {Path.GetFileName(Path.TrimEndingDirectorySeparator(hello.SyncFolder ?? ""))}";
                _syncingThrough.Visible = _stopSyncing.Visible = hello.SyncFolder is not null;
                _stats.Text = hello.StatsMenuTitle;
                _stats.Visible = true;
                break;
            // A new engine reads the runs from their new place, with nothing left from the old one.
            case SyncFolderSet set:
                Log.Write($"Sync folder is now {set.Path ?? "none"}{(set.Error is null ? "" : $", because {set.Error}")}");
                if (set.Error is not null) ShowWarning(set.Error);
                _engine.Start();
                break;
            case UpdateOffer offer:
                _updater.Offer(offer);
                break;
            case StatsMessage stats:
                _statsWindow?.Close();
                _statsWindow = new StatsWindow(stats.Page);
                _statsWindow.Show();
                _statsWindow.Activate();
                break;
            case CoachMessage coach:
                _panel.Show(coach.View);
                break;
            case PilotMessage pilot:
                _panel.Show(pilot.View);
                break;
            case CaptureRequest capture:
                ThreadPool.QueueUserWorkItem(_ =>
                {
                    byte[]? png = null;
                    try { png = GameCapture.CapturePng(); }
                    catch (Exception error) { Log.Write($"Screenshot failed: {error}"); }
                    _engine.Send(Wire.Screenshot(capture.Id, png));
                });
                break;
        }
    }

    private Forms.NotifyIcon MakeTray()
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add(new Forms.ToolStripMenuItem($"Balabro {Paths.Version}") { Enabled = false });
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Show overlay", null, (_, _) => ShowOverlay());
        menu.Items.Add("Move overlay to the corner", null, (_, _) =>
        {
            ShowOverlay();
            WindowPlacement.MoveToCorner(_panel);
            _placement.Save(_panel);
        });
        _stats.Click += (_, _) => _engine.Send(Wire.Stats());
        menu.Items.Add(_stats);
        menu.Items.Add(new Forms.ToolStripSeparator());
        _syncWith.Click += (_, _) =>
        {
            if (PickSyncFolder(_syncFolder) is { } folder) _engine.Send(Wire.SetSyncFolder(folder));
        };
        menu.Items.Add(_syncWith);
        menu.Items.Add(_syncingThrough);
        _stopSyncing.Click += (_, _) => _engine.Send(Wire.SetSyncFolder(null));
        menu.Items.Add(_stopSyncing);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Open logs folder", null, (_, _) =>
        {
            Directory.CreateDirectory(Paths.LogsFolder);
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{Paths.LogsFolder}\"") { UseShellExecute = true });
        });
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => Application.Current.Shutdown());

        var icon = Application.GetResourceStream(new Uri("pack://application:,,,/Balabro;component/spade.ico"))!.Stream;
        var tray = new Forms.NotifyIcon
        {
            Icon = new System.Drawing.Icon(icon, Forms.SystemInformation.SmallIconSize),
            Text = $"Balabro {Paths.Version}",
            ContextMenuStrip = menu,
            Visible = true,
        };
        tray.DoubleClick += (_, _) => ShowOverlay();
        return tray;
    }

    private static string? ShowFolderDialog(string? current)
    {
        var iCloudDrive = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "iCloudDrive");
        using var dialog = new Forms.FolderBrowserDialog
        {
            Description = "Choose a folder iCloud Drive, OneDrive or Dropbox keeps the same on your other computer",
            UseDescriptionForTitle = true,
            ShowNewFolderButton = true,
            InitialDirectory = current ?? (Directory.Exists(iCloudDrive) ? iCloudDrive : ""),
        };
        return dialog.ShowDialog() == Forms.DialogResult.OK ? dialog.SelectedPath : null;
    }

    private void ShowOverlay()
    {
        _panel.Show();
        if (!WindowPlacement.IsOnScreen(_panel)) WindowPlacement.MoveToCorner(_panel);
        _panel.KeepOnTop();
    }

    public void Dispose()
    {
        Log.Write("Balabro quitting");
        _placement.Save(_panel);
        _guard?.Dispose();
        if (_tray is not null)
        {
            _tray.Visible = false;
            _tray.Dispose();
        }
        _engine.Dispose();
    }
}

/// The panel's place and size, in `%LOCALAPPDATA%\Balabro\window.json`.
internal sealed class WindowPlacement
{
    private sealed record Saved(double Left, double Top, double Width, double Height);

    private static string FilePath => Path.Combine(Paths.DataFolder, "window.json");

    public void Restore(Window window)
    {
        try
        {
            if (File.Exists(FilePath) && JsonSerializer.Deserialize<Saved>(File.ReadAllText(FilePath)) is { } saved && saved.Width > 0 && saved.Height > 0)
            {
                (window.Left, window.Top, window.Width, window.Height) = (saved.Left, saved.Top, Math.Max(window.MinWidth, saved.Width), Math.Max(window.MinHeight, saved.Height));
                window.WindowStartupLocation = WindowStartupLocation.Manual;
                if (IsOnScreen(window)) return;
            }
        }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException)
        {
            Log.Write($"Couldn't read window.json: {error.Message}");
        }
        MoveToCorner(window);
    }

    public void Save(Window window)
    {
        if (double.IsNaN(window.Left) || double.IsNaN(window.Top)) return;
        try
        {
            Directory.CreateDirectory(Paths.DataFolder);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(new Saved(window.Left, window.Top, window.ActualWidth > 0 ? window.ActualWidth : window.Width, window.ActualHeight > 0 ? window.ActualHeight : window.Height)));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Log.Write($"Couldn't write window.json: {error.Message}");
        }
    }

    /// The top right of the primary screen's work area, inset as on the Mac.
    public static void MoveToCorner(Window window)
    {
        var area = SystemParameters.WorkArea;
        var width = window.ActualWidth > 0 ? window.ActualWidth : window.Width;
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = area.Right - width - 24;
        window.Top = area.Top + 24;
    }

    /// Whether the title row is somewhere the player can grab it.
    public static bool IsOnScreen(Window window)
    {
        var screen = new Rect(SystemParameters.VirtualScreenLeft, SystemParameters.VirtualScreenTop, SystemParameters.VirtualScreenWidth, SystemParameters.VirtualScreenHeight);
        var title = new Rect(window.Left, window.Top, Math.Max(1, window.Width), 30);
        return screen.IntersectsWith(title);
    }
}
