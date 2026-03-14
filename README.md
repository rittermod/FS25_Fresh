# Fresh

Fresh adds shelf life to your products - crops age over time and will spoil if not sold or used!

Fresh brings perishable products to Farming Simulator 25. Your harvested crops, processed goods, and baled forage now have realistic shelf lives. Fresh vegetables spoil quickly, while canned products and grains last much longer. Bales of grass spoil within days, while silage stays fresh for months. Plan your logistics carefully - leave produce or bales sitting too long and they will expire and be lost! Customize shelf lives to match your playstyle via the in-game Settings menu.

## Why Fresh?

Vanilla FS25 lets you stockpile products indefinitely, waiting for the perfect price. Fresh changes the game:

- **Strategic timing**: Sell before products expire or lose everything
- **Active management**: Check ages, track losses, prioritize older stock
- **Realistic farming**: Real farms don't have infinite shelf life
- **Your rules**: Customize expiration times to match your playstyle

Fresh tracks your products using a batch system - each harvest or production run is tracked separately with its own age. Oldest stock expires first, just like real inventory management.

## Notes

- Beta release - testing and feedback welcome
- Most storage types supported: vehicles, bales, silos, productions, husbandries
- Supports products from basegame, DLCs, and maps/mods
- Customize shelf lives via the Fresh Menu

## Features

### Fresh Menu (Right Shift+F)
- **Inventory Overview**: See all perishables at a glance with oldest ages
- **Loss Statistics**: Track what you've lost and when
- **Shelf Life**: Browse all products with effective shelf life per storage class
- **Storages**: Browse all storages with their class, fill status, and store icons
- **Settings**: Customize shelf lives for any product

### Storage Classes
- Storages are auto-classified based on type: Exposed, Sheltered, Indoor, Cooled, Frozen, or Disabled (no aging)
- Each class applies an aging speed multiplier — better storage means slower spoilage
- Override storage class per-storage via Settings
- Set per-product max benefit class to cap how much a storage class can help

### Settings & Customization
- Difficulty presets (Very Easy/Easy/Normal/Hard) - adjust all shelf lives at once, or use Custom for individual control
- Configure shelf life for any product (basegame, DLCs, maps/mods)
- Per-product max benefit class to limit storage class effectiveness
- Products organized by basegame vs DLC & Mods tabs
- Enable/disable expiration globally or per-product
- Configurable warning threshold (6h/12h/24h/48h/72h) - choose when expiry warnings appear
- Toggle age distribution display on/off
- Reset all settings to defaults with one click
- Per-savegame settings
- Multiplayer: host/admin controls settings for all players

### Loss Tracking
- All expirations recorded in loss log
- Daily notifications summarizing your farm's losses
- View loss history in menu

### Perishable products
- 100+ products with realistic shelf lives (fresh produce spoils in days, grains last months, canned products up to 3 years)
- 130+ non-expiring products pre-configured (animals, wood, fuel, manufactured goods, etc.)
- 4 bale types: Fresh Grass (days), Hay (18 months), Straw (24 months), Silage (12 months)
- Wrapped grass bales begin aging after fermentation completes

### Tracking Locations
- Vehicles: trailers, tankers, combine tanks, etc.
- Bales and pallets: on the ground and in storage buildings
- Placeables: silos, productions, husbandries, object storage

### Visual Feedback
- Age distribution bars when near placeables, vehicles, and bales (color-coded: blue=fresh, green=good, orange=warning, red=critical)
- Expiry countdown on vehicles and bales ("Expires in: X hours/days")
- Expiring amount and time remaining shown per fill type on placeables and husbandries (e.g., "-1,000 l in 24h")
- Warning highlight when products near expiration (configurable threshold)
- Notification when products expire and are removed

### Inventory Behavior
- Oldest items retrieved first from storage
- Expired products automatically removed
- Batch ages preserved during transfers between containers

### Technical
- Multiplayer support (server-authoritative)
- Ages saved with your game

## Limitations

- No loose item tracking (loose grass, grains, etc on the ground)

## Known Issues

**General:**
- Store-bought pallets may show double the actual amount

**Multiplayer:**
- Clients may not see "Expires in" info when looking at bales

**Edge Cases:**
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

## Usage

- Install the mod and play normally
- Open Fresh Menu with Right Shift+F to view inventory, stats, and settings
- Check expiry by looking at any vehicle, bale, or storage in the info box
- Sell or process produce before expiration to avoid losses
- Customize shelf lives in Settings if defaults don't suit your playstyle

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
