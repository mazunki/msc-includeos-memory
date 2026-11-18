{
  withCcache ? false, # Enable ccache support
  smp ? false, # Enable SMP support
}:
# points at the sibling checkout so it picks up whatever branch is active
# there (e.g. ref-buddy-init-new), same pattern as repos/magnus/runtimes/ocaml-fib
import ../IncludeOS { inherit withCcache; inherit smp; }
