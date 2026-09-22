# Storage Classes Guide

Fresh assigns a storage class to every container based on its type and location. Better storage slows aging, extending the effective shelf life of your goods. This guide explains how the system works and how to make the most of it.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_Fresh/issues).

---

## The Six Storage Classes

Each storage class applies a multiplier to the base aging rate. Lower multipliers mean slower aging and longer effective shelf life.

| Class | Multiplier | Effective Shelf Life | Description |
|-------|-----------|---------------------|-------------|
| **Exposed** | 1.5x | 67% of base | Outdoors, no protection from elements |
| **Sheltered** | 1.0x | 100% of base | Covered or partially protected |
| **Indoor** | 0.8x | 125% of base | Enclosed building |
| **Cooled** | 0.3x | 333% of base | Refrigerated storage |
| **Frozen** | 0.10x | 1000% of base | Deep freeze, nearly stops aging |
| **Disabled** | 0x | Indefinite | Aging completely stopped |

### What This Means in Practice

A product with a 6-month shelf life at Normal difficulty:

| Storage Class | Effective Shelf Life |
|---------------|---------------------|
| Exposed | 4 months |
| Sheltered | 6 months |
| Indoor | 7.5 months |
| Cooled | 20 months |
| Frozen | 5 years |

The difference between leaving strawberries on an outdoor pallet versus putting them in cooled storage is dramatic.

*You can view these effective shelf lives in-game: open the Fresh Menu -> Shelf Life tab. When Storage Class Aging is enabled, it displays a table with per-storage-class values for every product.*

---

## How Storage Classes Are Assigned

Fresh automatically detects the storage class based on the container type and, for loose bales, pallets, big bags, and parked vehicles, on whether they stand under a roof:

| Container Type | Default Class | Rationale |
|----------------|--------------|-----------|
| **Pallets** | Exposed outdoors, Sheltered under a roof | Rain and sun reach a pallet in the open |
| **Big bags** | Exposed outdoors, Sheltered under a roof | Rain and sun reach a big bag in the open |
| **Vehicle compartments with a load heap** (tippers, seeders, forage wagons) | Sheltered with the cover closed; Exposed with it open or with no cover; Sheltered when parked under a roof | Each compartment is judged by its own cover |
| **Vehicle tanks and closed hoppers** (tankers, sprayers) | Sheltered | The load has no open heap |
| **Bales** | Exposed outdoors, Sheltered under a roof | Left in the field or yard, or stacked in a shed |
| **Feed troughs** (husbandry food) | Sheltered | Under roof at husbandry |
| **Silos and storage** (placeables) | Indoor | Enclosed building storage |
| **Production point storage** | Indoor | Factory/processing buildings |
| **Object storage** (warehouses) | Indoor | Enclosed building storage for items |
| **Milk storage** (husbandry milk) | Cooled | Refrigerated milk tanks |

### Bales and pallets under a roof

Fresh checks where each loose bale, pallet, and big bag stands. When you put one down under a shed, carport, or barn roof, it becomes **Sheltered** a second or two after it stops moving. Carry it back out and it returns to **Exposed**. Fresh also re-checks every loose item once an in-game hour, so building or selling a shed over a resting bale takes effect within the hour. Not every building counts as a roof; see [What counts as a roof](#what-counts-as-a-roof).

### Vehicles: covers and roofs

Fresh classes each compartment of a vehicle on its own. A compartment with a load heap is **Sheltered** while its tarp or cover is closed and **Exposed** while it is open, and the class changes as soon as you open or close the cover. On trailers built to open their tarp while tipping, tipping opens it and it stays open until you close it. A compartment that its cover does not reach counts as Exposed.

A vehicle parked under a roof becomes **Sheltered** once it is parked and nobody sits in it or its tractor; a roof never lowers a class, so a tanker stays Sheltered outdoors. Combines and trailers without a cover stay **Exposed** outside, because a grain tank lid is not a cover. Fresh also re-checks every vehicle once an in-game hour, so a vehicle under a roof turns Sheltered at the next hour even while someone sits in it. The roof check is the same one bales use, so the buildings listed in [What counts as a roof](#what-counts-as-a-roof) do not shelter a vehicle either.

After loading a savegame, bales and pallets show Exposed, and vehicles the class of their own covers, for a second or two until the first roof check runs.

### What counts as a roof

Fresh sees a roof only where two things meet at the spot an item or a parked vehicle stands: the building marks the floor there as a covered area, and the roof overhead is modeled as a building. Most sheds, carports, and barns have both. Some buildings and shelters lack one or the other, and Fresh cannot detect those as a roof:

- A road or river bank, even though some maps mark them as covered ground.
- Buildings whose roof is not modeled as a building, such as the small cow barn.
- Buildings that do not mark a covered floor area, such as some of the garden sheds sold in the shop, and mod buildings whose author did not mark one.
- Buildings that are part of the map itself, when the map author did not mark their floor as covered.
- A closed trailer's own roof: a pallet inside one counts as Exposed unless the trailer stands under a building roof.

If a shelter you use does not count, set the class yourself with a [storage class override](#storage-class-overrides).

---

## Max Benefit Class

Each product has a **maximum benefit class** that caps how much it benefits from better storage. This models real-world behavior - freezing milk doesn't preserve it the way freezing meat does.

| Max Benefit | Products (examples) | Effect |
|-------------|--------------------|----|
| **Sheltered** | Straw, chaff, forage, grass windrows | No benefit from Indoor, Cooled, or Frozen storage |
| **Indoor** | Grains, flour, oils, canned goods, sugar, chocolate | No benefit from Cooled or Frozen storage |
| **Cooled** | Dairy (milk, cheese, eggs), juice, onions, sugar beet | No benefit from Frozen storage |
| **Frozen** | Fresh produce, fish, baked goods, mushrooms | Benefits from all storage classes up to Frozen |

### How It Works

When a product is stored in a class better than its max benefit, the effective multiplier is capped at the max benefit class:

- **Strawberries** (max benefit: Frozen) in Frozen storage -> uses 0.10x multiplier (full benefit)
- **Wheat** (max benefit: Indoor) in Cooled storage -> uses 0.8x multiplier (capped at Indoor)
- **Wheat** (max benefit: Indoor) in Indoor storage -> uses 0.8x multiplier (full benefit)
- **Milk** (max benefit: Cooled) in Frozen storage -> uses 0.3x multiplier (capped at Cooled)

This means there's no point in building frozen storage for grain - a dry indoor silo gives the same benefit. But fresh produce benefits enormously from the best storage you can provide.

See the [Shelf Life Table](reference-shelf-life.md) for every product's max benefit class.

---

## Storage Class Strategy

### Fresh Produce and Dairy

These products expire fast (1-5 months) but benefit from Cooled or Frozen storage. Prioritize:

- Move fresh harvests to Cooled/Frozen storage quickly
- Don't leave pallets sitting outdoors - Exposed storage ages them 50% faster than baseline
- Dairy products max out at Cooled, so a fridge is sufficient

### Grains and Processed Goods

These products have longer shelf lives (6-24 months) and max out at Indoor storage. Standard silos and production buildings provide full benefit. No need for refrigeration.

### Bales

Bales in the open are Exposed; bales under a roof are Sheltered. Fresh grass windrow bales (1-month shelf life) are particularly vulnerable:

- Wrap grass bales for silage as soon as possible - fermentation pauses aging
- Dry grass bales last much longer (18 months) but still benefit from sheltered storage
- Stack bales in a shed or under a carport to move them from Exposed to Sheltered

### Animal Feed

Feed in husbandry troughs is classified as Sheltered. Most feed types (pig food, fish food) have moderate shelf lives and won't benefit from better storage beyond Indoor.

---

## Storage Class Overrides

If the automatic detection doesn't match your situation - for example, a shelter Fresh does not count as a roof or a refrigerated mod building - you can override the storage class.

Open the Fresh Menu (Right Shift + F) -> Settings tab -> Storage sub-tab. Each tracked storage shows its detected class and an override dropdown to change it.

For a building or vehicle, the class you choose replaces the detected one. The **Loose Items** entry works differently: the class you choose there is a **minimum** for every loose bale, pallet, and big bag. An item under a roof keeps Sheltered even when you choose Exposed, so choosing Exposed now behaves like Default. Choose Sheltered or better to give every loose item at least that class, roof or not.

---

## Interaction with Difficulty Presets

Storage class multipliers stack with difficulty presets. The difficulty preset scales the base shelf life, and the storage class multiplier scales the aging rate:

**Example: Strawberries (1-month base shelf life)**

| Difficulty | Storage | Effective Shelf Life |
|------------|---------|---------------------|
| Normal | Exposed | 0.67 months |
| Normal | Indoor | 1.25 months |
| Normal | Cooled | 3.3 months |
| Easy (x2) | Exposed | 1.3 months |
| Easy (x2) | Cooled | 6.7 months |
| Very Easy (x4) | Cooled | 13.3 months |

At Very Easy difficulty with Cooled storage, even strawberries last over a year - giving casual players plenty of breathing room while still adding the freshness mechanic.
