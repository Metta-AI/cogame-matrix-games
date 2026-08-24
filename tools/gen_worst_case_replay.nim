## Writes the worst-case model-text fixture. Not a test and not part of the
## build: run it when `tests/support/worst_case.nim` changes.
##
##   nim r --path:src --path:tests tools/gen_worst_case_replay.nim
##
## `tests/test_worst_case_text.nim` fails if the committed file and this
## generator disagree, so the fixture can never quietly drift -- or quietly
## shorten, which would leave the CI step that loads it passing while testing
## nothing.

import std/[os, strutils]
import support/worst_case

when isMainModule:
  let root = currentSourcePath().parentDir().parentDir()
  let path = root / FixtureRelPath.replace("/", DirSep & "")
  createDir(path.parentDir())
  let bytes = worstCaseReplayBytes()
  writeFile(path, bytes)
  echo "wrote ", path, " (", bytes.len, " bytes)"
