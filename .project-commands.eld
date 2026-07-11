;;; -*- lisp-data -*-
((run . "nim r src/example/pathEditor.nim")
 (commands "nimble run" "nim r src/nest/widgets.nim"
	   "nim r src/nest.nim" "nim r src/widgets2.nim"
	   "nim r src/example/pathEditor.nim")
 (build . "nim r src/nest.nim"))
