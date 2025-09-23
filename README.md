# prioritize.lua
#
#
# DO NOT USE FOR JOB ABILITIES OR WEAPON SKILLS.
# DO NOT USE FOR JOB ABILITIES OR WEAPON SKILLS.
# DO NOT USE FOR JOB ABILITIES OR WEAPON SKILLS.
# DO NOT USE FOR JOB ABILITIES OR WEAPON SKILLS.
# DO NOT USE FOR JOB ABILITIES OR WEAPON SKILLS.
#
#
A **GearSwap export helper** that writes a prioritized gear set based on **HP contributions**.  
This script can **export your currently equipped gear** as a GearSwap‐ready Lua file with `priority=` tags, or **clone your entire job file** and inject priorities into every set.

<img width="1149" height="699" alt="Prioritize" src="https://github.com/user-attachments/assets/610f25c8-b8ff-4e3a-af13-0078bc5d9aac" />

---

## 📂 Installation

1. Copy the file into:
   ```
   Windower/addons/GearSwap/libs/prioritize.lua
   ```
2. Add this line to your job file:
   ```lua
   include('prioritize.lua')
   ```

---

## ⚡ Usage

### Export your current gear
```
//gs c export-p
```
- Creates a new file with your currently equipped gear.
- Each item gets a `priority` value based on its HP contribution.
- Output location:
  ```
  Windower/addons/GearSwap/data/export
  ```

### Clone and prioritize your job file
```
//gs c create
```
- Clones your current job Lua into a new `-p.lua` version.  
- Injects `priority=` values into every gear set.  
- Existing priorities are updated. Items with no HP contribution lose their priority tag.
- Output location:
  ```
  Windower/addons/GearSwap/data/<JobName>-p.lua
  ```

*Note: Running `//gs create` or `//gs export-p` directly also works, but GearSwap may throw a harmless error.*

---

## ⚙️ Features

- **Priority calculation**:
  - HP+ from `resources/item_mods`.
  - Augments parsed via `extdata`.
  - `MP → HP` conversions parsed from text.
  - Fixed overrides for **Unity** and **JSE necks**.
  - Platinum Moogle Belt = `floor(MaxHP / 11)` at export time.
- **Augment normalization** for consistent parsing.
- **Inventory lookup** to pull the best augments even if not in the job file.
- **Automatic directory creation** for export paths.
- **Readable outputs** that mirror GearSwap’s own export format.

---

## 📝 Example Output

```lua
sets.exported={
    main={ name="Tizona", augments={'Path: A',}},
    sub={ name="Machaera +2", augments={'TP Bonus +1000',}},
    ammo="Staunch Tathlum +1",
    head={ name="Nyame Helm", augments={'Path: B',}, priority=91},
    body={ name="Hashishin Mintan +3", priority=87},
    hands={ name="Nyame Gauntlets", augments={'Path: B',}, priority=91},
    legs={ name="Carmine Cuisses +1", augments={'Accuracy+20','Attack+12','\"Dual Wield\"+6',}, priority=50},
    feet={ name="Nyame Sollerets", augments={'Path: B',}, priority=68},
    neck="Sibyl Scarf",
    waist={ name="Plat. Mog. Belt", priority=253},
    left_ear={ name="Eabani Earring", priority=45},
    right_ear="Flashward Earring",
    left_ring="Stikini Ring +1",
    right_ring="Stikini Ring +1",
    back={ name="Rosmerta's Cape", augments={'MND+20','Eva.+20 /Mag. Eva.+20','Mag. Evasion+10','\"Cure\" potency +10%','Phys. dmg. taken-10%',}},
}
```

---

## 📌 Notes

- Augments not tracked in resources (Unity/JSE) use fixed HP overrides.
- Exports are timestamped:
  ```
  PLAYER 2025-09-17 12-44-03-p.lua
  ```
- **create** is best for bulk‐injecting into full job files.  
- **export-p** is lighter, useful for snapshotting one set or maintaining consistency.

---

## 👤 Metadata

- **Library name:** `prioritize`  
- **Author:** Nsane  
- **Version:** 2025.9.17  
- **Commands:**  
  - `//gs c export-p`  
  - `//gs c create`
