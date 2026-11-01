using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace Balabro.Windows;

/// The sums behind Sources/Balabro/WaitingView.swift. Every frame is a pure function of `time`, so nothing can get stuck mid-animation.
internal static class WaitingMotion
{
    public readonly record struct Tally(int Chips, int Mult, double Fade, double Pulse, double Heat);

    public static Tally ScoreTally(double time)
    {
        var progress = time / 6 % 1;
        // Fades through the reset, so the numbers don't snap back to the start.
        var fade = Math.Min(1, Math.Min(progress, 1 - progress) / 0.05);
        var pulse = 1 + 0.06 * fade * (1 - progress * 8 % 1);
        // Dies down just before the numbers reset, so the loop doesn't cut off a full flame.
        var heat = Math.Min(1, Math.Max(0, (progress - 0.15) / 0.45)) * Math.Min(1, (1 - progress) / 0.08);
        return new Tally(10 + (int)(progress * 90), 1 + (int)(progress * 8), fade, pulse, heat);
    }

    /// Above zero means fire. `rise` is 0 at the top of the tile and 1 at the flames' full reach.
    public static double FlameFuel(double x, double rise, double time, double heat)
    {
        var u = x * 2.2;
        var v = rise * 2.2 - time * 2.4;
        for (var i = 0; i < 3; i++)
        {
            var bend = 0.55 * Math.Sin(v * 1.6 + time * 0.7);
            v += 0.55 * Math.Sin(u * 1.9 - time * 0.5);
            u += bend;
        }
        var outline = heat * (1 - x * x) * 0.7;
        return outline - rise + 0.35 * Math.Sin(u * 3.1) * Math.Sin(v * 1.9);
    }

    public readonly record struct Coin(double ScaleX, double OffsetY, double ShadowWidth);

    public static Coin SpinningCoin(double time)
    {
        var hop = Math.Abs(Math.Sin(time * Math.PI / 1.6));
        return new Coin(Math.Max(0.08, Math.Abs(Math.Cos(time * Math.PI / 1.6))), -8 * hop + 8, 40 - 12 * hop);
    }

    public static double CardOffsetY(int index, double time) =>
        Math.Abs(index - 2.0) * 3 - 10 * Math.Max(0, Math.Sin(time * 3 - index * 0.8));

    public const double ShineWidth = 0.4;

    /// Where the band starts. It starts and ends wholly off the card, then rests, so restarting it can't be seen.
    public static double PackShine(double time)
    {
        var sweep = Math.Min(1, time / 2.4 % 1 / 0.6);
        return -ShineWidth + sweep * (1 + ShineWidth);
    }

    public static double PackAngle(double time) => Math.Sin(time * 2.5) * 5;

    public static string Caption(IReadOnlyList<string> captions, double time) =>
        captions.Count == 0 ? "" : captions[(int)(time / 3.5) % captions.Count];
}

/// What the panel shows while Claude works out a decision. Drawn from shapes because the public repo can't ship the
/// game's art. `tickers` gets one call per frame with the time. Without `moving` the shapes hold still and only the caption changes.
internal static class WaitingView
{
    public static FrameworkElement Build(DecisionKind kind, IReadOnlyList<string> captions, ICollection<Action<double>> tickers, bool moving)
    {
        var caption = Ui.Pixel("", 2, Theme.Chips);
        caption.HorizontalAlignment = HorizontalAlignment.Center;
        tickers.Add(time => caption.Text = WaitingMotion.Caption(captions, time));

        var motion = new List<Action<double>>();
        var drawing = Animation(kind, motion);
        drawing.VerticalAlignment = VerticalAlignment.Bottom;
        drawing.HorizontalAlignment = HorizontalAlignment.Center;
        tickers.Add(time =>
        {
            var t = moving ? time : 0;
            foreach (var step in motion) step(t);
        });

        var picture = new Grid { Height = 92 };
        picture.Children.Add(drawing);
        return new Border { Padding = new Thickness(0, 10, 0, 0), Child = Ui.Column(14, picture, caption) };
    }

    private static FrameworkElement Animation(DecisionKind kind, ICollection<Action<double>> motion) => kind switch
    {
        DecisionKind.PlayHand => ScoreTally(motion),
        DecisionKind.Shop => SpinningCoin(motion),
        DecisionKind.BlindSelect => CardFan(motion),
        _ => WobblingPack(motion),
    };

    /// Blue chips times red mult, climbing like the game's score counter until the tiles catch fire.
    private static FrameworkElement ScoreTally(ICollection<Action<double>> motion)
    {
        var chips = Tile(Theme.Chips, Theme.ChipsDeep, Brush(0x9BDCFF), out var chipsNumber, out var chipsFlames);
        var mult = Tile(Theme.Mult, Theme.MultDeep, Theme.Money, out var multNumber, out var multFlames);
        var pulse = new ScaleTransform();
        mult.RenderTransform = pulse;
        mult.RenderTransformOrigin = new Point(0.5, 0.5);
        var times = Ui.Text("×", 20, Theme.Mult, FontWeights.Heavy, wrap: false);
        times.VerticalAlignment = VerticalAlignment.Center;
        motion.Add(time =>
        {
            var tally = WaitingMotion.ScoreTally(time);
            chipsNumber.Text = tally.Chips.ToString();
            multNumber.Text = tally.Mult.ToString();
            chipsNumber.Opacity = multNumber.Opacity = tally.Fade;
            pulse.ScaleX = pulse.ScaleY = tally.Pulse;
            chipsFlames.Show(time, tally.Heat);
            multFlames.Show(time + 40, tally.Heat);
        });
        return Ui.Row(8, chips, times, mult);
    }

    private static Grid Tile(Brush face, Brush lip, Brush core, out TextBlock number, out PixelFlames flames)
    {
        number = Ui.Pixel("", 3, Theme.Text);
        number.HorizontalAlignment = HorizontalAlignment.Center;
        number.VerticalAlignment = VerticalAlignment.Center;
        flames = new PixelFlames(face, core);
        var tile = new Grid { Width = 72, Height = 44 };
        tile.Children.Add(flames);
        tile.Children.Add(Ui.ChipTile(new Border(), face, lip));
        tile.Children.Add(number);
        return tile;
    }

    private static FrameworkElement SpinningCoin(ICollection<Action<double>> motion)
    {
        var coin = new Grid { Width = 50, Height = 50, RenderTransformOrigin = new Point(0.5, 0.5) };
        coin.Children.Add(new Ellipse { Fill = Theme.MoneyDeep });
        coin.Children.Add(new Ellipse { Fill = Theme.Money, Margin = new Thickness(3) });
        coin.Children.Add(new Ellipse { Stroke = Theme.MoneyDeep, StrokeThickness = 2, Margin = new Thickness(7) });
        var dollar = Ui.Pixel("$", 3, Theme.MoneyDeep);
        dollar.HorizontalAlignment = HorizontalAlignment.Center;
        dollar.VerticalAlignment = VerticalAlignment.Center;
        coin.Children.Add(dollar);
        var spin = new ScaleTransform();
        var hop = new TranslateTransform();
        var moves = new TransformGroup();
        moves.Children.Add(spin);
        moves.Children.Add(hop);
        coin.RenderTransform = moves;
        var shadow = new Ellipse { Fill = Theme.FeltDeep, Height = 6, HorizontalAlignment = HorizontalAlignment.Center };
        motion.Add(time =>
        {
            var state = WaitingMotion.SpinningCoin(time);
            spin.ScaleX = state.ScaleX;
            hop.Y = state.OffsetY;
            shadow.Width = state.ShadowWidth;
        });
        return Ui.Column(6, coin, shadow);
    }

    /// A wave running through a fanned hand of cards.
    private static FrameworkElement CardFan(ICollection<Action<double>> motion)
    {
        var suits = new (string Glyph, Brush Colour)[] { ("♠", Theme.Chips), ("♥", Theme.Mult), ("♣", Theme.Chips), ("♦", Theme.Mult), ("♠", Theme.Chips) };
        var fan = new Grid { Width = 34, Height = 48 };
        for (var i = 0; i < suits.Length; i++)
        {
            var position = i - 2.0;
            var glyph = Ui.Text(suits[i].Glyph, 18, suits[i].Colour, wrap: false);
            glyph.HorizontalAlignment = HorizontalAlignment.Center;
            glyph.VerticalAlignment = VerticalAlignment.Center;
            var card = new Grid { RenderTransformOrigin = new Point(0.5, 0.5) };
            card.Children.Add(new Border { Background = Theme.FeltDeep, CornerRadius = new CornerRadius(4), RenderTransform = new TranslateTransform(0, 2) });
            card.Children.Add(new Border { Background = Theme.Text, CornerRadius = new CornerRadius(4), Child = glyph });
            var shift = new TranslateTransform(position * 22, 0);
            var moves = new TransformGroup();
            moves.Children.Add(new RotateTransform(position * 9));
            moves.Children.Add(shift);
            card.RenderTransform = moves;
            fan.Children.Add(card);
            var index = i;
            motion.Add(time => shift.Y = WaitingMotion.CardOffsetY(index, time));
        }
        return fan;
    }

    /// A booster pack wobbling on the spot, with a shine passing across the foil.
    private static FrameworkElement WobblingPack(ICollection<Action<double>> motion)
    {
        var pack = new Grid
        {
            Width = 50,
            Height = 70,
            Clip = new RectangleGeometry(new Rect(0, 0, 50, 70), 4, 4),
            RenderTransformOrigin = new Point(0.5, 0.5),
        };
        pack.Children.Add(new Rectangle
        {
            Fill = new LinearGradientBrush(Color.FromRgb(0x00, 0x9D, 0xFF), Color.FromRgb(0xFE, 0x5F, 0x55), new Point(0, 0), new Point(1, 1)),
        });
        var band = Color.FromRgb(255, 255, 255);
        var shine = new LinearGradientBrush
        {
            GradientStops =
            {
                new GradientStop(Color.FromArgb(0, band.R, band.G, band.B), 0),
                new GradientStop(Color.FromArgb(115, band.R, band.G, band.B), 0.5),
                new GradientStop(Color.FromArgb(0, band.R, band.G, band.B), 1),
            },
        };
        pack.Children.Add(new Rectangle { Fill = shine });
        pack.Children.Add(new Rectangle { Fill = Theme.Muted, Height = 6, VerticalAlignment = VerticalAlignment.Top });
        pack.Children.Add(new Rectangle { Fill = Theme.Muted, Height = 6, VerticalAlignment = VerticalAlignment.Bottom });
        var question = Ui.Pixel("?", 3, Theme.Text);
        question.HorizontalAlignment = HorizontalAlignment.Center;
        question.VerticalAlignment = VerticalAlignment.Center;
        pack.Children.Add(question);
        var wobble = new RotateTransform();
        pack.RenderTransform = wobble;
        motion.Add(time =>
        {
            var start = WaitingMotion.PackShine(time);
            shine.StartPoint = new Point(start, start);
            shine.EndPoint = new Point(start + WaitingMotion.ShineWidth, start + WaitingMotion.ShineWidth);
            wobble.Angle = WaitingMotion.PackAngle(time);
        });
        return pack;
    }

    private static SolidColorBrush Brush(uint hex)
    {
        var brush = new SolidColorBrush(Color.FromRgb((byte)(hex >> 16), (byte)(hex >> 8), (byte)hex));
        brush.Freeze();
        return brush;
    }
}

/// Square pixels of fire behind a tile. A rising field, bent by a few sine waves so the tongues lick and break off,
/// is cut against an outline that's tallest in the middle. Solid colours, as in the game. It sits in the tile's own
/// bounds and draws above them.
internal sealed class PixelFlames : FrameworkElement
{
    public const double Reach = 48;
    private const double Pixel = 3;

    private readonly Brush _flame;
    private readonly Brush _core;
    private double _time;
    private double _heat;

    public PixelFlames(Brush flame, Brush core)
    {
        (_flame, _core) = (flame, core);
        IsHitTestVisible = false;
        RenderOptions.SetEdgeMode(this, EdgeMode.Aliased);
    }

    public void Show(double time, double heat)
    {
        (_time, _heat) = (time, heat);
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext context)
    {
        if (_heat <= 0) return;
        var columns = (int)(ActualWidth / Pixel);
        var outer = new StreamGeometry();
        var inner = new StreamGeometry();
        using (var outerShape = outer.Open())
        using (var innerShape = inner.Open())
        {
            for (var column = 0; column < columns; column++)
            {
                var x = (column + 0.5) / columns * 2 - 1;
                for (var row = 0; row <= (int)(Reach / Pixel); row++)
                {
                    var top = row * Pixel;
                    var fuel = WaitingMotion.FlameFuel(x, (Reach - top - Pixel) / Reach, _time, _heat);
                    if (fuel <= 0) continue;
                    AddSquare(fuel > 0.5 ? innerShape : outerShape, column * Pixel, top - Reach);
                }
            }
        }
        outer.Freeze();
        inner.Freeze();
        context.DrawGeometry(_flame, null, outer);
        context.DrawGeometry(_core, null, inner);
    }

    private static void AddSquare(StreamGeometryContext shape, double x, double y)
    {
        shape.BeginFigure(new Point(x, y), true, true);
        shape.LineTo(new Point(x + Pixel, y), false, false);
        shape.LineTo(new Point(x + Pixel, y + Pixel), false, false);
        shape.LineTo(new Point(x, y + Pixel), false, false);
    }
}
