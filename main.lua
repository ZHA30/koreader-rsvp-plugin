--[[--
FastReader plugin for KOReader

@module koplugin.FastReader
--]]--

-- This is a debug plugin, remove the following if block to enable it
-- if true then
--     return { disabled = true, }
-- end

local Dispatcher = require("dispatcher")  -- luacheck:ignore
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local TextWidget = require("ui/widget/textwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local OverlapGroup = require("ui/widget/overlapgroup")
local LineWidget = require("ui/widget/linewidget")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local RenderText = require("ui/rendertext")
local Blitbuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local logger = require("logger")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local FastReader = WidgetContainer:extend{
    name = "fastreader",
    is_doc_only = true,
}

function FastReader:onDispatcherRegisterActions()
    Dispatcher:registerAction("fastreader_action", {category="none", event="FastReader", title=_("快速阅读"), general=true,})
    Dispatcher:registerAction("fastreader_rsvp", {category="none", event="FastReaderRSVP", title=_("RSVP 速读"), general=true,})
end

function FastReader:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    
    -- Load settings
    self.settings_file = DataStorage:getSettingsDir() .. "/fastreader.lua"
    self.settings = LuaSettings:open(self.settings_file)
    
    -- RSVP state
    self.rsvp_enabled = false
    self.rsvp_timer = nil
    self.pending_resume_task = nil
    
    -- Tap-to-launch RSVP settings
    self.tap_to_launch_enabled = self.settings:readSetting("tap_to_launch_enabled") or false
    self.rsvp_speed = self.settings:readSetting("rsvp_speed") or 250  -- words per minute
    self.current_word_index = 1
    self.words = {}
    self.original_view_mode = nil
    
    local ovp_setting = self.settings:readSetting("ovp_alignment_enabled")
    if ovp_setting == nil then
        self.ovp_alignment_enabled = true
    else
        self.ovp_alignment_enabled = ovp_setting
    end

    -- Position tracking for resume functionality
    self.last_page_hash = nil -- Hash to identify current page content
    self.last_word_index = 1  -- Last read word index on this page
    self.show_position_indicator = self.settings:readSetting("show_position_indicator") or true
    
    -- Multi-word display settings
    self.words_preview_count = self.settings:readSetting("words_preview_count") or 3 -- Show current + 2 next words
    
    -- Display size settings (percentage of screen)
    self.display_width_percent = self.settings:readSetting("display_width_percent") or 90 -- 90% of screen width
    self.display_height_percent = self.settings:readSetting("display_height_percent") or 25 -- 25% of screen height
    
    -- Register for document events to setup callbacks when document is ready
    self.ui:registerPostReaderReadyCallback(function()
        self:setupTapHandler()
    end)
end

function FastReader:saveSettings()
    if self.settings then
        self.settings:saveSetting("rsvp_speed", self.rsvp_speed)
        self.settings:saveSetting("tap_to_launch_enabled", self.tap_to_launch_enabled)
        self.settings:saveSetting("show_position_indicator", self.show_position_indicator)
        self.settings:saveSetting("words_preview_count", self.words_preview_count)
        self.settings:saveSetting("ovp_alignment_enabled", self.ovp_alignment_enabled)
        self.settings:saveSetting("display_width_percent", self.display_width_percent)
        self.settings:saveSetting("display_height_percent", self.display_height_percent)
        self.settings:flush()
    end
end

function FastReader:enableContinuousView()
    -- Save original view mode
    if self.ui.rolling then
        -- Already in continuous mode for reflowable documents
        logger.info("FastReader: Document already in rolling mode")
        return true
    elseif self.ui.paging then
        -- For paged documents, save original mode
        self.original_view_mode = "paging"
        logger.info("FastReader: Document in paging mode, will use page-by-page navigation")
        
        -- Try to enable scroll mode if document supports it
        if self.ui.document.provider == "crengine" then
            -- This is a reflowable document in paging mode, could switch to scroll
            logger.info("FastReader: Could potentially switch to scroll mode for crengine document")
        elseif self.ui.document.provider == "mupdf" then
            -- PDF document - can't really switch to continuous, but we'll handle page navigation
            logger.info("FastReader: PDF document - will use page-by-page navigation")
        end
        
        return true
    end
    logger.warn("FastReader: Unknown document type")
    return false
end

function FastReader:restoreOriginalView()
    if self.original_view_mode and self.original_view_mode == "paging" then
        -- Restore paging mode if it was originally used
        -- Implementation would depend on KOReader's internal APIs
        self.original_view_mode = nil
    end
end

local function containsChineseText(text)
    -- Simple check: if text contains Chinese punctuation, it's likely Chinese
    return text:find("。") ~= nil or text:find("！") ~= nil or
           text:find("？") ~= nil or text:find("；") ~= nil or
           text:find("，") ~= nil or text:find("：") ~= nil
end

local function splitChineseSentences(text)
    -- Advanced Chinese text splitting with semantic punctuation handling
    -- 其后拆分 (split after): 。！？；……， 
    -- 其前拆分 (split before): "'《〈【（ 
    -- 双重标号拆分 (split after paired + sentence-ending): "。"！"？）。）！）？》。》！》？……。——！ 
    
    -- UTF-8 encoded punctuation marks
    local after_split = {
        ["。"] = true,  -- 。Chinese period
        ["！"] = true,  -- ！Exclamation
        ["？"] = true,  -- ？Question
        ["；"] = true,  -- ；Semicolon
        ["…"] = true,   -- …Ellipsis
        ["，"] = true,   -- ，Chinese comma
        ["、"] = true,   -- 、Colon
        ["\n"] = true,  -- Newline
    }
    
    local before_split = {
        ["\226\128\156"] = true,  -- 'U+2018 Left single quote
        ["《"] = true,  -- 《Left angle bracket
        ["〈"] = true,  -- 〈Small left angle
        ["【"] = true,  -- 【Left corner bracket
        ["（"] = true,  -- （Left paren
        [" "] = true,  --  Space
    }
    
    -- Right/closing marks - split AFTER these (when standalone or paired with sentence-ending)
    local closing_marks = {
        ["\226\128\157"] = true,  -- 'U+2019 Right single quote
        ["》"] = true,  -- 》Right angle bracket
        ["〉"] = true,  -- 〉Small right angle
        ["】"] = true,  -- 】Right corner bracket
        ["）"] = true,  -- ）Right paren
    }
    
    local segments = {}
    local current = ""
    local i = 1
    
    while i <= string.len(text) do
        -- Get current UTF-8 character
        local byte1 = string.byte(text, i)
        local char_len = 1
        local char = string.sub(text, i, i)
        
        if byte1 >= 192 and byte1 < 224 then
            char_len = 2
            char = string.sub(text, i, i + 1)
        elseif byte1 >= 224 and byte1 < 240 then
            char_len = 3
            char = string.sub(text, i, i + 2)
        elseif byte1 >= 240 then
            char_len = 4
            char = string.sub(text, i, i + 3)
        end
        
        -- Look ahead for next character to check for double punctuation
        local next_byte1 = string.byte(text, i + char_len)
        local next_char_len = 1
        local next_char = nil
        
        if next_byte1 then
            if next_byte1 >= 192 and next_byte1 < 224 then
                next_char_len = 2
                next_char = string.sub(text, i + char_len, i + char_len + 1)
            elseif next_byte1 >= 224 and next_byte1 < 240 then
                next_char_len = 3
                next_char = string.sub(text, i + char_len, i + char_len + 2)
            elseif next_byte1 >= 240 then
                next_char_len = 4
                next_char = string.sub(text, i + char_len, i + char_len + 3)
            else
                next_char = string.sub(text, i + char_len, i + char_len)
            end
        end
        
        -- Check for 其前拆分 (split before opening marks)
        if before_split[char] then
            if current:match("[^ \t\n\r]") then
                table.insert(segments, current)
                current = char
            else
                current = current .. char
            end
        -- Check for double punctuation: closing mark + sentence-ending mark
        -- 引号+句末: "。、"！、"？
        -- 括号+句末: ）。、！）、？）
        -- 书名号+句末: 》。、》！、》？
        elseif closing_marks[char] and next_char and after_split[next_char] then
            current = current .. char .. next_char
            if current:match("[^ \t\n\r]") then
                table.insert(segments, current)
                current = ""
            end
            i = i + char_len + next_char_len
            goto continue
        -- Check for double punctuation: sentence-ending mark + closing mark
        -- 句末+引号: "。、"！、"？
        elseif after_split[char] and next_char and closing_marks[next_char] then
            current = current .. char .. next_char
            if current:match("[^ \t\n\r]") then
                table.insert(segments, current)
                current = ""
            end
            i = i + char_len + next_char_len
            goto continue
        -- Check for 组合后拆分 (split after closing paired marks without sentence-ending)
        elseif closing_marks[char] then
            current = current .. char
            if current:match("[^ \t\n\r]") then
                table.insert(segments, current)
                current = ""
            end
        -- Check for 其后拆分 (split after sentence-ending marks)
        elseif after_split[char] then
            current = current .. char
            if current:match("[^ \t\n\r]") then
                table.insert(segments, current)
                current = ""
            end
        else
            current = current .. char
        end
        
        i = i + char_len
        ::continue::
    end
    
    -- Add remaining text
    if current:match("[^ \t\n\r]") then
        table.insert(segments, current)
    end
    
    -- If no segments found, return whole text as one
    if #segments == 0 and text:match("[^ \t\n\r]") then
        table.insert(segments, text)
    end
    
    return segments
end

local function splitEnglishWords(text)
    -- Split English text into words
    local words = {}
    for word in text:gmatch("%S+") do
        -- Clean up word (remove some punctuation but keep basic structure)
        word = word:gsub("^[%p]*", ""):gsub("[%p]*$", "")
        if word and word ~= "" then
            table.insert(words, word)
        end
    end
    return words
end

local function calculateAdaptiveInterval(word, base_speed)
    -- Adapt speed based on word/sentence length
    -- Longer Chinese text needs more time to comprehend
    local char_count = 0
    
    -- Count UTF-8 characters using util function
    if util.splitToChars then
        char_count = #util.splitToChars(word)
    else
        -- Fallback: estimate from byte length (most CJK chars are 3 bytes)
        local byte_len = string.len(word)
        char_count = math.ceil(byte_len / 3)
    end
    
    if char_count <= 0 then
        char_count = 1
    end
    
    -- Adaptive factor: longer text = slower reading
    -- For Chinese sentences, each character adds 20% more time than base
    local adaptive_factor = 1.0
    if char_count > 1 then
        adaptive_factor = 1.0 + (char_count - 1) * 0.2
    end
    
    -- Calculate interval: base_interval * adaptive_factor
    local base_interval = 60000 / base_speed  -- Convert WPM to ms
    return math.floor(base_interval * adaptive_factor)
end

function FastReader:extractWordsFromCurrentPage()
    if not self.ui.document then
        logger.warn("FastReader: No document available")
        return {}
    end
    
    local text = ""
    local debug_info = {}
    
    logger.info("FastReader: Starting text extraction")
    logger.info("FastReader: Document type: " .. tostring(self.ui.document.provider))
    
    if self.ui.rolling then
        -- For reflowable documents (EPUB, FB2, etc.)
        -- Use the same method as readerview.lua getCurrentPageLineWordCounts()
        logger.info("FastReader: Rolling document - using getTextFromPositions")
        
        local success, text_result = pcall(function()
            local Screen = require("device").screen
            local res = self.ui.document:getTextFromPositions(
                {x = 0, y = 0},
                {x = Screen:getWidth(), y = Screen:getHeight()}, 
                true -- do not highlight
            )
            
            if res and res.text then
                logger.info("FastReader: getTextFromPositions success: " .. string.len(res.text) .. " characters")
                return res.text
            else
                logger.warn("FastReader: getTextFromPositions returned empty result")
                return nil
            end
        end)
        
        if success and text_result and text_result ~= "" then
            text = text_result
            table.insert(debug_info, "SUCCESS: getTextFromPositions returned " .. string.len(text_result) .. " chars")
            logger.info("FastReader: Text extraction success: " .. string.len(text_result) .. " characters")
        else
            table.insert(debug_info, "FAILED: getTextFromPositions - " .. tostring(text_result))
            logger.warn("FastReader: getTextFromPositions failed: " .. tostring(text_result))
            
            -- Fallback: try to get text from XPointers
            local fallback_success, fallback_text = pcall(function()
                -- For rolling documents, try XPointer method
                if self.ui.rolling and self.ui.document.getTextFromXPointers then
                    local current_xpointer = self.ui.rolling:getBookLocation()
                    if current_xpointer then
                        local text_result = self.ui.document:getTextFromXPointers(current_xpointer, current_xpointer, true)
                        if text_result and text_result.text and text_result.text ~= "" then
                            return text_result.text
                        end
                    end
                end
                return nil
            end)
            
            if fallback_success and fallback_text and fallback_text ~= "" then
                text = fallback_text
                table.insert(debug_info, "SUCCESS: XPointer fallback returned " .. string.len(fallback_text) .. " chars")
                logger.info("FastReader: XPointer fallback success: " .. string.len(fallback_text) .. " characters")
            else
                table.insert(debug_info, "FAILED: XPointer fallback - " .. tostring(fallback_text))
                logger.warn("FastReader: XPointer fallback failed: " .. tostring(fallback_text))
            end
        end
        
    elseif self.ui.paging then
        -- For paged documents (PDF, DjVu, etc.)
        local page = self.ui.paging.current_page
        table.insert(debug_info, "Document type: paging (PDF/DjVu/etc), page: " .. tostring(page))
        logger.info("FastReader: Paging document, page: " .. tostring(page))
        
        if page and self.ui.document.getPageText then
            local success, page_text = pcall(self.ui.document.getPageText, self.ui.document, page)
            if success and page_text and page_text ~= "" then
                text = page_text
                table.insert(debug_info, "SUCCESS: getPageText returned " .. string.len(page_text) .. " chars")
                logger.info("FastReader: Successfully extracted " .. string.len(page_text) .. " characters")
            else
                table.insert(debug_info, "FAILED: getPageText - " .. tostring(page_text))
                logger.warn("FastReader: getPageText failed: " .. tostring(page_text))
            end
        end
    else
        table.insert(debug_info, "ERROR: Unknown document type - neither rolling nor paging")
        logger.warn("FastReader: Unknown document type")
    end
    
    logger.info("FastReader: Final text extraction result: " .. (text and string.len(text) or 0) .. " characters")
    
    -- Show debug info if no text was found
    if not text or text == "" then
        logger.warn("FastReader: Text extraction completely failed")
        logger.info("FastReader: Debug info: " .. table.concat(debug_info, " | "))
        
        UIManager:show(InfoMessage:new{
            text = _("无法从此文档类型中提取文本"),
            timeout = 3,
        })
        
        return {}
    end
    
    -- Detect if text contains Chinese and split accordingly
    local words = {}
    if containsChineseText(text) then
        logger.info("FastReader: Chinese text detected, using sentence splitting")
        words = splitChineseSentences(text)
    else
        logger.info("FastReader: English text detected, using word splitting")
        words = splitEnglishWords(text)
    end
    
    logger.info("FastReader: Successfully extracted " .. #words .. " units")
    return words
end

local function wrapTextByWidth(text, face, max_width, max_lines, bold)
    -- Wrap text to fit within max_width
    -- bold: whether text should be measured with bold font
    -- If max_lines is provided and text exceeds it, text will be truncated
    -- If max_lines is nil or very large, all text will be shown
    if not text or text == "" then
        return {""}
    end
    
    local lines = {}
    local current_line = ""
    local chars = util.splitToChars(text)
    
    for idx, char in ipairs(chars) do
        local test_line = current_line .. char
        local metrics = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, test_line, true, bold)
        
        if metrics and metrics.x and metrics.x > max_width then
            -- Current line is full, need to start new line
            -- Check if this is the last character - if so, force it onto this line
            local is_last_char = (idx == #chars)
            if is_last_char then
                -- Force last char onto current line even if it exceeds
                current_line = test_line
            else
                if max_lines and #lines >= max_lines then
                    -- Force remaining chars onto last line
                    current_line = current_line .. char
                else
                    table.insert(lines, current_line)
                    current_line = char
                end
            end
        else
            current_line = test_line
        end
    end
    
    -- Add remaining text
    if current_line ~= "" then
        table.insert(lines, current_line)
    end
    
    return #lines > 0 and lines or {""}
end

local function getOptimalRecognitionIndex(char_count)
    if char_count <= 1 then
        return 1
    elseif char_count == 2 then
        return 1
    elseif char_count == 3 then
        return 2
    elseif char_count == 4 then
        return 2
    elseif char_count == 5 then
        return 3
    elseif char_count == 6 then
        return 3
    elseif char_count == 7 then
        return 4
    elseif char_count == 8 then
        return 4
    end
    return 5
end

local function measureTextWidth(face, text, bold)
    if not text or text == "" then
        return 0
    end
    local metrics = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, text, true, bold)
    return math.floor(metrics.x or 0)
end

local function calculateAnchorOffset(word, face, bold)
    if not word or word == "" then
        return 0, 1
    end

    local chars = util.splitToChars(word)
    local char_count = #chars
    if char_count == 0 then
        return 0, 1
    end

    local ovp_index = getOptimalRecognitionIndex(char_count)
    local prefix_text = table.concat(chars, "", 1, ovp_index - 1)
    local key_char = chars[ovp_index] or ""

    local prefix_width = measureTextWidth(face, prefix_text, bold)
    local key_width = measureTextWidth(face, key_char, bold)

    return prefix_width + (key_width / 2), ovp_index
end

function FastReader:showRSVPWord(current_word)
    if not current_word or current_word == "" then
        return
    end

    -- Create multi-word display with current word highlighted
    local Screen = require("device").screen
    
    -- Get preview words (current + next words)
    local preview_words = {}
    for i = 0, self.words_preview_count - 1 do
        local word_index = self.current_word_index + i
        if word_index <= #self.words then
            table.insert(preview_words, self.words[word_index])
        end
    end
    
    -- Fixed dimensions based on display size percentage settings
    local fixed_width = math.floor(Screen:getWidth() * (self.display_width_percent / 100))
    local fixed_height = math.floor(Screen:getHeight() * (self.display_height_percent / 100))
    
    -- Enforce minimum and maximum size limits
    -- For width: keep reasonable bounds but respect percentage
    local min_width = Screen:scaleBySize(220)
    local max_width = Screen:getWidth() - Screen:scaleBySize(40)
    fixed_width = math.max(min_width, math.min(fixed_width, max_width))
    
    -- For height: don't artificially limit the percentage setting too much
    -- Allow percentages to be respected, but keep a minimum for usability
    local min_height = Screen:scaleBySize(60)
    fixed_height = math.max(min_height, fixed_height)
    local text_padding = Screen:scaleBySize(20)
    local inner_width = fixed_width - (text_padding * 2)
    local inner_height = fixed_height - (text_padding * 2)
    local base_font_name = self.ovp_alignment_enabled and "infont" or "cfont"
    local anchor_face = Font:getFace(base_font_name, 28)
    local secondary_face = Font:getFace(base_font_name, 24)
    local inter_word_gap = Screen:scaleBySize(15)
    local min_left_padding = Screen:scaleBySize(20)
    local base_right_padding = self.words_preview_count <= 2 and Screen:scaleBySize(140) or Screen:scaleBySize(180)
    base_right_padding = math.max(Screen:scaleBySize(80), math.min(base_right_padding, math.floor(inner_width * 0.6)))
    local anchor_offset = self.ovp_alignment_enabled and calculateAnchorOffset(current_word, anchor_face, true) or 0

    -- Desired anchor position from the left edge of the inner area
    local anchor_target
    if self.ovp_alignment_enabled then
        local target_limit = Screen:scaleBySize(self.words_preview_count <= 2 and 90 or 140)
        anchor_target = math.min(inner_width - base_right_padding, target_limit)
        anchor_target = math.max(anchor_target, Screen:scaleBySize(90))
    else
        anchor_target = math.floor(inner_width / 2)
    end

    local leading_padding = 0
    if self.ovp_alignment_enabled then
        leading_padding = math.max(anchor_target - anchor_offset, 0)
    else
        leading_padding = math.max(math.floor((inner_width - base_right_padding) * 0.2), min_left_padding)
    end

    local layout_items = {}
    local total_content_width = leading_padding
    if leading_padding > 0 then
        table.insert(layout_items, {
            widget = HorizontalSpan:new{ width = leading_padding },
            width = leading_padding,
            removable = false,
            is_spacing = true,
            is_leading = true,
        })
    end

    for i, word in ipairs(preview_words) do
        local is_current = (i == 1)
        local word_color = is_current and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY

        -- Check if current word needs wrapping
        local word_widget
        local face = is_current and anchor_face or secondary_face
        local word_metrics = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, word, true, is_current)
        
        local is_wrapped = false
        if word_metrics and word_metrics.x and word_metrics.x > inner_width - base_right_padding - 20 then
            -- Word is too long, wrap it into multiple lines
            -- For wrapped text, use the full available inner width
            -- inner_width already accounts for frame padding (text_padding * 2)
            local wrap_width = inner_width - Screen:scaleBySize(10)
            -- Use 4 lines max to fit within display height (120px height - 40px padding = ~80px, ~20px per line)
            local wrapped_lines = wrapTextByWidth(word, face, wrap_width, 4, is_current)
            
            if #wrapped_lines > 1 then
                is_wrapped = true
                -- Use VerticalGroup for multi-line display
                local group = VerticalGroup:new{}
                for _, line in ipairs(wrapped_lines) do
                    local line_widget = TextWidget:new{
                        text = line,
                        face = face,
                        bold = is_current,
                        fgcolor = word_color,
                    }
                    table.insert(group, line_widget)
                end
                word_widget = group
            else
                -- Single line is fine
                word_widget = TextWidget:new{
                    text = wrapped_lines[1] or word,
                    face = face,
                    bold = is_current,
                    fgcolor = word_color,
                }
            end
        else
            -- Normal single-line widget
            word_widget = TextWidget:new{
                text = word,
                face = face,
                bold = is_current,
                fgcolor = word_color,
            }
        end

        -- For VerticalGroup, we need to get dimensions differently
        local widget_width
        local widget_classname = word_widget.classname or ""
        if widget_classname == "VerticalGroup" then
            -- VerticalGroup - wrap in CenterContainer with minimal padding
            local wrapper_width = inner_width - Screen:scaleBySize(10)
            local wrapper = CenterContainer:new{
                dimen = Geom:new{ w = wrapper_width, h = inner_height },
                word_widget,
            }
            widget_width = wrapper_width
            word_widget = wrapper
        else
            widget_width = word_widget:getSize().w
        end
        table.insert(layout_items, {
            widget = word_widget,
            width = widget_width,
            removable = (i > 1),
            is_spacing = false,
            is_word = true,
        })
        total_content_width = total_content_width + widget_width

        if i < #preview_words then
            table.insert(layout_items, {
                widget = HorizontalSpan:new{ width = inter_word_gap },
                width = inter_word_gap,
                removable = true,
                is_spacing = true,
            })
            total_content_width = total_content_width + inter_word_gap
        end
    end

    local max_allowed_width = inner_width - base_right_padding
    local idx = #layout_items
    while idx >= 1 and total_content_width > max_allowed_width do
        local item = layout_items[idx]
        if item.removable then
            total_content_width = total_content_width - item.width
            table.remove(layout_items, idx)
            if item.is_word then
                local prev = layout_items[idx - 1]
                if prev and prev.is_spacing and not prev.is_leading then
                    total_content_width = total_content_width - prev.width
                    table.remove(layout_items, idx - 1)
                    idx = idx - 1
                end
            end
        end
        idx = idx - 1
    end

    -- Ensure we never exceed inner width
    if total_content_width > inner_width then
        local overflow = total_content_width - inner_width
        local lead_item = layout_items[1]
        if lead_item and lead_item.is_leading then
            local trimmed = math.min(lead_item.width - min_left_padding, overflow)
            if trimmed > 0 then
                lead_item.width = lead_item.width - trimmed
                lead_item.widget.width = lead_item.width
                total_content_width = total_content_width - trimmed
            end
        end
    end

    local applied_leading = 0
    if layout_items[1] and layout_items[1].is_leading then
        applied_leading = layout_items[1].width
    end

    local word_widgets = {}
    for _, item in ipairs(layout_items) do
        table.insert(word_widgets, item.widget)
    end

    -- Create horizontal group containing all words
    local words_group = HorizontalGroup:new{
        align = "center",
        allow_mirroring = false,
    }

    -- Add all word widgets to the group
    for _, widget in ipairs(word_widgets) do
        table.insert(words_group, widget)
    end

    -- Overlay crosshair aligned to the optimal recognition point
    local word_container = LeftContainer:new{
        allow_mirroring = false,
        dimen = Geom:new{
            w = inner_width,
            h = inner_height,
        },
        words_group,
    }

    local inner_overlap = OverlapGroup:new{
        allow_mirroring = false,
        dimen = Geom:new{
            w = inner_width,
            h = inner_height,
        },
    }

    if self.ovp_alignment_enabled then
        local crosshair_width = math.max(Screen:scaleBySize(1), 1)
        local crosshair_height = inner_height
        local crosshair_center = applied_leading + anchor_offset
        local crosshair_x_offset = math.floor(crosshair_center - (crosshair_width / 2))
        crosshair_x_offset = math.max(0, math.min(inner_width - crosshair_width, crosshair_x_offset))

        local vertical_crosshair = LineWidget:new{
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            dimen = Geom:new{
                w = crosshair_width,
                h = crosshair_height,
            },
        }
        vertical_crosshair.overlap_offset = {crosshair_x_offset, 0}
        table.insert(inner_overlap, vertical_crosshair)

        local horizontal_width = math.min(Screen:scaleBySize(30), inner_width)
        local horizontal_height = math.max(Screen:scaleBySize(1), 1)
        local horizontal_crosshair = LineWidget:new{
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            dimen = Geom:new{
                w = horizontal_width,
                h = horizontal_height,
            },
        }
        local horizontal_x = math.floor(crosshair_x_offset + (crosshair_width / 2) - (horizontal_width / 2))
        horizontal_x = math.max(0, math.min(inner_width - horizontal_width, horizontal_x))
        local horizontal_y = math.floor((inner_height / 2) - (horizontal_height / 2))
        horizontal_crosshair.overlap_offset = {horizontal_x, horizontal_y}
        table.insert(inner_overlap, horizontal_crosshair)
    end

    table.insert(inner_overlap, word_container)

    -- Enclose in frame and keep widget centered on screen
    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 2,
        padding = text_padding,
        margin = 0,
        width = fixed_width,
        height = fixed_height,
        inner_overlap,
    }
    
    -- Center the fixed-width frame on screen
    local container = CenterContainer:new{
        dimen = Geom:new{
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        },
        frame,
    }
    
    -- Add tap/touch handlers to stop RSVP
    container.onTapClose = function()
        self:stopRSVP()
        return true
    end
    
    container.onTap = function()
        self:stopRSVP()
        return true
    end
    
    container.onGesture = function()
        self:stopRSVP()
        return true
    end
    
    frame.onTap = function()
        self:stopRSVP()
        return true
    end
    
    -- Remove previous RSVP widget if exists and do incremental refresh
    if self.rsvp_widget then
        local refresh_region = self.rsvp_widget.dimen or {
            x = 0, y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight()
        }
        UIManager:close(self.rsvp_widget, "ui", refresh_region)
    end
    
    self.rsvp_widget = container
    -- Use incremental refresh - only refresh the container area
    UIManager:show(self.rsvp_widget, "ui", self.rsvp_widget.dimen)
end

function FastReader:startRSVP()
    if self.rsvp_enabled then
        logger.info("FastReader: RSVP already enabled, ignoring start request")
        return
    end
    
    logger.info("FastReader: Starting RSVP mode")
    
    -- Enable continuous view mode
    self:enableContinuousView()
    
    -- Extract words from current page
    self.words = self:extractWordsFromCurrentPage()
    
    logger.info("FastReader: Extracted " .. #self.words .. " words from current page")
    
    if #self.words == 0 then
        -- Show error message and abort
        UIManager:show(InfoMessage:new{
            text = _("无法从文档中提取文本。请查看日志了解详情。"),
            timeout = 5,
        })
        logger.warn("FastReader: Cannot start RSVP - no words extracted")
        return
    end
    
    self.rsvp_enabled = true
    
    -- Check if we can resume from last position on this page
    if self:shouldResumeFromLastPosition() then
        self.current_word_index = self.last_word_index
        logger.info("FastReader: Resuming from word " .. self.current_word_index .. " of " .. #self.words)
        
        -- Show position indicator if enabled
        if self.show_position_indicator then
            self:showPositionIndicator()
        end
    else
        self.current_word_index = 1
        logger.info("FastReader: Starting from beginning")
    end
    
    -- Calculate adaptive interval based on first word length
    local first_word = self.words[self.current_word_index]
    local interval = calculateAdaptiveInterval(first_word, self.rsvp_speed)
    local char_count = util.splitToChars and #util.splitToChars(first_word) or string.len(first_word)
    logger.info("FastReader: RSVP adaptive interval for '" .. first_word .. "' (len=" .. char_count .. "): " .. interval .. "ms at " .. self.rsvp_speed .. " WPM")
    
    -- Start RSVP timer
    if self.rsvp_timer then
        UIManager:unschedule(self.rsvp_timer)
        self.rsvp_timer = nil
    end
    self.rsvp_timer = function()
        self.rsvp_timer = nil
        self:rsvpTick()
    end
    UIManager:scheduleIn(interval / 1000, self.rsvp_timer)
    
    -- Show first word
    self:showRSVPWord(self.words[self.current_word_index])
    
    logger.info("FastReader: RSVP started successfully")
end

function FastReader:stopRSVP()
    if not self.rsvp_enabled then
        return
    end
    
    logger.info("FastReader: Stopping RSVP mode")
    
    -- Save current position before stopping
    if #self.words > 0 and self.current_word_index > 1 then
        self:updateLastReadPosition()
    end
    
    self.rsvp_enabled = false
    
    -- Stop timer
    if self.rsvp_timer then
        UIManager:unschedule(self.rsvp_timer)
        self.rsvp_timer = nil
    end

    if self.pending_resume_task then
        UIManager:unschedule(self.pending_resume_task)
        self.pending_resume_task = nil
    end
    
    -- Remove RSVP widget
    if self.rsvp_widget then
        local refresh_region
        if self.rsvp_widget.dimen then
            refresh_region = self.rsvp_widget.dimen
        end
        UIManager:close(self.rsvp_widget, "ui", refresh_region)
        self.rsvp_widget = nil
    end
    
    -- Remove position indicator if shown
    self:hidePositionIndicator()
    
    -- Restore original view mode
    self:restoreOriginalView()
    
    UIManager:show(InfoMessage:new{
        text = _("速读已停止"),
        timeout = 1.5,
    })
end

function FastReader:rsvpTick()
    if not self.rsvp_enabled or #self.words == 0 then
        return
    end
    
    self.current_word_index = self.current_word_index + 1
    
    if self.current_word_index <= #self.words then
        -- Show next word
        local current_word = self.words[self.current_word_index]
        self:showRSVPWord(current_word)
        
        -- Schedule next tick with adaptive interval
        local interval = calculateAdaptiveInterval(current_word, self.rsvp_speed)
        if self.rsvp_timer then
            UIManager:unschedule(self.rsvp_timer)
            self.rsvp_timer = nil
        end
        self.rsvp_timer = function()
            self.rsvp_timer = nil
            self:rsvpTick()
        end
        UIManager:scheduleIn(interval / 1000, self.rsvp_timer)
    else
        -- End of current page reached, try to go to next page
        logger.info("FastReader: End of current page, attempting to go to next page")
        self:goToNextPageAndContinueRSVP()
    end
end

function FastReader:goToNextPageAndContinueRSVP()
    -- Try to go to next page
    local success = false
    
    if self.ui.paging then
        -- For paged documents (PDF, DjVu, etc.)
        local current_page = self.ui.paging.current_page
        local total_pages = self.ui.document:getPageCount()
        
        if current_page < total_pages then
            self.ui.paging:onGotoPage(current_page + 1)
            success = true
            logger.info("FastReader: Moved to page " .. (current_page + 1))
        else
            logger.info("FastReader: Already at last page")
            self:stopRSVP()
            UIManager:show(InfoMessage:new{
                text = _("已到达文档末尾"),
                timeout = 2,
            })
            return
        end
        
    elseif self.ui.rolling then
        -- For reflowable documents (EPUB, FB2, etc.)
        -- Try to scroll down by one screen
        local Event = require("ui/event")
        local ret = self.ui:handleEvent(Event:new("GotoViewRel", 1))
        if ret then
            success = true
            logger.info("FastReader: Scrolled to next screen in rolling mode")
        else
            logger.info("FastReader: Could not scroll further in rolling mode")
            self:stopRSVP()
            UIManager:show(InfoMessage:new{
                text = _("已到达文档末尾"),
                timeout = 2,
            })
            return
        end
    else
        logger.warn("FastReader: Unknown document type")
        self:stopRSVP()
        return
    end
    
    if success then
        -- Small delay to let the page render, then extract words and continue
        if self.pending_resume_task then
            UIManager:unschedule(self.pending_resume_task)
        end
        self.pending_resume_task = function()
            self.pending_resume_task = nil
            self:continueRSVPWithNewPage()
        end
        UIManager:scheduleIn(0.1, self.pending_resume_task)
    end
end

function FastReader:continueRSVPWithNewPage()
    if not self.rsvp_enabled then
        return
    end
    -- Extract words from new page/position
    local new_words = self:extractWordsFromCurrentPage()
    
    if #new_words > 0 then
        self.words = new_words
        self.current_word_index = 1
        -- Reset position tracking for new page
        self.last_page_hash = nil
        self.last_word_index = 1
        logger.info("FastReader: Extracted " .. #new_words .. " words from new page")
        
        -- Continue with first word of new page
        local first_word = self.words[self.current_word_index]
        self:showRSVPWord(first_word)
        
        -- Schedule next tick with adaptive interval
        local interval = calculateAdaptiveInterval(first_word, self.rsvp_speed)
        if self.rsvp_timer then
            UIManager:unschedule(self.rsvp_timer)
            self.rsvp_timer = nil
        end
        self.rsvp_timer = function()
            self.rsvp_timer = nil
            self:rsvpTick()
        end
        UIManager:scheduleIn(interval / 1000, self.rsvp_timer)
    else
        logger.warn("FastReader: No words extracted from new page, trying next page")
        -- Try one more page if this one is empty
        self:goToNextPageAndContinueRSVP()
    end
end

function FastReader:toggleRSVP()
    if self.rsvp_enabled then
        self:stopRSVP()
    else
        self:startRSVP()
    end
end

function FastReader:addToMainMenu(menu_items)
    menu_items.fastreader = {
        text = _("快速阅读"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("开始/停止速读"),
                callback = function()
                    self:toggleRSVP()
                end,
            },
            {
                text = _("点击文本启动速读"),
                checked_func = function()
                    return self.tap_to_launch_enabled
                end,
                callback = function()
                    self.tap_to_launch_enabled = not self.tap_to_launch_enabled
                    self:saveSettings()
                    
                    if self.tap_to_launch_enabled then
                        UIManager:show(InfoMessage:new{
                            text = _("点击文本启动速读已启用。点击文本即可开始速读。"),
                            timeout = 3,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("点击文本启动速读已禁用"),
                            timeout = 2,
                        })
                    end
                end,
                help_text = _("启用后，点击文本可直接开始速读，无需进入菜单。"),
            },
            {
                text = _("显示阅读位置"),
                checked_func = function()
                    return self.show_position_indicator
                end,
                callback = function()
                    self.show_position_indicator = not self.show_position_indicator
                    self:saveSettings()
                    
                    if self.show_position_indicator then
                        UIManager:show(InfoMessage:new{
                            text = _("位置指示器已启用。恢复速读时显示阅读进度。"),
                            timeout = 3,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("位置指示器已禁用"),
                            timeout = 2,
                        })
                    end
                end,
                help_text = _("启用后，在同一页面恢复速读时显示阅读位置指示器。"),
            },
            {
                text = _("最佳对齐(OVP)"),
                checked_func = function()
                    return self.ovp_alignment_enabled
                end,
                callback = function()
                    self.ovp_alignment_enabled = not self.ovp_alignment_enabled
                    self:saveSettings()

                    if self.ovp_alignment_enabled then
                        UIManager:show(InfoMessage:new{
                            text = _("最佳对齐已启用。词句按焦点十字准线对齐。"),
                            timeout = 3,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("最佳对齐已禁用。词句在小部件中居中。"),
                            timeout = 3,
                        })
                    end
                end,
                help_text = _("将每个词句与其最优识别点对齐，并显示细致的十字准线。"),
            },
            {
                text_func = function()
                    return T(_("预览词句: %1"), self.words_preview_count)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local spin_widget = SpinWidget:new{
                        title_text = _("RSVP预览词句"),
                        info_text = _("在RSVP小部件中显示的词句数(1-10)"),
                        width = math.floor(Screen:getWidth() * 0.6),
                        value = self.words_preview_count,
                        value_min = 1,
                        value_max = 10,
                        value_step = 1,
                        value_hold_step = 2,
                        default_value = 3,
                        unit = _("个"),
                        callback = function(spin)
                            self.words_preview_count = spin.value
                            self:saveSettings()
                            touchmenu_instance:updateItems()
                            UIManager:show(InfoMessage:new{
                                text = T(_("预览词句设置为 %1"), self.words_preview_count),
                                timeout = 2,
                            })
                        end
                    }
                    UIManager:show(spin_widget)
                end,
                help_text = _("控制RSVP小部件中显示的词句数。当前词句高亮，后续词句变暗。"),
            },
            {
                text_func = function()
                    return _("显示宽度: ") .. self.display_width_percent .. "%"
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local spin_widget = SpinWidget:new{
                        title_text = _("RSVP显示宽度"),
                        info_text = _("RSVP文本框占屏幕宽度的百分比(20%-100%)"),
                        width = math.floor(Screen:getWidth() * 0.6),
                        value = self.display_width_percent,
                        value_min = 20,
                        value_max = 100,
                        value_step = 5,
                        value_hold_step = 10,
                        default_value = 90,
                        unit = "%",
                        callback = function(spin)
                            self.display_width_percent = spin.value
                            self:saveSettings()
                            touchmenu_instance:updateItems()
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("显示宽度设置为 %d%%"), self.display_width_percent),
                                timeout = 2,
                            })
                        end
                    }
                    UIManager:show(spin_widget)
                end,
                help_text = _("控制RSVP文本框的宽度，以屏幕宽度的百分比表示。默认90%。"),
            },
            {
                text_func = function()
                    return _("显示高度: ") .. self.display_height_percent .. "%"
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local spin_widget = SpinWidget:new{
                        title_text = _("RSVP显示高度"),
                        info_text = _("RSVP文本框占屏幕高度的百分比(10%-50%)"),
                        width = math.floor(Screen:getWidth() * 0.6),
                        value = self.display_height_percent,
                        value_min = 10,
                        value_max = 50,
                        value_step = 5,
                        value_hold_step = 10,
                        default_value = 25,
                        unit = "%",
                        callback = function(spin)
                            self.display_height_percent = spin.value
                            self:saveSettings()
                            touchmenu_instance:updateItems()
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("显示高度设置为 %d%%"), self.display_height_percent),
                                timeout = 2,
                            })
                        end
                    }
                    UIManager:show(spin_widget)
                end,
                help_text = _("控制RSVP文本框的高度，以屏幕高度的百分比表示。默认25%。"),
            },
            {
                text = _("速读速度"),
                sub_item_table = {
                    {
                        text_func = function()
                            return T(_("当前: %1 WPM"), self.rsvp_speed)
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            local SpinWidget = require("ui/widget/spinwidget")
                            local spin_widget = SpinWidget:new{
                                title_text = _("RSVP阅读速度"),
                                info_text = _("每分钟词句数(50-1000)"),
                                width = math.floor(Screen:getWidth() * 0.6),
                                value = self.rsvp_speed,
                                value_min = 50,
                                value_max = 1000,
                                value_step = 25,
                                value_hold_step = 100,
                                default_value = 250,
                                unit = "WPM",
                                callback = function(spin)
                                    self.rsvp_speed = spin.value
                                    self:saveSettings()
                                    touchmenu_instance:updateItems()
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("RSVP速度设置为 %1 WPM"), self.rsvp_speed),
                                        timeout = 1,
                                    })
                                end
                            }
                            UIManager:show(spin_widget)
                        end,
                        separator = true,
                    },
                    {
                        text = _("100 WPM (极慢)"),
                        callback = function()
                            self.rsvp_speed = 100
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP速度设置为 100 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("150 WPM (慢)"),
                        callback = function()
                            self.rsvp_speed = 150
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP速度设置为 150 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("200 WPM (标准)"),
                        callback = function()
                            self.rsvp_speed = 200
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP速度设置为 200 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("250 WPM (快)"),
                        callback = function()
                            self.rsvp_speed = 250
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP速度设置为 250 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("300 WPM (很快)"),
                        callback = function()
                            self.rsvp_speed = 300
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP速度设置为 300 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("400 WPM (极快)"),
                        callback = function()
                            self.rsvp_speed = 400
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP速度设置为 400 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("500 WPM (超快)"),
                        callback = function()
                            self.rsvp_speed = 500
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP速度设置为 500 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                },
            },
        },
    }
end

function FastReader:onFastReaderRSVP()
    self:toggleRSVP()
end

-- Key event handlers for RSVP control
function FastReader:onKeyPress(key)
    if not self.rsvp_enabled then
        return false
    end
    
    if key == "Menu" or key == "Back" then
        self:stopRSVP()
        return true
    elseif key == "Press" or key == "LPgFwd" then
        -- Pause/resume RSVP
        if self.rsvp_timer then
            UIManager:unschedule(self.rsvp_timer)
            self.rsvp_timer = nil
            UIManager:show(InfoMessage:new{
                text = _("速读已暂停"),
                timeout = 1,
            })
        else
            local interval = 60000 / self.rsvp_speed
            self.rsvp_timer = function()
                self.rsvp_timer = nil
                self:rsvpTick()
            end
            UIManager:scheduleIn(interval / 1000, self.rsvp_timer)
            UIManager:show(InfoMessage:new{
                text = _("速读已继续"),
                timeout = 1,
            })
        end
        return true
    elseif key == "LPgBack" then
        -- Go to previous word
        if self.current_word_index > 1 then
            self.current_word_index = self.current_word_index - 1
            self:showRSVPWord(self.words[self.current_word_index])
        end
        return true
    end
    
    return false
end

function FastReader:onCloseDocument()
    -- Clean up when document is closed
    self:stopRSVP()
    self.enabled = false
end

function FastReader:onExit()
    -- Clean up when exiting
    self:stopRSVP()
end

function FastReader:setupTapHandler()
    -- Always register the tap handler, but check settings in the handler itself
    self.ui:registerTouchZones({
        {
            id = "fastreader_tap_to_launch",
            ges = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0, 
                ratio_w = 1, ratio_h = 1,  -- Full screen
            },
            overrides = {
                -- Override specific tap handlers to intercept taps on text
                "readerhighlight_tap",
                "tap_top_left_corner",
                "tap_top_right_corner", 
                "tap_left_bottom_corner",
                "tap_right_bottom_corner",
                "tap_forward",
                "tap_backward",
            },
            handler = function(ges)
                return self:onTapToLaunchRSVP(ges)
            end,
        },
    })
    
    logger.info("FastReader: Tap handler registered for RSVP launch")
end

function FastReader:onTapToLaunchRSVP(ges)
    -- Only handle if tap-to-launch is enabled and RSVP is not already running
    if not self.tap_to_launch_enabled or self.rsvp_enabled then
        return false -- Let other handlers process this
    end
    
    -- Check if we tapped on text area (similar to dictionary mode)
    if self:isTapOnTextArea(ges) then
        logger.info("FastReader: Tap on text area detected, launching RSVP")
        self:startRSVP()
        return true -- Consumed the tap, prevent other handlers
    end
    
    return false -- Let other handlers process this tap
end

function FastReader:isTapOnTextArea(ges)
    -- More sophisticated check based on DictionaryMode approach
    local Screen = require("device").screen
    local x, y = ges.pos.x, ges.pos.y
    
    -- Exclude UI areas (similar margins as used in KOReader)
    local ui_margin = Screen:scaleBySize(30)
    local footer_height = self.ui.view.footer_visible and self.ui.view.footer:getHeight() or 0
    
    -- Check if tap is in main reading area
    if x > ui_margin and x < (Screen:getWidth() - ui_margin) and 
       y > ui_margin and y < (Screen:getHeight() - footer_height - ui_margin) then
        
        -- Additional check: try to get text at tap position to confirm it's over text
        if self.ui.document and self.ui.view then
            local pos = self.ui.view:screenToPageTransform(ges.pos)
            if pos then
                local text_result = self.ui.document:getTextFromPositions(pos, pos)
                if text_result and text_result.text and text_result.text:match("%S") then
                    -- We have non-whitespace text at this position
                    return true
                end
            end
        end
    end
    
    return false
end

function FastReader:getCurrentPageHash()
    -- Create a hash to identify current page content and position
    local hash_data = ""
    
    if self.ui.paging then
        -- For paged documents, use page number
        hash_data = "page_" .. tostring(self.ui.paging.current_page)
    elseif self.ui.rolling then
        -- For rolling documents, use xpointer or position
        local xpointer = self.ui.rolling:getBookLocation()
        hash_data = "rolling_" .. tostring(xpointer or "unknown")
    end
    
    -- Add document file path to make hash unique per document
    if self.ui.document and self.ui.document.file then
        hash_data = hash_data .. "_" .. self.ui.document.file
    end
    
    return hash_data
end

function FastReader:shouldResumeFromLastPosition()
    local current_hash = self:getCurrentPageHash()
    return self.last_page_hash == current_hash and self.last_word_index > 1
end

function FastReader:updateLastReadPosition()
    self.last_page_hash = self:getCurrentPageHash()
    self.last_word_index = self.current_word_index
    logger.info("FastReader: Updated last read position to word " .. self.last_word_index)
end

function FastReader:showPositionIndicator()
    if not self.show_position_indicator or self.current_word_index <= 1 then
        return
    end
    
    -- Hide any existing indicator first
    self:hidePositionIndicator()
    
    -- Create a small indicator showing reading progress
    local progress_text = string.format("📖 %d/%d", self.current_word_index, #self.words)
    local percentage = math.floor((self.current_word_index / #self.words) * 100)
    
    local indicator_widget = TextWidget:new{
        text = progress_text,
        face = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_WHITE,
    }
    
    local indicator_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_DARK_GRAY,
        bordersize = 1,
        padding = 4,
        margin = 0,
        radius = 4,
        indicator_widget,
    }
    
    -- Position in top-right corner
    local Screen = require("device").screen
    local margin = Screen:scaleBySize(10)
    
    self.position_indicator_widget = OverlapGroup:new{
        dimen = Geom:new{
            x = Screen:getWidth() - indicator_frame:getSize().w - margin,
            y = margin,
            w = indicator_frame:getSize().w,
            h = indicator_frame:getSize().h,
        },
        indicator_frame,
    }
    
    UIManager:show(self.position_indicator_widget)
    
    -- Auto-hide after 3 seconds
    if self.indicator_timer then
        UIManager:unschedule(self.indicator_timer)
        self.indicator_timer = nil
    end
    self.indicator_timer = function()
        self.indicator_timer = nil
        self:hidePositionIndicator()
    end
    UIManager:scheduleIn(3, self.indicator_timer)
end

function FastReader:hidePositionIndicator()
    if self.position_indicator_widget then
        UIManager:close(self.position_indicator_widget)
        self.position_indicator_widget = nil
    end
    
    if self.indicator_timer then
        UIManager:unschedule(self.indicator_timer)
        self.indicator_timer = nil
    end
end

return FastReader
