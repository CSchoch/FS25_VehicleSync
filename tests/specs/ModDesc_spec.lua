--[[
    Static checks of modDesc.xml and the translations against the ModHub guidelines
    (modHubGuidelinesENv59-1.pdf: 5.1 icon, 5.4 descVersion, 5.5 modDesc, 8.2 EN/DE for UI texts,
    10.4 script mod description with hotkeys).
]]

local engine = dofile("tests/mocks/engine.lua")
engine.loadMod()

local function readFile(path, binary)
    local fh = assert(io.open(path, binary and "rb" or "r"))
    local content = fh:read("*a")
    fh:close()
    return content
end

local modDesc = readFile("modDesc.xml")

local function readTexts(lang)
    local texts, order = {}, {}
    local content = readFile("translations/translation_" .. lang .. ".xml")
    for name, text in content:gmatch('<text name="([^"]+)" text="([^"]*)"') do
        assert.is_nil(texts[name], "duplicate l10n key " .. name .. " in " .. lang)
        texts[name] = text
        table.insert(order, name)
    end
    return texts, order
end

local en, enOrder = readTexts("en")
local de = readTexts("de")

local function description(lang)
    return modDesc:match("<description>.-<" .. lang .. ">%s*<!%[CDATA%[(.-)%]%]>%s*</" .. lang .. ">")
end

local function actions()
    local list = {}
    for name in modDesc:gmatch('<action name="([^"]+)"') do
        table.insert(list, name)
    end
    return list
end

local function bindings()
    local map = {}
    for action, input in modDesc:gmatch('<actionBinding action="([^"]+)">%s*<binding device="KB_MOUSE_DEFAULT" input="([^"]+)"') do
        map[action] = input
    end
    return map
end

local function srcFiles()
    local files = {}
    local p = io.popen('dir /s /b src\\*.lua 2>nul')
    for line in p:lines() do
        table.insert(files, line)
    end
    p:close()
    return files
end

describe("modDesc.xml", function()
    it("uses the current descVersion and a four digit version", function()
        local descVersion = tonumber(modDesc:match('<modDesc descVersion="(%d+)"'))
        assert.is_not_nil(descVersion)
        assert.is_true(descVersion >= 113)
        assert.is_not_nil(modDesc:match("<version>%d+%.%d+%.%d+%.%d+</version>"))
    end)

    it("has an English and German title with capital initial letters", function()
        local enTitle = modDesc:match("<title>%s*<en>(.-)</en>")
        local deTitle = modDesc:match("<title>.-<de>(.-)</de>")
        assert.equals("Vehicle Sync", enTitle)
        assert.is_not_nil(deTitle)
        for _, title in ipairs({ enTitle, deTitle }) do
            for word in title:gmatch("%S+") do
                assert.is_not_nil(word:match("^%u"), "word '" .. word .. "' must start with a capital letter")
            end
        end
    end)

    it("has detailed CDATA descriptions in English and German that are not copies", function()
        local enText, deText = description("en"), description("de")
        assert.is_not_nil(enText, "en description must use CDATA")
        assert.is_not_nil(deText, "de description must use CDATA")
        assert.not_equals(enText, deText)
        assert.is_true(#enText > 800)
        -- TestRunner (ModDescCheck excessChangelog): no changelog in the initial 1.0.0.0 release,
        -- a changelog is mandatory for every update (guideline 5.3)
        local version = modDesc:match("<version>(.-)</version>")
        if version == "1.0.0.0" then
            assert.is_nil(enText:lower():find("changelog", 1, true))
            assert.is_nil(deText:lower():find("änderungen", 1, true))
            assert.is_nil(deText:lower():find("changelog", 1, true))
        else
            assert.contains(enText, "CHANGELOG")
        end
    end)

    it("contains no links, logos or brand names in the description (5.1 / 8.3)", function()
        for _, lang in ipairs({ "en", "de" }) do
            local text = description(lang)
            assert.is_nil(text:lower():find("http", 1, true))
            assert.is_nil(text:lower():find("www.", 1, true))
            for _, brand in ipairs({ "deere", "claas", "case ih", "new holland", "fendt" }) do
                assert.is_nil(text:lower():find(brand, 1, true), "brand name " .. brand)
            end
        end
    end)

    it("declares multiplayer support", function()
        assert.is_not_nil(modDesc:find('<multiplayer supported="true"', 1, true))
    end)

    it("references an existing 512x512 BC1 icon without mipmaps (TestRunner modIconResolution)", function()
        local icon = modDesc:match("<iconFilename>(.-)</iconFilename>")
        assert.equals("icon_VehicleSync.dds", icon)
        local data = readFile(icon, true)
        assert.equals("DDS ", data:sub(1, 4))
        local function u32(offset)
            local b1, b2, b3, b4 = data:byte(offset + 1, offset + 4)
            return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        end
        assert.equals(512, u32(12))
        assert.equals(512, u32(16))
        assert.is_true(u32(28) <= 1, "icon must not have mipmaps")
        assert.equals("DXT1", data:sub(85, 88))
    end)

    it("sources only existing files, the specialization last via the manager", function()
        local count = 0
        for filename in modDesc:gmatch('<sourceFile filename="([^"]+)"') do
            assert.is_not_nil(io.open(filename, "r"), filename)
            count = count + 1
        end
        assert.equals(6, count)
        assert.is_nil(modDesc:find("VehicleSyncSpec.lua\"", 1, true))
        assert.is_not_nil(io.open(VehicleSync and VehicleSync.SPEC_FILENAME or "src/VehicleSyncSpec.lua", "r"))
    end)

    it("uses the translation files of both languages", function()
        assert.is_not_nil(modDesc:find('<l10n filenamePrefix="translations/translation" />', 1, true))
    end)
end)

describe("input bindings", function()
    it("binds every action exactly once on the keyboard", function()
        local map = bindings()
        local list = actions()
        assert.equals(9, #list)
        local seenInputs = {}
        for _, action in ipairs(list) do
            assert.is_not_nil(map[action], "missing binding for " .. action)
            assert.is_nil(seenInputs[map[action]], "duplicate key " .. map[action])
            seenInputs[map[action]] = true
            assert.is_not_nil(map[action]:match("^KEY_lalt "), action .. " should use a Left Alt combination")
        end
    end)

    it("avoids Left Alt combinations used by other installed mods", function()
        for _, input in pairs(bindings()) do
            for _, taken in ipairs({ "KEY_lalt KEY_s", "KEY_lalt KEY_g", "KEY_lalt KEY_b", "KEY_lalt KEY_h", "KEY_lalt KEY_w", "KEY_lalt KEY_e" }) do
                assert.not_equals(taken, input)
            end
        end
    end)

    it("matches the actions used by the specialization", function()
        local source = readFile("src/VehicleSyncSpec.lua")
        local declared = {}
        for _, a in ipairs(actions()) do declared[a] = true end
        local used = 0
        for action in source:gmatch('add%("(VS_[A-Z_]+)"') do
            assert.is_true(declared[action] == true, action .. " not declared in modDesc")
            used = used + 1
        end
        assert.equals(9, used)
    end)

    it("explains every hotkey in both descriptions (10.4)", function()
        local keyNames = { KEY_n = "N", KEY_c = "C", KEY_m = "M", KEY_p = "P", KEY_r = "R" }
        for _, input in pairs(bindings()) do
            local key = input:match("KEY_lalt (KEY_%w+)")
            local letter = keyNames[key]
            if letter ~= nil then
                assert.contains(description("en"), "Left Alt + " .. letter)
                assert.contains(description("de"), "Linke Alt + " .. letter)
            end
        end
        assert.contains(description("en"), "Arrow Left / Right")
        assert.contains(description("de"), "Pfeil Links / Rechts")
    end)

    it("has an input text for every action in both languages", function()
        for _, action in ipairs(actions()) do
            assert.is_not_nil(en["input_" .. action], action)
            assert.is_not_nil(de["input_" .. action], action)
        end
    end)
end)

describe("translations", function()
    it("have the same keys in English and German (8.2)", function()
        for key in pairs(en) do
            assert.is_not_nil(de[key], "missing German text " .. key)
        end
        for key in pairs(de) do
            assert.is_not_nil(en[key], "missing English text " .. key)
        end
        assert.is_true(#enOrder > 50)
    end)

    it("start with a capital letter unless they start with a format placeholder (5.5)", function()
        for _, texts in ipairs({ en, de }) do
            for key, text in pairs(texts) do
                -- UTF-8 upper case umlauts (Ä, Ö, Ü) are two bytes: 0xC3 0x84 / 0x96 / 0x9C
                if text:sub(1, 1) ~= "%" then
                    local upperUmlaut = text:byte(1) == 195 and text:byte(2) >= 128 and text:byte(2) <= 158
                    assert.is_true(text:match("^%u") ~= nil or upperUmlaut, key .. ": " .. text)
                end
            end
        end
    end)

    it("are real translations, not copies of English", function()
        local copies = 0
        for key, text in pairs(en) do
            if de[key] == text then copies = copies + 1 end
        end
        assert.equals(0, copies)
    end)

    it("keep the same format placeholders in both languages", function()
        for key, text in pairs(en) do
            local a, b = {}, {}
            for p in text:gmatch("%%[%d%.]*[sdf]") do table.insert(a, p) end
            for p in de[key]:gmatch("%%[%d%.]*[sdf]") do table.insert(b, p) end
            assert.same(a, b, key)
        end
    end)

    it("cover every l10n key used in the scripts", function()
        for _, file in ipairs(srcFiles()) do
            local source = readFile(file)
            for key in source:gmatch('getText%("([%w_]+)"') do
                assert.is_not_nil(en[key], key .. " used in " .. file)
            end
            for key in source:gmatch('"(vs_[%w_]+)"') do
                -- "vs_reason_" .. name is a key prefix, covered by the reason test below
                if key:sub(-1) ~= "_" then
                    assert.is_not_nil(en[key], key .. " used in " .. file)
                end
            end
        end
    end)

    it("cover every reason and state", function()
        for name, value in pairs(VehicleSyncController.REASON) do
            local key = VehicleSyncController.getReasonTextKey(value)
            if name ~= "NONE" then
                assert.is_not_nil(en[key], key)
            end
        end
        for _, state in ipairs({ "idle", "connected", "acquiring", "tracking" }) do
            assert.is_not_nil(en["vs_state_" .. state])
        end
    end)
end)
