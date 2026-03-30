// Office map: 20x14 tiles using gentle-obj.png tileset
// Tile indices reference 32x32 tiles in gentle-obj.png (1440x1024, 45 cols x 32 rows)
const TILE_W = 32, TILESET_PX_W = 1440, TILESET_PX_H = 1024;
const MAP_W = 20, MAP_H = 14;

// Tile IDs from gentle-obj.png (approximate — picked visually appropriate tiles)
const T = {
  FLOOR: 181,      // grey/green ground tile
  FLOOR2: 182,     // slightly different floor
  WALL_H: 46,      // horizontal wall
  WALL_V: 91,      // vertical wall
  WALL_TL: 45,     // top-left corner
  WALL_TR: 47,     // top-right corner
  WALL_BL: 135,    // bottom-left corner
  WALL_BR: 137,    // bottom-right corner
  TABLE: 459,      // table/desk tile
  CHAIR: 504,      // chair/seat
  BOOKSHELF: 414,  // bookshelf
  CRATE: 369,      // crate/filing cabinet
  EMPTY: -1,
};

// Background layer: floor + walls
const BG_TILES = [];
for (let x = 0; x < MAP_W; x++) {
  BG_TILES[x] = [];
  for (let y = 0; y < MAP_H; y++) {
    // Walls on border
    if (y === 0 && x === 0) BG_TILES[x][y] = T.WALL_TL;
    else if (y === 0 && x === MAP_W - 1) BG_TILES[x][y] = T.WALL_TR;
    else if (y === MAP_H - 1 && x === 0) BG_TILES[x][y] = T.WALL_BL;
    else if (y === MAP_H - 1 && x === MAP_W - 1) BG_TILES[x][y] = T.WALL_BR;
    else if (y === 0 || y === MAP_H - 1) BG_TILES[x][y] = T.WALL_H;
    else if (x === 0 || x === MAP_W - 1) BG_TILES[x][y] = T.WALL_V;
    // Checkerboard floor
    else BG_TILES[x][y] = (x + y) % 2 === 0 ? T.FLOOR : T.FLOOR2;
  }
}

// Object layer: station furniture
const OBJ_TILES = [];
for (let x = 0; x < MAP_W; x++) {
  OBJ_TILES[x] = [];
  for (let y = 0; y < MAP_H; y++) {
    OBJ_TILES[x][y] = T.EMPTY;
  }
}

// Station desk placements (desks at station positions)
// Planning desk
OBJ_TILES[3][3] = T.TABLE;
OBJ_TILES[4][3] = T.TABLE;
// Build workstation
OBJ_TILES[8][3] = T.TABLE;
OBJ_TILES[9][3] = T.TABLE;
// Audit desk
OBJ_TILES[14][3] = T.TABLE;
OBJ_TILES[15][3] = T.TABLE;
// Repair bench
OBJ_TILES[14][9] = T.TABLE;
OBJ_TILES[15][9] = T.TABLE;
// Test lab
OBJ_TILES[8][9] = T.TABLE;
OBJ_TILES[9][9] = T.TABLE;
// Shipping desk
OBJ_TILES[3][9] = T.TABLE;
OBJ_TILES[4][9] = T.TABLE;
// Merged shelf
OBJ_TILES[17][11] = T.BOOKSHELF;
OBJ_TILES[18][11] = T.BOOKSHELF;
// Failed corner
OBJ_TILES[1][11] = T.CRATE;
OBJ_TILES[2][11] = T.CRATE;

// No animated environment sprites for office
const ANIM_SPRITES = [];
