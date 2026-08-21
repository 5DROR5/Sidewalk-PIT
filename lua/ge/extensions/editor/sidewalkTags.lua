# ============================================================================
# sidewalk_pit - procedural sidewalk and curb geometry for BeamNG.drive maps
# ============================================================================

import bpy
import bmesh
import sys
import traceback
import heapq
import json
import math
import hashlib
import os
import re
import struct
from mathutils import Vector


CLI_FLAGS = {
    "level":     ("LEVEL_NAME",         str,  "map folder name, e.g. derby"),
    "game-root": ("CLI_GAME_ROOT",      str,  "folder containing 'levels'"),
    "out":       ("CLI_EXPORT_FOLDER",  str,  "where to write the .dae"),
    "all-decals": ("CLI_ALL_DECALROAD", bool, "also process plain DecalRoad"),
}


def _script_args():
    argv = list(sys.argv)
    if "--" in argv:
        return argv[argv.index("--") + 1:]
    if argv and argv[0].lower().endswith(".py"):
        return argv[1:]
    stray = [t for t in argv
             if t.split("=", 1)[0].lstrip("-") in CLI_FLAGS and t.startswith("--")]
    if stray:
        print("sidewalk_pit: " + " ".join(stray) + " came after --python, so Blender "
              "took them instead of this script.\n"
              "              Put a bare -- between the .py path and the options:\n"
              "                blender --background --python sidewalk_pit.py -- "
              + " ".join(stray), file=sys.stderr)
        sys.exit(2)
    return []


def _cli_help():
    print("sidewalk_pit - BeamNG sidewalk generator\n")
    print("  blender --background --python sidewalk_pit.py -- [options]\n")
    for flag, (_name, kind, doc) in CLI_FLAGS.items():
        arg = "" if kind is bool else " VALUE"
        print(f"  --{flag}{arg}".ljust(26) + doc)
    print("  --help".ljust(26) + "show this and exit")


def _parse_cli():
    argv = _script_args()
    out, i = {}, 0
    while i < len(argv):
        tok = argv[i]
        i += 1
        if tok in ("-h", "--help"):
            _cli_help()
            sys.exit(0)
        if not tok.startswith("--"):
            continue
        key, val = tok[2:], None
        if "=" in key:
            key, val = key.split("=", 1)
        if key not in CLI_FLAGS:
            print(f"sidewalk_pit: unknown option '--{key}' "
                  f"(try --help)", file=sys.stderr)
            sys.exit(2)
        name, kind, _doc = CLI_FLAGS[key]
        if kind is bool:
            out[name] = True
            continue
        if val is None:
            if i >= len(argv) or argv[i].startswith("--"):
                print(f"sidewalk_pit: --{key} needs a value", file=sys.stderr)
                sys.exit(2)
            val = argv[i]
            i += 1
        out[name] = val
    return out


CLI = _parse_cli()
HEADLESS = bool(getattr(bpy.app, "background", False))


# Replace west_coast_usa with the name of your map
LEVEL_NAME = "west_coast_usa"

GAME_ROOT = None

LEVEL_NAME = CLI.get("LEVEL_NAME", LEVEL_NAME)
GAME_ROOT = CLI.get("CLI_GAME_ROOT", GAME_ROOT)

def _env_dir(var, *parts):
    base = os.environ.get(var)
    return os.path.join(base, *parts) if base else None


def _home(*parts):
    return os.path.expanduser(os.path.join("~", *parts))


def _steam_library_roots():
    roots = []
    bases = [_env_dir("ProgramFiles(x86)", "Steam"),
             _env_dir("ProgramFiles", "Steam"),
             _home(".steam", "steam"),
             _home(".local", "share", "Steam"),
             _home("Library", "Application Support", "Steam")]
    for base in [b for b in bases if b]:
        vdf = os.path.join(base, "steamapps", "libraryfolders.vdf")
        roots.append(base)
        try:
            with open(vdf, "r", encoding="utf-8", errors="ignore") as f:
                text = f.read()
        except OSError:
            continue
        for m in re.finditer(r'"path"\s*"([^"]+)"', text):
            roots.append(m.group(1).replace("\\\\", os.sep))
    out = []
    for r in roots:
        p = os.path.join(r, "steamapps", "common", "BeamNG.drive")
        if p not in out:
            out.append(p)
    return out


def _user_data_roots():
    bases = [_env_dir("LOCALAPPDATA", "BeamNG", "BeamNG.drive"),
             _env_dir("LOCALAPPDATA", "BeamNG.drive"),
             _home(".local", "share", "BeamNG.drive"),
             _home("Library", "Application Support", "BeamNG.drive")]
    roots = []
    for base in [b for b in bases if b]:
        if not os.path.isdir(base):
            continue
        roots.append(os.path.join(base, "current"))
        try:
            versions = [d for d in os.listdir(base)
                        if re.fullmatch(r"\d+\.\d+", d) and os.path.isdir(os.path.join(base, d))]
        except OSError:
            continue
        for d in sorted(versions, key=lambda s: [int(x) for x in s.split(".")], reverse=True):
            roots.append(os.path.join(base, d))
    return roots


def detect_game_root(level_name):
    override = os.environ.get("SIDEWALK_PIT_GAME_ROOT") or GAME_ROOT
    if override:
        return override
    candidates = _user_data_roots() + _steam_library_roots()
    for root in candidates:
        if os.path.isdir(os.path.join(root, "levels", level_name)):
            return root
    for root in candidates:
        if os.path.isdir(os.path.join(root, "levels")):
            return root
    raise RuntimeError(
        "Could not locate a BeamNG.drive installation.\n"
        "Set GAME_ROOT at the top of this script, or the "
        "SIDEWALK_PIT_GAME_ROOT environment variable, to the folder that "
        "contains a 'levels' directory.\nSearched:\n  "
        + "\n  ".join(candidates))


GAME_ROOT = detect_game_root(LEVEL_NAME)
LEVEL_ROOT = os.path.join(GAME_ROOT, "levels", LEVEL_NAME)


USE_LEVEL_ITEMS_FILE = True
JSON_PATH_MANUAL = os.path.join(GAME_ROOT, "square.json")

ITEMS_FILE_INCLUDE = []
ITEMS_FILE_EXCLUDE = []
PRINT_ITEMS_FILE_BREAKDOWN = True

MARKER_MATERIAL = "WarningMaterial"

DEFAULT_ZEBRA_MATERIAL = MARKER_MATERIAL

ZEBRA_MATERIAL_KEYWORDS = ["zebra", "crosswalk"]

MESHROAD_UNTEXTURED_ONLY = True

MESHROAD_MATERIAL_KEYS = ["topMaterial", "sideMaterial", "bottomMaterial"]
MESHROAD_PLACEHOLDER_MATERIALS = [MARKER_MATERIAL]

MESHROAD_EXCLUDE_KEYS = []

PROCESS_ALL_DECALROAD = False
PROCESS_ALL_DECALROAD = CLI.get("CLI_ALL_DECALROAD", PROCESS_ALL_DECALROAD)
ROAD_MATERIAL_FILTER = None

SIDE = "both"
GAP = 0.5
WIDTH = 2.5
HEIGHT = 0.3
CURB_STRIP = 0.15
Z_OFFSET = 0.0

THIN_ROAD_THRESHOLD = 1.0

CLOSE_LOOP_TOLERANCE = 0.5

SMOOTH_CORNERS = False
SMOOTH_SEGMENT_LENGTH = 0.75

BUILD_TRAFFIC_ISLANDS = True
ISLAND_MAX_MARKER_WIDTH = 0.5
ISLAND_JOIN_TOLERANCE = 0.5
ISLAND_MIN_AREA = 0.5
ISLAND_MITER_MIN_COS = 0.25
ISLAND_SMOOTH = True

TERRAIN_UNLESS_OVER_OBJECTS = True

ISLAND_FIX_TWIST = True
ISLAND_Z_BLEND_RADIUS = 2.5

ISLAND_WARN_TWIST = 0.15

ISLAND_MITER_NEIGHBOR_RATIO = 0.0

FORCE_FACE_ORIENTATION = True

SPLIT_FLAT_QUADS = False

DIAG_QUADS = True
DIAG_QUADS_SAMPLES = 6
DIAG_CHAMFER = True

ISLAND_ROUND_CORNERS = True
ISLAND_CORNER_RADIUS = 0.5
ISLAND_CORNER_MIN_TURN_DEG = 30.0

ROUND_OPEN_ENDS = True

ROUND_ENDS_SOURCES = ["decalroad", "decalroad_exact"]

ROUND_END_MAX_TURN_DEG = 6.0
ROUND_END_TIP_WIDTH = 0.30
ROUND_END_RADIUS_SCALE = 1.0

ROUND_END_MAX_WIDTH = 5.0

SUPPRESS_CAPS_AT_JUNCTIONS = True
JUNCTION_CAP_TOLERANCE = 2.5

FLUSH_HAIRPIN_TIPS = True
HAIRPIN_MAX_EXTEND_RATIO = 3.0

HAIRPIN_UNION = True
HAIRPIN_UNION_MAX_WIDTH_RATIO = 1.3
HAIRPIN_NOTCH_RADIUS = 0.35

MESHROAD_SMOOTH_CORNERS = True
MESHROAD_SMOOTH_SEGMENT_LENGTH = 0.75
MESHROAD_SMOOTH_MAX_TURN_DEG = 2.0

ZEBRA_SMOOTH_CORNERS = True
ZEBRA_SMOOTH_SEGMENT_LENGTH = 0.75

BEVEL_ZEBRA_EDGES = True

CURB_PROFILE_ENABLED = True
CURB_PROFILES = {
    "walk":   {"angle": 15.0, "exposed": 0.15, "label": "sidewalk"},
    "island": {"angle": 34.6, "exposed": 0.15, "label": "traffic island"},
}
CURB_PROFILE_BY_SOURCE = {
    "decalroad": "walk",
    "decalroad_exact": "walk",
    "meshroad": "walk",
    "island": "island",
}
ZEBRA_BEVEL_SIZE = 0.03

MERGE_ZEBRA_JUNCTIONS = True

ZEBRA_JOIN_TOLERANCE = 2.5

ZEBRA_FILLET_MAX_TRIM_RATIO = 0.35

ZEBRA_FILLET_TANGENT_PROBE = 1.2

ZEBRA_FILLET_MIN_ADVANCE = 0.4

SMOOTH_MAX_TURN_DEG = 4.0
ZEBRA_FILLET_MAX_TURN_DEG = 3.0

ZEBRA_FILLET_KEEP_INSIDE = True
ZEBRA_FILLET_INSIDE_TOLERANCE = 0.005

ZEBRA_FILLET_INNER_BIAS = 0.92

ZEBRA_FILLET_MAX_CORNER_DEG = 115.0

ZEBRA_FILLET_MAX_WIDTH_RATIO = 1.6

ZEBRA_FAN_MIN_TURN_DEG = 18.0
ZEBRA_FAN_MAX_REACH = 8.0

ZEBRA_SEAM_WELD = 0.05
MIN_NODE_SPACING = 0.02

VALIDATE_MESH = True


OPTIMIZE_HIDDEN_FACES = True

SIMPLE_COLMESH = True
COLMESH_WELD_DIST = 1e-4
COLMESH_UV = False

SIMPLIFY_PATH = True
SIMPLIFY_TOLERANCE = 0.02
SIMPLIFY_MAX_SPAN = 12.0
SIMPLIFY_MAX_TURN_DEG = 1.5

ROUND_DAE_FLOATS = True
DAE_FLOAT_DECIMALS = 4

PRINT_SIZE_REPORT = True

USE_TERRAIN_HEIGHT = True
TERRAIN_FILE_OVERRIDE = None
TERRAIN_POSITION_FALLBACK = (-2048.0, -2048.0, 100.0)
TERRAIN_MAX_HEIGHT_FALLBACK = 500.0
TERRAIN_SQUARE_SIZE_FALLBACK = 1.0

DECAL_HEIGHT_OFFSET = 0.10


STYLE_CONFIG_NAME = "pit_sidewalk_styles.json"
STYLE_CONFIG_PATH = os.path.join(LEVEL_ROOT, STYLE_CONFIG_NAME)

STYLE_DEFAULTS = {
    "version": 1,
    "fieldPrefix": "pit_",
    "seed": 20260812,
    "defaultScale": 2.5,
    "axes": {
        "curb": {"field": "pit_curb", "label": "curb edge"},
        "walk": {"field": "pit_walk", "label": "walk centre"},
        "profile": {"field": "pit_profile", "label": "curb profile"},
        "wall": {"field": "pit_wall", "label": "MeshRoad material"},
        "bottom": {"field": "pit_bottom", "label": "bottom faces"},
        "roll": {"field": "pit_roll", "label": "banking from nodes"},
    },
    "atlases": {
        "curbs8": {
            "bands": 8,
            "bandPx": 64,
            "paintRows": [1.5, 35.0],
            "plainRows": [40.5, 60.0],
            "paintOn": "top",
            "uScale": 5.89,
            "originTop": True,
        }
    },
    "sequence": {
        "curb": {"segment": [6.0, 18.0], "avoidRepeat": True},
        "walk": {"segment": [14.0, 40.0], "avoidRepeat": True},
    },
}

CURB_STYLE_VARIATION = True
WALK_STYLE_VARIATION = True


class StyleConfigError(Exception):
    pass


def _merge_cfg(base, over):
    out = dict(base)
    for k, v in over.items():
        out[k] = _merge_cfg(out[k], v) if (isinstance(v, dict)
                                           and isinstance(out.get(k), dict)) else v
    return out


def _pair(v, where="scale"):
    if isinstance(v, (tuple, list)):
        if len(v) != 2:
            raise StyleConfigError(f"{where}: must be a number or a [U, V] pair")
        return float(v[0]), float(v[1])
    if isinstance(v, (int, float)):
        return float(v), float(v)
    raise StyleConfigError(f"{where}: must be a number or a [U, V] pair")


def _starter_style_config():
    walk_mat = f"{LEVEL_NAME}_sidewalk_tiles"
    curb_mat = f"{LEVEL_NAME}_curb_concrete"
    return {
        "version": 1,
        "materials": {walk_mat: {"scale": 2.5}, curb_mat: {"scale": 2.5}},
        "curb": {
            "material": curb_mat,
            "styles": {"plain": {"band": 0, "weight": 100,
                                 "label": "concrete", "color": [0.66, 0.64, 0.60]}},
        },
        "walk": {
            "styles": {"tiles": {"material": walk_mat, "weight": 100,
                                 "label": "paving", "color": [0.70, 0.68, 0.64]}},
        },
    }


class StyleResolver:

    def __init__(self, cfg):
        self.cfg = cfg
        self.seed = cfg["seed"]
        self.field_prefix = cfg["fieldPrefix"].lower()
        self.default_scale = cfg["defaultScale"]
        self.materials = cfg["materials"]
        self.atlases = cfg["atlases"]
        self.axes = cfg["axes"]
        self.sequence = cfg["sequence"]
        self.curb_styles = (cfg.get("curb") or {}).get("styles") or {}
        self.walk_styles = (cfg.get("walk") or {}).get("styles") or {}
        self.curb_material = (cfg.get("curb") or {}).get("material")
        self.meshroad_curb_material = ((cfg.get("curb") or {}).get("meshroadMaterial")
                                       or self.curb_material)
        self.zebra_material = cfg.get("zebraMaterial")
        self.wall_styles = (cfg.get("wall") or {}).get("styles", {})
        self.unknown_tags = {}
        self._validate()


    def _validate(self):
        if self.cfg.get("version") != 1:
            raise StyleConfigError("version must be 1")
        for axis in ("curb", "walk"):
            if not self.axes.get(axis, {}).get("field"):
                raise StyleConfigError(f"axes.{axis}.field is missing")
        self.profile_field = (self.axes.get("profile") or {}).get("field", "pit_profile")
        self.wall_field = (self.axes.get("wall") or {}).get("field", "pit_wall")
        self.bottom_field = (self.axes.get("bottom") or {}).get("field", "pit_bottom")
        self.roll_field = (self.axes.get("roll") or {}).get("field", "pit_roll")
        for name, st in self.wall_styles.items():
            mat = st.get("material")
            if not mat:
                raise StyleConfigError(f"wall.styles.{name}: material is missing")
            if mat not in self.materials:
                raise StyleConfigError(
                    f"wall.styles.{name}: material {mat!r} is not defined under materials")
        for name, m in self.materials.items():
            _pair(m.get("scale", self.default_scale), f"materials.{name}.scale")
            atlas = m.get("atlas")
            if atlas is not None and atlas not in self.atlases:
                raise StyleConfigError(f"materials.{name}.atlas points at {atlas!r}, which does not exist")
        if not self.curb_styles or not self.walk_styles:
            raise StyleConfigError("each axis needs at least one style")

        for name, st in self.curb_styles.items():
            if "scale" in st:
                _pair(st["scale"], f"curb.styles.{name}.scale")
            if "sequence" in st:
                self._validate_sequence(st, self.curb_styles, f"curb.styles.{name}")
                if any("scale" in self.curb_styles[n] for n in st["sequence"]):
                    raise StyleConfigError(
                        f"curb.styles.{name}.sequence: a sequence alternates bands only, not texture scales")
            elif not isinstance(st.get("band"), int) and "scale" not in st:
                raise StyleConfigError(f"curb.styles.{name}: needs band, scale or sequence")
        for name, st in self.walk_styles.items():
            if "sequence" in st:
                self._validate_sequence(st, self.walk_styles, f"walk.styles.{name}")
            elif not st.get("material"):
                raise StyleConfigError(f"walk.styles.{name}: needs material or sequence")
            elif st["material"] not in self.materials:
                raise StyleConfigError(
                    f"walk.styles.{name}: material {st['material']!r} is not defined under materials")
        if not self.curb_material:
            raise StyleConfigError(
                "curb.material is missing - it names the material used for every kerb "
                "in the map, and the curb styles only vary its band or scale. In the "
                "Sidewalk Tags tool, tick 'also set as the map's curb material' when "
                "adding a kerb material, or add it to the json by hand:\n"
                '    "curb": { "material": "<name>", "styles": { ... } }')
        for key, mat in (("material", self.curb_material),
                         ("meshroadMaterial", self.meshroad_curb_material)):
            if mat not in self.materials:
                raise StyleConfigError(f"curb.{key}: material {mat!r} is not defined under materials")

    def _validate_sequence(self, st, styles, where):
        seq = st["sequence"]
        if not isinstance(seq, list) or len(seq) < 2:
            raise StyleConfigError(f"{where}.sequence needs at least two styles")
        for nm in seq:
            if nm not in styles:
                raise StyleConfigError(f"{where}.sequence refers to {nm!r}, which does not exist")
            if "sequence" in styles[nm]:
                raise StyleConfigError(f"{where}.sequence refers to {nm!r}, which is itself a sequence")


    def scale_for(self, material):
        m = self.materials.get(material)
        return _pair(m.get("scale", self.default_scale) if m else self.default_scale,
                     f"materials.{material}.scale")

    def atlas_for(self, material):
        key = (self.materials.get(material) or {}).get("atlas")
        return self.atlases.get(key) if key else None

    def fields_of(self, obj):
        p = self.field_prefix
        return {k.lower(): v for k, v in obj.items()
                if isinstance(k, str) and k.lower().startswith(p)}

    def band_labels(self):
        return {st["band"]: st.get("label", "")
                for st in self.curb_styles.values() if "band" in st}


    def _weighted(self, weights, *key_parts):
        keys = list(weights)
        total = sum(weights[k] for k in keys)
        if total <= 0:
            return keys[0]
        raw = "|".join(str(p) for p in (self.seed,) + key_parts).encode("utf-8")
        r = int(hashlib.md5(raw).hexdigest()[:8], 16) % total
        for k in keys:
            r -= weights[k]
            if r < 0:
                return k
        return keys[-1]

    def _sequence_picker(self, key, kind, options, segment, avoid_repeat):
        options = list(options) or [0]
        lo, hi = float(segment[0]), float(segment[1])
        edges, vals = [0.0], []

        def extend_to(s):
            while edges[-1] <= s + 1e-6:
                i = len(vals)
                frac = (int(hashlib.md5(f"{key}|{kind}|len|{i}".encode()).hexdigest()[:8], 16)
                        % 10000) / 10000.0
                edges.append(edges[-1] + lo + frac * max(0.0, hi - lo))
                prev = vals[-1] if vals else None
                pool = ([o for o in options if o != prev]
                        if (avoid_repeat and prev is not None and len(options) > 1)
                        else options)
                r = int(hashlib.md5(f"{key}|{kind}|val|{i}".encode()).hexdigest()[:8], 16)
                vals.append(pool[r % len(pool)])

        def pick(s):
            s = abs(float(s))
            extend_to(s)
            for i in range(len(vals)):
                if s < edges[i + 1]:
                    return vals[i]
            return vals[-1]

        return pick

    def _seq_params(self, st, axis):
        base = self.sequence.get(axis, {})
        return (st.get("segment", base.get("segment", [10.0, 20.0])),
                st.get("avoidRepeat", base.get("avoidRepeat", True)))

    def _tag(self, fields, axis, key):
        name = fields.get(self.axes[axis]["field"].lower())
        if name is None or name == "":
            return None
        styles = self.curb_styles if axis == "curb" else self.walk_styles
        if name not in styles:
            self.unknown_tags.setdefault((axis, str(name)), []).append(str(key))
            return None
        return name


    def _profile_tag(self, fields, key):
        name = fields.get(self.profile_field.lower())
        if name is None or name == "":
            return None
        if name not in CURB_PROFILES:
            self.unknown_tags.setdefault(("profile", str(name)), []).append(str(key))
            return None
        return name

    def _wall_tag(self, fields, key):
        name = fields.get(self.wall_field.lower())
        if name is None or name == "":
            return None
        st = self.wall_styles.get(name)
        if not st:
            self.unknown_tags.setdefault(("wall", str(name)), []).append(str(key))
            return None
        return st["material"]

    def _flag_tag(self, fields, field, axis, key):
        v = fields.get(field.lower())
        if v is None or v == "":
            return None
        t = str(v).strip().lower()
        if t in ("on", "true", "1", "yes"):
            return True
        if t in ("off", "false", "0", "no"):
            return False
        self.unknown_tags.setdefault((axis, str(v)), []).append(str(key))
        return None

    def resolve(self, fields, key):
        curb_tag = self._tag(fields, "curb", key)
        walk_tag = self._tag(fields, "walk", key)
        profile_tag = self._profile_tag(fields, key)

        band_at, curb_scale, curb_name = None, None, None
        if curb_tag is not None:
            curb_name = curb_tag
            st = self.curb_styles[curb_tag]
            if "sequence" in st:
                bands = [self.curb_styles[n].get("band", 0) for n in st["sequence"]]
                segment, avoid = self._seq_params(st, "curb")
                band_at = self._sequence_picker(str(key), "curb", bands, segment, avoid)
                band = bands[0]
            else:
                band, curb_scale = st.get("band", 0), st.get("scale")
        else:
            fixed = {nm: st for nm, st in self.curb_styles.items() if "sequence" not in st}
            if CURB_STYLE_VARIATION:
                curb_name = self._weighted({nm: st.get("weight", 0)
                                            for nm, st in fixed.items()}, "curb", key)
            else:
                curb_name = next(iter(fixed))
            st = fixed[curb_name]
            band, curb_scale = st.get("band", 0), st.get("scale")

        extras, slot_at = [], None
        if walk_tag is not None:
            st = self.walk_styles[walk_tag]
            if "sequence" in st:
                pool = list(dict.fromkeys(self.walk_styles[n]["material"]
                                          for n in st["sequence"]))
                segment, avoid = self._seq_params(st, "walk")
                walk_material, extras = pool[0], pool[1:]
                slots = [0] + [2 + k for k in range(len(extras))]
                slot_at = self._sequence_picker(str(key), "walk", slots, segment, avoid)
            else:
                walk_material = st["material"]
        elif WALK_STYLE_VARIATION:
            weights = {st["material"]: st.get("weight", 0)
                       for st in self.walk_styles.values() if "material" in st}
            walk_material = self._weighted(weights, "walk", key)
        else:
            walk_material = next(st["material"] for st in self.walk_styles.values()
                                 if "material" in st)

        return {
            "walk_slots": [walk_material, self.curb_material] + extras,
            "walk_material": walk_material,
            "extras": extras,
            "walk_scale": self.scale_for(walk_material),
            "curb_band": int(band),
            "curb_band_at": band_at,
            "curb_style": curb_name,
            "curb_scale": (_pair(curb_scale, f"curb.styles.{curb_name}.scale")
                           if curb_scale is not None else None),
            "walk_slot_at": slot_at,
            "profile": profile_tag,
            "wall_material": self._wall_tag(fields, key),
            "bottom": self._flag_tag(fields, self.bottom_field, "bottom", key),
            "roll": self._flag_tag(fields, self.roll_field, "roll", key),
            "tagged": bool(curb_tag or walk_tag or profile_tag),
        }


def _load_style_config():
    cfg = STYLE_DEFAULTS
    if os.path.exists(STYLE_CONFIG_PATH):
        try:
            with open(STYLE_CONFIG_PATH, "r", encoding="utf-8") as f:
                cfg = _merge_cfg(cfg, json.load(f))
        except ValueError as exc:
            raise StyleConfigError(f"{STYLE_CONFIG_PATH}: invalid JSON - {exc}")
    else:
        starter = _starter_style_config()
        try:
            os.makedirs(LEVEL_ROOT, exist_ok=True)
            with open(STYLE_CONFIG_PATH, "w", encoding="utf-8") as f:
                json.dump(starter, f, ensure_ascii=False, indent=2)
            print(f"  [style] wrote starter config: {STYLE_CONFIG_PATH}")
        except OSError as exc:
            print(f"  [style] could not write the map config ({exc}) - using defaults")
        cfg = _merge_cfg(cfg, starter)
    return StyleResolver(cfg)


ACTIVE_TEXTURE_SCALE = [(1.0, 1.0), (1.0, 1.0)]


def apply_styles(resolver):
    global STYLES, CURB_MATERIAL_NAME, MESHROAD_CURB_MATERIAL_NAME
    global SIDEWALK_MATERIAL_NAME, ZEBRA_MATERIAL, TEXTURE_SCALE
    global CURB_IS_ATLAS, CURB_ATLAS_BANDS, CURB_ATLAS_BAND_PX
    global CURB_ATLAS_PAINT_ROWS, CURB_ATLAS_PLAIN_ROWS, CURB_ATLAS_PLAIN_SLICE
    global CURB_ATLAS_PAINT_ON, CURB_ATLAS_U_SCALE, CURB_ATLAS_ORIGIN_TOP

    STYLES = resolver
    CURB_MATERIAL_NAME = resolver.curb_material
    MESHROAD_CURB_MATERIAL_NAME = resolver.meshroad_curb_material
    SIDEWALK_MATERIAL_NAME = next((st["material"] for st in resolver.walk_styles.values()
                                   if "material" in st), None)
    if SIDEWALK_MATERIAL_NAME is None:
        raise StyleConfigError(
            "walk.styles has no style with a material - a sequence alternates between "
            "other styles, so at least one plain style is required")
    ZEBRA_MATERIAL = resolver.zebra_material or DEFAULT_ZEBRA_MATERIAL
    TEXTURE_SCALE = resolver.default_scale

    atlas = resolver.atlas_for(CURB_MATERIAL_NAME)
    CURB_IS_ATLAS = atlas is not None
    a = atlas or STYLE_DEFAULTS["atlases"]["curbs8"]
    CURB_ATLAS_BANDS = int(a["bands"])
    CURB_ATLAS_BAND_PX = int(a["bandPx"])
    CURB_ATLAS_PAINT_ROWS = tuple(a["paintRows"])
    CURB_ATLAS_PLAIN_ROWS = tuple(a["plainRows"])
    CURB_ATLAS_PLAIN_SLICE = tuple(a.get("plainSlice", a["plainRows"]))
    CURB_ATLAS_PAINT_ON = a["paintOn"]
    CURB_ATLAS_U_SCALE = a.get("uScale")
    CURB_ATLAS_ORIGIN_TOP = bool(a.get("originTop", True))
    ACTIVE_TEXTURE_SCALE[0] = _pair(TEXTURE_SCALE)
    ACTIVE_TEXTURE_SCALE[1] = _pair(TEXTURE_SCALE)



apply_styles(StyleResolver(_merge_cfg(STYLE_DEFAULTS, _starter_style_config())))

def road_roll_tag(road):
    return bool(STYLES.resolve(road.get("fields") or {}, road.get("persistentId") or "")["roll"])


def texture_scale_for(material_name):
    return STYLES.scale_for(material_name)


ACTIVE_CURB_STYLE_SCALE = [None]


def curb_scale_for(material_name):
    override = ACTIVE_CURB_STYLE_SCALE[0]
    if override is not None and material_name == CURB_MATERIAL_NAME:
        return override
    return texture_scale_for(material_name)


ACTIVE_ZEBRA = [None]
ACTIVE_ZEBRA_WALK = [None]
ACTIVE_S = [0.0]
ACTIVE_WALK_SLOTS = [[]]
ACTIVE_CURB_BAND = [0]

ACTIVE_KEEP_BOTTOM = [False]

CURB_ATLAS_ACTIVE = [True]

ACTIVE_CURB_PROFILE = [CURB_PROFILES["walk"]]

ACTIVE_UP = [None]

ACTIVE_TURN_SCALE = [1.0]

FACE_REFS = [None]

SHADE_SMOOTH = True

SMOOTH_CREASE_ANGLE_DEG = 30.0

DIAG_WALL_TWIST = True


def set_curb_profile(source):
    name = CURB_PROFILE_BY_SOURCE.get(source, "walk")
    ACTIVE_CURB_PROFILE[0] = CURB_PROFILES.get(name, CURB_PROFILES["walk"])

STYLE_USAGE = {"curb": {}, "walk": {}, "src": {}}


def _curb_band_v(row, s=None):
    band = ACTIVE_CURB_BAND[0]
    if ACTIVE_ZEBRA[0] is not None and s is not None:
        band = ACTIVE_ZEBRA[0](s)
    band %= CURB_ATLAS_BANDS
    v = (band * CURB_ATLAS_BAND_PX + row) / float(CURB_ATLAS_BANDS * CURB_ATLAS_BAND_PX)
    return (1.0 - v) if CURB_ATLAS_ORIGIN_TOP else v


def _row_span(rows, k):
    return rows[0] + min(1.0, max(0.0, k)) * (rows[1] - rows[0])


def curb_top_v(w, s=None):
    if not CURB_ATLAS_ACTIVE[0]:
        return (w - CURB_STRIP) / _tex(CURB) + 0.5
    k = (w / CURB_STRIP) if CURB_STRIP > 1e-9 else 0.0
    if CURB_ATLAS_PAINT_ON == "top":
        return _curb_band_v(_row_span(CURB_ATLAS_PAINT_ROWS, k), s)
    return _curb_band_v(_row_span(CURB_ATLAS_PLAIN_SLICE, k), s)


def curb_face_v(depth, s=None):
    if not CURB_ATLAS_ACTIVE[0]:
        return depth / _tex(CURB) + 0.5
    k = (depth / HEIGHT) if HEIGHT > 1e-9 else 0.0
    if CURB_ATLAS_PAINT_ON == "top":
        return _curb_band_v(_row_span(CURB_ATLAS_PLAIN_ROWS, k), s)
    return _curb_band_v(_row_span((CURB_ATLAS_PAINT_ROWS[0],
                                   CURB_ATLAS_PLAIN_ROWS[1]), k), s)


def curb_u(s):
    if not CURB_ATLAS_ACTIVE[0]:
        return s / _texuv(CURB)[0] + 0.5
    sc = CURB_ATLAS_U_SCALE if CURB_ATLAS_U_SCALE else _tex(CURB)
    return s / sc + 0.5


def uv_curb_top(w, s):
    return (curb_u(s), curb_top_v(w, s))


def uv_curb_face(depth, s):
    return (curb_u(s), curb_face_v(depth, s))


def _texuv(mat):
    return ACTIVE_TEXTURE_SCALE[1] if mat == CURB else ACTIVE_TEXTURE_SCALE[0]


def _tex(mat):
    return _texuv(mat)[1]

OBJECT_NAME = "custom_sidewalk"
EXPORT_FOLDER = os.path.join(LEVEL_ROOT, "art", "shapes", "sidewalk")
EXPORT_FOLDER = CLI.get("CLI_EXPORT_FOLDER", EXPORT_FOLDER)
EXPORT_DAE = True

OVERWRITE_EXPORT = True
FIXED_EXPORT_NAME = "sidewalk_pit"


hw = WIDTH / 2
inset = hw - CURB_STRIP

if inset <= 0:
    raise ValueError("CURB_STRIP is too large relative to WIDTH - inset came out zero or negative")

WALK, CURB = 0, 1
WANT_UP = Vector((0.0, 0.0, 1.0))
WANT_DOWN = Vector((0.0, 0.0, -1.0))


def iter_json_objects(text):
    decoder = json.JSONDecoder()
    idx, n = 0, len(text)
    while idx < n:
        while idx < n and text[idx] in " \t\r\n":
            idx += 1
        if idx >= n:
            break
        try:
            obj, end = decoder.raw_decode(text, idx)
        except json.JSONDecodeError:
            break
        yield obj
        idx = end


def find_items_files():
    if not USE_LEVEL_ITEMS_FILE:
        return [JSON_PATH_MANUAL], [JSON_PATH_MANUAL]

    root = os.path.join(LEVEL_ROOT, "main")
    if not os.path.isdir(root):
        root = LEVEL_ROOT
    if not os.path.isdir(root):
        raise ValueError(
            f"Map folder not found: {LEVEL_ROOT}\n"
            f"Check LEVEL_NAME={LEVEL_NAME!r} and GAME_ROOT."
        )

    all_files = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            if fn.lower() == "items.level.json":
                all_files.append(os.path.join(dirpath, fn))
    all_files.sort()

    if not all_files:
        raise ValueError(f"No items.level.json found under {root}")

    def keep(p):
        rel = os.path.relpath(p, LEVEL_ROOT).replace("\\", "/").lower()
        if ITEMS_FILE_INCLUDE and not any(s.lower() in rel for s in ITEMS_FILE_INCLUDE):
            return False
        if any(s.lower() in rel for s in ITEMS_FILE_EXCLUDE):
            return False
        return True

    road_files = [p for p in all_files if keep(p)]
    if not road_files:
        raise ValueError(
            f"ITEMS_FILE_INCLUDE/EXCLUDE filtered out all {len(all_files)} files. "
            f"Clear the lists or correct them."
        )

    print(f"Scanned {len(all_files)} items.level.json files under {os.path.relpath(root, GAME_ROOT)}"
          + (f" ({len(road_files)} after filtering)" if len(road_files) != len(all_files) else ""))
    return road_files, all_files


def _group_of(json_path):
    try:
        rel = os.path.relpath(os.path.dirname(json_path), LEVEL_ROOT)
    except (ValueError, TypeError):
        return ""
    rel = rel.replace("\\", "/").strip("/")
    if rel.lower().startswith("main/"):
        rel = rel[5:]
    return "" if rel in (".", "") else rel


def _read_json_objects(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return list(iter_json_objects(f.read()))
    except (OSError, UnicodeDecodeError) as exc:
        print(f"  [json] skipping {os.path.basename(os.path.dirname(path))}/items.level.json: {exc}")
        return []


def load_all_centerlines(json_paths, material_filter=None):
    if isinstance(json_paths, str):
        json_paths = [json_paths]

    decal_candidates = []
    meshroad_candidates = []
    breakdown = []
    n_skipped_total = 0
    skipped_by_key = set()
    for json_path in json_paths:
        n_decal = n_mesh = n_skipped = 0
        group_path = _group_of(json_path)
        for obj in _read_json_objects(json_path):
            cls = obj.get("class")
            raw_nodes = obj.get("nodes")
            if cls not in ("DecalRoad", "MeshRoad") or not isinstance(raw_nodes, list) or not raw_nodes:
                continue
            if not all(isinstance(n, (list, tuple)) and len(n) >= 4 for n in raw_nodes):
                continue

            nodes = [{"x": n[0], "y": n[1], "z": n[2], "width": n[3]} for n in raw_nodes]

            if cls == "DecalRoad":
                n_decal += 1
                decal_candidates.append({
                    "persistentId": obj.get("persistentId"),
                    "name": obj.get("name"),
                    "group": group_path,
                    "fields": STYLES.fields_of(obj),
                    "material": obj.get("material"),
                    "over_objects": bool(obj.get("overObjects")),
                    "nodes": nodes,
                    "widths": [n["width"] for n in nodes],
                    "width": nodes[0]["width"],
                })
            else:
                if not all(len(n) >= 5 for n in raw_nodes):
                    continue
                textured = _meshroad_textured_keys(obj)
                if MESHROAD_UNTEXTURED_ONLY and textured:
                    n_skipped += 1
                    skipped_by_key.update(d.split("=")[0] for d in textured)
                    continue
                n_mesh += 1
                meshroad_candidates.append({
                    "persistentId": obj.get("persistentId"),
                    "name": obj.get("name"),
                    "group": group_path,
                    "fields": STYLES.fields_of(obj),
                    "nodes": nodes,
                    "widths": [n["width"] for n in nodes],
                    "depths": [raw[4] for raw in raw_nodes],
                    "ups": meshroad_ups(raw_nodes),
                    "width": nodes[0]["width"],
                    "source": "meshroad",
                })
        n_skipped_total += n_skipped
        if n_decal or n_mesh or n_skipped:
            breakdown.append((os.path.relpath(json_path, LEVEL_ROOT) if USE_LEVEL_ITEMS_FILE else json_path,
                              n_decal, n_mesh, n_skipped))

    if PRINT_ITEMS_FILE_BREAKDOWN and breakdown:
        print("  breakdown by file:")
        for rel, nd, nm, ns in breakdown:
            extra = f", {ns} textured MeshRoad (skipped)" if ns else ""
            print(f"    {nd:>5} DecalRoad, {nm:>4} MeshRoad{extra}   {rel}")

    if MESHROAD_UNTEXTURED_ONLY and n_skipped_total:
        print(f"  [meshroad] skipped {n_skipped_total} MeshRoad that have a texture assigned "
              f"(keys found: {', '.join(sorted(skipped_by_key))}).")
        print(f"  [meshroad] if those are the ones you drew, set MESHROAD_UNTEXTURED_ONLY = False.")

    roads = []

    zebra_mats = resolve_zebra_materials(decal_candidates)
    zebra_candidates = [c for c in decal_candidates if c["material"] in zebra_mats]
    decal_candidates = [c for c in decal_candidates if c["material"] not in zebra_mats]
    islands, zebra_candidates = extract_islands(zebra_candidates)
    roads.extend(islands)

    for c in zebra_candidates:
        c["source"] = "decalroad_exact"
    if zebra_candidates:
        print(f"Found {len(zebra_candidates)} crosswalk DecalRoad "
              f"({', '.join(sorted(m for m in zebra_mats if m))}) - building in 'exact' mode")
    roads.extend(zebra_candidates)

    if PROCESS_ALL_DECALROAD and decal_candidates:
        chosen = []
        if material_filter:
            chosen = [c for c in decal_candidates if c["material"] == material_filter]
        if not chosen:
            groups = {}
            for c in decal_candidates:
                n0 = c["nodes"][0]
                key = (round(n0["x"], 1), round(n0["y"], 1))
                if key not in groups or c["width"] > groups[key]["width"]:
                    groups[key] = c
            chosen = list(groups.values())
            materials_found = sorted({c["material"] for c in decal_candidates})
            print(f"Auto-detected {len(chosen)} DecalRoad (out of {len(decal_candidates)}, materials: {materials_found})")
        for c in chosen:
            c["source"] = "decalroad"
        roads.extend(chosen)
    elif decal_candidates:
        print(f"Ignoring {len(decal_candidates)} plain DecalRoad (PROCESS_ALL_DECALROAD=False) - only MeshRoad and zebra decals are processed")

    if meshroad_candidates:
        print(f"Found {len(meshroad_candidates)} MeshRoad - building in 'exact' mode (exact per-node width)")
    roads.extend(meshroad_candidates)

    if not roads:
        raise ValueError(f"No DecalRoad/MeshRoad at all in {json_path} - check that the content was pasted correctly")
    return roads


def _has_value(obj, key):
    if key not in obj:
        return False
    v = obj[key]
    if v is None:
        return False
    if isinstance(v, str) and not v.strip():
        return False
    return True


def _meshroad_textured_keys(obj):
    placeholders = {str(m).strip().lower() for m in MESHROAD_PLACEHOLDER_MATERIALS}
    hits = []
    for key in MESHROAD_MATERIAL_KEYS:
        if not _has_value(obj, key):
            continue
        val = str(obj[key]).strip()
        if val.lower() in placeholders:
            continue
        hits.append(f"{key}={val}")
    for key in MESHROAD_EXCLUDE_KEYS:
        if _has_value(obj, key):
            hits.append(key)
    return hits


def extract_islands(candidates):
    if not BUILD_TRAFFIC_ISLANDS:
        return [], candidates

    thin, thick = [], []
    for c in candidates:
        ws = c.get("widths") or [c.get("width", 0.0)]
        if ws and max(ws) < ISLAND_MAX_MARKER_WIDTH and len(c["nodes"]) >= 2:
            thin.append(c)
        else:
            thick.append(c)
    if not thin:
        return [], candidates

    tol = ISLAND_JOIN_TOLERANCE

    def endp(c, last):
        node = c["nodes"][-1 if last else 0]
        return (node["x"], node["y"], node["z"])

    def near(a, b):
        return math.hypot(a[0] - b[0], a[1] - b[1]) <= tol

    used = [False] * len(thin)
    islands, leftovers = [], []

    for start_i in range(len(thin)):
        if used[start_i]:
            continue
        used[start_i] = True
        chain = [(start_i, False)]
        ring_start = endp(thin[start_i], False)
        cur = endp(thin[start_i], True)
        closed = False
        self_closing = len(thin[start_i]["nodes"]) >= 3
        while True:
            if near(cur, ring_start) and (len(chain) >= 2 or self_closing):
                closed = True
                break
            nxt = None
            for j in range(len(thin)):
                if used[j]:
                    continue
                if near(cur, endp(thin[j], False)):
                    nxt = (j, False)
                    break
                if near(cur, endp(thin[j], True)):
                    nxt = (j, True)
                    break
            if nxt is None:
                break
            used[nxt[0]] = True
            chain.append(nxt)
            cur = endp(thin[nxt[0]], not nxt[1])

        if not closed:
            leftovers.extend(thin[i] for i, _ in chain)
            continue

        pts = []
        spans = []
        for i, rev in chain:
            seq = thin[i]["nodes"]
            if rev:
                seq = list(reversed(seq))
            raw = [(nd["x"], nd["y"]) for nd in seq]
            seg = [Vector((nd["x"], nd["y"], nd["z"])) for nd in seq]
            if ISLAND_SMOOTH and len(seg) >= 3:
                seg = smooth_path(seg, SMOOTH_SEGMENT_LENGTH)
            seg = [(v.x, v.y, v.z) for v in seg]
            seg_spans = [2.0 * min(math.hypot(p[0] - q[0], p[1] - q[1]) for q in raw)
                         for p in seg]
            if pts and near(seg[0], pts[-1]):
                seg, seg_spans = seg[1:], seg_spans[1:]
            for p, sp in zip(seg, seg_spans):
                if pts and math.hypot(p[0] - pts[-1][0], p[1] - pts[-1][1]) < 1e-3:
                    continue
                pts.append(p)
                spans.append(sp)
        while len(pts) > 3 and near(pts[-1], pts[0]):
            pts.pop()
            spans.pop()

        uses_nodes = (not TERRAIN_UNLESS_OVER_OBJECTS) or any(
            thin[i].get("over_objects") for i, _rev in chain)
        if ISLAND_FIX_TWIST and uses_nodes and len(pts) >= 4:
            before = island_twist(pts)[0]
            pts = harmonize_island_z(pts, spans, ISLAND_Z_BLEND_RADIUS)
            after = island_twist(pts)[0]
            if before > ISLAND_WARN_TWIST:
                print(f"  [island] height twist: {before:.2f}m -> {after:.2f}m "
                      f"(levelled against the side with the denser nodes)")

        if ISLAND_ROUND_CORNERS and len(pts) >= 3:
            pts = round_polyline_corners(pts, ISLAND_CORNER_RADIUS,
                                         ISLAND_CORNER_MIN_TURN_DEG)

        area = abs(_signed_area_2d(pts))
        if len(pts) < 3 or area < ISLAND_MIN_AREA:
            print(f"  [island] closed loop found but its area {area:.2f} sq m "
                  f"< ISLAND_MIN_AREA - skipped")
            leftovers.extend(thin[i] for i, _ in chain)
            continue

        islands.append({
            "source": "island",
            "over_objects": any(thin[i].get("over_objects") for i, _rev in chain),
            "name": thin[chain[0][0]].get("name"),
            "persistentId": thin[chain[0][0]].get("persistentId"),
            "group": thin[chain[0][0]].get("group", ""),
            "fields": thin[chain[0][0]].get("fields") or {},
            "material": thin[chain[0][0]].get("material"),
            "ring": pts,
            "nodes": [{"x": p[0], "y": p[1], "z": p[2], "width": 0.0} for p in pts],
            "parts": len(chain),
            "area": area,
        })

    if islands:
        for isl in islands:
            print(f"  [island] traffic island: {isl['parts']} decals -> closed polygon "
                  f"{len(isl['ring'])} vertices, {isl['area']:.1f} sq m")

    return islands, thick + leftovers


def resolve_zebra_materials(decal_candidates):
    all_mats = sorted({c["material"] for c in decal_candidates if c["material"]})

    if ZEBRA_MATERIAL:
        if ZEBRA_MATERIAL not in all_mats:
            print(f"  [zebra] warning: ZEBRA_MATERIAL={ZEBRA_MATERIAL!r} was not found on any DecalRoad in the map.")
            print(f"  [zebra] materials present: {all_mats}")
        return {ZEBRA_MATERIAL}

    hits = {m for m in all_mats if any(k.lower() in m.lower() for k in ZEBRA_MATERIAL_KEYWORDS)}
    if hits:
        print(f"  [zebra] auto-detected: {sorted(hits)}")
    else:
        print(f"  [zebra] no crosswalk decal detected. materials present: {all_mats}")
        print(f"  [zebra] if one of them is a crosswalk, add it as zebraMaterial "
              f"in {STYLE_CONFIG_NAME}.")
    return hits


def find_terrain_block(json_paths):
    if isinstance(json_paths, str):
        json_paths = [json_paths]
    for json_path in json_paths:
        for obj in _read_json_objects(json_path):
            if obj.get("class") == "TerrainBlock":
                print(f"  TerrainBlock found in: "
                      f"{os.path.relpath(json_path, LEVEL_ROOT) if USE_LEVEL_ITEMS_FILE else json_path}")
                return {
                    "position": tuple(obj.get("position", TERRAIN_POSITION_FALLBACK)),
                    "max_height": obj.get("maxHeight", TERRAIN_MAX_HEIGHT_FALLBACK),
                    "square_size": obj.get("squareSize", TERRAIN_SQUARE_SIZE_FALLBACK),
                    "terrain_file": obj.get("terrainFile"),
                }
    return None


def resolve_terrain_file(info):
    if TERRAIN_FILE_OVERRIDE:
        if os.path.isfile(TERRAIN_FILE_OVERRIDE):
            return TERRAIN_FILE_OVERRIDE
        print(f"  [ter] TERRAIN_FILE_OVERRIDE does not exist: {TERRAIN_FILE_OVERRIDE}")

    if info and info.get("terrain_file"):
        rel = str(info["terrain_file"]).replace("\\", "/").lstrip("/")
        cand = os.path.normpath(os.path.join(GAME_ROOT, rel))
        if os.path.isfile(cand):
            return cand
        cand2 = os.path.normpath(os.path.join(LEVEL_ROOT, os.path.basename(rel)))
        if os.path.isfile(cand2):
            return cand2
        print(f"  [ter] terrainFile={info['terrain_file']!r} points at a missing file - falling back to a search")

    found = []
    if os.path.isdir(LEVEL_ROOT):
        for dirpath, _d, filenames in os.walk(LEVEL_ROOT):
            for fn in filenames:
                if fn.lower().endswith(".ter"):
                    p = os.path.join(dirpath, fn)
                    try:
                        found.append((os.path.getsize(p), p))
                    except OSError:
                        pass
    if not found:
        return None
    found.sort(reverse=True)
    if len(found) > 1:
        print(f"  [ter] found {len(found)} .ter files - picked the largest: {os.path.basename(found[0][1])}")
    return found[0][1]


def load_ter_file(path):
    with open(path, "rb") as f:
        data = f.read()
    offset = 0
    offset += 1
    size = struct.unpack_from("<I", data, offset)[0]; offset += 4
    sample_count = size * size
    height_map = struct.unpack_from(f"<{sample_count}H", data, offset)
    return {"size": size, "height_map": height_map}


_terrain_cache = {}
TERRAIN_SCAN_FILES = []


def get_terrain_sampler():
    if "sampler" in _terrain_cache:
        return _terrain_cache["sampler"]

    info = find_terrain_block(TERRAIN_SCAN_FILES)
    if info:
        pos, max_h, sq = info["position"], info["max_height"], info["square_size"]
        print(f"  TerrainBlock: position={pos}, maxHeight={max_h}, squareSize={sq}")
    else:
        pos = TERRAIN_POSITION_FALLBACK
        max_h = TERRAIN_MAX_HEIGHT_FALLBACK
        sq = TERRAIN_SQUARE_SIZE_FALLBACK
        print(f"  No TerrainBlock found - fallback values: position={pos}, maxHeight={max_h}, squareSize={sq}")

    ter_path = resolve_terrain_file(info)
    if not ter_path:
        print("  [ter] no .ter file for this map - continuing without terrain height sampling "
              "(the centreline Z is used across the full sidewalk width).")
        _terrain_cache["sampler"] = None
        return None

    try:
        terrain = load_ter_file(ter_path)
    except (OSError, struct.error) as exc:
        print(f"  [ter] failed to read {ter_path}: {exc} - continuing without terrain height sampling.")
        _terrain_cache["sampler"] = None
        return None

    size = terrain["size"]
    hm = terrain["height_map"]
    print(f"  terrain: {os.path.basename(ter_path)}  {size}x{size}  "
          f"(covers {size * sq:.0f}x{size * sq:.0f} m)")

    def sample(x, y):
        gx = (x - pos[0]) / sq
        gy = (y - pos[1]) / sq
        gx = min(max(gx, 0.0), size - 1.0001)
        gy = min(max(gy, 0.0), size - 1.0001)
        x0, y0 = int(gx), int(gy)
        x1, y1 = min(x0 + 1, size - 1), min(y0 + 1, size - 1)
        fx, fy = gx - x0, gy - y0
        h00 = hm[y0 * size + x0]
        h10 = hm[y0 * size + x1]
        h01 = hm[y1 * size + x0]
        h11 = hm[y1 * size + x1]
        h0 = h00 * (1 - fx) + h10 * fx
        h1 = h01 * (1 - fx) + h11 * fx
        raw = h0 * (1 - fy) + h1 * fy
        return pos[2] + (raw / 65535.0) * max_h

    _terrain_cache["sampler"] = sample
    return sample


CR_ALPHA = 0.5


def cr_knots(p0, p1, p2, p3):
    if CR_ALPHA <= 0.0:
        return None
    t = [0.0]
    for a, b in ((p0, p1), (p1, p2), (p2, p3)):
        t.append(t[-1] + max(1e-9, (b - a).length) ** CR_ALPHA)
    return tuple(t)


def catmull_rom_point(p0, p1, p2, p3, t, knots=None):
    if knots is None:
        t2 = t * t
        t3 = t2 * t
        return ((p1 * 2.0)
                + (p2 - p0) * t
                + (p0 * 2.0 - p1 * 5.0 + p2 * 4.0 - p3) * t2
                + (p1 * 3.0 - p0 - p2 * 3.0 + p3) * t3) * 0.5
    k0, k1, k2, k3 = knots
    u = k1 + (k2 - k1) * t

    def lerp(a, b, ta, tb):
        if tb - ta < 1e-12:
            return b
        f = (u - ta) / (tb - ta)
        return a * (1.0 - f) + b * f

    a1 = lerp(p0, p1, k0, k1)
    a2 = lerp(p1, p2, k1, k2)
    a3 = lerp(p2, p3, k2, k3)
    b1 = lerp(a1, a2, k0, k2)
    b2 = lerp(a2, a3, k1, k3)
    return lerp(b1, b2, k1, k2)


def _segment_t_values(p0, p1, p2, p3, target_spacing, max_turn_deg=None, knots=None):
    limit = SMOOTH_MAX_TURN_DEG if max_turn_deg is None else max_turn_deg
    seg_len = (p2 - p1).length
    if limit >= 180.0:
        steps = max(1, int(round(seg_len / target_spacing)))
        return [s / steps for s in range(1, steps + 1)]

    dense = max(16, min(256, int(seg_len / 0.05)))
    pts = [catmull_rom_point(p0, p1, p2, p3, i / float(dense), knots) for i in range(dense + 1)]

    ts, acc_d, acc_a, prev_dir = [], 0.0, 0.0, None
    for i in range(1, dense + 1):
        d = pts[i] - pts[i - 1]
        acc_d += d.length
        cur = d.normalized() if d.length > 1e-9 else None
        if prev_dir is not None and cur is not None:
            acc_a += math.degrees(math.acos(max(-1.0, min(1.0, prev_dir.dot(cur)))))
        if cur is not None:
            prev_dir = cur
        if (i == dense or acc_d >= target_spacing
                or acc_a >= limit * ACTIVE_TURN_SCALE[0]):
            ts.append(i / float(dense))
            acc_d, acc_a = 0.0, 0.0
    return ts


def smooth_path(points, target_spacing, max_turn_deg=None):
    if len(points) < 3 or target_spacing <= 0:
        return points[:]

    padded = ([points[0] * 2.0 - points[1]] + points
              + [points[-1] * 2.0 - points[-2]])
    result = [points[0]]
    for i in range(1, len(padded) - 2):
        p0, p1, p2, p3 = padded[i - 1], padded[i], padded[i + 1], padded[i + 2]
        seg_len = (p2 - p1).length
        if seg_len < 1e-6:
            continue
        kn = cr_knots(p0, p1, p2, p3)
        for t in _segment_t_values(p0, p1, p2, p3, target_spacing, max_turn_deg, kn):
            result.append(catmull_rom_point(p0, p1, p2, p3, t, kn))
    return result


def smooth_path_with_widths(points, widths, target_spacing, depths=None, max_turn_deg=None):
    if len(points) < 3 or target_spacing <= 0:
        if depths is None:
            return points[:], widths[:]
        return points[:], widths[:], depths[:]

    padded_p = ([points[0] * 2.0 - points[1]] + points
                + [points[-1] * 2.0 - points[-2]])
    padded_w = [widths[0]] + widths + [widths[-1]]
    padded_d = ([depths[0]] + depths + [depths[-1]]) if depths is not None else None
    result_p = [points[0]]
    result_w = [widths[0]]
    result_d = [depths[0]] if depths is not None else None
    for i in range(1, len(padded_p) - 2):
        p0, p1, p2, p3 = padded_p[i - 1], padded_p[i], padded_p[i + 1], padded_p[i + 2]
        w0, w1, w2, w3 = padded_w[i - 1], padded_w[i], padded_w[i + 1], padded_w[i + 2]
        if depths is not None:
            d0, d1, d2, d3 = padded_d[i - 1], padded_d[i], padded_d[i + 1], padded_d[i + 2]
        seg_len = (p2 - p1).length
        if seg_len < 1e-6:
            continue
        kn = cr_knots(p0, p1, p2, p3)
        for t in _segment_t_values(p0, p1, p2, p3, target_spacing, max_turn_deg, kn):
            result_p.append(catmull_rom_point(p0, p1, p2, p3, t, kn))
            result_w.append(catmull_rom_point(w0, w1, w2, w3, t, kn))
            if depths is not None:
                result_d.append(catmull_rom_point(d0, d1, d2, d3, t, kn))
    if depths is None:
        return result_p, result_w
    return result_p, result_w, result_d


def is_closed_loop(points, tol=CLOSE_LOOP_TOLERANCE):
    return len(points) >= 3 and (points[0] - points[-1]).length < tol


def _tangents_for(road, points):
    tans = compute_tangents(points)
    explicit = road.get("section_tangents")
    if explicit and len(explicit) == len(tans):
        return [e if e is not None else t for e, t in zip(explicit, tans)]
    return tans


FOLD_GUARD = True
FOLD_GUARD_EPS = 1e-4
MESHROAD_MIN_EDGE_ADVANCE_FRAC = 0.20


def _offset_advances(points, tangents, offsets, j, i, min_frac=0.0):
    tj, ti = tangents[j], tangents[i]
    need = FOLD_GUARD_EPS
    if min_frac > 0.0:
        d = points[i] - points[j]
        need = max(need, min_frac * math.hypot(d.x, d.y))
    for s in (-1.0, 1.0):
        oj, oi = s * offsets[j], s * offsets[i]
        dx = (points[i].x - ti.y * oi) - (points[j].x - tj.y * oj)
        dy = (points[i].y + ti.x * oi) - (points[j].y + tj.x * oj)
        if dx * tj.x + dy * tj.y <= need:
            return False
        if dx * ti.x + dy * ti.y <= need:
            return False
    return True


def non_folding_keep(points, tangents, offsets, closed=False, forced=None, min_frac=0.0):
    n = len(points)
    if n < 3 or not offsets or len(offsets) != n:
        return list(range(n))
    keep = [0]
    for i in range(1, n):
        j = keep[-1]
        if (forced and forced[i]) or _offset_advances(points, tangents, offsets, j, i, min_frac):
            keep.append(i)
        elif i == n - 1 and not closed:
            if len(keep) > 1 and not (forced and forced[j]):
                keep[-1] = i
            else:
                keep.append(i)
    if closed:
        while len(keep) > 3 and not _offset_advances(points, tangents, offsets, keep[-1], keep[0], min_frac):
            if forced and forced[keep[-1]]:
                break
            keep.pop()
    return keep


MESHROAD_MIN_RADIUS_MARGIN = 1.5
MESHROAD_RELAX_ITERS = 400

MESHROAD_SWEPT_MIN_RATIO = 1.20
MESHROAD_MARGIN_GROWTH = 1.12
MESHROAD_RELAX_ROUNDS = 12
MESHROAD_MAX_RELAX_DISP_HW = 0.75


def _xy_radius(a, b, c):
    ar = abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2.0
    A, B, C = (b - a).length, (c - b).length, (c - a).length
    if ar < 1e-12 or A < 1e-9 or B < 1e-9:
        return float("inf")
    return A * B * C / (4.0 * ar)


def relax_tight_corners(points, widths, margin=MESHROAD_MIN_RADIUS_MARGIN,
                        max_iter=MESHROAD_RELAX_ITERS):
    n = len(points)
    if n < 3 or not widths:
        return points, 0.0, 0
    pts = [Vector((p.x, p.y, p.z)) for p in points]
    orig = [Vector((p.x, p.y, p.z)) for p in points]

    used = 0
    for _ in range(max_iter):
        bad = []
        for i in range(1, n - 1):
            hw = (widths[i] if i < len(widths) else widths[-1]) / 2.0
            if hw > 1e-6 and _xy_radius(pts[i - 1], pts[i], pts[i + 1]) < hw * margin:
                bad.append(i)
        if not bad:
            break
        idx = sorted({j for i in bad for j in (i - 1, i, i + 1) if 0 < j < n - 1})
        upd = {}
        for i in idx:
            mid = (pts[i - 1] + pts[i + 1]) * 0.5
            upd[i] = Vector((pts[i].x + (mid.x - pts[i].x) * 0.25,
                             pts[i].y + (mid.y - pts[i].y) * 0.25,
                             pts[i].z))
        for i, v in upd.items():
            pts[i] = v
        used += 1
    disp = max((pts[i] - orig[i]).length for i in range(n))
    return pts, disp, used


def _reparam_vertical(orig, moved, widths=None, depths=None):
    def cum(p):
        s = [0.0]
        for i in range(1, len(p)):
            d = p[i] - p[i - 1]
            s.append(s[-1] + math.hypot(d.x, d.y))
        return s
    if len(orig) != len(moved) or len(orig) < 2:
        return moved, widths, depths
    so, sn = cum(orig), cum(moved)
    if so[-1] < 1e-9 or sn[-1] < 1e-9:
        return moved, widths, depths
    has_w = widths is not None and len(widths) == len(orig)
    has_d = depths is not None and len(depths) == len(orig)
    out_p, out_w, out_d, j = [], [], [], 1
    for i, p in enumerate(moved):
        t = sn[i] / sn[-1] * so[-1]
        while j < len(so) - 1 and so[j] < t:
            j += 1
        a, b = j - 1, j
        span = so[b] - so[a]
        f = 0.0 if span < 1e-12 else (t - so[a]) / span
        out_p.append(Vector((p.x, p.y, orig[a].z + (orig[b].z - orig[a].z) * f)))
        if has_w:
            out_w.append(widths[a] + (widths[b] - widths[a]) * f)
        if has_d:
            out_d.append(depths[a] + (depths[b] - depths[a]) * f)
    return out_p, (out_w if has_w else widths), (out_d if has_d else depths)


def _min_radius_ratio(points, widths):
    worst, at = float("inf"), None
    for i in range(1, len(points) - 1):
        hw = (widths[i] if widths and i < len(widths) else 0.0) / 2.0
        if hw <= 1e-6:
            continue
        r = _xy_radius(points[i - 1], points[i], points[i + 1]) / hw
        if r < worst:
            worst, at = r, points[i]
    return worst, at


def _swept_ratio(points, widths, depths, spacing, max_turn_deg=None):
    if len(points) < 3:
        return float("inf"), None
    if depths is not None:
        dense, dwid, _ = smooth_path_with_widths(points, widths, spacing, depths=depths,
                                                 max_turn_deg=max_turn_deg)
    else:
        dense, dwid = smooth_path_with_widths(points, widths, spacing,
                                              max_turn_deg=max_turn_deg)
    return _min_radius_ratio(dense, dwid)


def _dup_sharp(points, widths, depths, sharp):
    cp, cw, cd = [], [], []
    for i, p in enumerate(points):
        reps = 2 if (0 < i < len(points) - 1 and sharp[i]) else 1
        for _ in range(reps):
            cp.append(p)
            cw.append(widths[i])
            if depths is not None:
                cd.append(depths[i])
    return cp, cw, (cd if depths is not None else None)


def _dedupe(points, widths, depths):
    op, ow, od = [points[0]], [widths[0]], ([depths[0]] if depths is not None else None)
    for i in range(1, len(points)):
        if (points[i] - op[-1]).length <= 1e-6:
            continue
        op.append(points[i])
        ow.append(widths[i])
        if od is not None:
            od.append(depths[i])
    return op, ow, od


def sharpen_unroundable_corners(points, widths, depths, spacing, max_turn_deg, ratio):
    n = len(points)
    sharp = [False] * n
    if n < 3:
        return points, widths, depths, 0
    for _ in range(n):
        cp, cw, cd = _dup_sharp(points, widths, depths, sharp)
        if cd is not None:
            dn, dw, _dd = smooth_path_with_widths(cp, cw, spacing, depths=cd,
                                                  max_turn_deg=max_turn_deg)
        else:
            dn, dw = smooth_path_with_widths(cp, cw, spacing, max_turn_deg=max_turn_deg)
        dn, dw, _x = _dedupe(dn, dw, None)
        worst, at = float("inf"), None
        for k in range(1, len(dn) - 1):
            hw = (dw[k] if dw else 0.0) / 2.0
            if hw <= 1e-6:
                continue
            near = min((abs((dn[k] - points[m]).x) + abs((dn[k] - points[m]).y), m)
                       for m in range(1, n - 1) if not sharp[m])[1] \
                if any(not sharp[m] for m in range(1, n - 1)) else None
            if near is None:
                continue
            if (dn[k] - points[near]).length > spacing * 3.0:
                continue
            r = _xy_radius(dn[k - 1], dn[k], dn[k + 1]) / hw
            if r < worst:
                worst, at = r, near
        if at is None or worst >= ratio:
            break
        sharp[at] = True
    count = sum(1 for v in sharp if v)
    if not count:
        return points, widths, depths, 0
    cp, cw, cd = _dup_sharp(points, widths, depths, sharp)
    return cp, cw, cd, count


def relax_for_swept_path(points, widths, depths, spacing, max_turn_deg=None):
    if len(points) < 3 or not widths:
        return points, widths, depths, 0.0, 0, float("inf"), None
    ratio, at = _swept_ratio(points, widths, depths, spacing, max_turn_deg)
    best = (points, widths, depths, 0.0, 0)
    if ratio >= MESHROAD_SWEPT_MIN_RATIO:
        return best + (ratio, at)
    disp_cap = MESHROAD_MAX_RELAX_DISP_HW * (max(widths) / 2.0)
    margin = MESHROAD_MIN_RADIUS_MARGIN
    for _ in range(max(1, MESHROAD_RELAX_ROUNDS)):
        relaxed, disp, iters = relax_tight_corners(points, widths, margin=margin)
        if disp > disp_cap:
            break
        moved, w, d = _reparam_vertical(points, relaxed, widths, depths)
        r, a = _swept_ratio(moved, w, d, spacing, max_turn_deg)
        if r > ratio:
            best, ratio, at = (moved, w, d, disp, iters), r, a
        if r >= MESHROAD_SWEPT_MIN_RATIO:
            break
        margin *= MESHROAD_MARGIN_GROWTH
    return best + (ratio, at)


MESHROAD_SHARP_CORNERS = True
MESHROAD_SHARP_RATIO = 1.0
MITER_COMPENSATION = True
MITER_LIMIT = 3.0

MESHROAD_WIDTH_CLAMP = True
MESHROAD_WIDTH_LIPSCHITZ = 0.35
MESHROAD_MIN_HALF_WIDTH = 0.35
MESHROAD_WIDTH_CLAMP_HEADROOM = 1.10


def _width_clamp_ratio():
    frac = min(0.9, max(0.0, MESHROAD_MIN_EDGE_ADVANCE_FRAC))
    guard = MESHROAD_WIDTH_CLAMP_HEADROOM / max(1e-6, 1.0 - frac)
    return max(MESHROAD_SWEPT_MIN_RATIO, guard)


def clamp_widths_to_radius(points, widths, closed=False, ratio=None,
                           slope=None, floor_hw=None):
    n = len(points)
    if n < 3 or not widths or len(widths) != n:
        return widths, 0.0
    ratio = _width_clamp_ratio() if ratio is None else ratio
    slope = MESHROAD_WIDTH_LIPSCHITZ if slope is None else slope
    floor_hw = MESHROAD_MIN_HALF_WIDTH if floor_hw is None else floor_hw
    hw = []
    for i in range(n):
        if closed:
            a, b, c = points[i - 1], points[i], points[(i + 1) % n]
        elif i == 0:
            a, b, c = points[0], points[1], points[2]
        elif i == n - 1:
            a, b, c = points[n - 3], points[n - 2], points[n - 1]
        else:
            a, b, c = points[i - 1], points[i], points[i + 1]
        cap = _xy_radius(a, b, c) / ratio if ratio > 0 else float("inf")
        hw.append(max(floor_hw, min(widths[i] / 2.0, cap)))
    seg = [0.0] * n
    for i in range(1, n):
        d = points[i] - points[i - 1]
        seg[i] = math.hypot(d.x, d.y)
    wrap = 0.0
    if closed:
        d = points[0] - points[-1]
        wrap = math.hypot(d.x, d.y)
    for _ in range(3 if closed else 1):
        for i in range(1, n):
            hw[i] = min(hw[i], hw[i - 1] + slope * seg[i])
        for i in range(n - 2, -1, -1):
            hw[i] = min(hw[i], hw[i + 1] + slope * seg[i + 1])
        if closed:
            hw[0] = min(hw[0], hw[-1] + slope * wrap)
            hw[-1] = min(hw[-1], hw[0] + slope * wrap)
    out = [2.0 * v for v in hw]
    worst = max((widths[i] - out[i]) / 2.0 for i in range(n))
    return out, worst


def report_min_radius(name, points, widths, closed=False):
    n = len(points)
    if n < 3:
        return
    rows = []
    for i in range(n if closed else 1, n if closed else n - 1):
        a, b, c = points[i - 1], points[i], points[(i + 1) % n]
        A = (b - a).length
        B = (c - b).length
        C = (c - a).length
        ar = abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2.0
        if ar < 1e-12 or A < 1e-9 or B < 1e-9:
            continue
        R = A * B * C / (4.0 * ar)
        hw = (widths[i] if widths and i < len(widths) else 0.0) / 2.0
        if hw > 1e-6:
            rows.append((R / hw, R, hw, b))
    if not rows:
        return
    rows.sort(key=lambda r: r[0])
    if rows[0][0] < 3.0:
        print(f"  [radius] '{name}': tightest corners (radius / half-width ratio)")
        for ratio, R, hw, p in rows[:5]:
            flag = "  <-- below 1: the inner edge folds over" if ratio < 1.0 else ""
            print(f"           ratio {ratio:5.2f}   R={R:6.2f} m  half-width={hw:4.2f} "
                  f"at ({p.x:.2f}, {p.y:.2f}){flag}")


def tangent3d(points, i, closed=False):
    n = len(points)
    if n < 2:
        return Vector((1.0, 0.0, 0.0))
    if closed:
        d = points[(i + 1) % n] - points[i - 1]
    elif i == 0:
        d = points[1] - points[0]
    elif i == n - 1:
        d = points[i] - points[i - 1]
    else:
        d = points[i + 1] - points[i - 1]
    return d.normalized() if d.length > 1e-9 else Vector((1.0, 0.0, 0.0))


def meshroad_ups(raw_nodes):
    out = []
    for raw in raw_nodes:
        if len(raw) < 8:
            out.append(Vector((0.0, 0.0, 1.0)))
            continue
        up = Vector((float(raw[5]), float(raw[6]), float(raw[7])))
        out.append(up.normalized() if up.length > 1e-6 else Vector((0.0, 0.0, 1.0)))
    return out


def up_at(ups, dists, s):
    if not ups:
        return Vector((0.0, 0.0, 1.0))
    if len(ups) == 1 or not dists:
        return ups[0]
    if s <= dists[0]:
        return ups[0]
    for i in range(1, min(len(dists), len(ups))):
        if s <= dists[i]:
            span = dists[i] - dists[i - 1]
            f = 0.0 if span <= 1e-9 else (s - dists[i - 1]) / span
            v = ups[i - 1] * (1.0 - f) + ups[i] * f
            return v.normalized() if v.length > 1e-6 else ups[i]
    return ups[min(len(ups), len(dists)) - 1]


def compute_tangents(points):
    n = len(points)
    tangents = []
    for i in range(n):
        a = b = None
        if i > 0:
            d = points[i] - points[i - 1]
            d = Vector((d.x, d.y, 0.0))
            a = d.normalized() if d.length > 1e-9 else None
        if i < n - 1:
            d = points[i + 1] - points[i]
            d = Vector((d.x, d.y, 0.0))
            b = d.normalized() if d.length > 1e-9 else None
        if a is not None and b is not None:
            d = a + b
            if d.length < 1e-9:
                d = b
        else:
            d = a if a is not None else b
        if d is None or d.length < 1e-9:
            d = Vector((1.0, 0.0, 0.0))
        tangents.append(d.normalized())
    return tangents


def cumulative_distances(points):
    dist = [0.0]
    for i in range(1, len(points)):
        dist.append(dist[-1] + (points[i] - points[i - 1]).length)
    return dist


STATS = {
    "pts_before": 0, "pts_after": 0,
    "faces_full": 0, "verts_full": 0,
    "faces_vis": 0, "verts_vis": 0,
    "faces_col": 0, "verts_col": 0,
    "quad_convex": 0, "quad_concave": 0,
    "quad_bowtie": 0, "quad_degenerate": 0,
    "faces_reoriented": 0,
    "col_ring_fallback": 0,
    "chamfer_gap": 0,
    "chamfer_down": 0,
    "cap_rings_dropped": 0,
    "col_degenerate_removed": 0,
    "col_faces_reoriented": 0,
}

DIAG_SAMPLES = []


def _pt_line_dist(p, a, b):
    ab = b - a
    l2 = ab.dot(ab)
    if l2 < 1e-12:
        return (p - a).length
    s = max(0.0, min(1.0, (p - a).dot(ab) / l2))
    return (p - (a + ab * s)).length


def _simplify_indices(points, widths, heights, tol, forced, max_span, max_turn_deg=180.0):
    n = len(points)
    if n < 3 or tol <= 0:
        return list(range(n))

    turn_prefix = [0.0] * n
    for k in range(1, n - 1):
        d0 = points[k] - points[k - 1]
        d1 = points[k + 1] - points[k]
        f0, f1 = d0, d1
        ang = 0.0
        if f0.length > 1e-9 and f1.length > 1e-9:
            c = f0.dot(f1) / (f0.length * f1.length)
            ang = math.degrees(math.acos(max(-1.0, min(1.0, c))))
        turn_prefix[k] = turn_prefix[k - 1] + ang
    turn_prefix[n - 1] = turn_prefix[n - 2]

    def ok(i, j):
        a, b = points[i], points[j]
        if (b - a).length > max_span:
            return False
        if max_turn_deg < 180.0 and (turn_prefix[j - 1] - turn_prefix[i]) > max_turn_deg:
            return False
        span = float(j - i)
        for k in range(i + 1, j):
            if forced[k]:
                return False
            if _pt_line_dist(points[k], a, b) > tol:
                return False
            f = (k - i) / span
            if widths is not None:
                if abs(widths[k] - (widths[i] + (widths[j] - widths[i]) * f)) > tol:
                    return False
            if heights is not None:
                if abs(heights[k] - (heights[i] + (heights[j] - heights[i]) * f)) > tol:
                    return False
        return True

    keep = [0]
    i = 0
    while i < n - 1:
        best = i + 1
        j = i + 2
        while j <= n - 1 and ok(i, j):
            best = j
            j += 1
        keep.append(best)
        i = best
    return keep


def _signed_area_2d(pts):
    s = 0.0
    n = len(pts)
    for i in range(n):
        x1, y1 = pts[i][0], pts[i][1]
        x2, y2 = pts[(i + 1) % n][0], pts[(i + 1) % n][1]
        s += x1 * y2 - x2 * y1
    return s / 2.0


def _unit2(dx, dy):
    L = math.hypot(dx, dy)
    return (dx / L, dy / L) if L > 1e-9 else None


class _PolyIndex:

    __slots__ = ("poly", "n", "edges", "minx", "miny", "cs", "nx", "ny",
                 "cells", "rows")

    def __init__(self, poly):
        n = len(poly)
        self.poly = poly
        self.n = n
        edges = []
        for i in range(n):
            a, b = poly[i], poly[(i + 1) % n]
            edges.append((a[0], a[1], b[0], b[1]))
        self.edges = edges
        if n == 0:
            self.minx = self.miny = 0.0
            self.cs = 1.0
            self.nx = self.ny = 1
            self.cells = [[]]
            self.rows = [[]]
            return

        xs = [p[0] for p in poly]
        ys = [p[1] for p in poly]
        minx, maxx = min(xs), max(xs)
        miny, maxy = min(ys), max(ys)
        w = max(maxx - minx, 1e-9)
        h = max(maxy - miny, 1e-9)
        cs = math.sqrt(w * h / max(n, 1))
        if not (cs > 1e-12):
            cs = max(w, h)
        nx = int(w / cs) + 1
        ny = int(h / cs) + 1
        if nx > 512:
            nx = 512
        if ny > 512:
            ny = 512
        cs = max(w / nx, h / ny, 1e-12)
        nx = min(512, int(w / cs) + 1)
        ny = min(512, int(h / cs) + 1)

        self.minx, self.miny, self.cs, self.nx, self.ny = minx, miny, cs, nx, ny
        cells = [[] for _ in range(nx * ny)]
        rows = [[] for _ in range(ny)]
        for e in edges:
            ax, ay, bx, by = e
            ix0 = int((min(ax, bx) - minx) / cs)
            ix1 = int((max(ax, bx) - minx) / cs)
            iy0 = int((min(ay, by) - miny) / cs)
            iy1 = int((max(ay, by) - miny) / cs)
            ix0 = 0 if ix0 < 0 else (nx - 1 if ix0 > nx - 1 else ix0)
            ix1 = 0 if ix1 < 0 else (nx - 1 if ix1 > nx - 1 else ix1)
            iy0 = 0 if iy0 < 0 else (ny - 1 if iy0 > ny - 1 else iy0)
            iy1 = 0 if iy1 < 0 else (ny - 1 if iy1 > ny - 1 else iy1)
            for iy in range(iy0, iy1 + 1):
                rows[iy].append(e)
                base = iy * nx
                for ix in range(ix0, ix1 + 1):
                    cells[base + ix].append(e)
        self.cells = cells
        self.rows = rows

    def contains(self, p):
        if self.n == 0:
            return False
        y = p[1]
        iy = int((y - self.miny) / self.cs)
        if iy < 0:
            iy = 0
        elif iy > self.ny - 1:
            iy = self.ny - 1
        x = p[0]
        inside = False
        for x1, y1, x2, y2 in self.rows[iy]:
            if (y1 > y) != (y2 > y):
                if x1 + (y - y1) * (x2 - x1) / (y2 - y1) > x:
                    inside = not inside
        return inside

    def dist(self, p):
        if self.n == 0:
            return 1e18
        px, py = p[0], p[1]
        cs, nx, ny = self.cs, self.nx, self.ny
        cx = int((px - self.minx) / cs)
        cy = int((py - self.miny) / cs)
        if cx < 0:
            cx = 0
        elif cx > nx - 1:
            cx = nx - 1
        if cy < 0:
            cy = 0
        elif cy > ny - 1:
            cy = ny - 1

        best = 1e18
        cells = self.cells
        span = nx if nx > ny else ny
        r = 0
        while True:
            x0, x1 = cx - r, cx + r
            y0, y1 = cy - r, cy + r
            if r == 0:
                block = ((cx, cy),) if 0 <= cx < nx and 0 <= cy < ny else ()
            else:
                block = []
                for ix in range(x0, x1 + 1):
                    if 0 <= ix < nx:
                        if 0 <= y0 < ny:
                            block.append((ix, y0))
                        if 0 <= y1 < ny:
                            block.append((ix, y1))
                for iy in range(y0 + 1, y1):
                    if 0 <= iy < ny:
                        if 0 <= x0 < nx:
                            block.append((x0, iy))
                        if 0 <= x1 < nx:
                            block.append((x1, iy))
            for ix, iy in block:
                for ax, ay, bx, by in cells[iy * nx + ix]:
                    dx, dy = bx - ax, by - ay
                    l2 = dx * dx + dy * dy
                    if l2 < 1e-15:
                        d = math.hypot(px - ax, py - ay)
                    else:
                        s = (px - ax) * dx + (py - ay) * dy
                        s = s / l2
                        if s < 0.0:
                            s = 0.0
                        elif s > 1.0:
                            s = 1.0
                        d = math.hypot(px - (ax + dx * s), py - (ay + dy * s))
                    if d < best:
                        best = d
            lo_x = self.minx + (cx - r) * cs
            hi_x = self.minx + (cx + r + 1) * cs
            lo_y = self.miny + (cy - r) * cs
            hi_y = self.miny + (cy + r + 1) * cs
            reach = min(px - lo_x, hi_x - px, py - lo_y, hi_y - py)
            if best <= reach:
                break
            r += 1
            if r > span:
                break
        return best


def offset_polygon_inward(pts, dist):
    n = len(pts)
    ccw = _signed_area_2d(pts) > 0
    out = []
    for i in range(n):
        p_prev, p, p_next = pts[i - 1], pts[i], pts[(i + 1) % n]
        d0 = _unit2(p[0] - p_prev[0], p[1] - p_prev[1])
        d1 = _unit2(p_next[0] - p[0], p_next[1] - p[1])
        if d0 is None or d1 is None:
            out.append((p[0], p[1], p[2]))
            continue
        n0 = (-d0[1], d0[0]) if ccw else (d0[1], -d0[0])
        n1 = (-d1[1], d1[0]) if ccw else (d1[1], -d1[0])
        mx, my = n0[0] + n1[0], n0[1] + n1[1]
        L = math.hypot(mx, my)
        if L < 1e-9:
            out.append((p[0], p[1], p[2]))
            continue
        mx, my = mx / L, my / L
        cosv = mx * n1[0] + my * n1[1]
        step = dist / max(cosv, ISLAND_MITER_MIN_COS)
        if ISLAND_MITER_NEIGHBOR_RATIO > 0.0:
            near = min(math.hypot(p[0] - p_prev[0], p[1] - p_prev[1]),
                       math.hypot(p_next[0] - p[0], p_next[1] - p[1]))
            step = min(step, max(dist, near * ISLAND_MITER_NEIGHBOR_RATIO))
        out.append((p[0] + mx * step, p[1] + my * step, p[2]))
    return out


def fit_inner_ring(outer, cand, target):
    n = len(outer)
    idx = _PolyIndex(outer)
    dirs, lens, samples = [], [], []
    for p, q in zip(outer, cand):
        vx, vy = q[0] - p[0], q[1] - p[1]
        L = math.hypot(vx, vy)
        if L < 1e-9:
            dirs.append((0.0, 0.0))
            lens.append(0.0)
            samples.append([])
            continue
        ux, uy = vx / L, vy / L
        dirs.append((ux, uy))
        lens.append(L)
        probe_d = target / 0.45
        c_full = (p[0] + vx, p[1] + vy, q[2])
        c_probe = (p[0] + ux * probe_d, p[1] + uy * probe_d, q[2])
        if (idx.contains(c_full) and idx.dist(c_full) >= target * 0.999
                and idx.contains(c_probe)
                and idx.dist(c_probe) >= target * 0.999):
            samples.append(None)
            continue
        row = []
        for k in range(1, 41):
            d_along = L * 4.0 * k / 40.0
            c = (p[0] + vx / L * d_along, p[1] + vy / L * d_along, q[2])
            if not idx.contains(c):
                break
            row.append((d_along, idx.dist(c)))
        samples.append(row)

    want = []
    for row in samples:
        if row is None:
            want.append(target)
            continue
        h = max((d for _, d in row), default=0.0)
        want.append(min(target, 0.45 * h) if h > 0 else 0.0)

    seg = [math.hypot(outer[(i + 1) % n][0] - outer[i][0],
                      outer[(i + 1) % n][1] - outer[i][1]) for i in range(n)]
    for _ in range(2):
        for i in range(n):
            j = (i + 1) % n
            want[j] = min(want[j], want[i] + seg[i])
        for i in range(n - 1, -1, -1):
            j = (i + 1) % n
            want[i] = min(want[i], want[j] + seg[i])

    out = []
    n_narrow = 0
    for i in range(n):
        p, w, row = outer[i], want[i], samples[i]
        if row is None and w >= target * 0.999:
            out.append(cand[i])
            continue
        if row is None:
            row = []
            for k in range(1, 41):
                d_along = lens[i] * 4.0 * k / 40.0
                c = (p[0] + dirs[i][0] * d_along, p[1] + dirs[i][1] * d_along, cand[i][2])
                if not idx.contains(c):
                    break
                row.append((d_along, idx.dist(c)))
        if not row or w <= 1e-6:
            out.append((p[0] + dirs[i][0] * 0.01, p[1] + dirs[i][1] * 0.01, cand[i][2]))
            n_narrow += 1
            continue
        if w < target * 0.999:
            n_narrow += 1
        lo, hi = 0.0, row[-1][0]
        for d_along, d_edge in row:
            if d_edge >= w:
                hi = d_along
                break
            lo = d_along
        for _ in range(12):
            mid = (lo + hi) / 2.0
            c = (p[0] + dirs[i][0] * mid, p[1] + dirs[i][1] * mid, cand[i][2])
            if idx.contains(c) and idx.dist(c) >= w:
                hi = mid
            else:
                lo = mid
        out.append((p[0] + dirs[i][0] * hi, p[1] + dirs[i][1] * hi, cand[i][2]))
    return out, n_narrow


def _coverage(ring, tris):
    total = abs(_signed_area_2d(ring))
    if total < 1e-9:
        return 0.0
    got = sum(abs(_signed_area_2d([ring[a], ring[b], ring[c]])) for a, b, c in tris)
    return got / total


def triangulate_polygon(pts):
    n = len(pts)
    if n < 3:
        return []
    order = list(range(n))
    if _signed_area_2d(pts) < 0:
        order.reverse()
    m = len(order)

    prv = [(i - 1) % m for i in range(m)]
    nxt = [(i + 1) % m for i in range(m)]
    alive = [True] * m

    def P(i):
        return pts[order[i]]

    def area2(a, b, c):
        return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])

    def in_tri(p, a, b, c):
        return (area2(a, b, p) >= -1e-12 and area2(b, c, p) >= -1e-12
                and area2(c, a, p) >= -1e-12)

    def cost(i):
        a, b, c = P(prv[i]), P(i), P(nxt[i])
        return max(math.hypot(b[0] - a[0], b[1] - a[1]),
                   math.hypot(c[0] - b[0], c[1] - b[1]),
                   math.hypot(a[0] - c[0], a[1] - c[1]))

    def is_ear(i):
        a, b, c = P(prv[i]), P(i), P(nxt[i])
        if area2(a, b, c) <= 1e-12:
            return False
        j = nxt[nxt[i]]
        while j != prv[i]:
            if in_tri(P(j), a, b, c):
                return False
            j = nxt[j]
        return True

    cur = {i: cost(i) for i in range(m)}
    heap = [(cur[i], i) for i in range(m)]
    heapq.heapify(heap)
    tris = []
    remaining = m
    guard = 0

    while remaining > 3 and guard < 8 * m + 64:
        guard += 1
        pending = []
        chosen = None
        tries = 0
        while heap:
            c, i = heapq.heappop(heap)
            if not alive[i] or abs(cur.get(i, -1.0) - c) > 1e-9:
                continue
            tries += 1
            if tries > 60 or is_ear(i):
                chosen = i
                break
            pending.append((c, i))
        for e in pending:
            heapq.heappush(heap, e)
        if chosen is None:
            break
        a, b = prv[chosen], nxt[chosen]
        tris.append((order[a], order[chosen], order[b]))
        alive[chosen] = False
        nxt[a] = b
        prv[b] = a
        remaining -= 1
        for k in (a, b):
            cur[k] = cost(k)
            heapq.heappush(heap, (cur[k], k))

    if remaining == 3:
        i = next(k for k in range(m) if alive[k])
        tris.append((order[prv[i]], order[i], order[nxt[i]]))
    return tris


def mark_joined_ends(roads):
    if not SUPPRESS_CAPS_AT_JUNCTIONS:
        return 0

    ends = []
    for rd in roads:
        if rd.get("source") == "island" or not rd.get("nodes"):
            continue
        if ROUND_ENDS_SOURCES and rd.get("source") not in ROUND_ENDS_SOURCES:
            continue
        nodes = rd["nodes"]
        if len(nodes) < 2:
            continue
        ends.append((rd, "no_cap_start", (nodes[0]["x"], nodes[0]["y"])))
        ends.append((rd, "no_cap_end", (nodes[-1]["x"], nodes[-1]["y"])))

    tol = JUNCTION_CAP_TOLERANCE
    marked = 0
    for i in range(len(ends)):
        rd_i, key_i, p_i = ends[i]
        for j in range(i + 1, len(ends)):
            rd_j, key_j, p_j = ends[j]
            if rd_i is rd_j:
                continue
            if math.hypot(p_i[0] - p_j[0], p_i[1] - p_j[1]) > tol:
                continue
            for rd, key in ((rd_i, key_i), (rd_j, key_j)):
                if not rd.get(key):
                    rd[key] = True
                    marked += 1
    return marked


def _end_info(rd, at_end):
    nodes = rd["nodes"]
    tip = nodes[-1] if at_end else nodes[0]
    p = (tip["x"], tip["y"])
    seq = list(reversed(nodes)) if at_end else nodes
    probe = max(0.05, ZEBRA_FILLET_TANGENT_PROBE)
    acc = 0.0
    ref = None
    for k in range(1, len(seq)):
        q = (seq[k]["x"], seq[k]["y"])
        acc += math.hypot(q[0] - seq[k-1]["x"], q[1] - seq[k-1]["y"])
        ref = q
        if acc >= probe:
            break
    if ref is None:
        return None
    d = (p[0] - ref[0], p[1] - ref[1])
    L = math.hypot(*d)
    if L < 1e-9:
        return None
    return p, (d[0] / L, d[1] / L), tip


def _offset_polyline(points, widths, side):
    tans = compute_tangents(points)
    out = []
    for p, tn, w in zip(points, tans, widths):
        nrm = (-tn.y, tn.x)
        out.append((p.x + nrm[0] * side * w / 2.0,
                    p.y + nrm[1] * side * w / 2.0, p.z))
    return out


def _polyline_cross(pa, pb):
    for i in range(len(pa) - 1):
        a0, a1 = pa[i], pa[i + 1]
        d1 = (a1[0] - a0[0], a1[1] - a0[1])
        for j in range(len(pb) - 1):
            b0, b1 = pb[j], pb[j + 1]
            d2 = (b1[0] - b0[0], b1[1] - b0[1])
            den = d1[0] * d2[1] - d1[1] * d2[0]
            if abs(den) < 1e-12:
                continue
            dx, dy = b0[0] - a0[0], b0[1] - a0[1]
            s = (dx * d2[1] - dy * d2[0]) / den
            u = (dx * d1[1] - dy * d1[0]) / den
            if -1e-9 <= s <= 1 + 1e-9 and -1e-9 <= u <= 1 + 1e-9:
                return ((a0[0] + d1[0] * s, a0[1] + d1[1] * s,
                         a0[2] + (a1[2] - a0[2]) * s), i, j)
    return None


def _arc_points(center, p_from, p_to, z, max_turn_deg, through=None):
    a0 = math.atan2(p_from[1] - center[1], p_from[0] - center[0])
    a1 = math.atan2(p_to[1] - center[1], p_to[0] - center[0])
    r0 = math.hypot(p_from[0] - center[0], p_from[1] - center[1])
    r1 = math.hypot(p_to[0] - center[0], p_to[1] - center[1])
    if through is not None:
        at = math.atan2(through[1] - center[1], through[0] - center[0])
        span = (a1 - a0) % (2 * math.pi)
        rel = (at - a0) % (2 * math.pi)
        d = span if rel < span else span - 2 * math.pi
    else:
        d = a1 - a0
        while d > math.pi:
            d -= 2 * math.pi
        while d < -math.pi:
            d += 2 * math.pi
    steps = max(2, int(math.ceil(abs(math.degrees(d)) / max(0.5, max_turn_deg))))
    pts = []
    for k in range(1, steps):
        f = k / steps
        ang = a0 + d * f
        r = r0 + (r1 - r0) * f
        pts.append((center[0] + math.cos(ang) * r, center[1] + math.sin(ang) * r, z))
    return pts


def round_reflex_corners(ring, radius, min_turn_deg=45.0):
    n = len(ring)
    if n < 4 or radius <= 0:
        return ring
    ccw = _signed_area_2d(ring) > 0
    out = []
    for i in range(n):
        a, p, b = ring[i - 1], ring[i], ring[(i + 1) % n]
        d0 = _unit2(p[0] - a[0], p[1] - a[1])
        d1 = _unit2(b[0] - p[0], b[1] - p[1])
        if d0 is None or d1 is None:
            out.append(p)
            continue
        crossz = d0[0] * d1[1] - d0[1] * d1[0]
        if (crossz > 0) == ccw:
            out.append(p)
            continue
        cosv = max(-1.0, min(1.0, d0[0] * d1[0] + d0[1] * d1[1]))
        turn = math.degrees(math.acos(cosv))
        if turn < min_turn_deg:
            out.append(p)
            continue
        half = math.radians((180.0 - turn) / 2.0)
        if math.tan(half) < 1e-6:
            out.append(p)
            continue
        tlen = radius / math.tan(half)
        la = math.hypot(p[0] - a[0], p[1] - a[1])
        lb = math.hypot(b[0] - p[0], b[1] - p[1])
        tlen = min(tlen, la * 0.45, lb * 0.45)
        if tlen < 1e-4:
            out.append(p)
            continue
        s = (p[0] - d0[0] * tlen, p[1] - d0[1] * tlen, p[2])
        e = (p[0] + d1[0] * tlen, p[1] + d1[1] * tlen, p[2])
        mx, my = d0[0] - d1[0], d0[1] - d1[1]
        L = math.hypot(mx, my)
        if L < 1e-9:
            out.append(p)
            continue
        r_eff = tlen * math.tan(half)
        cx = p[0] + (mx / L) * (r_eff / math.sin(half))
        cy = p[1] + (my / L) * (r_eff / math.sin(half))
        out.append(s)
        out.extend(_arc_points((cx, cy), s, e, p[2], ZEBRA_FILLET_MAX_TURN_DEG))
        out.append(e)
    return out


def round_polyline_corners(ring, radius, min_turn_deg, convex_only=True):
    n = len(ring)
    if n < 3 or radius <= 0:
        return ring
    ccw = _signed_area_2d(ring) > 0

    seg = [math.hypot(ring[(i + 1) % n][0] - ring[i][0],
                      ring[(i + 1) % n][1] - ring[i][1]) for i in range(n)]
    total = sum(seg)
    if total < 1e-6:
        return ring
    arc_at = [0.0] * n
    for i in range(1, n):
        arc_at[i] = arc_at[i - 1] + seg[i - 1]

    corners = []
    for i in range(n):
        a, p, b = ring[i - 1], ring[i], ring[(i + 1) % n]
        d0 = _unit2(p[0] - a[0], p[1] - a[1])
        d1 = _unit2(b[0] - p[0], b[1] - p[1])
        if d0 is None or d1 is None:
            continue
        crossz = d0[0] * d1[1] - d0[1] * d1[0]
        is_convex = (crossz > 0) == ccw
        if convex_only and not is_convex:
            continue
        cosv = max(-1.0, min(1.0, d0[0] * d1[0] + d0[1] * d1[1]))
        turn = math.degrees(math.acos(cosv))
        if turn < min_turn_deg:
            continue
        corners.append((i, turn, is_convex))
    if not corners:
        return ring

    trims = {}
    for k, (i, turn, is_convex) in enumerate(corners):
        half = math.radians((180.0 - turn) / 2.0)
        tlen = radius / max(math.tan(half), 1e-6)
        prev_i = corners[k - 1][0]
        next_i = corners[(k + 1) % len(corners)][0]
        gap_prev = (arc_at[i] - arc_at[prev_i]) % total
        gap_next = (arc_at[next_i] - arc_at[i]) % total
        if len(corners) == 1:
            gap_prev = gap_next = total
        tlen = min(tlen, gap_prev * 0.45, gap_next * 0.45, total * 0.3)
        if tlen > 1e-4:
            trims[i] = tlen

    if not trims:
        return ring

    def point_at(arc_s):
        s = arc_s % total
        for i in range(n):
            if s <= arc_at[i] + seg[i] + 1e-12:
                f = (s - arc_at[i]) / seg[i] if seg[i] > 1e-12 else 0.0
                f = max(0.0, min(1.0, f))
                a, b = ring[i], ring[(i + 1) % n]
                return (a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f,
                        a[2] + (b[2] - a[2]) * f)
        return ring[-1]

    dropped = set()
    for i, tlen in trims.items():
        for j in range(n):
            d = (arc_at[j] - arc_at[i] + total / 2.0) % total - total / 2.0
            if abs(d) <= tlen + 1e-9:
                dropped.add(j)

    out = []
    for i in range(n):
        if i in trims:
            p = ring[i]
            tlen = trims[i]
            s = point_at(arc_at[i] - tlen)
            e = point_at(arc_at[i] + tlen)
            d0 = _unit2(p[0] - s[0], p[1] - s[1])
            d1 = _unit2(e[0] - p[0], e[1] - p[1])
            if d0 is None or d1 is None:
                out.append(p)
                continue
            cosv = max(-1.0, min(1.0, d0[0] * d1[0] + d0[1] * d1[1]))
            half = (math.pi - math.acos(cosv)) / 2.0
            if math.sin(half) < 1e-6:
                out.append(p)
                continue
            r_eff = tlen * math.tan(half)
            mx, my = d1[0] - d0[0], d1[1] - d0[1]
            L = math.hypot(mx, my)
            if L < 1e-9:
                out.append(p)
                continue
            cx = p[0] + (mx / L) * (r_eff / math.sin(half))
            cy = p[1] + (my / L) * (r_eff / math.sin(half))
            out.append(s)
            out.extend(_arc_points((cx, cy), s, e, p[2], ZEBRA_FILLET_MAX_TURN_DEG))
            out.append(e)
        elif i not in dropped:
            out.append(ring[i])

    clean = []
    for p in out:
        if clean and math.hypot(p[0] - clean[-1][0], p[1] - clean[-1][1]) < 1e-4:
            continue
        clean.append(p)
    return clean if len(clean) >= 4 else ring


def hairpin_union_ring(rd_i, e_i, rd_j, e_j, tip):
    def ordered(rd, at_end):
        pts = [Vector((n["x"], n["y"], n["z"])) for n in rd["nodes"]]
        ws = list(rd["widths"])
        if not at_end:
            pts, ws = list(reversed(pts)), list(reversed(ws))
        return pts, ws

    pa, wa = ordered(rd_i, e_i)
    pb, wb = ordered(rd_j, e_j)
    if len(pa) < 2 or len(pb) < 2:
        return None

    hwa, hwb = wa[-1] / 2.0, wb[-1] / 2.0
    ratio = max(hwa, hwb) / max(min(hwa, hwb), 1e-6)
    if ratio > HAIRPIN_UNION_MAX_WIDTH_RATIO:
        return None

    da = Vector(((pa[-1] - pa[-2]).x, (pa[-1] - pa[-2]).y, 0.0)).normalized()
    db = Vector(((pb[-1] - pb[-2]).x, (pb[-1] - pb[-2]).y, 0.0)).normalized()
    crossz = da.x * db.y - da.y * db.x
    if abs(crossz) < 1e-6:
        return None
    side_a_out = -1 if crossz < 0 else 1
    side_b_out = -side_a_out

    a_out = _offset_polyline(pa, wa, side_a_out)
    a_in = _offset_polyline(pa, wa, -side_a_out)
    b_out = _offset_polyline(pb, wb, side_b_out)
    b_in = _offset_polyline(pb, wb, -side_b_out)

    hit = _polyline_cross(a_in, b_in)
    if hit is None:
        return None
    K, ia, ib = hit

    zt = pa[-1].z
    bis = (da + db).normalized()
    tip_via = (tip[0] + bis.x * hwa, tip[1] + bis.y * hwa)

    def free_cap(pts, ws, p_from, p_to):
        d0 = Vector(((pts[1] - pts[0]).x, (pts[1] - pts[0]).y, 0.0)).normalized()
        hw0 = ws[0] / 2.0
        c = (pts[0].x, pts[0].y)
        via = (c[0] - d0.x * hw0, c[1] - d0.y * hw0)
        return _arc_points(c, p_from, p_to, pts[0].z, ROUND_END_MAX_TURN_DEG, via)

    ring = list(a_out)
    ring += _arc_points(tip, a_out[-1], b_out[-1], zt, ROUND_END_MAX_TURN_DEG, tip_via)
    ring += list(reversed(b_out))
    if not rd_j.get("no_cap_start" if e_j else "no_cap_end"):
        ring += free_cap(pb, wb, b_out[0], b_in[0])
    ring += list(b_in[:ib + 1])
    ring.append(K)
    ring += list(reversed(a_in[:ia + 1]))
    if not rd_i.get("no_cap_start" if e_i else "no_cap_end"):
        ring += free_cap(pa, wa, a_in[0], a_out[0])

    clean = []
    for p in ring:
        if clean and math.hypot(p[0] - clean[-1][0], p[1] - clean[-1][1]) < 1e-6:
            continue
        clean.append(p)
    while len(clean) > 3 and math.hypot(clean[-1][0] - clean[0][0],
                                        clean[-1][1] - clean[0][1]) < 1e-6:
        clean.pop()
    if len(clean) < 4 or abs(_signed_area_2d(clean)) < ISLAND_MIN_AREA:
        return None
    return round_reflex_corners(clean, HAIRPIN_NOTCH_RADIUS)


def flush_hairpin_tips(roads):
    if not (FLUSH_HAIRPIN_TIPS and ROUND_OPEN_ENDS):
        return 0

    ends = []
    for rd in roads:
        if rd.get("source") == "island" or len(rd.get("nodes") or []) < 2:
            continue
        if ROUND_ENDS_SOURCES and rd.get("source") not in ROUND_ENDS_SOURCES:
            continue
        ends.append((rd, True))
        ends.append((rd, False))

    handled = 0
    pairs = []
    done = set()
    for i in range(len(ends)):
        rd_i, e_i = ends[i]
        if (id(rd_i), e_i) in done:
            continue
        for j in range(i + 1, len(ends)):
            rd_j, e_j = ends[j]
            if rd_i is rd_j or (id(rd_j), e_j) in done:
                continue
            info_i, info_j = _end_info(rd_i, e_i), _end_info(rd_j, e_j)
            if not info_i or not info_j:
                continue
            (pi, di, _), (pj, dj, _) = info_i, info_j
            if math.hypot(pi[0] - pj[0], pi[1] - pj[1]) > JUNCTION_CAP_TOLERANCE:
                continue

            cosv = max(-1.0, min(1.0, di[0] * -dj[0] + di[1] * -dj[1]))
            turn = math.degrees(math.acos(cosv))
            if turn <= ZEBRA_FILLET_MAX_CORNER_DEG:
                continue

            den = di[0] * dj[1] - di[1] * dj[0]
            if abs(den) < 1e-9:
                continue
            dx, dy = pj[0] - pi[0], pj[1] - pi[1]
            s = (dx * dj[1] - dy * dj[0]) / den
            u = (dx * di[1] - dy * di[0]) / den
            hw_i = (rd_i["widths"][-1 if e_i else 0]) / 2.0
            hw_j = (rd_j["widths"][-1 if e_j else 0]) / 2.0
            reach = HAIRPIN_MAX_EXTEND_RATIO * max(hw_i, hw_j)
            if not (0.0 < s <= reach and 0.0 < u <= reach):
                continue

            ix, iy = pi[0] + di[0] * s, pi[1] + di[1] * s

            def extend(rd, at_end, hw):
                node = dict(rd["nodes"][-1 if at_end else 0])
                node["x"], node["y"] = ix, iy
                if at_end:
                    rd["nodes"].append(node)
                    rd["widths"].append(hw * 2.0)
                else:
                    rd["nodes"].insert(0, node)
                    rd["widths"].insert(0, hw * 2.0)

            extend(rd_i, e_i, hw_i)
            extend(rd_j, e_j, hw_j)

            len_i = sum(math.hypot(rd_i["nodes"][k+1]["x"] - rd_i["nodes"][k]["x"],
                                   rd_i["nodes"][k+1]["y"] - rd_i["nodes"][k]["y"])
                        for k in range(len(rd_i["nodes"]) - 1))
            len_j = sum(math.hypot(rd_j["nodes"][k+1]["x"] - rd_j["nodes"][k]["x"],
                                   rd_j["nodes"][k+1]["y"] - rd_j["nodes"][k]["y"])
                        for k in range(len(rd_j["nodes"]) - 1))
            keep, keep_e, drop, drop_e = ((rd_i, e_i, rd_j, e_j) if len_i >= len_j
                                          else (rd_j, e_j, rd_i, e_i))
            keep["no_cap_end" if keep_e else "no_cap_start"] = False
            drop["no_cap_end" if drop_e else "no_cap_start"] = True

            done.add((id(rd_i), e_i))
            done.add((id(rd_j), e_j))
            pairs.append((rd_i, e_i, rd_j, e_j, (ix, iy)))
            handled += 1
            break
    return handled, pairs


def _cap_ellipse_shrink(a_out, b_out, adv):
    def shrink(s):
        a_s, b_s = a_out - s, b_out - s
        if a_s <= 1e-6 or b_s <= 0.0 or adv >= a_s:
            return 0.0
        return b_s * math.sqrt(max(0.0, 1.0 - (adv / a_s) ** 2))
    return shrink


def add_rounded_ends(points, tangents, dists, widths, heights, closed, source,
                     no_cap_start=False, no_cap_end=False):
    empty_caps = [None] * len(points)
    if closed or not ROUND_OPEN_ENDS:
        return points, tangents, dists, widths, heights, empty_caps
    if ROUND_ENDS_SOURCES and source not in ROUND_ENDS_SOURCES:
        return points, tangents, dists, widths, heights, empty_caps
    if len(points) < 2 or not widths or not heights:
        return points, tangents, dists, widths, heights, empty_caps
    if len(widths) != len(points) or len(heights) != len(points):
        return points, tangents, dists, widths, heights, empty_caps

    def fan(idx, direction):
        w0 = widths[idx]
        hw = w0 / 2.0
        if hw <= 1e-6:
            return []
        if ROUND_END_MAX_WIDTH is not None and w0 >= ROUND_END_MAX_WIDTH:
            return []

        tip = max(ROUND_END_TIP_WIDTH, 2.0 * CURB_STRIP + 0.01)
        tip = max(1e-4, min(tip, w0 * 0.9))
        theta_max = math.acos(max(-1.0, min(1.0, tip / w0)))
        steps = max(1, int(math.ceil(math.degrees(theta_max) / max(0.5, ROUND_END_MAX_TURN_DEG))))

        a_out = hw * ROUND_END_RADIUS_SCALE
        b_out = hw
        a_in = a_out - CURB_STRIP
        b_in = b_out - CURB_STRIP

        thetas = [theta_max * k / steps for k in range(1, steps + 1)]
        if 0.0 < a_in < a_out:
            th_close = math.asin(max(-1.0, min(1.0, a_in / a_out)))
            if 1e-4 < th_close < theta_max - 1e-4:
                thetas.append(th_close)
                thetas = sorted(set(round(x, 9) for x in thetas))

        min_step = max(2e-3, 0.01 * hw)
        keep = []
        p_adv, p_half = 0.0, hw
        for th in thetas:
            adv, half = a_out * math.sin(th), b_out * math.cos(th)
            if math.hypot(adv - p_adv, half - p_half) < min_step:
                STATS["cap_rings_dropped"] = STATS.get("cap_rings_dropped", 0) + 1
                continue
            keep.append(th)
            p_adv, p_half = adv, half
        if thetas and (not keep or keep[-1] != thetas[-1]):
            if keep:
                keep[-1] = thetas[-1]
            else:
                keep = [thetas[-1]]
        thetas = keep

        tan = tangents[idx]
        out = []
        arc = 0.0
        prev_adv, prev_half = 0.0, hw
        for th in thetas:
            adv = a_out * math.sin(th)
            half = b_out * math.cos(th)

            if a_in > 1e-6 and b_in > 0.0 and adv < a_in:
                inset = b_in * math.sqrt(max(0.0, 1.0 - (adv / a_in) ** 2))
            else:
                inset = 0.0
            inset = min(half * 0.999, max(inset, half * 0.005))

            arc += math.hypot(adv - prev_adv, half - prev_half)
            prev_adv, prev_half = adv, half

            out.append((
                points[idx] + tan * (direction * adv),
                tan,
                dists[idx] + direction * adv,
                2.0 * half,
                heights[idx],
                {"inset": inset, "uv_hw": hw, "uv_s": dists[idx] + direction * arc,
                 "shrink": _cap_ellipse_shrink(a_out, b_out, adv)},
            ))
        return out

    head = [] if no_cap_start else fan(0, -1)[::-1]
    tail = [] if no_cap_end else fan(len(points) - 1, 1)
    if not head and not tail:
        return points, tangents, dists, widths, heights, empty_caps

    return (
        [r[0] for r in head] + list(points) + [r[0] for r in tail],
        [r[1] for r in head] + list(tangents) + [r[1] for r in tail],
        [r[2] for r in head] + list(dists) + [r[2] for r in tail],
        [r[3] for r in head] + list(widths) + [r[3] for r in tail],
        [r[4] for r in head] + list(heights) + [r[4] for r in tail],
        [r[5] for r in head] + [None] * len(points) + [r[5] for r in tail],
    )


def apply_simplify(road, points, widths, heights):
    STATS["pts_before"] += len(points)
    if not SIMPLIFY_PATH or len(points) < 3:
        STATS["pts_after"] += len(points)
        return road, points, widths, heights

    forced = [False] * len(points)
    sec = road.get("section_tangents")
    has_sec = bool(sec) and len(sec) == len(points)
    if has_sec:
        for i, v in enumerate(sec):
            if v is not None:
                forced[i] = True

    w = widths if (widths is not None and len(widths) == len(points)) else None
    h = heights if (heights is not None and len(heights) == len(points)) else None

    keep = _simplify_indices(points, w, h, SIMPLIFY_TOLERANCE * ACTIVE_TURN_SCALE[0],
                             forced, SIMPLIFY_MAX_SPAN,
                             SIMPLIFY_MAX_TURN_DEG * ACTIVE_TURN_SCALE[0])
    STATS["pts_after"] += len(keep)
    if len(keep) == len(points):
        return road, points, widths, heights

    new_points = [points[i] for i in keep]
    new_widths = [widths[i] for i in keep] if w is not None else widths
    new_heights = [heights[i] for i in keep] if h is not None else heights
    if has_sec:
        road = dict(road)
        road["section_tangents"] = [sec[i] for i in keep]
    return road, new_points, new_widths, new_heights


def _polyline_length(pts):
    return sum((pts[i] - pts[i - 1]).length for i in range(1, len(pts)))


def _flat_dir(v):
    d = Vector((v.x, v.y, 0.0))
    if d.length < 1e-9:
        return Vector((1.0, 0.0, 0.0))
    return d.normalized()


def _dir_at_end(pts, probe):
    if len(pts) < 2:
        return Vector((1.0, 0.0, 0.0))
    ref = pts[0]
    acc = 0.0
    for i in range(len(pts) - 1, 0, -1):
        acc += (pts[i] - pts[i - 1]).length
        if acc >= probe:
            ref = pts[i - 1]
            break
    return _flat_dir(pts[-1] - ref)


def _trim_from_end(pts, ws, length):
    if length <= 1e-6 or len(pts) < 2:
        return list(pts), list(ws)
    acc = 0.0
    for i in range(len(pts) - 1, 0, -1):
        seg = (pts[i] - pts[i - 1]).length
        if seg < 1e-9:
            continue
        if acc + seg >= length - 1e-9:
            t = (length - acc) / seg
            new_p = pts[i] + (pts[i - 1] - pts[i]) * t
            new_w = ws[i] + (ws[i - 1] - ws[i]) * t
            keep_p, keep_w = list(pts[:i]), list(ws[:i])
            if keep_p and (new_p - keep_p[-1]).length < 1e-6:
                keep_p[-1], keep_w[-1] = new_p, new_w
            else:
                keep_p.append(new_p)
                keep_w.append(new_w)
            if len(keep_p) < 2:
                return list(pts[:2]), list(ws[:2])
            return keep_p, keep_w
        acc += seg
    return list(pts[:2]), list(ws[:2])


def _trim_from_start(pts, ws, length):
    p, w = _trim_from_end(list(reversed(pts)), list(reversed(ws)), length)
    return list(reversed(p)), list(reversed(w))


def _hermite(p0, m0, p1, m1, t):
    t2, t3 = t * t, t * t * t
    return (p0 * (2 * t3 - 3 * t2 + 1) + m0 * (t3 - 2 * t2 + t)
            + p1 * (-2 * t3 + 3 * t2) + m1 * (t3 - t2))


def _bridge_samples(pA, dA, pB, dB, mag_scale, count=96):
    chord_v = pB - pA
    chord = Vector((chord_v.x, chord_v.y, 0.0)).length
    if chord < 1e-4:
        return None
    theta = math.acos(max(-1.0, min(1.0, dA.dot(dB))))
    ratio = 1.0 if theta < 1e-3 else 2.0 * math.tan(theta / 4.0) / math.sin(theta / 2.0)
    mag = chord * ratio * mag_scale
    if dA.dot(chord_v) <= 0.0 or dB.dot(chord_v) <= 0.0:
        mag = min(mag, chord * 0.5)
    p0 = Vector((pA.x, pA.y, 0.0))
    p1 = Vector((pB.x, pB.y, 0.0))
    m0, m1 = dA * mag, dB * mag
    return [_hermite(p0, m0, p1, m1, i / float(count)) for i in range(count + 1)]


def _outward_normals(dA, dB):
    cross_z = dA.x * dB.y - dA.y * dB.x
    if abs(cross_z) < 1e-4:
        return None
    sign = 1.0 if cross_z > 0.0 else -1.0
    return (Vector((dA.y, -dA.x, 0.0)) * sign, Vector((dB.y, -dB.x, 0.0)) * sign)


def _outward_violation(samples, pA, pB, normals):
    if normals is None:
        return -1.0
    nA, nB = normals
    worst = -1e9
    for q in samples:
        worst = max(worst, (q - pA).dot(nA), (q - pB).dot(nB))
    return worst


def _fan_corner(inner, nA, wA, nB, wB, sign, spacing, zA=None, zB=None):
    cz = nA.x * nB.y - nA.y * nB.x
    turn = math.atan2(cz, max(-1.0, min(1.0, nA.dot(nB))))
    if abs(turn) < 1e-4:
        return []

    steps = max(2, int(math.ceil(abs(math.degrees(turn)) / max(ZEBRA_FILLET_MAX_TURN_DEG, 0.1))))
    steps = max(steps, int(round(abs(turn) * max(wA, wB) / max(spacing, 1e-3))), 2)
    steps = min(steps, 240)

    cap_ok = (wB >= wA * math.cos(turn) - 1e-6) and (wA >= wB * math.cos(turn) - 1e-6)

    out = []
    for i in range(steps + 1):
        t = i / float(steps)
        phi = turn * t
        c, s_ = math.cos(phi), math.sin(phi)
        u = Vector((nA.x * c - nA.y * s_, nA.x * s_ + nA.y * c, 0.0))

        smooth = t * t * (3.0 - 2.0 * t)
        r = wA + (wB - wA) * smooth
        if cap_ok:
            ca, cb = math.cos(phi), math.cos(turn - phi)
            if ca > 0.05:
                r = min(r, wA / ca)
            if cb > 0.05:
                r = min(r, wB / cb)
        if i == 0:
            r = wA
        elif i == steps:
            r = wB
        r = max(r, 1e-3)

        center = inner + u * (r / 2.0)
        if zA is not None and zB is not None:
            center.z = zA + (zB - zA) * smooth
        tangent = Vector((-u.y, u.x, 0.0)) * sign
        out.append((center, r, tangent))
    return out


def _bridge_halfwidths(samples, pA, dA, hwA, pB, dB, hwB):
    n = len(samples)
    normals = _outward_normals(dA, dB)
    floor_hw = min(hwA, hwB)
    tol = ZEBRA_FILLET_INSIDE_TOLERANCE
    out = []
    for i in range(n):
        u = i / float(n - 1) if n > 1 else 0.0
        hw = hwA + (hwB - hwA) * u
        if normals is not None and ZEBRA_FILLET_KEEP_INSIDE:
            nA, nB = normals
            j0, j1 = max(0, i - 1), min(n - 1, i + 1)
            d = _flat_dir(samples[j1] - samples[j0])
            sign = 1.0 if (dA.x * dB.y - dA.y * dB.x) > 0.0 else -1.0
            nrm = Vector((d.y, -d.x, 0.0)) * sign
            for limit, base_n in ((pA + nA * hwA, nA), (pB + nB * hwB, nB)):
                proj = nrm.dot(base_n)
                if proj > 1e-6:
                    allowed = (tol - (samples[i] - limit).dot(base_n)) / proj
                    hw = min(hw, allowed)
            hw = max(hw, floor_hw)
        out.append(hw)
    return out


def _fillet_bridge(pA, dA, wA, pB, dB, wB, spacing, mag_scale=1.0):
    dense = _bridge_samples(pA, dA, pB, dB, mag_scale)
    if dense is None:
        return []

    cum, turn_total = [0.0], 0.0
    for i in range(1, len(dense)):
        cum.append(cum[-1] + (dense[i] - dense[i - 1]).length)
    for i in range(1, len(dense) - 1):
        a, b = _flat_dir(dense[i] - dense[i - 1]), _flat_dir(dense[i + 1] - dense[i])
        turn_total += math.degrees(math.acos(max(-1.0, min(1.0, a.dot(b)))))
    total = cum[-1]
    if total < 1e-4:
        return []

    steps_len = int(round(total / max(spacing, 1e-3)))
    steps_ang = int(math.ceil(turn_total / max(ZEBRA_FILLET_MAX_TURN_DEG, 0.1)))
    steps = max(2, steps_len, min(steps_ang, 200))

    out = []
    for s in range(1, steps):
        target = total * s / steps
        j = 1
        while j < len(cum) and cum[j] < target:
            j += 1
        j = min(j, len(cum) - 1)
        seg = cum[j] - cum[j - 1]
        f = (target - cum[j - 1]) / seg if seg > 1e-12 else 0.0
        p = dense[j - 1] + (dense[j] - dense[j - 1]) * f
        u = s / steps
        out.append((Vector((p.x, p.y, pA.z + (pB.z - pA.z) * u)), None, u, p))
    hws = _bridge_halfwidths([o[3] for o in out], pA, dA, wA / 2.0, pB, dB, wB / 2.0)
    return [(o[0], hw * 2.0) for o, hw in zip(out, hws)]


def _oriented(prep, end):
    if end == 1:
        return list(prep["pts"]), list(prep["ws"])
    return list(reversed(prep["pts"])), list(reversed(prep["ws"]))


def _corner_trims(pA, dA, hwA, pB, dB, hwB):
    cross = dA.x * dB.y - dA.y * dB.x
    if abs(cross) < 0.02:
        return None
    sign = 1.0 if cross > 0.0 else -1.0
    nA = Vector((dA.y, -dA.x, 0.0)) * sign
    nB = Vector((dB.y, -dB.x, 0.0)) * sign
    a0 = pA - nA * hwA
    b0 = pB - nB * hwB
    rhs = b0 - a0
    s_par = (rhs.x * dB.y - rhs.y * dB.x) / cross
    inner = a0 + dA * s_par
    foot_a = inner + nA * hwA
    foot_b = inner + nB * hwB
    return {"trim_a": (pA - foot_a).dot(dA), "trim_b": (foot_b - pB).dot(dB),
            "inner": inner, "nA": nA, "nB": nB, "sign": sign,
            "wA": hwA * 2.0, "wB": hwB * 2.0,
            "zA": pA.z, "zB": pB.z}


def _try_fan(A, wA, B, wB, cap_a, cap_b):
    ta = tb = 0.0
    frame = None
    for _ in range(8):
        st = _junction_state(A, wA, B, wB, ta, tb)
        if st is None:
            return None
        pA, dA, hwA, pB, dB, hwB = st
        turn = math.degrees(math.acos(max(-1.0, min(1.0, dA.dot(dB)))))
        if turn < ZEBRA_FAN_MIN_TURN_DEG:
            return None
        ref = _corner_trims(pA, dA, hwA, pB, dB, hwB)
        if ref is None:
            return None
        if (ref["inner"] - pA).length > ZEBRA_FAN_MAX_REACH * max(hwA, hwB):
            return None
        d_ta, d_tb = ref["trim_a"], ref["trim_b"]
        if abs(d_ta) < 1e-3 and abs(d_tb) < 1e-3:
            frame = ref
            break
        nta, ntb = ta + d_ta, tb + d_tb
        if nta < -1e-6 or ntb < -1e-6 or nta > cap_a or ntb > cap_b:
            return None
        ta, tb = nta, ntb
    if frame is None:
        return None
    return ta, tb, 1.0, frame


def _solve_junction(pa, ea, pb, eb):
    A, wA = _oriented(pa, ea)
    B, wB = _oriented(pb, eb)
    B, wB = list(reversed(B)), list(reversed(wB))

    cap_a = ZEBRA_FILLET_MAX_TRIM_RATIO * _polyline_length(A)
    cap_b = ZEBRA_FILLET_MAX_TRIM_RATIO * _polyline_length(B)

    st = _junction_state(A, wA, B, wB, 0.0, 0.0)
    if st is None:
        return None, "decal too short"
    turn0 = math.degrees(math.acos(max(-1.0, min(1.0, st[1].dot(st[4])))))
    if turn0 > ZEBRA_FILLET_MAX_CORNER_DEG:
        return None, f"turn too sharp {turn0:.0f}deg (V/hairpin)"

    fan = _try_fan(A, wA, B, wB, cap_a, cap_b)
    if fan is not None:
        return fan, None

    hwA0, hwB0 = st[2], st[5]
    ratio = max(hwA0, hwB0) / max(min(hwA0, hwB0), 1e-6)
    if ratio > ZEBRA_FILLET_MAX_WIDTH_RATIO:
        return None, f"width ratio {ratio:.1f} ({hwA0*2:.1f}m vs {hwB0*2:.1f}m) with no corner to fan from"

    ta = tb = 0.0
    for _ in range(6):
        st = _junction_state(A, wA, B, wB, ta, tb)
        if st is None:
            return None, "decal too short"
        pA, dA, hwA, pB, dB, hwB = st
        ref = _corner_trims(pA, dA, hwA, pB, dB, hwB)
        if ref is None:
            break
        d_ta, d_tb = ref["trim_a"], ref["trim_b"]
        if abs(d_ta) < 1e-3 and abs(d_tb) < 1e-3:
            break
        ta = max(0.0, min(cap_a, ta + d_ta))
        tb = max(0.0, min(cap_b, tb + d_tb))
    ta *= ZEBRA_FILLET_INNER_BIAS
    tb *= ZEBRA_FILLET_INNER_BIAS

    advance = ZEBRA_FILLET_MIN_ADVANCE
    for _ in range(16):
        st = _junction_state(A, wA, B, wB, ta, tb)
        if st is None:
            return None, "decal too short"
        pA, dA, hwA, pB, dB, hwB = st
        chord = Vector(((pB - pA).x, (pB - pA).y, 0.0))
        def_a = advance - dA.dot(chord)
        def_b = advance - dB.dot(chord)
        if def_a <= 1e-3 and def_b <= 1e-3:
            break
        if ta >= cap_a - 1e-6 and tb >= cap_b - 1e-6:
            return None, "overlap exceeds the trim budget"
        ta = min(cap_a, ta + max(0.0, def_a) * 0.5 + 1e-3)
        tb = min(cap_b, tb + max(0.0, def_b) * 0.5 + 1e-3)
    else:
        return None, "overlap exceeds the trim budget"

    last = "outward bulge / inner curb pinch"
    for _ in range(6):
        st = _junction_state(A, wA, B, wB, ta, tb)
        if st is None:
            return None, "decal too short"
        pA, dA, hwA, pB, dB, hwB = st
        scale = _solve_inward_scale(pA, dA, hwA, pB, dB, hwB)
        if scale is None:
            last = "outward bulge unavoidable"
        elif _pinches(pA, dA, hwA, pB, dB, hwB, scale):
            last = "radius smaller than the half-width (pinch)"
        else:
            return (ta, tb, scale, None), None
        if ta >= cap_a - 1e-6 and tb >= cap_b - 1e-6:
            return None, last
        step = max(0.25, 0.15 * (hwA + hwB))
        ta = min(cap_a, ta + step)
        tb = min(cap_b, tb + step)
    return None, last


def _junction_state(A, wA, B, wB, ta, tb):
    a2, wa2 = _trim_from_end(A, wA, ta)
    b2, wb2 = _trim_from_start(B, wB, tb)
    if len(a2) < 2 or len(b2) < 2:
        return None
    dA = _dir_at_end(a2, ZEBRA_FILLET_TANGENT_PROBE)
    dB = _dir_at_end(list(reversed(b2)), ZEBRA_FILLET_TANGENT_PROBE) * -1.0
    return a2[-1], dA, wa2[-1] / 2.0, b2[0], dB, wb2[0] / 2.0


def _pinches(pA, dA, hwA, pB, dB, hwB, scale):
    s = _bridge_samples(pA, dA, pB, dB, scale)
    if s is None:
        return False
    n = len(s)
    for i in range(1, n - 1):
        seg = ((s[i] - s[i - 1]).length + (s[i + 1] - s[i]).length) / 2.0
        if seg < 1e-9:
            continue
        a, b = _flat_dir(s[i] - s[i - 1]), _flat_dir(s[i + 1] - s[i])
        ang = math.acos(max(-1.0, min(1.0, a.dot(b))))
        hw = hwA + (hwB - hwA) * (i / float(n - 1))
        if ang > 1e-9 and seg / ang < hw * 0.98:
            return True
    return False


def _solve_inward_scale(pA, dA, hwA, pB, dB, hwB):
    if not ZEBRA_FILLET_KEEP_INSIDE:
        return 1.0
    normals = _outward_normals(dA, dB)
    if normals is None:
        return 1.0
    tol = ZEBRA_FILLET_INSIDE_TOLERANCE

    def ok(scale):
        s = _bridge_samples(pA, dA, pB, dB, scale)
        return s is not None and _outward_violation(s, pA, pB, normals) <= tol

    if ok(1.0):
        return 1.0
    lo = 0.15
    if not ok(lo):
        return None
    hi = 1.0
    for _ in range(12):
        mid = (lo + hi) / 2.0
        if ok(mid):
            lo = mid
        else:
            hi = mid
    return lo


def _cluster_endpoints(endpoints, tol):
    parent = list(range(len(endpoints)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    for i in range(len(endpoints)):
        for j in range(i + 1, len(endpoints)):
            if (endpoints[i]["pos"] - endpoints[j]["pos"]).length <= tol:
                union(i, j)

    groups = {}
    for i in range(len(endpoints)):
        groups.setdefault(find(i), []).append(i)
    return list(groups.values())


def _chain_order(n_roads, partner):
    chains = []
    used = set()

    def walk(start_road, enter_end):
        chain = []
        r, e = start_road, enter_end
        while True:
            if r in used:
                return chain, True
            used.add(r)
            chain.append((r, e == 1))
            exit_end = 1 - e
            nxt = partner.get((r, exit_end))
            if nxt is None:
                return chain, False
            r, e = nxt
            if (r, e) == (start_road, enter_end):
                return chain, True

    for r in range(n_roads):
        if r in used:
            continue
        free = [e for e in (0, 1) if (r, e) not in partner]
        if free:
            chains.append(walk(r, free[0]))
    for r in range(n_roads):
        if r not in used:
            chains.append(walk(r, 0))
    return chains


def _weld_short_segments(pts, ws, ts, min_len, closed=False):
    if len(pts) < 3:
        return pts, ws, ts
    keep_p, keep_w, keep_t = [pts[0]], [ws[0]], [ts[0]]
    last = len(pts) - 1
    for i in range(1, len(pts)):
        if i != last and (pts[i] - keep_p[-1]).length < min_len:
            if ts[i] is not None:
                keep_t[-1] = ts[i]
            keep_w[-1] = ws[i]
            continue
        keep_p.append(pts[i])
        keep_w.append(ws[i])
        keep_t.append(ts[i])
    if len(keep_p) >= 3 and (keep_p[-1] - keep_p[-2]).length < min_len:
        if keep_t[-1] is None:
            keep_t[-1] = keep_t[-2]
        del keep_p[-2], keep_w[-2], keep_t[-2]

    if closed and len(keep_p) >= 4:
        d_xy = math.hypot(keep_p[-1].x - keep_p[0].x, keep_p[-1].y - keep_p[0].y)
        if d_xy < ZEBRA_SEAM_WELD:
            if keep_t[0] is None and keep_t[-1] is not None:
                keep_t[0] = keep_t[-1]
            del keep_p[-1], keep_w[-1], keep_t[-1]
    return keep_p, keep_w, keep_t


def _as_road(template, pts, ws, closed, srcs, section_tangents=None):
    return {
        "persistentId": template.get("persistentId"),
        "group": template.get("group", ""),
        "fields": template.get("fields") or {},
        "material": template.get("material"),
        "nodes": [{"x": p.x, "y": p.y, "z": p.z, "width": w} for p, w in zip(pts, ws)],
        "widths": list(ws),
        "width": ws[0] if ws else WIDTH,
        "source": "decalroad_exact",
        "over_objects": any(s.get("over_objects") for s in srcs),
        "merged": True,
        "closed": bool(closed),
        "merged_from": [s.get("persistentId") for s in srcs],
        "section_tangents": section_tangents,
    }


def _path_sanity(pts, max_turn_deg=100.0):
    bad = 0
    for i in range(1, len(pts) - 1):
        a = _flat_dir(pts[i] - pts[i - 1])
        b = _flat_dir(pts[i + 1] - pts[i])
        if math.degrees(math.acos(max(-1.0, min(1.0, a.dot(b))))) > max_turn_deg:
            bad += 1
    return bad


def merge_zebra_roads(roads):
    zebras = [r for r in roads if r.get("source") == "decalroad_exact"]
    others = [r for r in roads if r.get("source") != "decalroad_exact"]
    if len(zebras) < 2:
        return roads

    prepared, self_closed = [], []
    for z in zebras:
        pts = [Vector((n["x"], n["y"], n["z"])) for n in z["nodes"]]
        ws = list(z["widths"])
        if is_closed_loop(pts):
            self_closed.append(z)
            continue
        if ZEBRA_SMOOTH_CORNERS:
            pts, ws = smooth_path_with_widths(pts, ws, ZEBRA_SMOOTH_SEGMENT_LENGTH)
        if len(pts) < 2:
            self_closed.append(z)
            continue
        prepared.append({"pts": pts, "ws": ws, "src": z, "raw_nodes": len(z["nodes"])})

    stubs = [p for p in prepared if p["raw_nodes"] <= 2 or _polyline_length(p["pts"]) < 3.0]
    if stubs:
        print(f"  [zebra-merge] note: {len(stubs)} zebra decals are 2-node stubs or shorter than 3m. "
              f"They cannot be trimmed enough for an arc, so their junctions are rejected - worth cleaning them up in the map.")

    if len(prepared) < 2:
        return roads

    endpoints = []
    for i, p in enumerate(prepared):
        endpoints.append({"road": i, "end": 0, "pos": p["pts"][0]})
        endpoints.append({"road": i, "end": 1, "pos": p["pts"][-1]})

    partner, skipped, reasons = {}, 0, {}
    for grp in _cluster_endpoints(endpoints, ZEBRA_JOIN_TOLERANCE):
        if len(grp) == 1:
            continue
        if len(grp) != 2:
            skipped += 1
            continue
        a, b = endpoints[grp[0]], endpoints[grp[1]]
        if a["road"] == b["road"] and a["end"] == b["end"]:
            continue
        partner[(a["road"], a["end"])] = (b["road"], b["end"])
        partner[(b["road"], b["end"])] = (a["road"], a["end"])

    if skipped:
        print(f"  [zebra-merge] {skipped} junctions with 3+ ends (a real intersection) - deliberately skipped, "
              f"built as separate decals as before")
    if not partner:
        print("  [zebra-merge] no junction found between zebra decals - nothing changed")
        return roads

    trims, rejected = {}, 0
    for (r, e), (r2, e2) in list(partner.items()):
        if (r, e) in trims:
            continue
        sol, why = _solve_junction(prepared[r], e, prepared[r2], e2)
        if sol is None:
            rejected += 1
            reasons[why] = reasons.get(why, 0) + 1
            partner.pop((r, e), None)
            partner.pop((r2, e2), None)
            continue
        ta, tb, scale, frame = sol
        flip = None if frame is None else {
            "inner": frame["inner"], "nA": frame["nB"], "nB": frame["nA"],
            "wA": frame["wB"], "wB": frame["wA"], "sign": -frame["sign"],
            "zA": frame["zB"], "zB": frame["zA"]}
        trims[(r, e)] = (ta, scale, frame)
        trims[(r2, e2)] = (tb, scale, flip)

    if rejected:
        total = rejected + len(partner) // 2
        print(f"  [zebra-merge] {rejected} of {total} junctions were not merged (left separate). By reason:")
        for why, cnt in sorted(reasons.items(), key=lambda kv: -kv[1]):
            print(f"                  {cnt:>3} x  {why}")
    if not partner:
        print("  [zebra-merge] no filletable junction remains - nothing changed")
        return roads

    chains = _chain_order(len(prepared), partner)
    merged_roads = []
    for chain, is_cycle in chains:
        if len(chain) == 1 and not is_cycle:
            p = prepared[chain[0][0]]
            merged_roads.append(_as_road(p["src"], p["pts"], p["ws"], False, [p["src"]]))
            continue

        segs = []
        for road_idx, rev in chain:
            p = prepared[road_idx]
            pts = list(reversed(p["pts"])) if rev else list(p["pts"])
            ws = list(reversed(p["ws"])) if rev else list(p["ws"])
            t_in = trims.get((road_idx, 1 if rev else 0), (0.0, 1.0, None))[0]
            t_out, scale_out, frame_out = trims.get((road_idx, 0 if rev else 1), (0.0, 1.0, None))
            pts, ws = _trim_from_start(pts, ws, t_in)
            pts, ws = _trim_from_end(pts, ws, t_out)
            segs.append({"pts": pts, "ws": ws, "src": p["src"], "idx": road_idx,
                         "scale_out": scale_out, "frame_out": frame_out})

        out_p, out_w = list(segs[0]["pts"]), list(segs[0]["ws"])
        out_t = [None] * len(out_p)
        n_join = len(segs) if is_cycle else len(segs) - 1
        for k in range(n_join):
            nxt = segs[(k + 1) % len(segs)]
            pA, wA = out_p[-1], out_w[-1]
            dA = _dir_at_end(out_p, ZEBRA_FILLET_TANGENT_PROBE)
            pB, wB = nxt["pts"][0], nxt["ws"][0]
            dB = _dir_at_end(list(reversed(nxt["pts"])), ZEBRA_FILLET_TANGENT_PROBE) * -1.0
            fr = segs[k]["frame_out"]
            if fr is not None:
                fan = _fan_corner(fr["inner"], fr["nA"], fr["wA"], fr["nB"], fr["wB"],
                                  fr["sign"], ZEBRA_SMOOTH_SEGMENT_LENGTH,
                                  zA=fr.get("zA"), zB=fr.get("zB"))
                bridge = [(pt, w, tg) for pt, w, tg in fan]
            else:
                bridge = [(pt, w, None) for pt, w in
                          _fillet_bridge(pA, dA, wA, pB, dB, wB, ZEBRA_SMOOTH_SEGMENT_LENGTH,
                                         segs[k]["scale_out"])]
            for j, (bp, bw, bt) in enumerate(bridge):
                weld = ZEBRA_SEAM_WELD if j == 0 else 1e-5
                if (bp - out_p[-1]).length > weld:
                    out_p.append(bp)
                    out_w.append(bw)
                    out_t.append(bt)
                else:
                    out_w[-1] = bw
                    if bt is not None:
                        out_t[-1] = bt
            if k + 1 < len(segs):
                for j, (q, qw) in enumerate(zip(nxt["pts"], nxt["ws"])):
                    weld = ZEBRA_SEAM_WELD if j == 0 else 1e-5
                    if (q - out_p[-1]).length > weld:
                        out_p.append(q)
                        out_w.append(qw)
                        out_t.append(None)
                    else:
                        out_w[-1] = qw

        out_p, out_w, out_t = _weld_short_segments(out_p, out_w, out_t, MIN_NODE_SPACING,
                                                   closed=is_cycle)
        bad = _path_sanity(out_p)
        if bad:
            print(f"  [zebra-merge] warning: {bad} sharp turns (>100deg) in the merged polyline - "
                  f"probably overlapping decals. Check that junction by hand.")
        srcs = [s["src"] for s in segs]
        merged_roads.append(_as_road(srcs[0], out_p, out_w, is_cycle, srcs, out_t))
        kind = "cycle" if is_cycle else "chain"
        print(f"  [zebra-merge] {kind} of {len(segs)} decals -> one polyline "
              f"({len(out_p)} nodes, {_polyline_length(out_p):.1f}m)")

    for z in self_closed:
        merged_roads.append(z)
    return merged_roads + others



MESHROAD_WALK_SPLIT = True
WALK_SPLIT_TARGET_FOLD_DEG = 10.0
WALK_SPLIT_MAX = 6

ACTIVE_WALK_SPLIT = [False]


def _edge_advance(points, tangents, i, j, off):
    ti, tj = tangents[i], tangents[j]
    ax = points[i].x - ti.y * off
    ay = points[i].y + ti.x * off
    bx = points[j].x - tj.y * off
    by = points[j].y + tj.x * off
    dx, dy = bx - ax, by - ay
    return min(dx * ti.x + dy * ti.y, dx * tj.x + dy * tj.y)


def _span_geometry(points, tangents, widths, i, j):
    hw = max(0.0, min(widths[i], widths[j]) / 2.0 - CURB_STRIP)
    if hw <= 1e-6:
        return 0.0, 0.0, 0.0, 0.0
    a = _edge_advance(points, tangents, i, j, -hw)
    b = _edge_advance(points, tangents, i, j, hw)
    dz = abs(points[j].z - points[i].z)
    return a, b, dz, hw


def span_fold_deg(a, b, dz):
    lo, hi = (a, b) if a <= b else (b, a)
    if dz < 1e-9 or lo <= 1e-9 or hi <= 1e-9:
        return 0.0
    return math.degrees(math.atan(dz / lo) - math.atan(dz / hi))


def walk_split_fracs(n, a, b, dz, hw):
    if n < 2:
        return []
    lo, hi = (a, b) if a <= b else (b, a)
    if hw <= 1e-6 or dz < 1e-9 or lo <= 1e-9 or hi - lo <= 1e-9:
        return [2.0 * i / n - 1.0 for i in range(1, n)]
    R = hw * (hi + lo) / (hi - lo)
    K = dz * R * 2.0 / (hi + lo)
    phi_in = math.atan(K / max(1e-9, R - hw))
    phi_out = math.atan(K / (R + hw))
    if abs(phi_in - phi_out) < 1e-9:
        return [2.0 * i / n - 1.0 for i in range(1, n)]
    out = []
    for k in range(1, n):
        phi = phi_in + (phi_out - phi_in) * k / n
        x = K / math.tan(phi) - R
        out.append(max(-0.999, min(0.999, x / hw)))
    if a > b:
        out = [-v for v in out]
    return sorted(out)


ROLES = ["outer_near", "inner_near", "inner_far", "outer_far"]


def build_cross_section(bm, point, normal, center_offset, mirror, width, height, extra_z_offset=0.0,
                         terrain_sampler=None, bevel_outer_edges=False, inset_override=None, uv_hw=None,
                         up_world=None, tangent=None, cap_shrink=None, walk_split=None):
    hw_n = width / 2.0
    if inset_override is None:
        inset_n = max(0.0, hw_n - CURB_STRIP)
    else:
        inset_n = max(0.0, min(float(inset_override), hw_n))
    local_x = {"outer_near": -hw_n, "inner_near": -inset_n, "inner_far": inset_n, "outer_far": hw_n}
    ht_n = height / 2.0

    chamfer, slope_h = 0.0, 0.0
    if CURB_PROFILE_ENABLED:
        prof = ACTIVE_CURB_PROFILE[0]
        chamfer = min(prof["exposed"], height)
        slope_h = min(math.tan(math.radians(prof["angle"])) * chamfer,
                      max(0.0, (hw_n - inset_n) * 0.9))
    elif bevel_outer_edges:
        slope_h = max(0.0, min(ZEBRA_BEVEL_SIZE, hw_n - inset_n))
        chamfer = slope_h
    if slope_h > 1e-6 and chamfer > 1e-6:
        ch_x = hw_n - slope_h
        if cap_shrink is not None:
            ch_x = max(inset_n, min(cap_shrink(slope_h), hw_n))
        local_x["outer_near_chamfer"] = -ch_x
        local_x["outer_far_chamfer"] = ch_x
    else:
        chamfer, slope_h = 0.0, 0.0

    side_dir, down_dir = normal, Vector((0.0, 0.0, -1.0))
    if up_world is not None:
        tan = tangent if tangent is not None else Vector((-normal.y, normal.x, 0.0))
        if tan.length > 1e-9:
            tan = tan.normalized()
            u = up_world - tan * up_world.dot(tan)
            if u.length > 1e-6:
                u.normalize()
                sd = u.cross(tan)
                if sd.length > 1e-9:
                    side_dir, down_dir = sd.normalized(), u * -1.0

    def make_point(role):
        world_offset = mirror * (center_offset + local_x[role])
        pos_center = point + side_dir * world_offset
        if terrain_sampler is not None:
            base_z = terrain_sampler(pos_center.x, pos_center.y)
            pos_center = Vector((pos_center.x, pos_center.y, base_z))
        return pos_center

    if uv_hw is None:
        uv_x = dict(local_x)
        uvh = hw_n
    else:
        uvh = float(uv_hw)
        uv_inset = max(0.0, uvh - CURB_STRIP)
        uv_x = {"outer_near": -uvh, "inner_near": -uv_inset,
                "inner_far": uv_inset, "outer_far": uvh}
        if "outer_near_chamfer" in local_x:
            uv_x["outer_near_chamfer"] = -uvh + slope_h
            uv_x["outer_far_chamfer"] = uvh - slope_h

    walk_roles = []
    if walk_split:
        uv_inset_n = max(0.0, uvh - CURB_STRIP)
        for k, f in enumerate(walk_split):
            role = f"walk_{k}"
            local_x[role] = inset_n * f
            uv_x[role] = uv_inset_n * f
            walk_roles.append(role)

    verts = {"_local_x": local_x, "_hw": hw_n, "_ht": ht_n, "_height": height, "_chamfer": chamfer,
             "_uv_x": uv_x, "_uv_hw": uvh, "_walk_roles": walk_roles,
             "_side": side_dir, "_up": down_dir * -1.0}
    for role in ROLES + walk_roles:
        pos_center = make_point(role)
        top_drop = chamfer if (chamfer > 1e-6 and role in ("outer_near", "outer_far")) else 0.0
        lift = Vector((0, 0, Z_OFFSET + extra_z_offset))
        top = pos_center + lift + down_dir * top_drop
        bot = pos_center + lift + down_dir * height
        verts[f"{role}_top"] = bm.verts.new(top)
        verts[f"{role}_bot"] = bm.verts.new(bot)

    if chamfer > 1e-6:
        for role in ("outer_near_chamfer", "outer_far_chamfer"):
            pos_center = make_point(role)
            top = pos_center + Vector((0, 0, Z_OFFSET + extra_z_offset))
            verts[f"{role}_top"] = bm.verts.new(top)

    return verts


def uv_top_bottom(local_x, s, mat):
    su, sv = _texuv(mat)
    if mat == WALK:
        return (local_x / su + 0.5, s / sv + 0.5)
    return (s / su + 0.5, local_x / sv + 0.5)


def uv_cap_curb(edge_dist, sign, local_x, ht_local, z_local):
    depth = max(0.0, ht_local - z_local)
    sc = (CURB_ATLAS_U_SCALE if (CURB_ATLAS_ACTIVE[0] and CURB_ATLAS_U_SCALE)
          else _tex(CURB))
    return (local_x / sc + 0.5, curb_face_v(depth))


def uv_cap_walk(edge_dist, sign, local_x, ht_local, z_local):
    wrap = edge_dist + sign * (ht_local - z_local)
    su, sv = _texuv(WALK)
    return (local_x / su + 0.5, wrap / sv + 0.5)


def face_normal_of(verts):
    n = Vector((0.0, 0.0, 0.0))
    m = len(verts)
    for i in range(m):
        a, b = verts[i].co, verts[(i + 1) % m].co
        n = n + a.cross(b)
    return n


def orient_to(verts, uvs, want):
    if want is None or face_normal_of(verts).dot(want) >= 0:
        return verts, uvs
    return tuple(reversed(verts)), (tuple(reversed(uvs)) if uvs else uvs)


def resolve_mat_index(mat):
    if mat == WALK and ACTIVE_ZEBRA_WALK[0] is not None:
        return ACTIVE_ZEBRA_WALK[0](ACTIVE_S[0])
    return mat


def add_quad(bm, uv_layer, faces_uv, v4, mat, uvs4, want=None):
    v4, uvs4 = orient_to(v4, uvs4, want)
    f = bm.faces.new(v4)
    f.material_index = resolve_mat_index(mat)
    for loop, uv in zip(f.loops, uvs4):
        loop[uv_layer].uv = uv
    return f


def _xy_cross(a, b, c):
    return ((b.co.x - a.co.x) * (c.co.y - a.co.y) -
            (b.co.y - a.co.y) * (c.co.x - a.co.x))


def quad_shape(v4):
    c = [_xy_cross(v4[i - 1], v4[i], v4[(i + 1) % 4]) for i in range(4)]
    scale = max(abs(x) for x in c)
    if scale < 1e-12:
        return "degenerate", -1
    for i in range(4):
        a, b = v4[i], v4[(i + 1) % 4]
        if abs(a.co.x - b.co.x) < 1e-6 and abs(a.co.y - b.co.y) < 1e-6:
            return "degenerate", -1
    tol = scale * 1e-6
    pos = [i for i, x in enumerate(c) if x > tol]
    neg = [i for i, x in enumerate(c) if x < -tol]
    if not pos or not neg:
        return "convex", -1
    if len(pos) == 1:
        return "concave", pos[0]
    if len(neg) == 1:
        return "concave", neg[0]
    return "bowtie", -1


def quad_fan_diagonal(v4):
    kind, idx = quad_shape(v4)
    STATS["quad_" + kind] += 1
    if DIAG_QUADS and kind in ("concave", "bowtie") and len(DIAG_SAMPLES) < DIAG_QUADS_SAMPLES:
        DIAG_SAMPLES.append((kind, [tuple(round(x, 2) for x in v.co) for v in v4]))
    if kind == "bowtie":
        return ((0, 1, 2), (0, 2, 3))
    if SPLIT_FLAT_QUADS and kind == "concave":
        k = idx
        return ((k, (k + 1) % 4, (k + 2) % 4), (k, (k + 2) % 4, (k + 3) % 4))
    return None


def _record_ref(f, want):
    if FACE_REFS[0] is not None and f is not None and want is not None:
        try:
            FACE_REFS[0].append((f, Vector((want.x, want.y, want.z))))
        except AttributeError:
            pass
    return f


def add_quad_flat(bm, uv_layer, v4, mat, uvs4, want):
    tris = quad_fan_diagonal(v4) if len(v4) == 4 else None
    if tris is None:
        return [_record_ref(add_quad(bm, uv_layer, None, v4, mat, uvs4, want), want)]

    out = []
    for t in tris:
        vs = tuple(v4[i] for i in t)
        if len(set(id(v) for v in vs)) != len(vs):
            continue
        us = tuple(uvs4[i] for i in t) if uvs4 else None
        try:
            out.append(_record_ref(add_quad(bm, uv_layer, None, vs, mat, us, want), want))
        except ValueError:
            continue
    return out


VALIDATE = True
VALIDATE_OFFSET_TOL = 0.01
VALIDATE_DEVIATION_TOL = 0.60
VALIDATE_SLOPE_JUMP_TOL = 20.0
VALIDATE_CREASE_TOL = 15.0

VALIDATION = []


def _authored_points(road):
    out = []
    for nd in (road.get("nodes") or []):
        try:
            if isinstance(nd, dict):
                out.append(Vector((float(nd["x"]), float(nd["y"]), float(nd["z"]))))
            else:
                out.append(Vector((float(nd[0]), float(nd[1]), float(nd[2]))))
        except (KeyError, IndexError, TypeError, ValueError):
            return []
    return out


def _flag(name, kind, detail, where=None):
    VALIDATION.append((name, kind, detail,
                       (round(where.x, 2), round(where.y, 2)) if where is not None else None))


def _guarded(fn):
    def wrapper(*a, **kw):
        if not VALIDATE:
            return None
        try:
            return fn(*a, **kw)
        except Exception as exc:
            VALIDATION.append(("<checker>", "error",
                               f"{fn.__name__} raised {type(exc).__name__}: {exc}", None))
            return None
    return wrapper


@_guarded
def check_offsets(name, points, tangents, widths, miter, closed=False):
    """The swept edge must sit exactly half-width from the centreline segment it spans.
    Catches a missing or wrong miter compensation, which silently narrows the ribbon."""
    if not VALIDATE or len(points) < 2:
        return
    worst, at = 0.0, None
    rng = range(len(points)) if closed else range(len(points) - 1)
    for i in rng:
        j = (i + 1) % len(points)
        a, b = points[i], points[j]
        seg = math.hypot(b.x - a.x, b.y - a.y)
        if seg < 1e-9:
            continue
        dx, dy = (b.x - a.x) / seg, (b.y - a.y) / seg
        nx, ny = -dy, dx
        for k in (i, j):
            hw = widths[k] / 2.0 * miter[k]
            px = points[k].x - tangents[k].y * hw
            py = points[k].y + tangents[k].x * hw
            got = abs((px - a.x) * nx + (py - a.y) * ny)
            err = abs(got - widths[k] / 2.0)
            if err > worst:
                worst, at = err, points[k]
    if worst > VALIDATE_OFFSET_TOL:
        _flag(name, "offset", f"swept edge is {worst:.2f} m off the authored half-width", at)


@_guarded
def check_path_fidelity(name, authored, points):
    """The built centreline must stay near the nodes the map author drew.
    Catches relaxation or smoothing that quietly relocates the road."""
    if not VALIDATE or len(authored) < 2 or not points:
        return
    worst, at = 0.0, None
    for q in points:
        best = min(_pt_seg_dist_2d(q, authored[i], authored[i + 1])
                   for i in range(len(authored) - 1))
        if best > worst:
            worst, at = best, q
    if worst > VALIDATE_DEVIATION_TOL:
        _flag(name, "drift", f"centreline wanders {worst:.2f} m from the authored nodes", at)


def _pt_seg_dist_2d(q, a, b):
    abx, aby = b.x - a.x, b.y - a.y
    L2 = abx * abx + aby * aby
    if L2 < 1e-12:
        return math.hypot(q.x - a.x, q.y - a.y)
    t = max(0.0, min(1.0, ((q.x - a.x) * abx + (q.y - a.y) * aby) / L2))
    return math.hypot(q.x - a.x - abx * t, q.y - a.y - aby * t)


@_guarded
def check_vertical(name, points):
    """Adjacent rings must not disagree wildly about the slope.
    Catches an XY-only move that left Z parameterised by the old arc length."""
    if not VALIDATE or len(points) < 3:
        return
    sl = []
    for i in range(1, len(points)):
        d = points[i] - points[i - 1]
        h = math.hypot(d.x, d.y)
        sl.append(d.z / h * 100.0 if h > 1e-9 else 0.0)
    worst, at = 0.0, None
    for i in range(1, len(sl)):
        j = abs(sl[i] - sl[i - 1])
        if j > worst:
            worst, at = j, points[i]
    if worst > VALIDATE_SLOPE_JUMP_TOL:
        _flag(name, "slope", f"slope jumps {worst:.0f} percentage points between rings", at)


@_guarded
def check_fold(name, points, tangents, offsets, closed=False):
    """Both offset edges must advance forwards across every span, or the surface
    crosses itself and the classifier reports bowties."""
    if not VALIDATE or len(points) < 2:
        return
    rng = range(len(points)) if closed else range(len(points) - 1)
    for i in rng:
        j = (i + 1) % len(points)
        if not _offset_advances(points, tangents, offsets, i, j):
            _flag(name, "fold", "an offset edge runs backwards - the surface folds", points[i])
            return


@_guarded
def check_top_crease(name, points, tangents, widths, bands, closed=False):
    """A ramp that turns while climbing is a helicoid; a level cross-section cannot
    span it flat. Measures the crease left after the width is split into bands."""
    if not VALIDATE or len(points) < 2 or bands < 1:
        return
    worst, at = 0.0, None
    rng = range(len(points)) if closed else range(len(points) - 1)
    for i in rng:
        j = (i + 1) % len(points)
        a, b, dz, _hw = _span_geometry(points, tangents, widths, i, j)
        f = span_fold_deg(a, b, dz) / float(bands)
        if f > worst:
            worst, at = f, points[i]
    if worst > VALIDATE_CREASE_TOL:
        _flag(name, "crease", f"top surface still creases {worst:.0f} deg per band", at)


@_guarded
def report_validation():
    if not VALIDATE or not VALIDATION:
        return
    print("-" * 62)
    print(f"  invariant checks: {len(VALIDATION)} finding(s)")
    for nm, kind, detail, where in VALIDATION[:20]:
        loc = f"  at ({where[0]}, {where[1]})" if where else ""
        print(f"     [{kind:6s}] '{nm}': {detail}{loc}")
    if len(VALIDATION) > 20:
        print(f"     ... and {len(VALIDATION) - 20} more")


def miter_scales(points, tangents, closed=False):
    n = len(points)
    out = [1.0] * n
    if not MITER_COMPENSATION or n < 3:
        return out
    for i in range(n):
        j = (i + 1) % n if closed else min(i + 1, n - 1)
        if j == i:
            continue
        d = points[j] - points[i]
        L = math.hypot(d.x, d.y)
        if L < 1e-9:
            continue
        cos_half = (d.x * tangents[i].x + d.y * tangents[i].y) / L
        if cos_half > 1e-3:
            out[i] = min(MITER_LIMIT, 1.0 / cos_half)
    if not closed:
        out[0] = 1.0
        out[-1] = 1.0
    return out


def build_sidewalk_side(bm, uv_layer, points, tangents, dists, widths, heights, center_offset, mirror,
                         extra_z_offset=0.0, terrain_sampler=None, closed=False, bevel_outer_edges=False,
                         hidden_layer=None, caps=None, up_layer=None, name_hint=""):
    def cap_of(i):
        return caps[i] if (caps and i < len(caps)) else None

    def out_dir(i):
        tn = tangents[i]
        return Vector((-tn.y, tn.x, 0.0)) * float(mirror)

    body_w = [w for i, w in enumerate(widths) if cap_of(i) is None]
    ref_src = body_w or list(widths)
    uv_ref = sorted(ref_src)[len(ref_src) // 2] / 2.0 if ref_src else None

    n_pts = len(points)
    spans = []
    for i in range(n_pts):
        j = (i + 1) % n_pts if closed else min(i + 1, n_pts - 1)
        spans.append(_span_geometry(points, tangents, widths, i, j) if j != i
                     else (0.0, 0.0, 0.0, 0.0))
    if not closed and len(spans) >= 2:
        spans[-1] = spans[-2]
    walk_n, walk_worst, walk_fracs = 1, 0.0, None
    if ACTIVE_WALK_SPLIT[0] and n_pts >= 3:
        worst_at = 0
        for idx, (a_, b_, dz_, _hw_) in enumerate(spans):
            f_ = span_fold_deg(a_, b_, dz_)
            if f_ > walk_worst:
                walk_worst, worst_at = f_, idx
        if walk_worst > WALK_SPLIT_TARGET_FOLD_DEG:
            walk_n = min(WALK_SPLIT_MAX,
                         int(math.ceil(walk_worst / WALK_SPLIT_TARGET_FOLD_DEG)))
            walk_fracs = walk_split_fracs(walk_n, *spans[worst_at])

    miter = miter_scales(points, tangents, closed)

    cross_sections = []
    for i, (p, t, w, h) in enumerate(zip(points, tangents, widths, heights)):
        normal = Vector((-t.y, t.x, 0.0)) * miter[i]
        c = cap_of(i)
        cs_split = walk_fracs if walk_n > 1 else None
        cs_up = ACTIVE_UP[0](dists[i]) if ACTIVE_UP[0] is not None else None
        cs_tan = tangent3d(points, i, closed) if cs_up is not None else None
        cs = build_cross_section(bm, p, normal, center_offset, mirror, w, h, extra_z_offset, terrain_sampler,
                                  bevel_outer_edges,
                                  inset_override=(c["inset"] if c else None),
                                  uv_hw=(uv_ref if uv_ref is not None
                                         else (c["uv_hw"] if c else None)),
                                  up_world=cs_up, tangent=cs_tan,
                                  cap_shrink=(c.get("shrink") if c else None),
                                  walk_split=cs_split)
        cross_sections.append(cs)

    n = len(points)
    seg_count = n if closed else n - 1
    total_len = dists[-1] + (points[0] - points[-1]).length if closed else 0.0

    uv_dists = [(cap_of(i)["uv_s"] if cap_of(i) else dists[i]) for i in range(n)]


    def top_role(cs, role):
        if role in ("outer_near", "outer_far") and cs.get("_chamfer", 0.0) > 1e-6:
            return f"{role}_chamfer"
        return role

    check_offsets(name_hint or "?", points, tangents, widths, miter, closed)
    check_fold(name_hint or "?", points, tangents,
               [widths[i] / 2.0 * miter[i] + abs(center_offset) for i in range(n_pts)], closed)
    check_vertical(name_hint or "?", points)
    check_top_crease(name_hint or "?", points, tangents, widths, walk_n, closed)

    wr = cross_sections[0].get("_walk_roles") if cross_sections else None
    chain = ["inner_near"] + list(wr or []) + ["inner_far"]
    pairs = ([("outer_near", "inner_near", CURB)]
             + [(chain[k], chain[k + 1], WALK) for k in range(len(chain) - 1)]
             + [("inner_far", "outer_far", CURB)])
    if walk_n > 1:
        STATS["walk_split_roads"] = STATS.get("walk_split_roads", 0) + 1
        print(f"  [walk] '{name_hint}': top surface split into {walk_n} bands across the width "
              f"(worst quad crease would have been {walk_worst:.0f} deg)")
    for i in range(seg_count):
        i2 = (i + 1) % n
        s0 = dists[i]
        s1 = total_len if (closed and i2 == 0) else dists[i2]
        su0 = uv_dists[i]
        su1 = total_len if (closed and i2 == 0) else uv_dists[i2]
        a, b = cross_sections[i], cross_sections[i2]

        ACTIVE_S[0] = s0
        if ACTIVE_ZEBRA_WALK[0] is not None:
            slot = ACTIVE_ZEBRA_WALK[0](s0)
            names = ACTIVE_WALK_SLOTS[0]
            if 0 <= slot < len(names):
                ACTIVE_TEXTURE_SCALE[0] = texture_scale_for(names[slot])

        for left_role, right_role, mat in pairs:
            xa = a["_local_x"] if mat == WALK else a["_uv_x"]
            xb = b["_local_x"] if mat == WALK else b["_uv_x"]
            t0 = s0 if mat == WALK else su0
            t1 = s1 if mat == WALK else su1
            lt_a, rt_a = top_role(a, left_role), top_role(a, right_role)
            lt_b, rt_b = top_role(b, left_role), top_role(b, right_role)
            v4 = (a[f"{lt_a}_top"], a[f"{rt_a}_top"], b[f"{rt_b}_top"], b[f"{lt_b}_top"])
            if mat == CURB:
                uvs = (
                    uv_curb_top(CURB_STRIP - (a["_uv_hw"] - abs(xa[lt_a])), t0),
                    uv_curb_top(CURB_STRIP - (a["_uv_hw"] - abs(xa[rt_a])), t0),
                    uv_curb_top(CURB_STRIP - (b["_uv_hw"] - abs(xb[rt_b])), t1),
                    uv_curb_top(CURB_STRIP - (b["_uv_hw"] - abs(xb[lt_b])), t1),
                )
            else:
                uvs = (
                    uv_top_bottom(xa[lt_a], t0, mat),
                    uv_top_bottom(xa[rt_a], t0, mat),
                    uv_top_bottom(xb[rt_b], t1, mat),
                    uv_top_bottom(xb[lt_b], t1, mat),
                )
            for f_top in add_quad_flat(bm, uv_layer, v4, mat, uvs,
                                       a.get("_up", WANT_UP)):
                if up_layer is not None:
                    f_top[up_layer] = 1

            v4b = (a[f"{right_role}_bot"], a[f"{left_role}_bot"],
                   b[f"{left_role}_bot"], b[f"{right_role}_bot"])
            uvsb = (
                uv_top_bottom(a["_uv_x"][right_role], su0, CURB),
                uv_top_bottom(a["_uv_x"][left_role], su0, CURB),
                uv_top_bottom(b["_uv_x"][left_role], su1, CURB),
                uv_top_bottom(b["_uv_x"][right_role], su1, CURB),
            )
            for f_bot in add_quad_flat(bm, uv_layer, v4b, CURB, uvsb,
                                       a.get("_up", WANT_UP) * -1.0):
                if hidden_layer is not None and not ACTIVE_KEEP_BOTTOM[0]:
                    f_bot[hidden_layer] = 1
                if up_layer is not None:
                    f_bot[up_layer] = -1

        for role in ROLES:
            side_sign = -1 if role in ("outer_near", "inner_near") else 1
            v4 = (a[f"{role}_bot"], a[f"{role}_top"], b[f"{role}_top"], b[f"{role}_bot"])
            uvs = (
                uv_curb_face(a["_height"], su0),
                uv_curb_face(a.get("_chamfer", 0.0), su0),
                uv_curb_face(b.get("_chamfer", 0.0), su1),
                uv_curb_face(b["_height"], su1),
            )
            want = a.get("_side", None)
            want = (want * float(mirror) if want is not None else out_dir(i)) * float(side_sign)
            f_wall = add_quad(bm, uv_layer, None, v4, CURB, uvs, want)
            if hidden_layer is not None and role in ("inner_near", "inner_far"):
                f_wall[hidden_layer] = 1

        for role in ("outer_near", "outer_far"):
            ch_a, ch_b = a.get("_chamfer", 0.0), b.get("_chamfer", 0.0)
            if (ch_a > 1e-6) != (ch_b > 1e-6):
                if DIAG_CHAMFER:
                    STATS["chamfer_gap"] += 1
                    if len(DIAG_SAMPLES) < DIAG_QUADS_SAMPLES + 6:
                        DIAG_SAMPLES.append(("chamfer-gap", [
                            tuple(round(x, 2) for x in a[f"{role}_top"].co),
                            tuple(round(x, 2) for x in b[f"{role}_top"].co)]))
                continue
            if ch_a > 1e-6 and ch_b > 1e-6:
                ch = f"{role}_chamfer"
                v4 = (a[f"{ch}_top"], a[f"{role}_top"], b[f"{role}_top"], b[f"{ch}_top"])
                uvs = (
                    uv_curb_face(0.0, su0),
                    uv_curb_face(a["_chamfer"], su0),
                    uv_curb_face(b["_chamfer"], su1),
                    uv_curb_face(0.0, su1),
                )
                ch_sign = -1.0 if role == "outer_near" else 1.0
                a_side = a.get("_side", None)
                base_out = (a_side * float(mirror)) if a_side is not None else out_dir(i)
                base_up = a.get("_up", Vector((0.0, 0.0, 1.0)))
                want_ch = (base_out * ch_sign + base_up).normalized()
                tag = 1 if want_ch.z > 0.05 else 0
                for f_ch in add_quad_flat(bm, uv_layer, v4, CURB, uvs, want_ch):
                    if f_ch is None:
                        continue
                    if up_layer is not None:
                        f_ch[up_layer] = tag
                    if DIAG_CHAMFER and f_ch.normal.z < -0.05:
                        STATS["chamfer_down"] += 1
                        if len(DIAG_SAMPLES) < DIAG_QUADS_SAMPLES + 6:
                            DIAG_SAMPLES.append(("chamfer-down", [
                                tuple(round(x, 2) for x in v.co) for v in f_ch.verts]))

    if not closed:
        for idx, sign in ((0, -1), (n - 1, 1)):
            cs = cross_sections[idx]
            edge_dist = uv_dists[idx]
            ACTIVE_S[0] = dists[idx]
            if ACTIVE_ZEBRA_WALK[0] is not None:
                slot = ACTIVE_ZEBRA_WALK[0](dists[idx])
                names = ACTIVE_WALK_SLOTS[0]
                if 0 <= slot < len(names):
                    ACTIVE_TEXTURE_SCALE[0] = texture_scale_for(names[slot])
            has_chamfer = cs.get("_chamfer", 0.0) > 1e-6
            cap_defs = [
                ("outer_near", "inner_near", CURB, uv_cap_curb, True),
                ("inner_near", "inner_far", WALK, uv_cap_walk, False),
                ("inner_far", "outer_far", CURB, uv_cap_curb, True),
            ]
            for role_a, role_b, mat, uv_fn, outer_side in cap_defs:
                cs_height = cs["_height"]
                outer_role = role_a if role_a in ("outer_near", "outer_far") else role_b
                if has_chamfer and outer_side:
                    ch = f"{outer_role}_chamfer"
                    if role_a == outer_role:
                        ring = [(role_b, -cs_height), (role_b, 0.0), (ch, 0.0), (role_a, -cs["_chamfer"]), (role_a, -cs_height)]
                    else:
                        ring = [(role_b, -cs_height), (role_b, -cs["_chamfer"]), (ch, 0.0), (role_a, 0.0), (role_a, -cs_height)]
                    if sign == -1:
                        ring = list(reversed(ring))
                    verts5 = [cs[f"{r}_bot"] if z == -cs_height else cs[f"{r}_top"] for r, z in ring]
                    cap_x = cs["_local_x"] if mat == WALK else cs["_uv_x"]
                    uvs5 = [uv_fn(edge_dist, sign, cap_x[r], 0.0, z) for r, z in ring]
                    want_cap = tangents[idx] * float(sign)
                    add_quad(bm, uv_layer, None, tuple(verts5), mat, uvs5, want_cap)
                else:
                    if sign == -1:
                        v4 = (cs[f"{role_b}_bot"], cs[f"{role_b}_top"], cs[f"{role_a}_top"], cs[f"{role_a}_bot"])
                        order = [role_b, role_b, role_a, role_a]
                        zs = [-cs_height, 0.0, 0.0, -cs_height]
                    else:
                        v4 = (cs[f"{role_a}_bot"], cs[f"{role_a}_top"], cs[f"{role_b}_top"], cs[f"{role_b}_bot"])
                        order = [role_a, role_a, role_b, role_b]
                        zs = [-cs_height, 0.0, 0.0, -cs_height]
                    cap_x = cs["_local_x"] if mat == WALK else cs["_uv_x"]
                    uvs = tuple(uv_fn(edge_dist, sign, cap_x[r], 0.0, z) for r, z in zip(order, zs))
                    want_cap = tangents[idx] * float(sign)
                    add_quad(bm, uv_layer, None, v4, mat, uvs, want_cap)


def finalize_bm(bm, mesh, name, hidden_layer=None, validate=True,
                 stats_vis=False, stats_col=False, warn_flipped=False, up_layer=None,
                 weld_dist=0.0, wall_dirs=None, face_refs=None):
    if weld_dist > 0.0 and bm.faces:
        before = len(bm.faces)
        bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=weld_dist)
        bmesh.ops.dissolve_degenerate(bm, dist=weld_dist, edges=bm.edges[:])
        bm.normal_update()
        STATS["col_degenerate_removed"] = (STATS.get("col_degenerate_removed", 0)
                                           + max(0, before - len(bm.faces)))

    if VALIDATE_MESH and validate:
        validate_watertight(bm, name)

    bm.normal_update()

    if up_layer is not None and bm.faces:
        score = 0.0
        scale = 0.0
        for f in bm.faces:
            tag = f[up_layer]
            if not tag:
                continue
            w = f.calc_area()
            score += tag * f.normal.z * w
            scale += w
        if scale > 1e-9:
            ratio = score / scale
            if ratio < 0.0:
                bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
                bm.normal_update()
                ratio = -ratio
            if ratio < 0.5:
                print(f"  [normals] warning: '{name}' - inconsistent orientation (score {ratio:.2f}). "
                      f"A global flip will not fix it; there is probably overlapping geometry.")

    if stats_vis:
        STATS["faces_full"] += len(bm.faces)
        STATS["verts_full"] += len(bm.verts)

    if hidden_layer is not None:
        doomed = [f for f in bm.faces if f[hidden_layer]]
        if doomed:
            bmesh.ops.delete(bm, geom=doomed, context="FACES")
        loose = [v for v in bm.verts if not v.link_faces]
        if loose:
            bmesh.ops.delete(bm, geom=loose, context="VERTS")
        bm.normal_update()

    if up_layer is not None and FORCE_FACE_ORIENTATION:
        wrong = [f for f in bm.faces
                 if f[up_layer] and f[up_layer] * f.normal.z < -1e-4]
        if wrong:
            bmesh.ops.reverse_faces(bm, faces=wrong)
            bm.normal_update()
            STATS["faces_reoriented"] += len(wrong)
            if stats_col:
                STATS["col_faces_reoriented"] = (STATS.get("col_faces_reoriented", 0)
                                                 + len(wrong))
            print(f"  [normals] '{name}': {len(wrong)} faces corrected from their tag")

    refs = list(wall_dirs or []) + list(face_refs or [])
    if refs:
        bm.normal_update()
        wrong = [f for f, want in refs
                 if f.is_valid and f.normal.dot(want) < -1e-4]
        if wrong:
            bmesh.ops.reverse_faces(bm, faces=wrong)
            bm.normal_update()
            STATS["wall_faces_reoriented"] = (STATS.get("wall_faces_reoriented", 0)
                                              + len(wrong))
            print(f"  [wall] '{name}': {len(wrong)} wall faces flipped outward")

    if SHADE_SMOOTH and up_layer is not None and not name.startswith("Colmesh_"):
        bm.normal_update()
        cos_crease = math.cos(math.radians(SMOOTH_CREASE_ANGLE_DEG))
        for f in bm.faces:
            f.smooth = True
        n_soft, n_sharp = 0, 0
        for e in bm.edges:
            lf = e.link_faces
            if len(lf) != 2:
                e.smooth = False
                n_sharp += 1
                continue
            a, b = lf
            tag = a[up_layer]
            if tag != b[up_layer] or (tag == 0 and a.normal.dot(b.normal) < cos_crease):
                e.smooth = False
                n_sharp += 1
            else:
                n_soft += 1
        STATS["smooth_top_edges"] = STATS.get("smooth_top_edges", 0) + n_soft
        STATS["sharp_edges"] = STATS.get("sharp_edges", 0) + n_sharp
        print(f"  [shade] '{name}': {len(bm.faces)} faces smooth, "
              f"{n_soft} edges soft, {n_sharp} edges hard")

    if DIAG_WALL_TWIST:
        bm.normal_update()
        rows = []
        for f in bm.faces:
            vs = f.verts[:]
            if len(vs) != 4 or abs(f.normal.z) > 0.5:
                continue
            n1 = (vs[1].co - vs[0].co).cross(vs[2].co - vs[0].co)
            n2 = (vs[2].co - vs[0].co).cross(vs[3].co - vs[0].co)
            if n1.length < 1e-12 or n2.length < 1e-12:
                continue
            twist = math.degrees(n1.normalized().angle(n2.normalized()))
            longest = max((vs[i].co - vs[(i + 1) % 4].co).length for i in range(4))
            thin = f.calc_area() / (longest * longest) if longest > 1e-9 else 0.0
            rows.append((twist, thin, f.calc_center_median()))
        if rows:
            worst = sorted(rows, key=lambda r: -r[0])[:5]
            if worst[0][0] > 1.0:
                print(f"  [twist] '{name}': most twisted wall faces")
                for tw, th, c in worst:
                    print(f"          twist {tw:6.2f}deg  thinness {th:.4f}  "
                          f"at ({c.x:.2f}, {c.y:.2f}, {c.z:.2f})")
            slim = sorted(rows, key=lambda r: r[1])[:5]
            if slim[0][1] < 0.02:
                print(f"  [thin]  '{name}': thinnest wall faces")
                for tw, th, c in slim:
                    print(f"          thinness {th:.5f}  twist {tw:5.2f}deg  "
                          f"at ({c.x:.2f}, {c.y:.2f}, {c.z:.2f})")

    if hidden_layer is not None:
        if warn_flipped:
            flipped = sum(1 for f in bm.faces
                          if f.normal.z < -0.5
                          and not (up_layer is not None and f[up_layer] == -1))
            if flipped:
                print(f"  [normals] warning: '{name}' - {flipped} faces point downward")
        bm.faces.layers.int.remove(hidden_layer)
    if up_layer is not None:
        bm.faces.layers.int.remove(up_layer)

    if stats_vis:
        STATS["faces_vis"] += len(bm.faces)
        STATS["verts_vis"] += len(bm.verts)
    if stats_col:
        STATS["faces_col"] += len(bm.faces)
        STATS["verts_col"] += len(bm.verts)

    bm.to_mesh(mesh)
    bm.free()
    return mesh


def build_mesh_for_side(points, tangents, dists, widths, heights, center_offset, mirror, name,
                         extra_z_offset=0.0, terrain_sampler=None, closed=False, bevel_outer_edges=False,
                         skip_hidden=False, count_stats=False, caps=None):
    mesh = bpy.data.meshes.new(name)
    bm = bmesh.new()
    uv_layer = bm.loops.layers.uv.verify()
    hidden_layer = bm.faces.layers.int.new("pit_hidden") if skip_hidden else None
    up_layer = bm.faces.layers.int.new("pit_up")

    FACE_REFS[0] = [] if ACTIVE_UP[0] is not None else None
    build_sidewalk_side(bm, uv_layer, points, tangents, dists, widths, heights, center_offset, mirror,
                         extra_z_offset, terrain_sampler, closed, bevel_outer_edges, hidden_layer, caps,
                         up_layer, name)
    refs = FACE_REFS[0]
    FACE_REFS[0] = None

    return finalize_bm(bm, mesh, name, hidden_layer, stats_vis=count_stats,
                       warn_flipped=True, up_layer=up_layer, face_refs=refs)


def harmonize_island_z(pts, spans, radius):
    n = len(pts)
    if n < 4 or radius <= 0:
        return pts
    r2 = radius * radius
    inv2s2 = 1.0 / (2.0 * (radius * 0.5) ** 2)
    out = []
    for i in range(n):
        p = pts[i]
        wsum = 0.0
        zsum = 0.0
        for j in range(n):
            q = pts[j]
            d2 = (p[0] - q[0]) ** 2 + (p[1] - q[1]) ** 2
            if d2 > r2:
                continue
            w = math.exp(-d2 * inv2s2) / (spans[j] + 0.05)
            wsum += w
            zsum += w * q[2]
        out.append((p[0], p[1], zsum / wsum if wsum > 1e-12 else p[2]))
    return out


def island_twist(outer, skip=6):
    n = len(outer)
    if n < 8:
        return 0.0, None
    worst, where = 0.0, None
    for i in range(n):
        p = outer[i]
        best_d, best_z = 1e18, None
        for j in range(n):
            if abs(((j - i + n // 2) % n) - n // 2) <= skip:
                continue
            q = outer[j]
            d = (p[0] - q[0]) ** 2 + (p[1] - q[1]) ** 2
            if d < best_d:
                best_d, best_z = d, q[2]
        if best_z is not None:
            dz = abs(p[2] - best_z)
            if dz > worst:
                worst, where = dz, p
    return worst, where


def build_island_mesh(ring, name, height, extra_z_offset=0.0, terrain_sampler=None,
                      skip_hidden=False, count_stats=False, simple=False, collision=False):
    mesh = bpy.data.meshes.new(name)
    bm = bmesh.new()
    uv_layer = None if simple else bm.loops.layers.uv.verify()
    hidden_layer = bm.faces.layers.int.new("pit_hidden") if skip_hidden else None
    up_layer = bm.faces.layers.int.new("pit_up")

    outer = [(p[0], p[1], p[2]) for p in ring]
    if _signed_area_2d(outer) < 0:
        outer = list(reversed(outer))
    n = len(outer)

    if not simple and ISLAND_WARN_TWIST > 0 and terrain_sampler is None:
        dz, where = island_twist(outer)
        if dz > ISLAND_WARN_TWIST and where is not None:
            print(f"  [island] '{name}': sides are not level - {dz:.2f}m difference "
                  f"near ({where[0]:.0f}, {where[1]:.0f}). The surface twists there.")
            print(f"  [island] usually caused by a decal with a long straight run facing one with "
                  f"dense nodes - add a node in that area.")

    inner, inner_tris = None, None
    if not simple and CURB_STRIP > 1e-6:
        cand, n_narrow = fit_inner_ring(outer, offset_polygon_inward(outer, CURB_STRIP),
                                        CURB_STRIP)
        a_out, a_in = _signed_area_2d(outer), _signed_area_2d(cand)
        if a_in > ISLAND_MIN_AREA * 0.05 and a_in < a_out:
            tris = triangulate_polygon(cand)
            cov = _coverage(cand, tris)
            if cov >= 0.90:
                inner, inner_tris = cand, tris
                worst = max((max(cand[a][2], cand[b][2], cand[c][2])
                             - min(cand[a][2], cand[b][2], cand[c][2])
                             for a, b, c in tris), default=0.0)
                if worst > height and terrain_sampler is None:
                    print(f"  [island] warning: '{name}' - fill triangle with a height difference of "
                          f"{worst:.2f}m (sidewalk thickness {height:.2f}). The surface does not follow "
                          f"the road there.")
                if n_narrow > len(outer) * 0.25:
                    print(f"  [island] '{name}': {n_narrow} of {len(outer)} vertices "
                          f"lie in a region narrower than {2*CURB_STRIP:.2f}m - the walk strip vanishes there")
            else:
                print(f"  [island] '{name}': the inner triangulation covered only {100*cov:.0f}% - "
                      f"the island is all curb")
        else:
            print(f"  [island] '{name}': no room for a walk strip (inner area {a_in:.2f} "
                  f"of {a_out:.2f}) - the island is all curb")

    if DIAG_QUADS and inner and not simple:
        ws = [math.hypot(inner[k][0] - outer[k][0], inner[k][1] - outer[k][1])
              for k in range(n)]
        thin = [k for k, w in enumerate(ws) if w < CURB_STRIP * 0.5]
        print(f"  [island] '{name}': actual curb width min/mean/max = "
              f"{min(ws):.3f}/{sum(ws)/len(ws):.3f}/{max(ws):.3f}m "
              f"(target {CURB_STRIP:.2f})  |  {len(thin)} vertices below half the target")
        for k in thin[:4]:
            print(f"      thin ({ws[k]:.3f}m) at ({outer[k][0]:.1f}, {outer[k][1]:.1f})")

    slope_h, slope_v = 0.0, 0.0
    slope_ring = None
    if CURB_PROFILE_ENABLED:
        prof = ACTIVE_CURB_PROFILE[0]
        slope_v = min(prof["exposed"], height)
        slope_h = min(math.tan(math.radians(prof["angle"])) * slope_v, CURB_STRIP * 0.9)
    if slope_h > 1e-6:
        cand, _ = fit_inner_ring(outer, offset_polygon_inward(outer, slope_h), slope_h)
        a_out, a_in = _signed_area_2d(outer), _signed_area_2d(cand)
        if len(cand) == n and a_in > 0.0 and a_in < a_out:
            slope_ring = cand
        else:
            slope_h, slope_v = 0.0, 0.0

    def mkz(p, drop):
        z = terrain_sampler(p[0], p[1]) if terrain_sampler is not None else p[2]
        return bm.verts.new(Vector((p[0], p[1], z + Z_OFFSET + extra_z_offset - drop)))

    top_ring = slope_ring or outer
    o_bot = [mkz(p, height) for p in outer]
    o_top = [mkz(p, 0.0) for p in top_ring]
    o_mid = [mkz(p, slope_v) for p in outer] if slope_ring else o_top

    i_top, i_bot = [], []
    if inner:
        for p in inner:
            i_top.append(mkz(p, 0.0))
            i_bot.append(mkz(p, height))

    perim = [0.0]
    for i in range(1, n):
        perim.append(perim[-1] + math.hypot(outer[i][0] - outer[i-1][0],
                                            outer[i][1] - outer[i-1][1]))
    total_perim = perim[-1] + math.hypot(outer[0][0] - outer[-1][0],
                                         outer[0][1] - outer[-1][1])

    def face(verts, mat, uvs=None, hidden=False, up=0, want=None):
        if len(set(id(v) for v in verts)) != len(verts):
            return None
        verts, uvs = orient_to(tuple(verts), tuple(uvs) if uvs else uvs, want)
        try:
            f = bm.faces.new(tuple(verts))
        except ValueError:
            return None
        f.material_index = 0 if collision else resolve_mat_index(mat)
        if uv_layer is not None and uvs:
            for loop, uv in zip(f.loops, uvs):
                loop[uv_layer].uv = uv
        if hidden and hidden_layer is not None:
            f[hidden_layer] = 1
        f[up_layer] = up
        return f

    def face_flat(verts, mat, uvs=None, hidden=False, up=0, want=None):
        tris = quad_fan_diagonal(verts) if len(verts) == 4 else None
        if tris is None:
            return [face(verts, mat, uvs, hidden, up, want)]
        return [face([verts[i] for i in t], mat,
                     ([uvs[i] for i in t] if uvs else None), hidden, up, want)
                for t in tris]

    wall_dirs = []
    for i in range(n):
        j = (i + 1) % n
        s0 = perim[i]
        s1 = total_perim if j == 0 else perim[j]
        wx, wy = outer[j][1] - outer[i][1], outer[i][0] - outer[j][0]
        want_out = Vector((wx, wy, 0.0))
        f_low = face([o_bot[i], o_mid[i], o_mid[j], o_bot[j]], CURB,
                     [uv_curb_face(height, s0), uv_curb_face(slope_v, s0),
                      uv_curb_face(slope_v, s1), uv_curb_face(height, s1)],
                     want=want_out)
        f_up = None
        if slope_ring:
            f_up = face([o_mid[i], o_top[i], o_top[j], o_mid[j]], CURB,
                        [uv_curb_face(slope_v, s0), uv_curb_face(0.0, s0),
                         uv_curb_face(0.0, s1), uv_curb_face(slope_v, s1)],
                        want=want_out)
        for f in (f_low, f_up):
            if f is not None:
                wall_dirs.append((f, want_out))

    if inner:
        for i in range(n):
            j = (i + 1) % n
            s0 = perim[i]
            s1 = total_perim if j == 0 else perim[j]
            flat_w = CURB_STRIP - slope_h
            face_flat([o_top[i], o_top[j], i_top[j], i_top[i]], CURB,
                      [uv_curb_top(flat_w, s0), uv_curb_top(flat_w, s1),
                       uv_curb_top(0.0, s1), uv_curb_top(0.0, s0)],
                      up=1, want=WANT_UP)
            face_flat([i_bot[i], i_bot[j], o_bot[j], o_bot[i]], CURB,
                      [uv_curb_top(0.0, s0), uv_curb_top(0.0, s1),
                       uv_curb_top(CURB_STRIP, s1), uv_curb_top(CURB_STRIP, s0)],
                      hidden=True, up=-1, want=WANT_DOWN)

        def uv_fill(p):
            su, sv = _texuv(WALK)
            return (p[0] / su + 0.5, p[1] / sv + 0.5)

        for a, b, c in inner_tris:
            face([i_top[a], i_top[b], i_top[c]], WALK,
                 [uv_fill(inner[a]), uv_fill(inner[b]), uv_fill(inner[c])], up=1, want=WANT_UP)
            face([i_bot[c], i_bot[b], i_bot[a]], WALK,
                 [uv_fill(inner[c]), uv_fill(inner[b]), uv_fill(inner[a])],
                 hidden=True, up=-1, want=WANT_DOWN)
    else:
        def uv_fill_c(p):
            sc = _tex(CURB)
            if not CURB_ATLAS_ACTIVE[0]:
                return (p[0] / sc + 0.5, p[1] / sc + 0.5)
            frac = (p[1] / sc) % 1.0
            return (p[0] / sc + 0.5, curb_top_v(frac * CURB_STRIP))

        outer_tris = triangulate_polygon(top_ring)
        cov = _coverage(top_ring, outer_tris)
        if cov < 0.99:
            print(f"  [island] warning: '{name}' - triangulation covered only {100*cov:.0f}% "
                  f"of the polygon. The mesh will have a hole.")
        for a, b, c in outer_tris:
            face([o_top[a], o_top[b], o_top[c]], CURB,
                 [uv_fill_c(top_ring[a]), uv_fill_c(top_ring[b]), uv_fill_c(top_ring[c])],
                 up=1, want=WANT_UP)
            face([o_bot[c], o_bot[b], o_bot[a]], CURB,
                 [uv_fill_c(outer[c]), uv_fill_c(outer[b]), uv_fill_c(outer[a])],
                 hidden=True, up=-1, want=WANT_DOWN)

    return finalize_bm(bm, mesh, name, hidden_layer, validate=not simple,
                       stats_vis=count_stats, stats_col=simple, up_layer=up_layer,
                       warn_flipped=not simple,
                       weld_dist=(COLMESH_WELD_DIST if simple else 0.0),
                       wall_dirs=wall_dirs)


def build_colmesh_for_side(points, tangents, dists, widths, heights, center_offset, mirror, name,
                            extra_z_offset=0.0, terrain_sampler=None, closed=False, bevel_outer_edges=False,
                            caps=None):
    mesh = bpy.data.meshes.new(name)
    bm = bmesh.new()

    miter = miter_scales(points, tangents, closed)
    check_offsets(f"{name} (collision)", points, tangents, widths, miter, closed)

    cs_list = []
    for i, (p, t, w, h) in enumerate(zip(points, tangents, widths, heights)):
        normal = Vector((-t.y, t.x, 0.0)) * miter[i]
        c = caps[i] if (caps and i < len(caps)) else None
        cs_list.append(build_cross_section(bm, p, normal, center_offset, mirror, w, h,
                                            extra_z_offset, terrain_sampler, bevel_outer_edges,
                                            inset_override=(c["inset"] if c else None),
                                            cap_shrink=(c.get("shrink") if c else None),
                                            up_world=(ACTIVE_UP[0](dists[i])
                                                      if ACTIVE_UP[0] is not None else None),
                                            tangent=(tangent3d(points, i, closed)
                                                     if ACTIVE_UP[0] is not None else None)))

    up_layer = bm.faces.layers.int.new("pit_up")

    def ring(cs, plain=False):
        r = [cs["outer_near_bot"], cs["outer_near_top"]]
        k = [False, True]
        if not plain and cs.get("_chamfer", 0.0) > 1e-6:
            r.append(cs["outer_near_chamfer_top"]); k.append(True)
            r.append(cs["outer_far_chamfer_top"]); k.append(True)
        r.append(cs["outer_far_top"]); k.append(True)
        r.append(cs["outer_far_bot"]); k.append(False)
        return r, k

    def face(vs, up=0, want=None):
        if len(set(id(v) for v in vs)) != len(vs):
            return None
        vs, _ = orient_to(tuple(vs), None, want)
        try:
            f = bm.faces.new(tuple(vs))
        except ValueError:
            return None
        f[up_layer] = up
        return f

    n = len(points)
    seg_count = n if closed else n - 1
    def out_at(i):
        tn = tangents[i]
        return Vector((-tn.y, tn.x, 0.0)) * float(mirror)

    for i in range(seg_count):
        ra, ka = ring(cs_list[i])
        rb, _kb = ring(cs_list[(i + 1) % n])
        if len(ra) != len(rb):
            ra, ka = ring(cs_list[i], plain=True)
            rb, _kb = ring(cs_list[(i + 1) % n], plain=True)
            STATS["col_ring_fallback"] = STATS.get("col_ring_fallback", 0) + 1
        for k in range(len(ra) - 1):
            up = 1 if (ka[k] and ka[k + 1]) else 0
            if up:
                want = WANT_UP
            else:
                want = out_at(i) * (-1.0 if k == 0 else 1.0)
            face((ra[k], ra[k + 1], rb[k + 1], rb[k]), up, want)
        face((ra[-1], ra[0], rb[0], rb[-1]), -1, WANT_DOWN)

    if not closed:
        face(ring(cs_list[0])[0], 0, tangents[0] * -1.0)
        face(ring(cs_list[-1])[0], 0, tangents[-1] * 1.0)

    loose = [v for v in bm.verts if not v.link_faces]
    if loose:
        bmesh.ops.delete(bm, geom=loose, context="VERTS")

    return finalize_bm(bm, mesh, name, validate=True, stats_col=True, up_layer=up_layer,
                       weld_dist=COLMESH_WELD_DIST)


def validate_watertight(bm, name):
    counts = {}
    for f in bm.faces:
        vs = list(f.verts)
        n = len(vs)
        for i in range(n):
            key = frozenset((vs[i], vs[(i + 1) % n]))
            counts[key] = counts.get(key, 0) + 1
    holes = sum(1 for c in counts.values() if c == 1)
    if holes:
        print(f"  [validate] warning: '{name}' - {holes} open edges (hole in the mesh)")
    return holes


def _kb(n):
    return f"{n / 1024.0:.1f} KB" if n < 1024 * 1024 else f"{n / 1048576.0:.2f} MB"


_FLOAT_RE = re.compile(r"-?\d*\.\d+(?:[eE][-+]?\d+)?|-?\d+[eE][-+]?\d+")


def shrink_dae_floats(path, decimals):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            txt = fh.read()
    except Exception as exc:
        print(f"  [dae] skipping float rounding: {exc}")
        return None

    before = len(txt.encode("utf-8"))

    def fmt(m):
        try:
            v = float(m.group(0))
        except ValueError:
            return m.group(0)
        s = f"{v:.{decimals}f}"
        if "." in s:
            s = s.rstrip("0").rstrip(".")
        if s in ("", "-", "-0"):
            s = "0"
        return s

    def body(m):
        return m.group(1) + _FLOAT_RE.sub(fmt, m.group(2)) + m.group(3)

    try:
        out = re.sub(r"(<float_array\b[^>]*>)(.*?)(</float_array>)", body, txt, flags=re.S)
    except Exception as exc:
        print(f"  [dae] float rounding failed, file left unchanged: {exc}")
        return None

    after = len(out.encode("utf-8"))
    if after >= before:
        return (before, before)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(out)
    return (before, after)


def print_size_report(size_raw, size_final):
    f_full, v_full = STATS["faces_full"], STATS["verts_full"]
    f_vis, v_vis = STATS["faces_vis"], STATS["verts_vis"]
    f_col, v_col = STATS["faces_col"], STATS["verts_col"]

    old_f, old_v = f_full * 2, v_full * 2
    new_f, new_v = f_vis + f_col, v_vis + v_col

    def pct(new, old):
        return f"{100.0 * (1 - new / float(old)):.1f}%" if old else "-"

    print("")
    print("=" * 62)
    print("  optimisation summary")
    print("=" * 62)
    if SIMPLIFY_PATH:
        pb, pa = STATS["pts_before"], STATS["pts_after"]
        print(f"  path points   : {pb:>9,} -> {pa:>9,}   ({pct(pa, pb)} smaller)")
    print(f"  faces (total) : {old_f:>9,} -> {new_f:>9,}   ({pct(new_f, old_f)} smaller)")
    print(f"     visual     : {f_full:>9,} -> {f_vis:>9,}   ({pct(f_vis, f_full)} smaller)")
    print(f"     collision  : {f_full:>9,} -> {f_col:>9,}   ({pct(f_col, f_full)} smaller)")
    print(f"  vertices      : {old_v:>9,} -> {new_v:>9,}   ({pct(new_v, old_v)} smaller)")
    print(f"  UV layer      : {'visual only' if not COLMESH_UV or SIMPLE_COLMESH else 'both'}")
    if STYLE_USAGE["curb"] or STYLE_USAGE["walk"]:
        print("-" * 62)
        print("  style variation")
        if STYLE_USAGE["walk"]:
            print("     walk:")
            for nm, cnt in sorted(STYLE_USAGE["walk"].items(), key=lambda kv: -kv[1]):
                print(f"        {nm:<22} {cnt:>4} objects  (scale {texture_scale_for(nm)})")
        if STYLE_USAGE["curb"]:
            print("     curb:")
            for nm, cnt in sorted(STYLE_USAGE["curb"].items(), key=lambda kv: -kv[1]):
                cst = STYLES.curb_styles.get(nm) or {}
                if "scale" in cst:
                    extra = f"scale {_pair(cst['scale'])}"
                elif CURB_IS_ATLAS and "band" in cst:
                    extra = f"band {cst['band']}"
                else:
                    extra = ""
                print(f"        {str(nm):<16} {cst.get('label', ''):<14} "
                      f"{cnt:>4} objects  {extra}")
        if STYLE_USAGE.get("src"):
            print("     style source:")
            for k, cnt in sorted(STYLE_USAGE["src"].items(), key=lambda kv: -kv[1]):
                print(f"        {k:<22} {cnt:>4} objects")
    if STYLES.unknown_tags:
        print("-" * 62)
        print("  tags not present in the config (fell back to the default)")
        for (axis, val), ids in sorted(STYLES.unknown_tags.items()):
            head = ", ".join(ids[:3]) + (" ..." if len(ids) > 3 else "")
            print(f"     {axis}={val!r:<20} {len(ids):>4} objects   {head}")
    tot = sum(STATS["quad_" + k] for k in ("convex", "concave", "bowtie", "degenerate"))
    if STATS["faces_reoriented"]:
        print(f"  faces fixed   : {STATS['faces_reoriented']:>9,}   "
              f"(normal contradicted the up tag, so it was flipped)")
    if STATS.get("col_faces_reoriented"):
        print(f"  collision     : {STATS['col_faces_reoriented']:>9,}   "
              f"faces were inverted and fixed (inverted triangle = inward push = tyre puncture)")
    if STATS.get("col_degenerate_removed"):
        print(f"  collision     : {STATS['col_degenerate_removed']:>9,}   "
              f"zero-area faces welded/dissolved (undefined normal = tyre puncture)")
    if STATS.get("smooth_top_edges"):
        print(f"  smooth shading: {STATS['smooth_top_edges']:>9,}   "
              f"edges shaded soft (normals averaged across them)")
    if STATS.get("sharp_edges"):
        print(f"  sharp edges   : {STATS['sharp_edges']:>9,}   "
              f"kerb/crease edges kept hard (>{SMOOTH_CREASE_ANGLE_DEG} deg or across an up tag)")
    if STATS.get("wall_faces_reoriented"):
        print(f"  island walls  : {STATS['wall_faces_reoriented']:>9,}   "
              f"wall faces flipped outward (up=0, outside tag enforcement)")
    if STATS.get("cap_rings_dropped"):
        print(f"  caps          : {STATS['cap_rings_dropped']:>9,}   "
              f"sliver rings dropped (~0 area face in the collision mesh)")
    report_validation()
    if STATS.get("sharp_corners"):
        print(f"  sharp corners : {STATS['sharp_corners']:>9,}   "
              f"mitred instead of rounded (too tight for the authored width)")
    if STATS.get("width_clamped"):
        print(f"  width clamp   : {STATS['width_clamped']:>9,}   "
              f"roads narrowed at corners tighter than the authored half-width")
    if STATS.get("walk_split_roads"):
        print(f"  walk bands    : {STATS['walk_split_roads']:>9,}   "
              f"roads whose top surface was split across the width (helicoid)")
    if STATS.get("fold_rings_dropped"):
        print(f"  fold guard    : {STATS['fold_rings_dropped']:>9,}   "
              f"rings dropped (spaced closer than the kerb offset could turn)")
    if STATS.get("col_ring_fallback"):
        print(f"  collision     : {STATS['col_ring_fallback']:>9,}   "
              f"segments built without a chamfer (previously dropped, leaving a hole)")
    if STATS.get("chamfer_gap") or STATS.get("chamfer_down"):
        print("-" * 62)
        print("  curb lip (the chamfer face is the entire visible height)")
        print(f"     skipped    : {STATS.get('chamfer_gap', 0):>9,}   "
              f"(chamfer inconsistent between two sections -> triangular hole)")
        print(f"     facing down: {STATS.get('chamfer_down', 0):>9,}   "
              f"(built inverted -> invisible, a 'missing tooth')")
    if tot:
        print("-" * 62)
        print(f"  horizontal face classification ({tot:,} total) | splitting "
              f"{'on' if SPLIT_FLAT_QUADS else 'off'}")
        for k, label in (("convex", "convex    "), ("concave", "concave   "),
                         ("bowtie", "bowtie    "), ("degenerate", "degenerate")):
            v = STATS["quad_" + k]
            note = "  <- split into 2 triangles" if (k == "bowtie" and v) else ""
            print(f"     {label} : {v:>9,}   ({100.0 * v / tot:4.1f}%){note}")
        if STATS["quad_bowtie"]:
            print("     bowtie should be 0 after welding. If any remain, jump to the samples below;")
            print("     there are probably overlapping decals that should not have been merged.")
        if DIAG_SAMPLES:
            print("  samples (jump to them in Blender with the N-panel):")
            for kind, pts in DIAG_SAMPLES:
                print(f"     {kind:<10} " + "  ".join(str(p) for p in pts))
    print("-" * 62)
    print(f"  DAE after export: {_kb(size_raw)}")
    if size_final != size_raw:
        print(f"  DAE final       : {_kb(size_final)}")
    print("=" * 62)
    print("  Note: the numbers above compare against the original script on the same data,")
    print("  not against your previous file size (point decimation also affects that).")
    print("")


def main():
    global TERRAIN_SCAN_FILES
    apply_styles(_load_style_config())
    print("=" * 62)
    print(f"  map: {LEVEL_NAME}")
    print(f"  config: {STYLE_CONFIG_NAME}  "
          f"({len(STYLES.curb_styles)} curb styles, {len(STYLES.walk_styles)} paving)")
    print(f"  materials: curb={CURB_MATERIAL_NAME!r}"
          + (f"  meshroad-curb={MESHROAD_CURB_MATERIAL_NAME!r}"
             if MESHROAD_CURB_MATERIAL_NAME != CURB_MATERIAL_NAME else "")
          + ("  (atlas)" if CURB_IS_ATLAS else ""))
    print("=" * 62)

    road_files, TERRAIN_SCAN_FILES = find_items_files()
    roads = load_all_centerlines(road_files, ROAD_MATERIAL_FILTER)
    print(f"Found {len(roads)} roads to process")

    if MERGE_ZEBRA_JUNCTIONS:
        before = len(roads)
        roads = merge_zebra_roads(roads)
        print(f"After merging zebra junctions: {before} -> {len(roads)} objects")

    n_marked = mark_joined_ends(roads)
    if n_marked:
        print(f"  [caps] {n_marked} ends meet another sidewalk - built flush, without a cap")

    n_hair, hair_pairs = flush_hairpin_tips(roads)
    if n_hair:
        print(f"  [caps] {n_hair} sharp V meetings -> shared rounded tip")

    if HAIRPIN_UNION and hair_pairs:
        consumed, made = [], []
        for rd_i, e_i, rd_j, e_j, tip in hair_pairs:
            ring = hairpin_union_ring(rd_i, e_i, rd_j, e_j, tip)
            if ring is None:
                print(f"  [hairpin] could not compute a union outline - left as 2 overlapping strips")
                continue
            consumed.extend([id(rd_i), id(rd_j)])
            made.append({
                "source": "island", "name": (rd_i.get("name") or rd_i.get("persistentId")),
                "over_objects": bool(rd_i.get("over_objects") or rd_j.get("over_objects")),
                "persistentId": rd_i.get("persistentId"), "material": rd_i.get("material"),
                "group": rd_i.get("group", ""),
                "fields": rd_i.get("fields") or {},
                "ring": ring,
                "nodes": [{"x": p[0], "y": p[1], "z": p[2], "width": 0.0} for p in ring],
                "parts": 2, "area": abs(_signed_area_2d(ring)), "hairpin": True,
            })
        if made:
            roads = [r for r in roads if id(r) not in consumed] + made
            for m in made:
                print(f"  [hairpin] 2 strips -> one polygon, {len(m['ring'])} vertices, "
                      f"{m['area']:.1f} sq m")

    signs = []
    if SIDE in ("left", "both"):
        signs.append(1)
    if SIDE in ("right", "both"):
        signs.append(-1)

    bpy.data.materials.get(SIDEWALK_MATERIAL_NAME) or bpy.data.materials.new(SIDEWALK_MATERIAL_NAME)
    mat_curb = bpy.data.materials.get(CURB_MATERIAL_NAME) or bpy.data.materials.new(CURB_MATERIAL_NAME)
    bpy.data.materials.get(MESHROAD_CURB_MATERIAL_NAME) or bpy.data.materials.new(MESHROAD_CURB_MATERIAL_NAME)

    for nm in list(bpy.data.objects.keys()):
        if nm.startswith(OBJECT_NAME) or nm.startswith("Colmesh_") or nm in ("base00", "start01"):
            bpy.data.objects.remove(bpy.data.objects[nm], do_unlink=True)
    for nm in list(bpy.data.meshes.keys()):
        if nm.startswith(OBJECT_NAME) or nm.startswith("Colmesh_"):
            mesh = bpy.data.meshes[nm]
            if mesh.users == 0:
                bpy.data.meshes.remove(mesh)

    base00 = bpy.data.objects.new("base00", None)
    bpy.context.collection.objects.link(base00)
    start01 = bpy.data.objects.new("start01", None)
    start01.parent = base00
    bpy.context.collection.objects.link(start01)

    all_objs = [base00, start01]

    terrain_sampler = get_terrain_sampler() if USE_TERRAIN_HEIGHT else None

    def z_source(road):
        if not TERRAIN_UNLESS_OVER_OBJECTS:
            return None
        return None if road.get("over_objects") else terrain_sampler

    def pick_style(road, r_idx):
        key = road.get("persistentId") or road.get("name") or f"idx{r_idx}"
        st = STYLES.resolve(road.get("fields") or {}, key)

        if st["profile"]:
            ACTIVE_CURB_PROFILE[0] = CURB_PROFILES[st["profile"]]
            STYLE_USAGE.setdefault("profile", {})
            STYLE_USAGE["profile"][st["profile"]] = STYLE_USAGE["profile"].get(st["profile"], 0) + 1

        ACTIVE_ZEBRA[0] = st["curb_band_at"]
        ACTIVE_ZEBRA_WALK[0] = st["walk_slot_at"]
        ACTIVE_CURB_BAND[0] = st["curb_band"]
        ACTIVE_CURB_STYLE_SCALE[0] = st["curb_scale"]
        ACTIVE_WALK_SLOTS[0] = st["walk_slots"]
        ACTIVE_TEXTURE_SCALE[0] = st["walk_scale"]

        walk_name, extra = st["walk_material"], st["extras"]
        mats = [(bpy.data.materials.get(nm) or bpy.data.materials.new(nm))
                for nm in [walk_name] + extra]

        curb_key = "alternating" if st["curb_band_at"] else (st["curb_style"] or st["curb_band"])
        STYLE_USAGE["curb"][curb_key] = STYLE_USAGE["curb"].get(curb_key, 0) + 1
        for nm in [walk_name] + extra:
            STYLE_USAGE["walk"][nm] = STYLE_USAGE["walk"].get(nm, 0) + 1
        src = "tag" if st["tagged"] else "random"
        STYLE_USAGE["src"][src] = STYLE_USAGE["src"].get(src, 0) + 1
        return mats, walk_name, st

    for r_idx, road in enumerate(roads):
        if road.get("source") == "island":
            set_curb_profile("island")
            walk_mats, walk_name, _ = pick_style(road, r_idx)
            ACTIVE_UP[0] = None
            ACTIVE_TURN_SCALE[0] = 1.0
            ACTIVE_KEEP_BOTTOM[0] = False
            ACTIVE_WALK_SPLIT[0] = False
            ACTIVE_TEXTURE_SCALE[1] = curb_scale_for(CURB_MATERIAL_NAME)
            CURB_ATLAS_ACTIVE[0] = CURB_IS_ATLAS
            mesh_name = f"{OBJECT_NAME}_R{r_idx}_I"
            isl_terrain = z_source(road)
            print(f"Road {r_idx}: traffic island -> full polygon "
                  f"({len(road['ring'])} vertices, {road['area']:.1f} sq m, "
                  f"height from {'nodes (overObjects)' if isl_terrain is None else 'terrain'})")
            if terrain_sampler is not None and isl_terrain is not None:
                diffs = [p[2] - terrain_sampler(p[0], p[1]) for p in road["ring"][::7]]
                if diffs:
                    lo, hi = min(diffs), max(diffs)
                    if max(abs(lo), abs(hi)) > 0.5:
                        print(f"    [island] warning: decal Z deviates from the ground by "
                              f"{lo:+.2f}..{hi:+.2f} m, but they have no overObjects. "
                              f"The island is built at ground height and may end up buried - set overObjects in the map.")
            mesh_data = build_island_mesh(
                road["ring"], mesh_name, HEIGHT, DECAL_HEIGHT_OFFSET, isl_terrain,
                skip_hidden=OPTIMIZE_HIDDEN_FACES, count_stats=True
            )
            mesh_data.materials.append(walk_mats[0])
            mesh_data.materials.append(mat_curb)
            for m in walk_mats[1:]:
                mesh_data.materials.append(m)
            obj = bpy.data.objects.new(mesh_name, mesh_data)
            obj.parent = start01
            bpy.context.collection.objects.link(obj)

            col_name = f"Colmesh_{mesh_name}-1_mesh"
            colmesh_data = build_island_mesh(
                road["ring"], col_name, HEIGHT, DECAL_HEIGHT_OFFSET, isl_terrain,
                skip_hidden=False, count_stats=False, simple=SIMPLE_COLMESH,
                collision=True
            )
            if not SIMPLE_COLMESH:
                STATS["faces_col"] += len(colmesh_data.polygons)
                STATS["verts_col"] += len(colmesh_data.vertices)
                if not COLMESH_UV:
                    while colmesh_data.uv_layers:
                        colmesh_data.uv_layers.remove(colmesh_data.uv_layers[0])
            colmesh = bpy.data.objects.new(f"Colmesh_{mesh_name}-1", colmesh_data)
            colmesh.parent = start01
            bpy.context.collection.objects.link(colmesh)

            all_objs.extend([obj, colmesh])
            print(f"Road {r_idx} I [{road.get('name') or ''}]: "
                  f"{len(mesh_data.vertices)} vertices, {len(mesh_data.polygons)} faces"
                  f"  |  colmesh {len(colmesh_data.vertices)}v / {len(colmesh_data.polygons)}f")
            continue

        ups = road.get("ups")
        tilted = bool(ups) and any(math.hypot(u.x, u.y) > 1e-6 for u in ups)
        if road_roll_tag(road) and tilted:
            node_d = [0.0]
            for k in range(1, len(road["nodes"])):
                a, b = road["nodes"][k - 1], road["nodes"][k]
                node_d.append(node_d[-1] + math.hypot(b["x"] - a["x"], b["y"] - a["y"]))
            ACTIVE_UP[0] = lambda s, _u=list(ups), _d=node_d: up_at(_u, _d, s)
            lever, hw0 = 0.0, road["width"] / 2.0
            for k, u in enumerate(ups):
                hw = (road["widths"][k] if k < len(road.get("widths") or []) else road["width"]) / 2.0
                dep = (road["depths"][k] if k < len(road.get("depths") or []) else 0.0)
                lever = max(lever, hw + abs(dep) * math.hypot(u.x, u.y))
            ACTIVE_TURN_SCALE[0] = max(0.12, min(1.0, hw0 / lever)) if lever > 1e-6 else 1.0
        else:
            ACTIVE_UP[0] = None
            ACTIVE_TURN_SCALE[0] = 1.0

        points = [Vector((n["x"], n["y"], n["z"])) for n in road["nodes"]]

        if road.get("merged"):
            road_closed = bool(road.get("closed"))
            trimmed_widths = road.get("widths")
            trimmed_depths = None
        elif is_closed_loop(points):
            road_closed = True
            points = points[:-1]
            trimmed_widths = road.get("widths", [])[:-1] if road.get("widths") else None
            trimmed_depths = road.get("depths", [])[:-1] if road.get("depths") else None
        else:
            road_closed = False
            trimmed_widths = road.get("widths")
            trimmed_depths = road.get("depths")

        if road["source"] == "meshroad":
            if MESHROAD_MIN_RADIUS_MARGIN > 0 and not road_closed:
                nm = road.get("name") or f"R{r_idx}"
                relax_w = (trimmed_widths if trimmed_widths and len(trimmed_widths) == len(points)
                           else [road["width"]] * len(points))
                spacing = MESHROAD_SMOOTH_SEGMENT_LENGTH if MESHROAD_SMOOTH_CORNERS else 0.0
                (points, trimmed_widths, trimmed_depths,
                 disp, iters, swept_ratio, swept_at) = relax_for_swept_path(
                    points, relax_w, trimmed_depths, spacing, MESHROAD_SMOOTH_MAX_TURN_DEG)
                if disp > 1e-3:
                    print(f"  [corner] '{nm}': corners relaxed - max displacement {disp:.2f} m "
                          f"over {iters} iterations (swept radius/half-width {swept_ratio:.2f})")
                if swept_at is not None and swept_ratio < 1.0:
                    print(f"  [corner] warning: '{nm}' - the swept centreline still turns tighter "
                          f"than its own half-width (ratio {swept_ratio:.2f}) at "
                          f"({swept_at.x:.2f}, {swept_at.y:.2f}). The inner edge folds over there "
                          f"and produces bowtie faces. Widen that corner, add a node, or narrow "
                          f"the road in the World Editor.")
                elif swept_at is not None and swept_ratio < MESHROAD_SWEPT_MIN_RATIO:
                    print(f"  [corner] note: '{nm}' - tightest swept ratio {swept_ratio:.2f} at "
                          f"({swept_at.x:.2f}, {swept_at.y:.2f}); above 1.0 so nothing folds, but "
                          f"the inner kerb is very tight.")
            if MESHROAD_SMOOTH_CORNERS:
                if MESHROAD_SHARP_CORNERS:
                    points, trimmed_widths, trimmed_depths, n_sharp = \
                        sharpen_unroundable_corners(
                            points, trimmed_widths, trimmed_depths,
                            MESHROAD_SMOOTH_SEGMENT_LENGTH, MESHROAD_SMOOTH_MAX_TURN_DEG,
                            MESHROAD_SHARP_RATIO)
                    if n_sharp:
                        STATS["sharp_corners"] = STATS.get("sharp_corners", 0) + n_sharp
                        print(f"  [corner] '{road.get('name') or f'R{r_idx}'}': {n_sharp} corners "
                              f"kept sharp (mitred) - too tight to round at the authored width")
                points, widths_m, heights_m = smooth_path_with_widths(
                    points, trimmed_widths, MESHROAD_SMOOTH_SEGMENT_LENGTH, depths=trimmed_depths,
                    max_turn_deg=MESHROAD_SMOOTH_MAX_TURN_DEG
                )
                points, widths_m, heights_m = _dedupe(points, widths_m, heights_m)
            else:
                widths_m = trimmed_widths
                heights_m = trimmed_depths
            road, points, widths_m, heights_m = apply_simplify(road, points, widths_m, heights_m)
            if MESHROAD_WIDTH_CLAMP and not road_closed:
                widths_m, narrowed = clamp_widths_to_radius(points, widths_m, road_closed)
                if narrowed > 0.005:
                    print(f"  [width] '{road.get('name') or f'R{r_idx}'}': narrowed by up to "
                          f"{narrowed:.2f} m through corners too tight for the authored width")
                    STATS["width_clamped"] = STATS.get("width_clamped", 0) + 1
            report_min_radius(road.get("name") or f"R{r_idx}", points, widths_m, road_closed)
            tangents = _tangents_for(road, points)
            dists = cumulative_distances(points)
            variants = [("M", 0.0, 1, widths_m, heights_m)]
            road_extra_z = 0.0
            road_terrain = None
            road_bevel = False
            print(f"Road {r_idx}: MeshRoad source -> exact-width sidewalk (mode=exact, smooth={MESHROAD_SMOOTH_CORNERS}, closed={road_closed})")

        elif road["source"] == "decalroad_exact":
            if ZEBRA_SMOOTH_CORNERS and not road.get("merged"):
                points, widths_z = smooth_path_with_widths(points, trimmed_widths, ZEBRA_SMOOTH_SEGMENT_LENGTH)
            else:
                widths_z = trimmed_widths
            road, points, widths_z, _ = apply_simplify(road, points, widths_z, None)
            heights_z = [HEIGHT] * len(points)
            tangents = _tangents_for(road, points)
            dists = cumulative_distances(points)
            variants = [("Z", 0.0, 1, widths_z, heights_z)]
            road_extra_z = DECAL_HEIGHT_OFFSET
            road_terrain = z_source(road)
            road_bevel = BEVEL_ZEBRA_EDGES
            print(f"Road {r_idx}: zebra decal -> exact-width sidewalk (mode=exact, smooth={ZEBRA_SMOOTH_CORNERS}, terrain={USE_TERRAIN_HEIGHT}, closed={road_closed}, bevel={BEVEL_ZEBRA_EDGES})")

        else:
            if SMOOTH_CORNERS:
                points = smooth_path(points, SMOOTH_SEGMENT_LENGTH)
            road, points, _, _ = apply_simplify(road, points, None, None)
            tangents = _tangents_for(road, points)
            dists = cumulative_distances(points)
            road_half_width = road["width"] / 2.0
            const_widths = [WIDTH] * len(points)
            const_heights = [HEIGHT] * len(points)
            road_extra_z = DECAL_HEIGHT_OFFSET
            road_terrain = terrain_sampler
            road_bevel = False

            if road["width"] < THIN_ROAD_THRESHOLD:
                variants = [("C", 0.0, 1, const_widths, const_heights)]
                print(f"Road {r_idx}: width {road['width']:.2f}m < {THIN_ROAD_THRESHOLD}m -> centred sidewalk (mode=center, terrain={USE_TERRAIN_HEIGHT}, closed={road_closed})")
            else:
                variants = [
                    (("L" if sign > 0 else "R"), road_half_width + GAP + hw, sign, const_widths, const_heights)
                    for sign in signs
                ]
                print(f"Road {r_idx}: width {road['width']:.2f}m -> sidewalk on both flanks (mode=flank, terrain={USE_TERRAIN_HEIGHT}, closed={road_closed})")

        if VALIDATE:
            authored = _authored_points(road)
            if len(authored) >= 2:
                check_path_fidelity(road.get("name") or f"R{r_idx}", authored, points)

        if FOLD_GUARD and len(points) > 2 and variants:
            offsets = None
            for _s, co, _m, vw, _vh in variants:
                if not vw or len(vw) != len(points):
                    continue
                cur = [abs(co) + x / 2.0 for x in vw]
                offsets = cur if offsets is None else [max(a, b) for a, b in zip(offsets, cur)]
            sec = road.get("section_tangents")
            forced_flags = ([v is not None for v in sec]
                            if sec and len(sec) == len(points) else None)
            keep = non_folding_keep(points, tangents, offsets, road_closed, forced_flags,
                                    MESHROAD_MIN_EDGE_ADVANCE_FRAC
                                    if road["source"] == "meshroad" else 0.0)
            if 2 < len(keep) < len(points):
                n_dropped = len(points) - len(keep)
                STATS["fold_rings_dropped"] = STATS.get("fold_rings_dropped", 0) + n_dropped
                points = [points[i] for i in keep]
                tangents = [tangents[i] for i in keep]
                dists = [dists[i] for i in keep]
                variants = [(s, o, sg,
                             ([w[i] for i in keep] if w and len(w) > max(keep) else w),
                             ([h[i] for i in keep] if h and len(h) > max(keep) else h))
                            for s, o, sg, w, h in variants]
                print(f"  [fold] '{road.get('name') or f'R{r_idx}'}': {n_dropped} rings dropped - "
                      f"they sat closer together than the offset edge could turn, so the "
                      f"inner edge crossed itself")

        is_mr = road["source"] == "meshroad"
        set_curb_profile(road["source"])

        walk_mats, walk_name, st_res = pick_style(road, r_idx)

        mr_curb_name = st_res["wall_material"] or MESHROAD_CURB_MATERIAL_NAME
        curb_material = ((bpy.data.materials.get(mr_curb_name)
                          or bpy.data.materials.new(mr_curb_name)) if is_mr else mat_curb)
        ACTIVE_KEEP_BOTTOM[0] = bool(is_mr and st_res["bottom"])
        ACTIVE_WALK_SPLIT[0] = bool(is_mr and MESHROAD_WALK_SPLIT)
        ACTIVE_TEXTURE_SCALE[1] = (texture_scale_for(mr_curb_name) if is_mr
                                   else curb_scale_for(CURB_MATERIAL_NAME))
        if is_mr:
            ACTIVE_CURB_BAND[0] = 0
            CURB_ATLAS_ACTIVE[0] = (mr_curb_name == CURB_MATERIAL_NAME and CURB_IS_ATLAS)
        else:
            CURB_ATLAS_ACTIVE[0] = CURB_IS_ATLAS

        for label, center_offset, mirror, widths_for_build, heights_for_build in variants:
            mesh_name = f"{OBJECT_NAME}_R{r_idx}_{label}"

            v_pts, v_tan, v_dist, v_w, v_h, v_caps = add_rounded_ends(
                points, tangents, dists, widths_for_build, heights_for_build,
                road_closed, road["source"],
                no_cap_start=bool(road.get("no_cap_start")),
                no_cap_end=bool(road.get("no_cap_end"))
            )
            if len(v_pts) != len(points):
                print(f"    rounded ends: +{len(v_pts) - len(points)} rings")

            mesh_data = build_mesh_for_side(
                v_pts, v_tan, v_dist, v_w, v_h, center_offset, mirror, mesh_name,
                road_extra_z, road_terrain, road_closed, road_bevel,
                skip_hidden=OPTIMIZE_HIDDEN_FACES, count_stats=True, caps=v_caps
            )
            mesh_data.materials.append(walk_mats[0])
            mesh_data.materials.append(curb_material)
            for m in walk_mats[1:]:
                mesh_data.materials.append(m)

            obj = bpy.data.objects.new(mesh_name, mesh_data)
            obj.parent = start01
            bpy.context.collection.objects.link(obj)

            col_name = f"Colmesh_{mesh_name}-1_mesh"
            if SIMPLE_COLMESH:
                colmesh_data = build_colmesh_for_side(
                    v_pts, v_tan, v_dist, v_w, v_h, center_offset, mirror,
                    col_name, road_extra_z, road_terrain, road_closed, road_bevel, caps=v_caps
                )
            else:
                colmesh_data = build_mesh_for_side(
                    v_pts, v_tan, v_dist, v_w, v_h, center_offset, mirror,
                    col_name, road_extra_z, road_terrain, road_closed, road_bevel,
                    skip_hidden=False, count_stats=False, caps=v_caps
                )
                if not COLMESH_UV:
                    while colmesh_data.uv_layers:
                        colmesh_data.uv_layers.remove(colmesh_data.uv_layers[0])
                STATS["faces_col"] += len(colmesh_data.polygons)
                STATS["verts_col"] += len(colmesh_data.vertices)

            colmesh = bpy.data.objects.new(f"Colmesh_{mesh_name}-1", colmesh_data)
            colmesh.parent = start01
            bpy.context.collection.objects.link(colmesh)

            all_objs.extend([obj, colmesh])
            src_name = road.get("name") or road.get("persistentId") or ""
            print(f"Road {r_idx} {label} [{src_name}]: "
                  f"{len(mesh_data.vertices)} vertices, {len(mesh_data.polygons)} faces"
                  f"  |  colmesh {len(colmesh_data.vertices)}v / {len(colmesh_data.polygons)}f")

    if EXPORT_DAE:
        os.makedirs(EXPORT_FOLDER, exist_ok=True)
        if OVERWRITE_EXPORT:
            candidate = os.path.join(EXPORT_FOLDER, f"{FIXED_EXPORT_NAME}.dae")
        else:
            base_name = f"{OBJECT_NAME}.dae"
            candidate = os.path.join(EXPORT_FOLDER, base_name)
            counter = 1
            while os.path.exists(candidate):
                candidate = os.path.join(EXPORT_FOLDER, f"{OBJECT_NAME}_{counter}.dae")
                counter += 1

        bpy.ops.object.select_all(action="DESELECT")
        for obj in all_objs:
            obj.select_set(True)
        bpy.context.view_layer.objects.active = base00

        bpy.ops.wm.collada_export(
            filepath=candidate,
            selected=True,
            include_children=True,
        )
        print(f"Exporting to: {candidate}")

        size_raw = os.path.getsize(candidate) if os.path.exists(candidate) else 0
        size_final = size_raw
        if ROUND_DAE_FLOATS:
            res = shrink_dae_floats(candidate, DAE_FLOAT_DECIMALS)
            if res:
                size_final = res[1]
                print(f"  [dae] rounded to {DAE_FLOAT_DECIMALS} decimals: "
                      f"{_kb(res[0])} -> {_kb(res[1])}  ({100.0 * (1 - res[1] / max(1, res[0])):.1f}% smaller)")

        if PRINT_SIZE_REPORT:
            print_size_report(size_raw, size_final)


def _purge_startup_scene():
    """Headless Blender opens its startup scene (cube, camera, light). Nothing in
    it is ours, and a stray object must never reach the exporter."""
    if bpy.data.filepath:
        return
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob, do_unlink=True)


if __name__ == "__main__":
    if HEADLESS:
        print(f"  level     : {LEVEL_NAME}")
        print(f"  game root : {GAME_ROOT}")
        _purge_startup_scene()
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        if not HEADLESS:
            raise
        traceback.print_exc()
        sys.exit(1)
