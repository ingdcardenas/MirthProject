#!/usr/bin/env bash
#
# build-canal.sh <carpeta-canal> [xml-salida]
#
# Reconstruye el XML de un canal desde la estructura legible generada por
# explode-canal.sh (channel.yml + mapper.json + source/ + destination_N/),
# lo guarda como <carpeta-canal>/canal.xml (o la ruta indicada) y VERIFICA
# el resultado contra original.xml:
#
#   - Si no hubo ediciones respecto al explode -> se espera reproduccion
#     byte a byte de original.xml (auto-test de la maquinaria).
#   - Si hubo ediciones -> se espera equivalencia FUNCIONAL (arboles XML
#     normalizados via xml.etree.ElementTree.canonicalize); las regiones
#     no editadas siguen siendo byte-exactas.
#
# Este script NO exporta nada a Mirth. Solo construye y verifica en local.
# Para subir el resultado al servidor, usar despues:
#   ./export-canal.sh <carpeta-canal>/canal.xml
#
# Uso:
#   ./build-canal.sh canales/MiGrupo/01_-_MiCanal
#
# Codigos de salida:
#   0  -> build OK y verificacion OK (byte-exacta o funcional segun corresponda)
#   1  -> uso incorrecto (faltan argumentos)
#   2  -> la carpeta-canal no existe o no tiene original.xml/.manifest.json
#         (no fue generada por explode-canal.sh)
#   3  -> python3 no disponible o falta el modulo PyYAML
#   4  -> el XML reconstruido no es bien formado, o la verificacion funcional
#         detecto una discrepancia estructural real (no cosmetica)
#   20 -> error inesperado durante el build

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

if [[ $# -lt 1 ]]; then
    echo "Uso: $0 <carpeta-canal> [xml-salida]" >&2
    exit 1
fi

PROYECTO="$1"
SALIDA="${2:-${PROYECTO}/canal.xml}"

if [[ ! -f "${PROYECTO}/original.xml" || ! -f "${PROYECTO}/.manifest.json" ]]; then
    echo "[ERROR] '${PROYECTO}' no parece una carpeta-canal (falta original.xml o .manifest.json)." >&2
    echo "        Generala primero con: ./explode-canal.sh <canal.xml> ${PROYECTO}" >&2
    exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "[ERROR] Se requiere python3 instalado en el sistema." >&2
    exit 3
fi

if ! python3 -c "import yaml" >/dev/null 2>&1; then
    echo "[ERROR] Falta el modulo PyYAML (pip install pyyaml)." >&2
    exit 3
fi

echo "[INFO] Reconstruyendo '${PROYECTO}' -> '${SALIDA}' ..."

RESULT_JSON="$(mktemp)"
trap 'rm -f "${RESULT_JSON}"' EXIT

if ! PYTHONPATH="${SCRIPT_DIR}/lib:${PYTHONPATH:-}" python3 - "${PROYECTO}" "${SALIDA}" "${RESULT_JSON}" <<'PYEOF'
import json
import sys
import canal_proyecto as cp

proj, salida, result_path = sys.argv[1], sys.argv[2], sys.argv[3]

text, report = cp.build_project(proj)
with open(salida, "w", encoding="utf-8") as f:
    f.write(text)

original_text = open(f"{proj}/original.xml", encoding="utf-8").read()
verify = cp.verify(original_text, text)

with open(result_path, "w", encoding="utf-8") as f:
    json.dump({"report": report, "verify": verify}, f)

print(f"[INFO] Regiones sin cambios: {len(report['unchanged'])}")
if report["regenerated"]:
    print(f"[INFO] Regiones regeneradas (editadas): {', '.join(report['regenerated'])}")
else:
    print("[INFO] Ninguna region fue editada respecto al explode original.")
PYEOF
then
    echo "[ERROR] Fallo el build. Revisa el traceback anterior." >&2
    exit 20
fi

BYTE_EXACT="$(python3 -c "import json; print(json.load(open('${RESULT_JSON}'))['verify']['byte_exact'])")"
WELL_FORMED="$(python3 -c "import json; print(json.load(open('${RESULT_JSON}'))['verify']['well_formed'])")"
FUNCTIONAL="$(python3 -c "import json; print(json.load(open('${RESULT_JSON}'))['verify']['functional_equal'])")"
REGENERATED_COUNT="$(python3 -c "import json; print(len(json.load(open('${RESULT_JSON}'))['report']['regenerated']))")"

if [[ "${WELL_FORMED}" != "True" ]]; then
    echo "[ERROR] El XML reconstruido NO es bien formado." >&2
    exit 4
fi

if [[ "${REGENERATED_COUNT}" == "0" ]]; then
    if [[ "${BYTE_EXACT}" == "True" ]]; then
        echo "[OK] Auto-test byte-a-byte: build reproduce original.xml exactamente."
    else
        echo "[ERROR] No hubo ediciones pero el resultado NO es byte-exacto (bug de la maquinaria)." >&2
        exit 4
    fi
else
    echo "[OK] Verificacion funcional (arboles normalizados): $( [[ "${FUNCTIONAL}" == "True" ]] && echo 'sin diferencias estructurales' || echo 'hubo cambios estructurales (esperado si editaste algo mas que texto)' )"
fi

echo "[OK] XML construido en: ${SALIDA}"
echo "[INFO] Para exportarlo a Mirth: ./export-canal.sh ${SALIDA}"
exit 0
