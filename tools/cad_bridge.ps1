<#
.SYNOPSIS
    Мост DSH ↔ AutoCAD 2018 для LayerCycleManager и разработки LISP.

.DESCRIPTION
    Скрипт подключается к уже запущенному AutoCAD через COM (AutoCAD.Application),
    отправляет LISP/команды, забирает результат и умеет читать отчёты LCM.

    AutoCAD сам не запускается: если процесс acad.exe не найден — команда честно
    сообщает об этом. Это защита от случайного открытия чужого чертежа.

.PARAMETER Verb
    status  — AutoCAD, открытый DWG, загружен ли LCM, версия
    eval    — выполнить LISP-выражение, вернуть результат или текст ошибки
    load    — загрузить .lsp/.fas/.vlx в текущий чертёж
    dump    — выгрузить объекты ModelSpace (тип, слой, handle, координаты, текст)
    layers  — таблица слоёв: имя, цвет, заморожен, заблокирован, выключен
    shot    — снимок окна AutoCAD в PNG
    cmd     — отправить произвольную команду AutoCAD
    undo    — mark (поставить маркер) / back (откатить)
    cuix    — загрузить файл меню (CUIX/CUI)
    report  — разобрать свежий отчёт LCM из reports/ (AutoCAD не нужен)

.EXAMPLE
    .\cad_bridge.ps1 status
    .\cad_bridge.ps1 eval "(getvar \"DWGNAME\")"
    .\cad_bridge.ps1 dump -Layer "Уч 6 Цикл 1" -Out dump.json
    .\cad_bridge.ps1 shot -Out screen.png
    .\cad_bridge.ps1 report -Kind chain
    .\cad_bridge.ps1 eval "(lcm:chain-run '(\"Уч 6 Цикл 0\" \"Уч 6 Цикл 1\") nil)" -PrintLisp

.NOTES
    ВАЖНО: файл должен сохраняться в UTF-8 **с BOM**. Windows PowerShell 5.1
    без BOM читает .ps1 как ANSI и разваливает кириллицу в строках.

    Кодировки: отчёты LCM — Windows-1251, разделитель ';', десятичная запятая.
    LISP-выражения, отправляемые в AutoCAD, намеренно ASCII-only: кириллица
    передаётся только внутри строковых данных, которые формирует сам вызов.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('status', 'eval', 'load', 'dump', 'layers', 'shot', 'cmd', 'undo', 'cuix', 'report')]
    [string]$Verb,

    [Parameter(Position = 1)]
    [string]$Arg,

    [string]$Layer,
    [string]$Type,
    [string]$Out,
    [ValidateSet('chain', 'geo', 'check', 'points', 'pair', 'any')]
    [string]$Kind = 'any',
    [int]$TimeoutSec = 30,
    [switch]$Wait,
    [switch]$PrintLisp,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$Script:Root    = Split-Path -Parent $PSScriptRoot
$Script:Reports = Join-Path $Script:Root 'reports'
$Script:Utf8    = New-Object Text.UTF8Encoding($false)
$Script:Cp1251  = [Text.Encoding]::GetEncoding(1251)

# ---------------------------------------------------------------- COM / AutoCAD

function Get-Acad {
    # ВАЖНО: New-Object -ComObject AutoCAD.Application НЕ используется ни в каком виде —
    # если AutoCAD занят, он молча запускает второй экземпляр с пустым «Чертеж1.dwg»
    # и все вызовы начинают уходить в чужое окно. Подключаемся только к уже открытому.
    if ($Script:Acad) { return $Script:Acad }
    $lastError = $null
    for ($i = 0; $i -lt 8; $i++) {
        try {
            $Script:Acad = [Runtime.InteropServices.Marshal]::GetActiveObject('AutoCAD.Application')
            return $Script:Acad
        } catch {
            $lastError = $_
            Start-Sleep -Milliseconds 400
        }
    }
    throw "Нет связи с AutoCAD ($($lastError.Exception.Message)). Новый экземпляр намеренно не запускается: проверьте, что AutoCAD открыт с нужным чертежом, закройте лишние окна AutoCAD и повторите."
}

function Get-AcadDoc {
    $doc = (Get-Acad).ActiveDocument
    if ($null -eq $doc) { throw 'В AutoCAD нет активного документа.' }
    $doc
}

function Invoke-ComRetry {
    # AutoCAD отклоняет COM-вызовы, пока занят (RPC_E_CALL_REJECTED) — это временно.
    param([Parameter(Mandatory = $true)][scriptblock]$Action, [int]$Attempts = 8)
    $last = $null
    for ($i = 0; $i -lt $Attempts; $i++) {
        try { return (& $Action) }
        catch {
            $last = $_
            if ($_.Exception.Message -notmatch 'RPC_E_CALL_REJECTED|rejected by callee|0x80010001') { throw }
            Start-Sleep -Milliseconds 500
        }
    }
    throw $last.Exception
}

function Assert-Idle {
    $ca = Invoke-ComRetry { (Get-AcadDoc).GetVariable('CMDACTIVE') }
    if ($ca -ne 0) { throw "AutoCAD занят командой (CMDACTIVE=$ca). Дождитесь завершения и повторите." }
}

# ---------------------------------------------------------------- LISP transport

function New-ResultPath {
    # Каталог TEMP может быть недоступен на запись из песочницы — берём подпапку.
    $dir = Join-Path $env:TEMP 'lcm_bridge'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Join-Path $dir ('{0}.txt' -f ([guid]::NewGuid().ToString('N')))
}

function Format-LispPath {
    param([string]$Path)
    (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path -replace '\\', '/'
}

function Invoke-Lisp {
    <#
        Отправляет выражение в AutoCAD и ждёт файл с результатом.
        Возвращает [pscustomobject]@{ Ok; Value; Raw }.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Expression,
        [int]$Timeout = 30
    )

    $result = New-ResultPath
    $resultLisp = $result -replace '\\', '/'

    $payload = @"
(progn
 (setq __br (vl-catch-all-apply (function (lambda () $Expression))))
 (setq __f (open "$resultLisp" "w"))
 (if (vl-catch-all-error-p __br)
  (write-line (strcat "ERR|" (vl-catch-all-error-message __br)) __f)
  (progn (write-line "OK|" __f)
         (if __br (write-line (vl-prin1-to-string __br) __f))))
 (close __f)
 (princ))
"@ -replace "`r?`n", ' '

    if ($PrintLisp) { Write-Output $payload; return }

    Assert-Idle
    $doc = Get-AcadDoc
    Invoke-ComRetry { $doc.SendCommand(($payload.Trim() + ' ')) }

    $deadline = (Get-Date).AddSeconds($Timeout)
    while (-not (Test-Path $result)) {
        if ((Get-Date) -gt $deadline) {
            throw "AutoCAD не ответил за $Timeout с. Вероятно, команда ждёт ввода или открыт диалог."
        }
        Start-Sleep -Milliseconds 120
    }

    $text = [IO.File]::ReadAllText($result, $Script:Cp1251)
    Remove-Item -LiteralPath $result -Force -ErrorAction SilentlyContinue

    # Файл результата: первая строка "OK|" или "ERR|<сообщение>", далее — значение
    $rawLines = $text -split "`r?`n"
    $head = $rawLines[0]
    $hp = $head -split '\|', 2
    $status = $hp[0].Trim()
    $value = if ($hp.Count -gt 1) { $hp[1] } else { '' }
    if ($rawLines.Count -gt 1) {
        $rest = ($rawLines[1..($rawLines.Count - 1)] -join "`n").Trim()
        if ($rest) { $value = if ($value.Trim()) { $value + "`n" + $rest } else { $rest } }
    }
    $value = $value.Trim()

    if ($status -eq 'ERR') { throw "Ошибка LISP: $value" }
    [pscustomobject]@{ Ok = $true; Value = $value; Raw = $text.TrimEnd() }
}

function Send-AcadCommand {
    param([Parameter(Mandatory = $true)][string]$Command, [switch]$Wait)
    Assert-Idle
    $doc = Get-AcadDoc
    Invoke-ComRetry { $doc.SendCommand(($Command.Trim() + ' ')) }
    if ($Wait) {
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ($doc.GetVariable('CMDACTIVE') -ne 0) {
            if ((Get-Date) -gt $deadline) { throw "Команда не завершилась за $TimeoutSec с." }
            Start-Sleep -Milliseconds 150
        }
    }
}

# ---------------------------------------------------------------- reports (без AutoCAD)

function Read-LcmReport {
    param([Parameter(Mandatory = $true)][string]$Path)
    $lines = [IO.File]::ReadAllLines($Path, $Script:Cp1251)
    $meta = [ordered]@{}
    $rows = New-Object System.Collections.Generic.List[object]
    $section = ''
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t -eq '') { continue }
        if ($t.StartsWith('#')) {
            $body = $t.Substring(1).Trim()
            # Строка описания колонок: "# layer;points;matched;..." — первым идёт латинское имя в нижнем регистре
            if ($body -cmatch '^[a-z_][a-z0-9_]*(\s*;|$)') { continue }
            # "Ключ: значение" — метаданные отчёта
            if ($body -match '^([^:]{1,48}):\s*(.*)$') {
                $meta[$Matches[1].Trim()] = $Matches[2].Trim()
                continue
            }
            $section = $body
            continue
        }
        $rows.Add([pscustomobject]@{ Section = $section; Values = ($t -split ';') })
    }

    $num = { param($s) $v = 0.0; if ([double]::TryParse(($s -replace ',', '.'), [Globalization.NumberStyles]::Float, $null, [ref]$v)) { $v } else { $null } }

    # Счётчики из "Принято: 11 | Спорных: 0 | ..." (строка в meta разбирается по '|')
    $counters = [ordered]@{}
    foreach ($k in @($meta.Keys)) {
        $val = [string]$meta[$k]
        if ($val -notmatch '\|') { continue }
        foreach ($chunk in ($val -split '\|')) {
            $c = $chunk.Trim()
            if ($c -match '^([^:]+):\s*(.+)$') { $counters[$Matches[1].Trim()] = $Matches[2].Trim() }
            elseif ($c -match '^\d+$') { $counters[$k] = $c }
        }
    }

    $pairs = @($rows | Where-Object { $_.Section -match 'ПАРЫ ДЛЯ|ПРИНЯТЫЕ ПАРЫ' })
    $cycles = @($rows | Where-Object { $_.Section -cmatch '^ЦИКЛЫ' })
    $lengths = @($rows | Where-Object { $_.Section -match 'ПРОВЕРКА ДЛИН' })
    $mismatch = @($lengths | Where-Object { $_.Values.Count -ge 6 -and $_.Values[5] -notmatch '^ок$' })

    [pscustomobject]@{
        File       = Split-Path -Leaf $Path
        Kind       = if ((Split-Path -Leaf $Path) -match '^lcm_(?<k>chain|geo|check|points|pair)_') { $Matches['k'] } else { 'other' }
        Drawing    = $meta['Чертеж']
        LayerA     = $meta['Слой A']; LayerB = $meta['Слой B']
        FirstLayer = $meta['Первый слой']; LastLayer = $meta['Последний слой']
        Radius     = $meta['Порог']
        Counters   = $counters
        Pairs      = $pairs.Count
        Cycles     = $cycles.Count
        Lengths    = $lengths.Count
        Mismatches = $mismatch.Count
        Modified   = (Get-Item $Path).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        Path       = $Path
    }
}

function Get-LatestReport {
    param([string]$Kind = 'any')
    $pattern = switch ($Kind) {
        'chain' { 'lcm_chain_*.csv' }
        'geo' { 'lcm_geo_*.csv' }
        'check' { 'lcm_check_*.csv' }
        'points' { 'lcm_points_*.csv' }
        'pair' { 'lcm_pair_*.csv' }
        default { 'lcm_*.csv' }
    }
    Get-ChildItem -Path $Script:Reports -Filter $pattern -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

# ---------------------------------------------------------------- verbs

function Show-Status {
    $acad = $null
    try { $acad = Get-Acad }
    catch {
        "AutoCAD: нет связи. Откройте AutoCAD 2018 с нужным чертежом."
        return
    }
    $doc = $acad.ActiveDocument
    $lcm = $null; $ver = $null
    try {
        $r = Invoke-Lisp '(strcat (if (and (boundp (quote lcm:version)) lcm:version) "1" "0") "|" (if (boundp (quote lcm:version)) lcm:version "-") "|" (getvar "ACADVER"))'
        $v = ($r.Value -split '\|') | ForEach-Object { $_.Trim('"') }
        $lcm = if ($v[0] -eq '1') { 'загружен' } else { 'не загружен' }
        $ver = $v[1]
    } catch { $lcm = "ошибка: $($_.Exception.Message)" }

    [pscustomobject]@{
        AutoCAD   = 'запущен'
        Drawing   = $doc.Name
        FullPath  = $doc.FullName
        LCM       = $lcm
        LCMVersion = $ver
        ACADVER   = $doc.GetVariable('ACADVER')
    } | Format-List
}

function Invoke-Dump {
    $payload = @"
(progn
 (setq __ff (open "OUT" "w") __ss (ssget "_X" (list (cons 410 "Model"))))
 (if __ss
  (progn
   (setq __i 0)
   (while (< __i (sslength __ss))
    (setq __e (entget (ssname __ss __i)) __i (1+ __i))
    (setq __p (cdr (assoc 10 __e)) __t (cdr (assoc 1 __e)))
    (write-line
     (strcat (cdr (assoc 0 __e)) "|" (cdr (assoc 8 __e)) "|" (cdr (assoc 5 __e)) "|"
             (if __p (rtos (car __p) 2 4) "") "|"
             (if __p (rtos (cadr __p) 2 4) "") "|"
             (if (and __p (caddr __p)) (rtos (caddr __p) 2 4) "") "|"
             (if __t __t "")) __ff))))
 (close __ff) (princ))
"@
    $outPath = New-ResultPath
    $payload = $payload.Replace('"OUT"', '"' + ($outPath -replace '\\', '/') + '"') -replace "`r?`n", ' '

    if ($PrintLisp) { Write-Output $payload; return }

    Assert-Idle
    Invoke-ComRetry { (Get-AcadDoc).SendCommand($payload.Trim() + ' ') }

    $deadline = (Get-Date).AddSeconds([Math]::Max($TimeoutSec, 60))
    while (-not (Test-Path $outPath)) {
        if ((Get-Date) -gt $deadline) { throw 'Дамп не завершился: чертёж слишком большой или AutoCAD занят.' }
        Start-Sleep -Milliseconds 200
    }

    $lines = [IO.File]::ReadAllLines($outPath, $Script:Cp1251)
    Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue

    $items = foreach ($line in $lines) {
        if (-not $line) { continue }
        $f = $line -split '\|', 7
        if ($f.Count -lt 7) { continue }
        # AutoCAD пишет точку как десятичный разделитель (119103.0000), независимо от локали
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $x = 0.0; $y = 0.0; $z = 0.0
        $null = [double]::TryParse($f[3], [Globalization.NumberStyles]::Float, $inv, [ref]$x)
        $null = [double]::TryParse($f[4], [Globalization.NumberStyles]::Float, $inv, [ref]$y)
        $null = [double]::TryParse($f[5], [Globalization.NumberStyles]::Float, $inv, [ref]$z)
        [pscustomobject]@{ Type = $f[0]; Layer = $f[1]; Handle = $f[2]; X = $x; Y = $y; Z = $z; Text = $f[6] }
    }

    $filtered = @($items)
    if ($Layer) { $filtered = @($filtered | Where-Object { $_.Layer -eq $Layer }) }
    if ($Type) { $filtered = @($filtered | Where-Object { $_.Type -match $Type }) }

    if ($Out) {
        $target = if ([IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $Script:Root $Out }
        if ($Json) { $filtered | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $target -Encoding utf8 }
        else { $filtered | Export-Csv -LiteralPath $target -NoTypeInformation -Delimiter ';' -Encoding utf8 }
        "Объектов: $($filtered.Count) → $target"
    }
    else { $filtered }
}

function Get-LayerTable {
    $outPath = New-ResultPath
    $payload = @"
(progn
 (setq __ff (open "OUT" "w") __x (tblnext "LAYER" T))
 (while __x
  (setq __n (cdr (assoc 2 __x)) __c (cdr (assoc 62 __x)) __f (cdr (assoc 70 __x)))
  (write-line
   (strcat __n "|" (itoa __c) "|" (itoa (logand __f 1)) "|" (itoa (logand __f 4)) "|" (if (< __c 0) "0" "1"))
   __ff)
  (setq __x (tblnext "LAYER")))
 (close __ff) (princ))
"@
    $payload = $payload.Replace('"OUT"', '"' + ($outPath -replace '\\', '/') + '"') -replace "`r?`n", ' '

    if ($PrintLisp) { Write-Output $payload; return }

    Assert-Idle
    Invoke-ComRetry { (Get-AcadDoc).SendCommand($payload.Trim() + ' ') }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not (Test-Path $outPath)) {
        if ((Get-Date) -gt $deadline) { throw 'Таблица слоёв не получена: AutoCAD занят.' }
        Start-Sleep -Milliseconds 150
    }

    $lines = [IO.File]::ReadAllLines($outPath, $Script:Cp1251)
    Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue

    foreach ($line in $lines) {
        if (-not $line) { continue }
        $p = $line -split '\|', 5
        if ($p.Count -lt 5) { continue }
        [pscustomobject]@{
            Layer  = $p[0]
            Color  = [int]$p[1]
            Frozen = ($p[2] -eq '1')
            Locked = ($p[3] -eq '1')
            On     = ($p[4] -eq '1')
        }
    }
}

function Save-Screenshot {
    param([string]$Path)
    $acad = Get-Acad
    $hwnd = $acad.HWND

    if (-not ('Bridge.Win32Shot' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace Bridge {
    public static class Win32Shot {
        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int Left, Top, Right, Bottom; }

        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
        [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hWnd);

        public static void Capture(int handle, string path) {
            IntPtr hwnd = new IntPtr(handle);
            // Свёрнутое окно PrintWindow снимает как иконку (160x28) — разворачиваем
            if (IsIconic(hwnd)) { ShowWindow(hwnd, 9); System.Threading.Thread.Sleep(600); }
            SetForegroundWindow(hwnd);
            System.Threading.Thread.Sleep(300);
            RECT r; GetWindowRect(hwnd, out r);
            int w = r.Right - r.Left, h = r.Bottom - r.Top;
            if (w <= 0 || h <= 0) throw new Exception("Окно AutoCAD не имеет размеров.");
            using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
            using (Graphics g = Graphics.FromImage(bmp)) {
                IntPtr hdc = g.GetHdc();
                bool ok = PrintWindow(hwnd, hdc, 2);
                g.ReleaseHdc(hdc);
                if (!ok) throw new Exception("PrintWindow вернул ошибку.");
                bmp.Save(path, ImageFormat.Png);
            }
        }
    }
}
'@ -ReferencedAssemblies System.Drawing
    }

    $target = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $Script:Root $Path }
    [Bridge.Win32Shot]::Capture([int]$hwnd, $target)
    "Снимок: $target"
}

# ---------------------------------------------------------------- main

try {
    switch ($Verb) {
        'status' { Show-Status }

        'eval' {
            if (-not $Arg) { throw 'Укажите LISP-выражение: cad_bridge.ps1 eval "<выражение>"' }
            if ($PrintLisp) { Invoke-Lisp -Expression $Arg -Timeout $TimeoutSec; return }
            $r = Invoke-Lisp -Expression $Arg -Timeout $TimeoutSec
            # LISP печатает строки в кавычках — снимаем их для читаемости
            if ($r.Value -match '^"(.*)"$' -and $r.Value -notmatch '\\"') { $Matches[1] } else { $r.Value }
        }

        'load' {
            if (-not $Arg) { throw 'Укажите путь к .lsp/.fas/.vlx' }
            $path = Format-LispPath $Arg
            if ($PrintLisp) { Invoke-Lisp -Expression "(load `"$path`")" -Timeout $TimeoutSec; return }
            $r = Invoke-Lisp -Expression "(load `"$path`")" -Timeout $TimeoutSec
            "Загружено: $path`n$($r.Value)"
        }

        'dump' { Invoke-Dump }

        'layers' { Get-LayerTable | Format-Table -AutoSize }

        'shot' {
            if (-not $Out) { $Out = Join-Path $Script:Root 'reports\autocad_screen.png' }
            Save-Screenshot -Path $Out
        }

        'cmd' {
            if (-not $Arg) { throw 'Укажите команду AutoCAD' }
            Send-AcadCommand -Command $Arg -Wait:$Wait
            if ($PrintLisp) { Write-Output ($Arg.Trim() + ' ') } else { "Отправлено: $($Arg.Trim())" }
        }

        'undo' {
            $mode = if ($Arg -eq 'back') { '"_back"' } else { '"_mark"' }
            $r = Invoke-Lisp "(command `"_.undo`" $mode)" -Timeout $TimeoutSec
            if (-not $PrintLisp) { "undo $mode" }
        }

        'cuix' {
            if (-not $Arg) { throw 'Укажите путь к .cuix или .cui' }
            $path = Format-LispPath $Arg
            $expr = "(progn (setvar `"FILEDIA`" 0) (command `"_.menuload`" `"$path`") (setvar `"FILEDIA`" 1) `"ok`")"
            $r = Invoke-Lisp -Expression $expr -Timeout $TimeoutSec
            if (-not $PrintLisp) { "Меню загружено: $path" }
        }

        'report' {
            $file = Get-LatestReport -Kind $Kind
            if (-not $file) { throw "В $($Script:Reports) нет отчётов вида $Kind" }
            $rep = Read-LcmReport -Path $file.FullName
            if ($Json) { $rep | ConvertTo-Json -Depth 5 }
            else {
                $kindName = switch ($rep.Kind) { 'chain' { 'цепочка' } 'geo' { 'сопоставление' } 'check' { 'проверка' } 'points' { 'точки слоя' } 'pair' { 'сравнение слоёв' } default { $rep.Kind } }
                "Отчёт ($kindName): $($rep.File)"
                "  чертёж: $($rep.Drawing)"
                if ($rep.LayerA) { "  слои: $($rep.LayerA) → $($rep.LayerB)" }
                if ($rep.FirstLayer) { "  цепочка: $($rep.FirstLayer) → $($rep.LastLayer)" }
                if ($rep.Radius) { "  порог: $($rep.Radius)" }
                foreach ($k in $rep.Counters.Keys) { "  $($k): $($rep.Counters[$k])" }
                switch ($rep.Kind) {
                    'chain' { "  пар для отрисовки: $($rep.Pairs); строк циклов: $($rep.Cycles)" }
                    'geo'   { "  принято пар: $($rep.Pairs)" }
                    'check' { "  проверено длин: $($rep.Lengths); расхождений: $($rep.Mismatches)" }
                    default { "  строк данных: $($rep.Lengths + $rep.Cycles + $rep.Pairs)" }
                }
            }
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
