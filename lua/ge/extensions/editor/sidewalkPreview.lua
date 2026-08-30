-- PIT sidewalk preview - renders tagged DecalRoads and untextured MeshRoads as the Blender script will build them

local M = {}
local logTag = 'sidewalkPreview'

local MESH_PREFIX = "PitSidewalkPreview_"
local STYLE_FILE  = "pit_sidewalk_styles.json"

local function transKey(s)
  local k = s:lower():gsub("[^0-9a-z]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  return "pit.ui." .. k:sub(1, 60)
end

local function isRtlText(s)
  return type(s) == "string" and s:find("[\214\215\216\217]") ~= nil
end

local function lookup(s)
  if type(s) ~= "string" or s == "" or isRtlText(s) then return s end
  if not (core_locales and core_locales.translate) then return s end
  local ok, v = pcall(core_locales.translate, transKey(s), s)
  if ok and type(v) == "string" and v ~= "" then return v end
  return s
end

local function tr(f, ...)
  local s = lookup(f)
  if select("#", ...) == 0 then return s end
  local ok, out = pcall(string.format, s, ...)
  if ok then return out end
  local ok2, out2 = pcall(string.format, f, ...)
  return ok2 and out2 or f
end

local HEIGHT               = 0.3
local CURB_STRIP           = 0.15
local DECAL_HEIGHT_OFFSET  = 0.10
local Z_OFFSET             = 0.0
local SMOOTH_SEGMENT_LEN   = 0.75
local SMOOTH_MAX_TURN_DEG  = 4.0
local CR_ALPHA             = 0.5
local CR_MIN_KNOT_SPAN     = 1e-9
local CR_DUP_KNOT_EPS      = 1e-6
local CR_DUP_KNOT_FRAC     = 0.05

local ROUND_OPEN_ENDS        = true
local ROUND_END_MAX_TURN_DEG = 6.0
local ROUND_END_TIP_WIDTH    = 0.30
local ROUND_END_RADIUS_SCALE = 1.0
local ROUND_END_MAX_WIDTH    = 5.0

local ZEBRA_JOIN_TOLERANCE          = 2.5
local ZEBRA_FILLET_MAX_TRIM_RATIO   = 0.35
local ZEBRA_FILLET_TANGENT_PROBE    = 1.2
local ZEBRA_FILLET_MIN_ADVANCE      = 0.4
local ZEBRA_FILLET_MAX_TURN_DEG     = 3.0
local ZEBRA_FILLET_KEEP_INSIDE      = true
local ZEBRA_FILLET_INSIDE_TOLERANCE = 0.005
local ZEBRA_FILLET_INNER_BIAS       = 0.92
local ZEBRA_FILLET_MAX_CORNER_DEG   = 115.0
local ZEBRA_FILLET_MAX_WIDTH_RATIO  = 1.6
local ZEBRA_FAN_MIN_TURN_DEG        = 18.0
local ZEBRA_FAN_MAX_REACH           = 8.0
local ZEBRA_SEAM_WELD               = 0.05

local FLUSH_HAIRPIN_TIPS       = true
local HAIRPIN_MAX_EXTEND_RATIO = 3.0
local JUNCTION_CAP_TOLERANCE   = 2.5
local MIN_NODE_SPACING         = 0.02
local CLOSE_LOOP_TOLERANCE     = 0.5
local SUPPRESS_CAPS_AT_JUNCTIONS = true
local HAIRPIN_UNION                 = true
local HAIRPIN_UNION_MAX_WIDTH_RATIO = 1.3
local HAIRPIN_NOTCH_RADIUS          = 0.35

local BUILD_TRAFFIC_ISLANDS  = true
local ISLAND_MAX_MARKER_WIDTH = 0.5
local ISLAND_JOIN_TOLERANCE   = 0.5
local ISLAND_MIN_AREA         = 0.5
local ISLAND_MITER_MIN_COS    = 0.25
local ISLAND_SMOOTH           = true
local ISLAND_ROUND_CORNERS    = true
local ISLAND_CORNER_RADIUS    = 0.5
local ISLAND_CORNER_MIN_TURN_DEG = 30.0

local FACE_WANT_SIGN = -1

local MR = {
  MESHROAD_UNTEXTURED_ONLY       = true,
  MESHROAD_MATERIAL_KEYS         = {"topMaterial", "sideMaterial", "bottomMaterial"},
  MESHROAD_SMOOTH_CORNERS        = true,
  MESHROAD_SMOOTH_SEGMENT_LENGTH = 0.75,
  MESHROAD_SMOOTH_MAX_TURN_DEG   = 2.0,
  MESHROAD_MIN_EDGE_ADVANCE_FRAC = 0.20,
  MESHROAD_MIN_RADIUS_MARGIN     = 1.5,
  MESHROAD_RELAX_ITERS           = 400,
  MESHROAD_SWEPT_MIN_RATIO       = 1.20,
  MESHROAD_MARGIN_GROWTH         = 1.12,
  MESHROAD_RELAX_ROUNDS          = 12,
  MESHROAD_MAX_RELAX_DISP_HW     = 0.75,
  MESHROAD_SHARP_CORNERS         = true,
  MESHROAD_SHARP_RATIO           = 1.0,
  MESHROAD_SHARP_MAX_GROWTH      = 1.5,
  MESHROAD_SHARP_MITRE_FIT       = true,
  MESHROAD_SHARP_FIT_HEADROOM    = 0.95,
  MESHROAD_SHARP_MAX_HALF_DEG    = 85.0,
  MESHROAD_MITRE_STRIP           = true,
  MESHROAD_MITRE_STRIP_FRAC      = 0.5,
  MESHROAD_FORCE_MITRE_RINGS     = true,
  MESHROAD_MITRE_MATCH_DIST      = 0.5,
  MESHROAD_WIDTH_CLAMP           = true,
  MESHROAD_WIDTH_LIPSCHITZ       = 0.35,
  MESHROAD_MIN_HALF_WIDTH        = 0.35,
  MESHROAD_WIDTH_CLAMP_HEADROOM  = 1.10,
  MESHROAD_WALK_SPLIT            = true,
  MESHROAD_ROLL                  = true,
  MESHROAD_END_CAPS              = true,
  WALK_SPLIT_TARGET_FOLD_DEG     = 10.0,
  WALK_SPLIT_MAX                 = 6,
  MITER_COMPENSATION             = true,
  MITER_LIMIT                    = 3.0,
  FOLD_GUARD                     = true,
  FOLD_GUARD_EPS                 = 1e-4,
  SIMPLIFY_PATH                  = true,
  SIMPLIFY_TOLERANCE             = 0.02,
  SIMPLIFY_MAX_SPAN              = 12.0,
  SIMPLIFY_MAX_TURN_DEG          = 1.5,
  UVX_FROM_MEDIAN_DECAL          = false,
}

local mrState = {turnScale = 1.0, up = nil, curbMat = nil,
                 curbBand0 = false, note = nil, orient = false}

local mr = {}


local CURB_PROFILES = {
  walk   = {angle = 15.0, exposed = 0.15},
  island = {angle = 34.6, exposed = 0.15},
}

local DEFAULT_ATLAS = {
  bands = 8, bandPx = 64,
  paintRows = {1.5, 35.0}, plainRows = {40.5, 60.0},
  paintOn = "top", uScale = 5.89, originTop = true,
}

local stylePath      = ""
local styleCfg       = nil
local styleErr       = nil
local previewMeshes  = {}
local hiddenRoads    = {}
local rendered       = {}
local liveEnabled    = false
local lastStatus     = ""

local LIVE_MAX_ROADS = 12
local LIVE_MIN_DELAY = 0.1

local liveDelay      = 0.3
local pendingSince   = {}
local pendingSig     = {}

local curbKey, walkKey = nil, nil

local function levelDir()
  if not getMissionFilename then return nil end
  local ok, mission = pcall(getMissionFilename)
  if not ok or not mission or mission == "" then return nil end
  return mission:match("^(.*/)[^/]*$")
end

local function readJson(path)
  for _, fn in ipairs({jsonReadFile, readJsonFile}) do
    if type(fn) == "function" then
      local ok, data = pcall(fn, path)
      if ok and type(data) == "table" then return data end
    end
  end
  return nil
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function v3(p) return vec3(p.x, p.y, p.z) end

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, rol, tobit = bit.lshift, bit.rshift, bit.rol, bit.tobit

local MD5_K, MD5_S = {}, {
  7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
  5, 9,14,20, 5, 9,14,20, 5, 9,14,20, 5, 9,14,20,
  4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
  6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21,
}
for i = 0, 63 do
  MD5_K[i + 1] = tobit(math.floor(math.abs(math.sin(i + 1)) * 4294967296))
end

local function md5(msg)
  local len = #msg
  msg = msg .. string.char(0x80)
  while (#msg % 64) ~= 56 do msg = msg .. string.char(0) end

  local bits = len * 8
  for i = 0, 3 do
    msg = msg .. string.char(band(rshift(bits, i * 8), 0xFF))
  end
  msg = msg .. string.char(0, 0, 0, 0)

  local a0, b0, c0, d0 = tobit(0x67452301), tobit(0xefcdab89),
                         tobit(0x98badcfe), tobit(0x10325476)
  for chunk = 0, #msg / 64 - 1 do
    local M = {}
    for j = 0, 15 do
      local o = chunk * 64 + j * 4
      local b1, b2, b3, b4 = msg:byte(o + 1, o + 4)
      M[j] = tobit(bor(b1, lshift(b2, 8), lshift(b3, 16), lshift(b4, 24)))
    end
    local A, B, C, D = a0, b0, c0, d0
    for i = 0, 63 do
      local F, g
      if i < 16 then
        F = bor(band(B, C), band(bnot(B), D)); g = i
      elseif i < 32 then
        F = bor(band(D, B), band(bnot(D), C)); g = (5 * i + 1) % 16
      elseif i < 48 then
        F = bxor(B, bxor(C, D));               g = (3 * i + 5) % 16
      else
        F = bxor(C, bor(B, bnot(D)));          g = (7 * i) % 16
      end
      F = tobit(F + A + MD5_K[i + 1] + M[g])
      A = D; D = C; C = B
      B = tobit(B + rol(F, MD5_S[i + 1]))
    end
    a0 = tobit(a0 + A); b0 = tobit(b0 + B)
    c0 = tobit(c0 + C); d0 = tobit(d0 + D)
  end

  local function hex(w)
    local out = {}
    for i = 0, 3 do
      out[#out + 1] = string.format("%02x", band(rshift(w, i * 8), 0xFF))
    end
    return table.concat(out)
  end
  return hex(a0) .. hex(b0) .. hex(c0) .. hex(d0)
end

local function md5Prefix32(str)
  local h = md5(str)
  local v = 0
  for i = 1, 8 do
    v = v * 16 + tonumber(h:sub(i, i), 16)
  end
  return v
end

local function styleEntries(axis)
  local out = {}
  local styles = styleCfg and styleCfg[axis] and styleCfg[axis].styles
  if type(styles) ~= "table" then return out end
  for k, st in pairs(styles) do
    if type(st) == "table" and st.sequence == nil then
      out[#out + 1] = {key = k, label = st.label or k, color = st.color,
                       weight = st.weight or 0}
    end
  end
  table.sort(out, function(a, b)
    if a.weight ~= b.weight then return a.weight > b.weight end
    return a.key < b.key
  end)
  return out
end

local function jsonKeyOrder(text, section)
  local out = {}
  if not text then return out end
  local at = text:find('"' .. section .. '"%s*:%s*{')
  if not at then return out end
  local i = text:find("{", at, true)
  local depth, j = 0, i
  local body
  while j <= #text do
    local ch = text:sub(j, j)
    if ch == "{" then depth = depth + 1
    elseif ch == "}" then
      depth = depth - 1
      if depth == 0 then body = text:sub(i + 1, j - 1) break end
    end
    j = j + 1
  end
  if not body then return out end
  local d = 0
  local k = 1
  while k <= #body do
    local ch = body:sub(k, k)
    if ch == "{" or ch == "[" then d = d + 1
    elseif ch == "}" or ch == "]" then d = d - 1
    elseif ch == '"' and d == 0 then
      local e = body:find('"', k + 1, true)
      if not e then break end
      local name = body:sub(k + 1, e - 1)
      local rest = body:sub(e + 1):match("^%s*:")
      if rest then out[#out + 1] = name end
      k = e
    end
    k = k + 1
  end
  return out
end

local styleOrder = {}

local function loadStyles()
  styleCfg, styleErr = nil, nil
  styleOrder = {}
  local dir = levelDir()
  if not dir then styleErr = "no level loaded" return end
  stylePath = dir .. STYLE_FILE
  local data = readJson(stylePath)
  if not data then
    styleErr = "no styles config in this level"
    return
  end
  if data.version ~= 1 then styleErr = "styles config version must be 1" return end
  styleCfg = data

  local raw = nil
  if type(readFile) == "function" then
    local ok, txt = pcall(readFile, stylePath)
    if ok and type(txt) == "string" then raw = txt end
  end
  if raw then

    local function axisBlock(text, axis)
      local best = nil
      local from = 1
      while true do
        local a, b = text:find('"' .. axis .. '"%s*:%s*{', from)
        if not a then break end
        local open = text:find("{", b - 1, true)
        local depth, j = 0, open
        while j <= #text do
          local ch = text:sub(j, j)
          if ch == "{" then depth = depth + 1
          elseif ch == "}" then
            depth = depth - 1
            if depth == 0 then break end
          end
          j = j + 1
        end
        local body = text:sub(open, j)
        if body:find('"styles"%s*:%s*{') then best = body end
        from = b
      end
      return best
    end

    local cb = axisBlock(raw, "curb")
    local wb = axisBlock(raw, "walk")
    if cb then styleOrder.curb = jsonKeyOrder(cb, "styles") end
    if wb then styleOrder.walk = jsonKeyOrder(wb, "styles") end
  end
end

local function orderedStyleNames(axis)
  local styles = styleCfg and styleCfg[axis] and styleCfg[axis].styles
  if type(styles) ~= "table" then return {} end
  local out, seen = {}, {}
  for _, nm in ipairs(styleOrder[axis] or {}) do
    if styles[nm] and not seen[nm] then seen[nm] = true; out[#out + 1] = nm end
  end
  local rest = {}
  for nm in pairs(styles) do if not seen[nm] then rest[#rest + 1] = nm end end
  table.sort(rest)
  for _, nm in ipairs(rest) do out[#out + 1] = nm end
  return out
end

local function weightedPick(axis, weights, names, key)
  local total = 0
  for _, nm in ipairs(names) do total = total + (weights[nm] or 0) end
  if total <= 0 then return names[1] end
  local seed = (styleCfg and styleCfg.seed) or 20260812
  local raw = tostring(seed) .. "|" .. axis .. "|" .. tostring(key)
  local r = md5Prefix32(raw) % total
  for _, nm in ipairs(names) do
    r = r - (weights[nm] or 0)
    if r < 0 then return nm end
  end
  return names[#names]
end

local function resolveStyle(road)
  local key = road.persistentId or road.name or tostring(road.id)
  local curb, walk = road.curb, road.walk

  if not curb then
    local names, weights = {}, {}
    for _, nm in ipairs(orderedStyleNames("curb")) do
      local st = styleCfg.curb.styles[nm]
      if type(st) == "table" and st.sequence == nil then
        names[#names + 1] = nm
        weights[nm] = st.weight or 0
      end
    end
    if #names > 0 then curb = weightedPick("curb", weights, names, key) end
  end

  if not walk then

    local names, weights, byMat = {}, {}, {}
    for _, nm in ipairs(orderedStyleNames("walk")) do
      local st = styleCfg.walk.styles[nm]
      if type(st) == "table" and st.material then
        local m = st.material
        if weights[m] == nil then
          names[#names + 1] = m
          weights[m] = st.weight or 0
          byMat[m] = nm
        end
      end
    end
    if #names > 0 then
      local mat = weightedPick("walk", weights, names, key)
      walk = byMat[mat]
    end
  end

  return curb, walk
end

local function curbMaterialName()
  if mrState.curbMat then return mrState.curbMat end
  return styleCfg and styleCfg.curb and styleCfg.curb.material or nil
end

function mr.wallMaterialFor(key)
  local styles = styleCfg and styleCfg.wall and styleCfg.wall.styles
  local st = styles and key and styles[key]
  if type(st) == "table" and st.material then return st.material end
  return nil
end

function mr.meshroadCurbMaterial(road)
  local tagged = mr.wallMaterialFor(road and road.wall)
  if tagged then return tagged end
  local curb = styleCfg and styleCfg.curb
  return (curb and (curb.meshroadMaterial or curb.material)) or nil
end

local function heaviestStyle(axis)
  local styles = styleCfg and styleCfg[axis] and styleCfg[axis].styles
  if type(styles) ~= "table" then return nil end
  local best, bestW = nil, -1
  for k, st in pairs(styles) do
    if type(st) == "table" and st.sequence == nil then
      local w = st.weight or 0
      if w > bestW or (w == bestW and best and k < best) then
        best, bestW = k, w
      end
    end
  end
  return best
end

local function walkMaterialName()
  local styles = styleCfg and styleCfg.walk and styleCfg.walk.styles
  local st = styles and walkKey and styles[walkKey]
  if type(st) == "table" and st.material then return st.material end
  local fb = heaviestStyle("walk")
  local fbSt = fb and styles and styles[fb]
  if type(fbSt) == "table" and fbSt.material then return fbSt.material end
  return nil
end

local function matScale(name)
  local def = styleCfg and styleCfg.defaultScale or 2.5
  local m = name and styleCfg and styleCfg.materials and styleCfg.materials[name]
  local sc = type(m) == "table" and m.scale or nil
  if type(sc) == "table" then
    return sc[1] or def, sc[2] or sc[1] or def
  elseif type(sc) == "number" then
    return sc, sc
  end
  return def, def
end

local function curbBottomUV(uvx, sVal)
  local su, sv = matScale(curbMaterialName())
  return sVal / su + 0.5, uvx / sv + 0.5
end

local function curbAtlas()
  local name = curbMaterialName()
  local m = name and styleCfg and styleCfg.materials and styleCfg.materials[name]
  local key = type(m) == "table" and m.atlas or nil
  if not key then return nil end
  local reg = styleCfg.atlases
  if type(reg) == "table" and type(reg[key]) == "table" then return reg[key] end
  return DEFAULT_ATLAS
end

local function curbBand()
  if mrState.curbBand0 then return 0 end
  local styles = styleCfg and styleCfg.curb and styleCfg.curb.styles
  local st = styles and curbKey and styles[curbKey]
  if type(st) == "table" and type(st.band) == "number" then return st.band end
  local fb = heaviestStyle("curb")
  local fbSt = fb and styles and styles[fb]
  if type(fbSt) == "table" and type(fbSt.band) == "number" then return fbSt.band end
  return 0
end

local function rowSpan(rows, k)
  return rows[1] + clamp(k, 0.0, 1.0) * (rows[2] - rows[1])
end

local function curbBandV(atlas, row)
  local band = curbBand() % atlas.bands
  local v = (band * atlas.bandPx + row) / (atlas.bands * atlas.bandPx)
  if atlas.originTop ~= false then return 1.0 - v end
  return v
end

local function curbU(s)
  local atlas = curbAtlas()
  local su, sv = matScale(curbMaterialName())
  if not atlas then return s / su + 0.5 end
  local sc = atlas.uScale or sv
  return s / sc + 0.5
end

local function curbTopV(w)
  local atlas = curbAtlas()
  if not atlas then
    local _, sv = matScale(curbMaterialName())
    return (w - CURB_STRIP) / sv + 0.5
  end
  local k = (CURB_STRIP > 1e-9) and (w / CURB_STRIP) or 0.0
  if atlas.paintOn == "top" then
    return curbBandV(atlas, rowSpan(atlas.paintRows, k))
  end
  return curbBandV(atlas, rowSpan(atlas.plainSlice or atlas.plainRows, k))
end

local function curbFaceV(depth)
  local atlas = curbAtlas()
  if not atlas then
    local _, sv = matScale(curbMaterialName())
    return depth / sv + 0.5
  end
  local k = (HEIGHT > 1e-9) and (depth / HEIGHT) or 0.0
  if atlas.paintOn == "top" then
    return curbBandV(atlas, rowSpan(atlas.plainRows, k))
  end
  return curbBandV(atlas, rowSpan({atlas.paintRows[1], atlas.plainRows[2]}, k))
end

local function walkUV(localX, s)
  local su, sv = matScale(walkMaterialName())
  return localX / su + 0.5, s / sv + 0.5
end

local function crKnots(p0, p1, p2, p3)
  if CR_ALPHA <= 0.0 then return nil end
  local lens = {(p1 - p0):length(), (p2 - p1):length(), (p3 - p2):length()}
  local ref = math.max(lens[1], lens[2], lens[3])
  local floor = CR_MIN_KNOT_SPAN
  if ref > 0.0 then floor = math.max(CR_MIN_KNOT_SPAN, ref * CR_DUP_KNOT_FRAC) end
  local t = {0.0}
  for i = 1, 3 do
    local L = lens[i]
    if L <= CR_DUP_KNOT_EPS then L = floor end
    t[#t + 1] = t[#t] + L ^ CR_ALPHA
  end
  return t
end

local function crPoint(p0, p1, p2, p3, t, kn)
  if not kn then
    local t2 = t * t
    local t3 = t2 * t
    return (p1 * 2.0
            + (p2 - p0) * t
            + (p0 * 2.0 - p1 * 5.0 + p2 * 4.0 - p3) * t2
            + (p1 * 3.0 - p0 - p2 * 3.0 + p3) * t3) * 0.5
  end
  local k0, k1, k2, k3 = kn[1], kn[2], kn[3], kn[4]
  local u = k1 + (k2 - k1) * t

  local function lerp(a, b, ta, tb)
    if tb - ta < 1e-12 then return b end
    local f = (u - ta) / (tb - ta)
    return a * (1.0 - f) + b * f
  end

  local a1 = lerp(p0, p1, k0, k1)
  local a2 = lerp(p1, p2, k1, k2)
  local a3 = lerp(p2, p3, k2, k3)
  local b1 = lerp(a1, a2, k0, k2)
  local b2 = lerp(a2, a3, k1, k3)
  return lerp(b1, b2, k1, k2)
end

local function segmentTValues(p0, p1, p2, p3, spacing, kn, maxTurnDeg)
  local limit = maxTurnDeg or SMOOTH_MAX_TURN_DEG
  local segLen = (p2 - p1):length()
  if limit >= 180.0 then
    local steps = math.max(1, math.floor(segLen / spacing + 0.5))
    local ts = {}
    for s = 1, steps do ts[s] = s / steps end
    return ts
  end

  local dense = math.max(16, math.min(256, math.floor(segLen / 0.05)))
  local pts = {}
  for i = 0, dense do
    pts[i + 1] = crPoint(p0, p1, p2, p3, i / dense, kn)
  end

  local ts, accD, accA, prevDir = {}, 0.0, 0.0, nil
  for i = 1, dense do
    local d = pts[i + 1] - pts[i]
    local dl = d:length()
    accD = accD + dl
    local cur = (dl > 1e-9) and (d / dl) or nil
    if prevDir and cur then
      accA = accA + math.deg(math.acos(clamp(prevDir:dot(cur), -1.0, 1.0)))
    end
    if cur then prevDir = cur end
    if i == dense or accD >= spacing or accA >= limit * mrState.turnScale then
      ts[#ts + 1] = i / dense
      accD, accA = 0.0, 0.0
    end
  end
  return ts
end

local function smoothPath(points, spacing)
  local n = #points
  if n < 3 or spacing <= 0 then
    local out = {}
    for i = 1, n do out[i] = v3(points[i]) end
    return out
  end

  local padded = {points[1] * 2.0 - points[2]}
  for i = 1, n do padded[#padded + 1] = points[i] end
  padded[#padded + 1] = points[n] * 2.0 - points[n - 1]

  local result = {v3(points[1])}
  for i = 2, #padded - 2 do
    local p0, p1, p2, p3 = padded[i - 1], padded[i], padded[i + 1], padded[i + 2]
    if (p2 - p1):length() >= 1e-6 then
      local kn = crKnots(p0, p1, p2, p3)
      for _, t in ipairs(segmentTValues(p0, p1, p2, p3, spacing, kn)) do
        result[#result + 1] = crPoint(p0, p1, p2, p3, t, kn)
      end
    end
  end
  return result
end

local function resampleSectionTangents(points, sec, spacing)
  if not sec or #sec ~= #points or #points < 3 or spacing <= 0 then return nil end
  local n = #points
  local padded = {points[1] * 2.0 - points[2]}
  for i = 1, n do padded[#padded + 1] = points[i] end
  padded[#padded + 1] = points[n] * 2.0 - points[n - 1]

  local out = {sec[1]}
  for i = 2, #padded - 2 do
    local p0, p1, p2, p3 = padded[i - 1], padded[i], padded[i + 1], padded[i + 2]
    if (p2 - p1):length() >= 1e-6 then
      local ta, tb = sec[i - 1], sec[i]
      local kn = crKnots(p0, p1, p2, p3)
      for _, t in ipairs(segmentTValues(p0, p1, p2, p3, spacing, kn)) do
        if not ta or not tb then
          out[#out + 1] = (t > 0.999) and tb or false
        else
          local v = ta * (1.0 - t) + tb * t
          out[#out + 1] = (v:length() > 1e-9) and v:normalized() or tb
        end
      end
    end
  end
  return out
end

local function smoothPathWithWidths(points, widths, spacing, depths, maxTurnDeg)
  local n = #points
  if n < 3 or spacing <= 0 then
    local op, ow, od = {}, {}, (depths and {} or nil)
    for i = 1, n do
      op[i] = v3(points[i]); ow[i] = widths[i]
      if od then od[i] = depths[i] end
    end
    return op, ow, od
  end

  local pp = {points[1] * 2.0 - points[2]}
  local pw = {widths[1]}
  local pd = depths and {depths[1]} or nil
  for i = 1, n do
    pp[#pp + 1] = points[i]
    pw[#pw + 1] = widths[i]
    if pd then pd[#pd + 1] = depths[i] end
  end
  pp[#pp + 1] = points[n] * 2.0 - points[n - 1]
  pw[#pw + 1] = widths[n]
  if pd then pd[#pd + 1] = depths[n] end

  local rp, rw = {v3(points[1])}, {widths[1]}
  local rd = depths and {depths[1]} or nil
  for i = 2, #pp - 2 do
    local p0, p1, p2, p3 = pp[i - 1], pp[i], pp[i + 1], pp[i + 2]
    local w0, w1, w2, w3 = pw[i - 1], pw[i], pw[i + 1], pw[i + 2]
    if (p2 - p1):length() >= 1e-6 then
      local kn = crKnots(p0, p1, p2, p3)
      for _, t in ipairs(segmentTValues(p0, p1, p2, p3, spacing, kn, maxTurnDeg)) do
        rp[#rp + 1] = crPoint(p0, p1, p2, p3, t, kn)
        rw[#rw + 1] = crPoint(w0, w1, w2, w3, t, kn)
        if rd then
          rd[#rd + 1] = crPoint(pd[i - 1], pd[i], pd[i + 1], pd[i + 2], t, kn)
        end
      end
    end
  end
  return rp, rw, rd
end

local function terrainZ(x, y, fallback)
  if core_terrain and core_terrain.getTerrainHeight then
    local ok, h = pcall(core_terrain.getTerrainHeight, vec3(x, y, 0))
    if ok and type(h) == "number" then return h end
  end
  return fallback or 0.0
end

function mr.computeTangents(points)
  local n = #points
  local out = {}
  for i = 1, n do
    local a, b
    if i > 1 then
      local d = points[i] - points[i - 1]
      d = vec3(d.x, d.y, 0)
      if d:length() > 1e-9 then a = d:normalized() end
    end
    if i < n then
      local d = points[i + 1] - points[i]
      d = vec3(d.x, d.y, 0)
      if d:length() > 1e-9 then b = d:normalized() end
    end
    local d
    if a and b then
      d = a + b
      if d:length() < 1e-9 then d = b end
    else
      d = a or b
    end
    if not d or d:length() < 1e-9 then d = vec3(1, 0, 0) end
    out[i] = d:normalized()
  end
  return out
end

function mr.cumulativeDistances(points)
  local out = {0.0}
  for i = 2, #points do
    out[i] = out[i - 1] + (points[i] - points[i - 1]):length()
  end
  return out
end

function mr.tangent3d(points, i, closed)
  local n = #points
  if n < 2 then return vec3(1, 0, 0) end
  local d
  if closed then
    d = points[(i % n) + 1] - points[((i - 2) % n) + 1]
  elseif i == 1 then d = points[2] - points[1]
  elseif i == n then d = points[n] - points[n - 1]
  else d = points[i + 1] - points[i - 1] end
  if d:length() > 1e-9 then return d:normalized() end
  return vec3(1, 0, 0)
end

function mr.upAt(ups, dists, s)
  if not ups or #ups == 0 then return vec3(0, 0, 1) end
  if #ups == 1 or not dists or #dists == 0 then return ups[1] end
  if s <= dists[1] then return ups[1] end
  local lim = math.min(#dists, #ups)
  for i = 2, lim do
    if s <= dists[i] then
      local span = dists[i] - dists[i - 1]
      local f = (span <= 1e-9) and 0.0 or ((s - dists[i - 1]) / span)
      local v = ups[i - 1] * (1.0 - f) + ups[i] * f
      if v:length() > 1e-6 then return v:normalized() end
      return ups[i]
    end
  end
  return ups[lim]
end

function mr.xyRadius(a, b, c)
  local ar = math.abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2.0
  local A, B, C = (b - a):length(), (c - b):length(), (c - a):length()
  if ar < 1e-12 or A < 1e-9 or B < 1e-9 then return math.huge end
  return A * B * C / (4.0 * ar)
end

function mr.dedupe(points, widths, depths)
  local op = {points[1]}
  local ow = {widths[1]}
  local od = depths and {depths[1]} or nil
  for i = 2, #points do
    if (points[i] - op[#op]):length() > 1e-6 then
      op[#op + 1] = points[i]
      ow[#ow + 1] = widths[i]
      if od then od[#od + 1] = depths[i] end
    end
  end
  return op, ow, od
end

function mr.densify(points, widths, depths, spacing, maxTurnDeg)
  local dn, dw = smoothPathWithWidths(points, widths, spacing, depths, maxTurnDeg)
  dn, dw = mr.dedupe(dn, dw, nil)
  return dn, dw
end

function mr.dupSharp(points, widths, depths, sharp)
  local cp, cw, cd = {}, {}, (depths and {} or nil)
  local n = #points
  for i = 1, n do
    local reps = (i > 1 and i < n and sharp[i]) and 2 or 1
    for _ = 1, reps do
      cp[#cp + 1] = points[i]
      cw[#cw + 1] = widths[i]
      if cd then cd[#cd + 1] = depths[i] end
    end
  end
  return cp, cw, cd
end

function mr.minRadiusRatio(points, widths)
  local worst, at = math.huge, nil
  for i = 2, #points - 1 do
    local hw = ((widths and widths[i]) or 0.0) / 2.0
    if hw > 1e-6 then
      local r = mr.xyRadius(points[i - 1], points[i], points[i + 1]) / hw
      if r < worst then worst, at = r, points[i] end
    end
  end
  return worst, at
end

function mr.sweptRatio(points, widths, depths, spacing, maxTurnDeg)
  if #points < 3 then return math.huge, nil end
  local dense, dwid = smoothPathWithWidths(points, widths, spacing, depths, maxTurnDeg)
  return mr.minRadiusRatio(dense, dwid)
end

function mr.relaxTightCorners(points, widths, margin, maxIter)
  local n = #points
  if n < 3 or not widths or #widths == 0 then return points, 0.0, 0 end
  margin = margin or MR.MESHROAD_MIN_RADIUS_MARGIN
  maxIter = maxIter or MR.MESHROAD_RELAX_ITERS
  local pts, orig = {}, {}
  for i = 1, n do
    pts[i] = vec3(points[i].x, points[i].y, points[i].z)
    orig[i] = vec3(points[i].x, points[i].y, points[i].z)
  end

  local used = 0
  for _ = 1, maxIter do
    local bad, nbad = {}, 0
    for i = 2, n - 1 do
      local hw = ((i <= #widths) and widths[i] or widths[#widths]) / 2.0
      if hw > 1e-6 and mr.xyRadius(pts[i - 1], pts[i], pts[i + 1]) < hw * margin then
        nbad = nbad + 1
        bad[nbad] = i
      end
    end
    if nbad == 0 then break end
    local mark = {}
    for _, i in ipairs(bad) do
      for _, j in ipairs({i - 1, i, i + 1}) do
        if j > 1 and j < n then mark[j] = true end
      end
    end
    local upd = {}
    for j in pairs(mark) do
      local mid = (pts[j - 1] + pts[j + 1]) * 0.5
      upd[j] = vec3(pts[j].x + (mid.x - pts[j].x) * 0.25,
                    pts[j].y + (mid.y - pts[j].y) * 0.25,
                    pts[j].z)
    end
    for j, v in pairs(upd) do pts[j] = v end
    used = used + 1
  end
  local disp = 0.0
  for i = 1, n do
    local d = (pts[i] - orig[i]):length()
    if d > disp then disp = d end
  end
  return pts, disp, used
end

function mr.reparamVertical(orig, moved, widths, depths)
  local function cum(p)
    local s = {0.0}
    for i = 2, #p do
      local dx, dy = p[i].x - p[i - 1].x, p[i].y - p[i - 1].y
      s[i] = s[i - 1] + math.sqrt(dx * dx + dy * dy)
    end
    return s
  end
  local n = #orig
  if n ~= #moved or n < 2 then return moved, widths, depths end
  local so, sn = cum(orig), cum(moved)
  if so[n] < 1e-9 or sn[n] < 1e-9 then return moved, widths, depths end
  local hasW = widths ~= nil and #widths == n
  local hasD = depths ~= nil and #depths == n
  local outP, outW, outD, j = {}, {}, {}, 2
  for i = 1, n do
    local t = sn[i] / sn[n] * so[n]
    while j < n and so[j] < t do j = j + 1 end
    local a, b = j - 1, j
    local span = so[b] - so[a]
    local f = (span < 1e-12) and 0.0 or ((t - so[a]) / span)
    outP[i] = vec3(moved[i].x, moved[i].y, orig[a].z + (orig[b].z - orig[a].z) * f)
    if hasW then outW[i] = widths[a] + (widths[b] - widths[a]) * f end
    if hasD then outD[i] = depths[a] + (depths[b] - depths[a]) * f end
  end
  return outP, (hasW and outW or widths), (hasD and outD or depths)
end

function mr.relaxForSweptPath(points, widths, depths, spacing, maxTurnDeg)
  if #points < 3 or not widths or #widths == 0 then
    return points, widths, depths, 0.0, 0, math.huge, nil
  end
  local ratio, at = mr.sweptRatio(points, widths, depths, spacing, maxTurnDeg)
  local bP, bW, bD, bDisp, bIters = points, widths, depths, 0.0, 0
  if ratio >= MR.MESHROAD_SWEPT_MIN_RATIO then
    return bP, bW, bD, bDisp, bIters, ratio, at
  end
  local wmax = widths[1]
  for _, w in ipairs(widths) do if w > wmax then wmax = w end end
  local dispCap = MR.MESHROAD_MAX_RELAX_DISP_HW * (wmax / 2.0)
  local margin = MR.MESHROAD_MIN_RADIUS_MARGIN
  for _ = 1, math.max(1, MR.MESHROAD_RELAX_ROUNDS) do
    local relaxed, disp, iters = mr.relaxTightCorners(points, widths, margin)
    if disp > dispCap then break end
    local moved, w, d = mr.reparamVertical(points, relaxed, widths, depths)
    local r, a = mr.sweptRatio(moved, w, d, spacing, maxTurnDeg)
    if r > ratio then
      bP, bW, bD, bDisp, bIters = moved, w, d, disp, iters
      ratio, at = r, a
    end
    if r >= MR.MESHROAD_SWEPT_MIN_RATIO then break end
    margin = margin * MR.MESHROAD_MARGIN_GROWTH
  end
  return bP, bW, bD, bDisp, bIters, ratio, at
end

function mr.mitreRun(points, widths, i)
  local n = #points
  if i <= 1 or i >= n then return 0.0 end
  local a = points[i] - points[i - 1]
  local b = points[i + 1] - points[i]
  local la, lb = a:length(), b:length()
  if la < 1e-9 or lb < 1e-9 then return 0.0 end
  local cosT = clamp((a.x * b.x + a.y * b.y) / (la * lb), -1.0, 1.0)
  local half = math.min(math.acos(cosT) / 2.0, math.rad(MR.MESHROAD_SHARP_MAX_HALF_DEG))
  local hw = ((widths and widths[i]) or 0.0) / 2.0
  return hw * math.tan(half)
end

function mr.mitreFits(points, widths, i)
  local n = #points
  if i <= 1 or i >= n then return false end
  local need = mr.mitreRun(points, widths, i)
  if need <= 0.0 then return true end
  local legs = {{i - 1, (points[i] - points[i - 1]):length()},
                {i + 1, (points[i + 1] - points[i]):length()}}
  for k = 1, 2 do
    local j, leg = legs[k][1], legs[k][2]
    local other = 0.0
    if j > 1 and j < n then other = mr.mitreRun(points, widths, j) end
    if need + other > leg * MR.MESHROAD_SHARP_FIT_HEADROOM then return false end
  end
  return true
end

function mr.stripMitreTail(points, widths, heights, mitres, frac)
  local f = frac or MR.MESHROAD_MITRE_STRIP_FRAC
  local n = #points
  if n < 3 or not mitres or #mitres == 0 or f <= 0.0 then
    return points, widths, heights, 0
  end
  local protect = {}
  for k = 1, #mitres do
    local mp = mitres[k][1]
    local best, bestD = nil, math.huge
    for i = 1, n do
      local dx, dy = points[i].x - mp.x, points[i].y - mp.y
      local d = math.sqrt(dx * dx + dy * dy)
      if d < bestD then best, bestD = i, d end
    end
    if best then protect[best] = true end
  end
  local keep = {}
  for i = 1, n do
    local drop = false
    if not protect[i] and i > 1 and i < n then
      for k = 1, #mitres do
        local mp, run = mitres[k][1], mitres[k][2]
        local r = run * f
        if r > 1e-6 then
          local dx, dy = points[i].x - mp.x, points[i].y - mp.y
          if math.sqrt(dx * dx + dy * dy) < r then drop = true; break end
        end
      end
    end
    if not drop then keep[#keep + 1] = i end
  end
  if #keep < 3 or #keep == n then return points, widths, heights, 0 end
  local np, nw, nh = {}, {}, nil
  if heights then nh = {} end
  for k = 1, #keep do
    np[k] = points[keep[k]]
    nw[k] = widths[keep[k]]
    if nh then nh[k] = heights[keep[k]] end
  end
  return np, nw, nh, n - #keep
end

function mr.sharpenUnroundableCorners(points, widths, depths, spacing, maxTurnDeg, ratio)
  local n = #points
  local sharp = {}
  for i = 1, n do sharp[i] = false end
  if n < 3 then return points, widths, depths, 0, nil end

  local blocked = {}
  for i = 1, n do blocked[i] = false end
  if MR.MESHROAD_SHARP_MITRE_FIT then
    for i = 2, n - 1 do
      if not mr.mitreFits(points, widths, i) then blocked[i] = true end
    end
  end

  local baseDense = #(mr.densify(points, widths, depths, spacing, maxTurnDeg))
  local capDense = baseDense * MR.MESHROAD_SHARP_MAX_GROWTH

  for _ = 1, n do
    local cp, cw, cd = mr.dupSharp(points, widths, depths, sharp)
    local dn, dw = smoothPathWithWidths(cp, cw, spacing, cd, maxTurnDeg)
    dn, dw = mr.dedupe(dn, dw, nil)

    local anyFree = false
    for m = 2, n - 1 do
      if not sharp[m] and not blocked[m] then anyFree = true; break end
    end

    local worst, at = math.huge, nil
    if anyFree then
      for k = 2, #dn - 1 do
        local hw = ((dw and dw[k]) or 0.0) / 2.0
        if hw > 1e-6 then
          local bestD, near = math.huge, nil
          for m = 2, n - 1 do
            if not sharp[m] and not blocked[m] then
              local d = dn[k] - points[m]
              local man = math.abs(d.x) + math.abs(d.y)
              if man < bestD then bestD, near = man, m end
            end
          end
          if near and (dn[k] - points[near]):length() <= spacing * 3.0 then
            local r = mr.xyRadius(dn[k - 1], dn[k], dn[k + 1]) / hw
            if r < worst then worst, at = r, near end
          end
        end
      end
    end

    if not at or worst >= ratio then break end
    sharp[at] = true
    if baseDense > 0 and #dn > capDense then
      return points, widths, depths, 0, {runaway = true, from = baseDense, to = #dn}
    end
  end

  local count = 0
  for i = 1, n do if sharp[i] then count = count + 1 end end
  if count == 0 then return points, widths, depths, 0, nil end

  local cp, cw, cd = mr.dupSharp(points, widths, depths, sharp)
  local grown = #(mr.densify(cp, cw, cd, spacing, maxTurnDeg))
  if baseDense > 0 and grown > capDense then
    return points, widths, depths, 0, {runaway = true, from = baseDense, to = grown}
  end
  local mitres = {}
  for i = 1, n do
    if sharp[i] then
      mitres[#mitres + 1] = {points[i], mr.mitreRun(points, widths, i)}
    end
  end
  return cp, cw, cd, count, nil, mitres
end

function mr.ptLineDist(p, a, b)
  local ab = b - a
  local l2 = ab:dot(ab)
  if l2 < 1e-12 then return (p - a):length() end
  local s = clamp((p - a):dot(ab) / l2, 0.0, 1.0)
  return (p - (a + ab * s)):length()
end

function mr.simplifyIndices(points, widths, heights, tol, forced, maxSpan, maxTurnDeg)
  local n = #points
  if n < 3 or tol <= 0 then
    local all = {}
    for i = 1, n do all[i] = i end
    return all
  end

  local turnPrefix = {0.0}
  for k = 2, n - 1 do
    local d0 = points[k] - points[k - 1]
    local d1 = points[k + 1] - points[k]
    local ang = 0.0
    local l0, l1 = d0:length(), d1:length()
    if l0 > 1e-9 and l1 > 1e-9 then
      ang = math.deg(math.acos(clamp(d0:dot(d1) / (l0 * l1), -1.0, 1.0)))
    end
    turnPrefix[k] = turnPrefix[k - 1] + ang
  end
  turnPrefix[n] = turnPrefix[n - 1] or 0.0

  local function ok(i, j)
    local a, b = points[i], points[j]
    if (b - a):length() > maxSpan then return false end
    if maxTurnDeg < 180.0 and (turnPrefix[j - 1] - turnPrefix[i]) > maxTurnDeg then
      return false
    end
    local span = j - i
    for k = i + 1, j - 1 do
      if forced and forced[k] then return false end
      if mr.ptLineDist(points[k], a, b) > tol then return false end
      local f = (k - i) / span
      if widths then
        if math.abs(widths[k] - (widths[i] + (widths[j] - widths[i]) * f)) > tol then
          return false
        end
      end
      if heights then
        if math.abs(heights[k] - (heights[i] + (heights[j] - heights[i]) * f)) > tol then
          return false
        end
      end
    end
    return true
  end

  local keep = {1}
  local i = 1
  while i < n do
    local best = i + 1
    local j = i + 2
    while j <= n and ok(i, j) do
      best = j
      j = j + 1
    end
    keep[#keep + 1] = best
    i = best
  end
  return keep
end

function mr.applySimplify(points, widths, heights, forced)
  if not MR.SIMPLIFY_PATH or #points < 3 then return points, widths, heights end
  local w = (widths and #widths == #points) and widths or nil
  local h = (heights and #heights == #points) and heights or nil
  local keep = mr.simplifyIndices(points, w, h, MR.SIMPLIFY_TOLERANCE * mrState.turnScale,
                               forced, MR.SIMPLIFY_MAX_SPAN,
                               MR.SIMPLIFY_MAX_TURN_DEG * mrState.turnScale)
  if #keep == #points then return points, widths, heights end
  local np, nw, nh = {}, (w and {} or widths), (h and {} or heights)
  for k, i in ipairs(keep) do
    np[k] = points[i]
    if w then nw[k] = widths[i] end
    if h then nh[k] = heights[i] end
  end
  return np, nw, nh
end

function mr.widthClampRatio()
  local frac = clamp(MR.MESHROAD_MIN_EDGE_ADVANCE_FRAC, 0.0, 0.9)
  local guard = MR.MESHROAD_WIDTH_CLAMP_HEADROOM / math.max(1e-6, 1.0 - frac)
  return math.max(MR.MESHROAD_SWEPT_MIN_RATIO, guard)
end

function mr.clampWidthsToRadius(points, widths, closed, ratio, slope, floorHw)
  local n = #points
  if n < 3 or not widths or #widths ~= n then return widths, 0.0 end
  ratio = ratio or mr.widthClampRatio()
  slope = slope or MR.MESHROAD_WIDTH_LIPSCHITZ
  floorHw = floorHw or MR.MESHROAD_MIN_HALF_WIDTH

  local hw = {}
  for i = 1, n do
    local a, b, c
    if closed then
      a = points[((i - 2) % n) + 1]; b = points[i]; c = points[(i % n) + 1]
    elseif i == 1 then
      a, b, c = points[1], points[2], points[3]
    elseif i == n then
      a, b, c = points[n - 2], points[n - 1], points[n]
    else
      a, b, c = points[i - 1], points[i], points[i + 1]
    end
    local cap = (ratio > 0) and (mr.xyRadius(a, b, c) / ratio) or math.huge
    hw[i] = math.max(floorHw, math.min(widths[i] / 2.0, cap))
  end

  local seg = {0.0}
  for i = 2, n do
    local dx, dy = points[i].x - points[i - 1].x, points[i].y - points[i - 1].y
    seg[i] = math.sqrt(dx * dx + dy * dy)
  end
  local wrap = 0.0
  if closed then
    local dx, dy = points[1].x - points[n].x, points[1].y - points[n].y
    wrap = math.sqrt(dx * dx + dy * dy)
  end

  for _ = 1, (closed and 3 or 1) do
    for i = 2, n do hw[i] = math.min(hw[i], hw[i - 1] + slope * seg[i]) end
    for i = n - 1, 1, -1 do hw[i] = math.min(hw[i], hw[i + 1] + slope * seg[i + 1]) end
    if closed then
      hw[1] = math.min(hw[1], hw[n] + slope * wrap)
      hw[n] = math.min(hw[n], hw[1] + slope * wrap)
    end
  end

  local out, worst = {}, -math.huge
  for i = 1, n do
    out[i] = 2.0 * hw[i]
    local d = (widths[i] - out[i]) / 2.0
    if d > worst then worst = d end
  end
  return out, worst
end

function mr.offsetAdvances(points, tangents, offsets, j, i, minFrac)
  local tj, ti = tangents[j], tangents[i]
  local need = MR.FOLD_GUARD_EPS
  if minFrac and minFrac > 0.0 then
    local dx, dy = points[i].x - points[j].x, points[i].y - points[j].y
    need = math.max(need, minFrac * math.sqrt(dx * dx + dy * dy))
  end
  for _, s in ipairs({-1.0, 1.0}) do
    local oj, oi = s * offsets[j], s * offsets[i]
    local dx = (points[i].x - ti.y * oi) - (points[j].x - tj.y * oj)
    local dy = (points[i].y + ti.x * oi) - (points[j].y + tj.x * oj)
    if dx * tj.x + dy * tj.y <= need then return false end
    if dx * ti.x + dy * ti.y <= need then return false end
  end
  return true
end

function mr.nonFoldingKeep(points, tangents, offsets, closed, forced, minFrac)
  local n = #points
  if n < 3 or not offsets or #offsets ~= n then
    local all = {}
    for i = 1, n do all[i] = i end
    return all
  end
  local keep = {1}
  for i = 2, n do
    local j = keep[#keep]
    if (forced and forced[i]) or mr.offsetAdvances(points, tangents, offsets, j, i, minFrac) then
      keep[#keep + 1] = i
    elseif i == n and not closed then
      if #keep > 1 and not (forced and forced[j]) then
        keep[#keep] = i
      else
        keep[#keep + 1] = i
      end
    end
  end
  if closed then
    while #keep > 3 and not mr.offsetAdvances(points, tangents, offsets, keep[#keep], keep[1], minFrac) do
      if forced and forced[keep[#keep]] then break end
      keep[#keep] = nil
    end
  end
  return keep
end

function mr.miterScales(points, tangents, closed, radial)
  local n = #points
  local out = {}
  for i = 1, n do out[i] = 1.0 end
  if not MR.MITER_COMPENSATION or n < 3 then return out end
  for i = 1, n do
    if not (radial and radial[i]) then
      local j = closed and ((i % n) + 1) or math.min(i + 1, n)
      if j ~= i then
        local d = points[j] - points[i]
        local L = math.sqrt(d.x * d.x + d.y * d.y)
        if L >= 1e-9 then
          local cosHalf = (d.x * tangents[i].x + d.y * tangents[i].y) / L
          if cosHalf > 1e-3 then
            out[i] = math.min(MR.MITER_LIMIT, 1.0 / cosHalf)
          end
        end
      end
    end
  end
  if not closed then
    out[1] = 1.0
    out[n] = 1.0
  end
  return out
end

function mr.edgeAdvance(points, tangents, i, j, off)
  local ti, tj = tangents[i], tangents[j]
  local ax = points[i].x - ti.y * off
  local ay = points[i].y + ti.x * off
  local bx = points[j].x - tj.y * off
  local by = points[j].y + tj.x * off
  local dx, dy = bx - ax, by - ay
  return math.min(dx * ti.x + dy * ti.y, dx * tj.x + dy * tj.y)
end

function mr.spanGeometry(points, tangents, widths, i, j)
  local hw = math.max(0.0, math.min(widths[i], widths[j]) / 2.0 - CURB_STRIP)
  if hw <= 1e-6 then return 0.0, 0.0, 0.0, 0.0 end
  local a = mr.edgeAdvance(points, tangents, i, j, -hw)
  local b = mr.edgeAdvance(points, tangents, i, j, hw)
  local dz = math.abs(points[j].z - points[i].z)
  return a, b, dz, hw
end

function mr.spanFoldDeg(a, b, dz)
  local lo, hi = a, b
  if lo > hi then lo, hi = b, a end
  if dz < 1e-9 or lo <= 1e-9 or hi <= 1e-9 then return 0.0 end
  return math.deg(math.atan(dz / lo) - math.atan(dz / hi))
end

function mr.walkSplitFracs(n, a, b, dz, hw)
  if n < 2 then return {} end
  local lo, hi = a, b
  if lo > hi then lo, hi = b, a end
  local out = {}
  if hw <= 1e-6 or dz < 1e-9 or lo <= 1e-9 or (hi - lo) <= 1e-9 then
    for i = 1, n - 1 do out[i] = 2.0 * i / n - 1.0 end
    return out
  end
  local R = hw * (hi + lo) / (hi - lo)
  local K = dz * R * 2.0 / (hi + lo)
  local phiIn = math.atan(K / math.max(1e-9, R - hw))
  local phiOut = math.atan(K / (R + hw))
  if math.abs(phiIn - phiOut) < 1e-9 then
    for i = 1, n - 1 do out[i] = 2.0 * i / n - 1.0 end
    return out
  end
  for k = 1, n - 1 do
    local phi = phiIn + (phiOut - phiIn) * k / n
    local x = K / math.tan(phi) - R
    out[k] = clamp(x / hw, -0.999, 0.999)
  end
  if a > b then
    for k = 1, #out do out[k] = -out[k] end
  end
  table.sort(out)
  return out
end


local function sectionLayout(width, profile, insetOverride, capShrink, height, uvHw, walkFracs)
  local hw = width * 0.5
  height = height or HEIGHT
  local inset
  if insetOverride == nil then
    inset = math.max(0.0, hw - CURB_STRIP)
  else
    inset = math.max(0.0, math.min(insetOverride, hw))
  end

  local prof = CURB_PROFILES[profile] or CURB_PROFILES.walk
  local chamfer = math.min(prof.exposed, height)
  local slopeH = math.min(math.tan(math.rad(prof.angle)) * chamfer,
                          math.max(0.0, (hw - inset) * 0.9))

  local chX = nil
  if slopeH > 1e-6 and chamfer > 1e-6 then
    chX = hw - slopeH
    if capShrink then
      chX = math.max(inset, math.min(capShrink(slopeH), hw))
    end
  else
    chamfer, slopeH = 0.0, 0.0
  end

  local useUv = uvHw ~= nil
  local uvh = uvHw or hw
  local uvInset = math.max(0.0, uvh - CURB_STRIP)

  local cols = {}

  local function add(x, ux, drop, kind, hasBottom, role)
    cols[#cols + 1] = {x = x, uvx = (useUv and ux or x),
                       drop = drop, kind = kind, bottom = hasBottom, role = role}
  end

  if chX then
    add(-hw, -uvh, chamfer, "chamfer", true, "outer_near")
    add(-chX, -uvh + slopeH, 0.0, "curbtop", false, "outer_near_chamfer")
  else
    add(-hw, -uvh, chamfer, "curbtop", true, "outer_near")
  end
  add(-inset, -uvInset, 0.0, "walk", true, "inner_near")
  if walkFracs then
    for k, f in ipairs(walkFracs) do
      add(inset * f, uvInset * f, 0.0, "walk", false, "walk_" .. k)
    end
  end
  add(inset, uvInset, 0.0, "curbtop", true, "inner_far")
  if chX then
    add(chX, uvh - slopeH, 0.0, "chamfer", false, "outer_far_chamfer")
  end
  add(hw, uvh, chamfer, nil, true, "outer_far")
  return cols, hw, chamfer
end

local function signedArea2D(pts)
  local sA, n = 0.0, #pts
  for i = 1, n do
    local a, b = pts[i], pts[(i % n) + 1]
    sA = sA + (a.x * b.y - b.x * a.y)
  end
  return sA / 2.0
end

local function unit2(dx, dy)
  local L = math.sqrt(dx * dx + dy * dy)
  if L <= 1e-9 then return nil end
  return dx / L, dy / L
end

local function offsetPolygonInward(pts, dist)
  local n = #pts
  local ccw = signedArea2D(pts) > 0
  local out = {}
  for i = 1, n do
    local pPrev = pts[((i - 2) % n) + 1]
    local p = pts[i]
    local pNext = pts[(i % n) + 1]
    local d0x, d0y = unit2(p.x - pPrev.x, p.y - pPrev.y)
    local d1x, d1y = unit2(pNext.x - p.x, pNext.y - p.y)
    if not d0x or not d1x then
      out[i] = vec3(p.x, p.y, p.z)
    else
      local n0x, n0y, n1x, n1y
      if ccw then
        n0x, n0y = -d0y, d0x
        n1x, n1y = -d1y, d1x
      else
        n0x, n0y = d0y, -d0x
        n1x, n1y = d1y, -d1x
      end
      local mx, my = n0x + n1x, n0y + n1y
      local L = math.sqrt(mx * mx + my * my)
      if L < 1e-9 then
        out[i] = vec3(p.x, p.y, p.z)
      else
        mx, my = mx / L, my / L
        local cosv = mx * n1x + my * n1y
        local step = dist / math.max(cosv, ISLAND_MITER_MIN_COS)
        out[i] = vec3(p.x + mx * step, p.y + my * step, p.z)
      end
    end
  end
  return out
end

local PolyIndex = {}
PolyIndex.__index = PolyIndex

local function newPolyIndex(poly)
  local self = setmetatable({}, PolyIndex)
  local n = #poly
  self.n = n
  local edges = {}
  for i = 1, n do
    local a, b = poly[i], poly[(i % n) + 1]
    edges[i] = {a.x, a.y, b.x, b.y}
  end
  self.edges = edges
  if n == 0 then
    self.minx, self.miny, self.cs, self.nx, self.ny = 0, 0, 1, 1, 1
    self.cells, self.rows = {{}}, {{}}
    return self
  end

  local minx, maxx = math.huge, -math.huge
  local miny, maxy = math.huge, -math.huge
  for i = 1, n do
    local q = poly[i]
    if q.x < minx then minx = q.x end
    if q.x > maxx then maxx = q.x end
    if q.y < miny then miny = q.y end
    if q.y > maxy then maxy = q.y end
  end
  local w = math.max(maxx - minx, 1e-9)
  local h = math.max(maxy - miny, 1e-9)
  local cs = math.sqrt(w * h / math.max(n, 1))
  if not (cs > 1e-12) then cs = math.max(w, h) end
  local nx = math.floor(w / cs) + 1
  local ny = math.floor(h / cs) + 1
  if nx > 512 then nx = 512 end
  if ny > 512 then ny = 512 end
  cs = math.max(w / nx, h / ny, 1e-12)
  nx = math.min(512, math.floor(w / cs) + 1)
  ny = math.min(512, math.floor(h / cs) + 1)

  self.minx, self.miny, self.cs, self.nx, self.ny = minx, miny, cs, nx, ny
  local cells, rows = {}, {}
  for i = 1, nx * ny do cells[i] = {} end
  for i = 1, ny do rows[i] = {} end
  local function cl(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
  end
  for _, e in ipairs(edges) do
    local ax, ay, bx, by = e[1], e[2], e[3], e[4]
    local ix0 = cl(math.floor((math.min(ax, bx) - minx) / cs), 0, nx - 1)
    local ix1 = cl(math.floor((math.max(ax, bx) - minx) / cs), 0, nx - 1)
    local iy0 = cl(math.floor((math.min(ay, by) - miny) / cs), 0, ny - 1)
    local iy1 = cl(math.floor((math.max(ay, by) - miny) / cs), 0, ny - 1)
    for iy = iy0, iy1 do
      table.insert(rows[iy + 1], e)
      local base = iy * nx
      for ix = ix0, ix1 do table.insert(cells[base + ix + 1], e) end
    end
  end
  self.cells, self.rows = cells, rows
  return self
end

function PolyIndex:contains(px, py)
  if self.n == 0 then return false end
  local iy = math.floor((py - self.miny) / self.cs)
  if iy < 0 then iy = 0 elseif iy > self.ny - 1 then iy = self.ny - 1 end
  local inside = false
  for _, e in ipairs(self.rows[iy + 1]) do
    local x1, y1, x2, y2 = e[1], e[2], e[3], e[4]
    if (y1 > py) ~= (y2 > py) then
      if x1 + (py - y1) * (x2 - x1) / (y2 - y1) > px then inside = not inside end
    end
  end
  return inside
end

function PolyIndex:dist(px, py)
  if self.n == 0 then return 1e18 end
  local cs, nx, ny = self.cs, self.nx, self.ny
  local cx = math.floor((px - self.minx) / cs)
  local cy = math.floor((py - self.miny) / cs)
  if cx < 0 then cx = 0 elseif cx > nx - 1 then cx = nx - 1 end
  if cy < 0 then cy = 0 elseif cy > ny - 1 then cy = ny - 1 end

  local best = 1e18
  local span = (nx > ny) and nx or ny
  local r = 0
  while true do
    local block = {}
    if r == 0 then
      block[1] = {cx, cy}
    else
      local x0, x1, y0, y1 = cx - r, cx + r, cy - r, cy + r
      for ix = x0, x1 do
        if ix >= 0 and ix < nx then
          if y0 >= 0 and y0 < ny then block[#block + 1] = {ix, y0} end
          if y1 >= 0 and y1 < ny then block[#block + 1] = {ix, y1} end
        end
      end
      for iy = y0 + 1, y1 - 1 do
        if iy >= 0 and iy < ny then
          if x0 >= 0 and x0 < nx then block[#block + 1] = {x0, iy} end
          if x1 >= 0 and x1 < nx then block[#block + 1] = {x1, iy} end
        end
      end
    end
    for _, ce in ipairs(block) do
      for _, e in ipairs(self.cells[ce[2] * nx + ce[1] + 1]) do
        local ax, ay, bx, by = e[1], e[2], e[3], e[4]
        local dx, dy = bx - ax, by - ay
        local l2 = dx * dx + dy * dy
        local d
        if l2 < 1e-15 then
          d = math.sqrt((px - ax) ^ 2 + (py - ay) ^ 2)
        else
          local t = ((px - ax) * dx + (py - ay) * dy) / l2
          if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
          d = math.sqrt((px - (ax + dx * t)) ^ 2 + (py - (ay + dy * t)) ^ 2)
        end
        if d < best then best = d end
      end
    end
    local loX = self.minx + (cx - r) * cs
    local hiX = self.minx + (cx + r + 1) * cs
    local loY = self.miny + (cy - r) * cs
    local hiY = self.miny + (cy + r + 1) * cs
    local reach = math.min(px - loX, hiX - px, py - loY, hiY - py)
    if best <= reach then break end
    r = r + 1
    if r > span then break end
  end
  return best
end

local function fitInnerRing(outer, cand, target)
  local n = #outer
  local idx = newPolyIndex(outer)
  local dirs, lens, samples = {}, {}, {}

  for i = 1, n do
    local p, q = outer[i], cand[i]
    local vx, vy = q.x - p.x, q.y - p.y
    local L = math.sqrt(vx * vx + vy * vy)
    if L < 1e-9 then
      dirs[i] = {0.0, 0.0}; lens[i] = 0.0; samples[i] = {}
    else
      local ux, uy = vx / L, vy / L
      dirs[i] = {ux, uy}; lens[i] = L
      local probeD = target / 0.45
      local cfx, cfy = p.x + vx, p.y + vy
      local cpx, cpy = p.x + ux * probeD, p.y + uy * probeD
      if idx:contains(cfx, cfy) and idx:dist(cfx, cfy) >= target * 0.999
         and idx:contains(cpx, cpy) and idx:dist(cpx, cpy) >= target * 0.999 then
        samples[i] = false
      else
        local row = {}
        for k = 1, 40 do
          local dAlong = L * 4.0 * k / 40.0
          local cxp, cyp = p.x + ux * dAlong, p.y + uy * dAlong
          if not idx:contains(cxp, cyp) then break end
          row[#row + 1] = {dAlong, idx:dist(cxp, cyp)}
        end
        samples[i] = row
      end
    end
  end

  local want = {}
  for i = 1, n do
    local row = samples[i]
    if row == false then
      want[i] = target
    else
      local h = 0.0
      for _, e in ipairs(row) do if e[2] > h then h = e[2] end end
      want[i] = (h > 0) and math.min(target, 0.45 * h) or 0.0
    end
  end

  local seg = {}
  for i = 1, n do
    local a, b = outer[i], outer[(i % n) + 1]
    seg[i] = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
  end
  for _ = 1, 2 do
    for i = 1, n do
      local j = (i % n) + 1
      want[j] = math.min(want[j], want[i] + seg[i])
    end
    for i = n, 1, -1 do
      local j = (i % n) + 1
      want[i] = math.min(want[i], want[j] + seg[i])
    end
  end

  local out, nNarrow = {}, 0
  for i = 1, n do
    local p, w, row = outer[i], want[i], samples[i]
    if row == false and w >= target * 0.999 then
      out[i] = cand[i]
    else
      if row == false then
        row = {}
        for k = 1, 40 do
          local dAlong = lens[i] * 4.0 * k / 40.0
          local cxp = p.x + dirs[i][1] * dAlong
          local cyp = p.y + dirs[i][2] * dAlong
          if not idx:contains(cxp, cyp) then break end
          row[#row + 1] = {dAlong, idx:dist(cxp, cyp)}
        end
      end
      if #row == 0 or w <= 1e-6 then
        out[i] = vec3(p.x + dirs[i][1] * 0.01, p.y + dirs[i][2] * 0.01, cand[i].z)
        nNarrow = nNarrow + 1
      else
        if w < target * 0.999 then nNarrow = nNarrow + 1 end
        local lo, hi = 0.0, row[#row][1]
        for _, e in ipairs(row) do
          if e[2] >= w then hi = e[1] break end
          lo = e[1]
        end
        for _ = 1, 12 do
          local mid = (lo + hi) / 2.0
          local cxp = p.x + dirs[i][1] * mid
          local cyp = p.y + dirs[i][2] * mid
          if idx:contains(cxp, cyp) and idx:dist(cxp, cyp) >= w then hi = mid
          else lo = mid end
        end
        out[i] = vec3(p.x + dirs[i][1] * hi, p.y + dirs[i][2] * hi, cand[i].z)
      end
    end
  end
  return out, nNarrow
end

local function triangulatePolygon(ptsIn)

  local pts = {}
  for i = 1, #ptsIn do
    local q = ptsIn[i]
    local prev = pts[#pts]
    if not prev or math.sqrt((q.x - prev.x) ^ 2 + (q.y - prev.y) ^ 2) > 1e-6 then
      pts[#pts + 1] = q
    end
  end
  while #pts > 3 do
    local a, b = pts[1], pts[#pts]
    if math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) > 1e-6 then break end
    table.remove(pts)
  end

  local n = #pts
  if n < 3 then return {}, pts end
  local order = {}
  for i = 1, n do order[i] = i end
  if signedArea2D(pts) < 0 then
    local r = {}
    for i = n, 1, -1 do r[#r + 1] = order[i] end
    order = r
  end
  local m = #order

  local prv, nxt, alive = {}, {}, {}
  for i = 1, m do
    prv[i] = ((i - 2) % m) + 1
    nxt[i] = (i % m) + 1
    alive[i] = true
  end

  local function P(i) return pts[order[i]] end
  local function area2(a, b, c)
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
  end
  local function inTri(p, a, b, c)
    return area2(a, b, p) >= -1e-12 and area2(b, c, p) >= -1e-12
           and area2(c, a, p) >= -1e-12
  end
  local function cost(i)
    local a, b, c = P(prv[i]), P(i), P(nxt[i])
    local function h(u, v) return math.sqrt((u.x - v.x) ^ 2 + (u.y - v.y) ^ 2) end
    return math.max(h(b, a), h(c, b), h(a, c))
  end
  local function isEar(i)
    local a, b, c = P(prv[i]), P(i), P(nxt[i])
    if area2(a, b, c) <= 1e-12 then return false end
    local j = nxt[nxt[i]]
    while j ~= prv[i] do
      if inTri(P(j), a, b, c) then return false end
      j = nxt[j]
    end
    return true
  end

  local tris = {}
  local remaining = m
  local guard = 0
  while remaining > 3 and guard < 8 * m + 64 do
    guard = guard + 1
    local chosen, best = nil, math.huge
    for i = 1, m do
      if alive[i] and isEar(i) then
        local c = cost(i)
        if c < best then best, chosen = c, i end
      end
    end

    if not chosen then
      local bestArea = -math.huge
      for i = 1, m do
        if alive[i] then
          local a, b, c = P(prv[i]), P(i), P(nxt[i])
          local ar = area2(a, b, c)
          if ar > bestArea then bestArea, chosen = ar, i end
        end
      end
      if not chosen or bestArea <= 0.0 then break end
    end
    local a, b = prv[chosen], nxt[chosen]
    tris[#tris + 1] = {order[a], order[chosen], order[b]}
    alive[chosen] = false
    nxt[a] = b
    prv[b] = a
    remaining = remaining - 1
  end
  if remaining == 3 then
    for k = 1, m do
      if alive[k] then
        tris[#tris + 1] = {order[prv[k]], order[k], order[nxt[k]]}
        break
      end
    end
  end
  return tris, pts
end

local function arcPoints(cx, cy, pFrom, pTo, z, maxTurnDeg, through)
  local a0 = math.atan2(pFrom.y - cy, pFrom.x - cx)
  local a1 = math.atan2(pTo.y - cy, pTo.x - cx)
  local r0 = math.sqrt((pFrom.x - cx) ^ 2 + (pFrom.y - cy) ^ 2)
  local r1 = math.sqrt((pTo.x - cx) ^ 2 + (pTo.y - cy) ^ 2)
  local d
  if through then

    local at = math.atan2(through.y - cy, through.x - cx)
    local twoPi = 2 * math.pi
    local span = (a1 - a0) % twoPi
    local rel = (at - a0) % twoPi
    d = (rel < span) and span or (span - twoPi)
  else
    d = a1 - a0
    while d > math.pi do d = d - 2 * math.pi end
    while d < -math.pi do d = d + 2 * math.pi end
  end
  local steps = math.max(2, math.ceil(math.abs(math.deg(d)) / math.max(0.5, maxTurnDeg)))
  local pts = {}
  for k = 1, steps - 1 do
    local f = k / steps
    local ang = a0 + d * f
    local r = r0 + (r1 - r0) * f
    pts[#pts + 1] = vec3(cx + math.cos(ang) * r, cy + math.sin(ang) * r, z)
  end
  return pts
end

local function roundPolylineCorners(ring, radius, minTurnDeg)
  local n = #ring
  if n < 3 or radius <= 0 then return ring end
  local ccw = signedArea2D(ring) > 0

  local seg, total = {}, 0.0
  for i = 1, n do
    local a, b = ring[i], ring[(i % n) + 1]
    seg[i] = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
    total = total + seg[i]
  end
  if total < 1e-6 then return ring end
  local arcAt = {0.0}
  for i = 2, n do arcAt[i] = arcAt[i - 1] + seg[i - 1] end

  local corners = {}
  for i = 1, n do
    local a = ring[((i - 2) % n) + 1]
    local p = ring[i]
    local b = ring[(i % n) + 1]
    local d0x, d0y = unit2(p.x - a.x, p.y - a.y)
    local d1x, d1y = unit2(b.x - p.x, b.y - p.y)
    if d0x and d1x then
      local crossz = d0x * d1y - d0y * d1x
      local isConvex = (crossz > 0) == ccw
      if isConvex then
        local cosv = clamp(d0x * d1x + d0y * d1y, -1.0, 1.0)
        local turn = math.deg(math.acos(cosv))
        if turn >= minTurnDeg then
          corners[#corners + 1] = {i = i, turn = turn}
        end
      end
    end
  end
  if #corners == 0 then return ring end

  local trims = {}
  local nc = #corners
  for k = 1, nc do
    local i, turn = corners[k].i, corners[k].turn
    local half = math.rad((180.0 - turn) / 2.0)
    local tlen = radius / math.max(math.tan(half), 1e-6)
    local prevI = corners[((k - 2) % nc) + 1].i
    local nextI = corners[(k % nc) + 1].i
    local gapPrev = (arcAt[i] - arcAt[prevI]) % total
    local gapNext = (arcAt[nextI] - arcAt[i]) % total
    if nc == 1 then gapPrev, gapNext = total, total end
    tlen = math.min(tlen, gapPrev * 0.45, gapNext * 0.45, total * 0.3)
    if tlen > 1e-4 then trims[i] = tlen end
  end
  if next(trims) == nil then return ring end

  local function pointAt(arcS)
    local sv = arcS % total
    for i = 1, n do
      if sv <= arcAt[i] + seg[i] + 1e-12 then
        local f = (seg[i] > 1e-12) and ((sv - arcAt[i]) / seg[i]) or 0.0
        f = clamp(f, 0.0, 1.0)
        local a, b = ring[i], ring[(i % n) + 1]
        return vec3(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f,
                    a.z + (b.z - a.z) * f)
      end
    end
    return ring[n]
  end

  local dropped = {}
  for i, tlen in pairs(trims) do
    for j = 1, n do
      local d = (arcAt[j] - arcAt[i] + total / 2.0) % total - total / 2.0
      if math.abs(d) <= tlen + 1e-9 then dropped[j] = true end
    end
  end

  local out = {}
  for i = 1, n do
    local tlen = trims[i]
    if tlen then
      local p = ring[i]
      local sPt = pointAt(arcAt[i] - tlen)
      local ePt = pointAt(arcAt[i] + tlen)
      local d0x, d0y = unit2(p.x - sPt.x, p.y - sPt.y)
      local d1x, d1y = unit2(ePt.x - p.x, ePt.y - p.y)
      if not d0x or not d1x then
        out[#out + 1] = p
      else
        local cosv = clamp(d0x * d1x + d0y * d1y, -1.0, 1.0)
        local half = (math.pi - math.acos(cosv)) / 2.0
        local mx, my = d1x - d0x, d1y - d0y
        local L = math.sqrt(mx * mx + my * my)
        if math.sin(half) < 1e-6 or L < 1e-9 then
          out[#out + 1] = p
        else
          local rEff = tlen * math.tan(half)
          local cx = p.x + (mx / L) * (rEff / math.sin(half))
          local cy = p.y + (my / L) * (rEff / math.sin(half))
          out[#out + 1] = sPt
          for _, q in ipairs(arcPoints(cx, cy, sPt, ePt, p.z,
                                       ZEBRA_FILLET_MAX_TURN_DEG)) do
            out[#out + 1] = q
          end
          out[#out + 1] = ePt
        end
      end
    elseif not dropped[i] then
      out[#out + 1] = ring[i]
    end
  end

  local clean = {}
  for _, q in ipairs(out) do
    local last = clean[#clean]
    if not last or math.sqrt((q.x - last.x) ^ 2 + (q.y - last.y) ^ 2) >= 1e-4 then
      clean[#clean + 1] = q
    end
  end
  return (#clean >= 4) and clean or ring
end

local function flatDir(v)
  local d = vec3(v.x, v.y, 0.0)
  if d:length() < 1e-9 then return vec3(1.0, 0.0, 0.0) end
  return d:normalized()
end

local function roundReflexCorners(ring, radius, minTurnDeg)
  local n = #ring
  if n < 4 or radius <= 0 then return ring end
  minTurnDeg = minTurnDeg or 45.0
  local ccw = signedArea2D(ring) > 0
  local out = {}
  for i = 1, n do
    local a = ring[((i - 2) % n) + 1]
    local p = ring[i]
    local b = ring[(i % n) + 1]
    local d0x, d0y = unit2(p.x - a.x, p.y - a.y)
    local d1x, d1y = unit2(b.x - p.x, b.y - p.y)
    local handled = false
    if d0x and d1x then
      local crossz = d0x * d1y - d0y * d1x
      if (crossz > 0) ~= ccw then
        local cosv = clamp(d0x * d1x + d0y * d1y, -1.0, 1.0)
        local turn = math.deg(math.acos(cosv))
        if turn >= minTurnDeg then
          local half = math.rad((180.0 - turn) / 2.0)
          if math.tan(half) >= 1e-6 then
            local tlen = radius / math.tan(half)
            local la = math.sqrt((p.x - a.x) ^ 2 + (p.y - a.y) ^ 2)
            local lb = math.sqrt((b.x - p.x) ^ 2 + (b.y - p.y) ^ 2)
            tlen = math.min(tlen, la * 0.45, lb * 0.45)
            if tlen >= 1e-4 then
              local mx, my = d0x - d1x, d0y - d1y
              local L = math.sqrt(mx * mx + my * my)
              if L >= 1e-9 then
                local sp = vec3(p.x - d0x * tlen, p.y - d0y * tlen, p.z)
                local ep = vec3(p.x + d1x * tlen, p.y + d1y * tlen, p.z)
                local rEff = tlen * math.tan(half)
                local cx = p.x + (mx / L) * (rEff / math.sin(half))
                local cy = p.y + (my / L) * (rEff / math.sin(half))
                out[#out + 1] = sp
                for _, q in ipairs(arcPoints(cx, cy, sp, ep, p.z,
                                             ZEBRA_FILLET_MAX_TURN_DEG)) do
                  out[#out + 1] = q
                end
                out[#out + 1] = ep
                handled = true
              end
            end
          end
        end
      end
    end
    if not handled then out[#out + 1] = p end
  end
  return out
end

local function offsetPolyline(points, widths, side)
  local n = #points
  local out = {}
  for i = 1, n do
    local tn
    if i == 1 then tn = points[2] - points[1]
    elseif i == n then tn = points[n] - points[n - 1]
    else tn = points[i + 1] - points[i - 1] end
    tn = flatDir(tn)
    local nx, ny = -tn.y, tn.x
    local p, w = points[i], widths[i]
    out[i] = vec3(p.x + nx * side * w / 2.0, p.y + ny * side * w / 2.0, p.z)
  end
  return out
end

local function polylineCross(pa, pb)
  for i = 1, #pa - 1 do
    local a0, a1 = pa[i], pa[i + 1]
    local d1x, d1y = a1.x - a0.x, a1.y - a0.y
    for j = 1, #pb - 1 do
      local b0, b1 = pb[j], pb[j + 1]
      local d2x, d2y = b1.x - b0.x, b1.y - b0.y
      local den = d1x * d2y - d1y * d2x
      if math.abs(den) >= 1e-12 then
        local dx, dy = b0.x - a0.x, b0.y - a0.y
        local sPar = (dx * d2y - dy * d2x) / den
        local uPar = (dx * d1y - dy * d1x) / den
        if sPar >= -1e-9 and sPar <= 1 + 1e-9
           and uPar >= -1e-9 and uPar <= 1 + 1e-9 then
          return vec3(a0.x + d1x * sPar, a0.y + d1y * sPar,
                      a0.z + (a1.z - a0.z) * sPar), i, j
        end
      end
    end
  end
  return nil
end

local function hairpinUnionRing(rdI, eI, rdJ, eJ, tip)
  local function ordered(rd, atEnd)
    local p, w = {}, {}
    if atEnd then
      for i = 1, #rd.points do p[i] = rd.points[i]; w[i] = rd.widths[i] end
    else
      for i = #rd.points, 1, -1 do p[#p + 1] = rd.points[i]; w[#w + 1] = rd.widths[i] end
    end
    return p, w
  end

  local pa, wa = ordered(rdI, eI)
  local pb, wb = ordered(rdJ, eJ)
  if #pa < 2 or #pb < 2 then return nil end

  local hwa, hwb = wa[#wa] / 2.0, wb[#wb] / 2.0
  if math.max(hwa, hwb) / math.max(math.min(hwa, hwb), 1e-6)
     > HAIRPIN_UNION_MAX_WIDTH_RATIO then
    return nil
  end

  local da = flatDir(pa[#pa] - pa[#pa - 1])
  local db = flatDir(pb[#pb] - pb[#pb - 1])
  local crossz = da.x * db.y - da.y * db.x
  if math.abs(crossz) < 1e-6 then return nil end
  local sideAOut = (crossz < 0) and -1 or 1
  local sideBOut = -sideAOut

  local aOut = offsetPolyline(pa, wa, sideAOut)
  local aIn  = offsetPolyline(pa, wa, -sideAOut)
  local bOut = offsetPolyline(pb, wb, sideBOut)
  local bIn  = offsetPolyline(pb, wb, -sideBOut)

  local K, ia, ib = polylineCross(aIn, bIn)
  if not K then return nil end

  local zt = pa[#pa].z
  local bis = flatDir(da + db)
  local tipVia = vec3(tip.x + bis.x * hwa, tip.y + bis.y * hwa, zt)

  local function freeCap(pts, ws, pFrom, pTo)
    local d0 = flatDir(pts[2] - pts[1])
    local hw0 = ws[1] / 2.0
    local c = pts[1]
    local via = vec3(c.x - d0.x * hw0, c.y - d0.y * hw0, c.z)
    return arcPoints(c.x, c.y, pFrom, pTo, pts[1].z, ROUND_END_MAX_TURN_DEG, via)
  end

  local ring = {}
  local function push(q) ring[#ring + 1] = q end
  for i = 1, #aOut do push(aOut[i]) end
  for _, q in ipairs(arcPoints(tip.x, tip.y, aOut[#aOut], bOut[#bOut], zt,
                               ROUND_END_MAX_TURN_DEG, tipVia)) do push(q) end
  for i = #bOut, 1, -1 do push(bOut[i]) end
  if not (eJ and rdJ.noCapStart or rdJ.noCapEnd) then
    for _, q in ipairs(freeCap(pb, wb, bOut[1], bIn[1])) do push(q) end
  end
  for i = 1, ib do push(bIn[i]) end
  push(K)
  for i = ia, 1, -1 do push(aIn[i]) end
  if not (eI and rdI.noCapStart or rdI.noCapEnd) then
    for _, q in ipairs(freeCap(pa, wa, aIn[1], aOut[1])) do push(q) end
  end

  local clean = {}
  for _, q in ipairs(ring) do
    local last = clean[#clean]
    if not last or math.sqrt((q.x - last.x) ^ 2 + (q.y - last.y) ^ 2) >= 1e-6 then
      clean[#clean + 1] = q
    end
  end
  while #clean > 3 and math.sqrt((clean[#clean].x - clean[1].x) ^ 2
                                 + (clean[#clean].y - clean[1].y) ^ 2) < 1e-6 do
    table.remove(clean)
  end
  if #clean < 4 or math.abs(signedArea2D(clean)) < ISLAND_MIN_AREA then return nil end
  return roundReflexCorners(clean, HAIRPIN_NOTCH_RADIUS)
end

local function extractIslands(roads)
  if not BUILD_TRAFFIC_ISLANDS then return {}, roads end

  local thin, thick = {}, {}
  for _, rd in ipairs(roads) do
    local maxW = 0.0
    for _, w in ipairs(rd.widths) do if w > maxW then maxW = w end end
    if maxW < ISLAND_MAX_MARKER_WIDTH and #rd.points >= 2 then
      thin[#thin + 1] = rd
    else
      thick[#thick + 1] = rd
    end
  end
  if #thin == 0 then return {}, roads end

  local tol = ISLAND_JOIN_TOLERANCE
  local function endp(rd, last)
    return last and rd.points[#rd.points] or rd.points[1]
  end
  local function near(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy) <= tol
  end

  local used = {}
  local islands, leftovers = {}, {}

  for startI = 1, #thin do
    if not used[startI] then
      used[startI] = true
      local chain = {{i = startI, rev = false}}
      local ringStart = endp(thin[startI], false)
      local cur = endp(thin[startI], true)
      local closed = false
      local selfClosing = #thin[startI].points >= 3

      while true do
        if near(cur, ringStart) and (#chain >= 2 or selfClosing) then
          closed = true
          break
        end
        local nxtI, nxtRev = nil, false
        for j = 1, #thin do
          if not used[j] then
            if near(cur, endp(thin[j], false)) then nxtI, nxtRev = j, false break end
            if near(cur, endp(thin[j], true)) then nxtI, nxtRev = j, true break end
          end
        end
        if not nxtI then break end
        used[nxtI] = true
        chain[#chain + 1] = {i = nxtI, rev = nxtRev}
        cur = endp(thin[nxtI], not nxtRev)
      end

      if not closed then
        for _, c in ipairs(chain) do leftovers[#leftovers + 1] = thin[c.i] end
      else
        local pts = {}
        for _, c in ipairs(chain) do
          local seq = {}
          local src = thin[c.i].points
          if c.rev then
            for k = #src, 1, -1 do seq[#seq + 1] = src[k] end
          else
            for k = 1, #src do seq[k] = src[k] end
          end
          if ISLAND_SMOOTH and #seq >= 3 then
            seq = smoothPath(seq, SMOOTH_SEGMENT_LEN)
          end
          local from = 1
          if #pts > 0 and near(seq[1], pts[#pts]) then from = 2 end
          for k = from, #seq do
            local p = seq[k]
            if #pts == 0 or math.sqrt((p.x - pts[#pts].x) ^ 2
                                      + (p.y - pts[#pts].y) ^ 2) >= 1e-3 then
              pts[#pts + 1] = p
            end
          end
        end
        while #pts > 3 and near(pts[#pts], pts[1]) do table.remove(pts) end

        if ISLAND_ROUND_CORNERS and #pts >= 3 then
          pts = roundPolylineCorners(pts, ISLAND_CORNER_RADIUS,
                                     ISLAND_CORNER_MIN_TURN_DEG)
        end

        local area = math.abs(signedArea2D(pts))
        if #pts < 3 or area < ISLAND_MIN_AREA then
          for _, c in ipairs(chain) do leftovers[#leftovers + 1] = thin[c.i] end
        else
          local base = thin[chain[1].i]
          local srcIds = {}
          for _, c in ipairs(chain) do srcIds[#srcIds + 1] = thin[c.i].id end
          islands[#islands + 1] = {
            id = base.id, name = base.name, persistentId = base.persistentId,
            srcIds = srcIds,
            ring = pts, area = area, parts = #chain,
            curb = base.curb, walk = base.walk,
            profile = base.profile or "island",
            overObjects = base.overObjects,
            isIsland = true,
          }
        end
      end
    end
  end

  local rest = {}
  for _, r in ipairs(thick) do rest[#rest + 1] = r end
  for _, r in ipairs(leftovers) do rest[#rest + 1] = r end
  return islands, rest
end

local function polylineLength(pts)
  local acc = 0.0
  for i = 2, #pts do acc = acc + (pts[i] - pts[i - 1]):length() end
  return acc
end

local function dirAtEnd(pts, probe)
  local n = #pts
  if n < 2 then return vec3(1.0, 0.0, 0.0) end
  local ref = pts[1]
  local acc = 0.0
  for i = n, 2, -1 do
    acc = acc + (pts[i] - pts[i - 1]):length()
    if acc >= probe then ref = pts[i - 1] break end
  end
  return flatDir(pts[n] - ref)
end

local function trimFromEnd(pts, ws, length)
  if length <= 0.0 then
    local p, w = {}, {}
    for i = 1, #pts do p[i] = pts[i]; w[i] = ws[i] end
    return p, w
  end
  local n = #pts
  local remain = length
  local outP, outW = {}, {}
  for i = 1, n do outP[i] = pts[i]; outW[i] = ws[i] end
  while #outP >= 2 do
    local last = #outP
    local seg = (outP[last] - outP[last - 1]):length()
    if seg <= remain + 1e-12 then
      remain = remain - seg
      table.remove(outP); table.remove(outW)
      if remain <= 1e-12 then break end
    else
      local f = (seg - remain) / seg
      outP[last] = outP[last - 1] + (outP[last] - outP[last - 1]) * f
      outW[last] = outW[last - 1] + (outW[last] - outW[last - 1]) * f
      break
    end
  end
  return outP, outW
end

local function trimFromStart(pts, ws, length)
  local rp, rw = {}, {}
  for i = #pts, 1, -1 do rp[#rp + 1] = pts[i]; rw[#rw + 1] = ws[i] end
  local tp, tw = trimFromEnd(rp, rw, length)
  local op, ow = {}, {}
  for i = #tp, 1, -1 do op[#op + 1] = tp[i]; ow[#ow + 1] = tw[i] end
  return op, ow
end

local function junctionState(A, wA, B, wB, ta, tb)
  local a2, wa2 = trimFromEnd(A, wA, ta)
  local b2, wb2 = trimFromStart(B, wB, tb)
  if #a2 < 2 or #b2 < 2 then return nil end
  local dA = dirAtEnd(a2, ZEBRA_FILLET_TANGENT_PROBE)
  local rb = {}
  for i = #b2, 1, -1 do rb[#rb + 1] = b2[i] end
  local dB = dirAtEnd(rb, ZEBRA_FILLET_TANGENT_PROBE) * -1.0
  return a2[#a2], dA, wa2[#wa2] / 2.0, b2[1], dB, wb2[1] / 2.0
end

local function cornerTrims(pA, dA, hwA, pB, dB, hwB)
  local cross = dA.x * dB.y - dA.y * dB.x
  if math.abs(cross) < 0.02 then return nil end
  local sign = (cross > 0.0) and 1.0 or -1.0
  local nA = vec3(dA.y, -dA.x, 0.0) * sign
  local nB = vec3(dB.y, -dB.x, 0.0) * sign
  local a0 = pA - nA * hwA
  local b0 = pB - nB * hwB
  local rhs = b0 - a0
  local sPar = (rhs.x * dB.y - rhs.y * dB.x) / cross
  local inner = a0 + dA * sPar
  local footA = inner + nA * hwA
  local footB = inner + nB * hwB
  return {trimA = (pA - footA):dot(dA), trimB = (footB - pB):dot(dB),
          inner = inner, nA = nA, nB = nB, sign = sign,
          wA = hwA * 2.0, wB = hwB * 2.0, zA = pA.z, zB = pB.z}
end

local function hermite(p0, m0, p1, m1, t)
  local t2, t3 = t * t, t * t * t
  return p0 * (2 * t3 - 3 * t2 + 1) + m0 * (t3 - 2 * t2 + t)
         + p1 * (-2 * t3 + 3 * t2) + m1 * (t3 - t2)
end

local function bridgeSamples(pA, dA, pB, dB, magScale, count)
  count = count or 96
  local chordV = pB - pA
  local chord = vec3(chordV.x, chordV.y, 0.0):length()
  if chord < 1e-4 then return nil end
  local theta = math.acos(clamp(dA:dot(dB), -1.0, 1.0))
  local ratio = (theta < 1e-3) and 1.0
                or (2.0 * math.tan(theta / 4.0) / math.sin(theta / 2.0))
  local mag = chord * ratio * magScale
  if dA:dot(chordV) <= 0.0 or dB:dot(chordV) <= 0.0 then
    mag = math.min(mag, chord * 0.5)
  end
  local p0 = vec3(pA.x, pA.y, 0.0)
  local p1 = vec3(pB.x, pB.y, 0.0)
  local m0, m1 = dA * mag, dB * mag
  local out = {}
  for i = 0, count do out[i + 1] = hermite(p0, m0, p1, m1, i / count) end
  return out
end

local function outwardNormals(dA, dB)
  local crossZ = dA.x * dB.y - dA.y * dB.x
  if math.abs(crossZ) < 1e-4 then return nil end
  local sign = (crossZ > 0.0) and 1.0 or -1.0
  return vec3(dA.y, -dA.x, 0.0) * sign, vec3(dB.y, -dB.x, 0.0) * sign
end

local function outwardViolation(samples, pA, pB, nA, nB)
  if not nA then return -1.0 end
  local worst = -1e9
  for _, q in ipairs(samples) do
    worst = math.max(worst, (q - pA):dot(nA), (q - pB):dot(nB))
  end
  return worst
end

local function bridgeHalfwidths(samples, pA, dA, hwA, pB, dB, hwB)
  local n = #samples
  local nA, nB = outwardNormals(dA, dB)
  local floorHw = math.min(hwA, hwB)
  local tol = ZEBRA_FILLET_INSIDE_TOLERANCE
  local out = {}
  for i = 1, n do
    local u = (n > 1) and ((i - 1) / (n - 1)) or 0.0
    local hw = hwA + (hwB - hwA) * u
    if nA and ZEBRA_FILLET_KEEP_INSIDE then
      local j0 = math.max(1, i - 1)
      local j1 = math.min(n, i + 1)
      local d = flatDir(samples[j1] - samples[j0])
      local sign = ((dA.x * dB.y - dA.y * dB.x) > 0.0) and 1.0 or -1.0
      local nrm = vec3(d.y, -d.x, 0.0) * sign
      local limits = {{pA + nA * hwA, nA}, {pB + nB * hwB, nB}}
      for _, lb in ipairs(limits) do
        local proj = nrm:dot(lb[2])
        if proj > 1e-6 then
          hw = math.min(hw, (tol - (samples[i] - lb[1]):dot(lb[2])) / proj)
        end
      end
      hw = math.max(hw, floorHw)
    end
    out[i] = hw
  end
  return out
end

local function filletBridge(pA, dA, wA, pB, dB, wB, spacing, magScale)
  local dense = bridgeSamples(pA, dA, pB, dB, magScale or 1.0)
  if not dense then return {} end

  local cum, turnTotal = {0.0}, 0.0
  for i = 2, #dense do
    cum[i] = cum[i - 1] + (dense[i] - dense[i - 1]):length()
  end
  for i = 2, #dense - 1 do
    local a, b = flatDir(dense[i] - dense[i - 1]), flatDir(dense[i + 1] - dense[i])
    turnTotal = turnTotal + math.deg(math.acos(clamp(a:dot(b), -1.0, 1.0)))
  end
  local total = cum[#cum]
  if total < 1e-4 then return {} end

  local stepsLen = math.floor(total / math.max(spacing, 1e-3) + 0.5)
  local stepsAng = math.ceil(turnTotal / math.max(ZEBRA_FILLET_MAX_TURN_DEG, 0.1))
  local steps = math.max(2, stepsLen, math.min(stepsAng, 200))

  local pts, flats = {}, {}
  for sIdx = 1, steps - 1 do
    local target = total * sIdx / steps
    local j = 2
    while j <= #cum and cum[j] < target do j = j + 1 end
    j = math.min(j, #cum)
    local seg = cum[j] - cum[j - 1]
    local f = (seg > 1e-12) and ((target - cum[j - 1]) / seg) or 0.0
    local p = dense[j - 1] + (dense[j] - dense[j - 1]) * f
    local u = sIdx / steps
    pts[#pts + 1] = vec3(p.x, p.y, pA.z + (pB.z - pA.z) * u)
    flats[#flats + 1] = p
  end
  local hws = bridgeHalfwidths(flats, pA, dA, wA / 2.0, pB, dB, wB / 2.0)
  local out = {}
  for i = 1, #pts do out[i] = {p = pts[i], w = hws[i] * 2.0} end
  return out
end

local function pinches(pA, dA, hwA, pB, dB, hwB, scale)
  local sm = bridgeSamples(pA, dA, pB, dB, scale)
  if not sm then return false end
  local n = #sm
  for i = 2, n - 1 do
    local seg = ((sm[i] - sm[i - 1]):length() + (sm[i + 1] - sm[i]):length()) / 2.0
    if seg >= 1e-9 then
      local a, b = flatDir(sm[i] - sm[i - 1]), flatDir(sm[i + 1] - sm[i])
      local ang = math.acos(clamp(a:dot(b), -1.0, 1.0))
      local hw = hwA + (hwB - hwA) * ((i - 1) / (n - 1))
      if ang > 1e-9 and seg / ang < hw * 0.98 then return true end
    end
  end
  return false
end

local function solveInwardScale(pA, dA, hwA, pB, dB, hwB)
  if not ZEBRA_FILLET_KEEP_INSIDE then return 1.0 end
  local nA, nB = outwardNormals(dA, dB)
  if not nA then return 1.0 end
  local tol = ZEBRA_FILLET_INSIDE_TOLERANCE

  local function ok(scale)
    local sm = bridgeSamples(pA, dA, pB, dB, scale)
    return sm ~= nil and outwardViolation(sm, pA, pB, nA, nB) <= tol
  end

  if ok(1.0) then return 1.0 end
  local lo = 0.15
  if not ok(lo) then return nil end
  local hi = 1.0
  for _ = 1, 12 do
    local mid = (lo + hi) / 2.0
    if ok(mid) then lo = mid else hi = mid end
  end
  return lo
end

local function tryFan(A, wA, B, wB, capA, capB)
  local ta, tb = 0.0, 0.0
  local frame = nil
  for _ = 1, 8 do
    local pA, dA, hwA, pB, dB, hwB = junctionState(A, wA, B, wB, ta, tb)
    if not pA then return nil end
    local turn = math.deg(math.acos(clamp(dA:dot(dB), -1.0, 1.0)))
    if turn < ZEBRA_FAN_MIN_TURN_DEG then return nil end
    local ref = cornerTrims(pA, dA, hwA, pB, dB, hwB)
    if not ref then return nil end
    if (ref.inner - pA):length() > ZEBRA_FAN_MAX_REACH * math.max(hwA, hwB) then
      return nil
    end
    local dTa, dTb = ref.trimA, ref.trimB
    if math.abs(dTa) < 1e-3 and math.abs(dTb) < 1e-3 then
      frame = ref
      break
    end
    local nta, ntb = ta + dTa, tb + dTb
    if nta < -1e-6 or ntb < -1e-6 or nta > capA or ntb > capB then return nil end
    ta, tb = nta, ntb
  end
  if not frame then return nil end
  return {ta = ta, tb = tb, scale = 1.0, frame = frame}
end

local function fanCorner(inner, nA, wA, nB, wB, sign, spacing, zA, zB)
  local cz = nA.x * nB.y - nA.y * nB.x
  local turn = math.atan2(cz, clamp(nA:dot(nB), -1.0, 1.0))
  if math.abs(turn) < 1e-4 then return {} end

  local steps = math.max(2, math.ceil(math.abs(math.deg(turn))
                                      / math.max(ZEBRA_FILLET_MAX_TURN_DEG, 0.1)))
  steps = math.max(steps,
                   math.floor(math.abs(turn) * math.max(wA, wB)
                              / math.max(spacing, 1e-3) + 0.5), 2)
  steps = math.min(steps, 240)

  local capOk = (wB >= wA * math.cos(turn) - 1e-6)
                and (wA >= wB * math.cos(turn) - 1e-6)

  local out = {}
  for i = 0, steps do
    local t = i / steps
    local phi = turn * t
    local c, sn = math.cos(phi), math.sin(phi)
    local u = vec3(nA.x * c - nA.y * sn, nA.x * sn + nA.y * c, 0.0)

    local smooth = t * t * (3.0 - 2.0 * t)
    local r = wA + (wB - wA) * smooth
    if capOk then
      local ca, cb = math.cos(phi), math.cos(turn - phi)
      if ca > 0.05 then r = math.min(r, wA / ca) end
      if cb > 0.05 then r = math.min(r, wB / cb) end
    end
    if i == 0 then r = wA elseif i == steps then r = wB end
    r = math.max(r, 1e-3)

    local center = inner + u * (r / 2.0)
    if zA and zB then center = vec3(center.x, center.y, zA + (zB - zA) * smooth) end

    local tangent = vec3(-u.y, u.x, 0.0) * sign
    out[#out + 1] = {p = center, w = r, t = tangent}
  end
  return out
end

local function solveJunction(ptsA, wsA, ptsB, wsB)
  local capA = ZEBRA_FILLET_MAX_TRIM_RATIO * polylineLength(ptsA)
  local capB = ZEBRA_FILLET_MAX_TRIM_RATIO * polylineLength(ptsB)

  local pA, dA, hwA, pB, dB, hwB = junctionState(ptsA, wsA, ptsB, wsB, 0.0, 0.0)
  if not pA then return nil, "decal too short" end
  local turn0 = math.deg(math.acos(clamp(dA:dot(dB), -1.0, 1.0)))
  if turn0 > ZEBRA_FILLET_MAX_CORNER_DEG then
    return nil, "turn too sharp (V/hairpin)"
  end

  local fan = tryFan(ptsA, wsA, ptsB, wsB, capA, capB)
  if fan then return fan end

  local ratio = math.max(hwA, hwB) / math.max(math.min(hwA, hwB), 1e-6)
  if ratio > ZEBRA_FILLET_MAX_WIDTH_RATIO then
    return nil, "width ratio with no corner to fan from"
  end

  local ta, tb = 0.0, 0.0
  for _ = 1, 6 do
    local qA, qdA, qhwA, qB, qdB, qhwB = junctionState(ptsA, wsA, ptsB, wsB, ta, tb)
    if not qA then return nil, "decal too short" end
    local ref = cornerTrims(qA, qdA, qhwA, qB, qdB, qhwB)
    if not ref then break end
    if math.abs(ref.trimA) < 1e-3 and math.abs(ref.trimB) < 1e-3 then break end
    ta = math.max(0.0, math.min(capA, ta + ref.trimA))
    tb = math.max(0.0, math.min(capB, tb + ref.trimB))
  end
  ta = ta * ZEBRA_FILLET_INNER_BIAS
  tb = tb * ZEBRA_FILLET_INNER_BIAS

  local advance = ZEBRA_FILLET_MIN_ADVANCE
  local advanced = false
  for _ = 1, 16 do
    local qA, qdA, qhwA, qB, qdB, qhwB = junctionState(ptsA, wsA, ptsB, wsB, ta, tb)
    if not qA then return nil, "decal too short" end
    local chordV = qB - qA
    local chord = vec3(chordV.x, chordV.y, 0.0)
    local defA = advance - qdA:dot(chord)
    local defB = advance - qdB:dot(chord)
    if defA <= 1e-3 and defB <= 1e-3 then advanced = true break end
    if ta >= capA - 1e-6 and tb >= capB - 1e-6 then
      return nil, "overlap exceeds the trim budget"
    end
    ta = math.min(capA, ta + math.max(0.0, defA) * 0.5 + 1e-3)
    tb = math.min(capB, tb + math.max(0.0, defB) * 0.5 + 1e-3)
  end
  if not advanced then return nil, "overlap exceeds the trim budget" end

  local last = "outward bulge / inner curb pinch"
  for _ = 1, 6 do
    local qA, qdA, qhwA, qB, qdB, qhwB = junctionState(ptsA, wsA, ptsB, wsB, ta, tb)
    if not qA then return nil, "decal too short" end
    local scale = solveInwardScale(qA, qdA, qhwA, qB, qdB, qhwB)
    if scale == nil then
      last = "outward bulge unavoidable"
    elseif pinches(qA, qdA, qhwA, qB, qdB, qhwB, scale) then
      last = "radius smaller than the half-width (pinch)"
    else
      return {ta = ta, tb = tb, scale = scale, frame = nil}
    end
    if ta >= capA - 1e-6 and tb >= capB - 1e-6 then return nil, last end
    local step = math.max(0.25, 0.15 * (qhwA + qhwB))
    ta = math.min(capA, ta + step)
    tb = math.min(capB, tb + step)
  end
  return nil, last
end

local function clusterEndpoints(endpoints, tol)
  local n = #endpoints
  local parent = {}
  for i = 1, n do parent[i] = i end

  local function find(a)
    while parent[a] ~= a do
      parent[a] = parent[parent[a]]
      a = parent[a]
    end
    return a
  end

  for i = 1, n do
    for j = i + 1, n do
      if (endpoints[i].pos - endpoints[j].pos):length() <= tol then
        local ra, rb = find(i), find(j)
        if ra ~= rb then parent[rb] = ra end
      end
    end
  end

  local groups, order = {}, {}
  for i = 1, n do
    local r = find(i)
    if not groups[r] then groups[r] = {} order[#order + 1] = r end
    table.insert(groups[r], i)
  end
  local out = {}
  for _, r in ipairs(order) do out[#out + 1] = groups[r] end
  return out
end

local function keyOf(r, e) return r .. ":" .. e end

local function chainOrder(nRoads, partner)
  local chains, used = {}, {}

  local function walk(startRoad, enterEnd)
    local chain = {}
    local r, e = startRoad, enterEnd
    while true do
      if used[r] then return chain, true end
      used[r] = true
      chain[#chain + 1] = {road = r, rev = (e == 1)}
      local nxt = partner[keyOf(r, 1 - e)]
      if not nxt then return chain, false end
      r, e = nxt[1], nxt[2]
      if r == startRoad and e == enterEnd then return chain, true end
    end
  end

  for r = 1, nRoads do
    if not used[r] then
      local free = nil
      for _, e in ipairs({0, 1}) do
        if not partner[keyOf(r, e)] then free = e break end
      end
      if free ~= nil then
        local c, cyc = walk(r, free)
        chains[#chains + 1] = {chain = c, cycle = cyc}
      end
    end
  end
  for r = 1, nRoads do
    if not used[r] then
      local c, cyc = walk(r, 0)
      chains[#chains + 1] = {chain = c, cycle = cyc}
    end
  end
  return chains
end

local function oriented(prep, e)
  local p, w = {}, {}
  if e == 1 then
    for i = 1, #prep.pts do p[i] = prep.pts[i]; w[i] = prep.ws[i] end
  else
    for i = #prep.pts, 1, -1 do p[#p + 1] = prep.pts[i]; w[#w + 1] = prep.ws[i] end
  end
  return p, w
end

local function weldShortSegments(pts, ws, ts, minLen, closed)
  if #pts < 3 then return pts, ws, ts end
  local kp, kw, kt = {pts[1]}, {ws[1]}, {ts[1]}
  local last = #pts
  for i = 2, last do
    if i ~= last and (pts[i] - kp[#kp]):length() < minLen then
      if ts[i] then kt[#kt] = ts[i] end
      kw[#kw] = ws[i]
    else
      kp[#kp + 1] = pts[i]
      kw[#kw + 1] = ws[i]
      kt[#kt + 1] = ts[i]
    end
  end
  if #kp >= 3 and (kp[#kp] - kp[#kp - 1]):length() < minLen then
    if not kt[#kt] then kt[#kt] = kt[#kt - 1] end
    table.remove(kp, #kp - 1)
    table.remove(kw, #kw - 1)
    table.remove(kt, #kt - 1)
  end
  if closed and #kp >= 4 then
    local dxy = math.sqrt((kp[#kp].x - kp[1].x) ^ 2 + (kp[#kp].y - kp[1].y) ^ 2)
    if dxy < ZEBRA_SEAM_WELD then
      if not kt[1] and kt[#kt] then kt[1] = kt[#kt] end
      table.remove(kp)
      table.remove(kw)
      table.remove(kt)
    end
  end
  return kp, kw, kt
end

local function markJoinedEnds(roads)
  if not SUPPRESS_CAPS_AT_JUNCTIONS then return 0 end

  local ends = {}
  for _, rd in ipairs(roads) do
    if not rd.isIsland and #rd.points >= 2 then
      ends[#ends + 1] = {rd = rd, key = "noCapStart", p = rd.points[1]}
      ends[#ends + 1] = {rd = rd, key = "noCapEnd",   p = rd.points[#rd.points]}
    end
  end

  local marked = 0
  for i = 1, #ends do
    for j = i + 1, #ends do
      local a, b = ends[i], ends[j]
      if a.rd ~= b.rd
         and math.sqrt((a.p.x - b.p.x) ^ 2 + (a.p.y - b.p.y) ^ 2) <= JUNCTION_CAP_TOLERANCE then
        for _, e in ipairs({a, b}) do
          if not e.rd[e.key] then
            e.rd[e.key] = true
            marked = marked + 1
          end
        end
      end
    end
  end
  return marked
end

local function endInfo(rd, atEnd)
  local pts = rd.points
  if #pts < 2 then return nil end
  local tip = atEnd and pts[#pts] or pts[1]
  local probe = math.max(0.05, ZEBRA_FILLET_TANGENT_PROBE)
  local acc, ref = 0.0, nil
  if atEnd then
    for k = #pts - 1, 1, -1 do
      acc = acc + (pts[k + 1] - pts[k]):length()
      ref = pts[k]
      if acc >= probe then break end
    end
  else
    for k = 2, #pts do
      acc = acc + (pts[k] - pts[k - 1]):length()
      ref = pts[k]
      if acc >= probe then break end
    end
  end
  if not ref then return nil end
  return tip, flatDir(tip - ref)
end

local function flushHairpinTips(roads)
  if not (FLUSH_HAIRPIN_TIPS and ROUND_OPEN_ENDS) then return 0 end

  local ends = {}
  for _, rd in ipairs(roads) do
    if not rd.isIsland and #rd.points >= 2 then
      ends[#ends + 1] = {rd = rd, e = true}
      ends[#ends + 1] = {rd = rd, e = false}
    end
  end

  local done, handled, pairs_ = {}, 0, {}
  local function key(rd, e) return tostring(rd.id) .. ":" .. tostring(e) end

  for i = 1, #ends do
    local rdI, eI = ends[i].rd, ends[i].e
    if not done[key(rdI, eI)] then
      for j = i + 1, #ends do
        local rdJ, eJ = ends[j].rd, ends[j].e
        if rdI ~= rdJ and not done[key(rdJ, eJ)] then
          local pI, dI = endInfo(rdI, eI)
          local pJ, dJ = endInfo(rdJ, eJ)
          if pI and pJ
             and math.sqrt((pI.x - pJ.x) ^ 2 + (pI.y - pJ.y) ^ 2) <= JUNCTION_CAP_TOLERANCE then
            local cosv = clamp(dI.x * -dJ.x + dI.y * -dJ.y, -1.0, 1.0)
            local turn = math.deg(math.acos(cosv))
            if turn > ZEBRA_FILLET_MAX_CORNER_DEG then
              local den = dI.x * dJ.y - dI.y * dJ.x
              if math.abs(den) >= 1e-9 then
                local dx, dy = pJ.x - pI.x, pJ.y - pI.y
                local sPar = (dx * dJ.y - dy * dJ.x) / den
                local uPar = (dx * dI.y - dy * dI.x) / den
                local hwI = (eI and rdI.widths[#rdI.widths] or rdI.widths[1]) / 2.0
                local hwJ = (eJ and rdJ.widths[#rdJ.widths] or rdJ.widths[1]) / 2.0
                local reach = HAIRPIN_MAX_EXTEND_RATIO * math.max(hwI, hwJ)
                if sPar > 0.0 and sPar <= reach and uPar > 0.0 and uPar <= reach then
                  local ix = pI.x + dI.x * sPar
                  local iy = pI.y + dI.y * sPar

                  local function extend(rd, atEnd, hw)
                    local src = atEnd and rd.points[#rd.points] or rd.points[1]
                    local node = vec3(ix, iy, src.z)
                    if atEnd then
                      rd.points[#rd.points + 1] = node
                      rd.widths[#rd.widths + 1] = hw * 2.0
                    else
                      table.insert(rd.points, 1, node)
                      table.insert(rd.widths, 1, hw * 2.0)
                    end
                  end
                  extend(rdI, eI, hwI)
                  extend(rdJ, eJ, hwJ)

                  local lenI = polylineLength(rdI.points)
                  local lenJ = polylineLength(rdJ.points)
                  local keep, keepE, drop, dropE
                  if lenI >= lenJ then
                    keep, keepE, drop, dropE = rdI, eI, rdJ, eJ
                  else
                    keep, keepE, drop, dropE = rdJ, eJ, rdI, eI
                  end
                  if keepE then keep.noCapEnd = false else keep.noCapStart = false end
                  if dropE then drop.noCapEnd = true else drop.noCapStart = true end

                  done[key(rdI, eI)] = true
                  done[key(rdJ, eJ)] = true
                  pairs_[#pairs_ + 1] = {rdI, eI, rdJ, eJ, vec3(ix, iy, 0)}
                  handled = handled + 1
                  break
                end
              end
            end
          end
        end
      end
    end
  end
  return handled, pairs_
end

local function mergeJunctions(roads)
  local prepared = {}
  for _, rd in ipairs(roads) do
    if #rd.points >= 2 then
      prepared[#prepared + 1] = {pts = rd.points, ws = rd.widths, src = rd}
    end
  end
  if #prepared < 2 then return roads end

  local endpoints = {}
  for i, p in ipairs(prepared) do
    endpoints[#endpoints + 1] = {road = i, e = 0, pos = p.pts[1]}
    endpoints[#endpoints + 1] = {road = i, e = 1, pos = p.pts[#p.pts]}
  end

  local partner = {}
  for _, grp in ipairs(clusterEndpoints(endpoints, ZEBRA_JOIN_TOLERANCE)) do
    if #grp == 2 then
      local a, b = endpoints[grp[1]], endpoints[grp[2]]
      if not (a.road == b.road and a.e == b.e) then
        partner[keyOf(a.road, a.e)] = {b.road, b.e}
        partner[keyOf(b.road, b.e)] = {a.road, a.e}
      end
    end

  end
  if next(partner) == nil then return roads end

  local trims = {}
  for k, v in pairs(partner) do
    if not trims[k] then
      local r, e = k:match("^(%d+):(%d+)$")
      r, e = tonumber(r), tonumber(e)
      local r2, e2 = v[1], v[2]
      local ptsA, wsA = oriented(prepared[r], e)
      local ptsB, wsB = oriented(prepared[r2], e2)
      local rb, rw = {}, {}
      for i = #ptsB, 1, -1 do rb[#rb + 1] = ptsB[i]; rw[#rw + 1] = wsB[i] end
      local sol = solveJunction(ptsA, wsA, rb, rw)
      if sol then
        local flip = nil
        if sol.frame then
          local f = sol.frame
          flip = {inner = f.inner, nA = f.nB, nB = f.nA, wA = f.wB, wB = f.wA,
                  sign = -f.sign, zA = f.zB, zB = f.zA}
        end
        trims[k] = {t = sol.ta, scale = sol.scale, frame = sol.frame}
        trims[keyOf(r2, e2)] = {t = sol.tb, scale = sol.scale, frame = flip}
      else
        partner[k] = nil
        partner[keyOf(r2, e2)] = nil
      end
    end
  end
  if next(partner) == nil then return roads end

  local out = {}
  for _, entry in ipairs(chainOrder(#prepared, partner)) do
    local chain, isCycle = entry.chain, entry.cycle
    if #chain == 1 and not isCycle then
      out[#out + 1] = prepared[chain[1].road].src
    else
      local segs = {}
      for _, node in ipairs(chain) do
        local p = prepared[node.road]
        local pts, ws = {}, {}
        if node.rev then
          for i = #p.pts, 1, -1 do pts[#pts + 1] = p.pts[i]; ws[#ws + 1] = p.ws[i] end
        else
          for i = 1, #p.pts do pts[i] = p.pts[i]; ws[i] = p.ws[i] end
        end
        local tin = trims[keyOf(node.road, node.rev and 1 or 0)]
        local tout = trims[keyOf(node.road, node.rev and 0 or 1)]
        pts, ws = trimFromStart(pts, ws, tin and tin.t or 0.0)
        pts, ws = trimFromEnd(pts, ws, tout and tout.t or 0.0)
        segs[#segs + 1] = {pts = pts, ws = ws, src = p.src,
                           scaleOut = tout and tout.scale or 1.0,
                           frameOut = tout and tout.frame or nil}
      end

      local outP, outW, outT = {}, {}, {}
      for i = 1, #segs[1].pts do
        outP[i] = segs[1].pts[i]; outW[i] = segs[1].ws[i]; outT[i] = false
      end
      local nJoin = isCycle and #segs or (#segs - 1)
      for k = 1, nJoin do
        local nxt = segs[(k % #segs) + 1]
        local pA, wA = outP[#outP], outW[#outW]
        local dA = dirAtEnd(outP, ZEBRA_FILLET_TANGENT_PROBE)
        local pB, wB = nxt.pts[1], nxt.ws[1]
        local rnxt = {}
        for i = #nxt.pts, 1, -1 do rnxt[#rnxt + 1] = nxt.pts[i] end
        local dB = dirAtEnd(rnxt, ZEBRA_FILLET_TANGENT_PROBE) * -1.0

        local fr = segs[k].frameOut
        local bridge
        if fr then
          bridge = fanCorner(fr.inner, fr.nA, fr.wA, fr.nB, fr.wB, fr.sign,
                             SMOOTH_SEGMENT_LEN, fr.zA, fr.zB)
        else
          bridge = filletBridge(pA, dA, wA, pB, dB, wB,
                                SMOOTH_SEGMENT_LEN, segs[k].scaleOut)
        end

        for j, b in ipairs(bridge) do
          local weld = (j == 1) and ZEBRA_SEAM_WELD or 1e-5
          if (b.p - outP[#outP]):length() > weld then
            outP[#outP + 1] = b.p
            outW[#outW + 1] = b.w
            outT[#outT + 1] = b.t or false
          else
            outW[#outW] = b.w
            if b.t then outT[#outT] = b.t end
          end
        end
        if k + 1 <= #segs then
          for j = 1, #nxt.pts do
            local weld = (j == 1) and ZEBRA_SEAM_WELD or 1e-5
            if (nxt.pts[j] - outP[#outP]):length() > weld then
              outP[#outP + 1] = nxt.pts[j]
              outW[#outW + 1] = nxt.ws[j]
              outT[#outT + 1] = false
            else
              outW[#outW] = nxt.ws[j]
            end
          end
        end
      end

      outP, outW, outT = weldShortSegments(outP, outW, outT, MIN_NODE_SPACING, isCycle)

      local base = segs[1].src
      local srcIds = {}
      for _, sg in ipairs(segs) do srcIds[#srcIds + 1] = sg.src.id end
      out[#out + 1] = {
        id = base.id, name = base.name, persistentId = base.persistentId,
        srcIds = srcIds,
        points = outP, widths = outW, sectionTangents = outT,
        closed = isCycle,
        curb = base.curb, walk = base.walk, profile = base.profile,
        overObjects = base.overObjects,
        merged = #segs,
      }
    end
  end
  return out
end

local function capEllipseShrink(aOut, bOut, adv)
  return function(sv)
    local aS, bS = aOut - sv, bOut - sv
    if aS <= 1e-6 or bS <= 0.0 or adv >= aS then return 0.0 end
    local r = adv / aS
    return bS * math.sqrt(math.max(0.0, 1.0 - r * r))
  end
end

local function addRoundedEnds(points, tangents, dists, widths, closed,
                              noCapStart, noCapEnd)
  local n = #points
  local caps = {}
  for i = 1, n do caps[i] = false end
  if closed or not ROUND_OPEN_ENDS or n < 2 then
    return points, tangents, dists, widths, caps
  end

  local function fan(idx, direction)
    local w0 = widths[idx]
    local hw = w0 / 2.0
    if hw <= 1e-6 then return {} end
    if ROUND_END_MAX_WIDTH and w0 >= ROUND_END_MAX_WIDTH then return {} end

    local tip = math.max(ROUND_END_TIP_WIDTH, 2.0 * CURB_STRIP + 0.01)
    tip = math.max(1e-4, math.min(tip, w0 * 0.9))
    local thetaMax = math.acos(clamp(tip / w0, -1.0, 1.0))
    local steps = math.max(1, math.ceil(math.deg(thetaMax)
                                        / math.max(0.5, ROUND_END_MAX_TURN_DEG)))

    local aOut = hw * ROUND_END_RADIUS_SCALE
    local bOut = hw
    local aIn = aOut - CURB_STRIP
    local bIn = bOut - CURB_STRIP

    local thetas = {}
    for k = 1, steps do thetas[#thetas + 1] = thetaMax * k / steps end
    if aIn > 0.0 and aIn < aOut then
      local thClose = math.asin(clamp(aIn / aOut, -1.0, 1.0))
      if thClose > 1e-4 and thClose < thetaMax - 1e-4 then
        thetas[#thetas + 1] = thClose

        local seen, uniq = {}, {}
        for _, x in ipairs(thetas) do
          local r = math.floor(x * 1e9 + 0.5) / 1e9
          if not seen[r] then seen[r] = true; uniq[#uniq + 1] = r end
        end
        table.sort(uniq)
        thetas = uniq
      end
    end

    local minStep = math.max(2e-3, 0.01 * hw)
    local keep = {}
    local pAdv, pHalf = 0.0, hw
    for _, th in ipairs(thetas) do
      local adv, half = aOut * math.sin(th), bOut * math.cos(th)
      local dx, dy = adv - pAdv, half - pHalf
      if math.sqrt(dx * dx + dy * dy) >= minStep then
        keep[#keep + 1] = th
        pAdv, pHalf = adv, half
      end
    end
    if #thetas > 0 and (#keep == 0 or keep[#keep] ~= thetas[#thetas]) then
      if #keep > 0 then keep[#keep] = thetas[#thetas] else keep = {thetas[#thetas]} end
    end
    thetas = keep

    local tan = tangents[idx]
    local out = {}
    local arc = 0.0
    local prevAdv, prevHalf = 0.0, hw
    for _, th in ipairs(thetas) do
      local adv = aOut * math.sin(th)
      local half = bOut * math.cos(th)

      local inset = 0.0
      if aIn > 1e-6 and bIn > 0.0 and adv < aIn then
        local r = adv / aIn
        inset = bIn * math.sqrt(math.max(0.0, 1.0 - r * r))
      end
      inset = math.min(half * 0.999, math.max(inset, half * 0.005))

      local dx, dy = adv - prevAdv, half - prevHalf
      arc = arc + math.sqrt(dx * dx + dy * dy)
      prevAdv, prevHalf = adv, half

      out[#out + 1] = {
        p = points[idx] + tan * (direction * adv),
        t = tan,
        d = dists[idx] + direction * adv,
        w = 2.0 * half,
        cap = {inset = inset, uvHw = hw,
               uvS = dists[idx] + direction * arc,
               shrink = capEllipseShrink(aOut, bOut, adv)},
      }
    end
    return out
  end

  local head = {}
  if not noCapStart then
    local f = fan(1, -1)
    for i = #f, 1, -1 do head[#head + 1] = f[i] end
  end
  local tail = noCapEnd and {} or fan(n, 1)
  if #head == 0 and #tail == 0 then
    return points, tangents, dists, widths, caps
  end

  local op, ot, od, ow, oc = {}, {}, {}, {}, {}
  local function push(p, t, d, w, c)
    op[#op + 1] = p; ot[#ot + 1] = t; od[#od + 1] = d; ow[#ow + 1] = w
    oc[#oc + 1] = c
  end
  for _, r in ipairs(head) do push(r.p, r.t, r.d, r.w, r.cap) end
  for i = 1, n do push(points[i], tangents[i], dists[i], widths[i], false) end
  for _, r in ipairs(tail) do push(r.p, r.t, r.d, r.w, r.cap) end
  return op, ot, od, ow, oc
end

local function newSubmesh(material)
  return {verts = {}, faces = {}, normals = {}, uvs = {}, material = material,
          _nv = 0, _nn = 0, _nu = 0}
end

local function pushVert(sm, p)
  sm.verts[sm._nv + 1] = {x = p.x, y = p.y, z = p.z}
  sm._nv = sm._nv + 1
  return sm._nv - 1
end

local function pushNormal(sm, n)
  sm.normals[sm._nn + 1] = {x = n.x, y = n.y, z = n.z}
  sm._nn = sm._nn + 1
  return sm._nn - 1
end

local UV_FLIP_V = true

local function pushUV(sm, u, v)
  if UV_FLIP_V then v = 1.0 - v end
  sm.uvs[sm._nu + 1] = {u = u, v = v}
  sm._nu = sm._nu + 1
  return sm._nu - 1
end

local function pushTri(sm, a, b, c, n, ua, ub, uc)
  local f = sm.faces
  f[#f + 1] = {v = a, n = n, u = ua}
  f[#f + 1] = {v = b, n = n, u = ub}
  f[#f + 1] = {v = c, n = n, u = uc}
end

local function windingNormal(vs)
  local n = vec3(0, 0, 0)
  local m = #vs
  for i = 1, m do
    local a, b = vs[i], vs[(i % m) + 1]
    n = n + a:cross(b)
  end
  return n
end

local faceDiag = {chamferDown = 0, chamferSkipped = 0}

local function emitFace(sm, vs, uvs, want, tag)
  local m = #vs
  if m < 3 then return end
  local n = windingNormal(vs)
  if n:length() < 1e-9 then return end
  if want and (n:dot(want) * FACE_WANT_SIGN) < 0 then
    local rv, ru = {}, {}
    for i = m, 1, -1 do
      rv[#rv + 1] = vs[i]
      ru[#ru + 1] = uvs[i]
    end
    vs, uvs = rv, ru
    n = n * -1
  end
  local shade = n:normalized() * FACE_WANT_SIGN
  if tag == "chamfer" and shade.z < -0.05 then
    faceDiag.chamferDown = faceDiag.chamferDown + 1
  end
  local nIdx = pushNormal(sm, shade)
  local vi, ui = {}, {}
  for i = 1, m do
    vi[i] = pushVert(sm, vs[i])
    ui[i] = pushUV(sm, uvs[i][1], uvs[i][2])
  end
  for i = 2, m - 1 do
    pushTri(sm, vi[1], vi[i], vi[i + 1], nIdx, ui[1], ui[i], ui[i + 1])
  end
end

local function pushQuad(sm, pA1, pA2, pB2, pB1, uvA1, uvA2, uvB2, uvB1, want, tag)
  if mrState.orient then
    emitFace(sm, {pA1, pA2, pB2, pB1}, {uvA1, uvA2, uvB2, uvB1},
             want or vec3(0, 0, 1), tag)
    return
  end
  local e1 = pA2 - pA1
  local e2 = pB1 - pA1
  local n = e1:cross(e2)
  if n:length() < 1e-9 then return end
  n = n:normalized()
  if n.z < 0 then n = n * -1 end

  local nIdx = pushNormal(sm, n)
  local i1 = pushVert(sm, pA1)
  local i2 = pushVert(sm, pA2)
  local i3 = pushVert(sm, pB2)
  local i4 = pushVert(sm, pB1)
  local t1 = pushUV(sm, uvA1[1], uvA1[2])
  local t2 = pushUV(sm, uvA2[1], uvA2[2])
  local t3 = pushUV(sm, uvB2[1], uvB2[2])
  local t4 = pushUV(sm, uvB1[1], uvB1[2])

  pushTri(sm, i1, i2, i3, nIdx, t1, t2, t3)
  pushTri(sm, i1, i3, i4, nIdx, t1, t3, t4)
end

local function pushWall(sm, pA1, pA2, pB2, pB1, uvA1, uvA2, uvB2, uvB1, outward)
  if mrState.orient then
    emitFace(sm, {pA1, pA2, pB2, pB1}, {uvA1, uvA2, uvB2, uvB1}, outward)
    return
  end
  local e1 = pA2 - pA1
  local e2 = pB1 - pA1
  local n = e1:cross(e2)
  if n:length() < 1e-9 then return end
  n = n:normalized()
  if outward and n:dot(outward) < 0 then n = n * -1 end

  local nIdx = pushNormal(sm, n)
  local i1 = pushVert(sm, pA1)
  local i2 = pushVert(sm, pA2)
  local i3 = pushVert(sm, pB2)
  local i4 = pushVert(sm, pB1)
  local t1 = pushUV(sm, uvA1[1], uvA1[2])
  local t2 = pushUV(sm, uvA2[1], uvA2[2])
  local t3 = pushUV(sm, uvB2[1], uvB2[2])
  local t4 = pushUV(sm, uvB1[1], uvB1[2])

  pushTri(sm, i1, i2, i3, nIdx, t1, t2, t3)
  pushTri(sm, i1, i3, i4, nIdx, t1, t3, t4)
end

function mr.pushPolyOriented(sm, vs, uvs, want)
  emitFace(sm, vs, uvs, want)
end

function mr.capCurbUV(localX, htLocal, zLocal)
  local depth = math.max(0.0, htLocal - zLocal)
  local atlas = curbAtlas()
  local _, sv = matScale(curbMaterialName())
  local sc = (atlas and atlas.uScale) or sv
  return {localX / sc + 0.5, curbFaceV(depth)}
end

function mr.capWalkUV(edgeDist, sign, localX, htLocal, zLocal)
  local wrap = edgeDist + sign * (htLocal - zLocal)
  local su, sv = matScale(walkMaterialName())
  return {localX / su + 0.5, wrap / sv + 0.5}
end

function mr.isClosedLoop(points)
  return #points >= 3 and (points[1] - points[#points]):length() < CLOSE_LOOP_TOLERANCE
end

function mr.prepareMeshRoad(spl)
  local note = {}
  local raw, rawW, rawH = spl.points, spl.widths, spl.depths
  local closed = mr.isClosedLoop(raw)

  local p, w, h = {}, {}, {}
  local last = closed and (#raw - 1) or #raw
  for i = 1, last do
    p[i] = raw[i]
    w[i] = rawW[i]
    h[i] = rawH and rawH[i] or HEIGHT
  end
  if #p < 2 then return nil end

  mrState.up, mrState.turnScale, mrState.mitres = nil, 1.0, nil
  local ups = spl.ups
  local tilted = false
  if ups then
    for _, u in ipairs(ups) do
      if math.sqrt(u.x * u.x + u.y * u.y) > 1e-6 then tilted = true break end
    end
  end
  if MR.MESHROAD_ROLL and spl.roll and tilted then
    local nodeD = {0.0}
    for k = 2, #raw do
      local a, b = raw[k - 1], raw[k]
      nodeD[k] = nodeD[k - 1] + math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
    end
    mrState.up = function(s) return mr.upAt(ups, nodeD, s) end
    local lever, hw0 = 0.0, (rawW[1] or 2.0) / 2.0
    for k, u in ipairs(ups) do
      local hw = (rawW[k] or rawW[1] or 2.0) / 2.0
      local dep = (rawH and rawH[k]) or 0.0
      local lv = hw + math.abs(dep) * math.sqrt(u.x * u.x + u.y * u.y)
      if lv > lever then lever = lv end
    end
    mrState.turnScale = (lever > 1e-6) and clamp(hw0 / lever, 0.12, 1.0) or 1.0
    note.roll = true
  end

  local spacing = MR.MESHROAD_SMOOTH_CORNERS and MR.MESHROAD_SMOOTH_SEGMENT_LENGTH or 0.0
  local turn = MR.MESHROAD_SMOOTH_MAX_TURN_DEG

  if MR.MESHROAD_MIN_RADIUS_MARGIN > 0 and not closed then
    local disp, iters, ratio, at
    p, w, h, disp, iters, ratio, at = mr.relaxForSweptPath(p, w, h, spacing, turn)
    note.relaxDisp, note.relaxIters = disp, iters
    note.sweptRatio, note.sweptAt = ratio, at
  end

  if MR.MESHROAD_SMOOTH_CORNERS then
    if MR.MESHROAD_SHARP_CORNERS then
      local nSharp, runaway, mitres
      p, w, h, nSharp, runaway, mitres = mr.sharpenUnroundableCorners(
        p, w, h, MR.MESHROAD_SMOOTH_SEGMENT_LENGTH, turn, MR.MESHROAD_SHARP_RATIO)
      note.sharp, note.sharpRunaway = nSharp, runaway
      mrState.mitres = mitres
    end
    p, w, h = smoothPathWithWidths(p, w, MR.MESHROAD_SMOOTH_SEGMENT_LENGTH, h, turn)
    p, w, h = mr.dedupe(p, w, h)
    if MR.MESHROAD_MITRE_STRIP and mrState.mitres then
      local nStrip
      p, w, h, nStrip = mr.stripMitreTail(p, w, h, mrState.mitres)
      note.mitreStripped = nStrip
    end
  end

  local before = #p
  p, w, h = mr.applySimplify(p, w, h, nil)
  note.simplified = before - #p

  if MR.MESHROAD_WIDTH_CLAMP and not closed then
    local narrowed
    w, narrowed = mr.clampWidthsToRadius(p, w, closed)
    note.narrowed = narrowed
  end

  local tangents = mr.computeTangents(p)
  local dists = mr.cumulativeDistances(p)

  if MR.FOLD_GUARD and #p > 2 then
    local offsets = {}
    for i = 1, #p do offsets[i] = w[i] / 2.0 end
    local forced = nil
    local sec = mrState.sectionTangents
    if sec and #sec == #p then
      forced = {}
      for i = 1, #p do forced[i] = (sec[i] ~= nil) end
    end
    if MR.MESHROAD_FORCE_MITRE_RINGS and mrState.mitres and #mrState.mitres > 0 then
      if not forced then
        forced = {}
        for i = 1, #p do forced[i] = false end
      end
      for k = 1, #mrState.mitres do
        local mp = mrState.mitres[k][1]
        local best, bestD = nil, MR.MESHROAD_MITRE_MATCH_DIST
        for i = 1, #p do
          local dx, dy = p[i].x - mp.x, p[i].y - mp.y
          local d = math.sqrt(dx * dx + dy * dy)
          if d < bestD then best, bestD = i, d end
        end
        if best then forced[best] = true end
      end
    end
    local keep = mr.nonFoldingKeep(p, tangents, offsets, closed, forced,
                                MR.MESHROAD_MIN_EDGE_ADVANCE_FRAC)
    if #keep > 2 and #keep < #p then
      note.foldDropped = #p - #keep
      local np, nw, nh, nt, nd = {}, {}, {}, {}, {}
      for k, i in ipairs(keep) do
        np[k], nw[k], nh[k], nt[k], nd[k] = p[i], w[i], h[i], tangents[i], dists[i]
      end
      p, w, h, tangents, dists = np, nw, nh, nt, nd
    end
  end

  return p, w, h, tangents, dists, closed, note
end

local function buildRoadMesh(spl)
  local pts, ws = spl.points, spl.widths
  if #pts < 2 then return nil end

  local isMesh = (spl.source == "meshroad")
  local path, pathW, pathH, tangents, dists, isClosed, caps, note

  if isMesh then
    path, pathW, pathH, tangents, dists, isClosed, note = mr.prepareMeshRoad(spl)
    if not path or #path < 2 then return nil end
    caps = {}
    for i = 1, #path do caps[i] = false end
  else
    mrState.up, mrState.turnScale = nil, 1.0
    local sp, spW = smoothPathWithWidths(pts, ws, SMOOTH_SEGMENT_LEN)
    path, pathW = sp, spW
    if #path < 2 then return nil end

    isClosed = spl.closed
    if isClosed == nil then
      isClosed = #path >= 3
               and (path[1] - path[#path]):length() < CLOSE_LOOP_TOLERANCE
    end

    local np = #path
    local secT = nil
    if spl.sectionTangents then
      secT = resampleSectionTangents(pts, spl.sectionTangents, SMOOTH_SEGMENT_LEN)
      if secT and #secT ~= np then secT = nil end
    end

    tangents, dists = {}, {}
    local acc = 0.0
    for i = 1, np do
      local tn
      if isClosed then
        tn = path[(i % np) + 1] - path[((i - 2) % np) + 1]
      elseif i == 1 then tn = path[2] - path[1]
      elseif i == np then tn = path[np] - path[np - 1]
      else tn = path[i + 1] - path[i - 1] end
      tn = vec3(tn.x, tn.y, 0)
      if tn:length() < 1e-9 then tn = vec3(1, 0, 0) end
      tangents[i] = (secT and secT[i]) or tn:normalized()
      if i > 1 then acc = acc + (path[i] - path[i - 1]):length() end
      dists[i] = acc
    end

    if spl.roundEnds ~= false then
      path, tangents, dists, pathW, caps =
        addRoundedEnds(path, tangents, dists, pathW, isClosed,
                       spl.noCapStart, spl.noCapEnd)
    else
      caps = {}
      for i = 1, np do caps[i] = false end
    end
    pathH = {}
    for i = 1, #path do pathH[i] = HEIGHT end
  end

  local np = #path

  local bodyW = {}
  for i = 1, np do
    if not caps[i] then bodyW[#bodyW + 1] = pathW[i] end
  end
  if #bodyW == 0 then for i = 1, np do bodyW[i] = pathW[i] end end
  table.sort(bodyW)
  local uvHw = bodyW[math.floor(#bodyW / 2) + 1] / 2.0

  local prof = spl.profile or "walk"
  local overObjects = spl.overObjects and true or false
  local keepBottom = isMesh and (spl.bottom == true)
  faceDiag.chamferDown, faceDiag.chamferSkipped = 0, 0
  local uvRef = (isMesh or MR.UVX_FROM_MEDIAN_DECAL) and uvHw or nil

  local miter = nil
  if isMesh then miter = mr.miterScales(path, tangents, isClosed, nil) end

  local walkFracs, walkBands = nil, 1
  if isMesh and MR.MESHROAD_WALK_SPLIT and np >= 3 then
    local spans = {}
    for i = 1, np do
      local j = isClosed and ((i % np) + 1) or math.min(i + 1, np)
      if j ~= i then
        spans[i] = {mr.spanGeometry(path, tangents, pathW, i, j)}
      else
        spans[i] = {0.0, 0.0, 0.0, 0.0}
      end
    end
    if not isClosed and np >= 2 then spans[np] = spans[np - 1] end
    local worst, worstAt = 0.0, 1
    for i = 1, np do
      local f = mr.spanFoldDeg(spans[i][1], spans[i][2], spans[i][3])
      if f > worst then worst, worstAt = f, i end
    end
    if worst > MR.WALK_SPLIT_TARGET_FOLD_DEG then
      walkBands = math.min(MR.WALK_SPLIT_MAX,
                           math.ceil(worst / MR.WALK_SPLIT_TARGET_FOLD_DEG))
      local s = spans[worstAt]
      walkFracs = mr.walkSplitFracs(walkBands, s[1], s[2], s[3], s[4])
      if note then note.walkBands, note.walkFold = walkBands, worst end
    end
  end

  local cols0 = sectionLayout(pathW[1], prof, caps[1] and caps[1].inset or nil,
                              caps[1] and caps[1].shrink or nil,
                              pathH[1], uvRef, walkFracs)
  local nc = #cols0

  local walkMat = walkMaterialName()
  local curbMat = curbMaterialName()
  if not curbMat then return nil, "curb.material is not set in the styles config" end

  local smWalk = newSubmesh(walkMat or curbMat)
  local smCurb = newSubmesh(curbMat)

  local stations = {}
  for i = 1, np do
    local p = path[i]
    local tn = tangents[i]
    local m = miter and miter[i] or 1.0
    local side = vec3(-tn.y, tn.x, 0) * m
    local downDir = vec3(0, 0, -1)

    if isMesh and mrState.up then
      local upw = mrState.up(dists[i])
      local tan3 = mr.tangent3d(path, i, isClosed)
      local u = upw - tan3 * upw:dot(tan3)
      if u:length() > 1e-6 then
        u = u:normalized()
        local sd = u:cross(tan3)
        if sd:length() > 1e-9 then
          side = sd:normalized()
          downDir = u * -1.0
        end
      end
    end

    local c = caps[i]
    local hgt = pathH[i]
    local cols, hw, chamfer = sectionLayout(pathW[i], prof,
                                            c and c.inset or nil,
                                            c and c.shrink or nil,
                                            hgt, uvRef, walkFracs)
    if #cols ~= nc then
      cols, hw, chamfer = sectionLayout(pathW[i], prof, nil, nil,
                                        hgt, uvRef, walkFracs)
    end

    local top, bot = {}, {}
    for k = 1, nc do
      if isMesh then
        local q = p + side * cols[k].x
        local lift = vec3(0, 0, Z_OFFSET)
        top[k] = q + lift + downDir * cols[k].drop
        if cols[k].bottom or keepBottom then
          bot[k] = q + lift + downDir * hgt
        end
      else
        local q = p + side * cols[k].x
        local ground = overObjects and p.z or terrainZ(q.x, q.y, p.z)
        local base = ground + Z_OFFSET + DECAL_HEIGHT_OFFSET
        top[k] = vec3(q.x, q.y, base - cols[k].drop)
        if cols[k].bottom then bot[k] = vec3(q.x, q.y, base - hgt) end
      end
    end

    local uvS = (c and c.uvS) or dists[i]
    stations[i] = {top = top, bot = bot, s = uvS, side = side, down = downDir,
                   cols = cols, hw = hw, chamfer = chamfer, height = hgt}
  end

  local segCount = isClosed and np or (np - 1)
  local wrapS = isClosed
              and (stations[np].s + (path[1] - path[np]):length()) or 0.0

  for i = 1, segCount do
    local A, B = stations[i], stations[(i % np) + 1]
    local sA = A.s
    local sB = (i == np) and wrapS or B.s
    for c = 1, nc - 1 do
      local kind = A.cols[c].kind or "curbtop"
      local sm = (kind == "walk") and smWalk or smCurb
      local xa, xb = A.cols[c].x, A.cols[c + 1].x
      local xa2, xb2 = B.cols[c].x, B.cols[c + 1].x

      local uvA1, uvA2, uvB2, uvB1
      if kind == "walk" then
        local ua1, va1 = walkUV(xa, sA)
        local ua2, va2 = walkUV(xb, sA)
        local ub2, vb2 = walkUV(xb2, sB)
        local ub1, vb1 = walkUV(xa2, sB)
        uvA1, uvA2, uvB2, uvB1 = {ua1, va1}, {ua2, va2}, {ub2, vb2}, {ub1, vb1}
      elseif kind == "chamfer" then
        local da, db = A.cols[c].drop, A.cols[c + 1].drop
        uvA1 = {curbU(sA), curbFaceV(da)}
        uvA2 = {curbU(sA), curbFaceV(db)}
        uvB2 = {curbU(sB), curbFaceV(db)}
        uvB1 = {curbU(sB), curbFaceV(da)}
      else
        local ua, ub = A.cols[c].uvx, A.cols[c + 1].uvx
        local ua2c, ub2c = B.cols[c].uvx, B.cols[c + 1].uvx
        local wa = CURB_STRIP - (uvHw - math.abs(ua))
        local wb = CURB_STRIP - (uvHw - math.abs(ub))
        local wa2 = CURB_STRIP - (uvHw - math.abs(ua2c))
        local wb2 = CURB_STRIP - (uvHw - math.abs(ub2c))
        uvA1 = {curbU(sA), curbTopV(wa)}
        uvA2 = {curbU(sA), curbTopV(wb)}
        uvB2 = {curbU(sB), curbTopV(wb2)}
        uvB1 = {curbU(sB), curbTopV(wa2)}
      end

      local want
      if isMesh then
        local up = A.down * -1
        if kind == "chamfer" then
          local mid = (A.cols[c].x + A.cols[c + 1].x) * 0.5
          local outv = A.side:normalized() * ((mid < 0) and -1.0 or 1.0)
          want = (outv + up):normalized()
        else
          want = up
        end
      end

      pushQuad(sm, A.top[c], A.top[c + 1], B.top[c + 1], B.top[c],
               uvA1, uvA2, uvB2, uvB1, want, kind)
    end
  end

  for i = 1, segCount do
    local A, B = stations[i], stations[(i % np) + 1]
    local sA = A.s
    local sB = (i == np) and wrapS or B.s
    for _, c in ipairs({1, nc}) do
      if A.bot[c] and B.bot[c] then
        local outward = A.side * ((c == 1) and -1 or 1)
        pushWall(smCurb, A.top[c], A.bot[c], B.bot[c], B.top[c],
                 {curbU(sA), curbFaceV(A.chamfer)},
                 {curbU(sA), curbFaceV(A.height)},
                 {curbU(sB), curbFaceV(B.height)},
                 {curbU(sB), curbFaceV(B.chamfer)},
                 outward)
      end
    end
  end

  if keepBottom then
    for i = 1, segCount do
      local A, B = stations[i], stations[(i % np) + 1]
      local sA = A.s
      local sB = (i == np) and wrapS or B.s
      for c = 1, nc - 1 do
        if A.bot[c] and A.bot[c + 1] and B.bot[c] and B.bot[c + 1] then
          local ua1, va1 = curbBottomUV(A.cols[c].uvx, sA)
          local ua2, va2 = curbBottomUV(A.cols[c + 1].uvx, sA)
          local ub2, vb2 = curbBottomUV(B.cols[c + 1].uvx, sB)
          local ub1, vb1 = curbBottomUV(B.cols[c].uvx, sB)
          pushQuad(smCurb, A.bot[c], A.bot[c + 1], B.bot[c + 1], B.bot[c],
                   {ua1, va1}, {ua2, va2}, {ub2, vb2}, {ub1, vb1}, A.down)
        end
      end
    end
  end

  if isMesh and MR.MESHROAD_END_CAPS and not isClosed then
    local roleIdx = {}
    for k = 1, nc do
      if cols0[k].role then roleIdx[cols0[k].role] = k end
    end
    local defs = {
      {"outer_near", "inner_near", true},
      {"inner_near", "inner_far", false},
      {"inner_far", "outer_far", true},
    }
    for _, endSpec in ipairs({{1, -1.0}, {np, 1.0}}) do
      local idx, sign = endSpec[1], endSpec[2]
      local st = stations[idx]
      local edgeDist = st.s
      local hgt = st.height
      local hasCh = st.chamfer > 1e-6
      local want = tangents[idx] * sign
      for _, d in ipairs(defs) do
        local roleA, roleB, outerSide = d[1], d[2], d[3]
        local sm = outerSide and smCurb or smWalk
        local outerRole = (roleA == "outer_near" or roleA == "outer_far") and roleA or roleB
        local ring
        if hasCh and outerSide and roleIdx[outerRole .. "_chamfer"] then
          local ch = outerRole .. "_chamfer"
          if roleA == outerRole then
            ring = {{roleB, -hgt}, {roleB, 0.0}, {ch, 0.0},
                    {roleA, -st.chamfer}, {roleA, -hgt}}
          else
            ring = {{roleB, -hgt}, {roleB, -st.chamfer}, {ch, 0.0},
                    {roleA, 0.0}, {roleA, -hgt}}
          end
        else
          if sign < 0 then
            ring = {{roleB, -hgt}, {roleB, 0.0}, {roleA, 0.0}, {roleA, -hgt}}
          else
            ring = {{roleA, -hgt}, {roleA, 0.0}, {roleB, 0.0}, {roleB, -hgt}}
          end
        end
        if #ring == 5 and sign < 0 then
          local r = {}
          for k = #ring, 1, -1 do r[#r + 1] = ring[k] end
          ring = r
        end
        local vs, uvs, okRing = {}, {}, true
        for _, e in ipairs(ring) do
          local ci = roleIdx[e[1]]
          local v = ci and ((e[2] == -hgt) and st.bot[ci] or st.top[ci]) or nil
          if not v then okRing = false break end
          vs[#vs + 1] = v
          local lx = outerSide and st.cols[ci].uvx or st.cols[ci].x
          uvs[#uvs + 1] = outerSide and mr.capCurbUV(lx, 0.0, e[2])
                                     or mr.capWalkUV(edgeDist, sign, lx, 0.0, e[2])
        end
        if okRing then mr.pushPolyOriented(sm, vs, uvs, want) end
      end
    end
  end

  if note then note.chamferDown = faceDiag.chamferDown end

  local out = {}
  if #smCurb.faces > 0 then out[#out + 1] = smCurb end
  if #smWalk.faces > 0 then out[#out + 1] = smWalk end
  if #out == 0 then return nil end
  return out, nil, note
end

local function fieldPrefix()
  return (styleCfg and styleCfg.fieldPrefix) or "pit_"
end

local function axisField(axis)
  local axes = styleCfg and styleCfg.axes
  local a = type(axes) == "table" and axes[axis] or nil
  local name = type(a) == "table" and a.field or nil
  if type(name) == "string" and name ~= "" then return name end
  return fieldPrefix() .. axis
end

local function dynValue(obj, fieldName)
  if obj and obj.getDynDataFieldbyName then
    local ok, v = pcall(obj.getDynDataFieldbyName, obj, fieldName, 0)
    if ok and v ~= nil and v ~= "" then return tostring(v) end
  end
  return nil
end

local function objField(obj, name)
  if obj and obj.getField then
    local ok, v = pcall(obj.getField, obj, name, 0)
    if ok and v ~= nil and v ~= "" then return tostring(v) end
  end
  return nil
end

local MARKER_MATERIAL = "WarningMaterial"

function mr.meshRoadIsTextured(obj)
  for _, key in ipairs(MR.MESHROAD_MATERIAL_KEYS) do
    local v = objField(obj, key)
    if v and v ~= MARKER_MATERIAL then return true end
  end
  return false
end

function mr.flagValue(v)
  if v == nil then return nil end
  local t = tostring(v):lower()
  if t == "on" or t == "true" or t == "1" or t == "yes" then return true end
  if t == "off" or t == "false" or t == "0" or t == "no" then return false end
  return nil
end

local function readRoad(id)
  local obj = scenetree.findObjectById(id)
  if not obj then return nil end
  local cls = nil
  if obj.getClassName then
    local ok, c = pcall(obj.getClassName, obj)
    if ok then cls = c end
  end
  if cls ~= "DecalRoad" and cls ~= "MeshRoad" then return nil end
  local isMesh = (cls == "MeshRoad")

  if isMesh then
    if MR.MESHROAD_UNTEXTURED_ONLY and mr.meshRoadIsTextured(obj) then return nil end
  else
    if objField(obj, "material") ~= MARKER_MATERIAL then return nil end
  end
  if not obj.getNodeCount or not obj.getNodePosition then return nil end

  local okc, count = pcall(obj.getNodeCount, obj)
  if not okc or type(count) ~= "number" or count < 2 then return nil end

  local pts, ws, ds, ups = {}, {}, (isMesh and {} or nil), (isMesh and {} or nil)
  for i = 0, count - 1 do
    local okp, p = pcall(obj.getNodePosition, obj, i)
    if not okp or not p then return nil end
    local w = 2.0
    if obj.getNodeWidth then
      local okw, v = pcall(obj.getNodeWidth, obj, i)
      if okw and type(v) == "number" and v > 0 then w = v end
    end
    pts[#pts + 1] = vec3(p.x, p.y, p.z)
    ws[#ws + 1] = w
    if isMesh then
      local d = HEIGHT
      if obj.getNodeDepth then
        local okd, v = pcall(obj.getNodeDepth, obj, i)
        if okd and type(v) == "number" and v > 0 then d = v end
      end
      ds[#ds + 1] = d
      local u = vec3(0, 0, 1)
      if obj.getNodeNormal then
        local okn, v = pcall(obj.getNodeNormal, obj, i)
        if okn and v and v.x then
          local n = vec3(v.x, v.y, v.z)
          if n:length() > 1e-6 then u = n:normalized() end
        end
      end
      ups[#ups + 1] = u
    end
  end

  local over = objField(obj, "overObjects")

  local rollFlag, bottomFlag
  if isMesh then
    rollFlag = mr.flagValue(dynValue(obj, axisField("roll")))
    bottomFlag = mr.flagValue(dynValue(obj, axisField("bottom")))
  end

  local pid = objField(obj, "persistentId")
  if not pid and obj.getOrCreatePersistentID then
    local okp, v = pcall(obj.getOrCreatePersistentID, obj)
    if okp and v and v ~= "" then pid = tostring(v) end
  end
  return {
    id = id,
    persistentId = pid,
    name = (obj.getName and select(2, pcall(obj.getName, obj))) or tostring(id),
    source = isMesh and "meshroad" or "decalroad",
    points = pts,
    widths = ws,
    depths = ds,
    ups = ups,
    curb = dynValue(obj, axisField("curb")),
    walk = dynValue(obj, axisField("walk")),
    wall = isMesh and dynValue(obj, axisField("wall")) or nil,
    roll = rollFlag,
    bottom = bottomFlag,
    profile = dynValue(obj, axisField("profile")) or "walk",
    overObjects = (over == "1" or over == "true"),
  }
end

local function selectedIds()
  if editor and editor.selection and editor.selection.object then
    return editor.selection.object
  end
  return {}
end

local function buildIslandMesh(isl)
  local outer = {}
  for i, p in ipairs(isl.ring) do outer[i] = p end
  if signedArea2D(outer) < 0 then
    local r = {}
    for i = #outer, 1, -1 do r[#r + 1] = outer[i] end
    outer = r
  end
  local n = #outer
  if n < 3 then return nil end

  local prof = CURB_PROFILES[isl.profile] or CURB_PROFILES.island
  local slopeV = math.min(prof.exposed, HEIGHT)
  local slopeH = math.min(math.tan(math.rad(prof.angle)) * slopeV, CURB_STRIP * 0.9)

  local slopeRing = nil
  if slopeH > 1e-6 then
    local cand = fitInnerRing(outer, offsetPolygonInward(outer, slopeH), slopeH)
    local aOut, aIn = signedArea2D(outer), signedArea2D(cand)
    if #cand == n and aIn > 0.0 and aIn < aOut then
      slopeRing = cand
    else
      slopeH, slopeV = 0.0, 0.0
    end
  end

  local inner, innerTris, fillRing = nil, nil, nil
  if CURB_STRIP > 1e-6 then
    local cand = fitInnerRing(outer, offsetPolygonInward(outer, CURB_STRIP),
                              CURB_STRIP)
    local aOut, aIn = signedArea2D(outer), signedArea2D(cand)
    if aIn > ISLAND_MIN_AREA * 0.05 and aIn < aOut then

      local tris, used = triangulatePolygon(cand)
      inner = cand
      innerTris = tris
      fillRing = used
    end
  end

  local curbMat = curbMaterialName()
  if not curbMat then return nil, "curb.material is not set in the styles config" end
  local walkMat = walkMaterialName()
  local smCurb = newSubmesh(curbMat)
  local smWalk = newSubmesh(walkMat or curbMat)

  local overObjects = isl.overObjects and true or false
  local function mkz(p, drop)
    local ground = overObjects and p.z or terrainZ(p.x, p.y, p.z)
    return vec3(p.x, p.y, ground + Z_OFFSET + DECAL_HEIGHT_OFFSET - drop)
  end

  local topRing = slopeRing or outer
  local oBot, oTop, oMid = {}, {}, {}
  for i = 1, n do
    oBot[i] = mkz(outer[i], HEIGHT)
    oTop[i] = mkz(topRing[i], 0.0)
    oMid[i] = slopeRing and mkz(outer[i], slopeV) or oTop[i]
  end
  local iTop = {}
  if inner then
    for i = 1, n do iTop[i] = mkz(inner[i], 0.0) end
  end
  local fTop = {}
  if fillRing then
    for i = 1, #fillRing do fTop[i] = mkz(fillRing[i], 0.0) end
  end

  local perim = {0.0}
  for i = 2, n do
    perim[i] = perim[i - 1] + math.sqrt((outer[i].x - outer[i - 1].x) ^ 2
                                        + (outer[i].y - outer[i - 1].y) ^ 2)
  end
  local totalPerim = perim[n] + math.sqrt((outer[1].x - outer[n].x) ^ 2
                                          + (outer[1].y - outer[n].y) ^ 2)

  local flatW = CURB_STRIP - slopeH

  for i = 1, n do
    local j = (i % n) + 1
    local s0 = perim[i]
    local s1 = (j == 1) and totalPerim or perim[j]
    local outward = vec3(outer[j].y - outer[i].y, outer[i].x - outer[j].x, 0)

    pushWall(smCurb, oBot[i], oMid[i], oMid[j], oBot[j],
             {curbU(s0), curbFaceV(HEIGHT)},
             {curbU(s0), curbFaceV(slopeV)},
             {curbU(s1), curbFaceV(slopeV)},
             {curbU(s1), curbFaceV(HEIGHT)},
             outward)

    if slopeRing then
      pushWall(smCurb, oMid[i], oTop[i], oTop[j], oMid[j],
               {curbU(s0), curbFaceV(slopeV)},
               {curbU(s0), curbFaceV(0.0)},
               {curbU(s1), curbFaceV(0.0)},
               {curbU(s1), curbFaceV(slopeV)},
               outward)
    end

    if inner then
      pushQuad(smCurb, iTop[i], iTop[j], oTop[j], oTop[i],
               {curbU(s0), curbTopV(0.0)},
               {curbU(s1), curbTopV(0.0)},
               {curbU(s1), curbTopV(flatW)},
               {curbU(s0), curbTopV(flatW)})
    end
  end

  if inner and innerTris then
    local su, sv = matScale(walkMat)
    local function uvFill(p) return p.x / su + 0.5, p.y / sv + 0.5 end
    for _, t in ipairs(innerTris) do
      local a, b, c = t[1], t[2], t[3]

      a, b, c = a, c, b
      local pa, pb, pc = fTop[a], fTop[b], fTop[c]
      local nrm = (pb - pa):cross(pc - pa)
      if nrm:length() > 1e-9 then
        nrm = nrm:normalized()
        if nrm.z < 0 then nrm = nrm * -1 end

        local ni = pushNormal(smWalk, nrm)
        local i1 = pushVert(smWalk, pa)
        local i2 = pushVert(smWalk, pb)
        local i3 = pushVert(smWalk, pc)
        local ua, va = uvFill(fillRing[a])
        local ub, vb = uvFill(fillRing[b])
        local uc, vc = uvFill(fillRing[c])
        local t1 = pushUV(smWalk, ua, va)
        local t2 = pushUV(smWalk, ub, vb)
        local t3 = pushUV(smWalk, uc, vc)
        pushTri(smWalk, i1, i2, i3, ni, t1, t2, t3)
      end
    end
  end

  local out = {}
  if #smCurb.faces > 0 then out[#out + 1] = smCurb end
  if #smWalk.faces > 0 then out[#out + 1] = smWalk end
  if #out == 0 then return nil end
  return out
end

local function hideRoadOnce(id)
  if hiddenRoads[id] ~= nil then return end
  local obj = scenetree.findObjectById(id)
  if not obj then return end
  local was = (obj.hidden == true)
  hiddenRoads[id] = {was = was, set = true}
  pcall(function() obj.hidden = true end)
end

local function releaseRoadHidden(id)
  local rec = hiddenRoads[id]
  if not rec then return end
  local obj = scenetree.findObjectById(id)
  if obj then
    local cur = (obj.hidden == true)
    if cur == rec.set then
      pcall(function() obj.hidden = rec.was end)
    end
  end
  hiddenRoads[id] = nil
end

local function restoreHiddenRoads()
  for id, _ in pairs(hiddenRoads) do
    local rec = hiddenRoads[id]
    local obj = scenetree.findObjectById(id)
    if obj and rec then
      local cur = (obj.hidden == true)
      if cur == rec.set then
        pcall(function() obj.hidden = rec.was end)
      end
    end
  end
  hiddenRoads = {}
end

local function clearPreview()
  for _, m in pairs(previewMeshes) do
    if m and m.delete then pcall(function() m:delete() end) end
  end
  previewMeshes = {}
  restoreHiddenRoads()
  rendered = {}
  pendingSince, pendingSig = {}, {}
end

local function sweepOrphans()
  if not (scenetree and scenetree.findClassObjects) then return 0 end
  local ok, names = pcall(scenetree.findClassObjects, "ProceduralMesh")
  if not ok or type(names) ~= "table" then return 0 end
  local n = 0
  for _, nm in ipairs(names) do
    if type(nm) == "string" and nm:find(MESH_PREFIX, 1, true) and not previewMeshes[nm] then
      local o = scenetree.findObject(nm)
      if o then
        pcall(function() o:delete() end)
        n = n + 1
      end
    end
  end
  return n
end

local function roadSignature(road)
  local parts = {tostring(#road.points), tostring(road.source),
                 tostring(road.curb), tostring(road.walk),
                 tostring(road.wall), tostring(road.roll),
                 tostring(road.bottom),
                 tostring(road.profile), tostring(road.overObjects)}
  for i = 1, #road.points do
    local p = road.points[i]
    local u = road.ups and road.ups[i]
    parts[#parts + 1] = string.format("%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f",
                                      p.x, p.y, p.z, road.widths[i] or 0,
                                      road.depths and road.depths[i] or 0,
                                      u and u.x or 0, u and u.y or 0)
  end
  return table.concat(parts, "|")
end

local function removeMeshFor(id)
  local key = "_" .. tostring(id)
  for name, m in pairs(previewMeshes) do
    if name:sub(-#key) == key then
      if m and m.delete then pcall(function() m:delete() end) end
      previewMeshes[name] = nil
    end
  end
end

local meshCtr = 0

local function buildOne(road)
  curbKey, walkKey = resolveStyle(road)
  mrState.curbMat, mrState.curbBand0 = nil, false
  mrState.orient = (road.source == "meshroad")
  if road.source == "meshroad" then
    mrState.curbMat = mr.meshroadCurbMaterial(road)
    mrState.curbBand0 = true
  end
  local meshes, err, note
  if road.isIsland then
    meshes, err = buildIslandMesh(road)
  else
    meshes, err, note = buildRoadMesh(road)
  end
  mrState.curbMat, mrState.curbBand0, mrState.orient = nil, false, false
  mrState.note = note or mrState.note
  if not meshes then return false, err end

  removeMeshFor(road.id)
  meshCtr = meshCtr + 1
  local name = MESH_PREFIX .. tostring(meshCtr) .. "_" .. tostring(road.id)
  local o = createObject('ProceduralMesh')
  o:setPosition(vec3(0, 0, 0))
  o.canSave = false
  o:registerObject(name)
  scenetree.MissionGroup:add(o.obj)
  o:createMesh({meshes})
  previewMeshes[name] = o
  for _, sid in ipairs(road.srcIds or {road.id}) do hideRoadOnce(sid) end
  return true
end

local function renderSelection()
  clearPreview()
  if not styleCfg then loadStyles() end
  if not styleCfg then
    lastStatus = tostring(styleErr)
    return lastStatus
  end

  local ids = selectedIds()
  if #ids == 0 then
    lastStatus = "nothing selected"
    return lastStatus
  end

  local roads, skipped = {}, 0
  for _, id in ipairs(ids) do
    local road = readRoad(id)
    if road then roads[#roads + 1] = road else skipped = skipped + 1 end
  end

  table.sort(roads, function(a, b)
    local ia, ib = tonumber(a.id), tonumber(b.id)
    if ia and ib and ia ~= ib then return ia < ib end
    return tostring(a.persistentId or a.name or a.id)
         < tostring(b.persistentId or b.name or b.id)
  end)

  rendered = {}
  pendingSince, pendingSig = {}, {}
  for _, rd in ipairs(roads) do rendered[rd.id] = roadSignature(rd) end

  local meshRoads, decals = {}, {}
  for _, rd in ipairs(roads) do
    if rd.source == "meshroad" then meshRoads[#meshRoads + 1] = rd
    else decals[#decals + 1] = rd end
  end

  local islands, rest = extractIslands(decals)

  local paths = mergeJunctions(rest)
  markJoinedEnds(paths)
  local hairpins, hairPairs = flushHairpinTips(paths)

  local unions = 0
  if HAIRPIN_UNION and hairPairs and #hairPairs > 0 then
    local consumed, made = {}, {}
    for _, pr in ipairs(hairPairs) do
      local rdI, eI, rdJ, eJ, tip = pr[1], pr[2], pr[3], pr[4], pr[5]
      local ring = hairpinUnionRing(rdI, eI, rdJ, eJ, tip)
      if ring then
        consumed[rdI] = true
        consumed[rdJ] = true
        local srcIds = {}
        for _, r in ipairs({rdI, rdJ}) do
          for _, sid in ipairs(r.srcIds or {r.id}) do srcIds[#srcIds + 1] = sid end
        end
        made[#made + 1] = {
          id = rdI.id, name = rdI.name, persistentId = rdI.persistentId,
          srcIds = srcIds, ring = ring,
          area = math.abs(signedArea2D(ring)), parts = 2,
          curb = rdI.curb, walk = rdI.walk, profile = rdI.profile,
          overObjects = rdI.overObjects or rdJ.overObjects,
          isIsland = true,
        }
        unions = unions + 1
      end
    end
    if unions > 0 then
      local kept = {}
      for _, r in ipairs(paths) do
        if not consumed[r] then kept[#kept + 1] = r end
      end
      for _, r in ipairs(made) do kept[#kept + 1] = r end
      paths = kept
    end
  end

  for _, isl in ipairs(islands) do paths[#paths + 1] = isl end
  for _, mr in ipairs(meshRoads) do paths[#paths + 1] = mr end

  local built, merges = 0, 0
  for _, road in ipairs(paths) do
    if road.merged and road.merged > 1 then merges = merges + 1 end
    local ok, err = buildOne(road)
    if ok then built = built + 1
    else skipped = skipped + 1
         if err then lastStatus = err end end
  end

  if built > LIVE_MAX_ROADS and liveEnabled then
    liveEnabled = false
    lastStatus = tr("rendered %d - auto refresh turned off above %d roads",
                    built, LIVE_MAX_ROADS)
  else
    local parts = {}
    parts[#parts + 1] = (built == 1) and tr("rendered 1 path")
                                      or tr("rendered %d paths", built)
    if #meshRoads > 0 then
      parts[#parts + 1] = tr("%d MeshRoad", #meshRoads)
    end
    if merges > 0 then
      parts[#parts + 1] = tr("%d merged at junctions", merges)
    end
    if #islands > 0 then
      parts[#parts + 1] = (#islands == 1) and tr("1 island")
                                           or tr("%d islands", #islands)
    end
    if hairpins > 0 then
      local filled = (unions > 0) and tr(" (%d filled)", unions) or ""
      parts[#parts + 1] = ((hairpins == 1) and tr("1 V-end joined")
                                            or tr("%d V-ends joined", hairpins)) .. filled
    end
    if skipped > 0 then
      parts[#parts + 1] = tr("%d skipped", skipped)
    end
    lastStatus = table.concat(parts, ", ")
  end
  log('I', logTag, lastStatus)
  return lastStatus
end

local function refreshLive()
  if not liveEnabled then return end
  if next(rendered) == nil then return end

  local count = 0
  for _ in pairs(rendered) do count = count + 1 end
  if count > LIVE_MAX_ROADS then
    liveEnabled = false
    lastStatus = "auto refresh turned off - too many roads rendered"
    return
  end

  local now = os.clock()
  local dirty, gone = false, false
  for id, sig in pairs(rendered) do
    local road = readRoad(id)
    if not road then
      gone = true
    else
      local cur = roadSignature(road)
      if cur ~= sig then
        if pendingSig[id] ~= cur then
          pendingSig[id] = cur
          pendingSince[id] = now
        elseif now - (pendingSince[id] or now) >= liveDelay then
          dirty = true
        end
      else
        pendingSince[id], pendingSig[id] = nil, nil
      end
    end
  end

  if gone or dirty then
    renderSelection()
  end
end

local function onEditorInspectorFieldChanged(selectedIds_, fieldName, fieldValue, arrayIndex)
  if not liveEnabled then return end
  if type(selectedIds_) ~= "table" then return end
  for _, id in ipairs(selectedIds_) do
    if rendered[id] ~= nil or fieldName == "material" then
      renderSelection()
      return
    end
  end
end

local function convertSelection()
  local ids = selectedIds()
  if #ids == 0 then return "nothing selected" end

  local changed, skipped = 0, 0
  if editor and editor.history and editor.history.beginTransaction then
    pcall(function() editor.history:beginTransaction("PitSidewalkConvert") end)
  end
  for _, id in ipairs(ids) do
    local obj = scenetree.findObjectById(id)
    local cls = nil
    if obj and obj.getClassName then
      local ok, c = pcall(obj.getClassName, obj)
      if ok then cls = c end
    end
    if cls == "DecalRoad" and objField(obj, "material") ~= MARKER_MATERIAL then
      pcall(function() obj:setField("material", 0, MARKER_MATERIAL) end)
      changed = changed + 1
    elseif cls == "MeshRoad" and mr.meshRoadIsTextured(obj) then
      for _, key in ipairs(MR.MESHROAD_MATERIAL_KEYS) do
        pcall(function() obj:setField(key, 0, MARKER_MATERIAL) end)
      end
      changed = changed + 1
    else
      skipped = skipped + 1
    end
  end
  if editor and editor.history and editor.history.endTransaction then
    pcall(function() editor.history:endTransaction() end)
  end
  if editor and editor.setDirty then pcall(editor.setDirty) end

  lastStatus = (changed == 1) and tr("converted 1 road, skipped %d", skipped)
                               or tr("converted %d roads, skipped %d", changed, skipped)
  log('I', logTag, lastStatus)
  return lastStatus
end

local function onEditorAfterOpenLevel()
  clearPreview()
  sweepOrphans()
  loadStyles()
end

local function onClientEndMission()
  clearPreview()
  sweepOrphans()
end

M.diagMeshRoad = function(path)
  path = path or "/pit_meshroad_fixture.json"
  local fx = readJson(path)
  if type(fx) ~= "table" then
    print("pit: cannot read fixture " .. tostring(path))
    return
  end

  local function V(t) return vec3(t[1], t[2], t[3]) end
  local function VL(a)
    local o = {}
    for i, t in ipairs(a) do o[i] = V(t) end
    return o
  end
  local function devNum(a, b)
    if type(a) ~= "number" or type(b) ~= "number" then return math.huge end
    if a ~= a or b ~= b then return math.huge end
    if a > 1e17 and b > 1e17 then return 0.0 end
    return math.abs(a - b)
  end
  local function devList(a, b)
    if a == nil or b == nil or #a ~= #b then return math.huge end
    local d = 0.0
    for i = 1, #a do
      if type(b[i]) == "table" then
        local p = a[i]
        if p == nil then return math.huge end
        d = math.max(d, math.abs(p.x - b[i][1]),
                        math.abs(p.y - b[i][2]),
                        math.abs(p.z - b[i][3]))
      else
        d = math.max(d, devNum(a[i], b[i]))
      end
    end
    return d
  end

  local worst, failed = {}, {}
  local function note(name, d)
    if not worst[name] or d > worst[name] then worst[name] = d end
    if d > 1e-6 then failed[name] = true end
  end

  for _, c in ipairs(fx.xyRadius            or {}) do note("xyRadius",            devNum(mr.xyRadius(V(c[1]),               V(c[2]), V(c[3])), c[4])) end
  for _, c in ipairs(fx.ptLineDist          or {}) do note("ptLineDist",          devNum(mr.ptLineDist(V(c[1]),             V(c[2]), V(c[3])), c[4])) end
  for _, c in ipairs(fx.computeTangents     or {}) do note("computeTangents",     devList(mr.computeTangents(VL(c[1])),     c[2]))                    end
  for _, c in ipairs(fx.cumulativeDistances or {}) do note("cumulativeDistances", devList(mr.cumulativeDistances(VL(c[1])), c[2]))                    end
  for _, c in ipairs(fx.miterScales         or {}) do note("miterScales",         devList(mr.miterScales(VL(c[1]),          VL(c[2]), c[3]), c[4]))   end
  for _, c in ipairs(fx.clampWidthsToRadius or {}) do
    local out = mr.clampWidthsToRadius(VL(c[1]), c[2], c[3])
    note("clampWidthsToRadius", devList(out, c[4]))
  end
  for _, c in ipairs(fx.simplifyIndices or {}) do
    local k = mr.simplifyIndices(VL(c[1]), c[2], c[3], c[4], nil, c[5], c[6])
    note("simplifyIndices", devList(k, c[7]))
  end
  for _, c in ipairs(fx.nonFoldingKeep or {}) do
    local k = mr.nonFoldingKeep(VL(c[1]), VL(c[2]), c[3], c[4], nil, c[5])
    note("nonFoldingKeep", devList(k, c[6]))
  end
  for _, c in ipairs(fx.walkSplitFracs or {}) do
    note("walkSplitFracs", devList(mr.walkSplitFracs(c[1], c[2], c[3], c[4], c[5]), c[6]))
    note("spanFoldDeg", devNum(mr.spanFoldDeg(c[2], c[3], c[4]), c[7]))
  end
  for _, c in ipairs(fx.relaxTightCorners or {}) do
    local pts, disp, iters = mr.relaxTightCorners(VL(c[1]), c[2])
    note("relaxTightCorners", devList(pts, c[3]))
    note("relaxTightCorners", devNum(disp, c[4]))
    note("relaxTightCorners", devNum(iters, c[5]))
  end
  for _, c in ipairs(fx.smoothPathWithWidths or {}) do
    local p, w, h = smoothPathWithWidths(VL(c[1]), c[2], c[3], c[4], c[5])
    note("smoothPathWithWidths", devList(p, c[6]))
    note("smoothPathWithWidths", devList(w, c[7]))
    note("smoothPathWithWidths", devList(h, c[8]))
  end
  for _, c in ipairs(fx.pipeline or {}) do
    local spl = {source = "meshroad", points = VL(c[1]), widths = c[2], depths = c[3]}
    local p, w, h, tg, ds = mr.prepareMeshRoad(spl)
    note("PIPELINE points", devList(p, c[4]))
    note("PIPELINE widths", devList(w, c[5]))
    note("PIPELINE heights", devList(h, c[6]))
    note("PIPELINE tangents", devList(tg, c[7]))
    note("PIPELINE dists", devList(ds, c[8]))
  end

  local names = {}
  for k in pairs(worst) do names[#names + 1] = k end
  table.sort(names)
  local bad = 0
  for _, k in ipairs(names) do
    local d = worst[k]
    if failed[k] then bad = bad + 1 end
    print(string.format("%s  %-24s max dev %.3e",
                        failed[k] and "FAIL" or "PASS", k, d))
  end
  print(bad == 0 and "pit: MeshRoad port matches sidewalk_pit.py"
                 or ("pit: " .. bad .. " function(s) diverge"))
end

M.diagMeshFaces = function()
  if not styleCfg then loadStyles() end
  for _, id in ipairs(selectedIds()) do
    local obj = scenetree.findObjectById(id)
    local cls = "?"
    if obj and obj.getClassName then
      local ok, c = pcall(obj.getClassName, obj)
      if ok then cls = c end
    end
    if cls == "MeshRoad" then
      local hid = "unknown"
      if obj.hidden ~= nil then hid = tostring(obj.hidden) end
      local iv = objField(obj, "isRenderEnabled")
      print(string.format("MeshRoad %s: hidden=%s isRenderEnabled=%s",
                          tostring(id), hid, tostring(iv)))
      for _, key in ipairs(MR.MESHROAD_MATERIAL_KEYS) do
        print("   " .. key .. " = " .. tostring(objField(obj, key)))
      end
      local rd = readRoad(id)
      if rd then
        local zmin, zmax, dmin, dmax = 1e9, -1e9, 1e9, -1e9
        for i = 1, #rd.points do
          zmin = math.min(zmin, rd.points[i].z)
          zmax = math.max(zmax, rd.points[i].z)
          dmin = math.min(dmin, rd.depths[i])
          dmax = math.max(dmax, rd.depths[i])
        end
        print(string.format("   node z %.2f..%.2f   node depth %.2f..%.2f",
                            zmin, zmax, dmin, dmax))
        local meshes = buildRoadMesh(rd)
        if meshes then
          for _, sm in ipairs(meshes) do
            local lo, hi = 1e9, -1e9
            for _, v in ipairs(sm.verts) do
              lo = math.min(lo, v.z); hi = math.max(hi, v.z)
            end
            print(string.format("   submesh %s: %d tris, z %.3f..%.3f (span %.3f)",
                                tostring(sm.material), #sm.faces / 3, lo, hi, hi - lo))
          end
        end
      end
    end
  end
  local n = 0
  for _ in pairs(previewMeshes) do n = n + 1 end
  print("live preview meshes in scene: " .. n)
end

M.diagMeshRoadBuild = function()
  if not styleCfg then loadStyles() end
  local found = 0
  for _, id in ipairs(selectedIds()) do
    local rd = readRoad(id)
    if rd and rd.source == "meshroad" then
      found = found + 1
      local p, w, h, tg, ds, closed, note = mr.prepareMeshRoad(rd)
      if not p then
        print(string.format("meshroad %s: rejected (fewer than 2 usable nodes)",
                            tostring(rd.name)))
      else
        local wmin, wmax, hmin, hmax = w[1], w[1], h[1], h[1]
        for i = 1, #w do
          if w[i] < wmin then wmin = w[i] end
          if w[i] > wmax then wmax = w[i] end
          if h[i] < hmin then hmin = h[i] end
          if h[i] > hmax then hmax = h[i] end
        end
        print(string.format("meshroad %s: %d nodes -> %d rings%s  len %.1fm",
          tostring(rd.name), #rd.points, #p, closed and " (closed)" or "", ds[#ds]))
        print(string.format("   width %.2f..%.2f  depth %.2f..%.2f  curb=%s band=%d",
          wmin, wmax, hmin, hmax, tostring(mr.meshroadCurbMaterial(rd)), 0))
        print(string.format("   swept ratio %.3f (want >= %.2f)  relax %d iters, %.3fm",
          note.sweptRatio or -1, MR.MESHROAD_SWEPT_MIN_RATIO,
          note.relaxIters or 0, note.relaxDisp or 0))
        print(string.format("   sharp %d  simplify -%d  fold -%d  strip -%d  narrowed %.3fm",
          note.sharp or 0, note.simplified or 0, note.foldDropped or 0,
          note.mitreStripped or 0, note.narrowed or 0))
        print(string.format("   walk bands %d (fold %.1f deg, split above %.1f)",
          note.walkBands or 1, note.walkFold or 0, MR.WALK_SPLIT_TARGET_FOLD_DEG))
        print(string.format("   chamfer strips facing down: %d (want 0)",
          note.chamferDown or 0))
        print(string.format("   pit_roll=%s  pit_bottom=%s -> bottom faces %s",
          tostring(rd.roll), tostring(rd.bottom),
          (rd.bottom == true) and "drawn" or "not drawn"))
        if note.sharpRunaway then
          print("   sharpening backed out: ring count would have run away")
        end
      end
    end
  end
  if found == 0 then print("no untextured MeshRoad in the selection") end
end

M.diagIsland = function()
  if not styleCfg then loadStyles() end
  local roads = {}
  for _, id in ipairs(selectedIds()) do
    local r = readRoad(id)
    if r then roads[#roads + 1] = r end
  end
  print("marked roads in selection: " .. #roads)
  local islands, rest = extractIslands(roads)
  print("islands: " .. #islands .. "   leftover roads: " .. #rest)
  for k, isl in ipairs(islands) do
    local c0, w0 = resolveStyle(isl)
    print(string.format("island %d: %d parts, key=%s -> curb=%s walk=%s",
      k, isl.parts or 0, tostring(isl.persistentId or isl.name or isl.id),
      tostring(c0), tostring(w0)))
    if isl.srcIds then
      for n, sid in ipairs(isl.srcIds) do
        local rd = readRoad(sid)
        print(string.format("    part %d: id=%s pid=%s", n, tostring(sid),
          rd and tostring(rd.persistentId) or "?"))
      end
    end
    local outer = {}
    for i, pt in ipairs(isl.ring) do outer[i] = pt end
    if signedArea2D(outer) < 0 then
      local r = {}
      for i = #outer, 1, -1 do r[#r + 1] = outer[i] end
      outer = r
    end
    local cand, nNarrow = fitInnerRing(outer,
                            offsetPolygonInward(outer, CURB_STRIP), CURB_STRIP)
    local aOut, aIn = signedArea2D(outer), signedArea2D(cand)
    local tris = triangulatePolygon(cand)
    print(string.format("island %d: ring=%d pts  area=%.2f  outerArea=%.2f  innerArea=%.2f",
                        k, #outer, isl.area, aOut, aIn))
    print(string.format("   gate: innerArea > %.3f  and  innerArea < outerArea  ->  %s",
                        ISLAND_MIN_AREA * 0.05,
                        (aIn > ISLAND_MIN_AREA * 0.05 and aIn < aOut) and "PASS" or "FAIL"))
    local dupes = 0
    for i = 1, #cand do
      local q = cand[i]
      local r = cand[(i % #cand) + 1]
      if math.sqrt((q.x - r.x) ^ 2 + (q.y - r.y) ^ 2) <= 1e-6 then dupes = dupes + 1 end
    end
    local function segX(p1, p2, p3, p4)
      local function cr(o, a, b)
        return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
      end
      local d1, d2 = cr(p3, p4, p1), cr(p3, p4, p2)
      local d3, d4 = cr(p1, p2, p3), cr(p1, p2, p4)
      return ((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0))
    end
    local crossings = 0
    local cn = #cand
    for i = 1, cn do
      for j = i + 2, cn do
        if not (i == 1 and j == cn) then
          if segX(cand[i], cand[(i % cn) + 1], cand[j], cand[(j % cn) + 1]) then
            crossings = crossings + 1
          end
        end
      end
    end
    local tris2, used = triangulatePolygon(cand)
    print(string.format("   raw ring %d pts, %d coincident pairs, %d self-crossings",
                        cn, dupes, crossings))
    print(string.format("   after dedupe %d pts -> %d triangles (want %d)",
                        #used, #tris2, math.max(0, #used - 2)))
    print(string.format("   walkKey=%s   walkMaterial=%s",
                        tostring(isl.walk), tostring(walkMaterialName())))
  end
end

M.diagStyles = function()
  local vectors = {
    {"", "d41d8cd98f00b204e9800998ecf8427e"},
    {"a", "0cc175b9c0f1b6a831c399e269772661"},
    {"abc", "900150983cd24fb0d6963f7d28e17f72"},
    {"message digest", "f96b697d7cb7938d525a2f31aaf161d0"},
    {"abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"},
  }
  local allOk = true
  for _, v in ipairs(vectors) do
    local got = md5(v[1])
    if got ~= v[2] then
      allOk = false
      print(string.format("MD5 FAIL %q -> %s (want %s)", v[1], got, v[2]))
    end
  end
  print("MD5 self-test: " .. (allOk and "PASS" or "FAIL"))
  if not allOk then return end

  if not styleCfg then loadStyles() end
  print("seed: " .. tostring((styleCfg and styleCfg.seed) or 20260812))
  print("curb order: " .. table.concat(orderedStyleNames("curb"), ", "))
  print("walk order: " .. table.concat(orderedStyleNames("walk"), ", "))
  for _, id in ipairs(selectedIds()) do
    local rd = readRoad(id)
    if rd then
      local c, w = resolveStyle(rd)
      print(string.format("  %s  key=%s  curb=%s%s  walk=%s%s",
        tostring(rd.name), tostring(rd.persistentId or rd.name or rd.id),
        tostring(c), rd.curb and " (tag)" or " (drawn)",
        tostring(w), rd.walk and " (tag)" or " (drawn)"))
    end
  end
end

M.renderSelection      = renderSelection
M.clearPreview         = clearPreview
M.sweepOrphans         = sweepOrphans
M.convertSelection     = convertSelection
M.loadStyles           = loadStyles
M.refreshLive          = refreshLive
M.isLive               = function() return liveEnabled end
M.setLive              = function(v)
  liveEnabled = v and true or false
  if not liveEnabled then pendingSince, pendingSig = {}, {} end
end
M.renderedCount        = function()
  local n = 0
  for _ in pairs(rendered) do n = n + 1 end
  return n
end
M.liveMaxRoads         = function() return LIVE_MAX_ROADS end
M.getLiveDelay         = function() return liveDelay end
M.setLiveDelay         = function(v)
  if type(v) ~= "number" then return end
  liveDelay = math.max(LIVE_MIN_DELAY, v)
end
M.liveMinDelay         = function() return LIVE_MIN_DELAY end
M.getStatus            = function() return lastStatus end
M.getMeshNote          = function() return mrState.note end
M.getStyleError        = function() return styleErr end
M.onEditorInspectorFieldChanged = onEditorInspectorFieldChanged
M.onEditorAfterOpenLevel = onEditorAfterOpenLevel
M.onClientEndMission     = onClientEndMission

return M
