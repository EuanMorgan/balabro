using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Threading.Tasks;

namespace Balabro.Windows;

public enum UpdateStage { Available, Installing, Failed }

/// What the panel's update row shows. Its words come from the engine.
public sealed record UpdateState(UpdateOffer Offer, UpdateStage Stage)
{
    public string Message => Stage switch
    {
        UpdateStage.Available => Offer.Words.Available,
        UpdateStage.Installing => Offer.Words.Installing,
        _ => Offer.Words.Failed,
    };

    /// The button's title, if the row has one.
    public string? Action => Stage switch
    {
        UpdateStage.Available => Offer.Words.Update,
        UpdateStage.Failed => Offer.Words.Download,
        _ => null,
    };
}

/// Where the running app is, how it was started, and how to start a program. Tests pass a stand-in for the last.
internal sealed record UpdateSite(string InstallFolder, IReadOnlyList<string> Arguments, Action<string, IReadOnlyList<string>> Start)
{
    public static void StartProgram(string executable, IReadOnlyList<string> arguments)
    {
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(executable)! };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new IOException($"Couldn't start {executable}");
    }
}

/// Installs an `UpdateOffer` from inside the running app, as Sources/Balabro/Updater.swift does on the Mac. Restarting
/// mid-run is safe: a run's conversation only moves on a completed turn, so at worst the coach repeats the answer it was writing.
internal sealed class Updater
{
    private readonly UpdateSite _site;

    public UpdateState? State { get; private set; }

    public event Action? Changed;

    public Updater(UpdateSite site) => _site = site;

    public void Offer(UpdateOffer offer)
    {
        if (State?.Stage == UpdateStage.Installing) return;
        Set(new UpdateState(offer, UpdateStage.Available));
    }

    /// True when the new version is in place and started, so this process should exit.
    public async Task<bool> Install()
    {
        if (State is not { Stage: UpdateStage.Available, Offer: var offer }) return false;
        Set(new UpdateState(offer, UpdateStage.Installing));
        var temp = Path.Combine(Path.GetTempPath(), "balabro-update-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(temp);
            var zip = Path.Combine(temp, "release.zip");
            await Download(new Uri(offer.AssetUrl), zip);
            var swap = await Task.Run(() => UpdateSwap.Apply(Unpack(zip, Path.Combine(temp, "unpacked"), offer.Version), _site.InstallFolder));
            try
            {
                _site.Start(Path.Combine(_site.InstallFolder, "Balabro.exe"), _site.Arguments.Append(SingleCopy.AfterUpdateFlag).ToList());
            }
            catch (Exception error) when (error is Win32Exception or IOException or InvalidOperationException)
            {
                swap.Undo();
                throw new IOException("Couldn't start the new version", error);
            }
            return true;
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or IOException or InvalidDataException
            or UnauthorizedAccessException or UriFormatException or NotSupportedException)
        {
            Log.Write($"Update to {offer.Version} failed: {error}");
            Set(new UpdateState(offer, UpdateStage.Failed));
            return false;
        }
        finally
        {
            try { if (Directory.Exists(temp)) Directory.Delete(temp, true); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Log.Write($"Couldn't delete {temp}: {error.Message}"); }
        }
    }

    private void Set(UpdateState state)
    {
        State = state;
        Changed?.Invoke();
    }

    /// `file:` is only for checking this without publishing a release. The engine only offers GitHub's https addresses.
    internal static async Task Download(Uri from, string to)
    {
        if (from.IsFile)
        {
            File.Copy(from.LocalPath, to);
            return;
        }
        if (from.Scheme != Uri.UriSchemeHttps) throw new NotSupportedException($"Won't download from {from}");
        using var client = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Balabro");
        using var response = await client.GetAsync(from, HttpCompletionOption.ResponseHeadersRead);
        response.EnsureSuccessStatusCode();
        await using var file = File.Create(to);
        await response.Content.CopyToAsync(file);
    }

    /// Returns the folder holding the release's files. HTTPS from GitHub says who built them. This only shows that they
    /// arrived whole and are the version on offer, as the Mac's `isIntact` does for its bundle.
    internal static string Unpack(string zip, string into, string version)
    {
        ZipFile.ExtractToDirectory(zip, into);
        var package = Path.Combine(into, $"Balabro-{version}-windows-x64");
        foreach (var file in new[] { "Balabro.exe", "balabro-engine.exe", "version.txt" })
            if (!File.Exists(Path.Combine(package, file))) throw new InvalidDataException($"The download has no {file}");
        var found = File.ReadAllText(Path.Combine(package, "version.txt")).Trim();
        if (found != version) throw new InvalidDataException($"The download says it's version {found}, not {version}");
        return package;
    }
}

/// Puts a release's files into the install folder while the app runs from it. Windows lets a running exe or a loaded DLL
/// be renamed but not replaced, so each file the release replaces becomes `<name>.old`, which the next launch deletes.
/// Only files the release ships are touched, because the player may keep others in that folder.
internal sealed class UpdateSwap
{
    private const string OldSuffix = ".old";

    private readonly List<string> _renamed = new();
    private readonly List<string> _copied = new();

    private UpdateSwap() { }

    /// If anything fails, the install folder goes back as it was before this throws.
    public static UpdateSwap Apply(string package, string install)
    {
        var swap = new UpdateSwap();
        try
        {
            foreach (var file in Directory.EnumerateFiles(package, "*", SearchOption.AllDirectories).OrderBy(f => f, StringComparer.Ordinal))
            {
                var target = Path.Combine(install, Path.GetRelativePath(package, file));
                if (File.Exists(target))
                {
                    // Left by an update whose next launch couldn't delete it.
                    File.Delete(target + OldSuffix);
                    File.Move(target, target + OldSuffix);
                    swap._renamed.Add(target);
                }
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                // Listed first, because a copy that fails partway leaves part of a file to remove.
                swap._copied.Add(target);
                File.Copy(file, target);
            }
            return swap;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            swap.Undo();
            throw;
        }
    }

    /// Carries on past a file it can't put back, so one stuck file doesn't strand the rest.
    public void Undo()
    {
        foreach (var target in _copied)
        {
            if (Directory.Exists(target)) continue;
            Attempt(() => File.Delete(target), target);
        }
        foreach (var target in _renamed) Attempt(() => File.Move(target + OldSuffix, target, overwrite: true), target);
    }

    private static void Attempt(Action step, string file)
    {
        try { step(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Log.Write($"Couldn't put {file} back: {error.Message}"); }
    }

    /// What an update left behind. A file still in use stays for the launch after this one.
    public static void DeleteLeftovers(string install)
    {
        try
        {
            foreach (var old in Directory.EnumerateFiles(install, "*" + OldSuffix, SearchOption.AllDirectories))
            {
                try { File.Delete(old); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Log.Write($"Couldn't delete {old}: {error.Message}"); }
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Log.Write($"Couldn't look for old files: {error.Message}"); }
    }
}
