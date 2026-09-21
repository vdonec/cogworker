# frozen_string_literal: true

require 'cgi'
require 'json'

module Cogworker
  class Web
    module Routes
      # NOTE: always spelled `Cogworker::History::*` below, fully
      # qualified — a bare `History::Storage` from in here would resolve
      # (via lexical nesting) to *this* module first, which has no
      # `Storage`, not to the top-level `Cogworker::History`.
      module History
        STATUSES = %w[all success failed].freeze
        # Vendored under assets/ag-grid/ (pinned to Community v32.3.9 — see
        # CLAUDE.md) rather than fetched from jsdelivr, so this tab works
        # fully offline like the rest of the Web UI.
        AG_GRID_ASSETS = %w[ag-grid/ag-grid-community.min.js ag-grid/ag-grid.min.css
                            ag-grid/ag-theme-alpine.min.css].freeze

        module_function

        def registered(app)
          app.get('/history') do
            status = History::STATUSES.include?(params['status']) ? params['status'] : 'all'
            jid = params['jid'].to_s
            content = Routes::History.render_content(request.script_name, status, jid)
            if hx_request?
              content
            else
              Layout.wrap('History', content, script_name: request.script_name,
                                              extra_head: Routes::History.ag_grid_head(request.script_name))
            end
          end

          # Polled from the browser (see `grid_script`'s `refreshRows`) to
          # keep the grid live without a full-page/htmx fragment reload,
          # which would tear down and rebuild the AG Grid instance (and lose
          # its sort/filter/scroll state) on every tick.
          app.get('/history/data') do
            status = History::STATUSES.include?(params['status']) ? params['status'] : 'all'
            jid = params['jid'].to_s
            entries, = Cogworker::History::Storage.page(status, 1, Cogworker::History.max_entries)
            entries = entries.select { |e| e['jid'] == jid } unless jid.empty?
            [200, { 'content-type' => 'application/json' }, [JSON.generate(entries)]]
          end
        end

        def ag_grid_head(script_name)
          js, grid_css, theme_css = AG_GRID_ASSETS.map { |rel| Layout.path(script_name, "assets/#{rel}") }
          <<~HTML
            <script src="#{js}"></script>
            <link rel="stylesheet" href="#{grid_css}">
            <link rel="stylesheet" href="#{theme_css}">
          HTML
        end

        # Loads up to `Cogworker::History.max_entries` rows for the chosen
        # filter in one shot and hands them to AG Grid, which does its own
        # client-side sorting/per-column filtering/quick-search/pagination
        # from there — retention (`max_entries`) already bounds this to a
        # size AG Grid handles comfortably, so there's no need for the
        # gem's own server-side paging on top of it.
        #
        # `jid` (optional — empty string means "not filtering") narrows this
        # down to one job's own run history across every retry attempt (a
        # retried job keeps its original jid throughout, so this is exactly
        # "this job's full timeline", unlike the Jobs tab's own Retry
        # history, which only shows its *failures*, capped to the last few —
        # see `Routes::Jobs#attempts_section`, which links here).
        def render_content(script_name, status, jid = '')
          entries, = Cogworker::History::Storage.page(status, 1, Cogworker::History.max_entries)
          entries = entries.select { |e| e['jid'] == jid } unless jid.empty?
          <<~HTML
            <div style="display: flex; flex-direction: column; gap: 16px;">
              #{page_header(script_name, status, jid)}
              #{grid(entries, script_name, status, jid)}
            </div>
          HTML
        end

        def page_header(script_name, current_status, jid)
          links = STATUSES.map { |status| filter_link(script_name, status, jid, active: status == current_status) }.join
          <<~HTML
            <div style="display: flex; align-items: flex-end; justify-content: space-between; gap: 16px; flex-wrap: wrap;">
              <h2 style="margin: 0;">History</h2>
              <div class="seg">#{links}</div>
            </div>
            #{jid.empty? ? '' : jid_filter_banner(script_name, current_status, jid)}
          HTML
        end

        def filter_link(script_name, status, jid, active:)
          query = "status=#{status}"
          query += "&jid=#{CGI.escape(jid)}" unless jid.empty?
          href = Layout.path(script_name, "history?#{query}")
          %(<label class="seg-opt"><input type="radio" name="status" #{'checked' if active} onchange="location.href='#{href}'">#{Layout.h(status.capitalize)}</label>)
        end

        # Shown alongside the status filter whenever a `?jid=` narrowed the
        # grid down to one job — otherwise there'd be no indication *why*
        # the grid suddenly has far fewer rows, and no way back to the
        # unfiltered view short of hand-editing the URL.
        def jid_filter_banner(script_name, status, jid)
          clear_href = Layout.path(script_name, "history?status=#{status}")
          <<~HTML
            <div style="display: flex; align-items: center; gap: 8px; font-size: 13px; color: var(--color-neutral-400);">
              <span>Filtered to job <span class="mono">#{Layout.h(jid)}</span></span>
              <a href="#{clear_href}" class="btn btn-secondary" style="font-size: 12px; padding: 3px 8px;">clear</a>
            </div>
          HTML
        end

        def grid(entries, script_name, status, jid)
          <<~HTML
            <div id="history-grid" class="ag-theme-alpine" style="height: 70vh; width: 100%;"></div>

            <dialog id="history-backtrace-dialog" class="dialog" style="width: min(720px, 90vw);">
              <div style="display: flex; justify-content: space-between; align-items: center;">
                <span class="dialog-title">Backtrace</span>
                <button type="button" onclick="this.closest('dialog').close()" class="btn btn-icon btn-ghost" aria-label="Close">✕</button>
              </div>
              <pre id="history-backtrace-content" class="mono" style="margin: 0; font-size: 12px; line-height: 1.6; white-space: pre-wrap; max-height: 60vh; overflow-y: auto; background: var(--color-bg); border: 1px solid var(--color-divider); border-radius: var(--radius-sm); padding: var(--space-3);"></pre>
            </dialog>

            #{grid_script(entries, script_name, status, jid)}
          HTML
        end

        def grid_script(entries, script_name, status, jid)
          query = "status=#{status}"
          query += "&jid=#{CGI.escape(jid)}" unless jid.empty?
          data_url = Layout.path(script_name, "history/data?#{query}")
          <<~HTML
            <script>
              (function () {
                var dataUrl = #{Layout.json_for_script(data_url)};
                var rowData = #{Layout.json_for_script(entries)};
                var backtraces = {};
                // The dialog leads with the error itself (class + message)
                // and only then the backtrace — the grid's own Error column
                // can be too narrow/truncated to read the full message, and
                // clicking through to "just the backtrace" without it loses
                // the one thing you're usually trying to look up.
                function indexBacktraces() {
                  backtraces = {};
                  rowData.forEach(function (row) {
                    if (!row.backtrace) return;
                    var header = (row.error_class || 'Error') + ': ' + (row.error_message || '');
                    backtraces[row.jid] = header + '\\n\\n' + row.backtrace.join('\\n');
                  });
                }
                indexBacktraces();

                window.cogworkerShowHistoryBacktrace = function (jid) {
                  document.getElementById('history-backtrace-content').textContent = backtraces[jid] || '(no backtrace)';
                  document.getElementById('history-backtrace-dialog').showModal();
                };

                // Reads the actual nocturne tokens at render time (not a
                // hardcoded hex) so this stays in sync with a retuned ramp,
                // and resolves correctly whichever of the dark/light
                // `@media` blocks in styles.css is currently active —
                // matching the same `.tag`/`.tag-success`/`.tag-danger`
                // look used everywhere else, since AG Grid's own
                // cellRenderer can't just apply those CSS classes to cells
                // it builds from a plain string/DOM node.
                var cssVar = function (name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); };

                function statusCellRenderer(p) {
                  var ok = p.value === 'success';
                  var bg = cssVar(ok ? '--color-success-800' : '--color-danger-800');
                  var fg = cssVar(ok ? '--color-success-100' : '--color-danger-100');
                  // `line-height: 1` resets AG Grid's own row-height-driven
                  // `.ag-cell { line-height: <rowHeight>px; }` (inherited
                  // here since this span never set its own) — without it,
                  // the plain text content's line box takes on the full
                  // row height (e.g. 41px) before padding is even added,
                  // ballooning the pill well past the cell's own height and
                  // getting top/bottom-clipped by the cell's `overflow:
                  // hidden`, which also clips away its rounded corners.
                  return '<span style="display:inline-flex;align-items:center;font-size:11px;letter-spacing:0.02em;' +
                    'line-height:1;padding:3px 10px;border-radius:6px;background:' + bg + ';color:' + fg + ';">' +
                    p.value + '</span>';
                }

                function errorValueGetter(p) {
                  return p.data.error_class ? (p.data.error_class + ': ' + p.data.error_message) : '';
                }

                function errorCellRenderer(p) {
                  if (!p.data.backtrace) return p.value || '';
                  var span = document.createElement('span');
                  span.textContent = p.value;
                  span.style.color = cssVar('--color-danger-300');
                  span.style.textDecoration = 'underline';
                  span.style.cursor = 'pointer';
                  span.title = 'Click to view backtrace';
                  span.addEventListener('click', function () { window.cogworkerShowHistoryBacktrace(p.data.jid); });
                  return span;
                }

                // "2h 34m 23s 23ms" — each unit above the smallest one
                // present only shows up once it (or a bigger one) is
                // non-zero, so a typical sub-second job just reads "23ms"
                // rather than "0h 0m 0s 23ms".
                function formatDuration(ms) {
                  ms = Math.max(0, Math.round(ms));
                  var h = Math.floor(ms / 3600000);
                  var m = Math.floor((ms % 3600000) / 60000);
                  var s = Math.floor((ms % 60000) / 1000);
                  var msRemainder = ms % 1000;
                  var parts = [];
                  if (h > 0) parts.push(h + 'h');
                  if (h > 0 || m > 0) parts.push(m + 'm');
                  if (h > 0 || m > 0 || s > 0) parts.push(s + 's');
                  parts.push(msRemainder + 'ms');
                  return parts.join(' ');
                }

                var columnDefs = [
                  { field: 'finished_at', headerName: 'Finished', sort: 'desc', minWidth: 170,
                    valueFormatter: function (p) { return window.cogworkerFormatTime(new Date(p.value * 1000)); } },
                  { field: 'class', headerName: 'Class' },
                  { field: 'queue', headerName: 'Queue' },
                  { field: 'jid', headerName: 'JID', minWidth: 160 },
                  { field: 'args', headerName: 'Args', minWidth: 200,
                    valueFormatter: function (p) { return JSON.stringify(p.value); } },
                  { field: 'status', headerName: 'Status', cellRenderer: statusCellRenderer, maxWidth: 120 },
                  { headerName: 'Duration', maxWidth: 160,
                    // `valueGetter` stays a plain millisecond Integer — AG
                    // Grid sorts/filters on that raw value, `valueFormatter`
                    // only changes what's *displayed*, so numeric sort order
                    // ("23ms" before "1m 5s") stays correct regardless of
                    // formatting.
                    valueGetter: function (p) { return Math.round((p.data.finished_at - p.data.started_at) * 1000); },
                    valueFormatter: function (p) { return formatDuration(p.value); } },
                  { headerName: 'Error', minWidth: 260, valueGetter: errorValueGetter, cellRenderer: errorCellRenderer }
                ];

                var gridApi = agGrid.createGrid(document.getElementById('history-grid'), {
                  columnDefs: columnDefs,
                  rowData: rowData,
                  defaultColDef: { sortable: true, filter: true, resizable: true, flex: 1 },
                  pagination: true,
                  paginationPageSize: #{Cogworker::Web.history_per_page},
                  paginationPageSizeSelector: [10, 25, 50, 100]
                });

                if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {
                  document.getElementById('history-grid').classList.add('ag-theme-alpine-dark');
                }

                // AG Grid isn't htmx-swapped (unlike Workers/Stats/Overview), so
                // it needs its own poll — gated by the same global toggle —
                // that replaces just `rowData` in place rather than
                // reloading the fragment and tearing the grid instance down.
                function refreshRows() {
                  if (!window.cogworkerLiveUpdate) return;
                  fetch(dataUrl, { headers: { 'Accept': 'application/json' } })
                    .then(function (r) { return r.ok ? r.json() : null; })
                    .then(function (data) {
                      if (!data) return;
                      rowData = data;
                      indexBacktraces();
                      gridApi.setGridOption('rowData', rowData);
                    })
                    .catch(function () {});
                }
                setInterval(refreshRows, #{Cogworker::Web.live_update_interval * 1000});
              })();
            </script>
          HTML
        end
      end
    end
  end
end

Cogworker::Web.register(Cogworker::Web::Routes::History)
