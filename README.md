# secrete

Roblox Exploit using Rayfield Gen2 Library. Remaking SirMeme Hub and many others into one.

One file executes. The content — every module — lives in packs that are fetched
once, cached to the executor's filesystem, and served from that cache when HTTP
fails.

```lua
loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/0craxy0/secrete/main/secrete.lua", true))()
```

- **RightShift** — show / hide the window.
- **End** — panic: disable every module, drop the UI, disconnect everything.
- In the console: `Secrete.Enable("Crosshair")`, `Secrete.List(true)`, `Secrete.Panic()`.

## Scope

Everything in here runs on your own client and only ever reads your own state.
There is no aim assistance, no hit-registration spoofing and no information about
other players, by design.

Developer movement toggles (fly, noclip, walk speed) exist because that is
legitimate debugging, and they are locked to places you own: the gate checks
`game.CreatorId` against your `UserId`, or owner rank in a group-owned place, or
Studio. Attempting to enable them anywhere else refuses and logs why.

## Layout

```
secrete.lua            the only file users execute: framework, loader, boot
modules/universal.lua  packs — content that registers through Secrete.CreateModule
modules/developer.lua
test/                  offline harness: mocks, assertions, scenarios, runner
```

Inside `secrete.lua`:

| Section | Contents |
| --- | --- |
| 1. capabilities | Executor name, filesystem, HTTP, place-ownership detection. |
| 2. utility | Guarded calls, HTTP fallback, colour normalisation, refusals. |
| 3. store | Per-`PlaceId` module state in `secrete/profiles/<PlaceId>/state.txt`. |
| 4. gui | `Screen` / `Panel` / `Frame` / `Line` — the shell modules draw into. |
| 5. registry | `CreateModule`, `Toggle`, `Track`, `Surface`, `Element`, save/restore. |
| 6. library surface | The only place Rayfield is called: load, window, tabs, elements, notify. |
| 7. heartbeat | Sentivel uptime pings and failure bookkeeping. |
| 8. hotkeys | RightShift, End, panic, unload. |
| 9. loader | Fetches packs, caches them, falls back to that cache offline. |
| 10. boot | Capabilities → heartbeat → UI → packs → mount → restore → About. |

## Packs

A pack is a file that returns a function:

```lua
return function(Secrete)
    Secrete.CreateModule({ Name = "Thing", Description = "What it does.", Tab = "Visuals" })
end
```

`HUB.Packs` lists the packs every client loads (`universal`, `developer`). A pack
named after the `PlaceId` — `modules/1234567.lua` — is loaded too when the repo
has one, which is where game-specific modules belong. A missing place pack is not
an error.

Resolving a pack has exactly two sources: the repo, and
`secrete/cache/<name>.lua`. A successful fetch writes the cache; a failed fetch
falls back to it with a warning, so a client that ran once keeps working offline.
`shared.SecretePackLoader` overrides both — that is the hook the offline tests
use, and it is also how you develop a pack from disk in Studio.

## Adding a module

```lua
Secrete.CreateModule({
    Name = "My Module",
    Description = "What it does.",
    Tab = "Visuals",              -- created on demand
    Init = function(self)         -- once, at registration
        -- the flag is both the save key and the options key
        self:Element("Toggle", { name = "Enabled", flag = "enabled", value = true })
    end,
    OnEnable = function(self)     -- every enable
        local panel = Secrete.Gui.Panel(self:Surface("myModule"))
        self.line = Secrete.Gui.Line(panel, 1)
        self:Track(workspace.ChildAdded:Connect(print))  -- disconnected on disable
    end,
    Apply = function(self)        -- runs on every option change while enabled
        if self.line then
            self.line.Text = tostring(self.options.enabled)
        end
    end,
    OnDisable = function(self)
        self.line = nil
    end,
})
```

| Member | Description |
| --- | --- |
| `Enabled` | Current state. |
| `:Toggle(state?)` | Flip or force state; runs `OnEnable` / `OnDisable`, clears connections and surfaces, saves. |
| `:Track(connection)` | Collected and disconnected when the module disables. |
| `:Surface(name)` | A `ScreenGui` owned by the module, destroyed when it disables. |
| `:Element(kind, props)` | Builds a Rayfield element in the module's tab and mirrors its value into options. |
| `:SetOption(flag, value)` | Write an option; re-runs `Apply` while enabled. |

Supported `kind` values are the Gen2 element names: `Toggle`, `Slider`, `Dropdown`,
`Input`, `Keybind`, `ColorPicker`, `Button`, `Stat`, `Progress`, `Text`, `Divider`.

Three conventions worth keeping:

- **Flags are stable save keys.** Give every value element an explicit `flag`, and
  do not rename it later — that is what keeps saved files valid across versions.
- **Options are the source of truth.** Modules read `self.options`, never the
  element handles, so behaviour is identical when the UI is unavailable.
- **Build once, update in place.** Create your surface in `OnEnable` and write to
  those instances in `Apply`; rebuilding on every option change makes sliders
  flicker and leaves stale handles behind.

## Heartbeat

The hub keeps a [Sentivel](https://www.sentivel.com) uptime monitor updated. It
pings `HUB.HeartbeatURL` once when it starts, then every 60 seconds, so a monitor
that goes quiet means the script stopped running on a client.

- The URL and cadence are two constants at the top of [secrete.lua](secrete.lua).
- Settings tab: switch it off.
- `End` (panic), unload, or a client closing stops the pings. That silence is the
  signal the monitor is watching for.
- A failed ping is counted, never raised — `Secrete.Heartbeat.Failures` and
  `Secrete.Heartbeat.LastError` hold the detail and pinging resumes on the next
  interval.

Rayfield Gen2 has a `heartbeat` window property that does the same job, but it is
preview-channel only today, so the hub drives the ping itself and works on
whichever channel is loaded. One owner, one ping per interval.

A heartbeat key is public by nature: anyone reading this repo can ping it, or
watch the monitor. Treat it as an uptime signal, not a secret.

## Degrading instead of exploding

Every layer is optional:

- No filesystem → state lives in memory for the session, packs come from the
  network each run, and the UI still boots.
- HTTP blocked → packs come from `secrete/cache/`, and the heartbeat reports a
  failure instead of throwing.
- Rayfield fails to load, or an element is refused → the element becomes an inert
  stub, the module keeps its options, and the control is counted as refused. The
  About tab lists what was refused, and boot says so in one notification rather
  than only in a console nobody has open.
- A module that throws inside `Init`/`OnEnable`/`Apply` is caught, logged and
  disabled, and the rest of the hub keeps running.

Element-value persistence is Rayfield's own (`configuration = { autoSave, autoLoad }`),
written to `Rayfield/Configurations/secrete/secrete_<PlaceId>.rfld`. Enable/disable
state is the hub's, in the state file above. `forgetState = true` keeps the module
toggles out of Rayfield's file so the two stores never fight over the same value.

## Development

Studio can read the framework off disk instead of GitHub, and packs can come from
anywhere:

```lua
shared.SecreteDeveloper = true
loadstring(readfile("secrete.lua"))()
```

### Offline tests

`test/run.sh` builds one Luau chunk out of the mocks, the real `secrete.lua` and
the assertions, with each pack's source inlined so the harness compiles it the
same way the hub does in game. No Roblox, no executor, no network:

```bash
test/run.sh          # the place belongs to someone else: dev tools stay locked
test/run.sh owner    # the place belongs to the local player: dev tools apply
```

It runs in two phases. `assertions.lua` covers the boot path, pack loading, the
loader's fetch-cache-offline path, tab creation, element wiring, option
mirroring, surfaces built once and updated in place, the developer gate in both
directions, refusals, fault isolation, the state file, hotkeys, the heartbeat and
panic. `scenarios.lua` then drives whole lifecycles against fresh instances booted
from the hub's own source: packs fetched over the network and cached, an offline
boot served from that cache, two modules enabled and then a re-execution of the
script (they come back on, rendered, on a hub whose previous instance is torn
down), a library missing an element kind, ten simulated minutes of heartbeat
cadence, and a panic followed by a fresh run.

The suite has already caught an unparented overlay, a noclip loop that a fly
toggle disconnected, a connection leaking on every heartbeat toggle, movement
options that did not survive a respawn, fly dying on the new body, a Stats service
returning non-numbers throwing once per frame, a heartbeat switch that claimed the
monitor was being fed when there was no HTTP to feed it with, a teardown that wrote
"everything off" over the state the player had chosen, and an HTTP failure that
reported "the executor has no HTTP" instead of what actually went wrong.

One trap worth knowing before adding tests: a direct `typeof(x)` inside a chunk
compiled by `loadstring` goes to Luau's builtin, not to the mock's override, so the
hub's `typeof` checks would see mock connections and colours as plain tables. The
mock's `loadstring` prepends a line binding the mock's `typeof` as a local; without
it, connections are silently untracked and the suite passes while testing less.

The Luau CLI is expected at `.freebuff/tools/luau.exe`, falling back to `luau` on
`PATH`. It is a local download and is not committed — see `.gitignore`.

### What the tests do not prove

Nothing here has run against the real Roblox client or the real Rayfield build, so
element property names are still a guess in two places: the colour picker's
starting-colour key and the text element's `name`/`body`. That is why every element
goes through one tolerant helper — an element the library refuses becomes an inert
stub and shows up as a refusal. Treat the first in-game run as a smoke test: the
About tab prints the detected executor, filesystem, place-owner state, loaded
packs and refusals.

## License

CC0 1.0 Universal. See [LICENSE](LICENSE).
