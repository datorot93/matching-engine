// =============================================================================
// Shared configuration for all k6 load test scripts
// Spec 3, Section 4.1
// =============================================================================

// ---------------------------------------------------------------------------
// Target URLs -- set via environment variable or use defaults.
// ASR 1 tests hit the ME shard directly; ASR 2 tests hit the Edge Gateway.
// The port defaults to 8081 because 8080 is occupied by Airflow on this machine.
// Override via: k6 run -e ME_SHARD_A_URL=http://localhost:8081 ...
// ---------------------------------------------------------------------------
export const GATEWAY_URL    = __ENV.GATEWAY_URL    || 'http://149.130.191.100';
export const ME_SHARD_A_URL = __ENV.ME_SHARD_A_URL || 'http://149.130.191.100';
// export const GATEWAY_URL    = __ENV.GATEWAY_URL    || 'http://localhost:8081';
// export const ME_SHARD_A_URL = __ENV.ME_SHARD_A_URL || 'http://localhost:8081';

// ---------------------------------------------------------------------------
// Symbols assigned to each shard (must match ME SHARD_SYMBOLS env config)
// ---------------------------------------------------------------------------
export const SHARD_A_SYMBOLS = ['TEST-ASSET-A', 'TEST-ASSET-B', 'TEST-ASSET-C', 'TEST-ASSET-D'];
export const SHARD_B_SYMBOLS = ['TEST-ASSET-E', 'TEST-ASSET-F', 'TEST-ASSET-G', 'TEST-ASSET-H'];
export const SHARD_C_SYMBOLS = ['TEST-ASSET-I', 'TEST-ASSET-J', 'TEST-ASSET-K', 'TEST-ASSET-L'];
export const ALL_SYMBOLS     = [...SHARD_A_SYMBOLS, ...SHARD_B_SYMBOLS, ...SHARD_C_SYMBOLS];

// ---------------------------------------------------------------------------
// Price configuration (all values in cents)
// ---------------------------------------------------------------------------
export const BASE_PRICE   = 15000;  // $150.00 -- midpoint / spread boundary
export const PRICE_SPREAD = 200;    // $2.00 spread range (100 ticks each side)
export const TICK_SIZE    = 1;      // $0.01 per tick

// ---------------------------------------------------------------------------
// Order quantity range
// ---------------------------------------------------------------------------
export const MIN_QUANTITY = 10;
export const MAX_QUANTITY = 200;

// ---------------------------------------------------------------------------
// Threshold constants
// ---------------------------------------------------------------------------
export const LATENCY_THRESHOLD_MS = 200;  // ASR 1: p99 < 200ms

// ---------------------------------------------------------------------------
// HTTP request defaults
// ---------------------------------------------------------------------------
export const JSON_HEADERS = { 'Content-Type': 'application/json' };
export const SEED_TIMEOUT = '30s';
