#!/usr/bin/env bash
#
# login.sh
#
# Hace login UNA VEZ contra Mirth Connect y deja la sesion (cookie) guardada
# en un archivo FIJO (MIRTH_COOKIE_JAR, ver .env.example), para que
# test-conexion.sh, import-canal.sh y export-canal.sh la reutilicen sin
# volver a pedir usuario/contraseña, incluso en ejecuciones o terminales
# distintos, mientras Mirth no expire la sesion.
#
# Uso:
#   ./login.sh
#
# Al terminar, correr './logout.sh' para cerrar la sesion explicitamente.
#
# Codigos de salida:
#   0  -> login OK, sesion persistida
#   11 -> login fallido
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

# Si MIRTH_URL no llego por entorno ni por .env, se pregunta
# interactivamente el host, igual que se pregunta el usuario en
# mirth_login. Default: localhost:8443. Se acepta tanto un host/IP
# suelto (se completa con https:// y :8443) como una URL completa
# (https://host:puerto) por si el servidor usa otro puerto/protocolo.
if [[ -z "${MIRTH_URL:-}" ]]; then
    read -r -p "Host de Mirth Connect [localhost]: " mirth_host
    mirth_host="${mirth_host:-localhost}"
    if [[ "${mirth_host}" == http://* || "${mirth_host}" == https://* ]]; then
        MIRTH_URL="${mirth_host}"
    else
        MIRTH_URL="https://${mirth_host}:8443"
    fi
    export MIRTH_URL
fi

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/mirth-api.sh"

echo "=============================================================="
echo " Login persistente contra Mirth Connect"
echo " URL objetivo:      ${MIRTH_URL}"
echo " Archivo de sesion: ${MIRTH_COOKIE_JAR}"
echo "=============================================================="
echo

version="$(mirth_check_reachable)" || {
    mirth_err "Servidor no alcanzable. Revisar red/proxy antes de intentar login."
    exit "${MIRTH_ERR_HTTP}"
}
mirth_log "Version del servidor: ${version}"

if mirth_has_session; then
    mirth_log "Ya existe una sesion valida en ${MIRTH_COOKIE_JAR}."
    read -r -p "¿Renovar login de todas formas? [s/N]: " respuesta
    if [[ ! "${respuesta}" =~ ^[sS]$ ]]; then
        mirth_ok "Se mantiene la sesion existente. Nada que hacer."
        exit 0
    fi
fi

if ! mirth_login; then
    echo
    echo "RESULTADO: ERROR - login fallido"
    exit "${MIRTH_ERR_LOGIN}"
fi

chmod 600 "${MIRTH_COOKIE_JAR}"

echo
echo "=============================================================="
mirth_ok "Sesion activa y guardada en: ${MIRTH_COOKIE_JAR}"
echo " Esta sesion queda disponible para test-conexion.sh, import-canal.sh"
echo " y export-canal.sh en esta u otras terminales, SIN volver a pedir"
echo " credenciales, hasta que:"
echo "   - el propio Mirth Connect expire la sesion por timeout de servidor, o"
echo "   - se ejecute './logout.sh' para cerrarla explicitamente."
echo "=============================================================="
exit 0
