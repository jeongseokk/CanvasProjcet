param(
  [string]$InputPath = 'e:\CanvasProjcet\docs\main_android_explained.txt',
  [string]$OutputDir = 'e:\CanvasProjcet\docs\rendered'
)

Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Get-ChildItem $OutputDir -Filter 'page_*.jpg' -ErrorAction SilentlyContinue | Remove-Item -Force

$text = [System.IO.File]::ReadAllText($InputPath, [System.Text.Encoding]::UTF8)
$paragraphs = [regex]::Split($text.Trim(), '\r?\n\s*\r?\n') | Where-Object { $_.Trim().Length -gt 0 }

$pageWidth = 1240
$pageHeight = 1754
[float]$marginLeft = 85
[float]$marginRight = 85
[float]$marginTop = 85
[float]$marginBottom = 85
[float]$contentWidth = $pageWidth - $marginLeft - $marginRight
[float]$maxY = $pageHeight - $marginBottom

$bgColor = [System.Drawing.Color]::FromArgb(255, 255, 253, 248)
$textColor = [System.Drawing.Color]::FromArgb(255, 28, 35, 40)
$lineColor = [System.Drawing.Color]::FromArgb(255, 213, 208, 198)

$titleFont = New-Object System.Drawing.Font('Malgun Gothic', 24, [System.Drawing.FontStyle]::Bold)
$h1Font = New-Object System.Drawing.Font('Malgun Gothic', 18, [System.Drawing.FontStyle]::Bold)
$bodyFont = New-Object System.Drawing.Font('Malgun Gothic', 11.5, [System.Drawing.FontStyle]::Regular)

$stringFormat = New-Object System.Drawing.StringFormat
$stringFormat.Trimming = [System.Drawing.StringTrimming]::Word

$pageIndex = 0
$bitmap = $null
$graphics = $null
[float]$y = 0

function Start-Page {
  param([ref]$BitmapRef, [ref]$GraphicsRef, [ref]$YRef, [ref]$PageIndexRef)
  if ($GraphicsRef.Value -ne $null) { $GraphicsRef.Value.Dispose() }
  if ($BitmapRef.Value -ne $null) { $BitmapRef.Value.Dispose() }
  $PageIndexRef.Value = [int]$PageIndexRef.Value + 1
  $BitmapRef.Value = New-Object System.Drawing.Bitmap($pageWidth, $pageHeight)
  $GraphicsRef.Value = [System.Drawing.Graphics]::FromImage($BitmapRef.Value)
  $GraphicsRef.Value.Clear($bgColor)
  $GraphicsRef.Value.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
  $pen = New-Object System.Drawing.Pen($lineColor, 2)
  $GraphicsRef.Value.DrawLine($pen, $marginLeft, 55, $pageWidth - $marginRight, 55)
  $pen.Dispose()
  $YRef.Value = [float]$marginTop
}

function Save-Page {
  param([ref]$BitmapRef, [int]$Index)
  $outPath = Join-Path $OutputDir ('page_{0:d3}.jpg' -f $Index)
  $BitmapRef.Value.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Jpeg)
}

function Get-Style {
  param([string]$Paragraph)
  $trim = $Paragraph.Trim()
  if ($trim -eq 'main_android.dart 쉬운 해설') {
    return @{ Font = $titleFont; GapBefore = 0; GapAfter = 18 }
  }
  if ($trim -match '^\d+\. ' -or $trim -match '^\d+-\d+\. ') {
    return @{ Font = $h1Font; GapBefore = 14; GapAfter = 8 }
  }
  return @{ Font = $bodyFont; GapBefore = 0; GapAfter = 8 }
}

Start-Page ([ref]$bitmap) ([ref]$graphics) ([ref]$y) ([ref]$pageIndex)

foreach ($paragraph in $paragraphs) {
  $style = Get-Style $paragraph
  $font = $style.Font
  [float]$gapBefore = $style.GapBefore
  [float]$gapAfter = $style.GapAfter
  $brush = New-Object System.Drawing.SolidBrush($textColor)

  $y = [float]$y + $gapBefore
  $size = $graphics.MeasureString($paragraph, $font, [int]$contentWidth, $stringFormat)
  [float]$height = [math]::Ceiling($size.Height)

  if ($y + $height -gt $maxY) {
    Save-Page ([ref]$bitmap) $pageIndex
    Start-Page ([ref]$bitmap) ([ref]$graphics) ([ref]$y) ([ref]$pageIndex)
  }

  $drawRect = New-Object System.Drawing.RectangleF($marginLeft, $y, $contentWidth, $height)
  $graphics.DrawString($paragraph, $font, $brush, $drawRect, $stringFormat)
  $y = [float]$y + $height + $gapAfter
  $brush.Dispose()
}

if ($bitmap -ne $null) { Save-Page ([ref]$bitmap) $pageIndex }
if ($graphics -ne $null) { $graphics.Dispose() }
if ($bitmap -ne $null) { $bitmap.Dispose() }
$titleFont.Dispose(); $h1Font.Dispose(); $bodyFont.Dispose(); $stringFormat.Dispose()
Write-Output ("pages={0}" -f $pageIndex)
