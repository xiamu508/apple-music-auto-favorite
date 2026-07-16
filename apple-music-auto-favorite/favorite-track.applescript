-- favorite-track.applescript
-- 用法: osascript favorite-track.applescript "歌名1" "歌名2(简体)" "歌名3(繁体)"
-- 在 Music 当前打开的专辑页里找到匹配歌名的行，点"更多"菜单里的"喜爱"。
-- 输出: favorited / already_favorite / not_found / menu_not_found / accessibility_denied
--
-- 快速路径(毫秒级): 专辑页歌曲行的固定 AX 结构
--   window 1 > splitter group 1 > 内容 scroll area > list 1 > list 2 > group(每行)
--   行内: static texts = {序号, "", 歌名, 时长}; buttons 描述含 更多/已喜爱
--   按下"更多"后弹出菜单出现在同一 group 下: menu 1 of g
-- 兜底路径: 原递归全树搜索(应对布局变化的页面)

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

-- ============ 快速路径 ============

-- 在行 group 的弹出菜单里点"喜爱"。返回 favorited/already_favorite/menu_not_found
on clickFavoriteInRowMenu(g)
	tell application "System Events"
		set moreBtn to missing value
		try
			set moreBtn to (first button of g whose description is "更多" or description is "More")
		end try
		if moreBtn is missing value then return "menu_not_found"
		repeat with pressAttempt from 1 to 3
			perform action "AXPress" of moreBtn
			repeat with pollAttempt from 1 to 8
				delay 0.15
				try
					set theMenu to menu 1 of g
					set itemNames to name of UI elements of theMenu
					repeat with i from 1 to (count of itemNames)
						set n to item i of itemNames
						try
							set n to n as text
						on error
							set n to ""
						end try
						if n is "撤销喜爱" or n is "取消喜爱" or n is "Unfavorite" or n is "Unfavourite" or n is "Undo Favorite" then
							key code 53 -- Esc 关闭菜单
							return "already_favorite"
						else if n is "喜爱" or n is "Favorite" or n is "Favourite" or n is "Love" then
							perform action "AXPress" of UI element i of theMenu
							return "favorited"
						end if
					end repeat
				end try
			end repeat
		end repeat
		return "menu_not_found"
	end tell
end clickFavoriteInRowMenu

-- 专辑页快速路径。返回 favorited/already_favorite/"" (空=此路不通,走兜底)
on fastPathFavorite(titles)
	tell application "System Events"
		tell process "Music"
			try
				set sg to splitter group 1 of window 1
			on error
				return ""
			end try
			-- 内容区通常是 splitter group 的第 4 个子元素(第 2 个 scroll area)，
			-- 但为稳妥起见依次尝试每个 scroll area
			repeat with sa in scroll areas of sg
				set rowGroups to missing value
				try
					set rowGroups to groups of list 2 of list 1 of sa
				end try
				if rowGroups is not missing value then
					repeat with g in rowGroups
						set rowTitle to ""
						try
							set vals to value of static texts of g
							if (count of vals) ≥ 3 then set rowTitle to item 3 of vals as text
						end try
						if my titleMatches(rowTitle, titles) then
							-- 已喜爱指示按钮是持久的，先快速判断
							try
								set descs to description of buttons of g
								repeat with d in descs
									if (d as text) is in {"已喜爱", "Favorited", "撤销喜爱"} then return "already_favorite"
								end repeat
							end try
							return my clickFavoriteInRowMenu(g)
						end if
					end repeat
				end if
			end repeat
			return ""
		end tell
	end tell
end fastPathFavorite

-- ============ 兜底路径(递归全树, 慢但通用) ============

on findMoreButton(el, depth, titles, state)
	tell application "System Events"
		if depth > 18 then return
		try
			set kids to UI elements of el
		on error
			return
		end try
		repeat with k in kids
			try
				set r to role of k as text
				if r is "AXStaticText" then
					try
						set v to value of k as text
						if my titleMatches(v, titles) then
							set item 1 of state to true
						end if
					end try
				else if r is "AXButton" and (item 1 of state) is true and (item 2 of state) is missing value then
					try
						set d to description of k as text
						if d is "更多" or d is "More" then
							set item 2 of state to k
							return
						end if
					end try
				end if
			end try
			my findMoreButton(k, depth + 1, titles, state)
			if (item 2 of state) is not missing value then return
		end repeat
	end tell
end findMoreButton

on findFavoriteItem(el, depth, state)
	tell application "System Events"
		if depth > 8 then return
		try
			set kids to UI elements of el
		on error
			return
		end try
		repeat with k in kids
			try
				set r to role of k as text
				if r is "AXMenu" then
					repeat with mi in (UI elements of k)
						try
							set n to name of mi as text
							if n is "喜爱" or n is "Favorite" or n is "Favourite" or n is "Love" then
								set item 1 of state to mi
							else if n is "撤销喜爱" or n is "取消喜爱" or n is "Unfavorite" or n is "Unfavourite" or n is "Undo Favorite" then
								set item 2 of state to true
								return
							end if
						end try
					end repeat
					if (item 1 of state) is not missing value then return
				end if
				my findFavoriteItem(k, depth + 1, state)
				if (item 1 of state) is not missing value or (item 2 of state) is true then return
			end try
		end repeat
	end tell
end findFavoriteItem

on slowPathFavorite(titles)
	tell application "System Events"
		tell process "Music"
			if (count of windows) is 0 then return "not_found"
			set win to window 1
		end tell
	end tell

	set moreBtn to missing value
	repeat with attempt from 1 to 2
		set state to {false, missing value}
		my findMoreButton(win, 0, titles, state)
		if (item 2 of state) is not missing value then
			set moreBtn to item 2 of state
			exit repeat
		end if
		delay 0.8
	end repeat
	if moreBtn is missing value then return "not_found"

	repeat with pressAttempt from 1 to 3
		tell application "System Events"
			tell process "Music"
				set frontmost to true
			end tell
			perform action "AXPress" of moreBtn
		end tell
		delay 0.4

		repeat with pollAttempt from 1 to 6
			set menuState to {missing value, false}
			tell application "System Events"
				tell process "Music"
					my findFavoriteItem(it, 0, menuState)
				end tell
			end tell

			if (item 2 of menuState) is true then
				tell application "System Events" to key code 53
				return "already_favorite"
			end if
			if (item 1 of menuState) is not missing value then
				tell application "System Events"
					perform action "AXPress" of (item 1 of menuState)
				end tell
				return "favorited"
			end if
			delay 0.3
		end repeat
	end repeat
	return "menu_not_found"
end slowPathFavorite

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
			set frontmost to true
			if (count of windows) is 0 then return "not_found"
		end tell
	end tell

	-- 页面可能还在加载: 快速路径轮询最多 ~3 秒。
	-- 找到行就直接操作; 找不到则快速返回 not_found，
	-- 由调用方(.command)重开链接重试——Music 页面偶发加载失败，重开比等待有效
	repeat with attempt from 1 to 6
		set r to my fastPathFavorite(titles)
		if r is "favorited" or r is "already_favorite" then return r
		if r is "menu_not_found" then
			-- 找到了行但行内菜单方式失败，用全树递归兜底
			return my slowPathFavorite(titles)
		end if
		delay 0.5
	end repeat

	return "not_found"
end run
