using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using Xunit;

namespace Balabro.Windows.Tests;

public class StatsViewTests
{
    private static StatsPage Page(string golden) => Assert.IsType<StatsMessage>(Wire.Decode(Wpf.Golden(golden))).Page;

    private static FrameworkElement Laid(StatsPage page)
    {
        var view = StatsView.Build(page, topPadding: 36);
        Wpf.Arrange(view, 520, 900);
        return view;
    }

    private static TextBlock Text(FrameworkElement view, string text) => Wpf.All<TextBlock>(view).First(b => b.Text == text);

    private static StatsPage WithBars(params double[] shares) => new()
    {
        Title = "Stats",
        Hands = new BarList { Title = "Hands", Bars = shares.Select((share, i) => new Bar { Label = $"Hand {i}", Value = "1", Share = share, Help = $"Hand {i} help" }).ToList() },
        Runs = new RunList { Title = "Runs", Rows = new List<RunRow>() },
    };

    [Fact]
    public void TilesAreInThreeColumnsWithMoneyInItsColour() => Wpf.Run(() =>
    {
        var view = Laid(Page("stats-before-any-run"));
        var money = Text(view, "$1,083");
        var hand = Text(view, "32,163");
        Assert.Same(Theme.Money, money.Foreground);
        Assert.Same(Theme.Text, hand.Foreground);
        // Runs, Wins and Rounds across, then Best ante, Best hand and Most money below.
        var runs = Text(view, "13").TranslatePoint(new Point(0, 0), view);
        var rounds = Text(view, "111").TranslatePoint(new Point(0, 0), view);
        var ante = Text(view, "6").TranslatePoint(new Point(0, 0), view);
        Assert.Equal(runs.Y, rounds.Y);
        Assert.True(rounds.X > runs.X);
        Assert.Equal(runs.X, ante.X);
        Assert.True(ante.Y > runs.Y);
    });

    [Fact]
    public void WithNoRunsItSaysSo() => Wpf.Run(() =>
        Assert.Contains(Wpf.All<TextBlock>(Laid(Page("stats-before-any-run"))), b => b.Text == "Your runs appear here as you play them."));

    [Fact]
    public void AnteColumnsAreSizedByShareWithTheirHelp() => Wpf.Run(() =>
    {
        var column = Wpf.All<StackPanel>(Laid(Page("stats"))).First(s => (s.ToolTip as string) == "Ante 1, Red Deck, 21 Sep 2026");
        var bar = Wpf.All<Border>(column).Single();
        Assert.Equal(64 * 0.125, bar.ActualHeight);
        Assert.Equal(28, bar.ActualWidth);
        Assert.Same(Theme.Chips, bar.Background);
    });

    [Fact]
    public void ManyAnteColumnsShareTheWidth() => Wpf.Run(() =>
    {
        var page = new StatsPage
        {
            Title = "Stats",
            AnteChart = new AnteChart
            {
                Title = "How far",
                Caption = "Caption",
                Columns = Enumerable.Range(0, 40).Select(i => new AnteColumn { Ante = "1", Share = 1, Help = $"Run {i}" }).ToList(),
            },
            Runs = new RunList { Title = "Runs", Rows = new List<RunRow>() },
        };
        var view = Laid(page);
        var columns = Wpf.All<StackPanel>(view).Where(s => s.ToolTip is string).ToList();
        Assert.Equal(40, columns.Count);
        // 520 less 24 each side, less 39 gaps of 2, over 40 columns.
        Assert.Equal(9.85, columns[0].ActualWidth, 2);
        Assert.True(columns[^1].TranslatePoint(new Point(columns[^1].ActualWidth, 0), view).X <= 496.5);
    });

    [Theory]
    // The track is 520 less 24 each side, the 130 label, the 34 value and two gaps of 8: 292.
    [InlineData(1.0, 292.0)]
    [InlineData(0.5, 146.0)]
    [InlineData(0.001, 2.0)]
    [InlineData(0.0, 2.0)]
    public void BarsHaveALengthByShareOfAtLeastTwo(double share, double length) => Wpf.Run(() =>
    {
        var bar = Wpf.All<ShareBar>(Laid(WithBars(share))).Single();
        Assert.Equal(292, bar.ActualWidth);
        Assert.Equal(length, bar.Length, 6);
    });

    [Fact]
    public void BarsCarryTheirLabelAndHelp() => Wpf.Run(() =>
    {
        var view = Laid(Page("stats"));
        var row = Wpf.All<Grid>(view).First(g => (g.ToolTip as string)?.Length > 0);
        var label = Wpf.All<TextBlock>(row).First();
        Assert.Equal("High Card", label.Text);
        Assert.Equal(130, row.ColumnDefinitions[0].ActualWidth);
        Assert.Equal(1.0, Wpf.All<ShareBar>(row).Single().Share);
    });

    [Fact]
    public void DollarsInARunsDetailsAreInTheMoneyColour() => Wpf.Run(() =>
    {
        var view = Laid(Page("stats"));
        var details = Wpf.All<TextBlock>(view).First(b => b.Inlines.OfType<Run>().Any(r => r.Text == "$95"));
        Assert.Same(Theme.Money, details.Inlines.OfType<Run>().First(r => r.Text == "$95").Foreground);
        Assert.Equal("Best hand 16 · peak $95 · mostly High Card · Gluttonous Joker", string.Concat(details.Inlines.OfType<Run>().Select(r => r.Text)));
    });
}
