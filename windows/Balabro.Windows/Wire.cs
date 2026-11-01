using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Balabro.Windows;

// The engine's lines, as in Sources/BalabroEngine/HostLink.swift and Sources/BalabroCore/ViewJSON.swift.
// Tests/BalabroEngineTests/Fixtures/wire holds one golden line of each kind, which both sides' tests read.

public abstract record HostMessage;

public sealed record Hello(string Version, string? FontPath) : HostMessage;

public sealed record CoachMessage(CoachView View) : HostMessage;

public sealed record PilotMessage(PilotView View) : HostMessage;

/// Answered with a `screenshot` line carrying the same id.
public sealed record CaptureRequest(int Id) : HostMessage;

/// The answer to a `stats` line.
public sealed record StatsMessage(StatsPage Page) : HostMessage;

public enum CoachStatus { WaitingForRun, LookingAtPack, Thinking, Answering, Ready }

public enum CoachGoal { Win, Naneinf }

public enum DecisionKind { PlayHand, Shop, BlindSelect, OpenPack }

public sealed record CoachView
{
    public required CoachStatus Status { get; init; }
    public required CoachGoal Goal { get; init; }
    public required string Headline { get; init; }
    public double? ChipsNeeded { get; init; }
    public DecisionKind? WaitingOn { get; init; }
    public required List<string> WaitingCaptions { get; init; }
    public Placeholder? Placeholder { get; init; }
    public Advice? Advice { get; init; }
    public required List<ScoredLine> Score { get; init; }
    public required bool SawScreen { get; init; }
    public required List<FollowUp> Thread { get; init; }
    public string? QueuedQuestion { get; init; }
    public Problem? Problem { get; init; }
    public required bool CanRetry { get; init; }
}

public sealed record Placeholder
{
    public required string Title { get; init; }
    public string? Detail { get; init; }
}

public sealed record Advice
{
    public required List<string> DoNow { get; init; }
    public string? Goal { get; init; }
    public required List<string> Why { get; init; }
    public Lesson? Lesson { get; init; }
    public required string Rest { get; init; }
}

public sealed record Lesson
{
    public int? Number { get; init; }
    public required string Title { get; init; }
    public required string Body { get; init; }
    public required string Heading { get; init; }
}

public sealed record ScoredLine
{
    public required string Label { get; init; }
    public ScoreSum? Sum { get; init; }
    public required bool IsAlternative { get; init; }
    public required bool Clears { get; init; }
    public string? Note { get; init; }
}

public sealed record ScoreSum
{
    public required string Chips { get; init; }
    public required string Mult { get; init; }
    public required string Total { get; init; }
    public required bool IsEstimate { get; init; }
}

public sealed record FollowUp
{
    public required string Question { get; init; }
    public required string Reply { get; init; }
    public required bool ChangedSteps { get; init; }
}

public sealed record Problem
{
    public required string Kind { get; init; }
    public string? Reason { get; init; }
    public required string Message { get; init; }
}

public enum PilotStatus { Idle, Preparing, Playing, AskingClaude, Finished }

public sealed record PilotView
{
    public required PilotStatus Status { get; init; }
    public required string Title { get; init; }
    public DateTimeOffset? StartedAt { get; init; }
    public required CoachGoal Goal { get; init; }
    public BotStatus? Run { get; init; }
    public string? StartingLine { get; init; }
    public string? ChoosingLine { get; init; }
    public string? Why { get; init; }
    public string? Warning { get; init; }
    public PilotResult? Result { get; init; }
    public required List<BestTime> BestTimes { get; init; }
}

public sealed record BotStatus
{
    public required int Ante { get; init; }
    public required int Round { get; init; }
    public required int Dollars { get; init; }
    public required double BestHand { get; init; }
    public required string BestHandText { get; init; }
    public required string Doing { get; init; }
    public required List<string> Lines { get; init; }
}

public sealed record PilotResult
{
    public required PilotEnding Ending { get; init; }
    public required string Goal { get; init; }
    public required string Deck { get; init; }
    public required int Stake { get; init; }
    public required int Ante { get; init; }
    public required int Round { get; init; }
    public required double BestHand { get; init; }
    public required string BestHandText { get; init; }
    public required double Seconds { get; init; }
    public required string Time { get; init; }
    public required List<string> Lines { get; init; }
    public required string GameVersion { get; init; }
    public required DateTimeOffset FinishedAt { get; init; }
}

public sealed record PilotEnding
{
    public required string Kind { get; init; }
    public string? Reason { get; init; }
}

public sealed record BestTime
{
    public required string Title { get; init; }
    public required double Seconds { get; init; }
    public required string Line { get; init; }
}

/// Everything the stats window shows. A section the player has no data for is null.
public sealed record StatsPage
{
    public required string Title { get; init; }
    public StatsTotals? Totals { get; init; }
    public AnteChart? AnteChart { get; init; }
    public BarList? Hands { get; init; }
    public BarList? Jokers { get; init; }
    public required RunList Runs { get; init; }
}

public sealed record StatsTotals
{
    public required string Title { get; init; }
    public required List<StatsTile> Tiles { get; init; }
}

public sealed record StatsTile
{
    public required string Label { get; init; }
    public required string Value { get; init; }
    public required bool IsMoney { get; init; }
}

public sealed record AnteChart
{
    public required string Title { get; init; }
    public required string Caption { get; init; }
    /// Oldest first.
    public required List<AnteColumn> Columns { get; init; }
}

public sealed record AnteColumn
{
    public required string Ante { get; init; }
    /// The column's height as a share of the tallest the chart can draw, from 0 to 1.
    public required double Share { get; init; }
    public required string Help { get; init; }
}

public sealed record BarList
{
    public required string Title { get; init; }
    public required List<Bar> Bars { get; init; }
}

public sealed record Bar
{
    public required string Label { get; init; }
    public required string Value { get; init; }
    /// The bar's length as a share of the longest the chart can draw, from 0 to 1.
    public required double Share { get; init; }
    public required string Help { get; init; }
}

public sealed record RunList
{
    public required string Title { get; init; }
    public string? Empty { get; init; }
    public required List<RunRow> Rows { get; init; }
}

public sealed record RunRow
{
    public required string Id { get; init; }
    public required string Outcome { get; init; }
    public required string Deck { get; init; }
    public required string Date { get; init; }
    public required string Details { get; init; }
}

public static class Wire
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false), new LenientDoubleConverter() },
    };

    /// One line from the engine. Throws on a line the app can't read, so the caller can log it.
    public static HostMessage Decode(string line)
    {
        using var document = JsonDocument.Parse(line);
        var root = document.RootElement;
        var type = root.GetProperty("type").GetString();
        return type switch
        {
            "hello" => new Hello(
                root.GetProperty("version").GetString() ?? "dev",
                root.TryGetProperty("fontPath", out var font) && font.ValueKind == JsonValueKind.String ? font.GetString() : null),
            "coach" => new CoachMessage(View<CoachView>(root)),
            "pilot" => new PilotMessage(View<PilotView>(root)),
            "capture" => new CaptureRequest(root.GetProperty("id").GetInt32()),
            "stats" => new StatsMessage(root.GetProperty("data").Deserialize<StatsPage>(Options) ?? throw new JsonException("Empty stats")),
            _ => throw new JsonException($"Unknown line type {type}"),
        };
    }

    private static T View<T>(JsonElement root) =>
        root.GetProperty("view").Deserialize<T>(Options) ?? throw new JsonException("Empty view");

    // The app's lines, named after the runtime methods the Mac panel calls.
    public static string Ask(string question) => Line(new { type = "ask", question });
    public static string Retry() => Line(new { type = "retry" });
    public static string Refresh() => Line(new { type = "refresh" });
    public static string AdviseNextRun() => Line(new { type = "adviseNextRun" });
    public static string SetGoal(CoachGoal goal) => Line(new { type = "setGoal", goal = Name(goal) });
    public static string PlayForMe(CoachGoal goal) => Line(new { type = "playForMe", goal = Name(goal) });
    public static string StopPilot() => Line(new { type = "stopPilot" });
    public static string DismissPilot() => Line(new { type = "dismissPilot" });
    public static string Stats() => Line(new { type = "stats" });
    public static string Screenshot(int id, byte[]? png) => Line(new { type = "screenshot", id, png = png is null ? null : Convert.ToBase64String(png) });

    private static string Name(CoachGoal goal) => goal == CoachGoal.Naneinf ? "naneinf" : "win";

    private static string Line(object message) => JsonSerializer.Serialize(message);

    /// The engine writes an infinite best hand (naneinf) as "inf", because JSON has no infinity.
    private sealed class LenientDoubleConverter : JsonConverter<double>
    {
        public override double Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        {
            if (reader.TokenType == JsonTokenType.Number) return reader.GetDouble();
            return reader.GetString() switch
            {
                "inf" => double.PositiveInfinity,
                "-inf" => double.NegativeInfinity,
                "nan" => double.NaN,
                var text => double.Parse(text ?? throw new JsonException("Expected a number"), CultureInfo.InvariantCulture),
            };
        }

        public override void Write(Utf8JsonWriter writer, double value, JsonSerializerOptions options) => writer.WriteNumberValue(value);
    }
}
