#!/usr/bin/env bash
#
# explode-canal.sh <canal.xml> [carpeta-destino]
#
# Toma un XML de canal ya importado (p.ej. los de canales/<grupo>/) y lo
# "explota" a una carpeta-proyecto legible/editable:
#
#   <destino>/
#     original.xml       XML tal cual vino de Mirth, INTACTO (referencia)
#     channel.yml         metadata + scripts deploy/undeploy/pre/post
#     mapper.json          mapper steps del transformer del source (si aplica)
#     source/              config.yml + select_query.sql/update_query.sql/etc
#     destination_N/       config.yml + query.js / mapper.json / etc
#     .manifest.json        (interno) mapa de regiones para build-canal.sh
#
# No requiere sesion Mirth ni red: opera 100% local sobre el XML.
#
# Uso:
#   ./explode-canal.sh canales/MiGrupo/01_-_MiCanal.xml
#   ./explode-canal.sh canales/<grupo>/<canal>.xml proyectos/<grupo>/<canal>
#
# Por defecto, si no se indica carpeta-destino, se crea junto al XML de
# origen reemplazando el sufijo .xml por una carpeta con el mismo nombre
# (p.ej. canales/<grupo>/01_-_MiCanal/).
#
# Codigos de salida:
#   0  -> explode OK
#   1  -> uso incorrecto (faltan argumentos)
#   2  -> el XML de origen no existe o no es legible
#   3  -> python3 no disponible o falta el modulo PyYAML
#   20 -> error inesperado durante el explode

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

if [[ $# -lt 1 ]]; then
    echo "Uso: $0 <canal.xml> [carpeta-destino]" >&2
    exit 1
fi

XML_ORIGEN="$1"

if [[ ! -f "${XML_ORIGEN}" ]]; then
    echo "[ERROR] No existe o no es legible: ${XML_ORIGEN}" >&2
    exit 2
fi

if [[ $# -ge 2 ]]; then
    DESTINO="$2"
else
    DESTINO="${XML_ORIGEN%.xml}"
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "[ERROR] Se requiere python3 instalado en el sistema." >&2
    exit 3
fi

if ! python3 -c "import yaml" >/dev/null 2>&1; then
    echo "[ERROR] Falta el modulo PyYAML (pip install pyyaml)." >&2
    exit 3
fi

echo "[INFO] Explotando '${XML_ORIGEN}' -> '${DESTINO}' ..."

if ! PYTHONPATH="${SCRIPT_DIR}/lib:${PYTHONPATH:-}" python3 - "${XML_ORIGEN}" "${DESTINO}" <<'PYEOF'
import sys
import canal_proyecto as cp

xml_path, out_dir = sys.argv[1], sys.argv[2]
manifest = cp.explode(xml_path, out_dir)
print(f"[OK] {len(manifest['regions'])} regiones extraidas.")
PYEOF
then
    echo "[ERROR] Fallo el explode. Revisa el traceback anterior." >&2
    exit 20
fi

echo "[OK] Proyecto generado en: ${DESTINO}"
echo "[OK] Referencia intacta en: ${DESTINO}/original.xml"
exit 0
