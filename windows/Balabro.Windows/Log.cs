using System;
using System.IO;

namespace Balabro.Windows;

internal static class Paths
{
    /// `%LOCALAPPDATA%\Balabro`, the engine's data folder too. `BALABRO_DATA_FOLDER` moves both.
    public static string DataFolder { get; } = Environment.GetEnvironmentVariable("BALABRO_DATA_FOLDER") is { Length: > 0 } folder
        ? folder
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Balabro");

    public static string LogsFolder => Path.Combine(DataFolder, "logs");

    /// Written by scripts/make-windows.ps1 beside the exe. A build from source has none.
    public static string Version { get; } = ReadVersion();

    private static string ReadVersion()
    {
        try
        {
            var text = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "version.txt")).Trim();
            return text.Length > 0 ? text : "dev";
        }
        catch (IOException) { return "dev"; }
        catch (UnauthorizedAccessException) { return "dev"; }
    }
}

/// `logs\app.log` in the data folder, beside the engine's `engine.log`, so the owner can send both.
internal static class Log
{
    private static readonly object Gate = new();

    public static string FilePath => Path.Combine(Paths.LogsFolder, "app.log");

    public static void Write(string message)
    {
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(Paths.LogsFolder);
                var file = new FileInfo(FilePath);
                // Keeps the file small enough to attach to a message.
                if (file.Exists && file.Length > 2_000_000) File.Move(FilePath, FilePath + ".old", overwrite: true);
                File.AppendAllText(FilePath, $"{DateTimeOffset.Now:yyyy-MM-ddTHH:mm:ss.fffzzz} {message}{Environment.NewLine}");
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
