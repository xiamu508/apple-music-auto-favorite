-- 读取本机正在播放的歌曲信息
-- 输出三行: 来源App / 歌名 / 歌手
-- 优先级: Music播放中 > Spotify播放中 > Music暂停 > Spotify暂停

on musicInfo(requiredState)
	tell application "System Events"
		if not (exists process "Music") then return ""
	end tell
	tell application "Music"
		try
			set playerStateText to player state as text
			if playerStateText is requiredState then
				return "Music" & linefeed & (name of current track) & linefeed & (artist of current track)
			end if
		end try
	end tell
	return ""
end musicInfo

on spotifyInfo(requiredState)
	tell application "System Events"
		if not (exists process "Spotify") then return ""
	end tell
	tell application "Spotify"
		try
			set playerStateText to player state as text
			if playerStateText is requiredState then
				return "Spotify" & linefeed & (name of current track) & linefeed & (artist of current track)
			end if
		end try
	end tell
	return ""
end spotifyInfo

on run
	set result_ to my musicInfo("playing")
	if result_ is not "" then return result_
	set result_ to my spotifyInfo("playing")
	if result_ is not "" then return result_
	set result_ to my musicInfo("paused")
	if result_ is not "" then return result_
	set result_ to my spotifyInfo("paused")
	if result_ is not "" then return result_
	return ""
end run
