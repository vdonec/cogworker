# frozen_string_literal: true

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
            content = Routes::History.render_content(request.script_name, status)
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
            entries, = Cogworker::History::Storage.page(status, 1, Cogworker::History.max_entries)
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
        def render_content(script_name, status)
          entries, = Cogworker::History::Storage.page(status, 1, Cogworker::History.max_entries)
          filters(script_name, status) + grid(entries, script_name, status)
        end

        def filters(script_name, current_status)
          links = STATUSES.map { |status| filter_link(script_name, status, active: status == current_status) }.join
          %(<div class="mb-4 flex gap-2">#{links}</div>)
        end

        def filter_link(script_name, status, active:)
          classes = if active
                      'bg-indigo-600 text-white'
                    else
                      'bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700'
                    end
          href = Layout.path(script_name, "history?status=#{status}")
          %(<a href="#{href}" class="px-3 py-1 rounded-md text-sm font-medium #{classes}">#{Layout.h(status.capitalize)}</a>)
        end

        def grid(entries, script_name, status)
          <<~HTML
            <div id="history-grid" class="ag-theme-alpine" style="height: 70vh; width: 100%;"></div>

            <dialog id="history-backtrace-dialog" class="rounded-lg p-0 max-w-2xl w-[90vw] bg-white dark:bg-gray-900 text-gray-900 dark:text-gray-100">
              <div class="p-4">
                <div class="flex justify-between items-center mb-3">
                  <h3 class="font-semibold">Backtrace</h3>
                  <button type="button" onclick="this.closest('dialog').close()"
                          class="text-gray-400 hover:text-gray-600 dark:hover:text-gray-200">✕</button>
                </div>
                <pre id="history-backtrace-content" class="text-xs whitespace-pre-wrap max-h-[60vh] overflow-y-auto bg-gray-50 dark:bg-gray-950 p-3 rounded border border-gray-200 dark:border-gray-800"></pre>
              </div>
            </dialog>

            #{grid_script(entries, script_name, status)}
          HTML
        end

        def grid_script(entries, script_name, status)
          data_url = Layout.path(script_name, "history/data?status=#{status}")
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

                function statusCellRenderer(p) {
                  var ok = p.value === 'success';
                  var classes = ok
                    ? 'bg-green-100 text-green-800 dark:bg-green-900/40 dark:text-green-300'
                    : 'bg-red-100 text-red-800 dark:bg-red-900/40 dark:text-red-300';
                  return '<span class="px-2 py-0.5 rounded-full text-xs font-medium ' + classes + '">' + p.value + '</span>';
                }

                function errorValueGetter(p) {
                  return p.data.error_class ? (p.data.error_class + ': ' + p.data.error_message) : '';
                }

                function errorCellRenderer(p) {
                  if (!p.data.backtrace) return p.value || '';
                  var span = document.createElement('span');
                  span.textContent = p.value;
                  span.className = 'text-red-700 dark:text-red-400 underline cursor-pointer';
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

                // AG Grid isn't htmx-swapped (unlike Busy/Stats/Queues), so
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
