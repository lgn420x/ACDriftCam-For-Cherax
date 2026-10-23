-- =====================================================================
--
--    A C D R I F T C A M   -  LGN's drift camera & dashcam for Cherax  (v4)
--
-- =====================================================================
--  A standalone script in Cherax's own look - it doesn't need LGNFX. The cameras are LGNFX's own
--  (Vehicle > Cameras there): drift look, first person head cam with G-force, speed FOV zoom, speed shake,
--  speed blur, the dashcam and clear windows in first person - plus hotkeys for Camera Effects and the Dashcam.
--  INSTALL: put ACDriftCam.lua in your Cherax "Lua" folder.
--  FILES:   Lua\ACDriftCam - configs in Lua\ACDriftCam\configs (Settings tab: save, load, load on startup).
--  With LGNFX: if LGNFX's own camera effects or dashcam are switched on, ACDriftCam waits (so the two never
--  fight over the camera) - switch them off in LGNFX (Vehicle > Cameras) to use these.
-- =====================================================================

local AC_NAME = "ACDriftCam"
local AC_VERSION = "ACDriftCam v4"


-- ---------------------------------------------------------------------
-- core helpers (the same ones LGNFX uses)
-- ---------------------------------------------------------------------
local running = true
local function ShouldStop()
    if not running then return true end
    local ok, stop = pcall(ShouldUnload)
    return ok and stop == true
end
local Dump = {}
function Dump.Info(msg) pcall(Logger.LogInfo, tostring(msg)) end
local function LogErr(where, err)
    local msg = "[ACDriftCam] Error in " .. where .. ": " .. tostring(err)
    if not pcall(Logger.LogError, msg) then pcall(Logger.LogInfo, msg) end
end
local function Try(where, fn, ...)
    local ok, a, b = pcall(fn, ...)
    if not ok then LogErr(where, a) return nil end
    return a, b
end
local function J(s) return Utils.Joaat(s) end
-- every option of this script gets its own id ("AcDc_..."), so nothing clashes with LGNFX's (or anyone's)
local H = setmetatable({}, { __index = function(t, k)
    local v = Utils.Joaat("AcDc_" .. tostring(k))
    rawset(t, k, v)
    return v
end })
local F = { unloadHooks = {} }

local function NowMs()
    local ok, t = pcall(Time.GetEpocheMs)
    if ok and t then return t end
    local ok2, s = pcall(Time.Get)
    if ok2 and s then return s * 1000 end
    return 0
end
-- messages: Cherax's own popups
local function Notify(text)
    text = tostring(text)
    pcall(Logger.LogInfo, "[ACDriftCam] " .. text)
    pcall(GUI.AddToast, AC_NAME, text, 3000, eToastPos.BOTTOM_RIGHT)
end
-- Buttons ignore a second press within 0.4s (stops double-clicks / double callbacks doing things twice)
local function Button(hash, name, desc, fn)
    local last = -100000
    return FeatureMgr.AddFeature(hash, name, eFeatureType.Button, desc, function(...)
        local now = NowMs()
        if now - last < 400 then return end
        last = now
        return fn(...)
    end)
end

-- on-screen drawing that has to be asked for every frame (the dashcam's text): kept for ms, drawn by the loop
local HUD = { keep = {} }
F.hudKeep = function(key, fn, ms) HUD.keep[key] = { fn = fn, untilAt = NowMs() + (ms or 250) } end
function HUD.Frame(now)
    for k, v in pairs(HUD.keep) do
        if now <= v.untilAt then
            local ok, err = pcall(v.fn)
            if not ok and not HUD["err_" .. k] then HUD["err_" .. k] = true LogErr(k, err) end
        else
            HUD.keep[k] = nil
        end
    end
end
-- the game's own text and boxes (the same as LGNFX's: font, size, colour, left / centre / right)
do
    local function nv(...) pcall(Natives.InvokeVoid, ...) end
    F.hudText = function(s, x, y, scale, r, g, b, a, font, wrapTo, just)
        just = just or 1
        nv(0x66E0276CC5F6B9DA, font or 4)               -- SET_TEXT_FONT
        nv(0x07C837F9A01C34C9, 0.0, scale + 0.0)        -- SET_TEXT_SCALE
        nv(0xBE6B23FFA53FB442, r, g, b, a)              -- SET_TEXT_COLOUR
        nv(0x4E096588B13FFECA, just)                    -- SET_TEXT_JUSTIFICATION
        if just == 2 then nv(0x63145D9C883A1A70, 0.0, x + 0.0)        -- SET_TEXT_WRAP
        elseif wrapTo then nv(0x63145D9C883A1A70, 0.0, wrapTo + 0.0) end
        nv(0x1CA3E9EAC9D93E5E)                          -- SET_TEXT_DROP_SHADOW
        nv(0x25FBB336DF1804CB, "STRING")                -- BEGIN_TEXT_COMMAND_DISPLAY_TEXT
        nv(0x6C188BE134E074AA, s)                       -- ADD_TEXT_COMPONENT_SUBSTRING_PLAYER_NAME
        nv(0xCD015E5BB0D96A57, x + 0.0, y + 0.0, 0)     -- END_TEXT_COMMAND_DISPLAY_TEXT
    end
    F.hudRect = function(x, y, w, h, r, g, b, a)
        if a < 1 or w <= 0 or h <= 0 then return end
        nv(0x3A618A217E5154F0, x + 0.0, y + 0.0, w + 0.0, h + 0.0, r, g, b, math.floor(math.min(255, a)), false) -- DRAW_RECT
    end
end
-- WAITING FOR LGNFX: while LGNFX's own camera effects, dashcam or speed blur are on, these wait (two scripts
-- moving the camera at once would fight). F.On is what the cameras below ask instead of "is it switched on?"
F._wait = false
F.On = function(k) local f = F[k] return f ~= nil and f:IsToggled() and not F._wait end


local FeatureMgr = (function(cherax)
    local info = {}
    return setmetatable({
        info = info, -- hash -> { name, desc }
        AddFeature = function(hash, name, ftype, desc, ...)
            info[hash] = { name = name, desc = desc }
            return cherax.AddFeature(hash, name, ftype, desc, ...)
        end,
    }, { __index = cherax })
end)(FeatureMgr)

local function IB(...)
    local r = Natives.InvokeBool(...)
    if type(r) == "number" then return r ~= 0 end
    return r == true
end

F.notMyCar = function(v)
    if not v or v == 0 then return false end
    local okM, me = pcall(Natives.InvokeInt, 0xD80958FC74E988A6) -- PLAYER_PED_ID
    local okD, d = pcall(Natives.InvokeInt, 0xBB40DD2270B65366, v, -1, false) -- GET_PED_IN_VEHICLE_SEAT
    if okD and d and d ~= 0 and d ~= (okM and me or -1) and IB(0x12534C348C6CB68B, d) then return true end -- IS_PED_A_PLAYER
    local ok, res = pcall(function()
        if not IB(0x05661B80A8C9165F, v, "Player_Vehicle") then return false end -- DECOR_EXIST_ON
        local owner = Natives.InvokeInt(0xA06C969B02A97298, v, "Player_Vehicle") -- DECOR_GET_INT
        local mine = Natives.InvokeInt(0xBC1D768F2F5D6C05, Natives.InvokeInt(0x4F8644AF03D0E0D6)) -- NETWORK_HASH_FROM_PLAYER_HANDLE(PLAYER_ID)
        return owner ~= nil and owner ~= 0 and owner ~= -1 and owner ~= mine
    end)
    return ok and res == true
end
-- true while you're typing (GTA Online text chat, or the game's on-screen keyboard) -
-- hotkeys do nothing then, so typing a message can't set anything off
-- Also while the LGNFX command bar is open, and while you're typing in a text box in Cherax's menu
-- (plus a moment after, so the Enter / Esc that finished typing doesn't set a hotkey off)
F.uiTypingUntil = 0
F.Typing = function()
    if F.cmdOpen then return true end
    local okT, t = pcall(Time.GetEpocheMs)
    if okT and t and t < (F.uiTypingUntil or 0) then return true end
    local ok, chat = pcall(IB, 0xB118AF58B5F332A1) -- IS_MP_TEXT_CHAT_TYPING
    if ok and chat then return true end
    local ok2, kb = pcall(Natives.InvokeInt, 0x0CF2B696BBF945AE) -- UPDATE_ONSCREEN_KEYBOARD (0 = typing)
    return ok2 and kb == 0
end
-- (called every frame from the drawing event: is a Cherax menu text box / slider being used right now?)
F.NoteUiTyping = function()
    local okO, open = pcall(GUI.IsOpen)
    if not (okO and open) then return end
    local okA, active = pcall(ImGui.IsAnyItemActive)
    if okA and active then
        local okT, t = pcall(Time.GetEpocheMs)
        if okT and t then F.uiTypingUntil = t + 300 end
    end
end


local function ToPos(p)
    if not p then return nil end
    return { x = p.x + 0.0, y = p.y + 0.0, z = p.z + 0.0 }
end
-- a vector native's result as x, y, z (or nil)
F.V3xyz = function(...)
    local ok, a, b, c = pcall(Natives.InvokeV3, ...)
    if not ok or a == nil then return nil end
    if type(a) == "number" then return a, b, c end
    return a.x, a.y, a.z
end

local function EntityPos(h)
    if not h or h == 0 then return nil end
    local ok, p = pcall(function()
        local e = GTA.HandleToPointer(h)
        return e and e.Position
    end)
    if ok and p then return ToPos(p) end
    local ok2, a, b, c = pcall(Natives.InvokeV3, 0x3FEF770D40960D5A, h, true) -- GET_ENTITY_COORDS
    if ok2 and a then
        if type(a) == "number" then
            if b and c then return { x = a + 0.0, y = b + 0.0, z = c + 0.0 } end
        else
            local okT, t = pcall(ToPos, a)
            if okT then return t end
        end
    end
    return nil
end

local function TrimSlash(p) return (p:gsub("[\\/]+$", "")) end

local function LuaDir() return TrimSlash(FileMgr.GetMenuRootPath()) .. "\\Lua" end

-- WHERE ITS FILES LIVE: Lua\ACDriftCam (configs in Lua\ACDriftCam\configs)
local function CfgDir()
    local base = LuaDir() .. "\\ACDriftCam"
    pcall(FileMgr.CreateDir, base)
    return base
end
pcall(CfgDir)

local function Slider(hash, name, ftype, desc, min, max, step, default)
    local f = FeatureMgr.AddFeature(hash, name, ftype, desc)
    f:SetLimitValues(min, max)
    f:SetStepSize(step)
    f:SetDefaultValue(default)
    if ftype == eFeatureType.SliderInt then f:SetIntValue(default) else f:SetFloatValue(default) end
    return f
end

local function Toggle(hash, name, desc, default)
    local f = FeatureMgr.AddFeature(hash, name, eFeatureType.Toggle, desc)
    f:SetDefaultValue(default)
    f:SetBoolValue(default)
    F._bind = F._bind or {}
    F._bind[hash] = { name = name, kind = "toggle", f = f } -- for the Hotkeys page
    return f
end

-- Speed Units (the dashcam's speed): mph or km/h
F.speedoUnit = FeatureMgr.AddFeature(H.speedoUnit, "Speed Units", eFeatureType.Combo, "What the dashcam's speed is shown in")
F.speedoUnit:SetList({ "MPH", "KM/H" })

Try("creating driving helpers", function()
    local N = {
        PLAYER_PED_ID                   = 0xD80958FC74E988A6,
        GET_VEHICLE_PED_IS_IN           = 0x9A9112A0FE9A4713,
        GET_PED_IN_VEHICLE_SEAT         = 0xBB40DD2270B65366,
        IS_PED_IN_ANY_VEHICLE           = 0x997ABD671D25CA0B,
        GET_MODEL_DIMENSIONS            = 0x03E8D3D5F549087A,
    }
    local X = {}
    F.LX = X
    F.hudDraws = F.hudDraws or {}
    F.unloadHooks = F.unloadHooks or {}

    function X.Me()
        local ok, me = pcall(Natives.InvokeInt, N.PLAYER_PED_ID)
        return (ok and me and me ~= 0) and me or nil
    end
    -- the car you're in: car, you, are you the driver
    function X.Car()
        local me = X.Me()
        if not me or not IB(N.IS_PED_IN_ANY_VEHICLE, me, false) then return nil, me, false end
        local veh = Natives.InvokeInt(N.GET_VEHICLE_PED_IS_IN, me, false)
        if not veh or veh == 0 then return nil, me, false end
        return veh, me, Natives.InvokeInt(N.GET_PED_IN_VEHICLE_SEAT, veh, -1, false) == me
    end
    local dimCache = {}
    -- model size: minX, minY, minZ, maxX, maxY, maxZ
    function X.Dims(model)
        local d = dimCache[model]
        if d then return d[1], d[2], d[3], d[4], d[5], d[6] end
        local out = { -1.0, -2.3, -0.6, 1.0, 2.3, 1.0 }
        pcall(function()
            local a, b = Memory.Alloc(32), Memory.Alloc(32)
            Natives.InvokeVoid(N.GET_MODEL_DIMENSIONS, model, a, b)
            local v = { Memory.ReadFloat(a), Memory.ReadFloat(a + 8), Memory.ReadFloat(a + 16),
                        Memory.ReadFloat(b), Memory.ReadFloat(b + 8), Memory.ReadFloat(b + 16) }
            Memory.Free(a) Memory.Free(b)
            if v[1] and v[5] and v[5] > v[2] and v[5] - v[2] < 40 then out = v end
        end)
        dimCache[model] = out
        return out[1], out[2], out[3], out[4], out[5], out[6]
    end
    -- keys (never while you're typing in chat)
    function X.Key(vk) return vk and vk > 0 and Utils.IsKeyDown(vk) and not F.Typing() end
    -- speed in the speedometer's units
    function X.SpeedText(ms)
        if (F.speedoUnit:GetListIndex() or 0) == 0 then return ("%d MPH"):format(math.floor(ms * 2.23694 + 0.5)) end
        return ("%d KM/H"):format(math.floor(ms * 3.6 + 0.5))
    end
    X.KEYS = {
        { "Left Shift", 0xA0 }, { "Left Ctrl", 0xA2 }, { "Left Alt", 0xA4 }, { "Caps Lock", 0x14 },
        { "Q", 0x51 }, { "E", 0x45 }, { "Z", 0x5A }, { "X", 0x58 }, { "C", 0x43 }, { "B", 0x42 },
        { "Mouse Side 1", 0x05 }, { "Mouse Side 2", 0x06 }, { "Page Up", 0x21 }, { "Page Down", 0x22 },
        { "Up Arrow", 0x26 }, { "Down Arrow", 0x28 }, { "Numpad +", 0x6B }, { "Numpad -", 0x6D },
        { "Numpad 0", 0x60 }, { "Numpad Enter / Enter", 0x0D }, { "Right Shift", 0xA1 }, { "Right Ctrl", 0xA3 },
    }
    X.KEY_NAMES = {}
    for i, k in ipairs(X.KEYS) do X.KEY_NAMES[i] = k[1] end
end)

Try("creating wheel bridge", function()
    local B = { look = J("LgnWhl_Bridge_LookOff") }
    local function Get(h) local ok, f = pcall(FeatureMgr.GetFeature, h) return ok and f or nil end
    F.wheelLookOff = function()
        local f = Get(B.look)
        local ok, on = pcall(function() return f and f:IsToggled() end)
        return ok and on == true
    end
end)

Try("creating drift camera", function()
    local N = {
        PLAYER_PED_ID                      = 0xD80958FC74E988A6,
        GET_VEHICLE_PED_IS_IN              = 0x9A9112A0FE9A4713,
        IS_PED_IN_ANY_VEHICLE              = 0x997ABD671D25CA0B,
        GET_ENTITY_SPEED_VECTOR            = 0x9A8D700A51CB7B0D,
        GET_ENTITY_VELOCITY                = 0x4805D2B1D8CF94A9,
        GET_ENTITY_FORWARD_VECTOR          = 0x0A794A5A57F8DF91,
        GET_ENTITY_ROTATION                = 0xAFBD61CC738D9EB9,
        GET_PED_BONE_COORDS                = 0x17C07FC640E86B4E,
        GET_OFFSET_FROM_ENTITY_GIVEN_WORLD_COORDS = 0x2274BC1C4885E333,
        GET_CAM_ACTIVE_VIEW_MODE_CONTEXT   = 0x19CAFA3C87F7C2FF,
        GET_CAM_VIEW_MODE_FOR_CONTEXT      = 0xEE778F8C7E1142E2,
        GET_GAMEPLAY_CAM_FOV               = 0x65019750A0324133,
        SET_GAMEPLAY_CAM_RELATIVE_HEADING  = 0xB4EC2312F4E5B1F1,
        GET_GAMEPLAY_CAM_RELATIVE_HEADING  = 0x743607648ADD4587,
        SHAKE_GAMEPLAY_CAM                 = 0xFD55E49555E017CF,
        SET_GAMEPLAY_CAM_SHAKE_AMPLITUDE   = 0xA87E00932DB4D85D,
        STOP_GAMEPLAY_CAM_SHAKING          = 0x0EF93E9F3D08C178,
        CREATE_CAM                         = 0xC3981DCE61D9E13F,
        DESTROY_CAM                        = 0x865908C81A2C22E9,
        DOES_CAM_EXIST                     = 0xA7A932170592B50E,
        SET_CAM_ACTIVE                     = 0x026FB97D0A425F84,
        RENDER_SCRIPT_CAMS                 = 0x07E5B515DB0636FC,
        ATTACH_CAM_TO_ENTITY               = 0xFEDB7D269E8C60E3,
        HARD_ATTACH_CAM_TO_ENTITY          = 0x202A5ED9CE01D6E7,
        SET_CAM_ROT                        = 0x85973643155D0B07,
        SET_CAM_FOV                        = 0xB13C14F66A00D047,
        SET_CAM_NEAR_CLIP                  = 0xC7848EFCCC545182,
        STOP_CAM_SHAKING                   = 0xBDECF64367884AC3,
        GET_CONTROL_NORMAL                 = 0xEC3C9B8D5327B563,
        GET_DISABLED_CONTROL_NORMAL        = 0x11E65974A982637C,
        IS_CONTROL_PRESSED                 = 0xF3A21BCD95725A4A,
        IS_DISABLED_CONTROL_PRESSED        = 0xE2587F8CBBD87B1D,
        IS_USING_KEYBOARD_AND_MOUSE        = 0xA571D46727E2B718,
        IS_PAUSE_MENU_ACTIVE               = 0xB0034A223497FFCB,
        SET_ENTITY_LOCALLY_INVISIBLE       = 0xE135A9FF3F5D05D8,
        SET_PED_CAN_HEAD_IK                = 0xC11C18092C5530DC,
        SET_LOCAL_PLAYER_INVISIBLE_LOCALLY = 0xE5F773C1A1D9D168,
        SET_ENTITY_VISIBLE                 = 0xEA1C610A04DB6BBB,
        SET_ENTITY_ALPHA                   = 0x44A0870B7E92D7C0,
        RESET_ENTITY_ALPHA                 = 0x9B1E824FFBB7027A,
        GET_FRAME_TIME                     = 0x15C40837039FFAF7,
        GET_FRAME_COUNT                    = 0xFC8202EFC642E6F2,
    }
    F.dcMaster = Toggle(H.dcMaster, "Camera Effects On (everything)",
        "Master switch for everything on this page: drift look, head cam, G-force, FOV, zoom, speed shake. " ..
        "Off = the normal game camera. Back on = all your settings come back as they were.", true)
    F.dcOn = Toggle(H.dcOn, "Drift Camera",
        "Like Assetto Corsa's neck FX: when you slide sideways the camera turns to look where the car is going", false)
    F.dcAmount = Slider(H.dcAmount, "Look Amount", eFeatureType.SliderFloat,
        "How far the camera turns into the drift (1.0 = looks right along where you're sliding)", 0.2, 1.2, 0.05, 0.75)
    F.dcMax = Slider(H.dcMax, "Max Look Angle", eFeatureType.SliderInt,
        "The furthest the camera will turn, in degrees", 15, 90, 5, 60)
    F.dcSmooth = Slider(H.dcSmooth, "Smoothness", eFeatureType.SliderInt,
        "Higher = slower, softer camera movement", 1, 10, 1, 5)
    F.dcThird = Toggle(H.dcThird, "Third Person Too", "Drift look and speed shake in the third person cameras too", true)
    F.dcG = Toggle(H.dcG, "G-Force Head Movement",
        "Your head tips back when you accelerate and forward when you brake - the harder, the more. " ..
        "Also leans in corners and drops on landings. Only the camera moves.", false)
    F.dcGAmt = Slider(H.dcGAmt, "G-Force Amount", eFeatureType.SliderFloat,
        "How much the G-forces move your head", 0.2, 2.5, 0.1, 1.0)
    F.dcBaseOn = Toggle(H.dcBaseOn, "Custom First Person FOV",
        "Use your own FOV for first person in vehicles (set it below) instead of the game's", false)
    F.dcBase = Slider(H.dcBase, "First Person FOV", eFeatureType.SliderInt,
        "Your first person FOV in vehicles when you're not speeding (the game's is about 50)", 35, 100, 1, 62)
    F.dcFov = Toggle(H.dcFov, "Speed FOV Zoom (first person)",
        "The view very gently widens the faster you go, for a sense of speed. Tweak it with the sliders below", true)
    F.dcFovAmt = Slider(H.dcFovAmt, "Zoom Amount", eFeatureType.SliderFloat,
        "How many degrees wider the view gets at full speed (2-4 = subtle, 8+ = strong)", 0.5, 15.0, 0.5, 3.0)
    F.dcFovStart = Slider(H.dcFovStart, "Zoom Starts At (mph)", eFeatureType.SliderInt,
        "Below this speed there's no zoom at all", 0, 150, 5, 40)
    F.dcFovFull = Slider(H.dcFovFull, "Full Zoom At (mph)", eFeatureType.SliderInt,
        "The speed where the zoom reaches its full amount", 30, 250, 5, 160)
    F.dcFovSmooth = Slider(H.dcFovSmooth, "Zoom Smoothness", eFeatureType.SliderInt,
        "How slowly and softly the zoom follows your speed (higher = softer, lazier)", 1, 10, 1, 7)
    F.dcFovMax = Slider(H.dcFovMax, "Max FOV", eFeatureType.SliderInt,
        "The widest the view is ever allowed to get (lower it if you start seeing outside the car). " ..
        "Must be above First Person FOV or Speed FOV has no room to widen", 40, 130, 1, 75)
    F.dcCamFwd = Slider(H.dcCamFwd, "Head Cam Forward", eFeatureType.SliderFloat,
        "Moves the first person camera forward (+) or back (-) in metres. Raise it if you can see your own head", -0.10, 0.40, 0.01, 0.0)
    F.dcCamUp = Slider(H.dcCamUp, "Head Cam Height", eFeatureType.SliderFloat,
        "Moves the first person camera up (+) or down (-) in metres", -0.20, 0.20, 0.01, 0.0)
    F.dcLock = Toggle(H.dcLock, "Lock Camera To Car (smoother)",
        "Moves the first person camera in the same step as the car, so it can't twitch. Turn off only if the view " ..
        "looks tilted or wrong on your game version", true)
    F.dcHide = Toggle(H.dcHide, "Hide My Character (first person)",
        "Hides your character while the head cam is on, so you never see your face or hair " ..
        "(your hands on the wheel disappear too). Pick how below.", false)
    F.dcHideMode = FeatureMgr.AddFeature(H.dcHideMode, "Hide Mode", eFeatureType.Combo,
        "Invisible = works for sure, but other players can't see you either while it's on. " ..
        "See-through = you're faded to nothing (other players may see you faded too). " ..
        "My screen only = others always see you, but the game sometimes ignores it.")
    F.dcHideMode:SetList({ "Invisible (always works)", "See-through", "My screen only" })
    F.dcSpeed = Toggle(H.dcSpeed, "Speed Shake",
        "A road vibration that builds up the faster you go", false)
    F.dcSpeedAmt = Slider(H.dcSpeedAmt, "Speed Shake Amount", eFeatureType.SliderFloat,
        "How strong the speed vibration gets", 0.1, 2.0, 0.1, 0.8)

    local V3 = F.V3xyz
    local function MenuOpen() local ok, o = pcall(GUI.IsOpen) return ok and o == true end
    local function Ease(cur, target, dt, tau) return cur + (target - cur) * (1 - math.exp(-dt / tau)) end
    local function Wrap(a) while a > 180 do a = a - 360 end while a < -180 do a = a + 360 end return a end
    local function Clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
    -- a soft spring: starts moving gently and settles gently (a plain ease starts moving at
    -- full speed the instant its target changes - that sudden start is what looked like a jump)
    local function NewSpring(x) return { x = x or 0.0, v = 0.0 } end
    local function Spring(sp, target, dt, tau)
        local w = 2.4 / tau
        local n = math.max(1, math.ceil(dt / 0.008))
        local h = dt / n
        for _ = 1, n do
            sp.v = sp.v + (w * w * (target - sp.x) - 2 * w * sp.v) * h
            sp.x = sp.x + sp.v * h
        end
        return sp.x
    end
    local function Median3(a, b, c)
        if a > b then a, b = b, a end
        if b > c then b = c end
        return math.max(a, b)
    end

    -- shared motion state
    local lastT, prevV, aLong, aLat, jolt, lastJolt = 0, nil, 0.0, 0.0, 0.0, 0
    local lastFrame = nil
    local hLong, hLat = { 0.0, 0.0, 0.0 }, { 0.0, 0.0, 0.0 } -- last 3 raw readings (odd single frames are thrown away)
    -- smoothing state: filtered slide angle, corner lean, camera turn speed, car pitch / roll
    local slipF, aLatS, headVel, carP, carR = 0.0, 0.0, 0.0, nil, nil
    local headOffSince = nil
    local fovSpeed, fovVel = 0.0, 0.0
    local fovSlow, fovSlowV = 0.0, 0.0 -- (the speed the zoom follows: extra smooth)
    local shakeAmp, shakeP, shakeY, shakeR = 0.0, 0.0, 0.0, 0.0
    local backward, lookFrames, userUntil = false, 0, 0
    local head = 0.0 -- drift look angle (+ = left)

    -- ================= FIRST PERSON HEAD CAMERA =================
    local cam, camVeh = nil, nil
    local eye, baseFov, fovExtra = nil, 50.0, 0.0
    local gPitch, gRoll, gSurge, gSide, drop = 0.0, 0.0, 0.0, 0.0, 0.0
    local spP, spR, spS, spX = NewSpring(), NewSpring(), NewSpring(), NewSpring()
    local spEye = nil -- { x, y, z springs }
    -- where your head sits in this car (learnt while you're slow / stopped, kept while you drive)
    local seat = nil -- { veh, x, y, z }
    local spCarP, spCarR = nil, nil
    local freeYaw, freePitch, lastFree = 0.0, 0.0, 0
    local camShake = false
    local camPed = nil
    local camFwd = 0.22
    local HideStep
    -- hiding your character (and always putting you back)
    local hidden = nil -- { ped, mode }
    local function Unhide()
        if not hidden then return end
        local h = hidden
        hidden = nil
        if h.mode == 0 then pcall(Natives.InvokeVoid, N.SET_ENTITY_VISIBLE, h.ped, true, false)
        elseif h.mode == 1 then pcall(Natives.InvokeVoid, N.RESET_ENTITY_ALPHA, h.ped) end
    end
    F.dcUnhide = Unhide
    HideStep = function(ped, mode)
        if hidden and (hidden.ped ~= ped or hidden.mode ~= mode) then Unhide() end
        if mode < 0 then return end
        if mode == 0 then
            Natives.InvokeVoid(N.SET_ENTITY_VISIBLE, ped, false, false)
        elseif mode == 1 then
            Natives.InvokeVoid(N.SET_ENTITY_ALPHA, ped, 0, false)
        else
            Natives.InvokeVoid(N.SET_LOCAL_PLAYER_INVISIBLE_LOCALLY, false)
            Natives.InvokeVoid(N.SET_ENTITY_LOCALLY_INVISIBLE, ped)
        end
        hidden = { ped = ped, mode = mode }
    end
    local function CamOff()
        Unhide()
        if camPed then pcall(Natives.InvokeVoid, N.SET_PED_CAN_HEAD_IK, camPed, true) camPed = nil end
        if not cam then return end
        pcall(Natives.InvokeVoid, N.RENDER_SCRIPT_CAMS, false, false, 0, true, false)
        pcall(Natives.InvokeVoid, N.DESTROY_CAM, cam, false)
        cam, camVeh, eye, camShake = nil, nil, nil, false
        spEye = nil
    end
    F.dcCamOff = CamOff
    local lastCamCar = nil
    local function CamOn(veh)
        if cam and camVeh == veh and IB(N.DOES_CAM_EXIST, cam) then return true end
        CamOff()
        baseFov = Natives.InvokeFloat(N.GET_GAMEPLAY_CAM_FOV) or 50.0
        if baseFov < 20 or baseFov > 120 then baseFov = 50.0 end
        local c = Natives.InvokeInt(N.CREATE_CAM, "DEFAULT_SCRIPTED_CAMERA", true)
        if not c or c == 0 then return false end
        cam, camVeh = c, veh
        Natives.InvokeVoid(N.SET_CAM_NEAR_CLIP, cam, 0.05)
        Natives.InvokeVoid(N.SET_CAM_FOV, cam, baseFov + 0.0)
        Natives.InvokeVoid(N.SET_CAM_ACTIVE, cam, true)
        Natives.InvokeVoid(N.RENDER_SCRIPT_CAMS, true, false, 0, true, false)
        -- same car as before (the camera was only let go for a moment): carry on exactly where
        -- it was instead of snapping everything back to the middle (that snap was a twitch)
        if veh ~= lastCamCar then
            head, freeYaw, freePitch, fovExtra = 0.0, 0.0, 0.0, 0.0
            headVel, carP, carR = 0.0, nil, nil
            spCarP, spCarR = nil, nil
            fovVel = 0.0
            gPitch, gRoll, gSurge, gSide, drop = 0.0, 0.0, 0.0, 0.0, 0.0
            spP, spR, spS, spX = NewSpring(), NewSpring(), NewSpring(), NewSpring()
        end
        lastCamCar = veh
        return true
    end

    local function HeadCam(ped, veh, dt, now, speed, vx, vy, look, gOn, fovOn, spOn)
        if not CamOn(veh) then return false end
        local g = gOn and (F.dcGAmt:GetFloatValue() or 1.0) or 0.0

        -- where your eyes are (follows your character's head slowly, so it's steady)
        -- (follows the head closely so it can't lean into view)
        local hx, hy, hz = V3(N.GET_PED_BONE_COORDS, ped, 31086, 0.0, 0.0, 0.0) -- SKEL_Head
        -- The game hands back your head's position from a moment before the car's, so the
        -- faster you go the further behind (and, sliding, the further sideways) it reads -
        -- that's what pulled the camera back through the seat at speed. So where your head
        -- sits in the car is only learnt while you're going slowly, and held while you drive.
        if hx then
            local ox, oy, oz = V3(N.GET_OFFSET_FROM_ENTITY_GIVEN_WORLD_COORDS, veh, hx, hy, hz)
            if ox then
                local slow = speed < 2.0
                if not seat or seat.veh ~= veh then
                    -- first time in this car and already moving: take the lag back out
                    local lag = slow and 0.0 or dt
                    seat = { veh = veh, x = ox + (vx or 0.0) * lag, y = oy + (vy or 0.0) * lag, z = oz }
                elseif slow then
                    seat.x = Ease(seat.x, ox, dt, 0.5)
                    seat.y = Ease(seat.y, oy, dt, 0.5)
                    seat.z = Ease(seat.z, oz, dt, 0.5)
                end
            end
        end
        if seat and seat.veh == veh then
            -- anchored to the middle of the skull, far enough forward that the face is
            -- always behind the camera
            local fwd = 0.22 + (F.dcCamFwd:GetFloatValue() or 0.0)
            local up = 0.07 + (F.dcCamUp:GetFloatValue() or 0.0)
            camFwd = fwd
            local tx, ty, tz = seat.x, seat.y, seat.z + up
            if not spEye or not eye then
                spEye = { NewSpring(tx), NewSpring(ty), NewSpring(tz) }
                eye = { tx, ty, tz }
            else
                eye[1] = Spring(spEye[1], tx, dt, 0.30)
                eye[2] = Spring(spEye[2], ty, dt, 0.30)
                eye[3] = Spring(spEye[3], tz, dt, 0.30)
            end
        end
        if not eye then return false end
        HideStep(ped, F.dcHide:IsToggled() and (F.dcHideMode:GetListIndex() or 0) or -1)
        -- stop your character turning his head to look at things (that's what swung his face into view)
        if not camPed then camPed = ped Natives.InvokeVoid(N.SET_PED_CAN_HEAD_IK, ped, false) end

        -- your own looking around (mouse / right stick), then it eases back to the front
        local kbm = IB(N.IS_USING_KEYBOARD_AND_MOUSE, 2)
        local lx = Natives.InvokeFloat(N.GET_DISABLED_CONTROL_NORMAL, 0, 1) or 0
        local ly = Natives.InvokeFloat(N.GET_DISABLED_CONTROL_NORMAL, 0, 2) or 0
        -- (Wheel & Pedals: a pedal on the right stick mustn't swing the head cam)
        if not kbm and F.wheelLookOff and F.wheelLookOff() then lx, ly = 0, 0 end
        local sens = kbm and 10.0 or (200.0 * dt)
        local menuOpen = MenuOpen()
        if menuOpen then
            -- the Cherax menu is open: the mouse is for the menu, so your view stays put
            lastFree = now
        elseif math.abs(lx) > 0.02 or math.abs(ly) > 0.02 then
            freeYaw = Clamp(freeYaw - lx * sens, -150, 150)
            freePitch = Clamp(freePitch - ly * sens, -50, 35)
            lastFree = now
        elseif now - lastFree > 1200 then
            freeYaw = Ease(freeYaw, 0.0, dt, 0.35)
            freePitch = Ease(freePitch, 0.0, dt, 0.35)
        end
        local behind = IB(N.IS_CONTROL_PRESSED, 0, 79) or IB(N.IS_DISABLED_CONTROL_PRESSED, 0, 79)
            or (F.lookBackDown and F.lookBackDown()) -- (GTA's look behind - C - or the Look Back Key)

        -- G-forces on your head (harder braking / acceleration = more)
        local pT = Clamp(aLong * 7.0 * g, -16, 10)             -- + = tips back (looks up)
        local rT = Clamp(-aLat * 3.5 * g, -7, 7)               -- leans against the turn
        local sT = Clamp(-aLong * 0.035 * g, -0.07, 0.07)      -- head pushed back / thrown forward
        local xT = Clamp(-aLat * 0.02 * g, -0.03, 0.03)        -- head pushed to the side (a little: the window's close)
        gPitch = Spring(spP, pT, dt, 0.24)
        gRoll = Spring(spR, rT, dt, 0.26)
        gSurge = Spring(spS, sT, dt, 0.30)
        gSide = Spring(spX, xT, dt, 0.26)
        if jolt > 0 then drop = drop - math.min(0.08, jolt * 0.03) * g jolt = 0 end
        drop = Ease(drop, 0.0, dt, 0.18)

        -- camera angle = the car's angle (horizon partly steadied, like a real neck) + head movement
        local rawP, rawR, rz = V3(N.GET_ENTITY_ROTATION, veh, 2)
        rawP, rawR, rz = rawP or 0.0, rawR or 0.0, rz or 0.0
        -- the car's own tilt is smoothed a touch (bumps don't rattle your view), turning isn't
        if not spCarP then spCarP, spCarR = NewSpring(rawP), NewSpring(rawR) end
        carP = Spring(spCarP, rawP, dt, 0.12)
        carR = Spring(spCarR, rawR, dt, 0.12)
        local relYaw = head + (behind and 180 or freeYaw) + shakeY
        local relPitch = gPitch + (behind and 0 or freePitch) + drop * 60 + shakeP

        -- the camera swings round the middle of the head like a real neck, so however far you
        -- look your own head stays behind the camera. When you look back past the side it
        -- doesn't swing out behind your head (that pushed it into the seat) - it stays over
        -- your head and the near-clip grows so your own head / the headrest aren't drawn.
        local ry_, rp_ = math.rad(relYaw), math.rad(relPitch)
        -- (only a small sideways swing: a big one pushed the camera out through the door window)
        local cx = -math.sin(ry_) * math.cos(rp_) * camFwd * 0.35
        local cy = math.max(0.0, math.cos(ry_)) * math.cos(rp_) * camFwd
        local cz = math.sin(rp_) * camFwd
        local side = math.min(1, math.abs(Wrap(relYaw)) / 150)
        Natives.InvokeVoid(N.SET_CAM_NEAR_CLIP, cam, 0.05 + 0.17 * side * side)
        local ox, oy, oz = eye[1] + cx + gSide, eye[2] + cy + gSurge, eye[3] + cz + drop
        if F.dcLock:IsToggled() then
            -- LOCKED to the car: the game moves the camera with the car in the same step as it
            -- moves the car, so there's no one-frame lag between them (that lag was the twitch).
            -- The rotation is given relative to the car; the steadied-horizon part is added in.
            local relP = (carP * 0.8 + relPitch) - rawP
            local relR = (carR * 0.7 + gRoll + shakeR) - rawR
            Natives.InvokeVoid(N.HARD_ATTACH_CAM_TO_ENTITY, cam, veh, relP + 0.0, relR + 0.0, relYaw + 0.0,
                ox + 0.0, oy + 0.0, oz + 0.0, true)
        else
            Natives.InvokeVoid(N.ATTACH_CAM_TO_ENTITY, cam, veh, ox, oy, oz, true)
            Natives.InvokeVoid(N.SET_CAM_ROT, cam, (carP * 0.8 + relPitch) + 0.0, (carR * 0.7 + gRoll + shakeR) + 0.0,
                (rz + relYaw) + 0.0, 2)
        end

        -- speed FOV (smooth S-curve, never past Max FOV)
        -- (speed is smoothed first - it jumps a little every physics step - then the FOV moves on a
        -- soft spring, and eases into Max FOV instead of hitting it like a wall)
        fovSpeed = Ease(fovSpeed, speed, dt, 0.35) -- (used by the speed shake)
        -- The zoom: your speed goes through a soft spring, then the zoom itself goes through
        -- another soft spring. Both start and stop moving gently, so there's never a jump - even
        -- if the speed reading jitters, or you hit something and stop dead.
        local smooth = F.dcFovSmooth and (F.dcFovSmooth:GetIntValue() or 7) or 7
        local sTau = 0.25 + 0.08 * smooth                          -- speed follow (0.33 - 1.05 s)
        local zTau = 0.35 + 0.12 * smooth                          -- zoom follow  (0.47 - 1.55 s)
        local sw, zw = 2.4 / sTau, 2.4 / zTau
        local fsteps = math.max(1, math.ceil(dt / 0.008))
        local fh = dt / fsteps
        local want = 0.0
        local startS = (F.dcFovStart and F.dcFovStart:GetIntValue() or 40) * 0.44704
        local fullS = math.max(startS + 5, (F.dcFovFull and F.dcFovFull:GetIntValue() or 160) * 0.44704)
        local amt = F.dcFovAmt:GetFloatValue() or 3.0
        for _ = 1, fsteps do
            fovSlowV = fovSlowV + (sw * sw * (speed - fovSlow) - 2 * sw * fovSlowV) * fh
            fovSlow = fovSlow + fovSlowV * fh
            if fovOn then
                local k = Clamp((fovSlow - startS) / (fullS - startS), 0, 1)
                want = amt * (k * k * (3 - 2 * k))                 -- S-curve: eases in and out
            end
            fovVel = fovVel + (zw * zw * (want - fovExtra) - 2 * zw * fovVel) * fh
            fovExtra = fovExtra + fovVel * fh
        end
        local maxFov = F.dcFovMax:GetIntValue() or 75
        local base = F.dcBaseOn:IsToggled() and (F.dcBase:GetIntValue() or 62) or baseFov
        local room = math.max(0, maxFov - base)
        local extra = math.max(0, fovExtra)
        local fov = base + (room > 0 and room * (1 - math.exp(-extra / room)) or 0)
        Natives.InvokeVoid(N.SET_CAM_FOV, cam, fov + 0.0)

        -- speed shake on the head camera: our own smooth vibration (the game's shakes also
        -- wobble the zoom, which looked like the FOV jumping). Used on the next frame's angle.
        if camShake then Natives.InvokeVoid(N.STOP_CAM_SHAKING, cam, true) camShake = false end
        local k = spOn and Clamp((fovSpeed - 15) / 45, 0, 1) or 0
        shakeAmp = Ease(shakeAmp, k * k * (F.dcSpeedAmt:GetFloatValue() or 0.8), dt, 0.5)
        local st = now / 1000
        local d = shakeAmp * 0.55
        shakeP = d * (0.6 * math.sin(st * 29 + 1.3) + 0.4 * math.sin(st * 53 + 0.2))
        shakeY = d * 0.7 * (0.6 * math.sin(st * 23 + 2.1) + 0.4 * math.sin(st * 47 + 4.0))
        shakeR = d * 0.5 * (0.6 * math.sin(st * 19 + 0.7) + 0.4 * math.sin(st * 41 + 2.9))
        return true
    end

    -- ================= THIRD PERSON (game camera) =================
    local tpActive, gpShake, gpAmp = false, nil, 0.0
    local function GpShakeStop()
        if gpShake then pcall(Natives.InvokeVoid, N.STOP_GAMEPLAY_CAM_SHAKING, false) gpShake = nil end
        gpAmp = 0.0
    end
    local function ThirdPerson(dt, now, speed, look, spOn)
        if spOn and not (F.sfxMode and (F.sfxMode:GetListIndex() or 0) > 0) then
            local k = Clamp((speed - 15) / 45, 0, 1)
            gpAmp = Ease(gpAmp, k * k * (F.dcSpeedAmt:GetFloatValue() or 0.8), dt, 0.4)
            if gpAmp > 0.02 then
                if not gpShake then
                    Natives.InvokeVoid(N.SHAKE_GAMEPLAY_CAM, "ROAD_VIBRATION_SHAKE", gpAmp + 0.0)
                    gpShake = true
                end
                Natives.InvokeVoid(N.SET_GAMEPLAY_CAM_SHAKE_AMPLITUDE, gpAmp + 0.0)
            elseif gpShake then GpShakeStop() end
        else
            GpShakeStop()
        end
        if not look then tpActive = false return end
        local lx = Natives.InvokeFloat(N.GET_CONTROL_NORMAL, 0, 1) or 0
        local ly = Natives.InvokeFloat(N.GET_CONTROL_NORMAL, 0, 2) or 0
        if MenuOpen() then lx, ly = 0, 0 end -- (menu open: mouse is for the menu)
        if F.wheelLookOff and F.wheelLookOff() then lx, ly = 0, 0 end -- (Wheel & Pedals: pedal on the right stick)
        if math.abs(lx) > 0.12 or math.abs(ly) > 0.12 then lookFrames = lookFrames + 1 else lookFrames = 0 end
        if lookFrames >= 4 or IB(N.IS_CONTROL_PRESSED, 0, 79) then userUntil = now + 1200 end
        if now < userUntil then tpActive = false return end
        if not tpActive then
            tpActive = true
            head = Wrap(Natives.InvokeFloat(N.GET_GAMEPLAY_CAM_RELATIVE_HEADING) or 0.0)
            headVel = 0.0
        end
        Natives.InvokeVoid(N.SET_GAMEPLAY_CAM_RELATIVE_HEADING, head + 0.0)
    end

    local function ReleaseAll()
        CamOff()
        GpShakeStop()
        tpActive = false
        prevV = nil
    end

    F.dcTick = function()
        local now = NowMs()
        local dt = math.min(0.1, math.max(0.001, (now - lastT) / 1000))
        lastT = now
        if F.dcMaster and not F.On("dcMaster") then lastFrame = nil ReleaseAll() return end -- (master switch off)
        -- use the game's own frame time (the clock on the wall drifts against the game a little
        -- every frame, which made the measured acceleration jitter -> the head nodded)
        local okC, fc = pcall(Natives.InvokeInt, N.GET_FRAME_COUNT)
        local okT, ft = pcall(Natives.InvokeFloat, N.GET_FRAME_TIME)
        if okC and fc and fc ~= 0 then
            local frames = lastFrame and (fc - lastFrame) or 1
            lastFrame = fc
            if frames == 0 then return end -- already done this frame
            if okT and ft and ft > 0 and ft < 0.2 and frames >= 1 and frames <= 4 then
                dt = math.min(0.1, ft * frames)
            end
        end
        if F.dcMaster and not F.On("dcMaster") then ReleaseAll() return end -- (master switch off)
        if F.tourCamBusy and F.tourCamBusy() then ReleaseAll() return end -- (scenic tour camera is filming)
        local look, gOn, spOn, fovOn = F.dcOn:IsToggled(), F.dcG:IsToggled(), F.dcSpeed:IsToggled(), F.dcFov:IsToggled()
        local baseOn = F.dcBaseOn:IsToggled()
        if not (look or gOn or spOn or fovOn or baseOn) then ReleaseAll() return end
        local ped = Natives.InvokeInt(N.PLAYER_PED_ID)
        local veh = IB(N.IS_PED_IN_ANY_VEHICLE, ped, false) and Natives.InvokeInt(N.GET_VEHICLE_PED_IS_IN, ped, false) or 0
        if not veh or veh == 0 or IB(N.IS_PAUSE_MENU_ACTIVE) then ReleaseAll() return end
        local mode = Natives.InvokeInt(N.GET_CAM_VIEW_MODE_FOR_CONTEXT, Natives.InvokeInt(N.GET_CAM_ACTIVE_VIEW_MODE_CONTEXT))
        local fp = mode == 4

        -- ----- what the car is doing -----
        local vx, vy = V3(N.GET_ENTITY_SPEED_VECTOR, veh, true)
        local wx, wy, wz = V3(N.GET_ENTITY_VELOCITY, veh)
        local fx, fy = V3(N.GET_ENTITY_FORWARD_VECTOR, veh)
        if not (vx and wx and fx) then return end
        local speed = math.sqrt(wx * wx + wy * wy + wz * wz)
        if prevV then
            local ax, ay, az = (wx - prevV[1]) / dt, (wy - prevV[2]) / dt, (wz - prevV[3]) / dt
            local long = (ax * fx + ay * fy) / 9.81
            local lat = (ax * fy - ay * fx) / 9.81
            local up = az / 9.81
            if math.abs(long) < 4 and math.abs(lat) < 4 then
                hLong[1], hLong[2], hLong[3] = hLong[2], hLong[3], long
                hLat[1], hLat[2], hLat[3] = hLat[2], hLat[3], lat
                long = Median3(hLong[1], hLong[2], hLong[3])
                lat = Median3(hLat[1], hLat[2], hLat[3])
                -- the pull builds up quickly but lets go slowly: a gear change only drops it for
                -- a moment, so your head doesn't nod forward and back on every shift any more
                aLong = Ease(aLong, long, dt, math.abs(long) > math.abs(aLong) and 0.18 or 0.45)
                aLat = Ease(aLat, lat, dt, 0.18)
            end
            if up > 1.2 and up < 8 and now - lastJolt > 400 then jolt, lastJolt = up, now end
        end
        prevV = { wx, wy, wz }

        -- ----- drift look angle (works at any drift angle; not when really reversing) -----
        if backward then
            backward = not (vy > -1.0 or math.abs(vx) > -vy * 0.9)
        else
            backward = vy < -2.0 and math.abs(vx) < -vy * 0.5
        end
        local target = 0.0
        -- the slide angle is filtered first: the raw value jitters every frame (bumps, kerbs,
        -- wheels bouncing), which is what made the camera twitch
        local slipRaw = 0.0
        if look and not backward and speed > 3.0 then
            slipRaw = Clamp(math.deg((math.atan2 or math.atan)(vx, vy)), -120, 120) -- + = sliding right
        end
        slipF = Ease(slipF, slipRaw, dt, 0.10)
        if look and not backward then
            local fade = Clamp((speed - 3.0) / 6.0, 0, 1)
            fade = fade * fade * (3 - 2 * fade)                     -- soft fade in at low speed
            local a = math.abs(slipF)
            -- soft dead zone: tiny slides are ignored, then it eases in (no sudden start)
            local eff = a < 2 and 0 or (a < 8 and (a - 2) * (a - 2) / 12 or a - 5)
            target = -(slipF >= 0 and eff or -eff) * (F.dcAmount:GetFloatValue() or 0.75) * fade
        end
        aLatS = Ease(aLatS, aLat, dt, 0.25)
        if gOn and fp and not backward and vy > 0.5 then
            target = target - aLatS * 6.0 * (F.dcGAmt:GetFloatValue() or 1.0) -- glance into the corner
        end
        local max = F.dcMax:GetIntValue() or 60
        -- soft limit instead of a hard stop at the max angle
        local x = Clamp(target / max, -8, 8)
        local e2 = math.exp(2 * x)
        target = max * (e2 - 1) / (e2 + 1) -- (tanh)
        -- a spring (like a real neck) instead of a straight chase: it speeds up and slows down
        -- smoothly, so direction changes (flicking from one drift into the other) never jerk
        local tau = 0.05 + 0.05 * (F.dcSmooth:GetIntValue() or 5)
        local w = 2.4 / tau
        local steps = math.max(1, math.ceil(dt / 0.008))
        local h = dt / steps
        for _ = 1, steps do
            local acc = w * w * (target - head) - 2 * w * headVel
            headVel = headVel + acc * h
            head = head + headVel * h
        end

        -- ----- first person: our head camera (unless you're aiming / using the cinematic cam) -----
        local busy = IB(N.IS_CONTROL_PRESSED, 0, 25) or IB(N.IS_CONTROL_PRESSED, 0, 68)
            or IB(N.IS_CONTROL_PRESSED, 0, 80) or IB(N.IS_DISABLED_CONTROL_PRESSED, 0, 80)
        -- the game's own camera can flick its mode / aim state for a single frame (e.g. mid drift);
        -- the head cam only lets go if it's still the case a moment later, so it never
        -- bounces between the two cameras (that bounce was the leftover twitch)
        local wantHead = fp and not busy
        if wantHead then headOffSince = nil
        elseif cam then
            headOffSince = headOffSince or now
            if now - headOffSince < 350 then wantHead = true end
        end
        if wantHead then
            GpShakeStop()
            tpActive = false
            local ok, err = pcall(HeadCam, ped, veh, dt, now, speed, vx, vy, look, gOn, fovOn, spOn)
            if not ok then LogErr("head camera", err) CamOff() end
            return
        end
        CamOff()
        if not fp and F.dcThird:IsToggled() then
            ThirdPerson(dt, now, speed, look, spOn)
        else
            GpShakeStop()
            tpActive = false
        end
    end
end)

Try("creating dashcam and speed blur", function()
    local X = F.LX
    local N = {
        GET_PED_IN_VEHICLE_SEAT         = 0xBB40DD2270B65366,
        GET_ENTITY_MODEL                = 0x9F47B058362C84B5,
        GET_ENTITY_SPEED                = 0xD5037BA82E12416F,
        SET_TIMECYCLE_MODIFIER          = 0x2C933ABF17A1DF41,
        SET_TIMECYCLE_MODIFIER_STRENGTH = 0x82E7FFCD5B2326B3,
        CLEAR_TIMECYCLE_MODIFIER        = 0x0F07E7745A236711,
        SET_EXTRA_TIMECYCLE_MODIFIER    = 0x5096FD9CCB49056D,
        SET_EXTRA_TIMECYCLE_MODIFIER_STRENGTH = 0x2C328AF17210F009,
        CLEAR_EXTRA_TIMECYCLE_MODIFIER  = 0x92CCC17A7A2285DA,
        HIDE_HUD_AND_RADAR_THIS_FRAME   = 0x719FF505F097FD20,
        GET_CLOCK_HOURS                 = 0x25223CA6B4D20B7F,
        GET_CLOCK_MINUTES               = 0x13D2B8ADD79640F2,
    }
    local function nv(...) pcall(Natives.InvokeVoid, ...) end
    -- ================= DASHCAM (Vehicle > Cameras) - your screen only =================
    -- A camera bolted to the windscreen behind the mirror: it moves exactly with the car's body (every
    -- dip, bump and brake shows), plus the little buzz and wobble of a real suction mount, and a real
    -- dashcam's on-screen text (date, time, speed, GPS, street, REC timer, G-sensor event lock).
    local DN = {
        CREATE_CAM                      = 0xC3981DCE61D9E13F,
        DESTROY_CAM                     = 0x865908C81A2C22E9,
        SET_CAM_ACTIVE                  = 0x026FB97D0A425F84,
        RENDER_SCRIPT_CAMS              = 0x07E5B515DB0636FC,
        HARD_ATTACH_CAM_TO_ENTITY       = 0x202A5ED9CE01D6E7,
        SET_CAM_FOV                     = 0xB13C14F66A00D047,
        SET_CAM_NEAR_CLIP               = 0xC7848EFCCC545182,
        SHAKE_CAM                       = 0x6A25241C340D3822,
        SET_CAM_SHAKE_AMPLITUDE         = 0xD93DB43B82BC0D00,
        STOP_CAM_SHAKING                = 0xBDECF64367884AC3,
        SET_CAM_MOTION_BLUR_STRENGTH    = 0x6F0F77FBA9A8F2E6,
        GET_RENDERING_CAM               = 0x5234F9F10919EABA,
        GET_PED_BONE_COORDS             = 0x17C07FC640E86B4E,
        GET_OFFSET_FROM_ENTITY_GIVEN_WORLD_COORDS = 0x2274BC1C4885E333,
        GET_ENTITY_SPEED_VECTOR         = 0x9A8D700A51CB7B0D,
        GET_FRAME_TIME                  = 0x15C40837039FFAF7,
        GET_STREET_NAME_AT_COORD        = 0x2EB41072B4C1E4C0,
        GET_STREET_NAME_FROM_HASH_KEY   = 0xD0EF8A959B8A4CB9,
        HAS_ENTITY_COLLIDED_WITH_ANYTHING = 0x8BAD02F0368D9E14,
        GET_ASPECT_RATIO                = 0xF1307EF624A80D87,
    }
    F.dashOn = Toggle(H.dashOn, "Dashcam",
        "Real dashcam footage: a camera on the windscreen, bolted to the car, with the date, time, speed, GPS and REC on screen. " ..
        "Camera Effects and Speed Blur pause while it's on. Only on your screen", false)
    F.dashCam = Toggle(H.dashCam, "Windscreen Camera",
        "In a vehicle the view moves to the dashcam's spot on the windscreen. Off = keep the normal camera, just the dashcam look", true)
    F.dashView = FeatureMgr.AddFeature(H.dashView, "Camera Faces", eFeatureType.Combo,
        "Forward = through the windscreen. Backward = a rear dashcam looking out of the back window")
    F.dashView:SetList({ "Forward (windscreen)", "Backward (rear window)" })
    F.dashStyle = FeatureMgr.AddFeature(H.dashStyle, "Overlay Style", eFeatureType.Combo,
        "Dashcam = a real car dashcam's text (date, time, speed, GPS, street, REC timer, G-sensor). " ..
        "Camcorder = a handheld camera's REC, battery and viewfinder corners. Clean = no text at all")
    F.dashStyle:SetList({ "Dashcam", "Camcorder", "Clean (no text)" })
    F.dashFov = Slider(H.dashFov, "Lens Width (FOV)", eFeatureType.SliderInt,
        "How wide the dashcam sees (real dashcams are very wide - 85 to 95 looks right)", 60, 110, 1, 88)
    F.dashFwd = Slider(H.dashFwd, "Camera Forward / Back", eFeatureType.SliderFloat,
        "Fine tune: moves the camera towards the glass (+) or back into the car (-), in metres", -0.6, 0.6, 0.02, 0.0)
    F.dashUp = Slider(H.dashUp, "Camera Up / Down", eFeatureType.SliderFloat,
        "Fine tune: moves the camera up (+) or down (-), in metres", -0.4, 0.4, 0.02, 0.0)
    F.dashShake = Toggle(H.dashShake, "Mount Vibration",
        "The shakes of a camera stuck to the glass: a road buzz that grows with speed, a little wobble when you " ..
        "brake or accelerate hard, and a jolt when you hit something", true)
    F.dashSpeed = Toggle(H.dashSpeed, "Dashcam Speed", "Your speed on the footage (in a vehicle)", true)
    F.dashGps = Toggle(H.dashGps, "Dashcam GPS & Street", "GPS co-ordinates and the street you're on, like a GPS dashcam", true)
    F.dashTime = Toggle(H.dashTime, "Dashcam Date & Time", "The real date and time, like a camera's timestamp", true)
    F.dashFrame = Toggle(H.dashFrame, "Camcorder Corners", "Viewfinder corners round the edge of the screen (Camcorder style)", true)
    F.dashFilter = FeatureMgr.AddFeature(H.dashFilter, "Camera Filter", eFeatureType.Combo,
        "The picture's look")
    local FILTERS = { { "None" }, { "Camcorder (scan lines)", "scanline_cam" }, { "Security Camera", "CAMERA_secuirity" },
        { "Old VHS", "CAMERA_secuirity_FUZZ" }, { "Black & White", "NG_filmnoir_BW01" } }
    do local l = {} for i, f in ipairs(FILTERS) do l[i] = f[1] end F.dashFilter:SetList(l) end
    F.dashFilter:SetListIndex(0)
    F.dashHud = Toggle(H.dashHud, "Hide The Game's HUD", "Hides the minimap and GTA's HUD while the dashcam is on", true)

    local dash = { tc = nil, at = 0, was = nil, recAt = nil, lastSpd = nil, lastT = nil, event = -99999,
                   street = "", streetAt = 0, x = 0, y = 0 }
    local function DashFilterOff()
        if dash.tc then nv(N.CLEAR_TIMECYCLE_MODIFIER) dash.tc = nil end
    end
    table.insert(F.unloadHooks, function() pcall(DashFilterOff) end)

    -- ----- the other camera features wait while the dashcam's on (and come back after) -----
    local PAUSE = { "dcMaster", "cineAny", "sbOn" }
    local PAUSE_NAMES = { dcMaster = "Camera Effects", cineAny = "Cinematic Camera", sbOn = "Speed Blur" }
    local function PauseFile() return CfgDir() .. "\\dashcam_paused.txt" end
    local function ReadPaused()
        local l, seen = {}, {}
        pcall(function()
            if FileMgr.DoesFileExist(PauseFile()) then
                for k in (FileMgr.ReadFileContent(PauseFile()) or ""):gmatch("[%w_]+") do
                    if not seen[k] then seen[k] = true l[#l + 1] = k end
                end
            end
        end)
        return l, seen
    end
    local function WritePaused(l) pcall(FileMgr.WriteFileContent, CfgDir() .. "\\dashcam_paused.txt", table.concat(l, "\n")) end
    local function PauseOthers()
        -- (added to what's already noted - so a restart with the dashcam on never forgets what to bring back)
        local l, seen = ReadPaused()
        local names = {}
        for _, k in ipairs(PAUSE) do
            local f = F[k]
            if f and f:IsToggled() then
                f:SetBoolValue(false)
                if not seen[k] then seen[k] = true l[#l + 1] = k end
                names[#names + 1] = PAUSE_NAMES[k]
            end
        end
        WritePaused(l)
        if #names > 0 then Notify("Dashcam on - paused " .. table.concat(names, ", ") .. " (back when it's off)", true, "driving", { merge = "dashcam" }) end
    end
    local function ResumeOthers()
        local l = ReadPaused()
        local names = {}
        for _, k in ipairs(l) do
            local f = F[k]
            if f and not f:IsToggled() then f:SetBoolValue(true) names[#names + 1] = PAUSE_NAMES[k] or k end
        end
        WritePaused({})
        if #names > 0 then Notify("Dashcam off - " .. table.concat(names, ", ") .. " back on", true, "driving", { merge = "dashcam" }) end
    end

    -- ----- the windscreen camera -----
    local dc = { cam = nil, veh = nil, mount = nil, mountKey = nil, t = 0.0, lastFwd = nil, accel = 0.0,
                 wob = 0.0, wobV = 0.0, rollW = 0.0, rollV = 0.0, shaking = false, kick = false }
    local V3 = F.V3xyz
    local function CamOff()
        if dc.cam then
            -- (always handed back when it's ours on screen - the game doesn't always say which camera is showing,
            -- and asking first left the view stuck on the windscreen after getting out)
            if dc.live then nv(DN.RENDER_SCRIPT_CAMS, false, false, 0, true, false, 0) end
            nv(DN.SET_CAM_ACTIVE, dc.cam, false)
            nv(DN.DESTROY_CAM, dc.cam, false)
        end
        dc.cam, dc.veh, dc.shaking, dc.lastFwd, dc.live = nil, nil, false, nil, false
    end
    table.insert(F.unloadHooks, function() pcall(CamOff) end)
    F.dashCamOff = CamOff
    -- where the dashcam sits in this car: centred, just in front of your head at the top of the
    -- windscreen (measured from your head, so it's right in every car - low sports cars, vans, trucks)
    -- ----- per car: the dashcam's own settings and exactly where it sits, saved for each car model -----
    -- (where your head sits is measured once you're settled in the driver's seat - measuring while you were still
    -- sitting down put the camera somewhere slightly different every time you got in - then kept and saved)
    local PC = { cars = {}, model = nil, applied = nil, dirty = false, saveAt = 0, settledSince = nil }
    local DASH_DEF = { view = 0, fov = 88, fwd = 0.0, up = 0.0 }
    local function CarsFile() return CfgDir() .. "\\dashcam_cars.txt" end
    pcall(function()
        if FileMgr.DoesFileExist(CarsFile()) then
            for line in (FileMgr.ReadFileContent(CarsFile()) or ""):gmatch("[^\r\n]+") do
                local m, v, fo, fw, up, hy, hz = line:match("^(%-?%d+)|(%d*)|(%d*)|([%-%d%.]*)|([%-%d%.]*)|([%-%d%.]*)|([%-%d%.]*)$")
                if m then
                    PC.cars[tonumber(m)] = { view = tonumber(v), fov = tonumber(fo), fwd = tonumber(fw), up = tonumber(up),
                        hy = tonumber(hy), hz = tonumber(hz) }
                end
            end
        end
    end)
    local function SaveCars()
        local out = {}
        for m, e in pairs(PC.cars) do
            -- (a car you've only sat in keeps just where the camera sits - its settings stay blank until you change one)
            local set = e.fov ~= nil
            out[#out + 1] = ("%d|%s|%s|%s|%s|%s|%s"):format(m, set and tostring(e.view or 0) or "", set and tostring(e.fov) or "",
                set and ("%.2f"):format(e.fwd or 0) or "", set and ("%.2f"):format(e.up or 0) or "",
                e.hy and ("%.3f"):format(e.hy) or "", e.hz and ("%.3f"):format(e.hz) or "")
        end
        pcall(FileMgr.WriteFileContent, CarsFile(), table.concat(out, "\n"))
    end
    local function Current()
        return { view = F.dashView:GetListIndex() or 0, fov = F.dashFov:GetIntValue() or 88,
                 fwd = F.dashFwd:GetFloatValue() or 0, up = F.dashUp:GetFloatValue() or 0 }
    end
    local function Same(a, b)
        return a and b and a.view == b.view and a.fov == b.fov and math.abs(a.fwd - b.fwd) < 0.001 and math.abs(a.up - b.up) < 0.001
    end
    local function CarLabel(model)
        local ok, n = pcall(Natives.InvokeString, 0xB215AAC32D25D019, model) -- GET_DISPLAY_NAME_FROM_VEHICLE_MODEL
        if ok and n and n ~= "" and n ~= "CARNOTFOUND" then
            local okL, l = pcall(Natives.InvokeString, 0x7B5280EBA9840C72, n) -- GET_FILENAME_FOR_AUDIO_CONVERSATION (the proper name)
            if okL and l and l ~= "" and l ~= "NULL" then return l end
            return n
        end
        return "this car"
    end
    F.drawDashCar = function()
        if not F.On("dashOn") then return end
        if PC.model then
            local e = PC.cars[PC.model]
            pcall(ImGui.TextDisabled, ("Camera Faces / Lens / Forward / Up are saved for this car: %s%s"):format(CarLabel(PC.model),
                (e and e.fov) and "" or " (defaults - change one to save it)"))
        else
            pcall(ImGui.TextDisabled, "Get in a car: each car model keeps its own Camera Faces / Lens / Forward / Up")
        end
    end
    -- getting in: that car's settings come back (a car you've never set: the defaults); changing one saves it for that car
    local function PerCarTick(now, veh)
        if not veh then PC.model, PC.applied, PC.settledSince = nil, nil, nil return end
        local model = Natives.InvokeInt(N.GET_ENTITY_MODEL, veh)
        if model ~= PC.model then
            PC.model = model
            local e = PC.cars[model]
            local s = (e and e.fov) and e or DASH_DEF
            pcall(function()
                F.dashView:SetListIndex(s.view or 0) F.dashFov:SetIntValue(s.fov or 88)
                F.dashFwd:SetFloatValue((s.fwd or 0) + 0.0) F.dashUp:SetFloatValue((s.up or 0) + 0.0)
            end)
            PC.applied = Current()
            if e and e.fov then Notify("Dashcam: your " .. CarLabel(model) .. " settings", true, "driving", { merge = "dashcam car" }) end
            return
        end
        local cur = Current()
        if not Same(cur, PC.applied) then
            local e = PC.cars[model] or {}
            e.view, e.fov, e.fwd, e.up = cur.view, cur.fov, cur.fwd, cur.up
            PC.cars[model], PC.applied, PC.dirty, PC.saveAt = e, cur, true, now + 1200
        end
        if PC.dirty and now >= PC.saveAt then PC.dirty = false SaveCars() end
    end
    local function Mount(veh, me, view)
        local model = Natives.InvokeInt(N.GET_ENTITY_MODEL, veh)
        local minX, minY, minZ, maxX, maxY, maxZ = X.Dims(model)
        local e = PC.cars[model]
        local oy, oz = e and e.hy, e and e.hz
        if not oy then
            -- not measured for this car yet: once you've been sat still in the driver's seat for a moment, measure it
            local now = NowMs()
            local seated = IB(0xA808AA1D79230FC2, me, veh)                                  -- IS_PED_SITTING_IN_VEHICLE
                and not IB(0xB0760331C7AA4155, me, 160)                                      -- (not still getting in)
                and Natives.InvokeInt(N.GET_PED_IN_VEHICLE_SEAT, veh, -1, false) == me
            if seated then PC.settledSince = PC.settledSince or now else PC.settledSince = nil end
            if seated and now - PC.settledSince > 800 then
                local hx, hy, hz = V3(DN.GET_PED_BONE_COORDS, me, 31086, 0.0, 0.0, 0.0) -- (SKEL_Head)
                if hx then
                    local _, ry, rz = V3(DN.GET_OFFSET_FROM_ENTITY_GIVEN_WORLD_COORDS, veh, hx + 0.0, hy + 0.0, hz + 0.0)
                    if ry and math.abs(ry) < 15 and math.abs(rz) < 6 then
                        e = PC.cars[model] or {}
                        e.hy, e.hz = ry, rz
                        PC.cars[model] = e
                        SaveCars()
                        oy, oz = ry, rz
                    end
                end
            end
        end
        if not oy then oy, oz = (maxY or 2.0) * 0.1, (maxZ or 1.2) - 0.55 end -- (until then: a good guess from the car's size)
        if view == 1 then
            return { y = math.max((minY or -2.0) + 0.45, oy - 1.05), z = oz + 0.02, yaw = 180.0, pitch = -2.0 }
        end
        local _ = minX or minZ or maxX
        return { y = math.min((maxY or 2.0) - 0.35, oy + 0.52), z = oz + 0.10, yaw = 0.0, pitch = -3.5 }
    end
    local function Spring(x, v, target, dt, k, c)
        local n = math.max(1, math.ceil(dt / 0.008))
        local h = dt / n
        for _ = 1, n do
            v = v + (k * (target - x) - c * v) * h
            x = x + v * h
        end
        return x, v
    end
    local function CamTick(now, veh, me)
        -- (getting out: back to the normal camera straight away, not once you're out)
        local exiting = veh and me and IB(0xB0760331C7AA4155, me, 2) -- GET_IS_TASK_ACTIVE (CTaskExitVehicle)
        local want = F.On("dashOn") and F.dashCam:IsToggled() and veh and not exiting
        if not want then if dc.cam then CamOff() end return end
        if dc.cam and dc.veh ~= veh then CamOff() end
        -- another camera showing (Scenic Tour, Photo Mode, Photo Booth, Cherax's own...): it goes first
        local rendering = Natives.InvokeInt(DN.GET_RENDERING_CAM) or -1
        local other = rendering ~= -1 and rendering ~= 0 and rendering ~= dc.cam
        if other then dc.live = false return end -- (someone else's camera is showing: it goes first, ours comes back after)
        if not dc.cam then
            local c = Natives.InvokeInt(DN.CREATE_CAM, "DEFAULT_SCRIPTED_CAMERA", true)
            if not c or c == 0 or c == -1 then return end
            dc.cam, dc.veh, dc.mount = c, veh, nil
            nv(DN.SET_CAM_NEAR_CLIP, c, 0.04)
            nv(DN.SET_CAM_MOTION_BLUR_STRENGTH, c, 0.12)
            dc.wob, dc.wobV, dc.rollW, dc.rollV = 0.0, 0.0, 0.0, 0.0
        end
        if rendering ~= dc.cam or not dc.live then
            nv(DN.SET_CAM_ACTIVE, dc.cam, true)
            if not dc.live then nv(DN.RENDER_SCRIPT_CAMS, true, false, 0, true, false, 0) end
            dc.live = true
        end
        local dt = Natives.InvokeFloat(DN.GET_FRAME_TIME) or 0.016
        if dt <= 0 or dt > 0.1 then dt = 0.016 end
        dc.t = dc.t + dt
        -- how hard you're speeding up / braking / turning (in the car's own directions)
        local sx, sy = V3(DN.GET_ENTITY_SPEED_VECTOR, veh, true)
        sx, sy = sx or 0.0, sy or 0.0
        local speed = math.sqrt(sx * sx + sy * sy)
        if dc.lastFwd then
            local a = (sy - dc.lastFwd) / dt
            if math.abs(a) < 80 then dc.accel = dc.accel + (a - dc.accel) * math.min(1, dt * 7) end
        end
        dc.lastFwd = sy
        local view = F.dashView:GetListIndex() or 0
        local m = Mount(veh, me, view)
        local pitch, roll = m.pitch, 0.0
        if F.dashShake:IsToggled() then
            -- suction mount flex: tips forward when you brake, back when you floor it - with a little
            -- springy overshoot, like a real camera on a stalk
            local target = math.max(-1.6, math.min(1.6, dc.accel * 0.075)) * (view == 1 and -1 or 1)
            if dc.kick then dc.wobV = dc.wobV - 38.0 dc.rollV = dc.rollV + (math.random() - 0.5) * 30.0 dc.kick = false end
            dc.wob, dc.wobV = Spring(dc.wob, dc.wobV, target, dt, 140.0, 7.5)
            dc.rollW, dc.rollV = Spring(dc.rollW, dc.rollV, 0.0, dt, 160.0, 9.0)
            -- road buzz: fast, small, grows with speed (a real mount never sits perfectly still)
            local amp = math.min(1.0, speed / 38.0) * 0.11
            local t = dc.t
            pitch = pitch + dc.wob + amp * (math.sin(t * 41.3) + 0.6 * math.sin(t * 67.9 + 1.3) + 0.3 * math.sin(t * 11.7))
            roll = roll + dc.rollW + amp * 0.7 * (math.sin(t * 37.1 + 0.4) + 0.5 * math.sin(t * 59.3))
            if not dc.shaking then nv(DN.SHAKE_CAM, dc.cam, "ROAD_VIBRATION_SHAKE", 0.0) dc.shaking = true end
            nv(DN.SET_CAM_SHAKE_AMPLITUDE, dc.cam, math.min(0.4, speed / 55.0 * 0.4) + 0.0)
        elseif dc.shaking then
            nv(DN.STOP_CAM_SHAKING, dc.cam, true)
            dc.shaking = false
        end
        local fwdAdj = (F.dashFwd:GetFloatValue() or 0) * (view == 1 and -1 or 1)
        -- (bolted to the car: the game moves it with the car in the same step, so it never lags or twitches)
        nv(DN.HARD_ATTACH_CAM_TO_ENTITY, dc.cam, veh, pitch + 0.0, roll + 0.0, m.yaw + 0.0,
            0.0, m.y + fwdAdj + 0.0, m.z + (F.dashUp:GetFloatValue() or 0) + 0.0, true)
        nv(DN.SET_CAM_FOV, dc.cam, (F.dashFov:GetIntValue() or 88) + 0.0)
    end

    -- ----- the on-screen text -----
    local function Aspect()
        local ok, a = pcall(Natives.InvokeFloat, DN.GET_ASPECT_RATIO, false)
        return (ok and a and a > 0.5) and a or 16 / 9
    end
    local function Corner(x, y, dx, dy)
        local aspect = Aspect()
        local L, T = 0.045, 0.0028
        F.hudRect(x + dx * L / 2, y, L, T * aspect, 255, 255, 255, 210)
        F.hudRect(x, y + dy * L * aspect / 2, T, L * aspect, 255, 255, 255, 210)
    end
    -- lens vignette: the edges of a small wide lens go a little darker
    local function Vignette()
        local R = F.hudRect
        for i = 1, 7 do
            local a = 62 * (1 - (i - 1) / 7) ^ 2
            local b = 0.011
            R(0.5, (i - 0.5) * b, 1.0, b, 0, 0, 0, a) R(0.5, 1 - (i - 0.5) * b, 1.0, b, 0, 0, 0, a)
            R((i - 0.5) * b * 0.8, 0.5, b * 0.8, 1.0, 0, 0, 0, a) R(1 - (i - 0.5) * b * 0.8, 0.5, b * 0.8, 1.0, 0, 0, 0, a)
        end
    end
    local function Street(p, now)
        if now - dash.streetAt < 1000 then return dash.street end
        dash.streetAt = now
        pcall(function()
            local a, b = Memory.Alloc(8), Memory.Alloc(8)
            Memory.WriteInt(a, 0) Memory.WriteInt(b, 0)
            Natives.InvokeVoid(DN.GET_STREET_NAME_AT_COORD, p.x + 0.0, p.y + 0.0, p.z + 0.0, a, b)
            local h = Memory.ReadInt(a) or 0
            Memory.Free(a) Memory.Free(b)
            local s = h ~= 0 and Natives.InvokeString(DN.GET_STREET_NAME_FROM_HASH_KEY, h) or ""
            dash.street = (s and s ~= "") and s:upper() or ""
        end)
        return dash.street
    end
    local function DashTick(now)
        local on = F.On("dashOn")
        -- switched on / off: pause / bring back the other camera features
        if on ~= dash.was then
            if on then PauseOthers() dash.recAt = now
            elseif dash.was ~= nil then ResumeOthers() end
            dash.was = on
        end
        local veh, me = X.Car()
        if on then
            local okP, errP = pcall(PerCarTick, now, veh)
            if not okP and now - (dash.pcErr or 0) > 10000 then dash.pcErr = now LogErr("dashcam per car", errP) end
        end
        pcall(CamTick, now, veh, me)
        dash.showing = false
        if not on then DashFilterOff() return end
        -- (a dashcam lives in the car: on foot its overlay and filter go - Camcorder style still works on foot)
        if not veh and (F.dashStyle:GetListIndex() or 0) ~= 1 then DashFilterOff() return end
        dash.showing = true -- (the GTA Speedometer steps aside while this is up)
        -- the filter (only while no Drug Effect is using the game's colour filter)
        local fx = FILTERS[(F.dashFilter:GetListIndex() or 0) + 1]
        local want = fx and fx[2] or nil
        local sfxBusy = (F.sfxMode and (F.sfxMode:GetListIndex() or 0) > 0) or F.introPlaying
        if sfxBusy then dash.tc = nil
        elseif want then
            if dash.tc ~= want or now - dash.at > 2000 then
                nv(N.SET_TIMECYCLE_MODIFIER, want)
                nv(N.SET_TIMECYCLE_MODIFIER_STRENGTH, 1.0)
                dash.tc, dash.at = want, now
            end
        else DashFilterOff() end
        -- G-sensor: a crash or a very hard stop locks the clip, like a real dashcam
        local spd = veh and (Natives.InvokeFloat(N.GET_ENTITY_SPEED, veh) or 0) or nil
        if spd and dash.lastSpd and dash.lastT and now > dash.lastT then
            local drop = dash.lastSpd - spd
            local decel = drop * 1000 / (now - dash.lastT)
            if (decel > 14 and drop > 1.5) or (drop > 2.5 and IB(DN.HAS_ENTITY_COLLIDED_WITH_ANYTHING, veh)) then
                if now - dash.event > 1500 then dc.kick = true end
                dash.event = now
            end
        end
        dash.lastSpd, dash.lastT = spd, now
        if not (F.hudKeep and F.hudText and F.hudRect) then return end
        local style = F.dashStyle:GetListIndex() or 0
        local hideHud = F.dashHud:IsToggled()
        if style == 2 then
            if hideHud then F.hudKeep("dashcam", function() nv(N.HIDE_HUD_AND_RADAR_THIS_FRAME) end, 150) end
            return
        end
        local stamp
        if F.dashTime:IsToggled() then
            local okD, s = pcall(os.date, style == 0 and "%Y/%m/%d   %H:%M:%S" or "%d/%m/%Y   %H:%M:%S")
            if okD and s then stamp = s
            else stamp = ("%02d:%02d"):format(Natives.InvokeInt(N.GET_CLOCK_HOURS) or 0, Natives.InvokeInt(N.GET_CLOCK_MINUTES) or 0) end
        end
        local spdTxt = (F.dashSpeed:IsToggled() and spd) and X.SpeedText(spd) or nil
        local gps, street
        if style == 0 and F.dashGps:IsToggled() then
            local p = EntityPos(veh or me)
            if p then
                -- (GTA's map laid over Los Angeles, where it's based)
                local lat, lon = 34.0522 + p.y / 111320, -118.2437 + p.x / 92290
                gps = ("%s%.5f  %s%.5f"):format(lat >= 0 and "N" or "S", math.abs(lat), lon >= 0 and "E" or "W", math.abs(lon))
                street = Street(p, now)
            end
        end
        local secs = math.floor((now - (dash.recAt or now)) / 1000)
        local rec = ("%02d:%02d:%02d"):format(math.floor(secs / 3600), math.floor(secs / 60) % 60, secs % 60)
        local blink = (now % 1000) < 600
        local eventOn = now - dash.event < 5000
        local frame = F.dashFrame:IsToggled()
        F.hudKeep("dashcam", function()
            local T, R = F.hudText, F.hudRect
            if hideHud then nv(N.HIDE_HUD_AND_RADAR_THIS_FRAME) end -- (every frame, or the radar flickers)
            if style == 0 then
                Vignette()
                -- top: REC + running time, and the camera's own label
                if blink then R(0.031, 0.043, 0.0085, 0.0151, 235, 25, 25, 255) end
                T("REC  " .. rec, 0.040, 0.030, 0.33, 255, 255, 255, 235, 0)
                T("LGN DC-1   1440P  30FPS", 0.972, 0.030, 0.30, 205, 205, 205, 215, 0, nil, 2)
                -- G-sensor event
                if eventOn and (now % 500) < 330 then
                    R(0.5, 0.043, 0.19, 0.030, 200, 20, 20, 210)
                    T("G-SENSOR  EVENT LOCKED", 0.5, 0.030, 0.31, 255, 255, 255, 255, 0, nil, 0)
                end
                -- bottom: date / time and speed on the left, street and GPS on the right
                if stamp then T(stamp, 0.028, 0.912, 0.34, 255, 255, 255, 235, 0) end
                if spdTxt then T(spdTxt, 0.028, 0.942, 0.34, 255, 255, 255, 235, 0) end
                if street and street ~= "" then T(street, 0.972, 0.912, 0.32, 255, 255, 255, 225, 0, nil, 2) end
                if gps then T(gps, 0.972, 0.942, 0.32, 255, 255, 255, 225, 0, nil, 2) end
            else
                -- camcorder: REC, battery, timestamp, viewfinder corners
                if blink then R(0.052, 0.062, 0.011, 0.019, 230, 30, 30, 255) end
                T("REC   " .. rec, 0.062, 0.047, 0.42, 255, 255, 255, 235, 4)
                R(0.925, 0.062, 0.034, 0.020, 255, 255, 255, 220) R(0.925, 0.062, 0.030, 0.014, 0, 0, 0, 255)
                R(0.943, 0.062, 0.003, 0.009, 255, 255, 255, 220)
                for i = 0, 2 do R(0.9145 + i * 0.0095, 0.062, 0.0075, 0.010, 255, 255, 255, 220) end
                if stamp then T(stamp, 0.955, 0.912, 0.40, 255, 255, 255, 230, 4, nil, 2) end
                if spdTxt then T(spdTxt, 0.045, 0.912, 0.40, 255, 255, 255, 230, 4) end
                if frame then
                    Corner(0.03, 0.04, 1, 1) Corner(0.97, 0.04, -1, 1)
                    Corner(0.03, 0.96, 1, -1) Corner(0.97, 0.96, -1, -1)
                end
            end
        end, 150)
    end

    -- ================= SPEED BLUR (Vehicle > Cameras) - your screen only =================
    F.sbOn = Toggle(H.sbOn, "Speed Blur", "Motion blur that builds up the faster you go (only your screen)", false)
    F.sbAmt = Slider(H.sbAmt, "Blur Amount", eFeatureType.SliderFloat, "How strong the blur gets at full speed", 0.1, 1.0, 0.05, 0.5)
    F.sbStart = Slider(H.sbStart, "Blur Starts At (mph)", eFeatureType.SliderInt, "Below this speed there's no blur", 0, 150, 5, 60)
    F.sbFull = Slider(H.sbFull, "Full Blur At (mph)", eFeatureType.SliderInt, "The speed where the blur reaches its full amount", 30, 250, 5, 160)
    local sb = { set = false, k = 0.0, at = 0 }
    local function BlurOff()
        -- (never clears the LSD screen effect's own layer)
        if sb.set and not ((F.sfxMode and (F.sfxMode:GetListIndex() or 0) == 1) or F.introPlaying) then
            nv(N.SET_EXTRA_TIMECYCLE_MODIFIER_STRENGTH, 1.0) -- (back to full, so the next thing that uses this layer isn't faint)
            nv(N.CLEAR_EXTRA_TIMECYCLE_MODIFIER)
        end
        sb.set, sb.k = false, 0.0
    end
    table.insert(F.unloadHooks, function() pcall(BlurOff) end)
    local function BlurTick(now)
        local veh = F.On("sbOn") and X.Car() or nil
        local on = veh and (not F.dcMaster or F.On("dcMaster"))
        if on and ((F.sfxMode and (F.sfxMode:GetListIndex() or 0) == 1) or F.introPlaying) then sb.set = false return end -- (LSD is using that layer)
        if not on then if sb.set then BlurOff() end return end
        local mph = (Natives.InvokeFloat(N.GET_ENTITY_SPEED, veh) or 0) * 2.23694
        local s0, s1 = F.sbStart:GetIntValue() or 60, F.sbFull:GetIntValue() or 160
        local t = math.max(0, math.min(1, (mph - s0) / math.max(5, s1 - s0)))
        local target = t * (F.sbAmt:GetFloatValue() or 0.5)
        sb.k = sb.k + (target - sb.k) * 0.08
        if sb.k > 0.01 then
            if not sb.set or now - sb.at > 2000 then nv(N.SET_EXTRA_TIMECYCLE_MODIFIER, "rply_motionblur") sb.set, sb.at = true, now end
            nv(N.SET_EXTRA_TIMECYCLE_MODIFIER_STRENGTH, sb.k + 0.0)
        elseif sb.set then
            BlurOff()
        end
    end

    F.carExtrasTick = function()
        local now = NowMs()
        local function Run(name, fn)
            local ok, err = pcall(fn, now)
            if not ok then
                F._ceErr = F._ceErr or {}
                if now - (F._ceErr[name] or 0) > 10000 then F._ceErr[name] = now LogErr(name, err) end
            end
        end
        Run("dashcam look", DashTick)
        Run("speed blur", BlurTick)
    end
end)

Try("creating first person clear windows", function()
    local N = {
        PLAYER_PED_ID                  = 0xD80958FC74E988A6,
        GET_VEHICLE_PED_IS_IN          = 0x9A9112A0FE9A4713,
        GET_CAM_ACTIVE_VIEW_MODE_CONTEXT = 0x19CAFA3C87F7C2FF,
        GET_CAM_VIEW_MODE_FOR_CONTEXT  = 0xEE778F8C7E1142E2,
        GET_FOLLOW_VEHICLE_CAM_VIEW_MODE = 0xA4FF579AC0E3AAAE,
        GET_VEHICLE_WINDOW_TINT        = 0x0EE21293DAD47C95,
        SET_VEHICLE_WINDOW_TINT        = 0x57C51E6BAD752696,
        DOES_ENTITY_EXIST              = 0x7239B21A38F536BA,
    }
    local FIRST_PERSON = 4
    local cleared = nil -- { veh, tint }
    local outSince = nil
    local function Put(veh, tint) pcall(Natives.InvokeVoid, N.SET_VEHICLE_WINDOW_TINT, veh, tint) end
    local function Undo()
        if not cleared then return end
        local c = cleared
        cleared = nil
        if not c.same and IB(N.DOES_ENTITY_EXIST, c.veh) then Put(c.veh, c.tint) end
    end
    F.fpTintUndo = Undo
    local function InFirstPerson()
        local mode
        pcall(function()
            local ctx = Natives.InvokeInt(N.GET_CAM_ACTIVE_VIEW_MODE_CONTEXT)
            mode = Natives.InvokeInt(N.GET_CAM_VIEW_MODE_FOR_CONTEXT, ctx)
        end)
        if mode == nil then
            pcall(function() mode = Natives.InvokeInt(N.GET_FOLLOW_VEHICLE_CAM_VIEW_MODE) end)
        end
        return mode == FIRST_PERSON
    end
    F.fpTint = Toggle(H.fpTint, "Clear Windows In First Person",
        "Takes the tint off your windows while you're in first person in a vehicle, and puts it back when you're not", true)
    local nextCheck = 0
    F.fpTintTick = function()
        local now = NowMs()
        if now < nextCheck then return end
        nextCheck = now + 150
        local veh = 0
        if F.fpTint:IsToggled() and not F._lgnTint then
            local ped = Natives.InvokeInt(N.PLAYER_PED_ID)
            veh = Natives.InvokeInt(N.GET_VEHICLE_PED_IS_IN, ped, false) or 0
            if veh ~= 0 and F.notMyCar(veh) then veh = 0 end -- (a friend's car keeps its tint)
        end
        -- (the tint is only changed once when you go in / out - changing it over and over
        -- is what made the windows flicker - and a split-second camera blip is ignored)
        if veh ~= 0 and InFirstPerson() then
            outSince = nil
            if cleared and cleared.veh == veh then return end
            Undo()
            local tint = Natives.InvokeInt(N.GET_VEHICLE_WINDOW_TINT, veh)
            if tint == 0 then cleared = { veh = veh, tint = 0, same = true } return end -- already clear
            cleared = { veh = veh, tint = tint }
            Put(veh, 0)
        elseif cleared then
            if veh == cleared.veh then
                outSince = outSince or now
                if now - outSince < 600 then return end
            end
            outSince = nil
            Undo()
        end
    end
end)

-- ---------------------------------------------------------------------
-- PER CAR (Drift Cam tab): the head cam's seat, the first person FOV and the dashcam's spot remembered for each car
-- model - get in and they're how you left them for that car. Lua\ACDriftCam\cars.txt
-- ---------------------------------------------------------------------
Try("creating per-car settings", function()
    F.pcCar = Toggle(H.pcCar, "Remember Per Car",
        "Head Cam Forward / Height, First Person FOV and the Dashcam's position and lens are remembered for each car model - " ..
        "get in and they're set how you left them for that car", false)
    local KEYS = { { "dcBaseOn", "bool" }, { "dcBase", "int" }, { "dcCamFwd", "float" }, { "dcCamUp", "float" },
                   { "dashFwd", "float" }, { "dashUp", "float" }, { "dashFov", "int" } }
    local function File() return CfgDir() .. "\\cars.txt" end
    local cars = {}
    pcall(function()
        local txt = FileMgr.DoesFileExist(File()) and FileMgr.ReadFileContent(File()) or ""
        for line in txt:gmatch("[^\r\n]+") do
            local m, rest = line:match("^(%-?%d+)|(.*)$")
            if m then
                local e = {}
                for k, v in rest:gmatch("(%w+)=([^,]*)") do e[k] = v end
                cars[tonumber(m)] = e
            end
        end
    end)
    local function Save()
        local out = {}
        for m, e in pairs(cars) do
            local kv = {}
            for _, k in ipairs(KEYS) do if e[k[1]] then kv[#kv + 1] = k[1] .. "=" .. e[k[1]] end end
            out[#out + 1] = m .. "|" .. table.concat(kv, ",")
        end
        pcall(FileMgr.WriteFileContent, File(), table.concat(out, "\n") .. "\n", false)
    end
    local function Now()
        local e = {}
        for _, k in ipairs(KEYS) do
            local f = F[k[1]]
            if f then
                local ok, v = pcall(function()
                    if k[2] == "bool" then return f:IsToggled() and "1" or "0"
                    elseif k[2] == "int" then return tostring(math.floor(f:GetIntValue() or 0))
                    else return ("%.4f"):format(f:GetFloatValue() or 0) end
                end)
                if ok then e[k[1]] = v end
            end
        end
        return e
    end
    local function Sig(e) local t = {} for _, k in ipairs(KEYS) do t[#t + 1] = tostring(e[k[1]]) end return table.concat(t, ",") end
    local function Apply(e)
        for _, k in ipairs(KEYS) do
            local f, v = F[k[1]], e[k[1]]
            if f and v then pcall(function()
                if k[2] == "bool" then f:SetBoolValue(v == "1")
                elseif k[2] == "int" then f:SetIntValue(math.floor(tonumber(v) or 0))
                else f:SetFloatValue((tonumber(v) or 0) + 0.0) end
            end) end
        end
    end
    local P = { cur = nil, sig = nil, changedAt = nil, next = 0 }
    F.pcTick = function(now)
        if now < P.next then return end
        P.next = now + 300
        if not F.pcCar:IsToggled() then P.cur = nil return end
        local ped = Natives.InvokeInt(0xD80958FC74E988A6) -- PLAYER_PED_ID
        local model = nil
        if IB(0x997ABD671D25CA0B, ped, false) then -- IS_PED_IN_ANY_VEHICLE
            local veh = Natives.InvokeInt(0x9A9112A0FE9A4713, ped, false) -- GET_VEHICLE_PED_IS_IN
            model = (veh and veh ~= 0) and Natives.InvokeInt(0x9F47B058362C84B5, veh) or nil -- GET_ENTITY_MODEL
        end
        if model ~= P.cur then
            if P.changedAt then Save() P.changedAt = nil end
            P.cur = model
            if model and cars[model] then Apply(cars[model]) end
            P.sig = Sig(Now())
            return
        end
        if not model then return end
        local e = Now()
        local sig = Sig(e)
        if sig ~= P.sig then P.sig, cars[model], P.changedAt = sig, e, now end
        if P.changedAt and now - P.changedAt > 1500 then Save() P.changedAt = nil end
    end
    table.insert(F.unloadHooks, function() if P.changedAt then Save() end end)
    F.pcTest = { cars = cars, Save = Save } -- (for the tests)
end)

-- ---------------------------------------------------------------------
-- HOTKEYS (Settings tab): a key that switches Camera Effects on / off, and one for the Dashcam
-- ---------------------------------------------------------------------
Try("creating hotkeys", function()
    local KEYS = { { "None", 0 }, { "F5", 0x74 }, { "F6", 0x75 }, { "F7", 0x76 }, { "F8", 0x77 }, { "F9", 0x78 }, { "F10", 0x79 },
        { "F11", 0x7A }, { "Insert", 0x2D }, { "Home", 0x24 }, { "End", 0x23 }, { "Page Up", 0x21 }, { "Page Down", 0x22 },
        { "Numpad 0", 0x60 }, { "Numpad /", 0x6F }, { "Numpad *", 0x6A }, { "Numpad -", 0x6D }, { "Numpad +", 0x6B },
        { "Mouse Side 1", 0x05 }, { "Mouse Side 2", 0x06 }, { "B", 0x42 }, { "J", 0x4A }, { "K", 0x4B }, { "L", 0x4C }, { "N", 0x4E } }
    local names = {}
    for i, k in ipairs(KEYS) do names[i] = k[1] end
    F.hkCam = FeatureMgr.AddFeature(H.hkCam, "Camera Effects Key", eFeatureType.Combo, "Press it to switch Camera Effects (everything on the Drift Cam tab) on or off")
    F.hkCam:SetList(names)
    F.hkDash = FeatureMgr.AddFeature(H.hkDash, "Dashcam Key", eFeatureType.Combo, "Press it to switch the Dashcam on or off")
    F.hkDash:SetList(names)
    F.lbKey = FeatureMgr.AddFeature(H.lbKey, "Look Back Key", eFeatureType.Combo,
        "Hold it to look behind in the first person head cam. GTA's own look behind (C) always works too - this is an extra key")
    F.lbKey:SetList(names)
    F.lookBackDown = function()
        local k = KEYS[(F.lbKey:GetListIndex() or 0) + 1]
        return k ~= nil and k[2] > 0 and Utils.IsKeyDown(k[2]) and not F.Typing()
    end
    local was = {}
    local function Key(f, id, target, label)
        local k = KEYS[(f:GetListIndex() or 0) + 1]
        local down = k and k[2] > 0 and Utils.IsKeyDown(k[2]) and not F.Typing()
        if down and not was[id] then
            local on = not target:IsToggled()
            target:SetBoolValue(on)
            Notify(label .. (on and ": on" or ": off"))
        end
        was[id] = down
    end
    F.hkTick = function()
        Key(F.hkCam, "cam", F.dcMaster, "Camera Effects")
        Key(F.hkDash, "dash", F.dashOn, "Dashcam")
    end
end)

-- ---------------------------------------------------------------------
-- CONFIGS: Lua\ACDriftCam\configs\<name>.cfg. The one set with Load This On Startup loads when the script
-- starts; Auto-Save writes your changes into the config you're on a couple of seconds after you make them.
-- ---------------------------------------------------------------------
local KEYS = {
    { "dcMaster", "bool" },
    { "dcOn", "bool" },
    { "dcAmount", "float" },
    { "dcMax", "int" },
    { "dcSmooth", "int" },
    { "dcThird", "bool" },
    { "dcG", "bool" },
    { "dcGAmt", "float" },
    { "dcBaseOn", "bool" },
    { "dcBase", "int" },
    { "dcFov", "bool" },
    { "dcFovAmt", "float" },
    { "dcFovStart", "int" },
    { "dcFovFull", "int" },
    { "dcFovSmooth", "int" },
    { "dcFovMax", "int" },
    { "dcCamFwd", "float" },
    { "dcCamUp", "float" },
    { "dcLock", "bool" },
    { "dcHide", "bool" },
    { "dcHideMode", "combo" },
    { "dcSpeed", "bool" },
    { "dcSpeedAmt", "float" },
    { "dashOn", "bool" },
    { "dashCam", "bool" },
    { "dashView", "combo" },
    { "dashStyle", "combo" },
    { "dashFov", "int" },
    { "dashFwd", "float" },
    { "dashUp", "float" },
    { "dashShake", "bool" },
    { "dashSpeed", "bool" },
    { "dashGps", "bool" },
    { "dashTime", "bool" },
    { "dashFrame", "bool" },
    { "dashFilter", "combo" },
    { "dashHud", "bool" },
    { "sbOn", "bool" },
    { "sbAmt", "float" },
    { "sbStart", "int" },
    { "sbFull", "int" },
    { "speedoUnit", "combo" },
    { "fpTint", "bool" },
    { "pcCar", "bool" },
    { "hkCam", "combo" },
    { "hkDash", "combo" },
    { "lbKey", "combo" }
}
-- your LGNFX camera settings when ACDriftCam was made: what it starts with, and what Back To My Defaults puts back
local DEFAULTS = {
    dcMaster = "1",
    dcOn = "1",
    dcAmount = "0.81000000238418579",
    dcMax = "51",
    dcSmooth = "5",
    dcThird = "0",
    dcG = "1",
    dcGAmt = "0.843999981880188",
    dcBaseOn = "1",
    dcBase = "85",
    dcFov = "1",
    dcFovAmt = "7.4790000915527344",
    dcFovStart = "37",
    dcFovFull = "160",
    dcFovSmooth = "7",
    dcFovMax = "88",
    dcCamFwd = "-0.082999996840953827",
    dcCamUp = "0.050999999046325684",
    dcLock = "1",
    dcHide = "1",
    dcHideMode = "1",
    dcSpeed = "1",
    dcSpeedAmt = "0.3880000114440918",
    dashOn = "0",
    dashCam = "1",
    dashView = "0",
    dashStyle = "0",
    dashFov = "88",
    dashFwd = "0.0",
    dashUp = "0.0",
    dashShake = "1",
    dashSpeed = "1",
    dashGps = "1",
    dashTime = "1",
    dashFrame = "1",
    dashFilter = "1",
    dashHud = "1",
    sbOn = "0",
    sbAmt = "0.95599997043609619",
    sbStart = "1",
    sbFull = "43",
    speedoUnit = "0",
    fpTint = "0"
}
local CFG = { cur = nil, sig = nil, changedAt = nil, names = {}, delAsk = nil }
local function CfgFolder() local d = CfgDir() .. "\\configs" pcall(FileMgr.CreateDir, d) return d end
local function CfgPath(name) return CfgFolder() .. "\\" .. name .. ".cfg" end
local function StartFile() return CfgDir() .. "\\startup.txt" end
local function CleanName(s) return (tostring(s or ""):gsub('[\\/:%*%?"<>|]', ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function ValueOf(k, kind)
    local f = F[k]
    if not f then return nil end
    local ok, v = pcall(function()
        if kind == "bool" then return f:IsToggled() and "1" or "0"
        elseif kind == "int" then return tostring(math.floor(f:GetIntValue() or 0))
        elseif kind == "float" then return ("%.4f"):format(f:GetFloatValue() or 0)
        else return tostring(math.floor(f:GetListIndex() or 0)) end
    end)
    return ok and v or nil
end
local function SetValue(k, kind, v, asDefault)
    local f = F[k]
    if not f or v == nil then return end
    pcall(function()
        if kind == "bool" then
            local b = v == "1" or v == "true"
            f:SetBoolValue(b) if asDefault then f:SetDefaultValue(b) end
        elseif kind == "int" then
            local n = math.floor(tonumber(v) or 0)
            f:SetIntValue(n) if asDefault then f:SetDefaultValue(n) end
        elseif kind == "float" then
            local n = (tonumber(v) or 0) + 0.0
            f:SetFloatValue(n) if asDefault then f:SetDefaultValue(n) end
        else
            local n = math.floor(tonumber(v) or 0)
            f:SetListIndex(n) if asDefault then pcall(function() f:SetDefaultValue(n) end) end
        end
    end)
end
local function Lines()
    local out = {}
    for _, e in ipairs(KEYS) do
        local v = ValueOf(e[1], e[2])
        if v then out[#out + 1] = e[1] .. "=" .. v end
    end
    return out
end
local function ApplyText(txt)
    local kinds = {}
    for _, e in ipairs(KEYS) do kinds[e[1]] = e[2] end
    for line in tostring(txt or ""):gmatch("[^\r\n]+") do
        local k, v = line:match("^(%w+)=(.*)$")
        if k and kinds[k] then SetValue(k, kinds[k], v) end
    end
end
local function ApplyDefaults(asDefault)
    for _, e in ipairs(KEYS) do if DEFAULTS[e[1]] then SetValue(e[1], e[2], DEFAULTS[e[1]], asDefault) end end
end
local function NowSig() return table.concat(Lines(), "\n") end
local function WriteCfg(name)
    local ok = pcall(FileMgr.WriteFileContent, CfgPath(name), NowSig() .. "\n", false)
    return ok
end
local function ReadStartup()
    local ok, t = pcall(function() return FileMgr.DoesFileExist(StartFile()) and FileMgr.ReadFileContent(StartFile()) or "" end)
    return ok and CleanName((t or ""):match("[^\r\n]*")) or ""
end
local function RefreshList()
    local names = {}
    local ok, found = pcall(FileMgr.FindFiles, CfgFolder(), ".cfg", false)
    if ok and found then
        local seen = {}
        local function Add(p)
            local n = tostring(p):match("([^\\/]+)%.cfg$")
            if n and not seen[n:lower()] then seen[n:lower()] = true names[#names + 1] = n end
        end
        pcall(function() for _, p in pairs(found) do Add(p) end end)
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    CFG.names = names
    local keep = 0
    for i, n in ipairs(names) do if CFG.cur and n:lower() == CFG.cur:lower() then keep = i - 1 end end
    pcall(function() F.cfgList:SetList(#names > 0 and names or { "(no configs yet - type a name and press Save Config)" }) end)
    pcall(function() F.cfgList:SetListIndex(keep) end)
end
local function Picked() return CFG.names[(F.cfgList:GetListIndex() or 0) + 1] end
local function LoadCfg(name, quiet)
    local ok, txt = pcall(function() return FileMgr.DoesFileExist(CfgPath(name)) and FileMgr.ReadFileContent(CfgPath(name)) or nil end)
    if not ok or not txt then if not quiet then Notify("Couldn't find the config " .. name) end return false end
    ApplyDefaults(false) -- (anything the config doesn't mention goes back to your defaults)
    ApplyText(txt)
    CFG.cur, CFG.sig, CFG.changedAt = name, NowSig(), nil
    pcall(function() F.cfgName:SetStringValue(name) end)
    RefreshList()
    if not quiet then Notify("Loaded config: " .. name) end
    return true
end

F.cfgName = FeatureMgr.AddFeature(H.cfgName, "Config Name", eFeatureType.InputText, "The name to save your camera settings under")
F.cfgSave = Button(H.cfgSave, "Save Config", "Saves every camera setting under the name above (and that's the config you're on now)", function()
    local name = CleanName(F.cfgName:GetStringValue())
    if name == "" then Notify("Type a name in Config Name first") return end
    if WriteCfg(name) then
        CFG.cur, CFG.sig, CFG.changedAt = name, NowSig(), nil
        RefreshList()
        Notify("Saved config: " .. name)
    else
        Notify("Couldn't save the config " .. name)
    end
end)
F.cfgList = FeatureMgr.AddFeature(H.cfgList, "Saved Configs", eFeatureType.Combo, "Your saved camera configs")
F.cfgLoad = Button(H.cfgLoad, "Load Selected Config", "Puts every camera setting back how the picked config has it", function()
    local n = Picked()
    if not n then Notify("No config picked") return end
    LoadCfg(n)
end)
F.cfgStart = Button(H.cfgStart, "Load This On Startup", "The picked config loads every time ACDriftCam starts", function()
    local n = Picked()
    if not n then Notify("No config picked") return end
    if pcall(FileMgr.WriteFileContent, StartFile(), n .. "\n", false) then Notify(n .. " now loads on startup") end
end)
F.cfgDel = Button(H.cfgDel, "Delete Selected Config", "Deletes the picked config (press it twice)", function()
    local n = Picked()
    if not n then Notify("No config picked") return end
    local a = CFG.delAsk
    if not (a and a.name == n and NowMs() - a.at < 4000) then
        CFG.delAsk = { name = n, at = NowMs() }
        Notify("Press Delete Selected Config again to delete " .. n)
        return
    end
    CFG.delAsk = nil
    local ok = pcall(FileMgr.DeleteFile, CfgPath(n))
    if not ok then pcall(FileMgr.WriteFileContent, CfgPath(n), "", false) end
    if CFG.cur and CFG.cur:lower() == n:lower() then CFG.cur = nil end
    RefreshList()
    Notify("Deleted config: " .. n)
end)
F.cfgAuto = Toggle(H.cfgAuto, "Auto-Save My Config", "Your changes are saved into the config you're on a couple of seconds after you make them", true)
F.cfgReset = Button(H.cfgReset, "Back To My Defaults", "Every camera setting goes back to how ACDriftCam comes", function()
    ApplyDefaults(false)
    Notify("Camera settings back to your defaults" .. (CFG.cur and (" (Auto-Save puts them in " .. CFG.cur .. ")") or ""))
end)
F.cfgRefresh = Button(H.cfgRefresh, "Refresh Config List", "Looks in the configs folder again", function() RefreshList() end)
F.drawCfgInfo = function()
    local st = ReadStartup()
    pcall(ImGui.TextDisabled, "On now: " .. (CFG.cur or "(none - save one to keep your changes)") ..
        "     Loads on startup: " .. (st ~= "" and st or "(none)"))
    pcall(ImGui.TextDisabled, "Folder: Lua\\ACDriftCam\\configs")
end
-- auto-save (checked twice a second)
F.cfgTick = function(now)
    if now < (CFG.nextCheck or 0) then return end
    CFG.nextCheck = now + 500
    local sig = NowSig()
    if sig ~= CFG.sig then CFG.sig, CFG.changedAt = sig, now end
    if CFG.changedAt and now - CFG.changedAt > 2000 then
        CFG.changedAt = nil
        if CFG.cur and F.cfgAuto:IsToggled() then WriteCfg(CFG.cur) end
    end
end
-- (none of these go in Cherax's own config - this script keeps its own)
for _, e in ipairs(KEYS) do local f = F[e[1]] if f then pcall(function() f:SetSaveable(false) end) end end
for _, k in ipairs({ "cfgName", "cfgList", "cfgAuto" }) do pcall(function() F[k]:SetSaveable(false) end) end

-- STARTING UP: your defaults, then the startup config. First time: a "default" config is made from your
-- LGNFX settings and set to load on startup
Try("loading your config", function()
    ApplyDefaults(true)
    local st = ReadStartup()
    if st == "" then
        local okE, there = pcall(FileMgr.DoesFileExist, CfgPath("default"))
        if not (okE and there) then WriteCfg("default") end
        pcall(FileMgr.WriteFileContent, StartFile(), "default\n", false)
        st = "default"
    end
    if not LoadCfg(st, true) then CFG.sig = NowSig() end
    RefreshList()
end)

-- ---------------------------------------------------------------------
-- THE MENU: one "ACDriftCam" tab with three tabs inside - Drift Cam, Dashcam, Settings - in Cherax's own look
-- ---------------------------------------------------------------------
local function RenderOne(hash)
    local okR, errR = pcall(ClickGUI.RenderFeature, hash)
    local okH, hov = pcall(ImGui.IsItemHovered, 0)
    if not okR then LogErr("drawing an option", errR) end
    if okH and hov then
        local info = FeatureMgr.info[hash]
        if info and info.desc and info.desc ~= "" then pcall(ImGui.SetTooltip, info.desc) end
    end
end
local function RenderPage(secs)
    for _, section in ipairs(secs) do
        if ClickGUI.BeginCustomChildWindow(section[1]) then
            local ok, err = pcall(function()
                if section.draw and section.drawFirst then pcall(section.draw) end
                -- (a feature with its own switch: while it's off, just the switch)
                local off = section.master and not (function() local okT, on = pcall(function() return FeatureMgr.GetFeature(section.master):IsToggled() end) return okT and on end)()
                if off then
                    RenderOne(section.master)
                    pcall(ImGui.TextDisabled, section.hint or ("Turn it on to see its " .. (#section[2] - 1) .. " settings"))
                else
                    for _, hash in ipairs(section[2]) do RenderOne(hash) end
                end
                if section.draw and not section.drawFirst then pcall(section.draw) end
            end)
            if not ok then LogErr("drawing " .. tostring(section[1]), err) end
            ClickGUI.EndCustomChildWindow()
        end
    end
end
local function WaitNote()
    if F._wait then
        pcall(ImGui.TextDisabled, "Waiting: LGNFX's own camera effects / dashcam / speed blur are on - switch them off in LGNFX (Vehicle > Cameras) to use these")
    end
end

local PAGES = {
    { "Drift Cam", hint = "Camera effects while you drive: the drift look, first person head cam, speed FOV zoom, speed shake and blur", {
        { "Camera Effects", { H.dcMaster, H.dcThird }, drawFirst = true, draw = WaitNote },
        { "Drift Look", { H.dcOn, H.dcAmount, H.dcMax, H.dcSmooth }, master = H.dcOn },
        { "First Person Head Cam", { H.dcLock, H.dcCamFwd, H.dcCamUp, H.dcBaseOn, H.dcBase, H.dcHide, H.dcHideMode, H.lbKey } },
        { "Per Car", { H.pcCar }, draw = function() pcall(ImGui.TextDisabled, "Seat position, FOV and the dashcam's spot - each car remembers its own") end },
        { "G-Force Head Movement", { H.dcG, H.dcGAmt }, master = H.dcG },
        { "Speed FOV Zoom", { H.dcFov, H.dcFovAmt, H.dcFovStart, H.dcFovFull, H.dcFovSmooth, H.dcFovMax }, master = H.dcFov },
        { "Speed Shake", { H.dcSpeed, H.dcSpeedAmt }, master = H.dcSpeed },
        { "Speed Blur", { H.sbOn, H.sbAmt, H.sbStart, H.sbFull }, master = H.sbOn },
        { "Windows", { H.fpTint }, draw = function()
            if F._lgnTint then pcall(ImGui.TextDisabled, "Waiting: LGNFX's Clear Windows In First Person is on (it does the same job)") end
        end },
    } },
    { "Dashcam", hint = "Real dashcam footage: a camera on the windscreen, with the date, time, speed, GPS and REC on screen", {
        { "Dashcam", { H.dashOn, H.dashCam, H.dashView, H.dashFov, H.dashFwd, H.dashUp, H.dashShake }, master = H.dashOn,
            drawFirst = true, draw = function() WaitNote() if F.drawDashCar then F.drawDashCar() end end,
            hint = "While the Dashcam is on, the Drift Cam effects and Speed Blur are paused (they come back after)" },
        { "On-Screen Overlay", { H.dashStyle, H.dashSpeed, H.speedoUnit, H.dashGps, H.dashTime, H.dashFrame, H.dashFilter, H.dashHud } },
    } },
    { "Settings", hint = "Hotkeys, and your camera setups saved as configs (and the one that loads on startup)", {
        { "Hotkeys", { H.hkCam, H.hkDash } },
        { "Configs", { H.cfgName, H.cfgSave, H.cfgList, H.cfgLoad, H.cfgStart, H.cfgDel, H.cfgAuto, H.cfgRefresh },
            draw = function() F.drawCfgInfo() end, drawFirst = true },
        { "Defaults", { H.cfgReset }, draw = function() pcall(ImGui.TextDisabled, "Your defaults = the camera settings ACDriftCam comes with") end },
    } },
}
local function RenderTab()
    pcall(F.NoteUiTyping)
    if type(ImGui.BeginTabBar) == "function" and ImGui.BeginTabBar("##acdc_tabs", 0) then
        for _, sp in ipairs(PAGES) do
            if ImGui.BeginTabItem(sp[1] .. "##acdc") then
                if sp.hint then pcall(ImGui.TextDisabled, sp.hint) end
                local ok, err = pcall(RenderPage, sp[2])
                if not ok then LogErr("drawing " .. sp[1], err) end
                ImGui.EndTabItem()
            end
        end
        ImGui.EndTabBar()
    else
        for _, sp in ipairs(PAGES) do RenderPage(sp[2]) end
    end
end
Try("adding the menu tab", function()
    pcall(ClickGUI.RemoveTab, AC_NAME)
    ClickGUI.AddTab(AC_NAME, RenderTab)
end)
local listRoot, listMain = nil, nil
Try("adding the list menu tab", function()
    listRoot = ListGUI.GetRootTab()
    listMain = listRoot:AddSubTab(AC_NAME, "Drift camera, head cam and dashcam")
    for _, sp in ipairs(PAGES) do
        local sub = listMain:AddSubTab(sp[1], AC_NAME .. " - " .. sp[1])
        for _, section in ipairs(sp[2]) do
            pcall(function() sub:AddSeperator(section[1]) end)
            for _, h in ipairs(section[2]) do pcall(function() sub:AddFeature(h) end) end
        end
    end
end)

-- ---------------------------------------------------------------------
-- THE LOOP: every frame, each piece on its own (one with a problem can't stop the others)
-- ---------------------------------------------------------------------
-- (LGNFX's own cameras: checked once a second - read only, nothing of LGNFX's is ever changed)
local LGN_IDS = { J("LgnFx_DriftCam_Master"), J("LgnFx_CarX_dashOn"), J("LgnFx_CarX_sbOn") }
local LGN_SUBS = { J("LgnFx_DriftCam_On"), J("LgnFx_DriftCam_G"), J("LgnFx_DriftCam_Speed"), J("LgnFx_DriftCam_Fov"), J("LgnFx_DriftCam_BaseOn") }
local waitAt, waitTold = 0, false
local function WaitTick(now)
    if now < waitAt then return end
    waitAt = now + 1000
    local function On(h) local okG, f = pcall(FeatureMgr.GetFeature, h) local okT, t = pcall(function() return f and f:IsToggled() end) return okG and okT and t == true end
    local lgnCam = false
    if On(LGN_IDS[1]) then for _, h in ipairs(LGN_SUBS) do if On(h) then lgnCam = true end end end
    local wait = lgnCam or On(LGN_IDS[2]) or On(LGN_IDS[3])
    local mineOn = (F.dcMaster and F.dcMaster:IsToggled()) or (F.dashOn and F.dashOn:IsToggled()) or (F.sbOn and F.sbOn:IsToggled())
    if wait and mineOn and not waitTold then
        waitTold = true
        Notify("LGNFX's own camera effects are on - ACDriftCam waits until you switch them off in LGNFX (Vehicle > Cameras)")
    elseif not wait then
        waitTold = false
    end
    F._wait = wait
    F._lgnTint = On(J("LgnFx_FirstPersonClearWindows")) -- (LGNFX's own Clear Windows is on: ours waits, so only one changes the tint)
end
local STEPS = {
    { "waiting for lgnfx", function() WaitTick(NowMs()) end },
    { "drift camera", function() if F.dcTick then F.dcTick() end end },
    { "dashcam and speed blur", function() if F.carExtrasTick then F.carExtrasTick() end end },
    { "first person windows", function() if F.fpTintTick then F.fpTintTick() end end },
    { "per car", function() if F.pcTick then F.pcTick(NowMs()) end end },
    { "hotkeys", function() if F.hkTick then F.hkTick() end end },
    { "configs", function() F.cfgTick(NowMs()) end },
    { "on-screen text", function() HUD.Frame(NowMs()) end },
}
local stepErrAt = {}
Script.QueueJob(function()
    while not ShouldStop() do
        local now = NowMs()
        for _, step in ipairs(STEPS) do
            local ok, err = pcall(step[2])
            if not ok and now - (stepErrAt[step[1]] or 0) > 10000 then
                stepErrAt[step[1]] = now
                LogErr(step[1], err)
            end
        end
        Script.Yield(0)
    end
    for _, fn in ipairs(F.unloadHooks or {}) do pcall(fn) end
end)
-- (typing in any Cherax text box: keys don't do camera things meanwhile)
pcall(EventMgr.RegisterHandler, eLuaEvent.ON_PRESENT, function() pcall(F.NoteUiTyping) end)

-- STOPPING: the cameras let go (your own camera, character and screen come back), the last changes are saved,
-- then the menu and options go
pcall(EventMgr.RegisterHandler, eLuaEvent.ON_UNLOAD, function()
    running = false
    pcall(function() if CFG.cur and CFG.changedAt and F.cfgAuto:IsToggled() then WriteCfg(CFG.cur) end end)
    pcall(ClickGUI.RemoveTab, AC_NAME)
    if listRoot and listMain then pcall(function() listRoot:RemoveSubTab(listMain) end) end
    for _, fn in ipairs(F.unloadHooks or {}) do pcall(fn) end
    F.unloadHooks = {}
    if F.fpTintUndo then pcall(F.fpTintUndo) end -- (your windows' tint back)
    for _, hash in pairs(H) do pcall(FeatureMgr.RemoveFeature, hash) end
end)
Notify(AC_VERSION .. " loaded")
