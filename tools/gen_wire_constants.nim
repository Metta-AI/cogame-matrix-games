## Emits the shared wire constants as a JS object, so the browser chrome and
## the Nim sim can never drift apart on a tick rate, a cap or a colour.
## Piped into replay-viewer/dist/wire_constants.js by the viewer build.

import std/[json]
import matrix_games/[sim_types, matrices, map_art]

when isMainModule:
  var liveries = newJArray()
  for index in 0 ..< Seats:
    liveries.add(%*{
      "slot": index, "alias": aliasOf(index), "key": liveryOf(index),
      "hex": liveryHexOf(index),
      "camp": (if rowCamp(index): "row" else: "column")})
  var variants = newJObject()
  for name in MatrixNames:
    let spec = matrixSpec(name)
    variants[name] = %*{
      "K": spec.k, "tokens": spec.tokens, "coopToken": spec.coopToken,
      "crossCampOnly": spec.crossCampOnly, "art": artManifest(name)}
  echo "window.MATRIX_WIRE=", $ %*{
    "protocol": ReplayProtocol,
    "gameVersion": GameVersion,
    "fps": TargetFps,
    "seats": Seats,
    "aliases": Aliases,
    "boardW": BoardW,
    "boardH": BoardH,
    "cellPx": CellPx,
    "speeds": PlaybackSpeeds,
    "tokenKeys": TokenChromeKeys,
    "liveries": liveries,
    "beamDrawTicks": BeamDrawTicks,
    "cellFlashTicks": CellFlashTicks,
    "bigPayCp": BigPayCp,
    "variants": variants
  }, ";"
