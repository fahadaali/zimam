// The site's light and dark themes: the system's by default, or the one chosen with the toggle in
// the header, kept in this browser. A classic script in <head>, so the choice applies before the
// page paints; tokens.css and site.css follow `data-theme` on <html> (the screenshots and logos
// swap by their theme-light / theme-dark classes).
(() => {
  const KEY = "zimam.theme";
  const root = document.documentElement;
  const system = matchMedia("(prefers-color-scheme: dark)");
  try {
    const saved = localStorage.getItem(KEY);
    if (saved === "light" || saved === "dark") root.dataset.theme = saved;
  } catch {
    /* storage blocked: the system's theme */
  }

  const isDark = () => (root.dataset.theme ? root.dataset.theme === "dark" : system.matches);

  function choose(theme) {
    const apply = () => {
      root.dataset.theme = theme;
      sync();
    };
    // A short cross-fade between the themes, as a view transition; at once with Reduce Motion.
    if (document.startViewTransition && !matchMedia("(prefers-reduced-motion: reduce)").matches) document.startViewTransition(apply);
    else apply();
    try {
      localStorage.setItem(KEY, theme);
    } catch {
      /* for this page only */
    }
  }

  function sync() {
    for (const button of document.querySelectorAll("[data-theme-toggle]")) {
      const dark = isDark();
      button.setAttribute("aria-pressed", String(dark));
    }
  }

  document.addEventListener("DOMContentLoaded", () => {
    for (const button of document.querySelectorAll("[data-theme-toggle]")) {
      button.hidden = false;
      button.addEventListener("click", () => choose(isDark() ? "light" : "dark"));
    }
    sync();
  });
  system.addEventListener("change", sync);
})();
