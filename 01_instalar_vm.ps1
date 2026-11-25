# Prepara el entorno Windows desde la carpeta local del proyecto.
# Uso en una VM nueva (PowerShell como administrador): .\01_instalar_vm.ps1 -SinGpu
# Instala las dependencias de 02_requirements.txt y, si existe, el paquete local 04_pipeline_sbs.
# Requiere Internet para los paquetes publicados y los instaladores del sistema.
# -SoloEntorno omite los instaladores del sistema. -CacheHF permite copiar modelos desde una cache local.
# -ConOllama o -SoloOllama habilitan la instalacion opcional de Ollama.
# Registro: <Curso>\instalacion.log. Ruta predeterminada: C:\Proyectos.
[CmdletBinding()]
param(
    [string]$Requirements = "",
    [string]$Curso = "C:\Proyectos",
    # Parametros de compatibilidad con 07_preparar_sesion.ps1. El instalador siempre trabaja en local.
    [string]$Rama = "",
    [string]$Repositorio = "",
    [string]$Zip = "",
    [Alias("Modelo")][string[]]$Modelos = @("qwen3.5:4b", "glm-ocr", "qwen3.5:9b"),
    [switch]$SinModelo,
    [switch]$ConOllama,
    [switch]$SoloOllama,
    [string]$InstaladorOllama = "",
    [string]$VersionOllama = "v0.40.15",
    [switch]$SinGpu,
    [switch]$SoloEntorno,
    [switch]$SinClon,
    [switch]$SinModelosHF,
    [string]$CacheHF = "",
    [string]$IndiceTorch = "",
    [int]$Sesion = 8
)
$ErrorActionPreference = "Continue"
$Raiz = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
if (-not $Requirements) { $Requirements = Join-Path $Raiz "02_requirements.txt" }
if (-not $SoloOllama -and -not (Test-Path -LiteralPath $Requirements -PathType Leaf)) {
    throw "Falta el archivo local de dependencias: $Requirements"
}
$Verificador = Join-Path $Raiz "03_verificar_entorno.py"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = "SilentlyContinue"   # sin barra de progreso: Invoke-WebRequest es mucho mas lento con ella en PowerShell 5.1
$Tmp = "$env:TEMP\instalacion"
$Log = "$Curso\instalacion.log"
$Resumen = @()
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($SoloOllama) { $ConOllama = $true; $SoloEntorno = $true }
# con -File, PowerShell entrega «a,b» como un solo texto: se separa por comas
$Modelos = @($Modelos | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $SoloEntorno -and -not $esAdmin) {
    Write-Host "[ERROR] Este instalador instala programas del sistema: abra PowerShell con 'Ejecutar como administrador' y vuelva a ejecutarlo."
    Write-Host "        (Para instalar solo Ollama y sus modelos no hace falta administrador: agregue -SoloOllama.)"
    exit 1
}

# La carpeta trabajo se crea para el verificador de la VM del curso.
foreach ($c in @("datos", "trabajo", "modelos", "venv", "paquete")) { New-Item -ItemType Directory -Force "$Curso\$c" | Out-Null }
New-Item -ItemType Directory -Force $Tmp | Out-Null

function Anotar([string]$nivel, [string]$nombre, [string]$detalle = "") {
    $linea = "[{0}] {1} {2}" -f $nivel, $nombre, $detalle
    Write-Host $linea
    Add-Content -Path $Log -Value ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $linea)
    $script:Resumen += $linea
}

function Existe([string]$cmd) { return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

function ActualizarPath {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}

function Descargar([string]$url, [string]$destino) {
    $existente = Get-Item -LiteralPath $destino -ErrorAction SilentlyContinue
    if ($existente -and -not $existente.PSIsContainer -and $existente.Length -gt 0) { return $true }

    $temporal = "$destino.$([guid]::NewGuid().ToString('N')).part"
    try {
        Invoke-WebRequest -Uri $url -OutFile $temporal -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
        if ((Get-Item -LiteralPath $temporal -ErrorAction Stop).Length -eq 0) {
            throw "El servidor devolvio un archivo vacio."
        }
        Move-Item -LiteralPath $temporal -Destination $destino -Force -ErrorAction Stop
        return $true
    } catch {
        Anotar "ERROR" "descarga" "$url : $($_.Exception.Message)"
        return $false
    } finally {
        if (Test-Path -LiteralPath $temporal -PathType Leaf) {
            Remove-Item -LiteralPath $temporal -ErrorAction SilentlyContinue
        }
    }
}

function Instalar([string]$nombre, [scriptblock]$yaEsta, [scriptblock]$accion) {
    if (& $yaEsta) { Anotar "OK" $nombre "ya instalado"; return }
    Anotar "INFO" $nombre "se instala..."
    try { & $accion } catch { Anotar "ERROR" $nombre $_.Exception.Message }
    ActualizarPath
    if (& $yaEsta) { Anotar "OK" $nombre "instalado" } else { Anotar "ERROR" $nombre "no quedó disponible; si el programa quedó instalado, cierre esta consola, abra una NUEVA como administrador y repita el instalador" }
}

$tieneWinget = Existe "winget"

# 0a. Microsoft Visual C++ Redistributable (x64): sin msvcp140.dll y vcomp140.dll no se importan pymupdf, PyTorch,
# spaCy, accelerate ni paddleocr («DLL load failed», «Error loading c10.dll»). Python 3.12 no lo trae y una VM nueva tampoco.
# Se instala con administrador aunque se use -SoloEntorno; sin administrador solo se avisa. Codigos 1638 (ya hay una version
# mas nueva) y 3010 (pide reiniciar) cuentan como instalado.
$sys32 = "$env:SystemRoot\System32"
$tieneVC = { (Test-Path "$sys32\msvcp140.dll") -and (Test-Path "$sys32\vcomp140.dll") }
if (-not $SoloOllama) {
    if ($esAdmin) {
        Instalar "Visual C++ Redistributable" $tieneVC {
            if (Existe "winget") { winget install --id Microsoft.VCRedist.2015+.x64 -e --silent --accept-package-agreements --accept-source-agreements }
            $exe = "$Tmp\vc_redist.x64.exe"
            if (-not (& $tieneVC) -and (Descargar "https://aka.ms/vs/17/release/vc_redist.x64.exe" $exe)) {
                $p = Start-Process $exe -ArgumentList "/install /quiet /norestart" -Wait -PassThru
                if ($p.ExitCode -notin @(0, 1638, 3010)) { Anotar "AVISO" "Visual C++ Redistributable" "el instalador termino con el codigo $($p.ExitCode)" }
            }
        }
    } elseif (-not (& $tieneVC)) {
        Anotar "AVISO" "Visual C++ Redistributable" "falta (msvcp140.dll): repetir este instalador en PowerShell como administrador"
    }
}

if (-not $SoloEntorno) {
# 0b. Rutas largas de Windows (algunos paquetes de Python tienen rutas de mas de 260 caracteres)
try { New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -Value 1 -PropertyType DWORD -Force | Out-Null; Anotar "OK" "rutas largas" "habilitadas" } catch { Anotar "AVISO" "rutas largas" $_.Exception.Message }

function BuscarPython312 {
    foreach ($ruta in @("$env:ProgramFiles\Python312\python.exe", "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe")) {
        if (Test-Path -LiteralPath $ruta -PathType Leaf) {
            $version = & $ruta --version 2>&1
            if ($LASTEXITCODE -eq 0 -and "$version" -match '^Python 3\.12\.') { return $ruta }
        }
    }
    if (Existe "py") {
        $version = & py -3.12 --version 2>&1
        if ($LASTEXITCODE -eq 0 -and "$version" -match '^Python 3\.12\.') { return "py" }
    }
}

# 1. Python 3.12
Instalar "Python 3.12" { [bool](BuscarPython312) } {
    $exe = "$Tmp\python-3.12.10-amd64.exe"
    if (Descargar "https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe" $exe) {
        $proceso = Start-Process -FilePath $exe -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_launcher=1" -Wait -PassThru -ErrorAction Stop
        if ($proceso.ExitCode -notin @(0, 3010)) { Anotar "ERROR" "Python 3.12" "el instalador devolvio el codigo $($proceso.ExitCode)" }
    }
}

# 2. Git
Instalar "Git" { (Existe "git") -or (Test-Path "$env:ProgramFiles\Git\cmd\git.exe") } {
    if ($tieneWinget) { winget install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements }
    if (-not (Existe "git") -and -not (Test-Path "$env:ProgramFiles\Git\cmd\git.exe")) {
        $exe = "$Tmp\Git-2.47.1-64-bit.exe"
        if (Descargar "https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/Git-2.47.1-64-bit.exe" $exe) { Start-Process $exe -ArgumentList "/VERYSILENT /NORESTART" -Wait }
    }
}

# 3. Java (para tabula-py)
Instalar "Java 17" { (Existe "java") -or (@(Get-ChildItem "$env:ProgramFiles\Eclipse Adoptium\*\bin\java.exe" -ErrorAction SilentlyContinue).Count -gt 0) } {
    if ($tieneWinget) { winget install --id EclipseAdoptium.Temurin.17.JRE -e --silent --accept-package-agreements --accept-source-agreements }
    if (-not (Existe "java") -and @(Get-ChildItem "$env:ProgramFiles\Eclipse Adoptium\*\bin\java.exe" -ErrorAction SilentlyContinue).Count -eq 0) {
        $msi = "$Tmp\temurin17-jre.msi"
        if (Descargar "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.13%2B11/OpenJDK17U-jre_x64_windows_hotspot_17.0.13_11.msi" $msi) {
            Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJavaHome" -Wait
        }
    }
}

# 4. Tesseract con idiomas spa y osd
$tess = "$env:ProgramFiles\Tesseract-OCR"
Instalar "Tesseract OCR" { Test-Path "$tess\tesseract.exe" } {
    $exe = "$Tmp\tesseract-setup.exe"
    if (Descargar "https://github.com/UB-Mannheim/tesseract/releases/download/v5.4.0.20240606/tesseract-ocr-w64-setup-5.4.0.20240606.exe" $exe) {
        Start-Process $exe -ArgumentList "/S" -Wait
    }
}
if (Test-Path "$tess\tessdata") {
    foreach ($idioma in @("spa", "osd")) {
        if (-not (Test-Path "$tess\tessdata\$idioma.traineddata")) {
            Descargar "https://github.com/tesseract-ocr/tessdata_fast/raw/main/$idioma.traineddata" "$tess\tessdata\$idioma.traineddata" | Out-Null
        }
    }
    if ($env:Path -notlike "*Tesseract-OCR*") {
        [Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable("Path", "Machine") + ";$tess", "Machine")
        ActualizarPath
    }
}
} elseif ($SoloOllama) { Anotar "INFO" "programas del sistema" "omitidos por -SoloOllama (solo se instala Ollama y sus modelos)" }
else { Anotar "INFO" "programas del sistema" "omitidos por -SoloEntorno (Python, Git, Java y Tesseract deben estar instalados)" }

# 6. Entorno virtual y librerías
$venvPy = "$Curso\venv\Scripts\python.exe"
if (-not $SoloOllama) {
$py = BuscarPython312
if (-not (Test-Path $venvPy)) {
    if (-not $py) { Anotar "ERROR" "venv" "no hay Python 3.12: ejecutar este script como administrador, sin -SoloEntorno" }
    else {
        Anotar "INFO" "venv" "se crea $Curso\venv"
        if ($py -eq "py") { & py -3.12 -m venv "$Curso\venv" } else { & $py -m venv "$Curso\venv" }
        if ($LASTEXITCODE -ne 0) { Anotar "ERROR" "venv" "Python devolvio el codigo $LASTEXITCODE al crear el entorno" }
    }
}
if (Test-Path $venvPy) {
    & $venvPy -m pip install --upgrade pip 2>&1 | Out-Null
    # PyTorch primero (indice propio): GPU con CUDA 13.2 y, si falla, la rueda de CPU de PyPI (se usa desde la sesion 4)
    if ($Sesion -lt 4) {
        Anotar "INFO" "torch" "se instala desde la sesion 4 (repetir este instalador con -Sesion 4)"
    } elseif ($SinGpu -or $IndiceTorch -eq "cpu") {
        Anotar "INFO" "torch" "se instala la versión de CPU (PyPI)"
        & $venvPy -m pip install torch==2.15.0 2>&1 | Select-Object -Last 1
    } else {
        $indice = if ($IndiceTorch) { $IndiceTorch } else { "https://download.pytorch.org/whl/cu132" }
        Anotar "INFO" "torch GPU" "se instala desde $indice (unos 2 GB)"
        & $venvPy -m pip install torch==2.15.0 --index-url $indice 2>&1 | Select-Object -Last 1
        if ($LASTEXITCODE -ne 0) {
            Anotar "AVISO" "torch GPU" "fallo el indice de GPU; se instala la version de CPU (PyPI)"
            & $venvPy -m pip install torch==2.15.0 2>&1 | Select-Object -Last 1
        }
    }
    if ($Sesion -ge 4) { if ($LASTEXITCODE -eq 0) { Anotar "OK" "torch" "2.15.0" } else { Anotar "ERROR" "torch" "fallo; revisar versión y salida a Internet" } }
    if ($Requirements -and (Test-Path $Requirements)) {
        Anotar "INFO" "pip" "se instala $Requirements (puede tardar varios minutos)"
        & $venvPy -m pip install -r $Requirements 2>&1 | Tee-Object -FilePath "$Curso\pip_requirements.log" | ForEach-Object { if ($_ -match "^(Collecting|Installing collected|Successfully|ERROR)") { Write-Host "  pip: $_" } }
        if ($LASTEXITCODE -eq 0) { Anotar "OK" "librerías del curso" "" } else { Anotar "ERROR" "librerías del curso" "ver pip_requirements.log" }
        $paqueteLocal = Join-Path $Raiz "04_pipeline_sbs"
        if (Test-Path -LiteralPath (Join-Path $paqueteLocal "pyproject.toml") -PathType Leaf) {
            & $venvPy -m pip install -e $paqueteLocal 2>&1 | Tee-Object -FilePath (Join-Path $Curso "pip_pipeline_sbs.log")
            if ($LASTEXITCODE -eq 0) { Anotar "OK" "pipeline_sbs" "instalado desde $paqueteLocal" }
            else { Anotar "ERROR" "pipeline_sbs" "ver pip_pipeline_sbs.log" }
        }
        & $venvPy -m pip check 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Anotar "OK" "pip check" "sin conflictos de versiones" } else { Anotar "AVISO" "pip check" "hay conflictos de versiones; revisar con pip check" }
    } else { Anotar "ERROR" "requirements" "no existe 02_requirements.txt" }
    & $venvPy -m pip install "https://github.com/explosion/spacy-models/releases/download/es_core_news_md-3.8.0/es_core_news_md-3.8.0-py3-none-any.whl" 2>&1 | Select-Object -Last 1
    if ($LASTEXITCODE -eq 0) { Anotar "OK" "modelo spaCy es_core_news_md" "3.8.0" } else { Anotar "ERROR" "modelo spaCy es_core_news_md" "fallo la descarga desde github.com" }

    # Modelos de Hugging Face (sesion 4): se guardan en <Curso>\modelos\hf y HF_HOME queda definida para el usuario
    $hf = "$Curso\modelos\hf"
    New-Item -ItemType Directory -Force $hf | Out-Null
    if ($Curso -eq "C:\Proyectos") {   # solo con la ruta predeterminada: una prueba con otra carpeta no toca las variables del usuario
        [Environment]::SetEnvironmentVariable("HF_HOME", $hf, "User")
        [Environment]::SetEnvironmentVariable("HF_HUB_DISABLE_SYMLINKS_WARNING", "1", "User")
    }
    $env:HF_HOME = $hf
    $env:HF_HUB_DISABLE_SYMLINKS_WARNING = "1"
    Remove-Item Env:HF_HUB_OFFLINE -ErrorAction SilentlyContinue
    Anotar "OK" "HF_HOME" "$hf (se aplica en consolas nuevas)"
    if ($SinModelosHF -or -not $CacheHF) { Anotar "INFO" "modelos de Hugging Face" "copia local omitida; indique -CacheHF para usar una cache existente" }
    elseif ($Sesion -lt 4) { Anotar "INFO" "modelos de Hugging Face" "no se descargan ahora (se usan desde la sesión 4; repetir este instalador con -Sesion 4)" }
    else {
        foreach ($m in @("Davlan/xlm-roberta-base-ner-hrl", "MoritzLaurer/mDeBERTa-v3-base-mnli-xnli")) {
            $nombreCarpeta = "models--" + ($m -replace "/", "--")
            $carpetaModelo = "$hf\hub\$nombreCarpeta"
            if (Test-Path "$carpetaModelo\snapshots") { Anotar "OK" "modelo $m" "ya descargado"; continue }
            if ($CacheHF -and (Test-Path "$CacheHF\hub\$nombreCarpeta")) {
                Anotar "INFO" "modelo $m" "se copia desde $CacheHF"
                robocopy "$CacheHF\hub\$nombreCarpeta" $carpetaModelo /E /NFL /NDL /NJH /NJS /NP | Out-Null
                if (Test-Path "$carpetaModelo\snapshots") { Anotar "OK" "modelo $m" "copiado" } else { Anotar "ERROR" "modelo $m" "no se pudo copiar" }
                continue
            }
            Anotar "AVISO" "modelo $m" "no se encuentra en la cache local $CacheHF"
        }
    }
} else { Anotar "ERROR" "venv" "no se creo $venvPy"; exit 1 }
}

if ($Zip -and (Test-Path $Zip)) {
    Expand-Archive -Path $Zip -DestinationPath "$Curso\paquete" -Force
    Anotar "OK" "paquete" "descomprimido en $Curso\paquete"
}

# 8. GPU
if (Existe "nvidia-smi") { Anotar "OK" "GPU" ((& nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader) -join "; ") }
else { Anotar "AVISO" "GPU" "nvidia-smi no está: falta el controlador NVIDIA; se necesita desde la sesión 4 (pedir a soporte la extensión de GPU de Azure)" }

# 9. Ollama y sus modelos (desde la sesion 5, solo con -ConOllama). Ollama se instala para el usuario de la sesion de Windows
#    (%LOCALAPPDATA%\Programs\Ollama), sin administrador. Las variables se fijan ANTES del instalador, porque el instalador abre
#    Ollama al terminar y Ollama lee la carpeta de modelos al arrancar. No se espera con Start-Process -Wait: esa opcion espera
#    tambien a la aplicacion que el instalador deja abierta y la consola queda colgada.
$ApiOllama = "http://127.0.0.1:11434"
function LeerApiOllama([string]$ruta, [int]$milisegundos) {
    # Sin proxy: un proxy de la red de la VM no debe desviar la consulta a localhost. Devuelve el texto o $null
    try {
        $req = [Net.HttpWebRequest]::Create("$ApiOllama$ruta")
        $req.Proxy = $null; $req.Timeout = $milisegundos; $req.ReadWriteTimeout = $milisegundos
        $resp = $req.GetResponse()
        try { return (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } finally { $resp.Close() }
    } catch { return $null }
}
function VersionApiOllama {
    $texto = LeerApiOllama "/api/version" 3000
    if ($texto) { try { return ($texto | ConvertFrom-Json).version } catch { } }
    return $null
}
function EsperarApiOllama([int]$segundos, [int]$yaEsperados = 0) {
    # Consulta cada 2 s y avisa cada 30 s, para que no parezca colgado
    $inicio = Get-Date; $fin = $inicio.AddSeconds($segundos); $aviso = 30
    do {
        $v = VersionApiOllama
        if ($v) { return $v }
        Start-Sleep -Seconds 2
        $s = [int]((Get-Date) - $inicio).TotalSeconds + $yaEsperados
        if ($s -ge $aviso) { Write-Host "  Ollama arrancando... $s s"; $aviso = $s + 30 }
    } while ((Get-Date) -lt $fin)
    return $null
}
function Resuelto([string]$prefijo) {
    # Quita del resumen un error que la revision posterior ya resolvio, para que el resumen muestre el estado real
    $script:Resumen = @($script:Resumen | Where-Object { -not $_.StartsWith($prefijo) })
}
function VersionProgramaOllama([string]$exe) {
    # ollama --version escribe en la salida normal o en la de errores (si el servidor no corre): se leen las dos
    if (-not (Test-Path $exe)) { return $null }
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo $exe, "--version"
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $p = [Diagnostics.Process]::Start($psi)
        $texto = $p.StandardOutput.ReadToEnd() + " " + $p.StandardError.ReadToEnd()
        $null = $p.WaitForExit(30000)
    } catch { return $null }
    if ($texto -match "(\d+\.\d+\.\d+)") { return $Matches[1] }
    return $null
}
function ModelosOllama {
    $texto = LeerApiOllama "/api/tags" 10000
    if ($texto) { try { return @(($texto | ConvertFrom-Json).models | ForEach-Object { $_.name }) } catch { } }
    return @()
}
function NombreCompleto([string]$m) { if ($m -match ":") { return $m } else { return "${m}:latest" } }
function DescargarModelosOllama([string[]]$lista = $Modelos) {
    # ollama pull muestra el avance y retoma la descarga si se corta; lo ya descargado se omite
    foreach ($m in $lista) {
        if ((ModelosOllama) -contains (NombreCompleto $m)) { Anotar "OK" "modelo $m" "ya descargado"; continue }
        Anotar "INFO" "modelo $m" "se descarga (qwen3.5:4b 3,3 GB; glm-ocr 2,7 GB; qwen3.5:9b 6,6 GB)"
        & $exeOllama pull $m
        if ($LASTEXITCODE -ne 0) {
            Anotar "AVISO" "modelo $m" "la descarga se cortó: se repite (retoma donde quedó)"
            & $exeOllama pull $m
        }
        if ((ModelosOllama) -contains (NombreCompleto $m)) { Resuelto "[ERROR] modelo $m "; Anotar "OK" "modelo $m" "descargado" }
        else { Resuelto "[ERROR] modelo $m "; Anotar "ERROR" "modelo $m" "no quedó descargado: repetir 'ollama pull $m' (retoma donde quedó)" }
    }
}
function CarpetaModelosDelServidor {
    # La ultima linea «server config» del registro dice con que carpeta arranco el servidor de Ollama
    $registro = Join-Path $env:LOCALAPPDATA "Ollama\server.log"
    if (-not (Test-Path $registro)) { return $null }
    $linea = Select-String -Path $registro -Pattern "server config" -SimpleMatch | Select-Object -Last 1
    if ($linea -and $linea.Line -match "OLLAMA_MODELS:(\S*)") { return ($Matches[1] -replace "\\\\", "\") }
    return $null
}
function CuentaDeLaSesion {
    # Cuenta duena del escritorio (explorer.exe) en esta sesion de Windows; $null si no se puede leer
    try {
        $idSesion = (Get-Process -Id $PID).SessionId
        $explorador = Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId=$idSesion" -ErrorAction Stop | Select-Object -First 1
        if ($explorador) {
            $duenio = Invoke-CimMethod -InputObject $explorador -MethodName GetOwner -ErrorAction Stop
            if ($duenio.User) { return "$($duenio.Domain)\$($duenio.User)" }
        }
    } catch { }
    return $null
}

if ($ConOllama) {
    $dirOllama = Join-Path $env:LOCALAPPDATA "Programs\Ollama"
    $exeOllama = Join-Path $dirOllama "ollama.exe"
    $appOllama = Join-Path $dirOllama "ollama app.exe"
    $carpetaModelos = "$Curso\modelos\ollama"
    $cuentaActual = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $cuentaSesion = CuentaDeLaSesion
    $otraCuenta = ($cuentaSesion -and ($cuentaSesion -ne $cuentaActual))
    if ($otraCuenta) {
        Anotar "AVISO" "Ollama" ("PowerShell corre con la cuenta $cuentaActual, pero la sesión de Windows es de ${cuentaSesion}: " +
            "Ollama quedaría en el perfil de $cuentaActual y no se vería en la sesión. No se instala. " +
            "Se abre PowerShell SIN 'Ejecutar como administrador' (en la sesión propia) y se repite este instalador con -SoloOllama.")
    } else {
        if ($esAdmin) { Anotar "INFO" "Ollama" "PowerShell corre como administrador con la misma cuenta de la sesión ($cuentaActual): Ollama queda en su perfil" }
        # 9a. Variables de usuario ANTES de instalar (en la VM del curso) y en esta consola
        New-Item -ItemType Directory -Force $carpetaModelos | Out-Null
        if ($Curso -eq "C:\Proyectos") {   # una prueba con otra carpeta no toca las variables del usuario
            [Environment]::SetEnvironmentVariable("OLLAMA_MODELS", $carpetaModelos, "User")
            [Environment]::SetEnvironmentVariable("OLLAMA_NO_CLOUD", "1", "User")
        }
        $env:OLLAMA_MODELS = $carpetaModelos
        $env:OLLAMA_NO_CLOUD = "1"
        Anotar "OK" "OLLAMA_MODELS" "$carpetaModelos; OLLAMA_NO_CLOUD=1 (sin modelos en la nube)"

        # 9b. Programa: se instala si falta o si su version es anterior a 0.15.5 (glm-ocr la exige)
        $version = VersionProgramaOllama $exeOllama
        $vieja = $false
        if ($version) { try { $vieja = ([version]$version -lt [version]"0.15.5") } catch { $vieja = $false } }
        if ($version -and -not $vieja) {
            Anotar "OK" "Ollama" "ya instalado (versión $version en $dirOllama)"
        } else {
            if ($vieja) {
                Anotar "INFO" "Ollama" "versión $version anterior a 0.15.5: se actualiza"
                Get-Process -Name "ollama app", "ollama" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            }
            $exe = if ($InstaladorOllama -and (Test-Path $InstaladorOllama)) { $InstaladorOllama } else { Join-Path $Tmp "OllamaSetup.exe" }
            $firmado = (Test-Path $exe) -and ((Get-AuthenticodeSignature $exe).Status -eq "Valid")
            if (-not $firmado) {
                Remove-Item $exe -Force -ErrorAction SilentlyContinue
                foreach ($url in @("https://github.com/ollama/ollama/releases/download/$VersionOllama/OllamaSetup.exe", "https://ollama.com/download/OllamaSetup.exe")) {
                    Anotar "INFO" "Ollama" "se descarga OllamaSetup.exe (unos 1,7 GB) desde $url"
                    if (Existe "curl.exe") { & curl.exe -L --fail --retry 3 -o $exe $url } else { try { Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing } catch { } }
                    $firmado = (Test-Path $exe) -and ((Get-AuthenticodeSignature $exe).Status -eq "Valid")
                    if ($firmado) { break }
                    Remove-Item $exe -Force -ErrorAction SilentlyContinue
                    Anotar "AVISO" "Ollama" "la descarga no terminó o el archivo no trae la firma de Ollama; se prueba con otro enlace"
                }
            }
            if (-not $firmado) {
                Anotar "ERROR" "Ollama" "no se pudo descargar OllamaSetup.exe completo: revisar la salida a Internet y repetir el instalador"
            } else {
                Anotar "INFO" "Ollama" "se instala en $dirOllama (sin ventanas; unos minutos)"
                $registroInst = Join-Path $Tmp "ollama_instalacion.log"
                $proc = Start-Process -FilePath $exe -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/LOG=`"$registroInst`"" -PassThru
                $null = $proc.Handle   # conserva el proceso para leer su codigo de salida
                if (-not $proc.WaitForExit(900000)) { Anotar "ERROR" "Ollama" "el instalador no terminó en 15 min (registro: $registroInst)" }
                elseif ($proc.ExitCode -ne 0) { Anotar "ERROR" "Ollama" "el instalador terminó con el código $($proc.ExitCode) (registro: $registroInst)" }
                ActualizarPath
                $version = VersionProgramaOllama $exeOllama
                if ($version) { Anotar "OK" "Ollama" "instalado (versión $version en $dirOllama)" } else { Anotar "ERROR" "Ollama" "no quedó $exeOllama (registro: $registroInst)" }
            }
        }

        # 9c. Servicio: la API debe responder en localhost:11434. La primera vez Ollama puede tardar mas de un minuto en arrancar
        #     (detecta la GPU): se espera hasta 5 min en total. La aplicacion se abre una sola vez y ollama serve solo se inicia si
        #     no corre ningun proceso de Ollama: los dos a la vez compiten por el puerto 11434.
        if (Test-Path $exeOllama) {
            $api = EsperarApiOllama 60
            if (-not $api) {
                if (Get-Process -Name "ollama app", "ollama" -ErrorAction SilentlyContinue) {
                    Anotar "INFO" "Ollama" "está arrancando: se espera hasta 5 min en total"
                } elseif (Test-Path $appOllama) {
                    Anotar "INFO" "Ollama" "la API no responde: se abre la aplicación Ollama (se espera hasta 5 min en total)"
                    Start-Process -FilePath $appOllama
                } else {
                    Anotar "INFO" "Ollama" "la API no responde: se inicia ollama serve en segundo plano"
                    Start-Process -FilePath $exeOllama -ArgumentList "serve" -WindowStyle Hidden
                }
                $api = EsperarApiOllama 180 60
            }
            if (-not $api -and -not (Get-Process -Name "ollama" -ErrorAction SilentlyContinue)) {
                Anotar "INFO" "Ollama" "no hay servidor de Ollama en marcha: se inicia ollama serve en segundo plano"
                Start-Process -FilePath $exeOllama -ArgumentList "serve" -WindowStyle Hidden
            }
            if (-not $api) { $api = EsperarApiOllama 60 240 }
            if ($api) { Anotar "OK" "Ollama (API)" "responde en localhost:11434 (versión $api)" }
            else {
                $regServidor = Join-Path $env:LOCALAPPDATA "Ollama\server.log"
                $cola = if (Test-Path $regServidor) { (Get-Content $regServidor -Tail 5) -join " | " } else { "no existe $regServidor" }
                Anotar "ERROR" "Ollama (API)" "no responde en localhost:11434 tras 5 min: abrir «Ollama» desde Inicio y repetir este instalador. Últimas líneas del registro del servidor: $cola"
            }

            $carpetaServidor = CarpetaModelosDelServidor
            if ($api -and $carpetaServidor -and ($carpetaServidor.TrimEnd("\") -ne $carpetaModelos.TrimEnd("\"))) {
                Anotar "AVISO" "Ollama (carpeta de modelos)" ("el servidor usa $carpetaServidor y no $carpetaModelos (Ollama ya estaba abierto al fijar OLLAMA_MODELS). " +
                    "Se cierra Ollama desde su ícono junto al reloj (Quit Ollama), se abre de nuevo desde Inicio y se repite este instalador.")
            }

            # 9d. Modelos: ollama pull muestra el avance y retoma la descarga si se corta; lo ya descargado se omite
            if ($api -and -not $SinModelo) {
                $libre = [math]::Round((Get-PSDrive -Name $carpetaModelos.Substring(0, 1)).Free / 1GB)
                if ($libre -lt 15) { Anotar "AVISO" "disco" "quedan $libre GB libres; los tres modelos ocupan 12,5 GB" }
                DescargarModelosOllama
            } elseif ($SinModelo) { Anotar "INFO" "modelos de Ollama" "no se descargan (-SinModelo)" }

            # 9e. Revision final del sistema: si la API respondio despues de la espera o una descarga quedo a medias, se completa
            #     ahora y se quitan del resumen los errores ya resueltos; asi el resumen y el verificador muestran el estado real
            if (-not $api) {
                $api = VersionApiOllama
                if ($api) { Resuelto "[ERROR] Ollama (API)"; Anotar "OK" "Ollama (API)" "responde en la revisión final (versión $api)" }
            }
            if ($api -and -not $SinModelo) {
                $presentes = ModelosOllama
                $faltan = @($Modelos | Where-Object { $presentes -notcontains (NombreCompleto $_) })
                if ($faltan.Count -gt 0) {
                    Anotar "INFO" "revisión final" "faltan $($faltan -join ', '): se descargan ahora"
                    DescargarModelosOllama $faltan
                } else { Anotar "OK" "revisión final" "Ollama responde y están los modelos $($Modelos -join ', ')" }
            }
        }
    }
} elseif ($Sesion -ge 5) { Anotar "INFO" "Ollama" "no se instala ahora: en la sesión 5 se instala con el paso 3 de la guía (este instalador con -SoloOllama)" }

# 10. Verificacion final
if ((Test-Path $venvPy) -and (Test-Path -LiteralPath $Verificador -PathType Leaf)) {
    Write-Host "`n===== VERIFICACION DEL ENTORNO (sesiones 1 a $Sesion) ====="
    $extra = @()
    if ($ConOllama -and -not $otraCuenta) { $extra += "--con-llm" }
    & $venvPy $Verificador --sesion $Sesion --curso $Curso @extra
}

Write-Host "`n===== RESUMEN ====="
$Resumen | Where-Object { $_ -notmatch "^\[INFO\]" } | ForEach-Object { Write-Host $_ }
Write-Host "Registro: $Log"
Write-Host "`nSIGUIENTES PASOS (en una consola de PowerShell NUEVA; no hace falta administrador):"
Write-Host "  1. Si se instalaron programas del sistema, abrir la consola nueva: el PATH, HF_HOME y OLLAMA_MODELS se actualizan al abrirla."
Write-Host "  2. Verificar el entorno: $venvPy $Verificador --sesion $Sesion --curso `"$Curso`""
$carpetaInicio = $Raiz
Write-Host "  3. Carpeta de trabajo: cd $carpetaInicio"
Write-Host "  4. Cuaderno: $venvPy -m jupyterlab (desde $carpetaInicio)"
if ($ConOllama) { Write-Host "  5. Modelos de Ollama: ollama list (deben figurar $($Modelos -join ', '))" }
