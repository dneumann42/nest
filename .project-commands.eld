;;; -*- lisp-data -*-
((run . "nimble run -- run apps/nomicon")
 (commands "nimble run" "nim r src/nest/widgets.nim"
	   "nim r src/nest.nim" "nim r src/widgets2.nim"
	   "nim r src/example/pathEditor.nim"
	   "nimble run -- run ./apps/duck"
	   "nimble run -- run apps/nomicon")
 (build . "nim r src/nest.nim"))
