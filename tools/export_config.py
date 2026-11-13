"""Read the source XLSX without third-party dependencies; export validated Godot JSON.

Usage: python tools/export_config.py --prototype
       python tools/export_config.py --strict  (must reject current blank design values)
Prototype overrides fill only blank spreadsheet fields. They never replace a
populated spreadsheet value. Runtime-only defaults are explicitly prototype data.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import sys
import tempfile
import xml.etree.ElementTree as ET
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
REL = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"
ID_PATTERN = re.compile(r"^[a-z][a-z0-9_]*$")


def read_sheets(path: Path) -> dict[str, list[dict]]:
    with ZipFile(path) as z:
        strings = []
        if "xl/sharedStrings.xml" in z.namelist():
            for si in ET.fromstring(z.read("xl/sharedStrings.xml")).findall("m:si", NS):
                strings.append("".join(t.text or "" for t in si.iterfind(".//m:t", NS)))
        links = {r.attrib["Id"]: r.attrib["Target"] for r in ET.fromstring(z.read("xl/_rels/workbook.xml.rels"))}
        result = {}
        for sheet in ET.fromstring(z.read("xl/workbook.xml")).findall("m:sheets/m:sheet", NS):
            name = sheet.attrib["name"]
            if name == "产能预览":
                continue
            target = links[sheet.attrib[REL]]
            target = target.lstrip("/") if target.startswith("/") else "xl/" + target
            records, headers = [], {}
            for row in ET.fromstring(z.read(target)).findall("m:sheetData/m:row", NS):
                row_num = int(row.attrib["r"])
                if row_num == 2:
                    continue
                vals = {}
                for cell in row.findall("m:c", NS):
                    col = re.match(r"[A-Z]+", cell.attrib["r"]).group(0)
                    if cell.find("m:f", NS) is not None:
                        raise ValueError(f"{name}!{cell.attrib['r']}: source formulas are not allowed")
                    kind = cell.attrib.get("t")
                    raw = cell.find("m:v", NS)
                    if kind == "inlineStr":
                        value = "".join(t.text or "" for t in cell.iterfind(".//m:t", NS))
                    elif raw is None or raw.text is None:
                        value = None
                    elif kind == "s":
                        value = strings[int(raw.text)]
                    elif kind == "b":
                        value = raw.text == "1"
                    elif kind in ("str", "e"):
                        value = raw.text
                    else:
                        n = float(raw.text)
                        value = int(n) if n.is_integer() else n
                    vals[col] = value
                if row_num == 1:
                    headers = vals
                elif vals.get("A") is not None:
                    records.append({key: vals.get(col) for col, key in headers.items() if key})
            result[name] = records
        return result


def export(source: Path, override_path: Path, prototype: bool) -> dict:
    sheets = read_sheets(source)
    override = json.loads(override_path.read_text(encoding="utf-8")) if prototype else {}
    missing, provenance = [], {}
    config = {"schema_version": 1, "config_version": override.get("config_version", "0.3"),
              "mode": "prototype" if prototype else "strict", "globals": {}, "hire": {}, "jobs": {}, "inputs": {}}

    def value(row: dict, field: str, section: str, key: str, override_value=None):
        label = f"{section}.{key}.{field}"
        original = row.get(field)
        if original is None or original == "":
            if prototype and override_value is not None:
                provenance[label] = "prototype_overrides (原型建议)"
                return override_value
            missing.append(label)
            return None
        if not prototype and row.get("status") == "待定":
            missing.append(f"{label} (row remains pending)")
        provenance[label] = f"xlsx ({row.get('status', 'unknown')})"
        return original

    def unique(rows, field):
        ids = set()
        for row in rows:
            key = row.get(field)
            if not isinstance(key, str) or not ID_PATTERN.fullmatch(key) or key in ids:
                raise ValueError(f"Invalid or duplicate {field}: {key!r}")
            ids.add(key)

    for sheet, field in [("全局参数", "id"), ("雇佣岗位", "id"), ("实时作业", "id")]:
        if sheet not in sheets:
            raise ValueError(f"Required sheet missing: {sheet}")
        unique(sheets[sheet], field)
    for row in sheets["全局参数"]:
        key = row["id"]
        config["globals"][key] = value(row, "value", "globals", key, override.get("globals", {}).get(key))
    for row in sheets["雇佣岗位"]:
        key = row["id"]
        config["hire"][key] = {"name": row["name"], "building_id": row["building_id"]}
        for f in ("max_workers", "hire_cost"):
            config["hire"][key][f] = value(row, f, "hire", key, override.get("hire", {}).get(key, {}).get(f))
    for row in sheets["实时作业"]:
        key = row["id"]
        config["jobs"][key] = {f: row[f] for f in ("name", "team_id", "output_id")}
        for f in ("work_required", "rate_per_person_sec", "output_qty"):
            config["jobs"][key][f] = value(row, f, "jobs", key, override.get("jobs", {}).get(key, {}).get(f))
    seen_inputs = set()
    for row in sheets.get("配方消耗", []):
        job, item = row["job_id"], row["item_id"]
        if job not in config["jobs"] or not ID_PATTERN.fullmatch(item) or (job, item) in seen_inputs:
            raise ValueError(f"Invalid or duplicate recipe input: {job}/{item}")
        seen_inputs.add((job, item))
        config["inputs"].setdefault(job, {})[item] = value(row, "qty_per_batch", "inputs", f"{job}.{item}", override.get("inputs", {}).get(job, {}).get(item))
    if missing:
        raise ValueError("Unconfigured values:\n  " + "\n  ".join(missing))

    def numeric(n, label, positive=False, integer=False):
        if isinstance(n, bool) or not isinstance(n, (int, float)) or not math.isfinite(n) or (n <= 0 if positive else n < 0):
            raise ValueError(f"Invalid numeric value {label}: {n!r}")
        if integer and int(n) != n:
            raise ValueError(f"Integer required {label}: {n!r}")

    for key, val in config["globals"].items():
        integer = key.endswith("_cap") or key.endswith("_batch") or key in ("residents_initial", "soldiers_initial", "town_visual_actors", "evac_visual_groups")
        numeric(val, key, positive=not key.startswith("money") and key != "battle_money_grant", integer=integer)
    for key, val in config["hire"].items():
        numeric(val["max_workers"], key, True, True)
        numeric(val["hire_cost"], key, False, True)
    if set(config["hire"]) != {"engineer", "medical", "supply", "reserve"}:
        raise ValueError("Four known departments are required")
    for key, val in config["jobs"].items():
        if val["team_id"] not in {"unhired", "engineer", "medical", "supply"}:
            raise ValueError(f"Unknown team in {key}")
        for field in ("work_required", "rate_per_person_sec", "output_qty"):
            numeric(val[field], f"{key}.{field}", True, field == "output_qty")
    for job, ingredients in config["inputs"].items():
        for item, qty in ingredients.items():
            numeric(qty, f"{job}.{item}", True, True)
    g = config["globals"]
    if sum(v["max_workers"] for v in config["hire"].values()) > g["residents_initial"]:
        raise ValueError("Department capacity exceeds initial residents")
    if g["raid_enemy_cap"] > g["battle_enemy_cap"] or g["raid_ally_cap"] > g["battle_ally_cap"] or g["battle_ally_cap"] > g["soldier_roster_cap"]:
        raise ValueError("Phase/roster cap mismatch")
    if g["evac_rate_intact"] < g["evac_rate_damaged"] or not 0 < g["minor_defeat_ratio"] <= 1:
        raise ValueError("Invalid evacuation settings")
    if prototype:
        for key in ("initial_resources", "economy", "combat"):
            config[key] = override.get(key, {})
            provenance[key] = "prototype_overrides (原型建议)"
        economy = config["economy"]
        for key in ("initial_equipped", "warehouse_capacity", "neighbor_gift_amount"):
            numeric(economy.get(key), f"economy.{key}", key == "warehouse_capacity", True)
        if economy["initial_equipped"] > g["soldiers_initial"]:
            raise ValueError("Initial equipped count exceeds soldiers")
        for key, qty in config["initial_resources"].items():
            numeric(qty, f"initial_resources.{key}", integer=True)
            if qty > economy["warehouse_capacity"]:
                raise ValueError(f"Initial stock exceeds storage capacity: {key}")
        required_items = {"material", "herb_raw", "food_raw", "equipment", "medicine", "siege_engine", "rations"}
        if set(config["initial_resources"]) != required_items:
            raise ValueError("All seven initial resource quantities must be explicitly configured")
        if set(economy.get("initial_facilities", {})) != {"outer", "street", "evac"}:
            raise ValueError("All three initial facilities must be configured")
        for key, integrity in economy["initial_facilities"].items():
            numeric(integrity, f"initial_facilities.{key}")
            if integrity > 100:
                raise ValueError(f"Facility integrity exceeds 100: {key}")
        for key, qty in economy.get("neighbor_inventory", {}).items():
            numeric(qty, f"neighbor_inventory.{key}", integer=True)
        for key, val in config["combat"].items():
            numeric(val, f"combat.{key}")
        if not config["combat"]:
            raise ValueError("Prototype combat parameters must be explicitly configured")
    config["provenance"] = {"source": source.name, "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "fields": provenance}
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--prototype", action="store_true")
    mode.add_argument("--strict", action="store_true")
    parser.add_argument("--source", type=Path, default=ROOT / "outputs/fenghuo_v03/烽火连绵_数值配置_v0.3.xlsx")
    parser.add_argument("--overrides", type=Path, default=ROOT / "game/data/prototype_overrides.json")
    parser.add_argument("--output", type=Path, default=ROOT / "game/data/runtime_config.json")
    args = parser.parse_args()
    try:
        result = export(args.source, args.overrides, args.prototype)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=args.output.parent, suffix=".tmp", delete=False) as tmp:
            json.dump(result, tmp, ensure_ascii=False, indent=2, allow_nan=False)
            tmp.write("\n")
            temp_path = Path(tmp.name)
        temp_path.replace(args.output)
        print(f"Exported {args.output.name}: {len(result['globals'])} globals, {len(result['jobs'])} jobs, mode={result['mode']}")
        return 0
    except (OSError, ValueError, KeyError) as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
