namespace BrowserTimeTracker.Service;

public sealed record BrowserEvent(
    string Browser,
    string Event,
    string? Url,
    string? Title,
    DateTimeOffset Timestamp);

public sealed record AppEvent(
    string Event,
    string? UserName,
    string? ProcessName,
    string? AppName,
    string? WindowTitle,
    DateTimeOffset Timestamp);

public sealed record SummaryItem(string Label, string? Url, int Seconds);

public sealed record TimelineItem(
    string Label,
    string? Url,
    string? Secondary,
    int Seconds,
    long StartedAt,
    long EndedAt);

public sealed record BarSegment(string Label, int Seconds);

public sealed record HourBucket(int Hour, int Seconds, IReadOnlyList<BarSegment> Segments);

public sealed record DayBucket(string Date, string Label, int Seconds, IReadOnlyList<BarSegment> Segments);

public sealed record TodaySummary(
    int TotalSeconds,
    int AppTotalSeconds,
    IReadOnlyList<SummaryItem> Users,
    IReadOnlyList<SummaryItem> Apps,
    IReadOnlyList<SummaryItem> AppWindows,
    IReadOnlyList<SummaryItem> Domains,
    IReadOnlyList<SummaryItem> Pages,
    IReadOnlyList<TimelineItem> AppTimeline,
    IReadOnlyList<TimelineItem> PageTimeline,
    IReadOnlyList<SummaryItem> ColorDomains,
    IReadOnlyList<HourBucket> Hours,
    IReadOnlyList<DayBucket> Days,
    string WindowLabel);
