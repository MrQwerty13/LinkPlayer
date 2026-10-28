package player

import "syscall"

func sigStop() syscall.Signal { return syscall.SIGSTOP }
func sigCont() syscall.Signal { return syscall.SIGCONT }
