# Fresh

Fresh adds shelf life to your products - crops age over time and will spoil if not sold or used!

Fresh brings perishable products to Farming Simulator 25. Your harvested crops, processed goods, and baled forage now have realistic shelf lives - leafy vegetables spoil quickly, while grains and canned products last much longer. Leave produce sitting too long and it will expire and be lost! Customize shelf lives to match your playstyle via the Fresh Menu.

**[User Guide](https://rittermod.github.io/FS25_Fresh/)**

Found a bug? [Open an issue](https://github.com/RitterMod/FS25_Fresh/issues)

## Why Fresh?

Vanilla FS25 lets you stockpile products indefinitely, waiting for the perfect price. Fresh changes the game:

- **Strategic timing**: Sell before products expire or lose everything
- **Active management**: Check ages, track losses, prioritize older stock
- **Realistic farming**: Real farms don't have infinite shelf life
- **Your rules**: Set expiration times to match your playstyle

## Usage

- Install the mod and play normally
- Open Fresh Menu with Right Shift+F to view inventory, stats, and settings
- Check expiry by looking at any vehicle, bale, or storage in the info box
- Sell or process produce before expiration to avoid losses
- Customize shelf lives in Settings if defaults don't suit your playstyle

## Features

### Fresh Menu
- **Inventory Overview**: See all perishables at a glance with their oldest ages
- **Product Details**: Drill into any product - per-storage age breakdown across Fresh/Good/Warning/Critical buckets
- **Storage Details**: Drill into any storage - per-product breakdown with age distribution, storage class, expiry times, and category filter
- **Loss Statistics**: Track what you've lost and when
- **Shelf Life**: Browse all products with effective shelf life per storage class
- **Settings**: Customize shelf lives for any product and storage class benefits

### Storage Classes
- Storages are auto-classified based on type: Exposed, Sheltered, Indoor, Cooled, Frozen, or Disabled (no aging)
- Each class applies an aging speed multiplier - better storage means slower spoilage
- Override storage class per-storage via Settings
- Set per-product max benefit class to cap how much a storage class can help

### Visual Feedback
- Age distribution bars when near placeables, vehicles, and bales (color-coded: blue=fresh, green=good, orange=warning, red=critical)
- Storage class icons in HUD, expiring soon table, and loss log
- Expiry countdown on vehicles and bales ("Expires in: X hours/days")
- Expiring amount and time remaining shown per fill type on placeables and husbandries (e.g., "-1,000 l in 24h")
- Warning highlight when products near expiration (configurable threshold)
- Notification when products expire and are removed

### Perishable Products
- 100+ products with realistic shelf lives (perishable produce spoils in days, grains last months, canned products up to 3 years)
- 130+ non-expiring products pre-configured (animals, wood, fuel, manufactured goods, etc.)
- 4 bale types: Fresh Grass (days), Hay (18 months), Straw (24 months), Silage (12 months)
- Wrapped grass bales begin aging after fermentation completes

### Settings & Customization
- Difficulty presets (Very Easy/Easy/Normal/Hard) or Custom for individual control
- Configure shelf life for any product (basegame, DLCs, maps/mods)
- Enable/disable expiration globally or per-product
- Configurable warning threshold (6h/12h/24h/48h/72h)
- Reset all settings to defaults with one click
- Optional external config file (`modSettings/FS25_Fresh/customDefaults.xml`) to add or override shelf life, storage class, and aging multipliers for any crop - including custom map/mod crops - without editing the mod (update-safe, server-side in multiplayer)
- Per-savegame settings
- Multiplayer: host/admin controls settings for all players

### Loss Tracking
- All expirations recorded in loss log
- Daily notifications summarizing your farm's losses
- View loss history in menu

### Tracking Locations
- Vehicles: trailers, tankers, combine tanks, etc.
- Bales and pallets: on the ground and in storage buildings
- Placeables: silos, productions, husbandries, object storage

### How It Works
- Each harvest or production run is tracked as a separate batch with its own age
- Oldest items retrieved first from storage (FIFO)
- Expired products automatically removed
- Batch ages preserved during transfers between containers
- Multiplayer support (server-authoritative)
- Ages saved with your game

## Limitations & Known Issues
- No loose item tracking (loose grass, grains, etc. on the ground)
- Silo extensions are tracked separately rather than as a shared pool

## Installation

### From itch.io
1. Download the latest release from [itch.io](https://rittermod.itch.io/fs25-fresh)

### From GitHub Releases
1. Download the latest release from [Releases](https://github.com/rittermod/FS25_Fresh/releases)
2. Place the `.zip` file in your mods folder:
   - **Windows**: `%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\`
   - **macOS**: `~/Library/Application Support/FarmingSimulator2025/mods/`
3. Enable the mod in-game

### Manual Installation
1. Clone or download this repository
2. Copy the `FS25_Fresh` folder to your mods folder
3. Enable the mod in-game

## Compatibility

- **Game Version**: Farming Simulator 25
- **Multiplayer**: Supported (server-authoritative aging)
- **Platform**: PC (Windows/macOS)

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for the full version history.

## License

This mod is provided as-is for personal use with Farming Simulator 25.

## Credits

- **Author**: [Ritter](https://github.com/rittermod)

## Support

Found a bug or have a feature request? [Open an issue](https://github.com/rittermod/FS25_Fresh/issues)

---

*Fresh: Because hoarding should have consequences.*
