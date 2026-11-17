//! Rust port of `scripts/import/import.py`.
//!
//! Reads vectors from a binary or HDF5 file and upserts them into a Casper or
//! Qdrant collection via the corresponding HTTP API. Behaviour, CLI flags,
//! and on-disk binary format are kept identical to the Python version so the
//! two implementations are interchangeable.

use anyhow::{Context, Result, anyhow, bail};
use byteorder::{BigEndian, ReadBytesExt};
use clap::{Parser, ValueEnum};
use serde::Serialize;
use std::fs::File;
use std::io::{BufReader, Read};
use std::path::PathBuf;
use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
#[clap(rename_all = "lowercase")]
enum InputFormat {
    Bin,
    Hdf5,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
#[clap(rename_all = "lowercase")]
enum Backend {
    Casper,
    Qdrant,
}

#[derive(Parser, Debug)]
#[command(name = "import", about = "Import vectors from a binary/HDF5 file into Casper or Qdrant.")]
struct Args {
    /// Path to input vectors file.
    path: PathBuf,

    /// Input file format.
    #[arg(long, value_enum, default_value_t = InputFormat::Bin)]
    format: InputFormat,

    /// (HDF5) Dataset name to read vectors from. Required when --format hdf5.
    #[arg(long)]
    dataset: Option<String>,

    /// Base URL.
    #[arg(long, default_value = "http://localhost:7222")]
    base_url: String,

    /// Collection name (e.g. alex).
    #[arg(long)]
    collection: String,

    /// Backend to import into.
    #[arg(long, value_enum, default_value_t = Backend::Casper)]
    backend: Backend,

    /// Batch size for Casper batch update / Qdrant upserts.
    #[arg(long, default_value_t = 256)]
    batch_size: usize,

    /// (Qdrant) Wait for upsert to be processed before returning.
    #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
    wait: bool,

    /// Do not print per-batch progress logs.
    #[arg(long, default_value_t = false)]
    quiet: bool,
}

#[derive(Serialize)]
struct Point {
    id: u32,
    vector: Vec<f32>,
}

#[derive(Serialize)]
struct CasperBatch<'a> {
    upserts: &'a [Point],
    delete: &'a [u32],
}

#[derive(Serialize)]
struct QdrantBatch<'a> {
    points: &'a [Point],
}

struct Hdf5Reader {
    count: usize,
    dataset: hdf5::Dataset,
    cursor: usize,
}

impl Iterator for Hdf5Reader {
    type Item = Result<Point>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.cursor >= self.count {
            return None;
        }
        let i = self.cursor;
        self.cursor += 1;
        match self.dataset.read_slice_1d::<f32, _>(ndarray::s![i, ..]) {
            Ok(row) => Some(Ok(Point {
                id: i as u32,
                vector: row.to_vec(),
            })),
            Err(e) => Some(Err(anyhow!("hdf5 read error at row {i}: {e}"))),
        }
    }
}

struct BinReader {
    reader: BufReader<File>,
    dim: usize,
    remaining: usize,
}

impl BinReader {
    fn open(path: &PathBuf) -> Result<(usize, usize, Self)> {
        let file = File::open(path).with_context(|| format!("opening {}", path.display()))?;
        let mut reader = BufReader::new(file);
        let dim = reader
            .read_u32::<BigEndian>()
            .map_err(|_| anyhow!("File too short: missing header (dimension)"))? as usize;
        let count = reader.read_u32::<BigEndian>().map_err(|_| anyhow!("File too short: missing header (count)"))? as usize;
        Ok((dim, count, BinReader { reader, dim, remaining: count }))
    }
}

impl Iterator for BinReader {
    type Item = Result<Point>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.remaining == 0 {
            return None;
        }
        self.remaining -= 1;
        let id = match self.reader.read_u32::<BigEndian>() {
            Ok(v) => v,
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return None,
            Err(e) => return Some(Err(anyhow!("Truncated file: cannot read id ({e})"))),
        };
        let mut vector = vec![0f32; self.dim];
        let mut buf = vec![0u8; self.dim * 4];
        if let Err(e) = self.reader.read_exact(&mut buf) {
            return Some(Err(anyhow!("Truncated file: cannot read vector for id={id} ({e})")));
        }
        for (i, chunk) in buf.chunks_exact(4).enumerate() {
            vector[i] = f32::from_be_bytes(chunk.try_into().unwrap());
        }
        Some(Ok(Point { id, vector }))
    }
}

fn open_hdf5(path: &PathBuf, dataset_name: &str) -> Result<(usize, usize, Hdf5Reader)> {
    let file = hdf5::File::open(path).with_context(|| format!("opening hdf5 file {}", path.display()))?;
    let names = file.member_names().unwrap_or_default();
    if !names.iter().any(|n| n == dataset_name) {
        let mut sorted = names.clone();
        sorted.sort();
        let available = if sorted.is_empty() { "<none>".into() } else { sorted.join(", ") };
        bail!("Dataset '{dataset_name}' not found in HDF5 file. Available top-level datasets: {available}");
    }
    let dataset = file.dataset(dataset_name).with_context(|| format!("opening dataset '{dataset_name}'"))?;
    let shape = dataset.shape();
    if shape.len() != 2 {
        bail!("Dataset '{dataset_name}' must be 2D [count, dim], got shape={:?}", shape);
    }
    let count = shape[0];
    let dim = shape[1];
    Ok((dim, count, Hdf5Reader { count, dataset, cursor: 0 }))
}

fn send_casper(client: &reqwest::blocking::Client, base_url: &str, collection: &str, batch: &[Point]) -> Result<()> {
    let url = format!("{}/collection/{}/update", base_url.trim_end_matches('/'), collection);
    let body = CasperBatch { upserts: batch, delete: &[] };
    let resp = client.post(&url).json(&body).send().with_context(|| format!("POST {url}"))?;
    let status = resp.status();
    if !status.is_success() {
        let text = resp.text().unwrap_or_default();
        bail!("Casper {url} returned {status}: {text}");
    }
    Ok(())
}

fn send_qdrant(client: &reqwest::blocking::Client, base_url: &str, collection: &str, batch: &[Point], wait: bool) -> Result<()> {
    let url = format!("{}/collections/{}/points", base_url.trim_end_matches('/'), collection);
    let body = QdrantBatch { points: batch };
    let resp = client
        .put(&url)
        .query(&[("wait", if wait { "true" } else { "false" })])
        .json(&body)
        .send()
        .with_context(|| format!("PUT {url}"))?;
    let status = resp.status();
    if !status.is_success() {
        let text = resp.text().unwrap_or_default();
        bail!("Qdrant {url} returned {status}: {text}");
    }
    Ok(())
}

fn main() -> Result<()> {
    let args = Args::parse();

    match (args.format, &args.dataset) {
        (InputFormat::Hdf5, None) => bail!("--dataset is required when --format hdf5"),
        (InputFormat::Bin, Some(_)) => bail!("--dataset can only be used with --format hdf5"),
        _ => {}
    }
    if args.batch_size == 0 {
        bail!("--batch-size must be > 0");
    }

    println!("Importing vectors from file: {}", args.path.display());
    println!("Input format: {:?}", args.format);
    if let Some(ds) = &args.dataset {
        println!("Dataset: {ds}");
    }
    println!("Server URL: {}", args.base_url);
    println!("Collection: {}", args.collection);
    println!("Backend: {:?}", args.backend);
    if matches!(args.backend, Backend::Qdrant) {
        println!("Batch size: {}", args.batch_size);
        println!("Wait: {}", args.wait);
    }
    println!();

    let (dim, count, iter): (usize, usize, Box<dyn Iterator<Item = Result<Point>>>) = match args.format {
        InputFormat::Bin => {
            let (d, c, r) = BinReader::open(&args.path).context("reading file")?;
            (d, c, Box::new(r))
        }
        InputFormat::Hdf5 => {
            let dataset = args.dataset.as_deref().unwrap_or("");
            let (d, c, r) = open_hdf5(&args.path, dataset).context("reading file")?;
            (d, c, Box::new(r))
        }
    };

    println!("File info:");
    println!("  Dimension: {dim}");
    println!("  Documents: {count}");
    println!();

    let client = reqwest::blocking::Client::builder().timeout(Duration::from_secs(120)).build()?;

    let mut batch: Vec<Point> = Vec::with_capacity(args.batch_size);
    let mut processed: usize = 0;

    let flush = |client: &reqwest::blocking::Client, batch: &[Point]| -> Result<()> {
        match args.backend {
            Backend::Casper => send_casper(client, &args.base_url, &args.collection, batch),
            Backend::Qdrant => send_qdrant(client, &args.base_url, &args.collection, batch, args.wait),
        }
    };

    for item in iter {
        let point = item.context("reading document")?;
        batch.push(point);
        processed += 1;
        if batch.len() >= args.batch_size {
            flush(&client, &batch)?;
            if !args.quiet {
                println!("✓ Imported batch, processed={processed}/{count}");
            }
            batch.clear();
        }
    }
    if !batch.is_empty() {
        flush(&client, &batch)?;
        if !args.quiet {
            println!("✓ Imported batch, processed={processed}/{count}");
        }
    }

    println!();
    println!("Import finished. Processed documents: {processed}");
    Ok(())
}
