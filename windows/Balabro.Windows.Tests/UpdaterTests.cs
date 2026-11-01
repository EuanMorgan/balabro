using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Balabro.Windows.Tests;

/// Plain functions on a throwaway folder under %TEMP%, with fake files. No test here starts a process.
public sealed class UpdaterTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "balabro-updater-test-" + Guid.NewGuid().ToString("N"));
    private string Install => Path.Combine(_root, "install");
    private string Package => Path.Combine(_root, "built", "Balabro-2.0.0-windows-x64");
    private readonly List<(string Executable, IReadOnlyList<string> Arguments)> _started = new();

    public UpdaterTests()
    {
        WriteFile(Install, "Balabro.exe", "old app");
        WriteFile(Install, "balabro-engine.exe", "old engine");
        WriteFile(Install, "version.txt", "1.0.0");
        WriteFile(Install, @"bot\main.lua", "old bot");
        WriteFile(Install, "a-file-of-the-players.txt", "theirs");
        WriteFile(Package, "Balabro.exe", "new app");
        WriteFile(Package, "balabro-engine.exe", "new engine");
        WriteFile(Package, "version.txt", "2.0.0");
        WriteFile(Package, @"bot\main.lua", "new bot");
        WriteFile(Package, @"bot\added.lua", "added");
    }

    public void Dispose() => Directory.Delete(_root, true);

    private static void WriteFile(string folder, string name, string text)
    {
        var path = Path.Combine(folder, name);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text);
    }

    private string Read(string name) => File.ReadAllText(Path.Combine(Install, name));

    private void AssertUntouched()
    {
        Assert.Equal("old app", Read("Balabro.exe"));
        Assert.Equal("old engine", Read("balabro-engine.exe"));
        Assert.Equal("old bot", Read(@"bot\main.lua"));
        Assert.Equal("theirs", Read("a-file-of-the-players.txt"));
        Assert.False(File.Exists(Path.Combine(Install, @"bot\added.lua")));
        Assert.Empty(Directory.GetFiles(Install, "*.old", SearchOption.AllDirectories));
    }

    [Fact]
    public void TheSwapRenamesWhatItReplacesAndCopiesTheNewFilesIn()
    {
        UpdateSwap.Apply(Package, Install);

        Assert.Equal("new app", Read("Balabro.exe"));
        Assert.Equal("old app", Read("Balabro.exe.old"));
        Assert.Equal("new engine", Read("balabro-engine.exe"));
        Assert.Equal("old engine", Read("balabro-engine.exe.old"));
        Assert.Equal("2.0.0", Read("version.txt"));
        Assert.Equal("new bot", Read(@"bot\main.lua"));
        Assert.Equal("old bot", Read(@"bot\main.lua.old"));
        Assert.Equal("added", Read(@"bot\added.lua"));
        Assert.False(File.Exists(Path.Combine(Install, @"bot\added.lua.old")));
        Assert.Equal("theirs", Read("a-file-of-the-players.txt"));
        Assert.False(File.Exists(Path.Combine(Install, "a-file-of-the-players.txt.old")));
    }

    [Fact]
    public void TheSwapReplacesAnOldFileAnEarlierUpdateLeft()
    {
        WriteFile(Install, "Balabro.exe.old", "older still");
        UpdateSwap.Apply(Package, Install);
        Assert.Equal("old app", Read("Balabro.exe.old"));
    }

    private static void AssertFileProblem(Exception? error) =>
        Assert.True(error is IOException or UnauthorizedAccessException, $"Got {error}");

    /// version.txt moves last, so the files before it have to come back.
    [Fact]
    public void AFileThatCantBeRenamedPutsEverythingBack()
    {
        Exception? error;
        using (new FileStream(Path.Combine(Install, "version.txt"), FileMode.Open, FileAccess.Read, FileShare.Read))
            error = Record.Exception(() => UpdateSwap.Apply(Package, Install));
        AssertFileProblem(error);
        AssertUntouched();
        Assert.Equal("1.0.0", Read("version.txt"));
    }

    [Fact]
    public void AFileThatCantBeCopiedPutsEverythingBack()
    {
        File.Delete(Path.Combine(Install, "version.txt"));
        Directory.CreateDirectory(Path.Combine(Install, "version.txt"));
        AssertFileProblem(Record.Exception(() => UpdateSwap.Apply(Package, Install)));
        AssertUntouched();
        Assert.True(Directory.Exists(Path.Combine(Install, "version.txt")));
    }

    [Fact]
    public void UndoPutsEverythingBack()
    {
        UpdateSwap.Apply(Package, Install).Undo();
        AssertUntouched();
        Assert.Equal("1.0.0", Read("version.txt"));
    }

    [Fact]
    public void ALaunchDeletesOldFilesAndNothingElse()
    {
        UpdateSwap.Apply(Package, Install);
        UpdateSwap.DeleteLeftovers(Install);
        Assert.Empty(Directory.GetFiles(Install, "*.old", SearchOption.AllDirectories));
        Assert.Equal("new app", Read("Balabro.exe"));
        Assert.Equal("new bot", Read(@"bot\main.lua"));
        Assert.Equal("theirs", Read("a-file-of-the-players.txt"));
    }

    [Fact]
    public void AnOldFileStillInUseWaitsForTheNextLaunch()
    {
        WriteFile(Install, "busy.old", "busy");
        WriteFile(Install, "free.old", "free");
        using (new FileStream(Path.Combine(Install, "busy.old"), FileMode.Open, FileAccess.Read, FileShare.Read))
            UpdateSwap.DeleteLeftovers(Install);
        Assert.True(File.Exists(Path.Combine(Install, "busy.old")));
        Assert.False(File.Exists(Path.Combine(Install, "free.old")));
        UpdateSwap.DeleteLeftovers(Install);
        Assert.False(File.Exists(Path.Combine(Install, "busy.old")));
    }

    private static readonly UpdateWords Words = new()
    {
        Available = "Version 2.0.0 is available",
        Update = "Update",
        Installing = "Updating to 2.0.0…",
        Failed = "Couldn't update",
        Download = "Download",
    };

    private static UpdateOffer Offer(string zip) => new("2.0.0", new Uri(zip).AbsoluteUri, "https://example.com/release", Words);

    private string Zip()
    {
        var zip = Path.Combine(_root, "release.zip");
        ZipFile.CreateFromDirectory(Package, zip, CompressionLevel.Fastest, true);
        return zip;
    }

    private Updater UpdaterWith(Action<string, IReadOnlyList<string>>? start = null) =>
        new(new UpdateSite(Install, new[] { "--saves-root", @"C:\My Saves\" }, start ?? ((executable, arguments) => _started.Add((executable, arguments)))));

    [Fact]
    public async Task InstallingStartsTheNewVersionAndAsksTheOldOneToExit()
    {
        var updater = UpdaterWith();
        updater.Offer(Offer(Zip()));
        Assert.True(await updater.Install());

        Assert.Equal("new app", Read("Balabro.exe"));
        var started = Assert.Single(_started);
        Assert.Equal(Path.Combine(Install, "Balabro.exe"), started.Executable);
        Assert.Equal(new[] { "--saves-root", @"C:\My Saves\", "--after-update" }, started.Arguments);
        Assert.Equal(UpdateStage.Installing, updater.State?.Stage);
    }

    [Fact]
    public async Task IfTheNewVersionWontStartTheOldFilesComeBack()
    {
        var updater = UpdaterWith((_, _) => throw new Win32Exception(5));
        updater.Offer(Offer(Zip()));
        Assert.False(await updater.Install());
        AssertUntouched();
        Assert.Equal(("Couldn't update", "Download"), (updater.State?.Message, updater.State?.Action));
        Assert.Equal("https://example.com/release", updater.State?.Offer.PageUrl);
    }

    [Fact]
    public async Task IfTheSwapFailsTheRowOffersTheDownloadAndNothingStarts()
    {
        var updater = UpdaterWith();
        updater.Offer(Offer(Zip()));
        bool installed;
        using (new FileStream(Path.Combine(Install, "version.txt"), FileMode.Open, FileAccess.Read, FileShare.Read))
            installed = await updater.Install();
        Assert.False(installed);
        Assert.Empty(_started);
        AssertUntouched();
        Assert.Equal(UpdateStage.Failed, updater.State?.Stage);
    }

    [Theory]
    [InlineData("9.9.9", null)]
    [InlineData("2.0.0", "balabro-engine.exe")]
    public async Task ADownloadThatIsAnotherVersionOrIsntWholeFails(string version, string? missing)
    {
        WriteFile(Package, "version.txt", version);
        if (missing is not null) File.Delete(Path.Combine(Package, missing));
        var updater = UpdaterWith();
        updater.Offer(Offer(Zip()));
        Assert.False(await updater.Install());
        Assert.Equal(UpdateStage.Failed, updater.State?.Stage);
        Assert.Empty(_started);
        AssertUntouched();
    }

    [Fact]
    public async Task AMissingDownloadFails()
    {
        var updater = UpdaterWith();
        updater.Offer(Offer(Path.Combine(_root, "not-there.zip")));
        Assert.False(await updater.Install());
        Assert.Equal("Couldn't update", updater.State?.Message);
    }

    [Fact]
    public async Task OnlyHttpsDownloads() =>
        await Assert.ThrowsAsync<NotSupportedException>(() => Updater.Download(new Uri("http://example.invalid/release.zip"), Path.Combine(_root, "release.zip")));

    [Fact]
    public void TheRowSaysWhatTheEngineSaid()
    {
        var updater = UpdaterWith();
        var changes = 0;
        updater.Changed += () => changes++;
        updater.Offer(Offer(@"C:\x.zip"));
        Assert.Equal(1, changes);
        Assert.Equal(("Version 2.0.0 is available", "Update"), (updater.State?.Message, updater.State?.Action));
        var installing = new UpdateState(updater.State!.Offer, UpdateStage.Installing);
        Assert.Equal("Updating to 2.0.0…", installing.Message);
        Assert.Null(installing.Action);
    }

    private static string MutexName() => @"Local\Balabro.Tests." + Guid.NewGuid().ToString("N");

    /// Holds the name on its own thread, as the old copy holds it in its own process, until told to let go.
    private static (Thread Holder, ManualResetEventSlim LetGo) Hold(string name)
    {
        var held = new ManualResetEventSlim();
        var letGo = new ManualResetEventSlim();
        var holder = new Thread(() =>
        {
            using var mutex = SingleCopy.Take(name, afterUpdate: false)!;
            held.Set();
            letGo.Wait();
            mutex.ReleaseMutex();
        });
        holder.Start();
        held.Wait();
        return (holder, letGo);
    }

    [Fact]
    public async Task ASecondCopyExitsAtOnce()
    {
        var name = MutexName();
        var (holder, letGo) = Hold(name);
        Assert.Null(await Task.Run(() => SingleCopy.Take(name, afterUpdate: false)).WaitAsync(TimeSpan.FromSeconds(5)));
        letGo.Set();
        holder.Join();
    }

    /// The old version is still running when it starts the new one, which would otherwise exit as a second copy.
    [Fact]
    public void AfterAnUpdateTheNewCopyWaitsForTheOldOneToExit()
    {
        var name = MutexName();
        var (holder, letGo) = Hold(name);
        using var finished = new ManualResetEventSlim();
        var got = false;
        var newCopy = new Thread(() =>
        {
            using var mutex = SingleCopy.Take(name, afterUpdate: true);
            got = mutex is not null;
            mutex?.ReleaseMutex();
            finished.Set();
        });
        newCopy.Start();
        Assert.False(finished.Wait(TimeSpan.FromMilliseconds(300)));
        letGo.Set();
        Assert.True(finished.Wait(TimeSpan.FromSeconds(5)));
        Assert.True(got);
        holder.Join();
        newCopy.Join();
    }

    [Fact]
    public void AfterAnUpdateAnOldCopyThatDiedStillCounts()
    {
        var name = MutexName();
        var dead = new Thread(() => _ = SingleCopy.Take(name, afterUpdate: false));
        dead.Start();
        dead.Join();
        using var mutex = SingleCopy.Take(name, afterUpdate: true);
        Assert.NotNull(mutex);
        mutex!.ReleaseMutex();
    }
}
