# Fresh - Overview

Fresh transforms farm logistics in Farming Simulator 25. Instead of produce lasting forever, your goods now have realistic shelf lives - sell them in time or lose them to spoilage.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_Fresh/issues).

---

## What Changes

In vanilla FS25, you can harvest wheat, store it indefinitely, and sell it months or years later at the perfect seasonal price. There is no penalty for hoarding.

Fresh changes this. Every perishable product now has a shelf life measured in game months. Strawberries last 1 month. Wheat lasts 12 months. Canned goods last 2 years. When a product reaches its shelf life, it expires and is removed from the game - along with any revenue you would have earned.

This creates real economic decisions:

- **Sell or hold?** Waiting for a better price is risky if your goods might expire first
- **Logistics matter** - You need to move perishable goods through your supply chain efficiently
- **Storage choices count** - Proper storage (cooled, frozen) dramatically extends shelf life

---

## How Aging Works

Fresh ages products every game hour. Each hour, every tracked product moves slightly closer to its expiration threshold.

The aging rate depends on your game's **days per period** setting. Whether you play with 1 day per month or 30 days per month, products expire after the same number of in-game months. A product with a 3-month shelf life expires after 3 months regardless of your time settings.

### Time Remaining Display

When you look at a storage, vehicle, or bale containing perishable goods, the info box shows the time remaining before the oldest batch expires:

- **"Expires in 2.5 months"** - Plenty of time
- **"Expires in 3 days"** - Getting close (text turns yellow)
- **"Expires in 6 hours"** - Sell now or lose it (text turns yellow)
- **"Expired"** - Already gone

The warning color threshold is configurable (6h, 12h, 24h, 48h, or 72h before expiration).

---

## Batch Tracking

Fresh doesn't treat all goods in a container as one lump. Instead, it tracks **batches** - groups of the same product added at roughly the same time.

### Why Batches Matter

When you harvest 5,000 liters of wheat in March and another 5,000 in June, Fresh tracks these as two separate batches with different ages. The March wheat is 3 months older than the June wheat, and it will expire first.

### Oldest First (FIFO)

When you or the game retrieves products from storage, Fresh uses a **First In, First Out** system. The oldest batch is consumed first. This means:

- Selling from a silo takes the oldest grain first
- Production buildings consume the oldest input materials first
- Loading a trailer from storage takes the oldest goods first

This prevents the situation where fresh goods are used while older ones sit forgotten and expire.

### Batch Merging

To keep things efficient, Fresh merges batches that are close in age (within about 7 game hours). If you add wheat to a silo repeatedly over a few hours, those small additions merge into a single batch rather than creating dozens of tiny ones.

---

## What Gets Tracked

Fresh tracks perishable goods across five types of storage:

### Vehicles

Pallets, trailers, tankers, and any vehicle with fill capacity. When you load goods onto a vehicle, Fresh tracks them. When you sell or unload, the batches transfer with their ages preserved.

### Bales

Grass, straw, hay, and silage bales. Bales age based on their contents - grass windrows spoil within 1 month, while dry grass lasts 18 months. Wrapped bales undergoing **fermentation** pause aging until fermentation completes, then age as silage.

When a bale expires completely, it is deleted from the game (unlike vehicles, which stay as empty containers).

### Silos and Storage Points

Farm silos, selling stations, and any placeable storage. These are typically classified as Indoor storage, giving a moderate shelf life bonus.

### Production Points

Internal storage at production facilities. When a factory produces goods (like flour from wheat), the output starts fresh. Ingredients consumed by the factory are taken oldest-first.

### Husbandry Feed

Animal food troughs at husbandries. Feed placed in troughs ages over time, and animals consume the oldest feed first.

### Age Preservation on Transfer

When goods move between storage types - from a silo to a trailer, from a trailer to a selling point - their age transfers with them. Loading month-old wheat onto a trailer doesn't reset its age to fresh.

---

## Storage Classes

Where you store goods affects how quickly they age. Fresh has six storage classes, from worst to best:

| Class | Aging Rate | Example |
|-------|-----------|---------|
| **Exposed** | 1.5x faster | Pallets and bales left outdoors |
| **Sheltered** | 1.0x (baseline) | Covered storage, feed troughs |
| **Indoor** | 0.8x slower | Enclosed silos, production buildings |
| **Cooled** | 0.3x slower | Refrigerated storage |
| **Frozen** | 0.05x slower | Freezer storage (nearly stops aging) |
| **Disabled** | No aging | Aging completely stopped |

Each product also has a **max benefit class** that caps how much it benefits from better storage. For example, dairy products max out at Cooled - putting milk in a freezer doesn't help more than a fridge.

See the [Storage Classes Guide](guide-storage-classes.md) for the full details.

---

## Visual Feedback

### Info Box

When you approach a vehicle, silo, or bale containing perishable goods, the standard info box displays:

- The **time remaining** before the oldest batch expires
- The **amount expiring** and when
- Text turns **yellow** when expiration is near (configurable threshold)

### Age Distribution HUD

A separate HUD panel shows color-coded freshness bars when you're near a storage:

- **Blue** - Fresh (75-100% of shelf life remaining)
- **Green** - Good (50-75% remaining)
- **Orange** - Warning (25-50% remaining)
- **Red** - Critical (0-25% remaining)

This gives you an at-a-glance view of how much of your stored goods are near expiration. The age display can be toggled on/off in settings.

### Daily Loss Notifications

At the start of each game day, Fresh shows a summary notification if any products expired during the previous day, including the total amount lost.

---

## Fresh Menu

Press **Right Shift + F** to open the Fresh Menu. It has four tabs:

### Inventory Overview

A summary of all perishable goods across your farm:

- **Left table** - All tracked product types with total amounts, expiring quantities, and time to next expiry
- **Right table** - Items expiring soon (within 24h, 48h, or 72h), showing specific storage locations
- Sort by product type, expiring amount, or next expiry time

### Loss Statistics

Track what you've lost to spoilage:

- **Summary cards** - Losses for today, this month, last 12 months, and all time (amount and estimated value)
- **Product breakdown** - Which products you lose the most of
- **Recent losses** - Detailed log of individual expiration events with dates and locations

### Shelf Life

A read-only reference listing every perishable product with its active shelf life. When **Storage Class Aging** is enabled, the tab displays a table with columns for each storage class (Exposed through Frozen), showing the effective shelf life in months for every product in each class. Cells are left blank where a product's max benefit class is exceeded, making it easy to see at a glance which storage types actually help each product. When Storage Class Aging is disabled, a single shelf life value is shown per product.

### Settings

Full customization of the mod's behavior:

- **Difficulty presets** - Quick adjustment of all shelf lives at once
- **Per-product shelf lives** - Individual control over every product's expiration time
- **Max benefit classes** - Adjust the storage class ceiling per product
- **Storage class overrides** - Override automatic storage class detection
- **Global toggles** - Enable/disable expiration, storage class aging, warnings, age display, warning threshold

See the [Settings Reference](reference-settings.md) for full details.

---

## Controls

| Key | Action | Where |
|-----|--------|-------|
| **Right Shift + F** | Open/close Fresh Menu | In-game |

*The keybinding can be remapped in the game's input settings.*

---

## Console Commands

Fresh includes console commands for inspection and debugging. Open the game console (~) and type `fList` to see all tracked containers. See the [Settings Reference](reference-settings.md#console-commands) for the full command list.

---

## Further Reading

- [Storage Classes Guide](guide-storage-classes.md) - Deep dive into how storage affects shelf life
- [Shelf Life Table](reference-shelf-life.md) - Every product with its default shelf life
- [Settings Reference](reference-settings.md) - All configurable options
- [FAQ](faq.md) - Common questions and answers
