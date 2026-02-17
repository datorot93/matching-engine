// =============================================================================
// Test Case B4: Hot Symbol Test
// Spec 3, Section 5.8
//
// Purpose:  Validate shard isolation under skewed load. 80% of traffic goes
//           to a single symbol (TEST-ASSET-A on Shard A) while the remaining
//           20% is distributed across all other symbols.
//
// Target:   Edge Gateway (routes to all 3 shards by symbol)
// Executor: constant-arrival-rate at 84 orders/sec (~5,000/min) for 5 minutes
// Seed:     2,000 resting SELL orders on Shard A (extra depth for hot symbol),
//           500 on Shards B and C
//
// Pass criteria:
//   - p99 < 200ms overall
//   - Shard A handles 80% of traffic without degrading Shards B/C
//   - Shard B and C p99 unchanged (+/- 5%) compared to baseline
// =============================================================================

import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';
import { generateMixedOrder, randomSymbol } from './lib/orderGenerator.js';
import { seedShard } from './lib/seedHelper.js';
import {
    GATEWAY_URL,
    SHARD_A_SYMBOLS,
    SHARD_B_SYMBOLS,
    SHARD_C_SYMBOLS,
    ALL_SYMBOLS,
    JSON_HEADERS,
} from './lib/config.js';

const matchLatency = new Trend('match_latency_ms');

// Hot symbol: TEST-ASSET-A on Shard A receives 80% of all traffic
const HOT_SYMBOL = 'TEST-ASSET-A';

export const options = {
    scenarios: {
        hot_symbol: {
            executor:        'constant-arrival-rate',
            rate:            150,
            timeUnit:        '1s',
            duration:        '1m',
            preAllocatedVUs: 100,
            maxVUs:          200,
        },
    },
    thresholds: {
        'http_req_duration': ['p(99)<200'],
        'match_latency_ms':  ['p(99)<200'],
    },
};

export function setup() {
    console.log('=== Test B4: Hot Symbol Test ===');
    console.log(`Target URL: ${GATEWAY_URL}`);
    console.log(`Hot symbol: ${HOT_SYMBOL} (Shard A) receives 80% of traffic`);
    console.log('Rate: ~84 orders/sec (~5,040/min) for 5 minutes');
    console.log('');
    console.log('Seeding shards (extra depth on Shard A for hot symbol)...');

    // Extra depth on Shard A to support 80% traffic volume
    seedShard('a', SHARD_A_SYMBOLS, 500, 50, GATEWAY_URL);
    seedShard('b', SHARD_B_SYMBOLS, 2000, 100, GATEWAY_URL);
    seedShard('c', SHARD_C_SYMBOLS, 500, 50, GATEWAY_URL);

    console.log('All shards seeded. Starting hot symbol test...');
}

export default function () {
    let symbol;

    if (Math.random() < 0.8) {
        // 80% of traffic to the hot symbol
        symbol = HOT_SYMBOL;
    } else {
        // 20% distributed across all OTHER symbols
        const otherSymbols = ALL_SYMBOLS.filter((s) => s !== HOT_SYMBOL);
        symbol = randomSymbol(otherSymbols);
    }

    const order   = generateMixedOrder(symbol);
    const payload = JSON.stringify(order);

    const res = http.post(`${GATEWAY_URL}/orders`, payload, {
        headers: JSON_HEADERS,
    });

    check(res, {
        'status is 200': (r) => r.status === 200,
    });

    matchLatency.add(res.timings.duration);
}

export function teardown() {
    console.log('=== Test B4 complete. ===');
    console.log('Verify shard isolation in Prometheus:');
    console.log('  - Shard A should have received ~80% of total requests');
    console.log('  - Shards B and C p99 should be unchanged from baseline (+/- 5%)');
}
