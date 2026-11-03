// Stress workers for CPU, RAM and disk. Compiled in memory by PowerShell Add-Type (.NET Framework csc = C# 5 only:
// no string interpolation, no ?. operator, no expression-bodied members, no nameof).
// One StressRunner runs one test at a time on its own background threads; the UI only polls its properties.
using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;

namespace WonderKid
{
    public class StressRunner
    {
        private volatile bool _stop;
        private long _errors;
        private long _ops;
        private long _bytesDone;
        private DateTime _start;
        private int _seconds;
        private Thread _main;
        private volatile string _status = "idle";   // idle | running | completed | errors | crashed | stopped
        private volatile string _error = "";
        private volatile string _detail = "";
        private volatile int _threads;
        private double _mbps;
        private string _filePath;

        public string Kind = "";
        public string Status { get { return _status; } }
        public string Error { get { return _error; } }
        public string Detail { get { return _detail; } }
        public long Errors { get { return Interlocked.Read(ref _errors); } }
        public long Ops { get { return Interlocked.Read(ref _ops); } }
        public int Threads { get { return _threads; } }
        public double GBTested { get { return Interlocked.Read(ref _bytesDone) / 1073741824.0; } }
        public double MBps { get { return _mbps; } }
        public bool IsRunning { get { return _status == "running"; } }
        public int Seconds { get { return _seconds; } }

        public double Progress
        {
            get
            {
                if (_seconds <= 0 || _status == "idle") return 0;
                if (_status != "running") return 1;
                double p = (DateTime.UtcNow - _start).TotalSeconds / _seconds;
                return p > 1 ? 1 : (p < 0 ? 0 : p);
            }
        }

        public int SecondsLeft
        {
            get
            {
                if (_status != "running") return 0;
                int left = _seconds - (int)(DateTime.UtcNow - _start).TotalSeconds;
                return left < 0 ? 0 : left;
            }
        }

        private bool TimeUp() { return (DateTime.UtcNow - _start).TotalSeconds >= _seconds; }
        private bool Done() { return _stop || TimeUp(); }

        // kind: cpu | ram | disk. sizeBytes: RAM to test / disk file size. filePath: disk test file (on the system drive).
        public void Start(string kind, int seconds, long sizeBytes, string filePath)
        {
            if (_status == "running") throw new InvalidOperationException("a test is already running");
            _stop = false; _errors = 0; _ops = 0; _bytesDone = 0; _mbps = 0; _threads = 0;
            _error = ""; _detail = ""; Kind = kind; _seconds = seconds; _filePath = filePath;
            _start = DateTime.UtcNow;
            _status = "running";
            _main = new Thread(delegate () { Run(kind, sizeBytes, filePath); });
            _main.IsBackground = true;
            _main.Start();
        }

        public void Stop() { _stop = true; }

        // Waits for the worker to finish (after Stop or time-out). Returns true if it finished in time.
        public bool Wait(int milliseconds)
        {
            Thread t = _main;
            if (t == null) return true;
            return t.Join(milliseconds);
        }

        private void Run(string kind, long sizeBytes, string filePath)
        {
            try
            {
                if (kind == "cpu") RunCpu();
                else if (kind == "ram") RunRam(sizeBytes);
                else if (kind == "disk") RunDisk(sizeBytes, filePath);
                else throw new ArgumentException("unknown test kind: " + kind);
                if (_status == "running")
                {
                    if (_stop) _status = "stopped";
                    else if (Errors > 0) _status = "errors";
                    else _status = "completed";
                }
            }
            catch (Exception ex)
            {
                _error = ex.GetType().Name + ": " + ex.Message;
                _status = "crashed";
            }
            finally
            {
                if (kind == "disk") TryDelete(filePath);
                if (kind == "ram") { GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect(); }
            }
        }

        // ---------- CPU: one thread per logical core, float + integer work with a known answer ----------
        private static double FloatWork()
        {
            double acc = 0;
            for (int i = 1; i <= 200000; i++) acc += Math.Sqrt(i) * Math.Sin(i * 0.001);
            return acc;
        }

        private static long IntWork()
        {
            long x = 17;
            for (int i = 0; i < 300000; i++) x = unchecked(x * 6364136223846793005L + 1442695040888963407L) ^ (x >> 13);
            return x;
        }

        private void RunCpu()
        {
            double fRef = FloatWork();
            long iRef = IntWork();
            int n = Environment.ProcessorCount;
            _threads = n;
            string crash = null;
            Thread[] ts = new Thread[n];
            for (int k = 0; k < n; k++)
            {
                ts[k] = new Thread(delegate ()
                {
                    try
                    {
                        while (!Done())
                        {
                            if (FloatWork() != fRef) Interlocked.Increment(ref _errors);
                            if (IntWork() != iRef) Interlocked.Increment(ref _errors);
                            Interlocked.Increment(ref _ops);
                        }
                    }
                    catch (Exception ex) { crash = ex.Message; _stop = true; }
                });
                ts[k].IsBackground = true;
                ts[k].Priority = ThreadPriority.BelowNormal;   // full load, but the UI thread stays responsive
                ts[k].Start();
            }
            foreach (Thread t in ts) t.Join();
            if (crash != null) throw new Exception("CPU worker failed: " + crash);
            _detail = n + " threads, " + Ops + " work units";
        }

        // ---------- RAM: allocate 64 MB blocks, write a pattern, read back and compare ----------
        private const int Block = 64 * 1024 * 1024;

        private static void Fill(byte[] b, byte seed)
        {
            // Fill the first 4 KB by formula, then copy it doubling (fast and still position-dependent per pass).
            int first = Math.Min(4096, b.Length);
            for (int i = 0; i < first; i++) b[i] = (byte)(seed ^ (i * 31) ^ (i >> 8));
            int filled = first;
            while (filled < b.Length)
            {
                int n = Math.Min(filled, b.Length - filled);
                Buffer.BlockCopy(b, 0, b, filled, n);
                filled += n;
            }
        }

        private static int Verify(byte[] b, byte seed)
        {
            int bad = 0;
            for (int i = 0; i < b.Length; i++)
            {
                int j = i % 4096;
                if (b[i] != (byte)(seed ^ (j * 31) ^ (j >> 8))) { bad++; if (bad > 1000) break; }
            }
            return bad;
        }

        private void RunRam(long sizeBytes)
        {
            List<byte[]> blocks = new List<byte[]>();
            try
            {
                long want = sizeBytes / Block;
                if (want < 1) want = 1;
                for (long i = 0; i < want && !Done(); i++)
                {
                    try { blocks.Add(new byte[Block]); }
                    catch (OutOfMemoryException) { break; }   // test what we could get
                }
                _detail = (blocks.Count * 64) + " MB allocated";
                int pass = 0;
                while (!Done())
                {
                    for (int i = 0; i < blocks.Count && !Done(); i++)
                    {
                        byte seed = (byte)(pass * 37 + i * 11);
                        Fill(blocks[i], seed);
                        int bad = Verify(blocks[i], seed);
                        if (bad > 0) Interlocked.Add(ref _errors, bad);
                        Interlocked.Add(ref _bytesDone, Block);
                    }
                    pass++;
                }
                _detail = (blocks.Count * 64) + " MB, " + pass + " passes";
            }
            finally
            {
                blocks.Clear();
            }
        }

        // ---------- Disk: write a file with write-through, read back, verify; repeat until time is up ----------
        private const int Chunk = 4 * 1024 * 1024;

        private static void FillChunk(byte[] b, int pass, long index)
        {
            Fill(b, (byte)(pass * 13 + index));
            byte[] idx = BitConverter.GetBytes(index);
            Buffer.BlockCopy(idx, 0, b, 0, 8);
        }

        private void RunDisk(long sizeBytes, string filePath)
        {
            long chunks = sizeBytes / Chunk;
            if (chunks < 1) chunks = 1;
            byte[] w = new byte[Chunk];
            byte[] r = new byte[Chunk];
            byte[] expect = new byte[Chunk];
            int pass = 0;
            while (!Done())
            {
                DateTime t0 = DateTime.UtcNow;
                long written = 0;
                using (FileStream fs = new FileStream(filePath, FileMode.Create, FileAccess.Write, FileShare.None, Chunk, FileOptions.WriteThrough))
                {
                    for (long c = 0; c < chunks && !Done(); c++)
                    {
                        FillChunk(w, pass, c);
                        fs.Write(w, 0, Chunk);
                        written += Chunk;
                        double secs = (DateTime.UtcNow - t0).TotalSeconds;
                        if (secs > 0.5) _mbps = Math.Round(written / 1048576.0 / secs, 0);
                    }
                    fs.Flush(true);
                }
                using (FileStream fs = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.None, Chunk, FileOptions.SequentialScan))
                {
                    long c = 0;
                    while (c * Chunk < written && !_stop)
                    {
                        int got = 0;
                        while (got < Chunk)
                        {
                            int n = fs.Read(r, got, Chunk - got);
                            if (n <= 0) break;
                            got += n;
                        }
                        if (got != Chunk) { Interlocked.Increment(ref _errors); break; }
                        FillChunk(expect, pass, c);
                        for (int i = 0; i < Chunk; i += 512) { if (r[i] != expect[i] || r[i + 511] != expect[i + 511]) { Interlocked.Increment(ref _errors); break; } }
                        Interlocked.Add(ref _bytesDone, Chunk);
                        c++;
                    }
                }
                pass++;
            }
            _detail = pass + " passes, last write " + _mbps + " MB/s";
        }

        private static void TryDelete(string path)
        {
            try { if (!string.IsNullOrEmpty(path) && File.Exists(path)) File.Delete(path); } catch { }
        }
    }
}
