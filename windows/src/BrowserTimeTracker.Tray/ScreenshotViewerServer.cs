using System.Globalization;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace BrowserTimeTracker.Tray;

internal sealed class ScreenshotViewerServer : IDisposable
{
    private const int Port = 38889;

    private readonly string screenshotRoot;
    private readonly string token;
    private readonly TcpListener listener = new(IPAddress.Any, Port);
    private CancellationTokenSource? stopCts;

    public ScreenshotViewerServer(string screenshotRoot)
    {
        this.screenshotRoot = screenshotRoot;
        Directory.CreateDirectory(screenshotRoot);
        token = LoadOrCreateToken(screenshotRoot);
    }

    public string LocalUrl => $"http://127.0.0.1:{Port}/screenshots?token={Uri.EscapeDataString(token)}";

    public string LanUrl
    {
        get
        {
            return $"http://{Environment.MachineName}:{Port}/screenshots?token={Uri.EscapeDataString(token)}";
        }
    }

    public string ShareText
    {
        get
        {
            var fallbackIp = LocalNetworkAddress();
            if (string.IsNullOrWhiteSpace(fallbackIp))
            {
                return LanUrl;
            }

            return $"""
            {LanUrl}

            If that does not open from your phone or Mac, use this Wi-Fi IP fallback:
            http://{fallbackIp}:{Port}/screenshots?token={Uri.EscapeDataString(token)}
            """;
        }
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
        try
        {
            listener.Stop();
        }
        catch
        {
        }
    }

    public void Dispose()
    {
        Stop();
        stopCts?.Dispose();
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
            catch
            {
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
                    ? Text("Bad request", "400 Bad Request")
                    : Route(request);
                await stream.WriteAsync(response, cancellationToken);
            }
            catch
            {
            }
        }
    }

    private byte[] Route(LocalRequest request)
    {
        if (!IsAuthorized(request))
        {
            return Text("Unauthorized", "401 Unauthorized");
        }

        if (request.Method == "GET" && (request.Path == "/" || request.Path == "/screenshots"))
        {
            return Html(ScreenshotsHtml());
        }

        if (request.Method == "GET" && request.Path == "/screenshot-image")
        {
            if (!request.Query.TryGetValue("file", out var fileName))
            {
                return Text("Missing file", "400 Bad Request");
            }

            var filePath = ResolveScreenshotPath(fileName);
            if (filePath is null || !File.Exists(filePath))
            {
                return Text("Not found", "404 Not Found");
            }

            return Binary(File.ReadAllBytes(filePath), "image/jpeg");
        }

        return Text("Not found", "404 Not Found");
    }

    private string ScreenshotsHtml()
    {
        var files = RecentScreenshots()
            .Select(file =>
            {
                var relative = Path.GetRelativePath(screenshotRoot, file).Replace('\\', '/');
                var createdAt = File.GetCreationTime(file);
                return new
                {
                    Relative = relative,
                    Label = createdAt.ToString("HH:mm:ss", CultureInfo.CurrentCulture),
                    Day = createdAt.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)
                };
            })
            .ToArray();

        var items = files.Length == 0
            ? """<div class="empty">No screenshots yet</div>"""
            : string.Join("", files.Select(file =>
                $"""
                <a class="shot" href="/screenshot-image?token={Url(token)}&file={Url(file.Relative)}" target="_blank" rel="noreferrer">
                  <img loading="lazy" src="/screenshot-image?token={Url(token)}&file={Url(file.Relative)}" alt="Screenshot {HtmlEscape(file.Day)} {HtmlEscape(file.Label)}">
                  <span>{HtmlEscape(file.Day)} {HtmlEscape(file.Label)}</span>
                </a>
                """));

        return $$"""
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Recent Screenshots</title>
          <style>
            :root { color-scheme: light dark; --bg: #f7f7f2; --ink: #1f231c; --muted: #707866; --line: rgba(36,42,30,.14); --surface: rgba(255,255,250,.9); font-family: "Segoe UI", system-ui, sans-serif; }
            @media (prefers-color-scheme: dark) { :root { --bg: #10120e; --ink: #f3f5ef; --muted: #a6afa2; --line: rgba(243,245,239,.14); --surface: rgba(26,29,23,.92); } }
            * { box-sizing: border-box; }
            body { margin: 0; background: var(--bg); color: var(--ink); }
            main { max-width: 1180px; margin: 0 auto; padding: 22px 14px 34px; }
            header { position: sticky; top: 0; z-index: 2; background: color-mix(in srgb, var(--bg) 92%, transparent); backdrop-filter: blur(10px); padding: 12px 0 14px; border-bottom: 1px solid var(--line); margin-bottom: 14px; }
            h1 { margin: 0; font-size: 22px; line-height: 1.15; letter-spacing: 0; }
            .meta { margin-top: 5px; color: var(--muted); font-size: 13px; }
            .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 12px; }
            .shot { display: block; overflow: hidden; border: 1px solid var(--line); border-radius: 8px; background: var(--surface); color: inherit; text-decoration: none; }
            img { display: block; width: 100%; aspect-ratio: 16 / 10; object-fit: cover; background: #222; }
            span { display: block; padding: 9px 10px; color: var(--muted); font-size: 12px; font-variant-numeric: tabular-nums; }
            .empty { border: 1px solid var(--line); border-radius: 8px; padding: 18px; color: var(--muted); background: var(--surface); }
          </style>
        </head>
        <body>
          <main>
            <header>
              <h1>Recent Screenshots</h1>
              <div class="meta">Last 24 hours · {{files.Length}} images · refreshes every minute</div>
            </header>
            <div class="grid">{{items}}</div>
          </main>
          <script>setTimeout(() => location.reload(), 60000);</script>
        </body>
        </html>
        """;
    }

    private IEnumerable<string> RecentScreenshots()
    {
        var cutoff = DateTimeOffset.Now.AddHours(-24).LocalDateTime;
        if (!Directory.Exists(screenshotRoot))
        {
            return [];
        }

        return Directory
            .EnumerateFiles(screenshotRoot, "*.*", SearchOption.AllDirectories)
            .Where(IsScreenshotFile)
            .Where(file => File.GetCreationTime(file) >= cutoff)
            .OrderByDescending(File.GetCreationTime)
            .Take(240)
            .ToArray();
    }

    private string? ResolveScreenshotPath(string fileName)
    {
        var normalizedRelativePath = fileName.Replace('/', Path.DirectorySeparatorChar);
        var fullPath = Path.GetFullPath(Path.Combine(screenshotRoot, normalizedRelativePath));
        var root = Path.GetFullPath(screenshotRoot);
        if (!fullPath.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
            !IsScreenshotFile(fullPath))
        {
            return null;
        }

        return fullPath;
    }

    private bool IsAuthorized(LocalRequest request)
    {
        return request.Query.TryGetValue("token", out var requestedToken) &&
               IsSameToken(requestedToken);
    }

    private bool IsSameToken(string requestedToken)
    {
        var requestedBytes = Encoding.UTF8.GetBytes(requestedToken);
        var tokenBytes = Encoding.UTF8.GetBytes(token);
        return requestedBytes.Length == tokenBytes.Length &&
               CryptographicOperations.FixedTimeEquals(requestedBytes, tokenBytes);
    }

    private static async Task<LocalRequest?> ReadRequest(NetworkStream stream, CancellationToken cancellationToken)
    {
        using var buffer = new MemoryStream();
        var readBuffer = new byte[8192];
        var headerEnd = -1;

        while (buffer.Length <= 64 * 1024)
        {
            var read = await stream.ReadAsync(readBuffer, cancellationToken);
            if (read == 0)
            {
                break;
            }

            buffer.Write(readBuffer, 0, read);
            var bytes = buffer.ToArray();
            headerEnd = IndexOf(bytes, "\r\n\r\n"u8.ToArray());
            if (headerEnd >= 0)
            {
                break;
            }
        }

        var data = buffer.ToArray();
        if (headerEnd < 0)
        {
            return null;
        }

        var requestLine = Encoding.UTF8.GetString(data, 0, headerEnd).Split("\r\n").FirstOrDefault();
        var requestParts = requestLine?.Split(' ', 3, StringSplitOptions.RemoveEmptyEntries) ?? [];
        if (requestParts.Length < 2 || !Uri.TryCreate("http://127.0.0.1" + requestParts[1], UriKind.Absolute, out var uri))
        {
            return null;
        }

        return new LocalRequest(requestParts[0], uri.AbsolutePath, ParseQuery(uri.Query));
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

    private static byte[] Html(string value)
    {
        return Response("200 OK", "text/html; charset=utf-8", Encoding.UTF8.GetBytes(value));
    }

    private static byte[] Text(string value, string status)
    {
        return Response(status, "text/plain; charset=utf-8", Encoding.UTF8.GetBytes(value));
    }

    private static byte[] Binary(byte[] body, string contentType)
    {
        return Response("200 OK", contentType, body);
    }

    private static byte[] Response(string status, string contentType, byte[] body)
    {
        var header = new StringBuilder()
            .Append("HTTP/1.1 ").Append(status).Append("\r\n")
            .Append("Content-Type: ").Append(contentType).Append("\r\n")
            .Append("Content-Length: ").Append(body.Length).Append("\r\n")
            .Append("Cache-Control: no-store\r\n")
            .Append("Connection: close\r\n\r\n")
            .ToString();
        return Encoding.UTF8.GetBytes(header).Concat(body).ToArray();
    }

    private static string LoadOrCreateToken(string screenshotRoot)
    {
        var tokenPath = Path.Combine(screenshotRoot, "viewer_token.txt");
        if (File.Exists(tokenPath))
        {
            var existing = File.ReadAllText(tokenPath).Trim();
            if (!string.IsNullOrEmpty(existing))
            {
                return existing;
            }
        }

        var bytes = RandomNumberGenerator.GetBytes(24);
        var token = Convert.ToHexString(bytes).ToLowerInvariant();
        File.WriteAllText(tokenPath, token);
        return token;
    }

    private static string? LocalNetworkAddress()
    {
        return NetworkInterface.GetAllNetworkInterfaces()
            .Where(item => item.OperationalStatus == OperationalStatus.Up)
            .SelectMany(item => item.GetIPProperties().UnicastAddresses)
            .Where(address =>
                address.Address.AddressFamily == AddressFamily.InterNetwork &&
                !IPAddress.IsLoopback(address.Address))
            .Select(address => address.Address.ToString())
            .FirstOrDefault();
    }

    private static bool IsScreenshotFile(string file)
    {
        var extension = Path.GetExtension(file);
        return string.Equals(extension, ".jpg", StringComparison.OrdinalIgnoreCase) ||
               string.Equals(extension, ".jpeg", StringComparison.OrdinalIgnoreCase);
    }

    private static string HtmlEscape(string value)
    {
        return WebUtility.HtmlEncode(value);
    }

    private static string Url(string value)
    {
        return Uri.EscapeDataString(value);
    }

    private sealed record LocalRequest(
        string Method,
        string Path,
        IReadOnlyDictionary<string, string> Query);
}
