-- Voxel Mods Combo: TERRARIUM + ADVANCED_SHAPE, packaged and loaded
-- together as one mod install.
--
-- This file does none of the actual mod work itself. It is a two-line
-- loader: each fork's own, complete main.lua runs in full, in its own
-- chunk, against the SAME `mod` object the engine handed this file --
-- exactly as if two separate mods had both been installed. That is
-- deliberate: rather than hand-fusing two codebases that (per the note in
-- each file) diverged well past main.lua -- Water.lua, Voxel3D.lua,
-- VoxelScene.lua, ChunkMesher.lua, OverworldBattle.lua, DayNight.lua and
-- several other "shared-named" files are genuinely different, untestable-
-- by-me pieces of engineering per fork -- this keeps each fork's actual
-- logic 100% intact and lets the engine's own hook-chaining machinery
-- (mod.hooks:wrap's next(), mod.events:on's multiple listeners) do the
-- composing, the same way it already does for any two independently
-- installed mods.
--
-- What DOES need to be true for two mods to share one package instead of
-- two: their files cannot collide on disk, and any guard flag one of them
-- sets on a shared ENGINE class to avoid double-patching cannot collide
-- with the other's. Both of those are handled inside main_terrarium.lua
-- and main_dramatic.lua themselves (each documents its own three or four
-- mechanical changes at the top) -- nothing here.
--
-- Result: every pipeline, every setting, every hotkey from both forks is
-- present and running. TERRARIUM's letter keys (v/g/t/c/b/n/p/h/k/j) and
-- ADVANCED_SHAPE's number keys (3/5/6/7/8/9) were already designed not to
-- collide with each other -- that is the entire reason TERRARIUM is on
-- letters -- so nothing needed to change there either.

local mod = ...

local function run(rel)
  local source = mod:read(rel)
  if not source then
    error(("VOXEL COMBO: %s is missing -- reinstall the mod"):format(rel), 0)
  end
  local chunk, err = load(source, "@" .. mod.path .. "/" .. rel)
  if not chunk then
    error(("VOXEL COMBO: %s did not compile: %s"):format(rel, tostring(err)), 0)
  end
  -- Each fork's main.lua expects to receive `mod` as its sole vararg,
  -- exactly as the engine hands it to a normal entry point (`local mod =
  -- ...` is the first line of both).
  chunk(mod)
end

-- Order matters only in one narrow sense: whichever runs first is the
-- INNER layer of any hook the other also wraps (Game:keypressed and
-- similar patches this file never touches -- see each sub-file's own
-- header). TERRARIUM first, ADVANCED_SHAPE second, so a battle's or a
-- free-roam camera's zoom/select handling -- the more input-hungry of the
-- two forks -- gets first refusal on any key or button both would
-- otherwise claim.
run("main_terrarium.lua")
run("main_dramatic.lua")

-- A single flat version string for anything that only checks
-- mod.exports.version and does not know to look for the namespaced
-- mod.exports.terrarium / mod.exports.dramatic tables each sub-file sets.
mod.exports.version = "combo-1.0.0 (terrarium 1.15.0-mobile.snow.1 "
                       .. "+ advanced_shape 1.5.5)"
