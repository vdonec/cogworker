# frozen_string_literal: true

module Cogworker
  module Prometheus
    # Own minimal exporter, built entirely on the introspection API — no
    # dependency on any third-party Prometheus gem's internal hooks. Mounted
    # exactly the way any other Web UI extension is: `Web.register(...)`
    # adds its `/metrics` route through the normal extension mechanism, not
    # a special-cased reserved path in the Web core.
    module Exporter
      def self.registered(app)
        app.get('/metrics') do
          # Mounted unconditionally by Web.load_routes! (see there); gated
          # here, at request time, rather than by leaving the route
          # unregistered, so Cogworker::Web.prometheus_exporter_enabled can
          # be set any time before a request arrives, same as time_format/
          # live_update_interval — and so a disabled /metrics still 404s
          # for a reason visible right here, not a mysteriously-never-
          # mounted route.
          unless Cogworker::Web.prometheus_exporter_enabled
            next [404, { 'content-type' => 'text/plain' }, ['Not Found']]
          end

          [200, { 'content-type' => 'text/plain; version=0.0.4' }, [Exporter.render]]
        end
      end

      def self.render
        stats = Stats.new
        lines = []
        lines << '# TYPE cogworker_processed_total counter'
        lines << "cogworker_processed_total #{stats.processed}"
        lines << '# TYPE cogworker_failed_total counter'
        lines << "cogworker_failed_total #{stats.failed}"
        lines << '# TYPE cogworker_retry_size gauge'
        lines << "cogworker_retry_size #{stats.retry_size}"
        lines << '# TYPE cogworker_scheduled_size gauge'
        lines << "cogworker_scheduled_size #{stats.scheduled_size}"
        lines << '# TYPE cogworker_dead_size gauge'
        lines << "cogworker_dead_size #{stats.dead_size}"

        lines << '# TYPE cogworker_queue_size gauge'
        queue_names.each { |q| lines << %(cogworker_queue_size{queue="#{q}"} #{Queue.new(q).size}) }
        lines << '# TYPE cogworker_queue_latency_seconds gauge'
        queue_names.each do |q|
          lines << %(cogworker_queue_latency_seconds{queue="#{q}"} #{Queue.new(q).latency.round(3)})
        end

        lines << '# TYPE cogworker_busy_workers gauge'
        lines << "cogworker_busy_workers #{ProcessSet.new.sum { |p| p['busy'].to_i }}"

        "#{lines.join("\n")}\n"
      end

      def self.queue_names
        Cogworker.config.redis { |c| c.smembers(RedisKeys::QUEUES) }.sort
      end
    end
  end
end

Cogworker::Web.register(Cogworker::Prometheus::Exporter, name: 'prometheus_exporter', tab: nil, index: nil)
