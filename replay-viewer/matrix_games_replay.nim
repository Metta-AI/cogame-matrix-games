## Matrix Games static replay viewer, wasm side.
##
## Forked from `coworld-ctf/replay-viewer/ctf_replay.nim`: the same structure
## and the same safety furniture -- the `stageNote` buffer with its
## `stampStage` calls, the ABORTING_MALLOC rationale, and the
## `emscripten_exit_with_live_runtime()` epilogue, without which Nim's `main`
## destroys every module global while JS keeps calling in.
##
## `ctf_mismatch_tick` is DROPPED: matrix games records state, not inputs, so
## playback never re-simulates and there is nothing to mismatch. That is also
## why `#mmwarn` is gone from the page.
##
## JS hands the raw replay bytes to `mg_load_replay`; this module indexes them
## and then answers one packet per tick -- the board frame and the chrome
## frame in one object, paintbot's "smuggle the chrome TextMessage alongside
## the sprite packet" trick, in JSON.

import std/[json, strutils]
import matrix_games/[sim_types, global, replays]

var
  runtimeLoaded = false
  view: ViewerState
  packet: string
  cursor: int
  firstPacketDone: bool
  lastError: string

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals instead of trapping. The bundle is therefore linked
## with -s ABORTING_MALLOC=1 and this fixed buffer, stamped BEFORE each risky
## phase, stays readable from JS after the abort (aborting kills the call
## stack, not the linear memory), so the page can still report what the
## runtime was doing.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc renderCurrent() =
  packet = $view.viewerPacket(cursor, not firstPacketDone)
  firstPacketDone = true

proc mgLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "mg_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    let replay = parseReplayBytes(data.bytesFromPointer(int(length)))
    stampStage("index replay")
    view = initViewer(replay)
    let mapNote = " (map " & $BoardW & "x" & $BoardH & ")"
    ## Refuse boards whose render buffers cannot fit the 32-bit address space
    ## BEFORE anything is drawn, so the page gets a clean diagnostic instead
    ## of an OOM abort. A 24 x 14 yard is far under the budget, so this check
    ## is kept from paintbot and never trips.
    stampStage("check viewer capacity" & mapNote)
    if predictedViewerRenderBytes(BoardW, BoardH) > WasmViewerBudgetBytes:
      raise newException(MatrixGamesError,
        "replay board is too large for the browser viewer" & mapNote)
    stampStage("build first packet" & mapNote)
    cursor = 0
    firstPacketDone = false
    renderCurrent()
    runtimeLoaded = true
    return 1
  except Exception as error:
    ## Exception, not CatchableError: a Defect from the wasm build (an index
    ## or range check) must surface as a message in the shell, not as a silent
    ## zero with an empty error string.
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg
    if lastError.len == 0:
      lastError = "unknown failure while loading the replay"
    return 0

proc mgInput(data: ptr uint8, length: cint) {.exportc: "mg_input", cdecl.} =
  ## The page's only input is a seek: `s:<tick>`. Anything else is ignored.
  if not runtimeLoaded:
    return
  let text = data.bytesFromPointer(int(length))
  if text.len > 2 and text[0] == 's' and text[1] == ':':
    try:
      cursor = clamp(parseInt(text[2 .. ^1]), 0, view.tickCount - 1)
    except CatchableError:
      discard

proc mgFrame(index: cint): cint {.exportc: "mg_frame", cdecl.} =
  ## Advance to (or seek to) `index` and rebuild the packet. A seek is an
  ## array index: there is no re-simulation.
  if not runtimeLoaded:
    lastError = "no replay loaded"
    return -1
  try:
    stampStage("build packet")
    cursor = clamp(int(index), 0, view.tickCount - 1)
    renderCurrent()
    return cint(cursor)
  except Exception as error:
    lastError = "build packet: " & error.msg
    return -1

proc mgPacketPointer(): ptr uint8 {.exportc: "mg_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: cast[ptr uint8](packet[0].addr)

proc mgPacketLength(): cint {.exportc: "mg_packet_len", cdecl.} =
  cint(packet.len)

proc mgErrorPointer(): ptr uint8 {.exportc: "mg_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc mgErrorLength(): cint {.exportc: "mg_error_len", cdecl.} =
  cint(lastError.len)

proc mgStagePointer(): ptr uint8 {.exportc: "mg_stage_ptr", cdecl.} =
  ## The progress note. Unlike mg_error_*, this stays valid after an
  ## allocation-failure abort, so JS can report what the runtime was doing
  ## when the address space ran out.
  if stageNoteLen == 0: nil else: cast[ptr uint8](stageNote[0].addr)

proc mgStageLength(): cint {.exportc: "mg_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing `view` and `packet` while the wasm module stays alive and JS keeps
  # calling mg_load_replay / mg_frame. The whole session would then run on
  # freed globals. Unwinding main through emscripten's live-runtime exit skips
  # the destructor epilogue entirely, so globals stay valid for the life of
  # the page.
  emscriptenExitWithLiveRuntime()
