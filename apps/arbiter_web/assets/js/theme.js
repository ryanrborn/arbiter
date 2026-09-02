// Applies the persisted daisyUI theme before first paint.
//
// This lived inline in root.html.heex (where `mix phx.new` puts it). It was
// lifted out so the Content-Security-Policy in ArbiterWeb.Router can keep
// `script-src 'self'` — an inline <script> would have forced
// `'unsafe-inline'` there, which is most of what a CSP buys you.
//
// Loaded as a blocking <script> in <head>, deliberately: it must set
// data-theme before the body renders or the page flashes the wrong theme.
(() => {
  const setTheme = (theme) => {
    if (theme === "system") {
      localStorage.removeItem("phx:theme");
      document.documentElement.removeAttribute("data-theme");
    } else {
      localStorage.setItem("phx:theme", theme);
      document.documentElement.setAttribute("data-theme", theme);
    }
  };

  if (!document.documentElement.hasAttribute("data-theme")) {
    setTheme(localStorage.getItem("phx:theme") || "system");
  }

  window.addEventListener(
    "storage",
    (e) => e.key === "phx:theme" && setTheme(e.newValue || "system"),
  );

  window.addEventListener("phx:set-theme", (e) =>
    setTheme(e.target.dataset.phxTheme),
  );
})();
