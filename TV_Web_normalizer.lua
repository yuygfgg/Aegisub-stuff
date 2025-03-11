local gt = aegisub.gettext

script_name = gt("TV_Web_normalizer")
script_description = gt("一键整理 tv/web 日语字幕")
script_version = "1.0"

--[[
功能简介：
- 删除特效标签、括号内文本、赘余字符、换行符和零宽空格
- 删除空行和TV字幕的Rubi行
- 分割有两位说话人的字幕行
- 合并文本内容相同或时间码相同的相邻行
- 处理字母和数字：相邻的转为半角，孤立的转为全角
- 将半角片假名转为全角片假名
- 将部分平假名转为汉字
- 删除部分感叹词、拟声词和拟态词
- 将所有行的样式统一设置为Dial-JPN
]]

-- 引入依赖模块
local re = require 'aegisub.re'

-- 配置常量
local DEFAULT_STYLE = "Dial-JPN"

-- 辅助函数部分
-- 深拷贝表格，用于创建表格的完整副本
local function deep_copy(original)
    if type(original) ~= "table" then return original end
    
    local copy = {}
    for key, value in pairs(original) do
        copy[key] = type(value) == "table" and deep_copy(value) or value
    end
    return copy
end

-- 使用正则表达式进行替换
local function apply_replacements(subtitles, replace_table)
    for i = 1, #subtitles do
        local line = subtitles[i]
        if line.class == "dialogue" then
            for _, pair in ipairs(replace_table) do
                local pattern, replacement = pair[1], pair[2]
                line.text = re.sub(line.text, pattern, replacement)
            end
            subtitles[i] = line
        end
    end
end

-- 分割含有两个说话人的字幕行
local function split_dual_speaker_lines(subtitles)
    local offset = 0
    for i = 1, #subtitles do
        local index = i + offset
        if index > #subtitles then break end  -- 安全检查
        
        local line = subtitles[index]
        -- 检查是否含有两个说话人（通过"）"和"（"之间的内容判断）
        if line.class == "dialogue" and re.find(line.text, "）.*?（") then
            local original_text = line.text
            local half_duration = math.floor((line.end_time - line.start_time) / 2)

            -- 修改原行，只保留第一个说话人的内容
            line.actor = "Split"  -- 标记已分割的行
            line.end_time = line.start_time + half_duration
            line.text = re.sub(line.text, "^(.*?)）(.*?)（(.*?)$", "\\2")
            subtitles[index] = line

            -- 创建新行，保留第二个说话人的内容
            local new_line = deep_copy(line)
            new_line.start_time = line.end_time
            new_line.end_time = new_line.start_time + half_duration
            new_line.text = re.sub(original_text, "^.*）(.*)$", "\\1")

            subtitles.insert(index + 1, new_line)
            offset = offset + 1
        end
    end
end

-- 合并文本内容相同的相邻行
local function merge_identical_text_lines(subtitles)
    local i = 1
    while i < #subtitles do
        local current_line = subtitles[i]
        local next_line = subtitles[i + 1]

        if current_line.class == "dialogue" and next_line.class == "dialogue" and 
           current_line.text == next_line.text then
            -- 扩展当前行的时间范围
            current_line.end_time = next_line.end_time
            subtitles[i] = current_line
            
            -- 删除下一行
            subtitles.delete(i + 1)
        else
            i = i + 1
        end
    end
end

-- 合并时间码相同的相邻行
local function merge_identical_timing_lines(subtitles)
    local i = 1
    while i < #subtitles do
        local current_line = subtitles[i]
        local next_line = subtitles[i + 1]

        if current_line.class == "dialogue" and next_line.class == "dialogue" and
           current_line.start_time == next_line.start_time and 
           current_line.end_time == next_line.end_time then
            -- 合并文本内容（加全角空格分隔）
            current_line.text = current_line.text .. "　" .. next_line.text
            subtitles[i] = current_line
            
            -- 删除下一行
            subtitles.delete(i + 1)
        else
            i = i + 1
        end
    end
end

-- 删除空行和Rubi行
local function remove_empty_and_rubi_lines(subtitles)
    local i = 1
    while i <= #subtitles do
        local line = subtitles[i]
        
        -- 检查是否为空对话行或样式为Rubi的行
        if line.class == "dialogue" and 
           (re.match(line.text, "^\\s*$") or (line.style and line.style == "Rubi")) then
            subtitles.delete(i)
        else
            i = i + 1
        end
    end
end

-- 将孤立的半角字符转换为全角字符
local function convert_isolated_chars_to_fullwidth(subtitles)
    -- 处理每一行字幕
    for i = 1, #subtitles do
        local line = subtitles[i]
        if line.class == "dialogue" then
            -- 查找单独的半角字符并转换为全角
            line.text = re.sub(line.text, "([^A-Za-z0-9])([A-Za-z0-9])([^A-Za-z0-9])", 
                function(captures)
                    local before, char, after = captures[1], captures[2], captures[3]
                    local fullwidth_char = ""
                    
                    -- 半角到全角的映射
                    if char:match("[A-Z]") then
                        fullwidth_char = string.char(0xEF, 0xBC, 0x81 + (string.byte(char) - 65))
                    elseif char:match("[a-z]") then
                        fullwidth_char = string.char(0xEF, 0xBD, 0x81 + (string.byte(char) - 97))
                    elseif char:match("[0-9]") then
                        fullwidth_char = string.char(0xEF, 0xBC, 0x90 + (string.byte(char) - 48))
                    else
                        fullwidth_char = char
                    end
                    
                    return before .. fullwidth_char .. after
                end
            )
            
            -- 处理开头的单独半角字符
            line.text = re.sub(line.text, "^([A-Za-z0-9])([^A-Za-z0-9])", 
                function(captures)
                    local char, after = captures[1], captures[2]
                    local fullwidth_char = ""
                    
                    if char:match("[A-Z]") then
                        fullwidth_char = string.char(0xEF, 0xBC, 0x81 + (string.byte(char) - 65))
                    elseif char:match("[a-z]") then
                        fullwidth_char = string.char(0xEF, 0xBD, 0x81 + (string.byte(char) - 97))
                    elseif char:match("[0-9]") then
                        fullwidth_char = string.char(0xEF, 0xBC, 0x90 + (string.byte(char) - 48))
                    else
                        fullwidth_char = char
                    end
                    
                    return fullwidth_char .. after
                end
            )
            
            -- 处理结尾的单独半角字符
            line.text = re.sub(line.text, "([^A-Za-z0-9])([A-Za-z0-9])$", 
                function(captures)
                    local before, char = captures[1], captures[2]
                    local fullwidth_char = ""
                    
                    if char:match("[A-Z]") then
                        fullwidth_char = string.char(0xEF, 0xBC, 0x81 + (string.byte(char) - 65))
                    elseif char:match("[a-z]") then
                        fullwidth_char = string.char(0xEF, 0xBD, 0x81 + (string.byte(char) - 97))
                    elseif char:match("[0-9]") then
                        fullwidth_char = string.char(0xEF, 0xBC, 0x90 + (string.byte(char) - 48))
                    else
                        fullwidth_char = char
                    end
                    
                    return before .. fullwidth_char
                end
            )
            
            -- 单独一个字符的情况
            line.text = re.sub(line.text, "^([A-Za-z0-9])$", 
                function(captures)
                    local char = captures[1]
                    local fullwidth_char = ""
                    
                    if char:match("[A-Z]") then
                        fullwidth_char = string.char(0xEF, 0xBC, 0x81 + (string.byte(char) - 65))
                    elseif char:match("[a-z]") then
                        fullwidth_char = string.char(0xEF, 0xBD, 0x81 + (string.byte(char) - 97))
                    elseif char:match("[0-9]") then
                        fullwidth_char = string.char(0xEF, 0xBC, 0x90 + (string.byte(char) - 48))
                    else
                        fullwidth_char = char
                    end
                    
                    return fullwidth_char
                end
            )
            
            subtitles[i] = line
        end
    end
end

-- 设置所有对话行的样式
local function set_all_lines_style(subtitles, style_name)
    for i = 1, #subtitles do
        local line = subtitles[i]
        if line.class == "dialogue" then
            line.style = style_name
            subtitles[i] = line
        end
    end
end

-- 替换规则表
-- 第一组：基本清理
local basic_replacements = {
    {"\\\\N", " "}, -- 删除换行符
}

-- 第二组：标准化符号和删除特效标签
local symbol_and_tag_replacements = {
    -- 标准化符号
    {"っ…", "っ "},
    {"　", " "},
    {" +", "　"},
    {"(．．．|\\.\\.\\.|…　)", "…"},
    {"("|｢|『|［)+?", "「"},
    {"("|｣|』|］)+?", "」"},
    
    -- 删除特效标签和说话人信息
    {"\\{.*?\\}", ""},
    {"\\(.*?\\)", ""},
    {"（.*?）", ""},
    {".*?：", ""},
    
    -- 删除赘余符号
    {"(^　|‎|　$)", ""},
    {"(≪|≫|《|》|｟|｠|＜|＞|〈|〉|〔|〕)", ""},
    {"(｡|。|！|\\!|^…|…$|～$|⸺|―|-)", ""},
    {"(♪|♬|→|➡|🔊|☎|♥|✡|📱|📺|🎧|🎤|💻|📼|📹|🎬|⚟)", ""},
    
    -- 删除特定上下文中的赘余空格
    {"(多分|たぶん)　", "\\1"},
    {"(結構|けっこう)　", "\\1"},
    {"(絶対|ぜったい)　", "\\1"},
    {"(随分|ずいぶん)　", "\\1"},
    {"(一番|いちばん)　", "\\1"},
    {"(一体|いったい)　", "\\1"},
    {"(一杯|いっぱい)　", "\\1"},
    {"(朝|夜|午前|午後|最近|結局|実際|多数|全部|一切)　", "\\1"},
    {"(しか|なぜ|少し|必ず|もう|いずれ|いつか|ほとんど)　", "\\1"},
    
    -- 规范化问号
    {"(あ|か|な|ね|かしら|こ|よ|だ|ん|だろ|だろう|でしょ|でしょう|なんで|どうして|どうした){1}(？|\\?){1}", "\\1"},
    {"^(何|なに){1}(？|\\?){1}$", "\\1"},
}

-- 第三组：字符转换
local character_conversions = {
    -- 半角片假名到全角片假名的转换
    {"ｱ", "ア"}, {"ｲ", "イ"}, {"ｳ", "ウ"}, {"ｴ", "エ"}, {"ｵ", "オ"},
    {"ｧ", "ァ"}, {"ｨ", "ィ"}, {"ｩ", "ゥ"}, {"ｪ", "ェ"}, {"ｫ", "ォ"},
    {"ｶ", "カ"}, {"ｷ", "キ"}, {"ｸ", "ク"}, {"ｹ", "ケ"}, {"ｺ", "コ"},
    {"ｶﾞ", "ガ"}, {"ｷﾞ", "ギ"}, {"ｸﾞ", "グ"}, {"ｹﾞ", "ゲ"}, {"ｺﾞ", "ゴ"},
    {"ｻ", "サ"}, {"ｼ", "シ"}, {"ｽ", "ス"}, {"ｾ", "セ"}, {"ｿ", "ソ"},
    {"ｻﾞ", "ザ"}, {"ｼﾞ", "ジ"}, {"ｽﾞ", "ズ"}, {"ｾﾞ", "ゼ"}, {"ｿﾞ", "ゾ"},
    {"ﾀ", "タ"}, {"ﾁ", "チ"}, {"ﾂ", "ツ"}, {"ﾃ", "テ"}, {"ﾄ", "ト"},
    {"ｯ", "ッ"},
    {"ﾀﾞ", "ダ"}, {"ﾁﾞ", "ヂ"}, {"ﾂﾞ", "ヅ"}, {"ﾃﾞ", "デ"}, {"ﾄﾞ", "ド"},
    {"ﾅ", "ナ"}, {"ﾆ", "ニ"}, {"ﾇ", "ヌ"}, {"ﾈ", "ネ"}, {"ﾉ", "ノ"},
    {"ﾊ", "ハ"}, {"ﾋ", "ヒ"}, {"ﾌ", "フ"}, {"ﾍ", "ヘ"}, {"ﾎ", "ホ"},
    {"ﾊﾞ", "バ"}, {"ﾋﾞ", "ビ"}, {"ﾌﾞ", "ブ"}, {"ﾍﾞ", "ベ"}, {"ﾎﾞ", "ボ"},
    {"ﾊﾟ", "パ"}, {"ﾋﾟ", "ピ"}, {"ﾌﾟ", "プ"}, {"ﾍﾟ", "ペ"}, {"ﾎﾟ", "ポ"},
    {"ﾏ", "マ"}, {"ﾐ", "ミ"}, {"ﾑ", "ム"}, {"ﾒ", "メ"}, {"ﾓ", "モ"},
    {"ﾔ", "ヤ"}, {"ﾕ", "ユ"}, {"ﾖ", "ヨ"},
    {"ｬ", "ャ"}, {"ｭ", "ュ"}, {"ｮ", "ョ"},
    {"ﾗ", "ラ"}, {"ﾘ", "リ"}, {"ﾙ", "ル"}, {"ﾚ", "レ"}, {"ﾛ", "ロ"},
    {"ﾜ", "ワ"}, {"ｦ", "ヲ"}, {"ﾝ", "ン"},
    {"､", "、"}, {"｡", "。"}, {"･", "・"}, {"ｰ", "ー"},
    
    -- 全角字母数字到半角的转换
    {"Ａ", "A"}, {"Ｂ", "B"}, {"Ｃ", "C"}, {"Ｄ", "D"}, {"Ｅ", "E"}, {"Ｆ", "F"}, {"Ｇ", "G"},
    {"Ｈ", "H"}, {"Ｉ", "I"}, {"Ｊ", "J"}, {"Ｋ", "K"}, {"Ｌ", "L"}, {"Ｍ", "M"}, {"Ｎ", "N"},
    {"Ｏ", "O"}, {"Ｐ", "P"}, {"Ｑ", "Q"}, {"Ｒ", "R"}, {"Ｓ", "S"}, {"Ｔ", "T"},
    {"Ｕ", "U"}, {"Ｖ", "V"}, {"Ｗ", "W"}, {"Ｘ", "X"}, {"Ｙ", "Y"}, {"Ｚ", "Z"},
    {"ａ", "a"}, {"ｂ", "b"}, {"ｃ", "c"}, {"ｄ", "d"}, {"ｅ", "e"}, {"ｆ", "f"}, {"ｇ", "g"},
    {"ｈ", "h"}, {"ｉ", "i"}, {"ｊ", "j"}, {"ｋ", "k"}, {"ｌ", "l"}, {"ｍ", "m"}, {"ｎ", "n"},
    {"ｏ", "o"}, {"ｐ", "p"}, {"ｑ", "q"}, {"ｒ", "r"}, {"ｓ", "s"}, {"ｔ", "t"},
    {"ｕ", "u"}, {"ｖ", "v"}, {"ｗ", "w"}, {"ｘ", "x"}, {"ｙ", "y"}, {"ｚ", "z"},
    {"０", "0"}, {"１", "1"}, {"２", "2"}, {"３", "3"}, {"４", "4"},
    {"５", "5"}, {"６", "6"}, {"７", "7"}, {"８", "8"}, {"９", "9"},
}

-- 第四组：最终精细调整
local final_adjustments = {
    -- 删除赘余符号
    {"(^　|　$|^～|～$|^…|…$|^・|・$)", ""},
    
    -- 自定义替换平假名为汉字和各种文本规范化
    {"も～", "もう"}, {"ま～", "まあ"},
    {"ちょ…　", "ちょ…"}, {"ちょっ　", "ちょ…"},
    {"ちっ　違", "ち…違"}, {"ちっ…違", "ち…違"},
    {"まっ　待", "ま…待"}, {"まっ…待", "ま…待"},
    {"だっ　大丈夫", "だ…大丈夫"}, {"だっ…大丈夫", "だ…大丈夫"},
    {"べっ　別に", "べ…別に"}, {"べっ…別に", "べ…別に"},
    {"^何$", "なに"}, {"^何何$", "なになに"},
    {"もん絶(?!対)", "悶絶"}, {"(?<!あ)あした", "明日"}, {"かわいそう", "可哀相"},
    {"べつに", "別に"}, {"たしかに", "確かに"}, {"ひこ星", "彦星"}, {"ぼ印", "拇印"},
    {"わいせつ", "猥褻"}, {"卑わい", "卑猥"}, {"演えき", "演繹"}, {"さく裂", "炸裂"},
    {"わい談", "猥談"}, {"隠ぺい", "隠蔽"}, {"皮ふ", "皮膚"}, {"復しゅう", "復讐"},
    {"邪けん", "邪険"}, {"けん制", "牽制"}, {"急きょ", "急遽"}, {"軟こう", "軟膏"},
    {"せん越", "僭越"}, {"教べん", "教鞭"}, {"敏しょう", "敏捷"}, {"ねつ造", "捏造"},
    {"せん滅", "殲滅"}, {"けん属", "眷属"}, {"投てき", "投擲"}, {"垂ぜん", "垂涎"},
    {"殺りく", "殺戮"}, {"飢きん", "飢饉"}, {"まん延", "蔓延"}, {"執よう", "執拗"},
    {"ひん死", "瀕死"}, {"もうろう", "朦朧"}, {"金ぱく", "金箔"}, {"強じん", "強靭"},
    {"欺まん", "欺瞞"}, {"安ねい", "安寧"}, {"標ぼう", "標榜"}, {"ろうぜき", "狼藉"},
    {"朝げ", "朝餉"}, {"夕げ", "夕餉"}, {"ひきょう", "卑怯"}, {"しょく罪", "贖罪"},
    {"ふらち", "不埒"}, {"終えん", "終焉"}, {"ちょう愛", "寵愛"}, {"敬けん", "敬虔"},
    {"きゅう弾", "糾弾"}, {"えん罪", "冤罪"}, {"怒とう", "怒涛"}, {"てん足", "纏足"},
    {"範ちゅう", "範疇"}, {"清そ", "清楚"}, {"ごう音", "轟音"}, {"くん製", "燻製"},
    {"ろう屋", "牢屋"}, {"冒とく", "冒涜"}, {"塩こしょう", "塩胡椒"}, {"混とん", "混沌"},
    {"流ちょう", "流暢"}, {"すう勢", "趨勢"}, {"けんでん", "喧伝"}, {"さん奪", "簒奪"},
    {"秘けつ", "秘訣"}, {"しぜん", "自然"}, {"こつ然", "忽然"}, {"ぎょうこう", "僥倖"},
    {"刺しゅう", "刺繍"}, {"覆てつ", "覆轍"}, {"分べん", "分娩"}, {"伝ぱ", "伝播"},
    {"反すう", "反芻"}, {"さん然", "燦然"}, {"よう兵", "傭兵"}, {"へ理屈", "屁理屈"},
    
    -- 删除无实义的语气词、拟声词等
    {"(うっ　|うぅ|うわあ|わあ)+[ぁっッ]?", ""},
    {"[あアうウふフ]～[んン]", ""},
    {"(ア){0,1}(ハ){2,5}[ッ～…ー]{0,1}", ""},
    {"(アハ|ハァ|フム|フン|ドーン|ピュン)+[ッ～…ー]{0,1}", ""},
    {"^(あ|う|え|お|ん|うわ|うん|ア){0,1}(ぁ|っ|ッ|～|…|ー){0,1}(？){0,1}$", ""}, -- 单独出现
    {"(あ|え|お|ん|ほ|わ|ひ|く|ぐ|ね|お|ハ|ウ|フ|へえ)+[ぁぃっッァゥ？～…]　", ""}, -- 出现在句中
    {"(あ|え|お|ん|ほ|わ|ひ|ぐ|ね|お|ハ|ウ|フ|へえ)+[ぁぃっッァゥ？～…]$", ""}, -- 出现在句尾
    
    -- 最后一次规范标点符号
    {"(^　|　$|^～|～$|^…|…$|^・|・$)", ""},
    {"？", "\\?"},
    {"(.)(っ　|…　)(\\1)(.*)", "\\1…\\3\\4"}, -- 规范结巴表述
    {"([0-9]),([0-9]{3,3})", "\\1\\2"}, -- 删除千分位分隔符
}

-- 主处理函数
local function process_subtitles(subtitles, selected_lines, active_line)
    -- 检查字幕数量
    if #subtitles == 0 then
        aegisub.log("错误：没有可处理的字幕行。")
        return
    end

    -- 步骤1: 应用基本替换
    apply_replacements(subtitles, basic_replacements)
    
    -- 步骤2: 应用符号和标签替换
    apply_replacements(subtitles, symbol_and_tag_replacements)
    
    -- 步骤3: 分割有两个说话人的行
    split_dual_speaker_lines(subtitles)
    
    -- 步骤4: 删除空行和Rubi行（先删除，避免这些行参与后续合并）
    remove_empty_and_rubi_lines(subtitles)
    
    -- 步骤5: 合并文本相同的相邻行
    merge_identical_text_lines(subtitles)
    
    -- 步骤6: 合并时间码相同的相邻行
    merge_identical_timing_lines(subtitles)
    
    -- 步骤7: 应用字符转换
    apply_replacements(subtitles, character_conversions)
    
    -- 步骤8: 应用最终调整
    apply_replacements(subtitles, final_adjustments)
    
    -- 步骤9: 将非连续半角字符转换为全角
    convert_isolated_chars_to_fullwidth(subtitles)
    
    -- 步骤10: 设置所有行的样式
    set_all_lines_style(subtitles, DEFAULT_STYLE)
    
    -- 设置撤销点
    aegisub.set_undo_point(script_name)
    aegisub.log("处理完成：共处理 " .. #subtitles .. " 行字幕。")
end

-- 注册脚本
aegisub.register_macro(script_name, script_description, process_subtitles)
