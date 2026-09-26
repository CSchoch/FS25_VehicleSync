# FS25 Vehicle Sync

## Project Overview

Lua script mod for Farming Simulator 25, multiplayer first. A harvester (leader) takes over speed and
steering of a tractor with a grain cart (follower) for unloading on the go, modelled on real-world
leader/follower machine synchronisation (sync network, operational zone, Acquiring -> Tracking,
nudging by the leader operator, instant takeover by the follower operator).

## Standing Requirements

After every code change:
1. Run tests with coverage: `& "C:\Program Files (x86)\Lua\5.1\lua.exe" tests\run_tests.lua --coverage`
   (fails below 90 % line coverage; currently 100 %)
2. Add test cases for new functionality; new spec files must be added to `TEST_FILES` in
   `tests/run_tests.lua`, new source files to `SOURCE_FILES` there **and** to `tests/specs/ReleaseRules_spec.lua`'s count
3. Before a release: `create_release.bat` (tests + `dist\FS25_VehicleSync.zip`), then
   `TestRunner_public.exe --noPause --disableAutoOpen --outputPath dist\testrunner --logPath dist\testrunner dist\FS25_VehicleSync.zip`
   must PASS (`--logPath` takes a directory).

## Architecture

| File | Role |
| --- | --- |
| `src/VehicleSyncMath.lua` | Pure 2D geometry (x/z plane, +z forward, +x left, positive curvature = left) |
| `src/VehicleSyncController.lua` | Pure state machine (IDLE/CONNECTED/ACQUIRING/TRACKING), rules, zone, home point, nudges, pure-pursuit steering and speed law. No engine calls. |
| `src/VehicleSyncSettings.lua` | Server settings, `vehicleSync.xml` in the savegame, console `vsSettings` / `vsSet` |
| `src/network/VehicleSyncRequestEvent.lua` | client -> server operator actions |
| `src/network/VehicleSyncStateEvent.lua` | server -> clients full state (+ feedback-only variant for refusals) |
| `src/VehicleSyncSpec.lua` | Vehicle specialization (glue): requests, server rules, driving override, streams, input, HUD |
| `src/VehicleSync.lua` | Bootstrap: registers the spec for all Drivable+Enterable+Motorized types, save hook, console |

Key facts:
- **Server-authoritative.** Clients only send requests; `VehicleSyncSpec.handleRequest` accepts a
  request only from `vehicle:getOwnerConnection()` (the player sitting in it) or the local server player.
- **Driving = driver assist, not an AI job.** The server calls `Drivable:updateVehiclePhysics` for every
  player-controlled vehicle; the spec overrides it and replaces the neutral operator input with the
  controller command (steering via `rotTimeToAxisSide`, speed via motor speed limit). An operator must
  sit in the tractor (like the real system); pedal input (server), steering input (owner client,
  `setSteeringInput` override -> `OPERATOR_TAKEOVER` request) or cruise control (server) disengage.
- Poses use `getAIDirectionNode()` (falls back to `rootNode`); the pipe outlet is measured with
  `localToLocal(dischargeNode.node, directionNode)` only while the pipe is in an unloading state.
- The cart point is the first `fillUnit.exactFillRootNode` of an attached vehicle (what pipes aim at).
- Join in progress: `onWriteStream` / `onReadStream`; the leader may be streamed after the follower,
  so the leader id is resolved lazily (`pendingLeaderId`, `vsGetLeader`).
- Timers / takeover flags reset only when engaged-ness changes (ACQUIRING <-> TRACKING keeps them).

## GIANTS TestRunner rules (learned the hard way)

- `PublicLuaCheck` is textual: no `pcall`, `xpcall`, `collectgarbage`, `load(` anywhere in `src/` -
  this includes names like `Settings.load()`; use `XMLFile.loadIfExists`.
- `ObsoleteFiles` is textual: every file path must appear literally (no string concatenation).
- `ModDescCheck`: the FS25 mod icon must be **512x512** (the ModHub guideline PDF v5.9.1 still says
  256), BC1 without mipmaps; **no changelog** in the description of version 1.0.0.0, but a changelog
  is mandatory for every update.
- `tests/specs/ModDesc_spec.lua` and `ReleaseRules_spec.lua` encode these rules plus the ModHub
  guidelines (EN/DE texts, capitalised l10n, hotkeys documented, only lua/xml/dds in the zip).

## Icon

`python tools/make_icon.py` draws `_art/icon_VehicleSync.png` and converts it with texconv
(found in `..\FS25_WorkflowManager\tools\texconv.exe`).
