local eventlist = LuaEventManager.class:zbGet("EventList")
for i = 0, eventlist:size()-1 do
    local event = eventlist:get(i)
    local cbs  = event:zbGet("callbacks")
    if cbs:size() > 0 then
        local name = event:zbGet("name")
        print(name)
        for j = 0, cbs:size()-1 do
            local cb = cbs:get(j)
            local file = cb:zbGet("prototype"):zbGet("file")
            -- local line = cb:zbGet("prototype"):zbGet("lines")[1]
            print(string.format("    %-40s %s", file, cb:zbCall("toString")))
        end
        print()
    end
end
