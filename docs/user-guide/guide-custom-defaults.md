# Custom Defaults (Advanced)

Fresh's in-game Settings let you tune every product's shelf life - but those choices are saved inside that one savegame. Start a new game and you would set everything up again. **Custom Defaults** is an optional file that keeps your preferred setup in one reusable place: it applies to all your savegames and survives mod updates.

> **This is an advanced, optional feature.** You only need it if you want a reusable per-install configuration - for example, to give custom-crop or map-mod products a shelf life everywhere, or to carry your own basegame tweaks across all your saves. Setting it up means editing a small XML file in a text editor. Everyday tuning is easier in the [Settings menu](reference-settings.md).

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_Fresh/issues).

---

## Why use it

The in-game Settings are **per savegame**. To reuse the same setup across all your games, players used to edit the mod's bundled defaults file directly - but a mod update overwrites that file and wipes the changes. Custom Defaults replaces that workaround with a file that lives *outside* the mod, so it survives updates and applies to every save.

It is useful when you want to:

- Keep a personal baseline for basegame products that you reuse in every new game
- Give products from custom-crop, map, or other mods a shelf life in one central place
- Share or back up your preferred setup as a single file

The file is **portable**: you can list products from mods that are not even in your current game. Those entries stay dormant until a save actually contains that product, so one file works across all your saves.

---

## How it fits in

Custom Defaults is a layer that sits *between* the mod's built-in values and your in-game settings. When Fresh needs a product's shelf life, it checks these layers in order:

| Priority | Layer | Set where | Notes |
|----------|-------|-----------|-------|
| 1 (highest) | In-game settings | Fresh Menu, per savegame | A value you deliberately change here always wins |
| 2 | **Custom Defaults** | `modSettings/FS25_Fresh/customDefaults.xml`, per install | Your reusable baseline |
| 3 (lowest) | Bundled mod defaults | Ships inside the mod | Fresh's built-in values |

So anything you set in Custom Defaults overrides Fresh's built-in value for that product, but a change you make in the in-game Settings menu still takes priority. The difficulty preset multiplier (Easy, Hard, and so on) scales your custom periods exactly as it scales the bundled ones.

---

## Setting it up

1. Find the template `data/customDefaults.example.xml` inside the mod - open `FS25_Fresh.zip` in any archive viewer, or view it [on GitHub](https://github.com/rittermod/FS25_Fresh/blob/main/data/customDefaults.example.xml).
2. Create the folder `modSettings/FS25_Fresh/` (the `modSettings` folder sits next to your `mods` folder; create the `FS25_Fresh` subfolder if it does not exist).
3. Save your edited copy as `modSettings/FS25_Fresh/customDefaults.xml`.
4. Restart the game.

The file is re-read on **every launch** and applies to all your saves. It is never copied into a savegame and Fresh never writes to it.

> **Multiplayer:** On a dedicated or host server, place the file on the **server** only. Clients receive the values automatically through the normal settings sync, so the display matches everywhere. Clients do not need their own copy.

---

## What you can configure

The file uses the same format as Fresh's bundled defaults. A minimal example:

```xml
<?xml version="1.0" encoding="utf-8"?>
<freshSettings version="2">
    <fillTypes>
        <!-- Make wheat last 6 months instead of the bundled 12 -->
        <fillType name="WHEAT" period="6.0"/>

        <!-- Give a custom-crop mod's product a shelf life -->
        <fillType name="CUSTOMCROP" period="3.0" maxBenefitClass="cooled"/>

        <!-- Mark a product as never expiring -->
        <fillType name="POTATO" expires="false"/>
    </fillTypes>
</freshSettings>
```

### Per-product shelf life

Each `<fillType>` entry sets the default for one product:

| Attribute | Values | Meaning |
|-----------|--------|---------|
| `name` | Internal fill type name, e.g. `WHEAT` | Which product this applies to. Use the internal name (the same names used in the bundled defaults and in a crop mod's own files), **not** the in-game display name. |
| `period` | Months: `1.0`, `2.0`, `3.0`, `4.0`, `5.0`, `6.0`, `9.0`, `12.0`, `18.0`, `24.0`, `36.0`, `60.0` | Shelf life in months, at Normal difficulty in Sheltered storage. These are the values the in-game UI uses. |
| `expires` | `false` | Marks the product as non-expiring. Use this *instead of* `period`. |
| `maxBenefitClass` | `exposed`, `sheltered`, `indoor`, `cooled`, `frozen` | Optional. The best storage class that still improves this product (see the [Storage Classes Guide](guide-storage-classes.md#max-benefit-class)). |

### Global defaults

Seed a global default such as the info-box warning time:

```xml
<global>
    <setting name="warningHours" value="48"/>
</global>
```

A change made in the in-game Settings menu still overrides this.

### Storage class multipliers

Override the aging multiplier for specific storage classes:

```xml
<storageClasses enabled="true">
    <class name="frozen" multiplier="0.05"/>
</storageClasses>
```

Only the classes you list change; the rest keep their bundled values. Valid class names are `exposed`, `sheltered`, `indoor`, `cooled`, `frozen`, and `disabled`. The `enabled` attribute toggles storage-class aging on or off. See the [Storage Classes Guide](guide-storage-classes.md) for what each class means.

### Hidden categories

Hide entire fill-type categories from tracking and the Fresh Menu:

```xml
<categories>
    <category name="FUEL" hidden="true"/>
</categories>
```

This **adds to** the mod's built-in hidden categories (`ANIMAL` and `HORSE` stay hidden) - it does not replace them.

---

## Good to know

- **Re-read every launch.** Edit the file, restart the game, done. There is no need to touch each save.
- **In-game changes win.** Anything you deliberately set in the Fresh Menu for a save still overrides this file for that save. Editing the file later updates the baseline for products you have not overridden in that save.
- **Dormant entries are fine.** You can list products from mods that are not in your current game. They are ignored until a save actually contains them, so the same file works across all your saves.
- **Read-only.** Fresh never writes to this file and never copies it into a savegame.

---

## Further Reading

- [Storage Classes Guide](guide-storage-classes.md) - Storage class names, multipliers, and max benefit
- [Settings Reference](reference-settings.md) - Tuning shelf life from the in-game menu
- [Shelf Life Table](reference-shelf-life.md) - Default shelf life for every built-in product
