// Doki.exe: launcher compiled with the built-in .NET Framework csc (C# 5). D-020.
// Defender-friendly by design: no packed/embedded script, no "powershell -ExecutionPolicy Bypass -WindowStyle Hidden" command line.
// It hosts Windows PowerShell 5.1 in this process (System.Management.Automation from the GAC) and runs app\main.ps1 from the folder next to it.
// The execution policy is relaxed for this in-process runspace only; nothing system-wide is changed.
using System;
using System.Collections.Generic;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Doki")]
[assembly: AssemblyDescription("Reza Dadsetan - laptop quality-control tool")]
[assembly: AssemblyCompany("Reza Dadsetan")]
[assembly: AssemblyProduct("Doki")]
[assembly: AssemblyCopyright("Reza Dadsetan")]
[assembly: AssemblyVersion("0.0.0.0")]
[assembly: AssemblyFileVersion("0.0.0.0")]
[assembly: AssemblyInformationalVersion("0.0.0")]

static class Launcher
{
    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "app\\main.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("app\\main.ps1 was not found next to Doki.exe.\r\nExtract the whole zip, not only the exe.", "Doki", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        try
        {
            InitialSessionState iss = InitialSessionState.CreateDefault();
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;   // this process only
            using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
            {
                rs.ApartmentState = ApartmentState.STA;               // WPF needs STA
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddCommand(script);
                    // Pass "-Switch" and "-Name value" arguments through (e.g. -Lang en, -SelfTest).
                    for (int i = 0; i < args.Length; i++)
                    {
                        string a = args[i];
                        if (a.StartsWith("-") && a.Length > 1)
                        {
                            string name = a.Substring(1);
                            if (i + 1 < args.Length && !args[i + 1].StartsWith("-")) { ps.AddParameter(name, args[i + 1]); i++; }
                            else { ps.AddParameter(name); }
                        }
                    }
                    ps.Invoke();
                    if (ps.HadErrors && ps.Streams.Error.Count > 0)
                    {
                        StringBuilder sb = new StringBuilder();
                        int n = 0;
                        foreach (ErrorRecord e in ps.Streams.Error) { sb.AppendLine(e.ToString()); if (++n >= 3) break; }
                        TryLog(dir, sb.ToString());
                    }
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            TryLog(dir, ex.ToString());
            MessageBox.Show("Doki could not start:\r\n" + ex.Message, "Doki", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    static void TryLog(string dir, string text)
    {
        try
        {
            string logs = Path.Combine(dir, "Logs");
            Directory.CreateDirectory(logs);
            File.AppendAllText(Path.Combine(logs, "launcher.log"), DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + text + Environment.NewLine, Encoding.UTF8);
        }
        catch { }
    }
}
