using System.Net;
using System.Net.Mail;
using System.Text.Json;

namespace BrowserTimeTracker.Tray;

internal sealed class EmailNotifier
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly string appRoot;
    private readonly EmailSettings? settings;

    public EmailNotifier(string appRoot)
    {
        this.appRoot = appRoot;
        settings = LoadSettings(Path.Combine(appRoot, "email_settings.json"));
    }

    public async Task SendStartupNotification(string screenshotLink)
    {
        await SendNotification("online", "Windows computer online.", screenshotLink, enforceCooldown: true);
    }

    public async Task SendSessionNotification(string reason, string screenshotLink)
    {
        await SendNotification(reason, "Windows computer activity detected.", screenshotLink, enforceCooldown: false);
    }

    private async Task SendNotification(
        string reason,
        string messageText,
        string screenshotLink,
        bool enforceCooldown)
    {
        if (settings is not { Enabled: true } ||
            string.IsNullOrWhiteSpace(settings.SmtpHost) ||
            string.IsNullOrWhiteSpace(settings.From) ||
            string.IsNullOrWhiteSpace(settings.Username) ||
            string.IsNullOrWhiteSpace(settings.Password) ||
            string.IsNullOrWhiteSpace(settings.To))
        {
            return;
        }

        if (enforceCooldown && !ShouldSend(settings.CooldownMinutes))
        {
            return;
        }

        using var message = new MailMessage(settings.From, settings.To)
        {
            Subject = $"Browser Time Tracker {reason} - {Environment.MachineName}",
            Body = $"""
            {messageText}

            Event: {reason}

            Computer: {Environment.MachineName}
            User: {CurrentUserName()}
            Time: {DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss zzz}

            Screenshot link:
            {screenshotLink}
            """,
            IsBodyHtml = false
        };

        using var client = new SmtpClient(settings.SmtpHost, settings.SmtpPort)
        {
            EnableSsl = settings.EnableSsl,
            Credentials = new NetworkCredential(settings.Username, settings.Password),
            DeliveryMethod = SmtpDeliveryMethod.Network,
            Timeout = 15_000
        };

        await client.SendMailAsync(message);
        MarkSent();
    }

    private bool ShouldSend(int cooldownMinutes)
    {
        var statePath = StatePath();
        if (!File.Exists(statePath))
        {
            return true;
        }

        var text = File.ReadAllText(statePath).Trim();
        if (!DateTimeOffset.TryParse(text, out var lastSentAt))
        {
            return true;
        }

        return DateTimeOffset.Now - lastSentAt >= TimeSpan.FromMinutes(Math.Max(1, cooldownMinutes));
    }

    private void MarkSent()
    {
        File.WriteAllText(StatePath(), DateTimeOffset.Now.ToString("O"));
    }

    private string StatePath()
    {
        return Path.Combine(appRoot, "email_last_sent.txt");
    }

    private static EmailSettings? LoadSettings(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return null;
            }

            return JsonSerializer.Deserialize<EmailSettings>(File.ReadAllText(path), JsonOptions);
        }
        catch
        {
            return null;
        }
    }

    private static string CurrentUserName()
    {
        return string.IsNullOrWhiteSpace(Environment.UserDomainName)
            ? Environment.UserName
            : $@"{Environment.UserDomainName}\{Environment.UserName}";
    }

    private sealed record EmailSettings(
        bool Enabled,
        string SmtpHost,
        int SmtpPort,
        bool EnableSsl,
        string From,
        string Username,
        string Password,
        string To,
        int CooldownMinutes);
}
