## The one fixed arena, committed as an ASCII constant.
##
## `#` is wall, `.` is floor. 24 cells wide x 14 tall, rendered at 40 px per
## cell = a 960 x 560 board. It is mirror-symmetric left-right AND top-bottom,
## fully connected, and has exactly 216 free cells; `tests/test_sim.nim`
## asserts all four properties so a careless edit cannot ship a split arena.
##
## Paintbot's map generator, map pool and style tables are deleted: matrix
## games play the SAME yard in every variant, which is also why the viewer
## drops the zoom bar and the minimap.

import sim_types

const
  ArenaRows*: array[BoardH, string] = [
    "########################",
    "#....##..........##....#",
    "#..........##..........#",
    "#.##....#......#....##.#",
    "#.##................##.#",
    "#......##......##......#",
    "#..##..............##..#",
    "#..##..............##..#",
    "#......##......##......#",
    "#.##................##.#",
    "#.##....#......#....##.#",
    "#..........##..........#",
    "#....##..........##....#",
    "########################"
  ]
  FreeCellCount* = 216

proc inBounds*(x, y: int): bool {.inline.} =
  x >= 0 and x < BoardW and y >= 0 and y < BoardH

proc isWall*(x, y: int): bool {.inline.} =
  if not inBounds(x, y): true else: ArenaRows[y][x] == '#'

proc isFloor*(x, y: int): bool {.inline.} =
  not isWall(x, y)

proc freeCells*(): seq[(int, int)] =
  ## Row-major, so the seeded spawner draw is a function of the seed alone.
  for y in 0 ..< BoardH:
    for x in 0 ..< BoardW:
      if isFloor(x, y):
        result.add((x, y))

proc freeCellsIn*(x0, y0, x1, y1: int): seq[(int, int)] =
  for y in max(0, y0) .. min(BoardH - 1, y1):
    for x in max(0, x0) .. min(BoardW - 1, x1):
      if isFloor(x, y):
        result.add((x, y))

proc walls*(): seq[string] =
  for row in ArenaRows:
    result.add(row)

proc lineOfSight*(ax, ay, bx, by: int): bool =
  ## Bresenham over the wall grid: true when no wall cell strictly between the
  ## two cells blocks the line. This is what makes another cog's inventory
  ## visible -- the design note's "commitment is visible".
  var x = ax
  var y = ay
  let dx = abs(bx - ax)
  let dy = abs(by - ay)
  let sx = if ax < bx: 1 else: -1
  let sy = if ay < by: 1 else: -1
  var err = dx - dy
  while true:
    if x == bx and y == by:
      return true
    if (x != ax or y != ay) and isWall(x, y):
      return false
    let e2 = 2 * err
    if e2 > -dy:
      err -= dy
      x += sx
    if e2 < dx:
      err += dx
      y += sy
