--[[
    VehicleSync test runner (plain Lua 5.1, no external dependencies)

    Usage (from the mod root):
        & "C:\Program Files (x86)\Lua\5.1\lua.exe" tests\run_tests.lua
        & "C:\Program Files (x86)\Lua\5.1\lua.exe" tests\run_tests.lua --coverage

    busted-style API: describe / it / before_each / after_each and assert.* helpers.
    With --coverage, line coverage of every file in src/ is measured through debug.sethook.
    Executable lines are taken from `luac -l` so the percentage matches what Lua can execute.
    The run fails (exit 1) if a test fails or coverage drops below COVERAGE_THRESHOLD.

    New spec files must be added to TEST_FILES below or they will not run.
]]

local TEST_FILES = {
    "tests/specs/VehicleSyncMath_spec.lua",
    "tests/specs/VehicleSyncController_spec.lua",
    "tests/specs/VehicleSyncSettings_spec.lua",
    "tests/specs/VehicleSyncEvents_spec.lua",
    "tests/specs/VehicleSyncSpec_spec.lua",
    "tests/specs/VehicleSyncSpecNetwork_spec.lua",
    "tests/specs/VehicleSyncSpecInput_spec.lua",
    "tests/specs/VehicleSyncHudLayout_spec.lua",
    "tests/specs/VehicleSyncHud_spec.lua",
    "tests/specs/VehicleSync_spec.lua",
    "tests/specs/ModDesc_spec.lua",
    "tests/specs/ReleaseRules_spec.lua",
    "tests/specs/Multiplayer_spec.lua",
}

local SOURCE_FILES = {
    "src/VehicleSyncMath.lua",
    "src/VehicleSyncController.lua",
    "src/VehicleSyncSettings.lua",
    "src/network/VehicleSyncStateEvent.lua",
    "src/network/VehicleSyncRequestEvent.lua",
    "src/VehicleSyncSpec.lua",
    "src/hud/VehicleSyncHudLayout.lua",
    "src/hud/VehicleSyncHud.lua",
    "src/VehicleSync.lua",
}

local COVERAGE_THRESHOLD = 90
local LUAC = [["C:\Program Files (x86)\Lua\5.1\luac.exe"]]

local withCoverage = false
local filter = nil
for _, a in ipairs(arg or {}) do
    if a == "--coverage" then
        withCoverage = true
    elseif a:sub(1, 9) == "--filter=" then
        filter = a:sub(10)
    end
end

-- ---------------------------------------------------------------------------
-- Assertions
-- ---------------------------------------------------------------------------

local luaAssert = assert

local function fmt(v)
    if type(v) == "string" then
        return string.format("%q", v)
    end
    return tostring(v)
end

local function deepEqual(a, b, seen)
    if a == b then
        return true
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    seen = seen or {}
    if seen[a] == b then
        return true
    end
    seen[a] = b
    for k, v in pairs(a) do
        if not deepEqual(v, b[k], seen) then
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

assert = setmetatable({}, {
    __call = function(_, v, msg)
        return luaAssert(v, msg)
    end
})

function assert.is_true(v, msg)
    if v ~= true then error((msg or "") .. " expected true, got " .. fmt(v), 2) end
end
function assert.is_false(v, msg)
    if v ~= false then error((msg or "") .. " expected false, got " .. fmt(v), 2) end
end
function assert.is_nil(v, msg)
    if v ~= nil then error((msg or "") .. " expected nil, got " .. fmt(v), 2) end
end
function assert.is_not_nil(v, msg)
    if v == nil then error((msg or "") .. " expected non-nil", 2) end
end
function assert.is_truthy(v, msg)
    if not v then error((msg or "") .. " expected truthy, got " .. fmt(v), 2) end
end
function assert.is_falsy(v, msg)
    if v then error((msg or "") .. " expected falsy, got " .. fmt(v), 2) end
end
function assert.equals(expected, actual, msg)
    if expected ~= actual then
        error((msg or "") .. " expected " .. fmt(expected) .. ", got " .. fmt(actual), 2)
    end
end
function assert.not_equals(a, b, msg)
    if a == b then error((msg or "") .. " expected values to differ, both " .. fmt(a), 2) end
end
function assert.same(expected, actual, msg)
    if not deepEqual(expected, actual) then
        error((msg or "") .. " tables differ", 2)
    end
end
function assert.near(expected, actual, tolerance, msg)
    tolerance = tolerance or 1e-6
    if type(actual) ~= "number" or math.abs(expected - actual) > tolerance then
        error((msg or "") .. " expected " .. fmt(expected) .. " +/- " .. tolerance .. ", got " .. fmt(actual), 2)
    end
end
function assert.is_greater(limit, actual, msg)
    if not (actual > limit) then error((msg or "") .. " expected > " .. fmt(limit) .. ", got " .. fmt(actual), 2) end
end
function assert.is_less(limit, actual, msg)
    if not (actual < limit) then error((msg or "") .. " expected < " .. fmt(limit) .. ", got " .. fmt(actual), 2) end
end
function assert.has_error(fn, pattern)
    local ok, err = pcall(fn)
    if ok then error("expected an error", 2) end
    if pattern ~= nil and not string.find(tostring(err), pattern, 1, true) then
        error("error " .. fmt(tostring(err)) .. " does not contain " .. fmt(pattern), 2)
    end
end
function assert.has_no_error(fn)
    local ok, err = pcall(fn)
    if not ok then error("expected no error, got " .. tostring(err), 2) end
end
function assert.contains(haystack, needle, msg)
    if type(haystack) == "string" then
        if not string.find(haystack, needle, 1, true) then
            error((msg or "") .. " " .. fmt(haystack) .. " does not contain " .. fmt(needle), 2)
        end
        return
    end
    for _, v in pairs(haystack) do
        if deepEqual(v, needle) then return end
    end
    error((msg or "") .. " table does not contain " .. fmt(needle), 2)
end
function assert.not_contains(haystack, needle, msg)
    if type(haystack) == "string" then
        if string.find(haystack, needle, 1, true) then
            error((msg or "") .. " " .. fmt(haystack) .. " must not contain " .. fmt(needle), 2)
        end
        return
    end
    for _, v in pairs(haystack) do
        if deepEqual(v, needle) then error((msg or "") .. " table must not contain " .. fmt(needle), 2) end
    end
end

-- ---------------------------------------------------------------------------
-- BDD
-- ---------------------------------------------------------------------------

local results = { passed = 0, failed = 0, failures = {} }
local stack = {}
local beforeEach = {}
local afterEach = {}
local currentFile = ""

function describe(name, fn)
    table.insert(stack, name)
    local nBefore, nAfter = #beforeEach, #afterEach
    fn()
    while #beforeEach > nBefore do table.remove(beforeEach) end
    while #afterEach > nAfter do table.remove(afterEach) end
    table.remove(stack)
end

function before_each(fn) table.insert(beforeEach, fn) end
function after_each(fn) table.insert(afterEach, fn) end

function it(name, fn)
    local fullName = table.concat(stack, " > ") .. " > " .. name
    if filter ~= nil and not string.find(fullName, filter, 1, true) then
        return
    end
    local ok, err = true, nil
    for _, b in ipairs(beforeEach) do
        ok, err = pcall(b)
        if not ok then break end
    end
    if ok then
        ok, err = pcall(fn)
    end
    for i = #afterEach, 1, -1 do
        local ok2, err2 = pcall(afterEach[i])
        if ok and not ok2 then ok, err = ok2, err2 end
    end
    if ok then
        results.passed = results.passed + 1
    else
        results.failed = results.failed + 1
        table.insert(results.failures, { file = currentFile, name = fullName, err = tostring(err) })
    end
end

-- ---------------------------------------------------------------------------
-- Coverage
-- ---------------------------------------------------------------------------

local hits = {}
local tracked = {}

local function normalize(path)
    path = path:gsub("\\", "/")
    local idx = path:find("src/", 1, true)
    if idx ~= nil then
        return path:sub(idx)
    end
    return nil
end

local function hook(_, line)
    local info = debug.getinfo(2, "S")
    local source = info.source
    if source:sub(1, 1) == "@" then
        local key = tracked[source]
        if key == nil then
            key = normalize(source:sub(2)) or false
            tracked[source] = key
        end
        if key then
            local t = hits[key]
            if t == nil then
                t = {}
                hits[key] = t
            end
            t[line] = true
        end
    end
end

local function executableLines(file)
    local lines = {}
    local p = io.popen(LUAC .. " -l -p " .. file .. " 2>&1")
    for l in p:lines() do
        local n = l:match("^%s+%d+%s+%[(%d+)%]")
        if n ~= nil then
            lines[tonumber(n)] = true
        end
    end
    p:close()
    -- "end" of a function body is reported as a RETURN on the "end" line, which only executes
    -- for functions without an explicit return. Lines that only contain "end" are ignored to
    -- avoid penalising functions that always return early.
    local i = 0
    local fh = io.open(file, "r")
    if fh ~= nil then
        for text in fh:lines() do
            i = i + 1
            if text:match("^%s*end%s*[%)%,]*%s*$") or text:match("^%s*else%s*$") then
                lines[i] = nil
            end
        end
        fh:close()
    end
    return lines
end

-- ---------------------------------------------------------------------------
-- Run
-- ---------------------------------------------------------------------------

package.path = "./?.lua;./tests/?.lua;./tests/mocks/?.lua;" .. package.path

local function snapshotGlobals()
    local copy = {}
    for k, v in pairs(_G) do copy[k] = v end
    return copy
end

local function restoreGlobals(copy)
    for k in pairs(_G) do
        if copy[k] == nil then _G[k] = nil end
    end
    for k, v in pairs(copy) do _G[k] = v end
end

if withCoverage then
    debug.sethook(hook, "l")
end

for _, file in ipairs(TEST_FILES) do
    currentFile = file
    local snap = snapshotGlobals()
    local chunk, loadErr = loadfile(file)
    if chunk == nil then
        results.failed = results.failed + 1
        table.insert(results.failures, { file = file, name = "<load>", err = tostring(loadErr) })
    else
        local ok, err = pcall(chunk)
        if not ok then
            results.failed = results.failed + 1
            table.insert(results.failures, { file = file, name = "<top level>", err = tostring(err) })
        end
    end
    restoreGlobals(snap)
end

debug.sethook()

print("")
for _, f in ipairs(results.failures) do
    print("FAIL  " .. f.file .. "  " .. f.name)
    print("      " .. f.err)
end
print(string.format("\nPassed: %d   Failed: %d   Total: %d", results.passed, results.failed, results.passed + results.failed))

local coverageOk = true
if withCoverage then
    print("\nCoverage (executable lines):")
    local totalExec, totalHit = 0, 0
    local report = io.open("tests/coverage_report.txt", "w")
    for _, file in ipairs(SOURCE_FILES) do
        local execLines = executableLines(file)
        local fileHits = hits[file] or {}
        local nExec, nHit = 0, 0
        local missed = {}
        for line in pairs(execLines) do
            nExec = nExec + 1
            if fileHits[line] then
                nHit = nHit + 1
            else
                table.insert(missed, line)
            end
        end
        table.sort(missed)
        totalExec = totalExec + nExec
        totalHit = totalHit + nHit
        local pct = nExec > 0 and (100 * nHit / nExec) or 100
        local line = string.format("  %-45s %5.1f%%  (%d/%d)", file, pct, nHit, nExec)
        print(line)
        if report ~= nil then
            report:write(line .. "\n")
            if #missed > 0 then
                report:write("      missed lines: " .. table.concat(missed, ", ") .. "\n")
            end
        end
    end
    local pct = totalExec > 0 and (100 * totalHit / totalExec) or 100
    local summary = string.format("  %-45s %5.1f%%  (%d/%d)", "TOTAL", pct, totalHit, totalExec)
    print(summary)
    if report ~= nil then
        report:write(summary .. "\n")
        report:close()
    end
    print("  (missed lines per file: tests/coverage_report.txt)")
    if pct < COVERAGE_THRESHOLD then
        coverageOk = false
        print(string.format("\nCoverage %.1f%% is below the threshold of %d%%", pct, COVERAGE_THRESHOLD))
    end
end

if results.failed > 0 or not coverageOk then
    os.exit(1)
end
os.exit(0)
