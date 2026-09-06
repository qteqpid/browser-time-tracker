using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace BrowserTimeTracker.Service;

public sealed class LocalDashboardServer
{
    private const string EventTokenHeader = "X-Browser-Time-Tracker-Token";
    private const string EventToken = "browser-time-tracker-local-events-v1";

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true
    };

    private readonly BrowserTimeStore store;
    private readonly EventIngestor ingestor;
    private readonly AppEventIngestor appIngestor;
    private readonly ILogger<LocalDashboardServer> logger;
    private readonly TcpListener listener = new(IPAddress.Loopback, 38888);
    private CancellationTokenSource? stopCts;

    public LocalDashboardServer(
        BrowserTimeStore store,
        EventIngestor ingestor,
        AppEventIngestor appIngestor,
        ILogger<LocalDashboardServer> logger)
    {
        this.store = store;
        this.ingestor = ingestor;
        this.appIngestor = appIngestor;
        this.logger = logger;
    }

    public void Start()
    {
        stopCts = new CancellationTokenSource();
        listener.Start();
        _ = Task.Run(() => AcceptLoop(stopCts.Token));
    }

    public void Stop()
    {
        stopCts?.Cancel();
        listener.Stop();
    }

    private async Task AcceptLoop(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                var client = await listener.AcceptTcpClientAsync(cancellationToken);
                _ = Task.Run(() => Route(client, cancellationToken), cancellationToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (SocketException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "Dashboard server accept loop failed.");
            }
        }
    }

    private async Task Route(TcpClient client, CancellationToken cancellationToken)
    {
        using (client)
        {
            try
            {
                var stream = client.GetStream();
                var request = await ReadRequest(stream, cancellationToken);
                var response = request is null
                    ? Response("400 Bad Request", "text/plain; charset=utf-8", "Bad request"u8.ToArray())
                    : Route(request);
                await stream.WriteAsync(response, cancellationToken);
            }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "Request failed.");
            }
        }
    }

    private byte[] Route(LocalRequest request)
    {
        try
        {
            if (request.Method == "OPTIONS")
            {
                return Response("204 No Content", "text/plain; charset=utf-8", Array.Empty<byte>(), allowCors: true);
            }

            if (request.Method == "GET" && request.Path == "/health")
            {
                return Json(new { ok = true, paused = ingestor.IsPaused });
            }

            if (request.Method == "GET" && request.Path == "/api/today")
            {
                return Json(store.TodaySummary());
            }

            if (request.Method == "GET" && request.Path == "/api/summary")
            {
                return Json(SummaryFromRequest(request.Query));
            }

            if (request.Method == "GET" && (request.Path == "/" || request.Path == "/dashboard"))
            {
                return Text(DashboardHtml.Value, "text/html; charset=utf-8");
            }

            if (request.Method == "POST" && request.Path == "/events")
            {
                if (!IsValidEventToken(request))
                {
                    return Text("Unauthorized", "text/plain; charset=utf-8", "401 Unauthorized", allowCors: true);
                }

                if (request.Body.Length > 64 * 1024)
                {
                    return Text("Request too large", "text/plain; charset=utf-8", "413 Payload Too Large", allowCors: true);
                }

                var browserEvent = JsonSerializer.Deserialize<BrowserEvent>(request.Body, JsonOptions);
                if (browserEvent is null)
                {
                    return Text("Invalid event", "text/plain; charset=utf-8", "400 Bad Request", allowCors: true);
                }

                ingestor.Ingest(browserEvent);
                return Json(new { ok = true }, allowCors: true);
            }

            if (request.Method == "POST" && request.Path == "/app-events")
            {
                if (!IsValidEventToken(request))
                {
                    return Text("Unauthorized", "text/plain; charset=utf-8", "401 Unauthorized", allowCors: true);
                }

                if (request.Body.Length > 64 * 1024)
                {
                    return Text("Request too large", "text/plain; charset=utf-8", "413 Payload Too Large", allowCors: true);
                }

                var appEvent = JsonSerializer.Deserialize<AppEvent>(request.Body, JsonOptions);
                if (appEvent is null)
                {
                    return Text("Invalid event", "text/plain; charset=utf-8", "400 Bad Request", allowCors: true);
                }

                appIngestor.Ingest(appEvent);
                return Json(new { ok = true }, allowCors: true);
            }

            return Text("Not found", "text/plain; charset=utf-8", "404 Not Found");
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Request failed.");
            return Text("Internal server error", "text/plain; charset=utf-8", "500 Internal Server Error");
        }
    }

    private static async Task<LocalRequest?> ReadRequest(NetworkStream stream, CancellationToken cancellationToken)
    {
        using var buffer = new MemoryStream();
        var readBuffer = new byte[8192];
        var headerEnd = -1;
        var contentLength = 0;

        while (buffer.Length <= 128 * 1024)
        {
            var read = await stream.ReadAsync(readBuffer, cancellationToken);
            if (read == 0)
            {
                break;
            }

            buffer.Write(readBuffer, 0, read);
            var bytes = buffer.ToArray();
            if (headerEnd < 0)
            {
                headerEnd = IndexOf(bytes, "\r\n\r\n"u8.ToArray());
                if (headerEnd >= 0)
                {
                    var header = Encoding.UTF8.GetString(bytes, 0, headerEnd);
                    contentLength = ContentLength(header);
                }
            }

            if (headerEnd >= 0 && bytes.Length >= headerEnd + 4 + contentLength)
            {
                break;
            }
        }

        var data = buffer.ToArray();
        if (headerEnd < 0 || data.Length < headerEnd + 4 + contentLength)
        {
            return null;
        }

        var headerText = Encoding.UTF8.GetString(data, 0, headerEnd);
        var body = Encoding.UTF8.GetString(data, headerEnd + 4, contentLength);
        return ParseRequest(headerText, body);
    }

    private static LocalRequest? ParseRequest(string headerText, string body)
    {
        var lines = headerText.Split("\r\n");
        var requestParts = lines.FirstOrDefault()?.Split(' ', 3, StringSplitOptions.RemoveEmptyEntries) ?? [];
        if (requestParts.Length < 2)
        {
            return null;
        }

        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in lines.Skip(1))
        {
            var separator = line.IndexOf(':');
            if (separator <= 0)
            {
                continue;
            }
            headers[line[..separator].Trim()] = line[(separator + 1)..].Trim();
        }

        if (!Uri.TryCreate("http://127.0.0.1" + requestParts[1], UriKind.Absolute, out var uri))
        {
            return null;
        }

        return new LocalRequest(
            requestParts[0],
            uri.AbsolutePath,
            ParseQuery(uri.Query),
            headers,
            body);
    }

    private static int ContentLength(string headerText)
    {
        foreach (var line in headerText.Split("\r\n").Skip(1))
        {
            var separator = line.IndexOf(':');
            if (separator <= 0)
            {
                continue;
            }

            var name = line[..separator].Trim();
            var value = line[(separator + 1)..].Trim();
            if (string.Equals(name, "Content-Length", StringComparison.OrdinalIgnoreCase) &&
                int.TryParse(value, out var contentLength))
            {
                return contentLength;
            }
        }
        return 0;
    }

    private static IReadOnlyDictionary<string, string> ParseQuery(string query)
    {
        if (string.IsNullOrEmpty(query))
        {
            return new Dictionary<string, string>();
        }

        return query.TrimStart('?')
            .Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Select(part => part.Split('=', 2))
            .Where(parts => parts.Length > 0)
            .ToDictionary(
                parts => WebUtility.UrlDecode(parts[0]),
                parts => parts.Length > 1 ? WebUtility.UrlDecode(parts[1]) : "",
                StringComparer.OrdinalIgnoreCase);
    }

    private static int IndexOf(byte[] source, byte[] pattern)
    {
        for (var index = 0; index <= source.Length - pattern.Length; index++)
        {
            var found = true;
            for (var patternIndex = 0; patternIndex < pattern.Length; patternIndex++)
            {
                if (source[index + patternIndex] != pattern[patternIndex])
                {
                    found = false;
                    break;
                }
            }

            if (found)
            {
                return index;
            }
        }
        return -1;
    }

    private static bool IsValidEventToken(LocalRequest request)
    {
        return request.Headers.TryGetValue(EventTokenHeader, out var token) &&
               string.Equals(token, EventToken, StringComparison.Ordinal);
    }

    private TodaySummary SummaryFromRequest(IReadOnlyDictionary<string, string> query)
    {
        var dateString = query.TryGetValue("date", out var requestedDate)
            ? requestedDate
            : DateTimeOffset.Now.ToString("yyyy-MM-dd");
        var day = DateTime.TryParse(dateString, out var parsed)
            ? new DateTimeOffset(parsed.Date)
            : new DateTimeOffset(DateTimeOffset.Now.Date);
        var hourValue = query.TryGetValue("hour", out var requestedHour) ? requestedHour : "all";

        if (int.TryParse(hourValue, out var hour) && hour is >= 0 and < 24)
        {
            var start = day.AddHours(hour);
            var end = start.AddHours(1);
            return store.Summary(start, end, $"{dateString} {hour:00}:00-{hour + 1:00}:00");
        }

        return store.Summary(day, day.AddDays(1), $"{dateString} All day");
    }

    private static byte[] Json(object value, bool allowCors = false)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, JsonOptions);
        return Response("200 OK", "application/json; charset=utf-8", bytes, allowCors);
    }

    private static byte[] Text(
        string value,
        string contentType,
        string status = "200 OK",
        bool allowCors = false)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        return Response(status, contentType, bytes, allowCors);
    }

    private static byte[] Response(string status, string contentType, byte[] body, bool allowCors = false)
    {
        var header = new StringBuilder()
            .Append("HTTP/1.1 ").Append(status).Append("\r\n")
            .Append("Content-Type: ").Append(contentType).Append("\r\n")
            .Append("Content-Length: ").Append(body.Length).Append("\r\n")
            .Append("Connection: close\r\n");
        if (allowCors)
        {
            header
                .Append("Access-Control-Allow-Origin: *\r\n")
                .Append("Access-Control-Allow-Headers: content-type, x-browser-time-tracker-token\r\n")
                .Append("Access-Control-Allow-Methods: POST, OPTIONS\r\n");
        }

        header.Append("\r\n");
        return Encoding.UTF8.GetBytes(header.ToString()).Concat(body).ToArray();
    }

    private sealed record LocalRequest(
        string Method,
        string Path,
        IReadOnlyDictionary<string, string> Query,
        IReadOnlyDictionary<string, string> Headers,
        string Body);
}
