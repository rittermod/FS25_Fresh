# Frequently Asked Questions

Common questions about Fresh, covering expiration mechanics, storage, multiplayer, and customization.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_Fresh/issues).

---

## Why did my produce expire faster than expected?

Two things to check:

**1. Storage class.** Where your goods are stored matters significantly. Pallets and bales left outdoors are classified as **Exposed** (1.5x aging rate), meaning they expire 50% faster than the listed shelf life. Move goods into Indoor or Cooled storage to extend their life. See the [Storage Classes Guide](guide-storage-classes.md) for details.

**2. Difficulty preset.** At **Hard** difficulty, all shelf lives are halved. A product listed at 6 months on Normal only lasts 3 months on Hard. Check your preset in the Fresh Menu → Settings tab.

These effects stack. Strawberries (1-month base shelf life) on Hard difficulty in Exposed storage last roughly 10 days.

---

## Why is something lasting much longer than expected?

Check two things:

**1. Storage class.** If goods are in **Cooled** (0.3x) or **Frozen** (0.10x) storage, they age dramatically slower. Frozen storage extends shelf life by 10x.

**2. Difficulty preset.** **Very Easy** quadruples all shelf lives.

Also check if a storage class override has been applied via the Settings → Storage tab.

---

## Can I disable expiration entirely?

Yes. Open the Fresh Menu (Right Shift + F) → Settings tab and toggle **Enable Expiration** to Off. All aging pauses. Existing batch ages are preserved and resume if you re-enable it later.

---

## Can I disable expiration for specific products?

Yes. Set the difficulty to **Custom**, then open the Expiration sub-tab. Find the product and set it to **Do not expire**. That product will no longer age or expire while everything else continues normally.

---

## How does "oldest first" (FIFO) work?

When products are removed from storage - whether you're selling, a production building is consuming input, or animals are eating - Fresh always removes the **oldest batch first**. This mimics real-world stock rotation and prevents the situation where fresh goods are used while older ones sit forgotten at the back until they expire.

You don't need to do anything special for this to work. It happens automatically for all storage types.

---

## Does this work in multiplayer?

Yes. Fresh is fully multiplayer-compatible with a **server-authoritative** model:

- The server tracks all batch data, aging, and expirations
- Clients receive synchronized data and can view the Fresh Menu
- Settings changes by the host are broadcast to all clients
- Only the host or server admin can change settings

---

## Will this affect my existing savegame?

Fresh can be added to an existing savegame safely. When you first load a save with Fresh enabled:

- **Existing goods** start tracking with age 0 (fresh). They are not immediately penalized.
- **Existing storages** are scanned and registered automatically.
- **Removing the mod** later is also safe - Fresh's save data is stored separately and the game ignores it if the mod is not present.

---

## How do difficulty presets interact with custom settings?

- **Preset mode** (Very Easy/Easy/Normal/Hard): A global multiplier scales all shelf lives. You cannot edit individual products - the Expiration tab is read-only showing the effective values.
- **Custom mode**: No global multiplier. Every product can be individually configured. Products start at their Normal-difficulty defaults when you first switch to Custom.
- **Switching back** to a preset from Custom discards your per-product changes and applies the preset multiplier to the mod defaults.

---

## What products are tracked?

Fresh comes with around 100 perishable products pre-configured, covering:

- Fresh produce (vegetables, fruit, mushrooms)
- Dairy (milk, cheese, eggs, butter)
- Fish (salmon, trout, farmed fish)
- Baked goods (bread, cake)
- Processed foods (cereal, chocolate, chips)
- Grains, flour, and seeds
- Cooking oils
- Canned and preserved goods
- Animal feed and silage
- Bales (grass, hay, straw)

See the [Shelf Life Table](reference-shelf-life.md) for the complete list with default values.

---

## What about DLC and mod products?

Fresh automatically detects fill types added by DLCs, maps, and other mods. By default, new fill types don't expire. You can configure them in the Fresh Menu → Settings → Expiration tab, under the "DLCs & Mods" section. The tooltip for each product shows which DLC or mod added it.

---

## Why don't animals, fuel, or building materials expire?

These products are pre-configured as **non-expiring** because expiration doesn't make sense for them:

- **Animals** are living creatures, not perishable goods
- **Fuel and energy** (diesel, DEF, electric charge) don't spoil in practical terms
- **Construction materials** (wood, cement, bricks) have indefinite shelf life
- **Manufactured goods** (furniture, clothes, pianos) don't degrade

These items are hidden from the Fresh Menu to reduce clutter. If you want something unusual like expiring fuel for extra realism, you can enable it through Custom difficulty settings.

---

## How do bales work?

Bales track the same way as other containers but with two special behaviors:

**1. Fermentation pauses aging.** When you wrap a grass bale to make silage, aging pauses during the fermentation period. Once fermentation completes, the bale begins aging as silage (12-month shelf life) rather than as grass (1-month shelf life). This rewards wrapping bales promptly.

**2. Expired bales are deleted.** Unlike vehicles and silos that remain as empty containers, a bale that fully expires is removed from the game entirely. There's no empty bale left behind.

---

## How do storage classes get detected?

Fresh assigns storage classes automatically based on container type:

| Container | Default Class |
|-----------|--------------|
| Pallets, big bags | Exposed |
| Open-top trailers/tippers | Exposed |
| Enclosed vehicles/tankers | Sheltered |
| Bales | Exposed |
| Feed troughs | Sheltered |
| Silos, production buildings | Indoor |
| Husbandry milk storage | Cooled |

If the automatic detection doesn't match your setup, use storage class overrides. See the [Storage Classes Guide](guide-storage-classes.md#storage-class-overrides) for how to override.

---

## What does the "Benefit Limit" setting do?

Each product has a ceiling on how much it benefits from better storage. For example, wheat has a benefit limit of **Indoor** - storing it in a Cooled or Frozen facility provides no extra benefit over Indoor storage. But strawberries have a benefit limit of **Frozen** and benefit from the best storage you can provide.

This models real-world food storage: freezing grain doesn't meaningfully extend its life beyond proper dry storage, but freezing produce makes a huge difference.

See the [Storage Classes Guide](guide-storage-classes.md#max-benefit-class) for details and examples.

---

## How can I see effective shelf life per storage class?

Open the Fresh Menu (Right Shift + F) → Shelf Life tab. When **Storage Class Aging** is enabled, the tab displays a table with columns for each storage class (Exposed through Frozen), showing the effective shelf life in months for every product. Cells are blank where a product's max benefit class is exceeded, so you can immediately see which storage types benefit each product.

When Storage Class Aging is disabled, the tab shows a single shelf life value per product.

---

## Can I see what's about to expire?

Yes, several ways:

- **Fresh Menu → Overview** - The right panel shows items expiring within 24h/48h/72h
- **Fresh Menu → Product Details** - Select a product to see per-storage breakdown with freshness distribution
- **Fresh Menu → Storage Details** - Select a storage to see all products it holds with expiry times
- **Info boxes** - Look at any storage and the info box shows time remaining with yellow warnings
- **Age distribution HUD** - Color-coded bars when near storages (blue/green/orange/red)
- **Daily notifications** - A summary notification appears each morning if anything expired overnight
