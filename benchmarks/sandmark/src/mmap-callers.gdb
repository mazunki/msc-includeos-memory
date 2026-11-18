set pagination off
set confirm off
break __mmap
commands
  silent
  info symbol *(void**)$sp
  continue
end
run > /dev/null
quit
