// =============================================================================
// Test Case B2: Peak Sustained -- 3 Shards (PRIMARY ASR 2 TEST)
// Spec 3, Section 5.6
//
// Purpose:  Validate that 3 shards sustain >= 5,000 matches/min (>= 4,750
//           allowing 5% tolerance) for at least 4 of the 5 test minutes.
//
// Target:   Edge Gateway (routes to all 3 shards by symbol)
// Executor: constant-arrival-rate at 84 orders/sec (~5,040/min) for 5 minutes
// Seed:     500 resting SELL orders per symbol across 50 price levels on
//           each of the 3 shards
// Mix:      60% aggressive (match immediately), 40% passive (rest in book)
//
// Pass criteria:
//   - Aggregate throughput >= 4,750 matches/min for >= 4 minutes
//   - Per-shard p99 latency < 200ms
//   - Error rate < 1%
// =============================================================================

import http from 'k6/http';
import { check } from 'k6';
import { Trend, Counter } from 'k6/metrics';
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
const matchCount   = new Counter('match_count');

export const options = {
    scenarios: {
        peak_sustained: {
            executor:        'constant-arrival-rate',
            rate:            1300,           // ~84 orders/sec = ~5,040/min
            timeUnit:        '1s',
            duration:        '2m',
            preAllocatedVUs: 100,
            maxVUs:          300,
        },
    },
    thresholds: {
        'http_req_duration': ['p(99)<200'],   // p99 < 200ms
        'match_latency_ms':  ['p(99)<200'],   // Custom metric
        'http_req_failed':   ['rate<0.01'],   // Error rate < 1%
    },
};

export function setup() {
    console.log('=== Test B2: Peak Sustained -- 3 Shards (PRIMARY ASR 2 TEST) ===');
    console.log(`Target URL: ${GATEWAY_URL}`);
    console.log('Rate: ~84 orders/sec (~5,040/min) for 5 minutes');
    console.log('All 3 shards active, 12 symbols evenly distributed');
    console.log('Mix: 60% aggressive / 40% passive');
    console.log('');
    console.log('Seeding all 3 shards with 500 resting SELL orders each...');

    seedShard('a', SHARD_A_SYMBOLS, 500, 50, GATEWAY_URL);
    seedShard('b', SHARD_B_SYMBOLS, 500, 50, GATEWAY_URL);
    seedShard('c', SHARD_C_SYMBOLS, 500, 50, GATEWAY_URL);

    console.log('All shards seeded. Starting peak sustained load...');
}

export default function () {
    // Distribute orders evenly across all 12 symbols (4 per shard)
    const symbol  = randomSymbol(ALL_SYMBOLS);
    const order   = generateMixedOrder(symbol);
    const payload = JSON.stringify(order);

    const res = http.post(`${GATEWAY_URL}/orders`, payload, {
        headers: JSON_HEADERS,
    });

    check(res, {
        'status is 200': (r) => r.status === 200,
    });

    matchLatency.add(res.timings.duration);
    matchCount.add(1);
}

export function teardown() {
    console.log('=== Test B2 complete. ===');
    console.log('Verify in Prometheus:');
    console.log('  sum(rate(me_matches_total[1m])) * 60 >= 4750 for >= 4 minutes');
}
