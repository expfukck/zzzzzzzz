<#
.SYNOPSIS
    一个全能的游戏客户端管理脚本。它能从 WebDAV 下载资源，准备系统文件，自动搜索、验证、整理
    Riot Games 客户端，创建桌面快捷方式，重置配置文件，并在最后打开指定网页。

.DESCRIPTION
    此脚本按顺序执行以下操作：
    1. [新增] 管理员权限检查: 确保脚本以管理员身份运行。
    2. [新增] 准备系统文件: 复制 rundll32.exe 为 Riot Client.exe 到 System32 目录。
    3. [可选] WebDAV 下载: 下载指定的文件夹和单个文件到桌面。
    4. 客户端搜索与验证: 搜索并找出版本最合适的、包含 "Game\stub.dll" 的客户端。
    5. 客户端文件整理: 根据配置执行 "Move" 或 "Copy"。
    6. 创建桌面快捷方式: 为整理好的客户端在桌面创建快捷方式。
    7. 清理和更新配置文件: 删除 machine.cfg 并动态修改或创建 product_settings.yaml。
    8. 打开网页: 所有操作完成后，在默认浏览器中打开指定网页。
    9. 报告总耗时。
    10. 结束并等待用户确认。

.NOTES
    作者: AI 助手
    日期: 2023-10-28
    版本: 6.0
#>

# --- [新增] 1. 管理员权限检查 ---
# 检查当前用户是否为管理员，如果不是，则提示并退出。
$currentUser = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "错误：此脚本需要管理员权限才能运行。"
    Write-Error "请右键点击脚本文件，选择 '以管理员身份运行'。"
    Read-Host "按 Enter 键退出..."
    exit
}

# --- [新增] 记录脚本开始时间 ---
$startTime = Get-Date

# --- 配置 ---
# (配置部分保持不变)
$enableWebDAVDownload = $true
$webdavUrl = "http://www1.movemama.cn/便捷/"
$enableWebDAVFileDownload = $true
$webdavFileUrl = "http://www1.movemama.cn/1.rar"
$fileOperationMode = "Move"
$searchDepth = 8
$riotClientExe = "RiotClientServices.exe"
$leagueClientExe = "LeagueClient.exe"
$ddragonApiUrl = "https://ddragon.leagueoflegends.com/api/versions.json"

# --- 用于存储结果的变量 ---
$riotClientFullPath = ""
$leagueClientFoundList = @()
$latestApiVersion = ""
$closestLeagueClient = $null
$isLeagueClientVersionValid = $false

# --- 定义要搜索的驱动器 ---
$searchDrives = Get-PSDrive -PSProvider FileSystem | Where-Object {$_.Root -like "*:\" -and $_.Provider.Name -eq "FileSystem" -and $_.Free -gt 0} | Select-Object -ExpandProperty Root

# --- 版本号处理和比较函数 ---
# (函数部分保持不变)
function Get-VersionParts { param([string]$VersionString, [int]$PartsCount = 3); $parts = $VersionString.Split('.', [System.StringSplitOptions]::RemoveEmptyEntries) | Select-Object -First $PartsCount; while ($parts.Count -lt $PartsCount) { $parts += "0" }; return $parts | ForEach-Object { [int]$_ } }
function Get-VersionDistance { param([string]$LocalVersionDisplay, [string]$ApiVersion); $localInts = Get-VersionParts -VersionString $LocalVersionDisplay; $apiInts = Get-VersionParts -VersionString $ApiVersion; $distance = ([math]::Abs($localInts[0] - $apiInts[0]) * 10000) + ([math]::Abs($localInts[1] - $apiInts[1]) * 100) + ([math]::Abs($localInts[2] - $apiInts[2]) * 1); return $distance }
function Is-VersionCompatible { param([string]$LocalVersionDisplay, [string]$ApiVersion); if (-not $ApiVersion) { return $false }; $localInts = Get-VersionParts -VersionString $LocalVersionDisplay; $apiInts = Get-VersionParts -VersionString $ApiVersion; if ($localInts[0] -eq $apiInts[0] -and $localInts[1] -eq $apiInts[1] -and $localInts[2] -ge ($apiInts[2] - 1) -and $localInts[2] -le ($apiInts[2] + 1)) { return $true }; if ($localInts[0] -eq $apiInts[0] -and $localInts[1] -ge ($apiInts[1] - 1) -and $localInts[1] -le ($apiInts[1] + 1)) { return $true }; if ($localInts[0] -ge ($apiInts[0] - 1) -and $localInts[0] -le ($apiInts[0] + 1)) { return $true }; return $false }

# --- 主流程 ---

# --- [新增] 2. 准备系统文件 ---
Write-Host "--- 开始准备系统文件 ---" -ForegroundColor Yellow
try {
    # 使用环境变量 $env:SystemRoot 获取 C:\Windows 目录
    $system32Path = Join-Path $env:SystemRoot "System32"
    $sourceFile = Join-Path $system32Path "rundll32.exe"
    $destFile = Join-Path $system32Path "Riot Client.exe"

    Write-Host "正在将 '$sourceFile' 复制为 '$destFile'..."
    
    if (Test-Path $sourceFile) {
        # 使用 -Force 参数确保如果目标文件已存在，则会覆盖它
        Copy-Item -Path $sourceFile -Destination $destFile -Force
        Write-Host "文件复制成功！" -ForegroundColor Green
    } else {
        Write-Warning "源文件 '$sourceFile' 不存在，跳过此步骤。"
    }
} catch {
    Write-Error "准备系统文件时发生错误: $($_.Exception.Message)"
}
Write-Host ""


# --- 3 & 4. WebDAV 统一操作 ---
if ($enableWebDAVDownload -or $enableWebDAVFileDownload) {
    Write-Host "--- 开始执行 WebDAV 下载任务 ---" -ForegroundColor Yellow
    $credential = Get-Credential -UserName "" -Message "请输入用于所有 WebDAV 操作的凭据"

    if ($credential) {
        # --- 文件夹下载 ---
        if ($enableWebDAVDownload) {
            Write-Host "正在准备下载文件夹..."
            $desktopPath = [System.Environment]::GetFolderPath('Desktop')
            $uri = [System.Uri]$webdavUrl
            $folderName = ($uri.Segments[-1]).TrimEnd('/')
            $folderName = [System.Net.WebUtility]::UrlDecode($folderName)
            if ([string]::IsNullOrWhiteSpace($folderName)) { $folderName = "WebDAV_Download_Root" }
            $localDownloadPath = Join-Path -Path $desktopPath -ChildPath $folderName
            
            try {
                if (-not (Test-Path $localDownloadPath)) { New-Item -Path $localDownloadPath -ItemType Directory | Out-Null }
                Write-Host "正在连接到 WebDAV 服务器并获取文件列表..."
                $webRequest = @{ Uri = $webdavUrl; Method = 'PROPFIND'; Headers = @{Depth = 'infinity'}; Credential = $credential }
                $response = Invoke-RestMethod @webRequest
                $remoteItems = $response.multistatus.response | ForEach-Object { $href = $_.href; $relativePath = $href.Substring($uri.AbsolutePath.Length); if (-not [string]::IsNullOrWhiteSpace($relativePath)) { [System.Net.WebUtility]::UrlDecode($relativePath) } } | Where-Object { $_ }
                $totalCount = $remoteItems.Count
                $copiedCount = 0
                if ($totalCount -gt 0) {
                    Write-Host "文件列表获取成功，共 $totalCount 个项目，开始下载..."
                    foreach ($item in $remoteItems) {
                        $copiedCount++; $percent = ($copiedCount / $totalCount) * 100; $sourceUrl = "$($webdavUrl.TrimEnd('/'))/$item"; $destinationPath = Join-Path -Path $localDownloadPath -ChildPath $item
                        Write-Progress -Activity "从 WebDAV 下载文件夹" -Status "处理中: $item" -PercentComplete $percent -CurrentOperation "$copiedCount / $totalCount"
                        if ($item.EndsWith('/')) { if (-not (Test-Path $destinationPath)) { New-Item -Path $destinationPath -ItemType Directory -Force | Out-Null } } else { $parentDir = Split-Path -Path $destinationPath -Parent; if (-not (Test-Path $parentDir)) { New-Item -Path $parentDir -ItemType Directory -Force | Out-Null }; Start-BitsTransfer -Source $sourceUrl -Destination $destinationPath -Credential $credential -DisplayName "Downloading $item" | Out-Null }
                    }
                    Write-Progress -Activity "从 WebDAV 下载文件夹" -Completed
                    Write-Host "WebDAV 文件夹下载完成！" -ForegroundColor Green
                } else { Write-Host "WebDAV 文件夹为空，无需下载。" }
            } catch { Write-Error "WebDAV 文件夹下载失败: $($_.Exception.Message)" }
        }

        # --- 单文件下载 ---
        if ($enableWebDAVFileDownload) {
            Write-Host "正在准备下载单个文件..."
            $job = $null
            try {
                $desktopPath = [System.Environment]::GetFolderPath('Desktop'); $fileName = Split-Path -Path $webdavFileUrl -Leaf; $outputFilePath = Join-Path -Path $desktopPath -ChildPath $fileName
                $job = Start-BitsTransfer -Source $webdavFileUrl -Destination $outputFilePath -Credential $credential -Asynchronous
                while ($job.JobState -in 'Connecting', 'Transferring', 'Queued') { if ($job.BytesTotal -gt 0) { $percent = ($job.BytesTransferred / $job.BytesTotal) * 100; Write-Progress -Activity "从 WebDAV 下载文件" -Status "下载中: $fileName" -PercentComplete $percent -CurrentOperation ("{0:N2} MB / {1:N2} MB" -f ($job.BytesTransferred/1MB), ($job.BytesTotal/1MB)) } else { Write-Progress -Activity "从 WebDAV 下载文件" -Status "正在连接并获取文件大小..." }; Start-Sleep -Milliseconds 500 }
                Write-Progress -Activity "从 WebDAV 下载文件" -Completed
                if ($job.JobState -eq 'Transferred') { Complete-BitsTransfer -BitsJob $job; Write-Host "文件 '$fileName' 下载成功！" -ForegroundColor Green } else { $errorDetails = $job.ErrorDescription; throw "BITS 任务失败。状态: $($job.JobState). 服务器返回错误: $errorDetails" }
            } catch { Write-Error "WebDAV 单文件下载失败: $($_.Exception.Message)" } finally { if ($job) { Remove-BitsTransfer -BitsJob $job -Confirm:$false -ErrorAction SilentlyContinue } }
        }
    } else { Write-Warning "用户取消了凭据输入，已跳过所有 WebDAV 下载任务。" }
    Write-Host "--- WebDAV 下载任务结束 ---" -ForegroundColor Yellow
    Write-Host ""
}

# --- 5. 获取 API 版本 ---
Write-Host "正在获取最新的 League of Legends API 版本..."
try { $latestApiVersion = (Invoke-RestMethod -Uri $ddragonApiUrl)[0]; Write-Host "成功获取到 API 版本号: $latestApiVersion" } catch { Write-Error "获取 API 版本号时出错: $($_.Exception.Message)" }
Write-Host ""

# --- 6. 搜索 RiotClientServices.exe ---
Write-Host "正在搜索 '$riotClientExe'..."
foreach ($drive in $searchDrives) { $riotClientPaths = Get-ChildItem -Path $drive -Filter $riotClientExe -Depth $searchDepth -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1; if ($riotClientPaths) { $riotClientFullPath = $riotClientPaths.DirectoryName; Write-Host "找到 '$riotClientExe' 目录: $riotClientFullPath"; break } }
if (-not $riotClientFullPath) { Write-Host "'$riotClientExe' 未找到。" }
Write-Host ""

# --- 7. 搜索所有 LeagueClient.exe 实例 ---
Write-Host "正在搜索所有 '$leagueClientExe' 实例..."
foreach ($drive in $searchDrives) {
    Write-Host "正在 '$drive' 中搜索..."
    $foundPaths = Get-ChildItem -Path $drive -Filter $leagueClientExe -Depth $searchDepth -Recurse -ErrorAction SilentlyContinue
    foreach ($clientPath in $foundPaths) {
        $clientDir = $clientPath.DirectoryName
        if ($clientDir -like "*PBE*") { Write-Host "  - 找到实例于: $clientDir -> 已跳过 (PBE 客户端)"; continue }
        $gamePath = Join-Path -Path $clientDir -ChildPath "Game"; $stubDllPath = Join-Path -Path $gamePath -ChildPath "stub.dll"
        if (-not ((Test-Path $gamePath) -and (Test-Path $stubDllPath))) { Write-Host "  - 找到实例于: $clientDir -> 已跳过 (未找到 'Game\stub.dll' 结构)"; continue }
        Write-Host "  - 找到实例于: $clientDir -> 结构验证通过"
        try { $versionFull = (Get-Item $clientPath.FullName).VersionInfo.FileVersion; if ($versionFull) { $versionDisplay = ($versionFull.Split('.') | Select-Object -First 3) -join '.'; $leagueClientFoundList += @{ Path = $clientDir; VersionFull = $versionFull; VersionDisplay = $versionDisplay }; Write-Host "    版本: $versionDisplay" } } catch { Write-Warning "    无法获取版本信息。" }
    }
}
Write-Host "搜索完成，共找到 $($leagueClientFoundList.Count) 个有效实例。"
Write-Host ""

# --- 8. 筛选最接近的版本 ---
if ($leagueClientFoundList.Count -gt 0 -and $latestApiVersion) {
    Write-Host "正在筛选最接近 API 版本 '$latestApiVersion' 的客户端..."
    $minDistance = [int]::MaxValue
    foreach ($client in $leagueClientFoundList) { $distance = Get-VersionDistance -LocalVersionDisplay $client.VersionDisplay -ApiVersion $latestApiVersion; if ($distance -lt $minDistance) { $minDistance = $distance; $closestLeagueClient = $client } }
    if ($closestLeagueClient) { Write-Host "找到最接近的版本: $($closestLeagueClient.VersionDisplay) (路径: $($closestLeagueClient.Path))"; $isLeagueClientVersionValid = Is-VersionCompatible -LocalVersionDisplay $closestLeagueClient.VersionDisplay -ApiVersion $latestApiVersion }
}
Write-Host ""

# --- 9. 复制或移动文件 ---
# (此部分及后续部分保持不变)
$wasFileOperationSkipped = $false; $targetRiotClientPath = ""; $targetLeagueClientPath = ""
if ($closestLeagueClient -and $riotClientFullPath) {
    Write-Host "--- 开始执行文件整理操作 ---"
    $targetDrive = Split-Path -Path $closestLeagueClient.Path -Qualifier; $newRiotGamesPath = Join-Path -Path $targetDrive -ChildPath "Riot Games"; $riotClientDirName = Split-Path -Path $riotClientFullPath -Leaf; $leagueClientDirName = Split-Path -Path $closestLeagueClient.Path -Leaf; $targetRiotClientPath = Join-Path -Path $newRiotGamesPath -ChildPath $riotClientDirName; $targetLeagueClientPath = Join-Path -Path $newRiotGamesPath -ChildPath $leagueClientDirName
    if ((Test-Path $targetRiotClientPath) -and (Test-Path $targetLeagueClientPath)) { Write-Host "目标目录 '$newRiotGamesPath' 中已存在所需文件夹，将跳过文件整理。" -ForegroundColor Yellow; $wasFileOperationSkipped = $true } else { try { Write-Host "正在准备目标目录: $newRiotGamesPath"; New-Item -Path $newRiotGamesPath -ItemType Directory -Force -ErrorAction Stop | Out-Null; switch ($fileOperationMode.ToLower()) { 'copy' { Write-Host "正在复制 Riot Client..."; Copy-Item -Path $riotClientFullPath -Destination $newRiotGamesPath -Recurse -Force; Write-Host "正在复制 League of Legends..."; Copy-Item -Path $closestLeagueClient.Path -Destination $newRiotGamesPath -Recurse -Force } default { if ($fileOperationMode.ToLower() -ne 'move') { Write-Warning "无效模式, 将执行默认的 'Move' 操作。" }; Write-Host "正在移动 Riot Client..."; Move-Item -Path $riotClientFullPath -Destination $newRiotGamesPath -Force; Write-Host "正在移动 League of Legends..."; Move-Item -Path $closestLeagueClient.Path -Destination $newRiotGamesPath -Force } }; Write-Host "文件整理操作成功。" -ForegroundColor Green } catch { Write-Error "文件整理操作失败: $($_.Exception.Message)" } }
} else { Write-Host "--- 未满足文件整理条件 (未同时找到两个客户端目录) ---" }
Write-Host ""

# --- 10. 创建桌面快捷方式 ---
if ($closestLeagueClient -and $riotClientFullPath) {
    Write-Host "--- 开始创建桌面快捷方式 ---"
    try { $finalRiotClientPath = if ($wasFileOperationSkipped) { $riotClientFullPath } else { $targetRiotClientPath }; $finalLeagueClientPath = if ($wasFileOperationSkipped) { $closestLeagueClient.Path } else { $targetLeagueClientPath }; $finalRiotClientExe = Join-Path -Path $finalRiotClientPath -ChildPath $riotClientExe; $finalLeagueClientExe = Join-Path -Path $finalLeagueClientPath -ChildPath $leagueClientExe; if ((Test-Path $finalRiotClientExe) -and (Test-Path $finalLeagueClientExe)) { $wshell = New-Object -ComObject WScript.Shell; $desktopPath = [System.Environment]::GetFolderPath('Desktop'); $shortcutRiot = $wshell.CreateShortcut((Join-Path $desktopPath "Riot Client.lnk")); $shortcutRiot.TargetPath = $finalRiotClientExe; $shortcutRiot.Save(); Write-Host "已创建 Riot Client 快捷方式."; $shortcutLeague = $wshell.CreateShortcut((Join-Path $desktopPath "League of Legends.lnk")); $shortcutLeague.TargetPath = $finalLeagueClientExe; $shortcutLeague.Save(); Write-Host "已创建 League of Legends 快捷方式。" } else { Write-Warning "无法定位最终的 .exe 文件，已跳过创建快捷方式。" } } catch { Write-Error "创建快捷方式时出错: $($_.Exception.Message)" }
}
Write-Host ""

# --- 11. 清理和更新配置文件 ---
if ($closestLeagueClient -and $riotClientFullPath) {
    Write-Host "--- 开始清理和更新配置文件 ---"
    try { $finalRiotClientPath = if ($wasFileOperationSkipped) { $riotClientFullPath } else { $targetRiotClientPath }; $finalLeagueClientPath = if ($wasFileOperationSkipped) { $closestLeagueClient.Path } else { $targetLeagueClientPath }; $finalInstallRootPath = Split-Path -Path $finalLeagueClientPath -Parent; $programDataPath = $env:ProgramData; $machineCfgPath = Join-Path $programDataPath "Riot Games\machine.cfg"; Write-Host "正在检查 '$machineCfgPath'..."; if (Test-Path $machineCfgPath) { Remove-Item -Path $machineCfgPath -Force -ErrorAction SilentlyContinue; Write-Host "文件已删除。" } else { Write-Host "文件不存在，无需删除。" }; $yamlFilePath = Join-Path $programDataPath "Riot Games\Metadata\league_of_legends.live\league_of_legends.live.product_settings.yaml"; $yamlFileDir = Split-Path $yamlFilePath -Parent; $yamlFullPath = $finalLeagueClientPath.Replace('\', '/'); $yamlRootPath = $finalInstallRootPath.Replace('\', '/'); Write-Host "正在更新 '$yamlFilePath'..."; if (Test-Path $yamlFilePath) { $content = Get-Content $yamlFilePath -Raw; $newContent = $content -replace "(?m)^(product_install_full_path:).*", "product_install_full_path: ""$yamlFullPath""" -replace "(?m)^(product_install_root:).*", "product_install_root: ""$yamlRootPath"""; Set-Content -Path $yamlFilePath -Value $newContent -Encoding UTF8; Write-Host "YAML 文件更新成功。" } else { if (-not (Test-Path $yamlFileDir)) { New-Item -Path $yamlFileDir -ItemType Directory -Force | Out-Null }; $yamlTemplate = @"
auto_patching_enabled_by_player: false
dependencies:
    Direct X 9: {hash: "", phase: "Imported", version: "1.0.0"}
    vanguard: true
locale_data:
    available_locales: ["ar_AE", "id_ID", "cs_CZ", "de_DE", "el_GR", "en_AU", "en_GB", "en_PH", "en_SG", "en_US", "es_AR", "es_ES", "es_MX", "fr_FR", "hu_HU", "it_IT", "ja_JP", "ko_KR", "pl_PL", "pt_BR", "ro_RO", "ru_RU", "th_TH", "tr_TR", "vi_VN", "zh_MY", "zh_TW"]
    default_locale: "zh_TW"
patching_policy: "manual"
patchline_patching_ask_policy: "ask"
product_install_full_path: "$yamlFullPath"
product_install_root: "$yamlRootPath"
settings: {create_uninstall_key: true, locale: "zh_TW"}
should_repair: false
"@; Set-Content -Path $yamlFilePath -Value $yamlTemplate -Encoding UTF8; Write-Host "新的 YAML 文件已创建并配置完成。" } } catch { Write-Error "清理或更新配置文件时出错: $($_.Exception.Message)" }
}
Write-Host ""

# --- 12. 最终结果报告 ---
Write-Host "--- 最终结果报告 ---" -ForegroundColor Cyan
Write-Host "找到的 RiotClientServices.exe 目录: $riotClientFullPath"
if ($closestLeagueClient) { Write-Host "找到的最优 LeagueClient.exe 目录: $($closestLeagueClient.Path)"; Write-Host "  - 版本: $($closestLeagueClient.VersionDisplay) (完整: $($closestLeagueClient.VersionFull))" } else { Write-Host "未找到有效的 LeagueClient.exe。" }
Write-Host "版本兼容性检查结果: $isLeagueClientVersionValid"
Write-Host ""

# --- 13. 打开网页 ---
Write-Host "所有操作已完成，正在打开指定网页..."
try { Start-Process "https://uuyc.163.com" } catch { Write-Warning "无法自动打开网页: $($_.Exception.Message)" }
Write-Host ""

# --- 14. 计算并显示总耗时 ---
$endTime = Get-Date; $duration = $endTime - $startTime; $durationFormatted = "{0:00}:{1:00}:{2:00}" -f $duration.Hours, $duration.Minutes, $duration.Seconds
Write-Host "--- 脚本执行完毕，总耗时: $durationFormatted ---" -ForegroundColor Cyan
Write-Host ""

# --- 15. 等待用户输入后关闭 ---
Read-Host -Prompt "按 Enter 键关闭此窗口..."
