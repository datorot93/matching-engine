// =============================================================================
// Test Case B3: Progressive Ramp Test
// Spec 3, Section 5.7
//
// Purpose:  Validate that the system scales smoothly from 1,000 to 5,000
//           matches/min without latency spikes during ramp transitions.
//
// Target:   Edge Gateway (routes to all 3 shards by symbol)
// Executor: ramping-arrival-rate with 4 stages over 10 minutes:
//   Stage 1 (t=0-2m):    ~17/sec  = ~1,000/min  (1 shard load equivalent)
//   Stage 2 (t=2-4m):    ~42/sec  = ~2,500/min  (2 shard load equivalent)
//   Stage 3 (t=4-6m):    ~84/sec  = ~5,000/min  (3 shard load equivalent)
//   Stage 4 (t=6-10m):   ~84/sec  = ~5,000/min  sustained at peak
//
// NOTE: All 3 shards must be pre-deployed. The ramp test assumes shards are
// already running; it only increases the request rate, not the shard count.
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

export const options = {
    scenarios: {
        ramp: {
            executor:        'ramping-arrival-rate',
            startRate:       50,           // Start at ~1,000/min
            timeUnit:        '1s',
            preAllocatedVUs: 150,
            maxVUs:          300,
            stages: [
                { duration: '1m', target: 17 },    // t=0-2m:   hold at ~1,000/min
                { duration: '1m', target: 42 },    // t=2-4m:   ramp to ~2,500/min
                { duration: '1m', target: 100 },    // t=4-6m:   ramp to ~5,000/min
                { duration: '2m', target: 100 },    // t=6-10m:  sustain at ~5,000/min
            ],
        },
    },
    thresholds: {
        'http_req_duration': ['p(99)<200'],
        'match_latency_ms':  ['p(99)<200'],
    },
};

export function setup() {
    console.log('=== Test B3: Progressive Ramp (1K -> 2.5K -> 5K matches/min) ===');
    console.log(`Target URL: ${GATEWAY_URL}`);
    console.log('Stages:');
    console.log('  t=0-2m:   ~17/sec  (~1,000/min)');
    console.log('  t=2-4m:   ramp to ~42/sec  (~2,500/min)');
    console.log('  t=4-6m:   ramp to ~84/sec  (~5,000/min)');
    console.log('  t=6-10m:  sustain ~84/sec  (~5,000/min)');
    console.log('');
    console.log('NOTE: All 3 ME shards must be running for the full ramp test.');
    console.log('');
    console.log('Seeding all 3 shards...');

    seedShard('a', SHARD_A_SYMBOLS, 500, 50, GATEWAY_URL);
    seedShard('b', SHARD_B_SYMBOLS, 500, 50, GATEWAY_URL);
    seedShard('c', SHARD_C_SYMBOLS, 500, 50, GATEWAY_URL);

    console.log('All shards seeded. Starting ramp test (10 min total)...');
}

export default function () {
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
}

export function teardown() {
    console.log('=== Test B3 complete. ===');
    console.log('Check Grafana for smooth latency during ramp transitions.');
    console.log('Verify no latency spikes at transition points (t=2m, t=4m).');
}
