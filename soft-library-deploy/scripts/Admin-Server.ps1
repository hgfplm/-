<#
.SYNOPSIS
  软件库管理后台：可视界面上传软件安装包并填写信息，自动完成登记与门户刷新
.DESCRIPTION
  双击 启动管理界面.bat 启动本服务，浏览器打开：
    http://<服务器IP>:8080/admin?key=admin123
  （在服务器本机操作可用 http://localhost:8080/admin?key=admin123）

  界面功能（全部自动完成，不再需要手工编辑 CSV / 移动文件）：
    · 上传安装包：选文件 + 填名称/分类/说明 → 保存到 web\soft\ → 写入软件清单.csv → 门户立即刷新
    · 查看清单：哪些软件已有安装包、哪些缺失
    · 删除软件：安装包移入 deleted-soft\ 备份目录（不直接删除），清单同步移除

  注意：
    · 对局域网监听需要以管理员身份运行（bat 上右键"以管理员身份运行"）
    · 端口只应对 IT 部门开放（防火墙限制来源 IP）
    · 首次使用请修改下方 $Key 默认值
#>
param(
    [int]$Port = 8080,
    [string]$Key = "admin123"   # ← 访问密钥，务必修改
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
$softDir   = Join-Path $root "web\soft"
$delDir    = Join-Path $root "deleted-soft"
$csvFile   = Join-Path $PSScriptRoot "软件清单.csv"
$build     = Join-Path $PSScriptRoot "Build-Catalog.ps1"
$adminHtml = Join-Path $PSScriptRoot "admin.html"
$logFile   = Join-Path $root "download-log.csv"   # 员工下载记录（时间/IP/软件/文件）
$ALLOW_EXT = @(".exe",".msi",".msix",".msixbundle",".zip",".7z")

if (-not (Test-Path $softDir)) { Write-Host "错误：找不到 $softDir" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $build))   { Write-Host "错误：找不到 $build" -ForegroundColor Red; exit 1 }

# ---------- 工具函数 ----------
function Read-CsvRows {
    if (Test-Path $csvFile) { return @(Import-Csv -Path $csvFile -Encoding UTF8) } else { return @() }
}
function Write-CsvRows($rows) {
    $rows | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
}
function Upsert-Row([string]$dir,[string]$name,[string]$cat,[string]$desc,[string]$ver,[string]$file,[string]$src) {
    $rows = Read-CsvRows
    $newRow = [PSCustomObject]@{ 目录=$dir; 名称=$name; 分类=$cat; 说明=$desc; 版本=$ver; 文件名=$file; "软件源地址"=$src }
    $rows = @($rows | Where-Object { "$($_.目录)".Trim() -ne $dir })
    Write-CsvRows ($rows + $newRow)
}
function Remove-Row([string]$dir) {
    $rows = Read-CsvRows
    Write-CsvRows @($rows | Where-Object { "$($_.目录)".Trim() -ne $dir })
}
function Test-DirName([string]$dir) {
    # 只允许字母数字下划线横线，防止路径穿越
    return ($dir -match '^[A-Za-z0-9_\-]{1,40}$')
}
function Parse-Multipart($stream, [string]$contentType) {
    # 解析 multipart/form-data 请求体，返回 @{ fields=@{}; file=$null; fileBytes=$null }
    $result = @{ fields = @{}; file = $null; fileBytes = $null }
    if (-not $contentType -or $contentType -notmatch 'boundary=(.+)$') { return $result }
    $boundary = "--" + $matches[1].Trim('"')
    $ms = New-Object System.IO.MemoryStream
    $stream.CopyTo($ms)
    $body = $ms.ToArray()
    $ms.Close()
    $utf8 = [Text.Encoding]::UTF8
    $sep = $utf8.GetBytes($boundary)
    if ($body.Length -eq 0 -or $sep.Length -eq 0) { return $result }
    # boundary 定位：.NET IndexOf 找首字节候选再核对（大文件性能关键）
    $positions = New-Object System.Collections.Generic.List[int]
    $first = $sep[0]
    $i = [Array]::IndexOf($body, $first, 0)
    while ($i -ge 0) {
        if ($i -le $body.Length - $sep.Length) {
            $match = $true
            for ($j = 1; $j -lt $sep.Length; $j++) { if ($body[$i + $j] -ne $sep[$j]) { $match = $false; break } }
            if ($match) { $positions.Add($i); $i += $sep.Length - 1 }
        }
        $i = [Array]::IndexOf($body, $first, $i + 1)
    }
    for ($k = 0; $k -lt $positions.Count - 1; $k++) {
        $start = $positions[$k] + $sep.Length
        $end = $positions[$k + 1]
        if ($end -le $start) { continue }
        if ($body[$start] -eq 13 -and $body[$start + 1] -eq 10) { $start += 2 }
        if ($end -ge 2 -and $body[$end - 2] -eq 13 -and $body[$end - 1] -eq 10) { $end -= 2 }
        if ($end -le $start) { continue }
        $segLen = $end - $start
        $hdrEnd = -1
        $maxHdr = [Math]::Min($segLen - 4, 2048)
        $j = 0
        while ($j -lt $maxHdr) {
            if ($body[$start + $j] -eq 13 -and $body[$start + $j + 1] -eq 10 -and $body[$start + $j + 2] -eq 13 -and $body[$start + $j + 3] -eq 10) { $hdrEnd = $j; break }
            $j++
        }
        if ($hdrEnd -lt 0) { continue }
        $headers = $utf8.GetString($body, $start, $hdrEnd)
        $contentStart = $start + $hdrEnd + 4
        $contentLen = $end - $contentStart
        if ($contentLen -lt 0) { continue }
        if ($headers -match 'name="([^"]+)"') {
            $fname = $matches[1]
            if ($headers -match 'filename="([^"]*)"') {
                if ($matches[1]) {
                    $result.file = $matches[1]
                    $fb = New-Object byte[] $contentLen
                    [Array]::Copy($body, $contentStart, $fb, 0, $contentLen)
                    $result.fileBytes = $fb
                }
            } else {
                $val = $utf8.GetString($body, $contentStart, $contentLen)
                if ($val -match ([string][char]0xFFFD)) {
                    # 兼容 GBK 调用方（curl/脚本）：UTF-8 解码出现替换符时按 ANSI 重解
                    $ansi = [Text.Encoding]::GetEncoding([Text.Encoding]::Default.CodePage)
                    $ansiVal = $ansi.GetString($body, $contentStart, $contentLen)
                    if ($ansiVal -notmatch ([string][char]0xFFFD)) { $val = $ansiVal }
                }
                $result.fields[$fname] = $val
            }
        }
    }
    return $result
}
function Send-Json($res, $obj, [int]$code = 200) {
    # CORS：门户(:80)与管理后台(:8080)端口不同属跨域，统计接口需允许
    $res.Headers.Add("Access-Control-Allow-Origin", "*")
    $json = ConvertTo-Json -InputObject $obj -Depth 6 -Compress
    $buf = [Text.Encoding]::UTF8.GetBytes($json)
    $res.StatusCode = $code
    $res.ContentType = "application/json; charset=utf-8"
    $res.ContentLength64 = $buf.Length
    $res.OutputStream.Write($buf, 0, $buf.Length)
}
function Send-File($res, [string]$path, [string]$mime) {
    $buf = [IO.File]::ReadAllBytes($path)
    $res.StatusCode = 200
    $res.ContentType = $mime
    $res.ContentLength64 = $buf.Length
    $res.OutputStream.Write($buf, 0, $buf.Length)
}

# ---------- 启动监听 ----------
$listener = New-Object System.Net.HttpListener
try {
    $listener.Prefixes.Add("http://*:$Port/")
    $listener.Start()
} catch {
    Write-Host "提示：监听所有网卡需要管理员权限，已降级为仅本机访问（localhost）" -ForegroundColor Yellow
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.Start()
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " 软件库管理后台已启动" -ForegroundColor Cyan
Write-Host " 浏览器打开：http://localhost:$Port/admin?key=$Key" -ForegroundColor Cyan
Write-Host " 其他机器访问：把 localhost 换成服务器 IP" -ForegroundColor Cyan
Write-Host " 关闭本窗口即停止服务" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ---------- 主循环 ----------
while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $res = $ctx.Response
    try {
        $path = $req.Url.AbsolutePath.TrimEnd('/')
        $keyOk = ($req.QueryString["key"] -eq $Key)

        # 跨域预检请求（门户页面跨端口调用统计/上报接口时浏览器可能发起）
        if ($req.HttpMethod -eq "OPTIONS") {
            $res.Headers.Add("Access-Control-Allow-Origin", "*")
            $res.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            $res.Headers.Add("Access-Control-Allow-Headers", "Content-Type")
            $res.StatusCode = 204
            $res.OutputStream.Close()
            continue
        }

        if ($path -eq "/admin" -or $path -eq "/admin.html") {
            Send-File $res $adminHtml "text/html; charset=utf-8"
        }
        elseif ($path -eq "/api/state") {
            if (-not $keyOk) { Send-Json $res @{ ok=$false; msg="密钥错误" } 403; continue }
            $rows = Read-CsvRows

            # 聚合下载量：从 download-log.csv 按软件名统计（同时输出总计）
            $dlCount = @{}
            if (Test-Path $logFile) {
                $dlRows = @(Import-Csv -Path $logFile -Encoding UTF8)
                foreach ($l in $dlRows) {
                    $n = "$($l.软件)".Trim()
                    if ($n) { $dlCount[$n] = 1 + $(if ($dlCount.ContainsKey($n)) { $dlCount[$n] } else { 0 }) }
                }
            }

            $list = @()
            foreach ($r in $rows) {
                $dir = "$($r.目录)".Trim()
                $d = Join-Path $softDir $dir
                $files = @()
                if (Test-Path $d) { $files = @(Get-ChildItem $d -File | Where-Object { $ALLOW_EXT -contains $_.Extension.ToLower() } | ForEach-Object { $_.Name }) }
                $n2 = "$($r.名称)".Trim()
                $list += [PSCustomObject]@{
                    dir = $dir; name = $n2; cat = "$($r.分类)"; desc = "$($r.说明)"
                    ver = "$($r.版本)"; file = "$($r.文件名)"; src = "$($r.软件源地址)"
                    hasPkg = ($files.Count -gt 0); pkgFiles = $files
                    dl = $(if ($dlCount.ContainsKey($n2)) { $dlCount[$n2] } else { 0 })
                }
            }
            $totalDl = 0; foreach ($v in $dlCount.Values) { $totalDl += $v }
            Send-Json $res @{ ok=$true; rows=$list; totalDl=$totalDl }
        }
        elseif ($path -eq "/api/upload" -and $req.HttpMethod -eq "POST") {
            if (-not $keyOk) { Send-Json $res @{ ok=$false; msg="密钥错误" } 403; continue }

            # ---------- 解析 multipart/form-data（表单字段 + 文件） ----------
            $mp = Parse-Multipart $req.InputStream $req.ContentType
            $fields   = $mp.fields
            $file     = $mp.file
            $fileBytes = $mp.fileBytes

            # 旧版前端兼容：若不是 multipart 请求，但 URL 带 file 参数，
            # 则请求体就是原始文件内容（旧版页面把文件作为请求体直接发送）
            if (-not $fileBytes -and $req.QueryString["file"]) {
                $ms2 = New-Object System.IO.MemoryStream
                $req.InputStream.CopyTo($ms2)
                $fileBytes = $ms2.ToArray()
                $ms2.Close()
                $file = "$($req.QueryString["file"])"
            }

            # 读取字段：multipart 表单体优先，缺失时回退 URL 参数（兼容新旧前端）；
            # 一律 Trim 去掉首尾空白
            $dir  = "$($fields["dir"])".Trim();   if (-not $dir)  { $dir  = "$($req.QueryString["dir"])".Trim() }
            $name = "$($fields["name"])".Trim();  if (-not $name) { $name = "$($req.QueryString["name"])".Trim() }
            $cat  = "$($fields["cat"])".Trim();   if (-not $cat)  { $cat  = "$($req.QueryString["cat"])".Trim() }
            $desc = "$($fields["desc"])".Trim();  if (-not $desc) { $desc = "$($req.QueryString["desc"])".Trim() }
            $ver  = "$($fields["ver"])".Trim();   if (-not $ver)  { $ver  = "$($req.QueryString["ver"])".Trim() }
            $src  = "$($fields["src"])".Trim();   if (-not $src)  { $src  = "$($req.QueryString["src"])".Trim() }

            if (-not $dir) { Send-Json $res @{ ok=$false; msg="未收到目录名，请刷新管理页面（Ctrl+F5）后重试；若仍失败请确认服务器上 Admin-Server.ps1 与 admin.html 已同时更新" } 400; continue }
            if (-not (Test-DirName $dir)) { Send-Json $res @{ ok=$false; msg="目录名「$dir」含非法字符，只能用字母/数字/横线/下划线" } 400; continue }
            if (-not $name)   { Send-Json $res @{ ok=$false; msg="请填写软件名称" } 400; continue }
            if (-not $file -or -not $fileBytes) { Send-Json $res @{ ok=$false; msg="未收到文件内容" } 400; continue }
            $ext = [IO.Path]::GetExtension($file).ToLower()
            if ($ALLOW_EXT -notcontains $ext) { Send-Json $res @{ ok=$false; msg="不支持的文件类型 $ext（允许：exe/msi/zip/7z）" } 400; continue }

            # 保存上传的原始文件体
            $targetDir = Join-Path $softDir $dir
            New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
            $destFile = Join-Path $targetDir $file
            [IO.File]::WriteAllBytes($destFile, $fileBytes)
            $saved = (Get-Item $destFile).Length

            # 写入清单 + 刷新门户
            Upsert-Row $dir $name $cat $desc $ver $file $src
            & $build -Quiet 2>$null

            Send-Json $res @{ ok=$true; msg="已保存 $file（{0:N1} MB），门户已刷新" -f ($saved/1MB) }
        }
        elseif ($path -eq "/api/edit" -and ($req.HttpMethod -eq "POST" -or $req.HttpMethod -eq "GET")) {
            if (-not $keyOk) { Send-Json $res @{ ok=$false; msg="密钥错误" } 403; continue }

            # 中文参数优先从 multipart 表单体读取（避免 URL 编码问题）；回退 URL 参数
            $emp = Parse-Multipart $req.InputStream $req.ContentType
            $efields = $emp.fields
            $dir  = "$($efields["dir"])".Trim();   if (-not $dir)  { $dir  = "$($req.QueryString["dir"])".Trim() }
            $name = "$($efields["name"])".Trim();  if (-not $name) { $name = "$($req.QueryString["name"])".Trim() }
            $cat  = "$($efields["cat"])".Trim();   if (-not $cat)  { $cat  = "$($req.QueryString["cat"])".Trim() }
            $desc = "$($efields["desc"])".Trim();  if (-not $desc) { $desc = "$($req.QueryString["desc"])".Trim() }
            $ver  = "$($efields["ver"])".Trim();   if (-not $ver)  { $ver  = "$($req.QueryString["ver"])".Trim() }
            $src  = "$($efields["src"])".Trim();   if (-not $src)  { $src  = "$($req.QueryString["src"])".Trim() }

            if (-not (Test-DirName $dir)) { Send-Json $res @{ ok=$false; msg="目录名不合法" } 400; continue }
            if (-not $name) { Send-Json $res @{ ok=$false; msg="软件名称不能为空" } 400; continue }

            # 读取现有行，编辑只允许改元数据；版本/文件名/软件源缺省保持原值
            $rows = Read-CsvRows
            $row = $rows | Where-Object { "$($_.目录)".Trim() -eq $dir } | Select-Object -First 1
            if (-not $row) { Send-Json $res @{ ok=$false; msg="清单中不存在目录 $dir" } 404; continue }

            $newRow = [PSCustomObject]@{
                目录 = $dir
                名称 = $name
                分类 = $cat
                说明 = $desc
                版本 = if ($ver) { $ver } else { "$($row.版本)" }
                文件名 = "$($row.文件名)"
                "软件源地址" = if ($src) { $src } else { "$($row.软件源地址)" }
            }
            $rows = @($rows | Where-Object { "$($_.目录)".Trim() -ne $dir })
            Write-CsvRows ($rows + $newRow)
            & $build -Quiet 2>$null
            Send-Json $res @{ ok=$true; msg="已更新「$name」的信息，门户已刷新" }
        }
        elseif ($path -eq "/api/dlstats") {
            # 门户热度展示用：只读统计（软件名→下载次数），不含 IP 等明细，无需密钥
            $dlCount2 = @{}
            if (Test-Path $logFile) {
                $dlRows2 = @(Import-Csv -Path $logFile -Encoding UTF8)
                foreach ($l in $dlRows2) {
                    $n = "$($l.软件)".Trim()
                    if ($n) { $dlCount2[$n] = 1 + $(if ($dlCount2.ContainsKey($n)) { $dlCount2[$n] } else { 0 }) }
                }
            }
            Send-Json $res @{ ok=$true; stats=$dlCount2 }
        }
        elseif ($path -eq "/api/log") {
            # 员工下载行为上报接口：无需密钥（来自全员浏览器），仅接受内网来源，
            # 只追加一行 CSV，无任何读/写敏感数据的副作用
            $ip = $req.RemoteEndPoint.Address.IPAddressToString
            $isPrivate = ($ip -match '^10\.') -or ($ip -match '^192\.168\.') -or
                         ($ip -match '^172\.(1[6-9]|2\d|3[01])\.') -or ($ip -eq "127.0.0.1") -or ($ip -eq "::1")
            if (-not $isPrivate) { $res.StatusCode = 403; $res.OutputStream.Close(); continue }

            # 中文参数从 multipart 表单体读取（URL 中文会被错误解码）；ASCII 回退 URL
            $lmp = Parse-Multipart $req.InputStream $req.ContentType
            $lname = "$($lmp.fields["name"])".Trim()
            $lfile = "$($lmp.fields["file"])".Trim()
            if (-not $lname) { $lname = "$($req.QueryString["name"])".Trim() }
            if (-not $lfile) { $lfile = "$($req.QueryString["file"])".Trim() }
            if (-not $lname) { $res.StatusCode = 400; $res.OutputStream.Close(); continue }

            $entry = [PSCustomObject]@{
                时间 = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                IP   = $ip
                软件 = $lname
                文件 = $lfile
            }
            # 追加写入（首行带表头）
            if (-not (Test-Path $logFile)) {
                @($entry) | Export-Csv -Path $logFile -NoTypeInformation -Encoding UTF8
            } else {
                @($entry) | Export-Csv -Path $logFile -NoTypeInformation -Encoding UTF8 -Append
            }
            # sendBeacon/Image 上报只需空响应（CORS：允许门户跨端口上报）
            $res.Headers.Add("Access-Control-Allow-Origin", "*")
            $res.StatusCode = 204
            $res.OutputStream.Close()
            continue
        }
        elseif ($path -eq "/api/logs") {
            # 下载记录查询（需密钥）：默认返回最近 500 条，倒序
            if (-not $keyOk) { Send-Json $res @{ ok=$false; msg="密钥错误" } 403; continue }
            $logs = @()
            if (Test-Path $logFile) {
                $logs = @(Import-Csv -Path $logFile -Encoding UTF8)
                $kw = "$($req.QueryString["q"])".Trim()
                if ($kw) { $logs = @($logs | Where-Object { ("$($_.IP)$($_.软件)$($_.文件)") -like "*$kw*" }) }
                $logs = @($logs | Sort-Object { [datetime]$_.时间 } -Descending | Select-Object -First 500)
            }
            $rows2 = @($logs | ForEach-Object {
                [PSCustomObject]@{ t = "$($_.时间)"; ip = "$($_.IP)"; name = "$($_.软件)"; file = "$($_.文件)" }
            })
            if ($rows2.Count -eq 0) { $rows2 = @() }
            Send-Json $res @{ ok=$true; rows=$rows2; total=$rows2.Count }
        }
        elseif ($path -eq "/api/delete" -and ($req.HttpMethod -eq "POST" -or $req.HttpMethod -eq "GET")) {
            if (-not $keyOk) { Send-Json $res @{ ok=$false; msg="密钥错误" } 403; continue }
            $dir = $req.QueryString["dir"]
            if (-not (Test-DirName $dir)) { Send-Json $res @{ ok=$false; msg="目录名不合法" } 400; continue }

            $d = Join-Path $softDir $dir
            if (Test-Path $d) {
                New-Item -ItemType Directory -Force -Path $delDir | Out-Null
                $backup = Join-Path $delDir ("{0}-{1}" -f $dir, (Get-Date -Format "yyyyMMddHHmmss"))
                Move-Item $d $backup   # 备份，不直接删除
            }
            Remove-Row $dir
            & $build -Quiet 2>$null
            Send-Json $res @{ ok=$true; msg="已下架 $dir（安装包移入 deleted-soft\ 备份）" }
        }
        else {
            $res.StatusCode = 404
            $buf = [Text.Encoding]::UTF8.GetBytes("404")
            $res.OutputStream.Write($buf, 0, $buf.Length)
        }
    } catch {
        try {
            Send-Json $res @{ ok=$false; msg="服务器错误：$($_.Exception.Message)" } 500
        } catch {}
    } finally {
        try { $res.OutputStream.Close() } catch {}
    }
}
