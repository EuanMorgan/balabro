using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using Xunit;

namespace Balabro.Windows.Tests;

/// The expected numbers are worked by hand from Sources/Balabro/WaitingView.swift. The flame values come from a separate
/// Python copy of its `fuel`.
public class WaitingTests
{
    [Fact]
    public void TheTallyAtHalfway()
    {
        // progress 0.5: chips 10 + 45, mult 1 + 4, fade min(1, 0.5 / 0.05), a whole 4 sets of 8 so pulse is 1 + 0.06,
        // heat (0.5 - 0.15) / 0.45 with 0.5 / 0.08 capped at 1.
        var tally = WaitingMotion.ScoreTally(3);
        Assert.Equal((55, 5, 1.0), (tally.Chips, tally.Mult, tally.Fade));
        Assert.Equal(1.06, tally.Pulse, 10);
        Assert.Equal(0.35 / 0.45, tally.Heat, 10);
    }

    [Fact]
    public void TheTallyFadesAndCoolsThroughItsReset()
    {
        // progress 0.99: fade 0.01 / 0.05, heat capped at 1 then times 0.01 / 0.08.
        var ending = WaitingMotion.ScoreTally(5.94);
        Assert.Equal((99, 8), (ending.Chips, ending.Mult));
        Assert.Equal(0.2, ending.Fade, 10);
        Assert.Equal(0.125, ending.Heat, 10);
        Assert.Equal(0, WaitingMotion.ScoreTally(0.3).Heat);
        Assert.Equal(55, WaitingMotion.ScoreTally(3 + 6).Chips);
    }

    [Theory]
    [InlineData(0.0, 0.2, 3.0, 0.7777777777777778, 0.3416791844413683)]
    [InlineData(-0.5, 0.6, 4.2, 1.0, 0.12151179189448619)]
    [InlineData(0.9, 0.9, 1.0, 0.0, -0.7239405627430235)]
    public void TheFlames(double x, double rise, double time, double heat, double fuel) =>
        Assert.Equal(fuel, WaitingMotion.FlameFuel(x, rise, time, heat), 10);

    [Fact]
    public void TheCoin()
    {
        var resting = WaitingMotion.SpinningCoin(0);
        Assert.Equal((1.0, 8.0, 40.0), (resting.ScaleX, resting.OffsetY, resting.ShadowWidth));
        // Top of the hop at 0.8 s, side on, where the width stops at 0.08 so it never vanishes.
        var top = WaitingMotion.SpinningCoin(0.8);
        Assert.Equal(0.08, top.ScaleX, 10);
        Assert.Equal(0, top.OffsetY, 10);
        Assert.Equal(28, top.ShadowWidth, 10);
    }

    [Fact]
    public void TheCardsWave()
    {
        // The outer cards sit 6 lower. Each lifts up to 10 as the wave reaches it, starting 0.8 / 3 s after the last.
        Assert.Equal(6, WaitingMotion.CardOffsetY(0, 0), 10);
        Assert.Equal(0, WaitingMotion.CardOffsetY(2, 0), 10);
        Assert.Equal(6 - 10, WaitingMotion.CardOffsetY(0, Math.PI / 6), 10);
        Assert.Equal(-10, WaitingMotion.CardOffsetY(2, (Math.PI / 2 + 1.6) / 3), 10);
    }

    [Fact]
    public void ThePackShinesThenRests()
    {
        Assert.Equal(-0.4, WaitingMotion.PackShine(0), 10);
        Assert.Equal(0.3, WaitingMotion.PackShine(0.72), 10);
        Assert.Equal(1, WaitingMotion.PackShine(1.44), 10);
        Assert.Equal(1, WaitingMotion.PackShine(2.3), 10);
        Assert.Equal(-0.4, WaitingMotion.PackShine(2.4), 10);
        Assert.Equal(5, WaitingMotion.PackAngle(Math.PI / 5), 10);
    }

    [Fact]
    public void CaptionsTakeTurns()
    {
        var captions = new[] { "a", "b", "c" };
        Assert.Equal("a", WaitingMotion.Caption(captions, 3.4));
        Assert.Equal("b", WaitingMotion.Caption(captions, 3.6));
        Assert.Equal("a", WaitingMotion.Caption(captions, 10.6));
        Assert.Equal("", WaitingMotion.Caption(Array.Empty<string>(), 1));
    }

    private static System.Windows.Media.Imaging.BitmapSource Frame(DecisionKind kind, double time, bool moving = true)
    {
        var tickers = new List<Action<double>>();
        var view = WaitingView.Build(kind, new[] { "caption" }, tickers, moving);
        foreach (var ticker in tickers) ticker(time);
        Wpf.Arrange(view, 288, 140);
        return Previews.Image(view, 288, 140);
    }

    /// The picture is 92 tall under 10 of padding, and images are at 2×. The flames are above the 44-tall tile.
    private const int AboveTile = (10 + 92 - 44) * 2;

    [Fact]
    public void TheTilesCatchFireOnlyWhenHot() => Wpf.Run(() =>
    {
        Assert.True(Wpf.CountPixels(Frame(DecisionKind.PlayHand, 3), Theme.Chips, toY: AboveTile) > 100);
        Assert.True(Wpf.CountPixels(Frame(DecisionKind.PlayHand, 3), Theme.Mult, toY: AboveTile) > 100);
        Assert.Equal(0, Wpf.CountPixels(Frame(DecisionKind.PlayHand, 0.3), Theme.Chips, toY: AboveTile));
    });

    [Fact]
    public void TheCoinTurnsSideOn() => Wpf.Run(() =>
    {
        var flat = Wpf.CountPixels(Frame(DecisionKind.Shop, 0), Theme.Money);
        var edge = Wpf.CountPixels(Frame(DecisionKind.Shop, 0.8), Theme.Money);
        Assert.True(flat > 3000, $"{flat} coin pixels");
        Assert.True(edge < flat / 5, $"{edge} of {flat} coin pixels");
    });

    [Theory]
    [InlineData(DecisionKind.BlindSelect)]
    [InlineData(DecisionKind.OpenPack)]
    public void TheShapesMove(DecisionKind kind) => Wpf.Run(() =>
        Assert.NotEqual(Wpf.Pixels(Frame(kind, 0)), Wpf.Pixels(Frame(kind, 1))));

    [Theory]
    [InlineData(DecisionKind.BlindSelect)]
    [InlineData(DecisionKind.OpenPack)]
    public void WithReducedMotionTheShapesHoldStill(DecisionKind kind) => Wpf.Run(() =>
        Assert.Equal(Wpf.Pixels(Frame(kind, 0, moving: false)), Wpf.Pixels(Frame(kind, 1, moving: false))));
}
