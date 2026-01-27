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

- Early access release - testing and feedback welcome
- Most storage types supported: vehicles, bales, silos, productions, husbandries
- Supports products from basegame, DLCs, and maps/mods
- Customize shelf lives via the Fresh Menu

## Features

### Fresh Menu (Right Shift+F)
- **Inventory Overview**: See all perishables at a glance with oldest ages
- **Loss Statistics**: Track what you've lost and when
- **Settings**: Customize shelf lives for any product

### Settings & Customization
- Configure shelf life for any product (basegame, DLCs, maps/mods)
- Enable/disable expiration globally or per-product
- Toggle age distribution display on/off
- Per-savegame settings
- Multiplayer: host/admin controls settings for all players

### Loss Tracking
- All expirations recorded in loss log
- Daily notifications summarizing your farm's losses
- View loss history in menu

### Perishable products
- 100+ products with realistic shelf lives (fresh produce spoils in days, grains last months, canned products up to 3 years)
- 4 bale types: Fresh Grass (days), Hay (18 months), Straw (24 months), Silage (12 months)
- Wrapped grass bales begin aging after fermentation completes

### Tracking Locations
- Vehicles: trailers, tankers, combine tanks, etc.
- Bales and pallets: on the ground and in storage buildings
- Placeables: silos, productions, husbandries, object storage

### Visual Feedback
- Age distribution bars when near placeables/vehicles (color-coded: blue=fresh, green=good, orange=warning, red=critical)
- Expiry countdown on vehicles and bales ("Expires in: X days")
- Expiring amounts shown per fill type for placeables
- Warning highlight when products near expiration
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

## Installation

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

### 0.7.1.0 (Alpha - 2026-01-27)
- Fixed TMR mixer output tracking - FORAGE amount now correctly tracks all ingredients
- Fixed pig feed (PIGFOOD) losing age when deposited into pigsty - mixture ingredients now preserve source age

### 0.7.0.0 (Alpha - 2026-01-24)
- Added support for ALL fillTypes - basegame, DLCs, and maps/mods now configurable
- Improved Settings sorting - products with types appear first for easier navigation
- Added tooltips in Settings showing fillType details (internal name, type classification)

### 0.6.1.0
- Fixed age distribution showing on empty vehicles/placeables (floating point precision issue)

### 0.6.0.0 (Alpha - 2026-01-23)
- Added age distribution HUD: colored freshness bars appear when near placeables and vehicles
- Added toggle in Settings to enable/disable age distribution display
- Fixed freshness display to show per fillType (vehicles with multiple products now show all)
- Fixed expiration info only showing for perishable fillTypes

### 0.5.0.0 (Early Access - 2026-01-13)
- Added Fresh Menu (Right Shift+F) with tabbed interface for inventory, statistics, and settings
- Added Inventory Overview screen showing all perishables by type with oldest ages
- Added Loss Statistics screen tracking total losses and breakdown by product
- Added configurable shelf lives: customize expiration time for any product
- Added global enable/disable option for expiration system
- Added per-savegame settings with multiplayer sync (host/admin controls)
- Added loss tracking: all expirations now recorded in loss log
- Added daily notifications summarizing farm losses
- Improved transfer handling: batch ages preserved when moving between containers
- Rebuilt core architecture for better stability and maintainability

### 0.4.0.0 (Alpha 5 - 2025-12-28)
- Added placeable storage tracking: silos, production storage, and husbandry storage now age goods
- Added husbandry feed tracking: feed troughs in animal barns track perishable feed
- Added expiring count display for placeables (shows amount nearly expired per fill type)
- Added console commands for storage type (`fList storage` or `fList s`)
- Added multiplayer sync for placeable storage

### 0.3.0.0 (Alpha 4 - 2025-12-27)
- Added bulk vehicle tracking: trailers, tankers, and combine tanks now track perishable contents
- Expanded from pallets only to all vehicles with fill capacity (114 vehicle types)
- Console commands now use "vehicle" type instead of "pallet" for consistency

### 0.2.1.0 (Alpha 3 - 2025-12-27)
- Added expiring item counts in storage HUD ("X expiring" with warning highlight)
- Added FIFO retrieval from storage (oldest items spawn first)
- Added multiplayer sync for storage expiring counts
- Improved code documentation

### 0.2.0.0 (Alpha 2 - 2025-12-26)
- Added bale perishability with 4 forage types (grass, hay, straw, silage)
- Added expiry display when looking at bales
- Added warning highlight when bales near expiration
- Added bale storage aging (bales continue aging in barns/sheds)
- Added multiplayer sync for bale ages
- Added fermenting bale handling (wrapped grass ages after fermentation completes)
- Updated console commands with type filtering (pallet/bale/all)

### 0.1.0.0 (Alpha 1 - 2025-12-25)
- Initial alpha release
- Added perishable goods system for 100 product types across 10 categories
- Added age tracking for pallets and object storage (barns, sheds)
- Added expiry display when looking at pallets ("Expires in: X hours/days/months")
- Added warning highlight when produce nears expiration
- Added automatic removal of expired goods with player notification
- Added multiplayer support with server-authoritative aging
- Added savegame persistence for all batch ages

## License

This mod is provided as-is for personal use with Farming Simulator 25.

## Credits

- **Author**: [Ritter](https://github.com/rittermod)

## Support

Found a bug or have a feature request? [Open an issue](https://github.com/rittermod/FS25_Fresh/issues)

---

*Fresh: Because hoarding should have consequences.*
