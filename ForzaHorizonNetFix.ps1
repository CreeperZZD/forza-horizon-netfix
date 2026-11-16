# ======================================================================
# Forza Horizon 4/5/6 线上联机 一键修复 / 一键还原 脚本 / Online Fix
# ----------------------------------------------------------------------
# 功能：Fix    - 备份当前网络设置后，一键完成 Xbox Live + Teredo 修复
#       Restore- 按备份文件还原到修复前的状态（例如要用 Multisim 时）
#       Status - 只读，查看当前 Teredo 联机参数
#       （不传参数则显示交互菜单）
#
# 用法：以管理员身份运行（脚本会自动请求提权）
#       .\ForzaHorizonNetFix.ps1 -Action Fix
#       .\ForzaHorizonNetFix.ps1 -Action Restore
#       .\ForzaHorizonNetFix.ps1 -Action Status
#
# 思路来源：小黑盒《【地平线4/5】由于网络问题无法连接线上的解决办法》
#          作者 金木  https://www.xiaoheihe.cn
# 许可：MIT License
# ======================================================================
param([string]$Action = "")

# ---------- 自动提权（Status 为只读操作，无需管理员） ----------
if ($Action -ne "Status") {
    $currentUser = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "需要管理员权限，正在重新启动（请在 UAC 弹窗点“是”）..." -ForegroundColor Yellow
        $launchArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        if ($Action -ne "") { $launchArgs += " -Action $Action" }
        Start-Process powershell.exe $launchArgs -Verb RunAs
        exit
    }
}

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackupFile  = Join-Path $ScriptDir "ForzaNetBackup.json"

# netsh 可能不在 PATH 中，取完整路径兜底
$Netsh = (Get-Command netsh.exe -ErrorAction SilentlyContinue).Source
if (-not $Netsh) { $Netsh = Join-Path $env:SystemRoot "System32\netsh.exe" }

# 文章中涉及的 Xbox/系统服务（服务名 => 修复时的启动类型）
$GameServices = [ordered]@{
    "iphlpsvc"      = "Manual"     # IP Helper
    "IKEEXT"        = "Automatic"  # IKE and AuthIP IPsec Keying Modules
    "lmhosts"       = "Automatic"  # TCP/IP NetBIOS Helper
    "XboxGipSvc"    = "Automatic"  # Xbox Accessory Management Service
    "XblAuthManager"= "Automatic"  # Xbox Live 身份验证管理器
    "XboxNetApiSvc" = "Automatic"  # Xbox Live 网络服务
    "XblGameSave"   = "Manual"     # Xbox Live 游戏保存
}

# Teredo 服务器候选列表
# 前面几个来自原作者教程，但公共服务器会陆续失效，脚本会先做域名解析校验。
# 2026-11 实测：remlab / consulintel / ngix / managemydedi / teredo.ipv6.microsoft.com 已失效，
# 仍可用的是 teredo.trex.fi 和 win1710.ipv6.microsoft.com。
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
# 工具函数
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

# 读取注册表值（不存在返回 $null）
function Get-RegDwordOrNull($path, $name) {
    $item = Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    return $item.$name
}

# 带超时的服务启动：超时不再死等，返回状态字符串
# Running=已运行；Timeout=启动超时（触发启动服务无设备时属正常）；Error=启动失败
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

# 读取 netsh teredo show state 的全文
function Get-TeredoStateText {
    return (& $Netsh interface teredo show state 2>&1 | Out-String)
}

# 从输出中解析 State 字段
function Get-TeredoStateValue($text) {
    $m = [regex]::Match($text, "State\s*:\s*([^\r\n]+)")
    if ($m.Success) { return $m.Groups[1].Value.Trim() } else { return "" }
}

# 选服务器：先验域名解析，再按延迟排序，返回候选数组
function Find-BestTeredoServer {
    Write-Title "检测 Teredo 服务器（先校验域名，再测延迟）"
    $results = @()
    foreach ($srv in $TeredoServers) {
        $ip = Resolve-TeredoServerIp $srv
        if (-not $ip) {
            Write-Host ("  [失效] {0,-34} 域名已解析不到，跳过" -f $srv) -ForegroundColor DarkGray
            continue
        }
        try {
            $ping = Test-Connection -ComputerName $ip -Count 3 -ErrorAction Stop
            $avg  = [math]::Round(($ping | Measure-Object -Property ResponseTime -Average).Average)
            Write-Host ("  [可用] {0,-34} {1,-15} 平均 {2} ms" -f $srv, $ip, $avg) -ForegroundColor Green
            $results += [pscustomobject]@{ Server = $srv; AvgMs = $avg }
        } catch {
            Write-Host ("  [可用] {0,-34} {1,-15} 不回 ICMP，仍列为候选" -f $srv, $ip) -ForegroundColor Yellow
            $results += [pscustomobject]@{ Server = $srv; AvgMs = 9999 }
        }
    }
    if ($results.Count -eq 0) {
        Write-Host "  候选域名全部失效，回退到内置服务器 teredo.trex.fi" -ForegroundColor Yellow
        return @("teredo.trex.fi")
    }
    return ($results | Sort-Object AvgMs | ForEach-Object { $_.Server })
}

# 逐个尝试候选服务器，直到 Teredo 进入可用状态；成功返回服务器名，全失败返回 $null
function Set-TeredoServerVerified($candidates) {
    $finalServer = $null
    $lastState   = ""
    foreach ($cand in $candidates) {
        Write-Host ""
        Write-Host "  正在尝试服务器：$cand" -ForegroundColor Cyan
        & $Netsh interface teredo set state "server=$cand" | Out-Null
        & $Netsh interface teredo set state enterpriseclient | Out-Null
        for ($i = 1; $i -le 5; $i++) {
            Start-Sleep -Seconds 5
            $lastState = Get-TeredoStateValue (Get-TeredoStateText)
            Write-Host ("    第 {0} 次检测：State = {1}" -f $i, $lastState) -ForegroundColor DarkGray
            if ($lastState -in @("qualified", "dormant")) {
                $finalServer = $cand
                break
            }
        }
        if ($finalServer) { break }
        Write-Host "    该服务器未使 Teredo 可用，换下一个" -ForegroundColor Yellow
    }
    if ($finalServer) {
        Write-Host "  => 生效服务器：$finalServer（State = $lastState）" -ForegroundColor Green
    } else {
        Write-Host "  => 所有候选都未生效。可能是重启前状态未刷新，或运营商 NAT 限制。" -ForegroundColor Red
        Write-Host "     请重启后运行 Run-Status.bat 复查。" -ForegroundColor Red
    }
    return $finalServer
}

# ======================================================================
# 备份
# ======================================================================
function Invoke-Backup {
    Write-Title "备份当前网络设置"

    # 1. 网卡 IPv6 绑定状态
    $adapterBackup = @()
    foreach ($b in (Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue)) {
        $adapterBackup += [pscustomobject]@{
            Name      = $b.Name
            InterfaceDescription = $b.InterfaceDescription
            Enabled   = $b.Enabled
        }
    }

    # 2. 游戏相关服务 + NI 服务的原始启动类型/状态
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

    # 3. 注册表值备份
    $regBackup = @()
    $regTargets = @(
        @{ Path = $RegDnsCache; Name = "AddrConfigControl" },
        @{ Path = $RegDnsCache; Name = "DisabledComponents" },
        @{ Path = $RegTcpip6;   Name = "DisabledComponents" }
    )
    foreach ($t in $regTargets) {
        $regBackup += [pscustomobject]@{
            Path   = $t.Path
            Name   = $t.Name
            Exists = ($null -ne (Get-RegDwordOrNull $t.Path $t.Name))
            Value  = Get-RegDwordOrNull $t.Path $t.Name
        }
    }

    # 4. 组策略等效注册表项备份
    $policyBackup = @()
    if (Test-Path $RegPolicy) {
        $props = Get-ItemProperty -Path $RegPolicy
        foreach ($p in $props.PSObject.Properties) {
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
    Write-Host "备份完成：$BackupFile" -ForegroundColor Green
}

# ======================================================================
# 应用修复
# ======================================================================
function Invoke-Fix {
    if (Test-Path $BackupFile) {
        Write-Host "检测到首次备份已存在，保留原备份不覆盖（确保能还原到最初状态）。" -ForegroundColor DarkGreen
    } else {
        Invoke-Backup
    }

    # ---------- 1. 关闭所有网卡的 IPv6 协议绑定 ----------
    Write-Title "1/5 关闭网卡 IPv6（TCP/IPv6）绑定"
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" }
    foreach ($a in $adapters) {
        try {
            Disable-NetAdapterBinding -Name $a.Name -ComponentID ms_tcpip6 -ErrorAction Stop
            Write-Host "  已关闭 [$($a.Name)] 的 IPv6" -ForegroundColor Green
        } catch {
            Write-Host "  [$($a.Name)] 操作失败：$($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # ---------- 2. 禁用 NI 相关网络服务 ----------
    Write-Title "2/5 禁用 NI 相关网络服务"
    $niSvcs = Get-NIServices
    if ($null -eq $niSvcs) {
        Write-Host "  未发现 NI 服务（没装 NI 软件可跳过）" -ForegroundColor DarkGray
    } else {
        foreach ($svc in $niSvcs) {
            try {
                Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
                Set-Service  -Name $svc.Name -StartupType Disabled
                Write-Host "  已禁用服务：$($svc.DisplayName)" -ForegroundColor Green
            } catch {
                Write-Host "  禁用失败：$($svc.DisplayName) - $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    # ---------- 3. 设置并启动 Xbox/系统服务 ----------
    Write-Title "3/5 配置并启动 Xbox 相关服务"
    # 触发启动、无外设时不保持运行的服务（启动超时不算失败）
    $triggerServices = @("XboxGipSvc")
    foreach ($sName in $GameServices.Keys) {
        $svc = Get-Service -Name $sName -ErrorAction SilentlyContinue
        if ($null -eq $svc) {
            Write-Host "  系统中不存在服务：$sName（家庭版/精简版可能缺失）" -ForegroundColor DarkGray
            continue
        }
        try {
            Set-Service -Name $sName -StartupType $GameServices[$sName] -ErrorAction Stop
        } catch {
            Write-Host "  $sName 启动类型设置失败：$($_.Exception.Message)" -ForegroundColor Red
            continue
        }
        $startResult = Start-ServiceSafe $sName
        switch ($startResult) {
            "Running" {
                Write-Host ("  {0,-18} => {1}，正在运行" -f $sName, $GameServices[$sName]) -ForegroundColor Green
            }
            "Timeout" {
                if ($triggerServices -contains $sName) {
                    Write-Host ("  {0,-18} => {1}，触发启动服务将在需要时自动运行" -f $sName, $GameServices[$sName]) -ForegroundColor Yellow
                } else {
                    Write-Host "  $sName 启动超时，已继续（不影响后续步骤）" -ForegroundColor Yellow
                }
            }
            "Error" {
                if ($triggerServices -contains $sName) {
                    Write-Host ("  {0,-18} => {1}，当前无 Xbox 外设，属正常现象" -f $sName, $GameServices[$sName]) -ForegroundColor Yellow
                } else {
                    Write-Host "  $sName 启动失败，已继续" -ForegroundColor Red
                }
            }
        }
    }

    # ---------- 4. Teredo 注册表 + 组策略等效设置 ----------
    Write-Title "4/5 写入 Teredo 注册表与组策略等效项（家庭版无需 gpedit）"
    $candidates = Find-BestTeredoServer
    $bestServer = $candidates[0]

    Set-RegDwordSafe $RegDnsCache "AddrConfigControl" 0
    Set-RegDwordSafe $RegDnsCache "DisabledComponents" 0
    Set-RegDwordSafe $RegTcpip6   "DisabledComponents" 0
    Write-Host "  Dnscache/Tcpip6 注册表项已写入（值均为 0）" -ForegroundColor Green

    if (-not (Test-Path $RegPolicy)) { New-Item -Path $RegPolicy -Force | Out-Null }
    # 6to4 / ISATAP => 已禁用(2)；Teredo 默认限定 => 已启用(1)；Teredo 状态 => 企业客户端(3)
    Set-RegDwordSafe $RegPolicy "6to4_State"             2
    Set-RegDwordSafe $RegPolicy "ISATAP_State"           2
    Set-RegDwordSafe $RegPolicy "Teredo_DefaultQualified" 1
    Set-RegDwordSafe $RegPolicy "Teredo_State"           3
    Set-ItemProperty -Path $RegPolicy -Name "Teredo_ServerName" -Value $bestServer
    Write-Host "  6to4=禁用, ISATAP=禁用, Teredo=企业客户端, 服务器=$bestServer" -ForegroundColor Green

    # ---------- 5. netsh 设置并验证 ----------
    Write-Title "5/5 设置 Teredo 服务器并验证状态（自动重试，约需 10~30 秒）"
    $activeServer = Set-TeredoServerVerified $candidates
    if ($activeServer) {
        # 把最终生效的服务器写进策略，保证重启后仍用它
        Set-ItemProperty -Path $RegPolicy -Name "Teredo_ServerName" -Value $activeServer
    }

    Write-Title "修复全部完成"
    Write-Host "请重启电脑，重启后联网，再双击 Run-Status.bat 复查 Teredo 状态。" -ForegroundColor Yellow
    Write-Host "正常状态：类型 enterpriseclient，状态 qualified 或 dormant。" -ForegroundColor Yellow
}

# ======================================================================
# 还原
# ======================================================================
function Invoke-Restore {
    Write-Title "开始还原"
    if (-not (Test-Path $BackupFile)) {
        Write-Host "找不到备份文件 $BackupFile，无法还原。" -ForegroundColor Red
        return
    }
    $backup = Get-Content $BackupFile -Raw -Encoding utf8 | ConvertFrom-Json

    # 1. 网卡 IPv6 绑定
    Write-Host "还原网卡 IPv6 绑定..." -ForegroundColor Cyan
    foreach ($a in $backup.AdapterBindings) {
        if ($a.Enabled) {
            Enable-NetAdapterBinding -Name $a.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
        } else {
            Disable-NetAdapterBinding -Name $a.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
        }
        Write-Host "  [$($a.Name)] IPv6 = $($a.Enabled)"
    }

    # 2. 服务启动类型与状态
    Write-Host "还原服务配置..." -ForegroundColor Cyan
    foreach ($s in $backup.Services) {
        $modeMap = @{ "Auto" = "Automatic"; "Manual" = "Manual"; "Disabled" = "Disabled" }
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
            Write-Host "  $($s.Name) => $target"
        } catch {
            Write-Host "  $($s.Name) 还原失败：$($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # 3. 普通注册表项
    Write-Host "还原注册表项..." -ForegroundColor Cyan
    foreach ($r in $backup.Registry) {
        if ($r.Exists) {
            Set-RegDwordSafe $r.Path $r.Name $r.Value
            Write-Host "  恢复 $($r.Path) \ $($r.Name) = $($r.Value)"
        } else {
            Remove-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction SilentlyContinue
            Write-Host "  删除修复时新建的 $($r.Name)"
        }
    }

    # 4. 策略注册表项
    Write-Host "还原组策略等效注册表..." -ForegroundColor Cyan
    $createdNames = @("6to4_State","ISATAP_State","Teredo_DefaultQualified","Teredo_State","Teredo_ServerName")
    foreach ($cn in $createdNames) {
        $old = $backup.PolicyValues | Where-Object { $_.Name -eq $cn }
        if ($null -ne $old) {
            Set-ItemProperty -Path $RegPolicy -Name $cn -Value $old.Value
            Write-Host "  恢复策略值 $cn = $($old.Value)"
        } else {
            Remove-ItemProperty -Path $RegPolicy -Name $cn -ErrorAction SilentlyContinue
            Write-Host "  删除策略值 $cn"
        }
    }

    # 5. Teredo 恢复默认
    & $Netsh interface teredo set state default | Out-Null
    Write-Host "Teredo 已恢复系统默认。" -ForegroundColor Green

    Write-Host ""
    Write-Host "还原完成，建议重启电脑。" -ForegroundColor Yellow
}

# ======================================================================
# 查看 Teredo 状态
# ======================================================================
function Show-TeredoState {
    Write-Title "当前 Teredo 状态"
    $txt = Get-TeredoStateText
    Write-Host $txt

    $state   = Get-TeredoStateValue $txt
    $type    = ([regex]::Match($txt, "Type\s*:\s*([^\r\n]+)")).Groups[1].Value.Trim()
    $nat     = ([regex]::Match($txt, "NAT\s*:\s*([^\r\n]+)")).Groups[1].Value.Trim()
    $svr     = ([regex]::Match($txt, "Server Name\s*:\s*([^\r\n]+)")).Groups[1].Value.Trim()
    $err     = ([regex]::Match($txt, "Error\s*:\s*([^\r\n]+)")).Groups[1].Value.Trim()

    Write-Host ""
    Write-Host "==== 判读 ====" -ForegroundColor Cyan
    if ($state -in @("qualified", "dormant")) {
        Write-Host "  状态：正常（$state），联机参数已就绪。" -ForegroundColor Green
        if ($type -like "enterpriseclient*") {
            Write-Host "  类型：enterpriseclient，符合预期。" -ForegroundColor Green
        } else {
            Write-Host "  类型：$type，建议重跑一次 Run-Fix.bat 设为企业客户端。" -ForegroundColor Yellow
        }
        if ($nat -like "symmetric*") {
            Write-Host "  NAT：$nat —— 对称型 NAT，能连但可能偶发掉线。" -ForegroundColor Yellow
            Write-Host "        若频繁掉线，需在路由器开 UPnP 或改用加速器。" -ForegroundColor Yellow
        } elseif ($nat) {
            Write-Host "  NAT：$nat，穿越条件较好。" -ForegroundColor Green
        }
    } elseif ($state -eq "offline") {
        Write-Host "  状态：offline，Teredo 未工作。" -ForegroundColor Red
        if ($err) { Write-Host "  原因：$err" -ForegroundColor Red }
        if ($err -like "*resolve*") {
            Write-Host "  当前服务器 $svr 的域名解析不到（公共服务器已失效）。" -ForegroundColor Yellow
            Write-Host "  处理：重跑 Run-Fix.bat，脚本会自动探测并换用仍存活的服务器。" -ForegroundColor Yellow
        } else {
            Write-Host "  处理：重跑 Run-Fix.bat，并确认 IP Helper 服务处于运行状态。" -ForegroundColor Yellow
        }
    } elseif ($state) {
        Write-Host "  状态：$state（探测中/未就绪）。稍等 30 秒后重新运行 Run-Status.bat。" -ForegroundColor Yellow
    } else {
        Write-Host "  未读到状态字段，请确认 Teredo 服务是否存在。" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  正常标准：Type = enterpriseclient，State = qualified 或 dormant。" -ForegroundColor DarkGray
}

# ======================================================================
# 主菜单
# ======================================================================
function Show-Menu {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  地平线 4/5/6 线上联网 一键修复工具" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  1. 应用修复（自动备份后执行文章全部设置）"
    Write-Host "  2. 一键还原（恢复修复前的设置）"
    Write-Host "  3. 查看当前 Teredo 状态"
    Write-Host "  4. 退出"
    if (Test-Path $BackupFile) {
        $b = Get-Content $BackupFile -Raw -Encoding utf8 | ConvertFrom-Json
        Write-Host ("  备份时间：{0}" -f $b.BackupTime) -ForegroundColor DarkGreen
    }
    Write-Host "============================================" -ForegroundColor Cyan
}

# 带参数直接执行（供独立 bat 调用），无参数则进入交互菜单
if ($Action -eq "Fix") {
    Invoke-Fix
} elseif ($Action -eq "Restore") {
    Invoke-Restore
} elseif ($Action -eq "Status") {
    Show-TeredoState
} else {
    while ($true) {
        Show-Menu
        $choice = Read-Host "请输入选项 (1-4)"
        switch ($choice) {
            "1" { Invoke-Fix }
            "2" { Invoke-Restore }
            "3" { Show-TeredoState }
            "4" { exit }
            default { Write-Host "无效选项，请重新输入。" -ForegroundColor Red }
        }
        if ($choice -in @("1","2")) {
            Write-Host ""
            Read-Host "按回车键返回菜单"
        }
    }
}
