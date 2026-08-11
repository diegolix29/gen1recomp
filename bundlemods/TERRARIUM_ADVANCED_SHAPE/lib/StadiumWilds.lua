-- Stadium models for overworld wild Pokemon.
--
-- This module handles the rendering of stadium models for wild Pokemon
-- spawned by the overworld_wild_spawns mod, replacing their sprites with
-- 3D stadium models when the option is enabled.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local Mat4 = V.require("Mat4")
local StadiumPack = V.require("StadiumPack")
local StadiumRig = V.require("StadiumRig")
local Voxel3D = V.require("Voxel3D")

local StadiumWilds = {}

-- Cache for loaded wild Pokemon rigs (keyed by entity ID and species)
local rigCache = {}

-- Currently loaded rigs per entity
local entityRigs = {}

-- Current animation state per entity
local entityAnimStates = {}

-- Configuration
local WILDS_SCALE = 0.8  -- Scale for wild Pokemon models
local WILDS_ENABLED = false  -- Master toggle

-- ------- Entity Management

-- Check if stadium wilds feature is enabled
function StadiumWilds.enabled()
  if not WILDS_ENABLED then
    return false
  end
  -- Also check if stadium packs are available
  local okInstall, StadiumInstall = pcall(V.require, "StadiumInstall")
  if okInstall and StadiumInstall then
    return StadiumInstall.available()
  end
  return false
end

-- Enable or disable the feature
function StadiumWilds.setEnabled(enabled)
  WILDS_ENABLED = enabled == true
  if not enabled then
    StadiumWilds.clearCache()
  end
end

-- Check if an entity is a wild Pokemon (from overworld_wild_spawns mod)
function StadiumWilds.isWildPokemon(entity)
  if not entity then 
    return false 
  end
  -- Check for the overworld_wild_spawns marker
  local isWild = entity.overworldWildSpawn == true
  -- Also check by spawnId pattern as fallback
  if not isWild and entity.id and type(entity.id) == "string" then
    isWild = entity.id:find("wilds_of_kanto_entity") ~= nil
  end
  if not isWild and entity.spawnId and type(entity.spawnId) == "string" then
    isWild = entity.spawnId:find("wilds_of_kanto_entity") ~= nil
  end
  if isWild then
    print("StadiumWilds: isWildPokemon - entity IS wild, species:", entity.species, "id:", entity.id)
  end
  return isWild
end

-- Hook into entity creation from overworld_wild_spawns
-- This should be called when a wild Pokemon entity is created
function StadiumWilds.onEntityCreated(entity)
  if not StadiumWilds.enabled() then return end
  if not StadiumWilds.isWildPokemon(entity) then return end
  
  -- Try to load the stadium model for this entity
  local ok = pcall(function()
    return StadiumWilds.loadEntityModel(entity)
  end)
  if ok then
    -- Mark entity as using stadium model
    entity.useStadiumModel = true
  end
end

-- Hook into entity removal from overworld_wild_spawns
-- This should be called when a wild Pokemon entity is removed
function StadiumWilds.onEntityRemoved(entity)
  if not entity then return end
  StadiumWilds.clearEntity(entity)
end

-- Get the species dex number from an entity
function StadiumWilds.getEntitySpeciesDex(entity)
  if not entity then return nil end
  
  local species = entity.species
  if not species then return nil end
  
  -- Clean up the species name (remove leading and trailing spaces)
  if type(species) == "string" then
    species = species:gsub("^%s+", ""):gsub("%s+$", "")
    print("StadiumWilds: Cleaned species name:", species)
  end
  
  -- If it's already a number, return it
  local num = tonumber(species)
  if num and num >= 1 and num <= 151 then
    return num
  end
  
  -- Try to get from game data
  local mod = V.mod
  local game = mod.world and mod.world.game
  if game and game.data and game.data.pokemon then
    local mon = game.data.pokemon[species]
    if mon and mon.number then
      local dexNum = tonumber(mon.number)
      if dexNum and dexNum >= 1 and dexNum <= 151 then
        return dexNum
      end
    end
    
    -- Try iterating through all pokemon to find by name
    for id, def in pairs(game.data.pokemon) do
      if def and def.name and def.name:upper() == tostring(species):upper() then
        local dexNum = tonumber(def.number)
        if dexNum and dexNum >= 1 and dexNum <= 151 then
          return dexNum
        end
      end
      if tostring(id):upper() == tostring(species):upper() then
        local dexNum = tonumber(def.number)
        if dexNum and dexNum >= 1 and dexNum <= 151 then
          return dexNum
        end
      end
    end
  end
  
  return nil
end

-- Load a stadium model for a specific entity
function StadiumWilds.loadEntityModel(entity)
  if not entity or not StadiumWilds.enabled() then 
    print("StadiumWilds: loadEntityModel failed - feature disabled or no entity")
    return false 
  end
  
  local entityId = entity.id or entity.spawnId
  if not entityId then 
    print("StadiumWilds: loadEntityModel failed - no entity ID")
    return false 
  end
  
  -- Debug: show raw species name and its length
  print("StadiumWilds: Raw species name:", tostring(entity.species), "length:", #tostring(entity.species))
  
  local dex = StadiumWilds.getEntitySpeciesDex(entity)
  if not dex then 
    print("StadiumWilds: loadEntityModel failed - no dex for species:", entity.species)
    return false 
  end
  
  -- Check if already loaded
  if entityRigs[entityId] then 
    print("StadiumWilds: Model already loaded for entity:", entityId, "dex:", dex)
    return true 
  end
  
  -- Check cache
  local cacheKey = tostring(dex)
  if rigCache[cacheKey] then
    entityRigs[entityId] = rigCache[cacheKey]
    entityAnimStates[entityId] = { anim = 1, time = 0 }
    print("StadiumWilds: Using cached model for dex:", dex)
    return true
  end
  
  -- Load the Stadium model
  print("StadiumWilds: Loading model for dex:", dex)
  local model = StadiumPack.load(dex)
  if not model then
    print("StadiumWilds: Failed to load model for dex:", dex)
    return false
  end
  
  if model.staticPose then
    print("StadiumWilds: Model has static pose, declining dex:", dex)
    return false
  end
  
  -- Create the rig
  local rig = StadiumRig.new(model)
  if not rig then
    print("StadiumWilds: Failed to create rig for dex:", dex)
    return false
  end
  
  -- Cache and set current
  rigCache[cacheKey] = rig
  entityRigs[entityId] = rig
  entityAnimStates[entityId] = { anim = 1, time = 0 }
  
  -- Start idle animation
  rig:pose(1, 0, true)
  rig:skin(0)
  
  print("StadiumWilds: Successfully loaded model for dex:", dex, "entity:", entityId)
  return true
end

-- Unload a model for a specific entity
function StadiumWilds.unloadEntityModel(entity)
  if not entity then return end
  
  local entityId = entity.id or entity.spawnId
  if not entityId then return end
  
  local rig = entityRigs[entityId]
  if rig then
    -- Don't release the rig if it's cached (shared by species)
    entityRigs[entityId] = nil
    entityAnimStates[entityId] = nil
  end
end

-- ------- Rendering

-- Update animation state for an entity
function StadiumWilds.updateEntity(entity, dt)
  if not entity then return end
  
  local entityId = entity.id or entity.spawnId
  if not entityId then return end
  
  local rig = entityRigs[entityId]
  local animState = entityAnimStates[entityId]
  if not rig or not animState then return end
  
  animState.time = animState.time + dt
  rig:pose(animState.anim, animState.time * 30, true)  -- 30 FPS
  rig:anchor(0.75, dt)
  rig:textures(nil)
end

-- Draw a wild Pokemon entity
function StadiumWilds.drawEntity(entity)
  if not entity then return false end
  
  local entityId = entity.id or entity.spawnId
  if not entityId then return false end
  
  local rig = entityRigs[entityId]
  if not rig then return false end
  
  local x = entity.px or 0
  local y = entity.py or 0
  
  -- Calculate the model matrix
  local m = Mat4.translate(x, 0, y)
  
  -- Check if we're in free-roam mode (1st or 3rd person)
  local FirstPerson = V.require("FirstPerson")
  local b = FirstPerson.cardBlend()
  
  -- Determine facing direction
  local facing = entity.facing or "down"
  local yaw = 0
  if facing == "up" then yaw = math.pi
  elseif facing == "left" then yaw = -math.pi / 2
  elseif facing == "right" then yaw = math.pi / 2
  end
  
  -- Apply scale
  m = Mat4.scale(m, WILDS_SCALE, WILDS_SCALE, WILDS_SCALE)
  
  -- Apply rotation based on camera blend in free-roam
  if b > 0 then
    local yawOffset = yaw * b
    m = Mat4.rotateY(m, yawOffset)
  else
    m = Mat4.rotateY(m, yaw)
  end
  
  -- Skin and draw
  rig:skin(yaw)
  rig:draw(m)
  
  return true
end

-- Check if an entity has a stadium model loaded
function StadiumWilds.hasModel(entity)
  if not entity then return false end
  
  local entityId = entity.id or entity.spawnId
  if not entityId then return false end
  
  return entityRigs[entityId] ~= nil
end

-- ------- Cleanup

-- Clear all cached rigs
function StadiumWilds.clearCache()
  for cacheKey, rig in pairs(rigCache) do
    if rig then
      pcall(function() rig:release() end)
    end
  end
  rigCache = {}
  entityRigs = {}
  entityAnimStates = {}
end

-- Clear entity-specific data (called when entity is removed)
function StadiumWilds.clearEntity(entity)
  if not entity then return end
  StadiumWilds.unloadEntityModel(entity)
end

return StadiumWilds