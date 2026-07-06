# mirthConnect — herramientas CLI para gestionar canales de Mirth Connect

Scripts de shell para probar conectividad y gestionar (importar/exportar)
canales de un servidor Mirth Connect vía su API REST (motor Jersey), sin
depender de la consola administrativa gráfica.

Probado contra Mirth Connect **4.5.2** en `https://localhost:8443`.

## Requisitos

- `bash` 4+
- `curl`
- `python3` (usado para parsear XML en `import-canal.sh` / `import-grupo.sh` /
  `export-canal.sh`)
- `PyYAML` (`pip install pyyaml`) — solo necesario para `explode-canal.sh` /
  `build-canal.sh` (flujo "canal como proyecto", ver sección dedicada más
  abajo); no lo usan los scripts de conexión/import/export de XML plano

## Configuración

1. Copiar `.env.example` a `.env` y ajustar los valores necesarios:

   ```bash
   cp .env.example .env
   ```

2. **Nunca** poner la contraseña en `.env`. La contraseña se pide siempre
   de forma interactiva (`read -s`) al ejecutar `./login.sh`. Si se necesita
   automatizar en un pipeline controlado, se puede exportar
   `MIRTH_PASSWORD` como variable de entorno antes de ejecutar (no
   recomendado fuera de ese caso).

## Flujo de sesión (login una vez, reutilizar en el resto)

La sesión es **persistente**: se guarda en un archivo (cookie jar de curl,
`MIRTH_COOKIE_JAR`, por defecto `./.mirth-session` dentro de esta carpeta,
ignorado por git). Un login sirve para múltiples ejecuciones y terminales
distintos, hasta que se cierre explícitamente con `./logout.sh` o el propio
Mirth Connect expire la sesión por timeout de servidor.

```bash
./login.sh          # UNA vez: pide usuario/contraseña, guarda la sesión
./test-conexion.sh  # cuantas veces se quiera, sin pedir clave de nuevo
./import-canal.sh "HL7 Laboratorio Central"
./export-canal.sh canales/HL7_Laboratorio_Central.xml --deploy
./logout.sh          # al terminar: cierra sesión en el servidor y borra el archivo
```

Si `test-conexion.sh`, `import-canal.sh` o `export-canal.sh` no encuentran
una sesión válida (no se corrió `login.sh`, o la sesión expiró), terminan
con un mensaje claro pidiendo ejecutar `./login.sh` — **no** re-loguean
automáticamente, para no interrumpir con un prompt de contraseña en medio
de un flujo no interactivo.

### Nota sobre el proxy corporativo

Este entorno tiene un proxy Squid corporativo (`proxy.ejemplo.local:8080`)
exportado en las variables de entorno (`https_proxy`, `HTTP_PROXY`,
`ALL_PROXY`, etc.) que bloquea (403) el acceso directo al Mirth. Todos los
scripts de esta carpeta usan internamente `curl --noproxy '*'` para saltar
el proxy al hablar con el Mirth — no es necesario hacer nada adicional,
pero si se copian fragmentos de estos scripts a otro lado, no olvidar ese
flag.

## Scripts

### `login.sh`

Hace login interactivo (host de `.env`/`MIRTH_URL` o preguntado con
default `localhost:8443`; usuario de `.env`/`MIRTH_USER` o preguntado;
contraseña siempre con `read -s`) y persiste la sesión en
`MIRTH_COOKIE_JAR` con permisos `600`. Si ya hay una sesión válida,
pregunta si se quiere renovar antes de pedir credenciales de nuevo.

```bash
./login.sh
```

Códigos de retorno: `0` login OK / sesión ya activa, `11` login fallido,
`20` error inesperado.

### `logout.sh`

Cierra la sesión en el servidor (`POST /api/users/_logout`) y borra el
archivo de sesión persistente. Es el **único** script que invalida la
sesión — los demás nunca la cierran automáticamente.

```bash
./logout.sh
```

### `test-conexion.sh`

Prueba de conectividad en dos pasos:

1. Verifica alcance del servidor y muestra su versión
   (`GET /api/server/version`, sin autenticación).
2. Reutiliza la sesión persistente (creada con `login.sh`) y valida que
   autentica listando los canales (`GET /api/channels`), mostrando cuántos
   hay. Si no hay sesión válida, indica ejecutar `./login.sh` primero (no
   loguea automáticamente).

```bash
./login.sh          # una vez
./test-conexion.sh  # cuantas veces se quiera
```

Salida `OK`/`ERROR` clara en español. Códigos de retorno:

| Código | Significado |
|---|---|
| 0  | Conexión y autenticación verificadas |
| 10 | Error de conexión / HTTP contra el servidor |
| 11 | No hay sesión válida (falta correr `login.sh`) |
| 13 | Sesión expirada/inválida detectada durante la operación (HTTP 401) — correr `./login.sh` |
| 20 | Error inesperado / dependencia faltante |

### `import-grupo.sh <groupId|nombre-del-grupo>`

Requiere sesión previa (`./login.sh`). Importa un **grupo de canales**
completo desde Mirth (`/api/channelgroups`): resuelve el grupo por id o
por nombre exacto, crea `canales/<grupo-sanitizado>/`, descarga cada canal
miembro (`GET /api/channels/{id}`) a `canales/<grupo>/<canal>.xml` y
guarda además la metadata del propio grupo (membresías/orden) en
`canales/<grupo>/_grupo.xml`, para poder reexportar esa relación
grupo↔canales más adelante (hacia Mirth).

```bash
./import-grupo.sh "NombreDelGrupo (DEV)"
./import-grupo.sh <groupId>
```

Códigos de retorno relevantes: `0` OK (o parcial con algún canal fallido
ver abajo), `1` uso incorrecto, `10` error de conexión/HTTP, `11` no hay
sesión, `12` grupo no encontrado, `13` sesión expirada/inválida (HTTP 401)
— correr `./login.sh`, `20` error inesperado. Si al menos un canal miembro
falla al importarse, el script termina con `10` aunque el resto se haya
importado correctamente (revisar el resumen final en la salida).

### `import-canal.sh <channelId|nombre>`

Requiere sesión previa (`./login.sh`). Descarga un canal en formato XML
nativo de Mirth y lo guarda en `canales/<nombre-sanitizado>.xml`. Acepta
tanto el `channelId` (UUID) como el nombre exacto del canal (en cuyo caso
lo resuelve vía `/api/channels/idsAndNames`).

```bash
./import-canal.sh "HL7 Laboratorio Central"
./import-canal.sh 3a1e2b4c-5d6e-7f80-9a1b-2c3d4e5f6789
```

Códigos de retorno relevantes: `0` OK, `1` uso incorrecto, `10` error de
conexión/HTTP, `11` no hay sesión, `12` canal no encontrado, `13` sesión
expirada/inválida (HTTP 401) — correr `./login.sh`, `20` error inesperado.

### `export-canal.sh <archivo.xml> [--deploy]`

Requiere sesión previa (`./login.sh`). Crea o actualiza un canal en Mirth
a partir de un XML (típicamente uno generado por `import-canal.sh`), usando
el `<id>` embebido en el XML. Si el canal ya existe en el servidor lo
actualiza; si no existe, lo crea.

```bash
./export-canal.sh canales/HL7_Laboratorio_Central.xml
./export-canal.sh canales/HL7_Laboratorio_Central.xml --deploy   # además despliega el canal
```

Códigos de retorno relevantes: `0` OK, `1` uso incorrecto, `10` error de
conexión/HTTP, `11` no hay sesión, `13` sesión expirada/inválida (HTTP 401)
— correr `./login.sh`, `20` error inesperado.

### `canal.sh <subcomando> [args...]` — interfaz unificada recomendada

**No requiere sesión ni red.** Punto de entrada único y recomendado para
trabajar el flujo "canal como proyecto": es un wrapper fino que solo
despacha a `explode-canal.sh` / `build-canal.sh` (que a su vez delegan en
`lib/canal_proyecto.py`) sin reimplementar lógica propia. `explode-canal.sh`
y `build-canal.sh` siguen disponibles y funcionan igual de forma
independiente (compatibilidad hacia atrás); para trabajo nuevo se
recomienda `canal.sh` por unificar ambos pasos bajo una sola interfaz con
nombres en español (`deconstruir`/`reconstruir`).

Subcomandos:

- `./canal.sh deconstruir <canal.xml | carpeta-canal> [carpeta-destino]`
  — explota un XML a carpeta-proyecto. Equivale a `./explode-canal.sh`.
  Si el primer argumento es una carpeta-canal ya explotada (contiene
  `original.xml`), la re-explota in place desde ese `original.xml` (útil
  para regenerar la vista legible sin volver a importar desde Mirth).
- `./canal.sh reconstruir <carpeta-canal> [xml-salida]` — reconstruye el
  XML desde la carpeta-proyecto y lo verifica contra `original.xml`
  (byte-a-byte o funcional según corresponda). Equivale a
  `./build-canal.sh`. No exporta nada a Mirth.
- `./canal.sh --help` — muestra la ayuda embebida en la cabecera del
  script.

```bash
./canal.sh deconstruir canales/NombreDelGrupo_DEV/01_-_NombreCanal_IN_-_DEV.xml
./canal.sh deconstruir canales/NombreDelGrupo_DEV/01_-_NombreCanal_IN_-_DEV
./canal.sh reconstruir canales/NombreDelGrupo_DEV/01_-_NombreCanal_IN_-_DEV
./canal.sh --help
```

Códigos de retorno (heredados del script delegado, se propagan tal cual):
`0` OK, `1` uso incorrecto (falta subcomando, argumentos, o subcomando
desconocido), `2` origen inválido (XML/carpeta-canal no existe o no tiene
el formato esperado), `3` falta `python3` o `PyYAML`, `4` (solo
`reconstruir`) el XML reconstruido no es bien formado o hay discrepancia
estructural real, `20` error inesperado.

### `explode-canal.sh <canal.xml> [carpeta-destino]`

**No requiere sesión ni red** — opera 100% local sobre un XML ya
importado (por `import-canal.sh` o `import-grupo.sh`). "Explota" el XML
plano de un canal a una **carpeta-proyecto** legible y editable (ver
sección "Canal como proyecto" más abajo). Si no se indica
`carpeta-destino`, se crea junto al XML de origen reemplazando el sufijo
`.xml` por una carpeta homónima.

```bash
./explode-canal.sh canales/NombreDelGrupo_DEV/01_-_NombreCanal_IN_-_DEV.xml
# equivalente explícito:
./explode-canal.sh canales/<grupo>/<canal>.xml canales/<grupo>/<canal>
```

Requiere `python3` con el módulo `PyYAML` instalado (`pip install pyyaml`).

Códigos de retorno: `0` OK, `1` uso incorrecto, `2` el XML de origen no
existe/no es legible, `3` falta `python3` o `PyYAML`, `20` error inesperado
durante el explode.

### `build-canal.sh <carpeta-canal> [xml-salida]`

**No requiere sesión ni red.** Reconstruye el XML de un canal desde la
carpeta-proyecto generada por `explode-canal.sh`, lo guarda por defecto en
`<carpeta-canal>/canal.xml` y lo **verifica** contra `original.xml` (ver
"Modelo de verificación" más abajo). Este script solo construye y verifica
en local — para subir el resultado al servidor hay que encadenar
`export-canal.sh` sobre el XML generado.

```bash
./build-canal.sh canales/NombreDelGrupo_DEV/01_-_NombreCanal_IN_-_DEV
./export-canal.sh canales/NombreDelGrupo_DEV/01_-_NombreCanal_IN_-_DEV/canal.xml
```

Códigos de retorno: `0` build OK y verificación OK (byte-exacta o
funcional según corresponda), `1` uso incorrecto, `2` la carpeta-canal no
existe o no tiene `original.xml`/`.manifest.json` (no fue generada por
`explode-canal.sh`), `3` falta `python3` o `PyYAML`, `4` el XML
reconstruido no es bien formado o la verificación funcional detectó una
discrepancia estructural real, `20` error inesperado durante el build.

### Sesión expirada durante una operación (HTTP 401)

Si la sesión existía pero el servidor la invalidó (timeout, reinicio de
Mirth, etc.), `test-conexion.sh`, `import-canal.sh` y `export-canal.sh`
detectan el HTTP 401 en su operación principal y terminan con el código
`13` y el mensaje:

```
[ERROR] Sesión expirada o inválida (HTTP 401). Ejecuta ./login.sh para renovar la sesión.
```

Este chequeo es distinto del que hace `mirth_has_session` (usado
internamente antes de operar): ese es un probe silencioso que trata el 401
como señal normal de "todavía no hay sesión", sin imprimir error.

## Canal como proyecto (explode / editar / build / import)

Un XML de canal importado es un único bloque monolítico dificil de leer
y de diffear en revisiones de código (SQL, JS y scripts embebidos como
texto escapado dentro de tags XML). El flujo "canal como proyecto"
convierte ese XML en una carpeta con archivos legibles por separado, para
poder editar el SQL/JS/mapper con su sintaxis propia y revisar diffs
claros, sin perder la capacidad de reproducir el XML original.

### Ciclo de trabajo end-to-end

El punto de entrada recomendado para los pasos de explode/build es
`canal.sh` (`deconstruir`/`reconstruir`); se muestra aquí junto a su
equivalente standalone (`explode-canal.sh`/`build-canal.sh`), que sigue
funcionando igual para quien ya lo tenga en scripts o costumbre:

```bash
./login.sh
./import-grupo.sh "NombreDelGrupo (DEV)"
# -> canales/NombreDelGrupo_DEV/01_-_NombreCanal_IN_-_DEV.xml (y otros canales + _grupo.xml)

./canal.sh deconstruir canales/NombreDelGrupo_DEV/01_-_NombreCanal_IN_-_DEV.xml
# equivalente standalone: ./explode-canal.sh canales/NombreDelGrupo_DEV/01_-_NombreCanal_IN_-_DEV.xml
# -> canales/NombreDelGrupo_DEV/01_-_NombreCanal_IN_-_DEV/
#      original.xml  channel.yml  mapper.json  scripts/  source/  destination_1/  .manifest.json

# editar lo que corresponda:
#   channel.yml               metadata del canal; referencia (deploy_file/undeploy_file/
#                              preprocessing_file/postprocessing_file) a los scripts en scripts/
#   scripts/*.js               scripts deploy/undeploy/preprocessing/postprocessing extraidos
#                              (solo se crean los que tienen contenido)
#   mapper.json                mapper steps del transformer del source (si aplica)
#   source/config.yml           configuracion del source (poller, etc.)
#   source/select_query.sql     SQL del source (si aplica)
#   destination_N/config.yml    configuracion del destino N
#   destination_N/query.js      JS del destino N (si aplica)

./canal.sh reconstruir canales/NombreDelGrupo_DEV/01_-_NombreCanal_IN_-_DEV
# equivalente standalone: ./build-canal.sh canales/NombreDelGrupo_DEV/01_-_NombreCanal_IN_-_DEV
# -> .../canal.xml  (reconstruido + verificado local, ver seccion siguiente)

./export-canal.sh canales/NombreDelGrupo_DEV/01_-_NombreCanal_IN_-_DEV/canal.xml --deploy
./logout.sh
```

También se puede explotar un canal importado individualmente con
`import-canal.sh` en vez de un grupo completo; el resto del flujo es
idéntico.

### Estructura de la carpeta-proyecto de un canal

```
canales/<grupo>/<canal>/
├── original.xml          # XML tal cual vino de Mirth, INTACTO (referencia, se versiona)
├── channel.yml            # metadata; referencia via deploy_file/undeploy_file/
│                          # preprocessing_file/postprocessing_file a scripts/*.js (se versiona)
├── scripts/                # scripts a nivel canal extraidos como archivos .js (se versiona)
│   ├── deploy.js             # (solo se crea si el canal tiene deploy script con contenido)
│   ├── undeploy.js            # (idem, undeploy)
│   ├── preprocessing.js        # (idem, preprocessor)
│   └── postprocessing.js       # (idem, postprocessor)
├── mapper.json             # mapper steps del transformer del source, si aplica (se versiona)
├── source/
│   ├── config.yml           # configuracion del source (se versiona)
│   └── select_query.sql       # (u otros .sql/.js segun el canal) (se versiona)
├── destination_1/
│   ├── config.yml
│   └── query.js               # (o script.txt/mapper.json segun el destino) (se versiona)
├── .manifest.json         # (interno, uso de build-canal.sh) mapa de regiones — SE VERSIONA
└── canal.xml               # XML reconstruido por build-canal.sh — artefacto de BUILD, ignorado (.gitignore)
```

Qué se versiona y qué no: todo lo legible (`original.xml`, `channel.yml`,
`mapper.json`, `scripts/*.js`, `source/*`, `destination_N/*`,
`.manifest.json`) se versiona en git — son la fuente editable y la
referencia de fidelidad. Solo `canal.xml` (el resultado de
`build-canal.sh`) se ignora vía `.gitignore`: es un artefacto derivado,
regenerable en cualquier momento a partir del proyecto, igual que un
`dist/` de build.

### Modelo de verificación ("diff-and-splice")

`build-canal.sh` (a través de `lib/canal_proyecto.py`) no reserializa el
XML completo desde cero. En cambio:

- `original.xml` es la única fuente de verdad byte-a-byte; nunca se
  reparsea/reescribe el documento entero.
- Para cada región editable (bloques de texto grande — SQL/JS/scripts — y
  sub-árboles de configuración), el build recalcula sobre `original.xml`
  el valor "de referencia" que un explode produciría hoy, y lo compara
  contra lo que hay actualmente en los archivos legibles del proyecto:
  - si son **iguales** → esa región del texto original se deja intacta,
    sin tocar ni un byte.
  - si son **distintas** (el usuario editó algo) → se regenera solo esa
    región y se "empalma" (splice) en el texto original, en el mismo
    lugar.

Consecuencia práctica: un `explode` + `build` **sin ediciones** reproduce
`original.xml` byte a byte siempre — esto es lo que `build-canal.sh`
reporta como "auto-test byte-a-byte" y es una verificación de que la
maquinaria de explode/build funciona correctamente, **no** un requisito
que el usuario deba cumplir al editar. Cuando sí se edita algo, las
regiones no tocadas siguen siendo byte-exactas y las regiones editadas se
verifican por **equivalencia funcional** (árboles XML normalizados vía
`xml.etree.ElementTree.canonicalize`), reportando si hubo o no diferencias
estructurales reales además de las esperadas por la edición. Cualquier
aspecto del canal que el modelo de regiones no reconoce explícitamente
(por ejemplo, semántica interna de `updateMode` u otros campos no
mapeados a una región propia) se preserva opaco dentro del XML original,
sin que el toolkit interprete ni valide su contenido.

## Estructura

```
mirthConnect/
├── .env.example        # plantilla de configuración (sin credenciales)
├── .gitignore
├── README.md
├── lib/
│   ├── mirth-api.sh       # funciones comunes: mirth_curl, mirth_login, mirth_logout,
│   │                      # mirth_has_session, mirth_require_session, mirth_sanitize_name...
│   └── canal_proyecto.py  # motor explode/build/verify del modelo "canal como proyecto"
├── canales/             # <grupo>/<canal>.xml planos + <grupo>/<canal>/ carpetas-proyecto (versionable en git,
│                        # salvo canal.xml dentro de cada carpeta-proyecto, ver .gitignore)
├── .mirth-session       # (generado por login.sh, ignorado por git)
├── login.sh
├── logout.sh
├── test-conexion.sh
├── import-canal.sh
├── import-grupo.sh
├── canal.sh             # interfaz unificada recomendada: deconstruir/reconstruir (wrapper de explode/build)
├── explode-canal.sh
├── build-canal.sh
└── export-canal.sh
```

## Detalles de la API usados

- Header obligatorio en toda request: `X-Requested-With` (sin él, HTTP 400).
- Login: `POST /api/users/_login` (form-urlencoded: `username`, `password`),
  la sesión se mantiene con cookie `JSESSIONID` (cookie jar de curl).
- Sanity check sin auth: `GET /api/server/version` con `Accept: text/plain`.
- Listado de canales: `GET /api/channels` (requiere auth).
- Resolución de nombre a id: `GET /api/channels/idsAndNames`.
- Canal individual: `GET/PUT /api/channels/{id}` (XML nativo de Mirth).
- Deploy: `POST /api/channels/{id}/_deploy`.
- Grupos de canales: `GET /api/channelgroups` (listado completo, XML;
  usado por `import-grupo.sh` para resolver por id o nombre y para
  extraer las membresías/orden de canales de cada grupo).

## Tabla resumen de scripts

| Script | Propósito | Requiere sesión | Requiere red/Mirth | Códigos de salida principales |
|---|---|---|---|---|
| `login.sh` | Autentica y persiste la sesión | crea la sesión | sí | `0`, `11`, `20` |
| `logout.sh` | Invalida la sesión en el servidor y borra el cookie jar | sí (la cierra) | sí | — |
| `test-conexion.sh` | Verifica alcance del servidor + autenticación | sí | sí | `0`, `10`, `11`, `13`, `20` |
| `import-canal.sh` | Importa (descarga) un canal individual a XML plano | sí | sí | `0`, `1`, `10`, `11`, `12`, `13`, `20` |
| `import-grupo.sh` | Importa un grupo completo (canales + metadata del grupo) | sí | sí | `0`, `1`, `10`, `11`, `12`, `13`, `20` |
| `canal.sh` | Interfaz unificada recomendada (`deconstruir`/`reconstruir`), wrapper de `explode-canal.sh`/`build-canal.sh` | no | no | `0`, `1`, `2`, `3`, `4`, `20` |
| `explode-canal.sh` | XML plano → carpeta-proyecto legible (equivalente standalone de `canal.sh deconstruir`) | no | no | `0`, `1`, `2`, `3`, `20` |
| `build-canal.sh` | Carpeta-proyecto → XML reconstruido + verificado (equivalente standalone de `canal.sh reconstruir`) | no | no | `0`, `1`, `2`, `3`, `4`, `20` |
| `export-canal.sh` | Sube (crea/actualiza) un XML de canal a Mirth, con `--deploy` opcional | sí | sí | `0`, `1`, `10`, `11`, `13`, `20` |

## Seguridad

- El cookie jar de sesión es un archivo persistente (`.mirth-session` por
  defecto) con permisos `600`, creado/renovado únicamente por `login.sh` y
  borrado únicamente por `logout.sh`. Los demás scripts solo lo leen.
- `.env` real y el archivo de sesión están excluidos vía `.gitignore`.
- El certificado del servidor es autofirmado; los scripts usan `-k` en
  curl (controlable con `MIRTH_INSECURE_TLS` en `.env`).
# MirthProject
