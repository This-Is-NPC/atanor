if Code.ensure_loaded?(Phoenix.LiveDashboard) do
  defmodule Atanor.Dashboard.Metrics do
    @moduledoc false
    # The charts of the metrics page, from the events in docs/telemetry.md.
    # Durations are in native units, so every summary converts them.

    import Telemetry.Metrics

    @ms {:native, :millisecond}

    def metrics do
      requests() ++ cluster() ++ wasm() ++ connections() ++ alarms() ++ jobs() ++ cells() ++ feed() ++ native()
    end

    defp requests do
      [
        counter("atanor.call.count",
          event_name: [:atanor, :call],
          measurement: :duration,
          tags: [:worker, :kind, :result],
          description: "Calls into workers",
          reporter_options: [nav: "requests"]
        ),
        summary("atanor.call.duration",
          unit: @ms,
          tags: [:worker, :kind],
          description: "Time inside the worker's callback",
          reporter_options: [nav: "requests"]
        ),
        counter("atanor.call.errors",
          event_name: [:atanor, :call],
          measurement: :duration,
          keep: &(&1.result == :error),
          tags: [:worker, :reason],
          tag_values: &%{&1 | reason: inspect(&1.reason)},
          description: "Calls that failed",
          reporter_options: [nav: "requests"]
        ),
        counter("atanor.http.reject.count",
          tags: [:reason, :worker],
          tag_values: &%{&1 | worker: &1.worker || "-"},
          description: "HTTP requests answered before reaching a worker",
          reporter_options: [nav: "requests"]
        )
      ]
    end

    defp cluster do
      [
        counter("atanor.forward.count",
          event_name: [:atanor, :forward],
          measurement: :duration,
          tags: [:worker, :result],
          description: "Calls forwarded to the owner of a cell",
          reporter_options: [nav: "cluster"]
        ),
        summary("atanor.forward.duration",
          unit: @ms,
          tags: [:worker],
          description: "Whole round trip of forwarded calls",
          reporter_options: [nav: "cluster"]
        )
      ]
    end

    defp wasm do
      [
        counter("atanor.wasm.limit.count",
          tags: [:worker, :limit],
          description: "WASM calls stopped by a limit",
          reporter_options: [nav: "wasm"]
        ),
        summary("atanor.wasm.invoke.instantiate",
          unit: @ms,
          tags: [:worker],
          description: "Instantiation time of WASM calls",
          reporter_options: [nav: "wasm"]
        ),
        summary("atanor.wasm.invoke.run",
          unit: @ms,
          tags: [:worker],
          description: "Guest time after instantiation",
          reporter_options: [nav: "wasm"]
        ),
        summary("atanor.wasm.invoke.memory_bytes",
          unit: :byte,
          tags: [:worker],
          description: "Peak linear memory of WASM calls",
          reporter_options: [nav: "wasm"]
        ),
        summary("atanor.wasm.load.duration",
          unit: @ms,
          tags: [:source],
          description: "Time to get a compiled component",
          reporter_options: [nav: "wasm"]
        )
      ]
    end

    defp connections do
      [
        counter("atanor.tcp.connect.count",
          tags: [:worker, :listener],
          description: "TCP connections opened",
          reporter_options: [nav: "connections"]
        ),
        counter("atanor.tcp.disconnect.count",
          event_name: [:atanor, :tcp, :disconnect],
          measurement: :duration,
          tags: [:worker, :reason],
          description: "TCP connections closed",
          reporter_options: [nav: "connections"]
        ),
        counter("atanor.ws.connect.count",
          tags: [:worker],
          description: "WebSockets opened",
          reporter_options: [nav: "connections"]
        ),
        counter("atanor.ws.disconnect.count",
          event_name: [:atanor, :ws, :disconnect],
          measurement: :duration,
          tags: [:worker],
          description: "WebSockets closed",
          reporter_options: [nav: "connections"]
        )
      ]
    end

    defp alarms do
      [
        counter("atanor.alarm.fired.count",
          event_name: [:atanor, :alarm, :fired],
          measurement: :duration,
          tags: [:worker],
          description: "Alarms handled",
          reporter_options: [nav: "alarms"]
        ),
        counter("atanor.alarm.failed.count",
          event_name: [:atanor, :alarm, :failed],
          measurement: :duration,
          tags: [:worker, :final],
          description: "Alarm handlers that failed",
          reporter_options: [nav: "alarms"]
        ),
        summary("atanor.alarm.fired.duration",
          unit: @ms,
          tags: [:worker],
          description: "Claim to acknowledgment",
          reporter_options: [nav: "alarms"]
        )
      ]
    end

    defp jobs do
      [
        counter("atanor.job.enqueued.count",
          tags: [:worker, :kind],
          description: "Jobs enqueued",
          reporter_options: [nav: "jobs"]
        ),
        counter("atanor.job.started.count",
          tags: [:worker, :kind],
          description: "Job attempts started",
          reporter_options: [nav: "jobs"]
        ),
        counter("atanor.job.finished.count",
          event_name: [:atanor, :job, :finished],
          measurement: :duration,
          tags: [:worker, :result, :final],
          description: "Job attempts finished",
          reporter_options: [nav: "jobs"]
        ),
        counter("atanor.job.dead.count",
          tags: [:worker, :kind],
          description: "Jobs that exhausted their attempts",
          reporter_options: [nav: "jobs"]
        ),
        counter("atanor.sweep.page.dispatched",
          event_name: [:atanor, :sweep, :page],
          measurement: :dispatched,
          tags: [:operation],
          description: "Cells dispatched by bulk operations",
          reporter_options: [nav: "jobs"]
        )
      ]
    end

    defp cells do
      [
        sum("atanor.cells.migrate.count",
          tags: [:namespace],
          description: "Awake cells migrated to a new worker version",
          reporter_options: [nav: "cells"]
        ),
        counter("alambique.admission.evict.count",
          event_name: [:alambique, :admission, :evict],
          measurement: :bytes,
          description: "Cells hibernated to stay under awake max_bytes",
          reporter_options: [nav: "cells"]
        ),
        last_value("alambique.admission.evict.bytes",
          unit: :byte,
          description: "Memory of the awake cells after the last eviction",
          reporter_options: [nav: "cells"]
        )
      ]
    end

    # Gauges and cumulative counters polled from the native libraries.
    defp feed do
      [
        counter("atanor.feed.rejected.count",
          tags: [:reason],
          tag_values: &%{&1 | reason: inspect(&1.reason)},
          description: "Feed objects Alambique could not decode, which Atanor skipped",
          reporter_options: [nav: "feed"]
        )
      ]
    end

    defp native do
      wasm =
        for key <- ~w(live_instances queued_calls live_components calls rejected_calls traps_timeout traps_memory
                       traps_cpu traps_other host_calls disk_cache_hits disk_cache_misses alloc_bytes free_bytes)a do
          native("atanor.wasm.native.stats.#{key}", "WASM engine: #{key}", "wasm_native")
        end

      alambique =
        for key <- ~w(connections_open files_open sqlite_memory_used page_cache_hits page_cache_misses sqlite_calls
                       replication_calls lazy_calls ltx_bytes_encoded ltx_bytes_decoded)a do
          native("alambique.native.stats.#{key}", "Alambique: #{key}", "alambique_native")
        end

      wasm ++ alambique
    end

    defp native(name, description, nav),
      do: last_value(name, description: description, reporter_options: [nav: nav])
  end
end
