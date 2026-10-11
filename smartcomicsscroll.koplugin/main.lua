-- THIN GUTTER TEST: SAFE + total ON/OFF + 3-row detection.
-- TEST FIT SCAN v1: preserve original SAFE; search at least to reachable fit limit; 1-row gap tolerance.
-- Smart Comics Scroll 0.2.0 - independent-page viewport prototype
-- Based on the integration/rendering ideas of Webtoon Helper 2.2.4.
-- Instead of detecting panels, every CBZ/CBR page is treated as part of one
-- continuous vertical strip. A page turn moves roughly one screen, then looks
-- around the target for a white/black separator and snaps just AFTER it.

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local Event = require("ui/event")
local LuaSettings = require("luasettings")
local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local Geom = require("ui/geometry")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local StripOverlay = WidgetContainer:extend{ plugin = nil }
function StripOverlay:paintTo(bb, x, y)
    local P = self.plugin
    if not P or not P.is_enabled or not P.current_y or Screen:getWidth() <= Screen:getHeight() then return end
    P:paintViewport(bb)
end

local SmartScroll = WidgetContainer:extend{
    name = "smart_comics_scroll",
    is_doc_only = true,
    is_enabled = true,

    -- Separator detection. Deliberately simple: no panel recognition.
    white_threshold = 245,
    white_ratio = 0.92,
    black_threshold = 14,
    black_ratio = 0.96,
    min_gap_px = 10,          -- native/source px minimum (before analysis scale)
    adaptive_gap_ratio = 0.003,
    analysis_max_width = 360,
    sample_width = 80,

    -- Navigation.
    search_range = 0.32,      -- +/- 24% of screen around nominal next boundary
    overlap_ratio = 0.035,    -- fallback overlap when a panel must be split
    min_advance_ratio = 0.58, -- never snap absurdly close to current top
    max_advance_ratio = 1.30,

    page_cache = {},
    render_cache = {},
    render_cache_order = {},
    preload_pending = false,
    preload_pages = 2,
    layout = nil,
    current_y = nil,
    overlay = nil,
    visual_debug = false, -- OFF by default; available in settings
    last_snap = nil,
    navigating = false,
    debug_taps = 0,
    debug_snaps = 0,
    debug_hook_calls = 0,

    -- Webtoon Helper-style fit-to-height, deliberately limited:
    -- if the next separator is only a little below the screen, shrink the
    -- current slice just enough to show it completely.
    fit_to_height = true,
    fit_min_scale = 0.82, -- legacy setting (not used by Page-End Fit)
    page_end_max_reduction = 33, -- percentage, default 33
    fit_end = nil,
    fit_scale = 1.0,
    fit_at_page_end = false,
    fit_resume_y = nil,

    -- Optional right sidebar: narrows the webtoon render area on wide displays.
    sidebar_enabled = false,
    sidebar_ratio = 0.10,
}

function SmartScroll:readSettings()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/smart_comics_scroll.lua")
    local function n(k,d) return tonumber(self.settings:readSetting(k)) or d end
    self.is_enabled = self.settings:readSetting("is_enabled") ~= false
    self.visual_debug = self.settings:readSetting("visual_debug") == true
    self.white_threshold = n("white_threshold",245)
    self.white_ratio = math.min(n("white_ratio",0.92),0.92)
    self.black_threshold = n("black_threshold",14)
    self.black_ratio = math.min(n("black_ratio",0.96),0.96)
    self.min_gap_px = n("min_gap_px",10)
    self.adaptive_gap_ratio = n("adaptive_gap_ratio",0.003)
    self.search_range = n("search_range",0.32)
    self.overlap_ratio = n("overlap_ratio",0.035)
    self.fit_to_height = self.settings:readSetting("fit_to_height") ~= false
    self.auto_trim_top = self.settings:readSetting("auto_trim_top") ~= false
    self.fit_min_scale = n("fit_min_scale",0.82)
    self.page_end_max_reduction = math.max(0,math.min(40,n("page_end_max_reduction",33)))
    self.preload_pages = math.max(0, math.min(10, math.floor(n("preload_pages",2))))
    self.sidebar_enabled = false -- Keep full screen width; ignore previously saved sidebar setting
    self.sidebar_ratio = math.max(0.01, math.min(0.20, n("sidebar_ratio",0.10)))
end

function SmartScroll:saveSettings()
    for _,k in ipairs{
        "is_enabled","visual_debug","white_threshold","white_ratio","black_threshold","black_ratio",
        "min_gap_px","adaptive_gap_ratio","search_range","overlap_ratio","fit_to_height","fit_min_scale","preload_pages",
        "sidebar_enabled","sidebar_ratio","page_end_max_reduction","auto_trim_top"
    } do self.settings:saveSetting(k,self[k]) end
    self.settings:flush()
end

function SmartScroll:init()
    self:readSettings()
    Dispatcher:registerAction("smart_comics_next", {category="none", event="SmartComicsNext", title=_("Smart Comics: next screen"), paging=true})
    Dispatcher:registerAction("smart_comics_prev", {category="none", event="SmartComicsPrev", title=_("Smart Comics: previous screen"), paging=true})
    Dispatcher:registerAction("smart_comics_toggle", {category="none", event="SmartComicsToggle", title=_("Smart Comics: ON/OFF"), paging=true})
end

function SmartScroll:pageCount()
    return (self.ui.document.info and self.ui.document.info.number_of_pages) or 1
end

-- Conservative per-page blank-margin detection. One tiny render per page,
-- cached across layout rebuilds; no image processing dependencies.
function SmartScroll:getSideCrop(page, native)
    self.crop_cache = self.crop_cache or {}
    if self.crop_cache[page] then return self.crop_cache[page][1], self.crop_cache[page][2] end
    local zoom=math.min(1, 240/native.w)
    local ok,tile=pcall(function() return self.ui.document:renderPage(page,nil,zoom,0,1.0,1.0,true) end)
    local left,right=0,0
    if ok and tile and tile.bb then
        local bb=tile.bb
        local w,h=bb.w,bb.h
        -- Columns must be almost entirely white, including the middle of the page.
        -- Ignore at most 18% on either side, and leave a small safety margin.
        local function blankColumn(x)
            local white,total=0,0
            local step=math.max(1,math.floor(h/90))
            for y=0,h-1,step do
                local okp,px=pcall(function() return bb:getPixel(x,y):getColor8().a end)
                if okp and type(px)=="number" then
                    total=total+1
                    if px>=244 then white=white+1 end
                end
            end
            return total>0 and white/total>=0.985
        end
        local limit=math.floor(w*0.18)
        for x=0,limit-1 do if not blankColumn(x) then break end; left=x+1 end
        for x=w-1,w-limit,-1 do if not blankColumn(x) then break end; right=right+1 end
        -- Avoid cropping a page for negligible scan noise or uncertain margins.
        if left<math.max(3,math.floor(w*0.012)) then left=0 end
        if right<math.max(3,math.floor(w*0.012)) then right=0 end
        left=math.max(0,math.floor(left/zoom)-math.ceil(native.w*0.003))
        right=math.max(0,math.floor(right/zoom)-math.ceil(native.w*0.003))
    end
    self.crop_cache[page]={left,right}
    return left,right
end

-- Build the virtual strip in DISPLAY pixels. Every physical image is fit to
-- screen width independently, so pages with different source widths still join.
function SmartScroll:buildLayout()
    local full_sw = Screen:getWidth()
    local sw = self.sidebar_enabled and math.max(1, math.floor(full_sw * (1-self.sidebar_ratio) + 0.5)) or full_sw
    local pages, y = {}, 0
    for p=1,self:pageCount() do
        local d = self.ui.document:getNativePageDimensions(p)
        if d and d.w and d.h and d.w > 0 and d.h > 0 then
            local crop_l,crop_r=self:getSideCrop(p,d)
            local effective_w=math.max(1,d.w-crop_l-crop_r)
            local scale = sw / effective_w
            local dh = math.max(1, math.floor(d.h * scale + 0.5))
            pages[#pages+1] = {page=p, native_w=d.w, native_h=d.h, crop_l=crop_l, crop_r=crop_r, scale=scale, y0=y, y1=y+dh, display_h=dh}
            y = y + dh
        end
    end
    self.layout = {pages=pages, total_h=y, screen_w=sw, full_screen_w=full_sw}
end

function SmartScroll:getPageLayout(page)
    if not self.layout then self:buildLayout() end
    for _,p in ipairs(self.layout.pages) do if p.page == page then return p end end
end

-- Analyze only horizontal blank bands. This is NOT panel detection.
function SmartScroll:analyzePage(page)
    if self.page_cache[page] then return self.page_cache[page] end
    local doc = self.ui.document
    local native = doc:getNativePageDimensions(page)
    if not native or native.w < 1 or native.h < 1 then return nil end
    local zoom = math.min(1, self.analysis_max_width / native.w)
    local ok,tile = pcall(function() return doc:renderPage(page,nil,zoom,0,1.0,1.0,true) end)
    if not ok or not tile or not tile.bb then return nil end
    local bb,aw,ah = tile.bb,tile.bb.w,tile.bb.h
    -- Scan the central 84%: page borders and scan artifacts must not
    -- invalidate otherwise clean horizontal gutters. One low-res pass only.
    local left=math.floor(aw*0.08)
    local right=math.max(left,math.ceil(aw*0.92)-1)
    local sx=math.max(1,math.floor((right-left+1)/self.sample_width))
    local blank, white_rows, black_rows = {}, {}, {}
    for yy=0,ah-1 do
        local total, whites, blacks = 0,0,0
        for xx=left,right,sx do
            local okp,px=pcall(function() return bb:getPixel(xx,yy):getColor8().a end)
            if okp and type(px)=="number" then
                total=total+1
                if px>=self.white_threshold then whites=whites+1 end
                if px<=self.black_threshold then blacks=blacks+1 end
            end
        end
        local wr=total>0 and whites/total or 0
        local br=total>0 and blacks/total or 0
        blank[yy+1]=total>0 and (wr>=self.white_ratio or br>=self.black_ratio)
        white_rows[yy+1],black_rows[yy+1]=wr,br
    end
    local native_gap = math.max(self.min_gap_px, math.floor(native.h*self.adaptive_gap_ratio+0.5))
    local min_gap = 3 -- THIN GUTTER TEST: minimum 3 sampled blank rows
    local gaps, yy = {}, 1
    while yy <= ah do
        if blank[yy] then
            local s = yy
            while yy <= ah do
                if blank[yy] then
                    yy=yy+1
                elseif yy+1 <= ah and blank[yy+1] and yy-s >= 2 then
                    -- Bridge at most one noisy row, only inside a real blank band.
                    yy=yy+2
                else
                    break
                end
            end
            local e = yy-1
            if e-s+1 >= min_gap and (not blank[e] or e-s+1 >= 3) then
                -- source/native coordinates, end-exclusive-ish
                local n0 = math.max(0, math.floor((s-1)/zoom))
                local n1 = math.min(native.h, math.ceil(e/zoom))
                gaps[#gaps+1] = {y0=n0, y1=n1, h=n1-n0}
            end
        else yy=yy+1 end
    end
    local out = {native=native, gaps=gaps, zoom=zoom, white_rows=white_rows, black_rows=black_rows}
    self.page_cache[page] = out
    return out
end

-- Return all useful separator positions as GLOBAL DISPLAY Y coordinates.
-- We snap to the END of a blank band so the next screen starts with content,
-- not with a useless white/black separator at its top.
function SmartScroll:globalSeparatorsInRange(a,b)
    local out = {}
    if not self.layout then self:buildLayout() end
    for _,pl in ipairs(self.layout.pages) do
        if pl.y1 >= a and pl.y0 <= b then
            local an = self:analyzePage(pl.page)
            if an then
                for _,g in ipairs(an.gaps) do
                    local gs = pl.y0 + g.y0*pl.scale
                    local ge = pl.y0 + g.y1*pl.scale
                    if ge >= a and gs <= b then
                        out[#out+1] = {pos=ge, start=gs, finish=ge, gap_h=ge-gs, page=pl.page}
                    end
                end
            end
        end
    end
    return out
end

-- If a destination lands inside a white/black separator, advance only through
-- that contiguous blank area until real artwork starts. This reuses the cached
-- low-resolution row analysis; it does not render or analyze the page again.
-- It also works across physical CBZ image boundaries.
function SmartScroll:skipBlankAt(pos)
    if not self.layout then self:buildLayout() end
    local y=math.max(0,pos)
    local total=self.layout.total_h
    local started=false

    while y < total do
        local pl=nil
        for _,p in ipairs(self.layout.pages) do
            if y >= p.y0 and y < p.y1 then pl=p; break end
        end
        if not pl then break end

        local an=self:analyzePage(pl.page)
        if not an or not an.zoom or not an.white_rows then break end
        local native_y=(y-pl.y0)/pl.scale
        local row=math.floor(native_y*an.zoom)+1
        row=math.max(1,math.min(#an.white_rows,row))
        local wr=an.white_rows[row] or 0
        local br=an.black_rows[row] or 0
        local blank=(wr >= 0.94 or br >= 0.94)

        -- Never search for a separator here: only consume one when the exact
        -- destination is already inside it.
        if not blank then break end
        started=true

        local display_step=math.max(1,math.floor((1/an.zoom)*pl.scale+0.5))
        y=math.min(pl.y1,y+display_step)
        -- y == pl.y1 naturally enters the following physical image next loop.
    end

    if started and y > pos then
        y=math.max(pos,y-Screen:scaleBySize(3))
    end
    return y
end

-- Optional top trim: use ONLY a verified cached separator touching the
-- destination (or starting within 3 display px). Never seek past artwork.
-- Works for a new CBZ image and for subsequent screens alike.
function SmartScroll:trimTop(pos)
    if not self.auto_trim_top then return pos end
    if not self.layout then self:buildLayout() end
    local edge=Screen:scaleBySize(3)
    local pl
    for _,p in ipairs(self.layout.pages) do
        if pos >= p.y0 and pos < p.y1 then pl=p; break end
    end
    if not pl then return pos end
    local an=self:analyzePage(pl.page)
    if not an then return pos end
    for _,g in ipairs(an.gaps) do
        local gs=pl.y0+g.y0*pl.scale
        local ge=pl.y0+g.y1*pl.scale
        if gs <= pos+edge and ge > pos and gs >= pos-edge then
            return math.min(pl.y1, math.max(pos,ge-Screen:scaleBySize(2)))
        end
        if gs < pos and ge > pos then
            return math.min(pl.y1, math.max(pos,ge-Screen:scaleBySize(2)))
        end
    end
    return pos
end

function SmartScroll:findBestSnap(target, direction)
    local sh = Screen:getHeight()
    local radius = sh * self.search_range
    local cur = self.current_y or 0
    local minpos, maxpos
    if direction > 0 then
        minpos = math.max(cur + sh*self.min_advance_ratio, target-radius)
        maxpos = math.min(cur + sh*self.max_advance_ratio, target+radius)
    else
        -- For backwards navigation target is an estimated previous top.
        minpos = math.max(0, target-radius)
        maxpos = math.min(cur - sh*0.40, target+radius)
    end
    if maxpos <= minpos then return nil end
    local gaps = self:globalSeparatorsInRange(minpos,maxpos)
    local best,bestscore
    for _,g in ipairs(gaps) do
        local dist = math.abs(g.pos-target) / math.max(1,radius)
        local bonus = math.min(0.30, g.gap_h / math.max(1,sh) * 2.0)
        local score = dist - bonus
        if not bestscore or score < bestscore then best,bestscore=g,score end
    end
    return best
end

-- Diagnostics only: inspect cached low-resolution rows, without another render.
-- BEST WHITE is the brightest sampled row; RUN is the longest near-white band.
function SmartScroll:diagnoseGutter(pl, scan_a, scan_b)
    self.debug_scan_from=math.floor(scan_a+0.5)
    self.debug_scan_to=math.floor(scan_b+0.5)
    self.debug_best_white=nil; self.debug_best_white_pct=0
    self.debug_best_run=0; self.debug_min_run=0
    self.debug_reject="NO ROW"
    local an=self:analyzePage(pl.page)
    if not an or not an.white_rows or not an.zoom or an.zoom<=0 then
        self.debug_reject="NO ANALYSIS"
        return
    end
    local factor=an.zoom/pl.scale
    local lo=math.max(1,math.floor((scan_a-pl.y0)*factor)+1)
    local hi=math.min(#an.white_rows,math.ceil((scan_b-pl.y0)*factor)+1)
    local native_gap=math.max(self.min_gap_px,math.floor(an.native.h*self.adaptive_gap_ratio+0.5))
    local minrun=3 -- same sampled-row tolerance as detector
    self.debug_min_run=minrun
    local run=0
    local best_run=0
    local best_row=nil
    local best_ratio=-1
    local qualifying=0
    for i=lo,hi do
        local wr=an.white_rows[i] or 0
        local br=an.black_rows[i] or 0
        if wr>best_ratio then best_ratio=wr; best_row=i end
        if wr>=self.white_ratio or br>=self.black_ratio then
            run=run+1; qualifying=qualifying+1
            if run>best_run then best_run=run end
        elseif i>lo and i<hi and run>=2
            and ((an.white_rows[i+1] or 0)>=self.white_ratio or (an.black_rows[i+1] or 0)>=self.black_ratio) then
            run=run+1 -- one noisy sampled row inside a confirmed band
        else
            run=0
        end
    end
    self.debug_best_run=best_run
    if best_row then
        self.debug_best_white=math.floor(pl.y0+(best_row-1)/factor+0.5)
        self.debug_best_white_pct=math.floor(best_ratio*100+0.5)
    end
    if hi<lo then self.debug_reject="EMPTY RANGE"
    elseif best_run>=minrun then self.debug_reject="CHECK GAP POS"
    elseif qualifying>0 then self.debug_reject="BAND TOO SHORT"
    elseif best_ratio>=0 then self.debug_reject="RATIO TOO LOW"
    end
end

-- Webtoon Helper-style *single* feature: fit the current slice to height.
-- We do not restore panel segmentation. We simply look for the first strict
-- separator a little below the normal screen bottom. If it can be reached with
-- only a modest reduction, that whole slice is rendered on the current screen.
function SmartScroll:updateFitToHeight()
    self.fit_end=nil; self.fit_scale=1; self.fit_resume_y=nil
    self.fit_at_page_end=false
    self.debug_fit_total=0; self.debug_fit_screen=Screen:getHeight(); self.debug_fit_need=0; self.debug_fit_remaining=0
    self.debug_next_sep=nil; self.debug_sep_selected=nil; self.debug_candidates=0
    self.debug_scan_from=nil; self.debug_scan_to=nil; self.debug_best_white=nil; self.debug_best_white_pct=0
    self.debug_best_run=0; self.debug_min_run=0; self.debug_reject="NOT SCANNED"
    if not self.layout or not self.current_y then return end
    local sh=Screen:getHeight()
    local pl
    for _,p in ipairs(self.layout.pages) do
        if self.current_y>=p.y0 and self.current_y<p.y1 then pl=p; break end
    end
    if not pl then return end
    local top=self.current_y
    local remaining=pl.y1-top
    self.debug_fit_total=math.max(0,math.floor(pl.y1-pl.y0+0.5))
    self.debug_fit_remaining=math.max(0,math.floor(remaining+0.5))
    self.debug_fit_need=math.max(0,math.floor((1-sh/math.max(1,remaining))*100+0.5))
    local tolerance=math.max(0,math.min(0.4,self.page_end_max_reduction/100))
    if remaining<=sh then
        self.fit_end=pl.y1
        self.fit_resume_y=pl.y1
        self.fit_at_page_end=true
        return
    end
    if not self.fit_to_height then return end
    -- Physical CBZ page end has priority over any internal gutter.
    -- Never enlarge; shrink only within the configured tolerance.
    if remaining <= sh/(1-tolerance) then
        self.fit_end=pl.y1
        self.fit_resume_y=pl.y1
        self.fit_scale=math.min(1,sh/remaining)
        self.fit_at_page_end=true
        self.debug_reason="PAGE END FIRST"
        return
    end
    -- TEST: allow earlier gutters (from 30% of viewport) to avoid splitting
    -- a row of panels when the only valid gutter is above 67%.
    -- One local decision: end at a horizontal gutter, or use the
    -- available 33% fit to avoid a tiny leftover screen.
    -- Search range extends *past* the current screen bottom. Max Page-End
    -- reduction remains an independent hard cap on the zoom we may apply.
    local fit_limit=top+sh/(1-tolerance)
    -- Search beyond the viewport, always covering the full reachable fit
    -- interval. Search range can extend diagnostics further, but never zoom
    -- beyond Max Page-End reduction.
    local search_limit=math.min(pl.y1,math.max(top+sh*(1+self.search_range),fit_limit))
    local scan_start=top+sh*0.30
    self:diagnoseGutter(pl,scan_start,search_limit)
    local gaps=self:globalSeparatorsInRange(scan_start,search_limit)
    self.debug_candidates=#gaps
    if #gaps>0 then self.debug_reject="CANDIDATES FOUND" end
    self.debug_next_sep=nil
    local best
    for _,g in ipairs(gaps) do
        if g.start>top+sh*0.30 and g.finish<=pl.y1 then
            -- NEXT SEP reports the furthest candidate in the search window,
            -- including one too far away for the configured zoom limit.
            if not self.debug_next_sep or g.start>self.debug_next_sep then
                self.debug_next_sep=g.start
            end
            if g.start<=fit_limit+0.001 then
                -- Prefer the furthest *reachable* safe boundary.
                if not best or g.start>best.start then best=g end
            end
        end
    end
    if best then
        self.fit_end=best.start
        self.debug_sep_selected=best.start
        self.fit_resume_y=best.finish
        self.fit_scale=math.min(1,sh/(best.start-top))
        self.debug_reason="GAP"
        self.debug_reject="USED"
    else
        -- Without a verified gutter, do not invent a cut. Consume a
        -- normal screen; if the tail is short, fit it on the next view.
        self.debug_reason="NORMAL"
        if #gaps>0 then self.debug_reject="OUTSIDE FIT" end
    end
end

function SmartScroll:syncUnderlyingPage()
    if not self.layout then return end
    local y = self.current_y or 0
    local page = 1
    for _,pl in ipairs(self.layout.pages) do
        if y >= pl.y0 and y < pl.y1 then page=pl.page; break end
        if y >= pl.y1 then page=pl.page end
    end
    if self.ui.paging and self.ui.paging.current_page ~= page then
        self.navigating=true
        self.ui.paging:onGotoPage(page)
        self.navigating=false
    end
end

function SmartScroll:setY(y)
    if not self.layout then self:buildLayout() end
    local maxy = math.max(0,self.layout.total_h-1)
    self.current_y = math.max(0,math.min(maxy,math.floor(y+0.5)))
    self:syncUnderlyingPage()
    self:updateFitToHeight()
    UIManager:setDirty(self.ui.view.dialog,"full")
    self:schedulePreload()
end

function SmartScroll:nextScreen()
    if not self.layout then self:buildLayout() end
    if not self.current_y then self.current_y=0 end
    local sh=Screen:getHeight()
    local pl,idx
    for i,p in ipairs(self.layout.pages) do
        if self.current_y>=p.y0 and self.current_y<p.y1 then pl=p; idx=i; break end
    end
    if not pl then return false end
    local end_y=self.fit_end or math.min(pl.y1,self.current_y+sh)
    if end_y>=pl.y1-1 then
        local nextpl=self.layout.pages[idx+1]
        if not nextpl then
            self.ui:handleEvent(Event:new("EndOfBook"))
        else
            self:setY(self:trimTop(nextpl.y0))
        end
        return true
    end
    -- CONTINUITY EXACT TEST: only jump across a separator when FIT SCAN
    -- explicitly selected that separator. Otherwise preserve the precise
    -- end of the visible slice; do not trim or scan the destination.
    local destination
    if self.fit_resume_y and self.fit_end and self.fit_resume_y > self.fit_end then
        destination = self.fit_resume_y -- verified gutter selected by FIT SCAN
    else
        destination = end_y -- ordinary screen cut: zero skipped content
    end
    destination = math.max(self.current_y + 1, math.min(pl.y1, destination))
    if destination>=pl.y1 then
        local nextpl=self.layout.pages[idx+1]
        if nextpl then self:setY(self:trimTop(nextpl.y0))
        else self.ui:handleEvent(Event:new("EndOfBook")) end
    else
        self:setY(destination)
    end
    return true
end

function SmartScroll:openPreviousAtEnd()
    if not self.ui or not self.ui.document then return false end
    local FileChooser = require("ui/widget/filechooser")
    local fc = FileChooser:new{ ui = self.ui }
    local file = fc:getNextOrPreviousFileInFolder(self.ui.document.file, true)
    if not file then
        UIManager:show(InfoMessage:new{ text=_("This is the first file in the folder. No previous file to open.") })
        return true
    end

    -- Remember the exact destination. The new Reader instance consumes this
    -- one-shot marker and positions Smart Comics Scroll at its real EOF.
    G_reader_settings:saveSetting("smart_comics_open_at_end", file)
    G_reader_settings:flush()
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    UIManager:nextTick(function()
        filemanagerutil.openFile(self.ui, file)
    end)
    return true
end

function SmartScroll:prevScreen()
    if not self.current_y or self.current_y <= 0 then
        self:setY(0)
        return self:openPreviousAtEnd()
    end
    local sh=Screen:getHeight()
    local target=self.current_y-sh
    local snap=self:findBestSnap(target,-1)
    local ny=snap and snap.pos or (self.current_y-sh*(1-self.overlap_ratio))
    self:setY(ny); return true
end

function SmartScroll:onSmartComicsNext()
    if not self.is_enabled then return false end
    return self:nextScreen()
end
function SmartScroll:onSmartComicsPrev()
    if not self.is_enabled then return false end
    return self:prevScreen()
end
function SmartScroll:onSmartComicsToggle()
    self.is_enabled = not self.is_enabled
    self:saveSettings()
    if self.is_enabled then
        if self.ui and self.ui.paging and self.ui.document and not self.ui.document.is_reflowable then
            self:hookPageTurns()
            self:resetAtPage(self.ui.paging.current_page or 1)
        end
    else
        self:unhookPageTurns()
        self.preload_pending = false
        self.fit_end = nil
        self.fit_resume_y = nil
        self.fit_scale = 1
        self.page_cache = {}
        self.render_cache = {}
        self.render_cache_order = {}
        if self.ui and self.ui.view then
            UIManager:setDirty(self.ui.view.dialog, "full")
        end
    end
    UIManager:show(InfoMessage:new{
        text = self.is_enabled and _("Smart Comics Scroll: ON") or _("Smart Comics Scroll: OFF"),
        timeout = 1,
    })
    return true
end

function SmartScroll:renderCacheKey(page, scale)
    return tostring(page) .. "@" .. string.format("%.5f", scale)
end

function SmartScroll:getRenderedPage(page, scale)
    local key=self:renderCacheKey(page,scale)
    local cached=self.render_cache[key]
    if cached and cached.bb then return cached end
    local ok,tile=pcall(function()
        return self.ui.document:renderPage(page,nil,scale,0,1.0,1.0,true)
    end)
    if not ok or not tile or not tile.bb then return nil end
    self.render_cache[key]=tile
    self.render_cache_order[#self.render_cache_order+1]=key
    local max_cache=math.max(2,self.preload_pages+1)
    while #self.render_cache_order > max_cache do
        local old=table.remove(self.render_cache_order,1)
        if old ~= key then self.render_cache[old]=nil end
    end
    return tile
end

function SmartScroll:fitSideColor(srcbb, sy, hh)
    if not srcbb or srcbb.w < 2 or srcbb.h < 1 then return Blitbuffer.COLOR_WHITE end
    local y0=math.max(0,sy)
    local y1=math.min(srcbb.h-1,sy+hh-1)
    if y1 < y0 then return Blitbuffer.COLOR_WHITE end
    local step=math.max(1,math.floor((y1-y0+1)/24))
    local inset=math.min(2,math.max(0,math.floor(srcbb.w/100)))
    local xs={inset, math.max(0,srcbb.w-1-inset)}
    local sum,n=0,0
    for yy=y0,y1,step do
        for _,xx in ipairs(xs) do
            local ok,px=pcall(function() return srcbb:getPixel(xx,yy):getColor8().a end)
            if ok and px then sum=sum+px; n=n+1 end
        end
    end
    if n>0 and (sum/n) < 128 then return Blitbuffer.COLOR_BLACK end
    return Blitbuffer.COLOR_WHITE
end

function SmartScroll:schedulePreload()
    if self.preload_pages <= 0 or self.preload_pending or not self.layout or not self.current_y then return end
    self.preload_pending=true
    UIManager:scheduleIn(0.08,function()
        self.preload_pending=false
        if not self.is_enabled or not self.layout or not self.current_y then return end
        local sh=Screen:getHeight()
        local probe=(self.fit_resume_y or self.fit_end or (self.current_y+sh)) + Screen:scaleBySize(2)
        local first=nil
        for i,pl in ipairs(self.layout.pages) do
            if pl.y1 > probe then first=i; break end
        end
        if not first then return end
        local last=math.min(#self.layout.pages,first+self.preload_pages-1)
        for i=first,last do
            local pl=self.layout.pages[i]
            self:getRenderedPage(pl.page,pl.scale)
        end
    end)
end

function SmartScroll:viewportBackgroundColor(top, bottom, f)
    -- Pick one adaptive background for the WHOLE visible viewport.
    -- Sample the left/right edges of every visible rendered slice and weight
    -- naturally by the number of sampled rows. This reuses the render cache.
    local sum,n=0,0
    for _,pl in ipairs(self.layout.pages) do
        if pl.y1 > top and pl.y0 < bottom then
            local vis0=math.max(top,pl.y0)
            local vis1=math.min(bottom,pl.y1)
            local tile=self:getRenderedPage(pl.page,pl.scale*f)
            if tile and tile.bb and tile.bb.w >= 2 and tile.bb.h >= 1 then
                local sy=math.max(0,math.floor((vis0-pl.y0)*f+0.5))
                local hh=math.max(1,math.floor((vis1-vis0)*f+0.5))
                local y0=math.max(0,sy)
                local y1=math.min(tile.bb.h-1,sy+hh-1)
                if y1 >= y0 then
                    local step=math.max(1,math.floor((y1-y0+1)/24))
                    local inset=math.min(2,math.max(0,math.floor(tile.bb.w/100)))
                    local xs={inset,math.max(0,tile.bb.w-1-inset)}
                    for yy=y0,y1,step do
                        for _,xx in ipairs(xs) do
                            local ok,px=pcall(function() return tile.bb:getPixel(xx,yy):getColor8().a end)
                            if ok and px then sum=sum+px; n=n+1 end
                        end
                    end
                end
            end
        end
    end
    if n>0 and (sum/n) < 128 then return Blitbuffer.COLOR_BLACK end
    return Blitbuffer.COLOR_WHITE
end

function SmartScroll:paintViewport(bb)
    if not self.layout then self:buildLayout() end
    local full_sw,sh=Screen:getWidth(),Screen:getHeight()
    local sw=(self.layout and self.layout.screen_w) or full_sw
    -- Sidebar ratio is TOTAL reserved width, split equally left/right.
    local content_x=math.floor((full_sw-sw)/2)

    local f=(self.fit_end and self.fit_scale) or 1.0
    local top=self.current_y
    local bottom=self.fit_end or (self.current_y+sh)
    -- Clip the viewport to the current physical manga page.
    for _,pl in ipairs(self.layout.pages) do
        if top>=pl.y0 and top<pl.y1 then
            bottom=math.min(bottom,pl.y1)
            break
        end
    end
    local viewport_color=self:viewportBackgroundColor(top,bottom,f)
    -- Paint first, then draw the webtoon over it: sidebar, Fit margins and any
    -- uncovered top/bottom area all inherit the same adaptive color.
    bb:paintRect(0,0,full_sw,sh,viewport_color)
    local dy=0

    for _,pl in ipairs(self.layout.pages) do
        if pl.y1 > top and pl.y0 < bottom then
            local vis0=math.max(top,pl.y0)
            local vis1=math.min(bottom,pl.y1)
            -- Render the physical CBZ image at its normal fit-to-width scale,
            -- multiplied by the tiny fit-to-height factor.
            local render_scale=pl.scale*f
            local tile=self:getRenderedPage(pl.page,render_scale)
            if tile and tile.bb then
                -- vis0/vis1 are in normal strip display coordinates; convert
                -- their page-relative positions to the reduced render.
                local sy=math.max(0,math.floor((vis0-pl.y0)*f+0.5))
                local hh=math.max(1,math.floor((vis1-vis0)*f+0.5))
                hh=math.min(hh,tile.bb.h-sy,sh-dy)
                local cropped_w=math.max(1,math.floor((pl.native_w-pl.crop_l-pl.crop_r)*render_scale+0.5))
                local ww=math.min(sw,cropped_w)
                if hh>0 and ww>0 then
                    local inner_dx=math.floor((sw-ww)/2)
                    local dx=content_x+inner_dx
                    local sx=math.max(0,math.floor(pl.crop_l*render_scale+0.5)+math.max(0,math.floor((cropped_w-ww)/2)))
                    ww=math.min(ww,tile.bb.w-sx)
                    -- The full viewport has already been painted with the
                    -- adaptive edge color, so Fit/sidebar margins need no
                    -- separate fills here.
                    bb:blitFrom(tile.bb,dx,dy,sx,sy,ww,hh)
                    dy=dy+hh
                end
            end
        end
        if dy>=sh then break end
    end
    if self.visual_debug then
        self:paintDebug(bb, full_sw, sh, f)
        -- No fixed calibration stripe: all markers now track image coordinates.

    end
end

-- Compact bitmap HUD, independent of KOReader font/rendering APIs.
local hud_font = {
 A={"010","101","111","101","101"}, C={"011","100","100","100","011"},
 D={"110","101","101","101","110"}, E={"111","100","110","100","111"},
 H={"101","101","111","101","101"}, I={"111","010","010","010","111"},
 K={"101","101","110","101","101"}, M={"101","111","111","101","101"},
 N={"101","111","111","111","101"}, O={"111","101","101","101","111"},
 P={"110","101","110","100","100"}, S={"011","100","010","001","110"},
 T={"111","010","010","010","010"}, U={"101","101","101","101","111"},
 V={"101","101","101","101","010"}, Z={"111","001","010","100","111"},
 ['0']={"111","101","101","101","111"}, ['1']={"010","110","010","010","111"},
 ['2']={"110","001","010","100","111"}, ['3']={"110","001","010","001","110"},
 ['4']={"101","101","111","001","001"}, ['5']={"111","100","110","001","110"},
 ['6']={"011","100","110","101","111"}, ['7']={"111","001","010","010","010"},
 ['8']={"111","101","111","101","111"}, ['9']={"111","101","111","001","110"},
 ['.']={"000","000","000","000","010"}, [':']={"000","010","000","010","000"},
 [' ']={"000","000","000","000","000"}, ['-']={"000","000","111","000","000"},
}
function SmartScroll:paintDebugHud(bb, sw, sh, fit)
    local unit=math.max(2,math.floor(Screen:scaleBySize(2)))
    local lineh=7*unit
    local lines={
      "ACTIVE " .. (self.is_enabled and "1" or "0") .. " HOOK " .. tostring(self.debug_hook_calls or 0),
      "TAPS " .. tostring(self.debug_taps or 0) .. " SNAP " .. tostring(self.debug_snaps or 0),
      "ZOOM " .. string.format("%.2f",fit) .. " " .. (self.debug_reason or "NONE"),
      "PAGE " .. tostring(self.debug_fit_total or 0) .. " SCREEN " .. tostring(self.debug_fit_screen or 0),
      "LEFT " .. tostring(self.debug_fit_remaining or 0) .. " RED " .. tostring(self.debug_fit_need or 0),
      "NEXT SEP " .. (self.debug_next_sep and tostring(math.floor(self.debug_next_sep+0.5)) or "NONE"),
      "USE SEP " .. (self.debug_sep_selected and tostring(math.floor(self.debug_sep_selected+0.5)) or "NONE"),
      "SCAN " .. tostring(self.debug_scan_from or "-") .. " TO " .. tostring(self.debug_scan_to or "-"),
      "BEST WHITE " .. (self.debug_best_white and tostring(self.debug_best_white) or "NONE") .. " " .. tostring(self.debug_best_white_pct or 0) .. "%",
      "RUN " .. tostring(self.debug_best_run or 0) .. " MIN " .. tostring(self.debug_min_run or 0),
      "REJECT " .. tostring(self.debug_reject or "-"),
      "GAPS " .. tostring(self.debug_candidates or 0) .. " BND " .. tostring(self.debug_boundary or 0),
      "VIS " .. tostring(self.debug_visible_gaps or 0) .. " BELOW " .. tostring(self.debug_beyond_gaps or 0),
    }
    local maxchars=0
    for _,line in ipairs(lines) do maxchars=math.max(maxchars,#line) end
    local w=math.min(sw-8,(maxchars*4+2)*unit)
    local h=#lines*lineh+2*unit
    bb:paintRect(2,2,w,h,Blitbuffer.COLOR_WHITE)
    for li,line in ipairs(lines) do
        for i=1,#line do
            local ch=line:sub(i,i):upper()
            local glyph=hud_font[ch] or hud_font[' ']
            for gy=1,5 do
                for gx=1,3 do
                    if glyph[gy]:sub(gx,gx)=="1" then
                        local x=4+(i-1)*4*unit+(gx-1)*unit
                        local y=4+(li-1)*lineh+(gy-1)*unit
                        if x+unit<=sw and y+unit<=sh then
                            bb:paintRect(x,y,unit,unit,Blitbuffer.COLOR_BLACK)
                        end
                    end
                end
            end
        end
    end
end

-- Debug drawn over the actual manga. E-ink cannot show RGB colours reliably:
-- dashed gray = detected separator, solid black = selected separator,
-- alternating black/white = ordinary viewport boundary.
-- Separators beyond the visible screen are marked by a right-edge arrow;
-- their count is shown in the HUD (they cannot be drawn at their true Y yet).
function SmartScroll:paintDebug(bb, sw, sh, fit)
    local top=self.current_y or 0
    local pl
    if self.layout then
        for _,p in ipairs(self.layout.pages) do
            if top>=p.y0 and top<p.y1 then pl=p; break end
        end
    end
    local tolerance=math.max(0,math.min(.4,(self.page_end_max_reduction or 33)/100))
    local limit=pl and math.min(pl.y1,math.max(top+sh*(1+self.search_range),top+sh/(1-tolerance))) or top+sh/fit
    local gaps=self:globalSeparatorsInRange(top,limit)
    local candidates=0
    local visible=0
    local beyond=0
    local function dash(y,kind)
        y=math.floor(y+0.5)
        if y<0 or y>sh-3 then return end
        if kind=="chosen" then
            bb:paintRect(0,y,sw,3,Blitbuffer.COLOR_BLACK)
            bb:paintRect(sw-24,math.max(0,y-5),24,9,Blitbuffer.COLOR_BLACK)
        else
            local step=kind=="normal" and 16 or 22
            local ink=kind=="normal" and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY
            for x=0,sw-1,step do
                bb:paintRect(x,y,math.min(math.floor(step/2),sw-x),3,Blitbuffer.COLOR_WHITE)
                bb:paintRect(x,y+1,math.min(math.floor(step/2),sw-x),1,ink)
            end
            if kind=="gap" then
                bb:paintRect(sw-13,math.max(0,y-3),13,7,Blitbuffer.COLOR_BLACK)
            end
        end
    end
    for _,g in ipairs(gaps) do
        if pl and g.start>=pl.y0 and g.finish<=pl.y1
            and g.start>=top+sh*.8 and g.start<=limit then
            candidates=candidates+1
        end
        local y=(g.start-top)*fit
        if y>=0 and y<sh then
            visible=visible+1
            dash(y,"gap")
        elseif y>=sh then
            beyond=beyond+1
        end
    end
    -- Mark the actual viewport start, useful for confirming navigation moves.
    -- Alternating edge marker avoids obscuring the artwork.
    bb:paintRect(sw-6,0,6,9,Blitbuffer.COLOR_BLACK)
    -- Separators beyond the visible area cannot be drawn on the artwork;
    -- project them onto a short ruler at the right edge (bottom 33%).
    local extra=math.max(1,limit-(top+sh/fit))
    for _,g in ipairs(gaps) do
        local actual=(g.start-top)*fit
        if actual>=sh and g.start<=limit then
            local t=math.max(0,math.min(1,(g.start-(top+sh/fit))/extra))
            local ry=math.max(0,math.min(sh-4,math.floor(sh*.67+t*sh*.30)))
            bb:paintRect(sw-22,ry,20,3,Blitbuffer.COLOR_BLACK)
            bb:paintRect(sw-22,ry+3,10,2,Blitbuffer.COLOR_WHITE)
        end
    end
    -- Indicate separators found within tolerance but below the screen.
    if beyond>0 then
        local yy=sh-18
        bb:paintRect(sw-28,yy,26,15,Blitbuffer.COLOR_WHITE)
        bb:paintRect(sw-16,yy+1,3,8,Blitbuffer.COLOR_BLACK)
        bb:paintRect(sw-21,yy+7,13,3,Blitbuffer.COLOR_BLACK)
        bb:paintRect(sw-19,yy+10,9,3,Blitbuffer.COLOR_BLACK)
    end
    -- PAGE END: real bottom edge of this physical CBZ image (not a gutter).
    -- White backing plus black double dash remains legible on manga artwork.
    if pl then
        local py=math.floor((pl.y1-top)*fit+0.5)
        if py>=0 and py<sh then
            bb:paintRect(0,math.max(0,py-3),sw,5,Blitbuffer.COLOR_WHITE)
            for x=0,sw-1,24 do
                bb:paintRect(x,math.max(0,py-2),math.min(16,sw-x),3,Blitbuffer.COLOR_BLACK)
            end
            -- Distinct square marker on the right denotes PAGE END.
            bb:paintRect(sw-16,math.max(0,py-10),14,10,Blitbuffer.COLOR_BLACK)
            bb:paintRect(sw-13,math.max(0,py-8),8,5,Blitbuffer.COLOR_WHITE)
        end
    end
    -- The actual viewport cutoff is always the bottom of the screen.
    -- Previously sh*fit hid the marker when Fit-to-Height was active.
    -- Draw it even when no separator was detected (fallback cut).
    local cutoff=(self.fit_end and self.fit_end>top)
        and (self.fit_end-top)*fit or sh-3
    dash(math.min(sh-3,cutoff),"chosen")
    -- The next physical image boundary is separately marked above.

    self.debug_candidates=candidates
    self.debug_boundary=self.fit_end and math.floor(self.fit_end-top+.5) or 0
    self.debug_visible_gaps=visible
    self.debug_beyond_gaps=beyond
    self:paintDebugHud(bb,sw,sh,fit)
end

function SmartScroll:resetAtPage(page)
    self:buildLayout()
    self.last_snap=nil
    self.debug_candidates=0; self.debug_boundary=0; self.debug_visible_gaps=0; self.debug_beyond_gaps=0; self.debug_reason="RESET"
    self.page_cache={}
    self.render_cache={}
    self.render_cache_order={}
    local pl=self:getPageLayout(page)
    self.current_y=pl and pl.y0 or 0
    -- If the physical image itself starts inside a separator, start at content.
    self.current_y=self:skipBlankAt(self:trimTop(self.current_y))
    self:updateFitToHeight()
    UIManager:setDirty(self.ui.view.dialog,"full")
    self:schedulePreload()
end

function SmartScroll:hookPageTurns()
    if self._orig_goto_rel or not self.ui.paging then return end
    local plugin=self
    self._orig_goto_rel=self.ui.paging.onGotoViewRel
    self.ui.paging.onGotoViewRel=function(paging,diff,...)
        plugin.debug_hook_calls=(plugin.debug_hook_calls or 0)+1
        if plugin.is_enabled and (diff==1 or diff==-1) then
            plugin.debug_taps=(plugin.debug_taps or 0)+1
        end
        if plugin.is_enabled and Screen:getWidth() > Screen:getHeight() and not plugin.navigating and (diff==1 or diff==-1) then
            local handled
            if diff==1 then handled=plugin:nextScreen() else handled=plugin:prevScreen() end
            if handled then
                plugin.debug_snaps=(plugin.debug_snaps or 0)+1
                return true
            end
        end
        return plugin._orig_goto_rel(paging,diff,...)
    end
end
function SmartScroll:unhookPageTurns()
    if self._orig_goto_rel and self.ui and self.ui.paging then self.ui.paging.onGotoViewRel=self._orig_goto_rel end
    self._orig_goto_rel=nil
end

function SmartScroll:onReaderReady()
    self.ui.menu:registerToMainMenu(self)
    if not self.ui.paging or not self.ui.document or self.ui.document.is_reflowable then return end
    self:buildLayout()
    self.overlay=StripOverlay:new{plugin=self}
    self.ui.view:registerViewModule("smart_comics_scroll",self.overlay)    if self.is_enabled then
        self:hookPageTurns()
        local open_at_end = G_reader_settings:readSetting("smart_comics_open_at_end")
        if open_at_end and open_at_end == self.ui.document.file then
            -- One-shot: clear before positioning, so a crash/reopen cannot
            -- unexpectedly force this document back to its end.
            G_reader_settings:delSetting("smart_comics_open_at_end")
            G_reader_settings:flush()
            self.page_cache={}
            self.render_cache={}
            self.render_cache_order={}
            local maxy=math.max(0,self.layout.total_h-Screen:getHeight())
            self:setY(maxy)
        else
            self:resetAtPage(self.ui.paging.current_page or 1)
        end
    end
end

function SmartScroll:onPageUpdate(page)
    if self.navigating or not self.is_enabled then return end
    local pl=self:getPageLayout(page)
    if pl and (not self.current_y or self.current_y<pl.y0-Screen:getHeight() or self.current_y>pl.y1) then
        self:resetAtPage(page)
    end
end

function SmartScroll:showSettingsDialog(menu)
    -- A compact 2-column grid of native KOReader buttons. Each button opens
    -- one standard input dialog; no manual widget reparenting or scrolling.
    local dlg
    local specs = {
        { _("Search range (%)"), function() return math.floor(self.search_range * 100 + .5) end,
          function(v) self.search_range = math.max(.05, math.min(1.00, v / 100)) end },
        { _("Fallback overlap (%)"), function() return math.floor(self.overlap_ratio * 1000 + .5) / 10 end,
          function(v) self.overlap_ratio = math.max(0, math.min(.15, v / 100)) end },
        { _("Min separator (px)"), function() return self.min_gap_px end,
          function(v) self.min_gap_px = math.max(2, math.floor(v)) end },
        { _("White threshold"), function() return self.white_threshold end,
          function(v) self.white_threshold = math.max(0, math.min(255, math.floor(v))) end },
        { _("Max Page-End reduction (%)"), function() return self.page_end_max_reduction end,
          function(v) self.page_end_max_reduction = math.max(0, math.min(40, v)) end },
        { _("Preload pages"), function() return self.preload_pages end,
          function(v) self.preload_pages = math.max(0, math.min(10, math.floor(v))) end },
    }
    local function edit(i)
        local spec = specs[i]
        local editor
        editor = InputDialog:new{
            title = spec[1],
            input = tostring(spec[2]()),
            input_type = "number",
            buttons = {{
                { text = _("Cancel"), callback = function() UIManager:close(editor) end },
                { text = _("Save"), callback = function()
                    local value = tonumber(editor:getInputText())
                    if not value then
                        UIManager:show(InfoMessage:new{text=_("Enter a valid number")})
                        return
                    end
                    spec[3](value)
                    self.page_cache = {}; self.render_cache = {}
                    self:saveSettings(); self:buildLayout()
                    self:resetAtPage(self.ui.paging.current_page or 1)
                    UIManager:close(editor)
                    UIManager:close(dlg)
                    self:showSettingsDialog(menu)
                    if menu then menu:updateItems() end
                end },
            }},
        }
        UIManager:show(editor)
        editor:onShowKeyboard()
    end
    local rows = {}
    for i = 1, 6, 2 do
        local left, right = i, i + 1
        rows[#rows + 1] = {
            { text = specs[left][1] .. "\n" .. tostring(specs[left][2]()), callback = function() edit(left) end },
            { text = specs[right][1] .. "\n" .. tostring(specs[right][2]()), callback = function() edit(right) end },
        }
    end
    rows[#rows + 1] = {
        { text = (self.auto_trim_top and "☑ " or "☐ ") .. _("Auto Trim Top"),
          callback = function()
              self.auto_trim_top = not self.auto_trim_top
              self:saveSettings()
              UIManager:close(dlg)
              self:showSettingsDialog(menu)
              if menu then menu:updateItems() end
          end },
    }
    rows[#rows + 1] = {
        { text = _("Close"), callback = function() UIManager:close(dlg) end },
    }
    dlg = ButtonDialog:new{ title = _("Smart Comics Scroll"), buttons = rows }
    UIManager:show(dlg)
end

function SmartScroll:addToMainMenu(menu_items)
    menu_items.SmartComicsScroll={text=_("Smart Comics Scroll"),sorting_hint="typeset",sub_item_table={
        {text=_("Smart Comics Scroll: ON/OFF"),checked_func=function() return self.is_enabled end,callback=function() self:onSmartComicsToggle() end},
        {text=_("Fit slightly oversized content to height"),checked_func=function() return self.fit_to_height end,callback=function() self.fit_to_height=not self.fit_to_height; self:saveSettings(); self:updateFitToHeight(); UIManager:setDirty(self.ui.view.dialog,"full") end},
        {text=_("Visual debug (experimental)"),checked_func=function() return self.visual_debug end,callback=function() self.visual_debug=not self.visual_debug; self:saveSettings(); UIManager:setDirty(self.ui.view.dialog,"full") end},
        {text=_("Next smart screen"),callback=function() if self.is_enabled then self:nextScreen() end end},
        {text=_("Previous smart screen"),callback=function() if self.is_enabled then self:prevScreen() end end},
        {text=_("Scroll settings"),callback=function(m) self:showSettingsDialog(m) end},
        {text=_("Reset at current CBZ image"),callback=function() if self.is_enabled then self:resetAtPage(self.ui.paging.current_page or 1) end end},
        {text=_("About"),keep_menu_open=true,callback=function() UIManager:show(InfoMessage:new{text=_("Smart Comics Scroll is designed for landscape reading. It fits comic pages to screen width and tries to align each scroll with a horizontal gutter between rows of panels. It does not recognize individual panels or force screen rotation. Page turns use a flexible range to land just after nearby white or black separator bands. It does not try to recognize panels. If content or a physical image is only slightly taller than the screen, Fit-to-Height can shrink it up to the user-defined maximum reduction so it is shown completely; every forward destination that already lands inside a white/black separator skips only that contiguous blank area and starts at the first real content. If no safe separator exists, it splits the long panel with a small overlap.")}) end},
    }}
end

function SmartScroll:onCloseDocument()
    self:unhookPageTurns(); self.current_y=nil; self.page_cache={}; self.render_cache={}; self.layout=nil
    if self.ui and self.ui.view and self.ui.view.view_modules then self.ui.view.view_modules.smart_comics_scroll=nil end
end

return SmartScroll