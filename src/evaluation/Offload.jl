# Keeping the serving thread free of blocking work.
#
# A Pluto server does everything on one thread: HTTP.jl runs its accept loop on the interactive pool
# when there is one (its `@spawn :interactive`), and every connection, every websocket handler and
# every notebook run is an `@async` child of that loop — so all of it shares that thread. Julia file
# I/O is synchronous. A `write` to an NFS home that is having a slow minute therefore holds the
# THREAD, not just the task: `/ping` goes unanswered, the websocket goes quiet, and anything watching
# the server from outside concludes it is gone. That is what a 160 MB output-cache sidecar, or a
# notebook save, looked like from the hub's tunnel watchdog.
#
# The fix is to give the process a second thread and to put the blocking work there. Started with
# `--threads=1,1`, a server has one default thread (thread 1, where the main task only waits) and one
# interactive thread (where HTTP.jl and the notebooks live). `Threads.@spawn` from the interactive
# thread lands on the idle default thread, deterministically, and the caller waits with a yield.

"Flags every SpaceStation server process is launched with: one interactive thread for serving, one default thread for `offload_blocking`."
const SERVER_THREAD_FLAGS = "--threads=1,1"

"""
Run `f` off the serving thread — a blocking file operation, or a long CPU-bound one — when the
process has a thread to spare for it; inline otherwise (a single-threaded process, or a caller that
is already on the default pool). Returns `f()`'s value and rethrows its exception unwrapped, so
callers see exactly what they would have seen from a plain call.
"""
function offload_blocking(f)
    if Threads.nthreads(:interactive) > 0 && Threads.threadpool() === :interactive && Threads.nthreads(:default) >= 1
        t = Threads.@spawn f()
        try
            return fetch(t)
        catch e
            e isa TaskFailedException && rethrow(e.task.exception)
            rethrow()
        end
    end
    f()
end
