-- This file can be used to manually overwrite or add contents to the db
-- which weren't detect by the extractor. Make sure to write proper comments
-- and include as much information as possible, as this should be only the
-- intermediate solution and fixing the extractor instead is the desired goal.

-- [[ Quest: Great Bear Spirit ]]
-- Unit: Great Bear Spirit (11956)
-- Type: Talk/Gossip Menu Requirement
if pfDB["quests"]["data"][5929] then
  pfDB["quests"]["data"][5929]["obj"] = { ["U"] = { 11956 } }
end
if pfDB["quests"]["data"][5930] then
  pfDB["quests"]["data"][5930]["obj"] = { ["U"] = { 11956 } }
end

-- Zanzil's Mixture and a Fool's Stout is a convergence quest. Both Zanzil's
-- Secret (621) and Back to Booty Bay (1118) must be complete.
if pfDB["quests"]["data"][1119] then
  pfDB["quests"]["data"][1119]["preall"] = { 621, 1118 }
end
pfDB["quests"]["preall"] = pfDB["quests"]["preall"] or {}
pfDB["quests"]["preall"][1119] = { 621, 1118 }
