namespace BrowserTimeTracker.Service;

public sealed class EventIngestor
{
    private sealed record ActiveSession(string Id, string Url, string Browser);

    private readonly BrowserTimeStore store;
    private readonly object gate = new();
    private readonly Dictionary<string, ActiveSession> activeSessions = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> systemPauseReasons = new(StringComparer.OrdinalIgnoreCase);

    public EventIngestor(BrowserTimeStore store)
    {
        this.store = store;
    }

    public bool IsPaused
    {
        get
        {
            lock (gate)
            {
                return systemPauseReasons.Count > 0;
            }
        }
    }

    public void SetSystemPaused(bool paused, string reason, DateTimeOffset? at = null)
    {
        lock (gate)
        {
            if (paused)
            {
                systemPauseReasons.Add(reason);
            }
            else
            {
                systemPauseReasons.Remove(reason);
            }

            if (systemPauseReasons.Count > 0)
            {
                CloseAll(at ?? DateTimeOffset.Now);
            }
        }
    }

    public void Ingest(BrowserEvent browserEvent)
    {
        lock (gate)
        {
            var browser = browserEvent.Browser.ToLowerInvariant();

            switch (browserEvent.Event)
            {
                case "page_active":
                case "heartbeat":
                    systemPauseReasons.Remove("idle");
                    if (systemPauseReasons.Count > 0 ||
                        string.IsNullOrWhiteSpace(browserEvent.Url) ||
                        !IsTrackable(browserEvent.Url))
                    {
                        return;
                    }

                    if (activeSessions.TryGetValue(browser, out var active) && active.Url == browserEvent.Url)
                    {
                        store.UpdateSession(active.Id, browserEvent.Title, browserEvent.Timestamp);
                        return;
                    }

                    if (active is not null)
                    {
                        store.CloseSession(active.Id, browserEvent.Timestamp);
                    }

                    var id = store.StartSession(browser, browserEvent.Url, browserEvent.Title, browserEvent.Timestamp);
                    activeSessions[browser] = new ActiveSession(id, browserEvent.Url, browser);
                    break;

                case "page_hidden":
                case "page_closed":
                case "browser_blurred":
                case "user_idle":
                case "tracking_paused":
                    CloseBrowser(browser, browserEvent.Timestamp);
                    break;
            }
        }
    }

    private void CloseBrowser(string browser, DateTimeOffset endedAt)
    {
        if (activeSessions.Remove(browser, out var active))
        {
            store.CloseSession(active.Id, endedAt);
        }
    }

    private void CloseAll(DateTimeOffset endedAt)
    {
        foreach (var session in activeSessions.Values)
        {
            store.CloseSession(session.Id, endedAt);
        }
        activeSessions.Clear();
    }

    private static bool IsTrackable(string url)
    {
        return Uri.TryCreate(url, UriKind.Absolute, out var uri) &&
               (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps);
    }
}
