#!/usr/bin/env bash
#
# import-canal.sh <channelId|nombre>
#
# Importa (descarga) un canal desde Mirth Connect hacia el proyecto local
# en formato XML y lo guarda en canales/<nombre>.xml
#
# Uso:
#   ./import-canal.sh 3a1e2b4c-....-....-....-............
#   ./import-canal.sh "Nombre del canal"
#
# Codigos de salida:
#   0  -> importado OK
#   1  -> uso incorrecto (faltan argumentos)
#   10 -> error de conexion/HTTP
#   11 -> no hay sesion valida (correr ./login.sh primero)
#   12 -> canal no encontrado
#   13 -> sesion expirada/invalida detectada en la operacion (HTTP 401) -> correr ./login.sh
#   20 -> error inesperado
#
# Requiere sesion previa: correr ./login.sh una vez antes de usar este
# script (reusa la sesion persistente, no vuelve a pedir credenciales).

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

if [[ $# -lt 1 ]]; then
    echo "Uso: $0 <channelId|nombre-del-canal>" >&2
    exit 1
fi

IDENTIFICADOR="$1"

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

CANALES_DIR="${MIRTH_CANALES_DIR:-${SCRIPT_DIR}/canales}"
mkdir -p "${CANALES_DIR}"

mirth_log "Conectando a ${MIRTH_URL} ..."
version="$(mirth_check_reachable)" || { mirth_err "Servidor no alcanzable."; exit "${MIRTH_ERR_HTTP}"; }
mirth_log "Version del servidor: ${version}"

if ! mirth_require_session; then
    exit "${MIRTH_ERR_LOGIN}"
fi

# ---------------------------------------------------------------------------
# Resolver el ID del canal.
#
# Si el identificador ya parece un UUID (formato tipico de channelId en
# Mirth), se usa directo con /api/channels/{id}.
# Si no, se busca por nombre entre /api/channels/idsAndNames.
# ---------------------------------------------------------------------------
UUID_REGEX='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

channel_id=""
channel_name=""

if [[ "${IDENTIFICADOR}" =~ ${UUID_REGEX} ]]; then
    channel_id="${IDENTIFICADOR}"
else
    channel_name="${IDENTIFICADOR}"
    tmp_idsnames="$(mktemp)"
    http_code="$(mirth_curl -H 'Accept: application/xml' -o "${tmp_idsnames}" -w '%{http_code}' '/api/channels/idsAndNames')"
    if mirth_check_session_expired "${http_code}"; then
        rm -f "${tmp_idsnames}"
        exit "${MIRTH_ERR_SESSION_EXPIRED}"
    fi
    if [[ "${http_code}" != "200" ]]; then
        mirth_err "No se pudo obtener el listado de ids/nombres (HTTP ${http_code})."
        rm -f "${tmp_idsnames}"
        exit "${MIRTH_ERR_HTTP}"
    fi

    # El XML de idsAndNames tiene entradas <entry><string>ID</string><string>NOMBRE</string></entry>
    # Extraccion simple con grep/sed (evita dependencia de xmllint).
    channel_id="$(python3 - "${tmp_idsnames}" "${channel_name}" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET

xml_path, target_name = sys.argv[1], sys.argv[2]
tree = ET.parse(xml_path)
root = tree.getroot()

for entry in root.findall(".//entry"):
    strings = entry.findall("string")
    if len(strings) >= 2:
        cid, cname = strings[0].text, strings[1].text
        if cname == target_name:
            print(cid)
            break
PYEOF
)"
    rm -f "${tmp_idsnames}"

    if [[ -z "${channel_id}" ]]; then
        mirth_err "No se encontro ningun canal con el nombre '${channel_name}'."
        exit "${MIRTH_ERR_NOTFOUND}"
    fi
    mirth_log "Nombre '${channel_name}' resuelto a channelId ${channel_id}"
fi

# ---------------------------------------------------------------------------
# Descargar el XML del canal
# ---------------------------------------------------------------------------
tmp_channel_xml="$(mktemp)"
http_code="$(mirth_curl -H 'Accept: application/xml' -o "${tmp_channel_xml}" -w '%{http_code}' "/api/channels/${channel_id}")"

if mirth_check_session_expired "${http_code}"; then
    rm -f "${tmp_channel_xml}"
    exit "${MIRTH_ERR_SESSION_EXPIRED}"
fi

if [[ "${http_code}" == "404" ]]; then
    mirth_err "Canal '${IDENTIFICADOR}' no encontrado (HTTP 404)."
    rm -f "${tmp_channel_xml}"
    exit "${MIRTH_ERR_NOTFOUND}"
fi

if [[ "${http_code}" != "200" ]]; then
    mirth_err "Error al importar el canal (HTTP ${http_code})."
    rm -f "${tmp_channel_xml}"
    exit "${MIRTH_ERR_HTTP}"
fi

# Determinar nombre de salida: si no lo teniamos (vino por UUID), extraerlo del XML.
if [[ -z "${channel_name}" ]]; then
    channel_name="$(python3 - "${tmp_channel_xml}" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET

tree = ET.parse(sys.argv[1])
root = tree.getroot()
name_el = root.find("name")
print(name_el.text if name_el is not None else "canal_sin_nombre")
PYEOF
)"
fi

# Sanitizar nombre de archivo (transliteracion de tildes + colapso de
# guiones bajos, ver mirth_sanitize_name en lib/mirth-api.sh).
safe_name="$(mirth_sanitize_name "${channel_name}")"
destino="${CANALES_DIR}/${safe_name}.xml"

cp "${tmp_channel_xml}" "${destino}"
rm -f "${tmp_channel_xml}"

mirth_ok "Canal '${channel_name}' (${channel_id}) importado a: ${destino}"
exit 0
