#!/usr/bin/env python3
"""Calculadora de costo real de LLM para proyectos de modernización de aplicaciones.

Reimplementación mínima de la idea de KaiserWhoLearns/ReasoningEffortLLM
(arXiv:2610.34491): costo = tokens x tarifa, más costo de espera, y una
política de "escalera" (esfuerzo bajo siempre, un reintento en esfuerzo alto
solo en la fracción que falla). Solo biblioteca estándar; no llama a ninguna API.
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from datetime import date
from pathlib import Path

AQUI = Path(__file__).resolve().parent
MILLON = 1_000_000


class ErrorDatos(ValueError):
    """Dato faltante o inválido en los archivos de entrada o en los parámetros."""


# ---------------------------------------------------------------- tarifas

def tarifa_vigente(modelo: dict, fecha: date) -> dict:
    """Devuelve la tarifa del modelo vigente en `fecha` (límites inclusivos)."""
    vigentes = []
    for t in modelo["tarifas"]:
        desde = date.fromisoformat(t["vigente_desde"]) if t.get("vigente_desde") else date.min
        hasta = date.fromisoformat(t["vigente_hasta"]) if t.get("vigente_hasta") else date.max
        if desde <= fecha <= hasta:
            vigentes.append(t)
    if not vigentes:
        raise ErrorDatos(f"{modelo['modelo']}: no hay tarifa vigente para {fecha.isoformat()}")
    if len(vigentes) > 1:
        raise ErrorDatos(f"{modelo['modelo']}: tarifas solapadas para {fecha.isoformat()}")
    return vigentes[0]


# ---------------------------------------------------------------- aritmética

def separar_tokens(tokens_mes: float, prop_entrada: float, prop_salida: float) -> tuple[float, float]:
    """Reparte los tokens mensuales en (entrada, salida)."""
    if tokens_mes < 0:
        raise ErrorDatos("tokens_mes no puede ser negativo")
    if abs(prop_entrada + prop_salida - 1) > 1e-9:
        raise ErrorDatos("proporcion_entrada + proporcion_salida debe sumar 1")
    return tokens_mes * prop_entrada, tokens_mes * prop_salida


def costo_tokens(tok_entrada: float, tok_salida: float, tarifa: dict) -> float:
    """Costo en la moneda de la tarifa: tokens x tarifa por millón."""
    return (tok_entrada * tarifa["entrada"] + tok_salida * tarifa["salida"]) / MILLON


def costo_lista(tok_entrada: float, tok_salida: float, tarifa: dict) -> float:
    """Costo mensual de lista (esfuerzo bajo, sin tokens de razonamiento)."""
    return costo_tokens(tok_entrada, tok_salida, tarifa)


def costo_razonamiento(tok_entrada: float, tok_salida: float, tarifa: dict, multiplicador: float) -> float:
    """Costo en esfuerzo alto: la salida facturada es salida x multiplicador."""
    if multiplicador < 1:
        raise ErrorDatos("multiplicador_razonamiento debe ser >= 1")
    return costo_tokens(tok_entrada, tok_salida * multiplicador, tarifa)


def costo_escalera(tok_entrada: float, tok_salida: float, tarifa: dict,
                   multiplicador: float, tasa_fallo: float) -> float:
    """Escalera: bajo siempre + alto solo en la fracción que falla."""
    if not 0 <= tasa_fallo <= 1:
        raise ErrorDatos("tasa_fallo_esfuerzo_bajo debe estar entre 0 y 1")
    return (costo_lista(tok_entrada, tok_salida, tarifa)
            + tasa_fallo * costo_razonamiento(tok_entrada, tok_salida, tarifa, multiplicador))


def costo_espera(tok_salida: float, tokens_por_segundo: float, salario_hora: float) -> float:
    """Costo de esperar la respuesta: tokens de salida / velocidad x salario."""
    if tokens_por_segundo <= 0:
        raise ErrorDatos("tokens_por_segundo debe ser > 0")
    if salario_hora < 0:
        raise ErrorDatos("salario_hora no puede ser negativo")
    return tok_salida / tokens_por_segundo / 3600 * salario_hora


# ---------------------------------------------------------------- cálculo

def calcular(precios: dict, escenarios: dict, fecha: date, *, tokens_mes: float | None = None,
             multiplicador: float | None = None, tasa_fallo: float | None = None,
             tipo_cambio: float = 1.0, salario_hora: float | None = None,
             tokens_por_segundo: float | None = None) -> list[dict]:
    """Una fila por (modelo, escenario). Los valores sin dato quedan en None.

    Los costos de tokens se multiplican por `tipo_cambio` (USD -> moneda de
    salida). `salario_hora` ya debe venir en la moneda de salida.
    """
    con_espera = salario_hora is not None and tokens_por_segundo is not None
    filas = []
    for modelo in precios["modelos"]:
        tarifa = tarifa_vigente(modelo, fecha)
        for esc in escenarios["escenarios"]:
            total = esc["tokens_mes"] if tokens_mes is None else tokens_mes
            ent, sal = separar_tokens(total, esc["proporcion_entrada"], esc["proporcion_salida"])
            mult = multiplicador if multiplicador is not None else esc.get("multiplicador_razonamiento")
            fallo = tasa_fallo if tasa_fallo is not None else esc.get("tasa_fallo_esfuerzo_bajo")

            fila = {
                "modelo": modelo["modelo"],
                "escenario": esc["id"],
                "tarifa_entrada": tarifa["entrada"],
                "tarifa_salida": tarifa["salida"],
                "tokens_entrada": ent,
                "tokens_salida": sal,
                "costo_lista": costo_lista(ent, sal, tarifa) * tipo_cambio,
                "costo_razonamiento": None,
                "costo_escalera": None,
                "espera_lista": None,
                "espera_razonamiento": None,
                "espera_escalera": None,
            }
            if mult is not None:
                fila["costo_razonamiento"] = costo_razonamiento(ent, sal, tarifa, mult) * tipo_cambio
                if fallo is not None:
                    fila["costo_escalera"] = costo_escalera(ent, sal, tarifa, mult, fallo) * tipo_cambio
            if con_espera:
                fila["espera_lista"] = costo_espera(sal, tokens_por_segundo, salario_hora)
                if mult is not None:
                    fila["espera_razonamiento"] = costo_espera(sal * mult, tokens_por_segundo, salario_hora)
                    if fallo is not None:
                        fila["espera_escalera"] = costo_espera(
                            sal + fallo * sal * mult, tokens_por_segundo, salario_hora)
            filas.append(fila)
    return filas


# ---------------------------------------------------------------- salida

COLUMNAS_BASE = ["modelo", "escenario", "costo_lista", "costo_razonamiento", "costo_escalera"]
COLUMNAS_ESPERA = ["espera_lista", "espera_razonamiento", "espera_escalera"]
COLUMNAS_CSV = ["modelo", "escenario", "moneda", "fecha_tarifa", "tarifa_entrada", "tarifa_salida",
                "tokens_entrada", "tokens_salida"] + COLUMNAS_BASE[2:] + COLUMNAS_ESPERA


def _fmt(valor, decimales: int) -> str:
    if valor is None:
        return "n/d"
    if isinstance(valor, float):
        return f"{valor:.{decimales}f}"
    return str(valor)


def imprimir_tabla(filas: list[dict], con_espera: bool, decimales: int, out) -> None:
    columnas = COLUMNAS_BASE + (COLUMNAS_ESPERA if con_espera else [])
    celdas = [[_fmt(f[c], decimales) for c in columnas] for f in filas]
    anchos = [max(len(c), *(len(fila[i]) for fila in celdas)) for i, c in enumerate(columnas)]

    def linea(valores):
        partes = [v.ljust(a) if i < 2 else v.rjust(a) for i, (v, a) in enumerate(zip(valores, anchos))]
        return "  ".join(partes)

    print(linea(columnas), file=out)
    print("  ".join("-" * a for a in anchos), file=out)
    for fila in celdas:
        print(linea(fila), file=out)


def imprimir_csv(filas: list[dict], moneda: str, fecha: date, out) -> None:
    w = csv.DictWriter(out, fieldnames=COLUMNAS_CSV, lineterminator="\n")
    w.writeheader()
    for f in filas:
        w.writerow({**{k: ("" if v is None else round(v, 10) if isinstance(v, float) else v)
                       for k, v in f.items()},
                    "moneda": moneda, "fecha_tarifa": fecha.isoformat()})


# ---------------------------------------------------------------- CLI

def crear_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Costo mensual de LLM por modelo y escenario de modernización de aplicaciones.")
    p.add_argument("--precios", type=Path, default=AQUI / "prices.json", help="archivo de tarifas")
    p.add_argument("--escenarios", type=Path, default=AQUI / "scenarios.json", help="archivo de escenarios")
    p.add_argument("--tokens-mes", type=float, default=None,
                   help="tokens totales al mes; reemplaza el valor de todos los escenarios")
    p.add_argument("--moneda", choices=["USD", "CLP"], default="USD")
    p.add_argument("--tipo-cambio", type=float, default=None,
                   help="CLP por 1 USD; obligatorio con --moneda CLP")
    p.add_argument("--fecha", type=date.fromisoformat, default=None,
                   help="fecha AAAA-MM-DD para elegir la tarifa vigente (por defecto: hoy)")
    p.add_argument("--salida", choices=["tabla", "csv"], default="tabla")
    p.add_argument("--multiplicador-razonamiento", type=float, default=None,
                   help="reemplaza el multiplicador de todos los escenarios")
    p.add_argument("--tasa-fallo", type=float, default=None,
                   help="reemplaza la tasa de fallo en esfuerzo bajo (0 a 1) de todos los escenarios")
    p.add_argument("--salario-hora", type=float, default=None,
                   help="salario por hora, en la moneda de --moneda; activa el costo de espera")
    p.add_argument("--tokens-por-segundo", type=float, default=None,
                   help="velocidad de salida del modelo; activa el costo de espera")
    return p


def main(argv: list[str] | None = None, out=None) -> int:
    out = out or sys.stdout
    parser = crear_parser()
    args = parser.parse_args(argv)

    if args.moneda == "CLP":
        if args.tipo_cambio is None:
            parser.error("--moneda CLP requiere --tipo-cambio (CLP por 1 USD)")
        if args.tipo_cambio <= 0:
            parser.error("--tipo-cambio debe ser > 0")
        tipo_cambio = args.tipo_cambio
    else:
        if args.tipo_cambio is not None:
            parser.error("--tipo-cambio solo se usa con --moneda CLP")
        tipo_cambio = 1.0
    if (args.salario_hora is None) != (args.tokens_por_segundo is None):
        parser.error("el costo de espera requiere --salario-hora y --tokens-por-segundo juntos")

    precios = json.loads(args.precios.read_text(encoding="utf-8"))
    escenarios = json.loads(args.escenarios.read_text(encoding="utf-8"))
    if precios.get("moneda") != "USD":
        parser.error("prices.json debe estar en USD")
    fecha = args.fecha or date.today()

    try:
        filas = calcular(precios, escenarios, fecha, tokens_mes=args.tokens_mes,
                         multiplicador=args.multiplicador_razonamiento, tasa_fallo=args.tasa_fallo,
                         tipo_cambio=tipo_cambio, salario_hora=args.salario_hora,
                         tokens_por_segundo=args.tokens_por_segundo)
    except ErrorDatos as e:
        parser.error(str(e))

    if args.salida == "csv":
        imprimir_csv(filas, args.moneda, fecha, out)
    else:
        con_espera = args.salario_hora is not None
        print(f"Costo mensual en {args.moneda} | tarifas vigentes al {fecha.isoformat()} | "
              "tarifas de terceros SIN verificar en fuente oficial", file=out)
        imprimir_tabla(filas, con_espera, 2 if args.moneda == "CLP" else 4, out)
        if any(f["costo_escalera"] is None for f in filas):
            print("\nn/d: falta multiplicador de razonamiento y/o tasa de fallo "
                  "(scenarios.json, --multiplicador-razonamiento, --tasa-fallo).", file=out)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:  # p. ej. `calc.py | head`
        sys.stderr.close()
        sys.exit(0)
