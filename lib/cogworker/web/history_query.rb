# frozen_string_literal: true

require 'json'

module Cogworker
  class Web
    # Server side of the History tab's AG Grid (Infinite Row Model): one
    # block of rows at a time — `[rows, total]` for `offset`/`limit` —
    # instead of handing the browser every retained entry up front.
    #
    # `sort`/`filters` arrive in AG Grid's own `sortModel`/`filterModel`
    # shapes (`[{ 'colId' => ..., 'sort' => 'asc'|'desc' }]` /
    # `{ colId => { 'filterType' => 'text'|'number', 'type' => ..., ... } }`,
    # optionally combined via `operator`/`conditions`), and `COLUMNS` below
    # computes each column's value the same way `Routes::History#grid_script`
    # displays it, so a server-side filter matches what the viewer sees.
    #
    # Two paths:
    # - no filters, sorted by Finished (the default): a plain `ZREVRANGE`/
    #   `ZRANGE` of just the requested slice, total from `ZCARD` — the
    #   everyday case stays O(limit), whatever `History.max_entries` is.
    # - anything else (a column filter, `?jid=`, sorting by another column):
    #   a scan of the whole status ZSET in chunks, filtered/sorted in Ruby,
    #   then sliced. Bounded by retention (`History.retention_days`/
    #   `max_entries`), and only the requested slice ever leaves the server.
    class HistoryQuery
      SCAN_CHUNK = 1000
      MAX_LIMIT = 1000
      DEFAULT_SORT = 'finished_at'

      COLUMNS = {
        'finished_at' => ->(e) { e['finished_at'].to_f },
        'class' => ->(e) { e['class'].to_s },
        'queue' => ->(e) { e['queue'].to_s },
        'jid' => ->(e) { e['jid'].to_s },
        'args' => ->(e) { JSON.generate(e['args']) },
        'status' => ->(e) { e['status'].to_s },
        'duration' => ->(e) { ((e['finished_at'].to_f - e['started_at'].to_f) * 1000).round },
        'error' => ->(e) { e['error_class'] ? "#{e['error_class']}: #{e['error_message']}" : '' }
      }.freeze

      def initialize(status:, jid: '', sort: [], filters: {})
        @key = Cogworker::History::Storage::LIST_KEYS.fetch(status, Cogworker::History::Storage::LIST_KEYS.fetch('all'))
        @jid = jid.to_s
        @sort = Array(sort).find { |s| s.is_a?(Hash) && COLUMNS.key?(s['colId']) }
        @filters = filters.is_a?(Hash) ? filters.select { |col, _| COLUMNS.key?(col) } : {}
      end

      def fetch(offset, limit)
        offset = [offset.to_i, 0].max
        limit = limit.to_i.clamp(0, MAX_LIMIT)
        fast_path? ? fetch_slice(offset, limit) : fetch_scanned(offset, limit)
      end

      private

      def sort_col
        @sort ? @sort['colId'] : DEFAULT_SORT
      end

      def ascending?
        @sort && @sort['sort'] == 'asc'
      end

      def fast_path?
        @jid.empty? && @filters.empty? && sort_col == DEFAULT_SORT
      end

      def fetch_slice(offset, limit)
        return [[], Cogworker.config.redis { |c| c.zcard(@key) }] if limit.zero?

        stop = offset + limit - 1
        total, raw = Cogworker.config.redis do |c|
          [c.zcard(@key), ascending? ? c.zrange(@key, offset, stop) : c.zrevrange(@key, offset, stop)]
        end
        [raw.map { |r| JSON.parse(r) }, total]
      end

      def fetch_scanned(offset, limit)
        matched = scan.select { |entry| matches?(entry) }
        [sort(matched)[offset, limit] || [], matched.size]
      end

      # Ties stay newest-first (the scan's own order) either direction —
      # the index tiebreaker also makes Ruby's unstable `sort_by` stable.
      def sort(entries)
        getter = COLUMNS.fetch(sort_col)
        keyed = entries.each_with_index.map { |entry, i| [getter.call(entry), i, entry] }
        if ascending?
          keyed.sort_by { |value, i, _| [value, i] }.map(&:last)
        else
          keyed.sort_by { |value, i, _| [value, -i] }.reverse.map(&:last)
        end
      end

      def scan
        needle = @jid.empty? ? nil : JSON.generate('jid' => @jid)[1..-2]
        entries = []
        Cogworker.config.redis do |c|
          start = 0
          loop do
            chunk = c.zrevrange(@key, start, start + SCAN_CHUNK - 1)
            chunk.each do |raw|
              next if needle && !raw.include?(needle) # cheap pre-check before parsing

              entry = JSON.parse(raw)
              entries << entry if @jid.empty? || entry['jid'] == @jid
            end
            break if chunk.size < SCAN_CHUNK

            start += SCAN_CHUNK
          end
        end
        entries
      end

      def matches?(entry)
        @filters.all? { |col, model| model_matches?(model, COLUMNS.fetch(col).call(entry)) }
      end

      def model_matches?(model, value)
        return true unless model.is_a?(Hash)

        if model['conditions'].is_a?(Array)
          results = model['conditions'].map { |cond| condition_matches?(model['filterType'], cond, value) }
          model['operator'] == 'OR' ? results.any? : results.all?
        else
          condition_matches?(model['filterType'], model, value)
        end
      end

      def condition_matches?(filter_type, cond, value)
        return true unless cond.is_a?(Hash)

        case cond['filterType'] || filter_type
        when 'number' then number_matches?(cond, value)
        else text_matches?(cond, value.to_s)
        end
      end

      # AG Grid's default text filter semantics: case-insensitive.
      def text_matches?(cond, value)
        value = value.downcase
        needle = cond['filter'].to_s.downcase
        case cond['type']
        when 'contains' then value.include?(needle)
        when 'notContains' then !value.include?(needle)
        when 'equals' then value == needle
        when 'notEqual' then value != needle
        when 'startsWith' then value.start_with?(needle)
        when 'endsWith' then value.end_with?(needle)
        when 'blank' then value.empty?
        when 'notBlank' then !value.empty?
        else true
        end
      end

      # AG Grid's default number filter semantics (`inRange` exclusive).
      def number_matches?(cond, value)
        return value.nil? if cond['type'] == 'blank'
        return !value.nil? if cond['type'] == 'notBlank'

        target = Float(cond['filter'], exception: false)
        return true if target.nil?

        case cond['type']
        when 'equals' then value == target
        when 'notEqual' then value != target
        when 'lessThan' then value < target
        when 'lessThanOrEqual' then value <= target
        when 'greaterThan' then value > target
        when 'greaterThanOrEqual' then value >= target
        when 'inRange'
          to = Float(cond['filterTo'], exception: false)
          to.nil? || (value > target && value < to)
        else true
        end
      end
    end
  end
end
