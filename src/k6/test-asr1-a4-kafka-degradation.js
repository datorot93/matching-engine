// =============================================================================
// Test Case A4: Kafka Degradation (Decoupling Proof)
// Spec 3, Section 5.4
//
// Purpose:  Prove that Kafka/Redpanda unavailability does NOT affect matching
//           latency. The ME uses fire-and-forget Kafka publishing with acks=0,
//           so broker outages should not propagate to the matching hot path.
//
// Target:   ME Shard A directly (single shard, no gateway)
// Executor: constant-arrival-rate at 17 orders/sec for 3 minutes
// Seed:     500 resting SELL orders across 50 price levels
//
// Manual intervention required at t=60s:
//   kubectl scale statefulset redpanda --replicas=0 -n matching-engine
//
// After test completes, restore Redpanda:
//   kubectl scale statefulset redpanda --replicas=1 -n matching-engine
//
// Pass criterion: p99 matching latency does NOT increase > 10% when Kafka
// is degraded compared to the pre-degradation baseline.
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
        kafka_degradation: {
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
    console.log('=== Test A4: Kafka Degradation (Decoupling Proof) ===');
    console.log(`Target URL: ${ME_SHARD_A_URL}`);
    console.log('Duration: 3 minutes at ~17 orders/sec');
    console.log('');
    console.log('IMPORTANT: At t=60s, manually pause the Redpanda pod:');
    console.log('  kubectl scale statefulset redpanda --replicas=0 -n matching-engine');
    console.log('');
    console.log('Or use the helper script:');
    console.log('  bash infra/scripts/helpers/pause-redpanda.sh');
    console.log('');
    console.log('Monitor that p99 latency does NOT spike during Kafka outage.');
    console.log('');

    console.log('Seeding Order Book with 500 resting SELL orders across 50 price levels...');
    seedShardDirect(SHARD_A_SYMBOLS, 500, 50, ME_SHARD_A_URL);
    console.log('Seed complete. Starting load...');
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
    console.log('');
    console.log('=== Test A4 complete. ===');
    console.log('After reviewing results, restore Redpanda:');
    console.log('  kubectl scale statefulset redpanda --replicas=1 -n matching-engine');
}
