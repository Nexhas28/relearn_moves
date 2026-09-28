-- relearn_moves FireRed (Gen 3) headless test: run from the engine checkout with
-- POKEPORT_DATA_DIR=tests/fixture_data luajit mods/relearn_moves/tests/relearn_moves_gen3_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.modkit")
local Data = require("src.core.Data")
Data:load()

local modPath = "mods/relearn_moves"
local testPath = tostring((arg and arg[0]) or ""):gsub("\\", "/")
local fromTest = testPath:match("^(.*)/tests/relearn_moves_gen3_test%.lua$")
if fromTest and fromTest ~= "" then modPath = fromTest end

local PM = require("src.ui.game3.party_menu")
local Relearner = require("src.ui.game3.move_relearner")
local MoveLearn = require("src.core.game3.move_learn")
local Pokemon = require("src.core.game3.pokemon")
local RomText = require("src.core.game3.rom_text")
local Stack = require("src.ui.game3.stack")

-- The FireRed party popup draws through love; headless, stand in a draw that
-- records what the vanilla popup would see: its action ids and the label the
-- sCursorOptions lookup returns for the borrowed row.
local drawn
PM.draw = function()
  drawn = { actions = {}, label = RomText.at("sCursorOptions", 14) }
  for i, act in ipairs(PM.ACTIONS) do drawn.actions[i] = act end
end
local romAt = RomText.at
RomText.at = function(name, i, ...)
  if name == "sCursorOptions" then return "ROM" .. tostring(i) end
  return romAt(name, i, ...)
end
local vanillaIsHm = Pokemon.isHmMove

-- No ROM: stand in FireRed's species data.  The level-up list is the native
-- relearnableMoves (stubbed before the mod wraps it); species 1 evolves from
-- base species 172 and 172 carries the egg moves, as gEggMoves does.
local relearnable = { 33, 45 }
MoveLearn.relearnableMoves = function()
  local out = {}
  for i, id in ipairs(relearnable) do out[i] = id end
  return out
end
local eggTable = { [172] = { 186, 33, 227 } }
Pokemon.eggMoves = function(species) return eggTable[species] end
Pokemon.speciesOf = function(m) return m.species end
Pokemon.isEgg = function(m) return m.isEgg == true end
Pokemon.moveIdAt = function(m, slot) return m.moves and m.moves[slot] end
local Breeding = require("src.core.game3.breeding")
Breeding.eggSpecies = function(species) return species == 1 and 172 or species end

local run = T.sdk.loadMod(modPath, { data = Data, generation = 3 })
T.eq(run.mod and run.mod.state, "loaded", "runs on FireRed")
T.eq(#run.errors, 0, "loads clean (" .. tostring(run.errors[1]) .. ")")
local ex = run.loader.exports.relearn_moves
T.neq(ex and ex.injectGen3Actions, nil, "Gen 3 exports reachable")

-- ------------------------------------------------------ injectGen3Actions

local function list(...) return { ... } end
T.eq(table.concat(ex.injectGen3Actions(list("SUMMARY", "SWITCH", "ITEM", "CANCEL")), ","),
     "SUMMARY,SWITCH,ITEM,RELEARN,CANCEL", "RELEARN goes before CANCEL")
T.eq(table.concat(ex.injectGen3Actions(list("SUMMARY", "CUT", "SURF", "SWITCH", "ITEM", "CANCEL")), ","),
     "SUMMARY,CUT,SURF,SWITCH,ITEM,RELEARN,CANCEL", "field moves keep their rows")
T.eq(table.concat(ex.injectGen3Actions(list("SUMMARY", "SWITCH", "ITEM", "RELEARN", "CANCEL")), ","),
     "SUMMARY,SWITCH,ITEM,RELEARN,CANCEL", "never injected twice")
T.eq(table.concat(ex.injectGen3Actions(list("SHIFT", "SUMMARY", "CANCEL")), ","),
     "SHIFT,SUMMARY,CANCEL", "battle list untouched")
T.eq(table.concat(ex.injectGen3Actions(list("SUMMARY", "CANCEL")), ","),
     "SUMMARY,CANCEL", "double-battle list untouched")
T.eq(table.concat(ex.injectGen3Actions(list("ENTER", "SUMMARY", "CANCEL")), ","),
     "ENTER,SUMMARY,CANCEL", "choose-mons list untouched")
T.eq(table.concat(ex.injectGen3Actions(list("SUMMARY", "SWITCH", "CANCEL"), { isEgg = true }), ","),
     "SUMMARY,SWITCH,CANCEL", "eggs get no RELEARN")

-- ------------------------------------------------------ party menu flow

local pressed
local input = { wasPressed = function(_, key) return key == pressed end }
local function press(key)
  pressed = key
  PM.handleInput(input)
  pressed = nil
end

local shown
Relearner.show = function(mon, opts) shown = { mon = mon, opts = opts } end
local reloaded = 0
PM.reloadSprites = function() reloaded = reloaded + 1 end

local mon = { species = 1, level = 20, moves = { 33, 45, 22, 73 } }
local function openParty(battle)
  Stack.clear()
  PM.open = true
  PM._party = { mon }
  PM._session = { party = PM._party }
  PM._battle = battle
  PM._oam = nil
  PM._pokedude = nil
  PM._hpAnim = nil
  PM.cursor = 1
  PM.mode = "list"
  PM._previousMode = "list"
end

openParty(false)
press("a")
T.eq(PM.mode, "action", "A on a mon opens the action popup")
T.eq(PM.ACTIONS[#PM.ACTIONS - 1], "RELEARN", "field popup lists RELEARN before CANCEL")
T.eq(PM.ACTIONS[#PM.ACTIONS], "CANCEL", "CANCEL stays last")

PM.draw()
T.neq(drawn, nil, "wrapped draw reaches the vanilla draw")
local drawnIds = table.concat(drawn.actions, ",")
T.eq(drawnIds:find("RELEARN", 1, true), nil, "vanilla draw never sees the unknown RELEARN id")
T.neq(drawnIds:find("STORE", 1, true), nil, "RELEARN borrows the STORE row while drawing")
T.eq(drawn.label, "RELEARN", "borrowed row reads RELEARN")
T.eq(RomText.at("sCursorOptions", 14), "ROM14", "RomText.at restored after draw")
T.eq(PM.ACTIONS[#PM.ACTIONS - 1], "RELEARN", "action list restored after draw")

PM.actionCursor = #PM.ACTIONS - 1
press("a")
T.neq(shown, nil, "RELEARN opens FireRed's Move Relearner")
T.eq(shown and shown.mon, mon, "relearner gets the selected mon")
T.eq(shown and shown.opts.session, PM._session, "relearner gets the party session")
T.eq(PM.mode, "list", "party menu waits in list mode underneath")
local during = MoveLearn.relearnableMoves(mon)
T.eq(table.concat(during, ","), "33,45,186,227",
     "RELEARN session lists egg moves after level-up moves, deduped")
T.eq(table.concat(MoveLearn.relearnableMoves({ species = 1, level = 5, moves = {} }), ","),
     "33,45", "other mons (e.g. the Two Island tutor) keep the vanilla list")
shown.opts.onDone(true)
T.eq(reloaded, 1, "party icons come back after the relearner closes")
T.eq(table.concat(MoveLearn.relearnableMoves(mon), ","), "33,45",
     "egg moves drop out once the RELEARN session ends")
T.eq(table.concat(ex.gen3.appendEggMoves({ species = 1, moves = { 186 } }, {}), ","),
     "33,227", "known egg moves are skipped")
T.eq(#ex.gen3.appendEggMoves({ species = 1, isEgg = true, moves = {} }, {}), 0,
     "an egg gets no egg moves")
T.eq(#ex.gen3.appendEggMoves({ species = 50, moves = {} }, {}), 0,
     "a line with no egg moves adds nothing")

-- egg moves alone keep RELEARN usable
shown = nil
relearnable = {}
openParty(false)
press("a")
PM.actionCursor = #PM.ACTIONS - 1
press("a")
T.neq(shown, nil, "a mon with only egg moves still opens the relearner")
shown.opts.onDone(false)

-- nothing to relearn: a party message, no relearner
shown = nil
relearnable = {}
mon.species = 50
openParty(false)
press("a")
PM.actionCursor = #PM.ACTIONS - 1
press("a")
T.eq(shown, nil, "empty list does not open the relearner")
T.eq(PM.mode, "message", "empty list shows a message")
T.eq(PM._messageText, "No moves to relearn.", "empty-list message text")
PM.dismissMessage()
T.eq(PM.mode, "list", "message dismisses back to the party list")

-- CANCEL and B still behave like vanilla
mon.species = 1
relearnable = { 33 }
openParty(false)
press("a")
PM.actionCursor = #PM.ACTIONS
press("a")
T.eq(PM.mode, "list", "CANCEL closes the popup")
T.eq(shown, nil, "CANCEL does not open the relearner")

-- a battle-flagged party never gains RELEARN
openParty(true)
press("a")
local hasRelearn = false
for _, act in ipairs(PM.ACTIONS) do if act == "RELEARN" then hasRelearn = true end end
T.eq(hasRelearn, false, "battle party menu has no RELEARN")

-- ------------------------------------------------------ HM parity

T.eq(ex.gen3.vanillaIsHmMove, vanillaIsHm, "vanilla HM gate kept for reference")
T.eq(vanillaIsHm(15), true, "CUT is an HM in vanilla FireRed")
T.eq(Pokemon.isHmMove(15), false, "CUT can be replaced with the mod on")
local hmMon = { species = 1, level = 20, moves = { 15, 33, 45, 22 }, pp = {}, maxPp = {} }
T.eq(Pokemon.replaceMove(hmMon, 1, 73), 15, "replaceMove forgets an HM slot")
T.eq(hmMon.moves[1], 73, "the new move takes the HM's slot")

-- ------------------------------------------------------ hot reload

local wrappedInput = PM.handleInput
local reload = T.sdk.loadMod(modPath, { data = Data, generation = 3 })
T.eq(#reload.errors, 0, "reload is clean")
openParty(false)
relearnable = { 33 }
press("a")
local count = 0
for _, act in ipairs(PM.ACTIONS) do if act == "RELEARN" then count = count + 1 end end
T.eq(count, 1, "a reload does not stack wrappers")
T.neq(PM.handleInput, wrappedInput, "reload installs a fresh wrapper")

T.finish("relearn_moves gen3")
