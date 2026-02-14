// =============================================================================
// Test Case A2: Normal Load Latency -- PRIMARY ASR 1 TEST
// Spec 3, Section 5.2
//
// Purpose:  Validate p99 matching latency < 200ms at normal load (1,000 orders/min).
// Target:   ME Shard A directly (single shard, no gateway)
// Executor: constant-arrival-rate at ~17 orders/sec (1,020/min) for 5 minutes
// Seed:     500 resting SELL orders across 50 price levels
// Mix:      60% aggressive (match immediately), 40% passive (rest in book)
//
// Pass criteria:
//   - p99 http_req_duration     < 200ms
//   - p99 match_latency_ms      < 200ms
//   - Error rate                 < 1%
// =============================================================================

import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';
import { generateMixedOrder, randomShardASymbol } from './lib/orderGenerator.js';
import { seedShardDirect } from './lib/seedHelper.js';
import { ME_SHARD_A_URL, SHARD_A_SYMBOLS, JSON_HEADERS } from './lib/config.js';

// Custom metric for match latency (end-to-end HTTP round-trip from k6)
const matchLatency = new Trend('match_latency_ms');

export const options = {
    scenarios: {
        normal_load: {
            executor:        'constant-arrival-rate',
            rate:            17,           // ~17 orders/sec = ~1,020/min
            timeUnit:        '1s',
            duration:        '5m',
            preAllocatedVUs: 30,
            maxVUs:          60,
        },
    },
    thresholds: {
        'http_req_duration': ['p(99)<200'],   // p99 < 200ms
        'match_latency_ms':  ['p(99)<200'],   // Custom metric same threshold
        'http_req_failed':   ['rate<0.01'],   // Error rate < 1%
    },
};

export function setup() {
    console.log('=== Test A2: Normal Load Latency (PRIMARY ASR 1 TEST) ===');
    console.log(`Target URL: ${ME_SHARD_A_URL}`);
    console.log('Rate: ~17 orders/sec (~1,020/min) for 5 minutes');
    console.log('Mix: 60% aggressive / 40% passive');
    console.log('Seeding Order Book with 500 resting SELL orders across 50 price levels...');

    seedShardDirect(SHARD_A_SYMBOLS, 500, 50, ME_SHARD_A_URL);

    console.log('Seed complete. Starting load test...');
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
        'response has ACCEPTED status': (r) => {
            try {
                const body = JSON.parse(r.body);
                return body.status === 'ACCEPTED';
            } catch (e) {
                return false;
            }
        },
    });

    // Record on custom trend for fine-grained analysis
    matchLatency.add(res.timings.duration);
}

export function teardown() {
    console.log('=== Test A2 complete. Check thresholds above for PASS/FAIL. ===');
}
