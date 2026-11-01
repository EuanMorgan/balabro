using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using Xunit;

namespace Balabro.Windows.Tests;

public class PanelTests
{
    private static PreviewLine Line(string golden, double height = 560, bool showsWhy = true, UpdateOffer? update = null) =>
        new("test", Wire.Decode(Wpf.Golden(golden)), height, showsWhy, update);

    private static void WithPanel(PreviewLine line, Action<PanelWindow> check) => Wpf.Run(() =>
    {
        var panel = Previews.Open(line);
        try { check(panel); }
        finally { panel.Close(); }
    });

    private static IEnumerable<string> Selectable(PanelWindow panel) => Wpf.All<SelectableText>(panel).Select(t => t.Text);

    private static IEnumerable<string> Words(PanelWindow panel) => Wpf.All<TextBlock>(panel).Select(t => t.Text);

    [Fact]
    public void AdviceCanBeSelected() => WithPanel(Line("coach-advice"), panel =>
    {
        Assert.Equal(
            new[] { "Discard J♦ 4♠ 3♥", "Play K♥ K♣ 7♠ 7♦", "Two Pair", "Instead: Pair", "The Kings are your best pair.", "Pairs first", "Early blinds are cleared by pairs." },
            Selectable(panel));
    });

    [Fact]
    public void FollowUpsCanBeSelected() => WithPanel(Line("coach-ready"), panel =>
        Assert.Equal(new[] { "ok", "Say a fruit", "PLUM" }, Selectable(panel)));

    [Fact]
    public void SelectionGivesThePlayerTheWordsWithTheirColours() => Wpf.Run(() =>
    {
        var text = new SelectableText("Buy it, $6 for **K♥ Q♠** now", 13, Theme.Text);
        Assert.True(text.IsReadOnly);
        Wpf.Arrange(text, 300, 100);
        text.SelectAll();
        Assert.Equal("Buy it, $6 for K♥ Q♠ now", ColouredText.ForClipboard(text.Selection.Text).TrimEnd('\r', '\n'));
        var runs = ((Paragraph)text.Document.Blocks.FirstBlock).Inlines.OfType<Run>().ToList();
        Assert.Same(Theme.Money, runs.Single(r => r.Text == "$6").Foreground);
        Assert.Same(Theme.Mult, runs.Single(r => r.Text == "♥").Foreground);
        Assert.Equal(FontWeights.Bold, runs.Single(r => r.Text == "♠").FontWeight);
    });

    [Theory]
    [InlineData("Discard J♦\u2002\u20094♠\u2002\u20093♥", "Discard J♦ 4♠ 3♥")]
    [InlineData("Two  words stay", "Two  words stay")]
    public void CopiedCardsHaveOneSpace(string shown, string copied) => Assert.Equal(copied, ColouredText.ForClipboard(shown));

    [Fact]
    public void ItLaysOutLikeTheTextItReplaced() => Wpf.Run(() =>
    {
        const string words = "Keep K♥ K♣ 3♠ 3♦. Any King or 3 makes a Full House, so throw the rest and draw four.";
        foreach (var width in new[] { 140.0, 288.0, double.PositiveInfinity })
        {
            var selectable = new SelectableText(words, 13, Theme.Text);
            var plain = Ui.Coloured(words, 13, Theme.Text);
            selectable.Measure(new Size(width, double.PositiveInfinity));
            plain.Measure(new Size(width, double.PositiveInfinity));
            Assert.Equal(plain.DesiredSize.Height, selectable.DesiredSize.Height, 0);
            // Wrapped text takes the whole width. On one line it takes its own.
            if (double.IsInfinity(width)) Assert.InRange(selectable.DesiredSize.Width - plain.DesiredSize.Width, 0, 2);
            else Assert.Equal(width, selectable.DesiredSize.Width);
        }
    });

    [Fact]
    public void TheTextStartsAtItsLeftEdgeLikeATextBlock() => Wpf.Run(() =>
    {
        var text = new SelectableText("Say a fruit", 13, Theme.Text);
        text.Measure(new Size(300, 100));
        text.Arrange(new Rect(0, 0, text.DesiredSize.Width, text.DesiredSize.Height));
        text.UpdateLayout();
        var first = text.Document.ContentStart.GetInsertionPosition(LogicalDirection.Forward);
        Assert.Equal(0, first.GetCharacterRect(LogicalDirection.Forward).Left, 0);
    });

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    /// The panel stays inactive over the game, and text can't take focus there. WPF reads the real mouse button, so this
    /// calls what the mouse handlers call.
    [Fact]
    public void ADragSelectsWithThePanelInactiveAndTheForegroundLeftAlone() => WithPanel(Line("coach-ready", 420, false), panel =>
    {
        var foreground = GetForegroundWindow();
        var text = Wpf.All<SelectableText>(panel).Single(t => t.Text == "Say a fruit");
        var selected = 0;
        panel.AddHandler(SelectableText.TextSelectedEvent, new RoutedEventHandler((_, _) => selected++));
        Assert.False(panel.IsActive);
        Assert.False(text.IsKeyboardFocused);
        var middle = text.ActualHeight / 2;

        text.BeginDrag(new Point(1, middle));
        text.EndDrag();
        Assert.True(text.Selection.IsEmpty);
        Assert.Equal(0, selected);

        text.BeginDrag(new Point(1, middle));
        text.ExtendDrag(new Point(text.ActualWidth, middle));
        Assert.Equal("Say a fruit", text.Selection.Text);
        text.EndDrag();
        Assert.Equal(1, selected);

        Previews.Settle();
        Assert.False(panel.IsActive);
        Assert.Equal(foreground, GetForegroundWindow());
    });

    /// A click with no drag clears what was selected, as it does on the Mac.
    [Fact]
    public void AClickClearsTheSelection() => Wpf.Run(() =>
    {
        var text = new SelectableText("Say a fruit", 13, Theme.Text);
        Wpf.Arrange(text, 300, 100);
        text.SelectAll();
        text.BeginDrag(new Point(1, 5));
        text.EndDrag();
        Assert.True(text.Selection.IsEmpty);
    });

    [Fact]
    public void TheUpdateRowShowsOnlyWithAnOffer()
    {
        var offer = (UpdateOffer)Wire.Decode(Wpf.Golden("update"));
        WithPanel(Line("coach-advice", update: offer), panel =>
        {
            Assert.Contains("Version 0.3.0 is available", Words(panel));
            Assert.Contains("Update", Words(panel));
            panel.Show(new UpdateState(offer, UpdateStage.Installing));
            Previews.Settle();
            Assert.Contains("Updating to 0.3.0…", Words(panel));
            Assert.DoesNotContain("Update", Words(panel));
            panel.Show(new UpdateState(offer, UpdateStage.Failed));
            Previews.Settle();
            Assert.Contains("Couldn't update", Words(panel));
            Assert.Contains("Download", Words(panel));
        });
        WithPanel(Line("coach-advice"), panel => Assert.DoesNotContain("Update", Words(panel)));
    }

    [Fact]
    public void WhyOpensWhenThePreviewAsks()
    {
        WithPanel(Line("coach-advice", showsWhy: true), panel => Assert.Contains("The Kings are your best pair.", Selectable(panel)));
        WithPanel(Line("coach-advice", showsWhy: false), panel => Assert.DoesNotContain("The Kings are your best pair.", Selectable(panel)));
    }

    [Fact]
    public void APreviewImageIsTwiceThePanelsSize() => WithPanel(Line("coach-advice", 420), panel =>
    {
        var image = Previews.Image((Visual)panel.Content, 320, 420);
        Assert.Equal((640, 840), (image.PixelWidth, image.PixelHeight));
        Assert.True(Wpf.CountPixels(image, Theme.Felt) > 100_000);
    });

    [Fact]
    public void TheThinkingPanelAnimates() => WithPanel(new PreviewLine("test", Wire.Decode(Wpf.Golden("coach-thinking")), 420, false, null), panel =>
    {
        panel.HoldTime(3);
        Previews.Settle();
        Assert.Contains("55", Words(panel));
        Assert.Contains("5", Words(panel));
        Assert.Single(Words(panel), w => w is "Counting the chips" or "Checking the odds" or "Reading your hand");
        Assert.Equal(2, Wpf.All<PixelFlames>(panel).Count());
    });
}
