using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shell;

namespace Balabro.Windows;

/// Small builders for the panel's pieces, so the views read top to bottom like the Mac's SwiftUI.
internal static class Ui
{
    public static TextBlock Text(string text, double size, Brush brush, FontWeight? weight = null, bool wrap = true) => new()
    {
        Text = text,
        FontFamily = Theme.Body,
        FontSize = size,
        FontWeight = weight ?? FontWeights.Normal,
        Foreground = brush,
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
    };

    /// Markdown-ish text with suits and cash in the game's colours.
    public static TextBlock Coloured(string markdown, double size, Brush brush, FontWeight? weight = null)
    {
        var block = Text("", size, brush, weight);
        block.Inlines.AddRange(ColouredText.Inlines(markdown));
        block.LineHeight = size * 1.35;
        return block;
    }

    public static TextBlock Pixel(string text, int multiple, Brush brush)
    {
        var block = new TextBlock
        {
            Text = text,
            FontFamily = Theme.Pixel,
            FontSize = Theme.PixelSize(multiple),
            Foreground = brush,
            TextWrapping = TextWrapping.NoWrap,
        };
        if (Theme.HasPixelFont)
        {
            TextOptions.SetTextFormattingMode(block, TextFormattingMode.Display);
            TextOptions.SetTextRenderingMode(block, TextRenderingMode.Aliased);
        }
        else block.FontWeight = FontWeights.SemiBold;
        return block;
    }

    /// The game's button: a face with a darker lip under it.
    public static Border ChipTile(UIElement child, Brush? face = null, Brush? lip = null, Thickness? padding = null) => new()
    {
        Background = lip ?? Theme.ChipsDeep,
        CornerRadius = new CornerRadius(5),
        Child = new Border
        {
            Background = face ?? Theme.Chips,
            CornerRadius = new CornerRadius(5),
            Margin = new Thickness(0, 0, 0, 2),
            Padding = padding ?? new Thickness(6, 0, 6, 0),
            Child = child,
        },
    };

    public static UIElement ChipButton(string title, Action action)
    {
        var label = Pixel(title, 1, Theme.Text);
        label.VerticalAlignment = VerticalAlignment.Center;
        return Clickable(ChipTile(label, padding: new Thickness(8, 4, 8, 4)), action);
    }

    /// A click target with no chrome. It works in the title row too, where the rest of the row drags the panel.
    public static FrameworkElement Clickable(UIElement content, Action action, string? tooltip = null)
    {
        var target = new Border { Background = Brushes.Transparent, Child = content, Cursor = Cursors.Hand, ToolTip = tooltip };
        WindowChrome.SetIsHitTestVisibleInChrome(target, true);
        target.MouseLeftButtonDown += (_, e) =>
        {
            target.CaptureMouse();
            e.Handled = true;
        };
        target.MouseLeftButtonUp += (_, e) =>
        {
            if (!target.IsMouseCaptured) return;
            target.ReleaseMouseCapture();
            e.Handled = true;
            var point = e.GetPosition(target);
            if (point.X >= 0 && point.Y >= 0 && point.X <= target.ActualWidth && point.Y <= target.ActualHeight) action();
        };
        return target;
    }

    public static StackPanel Column(double spacing, params UIElement?[] children)
    {
        var panel = new StackPanel { Orientation = Orientation.Vertical };
        foreach (var child in children) Add(panel, child, spacing);
        return panel;
    }

    public static void Add(StackPanel panel, UIElement? child, double spacing)
    {
        if (child is null) return;
        if (panel.Children.Count > 0 && child is FrameworkElement element)
        {
            var margin = element.Margin;
            element.Margin = panel.Orientation == Orientation.Vertical
                ? new Thickness(margin.Left, margin.Top + spacing, margin.Right, margin.Bottom)
                : new Thickness(margin.Left + spacing, margin.Top, margin.Right, margin.Bottom);
        }
        panel.Children.Add(child);
    }

    public static StackPanel Row(double spacing, params UIElement?[] children)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var child in children) Add(panel, child, spacing);
        return panel;
    }

    /// Segoe's icon font: Fluent on Windows 11, MDL2 on Windows 10, at the same code points.
    public static TextBlock Icon(string glyph, double size, Brush brush) => new()
    {
        Text = glyph,
        FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
        FontSize = size,
        Foreground = brush,
        VerticalAlignment = VerticalAlignment.Center,
    };
}
