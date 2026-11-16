# ======================================================================
# Forza Horizon 4/5/6 线上联机 一键修复 / 一键还原 / 状态查看
# Forza Horizon 4/5/6 Online Fix - Fix / Restore / Status
# ----------------------------------------------------------------------
# 功能 Actions:
#   Fix     - 备份网络设置后修复 Xbox Live + Teredo
#   Restore - 按备份还原（例如要用 Multisim / LabVIEW 时）
#   Status  - 只读，查看 Teredo 联机参数
#
# 参数 Parameters:
#   -Action Fix|Restore|Status   不传则进入交互菜单 / interactive menu
#   -Lang   Auto|zh|en           默认 Auto，跟随系统语言 / follows system UI language
#
# 用法 Usage:
#   .\ForzaHorizonNetFix.ps1 -Action Fix
#   .\ForzaHorizonNetFix.ps1 -Action Status -Lang en
#
# 思路来源 Credits:
#   小黑盒《【地平线4/5】由于网络问题无法连接线上的解决办法》 作者 @金木
# 许可 License: MIT
# ======================================================================
param(
    [ValidateSet("Fix", "Restore", "Status", "")]
    [string]$Action = "",
    [ValidateSet("Auto", "zh", "en")]
    [string]$Lang = "Auto"
)

# ---------- 语言 / Language ----------
if ($Lang -eq "Auto") {
    if ($PSUICulture -like "zh*") { $script:UILang = "zh" } else { $script:UILang = "en" }
} else {
    $script:UILang = $Lang
}

# 双语文案：T "中文" "English"
function T($zh, $en) {
    if ($script:UILang -eq "en") { return $en } else { return $zh }
}

# ---------- 自动提权（Status 只读，无需管理员）----------
if ($Action -ne "Status") {
    $currentUser = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host (T "需要管理员权限，正在重新启动（请在 UAC 弹窗点“是”）..." "Administrator rights required, relaunching (click Yes on the UAC prompt)...") -ForegroundColor Yellow
        $launchArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        if ($Action -ne "") { $launchArgs += " -Action $Action" }
        if ($Lang -ne "Auto") { $launchArgs += " -Lang $Lang" }
        Start-Process powershell.exe $launchArgs -Verb RunAs
        exit
    }
}

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackupFile = Join-Path $ScriptDir "ForzaNetBackup.json"

# netsh 可能不在 PATH 中，取完整路径兜底
$Netsh = (Get-Command netsh.exe -ErrorAction SilentlyContinue).Source
if (-not $Netsh) { $Netsh = Join-Path $env:SystemRoot "System32\netsh.exe" }

# 需要配置并启动的服务（服务名 => 修复后的启动类型）
$GameServices = [ordered]@{
    "iphlpsvc"       = "Manual"     # IP Helper
    "IKEEXT"         = "Automatic"  # IKE and AuthIP IPsec Keying Modules
    "lmhosts"        = "Automatic"  # TCP/IP NetBIOS Helper
    "XboxGipSvc"     = "Automatic"  # Xbox Accessory Management Service
    "XblAuthManager" = "Automatic"  # Xbox Live Auth Manager
    "XboxNetApiSvc"  = "Automatic"  # Xbox Live Networking Service
    "XblGameSave"    = "Manual"     # Xbox Live Game Save
}

# 触发启动、无外设时不保持运行的服务（启动超时属正常）
$TriggerServices = @("XboxGipSvc", "XblGameSave")

# Teredo 服务器候选（前面的更稳，脚本每次运行都会重新校验域名）
# 注意：这类公共服务器的域名解析很不稳定，同一批服务器在不同网络下时通时不通
$TeredoServers = @(
    "teredo.trex.fi",
    "win1710.ipv6.microsoft.com",
    "teredo.remlab.net",
    "teredo-debian.remlab.net",
    "teredo.autotrans.consulintel.com",
    "teredo.ipv6.microsoft.com",
    "teredo.ngix.ne.kr",
    "teredo.managemydedi.com"
)

# 注册表位置
$RegDnsCache = "HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters"
$RegTcpip6   = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters"
$RegPolicy   = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\TCPIP\v6Transition"

# ======================================================================
# 工具函数 / Helpers
# ======================================================================

function Write-Title($text) {
    Write-Host ""
    Write-Host "==== $text ====" -ForegroundColor Cyan
}

function Get-NIServices {
    Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like "NI*" -or $_.DisplayName -like "NI *" -or $_.DisplayName -like "NI*"
    }
}

function Set-RegDwordSafe($path, $name, $value) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    $existing = Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue
    if ($null -eq $existing) {
        New-ItemProperty -Path $path -Name $name -Value $value -PropertyType DWord | Out-Null
    } else {
        Set-ItemProperty -Path $path -Name $name -Value $value
    }
}

function Get-RegDwordOrNull($path, $name) {
    $item = Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    return $item.$name
}

# 带超时的服务启动：Running / Timeout / Error / Missing
function Start-ServiceSafe($name, $timeoutSec = 6) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return "Missing" }
    if ($svc.Status -eq "Running") { return "Running" }
    try {
        $svc.Start()
        $svc.WaitForStatus("Running", (New-Object TimeSpan(0, 0, $timeoutSec)))
        return "Running"
    } catch {
        $now = Get-Service -Name $name
        if ($now.Status -eq "Running") { return "Running" }
        if ($now.Status -eq "StartPending") { return "Timeout" }
        return "Error"
    }
}

# 按字节解码文本：优先严格 UTF-8，失败则按 GBK(936) 解码
# netsh 在中文系统输出 GBK，直接走管道会被当成 UTF-8 而乱码
function Convert-BytesToText($bytes) {
    try {
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        return $strictUtf8.GetString($bytes)
    } catch {
        return ([Text.Encoding]::GetEncoding(936)).GetString($bytes)
    }
}

# 取 netsh teredo show state 文本（文件重定向 + 显式解码，彻底避开控制台代码页问题）
function Get-TeredoStateText {
    $tmp = Join-Path $env:TEMP ("teredo_state_" + [guid]::NewGuid().ToString("N") + ".txt")
    try {
        Start-Process -FilePath $Netsh -ArgumentList @("interface", "teredo", "show", "state") `
            -NoNewWindow -Wait -RedirectStandardOutput $tmp -ErrorAction Stop | Out-Null
        for ($i = 0; $i -lt 20; $i++) {
            if ((Test-Path -LiteralPath $tmp) -and (Get-Item -LiteralPath $tmp).Length -gt 0) { break }
            Start-Sleep -Milliseconds 100
        }
        $bytes = [IO.File]::ReadAllBytes($tmp)
        return (Convert-BytesToText $bytes)
    } catch {
        try { return (& $Netsh interface teredo show state 2>&1 | Out-String) } catch { return "" }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# 解析 Teredo 状态（不依赖英文标签，中英文系统都能识别）
function Get-TeredoInfo($text) {
    $state = ""
    if     ($text -match "(?i)\boffline\b")   { $state = "offline" }
    elseif ($text -match "(?i)\bqualified\b") { $state = "qualified" }
    elseif ($text -match "(?i)\bdormant\b")   { $state = "dormant" }
    elseif ($text -match "(?i)\bprobe\b")     { $state = "probe" }
    elseif ($text -match "(?i)\bdisabled\b")  { $state = "disabled" }

    $nat = ""
    if     ($text -match "(?i)\bsymmetric\b")  { $nat = "symmetric" }
    elseif ($text -match "(?i)\bcone\b")       { $nat = "cone" }
    elseif ($text -match "(?i)\brestricted\b") { $nat = "restricted" }

    $errKind = ""
    if     ($text -match "(?i)failed to resolve")      { $errKind = "dns" }
    elseif ($text -match "(?i)\bno route\b")           { $errKind = "route" }
    elseif ($text -match "(?i)\bfailed\b")             { $errKind = "other" }

    return [pscustomobject]@{
        State      = $state
        Enterprise = ($text -match "(?i)enterpriseclient")
        Nat        = $nat
        ErrorKind  = $errKind
        Server     = $null
    }
}

# 解析服务器域名（失败返回 $null）
function Resolve-TeredoServerIp($name) {
    try {
        $r = Resolve-DnsName -Name $name -Type A -ErrorAction Stop
        $ip = ($r | Where-Object { $_.IPAddress } | Select-Object -First 1).IPAddress
        return $ip
    } catch {
        return $null
    }
}

# 选服务器：先验域名解析，再按延迟排序
function Find-BestTeredoServer {
    Write-Title (T "检测 Teredo 服务器（先校验域名，再测延迟）" "Checking Teredo servers (DNS first, then latency)")
    $results = @()
    foreach ($srv in $TeredoServers) {
        $ip = Resolve-TeredoServerIp $srv
        if (-not $ip) {
            Write-Host (T ("  [x] {0,-33} 域名已解析不到，跳过" -f $srv) ("  [x] {0,-33} DNS lookup failed, skipped" -f $srv)) -ForegroundColor DarkGray
            continue
        }
        try {
            $ping = Test-Connection -ComputerName $ip -Count 3 -ErrorAction Stop
            $avg  = [math]::Round(($ping | Measure-Object -Property ResponseTime -Average).Average)
            Write-Host (T ("  [ok] {0,-32} {1,-15} 平均 {2} ms" -f $srv, $ip, $avg) ("  [ok] {0,-32} {1,-15} avg {2} ms" -f $srv, $ip, $avg)) -ForegroundColor Green
            $results += [pscustomobject]@{ Server = $srv; AvgMs = $avg }
        } catch {
            Write-Host (T ("  [ok] {0,-32} {1,-15} 不回 ICMP，仍列为候选" -f $srv, $ip) ("  [ok] {0,-32} {1,-15} no ICMP reply, kept" -f $srv, $ip)) -ForegroundColor Yellow
            $results += [pscustomobject]@{ Server = $srv; AvgMs = 9999 }
        }
    }
    if ($results.Count -eq 0) {
        Write-Host (T "  候选域名全部失效，回退到 teredo.trex.fi" "  All candidates dead, falling back to teredo.trex.fi") -ForegroundColor Yellow
        return @("teredo.trex.fi")
    }
    return ($results | Sort-Object AvgMs | ForEach-Object { $_.Server })
}

# 逐个尝试候选服务器，直到 Teredo 进入可用状态
function Set-TeredoServerVerified($candidates) {
    $finalServer = $null
    $lastState   = ""
    foreach ($cand in $candidates) {
        Write-Host ""
        Write-Host (T "  正在尝试服务器：$cand" "  Trying server: $cand") -ForegroundColor Cyan
        & $Netsh interface teredo set state "server=$cand" | Out-Null
        & $Netsh interface teredo set state enterpriseclient | Out-Null
        for ($i = 1; $i -le 5; $i++) {
            Start-Sleep -Seconds 5
            $info = Get-TeredoInfo (Get-TeredoStateText)
            $lastState = $info.State
            Write-Host (T ("    第 {0} 次检测：State = {1}" -f $i, $lastState) ("    check {0}: State = {1}" -f $i, $lastState)) -ForegroundColor DarkGray
            if ($lastState -in @("qualified", "dormant")) { $finalServer = $cand; break }
        }
        if ($finalServer) { break }
        Write-Host (T "    该服务器未使 Teredo 可用，换下一个" "    Not working, trying the next one") -ForegroundColor Yellow
    }
    if ($finalServer) {
        Write-Host (T ("  => 生效服务器：{0}（State = {1}）" -f $finalServer, $lastState) ("  => Working server: {0} (State = {1})" -f $finalServer, $lastState)) -ForegroundColor Green
    } else {
        Write-Host (T "  => 所有候选都未生效。可能是重启前状态未刷新，或运营商 NAT 限制。" "  => No candidate worked. Try after a reboot, or your carrier NAT blocks Teredo.") -ForegroundColor Red
        Write-Host (T "     请重启后运行 Run-Status.bat 复查。" "     Reboot and run Run-Status.bat to verify.") -ForegroundColor Red
    }
    return $finalServer
}

# ======================================================================
# 备份 / Backup
# ======================================================================
function Invoke-Backup {
    Write-Title (T "备份当前网络设置" "Backing up current network settings")

    $adapterBackup = @()
    foreach ($b in (Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue)) {
        $adapterBackup += [pscustomobject]@{
            Name = $b.Name
            InterfaceDescription = $b.InterfaceDescription
            Enabled = $b.Enabled
        }
    }

    $serviceBackup = @()
    $allTarget = @($GameServices.Keys) + (Get-NIServices | Select-Object -ExpandProperty Name)
    foreach ($sName in ($allTarget | Select-Object -Unique)) {
        $svc = Get-Service -Name $sName -ErrorAction SilentlyContinue
        if ($null -ne $svc) {
            $wmi = Get-CimInstance -ClassName Win32_Service -Filter "Name='$sName'" -ErrorAction SilentlyContinue
            $serviceBackup += [pscustomobject]@{
                Name        = $svc.Name
                DisplayName = $svc.DisplayName
                StartMode   = $wmi.StartMode
                Status      = $svc.Status.ToString()
                IsNI        = ($svc.Name -like "NI*" -or $svc.DisplayName -like "NI*")
            }
        }
    }

    $regBackup = @()
    $regTargets = @(
        @{ Path = $RegDnsCache; Name = "AddrConfigControl" },
        @{ Path = $RegDnsCache; Name = "DisabledComponents" },
        @{ Path = $RegTcpip6;   Name = "DisabledComponents" }
    )
    foreach ($t in $regTargets) {
        $regBackup += [pscustomobject]@{
            Path = $t.Path
            Name = $t.Name
            Exists = ($null -ne (Get-RegDwordOrNull $t.Path $t.Name))
            Value = Get-RegDwordOrNull $t.Path $t.Name
        }
    }

    $policyBackup = @()
    if (Test-Path $RegPolicy) {
        foreach ($p in (Get-ItemProperty -Path $RegPolicy).PSObject.Properties) {
            if ($p.Name -notlike "PS*") {
                $policyBackup += [pscustomobject]@{ Name = $p.Name; Value = $p.Value }
            }
        }
    }

    $backup = [pscustomobject]@{
        BackupTime       = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        AdapterBindings  = $adapterBackup
        Services         = $serviceBackup
        Registry         = $regBackup
        PolicyValues     = $policyBackup
        PolicyKeyExisted = (Test-Path $RegPolicy)
    }
    $backup | ConvertTo-Json -Depth 10 | Out-File -FilePath $BackupFile -Encoding utf8
    Write-Host ("  " + (T "备份完成：" "Backup saved to: ") + $BackupFile) -ForegroundColor Green
}

# ======================================================================
# 修复 / Fix
# ======================================================================
function Invoke-Fix {
    if (Test-Path $BackupFile) {
        Write-Host (T "检测到首次备份已存在，保留原备份不覆盖（确保能还原到最初状态）。" "Existing backup found; keeping it so you can always roll back to the original state.") -ForegroundColor DarkGreen
    } else {
        Invoke-Backup
    }

    # 1. 关闭网卡 IPv6
    Write-Title (T "1/5 关闭网卡 IPv6（TCP/IPv6）绑定" "1/5 Disabling IPv6 binding on adapters")
    foreach ($a in (Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" })) {
        try {
            Disable-NetAdapterBinding -Name $a.Name -ComponentID ms_tcpip6 -ErrorAction Stop
            Write-Host (T ("  已关闭 [{0}] 的 IPv6" -f $a.Name) ("  Disabled IPv6 on [{0}]" -f $a.Name)) -ForegroundColor Green
        } catch {
            Write-Host ((T "  操作失败：" "  failed: ") + $a.Name + " - " + $_.Exception.Message) -ForegroundColor Red
        }
    }

    # 2. 禁用 NI 服务
    Write-Title (T "2/5 禁用 NI 相关网络服务" "2/5 Disabling NI network services")
    $niSvcs = Get-NIServices
    if ($null -eq $niSvcs) {
        Write-Host (T "  未发现 NI 服务（没装 NI 软件可跳过）" "  No NI services found (nothing to do)") -ForegroundColor DarkGray
    } else {
        foreach ($svc in $niSvcs) {
            try {
                Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
                Set-Service  -Name $svc.Name -StartupType Disabled
                Write-Host ("  " + (T "已禁用服务：" "Disabled: ") + $svc.DisplayName) -ForegroundColor Green
            } catch {
                Write-Host ("  " + (T "禁用失败：" "failed: ") + $svc.DisplayName + " - " + $_.Exception.Message) -ForegroundColor Red
            }
        }
    }

    # 3. 配置并启动 Xbox / 系统服务
    Write-Title (T "3/5 配置并启动 Xbox 相关服务" "3/5 Configuring and starting Xbox services")
    foreach ($sName in $GameServices.Keys) {
        $svc = Get-Service -Name $sName -ErrorAction SilentlyContinue
        if ($null -eq $svc) {
            Write-Host (T ("  系统中不存在服务：{0}（家庭版/精简版可能缺失）" -f $sName) ("  Service not present: {0} (missing on some editions)" -f $sName)) -ForegroundColor DarkGray
            continue
        }
        try {
            Set-Service -Name $sName -StartupType $GameServices[$sName] -ErrorAction Stop
        } catch {
            Write-Host ("  $sName " + (T "启动类型设置失败：" "startup type failed: ") + $_.Exception.Message) -ForegroundColor Red
            continue
        }
        switch (Start-ServiceSafe $sName) {
            "Running" {
                Write-Host (T ("  {0,-18} => {1}，正在运行" -f $sName, $GameServices[$sName]) ("  {0,-18} => {1}, running" -f $sName, $GameServices[$sName])) -ForegroundColor Green
            }
            "Timeout" {
                Write-Host (T ("  {0,-18} => {1}，触发启动，需要时自动运行" -f $sName, $GameServices[$sName]) ("  {0,-18} => {1}, trigger-start, runs on demand" -f $sName, $GameServices[$sName])) -ForegroundColor Yellow
            }
            "Error" {
                if ($TriggerServices -contains $sName) {
                    Write-Host (T ("  {0,-18} => {1}，当前无 Xbox 外设，属正常" -f $sName, $GameServices[$sName]) ("  {0,-18} => {1}, no Xbox device attached, expected" -f $sName, $GameServices[$sName])) -ForegroundColor Yellow
                } else {
                    Write-Host ((T "  启动失败，已继续：" "  start failed, continuing: ") + $sName) -ForegroundColor Red
                }
            }
        }
    }

    # 4. 注册表 + 组策略等效项
    Write-Title (T "4/5 写入 Teredo 注册表与组策略等效项（家庭版无需 gpedit）" "4/5 Writing Teredo registry / policy values (no gpedit needed)")
    $candidates = Find-BestTeredoServer
    $bestServer = $candidates[0]

    Set-RegDwordSafe $RegDnsCache "AddrConfigControl" 0
    Set-RegDwordSafe $RegDnsCache "DisabledComponents" 0
    Set-RegDwordSafe $RegTcpip6   "DisabledComponents" 0
    Write-Host (T "  Dnscache / Tcpip6 注册表项已写入（值均为 0）" "  Dnscache / Tcpip6 registry values written (all 0)") -ForegroundColor Green

    if (-not (Test-Path $RegPolicy)) { New-Item -Path $RegPolicy -Force | Out-Null }
    # 6to4 / ISATAP => 已禁用(2)；Teredo 默认限定 => 已启用(1)；Teredo 状态 => 企业客户端(3)
    Set-RegDwordSafe $RegPolicy "6to4_State" 2
    Set-RegDwordSafe $RegPolicy "ISATAP_State" 2
    Set-RegDwordSafe $RegPolicy "Teredo_DefaultQualified" 1
    Set-RegDwordSafe $RegPolicy "Teredo_State" 3
    Set-ItemProperty -Path $RegPolicy -Name "Teredo_ServerName" -Value $bestServer
    Write-Host (T ("  6to4=禁用, ISATAP=禁用, Teredo=企业客户端, 服务器={0}" -f $bestServer) ("  6to4=disabled, ISATAP=disabled, Teredo=enterpriseclient, server={0}" -f $bestServer)) -ForegroundColor Green

    # 5. 设置并验证
    Write-Title (T "5/5 设置 Teredo 服务器并验证状态（约需 10~30 秒）" "5/5 Applying Teredo server and verifying (~10-30s)")
    $activeServer = Set-TeredoServerVerified $candidates
    if ($activeServer) {
        Set-ItemProperty -Path $RegPolicy -Name "Teredo_ServerName" -Value $activeServer
    }

    Write-Title (T "修复全部完成" "All done")
    Write-Host (T "请重启电脑，重启后联网，再双击 Run-Status.bat 复查 Teredo 状态。" "Please reboot, then run Run-Status.bat to verify.") -ForegroundColor Yellow
    Write-Host (T "正常状态：类型 enterpriseclient，状态 qualified 或 dormant。" "Expected: Type enterpriseclient, State qualified or dormant.") -ForegroundColor Yellow
}

# ======================================================================
# 还原 / Restore
# ======================================================================
function Invoke-Restore {
    Write-Title (T "开始还原" "Restoring")
    if (-not (Test-Path $BackupFile)) {
        Write-Host ((T "找不到备份文件，无法还原：" "Backup file not found, cannot restore: ") + $BackupFile) -ForegroundColor Red
        return
    }
    $backup = Get-Content -LiteralPath $BackupFile -Raw -Encoding utf8 | ConvertFrom-Json

    # 1. 网卡 IPv6 绑定
    Write-Host (T "还原网卡 IPv6 绑定..." "Restoring adapter IPv6 bindings...") -ForegroundColor Cyan
    foreach ($a in $backup.AdapterBindings) {
        if ($a.Enabled) {
            Enable-NetAdapterBinding -Name $a.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
        } else {
            Disable-NetAdapterBinding -Name $a.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
        }
        Write-Host ("  [$($a.Name)] IPv6 = $($a.Enabled)")
    }

    # 2. Teredo 恢复默认（先做，避免覆盖后面的注册表还原）
    & $Netsh interface teredo set state default | Out-Null

    # 3. 服务启动类型与状态
    Write-Host (T "还原服务配置..." "Restoring service settings...") -ForegroundColor Cyan
    $modeMap = @{ "Auto" = "Automatic"; "Manual" = "Manual"; "Disabled" = "Disabled" }
    foreach ($s in $backup.Services) {
        $target = $modeMap[$s.StartMode]
        if (-not $target) { $target = "Manual" }
        try {
            Set-Service -Name $s.Name -StartupType $target -ErrorAction Stop
            if ($target -ne "Disabled" -and $s.Status -eq "Running") {
                Start-Service -Name $s.Name -ErrorAction SilentlyContinue
            }
            if ($target -eq "Disabled") {
                Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue
            }
            Write-Host ("  $($s.Name) => $target")
        } catch {
            Write-Host ("  $($s.Name) " + (T "还原失败：" "restore failed: ") + $_.Exception.Message) -ForegroundColor Red
        }
    }

    # 4. 注册表项
    Write-Host (T "还原注册表项..." "Restoring registry values...") -ForegroundColor Cyan
    foreach ($r in $backup.Registry) {
        if ($r.Exists) {
            Set-RegDwordSafe $r.Path $r.Name $r.Value
            Write-Host ("  " + (T "恢复 " "restore ") + "$($r.Path) \ $($r.Name) = $($r.Value)")
        } else {
            Remove-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction SilentlyContinue
            Write-Host ("  " + (T "删除修复时新建的 " "removed ") + $r.Name)
        }
    }

    # 5. 组策略等效注册表
    Write-Host (T "还原组策略等效注册表..." "Restoring policy values...") -ForegroundColor Cyan
    $createdNames = @("6to4_State", "ISATAP_State", "Teredo_DefaultQualified", "Teredo_State", "Teredo_ServerName")
    foreach ($cn in $createdNames) {
        $old = $backup.PolicyValues | Where-Object { $_.Name -eq $cn }
        if ($null -ne $old) {
            Set-ItemProperty -Path $RegPolicy -Name $cn -Value $old.Value
            Write-Host ("  " + (T "恢复策略值 " "restore ") + "$cn = $($old.Value)")
        } else {
            Remove-ItemProperty -Path $RegPolicy -Name $cn -ErrorAction SilentlyContinue
            Write-Host ("  " + (T "删除策略值 " "removed ") + $cn)
        }
    }

    Write-Host ""
    Write-Host (T "还原完成，建议重启电脑。" "Restore finished. A reboot is recommended.") -ForegroundColor Yellow
}

# ======================================================================
# 查看状态 / Status
# ======================================================================
function Show-TeredoState {
    Write-Title (T "当前 Teredo 状态" "Current Teredo state")
    $txt = Get-TeredoStateText
    if ($txt.Trim()) { Write-Host $txt.TrimEnd() } else { Write-Host (T "（netsh 无输出）" "(no output from netsh)") }

    $info = Get-TeredoInfo $txt
    $svr = $null
    try { $svr = (Get-ItemProperty -Path $RegPolicy -Name "Teredo_ServerName" -ErrorAction Stop).Teredo_ServerName } catch { }
    if (-not $svr -and ($txt -match "(?i)([a-z0-9][a-z0-9-]*\.[a-z0-9.-]+\.(?:net|com|fi|kr|org))")) {
        $svr = $Matches[1]
    }

    Write-Host ""
    Write-Host (T "==== 判读" "==== Verdict") -ForegroundColor Cyan
    if ($info.State -in @("qualified", "dormant")) {
        Write-Host (T "  状态：正常（$($info.State)），联机参数已就绪。" "  State: OK ($($info.State)), online parameters ready.") -ForegroundColor Green
        if ($info.Enterprise) {
            Write-Host (T "  类型：enterpriseclient，符合预期。" "  Type: enterpriseclient, as expected.") -ForegroundColor Green
        } else {
            Write-Host (T "  类型：未处于 enterpriseclient，建议重跑一次 Run-Fix.bat。" "  Type: not enterpriseclient, re-run Run-Fix.bat.") -ForegroundColor Yellow
        }
        if ($info.Nat -eq "symmetric") {
            Write-Host (T "  NAT：symmetric（对称型），能连但可能偶发掉线。" "  NAT: symmetric - works but may drop occasionally.") -ForegroundColor Yellow
            Write-Host (T "        频繁掉线需在路由器开 UPnP 或改用加速器。" "        For stability enable UPnP or use a gaming accelerator.") -ForegroundColor Yellow
        } elseif ($info.Nat) {
            Write-Host (T "  NAT：$($info.Nat)，穿越条件较好。" "  NAT: $($info.Nat), good for hole punching.") -ForegroundColor Green
        }
    } elseif ($info.State -eq "offline") {
        Write-Host (T "  状态：offline，Teredo 未工作。" "  State: offline - Teredo is not working.") -ForegroundColor Red
        if ($info.ErrorKind -eq "dns") {
            Write-Host (T "  原因：服务器域名解析失败（公共服务器可能已失效）。" "  Cause: server name lookup failed (the public server may be dead).") -ForegroundColor Yellow
            if ($svr) { Write-Host ((T "  当前服务器：" "  Current server: ") + $svr) -ForegroundColor Yellow }
            Write-Host (T "  处理：重跑 Run-Fix.bat，脚本会自动换成仍存活的服务器。" "  Fix: re-run Run-Fix.bat; it switches to a live server automatically.") -ForegroundColor Yellow
        } else {
            Write-Host (T "  处理：重跑 Run-Fix.bat，并确认 IP Helper 服务处于运行状态。" "  Fix: re-run Run-Fix.bat and confirm IP Helper is running.") -ForegroundColor Yellow
        }
    } elseif ($info.State) {
        Write-Host (T "  状态：$($info.State)（未就绪），稍等 30 秒再运行 Run-Status.bat。" "  State: $($info.State) - wait 30s and run Run-Status.bat again.") -ForegroundColor Yellow
    } else {
        Write-Host (T "  未读到状态字段，请确认 Teredo 功能正常。" "  No state field found; verify the Teredo feature exists.") -ForegroundColor Red
    }
    Write-Host ""
    Write-Host (T "  正常标准：Type = enterpriseclient，State = qualified 或 dormant。" "  Expected: Type = enterpriseclient, State = qualified or dormant.") -ForegroundColor DarkGray
}

# ======================================================================
# 交互菜单 / Interactive menu
# ======================================================================
function Show-Menu {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host (T "  Forza Horizon 4/5/6 联机修复工具" "  Forza Horizon 4/5/6 Online Fix Tool") -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host (T "  1. 应用修复（自动备份后执行全部设置）" "  1. Apply fix (with automatic backup)")
    Write-Host (T "  2. 一键还原（恢复修复前的设置）" "  2. Restore previous settings")
    Write-Host (T "  3. 查看当前 Teredo 状态" "  3. Show current Teredo state")
    Write-Host (T "  4. 退出" "  4. Exit")
    if (Test-Path $BackupFile) {
        $b = Get-Content -LiteralPath $BackupFile -Raw -Encoding utf8 | ConvertFrom-Json
        Write-Host ((T "  备份时间：" "  Backup time: ") + $b.BackupTime) -ForegroundColor DarkGreen
    }
    Write-Host "============================================" -ForegroundColor Cyan
}

# 带参数直接执行（供 bat 调用），无参数进入菜单
if ($Action -eq "Fix") {
    Invoke-Fix
} elseif ($Action -eq "Restore") {
    Invoke-Restore
} elseif ($Action -eq "Status") {
    Show-TeredoState
} else {
    while ($true) {
        Show-Menu
        $hint = T "请输入选项 (1-4)" "Select (1-4)"
        $choice = Read-Host $hint
        switch ($choice) {
            "1" { Invoke-Fix }
            "2" { Invoke-Restore }
            "3" { Show-TeredoState }
            "4" { exit }
            default { Write-Host (T "无效选项，请重新输入。" "Invalid option, try again.") -ForegroundColor Red }
        }
        if ($choice -in @("1", "2")) {
            Write-Host ""
            Read-Host (T "按回车键返回菜单" "Press Enter to return to menu")
        }
    }
}
