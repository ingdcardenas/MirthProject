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
# El historial es la FUENTE DE VERDAD del "servidor actual": si existe,
# manda por encima de cualquier MIRTH_URL de entorno/.env (que solo se usa
# como fallback si todavia no hay historial). El .env NUNCA se modifica
# por este script. Precedencia de MIRTH_URL:
#   1. Si hay historial (.mirth-hosts no vacio) -> se muestra el ultimo
#      host usado como "servidor actual" y, en terminal interactivo, se
#      pregunta si desea cambiarse (Enter = mantenerlo, "s" = elegir/
#      escribir otro desde el historial); en ejecucion no interactiva
#      (stdin sin TTY) se usa ese ultimo host sin preguntar.
#   2. Si no hay historial pero MIRTH_URL viene de entorno/.env, se ofrece
#      ese valor como "servidor actual" con el mismo comportamiento.
#   3. Si no hay historial ni MIRTH_URL, se pregunta el host con default
#      "localhost" (comportamiento historico de este script).
# Ver detalle mas abajo en el script.
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
# Resolucion de MIRTH_URL: ver precedencia detallada en el comentario de
# cabecera del script (el historial .mirth-hosts manda sobre .env/entorno).
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

# Ofrece el historial de hosts (.mirth-hosts): default = ultimo usado,
# lista numerada de guardados, o posibilidad de escribir un host/URL
# nuevo. Deja el resultado en MIRTH_URL. Reutilizada por el Caso 1
# (cuando el usuario decide cambiar el servidor de .env) y el Caso 2.
_mirth_elegir_host_desde_historial() {
    mapfile -t _hosts_hist < <(mirth_hosts_list)

    if [[ "${#_hosts_hist[@]}" -eq 0 ]]; then
        # Sin historial aun.
        read -r -p "Host de Mirth Connect [localhost]: " mirth_host
        mirth_host="${mirth_host:-localhost}"
        MIRTH_URL="$(_mirth_parse_host_input "${mirth_host}")"
    else
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
}

# El historial (.mirth-hosts) es la fuente de verdad del "servidor
# actual": si tiene algo, manda por encima de MIRTH_URL de entorno/.env.
_mirth_ultimo_historial="$(mirth_hosts_last)"
if [[ -n "${_mirth_ultimo_historial}" ]]; then
    _mirth_servidor_actual="${_mirth_ultimo_historial}"
elif [[ -n "${MIRTH_URL:-}" ]]; then
    _mirth_servidor_actual="${MIRTH_URL}"
else
    _mirth_servidor_actual=""
fi

if [[ -n "${_mirth_servidor_actual}" ]]; then
    if [[ -t 0 ]]; then
        read -r -p "Servidor actual: ${_mirth_servidor_actual} - ¿cambiar de servidor? [s/N]: " _cambiar
        if [[ "${_cambiar}" =~ ^[sS]$ ]]; then
            _mirth_elegir_host_desde_historial
        else
            MIRTH_URL="${_mirth_servidor_actual}"
        fi
    else
        # Sin TTY: se respeta el servidor actual (historial o .env) sin
        # preguntar.
        MIRTH_URL="${_mirth_servidor_actual}"
    fi
else
    # Sin historial ni MIRTH_URL de entorno/.env: preguntar host nuevo.
    _mirth_elegir_host_desde_historial
fi

mirth_hosts_add "${MIRTH_URL}"

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
