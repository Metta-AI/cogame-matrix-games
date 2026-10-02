## The replay's event vocabulary and the buffer that collects it.
##
## Fork of paintbot's `src/ctf/events.nim`, reduced to the nine record kinds
## the design note pins: `order`, `pickup`, `beam`, `nocontest`, `interact`,
## `reset`, `leadchange`, `beatclose`, `end`. One JSON row per event, `t` is
## the tick, seats are slot integers and token types are integer indices --
## no names in the event stream, because the viewer maps slots to liveries
## and policy names itself.

import std/[json]
import sim_types

type
  EventBuffer* = object
    records*: seq[JsonNode]

const
  EventKinds* = ["order", "pickup", "beam", "nocontest", "interact", "reset",
    "leadchange", "beatclose", "end"]

proc add*(buffer: var EventBuffer, kind: string, fields: JsonNode) =
  var record = newJObject()
  record["k"] = %kind
  for key, value in fields:
    record[key] = value
  buffer.records.add(record)

proc publicEventJson*(record: JsonNode, live = false): JsonNode =
  result = copy(record)
  if result.hasKey("notes"):
    result.delete("notes")
  if live and record["k"].getStr() == "order":
    result["intent"] = %"private"
    result["token"] = %(-1)
    result["target"] = %(-1)

proc toJson*(buffer: EventBuffer): JsonNode =
  result = newJArray()
  for record in buffer.records:
    result.add(publicEventJson(record))

proc count*(buffer: EventBuffer, kind: string): int =
  for record in buffer.records:
    if record{"k"}.getStr() == kind:
      result.inc

proc orderEvent*(t, beat, seat: int, order: IntentOrder, source: OrderSource,
    latencyMs: int): JsonNode =
  %*{
    "t": t, "beat": beat, "seat": seat, "intent": $order.intent,
    "token": order.token, "target": order.target, "source": $source,
    "say": cleanText(order.say, MaxSayRunes),
    "notes": cleanText(order.notes, MaxNotesRunes),
    "latencyMs": latencyMs
  }
