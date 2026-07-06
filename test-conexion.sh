#!/usr/bin/env bash
#
# test-conexion.sh
#
# Prueba de conectividad contra el servidor Mirth Connect:
#   1) Alcance del servidor y version (sin autenticacion).
#   2) Verificacion de autenticacion (listado de canales) contando cuantos
#      hay, REUSANDO la sesion persistente creada por ./login.sh. Si no hay
#      sesion valida, indica al usuario que corra login.sh primero (no
#      loguea automaticamente).
#
# Uso:
#   ./login.sh              # una vez
#   ./test-conexion.sh      # cuantas veces se quiera, sin volver a pedir clave
#
# Variables de entorno / .env soportadas: ver .env.example
#
# Codigos de salida:
#   0  -> todo OK (alcance + auth)
#   10 -> error de conexion/HTTP contra el servidor
#   11 -> no hay sesion valida (falta correr login.sh)
#   12 -> (reservado, no usado en este script)
#   13 -> sesion expirada/invalida detectada en la operacion (HTTP 401) -> correr login.sh
#   20 -> error inesperado / dependencias faltantes

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Cargar .env si existe (no falla si no existe)
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

echo "=============================================================="
echo " Prueba de conexion a Mirth Connect"
echo " URL objetivo: ${MIRTH_URL}"
echo "=============================================================="
echo

echo "--- Paso 1/2: Alcance del servidor (sin autenticacion) ---"
version="$(mirth_check_reachable)"
rc=$?
if [[ ${rc} -ne 0 ]]; then
    mirth_err "No se pudo verificar el alcance del servidor. Revisar:"
    mirth_err "  - Conectividad de red hacia ${MIRTH_URL}"
    mirth_err "  - Que se este saltando el proxy corporativo (--noproxy '*')"
    mirth_err "  - Que el servicio Mirth este activo"
    echo
    echo "RESULTADO: ERROR (paso 1/2 - alcance)"
    exit "${rc}"
fi
mirth_ok "Servidor alcanzable. Version de Mirth Connect: ${version}"
echo

echo "--- Paso 2/2: Autenticacion y listado de canales (sesion persistente) ---"
if ! mirth_require_session; then
    echo
    echo "RESULTADO: ERROR (paso 2/2 - sin sesion valida, correr ./login.sh)"
    exit "${MIRTH_ERR_LOGIN}"
fi

tmp_channels="$(mktemp)"
http_code="$(mirth_curl -H 'Accept: application/xml' -o "${tmp_channels}" -w '%{http_code}' '/api/channels')"

if mirth_check_session_expired "${http_code}"; then
    rm -f "${tmp_channels}"
    echo
    echo "RESULTADO: ERROR (paso 2/2 - sesion expirada, correr ./login.sh)"
    exit "${MIRTH_ERR_SESSION_EXPIRED}"
fi

if [[ "${http_code}" != "200" ]]; then
    mirth_err "El listado de canales respondio HTTP ${http_code} (se esperaba 200)."
    rm -f "${tmp_channels}"
    echo
    echo "RESULTADO: ERROR (paso 2/2 - listado de canales)"
    exit "${MIRTH_ERR_HTTP}"
fi

# Contar canales: cada canal top-level viene como <channel ...> (Mirth 4.5.2
# lo emite con atributo, ej. <channel version="4.5.2">) dentro de <list>.
# Se matchea la apertura de la etiqueta seguida de espacio o cierre de tag,
# para no confundir con <channelId>, <channelGroups>, etc.
cantidad_canales="$(grep -oE '<channel[ >]' "${tmp_channels}" | wc -l | tr -d ' ')"
rm -f "${tmp_channels}"

mirth_ok "Autenticacion exitosa. Canales encontrados: ${cantidad_canales}"

echo
echo "=============================================================="
echo " RESULTADO: OK - conexion y autenticacion verificadas"
echo "=============================================================="
exit 0
