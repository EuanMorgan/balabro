using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Threading;
using Xunit;

namespace Balabro.Windows.Tests;

/// Needs a built engine, so it runs only when `BALABRO_TEST_ENGINE` names one and `BALABRO_DATA_FOLDER` a throwaway
/// data folder. The tray's items are clicked in-process, and the folder picker and warning box are stood in for.
public sealed class NeedsRealEngineFact : FactAttribute
{
    public NeedsRealEngineFact()
    {
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("BALABRO_TEST_ENGINE")) || string.IsNullOrEmpty(Environment.GetEnvironmentVariable("BALABRO_DATA_FOLDER")))
            Skip = "Set BALABRO_TEST_ENGINE and BALABRO_DATA_FOLDER to run this against a built engine";
    }
}

public class SyncTrayTests
{
    private static void PumpUntil(Func<bool> done, string waitingFor)
    {
        var waited = Stopwatch.StartNew();
        while (!done())
        {
            if (waited.Elapsed > TimeSpan.FromMinutes(2)) throw new TimeoutException($"Waiting for {waitingFor}. Log:\n{Log()}");
            var frame = new DispatcherFrame();
            var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
            timer.Tick += (_, _) => { timer.Stop(); frame.Continue = false; };
            timer.Start();
            Dispatcher.PushFrame(frame);
        }
    }

    private static string Log() => File.Exists(Balabro.Windows.Log.FilePath)
        ? new StreamReader(new FileStream(Balabro.Windows.Log.FilePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)).ReadToEnd()
        : "";

    private static string[] EnginePids() => Regex.Matches(Log(), @"Started the engine, pid (\d+)").Select(m => m.Groups[1].Value).ToArray();

    private static int Lines(string text) => Regex.Matches(Log(), Regex.Escape(text)).Count;

    private static string? MachineSyncFolder()
    {
        using var saved = System.Text.Json.JsonDocument.Parse(File.ReadAllText(Path.Combine(Paths.DataFolder, "machine.json")));
        return saved.RootElement.GetProperty("syncFolder").GetString();
    }

    private static readonly FileSystemAccessRule NoWriting = new(
        WindowsIdentity.GetCurrent().User!,
        FileSystemRights.WriteData | FileSystemRights.AppendData | FileSystemRights.WriteExtendedAttributes | FileSystemRights.WriteAttributes,
        InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
        PropagationFlags.None,
        AccessControlType.Deny);

    private static void ChangeRule(string folder, Action<DirectorySecurity> change)
    {
        var info = new DirectoryInfo(folder);
        var security = info.GetAccessControl();
        change(security);
        info.SetAccessControl(security);
    }

    [NeedsRealEngineFact]
    public void TheTraySwitchesSyncingOnAndOff() => Wpf.Run(() =>
    {
        // Never the player's own data.
        var temp = Path.GetFullPath(Path.GetTempPath());
        Assert.StartsWith(temp, Path.GetFullPath(Paths.DataFolder), StringComparison.OrdinalIgnoreCase);

        var root = Path.Combine(temp, "balabro-sync-test-" + Guid.NewGuid().ToString("N"));
        var saves = Path.Combine(root, "saves");
        var syncing = Path.Combine(root, "sync-folder");
        var readOnly = Path.Combine(root, "read-only");
        Directory.CreateDirectory(saves);
        Directory.CreateDirectory(syncing);
        Directory.CreateDirectory(readOnly);
        // NTFS's read-only attribute doesn't stop a folder being written to. Only permissions do.

        var application = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var arguments = new[] { "--saves-root", saves };
        var engine = new EngineLink(Path.Combine(Environment.GetEnvironmentVariable("BALABRO_TEST_ENGINE")!, "balabro-engine.exe"), arguments);
        var shell = new Shell(arguments, engine, preview: true);
        string? picked = null;
        var warnings = new System.Collections.Generic.List<string>();
        shell.PickSyncFolder = _ => picked;
        shell.ShowWarning = warnings.Add;
        try
        {
            ChangeRule(readOnly, security => security.AddAccessRule(NoWriting));
            shell.Start();
            PumpUntil(() => shell.StatsItem.Available, "the first hello");
            Assert.False(shell.StopSyncingItem.Available);
            var pids = EnginePids().Length;
            var firstPid = EnginePids()[^1];

            // Switching on.
            picked = syncing;
            shell.SyncWithItem.PerformClick();
            PumpUntil(() => shell.StopSyncingItem.Available, "Stop syncing to appear");
            Assert.Contains($"Sync folder is now {syncing}", Log());
            Assert.Equal(pids + 1, EnginePids().Length);
            var syncingPid = EnginePids()[^1];
            Assert.NotEqual(firstPid, syncingPid);
            Assert.Equal("Syncing through sync-folder", shell.SyncingThroughItem.Text);
            Assert.True(shell.SyncingThroughItem.Available);
            Assert.Equal(syncing, MachineSyncFolder());
            Assert.True(Directory.Exists(Path.Combine(syncing, "Balabro")));
            Assert.Empty(warnings);

            // A read-only folder, while syncing: a warning, and a new engine still on the old folder.
            picked = readOnly;
            var pidsBefore = EnginePids().Length;
            var hellos = Lines($"syncing through {syncing}");
            shell.SyncWithItem.PerformClick();
            PumpUntil(() => warnings.Count > 0 && Lines($"syncing through {syncing}") > hellos, "the warning and the new engine's hello");
            Assert.StartsWith("Couldn't sync through that folder.", Assert.Single(warnings));
            Assert.Contains($"Sync folder is now {syncing}, because Couldn't sync through that folder.", Log());
            Assert.Equal(pidsBefore + 1, EnginePids().Length);
            Assert.NotEqual(syncingPid, EnginePids()[^1]);
            Assert.True(shell.StopSyncingItem.Available);
            Assert.Equal(syncing, MachineSyncFolder());
            Assert.False(Directory.Exists(Path.Combine(readOnly, "Balabro")));

            // Stopping.
            pidsBefore = EnginePids().Length;
            shell.StopSyncingItem.PerformClick();
            PumpUntil(() => !shell.StopSyncingItem.Available, "Stop syncing to go");
            Assert.Contains("Sync folder is now none", Log());
            Assert.Equal(pidsBefore + 1, EnginePids().Length);
            Assert.False(shell.SyncingThroughItem.Available);
            Assert.Null(MachineSyncFolder());

            // A read-only folder, while not syncing: a warning, and a new engine still not syncing.
            warnings.Clear();
            picked = readOnly;
            pidsBefore = EnginePids().Length;
            shell.SyncWithItem.PerformClick();
            PumpUntil(() => warnings.Count > 0 && EnginePids().Length > pidsBefore, "the second warning");
            Assert.Contains("Sync folder is now none, because Couldn't sync through that folder.", Log());
            PumpUntil(() => Lines("syncing through nothing") >= 3, "the new engine's hello");
            Assert.False(shell.StopSyncingItem.Available);
            Assert.Null(MachineSyncFolder());

            foreach (var pid in EnginePids()[..^1]) Assert.DoesNotContain(Process.GetProcessesByName("balabro-engine"), p => p.Id.ToString() == pid);
        }
        finally
        {
            shell.Dispose();
            application.Shutdown();
            ChangeRule(readOnly, security => security.RemoveAccessRule(NoWriting));
            Directory.Delete(root, true);
        }
    });
}
