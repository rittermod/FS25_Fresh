# Fresh (In Development)

Fresh adds shelf life to your produce and bales - crops age over time and will spoil if not sold or used!

## Why Fresh?

Vanilla FS25 lets you stockpile goods indefinitely, waiting for the perfect price. Fresh changes the game:

- **Strategic timing**: Sell before goods expire or lose everything
- **Active management**: Check ages, prioritize older stock
- **Realistic farming**: Real farms don't have infinite shelf life

Fresh tracks your goods using a batch system - each harvest or production run is tracked separately with its own age. Oldest stock expires first (FIFO), just like real inventory management.

## Development Status

**Current Phase:** Alpha 5 (Placeable Storage Perishability)

### What's Working

**Perishable Goods**
- 100 products with realistic shelf lives (fresh produce spoils in days, grains last months, canned goods up to 3 years)
- 4 bale types: Fresh Grass (days), Hay (18 months), Straw (24 months), Silage (12 months)
- Wrapped grass bales age after fermentation completes

**Tracking Locations**
- Vehicles: trailers, tankers, combine tanks, etc.
- Bales and pallets: on the ground and in storage buildings
- Placeables: silos, productions, husbandries, object storage

**Visual Feedback**
- Expiry countdown on vehicles and bales ("Expires in: X days")
- Expiring amounts shown per fill type for placeables
- Warning highlight when goods near expiration
- Notification when goods expire and are removed

**Inventory & Technical**
- Oldest items retrieved first from storage (FIFO)
- Expired goods automatically removed
- Multiplayer support (server-authoritative)
- Ages saved with your game

### Planned

- Transfer chain (age flows between containers)
- Configurable shelf life settings

## Want to Help?

The mod is not ready for public testing yet, but if you're interested in testing beta builds when they are available join the discord channel #fs25_fresh on server https://discord.gg/KXFevNjknB 

![Fresh icon](assets/fresh_icon.png)

---

*Fresh: Because hoarding should have consequences.*
