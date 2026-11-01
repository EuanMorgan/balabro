using System;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;

namespace Balabro.Windows;

/// Balatro's palette, as in Sources/Balabro/Theme.swift: dark felt, with chip blue and mult red as the only accents.
internal static class Theme
{
    public static readonly SolidColorBrush Felt = Brush(0x374244);
    public static readonly SolidColorBrush FeltRaised = Brush(0x4F6367);
    public static readonly SolidColorBrush FeltDeep = Brush(0x2C3536);
    public static readonly SolidColorBrush Text = Brush(0xFFFFFF);
    public static readonly SolidColorBrush TextSoft = Brush(0xFFFFFF, 0.88);
    public static readonly SolidColorBrush Muted = Brush(0xBFC7D5);
    public static readonly SolidColorBrush MutedFaint = Brush(0xBFC7D5, 0.5);
    public static readonly SolidColorBrush Chips = Brush(0x009DFF);
    public static readonly SolidColorBrush ChipsDeep = Brush(0x006EB3);
    public static readonly SolidColorBrush Mult = Brush(0xFE5F55);
    public static readonly SolidColorBrush MultDeep = Brush(0xB2433C);
    public static readonly SolidColorBrush Money = Brush(0xF3B958);
    public static readonly SolidColorBrush MoneyDeep = Brush(0xAA813E);

    /// Advice body text stays in the system font: long sentences read better there than in a pixel face.
    public static readonly FontFamily Body = SystemFonts.MessageFontFamily;

    /// The game's m6x11plus once `hello` names it, else Consolas.
    public static FontFamily Pixel { get; private set; } = new("Consolas");
    public static bool HasPixelFont { get; private set; }

    public static void LoadPixelFont(string? path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return;
        try
        {
            var typeface = new GlyphTypeface(new Uri(path));
            var name = typeface.FamilyNames.Values.FirstOrDefault() ?? "m6x11plus";
            var folder = new Uri(Path.GetDirectoryName(path)! + Path.DirectorySeparatorChar);
            Pixel = new FontFamily(folder, "./#" + name);
            HasPixelFont = true;
            Log.Write($"Loaded the pixel font {name} from {path}");
        }
        catch (Exception error) when (error is IOException or ArgumentException or NotSupportedException or UriFormatException)
        {
            Log.Write($"Couldn't load the pixel font from {path}: {error.Message}");
        }
    }

    /// Pixel fonts blur at fractional sizes, so sizes are whole multiples of the font's 11 px design size.
    public static double PixelSize(int multiple) => 11 * multiple;

    private static SolidColorBrush Brush(uint hex, double opacity = 1)
    {
        var brush = new SolidColorBrush(Color.FromArgb((byte)Math.Round(opacity * 255), (byte)(hex >> 16), (byte)(hex >> 8), (byte)hex));
        brush.Freeze();
        return brush;
    }
}

/// Text in the game's colours: red and blue suits and yellow cash, with inline markdown (bold, italic, code).
internal static partial class ColouredText
{
    /// Undoes the wider gap `Colour` leaves after a suit, so copied cards read `J♦ 4♠`.
    public static string ForClipboard(string text) => WideSuitGap().Replace(text, "$1 ");

    public static Inline[] Inlines(string markdown)
    {
        var result = new System.Collections.Generic.List<Inline>();
        foreach (var (text, bold, italic, code) in Markdown(markdown))
        {
            foreach (var piece in Colour(text))
            {
                var run = new Run(piece.Text);
                if (piece.Brush is not null) run.Foreground = piece.Brush;
                if (bold) run.FontWeight = FontWeights.Bold;
                if (italic) run.FontStyle = FontStyles.Italic;
                if (code) run.FontFamily = new FontFamily("Consolas");
                result.Add(run);
            }
        }
        return result.ToArray();
    }

    private static System.Collections.Generic.IEnumerable<(string Text, bool Bold, bool Italic, bool Code)> Markdown(string text)
    {
        var position = 0;
        foreach (Match match in InlineMarkdown().Matches(text))
        {
            if (match.Index > position) yield return (text[position..match.Index], false, false, false);
            if (match.Groups["bold"].Success) yield return (match.Groups["bold"].Value, true, false, false);
            else if (match.Groups["bold2"].Success) yield return (match.Groups["bold2"].Value, true, false, false);
            else if (match.Groups["italic"].Success) yield return (match.Groups["italic"].Value, false, true, false);
            else if (match.Groups["code"].Success) yield return (match.Groups["code"].Value, false, false, true);
            position = match.Index + match.Length;
        }
        if (position < text.Length) yield return (text[position..], false, false, false);
    }

    private static System.Collections.Generic.IEnumerable<(string Text, Brush? Brush)> Colour(string text)
    {
        var position = 0;
        foreach (Match match in SuitOrCash().Matches(text))
        {
            if (match.Index > position) yield return (text[position..match.Index], null);
            if (match.Value[0] == '$') yield return (match.Value, Theme.Money);
            else
            {
                var brush = "♥♦♡♢".Contains(match.Value[0]) ? Theme.Mult : Theme.Chips;
                yield return (match.Value[..1], brush);
                // A normal space leaves one card's suit touching the next card's rank.
                if (match.Value.Length > 1) yield return ("  ", null);
            }
            position = match.Index + match.Length;
        }
        if (position < text.Length) yield return (text[position..], null);
    }

    [GeneratedRegex(@"\*\*(?<bold>.+?)\*\*|__(?<bold2>.+?)__|(?<![\w*])\*(?<italic>[^*\s][^*]*?)\*(?![\w*])|`(?<code>[^`]+)`")]
    private static partial Regex InlineMarkdown();

    [GeneratedRegex(@"[♥♦♡♢♠♣♤♧] ?|\$\d+(?:,\d+)*")]
    private static partial Regex SuitOrCash();

    [GeneratedRegex("([♥♦♡♢♠♣♤♧])\u2002\u2009")]
    private static partial Regex WideSuitGap();
}
