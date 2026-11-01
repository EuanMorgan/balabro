using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.ExceptionServices;
using System.Threading;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Balabro.Windows.Tests;

internal static class Wpf
{
    /// WPF's objects need a thread of their own, with a dispatcher that ends with it.
    public static void Run(Action test)
    {
        ExceptionDispatchInfo? failure = null;
        var thread = new Thread(() =>
        {
            try { test(); }
            catch (Exception error) { failure = ExceptionDispatchInfo.Capture(error); }
            finally { Dispatcher.CurrentDispatcher.InvokeShutdown(); }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        failure?.Throw();
    }

    /// Lays out a view with no window, as `Previews.Stats` does.
    public static void Arrange(FrameworkElement view, double width, double height)
    {
        view.Measure(new Size(width, height));
        view.Arrange(new Rect(0, 0, width, height));
        view.UpdateLayout();
    }

    public static IEnumerable<T> All<T>(DependencyObject root) where T : DependencyObject
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T found) yield return found;
            foreach (var deeper in All<T>(child)) yield return deeper;
        }
    }

    /// How many pixels of the image are exactly this colour.
    public static int CountPixels(BitmapSource image, SolidColorBrush brush, int fromY = 0, int? toY = null)
    {
        var pixels = new byte[image.PixelWidth * image.PixelHeight * 4];
        image.CopyPixels(pixels, image.PixelWidth * 4, 0);
        var colour = brush.Color;
        var count = 0;
        for (var y = fromY; y < (toY ?? image.PixelHeight); y++)
        for (var x = 0; x < image.PixelWidth; x++)
        {
            var at = (y * image.PixelWidth + x) * 4;
            if (pixels[at] == colour.B && pixels[at + 1] == colour.G && pixels[at + 2] == colour.R && pixels[at + 3] == 255) count++;
        }
        return count;
    }

    public static byte[] Pixels(BitmapSource image)
    {
        var pixels = new byte[image.PixelWidth * image.PixelHeight * 4];
        image.CopyPixels(pixels, image.PixelWidth * 4, 0);
        return pixels;
    }

    public static string Golden(string name) =>
        System.IO.File.ReadAllText(System.IO.Path.Combine(AppContext.BaseDirectory, "wire", name + ".json")).ReplaceLineEndings(" ");
}
