local root=(arg[1] or '/Users/loganangel/repos'):gsub('/$', '')..'/'
local function scenario(native,provider,fail,locale)
 pfQuestBackend=nil
 GetBuildInfo=function() return '1.12.1' end
 GetLocale=function() return locale or 'enUS' end
 GetAddOnInfo=function(n) return n,nil,nil,(n=='pfQuest-turtle' or (provider and n=='pfQuest-HearthDB-turtle')) and 1 or 0 end
 HDB_GetVersion=native and function() end or nil
 HDB_QueryRawAsync=HDB_GetVersion; HDB_ClearPoison=HDB_GetVersion; HDB_Close=HDB_GetVersion
 HDB_OpenAddon=native and function() if fail then error('missing') end return 42 end or nil
 dofile(root..'pfQuest/init/backend.lua')
 return pfQuestBackend.mode
end
assert(scenario(false,true)=='lua')
assert(scenario(true,false)=='lua')
assert(scenario(true,true,true)=='lua')
assert(scenario(true,true,false,'deDE')=='lua')
assert(scenario(true,true)=='hdb')
dofile(root..'pfQuest/db/init.lua')
for _,f in ipairs({'items','units','objects','quests','quests-itemreq','refloot'}) do
 dofile(root..'pfQuest/db/'..f..'.lua')
 assert(next(pfDB[f].data)==nil, f)
end
for _,f in ipairs({'items','units','objects','quests'}) do
 dofile(root..'pfQuest/db/enUS/'..f..'.lua')
 dofile(root..'pfQuest-turtle/db/'..f..'-turtle.lua')
 assert(next(pfDB[f].data)==nil,f)
end
assert(scenario(false,true)=='lua')
dofile(root..'pfQuest/db/init.lua')
for _,f in ipairs({'items','units','objects','quests'}) do
 dofile(root..'pfQuest/db/'..f..'.lua')
 assert(next(pfDB[f].data),f)
end
print('Loader scenarios and real database allocation guards passed')
