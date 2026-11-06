using System.Diagnostics;
using System.IO.Compression;
using System.Reflection;
using System.Security.Principal;

const string PayloadResourceName = "payload.zip";

try
{
    if (!IsAdministrator())
    {
        RelaunchElevated(args);
        return;
    }

    Console.WriteLine("[1] Extracting Browser Time Tracker installer payload");
    var tempRoot = Path.Combine(Path.GetTempPath(), "BrowserTimeTrackerInstaller", Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(tempRoot);
    Console.WriteLine($"    Temp directory: {tempRoot}");

    await using (var payload = Assembly.GetExecutingAssembly().GetManifestResourceStream(PayloadResourceName))
    {
        if (payload is null)
        {
            throw new InvalidOperationException("Installer payload is missing. Rebuild the installer with scripts\\package-installer.ps1.");
        }

        using var archive = new ZipArchive(payload, ZipArchiveMode.Read);
        archive.ExtractToDirectory(tempRoot, overwriteFiles: true);
    }

    Console.WriteLine("[2] Running installer script");
    var installScript = Path.Combine(tempRoot, "install-from-package.ps1");
    if (!File.Exists(installScript))
    {
        throw new FileNotFoundException("Installer script missing from payload.", installScript);
    }

    var exitCode = RunProcess(
        "powershell.exe",
        [
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            installScript
        ]);
    if (exitCode != 0)
    {
        throw new InvalidOperationException($"Installer script failed with exit code {exitCode}.");
    }

    Console.WriteLine("[DONE] Browser Time Tracker installed.");
}
catch (Exception ex)
{
    Console.Error.WriteLine("ERROR: Browser Time Tracker setup failed.");
    Console.Error.WriteLine($"ERROR: {ex.Message}");
    Environment.ExitCode = 1;
}

static bool IsAdministrator()
{
    using var identity = WindowsIdentity.GetCurrent();
    var principal = new WindowsPrincipal(identity);
    return principal.IsInRole(WindowsBuiltInRole.Administrator);
}

static void RelaunchElevated(string[] args)
{
    var currentProcess = Environment.ProcessPath;
    if (string.IsNullOrWhiteSpace(currentProcess))
    {
        throw new InvalidOperationException("Cannot determine current setup executable path.");
    }

    Console.WriteLine("Requesting administrator permission...");
    var startInfo = new ProcessStartInfo
    {
        FileName = currentProcess,
        UseShellExecute = true,
        Verb = "runas",
        Arguments = string.Join(" ", args.Select(QuoteArgument))
    };
    Process.Start(startInfo);
}

static int RunProcess(string fileName, IReadOnlyList<string> arguments)
{
    using var process = new Process();
    process.StartInfo.FileName = fileName;
    foreach (var argument in arguments)
    {
        process.StartInfo.ArgumentList.Add(argument);
    }

    process.StartInfo.UseShellExecute = false;
    process.StartInfo.RedirectStandardOutput = false;
    process.StartInfo.RedirectStandardError = false;
    process.Start();
    process.WaitForExit();
    return process.ExitCode;
}

static string QuoteArgument(string value)
{
    return value.Contains(' ') || value.Contains('"')
        ? "\"" + value.Replace("\"", "\\\"") + "\""
        : value;
}
