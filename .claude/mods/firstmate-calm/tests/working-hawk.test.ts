// firstmate-calm under `claude plugin test`: the hawk scene that replaces the stock
// working row when the per-home config/calm-scene setting selects it, its wing cycle,
// bird and land cadences, edge reversal, and basic colors on the mocked clock, and the
// setting itself: absent, ship, hawk, or unrecognized, re-read when /calm turns on and
// at each session start.
import { describe, expect, test } from "claude-code/testing";
import { calmCommand, decodeCells, rasterOf, SCENE, spinner, themeChange, world } from "./support.ts";

const HAWK_KEY = "firstmate-calm-working-hawk";
const SHIP_KEY = "firstmate-calm-working-ship";
const UP = "╲v╱";
const GLIDE = "─v─";
const DOWN = "╱v╲";
// The captain's hand-drawn land strip, 52 columns, repeated across the row.
const STRIP = "↟↟▁↟╱╲▁↟↟↟▁▁╱╲╱╲▁↟▁▁↟↟↟▁╱╲▁▁↟▁↟↟▁▁╱╲▁↟↟▁▁▁↟▁╱╲╱╲▁↟↟▁";
const STRIP_CELLS = Array.from(STRIP);
const DEFAULT = 0x01000000;
// xterm's RGB for the standard ANSI yellow, blue, and green.
const YELLOW = 0xcdcd00;
const BLUE = 0x0000ee;
const GREEN = 0x00cd00;
const TICK = 220;
const TICKS_PER_MOVE = 4;
const TICKS_PER_LAND_MOVE = 8;
// Two flaps, one pose per tick, then a glide of about four seconds.
const FLAP = [UP, GLIDE, DOWN, GLIDE, UP, GLIDE, DOWN];
const GLIDE_TICKS = 18;
const CYCLE = FLAP.length + GLIDE_TICKS;

const sessionStart = { cwd: "/work", surface: "terminal" as const, isInteractive: true };

/** The wing pose the design shows after `ticks` ticks. */
function poseAt(ticks: number): string {
  const index = ticks % CYCLE;
  return FLAP[index] ?? GLIDE;
}

/** The land row of `columns` cells once the strip has scrolled `offset` columns leftward. */
function landAt(offset: number, columns: number): string {
  let row = "";
  for (let column = 0; column < columns; column += 1) {
    row += STRIP_CELLS[(((column + offset) % STRIP_CELLS.length) + STRIP_CELLS.length) % STRIP_CELLS.length]!;
  }
  return row;
}

/** The color the design gives one land glyph. */
function landColor(glyph: string): number {
  return glyph === "╱" || glyph === "╲" ? BLUE : GREEN;
}

describe("the working hawk", () => {
  test("replaces the spinner with the bird over the land when the scene setting is hawk", async ($, on) => {
    world(on, { preference: "on\n", scene: "hawk\n" });
    const raster = rasterOf(await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 })));
    expect(raster).toBeDefined();
    expect(raster!.key).toBe(HAWK_KEY);
    expect(raster!.columns).toBe(38);
    expect(raster!.rows).toBe(2);
    const { glyphs, foregrounds, backgrounds } = decodeCells(raster!.cells, 38, 2);
    // The bird starts at the left edge in the first flap pose; the land starts unscrolled.
    expect(glyphs[0]).toBe(UP + " ".repeat(35));
    expect(glyphs[1]).toBe(landAt(0, 38));
    // Colors: the whole bird yellow, every slope blue, every pine and meadow cell green,
    // default-colored padding, default backgrounds, whatever the theme.
    expect(foregrounds[0]!.slice(0, 3)).toEqual([YELLOW, YELLOW, YELLOW]);
    expect(foregrounds[0]!.slice(3).every((color) => color === DEFAULT)).toBe(true);
    expect(foregrounds[1]).toEqual(Array.from(glyphs[1]!).map(landColor));
    expect(foregrounds[1]).toContain(BLUE);
    expect(foregrounds[1]).toContain(GREEN);
    expect(backgrounds.flat().every((color) => color === DEFAULT)).toBe(true);
  });

  test("flaps twice then glides, moves the bird every fourth tick and the land every eighth, through blits of the mounted size", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n", scene: "hawk\n" });
    await $.session.start(sessionStart);
    await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 }));
    for (let tick = 1; tick <= CYCLE + 1; tick += 1) {
      await clock.advance(TICK);
      expect(journal.blits).toHaveLength(tick);
      const blit = journal.blits[tick - 1]!;
      expect(blit).toMatchObject({ requestId: "agent-main", key: HAWK_KEY, columns: 38, rows: 2 });
      const { glyphs } = decodeCells(blit.cells, 38, 2);
      const birdColumn = Math.floor(tick / TICKS_PER_MOVE);
      expect(glyphs[0]).toBe(" ".repeat(birdColumn) + poseAt(tick) + " ".repeat(35 - birdColumn));
      expect(glyphs[1]).toBe(landAt(Math.floor(tick / TICKS_PER_LAND_MOVE), 38));
    }
    // The glide held the flat pose for about four seconds before the cycle repeated.
    const poses = journal.blits.map((blit) => decodeCells(blit.cells, 38, 2).glyphs[0]!.trim());
    expect(poses.slice(FLAP.length - 1, CYCLE - 1).every((pose) => pose === GLIDE)).toBe(true);
    expect(GLIDE_TICKS * TICK).toBeGreaterThanOrEqual(3900);
    expect(poses[CYCLE - 1]).toBe(UP);
  });

  test("reverses the land's scroll the moment the bird turns at an edge", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n", scene: "hawk\n" });
    await $.session.start(sessionStart);
    // Five columns leave the bird a two-column track: right edge after two moves.
    await $.ui.render(spinner("agent-main", { columns: 7, rows: 24 }));
    const rowsAt = (tick: number) => decodeCells(journal.blits[tick - 1]!.cells, 5, 2).glyphs;
    await clock.advance(TICK * 8);
    expect(rowsAt(4)[0]).toBe(` ${poseAt(4)} `);
    // Tick 8: the bird reaches the right edge and turns, so the land steps rightward (offset -1).
    expect(rowsAt(8)[0]).toBe(`  ${poseAt(8)}`);
    expect(rowsAt(8)[1]).toBe(landAt(-1, 5));
    await clock.advance(TICK * 8);
    expect(rowsAt(12)[0]).toBe(` ${poseAt(12)} `);
    // Tick 16: back at the left edge, turning right again, so the land steps leftward (offset 0).
    expect(rowsAt(16)[0]).toBe(`${poseAt(16)}  `);
    expect(rowsAt(16)[1]).toBe(landAt(0, 5));
    await clock.advance(TICK * 8);
    expect(rowsAt(24)[0]).toBe(`  ${poseAt(24)}`);
    expect(rowsAt(24)[1]).toBe(landAt(-1, 5));
  });

  test("falls back to the land alone when the row cannot hold the bird", async ($, on) => {
    world(on, { preference: "on\n", scene: "hawk\n" });
    const tiny = rasterOf(await $.ui.render(spinner("a", { columns: 4, rows: 24 })))!;
    expect(tiny.columns).toBe(2);
    expect(tiny.rows).toBe(1);
    expect(decodeCells(tiny.cells, 2, 1).glyphs[0]).toBe(landAt(0, 2));
    const exact = rasterOf(await $.ui.render(spinner("b", { columns: 5, rows: 24 })))!;
    expect(exact.columns).toBe(3);
    expect(exact.rows).toBe(2);
    expect(decodeCells(exact.cells, 3, 2).glyphs[0]).toBe(UP);
  });

  test("keeps its basic colors through a theme change, without a redraw", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n", scene: "hawk\n", theme: "dark" });
    await $.session.start(sessionStart);
    await $.ui.render(spinner("agent-main", { columns: 40, rows: 24 }));
    const redrawsBefore = journal.invalidations.length;
    await $.config.set(themeChange("light", "dark"));
    expect(journal.invalidations.length).toBe(redrawsBefore);
    await clock.advance(TICK);
    const { foregrounds } = decodeCells(journal.blits.at(-1)!.cells, 38, 2);
    expect(foregrounds[0]!.slice(0, 3)).toEqual([YELLOW, YELLOW, YELLOW]);
    expect(foregrounds[1]).toContain(BLUE);
    expect(foregrounds[1]).toContain(GREEN);
  });
});

describe("the scene setting", () => {
  test("draws the sailboat when the setting is absent", async ($, on) => {
    world(on, { preference: "on\n" });
    expect(rasterOf(await $.ui.render(spinner()))!.key).toBe(SHIP_KEY);
  });

  for (const [stored, expected] of [
    ["ship\n", SHIP_KEY],
    ["hawk\n", HAWK_KEY],
    ["  hawk  \n", HAWK_KEY],
    ["HAWK\n", SHIP_KEY],
    ["eagle\n", SHIP_KEY],
    ["", SHIP_KEY],
  ] as const) {
    test(`draws ${expected === HAWK_KEY ? "the hawk" : "the sailboat"} for the stored value ${JSON.stringify(stored)}`, async ($, on) => {
      world(on, { preference: "on\n", scene: stored });
      expect(rasterOf(await $.ui.render(spinner()))!.key).toBe(expected);
    });
  }

  test("re-reads an edited setting when /calm turns Calm on, so the new scene shows without a restart", async ($, on) => {
    const { files, journal } = world(on, { preference: "on\n" });
    await $.session.start(sessionStart);
    expect(rasterOf(await $.ui.render(spinner()))!.key).toBe(SHIP_KEY);
    await $.command.run(calmCommand());
    files.set(SCENE, "hawk\n");
    await $.command.run(calmCommand());
    expect(journal.toasts).toEqual(["Calm off", "Calm on"]);
    expect(rasterOf(await $.ui.render(spinner()))!.key).toBe(HAWK_KEY);
    await $.command.run(calmCommand());
    files.set(SCENE, "ship\n");
    await $.command.run(calmCommand());
    expect(rasterOf(await $.ui.render(spinner()))!.key).toBe(SHIP_KEY);
  });

  test("re-reads the setting at each session start", async ($, on) => {
    const { files } = world(on, { preference: "on\n" });
    await $.session.start(sessionStart);
    expect(rasterOf(await $.ui.render(spinner()))!.key).toBe(SHIP_KEY);
    files.set(SCENE, "hawk\n");
    await $.session.start(sessionStart);
    expect(rasterOf(await $.ui.render(spinner()))!.key).toBe(HAWK_KEY);
  });

  test("leaves the scene alone while Calm is off: the stock row draws whatever the setting says", async ($, on) => {
    const { clock, journal } = world(on, { scene: "hawk\n" });
    await $.session.start(sessionStart);
    expect(rasterOf(await $.ui.render(spinner()))).toBeUndefined();
    await clock.advance(TICK * 4);
    expect(journal.blits).toHaveLength(0);
  });
});
