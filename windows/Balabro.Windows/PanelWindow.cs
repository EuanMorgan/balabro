using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Shell;
using System.Windows.Threading;

namespace Balabro.Windows;

/// The always-on-top coaching panel, laid out as Sources/Balabro/OverlayView.swift:
///
/// ```
/// ┌───────────────────────────────┐
/// │ Ante 3 · Big Blind        ▶∞↻●│  headline in the pixel font, play for me, naneinf, refresh, status light
/// │ Do this now  Saw your screen  │
/// │ 1 Discard J♦ 4♠ 3♥ 2♥         │
/// │ Two Pair      [46] × [2] = 92 │
/// │           Leaves 208 to score │
/// │ Why ▸ Going for a Straight    │  everything from here scrolls
/// │ Lesson 12                     │
/// │ ───────────────────────────── │
/// │ [why keep the 6?]             │
/// │ [ Ask about this…  Ctrl+Alt+Space ]
/// └───────────────────────────────┘
/// ```
///
/// It never takes focus from the game (`WS_EX_NOACTIVATE`), except while the player types a question.
internal sealed class PanelWindow : Window
{
    private readonly Action<string> _send;
    private IntPtr _hwnd;

    private CoachView? _coach;
    private PilotView? _pilot;
    private string? _engineProblem;
    public Action? RestartEngine { get; set; }

    private bool _showWhy;
    private (int Count, int ReplyLength) _lastThread;
    private bool _hadAdvice;

    private readonly Grid _coachLayout = new();
    private readonly Border _header = new() { Padding = new Thickness(16, 14, 16, 12) };
    private readonly Border _banner = new() { Margin = new Thickness(12, 0, 12, 10), Visibility = Visibility.Collapsed };
    private readonly Grid _body = new() { ClipToBounds = true };
    private readonly ContentControl _pinned = new();
    private readonly ScrollViewer _scroll = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    private readonly TextBlock _queued = Ui.Text("", 11, Theme.Muted, wrap: false);
    private readonly TextBox _question = new();
    private readonly TextBlock _questionPlaceholder = Ui.Text("Ask about this…", 13, Theme.Muted, wrap: false);
    private readonly TextBlock _hint = Ui.Text("Ctrl+Alt+Space", 11, Theme.Muted, FontWeights.Medium, wrap: false);
    private readonly Border _pilotLayout = new() { Padding = new Thickness(16), Visibility = Visibility.Collapsed };

    // Everything that moves (thinking dots, captions, clocks) ticks from one timer, and is dropped at each redraw.
    private readonly List<Action<double>> _tickers = new();
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(50) };
    private readonly DateTime _epoch = DateTime.UtcNow;

    private IntPtr _returnFocusTo;
    private bool _typing;
    private bool _hotKeyRegistered;
    private const int HotKeyId = 0xB1B;

    public bool PilotIsActive => _pilot is { Status: not PilotStatus.Idle };

    public PanelWindow(Action<string> send)
    {
        _send = send;
        Title = "Balabro";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.CanResize;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        MinWidth = 280;
        MinHeight = 240;
        Width = 320;
        Height = 500;
        UseLayoutRounding = true;
        SnapsToDevicePixels = true;
        Background = Theme.FeltDeep;
        FontFamily = Theme.Body;
        WindowChrome.SetWindowChrome(this, new WindowChrome
        {
            CaptionHeight = 44,
            ResizeBorderThickness = new Thickness(6),
            GlassFrameThickness = new Thickness(0),
            CornerRadius = new CornerRadius(0),
            UseAeroCaptionButtons = false,
        });

        BuildLayout();
        SourceInitialized += OnSourceInitialized;
        Closed += (_, _) => OnClosed();
        Deactivated += (_, _) => { if (_typing) StopTyping(returnFocus: false); };
        _body.SizeChanged += (_, e) => { if (Math.Abs(e.PreviousSize.Height - e.NewSize.Height) > 0.5 || Math.Abs(e.PreviousSize.Width - e.NewSize.Width) > 0.5) Render(); };
        _header.SizeChanged += (_, _) => UpdateCaption();
        _timer.Tick += (_, _) => Tick();
        _timer.Start();
        Render();
    }

    // ---- Layout that lives as long as the window ----

    private void BuildLayout()
    {
        var face = new Border
        {
            Background = Theme.Felt,
            BorderBrush = Theme.FeltRaised,
            BorderThickness = new Thickness(1.5),
            CornerRadius = new CornerRadius(8),
            Margin = new Thickness(0, 0, 0, 4),
        };
        var stack = new Grid();
        stack.Children.Add(_coachLayout);
        stack.Children.Add(_pilotLayout);
        face.Child = stack;
        Content = face;

        foreach (var height in new[] { GridLength.Auto, GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto, GridLength.Auto })
            _coachLayout.RowDefinitions.Add(new RowDefinition { Height = height });
        Place(_coachLayout, _header, 0);
        Place(_coachLayout, _banner, 1);
        Place(_coachLayout, _body, 2);
        _queued.Margin = new Thickness(16, 0, 16, 6);
        _queued.TextTrimming = TextTrimming.CharacterEllipsis;
        Place(_coachLayout, _queued, 3);
        Place(_coachLayout, QuestionField(), 4);

        _body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _body.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Place(_body, _pinned, 0);
        Place(_body, _scroll, 1);
    }

    private static void Place(Grid grid, UIElement element, int row)
    {
        Grid.SetRow(element, row);
        grid.Children.Add(element);
    }

    private UIElement QuestionField()
    {
        _question.Background = Brushes.Transparent;
        _question.BorderThickness = new Thickness(0);
        _question.Foreground = Theme.Text;
        _question.CaretBrush = Theme.Text;
        _question.SelectionBrush = Theme.Chips;
        _question.FontFamily = Theme.Body;
        _question.FontSize = 13;
        _question.Padding = new Thickness(0);
        _question.VerticalContentAlignment = VerticalAlignment.Center;
        _question.FocusVisualStyle = null;
        _question.TextChanged += (_, _) => _questionPlaceholder.Visibility = _question.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        _question.PreviewKeyDown += OnQuestionKey;
        _questionPlaceholder.IsHitTestVisible = false;
        _questionPlaceholder.VerticalAlignment = VerticalAlignment.Center;
        _hint.Foreground = new SolidColorBrush(Color.FromArgb(178, 0xBF, 0xC7, 0xD5));
        _hint.VerticalAlignment = VerticalAlignment.Center;
        _hint.Margin = new Thickness(8, 0, 0, 0);

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(_questionPlaceholder);
        grid.Children.Add(_question);
        Grid.SetColumn(_hint, 1);
        grid.Children.Add(_hint);
        var box = new Border
        {
            Background = Theme.FeltDeep,
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10, 9, 10, 9),
            Margin = new Thickness(10),
            Child = grid,
            Cursor = Cursors.IBeam,
        };
        box.PreviewMouseLeftButtonDown += (_, _) => { if (!_typing) StartTyping(); };
        return box;
    }

    // ---- Incoming views ----

    public void Show(CoachView view)
    {
        if (view.Advice is null) _showWhy = false;
        _coach = view;
        Render();
    }

    public void Show(PilotView view)
    {
        _pilot = view;
        Render();
    }

    public void ShowEngineProblem(string? message)
    {
        _engineProblem = message;
        Render();
    }

    // ---- Drawing ----

    private void Render()
    {
        _tickers.Clear();
        if (PilotIsActive && _engineProblem is null)
        {
            _coachLayout.Visibility = Visibility.Collapsed;
            _pilotLayout.Visibility = Visibility.Visible;
            _pilotLayout.Child = PilotContent(_pilot!);
        }
        else
        {
            _pilotLayout.Visibility = Visibility.Collapsed;
            _coachLayout.Visibility = Visibility.Visible;
            RenderCoach();
        }
        Tick();
    }

    private void RenderCoach()
    {
        var view = _coach;
        _header.Child = Header(view);
        _banner.Child = Banner(view);
        _banner.Visibility = _banner.Child is null ? Visibility.Collapsed : Visibility.Visible;
        _queued.Text = view?.QueuedQuestion is { } queued ? $"Next: {queued}" : "";
        _queued.Visibility = view?.QueuedQuestion is null ? Visibility.Collapsed : Visibility.Visible;
        _hint.Text = _hotKeyRegistered ? "Ctrl+Alt+Space" : "Click the box to ask";

        var pinned = PinnedSteps(view);
        var content = Padded(ScrolledContent(view));
        // The steps stay pinned while there's room for the rest under them. Otherwise everything scrolls together.
        var fits = true;
        if (pinned is not null && _body.ActualHeight > 0)
        {
            pinned.Measure(new Size(_body.ActualWidth, double.PositiveInfinity));
            fits = pinned.DesiredSize.Height + 80 <= _body.ActualHeight;
        }
        if (fits)
        {
            _pinned.Content = pinned;
            _scroll.Content = content;
        }
        else
        {
            _pinned.Content = null;
            _scroll.Content = Ui.Column(0, pinned, content);
        }

        // A new decision's advice starts at the top; the offset left from the last one means nothing now.
        var hasAdvice = view?.Advice is not null || view?.Thread.Count > 0;
        if (hasAdvice && !_hadAdvice) _scroll.ScrollToTop();
        _hadAdvice = hasAdvice;
        var thread = (view?.Thread.Count ?? 0, view?.Thread.LastOrDefault()?.Reply.Length ?? 0);
        if (thread != _lastThread && thread.Item1 > 0) Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () => _scroll.ScrollToEnd());
        _lastThread = thread;
    }

    private UIElement Header(CoachView? view)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var headline = Ui.Pixel(string.IsNullOrEmpty(view?.Headline) ? "Balabro" : view!.Headline, 2, Theme.Text);
        headline.TextWrapping = TextWrapping.Wrap;
        headline.TextTrimming = TextTrimming.CharacterEllipsis;
        headline.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
        headline.LineHeight = 24;
        headline.MaxHeight = 48;
        headline.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(headline);

        var goal = view?.Goal ?? CoachGoal.Win;
        var buttons = Ui.Row(10);
        buttons.VerticalAlignment = VerticalAlignment.Center;
        buttons.Margin = new Thickness(8, 0, 0, 0);
        if (view is not null)
        {
            Ui.Add(buttons, Ui.Clickable(PlayGlyph(), () => _send(Wire.PlayForMe(goal)),
                "Play for me: Balabro plays a run by itself in its own copy of the game, as fast as it can. Your own run and stats aren't touched"), 10);
            var infinity = Ui.Text("∞", 17, goal == CoachGoal.Naneinf ? Theme.Money : Theme.Muted, FontWeights.Bold, wrap: false);
            infinity.Margin = new Thickness(0, -3, 0, 0);
            Ui.Add(buttons, Ui.Clickable(infinity, () => _send(Wire.SetGoal(goal == CoachGoal.Naneinf ? CoachGoal.Win : CoachGoal.Naneinf)),
                goal == CoachGoal.Naneinf ? "Chasing naneinf. Click to go back to coaching for the win" : "Chase naneinf: coach for the biggest score the game can show"), 10);
            if (view.Status != CoachStatus.WaitingForRun)
                Ui.Add(buttons, Ui.Clickable(Ui.Icon("", 12, Theme.Muted), () => _send(Wire.Refresh()), "Look at the screen again and redo the steps"), 10);
        }
        Ui.Add(buttons, new Ellipse { Width = 8, Height = 8, Fill = StatusColour(view?.Status), VerticalAlignment = VerticalAlignment.Center }, 10);
        Grid.SetColumn(buttons, 1);
        grid.Children.Add(buttons);
        return grid;
    }

    private static UIElement PlayGlyph() => new Path
    {
        Data = Geometry.Parse("M 0,0 L 9,5.5 L 0,11 Z"),
        Fill = Theme.Muted,
        VerticalAlignment = VerticalAlignment.Center,
        Margin = new Thickness(0, 1, 0, 0),
    };

    private static Brush StatusColour(CoachStatus? status) => status switch
    {
        CoachStatus.LookingAtPack or CoachStatus.Thinking or CoachStatus.Answering => Theme.Chips,
        CoachStatus.Ready => Theme.Money,
        _ => Theme.MutedFaint,
    };

    private UIElement? Banner(CoachView? view)
    {
        if (_engineProblem is { } stopped)
            return ProblemBanner(stopped, "Restart", () => RestartEngine?.Invoke());
        if (view?.Problem is { } problem)
            return ProblemBanner(problem.Message, view.CanRetry ? "Retry" : null, () => _send(Wire.Retry()));
        return null;
    }

    private static UIElement ProblemBanner(string message, string? action, Action onAction)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Ui.Text(message, 12, Theme.Text, FontWeights.Medium));
        if (action is not null)
        {
            var button = (FrameworkElement)Ui.ChipButton(action, onAction);
            button.Margin = new Thickness(10, 0, 0, 0);
            button.VerticalAlignment = VerticalAlignment.Top;
            Grid.SetColumn(button, 1);
            grid.Children.Add(button);
        }
        return new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(217, 0xFE, 0x5F, 0x55)),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10),
            Child = grid,
        };
    }

    private UIElement Padded(UIElement? inner)
    {
        if (inner is FrameworkElement element) element.Margin = new Thickness(16, 0, 16, 12);
        return inner ?? new Border();
    }

    private FrameworkElement? PinnedSteps(CoachView? view)
    {
        if (view?.Advice is not { DoNow.Count: > 0 } advice) return null;
        var title = new Grid();
        title.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        title.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        title.Children.Add(Ui.Pixel("Do this now", 2, Theme.Chips));
        if (view.SawScreen)
        {
            var saw = Ui.Row(4, Ui.Icon("", 11, Theme.Muted), Ui.Text("Saw your screen", 11, Theme.Muted, FontWeights.Medium, wrap: false));
            saw.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(saw, 1);
            title.Children.Add(saw);
        }
        var column = Ui.Column(10, title);
        for (var i = 0; i < advice.DoNow.Count; i++) Ui.Add(column, StepRow(i + 1, advice.DoNow[i]), 10);
        var width = Math.Max(100, _body.ActualWidth - 32);
        foreach (var scored in view.Score) Ui.Add(column, ScoreRow(scored, width), 10);
        column.Margin = new Thickness(16, 0, 16, 14);
        return column;
    }

    private static UIElement StepRow(int number, string text)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var digit = Ui.Pixel(number.ToString(), 2, Theme.Text);
        digit.HorizontalAlignment = HorizontalAlignment.Center;
        digit.VerticalAlignment = VerticalAlignment.Center;
        var tile = Ui.ChipTile(digit, padding: new Thickness(0));
        tile.Width = 24;
        tile.Height = 24;
        tile.VerticalAlignment = VerticalAlignment.Top;
        grid.Children.Add(tile);
        var step = Ui.Coloured(text, 15, Theme.Text, FontWeights.SemiBold);
        step.Margin = new Thickness(10, 1, 0, 0);
        Grid.SetColumn(step, 1);
        grid.Children.Add(step);
        return grid;
    }

    private static UIElement ScoreRow(ScoredLine scored, double width)
    {
        var label = Ui.Coloured(scored.Label, 13, Theme.Muted, FontWeights.Medium);
        label.VerticalAlignment = VerticalAlignment.Center;
        var numbers = Numbers(scored);
        // Beside the numbers when it fits on one line, otherwise above them, so a long label never wraps letter by letter.
        label.TextWrapping = TextWrapping.NoWrap;
        label.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var labelWidth = label.DesiredSize.Width;
        label.TextWrapping = TextWrapping.Wrap;
        double numbersWidth = 0;
        if (numbers is not null)
        {
            numbers.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            numbersWidth = numbers.DesiredSize.Width;
        }
        var column = new StackPanel();
        if (numbers is null || labelWidth + 6 + numbersWidth <= width)
        {
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.Children.Add(label);
            if (numbers is not null)
            {
                Grid.SetColumn(numbers, 1);
                numbers.Margin = new Thickness(6, 0, 0, 0);
                grid.Children.Add(numbers);
            }
            column.Children.Add(grid);
        }
        else
        {
            column.Children.Add(label);
            numbers.HorizontalAlignment = HorizontalAlignment.Right;
            numbers.Margin = new Thickness(0, 4, 0, 0);
            column.Children.Add(numbers);
        }
        if (scored.Note is { } note)
        {
            var text = Ui.Text(note, 12, Theme.Muted, FontWeights.SemiBold);
            text.HorizontalAlignment = HorizontalAlignment.Right;
            text.Margin = new Thickness(0, 2, 0, 0);
            column.Children.Add(text);
        }
        column.Opacity = scored.IsAlternative ? 0.6 : 1;
        return column;
    }

    private static FrameworkElement? Numbers(ScoredLine scored)
    {
        if (scored.Sum is not { } sum) return null;
        static UIElement Symbol(string text)
        {
            var block = Ui.Text(text, 13, Theme.Muted, FontWeights.SemiBold, wrap: false);
            block.VerticalAlignment = VerticalAlignment.Center;
            return block;
        }
        var total = Ui.Pixel(sum.Total, 2, scored.Clears ? Theme.Money : Theme.Text);
        total.VerticalAlignment = VerticalAlignment.Center;
        var row = Ui.Row(4,
            Ui.ChipTile(Ui.Pixel(sum.Chips, 2, Theme.Text)),
            Symbol("×"),
            Ui.ChipTile(Ui.Pixel(sum.Mult, 2, Theme.Text), Theme.Mult, Theme.MultDeep),
            Symbol(sum.IsEstimate ? "≈" : "="),
            total,
            scored.Clears ? Ui.Text("✓", 12, Theme.Money, FontWeights.Heavy, wrap: false) : null);
        row.VerticalAlignment = VerticalAlignment.Center;
        return row;
    }

    private UIElement? ScrolledContent(CoachView? view)
    {
        if (view is null) return Placeholder("Starting", null);
        if (view.Advice is not null || view.Thread.Count > 0)
        {
            var column = Ui.Column(14);
            if (view.Advice is { } advice) Ui.Add(column, AdviceView(advice, view.Status == CoachStatus.Answering && view.Thread.Count == 0), 14);
            if (view.Thread.Count > 0) Ui.Add(column, Thread(view.Thread, view.Status != CoachStatus.Ready), 14);
            return column;
        }
        if (view.WaitingOn is { } kind) return Waiting(kind, view.WaitingCaptions);
        if (view.Placeholder is { } placeholder)
        {
            var column = Ui.Column(12, Placeholder(placeholder.Title, placeholder.Detail));
            if (view.Status == CoachStatus.WaitingForRun)
            {
                var button = (FrameworkElement)Ui.ChipButton("What should I play next?", () => _send(Wire.AdviseNextRun()));
                button.HorizontalAlignment = HorizontalAlignment.Left;
                Ui.Add(column, button, 12);
            }
            return column;
        }
        return null;
    }

    private static FrameworkElement Placeholder(string title, string? detail) =>
        Ui.Column(6, Ui.Pixel(title, 2, Theme.Chips), detail is null ? null : Ui.Text(detail, 13, Theme.Muted));

    private UIElement AdviceView(Advice advice, bool streaming)
    {
        var column = Ui.Column(14);
        if (advice.Why.Count > 0)
        {
            var chevron = Ui.Text("›", 16, Theme.Muted, FontWeights.Heavy, wrap: false);
            chevron.RenderTransformOrigin = new Point(0.5, 0.55);
            chevron.RenderTransform = new RotateTransform(_showWhy ? 90 : 0);
            chevron.VerticalAlignment = VerticalAlignment.Center;
            var label = Ui.Row(6, Ui.Pixel("Why", 2, Theme.Muted), chevron);
            var disclosure = new DockPanel { LastChildFill = true };
            DockPanel.SetDock(label, Dock.Left);
            disclosure.Children.Add(label);
            if (advice.Goal is { } goal)
            {
                var goalText = Ui.Coloured(goal, 13, Theme.Text, FontWeights.SemiBold);
                goalText.Margin = new Thickness(8, 3, 0, 0);
                disclosure.Children.Add(goalText);
            }
            var whyColumn = Ui.Column(8, Ui.Clickable(disclosure, () => { _showWhy = !_showWhy; Render(); }));
            if (_showWhy)
            {
                var reasons = Ui.Column(6);
                foreach (var line in advice.Why)
                {
                    var grid = new Grid();
                    grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    grid.Children.Add(new Ellipse { Width = 4, Height = 4, Fill = Theme.MutedFaint, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 8, 8, 0) });
                    var text = Ui.Coloured(line, 13, Theme.TextSoft);
                    Grid.SetColumn(text, 1);
                    grid.Children.Add(text);
                    Ui.Add(reasons, grid, 6);
                }
                Ui.Add(whyColumn, reasons, 8);
            }
            Ui.Add(column, whyColumn, 14);
        }
        if (advice.Why.Count == 0 && advice.Goal is { } onlyGoal) Ui.Add(column, Ui.Coloured(onlyGoal, 13, Theme.Text, FontWeights.SemiBold), 14);
        if (advice.Lesson is { } lesson)
        {
            var lessonColumn = Ui.Column(4, Ui.Pixel(lesson.Heading, 2, Theme.Mult), Ui.Coloured(lesson.Title, 13, Theme.Text, FontWeights.SemiBold));
            if (lesson.Body.Length > 0) Ui.Add(lessonColumn, Ui.Coloured(lesson.Body, 13, Theme.Muted), 4);
            Ui.Add(column, lessonColumn, 14);
        }
        if (advice.Rest.Length > 0) Ui.Add(column, Ui.Coloured(advice.Rest, 13, Theme.TextSoft), 14);
        if (streaming) Ui.Add(column, ThinkingDots(), 14);
        return column;
    }

    private UIElement Thread(List<FollowUp> thread, bool waiting)
    {
        var column = Ui.Column(12, new Rectangle { Height = 1, Fill = Theme.FeltRaised });
        for (var i = 0; i < thread.Count; i++)
        {
            var followUp = thread[i];
            var question = new Border
            {
                Background = Theme.FeltDeep,
                CornerRadius = new CornerRadius(6),
                Padding = new Thickness(8, 5, 8, 5),
                HorizontalAlignment = HorizontalAlignment.Left,
                Child = Ui.Coloured(followUp.Question, 13, Theme.Muted, FontWeights.Medium),
            };
            var item = Ui.Column(6, question);
            if (followUp.Reply.Length > 0) Ui.Add(item, Ui.Coloured(followUp.Reply, 13, Theme.TextSoft), 6);
            if (followUp.ChangedSteps) Ui.Add(item, Ui.Text("Steps updated above", 11, Theme.Chips, FontWeights.Medium), 6);
            if (waiting && i == thread.Count - 1) Ui.Add(item, ThinkingDots(), 6);
            Ui.Add(column, item, 12);
        }
        return column;
    }

    /// Dots for a reply that's on its way. A fixed width stops the text beside them from shifting.
    private TextBlock ThinkingDots()
    {
        var dots = Ui.Pixel(".", 2, Theme.Chips);
        dots.Width = 30;
        dots.HorizontalAlignment = HorizontalAlignment.Left;
        _tickers.Add(time => dots.Text = new string('.', 1 + (int)(time / 0.4) % 3));
        return dots;
    }

    /// A simpler cousin of the Mac's drawn animations: the game's shapes, moving gently, over the caption.
    private UIElement Waiting(DecisionKind kind, List<string> captions)
    {
        var caption = Ui.Pixel(captions.FirstOrDefault() ?? "", 2, Theme.Chips);
        caption.HorizontalAlignment = HorizontalAlignment.Center;
        if (captions.Count > 1) _tickers.Add(time => caption.Text = captions[(int)(time / 3.5) % captions.Count]);
        var picture = new Grid { Height = 92 };
        var drawing = WaitingPicture(kind);
        drawing.VerticalAlignment = VerticalAlignment.Bottom;
        drawing.HorizontalAlignment = HorizontalAlignment.Center;
        picture.Children.Add(drawing);
        var column = Ui.Column(14, picture, caption);
        column.Margin = new Thickness(0, 10, 0, 0);
        return column;
    }

    private FrameworkElement WaitingPicture(DecisionKind kind)
    {
        switch (kind)
        {
            case DecisionKind.PlayHand:
            {
                TextBlock Number() { var b = Ui.Pixel("10", 3, Theme.Text); b.HorizontalAlignment = HorizontalAlignment.Center; b.VerticalAlignment = VerticalAlignment.Center; return b; }
                var chips = Number();
                var mult = Number();
                var chipsTile = Ui.ChipTile(chips);
                var multTile = Ui.ChipTile(mult, Theme.Mult, Theme.MultDeep);
                chipsTile.Width = multTile.Width = 72;
                chipsTile.Height = multTile.Height = 44;
                var times = Ui.Text("×", 20, Theme.Mult, FontWeights.Heavy, wrap: false);
                times.VerticalAlignment = VerticalAlignment.Center;
                _tickers.Add(time =>
                {
                    var progress = time / 6 % 1;
                    chips.Text = (10 + (int)(progress * 90)).ToString();
                    mult.Text = (1 + (int)(progress * 8)).ToString();
                });
                return Ui.Row(8, chipsTile, times, multTile);
            }
            case DecisionKind.Shop:
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
                coin.RenderTransform = spin;
                _tickers.Add(time => spin.ScaleX = Math.Max(0.08, Math.Abs(Math.Cos(time * Math.PI / 1.6))));
                return coin;
            }
            case DecisionKind.BlindSelect:
            {
                var fan = new Canvas { Width = 150, Height = 70 };
                var suits = new (string, Brush)[] { ("♠", Theme.Chips), ("♥", Theme.Mult), ("♣", Theme.Chips), ("♦", Theme.Mult), ("♠", Theme.Chips) };
                for (var i = 0; i < suits.Length; i++)
                {
                    var position = i - 2.0;
                    var face = Ui.Text(suits[i].Item1, 18, suits[i].Item2, wrap: false);
                    face.HorizontalAlignment = HorizontalAlignment.Center;
                    face.VerticalAlignment = VerticalAlignment.Center;
                    var card = new Border { Width = 34, Height = 48, CornerRadius = new CornerRadius(4), Background = Theme.Text, Child = face, RenderTransformOrigin = new Point(0.5, 0.5) };
                    var shift = new TranslateTransform();
                    var group = new TransformGroup();
                    group.Children.Add(new RotateTransform(position * 9));
                    group.Children.Add(shift);
                    card.RenderTransform = group;
                    Canvas.SetLeft(card, 58 + position * 22);
                    Canvas.SetTop(card, 14 + Math.Abs(position) * 3);
                    fan.Children.Add(card);
                    var index = i;
                    _tickers.Add(time => shift.Y = -10 * Math.Max(0, Math.Sin(time * 3 - index * 0.8)));
                }
                return fan;
            }
            default:
            {
                var question = Ui.Pixel("?", 3, Theme.Text);
                question.HorizontalAlignment = HorizontalAlignment.Center;
                question.VerticalAlignment = VerticalAlignment.Center;
                var pack = new Border
                {
                    Width = 50,
                    Height = 70,
                    CornerRadius = new CornerRadius(4),
                    Background = new LinearGradientBrush(Color.FromRgb(0x00, 0x9D, 0xFF), Color.FromRgb(0xFE, 0x5F, 0x55), 45),
                    BorderBrush = Theme.Muted,
                    BorderThickness = new Thickness(0, 6, 0, 6),
                    Child = question,
                    RenderTransformOrigin = new Point(0.5, 0.5),
                };
                var wobble = new RotateTransform();
                pack.RenderTransform = wobble;
                _tickers.Add(time => wobble.Angle = Math.Sin(time * 2.5) * 5);
                return pack;
            }
        }
    }

    /// Replaces the coach while the bot has a run, as Sources/Balabro/PilotPanel.swift. The bot plays in its own window.
    private UIElement PilotContent(PilotView view)
    {
        var layout = new DockPanel { LastChildFill = true };

        var title = new Grid();
        title.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        title.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        title.Children.Add(Ui.Pixel(view.Title, 2, Theme.Text));
        var clock = Ui.Pixel("", 2, Theme.Money);
        Grid.SetColumn(clock, 1);
        title.Children.Add(clock);
        if (view.Result is { } done) clock.Text = done.Time;
        else if (view.StartedAt is { } started) _tickers.Add(_ => clock.Text = Clock((DateTimeOffset.UtcNow - started).TotalSeconds));
        title.Margin = new Thickness(0, 0, 0, 12);
        DockPanel.SetDock(title, Dock.Top);
        layout.Children.Add(title);

        var buttons = Ui.Row(8);
        if (view.Result is null) Ui.Add(buttons, Ui.ChipButton("Stop", () => _send(Wire.StopPilot())), 8);
        else
        {
            Ui.Add(buttons, Ui.ChipButton("Play again", () =>
            {
                _send(Wire.DismissPilot());
                _send(Wire.PlayForMe(_coach?.Goal ?? view.Goal));
            }), 8);
            Ui.Add(buttons, Ui.ChipButton("Close", () => _send(Wire.DismissPilot())), 8);
        }
        DockPanel.SetDock(buttons, Dock.Bottom);
        buttons.Margin = new Thickness(0, 12, 0, 0);
        layout.Children.Add(buttons);

        var lines = Ui.Column(12);
        UIElement Line(string text) => Ui.Coloured(text, 13, Theme.Muted);
        if (view.Result is { } result)
        {
            foreach (var line in result.Lines) Ui.Add(lines, Line(line), 12);
            if (result.Ending is { Kind: "failed", Reason: { } reason }) Ui.Add(lines, Ui.Text(reason, 13, Theme.Mult), 12);
            foreach (var best in view.BestTimes) Ui.Add(lines, Line(best.Line), 12);
        }
        else
        {
            if (view.Run is { } run)
            {
                foreach (var line in run.Lines) Ui.Add(lines, Line(line), 12);
                Ui.Add(lines, Ui.Coloured(run.Doing, 13, Theme.Text), 12);
            }
            if (view.StartingLine is { } starting) Ui.Add(lines, Line(starting), 12);
            if (view.ChoosingLine is { } choosing) Ui.Add(lines, Line(choosing), 12);
            if (view.Why is { Length: > 0 } why) Ui.Add(lines, Ui.Coloured(why, 12, Theme.Muted), 12);
            if (view.Warning is { } warning) Ui.Add(lines, Ui.Text(warning, 13, Theme.Mult), 12);
        }
        layout.Children.Add(new ScrollViewer { Content = lines, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden });
        return layout;
    }

    private static string Clock(double seconds)
    {
        var whole = Math.Max(0, (int)seconds);
        return $"{whole / 60}:{whole % 60:00}";
    }

    private void Tick()
    {
        var time = (DateTime.UtcNow - _epoch).TotalSeconds;
        foreach (var ticker in _tickers.ToArray()) ticker(time);
    }

    /// The title row drags the panel. Its buttons opt out through `WindowChrome.IsHitTestVisibleInChrome`.
    private void UpdateCaption()
    {
        if (WindowChrome.GetWindowChrome(this) is { } chrome) chrome.CaptionHeight = Math.Max(30, _header.ActualHeight - 6);
    }

    // ---- Win32: no activation, the shortcut ----

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        _hwnd = new WindowInteropHelper(this).Handle;
        var style = Native.GetWindowLong(_hwnd, Native.GWL_EXSTYLE);
        Native.SetWindowLong(_hwnd, Native.GWL_EXSTYLE, (style | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW) & ~Native.WS_EX_APPWINDOW);
        var round = Native.DWMWCP_ROUND;
        Native.DwmSetWindowAttribute(_hwnd, Native.DWMWA_WINDOW_CORNER_PREFERENCE, ref round, sizeof(int));
        HwndSource.FromHwnd(_hwnd)?.AddHook(WndProc);
        _hotKeyRegistered = Native.RegisterHotKey(_hwnd, HotKeyId, Native.MOD_CONTROL | Native.MOD_ALT | Native.MOD_NOREPEAT, Native.VK_SPACE);
        if (!_hotKeyRegistered) Log.Write("Couldn't register Ctrl+Alt+Space; another program may have it");
        Render();
    }

    public event Action? MovedOrResized;

    private IntPtr WndProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        switch (message)
        {
            case Native.WM_HOTKEY when wParam.ToInt32() == HotKeyId:
                StartTyping();
                handled = true;
                break;
            case Native.WM_MOUSEACTIVATE when !_typing:
                handled = true;
                return new IntPtr(Native.MA_NOACTIVATE);
            case Native.WM_EXITSIZEMOVE:
                MovedOrResized?.Invoke();
                break;
        }
        return IntPtr.Zero;
    }

    /// Re-asserts topmost, since a game going borderless fullscreen can climb over it.
    public void KeepOnTop()
    {
        if (_hwnd != IntPtr.Zero && IsVisible)
            Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, 0, 0, 0, 0, Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
    }

    public IntPtr Handle => _hwnd;

    /// The shortcut, or a click in the box: show the panel, take the keyboard and focus the box,
    /// remembering which window to give it back to.
    public void StartTyping()
    {
        if (!IsVisible) Show();
        var foreground = Native.GetForegroundWindow();
        if (foreground != _hwnd && foreground != IntPtr.Zero) _returnFocusTo = foreground;
        SetNoActivate(false);
        _typing = true;
        Native.ForceForeground(_hwnd);
        Activate();
        _question.Focus();
        Keyboard.Focus(_question);
    }

    private void StopTyping(bool returnFocus)
    {
        _typing = false;
        SetNoActivate(true);
        Keyboard.ClearFocus();
        FocusManager.SetFocusedElement(this, null);
        var target = _returnFocusTo;
        _returnFocusTo = IntPtr.Zero;
        if (returnFocus && target != IntPtr.Zero && Native.IsWindow(target))
        {
            var ok = Native.ForceForeground(target);
            Log.Write($"Gave the keyboard back to \"{Native.WindowTitle(target)}\": {(ok ? "done" : "refused")}");
        }
    }

    private void OnQuestionKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            var question = _question.Text.Trim();
            if (question.Length > 0) _send(Wire.Ask(question));
            _question.Text = "";
            StopTyping(returnFocus: true);
            e.Handled = true;
        }
        else if (e.Key == Key.Escape)
        {
            StopTyping(returnFocus: true);
            e.Handled = true;
        }
    }

    private void SetNoActivate(bool on)
    {
        if (_hwnd == IntPtr.Zero) return;
        var style = Native.GetWindowLong(_hwnd, Native.GWL_EXSTYLE);
        Native.SetWindowLong(_hwnd, Native.GWL_EXSTYLE, on ? style | Native.WS_EX_NOACTIVATE : style & ~Native.WS_EX_NOACTIVATE);
    }

    private void OnClosed()
    {
        _timer.Stop();
        if (_hotKeyRegistered) Native.UnregisterHotKey(_hwnd, HotKeyId);
    }
}
