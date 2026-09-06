using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.Net.Http.Json;
using System.Runtime.InteropServices;
using System.Text;

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
    private const string AppEventsUrl = "http://127.0.0.1:38888/app-events";
    private const string EventTokenHeader = "X-Browser-Time-Tracker-Token";
    private const string EventToken = "browser-time-tracker-local-events-v1";
    private const int IdleSeconds = 300;
    private const int ScreenshotRetentionHours = 24;
    private const long ScreenshotJpegQuality = 65L;

    private readonly NotifyIcon notifyIcon;
    private readonly ToolStripMenuItem statusItem;
    private readonly System.Windows.Forms.Timer healthTimer;
    private readonly System.Windows.Forms.Timer activityTimer;
    private readonly System.Windows.Forms.Timer screenshotTimer;
    private readonly ScreenshotViewerServer screenshotViewerServer;
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
        menu.Items.Add("Open Screenshots", null, (_, _) => OpenScreenshots());
        menu.Items.Add("Copy Screenshot Link", null, (_, _) => CopyScreenshotLink());
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

        healthTimer = new System.Windows.Forms.Timer
        {
            Interval = 30_000
        };
        healthTimer.Tick += async (_, _) => await RefreshStatus();
        healthTimer.Start();

        activityTimer = new System.Windows.Forms.Timer
        {
            Interval = 5_000
        };
        activityTimer.Tick += async (_, _) => await TrackForegroundApp();
        activityTimer.Start();

        var screenshotRoot = ScreenshotRoot();
        screenshotViewerServer = new ScreenshotViewerServer(screenshotRoot);
        try
        {
            screenshotViewerServer.Start();
        }
        catch
        {
            statusItem.Text = "Screenshot sharing unavailable";
        }

        screenshotTimer = new System.Windows.Forms.Timer
        {
            Interval = 60_000
        };
        screenshotTimer.Tick += (_, _) => CaptureScreenshot();
        screenshotTimer.Start();

        _ = RefreshStatus();
        _ = TrackForegroundApp();
    }

    protected override void ExitThreadCore()
    {
        healthTimer.Stop();
        activityTimer.Stop();
        screenshotTimer.Stop();
        screenshotViewerServer.Stop();
        try
        {
            PostAppEvent(new AppEvent(
                "app_inactive",
                CurrentUserName(),
                null,
                null,
                null,
                DateTimeOffset.Now)).GetAwaiter().GetResult();
        }
        catch
        {
        }

        notifyIcon.Visible = false;
        notifyIcon.Dispose();
        screenshotViewerServer.Dispose();
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

    private void OpenScreenshots()
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = screenshotViewerServer.LocalUrl,
            UseShellExecute = true
        });
    }

    private void CopyScreenshotLink()
    {
        Clipboard.SetText(screenshotViewerServer.ShareText);
        statusItem.Text = "Screenshot link copied";
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

    private async Task TrackForegroundApp()
    {
        try
        {
            if (IsUserIdle())
            {
                await PostAppEvent(new AppEvent(
                    "user_idle",
                    CurrentUserName(),
                    null,
                    null,
                    null,
                    DateTimeOffset.Now));
                return;
            }

            var foregroundApp = ForegroundApp.Current();
            if (foregroundApp is null)
            {
                await PostAppEvent(new AppEvent(
                    "app_inactive",
                    CurrentUserName(),
                    null,
                    null,
                    null,
                    DateTimeOffset.Now));
                return;
            }

            await PostAppEvent(new AppEvent(
                "app_active",
                CurrentUserName(),
                foregroundApp.ProcessName,
                foregroundApp.AppName,
                foregroundApp.WindowTitle,
                DateTimeOffset.Now));
        }
        catch
        {
        }
    }

    private async Task PostAppEvent(AppEvent appEvent)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, AppEventsUrl)
        {
            Content = JsonContent.Create(appEvent)
        };
        request.Headers.TryAddWithoutValidation(EventTokenHeader, EventToken);
        using var response = await httpClient.SendAsync(request);
    }

    private static void CaptureScreenshot()
    {
        try
        {
            var now = DateTimeOffset.Now;
            var screenshotRoot = ScreenshotRoot();
            var dateFolder = Path.Combine(screenshotRoot, now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
            Directory.CreateDirectory(dateFolder);

            var bounds = Screen.AllScreens
                .Select(screen => screen.Bounds)
                .Aggregate(Rectangle.Union);
            if (bounds.Width <= 0 || bounds.Height <= 0)
            {
                return;
            }

            using var bitmap = new Bitmap(bounds.Width, bounds.Height);
            using (var graphics = Graphics.FromImage(bitmap))
            {
                graphics.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size);
            }

            var fileName = $"screenshot-{now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture)}.jpg";
            SaveJpeg(bitmap, Path.Combine(dateFolder, fileName));
            PruneScreenshots(screenshotRoot);
        }
        catch
        {
        }
    }

    private static void SaveJpeg(Bitmap bitmap, string path)
    {
        var jpegCodec = ImageCodecInfo.GetImageEncoders()
            .FirstOrDefault(codec => codec.FormatID == ImageFormat.Jpeg.Guid);
        if (jpegCodec is null)
        {
            bitmap.Save(path, ImageFormat.Jpeg);
            return;
        }

        using var parameters = new EncoderParameters(1);
        parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, ScreenshotJpegQuality);
        bitmap.Save(path, jpegCodec, parameters);
    }

    private static void PruneScreenshots(string screenshotRoot)
    {
        if (!Directory.Exists(screenshotRoot))
        {
            return;
        }

        var cutoff = DateTimeOffset.Now.AddHours(-ScreenshotRetentionHours).LocalDateTime;
        foreach (var file in Directory.EnumerateFiles(screenshotRoot, "*.*", SearchOption.AllDirectories))
        {
            try
            {
                var extension = Path.GetExtension(file);
                if (!string.Equals(extension, ".jpg", StringComparison.OrdinalIgnoreCase) &&
                    !string.Equals(extension, ".jpeg", StringComparison.OrdinalIgnoreCase) &&
                    !string.Equals(extension, ".png", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                if (File.GetCreationTime(file) < cutoff)
                {
                    File.Delete(file);
                }
            }
            catch
            {
            }
        }

        foreach (var directory in Directory.EnumerateDirectories(screenshotRoot))
        {
            try
            {
                if (!Directory.EnumerateFileSystemEntries(directory).Any())
                {
                    Directory.Delete(directory);
                }
            }
            catch
            {
            }
        }
    }

    private static string ScreenshotRoot()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "BrowserTimeTracker",
            "screenshots");
    }

    private static bool IsUserIdle()
    {
        var info = new LastInputInfo
        {
            cbSize = (uint)Marshal.SizeOf<LastInputInfo>()
        };
        if (!GetLastInputInfo(ref info))
        {
            return false;
        }

        var idleMilliseconds = unchecked((uint)Environment.TickCount - info.dwTime);
        return idleMilliseconds > TimeSpan.FromSeconds(IdleSeconds).TotalMilliseconds;
    }

    private static string CurrentUserName()
    {
        return string.IsNullOrWhiteSpace(Environment.UserDomainName)
            ? Environment.UserName
            : $@"{Environment.UserDomainName}\{Environment.UserName}";
    }

    private sealed record HealthResponse(bool Ok, bool Paused);

    private sealed record AppEvent(
        string Event,
        string UserName,
        string? ProcessName,
        string? AppName,
        string? WindowTitle,
        DateTimeOffset Timestamp);

    private sealed record ForegroundApp(string ProcessName, string AppName, string WindowTitle)
    {
        public static ForegroundApp? Current()
        {
            var handle = GetForegroundWindow();
            if (handle == IntPtr.Zero)
            {
                return null;
            }

            _ = GetWindowThreadProcessId(handle, out var processId);
            if (processId == 0)
            {
                return null;
            }

            using var process = Process.GetProcessById((int)processId);
            var processName = process.ProcessName;
            var appName = AppNameFrom(process) ?? processName;
            var windowTitle = WindowTitleFrom(handle);
            return new ForegroundApp(processName, appName, windowTitle);
        }

        private static string? AppNameFrom(Process process)
        {
            try
            {
                return process.MainModule?.FileVersionInfo.FileDescription;
            }
            catch
            {
                return null;
            }
        }

        private static string WindowTitleFrom(IntPtr handle)
        {
            var length = GetWindowTextLength(handle);
            if (length <= 0)
            {
                return "";
            }

            var builder = new StringBuilder(length + 1);
            _ = GetWindowText(handle, builder, builder.Capacity);
            return builder.ToString();
        }
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool GetLastInputInfo(ref LastInputInfo plii);

    [StructLayout(LayoutKind.Sequential)]
    private struct LastInputInfo
    {
        public uint cbSize;
        public uint dwTime;
    }
}
