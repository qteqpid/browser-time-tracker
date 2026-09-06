namespace BrowserTimeTracker.Service;

public sealed class AppEventIngestor
{
    private sealed record ActiveAppSession(
        string Id,
        string UserName,
        string ProcessName,
        string AppName,
        string WindowTitle);

    private readonly BrowserTimeStore store;
    private readonly object gate = new();
    private readonly Dictionary<string, ActiveAppSession> activeSessions = new(StringComparer.OrdinalIgnoreCase);

    public AppEventIngestor(BrowserTimeStore store)
    {
        this.store = store;
    }

    public void Ingest(AppEvent appEvent)
    {
        lock (gate)
        {
            var userName = Normalize(appEvent.UserName, "unknown");
            switch (appEvent.Event)
            {
                case "app_active":
                    var processName = Normalize(appEvent.ProcessName, "unknown");
                    var appName = Normalize(appEvent.AppName, processName);
                    var windowTitle = (appEvent.WindowTitle ?? "").Trim();

                    if (activeSessions.TryGetValue(userName, out var active) &&
                        string.Equals(active.ProcessName, processName, StringComparison.OrdinalIgnoreCase) &&
                        string.Equals(active.WindowTitle, windowTitle, StringComparison.Ordinal))
                    {
                        store.UpdateAppSession(active.Id, windowTitle, appEvent.Timestamp);
                        return;
                    }

                    if (active is not null)
                    {
                        store.CloseAppSession(active.Id, appEvent.Timestamp);
                    }

                    var id = store.StartAppSession(
                        userName,
                        processName,
                        appName,
                        windowTitle,
                        appEvent.Timestamp);
                    activeSessions[userName] = new ActiveAppSession(
                        id,
                        userName,
                        processName,
                        appName,
                        windowTitle);
                    break;

                case "app_inactive":
                case "user_idle":
                case "tracking_paused":
                    CloseUser(userName, appEvent.Timestamp);
                    break;
            }
        }
    }

    private void CloseUser(string userName, DateTimeOffset endedAt)
    {
        if (activeSessions.Remove(userName, out var active))
        {
            store.CloseAppSession(active.Id, endedAt);
        }
    }

    private static string Normalize(string? value, string fallback)
    {
        var normalized = value?.Trim();
        return string.IsNullOrEmpty(normalized) ? fallback : normalized;
    }
}
