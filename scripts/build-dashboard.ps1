# build-dashboard.ps1 - rebuild dev-site-crawls/index.html from existing data.
#
# Output layout: one collapsible <details> row per crawl date, newest date on
# top; within a day, pages with real changes come first (noise entries last),
# then a collapsed "failed" group and a collapsed "no change" group. Only the
# newest day is expanded by default. Each change entry gets rule-based tags
# (blog / release / new product / docs / AI / event / ...) and a short bullet
# brief distilled from the added lines of its diff file.
#
# Data sources:
#   <OutputRoot>/<company>/<site>[/pages/<slug>]/changes/YYYY-MM-DD.md   (diffs)
#   <OutputRoot>/crawl-YYYY-MM-DD.log                                   (no-change/failed)
#
# Called automatically at the end of every crawl run; also runnable standalone:
#   powershell -ExecutionPolicy Bypass -File build-dashboard.ps1
#
# PowerShell 5 compatible (ASCII-only comments; all Chinese UI strings live in
# config/dashboard-strings.json and are read with explicit UTF-8 decoding).

param(
    [string]$OutputRoot = (Join-Path $PSScriptRoot "..\..\..\..\dev-site-crawls")
)

$ErrorActionPreference = 'Stop'

$OutputRoot = (Resolve-Path $OutputRoot).Path
$Utf8 = [System.Text.UTF8Encoding]::new($false)

# ---- UI strings (UTF-8 JSON so this script file itself stays ASCII) ----
$stringsFile = Join-Path $PSScriptRoot "..\config\dashboard-strings.json"
$S = [System.IO.File]::ReadAllText($stringsFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json

function Escape-Html {
    param([string]$s)
    if (-not $s) { return '' }
    $s = $s -replace '&', '&amp;'
    $s = $s -replace '<', '&lt;'
    $s = $s -replace '>', '&gt;'
    return $s
}

# External-link icon (SVG) that opens the changed page itself in a new tab
function Get-PageLinkHtml {
    param([string]$Url)
    if (-not $Url) { return '' }
    $icon = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><polyline points="15 3 21 3 21 9"/><line x1="10" y1="14" x2="21" y2="3"/></svg>'
    return ('<a class="urllink" href="' + (Escape-Html $Url) + '" target="_blank" rel="noopener" title="' + (Escape-Html $Url) + '">' + $icon + '</a>')
}

# ---- Rule-based tagging: returns tag keys; display names come from $S.tags ----
function Get-TagKeys {
    param([string]$Display, [string]$Url, [string]$AddedText, [int]$AddedCount, [bool]$IsInitial)
    $t = New-Object System.Collections.Generic.List[string]
    if ($IsInitial) { $t.Add('initial') }

    $pathText = "$Display $Url"
    if ($pathText -match '(?i)blog') { $t.Add('blog') }

    if ($AddedText -match '(?i)\b(release notes?|released|hotfix|patch notes)\b' -or
        $AddedText -match '(?i)\b(CUDA|ROCm|cuDNN|CANN|TensorRT|DevKit)\s+\d' -or
        $AddedText -match '(?i)\bversion\s+v?\d') { $t.Add('release') }

    if ($AddedText -match '(?i)\b(announc\w*|introduc\w*|launch\w*|now available|generally available)\b' -or
        $AddedText -match '(?i)\bnew\s+(product|tool|sdk|platform|service|feature)\b') { $t.Add('newproduct') }

    # Docs-site hosts or bulk index changes count as documentation churn
    if ($Url -match '(?i)://docs?\.|/document|/docs/|/overview' -or $AddedCount -ge 40) { $t.Add('docs') }

    # Model updates: named model releases/deprecations & model catalog changes
    if ($AddedText -match '(?i)\b(Llama|Gemini|DeepSeek|Qwen|Mistral|Mixtral|Kimi|Grok)[ -]?\d' -or
        $AddedText -match '(?i)\bClaude\s+(\w+\s+)?\d|\b(chat)?gpt\b|\bo[134]\b' -or
        $AddedText -match '(?i)\b(LLM|checkpoint|model weights)s?\s+(releas\w+|updat\w+|available|version)' -or
        $AddedText -match '(?i)\b(new|added|latest|updated?|available|released?|launch\w*|deprecat\w*|retir\w*|sunset|introduc\w*|announc\w*)\s+(a\s+|an\s+|the\s+)?(new\s+|foundation\s+|language\s+|vision\s+|multimodal\s+|embedding\s+|text-to-image\s+|video\s+)?(AI\s+)?models?\b' -or
        $AddedText -match '(?i)(deprecat\w+|retir\w+|sunset).{0,40}\bmodels?\b' -or
        $AddedText -match '(?i)\bmodels?\s+(list|catalog|names?|pricing)\b') { $t.Add('model') }
    # Community AI capabilities developers can use: MCP, agents, retrieval/RAG, tool calling
    elseif ($AddedText -match '(?i)\bMCP\b|model context protocol|\bagents?\b|agentic|tool\s?(use|calling)|function calling|\bRAG\b|retrieval|vector (search|database)|knowledge base|plugins?\b') { $t.Add('aicommunity') }
    # AI products: AI platform/infra stack & GPU AI features (NIM, TensorRT, Megatron, DLSS ...)
    elseif ($AddedText -match '(?i)\b(AI|LLM|NIM|inference|multimodal|Riva|NeMo|TAO|Megatron|Cosmos|TensorRT|transformer|fine-tun\w*|embedd\w*|machine learning|Copilot|DLSS|G-Assist)\b') { $t.Add('aiproduct') }

    if ($AddedText -match '(?i)\b(webinar|summit|conference|workshop|hackathon|GTC|CES)\b') { $t.Add('event') }

    # Marketing/careers noise, ranked last within a day
    if ($Display -match '(?i)careers|jobs|shopping|deals' -or
        $AddedText -match '(?i)best time to buy|gaming deals|working at amd') { $t.Add('noise') }

    if ($t.Count -eq 0) { $t.Add('news') }
    return $t
}

# ---- Distill a short brief from added lines: keep title-ish lines only ----
function Get-Brief {
    param([string[]]$AddedLines, [int]$Max = 5)
    $brief = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $monthRe = '^(January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},\s*\d{4}$'
    foreach ($l in $AddedLines) {
        $t = $l.Trim()
        if ($t.Length -lt 15 -or $t.Length -gt 170) { continue }
        if ($t -match $monthRe) { continue }
        # Skip pure numbers/dates/garbled lines: need real words (latin or CJK)
        if ($t -notmatch '[A-Za-z]{3}') { if ($t -notmatch '[\u4e00-\u9fff]{4}') { continue } }
        $k = $t.ToLower()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $brief.Add($t)
        if ($brief.Count -ge $Max) { break }
    }
    return $brief
}

# ================= 1. Collect change entries from changes/*.md =================
$entries = New-Object System.Collections.Generic.List[object]
$mdFiles = @(Get-ChildItem -Path $OutputRoot -Recurse -Filter '*.md' | Where-Object { $_.FullName -match '\\changes\\' })
foreach ($f in $mdFiles) {
    $rel = $f.FullName.Substring($OutputRoot.Length + 1)
    $date = $f.BaseName
    if ($date -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }
    $siteRel = $rel -replace '\\changes\\[^\\]+\.md$', ''
    $isSub = ($siteRel -match '\\pages\\')

    $raw = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    $display = $siteRel -replace '\\', '/'
    $url = ''
    $addedCount = 0
    $removedCount = 0
    $isInitial = $false
    $addedLines = New-Object System.Collections.Generic.List[string]
    $inAdded = $false

    $lines = $raw -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($i -eq 0) {
            if ($l -match '^# Initial snapshot for (.+?) on ') { $isInitial = $true; $display = $Matches[1] }
            elseif ($l -match '^# Diff for (.+?) on ') { $display = $Matches[1] }
        }
        if ($l -match '^- URL:\s*(.+)$') { $url = $Matches[1].Trim() }
        if ($l -match '^- Added:\s*(\d+)') { $addedCount = [int]$Matches[1] }
        if ($l -match '^- Removed:\s*(\d+)') { $removedCount = [int]$Matches[1] }
        if ($l -match '^## Added lines') { $inAdded = $true; continue }
        if ($l -match '^## ') { $inAdded = $false; continue }
        if ($inAdded -and $l.StartsWith('+ ')) { $addedLines.Add($l.Substring(2)) }
    }

    $tagKeys = Get-TagKeys -Display $display -Url $url -AddedText (($addedLines | Select-Object -First 150) -join ' ') -AddedCount $addedCount -IsInitial $isInitial
    $briefLines = @()
    if ($isInitial) {
        $briefLines = @($S.initialNote)
    }
    else {
        $briefLines = @(Get-Brief -AddedLines $addedLines)
    }

    $entries.Add([pscustomobject]@{
        Date = $date; Display = $display; Url = $url
        Added = $addedCount; Removed = $removedCount
        Tags = @($tagKeys); Brief = @($briefLines)
        IsInitial = $isInitial; IsSub = $isSub
        Noise = (@($tagKeys) -contains 'noise')
        DiffRel = ($rel -replace '\\', '/')
    })
}

# ================= 2. Parse logs for no-change / failed pages per day =================
$logDays = @{}
$logFiles = @(Get-ChildItem -Path $OutputRoot -Filter 'crawl-*.log')
foreach ($lf in $logFiles) {
    $d = $lf.BaseName -replace '^crawl-', ''
    if ($d -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }
    if (-not $logDays.ContainsKey($d)) {
        $logDays[$d] = @{ NoChange = @{}; Failed = @{} }
    }
    foreach ($l in [System.IO.File]::ReadAllLines($lf.FullName)) {
        if ($l -match 'no change \[(.+?)\]') { $logDays[$d].NoChange[$Matches[1]] = $true }
        elseif ($l -match 'ERROR fetching (\S+)') { $logDays[$d].Failed[$Matches[1]] = $true }
    }
}

# url -> "company/name" map (to label failed seed pages nicely)
# NOTE: loop var must NOT be $s/$S - $S is the strings object (PS is
# case-insensitive, a $s loop var here silently clobbers every $S.xxx below)
$sitesFile = Join-Path $PSScriptRoot "..\config\sites.json"
$urlToSite = @{}
if (Test-Path $sitesFile) {
    $cfg = [System.IO.File]::ReadAllText($sitesFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($st in $cfg.sites) { $urlToSite[[string]$st.url] = "$($st.company)/$($st.name)" }
}

# ================= 3. Assemble HTML =================
$allDates = New-Object System.Collections.Generic.List[string]
foreach ($e in $entries) { if (-not $allDates.Contains($e.Date)) { $allDates.Add($e.Date) } }
foreach ($k in $logDays.Keys) { if (-not $allDates.Contains($k)) { $allDates.Add($k) } }
$sortedDates = @($allDates | Sort-Object -Descending)

$totalChanges = $entries.Count
$companySet = @{}
foreach ($e in $entries) {
    # DiffRel starts with the company dir ("company/site/..."), reliable even
    # for old-format diffs whose Display header lacks the company prefix
    $companySet[(($e.DiffRel -split '/')[0])] = $true
}

$tagColor = @{
    blog = 'tag-blog'; release = 'tag-release'; newproduct = 'tag-newproduct'
    docs = 'tag-docs'; model = 'tag-model'; aicommunity = 'tag-aicommunity'
    aiproduct = 'tag-aiproduct'; event = 'tag-event'; news = 'tag-news'
    initial = 'tag-initial'; noise = 'tag-noise'
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('<!DOCTYPE html>')
[void]$sb.AppendLine('<html lang="zh-CN">')
[void]$sb.AppendLine('<head>')
[void]$sb.AppendLine('<meta charset="utf-8">')
[void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
[void]$sb.AppendLine(('<title>' + (Escape-Html $S.title) + '</title>'))
[void]$sb.AppendLine('<style>')
[void]$sb.AppendLine(@'
body{font-family:"Segoe UI",system-ui,-apple-system,"Microsoft YaHei",sans-serif;background:#f2f3f7;margin:0;color:#1f2328}
header{background:linear-gradient(135deg,#16213e,#0f3460);color:#fff;padding:28px 32px}
header h1{margin:0 0 6px;font-size:24px}
header p{margin:0;opacity:.75;font-size:13px}
.meta{display:flex;gap:18px;margin-top:14px;font-size:13px;opacity:.9}
.meta b{font-size:18px;font-weight:600}
.wrap{max-width:1000px;margin:20px auto 60px;padding:0 16px}
.day{background:#fff;border-radius:12px;box-shadow:0 1px 4px rgba(15,23,42,.08);margin-bottom:14px;overflow:hidden}
.day>summary{cursor:pointer;padding:16px 22px;font-size:16px;font-weight:600;list-style:none;display:flex;align-items:center;flex-wrap:wrap;gap:8px}
.day>summary::-webkit-details-marker{display:none}
.day>summary .arrow{transition:transform .2s;font-size:12px;color:#888}
.day[open]>summary .arrow{transform:rotate(90deg)}
.dates{color:#16213e}
.badge{display:inline-block;padding:3px 10px;border-radius:12px;font-size:12px;font-weight:500}
.b-changed{background:#e1f0ff;color:#0a5bb5}
.b-nochange{background:#eef0f3;color:#6b7280}
.b-failed{background:#ffe3e3;color:#b91c1c}
.site{border-top:1px solid #eef0f3;padding:13px 22px}
.site.sub{background:#fafbfc}
.site-head{display:flex;align-items:center;flex-wrap:wrap;gap:6px}
.site-name{font-weight:600;font-size:14.5px;color:#16213e}
.site-count{font-size:12.5px;color:#6b7280}
.tag{display:inline-block;padding:2px 9px;border-radius:11px;font-size:11.5px;font-weight:500;white-space:nowrap}
.tag-blog{background:#e3f0ff;color:#0a5bb5}
.tag-release{background:#ffe9d6;color:#b35900}
.tag-newproduct{background:#f3e8ff;color:#7c3aed}
.tag-docs{background:#d9f2ee;color:#0d7a68}
.tag-aicommunity{background:#e4f8d8;color:#2e7d32}
.tag-aiproduct{background:#cffafe;color:#0e7490}
.tag-model{background:#fde2ec;color:#be1867}
.tag-event{background:#fff3c4;color:#8a6d00}
.tag-news{background:#ede7f6;color:#5e35b1}
.tag-initial{background:#e8e8e8;color:#555}
.tag-noise{background:#f0f0f0;color:#9ca3af}
.tag-sub{background:#f0f4ff;color:#64748b;border:1px solid #e2e8f0}
a.difflink{font-size:12px;color:#0a5bb5;text-decoration:none;margin-left:8px;white-space:nowrap}
a.difflink:hover{text-decoration:underline}
a.urllink{display:inline-flex;align-items:center;margin-left:auto;color:#8a94a3;text-decoration:none;line-height:1}
a.urllink:hover{color:#0a5bb5}
a.urllink svg{width:14px;height:14px;display:block}
.brief{margin:8px 0 0 0;padding-left:22px;color:#374151;font-size:13.5px}
.brief li{margin:4px 0;line-height:1.45}
.brief.none{list-style:none;padding-left:0;color:#9ca3af;font-style:italic}
.group{border-top:1px solid #eef0f3;padding:10px 22px;background:#fafbfc}
.group summary{cursor:pointer;font-size:13px;color:#6b7280}
.group .items{margin-top:8px;display:flex;flex-wrap:wrap;gap:6px}
.group .item{font-size:12px;color:#4b5563;background:#eef0f3;padding:2px 8px;border-radius:8px}
.empty{color:#9ca3af;text-align:center;padding:40px;font-size:14px}
footer{text-align:center;color:#9ca3af;font-size:12px;padding:20px}
'@)
[void]$sb.AppendLine('</style>')
[void]$sb.AppendLine('</head>')
[void]$sb.AppendLine('<body>')

[void]$sb.AppendLine('<header>')
[void]$sb.AppendLine(('<h1>' + (Escape-Html $S.title) + '</h1>'))
[void]$sb.AppendLine(('<p>' + (Escape-Html $S.subtitle) + '</p>'))
[void]$sb.AppendLine('<div class="meta">')
[void]$sb.AppendLine(('<div><b>' + $sortedDates.Count + '</b> ' + (Escape-Html $S.totalDays) + '</div>'))
[void]$sb.AppendLine(('<div><b>' + $totalChanges + '</b> ' + (Escape-Html $S.totalChanges) + '</div>'))
[void]$sb.AppendLine(('<div><b>' + $companySet.Count + '</b> ' + (Escape-Html $S.companies) + '</div>'))
[void]$sb.AppendLine('</div></header>')

[void]$sb.AppendLine('<div class="wrap">')

$dayIndex = 0
foreach ($date in $sortedDates) {
    $dayEntries = @($entries | Where-Object { $_.Date -eq $date })
    $noChangeNames = @()
    $failedNames = @()
    if ($logDays.ContainsKey($date)) {
        $noChangeNames = @($logDays[$date].NoChange.Keys | Sort-Object)
        $failedNames = @($logDays[$date].Failed.Keys | Sort-Object)
    }

    # changed first (most added lines first, noise last)
    $changed = @($dayEntries | Where-Object { -not $_.Noise } | Sort-Object -Property @{ Expression = 'Added'; Descending = $true })
    $noise = @($dayEntries | Where-Object { $_.Noise })

    $openAttr = ''
    if ($dayIndex -eq 0) { $openAttr = ' open' }

    [void]$sb.AppendLine(('<details class="day"' + $openAttr + '>'))
    [void]$sb.AppendLine('<summary>')
    [void]$sb.AppendLine('<span class="arrow">&#9654;</span>')
    [void]$sb.AppendLine(('<span class="dates">' + $date + '</span>'))
    if ($dayEntries.Count -gt 0) {
        [void]$sb.AppendLine(('<span class="badge b-changed">' + $dayEntries.Count + ' ' + (Escape-Html $S.changedBadge) + '</span>'))
    }
    if ($noChangeNames.Count -gt 0) {
        [void]$sb.AppendLine(('<span class="badge b-nochange">' + $noChangeNames.Count + ' ' + (Escape-Html $S.noChangeBadge) + '</span>'))
    }
    if ($failedNames.Count -gt 0) {
        [void]$sb.AppendLine(('<span class="badge b-failed">' + $failedNames.Count + ' ' + (Escape-Html $S.failedBadge) + '</span>'))
    }
    [void]$sb.AppendLine('</summary>')

    foreach ($e in $changed) {
        [void]$sb.AppendLine(('<div class="site' + ($(if ($e.IsSub) { ' sub' } else { '' })) + '">'))
        [void]$sb.AppendLine('<div class="site-head">')
        [void]$sb.AppendLine(('<span class="site-name">' + (Escape-Html $e.Display) + '</span>'))
        if ($e.IsSub) { [void]$sb.AppendLine(('<span class="tag tag-sub">' + (Escape-Html $S.subpageMark) + '</span>')) }
        foreach ($tk in $e.Tags) {
            if ($tk -eq 'initial') { $label = $S.initialTag } else { $label = $S.tags.$tk }
            [void]$sb.AppendLine(('<span class="tag ' + $tagColor[$tk] + '">' + (Escape-Html $label) + '</span>'))
        }
        if ($e.IsInitial) {
            [void]$sb.AppendLine('<span class="site-count">baseline</span>')
        }
        else {
            [void]$sb.AppendLine(('<span class="site-count">+' + $e.Added + ' / -' + $e.Removed + '</span>'))
        }
        [void]$sb.AppendLine((Get-PageLinkHtml $e.Url))
        [void]$sb.AppendLine(('<a class="difflink" href="' + (Escape-Html $e.DiffRel) + '">' + (Escape-Html $S.viewDiff) + ' &rarr;</a>'))
        [void]$sb.AppendLine('</div>')
        if ($e.Brief.Count -gt 0) {
            [void]$sb.AppendLine('<ul class="brief">')
            foreach ($b in $e.Brief) { [void]$sb.AppendLine('<li>' + (Escape-Html $b) + '</li>') }
            [void]$sb.AppendLine('</ul>')
        }
        [void]$sb.AppendLine('</div>')
    }

    foreach ($e in $noise) {
        [void]$sb.AppendLine(('<div class="site sub"><div class="site-head">'))
        [void]$sb.AppendLine(('<span class="site-name">' + (Escape-Html $e.Display) + '</span>'))
        if ($e.IsSub) { [void]$sb.AppendLine(('<span class="tag tag-sub">' + (Escape-Html $S.subpageMark) + '</span>')) }
        [void]$sb.AppendLine(('<span class="tag tag-noise">' + (Escape-Html $S.tags.noise) + '</span>'))
        [void]$sb.AppendLine(('<span class="site-count">+' + $e.Added + ' / -' + $e.Removed + '</span>'))
        [void]$sb.AppendLine((Get-PageLinkHtml $e.Url))
        [void]$sb.AppendLine(('<a class="difflink" href="' + (Escape-Html $e.DiffRel) + '">' + (Escape-Html $S.viewDiff) + ' &rarr;</a>'))
        [void]$sb.AppendLine('</div></div>')
    }

    if ($failedNames.Count -gt 0) {
        [void]$sb.AppendLine('<details class="group">')
        [void]$sb.AppendLine(('<summary>' + $failedNames.Count + ' ' + (Escape-Html $S.failedGroupTitle) + '</summary>'))
        [void]$sb.AppendLine('<div class="items">')
        foreach ($u in $failedNames) {
            $label = $u
            if ($urlToSite.ContainsKey($u)) { $label = $urlToSite[$u] }
            [void]$sb.AppendLine(('<span class="item">' + (Escape-Html $label) + '</span>'))
        }
        [void]$sb.AppendLine('</div></details>')
    }

    if ($noChangeNames.Count -gt 0) {
        [void]$sb.AppendLine('<details class="group">')
        [void]$sb.AppendLine(('<summary>' + $noChangeNames.Count + ' ' + (Escape-Html $S.noChangeGroupTitle) + '</summary>'))
        [void]$sb.AppendLine('<div class="items">')
        foreach ($n in $noChangeNames) { [void]$sb.AppendLine(('<span class="item">' + (Escape-Html $n) + '</span>')) }
        [void]$sb.AppendLine('</div></details>')
    }

    if ($dayEntries.Count -eq 0 -and $noChangeNames.Count -eq 0 -and $failedNames.Count -eq 0) {
        [void]$sb.AppendLine(('<div class="empty">' + (Escape-Html $S.noData) + '</div>'))
    }

    [void]$sb.AppendLine('</details>')
    $dayIndex = $dayIndex + 1
}

if ($sortedDates.Count -eq 0) {
    [void]$sb.AppendLine(('<div class="empty">' + (Escape-Html $S.emptyHint) + '</div>'))
}

[void]$sb.AppendLine('</div>')
[void]$sb.AppendLine(('<footer>' + (Escape-Html $S.generatedAt) + ': ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '</footer>'))
[void]$sb.AppendLine('</body>')
[void]$sb.AppendLine('</html>')

$htmlFile = Join-Path $OutputRoot 'index.html'
[System.IO.File]::WriteAllText($htmlFile, $sb.ToString(), $Utf8)
Write-Output ("Dashboard -> " + $htmlFile)
