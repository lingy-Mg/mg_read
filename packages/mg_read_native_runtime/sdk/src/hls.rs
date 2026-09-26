//! HLS URL projection follows the Node runtime's playlist/key/media distinction.
//! It preserves non-URI attributes (including byte ranges and IVs), and resolves
//! relative references against the final upstream URL after redirects.
use crate::error::{Result, invalid};
use reqwest::Url;

pub fn rewrite(
    text: &str,
    base: &Url,
    mut proxy: impl FnMut(&str, &str, &str) -> Result<String>,
) -> Result<String> {
    if !text.trim_start_matches('\u{feff}').starts_with("#EXTM3U") {
        return Err(invalid("Invalid HLS playlist"));
    }
    let text = text.trim_start_matches('\u{feff}');
    let mut next_playlist = false;
    let mut lines = Vec::new();
    for line in text.lines() {
        if line.is_empty() {
            lines.push(String::new());
            continue;
        }
        if !line.starts_with('#') {
            let url = base.join(line).map_err(|_| invalid("Invalid HLS URI"))?;
            let playlist = next_playlist || url.path().to_lowercase().ends_with(".m3u8");
            lines.push(proxy(
                url.as_str(),
                if playlist { "hls" } else { "video" },
                if playlist { "hlsPlaylist" } else { "hlsMedia" },
            )?);
            next_playlist = false;
            continue;
        }
        let tag = line.split(':').next().unwrap_or(line);
        if tag == "#EXT-X-STREAM-INF" {
            next_playlist = true;
        }
        let playlist = [
            "#EXT-X-MEDIA",
            "#EXT-X-I-FRAME-STREAM-INF",
            "#EXT-X-RENDITION-REPORT",
        ]
        .contains(&tag);
        let key = ["#EXT-X-KEY", "#EXT-X-SESSION-KEY"].contains(&tag);
        let mut output = String::new();
        let mut tail = line;
        while let Some(start) = tail.find("URI=\"") {
            output.push_str(&tail[..start + 5]);
            tail = &tail[start + 5..];
            let end = tail
                .find('"')
                .ok_or_else(|| invalid("Invalid HLS URI attribute"))?;
            let url = base
                .join(&tail[..end])
                .map_err(|_| invalid("Invalid HLS URI"))?;
            output.push_str(&proxy(
                url.as_str(),
                if playlist { "hls" } else { "video" },
                if playlist {
                    "hlsPlaylist"
                } else if key {
                    "hlsKey"
                } else {
                    "hlsMedia"
                },
            )?);
            output.push('"');
            tail = &tail[end + 1..];
        }
        output.push_str(tail);
        lines.push(output);
    }
    Ok(lines.join("\n"))
}
