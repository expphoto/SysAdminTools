# EmailKPIReport.ps1
# Pure PowerShell + Outlook COM + Chart.js HTML report
# Business hours aware (Mon-Fri, 8am-4pm)
# No Python, no pip, no external tools required
# Run with Outlook open

$yourEmail  = "user@example.com"
$yourName   = "Example User"
$daysBack   = 90
$bizStart   = 8
$bizEnd     = 16
$bizDays    = @("Monday","Tuesday","Wednesday","Thursday","Friday")
$cutoff     = (Get-Date).AddDays(-$daysBack)
$reportPath = "$env:USERPROFILE\Desktop\EmailKPI_Report.html"

function Get-BizHoursFast($start, $end) {
    if ($end -le $start) { return 0 }
    $bizStartSpan = [TimeSpan]::FromHours($bizStart)
    $bizEndSpan   = [TimeSpan]::FromHours($bizEnd)
    $total        = 0.0
    $current      = $start
    while ($current.Date -le $end.Date) {
        $dow = $current.DayOfWeek.ToString()
        if ($bizDays -contains $dow) {
            $dayStart = $current.Date.Add($bizStartSpan)
            $dayEnd   = $current.Date.Add($bizEndSpan)
            $segStart = if ($current -gt $dayStart) { $current } else { $dayStart }
            $segEnd   = if ($end -lt $dayEnd)       { $end }     else { $dayEnd }
            if ($segEnd -gt $segStart) {
                $total += ($segEnd - $segStart).TotalHours
            }
        }
        $current = $current.Date.AddDays(1)
    }
    return [math]::Round($total, 2)
}

function Get-Stats($set) {
    $vals = $set | Where-Object { $_.Responded -and $_.BizResponseHours -ne $null } |
                   Select-Object -ExpandProperty BizResponseHours
    if ($vals.Count -eq 0) { return @{avg=0;med=0;min=0;max=0;count=0} }
    $sorted = $vals | Sort-Object
    $mid    = [math]::Floor($sorted.Count / 2)
    $median = if ($sorted.Count % 2) { $sorted[$mid] } else { [math]::Round(($sorted[$mid-1] + $sorted[$mid])/2,2) }
    return @{
        avg   = [math]::Round(($vals | Measure-Object -Average).Average, 2)
        med   = $median
        min   = [math]::Round(($vals | Measure-Object -Minimum).Minimum, 2)
        max   = [math]::Round(($vals | Measure-Object -Maximum).Maximum, 2)
        count = $vals.Count
    }
}

Write-Host "Connecting to Outlook..." -ForegroundColor Cyan
$outlook   = New-Object -ComObject Outlook.Application
$namespace = $outlook.GetNamespace("MAPI")
$inbox     = $namespace.GetDefaultFolder(6)
$sent      = $namespace.GetDefaultFolder(5)

$sentLookup = @{}
Write-Host "Indexing sent items..." -ForegroundColor Cyan
foreach ($mail in $sent.Items) {
    try {
        if ($mail.Class -ne 43) { continue }
        if ($mail.SentOn -lt $cutoff) { continue }
        $key = ($mail.Subject -replace "^(RE: |FW: |Re: |Fw: )+", "").Trim().ToLower()
        if (-not $sentLookup.ContainsKey($key)) { $sentLookup[$key] = $mail.SentOn }
    } catch { continue }
}

Write-Host "Analyzing inbox..." -ForegroundColor Cyan
$results = @()
foreach ($mail in $inbox.Items) {
    try {
        if ($mail.Class -ne 43) { continue }
        if ($mail.ReceivedTime -lt $cutoff) { continue }

        $toField   = if ($mail.To)   { $mail.To }   else { "" }
        $ccField   = if ($mail.CC)   { $mail.CC }   else { "" }
        $bodySnip  = if ($mail.Body) { $mail.Body.Substring(0, [Math]::Min(600, $mail.Body.Length)) } else { "" }

$yourAlias   = $yourEmail.Split("@")[0]
$directTO    = ($toField -match [regex]::Escape($yourEmail)) -or
               ($toField -match [regex]::Escape($yourName))  -or
               ($toField -match [regex]::Escape($yourAlias))
$ccOnly      = (-not $directTO) -and (
               ($ccField -match [regex]::Escape($yourEmail)) -or
               ($ccField -match [regex]::Escape($yourName))  -or
               ($ccField -match [regex]::Escape($yourAlias)))
$atMentioned = $bodySnip -match ("@" + [regex]::Escape($yourName))
        $explicit    = $directTO -or $atMentioned

        $cleanSubject    = ($mail.Subject -replace "^(RE: |FW: |Re: |Fw: )+", "").Trim().ToLower()
        $responseTime    = $null
        $bizResponseTime = $null

        if ($sentLookup.ContainsKey($cleanSubject)) {
            $sentTime = $sentLookup[$cleanSubject]
            $diff     = ($sentTime - $mail.ReceivedTime).TotalHours
            if ($diff -gt 0 -and $diff -lt 120) {
                $responseTime    = [math]::Round($diff, 2)
                $bizResponseTime = Get-BizHoursFast $mail.ReceivedTime $sentTime
            }
        }

        $results += [PSCustomObject]@{
            ReceivedTime      = $mail.ReceivedTime
            DayOfWeek         = $mail.ReceivedTime.DayOfWeek.ToString()
            Hour              = $mail.ReceivedTime.Hour
            Subject           = $mail.Subject
            Sender            = $mail.SenderName
            DirectTO          = $directTO
            CCOnly            = $ccOnly
            AtMentioned       = $atMentioned
            Explicit          = $explicit
            ResponseTimeHours = $responseTime
            BizResponseHours  = $bizResponseTime
            Responded         = ($null -ne $responseTime)
        }
    } catch { continue }
}


Write-Host "Calculating KPIs..." -ForegroundColor Cyan

$direct  = $results | Where-Object { $_.DirectTO }
$cc      = $results | Where-Object { $_.CCOnly }
$atM     = $results | Where-Object { $_.AtMentioned }
$exp     = $results | Where-Object { $_.Explicit }

$sDirect = Get-Stats $direct
$sCC     = Get-Stats $cc
$sAt     = Get-Stats $atM
$sExp    = Get-Stats $exp

$dowOrder  = @("Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday")
$dowCounts = $dowOrder | ForEach-Object { $d = $_; ($results | Where-Object { $_.DayOfWeek -eq $d }).Count }

$hourCounts = 0..23 | ForEach-Object { $h = $_; ($results | Where-Object { $_.Hour -eq $h }).Count }

$weeklyData = $exp | Where-Object { $_.Responded -and $_.BizResponseHours -ne $null } |
    Group-Object { $_.ReceivedTime.ToString("yyyy-'W'ww") } | Sort-Object Name |
    ForEach-Object {
        $vals = $_.Group | Select-Object -ExpandProperty BizResponseHours
        $avg  = [math]::Round(($vals | Measure-Object -Average).Average, 2)
        [PSCustomObject]@{ Week = $_.Name; Avg = $avg }
    }
$weekLabels = ($weeklyData | Select-Object -ExpandProperty Week) -join '","'
$weekVals   = ($weeklyData | Select-Object -ExpandProperty Avg) -join ','

$buckets   = @("<1h","1-2h","2-4h","4-8h","8+biz h")
$bktCounts = @(0,0,0,0,0)
foreach ($r in ($direct | Where-Object { $_.Responded -and $_.BizResponseHours -ne $null })) {
    $v = $r.BizResponseHours
    if     ($v -lt 1) { $bktCounts[0]++ }
    elseif ($v -lt 2) { $bktCounts[1]++ }
    elseif ($v -lt 4) { $bktCounts[2]++ }
    elseif ($v -lt 8) { $bktCounts[3]++ }
    else              { $bktCounts[4]++ }
}

$totalInbox     = $results.Count
$totalDirect    = $direct.Count
$totalCC        = $cc.Count
$totalAt        = $atM.Count
$totalOther     = [Math]::Max(0, $totalInbox - $totalDirect - $totalCC - $totalAt)
$totalResponded = ($results | Where-Object { $_.Responded }).Count
$generatedAt    = (Get-Date).ToString("MMMM dd, yyyy hh:mm tt")

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<title>Email KPI Report — $yourName</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0f1117;color:#e0e0e0;padding:32px}
  h1{font-size:26px;color:#fff;margin-bottom:4px}
  .subtitle{color:#666;font-size:13px;margin-bottom:32px}
  .kpi-row{display:flex;flex-wrap:wrap;gap:14px;margin-bottom:36px}
  .kpi-card{background:#1a1d27;border:1px solid #2a2d3e;border-radius:10px;padding:18px 22px;min-width:150px;flex:1}
  .kpi-label{font-size:11px;color:#888;text-transform:uppercase;letter-spacing:.8px;margin-bottom:6px}
  .kpi-value{font-size:28px;font-weight:700}
  .kpi-sub{font-size:11px;color:#555;margin-top:4px}
  h2{color:#c0c8ff;font-size:16px;border-bottom:1px solid #2a2d3e;padding-bottom:8px;margin:32px 0 16px}
  table{width:100%;border-collapse:collapse;background:#1a1d27;border-radius:8px;overflow:hidden;margin-bottom:32px}
  th{background:#2a2d3e;color:#aaa;font-size:11px;text-transform:uppercase;padding:10px 14px;text-align:left}
  td{padding:10px 14px;border-bottom:1px solid #1e2130;font-size:13px}
  tr:last-child td{border-bottom:none}
  .charts-grid{display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-bottom:32px}
  .chart-box{background:#1a1d27;border:1px solid #2a2d3e;border-radius:10px;padding:20px}
  .chart-box.full{grid-column:1/-1}
  .chart-box h3{font-size:12px;color:#888;margin-bottom:14px;text-transform:uppercase;letter-spacing:.6px}
  canvas{max-height:260px}
  .footer{color:#333;font-size:11px;text-align:center;margin-top:48px}
  .blue{color:#4f8ef7}.green{color:#4caf7d}.orange{color:#f7a44f}.purple{color:#a78bfa}
  .biz-note{font-size:11px;color:#555;margin-top:6px;font-style:italic}
</style>
</head>
<body>
<h1>📊 Email Response KPI Report</h1>
<div class="subtitle">Generated $generatedAt &nbsp;|&nbsp; $yourName &nbsp;|&nbsp; Last $daysBack days &nbsp;|&nbsp; Business hours: Mon–Fri $($bizStart):00–$($bizEnd):00</div>

<h2>Overview</h2>
<div class="kpi-row">
  <div class="kpi-card"><div class="kpi-label">Total Received</div><div class="kpi-value">$totalInbox</div><div class="kpi-sub">Last $daysBack days</div></div>
  <div class="kpi-card"><div class="kpi-label">Responses Tracked</div><div class="kpi-value green">$totalResponded</div><div class="kpi-sub">Matched to sent items</div></div>
  <div class="kpi-card"><div class="kpi-label">Direct TO</div><div class="kpi-value blue">$totalDirect</div><div class="kpi-sub">Explicitly addressed</div></div>
  <div class="kpi-card"><div class="kpi-label">CC Only</div><div class="kpi-value orange">$totalCC</div><div class="kpi-sub">No direct ask implied</div></div>
  <div class="kpi-card"><div class="kpi-label">@Mentioned</div><div class="kpi-value purple">$totalAt</div><div class="kpi-sub">Body mention detected</div></div>
  <div class="kpi-card"><div class="kpi-label">Avg BizHrs (Direct TO)</div><div class="kpi-value green">$($sDirect.avg)h</div><div class="kpi-sub">Business hours only</div></div>
  <div class="kpi-card"><div class="kpi-label">Avg BizHrs (Explicit)</div><div class="kpi-value blue">$($sExp.avg)h</div><div class="kpi-sub">TO + @mention combined</div></div>
</div>

<h2>Response Time Breakdown <span class="biz-note">(business hours only — Mon–Fri $($bizStart):00–$($bizEnd):00)</span></h2>
<table>
  <thead><tr><th>Type</th><th>Responses</th><th>Avg</th><th>Median</th><th>Min</th><th>Max</th></tr></thead>
  <tbody>
    <tr><td><strong>Direct TO</strong></td><td>$($sDirect.count)</td><td>$($sDirect.avg)h</td><td>$($sDirect.med)h</td><td>$($sDirect.min)h</td><td>$($sDirect.max)h</td></tr>
    <tr><td><strong>CC Only</strong></td><td>$($sCC.count)</td><td>$($sCC.avg)h</td><td>$($sCC.med)h</td><td>$($sCC.min)h</td><td>$($sCC.max)h</td></tr>
    <tr><td><strong>@Mentioned in Body</strong></td><td>$($sAt.count)</td><td>$($sAt.avg)h</td><td>$($sAt.med)h</td><td>$($sAt.min)h</td><td>$($sAt.max)h</td></tr>
    <tr><td><strong>Any Explicit Ask</strong></td><td>$($sExp.count)</td><td>$($sExp.avg)h</td><td>$($sExp.med)h</td><td>$($sExp.min)h</td><td>$($sExp.max)h</td></tr>
  </tbody>
</table>

<h2>Charts</h2>
<div class="charts-grid">

  <div class="chart-box">
    <h3>Avg Biz Response Time by Type</h3>
    <canvas id="c1"></canvas>
  </div>

  <div class="chart-box">
    <h3>Inbox Volume by Addressing Type</h3>
    <canvas id="c2"></canvas>
  </div>

  <div class="chart-box">
    <h3>Direct TO — Biz Hour Response Buckets</h3>
    <canvas id="c3"></canvas>
  </div>

  <div class="chart-box">
    <h3>Emails Received by Day of Week</h3>
    <canvas id="c4"></canvas>
  </div>

  <div class="chart-box full">
    <h3>Weekly Avg Biz Response Time — Explicit Asks</h3>
    <canvas id="c5"></canvas>
  </div>

</div>

<div class="footer">Local Outlook COM data — $yourName personal inbox only &nbsp;|&nbsp; Business hours: Mon–Fri $($bizStart):00–$($bizEnd):00 &nbsp;|&nbsp; Not for distribution</div>

<script>
const cd = {
  plugins: { legend: { labels: { color: '#aaa', font: { size: 12 } } } },
  scales: { x: { ticks: { color: '#888' }, grid: { color: '#1e2130' } }, y: { ticks: { color: '#888' }, grid: { color: '#1e2130' } } }
};

new Chart(document.getElementById('c1'), {
  type: 'bar',
  data: {
    labels: ['Direct TO','CC Only','@Mentioned','Any Explicit'],
    datasets: [{ label: 'Avg Biz Hours', data: [$($sDirect.avg),$($sCC.avg),$($sAt.avg),$($sExp.avg)],
      backgroundColor: ['#4caf7d','#f7a44f','#a78bfa','#4f8ef7'], borderRadius: 6 }]
  },
  options: { ...cd, plugins: { ...cd.plugins, legend: { display: false } } }
});

new Chart(document.getElementById('c2'), {
  type: 'doughnut',
  data: {
    labels: ['Direct TO','CC Only','@Mentioned','Other'],
    datasets: [{ data: [$totalDirect,$totalCC,$totalAt,$totalOther],
      backgroundColor: ['#4f8ef7','#f7a44f','#a78bfa','#3a3d4e'], borderWidth: 0 }]
  },
  options: { plugins: { legend: { position: 'right', labels: { color: '#aaa' } } } }
});

new Chart(document.getElementById('c3'), {
  type: 'bar',
  data: {
    labels: ['<1h','1-2h','2-4h','4-8h','8+ biz h'],
    datasets: [{ label: 'Emails', data: [$($bktCounts -join ',')],
      backgroundColor: '#4f8ef7', borderRadius: 6 }]
  },
  options: { ...cd, plugins: { ...cd.plugins, legend: { display: false } } }
});

new Chart(document.getElementById('c4'), {
  type: 'bar',
  data: {
    labels: ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'],
    datasets: [{ label: 'Emails', data: [$($dowCounts -join ',')],
      backgroundColor: '#a78bfa', borderRadius: 6 }]
  },
  options: { ...cd, plugins: { ...cd.plugins, legend: { display: false } } }
});

new Chart(document.getElementById('c5'), {
  type: 'line',
  data: {
    labels: ["$weekLabels"],
    datasets: [{ label: 'Avg Biz Hours', data: [$weekVals],
      borderColor: '#4f8ef7', backgroundColor: 'rgba(79,142,247,0.15)',
      fill: true, tension: 0.4, pointRadius: 4 }]
  },
  options: { ...cd }
});
</script>
</body>
</html>
"@

$html | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host "`nReport saved to: $reportPath" -ForegroundColor Green
Start-Process $reportPath
