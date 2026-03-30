# b0b-world Sprite & Tile Inventory

Complete reference for every asset pack. All tile IDs verified from labeled PNG strips.

---

## Asset Files Summary

| File | Source | Size | Grid | Tile Size | Count |
|------|--------|------|------|-----------|-------|
| `donarg-office-32.png` | Donarg (itch.io) | 512x1024 | 16 cols x 32 rows | 32x32 | 512 |
| `masalimov-tiles.png` | Masalimov (itch.io) | 224x128 | 7 cols x 4 rows | 32x32 | 28 |
| `masalimov-chars.png` | Masalimov (itch.io) | 320x192 | 10 cols x 6 rows | 32x32 | 5 chars |
| `businessman.png` | pixelserial (itch.io) | 128x256 | 4 cols x 8 rows | 32x32 | 1 char |
| `policeman.png` | pixelserial (itch.io) | 128x256 | 4 cols x 8 rows | 32x32 | 1 char |
| `gentle-obj.png` | AI Town (CC-BY 4.0) | 1440x1024 | 45 cols x 32 rows | 32x32 | 1440 |
| `rpg-tileset.png` | AI Town (MIT) | 1600x1600 | 100 cols x 100 rows | **16x16** | 10000 |
| `magecity.png` | AI Town (MIT) | 256x1450 | 8 cols x ~45 rows | 32x32 | ~360 |
| `32x32folk.png` | AI Town (CC-BY 4.0) | 384x256 | 4 chars x 2 rows | 32x32 | 8 chars |
| `campfire.png` | AI Town (CC-BY 4.0) | 128x32 | 4 frames x 1 row | 32x32 | 4 frames |
| `gentlesparkle32.png` | AI Town (CC-BY 4.0) | 96x96 | 3x3 | 32x32 | 9 frames |
| `gentlewaterfall32.png` | AI Town (CC-BY 4.0) | 192x320 | 6 cols x 10 rows | 32x32 | 60 frames |
| `windmill.png` | AI Town (CC-BY 4.0) | 624x624 | 3x3 (8 filled) | 208x208 | 8 frames |
| `workers1.png` | B&W Surreal Office (CC0) | 384x256 | same as 32x32folk | 32x32 | 8 chars |
| `workers2.png` | B&W Surreal Office (CC0) | 384x256 | same as 32x32folk | 32x32 | 8 chars |
| `workerface1.png` | B&W Surreal Office (CC0) | 128x64 | portraits | 16x16 | 8 faces |
| `workerface2.png` | B&W Surreal Office (CC0) | 128x64 | portraits | 16x16 | 8 faces |
| `tileset_58.png` | B&W Surreal Office (CC0) | 64x80 | 4x5 | 16x16 | 20 |
| `assets/lpc-revised-the-office/` | LPC (CC-BY-SA 3.0) | various | individual PNGs | mixed | ~15 props |

Raw purchased packs: `/Users/robertnowell/Projects/b0b-asset-packs/` (guttykreum/, donarg/, pixelserial/, masalimov/).
All 29 pixelserial characters: `b0b-asset-packs/pixelserial/RPG Top Down Characters - Full version/`

---

## 1. Donarg Office Tileset (`donarg-office-32.png`)

512x1024, 16 cols x 32 rows at 32x32. Tile index = col + row x 16.

### Floors (rows 8-15, left half)
- 128-131: Blue-grey, tan, light grey, checkered tan
- 132-135: Gold/tan solid variants
- 144-145: Blue-grey lighter, tan with border
- 160-165: Tan solid, grey checkerboard, gold, blue-grey patterns
- 176-183: Mixed floor pattern blocks (grey, tan, blue variations)
- 192-199: More floor — tan, gold, blue-grey, cream variants
- 208-215: Same pattern area continued
- 224-231: Bottom of floor area
- 240-245: Final floor variants
- **Best picks**: 130 (light grey, corridor), 128+129 (blue-grey + tan, checkerboard), 132 (gold/tan, accent)

### Desks (rows 0-5)
- 1-2: Wood desk top (2 tiles wide, horizontal grain)
- 4-5: Tan/gold desk top (2 tiles wide, solid)
- 7: Small drawer unit
- 9-10: Grey+tan long counter top (left, right)
- 11: Silver/grey counter section
- 15: Small wood shelf unit
- 17-18: Grey desk with drawers (2 tiles, dark base)
- 21-22: Cream/white desk top (2 tiles)
- 24-26: Tan+grey long desk bottom sections
- 28-29: Grey cabinet/drawer unit top
- 32-33: Grey desk bottom (front face visible)
- 35-36: Pink/maroon trim desk details
- 37-38: Cream desk body sections
- 48-49: Grey desk front with drawer pull
- 53-54: Pink/maroon trim desk fronts
- 56-61: Grey+tan long counter bottom (6 tiles)
- 64-65: Wood desk front face (golden brown)
- 80-81: Tan desk section front

### Chairs (row 16)
- 256: Maroon/pink armchair (front view)
- 257: Dark red/burgundy armchair
- 258: Pink/salmon armchair
- 259: Tan/beige armchair
- 260-261: White office chair (front, side)
- 262-263: Grey office chair (front, side)

### Computers (rows 20-21)
- 328-329: CRT monitor + CPU tower (grey, first variant)
- 330-331: CRT monitor + CPU tower (darker, second variant)
- 332: Dark/off monitor (black screen)
- 333: Blue screen monitor (on, blue glow)
- 334-335: Coffee cups with saucers

### Bookshelves (rows 4-7, right side)
- 76-79: Bookshelf tops (red/green/blue books visible)
- 92-95: Full wood bookshelves (with colored book spines)
- 104-111: More bookshelves (wood + metal variants)
- 120-127: Bookcase+drawer combos (wood bottom, shelf top)
- 137-143: Metal shelving (grey, clean lines)
- 152-159: Bookshelves with books + metal shelving
- 168-171: Cabinet doors — wood (168), glass (169), wood (170), glass (171)
- 172-175: Purple/grey cabinet doors
- 200-207: More bookshelves/cabinets with colored books
- 217-223: Metal shelving units with items
- 232-239: Cabinet bottoms — wood door, glass door variants
- 248-255: Wood+grey cabinet lower halves

### Plants (rows 28-29)
- 450: Small potted plant (terra cotta pot)
- 451: Glass vase with plant
- 452-455: Tall leafy plants (4 variants, ascending size)
- 456-471: More plant variants (bushy, floor-standing)

### Boxes (rows 29-30)
- 472: Single small box
- 473-474: Double stacked boxes
- 475: Triple stacked boxes
- 476-479: Large boxes (2 variants)

### Paintings (rows 24-25)
- 384-385: Landscape painting (2 tiles wide, sunny scene, gold frame)
- 386-387: Lighthouse painting (2 tiles wide, coastal, gold frame)
- 388-389: Abstract/mountain paintings (1 tile each, gold frame)
- 390: Small nature frame
- 393-394: Open laptop (dark, blue screen)
- 395: Document/notepad

### Whiteboards & Charts (rows 25, 27)
- 416: Blank whiteboard (green)
- 432-433: Chalkboard/presentation board (2 tiles, dark, gold frame)
- 434-435: Grey presentation board (2 tiles)
- 436-437: Pie chart board (blue, red data)
- 438-439: Bar chart board (multi-color data)

### Printers & Electronics (rows 27-28)
- 440: USB drive / small device
- 441-442: Flat screen monitors (grey, 2 sizes)
- 443-446: Printer variants (with bird mascot!, grey, light/dark)
- 447: Cardboard box (small, tan)

### Clocks (row 23)
- 368: Blue wall clock
- 369: Red wall clock
- 370: Pink/salmon wall clock
- 372: Hourglass/frame (ornate wood)
- 373-375: Grey window/mirror frames

### Coffee/Water/Vending (rows 16-18)
- 280-283: Water cooler variants (tall, with bottle)
- 284-285: Grey fridge (front, 2 tiles tall)
- 287: Vending machine (colorful, red/green buttons)
- 296-299: Coffee machine/water dispenser variants

### Sofas & Benches (rows 17-19)
- 304: Barrel/wooden tub
- 305: Wood tall cabinet (brown)
- 306: Grey tall cabinet/locker
- 308-311: Wood bench (2 tiles, golden) + grey bench (2 tiles)
- 336-337: Grey low bench/couch (2 tiles, maroon base)
- 338-339: Wood-framed window/mirror unit (2 tiles)
- 340-343: Window frames (grey, glass panels)

### Folders/Small Items (rows 21-22)
- 344: Green folder
- 345: Blue folder
- 346: Pink/salmon folder
- 347: Green folder (darker)
- 348: Blue-grey folder
- 349: Pink/magenta folder
- 350: Yellow/gold folder
- 410: Document/notepad

### Laptops & Papers (rows 24-25)
- 393: Open laptop (dark, top view)
- 394: Open laptop (light/blue screen)
- 408-409: Closed laptop (dark)
- 410-413: Papers, notes
- 414-415: Calendar/notice board icons

### Windows (row 18)
- 290-291: Windows with frames

### Rugs & Mats (rows 30-31)
- 480-483: Floor mats (blue/grey, tan/gold)
- 484-487: Grey mat with dots, dark mat
- 496-499: Checkered rugs (yellow, red/pink)
- 500-503: Yellow rug with dots, dark rug

---

## 2. Masalimov Tiles (`masalimov-tiles.png`)

224x128, 7 cols x 4 rows at 32x32. Tile index = col + row x 7.

### Row 0 (tiles 0-6)
- 0: Filing cabinet front (dark, with lamp, 2 red drawers)
- 1: Filing cabinet front (dark, with lamp, 2 yellow drawers)
- 2: Bookshelf upper (horizontal colored bars/books)
- 3: Bookshelf upper (vertical colored bars)
- 4: Bookshelf upper (blue horizontal bars)
- 5: Bookshelf upper (blue/teal tint)
- 6: Window with blue tint + curtain

### Row 1 (tiles 7-13)
- 7: Filing cabinet side (dark with red drawers)
- 8: Filing cabinet side (dark with yellow drawers)
- 9: Desk with monitor (tan desk, dark screen, front view)
- 10: Desk with blue screen monitor (working!)
- 11: Desk with red/orange screen (task manager?)
- 12: Blue office chair (front, cushy)
- 13: Potted tree/bush (green, in orange pot)

### Row 2 (tiles 14-20)
- 14: Chair backs (pink/tan, viewed from behind)
- 15: Chair backs (another angle)
- 16: Desk with monitor (dark screen, different angle)
- 17: Desk with blue monitor (different angle)
- 18: Desk with tan/orange monitor
- 19: Wall clock (red, round)
- 20: Small potted plant (green, in blue pot)

### Row 3 (tiles 21-27) — Floors
- 21: Warm wood parquet (horizontal planks)
- 22: Blue-grey floor (horizontal lines, light)
- 23: Blue-grey floor (diagonal pattern)
- 24-25: Light blue floor (solid, subtle texture, 2 variants)
- 26: Tan/brown floor (warm, subtle)
- 27: Dark brown parquet (warm)

---

## 3. Masalimov Characters (`masalimov-chars.png`)

320x192, 10 cols x 6 rows at 32x32. 5 office characters.

### Layout
- Even rows (0, 2, 4): Idle frames — cols 0-4 only (one per character)
- Odd rows (1, 3, 5): Walk frames — char i at cols i and i+5 (2 frames each)
- Row 0-1: Facing down
- Row 2-3: Facing side (use horizontal flip for left/right)
- Row 4-5: Facing up

### Characters
- Char 0: Blue suit man
- Char 1: Glasses man
- Char 2: Pink suit person
- Char 3: Dark suit man
- Char 4: Another variant

Backup only — pixelserial is primary character source.

---

## 4. pixelserial Characters (`businessman.png`, `policeman.png`)

128x256 each, 4 cols x 8 rows at 32x32.

### Frame Layout
- Row 0: idle-down (4 frames)
- Row 1: idle-left (4 frames)
- Row 2: idle-right (4 frames)
- Row 3: idle-up (4 frames)
- Row 4: walk-down (4 frames)
- Row 5: walk-left (4 frames)
- Row 6: walk-right (4 frames)
- Row 7: walk-up (4 frames)

### Character Assignments
- **Businessman** -> Claude agent
- **Policeman** -> Codex agent (blue uniform, distinct)
- 27 more available at `b0b-asset-packs/pixelserial/RPG Top Down Characters - Full version/`

---

## 5. AI Town — gentle-obj.png

1440x1024, 45 cols x 32 rows at 32x32 = 1440 tiles. Tile index = col + row x 45.

### Rows 0-3 — Village Buildings & Tree Canopy
- **Cols 0-4**: Village building pieces — tan/brown rooftop (top-left corner, top edge, chimney), stone walls, wooden door
- **Cols 5-8**: White picket fence segments (horizontal, vertical, corners, gate), dirt path edges
- **Cols 9-44**: Dense green tree canopy — center fill, N/S/E/W edges, NE/NW/SE/SW corners, inner corners. Multiple shade variants (bright green over dark trunk/shadow)

### Rows 4-7 — Buildings, Water, Trees
- **Cols 0-5**: Rooftop edge pieces (brown shingle), walls with windows (white frame on tan), wall bottoms
- **Cols 6-8**: Blue water/river tiles — center, edges, river bends
- **Cols 9-30**: Tree canopy continued — edge variants, clearings
- **Cols 31-44**: Tree-to-grass transitions, isolated clumps

### Rows 8-11 — Ornate Structures, Water, Terrain
- **Cols 0-2**: Ornate gold-trimmed gate/arch (~3x2 multi-tile), stone pillar bases
- **Cols 3-4**: Iron fence segments (black, pointed tops)
- **Cols 5-7**: Pond/water body tiles (blue with stone edges)
- **Cols 8-15**: Grey cliff face tiles (rock edges meeting grass, all directions + corners)
- **Cols 16-44**: Green terrain with scattered tree canopy edges, hillside transitions

### Rows 12-15 — Indoor Tiles & Hills
- **Cols 0-2**: Tan floor tiles (plain, good for indoor rooms)
- **Cols 3-4**: Green carpet/rug tiles
- **Cols 5-7**: Small furniture — wooden table (2x1), chairs (brown, side view), window frame
- **Cols 8-10**: Wall tiles (tan, with baseboard)
- **Cols 11-44**: Hillside terrain, cliff edges, elevated ground transitions

### Rows 16-19 — Forest & Small Objects
- **Cols 0-14**: Dense forest (trunk + canopy, overlapping)
- **Cols 15-17**: Open tan ground / path tiles
- **Cols 18-20**: Tent (brown/tan, pointed top, ~2x2)
- **Cols 21-26**: Pumpkins, woven basket, clay pot, campfire (logs + flame), sleeping bag/bedroll
- **Cols 27-35**: Wooden sign post, well bucket, scarecrow, scattered items
- **Cols 36-44**: Transparent/empty

### Rows 20-23 — Forest Floor & Items
- **Cols 0-15**: Tree trunks on forest floor (dark green/brown ground)
- **Cols 16-18**: Weapons — sword (silver), axe (brown handle), pickaxe
- **Cols 19-21**: Leather bag/pouch, wooden shield (round), rope coil
- **Cols 22-25**: Wooden crate, barrel (brown staves), chest (brown with gold clasp)
- **Cols 26-30**: Grey rocks (3 sizes), tree stump (cut), flowers (red, yellow)
- **Cols 31-44**: Transparent/empty

### Rows 24-27 — Tree Trunks & Floor Tiles
- **Cols 0-18**: Large tree trunks on dark forest floor
- **Cols 19-22**: **Tan/brown floor tiles** (4 variants — plain tan, tan with grain, light brown, warm brown). Good for indoor floors!
- **Cols 23-24**: Small green bush/shrub tiles (2 variants)
- **Cols 25-28**: Dark green ground, grass tufts
- **Cols 29-44**: Mostly transparent

### Rows 28-31 — Large Trees
- **Cols 0-12**: Very large dark trees (~3-4 tiles wide x 3-4 tall, full trunk + root + canopy). Mushrooms, flowers at base.
- **Cols 13-44**: Mostly transparent/empty

### Best For Office Use
- Indoor floor: rows 12-15 cols 0-2 (tan), rows 24-27 cols 19-22 (brown/tan)
- Indoor walls: rows 12-15 cols 8-10
- Furniture: rows 12-15 cols 5-7 (table, chairs, window)
- Decorative: rows 8-11 cols 0-4 (ornate gate, iron fence)

### Best For Outdoor/Surrounds
- Grass: tree-clearing edge tiles throughout
- Water: rows 4-7 cols 6-8, rows 8-11 cols 5-7
- Paths: rows 16-19 cols 15-17
- Fences: rows 0-3 cols 5-8 (white picket), rows 8-11 cols 3-4 (iron)
- Trees: massive variety everywhere

---

## 6. AI Town — rpg-tileset.png

1600x1600, 100 cols x 100 rows at **16x16** = 10,000 tiles. Tile index = col + row x 100.

**NOTE**: 16x16 tiles — half our 32x32 engine size. Needs 2x nearest-neighbor scaling or use 2x2 groups as single 32x32 tiles.

### Rows 0-4 — Water, Terrain, Grass
- **Cols 0-11, Rows 0-3**: Water autotile — blue center, 8-directional edges (water-to-grass, water-to-dirt). Complete set for ponds/rivers/lakes.
- **Cols 12-23, Rows 0-3**: Purple/red earth — volcanic/corrupted ground autotile pattern.
- **Cols 24-35, Rows 0-5**: Dirt/brown earth — rocky dirt, edges meeting grass, path tiles. Unpaved roads.
- **Cols 36-55, Rows 0-5**: Gold/tan pyramid rooftop (multi-tile, ~10x5). Signature AI Town building.
- **Cols 56-75, Rows 0-7**: Brown rooftops, stone walls, brick textures, wooden planks, grey stone blocks.
- **Cols 76-99, Rows 0-3**: Checkered floor tiles (grey/purple, red/gold), brick wall faces, stone floor.

### Rows 5-9 — Ground, Buildings, Caves
- **Cols 0-11, Rows 5-7**: Green grass with flowers, mushrooms, crop rows, fence segments, gate.
- **Cols 12-23, Rows 5-7**: Dark cave floor autotile — black/dark brown center, edges. Underground.
- **Cols 24-35, Rows 5-7**: Grey flagstone path, ornate checkered floor, bridge planks.
- **Cols 36-55, Rows 5-9**: Building interiors — tan/gold walls, windows, doorframes, stairways.
- **Cols 56-75, Rows 5-9**: Building exteriors — brown/dark rooftops, chimneys, wall details.
- **Cols 76-99, Rows 5-9**: Grey castle/fortress walls, arched doorways.

### Rows 10-19 — Buildings, Bushes, Interiors
- **Cols 0-11, Rows 10-14**: Green bushes/hedges autotile, topiary, small trees.
- **Cols 12-23, Rows 10-14**: Ice/frozen water edges, lighter blue pond.
- **Cols 24-35, Rows 10-14**: Sand, tan earth, golden wheat field.
- **Cols 36-75, Rows 10-19**: Multi-tile village buildings — facades with windows, doors, shingled roofs.
- **Cols 76-99, Rows 10-14**: Purple/dark dungeon walls, torchlit passages.

### Rows 20-29 — Trees, Fire, Furniture, Market
- **Cols 0-11, Rows 20-24**: Large green trees (trunk + round canopy, ~3x4 tiles each, 2-3 variants).
- **Cols 12-23, Rows 20-24**: Grey stone textures, cracked earth, cave mouths.
- **Cols 24-35, Rows 20-29**: Fire/campfire animation, lava/magma pool tiles.
- **Cols 36-55, Rows 20-24**: Wooden fences, doors, treasure chest (brown+gold), wooden signs.
- **Cols 56-75, Rows 20-29**: **MARKET/SHOP** — shelves with potions (red, blue, green, yellow), counters, display tables, red+white awnings, stall frames, statue on pedestal.
- **Cols 76-99, Rows 20-29**: Castle interior — arched corridors, stone pillars, banners, grey brick.

### Rows 30-39 — Dungeon, Furniture, Shops
- **Cols 0-23, Rows 30-35**: Dungeon — black tiles, stone walls, torch brackets, dungeon doors, staircase, ladder.
- **Cols 24-35, Rows 30-35**: Grey stone walls, stone bridges.
- **Cols 36-55, Rows 30-39**: **FURNITURE** — wooden cabinets, bookshelves (colored spines!), dressers, table, chairs, bed frame.
- **Cols 56-75, Rows 30-39**: Market continued — shop counters, display shelves, awnings, lanterns, signs. Colored gems/orbs.
- **Cols 76-99, Rows 30-39**: Castle — grey walls, battlements, arrow slits, stone floor patterns.

### Rows 40-49 — Bedroom, Castle, Garden
- **Cols 36-55, Rows 40-49**: **BEDROOM/LIVING** — red bed (2x2), armchair (red cushion), round table, desk, dresser with mirror, wardrobe, candlestick, potted plant.
- **Cols 56-75, Rows 40-49**: Arched stone doorways (3-tile), castle entrance, portcullis, stone pavement, columns.
- **Cols 76-99, Rows 40-49**: Small rocks, flowers, vegetable patches, fence ends, stone wall segments.

### Rows 50-59 — Trees, Objects, Walls
- **Cols 0-15, Rows 50-55**: Dark trees (pine-like), wishing well (stone+rope+bucket), rocks (3 sizes), snake.
- **Cols 16-35, Rows 50-55**: Torches (wall-mounted, floor), hanging lanterns, chains, iron gate.
- **Cols 56-99, Rows 50-59**: Castle walls — wooden plank, stone, red brick, wall-floor transitions.

### Rows 60-69 — Waterfalls, Caves, Grass Paths
- **Cols 0-15, Rows 60-66**: **WATERFALL** — blue waterfall in stone frame (3-4 animation frames), pool at base.
- **Cols 16-35, Rows 60-66**: Cave openings — dark mouth in cliff face, stalactites.
- **Cols 56-75, Rows 60-69**: **GRASS PATHS** — dirt path on grass (crossroads, T-junctions, straight, curves). Complete autotile set!
- **Cols 76-99, Rows 60-69**: Pond edges on grass, small lake, desert sand pond.

### Rows 70-79 — Cliffs, Crystals
- **Cols 0-15, Rows 70-73**: Cliff + waterfall continued, cliff-grass edge tiles.
- **Cols 16-35, Rows 70-73**: Colored crystals/gems (purple, green, blue, red, pink, 1-tile), mushrooms, rocks.

### Rows 80-89 — Cliffs, Nature
- **Cols 0-20, Rows 80-86**: Large tree on cliff edge, grass-to-cliff autotile, dirt cliff face.
- **Cols 21-35, Rows 84-86**: Seashells, round stones, ice/snow tiles.

### Rows 90-99 — Bridge, Fence
- **Cols 0-15, Rows 90-93**: Stone fence/wall (grey, low), stone bridge over water (multi-tile).
- Rest: Mostly empty.

### Best For b0b Office
- Furniture (rows 30-49, cols 36-55): Bookshelves, cabinets, beds, chairs — at 16x16
- Market/shop (rows 20-39, cols 56-75): Potion shelves, counters, awnings — unique items
- Water/waterfall (rows 60-66, cols 0-15): Courtyard water feature
- Grass paths (rows 60-69, cols 56-75): Outdoor walkways
- Trees (rows 20-24, cols 0-11): Building surrounds

---

## 7. AI Town — magecity.png

256x1450, 8 cols x ~45 rows at 32x32. Object pack (irregularly packed multi-tile objects). Tile index = col + row x 8.

### Section y:0-290 (~rows 0-9) — Props, Walls, Shelves
- **Row 0**: Stone column/pillar (grey, ornate capital, 1x2 tall), stone wall fragment
- **Row 1**: Potted plants — clover in terracotta pot, aloe/succulent, tropical broadleaf, bushy fern (all 1x1, great decorative)
- **Row 2**: Wooden barrels (3 variants), wooden desk/table (brown, 2x1), small wooden chest/bench
- **Row 3**: Stone fountain with blue water basin (~3x2, ornate stone rim)
- **Rows 4-6**: Tan brick wall autotile — solid center, top/bottom/left/right edges, corners. Ivy/vine climbing wall tile.
- **Rows 7-9**: Wooden bookshelves — 3 variants with blue backgrounds, different shelf spacing (~2x3 each, brown wood, visible book spines)

### Section y:290-580 (~rows 9-18) — Stone, Statues, Trees
- **Rows 9-11**: Cobblestone pavement (grey, multiple sizes: 2x2, 3x3, 4x4). Good for plaza/courtyard.
- **Row 12**: Hedge bush (green, round, 1x1), garden bed (green in wood frame, 2x1), clay jug
- **Rows 13-15**: Twisted vine/tree trunks (brown, no leaves, 1x3 and 1x4 tall). Stone pedestal/plinth.
- **Row 15**: Bronze/gold bust statue on pedestal (~1x2).
- **Row 16**: Park bench (wooden, 2x1 front view). Fallen leaves/debris.
- **Rows 17-18**: Dead/bare tree — very large skeletal tree (~4x5 tiles!). Dramatic.

### Section y:580-870 (~rows 18-27) — Windows, Walls, Gates
- **Rows 18-19**: Stone eagle/gargoyle statue (grey, 2x2). Round garden bed with flowers (2x2).
- **Row 20**: Dark metal knight statue (1x2). Gold wing/scroll ornament (2x1).
- **Rows 21-23**: **WINDOWS** — blue glass in wood frames. 6 variants: tall narrow (1x2), wide (2x2), arched (1x2), small square (1x1), double-pane (2x1), shuttered.
- **Rows 24-26**: Brick wall + wooden beam framing (3 variants), wooden gate in stone pillars (3x2), brick wall with door (2x3), plank fence.

### Section y:870-1160 (~rows 27-36) — Ground, Hedges, Pumpkins
- **Row 27**: Grey floor tile (2x2). Brick-grass corner/transition tiles.
- **Rows 28-30**: Autumn hedges — orange/gold bushes (3 sizes: 2x1, 2x2, 3x2). Beautiful fall foliage.
- **Row 30**: Stone drainage grate. Scattered pumpkins (tiny orange).
- **Rows 31-33**: Grass-brick diagonal edges, overgrown stone path, moss-covered brick.

### Section y:1160-1450 (~rows 36-45) — Fences, Vines, Paths
- **Rows 36-37**: Brick wall variants — tan, dark grey, golden. Wall-ground edge tiles.
- **Rows 38-39**: Climbing vines/ivy (green, multiple angles), autumn leaves (red/orange), bare branches.
- **Row 40**: Iron fence — black railing/posts (2-3 tiles wide, pointed tops). Great for courtyard boundary.
- **Rows 41-42**: Stone pathway (grey flagstone, 2x2). Dark metal kettle (1x1).
- **Rows 43-44**: Wooden plank floor (brown, 2x2). Grey stone floor (2x2). Mossy ground.
- **Row 45**: Wooden crates (stacked, 1x1 and 2x1).

### Best For b0b Office
- Potted plants (row 1): 4 variants, desk/corner decorations
- Bookshelves (rows 7-9): Ornate, nicer than Donarg
- Windows (rows 21-23): 6 styles for office walls
- Walls (rows 4-6): Complete tan brick autotile + wooden framing
- Cobblestone (rows 9-11): Outdoor areas
- Iron fence (row 40): Office perimeter
- Wooden floor (rows 43-44): Alternative indoor floor
- Fountain (row 3): Courtyard centerpiece
- Bench (row 16): Break room / outdoor

---

## 8. AI Town — 32x32folk.png (Characters)

384x256, 4 characters wide x 2 rows = 8 village characters.

### Layout
Each character occupies 96x128 px = 3 frames x 4 directions at 32x32.
- **Direction order per character block**: Row 0=down, Row 1=left, Row 2=right, Row 3=up
- **Character positions**:
  - f1: (0,0), f2: (96,0), f3: (192,0), f4: (288,0)
  - f5: (0,128), f6: (96,128), f7: (192,128), f8: (288,128)
- Characters: Village folk — farmers, townsfolk with varied outfits/hair colors
- Used by `makeSheet(startX, startY)` to generate SpritesheetData

---

## 9. AI Town — Animated Spritesheets

### campfire.png (128x32)
- 4 frames at 32x32, single row
- Fire animation: logs with orange/yellow flames, 4-frame loop

### gentlesparkle32.png (96x96)
- 3x3 grid at 32x32 = 9 frames
- Sparkle/twinkle particle effect animation

### gentlewaterfall32.png (192x320)
- 6 cols x 10 rows at 32x32 = 60 tiles
- Waterfall animation tiles — top, middle, bottom sections with multiple animation frames
- Can be assembled into variable-height waterfalls

### windmill.png (624x624)
- 3x3 grid at 208x208 = 8 rotation frames (bottom-right cell empty)
- Full windmill with sails rotating through 8 angles
- Large sprite — needs scaling for 32x32 world (or use as landmark)

---

## 10. B&W Surreal Office (OpenGameArt, CC0)

### workers1.png (384x256) — 8 office worker characters
**EXACT SAME FORMAT as 32x32folk.png** — drop-in replacement!
- 4 chars wide x 2 rows, each 96x128 (3 frames x 4 directions at 32x32)
- Style: 1-bit black & white, minimalist corporate
- Same `makeSheet(startX, startY)` function works unchanged

### workers2.png (384x256) — 8 more characters
- Same format as workers1. Some have red accent color ("wraiths/monsters")
- Red-tinted characters could represent "failed" or "corrupted" agents

### workerface1.png (128x64) — 8 portraits
- Character face portraits at 16x16
- Office workers with hats, glasses, mustaches

### workerface2.png (128x64) — 8 more portraits
- Includes skull faces, robot faces, abstract — the "monster" variants

### tileset_58.png (64x80) — 20 minimal office tiles
- 4 cols x 5 rows at 16x16
- Contains: desk, computer screen, filing cabinet, floor, wall, door
- Minimal supplement — needs 2x scale for 32x32 engine

---

## 11. LPC Office Props (`assets/lpc-revised-the-office/`)

Individual PNG files, various sizes. CC-BY-SA 3.0.

| File | Size | Content |
|------|------|---------|
| `Laptop.png` | various | Open/closed laptop, multiple angles |
| `Copy Machine.png` | 64x64 | Copy machine, animated |
| `TV, Widescreen.png` | various | TV with static animation |
| `Water Cooler.png` | 32x64 | Standing water cooler |
| `Coffee Cup.png` | small | Small coffee cup |
| `Rotary Phones.png` | various | Vintage rotary phone |
| `Office Portraits.png` | various | Framed portrait paintings |
| `Bins.png` | various | Trash/recycle bins |
| `Mailboxes.png` | 96x96 | Mail slots |
| `Coffee Maker.png` | 64x64 | Coffee maker machine |
| `Desk, Ornate.png` | 160x128 | Ornate multi-frame desk |
| `Shopping Cart.png` | 32x64 | Shopping cart |

---

## Station Furniture Assignments (Design Decisions)

| Station | Desk (Donarg) | Chair (Donarg) | Props |
|---------|---------------|----------------|-------|
| Planning | 1,2 (wood) | 259 (tan) | 368 (clock), 410 (notepad) |
| Review | 21,22 (cream) | 262,263 (grey x2) | 344,345 (folders) |
| Building | 1,2 (wood) | 260 (white) | 333 (blue monitor), 393 (laptop) |
| Audit | 9,10 (grey counter) | 262 (grey) | 330,331 (CRT+CPU) |
| Repair | 64,65 (wood front) | 257 (dark red) | 472 (box), 447 (small box) |
| Testing | 1,2 (wood) | 258 (pink) | 333 (blue monitor), 438-439 (chart) |
| Ship | 17,18 (grey desk) | 256 (maroon) | 475 (stacked boxes), 410 (notepad) |
| Merged | 92,93 (bookshelves) | -- | 450 (plant), 384-385 (painting) |
| Failed | 472-475 (boxes) | -- | 443 (printer), 369 (red clock) |

---

## Tools

- `tile-picker.html` — Visual tile browser + map editor with palette system
- `sprite-test.html` — Frame inspector with animation previews
- `_tile_atlas/` — Extracted row strips for visual reference (donarg, gentle-obj, rpg-tileset, magecity)
