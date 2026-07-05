using System.Net;
using System.Text;
using System.Text.Json;

namespace BrowserTimeTracker.Service;

public sealed class LocalDashboardServer
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true
    };

    private readonly BrowserTimeStore store;
    private readonly EventIngestor ingestor;
    private readonly ILogger<LocalDashboardServer> logger;
    private readonly HttpListener listener = new();

    public LocalDashboardServer(
        BrowserTimeStore store,
        EventIngestor ingestor,
        ILogger<LocalDashboardServer> logger)
    {
        this.store = store;
        this.ingestor = ingestor;
        this.logger = logger;
        listener.Prefixes.Add("http://127.0.0.1:38888/");
    }

    public void Start()
    {
        listener.Start();
        _ = Task.Run(AcceptLoop);
    }

    public void Stop()
    {
        if (listener.IsListening)
        {
            listener.Stop();
        }
    }

    private async Task AcceptLoop()
    {
        while (listener.IsListening)
        {
            try
            {
                var context = await listener.GetContextAsync();
                _ = Task.Run(() => Route(context));
            }
            catch (HttpListenerException)
            {
                break;
            }
            catch (ObjectDisposedException)
            {
                break;
            }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "Dashboard server accept loop failed.");
            }
        }
    }

    private async Task Route(HttpListenerContext context)
    {
        try
        {
            var request = context.Request;
            var response = context.Response;
            response.Headers["Access-Control-Allow-Origin"] = "*";
            response.Headers["Access-Control-Allow-Headers"] = "content-type";
            response.Headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS";

            if (request.HttpMethod == "OPTIONS")
            {
                response.StatusCode = 204;
                response.Close();
                return;
            }

            var path = request.Url?.AbsolutePath ?? "/";
            if (request.HttpMethod == "GET" && path == "/health")
            {
                await WriteJson(response, new { ok = true, paused = ingestor.IsPaused });
                return;
            }

            if (request.HttpMethod == "GET" && path == "/api/today")
            {
                await WriteJson(response, store.TodaySummary());
                return;
            }

            if (request.HttpMethod == "GET" && path == "/api/summary")
            {
                await WriteJson(response, SummaryFromRequest(request));
                return;
            }

            if (request.HttpMethod == "GET" && (path == "/" || path == "/dashboard"))
            {
                await WriteText(response, DashboardHtml.Value, "text/html; charset=utf-8");
                return;
            }

            if (request.HttpMethod == "POST" && path == "/events")
            {
                using var reader = new StreamReader(request.InputStream, request.ContentEncoding);
                var body = await reader.ReadToEndAsync();
                if (body.Length > 64 * 1024)
                {
                    await WriteText(response, "Request too large", "text/plain; charset=utf-8", 413);
                    return;
                }

                var browserEvent = JsonSerializer.Deserialize<BrowserEvent>(body, JsonOptions);
                if (browserEvent is null)
                {
                    await WriteText(response, "Invalid event", "text/plain; charset=utf-8", 400);
                    return;
                }

                ingestor.Ingest(browserEvent);
                await WriteJson(response, new { ok = true });
                return;
            }

            await WriteText(response, "Not found", "text/plain; charset=utf-8", 404);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Request failed.");
            if (context.Response.OutputStream.CanWrite)
            {
                await WriteText(context.Response, "Internal server error", "text/plain; charset=utf-8", 500);
            }
        }
    }

    private TodaySummary SummaryFromRequest(HttpListenerRequest request)
    {
        var dateString = request.QueryString["date"] ?? DateTimeOffset.Now.ToString("yyyy-MM-dd");
        var day = DateTime.TryParse(dateString, out var parsed)
            ? new DateTimeOffset(parsed.Date)
            : new DateTimeOffset(DateTimeOffset.Now.Date);
        var hourValue = request.QueryString["hour"] ?? "all";

        if (int.TryParse(hourValue, out var hour) && hour is >= 0 and < 24)
        {
            var start = day.AddHours(hour);
            var end = start.AddHours(1);
            return store.Summary(start, end, $"{dateString} {hour:00}:00-{hour + 1:00}:00");
        }

        return store.Summary(day, day.AddDays(1), $"{dateString} All day");
    }

    private static Task WriteJson(HttpListenerResponse response, object value)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, JsonOptions);
        response.StatusCode = 200;
        response.ContentType = "application/json; charset=utf-8";
        response.ContentLength64 = bytes.Length;
        response.OutputStream.Write(bytes, 0, bytes.Length);
        response.Close();
        return Task.CompletedTask;
    }

    private static Task WriteText(HttpListenerResponse response, string value, string contentType, int statusCode = 200)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        response.StatusCode = statusCode;
        response.ContentType = contentType;
        response.ContentLength64 = bytes.Length;
        response.OutputStream.Write(bytes, 0, bytes.Length);
        response.Close();
        return Task.CompletedTask;
    }
}
