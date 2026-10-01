using System;
using System.Diagnostics.CodeAnalysis;
using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using QuickWingetSetup.Models;
using YamlDotNet.Serialization;

namespace QuickWingetSetup.Services;

public class ScriptFetchService
{
    private static readonly HttpClient _httpClient = new() { Timeout = TimeSpan.FromSeconds(30) };
    private readonly SemaphoreSlim _cacheLock = new(1, 1);
    private ExtensionConfig _config;
    private ScriptManifest? _cachedManifest;
    private DateTime _lastFetch = DateTime.MinValue;

    public ScriptFetchService()
    {
        _config = LoadConfig();
    }

    public bool CanRunPowerShellNativeFlows => _config.Source == "local";

    private static ExtensionConfig LoadConfig()
    {
        try
        {
            var configPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "QuickWingetSetup", "config.json");
            if (File.Exists(configPath))
            {
                var json = File.ReadAllText(configPath);
                return JsonSerializer.Deserialize(json, ModelsJsonContext.Default.ExtensionConfig) ?? new ExtensionConfig();
            }
        }
        catch { }
        return new ExtensionConfig();
    }

    public async Task<ScriptManifest?> GetManifestAsync(bool forceRefresh = false)
    {
        if (!forceRefresh && _cachedManifest != null
            && (DateTime.UtcNow - _lastFetch).TotalDays < _config.CacheTTLDays)
        {
            return _cachedManifest;
        }

        await _cacheLock.WaitAsync();
        try
        {
            if (!forceRefresh && _cachedManifest != null
                && (DateTime.UtcNow - _lastFetch).TotalDays < _config.CacheTTLDays)
            {
                return _cachedManifest;
            }

            string raw;
            if (_config.Source == "local")
            {
                var manifestPath = Path.Combine(_config.LocalPath, _config.ManifestFile);
                if (!File.Exists(manifestPath))
                    return null;
                raw = await File.ReadAllTextAsync(manifestPath);
            }
            else
            {
                var url = $"https://raw.githubusercontent.com/{_config.GithubRepo}/{_config.GithubBranch}/{_config.ManifestFile}";
                raw = await _httpClient.GetStringAsync(url);
            }

            var json = IsYaml(_config.ManifestFile) ? ConvertYamlToJson(raw) : raw;
            _cachedManifest = JsonSerializer.Deserialize(json, ModelsJsonContext.Default.ScriptManifest);
            _lastFetch = DateTime.UtcNow;
            return _cachedManifest;
        }
        catch
        {
            return _cachedManifest; // Return stale cache on failure
        }
        finally
        {
            _cacheLock.Release();
        }
    }

    private static bool IsYaml(string filename)
    {
        var ext = Path.GetExtension(filename);
        return ext.Equals(".yml", StringComparison.OrdinalIgnoreCase) ||
               ext.Equals(".yaml", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Parses YAML to an untyped object graph (Dictionary/List/scalars) and
    /// re-serializes it as JSON. We then feed the JSON to System.Text.Json's
    /// source-generated deserializer, keeping the AOT-unfriendly reflection
    /// path confined to YamlDotNet's untyped Deserialize.
    /// </summary>
    [UnconditionalSuppressMessage("Trimming", "IL2026", Justification = "YamlDotNet untyped deserialization does not require user types.")]
    [UnconditionalSuppressMessage("AOT", "IL3050", Justification = "YamlDotNet untyped deserialization does not require user types.")]
    private static string ConvertYamlToJson(string yaml)
    {
        var deserializer = new DeserializerBuilder().Build();
        var graph = deserializer.Deserialize(new StringReader(yaml));
        var jsonSerializer = new SerializerBuilder().JsonCompatible().Build();
        return jsonSerializer.Serialize(graph ?? new object());
    }

    public async Task<string?> GetScriptPathAsync(string relativePath)
    {
        if (relativePath.Contains("..") || Path.IsPathRooted(relativePath))
            return null;

        if (_config.Source == "local")
        {
            var fullPath = Path.Combine(_config.LocalPath, relativePath);
            if (!Path.GetFullPath(fullPath).StartsWith(Path.GetFullPath(_config.LocalPath), StringComparison.OrdinalIgnoreCase))
                return null;
            return File.Exists(fullPath) ? fullPath : null;
        }

        else
        {
            try
            {
                var url = $"https://raw.githubusercontent.com/{_config.GithubRepo}/{_config.GithubBranch}/{relativePath}";
                var content = await _httpClient.GetStringAsync(url);
                var cacheDir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "QuickWingetSetup", "cache");
                var localPath = Path.Combine(cacheDir, relativePath.Replace('/', Path.DirectorySeparatorChar));

                if (!Path.GetFullPath(localPath).StartsWith(Path.GetFullPath(cacheDir), StringComparison.OrdinalIgnoreCase))
                    return null;

                var dir = Path.GetDirectoryName(localPath);
                if (dir != null)
                    Directory.CreateDirectory(dir);
                await File.WriteAllTextAsync(localPath, content);
                return localPath;
            }
            catch
            {
                return null;
            }
        }
    }

    public Task ForceRefreshAsync()
    {
        _cachedManifest = null;
        _lastFetch = DateTime.MinValue;
        try
        {
            var cacheDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "QuickWingetSetup", "cache");
            if (Directory.Exists(cacheDir))
                Directory.Delete(cacheDir, true);
        }
        catch { }
        return Task.CompletedTask;
    }
}
