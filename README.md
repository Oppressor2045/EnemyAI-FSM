# Enemy AI (FSM)

A finite state machine for enemy AI: Idle -> Chase -> Attack, with Search
(lost sight) and Flee (low health) able to interrupt. Movement reuses the
`GridScanner`/`AStar` modules from the pathfinding project. Vision is
blocked by walls via raycast line-of-sight.

**Key behavior:** losing sight of the target does not make the monster path
straight toward its last known position. `Search` (and `Idle`, while waiting
to detect a target) wander to random nearby points instead, so the monster
doesn't "cheat" by knowing exactly where the target went, and doesn't just
freeze in place.

Stairs and other stepped terrain are walkable: `GridScanner` no longer
compares each cell against a single global floor height. Instead, `AStar`
checks the height difference between adjacent cells directly
(`GridScanner:CanStepBetween`, default max 3 studs) -- small steps (stairs)
stay connected, while a big jump (a wall) does not.

## Setup

1. Install dependencies (Rojo, via Rokit):
   ```bash
   rokit init
   rokit add rojo-rbx/rojo
   ```
2. Serve the project:
   ```bash
   rojo serve
   ```
3. In Roblox Studio, open the Rojo plugin panel and click **Connect**
   (`127.0.0.1:34872` by default).

## Structure

```
src/
  shared/
    GridScanner.luau   -- builds/updates the walkable grid via raycasts
    AStar.luau          -- A* search over the grid
    LineOfSight.luau    -- raycast-based vision check (blocked by walls)
    MonsterFSM.luau      -- Idle/Chase/Attack/Search/Flee state machine
  server/
    MonsterAI.server.luau -- demo: spawns/binds a monster to a player
    PlayerAnimationOverride.server.luau -- swaps the player's default walk/run animation
  starterPlayerScripts/
    SprintToggle.client.luau -- Left Shift toggles running on/off
```

## Usage

Place two parts in `Workspace`:

| Name              | Type | Purpose                              |
|-------------------|------|----------------------------------------|
| `MonsterAreaMin`  | Part | One diagonal corner of the roam area  |
| `MonsterAreaMax`  | Part | The other diagonal corner              |

Optionally place a `Model` named `Monster` with `PrimaryPart` set; otherwise
a placeholder red block is created automatically.

Running `MonsterAI.server.luau`:

- Binds to any player's character as the FSM's target
- Prints state transitions to Output (`[MonsterAI] State: Idle -> Chase`, etc.)
- While moving (`Idle`/`Chase`/`Search`/`Flee`), draws the current A* path
  as colored cube markers (cyan near the monster, gold near the target)
- Deals `AttackDamage` (default 10) to the target's Humanoid every
  `AttackCooldown` seconds (default 1s) while in `Attack` range

### Walk / run / attack animation

Set `WALK_ANIMATION_ID`, `RUN_ANIMATION_ID`, and `ATTACK_ANIMATION_ID` near
the top of `MonsterAI.server.luau` to animation asset ids (e.g.
`"rbxassetid://913402848"`). The monster walks (`MoveSpeed`) during
`Idle`/`Search`, runs (`ChaseSpeed`) during `Chase`/`Flee` -- `WalkSpeed` and
the active looping track switch automatically on each state transition.
The attack animation plays once (not looped) each time a hit lands, in sync
with the `AttackCooldown` damage tick. If your model came from a "Load
Character"-style plugin, check whether it has an `Animate` script --
animation ids are usually already set there (`Animate > walk > WalkAnim`,
`Animate > run > RunAnim`), and you can reuse them. Otherwise, create your
own with Studio's Clip Editor (Avatar tab) and publish it to get an id.

To test `Flee` without a combat system, add `fsm:TakeDamage(80)` right after
`MonsterFSM.new(...)` in `MonsterAI.server.luau`, or lower
`FleeHealthThreshold` in `MonsterFSM.luau` close to `1`.

## Known limitations

- **`GRID_PADDING`/area sizing trade-off.** Same as the pathfinding project:
  `MonsterAreaMin`/`Max` must be sized to avoid exposing open exterior space
  the monster could path through unrealistically.
- `Search` wanders using a purely random target point within `WanderRadius`;
  it doesn't bias toward the direction the target was last seen heading, so
  it can look aimless in open areas. Bias the wander target if you want more
  purposeful-looking searching.
- `CanStepBetween`'s `MaxStepHeight` (default 3 studs) is a single global
  value for the whole grid -- very different stair heights in the same level
  would need per-region tuning.

### Sprint toggle

Press **Left Shift** to toggle running on/off (not hold-to-run) --
`SprintToggle.client.luau` raises `Humanoid.WalkSpeed`, which is enough to
make the default `Animate` script switch from the walk to the run animation
on its own once speed crosses its internal threshold. Adjust `WALK_SPEED`
and `RUN_SPEED` at the top of the script as needed. Always resets to walking
speed on respawn.
