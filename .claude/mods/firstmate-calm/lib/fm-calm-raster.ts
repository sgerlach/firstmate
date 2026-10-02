// Packs one Calm working-animation frame as Claude Code Raster cells.
//
// The Claude Code mods API draws a grid of colored cells as one `Raster` element whose
// `cells` prop is base64 of `columns * rows` little-endian u32 triplets
// `[codePoint, foreground, background]`; `$.ui.blit` repaints a mounted Raster with a
// new `cells` string without a render pass. This module owns that packing for every
// scene: a frame is rows of color-tagged runs, and a palette maps each scene's color
// classes to Raster colors. ./fm-calm-ship-raster.ts owns the ship's palette and key,
// ./fm-calm-hawk-raster.ts the hawk's, and ../hooks/register.ts owns when a scene is drawn.
//
// Raster colors are RGB, and the terminal paints them through a quantized 256-color
// palette rather than the standard 16-color ANSI codes Pi's widget emits, which
// docs/calm-mode-feasibility.md records as a bounded gap.

/** Claude Code's Raster width limit, per RasterProps. */
export const CALM_RASTER_MAX_COLUMNS = 512;

/** The transcript's side margin the stock working row also sits inside. */
export const CALM_RASTER_MARGIN = 2;

/** The viewport width assumed before the surface has measured. */
export const CALM_RASTER_DEFAULT_VIEWPORT_COLUMNS = 80;

/** `0x01000000` (bit 24 alone) asks for the terminal's default color. */
export const CALM_RASTER_DEFAULT_COLOR = 0x01000000;

/** One same-colored run of cells inside a frame row, as every scene paints it. */
export type CalmRasterRun<Color extends string> = {
  readonly text: string;
  readonly color: Color;
};

/** One painted frame: rows of runs, each row at most the grid's width. */
export type CalmRasterFrame<Color extends string> = readonly (readonly CalmRasterRun<Color>[])[];

/** Foreground per color class, as `0x00RRGGBB`, or the terminal default. */
export type CalmRasterPalette<Color extends string> = Readonly<Record<Color, number>>;

/** How many Raster columns a Spinner site of `viewportColumns` gets: the row minus its margin, within the Raster's limits. */
export function calmRasterColumns(viewportColumns: number | undefined): number {
  const measured = viewportColumns ?? CALM_RASTER_DEFAULT_VIEWPORT_COLUMNS;
  return Math.max(1, Math.min(CALM_RASTER_MAX_COLUMNS, measured - CALM_RASTER_MARGIN));
}

const BASE64_ALPHABET =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/** Standard padded base64, written here because the hooks environment and Node differ on native helpers. */
export function encodeBase64(bytes: Uint8Array): string {
  let out = "";
  let index = 0;
  for (; index + 2 < bytes.length; index += 3) {
    const word = ((bytes[index] ?? 0) << 16) | ((bytes[index + 1] ?? 0) << 8) | (bytes[index + 2] ?? 0);
    out +=
      BASE64_ALPHABET[(word >> 18) & 63]! +
      BASE64_ALPHABET[(word >> 12) & 63]! +
      BASE64_ALPHABET[(word >> 6) & 63]! +
      BASE64_ALPHABET[word & 63]!;
  }
  const rest = bytes.length - index;
  if (rest === 1) {
    const word = (bytes[index] ?? 0) << 16;
    out += BASE64_ALPHABET[(word >> 18) & 63]! + BASE64_ALPHABET[(word >> 12) & 63]! + "==";
  } else if (rest === 2) {
    const word = ((bytes[index] ?? 0) << 16) | ((bytes[index + 1] ?? 0) << 8);
    out +=
      BASE64_ALPHABET[(word >> 18) & 63]! +
      BASE64_ALPHABET[(word >> 12) & 63]! +
      BASE64_ALPHABET[(word >> 6) & 63]! +
      "=";
  }
  return out;
}

export type CalmRasterCells = {
  /** How many rows the packed grid has: the frame's, one or two. */
  rows: number;
  /** The packed `cells` string for a Raster of `columns` by `rows`. */
  cells: string;
};

/**
 * Pack a frame painted for exactly `columns` cells. Every row is padded with plain
 * spaces to the full width, so a short run still fills its Raster row, and a row wider
 * than the grid is clipped rather than wrapped.
 */
export function packCalmRasterCells<Color extends string>(
  frame: CalmRasterFrame<Color>,
  columns: number,
  palette: CalmRasterPalette<Color>,
): CalmRasterCells {
  const rows = Math.max(1, frame.length);
  const words = new Uint32Array(columns * rows * 3);
  const put = (row: number, column: number, codePoint: number, foreground: number): void => {
    if (column < 0 || column >= columns) return;
    const offset = (row * columns + column) * 3;
    words[offset] = codePoint;
    words[offset + 1] = foreground;
    words[offset + 2] = CALM_RASTER_DEFAULT_COLOR;
  };
  for (let row = 0; row < rows; row += 1) {
    for (let column = 0; column < columns; column += 1) {
      put(row, column, 0x20, CALM_RASTER_DEFAULT_COLOR);
    }
    let column = 0;
    for (const run of frame[row] ?? []) {
      const foreground = palette[run.color];
      for (const glyph of Array.from(run.text)) {
        put(row, column, glyph.codePointAt(0) ?? 0x20, foreground);
        column += 1;
      }
    }
  }
  return { rows, cells: encodeBase64(new Uint8Array(words.buffer)) };
}
