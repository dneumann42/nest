;;; -*- lisp-data -*-
((run . "nim r src/variants.nim")
 (commands "nimble run" "nim r src/nest/widgets.nim"
	   "nim r src/nest.nim" "nim r src/widgets2.nim"
	   "nim r src/example/pathEditor.nim"
	   "nimble run -- run ./apps/duck"
	   "nimble run -- run apps/nomicon" "nim r src/variants.nim")
 (build . "nim r src/nest.nim"))
