// =============================================================================
// Test Case B1: Single Shard Baseline (through Gateway)
// Spec 3, Section 5.5
//
// Purpose:  Establish a single-shard throughput baseline measured through the
//           Edge Gateway. This value is used to calculate the linear scaling
//           ratio: throughput(3 shards) >= 0.9 * 3 * throughput(1 shard).
//
// Target:   Edge Gateway (routes to Shard A only; shards B/C not deployed)
// Executor: constant-arrival-rate at 17 orders/sec for 3 minutes
// Seed:     500 resting SELL orders across 50 price levels (direct to ME)
//
// NOTE: Although this is an ASR 2 test, it only sends traffic to Shard A
// symbols so the Gateway routes everything to a single shard.
// =============================================================================

import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';
import { generateMixedOrder, randomShardASymbol } from './lib/orderGenerator.js';
import { seedShard } from './lib/seedHelper.js';
import { GATEWAY_URL, SHARD_A_SYMBOLS, JSON_HEADERS } from './lib/config.js';

const matchLatency = new Trend('match_latency_ms');

export const options = {
    scenarios: {
        baseline: {
            executor:        'constant-arrival-rate',
            rate:            17,           // ~17 orders/sec = ~1,020/min
            timeUnit:        '1s',
            duration:        '3m',
            preAllocatedVUs: 30,
            maxVUs:          60,
        },
    },
    thresholds: {
        'http_req_duration': ['p(99)<200'],
        'match_latency_ms':  ['p(99)<200'],
    },
};

export function setup() {
    console.log('=== Test B1: Single Shard Baseline (through Gateway) ===');
    console.log(`Target URL: ${GATEWAY_URL}`);
    console.log('Rate: ~17 orders/sec (~1,020/min) for 3 minutes');
    console.log('Only Shard A symbols used -- single shard throughput baseline');
    console.log('');
    console.log('Seeding Shard A with 500 resting SELL orders across 50 price levels...');

    seedShard('a', SHARD_A_SYMBOLS, 500, 50, GATEWAY_URL);

    console.log('Seed complete. Starting baseline load...');
}

export default function () {
    // Only Shard A symbols -- establish single-shard baseline
    const symbol  = randomShardASymbol();
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
    console.log('=== Test B1 complete. Record baseline throughput for scaling ratio. ===');
}
