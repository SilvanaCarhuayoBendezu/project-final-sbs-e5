# Prepara el entorno y abre el cuaderno de los PDF de datos\Banco.
# Indique -Sesion para abrir uno de los laboratorios del curso.
# Primera instalacion, desde PowerShell como administrador: .\07_preparar_sesion.ps1 -SinGpu
# Entorno ya instalado: .\07_preparar_sesion.ps1 -SinInstalar
# Solo preparar y verificar: agregue -Completar.
[CmdletBinding()]
param(
    [ValidateSet(0, 2, 3, 4, 5, 6)]
    [int]$Sesion = 0,
    [switch]$SinInstalar,
    [switch]$SinGpu,
    [switch]$ConOllama,
    [switch]$Completar,
    [string]$Curso = "C:\Proyectos",
    [string]$CacheHF = ""
)

$ErrorActionPreference = "Stop"
$raiz = $PSScriptRoot
$cuadernos = @{
    0 = "01_extraccion_informes_bancarios.ipynb"
    2 = "01_LAB_S02_Ingesta.ipynb"
    3 = "02_LAB_S03_OCR_Imagenes.ipynb"
    4 = "03_LAB_S04_PLN_Extraccion.ipynb"
    5 = "04_LAB_S05_LLM_Extraccion.ipynb"
    6 = "05_LAB_S06_Pipelines_E2E.ipynb"
}
$cuaderno = Join-Path $raiz $cuadernos[$Sesion]
$instalador = Join-Path $raiz "01_instalar_vm.ps1"
$verificador = Join-Path $raiz "03_verificar_entorno.py"
$python = Join-Path $Curso "venv\Scripts\python.exe"
$perfilVerificacion = if ($Sesion -eq 0) { 6 } else { $Sesion }

if ($Sesion -eq 0) {
    $indice = Join-Path $raiz "datos\Banco\indice.csv"
    if (-not (Test-Path -LiteralPath $indice -PathType Leaf)) {
        throw "Falta el indice del corpus bancario: $indice"
    }
}
if (-not (Test-Path -LiteralPath $verificador -PathType Leaf)) {
    throw "Falta el verificador local: $verificador"
}
if (-not $Completar -and -not (Test-Path -LiteralPath $cuaderno -PathType Leaf)) {
    throw "Falta el cuaderno local: $cuaderno"
}

if (-not $SinInstalar) {
    if (-not (Test-Path -LiteralPath $instalador -PathType Leaf)) {
        throw "Falta el instalador local: $instalador"
    }
    # El perfil 6 instala tambien PyTorch y verifica el entorno sin exigir un repositorio del curso.
    $opciones = @("-Curso", $Curso, "-Sesion", "6")
    if ($SinGpu) { $opciones += "-SinGpu" }
    if ($ConOllama) { $opciones += "-ConOllama" }
    if ($CacheHF) { $opciones += @("-CacheHF", $CacheHF) }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $instalador @opciones
    if ($LASTEXITCODE -ne 0) {
        throw "El instalador termino con codigo $LASTEXITCODE. Revise $(Join-Path $Curso 'instalacion.log')."
    }
}

if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    throw "Falta el entorno virtual en $python. Ejecute este script sin -SinInstalar desde PowerShell como administrador."
}

$opcionesVerificacion = @("--sesion", "$perfilVerificacion", "--curso", $Curso)
if ($ConOllama) { $opcionesVerificacion += "--con-llm" }
& $python $verificador @opcionesVerificacion
if ($LASTEXITCODE -ne 0) {
    throw "La verificacion del entorno fallo. Revise los errores informados antes de abrir el cuaderno."
}

if ($Completar -or $env:JPY_PARENT_PID) {
    Write-Host "Entorno verificado. Cuaderno de la sesion: $cuaderno"
    return
}

Push-Location -LiteralPath $raiz
try {
    & $python -m jupyterlab $cuaderno
    if ($LASTEXITCODE -ne 0) {
        throw "JupyterLab termino con codigo $LASTEXITCODE."
    }
} finally {
    Pop-Location
}
