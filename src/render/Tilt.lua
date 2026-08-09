-- Overworld tilt mode: a cycleable, purely presentational perspective
-- tilt for the free-roam overworld.  The flat world canvas is treated as
-- a ground plane, rotated about the horizontal axis through the viewport
-- centre and viewed through a perspective camera, so rows above centre
-- recede/shrink and rows below come closer (the HD-2D "diorama" look).
-- Like survey zoom this lives entirely in the draw path -- zero effect
-- on collision, movement, triggers, scripts -- and is persisted via
-- save.options.tilt (OFF / 15 / 35 / 50).
--
-- Spec: docs/new-features.md (tilt mode)

local Zoom = require("src.render.Zoom")
local love = love

local Tilt = {}

-- Sky images for tilt mode, one per time-of-day phase (nil slot = no
-- custom image for that phase; falls back to a neighbouring phase, or to
-- the procedural gradient if nothing at all is loaded -- see
-- Tilt:getSkyBlend / Sky.lua's getSkyImage).
Tilt.SKY_PHASES = { "day", "dawn", "dusk", "night" }
Tilt.skyImages = {}       -- phase -> love.graphics.Image
Tilt.skyImagePaths = {}   -- phase -> the source path last set (for UI display)
-- Legacy single-image fields. Kept so any old caller that still reads
-- Tilt.skyImage directly (rather than through getSkyBlend) sees SOMETHING
-- sane: it mirrors whichever slot is currently primary.
Tilt.skyImage = nil
Tilt.skyImagePath = nil
-- Store options for sky enabled check
Tilt.options = nil
-- Sky rotation tracking (in radians). Unbounded -- see updateSkyRotation --
-- so a full turn pans the whole way round a 360 panorama instead of
-- stopping at a quarter turn.
Tilt.skyRotation = 0
Tilt.skyTargetRotation = 0
Tilt.skyBounceOffset = 0
-- Pixelation canvases for sky images (cached, one per phase)
Tilt.pixelatedSkyCanvases = {}
-- Legacy single-canvas mirror (see Tilt.skyImage above)
Tilt.pixelatedSkyCanvas = nil

-- Discrete tilt angles in degrees (index 0 is off).  Cycle: off→15→35→50→off.
Tilt.ANGLES_DEG = { 0, 15, 35, 50 }
Tilt.ANGLE_LABELS = { "OFF", "15", "35", "50" }

-- Runtime state.  `level` is the discrete option (0=off .. 3=50°);
-- `angle` is the live tweened tilt in radians; `from`/`goal`/`t` drive
-- the ease between any two levels (including off).
Tilt.level = 0
Tilt.angle = 0
Tilt.from = 0
Tilt.goal = 0
Tilt.t = 1
-- Compatibility: TARGET_ANGLE is the current goal; enabled mirrors level > 0.
Tilt.TARGET_ANGLE = 0
Tilt.enabled = false

Tilt.TWEEN_TIME = 0.25
Tilt.FOCAL = 1.0
Tilt.VIEW_MARGIN = 0.35

local function ease(t)
  return t * t * (3 - 2 * t)
end

local function goalFor(level)
  return math.rad(Tilt.ANGLES_DEG[level + 1] or 0)
end

function Tilt.setLevel(level)
  level = math.floor(tonumber(level) or 0)
  if level < 0 then level = 0 end
  if level > 3 then level = 3 end
  local goal = goalFor(level)
  if goal ~= Tilt.goal or level ~= Tilt.level then
    Tilt.from = Tilt.angle
    Tilt.goal = goal
    Tilt.t = 0
  end
  Tilt.level = level
  Tilt.TARGET_ANGLE = goal
  Tilt.enabled = level > 0
end

-- Advance OFF → 15 → 35 → 50 → OFF.  Returns the new level.
function Tilt.cycle()
  Tilt.setLevel((Tilt.level + 1) % 4)
  return Tilt.level
end

-- Legacy name: one cycle step (same as cycle).
function Tilt.toggle()
  return Tilt.cycle()
end

function Tilt.reset()
  Tilt.level = 0
  Tilt.angle = 0
  Tilt.from = 0
  Tilt.goal = 0
  Tilt.t = 1
  Tilt.TARGET_ANGLE = 0
  Tilt.enabled = false
end

function Tilt.applyOptions(opts)
  local level = math.floor(tonumber(opts and opts.tilt) or 0)
  if level < 0 then level = 0 end
  if level > 3 then level = 3 end
  Tilt.level = level
  Tilt.goal = goalFor(level)
  Tilt.from = Tilt.goal
  Tilt.angle = Tilt.goal
  Tilt.t = 1
  Tilt.TARGET_ANGLE = Tilt.goal
  Tilt.enabled = level > 0
  
  -- Store options for sky enabled check
  Tilt.options = opts

  -- Load each phase's sky image from the save directory if enabled and
  -- not already loaded. A save from before the four-slot split only has
  -- "sky_image.png" on disk with no phase in its name; that file is
  -- adopted as the DAY slot once, so an existing player's custom sky
  -- keeps working exactly where it always showed (day/overworld default)
  -- instead of vanishing on upgrade.
  if opts and opts.skyImageEnabled then
    if not Tilt.skyImages.day and not love.filesystem.getInfo("sky_image_day.png")
       and love.filesystem.getInfo("sky_image.png") then
      local legacy = love.filesystem.read("sky_image.png")
      if legacy then love.filesystem.write("sky_image_day.png", legacy) end
    end
    for _, phase in ipairs(Tilt.SKY_PHASES) do
      if not Tilt.skyImages[phase] then
        local savePath = Tilt.skyImageFile(phase)
        if love.filesystem.getInfo(savePath) then
          local success, img = pcall(love.graphics.newImage, savePath)
          if success and img then
            Tilt.skyImages[phase] = img
            print("Sky image loaded from save directory: " .. savePath)
          else
            print("Failed to load sky image from save directory: " .. tostring(img))
          end
        end
      end
    end
    Tilt:_syncLegacySkyImage()
  end
end

-- The save-directory filename for a phase's sky image.
function Tilt.skyImageFile(phase)
  return "sky_image_" .. tostring(phase) .. ".png"
end

-- Mirror whichever phase is "primary" right now onto the legacy
-- Tilt.skyImage / skyImagePath fields, for any old call site that still
-- reads them directly instead of going through getSkyBlend.
function Tilt:_syncLegacySkyImage()
  local primary = Tilt.skyImages.day or Tilt.skyImages.dusk
                 or Tilt.skyImages.dawn or Tilt.skyImages.night
  Tilt.skyImage = primary
  for phase, img in pairs(Tilt.skyImages) do
    if img == primary then Tilt.skyImagePath = Tilt.skyImagePaths[phase]; break end
  end
end

-- Check if sky image should be rendered (enabled and at least one phase's
-- image loaded).
function Tilt:isSkyEnabled()
  if not (Tilt.options and Tilt.options.skyImageEnabled) then return false end
  for _, phase in ipairs(Tilt.SKY_PHASES) do
    if Tilt.skyImages[phase] then return true end
  end
  return false
end

function Tilt.levelLabel(level)
  return Tilt.ANGLE_LABELS[(level or Tilt.level) + 1] or "OFF"
end

-- Ease angle from `from` toward `goal` over TWEEN_TIME.
function Tilt.update(dt)
  if Tilt.t < 1 then
    Tilt.t = math.min(1, Tilt.t + dt / Tilt.TWEEN_TIME)
    local e = ease(Tilt.t)
    Tilt.angle = Tilt.from + (Tilt.goal - Tilt.from) * e
  else
    Tilt.angle = Tilt.goal
  end
  Tilt.TARGET_ANGLE = Tilt.goal
  Tilt.enabled = Tilt.level > 0
  -- Ease sky rotation toward target
  local rotDiff = Tilt.skyTargetRotation - Tilt.skyRotation
  if math.abs(rotDiff) > 0.001 then
    Tilt.skyRotation = Tilt.skyRotation + rotDiff * 5 * dt
  end
end

-- The sky image is a 360 panorama, so its target rotation is the player's
-- COMPASS FACING, not a nudge accumulated from movement deltas -- the old
-- version clamped its target to +/-90 degrees, which meant turning around
-- fully never panned past a quarter of the image no matter how long you
-- walked. "down" (south) is 0, matching the image's un-rotated framing.
local FACING_ANGLE = {
  down = 0,
  left = math.pi / 2,
  up = math.pi,
  right = -math.pi / 2,
}

-- Update the sky's target rotation from the player's facing direction.
-- `facing` is one of "up"/"down"/"left"/"right" (Player.facing).
-- `moving` adds a small bounce so a walk still reads as motion under a
-- sky that has stopped turning (e.g. walking straight ahead).
function Tilt.updateSkyRotation(facing, moving)
  local target = FACING_ANGLE[facing]
  if target then
    -- Unwrap: pick whichever full-turn-equivalent of `target` sits
    -- closest to the sky's CURRENT position, so a turn always pans the
    -- short way around the panorama. Without this, turning left then
    -- right then left again would slowly wind the rotation up across
    -- many full turns instead of settling near 0.
    local twoPi = math.pi * 2
    target = target + math.floor((Tilt.skyRotation - target) / twoPi + 0.5) * twoPi
    Tilt.skyTargetRotation = target
  end
  if moving then
    Tilt.skyBounceOffset = math.sin(love.timer.getTime() * 5) * 0.03
  else
    Tilt.skyBounceOffset = 0
  end
end

-- true while tilt is on *or* still tweening -- i.e. whenever the renderer
-- must take the perspective path rather than the flat blit
function Tilt.active()
  return Tilt.level > 0 or Tilt.angle > 0
end

function Tilt.gateOK(top, overworld)
  return Zoom.gateOK(top, overworld)
end

function Tilt.groundPoint(cx, cy, vw, vh)
  local a = Tilt.angle
  if a <= 0 then return cx, cy, 1 end
  local u = cx - vw * 0.5
  local w = cy - vh * 0.5
  local d = Tilt.FOCAL * vh
  local scale = d / (d - w * math.sin(a))
  local sx = vw * 0.5 + u * scale
  local sy = vh * 0.5 + w * math.cos(a) * scale
  return sx, sy, scale
end

function Tilt.viewGrowth()
  local a = Tilt.angle
  if a <= 0 then return 1 end
  local topScale = 1 / (1 + 0.5 * math.sin(a) / Tilt.FOCAL)
  local base = 1 / (math.cos(a) * topScale)
  return base + Tilt.VIEW_MARGIN * (base - 1)
end

function Tilt.meshCorners(vw, vh)
  local corners = {
    { 0, 0, 0, 0 },
    { vw, 0, 1, 0 },
    { vw, vh, 1, 1 },
    { 0, vh, 0, 1 },
  }
  local out = {}
  for i, c in ipairs(corners) do
    local sx, sy, scale = Tilt.groundPoint(c[1], c[2], vw, vh)
    out[i] = { sx, sy, c[3], c[4], scale }
  end
  return out
end

-- Set the sky image for one time-of-day PHASE ("day", "dawn", "dusk", or
-- "night"). `phase` defaults to "day" so any old single-argument call
-- site keeps doing exactly what it always did.
function Tilt:setSkyImage(path, phase)
  phase = phase or "day"
  local valid = false
  for _, p in ipairs(Tilt.SKY_PHASES) do if p == phase then valid = true end end
  if not valid then phase = "day" end

  path = path and tostring(path) or nil

  -- Same source already loaded into this slot: nothing to do.
  if path == Tilt.skyImagePaths[phase] and Tilt.skyImages[phase] then
    return
  end

  Tilt.skyImagePaths[phase] = path
  if Tilt.skyImages[phase] and Tilt.skyImages[phase].release then
    Tilt.skyImages[phase]:release()
  end
  Tilt.skyImages[phase] = nil
  if Tilt.pixelatedSkyCanvases[phase] and Tilt.pixelatedSkyCanvases[phase].release then
    Tilt.pixelatedSkyCanvases[phase]:release()
  end
  Tilt.pixelatedSkyCanvases[phase] = nil

  if path and path ~= "" then
    local love = love
    local savePath = Tilt.skyImageFile(phase)

    -- Try to read the source file and write it into the save directory,
    -- which is the only place LÖVE can load an Image from on every
    -- platform this ships on.
    local sourceFile = io.open(path, "rb")
    if sourceFile then
      local content = sourceFile:read("*a")
      sourceFile:close()
      if content then
        love.filesystem.write(savePath, content)
        print("Sky image copied to save directory: " .. savePath)
      end
    end

    local success, img = pcall(love.graphics.newImage, savePath)
    if not success then
      print("Failed to load sky image: " .. tostring(img))
    else
      Tilt.skyImages[phase] = img
      print("Sky image loaded successfully from save directory: " .. savePath)
    end
  end
  Tilt:_syncLegacySkyImage()
end

-- Load a sky image that is ALREADY sitting in the save directory (e.g.
-- delivered there by a platform's file picker) into a phase slot. Unlike
-- setSkyImage, this does not try to io.open a raw OS path and copy it in
-- -- there is no OS path to copy FROM here, the picker put the file
-- straight into the save directory itself.
function Tilt:adoptSkyImageFile(phase, saveRelativePath)
  phase = phase or "day"
  if not love.filesystem.getInfo(saveRelativePath) then return false end
  local destPath = Tilt.skyImageFile(phase)
  if saveRelativePath ~= destPath then
    local content = love.filesystem.read(saveRelativePath)
    if not content then return false end
    love.filesystem.write(destPath, content)
  end
  local success, img = pcall(love.graphics.newImage, destPath)
  if not success then return false end
  if Tilt.skyImages[phase] and Tilt.skyImages[phase].release then
    Tilt.skyImages[phase]:release()
  end
  Tilt.skyImages[phase] = img
  Tilt.skyImagePaths[phase] = destPath
  if Tilt.pixelatedSkyCanvases[phase] and Tilt.pixelatedSkyCanvases[phase].release then
    Tilt.pixelatedSkyCanvases[phase]:release()
  end
  Tilt.pixelatedSkyCanvases[phase] = nil
  Tilt:_syncLegacySkyImage()
  return true
end

-- Remove the sky image set for one phase (or "day" if omitted).
function Tilt:removeSkyImage(phase)
  phase = phase or "day"
  if Tilt.skyImages[phase] and Tilt.skyImages[phase].release then
    Tilt.skyImages[phase]:release()
  end
  Tilt.skyImages[phase] = nil
  Tilt.skyImagePaths[phase] = nil
  if Tilt.pixelatedSkyCanvases[phase] and Tilt.pixelatedSkyCanvases[phase].release then
    Tilt.pixelatedSkyCanvases[phase]:release()
  end
  Tilt.pixelatedSkyCanvases[phase] = nil
  pcall(love.filesystem.remove, Tilt.skyImageFile(phase))
  Tilt:_syncLegacySkyImage()
end

-- The pixelated (or raw) drawable for one phase's image, cached per phase
-- exactly like the old single-slot cache was.
function Tilt:_pixelatedSky(phase)
  local img = Tilt.skyImages[phase]
  if not img then return nil end
  local pixelation = Tilt.options and Tilt.options.skyPixelation or 0
  if pixelation == 0 then return img end

  local scale = math.pow(2, pixelation) -- 2, 4, 8, or 16
  local skyW, skyH = img:getWidth(), img:getHeight()
  local pixelW = math.max(1, math.floor(skyW / scale))
  local pixelH = math.max(1, math.floor(skyH / scale))

  local canvas = Tilt.pixelatedSkyCanvases[phase]
  if not canvas or canvas:getWidth() ~= pixelW or canvas:getHeight() ~= pixelH then
    if canvas and canvas.release then canvas:release() end
    canvas = love.graphics.newCanvas(pixelW, pixelH)
    canvas:setFilter("nearest", "nearest")
    love.graphics.setCanvas(canvas)
    love.graphics.clear(1, 1, 1, 1)
    love.graphics.draw(img, 0, 0, 0, pixelW / skyW, pixelH / skyH)
    love.graphics.setCanvas()
    Tilt.pixelatedSkyCanvases[phase] = canvas
  end
  return canvas
end

-- Which loaded phase a phase's weight should fall back to when that
-- phase itself has no image set: dawn leans on day's image, night's
-- absence leans on dusk's -- so a player who only ever sets a "day" and
-- a "night" image still gets a sensible dawn/dusk out of them, rather
-- than the sky silently reverting to the flat gradient for two phases
-- out of four.
local PHASE_FALLBACK = { day = "day", dawn = "day", dusk = "night", night = "night" }

-- Get the current sky image (single slot, back-compat). Prefers "day",
-- like the original single-image build always showed.
function Tilt:getSkyImage()
  local img, _, _ = Tilt:getSkyBlend({ day = 1 })
  return img
end

-- The two images (and how to blend between them) for the current mix of
-- time-of-day phases. `weights` is a table like { day = 0.7, dusk = 0.3 }
-- (see the ADVANCED_SHAPE mod's DayNight.mix, which is the caller for the
-- normal in-game path) -- any subset of "day"/"dawn"/"dusk"/"night",
-- weights need not sum to 1.
--
-- Returns primaryImg, secondaryImg, secondaryAlpha. secondaryImg is nil
-- when there is nothing to cross-fade with; draw primaryImg first (fully
-- opaque) and, if present, secondaryImg on top at secondaryAlpha to get a
-- linear cross-fade that exactly matches the weights.
function Tilt:getSkyBlend(weights)
  if not Tilt:isSkyEnabled() then return nil end
  weights = weights or { day = 1 }

  -- Fold any phase with no image of its own onto its fallback, so the
  -- weight is never simply dropped.
  local folded = {}
  for phase, w in pairs(weights) do
    if w and w > 0 then
      local target = Tilt.skyImages[phase] and phase or (PHASE_FALLBACK[phase] or phase)
      folded[target] = (folded[target] or 0) + w
    end
  end

  local best, bestW, second, secondW = nil, -1, nil, -1
  for _, phase in ipairs(Tilt.SKY_PHASES) do
    local w = folded[phase]
    if w and Tilt.skyImages[phase] then
      if w > bestW then
        best, bestW, second, secondW = phase, w, best, bestW
      elseif w > secondW then
        second, secondW = phase, w
      end
    end
  end

  if not best then
    -- Nothing in the requested mix is loaded (e.g. only "night" was set
    -- and it is noon); show whatever IS loaded rather than nothing.
    for _, phase in ipairs(Tilt.SKY_PHASES) do
      if Tilt.skyImages[phase] then best, bestW = phase, 1; break end
    end
  end
  if not best then return nil end

  local primary = Tilt:_pixelatedSky(best)
  local secondaryImg, alpha = nil, 0
  if second and secondW and secondW > 0 then
    local total = bestW + secondW
    alpha = total > 0 and (secondW / total) or 0
    if alpha > 0.01 then secondaryImg = Tilt:_pixelatedSky(second) end
  end
  return primary, secondaryImg, alpha
end

-- ------- drawing a custom sky image
--
-- Reused Quad objects, keyed by an arbitrary caller-chosen slot name, so a
-- steady 60fps of sky drawing does not allocate a new Quad every frame and
-- so two callers layering a primary/secondary cross-fade do not fight over
-- the same Quad's viewport.
local skyQuads = {}

-- Draw ONE sky image as a full-canvas, wrapping 360 panorama. This is the
-- single implementation every caller shares -- the base Renderer's flat
-- 2D blit and the ADVANCED_SHAPE mod's 3D voxel pass alike -- so a fix
-- here reaches both instead of two copies of the same math silently
-- drifting apart (which is exactly how the mod's copy went stale against
-- this one the first time).
--
-- The old version drew a fixed two copies of the image, translated across
-- the screen, which broke two ways: the rotation that picks which slice
-- of the image is centred used to be clamped to a quarter turn (see
-- updateSkyRotation above), so the picture never panned past a sliver of
-- what a 360 panorama actually holds; and whenever the zoom or offset
-- pushed the seam between those two copies into view -- or pushed the
-- image far enough to clear its own top or bottom edge -- the canvas
-- behind showed through as a black rectangle, because there was no third
-- copy to catch the gap and nothing drawn at all above/below the image.
--
-- A Quad has no such edge to run out of. Its texture-space viewport is set
-- in SOURCE-IMAGE pixels and can sit anywhere on the number line; with the
-- image's horizontal wrap mode set to "repeat", a viewport far outside
-- 0..imgW just keeps sampling the image again, seamlessly, for ANY
-- rotation -- a genuine full turn pans the whole picture, it does not stop
-- at +/-90 degrees. The vertical wrap stays "clamp": most custom skies are
-- not top/bottom seamless, so panning past an edge holds that edge's own
-- pixels instead of wrapping into the opposite edge or showing nothing.
-- Either way the Quad's SCREEN-space size is set to exactly ww x wh, so
-- there is no seam for a second copy to fail to cover.
--
-- `slot` distinguishes this layer's cached Quad from any other layer
-- drawn the same frame (e.g. a primary/secondary cross-fade pair).
function Tilt:drawSkyLayer(img, alpha, ww, wh, slot)
  if not (img and alpha and alpha > 0 and ww and wh and ww > 0 and wh > 0) then
    return false
  end
  local imgW, imgH = img:getDimensions()
  if imgW < 1 or imgH < 1 then return false end
  pcall(img.setWrap, img, "repeat", "clamp")

  local zoom = (Tilt.options and Tilt.options.skyZoom) or 1.0
  if zoom < 0.05 then zoom = 0.05 end
  local offsetY = (Tilt.options and Tilt.options.skyOffsetY) or 0
  local rotation = (Tilt.skyRotation or 0) + (Tilt.skyBounceOffset or 0)

  -- how much of the source image (in its own pixels) the frame shows: at
  -- zoom 1 the whole image width covers the frame once, same as the old
  -- per-frame scale did
  local viewW = imgW / zoom
  local viewH = imgH / zoom
  -- azimuth -> a horizontal pixel position in the (wrapping) source; the
  -- viewport is centred on it so turning the rotation PANS the picture
  -- instead of sliding a fixed strip of it off the edge of the frame
  local u0 = (rotation / (2 * math.pi)) * imgW - viewW / 2
  local v0 = (0.5 - offsetY) * imgH - viewH / 2

  slot = slot or 1
  local quad = skyQuads[slot]
  if quad then
    quad:setViewport(u0, v0, viewW, viewH, imgW, imgH)
  else
    local ok, q = pcall(love.graphics.newQuad, u0, v0, viewW, viewH, imgW, imgH)
    if ok then quad = q; skyQuads[slot] = q end
  end
  if not quad then return false end

  love.graphics.setColor(1, 1, 1, alpha)
  love.graphics.draw(img, quad, 0, 0, 0, ww / viewW, wh / viewH)
  return true
end

-- Draw the CURRENT sky image(s) -- primary plus, mid-transition, a
-- cross-faded secondary -- as a full-canvas panorama. `weights` selects
-- the phase blend exactly as getSkyBlend does; nil resolves to "day" (or
-- whatever single image IS loaded), which is what a caller with no
-- time-of-day system of its own (the base Renderer) wants. Leaves colour
-- set to the last-drawn layer's alpha; callers that draw more on top
-- should reset it themselves, same as with any other love.graphics.draw.
function Tilt:drawSkyPanorama(ww, wh, weights, alphaScale)
  local primary, secondary, secondAlpha = Tilt:getSkyBlend(weights)
  if not primary then return false end
  alphaScale = alphaScale or 1
  local drew = Tilt:drawSkyLayer(primary, alphaScale, ww, wh, "a")
  if secondary and secondAlpha and secondAlpha > 0.01 then
    Tilt:drawSkyLayer(secondary, secondAlpha * alphaScale, ww, wh, "b")
  end
  love.graphics.setColor(1, 1, 1, 1)
  return drew
end

-- Drop the cached sky Quads (window resize, graphics-context loss / hot
-- reload). A Quad is not itself a GPU object, but the viewport it was
-- last set to belongs to a specific image's dimensions, and a stale one
-- is cheaper to just rebuild than to reason about after a context swap.
function Tilt:invalidateSkyQuads()
  skyQuads = {}
end

return Tilt
