using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;

namespace Balabro.Windows;

/// Coloured text the player can drag across to select and copy, as `.textSelection(.enabled)` gives the Mac's panel.
/// It lays out like the `TextBlock` it replaces, so it fits where one fits.
internal sealed class SelectableText : RichTextBox
{
    /// Raised when a drag ends with some text selected.
    public static readonly RoutedEvent TextSelectedEvent =
        EventManager.RegisterRoutedEvent("TextSelected", RoutingStrategy.Bubble, typeof(RoutedEventHandler), typeof(SelectableText));

    private static readonly ControlTemplate Bare = MakeTemplate();

    private readonly TextBlock _twin;

    public SelectableText(string markdown, double size, Brush brush, FontWeight? weight = null)
    {
        _twin = Ui.Coloured(markdown, size, brush, weight);
        Template = Bare;
        IsReadOnly = true;
        IsUndoEnabled = false;
        IsTabStop = false;
        AllowDrop = false;
        FocusVisualStyle = null;
        Background = Brushes.Transparent;
        BorderThickness = new Thickness(0);
        Padding = new Thickness(0);
        Foreground = brush;
        FontFamily = Theme.Body;
        FontSize = size;
        FontWeight = weight ?? FontWeights.Normal;
        SelectionBrush = Theme.Chips;
        IsInactiveSelectionHighlightEnabled = true;

        var paragraph = new Paragraph { Margin = new Thickness(0), LineHeight = _twin.LineHeight };
        paragraph.Inlines.AddRange(ColouredText.Inlines(markdown));
        Document = new FlowDocument(paragraph) { PagePadding = new Thickness(0) };

        DataObject.AddCopyingHandler(this, (_, e) => e.DataObject.SetData(DataFormats.UnicodeText, ColouredText.ForClipboard(Selection.Text)));
        PreviewMouseLeftButtonDown += (_, e) =>
        {
            BeginDrag(e.GetPosition(this));
            CaptureMouse();
            e.Handled = true;
        };
        PreviewMouseMove += (_, e) =>
        {
            if (!_dragging || e.LeftButton != MouseButtonState.Pressed) return;
            ExtendDrag(e.GetPosition(this));
            e.Handled = true;
        };
        PreviewMouseLeftButtonUp += (_, e) =>
        {
            if (!_dragging) return;
            ReleaseMouseCapture();
            EndDrag();
            e.Handled = true;
        };
    }

    // A RichTextBox only starts its own drag once it has keyboard focus, which the panel can't get while it's inactive
    // over the game. So the drag is done here, and the panel takes the keyboard only if there's a selection to copy.
    private bool _dragging;
    private TextPointer? _dragStart;

    internal void BeginDrag(Point at)
    {
        _dragging = true;
        _dragStart = GetPositionFromPoint(at, snapToText: true);
        if (_dragStart is not null) Selection.Select(_dragStart, _dragStart);
    }

    internal void ExtendDrag(Point to)
    {
        if (_dragStart is not null && GetPositionFromPoint(to, snapToText: true) is { } end) Selection.Select(_dragStart, end);
    }

    internal void EndDrag()
    {
        _dragging = false;
        if (!Selection.IsEmpty) RaiseEvent(new RoutedEventArgs(TextSelectedEvent, this));
    }

    /// The default template's own `ScrollViewer` would swallow the mouse wheel before the panel's could scroll.
    private static ControlTemplate MakeTemplate()
    {
        var template = new ControlTemplate(typeof(SelectableText)) { VisualTree = new FrameworkElementFactory(typeof(Decorator), "PART_ContentHost") };
        template.Seal();
        return template;
    }

    public string Text => ColouredText.ForClipboard(new TextRange(Document.ContentStart, Document.ContentEnd).Text.TrimEnd('\r', '\n'));

    /// The width of the text on one line.
    public double NaturalWidth
    {
        get
        {
            _twin.TextWrapping = TextWrapping.NoWrap;
            _twin.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var width = _twin.DesiredSize.Width;
            _twin.TextWrapping = TextWrapping.Wrap;
            return width;
        }
    }

    /// A `RichTextBox` keeps its text this far in from each side, even with no padding (measured at sizes 13 and 15).
    /// Laying it out this much wider and further left puts each line where a `TextBlock` would.
    private const double Inset = 5;

    /// A `RichTextBox` otherwise fills the width it's offered, which would stretch the question bubble across the panel.
    /// Text on one line takes its own width, and wrapped text takes all of it.
    protected override Size MeasureOverride(Size constraint)
    {
        var width = Math.Min(constraint.Width, Math.Ceiling(NaturalWidth) + 1);
        var inner = base.MeasureOverride(new Size(width + 2 * Inset, double.PositiveInfinity));
        return new Size(width, inner.Height);
    }

    protected override Size ArrangeOverride(Size final)
    {
        if (VisualChildrenCount > 0 && GetVisualChild(0) is UIElement content)
            content.Arrange(new Rect(-Inset, 0, final.Width + 2 * Inset, final.Height));
        return final;
    }
}
