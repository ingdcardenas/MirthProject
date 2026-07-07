# mirthConnect — toolkit CLI para canales de Mirth Connect

Toolkit de bash + curl + python3 que habla con la API REST de Mirth
Connect para trabajar los canales como **proyectos legibles y
versionables**: explota el XML monolítico de un canal en piezas
editables (SQL, JS, configuración) por separado, y permite reconstruirlo
verificando que el resultado sea fiel al original antes de volver a
subirlo al servidor.

## Requisitos

- `bash` 4+, `curl`, `python3`
- `PyYAML` (`pip install pyyaml`) — solo para el flujo "canal como
  proyecto" (`canal.sh deconstruir`/`reconstruir`)

## Quickstart

```bash
./login.sh
./import-grupo.sh "<grupo>"                         # o ./import-canal.sh "<canal>"
./canal.sh deconstruir canales/<grupo>/<canal>.xml  # explota el XML a carpeta editable
# ...editar SQL/JS/config dentro de la carpeta-proyecto...
./canal.sh reconstruir canales/<grupo>/<canal>       # reconstruye y verifica contra el original
./export-canal.sh canales/<grupo>/<canal>/canal.xml --deploy
./logout.sh
```

## Comandos clave

| Comando | Qué hace |
|---|---|
| `./login.sh` | Autentica una vez y persiste la sesión (cookie jar) para el resto de scripts. Recuerda los hosts usados y pregunta cuál usar en cada login. |
| `./import-grupo.sh <grupo>` / `./import-canal.sh <canal>` | Descarga desde Mirth un grupo de canales o un canal individual como XML plano. |
| `./canal.sh deconstruir <xml>` | Explota el XML del canal en una carpeta-proyecto legible y editable. |
| `./canal.sh reconstruir <carpeta>` | Reconstruye el XML desde la carpeta-proyecto y verifica que sea fiel al original. |
| `./export-canal.sh <xml> [--deploy]` | Sube el canal reconstruido a Mirth (crea/actualiza, y opcionalmente despliega). |
| `./logout.sh` | Cierra la sesión en el servidor y borra el cookie jar local. |

## Seguridad

Los XML de canales pueden contener credenciales u otros datos sensibles
embebidos (conexiones, contraseñas de destino, etc.). La carpeta
`canales/` está gitignoreada por defecto — no versionar datos reales.

## Documentación completa

Para la referencia detallada (configuración, flujo de sesión, ciclo
end-to-end, estructura de carpetas, modelo de verificación
"diff-and-splice", inventario de endpoints de la API y tabla completa de
scripts con códigos de retorno), ver
[README-DETALLADO.md](./README-DETALLADO.md).
