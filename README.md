# svg

`svg` is an SVG parser and static renderer for Racket. It renders SVG
documents with `racket/draw`, producing either a `bitmap%` or a `pict`.

The renderer covers most static SVG 1.1/SVG 2 features: paths, basic shapes,
transforms, gradients, patterns, clipping, masks, markers, text, images, CSS
stylesheets and geometry properties, and a substantial subset of filter
effects. Animation, scripting, and `foreignObject` are intentionally out of
scope.

## Installation

Install from the Racket package catalog:

```sh
raco pkg install svg
```

For local development from a checkout:

```sh
raco pkg install --link --auto --name svg .
```

## Quick Start

```racket
#lang racket

(require svg/svg racket/class)

(define bm
  (svg-string->bitmap
   #<<SVG
<svg width="120" height="80" xmlns="http://www.w3.org/2000/svg">
  <rect x="10" y="10" width="100" height="60" rx="8"
        fill="gold" stroke="black" stroke-width="2"/>
</svg>
SVG
   ))

(send bm save-file "out.png" 'png)
```

Use `svg-string->pict` or `svg-file->pict` when you want a composable
`pict` instead of a raster bitmap.

## Documentation

After installation, run:

```sh
raco docs svg-manual
```

The package manual documents the public API and the renderer's known
limitations.

## License

MIT
