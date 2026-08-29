# 包子漫画

MgRead Node.js 24 single-file conversion of the repository source for
`https://www.baozimh.com`. The upstream entry has no UUID, so the stable domain-derived
descriptor id is `org.mgread.baozimh-com`.

All cover and comic image URLs are exposed through the Runtime resource proxy. The
resource handler permits only Baozimh cover hosts and `*.bzcdn.net` page hosts, and
always sends the source page as Referer.
