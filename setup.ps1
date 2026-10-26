# sts-fleet one-click setup. Run it through setup.bat (double-click).
#
# Works out what this machine is and sets up whatever applies:
#   MT5 machine  -> finds every MT5 terminal, installs + compiles the heartbeat EA,
#                   links MT5's Common\Files\sts_fleet into Dropbox\ClaudeHub\fleet,
#                   writes the machine name so the EA needs no inputs.
#   Server       -> finds (or installs) Python, installs the MCP SDK, registers
#                   sts-fleet with Claude Code and Claude Desktop, runs a self-test.
# Safe to run again any time: everything is checked before it's changed.
#
# Optional:  setup.bat -Role Mt5 | Server | Both     (default: Auto)
#            setup.bat -NoTest                          (skip the server self-test)

param(
    [ValidateSet('Auto', 'Mt5', 'Server', 'Both')][string]$Role = 'Auto',
    [switch]$NoTest
)

$ErrorActionPreference = 'Stop'
$Start     = Get-Date
$Here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$ClaudeHub = Split-Path -Parent $Here
$FleetDir  = Join-Path $ClaudeHub 'fleet'
# Machine name: the one ClaudeHub / a previous setup gave this machine, else the Windows name.
$Machine = $null
try {
    $hubCfg = Join-Path $env:USERPROFILE '.claude\claudehub.json'
    if (Test-Path $hubCfg) { $Machine = (Get-Content $hubCfg -Raw | ConvertFrom-Json).machine }
} catch { }
if (-not $Machine) { $Machine = [Environment]::GetEnvironmentVariable('STS_MACHINE', 'User') }
if (-not $Machine) { $Machine = $env:COMPUTERNAME }
$Machine = "$Machine".Trim().ToUpper()
$LogLines  = New-Object System.Collections.Generic.List[string]
$Problems  = 0

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c; $LogLines.Add($m) }
function Head([string]$m) { Say ''; Say "== $m ==" 'Cyan' }
function Ok([string]$m)   { Say "  [OK]   $m" 'Green' }
function Info([string]$m) { Say "  [..]   $m" 'Gray' }
function Warn([string]$m) { Say "  [WARN] $m" 'Yellow' }
function Bad([string]$m)  { Say "  [FAIL] $m" 'Red'; $script:Problems++ }

trap {
    Bad "Setup stopped unexpectedly: $($_.Exception.Message)"
    Bad "  at $($_.InvocationInfo.PositionMessage -replace '\s+', ' ')"
    try {
        $lf = Join-Path $FleetDir "setup\$Machine.txt"
        New-Item -ItemType Directory -Force -Path (Split-Path $lf) | Out-Null
        $LogLines | Set-Content -Path $lf -Encoding UTF8
        Say "Log saved to $lf" 'DarkGray'
    } catch { }
    break
}

Say "sts-fleet setup on $Machine as $env:USERNAME  ($($Start.ToString('yyyy-MM-dd HH:mm')))" 'White'

# --------------------------------------------------------------------------
Head 'Fleet folder'
# --------------------------------------------------------------------------
if ($ClaudeHub -notmatch 'Dropbox') {
    Warn "This folder isn't inside Dropbox: $ClaudeHub"
    Warn 'Other machines will not see the fleet data. Move sts-fleet into Dropbox\ClaudeHub and run again.'
}
foreach ($sub in 'status', 'deals', 'events', 'setup') {
    New-Item -ItemType Directory -Force -Path (Join-Path $FleetDir $sub) | Out-Null
}
Ok "Fleet data folder: $FleetDir"
$rulesDst = Join-Path $FleetDir 'firm_rules.json'
if (-not (Test-Path $rulesDst)) {
    $rulesSrc = Join-Path $Here 'firm_rules.json'
    if (-not (Test-Path $rulesSrc)) { $rulesSrc = Join-Path $Here 'firm_rules.example.json' }
    Copy-Item $rulesSrc $rulesDst
    Ok 'Copied firm_rules.json into the fleet folder (shared by all machines)'
} else {
    Info 'firm_rules.json already in fleet folder, left as is'
}
[Environment]::SetEnvironmentVariable('STS_FLEET_DIR', $FleetDir, 'User')
[Environment]::SetEnvironmentVariable('STS_MACHINE', $Machine, 'User')
$env:STS_FLEET_DIR = $FleetDir
$env:STS_MACHINE = $Machine
Ok "User environment: STS_FLEET_DIR, STS_MACHINE=$Machine"

# --------------------------------------------------------------------------
# Discovery
# --------------------------------------------------------------------------
function Find-Mt5Terminals {
    $list = @{}
    $root = Join-Path $env:APPDATA 'MetaQuotes\Terminal'
    if (Test-Path $root) {
        foreach ($d in Get-ChildItem $root -Directory -ErrorAction SilentlyContinue) {
            $plat = $null
            if (Test-Path (Join-Path $d.FullName 'MQL5')) { $plat = 'MT5' }
            elseif (Test-Path (Join-Path $d.FullName 'MQL4')) { $plat = 'MT4' }
            if (-not $plat) { continue }   # skips Common and anything else
            $install = $null
            $origin = Join-Path $d.FullName 'origin.txt'
            if (Test-Path $origin) {
                $install = (Get-Content $origin -ErrorAction SilentlyContinue | Select-Object -First 1)
                if ($install) { $install = $install.Trim() }
            }
            $list[$d.FullName.ToLower()] = [pscustomobject]@{ DataDir = $d.FullName; InstallDir = $install; Portable = $false; Platform = $plat }
        }
    }
    # Install folders already served by a data folder above are not portable copies.
    $known = @{}
    foreach ($v in $list.Values) {
        if ($v.InstallDir) { $known[$v.InstallDir.TrimEnd('\').ToLower()] = $true }
    }
    # Portable installs keep MQL5 *and* their own config/Bases next to terminal64.exe.
    # A normal install folder (e.g. under Program Files) may contain MQL5 but has neither.
    $skip = @('Windows', '$Recycle.Bin', 'System Volume Information', 'ProgramData', 'Users', 'Recovery', 'PerfLogs')
    # Local fixed disks only: never crawl mapped network shares
    $drives = @()
    if ($env:OS -eq 'Windows_NT') {
        $drives = [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }
    }
    foreach ($drv in $drives) {
        $tops = Get-ChildItem $drv.RootDirectory.FullName -Directory -ErrorAction SilentlyContinue | Where-Object { $skip -notcontains $_.Name }
        foreach ($t in $tops) {
            $exes = Get-ChildItem $t.FullName -Include 'terminal64.exe', 'terminal.exe' -Recurse -Depth 3 -File -ErrorAction SilentlyContinue
            foreach ($exe in $exes) {
                $dir = $exe.DirectoryName
                $key = $dir.TrimEnd('\').ToLower()
                $mql = if ($exe.Name -ieq 'terminal64.exe') { 'MQL5' } else { 'MQL4' }
                $isPortable = (Test-Path (Join-Path $dir $mql)) -and
                              ((Test-Path (Join-Path $dir 'config')) -or (Test-Path (Join-Path $dir 'Bases')))
                if ($isPortable -and -not $known.ContainsKey($key) -and -not $list.ContainsKey($dir.ToLower())) {
                    $list[$dir.ToLower()] = [pscustomobject]@{ DataDir = $dir; InstallDir = $dir; Portable = $true; Platform = $(if ($mql -eq 'MQL5') { 'MT5' } else { 'MT4' }) }
                }
            }
        }
    }
    return @($list.Values)
}

function Get-LastAccount([string]$dataDir) {
    $logs = Get-ChildItem (Join-Path $dataDir 'logs') -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 5
    foreach ($f in $logs) {
        $m = Select-String -Path $f.FullName -Pattern "'(\d+)': authorized on (\S+)" -Encoding Unicode -ErrorAction SilentlyContinue |
            Select-Object -Last 1
        if ($m) {
            return [pscustomobject]@{ Login = $m.Matches[0].Groups[1].Value; Server = $m.Matches[0].Groups[2].Value }
        }
    }
    return $null
}

function Guess-Firm([string]$server) {
    $s = "$server".ToUpper()
    if ($s -match 'FTMO') { return 'FTMO' }
    if ($s -match 'FTUK|FT UK') { return 'FTUK' }
    if ($s -match 'BLUE.?GUARD') { return 'BlueGuardian' }
    if ($s -match 'LITE.?FINANCE') { return 'LiteFinance' }
    if ($s -match 'ATMOS') { return 'Atmos' }
    return '?'
}

function Find-Exe([string[]]$names, [string[]]$extraPaths) {
    foreach ($n in $names) {
        $c = Get-Command $n -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { return $c.Source }
    }
    foreach ($p in $extraPaths) { if ($p -and (Test-Path $p)) { return $p } }
    return $null
}

function Get-PyVersion([string]$exe) {
    try {
        $v = (& $exe -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null | Select-Object -First 1)
        if ($v) { return [version]$v.Trim() }
    } catch { }
    return $null
}

# Returns the newest Python 3.10+ on this machine, or $null. Older ones are ignored.
function Find-Python {
    $cands = New-Object System.Collections.Generic.List[string]
    $py = Get-Command py -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($py) {
        # py -0p lists every installed interpreter with its path
        foreach ($line in (& $py.Source -0p 2>$null)) {
            if ($line -match '([A-Za-z]:\\.+?python\.exe)') { $cands.Add($Matches[1]) }
        }
    }
    foreach ($n in 'python', 'python3') {
        foreach ($c in (Get-Command $n -All -ErrorAction SilentlyContinue)) {
            if ($c.Source -notmatch 'WindowsApps') { $cands.Add($c.Source) }
        }
    }
    foreach ($root in @((Join-Path $env:LOCALAPPDATA 'Programs\Python'), $env:ProgramFiles)) {
        if (-not $root) { continue }
        foreach ($d in Get-ChildItem $root -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue) {
            $exe = Join-Path $d.FullName 'python.exe'
            if (Test-Path $exe) { $cands.Add($exe) }
        }
    }
    $best = $null; $bestVer = [version]'0.0'
    foreach ($c in ($cands | Select-Object -Unique)) {
        $v = Get-PyVersion $c
        if ($v -and $v -ge [version]'3.10' -and $v -gt $bestVer) { $best = $c; $bestVer = $v }
    }
    return $best
}

$terminals = Find-Mt5Terminals
$claude = Find-Exe @('claude') @(
    (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
    (Join-Path $env:APPDATA 'npm\claude.cmd'),
    (Join-Path $env:LOCALAPPDATA 'Programs\claude\claude.exe')
)
$desktopCfgDir = Join-Path $env:APPDATA 'Claude'
# Make sure 'claude' works in any new terminal: add its folder to the user PATH if missing.
if ($claude) {
    $cdir = Split-Path $claude
    $onPath = (("$([Environment]::GetEnvironmentVariable('Path', 'User'));" +
                "$([Environment]::GetEnvironmentVariable('Path', 'Machine'))") -split ';') |
              Where-Object { $_ -and ($_.TrimEnd('\') -ieq $cdir.TrimEnd('\')) }
    if (-not $onPath) {
        $u = "$([Environment]::GetEnvironmentVariable('Path', 'User'))"
        [Environment]::SetEnvironmentVariable('Path', (($u.TrimEnd(';') + ';' + $cdir).TrimStart(';')), 'User')
        $script:PathFixed = $cdir
    }
}

$doMt5 = $false; $doServer = $false
switch ($Role) {
    'Mt5'    { $doMt5 = $true }
    'Server' { $doServer = $true }
    'Both'   { $doMt5 = $true; $doServer = $true }
    'Auto'   {
        $doMt5 = $terminals.Count -gt 0
        $doServer = [bool]$claude -or (Test-Path $desktopCfgDir)
        if (-not $doMt5 -and -not $doServer) { $doServer = $true }
    }
}
Head 'What this machine gets'
$n5 = @($terminals | Where-Object { $_.Platform -eq 'MT5' }).Count
$n4 = @($terminals | Where-Object { $_.Platform -eq 'MT4' }).Count
Info ("Terminals found: {0} MT5, {1} MT4" -f $n5, $n4)
Info ("Claude Code CLI: {0}" -f $(if ($claude) { $claude } else { 'not found' }))
if ($script:PathFixed) { Ok "Added $($script:PathFixed) to your PATH, so 'claude' works in new terminals" }
$parts = @()
if ($doMt5) { $parts += 'MT4/MT5 heartbeat' }
if ($doServer) { $parts += 'MCP server' }
Info ("Setting up: {0}" -f ($parts -join ' + '))

# --------------------------------------------------------------------------
if ($doMt5) {
    Head 'MT5: link Common\Files\sts_fleet to Dropbox'
    $common = Join-Path $env:APPDATA 'MetaQuotes\Terminal\Common\Files'
    New-Item -ItemType Directory -Force -Path $common | Out-Null
    $link = Join-Path $common 'sts_fleet'
    $needLink = $true
    if (Test-Path $link) {
        $item = Get-Item $link -Force
        if ($item.LinkType -in 'Junction', 'SymbolicLink') {
            $target = "$(@($item.Target)[0])".TrimEnd('\')
            if ($target -ieq $FleetDir.TrimEnd('\')) {
                Ok 'Junction already points at the fleet folder'
                $needLink = $false
            } else {
                Info "Junction pointed at $target, repointing"
                cmd /c "rmdir `"$link`"" | Out-Null   # removes the link only, not its target
            }
        } else {
            $backup = "$link.old-$($Start.ToString('yyyyMMdd-HHmmss'))"
            Copy-Item (Join-Path $link '*') $FleetDir -Recurse -Force -ErrorAction SilentlyContinue
            Rename-Item $link $backup
            Info "Existing sts_fleet folder copied into Dropbox and renamed to $(Split-Path $backup -Leaf)"
        }
    }
    if ($needLink) {
        $linkType = 'Junction'
        if ($env:OS -ne 'Windows_NT') { $linkType = 'SymbolicLink' }   # only for testing off Windows
        New-Item -ItemType $linkType -Path $link -Target $FleetDir | Out-Null
        Ok "Created junction $link -> $FleetDir"
    }
    # Prove it works end to end
    $probe = "probe_$Machine.tmp"
    try {
        Set-Content -Path (Join-Path $link "setup\$probe") -Value 'ok'
        if (Test-Path (Join-Path $FleetDir "setup\$probe")) { Ok 'Write through junction lands in Dropbox' }
        else { Bad 'Wrote through the junction but the file did not appear in Dropbox. Use tools\relay.py instead.' }
        Remove-Item (Join-Path $FleetDir "setup\$probe") -ErrorAction SilentlyContinue
    } catch { Bad "Junction write test failed: $($_.Exception.Message). Use tools\relay.py instead." }

    [IO.File]::WriteAllText((Join-Path $common 'sts_fleet_machine.txt'), $Machine, [Text.Encoding]::ASCII)
    Ok "Machine name file written (EA will report as $Machine)"

    Head 'MT5: install and compile STS_Heartbeat in every terminal'
    $rows = @()
    foreach ($t in $terminals) {
        $acct = Get-LastAccount $t.DataDir
        $label = Split-Path $t.DataDir -Leaf
        if ($t.InstallDir) { $label = "$(Split-Path $t.InstallDir -Leaf) [$($label.Substring(0, [Math]::Min(8, $label.Length)))]" }
        if ($t.Platform -eq 'MT4') {
            $src = Join-Path $Here 'mql5\STS_Heartbeat.mq4'; $mqlDir = 'MQL4'; $ext = '.mq4'; $exe5 = '.ex4'; $meName = 'metaeditor.exe'
        } else {
            $src = Join-Path $Here 'mql5\STS_Heartbeat.mq5'; $mqlDir = 'MQL5'; $ext = '.mq5'; $exe5 = '.ex5'; $meName = 'metaeditor64.exe'
        }
        $label = "$label $($t.Platform)"
        $dstDir = Join-Path $t.DataDir "$mqlDir\Experts\STS_Fleet"
        $dst = Join-Path $dstDir "STS_Heartbeat$ext"
        try {
            New-Item -ItemType Directory -Force -Path $dstDir -ErrorAction Stop | Out-Null
            Copy-Item $src $dst -Force -ErrorAction Stop
            (Get-Item $dst).LastWriteTime = Get-Date   # so MetaEditor sees it as changed
        } catch {
            Warn "Skipped $label ($($t.DataDir)): no write access. Run setup.bat as administrator if you use this terminal."
            $rows += [pscustomobject]@{
                Terminal = $label
                Login    = $(if ($acct) { $acct.Login } else { '?' })
                Server   = $(if ($acct) { $acct.Server } else { '?' })
                Broker   = $(if ($acct) { Guess-Firm $acct.Server } else { '?' })
                EA       = 'skipped (no access)'
            }
            continue
        }

        $compiled = 'not compiled'
        $me = $null
        if ($t.InstallDir) { $me = Join-Path $t.InstallDir $meName }
        if ($me -and (Test-Path $me)) {
            $clog = Join-Path $env:TEMP ("sts_hb_{0}.log" -f [guid]::NewGuid().ToString('N'))
            $meArgs = @("/compile:`"$dst`"", "/log:`"$clog`"")
            if ($t.Portable) { $meArgs += '/portable' }
            try {
                $sp = @{ FilePath = $me; ArgumentList = $meArgs; Wait = $true }
                if ($env:OS -eq 'Windows_NT') { $sp.WindowStyle = 'Hidden' }
                Start-Process @sp
                $ex5 = [IO.Path]::ChangeExtension($dst, $exe5)
                $txt = ''
                if (Test-Path $clog) { $txt = Get-Content $clog -Raw -ErrorAction SilentlyContinue }
                if ((Test-Path $ex5) -and (Get-Item $ex5).LastWriteTime -ge $Start.AddSeconds(-2)) {
                    $compiled = 'compiled'
                } else {
                    $compiled = 'COMPILE FAILED'
                    $errLines = ($txt -split "`r?`n" | Where-Object { $_ -match 'error' } | Select-Object -First 5) -join ' | '
                    Bad "Compile failed in $label. $errLines"
                }
            } catch { $compiled = 'COMPILE FAILED'; Bad "MetaEditor would not run for ${label}: $($_.Exception.Message)" }
        } else {
            $compiled = 'copied, compile in MetaEditor'
            Warn "$meName not found for $label. Open MetaEditor there and press F7 on STS_Fleet\STS_Heartbeat."
        }
        $rows += [pscustomobject]@{
            Terminal = $label
            Login    = $(if ($acct) { $acct.Login } else { '?' })
            Server   = $(if ($acct) { $acct.Server } else { '?' })
            Broker   = $(if ($acct) { Guess-Firm $acct.Server } else { '?' })
            EA       = $compiled
        }
    }
    if ($rows.Count) {
        $table = ($rows | Format-Table -AutoSize | Out-String).TrimEnd()
        Say $table 'White'
    }
    # Every account starts as a test account. Pre-write the tag commands for the ones
    # that look like prop firms so tagging is copy, paste, add the balance.
    $tagFile = Join-Path $FleetDir "setup\${Machine}_tag_commands.txt"
    $tagLines = @(
        "REM Accounts on $Machine. All are TEST accounts until tagged.",
        "REM For each challenge/funded account: replace BALANCE with its starting balance and run the line.",
        "REM Change 'challenge' to 'funded' where needed. Leave demo and EA-test accounts alone.",
        "cd /d `"$Here\tools`""
    )
    foreach ($r in $rows | Where-Object { $_.Login -ne '?' }) {
        $firmArg = $r.Broker
        if ($firmArg -eq '?') { $firmArg = 'FIRM' }
        $prefix = ''
        if ($r.Broker -eq '?' -or $r.Broker -eq 'LiteFinance') { $prefix = 'REM ' }   # likely a plain broker/demo account
        $tagLines += "REM $($r.Login) on $($r.Server) ($($r.Terminal))"
        $tagLines += "${prefix}python tag_account.py $($r.Login) challenge $firmArg BALANCE"
    }
    $tagLines | Set-Content -Path $tagFile -Encoding ASCII
    Info "All accounts start as test accounts (measured, no prop rules)."
    Info "Pre-filled tag commands for prop accounts: fleet\setup\${Machine}_tag_commands.txt"
}

# --------------------------------------------------------------------------
if ($doServer) {
    # Windows PowerShell 5.1 turns any stderr text from a native program (claude, pip, python)
    # into a fatal error under 'Stop'. Those tools print harmless notes there, so relax it here
    # and check results explicitly instead.
    $ErrorActionPreference = 'Continue'
    Head 'Server: Python and MCP SDK'
    $py = Find-Python
    if (-not $py) {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            Info 'No Python 3.10+ here (older versions are left alone). Installing Python 3.12 for this user with winget, about a minute...'
            & winget install -e --id Python.Python.3.12 --scope user --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
            $py = Find-Python
        }
    }
    if (-not $py) {
        # No winget (common on Windows Server): download the official installer from python.org
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $ProgressPreference = 'SilentlyContinue'
            $pyExe = Join-Path $env:TEMP 'python-3.12.8-amd64.exe'
            Info 'Downloading Python 3.12 from python.org...'
            Invoke-WebRequest 'https://www.python.org/ftp/python/3.12.8/python-3.12.8-amd64.exe' -OutFile $pyExe -UseBasicParsing
            Info 'Installing Python 3.12 for this user (a minute or two)...'
            Start-Process $pyExe -ArgumentList '/quiet InstallAllUsers=0 PrependPath=1 Include_test=0' -Wait
            $py = Find-Python
        } catch { Warn "Python download/install failed: $($_.Exception.Message)" }
    }
    if (-not $py) {
        Bad 'Python 3.10+ not found and winget could not install it. Install Python 3.12 from python.org, then run setup.bat again.'
    } else {
        Ok "Python $(Get-PyVersion $py) at $py"
        & $py -m pip install --upgrade --quiet --disable-pip-version-check -r (Join-Path $Here 'requirements.txt') 2>&1 | Out-Null
        $mcpVer = (& $py -c "import importlib.metadata as m; print(m.version('mcp'))" 2>$null)
        if ($mcpVer) { Ok "MCP SDK $mcpVer installed" } else { Bad 'pip could not install the mcp package'; $py = $null }
    }

    $server = Join-Path $Here 'server.py'

    if ($py) {
        Head 'Server: register with Claude Code'
        if ($claude) {
            & $claude mcp remove sts-fleet -s user 2>&1 | Out-Null
            $addArgs = @('mcp', 'add', 'sts-fleet', '-s', 'user', '-e', "STS_FLEET_DIR=$FleetDir", '--', $py, $server)
            $out = & $claude @addArgs 2>&1 | Out-String
            $listed = & $claude mcp list 2>&1 | Out-String
            if ($listed -notmatch 'sts-fleet') {
                # Windows PowerShell 5.1 can drop the "--" separator; retry through cmd
                $line = "`"$claude`" mcp add sts-fleet -s user -e `"STS_FLEET_DIR=$FleetDir`" -- `"$py`" `"$server`""
                $out = cmd /c "`"$line`"" 2>&1 | Out-String
                $listed = & $claude mcp list 2>&1 | Out-String
            }
            if ($listed -match 'sts-fleet') { Ok 'sts-fleet registered with Claude Code (user scope, all projects)' }
            else { Bad "Claude Code registration did not stick. Output: $($out.Trim())" }
        } else {
            Warn 'Claude Code CLI not found on this machine, skipped'
        }

        Head 'Server: register with Claude Desktop'
        if (Test-Path $desktopCfgDir) {
            $cfg = Join-Path $desktopCfgDir 'claude_desktop_config.json'
            try {
                if ((Test-Path $cfg) -and (Get-Item $cfg).Length -gt 0) {
                    Copy-Item $cfg "$cfg.bak-$($Start.ToString('yyyyMMdd-HHmmss'))" -ErrorAction Stop
                    $j = Get-Content $cfg -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    if ($null -eq $j) { throw 'config file parsed as empty' }
                } else {
                    $j = [pscustomobject]@{}
                }
                if (-not $j.PSObject.Properties['mcpServers']) { $j | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{}) }
                $entry = [pscustomobject]@{
                    command = $py
                    args    = @($server)
                    env     = [pscustomobject]@{ STS_FLEET_DIR = $FleetDir }
                }
                if ($j.mcpServers.PSObject.Properties['sts-fleet']) { $j.mcpServers.'sts-fleet' = $entry }
                else { $j.mcpServers | Add-Member -NotePropertyName 'sts-fleet' -NotePropertyValue $entry }
                $json = $j | ConvertTo-Json -Depth 20
                if (-not $json) { throw 'refusing to write an empty config' }
                [IO.File]::WriteAllText($cfg, $json, (New-Object Text.UTF8Encoding($false)))
                Ok 'Added to Claude Desktop config (restart Claude Desktop to load it)'
            } catch {
                Bad "Could not update Claude Desktop config: $($_.Exception.Message). A backup was kept next to it."
            }
        } else {
            Info 'Claude Desktop not installed here, skipped'
        }

        if (-not $NoTest) {
            Head 'Server: self-test against a sample fleet'
            $sample = Join-Path $env:TEMP 'sts-fleet-selftest'
            if (Test-Path $sample) { Remove-Item $sample -Recurse -Force -ErrorAction SilentlyContinue }
            & $py (Join-Path $Here 'tests\make_sample_fleet.py') $sample | Out-Null
            $saved = $env:STS_FLEET_DIR
            $env:STS_FLEET_DIR = $sample
            $testOut = & $py (Join-Path $Here 'tests\smoke_test.py') 2>&1 | Out-String
            $env:STS_FLEET_DIR = $saved
            if ($testOut -match 'ALL CHECKS PASSED') { Ok 'Every tool answered correctly over MCP' }
            else {
                $tail = ($testOut -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 6) -join "`n"
                Bad "Self-test failed:`n$tail"
            }
            Remove-Item $sample -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --------------------------------------------------------------------------
Head 'Done'
$logFile = Join-Path $FleetDir "setup\$Machine.txt"
if ($Problems -eq 0) {
    Say 'Everything checked out.' 'Green'
} else {
    Say "$Problems problem(s) above need attention." 'Red'
}
if ($doMt5 -and $terminals.Count) {
    Say ''
    Say 'One thing left per terminal: drag Experts > STS_Fleet > STS_Heartbeat onto any chart and click OK.' 'White'
    Say 'No inputs needed. Then tag only your challenge/funded accounts, e.g.:' 'White'
    Say "  python `"$Here\tools\tag_account.py`" 1520011234 challenge FTMO 100000" 'White'
    Say "Pre-filled lines for this machine are in fleet\setup\${Machine}_tag_commands.txt" 'White'
}
if ($doServer -and $claude) {
    Say ''
    Say 'Try it: open Claude Code and ask "check the sts-fleet status".' 'White'
}
$LogLines | Set-Content -Path $logFile -Encoding UTF8
Say "Log saved to $logFile" 'DarkGray'
