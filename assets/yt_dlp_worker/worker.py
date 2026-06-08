import json
import logging
import sys
import traceback
import warnings
from collections import OrderedDict

from yt_dlp import YoutubeDL


PROTOCOL_STDOUT = sys.stdout
sys.stdout = sys.stderr


def _write_response(payload):
    PROTOCOL_STDOUT.write(json.dumps(payload, ensure_ascii=True) + "\n")
    PROTOCOL_STDOUT.flush()


def _warning_to_stderr(
    message, category, filename, lineno, file=None, line=None
):
    sys.stderr.write(
        warnings.formatwarning(message, category, filename, lineno, line)
    )
    sys.stderr.flush()


warnings.showwarning = _warning_to_stderr
logging.basicConfig(stream=sys.stderr, level=logging.ERROR)

BASE_OPTS = {
    "skip_download": True,
    "quiet": True,
    "no_warnings": True,
    "ignoreerrors": True,
    "nocheckcertificate": True,
    "cachedir": False,
}
SEARCH_CACHE_LIMIT = 200
VIDEO_CACHE_LIMIT = 200
_search_cache = OrderedDict()
_video_cache = OrderedDict()


def _cache_get(cache, key):
    if key not in cache:
        return None
    value = cache.pop(key)
    cache[key] = value
    return value


def _cache_set(cache, key, value, limit):
    if key in cache:
        cache.pop(key)
    cache[key] = value
    while len(cache) > limit:
        cache.popitem(last=False)


def _make_ydl(extra=None):
    opts = dict(BASE_OPTS)
    if extra:
        opts.update(extra)
    return YoutubeDL(opts)


def _video_payload(info):
    upload_date = info.get("upload_date") or ""
    return {
        "id": info.get("id", ""),
        "title": info.get("title", ""),
        "channel": info.get("channel") or info.get("uploader") or "",
        "channel_id": info.get("channel_id") or info.get("uploader_id") or "",
        "upload_date": upload_date,
        "description": info.get("description") or "",
        "duration": int(info.get("duration") or 0),
        "tags": info.get("tags") or [],
        "view_count": info.get("view_count"),
        "like_count": info.get("like_count"),
        "is_live": bool(info.get("is_live") or False),
    }


def _extract_video_info(video_id):
    cached = _cache_get(_video_cache, video_id)
    if cached is not None:
        return cached

    info = _make_ydl().extract_info(
        f"https://www.youtube.com/watch?v={video_id}",
        download=False,
    )
    if not isinstance(info, dict):
        raise RuntimeError("yt-dlp returned no video info")

    payload = _video_payload(info)
    _cache_set(_video_cache, video_id, payload, VIDEO_CACHE_LIMIT)
    return payload


def _extract_video_with_stream_info(video_id):
    info = _make_ydl().extract_info(
        f"https://www.youtube.com/watch?v={video_id}",
        download=False,
    )
    if not isinstance(info, dict):
        raise RuntimeError("yt-dlp returned no video info")

    return {
        "video": _video_payload(info),
        "formats": info.get("formats") or [],
    }


def _extract_stream_manifest(video_id):
    info = _make_ydl().extract_info(
        f"https://www.youtube.com/watch?v={video_id}",
        download=False,
    )
    if not isinstance(info, dict):
        raise RuntimeError("yt-dlp returned no video info")

    return info.get("formats") or []


def _search_videos(query, count):
    cache_key = f"{count}:{query.strip().lower()}"
    cached = _cache_get(_search_cache, cache_key)
    if cached is not None:
        return cached

    info = _make_ydl(
        {
            "extract_flat": "in_playlist",
            "playlistend": count,
            "noplaylist": True,
        }
    ).extract_info(f"ytsearch{count}:{query}", download=False)
    entries = []
    if isinstance(info, dict):
        entries = info.get("entries") or []

    payload = [
        _video_payload(item)
        for item in entries
        if isinstance(item, dict)
    ]
    _cache_set(_search_cache, cache_key, payload, SEARCH_CACHE_LIMIT)
    return payload


def _handle_request(method, params):
    if method == "ping":
        return {"status": "ok"}
    if method == "shutdown":
        return {"status": "bye"}
    if method == "get_stream_manifest":
        return _extract_stream_manifest(params["videoId"])
    if method == "get_video":
        return _extract_video_info(params["videoId"])
    if method == "get_video_with_stream_info":
        return _extract_video_with_stream_info(params["videoId"])
    if method == "search_videos":
        return _search_videos(params["query"], int(params["count"]))
    raise RuntimeError(f"Unknown method: {method}")


def main():
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue

        request_id = None
        method = None
        try:
            payload = json.loads(line)
            request_id = payload.get("id")
            method = payload.get("method")
            params = payload.get("params") or {}
            result = _handle_request(method, params)
            _write_response(
                {
                    "id": request_id,
                    "ok": True,
                    "result": result,
                }
            )
            if method == "shutdown":
                return
        except Exception as exc:
            traceback.print_exc(file=sys.stderr)
            sys.stderr.flush()
            _write_response(
                {
                    "id": request_id,
                    "ok": False,
                    "error": str(exc),
                    "errorType": exc.__class__.__name__,
                    "method": method,
                }
            )


if __name__ == "__main__":
    main()
