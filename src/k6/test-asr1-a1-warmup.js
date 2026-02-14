// =============================================================================
// Test Case A1: JVM Warm-up and Baseline
// Spec 3, Section 5.1
//
// Purpose:  Trigger JIT compilation and class loading before the real test.
//           Results from this test are DISCARDED -- no thresholds enforced.
// Target:   ME Shard A directly (single shard, no gateway)
// Executor: constant-arrival-rate at 500 orders/min for 2 minutes
// Seed:     500 resting SELL orders across 50 price levels
// =============================================================================

import http from 'k6/http';
import { check } from 'k6';
import { generateMixedOrder, randomShardASymbol } from './lib/orderGenerator.js';
import { seedShardDirect } from './lib/seedHelper.js';
import { ME_SHARD_A_URL, SHARD_A_SYMBOLS, JSON_HEADERS } from './lib/config.js';

export const options = {
    scenarios: {
        warmup: {
            executor:        'constant-arrival-rate',
            rate:            500,          // 500 orders/min
            timeUnit:        '1m',
            duration:        '2m',
            preAllocatedVUs: 20,
            maxVUs:          50,
        },
    },
    // No thresholds -- warm-up results are discarded
    thresholds: {},
};

export function setup() {
    console.log('=== Test A1: JVM Warm-up ===');
    console.log(`Target URL: ${ME_SHARD_A_URL}`);
    console.log('Seeding Order Book with 500 resting SELL orders across 50 price levels...');

    seedShardDirect(SHARD_A_SYMBOLS, 500, 50, ME_SHARD_A_URL);

    console.log('Seed complete. Starting warm-up load (500 orders/min for 2 min)...');
    console.log('NOTE: Results from this test are discarded. No thresholds enforced.');
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
}

export function teardown() {
    console.log('=== Warm-up complete. Proceed to Test A2 (Normal Load). ===');
}
