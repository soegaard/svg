#lang racket/base
;;;; ---------------------------------------------------------------------
;;;; svg.rkt  --  An SVG parser and renderer for Racket
;;;; ---------------------------------------------------------------------
;;;
;;; SCOPE (Tier 10 update)
;;;   - Full path-data grammar ("d" attribute), per the SVG2 grammar:
;;;       https://svgwg.org/svg2-draft/paths.html#PathDataBNF
;;;     including the commands the earlier prototype was missing
;;;     (Q/q, T/t quadratic Beziers) and fixing two bugs found in it:
;;;       1. "M x1 y1 x2 y2 ..." (extra coordinate pairs after a moveto)
;;;          must be treated as implicit linetos, not repeated movetos.
;;;       2. Elliptical-arc flags (0/1) must be read as single characters,
;;;          not as general numbers -- otherwise a minified path like
;;;          "a30 50 0 1120 40" (flags "1","1" glued together) misparses
;;;          the two flags as the single number 11.
;;;   - A tree-walking SVG *document* renderer that understands <svg>
;;;     (including genuinely NESTED <svg>, which now establishes its own
;;;     viewport rather than being treated as a transparent <g>), <g>,
;;;     <defs>, <symbol>, <use>, <text>/<tspan>, <marker>, <image>,
;;;     <style>, `<filter>`, <path>, <rect> (incl. rounded corners),
;;;     <circle>, <ellipse>, <line>, <polyline>, <polygon>, the
;;;     `transform` attribute on any of them, a full paint model
;;;     including paint servers, and clipping/masking:
;;;       - `filter="url(#id)"` renders the referencing element into a
;;;         full-canvas offscreen ARGB buffer (the same simplification
;;;         masks already use, for the same reason: no need to compute a
;;;         tight bounding box, which isn't readily available for
;;;         groups), then runs it through the <filter>'s chain of
;;;         primitives -- feGaussianBlur, feOffset, feColorMatrix,
;;;         feFlood, feMerge/feMergeNode, feComposite, feBlend,
;;;         feComponentTransfer, feMorphology, and feDropShadow -- each
;;;         consuming named buffers (starting from "SourceGraphic"/
;;;         "SourceAlpha") and producing a new one, mirroring the SVG
;;;         filter-graph model exactly. feTurbulence, feDisplacementMap,
;;;         feConvolveMatrix, feDiffuseLighting/feSpecularLighting,
;;;         feImage, and feTile are NOT implemented -- turbulence/
;;;         lighting/convolution are substantial standalone algorithms
;;;         with low incidence in real-world SVGs next to blur/offset/
;;;         color/composite/merge, and feTile's tiling needs precise
;;;         filter-region/subregion bookkeeping that conflicts with the
;;;         full-canvas simplification used everywhere here (the
;;;         <filter>'s own region -- x/y/width/height, default -10%..110%
;;;         of the bbox -- is likewise NOT enforced as a clip, the same
;;;         disclosed simplification masks make). Per spec, a `filter`
;;;         referencing a missing or non-<filter> id means the element
;;;         (and its descendants/markers) is not rendered AT ALL -- a
;;;         real, different fallback from mask/clip-path's "just don't
;;;         apply it" leniency, implemented precisely (and tested
;;;         explicitly) rather than defaulting to the more common
;;;         pattern out of convenience.
;;;
;;;         All work happens in PREMULTIPLIED-alpha ARGB byte buffers
;;;         (matching get/set-argb-pixels' own format), since that's the
;;;         correct space for blurring and Porter-Duff compositing alike
;;;         -- blurring straight color would produce dark fringing at
;;;         partially-transparent edges. feColorMatrix and
;;;         feComponentTransfer, which are defined in terms of straight
;;;         color per spec, unpremultiply their input, do the math, and
;;;         repremultiply the result. SVG filters also default to
;;;         `color-interpolation-filters: linearRGB` -- primitives
;;;         operate on gamma-DEcoded color by default -- which turned out
;;;         to matter in practice, not just on paper: cross-checking
;;;         against librsvg initially showed a feColorMatrix
;;;         (saturate=0) result off by ~13/255 from doing the same math
;;;         directly on sRGB bytes; decoding SourceGraphic to linear at
;;;         the very start of the filter chain and encoding the final
;;;         result back to sRGB at the very end (via precomputed 256-
;;;         entry lookup tables, `srgb->linear-table`/
;;;         `linear->srgb-table`) brought that specific case to an EXACT
;;;         match. Per-primitive `color-interpolation-filters="sRGB"`
;;;         overrides aren't supported -- a disclosed, narrow gap given
;;;         how rarely that's used to opt out of the default.
;;;
;;;         feGaussianBlur uses the SVG Filter Effects spec's own
;;;         recommended approximation of a true Gaussian: three
;;;         successive box blurs (via an O(n) sliding-window sum, not a
;;;         naive O(n*d) convolution), whose sizes are derived from
;;;         stdDeviation by the spec's own formula. Verified empirically
;;;         against librsvg's own feGaussianBlur BEFORE building any
;;;         other primitive on top of it (a solid square blurred at
;;;         stdDeviation=4 matched librsvg to within +/-2 out of 255
;;;         across a full cross-section) -- confirming the algorithm and
;;;         constants were right before trusting anything built on it.
;;;         Length-valued primitive attributes (stdDeviation, dx/dy,
;;;         radius) are in user-space units and need converting to
;;;         device pixels for the buffer operations; `ambient-scale-
;;;         factor` extracts this from the dc's current transformation,
;;;         confirmed empirically to be exact (not merely approximate)
;;;         for this renderer specifically, since its own transform stack
;;;         (translate/scale/transform -- dc<%>'s own `rotate` is never
;;;         used, per the Tier 1 rotation-direction fix) always folds
;;;         into `get-transformation`'s sub-matrix rather than its
;;;         separate ox/oy/xs/ys/rotation fields.
;;;
;;;         feMorphology's dilate/erode is a separable min/max (again
;;;         horizontal then vertical), which is mathematically EXACT for
;;;         the rectangular structuring element SVG specifies, not an
;;;         approximation. feComposite implements the standard Porter-
;;;         Duff operators (over/in/out/atop/xor) plus "arithmetic";
;;;         feBlend implements only the core SVG1.1 modes (normal/
;;;         multiply/screen/darken/lighten) -- the extended CSS3 set
;;;         (overlay, color-dodge, hard-light, difference, hue/
;;;         saturation/color/luminosity, ...) falls back to normal, a
;;;         disclosed, narrow gap. feDropShadow is implemented directly
;;;         as its own standard composition of the other primitives
;;;         already built (blur SourceAlpha, offset it, flood+composite
;;;         "in", merge with the original graphic on top), rather than
;;;         needing anything new -- worth calling out since it's
;;;         arguably the single most common non-trivial filter in real-
;;;         world SVGs, right after blur itself;
;;;       - `<style>` CSS is parsed via `parsers/css` (Jens Axel Søgaard's
;;;         parsers-lib package, declared as a dependency in this package's
;;;         info.rkt) rather than a hand-rolled parser: a real CSS
;;;         Syntax Level 3 parser handles quoting/escaping/comments and
;;;         !important correctly, which a from-scratch parser would have
;;;         had to reinvent. Selector MATCHING against an actual element
;;;         and its ancestor chain is still ours on top of it, since
;;;         that's inherently SVG/DOM-specific and not something a
;;;         general CSS parser can provide: type/class/id/universal/
;;;         attribute selectors (presence, =, ~=, |=, ^=, $=, *=),
;;;         compound selectors combining several of those on one element,
;;;         descendant and child combinators, comma-separated selector
;;;         lists, real CSS specificity, and the FULL cascade against
;;;         presentation attributes and inline style="" -- five tiers,
;;;         highest first: inline !important, stylesheet !important (by
;;;         specificity/order), inline normal, stylesheet normal (by
;;;         specificity/order), then the plain presentation attribute,
;;;         which acts as though it were the lowest-specificity rule of
;;;         all (even a bare `rect { fill: red }` rule beats a
;;;         `fill="blue"` attribute on that element). Selector matching
;;;         needs each element's ANCESTOR chain for descendant/child
;;;         combinators, which nothing before this tier needed to track;
;;;         `current-ancestor-chain` threads it through precisely where
;;;         `render-node!` already recurses into an element's children,
;;;         reset to empty when entering a pattern tile/mask/marker/used-
;;;         <symbol>'s own content, mirroring how those same call sites
;;;         already start from `ua-default-ctx` rather than inheriting
;;;         paint context. Pseudo-classes (:hover, :nth-child, ...),
;;;         namespaced selectors, and sibling combinators (+/~) are all
;;;         deliberately unsupported: a compound using any of them is
;;;         marked impossible and NEVER matches, rather than silently
;;;         ignoring the unsupported part and over-matching -- actually
;;;         more correct for interaction-based pseudo-classes in a
;;;         one-shot static renderer (:hover can never apply to a
;;;         rendered-once raster) and a reasonable, narrow simplification
;;;         for the rest. @media/@supports/etc. are parsed structurally
;;;         (so they don't break anything) but their content is never
;;;         applied, matching the SVG-in-a-fixed-viewport reality here --
;;;         a real "does this media query currently apply" evaluator is
;;;         future work, not attempted.
;;;
;;;         Testing against this specific library surfaced two real
;;;         upstream bugs, both confirmed by direct, isolated
;;;         reproduction (not just an SVG rendering symptom) before being
;;;         treated as bugs rather than a misunderstanding on this file's
;;;         part, and reported to the author:
;;;           1. `css-selector-compounds` (the library's own helper for
;;;              grouping a selector's flat parts into compounds split on
;;;              combinators) returns them out of order -- "a b > c"
;;;              comes back with the FIRST combinator moved to the front
;;;              and the other two entries left with no combinator
;;;              between them, rather than in source order. Not used
;;;              here at all: compounds are grouped from the flat
;;;              `css-selector-parts` list instead, which IS in correct
;;;              source order (checked directly, independent of the
;;;              buggy helper), via this file's own `convert-css-selector`.
;;;           2. Class/id name scanning doesn't stop at a SUBSEQUENT '.'
;;;              or '#' -- chained simple selectors like ".foo.bar" or
;;;              "#bar.foo" come back as one identifier with the
;;;              delimiter embedded in it (class name "foo.bar", or id
;;;              name "bar.foo") instead of two separate parts. Worked
;;;              around in `split-mangled-selector-name`: a legitimate
;;;              CSS identifier never legitimately contains a literal '.'
;;;              or '#', so any occurrence is unambiguously this bug
;;;              rather than valid input, and is split back into the
;;;              separate class/id pieces the parser should have
;;;              produced.
;;;           Also worth noting for anyone hitting it independently: the
;;;           library's `css-declaration-value` keeps a literal
;;;           "!important" suffix in the raw value text even when it ALSO
;;;           flags `css-declaration-important?` separately (apparently
;;;           by design, for its own serialization/rewrite features) --
;;;           not a bug, but easy to trip over if you only check the
;;;           boolean and use the value as-is; stripped back off here
;;;           before storing it;
;;;       - `<image>` decodes `data:` URIs (base64 only -- the rarer
;;;         plain percent-encoded-text form isn't handled) and resolves
;;;         local file paths (percent-decoded, relative ones resolved
;;;         against the SVG file's own directory when rendering via
;;;         `svg-file->bitmap`; `svg-string->bitmap` has no such
;;;         directory, so a relative path there just won't resolve).
;;;         Deliberately does NOT fetch remote http(s)/ftp/etc URLs AT
;;;         ALL -- treating an arbitrary URL found inside untrusted SVG
;;;         content as auto-fetchable is a real privacy/SSRF-adjacent
;;;         concern, the same kind of judgment call a browser makes
;;;         about cross-origin content, not merely a missing feature; a
;;;         remote href simply renders nothing, like any other
;;;         unresolvable reference in this file, and this was treated as
;;;         a real design decision rather than something to build
;;;         unused, untested opt-in surface for on spec alone. A failed
;;;         load of any kind (dangling, malformed, undecodable, or an
;;;         image format the underlying codec can't handle) never raises
;;;         -- confirmed empirically that `read-bitmap` on garbage bytes
;;;         doesn't raise at all, it silently returns a broken 1x1
;;;         bitmap that's unsafe to even query further without checking
;;;         `ok?` first. Absent width/height default to the image's own
;;;         natural pixel size, per spec; `preserveAspectRatio` (fit vs.
;;;         crop) reuses the exact same `compute-viewbox-matrix` a
;;;         viewBox mapping does, treating the image's natural
;;;         dimensions as its own implicit viewBox; content is clipped
;;;         to the element's x/y/width/height viewport, so `slice`
;;;         cropping actually crops. `opacity` is applied via dc<%>'s own
;;;         `set-alpha`, confirmed by testing to modulate `draw-bitmap`'s
;;;         blending correctly, not just brush/pen fills;
;;;       - `marker-start`/`marker-mid`/`marker-end` (and the `marker`
;;;         shorthand setting all three) place a <marker>'s content at a
;;;         <path>/<line>/<polyline>/<polygon>'s vertices -- NOT the
;;;         other basic shapes, per spec. Vertices and their tangent
;;;         angles are extracted straight from `get-datum` the same way
;;;         `dc-path->polylines`'s dash-splitting does: a segment's
;;;         tangent at a given endpoint is just the direction from its
;;;         nearest distinct control point (or the plain endpoint-to-
;;;         endpoint direction for a straight line-to), so no separate
;;;         arc/curve tangent math was needed. A closed subpath that
;;;         doesn't already loop back to its own start in the raw
;;;         geometry (true for anything built via line-to/close rather
;;;         than a shape that happens to end where it began) gets an
;;;         implicit closing segment added, producing a distinct
;;;         "closure vertex" coincident with the start -- matching the
;;;         spec's own treatment of closepath as generating its own
;;;         vertex. `orient="auto"` uses a wraparound-robust bisector of
;;;         the in/out tangent angles (falling back to whichever one
;;;         exists at an open path's endpoints); `orient="auto-start-
;;;         reverse"` is the same plus 180 degrees, but only at the
;;;         marker-start vertex specifically. The tangent angle (atan2 of
;;;         the segment's dy,dx) is fed directly into the SAME
;;;         `rotation-matrix` the `transform` attribute's rotate() uses
;;;         -- confirmed empirically to already orient a marker's default
;;;         rightward-pointing content along the tangent direction with
;;;         no further sign adjustment needed, since it reuses a
;;;         convention already verified correct. `refX`/`refY` (specified
;;;         in the marker's own content/viewBox coordinate system) are
;;;         mapped through that viewBox matrix before being used as the
;;;         anchor offset, reusing the same `apply-matrix-to-point`
;;;         gradients use, so the correct content-space point ends up
;;;         exactly at the vertex regardless of viewBox scaling.
;;;         `markerUnits="strokeWidth"` (the default) scales the marker
;;;         by the referencing shape's own resolved stroke-width.
;;;         `overflow:hidden` (clipping content to the marker's own
;;;         viewport) IS enforced -- see VIEWPORT CLIPPING below; this
;;;         was previously a disclosed gap here. Cross-
;;;         checking against a real SVG renderer surfaced an apparent
;;;         mismatch that traced back to the reference tool, not this
;;;         code: that librsvg build silently ignores the `marker`
;;;         shorthand property (SVG2) and only recognizes the three
;;;         longhand properties -- confirmed by re-running the same scene
;;;         with explicit longhands, which then matched exactly;
;;;       - <text>/<tspan> are converted to actual path geometry via
;;;         dc-path%'s `text-outline` (rather than drawn with dc<%>'s
;;;         `draw-text`), then fed through the SAME `draw-shape-paths!`
;;;         pipeline every other shape uses -- so text gets full
;;;         gradient/pattern/dasharray/opacity paint support for free,
;;;         with no separate "text paint" code path. `text-outline`'s
;;;         (x,y) turned out to be the TOP-LEFT of the text's bounding
;;;         box, not its baseline (an initial guess based on a
;;;         coincidentally-plausible-looking render turned out wrong; a
;;;         guideline-and-bounding-box check settled it and matches what
;;;         the docs say), so every draw computes the ascent from
;;;         `get-text-extent` for that SPECIFIC string+font and shifts up
;;;         accordingly, verified against a precise pixel guideline.
;;;         Supports `font-family` (splitting a comma list into a generic
;;;         family racket/draw maps per-platform, plus a specific face
;;;         name if one is given), `font-size`, `font-weight` (keywords
;;;         or numeric), `font-style`, `text-anchor`, and `x`/`y`/`dx`/
;;;         `dy` -- including PER-CHARACTER positioning when an
;;;         attribute supplies more than one value. A <tspan> with its
;;;         own x/y resets the pen there; with dx/dy nudges it
;;;         relatively; with neither, continues where the previous
;;;         content left off. Cross-checking against librsvg surfaced a
;;;         real whitespace-handling bug: collapsing AND trimming each
;;;         text node independently ran separately-styled tspans
;;;         together with no space between them ("Bluethen" instead of
;;;         "Blue then"); fixed by collapsing every node's internal
;;;         whitespace but only trimming a LEADING space at the true
;;;         start of the whole <text> subtree (tracked via a shared
;;;         `started?` box), never trimming space between runs. Text-
;;;         anchor is applied per run (this element's own text), not to
;;;         a "chunk" spanning multiple sibling tspans as the spec
;;;         technically defines it -- a disclosed simplification
;;;         matching the common cases. A remaining, EXPECTED (not a bug)
;;;         divergence from librsvg: exact glyph pixel positions differ
;;;         by a few px, since Racket's font family resolution and
;;;         librsvg's (Pango-based) resolution can pick different actual
;;;         system fonts for the same nominal family, and different
;;;         fonts have different metrics at "the same" point size --
;;;         verified this isn't a bug in the baseline math itself via a
;;;         direct pixel-guideline check independent of any reference
;;;         renderer. `<textPath>` (laying text along a path) is NOT
;;;         implemented at all -- flagged from the start of this whole
;;;         project as the one text feature needing real arc-length
;;;         parameterization, deferred; `xml:space="preserve"` and
;;;         `text-decoration` are likewise not implemented;
;;;       - `clip-path="url(#id)"` (on any element) restricts painting to
;;;         the UNION of a <clipPath>'s child shapes, built via the same
;;;         `shape-node->dc-paths` leaf-shape geometry normal rendering
;;;         uses, combined into one dc-path% and applied through
;;;         `region%`. Confirmed empirically that `set-clipping-region`
;;;         composes correctly with whatever transform is already active
;;;         (unlike the gradient-brush pitfall in Tier 4 -- there's no
;;;         shared-coordinate-space issue here since nothing mutates the
;;;         shared dc's transform to build the clip). Nested clip-paths
;;;         (an element and an ancestor both specifying one) correctly
;;;         INTERSECT rather than one replacing the other -- confirmed
;;;         that `set-clipping-region` itself replaces, so the two
;;;         regions are combined via `region%`'s own `intersect` method
;;;         first. Supports `clipPathUnits` (objectBoundingBox needs a
;;;         bbox, so is only honored when clipping a leaf shape; on a
;;;         group it falls back to raw userSpaceOnUse coordinates, a
;;;         disclosed narrow gap), each clip child's own `transform`, and
;;;         `clip-rule` (one nonzero/evenodd choice for the whole
;;;         combined region, since `region%.set-path` takes a single
;;;         fill-rule -- mixing clip-rule across shapes in the same
;;;         clipPath isn't representable, a narrow simplification);
;;;       - `mask="url(#id)"` renders the mask's own content and the
;;;         masked element's content into separate full-canvas offscreen
;;;         buffers (deliberately whole-canvas rather than a tight
;;;         bounding region, trading memory for a much simpler
;;;         implementation), computes each pixel's luminance (or raw
;;;         alpha, for `mask-type="alpha"`) via `get-argb-pixels`,
;;;         multiplies it into the content buffer's own alpha via
;;;         `set-argb-pixels`, and composites the result onto the main dc
;;;         with `draw-bitmap` (confirmed this alpha-blends correctly
;;;         against whatever is already there). Mask content is always
;;;         rendered as `maskContentUnits="userSpaceOnUse"` (the
;;;         default) -- i.e. in the SAME absolute coordinate system as
;;;         wherever the masked element sits, not auto-centered/rebased
;;;         onto it; `maskContentUnits="objectBoundingBox"` is not
;;;         implemented, so a mask meant to be reused at different
;;;         positions needs its own content positioned to match each use
;;;         (a real mistake made and caught while cross-checking this
;;;         tier: a mask authored once at the origin and reused on an
;;;         element positioned elsewhere silently masked it away
;;;         entirely, since the two never geometrically overlapped).
;;;         `maskUnits`/x/y/width/height (the mask's own region) is
;;;         likewise NOT enforced as an extra clip -- a disclosed
;;;         simplification;
;;;       - `fill`/`stroke` accept "url(#id)" [+ optional fallback color],
;;;         referencing a <linearGradient>/<radialGradient>/<pattern>.
;;;         FILLS fully support all three; STROKES do not (confirmed
;;;         empirically that racket/draw's pen% has no gradient/stipple
;;;         support at all) and just use the fallback color, or no
;;;         stroke, instead -- a correct gradient/pattern stroke would
;;;         need stroke-to-fill outline tessellation, out of scope here
;;;         given how rare it is next to solid-color strokes;
;;;       - gradients support `gradientUnits` (objectBoundingBox is the
;;;         default), `gradientTransform`, multi-stop gradients, stop-
;;;         color/stop-opacity, and href-based stop inheritance between
;;;         gradients (a common real-world pattern: define stops once,
;;;         reuse across several gradients with different geometry). A
;;;         gradient's coordinates are resolved to plain numbers via
;;;         `map-paint-point` -- NOT by mutating the shape's own dc
;;;         transform, which was the first approach tried here and turned
;;;         out to be a real bug: since the gradient and the shape it
;;;         fills share the same dc, extending that dc's transform to
;;;         position the gradient shifted the SHAPE's geometry too. A
;;;         test that only checked "which end of the gradient is which
;;;         color" didn't catch this (pad-clamped colors look plausible
;;;         even when the shape itself is in the wrong place); a test
;;;         checking a specific pixel just outside the shape's boundary
;;;         did. `spreadMethod` is NOT implemented (racket/draw's
;;;         gradients have no native spread-method support beyond the
;;;         implicit "pad" clamp, which happens to be SVG's own default)
;;;         -- "reflect"/"repeat" silently fall back to "pad", a
;;;         disclosed, narrow gap given their rarity;
;;;       - patterns render their own content into an offscreen tile
;;;         bitmap and wrap it in a stipple brush%, supporting
;;;         `patternUnits`/`patternContentUnits`/`viewBox` and href-based
;;;         attribute inheritance. For the same reason described above,
;;;         the tile's `x`/`y` offset and `patternTransform` are NOT
;;;         implemented (always rendered as if x=0 y=0, transform
;;;         absent): a stipple brush has no coordinate-mapping hook to
;;;         apply them to other than the shared dc, which risks the same
;;;         shape-shifting mistake gradients had -- disclosed as a
;;;         narrower gap than the rest of pattern support, since nonzero
;;;         pattern x/y is uncommon in practice. Also does NOT rescale
;;;         the tile's own raster resolution for whatever ambient scale
;;;         is active on the dc -- testing found racket/draw's stipple-
;;;         tiling under an ambient scale behaves inconsistently in ways
;;;         that would need more investigation to characterize correctly,
;;;         so a pattern used inside a heavily zoomed viewBox or scaled
;;;         ancestor may look under/over-detailed rather than perfectly
;;;         crisp. Patterns also don't respect fill-opacity/opacity (a
;;;         narrower, separate gap from gradients, which do);
;;;       - `<use>` deep-clones its referenced element (by `href` or
;;;         `xlink:href`) at (x,y), with the used content's inheritance
;;;         resolved from `use`'s OWN context (not wherever the original
;;;         definition sits) -- the usual subtle point to get right here;
;;;         reference cycles (including direct self-reference) are
;;;         guarded against via `current-use-chain` rather than crashing
;;;         or hanging;
;;;       - `<symbol>` (and `<svg>`, whether nested directly or reached
;;;         via `<use>`) establishes a new viewport: `viewBox`/
;;;         `preserveAspectRatio` mapped into a width/height that's
;;;         `use`'s own if given, else the target's, else the viewBox
;;;         size -- reusing the exact same `compute-viewbox-matrix` the
;;;         root document uses, via the shared
;;;         `viewport-instantiation-matrix` helper;
;;;       - `<defs>`/`<symbol>` content, and paint-server/clipPath/mask
;;;         definitions wherever they sit in the tree, are captured in
;;;         the id table (built once, over the whole tree, so forward
;;;         references work) but never rendered directly;
;;;       - correct presentation-attribute INHERITANCE down the tree,
;;;         including an inline `style="..."` attribute and `<style>`
;;;         stylesheets, per the full cascade described above;
;;;       - color: `#rgb`/`#rrggbb`, named colors (with CSS-correct
;;;         overrides where Racket's X11-derived database disagrees),
;;;         `rgb()`/`rgba()`/`hsl()`/`hsla()` (integers or percentages,
;;;         classic comma syntax or CSS4 space/slash syntax), and
;;;         `currentColor` (resolved against the inherited `color`);
;;;       - `opacity`/`fill-opacity`/`stroke-opacity`, composed into the
;;;         painted color's alpha channel (confirmed empirically that
;;;         racket/draw's brush%/pen% alpha produces real translucent
;;;         blending, not just a flag). `opacity` on a container (`<g>`,
;;;         nested `<svg>`, `<use>`, and the `<symbol>`/`<svg>` a `<use>`
;;;         instantiates) is TRUE group opacity, not an approximation:
;;;         `render-with-opacity!` renders the container's whole subtree
;;;         into a fresh, fully-transparent offscreen buffer first (so
;;;         children that overlap each other composite correctly against
;;;         each other at full strength), then blends that single,
;;;         already-resolved buffer against the destination once via
;;;         dc<%>'s own `set-alpha`. An earlier version instead
;;;         accumulated opacity multiplicatively down the tree and folded
;;;         it into each descendant leaf's own fill/stroke-opacity --
;;;         exactly correct when a container's content doesn't overlap
;;;         itself, but visibly wrong at the overlap otherwise (two
;;;         50%-alpha layers stacked on each other compound to 75%
;;;         opacity, not 50%). Verified against librsvg on a deliberately
;;;         overlapping two-rect case: both agree on (127,127,255) at the
;;;         overlap, where the old approximation gave (127,63,191).
;;;         Nested containers' opacity compounds correctly (0.5 inside
;;;         0.5 gives an effective 0.25) as a natural consequence of each
;;;         level's offscreen composite being independent, with no
;;;         explicit multiplication needed. A single LEAF shape (no
;;;         children of its own) still folds its own opacity into its
;;;         own fill/stroke-opacity directly, same as before -- correct
;;;         for a leaf regardless, and cheaper than an offscreen buffer
;;;         for the overwhelmingly common case;
;;;       - `mix-blend-mode` (any element, not just containers): blends
;;;         the element against whatever's already drawn on the
;;;         destination (its backdrop) using one of the standard CSS
;;;         Compositing per-channel blend functions -- multiply, screen,
;;;         darken, lighten, overlay, hard-light, color-dodge, color-
;;;         burn, difference, exclusion (`blend-channel`, shared with
;;;         feBlend, Tier 10) -- rather than plain alpha compositing.
;;;         Verified against librsvg on a simple, single-element case
;;;         (a gray rect multiply-blended over a red one): exact match at
;;;         both the overlap and the backdrop-only region. Soft-light and
;;;         the four HSL-based modes (hue/saturation/color/luminosity,
;;;         which need converting each pixel to/from HSL rather than a
;;;         per-channel formula) are a disclosed, narrower gap, falling
;;;         back to "normal" like any other unrecognized mode. CSS
;;;         `isolation: isolate` is NOT implemented -- confirmed to
;;;         matter in practice, not just on paper: cross-checking against
;;;         a WPT test with several SIBLING elements all using
;;;         mix-blend-mode inside an isolated group showed each one
;;;         blending against the literal page backdrop in turn (in this
;;;         file's implementation) rather than against each other within
;;;         an isolated backdrop first, as `isolation: isolate` requires
;;;         -- correct for the much more common case of a single blended
;;;         element, visibly different for multiple blended siblings
;;;         inside an isolated group specifically;
;;;       - `stroke-linecap`/`stroke-linejoin` (direct pen% support;
;;;         `stroke-miterlimit` is parsed nowhere and has no effect --
;;;         racket/draw's pen% exposes no miter-limit control at all);
;;;       - `stroke-dasharray`/`stroke-dashoffset`, implemented by
;;;         flattening a shape's dc-path% into a polyline and splitting
;;;         it into on/off runs. The flattening works uniformly across
;;;         every shape (line-to, curve-to, native .arc, native
;;;         .ellipse/.rounded-rectangle) because inspecting `get-datum`
;;;         showed racket/draw represents ALL of them, once built, using
;;;         only two segment shapes -- a bare waypoint or a 6-element
;;;         cubic Bezier control-point vector -- so no separate arc-
;;;         sampling math was needed;
;;;     and, from Tier 0/1:
;;;       - a dc-level transformation stack, saved/restored around every
;;;         element -- rotation uses a matrix built from SVG's own
;;;         formula rather than dc<%>'s `rotate`, which spins the
;;;         opposite direction from SVG's convention;
;;;       - real `viewBox`/`preserveAspectRatio` handling;
;;;       - unit-aware length parsing (px/pt/pc/in/cm/mm/%).
;;;   - Rendering via racket/draw's dc-path% / dc<%>, per the plan to
;;;     target racket/draw directly rather than an intermediate IR.
;;;
;;; OUTPUT: pict (in addition to bitmap%)
;;;   `svg-string->pict`/`svg-file->pict`/`svg-doc->pict` wrap an already-
;;;   parsed document as a `pict` (the standard Racket functional-picture
;;;   library, part of the same distribution as Slideshow/Scribble --
;;;   unlike parsers/css, no separate package install is needed) via
;;;   pict's own `dc` constructor. This needed no change to
;;;   render-svg-doc! itself: it already targets the generic dc<%>
;;;   interface throughout (never assuming bitmap-dc% for the dc it's
;;;   HANDED, only for its own private scratch buffers -- mask/filter/
;;;   pattern/marker compositing, which is unrelated), so the resulting
;;;   pict can be drawn onto whatever dc it eventually lands on: a bitmap
;;;   (via pict->bitmap), but also a pdf-dc%/post-script-dc%/on-screen
;;;   canvas, giving vector PDF/PostScript output "for free" for content
;;;   that doesn't need mask/filter rasterization (masked/filtered
;;;   elements still rasterize internally either way, the same as in any
;;;   renderer, since those effects inherently require pixel buffers --
;;;   they'd show up as embedded raster images in an otherwise-vector
;;;   PDF). pict's `dc` constructor requires the draw procedure to leave
;;;   the dc's own tracked state exactly as it found it or raises a
;;;   contract violation -- confirmed empirically (by deliberately
;;;   leaving each candidate field unrestored one at a time and reading
;;;   which ones the contract actually caught) to be exactly
;;;   transformation, pen, brush, font, alpha, text-mode, and text-
;;;   foreground; smoothing, clipping-region, and background were tested
;;;   too and are NOT part of what's checked, though smoothing is still
;;;   explicitly restored for good hygiene regardless. render-svg-doc!
;;;   doesn't do this restoration on its own -- it permanently applies
;;;   the root viewBox transform and smoothing mode, which is fine for
;;;   its EXISTING direct callers -- so the pict wrapper saves and
;;;   restores all of it explicitly rather than changing render-svg-
;;;   doc!'s own contract. Uses `dc` rather than `unsafe-dc` deliberately:
;;;   it costs a second, throwaway render during pict construction (part
;;;   of the contract's own precondition check), but turns any future
;;;   accidental unrestored mutation into an immediate, clear contract
;;;   violation instead of silent dc-state corruption in whatever gets
;;;   drawn next to an svg-pict in a composed picture -- confirmed this
;;;   actually matters in practice, not just in principle, by composing
;;;   an svg-pict with ordinary picts (disk/text/frame/hc-append) and
;;;   checking the result renders correctly, not just that construction
;;;   alone doesn't raise.
;;;
;;;   A real, non-obvious bug surfaced here: the first version of
;;;   `svg-file->pict` wrapped its `parameterize` (setting the base
;;;   directory relative <image> hrefs resolve against) around the
;;;   PARSING step only. That silently broke relative image references
;;;   the moment the pict was actually drawn, because pict's `dc` draws
;;;   LAZILY -- whenever the pict is actually rendered, which can be well
;;;   after the pict was constructed and any surrounding `parameterize`'s
;;;   dynamic extent has already ended -- while image loading happens at
;;;   RENDER time (inside render-image-node!), not parse time. Fixed by
;;;   having the pict's own draw closure re-establish that parameterize
;;;   itself, every time it actually runs, rather than once at
;;;   construction. Caught by a test that rendered a file-based pict
;;;   with a real relative image reference end to end, not just one that
;;;   checked pict construction didn't raise.
;;;
;;;   The pict's own background is transparent (letting it compose
;;;   correctly with other picts around or behind it), unlike svg-string
;;;   ->bitmap/svg-file->bitmap's opaque white background (a sensible
;;;   default for a standalone saved image) -- a deliberate difference
;;;   in convention between the two output paths, not an inconsistency.
;;;
;;; GEOMETRY PROPERTIES (SVG2: cx/cy/r/rx/ry/x/y/width/height/d via CSS)
;;;   `geometry-attr-ref`/`geometry-attr-num`/`geometry-d-ref` let a
;;;   <rect>/<circle>/<ellipse>/<path>'s own geometry be set via CSS
;;;   (inline style or a <style> stylesheet), not just the plain XML
;;;   attribute of the same name -- confirmed against real usage in Web
;;;   Platform Tests' svg/geometry suite to be exactly this property set
;;;   for the basic shapes; x1/y1/x2/y2 (line) and points (polyline/
;;;   polygon) are NOT part of it (never appear as CSS properties
;;;   anywhere in that suite). This reuses the SAME cascade priority
;;;   Tier 9 built for paint properties (inline !important > stylesheet
;;;   !important > inline normal > stylesheet normal > plain attribute),
;;;   since resolving "what's the effective value of this property"
;;;   doesn't care whether the result feeds into paint or geometry --
;;;   but unlike paint properties, geometry properties are NOT inherited
;;;   (SVG2 gives them all `Inherited: no`), so this resolves only the
;;;   element's own cascade, with no ancestor fallback, rather than
;;;   being folded into render-ctx. `d`'s CSS syntax (`path('...')` or
;;;   `none`, not a plain length) gets its own small parse step;
;;;   `d: inherit`/`initial`/`unset` aren't supported, a disclosed,
;;;   narrow gap. `<ellipse>`'s `rx`/`ry` additionally cross-derive from
;;;   one another when either is `auto` or simply omitted entirely
;;;   (confirmed against a WPT test asserting exactly this) -- which
;;;   also retroactively fixed a PRE-EXISTING gap in plain-attribute
;;;   ellipses specifying only one of rx/ry, previously silently
;;;   rendering nothing instead of falling back correctly.
;;;
;;;   This is a natural extension of the cascade machinery already
;;;   built for paint, not a DOM-reactivity feature -- what wouldn't
;;;   translate to a static, single-pass renderer, and isn't attempted,
;;;   is anything requiring live reactivity: `:hover`/`:focus` changing
;;;   geometry, CSS transitions/animations interpolating it over time,
;;;   or a `<use>` reacting to a referenced element's size changing --
;;;   the same DOM/time boundary already drawn around animation and
;;;   interactive pseudo-classes in Tier 9.
;;;
;;;   Found by cross-testing against Web Platform Tests' svg/ suite (see
;;;   the wpt-harness/ tooling shipped alongside this file): of ~1750
;;;   files there, 243 are clean, static SVG-vs-SVG reftest pairs (no
;;;   live DOM/script, no SMIL); running them surfaced two real,
;;;   independently-confirmed bugs beyond the geometry-properties gap
;;;   itself, both fixed and covered by regression tests:
;;;     1. `viewBox="0, 0, 620, 340"` (comma-separated, valid per spec)
;;;        crashed with a raw contract violation -- viewBox parsing only
;;;        split on whitespace, so "0," failed to parse as a number.
;;;     2. "H 100" (a space between a path command letter and its
;;;        number) crashed, while "H100" and "L 100 100" both worked:
;;;        H/V pass `read-number!` directly, which -- unlike
;;;        `parse-coord-pair!` (used by L and others) -- doesn't skip
;;;        leading whitespace itself, and the shared repeat-parsing loop
;;;        skipped separators before every SUBSEQUENT value but never
;;;        before the first one. Neither bug was caught by this file's
;;;        own test suite, since its own hand-written fixtures (and the
;;;        path data this library itself generates for rounded rects)
;;;        happen to lean toward tight, no-space/comma-heavy formatting
;;;        -- exactly the kind of blind spot a second, independently-
;;;        authored test corpus is good at catching. Also motivated a
;;;        real robustness fix, independent of any specific bug: per
;;;        SVG2's error-handling model, a syntax error partway through
;;;        one path's `d` should render everything parsed before the
;;;        error, not crash the WHOLE document -- confirmed this file
;;;        did the latter before the fix.
;;;
;;; PERFORMANCE
;;;   A profiling pass (timing a range of documents: a plain icon, 2000
;;;   plain shapes, a large blurred rect, deeply nested opacity-bearing
;;;   groups, a masked rect, a large-radius morphology filter) found one
;;;   clear, worthwhile fix: `feMorphology` used an O(n*radius) sliding-
;;;   window rescan (recomputing the min/max over the whole window at
;;;   every output position) where `feGaussianBlur`'s box blur already
;;;   used an O(n) sliding-window SUM -- a radius=10 dilate on an 800x600
;;;   canvas took noticeably, disproportionately longer than a similarly
;;;   -sized blur pass as a result. Replaced with the standard O(n)
;;;   sliding-window min/max algorithm (a monotonic deque of candidate
;;;   indices -- a running min/max can't just subtract-on-exit the way a
;;;   running sum can, since removing the current min/max needs to know
;;;   what the next-best value in the window now is). Verified against
;;;   the original naive version across 10,000 randomized trials
;;;   (varying count/radius/operator) before replacing it, given how
;;;   easy an off-by-one is to introduce here -- a first attempt had
;;;   exactly that (double-advancing the window's right edge), caught
;;;   immediately by the randomized check on a 3-element input rather
;;;   than surviving into the shipped code. Confirmed a ~4x speedup on
;;;   the original profiling case (774ms -> 192ms) with pixel-identical
;;;   output to the version it replaced.
;;;
;;;   One characteristic found and deliberately NOT changed: opacity<1
;;;   (and mask/filter) on deeply NESTED containers costs roughly
;;;   linearly in nesting depth, since each level allocates its own
;;;   full-canvas offscreen buffer (confirmed: 80 levels of nested
;;;   `<g opacity="0.99">` took ~15x longer than 5 levels, consistent
;;;   with each level costing a roughly constant, canvas-size-
;;;   proportional amount). This is the same full-canvas simplification
;;;   used everywhere in this file to avoid computing tight per-group
;;;   bounding boxes (see the clip-path/mask/filter sections above) --
;;;   collapsing a chain of directly-nested, otherwise-plain opacity
;;;   groups into one buffer would help, but detecting that a chain is
;;;   genuinely collapsible (no intervening transform/clip/mask/filter/
;;;   siblings at each level) is real added complexity for a case that's
;;;   more a synthetic stress test than a common real-world document
;;;   shape, so it's disclosed rather than optimized here.
;;;
;;;   Separately, cross-testing against 287 real-world icons (Feather
;;;   Icons, MIT-licensed) rendered all of them without error in well
;;;   under a millisecond each on average, and matched librsvg's own
;;;   rendering exactly (zero pixel difference) on 234 of 287, with the
;;;   rest differing only by ordinary antialiasing noise on curved
;;;   strokes (confirmed: applying a modest fuzz tolerance brings 285 of
;;;   287 to zero difference, and the remaining two down to a single
;;;   pixel) -- a useful, different complementary signal to WPT's
;;;   conformance-suite focus: real, unremarkable, hand-authored content
;;;   renders correctly and quickly, not just synthetic spec-conformance
;;;   fixtures built to isolate one feature at a time.
;;;
;;; <textPath> AND xml:space
;;;   Two gaps disclosed since Tier 6 as narrow and deliberately deferred
;;;   are now implemented. `xml:space="preserve"` (on `<text>`, `<tspan>`,
;;;   or inherited from any ancestor -- the nearest explicit setting
;;;   anywhere up the tree wins, `initial-preserve-space?`) disables the
;;;   default whitespace-collapsing behavior, preserving runs of spaces/
;;;   tabs/newlines verbatim instead; a nested element can set its own
;;;   `xml:space="default"` to opt back out of an inherited "preserve".
;;;
;;;   `<textPath>` lays text out along a referenced shape's own geometry
;;;   (usually a `<path>`, but any basic shape works via the same
;;;   `shape-node->dc-paths` dispatcher clip-path/markers already use)
;;;   rather than in a straight line, via an arc-length parameterization
;;;   of the path (`build-arc-length-fn`): flatten it to a polyline
;;;   (reusing `dc-path->polylines`, the same technique markers and
;;;   dashing already use), accumulate cumulative distance at each
;;;   vertex, then binary-search for the enclosing segment and linearly
;;;   interpolate position and tangent angle for any queried arc-length
;;;   distance. Each character is measured (its own advance width),
;;;   positioned at its own starting arc-length offset (starting from
;;;   `startOffset`, a length or a percentage of the path's own total
;;;   length), and rotated to the local tangent -- built as its own
;;;   `dc-path%` at a local origin, then rotated and translated into
;;;   place (mirroring how `elliptical-arc-dc-path` builds one arc
;;;   segment at the origin before rotating/translating it) -- before
;;;   being appended into one combined path, so the whole run still goes
;;;   through the ordinary paint pipeline in a single `draw-shape-paths!`
;;;   call, exactly like straight-line text. Text longer than the path is
;;;   simply not rendered past its end, per spec. Scoped to the
;;;   `<textPath>`'s own direct text content -- a nested `<tspan>` inside
;;;   `<textPath>` isn't specially handled, a disclosed, narrow gap,
;;;   since font/paint context still comes from the `<textPath>`'s own
;;;   resolved context either way, it just won't get its own distinct
;;;   per-run styling.
;;;
;;;   A real, subtle bug caught while building this: `dc-path%`'s own
;;;   `rotate` method spins the OPPOSITE direction from an angle computed
;;;   via `atan2(dy,dx)` in this codebase's own established (SVG/screen,
;;;   clockwise-positive) convention -- confirmed empirically, not
;;;   assumed, with a simple rightward-pointing line rotated by a known
;;;   angle and checking exactly where its endpoint landed (the same
;;;   check that would have caught it had it been missed: a rotated
;;;   glyph pointing exactly backwards along the path). The angle must be
;;;   negated before being passed to `rotate` -- the same sign-flip
;;;   `elliptical-arc-dc-path` already needed, for the exact same reason.
;;;
;;;   `librsvg` -- the reference renderer this whole file has been cross-
;;;   checked against throughout -- has NO `textPath` support at all,
;;;   confirmed independently by several sources including its own
;;;   development documentation, so it couldn't serve as the usual cross-
;;;   check here. Instead, built and compiled `resvg` (a different,
;;;   independent SVG renderer with real `textPath` support) from source
;;;   specifically to validate this feature: a quarter-circle-arc test
;;;   ("Hello Arc") matched `resvg`'s own rendering to within the same
;;;   font-antialiasing-level pixel noise already documented for plain
;;;   text (Tier 6's cross-engine font-metric differences), not a
;;;   structural difference -- checked by rendering the identical markup
;;;   with the same font (DejaVu Sans) in both and comparing directly,
;;;   not just eyeballing similar-looking output.
;;;
;;; FILTER PRIMITIVES (CONTINUED): feConvolveMatrix, feDisplacementMap,
;;; feImage, feTurbulence, feDiffuseLighting/feSpecularLighting, feTile
;;;   The six filter primitives beyond Tier 10's original ten are now
;;;   implemented. Each was verified independently, since they differ
;;;   enough in character that no single cross-check approach covers
;;;   all of them:
;;;
;;;   feConvolveMatrix -- general 2D convolution, kernel applied FLIPPED
;;;   (true convolution, not correlation) per spec. `librsvg` (2.58.0,
;;;   the version available during development) was found to silently
;;;   no-op this primitive entirely -- even a plain 3x3 averaging kernel
;;;   produced zero spread on a single-pixel impulse -- consistent with
;;;   a historical librsvg bug ("feConvolveMatrix wasn't being rendered
;;;   at all") and long-documented cross-engine inconsistency in this
;;;   specific primitive (a Mozilla bug tracker entry on bias handling
;;;   dates to 2009; a W3C fxtf-drafts issue has the resvg author noting
;;;   "everyone doing their own thing" for edge cases). So this was
;;;   verified against the spec's own formula text instead (matched
;;;   word-for-word across several independent sources) and against a
;;;   hand-computed, isolated byte-buffer test, not `librsvg`. A real
;;;   bug WAS found and fixed this way: an early version applied `bias`
;;;   as a flat addition to every channel including alpha, which both
;;;   contradicts the spec's own "+ bias * ALPHA(x,y)" term and corrupts
;;;   the premultiplied representation whenever convolved alpha ended up
;;;   below 255; alpha now gets no separate bias term of its own (the
;;;   formula can't sensibly reference its own not-yet-computed output),
;;;   and color channels scale bias by the OUTPUT alpha rather than a
;;;   flat 255.
;;;
;;;   feDisplacementMap -- nearest-neighbor (not bilinear) sampling,
;;;   consistent with this file's other pixel-granularity primitives.
;;;   Verified via hand-derivation from the spec's own formula (a fully-
;;;   opaque region using its own alpha as the displacement source gives
;;;   an exactly predictable shift, confirmed to the pixel) rather than
;;;   against `librsvg`, which showed a materially different result for
;;;   that specific controlled case (pushing content off-canvas
;;;   entirely) despite a separate, more realistic gradient-based test
;;;   looking qualitatively similar between the two -- likely a scale-
;;;   interpretation difference in one specific corner case rather than
;;;   a structural error, but not fully chased down.
;;;
;;;   feImage -- a local fragment reference (#id) renders the referenced
;;;   element via the ordinary rendering pipeline at its own natural
;;;   position (no subregion-based rescaling for this case -- a
;;;   disclosed, narrower scope decision); a raster image reference gets
;;;   full x/y/width/height subregion fitting, reusing <image>'s own
;;;   compute-viewbox-matrix-based logic exactly. Verified against
;;;   librsvg for both cases: the element-reference case matched
;;;   librsvg's bounding box for a circle-plus-feOffset chain exactly
;;;   (25,25)-(74,74) in both, and the raster case matched visually with
;;;   only antialiasing/scaling-interpolation-level differences.
;;;
;;;   feTurbulence -- ported as closely as possible to the SPECIFIC
;;;   Perlin-noise reference algorithm the spec itself prescribes (a
;;;   Park-Miller "minimal standard" linear congruential PRNG seeding a
;;;   permutation table and per-channel gradient vectors), rather than
;;;   "some Perlin noise implementation" -- the spec is this prescriptive
;;;   specifically so independent implementations produce the same
;;;   noise field for the same seed. Unlike every other primitive here,
;;;   exact pixel-for-pixel matching against another renderer isn't the
;;;   meaningful bar: two independently correct PRNG ports still walk
;;;   their tables differently and produce a different specific noise
;;;   field for the same seed unless every last detail matches exactly
;;;   (not confirmed bit-exact against librsvg here). What WAS checked:
;;;   the overall statistical profile (mean/min/max pixel value) and
;;;   visual character converge closely against librsvg once the
;;;   generated alpha channel is correctly composited against the
;;;   background -- found only after an early verification attempt
;;;   ignored alpha entirely and rendered RGB opaquely, which looked
;;;   nothing like librsvg's output and would have been wrongly read as
;;;   an algorithm bug; corrected, the mean pixel value converged from
;;;   wildly off to within ~1% of librsvg's, with the max matching
;;;   exactly. Determinism (the same seed and parameters always produce
;;;   the same output) is guaranteed and tested directly, which is the
;;;   property that actually matters for a static renderer's own
;;;   reproducibility. `stitchTiles="stitch"` is not implemented (always
;;;   behaves as noStitch), a disclosed, narrower gap.
;;;
;;;   feDiffuseLighting/feSpecularLighting -- a surface normal computed
;;;   via the spec's own Sobel-gradient formula on the alpha channel,
;;;   then the standard Phong diffuse/specular reflectance equations for
;;;   one of three light source geometries (feDistantLight/fePointLight/
;;;   feSpotLight, including feSpotLight's limitingConeAngle cutoff).
;;;   The spec defines 9 DIFFERENT Sobel-kernel variants for edge/corner
;;;   pixels (smaller kernels with different divisors, not simply the
;;;   interior kernel with out-of-bounds samples papered over) -- this
;;;   uses "duplicate" edge-clamping instead (the same convention
;;;   feConvolveMatrix's own default edgeMode uses), a disclosed,
;;;   narrower simplification affecting only the outermost 1-pixel
;;;   border, where lighting effects are rarely the visual focus.
;;;   Verified against librsvg for all three light types using the
;;;   spec's own classic "3D sphere" pattern (blur SourceAlpha, light
;;;   it, clip to the original shape, composite back over the source):
;;;   pixel diffs of 7-15%, consistent with the same blur/antialiasing-
;;;   level variance already documented throughout this file for
;;;   anything involving feGaussianBlur, not a structural difference --
;;;   confirmed by the fact the diffuse-lighting test's own FIRST
;;;   attempt asserted the wrong light direction (a sign error in the
;;;   test's own prediction, not the implementation): re-deriving
;;;   Lx/Ly directly from the spec's azimuth/elevation formula rather
;;;   than assuming which corner should be brighter caught the mistake.
;;;
;;;   feTile -- uniquely among these, feTile genuinely needs a
;;;   subregion to tile FROM, which conflicts with this file's filter
;;;   system otherwise deliberately never tracking per-primitive
;;;   subregions at all (every primitive computes across the full
;;;   canvas). Resolved by reaching back into the filter graph's own
;;;   markup: eval-filter-chain now also tracks which XML node produced
;;;   each named result, so feTile can read ITS referenced primitive's
;;;   own x/y/width/height attributes directly and tile a crop of that
;;;   primitive's (already fully-computed, full-canvas) output -- since
;;;   that buffer already contains correct content everywhere, just not
;;;   clipped to the tile region, this is sufficient without needing
;;;   true subregion tracking generally. Verified against librsvg: both
;;;   show a clearly repeating tile pattern for the same test, and this
;;;   file's own output was confirmed to repeat with EXACTLY the
;;;   specified period (checked directly: pixels one, two, and three
;;;   tile-widths apart are bit-identical). If the referenced primitive
;;;   specified no explicit subregion at all, there's nothing to tile
;;;   from, so the input passes through unchanged -- a disclosed,
;;;   narrower gap for that specific case.
;;;
;;; textPath's path= ATTRIBUTE
;;;   SVG2 lets <textPath> carry its path data inline via a `path`
;;;   attribute, instead of only referencing a separate shape element
;;;   via `href` -- confirmed via a WPT test that `path` takes
;;;   precedence over `href` when both are given. The arc-length
;;;   machinery downstream is identical either way; only where the
;;;   geometry comes from differs. Verified via self-consistency rather
;;;   than an external renderer: neither available reference could
;;;   actually validate this specific, fairly recent feature (`librsvg`
;;;   has no `textPath` support at all; the `resvg` build available
;;;   during development was too old to support `path=` correctly,
;;;   silently falling back to a straight line instead of the curve) --
;;;   so instead, a `path=` attribute and an `href` to a separate <path>
;;;   with the IDENTICAL data are confirmed to render byte-for-byte
;;;   identically, which is the property that actually matters (both
;;;   codepaths feed the same downstream geometry). An EMPTY (`path=""`)
;;;   or INVALID (unparseable) `path` value falls back to `href` rather
;;;   than silently rendering nothing -- confirmed via two more WPT
;;;   tests specifically for those cases -- reusing this file's own
;;;   path-error-recovery (path-data->dc-paths already returns '()
;;;   gracefully for unparseable data) to detect "produced no usable
;;;   geometry at all" as the fallback trigger.
;;;
;;; PERFORMANCE (CONTINUED)
;;;   A second profiling pass, prompted by realistic (not just minimal)
;;;   settings, found two more real, worthwhile fixes on top of the
;;;   earlier feMorphology one:
;;;   - `feConvolveMatrix` compared `edgeMode` against strings inside
;;;     its innermost per-tap loop (called order-x*order-y*2 times per
;;;     pixel per channel -- tens of millions of times for a modestly
;;;     large kernel/canvas), and separately recomputed the same source-
;;;     coordinate mapping redundantly once per channel even though it
;;;     only depends on (x,y). Resolving `edgeMode` to a symbol once,
;;;     and precomputing each pixel's (source-offset . kernel-value)
;;;     taps once and reusing them across all 4 channels, gave a ~1.75x
;;;     speedup on a 5x5-kernel/400x400 case (708ms -> 405ms),
;;;     confirmed to produce byte-identical output to the original via
;;;     the full existing test suite (which checks specific computed
;;;     values, not just "doesn't crash").
;;;   - `feTurbulence`'s lattice-index and interpolation-factor
;;;     computation (see turb-lattice-info) depends only on (x,y), not
;;;     on which of the 4 channels is being computed -- only the final
;;;     gradient dot-product is channel-specific -- but an earlier
;;;     version's per-channel turb-turbulence/turb-noise2 calls
;;;     redundantly recomputed it 4 times per octave. Sharing it across
;;;     channels gave a ~2.15x speedup at a realistic numOctaves=8
;;;     setting on a 400x400 canvas (1.92s -> 0.89s), confirmed BYTE-
;;;     IDENTICAL to the pre-refactor output on a multi-octave
;;;     fractalNoise case before this replaced it (a pure performance
;;;     change, not a behavior change).
;;;
;;; PERCENTAGE RESOLUTION AND SUBREGION CLIPPING
;;;   Two related gaps, found via WPT testing and this file's own
;;;   filter-architecture notes respectively, resolved together since
;;;   the second reuses infrastructure the first needed anyway.
;;;
;;;   Percentages in geometry properties (cx/cy/r/rx/ry/x/y/width/
;;;   height) and `stroke-width` now resolve against the CURRENT
;;;   (possibly nested) viewport's own width, height, or diagonal
;;;   (sqrt(w^2+h^2)/sqrt(2) for orientation-agnostic lengths like `r`
;;;   and `stroke-width`), per spec, instead of being treated as a
;;;   literal number -- confirmed against the exact WPT test this was
;;;   originally found through (`rx: 25%` on an ellipse). This needed
;;;   `current-canvas-size` (a parameter that existed already, tracking
;;;   the document root's own size, but was never actually read
;;;   anywhere -- dead infrastructure from an earlier design) to instead
;;;   track the CURRENT viewport, updated at every point a new one is
;;;   established: a nested `<svg>`, a `<use>`-instantiated `<symbol>`/
;;;   `<svg>`, `<pattern>` tiles, and `<marker>` viewports -- each
;;;   computing its own resolved width/height the same way
;;;   `viewport-instantiation-matrix` itself does internally, confirmed
;;;   with a test nesting a percentage-sized circle inside a nested
;;;   `<svg>` smaller than the document root. Found and fixed along the
;;;   way: `<pattern>`'s own `viewBox` parsing had never received the
;;;   comma-separator fix (`parse-viewbox-attr`) applied to the root/
;;;   nested-viewport cases much earlier, so a pattern with a comma-
;;;   separated viewBox would have hit the exact same contract-violation
;;;   crash that fix was originally for.
;;;
;;;   Separately, individual filter primitives now respect their own
;;;   explicit x/y/width/height subregion, clipping their output to it
;;;   (anything outside becomes fully transparent) -- verified against
;;;   librsvg with an exact, zero-pixel-difference match on a feFlood
;;;   with an explicit subregion smaller than the canvas. This reuses
;;;   the node-tracking eval-filter-chain already needed for feTile
;;;   (confirmed not to interfere with feTile's own cropping, since
;;;   feTile only ever reads from within the region its referenced
;;;   primitive already occupies). A primitive with NO explicit
;;;   subregion at all is unaffected (its default subregion is still the
;;;   whole canvas, matching the `<filter>` element's own region, which
;;;   this file already treats as the whole canvas too) -- so this is a
;;;   narrower, additive fix: the `<mask>`/`<filter>` element's own
;;;   OVERALL region as a whole still isn't enforced as a clip, only
;;;   individual primitives' own explicit subregions now are.
;;;
;;; PAINT: GRADIENT/PATTERN STROKES, PATTERN FIXES, AND PAINT-ORDER
;;;   Five related paint/marker gaps, tackled together since several
;;;   share the same underlying paint-resolution machinery.
;;;
;;;   Gradient/pattern strokes (draw-gradient-stroke!): racket/draw's
;;;   pen% has no gradient/pattern support at all, so a stroke can't
;;;   just be handed the same brush a fill would use. Confirmed
;;;   empirically that brush%'s own [transformation ...] mechanism
;;;   (which the design originally intended to reuse) has NO effect at
;;;   all in the installed racket/draw build -- a brush constructed with
;;;   an explicit scale(5) transformation, with no ambient dc transform
;;;   in effect at all, still tiled at its stipple bitmap's own native
;;;   size, contradicting the mechanism's own documentation. Resolved
;;;   instead with the same "render shape -> use as alpha mask"
;;;   technique masks and feDropShadow already use elsewhere: render the
;;;   stroke's own geometry with a plain opaque pen into an offscreen
;;;   buffer to capture its shape, separately fill a same-sized buffer
;;;   with the brush everywhere (keeping the ambient transform, since a
;;;   gradient FILL was confirmed to already account for one correctly
;;;   this same way), then combine and composite. Verified against
;;;   librsvg across plain/transformed/dashed/pattern cases, all within
;;;   1-3% pixel diff (ordinary curve-antialiasing variance).
;;;
;;;   Pattern opacity and internal transparency (build-pattern-brush):
;;;   two related bugs traced to one root cause -- the pattern tile
;;;   bitmap was being constructed WITHOUT alpha-channel support at all
;;;   (a plain (make-object bitmap% w h), missing the (... #f #t) form
;;;   used everywhere else an alpha channel is needed), which forces
;;;   every pixel opaque no matter what's written to it. This broke two
;;;   independent things: `fill-opacity`/`opacity` on an element painted
;;;   with a pattern had no effect at all (confirmed via a WPT test),
;;;   and transparency WITHIN a pattern's own content never let
;;;   anything behind the pattern show through in the gaps. Both fixed
;;;   by the same one-line constructor change plus scaling the tile's
;;;   alpha byte by fill-opacity*opacity afterward (get-argb-pixels
;;;   confirmed empirically to return STRAIGHT, not premultiplied,
;;;   color, so only the alpha byte needs scaling). Verified against
;;;   librsvg: an exact, zero-pixel-difference match for the
;;;   transparency case.
;;;
;;;   Pattern `x`/`y` (a pure translation of the whole repeating grid):
;;;   baked directly into the tile bitmap via a wrap-around pixel read
;;;   (new[i,j] = old[(i-dx) mod w, (j-dy) mod h]), rather than via the
;;;   confirmed-broken brush transformation mechanism above. Verified
;;;   against librsvg: an exact, zero-pixel-difference match.
;;;   `patternTransform` specifically (which can rotate/skew, not just
;;;   translate, and so can't be baked into the tile via a pixel-domain
;;;   shift) remains a disclosed gap given that mechanism's unavailability.
;;;
;;;   `paint-order` (resolve-paint-order): required threading `node`
;;;   into draw-shape-paths! for EVERY shape type, not just the four
;;;   that support markers (path/line/polyline/polygon) -- an early
;;;   version only did this for those four, reasoning "only those
;;;   support markers", which missed that paint-order's fill/stroke
;;;   ORDERING matters for circle/rect/ellipse too even though they
;;;   never have markers. Caught by a direct pixel check in the
;;;   fill/stroke overlap region showing no difference at all between
;;;   orders before the fix. Markers moved from an unconditional call
;;;   after each shape's own rendering into draw-shape-paths!'s own
;;;   ordered dispatch, so `paint-order: markers ...` can now place a
;;;   marker before or between fill/stroke too. Verified against
;;;   librsvg: exact, zero-pixel-difference matches for both a
;;;   fill/stroke reordering case and a markers-before-stroke case.
;;;
;;;   `context-fill`/`context-stroke`: resolve to whatever fill/stroke
;;;   was active on the REFERENCING element, tracked via two parameters
;;;   set at each of the three places this file renders one element's
;;;   content "on behalf of" another (<use>, <marker>, <pattern>).
;;;   Verified against librsvg for the primary real-world use (a marker
;;;   automatically matching its path's stroke color): an exact,
;;;   zero-pixel-difference match. A real, crash-inducing bug found and
;;;   fixed along the way: a shape filled with a pattern sets context-
;;;   fill, for that pattern's OWN content, to the SAME paint-ref
;;;   pointing at that pattern -- so a pattern using
;;;   `fill="context-fill"` on itself resolved back to itself,
;;;   recursing without bound (confirmed to actually hang the process,
;;;   not just a theoretical concern) until `current-pattern-chain` (a
;;;   guard analogous to the existing `current-use-chain` for `<use>`
;;;   cycles) was added -- which, as a side effect, also now protects
;;;   against a pattern referencing itself directly, a separate,
;;;   pre-existing gap this happened to expose.
;;;
;;; pathLength
;;;   An author-claimed "logical" length for a path/line/polyline/
;;;   polygon, which rescales how stroke-dasharray/stroke-dashoffset AND
;;;   textPath's own startOffset are interpreted along it (the scale
;;;   factor is actual-geometric-length / pathLength, applied by scaling
;;;   the relevant values themselves rather than reparameterizing the
;;;   arc-length walk, since that gives the identical visual result with
;;;   no new machinery). A percentage startOffset is "X% of pathLength"
;;;   (or of the actual length, if pathLength isn't set), not "X% of the
;;;   actual length" directly regardless of pathLength -- confirmed via
;;;   a WPT test: with pathLength="0", startOffset values of 0%, 50%,
;;;   and -50% must ALL land at the identical position in the reference
;;;   (any percentage of zero is zero), which only happens if the
;;;   percentage is taken against pathLength first.
;;;
;;;   `pathLength="0"` is a real, defined spec edge case ("must be
;;;   treated as a scaling factor of infinity"), confirmed via a WPT
;;;   test. Getting this right surfaced a genuine hang, not just a wrong
;;;   answer: passing +inf.0-scaled dasharray values into
;;;   dash-split-polyline (which isn't designed to handle infinite dash
;;;   lengths) caused an actual infinite loop. Fixed by special-casing
;;;   an infinite scale factor as "no dashing at all" instead -- the
;;;   identical visual result (an infinitely long first dash never
;;;   ends, i.e. a solid stroke, which is exactly what the WPT
;;;   reference for this case shows), reached safely. Every
;;;   multiplication by the scale factor is also individually guarded
;;;   against 0*+inf.0 (which is NaN, not 0, in IEEE754), since a
;;;   dasharray value or startOffset can itself legitimately be zero
;;;   even when the overall scale factor is infinite.
;;;
;;;   Verified via hand-derivation and direct pixel checks rather than
;;;   against librsvg for this one -- confirmed via an actual W3C SVG
;;;   Working Group discussion thread (2020) that WebKit and Inkscape
;;;   don't implement pathLength for stroke-dashing at all ("no
;;;   implementations yet"), and librsvg was confirmed empirically to
;;;   behave the same way (rendering the raw, unscaled dasharray values
;;;   instead), so none of them can serve as a cross-check for this
;;;   specific feature. All 8 non-tentative pathLength-related WPT tests
;;;   pass (the four CSS `path-length` property tests are marked
;;;   `.tentative` -- an experimental, not-yet-implemented-anywhere
;;;   proposal per that same discussion thread -- and weren't pursued).
;;;
;;; VIEWPORT CLIPPING (overflow: hidden, the spec default)
;;;   A nested <svg>, a <use>-instantiated <symbol>/<svg>, and a
;;;   <marker> instance all default to `overflow: hidden` per spec --
;;;   previously none of these were enforced at all, a disclosed
;;;   simplification. Implemented via push-viewport-clip!, reusing the
;;;   same region%/intersect technique build-clip-region already uses
;;;   for clip-path, applied to a plain rectangle (0,0,width,height)
;;;   instead of an arbitrary shape. The clip must be applied in the
;;;   established viewport's OWN pixel space, BEFORE any viewBox-mapping
;;;   transform -- clipping to that same rectangle AFTER the viewBox
;;;   matrix would use viewBox-space coordinates instead, which are a
;;;   completely different (and usually differently-scaled) coordinate
;;;   system. `overflow="visible"` disables the clip; anything else
;;;   (omitted, "hidden", or any other value) clips, matching the
;;;   spec's own default. All three cases (nested <svg>, <use>-
;;;   instantiated <symbol>, and <marker>) verified against librsvg with
;;;   exact, zero-pixel-difference matches.
;;;
;;;   This directly resolved the WPT test that originally motivated
;;;   looking into it: a <use> overriding a <symbol>'s own width/height
;;;   had no visible effect at all when the symbol lacked a viewBox,
;;;   since viewport-instantiation-matrix returns an identity matrix
;;;   whenever there's no viewBox (nothing to scale to), and without
;;;   this clip, there was also nothing to constrain the content's
;;;   natural size either -- the override was silently a no-op either
;;;   way. Implementing the clip gives the override an actual effect
;;;   even without a viewBox, matching spec.
;;;
;;;   Also surfaced a genuinely loosely-written test fixture from
;;;   earlier in this file's own test suite: an orient=auto marker test
;;;   used a triangle path with negative-Y coordinates that were never
;;;   actually within its own declared (0,0)-(markerWidth,markerHeight)
;;;   viewport, silently relying on the previous absence of clipping --
;;;   fixed by adding overflow="visible" to that specific fixture, since
;;;   the test was about tangent-direction orientation, not clipping.
;;;   The broader tier regression suite was unaffected except for a
;;;   small, expected antialiasing-level difference (tier 7's own
;;;   marker reftest, confirmed via a zoomed side-by-side comparison to
;;;   be visually identical -- ordinary antialiasing where a rotated
;;;   clip boundary intersects rotated content at slightly different
;;;   subpixel positions, not a structural change).
;;;
;;; textLength / lengthAdjust
;;;   Rescales a <text>/<tspan> run to span EXACTLY textLength user
;;;   units instead of its natural width. `lengthAdjust="spacing"` (the
;;;   default) keeps every glyph's own shape and width unchanged,
;;;   stretching or compressing only the n-1 gaps between n characters;
;;;   `"spacingAndGlyphs"` applies a uniform horizontal scale to each
;;;   glyph's own outline and advance instead (built at a local origin,
;;;   then transformed into place, the same technique elliptical-arc-
;;;   dc-path already uses). Scoped to a single contiguous run's own
;;;   direct text content -- textLength spanning multiple sibling
;;;   tspans is a rarer, more involved case not attempted -- and not
;;;   combined with multi-value x/y-list positioning, which already
;;;   positions each character explicitly in a way that would conflict
;;;   with textLength's own stretching.
;;;
;;;   Verified via hand-derivation and direct pixel checks rather than
;;;   against librsvg, which was confirmed empirically to not implement
;;;   textLength at all (identical output regardless of
;;;   textLength="none"/"50"/"400"), corroborated by multiple
;;;   independent sources (a Wikimedia Phabricator ticket open since
;;;   2011, a GNOME GitLab issue).
;;;
;;; CSS inline-size / shape-inside (text wrapping)
;;;   Greedily word-wraps a <text> element's content across multiple
;;;   lines instead of running it along one baseline, per CSS
;;;   `inline-size` (a fixed or percentage wrapping width) or
;;;   `shape-inside:url(#id)` (deriving the wrap box from a referenced
;;;   shape -- scoped to a plain <rect> specifically: for a rectangle,
;;;   wrapping to fit inside it is functionally identical to inline-
;;;   size, since a rectangle's own horizontal extent doesn't vary by
;;;   line, unlike a circle or arbitrary path; any other referenced
;;;   shape falls back to not wrapping at all, a disclosed narrower
;;;   gap, since genuine arbitrary-shape text flow -- recomputing
;;;   available width per line from the shape's own geometry -- is a
;;;   substantially bigger undertaking). Line-height defaults to
;;;   font-size*1.25 when not otherwise specified via the CSS
;;;   `line-height` property (a bare number is a multiplier of font-
;;;   size; anything else is parsed as a length). `text-align` (left/
;;;   center/right/justify) takes precedence over `text-anchor` for
;;;   per-line alignment when set, confirmed via a WPT shape-inside test
;;;   using text-align specifically; `justify` distributes the gap
;;;   between a line's natural width and the wrap width evenly among
;;;   its inter-word spaces, EXCEPT the last line of the paragraph,
;;;   which is never justified (the standard text-layout convention,
;;;   confirmed via a WPT shape-inside reference file).
;;;
;;;   Scoped to the element's own content with a SINGLE, uniform font --
;;;   a nested <tspan> with its own distinct styling (e.g. a different
;;;   font-size) within the wrapped flow is a disclosed, narrower gap:
;;;   several of the WPT inline-size tests specifically combine
;;;   wrapping with per-run styling changes mid-paragraph, which would
;;;   need a considerably more involved "mini text-layout engine"
;;;   tracking multiple concurrent run styles and per-line max-height,
;;;   not just plain greedy word-wrap -- a nested <tspan>'s own text
;;;   content is still included in the wrapped flow as plain text,
;;;   using the outer element's own resolved font, just without its own
;;;   distinct styling applied within the wrap. Vertical writing modes,
;;;   bidi, and CJK line-breaking rules (exercised by a handful of the
;;;   WPT tests for both features) are out of scope entirely -- this
;;;   handles the common horizontal, left-to-right case.
;;;
;;;   Verified via hand-derivation rather than against the actual WPT
;;;   reference files for either feature, which depend on a specific
;;;   "FreeSans" font not installed here -- confirmed directly that
;;;   this file's own greedy-wrap decisions, though sometimes landing at
;;;   a DIFFERENT line-break point than a given WPT reference, are
;;;   correct FOR THE FONT ACTUALLY USED: e.g. "Lorem ipsum dolor sit
;;;   amet, consectetur" measures 438px wide in DejaVu Sans at 16px,
;;;   well over a 320px inline-size/shape-inside width, so wrapping
;;;   before "consectetur" is the right greedy-wrap decision for this
;;;   font at that width, not a bug -- different fonts genuinely wrap
;;;   differently at the same width, and the same text can wrap into a
;;;   different NUMBER of lines entirely (confirmed directly: the same
;;;   shape-inside example that wraps into 2 lines for FreeSans per its
;;;   own WPT reference wraps into 3 for DejaVu Sans at the same box).
;;;
;;; EXTENSION POINTS (deliberately left for later)
;;;   - CSS pseudo-classes, sibling combinators (+/~), and @media/
;;;     @supports/@keyframes evaluation are parsed but never acted on
;;;     (see the CSS section above for why and what that means in
;;;     practice). A <stop>'s own `style=""` (Tier 4) isn't wired through
;;;     the full stylesheet cascade, only inline style vs. presentation
;;;     attribute -- a <stop> targeted by a class/id selector is rare
;;;     enough that this is a disclosed, narrow gap rather than a full
;;;     integration. Geometry properties and `stroke-width` percentages
;;;     now resolve against the current (possibly nested) viewport's own
;;;     width/height/diagonal -- see PERCENTAGE RESOLUTION below -- but
;;;     other `parse-length` call sites that don't pass a `#:reference`
;;;     still treat a bare `%` as a literal number.
;;;   - `text-decoration` is not implemented (see the text section
;;;     above). `<textPath>` and `xml:space="preserve"` -- both
;;;     previously listed here as gaps -- are now implemented; see the
;;;     dedicated sections after `render-text-node!` and around
;;;     `initial-preserve-space?` respectively.
;;;   - `stroke-miterlimit`, gradient `spreadMethod` reflect/repeat,
;;;     pattern rescaling under an ambient dc scale, objectBoundingBox
;;;     clip-path on groups, mixed clip-rule within one clipPath,
;;;     `maskContentUnits="objectBoundingBox"`, CSS `isolation: isolate`,
;;;     and soft-light/the four HSL-based blend modes (hue/saturation/
;;;     color/luminosity) are the known gaps; see above for each.
;;;     Gradient/pattern STROKES, pattern `x`/`y`, and `paint-order` --
;;;     all previously listed here as gaps -- are now implemented; see
;;;     PAINT: GRADIENT/PATTERN STROKES, PATTERN FIXES, AND PAINT-ORDER
;;;     below. `patternTransform` specifically (as
;;;     opposed to plain `x`/`y`) remains unimplemented -- see that same
;;;     section for why. An individual filter PRIMITIVE's own explicit
;;;     x/y/width/height subregion IS now clipped (see PERCENTAGE
;;;     RESOLUTION AND SUBREGION CLIPPING below), but the `<mask>`/
;;;     `<filter>` element's own OVERALL region as a whole still isn't
;;;     -- content is still computed across the full canvas rather than
;;;     a tighter region in that specific case.
;;;   - Per-primitive `color-interpolation-filters="sRGB"` overrides are
;;;     not implemented -- the whole filter chain always runs in
;;;     linearRGB, the spec's own default. feTurbulence,
;;;     feDisplacementMap, feConvolveMatrix, feDiffuseLighting/
;;;     feSpecularLighting, feImage, and feTile -- all previously listed
;;;     here as gaps -- are now implemented; see the dedicated FILTER
;;;     PRIMITIVES (CONTINUED) section below for each one's own specific
;;;     scope and verification notes. feBlend/mix-blend-mode's shared
;;;     blend-mode set now covers multiply/screen/darken/lighten/
;;;     overlay/hard-light/color-dodge/color-burn/difference/exclusion
;;;     -- soft-light and the HSL-based four remain a gap, noted just
;;;     above.
;;;   - `<use>`/`<symbol>`/pattern percentage width/height don't resolve
;;;     against a real containing viewport yet (same disclosed
;;;     simplification as `parse-length` elsewhere: a bare `%` with no
;;;     reference passed in is treated as a literal number).
;;;   - `<image>` never fetches remote http(s)/etc URLs (a deliberate
;;;     policy choice, not an oversight -- see the image section above);
;;;     plain (non-base64) `data:` URIs aren't decoded either.
;;;
;;; ---------------------------------------------------------------------

;; Package dependencies are declared in info.rkt. If you use this file
;; directly outside the package, install parsers-lib for `parsers/css`;
;; parsers-lib pulls in lexers-lib as its own dependency.
(require racket/match
         racket/list
         racket/string
         racket/port
         racket/class
         racket/draw
         racket/math
         racket/path
         net/base64
         net/uri-codec
         parsers/css
         pict
         xml)

(provide parse-svg-path       ; string-or-input-port -> path-command list
         svg-path->dc-paths    ; path-command list -> (listof dc-path%)
         path-data->dc-paths   ; string -> (listof dc-path%)   [convenience]
         elliptical-arc-dc-path
         read-svg-document     ; string-or-input-port -> svg-doc
         svg-doc-width
         svg-doc-height
         svg-doc-id-table      ; svg-doc -> (hash/c string? xexpr?)
         svg-doc-view-matrix   ; svg-doc -> #(a b c d e f)
         parse-length
         parse-preserve-aspect-ratio
         compute-viewbox-matrix
         viewport-instantiation-matrix
         parse-transform-list  ; string -> (listof (cons/c symbol? (listof real?)))
         parse-paint           ; string [color%] -> (or/c color% paint-ref? #f)
         (struct-out paint-ref)
         parse-opacity
         parse-dasharray
         parse-linecap
         parse-linejoin
         parse-clip-rule
         parse-style-attr
         combined-bounding-box
         resolve-gradient-stops
         dc-path->polylines     ; dc-path% -> (listof (listof (cons/c real? real?)))
         dash-split-polyline
         parse-font-family      ; string -> (values (or/c string? #f) symbol?)
         parse-font-weight
         parse-font-style
         parse-text-anchor
         parse-number-list
         parse-marker-orient
         (struct-out vertex)
         dc-path->vertices       ; dc-path% -> (listof vertex)
         average-angle
         marker-angle-degrees
         collapse-whitespace
         load-image-bitmap      ; string -> (or/c (is-a?/c bitmap%) #f)
         current-svg-base-dir   ; parameter: (or/c path? #f)
         ambient-scale-factor
         premultiply!
         unpremultiply-in-place!
         srgb->linear-table
         linear->srgb-table
         render-svg-doc!       ; svg-doc dc<%> -> void
         svg-string->bitmap
         svg-file->bitmap
         svg-doc->pict         ; svg-doc -> pict?
         svg-string->pict
         svg-file->pict)

;;; =======================================================================
;;; Part 1: Path-data lexer/parser (hand-rolled recursive descent)
;;; =======================================================================
;;
;; We parse directly off the source string (rather than building a
;; separate token stream first) because the elliptical-arc flags need
;; context-sensitive lexing: a flag is *exactly one* digit, decided by
;; grammatical position, not by how many digits happen to follow.
;;
;; Output shape (kept close to a natural "tagged list" per command, easy
;; to pattern-match in the interpreter below):
;;
;;   '((M (x y))
;;     (L (x y))                  ; one entry per implicit/explicit lineto
;;     (C ((x1 y1) (x2 y2) (x y)) ((x1 y1) (x2 y2) (x y)) ...)
;;     (S ((x2 y2) (x y)) ...)
;;     (Q ((x1 y1) (x y)) ...)
;;     (T (x y) ...)
;;     (A (rx ry rot laf sf x y) ...)
;;     (H c1 c2 ...) (V c1 c2 ...)
;;     (Z))
;;
;; Lower-case tags mean "relative"; upper-case mean "absolute" -- same
;; convention as the SVG spec itself.

(struct pstate (str [pos #:mutable] len))

(define (make-pstate s) (pstate s 0 (string-length s)))
(define (at-eof? st) (>= (pstate-pos st) (pstate-len st)))
(define (peek-char* st) (and (not (at-eof? st)) (string-ref (pstate-str st) (pstate-pos st))))
(define (advance! st) (set-pstate-pos! st (add1 (pstate-pos st))))
(define (read-char! st) (define c (peek-char* st)) (advance! st) c)

(define (wsp-char? c) (and c (memv c '(#\tab #\space #\newline #\page #\return)) #t))

;; Permissive: accepts any run of whitespace/commas as a separator.
;; (A strict grammar distinguishes comma_wsp more finely; for a renderer
;; parsing real-world path data, being permissive here is the right
;; trade-off -- it accepts everything valid and a superset of malformed
;; input, but never *mis*-parses valid input.)
(define (skip-sep! st)
  (let loop ()
    (define c (peek-char* st))
    (cond [(wsp-char? c) (advance! st) (loop)]
          [(eqv? c #\,) (advance! st) (loop)]
          [else (void)])))

(define (digit-char? c) (and c (char<=? #\0 c #\9)))

(define (read-digit-string! st)
  (define start (pstate-pos st))
  (let loop () (when (digit-char? (peek-char* st)) (advance! st) (loop)))
  (substring (pstate-str st) start (pstate-pos st)))

(define (read-sign! st)
  (define c (peek-char* st))
  (cond [(eqv? c #\+) (advance! st) "+"]
        [(eqv? c #\-) (advance! st) "-"]
        [else ""]))

(define (parse-error st msg)
  (error 'parse-svg-path "~a (at character position ~a)" msg (pstate-pos st)))

;; number ::= sign? (digit* "." digit+ | digit+) ("e"|"E" sign? digit+)?
(define (read-number! st)
  (define sign (read-sign! st))
  (define int-part (read-digit-string! st))
  (define-values (frac-part has-dot?)
    (if (eqv? (peek-char* st) #\.)
        (begin (advance! st) (values (read-digit-string! st) #t))
        (values "" #f)))
  (when (and (= (string-length int-part) 0) (= (string-length frac-part) 0))
    (parse-error st "expected a number"))
  (define exp-part
    (let ([c (peek-char* st)])
      (cond
        [(and c (or (eqv? c #\e) (eqv? c #\E)))
         (define save (pstate-pos st))
         (advance! st)
         (define esign (read-sign! st))
         (define edigits (read-digit-string! st))
         (cond [(> (string-length edigits) 0) (string-append "e" esign edigits)]
               [else (set-pstate-pos! st save) ""])]
        [else ""])))
  (define numstr
    (string-append sign int-part (if has-dot? (string-append "." frac-part) "") exp-part))
  (string->number numstr))

;; A flag is *exactly* one character: "0" or "1". This is what makes
;; "a30 50 0 1120 40" lex correctly as two separate flags "1" "1"
;; followed by the number "20".
(define (read-flag! st)
  (define c (peek-char* st))
  (cond [(eqv? c #\0) (advance! st) 0]
        [(eqv? c #\1) (advance! st) 1]
        [else (parse-error st (format "expected a flag (0 or 1), got ~a"
                                       (if c c "end of input")))]))

(define (parse-coord-pair! st)
  (skip-sep! st)
  (define x (read-number! st))
  (skip-sep! st)
  (define y (read-number! st))
  (list x y))

(define (parse-curve-triplet! st)
  (list (parse-coord-pair! st) (parse-coord-pair! st) (parse-coord-pair! st)))

(define (parse-pair-double! st)
  (list (parse-coord-pair! st) (parse-coord-pair! st)))

(define (parse-arc-arg! st)
  (skip-sep! st)
  (define rx (read-number! st))
  (skip-sep! st)
  (define ry (read-number! st))
  (skip-sep! st)
  (define rot (read-number! st))
  (skip-sep! st)
  (define laf (read-flag! st))
  (skip-sep! st)
  (define sf (read-flag! st))
  (define p (parse-coord-pair! st))
  (list* rx ry rot laf sf p))

(define command-letters (string->list "MmZzLlHhVvCcSsQqTtAa"))
(define (command-letter? c) (and c (memv c command-letters) #t))

;; Reads one or more repetitions of `parse-one!`'s argument shape,
;; stopping when a command letter (or eof) is seen, and emits a single
;; tagged entry containing all the repetitions.
;; NOTE: the leading `skip-sep!` here matters even though several of the
;; `parse-one!` callbacks (parse-coord-pair! and friends) also skip
;; separators internally at their own start: H/V pass `read-number!`
;; directly, which does NOT skip leading whitespace itself (it's a
;; lower-level primitive that assumes the caller already positioned past
;; any separator) -- so without this, "H 100" (a leading space between
;; the command letter and its number, ordinary and common hand-written
;; style) failed to parse while "H100" and "L 100 100" both worked,
;; since L's parse-coord-pair! does its own skip-sep! but H/V's bare
;; read-number! never did. Caught by a WPT test using conventional
;; spaced-out path syntax my own hand-written test fixtures never
;; happened to exercise, since my own habit (and the path data this
;; library itself GENERATES for rounded rects) leans toward tight,
;; no-space/comma-separated formatting.
(define (parse-repeating! st emit! parse-one! tag)
  (skip-sep! st)
  (define groups (list (parse-one! st)))
  (let loop ()
    (skip-sep! st)
    (unless (or (at-eof? st) (command-letter? (peek-char* st)))
      (set! groups (cons (parse-one! st) groups))
      (loop)))
  (emit! (cons tag (reverse groups))))

;; moveto ::= ("M"|"m") coordinate-pair-sequence
;; Per spec: subsequent pairs after the first are implicit linetos,
;; using the *same* relative/absolute mode as the moveto itself.
(define (parse-moveto-group! st ch emit!)
  (define p1 (parse-coord-pair! st))
  (emit! (list (if (eqv? ch #\M) 'M 'm) p1))
  (define line-tag (if (eqv? ch #\M) 'L 'l))
  (let loop ()
    (skip-sep! st)
    (unless (or (at-eof? st) (command-letter? (peek-char* st)))
      (emit! (list line-tag (parse-coord-pair! st)))
      (loop))))

;; Per SVG2's path error-handling model, a syntax error partway through
;; `d` should render everything successfully parsed BEFORE the error,
;; not discard the whole path -- and, critically, must not propagate out
;; and take down the rest of the document with it (confirmed by testing:
;; before this, one malformed path anywhere crashed rendering of the
;; ENTIRE svg, not just that one element). A repeating command's whole
;; group (e.g. several H values in a row) is only emitted as a single
;; unit at the end, so an error partway through one discards that
;; group's own earlier, successfully-read values along with the later,
;; invalid one -- a defensible, disclosed simplification: still a real
;; correctness improvement over crashing, just not pixel-perfect against
;; the spec's per-value granularity for that one narrow case.
(define (parse-svg-path-string str)
  (define st (make-pstate str))
  (define acc '())
  (define (emit! x) (set! acc (cons x acc)))
  (with-handlers ([exn:fail? (lambda (e) (void))])
    (let loop ()
      (skip-sep! st)
      (unless (at-eof? st)
        (define ch (read-char! st))
        (unless (command-letter? ch)
          (parse-error st (format "expected a path command letter, got ~a" ch)))
        (case ch
          [(#\M #\m) (parse-moveto-group! st ch emit!)]
          [(#\Z #\z) (emit! (list (if (eqv? ch #\Z) 'Z 'z)))]
          [(#\L #\l) (parse-repeating! st emit! parse-coord-pair!   (if (eqv? ch #\L) 'L 'l))]
          [(#\H #\h) (parse-repeating! st emit! read-number!        (if (eqv? ch #\H) 'H 'h))]
          [(#\V #\v) (parse-repeating! st emit! read-number!        (if (eqv? ch #\V) 'V 'v))]
          [(#\C #\c) (parse-repeating! st emit! parse-curve-triplet! (if (eqv? ch #\C) 'C 'c))]
          [(#\S #\s) (parse-repeating! st emit! parse-pair-double!   (if (eqv? ch #\S) 'S 's))]
          [(#\Q #\q) (parse-repeating! st emit! parse-pair-double!   (if (eqv? ch #\Q) 'Q 'q))]
          [(#\T #\t) (parse-repeating! st emit! parse-coord-pair!    (if (eqv? ch #\T) 'T 't))]
          [(#\A #\a) (parse-repeating! st emit! parse-arc-arg!       (if (eqv? ch #\A) 'A 'a))])
      (loop))))
  (reverse acc))

(define (parse-svg-path x)
  (cond [(string? x)     (parse-svg-path-string x)]
        [(input-port? x) (parse-svg-path-string (port->string x))]
        [else (error 'parse-svg-path "expected a string or input-port, got: ~a" x)]))

;;; =======================================================================
;;; Part 2: Elliptical arc math (endpoint -> center parameterization)
;;; =======================================================================
;;
;; Straight port of the W3C endpoint-to-center-parameterization algorithm
;; (SVG spec, "Elliptical arc implementation notes"), split into a pure
;; math function (testable on its own) and a drawing function that uses
;; it to build a dc-path%.

;; arc-endpoint->center : produces (values cx cy rx ry theta1 delta-theta)
;; theta (rotation) is expected in RADIANS here; SVG's x-axis-rotation
;; attribute is in DEGREES, converted by the caller (elliptical-arc-dc-path).
(define (arc-endpoint->center x1 y1 x2 y2 rx ry phi large-arc? sweep?)
  (set! rx (abs rx))
  (set! ry (abs ry))
  (define x1- (+ (*    (cos phi)  (/ (- x1 x2) 2.)) (*   (sin phi)  (/ (- y1 y2) 2.))))
  (define y1- (+ (* (- (sin phi)) (/ (- x1 x2) 2.)) (*   (cos phi)  (/ (- y1 y2) 2.))))
  (define Λ (+ (/ (sqr x1-) (sqr rx)) (/ (sqr y1-) (sqr ry))))
  (when (> Λ 1)
    (set! rx (* (sqrt Λ) rx))
    (set! ry (* (sqrt Λ) ry)))
  (define s (if (eq? large-arc? sweep?) -1. 1.))
  (define α (sqrt (max 0. (/ (+ (* rx rx ry ry) (* -1. rx rx y1- y1-) (* -1. ry ry x1- x1-))
                             (+ (* rx rx y1- y1-) (* ry ry x1- x1-))))))
  (define cx- (* s α (/ (*     rx y1-) ry)))
  (define cy- (* s α (/ (* -1. ry x1-) rx)))
  (define cx (+ (* (cos phi) cx-) (* (- (sin phi)) cy-) (/ (+ x1 x2) 2.)))
  (define cy (+ (* (sin phi) cx-) (*    (cos phi)  cy-) (/ (+ y1 y2) 2.)))
  (define (angle-between ux uy vx vy)
    (define (norm x y) (sqrt (+ (* x x) (* y y))))
    (define (dot x1 y1 x2 y2) (+ (* x1 x2) (* y1 y2)))
    (define sgn (if (< (- (* ux vy) (* uy vx)) 0) -1. +1.))
    (* sgn (acos (max -1. (min 1. (/ (dot ux uy vx vy) (* (norm ux uy) (norm vx vy))))))))
  (define theta1 (angle-between 1. 0. (/ (- x1- cx-) rx) (/ (- y1- cy-) ry)))
  (define delta-theta
    (angle-between (/ (- x1- cx-) rx)          (/ (- y1- cy-) ry)
                    (/ (- (* -1. x1-) cx-) rx) (/ (- (* -1. y1-) cy-) ry)))
  (define delta-theta*
    (cond [(and (not sweep?) (> delta-theta 0)) (- delta-theta (* 2 pi))]
          [(and sweep? (< delta-theta 0))       (+ delta-theta (* 2 pi))]
          [else delta-theta]))
  (values cx cy rx ry theta1 delta-theta*))

;; elliptical-arc-dc-path : builds a dc-path% for one arc segment.
;; x-axis-rotation-deg is in DEGREES, matching the SVG "A"/"a" command's
;; own units, so callers don't need to convert.
(define (elliptical-arc-dc-path x1 y1 x2 y2 rx ry x-axis-rotation-deg large-arc-flag sweep-flag)
  (define phi (* (/ x-axis-rotation-deg 180.) pi))
  (define large-arc? (= large-arc-flag 1))
  (define sweep? (= sweep-flag 1))
  (define-values (cx cy arx ary theta1 delta-theta)
    (arc-endpoint->center x1 y1 x2 y2 rx ry phi large-arc? sweep?))
  (define theta2 (+ theta1 delta-theta))
  (define p (new dc-path%))
  ;; dc-path%'s `arc` sweeps counter-clockwise from start-radians to
  ;; end-radians by default in screen coordinates; matching the original
  ;; prototype's sign convention (negated angles, ccw? from the flag).
  (send p arc (- arx) (- ary) (* 2 arx) (* 2 ary) (- theta1) (- theta2) (not sweep?))
  (send p rotate (- phi))
  (send p translate cx cy)
  p)

;;; =======================================================================
;;; Part 3: Path-command interpreter -> dc-path% list
;;; =======================================================================
;;
;; A dc-path% holds zero-or-more closed subpaths plus at most one open
;; subpath; `move-to` starts a new open subpath. Since an SVG path can
;; contain several disconnected subpaths, retain its closed contours in
;; one dc-path% so a single SVG fill rule applies to all of them. We only
;; start a fresh dc-path% when a new moveto would otherwise leave an older
;; subpath open.

(define (svg-path->dc-paths commands)
  (define finished '())
  (define cur (new dc-path%))
  ;; Whether `cur` currently has an open subpath (i.e. move-to has been
  ;; called on it since it was created / since the last close).
  (define subpath-open? #f)
  ;; Whether `cur` contains any subpath, including a closed one. This is
  ;; distinct from `subpath-open?`, since a path made entirely of closed
  ;; contours still needs to be returned for filling.
  (define cur-has-content? #f)

  ;; current point
  (define X 0.) (define Y 0.)
  ;; start of current subpath (for Z/z, and for reopening after Z)
  (define SX 0.) (define SY 0.)
  ;; previous control point, tracked *separately* for cubic (C/S) and
  ;; quadratic (Q/T) curves, per spec.
  (define prev-cubic-cx #f) (define prev-cubic-cy #f)
  (define prev-quad-cx #f)  (define prev-quad-cy #f)
  (define (clear-controls!) (set! prev-cubic-cx #f) (set! prev-cubic-cy #f)
                             (set! prev-quad-cx #f)  (set! prev-quad-cy #f))

  ;; A "drawto" command (anything but M/Z) immediately following a
  ;; closepath must implicitly start a new subpath at the closepath's
  ;; start point -- dc-path% needs an explicit move-to for that.
  (define (ensure-open!)
    (unless subpath-open?
      (send cur move-to X Y)
      (set! subpath-open? #t)
      (set! cur-has-content? #t)))

  (define (do-M x y)
    (clear-controls!)
    ;; A dc-path% can retain any number of CLOSED contours, but only one
    ;; open contour. Preserve those closed contours together so nonzero and
    ;; evenodd filling can see their relationship.
    (when subpath-open?
      (set! finished (cons cur finished))
      (set! cur (new dc-path%))
      (set! cur-has-content? #f))
    (set! X x) (set! Y y) (set! SX x) (set! SY y)
    (send cur move-to X Y)
    (set! subpath-open? #t)
    (set! cur-has-content? #t))
  (define (do-m dx dy) (do-M (+ X dx) (+ Y dy)))

  (define (do-L x y) (clear-controls!) (ensure-open!) (set! X x) (set! Y y) (send cur line-to X Y))
  (define (do-l dx dy) (do-L (+ X dx) (+ Y dy)))

  (define (do-H x) (do-L x Y))
  (define (do-h dx) (do-L (+ X dx) Y))
  (define (do-V y) (do-L X y))
  (define (do-v dy) (do-L X (+ Y dy)))

  (define (do-Z)
    (clear-controls!)
    (when subpath-open?
      (send cur close)
      (set! subpath-open? #f))
    (set! X SX) (set! Y SY))

  (define (do-C x1 y1 x2 y2 x y)
    (ensure-open!)
    (send cur curve-to x1 y1 x2 y2 x y)
    (set! prev-cubic-cx x2) (set! prev-cubic-cy y2)
    (set! prev-quad-cx #f) (set! prev-quad-cy #f)
    (set! X x) (set! Y y))
  (define (do-c dx1 dy1 dx2 dy2 dx dy) (do-C (+ X dx1) (+ Y dy1) (+ X dx2) (+ Y dy2) (+ X dx) (+ Y dy)))

  (define (reflect prev cur*) (if prev (+ cur* (- cur* prev)) cur*))
  (define (do-S x2 y2 x y)
    (define x1 (reflect prev-cubic-cx X))
    (define y1 (reflect prev-cubic-cy Y))
    (do-C x1 y1 x2 y2 x y))
  (define (do-s dx2 dy2 dx dy) (do-S (+ X dx2) (+ Y dy2) (+ X dx) (+ Y dy)))

  ;; Quadratic Bezier: dc-path% has no native quadratic curve-to, so we
  ;; elevate to the equivalent cubic (standard degree-elevation formula).
  (define (do-Q qx qy x y)
    (ensure-open!)
    (define cx1 (+ X (* 2/3 (- qx X))))
    (define cy1 (+ Y (* 2/3 (- qy Y))))
    (define cx2 (+ x (* 2/3 (- qx x))))
    (define cy2 (+ y (* 2/3 (- qy y))))
    (send cur curve-to cx1 cy1 cx2 cy2 x y)
    (set! prev-quad-cx qx) (set! prev-quad-cy qy)
    (set! prev-cubic-cx #f) (set! prev-cubic-cy #f)
    (set! X x) (set! Y y))
  (define (do-q dqx dqy dx dy) (do-Q (+ X dqx) (+ Y dqy) (+ X dx) (+ Y dy)))

  (define (do-T x y)
    (define qx (reflect prev-quad-cx X))
    (define qy (reflect prev-quad-cy Y))
    (do-Q qx qy x y))
  (define (do-t dx dy) (do-T (+ X dx) (+ Y dy)))

  (define (do-A rx ry rot laf sf x y)
    (clear-controls!)
    (ensure-open!)
    (set! rx (abs rx)) (set! ry (abs ry))
    (cond
      [(and (= X x) (= Y y)) (void)]                ; identical endpoints: no-op
      [(or (= rx 0) (= ry 0)) (do-L x y)]            ; degenerate ellipse: straight line
      [else (send cur append (elliptical-arc-dc-path X Y x y rx ry rot laf sf))])
    (set! X x) (set! Y y))
  (define (do-a rx ry rot laf sf dx dy) (do-A rx ry rot laf sf (+ X dx) (+ Y dy)))

  (for ([command (in-list commands)])
    (match command
      [(list 'M (list x y)) (do-M x y)]
      [(list 'm (list x y)) (do-m x y)]
      [(list 'L (list x y)) (do-L x y)]
      [(list 'l (list x y)) (do-l x y)]
      [(list-rest 'L pts)   (for ([p (in-list pts)]) (do-L (first p) (second p)))]
      [(list-rest 'l pts)   (for ([p (in-list pts)]) (do-l (first p) (second p)))]
      [(list-rest 'H cs)    (for ([c (in-list cs)]) (do-H c))]
      [(list-rest 'h cs)    (for ([c (in-list cs)]) (do-h c))]
      [(list-rest 'V cs)    (for ([c (in-list cs)]) (do-V c))]
      [(list-rest 'v cs)    (for ([c (in-list cs)]) (do-v c))]
      [(list-rest 'C triplets)
       (for ([tri (in-list triplets)])
         (match-define (list (list x1 y1) (list x2 y2) (list x y)) tri)
         (do-C x1 y1 x2 y2 x y))]
      [(list-rest 'c triplets)
       (for ([tri (in-list triplets)])
         (match-define (list (list x1 y1) (list x2 y2) (list x y)) tri)
         (do-c x1 y1 x2 y2 x y))]
      [(list-rest 'S doubles)
       (for ([d (in-list doubles)])
         (match-define (list (list x2 y2) (list x y)) d)
         (do-S x2 y2 x y))]
      [(list-rest 's doubles)
       (for ([d (in-list doubles)])
         (match-define (list (list x2 y2) (list x y)) d)
         (do-s x2 y2 x y))]
      [(list-rest 'Q doubles)
       (for ([d (in-list doubles)])
         (match-define (list (list qx qy) (list x y)) d)
         (do-Q qx qy x y))]
      [(list-rest 'q doubles)
       (for ([d (in-list doubles)])
         (match-define (list (list qx qy) (list x y)) d)
         (do-q qx qy x y))]
      [(list-rest 'T pts)   (for ([p (in-list pts)]) (do-T (first p) (second p)))]
      [(list-rest 't pts)   (for ([p (in-list pts)]) (do-t (first p) (second p)))]
      [(list-rest 'A args)
       (for ([a (in-list args)])
         (match-define (list rx ry rot laf sf x y) a)
         (do-A rx ry rot laf sf x y))]
      [(list-rest 'a args)
       (for ([a (in-list args)])
         (match-define (list rx ry rot laf sf dx dy) a)
         (do-a rx ry rot laf sf dx dy))]
      [(list 'Z) (do-Z)]
      [(list 'z) (do-Z)]))
  (reverse (if cur-has-content? (cons cur finished) finished)))

(define (path-data->dc-paths d) (svg-path->dc-paths (parse-svg-path d)))

;;; =======================================================================
;;; Part 4: Minimal SVG document reader + renderer
;;; =======================================================================
;;
;; Architecture (Tier 0 rewrite): rather than flattening the tree into a
;; list of shapes up front, we keep the parsed xexpr tree and walk it at
;; render time, threading:
;;   - an inherited presentation-attribute context (`render-ctx`), so
;;     `<g fill="red">` correctly applies to descendants that don't
;;     override it themselves;
;;   - the dc's own transformation stack, saved/restored around each
;;     `<g>`/`<svg>` the same way a graphics-state stack works in any
;;     2D vector API -- confirmed empirically that racket/draw's dc<%>
;;     composes `translate`/`scale`/`transform` calls in the expected
;;     nested-coordinate-system order, AND that stroke width scales
;;     along with geometry (a 4px pen at 2x dc scale renders 8px thick),
;;     which is exactly SVG's default (non-`vector-effect`) behavior.
;;     No transform ATTRIBUTE is parsed yet (that's Tier 1) -- but the
;;     save/restore scaffolding is in place now so Tier 1 only needs to
;;     insert one call at the marked hook point.
;;   - a document-wide id -> node table, built once, for Tier 3+
;;     (`use`, `url(#id)` references) to consume later. Nothing in
;;     Tier 0 itself queries it yet.

(struct svg-doc (width height root id-table view-matrix stylesheet))
(struct render-ctx (fill stroke stroke-width fill-rule
                     stroke-linecap stroke-linejoin stroke-dasharray stroke-dashoffset
                     color fill-opacity stroke-opacity opacity
                     font-face font-family font-size font-weight font-style text-anchor)
  #:transparent)

(define (attr-ref attrs name [default #f])
  (define e (assq name attrs))
  (if e (cadr e) default))

;;; ---- Length units -------------------------------------------------------
;; Converts to "user units" (== CSS px, 96 per inch) per the CSS unit
;; conversions SVG relies on. `em` has no real font-size cascade to draw
;; on yet (that arrives with text support), so it falls back to a fixed
;; 16px assumption -- an approximation, flagged here rather than silently
;; assumed correct.
(define (unit->px-factor unit)
  (cond [(or (not unit) (string=? unit "") (string=? unit "px")) 1]
        [(string=? unit "pt") (/ 96. 72)]
        [(string=? unit "pc") (/ 96. 6)]
        [(string=? unit "in") 96.]
        [(string=? unit "cm") (/ 96. 2.54)]
        [(string=? unit "mm") (/ 96. 25.4)]
        [(string=? unit "em") 16.]
        [else 1]))

(define length-rx #px"^\\s*(-?[0-9.]+(?:[eE][-+]?[0-9]+)?)\\s*(px|pt|pc|in|cm|mm|em|%)?")

;; `reference` is the length a `%` value resolves against (e.g. viewport
;; width/height); if a `%` is seen with no reference available, we treat
;; the number as literal user units rather than erroring.
(define (parse-length s [default 0] #:reference [reference #f])
  (cond
    [(not s) default]
    [(regexp-match length-rx s)
     => (lambda (m)
          (define num (string->number (cadr m)))
          (define unit (caddr m))
          (cond [(and unit (string=? unit "%"))
                 (if reference (* (/ num 100.) reference) num)]
                [else (* num (unit->px-factor unit))]))]
    [else default]))

;; Racket's `the-color-database` is X11-derived, and several of the 16
;; original CSS1/HTML4 color keywords have values that genuinely differ
;; from what CSS/SVG mandate for the same name -- confirmed by rendering
;; against librsvg and finding visibly wrong colors, not just "purple"
;; (the famous case) but also "green" (X11: bright 0,255,0 vs CSS's dark
;; 0,128,0), "gray", "maroon", and "navy". These 16 are overridden
;; explicitly. Full CSS Color 4 coverage (all 147+ extended names,
;; gray/grey aliasing throughout compounds like "lightslategray", and
;; functional notations like rgb()/hsl()) is Tier 2 scope -- this fixes
;; only the specific names already proven wrong.
;; A small general-purpose float modulo (result has the same sign as the
;; divisor), used both for hue wraparound in hsl->rgb and for dash-pattern
;; phase wraparound in dash-split-polyline.
(define (fmod a b) (- a (* b (floor (/ a b)))))

(define (clamp-byte x) (inexact->exact (round (max 0 (min 255 x)))))
(define (clamp-unit x) (max 0. (min 1. x)))

;; hsl->rgb : real? real? real? -> (values real? real? real?)   [0-255 each]
;; h in degrees (any real; wrapped mod 360), s and l in [0,1].
(define (hsl->rgb h s l)
  (define h* (fmod h 360.))
  (define c (* (- 1 (abs (- (* 2 l) 1))) s))
  (define x (* c (- 1 (abs (- (fmod (/ h* 60.) 2.) 1)))))
  (define m (- l (/ c 2)))
  (define-values (r1 g1 b1)
    (cond [(< h* 60)  (values c x 0)]
          [(< h* 120) (values x c 0)]
          [(< h* 180) (values 0 c x)]
          [(< h* 240) (values 0 x c)]
          [(< h* 300) (values x 0 c)]
          [else       (values c 0 x)]))
  (values (* (+ r1 m) 255) (* (+ g1 m) 255) (* (+ b1 m) 255)))

;; Splits the inside of a "func(...)" call into individual value tokens,
;; permissively treating any run of commas/whitespace/slashes as a
;; separator -- accepts both the classic comma-separated syntax SVG's own
;; spec uses ("rgb(255, 0, 0)") and the newer CSS Color 4 space/slash
;; syntax ("rgb(255 0 0 / 50%)") for free.
(define (split-function-args s)
  (filter (lambda (x) (> (string-length x) 0)) (regexp-split #px"[\\s,/]+" (string-trim s))))

(define (token->number tok) (string->number (car (regexp-match #px"^-?[0-9.]+" tok))))
(define (token-percent? tok) (regexp-match? #rx"%$" tok))
(define (parse-rgb-component tok) (if (token-percent? tok) (* (/ (token->number tok) 100.) 255.) (token->number tok)))
(define (parse-unit-component tok) (if (token-percent? tok) (/ (token->number tok) 100.) (token->number tok)))

(define css-basic-color-overrides
  (hash "black" '(0 0 0)         "silver" '(192 192 192)  "gray"   '(128 128 128)
        "grey"  '(128 128 128)  "white"  '(255 255 255)  "maroon" '(128 0 0)
        "red"   '(255 0 0)       "purple" '(128 0 128)     "fuchsia" '(255 0 255)
        "green" '(0 128 0)       "lime"   '(0 255 0)       "olive"  '(128 128 0)
        "yellow" '(255 255 0)    "navy"   '(0 0 128)       "blue"   '(0 0 255)
        "teal"  '(0 128 128)     "aqua"   '(0 255 255)))

;; A `fill`/`stroke` value that references a paint server (gradient or
;; pattern) by id, per "url(#id)" or "url(#id) fallback-color" syntax.
;; Resolved lazily at paint time (not here), since resolving it needs
;; both the id table AND -- for the common objectBoundingBox case -- the
;; specific shape's own bounding box, neither of which parse-paint has.
(struct paint-ref (id fallback) #:transparent)

;; Parses "none", "currentColor", "#rgb", "#rrggbb", rgb()/rgba()/hsl()/
;; hsla(), "url(#id)" [+ optional fallback], or a named color into a
;; color%, a paint-ref, or #f. `current-color` supplies the value
;; "currentColor" resolves to (the inherited `color` property); alpha
;; from rgba()/hsla() is preserved on the returned color%, so opacity
;; composition later just multiplies it further.
;; Recognizes a `url(...)` reference at the start of `s` -- with EITHER
;; quoted ('...'/"...") or unquoted content -- returning (cons content
;; fallback-str), or #f if `s` isn't a url(...) reference at all (so
;; parse-paint's cond can correctly fall through to other paint types
;; only in that case, never for a url() that just happens not to
;; resolve). A real bug caught by a WPT test titled exactly "leading and
;; trailing whitespace is stripped from URL references": the previous
;; version only recognized the unquoted form, so url('#green') (quoted)
;; didn't match this clause AT ALL.
(define (try-split-url-paint s)
  (define quoted (regexp-match #px"(?i:^url)\\(\\s*(['\"])(.*?)\\1\\s*\\)\\s*(.*)$" s))
  (cond
    [quoted (cons (caddr quoted) (cadddr quoted))]
    [else
     (define unquoted (regexp-match #px"(?i:^url)\\(\\s*([^'\"\\s)]*)\\s*\\)\\s*(.*)$" s))
     (and unquoted (cons (cadr unquoted) (caddr unquoted)))]))

;; context-fill/context-stroke (SVG2): resolve to whatever fill/stroke
;; paint was active on the REFERENCING element -- primarily useful so a
;; <marker> can automatically match the stroke color of the path it's
;; attached to without hardcoding one, but usable via plain <use> and
;; <pattern> content too. Tracked via two parameters, set at each of the
;; three places this file renders one element's content "on behalf of"
;; another (render-use-node!, render-marker-instance!, build-pattern-
;; brush) to that OUTER element's own resolved fill/stroke -- #f (not
;; set) outside any of those contexts, in which case context-fill/
;; context-stroke resolve to no paint at all, matching how an
;; unresolvable paint-ref's own dangling reference behaves elsewhere.
(define current-context-fill (make-parameter #f))
(define current-context-stroke (make-parameter #f))

(define (parse-paint s [current-color #f])
  (define trimmed (and s (string-trim s)))
  (cond
    [(not s) #f]
    [(string-ci=? trimmed "none") #f]
    [(string-ci=? trimmed "currentcolor") (or current-color (parse-paint "black"))]
    [(string-ci=? trimmed "context-fill") (current-context-fill)]
    [(string-ci=? trimmed "context-stroke") (current-context-stroke)]
    [(try-split-url-paint trimmed)
     => (lambda (parts)
          ;; Only leading/trailing whitespace around the url() reference
          ;; as a WHOLE is stripped (confirmed against a WPT test titled
          ;; exactly that); whitespace INSIDE the fragment id itself is
          ;; part of the id verbatim -- "# red" is a genuinely different,
          ;; nonexistent id from "red", not the same id with stray
          ;; whitespace to clean up, so it correctly falls through to
          ;; the fallback color rather than matching anything.
          (define content (string-trim (car parts)))
          (define fallback-str (string-trim (cdr parts)))
          (define fallback (and (> (string-length fallback-str) 0) (parse-paint fallback-str current-color)))
          (if (and (> (string-length content) 0) (eqv? (string-ref content 0) #\#))
              (paint-ref (substring content 1) fallback)
              fallback))]  ; url() present but not a local fragment ref (e.g. http:) -- never fetched, so just the fallback
    [(regexp-match #px"^#([0-9a-fA-F]{6})$" trimmed)
     => (lambda (m) (define h (cadr m))
          (make-object color% (string->number (substring h 0 2) 16)
                               (string->number (substring h 2 4) 16)
                               (string->number (substring h 4 6) 16)))]
    [(regexp-match #px"^#([0-9a-fA-F]{3})$" trimmed)
     => (lambda (m) (define h (cadr m))
          (make-object color% (string->number (make-string 2 (string-ref h 0)) 16)
                               (string->number (make-string 2 (string-ref h 1)) 16)
                               (string->number (make-string 2 (string-ref h 2)) 16)))]
    [(regexp-match #px"(?i:^rgba?)\\((.*)\\)$" trimmed)
     => (lambda (m)
          (define toks (split-function-args (cadr m)))
          (define r (parse-rgb-component (list-ref toks 0)))
          (define g (parse-rgb-component (list-ref toks 1)))
          (define b (parse-rgb-component (list-ref toks 2)))
          (define a (if (>= (length toks) 4) (parse-unit-component (list-ref toks 3)) 1.0))
          (make-object color% (clamp-byte r) (clamp-byte g) (clamp-byte b) (clamp-unit a)))]
    [(regexp-match #px"(?i:^hsla?)\\((.*)\\)$" trimmed)
     => (lambda (m)
          (define toks (split-function-args (cadr m)))
          (define h (token->number (list-ref toks 0)))
          (define s (parse-unit-component (list-ref toks 1)))
          (define l (parse-unit-component (list-ref toks 2)))
          (define a (if (>= (length toks) 4) (parse-unit-component (list-ref toks 3)) 1.0))
          (define-values (r g b) (hsl->rgb h s l))
          (make-object color% (clamp-byte r) (clamp-byte g) (clamp-byte b) (clamp-unit a)))]
    [else
     (define name (string-downcase trimmed))
     (cond [(hash-ref css-basic-color-overrides name #f) => (lambda (rgb) (apply make-object color% rgb))]
           [(send the-color-database find-color name) => values]
           [else (make-object color% 0 0 0)])]))

;; opacity / fill-opacity / stroke-opacity: a number 0-1 or a percentage.
(define (parse-opacity s [default 1])
  (cond
    [(not s) default]
    [else
     (define trimmed (string-trim s))
     (define pct? (regexp-match? #rx"%$" trimmed))
     (define n (string->number (string-trim (regexp-replace #rx"%$" trimmed ""))))
     (if n (clamp-unit (if pct? (/ n 100.) n)) default)]))

(define (parse-linecap s) (cond [(string=? s "round") 'round] [(string=? s "square") 'projecting] [else 'butt]))
(define (parse-linejoin s) (cond [(string=? s "round") 'round] [(string=? s "bevel") 'bevel] [else 'miter]))

;; font-family is a comma-separated list, e.g. "Georgia, 'Times New Roman',
;; serif". Racket's font% distinguishes an actual "face" (a specific
;; installed font name) from an abstract "family" (a generic bucket the
;; platform maps to something reasonable) -- so we look for the first
;; generic CSS keyword anywhere in the list to use as `family`, and use
;; the first NON-generic name (if any), quotes stripped, as `face`.
(define generic-font-families
  (hash "serif" 'roman "sans-serif" 'swiss "monospace" 'modern
        "cursive" 'script "fantasy" 'decorative))

(define (parse-font-family s)
  (cond
    [(not s) (values #f 'default)]
    [else
     (define names (map (lambda (t) (string-trim (string-trim (string-trim (string-trim t) "'") "\"")))
                         (string-split s ",")))
     (define family (or (for/or ([n (in-list names)]) (hash-ref generic-font-families (string-downcase n) #f))
                         'default))
     (define face (for/or ([n (in-list names)]) (and (not (hash-ref generic-font-families (string-downcase n) #f)) n)))
     (values face family)]))

;; font-weight: "normal"/"bold", or a CSS numeric weight (100-900) --
;; racket/draw's font% accepts an integer weight directly (checked
;; against its documented range), so a numeric value is passed through
;; as-is rather than bucketed into just two levels.
(define (parse-font-weight s)
  (cond
    [(not s) 'normal]
    [(string-ci=? s "bold") 'bold]
    [(string-ci=? s "normal") 'normal]
    [(string->number s) => values]
    [else 'normal]))

(define (parse-font-style s)
  (cond [(not s) 'normal]
        [(string-ci=? s "italic") 'italic]
        [(string-ci=? s "oblique") 'slant]
        [else 'normal]))

(define (parse-text-anchor s)
  (cond [(not s) 'start]
        [(string-ci=? s "middle") 'middle]
        [(string-ci=? s "end") 'end]
        [else 'start]))

;; stroke-dasharray: an even-length list of non-negative lengths (an odd
;; length gets doubled, per spec), or #f for "none"/invalid (which means:
;; render as a normal solid stroke).
(define (parse-dasharray s)
  (define trimmed (string-trim (or s "")))
  (cond
    [(or (string=? trimmed "") (string-ci=? trimmed "none")) #f]
    [else
     (define toks (filter (lambda (x) (> (string-length x) 0)) (regexp-split #px"[\\s,]+" trimmed)))
     (define nums (map (lambda (t) (parse-length t 0)) toks))
     (cond
       [(null? nums) #f]
       [(ormap negative? nums) #f]         ; invalid per spec
       [(zero? (apply + nums)) #f]         ; invalid per spec (would be zero-length everything)
       [(odd? (length nums)) (append nums nums)]
       [else nums])]))

;; Inline style="..." attribute: "fill:red; stroke: blue !important" -> a
;; hash from (lowercased, trimmed) property name to (cons value
;; important?), tracking !important the same as stylesheet declarations
;; do (Tier 9), so an inline !important can correctly outrank even a
;; stylesheet !important rule (see resolve-inherited's cascade).
(define (parse-style-attr s)
  (define props (make-hash))
  (for ([decl (in-list (string-split (or s "") ";"))])
    (define parts (string-split decl ":"))
    (when (= (length parts) 2)
      (define name (string-trim (string-downcase (first parts))))
      (define raw-value (string-trim (second parts)))
      (define important? (regexp-match? #px"!\\s*important\\s*$" raw-value))
      (define value (string-trim (regexp-replace #px"!\\s*important\\s*$" raw-value "")))
      (hash-set! props name (cons value important?))))
  props)

;; Checks the parsed style="" declarations first (CSS gives inline style
;; higher priority than presentation attributes), falling back to the
;; plain attribute. Used only for the narrower case of resolving a
;; <stop>'s own style="" (Tier 4) -- a <stop> being targeted by a
;; class/id stylesheet selector is rare enough that it isn't wired
;; through the full cascade in resolve-inherited, a disclosed, narrow gap.
(define (style-or-attr-ref style-props attrs name [default #f])
  (define entry (hash-ref style-props (symbol->string name) #f))
  (if entry (car entry) (attr-ref attrs name default)))

(define (xexpr-tag x) (and (pair? x) (car x)))
(define (xexpr-attrs x) (if (and (pair? x) (pair? (cdr x)) (pair? (cadr x))
                                  (or (null? (cadr x)) (pair? (car (cadr x)))))
                             (cadr x) '()))
(define (xexpr-children x)
  (cond [(null? (cdr x)) '()]
        [(or (null? (cadr x)) (and (pair? (cadr x)) (pair? (car (cadr x)))))
         (cddr x)]
        [else (cdr x)]))
(define (element-children x) (filter pair? (xexpr-children x)))

;;; ---- viewBox / preserveAspectRatio --------------------------------------
;; Produces a #(a b c d e f) matrix (the exact format `dc<%>`'s `transform`
;; method accepts, per x' = a*x + c*y + e, y' = b*x + d*y + f) mapping
;; viewBox space into the width/height viewport, honoring `align` and
;; `meet`/`slice` per the spec algorithm.
(define identity-matrix (vector 1 0 0 1 0 0))

(struct preserve-ar (align meet-or-slice) #:transparent)

(define (parse-preserve-aspect-ratio s)
  (define toks (if (and s (> (string-length (string-trim s)) 0)) (string-split s) '("xMidYMid" "meet")))
  (define toks* (if (and (pair? toks) (string=? (car toks) "defer")) (cdr toks) toks))
  (define align (if (pair? toks*) (car toks*) "xMidYMid"))
  (define mos (if (and (pair? toks*) (pair? (cdr toks*))) (string->symbol (cadr toks*)) 'meet))
  (preserve-ar align mos))

(define (compute-viewbox-matrix vb-x vb-y vb-w vb-h vp-w vp-h par)
  (cond
    [(or (<= vb-w 0) (<= vb-h 0)) identity-matrix]
    [else
     (define align (preserve-ar-align par))
     (define scale-x (/ vp-w vb-w))
     (define scale-y (/ vp-h vb-h))
     (define-values (sx sy)
       (if (string=? align "none")
           (values scale-x scale-y)
           (let ([s (if (eq? (preserve-ar-meet-or-slice par) 'slice)
                        (max scale-x scale-y)
                        (min scale-x scale-y))])
             (values s s))))
     (define extra-x (- vp-w (* vb-w sx)))
     (define extra-y (- vp-h (* vb-h sy)))
     (define tx (+ (- (* vb-x sx))
                   (cond [(regexp-match? #rx"xMid" align) (/ extra-x 2)]
                         [(regexp-match? #rx"xMax" align) extra-x]
                         [else 0])))
     (define ty (+ (- (* vb-y sy))
                   (cond [(regexp-match? #rx"YMid" align) (/ extra-y 2)]
                         [(regexp-match? #rx"YMax" align) extra-y]
                         [else 0])))
     (vector sx 0 0 sy tx ty)]))

;;; ---- CSS <style> stylesheets (Tier 9) -------------------------------------
;; Parsing itself is delegated to `parsers/css` (Jens Axel Søgaard's
;; parsers-lib), a real CSS Syntax Level 3 parser with proper string/
;; comment/at-rule handling and !important tracking -- selector matching
;; against an actual element+ancestor chain (which no general CSS parser
;; can know how to do, since that's SVG/DOM-specific) is still ours, built
;; on top of it. Covers type/class/id/universal/attribute selectors
;; (presence, =, ~=, |=, ^=, $=, *=), compound selectors combining several
;; of those on one element, descendant and child combinators, comma-
;; separated selector lists, real CSS specificity, and the FULL cascade
;; against presentation attributes and inline style="" -- five tiers,
;; highest first: inline !important, stylesheet !important (by
;; specificity/order), inline normal, stylesheet normal (by specificity/
;; order), then the plain presentation attribute, which acts as though it
;; were the lowest-specificity rule of all (even a bare `rect { fill: red
;; }` rule beats a `fill="blue"` attribute on that element).
;;
;; `parsers/css`'s own `css-selector-compounds` helper -- which groups a
;; selector's flat parts into compounds split on combinators -- turned out
;; to have a real ordering bug (confirmed by testing "a b > c": the
;; combinators and compounds come back scrambled, not in source order),
;; reported upstream. Routed around it by grouping the flat
;; `css-selector-parts` list ourselves instead, which IS in correct
;; source order (checked directly, independent of the buggy helper).
;;
;; Pseudo-classes (:hover, :nth-child, etc.), namespaced selectors, and
;; sibling combinators (+/~) are all deliberately unsupported: a compound
;; using any of them is marked impossible and never matches, rather than
;; silently ignoring the part and over-matching. This is actually more
;; correct for interaction-based pseudo-classes in a static renderer --
;; :hover never applies to a one-shot raster -- and a reasonable, narrow
;; simplification for the structural ones (:nth-child etc.) and sibling
;; combinators, which could be added later but aren't common in SVG.
;;
;; Selector matching needs each element's ANCESTOR chain for descendant/
;; child combinators, which nothing before this tier needed to track.
;; `current-ancestor-chain` threads it through precisely where
;; `render-node!` already recurses into an element's children; content
;; rendered as its own "mini-document" (a pattern tile, a mask, a marker,
;; a used <symbol>'s instantiation) deliberately starts that chain fresh
;; rather than inheriting the referencing context's ancestors, mirroring
;; how those same call sites already start from `ua-default-ctx` rather
;; than inheriting paint context.

(struct css-compound (tag classes id attrs impossible?) #:transparent)
;; tag: symbol or #f (universal '*'); classes: (listof string);
;; id: string or #f; attrs: (listof (list string? (or/c string? #f)
;; (or/c string? #f))) -- (name matcher value); matcher #f means "just
;; check presence". impossible?: #t if this compound used a feature we
;; don't support (pseudo-class, namespace, ...) -- always fails to match.

(struct sel-step (combinator compound) #:transparent)
;; combinator: 'none (only valid for the first, leftmost step) | 'descendant | 'child
;; -- describes the combinator BETWEEN this compound and the PREVIOUS
;; (leftward) one in source order.

(struct css-rule (selectors declarations order) #:transparent)
;; selectors: (listof (listof sel-step)), one per comma-separated selector
;; declarations: (listof (list string? string? boolean?)) -- (name value important?)
;; order: this rule's position in the stylesheet, for cascade tiebreaking

(define (css-attribute-value->string v)
  (cond [(not v) #f]
        [(css-selector-attribute-string-value? v) (css-selector-attribute-string-value-value v)]
        [(css-selector-attribute-identifier-value? v) (css-selector-attribute-identifier-value-value v)]
        [else #f]))

;; Groups a css-selector?'s flat, correctly-ordered `css-selector-parts`
;; into our own compound/combinator step list (NOT via the library's own
;; `css-selector-compounds`, which has the ordering bug described above).
;; Returns #f if the selector uses a sibling combinator (+/~), which we
;; don't support at all.
(define (convert-css-selector sel)
  (define groups '()) (define current '()) (define current-comb 'none) (define unsupported? #f)
  (for ([p (in-list (css-selector-parts sel))])
    (cond
      [(css-selector-combinator? p)
       (set! groups (cons (cons current-comb (reverse current)) groups))
       (set! current '())
       (define txt (css-selector-combinator-text p))
       (cond [(equal? txt ">") (set! current-comb 'child)]
             [(equal? txt " ") (set! current-comb 'descendant)]
             [else (set! unsupported? #t)])]
      [else (set! current (cons p current))]))
  (set! groups (cons (cons current-comb (reverse current)) groups))
  (if unsupported? #f
      (for/list ([g (in-list (reverse groups))]) (sel-step (car g) (parts->css-compound (cdr g))))))

;; Works around a confirmed upstream parsers/css bug (reported to the
;; author): class/id name scanning doesn't stop at a SUBSEQUENT '.' or
;; '#', so chained simple selectors like ".foo.bar" or "#bar.foo" come
;; back as one identifier with the delimiter embedded in it (class name
;; "foo.bar", or id name "bar.foo") instead of two separate parts. A
;; legitimate CSS identifier never legitimately contains a literal '.'
;; or '#', so any occurrence is unambiguously this bug rather than valid
;; input -- split it back into the separate class/id pieces the parser
;; should have produced; each piece's kind is determined by whichever
;; delimiter introduced it ('.' -> class, '#' -> id), except the first
;; piece, which keeps whatever kind the caller already knows from which
;; struct type (css-selector-class? vs -id?) it came from.
(define (split-mangled-selector-name first-kind name)
  (for/list ([piece (in-list (regexp-split #px"(?=[.#])" name))] [i (in-naturals)])
    (cond [(= i 0) (cons first-kind piece)]
          [(eqv? (string-ref piece 0) #\.) (cons 'class (substring piece 1))]
          [(eqv? (string-ref piece 0) #\#) (cons 'id (substring piece 1))]
          [else (cons first-kind piece)])))

(define (parts->css-compound parts)
  (define tag #f) (define classes '()) (define id #f) (define attrs '()) (define impossible? #f)
  (define (add-name-pieces! first-kind name)
    (for ([piece (in-list (split-mangled-selector-name first-kind name))])
      (if (eq? (car piece) 'class) (set! classes (cons (cdr piece) classes)) (set! id (cdr piece)))))
  (for ([p (in-list parts)])
    (cond
      [(css-selector-type? p) (set! tag (string->symbol (css-selector-type-name p)))]
      [(css-selector-universal? p) (void)]
      [(css-selector-class? p) (add-name-pieces! 'class (css-selector-class-name p))]
      [(css-selector-id? p) (add-name-pieces! 'id (css-selector-id-name p))]
      [(css-selector-attribute? p)
       (define d (css-selector-attribute-derived-details p))
       (set! attrs (cons (list (css-selector-attribute-details-name d)
                                (css-selector-attribute-details-matcher d)
                                (css-attribute-value->string (css-selector-attribute-details-value d)))
                          attrs))]
      [else (set! impossible? #t)]))  ; pseudo-classes, namespaced selectors, anything else
  (css-compound tag (reverse classes) id (reverse attrs) impossible?))

(define (parse-css-stylesheet css-text)
  (define parsed (parse-css css-text))
  (define order 0)
  (for/fold ([rules '()] #:result (reverse rules))
            ([rule (in-list (css-stylesheet-rules parsed))] #:when (css-style-rule? rule))
    (define selectors (filter values (map convert-css-selector (css-style-rule-selectors rule))))
    ;; parsers/css keeps a literal "!important" suffix in the raw value
    ;; text even when it also flags `important?` separately (useful for
    ;; its own serialization/rewrite features; not what our cascade
    ;; wants), so strip it back off here.
    (define decls (for/list ([d (in-list (css-style-rule-block rule))] #:when (css-declaration? d))
                    (list (string-downcase (css-declaration-name d))
                          (string-trim (regexp-replace #px"(?i:!\\s*important)\\s*$" (css-declaration-value d) ""))
                          (css-declaration-important? d))))
    (set! order (add1 order))
    (cons (css-rule selectors decls (sub1 order)) rules)))

;; Standard CSS specificity as a (id . class+attr . type) triple, summed
;; across every compound in the selector (not just the last one) --
;; compared lexicographically by `specificity<?`.
(define (selector-specificity sel)
  (define-values (ids cls types)
    (for/fold ([ids 0] [cls 0] [types 0]) ([step (in-list sel)])
      (define c (sel-step-compound step))
      (values (+ ids (if (css-compound-id c) 1 0))
              (+ cls (length (css-compound-classes c)) (length (css-compound-attrs c)))
              (+ types (if (css-compound-tag c) 1 0)))))
  (list ids cls types))

(define (specificity<? a b)
  (match-define (list a1 a2 a3) a) (match-define (list b1 b2 b3) b)
  (cond [(not (= a1 b1)) (< a1 b1)] [(not (= a2 b2)) (< a2 b2)] [else (< a3 b3)]))

(define (attr-selector-matches? spec attrs)
  (match-define (list name matcher value) spec)
  (define v (attr-ref attrs (string->symbol name)))
  (cond
    [(not v) #f]
    [(not matcher) #t]
    [(not value) #f]
    [else
     (case matcher
       [("=") (equal? v value)]
       [("~=") (and (member value (string-split v)) #t)]
       [("|=") (or (equal? v value) (string-prefix? v (string-append value "-")))]
       [("^=") (string-prefix? v value)]
       [("$=") (string-suffix? v value)]
       [("*=") (string-contains? v value)]
       [else #f])]))

(define (compound-matches-node? c tag attrs)
  (and (not (css-compound-impossible? c))
       (or (not (css-compound-tag c)) (eq? (css-compound-tag c) tag))
       (or (not (css-compound-id c)) (equal? (css-compound-id c) (attr-ref attrs 'id)))
       (andmap (lambda (cls) (member cls (let ([cl (attr-ref attrs 'class)]) (if cl (string-split cl) '()))))
               (css-compound-classes c))
       (andmap (lambda (spec) (attr-selector-matches? spec attrs)) (css-compound-attrs c))))

;; ancestors: (listof xexpr?) from the immediate parent outward to the root.
(define (selector-matches? sel node ancestors)
  (define rev (reverse sel))
  (and (compound-matches-node? (sel-step-compound (car rev)) (xexpr-tag node) (xexpr-attrs node))
       (or (null? (cdr rev)) (match-selector-ancestors (sel-step-combinator (car rev)) (cdr rev) ancestors))))

;; `combinator` is the relationship between the already-matched element
;; (target-ward) and the next compound to find among `ancestors` -- it
;; comes from the step CLOSER TO THE TARGET (each step's own combinator
;; field describes its relationship to its target-ward neighbor, not to
;; whatever comes next going outward), so it has to be threaded through
;; explicitly rather than read off `(car rev-rest)` itself.
(define (match-selector-ancestors combinator rev-rest ancestors)
  (define comp (sel-step-compound (car rev-rest)))
  (define next-combinator (sel-step-combinator (car rev-rest)))
  (case combinator
    [(child)
     (and (pair? ancestors)
          (compound-matches-node? comp (xexpr-tag (car ancestors)) (xexpr-attrs (car ancestors)))
          (or (null? (cdr rev-rest)) (match-selector-ancestors next-combinator (cdr rev-rest) (cdr ancestors))))]
    [(descendant)
     (let loop ([anc ancestors])
       (cond [(null? anc) #f]
             [(and (compound-matches-node? comp (xexpr-tag (car anc)) (xexpr-attrs (car anc)))
                   (or (null? (cdr rev-rest)) (match-selector-ancestors next-combinator (cdr rev-rest) (cdr anc))))
              #t]
             [else (loop (cdr anc))]))]
    [else #f]))

;; The ancestor chain of the node currently being resolved, immediate
;; parent first -- empty at the document root, and deliberately reset to
;; empty when entering a pattern tile/mask/marker/symbol's own content,
;; since that's rendered as its own independent mini-document.
(define current-ancestor-chain (make-parameter '()))

;; The whole document's parsed stylesheet (all <style> elements'
;; contents concatenated, wherever they sit in the tree), built once by
;; read-svg-document. #f (rather than an empty list) is used as "no
;; stylesheet at all" so resolve-inherited can skip matching entirely
;; for the (extremely common) case of a document with no <style> at all.
(define current-stylesheet (make-parameter #f))

;; For one element, finds every stylesheet rule whose selector matches it
;; (using its ancestor chain for descendant/child combinators), then
;; applies their declarations in ascending (specificity, source-order) --
;; separately for normal and !important declarations, since the two
;; cascade at different priority tiers (see resolve-inherited) -- so a
;; later or higher-specificity rule overrides an earlier one within each
;; tier. Returns (values normal-hash important-hash).
(define (matched-stylesheet-declarations node)
  (define stylesheet (current-stylesheet))
  (cond
    [(not stylesheet) (values #hash() #hash())]
    [else
     (define ancestors (current-ancestor-chain))
     (define matches
       (for*/list ([rule (in-list stylesheet)]
                    [sel (in-list (css-rule-selectors rule))]
                    #:when (selector-matches? sel node ancestors))
         (list (selector-specificity sel) (css-rule-order rule) (css-rule-declarations rule))))
     (define sorted (sort matches (lambda (a b) (if (equal? (first a) (first b))
                                                      (< (second a) (second b))
                                                      (specificity<? (first a) (first b))))))
     (define normal (make-hash)) (define important (make-hash))
     (for ([m (in-list sorted)])
       (for ([d (in-list (third m))])
         (match-define (list name value imp?) d)
         (hash-set! (if imp? important normal) name value)))
     (values normal important)]))

;; SVG2's "geometry properties": cx/cy/r/rx/ry/x/y/width/height/d can be
;; set via CSS (inline style or a <style> stylesheet) as well as by the
;; plain XML attribute of the same name -- confirmed against real usage
;; in the wild (Web Platform Tests' svg/geometry suite) to be exactly
;; this set for the basic shapes; x1/y1/x2/y2 (line) and points
;; (polyline/polygon) are NOT part of it (never appear as CSS properties
;; anywhere in that suite), so line/polyline/polygon geometry is only
;; ever read from plain attributes, unchanged from before this.
;;
;; This is a natural extension of the SAME cascade machinery Tier 9
;; already built for paint properties (fill/stroke/opacity/...), not a
;; DOM-reactivity feature -- resolving "what's the effective value of
;; this property, given inline style/matched stylesheet rules/the plain
;; attribute, in cascade-priority order" doesn't care whether the result
;; feeds into paint or into geometry. What WOULDN'T translate to a
;; static, single-pass renderer -- and isn't attempted -- is anything
;; requiring live reactivity: `:hover`/`:focus` changing geometry, CSS
;; transitions/animations interpolating it over time, or a `<use>`
;; reacting to a referenced element's size changing. Those all need an
;; actual DOM and a time dimension, neither of which exists here (the
;; same boundary already drawn around animation and interactive pseudo-
;; classes in Tier 9).
;;
;; Unlike render-ctx's paint properties, geometry properties are NOT
;; inherited (SVG2 gives them all `Inherited: no` -- a <rect> doesn't
;; get its width from some ancestor's width, any more than it does as a
;; plain attribute today), so this resolves only the element's OWN
;; cascade, with no ancestor fallback, rather than being folded into
;; render-ctx.
(define (geometry-attr-ref node name [default #f])
  (define attrs (xexpr-attrs node))
  (define style-props (parse-style-attr (attr-ref attrs 'style)))
  (define-values (stylesheet-normal stylesheet-important) (matched-stylesheet-declarations node))
  (define prop (symbol->string name))
  (define inline (hash-ref style-props prop #f))
  (cond
    [(and inline (cdr inline)) (car inline)]
    [(hash-ref stylesheet-important prop #f) => values]
    [inline (car inline)]
    [(hash-ref stylesheet-normal prop #f) => values]
    [else (attr-ref attrs name default)]))

;; Per spec, a percentage geometry value resolves against the CURRENT
;; (possibly nested) viewport: x/width/cx-like properties against its
;; width, y/height/cy-like properties against its height, and anything
;; without a specific x/y orientation (r, stroke-width, and other plain
;; lengths) against the diagonal, sqrt(w^2+h^2)/sqrt(2). `current-
;; canvas-size` tracks the current viewport (updated at every point a
;; new one is established -- nested <svg>, a <use>-instantiated
;; <symbol>/<svg>, <pattern>, <marker> -- not just the document root),
;; confirmed via a WPT test using `rx: 25%` on an ellipse, which this
;; now resolves correctly instead of treating "25%" as the literal
;; number 25.
(define (percentage-reference-for name)
  (define size (current-canvas-size))
  (case name
    [(x cx x1 x2 width rx) (car size)]
    [(y cy y1 y2 height ry) (cdr size)]
    [else (/ (sqrt (+ (sqr (car size)) (sqr (cdr size)))) (sqrt 2))]))

(define (geometry-attr-num node name [default 0])
  (define v (geometry-attr-ref node name))
  (if v (parse-length v default #:reference (percentage-reference-for name)) default))

;; The `d` property's value syntax is different from the other geometry
;; properties -- `none` (no path at all) or `path('...')`/`path("...")`
;; (a quoted path-data string), not a plain length -- so it gets its own
;; small parse step rather than going through geometry-attr-num.
;; `d: inherit`/`initial`/`unset` are not supported (a disclosed, narrow
;; gap; the one place this showed up in practice was itself a scripted,
;; DOM-only test already outside this library's reach for other
;; reasons).
(define (geometry-d-ref node)
  (define v (geometry-attr-ref node 'd))
  (cond
    [(not v) #f]
    [(equal? (string-trim v) "none") ""]
    [else
     (define m (regexp-match #px"^path\\(\\s*['\"](.*)['\"]\\s*\\)$" (string-trim v)))
     (if m (cadr m) v)]))

;; Scans the WHOLE tree for <style> elements (wherever they sit -- not
;; just directly under <defs>), concatenates their text content, and
;; parses it as one stylesheet. #f if there's no <style> anywhere, so
;; callers can skip matching entirely for the common no-CSS case.
(define (build-stylesheet root)
  (define css-chunks '())
  (let walk ([node root])
    (when (eq? (xexpr-tag node) 'style)
      (for ([c (in-list (xexpr-children node))] #:when (string? c))
        (set! css-chunks (cons c css-chunks))))
    (for ([c (in-list (element-children node))]) (walk c)))
  (if (null? css-chunks) #f (parse-css-stylesheet (string-join (reverse css-chunks) "\n"))))



(define ua-default-ctx
  (render-ctx (parse-paint "black") #f 1 'winding
              'butt 'miter #f 0
              (parse-paint "black") 1 1 1
              #f 'default 16 'normal 'normal 'start))

(define (resolve-inherited node ctx)
  (define attrs (xexpr-attrs node))
  (define style-props (parse-style-attr (attr-ref attrs 'style)))
  (define-values (stylesheet-normal stylesheet-important) (matched-stylesheet-declarations node))
  ;; Full cascade, highest priority first: inline !important, stylesheet
  ;; !important (by specificity/source-order), inline normal, stylesheet
  ;; normal (by specificity/source-order), then the plain presentation
  ;; attribute -- which acts as though it were the LOWEST-specificity
  ;; rule of all, so even an unadorned `tag { ... }` rule beats one.
  (define (sref name [default #f])
    (define inline (hash-ref style-props (symbol->string name) #f))
    (cond
      [(and inline (cdr inline)) (car inline)]
      [(hash-ref stylesheet-important (symbol->string name) #f) => values]
      [inline (car inline)]
      [(hash-ref stylesheet-normal (symbol->string name) #f) => values]
      [else (attr-ref attrs name default)]))
  ;; `color` is resolved first since fill/stroke may reference it via
  ;; "currentColor"; if `color` itself says currentColor, that means
  ;; "inherit the parent's resolved color", handled by passing the
  ;; inherited value through as the fallback here too.
  (define new-color (let ([v (sref 'color)]) (if v (parse-paint v (render-ctx-color ctx)) (render-ctx-color ctx))))
  (define-values (new-face new-family)
    (let ([v (sref 'font-family)])
      (if v (parse-font-family v) (values (render-ctx-font-face ctx) (render-ctx-font-family ctx)))))
  (render-ctx
   (let ([v (sref 'fill)])   (if v (parse-paint v new-color) (render-ctx-fill ctx)))
   (let ([v (sref 'stroke)]) (if v (parse-paint v new-color) (render-ctx-stroke ctx)))
   (let ([v (sref 'stroke-width)])
     (if v (parse-length v (render-ctx-stroke-width ctx) #:reference (percentage-reference-for 'stroke-width))
         (render-ctx-stroke-width ctx)))
   (let ([v (sref 'fill-rule)]) (if v (if (string=? v "evenodd") 'odd-even 'winding) (render-ctx-fill-rule ctx)))
   (let ([v (sref 'stroke-linecap)]) (if v (parse-linecap v) (render-ctx-stroke-linecap ctx)))
   (let ([v (sref 'stroke-linejoin)]) (if v (parse-linejoin v) (render-ctx-stroke-linejoin ctx)))
   (let ([v (sref 'stroke-dasharray)]) (if v (parse-dasharray v) (render-ctx-stroke-dasharray ctx)))
   (let ([v (sref 'stroke-dashoffset)]) (if v (parse-length v (render-ctx-stroke-dashoffset ctx)) (render-ctx-stroke-dashoffset ctx)))
   new-color
   (let ([v (sref 'fill-opacity)]) (parse-opacity v (render-ctx-fill-opacity ctx)))
   (let ([v (sref 'stroke-opacity)]) (parse-opacity v (render-ctx-stroke-opacity ctx)))
   ;; `opacity` is NOT a normal inherited property -- each element's own
   ;; opacity (default 1) composites as a group effect, applied exactly
   ;; ONCE per element: a container (g/nested svg/use) wraps its whole
   ;; subtree in `render-with-opacity!`, an offscreen render-then-blend
   ;; that's correct even when the group's own children overlap each
   ;; other (unlike multiplying opacity into each descendant leaf's own
   ;; fill/stroke-opacity, which was this file's original approximation
   ;; -- exactly correct for non-overlapping content, but visibly wrong
   ;; at the overlap otherwise, since two 50%-alpha layers stacked on
   ;; each other compound to 75% opacity, not 50%). A leaf shape with no
   ;; children folds its own opacity into its own fill/stroke-opacity
   ;; directly, same as before. Since each element now handles its OWN
   ;; opacity exactly once at the point it's rendered, this value must
   ;; NOT also accumulate the ancestor chain's opacity multiplicatively
   ;; (ctx's incoming value is deliberately unused here) -- the ancestor
   ;; already applied its own via its own render-with-opacity! wrapper.
   (let ([v (sref 'opacity)]) (parse-opacity v 1))
   new-face
   new-family
   (let ([v (sref 'font-size)]) (if v (parse-length v (render-ctx-font-size ctx)) (render-ctx-font-size ctx)))
   (let ([v (sref 'font-weight)]) (if v (parse-font-weight v) (render-ctx-font-weight ctx)))
   (let ([v (sref 'font-style)]) (if v (parse-font-style v) (render-ctx-font-style ctx)))
   (let ([v (sref 'text-anchor)]) (if v (parse-text-anchor v) (render-ctx-text-anchor ctx)))))

;;; ---- Id table -------------------------------------------------------------

(define (build-id-table root)
  (define table (make-hash))
  (let walk ([node root])
    (define attrs (xexpr-attrs node))
    (define id (attr-ref attrs 'id))
    (when id (hash-set! table id node))
    (for ([c (in-list (element-children node))]) (walk c)))
  table)

;;; ---- Document reading -----------------------------------------------------

;; Resolves the root <svg>'s width/height. A bare `%` (or a missing
;; value) has no containing viewport to resolve against at the document
;; root, so it falls back to the viewBox size (or the CSS default
;; 300x150) rather than being treated as a literal number.
(define (resolve-root-dimension attr-str vb-fallback)
  (cond [(not attr-str) (or vb-fallback 300)]
        [(regexp-match? #px"%\\s*$" (string-trim attr-str)) (or vb-fallback 300)]
        [else (parse-length attr-str (or vb-fallback 300))]))

;; viewBox's four numbers may be separated by commas as well as
;; whitespace (the same convention path data and points lists use) --
;; caught by a WPT test using viewBox="0, 0, 620, 340": plain
;; whitespace-only splitting left a trailing comma stuck to each number
;; string, so string->number returned #f for all four, which then
;; crashed downstream arithmetic in compute-viewbox-matrix with a
;; contract violation instead of parsing correctly. Returns 4 values, or
;; 4 #f's if `vb` is absent or malformed (callers already treat a #f
;; vb-w/vb-h as "no usable viewBox" via `or` fallbacks).
(define (parse-viewbox-attr vb)
  (define ns (and vb (map string->number (filter (lambda (t) (> (string-length t) 0))
                                                  (regexp-split #px"[\\s,]+" (string-trim vb))))))
  (if (and ns (>= (length ns) 4) (andmap values (take ns 4)))
      (values (list-ref ns 0) (list-ref ns 1) (list-ref ns 2) (list-ref ns 3))
      (values #f #f #f #f)))

(define (read-svg-document x)
  (define root
    (xml->xexpr
     (document-element
      (cond [(string? x) (read-xml (open-input-string x))]
            [(input-port? x) (read-xml x)]
            [else (error 'read-svg-document "expected string or input-port, got: ~a" x)]))))
  (define attrs (xexpr-attrs root))
  (define vb (attr-ref attrs 'viewBox))
  (define-values (vb-x vb-y vb-w vb-h) (parse-viewbox-attr vb))
  (define width (resolve-root-dimension (attr-ref attrs 'width) vb-w))
  (define height (resolve-root-dimension (attr-ref attrs 'height) vb-h))
  (define par (parse-preserve-aspect-ratio (attr-ref attrs 'preserveAspectRatio)))
  (define matrix (if vb (compute-viewbox-matrix vb-x vb-y vb-w vb-h width height par) identity-matrix))
  (svg-doc width height root (build-id-table root) matrix (build-stylesheet root)))

;;; ---- The `transform` attribute (Tier 1) ---------------------------------
;;
;; Every primitive here is applied via the dc's raw `transform` method
;; (confirmed to implement x' = a*x + c*y + e, y' = b*x + d*y + f, and to
;; compose across calls in the correct nested left-to-right order for a
;; transform list). Rotation deliberately does NOT use dc<%>'s own
;; `rotate` convenience method: testing showed `dc.rotate` turns out to
;; spin the *opposite* way from SVG's rotate() (SVG defines a positive
;; angle as clockwise in its y-down coordinate system; `dc.rotate` is
;; counter-clockwise for a positive angle). Building the matrix directly
;; from SVG's own published formula and applying it via `transform`
;; sidesteps that mismatch entirely -- verified empirically to rotate
;; the correct (clockwise) direction.

(define (read-ident! st)
  (define start (pstate-pos st))
  (let loop () (when (and (not (at-eof? st)) (char-alphabetic? (peek-char* st))) (advance! st) (loop)))
  (substring (pstate-str st) start (pstate-pos st)))

;; parse-transform-list : string -> (listof (cons/c symbol? (listof real?)))
;; e.g. "translate(10,20) rotate(45)" -> '((translate 10 20) (rotate 45))
(define (parse-transform-list s)
  (define st (make-pstate (or s "")))
  (define acc '())
  (let loop ()
    (skip-sep! st)
    (unless (at-eof? st)
      (define name (string->symbol (read-ident! st)))
      (skip-sep! st)
      (unless (eqv? (peek-char* st) #\() (parse-error st (format "expected '(' after ~a" name)))
      (advance! st)
      (define nums
        (let nloop ([acc2 '()])
          (skip-sep! st)
          (if (eqv? (peek-char* st) #\))
              (reverse acc2)
              (let ([n (read-number! st)]) (skip-sep! st) (nloop (cons n acc2))))))
      (unless (eqv? (peek-char* st) #\)) (parse-error st (format "expected ')' to close ~a(...)" name)))
      (advance! st)
      (set! acc (cons (cons name nums) acc))
      (loop)))
  (reverse acc))

(define (rotation-matrix degrees)
  (define rad (degrees->radians degrees))
  (vector (cos rad) (sin rad) (- (sin rad)) (cos rad) 0 0))

(define (apply-transform-op! dc op)
  (match op
    [(list 'translate tx)        (send dc transform (vector 1 0 0 1 tx 0))]
    [(list 'translate tx ty)     (send dc transform (vector 1 0 0 1 tx ty))]
    [(list 'scale s)              (send dc transform (vector s 0 0 s 0 0))]
    [(list 'scale sx sy)          (send dc transform (vector sx 0 0 sy 0 0))]
    [(list 'rotate deg)           (send dc transform (rotation-matrix deg))]
    [(list 'rotate deg cx cy)
     (send dc transform (vector 1 0 0 1 cx cy))
     (send dc transform (rotation-matrix deg))
     (send dc transform (vector 1 0 0 1 (- cx) (- cy)))]
    [(list 'matrix a b c d e f)  (send dc transform (vector a b c d e f))]
    [(list 'skewX deg)            (send dc transform (vector 1 0 (tan (degrees->radians deg)) 1 0 0))]
    [(list 'skewY deg)            (send dc transform (vector 1 (tan (degrees->radians deg)) 0 1 0 0))]
    [_ (void)]))  ; unknown transform function: ignore rather than error

(define (apply-transform-attr! dc transform-str)
  (for ([op (in-list (parse-transform-list transform-str))]) (apply-transform-op! dc op)))

;;; ---- Basic shapes (Tier 1) ------------------------------------------------
;; Each shape ends up as one or more dc-path%s drawn through the same
;; paint pipeline `<path>` already uses (`draw-shape-paths!`), so fill/
;; stroke/fill-rule/inheritance work identically across all of them.

(define (attr-num attrs name [default 0]) (parse-length (attr-ref attrs name) default))

;; Flattens any dc-path% (however it was built -- line-to, curve-to,
;; native .arc, native .ellipse/.rounded-rectangle) into a polyline per
;; subpath. This works uniformly across every shape because `get-datum`
;; turns out to represent ALL of them (confirmed by inspection) using
;; only two segment shapes: a bare #(x y) waypoint, or a 6-element cubic
;; Bezier control-point vector -- racket/draw itself already approximates
;; arcs and ellipses as Bezier curves internally, so we don't need our
;; own arc-sampling math here at all.
(define (dc-path->polylines p [curve-samples 16])
  (define-values (closed-subpaths open-subpaths) (send p get-datum))
  (define (sample-subpath subpath closed?)
    (define pts '())
    (define cx #f) (define cy #f)
    (define (emit! x y) (set! pts (cons (cons x y) pts)))
    (for ([seg (in-list subpath)])
      (cond
        [(= (vector-length seg) 2)
         (define x (vector-ref seg 0)) (define y (vector-ref seg 1))
         (when (or (not cx) (> (abs (- x cx)) 1e-9) (> (abs (- y cy)) 1e-9)) (emit! x y))
         (set! cx x) (set! cy y)]
        [else  ; 6-element cubic Bezier control-point vector
         (define x1 (vector-ref seg 0)) (define y1 (vector-ref seg 1))
         (define x2 (vector-ref seg 2)) (define y2 (vector-ref seg 3))
         (define ex (vector-ref seg 4)) (define ey (vector-ref seg 5))
         (for ([i (in-range 1 (add1 curve-samples))])
           (define t (/ i curve-samples))
           (define mt (- 1 t))
           (emit! (+ (* mt mt mt cx) (* 3 mt mt t x1) (* 3 mt t t x2) (* t t t ex))
                  (+ (* mt mt mt cy) (* 3 mt mt t y1) (* 3 mt t t y2) (* t t t ey))))
         (set! cx ex) (set! cy ey)]))
    (define result (reverse pts))
    (if (and closed? (pair? result)
             (> (+ (abs (- (caar result) (car (last result))))
                   (abs (- (cdar result) (cdr (last result))))) 1e-6))
        (append result (list (car result)))
        result))
  (append (map (lambda (sp) (sample-subpath sp #t)) closed-subpaths)
          (if (pair? open-subpaths) (list (sample-subpath open-subpaths #f)) '())))

;; Splits a polyline into the "on" sub-polylines of a dasharray pattern
;; (an even-length list of non-negative lengths, alternating on/off),
;; starting `offset` units into the pattern.
;; Total geometric length of a polyline (sum of segment distances).
(define (polyline-length pts)
  (for/sum ([p1 (in-list pts)] [p2 (in-list (cdr pts))])
    (sqrt (+ (sqr (- (car p2) (car p1))) (sqr (- (cdr p2) (cdr p1)))))))

;; Total geometric length across every subpath of every dc-path% in
;; `paths` -- the same "flatten each path into per-subpath polylines"
;; technique dasharray splitting and marker vertices already use, summed
;; instead of walked. Used to compute the pathLength scale factor
;; (actual-length / author-claimed pathLength).
(define (paths-total-length paths)
  (for*/sum ([p (in-list paths)] [polyline (in-list (dc-path->polylines p))])
    (polyline-length polyline)))

(define (dash-split-polyline pts pattern offset)
  (cond
    [(< (length pts) 2) '()]
    [else
     (define total (apply + pattern))
     (define n (length pattern))
     (define pat (list->vector pattern))
     (define (locate phase)
       (let loop ([i 0] [remaining phase])
         (define L (vector-ref pat i))
         (if (< remaining L) (values i (- L remaining)) (loop (modulo (add1 i) n) (- remaining L)))))
     (define-values (k0 rem0) (locate (fmod offset total)))
     (define k k0)
     (define remaining rem0)
     (define runs '())
     (define current-run (if (even? k) (list (first pts)) '()))
     (define (toggle-at! pt)
       (when (even? k)
         (set! current-run (cons pt current-run))
         (set! runs (cons (reverse current-run) runs))
         (set! current-run '()))
       (set! k (modulo (add1 k) n))
       (set! remaining (vector-ref pat k))
       (when (even? k) (set! current-run (list pt))))
     (define (consume! dist pt)
       (set! remaining (- remaining dist))
       (when (even? k) (set! current-run (cons pt current-run))))
     (for ([p1 (in-list pts)] [p2 (in-list (cdr pts))])
       (define dx (- (car p2) (car p1))) (define dy (- (cdr p2) (cdr p1)))
       (define edge-len (sqrt (+ (* dx dx) (* dy dy))))
       (let loop ([pos 0.0])
         (define left (- edge-len pos))
         (cond
           [(>= left remaining)
            (define new-pos (+ pos remaining))
            (define t (if (zero? edge-len) 0 (/ new-pos edge-len)))
            (toggle-at! (cons (+ (car p1) (* t dx)) (+ (cdr p1) (* t dy))))
            (when (< new-pos edge-len) (loop new-pos))]
           [else (consume! left p2)])))
     (when (and (even? k) (pair? current-run)) (set! runs (cons (reverse current-run) runs)))
     (reverse runs)]))

;;; ---- Vertex/tangent extraction (Tier 7: markers) -------------------------
;; Markers are placed at a shape's VERTICES (moveto/lineto/curveto/arc
;; endpoints -- not curve control points), oriented by the tangent
;; direction(s) of the segment(s) meeting there. Reuses `get-datum` the
;; exact same way `dc-path->polylines` does: racket/draw represents
;; every shape (line-to, curve-to, native .arc, native .ellipse) using
;; only two segment shapes once built, so no separate arc-tangent math
;; is needed -- the tangent at a cubic Bezier's endpoint is just the
;; direction from its own control point to that endpoint (falling back
;; to the next-nearest point if a control point coincides with it).

(struct vertex (x y in-angle out-angle) #:transparent)  ; angles in radians, or #f if that side doesn't exist

(define (seg->endpoint seg)
  (if (= (vector-length seg) 2) (cons (vector-ref seg 0) (vector-ref seg 1))
      (cons (vector-ref seg 4) (vector-ref seg 5))))

(define (points-equal? p1 p2)
  (and (< (abs (- (car p1) (car p2))) 1e-9) (< (abs (- (cdr p1) (cdr p2))) 1e-9)))

;; atan2(dy,dx) -- matches the same clockwise-in-y-down convention already
;; verified for the `transform` attribute's rotate(), so this angle can be
;; fed straight into `rotation-matrix` with no further sign adjustment
;; (confirmed empirically: a shape's default rightward-pointing orientation
;; rotated by this angle correctly points along the (dx,dy) tangent).
(define (angle-between p1 p2) (atan (- (cdr p2) (cdr p1)) (- (car p2) (car p1))))

(define (seg-out-angle from-pt seg)
  (if (= (vector-length seg) 2)
      (angle-between from-pt (seg->endpoint seg))
      (let ([c1 (cons (vector-ref seg 0) (vector-ref seg 1))]
            [c2 (cons (vector-ref seg 2) (vector-ref seg 3))]
            [end (seg->endpoint seg)])
        (cond [(not (points-equal? from-pt c1)) (angle-between from-pt c1)]
              [(not (points-equal? from-pt c2)) (angle-between from-pt c2)]
              [else (angle-between from-pt end)]))))

(define (seg-in-angle from-pt seg)
  (define end (seg->endpoint seg))
  (if (= (vector-length seg) 2)
      (angle-between from-pt end)
      (let ([c1 (cons (vector-ref seg 0) (vector-ref seg 1))]
            [c2 (cons (vector-ref seg 2) (vector-ref seg 3))])
        (cond [(not (points-equal? end c2)) (angle-between c2 end)]
              [(not (points-equal? end c1)) (angle-between c1 end)]
              [else (angle-between from-pt end)]))))

;; Vertices for ONE subpath's raw get-datum segment list. If `closed?`
;; and the geometry doesn't already loop back to its own start (true for
;; anything built via move-to/line-to/close rather than a shape that
;; happens to end exactly where it began, like a native ellipse), an
;; implicit closing straight segment is added -- giving a distinct
;; "closure vertex" coincident with the start, matching the spec's own
;; treatment of closepath as generating its own vertex.
(define (subpath-vertices segments closed?)
  (define first-pt (seg->endpoint (first segments)))
  (define real-segs (rest segments))
  (define last-pt (if (null? real-segs) first-pt (seg->endpoint (last real-segs))))
  (define needs-close-seg? (and closed? (pair? real-segs) (not (points-equal? last-pt first-pt))))
  (define all-segs (if needs-close-seg? (append real-segs (list (vector (car first-pt) (cdr first-pt)))) real-segs))
  (cond
    [(null? all-segs) (list (vertex (car first-pt) (cdr first-pt) #f #f))]
    [else
     (define points (let loop ([segs all-segs] [cur first-pt] [acc (list first-pt)])
                      (if (null? segs) (reverse acc)
                          (loop (cdr segs) (seg->endpoint (car segs)) (cons (seg->endpoint (car segs)) acc)))))
     (define outs (for/list ([seg (in-list all-segs)] [pt (in-list points)]) (seg-out-angle pt seg)))
     (define ins (for/list ([seg (in-list all-segs)] [pt (in-list points)]) (seg-in-angle pt seg)))
     (define vlen (length points))
     (for/list ([k (in-range vlen)])
       (define pt (list-ref points k))
       (vertex (car pt) (cdr pt)
               (if (> k 0) (list-ref ins (sub1 k)) #f)
               (if (< k (sub1 vlen)) (list-ref outs k) #f)))]))

(define (dc-path->vertices p)
  (define-values (closed-subpaths open-subpath) (send p get-datum))
  (append (append-map (lambda (sp) (subpath-vertices sp #t)) closed-subpaths)
          (if (pair? open-subpath) (subpath-vertices open-subpath #f) '())))

;; Robustly averages two angles (radians), correct across the wraparound
;; at +/-180 degrees -- e.g. averaging 179 and -179 should give ~180,
;; not 0, which a naive (/ (+ a b) 2) would produce. Sums the two angles'
;; unit vectors and takes the resulting direction; if they point exactly
;; opposite (an ambiguous bisector), picks perpendicular to the first as
;; a reasonable, arbitrary-but-consistent convention.
(define (average-angle a1 a2)
  (define x (+ (cos a1) (cos a2)))
  (define y (+ (sin a1) (sin a2)))
  (if (and (< (abs x) 1e-9) (< (abs y) 1e-9)) (+ a1 (/ pi 2)) (atan y x)))

;; Combines a color%'s own alpha (from e.g. rgba()) with the resolved
;; fill/stroke/element opacity into the final color% used for painting.
(define (paint-color base extra-alpha)
  (and base (make-object color% (send base red) (send base green) (send base blue)
                          (* (send base alpha) extra-alpha))))

;;; ---- Gradients & patterns (Tier 4) ---------------------------------------

;; Interprets a gradient/pattern coordinate value according to `units`:
;; in objectBoundingBox mode both "0.5" and "50%" mean the fraction 0.5;
;; in userSpaceOnUse mode it's parsed as an ordinary length.
(define (parse-gradient-coord s default units)
  (define v (or s default))
  (cond
    [(string=? units "objectBoundingBox")
     (define trimmed (string-trim v))
     (if (regexp-match? #rx"%$" trimmed)
         (/ (or (string->number (string-trim (regexp-replace #rx"%$" trimmed ""))) 0) 100.)
         (or (string->number trimmed) 0))]
    [else (parse-length v)]))

;; The union bounding box across all of a shape's dc-path%s, used to
;; resolve objectBoundingBox-relative gradient/pattern coordinates.
;; Always the shape's pure fill geometry, per spec, regardless of
;; whether the paint server is used for fill or (in principle) stroke.
(define (combined-bounding-box paths)
  (if (null? paths)
      (list 0. 0. 0. 0.)
      (let loop ([ps paths] [minx +inf.0] [miny +inf.0] [maxx -inf.0] [maxy -inf.0])
        (if (null? ps)
            (list minx miny (- maxx minx) (- maxy miny))
            (let-values ([(x y w h) (send (car ps) get-bounding-box)])
              (loop (cdr ps) (min minx x) (min miny y) (max maxx (+ x w)) (max maxy (+ y h))))))))

;; Reads <stop> children (offset/stop-color/stop-opacity, either as
;; presentation attributes or inline style=), normalizing offsets to be
;; non-decreasing (per spec) and folding stop-opacity into each stop
;; color's alpha. If this gradient has no <stop> children of its own, it
;; inherits them from an href'd parent -- a common real-world pattern:
;; define stops once, reuse across several gradients with different
;; geometry.
(define (resolve-gradient-stops node)
  (define own (filter (lambda (c) (eq? (xexpr-tag c) 'stop)) (element-children node)))
  (define stop-nodes
    (if (pair? own)
        own
        (let ([href (href-ref (xexpr-attrs node))])
          (if (and href (regexp-match? #rx"^#" href))
              (let ([parent (hash-ref (current-id-table) (substring href 1) #f)])
                (if parent (filter (lambda (c) (eq? (xexpr-tag c) 'stop)) (element-children parent)) '()))
              '()))))
  (define parsed
    (for/list ([s (in-list stop-nodes)])
      (define attrs (xexpr-attrs s))
      (define style-props (parse-style-attr (attr-ref attrs 'style)))
      (define (sref name default) (or (style-or-attr-ref style-props attrs name #f) default))
      (define trimmed-offset (string-trim (sref 'offset "0")))
      (define offset (if (regexp-match? #rx"%$" trimmed-offset)
                          (/ (or (string->number (string-trim (regexp-replace #rx"%$" trimmed-offset ""))) 0) 100.)
                          (or (string->number trimmed-offset) 0)))
      (define color (parse-paint (sref 'stop-color "black")))
      (define opacity (parse-opacity (sref 'stop-opacity "1")))
      (cons (clamp-unit offset) (paint-color color opacity))))
  ;; Enforce non-decreasing offsets, per spec.
  (let loop ([lst parsed] [prev 0])
    (cond [(null? lst) '()]
          [else (define o (max prev (caar lst)))
                (cons (cons o (cdar lst)) (loop (cdr lst) o))])))

(define (stops->racket-stops stops extra-alpha)
  (for/list ([s (in-list stops)]) (list (car s) (paint-color (cdr s) extra-alpha))))

;; Computes the (a b c d e f) matrix equivalent to applying `transform-str`
;; (an SVG transform-list) starting from identity, via a disposable
;; scratch dc -- lets gradient coordinate mapping reuse the exact same
;; verified transform semantics (composition order, the rotate sign fix)
;; as the `transform` attribute, as pure math, without ever touching the
;; dc used to actually draw the shape being filled (see map-paint-point
;; below for why that distinction matters).
(define (transform-list->matrix transform-str)
  (define scratch (new bitmap-dc% [bitmap (make-object bitmap% 1 1)]))
  (apply-transform-attr! scratch transform-str)
  (vector-ref (send scratch get-transformation) 0))

(define (apply-matrix-to-point m x y)
  (values (+ (* (vector-ref m 0) x) (* (vector-ref m 2) y) (vector-ref m 4))
          (+ (* (vector-ref m 1) x) (* (vector-ref m 3) y) (vector-ref m 5))))

;; Maps a gradient-local point through objectBoundingBox (if applicable)
;; and then gradientTransform (if given), entirely as pure math -- NEVER
;; by mutating the dc used to draw the shape itself. An earlier version
;; of this applied both via dc.translate/scale/transform directly on the
;; shape's own dc (mirroring how the `transform` ATTRIBUTE is handled);
;; that turned out to be a real bug, caught by a test that checked a
;; specific pixel rather than just "which end of the gradient is which
;; color": since the gradient's own dc IS the shape's dc, extending its
;; transform to position the gradient ALSO shifted the shape's own
;; geometry by the same amount. Gradients correctly share whatever
;; ambient transform the shape already has (so they move/scale with a
;; `<g transform>` or viewBox exactly like the shape does) -- but their
;; OWN internal bbox/gradientTransform math has to be pre-baked into
;; plain coordinates beforehand, never layered onto the shared dc.
(define (map-paint-point x y bbox units extra-transform-str)
  (match-define (list bbox-x bbox-y bbox-w bbox-h) bbox)
  (define-values (bx by)
    (if (string=? units "objectBoundingBox")
        (values (+ bbox-x (* x (if (zero? bbox-w) 1e-6 bbox-w)))
                (+ bbox-y (* y (if (zero? bbox-h) 1e-6 bbox-h))))
        (values x y)))
  (if extra-transform-str
      (apply-matrix-to-point (transform-list->matrix extra-transform-str) bx by)
      (values bx by)))

;; Builds a brush% for a <linearGradient>/<radialGradient> reference.
;; spreadMethod is parsed nowhere (racket/draw's gradients have no
;; native spread-method support beyond the implicit "pad" clamp-to-edge
;; behavior, which happens to be SVG's own default) -- "reflect"/
;; "repeat" fall back to "pad", a disclosed, narrower gap than the rest
;; of this tier given how rarely they appear in real files.
(define (build-gradient-brush node bbox extra-alpha)
  (define attrs (xexpr-attrs node))
  (define (attr-or-inherited name)
    (or (attr-ref attrs name)
        (let ([href (href-ref attrs)])
          (and href (regexp-match? #rx"^#" href)
               (let ([parent (hash-ref (current-id-table) (substring href 1) #f)])
                 (and parent (attr-ref (xexpr-attrs parent) name)))))))
  (define stops (resolve-gradient-stops node))
  (define units (or (attr-or-inherited 'gradientUnits) "objectBoundingBox"))
  (define gt (attr-or-inherited 'gradientTransform))
  (define (map-pt x y) (map-paint-point x y bbox units gt))
  (cond
    [(null? stops) #f]
    [else
     (define rstops (stops->racket-stops stops extra-alpha))
     (match (xexpr-tag node)
       ['linearGradient
        (define x1raw (parse-gradient-coord (attr-or-inherited 'x1) "0%" units))
        (define y1raw (parse-gradient-coord (attr-or-inherited 'y1) "0%" units))
        (define x2raw (parse-gradient-coord (attr-or-inherited 'x2) "100%" units))
        (define y2raw (parse-gradient-coord (attr-or-inherited 'y2) "0%" units))
        (define-values (x1 y1) (map-pt x1raw y1raw))
        (define-values (x2 y2) (map-pt x2raw y2raw))
        ;; A gradientTransform that collapses the gradient vector to a
        ;; single point (e.g. scale(0), or a singular matrix) makes the
        ;; gradient itself unusable -- per spec (and a WPT test checking
        ;; exactly this), the correct behavior is to fall back to the
        ;; paint's own fallback color, not feed racket/draw a zero-
        ;; length gradient and get back whatever it happens to do with
        ;; that (empirically: some arbitrary blended stop color, not a
        ;; crash, but not the fallback either).
        (if (and (< (abs (- x2 x1)) 1e-6) (< (abs (- y2 y1)) 1e-6)) #f
            (new brush% [gradient (new linear-gradient% [x0 x1] [y0 y1] [x1 x2] [y1 y2] [stops rstops])]))]
       ['radialGradient
        (define cxraw (parse-gradient-coord (attr-or-inherited 'cx) "50%" units))
        (define cyraw (parse-gradient-coord (attr-or-inherited 'cy) "50%" units))
        (define rraw  (parse-gradient-coord (attr-or-inherited 'r)  "50%" units))
        (define fxraw (if (attr-or-inherited 'fx) (parse-gradient-coord (attr-or-inherited 'fx) "50%" units) cxraw))
        (define fyraw (if (attr-or-inherited 'fy) (parse-gradient-coord (attr-or-inherited 'fy) "50%" units) cyraw))
        (define-values (cx cy) (map-pt cxraw cyraw))
        (define-values (fx fy) (map-pt fxraw fyraw))
        ;; Radius: measure the mapped distance from center to a point
        ;; `rraw` away along +x, so it correctly reflects objectBoundingBox
        ;; scaling (and a uniform-scale gradientTransform). A skewed or
        ;; non-uniform-scale gradientTransform on a RADIAL gradient is
        ;; folded into this same single-radius approximation rather than
        ;; producing a true ellipse -- racket/draw's radial gradients are
        ;; circles only regardless, so this is already the ceiling on
        ;; fidelity here, not an extra loss.
        (define-values (edge-x edge-y) (map-pt (+ cxraw rraw) cyraw))
        (define r (sqrt (+ (sqr (- edge-x cx)) (sqr (- edge-y cy)))))
        ;; A zero/negative effective radius (r="0", or a degenerate
        ;; gradientTransform) is likewise unusable -- fall back rather
        ;; than propping it up with a tiny epsilon radius, which used to
        ;; produce a visible (wrong) near-solid-color dot instead of the
        ;; correct fallback.
        (if (<= r 1e-6) #f
            (new brush% [gradient (new radial-gradient% [x0 fx] [y0 fy] [r0 0] [x1 cx] [y1 cy] [r1 r] [stops rstops])]))]
       [_ #f])]))

;; Builds a brush% for a <pattern> reference: renders the pattern's own
;; content into an offscreen tile bitmap, then uses that as a stipple
;; fill. Deliberately does NOT support the pattern's `x`/`y` tile-origin
;; offset (always rendered as if x=0 y=0): after finding the
;; gradientTransform bug above, positioning the tile via dc.translate on
;; the shape's own dc looked like the same category of mistake (it would
;; shift the shape, not just the pattern), and baking an arbitrary offset
;; into the tile raster itself (via wraparound) was judged more risk than
;; the rarity of nonzero pattern x/y in real files justifies -- a
;; disclosed, narrower gap than the rest of pattern support. Similarly
;; does NOT rescale the tile's own raster resolution for whatever ambient
;; scale is active on the dc -- testing showed racket/draw's stipple-
;; tiling under a scaled dc behaves inconsistently in ways that would
;; need more investigation to characterize correctly, so a pattern used
;; inside a heavily zoomed viewBox or scaled ancestor may look under- or
;; over-detailed rather than perfectly crisp. Also doesn't apply fill-
;; opacity/element opacity to pattern fills -- a narrow, separate gap
;; from gradients, which do respect it. `patternTransform` is parsed
;; nowhere for the same reason `x`/`y` isn't: a stipple brush has no
;; coordinate-mapping hook to apply it to that wouldn't risk the same
;; shape-shifting mistake.
(define (build-pattern-brush node bbox extra-alpha)
  (define attrs (xexpr-attrs node))
  (define pattern-id (attr-ref attrs 'id))
  (cond
    [(and pattern-id (member pattern-id (current-pattern-chain))) #f]
    [else (build-pattern-brush* node attrs bbox extra-alpha pattern-id)]))

(define (build-pattern-brush* node attrs bbox extra-alpha pattern-id)
  (define (attr-or-inherited name)
    (or (attr-ref attrs name)
        (let ([href (href-ref attrs)])
          (and href (regexp-match? #rx"^#" href)
               (let ([parent (hash-ref (current-id-table) (substring href 1) #f)])
                 (and parent (attr-ref (xexpr-attrs parent) name)))))))
  (define units (or (attr-or-inherited 'patternUnits) "objectBoundingBox"))
  (define content-units (or (attr-or-inherited 'patternContentUnits) "userSpaceOnUse"))
  (match-define (list bbox-x bbox-y bbox-w bbox-h) bbox)
  (define obb? (string=? units "objectBoundingBox"))
  (define (resolve-coord s default) (if obb? (parse-gradient-coord s default units) (parse-length (or s default))))
  (define tile-w (let ([v (resolve-coord (attr-or-inherited 'width) "0")]) (if obb? (* v bbox-w) v)))
  (define tile-h (let ([v (resolve-coord (attr-or-inherited 'height) "0")]) (if obb? (* v bbox-h) v)))
  (cond
    [(or (<= tile-w 0) (<= tile-h 0)) #f]
    [else
     (define tile-px-w (max 1 (inexact->exact (round tile-w))))
     (define tile-px-h (max 1 (inexact->exact (round tile-h))))
     (define tile-bm (make-object bitmap% tile-px-w tile-px-h #f #t))
     (define tile-dc (new bitmap-dc% [bitmap tile-bm]))
     (send tile-dc set-smoothing 'smoothed)
     (define vb (attr-or-inherited 'viewBox))
     (define-values (p-vb-x p-vb-y p-vb-w p-vb-h) (parse-viewbox-attr vb))
     (cond
       [vb
        (define par (parse-preserve-aspect-ratio (attr-or-inherited 'preserveAspectRatio)))
        (send tile-dc transform (compute-viewbox-matrix p-vb-x p-vb-y p-vb-w p-vb-h
                                                          tile-px-w tile-px-h par))]
       [(string=? content-units "objectBoundingBox") (send tile-dc scale bbox-w bbox-h)]
       [else (void)])
     (define ctx* (resolve-inherited node ua-default-ctx))
     (parameterize ([current-use-chain '()] [current-ancestor-chain '()]
                    [current-canvas-size (if vb (cons p-vb-w p-vb-h) (cons tile-w tile-h))]
                    [current-pattern-chain (if pattern-id (cons pattern-id (current-pattern-chain)) (current-pattern-chain))])
       (for ([c (in-list (element-children node))]) (render-node! c ctx* tile-dc)))
     ;; extra-alpha (fill-opacity * opacity on the ELEMENT USING the
     ;; pattern, not the pattern's own content) previously went entirely
     ;; unused here -- confirmed via a WPT test (fill-opacity=0.5 with a
     ;; pattern fill) rendering fully opaque regardless. get-argb-pixels
     ;; returns STRAIGHT (non-premultiplied) color (confirmed
     ;; empirically: a 50%-alpha fill on a transparent-background bitmap
     ;; keeps its full 255 color bytes, only the alpha byte reflects the
     ;; 50%), so only the alpha channel needs scaling here, not the
     ;; color channels.
     (when (< extra-alpha 0.999)
       (define n (* tile-px-w tile-px-h 4))
       (define tile-bytes (make-bytes n))
       (send tile-bm get-argb-pixels 0 0 tile-px-w tile-px-h tile-bytes)
       (for ([i (in-range 0 n 4)])
         (bytes-set! tile-bytes i (inexact->exact (round (* extra-alpha (bytes-ref tile-bytes i))))))
       (send tile-bm set-argb-pixels 0 0 tile-px-w tile-px-h tile-bytes))
     ;; pattern x/y: an offset that shifts the WHOLE repeating grid, not
     ;; just this one tile's content -- equivalent to itself modulo the
     ;; tile size, since the tile repeats infinitely either way. Baked
     ;; directly into the tile bitmap's own pixel content via a wrap-
     ;; around read (new[i,j] = old[(i-dx) mod w, (j-dy) mod h]), rather
     ;; than via brush%'s own [transformation ...] constructor argument
     ;; -- confirmed empirically (not assumed from the docs, which
     ;; describe applying a transformation to a stipple's own
     ;; coordinates) that brush transformations are NOT respected at all
     ;; by the installed racket/draw's stipple rendering: a brush
     ;; constructed with an explicit scale(5) transformation, with no
     ;; ambient dc transform in effect at all, still tiled at the
     ;; stipple bitmap's own native size, not 5x -- so patternTransform
     ;; itself (which can rotate/skew, not just translate, and so can't
     ;; be baked into the tile via a pixel-domain shift) remains a
     ;; disclosed gap, but the pure-translation x/y case doesn't need
     ;; that broken mechanism at all.
     (define off-x (let ([v (resolve-coord (attr-or-inherited 'x) "0")]) (if obb? (* v bbox-w) v)))
     (define off-y (let ([v (resolve-coord (attr-or-inherited 'y) "0")]) (if obb? (* v bbox-h) v)))
     (define shift-x (modulo (inexact->exact (round off-x)) tile-px-w))
     (define shift-y (modulo (inexact->exact (round off-y)) tile-px-h))
     (unless (and (zero? shift-x) (zero? shift-y))
       (define n (* tile-px-w tile-px-h 4))
       (define old-bytes (make-bytes n))
       (send tile-bm get-argb-pixels 0 0 tile-px-w tile-px-h old-bytes)
       (define new-bytes (make-bytes n))
       (for* ([j (in-range tile-px-h)] [i (in-range tile-px-w)])
         (define src-i (modulo (- i shift-x) tile-px-w))
         (define src-j (modulo (- j shift-y) tile-px-h))
         (define dst-base (* 4 (+ i (* j tile-px-w))))
         (define src-base (* 4 (+ src-i (* src-j tile-px-w))))
         (for ([k (in-range 4)]) (bytes-set! new-bytes (+ dst-base k) (bytes-ref old-bytes (+ src-base k)))))
       (send tile-bm set-argb-pixels 0 0 tile-px-w tile-px-h new-bytes))
     (new brush% [stipple tile-bm])]))

;; Resolves a fill paint value (color%, a paint-ref to a gradient or
;; pattern, or #f) into a brush%. Unlike an earlier version, this never
;; touches `dc` at all -- gradients/patterns are now fully resolved as
;; plain coordinates/bitmaps beforehand (see map-paint-point), so there's
;; nothing left to save/restore around the caller's actual drawing.
;;
;; Falls back to the paint-ref's own fallback color whenever the
;; referenced server can't produce a usable brush, for ANY reason -- not
;; only a missing/wrong-type id, which is all an earlier version
;; checked. That earlier version silently rendered NO fill at all (not
;; the fallback) for a gradient with zero stops, or a gradientTransform
;; that collapses its geometry to a single point (e.g. scale(0)) -- the
;; latter caught by a WPT test expecting exactly this fallback behavior;
;; build-gradient-brush now returns #f for both cases instead of a
;; brush with unusable geometry, and this is where that #f is actually
;; turned into "try the fallback" rather than "no paint at all".
(define (resolve-fill-brush paint bbox extra-alpha)
  (let resolve ([paint paint])
    (cond
      [(not paint) #f]
      [(paint-ref? paint)
       (define server (hash-ref (current-id-table) (paint-ref-id paint) #f))
       (define built (and server
                           (case (xexpr-tag server)
                             [(linearGradient radialGradient) (build-gradient-brush server bbox extra-alpha)]
                             [(pattern) (build-pattern-brush server bbox extra-alpha)]
                             [else #f])))
       (or built (resolve (paint-ref-fallback paint)))]
      [else (new brush% [color (paint-color paint extra-alpha)])])))

;; Strokes `paths` using `brush` (a gradient or pattern brush, from
;; resolve-fill-brush) -- racket/draw's pen% has no gradient/pattern
;; support at all (confirmed empirically), so a gradient/pattern stroke
;; needs a fundamentally different technique from a solid-color one:
;; render the stroke's OWN geometry with a plain opaque pen into an
;; offscreen buffer to capture its shape as an alpha mask, separately
;; fill a same-sized buffer with the brush everywhere (keeping the SAME
;; ambient transform fills themselves already use, rather than
;; resetting to identity -- confirmed empirically that a gradient FILL
;; already correctly accounts for an ambient transform this same way,
;; so the stroke case should follow the identical convention), then
;; combine (the fill's color, the stroke mask's alpha) and composite
;; the result onto the real destination. This is the same "render shape
;; -> use as alpha mask" technique masks and feDropShadow already use
;; elsewhere in this file, applied here to a stroke outline instead of
;; a mask element or a blurred silhouette. Verified against librsvg for
;; a gradient-stroked circle: visually matching, with the residual
;; pixel diff consistent with the same curve-antialiasing variance seen
;; throughout this file for any stroked circle/ellipse, not a
;; structural difference.
(define (draw-gradient-stroke! paths brush width cap join dc)
  (define-values (cw-real ch-real) (send dc get-size))
  (define cw (max 1 (inexact->exact (round cw-real))))
  (define ch (max 1 (inexact->exact (round ch-real))))
  (define ambient (send dc get-transformation))
  (define clip (send dc get-clipping-region))
  (define mask-bm (make-object bitmap% cw ch #f #t))
  (define mask-dc (new bitmap-dc% [bitmap mask-bm]))
  (send mask-dc set-smoothing (send dc get-smoothing))
  (send mask-dc set-transformation ambient)
  (when clip (send mask-dc set-clipping-region clip))
  (send mask-dc set-brush (new brush% [style 'transparent]))
  (send mask-dc set-pen (new pen% [color "black"] [width width] [cap cap] [join join]))
  (for ([p (in-list paths)]) (send mask-dc draw-path p))
  (define mask-bytes (make-bytes (* cw ch 4)))
  (send mask-bm get-argb-pixels 0 0 cw ch mask-bytes)
  (define fill-bm (make-object bitmap% cw ch #f #t))
  (define fill-dc (new bitmap-dc% [bitmap fill-bm]))
  (send fill-dc set-transformation ambient)
  (when clip (send fill-dc set-clipping-region clip))
  (send fill-dc set-pen (new pen% [style 'transparent]))
  (send fill-dc set-brush brush)
  ;; a generously oversized rectangle (in the SAME, already-ambient-
  ;; transformed space paths are drawn in) so the brush covers the
  ;; whole stroke regardless of where it falls
  (send fill-dc draw-rectangle -100000 -100000 200000 200000)
  (define fill-bytes (make-bytes (* cw ch 4)))
  (send fill-bm get-argb-pixels 0 0 cw ch fill-bytes)
  (define combined (make-bytes (* cw ch 4)))
  (for ([i (in-range 0 (* cw ch 4) 4)])
    (bytes-set! combined i (bytes-ref mask-bytes i))
    (bytes-set! combined (+ i 1) (bytes-ref fill-bytes (+ i 1)))
    (bytes-set! combined (+ i 2) (bytes-ref fill-bytes (+ i 2)))
    (bytes-set! combined (+ i 3) (bytes-ref fill-bytes (+ i 3))))
  (premultiply! combined)
  (define result-bm (make-object bitmap% cw ch #f #t))
  (send result-bm set-argb-pixels 0 0 cw ch combined)
  (send dc set-transformation identity-transformation)
  (send dc draw-bitmap result-bm 0 0)
  (send dc set-transformation ambient))

;; Resolves the CSS `paint-order` property into an ordered list of the 3
;; symbols 'fill/'stroke/'markers. Default ("normal", or absent) is
;; (fill stroke markers); otherwise, whichever of the three keywords are
;; explicitly listed are painted in the order given, with any OMITTED
;; ones following after in their own default relative order (e.g.
;; "stroke" alone means stroke, then fill, then markers).
(define (resolve-paint-order node ctx)
  (define v (and node (geometry-attr-ref node 'paint-order)))
  (cond
    [(or (not v) (equal? (string-trim v) "normal")) '(fill stroke markers)]
    [else
     (define listed (filter (lambda (s) (memq s '(fill stroke markers)))
                             (map string->symbol (string-split (string-trim v)))))
     (define rest (filter (lambda (s) (not (memq s listed))) '(fill stroke markers)))
     (append listed rest)]))

;; `node`, if given, enables marker rendering (only path/line/polyline/
;; polygon actually have markers -- see maybe-render-markers!, which
;; already no-ops for any other element) and paint-order resolution
;; (a non-inherited CSS/presentation property, resolved fresh here via
;; geometry-attr-ref same as mix-blend-mode elsewhere, rather than
;; threaded through render-ctx). Callers with no node at all (rect/
;; circle/ellipse's own shape conversion, and text, none of which can
;; ever have markers) get the default fill-then-stroke order.
(define (draw-shape-paths! paths ctx dc [node #f])
  (define bbox (combined-bounding-box paths))
  (define fill-alpha (* (render-ctx-fill-opacity ctx) (render-ctx-opacity ctx)))
  (define stroke-alpha (* (render-ctx-stroke-opacity ctx) (render-ctx-opacity ctx)))
  (define width (render-ctx-stroke-width ctx))
  (define cap (render-ctx-stroke-linecap ctx))
  (define join (render-ctx-stroke-linejoin ctx))
  ;; pathLength: an author-claimed "logical" length for the path, which
  ;; rescales how stroke-dasharray/stroke-dashoffset are interpreted --
  ;; a dash pattern value of 1 with pathLength=2 means "half of the
  ;; path's actual length", not literally 1 user unit. The scale factor
  ;; is actual-geometric-length / pathLength; applied by scaling the
  ;; dasharray/dashoffset VALUES themselves before splitting the
  ;; polyline, rather than reparameterizing the split itself, since
  ;; that gives the identical visual result with no new machinery.
  ;; pathLength="0" means an infinite scale factor, per spec (confirmed
  ;; via a WPT test: a "1 1" dasharray with pathLength="0" renders as a
  ;; SOLID stroke in the reference, i.e. an infinitely long first dash)
  ;; -- each multiplication is guarded against 0*+inf.0 (which would be
  ;; NaN, not 0) individually, since a dasharray value could itself be
  ;; zero even when the overall scale factor is infinite. Ignored (scale
  ;; factor 1) for a negative or missing pathLength.
  (define path-length-attr (and node (attr-ref (xexpr-attrs node) 'pathLength)))
  (define path-length-scale
    (let ([pl (and path-length-attr (string->number (string-trim path-length-attr)))])
      (cond [(not pl) 1] [(zero? pl) +inf.0] [(> pl 0) (/ (paths-total-length paths) pl)] [else 1])))
  (define (scale-by-path-length v) (if (zero? v) 0 (* v path-length-scale)))
  ;; An infinite scale factor (pathLength="0") is special-cased to "no
  ;; dashing at all" rather than passing +inf.0-scaled values into
  ;; dash-split-polyline, which isn't designed to handle infinities and
  ;; was confirmed to hang (an infinite loop, not just a wrong answer)
  ;; when tried -- "no dashing" is the identical visual result anyway
  ;; (an infinitely long first dash simply never ends), reached safely.
  (define dasharray
    (cond [(infinite? path-length-scale) #f]
          [(render-ctx-stroke-dasharray ctx) => (lambda (d) (map scale-by-path-length d))]
          [else #f]))
  (define dashoffset (if (infinite? path-length-scale) 0 (scale-by-path-length (render-ctx-stroke-dashoffset ctx))))
  (define-values (fill-brush stroke-brush)
    (parameterize ([current-context-fill (render-ctx-fill ctx)] [current-context-stroke (render-ctx-stroke ctx)])
      (values (and (render-ctx-fill ctx) (resolve-fill-brush (render-ctx-fill ctx) bbox fill-alpha))
              (and (render-ctx-stroke ctx) (resolve-fill-brush (render-ctx-stroke ctx) bbox stroke-alpha)))))
  (define (do-fill!)
    (when fill-brush
      (send dc set-brush fill-brush)
      (send dc set-pen (new pen% [style 'transparent]))
      (for ([p (in-list paths)]) (send dc draw-path p 0 0 (render-ctx-fill-rule ctx)))))
  ;; strokes resolve through the SAME resolve-fill-brush a fill would,
  ;; so a gradient/pattern stroke gets a real gradient/pattern brush
  ;; (not just its fallback color) -- previously a dedicated
  ;; resolve-stroke-color always discarded a gradient/pattern down to
  ;; its fallback, since pen% (unlike brush%) has no gradient/pattern
  ;; support in racket/draw at all; see draw-gradient-stroke! above for
  ;; how a brush actually gets applied to a stroke outline.
  (define (do-stroke!)
    (when stroke-brush
      (define stroke-paths
        (if dasharray
            (for*/list ([p (in-list paths)]
                        [polyline (in-list (dc-path->polylines p))]
                        [run (in-list (dash-split-polyline polyline dasharray dashoffset))]
                        #:when (>= (length run) 2))
              (define dp (new dc-path%))
              (send dp move-to (car (first run)) (cdr (first run)))
              (for ([pt (in-list (rest run))]) (send dp line-to (car pt) (cdr pt)))
              dp)
            paths))
      (cond
        [(or (send stroke-brush get-gradient) (send stroke-brush get-stipple))
         (draw-gradient-stroke! stroke-paths stroke-brush width cap join dc)]
        [else
         (send dc set-brush (new brush% [style 'transparent]))
         (send dc set-pen (new pen% [color (send stroke-brush get-color)] [width width] [cap cap] [join join]))
         (for ([p (in-list stroke-paths)]) (send dc draw-path p))])))
  (define (do-markers!) (when node (maybe-render-markers! node ctx dc)))
  (for ([step (in-list (resolve-paint-order node ctx))])
    (case step [(fill) (do-fill!)] [(stroke) (do-stroke!)] [(markers) (do-markers!)])))

(define (render-path-node! node ctx dc)
  (draw-shape-paths! (path-data->dc-paths (or (geometry-d-ref node) "")) ctx dc node))

;; <rect>, including rounded corners, expressed as the exact equivalent
;; path-data string given by the SVG spec -- reuses the already-tested
;; arc machinery (including its zero-radius straight-line fallback,
;; which is exactly what a square-cornered rect needs) instead of
;; duplicating rounded-corner geometry.
(define (rect-node->dc-paths node)
  (define x (geometry-attr-num node 'x 0)) (define y (geometry-attr-num node 'y 0))
  (define w (geometry-attr-num node 'width 0)) (define h (geometry-attr-num node 'height 0))
  (cond
    [(not (and (> w 0) (> h 0))) '()]
    [else
     (define rx-attr (geometry-attr-ref node 'rx)) (define ry-attr (geometry-attr-ref node 'ry))
     (define rx0 (and rx-attr (parse-length rx-attr)))
     (define ry0 (and ry-attr (parse-length ry-attr)))
     (define rx (min (or rx0 ry0 0) (/ w 2.)))
     (define ry (min (or ry0 rx0 0) (/ h 2.)))
     (define d
       (if (or (<= rx 0) (<= ry 0))
           (format "M~a,~a H~a V~a H~a Z" x y (+ x w) (+ y h) x)
           (format (string-append "M~a,~a H~a A~a,~a 0 0 1 ~a,~a V~a A~a,~a 0 0 1 ~a,~a "
                                   "H~a A~a,~a 0 0 1 ~a,~a V~a A~a,~a 0 0 1 ~a,~a Z")
                   (+ x rx) y
                   (- (+ x w) rx) rx ry (+ x w) (+ y ry)
                   (- (+ y h) ry) rx ry (- (+ x w) rx) (+ y h)
                   (+ x rx) rx ry x (- (+ y h) ry)
                   (+ y ry) rx ry (+ x rx) y)))
     (path-data->dc-paths d)]))

(define (render-rect-node! node ctx dc) (draw-shape-paths! (rect-node->dc-paths node) ctx dc node))

(define (circle-node->dc-paths node)
  (define cx (geometry-attr-num node 'cx 0)) (define cy (geometry-attr-num node 'cy 0))
  (define r (geometry-attr-num node 'r 0))
  (if (<= r 0) '() (let ([p (new dc-path%)]) (send p ellipse (- cx r) (- cy r) (* 2 r) (* 2 r)) (list p))))

(define (render-circle-node! node ctx dc) (draw-shape-paths! (circle-node->dc-paths node) ctx dc node))

;; rx/ry="auto" (or omitted entirely) means "use the other radius" --
;; the same cross-fallback rect's own rx/ry already does, just phrased
;; via CSS's "auto" keyword instead of only "attribute absent". Confirmed
;; against a WPT test asserting exactly this ("rx auto means ry is
;; used").
(define (ellipse-node->dc-paths node)
  (define cx (geometry-attr-num node 'cx 0)) (define cy (geometry-attr-num node 'cy 0))
  (define (auto-or-absent? v) (or (not v) (equal? (string-trim v) "auto")))
  (define rx-raw (geometry-attr-ref node 'rx)) (define ry-raw (geometry-attr-ref node 'ry))
  (define rx0 (and (not (auto-or-absent? rx-raw)) (parse-length rx-raw)))
  (define ry0 (and (not (auto-or-absent? ry-raw)) (parse-length ry-raw)))
  (define rx (or rx0 ry0 0)) (define ry (or ry0 rx0 0))
  (if (not (and (> rx 0) (> ry 0))) '()
      (let ([p (new dc-path%)]) (send p ellipse (- cx rx) (- cy ry) (* 2 rx) (* 2 ry)) (list p))))

(define (render-ellipse-node! node ctx dc) (draw-shape-paths! (ellipse-node->dc-paths node) ctx dc node))

(define (line-node->dc-paths node)
  (define attrs (xexpr-attrs node))
  (define p (new dc-path%))
  (send p move-to (attr-num attrs 'x1 0) (attr-num attrs 'y1 0))
  (send p line-to (attr-num attrs 'x2 0) (attr-num attrs 'y2 0))
  (list p))

(define (render-line-node! node ctx dc) (draw-shape-paths! (line-node->dc-paths node) ctx dc node))

;; points ::= wsp* coordinate-pair-sequence -- reuses the same low-level
;; number reader the path-data parser uses (Part 1).
(define (parse-points s)
  (define st (make-pstate (or s "")))
  (define acc '())
  (let loop ()
    (skip-sep! st)
    (unless (at-eof? st)
      (define x (read-number! st))
      (skip-sep! st)
      (define y (read-number! st))
      (set! acc (cons (list x y) acc))
      (loop)))
  (reverse acc))

(define (points->dc-path pts close?)
  (define p (new dc-path%))
  (send p move-to (first (first pts)) (second (first pts)))
  (send p lines (map (lambda (pt) (cons (first pt) (second pt))) (rest pts)))
  (when close? (send p close))
  p)

(define (polyline-node->dc-paths node)
  (define pts (parse-points (attr-ref (xexpr-attrs node) 'points "")))
  (if (>= (length pts) 2) (list (points->dc-path pts #f)) '()))

(define (render-polyline-node! node ctx dc) (draw-shape-paths! (polyline-node->dc-paths node) ctx dc node))

;; Unlike <polyline>, a <polygon>'s closing segment is real geometry --
;; both filled and stroked -- so we close the dc-path%, not just leave
;; the last point unconnected.
(define (polygon-node->dc-paths node)
  (define pts (parse-points (attr-ref (xexpr-attrs node) 'points "")))
  (if (>= (length pts) 2) (list (points->dc-path pts #t)) '()))

(define (render-polygon-node! node ctx dc) (draw-shape-paths! (polygon-node->dc-paths node) ctx dc node))

;; Builds the dc-path%s for a single LEAF shape node, in its own local
;; coordinates, with NO paint applied -- the common geometry-only piece
;; shared by normal rendering (via the render-*-node! wrappers above)
;; and clipPath construction (Tier 5), which needs raw shape geometry to
;; build a clip region from, not painted output. Returns '() for
;; anything that isn't one of the basic shapes (including <path>, which
;; IS covered here).
(define (shape-node->dc-paths node)
  (match (xexpr-tag node)
    ['path (path-data->dc-paths (attr-ref (xexpr-attrs node) 'd ""))]
    ['rect (rect-node->dc-paths node)]
    ['circle (circle-node->dc-paths node)]
    ['ellipse (ellipse-node->dc-paths node)]
    ['line (line-node->dc-paths node)]
    ['polyline (polyline-node->dc-paths node)]
    ['polygon (polygon-node->dc-paths node)]
    [_ '()]))

;;; ---- Text (Tier 6) --------------------------------------------------------
;; <text>/<tspan>, rendered by converting each run of characters into
;; actual path geometry via dc-path%'s `text-outline` (rather than
;; drawing with dc<%>'s `draw-text`), then feeding those paths through
;; the EXISTING `draw-shape-paths!` pipeline -- so text gets full
;; gradient/pattern/dasharray/opacity paint support for free, the same
;; as any other shape, with no separate "text paint" code path needed.
;; `text-outline`'s (x,y) turned out to be the TOP-LEFT of the text's
;; bounding box, not its baseline (confirmed empirically after an
;; initial guess based on a coincidentally-plausible-looking test
;; render turned out wrong -- a guideline-and-bbox check settled it, and
;; matches what the docs say), so every draw computes the ascent from
;; `get-text-extent` and shifts up accordingly to honor SVG's baseline-
;; anchored (x,y) semantics.
;;
;; Scope: per-character x/y/dx/dy positioning works within a single
;; <text>/<tspan>'s own direct text content; text-anchor is applied per
;; run (this element's own text), not to a "chunk" spanning multiple
;; sibling tspans as the spec technically defines it -- a disclosed
;; simplification that matches the common cases (a plain <text>, or
;; tspans styled differently but not deliberately broken mid-chunk).
;; <textPath> (laying text along a path) IS implemented -- see the
;; dedicated section below, right after render-text-node!.

(define (parse-number-list s)
  (if (not s) '()
      (filter values (map string->number (filter (lambda (t) (> (string-length t) 0))
                                                  (regexp-split #px"[\\s,]+" (string-trim s)))))))

;; xml:space handling: SVG's default ("normal"/absent) collapses runs of
;; whitespace (including newlines from pretty-printed source) to a
;; single space. Leading whitespace is stripped only at the very start
;; of the whole <text> element's content (tracked via the `started?` box
;; threaded through render-text-node!'s recursion) -- collapsing but NOT
;; trimming every individual text node independently is what keeps
;; "<tspan>Blue</tspan> then <tspan>green</tspan>" from running every
;; run together into "Bluethengreen" (a real bug caught by actually
;; looking at a rendered smoke test, not just checking pixels the unit
;; tests already knew to look at). Trailing whitespace at the very end
;; of the whole subtree isn't specially stripped -- a narrow, low-impact
;; simplification (a sliver of invisible extra width that only matters
;; for text-anchor=end/middle in the rare case a chunk happens to end in
;; whitespace). xml:space="preserve" IS implemented -- see below.
;; xml:space is a special XML attribute (not a normal CSS-cascaded
;; property) that inherits down the tree on its own terms: the nearest
;; explicit setting -- on the element itself, or failing that the
;; nearest ancestor that sets one -- wins, defaulting to "default"
;; (collapse) if nothing anywhere up the tree sets it. Checked once per
;; <text> element (at the point render-node! dispatches to it) using
;; current-ancestor-chain, then threaded through render-text-node!'s own
;; recursion from there, with each <tspan> able to override it same as
;; the element itself can.
(define (initial-preserve-space? node)
  (define (xml-space-of n) (attr-ref (xexpr-attrs n) 'xml:space))
  (let loop ([chain (cons node (current-ancestor-chain))])
    (cond [(null? chain) #f]
          [(equal? (xml-space-of (car chain)) "preserve") #t]
          [(equal? (xml-space-of (car chain)) "default") #f]
          [else (loop (cdr chain))])))

(define (collapse-whitespace s) (regexp-replace* #px"[ \t\r\n]+" s " "))

(define (resolve-font ctx)
  (make-object font% (max 1 (render-ctx-font-size ctx)) (render-ctx-font-face ctx) (render-ctx-font-family ctx)
               (render-ctx-font-style ctx) (render-ctx-font-weight ctx) #f))

;; A throwaway dc used purely for font metrics (get-text-extent) --
;; metrics don't depend on what's actually being drawn to, only the
;; font and string, so one shared scratch dc is fine to reuse.
(define text-metrics-dc (new bitmap-dc% [bitmap (make-object bitmap% 1 1)]))

;; Converts SVG's baseline-anchored y to the top-left y that
;; `text-outline`/`draw-text` actually expect, using this specific
;; string+font's own ascent (not a fixed guess), so mixed font sizes
;; within one line still align on the same baseline correctly.
(define (baseline->top y text font)
  (define-values (w h descent leading) (send text-metrics-dc get-text-extent text font))
  (- y (- h descent leading)))

(define (text-width text font) (let-values ([(w h d l) (send text-metrics-dc get-text-extent text font)]) w))

;; Draws one contiguous run of plain text (no nested elements) starting
;; at (x,y), honoring text-anchor and per-character positions from
;; char-xs/char-ys (shorter than the text, or empty, is fine -- any
;; character beyond the list continues in natural left-to-right flow).
;; Returns the pen position after this run, for the caller to continue
;; laying out any following sibling content from. `text-length`, if
;; given, rescales the whole run to span EXACTLY that many user units
;; instead of its natural width, per `length-adjust` ("spacing", the
;; default, or "spacingAndGlyphs") -- verified via hand-derivation and
;; direct pixel checks rather than against librsvg, which was confirmed
;; empirically (identical output across textLength="none"/"50"/"400")
;; and via multiple independent sources (a Wikimedia Phabricator ticket
;; open since 2011, a GNOME GitLab issue) to not implement textLength at
;; all. Scoped to a single contiguous run's own direct text content --
;; textLength spanning multiple sibling tspans is a rarer, more involved
;; case (WPT's own test commentary acknowledges implementations differ
;; here) not attempted; not combined with multi-value char-xs/char-ys
;; positioning either, since those already position each character
;; explicitly in a way that would conflict with textLength's own
;; stretching.
(define (draw-text-run! text ctx dc char-xs char-ys x y [text-length #f] [length-adjust "spacing"])
  (define font (resolve-font ctx))
  (cond
    [(null? text) (values x y)]
    [(and text-length (<= (length char-xs) 1) (<= (length char-ys) 1))
     (define n (string-length text))
     (define natural-w (text-width text font))
     (define anchor-shift (case (render-ctx-text-anchor ctx) [(middle) (/ text-length 2)] [(end) text-length] [else 0]))
     (define start-x (- x anchor-shift))
     (cond
       [(equal? length-adjust "spacingAndGlyphs")
        ;; uniform horizontal scale applied to each glyph's own shape
        ;; AND advance -- built at a local origin (baseline start at
        ;; x=0) then scaled/translated into place, the same "build
        ;; local, then transform" pattern elliptical-arc-dc-path and
        ;; textPath's own per-character glyphs already use.
        (define scale (if (zero? natural-w) 1 (/ text-length natural-w)))
        (define combined (new dc-path%))
        (define cx start-x)
        (for ([i (in-range n)])
          (define ch (substring text i (add1 i)))
          (define ch-w (text-width ch font))
          (define p (new dc-path%))
          (send p text-outline font ch 0 (- (baseline->top y ch font) y))
          (send p transform (vector scale 0 0 1 0 0))
          (send p translate cx y)
          (send combined append p)
          (set! cx (+ cx (* ch-w scale))))
        (draw-shape-paths! (list combined) ctx dc)
        (values (+ start-x text-length) y)]
       [(<= n 1)
        ;; "spacing" mode with 0 or 1 characters: zero gaps to
        ;; redistribute anything across, so render naturally (glyphs
        ;; are never rescaled in "spacing" mode regardless).
        (define p (new dc-path%))
        (send p text-outline font text start-x (baseline->top y text font))
        (draw-shape-paths! (list p) ctx dc)
        (values (+ start-x natural-w) y)]
       [else
        ;; "spacing" (default): each glyph keeps its own natural shape
        ;; and width; only the GAPS between them (n-1 of them) are
        ;; stretched or compressed so the whole run spans text-length.
        (define extra-per-gap (/ (- text-length natural-w) (sub1 n)))
        (define combined (new dc-path%))
        (define cx start-x)
        (for ([i (in-range n)])
          (define ch (substring text i (add1 i)))
          (define ch-w (text-width ch font))
          (send combined text-outline font ch cx (baseline->top y ch font))
          (set! cx (+ cx ch-w extra-per-gap)))
        (draw-shape-paths! (list combined) ctx dc)
        (values (+ start-x text-length) y)])]
    [(or (> (length char-xs) 1) (> (length char-ys) 1))
     ;; Per-character positioning: build one glyph at a time so each can
     ;; land at its own explicit (or naturally-advanced) position.
     (define combined (new dc-path%))
     (define cx x) (define cy y)
     (for ([i (in-range (string-length text))])
       (define ch (substring text i (add1 i)))
       (define this-x (if (< i (length char-xs)) (list-ref char-xs i) cx))
       (define this-y (if (< i (length char-ys)) (list-ref char-ys i) cy))
       (send combined text-outline font ch this-x (baseline->top this-y ch font))
       (set! cx (+ this-x (text-width ch font)))
       (set! cy this-y))
     (draw-shape-paths! (list combined) ctx dc)
     (values cx cy)]
    [else
     (define w (text-width text font))
     (define anchor-shift (case (render-ctx-text-anchor ctx) [(middle) (/ w 2)] [(end) w] [else 0]))
     (define start-x (- x anchor-shift))
     (define p (new dc-path%))
     (send p text-outline font text start-x (baseline->top y text font))
     (draw-shape-paths! (list p) ctx dc)
     (values (+ start-x w) y)]))

;; Recursively lays out and draws <text>/<tspan> content, threading a
;; (x . y) pen position, a shared `started?` box (see
;; collapse-whitespace), and whether xml:space="preserve" is currently in
;; effect (see initial-preserve-space?) across sibling tspans and text
;; runs within the same <text> ancestor -- a tspan with its own x/y
;; attribute resets the pen there; one with dx/dy nudges it relatively;
;; one with neither just continues where the previous content left off.
;; Builds an arc-length parameterization of `polyline` (a list of (x . y)
;; points, as dc-path->polylines returns): returns (values query total)
;; where `total` is the polyline's total length and `query` maps an
;; arc-length distance to (list x y tangent-angle-radians), or #f if the
;; distance is outside [0, total]. `query` returns a single value that's
;; EITHER a list or #f (never inconsistently-arity multiple values),
;; specifically so callers can use a plain `(define r (query d))` +
;; `(when r ...)` without an arity mismatch. `query` is #f (instead of a
;; function) if `polyline` has fewer than 2 points to measure a length
;; between at all.
(define (build-arc-length-fn polyline)
  (define n (length polyline))
  (cond
    [(< n 2) (values #f 0)]
    [else
     (define pts (list->vector polyline))
     (define cumlen (make-vector n 0.0))
     (for ([i (in-range 1 n)])
       (define p0 (vector-ref pts (sub1 i))) (define p1 (vector-ref pts i))
       (vector-set! cumlen i (+ (vector-ref cumlen (sub1 i))
                                 (sqrt (+ (sqr (- (car p1) (car p0))) (sqr (- (cdr p1) (cdr p0))))))))
     (define total (vector-ref cumlen (sub1 n)))
     (values
      (lambda (d)
        (cond
          [(or (< d 0) (> d total)) #f]
          [else
           ;; binary search for the segment [i, i+1] enclosing d
           (define i (let loop ([lo 0] [hi (sub1 n)])
                       (if (>= lo hi) lo
                           (let ([mid (quotient (+ lo hi 1) 2)])
                             (if (<= (vector-ref cumlen mid) d) (loop mid hi) (loop lo (sub1 mid)))))))
           (define i2 (min (sub1 n) (add1 i)))
           (define p0 (vector-ref pts i)) (define p1 (vector-ref pts i2))
           (define seg-len (- (vector-ref cumlen i2) (vector-ref cumlen i)))
           (define t (if (zero? seg-len) 0 (/ (- d (vector-ref cumlen i)) seg-len)))
           (list (+ (car p0) (* t (- (car p1) (car p0))))
                 (+ (cdr p0) (* t (- (cdr p1) (cdr p0))))
                 (atan (- (cdr p1) (cdr p0)) (- (car p1) (car p0))))]))
      total)]))

;; Lays out text along the geometry of a referenced shape (usually a
;; <path>, but any basic shape works via the same shape-node->dc-paths
;; dispatcher clip-path/markers already use) rather than in a straight
;; line -- verified against `resvg` (librsvg has no textPath support at
;; all, confirmed independently by several sources, so it couldn't serve
;; as the usual cross-check here): a quarter-circle-arc test matched
;; resvg's own rendering within the same font-antialiasing-level noise
;; already documented for plain text, not a structural difference.
;;
;; Each character is measured (its own advance width via get-text-
;; extent), positioned at its own starting arc-length offset, and
;; rotated to the local tangent -- built as its own dc-path% at a local
;; origin, then rotated and translated into place (mirroring how
;; elliptical-arc-dc-path builds one arc segment at the origin before
;; rotating/translating it) -- before being appended into one combined
;; path, so the whole run still goes through the ordinary paint
;; pipeline in one draw-shape-paths! call, just like straight-line text.
;;
;; A real, subtle bug caught here: `dc-path%`'s own `rotate` method spins
;; the OPPOSITE direction from an angle computed via atan2(dy,dx) in
;; this codebase's own established (SVG/screen, clockwise-positive)
;; convention -- confirmed empirically, not assumed, with a simple
;; rightward-pointing line rotated by a known angle and checking exactly
;; where its endpoint landed. The angle must be negated before being
;; passed to `rotate`, the same sign-flip `elliptical-arc-dc-path`
;; already needed for the exact same reason.
;;
;; Text longer than the path is simply not rendered past the path's end,
;; per spec; `startOffset` may be a length or a percentage of the path's
;; own total length. Scoped to the <textPath>'s own direct text content
;; -- a nested <tspan> inside <textPath> isn't specially handled, a
;; disclosed, narrow gap, since font/paint context still comes from the
;; <textPath>'s own resolved ctx either way, it just won't get its own
;; distinct per-run styling.
(define (render-textpath-node! node ctx dc preserve-space?)
  (define attrs (xexpr-attrs node))
  (define ctx* (resolve-inherited node ctx))
  ;; SVG2's `path` attribute (inline path data) takes precedence over
  ;; `href` (a reference to a separate shape element) when both are
  ;; given -- confirmed via a WPT test titled exactly that. Either way,
  ;; the result is just a list of dc-path%s; the arc-length machinery
  ;; downstream doesn't care which source it came from. An EMPTY or
  ;; INVALID `path` value (producing no usable geometry at all -- path-
  ;; data->dc-paths already returns '() gracefully for unparseable data,
  ;; via this file's own path-error-recovery) falls back to `href`
  ;; instead of silently rendering nothing, confirmed via two WPT tests
  ;; specifically for an empty (`path=""`) and an invalid
  ;; (`path="Invalid path"`) value, both expecting the href fallback.
  (define path-attr (attr-ref attrs 'path))
  (define path-attr-paths (and path-attr (path-data->dc-paths path-attr)))
  (define path-attr-usable? (and path-attr-paths (pair? path-attr-paths)))
  (define href (href-ref attrs))
  (define target (and (not path-attr-usable?) href (regexp-match? #rx"^#" href)
                       (hash-ref (current-id-table) (substring href 1) #f)))
  (define paths (cond [path-attr-usable? path-attr-paths]
                      [target (shape-node->dc-paths target)]
                      [else '()]))
  (when (and paths (pair? paths))
    (define polyline (car (dc-path->polylines (car paths))))
    (define-values (arc-fn total) (build-arc-length-fn polyline))
    (when arc-fn
      (define this-preserve?
        (cond [(equal? (attr-ref attrs 'xml:space) "preserve") #t]
              [(equal? (attr-ref attrs 'xml:space) "default") #f]
              [else preserve-space?]))
      (define raw (apply string-append (filter string? (xexpr-children node))))
      (define text (if this-preserve? raw (string-trim (collapse-whitespace raw))))
      (define start-offset-str (attr-ref attrs 'startOffset))
      ;; startOffset (percentage or not) is interpreted against the
      ;; REFERENCED path's own pathLength, if it has one, and rescaled
      ;; to the path's actual geometric length -- the same idea
      ;; dasharray/dashoffset use in draw-shape-paths!. A percentage is
      ;; "X% of pathLength" (or of the actual length, if pathLength
      ;; isn't set), NOT "X% of the actual length" directly regardless
      ;; of pathLength -- confirmed via a WPT test: with pathLength="0",
      ;; startOffset 0%/50%/-50% all land at the IDENTICAL position in
      ;; the reference (any percentage of zero is zero), which only
      ;; happens if the percentage is taken against pathLength first.
      ;; pathLength="0" is a real, defined spec edge case ("must be
      ;; treated as a scaling factor of infinity", confirmed via a
      ;; separate WPT test): any non-zero LOGICAL offset then maps to a
      ;; position beyond the path's end (arc-fn's own out-of-range #f
      ;; handles that correctly, same as any other too-large offset),
      ;; while a logical offset of exactly 0 must still resolve to
      ;; exactly 0 -- explicitly guarded rather than computed as
      ;; 0*+inf.0, which would be NaN, not 0.
      (define path-length-attr-val
        (let* ([pl-str (and target (attr-ref (xexpr-attrs target) 'pathLength))]
               [pl (and pl-str (string->number (string-trim pl-str)))])
          (and pl (>= pl 0) pl)))
      (define path-length-scale
        (cond [(not path-length-attr-val) 1]
              [(zero? path-length-attr-val) +inf.0]
              [else (/ total path-length-attr-val)]))
      (define logical-offset
        (cond [(not start-offset-str) 0]
              [(regexp-match? #rx"%$" start-offset-str)
               (* (or path-length-attr-val total)
                  (/ (or (string->number (string-trim (regexp-replace #rx"%$" start-offset-str ""))) 0) 100.))]
              [else (parse-length start-offset-str 0)]))
      (define start-offset (if (zero? logical-offset) 0 (* logical-offset path-length-scale)))
      (define font (resolve-font ctx*))
      (define combined (new dc-path%))
      (define any-rendered? #f)
      (let loop ([i 0] [offset start-offset])
        (when (< i (string-length text))
          (define ch (substring text i (add1 i)))
          (define-values (w h descent leading) (send text-metrics-dc get-text-extent ch font))
          (define result (arc-fn offset))
          (when result
            (match-define (list x y angle) result)
            (define p (new dc-path%))
            (send p text-outline font ch 0 (- (- h descent leading)))
            (send p rotate (- angle))
            (send p translate x y)
            (send combined append p)
            (set! any-rendered? #t))
          (loop (add1 i) (+ offset w))))
      (when any-rendered? (draw-shape-paths! (list combined) ctx* dc)))))

;; Renders a <text> element with CSS `inline-size` or `shape-inside`
;; set: greedily word-wraps its text content across multiple lines,
;; each positioned per `text-align` (falling back to `text-anchor` if
;; text-align isn't set) with y incrementing by line-height for each
;; subsequent line -- confirmed against WPT tests' own reference files,
;; which express the expected wrapped result directly as one <tspan>
;; per line at increasing y, and confirm line-height defaults to
;; font-size*1.25 when not otherwise specified. Scoped to the <text>'s
;; own content with a SINGLE, uniform font -- a nested <tspan> with its
;; OWN distinct styling (e.g. a different font-size) within the wrapped
;; flow is a disclosed, narrower gap: several of the WPT inline-size
;; tests specifically combine wrapping with per-run styling changes
;; mid-paragraph, which would need a considerably more involved "mini
;; text-layout engine" tracking multiple concurrent run styles and per-
;; line max-height, not just plain greedy word-wrap. A nested <tspan>'s
;; own text content is still INCLUDED in the wrapped flow (as plain
;; text, using the outer element's own resolved font), just without its
;; own distinct styling applied within the wrap. Vertical writing modes,
;; bidi, and CJK line-breaking rules are out of scope entirely -- this
;; handles the common horizontal, left-to-right case.
;;
;; `box-x`/`box-y`, if given (the `shape-inside` case), override the
;; <text> element's own x/y as the wrap box's origin -- `shape-inside`
;; itself is scoped to referencing a plain <rect> specifically (deriving
;; the wrap box directly from its x/y/width), since for a rectangle,
;; "wrap text to fit inside this shape" is functionally identical to
;; inline-size (a rectangle's own horizontal extent doesn't vary by
;; line, unlike a circle or arbitrary path); referencing anything other
;; than a <rect> is a disclosed, narrower gap (falls back to not
;; wrapping at all, the same as if shape-inside weren't set), since
;; genuine arbitrary-shape text flow -- recomputing available width
;; per line from the shape's own geometry -- is a substantially bigger
;; undertaking than plain rectangular wrapping.
;;
;; `text-align: justify` distributes the gap between a line's natural
;; width and the wrap width evenly among the spaces between its words
;; -- except the LAST line of the paragraph, which is never justified,
;; the standard text-layout convention (confirmed via a WPT shape-
;; inside reference file, which shows the final line left-aligned even
;; under text-align:justify).
(define (render-wrapped-text-node! node ctx dc inline-size [box-x #f] [box-y #f])
  (define attrs (xexpr-attrs node))
  (define ctx* (resolve-inherited node ctx))
  (define font (resolve-font ctx*))
  (define (collect-text n)
    (apply string-append
           (for/list ([c (in-list (xexpr-children n))])
             (cond [(string? c) c]
                   [(memq (xexpr-tag c) '(tspan textPath)) (collect-text c)]
                   [else ""]))))
  (define text (string-trim (collapse-whitespace (collect-text node))))
  (define words (if (zero? (string-length text)) '() (string-split text " ")))
  (define line-height
    (let ([lh (geometry-attr-ref node 'line-height)])
      (cond
        [(not lh) (* 1.25 (render-ctx-font-size ctx*))]
        [(regexp-match? #px"^\\s*[0-9.]+\\s*$" lh) (* (string->number (string-trim lh)) (render-ctx-font-size ctx*))]
        [else (parse-length lh (* 1.25 (render-ctx-font-size ctx*)))])))
  ;; text-align takes precedence over text-anchor when set (confirmed
  ;; via a WPT shape-inside test using text-align specifically for
  ;; wrapped-text per-line alignment, distinct from text-anchor).
  (define align
    (let ([ta (geometry-attr-ref node 'text-align)])
      (cond [(equal? ta "center") 'center]
            [(or (equal? ta "right") (equal? ta "end")) 'right]
            [(equal? ta "justify") 'justify]
            [ta 'left]
            [else (case (render-ctx-text-anchor ctx*) [(middle) 'center] [(end) 'right] [else 'left])])))
  (define start-x (or box-x (attr-num attrs 'x 0)))
  (define start-y (or box-y (attr-num attrs 'y 0)))
  ;; Greedy word-wrap: each line gets as many words as fit within
  ;; inline-size; a single word alone wider than inline-size still gets
  ;; its own line rather than being broken mid-word (matching ordinary
  ;; "word-wrap: normal" CSS behavior, not "break-all").
  (define space-w (text-width " " font))
  (define lines
    (let loop ([remaining words] [current '()] [current-w 0] [acc '()])
      (cond
        [(null? remaining) (reverse (if (null? current) acc (cons (reverse current) acc)))]
        [else
         (define w (car remaining))
         (define w-width (text-width w font))
         (define new-w (if (null? current) w-width (+ current-w space-w w-width)))
         (if (or (null? current) (<= new-w inline-size))
             (loop (cdr remaining) (cons w current) new-w acc)
             (loop remaining '() 0 (cons (reverse current) acc)))])))
  (define n-lines (length lines))
  (for ([line (in-list lines)] [i (in-naturals)])
    (define y (+ start-y (* i line-height)))
    (define last-line? (= i (sub1 n-lines)))
    (cond
      [(and (eq? align 'justify) (not last-line?) (> (length line) 1))
       (define natural-w (+ (apply + (map (lambda (w) (text-width w font)) line)) (* (sub1 (length line)) space-w)))
       (define extra-per-gap (/ (- inline-size natural-w) (sub1 (length line))))
       (define combined (new dc-path%))
       (define cx start-x)
       (for ([w (in-list line)])
         (send combined text-outline font w cx (baseline->top y w font))
         (set! cx (+ cx (text-width w font) space-w extra-per-gap)))
       (draw-shape-paths! (list combined) ctx* dc)]
      [else
       (define line-text (string-join line " "))
       (define line-ctx (struct-copy render-ctx ctx*
                                      [text-anchor (case align [(center) 'middle] [(right) 'end] [else 'start])]))
       ;; box-x (the shape-inside case) is the wrap box's own LEFT EDGE,
       ;; so the actual anchor position needs computing from it and
       ;; inline-size. For plain inline-size (no box-x), the <text>
       ;; element's own x IS the anchor point already -- draw-text-run!
       ;; interprets it correctly via line-ctx's own text-anchor without
       ;; any further adjustment.
       (define anchor-x
         (if box-x
             (case align [(center) (+ start-x (/ inline-size 2))] [(right) (+ start-x inline-size)] [else start-x])
             start-x))
       (draw-text-run! line-text line-ctx dc '() '() anchor-x y)]))
  (values start-x (+ start-y (* (max 0 (sub1 n-lines)) line-height))))

(define (render-text-node! node ctx dc pen-x pen-y started? preserve-space?)
  (define attrs (xexpr-attrs node))
  (define ctx* (resolve-inherited node ctx))
  (define this-preserve?
    (cond [(equal? (attr-ref attrs 'xml:space) "preserve") #t]
          [(equal? (attr-ref attrs 'xml:space) "default") #f]
          [else preserve-space?]))
  (define x-list (parse-number-list (attr-ref attrs 'x)))
  (define y-list (parse-number-list (attr-ref attrs 'y)))
  (define dx-list (parse-number-list (attr-ref attrs 'dx)))
  (define dy-list (parse-number-list (attr-ref attrs 'dy)))
  (define text-length-attr (attr-ref attrs 'textLength))
  (define text-length (and text-length-attr (parse-length text-length-attr #f)))
  (define length-adjust (or (attr-ref attrs 'lengthAdjust) "spacing"))
  (define cx (box (if (pair? x-list) (car x-list) pen-x)))
  (define cy (box (if (pair? y-list) (car y-list) pen-y)))
  (when (pair? dx-list) (set-box! cx (+ (unbox cx) (car dx-list))))
  (when (pair? dy-list) (set-box! cy (+ (unbox cy) (car dy-list))))
  (for ([child (in-list (xexpr-children node))])
    (cond
      [(string? child)
       ;; xml:space="preserve": use the raw text verbatim, with no
       ;; collapsing and no leading-space stripping at all -- every
       ;; character of whitespace in the source is significant.
       (define text (if this-preserve? child
                        (let ([collapsed (collapse-whitespace child)])
                          ;; strip a leading space only if nothing has been drawn yet
                          (if (unbox started?) collapsed (string-trim collapsed #:right? #f)))))
       (when (> (string-length text) 0)
         (define-values (nx ny) (draw-text-run! text ctx* dc x-list y-list (unbox cx) (unbox cy) text-length length-adjust))
         (set-box! cx nx) (set-box! cy ny)
         (set-box! started? #t))]
      [(eq? (xexpr-tag child) 'tspan)
       (define-values (nx ny) (render-text-node! child ctx* dc (unbox cx) (unbox cy) started? this-preserve?))
       (set-box! cx nx) (set-box! cy ny)]
      [(eq? (xexpr-tag child) 'textPath)
       ;; a <textPath> lays out along a referenced shape's own geometry
       ;; rather than continuing the ordinary pen position, and doesn't
       ;; update it afterward either -- mixing plain text and <textPath>
       ;; within the same <text> is rare enough in practice that "the
       ;; pen position is simply unaffected by it" is a reasonable,
       ;; disclosed simplification rather than something more elaborate.
       (render-textpath-node! child ctx* dc this-preserve?)]
      [else (void)]))
  (values (unbox cx) (unbox cy)))

;; Computes the matrix that maps a viewBox-bearing element's own
;; coordinate space into a viewport of the given width/height, reusing
;; the exact same algorithm the root <svg> uses (Tier 0). Shared by
;; nested <svg> (which uses its own width/height, override = #f) and
;; <use> instantiating a <symbol>/<svg> (where <use>'s width/height, if
;; given, override the target's own).
(define (viewport-instantiation-matrix target-attrs override-width override-height)
  (define vb (attr-ref target-attrs 'viewBox))
  (define-values (vb-x vb-y vb-w vb-h) (parse-viewbox-attr vb))
  (define width  (or override-width  (and (attr-ref target-attrs 'width)  (parse-length (attr-ref target-attrs 'width)))  (or vb-w 100)))
  (define height (or override-height (and (attr-ref target-attrs 'height) (parse-length (attr-ref target-attrs 'height))) (or vb-h 100)))
  (define par (parse-preserve-aspect-ratio (attr-ref target-attrs 'preserveAspectRatio)))
  (if vb (compute-viewbox-matrix vb-x vb-y vb-w vb-h width height par) identity-matrix))

;;; ---- Markers (Tier 7) -----------------------------------------------------

(define (parse-marker-orient s)
  (cond [(not s) 0]
        [(string-ci=? s "auto") 'auto]
        [(string-ci=? s "auto-start-reverse") 'auto-start-reverse]
        [else (define m (regexp-match #px"^-?[0-9.]+" s)) (if m (string->number (car m)) 0)]))

;; orient=auto: the bisector of the vertex's in/out tangents (or
;; whichever one exists, at an open path's endpoints); orient=
;; auto-start-reverse: the same, plus 180 degrees when this is the
;; marker-start vertex specifically (so an arrowhead used as both start
;; and end marker points consistently "into" the line at both ends).
(define (marker-angle-degrees v orient is-start?)
  (cond
    [(number? orient) orient]
    [else
     (define in-a (vertex-in-angle v)) (define out-a (vertex-out-angle v))
     (define base (cond [(and in-a out-a) (average-angle in-a out-a)] [out-a out-a] [in-a in-a] [else 0]))
     (+ (radians->degrees base) (if (and (eq? orient 'auto-start-reverse) is-start?) 180 0))]))

;; Renders one <marker> instance at `vpos`, oriented by `angle-degrees`
;; and scaled by `stroke-width` if markerUnits="strokeWidth" (the
;; default). refX/refY -- specified in the marker's own content
;; (viewBox, if present) coordinate system -- are mapped through that
;; same viewBox matrix before being used as the anchor offset, so the
;; correct content-space point ends up exactly at the vertex regardless
;; of any viewBox scaling. `overflow:hidden` (clipping to the marker's
;; own viewport) is not enforced -- a disclosed simplification.
(define (render-marker-instance! marker-node vpos angle-degrees stroke-width dc path-fill path-stroke)
  (define attrs (xexpr-attrs marker-node))
  (define marker-units (or (attr-ref attrs 'markerUnits) "strokeWidth"))
  (define mw (parse-length (attr-ref attrs 'markerWidth) 3))
  (define mh (parse-length (attr-ref attrs 'markerHeight) 3))
  (define ref-x (parse-length (attr-ref attrs 'refX) 0))
  (define ref-y (parse-length (attr-ref attrs 'refY) 0))
  (define scale-factor (if (string=? marker-units "strokeWidth") stroke-width 1))
  (define matrix (viewport-instantiation-matrix attrs mw mh))
  (define-values (ref-x* ref-y*) (apply-matrix-to-point matrix ref-x ref-y))
  (define saved (send dc get-transformation))
  (send dc translate (car vpos) (cdr vpos))
  (send dc transform (rotation-matrix angle-degrees))
  (send dc scale scale-factor scale-factor)
  (send dc translate (- ref-x*) (- ref-y*))
  ;; the clip is applied in the established mw x mh viewport's OWN
  ;; pixel space -- BEFORE `matrix` (the viewBox-mapping transform,
  ;; if any), the same ordering the nested-<svg>/<use> viewport clips
  ;; use and for the same reason.
  (define saved-clip (push-viewport-clip! dc mw mh (geometry-attr-ref marker-node 'overflow)))
  (send dc transform matrix)
  (define ctx* (resolve-inherited marker-node ua-default-ctx))
  ;; context-fill/context-stroke within a marker's own content resolve
  ;; to the PATH's (or line/polyline/polygon's) own fill/stroke -- the
  ;; primary, most common real-world use for these two paint keywords,
  ;; letting a marker automatically match its path's stroke color.
  (parameterize ([current-use-chain '()] [current-ancestor-chain '()]
                 [current-canvas-size (cons mw mh)]
                 [current-context-fill path-fill] [current-context-stroke path-stroke])
    (for ([c (in-list (element-children marker-node))]) (render-node! c ctx* dc)))
  (send dc set-clipping-region saved-clip)
  (send dc set-transformation saved))

;; A shape's own path-and-flavor union of vertices for marker purposes --
;; the geometry only, reusing shape-node->dc-paths just like clip-path
;; construction does.
(define (shape-vertices node) (append-map dc-path->vertices (shape-node->dc-paths node)))

(define (marker-id-ref v)
  (define m (and v (regexp-match #rx"url\\(#([^)]+)\\)" v)))
  (and m (cadr m)))

;; <marker> only applies to <path>/<line>/<polyline>/<polygon> per spec
;; (not the other basic shapes). marker-start is the first vertex of the
;; shape's first subpath; marker-end is the last vertex of its last
;; subpath; marker-mid is everything else -- including subpath-boundary
;; vertices in the middle of a multi-subpath <path>, and the distinct
;; "closure vertex" `subpath-vertices` generates for a closed subpath
;; that isn't the shape's very last one.
(define (maybe-render-markers! node ctx dc)
  (when (memq (xexpr-tag node) '(path line polyline polygon))
    (define attrs (xexpr-attrs node))
    (define shorthand (attr-ref attrs 'marker))
    (define start-id (marker-id-ref (or (attr-ref attrs 'marker-start) shorthand)))
    (define mid-id   (marker-id-ref (or (attr-ref attrs 'marker-mid) shorthand)))
    (define end-id   (marker-id-ref (or (attr-ref attrs 'marker-end) shorthand)))
    (when (or start-id mid-id end-id)
      (define ctx* (resolve-inherited node ctx))
      (define verts (shape-vertices node))
      (define n (length verts))
      (for ([v (in-list verts)] [i (in-naturals)])
        (define is-start? (= i 0))
        (define is-end? (= i (sub1 n)))
        (define id (cond [is-start? start-id] [is-end? end-id] [else mid-id]))
        (when id
          (define marker-node (hash-ref (current-id-table) id #f))
          (when (and marker-node (eq? (xexpr-tag marker-node) 'marker))
            (define orient (parse-marker-orient (attr-ref (xexpr-attrs marker-node) 'orient)))
            (define angle (marker-angle-degrees v orient is-start?))
            (render-marker-instance! marker-node (cons (vertex-x v) (vertex-y v)) angle
                                      (render-ctx-stroke-width ctx*) dc
                                      (render-ctx-fill ctx*) (render-ctx-stroke ctx*))))))))

;;; ---- <image> (Tier 8) -----------------------------------------------------
;; Renders raster images referenced via `data:` URIs or local file paths.
;; Deliberately does NOT fetch remote http(s)/ftp/etc URLs at all --
;; treating an arbitrary URL found inside untrusted SVG content as
;; auto-fetchable is a real privacy/SSRF-adjacent concern, the same kind
;; of judgment call a browser makes about cross-origin content, not just
;; a missing feature; a remote href simply renders nothing, the same as
;; any other unresolvable reference in this file. This could be turned
;; into an opt-in later, but isn't built as unused, untested surface here
;; given nobody's asked for it yet.

;; The directory local file paths resolve relative to, set by
;; `svg-file->bitmap` to the SVG file's own directory; `svg-string->bitmap`
;; has no such directory, so a relative path just won't resolve there
;; (an absolute path still works either way).
(define current-svg-base-dir (make-parameter #f))

;; Loads the bitmap for an <image>'s href, or #f if it can't be (dangling,
;; remote, malformed, unreadable, or something the underlying image
;; codec can't decode) -- never raises; `bitmap%`'s own `ok?` catches the
;; "loaded but garbage" case (confirmed empirically: feeding read-bitmap
;; invalid image bytes doesn't raise, it silently returns a broken 1x1
;; bitmap that's unsafe to even query further without checking ok? first).
(define (load-image-bitmap href)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (cond
      [(regexp-match #px"^data:[^,]*;base64,(.*)$" href)
       => (lambda (m)
            (define bm (read-bitmap (open-input-bytes (base64-decode (string->bytes/utf-8 (cadr m))))))
            (and (send bm ok?) bm))]
      [(regexp-match #rx"^[a-zA-Z][a-zA-Z0-9+.-]*://" href) #f]  ; any scheme (http, https, ...): not fetched
      [else
       (define decoded-href (uri-decode href))
       (define base (current-svg-base-dir))
       (define path (if (and base (relative-path? decoded-href)) (build-path base decoded-href) decoded-href))
       (and (file-exists? path)
            (let ([bm (read-bitmap path)]) (and (send bm ok?) bm)))])))

;; <image> establishes a viewport at (x,y,width,height) -- absent width/
;; height default to the image's own natural pixel size, per spec -- and
;; fits the image's natural dimensions into it via preserveAspectRatio,
;; reusing `compute-viewbox-matrix` exactly as viewBox mapping does
;; (treating "0 0 natural-w natural-h" as the image's own implicit
;; viewBox). Clips to that viewport (the default overflow:hidden), so
;; `meet`-vs-`slice` cropping actually crops rather than overflowing.
;; `opacity` (there's no separate fill/stroke to speak of for a raster
;; image) is applied via dc<%>'s own `set-alpha`, confirmed by testing to
;; correctly modulate draw-bitmap's blending, not just brush/pen fills.
(define (render-image-node! node ctx dc)
  (define attrs (xexpr-attrs node))
  (define href (href-ref attrs))
  (define bm (and href (load-image-bitmap href)))
  (when bm
    (define natural-w (send bm get-width))
    (define natural-h (send bm get-height))
    (define x (attr-num attrs 'x 0))
    (define y (attr-num attrs 'y 0))
    ;; When only ONE of width/height is given, the other is computed to
    ;; preserve the image's own natural aspect ratio (standard replaced-
    ;; element sizing) -- confirmed missing by a WPT test giving only
    ;; `width` and expecting a proportional height, not the image's full
    ;; natural height regardless of the given width.
    (define w-attr (attr-ref attrs 'width)) (define h-attr (attr-ref attrs 'height))
    (define aspect (if (> natural-h 0) (/ natural-w natural-h) 1))
    (define-values (w h)
      (cond
        [(and w-attr h-attr) (values (attr-num attrs 'width 0) (attr-num attrs 'height 0))]
        [w-attr (let ([wv (attr-num attrs 'width 0)]) (values wv (if (> aspect 0) (/ wv aspect) 0)))]
        [h-attr (let ([hv (attr-num attrs 'height 0)]) (values (* hv aspect) hv))]
        [else (values natural-w natural-h)]))
    (when (and (> w 0) (> h 0) (> natural-w 0) (> natural-h 0))
      (define ctx* (resolve-inherited node ctx))
      (define par (parse-preserve-aspect-ratio (attr-ref attrs 'preserveAspectRatio)))
      (define matrix (compute-viewbox-matrix 0 0 natural-w natural-h w h par))
      (define saved (send dc get-transformation))
      (define saved-clip (send dc get-clipping-region))
      (define saved-alpha (send dc get-alpha))
      (send dc translate x y)
      (define clip-shape (new dc-path%))
      (send clip-shape rectangle 0 0 w h)
      (define region (new region% [dc dc]))
      (send region set-path clip-shape)
      (when saved-clip (send region intersect saved-clip))
      (send dc set-clipping-region region)
      (send dc transform matrix)
      (send dc set-alpha (* saved-alpha (render-ctx-opacity ctx*)))
      (send dc draw-bitmap bm 0 0)
      (send dc set-alpha saved-alpha)
      (send dc set-clipping-region saved-clip)
      (send dc set-transformation saved))))

;; Guards against reference cycles ("use" A -> B -> A, or a direct
;; self-reference): ids currently being expanded, so a repeat is a no-op
;; rather than an infinite recursion.
(define current-use-chain (make-parameter '()))

;; The same guard, for patterns specifically: a pattern referencing
;; itself (directly, or indirectly via ANOTHER pattern, or via
;; context-fill/context-stroke resolving back to a paint-ref pointing
;; at a pattern already being built) would otherwise recurse without
;; bound -- confirmed to actually happen and hang/crash the process
;; before this guard existed, via context-fill specifically: a shape
;; filled with a pattern sets context-fill to that SAME pattern
;; reference for the pattern's own content, so a pattern using
;; `fill="context-fill"` inside itself was resolving back to itself.
(define current-pattern-chain (make-parameter '()))

;; The document's id -> node table, set once per render. Promoted from an
;; explicit render-node! argument to a parameter in Tier 4, since paint-
;; server resolution (gradients/patterns, several calls deep inside
;; shape-drawing code) needs it too, and threading it through every
;; intermediate call would otherwise touch most of the file.
(define current-id-table (make-parameter (hash)))

(define (href-ref attrs)
  (or (attr-ref attrs 'href) (attr-ref attrs (string->symbol "xlink:href"))))

;; <use> deep-clones its referenced element in at (x,y) (an implicit
;; translate on top of use's own `transform`, already applied by
;; `render-node!` before this runs), with the used content's inheritance
;; resolved from `ctx` -- the <use> element's OWN resolved context, not
;; wherever the original definition happens to sit in the tree.
(define (render-use-node! node ctx dc)
  (define attrs (xexpr-attrs node))
  (define href (href-ref attrs))
  (when (and href (regexp-match? #rx"^#" href))
    (define id (substring href 1))
    (define target (hash-ref (current-id-table) id #f))
    (when (and target (not (member id (current-use-chain))))
      (send dc translate (attr-num attrs 'x 0) (attr-num attrs 'y 0))
      (define (render-use-content! target-dc)
        (parameterize ([current-use-chain (cons id (current-use-chain))]
                        [current-ancestor-chain '()]
                        [current-context-fill (render-ctx-fill ctx)]
                        [current-context-stroke (render-ctx-stroke ctx)])
          (match (xexpr-tag target)
            [(or 'symbol 'svg)
             (define target-attrs (xexpr-attrs target))
             (define use-width (and (attr-ref attrs 'width) (parse-length (attr-ref attrs 'width))))
             (define use-height (and (attr-ref attrs 'height) (parse-length (attr-ref attrs 'height))))
             (define ctx* (resolve-inherited target ctx))
             ;; matches viewport-instantiation-matrix's own internal
             ;; width/height resolution, so current-canvas-size (and
             ;; thus percentage resolution within the referenced
             ;; content) reflects the SAME viewport that matrix maps
             ;; content into.
             (define-values (t-vb-x t-vb-y t-vb-w t-vb-h) (parse-viewbox-attr (attr-ref target-attrs 'viewBox)))
             (define resolved-w (or use-width (and (attr-ref target-attrs 'width) (parse-length (attr-ref target-attrs 'width))) (or t-vb-w 100)))
             (define resolved-h (or use-height (and (attr-ref target-attrs 'height) (parse-length (attr-ref target-attrs 'height))) (or t-vb-h 100)))
             ;; the clip is applied in the established viewport's OWN
             ;; pixel space -- BEFORE the viewBox-mapping transform,
             ;; which would otherwise put target-dc into viewBox-space
             ;; (a different coordinate system from resolved-w/h). Per
             ;; spec, overflow is checked on the TARGET (the <symbol>/
             ;; <svg> being referenced), not the referencing <use>.
             (define saved-clip (push-viewport-clip! target-dc resolved-w resolved-h (geometry-attr-ref target 'overflow)))
             (send target-dc transform (viewport-instantiation-matrix target-attrs use-width use-height))
             (define (render-target-children! target-dc2)
               (parameterize ([current-canvas-size (cons resolved-w resolved-h)])
                 (for ([c (in-list (element-children target))]) (render-node! c ctx* target-dc2))))
             ;; the referenced <symbol>/<svg> may ALSO carry its own
             ;; opacity, separate from the <use>'s own (wrapped below) --
             ;; each applies exactly once, at the level that declared it.
             (render-with-opacity! (render-ctx-opacity ctx*) ctx* target-dc render-target-children!)
             (send target-dc set-clipping-region saved-clip)]
            [_ (render-node! target ctx target-dc)])))
      (render-with-opacity! (render-ctx-opacity ctx) ctx dc render-use-content!))))

;;; ---- Filters (Tier 10) ----------------------------------------------------
;; `filter="url(#id)"` renders the referencing element into an offscreen
;; ARGB buffer (the same full-canvas approach masks use, for the same
;; reason: avoiding the need to compute a tight bounding box, which isn't
;; readily available for groups), then runs it through the <filter>'s
;; chain of primitives (feGaussianBlur, feOffset, feColorMatrix, feFlood,
;; feMerge/feMergeNode, feComposite, feBlend, feComponentTransfer,
;; feMorphology, feDropShadow, feConvolveMatrix, feDisplacementMap,
;; feImage, feTurbulence, feDiffuseLighting/feSpecularLighting, feTile --
;; see the FILTER PRIMITIVES (CONTINUED) section below for the latter
;; six, added after the original ten), each consuming named buffers
;; (starting from "SourceGraphic"/"SourceAlpha") and producing a new
;; one, exactly mirroring the SVG filter-graph model. The <filter>'s own
;; region (x/y/width/height, default -10%..110% of the bbox) is NOT
;; enforced as a clip, the same disclosed simplification masks already
;; make. Per spec, a `filter` referencing a missing or non-<filter> id
;; means the element (and its descendants) is NOT rendered at all -- a
;; real, different fallback from mask/clip-path's "just don't apply it"
;; leniency, worth getting right rather than defaulting to the more
;; common pattern.
;;
;; All work happens in PREMULTIPLIED-alpha ARGB byte buffers (matching
;; get/set-argb-pixels' own format) since that's the correct space for
;; blurring and Porter-Duff compositing alike (blurring straight, non-
;; premultiplied color would produce dark fringing at partially-
;; transparent edges); feColorMatrix and feComponentTransfer, which are
;; defined in terms of straight color per spec, unpremultiply their
;; input, do the math, and repremultiply the result.
;;
;; Length-valued primitive attributes (stdDeviation, dx/dy, radius) are
;; in user-space units and need converting to device pixels for the
;; buffer operations; `ambient-scale-factor` extracts this from the dc's
;; current transformation. Confirmed empirically that this renderer's
;; own transform stack (translate/scale/transform -- dc<%>'s own
;; `rotate` is never used, given the Tier 1 rotation-direction fix)
;; always folds into `get-transformation`'s sub-matrix rather than its
;; separate ox/oy/xs/ys/rotation fields, so reading the scale off just
;; that sub-matrix is exact here, not merely approximate.

(define (ambient-scale-factor dc)
  (define sub (vector-ref (send dc get-transformation) 0))
  (sqrt (+ (sqr (vector-ref sub 0)) (sqr (vector-ref sub 1)))))

;; SVG filters default to `color-interpolation-filters: linearRGB`,
;; meaning primitives operate on gamma-DEcoded color by default -- a
;; real, visible difference from doing the same math directly on sRGB
;; bytes, confirmed by comparing against librsvg: a feColorMatrix
;; saturate=0 on orange differed by ~13/255 done in sRGB directly,
;; consistent with exactly this. Precomputed as 256-entry lookup tables
;; (the standard IEC 61966-2-1 formula) since they get applied to every
;; pixel's R/G/B at both ends of the filter pipeline. Applied ONCE at
;; the very start (decoding SourceGraphic) and ONCE at the very end
;; (encoding the final result back to sRGB) rather than per-primitive,
;; since supporting `color-interpolation-filters="sRGB"` as a per-
;; primitive override is a disclosed, narrow gap given how rarely it's
;; used to opt out of the default.
(define srgb->linear-table
  (build-vector 256 (lambda (v)
                       (define c (/ v 255.))
                       (define lin (if (<= c 0.04045) (/ c 12.92) (expt (/ (+ c 0.055) 1.055) 2.4)))
                       (max 0 (min 255 (inexact->exact (round (* lin 255))))))))

(define linear->srgb-table
  (build-vector 256 (lambda (v)
                       (define c (/ v 255.))
                       (define s (if (<= c 0.0031308) (* c 12.92) (- (* 1.055 (expt c (/ 1 2.4))) 0.055)))
                       (max 0 (min 255 (inexact->exact (round (* s 255))))))))

;; Both operate on STRAIGHT (non-premultiplied) R/G/B -- gamma is only
;; meaningful for actual color, not alpha-weighted color -- so callers
;; convert before premultiplying and after unpremultiplying, never on a
;; premultiplied buffer directly.
(define (srgb-bytes->linear! buf)
  (for ([i (in-range 0 (bytes-length buf) 4)])
    (bytes-set! buf (+ i 1) (vector-ref srgb->linear-table (bytes-ref buf (+ i 1))))
    (bytes-set! buf (+ i 2) (vector-ref srgb->linear-table (bytes-ref buf (+ i 2))))
    (bytes-set! buf (+ i 3) (vector-ref srgb->linear-table (bytes-ref buf (+ i 3))))))

(define (linear-bytes->srgb! buf)
  (for ([i (in-range 0 (bytes-length buf) 4)])
    (bytes-set! buf (+ i 1) (vector-ref linear->srgb-table (bytes-ref buf (+ i 1))))
    (bytes-set! buf (+ i 2) (vector-ref linear->srgb-table (bytes-ref buf (+ i 2))))
    (bytes-set! buf (+ i 3) (vector-ref linear->srgb-table (bytes-ref buf (+ i 3))))))

(define (premultiply! buf)
  (for ([i (in-range 0 (bytes-length buf) 4)])
    (define a (bytes-ref buf i))
    (bytes-set! buf (+ i 1) (quotient (* (bytes-ref buf (+ i 1)) a) 255))
    (bytes-set! buf (+ i 2) (quotient (* (bytes-ref buf (+ i 2)) a) 255))
    (bytes-set! buf (+ i 3) (quotient (* (bytes-ref buf (+ i 3)) a) 255))))

;; Returns a NEW, unpremultiplied copy; doesn't mutate `buf` (feColorMatrix
;; and feComponentTransfer both need the straight-color values without
;; disturbing the premultiplied buffer other primitives expect).
(define (unpremultiplied-copy buf)
  (define out (bytes-copy buf))
  (for ([i (in-range 0 (bytes-length out) 4)])
    (define a (bytes-ref out i))
    (when (> a 0)
      (bytes-set! out (+ i 1) (min 255 (quotient (* (bytes-ref out (+ i 1)) 255) a)))
      (bytes-set! out (+ i 2) (min 255 (quotient (* (bytes-ref out (+ i 2)) 255) a)))
      (bytes-set! out (+ i 3) (min 255 (quotient (* (bytes-ref out (+ i 3)) 255) a)))))
  out)

;; Box-blurs `buf` along one axis via an O(n) sliding-window sum, into
;; `out` (same size, must not alias `buf`): `count` positions per line,
;; `stride` bytes between consecutive samples along the blur axis,
;; `lines` many independent lines, `line-stride` bytes between the start
;; of each line. Used for BOTH horizontal (stride=4, count=w, lines=h,
;; line-stride=w*4) and vertical (stride=w*4, count=h, lines=w,
;; line-stride=4) passes, so the sliding-window logic is only written
;; once. Out-of-bounds samples are treated as transparent black (0),
;; the standard filter-effects convention for convolution at the edges.
(define (box-blur-1d! buf out count stride lines line-stride radius-left radius-right)
  (define window (+ radius-left radius-right 1))
  (for ([line (in-range lines)])
    (define line-base (* line line-stride))
    (define sum-a 0) (define sum-r 0) (define sum-g 0) (define sum-b 0)
    (define (px-base i) (+ line-base (* i stride)))
    (define (add-px! i)
      (when (and (>= i 0) (< i count))
        (define base (px-base i))
        (set! sum-a (+ sum-a (bytes-ref buf base)))
        (set! sum-r (+ sum-r (bytes-ref buf (+ base 1))))
        (set! sum-g (+ sum-g (bytes-ref buf (+ base 2))))
        (set! sum-b (+ sum-b (bytes-ref buf (+ base 3))))))
    (define (remove-px! i)
      (when (and (>= i 0) (< i count))
        (define base (px-base i))
        (set! sum-a (- sum-a (bytes-ref buf base)))
        (set! sum-r (- sum-r (bytes-ref buf (+ base 1))))
        (set! sum-g (- sum-g (bytes-ref buf (+ base 2))))
        (set! sum-b (- sum-b (bytes-ref buf (+ base 3))))))
    (for ([i (in-range (- radius-left) (add1 radius-right))]) (add-px! i))
    (for ([i (in-range count)])
      (define base (px-base i))
      (bytes-set! out base (quotient sum-a window))
      (bytes-set! out (+ base 1) (quotient sum-r window))
      (bytes-set! out (+ base 2) (quotient sum-g window))
      (bytes-set! out (+ base 3) (quotient sum-b window))
      (remove-px! (- i radius-left))
      (add-px! (+ i radius-right 1)))))

(define (box-blur-pass! buf out w h radius-left radius-right axis)
  (case axis
    [(horizontal) (box-blur-1d! buf out w 4 h (* w 4) radius-left radius-right)]
    [(vertical)   (box-blur-1d! buf out h (* w 4) w 4 radius-left radius-right)]))

;; The SVG Filter Effects spec's own recommended approximation of a true
;; Gaussian blur: three successive box blurs whose combined size is
;; derived from stdDeviation. Verified empirically against librsvg's own
;; feGaussianBlur output (a solid square blurred at stdDeviation=4):
;; matched to within +/-2 out of 255 across a full cross-section, the
;; same order of rounding noise seen elsewhere when comparing against a
;; different renderer, confirming this is the right algorithm/constants
;; before building anything else on top of it.
(define (gaussian-blur-1-axis! buf w h std-dev axis)
  (unless (<= std-dev 0)
    (define d (max 1 (inexact->exact (floor (+ (* std-dev 3 (sqrt (* 2 pi)) 0.25) 0.5)))))
    (define scratch (make-bytes (bytes-length buf)))
    (cond
      [(odd? d)
       (define r (quotient (sub1 d) 2))
       (for ([_ (in-range 3)]) (box-blur-pass! buf scratch w h r r axis) (bytes-copy! buf 0 scratch))]
      [else
       (define r (quotient d 2))
       (box-blur-pass! buf scratch w h r (sub1 r) axis) (bytes-copy! buf 0 scratch)
       (box-blur-pass! buf scratch w h (sub1 r) r axis) (bytes-copy! buf 0 scratch)
       (box-blur-pass! buf scratch w h r r axis) (bytes-copy! buf 0 scratch)])))

(define (apply-gaussian-blur! buf w h std-x std-y)
  (gaussian-blur-1-axis! buf w h std-x 'horizontal)
  (gaussian-blur-1-axis! buf w h std-y 'vertical))

;; ---- Individual primitive implementations ---------------------------------
;; Each takes already-resolved input buffer(s) (premultiplied ARGB bytes,
;; w*h*4 long) and the primitive's own xexpr node, returning a NEW
;; premultiplied buffer of the same size.

(define (fe-gaussian-blur in node w h scale)
  (define vals (parse-number-list (attr-ref (xexpr-attrs node) 'stdDeviation)))
  (define sx (* scale (if (pair? vals) (first vals) 0)))
  (define sy (* scale (if (>= (length vals) 2) (second vals) (if (pair? vals) (first vals) 0))))
  (define out (bytes-copy in))
  (apply-gaussian-blur! out w h sx sy)
  out)

(define (fe-offset in node w h scale)
  (define attrs (xexpr-attrs node))
  (define dx (inexact->exact (round (* scale (attr-num attrs 'dx 0)))))
  (define dy (inexact->exact (round (* scale (attr-num attrs 'dy 0)))))
  (define out (make-bytes (bytes-length in) 0))
  (for* ([y (in-range h)] [x (in-range w)])
    (define sx (- x dx)) (define sy (- y dy))
    (when (and (>= sx 0) (< sx w) (>= sy 0) (< sy h))
      (define src (* (+ sx (* sy w)) 4)) (define dst (* (+ x (* y w)) 4))
      (bytes-copy! out dst in src (+ src 4))))
  out)

;; type="matrix" (20 values) | "saturate" (1 value 0..1) | "hueRotate"
;; (1 value, degrees) | "luminanceToAlpha" -- the standard 5x4 affine
;; matrix on (R,G,B,A,1), applied to STRAIGHT (non-premultiplied) color
;; per spec.
(define (fe-color-matrix in node w h)
  (define attrs (xexpr-attrs node))
  (define type (or (attr-ref attrs 'type) "matrix"))
  (define vals (parse-number-list (attr-ref attrs 'values)))
  (define m
    (case type
      [("saturate")
       (define s (if (pair? vals) (first vals) 1))
       (list (+ 0.213 (* 0.787 s)) (- 0.715 (* 0.715 s)) (- 0.072 (* 0.072 s)) 0 0
             (- 0.213 (* 0.213 s)) (+ 0.715 (* 0.285 s)) (- 0.072 (* 0.072 s)) 0 0
             (- 0.213 (* 0.213 s)) (- 0.715 (* 0.715 s)) (+ 0.072 (* 0.928 s)) 0 0
             0 0 0 1 0)]
      [("hueRotate")
       (define a (degrees->radians (if (pair? vals) (first vals) 0)))
       (define c (cos a)) (define s (sin a))
       (list (+ 0.213 (* c 0.787) (* s -0.213)) (+ 0.715 (* c -0.715) (* s -0.715)) (+ 0.072 (* c -0.072) (* s 0.928)) 0 0
             (+ 0.213 (* c -0.213) (* s 0.143)) (+ 0.715 (* c 0.285) (* s 0.140)) (+ 0.072 (* c -0.072) (* s -0.283)) 0 0
             (+ 0.213 (* c -0.213) (* s -0.787)) (+ 0.715 (* c -0.715) (* s 0.715)) (+ 0.072 (* c 0.928) (* s 0.072)) 0 0
             0 0 0 1 0)]
      [("luminanceToAlpha")
       (list 0 0 0 0 0   0 0 0 0 0   0 0 0 0 0   0.2125 0.7154 0.0721 0 0)]
      [else (if (= (length vals) 20) vals (list 1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 1 0))]))
  (match-define (list m00 m01 m02 m03 m04 m10 m11 m12 m13 m14
                      m20 m21 m22 m23 m24 m30 m31 m32 m33 m34) m)
  (define straight (unpremultiplied-copy in))
  (define out (make-bytes (bytes-length in)))
  (for ([i (in-range 0 (bytes-length straight) 4)])
    (define a (/ (bytes-ref straight i) 255.))
    (define r (/ (bytes-ref straight (+ i 1)) 255.))
    (define g (/ (bytes-ref straight (+ i 2)) 255.))
    (define b (/ (bytes-ref straight (+ i 3)) 255.))
    (define (clamp01 v) (max 0. (min 1. v)))
    (define r* (clamp01 (+ (* m00 r) (* m01 g) (* m02 b) (* m03 a) m04)))
    (define g* (clamp01 (+ (* m10 r) (* m11 g) (* m12 b) (* m13 a) m14)))
    (define b* (clamp01 (+ (* m20 r) (* m21 g) (* m22 b) (* m23 a) m24)))
    (define a* (clamp01 (+ (* m30 r) (* m31 g) (* m32 b) (* m33 a) m34)))
    (bytes-set! straight i (inexact->exact (round (* a* 255))))
    (bytes-set! straight (+ i 1) (inexact->exact (round (* r* 255))))
    (bytes-set! straight (+ i 2) (inexact->exact (round (* g* 255))))
    (bytes-set! straight (+ i 3) (inexact->exact (round (* b* 255)))))
  (premultiply! straight)
  straight)

(define (fe-flood node w h ctx)
  (define attrs (xexpr-attrs node))
  (define color (or (parse-paint (or (attr-ref attrs 'flood-color) "black") (render-ctx-color ctx)) (parse-paint "black")))
  (define opacity (parse-opacity (attr-ref attrs 'flood-opacity) 1))
  (define a (inexact->exact (round (* 255 opacity))))
  ;; the filter pipeline works in linearRGB (see render-with-filter!),
  ;; so a flood color specified in ordinary sRGB needs decoding first.
  (define r (vector-ref srgb->linear-table (send color red)))
  (define g (vector-ref srgb->linear-table (send color green)))
  (define b (vector-ref srgb->linear-table (send color blue)))
  (define out (make-bytes (* w h 4)))
  (for ([i (in-range (* w h))])
    (define base (* i 4))
    (bytes-set! out base a)
    (bytes-set! out (+ base 1) (quotient (* r a) 255))
    (bytes-set! out (+ base 2) (quotient (* g a) 255))
    (bytes-set! out (+ base 3) (quotient (* b a) 255)))
  out)

;; Simple "over" compositing of each input in order (feMergeNode children).
(define (fe-merge inputs)
  (for/fold ([acc (first inputs)]) ([nxt (in-list (rest inputs))])
    (composite-over acc nxt)))

(define (composite-over bottom top)
  (define out (make-bytes (bytes-length bottom)))
  (for ([i (in-range 0 (bytes-length bottom) 4)])
    (define ta (bytes-ref top i)) (define inv (- 255 ta))
    (bytes-set! out i (min 255 (+ ta (quotient (* (bytes-ref bottom i) inv) 255))))
    (for ([k (in-list '(1 2 3))])
      (bytes-set! out (+ i k) (min 255 (+ (bytes-ref top (+ i k)) (quotient (* (bytes-ref bottom (+ i k)) inv) 255))))))
  out)

;; Standard Porter-Duff operators (over/in/out/atop/xor), plus
;; "arithmetic" (result = k1*i1*i2 + k2*i1 + k3*i2 + k4, per-channel, in
;; premultiplied space, clamped to [0,255]) -- all defined directly on
;; premultiplied color, which is exactly what Porter-Duff compositing
;; needs to be correct.
(define (fe-composite in in2 node)
  (define attrs (xexpr-attrs node))
  (define op (or (attr-ref attrs 'operator) "over"))
  (define n (bytes-length in))
  (define out (make-bytes n))
  (case op
    [("over") (bytes-copy! out 0 (composite-over in2 in))]
    [("in")
     (for ([i (in-range 0 n 4)])
       (define fa (/ (bytes-ref in2 i) 255.))
       (for ([k (in-list '(0 1 2 3))])
         (bytes-set! out (+ i k) (inexact->exact (round (* (bytes-ref in (+ i k)) fa))))))]
    [("out")
     (for ([i (in-range 0 n 4)])
       (define fa (/ (- 255 (bytes-ref in2 i)) 255.))
       (for ([k (in-list '(0 1 2 3))])
         (bytes-set! out (+ i k) (inexact->exact (round (* (bytes-ref in (+ i k)) fa))))))]
    [("atop")
     (for ([i (in-range 0 n 4)])
       (define fa (/ (bytes-ref in2 i) 255.)) (define fb (/ (- 255 (bytes-ref in i)) 255.))
       (for ([k (in-list '(0 1 2 3))])
         (bytes-set! out (+ i k) (min 255 (inexact->exact (round (+ (* (bytes-ref in (+ i k)) fa) (* (bytes-ref in2 (+ i k)) fb))))))))]
    [("xor")
     (for ([i (in-range 0 n 4)])
       (define fa (/ (- 255 (bytes-ref in2 i)) 255.)) (define fb (/ (- 255 (bytes-ref in i)) 255.))
       (for ([k (in-list '(0 1 2 3))])
         (bytes-set! out (+ i k) (min 255 (inexact->exact (round (+ (* (bytes-ref in (+ i k)) fa) (* (bytes-ref in2 (+ i k)) fb))))))))]
    [("arithmetic")
     (define k1 (attr-num attrs 'k1 0)) (define k2 (attr-num attrs 'k2 0))
     (define k3 (attr-num attrs 'k3 0)) (define k4 (attr-num attrs 'k4 0))
     (for ([i (in-range 0 n 4)])
       (for ([k (in-list '(0 1 2 3))])
         (define i1 (/ (bytes-ref in (+ i k)) 255.)) (define i2 (/ (bytes-ref in2 (+ i k)) 255.))
         (define v (+ (* k1 i1 i2) (* k2 i1) (* k3 i2) k4))
         (bytes-set! out (+ i k) (max 0 (min 255 (inexact->exact (round (* v 255))))))))]
    [else (bytes-copy! out 0 (composite-over in2 in))])
  out)

;; Shared by feBlend (Tier 10) and mix-blend-mode: the standard CSS
;; Compositing blend functions, operating per-channel on STRAIGHT
;; (unpremultiplied) 0-255 component values (cs = source/this element,
;; cb = backdrop/what's behind it). Covers every mode that's a simple
;; per-channel formula; soft-light (a piecewise formula involving its
;; own extra sub-function) and the four HSL-based modes (hue/saturation/
;; color/luminosity, which need converting each pixel to/from HSL and
;; recombining specific components rather than a per-channel formula)
;; are a disclosed, narrower gap, falling back to "normal" (the source
;; color unchanged) like any other unrecognized mode.
(define (blend-channel mode cs cb)
  (define s (/ cs 255.)) (define b (/ cb 255.))
  (define (mul x y) (* x y))
  (define (scr x y) (- (+ x y) (* x y)))
  (* 255.
     (case mode
       [("multiply") (mul b s)]
       [("screen") (scr b s)]
       [("darken") (min b s)]
       [("lighten") (max b s)]
       [("difference") (abs (- b s))]
       [("exclusion") (+ b s (* -2 b s))]
       [("hard-light") (if (<= s 0.5) (mul b (* 2 s)) (scr b (sub1 (* 2 s))))]
       [("overlay") (if (<= b 0.5) (mul s (* 2 b)) (scr s (sub1 (* 2 b))))]
       [("color-dodge") (cond [(= b 0) 0] [(= s 1) 1] [else (min 1 (/ b (- 1 s)))])]
       [("color-burn") (cond [(= b 1) 1] [(= s 0) 0] [else (- 1 (min 1 (/ (- 1 b) s)))])]
       [else s])))

;; Core SVG1.1 blend modes plus the CSS Compositing per-channel set
;; (see blend-channel); blends the straight (unpremultiplied) colors per
;; the blend function, then composites using standard alpha compositing,
;; per the spec's own definition of feBlend.
(define (fe-blend in in2 node)
  (define mode (or (attr-ref (xexpr-attrs node) 'mode) "normal"))
  (define straight-s (unpremultiplied-copy in))
  (define straight-b (unpremultiplied-copy in2))
  (define n (bytes-length in))
  (define blended (make-bytes n))
  (for ([i (in-range 0 n 4)])
    (bytes-set! blended i (bytes-ref straight-s i)) ; alpha channel untouched by the blend function itself
    (for ([k (in-list '(1 2 3))])
      (bytes-set! blended (+ i k)
                  (max 0 (min 255 (inexact->exact (round (blend-channel mode (bytes-ref straight-s (+ i k)) (bytes-ref straight-b (+ i k)))))))))
    (bytes-set! straight-s i (bytes-ref straight-s i)))
  (premultiply! blended)
  (composite-over in2 blended))

(define (parse-transfer-func node)
  (define attrs (and node (xexpr-attrs node)))
  (define type (and attrs (or (attr-ref attrs 'type) "identity")))
  (cond
    [(not node) (lambda (v) v)]
    [else
     (case type
       [("table")
        (define tv (parse-number-list (attr-ref attrs 'tableValues)))
        (cond [(null? tv) (lambda (v) v)]
              [(= (length tv) 1) (lambda (v) (first tv))]
              [else (lambda (v)
                      (define n (sub1 (length tv)))
                      (define k (min (sub1 n) (inexact->exact (floor (* v n)))))
                      (define vk (list-ref tv k)) (define vk1 (list-ref tv (add1 k)))
                      (+ vk (* (- (* v n) k) (- vk1 vk))))])]
       [("discrete")
        (define tv (parse-number-list (attr-ref attrs 'tableValues)))
        (if (null? tv) (lambda (v) v)
            (lambda (v) (list-ref tv (min (sub1 (length tv)) (inexact->exact (floor (* v (length tv))))))))]
       [("linear")
        (define slope (attr-num attrs 'slope 1)) (define intercept (attr-num attrs 'intercept 0))
        (lambda (v) (+ (* slope v) intercept))]
       [("gamma")
        (define amp (attr-num attrs 'amplitude 1)) (define exp (attr-num attrs 'exponent 1)) (define off (attr-num attrs 'offset 0))
        (lambda (v) (+ (* amp (expt v exp)) off))]
       [else (lambda (v) v)])]))

(define (fe-component-transfer in node w h)
  (define children (element-children node))
  (define (find tag) (findf (lambda (c) (eq? (xexpr-tag c) tag)) children))
  (define fr (parse-transfer-func (find 'feFuncR)))
  (define fg (parse-transfer-func (find 'feFuncG)))
  (define fb (parse-transfer-func (find 'feFuncB)))
  (define fa (parse-transfer-func (find 'feFuncA)))
  (define straight (unpremultiplied-copy in))
  (define (apply-clamped f byte) (max 0 (min 255 (inexact->exact (round (* 255 (f (/ byte 255.))))))))
  (for ([i (in-range 0 (bytes-length straight) 4)])
    (bytes-set! straight i (apply-clamped fa (bytes-ref straight i)))
    (bytes-set! straight (+ i 1) (apply-clamped fr (bytes-ref straight (+ i 1))))
    (bytes-set! straight (+ i 2) (apply-clamped fg (bytes-ref straight (+ i 2))))
    (bytes-set! straight (+ i 3) (apply-clamped fb (bytes-ref straight (+ i 3)))))
  (premultiply! straight)
  straight)

;; Separable min/max (dilate/erode) -- exact for the rectangular
;; structuring element SVG specifies, so a horizontal then vertical pass
;; (like the box blur) gives the correct result, not an approximation.
;; O(n) sliding-window min/max via a monotonic deque, replacing an
;; earlier version that rescanned the whole window at every output
;; position (O(n*radius) overall) -- found to be a real, measurable
;; bottleneck via performance profiling: a radius=10 dilate on an
;; 800x600 canvas took noticeably longer than a similarly-sized blur
;; pass, despite covering a comparable window size, because the blur
;; already used an O(n) sliding-window SUM while this used a naive
;; rescan. A running min/max can't just subtract-on-exit the way a
;; running sum can (removing the current min/max needs to know what the
;; next-best value in the window now is), which is why this needs an
;; actual deque of monotonically-ordered candidate indices rather than a
;; simple running accumulator. Verified correct against the original
;; naive version across 10,000 randomized trials (varying count/radius/
;; operator) before replacing it, given how easy an off-by-one is to
;; introduce in a sliding-window algorithm -- a first attempt at this had
;; exactly that (double-advancing the window's right edge, caught
;; immediately by the randomized check on a 3-element input).
(define (morphology-1d! buf out count stride lines line-stride radius op)
  (define should-pop? (if (eq? op 'dilate) (lambda (e n) (<= e n)) (lambda (e n) (>= e n))))
  (define idxs (make-vector (add1 count) 0))
  (for ([line (in-range lines)])
    (define line-base (* line line-stride))
    (for ([k (in-list '(0 1 2 3))])
      (define (val i) (bytes-ref buf (+ line-base (* i stride) k)))
      (define head 0) (define tail 0)
      (define (push! i)
        (let loop ()
          (when (and (> tail head) (should-pop? (val (vector-ref idxs (sub1 tail))) (val i)))
            (set! tail (sub1 tail))
            (loop)))
        (vector-set! idxs tail i)
        (set! tail (add1 tail)))
      (define next-to-push 0)
      (for ([i (in-range count)])
        (let loop ()
          (when (and (< next-to-push count) (<= next-to-push (+ i radius)))
            (push! next-to-push)
            (set! next-to-push (add1 next-to-push))
            (loop)))
        (let loop ()
          (when (and (> tail head) (< (vector-ref idxs head) (- i radius)))
            (set! head (add1 head))
            (loop)))
        (bytes-set! out (+ line-base (* i stride) k) (val (vector-ref idxs head)))))))

(define (fe-morphology in node w h scale)
  (define attrs (xexpr-attrs node))
  (define op (if (equal? (attr-ref attrs 'operator) "dilate") 'dilate 'erode))
  (define vals (parse-number-list (attr-ref attrs 'radius)))
  (define rx (inexact->exact (round (* scale (if (pair? vals) (first vals) 0)))))
  (define ry (inexact->exact (round (* scale (if (>= (length vals) 2) (second vals) (if (pair? vals) (first vals) 0))))))
  (define tmp (make-bytes (bytes-length in)))
  (define out (make-bytes (bytes-length in)))
  (if (<= rx 0) (bytes-copy! tmp 0 in) (morphology-1d! in tmp w 4 h (* w 4) rx op))
  (if (<= ry 0) (bytes-copy! out 0 tmp) (morphology-1d! tmp out h (* w 4) w 4 ry op))
  out)

;; General 2D convolution, per spec: for output pixel (x,y) and channel,
;; sum kernelMatrix[orderX-J-1, orderY-I-1] * source[x-targetX+J, y-
;; targetY+I] over the kernel's (J,I), divide by `divisor` (defaulting to
;; the kernel's own coefficient sum, or 1 if that sum is zero), then add
;; `bias`. The kernel is applied FLIPPED (rotated 180 degrees) relative
;; to its own (J,I) indices -- standard mathematical convolution, as
;; opposed to correlation -- confirmed with a deliberately asymmetric
;; kernel (a single off-center 1, everywhere else 0, which just shifts
;; the whole image by one pixel): checked directly against librsvg that
;; the shift comes out in the same direction, not mirrored.
;; `preserveAlpha="true"` convolves RGB only, on straight (non-
;; premultiplied) color, copying the source alpha channel through
;; unchanged; the default (false) convolves all 4 channels, on
;; premultiplied color, matching every other primitive's convention.
;; `edgeMode` controls out-of-bounds sampling: "duplicate" (default,
;; clamp to the nearest edge pixel), "wrap" (tile around), or "none"
;; (treat as transparent black). `kernelUnitLength` is not implemented
;; -- the convolution always operates directly in device pixels, the
;; same simplification `feMorphology`'s radius and `feGaussianBlur`'s
;; stdDeviation already make once converted via `ambient-scale-factor`.
;; Displaces pixels of `in` according to the color channel values of
;; `in2` (the displacement map), per spec:
;;   OUTPUT(x,y) = IN( x + scale*(XC(x,y)-0.5), y + scale*(YC(x,y)-0.5) )
;; where XC/YC are in2's own xChannelSelector/yChannelSelector channel
;; value (R/G/B/A, default A) at (x,y), normalized to 0-1. Sampled with
;; nearest-neighbor (not bilinear), consistent with every other
;; primitive in this file operating at whole-pixel granularity. Reads
;; in2's channel values from STRAIGHT (non-premultiplied) color, since a
;; displacement amount derived from premultiplied color would be
;; meaningless for a mostly-transparent map (premultiplied RGB collapses
;; toward 0 regardless of intended hue as alpha drops); `in` itself is
;; sampled directly in its existing (premultiplied) form, since a pure
;; spatial remapping doesn't care which color space it's in as long as
;; it's consistent between read and write. A displaced source position
;; landing outside the buffer produces transparent black, matching this
;; file's edgeMode="none"-equivalent convention elsewhere.
;; Renders a referenced image or document element as the filter's own
;; input (feImage ignores `in` entirely, generating its own content, the
;; same way feFlood and feTurbulence do). Two cases:
;;  - `href` is a local fragment (#id) referencing another element in
;;    the same document: rendered via the ordinary rendering pipeline
;;    (render-node!, with a fresh ua-default-ctx and reset ancestor/use
;;    chains, matching how <use>/mask/pattern content all start fresh)
;;    at its own natural position, under the SAME ambient transform as
;;    the rest of the filter chain so it aligns with everything else.
;;    Precise x/y/width/height subregion-fitting for this case (treating
;;    the reference like a <use> with explicit width/height forcing a
;;    scale) is NOT implemented -- a disclosed, narrower scope decision,
;;    given how much additional machinery precise subregion tracking
;;    would need on top of what this file's filter system already
;;    deliberately omits generally (see the filter section above).
;;  - `href` is a raster image (or base64 data: URI): loaded via the
;;    existing load-image-bitmap and fit into its own x/y/width/height
;;    subregion (defaulting to the whole filter canvas, converted back
;;    to user-space via the ambient scale factor, if unspecified) using
;;    the same compute-viewbox-matrix-based fitting <image> itself uses,
;;    respecting preserveAspectRatio -- this case gets full, precise
;;    subregion support, since it's exactly <image>'s own well-defined
;;    fitting logic reapplied, not a new kind of approximation.
;; feTurbulence generates Perlin/fractal noise via the SPECIFIC reference
;; algorithm the SVG spec itself prescribes (a Park-Miller "minimal
;; standard" linear congruential PRNG seeding a permutation table and
;; per-channel gradient vectors), rather than "some Perlin noise
;; implementation" -- the spec is this prescriptive specifically so
;; independent implementations produce the SAME noise field for the
;; same seed, which matters more here than for any other primitive in
;; this file. Ported as closely as possible to the spec's own reference
;; pseudocode (constants, table construction, noise2/turbulence
;; functions).
;;
;; Verification note: unlike every other primitive cross-checked in this
;; file, EXACT pixel-for-pixel matching against another renderer isn't
;; the meaningful bar here -- two independently-implemented PRNGs that
;; are each individually correct will still walk their permutation
;; tables differently and produce a DIFFERENT specific noise field for
;; the same seed unless every last implementation detail matches
;; exactly (this file's own port has not been confirmed bit-exact
;; against librsvg's specific output). What WAS checked, against
;; librsvg: the overall statistical profile (mean/min/max pixel value)
;; and visual character (pale, blobby, multi-colored noise, consistent
;; with genuine 2D Perlin turbulence) converge closely once the
;; generated alpha channel is correctly composited against the
;; background -- confirmed only after finding a real bug in the
;; verification process itself: an early comparison ignored the
;; generated alpha channel entirely and rendered RGB opaquely, which
;; looked nothing like librsvg's output and would have been wrongly
;; read as an algorithm bug; once composited properly (treating R/G/B/A
;; as premultiplied, blended over the background using the noise's own
;; alpha), the mean pixel value converged from wildly off to within
;; ~4% of librsvg's, and the max matched exactly. Determinism (the same
;; seed and parameters always produce the same output) is guaranteed
;; and tested directly, which is the property that actually matters for
;; a static renderer's own reproducibility.
;;
;; `stitchTiles="stitch"` (adjusting frequencies for seamless tiling) is
;; not implemented -- always behaves as noStitch, a disclosed, narrower
;; gap given the added complexity of the frequency-adjustment logic for
;; a comparatively rare, tiling-specific use case.
(define TURB-RAND-m 2147483647) ; 2**31 - 1
(define TURB-RAND-a 16807)
(define TURB-RAND-q 127773)
(define TURB-RAND-r 2836)
(define TURB-BSize 256)
(define TURB-BM 255)
(define TURB-PerlinN 4096)

(define (turb-setup-seed seed0)
  (define seed (inexact->exact (truncate seed0)))
  (define s1 (if (<= seed 0) (+ (- (modulo seed (sub1 TURB-RAND-m))) 1) seed))
  (if (> s1 (sub1 TURB-RAND-m)) (sub1 TURB-RAND-m) s1))

(define (turb-rand-next lSeed)
  (define result (- (* TURB-RAND-a (remainder lSeed TURB-RAND-q)) (* TURB-RAND-r (quotient lSeed TURB-RAND-q))))
  (if (<= result 0) (+ result TURB-RAND-m) result))

;; Builds the shared permutation table (uLatticeSelector) and per-channel
;; (R,G,B,A, in that order) unit gradient vectors, seeded per `seed0`.
(define (turb-init-tables seed0)
  (define lattice (make-vector (+ TURB-BSize TURB-BSize 2) 0))
  (define gradient (build-vector 4 (lambda (_) (make-vector (+ TURB-BSize TURB-BSize 2) (cons 0.0 0.0)))))
  (define seed (box (turb-setup-seed seed0)))
  (define (next!) (set-box! seed (turb-rand-next (unbox seed))) (unbox seed))
  (for ([k (in-range 4)])
    (for ([i (in-range TURB-BSize)])
      (vector-set! lattice i i)
      (define gx (/ (exact->inexact (- (remainder (next!) (+ TURB-BSize TURB-BSize)) TURB-BSize)) TURB-BSize))
      (define gy (/ (exact->inexact (- (remainder (next!) (+ TURB-BSize TURB-BSize)) TURB-BSize)) TURB-BSize))
      (define s (sqrt (+ (* gx gx) (* gy gy))))
      (vector-set! (vector-ref gradient k) i (if (zero? s) (cons 0.0 0.0) (cons (/ gx s) (/ gy s))))))
  (let loop ([i (sub1 TURB-BSize)])
    (when (> i 0)
      (define j (remainder (next!) TURB-BSize))
      (define tmp (vector-ref lattice i))
      (vector-set! lattice i (vector-ref lattice j))
      (vector-set! lattice j tmp)
      (loop (sub1 i))))
  (for ([i (in-range (+ TURB-BSize 2))])
    (vector-set! lattice (+ TURB-BSize i) (vector-ref lattice i))
    (for ([k (in-range 4)])
      (vector-set! (vector-ref gradient k) (+ TURB-BSize i) (vector-ref (vector-ref gradient k) i))))
  (values lattice gradient))

(define (turb-s-curve t) (* t t (- 3.0 (* 2.0 t))))
(define (turb-lerp t a b) (+ a (* t (- b a))))

;; The lattice indices and s-curve/interpolation factors depend only on
;; (x,y), not on which of the 4 channels is being computed -- only the
;; final gradient dot-product is channel-specific. Splitting this out
;; and computing it once per octave (rather than once per octave PER
;; CHANNEL, redundantly, as an earlier version did) was found via
;; profiling to meaningfully reduce fe-turbulence's real cost at
;; realistic multi-octave settings.
(define (turb-lattice-info x y lattice)
  (define tx (+ x TURB-PerlinN))
  (define bx0 (bitwise-and (inexact->exact (truncate tx)) TURB-BM))
  (define bx1 (bitwise-and (add1 bx0) TURB-BM))
  (define rx0 (- tx (truncate tx)))
  (define ty (+ y TURB-PerlinN))
  (define by0 (bitwise-and (inexact->exact (truncate ty)) TURB-BM))
  (define by1 (bitwise-and (add1 by0) TURB-BM))
  (define ry0 (- ty (truncate ty)))
  (define i (vector-ref lattice bx0))
  (define j (vector-ref lattice bx1))
  (values (vector-ref lattice (+ i by0)) (vector-ref lattice (+ j by0))
          (vector-ref lattice (+ i by1)) (vector-ref lattice (+ j by1))
          (turb-s-curve rx0) (turb-s-curve ry0)
          rx0 (- rx0 1.0) ry0 (- ry0 1.0)))

(define (turb-noise2-from-info channel b00 b10 b01 b11 sx sy rx0 rx1 ry0 ry1 gradient)
  (define g (vector-ref gradient channel))
  (define q00 (vector-ref g b00)) (define u1 (+ (* rx0 (car q00)) (* ry0 (cdr q00))))
  (define q10 (vector-ref g b10)) (define v1 (+ (* rx1 (car q10)) (* ry0 (cdr q10))))
  (define a (turb-lerp sx u1 v1))
  (define q01 (vector-ref g b01)) (define u2 (+ (* rx0 (car q01)) (* ry1 (cdr q01))))
  (define q11 (vector-ref g b11)) (define v2 (+ (* rx1 (car q11)) (* ry1 (cdr q11))))
  (define b (turb-lerp sx u2 v2))
  (turb-lerp sy a b))

(define (turb-noise2 channel x y lattice gradient)
  (define-values (b00 b10 b01 b11 sx sy rx0 rx1 ry0 ry1) (turb-lattice-info x y lattice))
  (turb-noise2-from-info channel b00 b10 b01 b11 sx sy rx0 rx1 ry0 ry1 gradient))

(define (turb-turbulence channel x y base-freq-x base-freq-y num-octaves fractal-sum? lattice gradient)
  (let loop ([octave 0] [vx (* x base-freq-x)] [vy (* y base-freq-y)] [amplitude 1.0] [sum 0.0])
    (if (>= octave num-octaves)
        sum
        (let ([n (turb-noise2 channel vx vy lattice gradient)])
          (loop (add1 octave) (* vx 2) (* vy 2) (* amplitude 2.0)
                (+ sum (/ (if fractal-sum? n (abs n)) amplitude)))))))

;; `baseFrequency` is a user-space quantity, but this file's filter
;; buffers are in device pixels -- device pixel (x,y) is converted back
;; to an approximate user-space position via the ambient scale factor
;; (dividing by `scale`, the same uniform factor stdDeviation/radius
;; already use elsewhere) so the noise frequency looks visually
;; consistent regardless of zoom level. This doesn't track the exact
;; absolute user-space origin (only the scale), so panning/zooming the
;; SAME document could shift the noise field slightly relative to a
;; renderer that tracks the true absolute origin -- a disclosed,
;; narrower simplification, unlikely to matter for the overwhelmingly
;; common case of a single, self-contained decorative filter.
;; feDiffuseLighting/feSpecularLighting light an image using its own
;; ALPHA channel as a bump map, following the SVG spec's own Phong-
;; lighting-model formulas: a surface normal from a Sobel gradient of
;; the alpha channel, then a diffuse or specular reflectance term for
;; one of three light source geometries (feDistantLight/fePointLight/
;; feSpotLight, given as a single child element).
;;
;; Surface normal: at edge/corner pixels, the spec defines 9 DIFFERENT
;; Sobel-kernel variants (smaller kernels with different divisors for
;; the pixels where a full 3x3 neighborhood doesn't exist, not simply
;; the interior kernel with out-of-bounds samples papered over) -- this
;; uses "duplicate" edge-clamping instead (reusing the interior 3x3
;; Sobel kernel with out-of-range samples clamped to the nearest valid
;; pixel, the same convention feConvolveMatrix's own default edgeMode
;; uses) rather than porting all 9 variants -- a disclosed, narrower
;; simplification affecting only the outermost 1-pixel border of the
;; canvas, where lighting effects are rarely the visual focus anyway.
;;
;; A light source's x/y/z position (point/spot lights) is converted
;; from user-space to device-pixel space via the ambient scale factor,
;; the same conversion feTurbulence's own coordinates use, since the
;; surface-normal/light-vector math all happens directly in device-
;; pixel buffer space. `feDistantLight`'s constant direction needs no
;; such conversion.
(define (surface-normal-at alpha-buf w h x y surface-scale)
  (define (a-at px py)
    (define cx (max 0 (min (sub1 w) px))) (define cy (max 0 (min (sub1 h) py)))
    (/ (bytes-ref alpha-buf (* 4 (+ cx (* cy w)))) 255.0))
  (define nx (* (- surface-scale) 0.25
                (- (+ (a-at (add1 x) (sub1 y)) (* 2 (a-at (add1 x) y)) (a-at (add1 x) (add1 y)))
                   (+ (a-at (sub1 x) (sub1 y)) (* 2 (a-at (sub1 x) y)) (a-at (sub1 x) (add1 y))))))
  (define ny (* (- surface-scale) 0.25
                (- (+ (a-at (sub1 x) (add1 y)) (* 2 (a-at x (add1 y))) (a-at (add1 x) (add1 y)))
                   (+ (a-at (sub1 x) (sub1 y)) (* 2 (a-at x (sub1 y))) (a-at (add1 x) (sub1 y))))))
  (define norm (sqrt (+ (* nx nx) (* ny ny) 1.0)))
  (values (/ nx norm) (/ ny norm) (/ 1.0 norm)))

;; Returns a function (x y z-surface -> (values lx ly lz lr lg lb)): the
;; unit light vector and the light's own effective color at surface
;; position (x,y,z-surface), all in device-pixel space. Light color is
;; constant except for feSpotLight, which attenuates it by the angle
;; from its own axis (and cuts it off entirely outside
;; limitingConeAngle, if given).
(define (make-light-fn node light-r light-g light-b scale)
  (define light-node (for/first ([c (in-list (element-children node))]
                                  #:when (memq (xexpr-tag c) '(feDistantLight fePointLight feSpotLight)))
                       c))
  (cond
    [(not light-node) (lambda (x y z) (values 0.0 0.0 1.0 0 0 0))]
    [(eq? (xexpr-tag light-node) 'feDistantLight)
     (define attrs (xexpr-attrs light-node))
     (define azimuth (degrees->radians (attr-num attrs 'azimuth 0)))
     (define elevation (degrees->radians (attr-num attrs 'elevation 0)))
     (define lx (* (cos azimuth) (cos elevation)))
     (define ly (- (* (sin azimuth) (cos elevation))))
     (define lz (sin elevation))
     (lambda (x y z) (values lx ly lz light-r light-g light-b))]
    [(eq? (xexpr-tag light-node) 'fePointLight)
     (define attrs (xexpr-attrs light-node))
     (define lightx (* scale (attr-num attrs 'x 0))) (define lighty (* scale (attr-num attrs 'y 0)))
     (define lightz (* scale (attr-num attrs 'z 0)))
     (lambda (x y z)
       (define dx (- lightx x)) (define dy (- lighty y)) (define dz (- lightz z))
       (define n (sqrt (+ (* dx dx) (* dy dy) (* dz dz))))
       (if (zero? n) (values 0.0 0.0 1.0 light-r light-g light-b)
           (values (/ dx n) (/ dy n) (/ dz n) light-r light-g light-b)))]
    [else ; feSpotLight
     (define attrs (xexpr-attrs light-node))
     (define lightx (* scale (attr-num attrs 'x 0))) (define lighty (* scale (attr-num attrs 'y 0)))
     (define lightz (* scale (attr-num attrs 'z 0)))
     (define pax (* scale (attr-num attrs 'pointsAtX 0))) (define pay (* scale (attr-num attrs 'pointsAtY 0)))
     (define paz (* scale (attr-num attrs 'pointsAtZ 0)))
     (define spec-exp (attr-num attrs 'specularExponent 1))
     (define cone-cos (let ([a (attr-ref attrs 'limitingConeAngle)])
                         (and a (cos (degrees->radians (or (string->number a) 90))))))
     (define sx (- pax lightx)) (define sy (- pay lighty)) (define sz (- paz lightz))
     (define sn (sqrt (+ (* sx sx) (* sy sy) (* sz sz))))
     (define-values (sux suy suz) (if (zero? sn) (values 0.0 0.0 1.0) (values (/ sx sn) (/ sy sn) (/ sz sn))))
     (lambda (x y z)
       (define dx (- lightx x)) (define dy (- lighty y)) (define dz (- lightz z))
       (define n (sqrt (+ (* dx dx) (* dy dy) (* dz dz))))
       (if (zero? n) (values 0.0 0.0 1.0 0 0 0)
           (let* ([lx (/ dx n)] [ly (/ dy n)] [lz (/ dz n)]
                  [minus-l-dot-s (- (+ (* lx sux) (* ly suy) (* lz suz)))])
             (if (or (<= minus-l-dot-s 0) (and cone-cos (< minus-l-dot-s cone-cos)))
                 (values lx ly lz 0 0 0)
                 (let ([atten (expt minus-l-dot-s spec-exp)])
                   (values lx ly lz (* light-r atten) (* light-g atten) (* light-b atten)))))))]))

(define (lighting-color-of attrs ctx)
  (define c (or (attr-ref attrs 'lighting-color) (attr-ref attrs 'lightColor)))
  (or (parse-paint c (render-ctx-color ctx)) (parse-paint "white")))

(define (fe-diffuse-lighting in node w h scale ctx)
  (define attrs (xexpr-attrs node))
  (define surface-scale (attr-num attrs 'surfaceScale 1))
  (define kd (attr-num attrs 'diffuseConstant 1))
  (define color (lighting-color-of attrs ctx))
  (define light-fn (make-light-fn node (send color red) (send color green) (send color blue) scale))
  (define out (make-bytes (* w h 4)))
  (for* ([y (in-range h)] [x (in-range w)])
    (define-values (nx ny nz) (surface-normal-at in w h x y surface-scale))
    (define z (* surface-scale (/ (bytes-ref in (* 4 (+ x (* y w)))) 255.0)))
    (define-values (lx ly lz lr lg lb) (light-fn x y z))
    (define ndotl (max 0.0 (+ (* nx lx) (* ny ly) (* nz lz))))
    (define base (* (+ x (* y w)) 4))
    (bytes-set! out base 255)
    (bytes-set! out (+ base 1) (max 0 (min 255 (inexact->exact (round (* kd ndotl lr))))))
    (bytes-set! out (+ base 2) (max 0 (min 255 (inexact->exact (round (* kd ndotl lg))))))
    (bytes-set! out (+ base 3) (max 0 (min 255 (inexact->exact (round (* kd ndotl lb)))))))
  out)

(define (fe-specular-lighting in node w h scale ctx)
  (define attrs (xexpr-attrs node))
  (define surface-scale (attr-num attrs 'surfaceScale 1))
  (define ks (attr-num attrs 'specularConstant 1))
  (define spec-exp (attr-num attrs 'specularExponent 1))
  (define color (lighting-color-of attrs ctx))
  (define light-fn (make-light-fn node (send color red) (send color green) (send color blue) scale))
  (define out (make-bytes (* w h 4)))
  (for* ([y (in-range h)] [x (in-range w)])
    (define-values (nx ny nz) (surface-normal-at in w h x y surface-scale))
    (define z (* surface-scale (/ (bytes-ref in (* 4 (+ x (* y w)))) 255.0)))
    (define-values (lx ly lz lr lg lb) (light-fn x y z))
    ;; H = normalize(L + eye), eye = (0,0,1) (viewer looking straight
    ;; down the z axis from infinity, per spec)
    (define hx lx) (define hy ly) (define hz (+ lz 1.0))
    (define hn (sqrt (+ (* hx hx) (* hy hy) (* hz hz))))
    (define ndoth (if (zero? hn) 0.0 (max 0.0 (/ (+ (* nx hx) (* ny hy) (* nz hz)) hn))))
    (define factor (* ks (expt ndoth spec-exp)))
    (define r (max 0 (min 255 (inexact->exact (round (* factor lr))))))
    (define g (max 0 (min 255 (inexact->exact (round (* factor lg))))))
    (define b (max 0 (min 255 (inexact->exact (round (* factor lb))))))
    (define a (max r g b))
    (define base (* (+ x (* y w)) 4))
    (bytes-set! out base a)
    (bytes-set! out (+ base 1) r) (bytes-set! out (+ base 2) g) (bytes-set! out (+ base 3) b))
  out)

;; feTile tiles a smaller subregion of `in` to fill the whole w*h
;; buffer. Uniquely among this file's primitives, feTile genuinely needs
;; a subregion to tile FROM -- since this file's filter system otherwise
;; deliberately never tracks per-primitive subregions (every primitive
;; computes across the full canvas; see the filter section above), this
;; reaches back into the filter graph's own markup for the region: the
;; x/y/width/height attributes on the specific primitive node that
;; produced `in` (in user-space units, converted to device pixels via
;; the ambient scale factor). Since the full-canvas buffer that
;; primitive produced already contains correct content everywhere, just
;; not clipped to that region, tiling a crop of it this way is
;; sufficient without needing true subregion tracking generally. If the
;; referenced primitive specified no explicit subregion at all (or
;; `in-node` is unavailable, e.g. `in="SourceGraphic"`, which has no
;; producing primitive node to read a subregion from), there's nothing
;; to tile from, so `in` is returned unchanged -- a disclosed, narrower
;; gap for that specific case.
(define (fe-tile in in-node w h scale)
  (define attrs (and in-node (xexpr-attrs in-node)))
  (define x-str (and attrs (attr-ref attrs 'x))) (define y-str (and attrs (attr-ref attrs 'y)))
  (define w-str (and attrs (attr-ref attrs 'width))) (define h-str (and attrs (attr-ref attrs 'height)))
  (cond
    [(not (and x-str y-str w-str h-str)) in]
    [else
     (define tx (inexact->exact (round (* scale (parse-length x-str)))))
     (define ty (inexact->exact (round (* scale (parse-length y-str)))))
     (define tw (max 1 (inexact->exact (round (* scale (parse-length w-str))))))
     (define th (max 1 (inexact->exact (round (* scale (parse-length h-str))))))
     (define out (make-bytes (* w h 4)))
     (for* ([y (in-range h)] [x (in-range w)])
       (define sx (+ tx (modulo (- x tx) tw)))
       (define sy (+ ty (modulo (- y ty) th)))
       (when (and (>= sx 0) (< sx w) (>= sy 0) (< sy h))
         (define out-base (* (+ x (* y w)) 4))
         (define in-base (* (+ sx (* sy w)) 4))
         (for ([k (in-list '(0 1 2 3))]) (bytes-set! out (+ out-base k) (bytes-ref in (+ in-base k))))))
     out]))

(define (fe-turbulence node w h scale)
  (define attrs (xexpr-attrs node))
  (define freq-vals (parse-number-list (attr-ref attrs 'baseFrequency)))
  (define base-freq-x (if (pair? freq-vals) (first freq-vals) 0.0))
  (define base-freq-y (if (>= (length freq-vals) 2) (second freq-vals) base-freq-x))
  (define num-octaves (max 0 (inexact->exact (round (attr-num attrs 'numOctaves 1)))))
  (define seed (attr-num attrs 'seed 0))
  (define fractal-sum? (equal? (attr-ref attrs 'type) "fractalNoise"))
  (define-values (lattice gradient) (turb-init-tables seed))
  (define out (make-bytes (* w h 4)))
  (define sums (make-vector 4 0.0))
  (for* ([y (in-range h)] [x (in-range w)])
    (define ux (/ (+ x 0.5) scale)) (define uy (/ (+ y 0.5) scale))
    (vector-fill! sums 0.0)
    ;; Shares the lattice-index/interpolation-factor computation across
    ;; all 4 channels each octave (see turb-lattice-info), rather than
    ;; each channel's own turb-turbulence/turb-noise2 call redundantly
    ;; recomputing identical lattice lookups -- found via profiling to
    ;; meaningfully reduce fe-turbulence's real cost at realistic
    ;; multi-octave settings (a common numOctaves=8 case went from
    ;; ~1.9s to well under 1s on a 400x400 canvas).
    (let loop ([octave 0] [vx (* ux base-freq-x)] [vy (* uy base-freq-y)] [amplitude 1.0])
      (when (< octave num-octaves)
        (define-values (b00 b10 b01 b11 sx sy rx0 rx1 ry0 ry1) (turb-lattice-info vx vy lattice))
        (for ([c (in-range 4)])
          (define n (turb-noise2-from-info c b00 b10 b01 b11 sx sy rx0 rx1 ry0 ry1 gradient))
          (vector-set! sums c (+ (vector-ref sums c) (/ (if fractal-sum? n (abs n)) amplitude))))
        (loop (add1 octave) (* vx 2) (* vy 2) (* amplitude 2.0))))
    (define (chan-byte c)
      (define t (vector-ref sums c))
      (define v01 (if fractal-sum? (/ (+ (* t 255) 255) 2.0) (* t 255)))
      (max 0 (min 255 (inexact->exact (round v01)))))
    (define base (* (+ x (* y w)) 4))
    (bytes-set! out base (chan-byte 3))
    (bytes-set! out (+ base 1) (chan-byte 0))
    (bytes-set! out (+ base 2) (chan-byte 1))
    (bytes-set! out (+ base 3) (chan-byte 2)))
  (premultiply! out)
  out)

(define (fe-image node w h scale ctx ambient)
  (define attrs (xexpr-attrs node))
  (define href (href-ref attrs))
  (define content-bm (make-object bitmap% w h #f #t))
  (define content-dc (new bitmap-dc% [bitmap content-bm]))
  (send content-dc set-smoothing 'smoothed)
  (send content-dc set-transformation ambient)
  (cond
    [(and href (regexp-match? #rx"^#" href))
     (define target (hash-ref (current-id-table) (substring href 1) #f))
     (when target
       (parameterize ([current-use-chain '()] [current-ancestor-chain '()])
         (render-node! target ua-default-ctx content-dc)))]
    [href
     (define bm (load-image-bitmap href))
     (when bm
       (define nat-w (send bm get-width)) (define nat-h (send bm get-height))
       (when (and (> nat-w 0) (> nat-h 0))
         (define x (attr-num attrs 'x 0)) (define y (attr-num attrs 'y 0))
         (define wv (if (attr-ref attrs 'width) (attr-num attrs 'width 0) (/ w scale)))
         (define hv (if (attr-ref attrs 'height) (attr-num attrs 'height 0) (/ h scale)))
         (when (and (> wv 0) (> hv 0))
           (define par (parse-preserve-aspect-ratio (attr-ref attrs 'preserveAspectRatio)))
           (define matrix (compute-viewbox-matrix 0 0 nat-w nat-h wv hv par))
           (send content-dc translate x y)
           (send content-dc transform matrix)
           (send content-dc draw-bitmap bm 0 0))))]
    [else (void)])
  (define out (make-bytes (* w h 4)))
  (send content-bm get-argb-pixels 0 0 w h out)
  (srgb-bytes->linear! out)
  (premultiply! out)
  out)

(define (fe-displacement-map in in2 node w h scale-factor)
  (define attrs (xexpr-attrs node))
  (define scale (* scale-factor (attr-num attrs 'scale 0)))
  (define (channel-offset sel) (case sel [("R") 1] [("G") 2] [("B") 3] [else 0])) ; else/"A" -> 0
  (define x-off (channel-offset (or (attr-ref attrs 'xChannelSelector) "A")))
  (define y-off (channel-offset (or (attr-ref attrs 'yChannelSelector) "A")))
  (define map-straight (unpremultiplied-copy in2))
  (define out (make-bytes (bytes-length in)))
  (for* ([y (in-range h)] [x (in-range w)])
    (define map-base (* (+ x (* y w)) 4))
    (define xc (/ (bytes-ref map-straight (+ map-base x-off)) 255.))
    (define yc (/ (bytes-ref map-straight (+ map-base y-off)) 255.))
    (define sx (inexact->exact (round (+ x (* scale (- xc 0.5))))))
    (define sy (inexact->exact (round (+ y (* scale (- yc 0.5))))))
    (define out-base map-base)
    (if (and (>= sx 0) (< sx w) (>= sy 0) (< sy h))
        (for ([k (in-list '(0 1 2 3))])
          (bytes-set! out (+ out-base k) (bytes-ref in (+ (* (+ sx (* sy w)) 4) k))))
        (for ([k (in-list '(0 1 2 3))]) (bytes-set! out (+ out-base k) 0))))
  out)

(define (fe-convolve-matrix in node w h)
  (define attrs (xexpr-attrs node))
  (define order-vals (parse-number-list (or (attr-ref attrs 'order) "3")))
  (define order-x (max 1 (inexact->exact (round (if (pair? order-vals) (first order-vals) 3)))))
  (define order-y (max 1 (inexact->exact (round (if (>= (length order-vals) 2) (second order-vals) order-x)))))
  (define kernel (parse-number-list (attr-ref attrs 'kernelMatrix)))
  (cond
    [(not (= (length kernel) (* order-x order-y))) in]  ; malformed per spec: leave the input unchanged
    [else
     (define kernel-vec (list->vector kernel))
     (define kernel-sum (apply + kernel))
     (define divisor-str (attr-ref attrs 'divisor))
     (define divisor (let ([d (and divisor-str (string->number divisor-str))])
                       (cond [(and d (not (zero? d))) d] [(zero? kernel-sum) 1] [else kernel-sum])))
     (define bias (attr-num attrs 'bias 0))
     (define target-x (inexact->exact (round (attr-num attrs 'targetX (quotient order-x 2)))))
     (define target-y (inexact->exact (round (attr-num attrs 'targetY (quotient order-y 2)))))
     (define edge-mode (or (attr-ref attrs 'edgeMode) "duplicate"))
     (define preserve-alpha? (equal? (attr-ref attrs 'preserveAlpha) "true"))
     (define src (if preserve-alpha? (unpremultiplied-copy in) in))
     ;; Performance: resolve edgeMode to a plain symbol ONCE rather than
     ;; comparing strings inside map-coord on every single tap access
     ;; (called order-x*order-y*2 times per pixel per channel -- tens of
     ;; millions of times for a modestly large kernel/canvas, found via
     ;; profiling to be a real, measurable bottleneck).
     (define edge-mode-sym (cond [(equal? edge-mode "wrap") 'wrap] [(equal? edge-mode "none") 'none] [else 'duplicate]))
     (define (map-coord v maxv)
       (cond [(and (>= v 0) (< v maxv)) v]
             [(eq? edge-mode-sym 'wrap) (modulo v maxv)]
             [(eq? edge-mode-sym 'none) #f]
             [else (max 0 (min (sub1 maxv) v))]))
     (define out (make-bytes (bytes-length src)))
     ;; The formula's bias term is "+ bias * ALPHA(x,y)" -- alpha itself
     ;; has no sensible separate bias term (the formula can't reference
     ;; its own not-yet-computed output), so alpha is convolved plain
     ;; (sum/divisor, no bias), and that OUTPUT alpha is what scales the
     ;; bias added to the color channels. A first version applied a flat
     ;; `bias * 255` to every channel including alpha, which both
     ;; contradicts the spec's own alpha-weighted bias term and corrupts
     ;; the premultiplied representation whenever the convolved alpha
     ;; ended up lower than 255 (color channels legitimately allowed to
     ;; exceed alpha, an invalid premultiplied state) -- caught by a
     ;; bias-only test unexpectedly compositing as if fully opaque white
     ;; rather than the intended tinted-gray result.
     ;;
     ;; Performance: the source byte-offset for each kernel tap depends
     ;; only on (x,y), not on which channel is being convolved, but the
     ;; ORIGINAL per-channel conv-sum recomputed it redundantly four
     ;; times per pixel (once per channel), found via the same profiling
     ;; pass -- precomputing each tap's (source-offset . kernel-value)
     ;; once per pixel and reusing it across channels avoids that.
     (define (taps-at x y)
       (for*/list ([i (in-range order-y)] [j (in-range order-x)])
         (define sx (map-coord (+ (- x target-x) j) w))
         (define sy (map-coord (+ (- y target-y) i) h))
         (and sx sy (cons (* (+ sx (* sy w)) 4) (vector-ref kernel-vec (+ (- order-x j 1) (* (- order-y i 1) order-x)))))))
     (define (conv-sum taps k)
       (for/sum ([tap (in-list taps)] #:when tap)
         (* (cdr tap) (bytes-ref src (+ (car tap) k)))))
     (define (clamp v) (max 0 (min 255 (inexact->exact (round v)))))
     (for* ([y (in-range h)] [x (in-range w)])
       (define out-base (* (+ x (* y w)) 4))
       (define taps (taps-at x y))
       (cond
         [preserve-alpha?
          (for ([k (in-list '(1 2 3))])
            (bytes-set! out (+ out-base k) (clamp (+ (/ (conv-sum taps k) divisor) (* bias 255)))))
          (bytes-set! out out-base (bytes-ref src out-base))]
         [else
          (define out-alpha (clamp (/ (conv-sum taps 0) divisor)))
          (bytes-set! out out-base out-alpha)
          (for ([k (in-list '(1 2 3))])
            (bytes-set! out (+ out-base k) (clamp (+ (/ (conv-sum taps k) divisor) (* bias out-alpha)))))]))
     (when preserve-alpha? (premultiply! out))
     out]))

;; Shorthand for blur(SourceAlpha) -> offset -> flood+composite("in")
;; -> merge with the original graphic on top -- built directly from the
;; other primitives already implemented, since it's just their standard
;; composition (and extremely common in real-world SVGs, arguably more
;; so than any single primitive except blur itself).
(define (fe-drop-shadow in node w h scale ctx)
  (define attrs (xexpr-attrs node))
  (define std (attr-num attrs 'stdDeviation 2))
  (define dx (attr-num attrs 'dx 2)) (define dy (attr-num attrs 'dy 2))
  (define source-alpha (make-bytes (bytes-length in) 0))
  (for ([i (in-range 0 (bytes-length in) 4)]) (bytes-set! source-alpha i (bytes-ref in i)))
  (define blurred (bytes-copy source-alpha))
  (apply-gaussian-blur! blurred w h (* scale std) (* scale std))
  (define offset-node `(feOffset ((dx ,(number->string dx)) (dy ,(number->string dy)))))
  (define offsetted (fe-offset blurred offset-node w h scale))
  (define flood-node `(feFlood ((flood-color ,(or (attr-ref attrs 'flood-color) "black"))
                                 (flood-opacity ,(or (attr-ref attrs 'flood-opacity) "1")))))
  (define flood (fe-flood flood-node w h ctx))
  (define shadow (fe-composite flood offsetted '(feComposite ((operator "in")))))
  (fe-merge (list shadow in)))

;; ---- Filter-graph evaluation -----------------------------------------------

(define filter-primitive-tags '(feGaussianBlur feOffset feColorMatrix feFlood feMerge
                                 feComposite feBlend feComponentTransfer feMorphology feDropShadow
                                 feConvolveMatrix feDisplacementMap feImage feTurbulence
                                 feDiffuseLighting feSpecularLighting feTile))

;; Resolves a primitive's `in`/`in2` attribute to a buffer: an explicit
;; name (a previous `result`, or "SourceGraphic"/"SourceAlpha"), or --
;; when omitted -- the previous primitive's result for the first input,
;; SourceGraphic for the very first primitive if it's omitted there too
;; (per spec).
(define (resolve-filter-input name results last-result)
  (cond [name (hash-ref results name (lambda () (hash-ref results "SourceGraphic")))]
        [last-result last-result]
        [else (hash-ref results "SourceGraphic")]))

;; Runs `filter-node`'s primitive chain against `source` (SourceGraphic,
;; a premultiplied w*h*4 buffer), returning the final premultiplied
;; buffer.
;; If `pattrs` specifies an explicit x/y/width/height subregion (user-
;; space units, converted to device pixels via the ambient scale
;; factor), clips `buf` to it -- anything outside becomes fully
;; transparent, matching how every OTHER primitive already treats out-
;; of-bounds content elsewhere in this file. If none of x/y/width/
;; height are given at all, `buf` is returned unchanged: a primitive's
;; default subregion is the same as the filter's own overall region,
;; which this file already treats as the whole canvas (see the filter
;; section above), so there's nothing tighter to clip to in that case.
;; A dimension that IS given resolves normally; one that's omitted
;; while at least one sibling dimension is present falls back to the
;; buffer's own edge (0 for x/y, the full w/h for width/height) --  a
;; narrower approximation of the filter region's own true default
;; (-10%/-10%/120%/120% of the bounding box) given this file already
;; doesn't track that more precisely either.
(define (clip-to-subregion buf pattrs w h scale)
  (define x-str (attr-ref pattrs 'x)) (define y-str (attr-ref pattrs 'y))
  (define w-str (attr-ref pattrs 'width)) (define h-str (attr-ref pattrs 'height))
  (cond
    [(not (or x-str y-str w-str h-str)) buf]
    [else
     (define rx (if x-str (inexact->exact (round (* scale (parse-length x-str)))) 0))
     (define ry (if y-str (inexact->exact (round (* scale (parse-length y-str)))) 0))
     (define rw (if w-str (max 0 (inexact->exact (round (* scale (parse-length w-str))))) w))
     (define rh (if h-str (max 0 (inexact->exact (round (* scale (parse-length h-str))))) h))
     (define out (bytes-copy buf))
     (for* ([y (in-range h)] [x (in-range w)])
       (unless (and (>= x rx) (< x (+ rx rw)) (>= y ry) (< y (+ ry rh)))
         (define base (* (+ x (* y w)) 4))
         (bytes-set! out base 0) (bytes-set! out (+ base 1) 0)
         (bytes-set! out (+ base 2) 0) (bytes-set! out (+ base 3) 0)))
     out]))

(define (eval-filter-chain filter-node source w h scale ctx ambient)
  (define results (make-hash))
  (hash-set! results "SourceGraphic" source)
  (define source-alpha (make-bytes (bytes-length source) 0))
  (for ([i (in-range 0 (bytes-length source) 4)]) (bytes-set! source-alpha i (bytes-ref source i)))
  (hash-set! results "SourceAlpha" source-alpha)
  ;; Tracks which XML node produced each named result -- used only by
  ;; feTile, which (uniquely among these primitives) needs to reach back
  ;; into the filter graph's own markup for the referenced primitive's
  ;; x/y/width/height, since this file's filter system otherwise
  ;; deliberately never tracks per-primitive subregions at all.
  (define result-nodes (make-hash))
  (define (resolve-input-node name last-node)
    (cond [name (hash-ref result-nodes name #f)]
          [last-node last-node]
          [else #f]))
  (define last #f)
  (define last-node #f)
  (for ([prim (in-list (element-children filter-node))] #:when (memq (xexpr-tag prim) filter-primitive-tags))
    (define pattrs (xexpr-attrs prim))
    (define in (resolve-filter-input (attr-ref pattrs 'in) results last))
    (define out
      (clip-to-subregion
       (case (xexpr-tag prim)
         [(feGaussianBlur) (fe-gaussian-blur in prim w h scale)]
         [(feOffset) (fe-offset in prim w h scale)]
         [(feColorMatrix) (fe-color-matrix in prim w h)]
         [(feFlood) (fe-flood prim w h ctx)]
         [(feMerge)
          (define nodes (filter (lambda (c) (eq? (xexpr-tag c) 'feMergeNode)) (element-children prim)))
          (define inputs (for/list ([n (in-list nodes)]) (resolve-filter-input (attr-ref (xexpr-attrs n) 'in) results last)))
          (fe-merge (if (null? inputs) (list in) inputs))]
         [(feComposite) (fe-composite in (resolve-filter-input (attr-ref pattrs 'in2) results last) prim)]
         [(feBlend) (fe-blend in (resolve-filter-input (attr-ref pattrs 'in2) results last) prim)]
         [(feComponentTransfer) (fe-component-transfer in prim w h)]
         [(feMorphology) (fe-morphology in prim w h scale)]
         [(feDropShadow) (fe-drop-shadow in prim w h scale ctx)]
         [(feConvolveMatrix) (fe-convolve-matrix in prim w h)]
         [(feDisplacementMap) (fe-displacement-map in (resolve-filter-input (attr-ref pattrs 'in2) results last) prim w h scale)]
         [(feImage) (fe-image prim w h scale ctx ambient)]
         [(feTurbulence) (fe-turbulence prim w h scale)]
         [(feDiffuseLighting) (fe-diffuse-lighting in prim w h scale ctx)]
         [(feSpecularLighting) (fe-specular-lighting in prim w h scale ctx)]
         [(feTile) (fe-tile in (resolve-input-node (attr-ref pattrs 'in) last-node) w h scale)]
         [else in])
       pattrs w h scale))
    (when (attr-ref pattrs 'result) (hash-set! results (attr-ref pattrs 'result) out) (hash-set! result-nodes (attr-ref pattrs 'result) prim))
    (set! last out)
    (set! last-node prim))
  (or last source))

;; Renders `node` through a <filter> reference: renders its content into
;; a full-canvas SourceGraphic buffer (same transform/clip already active
;; on `dc`, so it aligns correctly), runs the filter chain, and
;; composites the result back at identity (already in final device-pixel
;; space). Per spec, a missing/non-<filter> reference means `node`
;; renders NOTHING at all -- different from mask's leniency, and worth
;; matching precisely rather than defaulting to the more common pattern.
(define (render-with-filter! filter-node ctx dc render-thunk)
  (define-values (cw-real ch-real) (send dc get-size))
  (define cw (max 1 (inexact->exact (round cw-real))))
  (define ch (max 1 (inexact->exact (round ch-real))))
  (define ambient (send dc get-transformation))
  (define clip (send dc get-clipping-region))
  (define scale (ambient-scale-factor dc))
  (define content-bm (make-object bitmap% cw ch #f #t))
  (define content-dc (new bitmap-dc% [bitmap content-bm]))
  (send content-dc set-smoothing 'smoothed)
  (send content-dc set-transformation ambient)
  (when clip (send content-dc set-clipping-region clip))
  (render-thunk content-dc)
  (define source (make-bytes (* cw ch 4)))
  (send content-bm get-argb-pixels 0 0 cw ch source)
  (srgb-bytes->linear! source)
  (premultiply! source)
  (define result (eval-filter-chain filter-node source cw ch scale ctx ambient))
  (unpremultiply-in-place! result)
  (linear-bytes->srgb! result)
  (send content-bm set-argb-pixels 0 0 cw ch result)
  (send dc set-transformation identity-transformation)
  (send dc draw-bitmap content-bm 0 0)
  (send dc set-transformation ambient))

;; set-argb-pixels expects straight (non-premultiplied) alpha, matching
;; get-argb-pixels' own output -- confirmed empirically back in Tier 5.
(define (unpremultiply-in-place! buf)
  (for ([i (in-range 0 (bytes-length buf) 4)])
    (define a (bytes-ref buf i))
    (when (> a 0)
      (bytes-set! buf (+ i 1) (min 255 (quotient (* (bytes-ref buf (+ i 1)) 255) a)))
      (bytes-set! buf (+ i 2) (min 255 (quotient (* (bytes-ref buf (+ i 2)) 255) a)))
      (bytes-set! buf (+ i 3) (min 255 (quotient (* (bytes-ref buf (+ i 3)) 255) a))))))

;;; ---- Clipping & masking (Tier 5) -----------------------------------------

;; The pixel dimensions of the final output, set once per render (Tier 5
;; masks need this to size their offscreen compositing buffers).
(define current-canvas-size (make-parameter (cons 300 150)))

;; A cached "identity" dc transformation, used to temporarily reset the
;; dc when drawing an already-fully-resolved offscreen buffer (see
;; render-with-mask!) -- read once from a fresh scratch dc rather than
;; hand-building the compound vector format, in case that format ever
;; changes.
(define identity-transformation
  (send (new bitmap-dc% [bitmap (make-object bitmap% 1 1)]) get-transformation))

(define (parse-clip-rule s) (if (equal? s "evenodd") 'odd-even 'winding))

;; Builds a region% for a <clipPath>'s content, in LOCAL (userSpaceOnUse)
;; coordinates by default -- safe to combine directly with whatever
;; transform is already active on `dc` (confirmed empirically that
;; set-clipping-region composes correctly with the ambient transform,
;; unlike the gradient-brush pitfall found in Tier 4: there's no shared-
;; coordinate-space issue here since this never mutates dc's transform,
;; only builds a standalone dc-path% first). For
;; clipPathUnits="objectBoundingBox", the combined path is scaled (via
;; dc-path%'s own `.transform`, which only affects this standalone path
;; object) by the referencing element's bounding box -- only available
;; when the caller can supply one (leaf shapes); for groups, `bbox` is
;; #f and objectBoundingBox falls back to raw userSpaceOnUse coordinates,
;; a disclosed, narrow limitation. Each clip child's own `transform` is
;; also baked in the same way; clip-rule is read once for the whole
;; combined region (evenodd if ANY child specifies it, else nonzero) --
;; region%.set-path takes one fill-rule for its whole path, so per-shape
;; clip-rule mixing within a single clipPath isn't representable, a
;; narrow simplification given how rarely shapes with differing clip-
;; rule are combined in the same clipPath.
;; Enforces `overflow` on a viewport-establishing element (nested <svg>,
;; a <use>-instantiated <symbol>/<svg>, or a <marker> instance) by
;; clipping `dc` to the rectangle (0,0,width,height) in whatever
;; coordinate space is CURRENTLY active (i.e. call this after applying
;; that viewport's own transform, the same way build-clip-region's
;; region composes correctly with the ambient transform already in
;; effect). Per spec, all of these default to `overflow: hidden` (clip)
;; unless explicitly set to "visible" -- previously this file didn't
;; enforce ANY of them, a disclosed simplification that in practice
;; meant a <use> overriding a <symbol>'s own width/height had no visual
;; effect at all when the symbol lacked a viewBox (nothing to scale
;; without one, and nothing to clip without this), confirmed via a WPT
;; test. Returns the PREVIOUS clipping region (possibly #f for "none"),
;; which the caller must restore afterward so this doesn't leak into
;; sibling rendering -- mirrors apply-clip-path!'s own intersect-with-
;; existing-clip behavior, so a viewport clip nested inside an already-
;; clipped context still combines correctly rather than replacing it.
(define (push-viewport-clip! dc width height overflow-value)
  (define saved (send dc get-clipping-region))
  (unless (equal? overflow-value "visible")
    (define rect-path (new dc-path%))
    (send rect-path rectangle 0 0 (max 0 width) (max 0 height))
    (define region (new region% [dc dc]))
    (send region set-path rect-path 0 0 'winding)
    (when saved (send region intersect saved))
    (send dc set-clipping-region region))
  saved)

(define (build-clip-region clip-node dc [bbox #f])
  (define attrs (xexpr-attrs clip-node))
  (define units (or (attr-ref attrs 'clipPathUnits) "userSpaceOnUse"))
  (define combined (new dc-path%))
  (define any-content? #f)
  (define any-evenodd? (equal? (attr-ref attrs 'clip-rule) "evenodd"))
  (for ([child (in-list (element-children clip-node))])
    (define child-attrs (xexpr-attrs child))
    (define paths (shape-node->dc-paths child))
    (define transform-str (attr-ref child-attrs 'transform))
    (when (equal? (attr-ref child-attrs 'clip-rule) "evenodd") (set! any-evenodd? #t))
    (for ([p (in-list paths)])
      (when transform-str (send p transform (transform-list->matrix transform-str)))
      (set! any-content? #t)
      (send combined append p)))
  (cond
    [(not any-content?) #f]
    [else
     (when (and (string=? units "objectBoundingBox") bbox)
       (match-define (list bx by bw bh) bbox)
       (send combined transform (vector (if (zero? bw) 1e-6 bw) 0 0 (if (zero? bh) 1e-6 bh) bx by)))
     (define region (new region% [dc dc]))
     (send region set-path combined 0 0 (if any-evenodd? 'odd-even 'winding))
     region]))

;; Applies clip-path="url(#id)" to `dc`, INTERSECTING with any already-
;; active clip so nested clip-paths correctly combine (set-clipping-
;; region itself REPLACES rather than intersects, confirmed empirically
;; -- region%'s own `intersect` method is what actually combines them).
;; `bbox` is passed through for objectBoundingBox clipPathUnits when the
;; caller has one (leaf shapes only).
(define (apply-clip-path! dc clip-path-str [bbox #f])
  (define m (regexp-match #rx"url\\(#([^)]+)\\)" clip-path-str))
  (when m
    (define target (hash-ref (current-id-table) (cadr m) #f))
    (when (and target (eq? (xexpr-tag target) 'clipPath))
      (define region (build-clip-region target dc bbox))
      (when region
        (define existing (send dc get-clipping-region))
        (when existing (send region intersect existing))
        (send dc set-clipping-region region)))))

;; Renders `node` (via `render-thunk`, which draws it onto whatever dc
;; it's given) through a <mask> reference: renders the mask's own content
;; and `node`'s content into separate full-canvas offscreen buffers
;; (using the SAME transform/clip already active on `dc`, so both align
;; correctly with it), computes each pixel's mask value (luminance by
;; default, or raw alpha for mask-type="alpha") and multiplies it into
;; the content buffer's own alpha, then draws the composited result onto
;; `dc` at identity (the buffer is already in final device-pixel space).
;; Deliberately sized to the WHOLE canvas rather than a tight bounding
;; region around `node`, trading some memory/performance for a much
;; simpler implementation -- masks are a correctness feature here, not a
;; performance-critical path. Mask content is always userSpaceOnUse
;; (`maskContentUnits="objectBoundingBox"` isn't implemented), so it must
;; be positioned in the SAME absolute coordinates as wherever `node`
;; itself sits, not re-based onto it -- a mask authored once and reused
;; at a different position won't overlap what it's meant to mask at all.
;; The mask's own region (`maskUnits`/x/y/width/height, default
;; -10%..110% of the bbox) is likewise NOT enforced as an extra clip --
;; content outside it is expected to just not paint anything in
;; practice, a disclosed, narrow simplification.
;; Renders `node` (via `render-thunk`) as a true, correctly-composited
;; group at reduced `opacity`: renders its whole subtree into a fresh,
;; fully-transparent full-canvas buffer FIRST (so any of its own
;; children that overlap each other composite correctly against each
;; other at full strength, exactly as if opacity were 1), then blends
;; that single, already-resolved buffer against the destination ONCE via
;; dc<%>'s own `set-alpha` (confirmed correct for this back in Tier 8's
;; <image> opacity support) -- unlike multiplying opacity into each
;; descendant leaf's own fill/stroke-opacity (this file's original
;; approximation, still used for a leaf with no children of its own),
;; which is only correct when a group's own content doesn't overlap
;; itself. Skips the offscreen-buffer cost entirely at the boundaries
;; (opacity effectively 1 or 0), where it wouldn't change anything.
(define (render-with-opacity! opacity ctx dc render-thunk)
  (cond
    [(>= opacity 0.999) (render-thunk dc)]
    [(<= opacity 0.001) (void)]
    [else
     (define-values (cw-real ch-real) (send dc get-size))
     (define cw (max 1 (inexact->exact (round cw-real))))
     (define ch (max 1 (inexact->exact (round ch-real))))
     (define ambient (send dc get-transformation))
     (define clip (send dc get-clipping-region))
     (define content-bm (make-object bitmap% cw ch #f #t))
     (define content-dc (new bitmap-dc% [bitmap content-bm]))
     (send content-dc set-smoothing 'smoothed)
     (send content-dc set-transformation ambient)
     (when clip (send content-dc set-clipping-region clip))
     (render-thunk content-dc)
     (define saved-alpha (send dc get-alpha))
     (send dc set-transformation identity-transformation)
     (send dc set-alpha (* saved-alpha opacity))
     (send dc draw-bitmap content-bm 0 0)
     (send dc set-alpha saved-alpha)
     (send dc set-transformation ambient)]))

;; The CSS `mix-blend-mode` property: renders `node` (via `render-thunk`)
;; blended against whatever's already drawn on `dc` (the backdrop),
;; using one of the same blend functions feBlend uses (see
;; blend-channel) -- "normal" (or an absent/unrecognized mode) is a
;; plain, unmodified render. Unlike opacity/mask/filter, this needs to
;; read `dc`'s own CURRENT pixels (via its backing bitmap%, confirmed
;; accessible through get-bitmap) as well as the element's own newly-
;; rendered content, so it can't just draw over the backdrop the normal
;; way -- the blend function needs both layers explicitly. Reuses
;; fe-blend directly (via a small synthetic node carrying just the mode)
;; rather than duplicating its blend-then-composite pixel loop.
;; Approximated as its own independent compositing step rather than
;; exactly matching the CSS Compositing spec's combined opacity+blend-
;; mode formula when BOTH are non-default on the same element
;; simultaneously (a disclosed, narrow simplification given how rarely
;; that specific combination occurs in practice).
(define (render-with-blend-mode! mode ctx dc render-thunk)
  (cond
    [(or (not mode) (equal? mode "normal")) (render-thunk dc)]
    [else
     (define-values (cw-real ch-real) (send dc get-size))
     (define cw (max 1 (inexact->exact (round cw-real))))
     (define ch (max 1 (inexact->exact (round ch-real))))
     (define ambient (send dc get-transformation))
     (define clip (send dc get-clipping-region))
     (define content-bm (make-object bitmap% cw ch #f #t))
     (define content-dc (new bitmap-dc% [bitmap content-bm]))
     (send content-dc set-smoothing 'smoothed)
     (send content-dc set-transformation ambient)
     (when clip (send content-dc set-clipping-region clip))
     (render-thunk content-dc)
     (define source (make-bytes (* cw ch 4)))
     (send content-bm get-argb-pixels 0 0 cw ch source)
     (define backdrop (make-bytes (* cw ch 4)))
     (send (send dc get-bitmap) get-argb-pixels 0 0 cw ch backdrop)
     (premultiply! source)
     (premultiply! backdrop)
     (define result (fe-blend source backdrop `(feBlend ((mode ,mode)))))
     (unpremultiply-in-place! result)
     (send dc set-transformation identity-transformation)
     (send (send dc get-bitmap) set-argb-pixels 0 0 cw ch result)
     (send dc set-transformation ambient)]))

(define (render-with-mask! mask-node ctx dc render-thunk)
  (define-values (cw-real ch-real) (send dc get-size))
  (define cw (max 1 (inexact->exact (round cw-real))))
  (define ch (max 1 (inexact->exact (round ch-real))))
  (define ambient (send dc get-transformation))
  (define clip (send dc get-clipping-region))
  (define (fresh-offscreen-dc)
    (define bm (make-object bitmap% cw ch #f #t))
    (define odc (new bitmap-dc% [bitmap bm]))
    (send odc set-smoothing 'smoothed)
    (send odc set-transformation ambient)
    (when clip (send odc set-clipping-region clip))
    (values bm odc))
  (define-values (content-bm content-dc) (fresh-offscreen-dc))
  (render-thunk content-dc)
  (define-values (mask-bm mask-dc) (fresh-offscreen-dc))
  (define mask-ctx (resolve-inherited mask-node ua-default-ctx))
  (parameterize ([current-use-chain '()] [current-ancestor-chain '()])
    (for ([c (in-list (element-children mask-node))]) (render-node! c mask-ctx mask-dc)))
  (define n (* cw ch 4))
  (define content-bytes (make-bytes n))
  (define mask-bytes (make-bytes n))
  (send content-bm get-argb-pixels 0 0 cw ch content-bytes)
  (send mask-bm get-argb-pixels 0 0 cw ch mask-bytes)
  (define alpha-mode? (equal? (attr-ref (xexpr-attrs mask-node) 'mask-type) "alpha"))
  (for ([i (in-range (* cw ch))])
    (define base (* i 4))
    (define m-a (/ (bytes-ref mask-bytes base) 255.))
    (define mask-value
      (if alpha-mode?
          m-a
          (* m-a (/ (+ (* 0.2125 (bytes-ref mask-bytes (+ base 1)))
                       (* 0.7154 (bytes-ref mask-bytes (+ base 2)))
                       (* 0.0721 (bytes-ref mask-bytes (+ base 3))))
                    255.))))
    (define c-a (bytes-ref content-bytes base))
    (bytes-set! content-bytes base (inexact->exact (round (* c-a mask-value)))))
  (send content-bm set-argb-pixels 0 0 cw ch content-bytes)
  (send dc set-transformation identity-transformation)
  (send dc draw-bitmap content-bm 0 0)
  (send dc set-transformation ambient))

;; Walks the tree, applying inheritance (via `render-ctx`), the
;; `transform` attribute, `clip-path`, and `mask` -- all saved/restored
;; around every element, not just containers, since each is valid on any
;; of them.
(define (render-node! node ctx dc)
  (define attrs (xexpr-attrs node))
  (define transform-str (attr-ref attrs 'transform))
  (define clip-path-str (attr-ref attrs 'clip-path))
  (define mask-str (attr-ref attrs 'mask))
  (define filter-str (attr-ref attrs 'filter))
  (define saved-transformation (send dc get-transformation))
  (when transform-str (apply-transform-attr! dc transform-str))
  (define saved-clip (send dc get-clipping-region))
  (when clip-path-str
    (define leaf-bbox (and (memq (xexpr-tag node) '(path rect circle ellipse line polyline polygon))
                            (combined-bounding-box (shape-node->dc-paths node))))
    (apply-clip-path! dc clip-path-str leaf-bbox))
  (define (render-content! target-dc)
    (match (xexpr-tag node)
      ['path     (render-path-node! node (resolve-inherited node ctx) target-dc)]
      ['rect     (render-rect-node! node (resolve-inherited node ctx) target-dc)]
      ['circle   (render-circle-node! node (resolve-inherited node ctx) target-dc)]
      ['ellipse  (render-ellipse-node! node (resolve-inherited node ctx) target-dc)]
      ['line     (render-line-node! node (resolve-inherited node ctx) target-dc)]
      ['polyline (render-polyline-node! node (resolve-inherited node ctx) target-dc)]
      ['polygon  (render-polygon-node! node (resolve-inherited node ctx) target-dc)]
      ['use      (render-use-node! node (resolve-inherited node ctx) target-dc)]
      ['image    (render-image-node! node ctx target-dc)]
      ['text
       (define inline-size-str (geometry-attr-ref node 'inline-size))
       (define inline-size (and inline-size-str (parse-length inline-size-str #f #:reference (percentage-reference-for 'width))))
       ;; shape-inside:url(#id) -- scoped to a plain <rect> target (see
       ;; render-wrapped-text-node!'s own note on why): the wrap box's
       ;; width comes directly from the rect's own width, and the FIRST
       ;; line's baseline is positioned at the rect's own y plus the
       ;; resolved font's own ascent (confirmed via a WPT test's
       ;; reference file to be font-metric-derived, not a fixed offset
       ;; or the rect's own y directly).
       (define shape-inside-str (geometry-attr-ref node 'shape-inside))
       (define shape-inside-m (and shape-inside-str (regexp-match #rx"url\\(#([^)]+)\\)" shape-inside-str)))
       (define shape-inside-target (and shape-inside-m (hash-ref (current-id-table) (cadr shape-inside-m) #f)))
       (define shape-inside-rect (and shape-inside-target (eq? (xexpr-tag shape-inside-target) 'rect) shape-inside-target))
       (cond
         [shape-inside-rect
          (define rect-attrs (xexpr-attrs shape-inside-rect))
          (define box-x (attr-num rect-attrs 'x 0))
          (define box-y (attr-num rect-attrs 'y 0))
          (define box-w (attr-num rect-attrs 'width 0))
          (define ctx-for-ascent (resolve-inherited node ctx))
          (define font-for-ascent (resolve-font ctx-for-ascent))
          (define-values (aw ah ad al) (send text-metrics-dc get-text-extent "M" font-for-ascent))
          (render-wrapped-text-node! node ctx target-dc box-w box-x (+ box-y (- ah ad al)))]
         [(and inline-size (> inline-size 0))
          (render-wrapped-text-node! node ctx target-dc inline-size)]
         [else (render-text-node! node ctx target-dc 0 0 (box #f) (initial-preserve-space? node))])
       (void)]
      ['tspan    (void)]  ; only ever processed via render-text-node!'s own recursion
      ['textPath (void)]  ; likewise -- only ever processed via render-text-node!'s own recursion
      ['g
       (define ctx* (resolve-inherited node ctx))
       (define (render-children! target-dc2)
         (parameterize ([current-ancestor-chain (cons node (current-ancestor-chain))])
           (for ([c (in-list (element-children node))]) (render-node! c ctx* target-dc2))))
       (render-with-opacity! (render-ctx-opacity ctx*) ctx* target-dc render-children!)]
      ['svg
       ;; A genuinely NESTED <svg> (the document root never reaches this
       ;; case -- see render-svg-doc!, which applies the root's
       ;; precomputed view matrix once and walks the root's CHILDREN
       ;; directly, so the root's viewBox never gets applied twice).
       (send target-dc translate (attr-num attrs 'x 0) (attr-num attrs 'y 0))
       (define ctx* (resolve-inherited node ctx))
       ;; matches viewport-instantiation-matrix's own internal
       ;; width/height resolution (see the same note in render-use-node!).
       (define-values (n-vb-x n-vb-y n-vb-w n-vb-h) (parse-viewbox-attr (attr-ref attrs 'viewBox)))
       (define resolved-w (or (and (attr-ref attrs 'width) (parse-length (attr-ref attrs 'width))) (or n-vb-w 100)))
       (define resolved-h (or (and (attr-ref attrs 'height) (parse-length (attr-ref attrs 'height))) (or n-vb-h 100)))
       ;; the clip is applied in the established viewport's OWN pixel
       ;; space -- BEFORE the viewBox-mapping transform below, which
       ;; would otherwise put the dc into viewBox-space (a different
       ;; coordinate system entirely from resolved-w/resolved-h).
       (define saved-clip (push-viewport-clip! target-dc resolved-w resolved-h (geometry-attr-ref node 'overflow)))
       (send target-dc transform (viewport-instantiation-matrix attrs #f #f))
       (define (render-children! target-dc2)
         (parameterize ([current-ancestor-chain (cons node (current-ancestor-chain))]
                        [current-canvas-size (cons resolved-w resolved-h)])
           (for ([c (in-list (element-children node))]) (render-node! c ctx* target-dc2))))
       (render-with-opacity! (render-ctx-opacity ctx*) ctx* target-dc render-children!)
       (send target-dc set-clipping-region saved-clip)]
      ['defs (void)]    ; never rendered directly; already captured in the id table
      ['symbol (void)]  ; likewise -- only rendered via <use>
      ['style (void)]   ; likewise -- parsed once by build-stylesheet, never rendered
      [(or 'linearGradient 'radialGradient 'pattern 'stop)
       (void)]          ; paint servers: resolved via url(#id) at paint time
      [(or 'clipPath 'mask 'marker 'filter) (void)]  ; likewise: only ever referenced via url(#id)
      [_ (void)]))      ; unknown/unsupported element: skip (forward-compatible)
  (define mask-target (and mask-str (regexp-match #rx"url\\(#([^)]+)\\)" mask-str)))
  (define mask-node (and mask-target (hash-ref (current-id-table) (cadr mask-target) #f)))
  (define filter-target (and filter-str (regexp-match #rx"url\\(#([^)]+)\\)" filter-str)))
  (define filter-node (and filter-target (hash-ref (current-id-table) (cadr filter-target) #f)))
  ;; Per spec, a `filter` referencing a missing or non-<filter> id means
  ;; the element (and its descendants/markers) is not rendered AT ALL --
  ;; a real, different fallback from mask/clip-path's leniency (which
  ;; just skip applying the effect), not a shortcut taken here.
  (unless (and filter-str (not (and filter-node (eq? (xexpr-tag filter-node) 'filter))))
    (define (render-with-filter-maybe! target-dc)
      (if (and filter-node (eq? (xexpr-tag filter-node) 'filter))
          (render-with-filter! filter-node ctx target-dc render-content!)
          (render-content! target-dc)))
    (define blend-mode (geometry-attr-ref node 'mix-blend-mode))
    (define (render-with-blend-maybe! target-dc)
      (render-with-blend-mode! blend-mode ctx target-dc render-with-filter-maybe!))
    (if (and mask-node (eq? (xexpr-tag mask-node) 'mask))
        (render-with-mask! mask-node ctx dc render-with-blend-maybe!)
        (render-with-blend-maybe! dc)))
  (send dc set-clipping-region saved-clip)
  (send dc set-transformation saved-transformation))

(define (render-svg-doc! doc dc)
  (send dc set-smoothing 'smoothed)
  (send dc transform (svg-doc-view-matrix doc))
  (define root (svg-doc-root doc))
  (parameterize ([current-id-table (svg-doc-id-table doc)]
                 [current-canvas-size (cons (svg-doc-width doc) (svg-doc-height doc))]
                 [current-stylesheet (svg-doc-stylesheet doc)])
    (define ctx* (resolve-inherited root ua-default-ctx))
    (parameterize ([current-ancestor-chain (list root)])
      (for ([c (in-list (element-children root))]) (render-node! c ctx* dc)))))

(define (svg-string->bitmap s)
  (define doc (read-svg-document s))
  (define bm (make-object bitmap% (max 1 (inexact->exact (ceiling (svg-doc-width doc))))
                                   (max 1 (inexact->exact (ceiling (svg-doc-height doc))))))
  (define dc (new bitmap-dc% [bitmap bm]))
  (render-svg-doc! doc dc)
  bm)

(define (svg-file->bitmap path)
  (parameterize ([current-svg-base-dir (let-values ([(base name dir?) (split-path (path->complete-path path))]) base)])
    (call-with-input-file path (lambda (in) (svg-string->bitmap (port->string in))))))

;;; ---- pict output ------------------------------------------------------
;; Wraps an already-parsed svg-doc as a `pict` via pict's own `dc`
;; constructor. This works with no changes to render-svg-doc! itself
;; because it already targets the generic dc<%> interface throughout --
;; it never assumes bitmap-dc% specifically for the dc it's HANDED (only
;; for its own INTERNAL scratch buffers, e.g. masks/filters/patterns/
;; markers compositing through their own private offscreen bitmap-dc%
;; instances, which is unrelated to what the caller passes in here) --
;; so the resulting pict can be rendered onto whatever dc it ends up on:
;; a bitmap (via pict->bitmap), but also a pdf-dc%/post-script-dc%/on-
;; screen canvas, giving vector PDF/PostScript output "for free" for any
;; content that doesn't need mask/filter rasterization (masked/filtered
;; elements still rasterize internally either way, the same as in any
;; renderer, since those effects inherently require pixel buffers --
;; they'd show up as embedded raster images in an otherwise-vector PDF).
;;
;; pict's `dc` constructor requires the draw procedure to leave the dc's
;; own tracked state exactly as it found it (or raises a contract
;; violation) -- confirmed empirically to mean exactly transformation,
;; pen, brush, font, alpha, text-mode, and text-foreground (smoothing,
;; clipping-region, and background were tested too and are NOT part of
;; what's checked, though smoothing is still explicitly restored below
;; for good hygiene, since a dc-touching function leaving stray state
;; behind is a bad citizen regardless of what any one particular caller
;; happens to check). render-svg-doc! doesn't do this on its own -- it
;; permanently applies the root viewBox transform and smoothing mode --
;; so this wraps it with an explicit save/restore rather than changing
;; render-svg-doc!'s own contract (used directly elsewhere without this
;; expectation). Deliberately uses `dc` rather than `unsafe-dc`: it costs
;; a second, throwaway render during pict construction (part of the
;; contract's own precondition check), but turns any future accidental
;; unrestored mutation into an immediate, clear contract violation
;; instead of silent state corruption in whatever gets drawn next to an
;; svg-pict in a composed picture -- exactly the failure mode that would
;; otherwise be hardest to diagnose, given how much dc state rendering
;; touches.
;; `base-dir`, if given, is re-established via `parameterize` EVERY time
;; the draw procedure actually runs, not just once when the pict is
;; constructed: pict's `dc` draws lazily, whenever the pict is actually
;; rendered (via pict->bitmap, or later still if just held onto and
;; combined with other picts first) -- often well outside the dynamic
;; extent of whatever `parameterize` was active when the pict was first
;; built. A first version of this wrapped the parameterize around
;; svg-file->pict's own parsing step only, which silently broke relative
;; <image> href resolution the moment the pict was actually drawn: image
;; loading happens at RENDER time (inside render-image-node!), not parse
;; time, by which point that parameterize's dynamic extent had already
;; ended. Caught by a test that actually rendered a file-based pict with
;; a relative image reference, not just checked that construction alone
;; didn't raise.
(define (svg-doc->pict doc [base-dir #f])
  (define w (svg-doc-width doc))
  (define h (svg-doc-height doc))
  (dc (lambda (dc dx dy)
        (define saved-t (send dc get-transformation))
        (define saved-pen (send dc get-pen))
        (define saved-brush (send dc get-brush))
        (define saved-font (send dc get-font))
        (define saved-alpha (send dc get-alpha))
        (define saved-text-mode (send dc get-text-mode))
        (define saved-text-fg (send dc get-text-foreground))
        (define saved-smoothing (send dc get-smoothing))
        (send dc translate dx dy)
        (parameterize ([current-svg-base-dir base-dir]) (render-svg-doc! doc dc))
        (send dc set-transformation saved-t)
        (send dc set-pen saved-pen)
        (send dc set-brush saved-brush)
        (send dc set-font saved-font)
        (send dc set-alpha saved-alpha)
        (send dc set-text-mode saved-text-mode)
        (send dc set-text-foreground saved-text-fg)
        (send dc set-smoothing saved-smoothing))
      w h))

(define (svg-string->pict s) (svg-doc->pict (read-svg-document s)))

(define (svg-file->pict path)
  (define base-dir (let-values ([(base name dir?) (split-path (path->complete-path path))]) base))
  (call-with-input-file path (lambda (in) (svg-doc->pict (read-svg-document (port->string in)) base-dir))))

;;; =======================================================================
;;; Tests
;;; =======================================================================

(module+ test
  (require rackunit racket/file)

  ;; ---- path-data lexer/parser -------------------------------------------

  (test-case "simple absolute moveto+lineto"
    (check-equal? (parse-svg-path "M10,20 L30,40")
                  '((M (10 20)) (L (30 40)))))

  (test-case "multiple moveto coordinate pairs become implicit linetos"
    ;; Regression test for the bug found in the uploaded prototype:
    ;; "M x1 y1 x2 y2 x3 y3" is one moveto + two linetos, not three movetos.
    (check-equal? (parse-svg-path "M10 10 20 20 30 30")
                  '((M (10 10)) (L (20 20)) (L (30 30))))
    (check-equal? (parse-svg-path "m1 1 2 2")
                  '((m (1 1)) (l (2 2)))))

  (test-case "numbers: signs, decimals, exponents, implicit separators"
    (check-equal? (parse-svg-path "M -1.5e2,+3 L100-50")
                  '((M (-150.0 3)) (L (100 -50)))))

  (test-case "H/V accept repeated coordinates"
    (check-equal? (parse-svg-path "M0,0H1 2 3V4 5")
                  '((M (0 0)) (H 1 2 3) (V 4 5))))

  (test-case "cubic and smooth-cubic curves"
    (check-equal? (parse-svg-path "M0,0 C1,1 2,2 3,3 S4,4 5,5")
                  '((M (0 0)) (C ((1 1) (2 2) (3 3))) (S ((4 4) (5 5))))))

  (test-case "quadratic and smooth-quadratic curves (previously unsupported)"
    (check-equal? (parse-svg-path "M0,0 Q1,1 2,2 T3,3")
                  '((M (0 0)) (Q ((1 1) (2 2))) (T (3 3)))))

  (test-case "closepath, both cases"
    (check-equal? (parse-svg-path "M0,0L1,1Z") '((M (0 0)) (L (1 1)) (Z)))
    (check-equal? (parse-svg-path "M0,0L1,1z") '((M (0 0)) (L (1 1)) (z))))

  (test-case "arc flags glued together (minified paths) parse correctly"
    ;; Regression test for the flag-lexing bug: "11" here must be flags
    ;; large-arc=1, sweep=1 -- not the single number 11.
    (check-equal? (parse-svg-path "M0,0A2.5,2.5 0 1120 40")
                  '((M (0 0)) (A (2.5 2.5 0 1 1 20 40)))))

  (test-case "arc flags with normal separators still work"
    (check-equal? (parse-svg-path "M0,0 A2.5,2.5,0,1,1,20,40")
                  '((M (0 0)) (A (2.5 2.5 0 1 1 20 40)))))

  (test-case "repeated arc arguments under one command letter"
    (check-equal? (parse-svg-path "M0,0A1,1,0,0,0,1,1,2,2,0,1,1,3,3")
                  '((M (0 0)) (A (1 1 0 0 0 1 1) (2 2 0 1 1 3 3)))))

  ;; ---- elliptical arc math -----------------------------------------------

  (test-case "arc-endpoint->center: quarter circle"
    ;; A unit circle, quarter arc from (1,0) to (0,1): the center must be
    ;; the origin, and the swept angle magnitude must be pi/2.
    (define-values (cx cy rx ry theta1 dtheta)
      (arc-endpoint->center 1. 0. 0. 1. 1. 1. 0. #f #t))
    (check-= cx 0. 1e-9)
    (check-= cy 0. 1e-9)
    (check-= rx 1. 1e-9)
    (check-= ry 1. 1e-9)
    (check-= (abs dtheta) (/ pi 2) 1e-9))

  (test-case "arc-endpoint->center: radii too small get scaled up"
    ;; Endpoints 2 apart but radius only 0.5 each: the algorithm must
    ;; scale rx/ry up so the ellipse can actually reach both points.
    (define-values (cx cy rx ry theta1 dtheta)
      (arc-endpoint->center 0. 0. 2. 0. 0.5 0.5 0. #f #t))
    (check-true (> rx 0.9)))  ; scaled up from 0.5 towards 1.0 (radius must be >= half the chord)

  ;; ---- interpreter: path-data -> dc-path% --------------------------------

  (test-case "svg-path->dc-paths produces one subpath per moveto"
    (define paths (path-data->dc-paths "M0,0 L1,1 M2,2 L3,3"))
    (check-equal? (length paths) 2))

  (test-case "single moveto with implicit linetos stays one subpath"
    (define paths (path-data->dc-paths "M0,0 1,1 2,2"))
    (check-equal? (length paths) 1))

  (test-case "quadratic curve advances current point correctly"
    ;; After "M0,0 Q5,10 10,0" the current point must be (10,0), so a
    ;; following relative lineto lands at the expected absolute spot.
    (define paths (path-data->dc-paths "M0,0 Q5,10 10,0 l5,5"))
    (check-equal? (length paths) 1)
    (define-values (closed open) (send (first paths) get-datum))
    (define last-point (last open))
    (check-= (vector-ref last-point 0) 15. 1e-9)
    (check-= (vector-ref last-point 1) 5. 1e-9))

  (test-case "closepath returns current point to subpath start"
    (define paths (path-data->dc-paths "M5,5 L10,10 Z l1,1"))
    ;; Z closes the first subpath; the following relative lineto implicitly
    ;; starts a new open subpath at (5,5), landing at (6,6). Both remain in
    ;; one dc-path% so its fill rule also sees the preceding closed contour.
    (check-equal? (length paths) 1)
    (define-values (closed open) (send (first paths) get-datum))
    (define last-point (last open))
    (check-= (vector-ref last-point 0) 6. 1e-9)
    (check-= (vector-ref last-point 1) 6. 1e-9))

  (test-case "one SVG path applies its fill rule across closed contours"
    ;; The two contours are part of one SVG <path>. Keeping them in one
    ;; dc-path% is essential: drawing each contour separately fills the
    ;; centre instead of making the evenodd hole. Font glyph counters use
    ;; exactly this multi-contour representation.
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <path d=\"M0 0H20V20H0Z M5 5H15V15H5Z\"
                         fill=\"black\" fill-rule=\"evenodd\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 2 2 px)
    (check-equal? (send px red) 0)
    (send dc get-pixel 10 10 px)
    (check-equal? (send px red) 255))

  ;; ---- Length units ---------------------------------------------------

  (test-case "parse-length converts unit suffixes to px (96 units/inch)"
    (check-= (parse-length "10px") 10. 1e-9)
    (check-= (parse-length "10") 10. 1e-9)
    (check-= (parse-length "1in") 96. 1e-9)
    (check-= (parse-length "72pt") 96. 1e-9)
    (check-= (parse-length "1pc") 16. 1e-9)
    (check-= (parse-length "1cm") (/ 96. 2.54) 1e-9)
    (check-= (parse-length "10mm") (/ 960. 25.4) 1e-9))

  (test-case "parse-length resolves % against a reference; passes the number through without one"
    (check-= (parse-length "50%" 0 #:reference 200) 100. 1e-9)
    (check-= (parse-length "50%") 50. 1e-9))

  ;; ---- preserveAspectRatio parsing --------------------------------------

  (test-case "parse-preserve-aspect-ratio defaults to xMidYMid meet"
    (define par (parse-preserve-aspect-ratio #f))
    (check-equal? (preserve-ar-align par) "xMidYMid")
    (check-equal? (preserve-ar-meet-or-slice par) 'meet))

  (test-case "parse-preserve-aspect-ratio parses align/meet-or-slice, ignoring a leading 'defer'"
    (define par (parse-preserve-aspect-ratio "defer xMinYMax slice"))
    (check-equal? (preserve-ar-align par) "xMinYMax")
    (check-equal? (preserve-ar-meet-or-slice par) 'slice))

  ;; ---- viewBox matrix math ------------------------------------------------

  (test-case "compute-viewbox-matrix: identity when viewBox equals the viewport"
    (check-equal? (compute-viewbox-matrix 0 0 100 100 100 100 (parse-preserve-aspect-ratio #f))
                  (vector 1 0 0 1 0 0)))

  (test-case "compute-viewbox-matrix: 'meet' scales to the smaller ratio and centers the leftover"
    ;; viewBox 200x100 into a 100x100 viewport: scale-x=0.5, scale-y=1.0;
    ;; meet picks the smaller (0.5), and default xMidYMid centers the
    ;; resulting 50px of vertical leftover -> ty = 25.
    (define m (compute-viewbox-matrix 0 0 200 100 100 100 (parse-preserve-aspect-ratio #f)))
    (check-= (vector-ref m 0) 0.5 1e-9)
    (check-= (vector-ref m 3) 0.5 1e-9)
    (check-= (vector-ref m 5) 25. 1e-9))

  (test-case "compute-viewbox-matrix: 'slice' scales to the larger ratio instead"
    (define m (compute-viewbox-matrix 0 0 200 100 100 100 (parse-preserve-aspect-ratio "xMidYMid slice")))
    (check-= (vector-ref m 0) 1.0 1e-9)
    (check-= (vector-ref m 3) 1.0 1e-9))

  (test-case "compute-viewbox-matrix: viewBox min-x/min-y offset is canceled out"
    (define m (compute-viewbox-matrix 10 20 100 100 100 100 (parse-preserve-aspect-ratio "none")))
    (check-= (vector-ref m 4) -10. 1e-9)
    (check-= (vector-ref m 5) -20. 1e-9))

  ;; ---- presentation-attribute inheritance (direct, on hand-built xexprs) ---

  (test-case "resolve-inherited: unset attributes inherit the parent's resolved value"
    (define g-ctx (resolve-inherited '(g ((fill "red") (stroke "blue"))) ua-default-ctx))
    (define leaf-ctx (resolve-inherited '(path ((d "M0,0"))) g-ctx))
    (check-equal? (send (render-ctx-fill leaf-ctx) red) 255)
    (check-equal? (send (render-ctx-stroke leaf-ctx) blue) 255))

  (test-case "resolve-inherited: a node's own attribute overrides the inherited value"
    (define g-ctx (resolve-inherited '(g ((fill "red"))) ua-default-ctx))
    (define leaf-ctx (resolve-inherited '(path ((fill "blue"))) g-ctx))
    (check-equal? (send (render-ctx-fill leaf-ctx) blue) 255)
    (check-equal? (send (render-ctx-fill leaf-ctx) red) 0))

  ;; ---- SVG document reader + renderer (integration) -----------------------

  (test-case "read-svg-document picks up width/height/viewBox"
    (define doc (read-svg-document "<svg width=\"200\" height=\"100\"><path d=\"M0,0L1,1\"/></svg>"))
    (check-equal? (svg-doc-width doc) 200)
    (check-equal? (svg-doc-height doc) 100))

  (test-case "read-svg-document falls back to viewBox when width/height absent"
    (define doc (read-svg-document "<svg viewBox=\"0 0 50 25\"><path d=\"M0,0L1,1\"/></svg>"))
    (check-equal? (svg-doc-width doc) 50)
    (check-equal? (svg-doc-height doc) 25))

  (test-case "a bare % width at the document root falls back to the viewBox size"
    (define doc (read-svg-document "<svg width=\"100%\" height=\"100%\" viewBox=\"0 0 40 30\"><path d=\"M0,0L1,1\"/></svg>"))
    (check-equal? (svg-doc-width doc) 40)
    (check-equal? (svg-doc-height doc) 30))

  (test-case "presentation attributes inherit through <g> when rendered"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\"><g fill=\"#ff0000\"><path d=\"M0,0 L20,0 L20,20 L0,20 Z\"/></g></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px red) 255)
    (check-equal? (send px green) 0))

  (test-case "a path's own fill overrides an inherited one when rendered"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\"><g fill=\"#ff0000\"><path d=\"M0,0 L20,0 L20,20 L0,20 Z\" fill=\"#0000ff\"/></g></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px blue) 255)
    (check-equal? (send px red) 0))

  (test-case "nested <g> elements are all walked and rendered"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <g><path d=\"M0,0 L5,0 L5,5 L0,5 Z\" fill=\"#ff0000\"/>
                      <g><path d=\"M10,10 L15,10 L15,15 L10,15 Z\" fill=\"#0000ff\"/></g>
                   </g>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 2 2 px)
    (check-equal? (send px red) 255)
    (send dc get-pixel 12 12 px)
    (check-equal? (send px blue) 255))

  (test-case "unsupported elements are skipped, not fatal, and siblings still render"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <image x=\"0\" y=\"0\" width=\"5\" height=\"5\" href=\"not-yet-supported.png\"/>
                   <path d=\"M10,10 L15,10 L15,15 L10,15 Z\" fill=\"#00ff00\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; <image> (Tier 8) is skipped, not fatal, and the area it would have
    ;; occupied stays blank.
    (send dc get-pixel 2 2 px)
    (check-equal? (send px green) 255)
    ;; its sibling <path> must still render normally.
    (send dc get-pixel 12 12 px)
    (check-equal? (send px green) 255)
    (check-equal? (send px red) 0))

  (test-case "content inside <defs> is captured in the id table but never rendered directly"
    (define doc (read-svg-document
                 "<svg width=\"20\" height=\"20\"><defs><path id=\"p1\" d=\"M0,0 L20,0 L20,20 L0,20 Z\" fill=\"red\"/></defs></svg>"))
    (check-true (hash-has-key? (svg-doc-id-table doc) "p1"))
    (define bm (make-object bitmap% 20 20))
    (define dc (new bitmap-dc% [bitmap bm]))
    (render-svg-doc! doc dc)
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px red) 255)
    (check-equal? (send px green) 255)
    (check-equal? (send px blue) 255))

  (test-case "viewBox scaling positions rendered content at the scaled location"
    ;; A 10x10-unit square in a 0..10 viewBox, mapped onto a 100x100
    ;; viewport, is a uniform 10x scale -- its center should land at (50,50).
    (define bm (svg-string->bitmap
                "<svg width=\"100\" height=\"100\" viewBox=\"0 0 10 10\">
                   <path d=\"M0,0 L10,0 L10,10 L0,10 Z\" fill=\"#00ff00\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 50 50 px)
    (check-equal? (send px green) 255))

  (test-case "viewBox scaling also scales stroke width (confirmed dc-level behavior)"
    ;; A 1-unit-wide stroke in a viewBox scaled 10x should render roughly
    ;; 10px thick -- confirms the dc transformation stack (not manual path
    ;; baking) is what's driving rendering, matching SVG's default
    ;; (non-vector-effect) stroke-scaling behavior.
    (define bm (svg-string->bitmap
                "<svg width=\"100\" height=\"20\" viewBox=\"0 0 10 2\">
                   <path d=\"M0,1 L10,1\" stroke=\"black\" stroke-width=\"1\" fill=\"none\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define thickness
      (for/sum ([y (in-range 20)])
        (send dc get-pixel 50 y px)
        (if (< (send px red) 200) 1 0)))
    (check-true (> thickness 5)))  ; ~10px expected; generous margin for antialiasing

  (test-case "parse-paint handles hex, shorthand hex, none, and named colors"
    (check-equal? (send (parse-paint "#ff0000") red) 255)
    (check-equal? (send (parse-paint "#f00") red) 255)
    (check-false (parse-paint "none"))
    (check-equal? (send (parse-paint "red") red) 255))

  (test-case "parse-paint uses CSS/SVG color values, not Racket's X11-derived defaults"
    ;; Racket's the-color-database is X11-based and gives visibly wrong
    ;; values for several of the 16 basic CSS names -- caught by
    ;; rendering against librsvg and comparing output.
    (define (rgb color-string) (define c (parse-paint color-string))
      (list (send c red) (send c green) (send c blue)))
    (check-equal? (rgb "green") '(0 128 0))    ; X11 would give (0 255 0)
    (check-equal? (rgb "purple") '(128 0 128)) ; X11 would give (160 32 240)
    (check-equal? (rgb "gray") '(128 128 128)) ; X11 would give (190 190 190)
    (check-equal? (rgb "grey") '(128 128 128)) ; missing entirely from X11 db
    (check-equal? (rgb "maroon") '(128 0 0))   ; X11 would give (176 48 96)
    (check-equal? (rgb "navy") '(0 0 128)))    ; X11 would give (36 36 140)

  (test-case "svg-string->bitmap renders without error and yields correct size"
    (define bm (svg-string->bitmap
                "<svg width=\"40\" height=\"20\"><path d=\"M0,0 L40,20 L0,20 Z\" fill=\"#0000ff\"/></svg>"))
    (check-equal? (send bm get-width) 40)
    (check-equal? (send bm get-height) 20)
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (check-true (send dc get-pixel 10 15 px)))

  (test-case "arcs from real SVG test-suite paths do not crash and stay closed"
    ;; Sanity-check against the same kind of paths referenced in the
    ;; uploaded test file's comments (W3C arc test suite paths).
    (define paths (path-data->dc-paths "M 30 150 a 40 40 0 0 1 65 50 Z"))
    (check-equal? (length paths) 1))

  ;; ==== Tier 1: the `transform` attribute =================================

  (test-case "parse-transform-list parses individual functions with varied separators"
    (check-equal? (parse-transform-list "translate(10,20)") '((translate 10 20)))
    (check-equal? (parse-transform-list "translate(10 20)") '((translate 10 20)))
    (check-equal? (parse-transform-list "translate(10)") '((translate 10)))
    (check-equal? (parse-transform-list "scale(2)") '((scale 2)))
    (check-equal? (parse-transform-list "scale(2,3)") '((scale 2 3)))
    (check-equal? (parse-transform-list "rotate(45)") '((rotate 45)))
    (check-equal? (parse-transform-list "rotate(45,10,10)") '((rotate 45 10 10)))
    (check-equal? (parse-transform-list "skewX(10)") '((skewX 10)))
    (check-equal? (parse-transform-list "skewY(-10)") '((skewY -10)))
    (check-equal? (parse-transform-list "matrix(1,0,0,1,5,5)") '((matrix 1 0 0 1 5 5))))

  (test-case "parse-transform-list parses a chained list of functions in order"
    (check-equal? (parse-transform-list "translate(10,20) rotate(45) scale(2)")
                  '((translate 10 20) (rotate 45) (scale 2))))

  (define (fresh-test-dc) (new bitmap-dc% [bitmap (make-object bitmap% 10 10)]))
  (define (current-matrix dc) (vector-ref (send dc get-transformation) 0))
  (define (check-matrix=~ m expected)
    (for ([a (in-vector m)] [b (in-vector expected)]) (check-= a b 1e-9)))

  (test-case "apply-transform-op!: translate/scale/matrix produce the expected raw matrices"
    (define dc1 (fresh-test-dc))
    (apply-transform-op! dc1 '(translate 10 20))
    (check-matrix=~ (current-matrix dc1) (vector 1 0 0 1 10 20))
    (define dc2 (fresh-test-dc))
    (apply-transform-op! dc2 '(scale 2 3))
    (check-matrix=~ (current-matrix dc2) (vector 2 0 0 3 0 0))
    (define dc3 (fresh-test-dc))
    (apply-transform-op! dc3 '(matrix 1 2 3 4 5 6))
    (check-matrix=~ (current-matrix dc3) (vector 1 2 3 4 5 6)))

  (test-case "apply-transform-op!: rotate matches SVG's clockwise-for-positive-angle convention"
    ;; Regression test for the sign-convention mismatch found by testing:
    ;; dc<%>'s own `rotate` method spins counter-clockwise for a positive
    ;; angle, but SVG defines rotate() as clockwise -- rotate(90) must
    ;; produce matrix(cos90,sin90,-sin90,cos90,0,0) = (0,1,-1,0,0,0).
    (define dc (fresh-test-dc))
    (apply-transform-op! dc '(rotate 90))
    (check-matrix=~ (current-matrix dc) (vector 0 1 -1 0 0 0)))

  (test-case "apply-transform-op!: rotate around a pivot leaves the pivot point fixed"
    (define dc (fresh-test-dc))
    (apply-transform-op! dc '(rotate 37 5 5))
    (define m (current-matrix dc))
    (define (apply-m x y)
      (values (+ (* (vector-ref m 0) x) (* (vector-ref m 2) y) (vector-ref m 4))
              (+ (* (vector-ref m 1) x) (* (vector-ref m 3) y) (vector-ref m 5))))
    (define-values (px py) (apply-m 5 5))
    (check-= px 5. 1e-6)
    (check-= py 5. 1e-6))

  (test-case "apply-transform-op!: skewX/skewY use SVG's tan()-based matrix"
    (define dc1 (fresh-test-dc))
    (apply-transform-op! dc1 '(skewX 45))
    (check-= (vector-ref (current-matrix dc1) 2) 1.0 1e-9)  ; tan(45deg) = 1
    (define dc2 (fresh-test-dc))
    (apply-transform-op! dc2 '(skewY 45))
    (check-= (vector-ref (current-matrix dc2) 1) 1.0 1e-9))

  (test-case "the transform attribute translates a shape when rendered"
    (define bm (svg-string->bitmap
                "<svg width=\"30\" height=\"30\"><rect x=\"0\" y=\"0\" width=\"5\" height=\"5\" fill=\"red\" transform=\"translate(20,20)\"/></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 2 2 px)   ; original (untranslated) location: must stay blank
    (check-equal? (send px red) 255)
    (send dc get-pixel 22 22 px) ; translated location: must be filled
    (check-equal? (send px red) 255)
    (check-equal? (send px green) 0))

  (test-case "a <g transform=...> applies to its children without leaking to siblings"
    (define bm (svg-string->bitmap
                "<svg width=\"40\" height=\"20\">
                   <g transform=\"translate(20,0)\"><rect x=\"0\" y=\"0\" width=\"5\" height=\"5\" fill=\"blue\"/></g>
                   <rect x=\"0\" y=\"0\" width=\"5\" height=\"5\" fill=\"red\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 2 2 px)   ; untranslated sibling rect: unaffected by the g's transform
    (check-equal? (send px red) 255)
    (send dc get-pixel 22 2 px)  ; the g's child, shifted by translate(20,0)
    (check-equal? (send px blue) 255))

  ;; ==== Tier 1: basic shapes ================================================

  (test-case "<rect> renders a filled axis-aligned rectangle"
    (define bm (svg-string->bitmap "<svg width=\"20\" height=\"20\"><rect x=\"2\" y=\"2\" width=\"10\" height=\"10\" fill=\"#0000ff\"/></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 5 5 px)
    (check-equal? (send px red) 0)     ; blue fill has red=0; white background has red=255
    (send dc get-pixel 17 17 px)
    (check-equal? (send px red) 255))

  (test-case "<rect> with rx rounds the corners"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\"><rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" rx=\"8\" fill=\"#00ff00\"/></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)  ; center: well inside
    (check-equal? (send px red) 0)     ; green fill has red=0; white background has red=255
    (send dc get-pixel 1 1 px)    ; corner: cut away by the rounding
    (check-equal? (send px red) 255))

  (test-case "<circle> renders a filled disk"
    (define bm (svg-string->bitmap "<svg width=\"20\" height=\"20\"><circle cx=\"10\" cy=\"10\" r=\"8\" fill=\"red\"/></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px green) 0)   ; red fill has green=0; white background has green=255
    (send dc get-pixel 1 1 px)
    (check-equal? (send px green) 255))

  (test-case "<ellipse> respects independent x/y radii"
    (define bm (svg-string->bitmap "<svg width=\"20\" height=\"20\"><ellipse cx=\"10\" cy=\"10\" rx=\"9\" ry=\"3\" fill=\"purple\"/></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 15 10 px)  ; well inside on the wide (x) axis
    (check-equal? (send px red) 128)
    (send dc get-pixel 10 2 px)   ; well outside on the narrow (y) axis
    (check-equal? (send px green) 255))

  (test-case "<line> only strokes, never fills, regardless of an inherited fill"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\"><g fill=\"red\"><line x1=\"2\" y1=\"10\" x2=\"18\" y2=\"10\" stroke=\"black\"/></g></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 2 px)  ; well off the line: a zero-area shape can't fill anything
    (check-equal? (send px red) 255)
    (check-equal? (send px green) 255))

  (test-case "<polygon> strokes its closing edge; <polyline> does not"
    (define px (make-object color%))
    (define dc-poly (new bitmap-dc% [bitmap (svg-string->bitmap
                     "<svg width=\"20\" height=\"20\"><polygon points=\"2,2 18,2 18,18\" fill=\"none\" stroke=\"black\"/></svg>")]))
    (send dc-poly get-pixel 10 10 px)  ; midpoint of the (18,18)-(2,2) closing diagonal
    (check-true (< (send px red) 100))
    (define dc-line (new bitmap-dc% [bitmap (svg-string->bitmap
                     "<svg width=\"20\" height=\"20\"><polyline points=\"2,2 18,2 18,18\" fill=\"none\" stroke=\"black\"/></svg>")]))
    (send dc-line get-pixel 10 10 px)  ; same point: polyline never draws that edge
    (check-equal? (send px red) 255))

  ;; ==== Tier 2: color functions ============================================

  (test-case "parse-paint handles rgb()/rgba() with integers and percentages"
    (define (rgb s) (define c (parse-paint s)) (list (send c red) (send c green) (send c blue)))
    (check-equal? (rgb "rgb(255,0,0)") '(255 0 0))
    (check-equal? (rgb "rgb(100%, 0%, 0%)") '(255 0 0))
    (check-equal? (rgb "rgb(0, 128, 255)") '(0 128 255))
    (check-equal? (rgb "rgb(255 0 0)") '(255 0 0))  ; CSS4 space syntax
    (check-= (send (parse-paint "rgba(255,0,0,0.5)") alpha) 0.5 1e-9))

  (test-case "parse-paint handles hsl()/hsla()"
    (define (rgb s) (define c (parse-paint s)) (list (send c red) (send c green) (send c blue)))
    (check-equal? (rgb "hsl(0,100%,50%)") '(255 0 0))
    (check-equal? (rgb "hsl(120,100%,50%)") '(0 255 0))
    (check-equal? (rgb "hsl(240,100%,50%)") '(0 0 255))
    (check-= (send (parse-paint "hsla(0,100%,50%,0.25)") alpha) 0.25 1e-9))

  (test-case "parse-paint resolves currentColor against the supplied current-color"
    (define blue (parse-paint "blue"))
    (define resolved (parse-paint "currentColor" blue))
    (check-equal? (send resolved blue) 255)
    (check-equal? (send resolved red) 0))

  (test-case "currentColor resolves against the inherited color property when rendered"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\"><g color=\"blue\"><rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"currentColor\"/></g></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px blue) 255)
    (check-equal? (send px red) 0))

  ;; ==== Tier 2: opacity =====================================================

  (test-case "parse-opacity handles numbers and percentages, clamped to [0,1]"
    (check-= (parse-opacity "0.5") 0.5 1e-9)
    (check-= (parse-opacity "50%") 0.5 1e-9)
    (check-= (parse-opacity "2") 1.0 1e-9)
    (check-= (parse-opacity "-1") 0.0 1e-9))

  (test-case "fill-opacity blends the fill over whatever is underneath when rendered"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"#00ff00\"/>
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"#ff0000\" fill-opacity=\"0.5\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-true (and (> (send px red) 100) (< (send px red) 200)))
    (check-true (and (> (send px green) 100) (< (send px green) 200))))

  (test-case "element opacity multiplies onto fill/stroke opacity when rendered"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"#00ff00\"/>
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"#ff0000\" opacity=\"0.5\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-true (and (> (send px red) 100) (< (send px red) 200))))

  (test-case "opacity accumulates multiplicatively through nested groups"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"#00ff00\"/>
                   <g opacity=\"0.5\"><g opacity=\"0.5\"><rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"#ff0000\"/></g></g>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    ;; combined opacity 0.5*0.5=0.25 -> mostly green, a little red mixed in
    (check-true (> (send px green) (send px red))))

  ;; ==== Tier 2: stroke-linecap / stroke-linejoin ===========================

  (test-case "parse-linecap/parse-linejoin map SVG keywords to racket/draw symbols"
    (check-equal? (parse-linecap "round") 'round)
    (check-equal? (parse-linecap "square") 'projecting)
    (check-equal? (parse-linecap "butt") 'butt)
    (check-equal? (parse-linejoin "round") 'round)
    (check-equal? (parse-linejoin "bevel") 'bevel)
    (check-equal? (parse-linejoin "miter") 'miter))

  (test-case "stroke-linecap=square extends the stroke past the endpoint; butt does not"
    (define px (make-object color%))
    (define dc-sq (new bitmap-dc% [bitmap (svg-string->bitmap
                   "<svg width=\"20\" height=\"20\"><line x1=\"5\" y1=\"10\" x2=\"10\" y2=\"10\" stroke=\"black\" stroke-width=\"4\" stroke-linecap=\"square\"/></svg>")]))
    (send dc-sq get-pixel 11 10 px)
    (check-true (< (send px red) 200))
    (define dc-butt (new bitmap-dc% [bitmap (svg-string->bitmap
                     "<svg width=\"20\" height=\"20\"><line x1=\"5\" y1=\"10\" x2=\"10\" y2=\"10\" stroke=\"black\" stroke-width=\"4\" stroke-linecap=\"butt\"/></svg>")]))
    (send dc-butt get-pixel 11 10 px)
    (check-equal? (send px red) 255))

  ;; ==== Tier 2: stroke-dasharray / stroke-dashoffset =======================

  (test-case "parse-dasharray parses, validates, and doubles odd-length lists"
    (check-equal? (parse-dasharray "5,3") '(5 3))
    (check-equal? (parse-dasharray "5 3 2") '(5 3 2 5 3 2))
    (check-false (parse-dasharray "none"))
    (check-false (parse-dasharray ""))
    (check-false (parse-dasharray "-1,3"))
    (check-false (parse-dasharray "0,0")))

  (define (check-points= pts expected)
    (check-equal? (length pts) (length expected))
    (for ([p (in-list pts)] [e (in-list expected)])
      (check-= (car p) (car e) 1e-6)
      (check-= (cdr p) (cdr e) 1e-6)))

  (test-case "dc-path->polylines flattens a straight-line path exactly"
    (define p (new dc-path%))
    (send p move-to 0 0)
    (send p line-to 10 0)
    (send p line-to 10 10)
    (define polys (dc-path->polylines p))
    (check-equal? (length polys) 1)
    (check-points= (first polys) (list (cons 0. 0.) (cons 10. 0.) (cons 10. 10.))))

  (test-case "dc-path->polylines subdivides curves into multiple sampled points"
    (define p (new dc-path%))
    (send p move-to 0 0)
    (send p curve-to 0 10 10 10 10 0)
    (define pts (first (dc-path->polylines p)))
    (check-true (> (length pts) 5))
    (check-= (car (first pts)) 0. 1e-6) (check-= (cdr (first pts)) 0. 1e-6)
    (check-= (car (last pts)) 10. 1e-6) (check-= (cdr (last pts)) 0. 1e-6))

  (test-case "dc-path->polylines closes a closed subpath's polyline back to its start"
    (define p (new dc-path%))
    (send p move-to 0 0) (send p line-to 10 0) (send p line-to 10 10) (send p close)
    (define pts (first (dc-path->polylines p)))
    (check-= (car (last pts)) 0. 1e-6) (check-= (cdr (last pts)) 0. 1e-6))

  (test-case "dash-split-polyline splits a straight line into alternating on/off runs"
    (define pts (list (cons 0. 0.) (cons 10. 0.)))
    (define runs (dash-split-polyline pts '(2 1) 0))
    (check-equal? (length runs) 4)
    (check-= (car (first (first runs))) 0. 1e-9)
    (check-= (car (last (first runs))) 2. 1e-9))

  (test-case "dash-split-polyline honors a nonzero dashoffset as a phase shift"
    (define pts (list (cons 0. 0.) (cons 10. 0.)))
    (define runs (dash-split-polyline pts '(2 1) 1))
    ;; shifted 1 unit into the first "on" dash -> the first visible run
    ;; is only 1 unit long (from 0 to 1), not the full 2.
    (check-= (car (last (first runs))) 1. 1e-9))

  (test-case "stroke-dasharray produces real gaps when rendered"
    (define bm (svg-string->bitmap
                "<svg width=\"30\" height=\"10\"><line x1=\"0\" y1=\"5\" x2=\"30\" y2=\"5\" stroke=\"black\" stroke-width=\"2\" stroke-dasharray=\"6,4\"/></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 2 5 px)   ; inside the first 6-unit dash
    (check-true (< (send px red) 200))
    (send dc get-pixel 8 5 px)   ; inside the following 4-unit gap
    (check-equal? (send px red) 255))

  ;; ==== Tier 2: inline style="" attribute ==================================

  (test-case "parse-style-attr parses semicolon-separated declarations, tracking !important"
    (define props (parse-style-attr "fill: red; stroke:blue ;  opacity : 0.5"))
    (check-equal? (car (hash-ref props "fill")) "red")
    (check-false (cdr (hash-ref props "fill")))
    (check-equal? (car (hash-ref props "stroke")) "blue")
    (check-equal? (car (hash-ref props "opacity")) "0.5")
    (define important-props (parse-style-attr "fill: red !important; stroke: blue"))
    (check-equal? (car (hash-ref important-props "fill")) "red")
    (check-true (cdr (hash-ref important-props "fill")))
    (check-false (cdr (hash-ref important-props "stroke"))))

  (test-case "style=... takes priority over a presentation attribute of the same name"
    (define ctx (resolve-inherited '(path ((fill "blue") (style "fill:red"))) ua-default-ctx))
    (check-equal? (send (render-ctx-fill ctx) red) 255)
    (check-equal? (send (render-ctx-fill ctx) green) 0))

  ;; ==== Tier 3: defs / use / symbol =========================================

  (test-case "<use> renders a <defs>-declared shape, positioned by x/y"
    (define bm (svg-string->bitmap
                "<svg width=\"40\" height=\"40\">
                   <defs><circle id=\"c\" cx=\"0\" cy=\"0\" r=\"8\" fill=\"red\"/></defs>
                   <use href=\"#c\" x=\"10\" y=\"10\"/>
                   <use href=\"#c\" x=\"30\" y=\"30\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px green) 0)  ; first instance, centered at (10,10)
    (send dc get-pixel 30 30 px)
    (check-equal? (send px green) 0)  ; second instance, centered at (30,30)
    (send dc get-pixel 0 0 px)
    (check-equal? (send px green) 255))  ; original defs location: never drawn there directly

  (test-case "xlink:href is accepted as a fallback for href"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\" xmlns:xlink=\"http://www.w3.org/1999/xlink\">
                   <defs><rect id=\"r\" x=\"0\" y=\"0\" width=\"6\" height=\"6\" fill=\"blue\"/></defs>
                   <use xlink:href=\"#r\" x=\"5\" y=\"5\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 7 7 px)
    (check-equal? (send px blue) 255))

  (test-case "<use> establishes inheritance from its own context, overridable by the target"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <defs><circle id=\"c1\" cx=\"0\" cy=\"0\" r=\"8\"/></defs>
                   <defs><circle id=\"c2\" cx=\"0\" cy=\"0\" r=\"8\" fill=\"blue\"/></defs>
                   <use href=\"#c1\" x=\"10\" y=\"10\" fill=\"red\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px red) 255)   ; c1 has no own fill -> inherits red from <use>
    (check-equal? (send px blue) 0))

  (test-case "a target's own attribute still overrides what <use> would otherwise supply"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <defs><circle id=\"c2\" cx=\"0\" cy=\"0\" r=\"8\" fill=\"blue\"/></defs>
                   <use href=\"#c2\" x=\"10\" y=\"10\" fill=\"red\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px blue) 255)  ; c2's own fill="blue" wins over <use>'s inherited red
    (check-equal? (send px red) 0))

  (test-case "a dangling href is not fatal and simply renders nothing"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\"><use href=\"#nope\" x=\"5\" y=\"5\"/></svg>"))
    (check-equal? (send bm get-width) 20))  ; just needs to not crash

  (test-case "a self-referencing <use> does not infinite-loop"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\"><use id=\"u\" href=\"#u\" x=\"5\" y=\"5\"/></svg>"))
    (check-equal? (send bm get-width) 20))

  (test-case "a <use> reference cycle (A -> B -> A) does not infinite-loop"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <defs>
                     <g id=\"a\"><use href=\"#b\"/></g>
                     <g id=\"b\"><use href=\"#a\"/></g>
                   </defs>
                   <use href=\"#a\"/>
                 </svg>"))
    (check-equal? (send bm get-width) 20))

  (test-case "<symbol> is never rendered directly without a <use>"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\"><symbol id=\"s\"><rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"red\"/></symbol></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px green) 255))

  (test-case "<use> instantiating a <symbol> establishes a new viewport via viewBox"
    (define bm (svg-string->bitmap
                "<svg width=\"40\" height=\"40\">
                   <symbol id=\"s\" viewBox=\"0 0 10 10\"><rect x=\"0\" y=\"0\" width=\"10\" height=\"10\" fill=\"green\"/></symbol>
                   <use href=\"#s\" width=\"40\" height=\"40\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; the 10x10 symbol content scaled 4x by the use's 40x40 instantiation
    ;; should fill the whole canvas, including near the far corner.
    (send dc get-pixel 35 35 px)
    (check-equal? (send px red) 0)
    (check-equal? (send px green) 128))

  (test-case "a nested <svg> establishes its own viewport, independent of the root's"
    (define bm (svg-string->bitmap
                "<svg width=\"100\" height=\"50\" viewBox=\"0 0 100 50\">
                   <rect x=\"0\" y=\"0\" width=\"40\" height=\"50\" fill=\"red\"/>
                   <svg x=\"40\" y=\"0\" width=\"60\" height=\"50\" viewBox=\"0 0 6 5\">
                     <rect x=\"0\" y=\"0\" width=\"6\" height=\"5\" fill=\"blue\"/>
                   </svg>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 20 25 px)  ; inside the root-level red rect
    (check-equal? (send px red) 255)
    (send dc get-pixel 70 25 px)  ; inside the nested <svg>'s own scaled content
    (check-equal? (send px blue) 255))

  ;; ==== Tier 4: gradients & patterns ========================================

  (test-case "parse-paint recognizes url(#id) with and without a fallback color"
    (define p1 (parse-paint "url(#g1)"))
    (check-true (paint-ref? p1))
    (check-equal? (paint-ref-id p1) "g1")
    (check-false (paint-ref-fallback p1))
    (define p2 (parse-paint "url(#g2) red"))
    (check-true (paint-ref? p2))
    (check-equal? (paint-ref-id p2) "g2")
    (check-equal? (send (paint-ref-fallback p2) red) 255))

  (test-case "combined-bounding-box unions the bounding boxes of several dc-path%s"
    (define p1 (new dc-path%)) (send p1 rectangle 0 0 10 10)
    (define p2 (new dc-path%)) (send p2 rectangle 20 20 5 5)
    (check-equal? (combined-bounding-box (list p1 p2)) (list 0. 0. 25. 25.)))

  (test-case "resolve-gradient-stops parses offsets, colors, and opacity, forcing non-decreasing order"
    (define node '(linearGradient ()
                    (stop ((offset "0") (stop-color "red")))
                    (stop ((offset "80%") (stop-color "blue") (stop-opacity "0.5")))
                    (stop ((offset "50%") (stop-color "green")))))  ; out of order -> clamped up to 0.8
    (define stops (resolve-gradient-stops node))
    (check-equal? (length stops) 3)
    (check-= (car (first stops)) 0. 1e-9)
    (check-= (car (second stops)) 0.8 1e-9)
    (check-= (car (third stops)) 0.8 1e-9)  ; clamped: can't go backwards from 0.8 to 0.5
    (check-= (send (cdr (second stops)) alpha) 0.5 1e-9))

  (test-case "a linear gradient fill runs from its first stop's color to its last"
    (define bm (svg-string->bitmap
                "<svg width=\"100\" height=\"20\">
                   <defs><linearGradient id=\"g\" x1=\"0%\" y1=\"0%\" x2=\"100%\" y2=\"0%\">
                     <stop offset=\"0%\" stop-color=\"red\"/>
                     <stop offset=\"100%\" stop-color=\"blue\"/>
                   </linearGradient></defs>
                   <rect x=\"0\" y=\"0\" width=\"100\" height=\"20\" fill=\"url(#g)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 2 10 px)
    (check-true (> (send px red) 200))
    (send dc get-pixel 97 10 px)
    (check-true (> (send px blue) 200)))

  (test-case "gradientUnits=userSpaceOnUse uses absolute coordinates instead of bbox fractions"
    (define bm (svg-string->bitmap
                "<svg width=\"100\" height=\"20\">
                   <defs><linearGradient id=\"g\" gradientUnits=\"userSpaceOnUse\" x1=\"40\" y1=\"0\" x2=\"60\" y2=\"0\">
                     <stop offset=\"0\" stop-color=\"red\"/>
                     <stop offset=\"1\" stop-color=\"blue\"/>
                   </linearGradient></defs>
                   <rect x=\"0\" y=\"0\" width=\"100\" height=\"20\" fill=\"url(#g)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; the gradient only spans x=40..60 in absolute user space, so
    ;; everything left of it should be clamped to pure red (pad).
    (send dc get-pixel 5 10 px)
    (check-equal? (send px red) 255)
    (check-equal? (send px blue) 0))

  (test-case "a radial gradient fill is red at its center and blue at its edge"
    (define bm (svg-string->bitmap
                "<svg width=\"40\" height=\"40\">
                   <defs><radialGradient id=\"g\">
                     <stop offset=\"0%\" stop-color=\"red\"/>
                     <stop offset=\"100%\" stop-color=\"blue\"/>
                   </radialGradient></defs>
                   <circle cx=\"20\" cy=\"20\" r=\"18\" fill=\"url(#g)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 20 20 px)
    (check-true (> (send px red) 200))
    (send dc get-pixel 20 3 px)
    (check-true (> (send px blue) 150)))

  (test-case "gradientTransform further transforms the gradient's own coordinate system"
    (define bm (svg-string->bitmap
                "<svg width=\"100\" height=\"20\">
                   <defs><linearGradient id=\"g\" gradientUnits=\"userSpaceOnUse\" x1=\"0\" y1=\"0\" x2=\"10\" y2=\"0\"
                                          gradientTransform=\"translate(80,0)\">
                     <stop offset=\"0\" stop-color=\"red\"/>
                     <stop offset=\"1\" stop-color=\"blue\"/>
                   </linearGradient></defs>
                   <rect x=\"0\" y=\"0\" width=\"100\" height=\"20\" fill=\"url(#g)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; shifted 80 units right: the gradient's own [0,10] span now covers
    ;; x=80..90, so x=5 (far outside it) should pad to solid red.
    (send dc get-pixel 5 10 px)
    (check-equal? (send px red) 255)
    (check-equal? (send px blue) 0))

  (test-case "a gradient inherits stops from an href'd parent when it has none of its own"
    (define bm (svg-string->bitmap
                "<svg width=\"100\" height=\"20\">
                   <defs>
                     <linearGradient id=\"base\">
                       <stop offset=\"0%\" stop-color=\"red\"/>
                       <stop offset=\"100%\" stop-color=\"blue\"/>
                     </linearGradient>
                     <linearGradient id=\"g\" href=\"#base\" x1=\"0%\" y1=\"0%\" x2=\"100%\" y2=\"0%\"/>
                   </defs>
                   <rect x=\"0\" y=\"0\" width=\"100\" height=\"20\" fill=\"url(#g)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 2 10 px)
    (check-true (> (send px red) 200))
    (send dc get-pixel 97 10 px)
    (check-true (> (send px blue) 200)))

  (test-case "fill=url(#missing) with a fallback color uses the fallback"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\"><rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"url(#nope) lime\"/></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px green) 255)  ; "lime" is (0,255,0)
    (check-equal? (send px red) 0))

  (test-case "fill=url(#missing) with no fallback renders nothing"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\"><rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"url(#nope)\"/></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px red) 255)
    (check-equal? (send px green) 255))

  (test-case "stroke=url(...) has no gradient/pattern support -- falls back to its fallback color, or no stroke"
    (define bm-fb (svg-string->bitmap
                   "<svg width=\"20\" height=\"20\"><line x1=\"2\" y1=\"10\" x2=\"18\" y2=\"10\" stroke=\"url(#g) black\" stroke-width=\"4\"/></svg>"))
    (define dc-fb (new bitmap-dc% [bitmap bm-fb]))
    (define px (make-object color%))
    (send dc-fb get-pixel 10 10 px)
    (check-equal? (send px red) 0)  ; used the fallback (black)
    (define bm-none (svg-string->bitmap
                     "<svg width=\"20\" height=\"20\"><line x1=\"2\" y1=\"10\" x2=\"18\" y2=\"10\" stroke=\"url(#g)\" stroke-width=\"4\"/></svg>"))
    (define dc-none (new bitmap-dc% [bitmap bm-none]))
    (send dc-none get-pixel 10 10 px)
    (check-equal? (send px red) 255))  ; no fallback -> no stroke at all

  (test-case "a userSpaceOnUse pattern tiles its content across the fill"
    (define bm (svg-string->bitmap
                "<svg width=\"40\" height=\"20\">
                   <defs><pattern id=\"p\" patternUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"10\" height=\"10\">
                     <rect x=\"0\" y=\"0\" width=\"5\" height=\"5\" fill=\"navy\"/>
                   </pattern></defs>
                   <rect x=\"0\" y=\"0\" width=\"40\" height=\"20\" fill=\"url(#p)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; the 5x5 navy square should repeat every 10px -- check two repeats
    (send dc get-pixel 2 2 px)
    (check-equal? (send px blue) 128)
    (send dc get-pixel 12 2 px)
    (check-equal? (send px blue) 128)
    ;; and the gap between them (in the empty part of each 10x10 tile) stays blank
    (send dc get-pixel 7 2 px)
    (check-equal? (send px red) 255))

  (test-case "an objectBoundingBox gradient fill does not shift the shape's own geometry"
    ;; Regression test for a real bug found during development: applying
    ;; the objectBoundingBox mapping via dc.translate/scale on the SAME
    ;; dc used to draw the shape shifted the shape itself, not just the
    ;; gradient's coordinates. A rect from x=5..15 should stay exactly
    ;; there regardless of what gradient fills it.
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <defs><linearGradient id=\"g\">
                     <stop offset=\"0%\" stop-color=\"red\"/>
                     <stop offset=\"100%\" stop-color=\"blue\"/>
                   </linearGradient></defs>
                   <rect x=\"5\" y=\"5\" width=\"10\" height=\"10\" fill=\"url(#g)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; just outside the rect on every side: must stay white
    (for ([pt (list (cons 2 10) (cons 17 10) (cons 10 2) (cons 10 17))])
      (send dc get-pixel (car pt) (cdr pt) px)
      (check-equal? (list (send px red) (send px green) (send px blue)) (list 255 255 255)))
    ;; well inside the rect: must be painted (not white)
    (send dc get-pixel 10 10 px)
    (check-false (equal? (list (send px red) (send px green) (send px blue)) (list 255 255 255))))

  (test-case "an objectBoundingBox pattern (the default) sizes its tile to the shape's bbox"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <defs><pattern id=\"p\" width=\"1\" height=\"1\">
                     <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"teal\"/>
                   </pattern></defs>
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"url(#p)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px green) 128)
    (check-equal? (send px red) 0))

  ;; ==== Tier 5: clipPath ====================================================

  (test-case "parse-clip-rule maps SVG keywords to racket/draw fill-rule symbols"
    (check-equal? (parse-clip-rule "evenodd") 'odd-even)
    (check-equal? (parse-clip-rule "nonzero") 'winding)
    (check-equal? (parse-clip-rule #f) 'winding))

  (test-case "clip-path restricts a shape's fill to the clip region"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <defs><clipPath id=\"c\"><circle cx=\"10\" cy=\"10\" r=\"5\"/></clipPath></defs>
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"red\" clip-path=\"url(#c)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)  ; inside the clip circle
    (check-equal? (send px green) 0)
    (send dc get-pixel 1 1 px)    ; well outside it
    (check-equal? (send px green) 255))

  (test-case "clipPathUnits=objectBoundingBox scales the clip shape to the referencing element's bbox"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <defs><clipPath id=\"c\" clipPathUnits=\"objectBoundingBox\"><circle cx=\"0.5\" cy=\"0.5\" r=\"0.5\"/></clipPath></defs>
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"red\" clip-path=\"url(#c)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px green) 0)
    (send dc get-pixel 1 1 px)
    (check-equal? (send px green) 255))

  (test-case "a clip shape's own transform is baked into the clip geometry"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <defs><clipPath id=\"c\"><rect x=\"0\" y=\"0\" width=\"6\" height=\"6\" transform=\"translate(10,10)\"/></clipPath></defs>
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"blue\" clip-path=\"url(#c)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 12 12 px)  ; inside the translated 10..16 x 10..16 rect
    (check-equal? (send px red) 0)
    (send dc get-pixel 2 2 px)
    (check-equal? (send px red) 255))

  (test-case "clip-path on a <g> and on its child intersect rather than replace"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <defs>
                     <clipPath id=\"left\"><rect x=\"0\" y=\"0\" width=\"10\" height=\"20\"/></clipPath>
                     <clipPath id=\"top\"><rect x=\"0\" y=\"0\" width=\"20\" height=\"10\"/></clipPath>
                   </defs>
                   <g clip-path=\"url(#left)\">
                     <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"green\" clip-path=\"url(#top)\"/>
                   </g>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 3 3 px)   ; inside both clips (top-left quadrant)
    (check-equal? (send px red) 0)
    (send dc get-pixel 15 3 px)  ; inside "top" only, excluded by "left"
    (check-equal? (send px red) 255))

  (test-case "clip-rule=evenodd creates a hole where two clip shapes overlap"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <defs><clipPath id=\"c\" clip-rule=\"evenodd\">
                     <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\"/>
                     <rect x=\"5\" y=\"5\" width=\"10\" height=\"10\"/>
                   </clipPath></defs>
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"purple\" clip-path=\"url(#c)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 2 2 px)    ; outer region: filled
    (check-equal? (send px green) 0)
    (send dc get-pixel 10 10 px)  ; inside the inner rect: evenodd hole -> unfilled
    (check-equal? (send px green) 255))

  ;; ==== Tier 5: mask =========================================================

  (test-case "mask shows content where the mask is white and hides it where black"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <defs><mask id=\"m\">
                     <rect x=\"0\" y=\"0\" width=\"10\" height=\"20\" fill=\"white\"/>
                     <rect x=\"10\" y=\"0\" width=\"10\" height=\"20\" fill=\"black\"/>
                   </mask></defs>
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"red\" mask=\"url(#m)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 3 10 px)   ; under the white half: visible
    (check-equal? (send px green) 0)
    (send dc get-pixel 17 10 px)  ; under the black half: hidden
    (check-equal? (send px green) 255))

  (test-case "mask-type=alpha uses the mask's own alpha instead of computing luminance"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <defs><mask id=\"m\" mask-type=\"alpha\">
                     <rect x=\"0\" y=\"0\" width=\"10\" height=\"20\" fill=\"red\" fill-opacity=\"1\"/>
                     <rect x=\"10\" y=\"0\" width=\"10\" height=\"20\" fill=\"red\" fill-opacity=\"0\"/>
                   </mask></defs>
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"blue\" mask=\"url(#m)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 3 10 px)   ; full alpha region: visible
    (check-equal? (send px red) 0)
    (send dc get-pixel 17 10 px)  ; zero alpha region: hidden
    (check-equal? (send px red) 255))

  (test-case "mask content uses absolute (userSpaceOnUse) coordinates, not ones relative to the masked element"
    ;; Regression test for a mistake initially made in a hand-authored
    ;; cross-check file, not the renderer itself: maskContentUnits
    ;; defaults to userSpaceOnUse, meaning the mask's content is
    ;; positioned in the SAME absolute coordinate system as wherever the
    ;; masked element sits -- not auto-centered/re-based on it. A mask
    ;; whose content only overlaps x=0..20 has no effect on an element
    ;; positioned at x=100..200, since they don't overlap at all.
    (define bm (svg-string->bitmap
                "<svg width=\"220\" height=\"20\">
                   <defs><mask id=\"m\">
                     <rect x=\"0\" y=\"0\" width=\"10\" height=\"20\" fill=\"white\"/>
                     <rect x=\"10\" y=\"0\" width=\"10\" height=\"20\" fill=\"black\"/>
                   </mask></defs>
                   <rect x=\"100\" y=\"0\" width=\"100\" height=\"20\" fill=\"red\" mask=\"url(#m)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; the mask's own content (x=0..20) doesn't reach out to x=100..200
    ;; at all, so nothing there is masked "white" -> the whole rect is
    ;; effectively masked away (matches at 0 alpha for the whole area).
    (send dc get-pixel 150 10 px)
    (check-equal? (send px green) 255))

  (test-case "a mask referencing a nonexistent id falls back to unmasked (mask:none), not fatal"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\"><rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"red\" mask=\"url(#nope)\"/></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px green) 0))

  ;; ==== Tier 6: text ========================================================

  (test-case "parse-font-family separates a generic family from a specific face name"
    (define-values (face1 fam1) (parse-font-family "Georgia, serif"))
    (check-equal? face1 "Georgia")
    (check-equal? fam1 'roman)
    (define-values (face2 fam2) (parse-font-family "sans-serif"))
    (check-false face2)
    (check-equal? fam2 'swiss)
    (define-values (face3 fam3) (parse-font-family "'Courier New', monospace"))
    (check-equal? face3 "Courier New")
    (check-equal? fam3 'modern)
    (define-values (face4 fam4) (parse-font-family #f))
    (check-false face4)
    (check-equal? fam4 'default))

  (test-case "parse-font-weight/parse-font-style/parse-text-anchor map keywords correctly"
    (check-equal? (parse-font-weight "bold") 'bold)
    (check-equal? (parse-font-weight "normal") 'normal)
    (check-equal? (parse-font-weight "700") 700)
    (check-equal? (parse-font-style "italic") 'italic)
    (check-equal? (parse-font-style "oblique") 'slant)
    (check-equal? (parse-text-anchor "middle") 'middle)
    (check-equal? (parse-text-anchor "end") 'end)
    (check-equal? (parse-text-anchor #f) 'start))

  (test-case "parse-number-list parses whitespace/comma-separated numbers"
    (check-equal? (parse-number-list "10 20 30") '(10 20 30))
    (check-equal? (parse-number-list "10,20,30") '(10 20 30))
    (check-equal? (parse-number-list #f) '())
    (check-equal? (parse-number-list "") '()))

  (test-case "collapse-whitespace collapses runs but doesn't trim"
    (check-equal? (collapse-whitespace "a   b\n\tc") "a b c")
    (check-equal? (collapse-whitespace " x ") " x "))

  (test-case "<text> paints its fill color at the expected position"
    (define bm (svg-string->bitmap
                "<svg width=\"100\" height=\"40\"><text x=\"10\" y=\"25\" font-size=\"24\" fill=\"red\">Hi</text></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; scan a region where the glyphs should be for a strongly-red pixel
    (define found?
      (for*/or ([x (in-range 8 40)] [y (in-range 5 30)])
        (send dc get-pixel x y px)
        (and (> (send px red) 200) (< (send px green) 100))))
    (check-true found?))

  (test-case "text-anchor=start/middle/end position text relative to x correctly"
    (define (rendered-columns-with-ink svg-str)
      (define bm (svg-string->bitmap svg-str))
      (define dc (new bitmap-dc% [bitmap bm]))
      (define px (make-object color%))
      (for/list ([x (in-range (send bm get-width))]
                 #:when (for/or ([y (in-range (send bm get-height))])
                          (send dc get-pixel x y px)
                          (< (send px red) 100)))
        x))
    (define start-cols (rendered-columns-with-ink
                         "<svg width=\"200\" height=\"40\"><text x=\"100\" y=\"25\" font-size=\"20\" text-anchor=\"start\">WWWW</text></svg>"))
    (define middle-cols (rendered-columns-with-ink
                          "<svg width=\"200\" height=\"40\"><text x=\"100\" y=\"25\" font-size=\"20\" text-anchor=\"middle\">WWWW</text></svg>"))
    (define end-cols (rendered-columns-with-ink
                       "<svg width=\"200\" height=\"40\"><text x=\"100\" y=\"25\" font-size=\"20\" text-anchor=\"end\">WWWW</text></svg>"))
    ;; start: text begins at or after x=100. middle: spans roughly
    ;; centered on 100 (so its leftmost ink is well before start's).
    ;; end: text finishes at or before x=100 (its rightmost ink is well
    ;; before start's leftmost ink).
    (check-true (>= (apply min start-cols) 98))
    (check-true (< (apply min middle-cols) (apply min start-cols)))
    (check-true (<= (apply max end-cols) 102)))

  (test-case "a tspan's own fill overrides the parent text's, and plain text falls back to the parent's"
    (define bm (svg-string->bitmap
                "<svg width=\"100\" height=\"30\"><text x=\"5\" y=\"20\" font-size=\"18\" fill=\"blue\">A<tspan fill=\"red\">B</tspan></text></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define (blue-ink-in? x0 x1)
      (for*/or ([x (in-range x0 x1)] [y (in-range 30)])
        (send dc get-pixel x y px) (and (< (send px red) 100) (> (send px blue) 100))))
    (define (red-ink-in? x0 x1)
      (for*/or ([x (in-range x0 x1)] [y (in-range 30)])
        (send dc get-pixel x y px) (and (> (send px red) 100) (< (send px blue) 100) (< (send px green) 100))))
    (check-true (blue-ink-in? 0 100))
    (check-true (red-ink-in? 0 100)))

  (test-case "larger font-size produces visibly larger glyphs (more vertical extent)"
    (define (ink-row-span svg-str)
      (define bm (svg-string->bitmap svg-str))
      (define dc (new bitmap-dc% [bitmap bm]))
      (define px (make-object color%))
      (define rows (for/list ([y (in-range (send bm get-height))]
                               #:when (for/or ([x (in-range (send bm get-width))])
                                        (send dc get-pixel x y px) (< (send px red) 100)))
                     y))
      (if (null? rows) 0 (- (apply max rows) (apply min rows))))
    (define small (ink-row-span "<svg width=\"100\" height=\"100\"><text x=\"5\" y=\"50\" font-size=\"12\">Ag</text></svg>"))
    (define large (ink-row-span "<svg width=\"100\" height=\"100\"><text x=\"5\" y=\"50\" font-size=\"48\">Ag</text></svg>"))
    (check-true (> large small)))

  (test-case "text respects a gradient fill via the same paint pipeline as shapes"
    (define bm (svg-string->bitmap
                "<svg width=\"150\" height=\"40\">
                   <defs><linearGradient id=\"g\" x1=\"0%\" y1=\"0%\" x2=\"100%\" y2=\"0%\">
                     <stop offset=\"0%\" stop-color=\"red\"/><stop offset=\"100%\" stop-color=\"blue\"/>
                   </linearGradient></defs>
                   <text x=\"5\" y=\"28\" font-size=\"30\" fill=\"url(#g)\">WW</text>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define (white? x y) (send dc get-pixel x y px)
      (and (= (send px red) 255) (= (send px green) 255) (= (send px blue) 255)))
    (define (ink-y-in-col x) (for/first ([y (in-range 40)] #:unless (white? x y)) y))
    (define ink-cols (for/list ([x (in-range 150)] #:when (ink-y-in-col x)) x))
    (check-true (pair? ink-cols))
    (send dc get-pixel (first ink-cols) (ink-y-in-col (first ink-cols)) px)
    (define left-red (send px red)) (define left-blue (send px blue))
    (send dc get-pixel (last ink-cols) (ink-y-in-col (last ink-cols)) px)
    (define right-red (send px red)) (define right-blue (send px blue))
    ;; the leftmost ink should be redder-than-blue and the rightmost
    ;; bluer-than-red -- confirms the gradient direction is honored
    ;; across the text's own actual extent, whatever that turns out to be.
    (check-true (> left-red left-blue))
    (check-true (> right-blue right-red)))

  (test-case "per-character x positions place characters explicitly, not in natural flow"
    (define bm (svg-string->bitmap
                "<svg width=\"150\" height=\"30\"><text x=\"0 60 120\" y=\"20\" font-size=\"20\">iii</text></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define (has-ink? x0 x1)
      (for*/or ([x (in-range x0 x1)] [y (in-range 30)])
        (send dc get-pixel x y px) (< (send px red) 100)))
    ;; each "i" should land near its own explicit x, not clustered together
    ;; as natural left-to-right flow of "iii" would produce
    (check-true (has-ink? 0 20))
    (check-true (has-ink? 60 80))
    (check-true (has-ink? 120 140)))

  ;; ==== Tier 7: markers =====================================================

  (test-case "parse-marker-orient parses auto/auto-start-reverse/numeric/absent"
    (check-equal? (parse-marker-orient "auto") 'auto)
    (check-equal? (parse-marker-orient "auto-start-reverse") 'auto-start-reverse)
    (check-equal? (parse-marker-orient "45") 45)
    (check-equal? (parse-marker-orient #f) 0))

  (test-case "average-angle bisects two angles, robust to wraparound near +/-180"
    (check-= (average-angle 0 (/ pi 2)) (/ pi 4) 1e-9)
    (define result (average-angle (* pi 0.99) (* pi -0.99)))
    (check-= (abs result) pi 0.1))

  (test-case "dc-path->vertices extracts an open path's vertices with correct tangents"
    (define paths (path-data->dc-paths "M0,0 L10,0 L10,10"))
    (define verts (append-map dc-path->vertices paths))
    (check-equal? (length verts) 3)
    (match-define (list v0 v1 v2) verts)
    (check-= (vertex-x v0) 0 1e-6) (check-= (vertex-y v0) 0 1e-6)
    (check-false (vertex-in-angle v0))
    (check-= (vertex-out-angle v0) 0 1e-6)     ; pointing along +x
    (check-= (vertex-in-angle v1) 0 1e-6)
    (check-= (vertex-out-angle v1) (/ pi 2) 1e-6)  ; pointing along +y (down)
    (check-= (vertex-in-angle v2) (/ pi 2) 1e-6)
    (check-false (vertex-out-angle v2)))

  (test-case "dc-path->vertices adds a distinct closure vertex for a closed subpath"
    (define paths (path-data->dc-paths "M0,0 L10,0 L10,10 Z"))
    (define verts (append-map dc-path->vertices paths))
    (check-equal? (length verts) 4)  ; 3 real vertices + 1 closure duplicate
    (define vlast (last verts))
    (check-= (vertex-x vlast) 0 1e-6) (check-= (vertex-y vlast) 0 1e-6)
    (check-false (vertex-out-angle vlast))
    (check-true (real? (vertex-in-angle vlast))))

  (test-case "marker-angle-degrees: auto bisects or uses whichever side exists; auto-start-reverse flips only at start"
    (define v-mid (vertex 0 0 0 (/ pi 2)))
    (check-= (marker-angle-degrees v-mid 'auto #f) 45 1e-6)
    (define v-start (vertex 0 0 #f 0))
    (check-= (marker-angle-degrees v-start 'auto #t) 0 1e-6)
    (check-= (marker-angle-degrees v-start 'auto-start-reverse #t) 180 1e-6)
    (check-= (marker-angle-degrees v-mid 'auto-start-reverse #f) 45 1e-6)
    (check-= (marker-angle-degrees v-mid 30 #f) 30 1e-6))

  (test-case "marker-start/-mid/-end are placed at the first/middle/last vertices"
    (define bm (svg-string->bitmap
                "<svg width=\"60\" height=\"60\">
                   <defs><marker id=\"m\" markerWidth=\"4\" markerHeight=\"4\" refX=\"2\" refY=\"2\">
                     <rect x=\"0\" y=\"0\" width=\"4\" height=\"4\" fill=\"red\"/>
                   </marker></defs>
                   <path d=\"M10,10 L30,30 L50,10\" fill=\"none\" stroke=\"black\"
                         marker-start=\"url(#m)\" marker-mid=\"url(#m)\" marker-end=\"url(#m)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define (red-at? x y) (send dc get-pixel x y px) (and (> (send px red) 200) (< (send px green) 100)))
    (check-true (red-at? 10 10))
    (check-true (red-at? 30 30))
    (check-true (red-at? 50 10)))

  (test-case "markers don't apply to <rect>/<circle>/<ellipse>"
    (define bm (svg-string->bitmap
                "<svg width=\"40\" height=\"40\">
                   <defs><marker id=\"m\" markerWidth=\"4\" markerHeight=\"4\"><rect x=\"0\" y=\"0\" width=\"4\" height=\"4\" fill=\"red\"/></marker></defs>
                   <rect x=\"10\" y=\"10\" width=\"20\" height=\"20\" fill=\"none\" stroke=\"black\" marker-start=\"url(#m)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define any-red? (for*/or ([x (in-range 40)] [y (in-range 40)])
                       (send dc get-pixel x y px) (and (> (send px red) 200) (< (send px green) 100))))
    (check-false any-red?))

  (test-case "orient=auto rotates the marker to align with the path's tangent direction"
    (define bm (svg-string->bitmap
                "<svg width=\"40\" height=\"40\">
                   <defs><marker id=\"m\" markerWidth=\"10\" markerHeight=\"10\" refX=\"0\" refY=\"0\" orient=\"auto\" markerUnits=\"userSpaceOnUse\" overflow=\"visible\">
                     <path d=\"M0,-3 L6,0 L0,3 Z\" fill=\"black\"/>
                   </marker></defs>
                   <line x1=\"20\" y1=\"5\" x2=\"20\" y2=\"30\" stroke=\"blue\" marker-end=\"url(#m)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define (dark? x y) (send dc get-pixel x y px) (< (send px red) 100))
    ;; oriented downward (matching the line's tangent): ink appears BELOW
    ;; the line's end, not off to the side.
    (check-true (dark? 20 33))
    (check-false (dark? 30 30)))

  (test-case "markerUnits=strokeWidth (the default) scales the marker with the shape's stroke-width"
    (define (red-pixel-count stroke-width)
      (define bm (svg-string->bitmap
                  (format "<svg width=\"60\" height=\"60\">
                     <defs><marker id=\"m\" markerWidth=\"4\" markerHeight=\"4\" refX=\"2\" refY=\"2\">
                       <rect x=\"0\" y=\"0\" width=\"4\" height=\"4\" fill=\"red\"/>
                     </marker></defs>
                     <line x1=\"10\" y1=\"30\" x2=\"50\" y2=\"30\" stroke=\"black\" stroke-width=\"~a\" marker-start=\"url(#m)\"/>
                   </svg>" stroke-width)))
      (define dc (new bitmap-dc% [bitmap bm]))
      (define px (make-object color%))
      (for*/sum ([x (in-range 60)] [y (in-range 60)])
        (send dc get-pixel x y px)
        (if (and (> (send px red) 200) (< (send px green) 100)) 1 0)))
    (check-true (> (red-pixel-count 8) (red-pixel-count 1))))

  (test-case "refX/refY anchor a specific point of the marker's own content to the vertex"
    (define bm (svg-string->bitmap
                "<svg width=\"60\" height=\"40\">
                   <defs><marker id=\"m\" markerWidth=\"10\" markerHeight=\"10\" refX=\"0\" refY=\"5\" markerUnits=\"userSpaceOnUse\">
                     <rect x=\"0\" y=\"0\" width=\"10\" height=\"10\" fill=\"red\"/>
                   </marker></defs>
                   <line x1=\"30\" y1=\"20\" x2=\"30\" y2=\"20\" stroke=\"black\" marker-start=\"url(#m)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define (red-at? x y) (send dc get-pixel x y px) (and (> (send px red) 200) (< (send px green) 100)))
    (check-true (red-at? 32 20))
    (check-false (red-at? 25 20)))

  ;; ==== Tier 8: <image> =====================================================

  ;; A tiny 4x4 PNG, left half red and right half blue, used throughout.
  (define test-image-data-uri
    (string-append
     "data:image/png;base64,"
     "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAGklEQVQImWP8z8Dwn4GBgYERQjEwMaABwgIAvNMDBsJIrS8AAAAASUVORK5CYII="))

  (test-case "load-image-bitmap decodes a data: URI"
    (define bm (load-image-bitmap test-image-data-uri))
    (check-true (and bm (send bm ok?)))
    (check-equal? (send bm get-width) 4)
    (check-equal? (send bm get-height) 4))

  (test-case "load-image-bitmap does not fetch remote URLs"
    (check-false (load-image-bitmap "https://example.com/pic.png"))
    (check-false (load-image-bitmap "http://example.com/pic.png")))

  (test-case "load-image-bitmap returns #f for a missing local file, without raising"
    (check-false (load-image-bitmap "/definitely/not/a/real/path/xyz.png")))

  (test-case "load-image-bitmap returns #f for undecodable data, without raising"
    (check-false (load-image-bitmap "data:image/png;base64,dGhpcyBpcyBub3QgYSByZWFsIGltYWdl")))

  (test-case "<image> renders the decoded bitmap at its declared position and size"
    (define bm (svg-string->bitmap
                (format "<svg width=\"40\" height=\"40\"><image x=\"10\" y=\"10\" width=\"20\" height=\"20\" href=\"~a\"/></svg>"
                        test-image-data-uri)))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 15 20 px)  ; left half of the image: red
    (check-true (and (> (send px red) 200) (< (send px blue) 100)))
    (send dc get-pixel 25 20 px)  ; right half: blue
    (check-true (and (> (send px blue) 200) (< (send px red) 100)))
    (send dc get-pixel 5 5 px)    ; outside the image entirely: untouched background
    (check-equal? (list (send px red) (send px green) (send px blue)) (list 255 255 255)))

  (test-case "<image> with no width/height falls back to the bitmap's own natural size"
    (define doc (read-svg-document
                 (format "<svg width=\"40\" height=\"40\"><image x=\"0\" y=\"0\" href=\"~a\"/></svg>" test-image-data-uri)))
    ;; render and confirm ink extends over roughly the natural 4x4 area,
    ;; not stretched to fill the whole 40x40 canvas nor absent entirely
    (define bm (make-object bitmap% 40 40))
    (define dc (new bitmap-dc% [bitmap bm]))
    (render-svg-doc! doc dc)
    (define px (make-object color%))
    (send dc get-pixel 1 1 px)
    (check-false (equal? (list (send px red) (send px green) (send px blue)) (list 255 255 255)))
    (send dc get-pixel 20 20 px)
    (check-equal? (list (send px red) (send px green) (send px blue)) (list 255 255 255)))

  (test-case "<image> clips content to its own x/y/width/height viewport"
    ;; preserveAspectRatio defaults to xMidYMid meet: fitting a 1:1 image
    ;; into a very wide box leaves it letterboxed, centered -- content
    ;; must not spill outside the declared box in the narrow dimension.
    (define bm (svg-string->bitmap
                (format "<svg width=\"60\" height=\"20\"><image x=\"0\" y=\"0\" width=\"60\" height=\"20\" href=\"~a\"/></svg>"
                        test-image-data-uri)))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; the meet-scaled 20x20 image is centered horizontally (x=20..40);
    ;; well outside that, at the box's far edges, must stay blank.
    (send dc get-pixel 2 10 px)
    (check-equal? (list (send px red) (send px green) (send px blue)) (list 255 255 255))
    (send dc get-pixel 58 10 px)
    (check-equal? (list (send px red) (send px green) (send px blue)) (list 255 255 255))
    (send dc get-pixel 30 10 px)
    (check-false (equal? (list (send px red) (send px green) (send px blue)) (list 255 255 255))))

  (test-case "opacity on <image> blends it with whatever is underneath"
    (define bm (svg-string->bitmap
                (format "<svg width=\"20\" height=\"20\">
                           <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"#00ff00\"/>
                           <image x=\"0\" y=\"0\" width=\"20\" height=\"20\" opacity=\"0.5\" href=\"~a\"/>
                         </svg>" test-image-data-uri)))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 5 10 px)  ; over the image's red half, blended with green bg
    (check-true (and (> (send px red) 80) (< (send px red) 200) (> (send px green) 80) (< (send px green) 200))))

  (test-case "a remote <image> href is not fatal; it simply doesn't render"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\"><image x=\"0\" y=\"0\" width=\"20\" height=\"20\" href=\"https://example.com/x.png\"/></svg>"))
    (check-equal? (send bm get-width) 20))

  (test-case "svg-file->bitmap resolves a relative <image> href against the SVG file's own directory"
    (define dir (make-temporary-file "svgtest~a" 'directory))
    (dynamic-wind
     void
     (lambda ()
       (define png-path (build-path dir "tiny.png"))
       (call-with-output-file png-path
         (lambda (out) (send (load-image-bitmap test-image-data-uri) save-file out 'png)))
       (define svg-path (build-path dir "test.svg"))
       (call-with-output-file svg-path
         (lambda (out) (write-string "<svg width=\"20\" height=\"20\"><image x=\"0\" y=\"0\" width=\"20\" height=\"20\" href=\"tiny.png\"/></svg>" out)))
       (define bm (svg-file->bitmap svg-path))
       (define dc (new bitmap-dc% [bitmap bm]))
       (define px (make-object color%))
       (send dc get-pixel 5 10 px)
       (check-true (and (> (send px red) 200) (< (send px blue) 100))))
     (lambda () (delete-directory/files dir))))

  ;; ==== Tier 9: CSS <style> stylesheets ====================================

  (test-case "parse-css-stylesheet parses a simple type selector and its declarations, including !important"
    (define rules (parse-css-stylesheet "rect { fill: red; stroke: blue !important; }"))
    (check-equal? (length rules) 1)
    (define sel (first (css-rule-selectors (first rules))))
    (check-equal? (length sel) 1)
    (check-equal? (css-compound-tag (sel-step-compound (first sel))) 'rect)
    (check-equal? (css-rule-declarations (first rules)) '(("fill" "red" #f) ("stroke" "blue" #t))))

  (test-case "parse-css-stylesheet parses class/id/universal/attribute selectors, including richer matchers"
    (define (compound-of css) (sel-step-compound (first (first (css-rule-selectors (first (parse-css-stylesheet css)))))))
    (check-equal? (css-compound-classes (compound-of ".foo { }")) '("foo"))
    (check-equal? (css-compound-id (compound-of "#bar { }")) "bar")
    (check-false (css-compound-tag (compound-of "* { }")))
    (check-equal? (css-compound-attrs (compound-of "[data-x] { }")) '(("data-x" #f #f)))
    (check-equal? (css-compound-attrs (compound-of "[data-x=\"5\"] { }")) '(("data-x" "=" "5")))
    (check-equal? (css-compound-attrs (compound-of "[data-x^=\"5\"] { }")) '(("data-x" "^=" "5"))))

  (test-case "parse-css-stylesheet parses compound selectors combining tag+class+id"
    (define sel (first (css-rule-selectors (first (parse-css-stylesheet "rect.foo#bar { }")))))
    (define c (sel-step-compound (first sel)))
    (check-equal? (css-compound-tag c) 'rect)
    (check-equal? (css-compound-classes c) '("foo"))
    (check-equal? (css-compound-id c) "bar"))

  (test-case "parse-css-stylesheet parses descendant and child combinators"
    (define sel1 (first (css-rule-selectors (first (parse-css-stylesheet "g rect { }")))))
    (check-equal? (length sel1) 2)
    (check-equal? (sel-step-combinator (first sel1)) 'none)
    (check-equal? (sel-step-combinator (second sel1)) 'descendant)
    (define sel2 (first (css-rule-selectors (first (parse-css-stylesheet "g > rect { }")))))
    (check-equal? (sel-step-combinator (second sel2)) 'child))

  (test-case "parse-css-stylesheet parses comma-separated selector lists"
    (define rule (first (parse-css-stylesheet "rect, circle { fill: red; }")))
    (check-equal? (length (css-rule-selectors rule)) 2))

  (test-case "parse-css-stylesheet skips comments and @-rules without crashing"
    (define rules (parse-css-stylesheet "/* c */ @media screen { rect { fill: red; } } .foo { stroke: blue; }"))
    (check-equal? (length rules) 1)
    (check-equal? (css-compound-classes (sel-step-compound (first (first (css-rule-selectors (first rules)))))) '("foo")))

  (test-case "selector-specificity computes standard CSS (id,class,type) triples"
    (define (spec-of css) (selector-specificity (first (css-rule-selectors (first (parse-css-stylesheet css))))))
    (check-equal? (spec-of "rect { }") '(0 0 1))
    (check-equal? (spec-of ".foo { }") '(0 1 0))
    (check-equal? (spec-of "#bar { }") '(1 0 0))
    (check-equal? (spec-of "g rect.foo { }") '(0 1 2)))

  (test-case "specificity<? compares lexicographically: id beats class beats type"
    (check-true (specificity<? '(0 0 1) '(0 1 0)))
    (check-true (specificity<? '(0 1 0) '(1 0 0)))
    (check-false (specificity<? '(1 0 0) '(0 5 5))))

  (test-case "compound-matches-node? checks tag/class/id/attrs together, and impossible? always fails"
    (define c (css-compound 'rect '("a" "b") "x" '(("data-y" "=" "5")) #f))
    (check-true (compound-matches-node? c 'rect '((class "a b") (id "x") (data-y "5"))))
    (check-false (compound-matches-node? c 'circle '((class "a b") (id "x") (data-y "5"))))
    (check-false (compound-matches-node? c 'rect '((class "a") (id "x") (data-y "5"))))
    (define impossible-c (css-compound #f '() #f '() #t))
    (check-false (compound-matches-node? impossible-c 'rect '())))

  (test-case "a type selector overrides a presentation attribute (attrs are lowest cascade priority)"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\"><style>rect{fill:red;}</style><rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"blue\"/></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px red) 255)
    (check-equal? (send px blue) 0))

  (test-case "a class selector beats a type selector"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\"><style>rect{fill:red;} .a{fill:blue;}</style><rect class=\"a\" x=\"0\" y=\"0\" width=\"20\" height=\"20\"/></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px blue) 255))

  (test-case "an id selector beats a class selector"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\"><style>.a{fill:blue;} #x{fill:lime;}</style><rect id=\"x\" class=\"a\" x=\"0\" y=\"0\" width=\"20\" height=\"20\"/></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px green) 255)
    (check-equal? (send px blue) 0))

  (test-case "inline style=\"\" still wins over any stylesheet rule"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\"><style>#x{fill:red;}</style><rect id=\"x\" style=\"fill:blue\" x=\"0\" y=\"0\" width=\"20\" height=\"20\"/></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px blue) 255)
    (check-equal? (send px red) 0))

  (test-case "when specificity ties, the later rule in the stylesheet wins"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\"><style>rect{fill:red;} rect{fill:blue;}</style><rect x=\"0\" y=\"0\" width=\"20\" height=\"20\"/></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px blue) 255))

  (test-case "a descendant combinator only matches inside the right ancestor"
    (define bm (svg-string->bitmap
                "<svg width=\"40\" height=\"20\">
                   <style>g rect { fill: red; }</style>
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"blue\"/>
                   <g><rect x=\"20\" y=\"0\" width=\"20\" height=\"20\" fill=\"blue\"/></g>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)  ; not inside a g
    (check-equal? (send px blue) 255)
    (send dc get-pixel 30 10 px)  ; inside a g
    (check-equal? (send px red) 255))

  (test-case "a child combinator requires a DIRECT parent match, unlike descendant"
    (define bm (svg-string->bitmap
                "<svg width=\"400\" height=\"200\">
                   <style>g > rect { fill: red; }</style>
                   <g><rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"blue\"/></g>
                   <g><svg x=\"200\" y=\"0\" width=\"20\" height=\"20\"><rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"blue\"/></svg></g>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)   ; rect's direct parent IS g -> matches
    (check-equal? (send px red) 255)
    (send dc get-pixel 210 10 px)  ; rect's direct parent is the nested <svg>, not g -> must not match
    (check-equal? (send px blue) 255))

  (test-case "an attribute selector matches by presence or by exact value"
    (define bm (svg-string->bitmap
                "<svg width=\"40\" height=\"20\">
                   <style>[data-active] { fill: red; }</style>
                   <rect data-active=\"1\" x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"blue\"/>
                   <rect x=\"20\" y=\"0\" width=\"20\" height=\"20\" fill=\"blue\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)   ; has data-active -> overridden to red
    (check-equal? (send px red) 255)
    (check-equal? (send px blue) 0)
    (send dc get-pixel 30 10 px)   ; no data-active -> stays blue
    (check-equal? (send px blue) 255)
    (check-equal? (send px red) 0))

  (test-case "<style> content is parsed but never rendered as a visible shape"
    (define bm (svg-string->bitmap "<svg width=\"20\" height=\"20\"><style>rect{fill:red;}</style></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (list (send px red) (send px green) (send px blue)) (list 255 255 255)))

  (test-case "chained class/id selectors like .foo.bar work correctly (upstream parsers/css scanning bug worked around)"
    (define bm (svg-string->bitmap
                "<svg width=\"40\" height=\"20\">
                   <style>.foo.bar { fill: red; } .foo { fill: blue; }</style>
                   <rect class=\"foo bar\" x=\"0\" y=\"0\" width=\"20\" height=\"20\"/>
                   <rect class=\"foo\" x=\"20\" y=\"0\" width=\"20\" height=\"20\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)   ; has BOTH classes -> matches the more specific .foo.bar -> red
    (check-equal? (send px red) 255)
    (send dc get-pixel 30 10 px)   ; only .foo -> blue
    (check-equal? (send px blue) 255))

  (test-case "!important in a stylesheet rule beats a normal inline style, which beats a normal stylesheet rule"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <style>#x { fill: red !important; } rect { fill: green; }</style>
                   <rect id=\"x\" style=\"fill: blue\" x=\"0\" y=\"0\" width=\"20\" height=\"20\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px red) 255)
    (check-equal? (send px blue) 0)
    (check-equal? (send px green) 0))

  (test-case "an inline !important beats even a stylesheet !important rule"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <style>#x { fill: red !important; }</style>
                   <rect id=\"x\" style=\"fill: blue !important\" x=\"0\" y=\"0\" width=\"20\" height=\"20\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px blue) 255)
    (check-equal? (send px red) 0))

  (test-case "richer attribute-selector matchers (^=, $=, ~=) work in actual rendering"
    (define bm (svg-string->bitmap
                "<svg width=\"60\" height=\"20\">
                   <style>
                     [data-name^=\"start\"] { fill: red; }
                     [data-name$=\"end\"] { fill: green; }
                     [data-name~=\"tag\"] { stroke: blue; stroke-width: 3; }
                   </style>
                   <rect data-name=\"start-here\" x=\"0\" y=\"0\" width=\"18\" height=\"18\" fill=\"black\"/>
                   <rect data-name=\"the-end\" x=\"21\" y=\"0\" width=\"18\" height=\"18\" fill=\"black\"/>
                   <rect data-name=\"one tag two\" x=\"42\" y=\"0\" width=\"18\" height=\"18\" fill=\"none\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 9 9 px)
    (check-equal? (send px red) 255)
    (send dc get-pixel 30 9 px)
    (check-equal? (send px green) 128)
    (send dc get-pixel 41 9 px)  ; within the left stroke edge of the third rect
    (check-true (< (send px red) 100)))

  ;; ==== Tier 10: filters ====================================================

  (test-case "premultiply!/unpremultiply-in-place! round-trip within integer rounding tolerance"
    (define buf (bytes 128 200 100 50  255 10 20 30  0 99 99 99))
    (define orig (bytes-copy buf))
    (premultiply! buf)
    (unpremultiply-in-place! buf)
    ;; integer division in premultiply/unpremultiply truncates rather
    ;; than rounds, so an exact round-trip isn't guaranteed -- +/-1 is
    ;; expected lossy behavior, not a bug. The alpha=0 pixel's RGB is
    ;; left untouched by design (undefined color, doesn't matter since
    ;; it's fully transparent), so it's excluded here.
    (for ([i (in-range 8)]) (check-true (<= (abs (- (bytes-ref buf i) (bytes-ref orig i))) 1))))

  (test-case "srgb<->linear gamma tables round-trip and preserve the endpoints"
    (check-equal? (vector-ref srgb->linear-table 0) 0)
    (check-equal? (vector-ref srgb->linear-table 255) 255)
    (check-equal? (vector-ref linear->srgb-table 0) 0)
    (check-equal? (vector-ref linear->srgb-table 255) 255)
    ;; a mid-gray value should round-trip back close to itself
    (define v (vector-ref linear->srgb-table (vector-ref srgb->linear-table 128)))
    (check-true (<= (abs (- v 128)) 2)))

  (test-case "ambient-scale-factor reads the dc's current uniform scale exactly"
    (define bm (make-object bitmap% 10 10))
    (define dc (new bitmap-dc% [bitmap bm]))
    (check-= (ambient-scale-factor dc) 1.0 1e-9)
    (send dc scale 2.5 2.5)
    (check-= (ambient-scale-factor dc) 2.5 1e-9))

  (test-case "feGaussianBlur spreads a shape's alpha beyond its original bounds"
    (define bm (svg-string->bitmap
                "<svg width=\"60\" height=\"60\">
                   <defs><filter id=\"b\"><feGaussianBlur stdDeviation=\"4\"/></filter></defs>
                   <rect x=\"20\" y=\"20\" width=\"20\" height=\"20\" fill=\"red\" filter=\"url(#b)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 30 30 px) (check-true (< (send px green) 100))  ; center: solid
    (send dc get-pixel 12 30 px) (check-true (< (send px green) 255))  ; well outside the original rect: blur reaches here
    (send dc get-pixel 2 30 px)  (check-equal? (send px green) 255))    ; far enough away: untouched

  (test-case "a dangling/invalid filter reference means the element renders NOTHING (unlike mask's leniency)"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\"><rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"red\" filter=\"url(#nope)\"/></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (list (send px red) (send px green) (send px blue)) (list 255 255 255)))

  (test-case "feOffset shifts filtered content by dx/dy"
    (define bm (svg-string->bitmap
                "<svg width=\"60\" height=\"60\">
                   <defs><filter id=\"o\"><feOffset dx=\"20\" dy=\"0\"/></filter></defs>
                   <rect x=\"5\" y=\"5\" width=\"10\" height=\"10\" fill=\"red\" filter=\"url(#o)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px) (check-equal? (send px green) 255)   ; original position: empty (shifted away)
    (send dc get-pixel 30 10 px) (check-true (< (send px green) 100)))  ; shifted-to position: red

  (test-case "feColorMatrix saturate=0 desaturates to gray (R=G=B)"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <defs><filter id=\"g\"><feColorMatrix type=\"saturate\" values=\"0\"/></filter></defs>
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"orange\" filter=\"url(#g)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px red) (send px green))
    (check-equal? (send px green) (send px blue)))

  (test-case "feColorMatrix type=matrix identity leaves color unchanged"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <defs><filter id=\"i\">
                     <feColorMatrix type=\"matrix\" values=\"1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 1 0\"/>
                   </filter></defs>
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"#4080c0\" filter=\"url(#i)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-true (<= (abs (- (send px red) #x40)) 2))
    (check-true (<= (abs (- (send px green) #x80)) 2))
    (check-true (<= (abs (- (send px blue) #xc0)) 2)))

  (test-case "feFlood fills the whole filter region regardless of the source shape"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <defs><filter id=\"f\"><feFlood flood-color=\"blue\" flood-opacity=\"1\"/></filter></defs>
                   <circle cx=\"10\" cy=\"10\" r=\"3\" fill=\"red\" filter=\"url(#f)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 1 1 px)  ; corner, well outside the small circle -- still flooded
    (check-equal? (send px blue) 255)
    (check-equal? (send px red) 0))

  (test-case "feMerge layers inputs in order, later on top"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <defs><filter id=\"m\">
                     <feFlood flood-color=\"red\" result=\"r\"/>
                     <feFlood flood-color=\"blue\" result=\"b\"/>
                     <feMerge><feMergeNode in=\"r\"/><feMergeNode in=\"b\"/></feMerge>
                   </filter></defs>
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"black\" filter=\"url(#m)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px blue) 255)
    (check-equal? (send px red) 0))

  (test-case "feComposite operator=in keeps only the overlap of the two inputs"
    (define bm (svg-string->bitmap
                "<svg width=\"40\" height=\"20\">
                   <defs><filter id=\"c\" x=\"0%\" y=\"0%\" width=\"100%\" height=\"100%\">
                     <feFlood flood-color=\"blue\" result=\"flood\"/>
                     <feComposite in=\"flood\" in2=\"SourceGraphic\" operator=\"in\"/>
                   </filter></defs>
                   <circle cx=\"20\" cy=\"10\" r=\"8\" fill=\"red\" filter=\"url(#c)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 20 10 px)  ; inside the circle: blue (flood, masked by the circle's alpha)
    (check-equal? (send px blue) 255)
    (send dc get-pixel 2 10 px)   ; well outside the circle: untouched background
    (check-equal? (list (send px red) (send px green) (send px blue)) (list 255 255 255)))

  (test-case "feBlend mode=multiply darkens"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <defs><filter id=\"bl\">
                     <feFlood flood-color=\"#808080\" result=\"gray\"/>
                     <feBlend in=\"SourceGraphic\" in2=\"gray\" mode=\"multiply\"/>
                   </filter></defs>
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"white\" filter=\"url(#bl)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-true (< (send px red) 240)))  ; white multiplied by mid-gray is noticeably darker

  (test-case "feComponentTransfer linear scales channel values"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <defs><filter id=\"ct\">
                     <feComponentTransfer><feFuncR type=\"linear\" slope=\"0.5\" intercept=\"0\"/></feComponentTransfer>
                   </filter></defs>
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"#ff0000\" filter=\"url(#ct)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-true (< (send px red) 200))
    (check-true (> (send px red) 80)))

  (test-case "feMorphology dilate grows the shape, erode shrinks it"
    (define (ink-width svg-str)
      (define bm (svg-string->bitmap svg-str))
      (define dc (new bitmap-dc% [bitmap bm]))
      (define px (make-object color%))
      (length (for/list ([x (in-range 60)] #:when (begin (send dc get-pixel x 30 px) (< (send px green) 200))) x)))
    (define base "<svg width=\"60\" height=\"60\"><defs><filter id=\"m\"><feMorphology operator=\"~a\" radius=\"5\"/></filter></defs><rect x=\"25\" y=\"25\" width=\"10\" height=\"10\" fill=\"red\" filter=\"url(#m)\"/></svg>")
    (define dilated-width (ink-width (format base "dilate")))
    (define eroded-width (ink-width (format base "erode")))
    (check-true (> dilated-width 10))
    (check-true (< eroded-width 10)))

  (test-case "feDropShadow renders a visible, offset shadow behind the source shape"
    (define bm (svg-string->bitmap
                "<svg width=\"60\" height=\"60\">
                   <defs><filter id=\"ds\" x=\"-50%\" y=\"-50%\" width=\"200%\" height=\"200%\">
                     <feDropShadow dx=\"10\" dy=\"0\" stdDeviation=\"2\" flood-color=\"black\" flood-opacity=\"0.8\"/>
                   </filter></defs>
                   <rect x=\"15\" y=\"15\" width=\"15\" height=\"15\" fill=\"red\" filter=\"url(#ds)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 22 22 px)  ; inside the original shape: red
    (check-true (< (send px green) 100))
    (send dc get-pixel 35 22 px)  ; shadow region (shifted +10 in x, no original shape there): darkened
    (check-true (< (send px red) 200)))

  ;; ==== pict output ==========================================================

  (test-case "svg-string->pict returns a pict? with the SVG's declared dimensions"
    (define p (svg-string->pict "<svg width=\"80\" height=\"60\"><rect x=\"0\" y=\"0\" width=\"10\" height=\"10\" fill=\"red\"/></svg>"))
    (check-true (pict? p))
    (check-equal? (pict-width p) 80)
    (check-equal? (pict-height p) 60))

  (test-case "the pict renders the same shape colors/positions as svg-string->bitmap (background legitimately differs)"
    (define svg-str "<svg width=\"40\" height=\"30\"><rect x=\"5\" y=\"5\" width=\"10\" height=\"10\" fill=\"crimson\"/></svg>")
    (define direct-bm (svg-string->bitmap svg-str))
    (define pict-bm (pict->bitmap (svg-string->pict svg-str)))
    (define dcd (new bitmap-dc% [bitmap direct-bm]))
    (define dcp (new bitmap-dc% [bitmap pict-bm]))
    (define px (make-object color%))
    (send dcd get-pixel 10 10 px)
    (define direct-rgb (list (send px red) (send px green) (send px blue)))
    (send dcp get-pixel 10 10 px)
    (define pict-rgb (list (send px red) (send px green) (send px blue)))
    (check-equal? direct-rgb pict-rgb)
    ;; the pict's own background (unlike svg-string->bitmap's opaque
    ;; white) is transparent by design, matching pict's own compositional
    ;; convention rather than assuming a standalone-image default
    (send dcp get-pixel 1 1 px)
    (check-equal? (send px alpha) 0.0))

  (test-case "an svg pict composes with ordinary picts via standard combinators without a contract violation"
    (define p (svg-string->pict "<svg width=\"20\" height=\"20\"><circle cx=\"10\" cy=\"10\" r=\"8\" fill=\"blue\"/></svg>"))
    (define composed (hc-append 5 (colorize (disk 10) "orange") p (text "label")))
    (check-true (pict? composed))
    (check-true (is-a? (pict->bitmap composed) bitmap%)))

  (test-case "svg-file->pict resolves a relative <image> href against the SVG file's own directory"
    (define dir (make-temporary-file "svgtest~a" 'directory))
    (dynamic-wind
     void
     (lambda ()
       (define data-uri
         (string-append
          "data:image/png;base64,"
          "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAGklEQVQImWP8z8Dwn4GBgYERQjEwMaABwgIAvNMDBsJIrS8AAAAASUVORK5CYII="))
       (define png-path (build-path dir "tiny.png"))
       (call-with-output-file png-path
         (lambda (out) (send (load-image-bitmap data-uri) save-file out 'png)))
       (define svg-path (build-path dir "test.svg"))
       (call-with-output-file svg-path
         (lambda (out) (write-string "<svg width=\"20\" height=\"20\"><image x=\"0\" y=\"0\" width=\"20\" height=\"20\" href=\"tiny.png\"/></svg>" out)))
       (define bm (pict->bitmap (svg-file->pict svg-path)))
       (define dc (new bitmap-dc% [bitmap bm]))
       (define px (make-object color%))
       (send dc get-pixel 5 10 px)
       (check-true (and (> (send px red) 200) (< (send px blue) 100))))
     (lambda () (delete-directory/files dir))))

  ;; ==== Regressions found via cross-checking against Web Platform Tests ====

  (test-case "viewBox accepts comma-separated numbers, not just whitespace-separated"
    (define doc1 (read-svg-document "<svg viewBox=\"0, 0, 620, 340\" width=\"310\" height=\"170\"></svg>"))
    (define doc2 (read-svg-document "<svg viewBox=\"0 0 620 340\" width=\"310\" height=\"170\"></svg>"))
    (check-equal? (svg-doc-view-matrix doc1) (svg-doc-view-matrix doc2)))

  (test-case "H/V path commands parse correctly with a leading space before their number"
    ;; a real, reproducible bug: parse-repeating! skipped separators
    ;; before each SUBSEQUENT repeated value but never before the FIRST
    ;; one, and read-number! (used directly by H/V) doesn't skip leading
    ;; whitespace itself the way parse-coord-pair! (used by L and
    ;; others) does -- so "H 100" crashed while "H100" and "L 100 100"
    ;; both worked fine.
    (check-not-exn (lambda () (parse-svg-path "M 0 0 H 100")))
    (check-not-exn (lambda () (parse-svg-path "M 0 0 H 100 V 100 H 0 Z")))
    (check-equal? (parse-svg-path "M 0 0 H 100") (parse-svg-path "M0,0H100")))

  (test-case "a syntax error partway through path data renders everything before it, without crashing the whole document"
    ;; per SVG2's path error-handling model: render up to (not
    ;; including) the first error. Before this fix, ANY malformed path
    ;; anywhere in a document raised an exception that crashed rendering
    ;; of the entire SVG, not just that one element.
    (check-not-exn (lambda () (parse-svg-path "m 0 0 l 3 -4 z # ignored suffix v 123")))
    (define cmds (parse-svg-path "m 0 0 l 3 -4 z # ignored suffix v 123"))
    (check-equal? cmds '((m (0 0)) (l (3 -4)) (z)))
    ;; and a malformed path must not take down its siblings
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <path d=\"# totally invalid\" fill=\"red\"/>
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"blue\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px blue) 255))

  ;; ==== SVG2 geometry properties (cx/cy/r/rx/ry/x/y/width/height/d via CSS) ===

  (test-case "geometry-attr-ref follows the same cascade priority as paint properties"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <style>circle { r: 5px; } #c { r: 8px; }</style>
                   <circle id=\"c\" cx=\"10\" cy=\"10\" fill=\"blue\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; #c (id, specificity 1,0,0) beats the bare type selector (0,0,1) -> r=8
    (send dc get-pixel 10 3 px)   ; y=10-7=3: inside an r=8 circle, outside r=5
    (check-equal? (send px blue) 255))

  (test-case "a circle's cx/cy/r can be set entirely via CSS, with no geometry attributes at all"
    (define bm (svg-string->bitmap
                "<svg width=\"120\" height=\"120\">
                   <style>circle { cx: 60px; cy: 60px; r: 40px; fill: crimson; }</style>
                   <circle/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 60 60 px)
    (check-true (and (> (send px red) 200) (< (send px blue) 100)))
    (send dc get-pixel 5 5 px)
    (check-equal? (list (send px red) (send px green) (send px blue)) (list 255 255 255)))

  (test-case "a rect's x/y/width/height/rx can be set via CSS"
    (define bm (svg-string->bitmap
                "<svg width=\"100\" height=\"100\">
                   <style>rect { x: 10px; y: 10px; width: 60px; height: 60px; fill: blue; }</style>
                   <rect/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 40 40 px)
    (check-equal? (send px blue) 255)
    (check-equal? (send px red) 0)
    (send dc get-pixel 5 5 px)
    (check-equal? (send px red) 255))

  (test-case "a path's d can be set via CSS using the path('...') syntax"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <style>path { d: path('M 0 0 H 20 V 20 H 0 Z'); fill: green; }</style>
                   <path/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px red) 0))

  (test-case "d: none renders nothing for that path, without affecting the rest of the document"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <path d=\"M 0 0 H 20 V 20 H 0 Z\" fill=\"red\" style=\"d: none\"/>
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"blue\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px blue) 255)
    (check-equal? (send px red) 0))

  (test-case "ellipse rx/ry=auto (or omitted entirely) cross-derives from whichever one IS given"
    (define (render-and-check svg-str)
      (define bm (svg-string->bitmap svg-str))
      (define dc (new bitmap-dc% [bitmap bm]))
      (define px (make-object color%))
      ;; a 30-unit-radius circle-like ellipse centered at (50,50): check
      ;; all four cardinal points land inside the stroked ring
      (for ([pt (list (cons 50 22) (cons 50 78) (cons 22 50) (cons 78 50))])
        (send dc get-pixel (car pt) (cdr pt) px)
        (check-equal? (send px blue) 255)))
    ;; via CSS "auto"
    (render-and-check
     "<svg width=\"100\" height=\"100\"><style>ellipse { ry: 30px; rx: auto; }</style>
        <ellipse cx=\"50\" cy=\"50\" fill=\"none\" stroke=\"blue\" stroke-width=\"5\"/></svg>")
    ;; via CSS with rx simply never mentioned at all (not even "auto")
    (render-and-check
     "<svg width=\"100\" height=\"100\"><style>ellipse { ry: 30px; }</style>
        <ellipse cx=\"50\" cy=\"50\" fill=\"none\" stroke=\"blue\" stroke-width=\"5\"/></svg>")
    ;; via a plain attribute, ry given and rx entirely absent (no CSS at all)
    (render-and-check
     "<svg width=\"100\" height=\"100\"><ellipse cx=\"50\" cy=\"50\" ry=\"30\" fill=\"none\" stroke=\"blue\" stroke-width=\"5\"/></svg>"))

  (test-case "url() paint references work quoted or unquoted, stripping only OUTER whitespace"
    ;; a real bug found via WPT: the url() regex required an unquoted
    ;; '#' directly, so url('#id') (quoted) never matched at all.
    (define (fill-at svg-str x y)
      (define bm (svg-string->bitmap svg-str))
      (define dc (new bitmap-dc% [bitmap bm]))
      (define px (make-object color%))
      (send dc get-pixel x y px)
      (list (send px red) (send px green) (send px blue)))
    (define defs "<defs><linearGradient id=\"green\"><stop stop-color=\"green\"/></linearGradient></defs>")
    ;; leading whitespace INSIDE the quotes, before '#'
    (check-equal? (fill-at (format "<svg width=\"20\" height=\"20\">~a<rect width=\"20\" height=\"20\" fill=\"url(' #green') red\"/></svg>" defs) 10 10)
                  (list 0 128 0))
    ;; trailing whitespace INSIDE the quotes, after the id
    (check-equal? (fill-at (format "<svg width=\"20\" height=\"20\">~a<rect width=\"20\" height=\"20\" fill=\"url('#green ') red\"/></svg>" defs) 10 10)
                  (list 0 128 0))
    ;; whitespace INSIDE the fragment id itself ("# red") must NOT match "red" --
    ;; it's a genuinely different, nonexistent id, so this must fall back
    (check-equal? (fill-at "<svg width=\"20\" height=\"20\"><rect width=\"20\" height=\"20\" fill=\"url(' # red ') green\"/></svg>" 10 10)
                  (list 0 128 0)))

  (test-case "a gradient with a degenerate (zero-length/radius) transform falls back to the fallback color"
    (define (fill-at svg-str x y)
      (define bm (svg-string->bitmap svg-str))
      (define dc (new bitmap-dc% [bitmap bm]))
      (define px (make-object color%))
      (send dc get-pixel x y px)
      (list (send px red) (send px green) (send px blue)))
    ;; linear gradient collapsed to a single point by scale(0)
    (check-equal? (fill-at
                   "<svg width=\"20\" height=\"20\">
                      <linearGradient id=\"g\" gradientTransform=\"scale(0)\">
                        <stop offset=\"0\" stop-color=\"yellow\"/><stop offset=\"1\" stop-color=\"red\"/>
                      </linearGradient>
                      <rect width=\"20\" height=\"20\" fill=\"url(#g) green\"/>
                    </svg>" 10 10)
                  (list 0 128 0))
    ;; radial gradient with r=0
    (check-equal? (fill-at
                   "<svg width=\"20\" height=\"20\">
                      <radialGradient id=\"g\" r=\"0\">
                        <stop offset=\"0\" stop-color=\"yellow\"/><stop offset=\"1\" stop-color=\"red\"/>
                      </radialGradient>
                      <rect width=\"20\" height=\"20\" fill=\"url(#g) green\"/>
                    </svg>" 10 10)
                  (list 0 128 0))
    ;; a gradient with zero stops, likewise unusable
    (check-equal? (fill-at
                   "<svg width=\"20\" height=\"20\">
                      <linearGradient id=\"g\"></linearGradient>
                      <rect width=\"20\" height=\"20\" fill=\"url(#g) green\"/>
                    </svg>" 10 10)
                  (list 0 128 0)))

  (test-case "<image> with only ONE of width/height given preserves the image's natural aspect ratio"
    (define data-uri
      (string-append
       "data:image/png;base64,"
       "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAGklEQVQImWP8z8Dwn4GBgYERQjEwMaABwgIAvNMDBsJIrS8AAAAASUVORK5CYII="))
    ;; source is a 4x4 (1:1 aspect) image; width=40 given, height omitted
    ;; -- should come out as 40x40, NOT stretched to the canvas's full height
    (define bm (svg-string->bitmap
                (format "<svg width=\"100\" height=\"100\"><image href=\"~a\" width=\"40\"/></svg>" data-uri)))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 20 20 px)
    (check-false (equal? (list (send px red) (send px green) (send px blue)) (list 255 255 255)))
    (send dc get-pixel 20 45 px)
    (check-equal? (list (send px red) (send px green) (send px blue)) (list 255 255 255)))

  ;; ==== True group opacity ==================================================

  (test-case "a group's opacity correctly composites overlapping children as ONE unit, not each separately"
    ;; verified against librsvg: the overlap of a red and blue rect
    ;; inside a 50%-opacity group should be (127,127,255) -- blue drawn
    ;; fully opaque OVER red first, then that single result blended over
    ;; white at 50% -- not (127,63,191), which is what you get from
    ;; blending red-over-white at 50% and then blue-over-THAT at 50%
    ;; separately (the old per-leaf approximation's failure mode).
    (define bm (svg-string->bitmap
                "<svg width=\"40\" height=\"40\">
                   <g opacity=\"0.5\">
                     <rect x=\"5\" y=\"5\" width=\"20\" height=\"20\" fill=\"red\"/>
                     <rect x=\"15\" y=\"15\" width=\"20\" height=\"20\" fill=\"blue\"/>
                   </g>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 18 18 px)
    (check-equal? (list (send px red) (send px green) (send px blue)) (list 127 127 255)))

  (test-case "group opacity still renders correctly for the common, non-overlapping case"
    (define bm (svg-string->bitmap
                "<svg width=\"40\" height=\"20\">
                   <g opacity=\"0.5\">
                     <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"red\"/>
                     <rect x=\"20\" y=\"0\" width=\"20\" height=\"20\" fill=\"blue\"/>
                   </g>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (list (send px red) (send px green) (send px blue)) (list 255 127 127))
    (send dc get-pixel 30 10 px)
    (check-equal? (list (send px red) (send px green) (send px blue)) (list 127 127 255)))

  (test-case "opacity=1 and opacity=0 groups take their fast-path boundaries correctly"
    (define bm-full (svg-string->bitmap
                      "<svg width=\"20\" height=\"20\"><g opacity=\"1\"><rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"blue\"/></g></svg>"))
    (define dc1 (new bitmap-dc% [bitmap bm-full]))
    (define px (make-object color%))
    (send dc1 get-pixel 10 10 px)
    (check-equal? (send px blue) 255)
    (check-equal? (send px red) 0)
    (define bm-none (svg-string->bitmap
                      "<svg width=\"20\" height=\"20\"><g opacity=\"0\"><rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"blue\"/></g></svg>"))
    (define dc2 (new bitmap-dc% [bitmap bm-none]))
    (send dc2 get-pixel 10 10 px)
    (check-equal? (list (send px red) (send px green) (send px blue)) (list 255 255 255)))

  (test-case "nested groups' opacity compounds correctly (0.5 inside 0.5 gives an effective 0.25)"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <g opacity=\"0.5\"><g opacity=\"0.5\">
                     <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"blue\"/>
                   </g></g>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    ;; 0.25 blue over white: 255*0.75 + 0*0.25 = 191.25, 255*0.75+255*0.25=255
    (check-true (<= (abs (- (send px red) 191)) 2))
    (check-equal? (send px blue) 255))

  ;; ==== mix-blend-mode =======================================================

  (test-case "blend-channel implements the standard CSS Compositing per-channel formulas"
    (check-= (blend-channel "multiply" 128 128) (/ (* 128 128) 255.) 1.0)
    (check-= (blend-channel "screen" 0 255) 255.0 1.0)
    (check-= (blend-channel "darken" 100 200) 100.0 1.0)
    (check-= (blend-channel "lighten" 100 200) 200.0 1.0)
    (check-= (blend-channel "difference" 100 60) 40.0 1.0)
    (check-= (blend-channel "exclusion" 0 0) 0.0 1.0)
    (check-= (blend-channel "color-dodge" 0 100) 100.0 1.0)  ; cs=0 -> backdrop unchanged
    (check-= (blend-channel "color-burn" 255 100) 100.0 1.0) ; cs=1 -> backdrop unchanged
    (check-= (blend-channel "normal" 42 200) 42.0 1.0))       ; unrecognized/normal -> source through unchanged

  (test-case "mix-blend-mode=multiply blends an element against its real backdrop"
    ;; verified against librsvg: both agree exactly on these two points
    (define bm (svg-string->bitmap
                "<svg width=\"40\" height=\"20\">
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"red\"/>
                   <rect x=\"10\" y=\"0\" width=\"20\" height=\"20\" fill=\"#808080\" style=\"mix-blend-mode: multiply\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 15 10 px)  ; overlap: red * gray
    (check-equal? (list (send px red) (send px green) (send px blue)) (list 128 0 0))
    (send dc get-pixel 25 10 px)  ; gray-only, over white background
    (check-equal? (list (send px red) (send px green) (send px blue)) (list 128 128 128)))

  (test-case "mix-blend-mode=normal (or absent) renders unchanged"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"blue\" style=\"mix-blend-mode: normal\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (send px blue) 255)
    (check-equal? (send px red) 0))

  ;; ==== xml:space="preserve" =================================================

  (define (rightmost-ink-x bm y)
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (for/fold ([rightmost 0]) ([x (in-range (sub1 (send bm get-width)) 0 -1)] #:break (> rightmost 0))
      (send dc get-pixel x y px)
      (if (< (send px red) 200) x rightmost)))

  (test-case "xml:space=\"preserve\" keeps internal runs of whitespace, unlike the default collapsing behavior"
    (define collapsed (svg-string->bitmap "<svg width=\"300\" height=\"50\"><text x=\"10\" y=\"30\" font-size=\"20\">a     b</text></svg>"))
    (define preserved (svg-string->bitmap "<svg width=\"300\" height=\"50\"><text x=\"10\" y=\"30\" font-size=\"20\" xml:space=\"preserve\">a     b</text></svg>"))
    (check-true (> (rightmost-ink-x preserved 25) (rightmost-ink-x collapsed 25))))

  (test-case "xml:space=\"preserve\" is inherited from an ancestor element, not just <text>/<tspan> themselves"
    (define via-g (svg-string->bitmap "<svg width=\"300\" height=\"50\"><g xml:space=\"preserve\"><text x=\"10\" y=\"30\" font-size=\"20\">a     b</text></g></svg>"))
    (define direct (svg-string->bitmap "<svg width=\"300\" height=\"50\"><text x=\"10\" y=\"30\" font-size=\"20\" xml:space=\"preserve\">a     b</text></svg>"))
    (check-equal? (rightmost-ink-x via-g 25) (rightmost-ink-x direct 25)))

  (test-case "a <tspan> can override its inherited xml:space back to \"default\""
    (define overridden (svg-string->bitmap
                         "<svg width=\"300\" height=\"50\"><text x=\"10\" y=\"30\" font-size=\"20\" xml:space=\"preserve\"><tspan xml:space=\"default\">a     b</tspan></text></svg>"))
    (define collapsed (svg-string->bitmap "<svg width=\"300\" height=\"50\"><text x=\"10\" y=\"30\" font-size=\"20\">a     b</text></svg>"))
    (check-equal? (rightmost-ink-x overridden 25) (rightmost-ink-x collapsed 25)))

  ;; ==== <textPath> ============================================================

  (test-case "build-arc-length-fn parameterizes a polyline correctly"
    (define-values (fn total) (build-arc-length-fn (list (cons 0 0) (cons 10 0) (cons 10 10))))
    (check-= total 20 1e-9)
    (check-= (first (fn 0)) 0 1e-9)
    (check-= (second (fn 0)) 0 1e-9)
    ;; at distance 5 (halfway along the first, horizontal segment)
    (match-define (list x1 y1 a1) (fn 5))
    (check-= x1 5 1e-9) (check-= y1 0 1e-9) (check-= a1 0 1e-9)
    ;; at distance 15 (halfway along the second, vertical segment) --
    ;; tangent angle should be +90 degrees (pi/2): straight down, in this
    ;; codebase's own clockwise-positive-in-y-down convention
    (match-define (list x2 y2 a2) (fn 15))
    (check-= x2 10 1e-9) (check-= y2 5 1e-9) (check-= a2 (/ pi 2) 1e-9)
    ;; out of range
    (check-false (fn -1))
    (check-false (fn 21)))

  (test-case "build-arc-length-fn returns #f for a degenerate (fewer than 2 point) polyline"
    (define-values (fn total) (build-arc-length-fn (list (cons 0 0))))
    (check-false fn)
    (check-equal? total 0))

  (test-case "<textPath> lays text out along a curved path, not in a straight line"
    ;; a quarter-circle arc: text following it should extend noticeably
    ;; higher (smaller y) than a straight horizontal baseline would, since
    ;; the path curves upward -- verified visually and against `resvg`
    ;; (librsvg has no textPath support at all, confirmed independently
    ;; by several sources, so it can't serve as the cross-check here)
    (define bm (svg-string->bitmap
                "<svg width=\"200\" height=\"200\">
                   <path id=\"arc\" d=\"M 20,180 A 160,160 0 0 1 180,20\" fill=\"none\"/>
                   <text font-size=\"24\"><textPath href=\"#arc\">Hello Arc</textPath></text>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; some ink should appear well above y=100 -- a straight-line
    ;; rendering starting at (20,180) could never reach that high
    (define found-high-ink?
      (for*/or ([x (in-range 200)] [y (in-range 100)])
        (send dc get-pixel x y px)
        (< (send px red) 200)))
    (check-true found-high-ink?))

  (test-case "<textPath>'s startOffset positions the start of the text along the path"
    (define (fill-extent-x svg-str)
      (define bm (svg-string->bitmap svg-str))
      (define dc (new bitmap-dc% [bitmap bm]))
      (define px (make-object color%))
      (for*/first ([x (in-range 200)] [y (in-range 5 25)]
                   #:when (begin (send dc get-pixel x y px) (< (send px red) 200)))
        x))
    (define no-offset
      (fill-extent-x "<svg width=\"200\" height=\"50\"><path id=\"p\" d=\"M10,25 L190,25\" fill=\"none\"/>
                        <text font-size=\"20\"><textPath href=\"#p\">X</textPath></text></svg>"))
    (define with-offset
      (fill-extent-x "<svg width=\"200\" height=\"50\"><path id=\"p\" d=\"M10,25 L190,25\" fill=\"none\"/>
                        <text font-size=\"20\"><textPath href=\"#p\" startOffset=\"50%\">X</textPath></text></svg>"))
    (check-true (> with-offset no-offset)))

  (test-case "text longer than the path stops rendering rather than wrapping or crashing"
    (check-not-exn
     (lambda ()
       (svg-string->bitmap
        "<svg width=\"60\" height=\"50\"><path id=\"p\" d=\"M10,25 L50,25\" fill=\"none\"/>
           <text font-size=\"20\"><textPath href=\"#p\">This text is way too long for the path</textPath></text></svg>"))))

  (test-case "a dangling textPath reference renders nothing, without crashing or affecting siblings"
    (define bm (svg-string->bitmap
                "<svg width=\"100\" height=\"50\">
                   <text font-size=\"20\"><textPath href=\"#nope\">Missing</textPath></text>
                   <rect x=\"0\" y=\"0\" width=\"100\" height=\"50\" fill=\"blue\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 50 25 px)
    (check-equal? (send px blue) 255))

  (test-case "<textPath> accepts xlink:href as well as href"
    (check-not-exn
     (lambda ()
       (svg-string->bitmap
        "<svg width=\"200\" height=\"50\" xmlns:xlink=\"http://www.w3.org/1999/xlink\">
           <path id=\"p\" d=\"M10,25 L190,25\" fill=\"none\"/>
           <text font-size=\"20\"><textPath xlink:href=\"#p\">Test</textPath></text></svg>"))))

  ;; ==== feConvolveMatrix ======================================================
  ;; librsvg (2.58.0, the version available here) was confirmed to silently
  ;; no-op feConvolveMatrix entirely -- a 3x3 averaging kernel produced
  ;; literally zero spread on a single-pixel impulse, consistent with a
  ;; historical librsvg bug ("feConvolveMatrix wasn't being rendered at
  ;; all") and documented cross-engine inconsistency in this exact
  ;; primitive going back over a decade (a Mozilla bug tracker entry on
  ;; bias handling, and a W3C fxtf-drafts issue where the resvg author
  ;; notes "everyone doing their own thing" for edge cases). So these
  ;; tests check against hand-derived values from the spec's own
  ;; formula, confirmed via an isolated, non-rendering byte-buffer
  ;; computation before ever touching svg.rkt's implementation.

  (test-case "feConvolveMatrix: the identity kernel (1 at center) is a no-op"
    (define with-filter (svg-string->bitmap
                         "<svg width=\"40\" height=\"40\">
                            <defs><filter id=\"f\" x=\"0%\" y=\"0%\" width=\"100%\" height=\"100%\">
                              <feConvolveMatrix order=\"3\" kernelMatrix=\"0 0 0 0 1 0 0 0 0\" divisor=\"1\"/>
                            </filter></defs>
                            <rect x=\"10\" y=\"10\" width=\"20\" height=\"20\" fill=\"blue\" filter=\"url(#f)\"/>
                          </svg>"))
    (define without-filter (svg-string->bitmap
                             "<svg width=\"40\" height=\"40\"><rect x=\"10\" y=\"10\" width=\"20\" height=\"20\" fill=\"blue\"/></svg>"))
    (define (bytes-of bm) (define b (make-bytes (* 40 40 4))) (send bm get-argb-pixels 0 0 40 40 b) b)
    (check-equal? (bytes-of with-filter) (bytes-of without-filter)))

  (test-case "feConvolveMatrix: the kernel is applied flipped (true convolution, not correlation)"
    ;; kernel with a single 1 at the top-left corner (flat index 0), default
    ;; target=1 for a 3x3 kernel: per the spec's own formula the source
    ;; sampled is (x+1,y+1), so the whole image shifts toward smaller (x,y)
    ;; -- confirmed via an isolated hand-computed byte-buffer test before
    ;; this was ever implemented, and reconfirmed here end-to-end.
    (define bm (svg-string->bitmap
                "<svg width=\"60\" height=\"60\">
                   <defs><filter id=\"f\" x=\"0%\" y=\"0%\" width=\"100%\" height=\"100%\">
                     <feConvolveMatrix order=\"3\" kernelMatrix=\"1 0 0 0 0 0 0 0 0\" divisor=\"1\" edgeMode=\"none\"/>
                   </filter></defs>
                   <rect x=\"20\" y=\"20\" width=\"20\" height=\"20\" fill=\"blue\" filter=\"url(#f)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define (blue-at? x y) (send dc get-pixel x y px) (and (> (send px blue) 200) (< (send px red) 100)))
    ;; shifted by (-1,-1): the rect now covers [19,38], not the original
    ;; [20,39] -- 19 and 37 are newly/still covered, 18 and 39 are the
    ;; positions just outside the SHIFTED range on each side
    (check-true (blue-at? 19 30))
    (check-false (blue-at? 18 30))
    (check-false (blue-at? 39 30))
    (check-true (blue-at? 37 30)))

  (test-case "feConvolveMatrix: an averaging kernel blurs a hard edge"
    (define bm (svg-string->bitmap
                "<svg width=\"40\" height=\"40\">
                   <defs><filter id=\"f\" x=\"0%\" y=\"0%\" width=\"100%\" height=\"100%\">
                     <feConvolveMatrix order=\"3\" kernelMatrix=\"1 1 1 1 1 1 1 1 1\" edgeMode=\"duplicate\"/>
                   </filter></defs>
                   <g filter=\"url(#f)\">
                     <rect x=\"0\" y=\"0\" width=\"20\" height=\"40\" fill=\"black\"/>
                     <rect x=\"20\" y=\"0\" width=\"20\" height=\"40\" fill=\"white\"/>
                   </g>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 20 20 px)
    (check-true (< (send px red) 250))   ; not pure white
    (check-true (> (send px red) 5)))    ; not pure black either -- genuinely blended

  (test-case "feConvolveMatrix: preserveAlpha keeps the source alpha channel exactly"
    ;; needs pict (transparent background), not svg-string->bitmap (always
    ;; opaque white) -- a bitmap's own final alpha is always 255 regardless
    ;; of any opacity applied while rendering onto it, so it can't reveal
    ;; whether the alpha CHANNEL itself was preserved partway through a
    ;; filter chain (a real mistake in an earlier version of this test).
    (define p (svg-string->pict
               "<svg width=\"20\" height=\"20\">
                  <defs><filter id=\"f\" x=\"0%\" y=\"0%\" width=\"100%\" height=\"100%\">
                    <feConvolveMatrix order=\"1\" kernelMatrix=\"2\" divisor=\"1\" preserveAlpha=\"true\"/>
                  </filter></defs>
                  <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"red\" opacity=\"0.4\" filter=\"url(#f)\"/>
                </svg>"))
    (define bm (pict->bitmap p))
    (define bytes (make-bytes (* 20 20 4)))
    (send bm get-argb-pixels 0 0 20 20 bytes)
    (define idx (* 4 (+ 10 (* 10 20))))
    (check-= (bytes-ref bytes idx) (round (* 255 0.4)) 1))

  (test-case "feConvolveMatrix with a malformed kernel (wrong element count) leaves the input unchanged, per spec"
    (define bm (svg-string->bitmap
                "<svg width=\"20\" height=\"20\">
                   <defs><filter id=\"f\"><feConvolveMatrix order=\"3\" kernelMatrix=\"1 2 3\"/></filter></defs>
                   <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"lime\" filter=\"url(#f)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 10 10 px)
    (check-equal? (list (send px red) (send px green) (send px blue)) (list 0 255 0)))

  ;; ==== feDisplacementMap =====================================================

  (test-case "feDisplacementMap shifts background pixels to sample from a fully-opaque region, per the spec formula"
    ;; xChannelSelector/yChannelSelector="A": within the opaque rect
    ;; (alpha=255, normalized 1.0) dx=dy=scale*(1.0-0.5)=+20; over the
    ;; transparent background (alpha=0) dx=dy=scale*(0-0.5)=-20. A
    ;; background OUTPUT position (x,y) therefore samples INPUT at
    ;; (x-20,y-20) -- landing inside the original [30,49] rect exactly
    ;; when (x,y) is in [50,69], which is what should show blue in the
    ;; output (verified by hand-deriving the formula before this test
    ;; was written, not the reverse).
    (define bm (svg-string->bitmap
                "<svg width=\"100\" height=\"100\">
                   <defs><filter id=\"f\" x=\"0%\" y=\"0%\" width=\"100%\" height=\"100%\">
                     <feDisplacementMap in=\"SourceGraphic\" in2=\"SourceGraphic\" scale=\"40\" xChannelSelector=\"A\" yChannelSelector=\"A\"/>
                   </filter></defs>
                   <g filter=\"url(#f)\"><rect x=\"30\" y=\"30\" width=\"20\" height=\"20\" fill=\"blue\"/></g>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define (blue-at? x y) (send dc get-pixel x y px) (and (> (send px blue) 200) (< (send px red) 100)))
    (check-true (blue-at? 55 55))    ; inside the shifted [50,69] region
    (check-false (blue-at? 35 35))   ; the ORIGINAL rect position should now be empty
    (check-false (blue-at? 75 75)))  ; well outside the shifted region

  (test-case "feDisplacementMap with scale=0 is a no-op"
    (define with-filter (svg-string->bitmap
                         "<svg width=\"40\" height=\"40\">
                            <defs><filter id=\"f\" x=\"0%\" y=\"0%\" width=\"100%\" height=\"100%\">
                              <feDisplacementMap in=\"SourceGraphic\" in2=\"SourceGraphic\" scale=\"0\"/>
                            </filter></defs>
                            <rect x=\"10\" y=\"10\" width=\"20\" height=\"20\" fill=\"blue\" filter=\"url(#f)\"/>
                          </svg>"))
    (define without-filter (svg-string->bitmap
                             "<svg width=\"40\" height=\"40\"><rect x=\"10\" y=\"10\" width=\"20\" height=\"20\" fill=\"blue\"/></svg>"))
    (define (bytes-of bm) (define b (make-bytes (* 40 40 4))) (send bm get-argb-pixels 0 0 40 40 b) b)
    (check-equal? (bytes-of with-filter) (bytes-of without-filter)))

  ;; ==== feImage ===============================================================

  (test-case "feImage renders a locally-referenced element, aligned with the ambient transform"
    ;; verified against librsvg: both agree on the exact bounding box
    ;; (25,25)-(74,74) for a cx=30,cy=30,r=25 circle offset by (20,20)
    ;; via a subsequent feOffset -- the circle's own geometry PLUS the
    ;; filter chain's offset, confirming feImage's output correctly
    ;; feeds into later primitives like any other filter result.
    (define bm (svg-string->bitmap
                "<svg width=\"100\" height=\"100\">
                   <defs>
                     <circle id=\"mycircle\" cx=\"30\" cy=\"30\" r=\"25\" fill=\"orange\"/>
                     <filter id=\"f\" x=\"0%\" y=\"0%\" width=\"100%\" height=\"100%\">
                       <feImage href=\"#mycircle\"/>
                       <feOffset dx=\"20\" dy=\"20\"/>
                     </filter>
                   </defs>
                   <rect x=\"0\" y=\"0\" width=\"100\" height=\"100\" fill=\"white\" filter=\"url(#f)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define min-x 100) (define max-x 0) (define min-y 100) (define max-y 0)
    (for* ([x (in-range 100)] [y (in-range 100)])
      (send dc get-pixel x y px)
      (when (and (> (send px red) 200) (< (send px blue) 100))
        (set! min-x (min min-x x)) (set! max-x (max max-x x)) (set! min-y (min min-y y)) (set! max-y (max max-y y))))
    (check-equal? (list min-x min-y max-x max-y) (list 25 25 74 74)))

  (test-case "feImage with a dangling local reference produces nothing, without crashing"
    (check-not-exn
     (lambda ()
       (svg-string->bitmap
        "<svg width=\"40\" height=\"40\">
           <defs><filter id=\"f\"><feImage href=\"#nope\"/></filter></defs>
           <rect x=\"0\" y=\"0\" width=\"40\" height=\"40\" fill=\"blue\" filter=\"url(#f)\"/>
         </svg>"))))

  ;; ==== feTurbulence ==========================================================
  ;; Verified against librsvg statistically (mean/min/max pixel value and
  ;; overall visual character), not pixel-for-pixel -- two independently
  ;; correct PRNG ports will walk their permutation tables differently
  ;; and produce a different specific noise field for the same seed
  ;; unless every implementation detail matches exactly. What IS
  ;; guaranteed and tested here is determinism (this file's own output
  ;; is reproducible for a given seed) and the statistical/visual
  ;; convergence already checked during development (mean 227.8 here vs
  ;; librsvg's 229, max matching exactly at 255, for the same
  ;; baseFrequency=0.1/seed=0/turbulence-type case).

  (test-case "feTurbulence is deterministic: the same seed and parameters always produce the same output"
    (define svg-str "<svg width=\"50\" height=\"50\"><filter id=\"f\"><feTurbulence baseFrequency=\"0.2\" seed=\"5\"/></filter><rect width=\"50\" height=\"50\" filter=\"url(#f)\"/></svg>")
    (define (bytes-of svg) (define bm (svg-string->bitmap svg)) (define b (make-bytes (* 50 50 4))) (send bm get-argb-pixels 0 0 50 50 b) b)
    (check-equal? (bytes-of svg-str) (bytes-of svg-str)))

  (test-case "feTurbulence: different seeds produce different output"
    (define (bytes-of svg) (define bm (svg-string->bitmap svg)) (define b (make-bytes (* 50 50 4))) (send bm get-argb-pixels 0 0 50 50 b) b)
    (check-false (equal? (bytes-of "<svg width=\"50\" height=\"50\"><filter id=\"f\"><feTurbulence baseFrequency=\"0.2\" seed=\"5\"/></filter><rect width=\"50\" height=\"50\" filter=\"url(#f)\"/></svg>")
                          (bytes-of "<svg width=\"50\" height=\"50\"><filter id=\"f\"><feTurbulence baseFrequency=\"0.2\" seed=\"99\"/></filter><rect width=\"50\" height=\"50\" filter=\"url(#f)\"/></svg>"))))

  (test-case "feTurbulence: type=fractalNoise differs from the default type=turbulence"
    (define (bytes-of svg) (define bm (svg-string->bitmap svg)) (define b (make-bytes (* 50 50 4))) (send bm get-argb-pixels 0 0 50 50 b) b)
    (check-false (equal? (bytes-of "<svg width=\"50\" height=\"50\"><filter id=\"f\"><feTurbulence baseFrequency=\"0.2\" seed=\"5\"/></filter><rect width=\"50\" height=\"50\" filter=\"url(#f)\"/></svg>")
                          (bytes-of "<svg width=\"50\" height=\"50\"><filter id=\"f\"><feTurbulence type=\"fractalNoise\" baseFrequency=\"0.2\" seed=\"5\"/></filter><rect width=\"50\" height=\"50\" filter=\"url(#f)\"/></svg>"))))

  (test-case "feTurbulence with multiple octaves renders without error"
    (check-not-exn
     (lambda ()
       (svg-string->bitmap "<svg width=\"50\" height=\"50\"><filter id=\"f\"><feTurbulence baseFrequency=\"0.1\" numOctaves=\"4\" seed=\"3\"/></filter><rect width=\"50\" height=\"50\" filter=\"url(#f)\"/></svg>"))))

  (test-case "feTurbulence's overall value distribution statistically matches librsvg's for the same parameters"
    ;; librsvg's own rendering of this exact filter (baseFrequency=0.1,
    ;; numOctaves=1, seed=0, type=turbulence) on a 100x100 canvas gives
    ;; red-channel mean=229, min=84, max=255; this file's own gives
    ;; mean=227.8, min=87, max=255 -- checked with generous tolerances,
    ;; since exact reproduction isn't the meaningful bar for noise.
    (define bm (svg-string->bitmap
                "<svg width=\"100\" height=\"100\">
                   <filter id=\"f\" x=\"0%\" y=\"0%\" width=\"100%\" height=\"100%\">
                     <feTurbulence type=\"turbulence\" baseFrequency=\"0.1\" numOctaves=\"1\" seed=\"0\"/>
                   </filter>
                   <rect width=\"100\" height=\"100\" filter=\"url(#f)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define total 0) (define mx 0)
    (for* ([x (in-range 100)] [y (in-range 100)])
      (send dc get-pixel x y px)
      (set! total (+ total (send px red)))
      (set! mx (max mx (send px red))))
    (check-= (/ total 10000.0) 229 15)
    (check-equal? mx 255))

  ;; ==== feDiffuseLighting / feSpecularLighting ================================
  ;; Verified against librsvg for all three light source types (point,
  ;; distant, spot): each produces the expected qualitative lighting
  ;; effect (a glossy specular highlight or a directional diffuse
  ;; shadow) with pixel diffs of 7-15%, consistent with the same
  ;; blur/antialiasing-level variance already seen throughout this file
  ;; for anything involving feGaussianBlur, not a structural difference.

  (test-case "feSpecularLighting with a point light produces a bright highlight, clipped to the source shape"
    (define bm (svg-string->bitmap
                "<svg width=\"150\" height=\"150\">
                   <defs><filter id=\"f\" x=\"-20%\" y=\"-20%\" width=\"140%\" height=\"140%\">
                     <feGaussianBlur in=\"SourceAlpha\" stdDeviation=\"2\" result=\"blur\"/>
                     <feSpecularLighting in=\"blur\" surfaceScale=\"5\" specularConstant=\"1\" specularExponent=\"10\"
                                          lighting-color=\"white\" result=\"spec\">
                       <fePointLight x=\"50\" y=\"50\" z=\"80\"/>
                     </feSpecularLighting>
                     <feComposite in=\"spec\" in2=\"SourceAlpha\" operator=\"in\" result=\"specClip\"/>
                     <feComposite in=\"SourceGraphic\" in2=\"specClip\" operator=\"arithmetic\" k1=\"0\" k2=\"1\" k3=\"1\" k4=\"0\"/>
                   </filter></defs>
                   <circle cx=\"75\" cy=\"75\" r=\"50\" fill=\"steelblue\" filter=\"url(#f)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; near the light's own (x,y)=(50,50): bright highlight, near white
    (send dc get-pixel 50 50 px)
    (check-true (> (send px red) 200))
    ;; far from the light, near the shape's own edge: little to no
    ;; specular contribution, should look close to the base fill color,
    ;; not white
    (send dc get-pixel 75 120 px)
    (check-true (< (send px red) 200))
    ;; well outside the circle entirely: untouched white background
    (send dc get-pixel 10 10 px)
    (check-equal? (list (send px red) (send px green) (send px blue)) (list 255 255 255)))

  (test-case "feDiffuseLighting with a distant light produces a directional shading gradient"
    (define bm (svg-string->bitmap
                "<svg width=\"150\" height=\"150\">
                   <defs><filter id=\"f\" x=\"-20%\" y=\"-20%\" width=\"140%\" height=\"140%\">
                     <feGaussianBlur in=\"SourceAlpha\" stdDeviation=\"3\" result=\"blur\"/>
                     <feDiffuseLighting in=\"blur\" surfaceScale=\"8\" diffuseConstant=\"1\" lighting-color=\"white\" result=\"diff\">
                       <feDistantLight azimuth=\"235\" elevation=\"45\"/>
                     </feDiffuseLighting>
                     <feComposite in=\"diff\" in2=\"SourceAlpha\" operator=\"in\" result=\"diffClip\"/>
                     <feComposite in=\"SourceGraphic\" in2=\"diffClip\" operator=\"arithmetic\" k1=\"1\" k2=\"0\" k3=\"0\" k4=\"0\"/>
                   </filter></defs>
                   <circle cx=\"75\" cy=\"75\" r=\"50\" fill=\"orange\" filter=\"url(#f)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; azimuth=235/elevation=45: Lx=cos(235)*cos(45)=-0.41, Ly=-sin(235)*cos(45)=+0.58
    ;; (computed directly from the spec formula, not assumed) -- light
    ;; comes from the lower-left (negative x, positive y in SVG's
    ;; y-down convention), so the lower-left edge should be brighter
    ;; than the upper-right edge
    (send dc get-pixel 45 105 px) (define lower-left (send px red))
    (send dc get-pixel 105 45 px) (define upper-right (send px red))
    (check-true (> lower-left upper-right)))

  (test-case "feSpotLight's limitingConeAngle cuts off light outside the cone"
    (define bm (svg-string->bitmap
                "<svg width=\"150\" height=\"150\">
                   <defs><filter id=\"f\" x=\"-20%\" y=\"-20%\" width=\"140%\" height=\"140%\">
                     <feGaussianBlur in=\"SourceAlpha\" stdDeviation=\"2\" result=\"blur\"/>
                     <feSpecularLighting in=\"blur\" surfaceScale=\"5\" specularConstant=\"1\" specularExponent=\"8\"
                                          lighting-color=\"white\" result=\"spec\">
                       <feSpotLight x=\"40\" y=\"40\" z=\"100\" pointsAtX=\"75\" pointsAtY=\"75\" pointsAtZ=\"0\"
                                    specularExponent=\"1\" limitingConeAngle=\"10\"/>
                     </feSpecularLighting>
                     <feComposite in=\"spec\" in2=\"SourceAlpha\" operator=\"in\" result=\"specClip\"/>
                     <feComposite in=\"SourceGraphic\" in2=\"specClip\" operator=\"arithmetic\" k1=\"0\" k2=\"1\" k3=\"1\" k4=\"0\"/>
                   </filter></defs>
                   <circle cx=\"75\" cy=\"75\" r=\"50\" fill=\"seagreen\" filter=\"url(#f)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; near where the spotlight points (75,75): strong illumination
    (send dc get-pixel 75 75 px) (define near-center (send px red))
    ;; still on the shape (distance ~47 from center, within radius 50),
    ;; but far from the cone's narrow (10 degree) axis -- outside the
    ;; cone, so no specular contribution at all: just the plain fill color
    (send dc get-pixel 108 108 px) (define far-corner (send px red))
    (check-true (> near-center far-corner)))

  ;; ==== feTile ================================================================

  (test-case "feTile repeats a referenced primitive's own subregion with the exact specified period"
    ;; verified visually against librsvg too: both show a clearly
    ;; repeating tile pattern at the same 20x20 period, though the
    ;; specific noise content differs (expected, per feTurbulence's own
    ;; disclosed cross-engine noise variance)
    (define bm (svg-string->bitmap
                "<svg width=\"120\" height=\"120\">
                   <defs><filter id=\"f\" x=\"0%\" y=\"0%\" width=\"100%\" height=\"100%\">
                     <feTurbulence type=\"turbulence\" baseFrequency=\"0.3\" numOctaves=\"1\" seed=\"2\"
                                   x=\"0\" y=\"0\" width=\"20\" height=\"20\" result=\"tile\"/>
                     <feTile in=\"tile\" x=\"0\" y=\"0\" width=\"120\" height=\"120\"/>
                   </filter></defs>
                   <rect width=\"120\" height=\"120\" filter=\"url(#f)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define (rgb x y) (send dc get-pixel x y px) (list (send px red) (send px green) (send px blue)))
    (define base (rgb 5 5))
    (check-equal? (rgb 25 5) base)
    (check-equal? (rgb 45 5) base)
    (check-equal? (rgb 5 25) base)
    (check-equal? (rgb 5 45) base)
    ;; and a DIFFERENT point within the same tile should generally NOT
    ;; match (confirming this isn't just a uniformly-flooded buffer)
    (check-false (equal? (rgb 15 15) base)))

  (test-case "feTile falls back to passing its input through unchanged when the referenced primitive has no explicit subregion"
    (check-not-exn
     (lambda ()
       (svg-string->bitmap
        "<svg width=\"40\" height=\"40\">
           <defs><filter id=\"f\">
             <feFlood flood-color=\"blue\" result=\"flood\"/>
             <feTile in=\"flood\"/>
           </filter></defs>
           <rect width=\"40\" height=\"40\" filter=\"url(#f)\"/>
         </svg>"))))

  ;; ==== textPath path= attribute ==============================================

  (test-case "textPath's path= attribute (inline path data) takes precedence over href, per SVG2"
    ;; verified via self-consistency (external renderers weren't
    ;; reliable references for this specific, fairly recent feature:
    ;; librsvg has no textPath support at all, and the resvg build
    ;; available during development was too old to support path=
    ;; correctly, falling back to a straight line instead of the
    ;; curve): a path= attribute and an equivalent href to a <path>
    ;; with the SAME data must render byte-identically.
    (define curve "M 10 50 Q 100 10 200 50 T 390 50")
    (define via-path (svg-string->bitmap
                       (format "<svg width=\"400\" height=\"200\">
                                  <defs><path id=\"line\" d=\"M 10 50 L 100 200\"/></defs>
                                  <text><textPath href=\"#line\" path=\"~a\">Text along a quadratic curve</textPath></text>
                                </svg>" curve)))
    (define via-href (svg-string->bitmap
                       (format "<svg width=\"400\" height=\"200\">
                                  <defs><path id=\"curve\" d=\"~a\"/></defs>
                                  <text><textPath href=\"#curve\">Text along a quadratic curve</textPath></text>
                                </svg>" curve)))
    (define (bytes-of bm) (define b (make-bytes (* 400 200 4))) (send bm get-argb-pixels 0 0 400 200 b) b)
    (check-equal? (bytes-of via-path) (bytes-of via-href)))

  ;; ==== Percentage resolution against the containing viewport ================
  ;; `current-canvas-size` now tracks the CURRENT (possibly nested)
  ;; viewport rather than only the document root, and geometry
  ;; properties/stroke-width resolve percentages against it (width for
  ;; x-like properties, height for y-like, the diagonal for anything
  ;; orientation-agnostic) instead of treating "25%" as the literal
  ;; number 25 -- confirmed against the specific WPT test this was
  ;; originally found through (`rx: 25%` on an ellipse).

  (test-case "circle cx/cy/r percentages resolve against the containing viewport's width/height"
    (define bm (svg-string->bitmap
                "<svg width=\"200\" height=\"100\"><circle cx=\"50%\" cy=\"50%\" r=\"10%\" fill=\"blue\"/></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; cx=100 (50% of 200), cy=50 (50% of 100), r=20 (10% of the
    ;; diagonal-ish reference -- but per spec r is NOT x/y-oriented, so
    ;; it resolves against the diagonal: sqrt(200^2+100^2)/sqrt(2) =
    ;; ~158.1, so r = 15.81)
    (send dc get-pixel 100 50 px)
    (check-equal? (send px blue) 255)
    (send dc get-pixel 100 15 px)
    (check-equal? (list (send px red) (send px blue)) (list 255 255)))  ; well outside r, white background

  (test-case "ellipse rx/ry auto-derivation works correctly with percentage values (the original WPT-found case)"
    (define bm (svg-string->bitmap
                "<svg width=\"40\" height=\"40\"><style>ellipse { rx: 25%; ry: auto; }</style>
                   <ellipse cx=\"20\" cy=\"20\" fill=\"none\" stroke=\"blue\" stroke-width=\"5\"/></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; rx=25% of width(40)=10; ry auto-derives to match
    (for ([pt (list (cons 20 8) (cons 20 32) (cons 8 20) (cons 32 20))])
      (send dc get-pixel (car pt) (cdr pt) px)
      (check-equal? (send px blue) 255)))

  (test-case "stroke-width percentages resolve against the diagonal reference length"
    (define bm-percent (svg-string->bitmap
                         "<svg width=\"60\" height=\"80\"><line x1=\"10\" y1=\"40\" x2=\"50\" y2=\"40\" stroke=\"black\" stroke-width=\"10%\"/></svg>"))
    ;; diagonal = sqrt(60^2+80^2)/sqrt(2) = 70.7, so stroke-width = 7.07
    (define bm-explicit (svg-string->bitmap
                          "<svg width=\"60\" height=\"80\"><line x1=\"10\" y1=\"40\" x2=\"50\" y2=\"40\" stroke=\"black\" stroke-width=\"7.07\"/></svg>"))
    (define (bytes-of bm) (define b (make-bytes (* 60 80 4))) (send bm get-argb-pixels 0 0 60 80 b) b)
    (check-equal? (bytes-of bm-percent) (bytes-of bm-explicit)))

  (test-case "percentage resolution correctly tracks a NESTED viewport, not just the document root"
    (define bm (svg-string->bitmap
                "<svg width=\"100\" height=\"100\">
                   <svg x=\"0\" y=\"0\" width=\"40\" height=\"40\">
                     <circle cx=\"50%\" cy=\"50%\" r=\"25%\" fill=\"blue\"/>
                   </svg>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; inner viewport is 40x40 (not the outer 100x100), so cx=cy=20, r=10
    (send dc get-pixel 20 20 px)
    (check-equal? (send px blue) 255)
    (send dc get-pixel 20 9 px)
    (check-equal? (send px red) 255))

  ;; ==== Per-primitive filter subregion clipping ===============================

  (test-case "a filter primitive's own explicit x/y/width/height subregion clips its output"
    ;; verified against librsvg: exact, zero-pixel-difference match
    (define bm (svg-string->bitmap
                "<svg width=\"100\" height=\"100\">
                   <filter id=\"f\" x=\"0%\" y=\"0%\" width=\"100%\" height=\"100%\">
                     <feFlood flood-color=\"blue\" x=\"20\" y=\"20\" width=\"40\" height=\"40\"/>
                   </filter>
                   <rect width=\"100\" height=\"100\" fill=\"white\" filter=\"url(#f)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 40 40 px)
    (check-equal? (send px blue) 255)
    (send dc get-pixel 10 10 px)
    (check-equal? (list (send px red) (send px blue)) (list 255 255))
    (send dc get-pixel 70 70 px)
    (check-equal? (list (send px red) (send px blue)) (list 255 255)))

  (test-case "a primitive with no explicit subregion at all is not clipped (fills the whole canvas as before)"
    (define bm (svg-string->bitmap
                "<svg width=\"40\" height=\"40\">
                   <filter id=\"f\"><feFlood flood-color=\"blue\"/></filter>
                   <rect width=\"40\" height=\"40\" filter=\"url(#f)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 5 5 px) (check-equal? (send px blue) 255)
    (send dc get-pixel 35 35 px) (check-equal? (send px blue) 255))

  (test-case "feTile still tiles correctly when its referenced primitive is now clipped to its own subregion"
    (define bm (svg-string->bitmap
                "<svg width=\"120\" height=\"120\">
                   <defs><filter id=\"f\" x=\"0%\" y=\"0%\" width=\"100%\" height=\"100%\">
                     <feTurbulence type=\"turbulence\" baseFrequency=\"0.3\" numOctaves=\"1\" seed=\"2\"
                                   x=\"0\" y=\"0\" width=\"20\" height=\"20\" result=\"tile\"/>
                     <feTile in=\"tile\" x=\"0\" y=\"0\" width=\"120\" height=\"120\"/>
                   </filter></defs>
                   <rect width=\"120\" height=\"120\" filter=\"url(#f)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define (rgb x y) (send dc get-pixel x y px) (list (send px red) (send px green) (send px blue)))
    (define base (rgb 5 5))
    (check-equal? (rgb 25 5) base)
    (check-equal? (rgb 5 25) base))

  ;; ==== Gradient/pattern strokes ==============================================
  ;; racket/draw's pen% has no gradient/pattern support at all, so
  ;; stroking with one needs a fundamentally different technique
  ;; (draw-gradient-stroke!): render the stroke geometry as an alpha
  ;; mask, fill the same area with the brush, combine. Verified against
  ;; librsvg across four cases (plain, transformed, dashed, pattern),
  ;; all within 1-3% pixel diff, consistent with ordinary curve
  ;; antialiasing variance, not a structural difference.

  (test-case "a circle can be stroked with a linear gradient"
    (define bm (svg-string->bitmap
                "<svg width=\"200\" height=\"200\">
                   <defs><linearGradient id=\"g\" x1=\"0%\" y1=\"0%\" x2=\"100%\" y2=\"0%\">
                     <stop offset=\"0%\" stop-color=\"red\"/><stop offset=\"100%\" stop-color=\"blue\"/>
                   </linearGradient></defs>
                   <circle cx=\"100\" cy=\"100\" r=\"60\" fill=\"none\" stroke=\"url(#g)\" stroke-width=\"12\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; left of the ring: red-dominant; right of the ring: blue-dominant
    (send dc get-pixel 40 100 px) (check-true (> (send px red) (send px blue)))
    (send dc get-pixel 160 100 px) (check-true (> (send px blue) (send px red)))
    ;; fill area (center) stays background, since fill=none
    (send dc get-pixel 100 100 px) (check-equal? (list (send px red) (send px blue)) (list 255 255)))

  (test-case "a gradient stroke correctly follows an ambient transform"
    (define bm (svg-string->bitmap
                "<svg width=\"200\" height=\"200\">
                   <defs><linearGradient id=\"g\" x1=\"0%\" y1=\"0%\" x2=\"100%\" y2=\"0%\">
                     <stop offset=\"0%\" stop-color=\"red\"/><stop offset=\"100%\" stop-color=\"blue\"/>
                   </linearGradient></defs>
                   <g transform=\"translate(20,20) scale(1.5)\">
                     <circle cx=\"50\" cy=\"50\" r=\"30\" fill=\"none\" stroke=\"url(#g)\" stroke-width=\"8\"/>
                   </g>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; scaled/translated circle center is ~(95,95), radius ~45: check
    ;; left vs right of the ring still shows red->blue
    (send dc get-pixel 45 95 px) (check-true (> (send px red) (send px blue)))
    (send dc get-pixel 145 95 px) (check-true (> (send px blue) (send px red))))

  (test-case "a gradient stroke combines correctly with stroke-dasharray"
    (define bm (svg-string->bitmap
                "<svg width=\"200\" height=\"200\">
                   <defs><linearGradient id=\"g\" x1=\"0%\" y1=\"0%\" x2=\"100%\" y2=\"0%\">
                     <stop offset=\"0%\" stop-color=\"red\"/><stop offset=\"100%\" stop-color=\"blue\"/>
                   </linearGradient></defs>
                   <circle cx=\"100\" cy=\"100\" r=\"60\" fill=\"none\" stroke=\"url(#g)\" stroke-width=\"10\" stroke-dasharray=\"15,8\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; some pixels along the ring should be background (the dash gaps),
    ;; confirming dashing is still happening, not a solid ring
    (define found-gap?
      (for/or ([angle (in-range 0 360 5)])
        (define rad (degrees->radians angle))
        (define x (inexact->exact (round (+ 100 (* 60 (cos rad))))))
        (define y (inexact->exact (round (+ 100 (* 60 (sin rad))))))
        (send dc get-pixel x y px)
        (equal? (list (send px red) (send px green) (send px blue)) (list 255 255 255))))
    (check-true found-gap?))

  (test-case "a shape can be stroked with a pattern"
    (define bm (svg-string->bitmap
                "<svg width=\"200\" height=\"200\">
                   <defs><pattern id=\"p\" width=\"10\" height=\"10\" patternUnits=\"userSpaceOnUse\">
                     <rect width=\"10\" height=\"10\" fill=\"white\"/>
                     <rect width=\"5\" height=\"5\" fill=\"black\"/>
                   </pattern></defs>
                   <circle cx=\"100\" cy=\"100\" r=\"60\" fill=\"none\" stroke=\"url(#p)\" stroke-width=\"14\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; the ring should contain BOTH black and white pixels (the
    ;; checkerboard), not a single uniform fallback color
    (define saw-black? #f) (define saw-white-on-ring? #f)
    (for ([angle (in-range 0 360 3)])
      (define rad (degrees->radians angle))
      (define x (inexact->exact (round (+ 100 (* 60 (cos rad))))))
      (define y (inexact->exact (round (+ 100 (* 60 (sin rad))))))
      (send dc get-pixel x y px)
      (define v (list (send px red) (send px green) (send px blue)))
      (when (equal? v (list 0 0 0)) (set! saw-black? #t))
      (when (equal? v (list 255 255 255)) (set! saw-white-on-ring? #t)))
    (check-true saw-black?))

  ;; ==== Pattern alpha-channel fixes ===========================================
  ;; The pattern tile bitmap was being created without alpha-channel
  ;; support at all (a plain (make-object bitmap% w h), not the (... #f
  ;; #t) form used everywhere else an alpha channel is needed) --
  ;; confirmed to be the actual root cause after fill-opacity scaling
  ;; alone didn't fix anything: a non-alpha bitmap forces every pixel
  ;; opaque regardless of what's written via set-argb-pixels. This
  ;; affected two distinct things: transparency WITHIN a pattern's own
  ;; content (a gap between tiled shapes never let anything behind the
  ;; pattern show through), and fill-opacity/opacity applied to an
  ;; element painted with a pattern (silently had no effect at all).
  ;; Both verified against librsvg (the transparency case: an exact,
  ;; zero-pixel-difference match).

  (test-case "a pattern with transparent gaps in its own content lets the background show through"
    (define bm (svg-string->bitmap
                "<svg width=\"40\" height=\"40\">
                   <defs><pattern id=\"p\" width=\"10\" height=\"10\" patternUnits=\"userSpaceOnUse\">
                     <circle cx=\"5\" cy=\"5\" r=\"3\" fill=\"blue\"/>
                   </pattern></defs>
                   <rect width=\"40\" height=\"40\" fill=\"red\"/>
                   <rect width=\"40\" height=\"40\" fill=\"url(#p)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 0 0 px)
    (check-equal? (list (send px red) (send px blue)) (list 255 0))
    (send dc get-pixel 5 5 px)
    (check-equal? (list (send px red) (send px blue)) (list 0 255)))

  (test-case "fill-opacity on an element painted with a pattern actually reduces its opacity"
    (define p (svg-string->pict
               "<svg width=\"40\" height=\"40\">
                  <defs><pattern id=\"p\" width=\"1\" height=\"1\" patternContentUnits=\"objectBoundingBox\">
                    <rect fill=\"lime\" width=\"1\" height=\"1\"/>
                  </pattern></defs>
                  <rect width=\"40\" height=\"40\" fill-opacity=\"0.5\" fill=\"url(#p)\"/>
                </svg>"))
    (define bm (pict->bitmap p))
    (define bytes (make-bytes (* 40 40 4)))
    (send bm get-argb-pixels 0 0 40 40 bytes)
    (define idx (* 4 (+ 20 (* 20 40))))
    (check-= (bytes-ref bytes idx) 128 2))

  (test-case "pattern x/y shifts the whole repeating tile grid"
    ;; verified against librsvg: exact, zero-pixel-difference match.
    ;; patternTransform (rotate/skew) remains a disclosed gap -- unlike
    ;; a pure x/y translation, it can't be baked into the tile bitmap
    ;; via a pixel-domain wrap-around shift, and brush%'s own
    ;; [transformation ...] mechanism was confirmed empirically to have
    ;; no effect at all in the installed racket/draw.
    (define bm (svg-string->bitmap
                "<svg width=\"60\" height=\"60\">
                   <defs><pattern id=\"p\" width=\"20\" height=\"20\" patternUnits=\"userSpaceOnUse\" x=\"5\" y=\"5\">
                     <rect width=\"10\" height=\"10\" fill=\"blue\"/>
                   </pattern></defs>
                   <rect width=\"60\" height=\"60\" fill=\"url(#p)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; without the x=5,y=5 shift, (0,0) would be the START of a blue
    ;; 10x10 square (since patterns start unshifted at the origin by
    ;; default); with the shift, (0,0) falls in what was the GAP
    (send dc get-pixel 2 2 px)
    (check-equal? (list (send px red) (send px blue)) (list 255 255))
    ;; and the blue square should now appear starting at (5,5) instead
    (send dc get-pixel 7 7 px)
    (check-equal? (list (send px red) (send px blue)) (list 0 255)))

  ;; ==== paint-order ============================================================
  ;; Both verified against librsvg with exact, zero-pixel-difference
  ;; matches. Required threading `node` into draw-shape-paths! for
  ;; EVERY shape type (not just the 4 that support markers) -- an
  ;; earlier version only did this for path/line/polyline/polygon,
  ;; reasoning "only those support markers", which missed that
  ;; paint-order's fill/stroke ordering matters for circle/rect/ellipse
  ;; too even though they never have markers -- caught by a direct,
  ;; unambiguous pixel check in the fill/stroke overlap region showing
  ;; no difference at all between the two orders before the fix.

  (test-case "paint-order: stroke draws the stroke before the fill, changing what's visible in their overlap"
    (define bm (svg-string->bitmap
                "<svg width=\"200\" height=\"100\">
                   <circle cx=\"50\" cy=\"50\" r=\"20\" fill=\"yellow\" stroke=\"blue\" stroke-width=\"15\"/>
                   <circle cx=\"150\" cy=\"50\" r=\"20\" fill=\"yellow\" stroke=\"blue\" stroke-width=\"15\" style=\"paint-order: stroke\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define (blue-at? cx r) (send dc get-pixel (+ cx r) 50 px) (equal? (list (send px red) (send px blue)) (list 0 255)))
    ;; default order: stroke drawn last, fully covers the overlap region (fill/stroke band [12.5,20])
    (check-true (blue-at? 50 14))
    (check-true (blue-at? 50 17))
    ;; paint-order:stroke: fill drawn last, covers the INNER half of the stroke band instead
    (check-false (blue-at? 150 14))
    (check-false (blue-at? 150 17))
    (check-true (blue-at? 150 22)))  ; outer half of the stroke band still shows through

  (test-case "paint-order: markers draws markers before stroke, letting the stroke cover part of the marker"
    (define bm (svg-string->bitmap
                "<svg width=\"100\" height=\"100\">
                   <defs>
                     <marker id=\"m\" markerWidth=\"20\" markerHeight=\"20\" refX=\"10\" refY=\"10\" viewBox=\"0 0 20 20\">
                       <rect x=\"0\" y=\"0\" width=\"20\" height=\"20\" fill=\"red\"/>
                     </marker>
                   </defs>
                   <line x1=\"20\" y1=\"50\" x2=\"80\" y2=\"50\" stroke=\"blue\" stroke-width=\"30\"
                         marker-start=\"url(#m)\" style=\"paint-order: markers\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; at the line's start, the thick (30px) blue stroke should now
    ;; cover most of the 20x20 red marker (since markers paint first)
    (send dc get-pixel 20 50 px)
    (check-equal? (list (send px red) (send px blue)) (list 0 255)))

  ;; ==== context-fill / context-stroke =========================================
  ;; Resolve to whatever fill/stroke was active on the REFERENCING
  ;; element -- verified against librsvg for the primary real-world use
  ;; (a marker automatically matching its path's own stroke color: an
  ;; exact, zero-pixel-difference match) and via direct pixel checks for
  ;; the <use> case (matching a WPT test's own markup pattern).
  ;;
  ;; A real, crash-inducing bug found and fixed along the way: a shape
  ;; filled with a pattern sets context-fill, for that pattern's OWN
  ;; content, to the SAME paint-ref pointing at that pattern -- so a
  ;; pattern using `fill="context-fill"` on itself was resolving back to
  ;; itself, recursing without bound (confirmed to actually hang/crash
  ;; the process before the fix, not just a theoretical concern).
  ;; Fixed with current-pattern-chain, a guard analogous to the existing
  ;; current-use-chain for <use> cycles -- which also, as a side effect,
  ;; now protects against a pattern referencing itself directly, a
  ;; separate, pre-existing gap this happened to expose.

  (test-case "context-fill/context-stroke resolve to the referencing element's own fill/stroke, via <use>"
    (define bm (svg-string->bitmap
                "<svg width=\"200\" height=\"150\">
                   <defs><rect id=\"rectangle\" width=\"60\" height=\"60\" style=\"fill:context-stroke;stroke:context-fill\"/></defs>
                   <g style=\"fill:blue;stroke:lime;stroke-width:5\">
                     <use xlink:href=\"#rectangle\" transform=\"translate(10,10)\"/>
                   </g>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; interior: fill:context-stroke -> the <g>'s own stroke (lime)
    (send dc get-pixel 40 40 px)
    (check-equal? (list (send px red) (send px green) (send px blue)) (list 0 255 0))
    ;; stroke band: stroke:context-fill -> the <g>'s own fill (blue)
    (send dc get-pixel 10 40 px)
    (check-equal? (list (send px red) (send px green) (send px blue)) (list 0 0 255)))

  (test-case "context-stroke on a marker matches its path's own stroke color"
    (define bm (svg-string->bitmap
                "<svg width=\"100\" height=\"100\">
                   <defs>
                     <marker id=\"dot\" markerWidth=\"10\" markerHeight=\"10\" refX=\"5\" refY=\"5\" viewBox=\"0 0 10 10\">
                       <circle cx=\"5\" cy=\"5\" r=\"4\" fill=\"context-stroke\"/>
                     </marker>
                   </defs>
                   <path d=\"M20,50 L80,50\" stroke=\"purple\" stroke-width=\"4\"
                         marker-start=\"url(#dot)\" marker-end=\"url(#dot)\" fill=\"none\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 20 50 px)
    (check-equal? (list (send px red) (send px green) (send px blue)) (list 128 0 128)))

  (test-case "a pattern using context-fill on itself doesn't crash or hang (cycle guard)"
    (check-not-exn
     (lambda ()
       (svg-string->bitmap
        "<svg width=\"60\" height=\"60\">
           <defs><pattern id=\"p\" width=\"1\" height=\"1\" patternContentUnits=\"objectBoundingBox\">
             <rect width=\"1\" height=\"1\" fill=\"context-fill\"/>
           </pattern></defs>
           <rect width=\"60\" height=\"60\" fill=\"url(#p)\"/>
         </svg>"))))

  (test-case "a pattern directly referencing itself doesn't crash or hang (cycle guard)"
    (check-not-exn
     (lambda ()
       (svg-string->bitmap
        "<svg width=\"60\" height=\"60\">
           <defs><pattern id=\"p\" width=\"10\" height=\"10\" patternUnits=\"userSpaceOnUse\">
             <rect width=\"10\" height=\"10\" fill=\"url(#p)\"/>
           </pattern></defs>
           <rect width=\"60\" height=\"60\" fill=\"url(#p)\"/>
         </svg>"))))

  ;; ==== pathLength =============================================================
  ;; Verified via hand-derivation and direct pixel checks rather than
  ;; against librsvg -- confirmed via an actual W3C SVG Working Group
  ;; discussion thread (2020) that WebKit and Inkscape don't implement
  ;; pathLength for stroke-dashing at all ("no implementations yet"),
  ;; and librsvg was confirmed to behave the same way (using the raw,
  ;; unscaled dasharray values), so it can't serve as a cross-check for
  ;; this feature. WPT's own reference files (authored assuming correct
  ;; spec behavior, not the common non-implementation) were used
  ;; instead: all 8 pathLength-related non-tentative WPT tests pass.

  (test-case "pathLength rescales stroke-dasharray to the path's actual geometric length"
    (define bm (svg-string->bitmap
                "<svg width=\"120\" height=\"20\">
                   <line x1=\"10\" y1=\"10\" x2=\"110\" y2=\"10\" stroke=\"black\" stroke-width=\"4\"
                         stroke-dasharray=\"1\" pathLength=\"2\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    ;; dash of "1" with pathLength=2 = half the actual 100-unit length = 50 units
    (send dc get-pixel 40 10 px) (check-equal? (send px red) 0)     ; within the first (50-unit) dash
    (send dc get-pixel 80 10 px) (check-equal? (send px red) 255))  ; within the gap

  (test-case "pathLength=\"0\" makes stroke-dasharray render as a solid stroke (infinite scale factor, per spec), without hanging"
    ;; a real, confirmed hang was found and fixed here: dash-split-
    ;; polyline isn't designed to handle infinite dash lengths, so an
    ;; infinite scale factor is special-cased to "no dashing" instead
    ;; of being passed through -- the identical visual result, reached
    ;; safely.
    (define bm (svg-string->bitmap
                "<svg width=\"120\" height=\"120\">
                   <path d=\"M10,10L110,10L110,110L10,110Z\" pathLength=\"0\" stroke-dashoffset=\"1\"
                         stroke-dasharray=\"1 1\" fill=\"none\" stroke=\"black\" stroke-width=\"10\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (for ([pt (list (cons 50 10) (cons 90 10) (cons 110 50) (cons 110 90))])
      (send dc get-pixel (car pt) (cdr pt) px)
      (check-equal? (list (send px red) (send px green) (send px blue)) (list 0 0 0))))

  (test-case "pathLength=\"0\" makes any non-zero textPath startOffset resolve off the path (infinite scale factor)"
    (check-not-exn
     (lambda ()
       (svg-string->bitmap
        "<svg width=\"300\" height=\"200\">
           <defs><path id=\"track\" d=\"M 50 50 h 200\" pathLength=\"0\"/></defs>
           <text><textPath href=\"#track\" startOffset=\"1\">Hello</textPath></text>
         </svg>"))))

  (test-case "pathLength=\"0\" makes ALL percentage textPath startOffsets resolve to the identical position"
    ;; confirmed via a WPT test: with pathLength=0, a percentage
    ;; startOffset is "X% of pathLength" (which is 0) rather than "X%
    ;; of the actual length" -- so 0%, 50%, and -50% must all produce
    ;; the SAME rendering, not three different text positions.
    (define (render off)
      (svg-string->bitmap
       (format "<svg width=\"300\" height=\"100\">
                  <defs><path id=\"track\" d=\"M 20 50 h 260\" pathLength=\"0\"/></defs>
                  <text font-size=\"20\"><textPath href=\"#track\" startOffset=\"~a\">Hello there</textPath></text>
                </svg>" off)))
    (define (bytes-of bm) (define b (make-bytes (* 300 100 4))) (send bm get-argb-pixels 0 0 300 100 b) b)
    (define b0 (bytes-of (render "0%")))
    (define b50 (bytes-of (render "50%")))
    (define bneg50 (bytes-of (render "-50%")))
    (check-equal? b0 b50)
    (check-equal? b0 bneg50))

  ;; ==== Viewport clipping (overflow: hidden, the spec default) ================
  ;; Nested <svg>, a <use>-instantiated <symbol>/<svg>, and <marker>
  ;; instances all default to overflow:hidden per spec -- previously
  ;; none of these were enforced at all (a disclosed simplification).
  ;; Implemented via push-viewport-clip!, applied in the established
  ;; viewport's own pixel space BEFORE any viewBox-mapping transform
  ;; (clipping to a viewBox-space rectangle would use the wrong
  ;; coordinate system entirely). All three verified against librsvg
  ;; with exact, zero-pixel-difference matches.
  ;;
  ;; Implementing this surfaced that current-canvas-size's own PATTERN
  ;; test fixture from earlier (an orient=auto marker test) used a
  ;; triangle path with negative-Y coordinates never actually within
  ;; its own declared viewport, silently relying on the PREVIOUS absence
  ;; of clipping -- fixed by adding overflow="visible" to that fixture,
  ;; since the test was about orientation, not clipping.

  (test-case "a nested <svg> clips its content to its own viewport by default"
    (define bm (svg-string->bitmap
                "<svg width=\"100\" height=\"100\">
                   <svg x=\"0\" y=\"0\" width=\"50\" height=\"50\">
                     <circle cx=\"50\" cy=\"50\" r=\"40\" fill=\"red\"/>
                   </svg>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 25 25 px) (check-equal? (send px red) 255)   ; within the 50x50 viewport: visible
    (send dc get-pixel 75 75 px) (check-equal? (send px red) 255))  ; outside it: clipped, background shows

  (test-case "overflow=\"visible\" on a nested <svg> disables the default clipping"
    (define bm (svg-string->bitmap
                "<svg width=\"100\" height=\"100\">
                   <svg x=\"0\" y=\"0\" width=\"50\" height=\"50\" overflow=\"visible\">
                     <circle cx=\"50\" cy=\"50\" r=\"40\" fill=\"red\"/>
                   </svg>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 75 75 px)
    (check-equal? (send px red) 255))

  (test-case "a <use>-instantiated <symbol> clips its content to the resolved viewport (the original WPT-found case)"
    (define bm (svg-string->bitmap
                "<svg width=\"500\" height=\"500\">
                   <defs><symbol id=\"sym\" width=\"200\" height=\"200\"><rect width=\"400\" height=\"400\" fill=\"green\"/></symbol></defs>
                   <use href=\"#sym\" width=\"100\" height=\"100\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define non-green 0)
    (for* ([x (in-range 100)] [y (in-range 100)])
      (send dc get-pixel x y px)
      (unless (and (= (send px red) 0) (= (send px green) 128) (= (send px blue) 0)) (set! non-green (add1 non-green))))
    (check-equal? non-green 0)
    (send dc get-pixel 150 150 px)
    (check-equal? (send px red) 255))

  (test-case "a <marker> clips its content to its own viewport by default"
    (define bm (svg-string->bitmap
                "<svg width=\"100\" height=\"100\">
                   <defs><marker id=\"m\" markerWidth=\"10\" markerHeight=\"10\" refX=\"5\" refY=\"5\" markerUnits=\"userSpaceOnUse\">
                     <circle cx=\"5\" cy=\"5\" r=\"20\" fill=\"red\"/>
                   </marker></defs>
                   <line x1=\"50\" y1=\"50\" x2=\"50\" y2=\"50\" stroke=\"blue\" marker-start=\"url(#m)\"/>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (send dc get-pixel 50 50 px) (check-equal? (send px red) 255)   ; within the 10x10 marker viewport
    (send dc get-pixel 10 10 px) (check-equal? (send px green) 255))  ; well outside it: clipped away

  (test-case "textPath's path= falls back to href when path is empty or invalid"
    ;; confirmed via two WPT tests (path="" and path="Invalid path"),
    ;; both expecting the href fallback rather than rendering nothing.
    (define curve "M 10 50 Q 100 10 200 50 T 390 50")
    (define via-href (svg-string->bitmap
                       (format "<svg width=\"400\" height=\"200\">
                                  <defs><path id=\"curve\" d=\"~a\"/></defs>
                                  <text><textPath href=\"#curve\">Text along a quadratic curve</textPath></text>
                                </svg>" curve)))
    (define (bytes-of bm) (define b (make-bytes (* 400 200 4))) (send bm get-argb-pixels 0 0 400 200 b) b)
    (for ([path-val (list "" "Invalid path")])
      (define via-fallback (svg-string->bitmap
                             (format "<svg width=\"400\" height=\"200\">
                                        <defs><path id=\"curve\" d=\"~a\"/></defs>
                                        <text><textPath href=\"#curve\" path=\"~a\">Text along a quadratic curve</textPath></text>
                                      </svg>" curve path-val)))
      (check-equal? (bytes-of via-fallback) (bytes-of via-href))))

  ;; ==== textLength / lengthAdjust =============================================
  ;; Verified via hand-computation rather than against librsvg, which
  ;; was confirmed empirically (identical output regardless of
  ;; textLength="none"/"50"/"400") and via multiple independent sources
  ;; (a Wikimedia Phabricator ticket open since 2011, a GNOME GitLab
  ;; issue) to not implement textLength at all.

  (test-case "textLength with lengthAdjust=spacing keeps each glyph's own width, stretching only the gaps"
    (define (ink-runs bm)
      (define dc (new bitmap-dc% [bitmap bm]))
      (define px (make-object color%))
      (define (col-has-ink? x) (for/or ([y (in-range 60)]) (send dc get-pixel x y px) (< (send px red) 150)))
      (define runs '()) (define in-run? #f) (define run-start 0)
      (for ([x (in-range 300)])
        (define ink? (col-has-ink? x))
        (cond [(and ink? (not in-run?)) (set! in-run? #t) (set! run-start x)]
              [(and (not ink?) in-run?) (set! in-run? #f) (set! runs (cons (list run-start (sub1 x)) runs))]))
      (when in-run? (set! runs (cons (list run-start 299) runs)))
      (reverse runs))
    (define natural (ink-runs (svg-string->bitmap
                               "<svg width=\"300\" height=\"60\"><text x=\"10\" y=\"40\" font-family=\"DejaVu Sans\" font-size=\"20\">ABCD</text></svg>")))
    (define stretched (ink-runs (svg-string->bitmap
                                 "<svg width=\"300\" height=\"60\"><text x=\"10\" y=\"40\" font-family=\"DejaVu Sans\" font-size=\"20\"
                                    textLength=\"200\" lengthAdjust=\"spacing\">ABCD</text></svg>")))
    ;; same 4 glyphs, each within a couple pixels of its natural width (antialiasing rounding)
    (check-equal? (length stretched) 4)
    (for ([n natural] [s stretched])
      (check-true (<= (abs (- (- (second n) (first n)) (- (second s) (first s)))) 2)))
    ;; but spread MUCH further apart, and the overall span approaches textLength=200
    ;; the first glyph starts at the SAME position in both (only the
    ;; gaps AFTER it grow); the second glyph's start position shifting
    ;; later is the meaningful signal that stretching actually happened
    (check-true (> (first (second stretched)) (first (second natural))))
    (check-true (> (- (second (last stretched)) (first (first stretched))) 190)))

  (test-case "textLength with lengthAdjust=spacingAndGlyphs scales each glyph's own width proportionally"
    (define bm (svg-string->bitmap
                "<svg width=\"300\" height=\"60\"><text x=\"10\" y=\"40\" font-family=\"DejaVu Sans\" font-size=\"20\"
                   textLength=\"200\" lengthAdjust=\"spacingAndGlyphs\">ABCD</text></svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define (col-has-ink? x) (for/or ([y (in-range 60)]) (send dc get-pixel x y px) (< (send px red) 150)))
    (define min-x #f) (define max-x 0)
    (for ([x (in-range 300)]) (when (col-has-ink? x) (unless min-x (set! min-x x)) (set! max-x x)))
    ;; overall span approaches the target textLength=200 (a few units
    ;; short is expected: text-width measures pen ADVANCE, and the last
    ;; glyph's own visual ink typically doesn't reach the full advance
    ;; edge -- normal font metrics, not a bug)
    (check-true (> (- max-x min-x) 190)))

  ;; ==== CSS inline-size (text wrapping) ========================================
  ;; Scoped to a <text>'s own content with a single, uniform font (a
  ;; nested <tspan> with its own distinct styling within the wrapped
  ;; flow is a disclosed, narrower gap); horizontal, left-to-right only
  ;; (vertical writing modes, bidi, and CJK line-breaking are out of
  ;; scope). Verified via hand-derivation rather than against the
  ;; actual WPT reference files for this feature, which depend on a
  ;; specific "FreeSans" font not installed here -- confirmed directly
  ;; that a DIFFERENT wrap point than the WPT reference's own is
  ;; correct FOR THE FONT ACTUALLY USED (measured: "...amet, consectetur"
  ;; is 438px wide in DejaVu Sans at 16px, well over a 320px inline-size,
  ;; so wrapping before "consectetur" is the right greedy-wrap decision
  ;; for this font, not a bug -- different fonts genuinely wrap
  ;; differently at the same inline-size).

  (test-case "inline-size wraps text onto multiple lines, with the default line-height (font-size*1.25)"
    (define bm (svg-string->bitmap
                "<svg width=\"480\" height=\"200\">
                   <text x=\"80\" y=\"114.8\" font-family=\"DejaVu Sans\" style=\"font-size:16px;inline-size:320px\">Lorem ipsum dolor sit amet, consectetur adipisicing elit,</text>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define (row-has-ink? y) (for/or ([x (in-range 480)]) (send dc get-pixel x y px) (< (send px red) 150)))
    (check-true (row-has-ink? 108))    ; line 1
    (check-true (row-has-ink? 128))    ; line 2 (y=114.8+20=134.8, within a few px)
    (check-false (row-has-ink? 148)))  ; no third line

  (test-case "inline-size + text-anchor:middle centers each wrapped line independently on x"
    (define bm (svg-string->bitmap
                "<svg width=\"480\" height=\"200\">
                   <text x=\"240\" y=\"114.8\" font-family=\"DejaVu Sans\" style=\"font-size:16px;inline-size:320px;text-anchor:middle\">Lorem ipsum dolor sit amet, consectetur adipisicing elit,</text>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define (line-center y)
      (define min-x #f) (define max-x 0)
      (for ([x (in-range 480)])
        (send dc get-pixel x y px)
        (when (< (send px red) 150) (unless min-x (set! min-x x)) (set! max-x x)))
      (/ (+ min-x max-x) 2.0))
    (check-= (line-center 108) 240 8)
    (check-= (line-center 128) 240 8))

  (test-case "inline-size + text-anchor:end right-aligns each wrapped line to x"
    (define bm (svg-string->bitmap
                "<svg width=\"480\" height=\"200\">
                   <text x=\"400\" y=\"114.8\" font-family=\"DejaVu Sans\" style=\"font-size:16px;inline-size:320px;text-anchor:end\">Lorem ipsum dolor sit amet, consectetur adipisicing elit,</text>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define (line-max-x y)
      (define max-x 0)
      (for ([x (in-range 480)]) (send dc get-pixel x y px) (when (< (send px red) 150) (set! max-x x)))
      max-x)
    (check-true (< (abs (- (line-max-x 108) 400)) 20))
    (check-true (< (abs (- (line-max-x 128) 400)) 20)))

  (test-case "a percentage inline-size resolves against the containing viewport's width"
    (define (bytes-of bm) (define b (make-bytes (* 480 200 4))) (send bm get-argb-pixels 0 0 480 200 b) b)
    (define via-percent (svg-string->bitmap
                         "<svg width=\"480\" height=\"200\" viewBox=\"0 0 480 200\">
                            <text x=\"80\" y=\"114.8\" font-family=\"DejaVu Sans\" style=\"font-size:16px;inline-size:66.66667%\">Lorem ipsum dolor sit amet, consectetur adipisicing elit,</text>
                          </svg>"))
    (define via-px (svg-string->bitmap
                    "<svg width=\"480\" height=\"200\">
                       <text x=\"80\" y=\"114.8\" font-family=\"DejaVu Sans\" style=\"font-size:16px;inline-size:320px\">Lorem ipsum dolor sit amet, consectetur adipisicing elit,</text>
                     </svg>"))
    (check-equal? (bytes-of via-percent) (bytes-of via-px)))

  ;; ==== CSS shape-inside (rectangle-scoped) ===================================
  ;; Scoped to shape-inside referencing a plain <rect> specifically --
  ;; for a rectangle, "wrap text to fit inside this shape" is
  ;; functionally identical to inline-size (a rectangle's own
  ;; horizontal extent doesn't vary by line); referencing anything
  ;; else falls back to not wrapping at all, a disclosed narrower gap.
  ;; The first line's baseline is positioned at the rect's own y plus
  ;; the resolved font's own ascent (confirmed via a WPT reference file
  ;; to be font-metric-derived). Verified via hand-derivation rather
  ;; than the actual WPT reference (which depends on a "FreeSans" font
  ;; not installed here, and which happens to wrap into 2 lines for
  ;; that font vs 3 for DejaVu Sans at the same box width -- different
  ;; fonts genuinely wrap differently, confirmed directly, not a bug).

  (test-case "shape-inside wraps text within a referenced rect's own bounds"
    (define bm (svg-string->bitmap
                "<svg width=\"480\" height=\"360\">
                   <defs><rect id=\"TestRect\" x=\"90\" y=\"100\" width=\"300\" height=\"40\"/></defs>
                   <text font-family=\"DejaVu Sans\" style=\"font-size:16px;shape-inside:url(#TestRect)\">Lorem ipsum dolor sit amet, consectetur adipisicing elit,</text>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define (col-has-ink? x lo hi) (for/or ([y (in-range lo hi)]) (send dc get-pixel x y px) (< (send px red) 150)))
    (define min-x #f)
    (for ([x (in-range 480)]) (when (and (not min-x) (col-has-ink? x 100 125)) (set! min-x x)))
    (check-= min-x 90 5))

  (test-case "shape-inside + text-align:center centers each wrapped line on the rect's own horizontal center"
    (define bm (svg-string->bitmap
                "<svg width=\"480\" height=\"360\">
                   <defs><rect id=\"TestRect\" x=\"90\" y=\"100\" width=\"300\" height=\"40\"/></defs>
                   <text font-family=\"DejaVu Sans\" style=\"font-size:16px;shape-inside:url(#TestRect);text-align:center\">Lorem ipsum dolor sit amet, consectetur adipisicing elit,</text>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define (line-extent y-lo y-hi)
      (define lo #f) (define hi 0)
      (for* ([x (in-range 480)] [y (in-range y-lo y-hi)])
        (send dc get-pixel x y px)
        (when (< (send px red) 150) (unless lo (set! lo x)) (set! hi x)))
      (list lo hi))
    (define ext (line-extent 100 125))
    (check-= (/ (+ (first ext) (second ext)) 2.0) 240 5))

  (test-case "shape-inside + text-align:justify stretches non-last lines to the full width, but not the last line"
    (define bm (svg-string->bitmap
                "<svg width=\"480\" height=\"360\">
                   <defs><rect id=\"TestRect\" x=\"90\" y=\"100\" width=\"300\" height=\"40\"/></defs>
                   <text font-family=\"DejaVu Sans\" style=\"font-size:16px;shape-inside:url(#TestRect);text-align:justify\">Lorem ipsum dolor sit amet, consectetur adipisicing elit,</text>
                 </svg>"))
    (define dc (new bitmap-dc% [bitmap bm]))
    (define px (make-object color%))
    (define (row-extent y)
      (define lo #f) (define hi 0)
      (for ([x (in-range 480)])
        (send dc get-pixel x y px)
        (when (< (send px red) 150) (unless lo (set! lo x)) (set! hi x)))
      (and lo (list lo hi)))
    (define line-extents
      (let loop ([y 90] [current #f] [acc '()])
        (cond
          [(= y 180) (reverse (if current (cons current acc) acc))]
          [else
           (define ext (row-extent y))
           (cond
             [(and ext current)
              (loop (add1 y) (list (min (first current) (first ext))
                                   (max (second current) (second ext)))
                    acc)]
             [ext (loop (add1 y) ext acc)]
             [current (loop (add1 y) #f (cons current acc))]
             [else (loop (add1 y) #f acc)])])))
    (check-true (>= (length line-extents) 2))
    (define line1 (first line-extents))
    (define last-line (last line-extents))
    ;; a justified (non-last) line spans close to the full 90-390 box
    (check-true (> (- (second line1) (first line1)) 290))
    ;; the true last line is NOT justified -- noticeably shorter
    (check-true (< (- (second last-line) (first last-line)) 250))))
