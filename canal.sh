#!/usr/bin/env bash
#
# canal.sh <subcomando> [args...]
#
# Punto de entrada unico para trabajar un canal de Mirth como "carpeta
# proyecto" legible/editable. Es un wrapper fino: NO reimplementa logica,
# solo despacha a los scripts existentes (explode-canal.sh / build-canal.sh),
# que a su vez delegan en el motor lib/canal_proyecto.py.
#
# Subcomandos:
#
#   deconstruir <canal.xml | carpeta-canal> [carpeta-destino]
#       Explota un XML de canal a una carpeta-proyecto:
#         original.xml, channel.yml, mapper.json, source/, destination_N/
#       Si el primer argumento es una carpeta-canal ya existente (contiene
#       original.xml), se re-explota desde su original.xml (util para
#       regenerar la vista legible sin volver a importar desde Mirth).
#       Equivale a: ./explode-canal.sh <canal.xml> [carpeta-destino]
#
#   reconstruir <carpeta-canal> [xml-salida]
#       Reconstruye el XML desde la carpeta-proyecto y verifica el
#       resultado contra original.xml (byte-a-byte si no hubo ediciones,
#       funcional si hubo cambios). NO exporta nada a Mirth.
#       Equivale a: ./build-canal.sh <carpeta-canal> [xml-salida]
#
# Ejemplos:
#   ./canal.sh deconstruir canales/MiGrupo/01_-_MiCanal.xml
#   ./canal.sh deconstruir canales/MiGrupo/01_-_MiCanal
#   ./canal.sh reconstruir canales/MiGrupo/01_-_MiCanal
#   ./canal.sh --help
#
# Codigos de salida (heredados del script delegado; se propagan tal cual):
#   0  -> OK
#   1  -> uso incorrecto (falta subcomando, argumentos, o subcomando desconocido)
#   2  -> origen invalido (XML/carpeta-canal no existe o no tiene el formato esperado)
#   3  -> python3 no disponible o falta el modulo PyYAML
#   4  -> (solo reconstruir) el XML reconstruido no es bien formado o hay
#         discrepancia estructural real detectada por la verificacion
#   20 -> error inesperado durante la operacion

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

mostrar_ayuda() {
    sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

if [[ $# -lt 1 || "$1" == "--help" || "$1" == "-h" ]]; then
    mostrar_ayuda
    [[ $# -lt 1 ]] && exit 1
    exit 0
fi

SUBCOMANDO="$1"
shift

case "${SUBCOMANDO}" in
    deconstruir)
        if [[ $# -lt 1 ]]; then
            echo "Uso: $0 deconstruir <canal.xml | carpeta-canal> [carpeta-destino]" >&2
            exit 1
        fi

        ORIGEN="$1"
        shift

        if [[ -d "${ORIGEN}" ]]; then
            if [[ ! -f "${ORIGEN}/original.xml" ]]; then
                echo "[ERROR] '${ORIGEN}' es una carpeta pero no contiene original.xml (no es una carpeta-canal valida)." >&2
                exit 2
            fi
            XML_ORIGEN="${ORIGEN}/original.xml"
            DESTINO_DEFAULT="${ORIGEN}"
        elif [[ -f "${ORIGEN}" ]]; then
            XML_ORIGEN="${ORIGEN}"
            DESTINO_DEFAULT="${ORIGEN%.xml}"
        else
            echo "[ERROR] No existe o no es legible: ${ORIGEN}" >&2
            exit 2
        fi

        DESTINO="${1:-${DESTINO_DEFAULT}}"

        exec "${SCRIPT_DIR}/explode-canal.sh" "${XML_ORIGEN}" "${DESTINO}"
        ;;

    reconstruir)
        if [[ $# -lt 1 ]]; then
            echo "Uso: $0 reconstruir <carpeta-canal> [xml-salida]" >&2
            exit 1
        fi

        exec "${SCRIPT_DIR}/build-canal.sh" "$@"
        ;;

    *)
        echo "[ERROR] Subcomando desconocido: '${SUBCOMANDO}'" >&2
        echo "        Subcomandos validos: deconstruir, reconstruir" >&2
        echo "        Usa '$0 --help' para ver el detalle." >&2
        exit 1
        ;;
esac
