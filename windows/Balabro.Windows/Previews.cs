using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Balabro.Windows;

/// `Balabro.exe --render-previews <dir>` writes each of the engine's preview states as a PNG, and the stats page, for
/// comparing with the images from the Mac's `--render-previews`. Nothing it draws shows on screen.
internal static class Previews
{
    private const double Scale = 2;
    private const double PanelWidth = 320;
    /// Flames are high, the coin is mid-spin and the cards are mid-wave.
    private const double AnimationTime = 4.2;

    public static int Render(string directory, string[] args)
    {
        Directory.CreateDirectory(directory);
        // The engine coaches any run it can see, so unless told otherwise it gets a saves folder with nothing in it.
        var scratch = Path.Combine(Path.GetTempPath(), "balabro-previews-" + Guid.NewGuid().ToString("N"));
        var given = Shell.EngineArguments(args);
        if (given.Length == 0) Directory.CreateDirectory(scratch);
        try
        {
            var page = FontAndStats(given.Length > 0 ? given : new[] { "--saves-root", scratch });
            if (page is null) return 1;
            // After the wait for the engine, because the pilot's clocks run from when these lines are printed.
            foreach (var line in EngineOutput("--print-preview-views").Select(Wire.DecodePreview))
                Save(Panel(line), Path.Combine(directory, line.Name + ".png"));
            Save(Stats(page), Path.Combine(directory, "stats.png"));
            return 0;
        }
        catch (Exception error) when (error is IOException or InvalidOperationException or System.Text.Json.JsonException or System.ComponentModel.Win32Exception)
        {
            Log.Write($"Couldn't render the previews: {error}");
            return 1;
        }
        finally
        {
            if (Directory.Exists(scratch)) Directory.Delete(scratch, true);
        }
    }

    /// Starts an engine for the game's font and the stats page. Null if it doesn't answer.
    private static StatsPage? FontAndStats(string[] engineArguments)
    {
        using var engine = new EngineLink(engineArguments);
        var hello = new TaskCompletionSource<Hello>();
        var stats = new TaskCompletionSource<StatsPage>();
        engine.Received += message =>
        {
            if (message is Hello said) hello.TrySetResult(said);
            if (message is StatsMessage answer) stats.TrySetResult(answer.Page);
        };
        engine.Start();
        var wait = TimeSpan.FromMinutes(2);
        if (!hello.Task.Wait(wait))
        {
            Log.Write("The engine didn't say hello for the previews");
            return null;
        }
        Theme.LoadPixelFont(hello.Task.Result.FontPath);
        engine.Send(Wire.Stats());
        if (stats.Task.Wait(wait)) return stats.Task.Result;
        Log.Write("The engine didn't send the stats page for the previews");
        return null;
    }

    private static IEnumerable<string> EngineOutput(string argument)
    {
        using var process = Process.Start(new ProcessStartInfo(EngineLink.ExecutablePath, argument)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            StandardOutputEncoding = new UTF8Encoding(false),
        }) ?? throw new InvalidOperationException("Couldn't start the engine");
        var output = process.StandardOutput.ReadToEnd();
        process.WaitForExit();
        if (process.ExitCode != 0) throw new InvalidOperationException($"The engine's {argument} exited with {process.ExitCode}");
        return output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    }

    /// A real window off the screen, because the panel lays itself out from its window's size.
    internal static PanelWindow Open(PreviewLine line)
    {
        var panel = new PanelWindow(_ => { }, preview: true)
        {
            Width = PanelWidth,
            Height = line.Height,
            Left = -4000,
            Top = 0,
            WindowStartupLocation = WindowStartupLocation.Manual,
        };
        panel.Show();
        if (line.Panel is CoachMessage coach) panel.Show(coach.View);
        if (line.Panel is PilotMessage pilot) panel.Show(pilot.View);
        panel.Show(line.Update is null ? null : new UpdateState(line.Update, UpdateStage.Available));
        panel.ShowWhy = line.ShowsWhy;
        panel.HoldTime(AnimationTime);
        Settle();
        return panel;
    }

    private static BitmapSource Panel(PreviewLine line)
    {
        var panel = Open(line);
        try { return Image((Visual)panel.Content, PanelWidth, line.Height); }
        finally { panel.Close(); }
    }

    internal static BitmapSource Stats(StatsPage page)
    {
        var view = StatsView.Build(page, topPadding: 36);
        view.Measure(new Size(520, 900));
        view.Arrange(new Rect(0, 0, 520, 900));
        view.UpdateLayout();
        return Image(view, 520, 900);
    }

    internal static void Settle()
    {
        for (var i = 0; i < 3; i++) Dispatcher.CurrentDispatcher.Invoke(() => { }, DispatcherPriority.ApplicationIdle);
    }

    internal static BitmapSource Image(Visual visual, double width, double height)
    {
        var image = new RenderTargetBitmap((int)(width * Scale), (int)(height * Scale), 96 * Scale, 96 * Scale, PixelFormats.Pbgra32);
        image.Render(visual);
        image.Freeze();
        return image;
    }

    private static void Save(BitmapSource image, string path)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(image));
        using var file = File.Create(path);
        encoder.Save(file);
        Log.Write($"Wrote {path}");
    }
}
