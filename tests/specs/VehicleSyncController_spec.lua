dofile("tests/mocks/engine.lua")
TestEngine.loadCore()

local C = VehicleSyncController
local STATE = C.STATE
local REASON = C.REASON

local settings

local function geometry(overrides)
    local g = { cartLocalX = 7, cartLocalZ = 2, tractorLocalX = 7, tractorLocalZ = 8, lateralError = 0,
        alongError = 0, headingError = 0, distance = 10, cartToTractorAlong = 6 }
    for k, v in pairs(overrides or {}) do g[k] = v end
    return g
end

local function engagedCtx(overrides)
    local ctx = {
        state = STATE.TRACKING, dt = 16, leaderExists = true, networkEnabled = true, distance = 10,
        operatorPresent = true, motorStarted = true, operatorSteering = false, operatorPedal = false,
        operatorCruise = false, cartFull = false, leaderSpeed = 8, leaderCurvature = 0, abortTimer = 0,
        geometry = geometry(),
    }
    for k, v in pairs(overrides or {}) do ctx[k] = v end
    return ctx
end

describe("VehicleSyncController", function()
    before_each(function()
        settings = C.buildSettings()
    end)

    describe("settings", function()
        it("builds defaults", function()
            assert.equals(16, settings.maxSyncSpeed)
            assert.equals(0.5, settings.minSyncSpeed)
            assert.equals(0.5, settings.maxLeaderCurvature)
        end)
        it("applies typed overrides and ignores unknown or mistyped keys", function()
            local s = C.buildSettings({ maxSyncSpeed = 20, unknownKey = 1, disengageOnCartFull = "no" })
            assert.equals(20, s.maxSyncSpeed)
            assert.is_nil(s.unknownKey)
            assert.is_true(s.disengageOnCartFull)
        end)
    end)

    describe("state helpers", function()
        it("knows engaged and linked states", function()
            assert.is_false(C.isEngaged(STATE.IDLE))
            assert.is_false(C.isEngaged(STATE.CONNECTED))
            assert.is_true(C.isEngaged(STATE.ACQUIRING))
            assert.is_true(C.isEngaged(STATE.TRACKING))
            assert.is_false(C.isLinked(STATE.IDLE))
            assert.is_false(C.isLinked(nil))
            assert.is_true(C.isLinked(STATE.CONNECTED))
        end)
        it("fits every state into the network bits", function()
            for _, v in pairs(STATE) do
                assert.is_less(2 ^ C.NUM_STATE_BITS, v)
            end
        end)
        it("keeps reason codes unique and inside UInt8", function()
            local seen = {}
            for name, v in pairs(REASON) do
                assert.is_nil(seen[v], "duplicate reason " .. name)
                seen[v] = true
                assert.is_true(v >= 0 and v <= 255)
            end
        end)
    end)

    describe("computeGeometry", function()
        it("computes errors in the leader frame", function()
            local leader = { x = 0, z = 0, heading = 0 }
            local follower = { x = 7.5, z = 9, heading = 0.1 }
            local cart = { x = 7.5, z = 3 }
            local g = C.computeGeometry(leader, follower, cart, { x = 7, z = 2 })
            assert.near(0.5, g.lateralError)
            assert.near(1, g.alongError)
            assert.near(0.1, g.headingError)
            assert.near(math.sqrt(7.5 ^ 2 + 81), g.distance)
            assert.near(6, g.cartToTractorAlong)
        end)
        it("uses the follower as cart when no cart exists", function()
            local g = C.computeGeometry({ x = 0, z = 0, heading = 0 }, { x = 7, z = 2, heading = 0 }, nil, { x = 7, z = 2 })
            assert.near(0, g.alongError)
            assert.near(7, g.cartLocalX)
        end)
        it("works for rotated leaders", function()
            -- leader heading east (+x world); a point 7 m to its left lies at world -z
            local g = C.computeGeometry({ x = 0, z = 0, heading = math.pi / 2 }, { x = 2, z = -7, heading = math.pi / 2 }, nil, { x = 7, z = 2 })
            assert.near(0, g.lateralError)
            assert.near(0, g.alongError)
        end)
    end)

    describe("operational zone", function()
        it("accepts positions beside and behind the leader", function()
            assert.is_true(C.isInOperationalZone(geometry({ cartLocalX = 8, cartLocalZ = -20 }), settings))
            assert.is_true(C.isInOperationalZone(geometry({ cartLocalX = -8, cartLocalZ = 10 }), settings))
        end)
        it("rejects positions too far away or with a wrong heading", function()
            assert.is_false(C.isInOperationalZone(geometry({ cartLocalX = 30 }), settings))
            assert.is_false(C.isInOperationalZone(geometry({ cartLocalZ = 20 }), settings))
            assert.is_false(C.isInOperationalZone(geometry({ cartLocalZ = -50 }), settings))
            assert.is_false(C.isInOperationalZone(geometry({ headingError = math.rad(45) }), settings))
        end)
    end)

    describe("home point", function()
        it("computes the minimum lateral clearance", function()
            assert.near(3.5 / 2 + 3 / 2 + 1, C.getMinLateral(3.5, 3, settings))
            assert.near(4, C.getMinLateral(nil, nil, settings))
        end)
        it("clamps lateral and along offsets, keeping the side", function()
            local h = C.clampHome({ x = 1, z = 50 }, 3, 3, settings)
            assert.near(4, h.x)
            assert.near(20, h.z)
            h = C.clampHome({ x = -1, z = -50 }, 3, 3, settings)
            assert.near(-4, h.x)
            assert.near(-20, h.z)
            h = C.clampHome({ x = 40, z = 0 }, 3, 3, settings)
            assert.near(20, h.x)
        end)
        it("honours an explicit side for x == 0", function()
            local h = C.clampHome({ x = 0, z = 0 }, 3, 3, settings, -1)
            assert.near(-4, h.x)
        end)
        it("uses the measured pipe outlet as default", function()
            local h = C.getDefaultHome({ x = 7.2, z = 1.5 }, 1, 3.5, 3, settings)
            assert.near(7.2, h.x)
            assert.near(1.5, h.z)
        end)
        it("falls back to the pipe side without a measurement", function()
            local h = C.getDefaultHome(nil, -1, 3, 3, settings)
            assert.near(-(4 + settings.fallbackLateralMargin), h.x)
            assert.near(0, h.z)
            h = C.getDefaultHome(nil, nil, 3, 3, settings)
            assert.is_greater(0, h.x)
        end)
        it("nudges in all four directions", function()
            local home = { x = 7, z = 2 }
            local h, delta = C.applyNudge(home, C.NUDGE.LEFT, 3, 3, settings)
            assert.near(7.25, h.x)
            assert.near(0, delta)
            h = C.applyNudge(home, C.NUDGE.RIGHT, 3, 3, settings)
            assert.near(6.75, h.x)
            h, delta = C.applyNudge(home, C.NUDGE.FORWARD, 3, 3, settings)
            assert.near(2.25, h.z)
            assert.near(0.25, delta)
            h, delta = C.applyNudge(home, C.NUDGE.BACK, 3, 3, settings)
            assert.near(1.75, h.z)
            assert.near(-0.25, delta)
            h = C.applyNudge(home, 99, 3, 3, settings)
            assert.near(7, h.x)
        end)
        it("mirrors left/right on the right side of the leader", function()
            local h = C.applyNudge({ x = -7, z = 2 }, C.NUDGE.LEFT, 3, 3, settings)
            assert.near(-6.75, h.x)
            h = C.applyNudge({ x = -7, z = 2 }, C.NUDGE.RIGHT, 3, 3, settings)
            assert.near(-7.25, h.x)
        end)
        it("never nudges the cart into or across the leader", function()
            local h = { x = 4.1, z = 0 }
            for _ = 1, 10 do
                h = C.applyNudge(h, C.NUDGE.RIGHT, 3, 3, settings)
            end
            assert.near(4, h.x)
            h = { x = -4.1, z = 0 }
            for _ = 1, 40 do
                h = C.applyNudge(h, C.NUDGE.LEFT, 3, 3, settings)
            end
            assert.near(-4, h.x)
        end)
        it("builds a home point from the current cart position", function()
            local h = C.homeFromGeometry(geometry({ cartLocalX = -6.123, cartLocalZ = 1.456 }), 3, 3, settings)
            assert.near(-6.12, h.x)
            assert.near(1.46, h.z)
        end)
    end)

    describe("curvature tracker", function()
        it("reports degrees per meter after the window", function()
            local t = C.newCurvatureTracker()
            assert.equals(0, C.updateCurvature(t, 0, 0, 0, 3))
            assert.equals(0, C.updateCurvature(t, 0, 2, math.rad(1), 3))
            local v = C.updateCurvature(t, 0, 4, math.rad(2), 3)
            assert.near(0.5, v, 1e-6)
        end)
        it("keeps the last value until the next window completes", function()
            local t = C.newCurvatureTracker()
            C.updateCurvature(t, 0, 0, 0, 3)
            C.updateCurvature(t, 0, 3, math.rad(6), 3)
            assert.near(2, t.value, 1e-6)
            assert.near(2, C.updateCurvature(t, 0, 4, math.rad(6), 3), 1e-6)
        end)
        it("resets", function()
            local t = C.newCurvatureTracker()
            C.updateCurvature(t, 0, 0, 0, 3)
            C.updateCurvature(t, 0, 3, math.rad(6), 3)
            C.resetCurvature(t)
            assert.equals(0, t.value)
            assert.is_nil(t.lastX)
        end)
    end)

    describe("checkConnect", function()
        local function ctx(o)
            local c = { leaderExists = true, isSelf = false, networkEnabled = true, sameFarm = true, distance = 20 }
            for k, v in pairs(o or {}) do c[k] = v end
            return c
        end
        it("accepts a valid leader", function()
            local ok, reason = C.checkConnect(ctx(), settings)
            assert.is_true(ok)
            assert.equals(REASON.CONNECTED, reason)
        end)
        it("rejects missing, own, closed, foreign and distant leaders", function()
            local _, r = C.checkConnect(ctx({ leaderExists = false }), settings)
            assert.equals(REASON.NO_LEADER, r)
            _, r = C.checkConnect(ctx({ isSelf = true }), settings)
            assert.equals(REASON.NO_LEADER, r)
            _, r = C.checkConnect(ctx({ networkEnabled = false }), settings)
            assert.equals(REASON.NETWORK_CLOSED, r)
            _, r = C.checkConnect(ctx({ sameFarm = false }), settings)
            assert.equals(REASON.NOT_ALLOWED, r)
            _, r = C.checkConnect(ctx({ distance = 100 }), settings)
            assert.equals(REASON.OUT_OF_RANGE, r)
        end)
    end)

    describe("checkEngage", function()
        local function ctx(o)
            local c = { state = STATE.CONNECTED, geometry = geometry(), leaderSpeed = 8, leaderBusy = false,
                operatorPresent = true, motorStarted = true, cartFull = false }
            for k, v in pairs(o or {}) do c[k] = v end
            return c
        end
        it("engages inside the zone and speed window", function()
            local ok, reason = C.checkEngage(ctx(), settings)
            assert.is_true(ok)
            assert.equals(REASON.ENGAGED, reason)
        end)
        it("rejects every failed requirement with its reason", function()
            local cases = {
                { { state = STATE.IDLE }, REASON.NO_LEADER },
                { { operatorPresent = false }, REASON.OPERATOR_LEFT },
                { { motorStarted = false }, REASON.MOTOR_OFF },
                { { leaderBusy = true }, REASON.LEADER_BUSY },
                { { cartFull = true }, REASON.CART_FULL },
                { { leaderSpeed = 0 }, REASON.LEADER_SPEED_WINDOW },
                { { leaderSpeed = 20 }, REASON.LEADER_SPEED_WINDOW },
                { { geometry = geometry({ cartLocalX = 40 }) }, REASON.NOT_IN_ZONE },
            }
            for _, case in ipairs(cases) do
                local ok, reason = C.checkEngage(ctx(case[1]), settings)
                assert.is_false(ok)
                assert.equals(case[2], reason)
            end
        end)
        it("allows a full cart when the setting is off", function()
            settings.disengageOnCartFull = false
            assert.is_true((C.checkEngage(ctx({ cartFull = true }), settings)))
        end)
    end)

    describe("evaluate", function()
        it("does nothing while idle", function()
            local s, r, t = C.evaluate(engagedCtx({ state = STATE.IDLE, leaderExists = false }), settings)
            assert.equals(STATE.IDLE, s)
            assert.equals(REASON.NONE, r)
            assert.equals(0, t)
        end)
        it("drops to IDLE on connection faults from any linked state", function()
            for _, state in ipairs({ STATE.CONNECTED, STATE.ACQUIRING, STATE.TRACKING }) do
                local s, r = C.evaluate(engagedCtx({ state = state, leaderExists = false }), settings)
                assert.equals(STATE.IDLE, s)
                assert.equals(REASON.LEADER_LOST, r)
                s, r = C.evaluate(engagedCtx({ state = state, networkEnabled = false }), settings)
                assert.equals(STATE.IDLE, s)
                assert.equals(REASON.NETWORK_CLOSED, r)
                s, r = C.evaluate(engagedCtx({ state = state, distance = 600 }), settings)
                assert.equals(STATE.IDLE, s)
                assert.equals(REASON.OUT_OF_RANGE, r)
            end
        end)
        it("keeps CONNECTED without further checks", function()
            local s, r = C.evaluate(engagedCtx({ state = STATE.CONNECTED, operatorPresent = false, geometry = nil }), settings)
            assert.equals(STATE.CONNECTED, s)
            assert.equals(REASON.NONE, r)
        end)
        it("falls back to CONNECTED at once when the operator takes over or the engine stops", function()
            local cases = {
                { { operatorPresent = false }, REASON.OPERATOR_LEFT },
                { { operatorSteering = true }, REASON.OPERATOR_STEERING },
                { { operatorPedal = true }, REASON.OPERATOR_PEDAL },
                { { operatorCruise = true }, REASON.OPERATOR_CRUISE },
                { { motorStarted = false }, REASON.MOTOR_OFF },
            }
            for i, case in ipairs(cases) do
                local s, r, t, fault = C.evaluate(engagedCtx(case[1]), settings)
                assert.equals(STATE.CONNECTED, s, "case " .. i)
                assert.equals(case[2], r, "case " .. i)
                assert.equals(0, t)
                assert.equals(REASON.NONE, fault)
            end
        end)
        it("names every machine fault", function()
            local cases = {
                { { cartFull = true }, REASON.CART_FULL },
                { { leaderSpeed = -2 }, REASON.LEADER_REVERSING },
                { { leaderSpeed = 17 }, REASON.LEADER_TOO_FAST },
                { { leaderSpeed = 0 }, REASON.LEADER_STOPPED },
                { { leaderCurvature = 0.6 }, REASON.LEADER_TURNING },
                { { geometry = geometry({ headingError = math.rad(70) }) }, REASON.LEADER_TURNING },
                { { geometry = geometry({ lateralError = 16 }) }, REASON.POSITION_LOST },
                { { geometry = geometry({ alongError = -31 }) }, REASON.POSITION_LOST },
                { {}, REASON.NONE },
            }
            for i, case in ipairs(cases) do
                assert.equals(case[2], C.getFault(engagedCtx(case[1]), settings), "case " .. i)
            end
            settings.disengageOnCartFull = false
            assert.equals(REASON.NONE, C.getFault(engagedCtx({ cartFull = true }), settings))
        end)
        it("ends the sync only when a machine fault lasts for abortDelay", function()
            assert.equals(5000, settings.abortDelay)
            local ctx = engagedCtx({ leaderCurvature = 0.6, dt = 2000 })
            local s, r, t, fault = C.evaluate(ctx, settings)
            assert.equals(STATE.TRACKING, s)
            assert.equals(REASON.NONE, r)
            assert.equals(2000, t)
            assert.equals(REASON.LEADER_TURNING, fault)
            -- another fault keeps the count going
            ctx.abortTimer, ctx.leaderCurvature, ctx.leaderSpeed = t, 0, 0
            s, r, t, fault = C.evaluate(ctx, settings)
            assert.equals(4000, t)
            assert.equals(REASON.LEADER_STOPPED, fault)
            ctx.abortTimer = t
            s, r, t, fault = C.evaluate(ctx, settings)
            assert.equals(STATE.CONNECTED, s)
            assert.equals(REASON.LEADER_STOPPED, r)
            assert.equals(0, t)
            assert.equals(REASON.NONE, fault)
        end)
        it("keeps following during the delay and resets it once the fault is gone", function()
            local s, _, t, fault = C.evaluate(engagedCtx({ state = STATE.ACQUIRING, leaderSpeed = 0, abortTimer = 1000 }), settings)
            assert.equals(STATE.TRACKING, s)
            assert.equals(1016, t)
            assert.equals(REASON.LEADER_STOPPED, fault)
            s, _, t = C.evaluate(engagedCtx({ geometry = geometry({ lateralError = 16 }), abortTimer = 100 }), settings)
            assert.equals(STATE.ACQUIRING, s)
            assert.equals(116, t)
            local _, _, reset, none = C.evaluate(engagedCtx({ abortTimer = 4900 }), settings)
            assert.equals(0, reset)
            assert.equals(REASON.NONE, none)
        end)
        it("treats a missing dt / curvature / timer as zero", function()
            local ctx = engagedCtx({ leaderSpeed = 0 })
            ctx.dt, ctx.leaderCurvature, ctx.abortTimer = nil, nil, nil
            local s, _, t = C.evaluate(ctx, settings)
            assert.equals(STATE.TRACKING, s)
            assert.equals(0, t)
        end)
        it("switches ACQUIRING -> TRACKING within tolerance", function()
            local s = C.evaluate(engagedCtx({ state = STATE.ACQUIRING, geometry = geometry({ lateralError = 0.3, alongError = 0.8 }) }), settings)
            assert.equals(STATE.TRACKING, s)
            s = C.evaluate(engagedCtx({ state = STATE.ACQUIRING, geometry = geometry({ lateralError = 1, alongError = 0 }) }), settings)
            assert.equals(STATE.ACQUIRING, s)
        end)
        it("switches TRACKING -> ACQUIRING when the error grows", function()
            local s = C.evaluate(engagedCtx({ geometry = geometry({ lateralError = 3 }) }), settings)
            assert.equals(STATE.ACQUIRING, s)
            s = C.evaluate(engagedCtx({ geometry = geometry({ alongError = 5 }) }), settings)
            assert.equals(STATE.ACQUIRING, s)
            s = C.evaluate(engagedCtx({ geometry = geometry({ lateralError = 1 }) }), settings)
            assert.equals(STATE.TRACKING, s)
        end)
    end)

    describe("control law", function()
        it("scales the look-ahead with speed", function()
            assert.equals(settings.lookAheadMin, C.getLookAhead(2, settings))
            assert.near(12 * settings.lookAheadPerKmh, C.getLookAhead(12, settings))
            assert.equals(settings.lookAheadMax, C.getLookAhead(40, settings))
        end)
        it("matches the leader speed without error", function()
            assert.near(8, C.getTargetSpeed(STATE.TRACKING, 8, 0, settings))
        end)
        it("speeds up when behind and slows down when ahead", function()
            assert.near(8 + 1.2, C.getTargetSpeed(STATE.TRACKING, 8, -1, settings))
            assert.near(8 - 1.2, C.getTargetSpeed(STATE.TRACKING, 8, 1, settings))
        end)
        it("limits the correction per state", function()
            assert.near(8 + settings.maxTrackingCorrection, C.getTargetSpeed(STATE.TRACKING, 8, -20, settings))
            assert.near(8 + settings.maxCatchUpSpeed, C.getTargetSpeed(STATE.ACQUIRING, 8, -20, settings))
        end)
        it("never commands negative speeds and stops below stopSpeed", function()
            assert.equals(0, C.getTargetSpeed(STATE.ACQUIRING, 2, 10, settings))
            assert.equals(0, C.getTargetSpeed(STATE.TRACKING, 0.7, 0.2, settings))
        end)
        it("stands still with a standing leader unless the cart is behind", function()
            assert.equals(0, C.getTargetSpeed(STATE.TRACKING, 0, 0, settings))
            assert.near(3, C.getTargetSpeed(STATE.TRACKING, 0, -5, settings))
        end)
        it("steers towards the home line", function()
            local leader = { x = 0, z = 0, heading = 0, speed = 8 }
            -- follower 2 m too far left -> steer right (negative curvature)
            local follower = { x = 9, z = 8, heading = 0, speed = 8 }
            local g = C.computeGeometry(leader, follower, nil, { x = 7, z = 8 })
            local cmd = C.computeCommand(STATE.ACQUIRING, leader, follower, g, { x = 7, z = 8 }, settings)
            assert.is_less(0, cmd.curvature)
            assert.is_false(cmd.brake)
            -- follower too far right -> steer left
            follower.x = 5
            g = C.computeGeometry(leader, follower, nil, { x = 7, z = 8 })
            cmd = C.computeCommand(STATE.ACQUIRING, leader, follower, g, { x = 7, z = 8 }, settings)
            assert.is_greater(0, cmd.curvature)
        end)
        it("drives straight on the line and brakes with a standing leader", function()
            local leader = { x = 0, z = 0, heading = 0.4, speed = 0 }
            local wx, wz = VehicleSyncMath.localToWorld(0, 0, 0.4, 7, 8)
            local follower = { x = wx, z = wz, heading = 0.4, speed = 0 }
            local g = C.computeGeometry(leader, follower, nil, { x = 7, z = 8 })
            local cmd = C.computeCommand(STATE.TRACKING, leader, follower, g, { x = 7, z = 8 }, settings)
            assert.near(0, cmd.curvature, 1e-9)
            assert.is_true(cmd.brake)
            assert.equals(settings.lookAheadMin, cmd.lookAhead)
        end)
        it("tolerates a missing follower speed", function()
            local leader = { x = 0, z = 0, heading = 0, speed = 12 }
            local follower = { x = 7, z = 8, heading = 0 }
            local g = C.computeGeometry(leader, follower, nil, { x = 7, z = 8 })
            local cmd = C.computeCommand(STATE.TRACKING, leader, follower, g, { x = 7, z = 8 }, settings)
            assert.near(12 * settings.lookAheadPerKmh, cmd.lookAhead)
        end)
    end)

    describe("closed loop simulation", function()
        -- kinematic bicycle model driven by the controller: the cart must converge to the home point
        it("converges from an offset start and stays stable", function()
            local home = { x = 7, z = 2 }
            local leader = { x = 0, z = 0, heading = 0, speed = 8 }
            local follower = { x = 11, z = -6, heading = 0.15, speed = 5 }
            local trail = 6
            local state = STATE.ACQUIRING
            local dt = 0.05
            local wheelBase = 3
            for _ = 1, 1200 do
                local cartX, cartZ = VehicleSyncMath.localToWorld(follower.x, follower.z, follower.heading, 0, -trail)
                local g = C.computeGeometry(leader, follower, { x = cartX, z = cartZ }, home)
                state = C.evaluate({ state = state, dt = dt * 1000, leaderExists = true, networkEnabled = true,
                    distance = g.distance, operatorPresent = true, motorStarted = true, leaderSpeed = leader.speed,
                    leaderCurvature = 0, geometry = g, abortTimer = 0 }, settings)
                assert.is_true(C.isEngaged(state), "sync dropped")
                local cmd = C.computeCommand(state, leader, follower, g, home, settings)
                -- speed responds with a first order lag, steering is limited to 0.2 1/m
                follower.speed = follower.speed + (cmd.targetSpeed - follower.speed) * math.min(1, dt * 2)
                local curvature = VehicleSyncMath.clamp(cmd.curvature, -0.2, 0.2)
                local v = follower.speed / 3.6
                -- positive curvature turns left, i.e. increases the heading (forward = (sin h, cos h))
                follower.heading = follower.heading + v * curvature * dt
                follower.x = follower.x + math.sin(follower.heading) * v * dt
                follower.z = follower.z + math.cos(follower.heading) * v * dt
                leader.z = leader.z + leader.speed / 3.6 * dt
            end
            local cartX, cartZ = VehicleSyncMath.localToWorld(follower.x, follower.z, follower.heading, 0, -trail)
            local g = C.computeGeometry(leader, follower, { x = cartX, z = cartZ }, home)
            assert.equals(STATE.TRACKING, state)
            assert.near(0, g.lateralError, 0.3)
            assert.near(0, g.alongError, 0.5)
            assert.near(8, follower.speed, 0.5)
        end)
    end)

    describe("reason texts", function()
        it("maps reasons to l10n keys", function()
            assert.equals("vs_reason_cart_full", C.getReasonTextKey(REASON.CART_FULL))
            assert.is_nil(C.getReasonTextKey(REASON.NONE))
            assert.is_nil(C.getReasonTextKey(250))
        end)
        it("classifies warnings", function()
            assert.is_false(C.isWarningReason(REASON.CONNECTED))
            assert.is_false(C.isWarningReason(REASON.ENGAGED))
            assert.is_false(C.isWarningReason(REASON.HOME_SET))
            assert.is_true(C.isWarningReason(REASON.LEADER_TURNING))
            assert.is_true(C.isWarningReason(REASON.CART_FULL))
        end)
    end)
end)
