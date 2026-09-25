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

          # The grid's Infinite Row Model datasource (`grid_script`'s
          # `getRows`) — one block of rows per call, sorted/filtered
          # server-side by `Web::HistoryQuery`, so the page never ships
          # every retained entry to the browser. Also what live updates
          # re-hit (`refreshInfiniteCache`), for just the blocks on screen.
          app.get('/history/data') do
            status = History::STATUSES.include?(params['status']) ? params['status'] : 'all'
            query = Cogworker::Web::HistoryQuery.new(
              status: status, jid: params['jid'].to_s,
              sort: Routes::History.parse_json_param(params['sort'], []),
              filters: Routes::History.parse_json_param(params['filter'], {})
            )
            start = params['start'].to_i
            rows, total = query.fetch(start, params['end'].to_i - start)
            [200, { 'content-type' => 'application/json' }, [JSON.generate('rows' => rows, 'total' => total)]]
          end
        end

        # A malformed/missing `sort`/`filter` param just means "none" rather
        # than a 500 — it's built by our own script, but still user input.
        def parse_json_param(raw, fallback)
          return fallback if raw.nil? || raw.empty?

          parsed = JSON.parse(raw)
          parsed.is_a?(fallback.class) ? parsed : fallback
        rescue JSON::ParserError
          fallback
        end

        def ag_grid_head(script_name)
          js, grid_css, theme_css = AG_GRID_ASSETS.map { |rel| Layout.path(script_name, "assets/#{rel}") }
          <<~HTML
            <script src="#{js}"></script>
            <link rel="stylesheet" href="#{grid_css}">
            <link rel="stylesheet" href="#{theme_css}">
          HTML
        end

        # Renders just the grid shell — rows are fetched block by block
        # from `GET /history/data` (AG Grid's Infinite Row Model), with
        # sorting, per-column filtering and pagination all done server-side
        # (`Web::HistoryQuery`), so page weight no longer grows with
        # `History.max_entries`.
        #
        # `jid` (optional — empty string means "not filtering") narrows this
        # down to one job's own run history across every retry attempt (a
        # retried job keeps its original jid throughout, so this is exactly
        # "this job's full timeline", unlike the Jobs tab's own Retry
        # history, which only shows its *failures*, capped to the last few —
        # see `Routes::Jobs#attempts_section`, which links here).
        def render_content(script_name, status, jid = '')
          <<~HTML
            <div style="display: flex; flex-direction: column; gap: 16px;">
              #{page_header(script_name, status, jid)}
              #{grid(script_name, status, jid)}
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

        def grid(script_name, status, jid)
          <<~HTML
            <div id="history-grid" class="ag-theme-alpine" style="height: 70vh; width: 100%;"></div>

            <dialog id="history-backtrace-dialog" class="dialog" style="width: min(720px, 90vw);">
              <div style="display: flex; justify-content: space-between; align-items: center;">
                <span class="dialog-title">Backtrace</span>
                <button type="button" onclick="this.closest('dialog').close()" class="btn btn-icon btn-ghost" aria-label="Close">✕</button>
              </div>
              <pre id="history-backtrace-content" class="mono" style="margin: 0; font-size: 12px; line-height: 1.6; white-space: pre-wrap; max-height: 60vh; overflow-y: auto; background: var(--color-bg); border: 1px solid var(--color-divider); border-radius: var(--radius-sm); padding: var(--space-3);"></pre>
            </dialog>

            #{grid_script(script_name, status, jid)}
          HTML
        end

        def grid_script(script_name, status, jid)
          query = "status=#{status}"
          query += "&jid=#{CGI.escape(jid)}" unless jid.empty?
          data_url = Layout.path(script_name, "history/data?#{query}")
          <<~HTML
            <script>
              (function () {
                var dataUrl = #{Layout.json_for_script(data_url)};
                // The dialog leads with the error itself (class + message)
                // and only then the backtrace — the grid's own Error column
                // can be too narrow/truncated to read the full message, and
                // clicking through to "just the backtrace" without it loses
                // the one thing you're usually trying to look up. Takes the
                // row itself (not a jid lookup): every retry attempt of one
                // job shares its jid but has its own backtrace.
                window.cogworkerShowHistoryBacktrace = function (row) {
                  var text = row && row.backtrace
                    ? (row.error_class || 'Error') + ': ' + (row.error_message || '') + '\\n\\n' + row.backtrace.join('\\n')
                    : '(no backtrace)';
                  document.getElementById('history-backtrace-content').textContent = text;
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

                // Infinite Row Model: a row whose block is still loading has
                // no `data` yet — every getter/renderer below guards for it.
                function statusCellRenderer(p) {
                  if (!p.value) return '';
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
                  if (!p.data) return '';
                  return p.data.error_class ? (p.data.error_class + ': ' + p.data.error_message) : '';
                }

                function errorCellRenderer(p) {
                  if (!p.data || !p.data.backtrace) return p.value || '';
                  var span = document.createElement('span');
                  span.textContent = p.value;
                  span.style.color = cssVar('--color-danger-300');
                  span.style.textDecoration = 'underline';
                  span.style.cursor = 'pointer';
                  span.title = 'Click to view backtrace';
                  span.addEventListener('click', function () { window.cogworkerShowHistoryBacktrace(p.data); });
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

                // Sorting/filtering run server-side (`Web::HistoryQuery`,
                // keyed by each column's `colId`), so every `colId` here
                // must match one of its `COLUMNS` — and compute the same
                // value there as `valueGetter`/`valueFormatter` show here.
                // Status has no column filter: the All/Success/Failed
                // switch above already picks which ZSET is read at all.
                var textFilter = { filter: 'agTextColumnFilter', filterParams: { buttons: ['reset'], debounceMs: 400 } };
                var columnDefs = [
                  { colId: 'finished_at', field: 'finished_at', headerName: 'Finished', sort: 'desc', minWidth: 170, filter: false,
                    valueFormatter: function (p) { return p.value == null ? '' : window.cogworkerFormatTime(new Date(p.value * 1000)); } },
                  Object.assign({ colId: 'class', field: 'class', headerName: 'Class' }, textFilter),
                  Object.assign({ colId: 'queue', field: 'queue', headerName: 'Queue' }, textFilter),
                  Object.assign({ colId: 'jid', field: 'jid', headerName: 'JID', minWidth: 160 }, textFilter),
                  Object.assign({ colId: 'args', field: 'args', headerName: 'Args', minWidth: 200,
                    valueFormatter: function (p) { return p.data ? JSON.stringify(p.value) : ''; } }, textFilter),
                  { colId: 'status', field: 'status', headerName: 'Status', cellRenderer: statusCellRenderer, maxWidth: 120, filter: false },
                  { colId: 'duration', headerName: 'Duration', maxWidth: 160,
                    filter: 'agNumberColumnFilter', filterParams: { buttons: ['reset'], debounceMs: 400 },
                    // `valueGetter` stays a plain millisecond Integer (the
                    // same unit the number filter compares against server-
                    // side), `valueFormatter` only changes what's displayed.
                    valueGetter: function (p) { return p.data ? Math.round((p.data.finished_at - p.data.started_at) * 1000) : null; },
                    valueFormatter: function (p) { return p.value == null ? '' : formatDuration(p.value); } },
                  Object.assign({ colId: 'error', headerName: 'Error', minWidth: 260, valueGetter: errorValueGetter,
                    cellRenderer: errorCellRenderer }, textFilter)
                ];

                function blockUrl(params) {
                  return dataUrl +
                    '&start=' + params.startRow + '&end=' + params.endRow +
                    '&sort=' + encodeURIComponent(JSON.stringify(params.sortModel || [])) +
                    '&filter=' + encodeURIComponent(JSON.stringify(params.filterModel || {}));
                }

                var datasource = {
                  getRows: function (params) {
                    fetch(blockUrl(params), { headers: { 'Accept': 'application/json' } })
                      .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
                      .then(function (data) { params.successCallback(data.rows, data.total); })
                      .catch(function () { params.failCallback(); });
                  }
                };

                var gridApi = agGrid.createGrid(document.getElementById('history-grid'), {
                  columnDefs: columnDefs,
                  rowModelType: 'infinite',
                  datasource: datasource,
                  // One block == one page, and only that one block cached:
                  // `refreshInfiniteCache()` (the live poll below) re-fetches
                  // *every* cached block, so a bigger cache meant one extra
                  // request per page visited on every tick. Paging back to an
                  // earlier page costs a fresh request instead — fine, and
                  // it's fresher anyway.
                  cacheBlockSize: #{Cogworker::Web.history_per_page},
                  maxBlocksInCache: 1,
                  defaultColDef: { sortable: true, resizable: true, flex: 1 },
                  pagination: true,
                  paginationPageSize: #{Cogworker::Web.history_per_page},
                  paginationPageSizeSelector: [10, 25, 50, 100],
                  // Keeps block size == page size when the viewer picks a
                  // different page size — otherwise one page would span
                  // several blocks, more than the 1-block cache holds.
                  onPaginationChanged: function (e) {
                    if (!e.newPageSize) return;
                    var size = e.api.paginationGetPageSize();
                    if (e.api.getGridOption('cacheBlockSize') !== size) e.api.setGridOption('cacheBlockSize', size);
                  }
                });

                if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {
                  document.getElementById('history-grid').classList.add('ag-theme-alpine-dark');
                }

                // AG Grid isn't htmx-swapped (unlike Workers/Stats/Overview), so
                // it needs its own poll — gated by the same global toggle —
                // that re-fetches just the cached blocks in place (current
                // sort/filter/page kept) rather than reloading the fragment
                // and tearing the grid instance down.
                function refreshRows() {
                  if (!window.cogworkerLiveUpdate) return;
                  gridApi.refreshInfiniteCache();
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
