// =============================================================================
// Test Case A3: Order Book Depth Variation
// Spec 3, Section 5.3
//
// Purpose:  Measure how Order Book depth affects matching latency.
// Target:   ME Shard A directly (single shard, no gateway)
// Executor: 3 sequential constant-arrival-rate scenarios at 17 orders/sec
//
// Sub-tests:
//   1. Shallow: 100 resting orders, 10 price levels  (t=0m to t=3m)
//   2. Medium:  1,000 resting orders, 100 price levels (t=3m30s to t=6m30s)
//   3. Deep:    10,000 resting orders, 500 price levels (t=7m to t=10m)
//
// Recommended approach: Run this as 3 separate k6 invocations with ME restart
// between each to get a clean Order Book. For a single-invocation approach,
// we seed with the maximum depth (10,000) and let depth change dynamically
// as orders are consumed by matching.
//
// Seed strategy for single-invocation: seed 10,000 orders up front.
// =============================================================================

import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';
import { generateMixedOrder, randomShardASymbol } from './lib/orderGenerator.js';
import { seedShardDirect } from './lib/seedHelper.js';
import { ME_SHARD_A_URL, SHARD_A_SYMBOLS, JSON_HEADERS } from './lib/config.js';

const matchLatency = new Trend('match_latency_ms');

export const options = {
    scenarios: {
        // Sub-test 1: Shallow Order Book (100 resting orders, 10 price levels)
        shallow: {
            executor:        'constant-arrival-rate',
            rate:            17,
            timeUnit:        '1s',
            duration:        '3m',
            preAllocatedVUs: 30,
            maxVUs:          60,
            startTime:       '0s',
            env: { DEPTH_LABEL: 'shallow' },
        },
        // Sub-test 2: Medium Order Book (1,000 resting orders, 100 price levels)
        medium: {
            executor:        'constant-arrival-rate',
            rate:            17,
            timeUnit:        '1s',
            duration:        '3m',
            preAllocatedVUs: 30,
            maxVUs:          60,
            startTime:       '3m30s',     // 30s gap for transition
            env: { DEPTH_LABEL: 'medium' },
        },
        // Sub-test 3: Deep Order Book (10,000 resting orders, 500 price levels)
        deep: {
            executor:        'constant-arrival-rate',
            rate:            17,
            timeUnit:        '1s',
            duration:        '3m',
            preAllocatedVUs: 30,
            maxVUs:          60,
            startTime:       '7m',        // 30s gap for transition
            env: { DEPTH_LABEL: 'deep' },
        },
    },
    thresholds: {
        'http_req_duration': ['p(99)<200'],
        'match_latency_ms':  ['p(99)<200'],
    },
};

export function setup() {
    console.log('=== Test A3: Order Book Depth Variation ===');
    console.log(`Target URL: ${ME_SHARD_A_URL}`);
    console.log('Sub-tests: shallow (100), medium (1,000), deep (10,000) resting orders');
    console.log('');
    console.log('RECOMMENDED: Run each depth as a separate k6 invocation with');
    console.log('  ME restart between each for clean Order Book state.');
    console.log('  This single-invocation seeds 10,000 orders up front.');
    console.log('');
    console.log('Seeding Order Book with 10,000 resting SELL orders across 500 price levels...');

    seedShardDirect(SHARD_A_SYMBOLS, 10000, 500, ME_SHARD_A_URL);

    console.log('Seed complete. Starting depth variation test (~10 min total)...');
}

export default function () {
    const symbol  = randomShardASymbol();
    const order   = generateMixedOrder(symbol);
    const payload = JSON.stringify(order);

    const res = http.post(`${ME_SHARD_A_URL}/orders`, payload, {
        headers: JSON_HEADERS,
    });

    check(res, {
        'status is 200': (r) => r.status === 200,
    });

    matchLatency.add(res.timings.duration);
}

export function teardown() {
    console.log('=== Test A3 complete. Compare p99 latency across shallow/medium/deep periods. ===');
}
