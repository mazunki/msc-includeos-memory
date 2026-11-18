# Do unikernels need POSIX? Memory Management in IncludeOS

Hi! This is my master's thesis from the University of Oslo (2026), along with the primary experiments I ran for it. It's about giving programs on unikernels, specifically [IncludeOS](https://github.com/includeos/IncludeOS), more control over their memory: named regions, fixed placement, and named permissions. We do this by playing with `mmap`/`mprotect`, and compare how well we can do over Linux.

The repository is mainly split into two parts: the thesis itself, and a monorepo of the different experiments which are referenced in the thesis.

- [thesis](thesis): the LaTeX source and the PDF (`thesis.pdf`).
- [benchmarks](benchmarks): what was run for the evaluation, and the raw results.

The IncludeOS changes are on the `msc-thesis` branch of [mazunki/IncludeOS](https://github.com/mazunki/IncludeOS/tree/msc-thesis).

Hope you enjoy!

