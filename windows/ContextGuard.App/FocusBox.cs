using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace ContextGuard.App;

/// <summary>
/// WinUI draws a control's keyboard focus box in the theme's colors when focus arrives and keeps those colors through
/// a light/dark switch (a high contrast switch redraws it), so after a switch the box showed the old theme's colors.
/// Turning the control's system focus visuals off, and on again once the switch has reached its theme resources
/// (turning them back on at once, or from <c>ActualThemeChanged</c>, drew the old colors again), draws it anew.
/// </summary>
static class FocusBox
{
    /// <summary>Call when a window's content changes theme.</summary>
    internal static void Redraw(XamlRoot? root)
    {
        if (root is null) return;
        if (FocusManager.GetFocusedElement(root) is not Control { FocusState: FocusState.Keyboard, UseSystemFocusVisuals: true } control)
            return;
        control.UseSystemFocusVisuals = false;
        control.DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low,
            () => control.ClearValue(Control.UseSystemFocusVisualsProperty));
    }
}
