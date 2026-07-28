using System;
using System.Diagnostics.CodeAnalysis;
using System.IO;
using System.IO.Compression;
using System.Linq;
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

    /// <summary>
    /// Returns an entry point together with its sibling payload. Remote
    /// PowerShell installers can span multiple files, unlike a DSC document,
    /// so cache an extracted repository snapshot instead of one raw file.
    /// </summary>
    public async Task<string?> GetPayloadEntryPathAsync(
        string relativePath,
        string[]? requiredPayloadFiles = null)
    {
        if (relativePath.Contains("..") || Path.IsPathRooted(relativePath))
            return null;

        if (_config.Source == "local")
        {
            var localEntry = await GetScriptPathAsync(relativePath);
            return HasRequiredPayloadFiles(localEntry, requiredPayloadFiles) ? localEntry : null;
        }

        var cacheDir = GetRepositoryCacheDirectory();
        var expected = Path.Combine(cacheDir, relativePath.Replace('/', Path.DirectorySeparatorChar));
        if (IsPayloadCacheFresh(cacheDir, expected, requiredPayloadFiles))
            return expected;

        await _cacheLock.WaitAsync();
        try
        {
            if (IsPayloadCacheFresh(cacheDir, expected, requiredPayloadFiles))
                return expected;

            if (Directory.Exists(cacheDir))
                Directory.Delete(cacheDir, true);
            Directory.CreateDirectory(cacheDir);

            var archiveUrl =
                $"https://github.com/{_config.GithubRepo}/archive/refs/heads/{_config.GithubBranch}.zip";
            var archivePath = Path.Combine(cacheDir, "repository.zip");
            await using (var source = await _httpClient.GetStreamAsync(archiveUrl))
            await using (var destination = File.Create(archivePath))
            {
                await source.CopyToAsync(destination);
            }

            var extractRoot = Path.Combine(cacheDir, "extract");
            ZipFile.ExtractToDirectory(archivePath, extractRoot);
            File.Delete(archivePath);
            var repositoryRoot = Directory.GetDirectories(extractRoot).FirstOrDefault();
            if (repositoryRoot == null)
                return null;

            var extractedEntry = Path.Combine(
                repositoryRoot,
                relativePath.Replace('/', Path.DirectorySeparatorChar));
            if (!File.Exists(extractedEntry))
                return null;

            var payloadDirectory = Path.GetDirectoryName(expected);
            if (payloadDirectory == null)
                return null;
            Directory.CreateDirectory(payloadDirectory);

            var sourceDirectory = Path.GetDirectoryName(extractedEntry);
            if (sourceDirectory == null)
                return null;
            foreach (var sourcePath in Directory.EnumerateFiles(sourceDirectory, "*", SearchOption.AllDirectories))
            {
                var relative = Path.GetRelativePath(sourceDirectory, sourcePath);
                var destinationPath = Path.Combine(payloadDirectory, relative);
                Directory.CreateDirectory(Path.GetDirectoryName(destinationPath)!);
                File.Copy(sourcePath, destinationPath, true);
            }
            if (!HasRequiredPayloadFiles(expected, requiredPayloadFiles))
                return null;

            File.WriteAllText(
                Path.Combine(cacheDir, ".fetched-at"),
                DateTime.UtcNow.ToString("O"));
            return expected;
        }
        catch
        {
            return null;
        }
        finally
        {
            _cacheLock.Release();
        }
    }

    private string GetRepositoryCacheDirectory()
    {
        var invalid = Path.GetInvalidFileNameChars();
        var safeRepo = string.Join("_", _config.GithubRepo.Split(invalid));
        var safeBranch = string.Join("_", _config.GithubBranch.Split(invalid));
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "QuickWingetSetup", "cache", "repositories", safeRepo, safeBranch);
    }

    private bool IsPayloadCacheFresh(
        string cacheDirectory,
        string entryPath,
        string[]? requiredPayloadFiles)
    {
        if (!HasRequiredPayloadFiles(entryPath, requiredPayloadFiles))
            return false;

        var stampPath = Path.Combine(cacheDirectory, ".fetched-at");
        if (!File.Exists(stampPath))
            return false;

        var ttl = TimeSpan.FromDays(Math.Max(0, _config.CacheTTLDays));
        return ttl > TimeSpan.Zero
            && DateTime.UtcNow - File.GetLastWriteTimeUtc(stampPath) < ttl;
    }

    private static bool HasRequiredPayloadFiles(string? entryPath, string[]? requiredPayloadFiles)
    {
        if (string.IsNullOrEmpty(entryPath) || !File.Exists(entryPath))
            return false;
        if (requiredPayloadFiles == null || requiredPayloadFiles.Length == 0)
            return true;

        var payloadRoot = Path.GetDirectoryName(entryPath);
        if (payloadRoot == null)
            return false;
        var trustedRoot = Path.GetFullPath(payloadRoot).TrimEnd(Path.DirectorySeparatorChar)
            + Path.DirectorySeparatorChar;

        foreach (var relativePath in requiredPayloadFiles)
        {
            if (string.IsNullOrWhiteSpace(relativePath)
                || relativePath.Contains("..")
                || Path.IsPathRooted(relativePath))
            {
                return false;
            }

            var candidate = Path.GetFullPath(Path.Combine(
                payloadRoot,
                relativePath.Replace('/', Path.DirectorySeparatorChar)));
            if (!candidate.StartsWith(trustedRoot, StringComparison.OrdinalIgnoreCase)
                || !File.Exists(candidate))
            {
                return false;
            }
        }
        return true;
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
