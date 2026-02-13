// ── Version ──

declare const __HRON_VERSION__: string;
const versionEl = document.getElementById("version");
if (versionEl) {
  versionEl.textContent = `v${__HRON_VERSION__}`;
}

// ── Theme ──

const themeToggle = document.getElementById("theme-toggle") as HTMLButtonElement;

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

// ── Install toggle ──

document.querySelectorAll<HTMLButtonElement>(".toggle-btn").forEach((btn) => {
  btn.addEventListener("click", () => {
    const parent = btn.closest(".install-java");
    if (!parent) return;

    parent.querySelectorAll(".toggle-btn").forEach((b) => b.classList.remove("active"));
    parent.querySelectorAll(".toggle-content").forEach((c) => c.classList.remove("active"));

    btn.classList.add("active");
    const target = btn.dataset.target;
    if (target) {
      parent.querySelector(`#${target}`)?.classList.add("active");
    }
  });
});
