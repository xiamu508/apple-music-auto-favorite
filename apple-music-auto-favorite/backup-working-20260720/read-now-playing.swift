// read-now-playing.swift
// 读取本机系统级"正在播放"(Now Playing)信息，覆盖任意来源:
//   Music / Spotify / 网易云音乐 / QQ音乐 等原生 App，以及
//   Safari / Chrome / Edge 等浏览器里的网页播放(YouTube/B站/网页版音乐…)。
//
// 原理: 这些 App/网页都会把当前曲目上报给 macOS 的 Now Playing 系统
// (即控制中心里那块播放控件)。这里通过公开可 dlopen 的 MediaRemote
// 框架直接读取，无需截屏、无需辅助功能、无需私有头文件。
//
// 输出(与 read-now-playing.applescript 保持一致的三行契约):
//   第 1 行: 来源 App 名(读不到时为 "NowPlaying")
//   第 2 行: 歌名
//   第 3 行: 歌手
// 读不到正在播放的曲目时输出空(退出码 0)，由调用方回退到 AppleScript 读取。

import Foundation
import AppKit

let frameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
    // 框架不可用(理论上不会发生): 静默退出，让调用方回退
    exit(0)
}

typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
typealias GetPIDFn = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void

guard let infoSym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else {
    exit(0)
}
let getNowPlayingInfo = unsafeBitCast(infoSym, to: GetInfoFn.self)

// 读取曲目信息
var title = ""
var artist = ""
let infoSem = DispatchSemaphore(value: 0)
getNowPlayingInfo(DispatchQueue.global()) { info in
    title = (info["kMRMediaRemoteNowPlayingInfoTitle"] as? String) ?? ""
    artist = (info["kMRMediaRemoteNowPlayingInfoArtist"] as? String) ?? ""
    infoSem.signal()
}
_ = infoSem.wait(timeout: .now() + 2)

let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
if trimmedTitle.isEmpty {
    // 系统当前没有可读的正在播放曲目，交给调用方回退
    exit(0)
}

// 读取来源 App 名(可选，读不到不影响主流程)
var sourceName = "NowPlaying"
if let pidSym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID") {
    let getPID = unsafeBitCast(pidSym, to: GetPIDFn.self)
    let pidSem = DispatchSemaphore(value: 0)
    getPID(DispatchQueue.global()) { pid in
        if pid > 0, let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName, !name.isEmpty {
            sourceName = name
        }
        pidSem.signal()
    }
    _ = pidSem.wait(timeout: .now() + 1)
}

let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
print(sourceName)
print(trimmedTitle)
print(trimmedArtist)
