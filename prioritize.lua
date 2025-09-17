-- prioritize.lua
-- GearSwap export helper that writes a prioritized set based on HP contributions.
-- Usage:
--   1) Place at: Windower/addons/GearSwap/libs/prioritize.lua
--   2) In your job file: include('prioritize.lua')
-- Options:
--   1) Run: //gs c create, Clone's your existing Job file and add the priorities to every set.
--   2) Run: //gs c export-p, --exports a lua file that look like a typical gs export
--           //gs create or export-p also works, but GearSwap itself will throw a harmless error.
-- Notes:
--   * It's not perfect, there are some items in game, that the augment is not tracked by res or extdata. I.E Unity and JSE Necks.
--   • Platinum Moogle Belt priority = (player MaxHP / 11) at time of export.
--   • Some items have fixed HP overrides when augments are not detectable via resources/extdata.
--   • create Output: addons/GearSwap/data
--   • export-p Output: addons/GearSwap/data/export

_libs.name     = 'prioritize'
_libs.author   = 'Nsane'
_libs.version  = '2025.9.17'
_libs.commands = { 'gs c create', 'gs c export-p' }

local res     = require('resources')
local extdata = require('extdata')

-----------------------------------------------------------------------
-- Static caps and slot vocabulary
-----------------------------------------------------------------------
local UNITY_HP = {
  ['unmoving collar +1'] = 200,
  ['gelatinous ring +1'] = 100,
  ['zwazo earring +1']   = 45,
  ['montante +1']        = 100,
  ['evalach +1']         = 150,
}

local JSE_NECK_HP = {
  ["warrior's bead necklace"]     = 50, ["warrior's bead necklace +1"] = 75, ["warrior's bead necklace +2"] = 100,
  ["knight's bead necklace"]      = 30, ["knight's bead necklace +1"]  = 45, ["knight's bead necklace +2"]  = 60,
  ["futhark torque"]              = 30, ["futhark torque +1"]          = 45, ["futhark torque +2"]          = 60,
}

local slot_keys = {
  'main','sub','range','ammo','head','body','hands','legs','feet',
  'neck','waist','left_ear','right_ear','left_ring','right_ring','back',
  'ear1','ear2','ring1','ring2','lear','rear','lring','rring',
}

local slot_map = {}
for _, s in ipairs(slot_keys) do slot_map[s] = true end

local slot_alias = {
  ear1='left_ear', ear2='right_ear', ring1='left_ring', ring2='right_ring',
  lear='left_ear', rear='right_ear', lring='left_ring', rring='right_ring',
  range='ranged',
}

-----------------------------------------------------------------------
-- Small helpers
-----------------------------------------------------------------------
local function sl(s) return type(s) == 'string' and s:lower() or s end
local function q (s) return string.format('%q', s or '') end
local function sq(s)
  s = tostring(s or ''):gsub('\\', '\\\\'):gsub("'", "\\'")
  return "'" .. s .. "'"
end

-- Normalize names for stable lookup of overrides. Drops non-word chars and simplifies common variants.
local function norm_item_key(s)
  s = sl(s or ''):gsub('[^%w%+]', '')
  s = s:gsub('necklace', ''):gsub('beads', 'bead'):gsub('warriors', 'war'):gsub('knights', 'kgt')
  return s
end

local JSE_NECK_HP_NORM = (function()
  local t = {}
  for k, v in pairs(JSE_NECK_HP) do t[norm_item_key(k)] = v end
  return t
end)()

local function is_pmog_belt(name)
  if not name then return false end
  local n = sl(name)
  return n:find('plat%.%s*mog%.%s*belt') or n:find('platinum%s+moogle%s+belt') or false
end

-- Parse "Converts <N> MP to HP" and also "<N> MP to HP" variants from text.
local function mp_to_hp_from_text(text)
  local s = sl(text or '')
  local best = 0
  for num in s:gmatch('converts%s*(%d+)%s*mp%s*to%s*hp') do best = math.max(best, tonumber(num)) end
  for num in s:gmatch('(%d+)%s*mp%s*to%s*hp') do best = math.max(best, tonumber(num)) end
  return best
end

-----------------------------------------------------------------------
-- Resources lookups
-----------------------------------------------------------------------
local ID_BY_NAME = (function()
  local t = {}
  if res.items then
    for id, it in pairs(res.items) do
      if type(it.en)  == 'string' then t[it.en:lower()]  = id end
      if type(it.enl) == 'string' then t[it.enl:lower()] = id end
    end
  end
  return t
end)()

-- Base HP from structured item_mods plus best HP+ and MP→HP found in description.
local function get_base_hp(item_id)
  if not item_id or item_id == 0 then return 0 end

  local total_hp_mods = 0
  local mods = res.item_mods and res.item_mods[item_id]
  if type(mods) == 'table' then
    for _, m in ipairs(mods) do
      if m and (m.mod == 'HP' or m.mod == 'hp' or m.id == 1) and tonumber(m.value) then
        total_hp_mods = total_hp_mods + tonumber(m.value)
      end
    end
  end

  local it = res.items and res.items[item_id]
  local add_from_desc = 0
  if it then
    local d = res.item_descriptions and res.item_descriptions[item_id]
    local text = ((d and (d.en or d.enl)) or '') .. ' ' .. (it.en or '') .. ' ' .. (it.enl or '')
    local best_hp_plus = 0
    for num in text:gmatch('HP%+%s*(%d+)') do best_hp_plus = math.max(best_hp_plus, tonumber(num)) end
    local mp2hp = mp_to_hp_from_text(text)
    add_from_desc = math.max(add_from_desc, best_hp_plus) + mp2hp
  end

  return total_hp_mods + add_from_desc
end

local function get_base_hp_by_name_exact(name)
  local id = ID_BY_NAME[(name or ''):lower()]
  return get_base_hp(id)
end

-----------------------------------------------------------------------
-- Augments parsing
-----------------------------------------------------------------------
local function clean_augments(list)
  if type(list) ~= 'table' then return {} end
  local out = {}
  for _, a in ipairs(list) do
    if type(a) == 'string' then
      local t = a:gsub('^%s+', ''):gsub('%s+$', '')
      if t ~= '' and sl(t) ~= 'none' then out[#out+1] = t end
    end
  end
  return out
end

-- Sum "HP+N" and any "… MP to HP" conversions present in augment text.
local function hp_from_aug_strings(list)
  if type(list) ~= 'table' then return 0 end
  local total = 0
  for _, s in ipairs(list) do
    for n in s:gmatch('HP%+%s*(%d+)') do total = total + tonumber(n) end
    total = total + mp_to_hp_from_text(s)
  end
  return total
end

local function extract_aug_strings_from_extdata(ed)
  local out = {}
  if not ed then return out end
  if type(ed.augments) == 'table' then
    for _, a in ipairs(ed.augments) do
      if a ~= '' and sl(a) ~= 'none' then out[#out+1] = a end
    end
  end
  if type(ed.augments_raw) == 'table' then
    for _, a in ipairs(ed.augments_raw) do
      if a ~= '' and sl(a) ~= 'none' then out[#out+1] = a end
    end
  end
  return out
end

-----------------------------------------------------------------------
-- Equipped items and per-slot priority computation
-----------------------------------------------------------------------
local function norm_bag_key(bag_id, items_tbl)
  local r = res.bags and res.bags[bag_id]
  if not r then return nil end
  local key = (r.english or r.en or r.enl or ''):lower():gsub('%s+', '')
  return items_tbl[key] and key or nil
end

-- Snapshot a single equipped slot with base and augment HP.
local function get_equipped_item(slot)
  local items = windower.ffxi.get_items()
  if not items or not items.equipment then return nil end

  local idx = items.equipment[slot]
  local bag_id = items.equipment[slot .. '_bag']
  if not idx or idx == 0 or not bag_id then return nil end

  local bag_key = norm_bag_key(bag_id, items)
  if not bag_key then return nil end

  local entry = items[bag_key][idx]
  if not entry or not entry.id or entry.id == 0 then return nil end

  local it = res.items and res.items[entry.id]
  local name = it and (it.en or it.enl) or ('Item ' .. tostring(entry.id))

  local aug_list = {}
  if entry.extdata then
    local ed = extdata.decode(entry)
    for _, s in ipairs(extract_aug_strings_from_extdata(ed)) do aug_list[#aug_list+1] = s end
  end

  return {
    id       = entry.id,
    name     = name,
    augments = aug_list,
    base_hp  = get_base_hp(entry.id),
    aug_hp   = hp_from_aug_strings(aug_list),
    slot     = slot,
  }
end

-- Priority by item object. Used for exporting current gear.
local function compute_priority(it, max_hp)
  if not it then return 0 end
  if it.slot == 'waist' and is_pmog_belt(it.name) and max_hp and max_hp > 0 then
    return math.floor(max_hp / 11)
  end
  local base = it.base_hp or 0
  local aug  = it.aug_hp  or 0
  local cap_u = UNITY_HP[sl(it.name)]
  if cap_u and cap_u > aug then aug = cap_u end
  local cap_j = JSE_NECK_HP_NORM[norm_item_key(it.name)]
  if cap_j and cap_j > aug then aug = cap_j end
  return base + aug
end

-- Priority by name and optional augment text. Used when rewriting job sets.
local function compute_priority_for_name(slot, name, aug_text, max_hp)
  local slot_norm = slot_alias[slot] or slot
  if not name or name == '' then return 0 end
  if slot_norm == 'waist' and is_pmog_belt(name) and max_hp and max_hp > 0 then
    return math.floor(max_hp / 11)
  end
  local base = get_base_hp_by_name_exact(name)
  local aug = 0
  if aug_text and type(aug_text) == 'string' then
    for n in aug_text:gmatch('HP%+%s*(%d+)') do aug = aug + tonumber(n) end
    aug = aug + mp_to_hp_from_text(aug_text)
  end
  local cap_u = UNITY_HP[sl(name)]
  if cap_u and cap_u > aug then aug = cap_u end
  local cap_j = JSE_NECK_HP_NORM[norm_item_key(name)]
  if cap_j and cap_j > aug then aug = cap_j end
  return base + aug
end

-----------------------------------------------------------------------
-- Export current gear to a prioritized export file
-----------------------------------------------------------------------
local function ensure_dirs()
  local base = windower.addon_path .. 'data'
  if not windower.dir_exists(base) then windower.create_dir(base) end
  local export = base .. '\\export'
  if not windower.dir_exists(export) then windower.create_dir(export) end
end

local function build_item_line(slot, name, augments, priority)
  local augs = clean_augments(augments)
  if #augs == 0 and not priority then
    return string.format('    %s=%s,', slot, q(name))
  end
  local parts = { string.format('    %s={ name=%s', slot, q(name)) }
  if #augs > 0 then
    local ss = {}
    for _, a in ipairs(augs) do ss[#ss+1] = sq(a) end
    parts[#parts+1] = ', augments={' .. table.concat(ss, ',') .. '}'
  end
  if priority and priority > 0 then
    parts[#parts+1] = ', priority=' .. priority
  end
  parts[#parts+1] = '},'
  return table.concat(parts)
end

local function write_export_p()
  local player = windower.ffxi.get_player()
  if not player then
    windower.add_to_chat(123, '[prioritize] No player data.')
    return
  end
  local max_hp = player.vitals and (player.vitals.max_hp or player.vitals.hp) or nil
  local lines = {'sets.exported={'}
  for _, slot in ipairs({'main','sub','range','ammo','head','body','hands','legs','feet','neck','waist','left_ear','right_ear','left_ring','right_ring','back'}) do
    local it = get_equipped_item(slot)
    if it then
      local pr = compute_priority(it, max_hp)
      lines[#lines+1] = build_item_line(slot, it.name, it.augments, pr > 0 and pr or nil)
    end
  end
  lines[#lines+1] = '}'
  ensure_dirs()
  local stamp = os.date('%Y-%m-%d %H-%M-%S')
  local rel = string.format('data/export/%s %s-p.lua', player.name or 'PLAYER', stamp)
  local full = (windower.addon_path .. rel):gsub('/', '\\')
  local fh = io.open(full, 'wb')
  if not fh then
    windower.add_to_chat(123, '[prioritize] Failed to open: ' .. full)
    return
  end
  fh:write(table.concat(lines, '\n'))
  fh:close()
  windower.add_to_chat(123, 'GearSwap: Exported your prioritized equipped gear as a Lua file.')
end

-----------------------------------------------------------------------
-- Job file rewrite: inject priority=N into item entries
-----------------------------------------------------------------------
-- Capture including job file path once at load.
local includer_path = (function()
  for lvl = 2, 40 do
    local info = debug.getinfo(lvl, 'S')
    if info and info.source and info.source:sub(1,1) == '@' then
      local p  = info.source:sub(2)
      local lp = sl(p)
      if lp:find('addons[\\/]+gearswap[\\/]+data[\\/]')
         and not lp:find('libs[\\/]')
         and not lp:find('prioritize%.lua') then
        return p
      end
    end
  end
  return nil
end)()

-- Read a single Lua value starting at index `idx` and return the index of its last character.
local function read_lua_value(src, idx)
  local i,n=idx,#src
  while i<=n and src:sub(i,i):match('%s') do i=i+1 end
  if i>n then return idx end
  local ch=src:sub(i,i)
  if ch=="'" or ch=='"' then
    local q=ch; i=i+1
    while i<=n do local c=src:sub(i,i); if c=='\\' then i=i+2 elseif c==q then i=i+1; break else i=i+1 end end
    return i-1
  elseif ch=='{' then
    local d=0
    while i<=n do
      local c=src:sub(i,i)
      if c=="'" or c=='"' then
        local q=c; i=i+1
        while i<=n do local cc=src:sub(i,i); if cc=='\\' then i=i+2 elseif cc==q then i=i+1; break else i=i+1 end end
      elseif c=='{' then d=d+1; i=i+1
      elseif c=='}' then d=d-1; i=i+1; if d==0 then break end
      else i=i+1 end
    end
    return i-1
  else
    while i<=n do local c=src:sub(i,i); if c==',' or c=='}' or c=='\n' then break end; i=i+1 end
    return i-1
  end
end

local function extract_name_and_aug(rhs)
  local name = rhs:match('^%s*[\'"](.-)[\'"]%s*$')
  if name then return name, nil end
  name = rhs:match('[,{}%s]name%s*=%s*[\'"](.-)[\'"]')
  local aug = rhs:match('augments%s*=%s*%b{}')
  return name, aug
end

-- Remove any existing priority field from a table RHS while preserving other keys.
local function strip_priority_field(rhs)
  if not rhs:find('{') then return rhs end
  local r = rhs
  r = r:gsub('%s*,%s*priority%s*=%s*%d+%s*', '', 1)
  r = r:gsub('priority%s*=%s*%d+%s*,%s*', '', 1)
  r = r:gsub('%s*,%s*}', '}', 1)
  return r
end

-- True if RHS is exactly "{ name='X' }" or "{ name="X" }".
local function table_is_only_name(rhs_no_pr)
  local s = rhs_no_pr:match('^%s*{%s*(.-)%s*}%s*$')
  if not s then return false end
  s = s:gsub('%s+', '')
  return s:match("^name=%b''$") or s:match('^name=%b""$')
end

-- Insert or update priority=N into the RHS, minimizing table form when possible.
local function inject_priority_rhs(rhs, pr)
  if not pr or pr <= 0 then
    if rhs:match('^%s*["\']') then return rhs end
    local name, aug = extract_name_and_aug(rhs)
    local rhs_no_pr = strip_priority_field(rhs)
    if aug then return rhs_no_pr end
    if name and table_is_only_name(rhs_no_pr) then
      return string.format('%q', name)
    end
    rhs_no_pr = rhs_no_pr:gsub('{%s*name%s*=', '{ name='):gsub(',%s*priority%s*=', ', priority=')
    return rhs_no_pr
  end

  if rhs:match('^%s*["\']') then
    local name = rhs:match('^%s*["\'](.-)["\']%s*$')
    if not name then return rhs end
    return string.format('{ name=%q, priority=%d}', name, pr)
  end

  if rhs:find('priority%s*=') then
    rhs = rhs:gsub('priority%s*=%s*%d+', 'priority=' .. pr, 1)
  else
    local head = rhs:match('^(.*)%}%s*$')
    if head then rhs = head .. ', priority=' .. pr .. '}' end
  end

  rhs = rhs:gsub('{%s*name%s*=', '{ name='):gsub(',%s*priority%s*=', ', priority=')
  return rhs
end

local function base_no_ext(p)
  local f = (p or ''):gsub('[\\/]$', ''):match('([^\\/]+)$') or p or ''
  return f:gsub('%.[Ll][Uu][Aa]$', '')
end

-- Walk the Lua source and inject computed priorities for each slot assignment.
local function transform_all_sets(src, max_hp)
  local i, n, out, count = 1, #src, {}, 0
  while i <= n do
    local s, e, slot
    local j = i
    while j <= n do
      local k1, k2 = src:find('%f[%w_](%a[%w_]*)%f[^%w_]%s*=%s*', j)
      if not k1 then break end
      local nm = src:match('%f[%w_](%a[%w_]*)%f[^%w_]%s*=%s*', j)
      if nm and slot_map[nm] then s, e, slot = k1, k2, nm; break end
      j = k2 + 1
    end
    if not s then
      out[#out+1] = src:sub(i)
      break
    end
    out[#out+1] = src:sub(i, e)
    local rhs_start = e + 1
    local rhs_end   = read_lua_value(src, rhs_start)
    local rhs       = src:sub(rhs_start, rhs_end)
    local item_name, aug = extract_name_and_aug(rhs)
    local pr = item_name and compute_priority_for_name(slot, item_name, aug, max_hp) or 0
    local new_rhs = inject_priority_rhs(rhs, pr)
    local had   = rhs:match('priority%s*=%s*(%d+)')
    local will  = new_rhs:match('priority%s*=%s*(%d+)')
    if (not had and will) or (had and will and tonumber(had) ~= tonumber(will)) then
      count = count + 1
    end
    out[#out+1] = new_rhs
    i = rhs_end + 1
  end
  return table.concat(out), count
end

local function prioritize_create(optional_rel_path)
  local src = optional_rel_path and (windower.addon_path .. optional_rel_path) or includer_path
  if not src then
    windower.add_to_chat(123, '[prioritize] Cannot find including job file. Pass path: //gs create data/YourJob.lua')
    return
  end

  local f = io.open(src, 'rb')
  if not f then
    windower.add_to_chat(123, '[prioritize] Read failed: ' .. src)
    return
  end
  local data = f:read('*a'); f:close()

  local player = windower.ffxi.get_player()
  local max_hp = player and player.vitals and (player.vitals.max_hp or player.vitals.hp) or nil

  local rewritten, count = transform_all_sets(data, max_hp)
  local out = src:gsub('%.lua$', '-p.lua')

  local fo = io.open(out, 'wb')
  if not fo then
    windower.add_to_chat(123, '[prioritize] Write failed: ' .. out)
    return
  end
  fo:write(rewritten); fo:close()

  windower.add_to_chat(123, ('GearSwap: Created %s (%d priorities injected).'):format(base_no_ext(out), count))
end

-----------------------------------------------------------------------
-- Inventory-driven augment override for name-based priority
-----------------------------------------------------------------------
local INVENTORY_BEST_AUG_HP = nil

local function bag_table_for_id(items_tbl, bag_id)
  local r = res.bags and res.bags[bag_id]
  if not r then return nil end
  local key = (r.english or r.en or r.enl or ''):lower():gsub('%s+', '')
  return items_tbl[key]
end

-- Build a cache: best HP from augments per normalized item name across all bags.
local function build_inventory_aug_index()
  local items = windower.ffxi.get_items()
  local out = {}
  if not items then return out end

  for bag_id, _ in pairs(res.bags or {}) do
    local bag_tbl = bag_table_for_id(items, bag_id)
    if type(bag_tbl) == 'table' then
      for _, entry in pairs(bag_tbl) do
        if type(entry) == 'table' and entry.id and entry.id ~= 0 and entry.extdata then
          local it = res.items and res.items[entry.id]
          local name = it and (it.en or it.enl)
          if name then
            local ed = extdata.decode(entry)
            local aug_list = extract_aug_strings_from_extdata(ed)
            local hp_aug = hp_from_aug_strings(aug_list)
            if hp_aug and hp_aug > 0 then
              local key = norm_item_key(name)
              if not out[key] or hp_aug > out[key] then
                out[key] = hp_aug
              end
            end
          end
        end
      end
    end
  end

  return out
end

local function best_aug_hp_from_inventory(name)
  if not name or name == '' then return 0 end
  if not INVENTORY_BEST_AUG_HP then
    INVENTORY_BEST_AUG_HP = build_inventory_aug_index()
  end
  return INVENTORY_BEST_AUG_HP[norm_item_key(name)] or 0
end

-- Override name-based priority to consult inventory for missing augments.
local function compute_priority_for_name_augaware(slot, name, aug_text, max_hp)
  local slot_norm = slot_alias[slot] or slot
  if not name or name == '' then return 0 end
  if slot_norm == 'waist' and is_pmog_belt(name) and max_hp and max_hp > 0 then
    return math.floor(max_hp / 11)
  end
  local base = get_base_hp_by_name_exact(name)
  local aug = 0
  if aug_text and type(aug_text) == 'string' then
    for n in aug_text:gmatch('HP%+%s*(%d+)') do aug = aug + tonumber(n) end
    aug = aug + mp_to_hp_from_text(aug_text)
  else
    aug = math.max(aug, best_aug_hp_from_inventory(name))
  end
  local cap_u = UNITY_HP[sl(name)]
  if cap_u and cap_u > aug then aug = cap_u end
  local cap_j = JSE_NECK_HP_NORM[norm_item_key(name)]
  if cap_j and cap_j > aug then aug = cap_j end
  return base + aug
end

compute_priority_for_name = compute_priority_for_name_augaware

-----------------------------------------------------------------------
-- Commands
-----------------------------------------------------------------------
windower.register_event('addon command', function(cmd, a1, a2)
  cmd = sl(cmd or '')
  if cmd == 'export-p' then
    write_export_p()
    return
  elseif cmd == 'create' then
    prioritize_create(a1 and a1:match('%.lua$') and a1 or nil)
    return
  elseif cmd == 'c' then
    local sub = sl(tostring(a1 or ''))
    if sub == 'export-p' then
      write_export_p()
      return
    end
    if sub == 'create' then
      prioritize_create(a2 and a2:match('%.lua$') and a2 or nil)
      return
    end
  end
end)