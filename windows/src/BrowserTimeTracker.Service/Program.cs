using BrowserTimeTracker.Service;
using Microsoft.Extensions.Hosting.WindowsServices;

var builder = Host.CreateApplicationBuilder(args);
builder.Services.AddWindowsService(options =>
{
    options.ServiceName = "Browser Time Tracker";
});

builder.Services.AddSingleton<BrowserTimeStore>();
builder.Services.AddSingleton<EventIngestor>();
builder.Services.AddSingleton<LocalDashboardServer>();
builder.Services.AddHostedService<Worker>();

var host = builder.Build();
host.Run();
