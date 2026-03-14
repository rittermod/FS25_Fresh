# Settings Reference

All Fresh settings are accessible from the Fresh Menu (Right Shift + F) → Settings tab. Settings are saved per savegame and synced in multiplayer.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_Fresh/issues).

---

## Global Settings

| Setting | Default | Options | Description |
|---------|---------|---------|-------------|
| **Enable Expiration** | On | Off / On | Toggles all aging and expiration. When off, products never age or expire. |
| **Show Warnings** | On | Off / On | Show expiry warnings in info boxes when looking at storages and vehicles. |
| **Show Age Display** | On | Off / On | Show color-coded age distribution bars when near storages. |
| **Warning Threshold** | 24 hours | 6h / 12h / 24h / 48h / 72h | Info box text turns yellow when a product expires within this time. Items with shorter shelf lives may always show as expiring. |
| **Storage Class Aging** | On | Off / On | When enabled, goods age at different rates depending on storage type (Exposed ages fastest, Frozen slowest). When disabled, all storages age at the same baseline rate. |

*With expiration disabled, all aging mechanics are paused. Existing batch ages are preserved and resume aging when re-enabled.*

---

## Difficulty Presets

The difficulty preset scales all shelf lives at once. Select a preset from the Settings tab.

| Preset | Multiplier | Effect |
|--------|-----------|--------|
| **Very Easy** | ×4 | All shelf lives quadrupled. Strawberries last 4 months instead of 1. |
| **Easy** | ×2 | All shelf lives doubled. Forgiving pace for learning the mechanic. |
| **Normal** | ×1 | Default values from the [Shelf Life Table](reference-shelf-life.md). Research-based realism. |
| **Hard** | ×0.5 | All shelf lives halved. Demanding logistics for experienced players. |
| **Custom** | varies | Unlocks individual per-product controls. No global multiplier applied. |

### How Presets Interact with Custom Settings

- Selecting a preset (Very Easy through Hard) applies that multiplier to all products. The Expiration and Max Benefit tabs show the effective values but are read-only.
- Selecting **Custom** unlocks the Expiration tab for individual per-product editing. Products start at their Normal-difficulty defaults.
- Switching from Custom back to a preset discards any per-product changes and applies the preset multiplier to the mod defaults.

---

## Expiration Settings (Per Product)

Available when difficulty is set to **Custom**. Located in the Settings tab → Expiration sub-tab.

Each perishable product has a configurable shelf life:

| Option | Meaning |
|--------|---------|
| **Do not expire** | Product never expires (removed from tracking) |
| **1 month** - **5 years** | Time before expiration in Sheltered storage |

Available values: 1, 2, 3, 4, 5, 6, 9, 12, 18, 24, 36, or 60 months.

Products are organized into two sections:

- **Expiration Times** - Basegame fill types
- **Expiration Times (DLCs & Mods)** - Fill types from DLCs, maps, and other mods

Each product shows a tooltip with the fill type's source (basegame, DLC name, or mod name).

---

## Max Benefit Settings (Per Product)

Located in the Settings tab → Max Benefit sub-tab. Controls the maximum storage class that benefits each product.

| Option | Meaning |
|--------|---------|
| **Sheltered** | No benefit from Indoor, Cooled, or Frozen storage |
| **Indoor** | No benefit from Cooled or Frozen storage |
| **Cooled** | No benefit from Frozen storage |
| **Frozen** | Benefits from all storage classes |

See the [Storage Classes Guide](guide-storage-classes.md#max-benefit-class) for how this interacts with storage type.

---

## Storage Class Settings

Located in the Settings tab → Storage sub-tab. Override the automatically detected storage class for specific storages.

Each tracked storage shows:

- Its name and location
- The detected (automatic) storage class
- An override dropdown to change the class

Vehicles appear in the list as soon as they are on the map, even when empty. This lets you configure storage class overrides before loading any goods.

A special **Items in World** entry covers all bales, pallets, and big bags not placed in a dedicated object storage. Overriding this entry applies to all loose items at once.

Use this when automatic detection doesn't match your setup - for example, if a mod building provides refrigerated storage but Fresh detects it as Indoor.

---

## Reset to Defaults

A **Reset to Defaults** button at the bottom of the Settings tab restores all settings to the mod's original values:

- Difficulty returns to Normal
- All per-product shelf lives return to mod defaults
- All max benefit classes return to mod defaults
- All storage class overrides are cleared
- Global settings (warnings, age display, threshold) return to defaults

A confirmation dialog appears before the reset takes effect. This action cannot be undone.

---

## Settings Dependencies

Some settings depend on others:

```
Enable Expiration → All other settings (only when Expiration is On)
Difficulty Preset → Expiration tab (editable only when Custom)
Storage Class Aging → Max Benefit tab + Storage tab (visible only when On)
                    → Shelf Life tab display (per-class table when On, simple list when Off)
```

*Dependent settings are greyed out or hidden when their parent setting is disabled.*

---

## Console Commands

For advanced users and debugging. Open the game console with the tilde key (~).

### Inspection (All Users)

| Command | Args | Description |
|---------|------|-------------|
| `fList` | `[type]` | List all tracked containers. Filter by type: `vehicle` (v), `bale` (b), `placeable` (p), `husbandryfood` (h), `stored` (s) |
| `fInspect` | `<#>` | Show detailed info for container # (from fList) |
| `fBatches` | `<#>` | Show all batches in container # with ages |
| `fStorages` | `[class\|config]` | Show storage classes for all containers. Use `config` to show max benefit per product |
| `fStats` | - | Show loss statistics summary |
| `fStatus` | `[hours]` | List containers expiring within N hours (default: 24) |
| `fLog` | `[count]` | Show recent loss log entries (default: 50) |
| `fDump` | - | Dump full mod state to the game log file |

### Batch Manipulation (Admin Only)

| Command | Args | Description |
|---------|------|-------------|
| `fAddBatch` | `<#> <amount> [age]` | Add a batch to container #. Age in periods (default: 0 = fresh) |
| `fRemBatch` | `<#> <batchIdx>` | Remove a specific batch from container # |
| `fSetAge` | `<#> <batchIdx> <age>` | Set age of a specific batch (in periods) |
| `fSetAllAge` | `<#> [age]` | Set all batches in container # to age (default: 0) |

### Time Simulation (Admin Only)

| Command | Args | Description |
|---------|------|-------------|
| `fAge` | `<hours>` | Simulate N hours of aging on ALL containers |
| `fAgeContainer` | `<#> <hours>` | Simulate N hours of aging on container # only |
| `fExpire` | `<#> [batchIdx]` | Force expire a specific batch (or all batches) in container # |
| `fExpireAll` | `<type\|all>` | Force expire all containers of a type, or `all` |

### Storage Class Overrides (Admin Only)

| Command | Args | Description |
|---------|------|-------------|
| `fSetStorage` | `<#\|items> <class>` | Override storage class. Use container # or `items` for all bales/pallets. Class: exposed, sheltered, indoor, cooled, frozen, disabled |
| `fClearStorage` | `<#\|items>` | Remove storage class override |

### Maintenance (Admin Only)

| Command | Args | Description |
|---------|------|-------------|
| `fClearLog` | - | Clear the loss log |
| `fReconcile` | - | Manually reconcile tracked state with game state |

*Admin commands require master user access or server access.*
