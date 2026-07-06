#!/usr/bin/env bash
#
# logout.sh
#
# Cierra explicitamente la sesion persistente de Mirth Connect creada por
# login.sh: llama a POST /api/users/_logout y borra el archivo de cookie
# jar fijo (MIRTH_COOKIE_JAR).
#
# Uso:
#   ./logout.sh
#
# Codigos de salida:
#   0  -> logout OK (o no habia sesion que cerrar)
#   20 -> error inesperado

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env"
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "[ERROR] Se requiere 'curl' instalado en el sistema." >&2
    exit 20
fi

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/mirth-api.sh"

mirth_logout
exit 0
