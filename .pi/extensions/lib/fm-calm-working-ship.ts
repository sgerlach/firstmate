// Firstmate's Calm-only animated working presentation for Pi.
//
// Calm replaces Pi's stock working row with an animated working scene while one logical
// agent run is active: a tiny SSHHIP-derived boat by default, or the hawk that
// ./fm-calm-working-hawk.ts paints. The sprite geometry, bounce track, two animation
// cadences, palette classes, and freeze/resume state are owned by the harness-neutral
// ./fm-calm-working-ship-sprite.ts (a tracked symlink into the Claude Code Calm mod,
// which both harnesses share); this module owns only Pi's rendering of those frames
// as standard ANSI escapes and the temporary TUI widget every scene draws through.
// `.pi/extensions/fm-calm.ts` owns which scene is drawn and when the presentation is
// installed and removed, and stays the sole caller of setWorkingVisible().
// docs/calm.md owns the captain-facing contract.
//
// Continuity: one extension-owned animation instance survives hide/show within the same
// Pi process and Calm extension lifetime. Disposing the widget freezes column,
// direction, water phase, and tick cadence without advancing them for hidden wall
// time. The next working period resumes from that exact logical state. A fresh session
// or new extension lifetime calls reset() and starts at the normal initial position.
// State is never a module-level or process-global singleton.
//
// Verified against Pi 0.81.1 declarations and the Pi 0.82.0 CLI, which expose
// ExtensionUIContext.setWidget() with a component factory, per-widget dispose(), and
// TUI.requestRender(). Pi renders a widget through Component.render(width), so this
// module recomputes its track from that width on every frame instead of caching a
// terminal size that a resize would invalidate. A resize while the boat is hidden is
// applied on the first resumed frame through the same clamp path.
import type { Component, TUI } from "@earendil-works/pi-tui";
import {
  CALM_WORKING_SHIP_TICK_MS,
  CALM_WORKING_SHIP_TICKS_PER_MOVE,
  createCalmWorkingShipSprite,
  type CalmWorkingShipColor,
  type CalmWorkingShipSprite,
} from "./fm-calm-working-ship-sprite.ts";

export { CALM_WORKING_SHIP_TICK_MS, CALM_WORKING_SHIP_TICKS_PER_MOVE };

/** Restores the default foreground so color never bleeds into padding or later frames. */
const RESET = "\u001b[39m";

/** A standard ANSI foreground escape for each color class of one scene; `plain` stays uncolored. */
export type CalmWorkingAnsiPalette<Color extends string> = Readonly<
  Record<Exclude<Color, "plain">, string>
>;

// Standard ANSI foreground codes only: no theme lookup, bright variant, or 256/RGB.
// Water is a single blue so the swell reads through glyph height alone; the boat is a
// single yellow so its sail halves, mast, and hull never split into mismatched colors.
const SHIP_ANSI_FOREGROUND: CalmWorkingAnsiPalette<CalmWorkingShipColor> = {
  water: "\u001b[34m",
  boat: "\u001b[33m",
};

// The working-row widget slot is deliberately shared with the standalone Pi Calm
// extension, which installs its boat under the same "calm-working-ship" key. Pi
// replaces widgets under one key, so a session that loads both Calms renders a
// single working scene and a session loading either alone is unchanged. Every Firstmate
// scene uses this one slot. Rename the slot in both implementations together, or
// dual-install sessions duplicate the working row.
export const CALM_WORKING_SHIP_WIDGET_KEY = "calm-working-ship";

/** What the working widget drives: any scene's state, painted for Pi. */
export type CalmWorkingSceneAnimation = {
  /** Advance one scheduler tick. */
  tick(): void;
  /** Return to the state of the last painted frame, discarding later ticks. */
  restoreLastRendered(): void;
  /** Render one frame that exactly fits `width`, clamping the track to it first. */
  render(width: number): string[];
};

export type CalmWorkingShipAnimation = Omit<CalmWorkingShipSprite, "frame"> & CalmWorkingSceneAnimation;

/** One frame's rows of color-tagged runs painted as standard ANSI, each run closed with a default-foreground reset. */
export function paintCalmWorkingFrame<Color extends string>(
  frame: readonly (readonly { readonly text: string; readonly color: Color }[])[],
  palette: CalmWorkingAnsiPalette<Color>,
): string[] {
  return frame.map((row) =>
    row
      .map((run) =>
        run.color === "plain"
          ? run.text
          : `${palette[run.color as Exclude<Color, "plain">]}${run.text}${RESET}`,
      )
      .join(""),
  );
}

export function createCalmWorkingShipAnimation(): CalmWorkingShipAnimation {
  const sprite = createCalmWorkingShipSprite();
  return {
    position: sprite.position,
    direction: sprite.direction,
    waterPhase: sprite.waterPhase,
    restoreLastRendered: sprite.restoreLastRendered,
    reset: sprite.reset,
    clampToWidth: sprite.clampToWidth,
    tick: sprite.tick,
    render(width: number): string[] {
      return paintCalmWorkingFrame(sprite.frame(width), SHIP_ANSI_FOREGROUND);
    },
  };
}

/**
 * Build the temporary Calm working widget bound to one caller-owned scene animation.
 * Every scene ticks on the one Calm tick the ship's sprite core defines. Pi disposes
 * the previous component before installing a replacement under the same key and when
 * it clears extension widgets, so the single scheduler driving the scene's cadences
 * cannot outlive the widget or duplicate. Disposing freezes the shared animation in
 * place; the next widget bound to the same animation resumes without applying hidden
 * wall time.
 */
export function createCalmWorkingWidget(
  tui: TUI,
  animation: CalmWorkingSceneAnimation = createCalmWorkingShipAnimation(),
): Component & { dispose(): void } {
  let disposed = false;
  const timer = setInterval(() => {
    if (disposed) return;
    animation.tick();
    tui.requestRender();
  }, CALM_WORKING_SHIP_TICK_MS);
  // The animation must never keep Pi's process alive on its own.
  timer.unref?.();

  return {
    render: (width) => (disposed ? [] : animation.render(width)),
    // Every frame is rebuilt from fixed standard ANSI codes, so there is no cache.
    invalidate: () => {},
    dispose: () => {
      if (disposed) return;
      disposed = true;
      clearInterval(timer);
      animation.restoreLastRendered();
    },
  };
}
