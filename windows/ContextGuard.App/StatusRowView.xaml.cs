using ContextGuard.Feed;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace ContextGuard.App;

/// <summary>A label and how it stands, in the status's tone; the row's tooltip says what it is for.</summary>
public sealed partial class StatusRowView : UserControl
{
    public StatusRowView()
    {
        InitializeComponent();
    }

    /// <param name="card">Its card's AutomationId: two cards can each have a Judge.</param>
    internal void Show(StatusRow row, string card)
    {
        Label.Text = row.Label;
        Value.ShowStatus(row.Status);
        Value.Id = $"{card}.{row.Label}";
        ToolTipService.SetToolTip(Row, row.Help);
        AutomationProperties.SetHelpText(Label, row.Help);
    }
}
