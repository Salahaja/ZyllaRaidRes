// watcher_job.h -- start a helper process that cannot outlive the game.
//
// The helper goes into a job object set to kill everything in it when the
// last handle to the job closes. The game holds that one handle, so however
// the game ends -- a normal exit, a crash, Task Manager -- Windows closes it
// and ends the helper and everything the helper started (the python behind
// the WindowsApps python.exe, and the headless Chrome) along with it.
//
// Shared by RaidResLock.dll and test_lockjob.exe, so the test proves the
// code the DLL runs.

#pragma once

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

// Starts `cmdline` hidden in `cwd`. Returns the job (keep it open while the
// game runs), or nullptr when no job could be made -- then the helper still
// runs, and is left to notice the game has gone by itself (watch --parent).
inline HANDLE StartInJob(char *cmdline, const char *cwd, DWORD *pid) {
    // Not inheritable: a handle held by anything inside the job would keep
    // the job open after the game, and nothing would be killed.
    HANDLE job = CreateJobObjectA(nullptr, nullptr);
    if (job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                     &limits, sizeof(limits))) {
            CloseHandle(job);
            job = nullptr;
        }
    }

    STARTUPINFOA si = {};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi = {};
    // Suspended until it is in the job, so nothing it starts can slip out.
    if (!CreateProcessA(nullptr, cmdline, nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr, cwd, &si, &pi)) {
        if (job) CloseHandle(job);
        return nullptr;
    }
    if (job && !AssignProcessToJobObject(job, pi.hProcess)) {
        CloseHandle(job);
        job = nullptr;
    }
    ResumeThread(pi.hThread);
    if (pid) *pid = pi.dwProcessId;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return job;
}

// How many processes are in the job right now.
inline DWORD JobProcessCount(HANDLE job) {
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info = {};
    if (!job || !QueryInformationJobObject(job, JobObjectBasicAccountingInformation,
                                           &info, sizeof(info), nullptr))
        return 0;
    return info.ActiveProcesses;
}
