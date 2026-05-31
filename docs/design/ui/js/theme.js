/* Shared theme toggle — persisted in localStorage, respects system pref */
(function () {
  function getSystem() {
    return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }
  function apply(theme) {
    document.documentElement.setAttribute("data-theme", theme);
    try { localStorage.setItem("hron-theme", theme); } catch (e) {}
  }
  var stored;
  try { stored = localStorage.getItem("hron-theme"); } catch (e) {}
  if (stored === "light" || stored === "dark") apply(stored);

  document.addEventListener("click", function (e) {
    var btn = e.target.closest && e.target.closest("#theme-toggle");
    if (!btn) return;
    var current = document.documentElement.getAttribute("data-theme") || getSystem();
    apply(current === "dark" ? "light" : "dark");
  });
})();
