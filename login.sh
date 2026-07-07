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
# Historial de hosts: cada host/URL usado se guarda en .mirth-hosts (raiz
# del repo, gitignoreado) para poder elegirlo de nuevo en logins futuros.
# Precedencia de MIRTH_URL: si ya viene por entorno/.env se usa tal cual
# sin preguntar (solo se registra en el historial); si no, se pregunta
# interactivamente ofreciendo el ultimo host usado como default y el resto
# del historial como lista numerada. Ver detalle mas abajo en el script.
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

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/mirth-api.sh"

# ---------------------------------------------------------------------------
# Resolucion de MIRTH_URL - precedencia (de mayor a menor prioridad):
#   1. MIRTH_URL ya seteada por entorno o por .env -> se respeta tal cual
#      (no se pregunta nada), pero igual se registra en el historial de
#      hosts para que quede disponible como opcion en logins futuros.
#   2. Interactivo: se ofrece el historial de hosts usados anteriormente
#      (.mirth-hosts), mostrando el ultimo usado como default [Enter], la
#      lista numerada de hosts guardados para elegir, o la posibilidad de
#      escribir un host/URL nuevo (que se agrega al historial).
#   3. Si no hay historial todavia, se pregunta el host con default
#      "localhost" (comportamiento historico de este script).
#
# En todos los casos se acepta tanto un host/IP suelto (se completa con
# https:// y :8443) como una URL completa (https://host:puerto), por si el
# servidor usa otro puerto/protocolo.
# ---------------------------------------------------------------------------
_mirth_parse_host_input() {
    local entrada="${1:-}"
    if [[ "${entrada}" == http://* || "${entrada}" == https://* ]]; then
        printf '%s\n' "${entrada}"
    else
        printf 'https://%s:8443\n' "${entrada}"
    fi
}

if [[ -n "${MIRTH_URL:-}" ]]; then
    # Caso 1: viene de entorno/.env, se respeta sin preguntar.
    mirth_hosts_add "${MIRTH_URL}"
else
    mapfile -t _hosts_hist < <(mirth_hosts_list)

    if [[ "${#_hosts_hist[@]}" -eq 0 ]]; then
        # Caso 3: sin historial aun.
        read -r -p "Host de Mirth Connect [localhost]: " mirth_host
        mirth_host="${mirth_host:-localhost}"
        MIRTH_URL="$(_mirth_parse_host_input "${mirth_host}")"
    else
        # Caso 2: hay historial -> ofrecer default + lista numerada.
        _ultimo="${_hosts_hist[0]}"
        echo "Hosts guardados:"
        for i in "${!_hosts_hist[@]}"; do
            printf '  [%d] %s\n' "$((i + 1))" "${_hosts_hist[${i}]}"
        done
        read -r -p "Host actual: ${_ultimo} - [Enter] para usarlo, numero de la lista, o host/URL nuevo: " _seleccion

        if [[ -z "${_seleccion}" ]]; then
            MIRTH_URL="${_ultimo}"
        elif [[ "${_seleccion}" =~ ^[0-9]+$ ]] && (( _seleccion >= 1 && _seleccion <= ${#_hosts_hist[@]} )); then
            MIRTH_URL="${_hosts_hist[$((_seleccion - 1))]}"
        else
            MIRTH_URL="$(_mirth_parse_host_input "${_seleccion}")"
        fi
    fi

    mirth_hosts_add "${MIRTH_URL}"
fi

export MIRTH_URL

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
