using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace ContextGuard.App;

/// <summary>
/// One line of text cut in the middle to fit its width ("billing-3f · C:\co…\billing"), as the Mac's
/// <c>truncationMode(.middle)</c>; XAML can only cut at the end. The width is its column's (a block's own width
/// follows its text), so it is fitted again whenever the text or the column's width changes. A screen reader and the
/// tooltip get the whole text.
/// </summary>
sealed class MiddleTrim
{
    readonly TextBlock block;
    readonly FrameworkElement column;
    string text = "";
    double fittedTo = -1;

    /// <param name="column">What the block spans: its width is the room the text has.</param>
    public MiddleTrim(TextBlock block, FrameworkElement column)
    {
        this.block = block;
        this.column = column;
        block.TextWrapping = TextWrapping.NoWrap;
        column.SizeChanged += (_, e) =>
        {
            if (e.NewSize.Width != e.PreviousSize.Width) Fit();
        };
    }

    public string Text
    {
        get => text;
        set
        {
            if (value == text && fittedTo >= 0) return;
            text = value;
            fittedTo = -1;
            AutomationProperties.SetName(block, text);
            Fit();
        }
    }

    void Fit()
    {
        var width = column.ActualWidth - block.Margin.Left - block.Margin.Right;
        if (width <= 0)
        {
            // Not laid out yet: whole for now, fitted once it has a width.
            block.Text = text;
            return;
        }
        if (width == fittedTo) return;
        fittedTo = width;
        var fitted = Feed.TextFit.Middle(text, width, Measure);
        block.Text = fitted;
        ToolTipService.SetToolTip(block, fitted == text ? null : text);
    }

    /// <summary>The width a string takes in this block, in its font.</summary>
    double Measure(string candidate)
    {
        block.Text = candidate;
        block.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        return block.DesiredSize.Width;
    }
}
