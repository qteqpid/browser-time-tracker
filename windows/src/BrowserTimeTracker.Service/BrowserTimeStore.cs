using Microsoft.Data.Sqlite;

namespace BrowserTimeTracker.Service;

public sealed class BrowserTimeStore
{
    private const int RetentionDays = 7;
    private readonly object gate = new();
    private readonly string dbPath;

    public BrowserTimeStore()
    {
        var root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "BrowserTimeTracker");
        Directory.CreateDirectory(root);
        dbPath = Path.Combine(root, "browser_time.sqlite");
        Setup();
        PruneData();
    }

    public string StartSession(string browser, string url, string? title, DateTimeOffset at)
    {
        lock (gate)
        {
            var id = Guid.NewGuid().ToString("N");
            var startedAt = at.ToUnixTimeSeconds();
            Execute(
                """
                INSERT INTO page_sessions
                (id, browser, url, domain, title, started_at, ended_at, duration_seconds)
                VALUES ($id, $browser, $url, $domain, $title, $startedAt, $startedAt, 0)
                """,
                command =>
                {
                    command.Parameters.AddWithValue("$id", id);
                    command.Parameters.AddWithValue("$browser", browser);
                    command.Parameters.AddWithValue("$url", url);
                    command.Parameters.AddWithValue("$domain", DomainFrom(url));
                    command.Parameters.AddWithValue("$title", title ?? "");
                    command.Parameters.AddWithValue("$startedAt", startedAt);
                });
            return id;
        }
    }

    public void UpdateSession(string id, string? title, DateTimeOffset endedAt)
    {
        lock (gate)
        {
            var timestamp = endedAt.ToUnixTimeSeconds();
            Execute(
                """
                UPDATE page_sessions
                SET title = CASE WHEN $title = '' THEN title ELSE $title END,
                    ended_at = $endedAt,
                    duration_seconds = MAX(0, CAST($endedAt - started_at AS INTEGER))
                WHERE id = $id
                """,
                command =>
                {
                    command.Parameters.AddWithValue("$title", title ?? "");
                    command.Parameters.AddWithValue("$endedAt", timestamp);
                    command.Parameters.AddWithValue("$id", id);
                });
        }
    }

    public void CloseSession(string id, DateTimeOffset endedAt)
    {
        UpdateSession(id, null, endedAt);
    }

    public string StartAppSession(
        string userName,
        string processName,
        string appName,
        string? windowTitle,
        DateTimeOffset at)
    {
        lock (gate)
        {
            var id = Guid.NewGuid().ToString("N");
            var startedAt = at.ToUnixTimeSeconds();
            Execute(
                """
                INSERT INTO app_sessions
                (id, user_name, process_name, app_name, window_title, started_at, ended_at, duration_seconds)
                VALUES ($id, $userName, $processName, $appName, $windowTitle, $startedAt, $startedAt, 0)
                """,
                command =>
                {
                    command.Parameters.AddWithValue("$id", id);
                    command.Parameters.AddWithValue("$userName", userName);
                    command.Parameters.AddWithValue("$processName", processName);
                    command.Parameters.AddWithValue("$appName", appName);
                    command.Parameters.AddWithValue("$windowTitle", windowTitle ?? "");
                    command.Parameters.AddWithValue("$startedAt", startedAt);
                });
            return id;
        }
    }

    public void UpdateAppSession(string id, string? windowTitle, DateTimeOffset endedAt)
    {
        lock (gate)
        {
            var timestamp = endedAt.ToUnixTimeSeconds();
            Execute(
                """
                UPDATE app_sessions
                SET window_title = CASE WHEN $windowTitle = '' THEN window_title ELSE $windowTitle END,
                    ended_at = $endedAt,
                    duration_seconds = MAX(0, CAST($endedAt - started_at AS INTEGER))
                WHERE id = $id
                """,
                command =>
                {
                    command.Parameters.AddWithValue("$windowTitle", windowTitle ?? "");
                    command.Parameters.AddWithValue("$endedAt", timestamp);
                    command.Parameters.AddWithValue("$id", id);
                });
        }
    }

    public void CloseAppSession(string id, DateTimeOffset endedAt)
    {
        UpdateAppSession(id, null, endedAt);
    }

    public TodaySummary TodaySummary()
    {
        var start = new DateTimeOffset(DateTimeOffset.Now.Date);
        var end = start.AddDays(1);
        return Summary(start, end, "Today");
    }

    public TodaySummary Summary(DateTimeOffset start, DateTimeOffset end, string windowLabel)
    {
        lock (gate)
        {
            return SummaryUnlocked(start, end, windowLabel);
        }
    }

    public void PruneData()
    {
        lock (gate)
        {
            var cutoff = DateTimeOffset.Now.AddDays(-RetentionDays).ToUnixTimeSeconds();
            Execute("DELETE FROM page_sessions WHERE ended_at < $cutoff", command =>
            {
                command.Parameters.AddWithValue("$cutoff", cutoff);
            });
            Execute("DELETE FROM app_sessions WHERE ended_at < $cutoff", command =>
            {
                command.Parameters.AddWithValue("$cutoff", cutoff);
            });
        }
    }

    private TodaySummary SummaryUnlocked(DateTimeOffset start, DateTimeOffset end, string windowLabel)
    {
        var startSeconds = start.ToUnixTimeSeconds();
        var endSeconds = end.ToUnixTimeSeconds();
        var total = QueryInt(
            OverlapSql("SELECT COALESCE(SUM({0}), 0) FROM page_sessions WHERE ended_at > $start AND started_at < $end"),
            startSeconds,
            endSeconds);
        var appTotal = QueryInt(
            OverlapSql("SELECT COALESCE(SUM({0}), 0) FROM app_sessions WHERE ended_at > $start AND started_at < $end"),
            startSeconds,
            endSeconds);
        var users = QueryItems(
            OverlapSql(
                """
                SELECT user_name, NULL, COALESCE(SUM({0}), 0) AS total
                FROM app_sessions
                WHERE ended_at > $start AND started_at < $end
                GROUP BY user_name
                HAVING total > 0
                ORDER BY total DESC
                LIMIT 10
                """),
            startSeconds,
            endSeconds);
        var apps = QueryItems(
            OverlapSql(
                """
                SELECT COALESCE(NULLIF(app_name, ''), process_name), NULL, COALESCE(SUM({0}), 0) AS total
                FROM app_sessions
                WHERE ended_at > $start AND started_at < $end
                GROUP BY COALESCE(NULLIF(app_name, ''), process_name)
                HAVING total > 0
                ORDER BY total DESC
                LIMIT 10
                """),
            startSeconds,
            endSeconds);
        var appWindows = QueryItems(
            OverlapSql(
                """
                SELECT
                    COALESCE(NULLIF(window_title, ''), COALESCE(NULLIF(app_name, ''), process_name)),
                    NULL,
                    COALESCE(SUM({0}), 0) AS total
                FROM app_sessions
                WHERE ended_at > $start AND started_at < $end
                GROUP BY process_name, COALESCE(NULLIF(window_title, ''), COALESCE(NULLIF(app_name, ''), process_name))
                HAVING total > 0
                ORDER BY total DESC
                LIMIT 10
                """),
            startSeconds,
            endSeconds);
        var domains = QueryItems(
            OverlapSql(
                """
                SELECT domain, NULL, COALESCE(SUM({0}), 0) AS total
                FROM page_sessions
                WHERE ended_at > $start AND started_at < $end AND domain != ''
                GROUP BY domain
                HAVING total > 0
                ORDER BY total DESC
                LIMIT 10
                """),
            startSeconds,
            endSeconds);
        var pages = QueryItems(
            OverlapSql(
                """
                SELECT COALESCE(NULLIF(title, ''), url), url, COALESCE(SUM({0}), 0) AS total
                FROM page_sessions
                WHERE ended_at > $start AND started_at < $end AND url != ''
                GROUP BY url
                HAVING total > 0
                ORDER BY total DESC
                LIMIT 10
                """),
            startSeconds,
            endSeconds);
        var appTimeline = QueryTimelineItems(
            OverlapSql(
                """
                SELECT
                    COALESCE(NULLIF(app_name, ''), process_name),
                    NULL,
                    CASE
                        WHEN NULLIF(window_title, '') IS NULL THEN user_name
                        ELSE user_name || ' - ' || window_title
                    END,
                    CAST({0} AS INTEGER) AS seconds,
                    MAX(started_at, $start) AS window_started_at,
                    MIN(ended_at, $end) AS window_ended_at
                FROM app_sessions
                WHERE ended_at > $start AND started_at < $end
                ORDER BY window_started_at DESC
                LIMIT 50
                """),
            startSeconds,
            endSeconds);
        var pageTimeline = QueryTimelineItems(
            OverlapSql(
                """
                SELECT
                    COALESCE(NULLIF(title, ''), url),
                    url,
                    browser,
                    CAST({0} AS INTEGER) AS seconds,
                    MAX(started_at, $start) AS window_started_at,
                    MIN(ended_at, $end) AS window_ended_at
                FROM page_sessions
                WHERE ended_at > $start AND started_at < $end AND url != ''
                ORDER BY window_started_at DESC
                LIMIT 50
                """),
            startSeconds,
            endSeconds);
        var colorDomains = ColorDomainsUnlocked();
        var topDomainLabels = colorDomains.Select(item => item.Label).ToArray();

        return new TodaySummary(
            total,
            appTotal,
            users,
            apps,
            appWindows,
            domains,
            pages,
            appTimeline,
            pageTimeline,
            colorDomains,
            HourlyBucketsUnlocked(start, topDomainLabels),
            DayBucketsUnlocked(topDomainLabels),
            windowLabel);
    }

    private IReadOnlyList<HourBucket> HourlyBucketsUnlocked(DateTimeOffset date, IReadOnlyList<string> topDomains)
    {
        var dayStart = date.Date;
        return Enumerable.Range(0, 24).Select(hour =>
        {
            var start = new DateTimeOffset(dayStart.AddHours(hour));
            var end = start.AddHours(1);
            var total = QueryInt(
                OverlapSql("SELECT COALESCE(SUM({0}), 0) FROM page_sessions WHERE ended_at > $start AND started_at < $end"),
                start.ToUnixTimeSeconds(),
                end.ToUnixTimeSeconds());
            return new HourBucket(hour, total, SegmentBucketsUnlocked(start, end, topDomains));
        }).ToArray();
    }

    private IReadOnlyList<DayBucket> DayBucketsUnlocked(IReadOnlyList<string> topDomains)
    {
        var today = DateTimeOffset.Now.Date;
        var firstDay = today.AddDays(-6);
        return Enumerable.Range(0, 7).Select(offset =>
        {
            var start = new DateTimeOffset(firstDay.AddDays(offset));
            var end = start.AddDays(1);
            var total = QueryInt(
                OverlapSql("SELECT COALESCE(SUM({0}), 0) FROM page_sessions WHERE ended_at > $start AND started_at < $end"),
                start.ToUnixTimeSeconds(),
                end.ToUnixTimeSeconds());
            return new DayBucket(
                start.ToString("yyyy-MM-dd"),
                start.ToString("ddd"),
                total,
                SegmentBucketsUnlocked(start, end, topDomains));
        }).ToArray();
    }

    private IReadOnlyList<BarSegment> SegmentBucketsUnlocked(DateTimeOffset start, DateTimeOffset end, IReadOnlyList<string> topDomains)
    {
        var rows = QueryDomainSeconds(
            OverlapSql(
                """
                SELECT domain, COALESCE(SUM({0}), 0) AS total
                FROM page_sessions
                WHERE ended_at > $start AND started_at < $end AND domain != ''
                GROUP BY domain
                HAVING total > 0
                ORDER BY total DESC
                """),
            start.ToUnixTimeSeconds(),
            end.ToUnixTimeSeconds());
        if (rows.Count == 0)
        {
            return Array.Empty<BarSegment>();
        }

        if (topDomains.Count == 0)
        {
            return [new BarSegment("Other", rows.Sum(row => row.Seconds))];
        }

        var secondsByDomain = rows.ToDictionary(row => row.Domain, row => row.Seconds);
        var known = topDomains
            .Where(secondsByDomain.ContainsKey)
            .Select(domain => new BarSegment(domain, secondsByDomain[domain]))
            .Where(segment => segment.Seconds > 0)
            .ToList();
        var other = rows.Sum(row => row.Seconds) - known.Sum(segment => segment.Seconds);
        if (other > 0)
        {
            known.Add(new BarSegment("Other", other));
        }
        return known;
    }

    private IReadOnlyList<SummaryItem> ColorDomainsUnlocked()
    {
        var end = new DateTimeOffset(DateTimeOffset.Now.Date.AddDays(1));
        var start = end.AddDays(-7);
        return QueryItems(
            OverlapSql(
                """
                SELECT domain, NULL, COALESCE(SUM({0}), 0) AS total
                FROM page_sessions
                WHERE ended_at > $start AND started_at < $end AND domain != ''
                GROUP BY domain
                HAVING total > 0
                ORDER BY total DESC
                LIMIT 10
                """),
            start.ToUnixTimeSeconds(),
            end.ToUnixTimeSeconds());
    }

    private void Setup()
    {
        lock (gate)
        {
            Execute(
                """
                CREATE TABLE IF NOT EXISTS page_sessions (
                    id TEXT PRIMARY KEY,
                    browser TEXT NOT NULL,
                    url TEXT NOT NULL,
                    domain TEXT NOT NULL,
                    title TEXT,
                    started_at INTEGER NOT NULL,
                    ended_at INTEGER NOT NULL,
                    duration_seconds INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS idx_page_sessions_started_at ON page_sessions(started_at);
                CREATE INDEX IF NOT EXISTS idx_page_sessions_domain ON page_sessions(domain);
                CREATE TABLE IF NOT EXISTS app_sessions (
                    id TEXT PRIMARY KEY,
                    user_name TEXT NOT NULL,
                    process_name TEXT NOT NULL,
                    app_name TEXT NOT NULL,
                    window_title TEXT,
                    started_at INTEGER NOT NULL,
                    ended_at INTEGER NOT NULL,
                    duration_seconds INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS idx_app_sessions_started_at ON app_sessions(started_at);
                CREATE INDEX IF NOT EXISTS idx_app_sessions_process_name ON app_sessions(process_name);
                CREATE INDEX IF NOT EXISTS idx_app_sessions_user_name ON app_sessions(user_name);
                """,
                _ => { });
        }
    }

    private void Execute(string sql, Action<SqliteCommand> bind)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        bind(command);
        command.ExecuteNonQuery();
    }

    private int QueryInt(string sql, long start, long end)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.Parameters.AddWithValue("$start", start);
        command.Parameters.AddWithValue("$end", end);
        return Convert.ToInt32(command.ExecuteScalar() ?? 0);
    }

    private IReadOnlyList<SummaryItem> QueryItems(string sql, long start, long end)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.Parameters.AddWithValue("$start", start);
        command.Parameters.AddWithValue("$end", end);
        using var reader = command.ExecuteReader();

        var items = new List<SummaryItem>();
        while (reader.Read())
        {
            items.Add(new SummaryItem(
                reader.GetString(0),
                reader.IsDBNull(1) ? null : reader.GetString(1),
                reader.GetInt32(2)));
        }
        return items;
    }

    private IReadOnlyList<TimelineItem> QueryTimelineItems(string sql, long start, long end)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.Parameters.AddWithValue("$start", start);
        command.Parameters.AddWithValue("$end", end);
        using var reader = command.ExecuteReader();

        var items = new List<TimelineItem>();
        while (reader.Read())
        {
            items.Add(new TimelineItem(
                reader.GetString(0),
                reader.IsDBNull(1) ? null : reader.GetString(1),
                reader.IsDBNull(2) ? null : reader.GetString(2),
                reader.GetInt32(3),
                reader.GetInt64(4),
                reader.GetInt64(5)));
        }
        return items;
    }

    private IReadOnlyList<(string Domain, int Seconds)> QueryDomainSeconds(string sql, long start, long end)
    {
        using var connection = OpenConnection();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.Parameters.AddWithValue("$start", start);
        command.Parameters.AddWithValue("$end", end);
        using var reader = command.ExecuteReader();

        var items = new List<(string Domain, int Seconds)>();
        while (reader.Read())
        {
            items.Add((reader.GetString(0), reader.GetInt32(1)));
        }
        return items;
    }

    private SqliteConnection OpenConnection()
    {
        var connection = new SqliteConnection($"Data Source={dbPath}");
        connection.Open();
        return connection;
    }

    private static string OverlapSql(string template)
    {
        return string.Format(template, "MAX(0, MIN(ended_at, $end) - MAX(started_at, $start))");
    }

    private static string DomainFrom(string url)
    {
        return Uri.TryCreate(url, UriKind.Absolute, out var uri) ? uri.Host : "";
    }
}
