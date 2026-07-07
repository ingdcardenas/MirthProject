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
# Precedencia de MIRTH_URL: si ya viene por entorno/.env, en un terminal
# interactivo se muestra ese servidor y se pregunta si desea cambiarse
# (Enter = mantenerlo, o elegir/escribir otro desde el historial); en
# ejecucion no interactiva (stdin sin TTY, ej. CI/pipe) se respeta tal
# cual sin preguntar. Si no viene por entorno/.env, se pregunta siempre
# interactivamente ofreciendo el ultimo host usado como default y el resto
# del historial como lista numerada. Ver detalle mas abajo en el script.
# Si el host final elegido difiere del que traia .env, se reemplaza la
# linea MIRTH_URL= en .env (si el archivo existe) para que el proximo
# login muestre como "servidor actual" el ultimo realmente usado.
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

# Se guarda el valor original de .env/entorno para poder comparar mas
# adelante si el usuario termino eligiendo un host distinto y, en tal
# caso, persistir el cambio en .env (ver _mirth_persistir_env_url).
_mirth_url_original="${MIRTH_URL:-}"

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

# Persiste MIRTH_URL en SCRIPT_DIR/.env, reemplazando la linea MIRTH_URL=
# existente (o agregandola si no hay ninguna) y dejando el resto del
# archivo intacto. Politica conservadora: si no existe .env (el valor
# solo venia por variable de entorno), NO se crea uno nuevo: solo se
# informa por stdout que se usara el host elegido (ya queda en el
# historial .mirth-hosts para el proximo login).
_mirth_persistir_env_url() {
    local nuevo_url="${1:-}"
    local env_file="${SCRIPT_DIR}/.env"

    if [[ ! -f "${env_file}" ]]; then
        echo "[INFO] No existe ${env_file} (MIRTH_URL venia solo por entorno);" \
             "se usara '${nuevo_url}' en esta ejecucion, y queda guardado en" \
             "el historial .mirth-hosts para el proximo login."
        return 0
    fi

    if grep -qE '^[[:space:]]*MIRTH_URL=' "${env_file}"; then
        # Delimitador '|' en sed (en vez de '/') porque la URL contiene '/'.
        sed -i -E "s|^[[:space:]]*MIRTH_URL=.*|MIRTH_URL=\"${nuevo_url}\"|" "${env_file}"
    else
        printf 'MIRTH_URL="%s"\n' "${nuevo_url}" >> "${env_file}"
    fi
    mirth_log "Servidor actualizado en ${env_file}: MIRTH_URL=${nuevo_url}"
}

if [[ -n "${MIRTH_URL:-}" ]]; then
    # Caso 1: viene de entorno/.env. En terminal interactivo se ofrece
    # cambiarlo; en ejecucion no interactiva (sin TTY) se respeta tal cual.
    if [[ -t 0 ]]; then
        read -r -p "Servidor actual (de .env): ${MIRTH_URL} - ¿cambiar de servidor? [s/N]: " _cambiar
        if [[ "${_cambiar}" =~ ^[sS]$ ]]; then
            _mirth_elegir_host_desde_historial
        fi
    fi
    mirth_hosts_add "${MIRTH_URL}"
else
    _mirth_elegir_host_desde_historial
    mirth_hosts_add "${MIRTH_URL}"
fi

# Si el host final quedo distinto al que traia .env/entorno, persistirlo
# en .env para que el proximo login ya muestre el host realmente usado
# (y no siempre el valor original de .env).
if [[ "${MIRTH_URL}" != "${_mirth_url_original}" ]]; then
    _mirth_persistir_env_url "${MIRTH_URL}"
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
