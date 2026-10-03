<#
  Compila la app nativa del mando para Android (tools/controller-app/android) y la deja en
  src/JDCStudioTape/Assets/Play/phone-app.apk: la herramienta la embebe y el móvil la descarga desde
  Ajustes › Android (https://PC/phone-app.apk).

  Uso (PowerShell):
    .\build-android.ps1                    # usa JDK 17, Android SDK y Gradle ya instalados (JAVA_HOME / ANDROID_HOME / gradle)
    .\build-android.ps1 -Download          # descarga lo que falte en %LOCALAPPDATA%\JDCStudioTape\android-toolchain (~0,7 GB)
    .\build-android.ps1 -Download -AcceptLicenses   # además acepta las licencias del Android SDK sin preguntar
    .\build-android.ps1 -Download -FetchOnly        # sólo JDK, command-line tools y Gradle (sin licencias ni compilar)
    -Toolchain <carpeta>                   # otra carpeta para las herramientas

  Descargas de -Download (oficiales):
    JDK 17 (Eclipse Temurin, api.adoptium.net) · Android command-line tools (dl.google.com) ·
    Gradle 8.7 (services.gradle.org) · platforms;android-34 + build-tools;34.0.0 (sdkmanager) ·
    y el plugin de Android para Gradle desde maven.google.com la primera vez que compila.
#>
param([switch]$Download, [switch]$AcceptLicenses, [switch]$Debug, [switch]$FetchOnly, [string]$Toolchain)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest es muchísimo más lento con la barra de progreso
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
# Herramientas fuera del proyecto (no viajan con él).
$tc = if ($Toolchain) { $Toolchain } else { Join-Path $env:LOCALAPPDATA 'JDCStudioTape\android-toolchain' }
$proj = Join-Path $root 'android'
$out = Join-Path $root '..\..\src\JDCStudioTape\Assets\Play\phone-app.apk'

function Get-Zip($url, $dest, $name) {
  $zip = Join-Path $tc ($name + '.zip')
  Write-Host "Descargando $name…  $url"
  Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
  Write-Host ("  " + [math]::Round((Get-Item $zip).Length / 1MB, 1) + ' MB; descomprimiendo…')
  Expand-Archive -Path $zip -DestinationPath $dest -Force
  Remove-Item $zip -Force
}
New-Item -ItemType Directory -Force $tc | Out-Null

# ── JDK 17 ──
$java = $env:JAVA_HOME
if (-not $java -or -not (Test-Path (Join-Path $java 'bin\javac.exe'))) {
  $java = Get-ChildItem $tc -Directory -Filter 'jdk-17*' -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object FullName
}
if (-not $java) {
  if (-not $Download) { throw 'Falta el JDK 17: instala uno (JAVA_HOME) o usa -Download' }
  Get-Zip 'https://api.adoptium.net/v3/binary/latest/17/ga/windows/x64/jdk/hotspot/normal/eclipse' $tc 'jdk17'
  $java = Get-ChildItem $tc -Directory -Filter 'jdk-17*' | Select-Object -First 1 | ForEach-Object FullName
}
$env:JAVA_HOME = $java
$env:Path = (Join-Path $java 'bin') + ';' + $env:Path

# ── Android SDK: command-line tools ──
$sdk = $env:ANDROID_HOME
if (-not $sdk) { $sdk = $env:ANDROID_SDK_ROOT }
if (-not $sdk -or -not (Test-Path $sdk)) { $sdk = Join-Path $tc 'android-sdk' }
$sdkman = Join-Path $sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
if (-not (Test-Path $sdkman)) {
  if (-not $Download) { throw 'Falta el Android SDK: instala Android Studio (ANDROID_HOME) o usa -Download' }
  $tmp = Join-Path $tc 'cmdline-tmp'
  Get-Zip 'https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip' $tmp 'cmdline-tools'
  New-Item -ItemType Directory -Force (Join-Path $sdk 'cmdline-tools') | Out-Null
  Move-Item (Join-Path $tmp 'cmdline-tools') (Join-Path $sdk 'cmdline-tools\latest') -Force
  Remove-Item $tmp -Recurse -Force
}

# ── Gradle ──
$gradle = Get-Command gradle -ErrorAction SilentlyContinue | ForEach-Object Source
if (-not $gradle) {
  $g = Join-Path $tc 'gradle-8.7\bin\gradle.bat'
  if (-not (Test-Path $g)) {
    if (-not $Download) { throw 'Falta Gradle 8.7+: instálalo o usa -Download' }
    Get-Zip 'https://services.gradle.org/distributions/gradle-8.7-bin.zip' $tc 'gradle'
  }
  $gradle = $g
}
if ($FetchOnly) { Write-Host "Descargado en $tc. Falta: licencias del SDK, platform 34, build-tools 34 y compilar."; return }

# ── Android SDK: paquetes (piden aceptar la licencia del SDK) ──
$need = @('platforms;android-34', 'build-tools;34.0.0')
$missing = $need | Where-Object { -not (Test-Path (Join-Path $sdk ($_.Replace(';', '\')))) }
if ($missing) {
  if (-not $Download) { throw ('Faltan paquetes del SDK: ' + ($missing -join ', ') + ' (usa -Download)') }
  if ($AcceptLicenses) { (1..40 | ForEach-Object { 'y' }) | & $sdkman --sdk_root=$sdk --licenses | Out-Null }
  else { & $sdkman --sdk_root=$sdk --licenses }
  & $sdkman --sdk_root=$sdk @missing
  if ($LASTEXITCODE -ne 0) { throw "sdkmanager falló ($LASTEXITCODE)" }
}
$env:ANDROID_HOME = $sdk
# local.properties con barras normales (en un .properties las invertidas son escapes).
Set-Content -Path (Join-Path $proj 'local.properties') -Value ('sdk.dir=' + $sdk.Replace('\', '/')) -Encoding ASCII

# ── compilar ──
$env:GRADLE_USER_HOME = Join-Path $tc 'gradle-home'
# Java 16+ en Windows abre su tubería interna con un socket de dominio Unix en %TEMP%: con una ruta larga (o corta tipo
# SEBAST~1) falla con «Unable to establish loopback connection». Carpeta corta para ese socket:
$sock = Join-Path $env:USERPROFILE '.jdcsock'
New-Item -ItemType Directory -Force $sock | Out-Null
$env:JAVA_TOOL_OPTIONS = '-Djdk.net.unixdomain.tmpdir=' + $sock.Replace('\', '/')
$task = if ($Debug) { 'assembleDebug' } else { 'assembleRelease' }
# (Gradle escribe avisos en stderr: sin Stop, que los tomaría por errores; vale el código de salida)
$ErrorActionPreference = 'Continue'
& $gradle -p $proj $task --no-daemon 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -notmatch '^Picked up JAVA_TOOL_OPTIONS' } | Out-Host
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($code -ne 0) { throw "Gradle falló ($code)" }
$kind = if ($Debug) { 'debug' } else { 'release' }
$apk = Join-Path $proj "app\build\outputs\apk\$kind\app-$kind.apk"
Copy-Item $apk $out -Force
Write-Host ("APK lista: " + (Resolve-Path $out) + ' (' + [math]::Round((Get-Item $out).Length / 1MB, 1) + ' MB). Recompila JDCStudioTape para embeberla.')
