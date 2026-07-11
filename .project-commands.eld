;;; -*- lisp-data -*-
((build . "nim r src/nest.nim") (run . "nim r src/nest.nim")
 (commands "nimble run" "nim r src/nest/widgets.nim"
	   "nim r src/nest.nim" "nim r src/widgets2.nim"))
