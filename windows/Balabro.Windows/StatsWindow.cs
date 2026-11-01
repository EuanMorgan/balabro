using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Interop;
using System.Windows.Media;

namespace Balabro.Windows;

/// Stays over the game like the panel, as Sources/Balabro/StatsWindow.swift does, with a title bar in the felt's colour.
internal sealed class StatsWindow : Window
{
    public StatsWindow(StatsPage page)
    {
        Title = page.Title;
        Width = 520;
        Height = 680;
        Topmost = true;
        Background = Theme.Felt;
        FontFamily = Theme.Body;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        UseLayoutRounding = true;
        // The Mac's 36 includes its title bar, which is drawn over the content. This one sits above it.
        Content = StatsView.Build(page, topPadding: 8);
        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            var dark = 1;
            Native.DwmSetWindowAttribute(hwnd, Native.DWMWA_USE_IMMERSIVE_DARK_MODE, ref dark, sizeof(int));
            var felt = Theme.Felt.Color;
            var caption = felt.R | felt.G << 8 | felt.B << 16;
            Native.DwmSetWindowAttribute(hwnd, Native.DWMWA_CAPTION_COLOR, ref caption, sizeof(int));
        };
    }
}

/// Reads top to bottom like the Mac's `StatsView`. Every word and number comes from the engine's `StatsPage`.
internal static class StatsView
{
    public const double AnteColumnHeight = 64;

    public static FrameworkElement Build(StatsPage page, double topPadding)
    {
        var sections = Ui.Column(24);
        if (page.Totals is { } totals) Ui.Add(sections, Section(totals.Title, Tiles(totals)), 24);
        if (page.AnteChart is { } chart) Ui.Add(sections, Section(chart.Title, Ante(chart)), 24);
        if (page.Hands is { } hands) Ui.Add(sections, Bars(hands), 24);
        if (page.Jokers is { } jokers) Ui.Add(sections, Bars(jokers), 24);
        Ui.Add(sections, Section(page.Runs.Title, Runs(page.Runs)), 24);
        sections.Margin = new Thickness(24, topPadding, 24, 24);
        return new ScrollViewer
        {
            Content = sections,
            VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Background = Theme.Felt,
        };
    }

    private static FrameworkElement Section(string title, UIElement content) => Ui.Column(12, Ui.Pixel(title, 2, Theme.Chips), content);

    private static UIElement Tiles(StatsTotals totals)
    {
        var grid = new UniformGrid { Columns = 3 };
        foreach (var tile in totals.Tiles)
        {
            var column = Ui.Column(2, Ui.Pixel(tile.Value, 2, tile.IsMoney ? Theme.Money : Theme.Text), Ui.Text(tile.Label, 12, Theme.Muted));
            column.Margin = new Thickness(0, 0, 0, 14);
            grid.Children.Add(column);
        }
        return grid;
    }

    /// One series, so one colour. Every bar carries its own name and value.
    private static FrameworkElement Bars(BarList list)
    {
        var rows = Ui.Column(6);
        foreach (var bar in list.Bars)
        {
            var grid = new Grid { ToolTip = bar.Help, Background = Brushes.Transparent };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(130) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(34) });
            var label = Ui.Text(bar.Label, 12, Theme.Text, wrap: false);
            label.TextTrimming = TextTrimming.CharacterEllipsis;
            label.VerticalAlignment = VerticalAlignment.Center;
            grid.Children.Add(label);
            var track = new ShareBar(bar.Share) { Margin = new Thickness(8, 0, 8, 0), Height = 12 };
            Grid.SetColumn(track, 1);
            grid.Children.Add(track);
            var value = Digits(Ui.Text(bar.Value, 12, Theme.Muted, wrap: false));
            value.HorizontalAlignment = HorizontalAlignment.Right;
            value.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(value, 2);
            grid.Children.Add(value);
            Ui.Add(rows, grid, 6);
        }
        return Section(list.Title, rows);
    }

    private static UIElement Ante(AnteChart chart)
    {
        var columns = new AnteColumns();
        foreach (var column in chart.Columns)
        {
            var number = Digits(Ui.Text(column.Ante, 11, Theme.Muted, wrap: false));
            number.HorizontalAlignment = HorizontalAlignment.Center;
            var bar = new Border
            {
                Background = Theme.Chips,
                CornerRadius = new CornerRadius(4, 4, 0, 0),
                Height = AnteColumnHeight * column.Share,
            };
            var stack = Ui.Column(2, number, bar);
            stack.ToolTip = column.Help;
            stack.Background = Brushes.Transparent;
            columns.Children.Add(stack);
        }
        return Ui.Column(4, columns, Ui.Text(chart.Caption, 11, Theme.Muted));
    }

    private static UIElement Runs(RunList runs)
    {
        var column = Ui.Column(12);
        if (runs.Empty is { } empty) Ui.Add(column, Ui.Text(empty, 13, Theme.Muted), 12);
        var rows = Ui.Column(14);
        foreach (var run in runs.Rows) Ui.Add(rows, RunRow(run), 14);
        if (runs.Rows.Count > 0) Ui.Add(column, rows, 12);
        return column;
    }

    private static UIElement RunRow(RunRow run)
    {
        var title = new TextBlock { FontFamily = Theme.Body, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Bottom };
        title.Inlines.Add(new Run(run.Outcome) { FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = Theme.Text });
        title.Inlines.Add(new Run(" " + run.Deck) { FontSize = 12, Foreground = Theme.Muted });
        var date = Ui.Text(run.Date, 11, Theme.Muted, wrap: false);
        date.VerticalAlignment = VerticalAlignment.Bottom;
        date.Margin = new Thickness(8, 0, 0, 1);
        var heading = new Grid();
        heading.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        heading.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        heading.Children.Add(title);
        Grid.SetColumn(date, 1);
        heading.Children.Add(date);
        return Ui.Column(2, heading, Ui.Coloured(run.Details, 12, Theme.Muted));
    }

    private static TextBlock Digits(TextBlock block)
    {
        Typography.SetNumeralAlignment(block, FontNumeralAlignment.Tabular);
        return block;
    }
}

/// Columns side by side along the bottom, sharing the width up to 28 each, so a long history still fits.
internal sealed class AnteColumns : Panel
{
    private const double MaxWidth28 = 28;
    private const double Gap = 2;

    private double ColumnWidth(double available) =>
        Math.Min(MaxWidth28, Math.Max(0, (available - Gap * (InternalChildren.Count - 1)) / Math.Max(1, InternalChildren.Count)));

    protected override Size MeasureOverride(Size available)
    {
        var width = ColumnWidth(available.Width);
        double height = 0;
        foreach (UIElement child in InternalChildren)
        {
            child.Measure(new Size(width, double.PositiveInfinity));
            height = Math.Max(height, child.DesiredSize.Height);
        }
        return new Size((width + Gap) * InternalChildren.Count - Gap, height);
    }

    protected override Size ArrangeOverride(Size final)
    {
        var width = ColumnWidth(final.Width);
        for (var i = 0; i < InternalChildren.Count; i++)
        {
            var child = InternalChildren[i];
            child.Arrange(new Rect(i * (width + Gap), final.Height - child.DesiredSize.Height, width, child.DesiredSize.Height));
        }
        return final;
    }
}

/// A bar that fills its share of the width it's given, with its far end rounded.
internal sealed class ShareBar : FrameworkElement
{
    private const double Radius = 4;

    public double Share { get; }

    public ShareBar(double share) => Share = share;

    public double Length => Math.Max(2, ActualWidth * Share);

    protected override void OnRender(DrawingContext context)
    {
        var (length, height) = (Length, ActualHeight);
        var radius = Math.Min(Radius, Math.Min(length, height / 2));
        var shape = new StreamGeometry();
        using (var pen = shape.Open())
        {
            pen.BeginFigure(new Point(0, 0), true, true);
            pen.LineTo(new Point(length - radius, 0), false, false);
            pen.ArcTo(new Point(length, radius), new Size(radius, radius), 0, false, SweepDirection.Clockwise, false, false);
            pen.LineTo(new Point(length, height - radius), false, false);
            pen.ArcTo(new Point(length - radius, height), new Size(radius, radius), 0, false, SweepDirection.Clockwise, false, false);
            pen.LineTo(new Point(0, height), false, false);
        }
        shape.Freeze();
        context.DrawGeometry(Theme.Chips, null, shape);
    }
}
