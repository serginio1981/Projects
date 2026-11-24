# LLMResearch — calculadora de costo real de LLM

Calculadora de línea de comandos que estima el costo mensual de usar distintos
LLM en proyectos de **modernización de aplicaciones**. Python 3.10+, solo
biblioteca estándar, **no llama a ninguna API** ni necesita claves.

> **Advertencia sobre las tarifas.** Los precios de `prices.json` provienen de
> terceros (agregadores) y **no están verificados en la fuente oficial**.
> Antes de usar cualquier resultado para una decisión o una propuesta,
> verifica cada tarifa en la página oficial de precios del proveedor
> correspondiente y actualiza los campos `fuente` y `fecha`.

## Qué calcula

Para cada combinación de modelo y escenario:

| Columna | Fórmula |
|---|---|
| `costo_lista` | `(tokens_entrada × tarifa_entrada + tokens_salida × tarifa_salida) / 1.000.000` |
| `costo_razonamiento` | igual, pero con `tokens_salida × multiplicador_razonamiento` |
| `costo_escalera` | `costo_lista + tasa_fallo × costo_razonamiento` (bajo siempre, alto solo en la fracción que falla, un único reintento) |
| `espera_*` (opcional) | `tokens_salida / tokens_por_segundo / 3600 × salario_hora`, con los tokens de salida de cada variante |

Si falta un dato (multiplicador, tasa de fallo, salario o velocidad) la columna
aparece como `n/d` en la tabla y vacía en el CSV. **La calculadora no rellena
datos faltantes.**

## Uso

```bash
python3 calc.py
```

```bash
python3 calc.py --tokens-mes 5000000 --multiplicador-razonamiento 3 --tasa-fallo 0.25
```

```bash
python3 calc.py --moneda CLP --tipo-cambio 950 --fecha 2026-12-01 --salida csv > costos.csv
```

Los valores `3`, `0.25` y `950` de los ejemplos son solo ilustrativos de la
sintaxis; no son recomendaciones ni datos medidos.

| Opción | Descripción |
|---|---|
| `--tokens-mes N` | Tokens totales al mes; reemplaza el valor de todos los escenarios. |
| `--moneda USD\|CLP` | Moneda de salida (por defecto USD). |
| `--tipo-cambio X` | CLP por 1 USD. **Obligatorio** con `--moneda CLP`; no hay valor por defecto. |
| `--fecha AAAA-MM-DD` | Fecha para elegir la tarifa vigente (por defecto, hoy). |
| `--salida tabla\|csv` | Formato de salida (por defecto tabla). |
| `--multiplicador-razonamiento M` | Reemplaza el multiplicador de todos los escenarios (≥ 1). |
| `--tasa-fallo P` | Reemplaza la tasa de fallo en esfuerzo bajo de todos los escenarios (0 a 1). |
| `--salario-hora S` | Salario por hora **en la moneda de salida**. Activa el costo de espera. |
| `--tokens-por-segundo V` | Velocidad de salida. Debe darse junto con `--salario-hora`. |
| `--precios`, `--escenarios` | Rutas alternativas a los archivos JSON. |

## Archivos

- `prices.json` — tarifas en USD por millón de tokens (`entrada`, `salida`,
  `lectura_cache`), con `fuente` y `fecha` por modelo. Cada modelo tiene una
  lista de `tarifas` con `vigente_desde` / `vigente_hasta` (fechas inclusivas,
  `null` = sin límite), lo que permite cambios programados como el de
  Gemini 4 Carbon (2 / 10 hasta el 2026-11-30; 4 / 20 desde el 2026-12-01).
- `scenarios.json` — escenarios: análisis de código legado, migración/refactor,
  generación de pruebas y documentación.
- `calc.py` — la calculadora.
- `tests/test_calc.py` — pruebas con casos calculados a mano.

## Pruebas

```bash
python3 -m unittest discover -s tests -v
```

## Supuestos (todos editables)

1. **Tarifas**: las de `prices.json`, cargadas el 2026-11-24 desde agregadores,
   sin verificar en fuente oficial.
2. **Volumen**: 20.000 tokens al mes por escenario (entrada + salida). Es un
   valor por defecto arbitrario, no una medición de ningún proyecto.
3. **Proporción**: 80 % entrada y 20 % salida en los cuatro escenarios. Hoy los
   cuatro escenarios tienen valores idénticos, así que dan el mismo costo hasta
   que los edites.
4. **Multiplicador de razonamiento y tasa de fallo en esfuerzo bajo**: están en
   `null` en `scenarios.json`. No hay un valor por defecto porque no tenemos
   una medición propia y no se inventan resultados de benchmarks. Debes
   definirlos por escenario o con `--multiplicador-razonamiento` / `--tasa-fallo`.
5. **Los tokens de razonamiento se facturan a la tarifa de salida.** Verifícalo
   para cada proveedor.
6. **Escalera**: un único reintento, en esfuerzo alto, que siempre resuelve la
   tarea; el intento alto repite la misma entrada completa.
7. **El multiplicador y la tasa de fallo son iguales para todos los modelos**
   de un escenario. En la práctica varían por modelo.
8. **Costo de espera**: una persona espera sin hacer otra cosa durante todo el
   tiempo de generación, la velocidad es única para todos los modelos e incluye
   solo la generación de la salida (no latencia inicial ni colas). En la
   escalera se suma el tiempo del intento bajo más el del alto en la fracción
   que falla.
9. **Lectura de caché**: el campo `lectura_cache` existe en `prices.json` pero
   está en `null` (sin dato) y **no se usa en el cálculo**.
10. **Sin descuentos**: no se modelan lotes (batch), descuentos por volumen,
    tarifas por contexto largo ni impuestos.
11. **Tipo de cambio**: uno solo, fijo, aplicado a todo el mes.

## Créditos

La metodología (costo = tokens × tarifa, más costo de espera, y la política de
"escalera") se basa en:

- Repositorio: [KaiserWhoLearns/ReasoningEffortLLM](https://github.com/KaiserWhoLearns/ReasoningEffortLLM) (licencia MIT).
- Paper: *What Effort Level Should I Choose? On the Economics of Reasoning
  Effort in LLM Agents*, Kaiser Sun, Yongchan Kwon, Zain Hasan, Shang Zhu,
  Kaitlyn Zhou y Federico Bianchi, arXiv:2610.34491 (2026).
  Título y autores tomados del README del repositorio; no se pudieron
  contrastar con la ficha de arXiv.

Este proyecto es una reimplementación mínima e independiente de la idea: no
contiene código del repositorio original ni reproduce sus resultados.

## Licencia

MIT. Ver [LICENSE](LICENSE).
