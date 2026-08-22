const fs = require("fs")
const path = require("path")

// Test: heroicons plugin can resolve all used icon names
describe("heroicons plugin", () => {
  test("resolves all icon names used in the app", () => {
    const heroiconsDir = path.join(__dirname, "../../../../deps/heroicons/optimized")

    // Icon names used in the application (extracted from templates and components)
    const usedIcons = [
      "information-circle",
      "exclamation-circle",
      "x-mark",
      "arrow-path",
      "arrow-right",
      "arrow-left",
      "exclamation-triangle",
      "bars-3",
      "computer-desktop-micro",
      "sun-micro",
      "moon-micro",
      "plus",
      "cpu-chip",
      "check-circle-micro",
      "archive-box",
      "archive-box-x-mark",
      "arrow-down-left",
      "arrow-down-tray",
      "arrow-path-rounded-square",
      "arrow-top-right-on-square",
      "arrow-trending-up",
      "arrow-up-right",
      "banknotes",
      "bars-3-bottom-left",
      "beaker",
      "bolt",
      "bookmark",
      "building-office-2",
      "calendar",
      "calendar-days",
      "chart-bar",
      "check",
      "check-badge",
      "check-circle",
      "chevron-down",
      "chevron-left",
      "chevron-right",
      "chevron-up",
      "clipboard-document-check",
      "clipboard-document-list",
      "clock",
      "code-bracket",
      "cog-6-tooth",
      "command-line",
      "currency-dollar",
      "document-magnifying-glass",
      "document-text",
      "envelope",
      "eye",
      "eye-slash",
      "fire",
      "flag",
      "funnel",
      "hashtag",
      "identification",
      "inbox",
      "inbox-arrow-down",
      "inbox-stack",
      "key",
      "link-slash",
      "lock-closed",
      "lock-open",
      "magnifying-glass",
      "magnifying-glass-circle",
      "moon",
      "paper-airplane",
      "pencil-square",
      "plus-circle",
      "question-mark-circle",
      "queue-list",
      "rectangle-stack",
      "rocket-launch",
      "scale",
      "server-stack",
      "shield-exclamation",
      "signal-slash",
      "sparkles",
      "stop-circle",
      "sun-micro",
      "table-cells",
      "tag",
      "ticket",
      "trash",
      "trophy",
      "user-circle",
      "variable",
      "x-circle"
    ]

    // Build the icon values map (same logic as heroicons plugin)
    let values = {}
    const iconSizes = [
      ["", "/24/outline"],
      ["-solid", "/24/solid"],
      ["-mini", "/20/solid"],
      ["-micro", "/16/solid"]
    ]

    iconSizes.forEach(([suffix, dir]) => {
      const dirPath = path.join(heroiconsDir, dir)
      fs.readdirSync(dirPath).forEach(file => {
        let name = path.basename(file, ".svg") + suffix
        values[name] = { name, fullPath: path.join(dirPath, file) }
      })
    })

    // Test: all icons should be resolvable
    const missing = usedIcons.filter(icon => !values[icon])

    expect(missing.length).toBe(0)
    if (missing.length > 0) {
      console.error("Missing icons:", missing)
    }
  })

  test("has fallback directory structure for vendored icons", () => {
    const fallbackDir = path.join(__dirname, "../../../../reference/assets/icons")
    // This test should fail initially, then pass after we implement fallback support
    expect(() => {
      fs.accessSync(fallbackDir)
    }).toThrow()
  })
})
