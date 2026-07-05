using System.Runtime.InteropServices;

namespace BrowserTimeTracker.Service;

public sealed class Worker : BackgroundService
{
    private readonly BrowserTimeStore store;
    private readonly EventIngestor ingestor;
    private readonly LocalDashboardServer server;
    private readonly ILogger<Worker> logger;

    public Worker(
        BrowserTimeStore store,
        EventIngestor ingestor,
        LocalDashboardServer server,
        ILogger<Worker> logger)
    {
        this.store = store;
        this.ingestor = ingestor;
        this.server = server;
        this.logger = logger;
    }

    public override Task StartAsync(CancellationToken cancellationToken)
    {
        server.Start();
        return base.StartAsync(cancellationToken);
    }

    public override Task StopAsync(CancellationToken cancellationToken)
    {
        server.Stop();
        return base.StopAsync(cancellationToken);
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                store.PruneData();
                ingestor.SetSystemPaused(IsUserIdle(), "idle");
            }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "Periodic maintenance failed.");
            }

            await Task.Delay(TimeSpan.FromMinutes(5), stoppingToken);
        }
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
        return idleMilliseconds > TimeSpan.FromMinutes(5).TotalMilliseconds;
    }

    [DllImport("user32.dll")]
    private static extern bool GetLastInputInfo(ref LastInputInfo plii);

    [StructLayout(LayoutKind.Sequential)]
    private struct LastInputInfo
    {
        public uint cbSize;
        public uint dwTime;
    }
}
