/**
 * Public category page boundaries, without I/O or host layout decisions.
 * The first module-main/tab-list owns today's updates, hot ranking or new films;
 * later panels must not leak into that category. The weekly page owns seven
 * separate weekday panels, including hidden days and legitimately empty days.
 */
export function categoryPanels(html: string, id: string, title: string) {
  const panels = modulePanels(html);
  if (id !== 'week') {
    if (panels[0] === undefined) throw new Error('Category listing is unavailable.');
    return [{ id, title, html: panels[0] }];
  }
  const days = [...html.matchAll(/<span\b[^>]*\bdata-dropdown-value=["'](周[一二三四五六日])["'][^>]*>/gu)]
    .map(match => match[1]!);
  if (days.length !== 7 || new Set(days).size !== 7 || panels.length !== 7) {
    throw new Error('Weekly schedule is unavailable.');
  }
  return panels.map((body, index) => ({ id: `week:${index + 1}`, title: days[index]!, html: body }));
}

function modulePanels(html: string): string[] {
  const panels: string[] = [];
  let start = -1;
  let depth = 0;
  for (const match of html.matchAll(/<\/?div\b[^>]*>/giu)) {
    if (/^<\//u.test(match[0])) {
      if (start >= 0 && --depth === 0) {
        panels.push(html.slice(start, match.index));
        start = -1;
      }
    } else if (start >= 0) {
      depth += 1;
    } else {
      const classes = /\bclass=["']([^"']*)["']/iu.exec(match[0])?.[1]?.split(/\s+/u) ?? [];
      if (classes.includes('module-main') && classes.includes('tab-list')) {
        start = match.index + match[0].length;
        depth = 1;
      }
    }
  }
  return panels;
}
