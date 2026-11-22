use serde_json::Value;

#[derive(Debug, Clone, PartialEq)]
pub struct Sample {
    pub sweep: String,
    pub source: String,
    pub article: String,
    pub arm: String,
    pub blocks: f64,
    pub words: f64,
    pub wpb: f64,
    pub bytes: f64,
    pub ms: f64,
    pub ms_min: Option<f64>,
    pub ms_max: Option<f64>,
    pub reps: Option<f64>,
    pub nodes: Option<f64>,
}

/// One telemetry-recorded `ArticleIngress.read` call. `extract_ms` runs from
/// `extract.start` to `T4.parsed`. `plan_ms` runs from `T4.parsed` to `T5.planReady`,
/// and includes the page hash, which the shipped code computes in that span.
#[derive(Debug, Clone, PartialEq)]
pub struct Split {
    pub article: String,
    pub extract_ms: f64,
    pub plan_ms: f64,
}

#[derive(Debug, Default)]
pub struct Log {
    pub samples: Vec<Sample>,
    pub splits: Vec<Split>,
    pub skipped: usize,
    pub builds: Vec<String>,
}

fn text<'a>(fields: &'a Value, name: &str) -> &'a str {
    fields[name].as_str().unwrap_or("")
}

fn number(fields: &Value, name: &str) -> Result<f64, String> {
    text(fields, name)
        .parse::<f64>()
        .map_err(|_| format!("field `{name}` is not a number: {}", fields[name]))
}

fn optional(fields: &Value, name: &str) -> Option<f64> {
    text(fields, name).parse::<f64>().ok()
}

/// Reads one oplog file into `log`. Events are read in file order, so each
/// `probe.call` marker owns the telemetry events that follow it.
pub fn parse(source: &str, log: &mut Log) -> Result<(), String> {
    let mut current: Option<String> = None;
    let mut started: Option<f64> = None;
    let mut parsed: Option<f64> = None;

    for (number_of_line, line) in source.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let event: Value = serde_json::from_str(line)
            .map_err(|e| format!("line {}: {e}", number_of_line + 1))?;
        let name = event["event"].as_str().unwrap_or("");
        let fields = &event["fields"];
        let t = event["t"].as_f64().unwrap_or(f64::NAN);

        match name {
            "probe.start" => log.builds.push(format!("{} {}", text(fields, "build"), text(fields, "os"))),
            "probe.skip" => log.skipped += 1,
            "probe.call" => {
                current = Some(text(fields, "article").to_string());
                started = None;
                parsed = None;
            }
            "extract.start" => {
                if current.is_some() {
                    started = Some(t);
                }
            }
            "T4.parsed" => {
                if started.is_some() {
                    parsed = Some(t);
                }
            }
            "T5.planReady" => {
                if let (Some(article), Some(s), Some(p)) = (current.clone(), started, parsed) {
                    log.splits.push(Split {
                        article,
                        extract_ms: (p - s) * 1000.0,
                        plan_ms: (t - p) * 1000.0,
                    });
                }
                started = None;
                parsed = None;
            }
            "probe.sample" => log.samples.push(Sample {
                sweep: text(fields, "sweep").to_string(),
                source: text(fields, "source").to_string(),
                article: text(fields, "article").to_string(),
                arm: text(fields, "arm").to_string(),
                blocks: number(fields, "blocks")?,
                words: number(fields, "words")?,
                wpb: number(fields, "wpb")?,
                bytes: number(fields, "bytes")?,
                ms: number(fields, "ms")?,
                ms_min: optional(fields, "ms_min"),
                ms_max: optional(fields, "ms_max"),
                reps: optional(fields, "reps"),
                nodes: optional(fields, "nodes"),
            }),
            _ => {}
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const LINE_SAMPLE: &str = r#"{"t":1.0,"event":"probe.sample","fields":{"sweep":"A","source":"synthetic","article":"A-b25-w30-s1","arm":"plan","blocks":"25","words":"750","wpb":"30.000","bytes":"4000","ms":"0.5","iters":"40","checksum":"1"}}"#;

    #[test]
    fn parses_a_sample() {
        let mut log = Log::default();
        parse(LINE_SAMPLE, &mut log).unwrap();
        assert_eq!(log.samples.len(), 1);
        assert_eq!(log.samples[0].blocks, 25.0);
        assert_eq!(log.samples[0].ms, 0.5);
        assert_eq!(log.samples[0].nodes, None);
    }

    #[test]
    fn reads_spread_and_node_fields_when_present() {
        let line = r#"{"t":1.0,"event":"probe.sample","fields":{"sweep":"real","source":"file","article":"082-nyt-cooking","arm":"extract","blocks":"2","words":"6","wpb":"3.0","bytes":"300000","ms":"200.0","ms_min":"190.0","ms_max":"260.0","reps":"5","nodes":"4100","checksum":"1"}}"#;
        let mut log = Log::default();
        parse(line, &mut log).unwrap();
        let s = &log.samples[0];
        assert_eq!(s.ms_min, Some(190.0));
        assert_eq!(s.ms_max, Some(260.0));
        assert_eq!(s.reps, Some(5.0));
        assert_eq!(s.nodes, Some(4100.0));
    }

    #[test]
    fn pairs_telemetry_stages_under_their_call_marker() {
        let text = [
            r#"{"t":10.0,"event":"probe.call","fields":{"article":"x"}}"#,
            r#"{"t":10.1,"event":"extract.start","fields":{"bytes":"9"}}"#,
            r#"{"t":10.3,"event":"T4.parsed","fields":{"blocks":"2"}}"#,
            r#"{"t":10.6,"event":"T5.planReady","fields":{"sentences":"3","words":"9"}}"#,
            r#"{"t":11.0,"event":"probe.call","fields":{"article":"x"}}"#,
            r#"{"t":11.1,"event":"extract.start","fields":{"bytes":"9"}}"#,
        ]
        .join("\n");
        let mut log = Log::default();
        parse(&text, &mut log).unwrap();
        assert_eq!(log.splits.len(), 1);
        assert!((log.splits[0].extract_ms - 200.0).abs() < 1e-6);
        assert!((log.splits[0].plan_ms - 300.0).abs() < 1e-6);
    }

    #[test]
    fn a_failed_read_leaves_no_split() {
        let text = [
            r#"{"t":1.0,"event":"probe.call","fields":{"article":"y"}}"#,
            r#"{"t":1.1,"event":"extract.start","fields":{}}"#,
            r#"{"t":1.2,"event":"extract.failed","fields":{"kind":"walled"}}"#,
            r#"{"t":2.0,"event":"probe.call","fields":{"article":"z"}}"#,
        ]
        .join("\n");
        let mut log = Log::default();
        parse(&text, &mut log).unwrap();
        assert!(log.splits.is_empty());
    }
}
