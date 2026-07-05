using System.Diagnostics;
using System.Net.Http.Json;

namespace BrowserTimeTracker.Tray;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new TrayApplicationContext());
    }
}

internal sealed class TrayApplicationContext : ApplicationContext
{
    private const string DashboardUrl = "http://127.0.0.1:38888/dashboard";
    private readonly NotifyIcon notifyIcon;
    private readonly ToolStripMenuItem statusItem;
    private readonly System.Windows.Forms.Timer timer;
    private readonly HttpClient httpClient = new()
    {
        Timeout = TimeSpan.FromSeconds(2)
    };

    public TrayApplicationContext()
    {
        statusItem = new ToolStripMenuItem("Service: checking...")
        {
            Enabled = false
        };

        var menu = new ContextMenuStrip();
        menu.Items.Add(statusItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Open Dashboard", null, (_, _) => OpenDashboard());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit tray UI", null, (_, _) => ExitThread());

        notifyIcon = new NotifyIcon
        {
            Text = "Browser Time Tracker",
            Icon = SystemIcons.Application,
            ContextMenuStrip = menu,
            Visible = true
        };
        notifyIcon.DoubleClick += (_, _) => OpenDashboard();

        timer = new System.Windows.Forms.Timer
        {
            Interval = 30_000
        };
        timer.Tick += async (_, _) => await RefreshStatus();
        timer.Start();
        _ = RefreshStatus();
    }

    protected override void ExitThreadCore()
    {
        timer.Stop();
        notifyIcon.Visible = false;
        notifyIcon.Dispose();
        httpClient.Dispose();
        base.ExitThreadCore();
    }

    private static void OpenDashboard()
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = DashboardUrl,
            UseShellExecute = true
        });
    }

    private async Task RefreshStatus()
    {
        try
        {
            var health = await httpClient.GetFromJsonAsync<HealthResponse>("http://127.0.0.1:38888/health");
            statusItem.Text = health?.Ok == true ? "Service: running" : "Service: unavailable";
            notifyIcon.Text = $"Browser Time Tracker - {statusItem.Text}";
        }
        catch
        {
            statusItem.Text = "Service: unavailable";
            notifyIcon.Text = "Browser Time Tracker - service unavailable";
        }
    }

    private sealed record HealthResponse(bool Ok, bool Paused);
}
