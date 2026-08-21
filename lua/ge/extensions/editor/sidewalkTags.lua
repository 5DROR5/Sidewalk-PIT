--  PIT sidewalk tagging tool


local M = {}
local logTag = 'sidewalkTags'
local imgui = ui_imgui

local toolWindowName = "pitSidewalkTags"
local registered = false
local statusText = ""

local ensureRegistered

local CONFIG_NAME = "pit_sidewalk_styles.json"
local DEFAULT_PREFIX = "pit_"

local DEFAULT_PROFILE_STYLES = {
  walk   = {label = "sidewalk",       color = {0.45, 0.60, 0.80}, weight = 2},
  island = {label = "traffic island", color = {0.75, 0.55, 0.35}, weight = 1},
}

local DEFAULT_FLAG_STYLES = {
  on  = {label = "on",  color = {0.35, 0.70, 0.40}, weight = 2},
  off = {label = "off", color = {0.55, 0.55, 0.55}, weight = 1},
}

local sectionForce = nil

local AXES = {"curb", "walk", "profile"}
local MR_AXES = {"wall", "bottom", "roll"}
local ALL_AXES = {"curb", "walk", "profile", "wall", "bottom", "roll"}

local rtlLayout = false
local rtlCache = {}

local mirrorMap = {
  ["("] = ")", [")"] = "(",
  ["["] = "]", ["]"] = "[",
  ["{"] = "}", ["}"] = "{",
  ["<"] = ">", [">"] = "<",
}

local function isLtrChar(ch)
  if #ch ~= 1 then return false end
  return ch:match("[%a%d_%.]") ~= nil
end

local function isRtlText(s)
  return type(s) == "string" and s:find("[\214\215\216\217]") ~= nil
end

local function utf8Split(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local b = s:byte(i)
    local len = 1
    if b >= 0xF0 then len = 4
    elseif b >= 0xE0 then len = 3
    elseif b >= 0xC0 then len = 2 end
    out[#out + 1] = s:sub(i, i + len - 1)
    i = i + len
  end
  return out
end

local function flipToVisual(s)
  local chars = utf8Split(s)
  local count = #chars

  local rev = {}
  for i = count, 1, -1 do
    rev[#rev + 1] = chars[i]
  end

  local i = 1
  while i <= count do
    if isLtrChar(rev[i]) then
      local a = i
      while i <= count and isLtrChar(rev[i]) do i = i + 1 end
      local b = i - 1
      while a < b do
        rev[a], rev[b] = rev[b], rev[a]
        a, b = a + 1, b - 1
      end
    else
      i = i + 1
    end
  end

  for k = 1, count do
    local m = mirrorMap[rev[k]]
    if m then rev[k] = m end
  end

  return table.concat(rev)
end

local function rtl(s)
  if s == nil or s == "" then return s end
  local cached = rtlCache[s]
  if cached then return cached end

  local label, idPart = s, ""
  local p = s:find("##", 1, true)
  if p then
    label = s:sub(1, p - 1)
    idPart = s:sub(p)
  end

  local result = isRtlText(label) and (flipToVisual(label) .. idPart) or s
  rtlCache[s] = result
  return result
end

local function availWidth()
  if imgui.GetContentRegionAvailWidth then
    local ok, w = pcall(imgui.GetContentRegionAvailWidth)
    if ok and w then return w end
  end
  if imgui.GetContentRegionAvail then
    local ok, r = pcall(imgui.GetContentRegionAvail)
    if ok and r and r.x then return r.x end
  end
  return 0
end

local function alignRight(width)
  if not rtlLayout then return end
  local offset = availWidth() - width
  if offset > 0 then
    imgui.SetCursorPosX(imgui.GetCursorPosX() + offset)
  end
end

local function text(s, col)
  local v = rtl(s)
  if rtlLayout then
    local ok, size = pcall(imgui.CalcTextSize, v)
    if ok and size then alignRight(size.x) end
  end
  if col then
    imgui.TextColored(col, v)
  else
    imgui.TextUnformatted(v)
  end
end

-- ---------------------------------------------------------------------------
-- config
-- ---------------------------------------------------------------------------

local cfg = nil
local cfgPath = ""
local cfgError = nil
local cfgMissing = false
local cfgEmpty = false
local palette = nil
local fieldOf = {}

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

local function color4(c, alpha)
  if type(c) == "table" and #c >= 3 then
    return imgui.ImVec4(c[1], c[2], c[3], alpha or 1)
  end
  return imgui.ImVec4(0.35, 0.38, 0.45, alpha or 1)
end

local function luminance(c)
  if type(c) ~= "table" or #c < 3 then return 0.35 end
  return 0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3]
end

local function buildAxis(styles, axis)
  local out = {}
  if type(styles) ~= "table" then return out end
  for name, st in pairs(styles) do
    if type(st) == "table" then
      out[#out + 1] = {
        value = name,
        label = st.label or name,
        color = st.color,
        band = st.band,
        weight = st.weight or 0,
        isSequence = st.sequence ~= nil,
      }
    end
  end
  table.sort(out, function(a, b)
    if a.isSequence ~= b.isSequence then return b.isSequence end
    if axis == "curb" and a.band and b.band and a.band ~= b.band then
      return a.band < b.band
    end
    if a.weight ~= b.weight then return a.weight > b.weight end
    return a.value < b.value
  end)
  return out
end

local function curbUsesAtlas()
  local name = cfg and cfg.curb and cfg.curb.material
  local mat = name and cfg.materials and cfg.materials[name]
  return type(mat) == "table" and mat.atlas ~= nil
end

local function loadConfig()
  cfg, palette, cfgError = nil, nil, nil
  cfgMissing = false
  cfgEmpty = false
  fieldOf = {}
  rtlLayout = false

  local dir = levelDir()
  if not dir then
    cfgError = "no level loaded"
    return
  end
  cfgPath = dir .. CONFIG_NAME

  local data = readJson(cfgPath)
  if not data then
    local exists = false
    if FS and FS.fileExists then
      local ok, v = pcall(FS.fileExists, FS, cfgPath)
      exists = ok and v or false
    end
    cfgMissing = not exists
    cfgError = cfgMissing and "no config in this level yet" or "file malformed"
    return
  end
  if data.version ~= 1 then
    cfgError = "version must be 1"
    return
  end

  local axes = data.axes or {}
  local prefix = data.fieldPrefix or DEFAULT_PREFIX
  for _, ax in ipairs(ALL_AXES) do
    fieldOf[ax] = (axes[ax] or {}).field or (prefix .. ax)
  end

  palette = {
    curb = {
      label = (axes.curb or {}).label or "curb edge",
      entries = buildAxis((data.curb or {}).styles, "curb"),
    },
    walk = {
      label = (axes.walk or {}).label or "walk centre",
      entries = buildAxis((data.walk or {}).styles, "walk"),
    },
    profile = {
      label = (axes.profile or {}).label or "curb profile",
      entries = buildAxis((data.profile or {}).styles or DEFAULT_PROFILE_STYLES, "profile"),
    },
    wall = {
      label = (axes.wall or {}).label or "MeshRoad material",
      entries = buildAxis((data.wall or {}).styles, "wall"),
    },
    bottom = {
      label = (axes.bottom or {}).label or "bottom faces",
      entries = buildAxis(DEFAULT_FLAG_STYLES, "bottom"),
    },
    roll = {
      label = (axes.roll or {}).label or "banking from nodes",
      entries = buildAxis(DEFAULT_FLAG_STYLES, "roll"),
    },
  }

  cfgEmpty = (#palette.curb.entries == 0 and #palette.walk.entries == 0
              and #palette.wall.entries == 0)

  for _, ax in ipairs(ALL_AXES) do
    if isRtlText(palette[ax].label) then rtlLayout = true end
    for _, e in ipairs(palette[ax].entries) do
      if isRtlText(e.label) then rtlLayout = true end
    end
  end

  cfg = data
end

-- ---------------------------------------------------------------------------
-- material picking
-- ---------------------------------------------------------------------------

local matSet = nil
local matFilter = imgui.ImGuiTextFilter()
local texCache = {}
local texBudget = 0
local opaqueOnly = imgui.BoolPtr(true)
local likelyOnly = imgui.BoolPtr(false)
local asNewStyle = imgui.BoolPtr(false)
local matClassCache = {}
local newScaleU = imgui.FloatPtr(2.5)
local newScaleV = imgui.FloatPtr(2.5)
local newBand = imgui.IntPtr(0)
local newAxis = imgui.IntPtr(1)
local alsoCurbMat = imgui.BoolPtr(false)
local alsoMeshMat = imgui.BoolPtr(false)
local selectedMat = nil
local matError = nil
local labelBuf = imgui.ArrayChar(64)

local ffiLib = nil
local function ffiGet()
  if ffiLib == nil then
    local ok, lib = pcall(require, "ffi")
    ffiLib = (ok and lib) or false
  end
  return ffiLib or nil
end

local function bufRead(arr)
  local lib = ffiGet()
  if not lib then return "" end
  local ok, s = pcall(lib.string, arr)
  return (ok and s) and s or ""
end

local function bufWrite(arr, str)
  local lib = ffiGet()
  if not lib then return end
  pcall(lib.copy, arr, tostring(str or ""))
end

local VEC32 = imgui.ImVec2(32, 32)

local function ensureMatSet()
  if matSet then return matSet end
  matSet = {}
  if not Sim or not Sim.getMaterialSet then return matSet end
  local ok, set = pcall(Sim.getMaterialSet)
  if not ok or not set then return matSet end
  for i = 0, set:size() - 1 do
    matSet[#matSet + 1] = set:at(i)
  end
  return matSet
end

local function matField(mat, name, idx)
  if not mat or not mat.getField then return nil end
  local ok, v = pcall(mat.getField, mat, name, idx or 0)
  if ok then return v end
  return nil
end

local function texFor(mat)
  if type(editor.texObj) ~= "function" then return nil end
  local img = matField(mat, "baseColorMap", 0)
  if not img or img == "" then img = matField(mat, "diffuseMap", 0) end
  if not img or img == "" then img = matField(mat, "colorMap", 0) end
  if not img or img == "" then return nil end
  local abs = img
  if not img:find("/") then
    local okp, base = pcall(mat.getPath, mat)
    abs = (okp and base or "") .. img
  end
  if texCache[abs] == nil and texBudget < 5 then
    texBudget = texBudget + 1
    local ok, tex = pcall(editor.texObj, abs)
    local empty = (type(tex) ~= "table") or (next(tex) == nil)
    texCache[abs] = (ok and not empty) and tex or false
  end
  return texCache[abs] or nil
end

local NON_COVERING_BLEND = {
  Add = true, AddAlpha = true, Mul = true, Sub = true, PreMulAlpha = true,
}

local function matOpacityClass(mat)
  local function on(k)
    local v = matField(mat, k, 0)
    return v == "1" or v == "true"
  end
  local function filled(k)
    local v = matField(mat, k, 0)
    return v ~= nil and v ~= ""
  end

  if on("alphaTest") or filled("opacityMap") or filled("opacityDetailMap") then
    return "cutout"
  end
  local of = tonumber(matField(mat, "opacityFactor", 0) or "1")
  if of and of < 1 then return "faded" end
  if on("emissive") then return "glow" end

  local op = matField(mat, "translucentBlendOp", 0)
  if op and NON_COVERING_BLEND[op] then return "glow" end
  if op == "LerpAlpha" and not on("translucentZWrite") then return "blended" end

  return "opaque"
end

local function matClass(mat, name)
  local c = matClassCache[name]
  if c == nil then
    local ok, v = pcall(matOpacityClass, mat)
    c = ok and v or "opaque"
    matClassCache[name] = c
  end
  return c
end

local function isSolidMaterial(mat, name)
  return matClass(mat, name) == "opaque"
end


local CANDIDATE_DENY = {
  "annotation", "checkpoint", "marker", "rooftile", "roof_tile", "invisible",
  "unmapped", "noshape", "default", "editor", "debug", "test", "lod",
  "decal", "damage", "eroded", "destroyed", "leak", "dirty",
}


local CANDIDATE_RULES = {
  {axis = "curb", rank = 1, keys = {"curb", "kerb", "gutter"}},
  {axis = "walk", rank = 1, keys = {"sidewalk", "pavement", "walkway"}},
  {axis = "walk", rank = 2, keys = {"slab", "paver", "floortile"}},
  {axis = "walk", rank = 3, keys = {"tiles", "cobble"}},
  {axis = "wall", rank = 1, keys = {"concrete", "retaining"}},
  {axis = "wall", rank = 2, keys = {"stone", "wall", "blockwall"}},
  {axis = "wall", rank = 3, keys = {"brick", "cladding"}},
}

local candidateCache = {}

local function candidateInfo(name)
  local hit = candidateCache[name]
  if hit ~= nil then
    if hit == false then return nil end
    return hit
  end
  local n = name:lower()
  for _, d in ipairs(CANDIDATE_DENY) do
    if n:find(d, 1, true) then
      candidateCache[name] = false
      return nil
    end
  end
  for _, r in ipairs(CANDIDATE_RULES) do
    for _, k in ipairs(r.keys) do
      if n:find(k, 1, true) then
        local info = {axis = r.axis, key = k, rank = r.rank}
        candidateCache[name] = info
        return info
      end
    end
  end
  candidateCache[name] = false
  return nil
end

local function writeJson(path, data)
  for _, fn in ipairs({jsonWriteFile, writeJsonFile}) do
    if type(fn) == "function" then
      local ok = pcall(fn, path, data, true)
      if ok then return true end
    end
  end
  return false
end


local function slug(s)
  s = tostring(s or ""):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  return s ~= "" and s or "style"
end

local function commitConfig(data)
  if cfgPath == "" then
    statusText = "no level loaded"
    return false
  end
  local tmp = cfgPath .. ".tmp"
  if not writeJson(tmp, data) then
    statusText = "write failed - no permission on the level folder?"
    return false
  end
  if not readJson(tmp) then
    statusText = "the written file is unreadable - config left unchanged"
    return false
  end
  if not writeJson(cfgPath, data) then
    statusText = "writing the config failed"
    return false
  end
  return true
end

local function dataCurbUsesAtlas(data)
  local name = data and data.curb and data.curb.material
  local mat = name and data.materials and data.materials[name]
  return type(mat) == "table" and mat.atlas ~= nil
end

local function styleKeyFor(data, axis, matName, label, forceNew)
  local styles = (data[axis] or {}).styles or {}
  local base = slug(label ~= "" and label or matName)

  if not forceNew then
    local st = styles[base]
    if st and (st.material == matName or st.material == nil) then return base end
    if not st then return base end
  end

  local i = 2
  while styles[base .. "_" .. i] do i = i + 1 end
  return base .. "_" .. i
end

local function emptyConfigData()
  return {
    version = 1,
    seed = os.time and math.floor(os.time() % 100000000) or 1,
    fieldPrefix = DEFAULT_PREFIX,
    defaultScale = 2.5,
    axes = {
      curb    = {field = DEFAULT_PREFIX .. "curb",    label = "curb edge"},
      walk    = {field = DEFAULT_PREFIX .. "walk",    label = "walk centre"},
      wall    = {field = DEFAULT_PREFIX .. "wall",    label = "MeshRoad material"},
      bottom  = {field = DEFAULT_PREFIX .. "bottom",  label = "bottom faces"},
      roll    = {field = DEFAULT_PREFIX .. "roll",    label = "banking from nodes"},
      profile = {field = DEFAULT_PREFIX .. "profile", label = "curb profile"},
    },
    materials = {},
    curb = {styles = {}},
    walk = {styles = {}},
    wall = {styles = {}},
  }
end


local function createEmptyConfig()
  if cfgPath == "" then
    statusText = "no level loaded"
    return false
  end
  if readJson(cfgPath) then
    statusText = "a config already exists - not overwriting it"
    return false
  end
  if not commitConfig(emptyConfigData()) then return false end
  loadConfig()
  statusText = "created " .. CONFIG_NAME
  log('I', logTag, statusText)
  return true
end

local function materialStillUsed(data, matName, skipAxis, skipKey)
  for _, ax in ipairs(ALL_AXES) do
    local styles = (data[ax] or {}).styles
    if type(styles) == "table" then
      for k, st in pairs(styles) do
        if not (ax == skipAxis and k == skipKey) and type(st) == "table"
           and st.material == matName then
          return true
        end
      end
    end
  end
  local curb = data.curb or {}
  if curb.material == matName or curb.meshroadMaterial == matName then return true end
  return false
end

local function removeStyleFromConfig(axis, key)
  local data = readJson(cfgPath)
  if not data then
    statusText = "cannot read the config"
    return
  end
  local styles = (data[axis] or {}).styles
  local st = styles and styles[key]
  if not st then
    statusText = "style not found: " .. tostring(key)
    return
  end

  local matName = st.material
  styles[key] = nil

  local unlinked = 0
  for _, ax in ipairs(ALL_AXES) do
    local s2 = (data[ax] or {}).styles
    if type(s2) == "table" then
      for _, other in pairs(s2) do
        if type(other) == "table" and type(other.sequence) == "table" then
          for i = #other.sequence, 1, -1 do
            if other.sequence[i] == key then
              table.remove(other.sequence, i)
              unlinked = unlinked + 1
            end
          end
        end
      end
    end
  end

  if matName and data.materials and not materialStillUsed(data, matName) then
    data.materials[matName] = nil
  end

  if not commitConfig(data) then return end
  loadConfig()
  statusText = string.format("removed %s from %s%s", key, axis,
                             unlinked > 0
                               and string.format(" (%d sequence link%s cleared)",
                                                 unlinked, unlinked == 1 and "" or "s")
                               or "")
  log('I', logTag, statusText)
end

local function addMaterialToConfig(matName, axis, su, sv, label, asCurbMat, asMeshMat, forceNew)
  label = (label and label ~= "") and label or matName
  local data = readJson(cfgPath)
  if not data then
    if not cfgMissing then
      statusText = "cannot read the config for writing"
      return
    end
    data = emptyConfigData()
  end

  data.materials = data.materials or {}
  data.materials[matName] = data.materials[matName] or {}
  data.materials[matName].scale = {su, sv}

  data.curb = data.curb or {}

  if asCurbMat or (axis == "curb" and not data.curb.material) then
    data.curb.material = matName
  end
  if asMeshMat or (axis == "wall" and not data.curb.meshroadMaterial) then
    data.curb.meshroadMaterial = matName
  end

  data[axis] = data[axis] or {}
  data[axis].styles = data[axis].styles or {}

  local key = styleKeyFor(data, axis, matName, label, forceNew)
  local style = data[axis].styles[key]
  if style then
    style.label = label
  else
    style = {
      material = matName,
      weight = 0,
      label = label,
      color = {0.55, 0.55, 0.58},
    }
    data[axis].styles[key] = style
  end

  if axis == "curb" then
    style.material = nil
    if dataCurbUsesAtlas(data) then
      style.band = newBand[0]
      style.scale = nil
    else
      style.scale = {su, sv}
      style.band = nil
    end
  end

  if not commitConfig(data) then return end

  local wasAtlas = dataCurbUsesAtlas(data)
  loadConfig()
  if axis == "curb" and wasAtlas then
    statusText = string.format("%s (%s) added to %s as band %d  [%s]",
                               label, matName, axis, newBand[0], key)
  else
    statusText = string.format("%s (%s) added to %s at scale %.2f x %.2f  [%s]",
                               label, matName, axis, su, sv, key)
  end
  log('I', logTag, statusText)
end

-- ---------------------------------------------------------------------------
-- scene access
-- ---------------------------------------------------------------------------

local function getSelection()
  if not editor or not editor.selection then return {} end
  return editor.selection.object or {}
end

local function classOf(id)
  local obj = scenetree.findObjectById(id)
  if not obj then return "" end
  if obj.getClassName then
    local ok, name = pcall(obj.getClassName, obj)
    if ok and name then return name end
  end
  return obj.className or ""
end

local function dynValue(id, fieldName)
  local fields = editor.getDynamicFields(id)
  if not fields then return nil end
  for i = 1, #fields do
    if fields[i] == fieldName then
      local ok, val = pcall(editor.getFieldValue, id, fieldName)
      if ok and val ~= "" then return val end
      return nil
    end
  end
  return nil
end

local function selectionValue(ids, fieldName)
  if #ids == 0 then return nil, "none" end
  local first = dynValue(ids[1], fieldName)
  for i = 2, #ids do
    if dynValue(ids[i], fieldName) ~= first then return nil, "mixed" end
  end
  if first == nil then return nil, "none" end
  return first, "all"
end

local function applyValue(fieldName, value)
  local ids = getSelection()
  if #ids == 0 then
    statusText = "nothing selected"
    return
  end

  editor.history:beginTransaction("PitSidewalkTag")
  for i = 1, #ids do
    editor.setDynamicFieldValue(ids[i], fieldName, value, 0)
  end
  editor.history:endTransaction()

  statusText = (value == "")
    and string.format("cleared %s from %d objects", fieldName, #ids)
    or string.format("%s = %s written to %d objects", fieldName, value, #ids)
  log('I', logTag, statusText)
end

-- ---------------------------------------------------------------------------
-- coverage
-- ---------------------------------------------------------------------------

local coverage = nil

local function objDynValue(obj, fieldName)
  if obj and obj.getDynDataFieldbyName then
    local ok, v = pcall(obj.getDynDataFieldbyName, obj, fieldName, 0)
    if ok and v ~= nil and v ~= "" then return v end
  end
  return nil
end

local function knownValues(axis)
  local set = {}
  if palette then
    for _, e in ipairs(palette[axis].entries) do set[e.value] = true end
  end
  return set
end

local function scanCoverage()
  coverage = {total = 0, untagged = 0}
  for _, ax in ipairs(ALL_AXES) do coverage[ax] = {} end
  if not scenetree.findClassObjects then
    statusText = "scanning is not supported in this version"
    return
  end
  local ok, names = pcall(scenetree.findClassObjects, "DecalRoad")
  if not ok or type(names) ~= "table" then
    statusText = "no decals found in the map"
    return
  end

  local known = {}
  for _, ax in ipairs(ALL_AXES) do known[ax] = knownValues(ax) end

  for _, nm in ipairs(names) do
    local obj = scenetree.findObject(nm)
    if obj then
      local id = obj.getID and obj:getID() or nil
      coverage.total = coverage.total + 1
      local tagged = false
      for _, axis in ipairs(ALL_AXES) do
        local v = objDynValue(obj, fieldOf[axis])
        if v then
          tagged = true
          local bucket = coverage[axis][v]
          if not bucket then
            bucket = {n = 0, ids = {}, known = known[axis][v] or false}
            coverage[axis][v] = bucket
          end
          bucket.n = bucket.n + 1
          if id then bucket.ids[#bucket.ids + 1] = id end
        end
      end
      if not tagged then coverage.untagged = coverage.untagged + 1 end
    end
  end
  statusText = string.format("scanned %d decals", coverage.total)
end

local MARKER_MATERIAL = "WarningMaterial"
local MESHROAD_MATERIAL_KEYS = {"topMaterial", "sideMaterial", "bottomMaterial"}

local function objField(obj, name)
  if obj and obj.getField then
    local ok, v = pcall(obj.getField, obj, name, 0)
    if ok and v ~= nil and v ~= "" then return tostring(v) end
  end
  return nil
end

local function findUnskinned(kind)
  local ids = {}
  if not scenetree.findClassObjects then return ids end
  local ok, names = pcall(scenetree.findClassObjects, kind)
  if not ok or type(names) ~= "table" then return ids end

  for _, nm in ipairs(names) do
    local obj = scenetree.findObject(nm)
    if obj then
      local take
      if kind == "MeshRoad" then
        local real = false
        for _, key in ipairs(MESHROAD_MATERIAL_KEYS) do
          local v = objField(obj, key)
          if v and v ~= MARKER_MATERIAL then real = true end
        end
        take = not real
      else
        take = (objField(obj, "material") == MARKER_MATERIAL)
      end
      if take then
        local id = obj.getID and obj:getID() or nil
        if id then ids[#ids + 1] = id end
      end
    end
  end
  return ids
end

local function selectIds(ids)
  if not ids or #ids == 0 then return end
  if editor.selectObjects then
    local ok = pcall(editor.selectObjects, ids)
    if ok then
      statusText = string.format("selected %d objects", #ids)
      return
    end
  end
  if editor.selectObjectById then
    if editor.clearObjectSelection then editor.clearObjectSelection() end
    for i = 1, #ids do pcall(editor.selectObjectById, ids[i]) end
    statusText = string.format("selected %d objects", #ids)
  end
end

-- ---------------------------------------------------------------------------
-- gui
-- ---------------------------------------------------------------------------

local BTN_W = 122
local PER_ROW = 2

local function paletteButton(entry, axis, isActive)
  local pushes = 0
  if entry.color then
    imgui.PushStyleColor2(imgui.Col_Button, color4(entry.color, 1))
    imgui.PushStyleColor2(imgui.Col_ButtonHovered, color4(entry.color, 0.85))
    imgui.PushStyleColor2(imgui.Col_ButtonActive, color4(entry.color, 0.7))
    imgui.PushStyleColor2(imgui.Col_Text, (luminance(entry.color) < 0.5)
                          and imgui.ImVec4(1, 1, 1, 1) or imgui.ImVec4(0.05, 0.05, 0.05, 1))
    pushes = 4
  end

  local label = entry.label .. (isActive and "  <" or "")
  local clicked = imgui.Button(rtl(label) .. "##" .. axis .. "_" .. entry.value,
                               imgui.ImVec2(BTN_W, 0))

  for _ = 1, pushes do imgui.PopStyleColor() end

  if imgui.IsItemHovered() then
    imgui.SetTooltip(entry.value)
  end
  return clicked
end

local function section(title, defaultOpen)
  if sectionForce ~= nil then
    pcall(imgui.SetNextItemOpen, sectionForce)
  elseif defaultOpen then
    pcall(imgui.SetNextItemOpen, true, imgui.Cond_FirstUseEver)
  end
  return imgui.CollapsingHeader1(rtl(title))
end

local function drawAxis(axis, ids, hasSelection)
  local ax = palette[axis]
  if not ax or #ax.entries == 0 then return end
  local field = fieldOf[axis]

  if not section(ax.label .. "  (" .. field .. ")", true) then return end

  local current, state = selectionValue(ids, field)

  if state == "mixed" then
    text("current: mixed", imgui.ImVec4(1, 0.7, 0.2, 1))
  elseif state == "all" then
    local known = false
    for _, e in ipairs(ax.entries) do
      if e.value == current then
        known = true
        break
      end
    end
    text("current: " .. tostring(current) .. (known and "" or "  (not in config)"),
         known and imgui.ImVec4(0.4, 1, 0.4, 1) or imgui.ImVec4(1, 0.45, 0.35, 1))
  else
    text("current: (untagged - default)", imgui.ImVec4(0.6, 0.6, 0.6, 1))
  end

  local total = #ax.entries
  local rowStart = 1
  while rowStart <= total do
    local rowEnd = math.min(rowStart + PER_ROW - 1, total)
    local inRow = rowEnd - rowStart + 1
    alignRight(BTN_W * inRow + 8 * (inRow - 1))

    if rtlLayout then
      for k = rowEnd, rowStart, -1 do
        if k < rowEnd then imgui.SameLine() end
        local entry = ax.entries[k]
        local active = (state == "all" and current == entry.value)
        if paletteButton(entry, axis, active) and hasSelection then
          applyValue(field, entry.value)
        end
      end
    else
      for k = rowStart, rowEnd do
        if k > rowStart then imgui.SameLine() end
        local entry = ax.entries[k]
        local active = (state == "all" and current == entry.value)
        if paletteButton(entry, axis, active) and hasSelection then
          applyValue(field, entry.value)
        end
      end
    end
    rowStart = rowStart + PER_ROW
  end

  alignRight(BTN_W)
  if imgui.Button(rtl("clear  X") .. "##clear_" .. axis, imgui.ImVec2(BTN_W, 0)) and hasSelection then
    applyValue(field, "")
  end
end

local function drawCoverage()
  if not section("tag coverage in the map", false) then return end

  alignRight(BTN_W * 2 + 8)
  if imgui.Button(rtl("select MeshRoad") .. "##selmesh", imgui.ImVec2(BTN_W, 0)) then
    local ids = findUnskinned("MeshRoad")
    if #ids == 0 then
      statusText = "no untextured MeshRoad found"
    else
      selectIds(ids)
      statusText = string.format("selected %d untextured MeshRoad", #ids)
    end
  end
  imgui.SameLine()
  if imgui.Button(rtl("select decals") .. "##seldecal", imgui.ImVec2(BTN_W, 0)) then
    local ids = findUnskinned("DecalRoad")
    if #ids == 0 then
      statusText = "no marked decals found"
    else
      selectIds(ids)
      statusText = string.format("selected %d marked decals", #ids)
    end
  end
  text("MeshRoad = no real material.  decals = material is " .. MARKER_MATERIAL,
       imgui.ImVec4(0.5, 0.5, 0.5, 1))

  alignRight(BTN_W)
  if imgui.Button(rtl("scan now") .. "##scan", imgui.ImVec2(BTN_W, 0)) then
    scanCoverage()
  end

  if not coverage then
    text("the scan walks the whole map, so it only runs on click",
         imgui.ImVec4(0.6, 0.6, 0.6, 1))
    return
  end

  text(string.format("decals total: %d   untagged: %d", coverage.total, coverage.untagged))

  for _, axis in ipairs(ALL_AXES) do
    local rows = {}
    for value, b in pairs(coverage[axis]) do
      rows[#rows + 1] = {value = value, n = b.n, ids = b.ids, known = b.known}
    end
    if #rows > 0 then
      table.sort(rows, function(a, b) return a.n > b.n end)
      text(palette[axis].label .. ":")
      for _, r in ipairs(rows) do
        alignRight(250)
        if imgui.Button(rtl("select") .. "##sel_" .. axis .. "_" .. r.value, imgui.ImVec2(56, 0)) then
          selectIds(r.ids)
        end
        imgui.SameLine()
        imgui.TextColored(r.known and imgui.ImVec4(0.75, 0.75, 0.75, 1)
                                   or imgui.ImVec4(1, 0.45, 0.35, 1),
                          string.format("%s = %s   %d", axis, r.value, r.n))
      end
    end
  end
end

local function scaleHint(su, sv)
  local old = ""
  local known = cfg and cfg.materials and cfg.materials[selectedMat]
  local sc = known and known.scale
  if type(sc) == "table" and #sc >= 2 then
    old = string.format("   (config now: %.2f x %.2f)", sc[1], sc[2])
  elseif type(sc) == "number" then
    old = string.format("   (config now: %.2f)", sc)
  end
  return string.format("U %.2f m/tile - %.1f tiles per 10 m along", su, 10.0 / su),
         string.format("V %.2f m/tile - %.1f tiles per 10 m across%s", sv, 10.0 / sv, old)
end

local function drawAdvanced()
  if not section("advanced", false) then return end

  text("add a material already in the map to the config", imgui.ImVec4(0.6, 0.6, 0.6, 1))

  local set = ensureMatSet()
  if #set == 0 then
    text("no materials found in the map", imgui.ImVec4(1, 0.45, 0.35, 1))
    return
  end

  imgui.PushID1("pitMatFilter")
  pcall(imgui.ImGuiTextFilter_Draw, matFilter, "Search...", 200)
  imgui.PopID()
  imgui.Checkbox(rtl("solid materials only") .. "##opaqueonly", opaqueOnly)
  if imgui.IsItemHovered() then
    imgui.SetTooltip("keeps only materials that fully cover a surface.\n"
                     .. "hides alpha cutouts, glows and blended overlays.\n"
                     .. "solid decal roads stay.")
  end
  imgui.SameLine()
  imgui.Checkbox(rtl("likely candidates") .. "##likelyonly", likelyOnly)
  if imgui.IsItemHovered() then
    imgui.SetTooltip("narrows the list to paving and walling materials by name.\n"
                     .. "a suggestion, not a rule - switch it off to see everything.")
  end

  local hidden = 0
  local narrowed = 0

  local function drawList()
    local rows = {}
    for i = 1, #set do
      local mat = set[i]
      local okn, name = pcall(mat.getName, mat)
      local pass = okn and name and name ~= ""
                   and imgui.ImGuiTextFilter_PassFilter(matFilter, name)
      if pass and opaqueOnly[0] and not isSolidMaterial(mat, name) then
        pass = false
        hidden = hidden + 1
      end
      local info = pass and candidateInfo(name) or nil
      if pass and likelyOnly[0] and not info then
        pass = false
        narrowed = narrowed + 1
      end
      if pass then
        rows[#rows + 1] = {mat = mat, name = name, info = info}
      end
    end

    if likelyOnly[0] then
      table.sort(rows, function(a, b)
        if a.info.axis ~= b.info.axis then return a.info.axis < b.info.axis end
        if a.info.rank ~= b.info.rank then return a.info.rank < b.info.rank end
        return #a.name < #b.name
      end)
    end

    for _, row in ipairs(rows) do
      local name = row.name
      local clicked = false
      local tex = texFor(row.mat)
      if tex and tex.texId then
        local oki, hit = pcall(imgui.ImageButton, "##tex_" .. name, tex.texId, VEC32)
        if oki and hit then clicked = true end
        if oki then imgui.SameLine() end
      end
      if imgui.Selectable1(name .. "##sel_" .. name, selectedMat == name) or clicked then
        selectedMat = name
        asNewStyle[0] = false
        local known = cfg and cfg.materials and cfg.materials[name]
        local sc = known and known.scale
        if type(sc) == "table" and #sc >= 2 then
          newScaleU[0], newScaleV[0] = sc[1], sc[2]
        elseif type(sc) == "number" then
          newScaleU[0], newScaleV[0] = sc, sc
        end
        local existing = nil
        for _, ax in ipairs({"walk", "curb", "wall"}) do
          local styles = cfg and cfg[ax] and cfg[ax].styles
          if type(styles) == "table" then
            for _, st in pairs(styles) do
              if type(st) == "table" and st.material == name and st.label then
                existing = st.label
                break
              end
            end
          end
          if existing then break end
        end
        bufWrite(labelBuf, existing or name)
        if row.info then newAxis[0] = (row.info.axis == "curb" and 0)
                                      or (row.info.axis == "wall" and 2) or 1 end
      end
      if row.info and likelyOnly[0] then
        imgui.SameLine()
        text("[" .. row.info.axis .. "]", imgui.ImVec4(0.45, 0.55, 0.45, 1))
      end
    end
  end

  texBudget = 0
  imgui.BeginChild1("pitMatList", imgui.ImVec2(0, 180), true)
  local okList, listErr = pcall(drawList)
  imgui.EndChild()
  if not okList then
    matError = tostring(listErr)
  end
  if matError then
    text("list error: " .. matError, imgui.ImVec4(1, 0.45, 0.35, 1))
  end
  if hidden > 0 or narrowed > 0 then
    local parts = {}
    if hidden > 0 then parts[#parts + 1] = hidden .. " transparent" end
    if narrowed > 0 then parts[#parts + 1] = narrowed .. " off-topic" end
    text(table.concat(parts, ", ") .. " hidden", imgui.ImVec4(0.6, 0.6, 0.6, 1))
  end

  if not selectedMat then
    text("pick a material from the list", imgui.ImVec4(0.6, 0.6, 0.6, 1))
    return
  end

  imgui.Separator()
  imgui.TextUnformatted(selectedMat)

  local uses = {}
  if cfg then
    for _, ax in ipairs(ALL_AXES) do
      local styles = cfg[ax] and cfg[ax].styles
      if type(styles) == "table" then
        for k, st in pairs(styles) do
          if type(st) == "table" and (st.material == selectedMat
             or (ax == "curb" and cfg.curb and cfg.curb.material == selectedMat
                 and st.sequence == nil)) then
            uses[#uses + 1] = {axis = ax, key = k, label = st.label or k}
          end
        end
      end
    end
  end

  if #uses > 0 then
    text(string.format("already used by %d style%s:", #uses, #uses == 1 and "" or "s"),
         imgui.ImVec4(1, 0.7, 0.2, 1))
    for _, u in ipairs(uses) do
      if imgui.Button(rtl("remove") .. "##rm_" .. u.axis .. "_" .. u.key,
                      imgui.ImVec2(70, 0)) then
        removeStyleFromConfig(u.axis, u.key)
      end
      imgui.SameLine()
      text(string.format("%s . %s   (%s)", u.axis, u.key, u.label),
           imgui.ImVec4(0.75, 0.75, 0.75, 1))
    end
    imgui.Checkbox(rtl("add as a new style") .. "##newstyle", asNewStyle)
    if imgui.IsItemHovered() then
      imgui.SetTooltip("off: update the matching style in place.\n"
                       .. "on: keep the existing one and add another, so the same\n"
                       .. "material can appear at several scales.")
    end
  end

  imgui.PushItemWidth(-1)
  imgui.InputText("##pitlabel", labelBuf, 64)
  imgui.PopItemWidth()
  text("display name - this is what appears on the palette button",
       imgui.ImVec4(0.5, 0.5, 0.5, 1))

  imgui.PushItemWidth(90)
  imgui.DragFloat("U##su", newScaleU, 0.01, 0.05, 64.0, "%.2f")
  imgui.SameLine()
  imgui.DragFloat("V##sv", newScaleV, 0.01, 0.05, 64.0, "%.2f")
  imgui.PopItemWidth()

  local hintU, hintV = scaleHint(newScaleU[0], newScaleV[0])
  text(hintU, imgui.ImVec4(0.5, 0.5, 0.5, 1))
  text(hintV, imgui.ImVec4(0.5, 0.5, 0.5, 1))

  imgui.RadioButton2(rtl("walk centre") .. "##axw", newAxis, 1)
  imgui.SameLine()
  imgui.RadioButton2(rtl("curb edge") .. "##axc", newAxis, 0)
  imgui.SameLine()
  imgui.RadioButton2(rtl("MeshRoad wall") .. "##axwall", newAxis, 2)

  if newAxis[0] == 0 then
    if curbUsesAtlas() then
      imgui.PushItemWidth(90)
      imgui.InputInt("band##curbband", newBand)
      imgui.PopItemWidth()
      if newBand[0] < 0 then newBand[0] = 0 end
      text("this map's curb material is an atlas, so a curb style selects a "
           .. "band. The scale above is stored on the material only.",
           imgui.ImVec4(0.5, 0.5, 0.5, 1))
    else
      text("this map's curb material has no atlas, so the scale above is "
           .. "written into the curb style itself.",
           imgui.ImVec4(0.5, 0.5, 0.5, 1))
    end
  end


  if newAxis[0] == 0 and cfg and cfg.curb and cfg.curb.material
     and cfg.curb.material ~= selectedMat then
    text("curb.material is " .. tostring(cfg.curb.material)
         .. " - this style will be drawn with that material, not "
         .. selectedMat, imgui.ImVec4(1, 0.7, 0.2, 1))
    text("curb styles vary band or scale only. tick the box below to replace"
         .. " the map's kerb material instead", imgui.ImVec4(0.6, 0.6, 0.6, 1))
  end

  imgui.Checkbox(rtl("also set as the map's curb material") .. "##ascurb", alsoCurbMat)
  imgui.Checkbox(rtl("also set as the map's MeshRoad material") .. "##asmesh", alsoMeshMat)
  text("these write curb.material and meshroadMaterial, not a style. the first"
       .. " kerb or wall material added sets them automatically",
       imgui.ImVec4(0.5, 0.5, 0.5, 1))
  if cfg and cfg.curb then
    text(string.format("now: curb.material = %s   meshroadMaterial = %s",
                       tostring(cfg.curb.material or "(unset)"),
                       tostring(cfg.curb.meshroadMaterial or "(unset)")),
         (cfg.curb.material and imgui.ImVec4(0.5, 0.5, 0.5, 1))
                            or imgui.ImVec4(1, 0.45, 0.35, 1))
  end

  alignRight(BTN_W)
  if imgui.Button(rtl("add to config") .. "##addmat", imgui.ImVec2(BTN_W, 0)) then
    local label = bufRead(labelBuf)
    if label == "" then label = selectedMat end
    local axis = "walk"
    if newAxis[0] == 0 then axis = "curb"
    elseif newAxis[0] == 2 then axis = "wall" end
    addMaterialToConfig(selectedMat, axis, newScaleU[0], newScaleV[0], label,
                        alsoCurbMat[0], alsoMeshMat[0], asNewStyle[0])
  end
end

local function onEditorGui()
  ensureRegistered()
  if not editor.isWindowVisible(toolWindowName) then return end

  if editor.beginWindow(toolWindowName, "PIT - Sidewalk Tags") then
    alignRight(BTN_W * 2 + 8)
    if imgui.Button(rtl("collapse all") .. "##collapseall", imgui.ImVec2(BTN_W, 0)) then
      sectionForce = false
    end
    imgui.SameLine()
    if imgui.Button(rtl("expand all") .. "##expandall", imgui.ImVec2(BTN_W, 0)) then
      sectionForce = true
    end

    alignRight(BTN_W)
    if imgui.Button(rtl("reload config") .. "##reload", imgui.ImVec2(BTN_W, 0)) then
      loadConfig()
      coverage = nil
      statusText = cfgError and ("error: " .. cfgError) or "config loaded"
    end

    if not palette then
      if cfgMissing then
        text("no config in this level yet", imgui.ImVec4(0.8, 0.8, 0.8, 1))
        text(cfgPath ~= "" and cfgPath or CONFIG_NAME, imgui.ImVec4(0.6, 0.6, 0.6, 1))
        text("create an empty one, then add materials under 'advanced'",
             imgui.ImVec4(0.6, 0.6, 0.6, 1))
        alignRight(BTN_W)
        if imgui.Button(rtl("create config") .. "##mkcfg", imgui.ImVec2(BTN_W, 0)) then
          createEmptyConfig()
        end
        drawAdvanced()
      else
        text("config not loaded: " .. tostring(cfgError), imgui.ImVec4(1, 0.45, 0.35, 1))
        text(cfgPath ~= "" and cfgPath or CONFIG_NAME, imgui.ImVec4(0.6, 0.6, 0.6, 1))
        text("fix or delete the file - nothing is written while it is unreadable",
             imgui.ImVec4(0.6, 0.6, 0.6, 1))
      end
    else
      local ids = getSelection()
      local hasSelection = #ids > 0
      local decalCount, meshCount = 0, 0
      for i = 1, #ids do
        local cls = classOf(ids[i])
        if cls == "DecalRoad" then decalCount = decalCount + 1
        elseif cls == "MeshRoad" then meshCount = meshCount + 1 end
      end

      if cfgEmpty then
        text("this config has no styles yet - add materials under 'advanced'",
             imgui.ImVec4(1, 0.7, 0.2, 1))
      end

      if not hasSelection then
        text("select decals in the SceneTree", imgui.ImVec4(1, 0.5, 0, 1))
      else
        text(string.format("selected: %d  (DecalRoad: %d, MeshRoad: %d)",
                           #ids, decalCount, meshCount))
        if decalCount + meshCount < #ids then
          text("the selection contains objects that are neither DecalRoad nor MeshRoad",
               imgui.ImVec4(1, 0.7, 0.2, 1))
        end
      end

      for _, ax in ipairs(AXES) do
        drawAxis(ax, ids, hasSelection)
      end

      imgui.Separator()
      text("MeshRoad only", imgui.ImVec4(0.55, 0.75, 1, 1))
      if hasSelection and meshCount == 0 then
        text("no MeshRoad in the selection - these tags will have no effect",
             imgui.ImVec4(1, 0.7, 0.2, 1))
      end
      for _, ax in ipairs(MR_AXES) do
        drawAxis(ax, ids, hasSelection)
      end

      imgui.Separator()
      drawCoverage()

      imgui.Separator()
      drawAdvanced()

      if statusText ~= "" then
        imgui.Separator()
        text(statusText, imgui.ImVec4(0.4, 1, 0.4, 1))
      end
    end
  end
  editor.endWindow()
  sectionForce = nil
end

-- ---------------------------------------------------------------------------
-- setup
-- ---------------------------------------------------------------------------

ensureRegistered = function()
  if registered then return end
  if not editor or not editor.registerWindow then return end
  editor.registerWindow(toolWindowName, imgui.ImVec2(380, 560))
  editor.addWindowMenuItem("Sidewalk Tags", function()
    editor.showWindow(toolWindowName)
  end, {groupMenuName = "PIT"})
  registered = true
end

local function onEditorInitialized()
  ensureRegistered()
  loadConfig()
end

local function onEditorAfterOpenLevel()
  loadConfig()
  coverage = nil
  statusText = ""
end

local function open()
  ensureRegistered()
  matClassCache = {}
  if not palette then loadConfig() end
  editor.showWindow(toolWindowName)
end

M.onEditorGui = onEditorGui
M.onEditorInitialized = onEditorInitialized
M.onEditorAfterOpenLevel = onEditorAfterOpenLevel
M.open = open

return M
