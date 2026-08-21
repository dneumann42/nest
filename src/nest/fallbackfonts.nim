## The fonts compiled into the binary as a last-resort fallback.
##
## A backend looks for a system font first, so an application picks up the
## fonts the machine is set up with. When none of them can be opened these
## take over, so text always renders: a UI is never blank because the host
## happens to have no font installed at a path the backend knows.
##
## Both are Liberation fonts, licensed under the SIL Open Font License 1.1;
## the licence travels with them in `fonts/LICENSE-Liberation.txt`.

const
  fallbackSansFont* = staticRead("fonts/LiberationSans-Regular.ttf")
    ## Liberation Sans Regular, the fallback for proportional text.
  fallbackMonoFont* = staticRead("fonts/LiberationMono-Regular.ttf")
    ## Liberation Mono Regular, the fallback for monospaced text.
