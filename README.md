# nest

User interface framework

## Bundled fonts

`src/nest/fonts` holds Liberation Sans and Liberation Mono, compiled into the
binary and used when no system font can be opened, so text always renders.
They are licensed under the SIL Open Font License 1.1, a copy of which sits
beside them in `src/nest/fonts/LICENSE-Liberation.txt`.

## Documentation

- `docs/ui.org` — building interfaces, in Nim and in owl
- `docs/layout.org` — the constraint layout
- `docs/dialogs.org` — dialogs and overlays
- `docs/performance.org` — what a frame costs, how the loop decides what to
  draw, and how to measure both (`nimble bench`, `nimble profile`,
  `-d:nestBench`)

## Benchmarking

Nest carries its own frame instrumentation, compiled out unless asked for:

    nimble bench                      # frame cost of resize, idle and dialogs
    nimble profile                    # the same, with a per-phase breakdown
    nim c -r -d:release -d:nestBench tests/bench_resize.nim

Any build can be instrumented with `-d:nestBench` and told to report with
`NEST_BENCH_REPORT_MS=1000`, `NEST_BENCH_SUMMARY=1` or `NEST_BENCH_JSON=path`.
See `docs/performance.org`.
