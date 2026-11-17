using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Feed = ContextGuard.Feed;

namespace ContextGuard.App;

/// <summary>
/// A tool's mark before a session's title (<see cref="Feed.ToolLogos"/>). A screen reader finds it as an image named
/// for the tool.
/// </summary>
public sealed partial class ToolLogoView : UserControl
{
    string? shown;

    public ToolLogoView() => InitializeComponent();

    /// <summary>The tool's mark; nothing for no tool, or for a newer program's tool this build has no mark for.</summary>
    internal void Show(Feed.Tool? tool)
    {
        var data = tool is null ? null : Feed.ToolLogos.For(tool.Id);
        Visibility = data is null ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetName(this, data is null ? "" : tool!.Name);
        if (data is null || data == shown) return;
        Mark.Data = (Geometry)XamlBindingHelper.ConvertValue(typeof(Geometry), data);
        shown = data;
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new LogoPeer(this);

    sealed partial class LogoPeer(ToolLogoView owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Image;

        protected override string GetClassNameCore() => nameof(ToolLogoView);
    }
}
