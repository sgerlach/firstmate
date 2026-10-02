// Firstmate's harness-neutral Calm working-hawk scene.
//
// The second Calm working animation: a hawk flying back and forth above a repeating
// hand-drawn strip of mountains, pines, and meadow, in place of the sailboat on water.
// Like ./fm-calm-working-ship-sprite.ts, this module owns the geometry, the bounce
// track, the cadences, the color classes, and the freeze/resume state, and paints each
// frame as rows of color-tagged runs rather than bytes, so a harness renders the runs
// its own way. Today only the Claude Code mod draws this scene (../hooks/register.ts
// through ./fm-calm-hawk-raster.ts); the Pi extension keeps the ship. docs/calm.md owns
// the captain-facing contract and docs/configuration.md the scene setting.
//
// Nothing here imports a harness: every glyph is one terminal column under both
// harnesses' width rules, so widths are plain character counts.
//
// Cadence: the Calm scheduler's tick drives three linked cadences from one counter.
//   - Wings: the bird flaps twice, then glides. A flap is one pose per tick, so the two
//     flaps take CALM_WORKING_HAWK_FLAP_POSES.length ticks, and the glide holds the flat
//     pose for CALM_WORKING_HAWK_GLIDE_TICKS ticks (about four seconds). The long glide
//     keeps the bird calm instead of busy.
//   - Bird: one column every CALM_WORKING_HAWK_TICKS_PER_MOVE ticks, bouncing between
//     the edges exactly as the boat does.
//   - Land: one column every CALM_WORKING_HAWK_TICKS_PER_LAND_MOVE ticks, half the
//     bird's speed, so the mountains feel farther away. The strip passes opposite to the
//     bird's travel, as scenery passes a flier, and reverses the moment the bird turns
//     at an edge, as the water's trough follows the boat's new direction.
// Ticks, not wall-clock timestamps, drive every state change, so tests can seek time exactly.
//
// Continuity: one caller-owned instance survives hide/show within one harness process.
// restoreLastRendered() freezes column, direction, land offset, and tick cadence at the
// last painted frame without advancing them for hidden wall time; a fresh session calls
// reset(). State is never a module-level or process-global singleton.
import { CALM_WORKING_SHIP_TICK_MS } from "./fm-calm-working-ship-sprite.ts";

/** Scheduler period: the hawk shares the one Calm tick the ship defines. */
export const CALM_WORKING_HAWK_TICK_MS = CALM_WORKING_SHIP_TICK_MS;
/** The bird moves one column every Nth tick, the boat's speed: 220 * 4 = 880ms per column. */
export const CALM_WORKING_HAWK_TICKS_PER_MOVE = 4;
/** The land moves one column every Nth tick, half the bird's speed: 1760ms per column. */
export const CALM_WORKING_HAWK_TICKS_PER_LAND_MOVE = 8;

/** The three wing poses, each three one-column glyphs wide. */
export const CALM_WORKING_HAWK_POSES = {
  up: "╲v╱",
  glide: "─v─",
  down: "╱v╲",
} as const;

/** One pose per tick while flapping: two full beats, each passing through the flat pose. */
export const CALM_WORKING_HAWK_FLAP_POSES: readonly string[] = [
  CALM_WORKING_HAWK_POSES.up,
  CALM_WORKING_HAWK_POSES.glide,
  CALM_WORKING_HAWK_POSES.down,
  CALM_WORKING_HAWK_POSES.glide,
  CALM_WORKING_HAWK_POSES.up,
  CALM_WORKING_HAWK_POSES.glide,
  CALM_WORKING_HAWK_POSES.down,
];
/** Ticks the glide holds after the two flaps: 18 * 220ms = 3960ms, about four seconds. */
export const CALM_WORKING_HAWK_GLIDE_TICKS = 18;
/** One complete wing cycle: the two flaps, then the glide. */
export const CALM_WORKING_HAWK_CYCLE_TICKS =
  CALM_WORKING_HAWK_FLAP_POSES.length + CALM_WORKING_HAWK_GLIDE_TICKS;

/**
 * The captain's hand-drawn land strip, repeated across the row so the same picture
 * comes back every time: `╱╲` mountains, `↟` pines, and `▁` meadow.
 */
export const CALM_WORKING_HAWK_LAND_STRIP =
  "↟↟▁↟╱╲▁↟↟↟▁▁╱╲╱╲▁↟▁▁↟↟↟▁╱╲▁▁↟▁↟↟▁▁╱╲▁↟↟▁▁▁↟▁╱╲╱╲▁↟↟▁";

/** Terminal columns a string of one-column glyphs occupies. */
function cellCount(text: string): number {
  return Array.from(text).length;
}

const LAND_CELLS: readonly string[] = Array.from(CALM_WORKING_HAWK_LAND_STRIP);
/** Columns in one repeat of the land strip. */
export const CALM_WORKING_HAWK_LAND_COLUMNS = LAND_CELLS.length;
const BIRD_WIDTH = cellCount(CALM_WORKING_HAWK_POSES.glide);

/**
 * The color classes a frame uses. `plain` is uncolored padding; `bird` is the whole
 * bird in every pose; `mountain` is each `╱` and `╲` slope; `pine` is each `↟`; `meadow`
 * is each `▁` of ground. The captain's design paints the bird yellow, the mountains
 * blue, and the pines and meadow green, all basic terminal colors, and each harness maps
 * a class to its own encoding of those colors.
 */
export type CalmWorkingHawkColor = "plain" | "bird" | "mountain" | "pine" | "meadow";

/** One same-colored run of cells inside a frame row. */
export type CalmWorkingHawkRun = {
  readonly text: string;
  readonly color: CalmWorkingHawkColor;
};

/** One painted frame: one or two rows of runs, each row exactly the requested width. */
export type CalmWorkingHawkFrame = readonly (readonly CalmWorkingHawkRun[])[];

export type CalmWorkingHawkSprite = {
  /** Paint one frame that exactly fits `width`, clamping the track to it first. */
  frame(width: number): CalmWorkingHawkFrame;
  /** Advance one scheduler tick: wings every tick, bird and land on their slower cadences. */
  tick(): void;
  /** Return to the state of the last painted frame, discarding later ticks. */
  restoreLastRendered(): void;
  /** Restore the normal initial column, direction, land offset, and cadence. */
  reset(): void;
  /**
   * Clamp the frozen column and direction to `width` without advancing time.
   * Used when a terminal resize lands while the working presentation is hidden.
   */
  clampToWidth(width: number): void;
  /** Current bird column, exposed for deterministic motion assertions. */
  position(): number;
  /** Current travel direction: 1 travelling right, -1 travelling left. */
  direction(): number;
  /** The wing pose the next frame paints. */
  pose(): string;
  /** How many columns the land strip has scrolled; positive means it passed leftward. */
  landOffset(): number;
};

/** The color class of one land glyph. */
export function calmWorkingHawkLandColor(glyph: string): CalmWorkingHawkColor {
  if (glyph === "↟") return "pine";
  if (glyph === "▁") return "meadow";
  return "mountain";
}

/** The wing pose at a tick count: the two flaps first, then the glide, repeating. */
export function calmWorkingHawkPoseAt(ticks: number): string {
  const index = ticks % CALM_WORKING_HAWK_CYCLE_TICKS;
  return CALM_WORKING_HAWK_FLAP_POSES[index] ?? CALM_WORKING_HAWK_POSES.glide;
}

/** The land glyph at an absolute column for a scroll offset; the strip repeats. */
export function calmWorkingHawkLandGlyph(column: number, offset: number): string {
  const index = (((column + offset) % CALM_WORKING_HAWK_LAND_COLUMNS) + CALM_WORKING_HAWK_LAND_COLUMNS) % CALM_WORKING_HAWK_LAND_COLUMNS;
  return LAND_CELLS[index] ?? "▁";
}

export function createCalmWorkingHawkSprite(): CalmWorkingHawkSprite {
  let position = 0;
  let direction = 1;
  let span = 0;
  let offset = 0;
  let ticks = 0;
  let renderedPosition = position;
  let renderedDirection = direction;
  let renderedSpan = span;
  let renderedOffset = offset;
  let renderedTicks = ticks;

  // Reversing the moment the bird lands on an endpoint means the endpoint frame already
  // carries the new direction, so the land's next step follows the turn.
  const settleDirectionAtEdges = (): void => {
    if (span <= 0) return;
    if (position >= span) direction = -1;
    else if (position <= 0) direction = 1;
  };

  const applyWidth = (width: number): void => {
    if (width <= 0) {
      span = 0;
      position = 0;
      return;
    }
    span = Math.max(0, width - BIRD_WIDTH);
    position = Math.min(position, span);
    settleDirectionAtEdges();
  };

  const commitRenderedState = (): void => {
    renderedPosition = position;
    renderedDirection = direction;
    renderedSpan = span;
    renderedOffset = offset;
    renderedTicks = ticks;
  };

  const restoreLastRenderedState = (): void => {
    position = renderedPosition;
    direction = renderedDirection;
    span = renderedSpan;
    offset = renderedOffset;
    ticks = renderedTicks;
  };

  /** The land row: `width` cells of the scrolled strip, adjacent same-colored cells as one run. */
  const land = (width: number): CalmWorkingHawkRun[] => {
    const runs: CalmWorkingHawkRun[] = [];
    for (let column = 0; column < width; column += 1) {
      const glyph = calmWorkingHawkLandGlyph(column, offset);
      const color = calmWorkingHawkLandColor(glyph);
      const last = runs[runs.length - 1];
      if (last !== undefined && last.color === color) {
        runs[runs.length - 1] = { text: last.text + glyph, color };
      } else {
        runs.push({ text: glyph, color });
      }
    }
    return runs;
  };

  // The bird is one bird-colored run, so its wings and body never split into mismatched colors.
  const bird = (): CalmWorkingHawkRun[] => [{ text: calmWorkingHawkPoseAt(ticks), color: "bird" }];

  return {
    position: () => position,
    direction: () => direction,
    pose: () => calmWorkingHawkPoseAt(ticks),
    landOffset: () => offset,

    restoreLastRendered: restoreLastRenderedState,

    reset(): void {
      position = 0;
      direction = 1;
      span = 0;
      offset = 0;
      ticks = 0;
      commitRenderedState();
    },

    clampToWidth(width: number): void {
      applyWidth(width);
    },

    tick(): void {
      ticks += 1;
      if (ticks % CALM_WORKING_HAWK_TICKS_PER_MOVE === 0) {
        if (span <= 0) {
          position = 0;
        } else {
          position = Math.min(span, Math.max(0, position + direction));
          settleDirectionAtEdges();
        }
      }
      // The land steps with the direction in force after the bird's move, so a turn at
      // the edge reverses the scenery on that same tick.
      if (ticks % CALM_WORKING_HAWK_TICKS_PER_LAND_MOVE === 0) offset += direction;
    },

    frame(width: number): CalmWorkingHawkFrame {
      if (width <= 0) return [];

      // A resize lands here before the next frame, so recompute and clamp the track
      // immediately rather than trusting a position measured against the old width.
      applyWidth(width);

      let frame: CalmWorkingHawkFrame;
      if (width < BIRD_WIDTH) {
        // Too narrow for the bird: the land alone.
        frame = [land(width)];
      } else {
        frame = [
          position > 0 ? [{ text: " ".repeat(position), color: "plain" }, ...bird()] : bird(),
          land(width),
        ];
      }

      commitRenderedState();
      return frame;
    },
  };
}
