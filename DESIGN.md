# GuiCondicionado design guide

GuiCondicionado is a SwiftUI menu bar app for macOS 15+ that controls a Midea air conditioner over the
home LAN. The UI is in Brazilian Portuguese. This guide keeps new rooms, devices and controls
consistent with what exists. Every rule is meant to be checkable against the code or a snapshot.

Source of truth, in order: `Components.swift` (tokens and shared controls), `PanelView.swift` (layout,
sections, `Labels`), `Support.swift` (`Format`, `Snapshot`), `ACStore.swift` (edit and sync behavior).
If the code and this guide disagree, fix one of them in the same change.

## 1. Principles

1. **Glanceable in under 2 s.** Opening the panel answers three questions without reading prose: is
   it on, what is the setpoint, how warm is the room. One large setpoint numeral, one lit power
   module, state shown with color *and* shape.
2. **One panel, no windows.** Everything lives in the `MenuBarExtra` `.window` panel. Secondary
   choices open a native `NSMenu` (`PopupMenu`). Don't add sheets, popovers, alerts, a Settings
   window or a Dock presence.
3. **Native macOS feel.** System font, SF Symbols, `Color.primary`/`.secondary` neutrals, native menus,
   and rounded modules in the spirit of Control Center. Controls are standard `Button`s with a
   `ButtonStyle` drawn in SwiftUI (§3). No bundled images or web views.
4. **Never block on the network.** Edits apply locally at once and sync after a debounce. Failures
   show up in the footer, never as a modal. Once the app has a state, it never hides it behind a
   spinner.
5. **Only shows up at home.** The menu bar item exists on the home network, plus when something
   needs the user (setup error, missing Local Network permission). Nowhere else.
6. **Quiet by default.** No notifications and no app sounds; the unit's own beep is a setting
   ("Bipe ao alterar"). Motion only signals state.

## 2. Tokens

The panel is a Bento grid (prototype "C1", branch `prototype/panel-variants`). All tokens live in
`Components.swift`: layout metrics in `enum Bento` (`Components.swift:7`), colors and gradients in
`enum Palette` (`Components.swift:19`). New code reuses these values; a new value needs a reason and an
entry here.

### Color

Neutrals that differ by appearance use `Color(light:dark:)` (`Components.swift:79`), a dynamic `NSColor`
that SwiftUI resolves from the environment's color scheme, so `--dark` snapshots pick the right value.

| Token (`Palette.`) | Light | Dark | Used for |
|---|---|---|---|
| `accent` | **#5CB8FF** (ice blue) | same | the only accent: gradients, `tint`, accent glyphs on dark |
| `accentHigh` / `accentLow` | #7CC9FF / #439FF3 | same | gradient ends |
| `accentDeep` | #2F7BEA | same | power glyph on its white orb, the lit glow |
| `accentGlyph` | `accentDeep` | `accent` | active toggle icon (ice blue is only 1.8:1 on light) |
| `ink` / `inkSecondary` | #031933 at 0.88 / 0.58 | same | text and marks on accent fills |
| `module` / `moduleHover` / `modulePressed` | white 0.62 / white 0.85 / black 0.07 | white 0.06 / 0.085 / 0.115 | neutral card: rest, hover, pressed |
| `tint` / `tintHover` / `tintPressed` | accent at 22 / 28 / 34% over white (#DBEFFF, #D1EBFF, #C7E7FF) | accent 0.17 / 0.22 / 0.27 | active toggle while the unit runs |
| `selected` / `selectedHover` / `selectedPressed` | black 0.08 / 0.10 / 0.13 | white 0.13 / 0.16 / 0.19 | active toggle while off; quiet capsule |
| `hairline` | black 0.06 | white 0.04 | 1 pt inner stroke on every card |
| `moduleShadow` | black 0.07, radius 1.5, y 0.5 | none | lifts light-mode cards |
| `orb` | black 0.05 | white 0.09 | icon circle; glyph button hover |
| `fillOff` | black 0.10 | white 0.17 | slider fill while off |
| `dimValue` | black 0.68 | white 0.72 | "Desligado" on the power module |
| `strongMeta` | black 0.75 | white 0.78 | header room temperature |
| `footer` / `footerStrong` | black 0.45 / 0.60 | white 0.36 / 0.60 | footer status; offline message and gear hover |
| `warning` | system `.orange` | same | offline, blocked, setup and device-error glyphs |
| `litGradient` | `accentHigh` → `accent` (45%) → #47A3F5, top-left to bottom-right | same | lit power module, prominent capsule |
| `fillGradient` | `accentHigh` → `accent` (42%) → `accentLow`, top to bottom over the whole module | same | slider fill while running |

Text uses the system hierarchical styles: `.primary` for values, `.secondary` for captions, `.tertiary`
for the chevron. Hierarchical styles derive from the current foreground style, so inside a view that
already set a custom color (the footer), use an explicit token instead (`footerStrong`).

Semantic mapping (use these and don't invent new ones):

| Meaning | Treatment |
|---|---|
| Running | power module `.lit`; slider `fillGradient` with an `ink` numeral; active toggles `tint` with an `accentGlyph` icon |
| Off | everything stays adjustable; power module neutral with a `.secondary` glyph and `dimValue` text; slider `fillOff`; active toggles `selected` with a `.primary` icon; orb glyphs `.secondary` |
| Active toggle | `.fill` symbol at 22% (16% while off) under the outline, name `.primary` |
| Hover / pressed | the tone's `*Hover` / `*Pressed` fill; lit fills ±0.04 brightness; modules scale to 0.965 when pressed (capsules 0.97) |
| Syncing | footer dot pulses, "Sincronizando…" |
| Idle / fresh | footer dot plus relative time |
| Offline / device error | `warning` icon plus text |
| Disabled (Ventilar) | slider at 0.4 opacity, no hit testing, caption "Sem ajuste ao ventilar" |

**Light vs dark.** Dark follows C1: translucent white cards on the panel material. Light uses frosted
white cards with a hairline and a soft shadow, like Control Center. The accent, gradients and `ink`
don't change; accent glyphs on light surfaces switch to `accentDeep`. Check both with `--dark` snapshots.

### Typography

System font throughout; only the setpoint numeral uses `.rounded`. Sizes are explicit points.

| Role | Size | Weight | Notes |
|---|---|---|---|
| Setpoint numeral | 50 | semibold, rounded | tracking −1.2, `.monospacedDigit()`, numericText transition |
| Setpoint "°" | 28 | medium, rounded | 0.55 opacity, top-aligned, 3 pt down |
| Header title | 15 | semibold | tracking −0.15 (room name) |
| Header readings | 12 | regular; room value medium | `.monospacedDigit()`; value `strongMeta`, the rest `.secondary` |
| Module caption | 11 | regular | `.secondary` ("Modo", "Temperatura") |
| Module value | 13 | semibold | tracking −0.13, one line; menu values may tighten and scale to 0.85 ("Desumidificar") |
| Toggle name | 12 | medium | `.secondary` when inactive, `.primary` when active |
| Room marker | 10.5 | medium | `.monospacedDigit()` |
| Notice title / body | 13 semibold / 12 regular | | body `.secondary`, wraps |
| Capsule | 12 | semibold | |
| Footer and error line | 11 | regular | |

Glyph sizes: orb glyph 17 (power 17 semibold); toggle icon 19 in a 24 pt frame; chevron 10 semibold;
footer gear 12; footer dot 5.

### Spacing, shape and size

| Token | Value | Where |
|---|---|---|
| Panel width | **368** (`Bento.width`), content 336 (`Bento.content`) | `PanelView` |
| Outer padding | 16 (`Bento.padding`) | `PanelView` |
| Grid gap | 8 (`Bento.gap`), the same between rows and columns | grid |
| Row height | 80 (`Bento.row`); the temperature module spans 2 rows (168) | grid |
| Columns | halves 164 (`Bento.half`); thirds split a row equally (106.67) | grid |
| Card radius | 16, `.continuous` (`Bento.radius`) | every module, the slider clip, notices |
| Orb | 36 circle (`Bento.orb`) | 2x1 modules, notices |
| 2x1 module | horizontal padding 12, orb to text 10, caption to value 2, chevron pulled 4 toward the text | `MenuModule`, `PowerModule` |
| Toggle module | icon to name 7, horizontal padding 8 | `ToggleModule` |
| Slider content | padding top 13, leading 14, bottom 8; marks and room marker 12 from the trailing edge | `TemperatureSlider` |
| Tick marks | 1 pt tall; 5 wide at 0.16 opacity, 8 wide at 0.26 for 20° and 25° | `TemperatureSlider` |
| Header | padding 1 top, 4 at the sides, 12 below | `PanelHeader` |
| Footer | 11 above, 4 at the sides, status gap 6 | `FooterRow` |
| Notice | padding 14, orb to text 12, text to actions 14, actions 8 apart and aligned with the text | `Notice` |
| Capsule | height 28, horizontal padding 14 | `CapsuleButton` |
| Glyph button | 26 circle, with −7 vertical padding so the footer stays as tall as its text | footer gear |

Panel skeleton, top to bottom: `PanelHeader` → grid → optional error line → `FooterRow`. The grid:
1. Rows 1–2: `TemperatureSlider` (left half, both rows); `PowerModule` above the Modo `MenuModule` (right half).
2. Row 3: the Ventilação and Direção do ar `MenuModule`s (halves).
3. Row 4: the Eco, Turbo and Dormir `ToggleModule`s (thirds).

With no state to show, a full-width `Notice` replaces the grid. The header (name only) and the footer
(gear only) stay, except that a setup error has no header.

## 3. Components

Shared controls live in `Components.swift`; panel sections (`PanelHeader`, `FooterRow`, `Notice`) are
`private` in `PanelView.swift`. Every button uses a custom `ButtonStyle` drawn in
SwiftUI, because system styles render as yellow placeholders in `ImageRenderer` snapshots. Hover comes
from `.onHover`, pressed from `configuration.isPressed`, and every control sets an explicit `contentShape`.

**ModuleBackground and ModuleButtonStyle** (`Components.swift:112`, `:148`). The card behind every
module, and the button style that puts a label on it.
- Tones: `.neutral`, `.tinted` (active toggle while running), `.selected` (active toggle while off) and
  `.lit` (power on). Each has rest, hover and pressed fills (§2). `.lit` is `litGradient` with a white
  0.18 inner stroke and an `accentDeep` 0.28 glow (radius 9, y 6).
- While hovered or pressed, the style sets the `moduleHighlighted` environment value, so a part of the
  label (the chevron) can react.
- Use it for every module button. Don't put a system-styled button inside a module.

**PowerModule** (`Components.swift:246`). 2x1, top right; the only power control.
- On: `.lit`, a white 0.96 orb with an `accentDeep` `power` glyph, "Ar-condicionado" in
  `inkSecondary`, "Ligado" in `ink`. Off: neutral, a `.secondary` glyph on `orb`, "Desligado" in
  `dimValue`.
- The tooltip names the action: "Desligar" / "Ligar". Accessibility: label "Ar-condicionado", value
  "Ligado"/"Desligado", toggle trait.

**MenuModule** (`Components.swift:194`). 2x1: orb, caption, current value and `chevron.down`. It opens
a `PopupMenu`.
- Used for Modo, Ventilação and Direção do ar. The orb glyph is `.primary` while running and
  `.secondary` while off. The chevron is `.tertiary`, and `.secondary` on hover.
- The value is the full label (§5). Tooltips: "Escolher modo", "Escolher ventilação", "Escolher direção
  do ar". Accessibility label = caption, value = current value, hint = tooltip.
- Use for 3–6 enumerated options. Like C1, these open a menu instead of cycling on click, so every
  option is visible at once.

**ToggleModule** (`Components.swift:283`). One third of a row, icon over name: Eco, Turbo, Dormir.
- Active: the symbol's `.fill` variant at 22% (16% while off) under the outline, name `.primary`. While
  running: tone `.tinted`, icon `accentGlyph`. While off: tone `.selected`, icon `.primary`. Inactive:
  icon `.primary` at 0.85, name `.secondary`.
- Tooltips: "Ligar Eco" / "Desligar Eco", "Ligar Turbo" / "Desligar Turbo", "Ligar modo Dormir" /
  "Desligar modo Dormir". Toggle trait, value "Ligado"/"Desligado". Eco and Turbo are mutually
  exclusive in the store, not the view.
- The symbol needs an outline and a `.fill` variant (`leaf`, `bolt`, `moon`).

**TemperatureSlider** (`Components.swift:329`). The tall module: a vertical fill slider over 16–30 in
whole degrees.
- Anatomy: caption "Temperatura" top-leading; the setpoint numeral bottom-leading; 14 tick marks on the
  trailing edge, one per degree boundary; a room marker ("Sala 23°" plus a 12 × 2 bar) at the room
  temperature, kept on the marks and hidden in Ventilar. The fill rises to `(value − 15) / 15` of the
  height, with a 1 pt white top edge (0.55, or 0.35 while off). The content is drawn twice: once over
  the card, and once in `ink`, masked to the fill.
- Input: drag, or click anywhere to jump (value = rounded level × 15 + 15). Scroll wheel or trackpad
  steps once per wheel notch or per 24 pt of trackpad travel, ignoring momentum, through
  `ScrollWheelMonitor` (`Components.swift:565`), a local event monitor installed only while the pointer
  is over the slider. VoiceOver increments and decrements through `accessibilityAdjustableAction`.
  `onChange` fires only when the whole-degree value differs; scroll and VoiceOver call `onStep(±1)`.
- States: hover and drag lighten the card. Off = gray `fillOff` fill and no navy layer, still
  adjustable. Ventilar = 0.4 opacity, no hit testing, caption "Sem ajuste ao ventilar".
- Use for one numeric range per panel. Don't use it for enumerated values.

**Orb** (`Components.swift:179`). A 36 pt circle with a 17 pt glyph, filled with `orb` unless the
module overrides it.

**CapsuleButton** (`Components.swift:609`). Recovery actions in notices. Prominent = `litGradient` with
`ink` text; quiet = `selected`. Hover is ±0.04 brightness or the next `selected` step; pressing scales
to 0.97.

**GlyphButtonStyle** (`Components.swift:660`). The footer gear: a `footer` glyph in a 26 pt circle hit
area; hover shows an `orb` circle and a `footerStrong` glyph. Every use needs `.help` and an
accessibility label.

**PopupMenu** (`Components.swift:690`). The only way to pick from a list. `PopupMenu.show([...])` opens a
native `NSMenu` at the pointer. It exists because SwiftUI's `Menu` can't take a custom label in a menu
bar window.
- Entries: `.item(title, symbol:, checked:)` and `.separator`. The current value is `checked: true`;
  `symbol` adds an SF Symbol image (the Modo and Direção do ar menus). Group items with separators:
  actions, then preferences, then "Sair".
- `selectionUnderPointer: true` opens the menu with the checked item under the pointer, like a pop-up
  button. The module menus use it; the settings menu doesn't.
- Don't build custom SwiftUI dropdowns or popovers.

**PanelHeader** (`PanelView.swift:129`). Room name leading; "23° agora · lá fora 18,5°" trailing, each
half left out when the unit doesn't report it.

**FooterRow** (`PanelView.swift:172`). Status leading, settings gear (`gearshape`, tooltip "Ajustes")
trailing. Status variants:
`.idle` → 5 pt dot + relative time, refreshed by `TimelineView` every 30 s;
`.syncing` → pulsing dot + "Sincronizando…";
`.offline(msg)` → `warning` `exclamationmark.circle.fill` + the message in `footerStrong`.
Notices pass no status, because the card already explains it, but keep the gear so "Sair" is always
reachable. The settings menu holds app-level items only: "Atualizar agora", "Bipe ao alterar",
"Abrir ao iniciar o Mac", "Sair do GuiCondicionado".

**Notice** (`PanelView.swift:222`). A full-width card that replaces the grid when there is no state to
show: an orb (`warning` glyph for problems, `.secondary` while connecting, pulsing while busy), a 13
semibold title, a 12 pt body, then up to two `CapsuleButton`s.
- Used for the setup error, Local Network blocked ("Abrir Ajustes" + "Tentar de novo"), connecting,
  and first load failed ("Tentar de novo"). Don't use it while a state exists; transient errors go in
  the footer.

## 4. States and feedback

| Situation | What the panel shows | Copy |
|---|---|---|
| Config missing / invalid | `Notice` `exclamationmark.triangle`, no header | "Configuração" + "Nenhum ar-condicionado configurado." or "Não encontrei a configuração em ~/.config/ac-menubar/config.json." |
| Local Network blocked (`Sync.blocked`) | `Notice` `lock.shield` + "Abrir Ajustes" (opens Privacy_LocalNetwork) and "Tentar de novo" | "Sem acesso à rede local" / "O macOS bloqueou a conexão com o ar. Em Ajustes do Sistema → Privacidade e Segurança → Rede Local, ative o GuiCondicionado. Se uma VPN estiver ligada, desligue-a." |
| First load | `Notice` `air.conditioner.horizontal`, pulsing | "Conectando…" / "Falando com o ar-condicionado." |
| First load failed | `Notice` `wifi.exclamationmark` + "Tentar de novo" | "Sem conexão" + offline message |
| Has state, write or poll failed | the grid stays; the footer shows an orange icon and the message | offline message (below) |
| Device reports an error code | orange line above the footer | "O ar informou o código de erro 5." |
| Mode Ventilar | slider at 0.4 opacity and not hittable, room marker hidden | "Sem ajuste ao ventilar" |
| On | lit power module, blue slider fill, blue active toggles, filled menu bar icon | menu bar shows setpoint |
| Off | neutral power module, gray slider fill, gray active toggles, outline menu bar icon | menu bar shows room temperature |

Offline messages (`ACStore.message(for:)`): "O ar não respondeu.", "O ar recusou a chave salva.",
otherwise MideaKit's pt-BR `errorDescription` (`Sources/MideaKit/Bytes.swift:62`). EHOSTUNREACH
isn't an offline message: it sets `Sync.blocked`, which shows the Local Network notice.

**Optimistic edit + debounce rule** (`ACStore.edit`):
1. Mutate a copy of the state; if nothing changed, stop (no publish, no write).
2. Publish the new state immediately, so the UI never waits for the device.
3. Bump `revision`, cancel any pending write, schedule `apply()` after the debounce:
   **600 ms for the setpoint** (slider drag and scroll), **150 ms for everything else** (toggles, menus).
4. While a write is pending, polls are skipped, and device reports older than the current revision
   are dropped, so a slow reply never snaps the UI back.
5. A failed write keeps the optimistic state and shows the offline footer. The next successful poll
   reconciles.

## 5. Copy guidelines (pt-BR)

- **The same full names in modules and menus.** A module's value column is about 78 pt, enough for
  every label ("Desumidificar" tightens slightly).

  | Setting | Labels, in menu order |
  |---|---|
  | Modo | Refrigerar, Desumidificar, Ventilar, Automático (no Aquecer: this unit only cools) |
  | Ventilação | Automática, Baixa, Média, Alta |
  | Direção do ar | Desligada, Vertical, Horizontal, Ambas |

  Watch gender agreement: *o modo* Automático, *a ventilação* Automática, *a direção* Desligada /
  Ambas. All mappings live in `enum Labels`; never inline a label in a view.
- **Sentence case** everywhere: "Atualizar agora", "Abrir ao iniciar o Mac", "Tentar de novo". Proper
  names keep their capitals ("Ajustes do Sistema", "Abrir Ajustes", "Mac").
- **Tone: friendly, brief, concrete.** Call the unit "o ar". Say what happened, then how to fix it,
  in short steps: "O macOS bloqueou a conexão com o ar. … Se uma VPN estiver ligada, desligue-a."
  Full sentences end with a period; labels, titles and buttons don't.
- **Buttons and menu items start with an infinitive verb**: "Abrir Ajustes", "Atualizar agora",
  "Sair do GuiCondicionado". Tooltips name the action, not the state: "Ligar" / "Desligar".
- **Progress** uses the single ellipsis character: "Sincronizando…", "Conectando…". Unknown values
  use an em dash "—".
- **Numbers** always go through `Format` (`Support.swift:6`): the value rounds to the nearest 0.5,
  whole numbers drop the decimal, and decimals use a comma: "21°", "20,5°". Never interpolate a
  `Double` or use `%.1f` directly. Units: always "°" without C ("21°", "lá fora 18,5°"); the setpoint
  numeral draws the "°" as a separate smaller glyph.
- **Relative time**: "Atualizado agora" (< 60 s), "Atualizado há 1 min", "Atualizado há 12 min",
  "Aguardando o ar" before the first read.
- **Menu bar text**: the setpoint while on, the room temperature while off, nothing if there's no
  state (`ACStore.menuBarText`).

## 6. Motion and iconography

- **SF Symbols only.** No bundled images in the UI. Outline = off/inactive, `.fill` = on/active
  (`moon`/`moon.fill`, `air.conditioner.horizontal`/`.fill`).
- **Rendering.** Everything is monochrome via `foregroundStyle`; no view sets a symbol rendering mode.
  Use `.hierarchical` when a multi-layer symbol needs depth but no state colors, and `.palette` only
  when its layers carry state (neither is used yet).
- **Symbol effects only signal ongoing activity,** and there are two, both `.pulse` with `.repeating`:
  the footer's "Sincronizando…" dot (`FooterRow`) and the symbol of a busy `Notice` ("Conectando…").
  No decorative or attention-seeking effects.
- **The fan glyph is deliberately static.** The Ventilação module shows a plain `fan` symbol, running
  or not, because the design prefers no constant motion in the panel while the unit runs. Don't add
  a rotation or any other looping effect to a module icon.
- **Every repeating effect requires `onScreen && !reduceMotion`.** `onScreen` is
  `@Environment(\.panelOnScreen)` (`Components.swift:91`) and `reduceMotion` is
  `@Environment(\.accessibilityReduceMotion)`. `PanelView` sets `panelOnScreen` from its window's
  occlusion state through `OnScreenReader` (`Components.swift:528`), because `MenuBarExtra` keeps the
  window alive offscreen and a hidden effect keeps rendering. Before this rule, a hidden spinning fan
  (since removed) cost 7–10% CPU for as long as the unit ran (rule 8.7). Snapshots skip the reader
  (§9).
- **Numbers** animate with `.contentTransition(.numericText(value:))` and `.monospacedDigit()` (the
  setpoint numeral), so digits don't jitter.
- **Durations 0.12–0.22 s**, no bounce. Panel content swaps between states without transitions.

  | What | Duration | Curve | Where |
  |---|---|---|---|
  | Press-in scale | 0.16 | ease-out | `ModuleButtonStyle`, `CapsuleButton` |
  | Hover fill | 0.18 | ease-out | `ModuleButtonStyle`, `CapsuleButton` |
  | Tone change (lit, tinted, selected) | 0.22 | ease-in-out | `ModuleButtonStyle`, `PowerModule` |
  | Toggle on/off | 0.2 | ease-in-out | `ToggleModule` |
  | Slider fill and numeral | 0.2, 0.12 while dragging | `.snappy` | `TemperatureSlider` |
  | Slider lit/gray | 0.22 | ease-in-out | `TemperatureSlider` |
  | Footer gear hover / press | 0.16 / 0.12 | ease-out | `GlyphButtonStyle` |

- Current symbol set, by meaning (from `systemName:`, `symbol:` and `enum Labels`):
  - The unit: `air.conditioner.horizontal` (`.fill` while on) in the menu bar label and the
    "Conectando…" notice.
  - Power: `power`. Fan: `fan`. Menu and settings: `chevron.down`, `gearshape`.
  - Modo (`Labels.modeSymbol`): `snowflake` Refrigerar, `drop` Desumidificar, `wind` Ventilar,
    `a.circle` Automático. `sun.max` (Aquecer) is mapped but not in the menu.
  - Direção do ar (`Labels.swingSymbol`): `arrow.down` Desligada, `arrow.up.and.down` Vertical,
    `arrow.left.and.right` Horizontal, `arrow.up.and.down.and.arrow.left.and.right` Ambas.
  - Toggles: `leaf`, `bolt`, `moon`, each with its `.fill` variant.
  - Status: `circle.fill` (syncing dot), `exclamationmark.circle.fill` (offline footer),
    `exclamationmark.triangle` (setup notice), `exclamationmark.triangle.fill` (device error line),
    `lock.shield` (Local Network blocked), `wifi.exclamationmark` (first load failed).

  Reuse these before adding new ones, and give each symbol one meaning.

## 7. Menu bar behavior

- **Visibility.** `MenuBarExtra(isInserted:)` is driven by `isVisible = home || setupError != nil ||
  sync == .blocked` (`ACStore.updateVisibility`). "Home" (`HomeNetworkMonitor`) needs two things:
  some interface (Wi-Fi, Ethernet or any other) has an IPv4 address on the saved air conditioner's
  /24, and the unit itself, matched by device id, has answered on this network (a discovery reply or
  a successful request). The /24 alone isn't enough: every router of a given ISP or brand tends
  to ship the same default LAN, so a friend's network can look identical.
  - **Shows** as soon as the unit answers: discovery runs right away, then one TCP try if it's
    silent. Launched with the unit switched off, the item stays hidden until the unit answers.
  - **Stays** while an interface remains on the /24, even when the unit stops answering (switched
    off, or a VPN such as NordVPN blocking the LAN). The panel then shows the offline message, "O ar
    não respondeu." or "Sem acesso à rede local (VPN?)". Failed requests never hide the item.
  - **Hides** 10 s after the /24 address is gone, or after a network change until the unit answers
    again. A network change is a different set of addresses on the /24 (leaving Wi-Fi and joining
    another network counts, even with the same address) or the path going unsatisfied and coming
    back. Interfaces outside the /24, such as a VPN's `utun` or a VM bridge, don't count.
  - **Exceptions:** the item stays visible while blocked (macOS denied Local Network access,
    `MideaError.localNetworkDenied`) or with a setup error, so the panel can say what to do.
- **Label.** One item: the symbol plus text, `Text("\(Image(systemName:)) 21°")`. Outline symbol when
  off, `.fill` when on. With no state, the label is the symbol alone.
- **Template rendering.** The menu bar renders the label as a monochrome template that follows the
  menu bar appearance. Don't apply colors, palette rendering or symbol effects to it.
- **No Dock icon, no app menu.** `LSUIElement = true` (`Resources/Info.plist:21`). Quitting is
  "Sair do GuiCondicionado" in the footer menu.
- **One item total**, even with several devices (§9).

## 8. Performance rules for UI code

The app once hit a runaway SwiftUI update loop that grew it to **19 GB**. These rules are mandatory.

1. **The App body must not observe the main store.** `GuiCondicionadoApp` holds `ACStore.shared` as
   a plain `let` and observes only `MenuBarVisibility`, a tiny object that publishes the
   `isInserted` Bool. Only views that render state (`PanelView`, `MenuBarLabel`) observe a store.
2. **Bindings handed to SwiftUI ignore same-value writes.** `MenuBarExtra(isInserted:)` writes back
   to its binding. The setter must return early when the value is unchanged and call
   `objectWillChange.send()` only on a real change (`MenuBarVisibility.isVisible`). Apply this to any
   new `Binding` that crosses into a scene or AppKit-backed view.
3. **Never assign a `@Published` value inside `body`**, inside a computed property that `body` reads,
   or in `onAppear`/`onChange` handlers that run on every render. Derived values are computed
   properties (`ACStore.isOn`, `ACStore.menuBarText`).
4. **No same-value `@Published` assignments on timers or polls.** `@Published` fires
   `objectWillChange` even when the new value equals the old one. Compare first
   (`if x != new { x = new }`, as `ACStore.setSync` does), or use `.removeDuplicates()` on Combine
   pipelines.
5. **Cadence.** Device poll every 60 s while at home, plus once each time the panel opens
   (`NSWindow.didBecomeKeyNotification`). Home detection has no timer while away or once confirmed:
   NWPathMonitor reports network changes (settled for 2 s), and reading the interfaces is one
   getifaddrs call, with no subprocesses. Discovery (a 2.5 s UDP broadcast) only runs on the unit's
   /24: while unconfirmed, right away, then 30 s, 1, 2 and 4 min later, then every 5 min; at home,
   when a request fails, on the same backoff. The backoff restarts on a network change or when the
   unit answers. Background sleeps carry a tolerance (the poll 10 s) so macOS can batch wake-ups.
   Clock-driven text uses `TimelineView(.periodic(..., by: 30))`, never a publishing timer. Don't add
   faster timers.
6. **Watchdog.** `Watchdog` (`Diagnostics.swift`) checks every 5 s on its own queue (2 s leeway), so
   a stuck main thread can't stall it. It calls `exit(1)` when the physical footprint passes
   **1 GB**, or when the app has used over **90% of a core for 60 s** straight, a spin that doesn't
   allocate. Before quitting it logs to `~/Library/Logs/GuiCondicionado.log` and writes a one-second
   stack sample (`/usr/bin/sample`, waiting at most 3 s) to
   `~/Library/Logs/GuiCondicionado-sample.txt`, which shows where the app was stuck. The thresholds
   are constants on `Watchdog`. It's a seatbelt, not a fix: if it fires, find the loop.
7. **Repeating effects only while the panel is on screen.** `MenuBarExtra` keeps the panel's window
   alive after it closes, so a repeating `symbolEffect` keeps rendering behind it: a hidden spinning
   fan (since removed) cost 7–10% CPU for as long as the unit ran. Gate every repeating effect on
   `onScreen && !reduceMotion`, with `onScreen` from `@Environment(\.panelOnScreen)`
   (`Components.swift:91`). `PanelView` sets it from the window's occlusion state through
   `OnScreenReader` (`Components.swift:528`). Don't start any other repeating animation without it.
8. **Check it:** leave the app running for 10 minutes with the panel open, then closed;
   `footprint GuiCondicionado` should stay flat; a steadily climbing
   footprint means an update loop.

## 9. Extending the app

**Adding a room or device (device switcher pattern).**
- [ ] Add the entry to `devices` in `~/.config/ac-menubar/config.json`; `name` is the room shown in
  the `PanelHeader` ("Sala", "Quarto").
- [ ] One store per device. `ACStore` is "App state for one air conditioner": polling, optimistic
  edits and recovery for that device only. A different device kind (e.g. a TV) gets its own store
  type with the same edit/debounce/revision contract.
- [ ] A small root object owns the store list and the selected device. It must not forward child
  `objectWillChange` (rule 8.1). Persist the selection in `UserDefaults`, like `beep`.
- [ ] Switcher UI: with two or more devices, the room name in `PanelHeader` becomes a plain button with
  a 10 pt semibold `chevron.down` (the same affordance as a `MenuModule`). It opens `PopupMenu` with
  one checked item per room and `selectionUnderPointer: true`. With one device there is no chevron.
  Draw the button with a custom `ButtonStyle` (§3) and keep its hit target at least 28 pt tall (§10).
- [ ] The menu bar keeps one item that shows the selected device's text.
- [ ] A new device kind follows the panel skeleton (§2): `PanelHeader` (name and readings), a Bento
  grid of 80 pt rows, `FooterRow`. Power goes in a `PowerModule` (it hard-codes "Ar-condicionado"
  today, so make the title a parameter first), enumerated choices in `MenuModule`s, booleans in
  `ToggleModule`s, one numeric range in a tall slider module. Reuse `FooterRow` and `Notice` unchanged;
  both are `private` in `PanelView.swift`, so move them to a shared file when a second panel needs them.

**Adding a control.** Pick the lightest component that fits:

| The setting is… | Use | Example |
|---|---|---|
| a boolean | `ToggleModule`, three per row (106.67 × 80); a fourth starts a new row | Eco, Turbo, Dormir |
| 3–6 named options | `MenuModule` + `PopupMenu`, two per row (164 × 80) | Modo, Ventilação, Direção do ar |
| a numeric range | `TemperatureSlider` pattern: drag, scroll wheel, `accessibilityAdjustableAction`, 600 ms debounce | Temperatura |
| app-level, rare or an action | footer gear `PopupMenu` item | Bipe ao alterar |
| more than 6 options, free text, or multi-step | rethink it; the panel doesn't do forms | — |

- [ ] Labels, and symbols for enumerated options, go in `enum Labels` (`PanelView.swift:305`). The module
  and its menu show the same full label (§5).
- [ ] The store method goes through `ACStore.edit(debounce:)`; mutually exclusive features are resolved
  there (`toggleEco`, `toggleTurbo`). The default debounce is 150 ms; a numeric range uses 600 ms
  (`setTarget`).
- [ ] Disable controls that don't apply in the current mode (0.4 opacity, no hit testing) and say why
  in the caption, as the slider does in Ventilar.
- [ ] Build on `ModuleButtonStyle` and `ModuleBackground`, never a system button style (§3).
- [ ] `.help` (a parameter of `MenuModule` and `ToggleModule`), an accessibility label and a value on
  every control (§10).
- [ ] A repeating effect needs `onScreen && !reduceMotion` (§6, rule 8.7).

**Verify with snapshots** (no device or network needed; `ACStore(preview:)` never connects):

```sh
GuiCondicionado --snapshot out.png [--dark] [--scenario on|off|connecting|offline|permission]
```

`Snapshot` (`Support.swift:45`) renders `PanelView` with sample data, writes the PNG and exits before
any store or scene exists.
- **Scenarios:** `on` (the default), `off` (`--off` is an alias), `connecting` (no state, so the
  "Conectando…" notice), `offline` (the grid stays, the footer says "O ar não respondeu." and
  "Atualizado há 5 min") and `permission` (the Local Network notice). An unknown name exits with
  status 1 and lists the valid ones. No scenario shows the setup error or the first-load-failed notice
  (§4); add one to `Snapshot.Scenario` when you change them.
- **Flags:** `--dark` renders the dark appearance, otherwise light.
- **Sample state:** room "Sala", 21°, Refrigerar, Ventilação Automática, Direção do ar Vertical, Eco on
  (Turbo and Dormir off), 23° inside, 18,5° outside. Power is on, except in `off`.
- **Output:** 2× scale on a flat `windowBackgroundColor`, not the panel's material. The panel is
  `Bento.width` = 368 pt wide, so the PNG is 736 px.

Render light and dark for every scenario your change touches, and check that the width stays at 368
and nothing truncates. `PanelView` skips `OnScreenReader` in snapshots (`PanelView.swift:41`), because
`ImageRenderer` draws AppKit views as a placeholder; `panelOnScreen` then keeps its default, true.
`ImageRenderer` also doesn't animate symbol effects or render `NSMenu`s, so check menus, motion,
Reduce Motion and the on-screen gating in the running app.

## 10. Accessibility

- **Hit targets ≥ 28 × 28 pt** for anything new. Existing sizes, from `Bento`: `PowerModule` and
  `MenuModule` 164 × 80 (`Bento.half` × `Bento.row`), `ToggleModule` 106.67 × 80, `TemperatureSlider`
  164 × 168, `CapsuleButton` 28 high. The one exception is the footer gear, a 26 pt circle
  (`GlyphButtonStyle`). Every custom control sets `contentShape` so the whole shape is hittable.
- **Labels.** Icon-only buttons need `.help` and `.accessibilityLabel` (the gear: "Ajustes"). Tooltips
  are pt-BR and name the action ("Ligar Eco", "Escolher modo"); the gear's and the slider's name the
  control or say how to use it ("Ajustes", "Arraste para ajustar a temperatura", "Sem ajuste ao
  ventilar"). Modules label themselves with their caption or name and give a value ("Ligado" /
  "Desligado", or the current option); `PowerModule` and `ToggleModule` add the toggle trait, and
  `MenuModule` uses its tooltip as the hint. Custom controls built from gestures need
  `.accessibilityElement`, a label, a value ("21 graus") and `.accessibilityAdjustableAction` for ±1;
  `TemperatureSlider` has all four.
- **Contrast.** Neutrals inherit system contrast. The accent is strong on dark (about 7.7:1) but weak on
  light: white on accent is about 2.2:1 and accent on the light panel about 1.8:1. Text on accent
  fills is `ink`, and accent glyphs on neutral surfaces use `accentGlyph` (§2). Never put essential
  text in accent; the accent may only reinforce a state that something else also shows.
- **Not by color alone.** Every state change also changes shape, symbol variant, position or text:
  the power module reads "Ligado" / "Desligado", an active toggle shows its `.fill` symbol and a
  `.primary` name, the slider fill rises with the value, the menu bar symbol fills when on, and
  warnings always pair orange with an icon and a sentence.
- **Reduce Motion.** Implemented: with `accessibilityReduceMotion` on, both repeating symbol effects
  (the sync and busy `.pulse`) stay off (§6). One-shot animations (0.12–0.22 s fades, the press-in
  scale, the numeric-text change) still run.

## Open design questions

1. **No keyboard path to the setpoint.** Nothing in `Sources/GuiCondicionado` uses `.focusable` or
   `.onKeyPress`, so the arrow keys can't change the temperature; only the pointer and VoiceOver's
   adjustable action can (`Components.swift:369` and `:391`). Make `TemperatureSlider` focusable and
   step on up and down arrows through `onStep`.
2. **The footer gear is 26 × 26 pt,** below the 28 pt minimum (`Components.swift:672`). It keeps the
   footer as tall as its text with −7 pt vertical padding (`PanelView.swift:208`). Grow the hit area
   or accept it as the one exception.
3. **The 16–30 range is written in three places:** `TemperatureSlider.range` (`Components.swift:330`),
   the clamp in `ACStore.setTarget` (`ACStore.swift:290`) and MideaKit's `setState`
   (`Sources/MideaKit/AirConditioner.swift:98`). The room marker clamp also hard-codes 14
   (`Components.swift:408`). Give the app target one constant for the slider and the store; MideaKit
   keeps its own protocol limit.
