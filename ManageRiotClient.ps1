<#
.SYNOPSIS
    一个全能的游戏客户端管理脚本。它能从 WebDAV 下载资源（带进度条），自动搜索、验证、整理
    Riot Games 客户端，创建桌面快捷方式，重置配置文件，并在最后打开指定网页。

.DESCRIPTION
    此脚本按顺序执行以下操作：
    1. [可选] WebDAV 下载:
       - 统一一次性输入凭据。
       - 下载指定的文件夹和单个文件到桌面，并显示实时进度条。
       - 修正了文件夹下载时可能产生的重复目录问题。
    2. 客户端搜索与验证: 搜索并找出版本最合适的 League of Legends 客户端。
    3. 客户端文件整理: 检查目标目录，避免重复操作，然后根据配置执行 "Move" 或 "Copy"。
    4. 创建桌面快捷方式: 为整理好的客户端在桌面创建快捷方式。
    5. 清理和更新配置文件: 删除 machine.cfg 并动态修改或创建 product_settings.yaml。
    6. [新增] 打开网页: 所有操作完成后，在默认浏览器中打开指定网页。
    7. 结束并等待用户确认。

.NOTES
    作者: AI 助手
    日期: 2023-10-27
    版本: 4.0 (修正：BITS 任务的错误属性获取方式)

.EXAMPLE
    .\ManageRiotClient.ps1
#>

# --- 配置 ---
# --- 1. WebDAV 下载配置 ---
$enableWebDAVDownload = $true      # 设置为 $true 启用 WebDAV 文件夹下载
$webdavUrl = "http://www1.movemama.cn/便捷/"

$enableWebDAVFileDownload = $true # 设置为 $true 启用 WebDAV 单文件下载
$webdavFileUrl = "http://www1.movemama.cn/1.rar"

# --- 2. Riot 客户端文件操作配置 ---
$fileOperationMode = "Move" # 可选操作: "Move" (移动) 或 "Copy" (复制)。默认为 "Move"。
$searchDepth = 8 # 搜索的最大深度

# --- 3. 文件名配置 (一般无需修改) ---
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
function Get-VersionParts {
    param(
        [Parameter(Mandatory=$true)]
        [string]$VersionString,
        [int]$PartsCount = 3
    )
    $parts = $VersionString.Split('.', [System.StringSplitOptions]::RemoveEmptyEntries) | Select-Object -First $PartsCount
    while ($parts.Count -lt $PartsCount) { $parts += "0" }
    return $parts | ForEach-Object { [int]$_ }
}

function Get-VersionDistance {
    param(
        [Parameter(Mandatory=$true)]
        [string]$LocalVersionDisplay,
        [Parameter(Mandatory=$true)]
        [string]$ApiVersion
    )
    $localInts = Get-VersionParts -VersionString $LocalVersionDisplay
    $apiInts = Get-VersionParts -VersionString $ApiVersion
    $distance = ([math]::Abs($localInts[0] - $apiInts[0]) * 10000) +
                ([math]::Abs($localInts[1] - $apiInts[1]) * 100) +
                ([math]::Abs($localInts[2] - $apiInts[2]) * 1)
    return $distance
}

function Is-VersionCompatible {
    param(
        [Parameter(Mandatory=$true)]
        [string]$LocalVersionDisplay,
        [Parameter(Mandatory=$true)]
        [string]$ApiVersion
    )
    if (-not $ApiVersion) { return $false }
    $localInts = Get-VersionParts -VersionString $LocalVersionDisplay
    $apiInts = Get-VersionParts -VersionString $ApiVersion
    if ($localInts[0] -eq $apiInts[0] -and $localInts[1] -eq $apiInts[1] -and $localInts[2] -ge ($apiInts[2] - 1) -and $localInts[2] -le ($apiInts[2] + 1)) { return $true }
    if ($localInts[0] -eq $apiInts[0] -and $localInts[1] -ge ($apiInts[1] - 1) -and $localInts[1] -le ($apiInts[1] + 1)) { return $true }
    if ($localInts[0] -ge ($apiInts[0] - 1) -and $localInts[0] -le ($apiInts[0] + 1)) { return $true }
    return $false
}

# --- 主流程 ---

# --- 1 & 2. WebDAV 统一操作 ---
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
            $uncPath = "\\{0}@{1}{2}" -f $uri.DnsSafeHost, $uri.Port, $uri.AbsolutePath.Replace('/', '\')
            $uncPath = [System.Net.WebUtility]::UrlDecode($uncPath)
            $driveName = "WebDAVShare"
            try {
                if (-not (Test-Path $localDownloadPath)) { New-Item -Path $localDownloadPath -ItemType Directory | Out-Null }
                Write-Host "正在连接到 WebDAV 服务器..."
                New-PSDrive -Name $driveName -PSProvider FileSystem -Root $uncPath -Credential $credential -ErrorAction Stop | Out-Null
                Write-Host "连接成功，正在准备下载文件到 '$localDownloadPath'..."
                
                $sourceItems = Get-ChildItem -Path "$($driveName):\" -Recurse
                $totalCount = $sourceItems.Count
                $copiedCount = 0
                if ($totalCount -gt 0) {
                    Copy-Item -Path "$($driveName):\*" -Destination $localDownloadPath -Recurse -Force -PassThru | ForEach-Object {
                        $copiedCount++
                        $percent = ($copiedCount / $totalCount) * 100
                        Write-Progress -Activity "从 WebDAV 下载文件夹" -Status "正在复制: $($_.Name)" -PercentComplete $percent -CurrentOperation "$copiedCount / $totalCount"
                    }
                    Write-Progress -Activity "从 WebDAV 下载文件夹" -Completed
                } else {
                    Write-Host "WebDAV 文件夹为空，无需下载。"
                }
                Write-Host "WebDAV 文件夹下载完成！" -ForegroundColor Green
            } catch {
                Write-Error "WebDAV 文件夹下载失败: $($_.Exception.Message)"
            } finally {
                if (Get-PSDrive $driveName -ErrorAction SilentlyContinue) { Remove-PSDrive -Name $driveName; Write-Host "已断开 WebDAV 连接。" }
            }
        }

        # --- 单文件下载 ---
        if ($enableWebDAVFileDownload) {
            Write-Host "正在准备下载单个文件..."
            $job = $null
            try {
                $desktopPath = [System.Environment]::GetFolderPath('Desktop')
                $fileName = Split-Path -Path $webdavFileUrl -Leaf
                $outputFilePath = Join-Path -Path $desktopPath -ChildPath $fileName
                
                # 开始 BITS 传输任务
                $job = Start-BitsTransfer -Source $webdavFileUrl -Destination $outputFilePath -Credential $credential -Asynchronous
                
                # 循环显示进度，直到任务结束（无论成功、失败还是暂停）
                while ($job.JobState -in 'Connecting', 'Transferring', 'Queued') {
                    if ($job.BytesTotal -gt 0) { # 只有在总大小已知时才计算百分比
                        $percent = ($job.BytesTransferred / $job.BytesTotal) * 100
                        Write-Progress -Activity "从 WebDAV 下载文件" -Status "下载中: $fileName" -PercentComplete $percent -CurrentOperation ("{0:N2} MB / {1:N2} MB" -f ($job.BytesTransferred/1MB), ($job.BytesTotal/1MB))
                    } else {
                        Write-Progress -Activity "从 WebDAV 下载文件" -Status "正在连接并获取文件大小..."
                    }
                    Start-Sleep -Milliseconds 500
                }
                Write-Progress -Activity "从 WebDAV 下载文件" -Completed

                # 在完成任务前，检查任务的最终状态
                if ($job.JobState -eq 'Transferred') {
                    # 只有当状态是“已传输”时，才算真正成功
                    Complete-BitsTransfer -BitsJob $job
                    Write-Host "文件 '$fileName' 下载成功！" -ForegroundColor Green
                } else {
                    # --- 【最终修正】 ---
                    # 如果是其他状态（如 Error, TransientError），则获取错误信息并抛出异常
                    $errorDetails = $job.ErrorDescription
                    throw "BITS 任务失败。状态: $($job.JobState). 服务器返回错误: $errorDetails"
                }

            } catch {
                # 现在 catch 块可以捕获到我们手动抛出的详细错误
                Write-Error "WebDAV 单文件下载失败: $($_.Exception.Message)"
            } finally {
                # 确保无论如何都清理任务
                if ($job) { Remove-BitsTransfer -BitsJob $job -Confirm:$false -ErrorAction SilentlyContinue }
            }
        }
    } else {
        Write-Warning "用户取消了凭据输入，已跳过所有 WebDAV 下载任务。"
    }
    Write-Host "--- WebDAV 下载任务结束 ---" -ForegroundColor Yellow
    Write-Host ""
    # --- 3. 获取 API 版本 ---
Write-Host "正在获取最新的 League of Legends API 版本..."
try {
    $latestApiVersion = (Invoke-RestMethod -Uri $ddragonApiUrl)[0]
    Write-Host "成功获取到 API 版本号: $latestApiVersion"
} catch {
    Write-Error "获取 API 版本号时出错: $($_.Exception.Message)"
}
Write-Host ""

# --- 4. 搜索 RiotClientServices.exe ---
Write-Host "正在搜索 '$riotClientExe'..."
foreach ($drive in $searchDrives) {
    $riotClientPaths = Get-ChildItem -Path $drive -Filter $riotClientExe -Depth $searchDepth -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($riotClientPaths) {
        $riotClientFullPath = $riotClientPaths.DirectoryName
        Write-Host "找到 '$riotClientExe' 目录: $riotClientFullPath"
        break
    }
}
if (-not $riotClientFullPath) { Write-Host "'$riotClientExe' 未找到。" }
Write-Host ""

# --- 5. 搜索所有 LeagueClient.exe 实例 ---
Write-Host "正在搜索所有 '$leagueClientExe' 实例..."
foreach ($drive in $searchDrives) {
    Write-Host "正在 '$drive' 中搜索..."
    $foundPaths = Get-ChildItem -Path $drive -Filter $leagueClientExe -Depth $searchDepth -Recurse -ErrorAction SilentlyContinue
    foreach ($clientPath in $foundPaths) {
        if ($clientPath.DirectoryName -like "*PBE*") {
            Write-Host "  - 找到实例于: $($clientPath.DirectoryName) -> 已跳过 (PBE 客户端)"
            continue
        }
        Write-Host "  - 找到实例于: $($clientPath.DirectoryName)"
        try {
            $versionFull = (Get-Item $clientPath.FullName).VersionInfo.FileVersion
            if ($versionFull) {
                $versionDisplay = ($versionFull.Split('.') | Select-Object -First 3) -join '.'
                $leagueClientFoundList += @{ Path = $clientPath.DirectoryName; VersionFull = $versionFull; VersionDisplay = $versionDisplay }
                Write-Host "    版本: $versionDisplay"
            }
        } catch { Write-Warning "    无法获取版本信息。" }
    }
}
Write-Host "搜索完成，共找到 $($leagueClientFoundList.Count) 个有效实例。"
Write-Host ""

# --- 6. 筛选最接近的版本 ---
if ($leagueClientFoundList.Count -gt 0 -and $latestApiVersion) {
    Write-Host "正在筛选最接近 API 版本 '$latestApiVersion' 的客户端..."
    $minDistance = [int]::MaxValue
    foreach ($client in $leagueClientFoundList) {
        $distance = Get-VersionDistance -LocalVersionDisplay $client.VersionDisplay -ApiVersion $latestApiVersion
        if ($distance -lt $minDistance) {
            $minDistance = $distance
            $closestLeagueClient = $client
        }
    }
    if ($closestLeagueClient) {
        Write-Host "找到最接近的版本: $($closestLeagueClient.VersionDisplay) (路径: $($closestLeagueClient.Path))"
        $isLeagueClientVersionValid = Is-VersionCompatible -LocalVersionDisplay $closestLeagueClient.VersionDisplay -ApiVersion $latestApiVersion
    }
}
Write-Host ""

# --- 7. 复制或移动文件 ---
$wasFileOperationSkipped = $false
$targetRiotClientPath = ""
$targetLeagueClientPath = ""
if ($closestLeagueClient -and $riotClientFullPath) {
    Write-Host "--- 开始执行文件整理操作 ---"
    $targetDrive = Split-Path -Path $closestLeagueClient.Path -Qualifier
    $newRiotGamesPath = Join-Path -Path $targetDrive -ChildPath "Riot Games"
    $riotClientDirName = Split-Path -Path $riotClientFullPath -Leaf
    $leagueClientDirName = Split-Path -Path $closestLeagueClient.Path -Leaf
    $targetRiotClientPath = Join-Path -Path $newRiotGamesPath -ChildPath $riotClientDirName
    $targetLeagueClientPath = Join-Path -Path $newRiotGamesPath -ChildPath $leagueClientDirName

    if ((Test-Path $targetRiotClientPath) -and (Test-Path $targetLeagueClientPath)) {
        Write-Host "目标目录 '$newRiotGamesPath' 中已存在所需文件夹，将跳过文件整理。" -ForegroundColor Yellow
        $wasFileOperationSkipped = $true
    } else {
        try {
            Write-Host "正在准备目标目录: $newRiotGamesPath"
            New-Item -Path $newRiotGamesPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
            switch ($fileOperationMode.ToLower()) {
                'copy' {
                    Write-Host "正在复制 Riot Client..."
                    Copy-Item -Path $riotClientFullPath -Destination $newRiotGamesPath -Recurse -Force
                    Write-Host "正在复制 League of Legends..."
                    Copy-Item -Path $closestLeagueClient.Path -Destination $newRiotGamesPath -Recurse -Force
                }
                default {
                    if ($fileOperationMode.ToLower() -ne 'move') { Write-Warning "无效模式, 将执行默认的 'Move' 操作。" }
                    Write-Host "正在移动 Riot Client..."
                    Move-Item -Path $riotClientFullPath -Destination $newRiotGamesPath -Force
                    Write-Host "正在移动 League of Legends..."
                    Move-Item -Path $closestLeagueClient.Path -Destination $newRiotGamesPath -Force
                }
            }
            Write-Host "文件整理操作成功。" -ForegroundColor Green
        } catch {
            Write-Error "文件整理操作失败: $($_.Exception.Message)"
        }
    }
} else {
    Write-Host "--- 未满足文件整理条件 (未同时找到两个客户端目录) ---"
}
Write-Host ""

# --- 8. 创建桌面快捷方式 ---
if ($closestLeagueClient -and $riotClientFullPath) {
    Write-Host "--- 开始创建桌面快捷方式 ---"
    try {
        $finalRiotClientPath = if ($wasFileOperationSkipped) { $riotClientFullPath } else { $targetRiotClientPath }
        $finalLeagueClientPath = if ($wasFileOperationSkipped) { $closestLeagueClient.Path } else { $targetLeagueClientPath }
        $finalRiotClientExe = Join-Path -Path $finalRiotClientPath -ChildPath $riotClientExe
        $finalLeagueClientExe = Join-Path -Path $finalLeagueClientPath -ChildPath $leagueClientExe

        if ((Test-Path $finalRiotClientExe) -and (Test-Path $finalLeagueClientExe)) {
            $wshell = New-Object -ComObject WScript.Shell
            $desktopPath = [System.Environment]::GetFolderPath('Desktop')
            $shortcutRiot = $wshell.CreateShortcut((Join-Path $desktopPath "Riot Client.lnk"))
            $shortcutRiot.TargetPath = $finalRiotClientExe
            $shortcutRiot.Save()
            Write-Host "已创建 Riot Client 快捷方式。"
            $shortcutLeague = $wshell.CreateShortcut((Join-Path $desktopPath "League of Legends.lnk"))
            $shortcutLeague.TargetPath = $finalLeagueClientExe
            $shortcutLeague.Save()
            Write-Host "已创建 League of Legends 快捷方式。"
        } else {
            Write-Warning "无法定位最终的 .exe 文件，已跳过创建快捷方式。"
        }
    } catch {
        Write-Error "创建快捷方式时出错: $($_.Exception.Message)"
    }
}
Write-Host ""

# --- 9. 清理和更新配置文件 ---
if ($closestLeagueClient -and $riotClientFullPath) {
    Write-Host "--- 开始清理和更新配置文件 ---"
    try {
        $finalRiotClientPath = if ($wasFileOperationSkipped) { $riotClientFullPath } else { $targetRiotClientPath }
        $finalLeagueClientPath = if ($wasFileOperationSkipped) { $closestLeagueClient.Path } else { $targetLeagueClientPath }
        $finalInstallRootPath = Split-Path -Path $finalLeagueClientPath -Parent

        $programDataPath = $env:ProgramData
        $machineCfgPath = Join-Path $programDataPath "Riot Games\machine.cfg"
        Write-Host "正在检查 '$machineCfgPath'..."
        if (Test-Path $machineCfgPath) {
            Remove-Item -Path $machineCfgPath -Force -ErrorAction SilentlyContinue
            Write-Host "文件已删除。"
        } else {
            Write-Host "文件不存在，无需删除。"
        }

        $yamlFilePath = Join-Path $programDataPath "Riot Games\Metadata\league_of_legends.live\league_of_legends.live.product_settings.yaml"
        $yamlFileDir = Split-Path $yamlFilePath -Parent
        $yamlFullPath = $finalLeagueClientPath.Replace('\', '/')
        $yamlRootPath = $finalInstallRootPath.Replace('\', '/')

        Write-Host "正在更新 '$yamlFilePath'..."
        if (Test-Path $yamlFilePath) {
            $content = Get-Content $yamlFilePath -Raw
            $newContent = $content -replace "(?m)^(product_install_full_path:).*", "product_install_full_path: ""$yamlFullPath""" `
                                  -replace "(?m)^(product_install_root:).*", "product_install_root: ""$yamlRootPath"""
            Set-Content -Path $yamlFilePath -Value $newContent -Encoding UTF8
            Write-Host "YAML 文件更新成功。"
        } else {
            if (-not (Test-Path $yamlFileDir)) {
                New-Item -Path $yamlFileDir -ItemType Directory -Force | Out-Null
            }
            $yamlTemplate = @"
auto_patching_enabled_by_player: false
dependencies:
    Direct X 9:
        hash: ""
        phase: "Imported"
        version: "1.0.0"
    vanguard: true
locale_data:
    available_locales:
    - "ar_AE"
    - "id_ID"
    - "cs_CZ"
    - "de_DE"
    - "el_GR"
    - "en_AU"
    - "en_GB"
    - "en_PH"
    - "en_SG"
    - "en_US"
    - "es_AR"
    - "es_ES"
    - "es_MX"
    - "fr_FR"
    - "hu_HU"
    - "it_IT"
    - "ja_JP"
    - "ko_KR"
    - "pl_PL"
    - "pt_BR"
    - "ro_RO"
    - "ru_RU"
    - "th_TH"
    - "tr_TR"
    - "vi_VN"
    - "zh_MY"
    - "zh_TW"
    default_locale: "zh_TW"
patching_policy: "manual"
patchline_patching_ask_policy: "ask"
product_install_full_path: "$yamlFullPath"
product_install_root: "$yamlRootPath"
settings:
    create_uninstall_key: true
    locale: "zh_TW"
should_repair: false
"@
            Set-Content -Path $yamlFilePath -Value $yamlTemplate -Encoding UTF8
            Write-Host "新的 YAML 文件已创建并配置完成。"
        }
    } catch {
        Write-Error "清理或更新配置文件时出错: $($_.Exception.Message)"
    }
}
Write-Host ""

# --- 10. 最终结果报告 ---
Write-Host "--- 最终结果报告 ---"
Write-Host "找到的 RiotClientServices.exe 目录: $riotClientFullPath"
if ($closestLeagueClient) {
    Write-Host "找到的最优 LeagueClient.exe 目录: $($closestLeagueClient.Path)"
    Write-Host "  - 版本: $($closestLeagueClient.VersionDisplay) (完整: $($closestLeagueClient.VersionFull))"
} else {
    Write-Host "未找到有效的 LeagueClient.exe。"
}
Write-Host "版本兼容性检查结果: $isLeagueClientVersionValid"
Write-Host ""

# --- 11. (新增) 打开网页 ---
Write-Host "所有操作已完成，正在打开指定网页..."
try {
    Start-Process "https://uuyc.163.com"
} catch {
    Write-Warning "无法自动打开网页: $($_.Exception.Message)"
}

# --- 12. 等待用户输入后关闭 ---
Read-Host -Prompt "按 Enter 键关闭此窗口..."


}
