<#
.SYNOPSIS
  自动编目：扫描 web\soft\ 目录 + 软件清单.csv，自动生成 web\data.js
.DESCRIPTION
  在【服务器】上运行（或双击同目录的 更新软件目录.bat）。

  工作流程：
    1. 扫描 web\soft\<软件目录>\ 下的安装包（.exe/.msi/.zip 等）
    2. 每个目录取版本号最高的文件作为当前版本（从文件名识别版本号）
    3. 元数据（名称/分类/说明/版本）优先级：软件清单.csv > 安装包旁 info.json > 目录名
    4. 合并 web\authorized.json 中的商业授权软件条目
    5. 重新生成 web\data.js（自动算版本、大小、更新日期）

  结果：添加软件只需 —— 安装包丢进目录（或由自动更新脚本下载）→ 双击 bat。
#>
param(
    [switch]$Quiet   # 由 Update-AllSoftware.ps1 调用时静默执行
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$softDir  = Join-Path $root "web\soft"
$authFile = Join-Path $root "web\authorized.json"
$listFile = Join-Path $PSScriptRoot "软件清单.csv"
$dataFile = Join-Path $root "web\data.js"

if (-not (Test-Path $softDir)) { Write-Host "错误：找不到 $softDir" -ForegroundColor Red; exit 1 }

$EXTS = @(".exe",".msi",".msix",".msixbundle",".zip",".7z")
$CAT_ORDER = @("浏览器","办公套件","压缩工具","PDF 工具","输入法","通讯协作","系统工具","未分类")

function Get-VerFromString([string]$s) {
    if ($s -match '(\d+(\.\d+){1,3})') { return $matches[1] }
    return $null
}

# ---------- 0. 加载软件清单.csv（集中维护的元数据） ----------
$csvMap = @{}
if (Test-Path $listFile) {
    try {
        $rows = Import-Csv -Path $listFile -Encoding UTF8
        foreach ($r in $rows) {
            $key = "$($r.目录)".Trim()
            if ($key) { $csvMap[$key] = $r }
        }
    } catch { Write-Host "警告：软件清单.csv 格式错误，已忽略（$($_.Exception.Message)）" -ForegroundColor Yellow }
} else {
    Write-Host "提示：未找到 scripts\软件清单.csv，元数据将使用目录旁 info.json 或默认值" -ForegroundColor DarkYellow
}

# ---------- 1. 扫描免费软件目录 ----------
$free = New-Object System.Collections.Generic.List[object]

foreach ($dir in (Get-ChildItem $softDir -Directory)) {
    $files = @(Get-ChildItem $dir.FullName -File | Where-Object { $EXTS -contains $_.Extension.ToLower() })
    if ($files.Count -eq 0) { continue }

    # 载入清单行（按目录名匹配）
    $row = $csvMap[$dir.Name]

    # 安装包旁 info.json（备用元数据，优先级低于清单）
    $info = $null
    $infoFile = Join-Path $dir.FullName "info.json"
    if (Test-Path $infoFile) {
        try { $info = Get-Content $infoFile -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { Write-Host "警告：$infoFile 格式错误，已忽略" -ForegroundColor Yellow }
    }

    # 选定安装包：清单/info.json 指定了文件名则精确匹配；
    # 否则取文件名中版本号最高的；都识别不出则取最新修改的
    $wantFile = $null
    if ($row -and $row.文件名) { $wantFile = "$($row.文件名)".Trim() }
    elseif ($info -and $info.file) { $wantFile = $info.file }
    $pkg = $null
    if ($wantFile) {
        $pkg = $files | Where-Object { $_.Name -eq $wantFile } | Select-Object -First 1
        if (-not $pkg) { Write-Host "警告：$($dir.Name) 清单指定文件 $wantFile 不存在，改为自动选择" -ForegroundColor Yellow }
    }
    if (-not $pkg) {
        $pkg = $files | Sort-Object -Descending -Property `
            { $v = Get-VerFromString $_.Name; if ($v) { try { [version]$v } catch { [version]"0.0" } } else { [version]"0.0" } }, `
            { $_.LastWriteTime } | Select-Object -First 1
        if ($files.Count -gt 1) {
            Write-Host "提示：$($dir.Name) 目录有 $($files.Count) 个安装包，已选择 $($pkg.Name)；建议删除旧版本或在清单中指定文件名" -ForegroundColor DarkYellow
        }
    }

    # 元数据：清单 > info.json > 默认
    $name = if ($row -and $row.名称) { "$($row.名称)".Trim() }
            elseif ($info -and $info.name) { $info.name }
            else { (Get-Culture).TextInfo.ToTitleCase($dir.Name) }
    $cat  = if ($row -and $row.分类) { "$($row.分类)".Trim() }
            elseif ($info -and $info.category) { $info.category }
            else { "未分类" }
    $desc = if ($row -and $row.说明) { "$($row.说明)".Trim() }
            elseif ($info -and $info.desc) { $info.desc }
            else { "（说明待补充：编辑 scripts\软件清单.csv 填写说明列）" }
    $ver  = if ($row -and $row.版本) { "$($row.版本)".Trim() } else { $null }
    if (-not $ver -and $info -and $info.version) { $ver = "$($info.version)" }
    if (-not $ver) { $ver = Get-VerFromString $pkg.Name }

    $size = if ($pkg.Length -ge 1GB) { "{0:N1} GB" -f ($pkg.Length/1GB) }
            else { "{0:N1} MB" -f ($pkg.Length/1MB) }

    $free.Add([PSCustomObject][ordered]@{
        name = $name; category = $cat; desc = $desc
        version = "$ver"; size = $size
        date = $pkg.LastWriteTime.ToString("yyyy-MM-dd")
        file = "soft/$($dir.Name)/$($pkg.Name)"
        authorized = $false
    })
}

# 免费软件排序：分类 → 名称
$freeSorted = @($free | Sort-Object -Property `
    { $i = [array]::IndexOf($CAT_ORDER, $_.category); if ($i -lt 0) { 99 } else { $i } }, `
    { $_.name })

# 清单里登记了、但目录里还没有安装包的软件（提示补下载）
$missing = @()
foreach ($key in $csvMap.Keys) {
    if (-not (Test-Path (Join-Path $softDir $key))) {
        $n = if ($csvMap[$key].名称) { $csvMap[$key].名称 } else { $key }
        $missing += $n
    }
}

# ---------- 2. 合并商业授权软件（authorized.json） ----------
$auth = @()
if (Test-Path $authFile) {
    try {
        $authList = Get-Content $authFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($a in $authList) {
            $o = [ordered]@{
                name = $a.name
                category = if ($a.category) { $a.category } else { "商业授权" }
                desc = $a.desc
                version = if ($a.version) { "$($a.version)" } else { "" }
                file = if ($a.file) { $a.file } else { "#" }
                authorized = $true
            }
            if ($a.note) { $o["note"] = $a.note }
            $auth += [PSCustomObject]$o
        }
    } catch { Write-Host "警告：authorized.json 格式错误，已忽略（$($_.Exception.Message)）" -ForegroundColor Yellow }
}

# ---------- 3. 生成 data.js ----------
$all = @($freeSorted) + @($auth)
$json = ConvertTo-Json -InputObject $all -Depth 5

$header = @"
/*
 * 企业软件库数据文件 —— 由 scripts\Build-Catalog.ps1 自动生成，请勿手工编辑！
 *
 * 添加/修改软件：编辑 scripts\软件清单.csv → 双击 scripts\更新软件目录.bat
 * 安装包均手动放置：按清单中的"软件源地址"下载后放入 web\soft\<目录>\
 * 商业授权软件条目：web\authorized.json
 */
"@
Set-Content -Path $dataFile -Value "$header`r`nwindow.SOFTWARE_DATA = $json;" -Encoding UTF8

# ---------- 4. 输出报告 ----------
if (-not $Quiet) {
    Write-Host ""
    Write-Host "===== 编目完成 $(Get-Date -Format 'yyyy-MM-dd HH:mm') =====" -ForegroundColor Cyan
    Write-Host ("已登记免费软件 {0} 个：" -f $freeSorted.Count)
    foreach ($e in $freeSorted) {
        Write-Host ("  {0,-24} v{1,-14} [{2}]" -f $e.name, $e.version, $e.category) -ForegroundColor Green
    }
    Write-Host ("商业授权软件 {0} 个（来自 authorized.json）" -f $auth.Count)
    if ($missing.Count -gt 0) {
        Write-Host ""
        Write-Host "注意：清单中以下软件还没有安装包（目录不存在），请检查：" -ForegroundColor Yellow
        $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    }
    Write-Host ""
    Write-Host "data.js 已重新生成。浏览器 Ctrl+F5 强制刷新即可看到变化。" -ForegroundColor Gray
}
