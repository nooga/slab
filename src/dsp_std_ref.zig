//! Zig mirrors of dsp-std words (kernels/00-primitives/math.fy), operation
//! for operation, so kernel equivalence tests can pin fy codegen to a
//! reference at machine precision. Keep in step with math.fy.

fn sinR(r: f64) f64 {
    const s = r * r;
    var p: f64 = -2.3909597256746232e-08;
    p = p * s + 2.7526639292592648e-06;
    p = p * s + -0.00019840894515007722;
    p = p * s + 0.008333331326760368;
    p = p * s + -0.16666666631809604;
    return p * s * r + r;
}

fn turnSign(n: f64) f64 {
    return 1.0 - (n - @floor(n * 0.5) * 2.0) * 2.0;
}

/// sin(pi y)
pub fn sinpi(y: f64) f64 {
    const n = @floor(y + 0.5);
    return sinR((y - n) * 3.141592653589793) * turnSign(n);
}

/// sin(2 pi p), p any phase
pub fn sin2pi(p: f64) f64 {
    return sinpi((p - @floor(p)) * 2.0);
}
