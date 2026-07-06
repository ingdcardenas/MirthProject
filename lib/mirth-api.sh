#!/usr/bin/env bash
#
# lib/mirth-api.sh
#
# Libreria comun para hablar con la API REST de Mirth Connect (motor Jersey,
# version 4.5.2 confirmada) desde scripts de shell.
#
# Debe ser SOURCEADA, no ejecutada directamente:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/mirth-api.sh"
#
# Requiere: curl
#
# Puntos criticos de conectividad (ya verificados en este entorno):
#   - Puede haber un proxy corporativo (ej. proxy:8080) exportado en las
#     variables de entorno (https_proxy, HTTP_PROXY, ALL_PROXY, etc.) que
#     bloquea (403) el acceso al Mirth. TODA llamada debe saltar el proxy
#     con --noproxy '*'.
#   - El certificado del Mirth es autofirmado -> se usa -k.
#   - La API exige el header "X-Requested-With" en toda request, si falta
#     responde HTTP 400.
#   - Login: POST /api/users/_login (form-urlencoded: username, password)
#     devuelve una cookie de sesion JSESSIONID que se reutiliza via cookie
#     jar de curl (-c / -b).
#
# Modelo de sesion (persistente, definido por pedido del usuario):
#   - MIRTH_COOKIE_JAR es un archivo FIJO (no temporal por-PID) que
#     sobrevive entre ejecuciones y terminales distintas. Default:
#     "${SCRIPT_DIR}/.mirth-session" (gitignoreado), configurable en .env.
#   - login.sh crea/renueva esa cookie una vez.
#   - test-conexion.sh / import-canal.sh / export-canal.sh la REUSAN sin
#     volver a pedir credenciales, validando con mirth_has_session.
#   - logout.sh es el UNICO que cierra sesion en el servidor y borra el
#     archivo. Los scripts normales NO borran la cookie persistente al
#     salir (a diferencia de un cookie jar temporal, que si se limpia).

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuracion / defaults
# ---------------------------------------------------------------------------

MIRTH_URL="${MIRTH_URL:-https://localhost:8443}"

# Cookie jar persistente por defecto: vive junto a la libreria (carpeta del
# proyecto), fuera de /tmp, para que sobreviva entre ejecuciones/terminales.
_MIRTH_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
MIRTH_COOKIE_JAR="${MIRTH_COOKIE_JAR:-${_MIRTH_LIB_DIR}/.mirth-session}"

MIRTH_INSECURE_TLS="${MIRTH_INSECURE_TLS:-true}"

# Codigo de retorno especial cuando el servidor responde con un HTTP de error
readonly MIRTH_ERR_HTTP=10
readonly MIRTH_ERR_LOGIN=11
readonly MIRTH_ERR_NOTFOUND=12
readonly MIRTH_ERR_SESSION_EXPIRED=13

# ---------------------------------------------------------------------------
# Utilidades de mensajes
# ---------------------------------------------------------------------------

mirth_log()  { echo "[mirth] $*" >&2; }
mirth_ok()   { echo "[OK]    $*" >&2; }
mirth_err()  { echo "[ERROR] $*" >&2; }

# ---------------------------------------------------------------------------
# mirth_curl: wrapper de curl con las opciones criticas ya aplicadas.
#
# Uso: mirth_curl [opciones-curl-extra...] <path-o-url>
#
# Siempre agrega:
#   --noproxy '*'                 -> salta el proxy Squid corporativo
#   -k (si MIRTH_INSECURE_TLS=true) -> certificado autofirmado
#   -H "X-Requested-With: mirth-cli-tools"
#   -b/-c "$MIRTH_COOKIE_JAR"     -> reusa/guarda cookie de sesion
#
# El ULTIMO argumento recibido siempre se interpreta como el path
# (relativo a MIRTH_URL) o URL completa. Todos los argumentos anteriores se
# pasan tal cual a curl (opciones, valores de -H, -o, -w, etc.).
# ---------------------------------------------------------------------------
mirth_curl() {
    local -a curl_opts=(-s --noproxy '*' -H "X-Requested-With: mirth-cli-tools")

    if [[ "${MIRTH_INSECURE_TLS}" == "true" ]]; then
        curl_opts+=(-k)
    fi

    curl_opts+=(-c "${MIRTH_COOKIE_JAR}" -b "${MIRTH_COOKIE_JAR}")

    if [[ $# -eq 0 ]]; then
        mirth_err "mirth_curl: falta el path/URL como ultimo argumento."
        return 1
    fi

    local argc=$#
    local url_or_path="${!argc}"
    local -a args=("${@:1:$((argc-1))}")

    local full_url="${url_or_path}"
    if [[ "${url_or_path}" != http://* && "${url_or_path}" != https://* ]]; then
        full_url="${MIRTH_URL}${url_or_path}"
    fi

    curl "${curl_opts[@]}" "${args[@]}" "${full_url}"
}

# ---------------------------------------------------------------------------
# mirth_curl_status: igual que mirth_curl pero devuelve el codigo HTTP en vez
# del cuerpo (util para validaciones). El cuerpo, si se necesita, se puede
# volcar a un archivo con -o.
# ---------------------------------------------------------------------------
mirth_curl_status() {
    mirth_curl -o /dev/null -w '%{http_code}' "$@"
}

# ---------------------------------------------------------------------------
# mirth_check_reachable: valida que el servidor responde y muestra su
# version. No requiere autenticacion (GET /api/server/version).
#
# Retorna 0 si respondio 200, distinto de 0 en otro caso.
# Imprime la version por stdout si tuvo exito.
# ---------------------------------------------------------------------------
mirth_check_reachable() {
    local tmp_body
    tmp_body="$(mktemp)"
    local http_code
    http_code="$(mirth_curl -H 'Accept: text/plain' -o "${tmp_body}" -w '%{http_code}' '/api/server/version')"
    local curl_rc=$?

    if [[ ${curl_rc} -ne 0 ]]; then
        mirth_err "No se pudo contactar a ${MIRTH_URL} (curl rc=${curl_rc}). Verificar red/proxy."
        rm -f "${tmp_body}"
        return "${MIRTH_ERR_HTTP}"
    fi

    if [[ "${http_code}" != "200" ]]; then
        mirth_err "El servidor respondio HTTP ${http_code} en /api/server/version"
        rm -f "${tmp_body}"
        return "${MIRTH_ERR_HTTP}"
    fi

    cat "${tmp_body}"
    rm -f "${tmp_body}"
    return 0
}

# ---------------------------------------------------------------------------
# mirth_has_session: verifica si MIRTH_COOKIE_JAR existe y sigue
# representando una sesion valida en el servidor. Usa una llamada barata
# autenticada (/api/channels/idsAndNames) y confirma que responde 200 (no
# 401/403, que es lo que devuelve Mirth cuando la sesion expiro o no existe).
#
# Retorna 0 si hay sesion valida, distinto de 0 en otro caso (sin loguear
# error: es una verificacion silenciosa para que el llamador decida que
# hacer, ej. pedir al usuario correr login.sh).
# ---------------------------------------------------------------------------
mirth_has_session() {
    if [[ ! -s "${MIRTH_COOKIE_JAR}" ]]; then
        return 1
    fi

    local http_code
    http_code="$(mirth_curl_status -H 'Accept: application/xml' '/api/channels/idsAndNames')"

    [[ "${http_code}" == "200" ]]
}

# ---------------------------------------------------------------------------
# mirth_require_session: helper para scripts que NO deben re-loguear solos.
# Si hay sesion valida, retorna 0 silenciosamente. Si no, imprime un mensaje
# claro indicando que hay que correr login.sh y retorna MIRTH_ERR_LOGIN.
# ---------------------------------------------------------------------------
mirth_require_session() {
    if mirth_has_session; then
        return 0
    fi

    mirth_err "No hay una sesion valida en ${MIRTH_COOKIE_JAR}."
    mirth_err "Ejecuta './login.sh' primero para autenticarte, luego reintenta."
    return "${MIRTH_ERR_LOGIN}"
}

# ---------------------------------------------------------------------------
# mirth_check_session_expired <http_code>
#
# Chequeo CENTRALIZADO y RUIDOSO de sesion expirada/invalida, para usar en
# las operaciones reales (listar canales, exportar, importar), NO en
# mirth_has_session (ese es un probe silencioso: un 401 ahi simplemente
# significa "todavia no hay sesion", no un error a gritar).
#
# Uso tipico en los scripts:
#   http_code="$(mirth_curl_status ... '/api/channels')"
#   if mirth_check_session_expired "${http_code}"; then
#       exit "${MIRTH_ERR_SESSION_EXPIRED}"
#   fi
#   # aca seguir con el manejo normal de 200/404/500/etc.
#
# Retorna 0 (y emite el mensaje) si el codigo es 401 (sesion expirada o
# invalida). Retorna 1 sin emitir nada si el codigo NO es 401 (el llamador
# sigue con su propio manejo de errores para 404/500/etc, sin cambios).
# ---------------------------------------------------------------------------
mirth_check_session_expired() {
    local http_code="${1:-}"

    if [[ "${http_code}" == "401" ]]; then
        mirth_err "Sesion expirada o invalida (HTTP 401). Ejecuta ./login.sh para renovar la sesion."
        return 0
    fi

    return 1
}

# ---------------------------------------------------------------------------
# mirth_login [usuario]
#
# Hace login contra /api/users/_login. Si no se pasa usuario, usa
# $MIRTH_USER o pregunta interactivamente. La contrasena SIEMPRE se pide
# interactiva con `read -s` salvo que ya venga en $MIRTH_PASSWORD (variable
# de entorno, no persistida en disco).
#
# Guarda la cookie de sesion en $MIRTH_COOKIE_JAR con permisos 600.
#
# Retorna 0 si el login fue exitoso, distinto de 0 en otro caso.
# ---------------------------------------------------------------------------
mirth_login() {
    local user="${1:-${MIRTH_USER:-}}"

    if [[ -z "${user}" ]]; then
        read -r -p "Usuario de Mirth Connect: " user
    fi

    if [[ -z "${user}" ]]; then
        mirth_err "No se indico usuario. Abortando login."
        return "${MIRTH_ERR_LOGIN}"
    fi

    local password="${MIRTH_PASSWORD:-}"
    if [[ -z "${password}" ]]; then
        read -r -s -p "Password de ${user}@Mirth Connect: " password
        echo >&2
    fi

    if [[ -z "${password}" ]]; then
        mirth_err "No se indico contrasena. Abortando login."
        return "${MIRTH_ERR_LOGIN}"
    fi

    # Crear/limpiar cookie jar con permisos restrictivos ANTES del login.
    # Se crea el directorio contenedor por si MIRTH_COOKIE_JAR apunta a una
    # ruta como ~/.cache/mirth/session que aun no existe.
    mkdir -p "$(dirname -- "${MIRTH_COOKIE_JAR}")"
    : > "${MIRTH_COOKIE_JAR}"
    chmod 600 "${MIRTH_COOKIE_JAR}"

    local tmp_body
    tmp_body="$(mktemp)"
    chmod 600 "${tmp_body}"

    local http_code
    http_code="$(mirth_curl -X POST \
        --data-urlencode "username=${user}" \
        --data-urlencode "password=${password}" \
        -o "${tmp_body}" -w '%{http_code}' \
        '/api/users/_login')"

    # No dejar la password en memoria de variables mas de lo necesario
    unset password

    if [[ "${http_code}" != "200" ]]; then
        mirth_err "Login fallido (HTTP ${http_code}). Revisar usuario/contrasena."
        rm -f "${tmp_body}"
        return "${MIRTH_ERR_LOGIN}"
    fi

    rm -f "${tmp_body}"
    mirth_ok "Login exitoso como '${user}'."
    return 0
}

# ---------------------------------------------------------------------------
# mirth_logout: cierra la sesion en el servidor y borra el cookie jar
# persistente local. Es EXPLICITO a proposito: solo debe invocarlo
# logout.sh. Los demas scripts (test-conexion.sh, import-canal.sh,
# export-canal.sh) NO llaman a esta funcion, para no invalidar la sesion
# que el usuario dejo activa con login.sh.
# ---------------------------------------------------------------------------
mirth_logout() {
    if [[ -f "${MIRTH_COOKIE_JAR}" ]]; then
        mirth_curl -X POST '/api/users/_logout' >/dev/null 2>&1 || true
        rm -f "${MIRTH_COOKIE_JAR}"
        mirth_log "Sesion cerrada y cookie jar eliminado (${MIRTH_COOKIE_JAR})."
    else
        mirth_log "No habia cookie jar de sesion en ${MIRTH_COOKIE_JAR}."
    fi
}

# ---------------------------------------------------------------------------
# mirth_cleanup_temp_jar: borra SOLO cookie jars temporales (por ejemplo, uno
# creado ad-hoc con MIRTH_COOKIE_JAR=$(mktemp) para un uso puntual aislado).
# NUNCA borra el cookie jar persistente por defecto (${SCRIPT_DIR}/.mirth-session
# o el que se haya configurado en .env) -- ese solo lo borra logout.sh.
#
# Uso tipico: trap 'mirth_cleanup_temp_jar "$MI_JAR_TEMPORAL"' EXIT
# ---------------------------------------------------------------------------
mirth_cleanup_temp_jar() {
    local jar="${1:-}"
    [[ -n "${jar}" && -f "${jar}" ]] && rm -f "${jar}"
}

# ---------------------------------------------------------------------------
# mirth_sanitize_name <nombre>
#
# Saneo centralizado de nombres (de canal o de grupo) para usarlos como
# nombre de archivo/carpeta en filesystem, usado por import-canal.sh y
# import-grupo.sh.
#
# Reglas de saneo:
#   1. Translitera caracteres acentuados a su equivalente ASCII (a, e, i, o,
#      u, n, y sus mayusculas) via unicodedata.normalize('NFKD', ...) +
#      descarte de diacriticos combinantes. La n/N se reemplaza explicito
#      ANTES de NFKD porque NFKD no separa la tilde de la n (no es un
#      caracter combinante en Unicode, es una letra propia).
#   2. Cualquier caracter que no sea A-Za-z0-9._- se reemplaza por '_'
#      (mismo criterio previo, para simbolos que no son letras acentuadas:
#      espacios, parentesis, etc).
#   3. Colapsa secuencias de '_' repetidos en uno solo.
#   4. Recorta '_' al principio/final del nombre resultante (para no dejar
#      "Nombre_" o archivos "Nombre_.xml").
#
# Uso: safe="$(mirth_sanitize_name "${nombre_original}")"
# ---------------------------------------------------------------------------
mirth_sanitize_name() {
    local nombre="${1:-}"
    python3 -c '
import sys
import re
import unicodedata

s = sys.argv[1]
s = s.replace("ñ", "n").replace("Ñ", "N")
s = unicodedata.normalize("NFKD", s)
s = "".join(c for c in s if not unicodedata.combining(c))
s = re.sub(r"[^A-Za-z0-9._-]", "_", s)
s = re.sub(r"_+", "_", s)
s = s.strip("_")
print(s)
' "${nombre}"
}
