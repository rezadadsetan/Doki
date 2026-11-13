// Install the compressed portable payload; keep the application launcher unchanged.
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Doki")]
[assembly: AssemblyProduct("Doki")]
[assembly: AssemblyDescription("Doki single-file installer and launcher")]
[assembly: AssemblyVersion("2.9.0.0")]
[assembly: AssemblyFileVersion("2.9.0.0")]

static class SingleFileWrapper
{
    internal static string InstallDirectory()
    {
        string native = Environment.GetEnvironmentVariable("ProgramW6432");
        if (string.IsNullOrEmpty(native)) native = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        return Path.Combine(native, "doki-standalone");
    }

    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            string destination = InstallDirectory();
#if PACKAGING_TEST
            if (args.Length != 2 || args[0] != "--test-install") return 2;
            destination = Path.GetFullPath(args[1]);
#endif
            using (Mutex gate = new Mutex(false, "Global\\DokiStandaloneSingleFileInstall"))
            {
                bool held = false;
                try
                {
                    try { held = gate.WaitOne(TimeSpan.FromSeconds(30)); }
                    catch (AbandonedMutexException) { held = true; }
                    if (!held) throw new IOException("Another Doki installation is in progress. Try again shortly.");
                    Install(destination);
                }
                finally { if (held) gate.ReleaseMutex(); }
            }
#if PACKAGING_TEST
            return 0;
#else
            ProcessStartInfo start = new ProcessStartInfo(Path.Combine(destination, "Doki.exe"), string.Join(" ", Array.ConvertAll(args, Quote)));
            start.WorkingDirectory = destination;
            start.UseShellExecute = true;
            Process.Start(start);
            return 0;
#endif
        }
        catch (Exception error)
        {
#if PACKAGING_TEST
            Console.Error.WriteLine(error.Message);
#else
            MessageBox.Show("Doki could not install or start.\r\n" + error.Message, "Doki", MessageBoxButtons.OK, MessageBoxIcon.Error);
#endif
            return 1;
        }
    }

    static void CheckPath(string path)
    {
        for (string p = Path.GetFullPath(path); !string.IsNullOrEmpty(p); p = Path.GetDirectoryName(p))
            if ((Directory.Exists(p) || File.Exists(p)) && (File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Doki installation paths must not contain symbolic links or junctions.");
    }

    static string EntryPath(string root, string name)
    {
        root = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        string file = Path.GetFullPath(Path.Combine(root, name));
        if (!file.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new IOException("Invalid package path.");
        CheckPath(file);
        return file;
    }

    static bool Same(Stream input, string file)
    {
        if (!File.Exists(file)) return false;
        using (SHA256 hash = SHA256.Create())
        using (Stream existing = File.OpenRead(file))
            return Convert.ToBase64String(hash.ComputeHash(input)) == Convert.ToBase64String(hash.ComputeHash(existing));
    }

    static void CopyTree(string source, string target)
    {
        CheckPath(source);
        Directory.CreateDirectory(target);
        foreach (string file in Directory.GetFiles(source))
        {
            CheckPath(file);
            File.Copy(file, Path.Combine(target, Path.GetFileName(file)));
        }
        foreach (string folder in Directory.GetDirectories(source)) CopyTree(folder, Path.Combine(target, Path.GetFileName(folder)));
    }

    static void DeleteOwned(string path, string destination)
    {
        string prefix = Path.GetFullPath(destination) + ".install-";
        if (!Path.GetFullPath(path).StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new IOException("Invalid staging path.");
        CheckPath(path);
        if (Directory.Exists(path)) Directory.Delete(path, true);
    }

    static void Install(string destination)
    {
        CheckPath(destination);
        string installedExe = Path.Combine(destination, "Doki.exe");
        if (File.Exists(installedExe))
        {
            CheckPath(installedExe);
            Version installedVersion;
            if (Version.TryParse(FileVersionInfo.GetVersionInfo(installedExe).FileVersion, out installedVersion) &&
                installedVersion > Assembly.GetExecutingAssembly().GetName().Version &&
                File.Exists(EntryPath(destination, "app/main.ps1"))) return;
        }
        using (Stream payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
        using (ZipArchive archive = new ZipArchive(payload, ZipArchiveMode.Read))
        {
            bool changed = false;
            foreach (ZipArchiveEntry entry in archive.Entries)
            {
                if (entry.Name.Length == 0) continue;
                using (Stream input = entry.Open())
                    if (!Same(input, EntryPath(destination, entry.FullName))) changed = true;
            }
            if (!changed) return;
            foreach (Process running in Process.GetProcessesByName("Doki"))
            using (running)
            {
                try
                {
                    if (string.Equals(running.MainModule.FileName, Path.Combine(destination, "Doki.exe"), StringComparison.OrdinalIgnoreCase))
                        throw new IOException("Close Doki before installing or repairing its files.");
                }
                catch (System.ComponentModel.Win32Exception) { throw new IOException("Close any running Doki window before installing."); }
            }
            string staging = destination + ".install-" + Guid.NewGuid().ToString("N");
            string backup = destination + ".install-" + Guid.NewGuid().ToString("N");
            bool installed = false;
            try
            {
                if (Directory.Exists(destination)) CopyTree(destination, staging);
                else Directory.CreateDirectory(staging);
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    string file = EntryPath(staging, entry.FullName);
                    if (entry.Name.Length == 0) { Directory.CreateDirectory(file); continue; }
                    Directory.CreateDirectory(Path.GetDirectoryName(file));
                    using (Stream input = entry.Open())
                    using (Stream output = File.Create(file)) { input.CopyTo(output); }
                    using (Stream input = entry.Open())
                        if (!Same(input, file)) throw new IOException("Package verification failed.");
                }
                if (Directory.Exists(destination)) Directory.Move(destination, backup);
                try { Directory.Move(staging, destination); installed = true; }
                catch
                {
                    if (Directory.Exists(backup)) Directory.Move(backup, destination);
                    throw;
                }
            }
            finally
            {
                DeleteOwned(staging, destination);
                // Never delete the original backup unless the replacement succeeded.
                if (installed) DeleteOwned(backup, destination);
            }
        }
    }

    internal static string Quote(string value)
    {
        System.Text.StringBuilder result = new System.Text.StringBuilder("\"");
        int slashes = 0;
        foreach (char c in value)
        {
            if (c == '\\') { slashes++; continue; }
            result.Append('\\', c == '"' ? slashes * 2 + 1 : slashes);
            result.Append(c);
            slashes = 0;
        }
        result.Append('\\', slashes * 2);
        return result.Append('"').ToString();
    }
}
