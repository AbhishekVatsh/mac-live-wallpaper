using System.Diagnostics;

namespace LiveWallpaper;

static class Program
{
    const string RunningMutex = @"Local\LiveWallpaper.Running";
    const string ExitRequest = @"Local\LiveWallpaper.Exit";

    [STAThread]
    static void Main(string[] args)
    {
        // Only one copy may run, or two videos could play at once. A newly opened copy
        // (say, a fresh install) asks the running one to Exit, then takes over.
        using var exitRequest = new EventWaitHandle(false, EventResetMode.AutoReset, ExitRequest);
        using var running = new Mutex(false, RunningMutex);
        var owned = Acquire(running, TimeSpan.Zero);
        if (!owned)
        {
            exitRequest.Set();
            owned = Acquire(running, TimeSpan.FromSeconds(8));
            if (!owned)
            {
                foreach (var other in Process.GetProcessesByName("LiveWallpaper"))
                    if (other.Id != Environment.ProcessId) try { other.Kill(); } catch { }
                owned = Acquire(running, TimeSpan.FromSeconds(5));
            }
        }
        exitRequest.Reset();

        ApplicationConfiguration.Initialize();
        var app = new App(args);
        var ui = SynchronizationContext.Current!;

        // Exit when another copy asks.
        new Thread(() =>
        {
            exitRequest.WaitOne();
            ui.Post(_ => app.Exit(), null);
        }) { IsBackground = true }.Start();

        Application.Run(app);
        if (owned) running.ReleaseMutex();
    }

    static bool Acquire(Mutex mutex, TimeSpan timeout)
    {
        try { return mutex.WaitOne(timeout); }
        catch (AbandonedMutexException) { return true; }   // the previous copy crashed
    }
}
