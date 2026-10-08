// grill-design picker: a draggable dock that switches the designs of one round.
//
// Inline this file into the round's HTML, after the round's JSON block: a
// script element of type application/json with id grill-round, holding
// { question, designs: [{ id, name, angle, cost }], states: [{ id, name }] }.
// This file never spells out a closing script tag, because the HTML parser
// would end the inline script at it.
//
// The live choice is written to data-design and data-state on the html
// element, so each design styles itself under [data-design="<id>"]. Elements marked
// data-for-design="<id> <id>" or data-for-state="<id>" are hidden unless the
// live choice is listed. Every switch dispatches a "grill:change" event on
// document with { design, state, replay } in detail.
//
// Ideas borrowed from the variate card (github.com/Nutlope/variate, MIT).

(() => {
  "use strict";

  const source = document.getElementById("grill-round");
  if (!source) {
    console.error("grill-design picker: no application/json script with id grill-round");
    return;
  }
  let round;
  try {
    round = JSON.parse(source.textContent);
  } catch (error) {
    console.error("grill-design picker: grill-round is not valid JSON", error);
    return;
  }
  const designs = Array.isArray(round.designs) ? round.designs : [];
  const states = Array.isArray(round.states) ? round.states : [];
  if (!designs.length) {
    console.error("grill-design picker: grill-round has no designs");
    return;
  }

  const root = document.documentElement;
  const POSITION_KEY = "grill-design:dock-position";

  // localStorage throws in private windows and sandboxed previews; the dock
  // must still work there, it only forgets where it was dragged.
  const storage = {
    get(key) { try { return JSON.parse(localStorage.getItem(key)); } catch (_) { return null; } },
    set(key, value) { try { localStorage.setItem(key, JSON.stringify(value)); } catch (_) {} },
  };

  const fromHash = () => {
    const params = new URLSearchParams(location.hash.slice(1));
    return { design: params.get("design"), state: params.get("state") };
  };
  const known = (list, id) => list.some((item) => item.id === id);

  const initial = fromHash();
  let design = known(designs, initial.design) ? initial.design : designs[0].id;
  let state = states.length ? (known(states, initial.state) ? initial.state : states[0].id) : null;

  function applyChoice(replay) {
    root.dataset.design = design;
    if (state) root.dataset.state = state; else delete root.dataset.state;
    for (const node of document.querySelectorAll("[data-for-design]")) {
      node.hidden = !node.dataset.forDesign.split(/\s+/).includes(design);
    }
    for (const node of document.querySelectorAll("[data-for-state]")) {
      node.hidden = !node.dataset.forState.split(/\s+/).includes(state);
    }
    const hash = new URLSearchParams({ design, ...(state ? { state } : {}) });
    history.replaceState(null, "", `#${hash}`);
    document.dispatchEvent(new CustomEvent("grill:change", { detail: { design, state, replay } }));
    render();
  }

  // Re-entering the same design restarts its CSS animations, so a round about
  // motion can be watched more than once.
  function replay() {
    delete root.dataset.design;
    void root.offsetWidth;
    applyChoice(true);
  }

  function selectDesign(id) {
    if (id === design) { replay(); return; }
    design = id;
    applyChoice(false);
  }

  function step(delta) {
    const index = designs.findIndex((item) => item.id === design);
    selectDesign(designs[(index + delta + designs.length) % designs.length].id);
  }

  // The dock lives in a shadow root reset with all: initial, so the designs
  // under review cannot restyle it and it cannot leak into them.
  const host = document.createElement("grill-picker");
  const shadow = host.attachShadow({ mode: "open" });
  shadow.innerHTML = `
<style>
:host { all: initial; display: block; position: fixed; right: 16px; bottom: 16px; z-index: 2147483646; }
@media print { :host { display: none } }
* { box-sizing: border-box; margin: 0; }
.dock {
  width: min(320px, calc(100vw - 32px));
  padding: 10px 12px 12px;
  border-radius: 12px;
  background: #16181d;
  color: #e8e9ed;
  box-shadow: 0 8px 28px rgb(0 0 0 / .35), 0 0 0 1px rgb(255 255 255 / .08);
  font: 13px/1.4 system-ui, -apple-system, "Segoe UI", sans-serif;
  color-scheme: dark;
}
.grip {
  display: flex; align-items: center; gap: 8px;
  cursor: grab; touch-action: none; user-select: none;
  color: #9a9ea8; font-size: 12px;
}
.grip:active { cursor: grabbing; }
.grip::before { content: "⋮⋮"; letter-spacing: -2px; }
.question { color: #e8e9ed; font-weight: 600; }
.pager { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 8px; }
button {
  all: unset; box-sizing: border-box;
  min-width: 28px; height: 28px; padding: 0 8px;
  display: inline-flex; align-items: center; justify-content: center;
  border-radius: 7px; background: #23262d; color: #c9ccd3;
  font: inherit; cursor: pointer; white-space: nowrap;
}
button:hover { background: #2d3139; }
button:focus-visible { outline: 2px solid #7aa2ff; outline-offset: 1px; }
button[aria-pressed="true"] { background: #e8e9ed; color: #16181d; font-weight: 600; }
.detail { margin-top: 8px; color: #b4b8c1; }
.detail b { color: #e8e9ed; font-weight: 600; }
.cost { color: #f0b37e; }
.states { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 10px; padding-top: 10px; border-top: 1px solid #2d3139; }
.keys { margin-top: 8px; color: #6f7480; font-size: 11px; }
</style>
<div class="dock" role="region" aria-label="Design picker">
  <div class="grip"><span class="question"></span></div>
  <div class="pager" role="group" aria-label="Designs"></div>
  <p class="detail" aria-live="polite"></p>
  <div class="states" role="group" aria-label="States"></div>
  <p class="keys">← → or 1–9 switch · click the current design to replay it</p>
</div>`;

  const dock = shadow.querySelector(".dock");
  const grip = shadow.querySelector(".grip");
  const pager = shadow.querySelector(".pager");
  const detail = shadow.querySelector(".detail");
  const stateBar = shadow.querySelector(".states");
  shadow.querySelector(".question").textContent = round.question || "Pick a design";
  if (!states.length) stateBar.remove();

  const designButtons = designs.map((item, index) => {
    const button = document.createElement("button");
    button.type = "button";
    button.addEventListener("click", () => selectDesign(item.id));
    button.dataset.number = String(index + 1);
    pager.append(button);
    return button;
  });
  const stateButtons = states.map((item) => {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = item.name || item.id;
    button.addEventListener("click", () => { state = item.id; applyChoice(false); });
    stateBar.append(button);
    return button;
  });

  function render() {
    designs.forEach((item, index) => {
      const live = item.id === design;
      const button = designButtons[index];
      // The live chip wears its name and the rest stay numbers, so the dock
      // stays narrow while always saying what is on screen.
      button.textContent = live ? `${index + 1} · ${item.name || item.id}` : String(index + 1);
      button.setAttribute("aria-pressed", String(live));
      button.title = [item.name, item.angle, item.cost && `cost: ${item.cost}`].filter(Boolean).join(" — ");
    });
    stateButtons.forEach((button, index) => {
      button.setAttribute("aria-pressed", String(states[index].id === state));
    });
    const current = designs.find((item) => item.id === design);
    detail.replaceChildren();
    if (current.angle) {
      const angle = document.createElement("b");
      angle.textContent = current.angle;
      detail.append(angle);
    }
    if (current.cost) {
      const cost = document.createElement("span");
      cost.className = "cost";
      cost.textContent = `${current.angle ? " · " : ""}cost: ${current.cost}`;
      detail.append(cost);
    }
    detail.hidden = !current.angle && !current.cost;
  }

  function onKey(event) {
    if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return;
    const target = event.composedPath()[0];
    if (target instanceof HTMLElement && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName))) return;
    if (event.key === "ArrowRight") { step(1); event.preventDefault(); return; }
    if (event.key === "ArrowLeft") { step(-1); event.preventDefault(); return; }
    const number = Number(event.key);
    if (Number.isInteger(number) && number >= 1 && number <= designs.length) {
      selectDesign(designs[number - 1].id);
      event.preventDefault();
    }
  }

  function place(position) {
    if (!position) return;
    const maxX = Math.max(0, innerWidth - dock.offsetWidth);
    const maxY = Math.max(0, innerHeight - dock.offsetHeight);
    host.style.left = `${Math.min(Math.max(0, position.x), maxX)}px`;
    host.style.top = `${Math.min(Math.max(0, position.y), maxY)}px`;
    host.style.right = "auto";
    host.style.bottom = "auto";
  }

  grip.addEventListener("pointerdown", (event) => {
    if (event.button !== 0) return;
    const box = host.getBoundingClientRect();
    const offsetX = event.clientX - box.left;
    const offsetY = event.clientY - box.top;
    grip.setPointerCapture(event.pointerId);
    const move = (moveEvent) => place({ x: moveEvent.clientX - offsetX, y: moveEvent.clientY - offsetY });
    const end = () => {
      grip.removeEventListener("pointermove", move);
      grip.removeEventListener("pointerup", end);
      grip.removeEventListener("pointercancel", end);
      const placed = host.getBoundingClientRect();
      storage.set(POSITION_KEY, { x: placed.left, y: placed.top });
    };
    grip.addEventListener("pointermove", move);
    grip.addEventListener("pointerup", end);
    grip.addEventListener("pointercancel", end);
  });

  addEventListener("keydown", onKey);
  addEventListener("hashchange", () => {
    const next = fromHash();
    if (known(designs, next.design)) design = next.design;
    if (known(states, next.state)) state = next.state;
    applyChoice(false);
  });
  addEventListener("resize", () => { if (host.style.left) place({ x: parseFloat(host.style.left), y: parseFloat(host.style.top) }); });

  document.body.append(host);
  place(storage.get(POSITION_KEY));
  applyChoice(false);
})();
