"""Pruebas de aritmética con casos calculados a mano.

Caso base: 20000 tokens/mes, 80% entrada (16000) y 20% salida (4000).
Los valores de multiplicador, tasa de fallo, velocidad, salario y tipo de
cambio usados aquí son números de prueba, no datos reales.
"""
import contextlib
import io
import json
import sys
import unittest
from datetime import date
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(RAIZ))

import calc  # noqa: E402

PRECIOS = json.loads((RAIZ / "prices.json").read_text(encoding="utf-8"))
ESCENARIOS = json.loads((RAIZ / "scenarios.json").read_text(encoding="utf-8"))
FABLE = {"entrada": 8, "salida": 40}


def modelo(nombre):
    return next(m for m in PRECIOS["modelos"] if m["modelo"] == nombre)


class TestAritmetica(unittest.TestCase):
    def test_separar_tokens(self):
        ent, sal = calc.separar_tokens(20000, 0.8, 0.2)
        self.assertAlmostEqual(ent, 16000)
        self.assertAlmostEqual(sal, 4000)

    def test_proporciones_deben_sumar_uno(self):
        with self.assertRaises(calc.ErrorDatos):
            calc.separar_tokens(20000, 0.8, 0.3)

    def test_costo_lista(self):
        # 16000 x 8/1e6 = 0.128 ; 4000 x 40/1e6 = 0.160 ; total 0.288
        self.assertAlmostEqual(calc.costo_lista(16000, 4000, FABLE), 0.288)

    def test_costo_lista_modelo_barato(self):
        # Haiku 0.10/0.50: 16000 x 0.10/1e6 = 0.0016 ; 4000 x 0.50/1e6 = 0.0020 ; total 0.0036
        self.assertAlmostEqual(calc.costo_lista(16000, 4000, {"entrada": 0.10, "salida": 0.50}), 0.0036)

    def test_costo_razonamiento(self):
        # multiplicador 3: salida 12000 x 40/1e6 = 0.480 ; + 0.128 = 0.608
        self.assertAlmostEqual(calc.costo_razonamiento(16000, 4000, FABLE, 3), 0.608)

    def test_costo_escalera(self):
        # bajo siempre 0.288 + 25% x alto 0.608 = 0.288 + 0.152 = 0.440
        self.assertAlmostEqual(calc.costo_escalera(16000, 4000, FABLE, 3, 0.25), 0.440)

    def test_escalera_extremos(self):
        # sin fallos = lista ; todo falla = lista + alto
        self.assertAlmostEqual(calc.costo_escalera(16000, 4000, FABLE, 3, 0), 0.288)
        self.assertAlmostEqual(calc.costo_escalera(16000, 4000, FABLE, 3, 1), 0.896)

    def test_costo_espera(self):
        # 4000 tokens / 50 tok/s = 80 s ; 36 por hora = 0.01 por segundo ; 0.80
        self.assertAlmostEqual(calc.costo_espera(4000, 50, 36), 0.80)

    def test_parametros_invalidos(self):
        with self.assertRaises(calc.ErrorDatos):
            calc.costo_razonamiento(16000, 4000, FABLE, 0.5)
        with self.assertRaises(calc.ErrorDatos):
            calc.costo_escalera(16000, 4000, FABLE, 3, 1.5)
        with self.assertRaises(calc.ErrorDatos):
            calc.costo_espera(4000, 0, 36)


class TestTarifaVigente(unittest.TestCase):
    def test_carbon_hasta_30_de_noviembre(self):
        t = calc.tarifa_vigente(modelo("Gemini 4 Carbon"), date(2026, 11, 30))
        self.assertEqual((t["entrada"], t["salida"]), (2, 10))
        # 16000 x 2/1e6 = 0.032 ; 4000 x 10/1e6 = 0.040 ; total 0.072
        self.assertAlmostEqual(calc.costo_lista(16000, 4000, t), 0.072)

    def test_carbon_desde_1_de_diciembre(self):
        t = calc.tarifa_vigente(modelo("Gemini 4 Carbon"), date(2026, 12, 1))
        self.assertEqual((t["entrada"], t["salida"]), (4, 20))
        # 16000 x 4/1e6 = 0.064 ; 4000 x 20/1e6 = 0.080 ; total 0.144
        self.assertAlmostEqual(calc.costo_lista(16000, 4000, t), 0.144)

    def test_sin_tarifa_vigente(self):
        m = {"modelo": "X", "tarifas": [{"vigente_desde": "2026-12-01", "vigente_hasta": None,
                                         "entrada": 1, "salida": 1}]}
        with self.assertRaises(calc.ErrorDatos):
            calc.tarifa_vigente(m, date(2026, 11, 30))

    def test_tarifas_solapadas(self):
        t = {"vigente_desde": None, "vigente_hasta": None, "entrada": 1, "salida": 1}
        with self.assertRaises(calc.ErrorDatos):
            calc.tarifa_vigente({"modelo": "X", "tarifas": [t, t]}, date(2026, 11, 30))

    def test_tabla_cargada_coincide_con_el_encargo(self):
        esperado = {
            "Claude Fable 5.2": (8, 40), "Claude Opus 5.5": (4, 20), "Claude Sonnet 5.5": (2, 10),
            "Claude Haiku 5.5": (0.10, 0.50), "GPT-6.2 Astra": (8, 40), "GPT-6.2 Sol": (2, 10),
            "GPT-6.1 Terra": (1, 5), "GPT-6 Luna": (0.10, 0.50), "Gemini 4 Neon": (3, 15),
            "Gemini 4 Carbon": (2, 10), "Gemini 4 Hydrogen": (1.50, 7.50),
        }
        self.assertEqual(len(PRECIOS["modelos"]), len(esperado))
        for m in PRECIOS["modelos"]:
            t = calc.tarifa_vigente(m, date(2026, 11, 24))
            self.assertEqual((t["entrada"], t["salida"]), esperado[m["modelo"]], m["modelo"])
            self.assertEqual(m["fecha"], "2026-11-24")
            self.assertIn("sin verificar", m["fuente"])


class TestCalcular(unittest.TestCase):
    def fila(self, filas, nombre, escenario="migracion-refactor"):
        return next(f for f in filas if f["modelo"] == nombre and f["escenario"] == escenario)

    def test_una_fila_por_modelo_y_escenario(self):
        filas = calc.calcular(PRECIOS, ESCENARIOS, date(2026, 11, 24))
        self.assertEqual(len(filas), 11 * 4)

    def test_sin_supuestos_no_se_rellena(self):
        f = self.fila(calc.calcular(PRECIOS, ESCENARIOS, date(2026, 11, 24)), "Claude Fable 5.2")
        self.assertAlmostEqual(f["costo_lista"], 0.288)
        self.assertIsNone(f["costo_razonamiento"])
        self.assertIsNone(f["costo_escalera"])
        self.assertIsNone(f["espera_lista"])

    def test_completo_con_espera(self):
        filas = calc.calcular(PRECIOS, ESCENARIOS, date(2026, 11, 24), multiplicador=3,
                              tasa_fallo=0.25, salario_hora=36, tokens_por_segundo=50)
        f = self.fila(filas, "Claude Fable 5.2")
        self.assertAlmostEqual(f["costo_razonamiento"], 0.608)
        self.assertAlmostEqual(f["costo_escalera"], 0.440)
        self.assertAlmostEqual(f["espera_lista"], 0.80)          # 80 s
        self.assertAlmostEqual(f["espera_razonamiento"], 2.40)   # 12000/50 = 240 s
        self.assertAlmostEqual(f["espera_escalera"], 1.40)       # 80 + 0.25 x 240 = 140 s

    def test_tokens_mes_reemplaza_el_escenario(self):
        # 1.000.000 tokens: 800000 x 8/1e6 = 6.4 ; 200000 x 40/1e6 = 8.0 ; total 14.4
        f = self.fila(calc.calcular(PRECIOS, ESCENARIOS, date(2026, 11, 24), tokens_mes=1_000_000),
                      "Claude Fable 5.2")
        self.assertAlmostEqual(f["costo_lista"], 14.4)

    def test_tipo_cambio(self):
        # 0.288 USD x 950 CLP/USD = 273.6 CLP
        f = self.fila(calc.calcular(PRECIOS, ESCENARIOS, date(2026, 11, 24), tipo_cambio=950),
                      "Claude Fable 5.2")
        self.assertAlmostEqual(f["costo_lista"], 273.6)

    def test_carbon_cambia_el_1_de_diciembre(self):
        nov = self.fila(calc.calcular(PRECIOS, ESCENARIOS, date(2026, 11, 30)), "Gemini 4 Carbon")
        dic = self.fila(calc.calcular(PRECIOS, ESCENARIOS, date(2026, 12, 1)), "Gemini 4 Carbon")
        self.assertAlmostEqual(nov["costo_lista"], 0.072)
        self.assertAlmostEqual(dic["costo_lista"], 0.144)


class TestCLI(unittest.TestCase):
    def ejecutar(self, *args):
        out = io.StringIO()
        self.assertEqual(calc.main(list(args), out=out), 0)
        return out.getvalue()

    def test_clp_exige_tipo_cambio(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            calc.main(["--moneda", "CLP"], out=io.StringIO())

    def test_espera_exige_ambos_parametros(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            calc.main(["--salario-hora", "36"], out=io.StringIO())

    def test_csv(self):
        lineas = self.ejecutar("--salida", "csv", "--fecha", "2026-12-01").splitlines()
        self.assertEqual(len(lineas), 1 + 11 * 4)
        self.assertTrue(lineas[0].startswith("modelo,escenario,moneda,fecha_tarifa"))

    def test_tabla_marca_datos_faltantes(self):
        salida = self.ejecutar("--fecha", "2026-11-24")
        self.assertIn("n/d", salida)
        self.assertIn("0.2880", salida)


if __name__ == "__main__":
    unittest.main()
