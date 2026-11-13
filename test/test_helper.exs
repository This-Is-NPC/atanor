# Few guest threads and short CPU limits, so the limit tests finish quickly. Fixed for the VM when the
# first node starts. `max_waiting` is given: otherwise the memory limit of whichever node starts first
# (some tests set a tiny one) would derive it for every test of the VM.
Application.put_env(:atanor, :wasm, threads: 4, queue: 32, max_waiting: 8, queue_wait_ms: 1500, cpu_ms: 300)

# assert_receive bounds a failure; it is not a timing assumption.
ExUnit.start(exclude: [:seaweedfs, :cluster], assert_receive_timeout: 2_000)

# Under `mix test --cover` modules run cover-compiled, so their MD5 differs from the beam file that the
# packaging tests hash. Load the worker they package from disk; it is test support, not counted anyway.
if :code.which(Atanor.Test.ProbeWorker) == :cover_compiled do
  :code.purge(Atanor.Test.ProbeWorker)
  :code.delete(Atanor.Test.ProbeWorker)
  {:module, _} = :code.load_file(Atanor.Test.ProbeWorker)
end
