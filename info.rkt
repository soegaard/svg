#lang info

(define collection "svg")
(define version "0.1")
(define pkg-authors '(soegaard))
(define license 'MIT)
(define pkg-desc "An SVG parser and static renderer for Racket")

(define deps
  '("base"
    "draw-lib"
    "net-lib"
    "parsers-lib"
    "pict-lib"))

(define build-deps
  '("draw-doc"
    "pict-doc"
    "racket-doc"
    "rackunit-lib"
    "sandbox-lib"
    "scribble-lib"))

(define scribblings
  '(("scribblings/svg.scrbl" (multi-page))))

(define compile-omit-paths '("docs"))
(define test-omit-paths '("docs"))
