-- Run with: lua tests/backend_parity.lua <pfQuest source> <pfQuest-turtle source>
local core, turtle = assert(arg[1]), assert(arg[2])
table.getn = table.getn or function(t) return #t end
string.gfind = string.gfind or string.gmatch
strfind, strlower, strlen = string.find, string.lower, string.len
local function read(path) local f=assert(io.open(path));local s=f:read('*a');f:close();return s end
local function compile(s) return assert((loadstring or load)(s)) end
pfQuestCompat = { GetDifficultyColor=function() return {r=1,g=1,b=0} end }
pfQuest = {questlog={}}
pfQuest_history = {}
pfQuest_config = {showlowlevel='1',showhighlevel='0',questpinlevelrange='off'}
UnitLevel = function() return 60 end
pfDatabase = {staticRejectSet={}}
local skills = {[755]=225,[356]=225}
function pfDatabase:GetPlayerSkillCached(id) return skills[id] or false end
-- Load the actual lean data initializer and overwrites: must not require Lua rows.
dofile(core .. '/db/init.lua')
for _,db in ipairs({'items','units','objects','refloot','quests-itemreq','quests'}) do pfDB[db].data={};pfDB[db].enUS={} end
dofile(core .. '/overwrites.lua')
dofile(turtle .. '/overwrites.lua')
assert(pfDB.quests.preall[41286][3]==41285)
assert(pfDB.quests.preall[41290][3]==41289)
local source=read(core .. '/database.lua')
local start=assert(string.find(source,'function pfDatabase:MeetsQuestProfession',1,true))
local stop=assert(string.find(source,'-- SearchQuests incremental node cache.',start,true))
compile(string.sub(source,start,stop-1))()
dofile(core .. '/hdb_adapter.lua')
local nativeCalls=0
local function native() nativeCalls=nativeCalls+1;error('unexpected native lookup') end
local function disabled()
 assert(not pfDatabase:IsHDBEnabled())
 assert(not pfDatabase:SearchQuestTitlesHDB('quest',10,function() end))
 assert(not pfDatabase:SearchQuestIDHDB(41286,{qlogid=1}))
 assert(not pfDatabase:SearchQuestPreviewHDB(41286,{}))
 assert(not pfDatabase:SearchQuestGiversHDB({}))
 assert(not pfDatabase:SearchItemIDHDB(1,{}))
end
disabled() -- no companion or DLL
pfQuestHearthDB={GetQuestMapPinsAsync=native,SearchQuestTitlesAsync=native,GetQuestStartPinsAsync=native}
disabled() -- installed companion, missing DLL
assert(nativeCalls==0)
HDB_GetVersion=native;HDB_OpenAddon=native;HDB_QueryRawAsync=native;HDB_ClearPoison=native
assert(pfDatabase:IsHDBEnabled())
-- Native title search dispatches to the companion only with both components.
pfQuestHearthDB.SearchQuestTitlesAsync=function(self,q,limit,cb) cb({[1]={title='Native quest'}});return true end
local answered=false
assert(pfDatabase:SearchQuestTitlesHDB('quest',10,function(rows) answered=rows[1].title=='Native quest' end))
assert(answered)
-- All-three prerequisites must hold even with no loaded Lua quest records.
for _,branch in ipairs({{41286,41283,41284,41285},{41290,41287,41288,41289}}) do
 for mask=0,7 do
  pfQuest_history={}
  for i=1,3 do if math.floor(mask/2^(i-1))%2==1 then pfQuest_history[branch[i+1]]={1,60} end end
  local pins={{questID=branch[1],quest='Referral',qlvl=40,qmin=40,prerequisites=table.concat({branch[2],branch[3],branch[4]},','),skill=755}}
  assert(table.getn(pfDatabase:FilterHDBAvailableStartPins(pins))==(mask==7 and 1 or 0))
 end
end
for _,ref in ipairs({41286,41290}) do
 pfQuest_history={[ref]={1,60}}
 assert(table.getn(pfDatabase:FilterHDBAvailableStartPins({{questID=41291,quest='Recovery',qlvl=40,qmin=40,prerequisites='41286,41290',skill=755}}))==1)
end
skills[356]=224;assert(not pfDatabase:MeetsQuestProfession(6608,356))
skills[356]=225;assert(pfDatabase:MeetsQuestProfession(6608,356))
skills[755]=224;assert(not pfDatabase:MeetsQuestProfession(41291,755))
skills[755]=225;assert(pfDatabase:MeetsQuestProfession(41291,755))
-- Load real Lua data + overlays and test the same static eligibility function.
for _,db in ipairs({'items','units','objects','refloot','quests-itemreq','quests','areatrigger'}) do
 dofile(core..'/db/'..db..'.lua');dofile(turtle..'/db/'..db..'-turtle.lua')
end
dofile(turtle..'/overwrites.lua')
for _,db in ipairs({'items','units','objects','refloot','quests-itemreq','quests','areatrigger'}) do
 for id,row in pairs(pfDB[db]['data-turtle'] or {}) do pfDB[db].data[id]=row~='_' and row or nil end
end
local start=assert(string.find(source,'function pfDatabase:QuestFilter',1,true))
local stop=assert(string.find(source,'-- SearchQuests skill cache:',start,true))
compile('local quests=pfDB.quests.data\nlocal compat=pfQuestCompat\n'..string.sub(source,start,stop-1))()
bit={band=function(a,b) -- portable mask operation for the test host
 local value,p=0,1;while a>0 and b>0 do if a%2==1 and b%2==1 then value=value+p end;a=math.floor(a/2);b=math.floor(b/2);p=p*2 end;return value end}
for _,branch in ipairs({{41286,41283,41284,41285},{41290,41287,41288,41289}}) do
 for mask=0,7 do
  pfQuest_history={}
  for i=1,3 do if math.floor(mask/2^(i-1))%2==1 then pfQuest_history[branch[i+1]]={1,60} end end
  assert((pfDatabase:QuestFilter(branch[1],60,1,1) and true or false)==(mask==7))
 end
end
assert(pfDB.quests.data[40581].obj) -- scripted objectives remain explicit
assert(pfDB.items['data-turtle'][60603].U[60730]==100)
print('PASS: optional backend dispatch, missing DLL fallback, Lua/HDB all-three prerequisite parity, faction convergence and profession ranks')
