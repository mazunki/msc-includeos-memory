# boot-trace

How IncludeOS starts up on x86_64 with Multiboot, up to APIC timer
calibration, and how memory becomes available along the way (§2.5, §4.1).

- `tracing.pdf` (source `tracing.tex`): the startup sequence reconstructed
  from a GDB trace with breakpoints across early kernel code and the serial
  boot log, at IncludeOS commit `62337fceb`, with why each phase comes where
  it does.
- `call-chain.md`: the bare call chain from `long_mode()` to `kernel_main`.

    pdflatex tracing.tex && pdflatex tracing.tex
