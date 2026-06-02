# Fresh

A Farming Simulator 25 mod that adds shelf life to your produce and bales - crops age over time and spoil if not sold or used.

> **Note:** This documentation was generated with AI assistance and may contain inaccuracies. If you spot an error, please [open an issue](https://github.com/rittermod/FS25_Fresh/issues).

## Key Features

- **Produce perishability** - Harvested crops, processed products, and baled forage age over time and eventually expire
- **Around 100 products** with research-based default shelf lives, from strawberries (1 month) to canned goods (2 years)
- **Storage classes** - Where you store goods matters: frozen storage extends shelf life 10x compared to leaving goods outdoors
- **Batch tracking** - FIFO system retrieves oldest items first, so nothing gets forgotten at the back
- **Visual feedback** - Color-coded age bars, expiry warnings in info boxes, and daily loss notifications
- **Fresh Menu** - Inventory overview, product and storage details, loss statistics, shelf life reference, and full settings customization
- **Difficulty presets** - Very Easy (4x shelf life) through Hard (half shelf life), plus a Custom mode for per-product control
- **Reusable custom defaults** - Advanced users can set shelf lives once in an external file that applies to all savegames and survives mod updates
- **Multiplayer support** - Server-authoritative with full client synchronization

## Download

**[Latest release on GitHub](https://github.com/rittermod/FS25_Fresh/releases/latest)**

## Installation

1. Download the latest `FS25_Fresh.zip` from the link above
2. Place the ZIP file in your FS25 mods folder (do not extract it)
3. Enable the mod in the in-game mod manager

## Compatibility

| | |
|---|---|
| **Game** | Farming Simulator 25 |
| **Multiplayer** | Supported (server-authoritative) |
| **Known conflicts** | None currently known |

Fresh tracks all vanilla FS25 products plus any fill types added by DLCs, maps, or other mods. New fill types default to non-expiring unless configured in the settings.

## Documentation

**[Mod Overview](overview.md)** - How the mod works: what changes from vanilla FS25, how aging and batches work, and what to expect.

### Guide

- [Storage Classes](guide-storage-classes.md) - How storage location affects shelf life, the 6 storage classes, and the max benefit system
- [Custom Defaults](guide-custom-defaults.md) - Advanced: a reusable per-install config file that applies to all savegames and survives mod updates

### Reference

- [Shelf Life Table](reference-shelf-life.md) - Every perishable product with its default shelf life and max benefit class
- [Settings](reference-settings.md) - All configurable options with defaults and descriptions

### FAQ

- [Frequently Asked Questions](faq.md) - Common questions about expiration, storage, multiplayer, and customization
