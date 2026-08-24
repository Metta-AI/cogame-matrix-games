## Board art manifest: one baked yard floor plus the shipped wall tiles.
##
## Fork of paintbot's `src/ctf/map_art.nim`, reduced to what a fixed 24 x 14
## yard needs. Paintbot bakes a per-map floor at load; matrix games plays the
## SAME yard in every variant, so the floor is a single committed bake
## (`scripts/art/gen_matrix_art.py` -> `data/yard_floor.png`) that the
## renderer tiles, and the walls reuse the starter's shipped
## `client/art/walls/{wall_h,wall_v}.jpg`.
##
## The list lives in Nim because three places have to agree on it: the viewer
## meta, `Dockerfile.replay-viewer`'s `test -f` assertions, and the art
## generator's output set. `tests/test_viewer.nim` checks the files exist.

import std/[json]
import sim_types, matrices

const
  YardFloor* = "art/yard_floor.png"
  WallHorizontal* = "art/walls/wall_h.jpg"
  WallVertical* = "art/walls/wall_v.jpg"
  ResetBurst* = "art/reset_burst.png"
  PickupSpark* = "art/pickup_spark.png"
  LockerRoomBg* = "art/lockerroom/bg.jpg"
  RigPoses* = ["idle", "carry", "hold", "fire"]

proc rigPath*(livery, pose: string): string =
  "art/rig_matrix/" & livery & "/" & pose & ".png"

proc beamPath*(livery: string): string =
  "art/beam_" & livery & ".png"

proc tokenPath*(variant: string, index: int): string =
  "art/tokens/" & variant & "_" & $index & ".png"

proc artManifest*(variant: string): JsonNode =
  ## Every asset the board renderer loads, keyed the way the worker's
  ## `ART_FILES` table expects.
  let spec = matrixSpec(variant)
  result = newJObject()
  result["floor"] = %YardFloor
  result["wallH"] = %WallHorizontal
  result["wallV"] = %WallVertical
  result["burst"] = %ResetBurst
  result["spark"] = %PickupSpark
  var rigs = newJObject()
  var beams = newJObject()
  for livery in LiveryKeys:
    var poses = newJObject()
    for pose in RigPoses:
      poses[pose] = %rigPath(livery, pose)
    poses["armband"] = %("art/rig_matrix/" & livery & "/armband.png")
    rigs[livery] = poses
    beams[livery] = %beamPath(livery)
  result["rigs"] = rigs
  result["beams"] = beams
  var tokens = newJArray()
  for index in 0 ..< spec.k:
    tokens.add(%tokenPath(variant, index))
  result["tokens"] = tokens
