#!/usr/bin/env python3
"""
canal_proyecto.py — motor explode/build/verify para el modelo "canal como proyecto".

Estrategia de fidelidad ("diff-and-splice"):

  - `original.xml` es la ÚNICA fuente de verdad byte-a-byte. Nunca se
    reparsea/reserializa el documento completo.
  - Al explode(): se identifican "regiones" (bloques de texto grande —
    SQL/JS/scripts — y sub-árboles de configuración) y se extraen a
    archivos legibles (.sql, .js, mapper.json, config.yml, channel.yml).
  - Al build(): se recalculan, sobre `original.xml`, los valores "de
    referencia" que el explode habría producido HOY. Se comparan contra
    lo que hay actualmente en los archivos legibles del proyecto:
      * si son IGUALES -> esa región del texto original se deja intacta
        (no se toca ni un byte).
      * si son DISTINTAS -> se regenera SOLO esa región (con un
        serializador propio) y se empalma ("splice") en el texto
        original, en el mismo lugar.

  Consecuencia directa: un explode()+build() SIN ediciones reproduce
  `original.xml` byte a byte SIEMPRE, sin importar la complejidad del
  canal (no depende de que nuestro serializador imite perfectamente las
  reglas de escritura de XStream/Mirth para self-closing tags, orden de
  atributos, etc. — esas reglas solo importan para el texto que el
  usuario decidió editar).

  ElementTree ya decodifica entidades XML al parsear (&apos; -> ' etc.),
  así que todo el texto que se escribe a disco (sql/js/yaml/json) está en
  texto plano legible. Solo se re-escapa al regenerar una región editada.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

import yaml

# ---------------------------------------------------------------------------
# Utilidades de escape (reproducen el escapado agresivo de XStream/Mirth:
# &, <, >, ' y " se escapan siempre en el texto de los nodos, en ese orden).
# ---------------------------------------------------------------------------

def xml_escape_text(s: str) -> str:
    if s is None:
        return s
    s = s.replace("&", "&amp;")
    s = s.replace("<", "&lt;")
    s = s.replace(">", "&gt;")
    s = s.replace("'", "&apos;")
    s = s.replace('"', "&quot;")
    return s


# ---------------------------------------------------------------------------
# Localización de spans en el texto crudo original, por (tag, ocurrencia).
# La ocurrencia se calcula siempre sobre el ÁRBOL del `original.xml`
# (root.iter(tag)), nunca sobre el árbol construido, así que es estable.
# ---------------------------------------------------------------------------

def _tag_pattern(tag: str) -> re.Pattern:
    t = re.escape(tag)
    # Grupo 1 = contenido interno si viene en forma abierta/cerrada.
    # Forma autocerrada (<tag/>) también se reconoce (grupo 1 = None).
    return re.compile(r"<" + t + r"(?:\s[^>]*)?(?:/>|>(.*?)</" + t + r">)", re.DOTALL)


def occurrence_index(root: ET.Element, elem: ET.Element) -> int:
    """Índice (0-based) de `elem` entre todos los elementos con su mismo tag,
    en orden de documento, dentro de `root`."""
    siblings_same_tag = list(root.iter(elem.tag))
    for i, e in enumerate(siblings_same_tag):
        if e is elem:
            return i
    raise ValueError(f"elemento {elem.tag!r} no encontrado bajo root al calcular ocurrencia")


def find_span(raw_text: str, tag: str, index: int):
    """Devuelve (match, inner_start, inner_end) del bloque interno de la
    ocurrencia `index` de `tag` en `raw_text`. Si el tag está autocerrado,
    inner_start==inner_end==posición justo antes de '/>'."""
    matches = list(_tag_pattern(tag).finditer(raw_text))
    if index >= len(matches):
        raise ValueError(f"no se encontraron {index + 1} ocurrencias de <{tag}> en el XML")
    m = matches[index]
    if m.group(1) is None:
        # Autocerrado: no hay contenido interno.
        pos = m.end() - 2  # justo antes de "/>"
        return m, pos, pos
    return m, m.start(1), m.end(1)


# ---------------------------------------------------------------------------
# Conversión genérica ET <-> dict (para sub-árboles de configuración que no
# son texto grande). Representación:
#   {"@attrs": {...}}                      si tiene atributos
#   {"@children": [[tag, obj], [tag, obj]]} si tiene hijos (preserva orden
#                                            y tags repetidos)
#   {"@text": <str|None>}                   si es hoja
# ---------------------------------------------------------------------------

def elem_to_obj(e: ET.Element) -> dict:
    obj = {}
    if e.attrib:
        obj["@attrs"] = dict(e.attrib)
    children = list(e)
    if children:
        obj["@children"] = [[c.tag, elem_to_obj(c)] for c in children]
    else:
        obj["@text"] = e.text
    return obj


def obj_to_fragment(tag: str, obj: dict, indent: int) -> str:
    """Serializa `obj` (formato elem_to_obj) de vuelta a XML, con
    indentación de 2 espacios por nivel a partir de `indent`."""
    pad = " " * indent
    attrs = obj.get("@attrs", {})
    attrs_str = "".join(f' {k}="{v}"' for k, v in attrs.items())
    if "@children" in obj:
        children = obj["@children"]
        if not children:
            return f"{pad}<{tag}{attrs_str}/>"
        lines = [f"{pad}<{tag}{attrs_str}>"]
        for ctag, cobj in children:
            lines.append(obj_to_fragment(ctag, cobj, indent + 2))
        lines.append(f"{pad}</{tag}>")
        return "\n".join(lines)
    else:
        text = obj.get("@text")
        if text is None:
            return f"{pad}<{tag}{attrs_str}/>"
        if text == "":
            return f"{pad}<{tag}{attrs_str}></{tag}>"
        return f"{pad}<{tag}{attrs_str}>{xml_escape_text(text)}</{tag}>"


# ---------------------------------------------------------------------------
# Detección de "textos grandes" a extraer a archivo aparte dentro de una
# propiedad de conector (heurística documentada en README/decisiones):
#   - hijo DIRECTO de <properties>, sin sub-hijos (hoja)
#   - texto no vacío, y (len > 150 o contiene salto de línea)
# Nombre de archivo según el tag y, si existe, el flag <useScript>.
# ---------------------------------------------------------------------------

_SQL_TAGS = {"select", "update"}
_SCRIPTABLE_TAGS = {"query", "script", "template", "batchScript"}


def _big_text_filename(tag: str, use_script: bool) -> str:
    if tag in _SQL_TAGS:
        return f"{tag}_query.sql"
    if tag in _SCRIPTABLE_TAGS:
        ext = "js" if use_script else "sql" if tag == "query" else "txt"
        return f"{tag}.{ext}"
    return f"{tag}.txt"


def extract_big_texts(properties_elem: ET.Element):
    """Devuelve lista de (tag, elem, filename, texto) para los hijos
    directos de `properties_elem` que califican como texto grande."""
    use_script_elem = properties_elem.find("useScript")
    use_script = (use_script_elem is not None and use_script_elem.text == "true")
    out = []
    for child in list(properties_elem):
        if len(child) > 0:
            continue
        text = child.text or ""
        if text and (len(text) > 150 or "\n" in text):
            out.append((child.tag, child, _big_text_filename(child.tag, use_script), text))
    return out


# ---------------------------------------------------------------------------
# MapperStep <-> dict, usado para mapper.json (source/transformer/elements)
# ---------------------------------------------------------------------------

MAPPER_STEP_TAG = "com.mirth.connect.plugins.mapper.MapperStep"
_MAPPER_FIELDS = ["name", "sequenceNumber", "enabled", "variable", "mapping",
                  "defaultValue", "replacements", "scope"]


def is_pure_mapper_elements(elements_elem: ET.Element) -> bool:
    children = list(elements_elem)
    return len(children) > 0 and all(c.tag == MAPPER_STEP_TAG for c in children)


def mapper_step_to_dict(step_elem: ET.Element) -> dict:
    d = {}
    for f in _MAPPER_FIELDS:
        child = step_elem.find(f)
        if child is None:
            continue
        if f == "replacements":
            d[f] = [] if len(child) == 0 else [elem_to_obj(c) for c in child]
        elif f == "sequenceNumber":
            d[f] = int(child.text) if child.text is not None else None
        elif f == "enabled":
            d[f] = (child.text == "true")
        else:
            d[f] = child.text if child.text is not None else ""
    return d


def mapper_elements_to_list(elements_elem: ET.Element) -> list:
    return [mapper_step_to_dict(c) for c in elements_elem]


def mapper_list_to_fragment(steps: list, indent: int) -> str:
    pad = " " * indent
    ipad = " " * (indent + 2)
    lines = [f"{pad}<elements>"]
    for step in steps:
        lines.append(f"{ipad}<{MAPPER_STEP_TAG} version=\"4.5.2\">")
        for f in _MAPPER_FIELDS:
            if f not in step:
                continue
            val = step[f]
            fpad = " " * (indent + 4)
            if f == "replacements":
                if not val:
                    lines.append(f"{fpad}<replacements/>")
                else:
                    lines.append(f"{fpad}<replacements>")
                    for r in val:
                        lines.append(obj_to_fragment("string", r, indent + 6))
                    lines.append(f"{fpad}</replacements>")
            elif f == "enabled":
                lines.append(f"{fpad}<enabled>{'true' if val else 'false'}</enabled>")
            elif f == "sequenceNumber":
                lines.append(f"{fpad}<sequenceNumber>{val}</sequenceNumber>")
            elif f == "defaultValue":
                if val:
                    lines.append(f"{fpad}<defaultValue>{xml_escape_text(val)}</defaultValue>")
                else:
                    lines.append(f"{fpad}<defaultValue></defaultValue>")
            else:
                lines.append(f"{fpad}<{f}>{xml_escape_text(val)}</{f}>")
        lines.append(f"{ipad}</{MAPPER_STEP_TAG}>")
    lines.append(f"{pad}</elements>")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Modelo de regiones: cada región sabe cómo (a) calcular su valor de
# referencia desde un ET.Element dado, (b) leer/escribir su archivo legible,
# (c) regenerar su fragmento XML si cambió.
# ---------------------------------------------------------------------------

class Region:
    def __init__(self, tag, index, kind, relpath, indent):
        self.tag = tag
        self.index = index
        self.kind = kind        # 'text' | 'mapper' | 'dict' | 'raw'
        self.relpath = relpath  # ruta relativa al proyecto, o None (inline en channel.yml)
        self.indent = indent

    def ref_value(self, elem: ET.Element):
        if self.kind == "text":
            return elem.text or ""
        if self.kind == "mapper":
            return mapper_elements_to_list(elem)
        if self.kind == "dict":
            return elem_to_obj(elem)
        if self.kind == "raw":
            # Se guarda el propio fragmento crudo (sin reinterpretar) como
            # texto, para los casos no soportados estructuralmente.
            return ET.tostring(elem, encoding="unicode")
        raise ValueError(self.kind)

    def fragment(self, value):
        if self.kind == "text":
            text = value or ""
            if text == "":
                return f'{" " * self.indent}<{self.tag}></{self.tag}>'
            return f'{" " * self.indent}<{self.tag}>{xml_escape_text(text)}</{self.tag}>'
        if self.kind == "mapper":
            return mapper_list_to_fragment(value, self.indent)
        if self.kind == "dict":
            return obj_to_fragment(self.tag, value, self.indent)
        if self.kind == "raw":
            # No se editan a mano los raw fallback en esta iteración; si
            # cambia, se reinyecta tal cual el texto guardado.
            return value
        raise ValueError(self.kind)


def _indent_of(raw_text: str, pos: int) -> int:
    line_start = raw_text.rfind("\n", 0, pos) + 1
    return pos - line_start


# ---------------------------------------------------------------------------
# EXPLODE
# ---------------------------------------------------------------------------

def _connector_regions(root, raw, conn_props_elem, prefix):
    """Regiones de una `<properties>` de conector (source o destination):
    textos grandes (sql/js) + resto genérico como dict."""
    regions = {}
    big = extract_big_texts(conn_props_elem)
    big_tags = {tag for tag, *_ in big}
    for tag, elem, fname, text in big:
        idx = occurrence_index(root, elem)
        _, s, _e = find_span(raw, tag, idx)
        indent = _indent_of(raw, s)
        regions[f"{prefix}/{fname}"] = (Region(tag, idx, "text", f"{prefix}/{fname}", indent), elem)

    idx = occurrence_index(root, conn_props_elem)
    _, s, _e = find_span(raw, "properties", idx)
    indent = _indent_of(raw, s)
    # dict genérico, pero omitiendo los hijos ya extraídos como texto grande
    obj = elem_to_obj(conn_props_elem)
    if "@children" in obj:
        obj["@children"] = [[t, o] for t, o in obj["@children"] if t not in big_tags]
    regions[f"{prefix}/properties"] = (Region("properties", idx, "dict", f"{prefix}/config.yml", indent), conn_props_elem)
    return regions, obj


def _elements_region(root, raw, elements_elem, prefix, label):
    """elements de filter/transformer/responseTransformer: MapperStep -> json,
    resto -> raw fallback (solo si no está vacío)."""
    if elements_elem is None or len(elements_elem) == 0:
        return None
    idx = occurrence_index(root, elements_elem)
    _, s, _e = find_span(raw, "elements", idx)
    indent = _indent_of(raw, s)
    if is_pure_mapper_elements(elements_elem):
        return ("mapper", Region("elements", idx, "mapper", f"{prefix}/mapper.json", indent), elements_elem)
    return ("raw", Region("elements", idx, "raw", f"{prefix}/{label}_elements.xml", indent), elements_elem)


def explode(xml_path: str, out_dir: str):
    xml_path = Path(xml_path)
    raw = xml_path.read_text(encoding="utf-8")
    root = ET.fromstring(raw)
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    (out / "original.xml").write_text(raw, encoding="utf-8")

    manifest = {"regions": {}}  # relpath_key -> {tag, index, kind}

    def register(key, region):
        manifest["regions"][key] = {"tag": region.tag, "index": region.index,
                                     "kind": region.kind, "indent": region.indent,
                                     "relpath": region.relpath}

    channel = {
        "mirth_version": root.get("version"),
        "id": root.findtext("id"),
        "name": root.findtext("name"),
        "description": root.findtext("description") or "",
        "revision": root.findtext("revision"),
        "nextMetaDataId": root.findtext("nextMetaDataId"),
    }

    # Scripts a nivel canal (deploy/undeploy/pre/postprocessing): se extraen
    # a archivos .js dentro de scripts/ (igual que select_query.sql o
    # destination_N/query.js) y en channel.yml quedan como referencia
    # `<nombre>_file`. Solo se crea el archivo/referencia si el script
    # tiene contenido real; los bloques vacíos no generan archivo.
    SCRIPT_TAGS = [
        ("deployScript", "deploy"),
        ("undeployScript", "undeploy"),
        ("preprocessingScript", "preprocessing"),
        ("postprocessingScript", "postprocessing"),
    ]
    scripts_yml = {}
    for tag, short in SCRIPT_TAGS:
        elem = root.find(tag)
        idx = occurrence_index(root, elem)
        _, s, _e = find_span(raw, tag, idx)
        indent = _indent_of(raw, s)
        text = elem.text or ""
        if text.strip():
            relpath = f"scripts/{short}.js"
            (out / "scripts").mkdir(exist_ok=True)
            (out / relpath).write_text(text, encoding="utf-8")
            register(f"channel/{tag}", Region(tag, idx, "text", relpath, indent))
            scripts_yml[f"{short}_file"] = relpath
        else:
            register(f"channel/{tag}", Region(tag, idx, "text", None, indent))
    channel["scripts"] = scripts_yml

    props_elem = root.find("properties")
    idx = occurrence_index(root, props_elem)
    _, s, _e = find_span(raw, "properties", idx)
    indent = _indent_of(raw, s)
    register("channel/properties", Region("properties", idx, "dict", None, indent))
    channel["properties"] = elem_to_obj(props_elem)

    export_elem = root.find("exportData")
    if export_elem is not None:
        idx = occurrence_index(root, export_elem)
        _, s, _e = find_span(raw, "exportData", idx)
        indent = _indent_of(raw, s)
        register("channel/exportData", Region("exportData", idx, "dict", None, indent))
        channel["export_metadata"] = elem_to_obj(export_elem)

    (out / "channel.yml").write_text(
        yaml.safe_dump(channel, allow_unicode=True, sort_keys=False, width=100),
        encoding="utf-8")

    # ---- sourceConnector ----
    src = root.find("sourceConnector")
    src_dir = out / "source"
    src_dir.mkdir(exist_ok=True)
    src_cfg = {
        "metaDataId": src.findtext("metaDataId"),
        "name": src.findtext("name"),
        "transportName": src.findtext("transportName"),
        "mode": src.findtext("mode"),
        "enabled": src.findtext("enabled"),
        "waitForPrevious": src.findtext("waitForPrevious"),
    }
    props = src.find("properties")
    regions, props_obj = _connector_regions(root, raw, props, "source")
    for key, (region, elem) in regions.items():
        register(key, region)
        if region.kind == "text":
            (out / region.relpath).write_text(elem.text or "", encoding="utf-8")
    src_cfg["properties"] = props_obj

    transformer = src.find("transformer")
    if transformer is not None:
        src_cfg["transformer_meta"] = {
            "inboundDataType": transformer.findtext("inboundDataType"),
            "outboundDataType": transformer.findtext("outboundDataType"),
        }
        inb = transformer.find("inboundProperties")
        outb = transformer.find("outboundProperties")
        if inb is not None:
            idx = occurrence_index(root, inb)
            _, s, _e = find_span(raw, "inboundProperties", idx)
            register("source/transformer/inboundProperties",
                     Region("inboundProperties", idx, "dict", "source/config.yml", _indent_of(raw, s)))
            src_cfg["transformer_inboundProperties"] = elem_to_obj(inb)
        if outb is not None:
            idx = occurrence_index(root, outb)
            _, s, _e = find_span(raw, "outboundProperties", idx)
            register("source/transformer/outboundProperties",
                     Region("outboundProperties", idx, "dict", "source/config.yml", _indent_of(raw, s)))
            src_cfg["transformer_outboundProperties"] = elem_to_obj(outb)

        els = transformer.find("elements")
        res = _elements_region(root, raw, els, "source", "transformer")
        if res:
            kind, region, elem = res
            register("source/transformer/elements", region)
            if kind == "mapper":
                (out / "mapper.json").write_text(
                    json.dumps(mapper_elements_to_list(elem), ensure_ascii=False, indent=2),
                    encoding="utf-8")
            else:
                (out / region.relpath).write_text(ET.tostring(elem, encoding="unicode"), encoding="utf-8")

    filt = src.find("filter")
    if filt is not None:
        els = filt.find("elements")
        res = _elements_region(root, raw, els, "source", "filter")
        if res:
            kind, region, elem = res
            register("source/filter/elements", region)
            (out / region.relpath).write_text(ET.tostring(elem, encoding="unicode"), encoding="utf-8")

    (src_dir / "config.yml").write_text(
        yaml.safe_dump(src_cfg, allow_unicode=True, sort_keys=False, width=100),
        encoding="utf-8")

    # ---- destinationConnectors ----
    dests = root.find("destinationConnectors")
    for n, conn in enumerate(dests.findall("connector"), start=1):
        prefix = f"destination_{n}"
        ddir = out / prefix
        ddir.mkdir(exist_ok=True)
        dcfg = {
            "metaDataId": conn.findtext("metaDataId"),
            "name": conn.findtext("name"),
            "transportName": conn.findtext("transportName"),
            "mode": conn.findtext("mode"),
            "enabled": conn.findtext("enabled"),
            "waitForPrevious": conn.findtext("waitForPrevious"),
        }
        props = conn.find("properties")
        regions, props_obj = _connector_regions(root, raw, props, prefix)
        for key, (region, elem) in regions.items():
            register(key, region)
            if region.kind == "text":
                (out / region.relpath).write_text(elem.text or "", encoding="utf-8")
        dcfg["properties"] = props_obj

        for section in ["transformer", "responseTransformer"]:
            sec = conn.find(section)
            if sec is None:
                continue
            dcfg[f"{section}_meta"] = {
                "inboundDataType": sec.findtext("inboundDataType"),
                "outboundDataType": sec.findtext("outboundDataType"),
            }
            els = sec.find("elements")
            res = _elements_region(root, raw, els, prefix, section)
            if res:
                kind, region, elem = res
                register(f"{prefix}/{section}/elements", region)
                if kind == "mapper":
                    (ddir / "mapper.json").write_text(
                        json.dumps(mapper_elements_to_list(elem), ensure_ascii=False, indent=2),
                        encoding="utf-8")
                else:
                    (out / region.relpath).write_text(ET.tostring(elem, encoding="unicode"), encoding="utf-8")

        filt = conn.find("filter")
        if filt is not None:
            els = filt.find("elements")
            res = _elements_region(root, raw, els, prefix, "filter")
            if res:
                kind, region, elem = res
                register(f"{prefix}/filter/elements", region)
                (out / region.relpath).write_text(ET.tostring(elem, encoding="unicode"), encoding="utf-8")

        (ddir / "config.yml").write_text(
            yaml.safe_dump(dcfg, allow_unicode=True, sort_keys=False, width=100),
            encoding="utf-8")

    (out / ".manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return manifest


# ---------------------------------------------------------------------------
# BUILD
# ---------------------------------------------------------------------------

def _read_current(out: Path, region: Region):
    if region.relpath is None:
        return None  # se resuelve desde channel.yml por el caller
    p = out / region.relpath
    if region.kind == "text":
        return p.read_text(encoding="utf-8") if p.exists() else ""
    if region.kind == "mapper":
        mp = out / "mapper.json" if region.relpath.endswith("mapper.json") else p
        return json.loads(mp.read_text(encoding="utf-8"))
    if region.kind == "dict":
        cfgp = out / region.relpath
        return yaml.safe_load(cfgp.read_text(encoding="utf-8"))
    if region.kind == "raw":
        return p.read_text(encoding="utf-8") if p.exists() else None
    raise ValueError(region.kind)


def build(project_dir: str):
    proj = Path(project_dir)
    orig_path = proj / "original.xml"
    raw = orig_path.read_text(encoding="utf-8")
    root = ET.fromstring(raw)
    manifest = json.loads((proj / ".manifest.json").read_text(encoding="utf-8"))

    channel_yml = yaml.safe_load((proj / "channel.yml").read_text(encoding="utf-8"))
    src_cfg = yaml.safe_load((proj / "source/config.yml").read_text(encoding="utf-8"))
    dest_cfgs = {}
    for d in sorted(proj.glob("destination_*/config.yml")):
        dest_cfgs[d.parent.name] = yaml.safe_load(d.read_text(encoding="utf-8"))

    splices = []   # (start, end, replacement_text)
    report = {"unchanged": [], "regenerated": []}

    def process(key, tag, index, kind, indent, ref_value, cur_value, relpath):
        _, s, e = find_span(raw, tag, index)
        if ref_value == cur_value:
            report["unchanged"].append(key)
            return
        region = Region(tag, index, kind, relpath, indent)
        frag_full = region.fragment(cur_value)
        # frag_full incluye indentación + <tag>...; el splice reemplaza
        # solo el contenido INTERNO (entre las posiciones s,e), así que
        # se recorta la apertura/cierre generados por fragment() para
        # dejar solo lo interno cuando kind == 'text'.
        if kind == "text":
            inner = xml_escape_text(cur_value or "")
            splices.append((s, e, inner))
        elif kind == "mapper":
            inner_frag = mapper_list_to_fragment(cur_value, indent)
            # mapper_list_to_fragment ya incluye <elements>...</elements>;
            # hay que reemplazar el elemento completo <elements> (s,e
            # apunta al contenido interno de <elements>, así que envolvemos
            # extrayendo solo el interior de inner_frag).
            inner_only = inner_frag[inner_frag.index(">") + 1: inner_frag.rindex("<")]
            splices.append((s, e, inner_only))
        elif kind == "dict":
            inner_frag = obj_to_fragment(tag, cur_value, indent)
            inner_only = inner_frag[inner_frag.index(">") + 1: inner_frag.rindex("<")] if "@children" in cur_value or cur_value.get("@text") is not None else ""
            splices.append((s, e, inner_only))
        else:
            splices.append((s, e, cur_value or ""))
        report["regenerated"].append(key)

    for key, m in manifest["regions"].items():
        tag, index, kind, indent, relpath = m["tag"], m["index"], m["kind"], m["indent"], m["relpath"]
        if key.startswith("channel/") and kind == "text":
            scr_tag = key.split("/", 1)[1]
            elem = root.find(scr_tag)
            ref = elem.text or ""
            if relpath:
                p = proj / relpath
                cur = p.read_text(encoding="utf-8") if p.exists() else ""
            else:
                # No hubo archivo en el explode (script vacío en el original);
                # el valor actual es "" salvo que no exista referencia alguna.
                cur = ""
            process(key, tag, index, kind, indent, ref, cur, relpath)
        elif key == "channel/properties":
            elem = root.find("properties")
            ref = elem_to_obj(elem)
            cur = channel_yml.get("properties")
            process(key, tag, index, kind, indent, ref, cur, relpath)
        elif key == "channel/exportData":
            elem = root.find("exportData")
            ref = elem_to_obj(elem)
            cur = channel_yml.get("export_metadata")
            process(key, tag, index, kind, indent, ref, cur, relpath)
        elif key.startswith("source/"):
            _resolve_connector_region(root, key, m, src_cfg, process)
        elif key.startswith("destination_"):
            dprefix = key.split("/", 1)[0]
            _resolve_connector_region(root, key, m, dest_cfgs[dprefix], process)

    # aplicar splices en orden descendente de posición
    text = raw
    for s, e, repl in sorted(splices, key=lambda x: -x[0]):
        text = text[:s] + repl + text[e:]

    return text, report


def _resolve_connector_region(root, key, m, cfg, process):
    tag, index, kind, indent, relpath = m["tag"], m["index"], m["kind"], m["indent"], m["relpath"]
    parts = key.split("/")
    prefix = parts[0]
    conn = _find_connector(root, prefix)
    if kind == "text":
        elem = list(root.iter(tag))[index]
        ref = elem.text or ""
        fname = relpath.rsplit("/", 1)[-1]
        # el nombre de campo dentro de config.yml no se guarda aparte;
        # se guardó como archivo, así que cur se lee directo del archivo
        # (ya resuelto por el caller vía filesystem en build()).
        cur = _current_text_file(relpath)
        process(key, tag, index, kind, indent, ref, cur, relpath)
    elif kind == "mapper":
        elem = list(root.iter(tag))[index]
        ref = mapper_elements_to_list(elem)
        cur = _current_mapper_file(relpath, prefix)
        process(key, tag, index, kind, indent, ref, cur, relpath)
    elif kind == "dict":
        elem = list(root.iter(tag))[index]
        ref = elem_to_obj(elem)
        if "properties" in key and key.endswith("properties") and parts[-1] == "properties" and len(parts) == 2:
            # region properties -> se compara contra cfg['properties'] pero
            # sin los hijos ya extraídos a archivo grande (mismo criterio
            # que en explode: se filtran los mismos tags grandes)
            big = extract_big_texts(conn.find("properties")) if tag == "properties" else []
            big_tags = {t for t, *_ in big}
            if "@children" in ref:
                ref["@children"] = [[t, o] for t, o in ref["@children"] if t not in big_tags]
            cur = cfg.get("properties")
        elif tag == "inboundProperties":
            cur = cfg.get("transformer_inboundProperties")
        elif tag == "outboundProperties":
            cur = cfg.get("transformer_outboundProperties")
        else:
            cur = None
        process(key, tag, index, kind, indent, ref, cur, relpath)
    elif kind == "raw":
        cur = _current_text_file(relpath)
        ref = ET.tostring(list(root.iter(tag))[index], encoding="unicode")
        process(key, tag, index, kind, indent, ref, cur, relpath)


def _find_connector(root, prefix):
    if prefix == "source":
        return root.find("sourceConnector")
    n = int(prefix.split("_")[1])
    return root.find("destinationConnectors").findall("connector")[n - 1]


def _current_text_file(relpath):
    from pathlib import Path as _P
    p = _P(_CURRENT_PROJECT_DIR) / relpath
    return p.read_text(encoding="utf-8") if p.exists() else ""


def _current_mapper_file(relpath, prefix):
    from pathlib import Path as _P
    base = _P(_CURRENT_PROJECT_DIR)
    if prefix == "source":
        mp = base / "mapper.json"
    else:
        mp = base / prefix / "mapper.json"
    if not mp.exists():
        mp = base / relpath
    return json.loads(mp.read_text(encoding="utf-8"))


_CURRENT_PROJECT_DIR = "."


def build_project(project_dir: str):
    global _CURRENT_PROJECT_DIR
    _CURRENT_PROJECT_DIR = project_dir
    return build(project_dir)


# ---------------------------------------------------------------------------
# VERIFY
# ---------------------------------------------------------------------------

def verify(original_text: str, built_text: str):
    result = {"byte_exact": original_text == built_text, "well_formed": False,
              "functional_equal": False, "error": None}
    try:
        ET.fromstring(built_text)
        result["well_formed"] = True
    except ET.ParseError as ex:
        result["error"] = str(ex)
        return result
    try:
        c1 = ET.canonicalize(original_text, strip_text=True)
        c2 = ET.canonicalize(built_text, strip_text=True)
        result["functional_equal"] = (c1 == c2)
    except Exception as ex:
        result["error"] = f"canonicalize: {ex}"
    return result


if __name__ == "__main__":
    print(__doc__)
