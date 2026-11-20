<#
.SYNOPSIS
    Daily report: Jira task chuyển sang Closed/Resolved/Done + GitLab MR đã merge, post vào Teams.

.DESCRIPTION
    Mỗi lần chạy báo cáo cho một project (-Project <KEY>): cấu hình = .env chung (Jira, GitLab, chat test)
    rồi projects\<KEY>.env ghi đè (Jira project, board, repo GitLab, webhook group). State lưu ở state\<KEY>.json,
    log và payload ở logs\<KEY>\.
    Khoảng thời gian báo cáo = [lần gửi thành công trước, 00:00 hôm nay).
    Lần đầu (chưa có state\<KEY>.json): thứ 2 lấy từ thứ 6, các ngày khác lấy hôm qua.
    Nhờ vậy nếu máy tắt một hôm, lần chạy sau tự gộp luôn những ngày bị lỡ.
    Mỗi lần gửi group thành công, số liệu được lưu vào state\<KEY>.json (history) để tính xu hướng,
    sparkline và tổng kết tuần (thứ 6).
    Khi chạy bị lỗi, card cảnh báo chỉ gửi tới TEAMS_TEST_WEBHOOK_URL (chat test), không bao giờ gửi lên group.
    Card vượt $MaxPayloadBytes (~20KB) thì được tách thành nhiều tin nhắn liên tiếp, giữ đủ mọi dòng.
    Card tổng kết sprint: sprint (active/closed, thuộc scrum board của project) có thời điểm kết thúc
    (sớm hơn giữa completeDate và endDate) nằm trong khoảng báo cáo thì được gửi ngay sau card daily.
    Mỗi sprint chỉ gửi group một lần (state\<KEY>.json: sprintsReported). Bước sprint lỗi sau khi daily đã gửi thì
    lần chạy sau tìm sprint từ mốc sprintCheckedUntil (tối đa 14 ngày) nên card sprint không bị mất.

.PARAMETER Project
    Mã project (bắt buộc), vd DG: đọc cấu hình riêng từ projects\<KEY>.env. File đó không có JIRA_PROJECT
    thì JIRA_PROJECT = <KEY>. Card báo lỗi (gửi chat test chung) có tiền tố [<KEY>].

.PARAMETER DryRun
    Chỉ in ra màn hình + ghi logs\<KEY>\last-payload.json (và last-payload-2.json, ... khi card bị tách),
    logs\<KEY>\card-for-designer.json (card sprint: sprint-<id>-payload*.json, sprint-<id>-card-for-designer.json),
    không post Teams, không cập nhật state\<KEY>.json. Card sprint luôn được in, kể cả sprint đã gửi group rồi.

.PARAMETER Test
    Gửi tới TEAMS_TEST_WEBHOOK_URL (chat riêng) thay vì group. Không cập nhật state\<KEY>.json,
    không chặn "hôm nay đã gửi rồi", card sprint luôn được gửi kể cả sprint đã gửi group rồi.

.PARAMETER From
    Ngày bắt đầu (yyyy-MM-dd), ghi đè cách tính tự động.

.PARAMETER To
    Ngày kết thúc, không tính ngày này (yyyy-MM-dd). Mặc định hôm nay. Lời chào / tổng kết tuần
    tính theo ngày này (ngày gửi báo cáo).
    -From/-To gửi group thì không gửi card sprint; kèm -DryRun / -Test thì vẫn xem thử card sprint của khoảng đó.

.PARAMETER Force
    Gửi lại daily kể cả khi hôm nay đã gửi rồi (card sprint đã gửi group thì vẫn không gửi lại).
    Kèm -SprintId: gửi lại card của sprint đó kể cả khi đã gửi group rồi.

.PARAMETER SprintId
    Chỉ gửi card tổng kết của sprint này (id sprint Jira, vd 1884), bỏ qua daily report.
    Dùng được với -DryRun / -Test; gửi group thì ghi id vào state\<KEY>.json (sprintsReported),
    sprint đã gửi group rồi thì bỏ qua (thêm -Force để gửi lại).

.EXAMPLE
    .\daily-report.ps1 -Project DG -DryRun
    .\daily-report.ps1 -Project DG -Test
    .\daily-report.ps1 -Project DG -From 2026-10-27 -To 2026-11-03 -DryRun
    .\daily-report.ps1 -Project DG -From 2026-11-16 -To 2026-11-17 -DryRun    # xem trước daily + card sprint của sáng mai
    .\daily-report.ps1 -Project DG -SprintId 1884 -DryRun
    .\daily-report.ps1 -Project DG -SprintId 1895 -Test
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$Project,
    [switch]$DryRun,
    [switch]$Test,
    [string]$From,
    [string]$To,
    [switch]$Force,
    [ValidateRange(1, 2147483647)]
    [int]$SprintId
)
# Chuẩn hoá mã project: -Project dg và -Project DG cho cùng tiêu đề card / mã Jira mặc định.
$Project = $Project.ToUpperInvariant()

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root = $PSScriptRoot
# Cấu hình 2 lớp: .env chung (Jira, GitLab, chat test) rồi projects\<KEY>.env ghi đè phần riêng của project.
$sharedEnvPath = Join-Path $root '.env'
$projectDir = Join-Path $root 'projects'
$projectEnvPath = Join-Path $projectDir "$Project.env"
# Mỗi project một state và một thư mục log riêng, để các project không đè dữ liệu của nhau.
$logDir = Join-Path (Join-Path $root 'logs') $Project
$stateDir = Join-Path $root 'state'
$statePath = Join-Path $stateDir "$Project.json"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$logPath = Join-Path $logDir ((Get-Date).ToString('yyyy-MM-dd') + '.log')
Start-Transcript -Path $logPath -Append | Out-Null

# Kích thước payload tối đa cho một tin nhắn. Thực tế: card ≤ 15,9KB đến nơi, card 25,7KB bị Teams lặng lẽ bỏ
# (webhook Workflow vẫn trả 202). Vượt ngưỡng thì card được tách thành nhiều tin nhắn liên tiếp.
$MaxPayloadBytes = 20000
# Chờ giữa các tin nhắn khi card bị tách: các lần chạy Power Automate có thể chạy song song, chờ để giữ đúng thứ tự trong chat.
$PartDelaySeconds = 5
# Card báo lỗi: cắt bớt nội dung lỗi dài (vd trang HTML 502) để card không vượt giới hạn của Teams.
$MaxErrorTextChars = 2000
# Card báo lỗi: số dòng stack trace hiển thị (dòng đầu là nơi throw, các dòng sau là nơi gọi).
$MaxErrorStackLines = 3
# Thời gian chờ tối đa mỗi lệnh glab; phải nhỏ hơn nhiều so với ExecutionTimeLimit của Task Scheduler (10 phút)
# để catch còn kịp chạy và gửi cảnh báo.
$GlabTimeoutMs = 120000
# Số id sprint đã gửi card tổng kết được giữ trong state\<KEY>.json (sprintsReported); đủ dài để không bao giờ gửi lại sprint cũ.
$MaxReportedSprints = 50
# Bước sprint lỗi thì lần sau tìm sprint từ sprintCheckedUntil, nhưng không lùi quá số ngày này (giống giới hạn gộp ngày của daily).
$SprintCatchUpDays = 14
# Card sprint: số dòng task tối đa mỗi TextBlock; người có nhiều task hơn được chia thành nhiều Container
# để không block nào vượt $MaxPayloadBytes (Split-Card chỉ chuyển nguyên block, không chia được TextBlock).
$MaxBulletLinesPerBlock = 40
# Các trường của state\<KEY>.json; mang đủ trong bộ nhớ để lần ghi nào cũng không làm mất trường khác.
$StateKeys = @('lastEnd', 'sentAt', 'history', 'sprintsReported', 'sprintCheckedUntil')
# Key riêng của project: chỉ được nằm trong projects\<KEY>.env. Có trong .env chung thì throw, để project này không
# lặng lẽ kế thừa webhook / repo / board của project khác (gửi nhầm channel). JIRA_DONE_STATUSES được phép làm mặc định chung.
$ProjectOnlyKeys = @('JIRA_PROJECT', 'JIRA_BOARD_ID', 'GITLAB_PROJECTS', 'TEAMS_WEBHOOK_URL')

$utf8 = New-Object Text.UTF8Encoding $false
# Truyền -SprintId: chỉ gửi card tổng kết của sprint đó, bỏ qua daily.
$sprintOnly = $PSBoundParameters.ContainsKey('SprintId')

function Read-DotEnv([string]$path) {
    $cfg = @{}
    if (-not (Test-Path -LiteralPath $path)) { throw "Không thấy file cấu hình: $path" }
    foreach ($raw in Get-Content -LiteralPath $path -Encoding UTF8) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#') -or -not $line.Contains('=')) { continue }
        $i = $line.IndexOf('=')
        $cfg[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim().Trim('"')
    }
    return $cfg
}

# Không truyền $default thì key là bắt buộc. Không dùng "$null -ne $default": tham số [string] luôn bị ép $null thành ''.
function Get-Setting([hashtable]$cfg, [string]$key, [string]$default) {
    $v = $cfg[$key]
    if ([string]::IsNullOrWhiteSpace($v)) {
        if ($PSBoundParameters.ContainsKey('default')) { return $default }
        throw "Thiếu $key trong .env / projects\$Project.env"
    }
    return $v
}

# Đọc .env chung trước, rồi projects\<KEY>.env ghi đè (key nào cũng ghi đè được).
# Key trong $ProjectOnlyKeys chỉ lấy từ file project. File project không có JIRA_PROJECT thì JIRA_PROJECT = <KEY>.
function Read-ProjectConfig {
    if (-not (Test-Path -LiteralPath $projectEnvPath)) {
        $available = @(Get-ChildItem -LiteralPath $projectDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '.env' } | ForEach-Object { $_.BaseName } | Sort-Object)
        $availableText = if ($available.Count -gt 0) { $available -join ', ' } else { '(chưa có project nào)' }
        throw "Không thấy file cấu hình của project '$Project': $projectEnvPath. Project có sẵn trong projects\*.env: $availableText"
    }
    $merged = Read-DotEnv $sharedEnvPath
    $leaked = @($ProjectOnlyKeys | Where-Object { $merged.ContainsKey($_) })
    if ($leaked.Count -gt 0) {
        throw ".env chung đang chứa key riêng của project: $($leaked -join ', '). Chuyển sang projects\<KEY>.env rồi xoá khỏi .env."
    }
    $projectCfg = Read-DotEnv $projectEnvPath
    $required = @('GITLAB_PROJECTS')
    if (Test-GroupSend) { $required += 'TEAMS_WEBHOOK_URL' }
    $missing = @($required | Where-Object { [string]::IsNullOrWhiteSpace($projectCfg[$_]) })
    if ($missing.Count -gt 0) { throw "Thiếu $($missing -join ', ') trong $projectEnvPath (key riêng của project, không lấy từ .env chung)." }
    foreach ($k in $projectCfg.Keys) { $merged[$k] = $projectCfg[$k] }
    if ([string]::IsNullOrWhiteSpace($projectCfg['JIRA_PROJECT'])) { $merged['JIRA_PROJECT'] = $Project }
    return $merged
}

# Quote một tham số theo quy tắc CommandLineToArgvW: nhân đôi backslash đứng trước dấu " hoặc cuối chuỗi, escape dấu ".
function ConvertTo-ProcessArgument([string]$arg) {
    $escaped = ($arg -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

# Chạy glab và trả về stdout. Không dùng "& glab ... 2>&1": với ErrorActionPreference=Stop, PS 5.1 biến mọi dòng stderr
# (vd thông báo "Update available" của glab dù exit code 0) thành lỗi dừng script trước khi kịp xem $LASTEXITCODE.
# $token không rỗng thì truyền qua biến môi trường GITLAB_TOKEN của riêng process con (glab ưu tiên nó hơn token đã lưu).
# Kèm GITLAB_HOST = $gitlabHost: glab chỉ gửi GITLAB_TOKEN tới host mặc định, host chưa auth login thì bị bỏ qua (404).
function Invoke-Glab([string]$exe, [string[]]$arguments, [string]$context, [int]$timeoutMs, [string]$token = '', [string]$gitlabHost = '') {
    $verb = if ($arguments.Count -gt 0) { $arguments[0] } else { '' }
    $utf8NoBom = New-Object Text.UTF8Encoding $false
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = (@($arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8NoBom
    $psi.StandardErrorEncoding = $utf8NoBom
    if ($token) {
        $psi.EnvironmentVariables['GITLAB_TOKEN'] = $token
        if ($gitlabHost) { $psi.EnvironmentVariables['GITLAB_HOST'] = $gitlabHost }
    }

    $proc = [Diagnostics.Process]::Start($psi)
    try {
        # Đọc cả hai stream bất đồng bộ: tránh deadlock khi một pipe đầy, và cho phép chờ có giới hạn thời gian.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($timeoutMs)) {
            # Kill có thể lỗi nếu process vừa tự thoát giữa lúc hết giờ và lúc kill; khi đó không còn gì để dọn.
            try { $proc.Kill() } catch { Write-Host "Không kill được glab ($context): $($_.Exception.Message)" }
            throw "glab $verb treo quá $([int]($timeoutMs / 1000))s ($context)"
        }
        # Gọi lại bản không tham số để chắc chắn process đã thoát hẳn và stream đã đọc xong.
        $proc.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
        $exitCode = $proc.ExitCode
    } finally {
        $proc.Dispose()
    }

    if ($exitCode -ne 0) {
        $detail = if ($stderr) { $stderr } else { $stdout.Trim() }
        throw "glab $verb lỗi ($context): exit code $exitCode — $detail"
    }
    if ($stderr) { Write-Host "Bỏ qua stderr của glab $verb ($context), exit code 0: $stderr" }
    return $stdout
}

function New-TeamsPayload($card) {
    return @{
        type        = 'message'
        attachments = @(@{
            contentType = 'application/vnd.microsoft.card.adaptive'
            contentUrl  = $null
            content     = $card
        })
    }
}

# Số byte UTF-8 của JSON nén, đúng cách Send-Teams serialize.
function Get-JsonBytes($obj) {
    return [Text.Encoding]::UTF8.GetByteCount(($obj | ConvertTo-Json -Depth 30 -Compress))
}

function Get-PayloadBytes($card) {
    return (Get-JsonBytes (New-TeamsPayload $card))
}

function New-AdaptiveCard([object[]]$body) {
    return @{
        '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
        type      = 'AdaptiveCard'
        version   = '1.4'
        msteams   = @{ width = 'Full' }
        body      = @($body)
    }
}

function Send-Teams([string]$url, $card) {
    $json = (New-TeamsPayload $card) | ConvertTo-Json -Depth 30 -Compress
    Invoke-RestMethod -Method Post -Uri $url -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($json)) | Out-Null
}

function New-Text([string]$text, [hashtable]$extra = @{}) {
    $block = @{ type = 'TextBlock'; text = $text; wrap = $true }
    foreach ($k in $extra.Keys) { $block[$k] = $extra[$k] }
    return $block
}

function Escape-Md([string]$s) {
    if ($null -eq $s) { return '' }
    # Teams không hỗ trợ escape bằng "\", chỉ chặn trường hợp tiêu đề vô tình thành link markdown.
    return ($s -replace '\]\(', '] (')
}

# In card ra console (DryRun): bỏ URL của link markdown, ColumnSet in theo hàng.
function Get-CardLines($el, [string]$indent = '') {
    switch ($el.type) {
        'TextBlock' {
            if ($el.text -and $el.text.Trim()) {
                foreach ($l in ($el.text -split "`r?`n")) { $indent + ($l -replace '\[([^\]]+)\]\([^)]+\)', '$1') }
            }
        }
        'FactSet' { foreach ($f in $el.facts) { "$indent$($f.title): $($f.value)" } }
        'Container' { foreach ($i in $el.items) { Get-CardLines $i $indent } }
        'ColumnSet' {
            $cols = @(foreach ($c in $el.columns) { , @(foreach ($i in $c.items) { Get-CardLines $i '' }) })
            $counts = @($cols | ForEach-Object { $_.Count } | Select-Object -Unique)
            if ($counts.Count -eq 1) {
                for ($r = 0; $r -lt $counts[0]; $r++) { $indent + (@($cols | ForEach-Object { $_[$r] }) -join '  |  ') }
            } else {
                $indent + (@($cols | Where-Object { $_.Count -gt 0 } | ForEach-Object { $_[0] }) -join '  |  ')
                foreach ($c in $cols) { foreach ($l in ($c | Select-Object -Skip 1)) { "$indent      $l" } }
            }
        }
    }
}

function Get-Pct([int]$part, [int]$total) {
    if ($total -le 0) { return $null }
    return [int][math]::Round(100 * $part / $total)
}

# Tên ngắn: "Công. Nguyễn Quốc" -> "Công"; trùng tên gọi thì nơi gọi tự giữ tên đầy đủ.
function Get-GivenName([string]$full) {
    if ([string]::IsNullOrWhiteSpace($full)) { return '' }
    $i = $full.IndexOf('.')
    if ($i -gt 0) { return $full.Substring(0, $i).Trim() }
    return $full.Trim()
}

function New-Delta($d, [string]$suffix = '') {
    if ($d -gt 0) { return (New-Text "▲ $d$suffix" @{ size = 'Small'; color = 'Good'; horizontalAlignment = 'Center'; spacing = 'None' }) }
    if ($d -lt 0) { return (New-Text "▼ $(-$d)$suffix" @{ size = 'Small'; color = 'Attention'; horizontalAlignment = 'Center'; spacing = 'None' }) }
    return (New-Text '=' @{ size = 'Small'; isSubtle = $true; horizontalAlignment = 'Center'; spacing = 'None' })
}

function New-Kpi([string]$value, [string]$label, [string]$color, $delta, [bool]$showDelta, [string]$suffix = '') {
    $items = @(
        (New-Text $value @{ size = 'ExtraLarge'; weight = 'Bolder'; color = $color; horizontalAlignment = 'Center' }),
        (New-Text $label @{ size = 'Small'; isSubtle = $true; horizontalAlignment = 'Center'; spacing = 'None' })
    )
    if ($showDelta) {
        if ($null -eq $delta) { $items += (New-Text '·' @{ size = 'Small'; isSubtle = $true; horizontalAlignment = 'Center'; spacing = 'None' }) }
        else { $items += (New-Delta $delta $suffix) }
    }
    return @{ type = 'Column'; width = 'stretch'; items = $items }
}

# ---------- Tách card thành nhiều tin nhắn khi vượt $MaxPayloadBytes ----------
function Get-PartSuffix([int]$no, [int]$total) { return " · phần $no/$total" }

function Get-PartTitle($titleBlock, [int]$no, [int]$total) {
    $t = $titleBlock.Clone()
    $t.text = $titleBlock.text + (Get-PartSuffix $no $total)
    return $t
}

# Dòng đầu của các tin nhắn tiếp theo.
function New-PartHeader([string]$title, [int]$no, [int]$total) {
    return (New-Text ($title + (Get-PartSuffix $no $total)) @{ isSubtle = $true; weight = 'Bolder' })
}

# Vị trí dòng đầu tiên của một section (New-Section): tiêu đề + gợi ý ở trước, mỗi dòng task/MR là một ColumnSet.
# Trả về -1 nếu block không phải section có từ 2 dòng trở lên (không chia được).
function Get-SectionRowStart($block) {
    if ($block.type -ne 'Container') { return -1 }
    $items = @($block.items)
    $k = 0
    while ($k -lt $items.Count -and $items[$k].type -ne 'ColumnSet') { $k++ }
    if ($k -eq 0 -or ($items.Count - $k) -lt 2) { return -1 }
    for ($j = $k; $j -lt $items.Count; $j++) { if ($items[$j].type -ne 'ColumnSet') { return -1 } }
    return $k
}

# Một phần của section bị chia: giữ nguyên style/spacing, items bắt đầu bằng $lead.
function New-SectionChunk($section, [object[]]$lead) {
    $chunk = $section.Clone()
    $chunk.items = New-Object System.Collections.ArrayList
    $chunk.items.AddRange($lead)
    return $chunk
}

# Xếp lần lượt các block vào các card sao cho payload mỗi card <= $maxBytes; section quá lớn cho một card,
# hoặc không vừa chỗ còn lại khi card hiện tại chưa đầy một nửa, thì chia theo dòng.
# Kích thước tính cộng dồn = payload body rỗng + JSON từng block + dấu phẩy giữa các block (đúng như ConvertTo-Json -Compress).
# Tiêu đề / header phần được đo với "99/99" (dài nhất) nên khi điền số phần thật, card không lớn hơn lúc xếp.
# $title: đúng text của TextBlock tiêu đề trong card.
function Split-Card($card, [string]$title, [int]$maxBytes) {
    $blocks = @($card.body)
    $titleBlock = $blocks | Where-Object { $_.type -eq 'TextBlock' -and $_.text -eq $title } | Select-Object -First 1
    if ($null -eq $titleBlock) { throw "Split-Card: không tìm thấy tiêu đề '$title' trong card." }
    $emptyBytes = Get-PayloadBytes (New-AdaptiveCard @())
    $headerBytes = Get-JsonBytes (New-PartHeader $title 99 99)
    $parts = New-Object System.Collections.ArrayList

    # Phần 1 bắt đầu trống; các phần sau đã có sẵn header (tính là 1 block).
    function New-Part {
        $part = @{ blocks = New-Object System.Collections.ArrayList; bytes = $emptyBytes; n = 0 }
        if ($parts.Count -gt 0) { $part.bytes += $headerBytes; $part.n = 1 }
        [void]$parts.Add($part)
        return $part
    }
    function Test-Fits($part, [int]$b) { return ($part.bytes + $b + [int]($part.n -gt 0)) -le $maxBytes }
    function Add-Block($part, $block, [int]$b) {
        [void]$part.blocks.Add($block)
        $part.bytes += $b + [int]($part.n -gt 0)
        $part.n++
    }

    $cur = New-Part
    foreach ($block in $blocks) {
        $b = if ([object]::ReferenceEquals($block, $titleBlock)) { Get-JsonBytes (Get-PartTitle $titleBlock 99 99) } else { Get-JsonBytes $block }
        if (Test-Fits $cur $b) { Add-Block $cur $block $b; continue }

        # Section không vừa chỗ còn lại: chuyển nguyên section sang card mới, trừ khi section quá lớn cho một card,
        # hoặc card hiện tại chưa đầy một nửa (tránh tin nhắn gần như trống, vd phần 1 chỉ có header) — khi đó chia theo dòng.
        $rowStart = Get-SectionRowStart $block
        $fitsAlone = ($emptyBytes + $headerBytes + 1 + $b) -le $maxBytes
        $curUnderHalf = $cur.bytes -lt ($maxBytes / 2)
        if ($rowStart -lt 0 -or ($fitsAlone -and -not $curUnderHalf)) {
            if ($cur.blocks.Count -gt 0) { $cur = New-Part }
            if (-not (Test-Fits $cur $b)) {
                Write-Host "CẢNH BÁO: một block ($b bytes) vượt $maxBytes bytes kể cả khi đứng riêng, vẫn gửi riêng phần $($parts.Count)."
            }
            Add-Block $cur $block $b
            continue
        }

        # Chia các dòng ra nhiều Container; phần tiếp theo chỉ giữ tiêu đề "(tiếp)", bỏ gợi ý.
        $items = @($block.items)
        $chunk = $null
        for ($k = $rowStart; $k -lt $items.Count; $k++) {
            $row = $items[$k]
            $rb = Get-JsonBytes $row
            if ($null -ne $chunk -and ($cur.bytes + $rb + 1) -le $maxBytes) {
                [void]$chunk.items.Add($row)
                $cur.bytes += $rb + 1
                continue
            }
            $isFirstChunk = $null -eq $chunk
            if ($isFirstChunk) {
                $lead = @($items[0..($rowStart - 1)])
            } else {
                $continuedTitle = $items[0].Clone()
                $continuedTitle.text = $items[0].text + ' (tiếp)'
                $lead = @($continuedTitle)
            }
            $chunk = New-SectionChunk $block $lead
            # Dòng đầu mỗi phần không kẻ đường phân cách phía trên.
            if ($row.separator) {
                $row = $row.Clone()
                $row.Remove('separator')
            }
            [void]$chunk.items.Add($row)
            $cb = Get-JsonBytes $chunk
            # Phần đầu của section được ghép vào card hiện tại nếu vừa; phần tiếp theo luôn sang card mới.
            if ((-not $isFirstChunk -or -not (Test-Fits $cur $cb)) -and $cur.blocks.Count -gt 0) { $cur = New-Part }
            if (-not (Test-Fits $cur $cb)) {
                Write-Host "CẢNH BÁO: một dòng của section ($cb bytes) vượt $maxBytes bytes kể cả khi đứng riêng, vẫn gửi riêng phần $($parts.Count)."
            }
            Add-Block $cur $chunk $cb
        }
    }

    if ($parts.Count -eq 1) { return $card }
    $total = $parts.Count
    for ($p = 0; $p -lt $total; $p++) {
        if ($p -eq 0) {
            $body = @(foreach ($blk in $parts[0].blocks) {
                if ([object]::ReferenceEquals($blk, $titleBlock)) { Get-PartTitle $blk 1 $total } else { $blk }
            })
        } else {
            $body = @(New-PartHeader $title ($p + 1) $total) + @($parts[$p].blocks)
        }
        New-AdaptiveCard $body
    }
}

# ---------- Gửi card ----------
# Đo payload, tách khi vượt $MaxPayloadBytes, ghi logs\<prefix>.json (+ <prefix>-2.json, ...), rồi in (DryRun) hoặc post Teams.
function Send-Report($card, [string]$title, [string]$payloadPrefix) {
    $size = Get-PayloadBytes $card
    Write-Host ("Payload: {0:N0} bytes" -f $size)
    $cards = @($card)
    if ($size -gt $MaxPayloadBytes) {
        $cards = @(Split-Card $card $title $MaxPayloadBytes)
        Write-Host "Card vượt $MaxPayloadBytes bytes, tách thành $($cards.Count) tin nhắn:"
        for ($p = 0; $p -lt $cards.Count; $p++) {
            $partSize = Get-PayloadBytes $cards[$p]
            Write-Host ("  Phần {0}/{1}: {2:N0} bytes" -f ($p + 1), $cards.Count, $partSize)
            if ($partSize -gt $MaxPayloadBytes) { Write-Host "CẢNH BÁO: phần $($p + 1) vẫn vượt $MaxPayloadBytes bytes, Teams có thể bỏ qua." }
        }
    }

    # Xoá payload các phần của lần chạy trước để không lẫn với lần này. Chỉ khớp đúng "<prefix>-<số>.json"
    # để không xoá nhầm file của prefix khác (vd last-payload và sprint-payload).
    $partPattern = '^' + [regex]::Escape($payloadPrefix) + '-\d+\.json$'
    Get-ChildItem -LiteralPath $logDir -Filter "$payloadPrefix-*.json" | Where-Object { $_.Name -match $partPattern } | Remove-Item -Force
    for ($p = 0; $p -lt $cards.Count; $p++) {
        $payloadName = if ($p -eq 0) { "$payloadPrefix.json" } else { "$payloadPrefix-$($p + 1).json" }
        [IO.File]::WriteAllText((Join-Path $logDir $payloadName), ((New-TeamsPayload $cards[$p]) | ConvertTo-Json -Depth 30), $utf8)
    }

    if ($DryRun) {
        Write-Host "`n----- DRY RUN (không gửi Teams) -----"
        for ($p = 0; $p -lt $cards.Count; $p++) {
            if ($cards.Count -gt 1) { Write-Host "===== Phần $($p + 1)/$($cards.Count) =====" }
            foreach ($b in $cards[$p].body) { foreach ($l in (Get-CardLines $b)) { Write-Host $l }; Write-Host '' }
        }
        return
    }

    if ([string]::IsNullOrWhiteSpace($webhook)) { throw "Thiếu $webhookKey trong .env / projects\$Project.env" }
    for ($p = 0; $p -lt $cards.Count; $p++) {
        if ($p -gt 0) { Start-Sleep -Seconds $PartDelaySeconds }
        Send-Teams $webhook $cards[$p]
    }
    $sentText = if ($Test) { 'Đã gửi Teams (TEST)' } else { 'Đã gửi Teams' }
    if ($cards.Count -gt 1) { $sentText += " · $($cards.Count) phần" }
    Write-Host "$sentText."
}

# State đọc từ state\<KEY>.json ($state: kết quả ConvertFrom-Json, có thể $null) -> ordered dict chỉ gồm các trường $StateKeys đang có.
# Trường chưa có (vd chưa từng gửi daily) thì vẫn để trống, không tự bịa ra lastEnd.
function ConvertTo-StateData($state) {
    $data = [ordered]@{}
    foreach ($k in $StateKeys) {
        if ($state -and $null -ne $state.$k) { $data[$k] = $state.$k }
    }
    return $data
}

function Read-StateData([string]$path) {
    $state = $null
    if (Test-Path -LiteralPath $path) { $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    return (ConvertTo-StateData $state)
}

# Ghi toàn bộ state trong $data; trường nào không có thì không ghi.
function Save-State([string]$path, [System.Collections.IDictionary]$data) {
    # Ghi ra file tạm rồi đổi tên, để mất điện giữa chừng không làm hỏng state\<KEY>.json.
    $tmp = "$path.tmp"
    $data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

# Ghi phần sprint vào state\<KEY>.json: thêm $addSprintIds vào sprintsReported, và/hoặc dời mốc sprintCheckedUntil.
# Đọc lại file ngay trước khi ghi để không đè dữ liệu do lần chạy khác vừa ghi: các trường khác lấy theo file,
# sprintsReported lấy hợp hai bên (giữ $MaxReportedSprints id gần nhất), sprintCheckedUntil lấy mốc muộn hơn.
function Save-SprintState([int[]]$addSprintIds, [string]$checkedUntil) {
    $disk = Read-StateData $statePath
    foreach ($k in @('lastEnd', 'sentAt', 'history', 'sprintCheckedUntil')) {
        if ($disk.Contains($k)) { $stateData[$k] = $disk[$k] }
    }
    $ids = @(@($disk['sprintsReported']) + @($stateData['sprintsReported']) + @($addSprintIds) |
        Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ } | Select-Object -Unique)
    if ($ids.Count -gt 0) { $stateData['sprintsReported'] = @($ids | Select-Object -Last $MaxReportedSprints) }
    if ($checkedUntil -and $checkedUntil -gt [string]$stateData['sprintCheckedUntil']) { $stateData['sprintCheckedUntil'] = $checkedUntil }
    Save-State $statePath $stateData
}

# ---------- Card tổng kết sprint (Jira Agile API) ----------
function Invoke-JiraGet([string]$pathAndQuery) {
    return (Invoke-RestMethod -Method Get -Uri ($jiraUrl + $pathAndQuery) -Headers @{ Authorization = "Bearer $jiraToken" })
}

# Các API Agile dạng danh sách phân trang theo startAt/isLast.
function Get-AgileValues([string]$path) {
    $sep = if ($path.Contains('?')) { '&' } else { '?' }
    $at = 0
    do {
        $resp = Invoke-JiraGet "$path$($sep)startAt=$at"
        $page = @($resp.values | Where-Object { $_ })
        foreach ($v in $page) { $v }
        $at += $page.Count
    } while (-not $resp.isLast -and $page.Count -gt 0)
}

# JIRA_BOARD_ID (có thể nhiều id, cách nhau dấu phẩy); để trống thì lấy mọi scrum board của project.
function Get-ScrumBoardIds {
    $raw = Get-Setting $cfg 'JIRA_BOARD_ID' ''
    if ($raw) {
        return @($raw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object {
            $id = 0
            if (-not [int]::TryParse($_, [ref]$id) -or $id -le 0) { throw "JIRA_BOARD_ID không hợp lệ: '$_' (cần id số, cách nhau bằng dấu phẩy)" }
            $id
        } | Select-Object -Unique)
    }
    $ids = @(Get-AgileValues "/rest/agile/1.0/board?projectKeyOrId=$([Uri]::EscapeDataString($jiraProject))&type=scrum" |
        ForEach-Object { [int]$_.id })
    if ($ids.Count -eq 0) { Write-Host "Không có scrum board nào của $jiraProject, bỏ qua card tổng kết sprint." }
    else { Write-Host "Scrum board của $jiraProject`: $($ids -join ', ')" }
    return $ids
}

# Thời điểm kết thúc sprint (giờ máy) = sớm hơn giữa completeDate và endDate: team hay đóng sprint trước endDate.
function Get-SprintEndMoment($sprint) {
    $moments = @(foreach ($d in @($sprint.completeDate, $sprint.endDate)) {
        if ($d) { [DateTimeOffset]::Parse($d).LocalDateTime }
    })
    if ($moments.Count -eq 0) { return $null }
    return ($moments | Sort-Object | Select-Object -First 1)
}

function Get-ReportedSprintIds {
    return @(@($stateData['sprintsReported']) | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
}

# Gửi thật lên group (không -DryRun, không -Test): chỉ khi đó mới lọc / ghi sprintsReported.
function Test-GroupSend { return (-not $DryRun -and -not $Test) }

# -From/-To lên group không gửi card sprint (khoảng tuỳ chọn không đụng state\<KEY>.json); -DryRun / -Test vẫn xem thử được.
function Test-SkipSprintCustomRange { return ((Test-GroupSend) -and [bool]($From -or $To)) }

# -SprintId lên group mà sprint đã gửi rồi: bỏ qua, trừ khi -Force.
function Test-SkipSprintAlreadyReported([int]$id) {
    return ((Test-GroupSend) -and -not $Force -and (@(Get-ReportedSprintIds) -contains $id))
}

# Đầu khoảng tìm sprint: lùi về sprintCheckedUntil nếu lần trước bước sprint chưa xong (lỗi sau khi gửi daily),
# để sprint đó không bị mất. Chưa có mốc (lần đầu triển khai, không gửi sprint cũ), mốc quá $SprintCatchUpDays ngày,
# hoặc khoảng tuỳ chọn -From/-To thì giữ nguyên $start.
function Get-SprintSearchStart([datetime]$start, [datetime]$today) {
    $raw = [string]$stateData['sprintCheckedUntil']
    if ($From -or $To -or -not $raw) { return $start }
    $checked = [datetime]::ParseExact($raw, 'yyyy-MM-dd', $null)
    if ($checked -lt $start -and $checked -ge $today.AddDays(-$SprintCatchUpDays)) {
        Write-Host "Bước sprint lần trước chưa xong: tìm sprint từ $($checked.ToString('yyyy-MM-dd'))."
        return $checked
    }
    return $start
}

# Sprint (active/closed, thuộc board đang quét) kết thúc trong [$from, $to), sắp theo thời điểm kết thúc.
# Gửi group thì bỏ sprint đã gửi; DryRun / Test luôn lấy để xem thử được.
function Find-PendingSprints([datetime]$from, [datetime]$to) {
    $reported = @(if (Test-GroupSend) { Get-ReportedSprintIds })
    $found = New-Object System.Collections.ArrayList
    foreach ($boardId in Get-ScrumBoardIds) {
        foreach ($s in Get-AgileValues "/rest/agile/1.0/board/$boardId/sprint?state=active,closed") {
            # Board cũng liệt kê sprint của board khác có chung task; chỉ nhận sprint gốc của board này.
            if ([int]$s.originBoardId -ne $boardId) { continue }
            $moment = Get-SprintEndMoment $s
            if ($null -eq $moment -or $moment -lt $from -or $moment -ge $to) { continue }
            if ($reported -contains [int]$s.id) {
                Write-Host "Sprint $($s.name) (id $($s.id)) đã gửi card tổng kết, bỏ qua."
                continue
            }
            [void]$found.Add($s)
        }
    }
    return @($found | Sort-Object { Get-SprintEndMoment $_ })
}

function Get-SprintIssues([int]$id) {
    $list = New-Object System.Collections.ArrayList
    $at = 0
    do {
        $resp = Invoke-JiraGet "/rest/agile/1.0/sprint/$id/issue?startAt=$at&maxResults=100&fields=summary,status,assignee"
        $page = @($resp.issues | Where-Object { $_ })
        foreach ($i in $page) { [void]$list.Add($i) }
        $at += $page.Count
    } while ($page.Count -gt 0 -and $at -lt $resp.total)
    return @($list)
}

function Test-IssueDone($issue) {
    $st = $issue.fields.status
    if (-not $st) { return $false }
    return (($doneStatusNames -contains $st.name) -or ($st.statusCategory -and $st.statusCategory.key -eq 'done'))
}

# Khoá sắp xếp tự nhiên: theo project rồi theo số (DG-9 trước DG-10).
function Get-IssueSortKey([string]$key) {
    $i = $key.LastIndexOf('-')
    $n = 0
    if ($i -lt 0 -or -not [int]::TryParse($key.Substring($i + 1), [ref]$n)) { return $key }
    return ('{0}-{1:D10}' -f $key.Substring(0, $i), $n)
}

# Gom task theo người được gán. Sắp: nhiều task hoàn thành trước, rồi nhiều task hơn, rồi theo tên; "Chưa gán" luôn cuối.
# s = tên ngắn: tên gọi, hoặc tên đầy đủ khi hai thành viên sprint trùng tên gọi.
function Get-SprintMembers([object[]]$sprintIssues) {
    $groups = [ordered]@{}
    foreach ($i in $sprintIssues) {
        $a = $i.fields.assignee
        $k = if ($a) { 'user:' + ([string]$a.name).ToLower() } else { 'unassigned' }
        if (-not $groups.Contains($k)) {
            $groups[$k] = [pscustomobject]@{
                a    = [bool]$a
                n    = $(if ($a) { [string]$a.displayName } else { '' })
                s    = 'Chưa gán'
                done = New-Object System.Collections.ArrayList
                open = New-Object System.Collections.ArrayList
            }
        }
        # Không gán "$x = if (...) { $list }": list rỗng bị PowerShell trải ra thành $null.
        if (Test-IssueDone $i) { [void]$groups[$k].done.Add($i) } else { [void]$groups[$k].open.Add($i) }
    }

    $assigned = @($groups.Values | Where-Object { $_.a } | Sort-Object @{ e = { $_.done.Count }; Descending = $true },
        @{ e = { $_.done.Count + $_.open.Count }; Descending = $true }, n)
    $sameGiven = @{}
    foreach ($m in $assigned) { $g = Get-GivenName $m.n; $sameGiven[$g] = 1 + [int]$sameGiven[$g] }
    foreach ($m in $assigned) {
        $g = Get-GivenName $m.n
        $m.s = if (-not $g -or $sameGiven[$g] -gt 1) { $m.n } else { $g }
    }
    return @($assigned) + @($groups.Values | Where-Object { -not $_.a })
}

function Get-SprintTitle($sprint) {
    $from = [DateTimeOffset]::Parse($sprint.startDate).LocalDateTime.ToString('dd/MM')
    $to = (Get-SprintEndMoment $sprint).ToString('dd/MM/yyyy')
    return "🏁 Tổng kết $(Escape-Md $sprint.name) — $from – $to"
}

# Card tổng kết sprint: chỉ liệt kê task theo người, không ghép MR, không link.
function New-SprintCard($sprint, [object[]]$sprintIssues, [string]$title) {
    $body = New-Object System.Collections.ArrayList
    $greeting = '🏁 Sprint đã khép lại — cùng nhìn lại thành quả nhé!'
    if ($Test) { $greeting = '🧪 TEST · ' + $greeting }
    [void]$body.Add((New-Text $greeting @{ isSubtle = $true }))
    [void]$body.Add((New-Text $title @{ size = 'Large'; weight = 'Bolder'; spacing = 'None' }))
    if (-not [string]::IsNullOrWhiteSpace($sprint.goal)) {
        [void]$body.Add((New-Text ('🎯 Mục tiêu: ' + (Escape-Md $sprint.goal.Trim())) @{ size = 'Small'; isSubtle = $true; spacing = 'Small' }))
    }
    if ($sprintIssues.Count -eq 0) {
        [void]$body.Add(@{ type = 'Container'; style = 'emphasis'; spacing = 'Medium'; items = @(
            (New-Text 'Sprint không có task nào.')
        ) })
        return (New-AdaptiveCard @($body))
    }

    $members = @(Get-SprintMembers $sprintIssues)
    $assigned = @($members | Where-Object { $_.a })
    $doneCount = [int]($members | ForEach-Object { $_.done.Count } | Measure-Object -Sum).Sum
    $openCount = $sprintIssues.Count - $doneCount
    $pct = Get-Pct $doneCount $sprintIssues.Count
    $pctColor = if ($pct -ge 80) { 'Good' } elseif ($pct -ge 50) { 'Warning' } else { 'Attention' }
    [void]$body.Add(@{ type = 'ColumnSet'; spacing = 'Medium'; columns = @(
        (New-Kpi "$($sprintIssues.Count)" 'task trong sprint' 'Accent' $null $false),
        (New-Kpi "$doneCount" 'hoàn thành' 'Good' $null $false),
        (New-Kpi "$openCount" 'chưa xong' $(if ($openCount -gt 0) { 'Warning' } else { 'Good' }) $null $false),
        (New-Kpi "$pct%" 'tỉ lệ hoàn thành' $pctColor $null $false),
        (New-Kpi "$($assigned.Count)" 'thành viên' 'Default' $null $false)
    ) })

    $topDone = [int]($assigned | ForEach-Object { $_.done.Count } | Measure-Object -Maximum).Maximum
    if ($topDone -gt 0) {
        $names = @($assigned | Where-Object { $_.done.Count -eq $topDone } | ForEach-Object { '**' + (Escape-Md $_.s) + '**' }) -join ' & '
        [void]$body.Add((New-Text "⭐ MVP sprint: $names — $topDone task hoàn thành" @{ spacing = 'Medium' }))
    }

    foreach ($m in $members) {
        $lines = @(foreach ($i in @($m.done | Sort-Object { Get-IssueSortKey $_.key })) {
            '- ✅ {0} · {1}' -f $i.key, (Escape-Md $i.fields.summary)
        }) + @(foreach ($i in @($m.open | Sort-Object { Get-IssueSortKey $_.key })) {
            '- ⏳ {0} · {1} _({2})_' -f $i.key, (Escape-Md $i.fields.summary), $i.fields.status.name
        })
        $name = Escape-Md $m.s
        # Mỗi Container tối đa $MaxBulletLinesPerBlock dòng; các Container sau của cùng người ghi "(tiếp)".
        for ($from = 0; $from -lt $lines.Count; $from += $MaxBulletLinesPerBlock) {
            $chunk = $lines[$from..([math]::Min($from + $MaxBulletLinesPerBlock, $lines.Count) - 1)]
            if ($from -eq 0) {
                $header = '**👤 {0}** · {1}/{2} task hoàn thành' -f $name, $m.done.Count, $lines.Count
                $block = @{ type = 'Container'; separator = $true; spacing = 'Medium' }
            } else {
                $header = "**👤 $name** (tiếp)"
                $block = @{ type = 'Container'; spacing = 'Small' }
            }
            $block.items = @(
                (New-Text $header),
                (New-Text ($chunk -join "`r`n") @{ spacing = 'Small' })
            )
            [void]$body.Add($block)
        }
    }
    return (New-AdaptiveCard @($body))
}

# Gửi card tổng kết từng sprint; gửi group thành công thì ghi ngay id vào sprintsReported (sprint sau lỗi không làm mất sprint trước).
# $afterDaily: vừa gửi daily trong lần chạy này -> chờ trước card đầu để giữ đúng thứ tự trong chat.
function Send-SprintCards([object[]]$sprints, [bool]$afterDaily) {
    for ($s = 0; $s -lt $sprints.Count; $s++) {
        $sprint = $sprints[$s]
        $id = [int]$sprint.id
        $sprintIssues = @(Get-SprintIssues $id)
        Write-Host "`nCard tổng kết sprint: $($sprint.name) (id $id, $($sprint.state)) · $($sprintIssues.Count) task"
        $title = Get-SprintTitle $sprint
        $card = New-SprintCard $sprint $sprintIssues $title
        # File log theo id sprint: một lần chạy gửi nhiều sprint thì file của sprint sau không đè sprint trước.
        [IO.File]::WriteAllText((Join-Path $logDir "sprint-$id-card-for-designer.json"), ($card | ConvertTo-Json -Depth 30), $utf8)
        if (-not $DryRun -and ($afterDaily -or $s -gt 0)) { Start-Sleep -Seconds $PartDelaySeconds }
        Send-Report $card $title "sprint-$id-payload"
        if (Test-GroupSend) { Save-SprintState @($id) '' }
    }
}

# Bước card sprint của lần chạy daily (cả khi daily hôm nay đã gửi và chỉ gửi bù). Trả về số sprint đã xử lý.
function Invoke-SprintStep([datetime]$start, [datetime]$end, [bool]$afterDaily) {
    if (Test-SkipSprintCustomRange) {
        Write-Host 'Gửi -From/-To lên group: bỏ qua card sprint (dùng -SprintId nếu cần).'
        return 0
    }
    $pending = @(Find-PendingSprints (Get-SprintSearchStart $start $today) $end)
    if ($pending.Count -eq 0) { Write-Host 'Không có sprint nào cần tổng kết trong khoảng báo cáo.' }
    else { Send-SprintCards $pending $afterDaily }
    # Quét xong cả khoảng: dời mốc để lần sau không phải tìm lại (khoảng -From/-To đã bị loại ở trên).
    $checked = $end.ToString('yyyy-MM-dd')
    if ((Test-GroupSend) -and [string]$stateData['sprintCheckedUntil'] -ne $checked) { Save-SprintState @() $checked }
    return $pending.Count
}

# Đọc cấu hình trong try để lỗi cấu hình (thiếu file project, ...) cũng được ghi log và báo vào chat test.
$cfg = $null
# Bước đang chạy, để card báo lỗi nói rõ daily đã gửi hay chưa: 'daily' | 'sprint' (daily đã gửi) | 'sprint-only' (-SprintId).
$phase = 'daily'

try {
    # Chặn quên chuyển state của bản 1 project: không thì mất history, sprintsReported và chặn "hôm nay đã gửi".
    if ((Test-Path -LiteralPath (Join-Path $root 'state.json')) -and -not (Test-Path -LiteralPath $statePath)) {
        throw "Còn state.json cũ ở thư mục gốc: chuyển thành state\$Project.json (nếu là state của $Project) trước khi chạy."
    }
    $cfg = Read-ProjectConfig
    $webhookKey = if ($Test) { 'TEAMS_TEST_WEBHOOK_URL' } else { 'TEAMS_WEBHOOK_URL' }
    $webhook = $cfg[$webhookKey]

    # ---------- State + cấu hình Jira (daily và card sprint đều dùng) ----------
    $today = (Get-Date).Date
    $state = $null
    if (Test-Path -LiteralPath $statePath) { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
    # Mang đủ mọi trường trong bộ nhớ: lần lưu của daily không làm mất trường sprint, lần lưu của sprint không làm mất history.
    $stateData = ConvertTo-StateData $state

    $jiraUrl = (Get-Setting $cfg 'JIRA_URL').TrimEnd('/')
    $jiraToken = Get-Setting $cfg 'JIRA_PERSONAL_TOKEN'
    $jiraProject = Get-Setting $cfg 'JIRA_PROJECT'
    $doneStatusNames = @((Get-Setting $cfg 'JIRA_DONE_STATUSES' 'Closed,Resolved,Done').Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $doneStatuses = $doneStatusNames | ForEach-Object { '"' + $_ + '"' }

    if ($sprintOnly) {
        $phase = 'sprint-only'
        if (Test-SkipSprintAlreadyReported $SprintId) {
            Write-Host "Sprint $SprintId đã gửi card tổng kết lên group rồi. Dùng -Force để gửi lại."
            return
        }
        $sprint = Invoke-JiraGet "/rest/agile/1.0/sprint/$SprintId"
        if ($sprint.state -eq 'future') { throw "Sprint $SprintId ($($sprint.name)) chưa bắt đầu, chưa có gì để tổng kết." }
        Send-SprintCards @($sprint) $false
        return
    }

    # ---------- Khoảng thời gian ----------
    $dailyAlreadySent = $false
    if ($To) { $end = [datetime]::ParseExact($To, 'yyyy-MM-dd', $null) } else { $end = $today }

    if ($From) {
        $start = [datetime]::ParseExact($From, 'yyyy-MM-dd', $null)
    } else {
        $default = if ($today.DayOfWeek -eq [DayOfWeek]::Monday) { $today.AddDays(-3) } else { $today.AddDays(-1) }
        $start = $default
        if ($state -and $state.lastEnd) {
            $last = [datetime]::ParseExact($state.lastEnd, 'yyyy-MM-dd', $null)
            # Daily đã gửi: vẫn tính tiếp khoảng (lấy từ history bên dưới) để gửi bù card sprint nếu còn thiếu.
            if ($last -ge $today -and -not $Force -and -not $DryRun -and -not $Test) { $dailyAlreadySent = $true }
            # Gộp những ngày bị lỡ, nhưng không quá 14 ngày.
            if ($last -lt $default -and $last -ge $today.AddDays(-14)) { $start = $last }
            # Gửi lại (-Force/-Test/-DryRun) khi hôm nay đã gửi: dùng đúng khoảng của lần gửi đó (có thể đã gộp nhiều ngày).
            if ($last -ge $today -and $state.history) {
                $sentToday = @($state.history | Where-Object { $_.end -eq $today.ToString('yyyy-MM-dd') })
                if ($sentToday.Count -gt 0) { $start = [datetime]::ParseExact($sentToday[0].start, 'yyyy-MM-dd', $null) }
            }
        }
    }
    if ($start -ge $end) { throw "Khoảng thời gian rỗng: $start → $end" }

    $weekdayNames = @('CN', 'Thứ 2', 'Thứ 3', 'Thứ 4', 'Thứ 5', 'Thứ 6', 'Thứ 7')
    function Format-Range([datetime]$s, [datetime]$e) {
        if ($e.AddDays(-1) -eq $s) { return $s.ToString('dd/MM/yyyy') }
        return $s.ToString('dd/MM') + ' – ' + $e.AddDays(-1).ToString('dd/MM/yyyy')
    }
    $rangeLabel = Format-Range $start $end
    $titleRange = if ($end.AddDays(-1) -eq $start) { $weekdayNames[[int]$start.DayOfWeek] + ', ' + $rangeLabel } else { $rangeLabel }
    Write-Host "Khoảng báo cáo: $($start.ToString('yyyy-MM-dd HH:mm')) → $($end.ToString('yyyy-MM-dd HH:mm')) ($rangeLabel)"

    if ($dailyAlreadySent) {
        # Lần chạy trước gửi daily xong nhưng lỗi ở card sprint: chỉ gửi bù card sprint, không gửi lại daily.
        $phase = 'sprint'
        Write-Host 'Daily hôm nay đã gửi, chỉ kiểm tra card tổng kết sprint còn thiếu.'
        $sentSprints = Invoke-SprintStep $start $end $false
        if ($sentSprints -eq 0) { Write-Host "Hôm nay ($($today.ToString('yyyy-MM-dd'))) đã gửi rồi. Dùng -Force để gửi lại daily." }
        return
    }

    # ---------- Jira ----------
    $jql = 'project = {0} AND status CHANGED TO ({1}) DURING ("{2}", "{3}") ORDER BY key' -f `
        $jiraProject, ($doneStatuses -join ', '), $start.ToString('yyyy/MM/dd HH:mm'), $end.ToString('yyyy/MM/dd HH:mm')
    Write-Host "JQL: $jql"

    $issues = New-Object System.Collections.ArrayList
    $startAt = 0
    do {
        $body = @{ jql = $jql; startAt = $startAt; maxResults = 100; fields = @('summary', 'status', 'assignee') } |
            ConvertTo-Json -Depth 5
        $resp = Invoke-RestMethod -Method Post -Uri "$jiraUrl/rest/api/2/search" `
            -Headers @{ Authorization = "Bearer $jiraToken" } -ContentType 'application/json; charset=utf-8' `
            -Body ([Text.Encoding]::UTF8.GetBytes($body))
        foreach ($i in $resp.issues) { [void]$issues.Add($i) }
        $startAt += $resp.issues.Count
    } while ($resp.issues.Count -gt 0 -and $startAt -lt $resp.total)
    Write-Host "Jira: $($issues.Count) task"

    # ---------- GitLab ----------
    $gitlabHost = Get-Setting $cfg 'GITLAB_HOST'
    $gitlabToken = Get-Setting $cfg 'GITLAB_TOKEN' ''
    $gitlabProjects = (Get-Setting $cfg 'GITLAB_PROJECTS').Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $glab = (Get-Command glab -ErrorAction SilentlyContinue).Source
    if (-not $glab) { $glab = Join-Path $env:LOCALAPPDATA 'Programs\glab\glab.exe' }
    if (-not (Test-Path -LiteralPath $glab)) { throw "Không tìm thấy glab.exe" }

    $after = ([DateTimeOffset]$start).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $mrsByProject = [ordered]@{}
    foreach ($proj in $gitlabProjects) {
        $enc = [Uri]::EscapeDataString($proj)
        $list = New-Object System.Collections.ArrayList
        $page = 1
        do {
            $path = "projects/$enc/merge_requests?state=merged&updated_after=$([Uri]::EscapeDataString($after))" +
                "&per_page=100&page=$page&order_by=updated_at&sort=asc"
            $json = Invoke-Glab $glab @('api', '--hostname', $gitlabHost, $path) $proj $GlabTimeoutMs $gitlabToken $gitlabHost
            $batch = ConvertFrom-Json $json
            $n = 0
            foreach ($m in $batch) {
                $n++
                if (-not $m.merged_at) { continue }
                $mergedAt = ([DateTimeOffset]::Parse($m.merged_at)).LocalDateTime
                if ($mergedAt -ge $start -and $mergedAt -lt $end) { [void]$list.Add($m) }
            }
            $page++
        } while ($n -eq 100)
        $mrsByProject[$proj] = @($list | Sort-Object { [DateTimeOffset]::Parse($_.merged_at) })
        Write-Host "GitLab $proj`: $($list.Count) MR merged"
    }

    # ---------- Ghép Jira <-> MR theo mã task trong tên branch / tiêu đề MR ----------
    $keyRegex = '(?i)\b' + [regex]::Escape($jiraProject) + '-(\d+)\b'
    $multiProject = $mrsByProject.Count -gt 1
    $allMrs = @(foreach ($proj in $mrsByProject.Keys) {
        foreach ($m in $mrsByProject[$proj]) {
            $keys = @([regex]::Matches(($m.source_branch + ' ' + $m.title), $keyRegex) |
                ForEach-Object { $jiraProject.ToUpper() + '-' + $_.Groups[1].Value } | Select-Object -Unique)
            # Ticket của project Jira khác (vd ART-4651): chỉ nhận chữ HOA để tránh nhầm "utf-8", "v2-3" trong tên branch.
            $foreign = @([regex]::Matches(($m.source_branch + ' ' + $m.title), '\b([A-Z][A-Z0-9]{1,9})-(\d+)\b') |
                ForEach-Object { $_.Value } | Where-Object { -not $_.StartsWith($jiraProject.ToUpper() + '-') } | Select-Object -Unique)
            [pscustomobject]@{ Project = $proj; Mr = $m; JiraKeys = $keys; OtherKeys = $foreign }
        }
    })

    $doneKeys = @{}
    foreach ($i in $issues) { $doneKeys[$i.key] = $i }
    $mrsOfIssue = @{}
    foreach ($i in $issues) { $mrsOfIssue[$i.key] = @($allMrs | Where-Object { $_.JiraKeys -contains $i.key }) }

    $jiraGit = @($issues | Where-Object { $mrsOfIssue[$_.key].Count -gt 0 })
    $jiraOnly = @($issues | Where-Object { $mrsOfIssue[$_.key].Count -eq 0 })
    $gitOnly = @($allMrs | Where-Object { -not ($_.JiraKeys | Where-Object { $doneKeys.ContainsKey($_) }) })

    # Trạng thái hiện tại của các task được nhắc trong MR GitLab-only (task chưa done trong khoảng báo cáo).
    $otherStatus = @{}
    $otherKeys = @($gitOnly | ForEach-Object { $_.JiraKeys; $_.OtherKeys } | Select-Object -Unique)
    if ($otherKeys.Count -gt 0) {
        $q = @{ jql = 'key in (' + ($otherKeys -join ',') + ')'; maxResults = 100; fields = @('status'); validateQuery = $false } |
            ConvertTo-Json -Depth 5
        $r = Invoke-RestMethod -Method Post -Uri "$jiraUrl/rest/api/2/search" `
            -Headers @{ Authorization = "Bearer $jiraToken" } -ContentType 'application/json; charset=utf-8' `
            -Body ([Text.Encoding]::UTF8.GetBytes($q))
        foreach ($i in $r.issues) { $otherStatus[$i.key] = $i.fields.status }
    }
    Write-Host "Jira–GitLab: $($jiraGit.Count) · Jira only: $($jiraOnly.Count) · GitLab only: $($gitOnly.Count)"

    # ---------- Người đóng góp: Jira assignee + GitLab author, ghép theo username (cùng LDAP) ----------
    $people = [ordered]@{}
    function Add-Credit($dict, [string]$user, [string]$name, [int]$t, [int]$m) {
        if ([string]::IsNullOrWhiteSpace($user)) { return }
        $k = $user.ToLower()
        if (-not $dict.Contains($k)) { $dict[$k] = [pscustomobject]@{ n = $name; t = 0; m = 0 } }
        $p = $dict[$k]
        $p.t += $t
        $p.m += $m
    }
    foreach ($i in $issues) { if ($i.fields.assignee) { Add-Credit $people $i.fields.assignee.name $i.fields.assignee.displayName 1 0 } }
    foreach ($e in $allMrs) { if ($e.Mr.author) { Add-Credit $people $e.Mr.author.username $e.Mr.author.name 0 1 } }

    $current = [pscustomobject]@{
        start  = $start.ToString('yyyy-MM-dd')
        end    = $end.ToString('yyyy-MM-dd')
        tasks  = $issues.Count
        mrs    = $allMrs.Count
        linked = $jiraGit.Count
        people = $people
    }

    # ---------- Lịch sử: xu hướng, sparkline, tổng kết tuần ----------
    $history = @()
    if ($state -and $state.history) { $history = @($state.history | Where-Object { $_.end -le $current.start } | Sort-Object end) }
    $prev = if ($history.Count -gt 0) { $history[-1] } else { $null }

    function Get-PeopleEntries($p) {
        if ($null -eq $p) { return }
        if ($p -is [System.Collections.IDictionary]) {
            foreach ($kv in $p.GetEnumerator()) { [pscustomobject]@{ k = $kv.Key; n = $kv.Value.n; t = [int]$kv.Value.t; m = [int]$kv.Value.m } }
        } else {
            foreach ($pr in $p.PSObject.Properties) { [pscustomobject]@{ k = $pr.Name; n = $pr.Value.n; t = [int]$pr.Value.t; m = [int]$pr.Value.m } }
        }
    }

    $week = $null
    if ($end.DayOfWeek -eq [DayOfWeek]::Friday) {
        $monday = $end.AddDays(-4).ToString('yyyy-MM-dd')
        $weekEntries = @($history | Where-Object { $_.end -ge $monday })
        if ($weekEntries.Count -gt 0) {
            $all = @($weekEntries) + @($current)
            $wp = [ordered]@{}
            foreach ($x in $all) { foreach ($pe in Get-PeopleEntries $x.people) { Add-Credit $wp $pe.k $pe.n $pe.t $pe.m } }
            $week = [pscustomobject]@{
                label  = Format-Range ([datetime]::ParseExact($all[0].start, 'yyyy-MM-dd', $null)) $end
                tasks  = ($all | Measure-Object tasks -Sum).Sum
                mrs    = ($all | Measure-Object mrs -Sum).Sum
                linked = ($all | Measure-Object linked -Sum).Sum
                people = $wp
            }
        }
    }

    # Tên ngắn (Get-GivenName); trùng tên gọi thì giữ tên đầy đủ.
    $givenCount = @{}
    $nameSources = @($people.Values)
    if ($week) { $nameSources += @($week.people.Values) }
    foreach ($e in $allMrs) {
        $mu = if ($e.Mr.merge_user) { $e.Mr.merge_user } else { $e.Mr.merged_by }
        if ($mu -and $mu.name) { $nameSources += [pscustomobject]@{ n = $mu.name } }
    }
    $seenNames = @{}
    foreach ($p in $nameSources) {
        if ($seenNames.ContainsKey($p.n)) { continue }
        $seenNames[$p.n] = $true
        $g = Get-GivenName $p.n
        $givenCount[$g] = 1 + [int]$givenCount[$g]
    }
    function Get-ShortName([string]$full) {
        $g = Get-GivenName $full
        if (-not $g -or $givenCount[$g] -gt 1) { return (Escape-Md $full) }
        return (Escape-Md $g)
    }

    function Format-Stats([int]$t, [int]$m) {
        $parts = @()
        if ($t -gt 0) { $parts += "$t task" }
        if ($m -gt 0) { $parts += "$m MR" }
        return ($parts -join ' · ')
    }
    function Get-Ranked($dict) {
        return @($dict.Values | Sort-Object @{ e = { $_.t + $_.m }; Descending = $true }, @{ e = { $_.t }; Descending = $true }, n)
    }
    function Format-Mvp($dict) {
        $ranked = Get-Ranked $dict
        if ($ranked.Count -eq 0) { return $null }
        $top = $ranked[0]
        $winners = @($ranked | Where-Object { ($_.t + $_.m) -eq ($top.t + $top.m) -and $_.t -eq $top.t })
        $names = (@($winners | ForEach-Object { '**' + (Get-ShortName $_.n) + '**' }) -join ' & ')
        return "$names — " + (Format-Stats $top.t $top.m)
    }
    function Get-Spark([int[]]$vals) {
        $chars = '▁▂▃▄▅▆▇█'
        $max = ($vals | Measure-Object -Maximum).Maximum
        if ($max -le 0) { return ([string]$chars[0]) * $vals.Count }
        return -join @($vals | ForEach-Object { $chars[[int][math]::Round($_ * 7 / $max)] })
    }

    function Get-Greeting([datetime]$day) {
        $pool = @(switch ($day.DayOfWeek) {
            'Monday' { @(
                '☀️ Thứ 2 đây rồi! Sạc pin cuối tuần xong chưa, vào việc thôi nào 🔋',
                '🐢 Thứ 2 khởi động chậm cũng được, miễn là có khởi động 😌',
                '🧃 Ai còn ngái ngủ thì uống miếng nước, ai tỉnh rồi thì merge MR đi nè!',
                '🚀 Tuần mới, bug cũ… à nhầm, tuần mới, thành tích mới! 💪',
                '🎬 Tập mới của series "Làm game cực cháy" chính thức lên sóng!',
                '😴 Cuối tuần trôi nhanh như MR được approve… thôi vào việc nào!',
                '🌱 Tuần mới tươi như rau sạch, code cũng phải sạch nha cả nhà!',
                '📣 Loa loa loa! Tuần mới tới rồi, báo cáo cuối tuần trước ra lò nè!'
            ) }
            'Tuesday' { @(
                '☕ Thứ 3 rồi, cà phê vào, task ra!',
                '🔥 Thứ 3 — ngày lý tưởng để đóng vài ticket cho đời thêm vui!',
                '🎯 Mục tiêu hôm nay: số MR merge nhiều hơn số lần lướt TikTok 😆',
                '🌤️ Thứ 3 nắng đẹp, pipeline xanh, tâm trạng cũng xanh!',
                '🐣 Thứ 3 chưa mệt đâu, quẩy tiếp thôi cả nhà ơi!',
                '🍜 Ăn sáng chưa? Chưa thì đọc report cho no bụng tinh thần trước nè',
                '💡 Fun fact: đóng càng nhiều task, thứ 6 tới càng nhanh (chưa kiểm chứng) 🤓',
                '🛼 Thứ 3 lướt nhẹ, code êm, merge mượt!'
            ) }
            'Wednesday' { @(
                '🐫 Thứ 4 — đỉnh lưng lạc đà của tuần, vượt dốc là xuống dốc liền!',
                '⛰️ Qua nửa tuần rồi! Từ giờ là đường xuống dốc, thả phanh thôi 🛷',
                '🚀 Giữa tuần rồi, tăng tốc nào anh em ơi!',
                '🧠 Thứ 4 não hơi lag? Không sao, report này load nhanh lắm 😎',
                '🧋 Trà sữa giữa tuần là hợp lý, nhưng merge MR còn hợp lý hơn!',
                '🎮 Level giữa tuần: unlocked. Boss thứ 6 đang chờ phía trước!',
                '📈 Biểu đồ tinh thần giữa tuần: đi lên! (chắc vậy)',
                '🤸 Vươn vai cái nào, nửa tuần còn lại là của chúng ta!'
            ) }
            'Thursday' { @(
                '💪 Thứ 5 rồi, ngửi thấy mùi cuối tuần thoang thoảng đâu đây 👃',
                '🔥 Thứ 5 bứt tốc! Ticket nào còn treo thì đóng giùm cái nha',
                '🏃 Nước rút thứ 5: chạy deadline mà như chạy marathon!',
                '🍕 Thứ 5 — còn đúng 1 ngày nữa là được ăn mừng rồi!',
                '🎸 Thứ 5 quẩy nhẹ, thứ 6 quẩy mạnh, thứ 7 ngủ bù 😴',
                '🦸 Thứ 5 là ngày của những người hùng clear backlog!',
                '⏳ Đếm ngược tới cuối tuần: 1… nhưng đừng quên merge MR nha!',
                '🌈 Thứ 5 đẹp trời, code không bug, đời không lag!'
            ) }
            'Friday' { @(
                '🎉 TGIF! Thứ 6 rồi, merge xong là chill thôi!',
                '🍻 Thứ 6 — ngày đẹp nhất để đóng ticket và mở… kế hoạch cuối tuần!',
                '🕺 Thứ 6 nhảy múa! Nhưng đừng deploy chiều thứ 6 nha 🙅',
                '🏁 Về đích tuần này rồi! Cùng xem cả nhà cháy cỡ nào 🔥',
                '🌟 Thứ 6 tới rồi, ai chưa merge thì merge, ai merge rồi thì… tự thưởng!',
                '😎 Thứ 6 vibe: code nhẹ nhàng, tâm hồn bay bổng',
                '🎊 Thêm một tuần trôi qua, team mình vẫn đỉnh như thường lệ!',
                '🐙 Thứ 6 rồi mà vẫn còn sức đọc report à? Đỉnh thật sự!'
            ) }
            default { @(
                '👋 Cuối tuần mà vẫn đọc report? Tận tâm quá trời luôn!',
                '🛋️ Cuối tuần rồi, đọc xong report này thì đi chơi nha!'
            ) }
        })
        # Đổi câu theo tuần (8 câu mỗi thứ) để 2 tháng mới lặp lại; chạy lại trong ngày vẫn ra cùng câu.
        $weekIndex = [int][math]::Floor(($day.DayOfYear - 1) / 7)
        return $pool[$weekIndex % $pool.Count]
    }

    # ---------- Thành phần card ----------
    function New-StatusText([string]$name, [string]$cat, [string]$prefix = '') {
        $x = @{ weight = 'Bolder'; size = 'Small'; horizontalAlignment = 'Right' }
        if ($name -match '^(Done|Resolved)$') { $x.color = 'Good' }
        elseif ($name -eq 'Closed') { $x.isSubtle = $true }
        elseif ($cat -eq 'done') { $x.color = 'Good' }
        elseif ($cat -eq 'indeterminate') { $x.color = 'Warning' }
        elseif ($cat -eq 'new') { $x.color = 'Accent' }
        else { $x.color = 'Attention' }
        return (New-Text ($prefix + $name) $x)
    }

    # 3 cột: mã (cố định để các dòng thẳng hàng) | nội dung (giãn) | trạng thái (căn phải).
    function New-Row([string]$keyText, [object[]]$middle, [object[]]$right) {
        return @{
            type    = 'ColumnSet'
            spacing = 'Small'
            columns = @(
                @{ type = 'Column'; width = '72px'; items = @(New-Text $keyText @{ weight = 'Bolder' }) },
                @{ type = 'Column'; width = 'stretch'; items = $middle },
                @{ type = 'Column'; width = 'auto'; items = $right }
            )
        }
    }

    function Get-MrPeople($m, [string]$skipUser) {
        $parts = @()
        if ($m.author -and $m.author.username -ne $skipUser) { $parts += '👤 ' + (Get-ShortName $m.author.name) }
        $merger = if ($m.merge_user) { $m.merge_user } elseif ($m.merged_by) { $m.merged_by } else { $null }
        if ($merger -and $m.author -and $merger.username -ne $m.author.username) { $parts += 'merge: ' + (Get-ShortName $merger.name) }
        return $parts
    }

    function New-IssueRow($i, [object[]]$mrs) {
        $st = $i.fields.status
        $assignee = $i.fields.assignee
        $who = if ($assignee) { Get-ShortName $assignee.displayName } else { 'Chưa gán' }
        $skip = if ($assignee) { $assignee.name } else { '' }
        $mid = @(
            (New-Text (Escape-Md $i.fields.summary)),
            (New-Text "👤 $who" @{ size = 'Small'; isSubtle = $true; spacing = 'None' })
        )
        foreach ($e in $mrs) {
            $m = $e.Mr
            $parts = @('↳ [!{0}]({1}) {2} → {3}' -f $m.iid, $m.web_url, $m.source_branch, $m.target_branch)
            $parts += Get-MrPeople $m $skip
            if ($multiProject) { $parts += $e.Project.Split('/')[-1] }
            $mid += (New-Text ($parts -join ' · ') @{ size = 'Small'; spacing = 'None' })
        }
        return (New-Row ('[{0}]({1}/browse/{0})' -f $i.key, $jiraUrl) $mid @(New-StatusText $st.name $st.statusCategory.key))
    }

    function New-MrRow($e) {
        $m = $e.Mr
        $parts = @("$($m.source_branch) → $($m.target_branch)")
        $parts += Get-MrPeople $m ''
        if ($multiProject) { $parts += $e.Project.Split('/')[-1] }
        $mid = @(
            (New-Text (Escape-Md $m.title)),
            (New-Text ($parts -join ' · ') @{ size = 'Small'; isSubtle = $true; spacing = 'None' })
        )
        if ($e.JiraKeys.Count + $e.OtherKeys.Count -gt 0) {
            $right = @(foreach ($k in @($e.JiraKeys) + @($e.OtherKeys)) {
                $link = '[{0}]({1}/browse/{0}) ' -f $k, $jiraUrl
                if ($otherStatus.ContainsKey($k)) {
                    New-StatusText $otherStatus[$k].name $otherStatus[$k].statusCategory.key $link
                } elseif ($e.JiraKeys -contains $k) {
                    New-Text ($link + 'không tìm thấy') @{ size = 'Small'; color = 'Attention'; horizontalAlignment = 'Right' }
                } else {
                    # Project khác mà không đọc được (không quyền / Jira khác): vẫn coi là có ticket.
                    New-Text ('🎫 ' + $link.Trim()) @{ size = 'Small'; isSubtle = $true; horizontalAlignment = 'Right' }
                }
            })
        } else {
            $right = @(New-Text '⛔ không có ticket' @{ size = 'Small'; weight = 'Bolder'; color = 'Attention'; horizontalAlignment = 'Right' })
        }
        return (New-Row ('[!{0}]({1})' -f $m.iid, $m.web_url) $mid $right)
    }

    function New-Section([string]$title, [string]$hint, [string]$style, [object[]]$rows, [string]$emptyText) {
        $items = @(
            (New-Text $title @{ weight = 'Bolder'; size = 'Medium' }),
            (New-Text $hint @{ size = 'Small'; isSubtle = $true; spacing = 'None' })
        )
        if ($rows.Count -eq 0) {
            $items += (New-Text $emptyText @{ spacing = 'Small' })
        } else {
            for ($r = 1; $r -lt $rows.Count; $r++) { $rows[$r].separator = $true }
            $items += $rows
        }
        return @{ type = 'Container'; style = $style; spacing = 'Medium'; items = $items }
    }

    $cardTitle = "📋 Daily report $jiraProject — $titleRange"

    function Build-Card {
        $body = New-Object System.Collections.ArrayList
        $greeting = Get-Greeting $end
        if ($Test) { $greeting = '🧪 TEST · ' + $greeting }
        [void]$body.Add((New-Text $greeting @{ isSubtle = $true }))
        [void]$body.Add((New-Text $cardTitle @{ size = 'Large'; weight = 'Bolder'; spacing = 'None' }))

        $isEmpty = $issues.Count -eq 0 -and $allMrs.Count -eq 0
        $pct = Get-Pct $jiraGit.Count $issues.Count

        if ($isEmpty) {
            [void]$body.Add(@{ type = 'Container'; style = 'emphasis'; spacing = 'Medium'; items = @(
                (New-Text '😴 Yên ả — không có task done hay MR merged nào trong khoảng này.')
            ) })
        } else {
            # 1. KPI
            $hasPrev = $null -ne $prev
            $prevPct = if ($hasPrev) { Get-Pct ([int]$prev.linked) ([int]$prev.tasks) } else { $null }
            $prevPeople = if ($hasPrev) { @(Get-PeopleEntries $prev.people).Count } else { 0 }
            $pctColor = if ($null -eq $pct) { 'Default' } elseif ($pct -ge 80) { 'Good' } elseif ($pct -ge 50) { 'Warning' } else { 'Attention' }
            $pctText = if ($null -eq $pct) { '—' } else { "$pct%" }
            $pctDelta = if ($hasPrev -and $null -ne $pct -and $null -ne $prevPct) { $pct - $prevPct } else { $null }
            [void]$body.Add(@{ type = 'ColumnSet'; spacing = 'Medium'; columns = @(
                (New-Kpi "$($issues.Count)" 'task done' 'Good' $(if ($hasPrev) { $issues.Count - [int]$prev.tasks }) $hasPrev),
                (New-Kpi "$($allMrs.Count)" 'MR merged' 'Accent' $(if ($hasPrev) { $allMrs.Count - [int]$prev.mrs }) $hasPrev),
                (New-Kpi $pctText 'task có MR' $pctColor $pctDelta $hasPrev '%'),
                (New-Kpi "$($people.Count)" 'người góp' 'Default' $(if ($hasPrev) { $people.Count - $prevPeople }) $hasPrev)
            ) })

            $notes = @()
            if ($hasPrev) {
                $notes += '▲▼ so với báo cáo trước (' + (Format-Range ([datetime]::ParseExact($prev.start, 'yyyy-MM-dd', $null)) ([datetime]::ParseExact($prev.end, 'yyyy-MM-dd', $null))) + ')'
            }
            $series = @($history | Select-Object -Last 6) + @($current)
            if ($series.Count -ge 3) {
                $notes += '📈 Task ' + (Get-Spark @($series | ForEach-Object { [int]$_.tasks })) +
                    '  ·  MR ' + (Get-Spark @($series | ForEach-Object { [int]$_.mrs })) + "  ($($series.Count) báo cáo gần nhất)"
            }
            if ($notes.Count -gt 0) {
                [void]$body.Add((New-Text ($notes -join "`r`n") @{ size = 'Small'; isSubtle = $true; horizontalAlignment = 'Center'; spacing = 'Small' }))
            }

            # 4. Ăn mừng + MVP
            if ($issues.Count -gt 0 -and $jiraOnly.Count -eq 0 -and $gitOnly.Count -eq 0) {
                [void]$body.Add(@{ type = 'Container'; style = 'good'; spacing = 'Medium'; items = @(
                    (New-Text '🎉 Không task nào lạc trôi — task nào cũng có MR, MR nào cũng gắn task!' @{ weight = 'Bolder' })
                ) })
            }
            $mvp = Format-Mvp $people
            if ($mvp) { [void]$body.Add((New-Text "⭐ MVP: $mvp" @{ spacing = 'Medium' })) }

            # 2 + 3. Section có màu nền, mỗi task/MR là một dòng 3 cột
            [void]$body.Add((New-Section "🔗 Jira – GitLab · $($jiraGit.Count)" 'Task done có MR merged đi kèm' 'good' `
                @(foreach ($i in $jiraGit) { New-IssueRow $i $mrsOfIssue[$i.key] }) 'Chưa có cặp task – MR nào.'))
            # Jira only: chấp nhận được (task GD không cần commit) -> vàng.
            [void]$body.Add((New-Section "📝 Jira only · $($jiraOnly.Count)" 'Task done không có MR đi kèm — task GD / không cần code thì OK' `
                $(if ($jiraOnly.Count -gt 0) { 'warning' } else { 'emphasis' }) `
                @(foreach ($i in $jiraOnly) { New-IssueRow $i @() }) '✅ Task nào cũng có MR.'))
            # GitLab only: làm việc không có ticket là phạm rule DevOps -> đỏ.
            $noTicket = @($gitOnly | Where-Object { $_.JiraKeys.Count + $_.OtherKeys.Count -eq 0 }).Count
            $gitHint = if ($noTicket -gt 0) { "⛔ $noTicket MR không có ticket Jira — phạm rule DevOps, bổ sung ticket giúp nha!" } `
                       else { "MR có ticket nhưng chưa ghép được task $jiraProject đã done — kiểm tra lại trạng thái ticket" }
            $gitStyle = if ($noTicket -gt 0) { 'attention' } elseif ($gitOnly.Count -gt 0) { 'warning' } else { 'emphasis' }
            $gitIcon = if ($noTicket -gt 0) { '🚨' } else { '🔀' }
            [void]$body.Add((New-Section "$gitIcon GitLab only · $($gitOnly.Count)" $gitHint $gitStyle `
                @(foreach ($e in $gitOnly) { New-MrRow $e }) '✅ MR nào cũng có ticket. DevOps hài lòng 😎'))

            # Bảng đóng góp
            if ($people.Count -ge 2) {
                $facts = @(foreach ($p in (Get-Ranked $people)) { @{ title = (Get-ShortName $p.n); value = (Format-Stats $p.t $p.m) } })
                [void]$body.Add(@{ type = 'Container'; spacing = 'Medium'; separator = $true; items = @(
                    (New-Text '👥 Đóng góp' @{ weight = 'Bolder' }),
                    @{ type = 'FactSet'; spacing = 'Small'; facts = $facts }
                ) })
            }
        }

        # Tổng kết tuần (thứ 6)
        if ($week) {
            $items = @(
                (New-Text "📅 Tổng kết tuần · $($week.label)" @{ weight = 'Bolder'; size = 'Medium' }),
                (New-Text ("**{0}** task done · **{1}** MR merged" -f $week.tasks, $week.mrs) @{ spacing = 'Small' })
            )
            $wpct = Get-Pct ([int]$week.linked) ([int]$week.tasks)
            if ($null -ne $wpct) { $items[1].text += " · **$wpct%** task có MR" }
            $wmvp = Format-Mvp $week.people
            if ($wmvp) { $items += (New-Text "🏆 MVP tuần: $wmvp" @{ spacing = 'Small' }) }
            [void]$body.Add(@{ type = 'Container'; style = 'emphasis'; spacing = 'Medium'; items = $items })
        }

        return (New-AdaptiveCard @($body))
    }

    $card = Build-Card
    [IO.File]::WriteAllText((Join-Path $logDir 'card-for-designer.json'), ($card | ConvertTo-Json -Depth 30), $utf8)
    [IO.File]::WriteAllText((Join-Path $logDir 'last-summary.json'), ($current | ConvertTo-Json -Depth 10), $utf8)
    Send-Report $card $cardTitle 'last-payload'

    if (-not $DryRun -and -not $From -and -not $To -and -not $Test) {
        $stateData['lastEnd'] = $end.ToString('yyyy-MM-dd')
        $stateData['sentAt'] = (Get-Date).ToString('o')
        $stateData['history'] = @(@($history) + @($current) | Sort-Object end | Select-Object -Last 60)
        Save-State $statePath $stateData
    }

    # ---------- Card tổng kết sprint ----------
    # Chỉ đọc sprint sau khi daily đã gửi và đã lưu state: API Agile lỗi không chặn được daily; lần chạy lại
    # (nhánh "daily đã gửi") hoặc lần chạy hôm sau (mốc sprintCheckedUntil) sẽ gửi bù card sprint.
    $phase = 'sprint'
    [void](Invoke-SprintStep $start $end $true)
} catch {
    $err = $_
    $msg = $err.Exception.Message
    # Một số lỗi (vd RemoteException từ stderr của exe) có Message rỗng; TextBlock rỗng có thể làm Teams từ chối card.
    if ([string]::IsNullOrWhiteSpace($msg)) {
        $msg = "$($err.FullyQualifiedErrorId) [$($err.Exception.GetType().FullName)]"
        if (-not [string]::IsNullOrWhiteSpace("$($err.TargetObject)")) { $msg += " $($err.TargetObject)" }
    }
    Write-Host "LỖI ($phase): $msg"
    Write-Host $err.ScriptStackTrace
    # Thông báo lỗi chỉ gửi vào chat test, không bao giờ gửi lên group (kể cả khi đang chạy theo lịch).
    $errorWebhook = $null
    if ($cfg) {
        $errorWebhook = $cfg['TEAMS_TEST_WEBHOOK_URL']
    } elseif (-not $DryRun) {
        # Lỗi khi đọc cấu hình ($cfg chưa có): vẫn thử lấy webhook chat test từ .env chung để báo lỗi.
        try { $errorWebhook = (Read-DotEnv $sharedEnvPath)['TEAMS_TEST_WEBHOOK_URL'] }
        catch { Write-Host "Không đọc được .env chung để gửi thông báo lỗi: $($_.Exception.Message)" }
    }
    if ($DryRun) {
        Write-Host 'DryRun: không gửi thông báo lỗi lên Teams.'
    } elseif ([string]::IsNullOrWhiteSpace($errorWebhook)) {
        Write-Host 'Không có TEAMS_TEST_WEBHOOK_URL trong .env, bỏ qua gửi thông báo lỗi.'
    } else {
        $errText = if ($msg.Length -gt $MaxErrorTextChars) { $msg.Substring(0, $MaxErrorTextChars) + ' …' } else { $msg }
        $stackLines = @(($err.ScriptStackTrace -split "`r?`n") | Where-Object { $_ } | Select-Object -First $MaxErrorStackLines)
        $where = if ($stackLines.Count -gt 0) { $stackLines -join "`r`n" } else { $err.InvocationInfo.PositionMessage }
        # "<ScriptBlock>" có thể bị Teams hiểu là thẻ HTML và nuốt mất.
        $where = $where -replace '<', '‹' -replace '>', '›'
        $mode = if ($Test) { 'Test (-Test, chat test)' } else { 'Group (lịch chạy / gửi group)' }
        $argText = (@($PSBoundParameters.GetEnumerator() | ForEach-Object {
            if ($_.Value -is [switch]) { "-$($_.Key)" } else { "-$($_.Key) $($_.Value)" }
        }) -join ' ')
        if ($argText) { $mode += " · tham số: $argText" }
        $errTitle = switch ($phase) {
            'sprint' { "⚠️ [$Project] Card tổng kết sprint bị lỗi — daily ĐÃ gửi, chạy lại script (không -Force) hoặc dùng -SprintId" }
            'sprint-only' { "⚠️ [$Project] Card tổng kết sprint (-SprintId) bị lỗi" }
            default { "⚠️ [$Project] Daily report bị lỗi" }
        }
        try {
            Send-Teams $errorWebhook @{
                '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
                type      = 'AdaptiveCard'
                version   = '1.4'
                body      = @(
                    (New-Text $errTitle @{ weight = 'Bolder'; color = 'Attention' }),
                    (New-Text (Escape-Md $errText)),
                    (New-Text ("📍 Vị trí:`r`n" + (Escape-Md $where)) @{ size = 'Small'; fontType = 'Monospace' }),
                    (New-Text (Escape-Md "Chế độ: $mode") @{ size = 'Small'; isSubtle = $true }),
                    (New-Text "Log: $logPath" @{ size = 'Small'; isSubtle = $true })
                )
            }
            Write-Host 'Đã gửi thông báo lỗi vào chat test.'
        } catch { Write-Host "Không gửi được thông báo lỗi lên Teams: $($_.Exception.Message)" }
    }
    exit 1
} finally {
    Stop-Transcript | Out-Null
}
