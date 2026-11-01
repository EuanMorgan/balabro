using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using Balabro.Windows;
using Xunit;

namespace Balabro.Windows.Tests;

/// Every golden line in Tests/BalabroEngineTests/Fixtures/wire, which the engine's own tests check it still writes,
/// decoded into the app's records. A wire change that would break the app fails here.
public class WireTests
{
    private static HostMessage Golden(string name) =>
        Wire.Decode(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "wire", name + ".json")).ReplaceLineEndings(" "));

    [Fact]
    public void EveryGoldenFileIsTested()
    {
        var files = Directory.GetFiles(Path.Combine(AppContext.BaseDirectory, "wire"), "*.json").Select(Path.GetFileNameWithoutExtension).OrderBy(n => n);
        var tested = new[] { "capture", "coach-advice", "coach-no-screenshot", "coach-problem", "coach-ready", "coach-thinking", "coach-waiting", "hello", "pilot-failed", "pilot-playing" };
        Assert.Equal(tested, files);
    }

    [Fact]
    public void Hello()
    {
        var hello = Assert.IsType<Hello>(Golden("hello"));
        Assert.Equal("1.2.3", hello.Version);
        Assert.Equal(@"C:\Users\player\AppData\Local\Balabro\game\1730000000\resources\fonts\m6x11plus.ttf", hello.FontPath);
    }

    [Fact]
    public void Capture() => Assert.Equal(3, Assert.IsType<CaptureRequest>(Golden("capture")).Id);

    [Fact]
    public void CoachWaiting()
    {
        var view = Assert.IsType<CoachMessage>(Golden("coach-waiting")).View;
        Assert.Equal(CoachStatus.WaitingForRun, view.Status);
        Assert.Equal(CoachGoal.Win, view.Goal);
        Assert.Equal("Start or continue a run", view.Headline);
        Assert.Equal("Waiting for a run", view.Placeholder?.Title);
        Assert.StartsWith("Start or continue a run in Balatro.", view.Placeholder?.Detail);
        Assert.Null(view.ChipsNeeded);
        Assert.Null(view.Advice);
        Assert.Empty(view.Thread);
    }

    [Fact]
    public void CoachThinking()
    {
        var view = Assert.IsType<CoachMessage>(Golden("coach-thinking")).View;
        Assert.Equal(CoachStatus.Thinking, view.Status);
        Assert.Equal(DecisionKind.PlayHand, view.WaitingOn);
        Assert.Equal(300, view.ChipsNeeded);
        Assert.Equal(new[] { "Counting the chips", "Checking the odds", "Reading your hand" }, view.WaitingCaptions);
        Assert.Equal("Ante 1 · bl_small", view.Headline);
    }

    [Fact]
    public void CoachAdvice()
    {
        var view = Assert.IsType<CoachMessage>(Golden("coach-advice")).View;
        Assert.Equal(CoachStatus.Ready, view.Status);
        var advice = view.Advice!;
        Assert.Equal(new[] { "Discard J♦ 4♠ 3♥", "Play K♥ K♣ 7♠ 7♦" }, advice.DoNow);
        Assert.Equal("Build towards a Flush.", advice.Goal);
        Assert.Equal(new[] { "The Kings are your best pair." }, advice.Why);
        Assert.Equal("", advice.Rest);
        Assert.Equal(3, advice.Lesson?.Number);
        Assert.Equal("Lesson 3", advice.Lesson?.Heading);
        Assert.Equal("Pairs first", advice.Lesson?.Title);
        Assert.Equal("Early blinds are cleared by pairs.", advice.Lesson?.Body);

        Assert.Equal(2, view.Score.Count);
        var main = view.Score[0];
        Assert.Equal("Two Pair", main.Label);
        Assert.False(main.IsAlternative);
        Assert.False(main.Clears);
        Assert.Equal("Leaves 208 to score", main.Note);
        Assert.Equal(("46", "2", "92", false), (main.Sum!.Chips, main.Sum.Mult, main.Sum.Total, main.Sum.IsEstimate));
        var instead = view.Score[1];
        Assert.Equal("Instead: Pair", instead.Label);
        Assert.True(instead.IsAlternative);
        Assert.Null(instead.Note);
        Assert.Equal("60", instead.Sum!.Total);
    }

    [Fact]
    public void CoachReadyWithAFollowUp()
    {
        var view = Assert.IsType<CoachMessage>(Golden("coach-ready")).View;
        var followUp = Assert.Single(view.Thread);
        Assert.Equal("Say a fruit", followUp.Question);
        Assert.Equal("PLUM", followUp.Reply);
        Assert.False(followUp.ChangedSteps);
        Assert.Equal("ok", view.Advice?.Rest);
        Assert.Empty(view.Advice!.DoNow);
    }

    [Fact]
    public void CoachProblem()
    {
        var view = Assert.IsType<CoachMessage>(Golden("coach-problem")).View;
        Assert.True(view.CanRetry);
        Assert.Equal("turnFailed", view.Problem?.Kind);
        Assert.Equal("notLoggedIn", view.Problem?.Reason);
        Assert.Equal("Claude isn't logged in. Run `claude` in a terminal and log in, then retry.", view.Problem?.Message);
        Assert.Equal("Ready", view.Placeholder?.Title);
    }

    [Fact]
    public void CoachWithoutAScreenshot()
    {
        var view = Assert.IsType<CoachMessage>(Golden("coach-no-screenshot")).View;
        Assert.Equal(DecisionKind.OpenPack, view.WaitingOn);
        Assert.Equal("screenRecordingDenied", view.Problem?.Kind);
        Assert.StartsWith("Couldn't see Balatro's window. Make sure it's open, not minimised, and in Borderless mode.", view.Problem?.Message);
    }

    [Fact]
    public void PilotPlaying()
    {
        var view = Assert.IsType<PilotMessage>(Golden("pilot-playing")).View;
        Assert.Equal(PilotStatus.AskingClaude, view.Status);
        Assert.Equal("Playing for you", view.Title);
        Assert.Equal(new DateTimeOffset(2026, 9, 21, 14, 13, 20, TimeSpan.Zero), view.StartedAt);
        Assert.Equal("Claude is choosing", view.ChoosingLine);
        Assert.Equal("Hologram gives scaling XMult.", view.Why);
        Assert.Equal(4420, view.Run?.BestHand);
        Assert.Equal("Discarding 3 cards, 61% to reach 2,442", view.Run?.Doing);
        Assert.Equal(new[] { "Ante 4, round 11, $41", "Best hand 4,420" }, view.Run?.Lines);
        Assert.Equal("Fastest win: 6:52", Assert.Single(view.BestTimes).Line);
    }

    [Fact]
    public void PilotFailed()
    {
        var view = Assert.IsType<PilotMessage>(Golden("pilot-failed")).View;
        Assert.Equal(PilotStatus.Finished, view.Status);
        Assert.Equal(CoachGoal.Naneinf, view.Goal);
        Assert.Equal("Couldn't finish", view.Title);
        var result = view.Result!;
        Assert.Equal("failed", result.Ending.Kind);
        Assert.Equal("Claude isn't logged in.", result.Ending.Reason);
        Assert.True(double.IsPositiveInfinity(result.BestHand));
        Assert.Equal("naneinf", result.BestHandText);
        Assert.Equal("62:05", result.Time);
        Assert.Equal(new DateTimeOffset(2026, 9, 21, 15, 15, 25, TimeSpan.Zero), result.FinishedAt);
    }

    [Fact]
    public void ARenamedFieldFailsToDecode() =>
        Assert.ThrowsAny<JsonException>(() => Wire.Decode("""{"type":"coach","view":{"state":"ready"}}"""));

    [Fact]
    public void AppLinesMatchWhatTheEngineReads()
    {
        // The engine's WireTests.appLines reads these same shapes.
        Assert.Equal("""{"type":"ask","question":"why keep the 6?"}""", Wire.Ask("why keep the 6?"));
        Assert.Equal("""{"type":"setGoal","goal":"naneinf"}""", Wire.SetGoal(CoachGoal.Naneinf));
        Assert.Equal("""{"type":"playForMe","goal":"win"}""", Wire.PlayForMe(CoachGoal.Win));
        Assert.Equal("""{"type":"stopPilot"}""", Wire.StopPilot());
        Assert.Equal("""{"type":"screenshot","id":2,"png":"iVBO"}""", Wire.Screenshot(2, new byte[] { 0x89, 0x50, 0x4E }));
        Assert.Equal("""{"type":"screenshot","id":2,"png":null}""", Wire.Screenshot(2, null));
    }

    [Fact]
    public void OnlyTheSavesRootGoesToTheEngine()
    {
        Assert.Equal(new[] { "--saves-root", @"C:\x" }, Shell.EngineArguments(new[] { "--verbose", "--saves-root", @"C:\x" }));
        Assert.Empty(Shell.EngineArguments(new[] { "--saves-root" }));
    }
}
