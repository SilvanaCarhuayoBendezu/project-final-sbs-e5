"""Pipeline documental bancario. Todas las cajas usan puntos PDF sin rotación."""

from __future__ import annotations

import csv
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import unicodedata
from collections import Counter
from datetime import date, datetime, timezone
from pathlib import Path
from uuid import uuid4

import pandas as pd
import pymupdf
import pytesseract
import pyarrow as pa
import pyarrow.parquet as pq
from PIL import Image
from tabula.io import read_pdf


def cargar_inventario(corpus: Path) -> tuple[list[dict], list[dict]]:
    corpus = corpus.resolve()
    with (corpus / "indice.csv").open(encoding="utf-8-sig", newline="") as archivo:
        lector = csv.DictReader(archivo)
        requeridos = {"archivo", "estado", "entidad", "clasificadora", "periodo", "clasificacion"}
        if faltan := requeridos - set(lector.fieldnames or []):
            raise ValueError(f"Columnas faltantes en indice.csv: {sorted(faltan)}")
        filas = list(lector)
    entradas, incidencias, vistos = [], [], set()
    for fila in filas:
        referencia = fila["archivo"] or ""
        ruta = (corpus / referencia.replace("\\", "/")).resolve()
        if fila["estado"] != "descargado":
            causa = fila.get("error") or f"Estado del índice: {fila['estado']}"
        elif not ruta.is_relative_to(corpus) or ruta.suffix.lower() != ".pdf" or not ruta.is_file():
            causa = "Ruta de PDF inválida o archivo ausente"
        elif ruta in vistos:
            causa = "Ruta duplicada en el índice"
        else:
            vistos.add(ruta)
            entradas.append({"archivo": ruta.relative_to(corpus).as_posix(), "ruta": ruta, "indice": fila})
            continue
        incidencias.append({"archivo": referencia, "detalle": causa})
    return entradas, incidencias


def configurar_entorno() -> dict[str, str]:
    programas = Path(os.getenv("ProgramFiles", r"C:\Program Files"))
    java = shutil.which("java")
    if not java:
        java = next(iter(sorted(programas.glob("Eclipse Adoptium/*/bin/java.exe"), reverse=True)), None)
        if java:
            os.environ["PATH"] = str(java.parent) + os.pathsep + os.environ.get("PATH", "")
    if not java:
        raise RuntimeError("Tabula necesita Java. Ejecuta 01_instalar_vm.ps1 para preparar el entorno.")
    comando = os.getenv("TESSERACT_CMD") or shutil.which("tesseract")
    if not comando:
        candidato = programas / "Tesseract-OCR" / "tesseract.exe"
        if candidato.is_file():
            comando = str(candidato)
    if comando:
        pytesseract.pytesseract.tesseract_cmd = comando
    if "spa" not in pytesseract.get_languages():
        raise RuntimeError("El OCR requiere el idioma spa de Tesseract.")
    return {"java": str(java), "tesseract": str(pytesseract.get_tesseract_version())}


def ingestar(entrada: dict) -> dict:
    ruta = entrada["ruta"]
    with ruta.open("rb") as archivo:
        sha256 = hashlib.file_digest(archivo, "sha256").hexdigest()
    with pymupdf.open(ruta) as pdf:
        if not pdf.is_pdf or pdf.needs_pass or not len(pdf):
            raise ValueError("PDF vacío, cifrado o inválido")
        return {
            "archivo": entrada["archivo"], "sha256": sha256, "bytes": ruta.stat().st_size,
            "num_paginas": len(pdf), "indice": entrada["indice"], "pdf": pdf.metadata or {},
        }


def caja(rect) -> list[float]:
    return [round(float(v), 2) for v in rect]


def analizar_pagina(pagina) -> dict:
    limites = pagina.rect * pagina.derotation_matrix
    texto = pagina.get_text().strip()
    imagenes = [pymupdf.Rect(i["bbox"]) & limites for i in pagina.get_image_info()]
    vectores = [
        rect & limites for rect in pagina.cluster_drawings()
        if rect.width >= 80 and rect.height >= 40
    ]
    imagen_grande = any(i.get_area() >= limites.get_area() * 0.08 for i in imagenes)
    tipo = (
        ("mixto" if imagen_grande else "digital") if len(texto) >= 50
        else ("escaneado" if imagen_grande else ("digital" if texto else "sin_texto"))
    )
    return {
        "pagina": pagina.number + 1, "tipo": tipo, "caja": caja(limites), "rotacion": pagina.rotation,
        "caracteres_nativos": len(texto), "imagenes": [caja(i) for i in imagenes if not i.is_empty],
        "vectores": [caja(i) for i in vectores if not i.is_empty],
    }


def region(tipo, motor, rect, **contenido) -> dict:
    return {"tipo": tipo, "motor": motor, "caja": caja(rect), **contenido}


def leer_texto(pagina) -> list[dict]:
    bloques = pagina.get_text("dict", flags=pymupdf.TEXTFLAGS_DICT & ~pymupdf.TEXT_PRESERVE_IMAGES)["blocks"]
    regiones = []
    for bloque in bloques:
        lineas = bloque.get("lines", [])
        texto = "\n".join("".join(s["text"] for s in linea["spans"]) for linea in lineas).strip()
        if texto:
            tamanos = [s["size"] for linea in lineas for s in linea["spans"] if s["text"].strip()]
            negrita = all(
                s["flags"] & pymupdf.TEXT_FONT_BOLD for linea in lineas for s in linea["spans"] if s["text"].strip()
            )
            tipo = "titulo" if len(lineas) == 1 and len(texto) <= 100 and (negrita or max(tamanos) >= 14) else "texto"
            regiones.append(region(tipo, "pymupdf", bloque["bbox"], texto=texto))
    return regiones


def candidatos_tablas(pagina) -> list[tuple[pymupdf.Rect, bool]]:
    candidatos = []
    for tabla in pagina.find_tables().tables:
        if tabla.row_count >= 2 and tabla.col_count >= 2:
            candidatos.append((pymupdf.Rect(tabla.bbox), True))
    # Los indicadores en columnas pueden tener solo líneas horizontales.
    limites = pagina.rect * pagina.derotation_matrix
    for titulo in pagina.search_for("Indicadores Financieros"):
        textos = pagina.get_text("blocks", clip=pymupdf.Rect(
            titulo.x0 - 3, titulo.y1, limites.x1, min(titulo.y1 + 100, limites.y1),
        ))
        filas = [b for b in textos if b[6] == 0 and len(re.findall(r"\d", b[4])) >= 3]
        if len(filas) >= 2:
            rect = pymupdf.Rect(
                titulo.x0 - 2, filas[0][1] - 2, max(f[2] for f in filas) + 2, filas[-1][3] + 2,
            ) & limites
            # Las tablas pequeñas ya contenidas se sustituyen por la región completa.
            candidatos = [(r, modo) for r, modo in candidatos if not rect.contains(r)]
            candidatos.append((rect, False))
    return candidatos


def leer_tabla(ruta: Path, pagina, rect, cuadricula: bool) -> list[dict]:
    visible = rect * pagina.rotation_matrix
    tablas = read_pdf(
        str(ruta), pages=pagina.number + 1, area=[visible.y0, visible.x0, visible.y1, visible.x1],
        guess=False, lattice=cuadricula, stream=not cuadricula, output_format="json",
        multiple_tables=True, force_subprocess=True, silent=True,
    )
    regiones = []
    for tabla in tablas:
        filas = [[celda["text"] for celda in fila] for fila in tabla["data"]]
        if any(any(str(c).strip() for c in fila) for fila in filas):
            limites = pymupdf.Rect(tabla["left"], tabla["top"], tabla["right"], tabla["bottom"])
            regiones.append(region("tabla", "tabula-py", limites * pagina.derotation_matrix, filas=filas))
    return regiones


def leer_ocr(pagina, rect, tipo: str) -> dict:
    rotacion = pagina.rotation
    try:
        if rotacion:
            pagina.set_rotation(0)
        pix = pagina.get_pixmap(dpi=230, clip=rect, alpha=False)
    finally:
        if rotacion:
            pagina.set_rotation(rotacion)
    imagen = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)
    datos = pytesseract.image_to_data(
        imagen, lang="spa", config=f"--psm {3 if tipo == 'ocr_pagina' else 11}",
        timeout=90, output_type=pytesseract.Output.DICT,
    )
    lineas, confianza = {}, []
    for i, palabra in enumerate(datos["text"]):
        if palabra.strip():
            clave = (datos["block_num"][i], datos["par_num"][i], datos["line_num"][i])
            lineas.setdefault(clave, []).append(palabra.strip())
            confianza.append(float(datos["conf"][i]))
    return region(
        tipo, "tesseract", rect, texto="\n".join(" ".join(linea) for linea in lineas.values()),
        confianza=round(sum(confianza) / (100 * len(confianza)), 3) if confianza else None,
    )


def solapamiento(a, b) -> float:
    a, b = pymupdf.Rect(a), pymupdf.Rect(b)
    menor = min(a.get_area(), b.get_area())
    return (a & b).get_area() / menor if menor else 0


def ya_en_tabla(region_texto: dict, tablas: list[dict]) -> bool:
    rect = pymupdf.Rect(region_texto["caja"])
    palabras = Counter(limpiar(region_texto["texto"]).casefold().split())
    for tabla in tablas:
        interseccion = rect & pymupdf.Rect(tabla["caja"])
        if rect.get_area() and interseccion.get_area() / rect.get_area() >= 0.95:
            celdas = Counter(limpiar(" ".join(c for fila in tabla["filas"] for c in fila)).casefold().split())
            if palabras <= celdas:
                return True
    return False


def ordenar_layout(regiones: list[dict], limites: list[float]) -> list[dict]:
    """Lee columnas de izquierda a derecha entre regiones que cruzan ambas."""
    ancho = limites[2] - limites[0]
    candidatos = [limites[0] + ancho * i / 100 for i in range(42, 73, 2)]
    def corte(x):
        izq = sum(r["caja"][2] <= x - 2 for r in regiones)
        der = sum(r["caja"][0] >= x + 2 for r in regiones)
        return (izq + der if min(izq, der) >= 2 else 0, min(izq, der))
    centro = max(candidatos, key=corte)
    izquierda = [r for r in regiones if r["caja"][2] <= centro - 2]
    derecha = [r for r in regiones if r["caja"][0] >= centro + 2]
    vertical = lambda r: (r["caja"][1], r["caja"][0])
    if len(izquierda) < 2 or len(derecha) < 2:
        return sorted(regiones, key=vertical)
    bandas = sorted((r for r in regiones if r not in izquierda and r not in derecha), key=vertical)
    orden = []
    for banda in bandas:
        for columna in (izquierda, derecha):
            anteriores = sorted((r for r in columna if r["caja"][1] < banda["caja"][1]), key=vertical)
            orden.extend(anteriores)
            columna[:] = [r for r in columna if r not in anteriores]
        orden.append(banda)
    return orden + sorted(izquierda, key=vertical) + sorted(derecha, key=vertical)


def extraer_layout(ruta: Path, pagina, analisis: dict) -> tuple[list[dict], list[dict]]:
    regiones, avisos = leer_texto(pagina), []
    limites = pymupdf.Rect(analisis["caja"])
    if analisis["caracteres_nativos"]:
        try:
            for rect, cuadricula in candidatos_tablas(pagina):
                try:
                    resultado = leer_tabla(ruta, pagina, rect, cuadricula)
                    if not resultado and cuadricula:
                        resultado = leer_tabla(ruta, pagina, rect, False)
                    for tabla in resultado:
                        if not any(r["tipo"] == "tabla" and solapamiento(r["caja"], tabla["caja"]) > 0.9
                                   for r in regiones):
                            regiones.append(tabla)
                    if not resultado:
                        avisos.append({"regla": "tabla_sin_celdas", "detalle": str(caja(rect))})
                except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                    avisos.append({"regla": "tabula", "detalle": str(error)})
        except (ValueError, RuntimeError) as error:
            avisos.append({"regla": "deteccion_tabla", "detalle": str(error)})
    if analisis["tipo"] in {"escaneado", "sin_texto"}:
        zonas = [("ocr_pagina", limites)]
        avisos.append({"regla": "tablas_sin_capa_texto", "detalle": "Revisar posibles tablas rasterizadas"})
    else:
        zonas = []
        for coordenadas in analisis["imagenes"] + analisis["vectores"]:
            rect = pymupdf.Rect(coordenadas)
            if rect.get_area() < limites.get_area() * 0.035:
                continue
            if any(solapamiento(rect, r["caja"]) > 0.8 for r in regiones if r["tipo"] == "tabla"):
                continue
            if not any(solapamiento(rect, otra) > 0.8 for _, otra in zonas):
                zonas.append(("grafico", rect))
    for tipo, rect in zonas:
        try:
            regiones.append(leer_ocr(pagina, rect, tipo))
        except (OSError, ValueError, RuntimeError) as error:
            avisos.append({"regla": "ocr", "detalle": str(error)})
    tablas = [r for r in regiones if r["tipo"] == "tabla"]
    regiones = [r for r in regiones if r["tipo"] not in {"texto", "titulo"} or not ya_en_tabla(r, tablas)]
    for i, entrada in enumerate(ordenar_layout(regiones, analisis["caja"]), 1):
        entrada["orden"] = i
    return sorted(regiones, key=lambda r: r["orden"]), avisos


def limpiar(texto: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", texto).replace("\u00ad", "").split())


UNIDADES = re.compile(
    r"\b(miles|millones)\s+de\s+(soles|d[oó]lares)\b|\b(PEN|USD)\b|S/|US\$|%",
    re.IGNORECASE,
)
UNIDAD_TABLA = re.compile(r"\b(?:cifras|montos|importes|expresad[oa]s)\s+en\s+((?:miles|millones) de (?:soles|d[oó]lares))\b", re.I)


def unidad_tabla(tabla: dict, regiones: list[dict]) -> tuple[str | None, str | None]:
    x0, y0, x1, y1 = tabla["caja"]
    for candidata in regiones:
        izquierda, arriba, derecha, abajo = candidata["caja"]
        if derecha <= x0 or izquierda >= x1 or not (0 <= arriba - y1 <= 30 or 0 <= y0 - abajo <= 30):
            continue
        if nota := UNIDAD_TABLA.search(candidata["texto"]):
            return nota.group(1).lower(), nota.group()
    return None, None


def reconstruir(regiones: list[dict]) -> list[dict]:
    resultado = []
    for r in regiones:
        if r["tipo"] == "tabla":
            filas = [[limpiar(c) for c in fila] for fila in r["filas"]]
            filas = [fila for fila in filas if any(fila)]
            ancho = max(map(len, filas), default=0)
            filas = [fila + [""] * (ancho - len(fila)) for fila in filas]
            texto = "\n".join(" | ".join(fila) for fila in filas)
            resultado.append({**r, "filas": filas, "texto": texto})
        else:
            bruto = r["texto"]
            texto = limpiar(re.sub(r"(?<=\w)-\s*\n\s*(?=[a-záéíóúñ])", "", bruto))
            resultado.append({**r, "texto_original": bruto, "texto": texto})
    return [
        {**r, "unidades": list(dict.fromkeys(m.group(0) for m in UNIDADES.finditer(r["texto"])))}
        for r in resultado
    ]


PERSPECTIVA = re.compile(r"\bPerspectiva(?: de la calificaci[oó]n)?\s*:?\s*(Estable|Positiva|Negativa|En desarrollo)\b", re.I)
MESES = {
    nombre: i for i, nombre in enumerate(
        "enero febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre".split(), 1
    )
}
MESES["setiembre"] = 9
FECHA = re.compile(
    r"\b(?:[0-3]?\d/[01]?\d/\d{4}|\d{4}-[01]\d-[0-3]\d|"
    rf"[0-3]?\d de (?:{'|'.join(MESES)}) de \d{{4}})\b", re.I,
)
RATING = re.compile(r"\b(?:fortaleza financiera|calificaci[oó]n (?:actual|de la entidad))\s*(?:\|\s*|:\s*)?([A-D][+-]?)(?![\w+-])", re.I)
INDICADOR = re.compile(r"\b(?:total activos|patrimonio|resultado(?: neto)?|ROA|ROE|capital global|morosidad|liquidez)\b", re.I)


def extraer_semantica(documento: dict, paginas: list[dict]) -> list[dict]:
    hallazgos = []
    entidades = {}
    for campo in ("entidad", "clasificadora"):
        if valor := documento["indice"].get(campo):
            hallazgos.append({"tipo": campo, "valor": valor, "origen": "indice", "evidencia": valor})
            palabras = re.findall(r"\w+", valor)
            if palabras:
                entidades[campo] = re.compile(r"(?<!\w)" + r"[\W_]+".join(map(re.escape, palabras)) + r"(?!\w)", re.I)
    for pagina in paginas:
        regiones = pagina["regiones"]
        for r in regiones:
            procedencia = {"pagina": pagina["pagina"], "orden": r["orden"], "origen": r["motor"], "caja": r["caja"]}
            texto = r["texto"]
            texto_perspectiva = texto
            caja_perspectiva = r["caja"]
            if pagina["pagina"] <= 2 and r["tipo"] != "tabla":
                for campo, patron in entidades.items():
                    if coincidencia := patron.search(texto):
                        hallazgos.append({**procedencia, "tipo": campo, "valor": coincidencia.group(),
                                          "evidencia": coincidencia.group()})
            if r["tipo"] == "titulo" and texto.casefold() == "perspectiva":
                x0, _, x1, y1 = r["caja"]
                vecino = next((
                    c for c in regiones
                    if c["tipo"] in {"texto", "titulo"} and 0 <= c["caja"][1] - y1 <= 18
                    and c["caja"][0] < x1 and c["caja"][2] > x0
                ), None)
                if vecino:
                    texto_perspectiva += " " + vecino["texto"]
                    caja_perspectiva = caja(pymupdf.Rect(r["caja"]) | pymupdf.Rect(vecino["caja"]))
            for tipo, patron in (("perspectiva", PERSPECTIVA), ("calificacion_pdf", RATING), ("fecha", FECHA)):
                for m in patron.finditer(texto_perspectiva if tipo == "perspectiva" else texto):
                    valor = m.group(1) if m.lastindex else m.group()
                    normalizado = None
                    if tipo == "fecha":
                        try:
                            if "/" in valor:
                                fecha = datetime.strptime(valor, "%d/%m/%Y").date()
                            elif " de " in valor.lower():
                                dia, _, mes, _, anio = valor.lower().split()
                                fecha = date(int(anio), MESES[mes], int(dia))
                            else:
                                fecha = date.fromisoformat(valor)
                            normalizado = fecha.isoformat()
                        except ValueError:
                            pass
                    hallazgos.append({
                        **procedencia, "tipo": tipo, "valor": valor, "normalizado": normalizado,
                        "caja": caja_perspectiva if tipo == "perspectiva" else r["caja"],
                        "evidencia": m.group(),
                    })
            if r["tipo"] == "tabla" and r["filas"]:
                unidad, evidencia_unidad = unidad_tabla(r, regiones)
                encabezados = next(
                    (fila for fila in r["filas"] if any(re.fullmatch(r"[A-Za-zÁÉÍÓÚáéíóú]{3}[-–]\d{2,4}", c) for c in fila)), []
                )
                for fila in r["filas"]:
                    if not fila or not INDICADOR.search(fila[0]):
                        continue
                    for j, celda in enumerate(fila[1:], 1):
                        if re.fullmatch(r"[-−]?\d[\d.,]*\s*%?", celda):
                            hallazgos.append({
                                **procedencia, "tipo": "indicador", "nombre": fila[0], "valor": celda,
                                "periodo": encabezados[j] if j < len(encabezados) else None,
                                "unidad": "%" if "%" in celda else unidad,
                                "evidencia_unidad": celda if "%" in celda else evidencia_unidad,
                                "evidencia": " | ".join(fila),
                            })
    return hallazgos


def controlar_calidad(documento: dict, paginas: list[dict], campos: list[dict]) -> list[dict]:
    alertas = [{**i, "pagina": p["pagina"]} for p in paginas for i in p["avisos"]]
    for p in paginas:
        if not any(r["texto"] for r in p["regiones"]):
            alertas.append({"pagina": p["pagina"], "regla": "pagina_sin_texto", "detalle": "La página no produjo texto"})
    for c in campos:
        if c["tipo"] == "fecha" and not c["normalizado"]:
            alertas.append({"pagina": c["pagina"], "regla": "fecha_invalida", "detalle": c["evidencia"]})
        if c["tipo"] == "indicador" and not c["periodo"]:
            alertas.append({"pagina": c["pagina"], "regla": "indicador_sin_periodo", "detalle": c["nombre"]})
        if (c["tipo"] == "indicador" and c["nombre"].casefold() in {"total activos", "morosidad", "capital global"}
                and c["valor"].startswith(("-", "−"))):
            alertas.append({"pagina": c["pagina"], "regla": "indicador_negativo", "detalle": c["evidencia"]})
    esperado = limpiar(documento["indice"].get("clasificacion") or "").upper()
    calificaciones = {c["valor"].upper() for c in campos if c["tipo"] == "calificacion_pdf"}
    if esperado and calificaciones and esperado not in calificaciones:
        alertas.append({"regla": "calificacion_discrepante", "detalle": f"Índice {esperado}; PDF {sorted(calificaciones)}"})
    elif esperado and not calificaciones:
        alertas.append({"regla": "calificacion_sin_evidencia", "detalle": f"Índice {esperado}; sin coincidencia rotulada"})
    return alertas


def procesar(entrada: dict) -> dict:
    documento, paginas, campos, calidad = {"archivo": entrada["archivo"], "indice": entrada["indice"]}, [], [], []
    try:
        documento = ingestar(entrada)
        with pymupdf.open(entrada["ruta"]) as pdf:
            for pagina in pdf:
                try:
                    perfil = analizar_pagina(pagina)
                    regiones, avisos = extraer_layout(entrada["ruta"], pagina, perfil)
                    paginas.append({**perfil, "regiones": reconstruir(regiones), "avisos": avisos})
                except (RuntimeError, ValueError, OSError) as error:
                    calidad.append({"pagina": pagina.number + 1, "regla": "error_pagina", "detalle": str(error)})
        campos = extraer_semantica(documento, paginas)
        calidad.extend(controlar_calidad(documento, paginas, campos))
    except (RuntimeError, ValueError, OSError) as error:
        calidad.append({"regla": "error_documento", "detalle": str(error)})
    tipos = {p["tipo"] for p in paginas}
    documento["tipo_pdf"] = next(iter(tipos)) if len(tipos) == 1 else ("mixto" if tipos else None)
    documento["estado"] = "error" if not paginas else ("revisar" if calidad else "ok")
    return {"documento": documento, "paginas": paginas, "campos": campos, "calidad": calidad}


def exportar(resultados: list[dict], incidencias: list[dict], destino: Path) -> Path:
    """Publica un directorio por corrida con Parquet tipado y reporte HTML."""
    esquemas = {
        "documentos": {"archivo": pa.string(), "sha256": pa.string(), "bytes": pa.int64(), "num_paginas": pa.int32(),
                       "tipo_pdf": pa.string(), "estado": pa.string(), "entidad": pa.string(), "clasificadora": pa.string(),
                       "periodo": pa.string(), "clasificacion_indice": pa.string(), "url": pa.string(),
                       "indice": pa.string(), "pdf": pa.string()},
        "paginas": {"archivo": pa.string(), "pagina": pa.int32(), "tipo": pa.string(), "rotacion": pa.int32(),
                    "caracteres_nativos": pa.int32(), "caja": pa.list_(pa.float64()), "imagenes": pa.string(),
                    "vectores": pa.string()},
        "regiones": {"archivo": pa.string(), "pagina": pa.int32(), "orden": pa.int32(), "tipo": pa.string(),
                     "motor": pa.string(), "caja": pa.list_(pa.float64()), "texto": pa.string(),
                     "texto_original": pa.string(), "confianza": pa.float64(), "unidades": pa.list_(pa.string()),
                     "filas": pa.list_(pa.list_(pa.string()))},
        "campos": {"archivo": pa.string(), "pagina": pa.int32(), "orden": pa.int32(), "tipo": pa.string(),
                   "origen": pa.string(), "caja": pa.list_(pa.float64()), "nombre": pa.string(), "valor": pa.string(),
                   "normalizado": pa.string(), "periodo": pa.string(), "unidad": pa.string(), "evidencia": pa.string(),
                   "evidencia_unidad": pa.string()},
        "calidad": {"archivo": pa.string(), "pagina": pa.int32(), "regla": pa.string(), "detalle": pa.string()},
    }
    filas = {nombre: [] for nombre in esquemas}
    filas["calidad"].extend({**i, "regla": "indice"} for i in incidencias)
    for resultado in resultados:
        d = resultado["documento"]
        archivo = d["archivo"]
        indice = d["indice"]
        metadatos = {k: indice.get(k) for k in ("entidad", "clasificadora", "periodo", "url")}
        filas["documentos"].append({**d, **metadatos, "clasificacion_indice": indice.get("clasificacion"),
                                    "indice": json.dumps(indice, ensure_ascii=False),
                                    "pdf": json.dumps(d.get("pdf", {}), ensure_ascii=False)})
        filas["campos"].extend({"archivo": archivo, **c} for c in resultado["campos"])
        filas["calidad"].extend({"archivo": archivo, **c} for c in resultado["calidad"])
        for p in resultado["paginas"]:
            filas["paginas"].append({"archivo": archivo, **p, "imagenes": json.dumps(p["imagenes"]),
                                     "vectores": json.dumps(p["vectores"])})
            filas["regiones"].extend({"archivo": archivo, "pagina": p["pagina"], **r} for r in p["regiones"])

    destino.mkdir(parents=True, exist_ok=True)
    corrida = destino / f"{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}-{uuid4().hex[:8]}"
    with tempfile.TemporaryDirectory(dir=destino) as temporal:
        preparado = Path(temporal) / "corrida"
        preparado.mkdir()
        for nombre, campos in esquemas.items():
            tabla = pa.Table.from_pylist(filas[nombre], schema=pa.schema(list(campos.items())))
            pq.write_table(tabla, preparado / f"{nombre}.parquet")
        estados = Counter(d["estado"] for d in filas["documentos"])
        regiones = Counter(r["tipo"] for r in filas["regiones"])
        resumen = [
            ("Documentos", len(resultados)), ("Páginas", len(filas["paginas"])),
            ("Tablas", regiones["tabla"]), ("Gráficos OCR", regiones["grafico"]),
            ("Páginas OCR", regiones["ocr_pagina"]), ("Campos", len(filas["campos"])),
            ("Alertas", len(filas["calidad"])), *sorted(estados.items()),
        ]
        tablas_html = [
            ("Cobertura", pd.DataFrame(resumen, columns=["Indicador", "Total"])),
            ("Documentos", pd.DataFrame(filas["documentos"], columns=[
                "archivo", "entidad", "clasificadora", "tipo_pdf", "num_paginas", "estado",
            ])),
            ("Alertas de calidad", pd.DataFrame(filas["calidad"], columns=list(esquemas["calidad"]))),
        ]
        html = "\n".join(f"<h2>{titulo}</h2>\n{df.to_html(index=False, escape=True)}" for titulo, df in tablas_html)
        enlaces = " · ".join(f"<a href='{nombre}.parquet'>{nombre}.parquet</a>" for nombre in esquemas)
        (preparado / "reporte.html").write_text(
            "<!doctype html><html lang='es'><meta charset='utf-8'><title>Extracción bancaria</title>"
            "<style>body{font:16px system-ui;margin:2rem}table{border-collapse:collapse}"
            "td,th{padding:.4rem;text-align:left;border:1px solid #ccc}th{background:#eef3f8}</style>"
            "<h1>Extracción documental bancaria</h1>" + f"<p>{enlaces}</p>" + html + "</html>", encoding="utf-8",
        )
        preparado.rename(corrida)
    return corrida
