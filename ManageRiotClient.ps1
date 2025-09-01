<#
.SYNOPSIS
    һ��ȫ�ܵ���Ϸ�ͻ��˹���ű������ܴ� WebDAV ������Դ���������������Զ���������֤������
    Riot Games �ͻ��ˣ����������ݷ�ʽ�����������ļ�����������ָ����ҳ��

.DESCRIPTION
    �˽ű���˳��ִ�����²�����
    1. [��ѡ] WebDAV ����:
       - ͳһһ��������ƾ�ݡ�
       - ����ָ�����ļ��к͵����ļ������棬����ʾʵʱ��������
       - �������ļ�������ʱ���ܲ������ظ�Ŀ¼���⡣
    2. �ͻ�����������֤: �������ҳ��汾����ʵ� League of Legends �ͻ��ˡ�
    3. �ͻ����ļ�����: ���Ŀ��Ŀ¼�������ظ�������Ȼ���������ִ�� "Move" �� "Copy"��
    4. ���������ݷ�ʽ: Ϊ����õĿͻ��������洴����ݷ�ʽ��
    5. ����͸��������ļ�: ɾ�� machine.cfg ����̬�޸Ļ򴴽� product_settings.yaml��
    6. [����] ����ҳ: ���в�����ɺ���Ĭ��������д�ָ����ҳ��
    7. �������ȴ��û�ȷ�ϡ�

.NOTES
    ����: AI ����
    ����: 2023-10-27
    �汾: 3.8 (�������ű�ִ����Ϻ��Զ���ָ����ҳ)

.EXAMPLE
    .\ManageRiotClient.ps1
#>

# --- ���� ---
# --- 1. WebDAV �������� ---
$enableWebDAVDownload = $true      # ����Ϊ $true ���� WebDAV �ļ�������
$webdavUrl = "http://www1.movemama.cn/���/"

$enableWebDAVFileDownload = $true # ����Ϊ $true ���� WebDAV ���ļ�����
$webdavFileUrl = "http://www1.movemama.cn/1.rar"

# --- 2. Riot �ͻ����ļ��������� ---
$fileOperationMode = "Move" # ��ѡ����: "Move" (�ƶ�) �� "Copy" (����)��Ĭ��Ϊ "Move"��
$searchDepth = 8 # ������������

# --- 3. �ļ������� (һ�������޸�) ---
$riotClientExe = "RiotClientServices.exe"
$leagueClientExe = "LeagueClient.exe"
$ddragonApiUrl = "https://ddragon.leagueoflegends.com/api/versions.json"

# --- ���ڴ洢����ı��� ---
$riotClientFullPath = ""
$leagueClientFoundList = @()
$latestApiVersion = ""
$closestLeagueClient = $null
$isLeagueClientVersionValid = $false

# --- ����Ҫ������������ ---
$searchDrives = Get-PSDrive -PSProvider FileSystem | Where-Object {$_.Root -like "*:\" -and $_.Provider.Name -eq "FileSystem" -and $_.Free -gt 0} | Select-Object -ExpandProperty Root

# --- �汾�Ŵ���ͱȽϺ��� ---
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

# --- ������ ---

# --- 1 & 2. WebDAV ͳһ���� ---
if ($enableWebDAVDownload -or $enableWebDAVFileDownload) {
    Write-Host "--- ��ʼִ�� WebDAV �������� ---" -ForegroundColor Yellow
    $credential = Get-Credential -UserName "" -Message "�������������� WebDAV ������ƾ��"

    if ($credential) {
        # --- �ļ������� ---
        if ($enableWebDAVDownload) {
            Write-Host "����׼�������ļ���..."
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
                Write-Host "�������ӵ� WebDAV ������..."
                New-PSDrive -Name $driveName -PSProvider FileSystem -Root $uncPath -Credential $credential -ErrorAction Stop | Out-Null
                Write-Host "���ӳɹ�������׼�������ļ��� '$localDownloadPath'..."
                
                $sourceItems = Get-ChildItem -Path "$($driveName):\" -Recurse
                $totalCount = $sourceItems.Count
                $copiedCount = 0
                if ($totalCount -gt 0) {
                    Copy-Item -Path "$($driveName):\*" -Destination $localDownloadPath -Recurse -Force -PassThru | ForEach-Object {
                        $copiedCount++
                        $percent = ($copiedCount / $totalCount) * 100
                        Write-Progress -Activity "�� WebDAV �����ļ���" -Status "���ڸ���: $($_.Name)" -PercentComplete $percent -CurrentOperation "$copiedCount / $totalCount"
                    }
                    Write-Progress -Activity "�� WebDAV �����ļ���" -Completed
                } else {
                    Write-Host "WebDAV �ļ���Ϊ�գ��������ء�"
                }
                Write-Host "WebDAV �ļ���������ɣ�" -ForegroundColor Green
            } catch {
                Write-Error "WebDAV �ļ�������ʧ��: $($_.Exception.Message)"
            } finally {
                if (Get-PSDrive $driveName -ErrorAction SilentlyContinue) { Remove-PSDrive -Name $driveName; Write-Host "�ѶϿ� WebDAV ���ӡ�" }
            }
        }

        # --- ���ļ����� ---
        if ($enableWebDAVFileDownload) {
            Write-Host "����׼�����ص����ļ�..."
            $job = $null
            try {
                $desktopPath = [System.Environment]::GetFolderPath('Desktop')
                $fileName = Split-Path -Path $webdavFileUrl -Leaf
                $outputFilePath = Join-Path -Path $desktopPath -ChildPath $fileName
                
                $job = Start-BitsTransfer -Source $webdavFileUrl -Destination $outputFilePath -Credential $credential -Asynchronous
                while ($job.JobState -in 'Connecting', 'Transferring') {
                    $percent = ($job.BytesTransferred / $job.BytesTotal) * 100
                    Write-Progress -Activity "�� WebDAV �����ļ�" -Status "������: $fileName" -PercentComplete $percent -CurrentOperation ("{0:N2} MB / {1:N2} MB" -f ($job.BytesTransferred/1MB), ($job.BytesTotal/1MB))
                    Start-Sleep -Milliseconds 500
                }
                Write-Progress -Activity "�� WebDAV �����ļ�" -Completed
                Complete-BitsTransfer -BitsJob $job
                Write-Host "�ļ� '$fileName' ���سɹ���" -ForegroundColor Green
            } catch {
                Write-Error "WebDAV ���ļ�����ʧ��: $($_.Exception.Message)"
            } finally {
                if ($job) { Remove-BitsTransfer -BitsJob $job -Confirm:$false -ErrorAction SilentlyContinue }
            }
        }
    } else {
        Write-Warning "�û�ȡ����ƾ�����룬���������� WebDAV ��������"
    }
    Write-Host "--- WebDAV ����������� ---" -ForegroundColor Yellow
    Write-Host ""
}

# --- 3. ��ȡ API �汾 ---
Write-Host "���ڻ�ȡ���µ� League of Legends API �汾..."
try {
    $latestApiVersion = (Invoke-RestMethod -Uri $ddragonApiUrl)[0]
    Write-Host "�ɹ���ȡ�� API �汾��: $latestApiVersion"
} catch {
    Write-Error "��ȡ API �汾��ʱ����: $($_.Exception.Message)"
}
Write-Host ""

# --- 4. ���� RiotClientServices.exe ---
Write-Host "�������� '$riotClientExe'..."
foreach ($drive in $searchDrives) {
    $riotClientPaths = Get-ChildItem -Path $drive -Filter $riotClientExe -Depth $searchDepth -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($riotClientPaths) {
        $riotClientFullPath = $riotClientPaths.DirectoryName
        Write-Host "�ҵ� '$riotClientExe' Ŀ¼: $riotClientFullPath"
        break
    }
}
if (-not $riotClientFullPath) { Write-Host "'$riotClientExe' δ�ҵ���" }
Write-Host ""

# --- 5. �������� LeagueClient.exe ʵ�� ---
Write-Host "������������ '$leagueClientExe' ʵ��..."
foreach ($drive in $searchDrives) {
    Write-Host "���� '$drive' ������..."
    $foundPaths = Get-ChildItem -Path $drive -Filter $leagueClientExe -Depth $searchDepth -Recurse -ErrorAction SilentlyContinue
    foreach ($clientPath in $foundPaths) {
        if ($clientPath.DirectoryName -like "*PBE*") {
            Write-Host "  - �ҵ�ʵ����: $($clientPath.DirectoryName) -> ������ (PBE �ͻ���)"
            continue
        }
        Write-Host "  - �ҵ�ʵ����: $($clientPath.DirectoryName)"
        try {
            $versionFull = (Get-Item $clientPath.FullName).VersionInfo.FileVersion
            if ($versionFull) {
                $versionDisplay = ($versionFull.Split('.') | Select-Object -First 3) -join '.'
                $leagueClientFoundList += @{ Path = $clientPath.DirectoryName; VersionFull = $versionFull; VersionDisplay = $versionDisplay }
                Write-Host "    �汾: $versionDisplay"
            }
        } catch { Write-Warning "    �޷���ȡ�汾��Ϣ��" }
    }
}
Write-Host "������ɣ����ҵ� $($leagueClientFoundList.Count) ����Чʵ����"
Write-Host ""

# --- 6. ɸѡ��ӽ��İ汾 ---
if ($leagueClientFoundList.Count -gt 0 -and $latestApiVersion) {
    Write-Host "����ɸѡ��ӽ� API �汾 '$latestApiVersion' �Ŀͻ���..."
    $minDistance = [int]::MaxValue
    foreach ($client in $leagueClientFoundList) {
        $distance = Get-VersionDistance -LocalVersionDisplay $client.VersionDisplay -ApiVersion $latestApiVersion
        if ($distance -lt $minDistance) {
            $minDistance = $distance
            $closestLeagueClient = $client
        }
    }
    if ($closestLeagueClient) {
        Write-Host "�ҵ���ӽ��İ汾: $($closestLeagueClient.VersionDisplay) (·��: $($closestLeagueClient.Path))"
        $isLeagueClientVersionValid = Is-VersionCompatible -LocalVersionDisplay $closestLeagueClient.VersionDisplay -ApiVersion $latestApiVersion
    }
}
Write-Host ""

# --- 7. ���ƻ��ƶ��ļ� ---
$wasFileOperationSkipped = $false
$targetRiotClientPath = ""
$targetLeagueClientPath = ""
if ($closestLeagueClient -and $riotClientFullPath) {
    Write-Host "--- ��ʼִ���ļ�������� ---"
    $targetDrive = Split-Path -Path $closestLeagueClient.Path -Qualifier
    $newRiotGamesPath = Join-Path -Path $targetDrive -ChildPath "Riot Games"
    $riotClientDirName = Split-Path -Path $riotClientFullPath -Leaf
    $leagueClientDirName = Split-Path -Path $closestLeagueClient.Path -Leaf
    $targetRiotClientPath = Join-Path -Path $newRiotGamesPath -ChildPath $riotClientDirName
    $targetLeagueClientPath = Join-Path -Path $newRiotGamesPath -ChildPath $leagueClientDirName

    if ((Test-Path $targetRiotClientPath) -and (Test-Path $targetLeagueClientPath)) {
        Write-Host "Ŀ��Ŀ¼ '$newRiotGamesPath' ���Ѵ��������ļ��У��������ļ�����" -ForegroundColor Yellow
        $wasFileOperationSkipped = $true
    } else {
        try {
            Write-Host "����׼��Ŀ��Ŀ¼: $newRiotGamesPath"
            New-Item -Path $newRiotGamesPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
            switch ($fileOperationMode.ToLower()) {
                'copy' {
                    Write-Host "���ڸ��� Riot Client..."
                    Copy-Item -Path $riotClientFullPath -Destination $newRiotGamesPath -Recurse -Force
                    Write-Host "���ڸ��� League of Legends..."
                    Copy-Item -Path $closestLeagueClient.Path -Destination $newRiotGamesPath -Recurse -Force
                }
                default {
                    if ($fileOperationMode.ToLower() -ne 'move') { Write-Warning "��Чģʽ, ��ִ��Ĭ�ϵ� 'Move' ������" }
                    Write-Host "�����ƶ� Riot Client..."
                    Move-Item -Path $riotClientFullPath -Destination $newRiotGamesPath -Force
                    Write-Host "�����ƶ� League of Legends..."
                    Move-Item -Path $closestLeagueClient.Path -Destination $newRiotGamesPath -Force
                }
            }
            Write-Host "�ļ���������ɹ���" -ForegroundColor Green
        } catch {
            Write-Error "�ļ��������ʧ��: $($_.Exception.Message)"
        }
    }
} else {
    Write-Host "--- δ�����ļ��������� (δͬʱ�ҵ������ͻ���Ŀ¼) ---"
}
Write-Host ""

# --- 8. ���������ݷ�ʽ ---
if ($closestLeagueClient -and $riotClientFullPath) {
    Write-Host "--- ��ʼ���������ݷ�ʽ ---"
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
            Write-Host "�Ѵ��� Riot Client ��ݷ�ʽ��"
            $shortcutLeague = $wshell.CreateShortcut((Join-Path $desktopPath "League of Legends.lnk"))
            $shortcutLeague.TargetPath = $finalLeagueClientExe
            $shortcutLeague.Save()
            Write-Host "�Ѵ��� League of Legends ��ݷ�ʽ��"
        } else {
            Write-Warning "�޷���λ���յ� .exe �ļ���������������ݷ�ʽ��"
        }
    } catch {
        Write-Error "������ݷ�ʽʱ����: $($_.Exception.Message)"
    }
}
Write-Host ""

# --- 9. ����͸��������ļ� ---
if ($closestLeagueClient -and $riotClientFullPath) {
    Write-Host "--- ��ʼ����͸��������ļ� ---"
    try {
        $finalRiotClientPath = if ($wasFileOperationSkipped) { $riotClientFullPath } else { $targetRiotClientPath }
        $finalLeagueClientPath = if ($wasFileOperationSkipped) { $closestLeagueClient.Path } else { $targetLeagueClientPath }
        $finalInstallRootPath = Split-Path -Path $finalLeagueClientPath -Parent

        $programDataPath = $env:ProgramData
        $machineCfgPath = Join-Path $programDataPath "Riot Games\machine.cfg"
        Write-Host "���ڼ�� '$machineCfgPath'..."
        if (Test-Path $machineCfgPath) {
            Remove-Item -Path $machineCfgPath -Force -ErrorAction SilentlyContinue
            Write-Host "�ļ���ɾ����"
        } else {
            Write-Host "�ļ������ڣ�����ɾ����"
        }

        $yamlFilePath = Join-Path $programDataPath "Riot Games\Metadata\league_of_legends.live\league_of_legends.live.product_settings.yaml"
        $yamlFileDir = Split-Path $yamlFilePath -Parent
        $yamlFullPath = $finalLeagueClientPath.Replace('\', '/')
        $yamlRootPath = $finalInstallRootPath.Replace('\', '/')

        Write-Host "���ڸ��� '$yamlFilePath'..."
        if (Test-Path $yamlFilePath) {
            $content = Get-Content $yamlFilePath -Raw
            $newContent = $content -replace "(?m)^(product_install_full_path:).*", "product_install_full_path: ""$yamlFullPath""" `
                                  -replace "(?m)^(product_install_root:).*", "product_install_root: ""$yamlRootPath"""
            Set-Content -Path $yamlFilePath -Value $newContent -Encoding UTF8
            Write-Host "YAML �ļ����³ɹ���"
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
            Write-Host "�µ� YAML �ļ��Ѵ�����������ɡ�"
        }
    } catch {
        Write-Error "�������������ļ�ʱ����: $($_.Exception.Message)"
    }
}
Write-Host ""

# --- 10. ���ս������ ---
Write-Host "--- ���ս������ ---"
Write-Host "�ҵ��� RiotClientServices.exe Ŀ¼: $riotClientFullPath"
if ($closestLeagueClient) {
    Write-Host "�ҵ������� LeagueClient.exe Ŀ¼: $($closestLeagueClient.Path)"
    Write-Host "  - �汾: $($closestLeagueClient.VersionDisplay) (����: $($closestLeagueClient.VersionFull))"
} else {
    Write-Host "δ�ҵ���Ч�� LeagueClient.exe��"
}
Write-Host "�汾�����Լ����: $isLeagueClientVersionValid"
Write-Host ""

# --- 11. (����) ����ҳ ---
Write-Host "���в�������ɣ����ڴ�ָ����ҳ..."
try {
    Start-Process "https://uuyc.163.com"
} catch {
    Write-Warning "�޷��Զ�����ҳ: $($_.Exception.Message)"
}

# --- 12. �ȴ��û������ر� ---
Read-Host -Prompt "�� Enter ���رմ˴���..."
