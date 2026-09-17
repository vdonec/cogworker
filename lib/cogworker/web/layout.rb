# frozen_string_literal: true

require 'cgi'
require 'json'

module Cogworker
  class Web
    # Tiny shared page chrome for the built-in tabs — not part of the
    # extension contract (an extension is free to build its own HTML, or
    # use `erb`/`Views` the same way these do).
    module Layout
      BUILT_IN_TABS = { 'Queues' => 'queues', 'Busy' => 'busy', 'Retries' => 'retries',
                        'Scheduled' => 'scheduled', 'Periodic' => 'periodic', 'Dead' => 'dead',
                        'History' => 'history', 'Stats' => 'stats' }.freeze
      # Vendored under lib/cogworker/web/assets/ (served locally by
      # `Rack::Static`, wired up in `Web.build_app`) rather than fetched
      # from a CDN, so the Web UI works fully offline. `TAILWIND_HREF`
      # points at a pre-built, purged stylesheet (via the Tailwind CLI
      # against this app's own template files) rather than the Play CDN's
      # in-browser JIT script, since that script itself requires network
      # access to run at all.
      HTMX_SRC = 'assets/htmx.min.js'
      TAILWIND_HREF = 'assets/tailwind.css'

      BUTTON_VARIANTS = {
        default: 'bg-gray-100 text-gray-700 hover:bg-gray-200 dark:bg-gray-700 dark:text-gray-200 dark:hover:bg-gray-600',
        primary: 'bg-indigo-600 text-white hover:bg-indigo-500',
        warning: 'bg-amber-100 text-amber-800 hover:bg-amber-200 dark:bg-amber-900/40 dark:text-amber-300 dark:hover:bg-amber-900/70',
        danger: 'bg-red-50 text-red-700 hover:bg-red-100 dark:bg-red-900/30 dark:text-red-300 dark:hover:bg-red-900/60'
      }.freeze

      BADGE_VARIANTS = {
        success: 'bg-green-100 text-green-800 dark:bg-green-900/40 dark:text-green-300',
        warning: 'bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-300',
        danger: 'bg-red-100 text-red-800 dark:bg-red-900/40 dark:text-red-300',
        default: 'bg-gray-100 text-gray-700 dark:bg-gray-700 dark:text-gray-200'
      }.freeze

      # Shared with `Routes::Stats::CARD_ACCENTS` (its big card grid on the
      # actual Stats tab) — a single source of truth for which color each of
      # the 6 job counters gets, whether rendered as a big card there or as
      # a compact chip in `stats_bar` everywhere else.
      JOB_STAT_ACCENTS = {
        'Enqueued' => 'text-indigo-600 dark:text-indigo-400', 'Processed' => 'text-green-600 dark:text-green-400',
        'Failed' => 'text-red-600 dark:text-red-400', 'Retries' => 'text-amber-600 dark:text-amber-400',
        'Scheduled' => 'text-sky-600 dark:text-sky-400', 'Dead' => 'text-gray-500 dark:text-gray-400'
      }.freeze

      module_function

      # Wraps `inner` in a self-polling container: htmx re-fetches `path`
      # every `interval` and swaps the response into this same element's
      # innerHTML. The route behind `path` only needs to answer both "full
      # page" (a normal GET) and "just this fragment" (`Action#hx_request?`
      # true) — see e.g. Routes::Busy.
      # The `[window.cogworkerLiveUpdate]` event filter (htmx polling
      # syntax) makes every self-polling tab respect the global live-update
      # toggle (see `live_update_script`/`live_toggle_button` below) without
      # each route needing to know about it. `interval` defaults to the
      # shared, config-driven `Cogworker::Web.live_update_interval` (an
      # extension can still pass its own literal, e.g. `'10s'`, if it wants
      # a different cadence than the built-in tabs).
      def poll_div(id, script_name, relative_path, inner, interval: "#{Web.live_update_interval}s")
        %(<div id="#{id}" hx-get="#{path(script_name,
                                         relative_path)}" hx-trigger="every #{interval} [window.cogworkerLiveUpdate]" hx-swap="innerHTML">#{inner}</div>)
      end

      # Every generated link/form action must be prefixed with the app's
      # current mount point (`request.script_name` — e.g. `/cogworker` when
      # mounted via `map('/cogworker') { run Cogworker::Web }`), not written
      # as a bare root-absolute path: a bare `/queues` only works if this app
      # happens to be mounted at the root, and 404s/500s otherwise.
      def path(script_name, relative)
        "#{script_name}/#{relative}"
      end

      # `show_stats_bar: false` skips the global counter strip entirely —
      # used only by the Stats tab itself (`Routes::Stats`), which already
      # shows the same 6 numbers as its own, bigger card grid right below;
      # repeating them again in the compact bar right above would just be
      # the exact same figures twice on one page.
      def wrap(title, body, script_name: '', extra_head: '', show_stats_bar: true)
        <<~HTML
          <!doctype html>
          <html class="h-full">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>#{h(title)} · Cogworker</title>
            <link rel="stylesheet" href="#{path(script_name, TAILWIND_HREF)}">
            <script src="#{path(script_name, HTMX_SRC)}"></script>
            #{time_script}
            #{live_update_script}
            #{extra_head}
          </head>
          <body class="h-full bg-gray-50 dark:bg-gray-950 text-gray-900 dark:text-gray-100 antialiased">
            #{header(title, script_name)}
            #{stats_bar_strip(script_name) if show_stats_bar}
            <main class="w-full px-4 sm:px-6 lg:px-8 py-8">
              #{body}
            </main>
          </body>
          </html>
        HTML
      end

      def stats_bar_strip(script_name)
        <<~HTML
          <div class="border-b border-gray-200 dark:border-gray-800 bg-gray-50 dark:bg-gray-950">
            <div class="w-full px-4 sm:px-6 lg:px-8 py-2">
              #{stats_bar(script_name)}
            </div>
          </div>
        HTML
      end

      # The 6 job counters (Enqueued/Processed/Failed/Retries/Scheduled/
      # Dead) as a compact, always-visible strip under the header — same
      # counters as the big card grid on the Stats tab itself
      # (`Routes::Stats`), just rendered small enough to sit on every page
      # without pushing content down much. Self-polling (`poll_div`) via a
      # tiny dedicated `GET /stats/bar` fragment route (see `Routes::Stats`)
      # — always just this fragment, never a full page — so it stays live
      # and respects the same global toggle as everything else, without
      # every route needing to compute it itself.
      def stats_bar(script_name)
        poll_div('global-stats-bar', script_name, 'stats/bar', stats_bar_content)
      end

      def stats_bar_content
        stats = Cogworker::Stats.new
        values = {
          'Enqueued' => stats.enqueued, 'Processed' => stats.processed, 'Failed' => stats.failed,
          'Retries' => stats.retry_size, 'Scheduled' => stats.scheduled_size, 'Dead' => stats.dead_size
        }
        items = values.map { |label, value| stat_chip(label, value) }.join
        %(<div class="flex flex-wrap gap-2">#{items}</div>)
      end

      # Each counter its own bordered pill (not just plain text separated by
      # a gap) — border-only in dark mode (no fill) so it reads as an
      # outline against the page background rather than a lighter box
      # sitting on top of it; a solid `bg-white` still works fine in light
      # mode, where the surrounding strip is itself already light.
      def stat_chip(label, value)
        <<~HTML.strip
          <span class="inline-flex items-center gap-1 rounded-md border border-gray-200 dark:border-gray-800 dark:bg-transparent px-2 py-1 text-xs whitespace-nowrap">
            <span class="text-gray-500 dark:text-gray-400">#{h(label)}</span>
            <span class="font-semibold #{JOB_STAT_ACCENTS.fetch(label, '')}">#{h(value)}</span>
          </span>
        HTML
      end

      # Every `time_tag` renders a UTC fallback (readable with JS disabled,
      # or before this runs) plus a `datetime=` attribute; this rewrites
      # each one's visible text to the *browser's local* time, in
      # `Web.time_format`. Registered on `htmx:load`, which htmx fires once
      # for the initial page **and** again after every fragment swap — so
      # newly-swapped-in timestamps (an auto-refreshed Busy/Scheduled/Dead
      # tab) get the same treatment without a full reload.
      #
      # `window.cogworkerFormatTime` is the same formatter exposed globally
      # so other page scripts (e.g. the History tab's AG Grid column
      # `valueFormatter`) can render local time identically, without
      # duplicating the token map.
      def time_script
        <<~HTML
          <script>window.COGWORKER_TIME_FORMAT = #{time_format_json};</script>
          <script>
            (function () {
              function pad(n) { return String(n).padStart(2, '0'); }
              function fmt(date, pattern) {
                pattern = pattern || window.COGWORKER_TIME_FORMAT || '%Y-%m-%d %H:%M:%S';
                var map = {
                  '%Y': date.getFullYear(),
                  '%m': pad(date.getMonth() + 1),
                  '%d': pad(date.getDate()),
                  '%H': pad(date.getHours()),
                  '%M': pad(date.getMinutes()),
                  '%S': pad(date.getSeconds()),
                  '%B': date.toLocaleString(undefined, { month: 'long' }),
                  '%b': date.toLocaleString(undefined, { month: 'short' }),
                  '%A': date.toLocaleString(undefined, { weekday: 'long' }),
                  '%a': date.toLocaleString(undefined, { weekday: 'short' }),
                  '%p': date.getHours() < 12 ? 'AM' : 'PM',
                  '%%': '%'
                };
                return pattern.replace(/%[YmdHMSBbAap%]/g, function (m) { return map[m]; });
              }
              window.cogworkerFormatTime = fmt;
              document.addEventListener('htmx:load', function (evt) {
                var scope = (evt.detail && evt.detail.elt) || document;
                (scope.querySelectorAll ? scope : document).querySelectorAll('[data-cw-time]').forEach(function (el) {
                  var d = new Date(el.getAttribute('datetime'));
                  if (!isNaN(d)) el.textContent = fmt(d);
                });
              });
            })();
          </script>
        HTML
      end

      # Safe to interpolate directly inside an inline `<script>` block: every
      # `/` is escaped (valid JSON — the spec explicitly permits escaping
      # the solidus), which neutralizes a `</script>` sequence hiding inside
      # arbitrary data (a job's args/error message) that would otherwise
      # break out of the script tag.
      def json_for_script(obj)
        JSON.generate(obj).gsub('/', '\\/')
      end

      def time_format_json
        JSON.generate(Web.time_format)
      end

      # `value` may be a Time, or anything responding to `#to_f` (a raw
      # epoch number, as stored in a job/work hash). Renders a UTC fallback
      # (visible with JS disabled) using the same configured pattern; the
      # inline script above then swaps the visible text to the browser's
      # local time once it runs.
      def time_tag(value)
        return '' unless value

        time = value.is_a?(Time) ? value : Time.at(value.to_f)
        %(<time datetime="#{time.utc.iso8601}" data-cw-time>#{h(time.utc.strftime(Web.time_format))}</time>)
      end

      def header(title, script_name)
        links = BUILT_IN_TABS.merge(Web.tabs).map do |label, p|
          nav_link(label, p, script_name, active: label == title)
        end.join
        <<~HTML
          <header class="border-b border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900">
            <div class="w-full px-4 sm:px-6 lg:px-8">
              <div class="flex items-center h-14 gap-1">
                <span class="font-semibold tracking-tight mr-4">⚙️ Cogworker</span>
                <nav class="flex gap-1 overflow-x-auto">#{links}</nav>
                #{live_toggle_button}
              </div>
            </div>
          </header>
        HTML
      end

      # One global on/off switch for every auto-refreshing tab (the
      # htmx-polled Busy/Stats/Queues tabs via `poll_div`'s event filter, and
      # History's own AG Grid data refresh) — persisted in `localStorage` so
      # it survives navigating between tabs/reloading the page.
      def live_toggle_button
        %(<button type="button" data-cw-live-toggle onclick="window.cogworkerSetLiveUpdate(!window.cogworkerLiveUpdate)"
                  aria-pressed="true" title="Toggle live auto-refresh"
                  class="ml-auto flex-shrink-0 px-3 py-1.5 rounded-md text-sm font-medium bg-gray-100 hover:bg-gray-200 dark:bg-gray-700 dark:hover:bg-gray-600 text-gray-700 dark:text-gray-200">⏸ Live</button>)
      end

      # Runs before the rest of the page so `window.cogworkerLiveUpdate` is
      # already set by the time htmx evaluates its first `every ... [...]`
      # poll filter or a route's own refresh script checks it.
      def live_update_script
        <<~HTML
          <script>
            (function () {
              function readStored() {
                try {
                  var v = localStorage.getItem('cogworkerLiveUpdate');
                  return v === null ? true : v === 'true';
                } catch (e) { return true; }
              }
              window.cogworkerLiveUpdate = readStored();
              window.cogworkerSetLiveUpdate = function (on) {
                window.cogworkerLiveUpdate = on;
                try { localStorage.setItem('cogworkerLiveUpdate', on ? 'true' : 'false'); } catch (e) {}
                document.querySelectorAll('[data-cw-live-toggle]').forEach(function (btn) {
                  btn.textContent = on ? '⏸ Live' : '▶ Live';
                  btn.setAttribute('aria-pressed', on ? 'true' : 'false');
                });
              };
              document.addEventListener('DOMContentLoaded', function () {
                window.cogworkerSetLiveUpdate(window.cogworkerLiveUpdate);
              });
            })();
          </script>
        HTML
      end

      def nav_link(label, relative_path, script_name, active:)
        classes = if active
                    'bg-indigo-600 text-white'
                  else
                    'text-gray-600 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800'
                  end
        %(<a href="#{path(script_name,
                          relative_path)}" class="px-3 py-1.5 rounded-md text-sm font-medium whitespace-nowrap #{classes}">#{h(label)}</a>)
      end

      def h(str)
        CGI.escapeHTML(str.to_s)
      end

      def table(headers, rows, empty_message: 'Nothing here.')
        return %(<p class="text-sm text-gray-500 dark:text-gray-400 italic">#{h(empty_message)}</p>) if rows.empty?

        head = headers.map do |c|
          %(<th class="px-4 py-2 text-left text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400">#{h(c)}</th>)
        end.join
        body = rows.map do |row|
          cells = row.map { |cell| %(<td class="px-4 py-2 text-sm align-middle">#{cell}</td>) }.join
          %(<tr class="hover:bg-gray-50 dark:hover:bg-gray-800/60">#{cells}</tr>)
        end.join
        <<~HTML
          <div class="overflow-x-auto rounded-lg border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 shadow-sm">
            <table class="min-w-full divide-y divide-gray-200 dark:divide-gray-800">
              <thead class="bg-gray-50 dark:bg-gray-800/60"><tr>#{head}</tr></thead>
              <tbody class="divide-y divide-gray-100 dark:divide-gray-800">#{body}</tbody>
            </table>
          </div>
        HTML
      end

      def section(heading, body)
        %(<h2 class="text-lg font-semibold mt-8 mb-3">#{h(heading)}</h2>#{body})
      end

      # A one-button `<form>`, wired for both htmx (`hx-post`/`hx-target`)
      # and a plain, JS-less POST fallback to the same `action` URL.
      def badge(label, variant: :default)
        %(<span class="px-2 py-0.5 rounded-full text-xs font-medium #{BADGE_VARIANTS.fetch(variant)}">#{h(label)}</span>)
      end

      def form_button(action, hidden_name, hidden_value, label, hx_target:, variant: :default)
        classes = "px-2.5 py-1 rounded-md text-xs font-medium #{BUTTON_VARIANTS.fetch(variant)}"
        <<~HTML
          <form class="inline" hx-post="#{action}" hx-target="#{hx_target}" hx-swap="innerHTML" method="post" action="#{action}">
            <input type="hidden" name="#{hidden_name}" value="#{h(hidden_value)}">
            <button type="submit" class="#{classes}">#{h(label)}</button>
          </form>
        HTML
      end

      # Same wiring as `form_button`, minus the hidden identifying field —
      # for a whole-collection action (e.g. "delete all") that doesn't
      # target one particular row.
      def action_button(action, label, hx_target:, variant: :default)
        classes = "px-2.5 py-1 rounded-md text-xs font-medium #{BUTTON_VARIANTS.fetch(variant)}"
        <<~HTML
          <form class="inline" hx-post="#{action}" hx-target="#{hx_target}" hx-swap="innerHTML" method="post" action="#{action}">
            <button type="submit" class="#{classes}">#{h(label)}</button>
          </form>
        HTML
      end
    end
  end
end
