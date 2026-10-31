# cjk_render.ps1 —— 用系统真实中文字体为 OSD 生成 16x16 点阵
#
# 原理:
#   16x16 是极小尺寸, 禁止缩放重采样(会打乱笔画)。
#   做法: 在目标尺寸直接用 GDI+ 渲染(TextRenderingHint=SingleBitPerPixelGridFit,
#         这是专为小字号设计的网格拟合模式, 输出纯黑白无灰边)
#         然后量出墨迹包围盒, 只平移不缩放, 居中放进 16x16 格子。
#
# 用法:
#   .\cjk_gen.ps1 -Chars "日","早"           # 终端看效果
#   .\cjk_gen.ps1                              # 看默认 18 个字
#   .\cjk_gen.ps1 -EmitJs rendered_cjk.js      # 生成 JS 文件
#   .\cjk_gen.ps1 -FontName SimSun             # 换字体
param(
    [string[]]$Chars = @(),
    [string]$FontName = 'SimHei',
    [int]$SizePx = 32,
    [int]$Pad = 1,
    [double]$Threshold = 0.45,
    [string]$EmitJs = '',
    [string]$EmitPngDir = '',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$script:CANVAS = 0

function Get-InkBox {
    param([System.Drawing.Bitmap]$Bmp, [int]$Canvas)
    $minX = $Canvas; $maxX = -1; $minY = $Canvas; $maxY = -1
    for ($y = 0; $y -lt $Canvas; $y++) {
        for ($x = 0; $x -lt $Canvas; $x++) {
            $c = $Bmp.GetPixel($x, $y)
            if (($c.R + $c.G + $c.B) -gt 128) {
                if ($x -lt $minX) { $minX = $x }
                if ($x -gt $maxX) { $maxX = $x }
                if ($y -lt $minY) { $minY = $y }
                if ($y -gt $maxY) { $maxY = $y }
            }
        }
    }
    if ($maxX -lt 0) { return $null }
    return @{ MinX = $minX; MinY = $minY; MaxX = $maxX; MaxY = $maxY
              W = ($maxX - $minX + 1); H = ($maxY - $minY + 1) }
}

function Draw-Char {
    param([string]$Ch, [string]$Fam, [int]$Canvas, [single]$FSize)
    $bmp = New-Object System.Drawing.Bitmap($Canvas, $Canvas, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Black)
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
    $font = New-Object System.Drawing.Font($Fam, $FSize, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Near
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Near
    $g.DrawString($Ch, $font, [System.Drawing.Brushes]::White, 0.0, 0.0, $sf)
    $g.Dispose(); $font.Dispose(); $sf.Dispose()
    return $bmp
}

function Render-One {
    param([string]$Ch, [string]$Fam, [int]$Px, [int]$PadPx, [double]$Thr)

    $canvas = $Px * 3
    $limit  = $Px - 2 * $PadPx

    # ---- 1. 从大到小试字号, 取第一个墨迹不超 limit 的 ----
    $chosen = $null; $chosenSize = 0; $chosenBox = $null
    $biggest = $null; $biggestSize = 0; $biggestBox = $null

    foreach ($size in ($Px + 3)..7) {
        $bmp = Draw-Char -Ch $Ch -Fam $Fam -Canvas $canvas -FSize ([single]$size)
        $box = Get-InkBox -Bmp $bmp -Canvas $canvas
        if ($null -eq $box) { $bmp.Dispose(); continue }

        if ($null -eq $biggest) { $biggest = $bmp; $biggestSize = $size; $biggestBox = $box }
        else { $bmp.Dispose() }

        if ($box.W -le $limit -and $box.H -le $limit) {
            if ($null -ne $chosen) { $chosen.Dispose() }
            $chosen = Draw-Char -Ch $Ch -Fam $Fam -Canvas $canvas -FSize ([single]$size)
            $chosenSize = $size
            $chosenBox = Get-InkBox -Bmp $chosen -Canvas $canvas
            break
        }
        if ($null -ne $biggest -and $biggest -ne $bmp) { }
    }

    if ($null -eq $chosen) {
        if ($null -eq $biggest) {
            return @{ Rows = (New-Object 'int[]' $Px); Ink = 0.0; Empty = $true
                      FontPx = 0; BW = 0; BH = 0 }
        }
        $chosen = $biggest; $chosenSize = $biggestSize; $chosenBox = $biggestBox
    } elseif ($null -ne $biggest -and $biggest -ne $chosen) {
        $biggest.Dispose()
    }

    # ---- 2. 只平移, 居中放进 Px x Px ----
    $ox = [int][math]::Floor(($Px - $chosenBox.W) / 2)
    $oy = [int][math]::Floor(($Px - $chosenBox.H) / 2)

    $rows = New-Object 'int[]' $Px
    $ink = 0
    for ($ty = 0; $ty -lt $Px; $ty++) {
        $bits = 0
        for ($tx = 0; $tx -lt $Px; $tx++) {
            $sx = $tx - $ox + $chosenBox.MinX
            $sy = $ty - $oy + $chosenBox.MinY
            if ($sx -ge 0 -and $sx -lt $canvas -and $sy -ge 0 -and $sy -lt $canvas) {
                $c = $chosen.GetPixel($sx, $sy)
                $lum = ($c.R + $c.G + $c.B) / 765.0
                if ($lum -ge $Thr) {
                    $bits = $bits -bor (1 -shl ($Px - 1 - $tx))
                    $ink++
                }
            }
        }
        $rows[$ty] = $bits
    }
    if ($EmitPngDir -ne '') {
        # Independent image oracle: GDI translates the original raster without
        # using the bit-packing loop. Do not resize or reconstruct it from Rows.
        [void][System.IO.Directory]::CreateDirectory($EmitPngDir)
        $reference = New-Object System.Drawing.Bitmap($Px, $Px)
        $referenceGraphics = [System.Drawing.Graphics]::FromImage($reference)
        $referenceGraphics.Clear([System.Drawing.Color]::Black)
        $referenceGraphics.DrawImageUnscaled($chosen, ($ox - $chosenBox.MinX), ($oy - $chosenBox.MinY))
        $referenceGraphics.Dispose()
        $referencePath = Join-Path $EmitPngDir ('U{0:X4}.png' -f [int][char]$Ch)
        $reference.Save($referencePath, [System.Drawing.Imaging.ImageFormat]::Png)
        $reference.Dispose()
    }
    $chosen.Dispose()

    return @{ Rows = $rows; Ink = ($ink / [double]($Px * $Px)); Empty = $false
              FontPx = $chosenSize; BW = $chosenBox.W; BH = $chosenBox.H }
}

function Show-Art {
    param($Rows)
    $out = @()
    foreach ($r in $Rows) {
        $line = ''
        for ($i = 0; $i -lt $Rows.Count; $i++) {
            if (($r -shr ($Rows.Count - 1 - $i)) -band 1) { $line += '#' } else { $line += '.' }
        }
        $out += $line
    }
    return $out
}

$DEFAULT_CHARS = @(
    [char]0x65E5, [char]0x65E9, [char]0x665A, [char]0x996D, [char]0x540E,
    [char]0x524D, [char]0x6309, [char]0x65F6, [char]0x670D, [char]0x836F,
    [char]0x6BCF, [char]0x6B21, [char]0x8BF7, [char]0x6CE8, [char]0x610F,
    [char]0x7528, [char]0x5DF2, [char]0x5230
)
if ($Chars.Count -eq 0) { $Chars = $DEFAULT_CHARS }

Write-Host "字体=$FontName  目标=${SizePx}x${SizePx}  阈值=$Threshold  留白=$Pad"
Write-Host ""

$results = [ordered]@{}
foreach ($ch in $Chars) {
    $s = [string]$ch
    $r = Render-One -Ch $s -Fam $FontName -Px $SizePx -PadPx $Pad -Thr $Threshold
    $results[$s] = $r

    if (-not $Quiet -and $EmitJs -eq '') {
        $flag = ''
        if ($r.Empty) { $flag = '   <== 空白! 该字体没这个字?' }
        elseif ($r.Ink -lt 0.04) { $flag = '   <== 墨水太少' }
        elseif ($r.Ink -gt 0.60) { $flag = '   <== 墨水太多, 可能糊了' }
        Write-Host ("=== {0}  字号={1}  墨迹={2}x{3}  墨水率={4}%{5} ===" -f `
            $s, $r.FontPx, $r.BW, $r.BH, [math]::Round($r.Ink * 100, 1), $flag)
        Show-Art $r.Rows | ForEach-Object { Write-Host "  $_" }
        Write-Host ""
    }
}

if ($EmitJs -ne '') {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("// 由 cjk_gen.ps1 生成 -- 请勿手改")
    [void]$sb.AppendLine("// 字体=$FontName  尺寸=${SizePx}x${SizePx}  阈值=$Threshold")
    [void]$sb.AppendLine("// 渲染方式: GDI+ SingleBitPerPixelGridFit, 目标尺寸直接渲染(不缩放)")
    [void]$sb.AppendLine("'use strict';")
    [void]$sb.AppendLine("const CJK_RENDERED = {")
    foreach ($k in $results.Keys) {
        $hex = ($results[$k].Rows | ForEach-Object { '0x' + $_.ToString('X8') }) -join ', '
        [void]$sb.AppendLine("  '$k': [$hex],")
    }
    [void]$sb.AppendLine("};")
    [void]$sb.AppendLine("module.exports = { CJK_RENDERED };")
    $outTxt = $sb.ToString() -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($EmitJs, $outTxt, (New-Object System.Text.UTF8Encoding($false)))

    Write-Host "已写出: $EmitJs  ($($results.Count) 个字)"
    $bad = @()
    foreach ($k in $results.Keys) {
        if ($results[$k].Empty -or $results[$k].Ink -lt 0.04) { $bad += $k }
    }
    if ($bad.Count -gt 0) { Write-Host "WARNING 可疑字: $($bad -join ' ')" }
    else { Write-Host "OK 全部字墨迹正常" }
}
