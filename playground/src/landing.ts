// ── Version ──

declare const __HRON_VERSION__: string;
const versionEl = document.getElementById("version");
if (versionEl) {
  versionEl.textContent = `v${__HRON_VERSION__}`;
}

// ── Theme ──

const themeToggle = document.getElementById("theme-toggle");

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

themeToggle?.addEventListener("click", () => {
  const current =
    document.documentElement.getAttribute("data-theme") ?? getSystemTheme();
  applyTheme(current === "dark" ? "light" : "dark");
});

// ── Translator: cron → hron, typed out and cycled ──

interface Pair {
  cron: string;
  hron: string;
}

const PAIRS: Pair[] = [
  { cron: "0 9 * * 1-5", hron: "every <b>weekday</b> at 9:00" },
  { cron: "0 10 * * 0,6", hron: "every <b>weekend</b> at 10:00" },
  { cron: "*/30 9-17 * * 1-5", hron: "every <b>30 min</b> from 09:00 to 17:00 on weekdays" },
  { cron: "0 9 1,15 * *", hron: "every <b>month</b> on the 1st, 15th at 9:00" },
  { cron: "— not possible —", hron: "every <b>2 weeks</b> on monday at 9:00" },
  { cron: "— not possible —", hron: "every year on <b>dec 25</b> at 00:00" },
];

const CURSOR = '<span class="translator-cursor"></span>';
const cronEl = document.getElementById("t-cron");
const hronEl = document.getElementById("t-hron");

function escapeType(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;");
}

function typeOut(target: HTMLElement, markup: string, done: () => void) {
  const plain = markup.replace(/<\/?b>/g, "");
  let n = 0;
  const step = () => {
    n++;
    target.innerHTML = escapeType(plain.slice(0, n)) + CURSOR;
    if (n < plain.length) {
      window.setTimeout(step, 22 + Math.random() * 26);
    } else {
      target.innerHTML = markup + CURSOR;
      done();
    }
  };
  step();
}

if (cronEl && hronEl) {
  const cron = cronEl;
  const hron = hronEl;
  let i = 0;
  const cycle = () => {
    const pair = PAIRS[i % PAIRS.length];
    cron.textContent = pair.cron;
    cron.style.fontStyle = pair.cron.startsWith("—") ? "italic" : "normal";
    typeOut(hron, pair.hron, () => {
      i++;
      window.setTimeout(cycle, 2200);
    });
  };
  // Respect reduced-motion: skip the typing, just rotate.
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduceMotion) {
    let j = 0;
    const rotate = () => {
      const pair = PAIRS[j % PAIRS.length];
      cron.textContent = pair.cron;
      cron.style.fontStyle = pair.cron.startsWith("—") ? "italic" : "normal";
      hron.innerHTML = pair.hron + CURSOR;
      j++;
      window.setTimeout(rotate, 3200);
    };
    window.setTimeout(rotate, 2600);
  } else {
    window.setTimeout(cycle, 1400);
  }
}

// ── Install tabs ──

const tabs = document.getElementById("install-tabs");
const cmdText = document.getElementById("install-cmd-text");

tabs?.addEventListener("click", (e) => {
  const btn = (e.target as HTMLElement).closest<HTMLButtonElement>(".install-tab");
  if (!btn || !cmdText) return;
  tabs.querySelectorAll(".install-tab").forEach((t) => t.classList.remove("active"));
  btn.classList.add("active");
  cmdText.textContent = btn.dataset.cmd ?? "";
});

// ── Copy install command ──

const copyBtn = document.getElementById("copy-btn");
copyBtn?.addEventListener("click", () => {
  const label = copyBtn.querySelector("span");
  if (!cmdText || !label || !navigator.clipboard) return;
  void navigator.clipboard.writeText(cmdText.textContent ?? "").then(() => {
    const prev = label.textContent;
    label.textContent = "Copied";
    window.setTimeout(() => {
      label.textContent = prev;
    }, 1400);
  });
});
