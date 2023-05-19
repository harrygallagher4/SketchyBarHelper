--
-- This script is basically a 1:1 recreation of my sketchybar config which was
-- originally written in zsh. It's very minimal and pretty sloppy honestly.
--

local sb = sketchybar or require("core")
local inspect = require("inspect")

local function font(default_name, default_props)
  local name = default_name
  local size = default_props.size
  local weight = default_props.weight

  return function(n)
    local size_offset = n or 0
    return string.format("%s:%s:%d", name, weight, (size + size_offset))
  end
end

local label_font = font("Iosevka Nerd Font", { size = 12, weight = "Regular" })
local space_font = font("JetBrains Mono", { size = 12, weight = "Regular" })
local icon_font = font("Iosevka Nerd Font", { size = 12, weight = "Regular" })


sb.update()

sb.add_event("app_action")
sb.add_event("window_action")
sb.add_event("yabai_secondary_clicked")
sb.add_event("skhd_mode")

sb.bar({
  sticky = true,
  height = 20,
  blur_radius = 50,
  position = "top",
  color = "0xd015121c",
  padding = { left = 8, right = 8 }
})

sb.defaults({
  updates = "when_shown",
  drawing = "on",
  icon = {
    font = icon_font(),
    color = "0xffa4b9ef",
    highlight_color = "0xffebddaa",
    padding = { left = 0, right = 0 },
  },
  label = {
    font = label_font(),
    color = "0xffa4b9ef",
    highlight_color = "0xffebddaa",
    padding = { left = 2, right = 2 }
  }
})

sb.defaults({
  label = {
    font = space_font(),
    padding = { left = 3, right = 3 }
  }
})

for i = 1, 9 do
  sb.add_space(i, "left")
  sb.set(i, {
    label = i,
    associated_space = i,
    click_script = "yabai -m space --focus " .. i,
    script = "/Users/harry/.config/sketchybar/plugins/space.sh"
  })
end

--
-- Non-space defaults
--
sb.defaults({
  label = {
    font = label_font(),
    padding = { left = 2, right = 2 }
  }
})

--
-- Yabai
--
sb.item("yabai_primary", {
  script = "/Users/harry/.config/sketchybar/plugins/yabai.sh",
  icon = {
    font = icon_font(1),
    padding = { left = 6 }
  },
  subscribe = {
    "space_change",
    "window_action",
    "app_action",
    "yabai_secondary_clicked",
    "mouse.clicked"
  }
})

sb.item("yabai_secondary", {
  icon = { font = icon_font(4) },
  script = "/Users/harry/.config/sketchybar/plugins/yabai_secondary.sh",
  subscribe = { "mouse.clicked" }
})

--
-- Right items
--
sb.item("clock", {
  position = "right",
  update_freq = 1,
  label = {
    y_offset = 2,
    padding = { left = 2 }
  },
  script = "/Users/harry/.config/sketchybar/plugins/clock.sh"
})

sb.update()

