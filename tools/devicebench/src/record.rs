//! Microphone capture and WAV I/O. The only module that touches the audio device.

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::SampleFormat;

/// Records `seconds` from the input device, keeping the first channel only.
/// Writes a 32-bit float mono WAV and a JSON sidecar next to it. Returns the
/// Mac's wall clock, in seconds since 1970, taken when the stream started.
///
/// The recording's own clock is the sample count from the first sample. The
/// wall-clock start anchors that clock to the phone's `iso` stamps.
pub fn record(seconds: f64, out: &Path, device_name: Option<&str>) -> Result<f64, String> {
    let host = cpal::default_host();
    let device = match device_name {
        Some(wanted) => host
            .input_devices()
            .map_err(|e| e.to_string())?
            .find(|d| d.name().ok().as_deref() == Some(wanted)),
        None => host.default_input_device(),
    }
    .ok_or("no input device found (check System Settings > Privacy > Microphone)")?;
    let name = device.name().unwrap_or_else(|_| "unknown".into());

    let supported = device.default_input_config().map_err(|e| e.to_string())?;
    let format = supported.sample_format();
    let config: cpal::StreamConfig = supported.config();
    let channels = config.channels as usize;
    let rate = config.sample_rate.0;

    let samples = Arc::new(Mutex::new(Vec::<f32>::new()));
    let err = |e| eprintln!("stream error: {e}");
    let stream = match format {
        SampleFormat::F32 => {
            let sink = Arc::clone(&samples);
            device.build_input_stream(
                &config,
                move |data: &[f32], _: &cpal::InputCallbackInfo| push(&sink, data.iter().copied(), channels),
                err,
                None,
            )
        }
        SampleFormat::I16 => {
            let sink = Arc::clone(&samples);
            device.build_input_stream(
                &config,
                move |data: &[i16], _: &cpal::InputCallbackInfo| {
                    push(&sink, data.iter().map(|&s| s as f32 / 32_768.0), channels)
                },
                err,
                None,
            )
        }
        other => return Err(format!("unsupported sample format {other:?}")),
    }
    .map_err(|e| e.to_string())?;

    stream.play().map_err(|e| e.to_string())?;
    let started = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_secs_f64();
    thread::sleep(Duration::from_secs_f64(seconds));
    drop(stream);

    let mono = samples.lock().map_err(|_| "sample buffer poisoned")?.clone();
    write_wav(out, &mono, rate)?;
    let sidecar = serde_json::json!({
        "device": name,
        "sample_rate": rate,
        "channels_recorded": 1,
        "channels_in_device": channels,
        "frames": mono.len(),
        "seconds": mono.len() as f64 / rate as f64,
        "started_unix": started,
    });
    std::fs::write(out.with_extension("json"), sidecar.to_string()).map_err(|e| e.to_string())?;
    Ok(started)
}

/// Appends the first channel of each frame. The callback holds the lock for
/// one short append per buffer.
fn push(sink: &Arc<Mutex<Vec<f32>>>, interleaved: impl Iterator<Item = f32>, channels: usize) {
    if let Ok(mut buffer) = sink.lock() {
        for (i, sample) in interleaved.enumerate() {
            if i % channels == 0 {
                buffer.push(sample);
            }
        }
    }
}

pub fn write_wav(path: &Path, samples: &[f32], rate: u32) -> Result<(), String> {
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: rate,
        bits_per_sample: 32,
        sample_format: hound::SampleFormat::Float,
    };
    let mut writer = hound::WavWriter::create(path, spec).map_err(|e| e.to_string())?;
    for &s in samples {
        writer.write_sample(s).map_err(|e| e.to_string())?;
    }
    writer.finalize().map_err(|e| e.to_string())
}

/// Reads a WAV as mono `f32` samples. Multi-channel files are reduced to the first channel.
pub fn read_wav(path: &Path) -> Result<(Vec<f32>, f64), String> {
    let mut reader = hound::WavReader::open(path).map_err(|e| e.to_string())?;
    let spec = reader.spec();
    let channels = spec.channels as usize;
    let samples: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Float => reader
            .samples::<f32>()
            .collect::<Result<_, _>>()
            .map_err(|e| e.to_string())?,
        hound::SampleFormat::Int => {
            let scale = (1i64 << (spec.bits_per_sample - 1)) as f32;
            reader
                .samples::<i32>()
                .map(|s| s.map(|v| v as f32 / scale))
                .collect::<Result<_, _>>()
                .map_err(|e| e.to_string())?
        }
    };
    let mono = samples.into_iter().step_by(channels.max(1)).collect();
    Ok((mono, spec.sample_rate as f64))
}
