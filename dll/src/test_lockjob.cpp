// test_lockjob.exe -- does the lock watcher really go when the game goes?
//
// Plays the game: starts python through StartInJob, the same function
// RaidResLock.dll uses, and has it start Chrome the way the watcher does on
// its first lock or unlock -- raidres_lock.py's own start_chrome, headless,
// on about:blank, with a throwaway profile under <temp dir> and port 9339 so
// it never meets the real one. Then it ends the way a game can.
//
//   test_lockjob.exe <tools dir> <temp dir> crash   ends with no cleanup at all
//   test_lockjob.exe <tools dir> <temp dir> stop    ends as the DLL's StopWatcher does
//
// Afterwards nothing may be running with <temp dir> on its command line.

#include <cstdio>
#include <cstring>

#include "watcher_job.h"

int main(int argc, char **argv) {
    if (argc != 4) {
        std::printf("usage: test_lockjob <tools dir> <temp dir> crash|stop\n");
        return 2;
    }
    char python[MAX_PATH];
    DWORD n = SearchPathA(nullptr, "python.exe", nullptr, MAX_PATH, python, nullptr);
    if (n == 0 || n >= MAX_PATH) {
        std::printf("python.exe is not on PATH\n");
        return 2;
    }

    char cmdline[4096];
    _snprintf(cmdline, sizeof(cmdline),
              "\"%s\" -c \"import os, sys, time; "
              "os.environ['LOCALAPPDATA'] = sys.argv[2]; sys.path.insert(0, sys.argv[1]); "
              "import raidres_lock as w; w.CDP_PORT = 9339; "
              "ok = w.start_chrome('about:blank', headless=True); "
              "open(os.path.join(sys.argv[2], 'ready'), 'w').write(str(ok)); "
              "time.sleep(600)\" \"%s\" \"%s\"",
              python, argv[1], argv[2]);

    DWORD pid = 0;
    HANDLE job = StartInJob(cmdline, nullptr, &pid);
    if (!job) {
        std::printf("FAIL: no job; the helper (pid %lu) runs unguarded\n", pid);
        return 1;
    }

    char ready[MAX_PATH];
    _snprintf(ready, sizeof(ready), "%s\\ready", argv[2]);
    bool up = false;
    for (int i = 0; i < 60 && !up; ++i) {
        Sleep(500);
        up = GetFileAttributesA(ready) != INVALID_FILE_ATTRIBUTES;
    }
    std::printf("helper pid %lu; Chrome %s; %lu process(es) in the game's job\n",
                pid, up ? "started" : "NOT started", JobProcessCount(job));
    std::fflush(stdout);
    if (!up) return 1;

    if (std::strcmp(argv[3], "stop") == 0) {
        TerminateJobObject(job, 0);
        CloseHandle(job);
        return 0;
    }
    // A crash: no destructors, no DLL detach, the job handle left open for
    // Windows to close.
    TerminateProcess(GetCurrentProcess(), 3);
    return 3;
}
