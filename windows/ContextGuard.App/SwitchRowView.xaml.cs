using ContextGuard.Feed;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace ContextGuard.App;

/// <summary>
/// A switch row. Context Guard's own switch (<c>enabled</c>) sends <see cref="Intent.Enable"/>; Open at login is
/// the app's own (<see cref="LoginItem"/>): the board only says where it goes and its label.
/// </summary>
public sealed partial class SwitchRowView : UserControl
{
    /// <summary>The app's words, as the Mac's SettingsView words a login item it couldn't change.</summary>
    internal const string CouldNotChange = "Couldn't change it: {0}";

    string? toggleId;
    bool login, rendering;

    public SwitchRowView()
    {
        InitializeComponent();
        Problem.Id = "Login.Error";
    }

    /// <summary>The Settings window it sends to.</summary>
    internal ISettingsHost Host { private get; init; } = null!;

    internal void Show(Row row)
    {
        rendering = true;
        try
        {
            if (row.Toggle is { } toggle)
            {
                toggleId = toggle.Id;
                Label.Text = toggle.Label;
                Switch.IsChecked = toggle.On;
                AutomationProperties.SetAutomationId(Switch, "Toggle." + toggle.Id);
            }
            else if (row.Login is { } item)
            {
                login = true;
                Label.Text = item.Label;
                Switch.IsChecked = Host.Login.IsOn;
                AutomationProperties.SetAutomationId(Switch, "Login");
            }
            AutomationProperties.SetName(Switch, Label.Text);
        }
        finally
        {
            rendering = false;
        }
    }

    /// <summary>Open at login as Windows has it now (it can be changed in Windows' Startup apps too).</summary>
    internal void Refresh()
    {
        if (!login) return;
        rendering = true;
        Switch.IsChecked = Host.Login.IsOn;
        rendering = false;
    }

    void OnChanged(object sender, RoutedEventArgs e)
    {
        // Only you, never a new board, switches it.
        if (rendering) return;
        var on = Switch.IsChecked == true;
        if (login)
        {
            try
            {
                Host.Login.Set(on);
                ProblemPart.Visibility = Visibility.Collapsed;
            }
            catch (Exception x) when (x is UnauthorizedAccessException or System.Security.SecurityException or IOException)
            {
                Log.Write($"login item: {x.Message}");
                Problem.ShowProblem(string.Format(CouldNotChange, x.Message));
                ProblemPart.Visibility = Visibility.Visible;
            }
            Refresh();
        }
        else if (toggleId == "enabled")
        {
            _ = Host.Send(Intent.Enable(on));
        }
        else
        {
            Log.Write($"settings: a switch this build doesn't know: {toggleId}");
        }
    }
}
