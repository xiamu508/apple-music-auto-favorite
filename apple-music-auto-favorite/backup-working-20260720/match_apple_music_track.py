#!/usr/bin/env python3
import argparse
import concurrent.futures
import difflib
import json
import re
import sys
import unicodedata
import urllib.parse
import urllib.request
from pathlib import Path


VENDOR_DIR = Path(__file__).resolve().parent / "vendor"
if VENDOR_DIR.exists():
    sys.path.insert(0, str(VENDOR_DIR))

try:
    from opencc import OpenCC

    T2S_CONVERTER = OpenCC("t2s")
    S2T_CONVERTER = OpenCC("s2t")
except Exception:
    T2S_CONVERTER = None
    S2T_CONVERTER = None


FALLBACK_T2S = str.maketrans(
    {
        "願": "愿",
        "長": "长",
        "樂": "乐",
        "愛": "爱",
        "夢": "梦",
        "風": "风",
        "雲": "云",
        "語": "语",
        "國": "国",
        "聲": "声",
        "聽": "听",
        "後": "后",
        "臺": "台",
        "與": "与",
        "萬": "万",
        "無": "无",
        "會": "会",
        "點": "点",
        "間": "间",
        "關": "关",
        "開": "开",
        "裡": "里",
        "裏": "里",
    }
)


def to_simplified(text):
    text = text or ""
    if T2S_CONVERTER is not None:
        return T2S_CONVERTER.convert(text)
    return text.translate(FALLBACK_T2S)


def to_traditional(text):
    text = text or ""
    if S2T_CONVERTER is not None:
        return S2T_CONVERTER.convert(text)
    return text


def normalize(text):
    text = to_simplified(text)
    text = unicodedata.normalize("NFKC", text or "").casefold()
    text = re.sub(r"\b(feat|ft|featuring|with)\.?\b.*", "", text)
    text = re.sub(r"[\(\[\{（【].*?[\)\]\}）】]", "", text)
    text = "".join(
        ch
        for ch in unicodedata.normalize("NFD", text)
        if unicodedata.category(ch) != "Mn"
    )
    text = re.sub(r"[^\w\u3400-\u9fff]+", " ", text, flags=re.UNICODE)
    return re.sub(r"\s+", " ", text).strip()


def strip_dash_subtitle(title):
    """去掉 " - 副标题" 尾巴(Spotify 常用)。如 "愿人生 - 电影《逆行人生》推广主题曲" -> "愿人生"。"""
    head = re.split(r"\s+[-–—]\s+", title or "", maxsplit=1)[0].strip()
    return head if head else (title or "")


def ratio(left, right):
    left = normalize(left)
    right = normalize(right)
    if not left or not right:
        return 0.0
    if left == right:
        return 1.0
    if left in right or right in left:
        return min(len(left), len(right)) / max(len(left), len(right))
    return difflib.SequenceMatcher(None, left, right).ratio()


def artist_ratio(wanted, found):
    wanted_norm = normalize(wanted)
    found_norm = normalize(found)
    if not wanted_norm or not found_norm:
        return 0.0
    if wanted_norm == found_norm:
        return 1.0
    if wanted_norm in found_norm or found_norm in wanted_norm:
        return 0.95

    wanted_parts = re.split(r"\s+(?:and|x)\s+|[,/&+、，]|;", wanted_norm)
    found_parts = re.split(r"\s+(?:and|x)\s+|[,/&+、，]|;", found_norm)
    part_scores = [
        difflib.SequenceMatcher(None, w.strip(), f.strip()).ratio()
        for w in wanted_parts
        for f in found_parts
        if w.strip() and f.strip()
    ]
    return max(part_scores, default=0.0)


def fetch_json(params):
    request = urllib.request.Request(
        f"https://itunes.apple.com/search?{urllib.parse.urlencode(params)}",
        headers={"User-Agent": "CodexAppleMusicShortcut/1.0"},
    )
    with urllib.request.urlopen(request, timeout=8) as response:
        return json.load(response)


def fetch_all_parallel(param_list):
    """并行请求所有查询，按提交顺序返回结果(失败的请求返回 None)。"""
    payloads = [None] * len(param_list)
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as pool:
        futures = {pool.submit(fetch_json, params): idx for idx, params in enumerate(param_list)}
        for future in concurrent.futures.as_completed(futures):
            idx = futures[future]
            try:
                payloads[idx] = future.result()
            except Exception:
                payloads[idx] = None
    return payloads


def search(title, artist, countries):
    terms = []
    for title_variant, artist_variant in (
        (title, artist),
        (to_simplified(title), to_simplified(artist)),
        (strip_dash_subtitle(title), artist),
        (to_simplified(strip_dash_subtitle(title)), to_simplified(artist)),
    ):
        term = f"{title_variant} {artist_variant}".strip()
        if term and term not in terms:
            terms.append(term)

    param_list = [
        {
            "term": term,
            "media": "music",
            "entity": "song",
            "limit": "10",
            "country": country,
        }
        for country in countries
        for term in terms
    ]
    payloads = fetch_all_parallel(param_list)
    if all(payload is None for payload in payloads):
        raise RuntimeError("所有国家/地区的搜索请求都失败了")

    seen = set()
    results = []
    for params, payload in zip(param_list, payloads):
        if payload is None:
            continue
        for item in payload.get("results", []):
            track_id = item.get("trackId") or item.get("trackViewUrl")
            if not track_id or track_id in seen:
                continue
            seen.add(track_id)
            item["_country"] = params["country"]
            results.append(item)

    return results


def search_artist_ids(artist, countries):
    terms = []
    for artist_variant in (artist, to_simplified(artist)):
        artist_variant = artist_variant.strip()
        if artist_variant and artist_variant not in terms:
            terms.append(artist_variant)

    param_list = [
        {
            "term": term,
            "media": "music",
            "entity": "musicArtist",
            "limit": "4",
            "country": country,
        }
        for country in countries
        for term in terms
    ]
    payloads = fetch_all_parallel(param_list)

    artist_ids = {}
    for payload in payloads:
        if payload is None:
            continue
        for rank, item in enumerate(payload.get("results", [])):
            artist_id = item.get("artistId")
            if not artist_id:
                continue
            rank_score = max(0.0, 1.0 - rank * 0.08)
            artist_ids[artist_id] = max(artist_ids.get(artist_id, 0.0), rank_score)

    return artist_ids


def score_result(title, artist, item, wanted_artist_ids):
    track_name = item.get("trackName", "")
    # 歌名按两种形态取最高分: 原样、去掉 " - 副标题" 尾巴
    # (Spotify 用 " - " 接副标题，Apple Music 用括号，normalize 只剥括号)
    title_score = ratio(title, track_name)
    stripped = strip_dash_subtitle(title)
    if stripped != title:
        title_score = max(title_score, ratio(stripped, track_name))
    artist_score = artist_ratio(artist, item.get("artistName", ""))
    artist_id_score = 0.0
    artist_id = item.get("artistId")
    if title_score >= 0.95 and artist_id in wanted_artist_ids:
        artist_id_score = wanted_artist_ids[artist_id]
        artist_score = max(artist_score, artist_id_score)

    combined = title_score * 0.62 + artist_score * 0.38
    return {
        "title_score": round(title_score, 4),
        "artist_score": round(artist_score, 4),
        "artist_id_score": round(artist_id_score, 4),
        "score": round(combined, 4),
    }


def music_url(item):
    url = item.get("trackViewUrl", "")
    if url.startswith("https://music.apple.com/"):
        return "music://" + url.removeprefix("https://")
    return url


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--title", required=True)
    parser.add_argument("--artist", default="")
    parser.add_argument("--countries", default="CN,HK,TW,US,JP")
    args = parser.parse_args()

    countries = [country.strip().upper() for country in args.countries.split(",") if country.strip()]
    if not countries:
        countries = ["US"]

    if not args.artist.strip():
        print(
            json.dumps(
                {
                    "status": "manual",
                    "reason": "missing_artist",
                    "message": "没有拿到歌手名，不能安全自动收藏。",
                },
                ensure_ascii=False,
            )
        )
        return 0

    try:
        # 歌曲搜索与歌手ID搜索相互独立，并行执行
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            candidates_future = pool.submit(search, args.title, args.artist, countries)
            artist_ids_future = pool.submit(search_artist_ids, args.artist, countries)
            candidates = candidates_future.result()
            wanted_artist_ids = artist_ids_future.result()
    except Exception as exc:
        print(
            json.dumps(
                {
                    "status": "manual",
                    "reason": "search_failed",
                    "message": f"Apple Music 搜索接口不可用：{exc}",
                },
                ensure_ascii=False,
            )
        )
        return 0

    scored = []
    for item in candidates:
        scores = score_result(args.title, args.artist, item, wanted_artist_ids)
        scored.append((scores["score"], scores, item))

    scored.sort(key=lambda row: row[0], reverse=True)
    if not scored:
        print(
            json.dumps(
                {
                    "status": "manual",
                    "reason": "no_results",
                    "message": "Apple Music 没有返回候选歌曲。",
                },
                ensure_ascii=False,
            )
        )
        return 0

    _, best_scores, best = scored[0]

    def passes(scores):
        return (
            scores["title_score"] >= 0.88
            and scores["artist_score"] >= 0.78
            and scores["score"] >= 0.84
        )

    matched = passes(best_scores)

    # 优先用户所在商店(countries 第一项)的版本:
    # trackId 全球一致且按国家顺序去重，所以最佳匹配若来自其他商店，
    # 说明该曲目在本区商店不存在——尝试找本区的达标替代版本
    home_country = countries[0]
    available_in_home = True
    if matched and best.get("_country") != home_country:
        for _, alt_scores, alt in scored:
            if alt.get("_country") == home_country and passes(alt_scores):
                best, best_scores = alt, alt_scores
                break
        else:
            available_in_home = False

    output = {
        "status": "matched" if matched else "manual",
        "reason": "verified" if matched else "low_confidence",
        "home_country": home_country,
        "available_in_home": available_in_home,
        "query": {"title": args.title, "artist": args.artist},
        "match": {
            "title": best.get("trackName", ""),
            "title_simplified": to_simplified(best.get("trackName", "")),
            "title_traditional": to_traditional(best.get("trackName", "")),
            "artist": best.get("artistName", ""),
            "album": best.get("collectionName", ""),
            "country": best.get("_country", ""),
            "track_id": best.get("trackId"),
            "web_url": best.get("trackViewUrl", ""),
            "music_url": music_url(best),
            **best_scores,
        },
    }
    print(json.dumps(output, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    sys.exit(main())
