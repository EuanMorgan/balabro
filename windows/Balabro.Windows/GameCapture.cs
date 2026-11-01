using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;

namespace Balabro.Windows;

/// Screenshots of the player's Balatro window, for the booster pack the save can't show.
internal static class GameCapture
{
    private const int LongEdge = 1568;

    /// The largest visible, non-minimised window titled "Balatro" that isn't one of Balabro's own game copies,
    /// downscaled so the long edge is at most 1568 px, as PNG. Null when there's no such window or the capture is blank.
    public static byte[]? CapturePng()
    {
        var window = FindGameWindow();
        if (window == IntPtr.Zero)
        {
            Log.Write("Screenshot: no Balatro window");
            return null;
        }
        if (!Native.GetClientRect(window, out var client) || client.Right <= 0 || client.Bottom <= 0) return null;
        // No alpha: GDI leaves it zero, which would make the PNG transparent.
        using var full = new Bitmap(client.Right, client.Bottom, PixelFormat.Format32bppRgb);
        using (var graphics = Graphics.FromImage(full))
        {
            var dc = graphics.GetHdc();
            try
            {
                if (!Native.PrintWindow(window, dc, Native.PW_CLIENTONLY | Native.PW_RENDERFULLCONTENT))
                {
                    Log.Write("Screenshot: PrintWindow failed");
                    return null;
                }
            }
            finally { graphics.ReleaseHdc(dc); }
        }
        if (IsBlank(full))
        {
            Log.Write("Screenshot: the capture was blank");
            return null;
        }
        var scale = Math.Min(1.0, (double)LongEdge / Math.Max(full.Width, full.Height));
        using var scaled = Resize(full, scale);
        using var png = new MemoryStream();
        scaled.Save(png, ImageFormat.Png);
        Log.Write($"Screenshot: {full.Width}x{full.Height} scaled to {scaled.Width}x{scaled.Height}, {png.Length} bytes");
        return png.ToArray();
    }

    public static IntPtr FindGameWindow()
    {
        IntPtr best = IntPtr.Zero;
        long bestArea = 0;
        Native.EnumWindows((hwnd, _) =>
        {
            if (!Native.IsWindowVisible(hwnd) || Native.IsIconic(hwnd) || Native.WindowTitle(hwnd) != "Balatro") return true;
            if (IsBalabroCopy(hwnd)) return true;
            Native.GetWindowRect(hwnd, out var rect);
            long area = (long)(rect.Right - rect.Left) * (rect.Bottom - rect.Top);
            if (area > bestArea) (best, bestArea) = (hwnd, area);
            return true;
        }, IntPtr.Zero);
        return best;
    }

    /// The scorer's and the pilot's copies of the game run from the data folder.
    public static bool IsBalabroCopy(IntPtr hwnd)
    {
        var path = Native.ProcessPath(hwnd);
        return path.Length > 0 && path.StartsWith(Paths.DataFolder + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    /// A window that can't be drawn, such as one on exclusive fullscreen, comes back one flat colour.
    private static bool IsBlank(Bitmap bitmap)
    {
        var data = bitmap.LockBits(new Rectangle(0, 0, bitmap.Width, bitmap.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppRgb);
        try
        {
            unsafe
            {
                var first = *(int*)data.Scan0 & 0xFFFFFF;
                var stepX = Math.Max(1, bitmap.Width / 64);
                var stepY = Math.Max(1, bitmap.Height / 64);
                for (var y = 0; y < bitmap.Height; y += stepY)
                {
                    var row = (int*)((byte*)data.Scan0 + (long)y * data.Stride);
                    for (var x = 0; x < bitmap.Width; x += stepX)
                        if ((row[x] & 0xFFFFFF) != first) return false;
                }
                return true;
            }
        }
        finally { bitmap.UnlockBits(data); }
    }

    private static Bitmap Resize(Bitmap source, double scale)
    {
        var width = Math.Max(1, (int)Math.Round(source.Width * scale));
        var height = Math.Max(1, (int)Math.Round(source.Height * scale));
        var result = new Bitmap(width, height, PixelFormat.Format24bppRgb);
        using var graphics = Graphics.FromImage(result);
        graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
        graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
        graphics.CompositingQuality = CompositingQuality.HighQuality;
        graphics.DrawImage(source, new Rectangle(0, 0, width, height));
        return result;
    }
}
