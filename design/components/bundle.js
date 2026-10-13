/* @ds-bundle: {"format":4,"namespace":"Zimam","components":[{"name":"Button"},{"name":"TaskRow"},{"name":"DateChip"},{"name":"PrayerChip"},{"name":"ProjectCard"},{"name":"KanbanColumn"},{"name":"AISuggestion"}]} */
(function () {
  var React = window.React;
  var h = React.createElement;
  function cx() {
    var out = [];
    for (var i = 0; i < arguments.length; i++) { if (arguments[i]) out.push(arguments[i]); }
    return out.join(' ');
  }
  function num(n) { return Number(n).toLocaleString('ar-SA', { useGrouping: false }); }
  function svg(d, extra) {
    return h('svg', Object.assign({ viewBox: '0 0 16 16', width: 14, height: 14, 'aria-hidden': 'true', className: 'zm-ico' }, extra || {}), d);
  }
  var icons = {
    check: function () { return svg(h('path', { d: 'M3.5 8.5l3 3 6-7', fill: 'none', stroke: 'currentColor', strokeWidth: 2, strokeLinecap: 'round', strokeLinejoin: 'round' })); },
    flag: function () { return svg(h('path', { d: 'M4 14V2.5M4 3h7.5l-1.8 2.75L11.5 8.5H4', fill: 'none', stroke: 'currentColor', strokeWidth: 1.6, strokeLinecap: 'round', strokeLinejoin: 'round' })); },
    calendar: function () { return svg(h(React.Fragment, null, h('rect', { x: 2.5, y: 3.5, width: 11, height: 10, rx: 2, fill: 'none', stroke: 'currentColor', strokeWidth: 1.5 }), h('path', { d: 'M2.5 6.5h11M5.5 2v3M10.5 2v3', stroke: 'currentColor', strokeWidth: 1.5, strokeLinecap: 'round' }))); },
    horizon: function () { return svg(h(React.Fragment, null, h('path', { d: 'M4 10.5a4 4 0 0 1 8 0', fill: 'none', stroke: 'currentColor', strokeWidth: 1.6, strokeLinecap: 'round' }), h('path', { d: 'M2 13h12M8 2.5v2M3.2 5.2l1.2 1.2M12.8 5.2l-1.2 1.2', stroke: 'currentColor', strokeWidth: 1.6, strokeLinecap: 'round' }))); }
  };

  function Button(props) {
    var variant = props.variant || 'primary';
    var rest = Object.assign({}, props);
    delete rest.variant; delete rest.className; delete rest.children;
    return h('button', Object.assign({ type: 'button' }, rest, { className: cx('zm-btn', 'zm-btn-' + variant, props.className) }), props.children);
  }

  function DateChip(props) {
    var tone = props.tone || 'default';
    var parts = [props.hijri, props.gregorian].filter(Boolean).join('، ');
    return h('span', { className: cx('zm-chip', 'zm-chip-date', tone === 'overdue' && 'zm-chip-overdue') },
      icons.calendar(), h('span', null, parts), tone === 'overdue' ? h('span', { className: 'zm-sr' }, ' متأخرة') : null);
  }

  function PrayerChip(props) {
    return h('span', { className: 'zm-chip zm-chip-prayer' }, icons.horizon(), h('span', null, props.children));
  }

  var priorityWords = { high: 'أولوية عالية', medium: 'أولوية متوسطة', low: 'أولوية منخفضة' };
  function PriorityFlag(p) {
    if (!p || !priorityWords[p]) return null;
    return h('span', { className: 'zm-flag zm-flag-' + p, title: priorityWords[p] }, icons.flag(), h('span', { className: 'zm-sr' }, priorityWords[p]));
  }

  function TaskRow(props) {
    var done = !!props.done;
    var meta = [];
    if (props.date) meta.push(h(DateChip, Object.assign({ key: 'd' }, props.date)));
    if (props.prayer) meta.push(h(PrayerChip, { key: 'p' }, props.prayer));
    if (props.project) meta.push(h('span', { key: 'pr', className: 'zm-meta-text' }, props.project));
    return h('div', { className: cx('zm-task', done && 'zm-task-done', props.selected && 'zm-task-selected', props.compact && 'zm-task-compact', props.lifted && 'zm-task-lifted') },
      h('button', { type: 'button', className: cx('zm-check', done && 'zm-check-on'), 'aria-pressed': done ? 'true' : 'false', 'aria-label': done ? 'إلغاء الإنجاز' : 'إنجاز المهمة', onClick: props.onToggle }, done ? icons.check() : null),
      h('div', { className: 'zm-task-body' },
        h('div', { className: 'zm-task-title' }, props.title),
        props.note ? h('div', { className: 'zm-task-note' }, props.note) : null,
        meta.length ? h('div', { className: 'zm-task-meta' }, meta) : null),
      PriorityFlag(props.priority));
  }

  function ProjectCard(props) {
    var total = props.total || 0, doneCount = props.done || 0;
    var pct = total ? Math.round((doneCount / total) * 100) : 0;
    return h('div', { className: cx('zm-card', 'zm-project', props.active && 'zm-project-active') },
      h('div', { className: 'zm-project-head' },
        h('div', { className: 'zm-project-name' }, props.name),
        h('div', { className: 'zm-meta-text' }, num(doneCount) + ' من ' + num(total))),
      props.due ? h('div', { className: 'zm-project-due' }, h(DateChip, props.due)) : null,
      h('div', { className: 'zm-progress', role: 'progressbar', 'aria-valuemin': 0, 'aria-valuemax': 100, 'aria-valuenow': pct, 'aria-label': 'نسبة الإنجاز' },
        h('div', { className: 'zm-progress-fill', style: { inlineSize: pct + '%' } })));
  }

  function KanbanColumn(props) {
    return h('section', { className: 'zm-column', 'aria-label': props.title },
      h('header', { className: 'zm-column-head' },
        h('h3', { className: 'zm-column-title' }, props.title),
        h('span', { className: 'zm-count' }, num(props.count != null ? props.count : React.Children.count(props.children)))),
      h('div', { className: 'zm-column-body' }, props.children),
      props.onAdd ? h('button', { type: 'button', className: 'zm-column-add', onClick: props.onAdd }, 'إضافة مهمة') : null);
  }

  function AISuggestion(props) {
    return h('div', { className: 'zm-ai', role: 'group', 'aria-label': 'اقتراح المساعد' },
      h('div', { className: 'zm-ai-label' }, props.label || 'اقتراح المساعد'),
      h('div', { className: 'zm-ai-text' }, props.children),
      h('div', { className: 'zm-ai-actions' },
        h(Button, { variant: 'primary', onClick: props.onAccept }, props.acceptLabel || 'اعتماد'),
        h(Button, { variant: 'quiet', onClick: props.onDismiss }, props.dismissLabel || 'تجاهل')));
  }

  window.Zimam = Object.assign(window.Zimam || {}, {
    Button: Button,
    TaskRow: TaskRow,
    DateChip: DateChip,
    PrayerChip: PrayerChip,
    ProjectCard: ProjectCard,
    KanbanColumn: KanbanColumn,
    AISuggestion: AISuggestion
  });
})();
