( v2.fy - first testable NEON f64x2 primitive kernels.

  These operate on raw f64x2 buffers:
    k-v2-add    ( dst a b -- )
    k-v2-mul    ( dst a b -- )
    k-v2-fmadd  ( dst acc a b -- )

  They are intentionally tiny. The Slab kernel probe exercises them as
  compiler/ABI fixtures before higher-level audio kernels depend on them. )

dsp: k-v2-add v2f+ ;
dsp: k-v2-mul v2f* ;
dsp: k-v2-fmadd v2fmadd ;
