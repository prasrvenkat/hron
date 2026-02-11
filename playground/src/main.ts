import { Schedule } from "hron-wasm";

const textarea = document.getElementById("expression") as HTMLTextAreaElement;
const errorEl = document.getElementById("error") as HTMLDivElement;
const resultsEmpty = document.getElementById("results-empty") as HTMLDivElement;
const resultsEl = document.getElementById("results") as HTMLDivElement;
const occurrencesEl = document.getElementById("occurrences") as HTMLOListElement;
const cronEl = document.getElementById("cron") as HTMLDivElement;
const themeToggle = document.getElementById("theme-toggle") as HTMLButtonElement;

// ── Version ──

declare const __HRON_VERSION__: string;
document.getElementById("version")!.textContent = `v${__HRON_VERSION__}`;

// ── Theme ──

function getSystemTheme(): "light" | "dark" {
  return window.matchMedia("(prefers-color-scheme: dark)").matches
    ? "dark"
    : "light";
}

function applyTheme(theme: "light" | "dark") {
  document.documentElement.setAttribute("data-theme", theme);
  localStorage.setItem("hron-theme", theme);
}

const stored = localStorage.getItem("hron-theme");
if (stored === "light" || stored === "dark") {
  applyTheme(stored);
}

themeToggle.addEventListener("click", () => {
  const current =
    document.documentElement.getAttribute("data-theme") ?? getSystemTheme();
  applyTheme(current === "dark" ? "light" : "dark");
});

// ── Helpers ──

function nowZoned(): string {
  const now = new Date();
  const tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const pad = (n: number) => String(n).padStart(2, "0");
  const offset = -now.getTimezoneOffset();
  const sign = offset >= 0 ? "+" : "-";
  const abs = Math.abs(offset);
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}T${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}${sign}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}[${tz}]`;
}

// ── Evaluation ──

const BATCH = 5;
const MAX_OCCURRENCES = 100;
let currentSchedule: Schedule | null = null;
let shownCount = 0;

function evaluate(input: string) {
  const trimmed = input.trim();
  if (!trimmed) {
    errorEl.hidden = true;
    resultsEl.hidden = true;
    resultsEmpty.hidden = false;
    currentSchedule = null;
    return;
  }

  try {
    currentSchedule = Schedule.parse(trimmed);
  } catch (e: unknown) {
    resultsEl.hidden = true;
    resultsEmpty.hidden = true;
    errorEl.textContent = e instanceof Error ? e.message : String(e);
    errorEl.hidden = false;
    currentSchedule = null;
    return;
  }

  errorEl.hidden = true;
  resultsEmpty.hidden = true;
  resultsEl.hidden = false;

  // Next occurrences
  shownCount = 0;
  occurrencesEl.innerHTML = "";
  showMore();

  // Cron equivalent
  try {
    const cron = currentSchedule.toCron();
    cronEl.innerHTML = `<span class="cron-value">${escapeHtml(cron)}</span>`;
  } catch {
    cronEl.innerHTML = `<span class="cron-unavailable">Not expressible as cron</span>`;
  }
}

function showMore() {
  if (!currentSchedule) return;

  const now = nowZoned();
  const total = shownCount + BATCH;

  try {
    const all = currentSchedule.nextNFrom(now, total) as string[];
    const newItems = all.slice(shownCount);

    if (shownCount === 0 && all.length === 0) {
      const li = document.createElement("li");
      li.textContent = "No upcoming occurrences";
      li.style.color = "var(--text-dim)";
      li.style.fontStyle = "italic";
      occurrencesEl.appendChild(li);
      return;
    }

    // Remove existing "show more" button
    const existing = occurrencesEl.querySelector(".show-more");
    if (existing) existing.remove();

    for (const dt of newItems) {
      const li = document.createElement("li");
      li.textContent = dt;
      occurrencesEl.appendChild(li);
    }
    shownCount = all.length;

    // Add "show more" if we got a full batch and haven't hit the cap
    if (newItems.length === BATCH && shownCount < MAX_OCCURRENCES) {
      const li = document.createElement("li");
      li.className = "show-more";
      const btn = document.createElement("button");
      btn.type = "button";
      btn.textContent = `Show ${BATCH} more`;
      btn.addEventListener("click", showMore);
      li.appendChild(btn);
      occurrencesEl.appendChild(li);
    }
  } catch (e: unknown) {
    occurrencesEl.innerHTML = "";
    const li = document.createElement("li");
    const msg = e instanceof Error ? e.message : String(e);
    li.textContent = msg;
    li.style.color = "var(--error-text)";
    occurrencesEl.appendChild(li);
  }
}

function escapeHtml(s: string): string {
  const div = document.createElement("div");
  div.textContent = s;
  return div.innerHTML;
}

// ── Debounced input ──

let timer: ReturnType<typeof setTimeout>;
textarea.addEventListener("input", () => {
  clearTimeout(timer);
  timer = setTimeout(() => evaluate(textarea.value), 150);
});

// ── Example chips ──

document.querySelectorAll<HTMLButtonElement>(".chip[data-expr]").forEach((btn) => {
  btn.addEventListener("click", () => {
    textarea.value = btn.dataset.expr!;
    evaluate(textarea.value);
    textarea.focus();
  });
});

// ── Initial focus ──
textarea.focus();
