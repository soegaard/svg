#lang scribble/manual
@(require (for-label racket/base
                      racket/draw
                      racket/class
                      racket/contract
                      pict
                      svg)
          scribble/example
          racket/sandbox)

@(define ev (make-base-eval #:lang 'racket/base))
@(ev '(require svg racket/draw racket/class racket/math))


@title{svg: SVG Rendering for Racket}
@author+email["Jens Axel Søgaard" "jensaxel@soegaard.net"]

@italic{Note:}
The @tt{parsers} library and documentation were written with the help of Codex.

@defmodule[svg]

@racketmodname[svg] turns SVG files or strings into Racket @racket[bitmap%] images
or @hyperlink["https://docs.racket-lang.org/pict/index.html"]{@racket[pict]}s.

The @racketmodname[svg] Racket library allows you to read SVG documents and
then draw them with @racketmodname[racket/draw].
The library supports many common static SVG features, including shapes, paths,
colors, gradients, patterns, clipping, masks, text, images, CSS styles, and several filters.
It does not try to run animations or scripts;
it renders one still image.

The renderer covers most of static SVG 1.1 and SVG 2 --- shapes, paths, gradients and patterns,
clipping and masking, markers, text, images, CSS stylesheets
(including SVG2's CSS geometry properties), and a substantial subset of filter effects.

Rendering is built directly on @racketmodname[racket/draw]'s @racket[dc<%>] rather than
through an intermediate representation.

The main omissions are animations, scripting, and interactivity;
this is a static, single-frame renderer.
Other gaps are listed in @secref{scope-and-known-limitations}
at the end of this document.

@table-of-contents[]


@section{Installation}

Install the package with:

@verbatim{raco pkg install svg}

This installs @tt{parsers-lib}, @tt{draw-lib}, @tt{pict-lib}, and the other
declared dependencies automatically.

Then:

@racketblock[(require svg)]

@section{Quick Start}

The four functions you'll likely reach for first are @racket[svg-string->bitmap],
@racket[svg-file->bitmap], @racket[svg-string->pict], and @racket[svg-file->pict]
--- read an SVG document from a string or a file, and get back either a
@racket[bitmap%] or a @racket[pict].

@codeblock{
(require svg racket/class)

(define bm
  (svg-string->bitmap
   #<<SVG
<svg width="160" height="120" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="g" x1="0%" y1="0%" x2="100%" y2="0%">
      <stop offset="0%" stop-color="gold"/>
      <stop offset="100%" stop-color="crimson"/>
    </linearGradient>
  </defs>
  <rect x="10" y="10" width="140" height="60" rx="10" fill="url(#g)"/>
  <circle cx="40" cy="95" r="18" fill="steelblue" stroke="black" stroke-width="2"/>
  <circle cx="80" cy="95" r="18" fill="seagreen" stroke="black" stroke-width="2"/>
  <circle cx="120" cy="95" r="18" fill="orange" stroke="black" stroke-width="2"/>
</svg>
SVG
   ))

(send bm save-file "out.png" 'png)
}

@image["doc-examples/ex1-quickstart.png"]{gradient rounded rect above a row of three colored circles}

Swap @racket[svg-string->bitmap] for @racket[svg-string->pict] and you get a
@racket[pict] instead of a @racket[bitmap%] --- one that composes with
ordinary picts like @racket[disk], @racket[text], @racket[frame], and
@racket[hc-append]/@racket[vc-append], since it's built on @racket[pict]'s own
@racket[dc] constructor:

@racketblock[
(require svg pict)

(define badge (svg-string->pict "...")) (code:comment "same SVG string as above")

(hc-append 16 (text "A pict:" '(bold) 16) (frame badge))
]

@image["doc-examples/ex2-pict-composition.png"]{the same gradient badge, framed, next to a bold text label}

@racket[svg-file->bitmap] and @racket[svg-file->pict] are the file-path
equivalents; use them (rather than reading a file yourself and passing the
string to @racket[svg-string->bitmap]/@racket[svg-string->pict]) whenever the
SVG has relative @tt{<image>} references, since only the file-path versions
know what directory to resolve those against.

Filters, masks, and group opacity all compose the way you'd expect from a
browser --- a @tt{<filter>} with @tt{feDropShadow}, or a @tt{<g mask="...">}
layered with a semi-transparent group, render correctly rather than as a rough
approximation:

@image["doc-examples/ex3-filters.png"]{a purple circle and a coral rounded square, both with soft drop shadows}
@image["doc-examples/ex4-mask-opacity.png"]{a teal rectangle faded left-to-right by a mask, with two overlapping semi-transparent circles composited correctly as one unit above it}

If all you need is one of those four top-level functions, you can stop
reading here. The rest of this document covers the lower-level pieces
(path-data parsing, paint resolution, transform matrices, and so on) that
@racketmodname[svg] also exports, in case you want to reuse a piece of the
pipeline directly --- say, to parse path data for your own purposes, or to
resolve an SVG color string without rendering anything.

@section[#:tag "top-level-rendering"]{Top-Level Rendering}

This is the small set of functions most programs need: parse an SVG document
and get back something you can display or save. Everything else in this
document is either a building block these functions use internally (and
export for reuse) or a lower-level entry point for working with a piece of
the pipeline in isolation.

The two output formats --- @racket[bitmap%] and @racket[pict] --- are not
just two ways of returning the same picture:

@itemlist[
 @item{@bold{@racket[bitmap%]} (@racket[svg-string->bitmap], @racket[svg-file->bitmap])
   rasterizes onto a fresh bitmap sized exactly to the SVG's own width/height,
   with an @bold{opaque white background} --- the right default for "save
   this as a standalone image."}
 @item{@bold{@racket[pict]} (@racket[svg-string->pict], @racket[svg-file->pict],
   @racket[svg-doc->pict]) wraps the same rendering as a self-drawing
   @racket[pict] with a @bold{transparent background}, so it composes
   correctly with other picts around or behind it. Because
   @racket[render-svg-doc!] never assumes @racket[bitmap-dc%] for the
   @racket[dc<%>] it's handed (only for its own private offscreen buffers ---
   mask, filter, pattern, and marker content, which is unrelated), the
   resulting pict can be drawn onto @italic{any} @racket[dc<%>]: a bitmap via
   @racket[pict->bitmap], but also a @racket[pdf-dc%] or
   @racket[post-script-dc%], giving vector output for anything that doesn't
   need mask/filter rasterization. (Masked or filtered elements still
   rasterize internally either way, the same as in any renderer, since those
   effects inherently require pixel buffers --- they'd appear as embedded
   raster images in an otherwise-vector PDF.)}
]

Both families accept either a @bold{string} of SVG source or a @bold{file
path}; the file-path versions additionally know the SVG's own directory,
which matters for resolving relative @tt{<image>} references --- an
@tt{<image href="icon.png">} next to @tt{diagram.svg} only resolves correctly
if you render via @racket[(svg-file->bitmap "diagram.svg")], not by reading
the file yourself and passing its contents to @racket[svg-string->bitmap].

If you need to inspect or reuse a parsed document before rendering it (its
declared width/height, its id table, or its viewBox matrix),
@racket[read-svg-document] and the @tt{svg-doc-*} accessors below let you
separate parsing from rendering.

@defproc[(svg-string->bitmap [s string?]) (is-a?/c bitmap%)]{

Parses @racket[s] as an SVG document and renders it to a freshly-created
@racket[bitmap%], sized to the document's own width and height (each rounded
up to the nearest whole pixel, with a minimum of 1). The bitmap has an opaque
white background.

@codeblock{
(send (svg-string->bitmap
       #<<SVG
<svg width="100" height="100">
  <circle cx="50" cy="50" r="40" fill="crimson"/>
</svg>
SVG
       )
      save-file "circle.png" 'png)
}

@image["doc-examples/ex-circle.png"]{a solid crimson circle on a white background}
}

@defproc[(svg-file->bitmap [path path-string?]) (is-a?/c bitmap%)]{

Like @racket[svg-string->bitmap], but reads the document from @racket[path].
Any relative @tt{<image>} @tt{href} inside the document resolves against
@racket[path]'s own directory (see @racket[current-svg-base-dir]), so prefer
this over reading the file yourself and calling @racket[svg-string->bitmap]
whenever the document might reference local images by relative path.

@racketblock[(svg-file->bitmap "logo.svg")]
}

@defproc[(svg-string->pict [s string?]) pict?]{

Parses @racket[s] as an SVG document and returns a @racket[pict] that draws
it, sized to the document's own width and height. The pict's background is
transparent (unlike @racket[svg-string->bitmap]'s opaque white), so it
composes correctly with other picts.

@racketblock[
(require pict)
(hc-append 10 (svg-string->pict "...") (colorize (disk 20) "orange"))
]

Constructing the pict costs a second, throwaway render as part of
@racket[pict]'s own contract checking (@racket[dc]'s precondition renders once
with a scratch @racket[dc<%>] to confirm the draw procedure restores its
state correctly) --- this is @racket[pict]'s behavior, not something
@racketmodname[svg] adds on top, and it's a one-time cost per pict, not per
subsequent draw.
}

@defproc[(svg-file->pict [path path-string?]) pict?]{

Like @racket[svg-string->pict], but reads the document from @racket[path],
with relative @tt{<image>} references resolved against @racket[path]'s own
directory --- the @racket[pict] analogue of @racket[svg-file->bitmap], for
the same reason (see @racket[current-svg-base-dir]).

@racketblock[(svg-file->pict "logo.svg")]
}

@defproc[(svg-doc->pict [doc svg-doc?] [base-dir (or/c path? #f) #f]) pict?]{

Wraps an already-parsed @racket[svg-doc] (from @racket[read-svg-document]) as
a @racket[pict], without re-parsing. @racket[svg-string->pict] and
@racket[svg-file->pict] are both thin wrappers around this. @racket[base-dir],
if given, is used the same way @racket[current-svg-base-dir] is elsewhere: as
the directory relative @tt{<image>} references in @racket[doc] resolve
against. Passing it here (rather than wrapping the call in
@racket[(parameterize ([current-svg-base-dir ...]) ...)] yourself) matters
because @racket[pict]'s @racket[dc] constructor draws lazily --- the draw
procedure can run well after this call returns, outside any
@racket[parameterize]'s dynamic extent, so @racket[svg-doc->pict]
re-establishes the parameterization itself, every time the pict is actually
drawn.

Use this when you're calling @racket[read-svg-document] yourself anyway ---
for instance, to inspect @racket[svg-doc-width]/@racket[svg-doc-height]
before deciding how to render --- and want to avoid parsing the document
twice.
}

@defproc[(render-svg-doc! [doc svg-doc?] [dc (is-a?/c dc<%>)]) void?]{

Renders an already-parsed @racket[svg-doc] directly onto @racket[dc], applying
the document's own viewBox transform and drawing every element in turn. This
is the function every other rendering entry point in this library eventually
calls; use it directly when you already have a @racket[dc<%>] you want to draw
onto --- an existing bitmap, a canvas, a PDF page --- rather than getting a
fresh bitmap or pict back.

Unlike @racket[svg-doc->pict], this does @bold{not} save or restore the
@racket[dc]'s transformation, smoothing mode, pen, brush, font, or other
drawing state around the call --- it applies the viewBox transform and leaves
it applied, and generally assumes it can freely change @racket[dc]'s state.
If you need the @racket[dc]'s prior state preserved (for instance, because
you're drawing several things onto the same @racket[dc] in sequence), save
and restore it yourself around the call, the way @racket[svg-doc->pict] does
internally.

@racketblock[
(define bm (make-object bitmap% 200 200))
(define dc (new bitmap-dc% [bitmap bm]))
(render-svg-doc! (read-svg-document "<svg>...</svg>") dc)
]
}

@defproc[(read-svg-document [x (or/c string? input-port?)]) svg-doc?]{

Parses @racket[x] (SVG source, as a string or an input port) into an
@racket[svg-doc]: the document's root element, its declared width and height,
a table mapping every @tt{id} attribute in the document to its element (used
to resolve @tt{url(#id)}/@tt{href="#id"} references), its viewBox transform
matrix, and its parsed @tt{<style>} stylesheet (if any). This is the parsing
step that every top-level rendering function performs before rendering; call
it directly when you want to inspect a document (its dimensions, in
particular) before deciding how or whether to render it, or when you want to
render the same parsed document more than once without re-parsing.

Width and height resolve in the following order: the @tt{width}/@tt{height}
attributes if present and not given as a percentage; otherwise the
@tt{viewBox} attribute's width/height, if present; otherwise 300×150 (the CSS
replaced-element default).

@codeblock{
(define doc (read-svg-document #<<SVG
<svg width="640" height="480">...</svg>
SVG
                                ))
(svg-doc-width doc)   ; 640
(svg-doc-height doc)  ; 480
}
}

@deftogether[(@defproc[(svg-doc-width [doc svg-doc?]) real?]
              @defproc[(svg-doc-height [doc svg-doc?]) real?])]{

The document's own width and height, in user units (CSS pixels), resolved as
described under @racket[read-svg-document].
}

@defproc[(svg-doc-id-table [doc svg-doc?]) (hash/c string? any/c)]{

A hash mapping every @tt{id} attribute value found anywhere in the document
to the (xexpr-represented) element that carries it --- the table
@tt{url(#id)}/@tt{href="#id"} references are resolved against during
rendering. Useful if you want to inspect or extract a specific element (a
particular @tt{<symbol>}, gradient, or filter definition) from an
already-parsed document.
}

@defproc[(svg-doc-view-matrix [doc svg-doc?]) (vector/c real? real? real? real? real? real?)]{

The document's root viewBox transform, as a @racket[#(a b c d e f)] vector in
the format @racket[dc<%>]'s own @racket[transform] method accepts
(@racket[x' = a·x + c·y + e], @racket[y' = b·x + d·y + f]) --- the matrix
@racket[render-svg-doc!] applies once, at the very start, before drawing
anything. If the document has no @tt{viewBox}, this is the identity matrix
@racket[#(1 0 0 1 0 0)].
}

@section{Path Data}

These functions parse the @tt{d} attribute's path-data mini-language (the
same grammar used by @tt{<path>}, and by SVG2's @tt{d} CSS property) and turn
it into @racket[dc-path%] objects ready to hand to a @racket[dc<%>]. They
cover the full grammar --- all six drawing commands and their
relative/absolute/repeated forms, elliptical arcs, and the shorthand "smooth"
curve variants --- and were verified against @tt{librsvg} pixel-for-pixel
across each command, not just checked for successful parsing.

The parsing is split into two stages, each independently useful:

@itemlist[
 @item{@bold{@racket[parse-svg-path]} turns a @tt{d} string into a list of
   @italic{path commands} --- a small, inspectable, symbolic representation
   (e.g. @racket['((M (10 20)) (L (30 40)) (Z))]) --- without touching
   @racket[racket/draw] at all. Use this if you want to inspect, transform, or
   generate path data programmatically.}
 @item{@bold{@racket[svg-path->dc-paths]} turns that command list into actual
   @racket[dc-path%] objects. Use this once you have commands (whether from
   @racket[parse-svg-path] or built by hand) and want something to actually
   draw.}
]

@bold{@racket[path-data->dc-paths]} is the two stages composed, for the
common case of going straight from a @tt{d} string to @racket[dc-path%]s.
All three feed the same downstream geometry, shown here once as a filled
triangle:

@image["doc-examples/ex-path-triangle.png"]{a filled, stroked triangle drawn from path data "M0,0 L50,0 L25,50 Z"}

@subsection{The path-command format}

@racket[parse-svg-path] represents each path-data command as a list whose
first element is a symbol naming the command (matching the SVG letter
exactly, including case --- @racket['M] for absolute moveto, @racket['m] for
relative) and whose remaining elements are its arguments:

@tabular[#:sep @hspace[2]
         #:column-properties '(left left left)
         (list (list @bold{Command(s)} @bold{Shape} @bold{Example})
               (list @tt{M, m} "one coordinate pair" @racket[(M (10 20))])
               (list @tt{L, l} "one or more coordinate pairs" @racket[(L (10 20) (30 40))])
               (list @tt{H, h} "one or more bare numbers (x only)" @racket[(H 10 30)])
               (list @tt{V, v} "one or more bare numbers (y only)" @racket[(V 10 30)])
               (list @tt{C, c} "one or more (x1 y1) (x2 y2) (x y) triplets" @racket[(C (1 2) (3 4) (5 6))])
               (list @tt{S, s} "one or more (x2 y2) (x y) pairs" @racket[(S (3 4) (5 6))])
               (list @tt{Q, q} "one or more (qx qy) (x y) pairs" @racket[(Q (3 4) (5 6))])
               (list @tt{T, t} "one or more coordinate pairs" @racket[(T (5 6))])
               (list @tt{A, a} "one or more (rx ry rot large-arc sweep x y)" @racket[(A (10 10 0 0 1 20 20))])
               (list @tt{Z, z} "no arguments" @racket[(Z)]))]

A repeated command (e.g. @racket["L 10 20 30 40"]) produces one list entry
with all of its repetitions as separate arguments, not one entry per
repetition --- @racket['(L (10 20) (30 40))], not @racket['((L (10 20)) (L (30 40)))].

A syntax error partway through a @tt{d} string does not raise --- following
SVG2's own error-handling model, @racket[parse-svg-path] returns everything
successfully parsed @italic{before} the error, discarding only what came at
or after it (this also means a single malformed path can't take down the
rendering of an entire document; see @racket[svg-path->dc-paths] for what
happens to a partially-parsed command list).

@examples[
#:eval ev
(parse-svg-path "M 10 20 L 30 40 Z")
(parse-svg-path "M 0 0 L 3 -4 Z # not valid path syntax")
]

@defproc[(parse-svg-path [x (or/c string? input-port?)]) (listof list?)]{

Parses @racket[x] (path data, as a string or an input port) into a list of
path commands, in the format described above. Accepts both the full grammar
(@tt{M}/@tt{L}/@tt{H}/@tt{V}/@tt{C}/@tt{S}/@tt{Q}/@tt{T}/@tt{A}/@tt{Z}, upper-
and lowercase, repeated forms, comma-@italic{or}-whitespace-separated
arguments) and empty/whitespace-only input (which produces @racket['()]).

@examples[
#:eval ev
(parse-svg-path "M0,0 H100 V100 H0 Z")
]
}

@defproc[(svg-path->dc-paths [commands (listof list?)]) (listof (is-a?/c dc-path%))]{

Converts a list of path commands (in the format @racket[parse-svg-path]
produces) into one or more @racket[dc-path%] objects, ready to draw or
measure via @racket[racket/draw]. Produces more than one @racket[dc-path%]
when the path data has more than one subpath (i.e., more than one
@tt{M}/@tt{m} command) --- draw or fill each one separately, or collect them
with @racket[combined-bounding-box] if you need their combined extent.

@racketblock[
(define paths (svg-path->dc-paths (parse-svg-path "M0,0 L50,0 L25,50 Z")))
(send dc draw-path (first paths) 0 0)
]
}

@defproc[(path-data->dc-paths [d string?]) (listof (is-a?/c dc-path%))]{

Equivalent to @racket[(svg-path->dc-paths (parse-svg-path d))] --- parses
path data straight to @racket[dc-path%] objects, for when you don't need the
intermediate command list.

@racketblock[(path-data->dc-paths "M0,0 L50,0 L25,50 Z")]
}

@defproc[(elliptical-arc-dc-path [x1 real?] [y1 real?] [x2 real?] [y2 real?]
                                  [rx real?] [ry real?] [x-axis-rotation-deg real?]
                                  [large-arc-flag (or/c 0 1)] [sweep-flag (or/c 0 1)])
         (is-a?/c dc-path%)]{

Builds a single @racket[dc-path%] for one elliptical arc segment, from the
SVG path-data @tt{A}/@tt{a} command's own parameterization: start point
@racket[(x1, y1)], end point @racket[(x2, y2)], the ellipse's radii
@racket[rx]/@racket[ry], its rotation in degrees, and the two flags that
disambiguate which of the (up to four) ellipses meeting those constraints to
use. This is the endpoint-to-center conversion the SVG spec itself specifies,
implemented directly (not approximated) --- used internally by
@racket[svg-path->dc-paths] for every @tt{A}/@tt{a} command, and exported in
case you want an arc segment without going through path-data parsing at all.

Degenerate inputs (@racket[rx] or @racket[ry] of @racket[0], or an identical
start and end point) are the caller's responsibility to handle ---
@racket[svg-path->dc-paths] checks for both and substitutes a straight line,
per spec, before ever calling this function; calling it directly with a zero
radius does not raise, but also does not produce a meaningful arc.

@racketblock[(elliptical-arc-dc-path 0 0 50 50 50 50 0 0 1)]

@image["doc-examples/ex-elliptical-arc.png"]{an elliptical arc curving upward between two black endpoint dots}
}

@section{Geometry, Viewports, and Transforms}

This group covers the pieces that turn SVG's various coordinate-system
concepts --- length units, the @tt{transform} attribute, @tt{viewBox}, and
@tt{preserveAspectRatio} --- into plain numbers and the @racket[#(a b c d e f)]
matrix format @racket[dc<%>]'s own @racket[transform] method accepts.

Every matrix in this document and in @racketmodname[svg] uses that same
six-element vector format throughout, matching @racket[dc<%>]'s convention
exactly:

@verbatim{
x' = a·x + c·y + e
y' = b·x + d·y + f
}

so a matrix produced by one of these functions can always be passed directly
to @racket[(send dc transform matrix)].

@defproc[(parse-length [s (or/c string? #f)] [default real? 0]
                        [#:reference reference (or/c real? #f) #f]) real?]{

Parses an SVG/CSS length string --- a number, optionally followed by a unit
(@tt{px}, @tt{pt}, @tt{pc}, @tt{in}, @tt{cm}, @tt{mm}, @tt{em}, or @tt{%})
--- into a plain number of user units (CSS pixels). @tt{em} is treated as a
fixed 16px rather than resolved against the current font size (a disclosed
simplification: @tt{em} in practice is rare outside @tt{font-size} itself,
which this library doesn't parameterize this way). Returns @racket[default]
if @racket[s] is @racket[#f] or doesn't match the length grammar at all.

A percentage resolves against @racket[reference] if one is given
(@racket["50%"] with @racket[reference] @racket[200] gives @racket[100]);
with no @racket[reference], a percentage is treated as a literal number
instead of raising or resolving to @racket[default] (so @racket["50%"] with
no @racket[reference] gives @racket[50]) --- a disclosed simplification for
the cases in this library that don't thread a containing-viewport length
through to resolve percentages precisely.

@examples[
#:eval ev
(parse-length "10px")
(parse-length "1in")
(parse-length "50%" #:reference 200)
(parse-length #f 42)
]
}

@defproc[(parse-transform-list [s (or/c string? #f)]) (listof (cons/c symbol? (listof real?)))]{

Parses an SVG @tt{transform} attribute value --- a space-separated list of
@tt{name(args...)} function calls (@tt{translate}, @tt{scale}, @tt{rotate},
@tt{skewX}, @tt{skewY}, @tt{matrix}) --- into a list of @racket[(name . args)]
pairs, in source order. Doesn't build a matrix itself; combine with the
transform semantics your own code needs, or see the file's internal
@tt{apply-transform-attr!} for how @racketmodname[svg] applies these to a
@racket[dc<%>] (not exported, since it mutates a @racket[dc<%>] directly
rather than returning a value).

@examples[
#:eval ev
(parse-transform-list "translate(10,20) rotate(45)")
]

@image["doc-examples/ex-transform-list.png"]{a faint gray square at its original position, and the same square translated and rotated, in green}

Note on @tt{rotate}: SVG defines a positive angle as clockwise in its y-down
coordinate system. @racket[dc<%>]'s own @racket[rotate] method turns out to
spin the @italic{opposite} direction for a positive angle (confirmed
empirically) --- code building a matrix from this list's @tt{rotate} entries
directly, rather than using @racket[dc<%>]'s @racket[rotate] method, needs to
account for that sign difference to match SVG's convention.
(@racketmodname[svg]'s own internal transform-application code does this
already; it's only a concern if you're building your own matrix from this
parsed list.)
}

@defproc[(parse-preserve-aspect-ratio [s (or/c string? #f)]) any/c]{

Parses a @tt{preserveAspectRatio} attribute value (e.g. @racket["xMidYMid meet"],
@racket["xMinYMax slice"], @racket["none"]) into an opaque value meant only
to be passed to @racket[compute-viewbox-matrix]'s @racket[par] argument ---
there's no public accessor for its fields, and no exported constructor other
than this function. Defaults to @racket["xMidYMid meet"] (SVG's own default)
if @racket[s] is @racket[#f] or empty; the optional leading @racket["defer"]
keyword is accepted and ignored (this library never has more than one
applicable @tt{preserveAspectRatio} in play, so deferring to another one
never applies).

@examples[
#:eval ev
(parse-preserve-aspect-ratio "xMidYMid slice")
(parse-preserve-aspect-ratio #f)
]
}

@defproc[(compute-viewbox-matrix [vb-x real?] [vb-y real?] [vb-w real?] [vb-h real?]
                                  [vp-w real?] [vp-h real?] [par any/c])
         (vector/c real? real? real? real? real? real?)]{

Computes the transform matrix that maps a @tt{viewBox="vb-x vb-y vb-w vb-h"}
coordinate system into a @racket[vp-w]×@racket[vp-h] viewport, honoring
@racket[par]'s alignment and meet-or-slice behavior --- the exact algorithm
the SVG spec itself specifies. This is what @racket[read-svg-document] calls
for the document root, and what @racket[viewport-instantiation-matrix] calls
for nested viewports (@tt{<svg>}, @tt{<symbol>}, @tt{<marker>}, @tt{<pattern>},
@tt{<image>}); call it directly if you're building a custom nested-viewport
mechanism of your own and want the exact same alignment/scaling semantics.

A non-positive @racket[vb-w] or @racket[vb-h] returns the identity matrix (an
invalid viewBox per spec is treated as if there were none).

@examples[
#:eval ev
(compute-viewbox-matrix 0 0 100 100 200 200 (parse-preserve-aspect-ratio #f))
]

A 100×100 @tt{viewBox} mapped into a 140×100 viewport, under
@racket["xMidYMid meet"] (left) versus @racket["xMidYMid slice"] (right) ---
the dashed outline is the viewport; the blue square and red circle are the
viewBox content, identical in both:

@image["doc-examples/ex-viewbox-meet.png"]{meet: the content is scaled to fit entirely within the viewport, letterboxed left and right}
@image["doc-examples/ex-viewbox-slice.png"]{slice: the content is scaled to fill the viewport entirely, cropped left and right}
}

@defproc[(viewport-instantiation-matrix [target-attrs (listof (list/c symbol? string?))]
                                         [override-width (or/c real? #f)]
                                         [override-height (or/c real? #f)])
         (vector/c real? real? real? real? real? real?)]{

Computes the viewBox matrix for an element that establishes its own nested
viewport (a @tt{<symbol>} or @tt{<svg>} referenced via @tt{<use>}, or a
nested @tt{<svg>} directly) --- reading @tt{viewBox}, @tt{width}, @tt{height},
and @tt{preserveAspectRatio} off @racket[target-attrs] (an xexpr-style
attribute list), with @racket[override-width]/@racket[override-height] taking
precedence over the target's own @tt{width}/@tt{height} attributes when given
(used to implement @tt{<use width="..." height="...">} overriding a
referenced @tt{<symbol>}'s own dimensions). Returns the identity matrix if
@racket[target-attrs] has no @tt{viewBox} at all.

@examples[
#:eval ev
(viewport-instantiation-matrix '((viewBox "0 0 100 100") (width "50") (height "50"))
                                #f #f)
]

Uses the exact same mapping algorithm as @racket[compute-viewbox-matrix]
above (see that entry's images) --- the two functions differ only in where
their inputs come from: raw numbers there, an element's own attribute list
here.
}

@section{Paint and Color}

This group resolves SVG/CSS paint and color values --- everything from a
@tt{fill}/@tt{stroke} attribute's string down to a @racket[color%] object or
a reference to a paint server (gradient or pattern) to look up elsewhere.

The central function is @racket[parse-paint], which recognizes every common
CSS color syntax (@tt{#rgb}, @tt{#rrggbb}, @tt{rgb()}/@tt{rgba()},
@tt{hsl()}/@tt{hsla()}, named colors, @tt{currentcolor}) plus SVG's
@tt{url(#id)} paint-server references --- returning either a @racket[color%]
directly, or a @racket[paint-ref] struct for callers to resolve against a
document's id table (@racket[svg-doc-id-table]) themselves, since
@racket[parse-paint] has no access to one on its own.

@defproc[(parse-paint [s (or/c string? #f)] [current-color (or/c (is-a?/c color%) #f) #f])
         (or/c (is-a?/c color%) paint-ref? #f)]{

Parses a @tt{fill}, @tt{stroke}, @tt{stop-color}, or @tt{flood-color}-style
paint value into:

@itemlist[
 @item{@bold{@racket[#f]}, for @racket["none"] or when @racket[s] is itself @racket[#f];}
 @item{@bold{a @racket[color%]}, for @tt{#rgb}, @tt{#rrggbb},
   @tt{rgb(...)}/@tt{rgba(...)}, @tt{hsl(...)}/@tt{hsla(...)}, a named CSS
   color, or @racket["currentcolor"] (which resolves to @racket[current-color],
   or black if @racket[current-color] is @racket[#f]);}
 @item{@bold{a @racket[paint-ref]}, for a @racket["url(#id) fallback"]
   reference --- resolving the reference itself (looking @racket[id] up and
   building a gradient or pattern brush from it) is the caller's job, since
   @racket[parse-paint] has no document context to resolve it against.
   @racket[fallback], if the @tt{url(...)} has a trailing color/keyword after
   it, is itself already fully parsed (i.e. a @racket[color%], @racket[#f],
   or another @racket[paint-ref], never a raw string).}
]

Named colors use Racket's own X11-derived color database, except for 16
CSS1/HTML4 keyword names confirmed to differ from what CSS/SVG actually
specify for the same name (most famously @racket["purple"], but also
@racket["green"], @racket["gray"], @racket["maroon"], and @racket["navy"])
--- those 16 are overridden to their correct CSS values; every other name
(including the full CSS Color 4 extended palette) passes through to the
color database as-is.

@racket[url(...)] is recognized whether its argument is unquoted
(@racket["url(#id)"]) or quoted (@racket["url('#id')"]/@racket["url(\"#id\")"]),
and only leading/trailing whitespace around the reference as a whole is
stripped --- whitespace @italic{inside} the fragment id itself
(@racket["url(' # x ')"]) is preserved verbatim as part of the id, which will
then simply fail to match any real id and fall through to the fallback,
since @racket[" x"] (with a leading space) is a different id from @racket["x"].

@racketblock[
(parse-paint "#ff0000")               (code:comment "(is-a? color%), red")
(parse-paint "rgba(0, 0, 0, 0.5)")    (code:comment "(is-a? color%), 50%-alpha black")
(parse-paint "none")                  (code:comment "#f")
(parse-paint "url(#grad) blue")       (code:comment "(paint-ref \"grad\" (is-a? color%))")
]

Four colors resolved by @racket[parse-paint] --- a hex code, an
@racket[rgba(...)] with alpha, a named color, and @racket[hsl(...)]:

@image["doc-examples/ex-parse-paint.png"]{four rectangles: tomato red, a translucent blue-purple, sea green, and a purple from hsl()}
}

@defstruct[paint-ref ([id string?] [fallback (or/c (is-a?/c color%) paint-ref? #f)])]{

Represents an unresolved @tt{url(#id)} paint reference, as returned by
@racket[parse-paint]. @racket[id] is the fragment identifier (without the
leading @tt{#}) to look up in a document's id table; @racket[fallback] is the
already-parsed paint to fall back to if @racket[id] doesn't resolve to a
usable gradient or pattern (a missing id, an id that resolves to some other
kind of element, or --- for a gradient specifically --- one with no stops or
a degenerate geometry, such as a @tt{gradientTransform} that collapses it to
a single point).

@racketblock[
(paint-ref-id (parse-paint "url(#g) red"))       (code:comment "\"g\"")
(paint-ref-fallback (parse-paint "url(#g) red")) (code:comment "(is-a? color%), red")
]
}

@defproc[(parse-opacity [s (or/c string? #f)] [default (real-in 0 1) 1]) (real-in 0 1)]{

Parses an @tt{opacity}/@tt{fill-opacity}/@tt{stroke-opacity}/@tt{stop-opacity}/
@tt{flood-opacity}-style value --- a bare number or a percentage --- clamped
to @racket[[0, 1]]. Returns @racket[default] if @racket[s] is @racket[#f] or
doesn't parse as a number.

@examples[
#:eval ev
(parse-opacity "0.5")
(parse-opacity "50%")
(parse-opacity "150%")
(parse-opacity #f)
]
}

@defproc[(resolve-gradient-stops [node any/c]) (listof (cons/c (real-in 0 1) (is-a?/c color%)))]{

Reads a @tt{<linearGradient>} or @tt{<radialGradient>} element's @tt{<stop>}
children (their @tt{offset}/@tt{stop-color}/@tt{stop-opacity}, from either
presentation attributes or an inline @tt{style=""}) into a list of
@racket[(offset . color)] pairs, each color's alpha already combined with its
@tt{stop-opacity}, and offsets normalized to be non-decreasing (per spec ---
a @tt{<stop>} with a smaller offset than the one before it is clamped up to
match). If @racket[node] has no @tt{<stop>} children of its own, its stops
are inherited from whatever element its own @tt{href}/@tt{xlink:href} points
to (a common real-world pattern: define one gradient's stops once and reuse
them across several gradients that vary only in geometry) --- which means
this function consults the ambient @racket[current-id-table] parameter (not
itself exported) to resolve that reference, so it needs to be called during
rendering (inside @racket[render-svg-doc!]/@racket[render-node!]'s dynamic
extent) rather than standalone against an arbitrarily-obtained gradient
element.

@racketblock[
(resolve-gradient-stops
 '(linearGradient ()
   (stop ((offset "0") (stop-color "red")))
   (stop ((offset "1") (stop-color "blue") (stop-opacity "0.5")))))
(code:comment "(list (cons 0.0 (is-a? color%)) (cons 1.0 (is-a? color%)))")
]

The three stops above, rendered as an actual gradient bar (gold at 0, orange-red
at 0.5, purple at 60%-opacity at 1):

@image["doc-examples/ex-gradient-stops.png"]{a horizontal gradient bar from gold through orange-red to a translucent purple}
}

@defproc[(combined-bounding-box [paths (listof (is-a?/c dc-path%))]) (list/c real? real? real? real?)]{

Returns the union bounding box across all of @racket[paths], as
@racket[(list x y w h)] --- @racket[(list 0. 0. 0. 0.)] if @racket[paths] is
empty. Used internally to resolve @tt{objectBoundingBox}-relative
gradient/pattern coordinates and clip-path regions against a shape's own
geometry (always the shape's @italic{fill} geometry per spec, regardless of
whether the paint server is actually being used for @tt{fill} or
@tt{stroke}); exported since it's a generally useful thing to compute given
any list of @racket[dc-path%]s, for instance the ones @racket[svg-path->dc-paths]
returns for a multi-subpath shape.

@examples[
#:eval ev
(combined-bounding-box (path-data->dc-paths "M0,0 L50,0 L25,50 Z"))
]

The same curved shape from earlier, with its bounding box outlined:

@image["doc-examples/ex-bounding-box.png"]{a rounded blue shape inside a dashed rectangle marking its bounding box}
}

@section{Stroke Geometry}

@racket[racket/draw]'s @racket[pen%] has no concept of a dash pattern at all,
so drawing a dashed stroke means computing the dashed sub-segments directly:
flatten a @racket[dc-path%]'s curves into a polyline, then split that
polyline into the "on" runs a dash pattern would draw.
@racket[dc-path->polylines] and @racket[dash-split-polyline] are the two
pieces of that pipeline, exported separately in case you want polyline
flattening or dash-splitting without the other.

@racket[parse-linecap], @racket[parse-linejoin], and @racket[parse-clip-rule]
are small, self-contained parsers converting SVG's own attribute-value
keywords into the symbols @racket[racket/draw] expects.

@defproc[(parse-dasharray [s (or/c string? #f)]) (or/c (listof (and/c real? (not/c negative?))) #f)]{

Parses a @tt{stroke-dasharray} value --- a comma-@italic{or}-whitespace-separated
list of lengths --- into a list of non-negative numbers, always of
@bold{even} length (an odd-length list is doubled, per spec, so
@racket["5 10 15"] becomes @racket['(5 10 15 5 10 15)]). Returns @racket[#f]
for @racket["none"], empty input, a list containing a negative number, or a
list that sums to zero --- all of which mean "no dashing, draw a normal solid
stroke" per spec, which is exactly the signal @racket[#f] is meant to carry
to a caller deciding whether to dash a stroke at all.

@examples[
#:eval ev
(parse-dasharray "5,10")
(parse-dasharray "5 10 15")
(parse-dasharray "none")
(parse-dasharray "-1,2")
]

A solid line, and the same line dashed via @racket[(parse-dasharray "18,10")]
fed to @racket[dash-split-polyline] below:

@image["doc-examples/ex-dasharray.png"]{a solid horizontal line above a dashed horizontal line}
}

@defproc[(parse-linecap [s string?]) (or/c 'round 'projecting 'butt)]{

Parses a @tt{stroke-linecap} value (@racket["round"], @racket["square"], or
@racket["butt"]) into the symbol @racket[pen%] expects --- note that SVG's
@racket["square"] corresponds to @racket[racket/draw]'s @racket['projecting],
not a symbol named @racket['square]. Anything other than @racket["round"] or
@racket["square"] (including an absent/unrecognized value) gives
@racket['butt], SVG's default.

Butt, round, and square caps on three identical, otherwise-unstyled segments
(the thin line below each shows where the segment's true endpoints are):

@image["doc-examples/ex-linecap.png"]{three thick horizontal segments with butt, round, and square end caps respectively}
}

@defproc[(parse-linejoin [s string?]) (or/c 'round 'bevel 'miter)]{

Parses a @tt{stroke-linejoin} value (@racket["round"], @racket["bevel"], or
@racket["miter"]) into the symbol @racket[pen%] expects. Anything other than
@racket["round"] or @racket["bevel"] gives @racket['miter], SVG's default.
(There is no corresponding @tt{parse-stroke-miterlimit} support:
@racket[racket/draw]'s @racket[pen%] exposes no miter-limit control at all,
so @tt{stroke-miterlimit} has no effect anywhere in this library regardless
of value.)

Miter, round, and bevel joins on the same corner:

@image["doc-examples/ex-linejoin.png"]{three identical sharp corners with miter (pointed), round, and bevel (flat-cut) joins respectively}
}

@defproc[(parse-clip-rule [s (or/c string? #f)]) (or/c 'odd-even 'winding)]{

Parses a @tt{fill-rule}/@tt{clip-rule} value into the symbol
@racket[dc-path%]'s own fill-rule argument expects: @racket["evenodd"] gives
@racket['odd-even]; anything else (including @racket["nonzero"] and an
absent value) gives @racket['winding], the SVG default.

Two overlapping circles, filled as one path, under @racket['winding]
(left: both circles fully filled, since the overlap is still covered at
least once in the same winding direction) versus @racket['odd-even] (right:
the overlap is left unfilled, since it's covered an even number of times):

@image["doc-examples/ex-clip-rule-nonzero.png"]{two overlapping circles, fully filled as one solid blob}
@image["doc-examples/ex-clip-rule-evenodd.png"]{the same two overlapping circles, with the overlapping region unfilled, showing as a hole}
}

@defproc[(dc-path->polylines [p (is-a?/c dc-path%)] [curve-samples exact-positive-integer? 16])
         (listof (listof (cons/c real? real?)))]{

Flattens @racket[p] --- however it was built (@racket[line-to],
@racket[curve-to], the native @racket[.arc], or
@racket[.ellipse]/@racket[.rounded-rectangle]) --- into one polyline per
subpath, each a list of @racket[(x . y)] points. Works uniformly across every
shape because @racket[dc-path%]'s own @racket[get-datum] turns out to
represent all of them, once built, using only two segment shapes --- a bare
waypoint or a 6-element cubic Bézier control-point vector --- so curved
segments are sampled at @racket[curve-samples] evenly-spaced points along the
Bézier (higher values give a smoother approximation at the cost of more
points).

A closed subpath's polyline always ends by repeating its own first point
(closing the loop explicitly), even if the underlying path segments didn't
already return to their exact starting coordinates.

@examples[
#:eval ev
(dc-path->polylines (car (path-data->dc-paths "M0,0 L50,0 L25,50 Z")))
]

A curve (light gray) with its flattened sample points overlaid as dots:

@image["doc-examples/ex-polylines.png"]{a smooth curve with a dozen evenly-spaced red dots marking its polyline approximation}
}

@defproc[(dash-split-polyline [pts (listof (cons/c real? real?))]
                               [pattern (listof (and/c real? (not/c negative?)))]
                               [offset real?])
         (listof (listof (cons/c real? real?)))]{

Splits polyline @racket[pts] into the "on" sub-polylines a dash
@racket[pattern] (an even-length list of alternating on/off lengths, as
@racket[parse-dasharray] produces) would draw, starting @racket[offset] units
into the pattern --- the @tt{stroke-dashoffset} value, which may be negative
or larger than the pattern's total length (both wrap correctly). Returns
@racket['()] if @racket[pts] has fewer than two points (nothing to dash).

@examples[
#:eval ev
(dash-split-polyline '((0 . 0) (100 . 0)) '(10 5) 0)
]

See @racket[parse-dasharray] above for this function's own visual example ---
the two are almost always used together.
}

@section{CSS Styling}

@racketmodname[svg] resolves a full CSS cascade for both paint properties
(@tt{fill}, @tt{stroke}, @tt{opacity}, ...) and SVG2's "geometry properties"
(@tt{cx}, @tt{r}, @tt{x}, @tt{width}, @tt{d}, ...) --- inline @tt{style=""},
@tt{<style>} stylesheet rules (matched by type/class/id/universal/attribute
selectors, descendant and child combinators, with real CSS specificity and
@tt{!important}), and plain presentation attributes, in that priority order.
That whole mechanism is internal (it depends on parsing machinery from the
@tt{parsers/css} package and on rendering-time context --- the current
element's ancestor chain --- that only exists during an active render),
except for one small, standalone piece exported because it's independently
useful: parsing an inline @tt{style=""} attribute's own text into a lookup
table.

@defproc[(parse-style-attr [s (or/c string? #f)]) (hash/c string? (cons/c string? boolean?))]{

Parses an inline @tt{style="..."} attribute's value --- a semicolon-separated
list of @tt{property: value} declarations --- into a hash from (lowercased,
trimmed) property name to @racket[(cons value important?)], tracking a
trailing @tt{!important} on any declaration the same way a @tt{<style>}
stylesheet rule's own declarations are tracked internally (so an inline
@tt{!important} can be recognized as outranking even a stylesheet's own
@tt{!important} rule, which is how the full cascade orders them). A
malformed declaration (missing a colon, empty) is skipped rather than
raising.

@examples[
#:eval ev
(parse-style-attr "fill: red; stroke: blue !important")
]
}

@section[#:tag "text"]{Text}

@racketmodname[svg] renders @tt{<text>}/@tt{<tspan>} by converting text to path
geometry via @racket[dc-path%]'s own @racket[text-outline] (not
@racket[dc<%>]'s @racket[draw-text]), so text gets the same
gradient/pattern/dasharray/opacity support as any other shape, for free.
@tt{<textPath>} (laying text along a referenced shape's own geometry, via an
arc-length parameterization of the path) and @tt{xml:space="preserve"}
(disabling the default whitespace-collapsing behavior, with correct
XML-style inheritance down the tree) are both supported as well. None of
this rendering logic is exported directly, though --- there is no single
"parse/render a whole @tt{<text>} element" function in this API, since it
involves rendering-time context (pen position or arc-length position along a
path, inherited font state) beyond what a standalone parser can usefully
capture. The functions in this group are the small, self-contained parsers
that turn SVG/CSS text-related attribute values into the symbols and
structures @racket[font%] and the rest of that internal pipeline expect.

@racket[parse-number-list] and @racket[collapse-whitespace], while used
elsewhere in the file for text-specific purposes (@tt{<text>}'s
@tt{x}/@tt{y}/@tt{dx}/@tt{dy} attributes, which accept a list of numbers ---
one per character --- and collapsing runs of whitespace in text content per
SVG's whitespace-handling rules), are general-purpose enough to be useful
outside text too; @racket[parse-number-list] in particular is reused for
filter primitive attributes like @tt{stdDeviation} and @tt{radius} elsewhere
in the file.

@defproc[(parse-font-family [s (or/c string? #f)]) (values (or/c string? #f) symbol?)]{

Parses a @tt{font-family} value --- a comma-separated list such as
@racket["Georgia, 'Times New Roman', serif"] --- into two values: a specific
font @bold{face} (the first non-generic name in the list, quotes stripped,
or @racket[#f] if the list is all generic keywords), and a @bold{family}
(one of @racket['roman], @racket['swiss], @racket['modern], @racket['script],
@racket['decorative], or @racket['default]) --- the two pieces
@racket[font%]'s constructor wants separately, since it distinguishes an
actual installed font name from an abstract fallback bucket. The family is
taken from the first CSS generic keyword found anywhere in the list
(@racket["serif"] → @racket['roman], @racket["sans-serif"] → @racket['swiss],
@racket["monospace"] → @racket['modern], @racket["cursive"] → @racket['script],
@racket["fantasy"] → @racket['decorative]), defaulting to @racket['default]
if none appears.

@examples[
#:eval ev
(parse-font-family "Georgia, serif")
(parse-font-family "sans-serif")
(parse-font-family #f)
]

Text rendered with the results of @racket[parse-font-family]/
@racket[parse-font-weight]/@racket[parse-font-style] --- normal, bold, and
italic:

@image["doc-examples/ex-font-styles.png"]{the words Normal, Bold, and Italic, each rendered in its own named style}
}

@defproc[(parse-font-weight [s (or/c string? #f)]) (or/c 'normal 'bold exact-integer?)]{

Parses a @tt{font-weight} value: @racket["bold"]/@racket["normal"] give the
matching symbol; a numeric CSS weight (e.g. @racket["600"]) is passed through
as an integer, since @racket[racket/draw]'s @racket[font%] accepts an integer
weight directly rather than only the two named levels. Anything else
(including an absent value) gives @racket['normal].
}

@defproc[(parse-font-style [s (or/c string? #f)]) (or/c 'normal 'italic 'slant)]{

Parses a @tt{font-style} value: @racket["italic"] gives @racket['italic],
@racket["oblique"] gives @racket['slant] (the symbol @racket[font%] uses for
the same concept), anything else gives @racket['normal].
}

@defproc[(parse-text-anchor [s (or/c string? #f)]) (or/c 'start 'middle 'end)]{

Parses a @tt{text-anchor} value (@racket["start"], @racket["middle"], or
@racket["end"]) into the matching symbol; anything else (including an absent
value) gives @racket['start], SVG's default.

The same text, anchored @racket['start], @racket['middle], and @racket['end]
relative to the same reference point (the black dot; the dashed line marks
its x position):

@image["doc-examples/ex-text-anchor.png"]{three lines of text, each positioned differently relative to an identical reference dot -- starting at it, centered on it, and ending at it}
}

@defproc[(parse-number-list [s (or/c string? #f)]) (listof real?)]{

Parses a comma-@italic{or}-whitespace-separated list of numbers --- the
format used by @tt{<text>}'s @tt{x}/@tt{y}/@tt{dx}/@tt{dy} attributes, and by
filter-primitive numeric attributes like @tt{stdDeviation} and @tt{radius}
(which accept either one number or two, for separate x/y values). Non-numeric
tokens are silently dropped rather than raising; @racket[#f] or an
empty/whitespace-only string give @racket['()].

@examples[
#:eval ev
(parse-number-list "1, 2  3,4")
(parse-number-list "5")
(parse-number-list #f)
]
}

@defproc[(collapse-whitespace [s string?]) string?]{

Collapses every run of one or more spaces, tabs, carriage returns, or
newlines in @racket[s] into a single space --- SVG's default
@tt{xml:space="default"} whitespace handling for text content ---
@bold{without} trimming leading or trailing whitespace (trimming is handled
separately, only at the true start of a whole @tt{<text>} subtree, since a
leading space on an inner @tt{<tspan>} still needs to be preserved as the
word-separator it is when concatenated after a previous run of text).

@examples[
#:eval ev
(collapse-whitespace "a   b\n\tc")
]
}

@section{Markers}

SVG markers (@tt{<marker>}, placed via
@tt{marker-start}/@tt{marker-mid}/@tt{marker-end} or the @tt{marker}
shorthand) are positioned at a shape's @bold{vertices} ---
moveto/lineto/curveto/arc endpoints, not curve control points --- and
oriented along the tangent direction(s) of whatever segment(s) meet there.
This group is the vertex-and-tangent extraction and orientation-angle math
behind that placement, reusing the same @racket[get-datum]-based technique
@racket[dc-path->polylines] uses (@racket[racket/draw] represents every
built shape using only two segment shapes, so no separate arc-tangent math
is needed even for native @racket[.arc]/@racket[.ellipse] geometry).

@defstruct[vertex ([x real?] [y real?] [in-angle (or/c real? #f)] [out-angle (or/c real? #f)])]{

One vertex of a flattened path: its position @racket[(x, y)], and the
tangent angle (in radians, @racket[dc<%>]'s own clockwise-in-y-down
convention) of the segment arriving at it (@racket[in-angle]) and the
segment leaving it (@racket[out-angle]) --- either is @racket[#f] if this
vertex is an endpoint of an open subpath with no segment on that side. A
closed subpath that doesn't already loop back to its own starting point gets
an implicit closing vertex added (matching SVG's own treatment of
@tt{Z}/@tt{z} as generating its own vertex), consistent with how
@racket[dc-path->polylines] closes a polyline's loop explicitly too.

A zigzag path with each of its vertices marked:

@image["doc-examples/ex-vertices.png"]{a zigzag line with a red dot at each of its four vertices}
}

@defproc[(dc-path->vertices [p (is-a?/c dc-path%)]) (listof vertex?)]{

Extracts every vertex of @racket[p] (across all of its subpaths), in order,
as described above. This is what @racketmodname[svg] calls internally to decide
where to place @tt{marker-start}/@tt{marker-mid}/@tt{marker-end} instances
along a @tt{<path>}, @tt{<line>}, @tt{<polyline>}, or @tt{<polygon>}.

@examples[
#:eval ev
(dc-path->vertices (car (path-data->dc-paths "M0,0 L100,0")))
]
}

@defproc[(average-angle [a1 real?] [a2 real?]) real?]{

Averages two angles @racket[a1]/@racket[a2] (radians), correctly across the
wraparound at ±180°, where a naive @racket[(/ (+ a1 a2) 2)] would fail
(averaging 179° and −179° should give ~180°, not 0°). Implemented by summing
the two angles' unit vectors and taking the resulting direction; if they
point exactly opposite each other (an ambiguous bisector), returns
perpendicular to @racket[a1] as a reasonable, consistent convention rather
than an arbitrary one. This is what @racket[marker-angle-degrees] uses to
compute @tt{orient="auto"}'s bisector at a vertex where both an incoming and
an outgoing tangent exist.

@examples[
#:eval ev
(average-angle 0 0)
(radians->degrees (average-angle (degrees->radians 179) (degrees->radians -179)))
]

Two tangent directions (blue: incoming, green: outgoing) and their bisector
(red) at a vertex:

@image["doc-examples/ex-average-angle.png"]{three rays from a common point: one blue, one green, and their red bisector between them}
}

@defproc[(marker-angle-degrees [v vertex?] [orient (or/c real? 'auto 'auto-start-reverse)]
                                [is-start? boolean?])
         real?]{

Computes the angle (in degrees) to rotate a marker instance placed at vertex
@racket[v], given its @racket[orient] (as @racket[parse-marker-orient]
returns it) and whether this is the path's @tt{marker-start} vertex
specifically (@racket[is-start?]). A numeric @racket[orient] is returned
as-is; @racket['auto] gives the bisector of @racket[v]'s
@racket[in-angle]/@racket[out-angle] (via @racket[average-angle]), or
whichever one of the two exists at an open path's endpoint;
@racket['auto-start-reverse] is the same, plus 180° when @racket[is-start?]
is true --- so a single arrowhead marker used as both @tt{marker-start} and
@tt{marker-end} points consistently "into" the line at both ends rather than
the same nominal direction at both.
}

@defproc[(parse-marker-orient [s (or/c string? #f)]) (or/c real? 'auto 'auto-start-reverse)]{

Parses a @tt{<marker>}'s @tt{orient} attribute: @racket["auto"] and
@racket["auto-start-reverse"] give the matching symbol; a numeric angle (in
degrees, with or without a trailing @tt{deg} unit specifier being ignored
since only the leading number is read) gives that number; anything else
(including an absent value) gives @racket[0].

@examples[
#:eval ev
(parse-marker-orient "auto")
(parse-marker-orient "45")
(parse-marker-orient #f)
]

Arrowhead markers placed at each vertex of a curve, oriented via
@racket[marker-angle-degrees] with @racket[orient='auto] --- each arrow
points along the curve's own tangent direction at that point:

@image["doc-examples/ex-marker-orient.png"]{a curved line with an arrowhead at each end, both pointing along the curve's own tangent direction}
}

@section{Images}

@tt{<image>} support loads a local file or a base64 @tt{data:} URI into a
@racket[bitmap%], then fits it into its declared viewport the same way a
nested viewBox does (reusing @racket[compute-viewbox-matrix]). Remote
@tt{http(s)://} (or any other URI scheme) references are deliberately never
fetched --- a privacy/SSRF policy decision, not a missing feature --- and a
plain, non-base64-encoded @tt{data:} URI (e.g.
@tt{data:image/svg+xml,<svg>...</svg>}) isn't decoded either (a disclosed,
narrower gap). Loading an SVG file itself as an @tt{<image>} source (rather
than a raster PNG/JPEG) is also not supported.

@defproc[(load-image-bitmap [href string?]) (or/c (is-a?/c bitmap%) #f)]{

Loads the bitmap an @tt{<image>}'s @tt{href} (or @tt{xlink:href}) refers to,
or returns @racket[#f] if it can't be loaded for any reason --- a @tt{data:}
URI recognized but not base64-encoded, a remote (@tt{scheme://}) reference, a
relative local path that doesn't resolve against @racket[current-svg-base-dir],
a missing file, or image bytes the underlying codec can't decode
(@racket[bitmap%]'s own @racket[read-bitmap] doesn't raise on garbage image
data; it silently returns a broken 1×1 bitmap, which this function detects
via @racket[ok?] and treats the same as any other failure). Never raises.

A @tt{data:image/...;base64,...} URI is decoded directly. Anything matching
@tt{scheme://} for any scheme is treated as a remote reference and always
returns @racket[#f] --- deliberately, this library never fetches network
resources. Anything else is treated as a local file path: percent-decoded,
and resolved against @racket[current-svg-base-dir] if it's relative and that
parameter is set.

@racketblock[
(load-image-bitmap "data:image/png;base64,iVBORw0KGgo...")
(load-image-bitmap "icon.png")                    (code:comment "relative to current-svg-base-dir, if set")
(load-image-bitmap "https://example.com/x.png")   (code:comment "#f -- never fetched")
]

A bitmap loaded via @racket[load-image-bitmap] and drawn onto a fresh dc:

@image["doc-examples/ex-load-image.png"]{a small gold circle bitmap, framed with a thin black border}
}

@defparam[current-svg-base-dir base-dir (or/c path? #f)]{

A parameter holding the directory relative @tt{<image>} @tt{href}s resolve
against. @racket[svg-file->bitmap], @racket[svg-file->pict], and
@racket[svg-doc->pict] (when given its own @racket[base-dir] argument) all
set this to the SVG file's own directory around rendering;
@racket[svg-string->bitmap]/@racket[svg-string->pict] don't set it at all
(there's no file, and thus no directory, to resolve against), so a relative
@tt{<image>} reference inside a string-sourced document simply won't resolve
--- an absolute path still works either way, regardless of how the document
was loaded.

@racketblock[
(parameterize ([current-svg-base-dir (string->path "/home/user/icons/")])
  (load-image-bitmap "logo.png"))  (code:comment "resolves to /home/user/icons/logo.png")
]
}

@section{Filter and Color-Space Utilities}

SVG's @tt{<filter>} primitives (@tt{feGaussianBlur}, @tt{feColorMatrix},
@tt{feComposite}, and the rest) all operate on premultiplied-alpha ARGB
pixel buffers in @bold{linearRGB} color space, per spec --- a real, visible
difference from the sRGB bytes a @racket[bitmap%] actually stores (confirmed:
doing @tt{feColorMatrix}'s math directly on sRGB bytes produced results
measurably different from a reference renderer). The functions in this group
are the color-space-conversion and premultiplication building blocks that
make that correct, exported in case you're working with ARGB pixel buffers
yourself (from @racket[bitmap%]'s own
@racket[get-argb-pixels]/@racket[set-argb-pixels]) and want the same
conversions.

All of the pixel-buffer functions here operate on a @racket[bytes?] buffer in
the same 4-bytes-per-pixel @tt{[A, R, G, B, A, R, G, B, ...]} layout
@racket[get-argb-pixels]/@racket[set-argb-pixels] use.

@defproc[(ambient-scale-factor [dc (is-a?/c dc<%>)]) real?]{

Extracts a single, representative uniform scale factor from @racket[dc]'s
current transformation --- the factor a filter primitive's user-space length
parameters (@tt{stdDeviation}, @tt{radius}, @tt{dx}/@tt{dy}) need to be
multiplied by to convert them into device pixels for buffer-based
operations. Computed as the length a unit vector along the local +x axis
maps to under @racket[dc]'s current transformation.

This is exact, not merely approximate, for any @racket[dc<%>] whose current
transformation was built purely from @racket[translate]/@racket[scale]/
@racket[transform] calls (never @racket[dc<%>]'s own @racket[rotate]) ---
confirmed by checking empirically that those three methods always compose
into @racket[get-transformation]'s sub-matrix rather than its separate
origin/scale/rotation fields. If you've applied a rotation to @racket[dc]
via some other means before calling this, the result may not reflect that
rotation's effect on scale correctly.

@examples[
#:eval ev
(define dc (new bitmap-dc% [bitmap (make-object bitmap% 10 10)]))
(ambient-scale-factor dc)
(send dc scale 2.5 2.5)
(ambient-scale-factor dc)
]
}

@defproc[(premultiply! [buf bytes?]) void?]{

Converts @racket[buf] @bold{in place} from straight (unpremultiplied) to
premultiplied alpha: each pixel's R/G/B is multiplied by its own A/255.
Premultiplied alpha is the correct space for blurring (straight-color
blurring produces dark fringing at partially-transparent edges) and for
Porter-Duff compositing operators alike.

Blurring across a hard opaque/transparent edge, done two ways --- naively,
by blurring straight (unpremultiplied) color directly, versus correctly, by
calling @racket[premultiply!] first (and @racket[unpremultiply-in-place!]
after): the naive version darkens noticeably near the edge, since it
effectively blends real color with "phantom black" from the transparent
side; the premultiplied version doesn't.

@image["doc-examples/ex-premultiply.png"]{two blue-to-black horizontal gradients; the top one, blurred as straight color, is visibly darker near the transition than the bottom one, blurred correctly via premultiplication}
}

@defproc[(unpremultiply-in-place! [buf bytes?]) void?]{

The inverse of @racket[premultiply!], also in place: divides each pixel's
R/G/B by its own A/255 (dividing by 255/A, equivalently), leaving a
fully-transparent pixel's (A=0) color channels untouched (there's no
meaningful "straight color" to recover for a pixel with zero coverage) ---
the format @racket[set-argb-pixels] expects, matching what
@racket[get-argb-pixels] itself produces. Because the underlying arithmetic
uses integer division, a @racket[premultiply!]/@racket[unpremultiply-in-place!]
round trip is not guaranteed to reproduce the exact original bytes --- expect
agreement within ±1 per channel, not bit-for-bit equality.

@examples[
#:eval ev
(define buf (bytes 128 200 100 50))
(premultiply! buf)
(bytes->list buf)
(unpremultiply-in-place! buf)
(bytes->list buf)
]
}

@deftogether[(@defthing[srgb->linear-table (vectorof byte?)]
              @defthing[linear->srgb-table (vectorof byte?)])]{

Precomputed 256-entry lookup tables implementing the standard IEC 61966-2-1
sRGB↔linearRGB gamma conversion, indexed directly by a byte value
(@racket[(vector-ref srgb->linear-table 128)] gives the linearRGB equivalent
of sRGB byte 128). Precomputing these as tables (rather than calling
@racket[expt] per pixel per channel) matters because they're applied to
every R/G/B byte of a filter's @tt{SourceGraphic} at the very start of a
filter chain, and to every byte of the final result at the very end --- both
endpoints operate on @bold{straight} (non-premultiplied) color, so a caller
applying these directly to a premultiplied buffer will get an incorrect
result; convert before premultiplying and after unpremultiplying, never on a
premultiplied buffer directly.

@examples[
#:eval ev
(vector-ref srgb->linear-table 128)
(vector-ref linear->srgb-table 55)
]

The classic demonstration of why this matters: averaging black (0) and white
(255) naively in sRGB byte space gives 127, but averaging their
@bold{linear} equivalents and converting back gives a noticeably lighter 188
--- gamma-correct blending is not the same as byte-space blending:

@image["doc-examples/ex-srgb-linear.png"]{two gray bars; the top (naive byte average) is a medium gray, the bottom (gamma-correct average) is noticeably lighter}
}

@section[#:tag "scope-and-known-limitations"]{Scope and Known Limitations}

@racketmodname[svg] covers most of static SVG 1.1/2 rendering to a genuinely
deep level --- full path-data and transform grammars, a real paint model
(gradients, patterns, @tt{objectBoundingBox}, and both able to paint strokes
as well as fills), clipping and masking, markers (including @tt{paint-order}
and the @tt{context-fill}/@tt{context-stroke} paint keywords),
text-as-path-geometry including @tt{<textPath>} and @tt{xml:space="preserve"},
@tt{textLength}/@tt{lengthAdjust}, CSS @tt{inline-size}/@tt{shape-inside}
text wrapping, @tt{<image>}, a CSS engine with real specificity and
@tt{!important} (including SVG2's CSS geometry properties), true (not
approximated) group opacity, @tt{mix-blend-mode}, and essentially the full
SVG filter primitive set --- @tt{feGaussianBlur}, @tt{feOffset},
@tt{feColorMatrix}, @tt{feFlood}, @tt{feMerge}, @tt{feComposite},
@tt{feBlend}, @tt{feComponentTransfer}, @tt{feMorphology}, @tt{feDropShadow},
@tt{feConvolveMatrix}, @tt{feDisplacementMap}, @tt{feImage},
@tt{feTurbulence}, @tt{feDiffuseLighting}/@tt{feSpecularLighting}, and
@tt{feTile}. It has been cross-validated pixel-for-pixel against
@tt{librsvg} throughout its own development --- except where @tt{librsvg}
itself turned out to have no usable reference to check against (see below)
--- and against the subset of the Web Platform Tests SVG suite that's
expressible as a static reftest (no live DOM, no script) --- 243 such tests,
currently passing about 60%, with most of the remainder attributable to the
specific gaps below (several of which --- full bidirectional text, vertical
writing modes, CJK line-breaking, arbitrary-shape text flow --- are
substantial features genuinely out of scope) rather than to unexplained
discrepancies.

@bold{Not implemented at all:}

@itemlist[
 @item{@bold{Animation} --- neither SMIL (@tt{<animate>}, @tt{<animateTransform>},
   @tt{<animateMotion>}) nor CSS animations/transitions. This is a static,
   single-frame renderer; there is no time dimension anywhere in the
   pipeline. (@racket[pict] output was built instead, as a different,
   complementary direction --- see @secref["top-level-rendering"].)}
 @item{@bold{External/cross-document references} --- a gradient, pattern,
   marker, or @tt{<use>} referencing an id defined in a @italic{different}
   file. Everything must be defined within the same document.}
 @item{@bold{Custom @tt{@"@"font-face} web fonts} --- only fonts already
   installed on the system are used; a document that assumes a specific
   downloaded font for visual consistency will render with a substitute
   instead.}
 @item{@bold{CSS custom properties (@tt{var(...)})}, @bold{@tt{z-index}/CSS
   @tt{isolation}}, and CSS pseudo-classes/sibling combinators (@tt{:hover},
   @tt{:nth-child}, @tt{+}, @tt{~}) in @tt{<style>} stylesheets --- a
   selector using any of these never matches, rather than silently
   over-matching.}
 @item{@bold{Bidirectional text, vertical writing modes (@tt{writing-mode:
   tb-rl}/@tt{tb-lr}), and CJK-aware line-breaking rules} --- text is laid
   out left-to-right, horizontally, using simple whitespace-delimited word
   breaks throughout, including within @tt{inline-size}/@tt{shape-inside}
   wrapping.}
]

@bold{Implemented with a disclosed, narrower simplification:}

@itemlist[
 @item{Percentages resolve correctly against the current (possibly nested)
   viewport's own width, height, or diagonal (for orientation-agnostic
   lengths like @tt{r} and @tt{stroke-width}) for geometry properties and
   @tt{stroke-width} --- confirmed against a WPT test using @tt{rx: 25%} on
   an ellipse. Elsewhere, @racket[parse-length] resolves a percentage
   against an explicit reference length only when the caller provides one
   (see its @racket[#:reference] parameter); other call sites that don't
   thread a containing-viewport length through still treat a percentage
   there as a literal number.}
 @item{Gradient @tt{spreadMethod="reflect"}/@tt{"repeat"} fall back to
   @tt{"pad"}; a pattern's own tile doesn't rescale under an ambient
   @racket[dc] scale. Gradients and patterns can paint a @italic{stroke} as
   well as a fill --- @racket[racket/draw]'s @racket[pen%] has no
   gradient/pattern support at all, so this needed a different technique
   (render the stroke geometry as an alpha mask, fill the same area with
   the brush, combine) --- verified against @tt{librsvg} across
   plain/transformed/dashed/pattern-stroke cases, all within 1-3% pixel
   diff (ordinary curve-antialiasing variance). Pattern @tt{x}/@tt{y} (a
   pure grid translation) is also supported, verified against @tt{librsvg}
   with an exact, zero-pixel-difference match --- @tt{patternTransform}
   specifically (rotation/skew, not just translation) remains unsupported,
   since it can't be reduced to the same pixel-domain shift technique.
   Separately, a pattern's own @tt{fill-opacity}/@tt{opacity} and any
   transparency @italic{within} the pattern's own content (gaps that should
   let whatever's behind the pattern show through) are both now handled
   correctly too, verified against @tt{librsvg} with an exact match for the
   transparency case.}
 @item{@tt{clip-path}'s @tt{objectBoundingBox} units only work on leaf
   shapes, not groups; a single @tt{<clipPath>} combining children with
   different @tt{clip-rule} values uses one fill-rule for the whole
   combined region. @tt{maskContentUnits="objectBoundingBox"} isn't
   implemented. An individual filter primitive's own explicit
   @tt{x}/@tt{y}/@tt{width}/@tt{height} subregion @italic{is} enforced as a
   clip (verified against @tt{librsvg}: an exact, zero-pixel-difference
   match for a @tt{feFlood} with an explicit subregion smaller than the
   canvas) --- but the @tt{<mask>}/@tt{<filter>} element's own
   @italic{overall} region as a whole still isn't; content there is still
   computed across the full canvas rather than a tighter region.}
 @item{A nested @tt{<svg>}, a @tt{<use>}-instantiated @tt{<symbol>}/@tt{<svg>},
   and a @tt{<marker>} instance all default to @tt{overflow: hidden} per
   spec, clipping their content to their own viewport ---
   @tt{overflow="visible"} disables it. All three verified against
   @tt{librsvg} with exact, zero-pixel-difference matches. (Previously none
   of these were enforced at all.)}
 @item{The CSS @tt{paint-order} property (reordering fill/stroke/markers)
   is supported, including markers moving before or between fill and
   stroke --- verified against @tt{librsvg} with exact,
   zero-pixel-difference matches for both a fill/stroke reordering case
   and a markers-before-stroke case.}
 @item{The @tt{pathLength} attribute is supported: it rescales
   @tt{stroke-dasharray}/@tt{stroke-dashoffset} and @tt{<textPath>}'s own
   @tt{startOffset} (including a percentage @tt{startOffset}, which is "X%
   of pathLength," and the @tt{pathLength="0"} edge case, which per spec
   means an infinite scale factor). Neither @tt{librsvg} nor several major
   browser engines implement @tt{pathLength} for stroke-dashing at all, so
   this was verified via hand-derivation and direct pixel checks against
   WPT's own reference files instead; all 8 non-tentative pathLength WPT
   tests pass.}
 @item{The @tt{context-fill}/@tt{context-stroke} paint keywords (resolving
   to whatever fill/stroke was active on the referencing element --- most
   useful so a @tt{<marker>} can automatically match its path's own stroke
   color) are supported for @tt{<use>}, @tt{<marker>}, and @tt{<pattern>}
   content --- verified against @tt{librsvg} for the marker case with an
   exact, zero-pixel-difference match.}
 @item{@tt{feBlend}/@tt{mix-blend-mode} implement the core SVG1.1 modes
   plus the per-channel CSS Compositing set (@tt{multiply}, @tt{screen},
   @tt{darken}, @tt{lighten}, @tt{overlay}, @tt{hard-light},
   @tt{color-dodge}, @tt{color-burn}, @tt{difference}, @tt{exclusion}) ---
   @tt{soft-light} and the four HSL-based modes (@tt{hue}, @tt{saturation},
   @tt{color}, @tt{luminosity}) fall back to @tt{normal}.}
 @item{Per-primitive @tt{color-interpolation-filters="sRGB"} (opting a
   single filter primitive out of the default linearRGB color space) isn't
   supported; the whole filter chain always runs in linearRGB.}
 @item{A @tt{data:} URI for @tt{<image>} must be base64-encoded; the
   plainer, percent-encoded-text form isn't decoded. An SVG file can't
   itself be used as an @tt{<image>} source (only raster formats).}
 @item{@tt{<textPath>} and @tt{xml:space="preserve"} are both implemented
   (see @secref["text"])
   --- verified against @tt{resvg} (@tt{librsvg} has no @tt{textPath}
   support at all) for @tt{<textPath>} specifically, since no other part of
   this library could serve as that particular cross-check. @tt{<textPath>}'s
   @tt{path} attribute (SVG2's inline path data, as an alternative to
   @tt{href} referencing a separate shape, taking precedence when both are
   given) is also supported --- verified via self-consistency instead,
   since neither external renderer available during development could
   validate this specific, fairly recent feature either (the @tt{resvg}
   build available was too old to support @tt{path=} correctly). The one
   remaining narrow gap: a @tt{<tspan>} nested @italic{inside} a
   @tt{<textPath>} isn't given its own distinct styling --- the
   @tt{<textPath>}'s own resolved font/paint context applies to all of its
   text uniformly.}
 @item{@tt{textLength}/@tt{lengthAdjust} are implemented (both
   @tt{"spacing"}, the default, and @tt{"spacingAndGlyphs"}) --- verified
   via hand-derivation rather than against @tt{librsvg}, which was
   confirmed empirically (and via two independent, long-standing bug
   reports) not to implement @tt{textLength} at all. Scoped to a single
   run's own direct text content, not combined with multi-value
   @tt{x}/@tt{y} list positioning.}
 @item{CSS @tt{inline-size} and @tt{shape-inside} (text wrapping) are
   implemented for the common horizontal, left-to-right case, including
   @tt{text-align} (left/center/right/justify, with the last line of a
   justified paragraph correctly left unjustified) --- verified via
   hand-derivation, since the actual WPT reference files for this feature
   depend on a font not installed here. @tt{shape-inside} is scoped to
   referencing a plain @tt{<rect>} specifically (functionally equivalent to
   @tt{inline-size} for a rectangle, since its width doesn't vary by line)
   --- any other referenced shape falls back to not wrapping. Wrapping a
   @tt{<tspan>} with its own distinct styling (e.g. a different
   @tt{font-size}) within the wrapped flow isn't supported; its text is
   still included in the wrap, just using the outer element's own font.
   Vertical writing modes, bidi, and CJK line-breaking are out of scope
   entirely.}
 @item{@tt{feConvolveMatrix}, @tt{feDisplacementMap}, @tt{feImage},
   @tt{feTurbulence}, @tt{feDiffuseLighting}/@tt{feSpecularLighting}, and
   @tt{feTile} are all implemented, each independently verified given how
   much they differ in character (see @filepath{svg.rkt}'s own notes for
   exactly what was checked for each --- @tt{librsvg} itself turned out to
   have no usable @tt{feConvolveMatrix} support at all in the version
   available during development, and @tt{feTurbulence}'s own noise field
   isn't expected to match another renderer pixel-for-pixel even when both
   implementations are correct). Narrower gaps within these six:
   @tt{feTurbulence}'s @tt{stitchTiles="stitch"} always behaves as
   @tt{noStitch}; the lighting primitives use simple edge-pixel clamping
   rather than the spec's nine distinct edge/corner Sobel-kernel variants
   (affecting only the outermost 1px border); @tt{feImage} referencing
   another element in the same document (rather than a raster image)
   doesn't support subregion-based rescaling; and @tt{feTile} can only tile
   a primitive that specified an explicit subregion of its own, since this
   library doesn't track per-primitive subregions more generally (except
   for that one narrow case).}
]

None of these are silent: every one is called out in a comment at the
relevant place in @filepath{svg.rkt} itself, along with what was checked to
confirm it's a real gap rather than a guess (a cross-check against
@tt{librsvg}, a specific failing test, or both) --- this section is a
summary of those notes, not the primary source for them.
