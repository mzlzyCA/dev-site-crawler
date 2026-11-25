# dev-site-crawler / crawl.ps1
# Daily crawl of vendor developer portals: snapshot + diff + change screenshots.
# Each site optionally crawls sub-pages linked from the seed page
# (scope: same host by default, or the registrable domain).
# PowerShell 5 compatible (ASCII-only comments, no backtick continuations)

param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "..\config\sites.json"),
    [string]$OutputRoot = (Join-Path $PSScriptRoot "..\..\..\..\dev-site-crawls"),
    [switch]$Verbose
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config not found: $ConfigPath"
    exit 1
}
$ConfigPath = (Resolve-Path $ConfigPath).Path

if (-not (Test-Path $OutputRoot)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}
$OutputRoot = (Resolve-Path $OutputRoot).Path

$today = Get-Date -Format "yyyy-MM-dd"
$now = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$logFile = Join-Path $OutputRoot "crawl-$today.log"

function Write-Log {
    param([string]$Message)
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$stamp] $Message"
    if ($Verbose) { Write-Output $line }
    Add-Content -Path $logFile -Value $line
}

function Convert-HtmlToText {
    param([string]$Html)
    if (-not $Html) { return "" }
    $Html = [regex]::Replace($Html, '(?is)<(script|style|noscript)[^>]*>.*?</\1>', '')
    $Html = [regex]::Replace($Html, '(?s)<!--.*?-->', '')
    $Html = [regex]::Replace($Html, '(?i)</?(p|div|li|h[1-6]|tr|br|hr|section|article|header|footer|nav|main|table|thead|tbody|tfoot|td|th|ul|ol|dl|dd|dt|figure|figcaption|blockquote|pre)[^>]*>', "`n")
    $Html = [regex]::Replace($Html, '(?s)<[^>]+>', '')
    $Html = $Html -replace '&nbsp;', ' ' -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&#39;', "'" -replace '&apos;', "'"
    # Normalize invisible chars: NBSP -> space, zero-width / BOM stripped
    # (prevents fake diffs when a page only flips invisible characters)
    $Html = $Html -replace ([string][char]0x00A0), ' '
    $Html = $Html -replace ([string][char]0x200B), ''
    $Html = $Html -replace ([string][char]0xFEFF), ''
    $Html = [regex]::Replace($Html, "(\r?\n){3,}", "`n`n")
    $Html = [regex]::Replace($Html, "[ \t]{2,}", " ")
    return $Html.Trim()
}

function Get-PageContent {
    param([string]$Url)
    # intel.cn etc. sometimes return HTTP 200 with an EMPTY body under rate
    # limiting; that must not fail silently. Retry once with a backoff.
    $lastError = "unknown error"
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $headers = @{
                'User-Agent'      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
                'Accept'          = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
                'Accept-Language' = 'en-US,en;q=0.9,zh-CN;q=0.8'
            }
            $response = Invoke-WebRequest -Uri $Url -Headers $headers -TimeoutSec 60 -UseBasicParsing -MaximumRedirection 10
            # PS5 guesses charset from response headers and often guesses wrong, which
            # produced mojibake baselines and false-positive diffs. Decode the raw bytes
            # ourselves: UTF-8 first, GB18030 fallback for non-UTF-8 Chinese pages.
            if ($response.RawContentStream -and $response.RawContentStream.Length -gt 0) {
                $bytes = $response.RawContentStream.ToArray()
                $body = [System.Text.Encoding]::UTF8.GetString($bytes)
                $badUtf8 = ([regex]::Matches($body, ([string][char]0xFFFD))).Count
                if ($badUtf8 -gt 10) {
                    $gbBody = [System.Text.Encoding]::GetEncoding('GB18030').GetString($bytes)
                    $badGb = ([regex]::Matches($gbBody, ([string][char]0xFFFD))).Count
                    if ($badGb -lt $badUtf8) { $body = $gbBody }
                }
                if ($body.Length -gt 0 -and $body[0] -eq [char]0xFEFF) { $body = $body.Substring(1) }
                if ($body.Trim().Length -gt 0) { return $body }
                $lastError = "empty body after decode (status $($response.StatusCode))"
            }
            else {
                $lastError = "empty response body (status $($response.StatusCode))"
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }
        if ($attempt -lt 2) { Start-Sleep -Seconds 8 }
    }
    Write-Log "  ERROR fetching $Url : $lastError"
    return $null
}

function Get-Diff {
    param([string]$OldContent, [string]$NewContent)
    $oldLines = $OldContent -split "`r?`n"
    $newLines = $NewContent -split "`r?`n"

    $oldCount = @{}
    foreach ($l in $oldLines) {
        $key = $l.Trim()
        if (-not $key) { continue }
        if ($oldCount.ContainsKey($key)) { $oldCount[$key] = $oldCount[$key] + 1 } else { $oldCount[$key] = 1 }
    }
    $newCount = @{}
    foreach ($l in $newLines) {
        $key = $l.Trim()
        if (-not $key) { continue }
        if ($newCount.ContainsKey($key)) { $newCount[$key] = $newCount[$key] + 1 } else { $newCount[$key] = 1 }
    }

    $added = New-Object System.Collections.Generic.List[string]
    $addedCount = @{}
    foreach ($l in $newLines) {
        $key = $l.Trim()
        if (-not $key) { continue }
        $oldHas = 0
        if ($oldCount.ContainsKey($key)) { $oldHas = $oldCount[$key] }
        $newHas = 0
        if ($addedCount.ContainsKey($key)) { $newHas = $addedCount[$key] }
        $target = $newCount[$key] - $oldHas
        if ($newHas -lt $target) {
            $added.Add("+ $l")
            if ($addedCount.ContainsKey($key)) { $addedCount[$key] = $addedCount[$key] + 1 } else { $addedCount[$key] = 1 }
        }
    }

    $removed = New-Object System.Collections.Generic.List[string]
    $removedCount = @{}
    foreach ($l in $oldLines) {
        $key = $l.Trim()
        if (-not $key) { continue }
        $newHas = 0
        if ($newCount.ContainsKey($key)) { $newHas = $newCount[$key] }
        $oldHas = 0
        if ($removedCount.ContainsKey($key)) { $oldHas = $removedCount[$key] }
        $target = $oldCount[$key] - $newHas
        if ($oldHas -lt $target) {
            $removed.Add("- $l")
            if ($removedCount.ContainsKey($key)) { $removedCount[$key] = $removedCount[$key] + 1 } else { $removedCount[$key] = 1 }
        }
    }

    $result = @{ Added = $added; Removed = $removed }
    return $result
}

# Locate a headless-capable Chromium browser (Edge ships with Windows 10/11,
# Chrome is the fallback). Cached at script scope.
function Find-BrowserPath {
    $candidates = New-Object System.Collections.Generic.List[string]
    if (${env:ProgramFiles(x86)}) {
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'))
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'))
    }
    if ($env:ProgramFiles) {
        $candidates.Add((Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'))
        $candidates.Add((Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'))
    }
    if ($env:LOCALAPPDATA) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'))
    }
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

# Screenshot a URL with headless Edge/Chrome. --virtual-time-budget lets
# JS-heavy pages settle before capture; the isolated --user-data-dir avoids
# clashing with an interactive browser session.
function Take-Screenshot {
    param([string]$Url, [string]$OutPng)
    if (-not $script:BrowserExe) {
        Write-Log "  WARN screenshot skipped: no Edge/Chrome found"
        return $false
    }
    if (Test-Path $OutPng) { Remove-Item $OutPng -Force }
    $profileDir = Join-Path $env:TEMP 'devsite-shot-profile'
    $argLine = '--headless --disable-gpu --hide-scrollbars --user-data-dir="' + $profileDir + '" --screenshot="' + $OutPng + '" --window-size=1280,2400 --virtual-time-budget=10000 "' + $Url + '"'
    try {
        Start-Process -FilePath $script:BrowserExe -ArgumentList $argLine -WindowStyle Hidden -Wait | Out-Null
    }
    catch {
        Write-Log "  WARN screenshot failed: $($_.Exception.Message)"
        return $false
    }
    if ((Test-Path $OutPng) -and ((Get-Item $OutPng).Length -gt 0)) {
        Write-Log "  -> screenshot -> $OutPng"
        return $true
    }
    Write-Log "  WARN screenshot produced no file"
    return $false
}

# Extract same-scope sub-page links from a page's HTML.
# Scope 'host'   -> only links on the seed page's host (e.g. developer.nvidia.com)
# Scope 'domain' -> links anywhere under the registrable domain (e.g. nvidia.com)
# Links are deduped, junk-filtered, sorted (deterministic day-to-day) and returned.
function Get-SubLinks {
    param([string]$Html, [string]$BaseUrl, [string]$SeedUrl, [string]$Scope)

    $baseUri = New-Object System.Uri($BaseUrl)
    $seedUri = New-Object System.Uri($SeedUrl)
    $seedHost = $baseUri.Host.ToLower()
    $labels = $seedHost -split '\.'
    $regDomain = $seedHost
    if ($labels.Count -ge 2) { $regDomain = ($labels[-2..-1] -join '.') }

    $links = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    $hrefMatches = [regex]::Matches($Html, 'href\s*=\s*["'']([^"'']+)["'']')
    foreach ($m in $hrefMatches) {
        $href = $m.Groups[1].Value.Trim()
        if (-not $href) { continue }
        # Decode HTML entities commonly left in href values (&amp; above all)
        $href = $href -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&#39;', "'"
        if ($href -match '^(?i)(javascript|mailto|tel|data):') { continue }
        if ($href.StartsWith('#')) { continue }
        $hashIndex = $href.IndexOf('#')
        if ($hashIndex -ge 0) { $href = $href.Substring(0, $hashIndex) }
        if (-not $href) { continue }
        if ($href -match '(?i)\.(png|jpe?g|gif|svg|css|js|json|xml|pdf|zip|gz|tar|exe|msi|dmg|pkg|mp4|webm|ico|woff2?|ttf|eot|txt|rss|atom)(\?|$)') { continue }
        if ($href -match '(?i)/(privacy|legal|terms|login|signin|signup|register|careers|help|contact)(/|$)') { continue }
        try {
            $abs = New-Object System.Uri($baseUri, $href)
        }
        catch { continue }
        if ($abs.Scheme -ne 'http' -and $abs.Scheme -ne 'https') { continue }
        $h = $abs.Host.ToLower()
        $inScope = $false
        if ($Scope -eq 'domain') {
            if ($h -eq $regDomain -or $h.EndsWith('.' + $regDomain)) { $inScope = $true }
        }
        else {
            if ($h -eq $seedHost) { $inScope = $true }
        }
        if (-not $inScope) { continue }
        $u = $abs.AbsoluteUri
        if ($u -eq $seedUri.AbsoluteUri) { continue }
        if (-not $seen.ContainsKey($u)) {
            $seen[$u] = $true
            $links.Add($u)
        }
    }
    $links.Sort()
    return $links
}

# URL -> short safe directory name (host + path, non-alnum collapsed to '-')
function Convert-ToSlug {
    param([string]$Url)
    $u = New-Object System.Uri($Url)
    $s = $u.Host + $u.AbsolutePath
    $s = $s -replace '[^A-Za-z0-9]+', '-'
    $s = $s.Trim('-')
    if ($s.Length -gt 70) { $s = $s.Substring(0, 70) }
    if (-not $s) { $s = 'root' }
    return $s.ToLower()
}

# Process one page: snapshot, diff vs latest.md, write changes/<today>.md,
# screenshot the page when it actually changed, update the baseline.
# $PageDir holds snapshots/ changes/ latest.md for this page.
# Returns @{ Ok; Changed; Record } or $null when the fetch failed.
function Process-Page {
    param(
        [string]$Url,
        [string]$PageDir,
        [string]$Display,
        [string]$PreFetchedHtml
    )

    $snapshotDir = Join-Path $PageDir 'snapshots'
    $changesDir = Join-Path $PageDir 'changes'
    $latestFile = Join-Path $PageDir 'latest.md'
    foreach ($d in @($snapshotDir, $changesDir)) {
        if (-not (Test-Path $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }

    $html = $PreFetchedHtml
    if (-not $html) { $html = Get-PageContent -Url $Url }
    if (-not $html) { return $null }

    $text = Convert-HtmlToText -Html $html

    # latest.md stores BODY ONLY: the Fetched timestamp in the header must not be
    # part of the diff, otherwise every page is flagged as changed every single day.
    $nl = [Environment]::NewLine
    $bodyText = $text + $nl
    $header = "# $Display" + $nl + $nl + "- URL: $Url" + $nl + "- Fetched: $now" + $nl + $nl + "---" + $nl + $nl
    $content = $header + $bodyText

    $snapshotFile = Join-Path $snapshotDir "$today.md"
    [System.IO.File]::WriteAllText($snapshotFile, $content, [System.Text.UTF8Encoding]::new($false))

    $hasChange = $false
    $isInitial = $false
    $diffText = $null
    $addedForSummary = @()

    if (Test-Path $latestFile) {
        $oldBody = [System.IO.File]::ReadAllText($latestFile, [System.Text.UTF8Encoding]::new($false))
        if ($oldBody -ne $bodyText) {
            $diff = Get-Diff -OldContent $oldBody -NewContent $bodyText
            if ($diff.Added.Count -gt 0 -or $diff.Removed.Count -gt 0) {
                $hasChange = $true
                $diffLines = @()
                $diffLines += "# Diff for $Display on $today"
                $diffLines += ""
                $diffLines += "- URL: $Url"
                $diffLines += "- Compared: $now"
                $diffLines += "- Added: $($diff.Added.Count) lines"
                $diffLines += "- Removed: $($diff.Removed.Count) lines"
                $diffLines += ""
                $diffLines += "## Added lines"
                $diffLines += ""
                $diffLines += $diff.Added
                $diffLines += ""
                $diffLines += "## Removed lines"
                $diffLines += ""
                $diffLines += $diff.Removed
                $diffText = $diffLines -join "`r`n"

                foreach ($a in $diff.Added) {
                    $t = $a
                    if ($t.Length -gt 2) { $t = $t.Substring(2) }
                    $t = $t.Trim()
                    if ($t.Length -lt 5) { continue }
                    if ($t -match '^- (Fetched|Compared|URL|Company):') { continue }
                    if ($t -match '^# (Initial snapshot|Diff for)') { continue }
                    if ($t -match '^First-time capture') { continue }
                    $addedForSummary += $t
                }
            }
        }
    }
    else {
        $hasChange = $true
        $isInitial = $true
        $initParts = @()
        $initParts += "# Initial snapshot for $Display on $today"
        $initParts += ""
        $initParts += "First-time capture, no previous version to diff against."
        $initParts += ""
        $initParts += "---"
        $initParts += ""
        $initParts += $content
        $diffText = $initParts -join "`r`n"
    }

    if ($hasChange) {
        $diffFile = Join-Path $changesDir "$today.md"
        [System.IO.File]::WriteAllText($diffFile, $diffText, [System.Text.UTF8Encoding]::new($false))
        # Baseline = body only, so timestamps never pollute the diff
        [System.IO.File]::WriteAllText($latestFile, $bodyText, [System.Text.UTF8Encoding]::new($false))
        Write-Log "  -> CHANGE [$Display] diff -> $diffFile"
        if (-not $isInitial) {
            # Screenshot only for real content changes (not first-time baselines)
            $pngFile = Join-Path $changesDir "$today.png"
            Take-Screenshot -Url $Url -OutPng $pngFile | Out-Null
        }
    }
    else {
        Write-Log "  -> no change [$Display]"
    }

    return @{
        Ok       = $true
        Changed  = $hasChange
        Record   = @{ Display = $Display; Url = $Url; Added = $addedForSummary; IsInitial = $isInitial }
    }
}

# ========== Main ==========

Write-Log "==== Crawl start: $now ===="
Write-Log "Config: $ConfigPath"
Write-Log "Output: $OutputRoot"

$config = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Log "Loaded $($config.sites.Count) sites"

$script:BrowserExe = Find-BrowserPath
if ($script:BrowserExe) {
    Write-Log "Screenshot browser: $script:BrowserExe"
}
else {
    Write-Log "WARN: no Edge/Chrome found, change screenshots will be skipped"
}

$stats = @{ OK = 0; FAIL = 0; CHANGED = 0; UNCHANGED = 0; PAGES = 0; SUBPAGES = 0 }
$changeRecords = New-Object System.Collections.Generic.List[object]

foreach ($site in $config.sites) {
    $company = $site.company
    $siteName = $site.name
    $url = $site.url

    Write-Log "[$company/$siteName] $url"

    $siteDir = Join-Path (Join-Path $OutputRoot $company) $siteName

    $html = Get-PageContent -Url $url
    if (-not $html) {
        $stats.FAIL = $stats.FAIL + 1
        continue
    }

    $stats.PAGES = $stats.PAGES + 1
    $result = Process-Page -Url $url -PageDir $siteDir -Display "$company/$siteName" -PreFetchedHtml $html
    if ($result) {
        $stats.OK = $stats.OK + 1
        if ($result.Changed) {
            $stats.CHANGED = $stats.CHANGED + 1
            $changeRecords.Add($result.Record)
        }
        else {
            $stats.UNCHANGED = $stats.UNCHANGED + 1
        }
    }
    else {
        $stats.FAIL = $stats.FAIL + 1
    }

    # ----- optional sub-page crawling -----
    $maxPages = 0
    if ($site.maxPages) { $maxPages = [int]$site.maxPages }
    if ($site.crawl -eq $true -and $maxPages -lt 1) { $maxPages = 6 }
    if ($site.crawl -eq $true -and $maxPages -ge 1) {
        $scope = 'host'
        if ($site.scope) { $scope = [string]$site.scope }
        $subLinks = Get-SubLinks -Html $html -BaseUrl $url -SeedUrl $url -Scope $scope
        Write-Log "  crawl mode ($scope scope): $($subLinks.Count) in-scope links found, crawling up to $maxPages"

        $pagesDir = Join-Path $siteDir 'pages'
        if (-not (Test-Path $pagesDir)) {
            New-Item -ItemType Directory -Path $pagesDir -Force | Out-Null
        }

        $taken = 0
        foreach ($link in $subLinks) {
            if ($taken -ge $maxPages) { break }
            # Polite pacing between sub-page fetches
            Start-Sleep -Seconds 1
            $slug = Convert-ToSlug -Url $link
            $pageDir = Join-Path $pagesDir $slug
            $sub = Process-Page -Url $link -PageDir $pageDir -Display "$company/$siteName/$slug" -PreFetchedHtml $null
            $stats.PAGES = $stats.PAGES + 1
            $stats.SUBPAGES = $stats.SUBPAGES + 1
            if ($sub) {
                $stats.OK = $stats.OK + 1
                if ($sub.Changed) {
                    $stats.CHANGED = $stats.CHANGED + 1
                    $changeRecords.Add($sub.Record)
                }
                else {
                    $stats.UNCHANGED = $stats.UNCHANGED + 1
                }
            }
            else {
                $stats.FAIL = $stats.FAIL + 1
            }
            $taken = $taken + 1
        }
    }
}

Write-Log "==== Crawl done: OK=$($stats.OK) FAIL=$($stats.FAIL) CHANGED=$($stats.CHANGED) UNCHANGED=$($stats.UNCHANGED) PAGES=$($stats.PAGES) SUBPAGES=$($stats.SUBPAGES) ===="

# Retention: drop snapshots older than 60 days (diffs and latest.md are kept)
$cutoff = (Get-Date).AddDays(-60).ToString('yyyy-MM-dd')
$oldSnaps = Get-ChildItem -Path $OutputRoot -Recurse -Filter '*.md' | Where-Object { $_.FullName -match '\\snapshots\\' -and $_.BaseName -lt $cutoff }
$removedSnaps = 0
foreach ($s in $oldSnaps) {
    Remove-Item -Path $s.FullName -Force
    $removedSnaps = $removedSnaps + 1
}
if ($removedSnaps -gt 0) {
    Write-Log "Retention: removed $removedSnaps snapshots older than $cutoff"
}

# ========== Generate daily summary (bullet point, human-readable) ==========
$summaryDir = Join-Path $OutputRoot "summary"
if (-not (Test-Path $summaryDir)) {
    New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null
}
$summaryFile = Join-Path $summaryDir "$today.md"

$byCompany = @{}
foreach ($rec in $changeRecords) {
    $displayParts = $rec.Display -split '/'
    $company = $displayParts[0]
    if (-not $byCompany.ContainsKey($company)) {
        $byCompany[$company] = New-Object System.Collections.Generic.List[object]
    }
    $byCompany[$company].Add($rec)
}

$companies = $byCompany.Keys | Sort-Object

$summaryLines = @()
$summaryLines += '# Daily Dev-Site Update Summary - ' + $today
$summaryLines += ''
$summaryLines += '- Fetched: ' + $now
$summaryLines += '- Stats: OK=' + $stats.OK + ' FAIL=' + $stats.FAIL + ' CHANGED=' + $stats.CHANGED + ' UNCHANGED=' + $stats.UNCHANGED + ' PAGES=' + $stats.PAGES
$summaryLines += '- Companies with changes: ' + $companies.Count
$summaryLines += ''
$summaryLines += '---'
$summaryLines += ''

foreach ($company in $companies) {
    $recs = $byCompany[$company]
    $companyAdded = 0
    foreach ($r in $recs) { $companyAdded = $companyAdded + $r.Added.Count }
    if ($companyAdded -eq 0 -and -not ($recs | Where-Object { $_.IsInitial })) { continue }

    $summaryLines += '## ' + $company
    $summaryLines += ''

    foreach ($rec in $recs) {
        if ($rec.IsInitial) {
            $summaryLines += '### ' + $rec.Display
            $summaryLines += ''
            $summaryLines += '- __First-time capture, baseline only, no diff info__'
            $summaryLines += ''
            continue
        }
        if ($rec.Added.Count -eq 0) { continue }
        $summaryLines += '### ' + $rec.Display
        $summaryLines += ''
        $count = 0
        $maxShow = 20
        foreach ($a in $rec.Added) {
            if ($count -ge $maxShow) {
                $remain = $rec.Added.Count - $maxShow
                $summaryLines += '- ... ' + $remain + ' more added lines, see changes/' + $today + '.md'
                break
            }
            $summaryLines += '- ' + $a
            $count = $count + 1
        }
        $summaryLines += ''
    }
}

if ($companies.Count -eq 0) {
    $summaryLines += 'No changes today.'
    $summaryLines += ''
}

[System.IO.File]::WriteAllText($summaryFile, ($summaryLines -join [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
$summaryLogMsg = 'Summary -> ' + $summaryFile
Write-Log $summaryLogMsg

# ========== Rebuild the HTML dashboard from all data ==========
try {
    $dashboardScript = Join-Path $PSScriptRoot 'build-dashboard.ps1'
    & $dashboardScript -OutputRoot $OutputRoot
    Write-Log "Dashboard -> $(Join-Path $OutputRoot 'index.html')"
}
catch {
    Write-Log "WARN: dashboard rebuild failed: $($_.Exception.Message)"
}
Write-Log ''
