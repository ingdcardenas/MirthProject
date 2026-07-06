#!/usr/bin/env bash
#
# export-canal.sh <archivo.xml> [--deploy]
#
# Exporta un canal del proyecto local hacia Mirth Connect, a partir de un
# XML importado previamente (ver import-canal.sh). Si el canal ya existe
# en el servidor (mismo channelId) lo actualiza (PUT); si no existe, lo
# crea con el mismo id definido en el XML.
#
# Opciones:
#   --deploy   Ademas de exportar, despliega el canal
#              (POST /api/channels/{id}/_deploy)
#
# Uso:
#   ./export-canal.sh canales/mi_canal.xml
#   ./export-canal.sh canales/mi_canal.xml --deploy
#
# Codigos de salida:
#   0  -> export (y deploy si se pidio) OK
#   1  -> uso incorrecto
#   10 -> error de conexion/HTTP
#   11 -> no hay sesion valida (correr ./login.sh primero)
#   13 -> sesion expirada/invalida detectada en la operacion (HTTP 401) -> correr ./login.sh
#   20 -> error inesperado (archivo invalido, XML sin channelId, etc.)
#
# Requiere sesion previa: correr ./login.sh una vez antes de usar este
# script (reusa la sesion persistente, no vuelve a pedir credenciales).

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

if [[ $# -lt 1 ]]; then
    echo "Uso: $0 <archivo.xml> [--deploy]" >&2
    exit 1
fi

XML_FILE="$1"
DO_DEPLOY=false
if [[ "${2:-}" == "--deploy" ]]; then
    DO_DEPLOY=true
fi

if [[ ! -f "${XML_FILE}" ]]; then
    echo "[ERROR] El archivo '${XML_FILE}' no existe." >&2
    exit 1
fi

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env"
fi

for dep in curl python3; do
    if ! command -v "${dep}" >/dev/null 2>&1; then
        echo "[ERROR] Se requiere '${dep}' instalado en el sistema." >&2
        exit 20
    fi
done

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/mirth-api.sh"

# ---------------------------------------------------------------------------
# Extraer channelId y nombre del XML a exportar
# ---------------------------------------------------------------------------
read -r CHANNEL_ID CHANNEL_NAME <<<"$(python3 - "${XML_FILE}" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET

try:
    tree = ET.parse(sys.argv[1])
except ET.ParseError as e:
    print("", "")
    sys.exit(0)

root = tree.getroot()
id_el = root.find("id")
name_el = root.find("name")
channel_id = id_el.text if id_el is not None and id_el.text else ""
channel_name = name_el.text if name_el is not None and name_el.text else ""
print(channel_id, channel_name)
PYEOF
)"

if [[ -z "${CHANNEL_ID}" ]]; then
    mirth_err "No se pudo extraer <id> del XML '${XML_FILE}'. ¿Es un import valido de canal?"
    exit 20
fi

mirth_log "Canal a exportar: '${CHANNEL_NAME}' (id ${CHANNEL_ID})"

mirth_log "Conectando a ${MIRTH_URL} ..."
version="$(mirth_check_reachable)" || { mirth_err "Servidor no alcanzable."; exit "${MIRTH_ERR_HTTP}"; }
mirth_log "Version del servidor: ${version}"

if ! mirth_require_session; then
    exit "${MIRTH_ERR_LOGIN}"
fi

# ---------------------------------------------------------------------------
# Verificar si el canal ya existe (GET /api/channels/{id})
# ---------------------------------------------------------------------------
existe_status="$(mirth_curl_status -H 'Accept: application/xml' "/api/channels/${CHANNEL_ID}")"

if mirth_check_session_expired "${existe_status}"; then
    exit "${MIRTH_ERR_SESSION_EXPIRED}"
fi

if [[ "${existe_status}" == "200" ]]; then
    accion="actualizar"
elif [[ "${existe_status}" == "404" ]]; then
    accion="crear"
else
    mirth_err "No se pudo verificar existencia del canal (HTTP ${existe_status})."
    exit "${MIRTH_ERR_HTTP}"
fi

mirth_log "El canal ${accion:+se va a ${accion}}..."

# ---------------------------------------------------------------------------
# PUT /api/channels/{id} crea o actualiza segun exista o no (comportamiento
# estandar de la API REST de Mirth para este endpoint).
# ---------------------------------------------------------------------------
tmp_resp="$(mktemp)"
http_code="$(mirth_curl -X PUT \
    -H 'Content-Type: application/xml' \
    -H 'Accept: application/xml' \
    --data-binary "@${XML_FILE}" \
    -o "${tmp_resp}" -w '%{http_code}' \
    "/api/channels/${CHANNEL_ID}")"

if mirth_check_session_expired "${http_code}"; then
    rm -f "${tmp_resp}"
    exit "${MIRTH_ERR_SESSION_EXPIRED}"
fi

if [[ "${http_code}" != "200" && "${http_code}" != "204" ]]; then
    mirth_err "Fallo al ${accion} el canal (HTTP ${http_code}). Respuesta:"
    cat "${tmp_resp}" >&2
    rm -f "${tmp_resp}"
    exit "${MIRTH_ERR_HTTP}"
fi
rm -f "${tmp_resp}"

mirth_ok "Canal '${CHANNEL_NAME}' (${CHANNEL_ID}) ${accion}do correctamente."

# ---------------------------------------------------------------------------
# Deploy opcional
# ---------------------------------------------------------------------------
if [[ "${DO_DEPLOY}" == true ]]; then
    mirth_log "Desplegando canal ${CHANNEL_ID} ..."
    deploy_status="$(mirth_curl_status -X POST -H 'Accept: application/xml' "/api/channels/${CHANNEL_ID}/_deploy")"
    if mirth_check_session_expired "${deploy_status}"; then
        exit "${MIRTH_ERR_SESSION_EXPIRED}"
    fi
    if [[ "${deploy_status}" != "200" && "${deploy_status}" != "204" ]]; then
        mirth_err "Fallo el deploy del canal (HTTP ${deploy_status})."
        exit "${MIRTH_ERR_HTTP}"
    fi
    mirth_ok "Canal ${CHANNEL_ID} desplegado correctamente."
fi

exit 0
