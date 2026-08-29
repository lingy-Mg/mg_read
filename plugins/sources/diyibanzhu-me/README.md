# 第一版主

MgRead conversion of repository UUID `diyibanzhu-me` (`https://m.diyibanzhu.me`).

Protected HTML uses the source's single Runtime-owned `ctx.webview` page:

- the page starts hidden, navigates to the source origin once, and is reused;
- GET and POST requests use same-origin `page.fetch`, so browser Cookie and UA remain host-owned;
- rendered verification state is inspected with native `page.getHtml`;
- a detected verification page is shown, waits at most 120 seconds for `第一版主`, then hides and retries once;
- the plugin never reads Cookie, supplies a UA, creates a `sessionKey`, or performs a JavaScript click.
