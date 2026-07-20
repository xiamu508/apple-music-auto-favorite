-- favorite-track.applescript
-- 用法: osascript favorite-track.applescript "歌名1" "歌名2(简体)" "歌名3(繁体)"
-- 在 Music 当前打开的专辑/歌曲页里找到匹配歌名的行, 点行内"更多"菜单里的"喜爱"。
-- 输出: favorited / already_favorite / not_found / menu_not_found / accessibility_denied
--
-- 当前 (macOS 26 / Music) 专辑页歌曲行的辅助功能结构:
--   window 1 > scroll area(内容区, 直接挂在 window 下, 无 splitter group) > group(每行)
--   每行 group:
--     · AXDescription = 干净歌名 (如 "如约而至")            <- 定位歌曲行的首选依据
--     · 1 个 static text, 值形如 "序号 歌名 时长" (如 "8 如约而至 4:18")
--     · 1 个 button, description = "更多"
--     · 已喜爱的行还多一个 disabled button, description = "喜爱"  <- 已喜爱指示
--   按下"更多"后, 弹出菜单是该行 group 的子元素: menu 1 of g, 内含菜单项 "喜爱"
--
-- 注意陷阱: 专辑简介 group 的 description 是专辑名, 但简介正文里可能出现《歌名》,
--   且它也带一个"更多"(展开简介) 按钮。因此定位歌曲行时以 group 的 AXDescription 为准,
--   static text 兜底匹配时限制文本长度, 避免误命中长段简介。

on trimText(t)
	set t to t as text
	repeat while t begins with " "
		set t to text 2 thru -1 of t
	end repeat
	repeat while t ends with " "
		set t to text 1 thru -2 of t
	end repeat
	return t
end trimText

on titleMatches(candidate, titles)
	set candidate to my trimText(candidate)
	if candidate is "" then return false
	repeat with t in titles
		set wanted to my trimText(t)
		if wanted is not "" then
			if candidate is wanted then return true
			if (count of wanted) ≥ 2 and candidate contains wanted then return true
		end if
	end repeat
	return false
end titleMatches

-- ============ 歌曲行定位 (递归, 适配任意嵌套层级) ============

-- 判断一个 group 是否是匹配目标歌名的"歌曲行"。
on isTrackRow(g, titles)
	tell application "System Events"
		-- 该 group 必须含一个 description 为"更多"的按钮 (排除简介/货架卡片等)
		set hasMore to false
		try
			repeat with b in (buttons of g)
				set bd to ""
				try
					set bd to description of b as text
				end try
				if bd is "更多" or bd is "More" then
					set hasMore to true
					exit repeat
				end if
			end repeat
		end try
		if not hasMore then return false

		-- 首选: 行 group 的 AXDescription 即干净歌名
		try
			if my titleMatches(description of g as text, titles) then return true
		end try

		-- 兜底: 短 static text "序号 歌名 时长" 含歌名 (限制长度避免误命中简介)
		set txtList to {}
		try
			set txtList to value of static texts of g
		end try
		repeat with j from 1 to (count of txtList)
			set txtVal to ""
			try
				set txtVal to (item j of txtList) as text
			end try
			if txtVal is not "" and (count of txtVal) ≤ 40 then
				if my titleMatches(txtVal, titles) then return true
			end if
		end repeat

		return false
	end tell
end isTrackRow

-- 递归查找歌曲行 group。found 是 {missing value} 列表, 命中后 item 1 设为该 group。
on findRowGroup(el, depth, titles, found)
	tell application "System Events"
		if (item 1 of found) is not missing value then return
		if depth > 16 then return
		set kids to {}
		try
			set kids to UI elements of el
		on error
			return
		end try
		repeat with k in kids
			set isGroup to false
			try
				if (role of k as text) is "AXGroup" then set isGroup to true
			end try
			if isGroup then
				if my isTrackRow(k, titles) then
					set item 1 of found to (contents of k)
					return
				end if
			end if
			my findRowGroup(k, depth + 1, titles, found)
			if (item 1 of found) is not missing value then return
		end repeat
	end tell
end findRowGroup

-- ============ 在歌曲行上执行收藏 ============

-- 递归查找一个可见的 AXMenu (兜底: 万一菜单不是按钮/行 group 的直接子元素)
on findMenu(el, depth, found)
	tell application "System Events"
		if (item 1 of found) is not missing value then return
		if depth > 12 then return
		set kids to {}
		try
			set kids to UI elements of el
		on error
			return
		end try
		repeat with k in kids
			try
				if (role of k as text) is "AXMenu" then
					set item 1 of found to (contents of k)
					return
				end if
			end try
			my findMenu(k, depth + 1, found)
			if (item 1 of found) is not missing value then return
		end repeat
	end tell
end findMenu

-- 定位"更多"按钮弹出的菜单。按可靠性依次尝试:
--   1) menu 1 of 按钮本身 (AppKit "…" 按钮的菜单通常是按钮的子元素)
--   2) menu 1 of 行 group
--   3) 从行 group 递归查找
-- 找不到返回 missing value。
on locateMenu(moreBtn, g)
	tell application "System Events"
		try
			if (count of menus of moreBtn) > 0 then return menu 1 of moreBtn
		end try
		try
			if (count of menus of g) > 0 then return menu 1 of g
		end try
		set mFound to {missing value}
		try
			my findMenu(g, 0, mFound)
		end try
		return item 1 of mFound
	end tell
end locateMenu

-- 在已定位的行 group g 上收藏。返回 favorited / already_favorite / menu_not_found
on favoriteInRow(g)
	tell application "System Events"
		-- 1) 行内持久指示: 已喜爱的行含一个 description 为"喜爱"的(不可点)按钮
		try
			repeat with b in (buttons of g)
				set bd to ""
				try
					set bd to description of b as text
				end try
				if bd is "喜爱" or bd is "已喜爱" or bd is "Favorited" or bd is "Favourited" then
					return "already_favorite"
				end if
			end repeat
		end try

		-- 2) 找"更多"按钮
		set moreBtn to missing value
		try
			repeat with b in (buttons of g)
				set bd to ""
				try
					set bd to description of b as text
				end try
				if bd is "更多" or bd is "More" then
					set moreBtn to b
					exit repeat
				end if
			end repeat
		end try
		if moreBtn is missing value then return "menu_not_found"

		-- 3) 打开"更多"菜单: 优先 AXPress, 兜底 AXShowMenu; 轮询定位菜单
		set theMenu to missing value
		repeat with openAttempt from 1 to 4
			if openAttempt ≤ 2 then
				try
					perform action "AXPress" of moreBtn
				end try
			else
				try
					perform action "AXShowMenu" of moreBtn
				end try
			end if
			repeat with pollAttempt from 1 to 8
				delay 0.15
				set theMenu to my locateMenu(moreBtn, g)
				if theMenu is not missing value then exit repeat
			end repeat
			if theMenu is not missing value then exit repeat
		end repeat
		if theMenu is missing value then return "menu_not_found"

		-- 4) 读取菜单项
		set itemNames to {}
		try
			set itemNames to name of menu items of theMenu
		end try

		-- 先判断是否已喜爱(菜单含"取消喜爱"), 绝不误取消
		repeat with n in itemNames
			set nn to ""
			try
				set nn to n as text
			end try
			if nn is "撤销喜爱" or nn is "取消喜爱" or nn is "Unfavorite" or nn is "Unfavourite" or nn is "Undo Favorite" then
				try
					key code 53 -- Esc 关闭菜单
				end try
				return "already_favorite"
			end if
		end repeat

		-- 点"喜爱"
		repeat with i from 1 to (count of itemNames)
			set nn to ""
			try
				set nn to (item i of itemNames) as text
			end try
			if nn is "喜爱" or nn is "Favorite" or nn is "Favourite" or nn is "Love" then
				try
					perform action "AXPress" of menu item i of theMenu
					return "favorited"
				end try
			end if
		end repeat

		-- 菜单里没有"喜爱"项(可能已喜爱但用词不同/菜单结构异常): 关掉菜单
		try
			key code 53
		end try
		return "menu_not_found"
	end tell
end favoriteInRow

-- ============ 主流程 ============

on run argv
	if (count of argv) is 0 then return "not_found"
	set titles to {}
	repeat with a in argv
		set t to my trimText(a)
		if t is not "" and titles does not contain t then set end of titles to t
	end repeat
	if (count of titles) is 0 then return "not_found"

	tell application "System Events"
		if not (UI elements enabled) then return "accessibility_denied"
	end tell

	tell application "Music" to activate
	delay 0.3
	tell application "System Events"
		tell process "Music"
			try
				set frontmost to true
			end try
		end tell
	end tell

	-- 页面可能还在加载: 轮询最多 ~4 秒定位歌曲行并收藏。
	-- 找不到就快速返回 not_found, 由 .command 重开链接重试。
	set lastResult to "not_found"
	repeat with attempt from 1 to 8
		set found to {missing value}
		tell application "System Events"
			tell process "Music"
				if (count of windows) > 0 then
					try
						my findRowGroup(window 1, 0, titles, found)
					end try
				end if
			end tell
		end tell
		set g to item 1 of found
		if g is not missing value then
			set r to my favoriteInRow(g)
			if r is "favorited" or r is "already_favorite" then return r
			set lastResult to r
		end if
		delay 0.5
	end repeat

	return "not_found"
end run
