use std::cmp::Ordering;

/// Ordinary least squares with an intercept in column 0 when the caller adds one.
/// Columns are scaled before solving, so large and small regressors stay stable.
#[derive(Debug, Clone)]
pub struct Ols {
    pub coef: Vec<f64>,
    pub se: Vec<f64>,
    pub r2: f64,
    pub df: usize,
}

pub fn ols(columns: &[Vec<f64>], y: &[f64]) -> Option<Ols> {
    let p = columns.len();
    let n = y.len();
    if p == 0 || n <= p || columns.iter().any(|c| c.len() != n) {
        return None;
    }
    let scale: Vec<f64> = columns
        .iter()
        .map(|c| c.iter().fold(0.0_f64, |m, v| m.max(v.abs())).max(1e-300))
        .collect();
    let x: Vec<Vec<f64>> = columns
        .iter()
        .zip(&scale)
        .map(|(c, s)| c.iter().map(|v| v / s).collect())
        .collect();

    let mut xtx = vec![vec![0.0; p]; p];
    let mut xty = vec![0.0; p];
    for i in 0..p {
        for j in 0..p {
            xtx[i][j] = (0..n).map(|k| x[i][k] * x[j][k]).sum();
        }
        xty[i] = (0..n).map(|k| x[i][k] * y[k]).sum();
    }
    let inv = invert(&xtx)?;
    let beta: Vec<f64> = (0..p)
        .map(|i| (0..p).map(|j| inv[i][j] * xty[j]).sum())
        .collect();

    let rss: f64 = (0..n)
        .map(|k| {
            let fitted: f64 = (0..p).map(|i| beta[i] * x[i][k]).sum();
            (y[k] - fitted).powi(2)
        })
        .sum();
    let ybar = y.iter().sum::<f64>() / n as f64;
    let tss: f64 = y.iter().map(|v| (v - ybar).powi(2)).sum();
    let df = n - p;
    let sigma2 = rss / df as f64;

    Some(Ols {
        coef: beta.iter().zip(&scale).map(|(b, s)| b / s).collect(),
        se: (0..p).map(|i| (sigma2 * inv[i][i]).sqrt() / scale[i]).collect(),
        r2: if tss > 0.0 { 1.0 - rss / tss } else { 1.0 },
        df,
    })
}

fn invert(m: &[Vec<f64>]) -> Option<Vec<Vec<f64>>> {
    let n = m.len();
    let mut a: Vec<Vec<f64>> = m
        .iter()
        .enumerate()
        .map(|(i, row)| {
            let mut r = row.clone();
            r.extend((0..n).map(|j| if i == j { 1.0 } else { 0.0 }));
            r
        })
        .collect();
    for col in 0..n {
        let pivot = (col..n).max_by(|&x, &y| {
            a[x][col].abs().partial_cmp(&a[y][col].abs()).unwrap_or(Ordering::Equal)
        })?;
        if a[pivot][col].abs() < 1e-12 {
            return None;
        }
        a.swap(col, pivot);
        let p = a[col][col];
        for v in a[col].iter_mut() {
            *v /= p;
        }
        let pivot_row = a[col].clone();
        for (r, row) in a.iter_mut().enumerate() {
            if r != col {
                let f = row[col];
                if f != 0.0 {
                    for (v, c) in row.iter_mut().zip(&pivot_row) {
                        *v -= f * c;
                    }
                }
            }
        }
    }
    Some(a.into_iter().map(|row| row[n..].to_vec()).collect())
}

/// Log-log slope: the power-law exponent of `y` on `x`, with a 95 % interval.
#[derive(Debug, Clone, Copy)]
pub struct Slope {
    pub exponent: f64,
    pub lo: f64,
    pub hi: f64,
    pub n: usize,
}

pub fn loglog(points: &[(f64, f64)]) -> Option<Slope> {
    let pts: Vec<(f64, f64)> = points
        .iter()
        .filter(|(x, y)| *x > 0.0 && *y > 0.0)
        .map(|(x, y)| (x.ln(), y.ln()))
        .collect();
    let n = pts.len();
    if n < 3 {
        return None;
    }
    let ones = vec![1.0; n];
    let xs: Vec<f64> = pts.iter().map(|p| p.0).collect();
    let ys: Vec<f64> = pts.iter().map(|p| p.1).collect();
    let fit = ols(&[ones, xs], &ys)?;
    let t = t_critical(fit.df);
    let (e, se) = (fit.coef[1], fit.se[1]);
    Some(Slope { exponent: e, lo: e - t * se, hi: e + t * se, n })
}

/// Two-sided 95 % critical value of Student's t. Table up to 30 degrees of freedom.
pub fn t_critical(df: usize) -> f64 {
    const TABLE: [f64; 30] = [
        12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228,
        2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093, 2.086,
        2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042,
    ];
    match df {
        0 => f64::INFINITY,
        1..=30 => TABLE[df - 1],
        _ => 1.96,
    }
}

/// The pre-registered reading of a log-log slope. Linear needs the whole
/// interval inside [0.8, 1.2]. Quadratic needs the lower bound above 1.5.
pub fn verdict(s: &Slope) -> &'static str {
    if s.lo > 1.5 {
        "quadratic"
    } else if s.lo >= 0.8 && s.hi <= 1.2 {
        "linear"
    } else {
        "inconclusive"
    }
}

/// One synthetic or real measurement, as the two-term fit sees it.
#[derive(Debug, Clone, Copy)]
pub struct Row {
    pub ms: f64,
    pub words: f64,
    pub blocks: f64,
    pub wpb: f64,
}

/// `ms = a + b·words + c·blocks·wpb²`. The third coefficient is index 2.
/// `blocks·wpb²` equals `words·wpb`, so c is the cost per block of one word per block squared.
pub fn two_term(rows: &[Row]) -> Option<Ols> {
    let ones = vec![1.0; rows.len()];
    let words: Vec<f64> = rows.iter().map(|r| r.words).collect();
    let quad: Vec<f64> = rows.iter().map(|r| r.blocks * r.wpb * r.wpb).collect();
    let ys: Vec<f64> = rows.iter().map(|r| r.ms).collect();
    ols(&[ones, words, quad], &ys)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_power_law_gives_its_exponent() {
        let pts: Vec<(f64, f64)> = (1..=8).map(|x| (x as f64, 3.0 * (x as f64).powi(2))).collect();
        let s = loglog(&pts).unwrap();
        assert!((s.exponent - 2.0).abs() < 1e-9);
        assert_eq!(verdict(&s), "quadratic");
    }

    #[test]
    fn proportional_data_is_linear() {
        let pts: Vec<(f64, f64)> = (1..=8).map(|x| (x as f64, 0.5 * x as f64)).collect();
        let s = loglog(&pts).unwrap();
        assert!((s.exponent - 1.0).abs() < 1e-9);
        assert_eq!(verdict(&s), "linear");
    }

    #[test]
    fn noisy_slope_between_bands_is_inconclusive() {
        let pts = vec![(1.0, 1.0), (2.0, 2.9), (4.0, 3.6), (8.0, 9.2), (16.0, 14.0)];
        let s = loglog(&pts).unwrap();
        assert_eq!(verdict(&s), "inconclusive");
    }

    #[test]
    fn two_term_recovers_word_and_block_coefficients() {
        let shapes = [(25.0, 30.0), (50.0, 30.0), (100.0, 8.0), (100.0, 64.0), (400.0, 30.0), (20.0, 1000.0), (800.0, 30.0)];
        let rows: Vec<Row> = shapes
            .iter()
            .map(|&(blocks, wpb)| {
                let words = blocks * wpb;
                Row { ms: 5.0 + 0.02 * words + 0.3 * blocks * wpb * wpb, words, blocks, wpb }
            })
            .collect();
        let fit = two_term(&rows).unwrap();
        assert!((fit.coef[0] - 5.0).abs() < 1e-6);
        assert!((fit.coef[1] - 0.02).abs() < 1e-6);
        assert!((fit.coef[2] - 0.3).abs() < 1e-6);
    }

    #[test]
    fn three_columns_recover_bytes_and_node_coefficients() {
        let bytes: Vec<f64> = (1..=12).map(|i| (i * 1000) as f64).collect();
        let nodes: Vec<f64> = (1..=12).map(|i| (((i * i) % 17 + i) * 10) as f64).collect();
        let y: Vec<f64> = bytes.iter().zip(&nodes).map(|(b, n)| 5.0 + 0.002 * b + 0.04 * n).collect();
        let f = ols(&[vec![1.0; 12], bytes, nodes], &y).unwrap();
        assert!((f.coef[0] - 5.0).abs() < 1e-6);
        assert!((f.coef[1] - 0.002).abs() < 1e-9);
        assert!((f.coef[2] - 0.04).abs() < 1e-9);
        assert!((f.r2 - 1.0).abs() < 1e-9);
    }
}
