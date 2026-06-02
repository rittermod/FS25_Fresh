# Changelog

1.0.1.0-dev.2:
- Added optional external config (modSettings/FS25_Fresh/customDefaults.xml) to add or override shelf life, storage class and aging multipliers for any crop - including custom map/mod crops - without editing the mod (update-safe, re-read each launch, server-side in multiplayer)
- Added user guide documentation for the custom defaults config file (setup, precedence, schema, multiplayer)
- Added Ukrainian localization - contributed by sava4903-coder
- Improved stability: a rare error while aging or expiring one item no longer interrupts the rest of the hourly/daily update

1.0.1.0-dev.1:
- Fixed near-empty containers (under 1 L, e.g. a combine grain-tank leftover) showing as "0 L" rows in the inventory menus and skewing the displayed expiry

1.0.0.2:
- Fixed game crash/lock when mounting horses on Hof Bergmann map with horse addon pack

1.0.0.1:
- Fixed spurious error log "Failed to register RM_FRESH_MENU action" caused by benign duplicate input registration

1.0.0.0:
- Added Storage Details tab - per-product breakdown with age distribution, storage class, expiry times, and 4-category filter with shop icons
- Added Product Details tab - per-storage breakdown with age distribution across Fresh/Good/Warning/Critical buckets
- Added storage class icons to HUD, expiring soon table, and loss log with thick stroke variants for small-size legibility
- Added custom menu icons for all 6 tabs (Lucide icons)
- Added German localization - contributed by Roleplayboy
- Updated all translations (French, Italian, Swedish, German) to cover new detail tabs and storage features
- Improved settings UX: master Enable switch greys out all other settings, dependency toggles hide/show related controls and sub-tabs
- Improved menu polish: keyboard/controller navigation, table spacing, naming consistency
- Localized all remaining hardcoded English strings
- Rebalanced frozen multiplier from 0.05 to 0.10 (20x to 10x life extension)
- Adjusted shelf lives and storage class limits for 15+ products to better reflect real-world storage behavior
- Fixed dedicated server not recognizing third-party mod products on startup
- Fixed client HUD not showing freshness for products configured only via user settings
- Fixed incorrect maxBenefitClass for Lettuce, Potatoes, Sugarcane, Salmon/Trout Fry, and Butter
- Fixed storage list showing empty product entries for containers with zero fill level

0.10.0.0 (Beta - 2026-03-14):
- Added storage classes: storages are auto-classified (Exposed/Sheltered/Indoor/Cooled/Frozen/Disabled) affecting aging speed  - browse in new Storage tab, override per-storage, and cap per-product max benefit in Settings
- Improved Shelf Life tab: shows effective shelf life across all storage classes in a table layout
- Improved settings: consolidated into tabbed pages with per-product configuration
- Added user guide documentation site
- Fixed empty food troughs not being registered on load
- Fixed storages list showing other farms' storages in multiplayer

0.9.0.0 (Beta - 2026-02-10):
- Added Shelf Life tab to Fresh Menu - list all perishable products with their active shelf life
- Added difficulty presets (Very Easy/Easy/Normal/Hard/Custom) - adjust all shelf lives with a single setting
- Reorganized Settings into tabbed pages: general settings, basegame products, and DLC & Mods products
- Added "Reset to Defaults" button to restore all settings to mod defaults
- Added fill type source detection - tooltips now show whether a product is from basegame, DLC, mod, or map
- Expanded default configuration with 130+ non-expiring fill types (animals, wood, fuel, manufactured goods, etc.)
- Added more expiration period options (4 months, 5 months, 1.5 years, 5 years)
- Improved settings list by hiding irrelevant fill types (animals, cut crops, fuels, intermediates, etc.) - reduced visible list from 200+ to ~100 relevant products
- Added French localization
- Added Swedish localization

0.8.1.0 (Beta - 2026-01-31):
- Fixed products changed to "never expire" still showing as expiring in overview, HUD, and age display

0.8.0.0 (Beta - 2026-01-29):
- Reworked expiry warnings to use in-game time remaining - a 24h warning now means 24 hours regardless of product type or days-per-month setting
- Added configurable warning threshold in Settings (6h/12h/24h/48h/72h) - choose when expiry warnings appear
- Improved expiry display consistency - all storage types now show expiring amount and time remaining (e.g., "-1,000 l in 24h")
- Added partial expiry display for vehicles - shows expiring volume when only some contents are near expiry
- Improved time display - remaining time now uses intuitive breakpoints (hours/days/months)
- Unified status colors across HUD and menu to match FS25 palette
- Added Italian localization - contributed by @FirenzeIT

0.7.2.0 (Alpha - 2026-01-28):
- Added age distribution HUD for bales - colored freshness bar now appears when looking at bales

0.7.1.0 (Alpha - 2026-01-27):
- Fixed TMR mixer output tracking - FORAGE amount now correctly tracks all ingredients
- Fixed pig feed (PIGFOOD) losing age when deposited into pigsty - mixture ingredients now preserve source age
- Fixed containers not starting to age after enabling expiration for a previously disabled product
- Fixed vehicle showing wrong product freshness after refilling with a product set to 'do not expire'
- Fixed false error log when registering Fresh Menu keybinding in vehicle context

0.7.0.0 (Alpha - 2026-01-24):
- Added support for ALL fillTypes - basegame, DLCs, and maps/mods now configurable
- Improved Settings sorting - products with types appear first for easier navigation
- Added tooltips in Settings showing fillType details (internal name, type classification)

0.6.1.0:
- Fixed age distribution showing on empty vehicles/placeables (floating point precision issue)

0.6.0.0 (Alpha - 2026-01-23):
- Added age distribution HUD: colored freshness bars appear when near placeables and vehicles
- Added toggle in Settings to enable/disable age distribution display
- Fixed freshness display to show per fillType (vehicles with multiple products now show all)
- Fixed expiration info only showing for perishable fillTypes

0.5.0.0 (Early Access - 2026-01-13):
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

0.4.0.0 (Alpha 5 - 2025-12-28):
- Added placeable storage tracking: silos, production storage, and husbandry storage now age goods
- Added husbandry feed tracking: feed troughs in animal barns track perishable feed
- Added expiring count display for placeables (shows amount nearly expired per fill type)
- Added console commands for storage type (`fList storage` or `fList s`)
- Added multiplayer sync for placeable storage

0.3.0.0 (Alpha 4 - 2025-12-27):
- Added bulk vehicle tracking: trailers, tankers, and combine tanks now track perishable contents
- Expanded from pallets only to all vehicles with fill capacity (114 vehicle types)
- Console commands now use "vehicle" type instead of "pallet" for consistency

0.2.1.0 (Alpha 3 - 2025-12-27):
- Added expiring item counts in storage HUD ("X expiring" with warning highlight)
- Added FIFO retrieval from storage (oldest items spawn first)
- Added multiplayer sync for storage expiring counts
- Improved code documentation (removed development references)

0.2.0.0 (Alpha 2 - 2025-12-26):
- Added bale perishability with 4 forage types (grass, hay, straw, silage)
- Added expiry display when looking at bales
- Added warning highlight when bales near expiration
- Added bale storage aging (bales continue aging in barns/sheds)
- Added multiplayer sync for bale ages
- Added fermenting bale handling (wrapped grass ages after fermentation completes)
- Updated console commands with type filtering (pallet/bale/all)

0.1.0.0 (Alpha 1 - 2025-12-25):
- Initial alpha release
- Added perishable goods system for 65 product types with research-based shelf lives
- Added age tracking for pallets and object storage (barns, sheds)
- Added age display when looking at pallets ("Age: X days")
- Added warning highlight when produce nears expiration
- Added automatic removal of expired goods with player notification
- Added multiplayer support with server-authoritative aging
- Added savegame persistence for all batch ages
