<#
  check_lock_cleanup.ps1 -- is anything RaidResLock.dll started still running?

  RaidResLock.dll starts the lock watcher (python raidres_lock.py watch) with
  the game, and the watcher starts a headless Chrome on the first lock or
  unlock. When the game closes, both should go with it. This lists what is
  running and says, for each watcher and each watcher Chrome, whether the
  game that started it is still open.

    powershell -ExecutionPolicy Bypass -File check_lock_cleanup.ps1
    powershell -ExecutionPolicy Bypass -File check_lock_cleanup.ps1 -WaitForExit
    powershell -ExecutionPolicy Bypass -File check_lock_cleanup.ps1 -StopLeftovers

  -WaitForExit    waits for every WoW.exe to close, allows 5 seconds, then
                  reports: start it, close the game, read the verdict.
  -StopLeftovers  ends whatever belongs to a game that has already closed.
                  Only the watcher and its Chrome profile (chrome-cdp-raidres);
                  your own Chrome is never touched.
#>
param([switch]$WaitForExit, [switch]$StopLeftovers)

function Get-All {
    $all = @{}
    Get-CimInstance Win32_Process | ForEach-Object { $all[[int]$_.ProcessId] = $_ }
    return $all
}

# The nearest ancestor that passes $test, or $null. Windows reuses PIDs, so a
# "parent" that started after its child is somebody else and ends the walk.
function Get-Ancestor($all, $proc, [scriptblock]$test) {
    $seen = @{}
    $p = $proc
    while ($p -and -not $seen[[int]$p.ProcessId]) {
        $seen[[int]$p.ProcessId] = $true
        $parent = $all[[int]$p.ParentProcessId]
        if (-not $parent -or $parent.CreationDate -gt $p.CreationDate) { return $null }
        if (& $test $parent) { return $parent }
        $p = $parent
    }
    return $null
}

$isGame = { param($p) $p.Name -ieq 'WoW.exe' }
$isWatcher = { param($p) $p.Name -match '^pythonw?\.exe$' -and $p.CommandLine -match 'raidres_lock\.py' }
$isCdpChrome = { param($p) $p.Name -ieq 'chrome.exe' -and $p.CommandLine -match 'chrome-cdp-raidres' }

function Show-Time($p) { $p.CreationDate.ToString('HH:mm:ss') }

function Report {
    $all = Get-All
    $games = @($all.Values | Where-Object { & $isGame $_ } | Sort-Object CreationDate)
    # A watcher is the first raidres_lock.py python in its chain: the
    # WindowsApps python.exe starts the real one as its child.
    $watchers = @($all.Values | Where-Object {
        (& $isWatcher $_) -and -not (Get-Ancestor $all $_ $isWatcher)
    } | Sort-Object CreationDate)
    $chromes = @($all.Values | Where-Object {
        (& $isCdpChrome $_) -and $_.CommandLine -notmatch '--type='
    } | Sort-Object CreationDate)
    $leftovers = @()

    "Games running: $($games.Count)"
    foreach ($g in $games) { "  WoW.exe $($g.ProcessId)  started $(Show-Time $g)" }
    ""
    "Lock watchers: $($watchers.Count)"
    foreach ($w in $watchers) {
        $game = Get-Ancestor $all $w $isGame
        if ($game) {
            "  PID $($w.ProcessId)  started $(Show-Time $w)  with game $($game.ProcessId)"
        } else {
            "  PID $($w.ProcessId)  started $(Show-Time $w)  LEFT BEHIND: its game has closed"
            $leftovers += $w
        }
    }
    ""
    "Watcher Chrome (profile chrome-cdp-raidres): $($chromes.Count)"
    foreach ($c in $chromes) {
        $helpers = @($all.Values | Where-Object { $_.ParentProcessId -eq $c.ProcessId }).Count
        $owner = Get-Ancestor $all $c $isWatcher
        while ($owner -and ($up = Get-Ancestor $all $owner $isWatcher)) { $owner = $up }
        $game = if ($owner) { Get-Ancestor $all $owner $isGame } else { $null }
        $line = "  PID $($c.ProcessId)  started $(Show-Time $c)  $helpers helper process(es)"
        if ($game) {
            "$line  with game $($game.ProcessId)"
        } elseif ($owner) {
            "$line  LEFT BEHIND: started by watcher $($owner.ProcessId), whose game has closed"
            $leftovers += $c
        } else {
            "$line  LEFT BEHIND: the watcher that started it is gone"
            $leftovers += $c
        }
    }
    ""
    if ($leftovers.Count -gt 0) {
        "NOT CLEAN: $($leftovers.Count) process tree(s) outlived the game that started them."
    } elseif ($games.Count -gt 0) {
        "OK so far: everything running belongs to an open game."
        "Close the game and run this again, or run it with -WaitForExit."
    } else {
        "CLEAN: no watcher and no watcher Chrome left behind."
    }

    if ($StopLeftovers -and $leftovers.Count -gt 0) {
        ""
        foreach ($p in $leftovers) {
            & taskkill /T /F /PID $p.ProcessId | Out-Null
            "stopped $($p.Name) $($p.ProcessId) and its children"
        }
    }
}

if ($WaitForExit) {
    $wow = @(Get-Process -Name WoW -ErrorAction SilentlyContinue)
    if ($wow.Count -gt 0) {
        "Waiting for $($wow.Count) WoW.exe to close..."
        $wow | ForEach-Object { $_.WaitForExit() }
        "Closed. Giving it 5 seconds to clean up..."
        Start-Sleep -Seconds 5
        ""
    }
}
Report
