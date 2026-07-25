use casper_client::{CasperClient, SearchRequest};
use goose::prelude::*;
use hdf5::File;
use ndarray::s;
use qdrant_client::Qdrant;
use qdrant_client::qdrant::{SearchParamsBuilder, SearchPointsBuilder};
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use std::env;
use std::fs::File as StdFile;
use std::io::{BufReader, Read};
use std::sync::OnceLock;

const DEFAULT_VECTOR_DIM: usize = 96;
const DEFAULT_VECTOR_POOL_SIZE: usize = 100_000;
const DEFAULT_VECTOR_POOL_SEED: u64 = 1;

const DEFAULT_USER_START_OFFSET: usize = 1000;
const DEFAULT_USERS: usize = 32;
const DEFAULT_RUN_TIME_SECONDS: usize = 90;
const DEFAULT_SEARCH_LIMIT: usize = 1000;
const DEFAULT_OUTPUT_FORMAT: &str = "bin";
const ALLOWED_OUTPUT_FORMATS: &[&str] = &["json", "bin"];
const DEFAULT_BACKEND: &str = "casper";
const ALLOWED_BACKENDS: &[&str] = &["casper", "qdrant"];

static VECTOR_POOL: OnceLock<Vec<Vec<f64>>> = OnceLock::new();
static RUN_CONFIG: OnceLock<RunConfig> = OnceLock::new();
static QDRANT_CLIENT: OnceLock<Qdrant> = OnceLock::new();
static CASPER_CLIENT: OnceLock<CasperClient> = OnceLock::new();

enum PoolSource {
    Generated { size: usize, dim: usize, seed: u64 },
    Bin { path: String, size: usize },
    Hdf5 { path: String, dataset: String, size: usize },
}

#[derive(Clone)]
struct UserState {
    next: usize,
}

struct RunConfig {
    user_start_offset: usize,
    users: usize,
    run_time_seconds: usize,
    search_limit: usize,
    output_format: String,
    backend: String,
    ef_search: Option<usize>,
    qdrant_url: String,
    qdrant_collection: String,
    casper_host: String,
    casper_http_port: u16,
    casper_collection: String,
}

fn read_env_usize_or_default(name: &str, default: usize) -> usize {
    env::var(name).ok().and_then(|v| v.parse::<usize>().ok()).unwrap_or(default)
}

fn read_run_config() -> Result<RunConfig, String> {
    let output_format = env::var("OUTPUT_FORMAT").unwrap_or_else(|_| DEFAULT_OUTPUT_FORMAT.to_string());
    if !ALLOWED_OUTPUT_FORMATS.contains(&output_format.as_str()) {
        return Err(format!(
            "invalid OUTPUT_FORMAT '{output_format}', expected one of: {}",
            ALLOWED_OUTPUT_FORMATS.join(", ")
        ));
    }
    let backend = env::var("BACKEND").unwrap_or_else(|_| DEFAULT_BACKEND.to_string());
    if !ALLOWED_BACKENDS.contains(&backend.as_str()) {
        return Err(format!("invalid BACKEND '{backend}', expected one of: {}", ALLOWED_BACKENDS.join(", ")));
    }
    let ef_search = match env::var("HNSW_EF") {
        Ok(v) => Some(v.parse::<usize>().map_err(|_| "invalid HNSW_EF, expected unsigned integer".to_string())?),
        Err(_) => None,
    };
    if backend == "qdrant" && ef_search.is_none() {
        return Err("HNSW_EF is required when BACKEND=qdrant (we never want to fall through to Qdrant's server-side default)".to_string());
    }
    let qdrant_url = env::var("QDRANT_URL").unwrap_or_else(|_| "http://localhost:6334".to_string());
    let qdrant_collection = env::var("QDRANT_COLLECTION").unwrap_or_default();
    if backend == "qdrant" && qdrant_collection.is_empty() {
        return Err("QDRANT_COLLECTION is required when BACKEND=qdrant".to_string());
    }

    let casper_host = env::var("CASPER_HOST").unwrap_or_else(|_| "http://localhost".to_string());
    let casper_http_port = match env::var("CASPER_HTTP_PORT") {
        Ok(v) => v.parse::<u16>().map_err(|_| "invalid CASPER_HTTP_PORT, expected u16".to_string())?,
        Err(_) => 7222,
    };
    let casper_collection = env::var("CASPER_COLLECTION").unwrap_or_default();
    if backend == "casper" && casper_collection.is_empty() {
        return Err("CASPER_COLLECTION is required when BACKEND=casper".to_string());
    }

    Ok(RunConfig {
        user_start_offset: read_env_usize_or_default("USER_START_OFFSET", DEFAULT_USER_START_OFFSET),
        users: read_env_usize_or_default("USERS", DEFAULT_USERS),
        run_time_seconds: read_env_usize_or_default("RUN_TIME_SECONDS", DEFAULT_RUN_TIME_SECONDS),
        search_limit: read_env_usize_or_default("SEARCH_LIMIT", DEFAULT_SEARCH_LIMIT),
        output_format,
        backend,
        ef_search,
        qdrant_url,
        qdrant_collection,
        casper_host,
        casper_http_port,
        casper_collection,
    })
}

fn run_config() -> &'static RunConfig {
    RUN_CONFIG.get().expect("run config must be initialized in main()")
}

fn random_vector(rng: &mut impl Rng, dim: usize) -> Vec<f64> {
    let mut v: Vec<f64> = (0..dim).map(|_| rng.gen_range(0.0..1.0)).collect();
    let mut sum_sq = 0.0;
    for x in &v {
        sum_sq += x * x;
    }
    let norm = sum_sq.sqrt();
    if norm > 0.0 {
        for x in &mut v {
            *x /= norm;
        }
    }
    v
}

fn vector_pool() -> &'static [Vec<f64>] {
    VECTOR_POOL.get().expect("vector pool must be initialized in main()")
}

fn load_generated_pool(size: usize, dim: usize, seed: u64) -> Vec<Vec<f64>> {
    let mut rng = StdRng::seed_from_u64(seed);
    (0..size).map(|_| random_vector(&mut rng, dim)).collect()
}

fn load_bin_pool(path: &str, size: usize) -> Result<Vec<Vec<f64>>, String> {
    if size == 0 {
        return Err("pool size must be > 0".to_string());
    }
    let file = StdFile::open(path).map_err(|e| format!("failed to open bin file '{path}': {e}"))?;
    let mut reader = BufReader::new(file);
    let mut dim_buf = [0u8; 4];
    reader
        .read_exact(&mut dim_buf)
        .map_err(|e| format!("failed to read bin header dimension from '{path}': {e}"))?;
    let dim = u32::from_be_bytes(dim_buf) as usize;
    if dim == 0 {
        return Err(format!("bin file '{path}' has zero dimension"));
    }

    let mut count_buf = [0u8; 4];
    reader
        .read_exact(&mut count_buf)
        .map_err(|e| format!("failed to read bin header count from '{path}': {e}"))?;

    let mut vectors = Vec::with_capacity(size);
    for _ in 0..size {
        let mut id_buf = [0u8; 4];
        match reader.read_exact(&mut id_buf) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(e) => return Err(format!("failed to read vector id from '{path}': {e}")),
        }

        let mut vector = Vec::with_capacity(dim);
        for _ in 0..dim {
            let mut float_buf = [0u8; 4];
            reader
                .read_exact(&mut float_buf)
                .map_err(|e| format!("failed to read vector payload from '{path}': {e}"))?;
            vector.push(f32::from_be_bytes(float_buf) as f64);
        }
        vectors.push(vector);
    }
    if vectors.is_empty() {
        return Err(format!("bin file '{path}' has no vectors in requested range size={size}"));
    }
    Ok(vectors)
}

fn load_hdf5_pool(path: &str, dataset: &str, size: usize) -> Result<Vec<Vec<f64>>, String> {
    if size == 0 {
        return Err("pool size must be > 0".to_string());
    }
    let file = File::open(path).map_err(|e| format!("failed to open hdf5 file '{path}': {e}"))?;
    let ds = file
        .dataset(dataset)
        .map_err(|e| format!("failed to open dataset '{dataset}' in '{path}': {e}"))?;
    let shape = ds.shape();
    if shape.len() != 2 {
        return Err(format!("expected 2D dataset '{dataset}', got shape {shape:?}"));
    }
    let rows = shape[0];
    let end = size.min(rows);
    let slice = ds
        .read_slice_2d::<f32, _>(s![0..end, ..])
        .map_err(|e| format!("failed to read hdf5 slice [0..{end}): {e}"))?;
    let vectors: Vec<Vec<f64>> = slice.outer_iter().map(|row| row.iter().map(|x| *x as f64).collect()).collect();
    if vectors.is_empty() {
        return Err(format!("hdf5 file '{path}', dataset '{dataset}' has no vectors in requested range size={size}"));
    }
    Ok(vectors)
}

fn parse_pool_source() -> Result<PoolSource, String> {
    let source = env::var("POOL_SOURCE").unwrap_or_else(|_| "generated".to_string());
    let pool_path = env::var("POOL_PATH").ok();
    let dataset = env::var("POOL_DATASET").unwrap_or_else(|_| "train".to_string());
    let pool_size = env::var("POOL_SIZE")
        .ok()
        .map(|v| v.parse::<usize>().map_err(|_| "invalid POOL_SIZE, expected unsigned integer".to_string()))
        .transpose()?
        .unwrap_or(DEFAULT_VECTOR_POOL_SIZE);
    let pool_dim = env::var("POOL_DIM")
        .ok()
        .map(|v| v.parse::<usize>().map_err(|_| "invalid POOL_DIM, expected unsigned integer".to_string()))
        .transpose()?
        .unwrap_or(DEFAULT_VECTOR_DIM);
    if pool_dim == 0 {
        return Err("POOL_DIM must be > 0".to_string());
    }
    let pool_seed = env::var("POOL_SEED")
        .ok()
        .map(|v| v.parse::<u64>().map_err(|_| "invalid POOL_SEED, expected unsigned integer".to_string()))
        .transpose()?
        .unwrap_or(DEFAULT_VECTOR_POOL_SEED);

    match source.as_str() {
        "generated" => Ok(PoolSource::Generated {
            size: pool_size,
            dim: pool_dim,
            seed: pool_seed,
        }),
        "bin" => Ok(PoolSource::Bin {
            path: pool_path.ok_or_else(|| "--pool-path is required for --pool-source bin".to_string())?,
            size: pool_size,
        }),
        "hdf5" => Ok(PoolSource::Hdf5 {
            path: pool_path.ok_or_else(|| "--pool-path is required for --pool-source hdf5".to_string())?,
            dataset,
            size: pool_size,
        }),
        _ => Err(format!("invalid --pool-source '{source}', expected one of: generated, bin, hdf5")),
    }
}

fn casper_client() -> &'static CasperClient {
    CASPER_CLIENT.get().expect("casper client must be initialized in main()")
}

async fn search_user_casper(user: &mut GooseUser) -> TransactionResult {
    let cfg = run_config();

    if user.get_session_data_mut::<UserState>().is_none() {
        user.set_session_data(UserState {
            next: user.weighted_users_index.wrapping_mul(cfg.user_start_offset),
        });
    }

    let state = user.get_session_data_mut::<UserState>().expect("session data must be set");
    let pool = vector_pool();
    let idx = state.next % pool.len();
    state.next = state.next.wrapping_add(1);

    let query: Vec<f32> = pool[idx].iter().map(|x| *x as f32).collect();
    let request = SearchRequest { vector: query };
    let result = if let Some(ef) = cfg.ef_search {
        casper_client()
            .search_with_ef(&cfg.casper_collection, cfg.search_limit, Some(ef), request)
            .await
    } else {
        casper_client().search(&cfg.casper_collection, cfg.search_limit, request).await
    };

    if let Err(e) = result {
        eprintln!("casper search failed: {e}");
    }
    Ok(())
}

fn qdrant_client() -> &'static Qdrant {
    QDRANT_CLIENT.get().expect("qdrant client must be initialized in main()")
}

async fn search_user_qdrant(user: &mut GooseUser) -> TransactionResult {
    let cfg = run_config();

    if user.get_session_data_mut::<UserState>().is_none() {
        user.set_session_data(UserState {
            next: user.weighted_users_index.wrapping_mul(cfg.user_start_offset),
        });
    }

    let state = user.get_session_data_mut::<UserState>().expect("session data must be set");
    let pool = vector_pool();
    let idx = state.next % pool.len();
    state.next = state.next.wrapping_add(1);

    let ef = cfg.ef_search.expect("HNSW_EF must be set for qdrant backend (validated at startup)");
    let vector: Vec<f32> = pool[idx].iter().map(|x| *x as f32).collect();
    let request = SearchPointsBuilder::new(&cfg.qdrant_collection, vector, cfg.search_limit as u64)
        .with_payload(false)
        .params(SearchParamsBuilder::default().hnsw_ef(ef as u64))
        .build();

    if let Err(e) = qdrant_client().search_points(request).await {
        eprintln!("qdrant search_points failed: {e}");
    }
    Ok(())
}

async fn run_load_test() -> Result<(), GooseError> {
    let cfg = run_config();

    eprintln!("Starting Goose load test...");
    let scenario = match cfg.backend.as_str() {
        "qdrant" => scenario!("vector_search").register_transaction(transaction!(search_user_qdrant)),
        _ => scenario!("vector_search").register_transaction(transaction!(search_user_casper)),
    };
    GooseAttack::initialize()?
        .register_scenario(scenario)
        .set_default(GooseDefault::Host, "http://localhost:7222")?
        .set_default(GooseDefault::Users, cfg.users)?
        .set_default(GooseDefault::RunTime, cfg.run_time_seconds)?
        .execute()
        .await?;
    Ok(())
}

#[tokio::main]
async fn main() -> Result<(), GooseError> {
    let cfg = read_run_config().map_err(|detail| GooseError::InvalidOption {
        option: "CASPER_COLLECTION".to_string(),
        value: "".to_string(),
        detail,
    })?;
    RUN_CONFIG.set(cfg).map_err(|_| GooseError::InvalidOption {
        option: "run-config".to_string(),
        value: "".to_string(),
        detail: "run config is already initialized".to_string(),
    })?;

    let source = parse_pool_source().map_err(|detail| GooseError::InvalidOption {
        option: "arguments".to_string(),
        value: "".to_string(),
        detail,
    })?;

    let pool = match source {
        PoolSource::Generated { size, dim, seed } => {
            eprintln!("Pool source: generated, size={size}, dim={dim}, seed={seed}");
            load_generated_pool(size, dim, seed)
        }
        PoolSource::Bin { path, size } => {
            eprintln!("Pool source: bin ({path}), first size={size}");
            load_bin_pool(&path, size).map_err(|detail| GooseError::InvalidOption {
                option: "--pool-path".to_string(),
                value: path,
                detail,
            })?
        }
        PoolSource::Hdf5 { path, dataset, size } => {
            eprintln!("Pool source: hdf5 ({path}, dataset={dataset}), first size={size}");
            load_hdf5_pool(&path, &dataset, size).map_err(|detail| GooseError::InvalidOption {
                option: "--pool-path".to_string(),
                value: path,
                detail,
            })?
        }
    };
    let pool_size = pool.len();
    let dim = pool.first().map(|v| v.len()).unwrap_or(0);
    VECTOR_POOL.set(pool).map_err(|_| GooseError::InvalidOption {
        option: "pool".to_string(),
        value: "".to_string(),
        detail: "vector pool is already initialized".to_string(),
    })?;
    eprintln!("Loaded vector pool: size={pool_size}, dim={dim}");

    let cfg = run_config();
    eprintln!(
        "Run config: backend={}, user_start_offset={}, users={}, run_time_seconds={}, search_limit={}, output_format={}, hnsw_ef={:?}, qdrant_url={}, qdrant_collection={}, casper_host={}, casper_http_port={}, casper_collection={}",
        cfg.backend,
        cfg.user_start_offset,
        cfg.users,
        cfg.run_time_seconds,
        cfg.search_limit,
        cfg.output_format,
        cfg.ef_search,
        cfg.qdrant_url,
        cfg.qdrant_collection,
        cfg.casper_host,
        cfg.casper_http_port,
        cfg.casper_collection,
    );

    if cfg.backend == "casper" {
        let client = CasperClient::new(&cfg.casper_host, cfg.casper_http_port).map_err(|e| GooseError::InvalidOption {
            option: "CASPER_HOST".to_string(),
            value: format!("{}:{}", cfg.casper_host, cfg.casper_http_port),
            detail: format!("failed to build casper client: {e}"),
        })?;
        CASPER_CLIENT.set(client).map_err(|_| GooseError::InvalidOption {
            option: "casper-client".to_string(),
            value: "".to_string(),
            detail: "casper client is already initialized".to_string(),
        })?;
        eprintln!(
            "Initialized Casper HTTP client at {}:{} (collection={})",
            cfg.casper_host, cfg.casper_http_port, cfg.casper_collection
        );
    }

    if cfg.backend == "qdrant" {
        let client = Qdrant::from_url(&cfg.qdrant_url).build().map_err(|e| GooseError::InvalidOption {
            option: "QDRANT_URL".to_string(),
            value: cfg.qdrant_url.clone(),
            detail: format!("failed to build qdrant client: {e}"),
        })?;
        QDRANT_CLIENT.set(client).map_err(|_| GooseError::InvalidOption {
            option: "qdrant-client".to_string(),
            value: "".to_string(),
            detail: "qdrant client is already initialized".to_string(),
        })?;
        eprintln!("Initialized Qdrant gRPC client at {}", cfg.qdrant_url);
    }

    run_load_test().await?;

    eprintln!("All Goose load tests finished.");
    Ok(())
}
