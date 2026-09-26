--[[
    Release rules: GIANTS TestRunner (PublicLuaCheck, ObsoleteFiles) and ModHub 7.5 archive content.
]]

local LUAC = [["C:\Program Files (x86)\Lua\5.1\luac.exe"]]

local function readFile(path)
    local fh = assert(io.open(path, "r"))
    local content = fh:read("*a")
    fh:close()
    return content
end

local function listFiles(pattern)
    local files = {}
    local p = io.popen('dir /s /b ' .. pattern .. ' 2>nul')
    for line in p:lines() do
        local rel = line:gsub("\\", "/")
        local idx = rel:find("/FS25_VehicleSync/", 1, true)
        if idx ~= nil then
            rel = rel:sub(idx + #"/FS25_VehicleSync/")
        end
        table.insert(files, rel)
    end
    p:close()
    return files
end

describe("release rules", function()
    local sources = listFiles("src\\*.lua")

    it("finds all source files", function()
        assert.equals(9, #sources)
    end)

    it("uses none of the calls TestRunner's PublicLuaCheck rejects", function()
        for _, file in ipairs(sources) do
            local content = readFile(file)
            for _, word in ipairs({ "pcall", "collectgarbage", "load(", "loadstring", "dofile", "require(" }) do
                assert.is_nil(content:find(word, 1, true), file .. " contains " .. word)
            end
            -- the game has no io / os libraries
            assert.is_nil(content:find("%f[%w_]io%."), file .. " uses io")
            assert.is_nil(content:find("%f[%w_]os%."), file .. " uses os")
        end
    end)

    it("compiles every source file with Lua 5.1 (no FS25 only syntax)", function()
        for _, file in ipairs(sources) do
            local p = io.popen(LUAC .. " -p " .. file .. " 2>&1")
            local output = p:read("*a")
            p:close()
            assert.equals("", output, file)
            local content = readFile(file)
            assert.is_nil(content:find("[%w_%]%)]%s*[%+%-%*/]=%s"), file .. " uses a compound assignment")
        end
    end)

    it("references every script by its literal path (ObsoleteFiles check)", function()
        local modDesc = readFile("modDesc.xml")
        local bootstrap = readFile("src/VehicleSync.lua")
        for _, file in ipairs(sources) do
            local referenced = modDesc:find('"' .. file .. '"', 1, true) or bootstrap:find('"' .. file .. '"', 1, true)
            assert.is_truthy(referenced, file .. " is not referenced literally")
        end
    end)

    it("ships only lua, xml and dds files", function()
        local release = readFile("create_release.ps1")
        assert.contains(release, "$include = @('modDesc.xml', 'icon_VehicleSync.dds', 'src', 'textures', 'translations')")
        local shipped = {}
        for _, f in ipairs(listFiles("src\\*")) do table.insert(shipped, f) end
        for _, f in ipairs(listFiles("textures\\*")) do table.insert(shipped, f) end
        for _, f in ipairs(listFiles("translations\\*")) do table.insert(shipped, f) end
        for _, file in ipairs(shipped) do
            if file:find("%.") then
                assert.is_not_nil(file:match("%.lua$") or file:match("%.xml$") or file:match("%.dds$"), file)
            end
        end
    end)

    it("builds an archive named with the FS25_ prefix and without a version (5.2)", function()
        local release = readFile("create_release.ps1")
        local name = release:match("dist\\(FS25_[%w_]+%.zip)")
        assert.equals("FS25_VehicleSync.zip", name)
        assert.is_nil(name:gsub("^FS25_", ""):find("%d"))
    end)

    it("writes all scripts with the '[VehicleSync]' log prefix", function()
        for _, file in ipairs(sources) do
            local content = readFile(file)
            for message in content:gmatch('Logging%.%w+%("([^"]*)"') do
                assert.contains(message, "[VehicleSync]", file)
            end
        end
    end)
end)
