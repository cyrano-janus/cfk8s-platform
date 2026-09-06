var builder = WebApplication.CreateBuilder(args);

// Kestrel lauscht ohne diese Zeile auf seinem eigenen Default (5000/5001) und
// ist hinter Korifis Route nicht erreichbar. PORT setzt der AppWorkload.
var port = Environment.GetEnvironmentVariable("PORT") ?? "8080";
builder.WebHost.UseUrls($"http://0.0.0.0:{port}");

var app = builder.Build();

app.MapGet("/", () => Results.Json(new
{
    message = "Hallo von .NET auf Korifi",
    buildpack = "paketo-buildpacks/dotnet-core",
    vcap_services_present = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("VCAP_SERVICES")),
}));

app.MapGet("/env", () => Results.Json(new
{
    vcap_services = Environment.GetEnvironmentVariable("VCAP_SERVICES") ?? "<leer>",
}));

app.Run();
