#!/usr/bin/env bash
#
# import-grupo.sh <groupId|nombre-del-grupo>
#
# Importa un GRUPO de canales completo desde Mirth Connect al proyecto local:
#   - Resuelve el channelGroup por id o nombre via /api/channelgroups.
#   - Crea la subcarpeta canales/<nombre-grupo-saneado>/
#   - Descarga cada canal miembro (GET /api/channels/{id}) a
#     canales/<grupo>/<nombre-canal>.xml
#   - Guarda tambien el XML del propio channelGroup (membresias/orden) en
#     canales/<grupo>/_grupo.xml, para poder reexportar la relacion
#     grupo<->canales mas adelante (hacia Mirth).
#
# Uso:
#   ./import-grupo.sh 00000000-0000-0000-0000-000000000000
#   ./import-grupo.sh "Nombre del grupo (DEV)"
#
# Codigos de salida:
#   0  -> importado OK
#   1  -> uso incorrecto (faltan argumentos)
#   10 -> error de conexion/HTTP
#   11 -> no hay sesion valida (correr ./login.sh primero)
#   12 -> grupo o canal no encontrado
#   13 -> sesion expirada/invalida detectada en la operacion (HTTP 401) -> correr ./login.sh
#   20 -> error inesperado
#
# Requiere sesion previa: correr ./login.sh una vez antes de usar este
# script (reusa la sesion persistente, no vuelve a pedir credenciales).

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

if [[ $# -lt 1 ]]; then
    echo "Uso: $0 <groupId|nombre-del-grupo>" >&2
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
# Descargar el listado completo de channelgroups (no hay endpoint de
# busqueda por id/nombre individual verificado, asi que se filtra en
# python sobre el listado completo).
# ---------------------------------------------------------------------------
tmp_groups_xml="$(mktemp)"
http_code="$(mirth_curl -H 'Accept: application/xml' -o "${tmp_groups_xml}" -w '%{http_code}' '/api/channelgroups')"

if mirth_check_session_expired "${http_code}"; then
    rm -f "${tmp_groups_xml}"
    exit "${MIRTH_ERR_SESSION_EXPIRED}"
fi

if [[ "${http_code}" != "200" ]]; then
    mirth_err "No se pudo obtener el listado de grupos (HTTP ${http_code})."
    rm -f "${tmp_groups_xml}"
    exit "${MIRTH_ERR_HTTP}"
fi

# ---------------------------------------------------------------------------
# Resolver el grupo (por id o por nombre exacto) y extraer:
#   - group_id / group_name
#   - lista de channel ids miembros
#   - guardar el <channelGroup>...</channelGroup> aislado en un archivo tmp
# ---------------------------------------------------------------------------
tmp_group_only_xml="$(mktemp)"
tmp_member_ids="$(mktemp)"

resolved_name="$(python3 - "${tmp_groups_xml}" "${IDENTIFICADOR}" "${tmp_group_only_xml}" "${tmp_member_ids}" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET

groups_xml, target, out_group_xml, out_ids = sys.argv[1:5]

tree = ET.parse(groups_xml)
root = tree.getroot()

found = None
for grp in root.findall("channelGroup"):
    gid_el = grp.find("id")
    gname_el = grp.find("name")
    gid = gid_el.text if gid_el is not None else ""
    gname = gname_el.text if gname_el is not None else ""
    if gid == target or gname == target:
        found = grp
        break

if found is None:
    sys.exit(1)

gname_el = found.find("name")
gname = gname_el.text if gname_el is not None else "grupo_sin_nombre"

# Guardar el channelGroup aislado (con su declaracion XML propia)
ET.ElementTree(found).write(out_group_xml, encoding="UTF-8", xml_declaration=True)

# Extraer los ids de los canales miembros, en orden
with open(out_ids, "w") as f:
    for ch in found.findall("./channels/channel"):
        cid_el = ch.find("id")
        if cid_el is not None and cid_el.text:
            f.write(cid_el.text + "\n")

print(gname)
PYEOF
)"
py_rc=$?
rm -f "${tmp_groups_xml}"

if [[ ${py_rc} -ne 0 || -z "${resolved_name}" ]]; then
    mirth_err "No se encontro ningun grupo con id/nombre '${IDENTIFICADOR}'."
    rm -f "${tmp_group_only_xml}" "${tmp_member_ids}"
    exit "${MIRTH_ERR_NOTFOUND}"
fi

group_name="${resolved_name}"
mirth_log "Grupo resuelto: '${group_name}'"

# ---------------------------------------------------------------------------
# Sanitizar nombre de grupo para usarlo como nombre de carpeta.
#
# Usa el helper centralizado mirth_sanitize_name (lib/mirth-api.sh), que
# translitera tildes/enie a su equivalente ASCII (a, e, i, o, u, n) en vez
# de mangled-earlos a '_', y colapsa/recorta guiones bajos sobrantes. Mismo
# criterio usado por import-canal.sh para nombres de canal, para que ambos
# scripts produzcan nombres consistentes.
# ---------------------------------------------------------------------------
safe_group_name="$(mirth_sanitize_name "${group_name}")"
GROUP_DIR="${CANALES_DIR}/${safe_group_name}"
mkdir -p "${GROUP_DIR}"

# Guardar el XML del propio grupo (membresias/orden) para poder reexportar.
cp "${tmp_group_only_xml}" "${GROUP_DIR}/_grupo.xml"
rm -f "${tmp_group_only_xml}"
mirth_ok "Metadata del grupo guardada en: ${GROUP_DIR}/_grupo.xml"

# ---------------------------------------------------------------------------
# Importar cada canal miembro
# ---------------------------------------------------------------------------
total=0
importados=0
fallidos=0

while IFS= read -r channel_id; do
    [[ -z "${channel_id}" ]] && continue
    total=$((total + 1))

    tmp_channel_xml="$(mktemp)"
    ch_http_code="$(mirth_curl -H 'Accept: application/xml' -o "${tmp_channel_xml}" -w '%{http_code}' "/api/channels/${channel_id}")"

    if mirth_check_session_expired "${ch_http_code}"; then
        rm -f "${tmp_channel_xml}" "${tmp_member_ids}"
        exit "${MIRTH_ERR_SESSION_EXPIRED}"
    fi

    if [[ "${ch_http_code}" != "200" ]]; then
        mirth_err "Canal ${channel_id} no se pudo importar (HTTP ${ch_http_code})."
        fallidos=$((fallidos + 1))
        rm -f "${tmp_channel_xml}"
        continue
    fi

    channel_name="$(python3 - "${tmp_channel_xml}" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET

tree = ET.parse(sys.argv[1])
root = tree.getroot()
name_el = root.find("name")
print(name_el.text if name_el is not None else "canal_sin_nombre")
PYEOF
)"

    safe_channel_name="$(mirth_sanitize_name "${channel_name}")"
    destino="${GROUP_DIR}/${safe_channel_name}.xml"

    cp "${tmp_channel_xml}" "${destino}"
    rm -f "${tmp_channel_xml}"

    mirth_ok "Canal '${channel_name}' (${channel_id}) importado a: ${destino}"
    importados=$((importados + 1))
done < "${tmp_member_ids}"

rm -f "${tmp_member_ids}"

mirth_log "Grupo '${group_name}': ${importados}/${total} canales importados (${fallidos} fallidos)."

if [[ ${fallidos} -gt 0 ]]; then
    exit "${MIRTH_ERR_HTTP}"
fi

exit 0
