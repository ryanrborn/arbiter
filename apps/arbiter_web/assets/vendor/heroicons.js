const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = plugin(function({matchComponents, theme}) {
  let iconsDir = path.join(__dirname, "../../../../deps/heroicons/optimized")
  let fallbackIconsDir = path.join(__dirname, "../../../../reference/assets/icons")
  let values = {}
  let icons = [
    ["", "/24/outline"],
    ["-solid", "/24/solid"],
    ["-mini", "/20/solid"],
    ["-micro", "/16/solid"]
  ]
  icons.forEach(([suffix, dir]) => {
    fs.readdirSync(path.join(iconsDir, dir)).forEach(file => {
      let name = path.basename(file, ".svg") + suffix
      values[name] = {name, fullPath: path.join(iconsDir, dir, file)}
    })
  })

  // Add fallback icons from reference/assets/icons if the directory exists
  if (fs.existsSync(fallbackIconsDir)) {
    let fallbackIcons = [
      ["", "/outline"],
      ["-solid", "/solid"],
      ["-mini", "/mini"],
      ["-micro", "/micro"]
    ]
    fallbackIcons.forEach(([suffix, dir]) => {
      let fallbackDir = path.join(fallbackIconsDir, dir)
      if (fs.existsSync(fallbackDir)) {
        fs.readdirSync(fallbackDir).forEach(file => {
          let name = path.basename(file, ".svg") + suffix
          // Only add if not already present in deps/heroicons
          if (!values[name]) {
            values[name] = {name, fullPath: path.join(fallbackDir, file)}
          }
        })
      }
    })
  }
  matchComponents({
    "hero": ({name, fullPath}) => {
      let content = fs.readFileSync(fullPath).toString().replace(/\r?\n|\r/g, "")
      content = encodeURIComponent(content)
      let size = theme("spacing.6")
      if (name.endsWith("-mini")) {
        size = theme("spacing.5")
      } else if (name.endsWith("-micro")) {
        size = theme("spacing.4")
      }
      return {
        [`--hero-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
        "-webkit-mask": `var(--hero-${name})`,
        "mask": `var(--hero-${name})`,
        "mask-repeat": "no-repeat",
        "background-color": "currentColor",
        "vertical-align": "middle",
        "display": "inline-block",
        "width": size,
        "height": size
      }
    }
  }, {values})
})
