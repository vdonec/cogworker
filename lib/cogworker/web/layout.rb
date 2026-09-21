# frozen_string_literal: true

require 'cgi'
require 'json'

module Cogworker
  class Web
    # Tiny shared page chrome for the built-in tabs — not part of the
    # extension contract (an extension is free to build its own HTML, or
    # use `erb`/`Views` the same way these do).
    module Layout
      BUILT_IN_TABS = { 'Overview' => 'overview', 'Jobs' => 'jobs', 'Schedules' => 'schedules',
                        'Workers' => 'workers', 'History' => 'history' }.freeze
      # Vendored under lib/cogworker/web/assets/ (served locally by
      # `Rack::Static`, wired up in `Web.build_app`) rather than fetched
      # from a CDN, so the Web UI works fully offline. `NOCTURNE_CSS_HREF`/
      # `PHOSPHOR_CSS_HREF` are the "Relay" concept's design system
      # (tokens + component classes) and its icon font — both self-hosted,
      # same policy as htmx/AG Grid/Chart.js.
      #
      # No Tailwind stylesheet here any more — every built-in tab (Overview/
      # Jobs/Schedules/Workers, then History/Stats last, since both leaned
      # on hand-written Tailwind utility classes for their AG Grid/Chart.js
      # layout) has been migrated onto these nocturne classes/tokens, and
      # the vendored `assets/tailwind.css` file itself was removed with it —
      # nothing in this gem references it any more.
      HTMX_SRC = 'assets/htmx.min.js'
      NOCTURNE_CSS_HREF = 'assets/nocturne/styles.css'
      PHOSPHOR_CSS_HREF = 'assets/phosphor/style.css'

      BUTTON_VARIANTS = { default: 'btn-secondary', primary: 'btn-primary', warning: 'btn-warning',
                          danger: 'btn-danger', success: 'btn-success' }.freeze

      BADGE_VARIANTS = { success: 'tag-success', warning: 'tag-warning', danger: 'tag-danger',
                         default: 'tag-neutral' }.freeze

      module_function

      # Wraps `inner` in a self-polling container: htmx re-fetches `path`
      # every `interval` and swaps the response into this same element's
      # innerHTML. The route behind `path` only needs to answer both "full
      # page" (a normal GET) and "just this fragment" (`Action#hx_request?`
      # true) — see e.g. Routes::Workers.
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

      # `body`'s own `min-width: max-content` (not a hand-picked pixel
      # number) lets the browser compute the page's own minimum width from
      # whatever's actually inside it — right now that's the header (see
      # its own comment below), but it's self-adjusting: it'd grow or
      # shrink again on its own if the header's content ever changes, no
      # number to update by hand. Real payoff for `main` specifically: as
      # the other direct child of this `display: flex; flex-direction:
      # column` body, `main`'s default `align-items: stretch` cross-size
      # already tracks *whatever width body ends up being* — so once
      # body's own min-width is driven by the header, `main` stretches to
      # match it too, rather than independently shrinking to the viewport
      # while the header overflows past it (a real bug once: the page grew
      # a horizontal scrollbar for the header, but `main`'s own content
      # kept getting squeezed narrower against the viewport instead of
      # riding along at the same width). The other direction of the same
      # bug also hit once `main` was riding along correctly: `min-width:
      # max-content` on `body` takes the *max* of every child's own
      # max-content contribution, so `#cw-main`'s own (a wide table/card
      # grid, capped at 1480px by its own `max-width`) was *also* feeding
      # into it — and being bigger than the header's true ~1090px minimum,
      # it won, flooring the whole page at 1480px instead: the header sat
      # frozen, not tracking the window at all, for the entire 1090–1480px
      # range, only reacting once you crossed below 1480. `.cw-main`'s own
      # `contain: inline-size` (styles.css) is what excludes it from that
      # calculation, leaving the header as the only real contributor.
      def wrap(title, body, script_name: '', extra_head: '')
        <<~HTML
          <!doctype html>
          <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>#{h(title)} · Cogworker</title>
            <link rel="stylesheet" href="#{path(script_name, NOCTURNE_CSS_HREF)}">
            <link rel="stylesheet" href="#{path(script_name, PHOSPHOR_CSS_HREF)}">
            <script src="#{path(script_name, HTMX_SRC)}"></script>
            #{time_script}
            #{live_update_script}
            #{wide_layout_script}
            #{extra_head}
          </head>
          <body style="min-height: 100vh; display: flex; flex-direction: column; min-width: max-content;">
            #{header(title, script_name)}
            <main id="cw-main" class="cw-main" style="flex: 1; padding: 22px; display: flex; flex-direction: column; gap: 20px;">
              #{body}
            </main>
          </body>
          </html>
        HTML
      end

      # Behaves like a desktop app's toolbar: never wraps onto a second
      # line, no matter how narrow the window — below its natural content
      # width, the *page* scrolls horizontally instead (`wrap` above's
      # `min-width: max-content` on `body` is what turns this row's own
      # unshrinkable width into the *page's* scrollable minimum, `main`
      # included). What needs to be explicit here is `flex-wrap: nowrap` at
      # every level that could otherwise wrap (this row, `.nav`, the
      # right-hand action group), and — the easy-to-miss half of it —
      # `white-space: nowrap` on every label that could otherwise
      # line-break internally (`.btn` in styles.css covers the buttons;
      # nav links already get it from `nav_link` below). Without the
      # latter, flexbox's own "never shrink a row below its content's
      # minimum size" protection still holds, but that minimum is computed
      # from the *longest word*, not the whole label, once wrapping is
      # allowed — so a button like "Pause intake" still gets squeezed down
      # and its label splits into two lines ("Pause"/"intake") instead of
      # the row ever overflowing. This was caught by hand — a fixed pixel
      # `min-width` was tried first as a shortcut for both this and body's
      # own min-width above, then dropped for the CSS-computed `max-
      # content`/`white-space: nowrap` combination once the real causes
      # turned out to make a hardcoded number unnecessary either way.
      def header(title, script_name)
        links = BUILT_IN_TABS.merge(Web.tabs).map do |label, p|
          nav_link(label, p, script_name, active: label == title)
        end.join
        <<~HTML
          <header style="display: flex; align-items: center; gap: 14px; padding: 12px 22px; background: linear-gradient(180deg, color-mix(in srgb, var(--color-text) 4%, var(--color-bg)), var(--color-bg)); box-shadow: inset 0 -1px 0 var(--color-divider); position: sticky; top: 0; z-index: 5;">
            <span style="font-family: var(--font-heading); font-weight: var(--font-heading-weight); font-size: 18px; letter-spacing: -0.02em; white-space: nowrap;">Cogworker</span>
            <nav class="nav" style="padding: 0; gap: 2px; flex-wrap: nowrap;">#{links}</nav>
            <div style="margin-left: auto; display: flex; align-items: center; gap: 14px; flex-wrap: nowrap;">
              #{cluster_bar(script_name)}
              #{pause_intake_button(script_name)}
              #{resume_intake_button(script_name)}
              #{wide_layout_toggle_button}
              #{live_toggle_button}
            </div>
          </header>
        HTML
      end

      # `production · N workers` in the "Relay" concept mock, minus the
      # fabricated environment name (Cogworker has no such concept) — just
      # the real worker count (`ProcessSet`) and a status dot colored by
      # whether any of them are actually taking work right now, refreshed
      # via a tiny dedicated fragment route (`Routes::Workers`'s own `GET
      # /workers/summary`).
      def cluster_bar(script_name)
        poll_div('cluster-bar', script_name, 'workers/summary', cluster_bar_content)
      end

      def cluster_bar_content
        processes = Cogworker::ProcessSet.new.to_a
        active = processes.any? { |p| ![true, 'true'].include?(p['quiet']) }
        dot_glow = active ? ' box-shadow: 0 0 0 3px color-mix(in srgb, var(--color-success) 22%, transparent);' : ''
        dot_color = active ? 'var(--color-success)' : 'var(--color-neutral-600)'
        count = processes.size
        <<~HTML.strip
          <span style="display: inline-flex; align-items: center; gap: 7px; font-size: 13px; color: var(--color-neutral-400); white-space: nowrap;">
            <span style="width: 7px; height: 7px; border-radius: 50%; background: #{dot_color};#{dot_glow}"></span>
            #{count} #{count == 1 ? 'worker' : 'workers'}
          </span>
        HTML
      end

      # Cluster-wide "quiet every process" (`Routes::Workers`'s own `POST
      # /workers/pause_all`) — the mock's "Pause intake" button. Unlike real
      # Sidekiq OSS (where quiet is a one-way trip back to a fresh process),
      # `Manager#quiet` here is a plain in-memory flag, so `resume_intake_
      # button` below is a genuine, symmetric undo rather than a full
      # process restart.
      def pause_intake_button(script_name)
        action = path(script_name, 'workers/pause_all')
        action_button(action, 'Pause intake', hx_target: '#cluster-bar', icon: 'pause')
      end

      # The undo for the button above (`POST /workers/resume_all`) — both
      # buttons are always shown side by side rather than toggling one for
      # the other, since `#cluster-bar` only reports an aggregate "any
      # process active?" dot, not enough to know which single action applies
      # cluster-wide when processes are in a mixed state.
      def resume_intake_button(script_name)
        action = path(script_name, 'workers/resume_all')
        action_button(action, 'Resume intake', hx_target: '#cluster-bar', variant: :success, icon: 'play')
      end

      # `.nav a`/`.nav a[aria-current='page']` (styles.css) already turn a
      # link accent-colored on hover or when active — only the active
      # pill's background tint needs to be added here per-link, so this
      # stays in sync with the design system's own hover/focus treatment
      # instead of duplicating it.
      def nav_link(label, relative_path, script_name, active:)
        bg = active ? ' background: color-mix(in srgb, var(--color-accent) 14%, transparent);' : ''
        attrs = active ? ' aria-current="page"' : ''
        %(<a href="#{path(script_name,
                          relative_path)}"#{attrs} style="display: inline-block; padding: 6px 11px; border-radius: var(--radius-md); white-space: nowrap;#{bg}">#{h(label)}</a>)
      end

      # One global on/off switch for every auto-refreshing tab (the
      # htmx-polled Workers/Overview tabs via `poll_div`'s event filter, and
      # History's own AG Grid data refresh) — persisted in `localStorage` so
      # it survives navigating between tabs/reloading the page.
      def live_toggle_button
        %(<button type="button" data-cw-live-toggle class="btn btn-secondary" onclick="window.cogworkerSetLiveUpdate(!window.cogworkerLiveUpdate)"
                  aria-pressed="true" title="Toggle live auto-refresh"
                  style="flex-shrink: 0; font-size: 13px;">⏸ Live</button>)
      end

      # Global fixed-width/full-width switch for `<main>` (`#cw-main`, the
      # `.cw-main`/`.cw-main--wide` pair in styles.css) — same persisted-in-
      # `localStorage`, applies-on-every-page shape as `live_toggle_button`/
      # `live_update_script` above, just flipping a layout class instead of
      # gating polling. Defaults to fixed width (matching the design as
      # exported) when nothing's stored yet.
      def wide_layout_toggle_button
        %(<button type="button" data-cw-wide-toggle class="btn btn-secondary" onclick="window.cogworkerSetWideLayout(!window.cogworkerWideLayout)"
                  aria-pressed="false" title="Toggle fixed-width/full-width layout"
                  style="flex-shrink: 0; font-size: 13px;">⛶ Full width</button>)
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

      # One global on/off switch for every auto-refreshing tab (the
      # htmx-polled Workers/Overview tabs via `poll_div`'s event filter, and
      # History's own AG Grid data refresh) — persisted in `localStorage` so
      # it survives navigating between tabs/reloading the page.
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

      # Companion to `wide_layout_toggle_button` above — same persisted-
      # in-`localStorage`, apply-on-`DOMContentLoaded`-and-every-toggle
      # shape as `live_update_script`, just toggling `#cw-main`'s
      # `cw-main--wide` class (styles.css) instead of a polling flag.
      # Applied directly here (not deferred to a `poll_div`/htmx swap)
      # since `#cw-main` itself is never one of those fragments — it's the
      # element every fragment lives *inside*.
      def wide_layout_script
        <<~HTML
          <script>
            (function () {
              function readStored() {
                try { return localStorage.getItem('cogworkerWideLayout') === 'true'; } catch (e) { return false; }
              }
              window.cogworkerWideLayout = readStored();
              window.cogworkerSetWideLayout = function (on) {
                window.cogworkerWideLayout = on;
                try { localStorage.setItem('cogworkerWideLayout', on ? 'true' : 'false'); } catch (e) {}
                var main = document.getElementById('cw-main');
                if (main) main.classList.toggle('cw-main--wide', on);
                document.querySelectorAll('[data-cw-wide-toggle]').forEach(function (btn) {
                  btn.textContent = on ? '⛶ Fixed width' : '⛶ Full width';
                  btn.setAttribute('aria-pressed', on ? 'true' : 'false');
                });
              };
              document.addEventListener('DOMContentLoaded', function () {
                window.cogworkerSetWideLayout(window.cogworkerWideLayout);
              });
            })();
          </script>
        HTML
      end

      def h(str)
        CGI.escapeHTML(str.to_s)
      end

      # `wrapped: false` skips this table's own bordered/shadowed card —
      # for a caller that's already putting it inside one of its own (e.g.
      # a `<section>` alongside an `<h4>`, matching Overview's Throughput/
      # Redis cards), where the default wrapper would just nest one bordered
      # box inside another.
      def table(headers, rows, empty_message: 'Nothing here.', wrapped: true)
        return %(<p class="text-muted" style="font-size: 13px; font-style: italic;">#{h(empty_message)}</p>) if rows.empty?

        head = headers.map { |c| %(<th>#{h(c)}</th>) }.join
        body = rows.map do |row|
          cells = row.map { |cell| %(<td>#{cell}</td>) }.join
          %(<tr>#{cells}</tr>)
        end.join
        inner = <<~HTML
          <table class="table">
            <thead><tr>#{head}</tr></thead>
            <tbody>#{body}</tbody>
          </table>
        HTML
        return inner unless wrapped

        %(<div style="background: var(--color-surface); border-radius: var(--radius-md); box-shadow: var(--shadow-sm); padding: 8px 6px 4px; overflow-x: auto;">#{inner}</div>)
      end

      def section(heading, body)
        %(<h3 style="font-family: var(--font-heading); font-weight: var(--font-heading-weight); font-size: 17px; margin: var(--space-8) 0 var(--space-3);">#{h(heading)}</h3>#{body})
      end

      def badge(label, variant: :default)
        %(<span class="tag #{BADGE_VARIANTS.fetch(variant)}">#{h(label)}</span>)
      end

      # A one-button `<form>`, wired for both htmx (`hx-post`/`hx-target`)
      # and a plain, JS-less POST fallback to the same `action` URL.
      # `icon:` (a Phosphor icon name, e.g. `'arrow-clockwise'`) is optional
      # — the "Relay" concept mock only puts icons on a page's few
      # prominent/standalone actions (a detail panel's own buttons, the
      # header's "Pause intake"), never on the small, repeated actions
      # packed into a dense table row, so most call sites omit it.
      def form_button(action, hidden_name, hidden_value, label, hx_target:, variant: :default, icon: nil)
        classes = "btn #{BUTTON_VARIANTS.fetch(variant)}"
        <<~HTML
          <form style="display: inline;" hx-post="#{action}" hx-target="#{hx_target}" hx-swap="innerHTML" method="post" action="#{action}">
            <input type="hidden" name="#{hidden_name}" value="#{h(hidden_value)}">
            <button type="submit" class="#{classes}" style="font-size: 13px; padding: 4px 10px;">#{icon_tag(icon)}#{h(label)}</button>
          </form>
        HTML
      end

      # Same wiring as `form_button`, minus the hidden identifying field —
      # for a whole-collection action (e.g. "delete all") that doesn't
      # target one particular row.
      def action_button(action, label, hx_target:, variant: :default, icon: nil)
        classes = "btn #{BUTTON_VARIANTS.fetch(variant)}"
        <<~HTML
          <form style="display: inline;" hx-post="#{action}" hx-target="#{hx_target}" hx-swap="innerHTML" method="post" action="#{action}">
            <button type="submit" class="#{classes}" style="font-size: 13px; padding: 4px 10px;">#{icon_tag(icon)}#{h(label)}</button>
          </form>
        HTML
      end

      def icon_tag(name)
        name ? %(<i class="ph ph-#{name}"></i>) : ''
      end
    end
  end
end
