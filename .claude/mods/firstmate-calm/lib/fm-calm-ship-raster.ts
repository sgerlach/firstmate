// The Calm working ship on Claude Code's Raster: its key and its palette.
//
// ./fm-calm-raster.ts owns the cell packing every scene shares; this module owns only
// what the ship adds to it, and ../hooks/register.ts owns when the ship is drawn.
//
// The palette is Claude Code's own: the water takes the theme's spinner blue and the
// whole boat takes the Claude orange of the stock spinner, one set per theme family.
// The family follows the `theme` setting's prefix (`dark*` or `light*`); `auto`,
// custom, missing, and unreadable values use the light set as the both-readable
// fallback. The Pi extension keeps its standard ANSI colors and is unaffected.
import { CALM_RASTER_DEFAULT_COLOR, type CalmRasterPalette } from "./fm-calm-raster.ts";
import type { CalmWorkingShipColor } from "./fm-calm-working-ship-sprite.ts";

/** The Raster's `key` inside the Spinner drawing, what `$.ui.blit` names to repaint it. */
export const CALM_SHIP_RASTER_KEY = "firstmate-calm-working-ship";

/** Foreground per ship color class. */
export type CalmShipRasterPalette = CalmRasterPalette<CalmWorkingShipColor>;

/** The two theme families Claude Code's built-in themes fall into. */
export type CalmShipPaletteFamily = "dark" | "light";

/**
 * Claude Code's own colors per theme family: the dark and light spinner blues for the
 * water and the Claude orange of the stock spinner for the boat, from the app's
 * built-in theme tables.
 */
export const CALM_SHIP_RASTER_PALETTES: Readonly<Record<CalmShipPaletteFamily, CalmShipRasterPalette>> = {
  dark: { plain: CALM_RASTER_DEFAULT_COLOR, water: 0x93a5ff, boat: 0xd77757 },
  light: { plain: CALM_RASTER_DEFAULT_COLOR, water: 0x5769f7, boat: 0xd77757 },
};

/**
 * The palette family for a `theme` setting value: values starting with `dark` select
 * the dark set, values starting with `light` select the light set, and every other,
 * missing, or non-string value selects the both-readable light fallback.
 */
export function calmShipPaletteFamily(theme: unknown): CalmShipPaletteFamily {
  return typeof theme === "string" && theme.startsWith("dark") ? "dark" : "light";
}
