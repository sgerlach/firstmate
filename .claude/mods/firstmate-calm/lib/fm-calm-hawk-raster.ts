// The Calm working hawk on Claude Code's Raster: its key and its palette.
//
// ./fm-calm-raster.ts owns the cell packing every scene shares; this module owns only
// what the hawk adds to it, and ../hooks/register.ts owns when the hawk is drawn.
//
// The captain's design paints the bird yellow, the mountains blue, and the pines and
// meadow green, all basic terminal colors, whatever the theme. The Raster takes only
// RGB, so each class carries the RGB value xterm assigns to that standard ANSI color
// (yellow 3, blue 4, green 2); the terminal then paints the nearest color its 256-color
// quantization offers, which docs/calm.md records beside the ship's palette gap.
import { CALM_RASTER_DEFAULT_COLOR, type CalmRasterPalette } from "./fm-calm-raster.ts";
import type { CalmWorkingHawkColor } from "./fm-calm-working-hawk-sprite.ts";

/** The Raster's `key` inside the Spinner drawing, what `$.ui.blit` names to repaint it. */
export const CALM_HAWK_RASTER_KEY = "firstmate-calm-working-hawk";

/** xterm's RGB for standard ANSI yellow (color 3). */
export const CALM_HAWK_YELLOW = 0xcdcd00;
/** xterm's RGB for standard ANSI blue (color 4). */
export const CALM_HAWK_BLUE = 0x0000ee;
/** xterm's RGB for standard ANSI green (color 2). */
export const CALM_HAWK_GREEN = 0x00cd00;

/** Foreground per hawk color class: the one theme-independent set. */
export const CALM_HAWK_RASTER_PALETTE: CalmRasterPalette<CalmWorkingHawkColor> = {
  plain: CALM_RASTER_DEFAULT_COLOR,
  bird: CALM_HAWK_YELLOW,
  mountain: CALM_HAWK_BLUE,
  pine: CALM_HAWK_GREEN,
  meadow: CALM_HAWK_GREEN,
};
