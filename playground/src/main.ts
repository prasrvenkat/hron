import { Schedule } from "hron-wasm";

const textarea = document.getElementById("expression") as HTMLTextAreaElement;
const errorEl = document.getElementById("error") as HTMLDivElement;
const emptyEl = document.getElementById("empty") as HTMLDivElement;
const resultsEl = document.getElementById("results") as HTMLDivElement;
const occEl = document.getElementById("occurrences") as HTMLOListElement;
const cronEl = document.getElementById("cron") as HTMLDivElement;
const copyCron = document.getElementById("copy-cron") as HTMLButtonElement;
const tzNameEl = document.getElementById("tz-name") as HTMLElement;
const themeToggle = document.getElementById("theme-toggle") as HTMLButtonElement | null;

// ── Version (optional — landing carries the version pill) ──

declare const __HRON_VERSION__: string;
const versionEl = document.getElementById("version");
if (versionEl) versionEl.textContent = `v${__HRON_VERSION__}`;

// ── Theme ──

function getSystemTheme(): "light" | "dark" {
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function applyTheme(theme: "light" | "dark") {
  document.documentElement.setAttribute("data-theme", theme);
  localStorage.setItem("hron-theme", theme);
}

const storedTheme = localStorage.getItem("hron-theme");
if (storedTheme === "light" || storedTheme === "dark") applyTheme(storedTheme);

themeToggle?.addEventListener("click", () => {
  const current = document.documentElement.getAttribute("data-theme") ?? getSystemTheme();
  applyTheme(current === "dark" ? "light" : "dark");
});

// ── Constants & helpers ──

const WD = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MO = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const BATCH = 6;
const MAX_OCCURRENCES = 120;

/** A zoned timestamp in the viewer's local zone, the anchor for "next" queries. */
function nowZoned(): string {
  const now = new Date();
  const tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const pad = (n: number) => String(n).padStart(2, "0");
  const offset = -now.getTimezoneOffset();
  const sign = offset >= 0 ? "+" : "-";
  const abs = Math.abs(offset);
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}T${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}${sign}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}[${tz}]`;
}

/** Pull the IANA zone out of a zoned ISO string like `...+00:00[UTC]`. */
function tzFromIso(iso: string): string | null {
  const m = iso.match(/\[([^\]]+)\]\s*$/);
  return m ? m[1] : null;
}

/** Human "in 3 days" using the true instant (offset-aware), vs the wall-clock shown. */
function relativeTime(iso: string): string {
  const instant = new Date(iso.replace(/\[[^\]]*\]\s*$/, "")).getTime();
  if (Number.isNaN(instant)) return "";
  const mins = Math.round((instant - Date.now()) / 60000);
  if (mins <= 0) return "now";
  if (mins < 60) return `in ${mins} min`;
  const hrs = Math.round(mins / 60);
  if (hrs < 24) return `in ${hrs} ${hrs === 1 ? "hour" : "hours"}`;
  const days = Math.round(hrs / 24);
  if (days < 14) return `in ${days} ${days === 1 ? "day" : "days"}`;
  if (days < 60) return `in ${Math.round(days / 7)} weeks`;
  const months = Math.round(days / 30);
  if (months < 18) return `in ${months} months`;
  return `in ${Math.round(days / 365)} years`;
}

/** Auto-grow the single-line-feeling textarea to fit its content. */
function grow() {
  textarea.style.height = "auto";
  textarea.style.height = `${textarea.scrollHeight}px`;
}

// ── Rendering ──

function renderOccurrence(iso: string, isFirst: boolean): HTMLLIElement {
  const li = document.createElement("li");
  const m = iso.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/);
  if (!m) {
    li.textContent = iso;
    return li;
  }
  const year = Number(m[1]);
  const month = Number(m[2]);
  const day = Number(m[3]);
  const hh = m[4];
  const mi = m[5];
  // Day-of-week of a given calendar date is timezone-independent.
  const weekday = new Date(year, month - 1, day).getDay();

  li.className = isFirst ? "occ first" : "occ";

  const badge = document.createElement("div");
  badge.className = "occ-wd";
  const badgeDay = document.createElement("span");
  badgeDay.className = "d";
  badgeDay.textContent = String(day);
  const badgeWd = document.createElement("span");
  badgeWd.className = "w";
  badgeWd.textContent = WD[weekday];
  badge.append(badgeDay, badgeWd);

  const main = document.createElement("div");
  main.className = "occ-main";
  const date = document.createElement("div");
  date.className = "occ-date";
  date.textContent = `${WD[weekday]}, ${MO[month - 1]} ${day} ${year} · ${hh}:${mi}`;
  const isoLine = document.createElement("div");
  isoLine.className = "occ-iso";
  isoLine.textContent = iso;
  main.append(date, isoLine);

  const rel = document.createElement("div");
  rel.className = "occ-rel";
  rel.textContent = relativeTime(iso);

  li.append(badge, main, rel);
  return li;
}

function infoRow(text: string, color: string): HTMLLIElement {
  const li = document.createElement("li");
  li.className = "occ";
  const main = document.createElement("div");
  main.className = "occ-main";
  const date = document.createElement("div");
  date.className = "occ-date";
  date.style.color = color;
  date.textContent = text;
  main.append(date);
  li.append(main);
  return li;
}

function renderCron(cron: string | null) {
  copyCron.hidden = !cron;
  cronEl.replaceChildren();

  if (!cron) {
    lastCron = "";
    const wrap = document.createElement("div");
    wrap.className = "cron-unavailable";
    wrap.append(
      document.createTextNode("Not expressible as cron."),
    );
    const why = document.createElement("span");
    why.className = "why";
    why.append(
      document.createTextNode(
        "This schedule uses something the five-field syntax can't represent — an ordinal weekday, a multi-week interval, a yearly date, or a modifier like ",
      ),
    );
    const exceptCode = document.createElement("code");
    exceptCode.textContent = "except";
    const untilCode = document.createElement("code");
    untilCode.textContent = "until";
    why.append(exceptCode, document.createTextNode(" / "), untilCode, document.createTextNode("."));
    wrap.append(why);
    cronEl.append(wrap);
    return;
  }

  lastCron = cron;
  const value = document.createElement("span");
  value.className = "cron-value";
  value.textContent = cron;
  cronEl.append(value);

  const fields = cron.trim().split(/\s+/);
  const keys = ["min", "hour", "day", "month", "wday"];
  if (fields.length === 5) {
    const grid = document.createElement("div");
    grid.className = "cron-fields";
    fields.forEach((field, idx) => {
      const cell = document.createElement("div");
      cell.className = "cron-field";
      const v = document.createElement("div");
      v.className = "v";
      v.textContent = field;
      const k = document.createElement("div");
      k.className = "k";
      k.textContent = keys[idx];
      cell.append(v, k);
      grid.append(cell);
    });
    cronEl.append(grid);
  }
}

// ── Evaluation ──

let currentSchedule: Schedule | null = null;
let currentNow = "";
let shownCount = 0;
let lastCron = "";

function evaluate(input: string) {
  const trimmed = input.trim();
  if (!trimmed) {
    errorEl.hidden = true;
    resultsEl.hidden = true;
    emptyEl.hidden = false;
    currentSchedule = null;
    return;
  }

  try {
    currentSchedule = Schedule.parse(trimmed);
  } catch (e: unknown) {
    resultsEl.hidden = true;
    emptyEl.hidden = true;
    errorEl.textContent = e instanceof Error ? e.message : String(e);
    errorEl.hidden = false;
    currentSchedule = null;
    return;
  }

  errorEl.hidden = true;
  emptyEl.hidden = true;
  resultsEl.hidden = false;
  currentNow = nowZoned();
  tzNameEl.textContent = "UTC";

  // Cron equivalent
  try {
    renderCron(currentSchedule.toCron());
  } catch {
    renderCron(null);
  }

  // Next occurrences
  shownCount = 0;
  occEl.replaceChildren();
  showMore();
}

function showMore() {
  if (!currentSchedule) return;

  const existing = occEl.querySelector(".show-more-row");
  if (existing) existing.remove();

  let all: string[];
  try {
    all = currentSchedule.nextNFrom(currentNow, shownCount + BATCH) as string[];
  } catch (e: unknown) {
    occEl.replaceChildren();
    occEl.append(infoRow(e instanceof Error ? e.message : String(e), "var(--accent-ink)"));
    return;
  }

  if (shownCount === 0 && all.length === 0) {
    occEl.append(infoRow("No upcoming occurrences", "var(--muted)"));
    return;
  }

  const fresh = all.slice(shownCount);
  fresh.forEach((iso, idx) => {
    const isFirst = shownCount === 0 && idx === 0;
    if (isFirst) tzNameEl.textContent = tzFromIso(iso) ?? "UTC";
    occEl.append(renderOccurrence(iso, isFirst));
  });
  shownCount = all.length;

  if (fresh.length === BATCH && shownCount < MAX_OCCURRENCES) {
    const row = document.createElement("li");
    row.className = "show-more-row";
    const btn = document.createElement("button");
    btn.type = "button";
    btn.textContent = `Show ${BATCH} more`;
    btn.addEventListener("click", showMore);
    row.append(btn);
    occEl.append(row);
  }
}

// ── Copy cron ──

copyCron.addEventListener("click", () => {
  if (!lastCron || !navigator.clipboard) return;
  const label = copyCron.querySelector("span");
  void navigator.clipboard.writeText(lastCron).then(() => {
    if (!label) return;
    const prev = label.textContent;
    label.textContent = "Copied";
    window.setTimeout(() => {
      label.textContent = prev;
    }, 1300);
  });
});

// ── Input wiring ──

let timer: ReturnType<typeof setTimeout>;
textarea.addEventListener("input", () => {
  grow();
  clearTimeout(timer);
  timer = setTimeout(() => evaluate(textarea.value), 140);
});

document.querySelectorAll<HTMLButtonElement>(".chip[data-expr]").forEach((btn) => {
  btn.addEventListener("click", () => {
    textarea.value = btn.dataset.expr ?? "";
    grow();
    evaluate(textarea.value);
    textarea.focus();
  });
});

// Hint the placeholder with the viewer's own zone (results stay UTC unless specified).
try {
  const localTz = Intl.DateTimeFormat().resolvedOptions().timeZone;
  if (localTz) textarea.placeholder = `every weekday at 9:00 in ${localTz}`;
} catch {
  /* keep default placeholder */
}

// Seed a default so the page feels alive on first load.
textarea.value = "every weekday at 9:00";
grow();
evaluate(textarea.value);
textarea.focus();
