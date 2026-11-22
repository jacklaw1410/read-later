/// A scatter of `points` with an optional regression line `y = a + b·x`.
pub fn scatter(points: &[(f64, f64)], line: Option<(f64, f64)>, x_label: &str, y_label: &str) -> String {
    const W: f64 = 720.0;
    const H: f64 = 460.0;
    const L: f64 = 70.0;
    const R: f64 = 20.0;
    const T: f64 = 20.0;
    const B: f64 = 60.0;

    let xs = points.iter().map(|p| p.0);
    let ys = points.iter().map(|p| p.1);
    let x_max = xs.clone().fold(0.0_f64, f64::max).max(1.0);
    let y_max = ys.clone().fold(0.0_f64, f64::max).max(1.0);
    let sx = |x: f64| L + x / x_max * (W - L - R);
    let sy = |y: f64| H - B - y / y_max * (H - B - T);

    let mut out = String::new();
    out.push_str(&format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{W}\" height=\"{H}\" viewBox=\"0 0 {W} {H}\">\n"
    ));
    out.push_str("<rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n");
    out.push_str(&format!(
        "<line x1=\"{L}\" y1=\"{y0}\" x2=\"{x1}\" y2=\"{y0}\" stroke=\"black\"/>\n<line x1=\"{L}\" y1=\"{T}\" x2=\"{L}\" y2=\"{y0}\" stroke=\"black\"/>\n",
        y0 = H - B,
        x1 = W - R,
    ));
    out.push_str(&format!(
        "<text x=\"{x}\" y=\"{y}\" font-family=\"sans-serif\" font-size=\"13\" text-anchor=\"middle\">{x_label}</text>\n",
        x = (L + W - R) / 2.0,
        y = H - 18.0,
    ));
    out.push_str(&format!(
        "<text x=\"16\" y=\"{y}\" font-family=\"sans-serif\" font-size=\"13\" text-anchor=\"middle\" transform=\"rotate(-90 16 {y})\">{y_label}</text>\n",
        y = (T + H - B) / 2.0,
    ));
    if let Some((a, b)) = line {
        out.push_str(&format!(
            "<line x1=\"{x1}\" y1=\"{y1}\" x2=\"{x2}\" y2=\"{y2}\" stroke=\"#c0392b\" stroke-width=\"2\"/>\n",
            x1 = sx(0.0),
            y1 = sy(a.max(0.0).min(y_max)),
            x2 = sx(x_max),
            y2 = sy((a + b * x_max).max(0.0).min(y_max)),
        ));
    }
    for (x, y) in points {
        out.push_str(&format!(
            "<circle cx=\"{cx:.1}\" cy=\"{cy:.1}\" r=\"3\" fill=\"#2c3e50\"/>\n",
            cx = sx(*x),
            cy = sy(*y),
        ));
    }
    out.push_str("</svg>\n");
    out
}
