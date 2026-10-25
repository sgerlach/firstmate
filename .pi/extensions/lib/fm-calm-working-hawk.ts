// Firstmate's Calm working hawk for Pi.
//
// The second Calm working scene: a hawk flying back and forth above a repeating land
// strip, drawn in place of the boat when the per-home `config/calm-scene` setting selects
// it. The geometry, cadences, color classes, and freeze/resume state are owned by the
// harness-neutral ./fm-calm-working-hawk-sprite.ts (a tracked symlink into the Claude Code
// Calm mod, which both harnesses share); this module owns only the hawk's standard ANSI
// palette. ./fm-calm-working-ship.ts owns the painting and the widget every scene draws
// through, and `.pi/extensions/fm-calm.ts` owns when the hawk is drawn. docs/calm.md
// owns the captain-facing contract and docs/configuration.md the scene setting.
import {
  CALM_WORKING_HAWK_TICKS_PER_LAND_MOVE,
  CALM_WORKING_HAWK_TICKS_PER_MOVE,
  createCalmWorkingHawkSprite,
  type CalmWorkingHawkColor,
  type CalmWorkingHawkSprite,
} from "./fm-calm-working-hawk-sprite.ts";
import {
  paintCalmWorkingFrame,
  type CalmWorkingAnsiPalette,
  type CalmWorkingSceneAnimation,
} from "./fm-calm-working-ship.ts";

export { CALM_WORKING_HAWK_TICKS_PER_LAND_MOVE, CALM_WORKING_HAWK_TICKS_PER_MOVE };

// The captain's design paints the bird yellow, the mountains blue, and the pines and
// meadow green, whatever the theme. Pi emits those as the standard ANSI foreground
// codes, so the terminal paints its own palette entries for them.
const HAWK_ANSI_FOREGROUND: CalmWorkingAnsiPalette<CalmWorkingHawkColor> = {
  bird: "\u001b[33m",
  mountain: "\u001b[34m",
  pine: "\u001b[32m",
  meadow: "\u001b[32m",
};

export type CalmWorkingHawkAnimation = Omit<CalmWorkingHawkSprite, "frame"> & CalmWorkingSceneAnimation;

export function createCalmWorkingHawkAnimation(): CalmWorkingHawkAnimation {
  const sprite = createCalmWorkingHawkSprite();
  return {
    position: sprite.position,
    direction: sprite.direction,
    pose: sprite.pose,
    landOffset: sprite.landOffset,
    restoreLastRendered: sprite.restoreLastRendered,
    reset: sprite.reset,
    clampToWidth: sprite.clampToWidth,
    tick: sprite.tick,
    render(width: number): string[] {
      return paintCalmWorkingFrame(sprite.frame(width), HAWK_ANSI_FOREGROUND);
    },
  };
}
