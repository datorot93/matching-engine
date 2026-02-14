// =============================================================================
// Standalone Order Book Seed Script
// Spec 3, Section 5.9
//
// Purpose:  Pre-populate Order Books with resting SELL orders without running
//           any load. Useful for manual testing, debugging, and verifying
//           that the seed endpoint works before running full test suites.
//
// Modes:
//   single -- Seeds Shard A directly via POST /seed (no gateway needed)
//   multi  -- Seeds all 3 shards via Gateway POST /seed/{shardId}
//
// Usage:
//   k6 run -e SEED_MODE=single -e SEED_DEPTH=500 -e SEED_LEVELS=50 \
//          -e ME_SHARD_A_URL=http://localhost:8081 \
//          src/k6/seed-orderbooks.js
//
//   k6 run -e SEED_MODE=multi -e SEED_DEPTH=500 -e SEED_LEVELS=50 \
//          -e GATEWAY_URL=http://localhost:8081 \
//          src/k6/seed-orderbooks.js
// =============================================================================

import { seedShard, seedShardDirect } from './lib/seedHelper.js';
import {
    GATEWAY_URL,
    ME_SHARD_A_URL,
    SHARD_A_SYMBOLS,
    SHARD_B_SYMBOLS,
    SHARD_C_SYMBOLS,
} from './lib/config.js';

export const options = {
    vus:        1,
    iterations: 1,
};

export default function () {
    const mode   = __ENV.SEED_MODE   || 'single';
    const depth  = parseInt(__ENV.SEED_DEPTH  || '500', 10);
    const levels = parseInt(__ENV.SEED_LEVELS || '50',  10);

    console.log(`=== Order Book Seeding ===`);
    console.log(`Mode:   ${mode}`);
    console.log(`Depth:  ${depth} orders per symbol`);
    console.log(`Levels: ${levels} price levels`);
    console.log('');

    if (mode === 'single') {
        console.log(`Seeding Shard A directly at ${ME_SHARD_A_URL}...`);
        const count = seedShardDirect(SHARD_A_SYMBOLS, depth, levels, ME_SHARD_A_URL);
        console.log(`Done. Total seed orders: ${count}`);
    } else if (mode === 'multi') {
        console.log(`Seeding all 3 shards via Gateway at ${GATEWAY_URL}...`);
        let total = 0;
        total += seedShard('a', SHARD_A_SYMBOLS, depth, levels, GATEWAY_URL);
        total += seedShard('b', SHARD_B_SYMBOLS, depth, levels, GATEWAY_URL);
        total += seedShard('c', SHARD_C_SYMBOLS, depth, levels, GATEWAY_URL);
        console.log(`Done. Total seed orders across all shards: ${total}`);
    } else {
        console.error(`Unknown SEED_MODE: "${mode}". Use "single" or "multi".`);
    }
}
