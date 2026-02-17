// =============================================================================
// Test: Stochastic Aggressive Load -- SHORT (20 seconds)
//
// Purpose:  Stress-test the ME at ultra-high throughput with stochastic order
//           arrival for a short burst. Designed to be called repeatedly by
//           the mixed orchestrator.
//
// Stochastic techniques:
//   - Poisson process for inter-arrival times (sleepPoisson)
//   - Gaussian Random Walk for price generation (Box-Muller transform)
//   - Controlled BUY/SELL distribution: 38.46% BUY / 61.54% SELL
//
// Target:   ME Shard A directly (single shard, no gateway)
// Executor: ramping-vus  ramp to 150 VUs x lambda 300
// Duration: 20 seconds total (5s ramp + 10s blast + 5s cool-down)
// Seed:     Heavy seeding on both sides to sustain high match rate under blast.
//
// Pass criteria:
//   - p99 http_req_duration  < 200ms
//   - p99 matching_latency   < 200ms
//   - p95 matching_latency   < 150ms
//   - p50 matching_latency   < 100ms
//   - Error rate             < 1%
//   - Order success rate     > 99%
//
// Calculation:
//   Ramp to 150 VUs x lambda 300 = high-throughput blast
//   Duration 20s -> aggressive burst of orders
//   BUY:  ~38.46%
//   SELL: ~61.54%
// =============================================================================

import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

import {
    ME_SHARD_A_URL,
    SHARD_A_SYMBOLS,
    BASE_PRICE,
    JSON_HEADERS,
} from './lib/config.js';
import { seedShard } from './lib/seedHelper.js';
import { randomShardASymbol } from './lib/orderGenerator.js';
import {
    updateMarketPrice,
    sleepPoisson,
    generateStochasticOrder,
} from './lib/stochasticHelper.js';

// =============================================================================
// Custom metrics
// =============================================================================
const matchingLatency = new Trend('matching_latency', true);
const orderSuccessRate = new Rate('order_success_rate');
const buyOrderRate = new Rate('buy_order_rate');
const sellOrderRate = new Rate('sell_order_rate');
const buyOrderCount = new Counter('buy_order_count');
const sellOrderCount = new Counter('sell_order_count');
const totalOrderCount = new Counter('total_order_count');

// =============================================================================
// Lambda: 300 orders/sec per VU (high-frequency mode)
// =============================================================================
const LAMBDA = 100;

// =============================================================================
// k6 options -- 20 second total duration
// =============================================================================
export const options = {
    stages: [
        // Quick warm-up: ramp to 50 VUs in 5 seconds
        { duration: '5s', target: 10 },

        // AGGRESSIVE BLAST: 10 seconds at full rate
        { duration: '10s', target: 40 },

        // Immediate shutdown
        { duration: '5s', target: 0 },
    ],

    thresholds: {
        'http_req_duration': ['p(99)<200'],
        'http_req_failed':   ['rate<0.01'],
        'matching_latency':  ['p(99)<200', 'p(95)<150', 'p(50)<100'],
        'order_success_rate': ['rate>0.99'],
    },

    batch: 1,
    batchPerHost: 1,
};

// =============================================================================
// Per-VU market state
// =============================================================================
let marketPrices = {};

// =============================================================================
// Setup: heavy seeding for high-throughput blast
// =============================================================================
export function setup() {
    console.log('=== Test: Stochastic Aggressive Load -- SHORT (20s) ===');
    console.log(`Target URL: ${ME_SHARD_A_URL}`);
    console.log('Rate: ultra-high throughput burst for 20 seconds');
    console.log('Distribution: 38.46% BUY / 61.54% SELL (stochastic)');
    console.log('');

    // Heavy SELL seed: 2,000 per symbol across 100 price levels.
    // Use seedShard (via gateway /seed/{shardId}) since the port-forward
    // routes to the Edge Gateway, which does not expose a bare /seed endpoint.
    console.log('Seeding SELL orders: 2,000 per symbol across 100 price levels...');
    seedShard('a', SHARD_A_SYMBOLS, 2000, 100, ME_SHARD_A_URL);

    // Heavy BUY seed: resting BUY orders below BASE_PRICE so aggressive SELLs match.
    console.log('Seeding resting BUY orders for SELL-side matching...');
    let buySeeded = 0;
    for (const symbol of SHARD_A_SYMBOLS) {
        const orders = [];
        for (let level = 1; level <= 100; level++) {
            for (let i = 0; i < 20; i++) {
                orders.push({
                    orderId:  `seed-buy-${symbol}-${level}-${i}`,
                    symbol:   symbol,
                    side:     'BUY',
                    type:     'LIMIT',
                    price:    BASE_PRICE - level,
                    quantity: 10 + Math.floor(Math.random() * 190),
                });
            }
        }
        const payload = JSON.stringify({ orders: orders });
        const res = http.post(`${ME_SHARD_A_URL}/seed/a`, payload, {
            headers: JSON_HEADERS,
            timeout: '60s',
        });
        const ok = check(res, {
            [`seed BUY ${symbol} status 200`]: (r) => r.status === 200,
        });
        if (!ok) {
            console.error(`SEED BUY FAILED for ${symbol}: status=${res.status}, body=${res.body}`);
        }
        buySeeded += orders.length;
    }
    console.log(`Seeded ${buySeeded} resting BUY orders across ${SHARD_A_SYMBOLS.length} symbols.`);

    const initialPrices = {};
    SHARD_A_SYMBOLS.forEach((sym) => {
        initialPrices[sym] = BASE_PRICE;
    });

    console.log('Seed complete. Starting aggressive stochastic blast (20s)...');
    console.log('');

    return { initialPrices };
}

// =============================================================================
// Main VU function
// =============================================================================
export default function (data) {
    if (__ITER === 0) {
        marketPrices = { ...data.initialPrices };
    }

    const symbol = randomShardASymbol();
    const marketPrice = updateMarketPrice(symbol, marketPrices);
    const order = generateStochasticOrder(symbol, marketPrice);

    const payload = JSON.stringify(order);
    const params = {
        headers: JSON_HEADERS,
        tags: {
            symbol: order.symbol,
            side: order.side,
        },
    };

    const res = http.post(`${ME_SHARD_A_URL}/orders`, payload, params);

    // Record metrics
    matchingLatency.add(res.timings.duration);
    totalOrderCount.add(1);

    if (order.side === 'BUY') {
        buyOrderRate.add(1);
        sellOrderRate.add(0);
        buyOrderCount.add(1);
    } else {
        buyOrderRate.add(0);
        sellOrderRate.add(1);
        sellOrderCount.add(1);
    }

    const success = check(res, {
        'status is 200': (r) => r.status === 200,
        'latency < 200ms': () => res.timings.duration < 200,
    });

    orderSuccessRate.add(success ? 1 : 0);

    if (!success && __ITER % 500 === 0) {
        console.error(
            `Order failed: ${order.symbol} ${order.side} @ ${order.price} - ` +
            `Status: ${res.status}, Body: ${res.body}`
        );
    }

    sleepPoisson(LAMBDA);
}

// =============================================================================
// Teardown
// =============================================================================
export function teardown() {
    console.log('');
    console.log('=== Stochastic Aggressive Load (20s) complete ===');
    console.log('Metrics: matching_latency, order_success_rate, buy_order_count, sell_order_count, total_order_count');
    console.log('');
}
