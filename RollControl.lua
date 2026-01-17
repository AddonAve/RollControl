--[[
Copyright (c) 2025, Addon Ave
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
* Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.
* Neither the name of [RollControl] nor the names of its contributors
may be used to endorse or promote products derived from this software
without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL [Addon Ave] BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
]]

_addon.name = 'RollControl'
_addon.version = '1.0.0'
_addon.author = 'Addon Ave'
_addon.commands = {'rollcontrol','rc'}

require('logger')
require('luau')
chat = require('chat')
chars = require('chat.chars')
packets = require('packets')
texts = require('texts')
res = require('resources')

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

defaults = {}
defaults.autostop = true   		-- Stop Double-Up on Lucky roll unless you confirm
defaults.bust = 1      			-- Show Bust chance info
defaults.crooked = true			-- Crooked Cards 
defaults.effected = 1      		-- Show number of party members hit
defaults.fold = 1      			-- Requires Bust or multiple rolls
defaults.luckinfo = true   		-- Show Lucky or Unlucky info line
defaults.engaged = false  		-- Only roll when engaged
defaults.holdtp = false			-- Prevents rolls from being used while your TP is at least 1000
defaults.Roll_ind_1 = 8     	-- Chaos Roll
defaults.Roll_ind_2 = 12		-- Samurai Roll
defaults.remote_roll_plus = 7   -- COR roll+ potency (not self): 0|3|5|6|7|8
defaults.showdisplay = true   	-- Show small UI text line
defaults.displayx = 16
defaults.displayy = 712

settings = config.load(defaults)

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

zonedelay = 6
stealthy = ''
was_stealthy = ''
autoroll = false
lastRoll = 0
lastRollCrooked = false
midRoll = false
crookedPending = false
crookedRollActive = {} 
gearTable = {}
partyColor = {}
buffId = S{}
rollInfo = {}
rollIndex = {}
isLucky = false
rollPlusBonus = false
gearBonus = false
jobBonus = false
reportedOnce = false
ranMultiple = false
player = nil
displayBox = nil
rollPlusStepCache = {}
lastJobBonusAnnounce = {}

local remoteRollPlus = 0
local was_dead = false

--------------------------------------------------------------------------------
-- Job Detection
--------------------------------------------------------------------------------

local jobIdMap = {
war = 1,
mnk = 2,
whm = 3,
blm = 4,
rdm = 5,
thf = 6,
pld = 7,
drk = 8,
bst = 9,
brd = 10,
rng = 11,
sam = 12,
nin = 13,
drg = 14,
smn = 15,
blu = 16,
cor = 17,
pup = 18,
dnc = 19,
sch = 20,
geo = 21,
run = 22,
}

--------------------------------------------------------------------------------
-- Packet-based Party Job Tracker (main job only)
--------------------------------------------------------------------------------

partyJobs = {}
local job_debug_once = false

local function store_party_job(mob_id, job)
if not mob_id or not job then
return
end

--------------------------------------------------------------------------------
-- If packet gave us a string, map it to ID
--------------------------------------------------------------------------------

if type(job) == 'string' then
local lowered = job:lower()
for id, data in pairs(res.jobs) do
if (data.short   and data.short:lower()   == lowered)
or (data.english and data.english:lower() == lowered)
then
job = id
break
end
end
end

if type(job) ~= 'number' then
return
end
if job < 1 or job > 22 then
return
end

partyJobs[mob_id] = job
end

windower.register_event('incoming chunk', function(id, data)
if id ~= 0x0DD and id ~= 0x0DF and id ~= 0x044 then
return
end

local p = packets.parse('incoming', data)
if not p then
return
end
-- 0x0DD / 0x0DF: single actor update
if id == 0x0DD or id == 0x0DF then
local mob_id = p.ID or p['ID'] or p['Mob ID']
local job = p['Main job'] or p['Main Job'] or p['Job'] or p['Main Job ID']

store_party_job(mob_id, job)

-- Party list
elseif id == 0x044 then
for i = 0, 17 do
local memberId = p['ID ' .. i]
local job = p['Job ' .. i]
store_party_job(memberId, job)
end
end
end)

local function member_has_job(member, job_key)
-- Member must be a valid party entry with a mob and mob.id
if type(member) ~= 'table' or not member.mob or not member.mob.id then
return false
end

if not job_key then
return false
end
job_key = job_key:lower()

-- Lookup the wanted job ID
local wantedId = jobIdMap[job_key]
if not wantedId then
return false
end

-- Mob ID in party
local mobId = member.mob.id

-- Check packet-tracked job ID
local trackedJob = partyJobs[mobId]

if trackedJob and trackedJob == wantedId then
return true
end

return false
end

-- Check if any party member has this main job
local function party_has_job(job_key)
if not job_key then
return false
end
job_key = job_key:lower()

local party = windower.ffxi.get_party()
if not party then
return false
end

for key, member in pairs(party) do
-- Only process actual member tables
if type(member) == 'table' and member.mob and member.mob.id then
if member_has_job(member, job_key) then
return true
end
end
end

return false
end

--------------------------------------------------------------------------------
-- Gear Helpers
--------------------------------------------------------------------------------

local function getGear(slot)
local equip = windower.ffxi.get_items()['equipment']
local bag = equip[slot..'_bag']
local index = equip[slot]
if bag and index and windower.ffxi.get_items(bag)[index] then
return windower.ffxi.get_items(bag)[index].id
end
return 0
end

--------------------------------------------------------------------------------
-- Load-time Initialization
--------------------------------------------------------------------------------

windower.register_event('load', function()
-- Equipment tracking
gearTable = {
[0]  = getGear('main'),
[1]  = getGear('sub'),
[2]  = getGear('range'),
[3]  = getGear('ammo'),
[4]  = getGear('head'),
[9]  = getGear('neck'),
[11] = getGear('left_ear'),
[12] = getGear('right_ear'),
[5]  = getGear('body'),
[6]  = getGear('hands'),
[13] = getGear('left_ring'),
[14] = getGear('right_ring'),
[15] = getGear('back'),
[10] = getGear('waist'),
[7]  = getGear('legs'),
[8]  = getGear('feet'),
}

buffId = S{309} + S(res.buffs:english(string.endswith-{' Roll'})):map(table.get-{'id'})

-- 0x1E = Normal Variant, 0x1F = Brighter Variant
partyColor = {
p0 = string.char(0x1E, 247), -- Teal
p1 = string.char(0x1E, 204), -- Yellow
p2 = string.char(0x1E, 156), -- Green
p3 = string.char(0x1E, 238), -- Purple
p4 = string.char(0x1E, 5),   -- Red
p5 = string.char(0x1E, 6),   -- Blue
}

rollIndex = {
'Fighter\'s Roll','Monk\'s Roll','Healer\'s Roll','Wizard\'s Roll','Warlock\'s Roll','Rogue\'s Roll','Gallant\'s Roll','Chaos Roll',
'Beast Roll','Choral Roll','Hunter\'s Roll','Samurai Roll','Ninja Roll','Drachen Roll','Evoker\'s Roll','Magus\'s Roll',
'Corsair\'s Roll','Puppet Roll','Dancer\'s Roll','Scholar\'s Roll','Bolter\'s Roll','Caster\'s Roll','Courser\'s Roll',
'Blitzer\'s Roll','Tactician\'s Roll','Allies\' Roll','Miser\'s Roll','Companion\'s Roll','Avenger\'s Roll','Naturalist\'s Roll','Runeist\'s Roll'
}

-- Roll Total, Bust Effect, Effect, Lucky, Unlucky, Roll +1, Job Bonus, {Equipment Slot, Bonus Equipment, and Effect}
local rollTable = {
['Allies\'']      = {2,3,20,5,7,9,11,13,15,1,25, '-5', '% Skillchain Damage', 3, 10, 1, {nil,0}, {6, 11120, 27084, 27085, 23235, 23570, 5}},
['Avenger\'s']    = {3,4,5,14,6,7,8,2,9,10,16, '-4', '% Counter Rate', 4, 8, 1, {nil,0}},
['Beast']         = {64,80,96,256,112,128,160,32,176,192,320, '0', '% Pet Attack Bonus', 4, 8, 32, {'bst',100}, {nil,0}},
['Blitzer\'s']    = {2,3,4,11,5,6,7,8,1,19,12, '-3', '% Delay reduction', 4, 9, 1, {nil,0}, {4, 11080, 26772, 26773, 23101, 23436, 5}},
['Bolter\'s']     = {6,6,16,8,8,10,10,12,4,14,20, '0', '% Movement Speed', 3, 9, 4, {nil,0}},
['Caster\'s']     = {6,15,7,8,9,10,5,11,12,13,20, '-10', '% Fast Cast', 2, 7, 3, {nil,0}, {7, 11140, 27269, 27269, 10}},
['Chaos']         = {64,80,96,256,112,128,160,32,176,192,320, '-9.76', '% Attack / Ranged Attack', 4, 8, 32, {'drk',100}, {nil,0}},
['Choral']        = {-8,-42,-11,-15,-19,-4,-23,-27,-31,-35,-50, '+25', '% Spell Interruption Rate', 2, 6, 4, {'brd',-25}, {nil,0}},
['Companion\'s']  = {{20,4},{50,20},{20,6},{20,8},{30,10},{30,12},{30,14},{40,16},{40,18},{10,3},{70,30}, '0', ' Pet: Regain/Regen', 2, 10, {5,2}, {nil,0}},
['Corsair\'s']    = {10,11,11,12,20,13,15,16,8,17,24, '-6', '% Experience Bonus', 5, 9, 2, {'cor',5}, {nil,0}},
['Courser\'s']    = {2,3,11,4,5,6,7,8,1,10,12, '-3', '% Snapshot', 3, 9, 1, {nil,0}, {8, 11160, 27443, 27444, 10746, 23704, 3}},
['Dancer\'s']     = {3,4,12,5,6,7,1,8,9,10,16, '-4', ' Regen', 3, 7, 2, {'dnc',4}, {nil,0}},
['Drachen']       = {10,13,15,40,18,20,25,5,28,30,50, '0', ' Pet Accuracy Bonus', 4, 8, 5, {'drg',15}, {nil,0}},
['Evoker\'s']     = {1,1,1,1,3,2,2,2,1,3,4, '-1', ' Refresh', 5, 9, 1, {'smn',1}, {nil,0}},
['Fighter\'s']    = {1,2,3,4,10,5,6,6,1,7,15, '0', '% Double Attack', 5, 9, 1, {'war',5}, {nil,0}},
['Gallant\'s']    = {48,60,200,72,88,104,32,120,140,160,240, '-11.72', '% Defense Bonus', 3, 7, 24, {'pld',120}, {nil,0}},
['Healer\'s']     = {3,4,12,5,6,7,1,8,9,10,16, '-4', '% Cure Potency Received', 3, 7, 1, {'whm',4}, {nil,0}},
['Hunter\'s']     = {10,13,15,40,18,20,25,5,27,30,50, '-15', ' Accuracy / Ranged Accuracy', 4, 8, 5, {'rng',15}, {nil,0}},
['Magus\'s']      = {5,20,6,8,9,3,10,13,14,15,25, '-8', ' Magic Defense Bonus', 2, 6, 2, {'blu',8}, {nil,0}},
['Miser\'s']      = {30,50,70,90,200,110,20,130,150,170,250, '0', ' Save TP', 5, 7, 15, {nil,0}},
['Monk\'s']       = {8,10,32,12,14,15,4,20,22,24,40, '-10', ' Subtle Blow', 3, 7, 4, {'mnk',10}, {nil,0}},
['Naturalist\'s'] = {6,7,15,8,9,10,5,11,12,13,20, '-5', '% Enhancing Magic Duration', 3, 7, 1, {'geo',5}, {nil,0}},
['Ninja']         = {10,13,15,40,18,20,25,5,28,30,50, '-15', ' Evasion Bonus', 4, 8, 5, {'nin',15}, {nil,0}},
['Puppet']        = {5,8,35,11,14,18,2,22,26,30,40, '-12', ' Pet Magic Attack Bonus', 3, 7, 3, {'pup',12}, {nil,0}},
['Rogue\'s']      = {1,2,3,4,10,5,6,7,1,8,14, '-5', '% Critical Hit Rate', 5, 9, 1, {'thf',5}, {nil,0}},
['Runeist\'s']    = {10,13,15,40,18,20,25,5,28,30,50, '-15', ' Magic Evasion', 4, 8, 5, {'run',15}, {nil,0}},
['Samurai']       = {8,32,10,12,14,4,16,20,22,24,40, '-10', ' Store TP Bonus', 2, 6, 4, {'sam',10}, {nil,0}},
['Scholar\'s']    = {2,10,3,4,4,1,5,6,7,7,12, '-3', '% Conserve MP', 2, 6, 1, {'sch',3}, {nil,0}},
['Tactician\'s']  = {10,10,10,10,30,10,10,0,20,20,40, '-10', ' TP/tick Regain', 5, 8, 2, {nil,0}, {5, 11100, 26930, 26931, 23168, 23503, 10}},
['Warlock\'s']    = {10,13,15,40,18,20,25,5,28,30,50, '-15', ' Magic Accuracy Bonus', 4, 8, 5, {'rdm',15}, {nil,0}},
['Wizard\'s']     = {4,6,8,10,25,12,14,17,2,20,30, '-10', ' Magic Attack Bonus', 5, 9, 2, {'blm',10}, {nil,0}},
}

rollInfo = {}
for key, val in pairs(rollTable) do
local ja = res.job_abilities:with('english', key .. ' Roll')
if ja then
rollInfo[ja.id] = {key, unpack(val)}
end
end

settings = config.load(defaults)
remoteRollPlus = settings.remote_roll_plus or 0 

if settings.showdisplay then
create_display(settings)
end
end)

-- Reset state for each load/login
local lastRollId = 0

windower.register_event('load', 'login', function()
isLucky = false
rollPlusBonus = false
gearBonus = false
jobBonus = false
lastRoll = 0
lastRollId = 0
player = windower.ffxi.get_player()
rollPlusStepCache = {}
end)

--------------------------------------------------------------------------------
-- Buff Helper
--------------------------------------------------------------------------------

function haveBuff(...)
local args   = S{...}:map(string.lower)
local player = windower.ffxi.get_player()
if player and player.buffs then
for _, bid in pairs(player.buffs) do
local buff = res.buffs[bid]
if buff and args:contains(buff.en:lower()) then
return true
end
end
end
return false
end

--------------------------------------------------------------------------------
-- Cities
--------------------------------------------------------------------------------

Cities = S{
"Ru'Lude Gardens","Upper Jeuno","Lower Jeuno","Port Jeuno","Port Windurst","Windurst Waters",
"Windurst Woods","Windurst Walls","Heavens Tower","Port San d'Oria","Northern San d'Oria",
"Southern San d'Oria","Chateau d'Oraguille","Port Bastok","Bastok Markets","Bastok Mines",
"Metalworks","Aht Urhgan Whitegate","The Colosseum","Tavanazian Safehold","Nashmau",
"Selbina","Mhaura","Rabao","Norg","Kazham","Eastern Adoulin","Western Adoulin",
"Celennia Memorial Library","Mog Garden","Leafallia"
}

--------------------------------------------------------------------------------
-- Display Box
--------------------------------------------------------------------------------

function create_display(settings)
if displayBox then
displayBox:destroy()
end

local windowersettings = windower.get_windower_settings()
local x, y

if settings.displayx and settings.displayy then
x = settings.displayx
y = settings.displayy
end

displayBox = texts.new()
displayBox:pos(x, y)
displayBox:font('Arial')
displayBox:size(10)
displayBox:bold(true)
displayBox:bg_alpha(0)
displayBox:right_justified(false)
displayBox:stroke_width(2)
displayBox:stroke_transparency(192)

update_displaybox()
end

function update_displaybox()
local player = windower.ffxi.get_player()
if not player then
return
end

if not settings.showdisplay or not (player.main_job == 'COR' or player.sub_job == 'COR') then
if displayBox then displayBox:hide() end
return
end

displayBox:clear()

-- Roll 1 + Roll 2	
displayBox:append("Roll 1: "..rollIndex[settings.Roll_ind_1].."   ")
if player.main_job == 'COR' and settings.Roll_ind_1 ~= settings.Roll_ind_2 then
displayBox:append("Roll 2: "..rollIndex[settings.Roll_ind_2].."   ")
end

-- Hold TP status
displayBox:append("Hold TP: " .. (settings.holdtp and "On" or "Off") .. "   ")

-- Rolls status
displayBox:append("Rolls: ")
if autoroll then
if haveBuff('Invisible') then
displayBox:append("Suspended: Invisible")
elseif haveBuff('Sneak') then
displayBox:append("Suspended: Sneak")
else
displayBox:append("On")
end
else
displayBox:append("Off")
end

if settings.engaged then
displayBox:append("  Engaged Mode")
end

displayBox:show()
end

-- Disable automatic rolling when dead
windower.register_event('prerender', function()
local p = windower.ffxi.get_player()
if not p or not p.vitals then return end

-- Detect death
if p.vitals.hp == 0 then
if autoroll and not was_dead then
autoroll = false
midRoll = false
crookedPending = false
lastRoll = 0
lastRollCrooked = false
isLucky = false

update_displaybox()
end
was_dead = true
return
end

-- Reset flag after raise
was_dead = false
end)

-- Hide or show display on zoning packets
windower.register_event('outgoing chunk', function(id, data)
if id == 0x00D and displayBox then
displayBox:hide()
end
end)

windower.register_event('incoming chunk', function(id, data)
-- Display hide / show
if id == 0x00A and displayBox then
displayBox:show()
end

-- Gear tracking
if id == 0x050 then
local packet = packets.parse('incoming', data)
local slot   = windower.ffxi.get_items(packet['Inventory Bag'])[packet['Inventory Index']]
gearTable[packet['Equipment Slot']] = slot ~= nil and slot.id or 0
end
end)

--------------------------------------------------------------------------------
-- RollControl Logic
--------------------------------------------------------------------------------

function doRoll()
if Cities:contains(res.zones[windower.ffxi.get_info().zone].english) then
return
end
if not autoroll then
return
end
if haveBuff('amnesia') or haveBuff('impairment') or haveBuff('paralysis') then
midRoll = false
crookedPending = false
return
end
-- Sneak / Invisible suspend
if haveBuff('Sneak') or haveBuff('Invisible') then
stealthy = true
else
stealthy = false
end
if stealthy ~= was_stealthy then
update_displaybox()
end
was_stealthy = stealthy
if stealthy then
return
end

-- Get player once and reuse
local player = windower.ffxi.get_player()
if not player then
return
end

-- Only run for COR main or sub
if not (player.main_job == 'COR' or player.sub_job == 'COR') then
return
end

-- Idle or Engaged
local status = res.statuses[player.status].english
if not (((status == 'Idle') and not settings.engaged) or status == 'Engaged') then
return
end

-- Hold TP: stop rolls if toggle is On and TP >= 1000
if settings.holdtp and player.vitals and player.vitals.tp and player.vitals.tp >= 1000 then
return
end

local abil_recasts = windower.ffxi.get_ability_recasts()
local available_ja = S(windower.ffxi.get_abilities().job_abilities)

-- Fold off Bust if possible
if player.main_job == 'COR'
and haveBuff('Bust')
and available_ja:contains(178)
and abil_recasts[198]
and abil_recasts[198] == 0
then
windower.send_command('input /ja "Fold" <me>')
return
end

-- Phantom Roll global recast
if abil_recasts[193] and abil_recasts[193] > 0 then
return
end

-- Reset last roll if you lost both rolls
if not haveBuff(rollIndex[settings.Roll_ind_1]) and not haveBuff(rollIndex[settings.Roll_ind_2]) then
lastRoll = 0
lastRollCrooked = false
end

if not haveBuff(rollIndex[settings.Roll_ind_1]) then
-- Only use Crooked Cards if the toggle is On
if settings.crooked
and player.main_job == 'COR'
and player.main_job_level > 94
and abil_recasts[96] == 0
then
lastRollCrooked = true
crookedPending  = true
windower.send_command('input /ja "Crooked Cards" <me>;wait 2;input /ja "'..rollIndex[settings.Roll_ind_1]..'" <me>')
else
lastRollCrooked = false
windower.send_command('input /ja "'..rollIndex[settings.Roll_ind_1]..'" <me>')
end
elseif player.main_job == 'COR'
and not haveBuff(rollIndex[settings.Roll_ind_2]) then
windower.send_command('input /ja "'..rollIndex[settings.Roll_ind_2]..'" <me>')
end
end

-- Loop every 4 seconds
doRoll:loop(4)

--------------------------------------------------------------------------------
-- Text Filters
--------------------------------------------------------------------------------

windower.register_event('incoming text', function(old, new, color)
-- Hide Battlemod roll lines
if old:match("Roll.* The total.*")
or old:match('.*Roll.*' .. string.char(0x81, 0xA8))
or (old:match('.*uses Double.* The total') and color ~= 123)
then
return true
end

-- Hide
if old:match('.* receives the effect of .* Roll.') then
return true
end

-- Hide your own command echo
if old:find(">> /ja ")
or old:find(">> /jobability ")
or old:find(">> /ma ")
or old:find(">> /magic ")
or old:find(">> /nin ")
or old:find(">> /pet ")
or old:find(">> /song ")
or old:find(">> /ws ")
or old:find(">> /weaponskill ") then
return true
end

-- Hide
if old:find("cannot perform that action on the selected sub%-target") then
return true
end

-- Hide the system message "A command error occurred."
if old:find("A command error occurred") then
return true
end

return new, color
end)

--------------------------------------------------------------------------------
-- Double-Up Stopper + Fold Logic
--------------------------------------------------------------------------------

windower.register_event('outgoing text', function(original, modified)
local cleaned = windower.convert_auto_trans(original)
modified = original

-- Track Crooked Cards usage (sets flag for the *next* roll)
if cleaned:match('/jobability \"?Crooked Cards') or cleaned:match('/ja \"?Crooked Cards') then
crookedPending = true
end

-- Stop Double-Up on Lucky unless confirmed
if cleaned:match('/jobability \"?Double.*Up') or cleaned:match('/ja \"?Double.*Up') then
if isLucky and settings.autostop and player and player.id == (player.id or 0) then
windower.add_to_chat(159, 'Attempting to Doubleup on a Lucky Roll: Re-double up to continue')
isLucky = false
modified = ""
end
end

-- Fold
if settings.fold == 1 and (cleaned:match('/jobability \"?Fold') or cleaned:match('/ja \"?Fold')) then
local canBust = false
local cor_buffs = S(player and player.buffs or {}) * buffId
canBust = cor_buffs:contains(res.buffs:with('name', 'Bust').id) or cor_buffs:length() > 1

if canBust or ranMultiple then
modified = cleaned
ranMultiple = false
else
windower.add_to_chat(159, 'No Bust: Fold again to continue')
ranMultiple = true
modified = ""
end
return modified
end

return modified
end)

--------------------------------------------------------------------------------
-- Display + Auto Double-Up Logic
--------------------------------------------------------------------------------

windower.register_event('action', function(act)
-- Only interested in Phantom Roll actions (category 6) that are in rollInfo
if act.category ~= 6 or not table.containskey(rollInfo, act.param) then
return
end

local rollID = act.param
local rollNum = act.targets[1].actions[1].param
local actor = act.actor_id

--------------------------------------------------------------------------------
-- Lucky and Bust Info
--------------------------------------------------------------------------------

local function player_in_targets(a)
if not player then
player = windower.ffxi.get_player()
end
if not player then
return false
end
for i = 1, #a.targets do
if a.targets[i].id == player.id then
return true
end
end
return false
end

if player_in_targets(act) then
local party = windower.ffxi.get_party()
local rollMembers = {}

for partyMem in pairs(party) do
for effectedTarget = 1, #act.targets do
if type(party[partyMem]) == 'table'
and party[partyMem].mob
and act.targets[effectedTarget].id == party[partyMem].mob.id
then
rollMembers[effectedTarget] = partyColor[partyMem] .. party[partyMem].name .. chat.controls.reset
end
end
end

local membersHit = table.concat(rollMembers, ', ')
local amountHit  = settings.effected == 1 and '[' .. #rollMembers .. '] ' or ''

-- Check if this roll is under Crooked Cards
local crookedApplied = false
if actor == (player and player.id or 0) then
if crookedPending or lastRollCrooked or haveBuff('Crooked Cards') then
crookedApplied = true
crookedPending = false
lastRollCrooked = false
crookedRollActive[rollID] = true
elseif crookedRollActive[rollID] then
crookedApplied = true
end
end

local rollBonus = RollEffect(rollID, rollNum + 1, crookedApplied)

local luckChat   = ''

isLucky = false
if rollNum == rollInfo[rollID][15] or rollNum == 11 then
isLucky = true
windower.add_to_chat(158, 'Lucky roll!')
luckChat = string.char(31,158).." (Lucky!)"
elseif rollNum == rollInfo[rollID][16] then
luckChat = string.char(31,167).." (Unlucky!)"
end

if rollNum == 12 and #rollMembers > 0 then
crookedRollActive[rollID] = nil
-- Value used for the Bust line
local val = rollInfo[rollID][rollNum+1]
local vnum = tonumber(val)

-- Crooked Cards: Bust penalty −20%
if crookedApplied and vnum then
vnum = vnum * 0.80
val  = vnum
end

-- If this is Choral Roll, force the number to be negative
if rollInfo[rollID][1] == "Choral" and vnum then
val = -math.abs(vnum)
end

windower.add_to_chat(
1,
string.char(31,167)..
amountHit..'Bust! '..chat.controls.reset..
chars.implies..' '..membersHit..' '..chars.implies..
' ('..val..rollInfo[rollID][14]..')'
)

else
-- Add "+" for positive bonuses, but leave negatives as is
local bonusText   = tostring(rollBonus)
local bonusPrefix = ''

-- If it doesn't start with "-", treat it as positive and add "+"
if not bonusText:match('^%-') then
bonusPrefix = '+'
end

windower.add_to_chat(
1,
amountHit..membersHit..chat.controls.reset..' '..chars.implies..' '..
rollInfo[rollID][1]..' Roll '..chars['circle' .. rollNum]..
luckChat..string.char(31,13)..' ('..bonusPrefix..bonusText..')'..
BustRate(rollNum, actor)..
ReportRollInfo(rollID, actor)
)
end
end

--------------------------------------------------------------------------------
-- Crooked Cards / Double-Up / Snake Eye Tracking
--------------------------------------------------------------------------------

-- Ignore Phantom Roll used by trusts
if rollID == 177 then
return
end

local player_now = windower.ffxi.get_player()
if not player_now then
return
end

if actor == player_now.id then
if act.targets[1].actions[1].message ~= 424 then
lastRollCrooked = false
end

if rollNum == rollInfo[rollID][15] or rollNum == 11 then
lastRoll = rollNum
midRoll  = false
crookedRollActive[rollID] = nil
return
end

if not autoroll then
return
end

if haveBuff('amnesia') or haveBuff('impairment') or haveBuff('paralysis') then
return
end

if player_now.main_job == 'COR' then
local abil_recasts = windower.ffxi.get_ability_recasts()
local available_ja = S(windower.ffxi.get_abilities().job_abilities)

-- Snake Eye: 10 or (Lucky -1) or specific threshold
local snakeReady   = abil_recasts[197] == 0
local doubleReady  = abil_recasts[195] == 0

if available_ja:contains(177) and snakeReady and doubleReady and rollNum == 10 then
midRoll = true
windower.send_command('wait 1.2;input /ja "Snake Eye" <me>;wait 4.4;input /ja "Double-Up" <me>')

elseif available_ja:contains(177) and snakeReady and doubleReady
and rollNum == (rollInfo[rollID][15] - 1) then
midRoll = true
windower.send_command('wait 1.2;input /ja "Snake Eye" <me>;wait 4.4;input /ja "Double-Up" <me>')

elseif available_ja:contains(177) and snakeReady and doubleReady
and lastRoll ~= 11
and rollNum > 6
and rollNum == rollInfo[rollID][16] then
midRoll = true
windower.send_command('wait 1.2;input /ja "Snake Eye" <me>;wait 4.4;input /ja "Double-Up" <me>')

-- Plain Double-Up (no Snake Eye): still require Double-Up recast ready
elseif doubleReady and not lastRollCrooked and rollNum < 9 then
midRoll = true
windower.send_command('wait 4.4;input /ja "Double-Up" <me>')

elseif doubleReady and (rollNum < 6 or lastRoll == 8) and not lastRollCrooked then
midRoll = true
windower.send_command('wait 4.4;input /ja "Double-Up" <me>')

else
midRoll = false
lastRoll = rollNum
end

elseif rollNum < 6 then
midRoll = true
windower.send_command('@wait 4.4;input /ja "Double-Up" <me>')
end
end
end)

--------------------------------------------------------------------------------
-- RollEffect / BustRate / ReportRollInfo
--------------------------------------------------------------------------------

function RollEffect(rollid, rollnum, crookedApplied)
if rollnum == 13 then
return
end

local rollName = rollInfo[rollid][1]
local rollVal = rollInfo[rollid][rollnum]

--------------------------------------------------------------------------------
-- Companion's Roll: Special Text
--------------------------------------------------------------------------------

if rollName == "Companion\'s" then
local hpVal = rollVal[1]
local tpVal = rollVal[2]
return "Pet:"..hpVal.." Regen".." +"..tpVal.." Regain"
end

--------------------------------------------------------------------------------
-- Roll+ from COR gear or remote_roll_plus (remember first-roll step)
--------------------------------------------------------------------------------

if rollVal ~= '?' then
local p = player or windower.ffxi.get_player()
local isLocalCOR = p and (p.main_job == 'COR' or p.sub_job == 'COR')
local step = 0

if isLocalCOR then
-- Use cached step if we already computed it for this roll ID
step = rollPlusStepCache[rollid]

if not step then

-- Item Name         ID      Roll+
-- Barataria Ring    28548   5
-- Comm. Knife       21579   6
-- Lanun Knife       21580   7
-- Merirosvo Ring    28547   3
-- Regal Necklace    26038   7
-- Rostam            21581   8

if gearTable[0] == 21581 then -- Rostam (+8)
step = 8
elseif gearTable[0] == 21580 -- Lanun Knife (+7)
or gearTable[9] == 26038 then -- Regal Necklace (+7)
step = 7
elseif gearTable[0] == 21579 then -- Comm. Knife (+6)
step = 6
elseif gearTable[13] == 28548 -- Barataria (+5)
or gearTable[14] == 28548 then
step = 5
elseif gearTable[13] == 28547 -- Merirosvo (+3)
or gearTable[14] == 28547 then
step = 3
else
step = 0
end

rollPlusStepCache[rollid] = step
end
else
-- Not on COR: use configured Roll+ item every time (no gear issues here)
step = remoteRollPlus or 0
end

-- Only apply if this roll actually uses a numeric step (Chaos/Beast/Gallant/etc.)
if step > 0 and type(rollInfo[rollid][17]) == 'number' then
rollVal = rollVal + (rollInfo[rollid][17] * step)
end
end

--------------------------------------------------------------------------------
-- Job Bonus
--------------------------------------------------------------------------------

local jobInfo = rollInfo[rollid][18]
if jobInfo and type(jobInfo) == 'table' then
local baseJob = jobInfo[1]
local bonusAmt = jobInfo[2]

if baseJob and type(bonusAmt) == 'number' then
-- Use override if present; otherwise use the job from rollInfo
local effectiveJob = forcedBonusJob or baseJob

if party_has_job(effectiveJob) then
rollVal = rollVal + bonusAmt

-- Announce job bonus applied
local now = os.time()
local last = lastJobBonusAnnounce[rollid] or 0

if now - last >= 60 then
lastJobBonusAnnounce[rollid] = now
local jobUpper = effectiveJob:upper()
windower.add_to_chat(17, string.format('[Roll Control] %s job bonus applied to %s Roll', jobUpper, rollInfo[rollid][1]))
end
end
end
end

--------------------------------------------------------------------------------
-- Empyrean +2 / 109 / 119 gear bonus
--------------------------------------------------------------------------------

local gearInfo = rollInfo[rollid][19]
if gearInfo ~= nil and type(gearInfo) == 'table' then
local gearSlot = gearInfo[1]
local gear1 = gearInfo[2]
local gear2 = gearInfo[3]
local gear3 = gearInfo[4]
local bonus = gearInfo[5] or 0

if bonus ~= 0 and gearSlot ~= nil then
local hasGear =
gearTable[gearSlot] == gear1 or
gearTable[gearSlot] == gear2 or
gearTable[gearSlot] == gear3

local bonusVal = hasGear and bonus or 0
rollVal = rollVal + bonusVal
end
end

--------------------------------------------------------------------------------
-- Crooked Cards bonus (+20% effect when applied to this roll)
--------------------------------------------------------------------------------

if crookedApplied and type(rollVal) == 'number' then
rollVal = rollVal * 1.20
end

--------------------------------------------------------------------------------
-- Special Conversions
--------------------------------------------------------------------------------

-- Bolter's: convert internal to % move speed
if rollName == "Bolter\'s" then
rollVal = '%.0f':format(100 * ((5 + rollVal) / 5 - 1))
end

-- Chaos/Gallant's/Beast: convert internal units to %
if rollName == "Beast" or rollName == "Chaos" or rollName == "Gallant\'s" then
rollVal = '%.2f':format(rollVal / 1024 * 100)
end

return rollVal .. rollInfo[rollid][14]
end

function BustRate(rollNum, rollActor)
if rollNum <= 5 or rollNum == 11 or rollActor ~= (player and player.id or 0) or settings.bust == 0 then
return ''
end
return '\7  [Chance to Bust]: ' .. '%.1f':format((rollNum-5)*16.67) .. '%'
end

function ReportRollInfo(rollID, rollActor)
if rollActor ~= (player and player.id or 0) or not settings.luckinfo then
return ''
elseif reportedOnce then
reportedOnce = false
return ''
else
reportedOnce = true
return '\7  '..rollInfo[rollID][1]..' Roll\'s Lucky #: ' ..
rollInfo[rollID][15]..' Unlucky #: '..rollInfo[rollID][16]
end
end

----------------------------------------------------
-- Resume rolls when debuff clears
----------------------------------------------------

local function is_roll_block_buff(buff_id)
local b = res.buffs[buff_id]
if not b or not b.en then return false end
local n = b.en:lower()
return (n == 'amnesia' or n == 'impairment' or n == 'paralysis')
end

windower.register_event('lose buff', function(buff_id)
if not autoroll then return end
if not is_roll_block_buff(buff_id) then return end

-- Debuff cleared: allow rolling again
midRoll = false
crookedPending = false
zonedelay = 1
update_displaybox()
doRoll()
end)

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

windower.register_event('addon command', function(...)
local cmd = {...}

local sub = cmd[1] and cmd[1]:lower()
if cmd[2] then cmd[2] = cmd[2]:lower() end

if sub == "on" then
zonedelay = 2
midRoll = false
crookedPending = false
isLucky = false

if not autoroll then
autoroll = true
windower.add_to_chat(7, 'Enabling Automatic Rolling')
end
update_displaybox()
return
end

if sub == "off" then
zonedelay = 2
if autoroll then
autoroll = false
windower.add_to_chat(7, 'Disabling Automatic Rolling')
end
update_displaybox()
return
end

-- Roll 1
if sub == "roll1" then
local which = "Roll 1"
local key = "Roll_ind_1"

if not cmd[2] then
windower.add_to_chat(7, which..": "..rollIndex[settings[key]])
return
end

local name = cmd[2]
local rollchange = false

local function set(idx)
settings[key] = idx
config.save(settings)
rollchange = true
end

if     name:startswith("fig")	then set(1)   -- Fighter's Roll
elseif name:startswith("mon")   then set(2)   -- Monk's Roll
elseif name:startswith("hea")   then set(3)   -- Healer's Roll
elseif name:startswith("wiz")   then set(4)   -- Wizard's Roll
elseif name:startswith("war")	then set(5)   -- Warlock's Roll
elseif name:startswith("rog")   then set(6)   -- Rogue's Roll
elseif name:startswith("gal") 	then set(7)   -- Gallant's Roll
elseif name:startswith("cha")   then set(8)   -- Chaos Roll
elseif name:startswith("bea")   then set(9)   -- Beast Roll
elseif name:startswith("cho")  	then set(10)  -- Choral Roll
elseif name:startswith("hun")   then set(11)  -- Hunter's Roll
elseif name:startswith("sam")   then set(12)  -- Samurai Roll
elseif name:startswith("nin")   then set(13)  -- Ninja Roll
elseif name:startswith("dra")   then set(14)  -- Drachen Roll
elseif name:startswith("evo")   then set(15)  -- Evoker's Roll
elseif name:startswith("mag")   then set(16)  -- Magus Roll
elseif name:startswith("cor")   then set(17)  -- Corsair's Roll
elseif name:startswith("pup")   then set(18)  -- Puppet Roll
elseif name:startswith("dan")   then set(19)  -- Dancer's Roll
elseif name:startswith("sch")   then set(20)  -- Scholar's Roll
elseif name:startswith("bol")   then set(21)  -- Bolter's Roll
elseif name:startswith("cas")   then set(22)  -- Caster's Roll
elseif name:startswith("cou")  	then set(23)  -- Courser's Roll
elseif name:startswith("bli")   then set(24)  -- Blitzer's Roll
elseif name:startswith("tac")   then set(25)  -- Tactician's Roll
elseif name:startswith("all")   then set(26)  -- Allies' Roll
elseif name:startswith("mis")   then set(27)  -- Miser's Roll
elseif name:startswith("com")   then set(28)  -- Companion's Roll
elseif name:startswith("ave")  	then set(29)  -- Avenger's Roll
elseif name:startswith("nat") 	then set(30)  -- Naturalist's Roll
elseif name:startswith("run")   then set(31)  -- Runeist's Roll
end

if rollchange then
windower.add_to_chat(7, 'Setting '..which..' to: '..rollIndex[settings[key]])
else
windower.add_to_chat(7, 'Invalid roll name, '..which..' remains: '..rollIndex[settings[key]])
end

update_displaybox()
return
end

-- Roll 2
if sub == "roll2" then
local which = "Roll 2"
local key = "Roll_ind_2"

if not cmd[2] then
windower.add_to_chat(7, which..": "..rollIndex[settings[key]])
return
end

local name = cmd[2]
local rollchange = false

local function set(idx)
settings[key] = idx
config.save(settings)
rollchange = true
end

if     name:startswith("fig")	then set(1)   -- Fighter's Roll
elseif name:startswith("mon")   then set(2)   -- Monk's Roll
elseif name:startswith("hea")   then set(3)   -- Healer's Roll
elseif name:startswith("wiz")   then set(4)   -- Wizard's Roll
elseif name:startswith("war")	then set(5)   -- Warlock's Roll
elseif name:startswith("rog")   then set(6)   -- Rogue's Roll
elseif name:startswith("gal") 	then set(7)   -- Gallant's Roll
elseif name:startswith("cha")   then set(8)   -- Chaos Roll
elseif name:startswith("bea")   then set(9)   -- Beast Roll
elseif name:startswith("cho")  	then set(10)  -- Choral Roll
elseif name:startswith("hun")   then set(11)  -- Hunter's Roll
elseif name:startswith("sam")   then set(12)  -- Samurai Roll
elseif name:startswith("nin")   then set(13)  -- Ninja Roll
elseif name:startswith("dra")   then set(14)  -- Drachen Roll
elseif name:startswith("evo")   then set(15)  -- Evoker's Roll
elseif name:startswith("mag")   then set(16)  -- Magus Roll
elseif name:startswith("cor")   then set(17)  -- Corsair's Roll
elseif name:startswith("pup")   then set(18)  -- Puppet Roll
elseif name:startswith("dan")   then set(19)  -- Dancer's Roll
elseif name:startswith("sch")   then set(20)  -- Scholar's Roll
elseif name:startswith("bol")   then set(21)  -- Bolter's Roll
elseif name:startswith("cas")   then set(22)  -- Caster's Roll
elseif name:startswith("cou")  	then set(23)  -- Courser's Roll
elseif name:startswith("bli")   then set(24)  -- Blitzer's Roll
elseif name:startswith("tac")   then set(25)  -- Tactician's Roll
elseif name:startswith("all")   then set(26)  -- Allies' Roll
elseif name:startswith("mis")   then set(27)  -- Miser's Roll
elseif name:startswith("com")   then set(28)  -- Companion's Roll
elseif name:startswith("ave")  	then set(29)  -- Avenger's Roll
elseif name:startswith("nat") 	then set(30)  -- Naturalist's Roll
elseif name:startswith("run")   then set(31)  -- Runeist's Roll
end

if rollchange then
windower.add_to_chat(7, 'Setting '..which..' to: '..rollIndex[settings[key]])
else
windower.add_to_chat(7, 'Invalid roll name, '..which..' remains: '..rollIndex[settings[key]])
end

update_displaybox()
return
end

-- Crooked Cards
if sub == "cc" then
if not cmd[2] then
windower.add_to_chat(7, 'Crooked Cards: '..(settings.crooked and 'On' or 'Off'))
return
end

if cmd[2] == "on" then
settings.crooked = true
windower.add_to_chat(7, 'Crooked Cards: On')
elseif cmd[2] == "off" then
settings.crooked = false
windower.add_to_chat(7, 'Crooked Cards: Off')
else
windower.add_to_chat(7, 'Not a recognized command (use on/off)')
end

config.save(settings)
return
end

-- Hold TP
if sub == "holdtp" then
if not cmd[2] then
settings.holdtp = not settings.holdtp
windower.add_to_chat(7,'Hold TP: ' .. (settings.holdtp and 'On' or 'Off'))
elseif cmd[2] == 'on' then
settings.holdtp = true
windower.add_to_chat(7, 'Hold TP: On')
elseif cmd[2] == 'off' then
settings.holdtp = false
windower.add_to_chat(7, 'Hold TP: Off')
else
windower.add_to_chat(7, 'Not a recognized command (use on/off)')
end

config.save(settings)
update_displaybox() -- Make the display refresh

return
end

-- Roll+ potency (for the COR in your party)
if sub == "rollplus" then
if not cmd[2] then
windower.add_to_chat(7, string.format('Roll+ potency: %d', remoteRollPlus or 0))
windower.add_to_chat(7, 'Valid Roll+ potency: 0|3|5|6|7|8')
return
end

local n = tonumber(cmd[2])
if not n then
return
end

-- Only allow the real Roll+ amounts
local valid = S{0,3,5,6,7,8}
if not valid:contains(n) then
windower.add_to_chat(7, 'Invalid Roll+ potency')
return
end

remoteRollPlus = n
settings.remote_roll_plus = n
config.save(settings)

if n == 0 then
windower.add_to_chat(7, 'Roll+ disabled')
else
windower.add_to_chat(7, string.format('Roll+ potency set to: %d', n))
end
return
end

-- Display
if sub == "display" then
if not cmd[2] then
settings.showdisplay = not settings.showdisplay
windower.add_to_chat(7, 'Display: '..(settings.showdisplay and 'On' or 'Off'))
elseif cmd[2] == 'on' or cmd[2] == 'show' then
settings.showdisplay = true
windower.add_to_chat(7, 'Display: On')
elseif cmd[2] == 'off' or cmd[2] == 'hide' then
settings.showdisplay = false
windower.add_to_chat(7, 'Display: Off')
else
windower.add_to_chat(7, 'Not a recognized command (use on/off)')
end

config.save(settings)
if settings.showdisplay then
create_display(settings)
elseif displayBox then
displayBox:hide()
end
update_displaybox()
return
end

if sub == "engaged" then
if not cmd[2] then
settings.engaged = not settings.engaged
windower.add_to_chat(7, 'Engaged Mode: '..(settings.engaged and 'On' or 'Off'))
elseif cmd[2] == 'on' or cmd[2] == 'true' then
settings.engaged = true
windower.add_to_chat(7, 'Engaged Mode: On')
elseif cmd[2] == 'off' or cmd[2] == 'false' then
settings.engaged = false
windower.add_to_chat(7, 'Engaged Mode: Off')
else
windower.add_to_chat(7, 'Not a recognized command (use on/off)')
end
config.save(settings)
update_displaybox()
return
end

if sub == "status" then
windower.add_to_chat(7,'[RollControl] Status:')
windower.add_to_chat(7, 'Crooked Cards: ' .. (settings.crooked and 'On' or 'Off'))
windower.add_to_chat(7, 'Roll+ potency (not self): ' .. (settings.remote_roll_plus or 0))
return
end

if sub == "help" then
windower.add_to_chat(208,'[RollControl] Commands:')
windower.add_to_chat(208,' //rc on|off - Enable/Disable')
windower.add_to_chat(208,' //rc roll1 [name] - Set Roll #1')
windower.add_to_chat(208,' //rc roll2 [name] - Set Roll #2')
windower.add_to_chat(208,' //rc cc on|off - Crooked Cards on/off')
windower.add_to_chat(208,' //rc holdtp on|off - Hold TP on/off')
windower.add_to_chat(208,' //rc rollplus 0|3|5|6|7|8 - Set the COR roll+ potency (not self)')
windower.add_to_chat(208,' //rc display on|off - Display on/off')
windower.add_to_chat(208,' //rc engaged on|off - Rolls only when engaged')
windower.add_to_chat(208,' //rc status - Show current status')
return
end
end)

--------------------------------------------------------------------------------
-- Reset on Job or Zone Change
--------------------------------------------------------------------------------

windower.register_event('job change', function()
zonedelay = 0
autoroll = false
lastRoll = 0
lastRollCrooked = false
midRoll = false
crookedPending = false
isLucky = false
rollPlusStepCache = {}
update_displaybox()
end)

windower.register_event('zone change', function()
zonedelay = 0
autoroll = false
lastRoll = 0
lastRollCrooked = false
midRoll = false
crookedPending = false
isLucky = false
rollPlusStepCache = {}
update_displaybox()
end)
