# Spec 3: Load Testing Scripts (k6)

## 1. Role and Scope

**Role Name:** Load Testing Developer

**Scope:** Create all k6 load test scripts that generate synthetic order traffic for the ASR 1 (Latency) and ASR 2 (Scalability) experiments. This includes scripts for every test case defined in `experiment-design.md` Section 7, a shared utility module for order generation, and a seed script that pre-populates Order Books before each test.

**Out of Scope:** The Matching Engine (Spec 1), Edge Gateway (Spec 2), Infrastructure (Spec 4), and Integration Glue (Spec 5). This spec covers only the k6 JavaScript files.

---

## 2. Technology Stack

| Component | Technology | Version |
|:---|:---|:---|
| Load testing tool | Grafana k6 | latest (brew install k6) |
| Language | JavaScript (ES6 modules) | k6 runtime |
| HTTP | k6/http module | built-in |
| Metrics output | Prometheus remote write | `--out experimental-prometheus-rw` |

---

## 3. Project Structure

```
src/k6/
  lib/
    config.js             # Shared constants (URLs, symbols, timing)
    orderGenerator.js     # Functions to generate synthetic orders
    seedHelper.js         # Functions to pre-seed order books
  test-asr1-a1-warmup.js           # Test Case A1: JVM warm-up
  test-asr1-a2-normal-load.js      # Test Case A2: Normal load latency
  test-asr1-a3-depth-variation.js  # Test Case A3: Order Book depth variation
  test-asr1-a4-kafka-degradation.js # Test Case A4: Decoupling proof
  test-asr2-b1-baseline.js         # Test Case B1: Single shard baseline
  test-asr2-b2-peak-sustained.js   # Test Case B2: Peak 3-shard sustained
  test-asr2-b3-ramp.js             # Test Case B3: Progressive ramp
  test-asr2-b4-hot-symbol.js       # Test Case B4: Hot symbol test
  seed-orderbooks.js               # Standalone seed script
```

---

## 4. Shared Libraries

### 4.1 `lib/config.js`

```javascript
// Shared configuration for all test scripts

// Target URL is set via environment variable or defaults
export const GATEWAY_URL = __ENV.GATEWAY_URL || 'http://localhost:8080';
export const ME_SHARD_A_URL = __ENV.ME_SHARD_A_URL || 'http://localhost:8080';

// Symbols assigned to each shard
export const SHARD_A_SYMBOLS = ['TEST-ASSET-A', 'TEST-ASSET-B', 'TEST-ASSET-C', 'TEST-ASSET-D'];
export const SHARD_B_SYMBOLS = ['TEST-ASSET-E', 'TEST-ASSET-F', 'TEST-ASSET-G', 'TEST-ASSET-H'];
export const SHARD_C_SYMBOLS = ['TEST-ASSET-I', 'TEST-ASSET-J', 'TEST-ASSET-K', 'TEST-ASSET-L'];
export const ALL_SYMBOLS = [...SHARD_A_SYMBOLS, ...SHARD_B_SYMBOLS, ...SHARD_C_SYMBOLS];

// Price range for generated orders (in cents)
export const BASE_PRICE = 15000;    // $150.00
export const PRICE_SPREAD = 200;    // $2.00 spread range (100 ticks each side)
export const TICK_SIZE = 1;         // $0.01 per tick

// Order quantity range
export const MIN_QUANTITY = 10;
export const MAX_QUANTITY = 200;

// Thresholds
export const LATENCY_THRESHOLD_MS = 200;  // ASR 1: p99 < 200ms
```

### 4.2 `lib/orderGenerator.js`

```javascript
import { SHARD_A_SYMBOLS, ALL_SYMBOLS, BASE_PRICE, PRICE_SPREAD, TICK_SIZE, MIN_QUANTITY, MAX_QUANTITY } from './config.js';

let orderCounter = 0;

/**
 * Generate a unique order ID.
 */
export function generateOrderId(prefix = 'k6') {
    orderCounter++;
    return `${prefix}-${__VU}-${orderCounter}`;
}

/**
 * Generate an aggressive BUY order that will match against resting SELL orders.
 * Price is at or above the midpoint, ensuring it crosses the spread.
 */
export function generateAggressiveBuyOrder(symbol) {
    // Price above midpoint to ensure matching with resting sells
    const priceOffset = Math.floor(Math.random() * (PRICE_SPREAD / 2));
    const price = BASE_PRICE + priceOffset;  // At or above midpoint
    const quantity = MIN_QUANTITY + Math.floor(Math.random() * (MAX_QUANTITY - MIN_QUANTITY));

    return {
        orderId: generateOrderId('buy'),
        symbol: symbol,
        side: 'BUY',
        type: 'LIMIT',
        price: price,
        quantity: quantity,
    };
}

/**
 * Generate a passive BUY order that rests in the book (below best ask).
 * Price is well below the midpoint.
 */
export function generatePassiveBuyOrder(symbol) {
    const priceOffset = Math.floor(Math.random() * (PRICE_SPREAD / 2));
    const price = BASE_PRICE - PRICE_SPREAD - priceOffset;  // Well below midpoint
    const quantity = MIN_QUANTITY + Math.floor(Math.random() * (MAX_QUANTITY - MIN_QUANTITY));

    return {
        orderId: generateOrderId('buy-passive'),
        symbol: symbol,
        side: 'BUY',
        type: 'LIMIT',
        price: price,
        quantity: quantity,
    };
}

/**
 * Generate a SELL order for seeding the order book.
 * Prices are spread around and above the midpoint.
 */
export function generateSeedSellOrder(symbol, priceLevel, idx) {
    return {
        orderId: `seed-sell-${symbol}-${priceLevel}-${idx}`,
        symbol: symbol,
        side: 'SELL',
        type: 'LIMIT',
        price: BASE_PRICE + priceLevel * TICK_SIZE,
        quantity: MIN_QUANTITY + Math.floor(Math.random() * (MAX_QUANTITY - MIN_QUANTITY)),
    };
}

/**
 * Generate a mixed order (60% aggressive/matching, 40% passive/resting).
 * This matches the experiment-design.md Test Case A2 profile:
 * "60% aggressive limit orders (match immediately), 40% passive (rest in book)"
 */
export function generateMixedOrder(symbol) {
    if (Math.random() < 0.6) {
        return generateAggressiveBuyOrder(symbol);
    } else {
        return generatePassiveBuyOrder(symbol);
    }
}

/**
 * Pick a random symbol from the given list.
 */
export function randomSymbol(symbols = ALL_SYMBOLS) {
    return symbols[Math.floor(Math.random() * symbols.length)];
}

/**
 * Pick a random symbol from a specific shard.
 */
export function randomShardASymbol() {
    return randomSymbol(SHARD_A_SYMBOLS);
}
```

### 4.3 `lib/seedHelper.js`

```javascript
import http from 'k6/http';
import { check } from 'k6';
import { generateSeedSellOrder } from './orderGenerator.js';
import { GATEWAY_URL, ME_SHARD_A_URL } from './config.js';

/**
 * Seed a shard with resting SELL orders via the gateway's /seed/{shardId} endpoint.
 *
 * @param {string} shardId - Shard ID (a, b, c)
 * @param {string[]} symbols - Symbols assigned to this shard
 * @param {number} ordersPerSymbol - Number of resting orders per symbol
 * @param {number} priceLevels - Number of distinct price levels
 * @param {string} targetUrl - Base URL (gateway or direct ME)
 */
export function seedShard(shardId, symbols, ordersPerSymbol, priceLevels, targetUrl = GATEWAY_URL) {
    const orders = [];
    const ordersPerLevel = Math.ceil(ordersPerSymbol / priceLevels);

    for (const symbol of symbols) {
        for (let level = 1; level <= priceLevels; level++) {
            for (let i = 0; i < ordersPerLevel; i++) {
                orders.push(generateSeedSellOrder(symbol, level, i));
            }
        }
    }

    const url = `${targetUrl}/seed/${shardId}`;
    const payload = JSON.stringify({ orders: orders });
    const params = { headers: { 'Content-Type': 'application/json' }, timeout: '30s' };

    const res = http.post(url, payload, params);
    check(res, {
        'seed response status is 200': (r) => r.status === 200,
    });

    console.log(`Seeded shard ${shardId}: ${orders.length} orders across ${symbols.length} symbols, ${priceLevels} price levels`);
    return orders.length;
}

/**
 * Seed directly to an ME shard (bypass gateway). Used for ASR 1 single-shard tests.
 */
export function seedShardDirect(symbols, ordersPerSymbol, priceLevels, meUrl = ME_SHARD_A_URL) {
    const orders = [];
    const ordersPerLevel = Math.ceil(ordersPerSymbol / priceLevels);

    for (const symbol of symbols) {
        for (let level = 1; level <= priceLevels; level++) {
            for (let i = 0; i < ordersPerLevel; i++) {
                orders.push(generateSeedSellOrder(symbol, level, i));
            }
        }
    }

    const url = `${meUrl}/seed`;
    const payload = JSON.stringify({ orders: orders });
    const params = { headers: { 'Content-Type': 'application/json' }, timeout: '30s' };

    const res = http.post(url, payload, params);
    check(res, {
        'seed response status is 200': (r) => r.status === 200,
    });

    console.log(`Seeded ME directly: ${orders.length} orders across ${symbols.length} symbols, ${priceLevels} price levels`);
    return orders.length;
}
```

---

## 5. Test Scripts

### 5.1 Test Case A1: Warm-up and Baseline

**File:** `test-asr1-a1-warmup.js`

```javascript
import http from 'k6/http';
import { check } from 'k6';
import { generateMixedOrder, randomShardASymbol } from './lib/orderGenerator.js';
import { seedShardDirect } from './lib/seedHelper.js';
import { ME_SHARD_A_URL, SHARD_A_SYMBOLS, LATENCY_THRESHOLD_MS } from './lib/config.js';

export const options = {
    scenarios: {
        warmup: {
            executor: 'constant-arrival-rate',
            rate: 500,              // 500 orders/min
            timeUnit: '1m',
            duration: '2m',
            preAllocatedVUs: 20,
            maxVUs: 50,
        },
    },
    thresholds: {
        // No thresholds for warm-up -- discard results
    },
};

export function setup() {
    // Pre-seed with 500 resting sell orders across 50 price levels
    seedShardDirect(SHARD_A_SYMBOLS, 500, 50, ME_SHARD_A_URL);
}

export default function () {
    const symbol = randomShardASymbol();
    const order = generateMixedOrder(symbol);
    const payload = JSON.stringify(order);

    const res = http.post(`${ME_SHARD_A_URL}/orders`, payload, {
        headers: { 'Content-Type': 'application/json' },
    });

    check(res, {
        'status is 200': (r) => r.status === 200,
    });
}
```

### 5.2 Test Case A2: Normal Load Latency (PRIMARY ASR 1 TEST)

**File:** `test-asr1-a2-normal-load.js`

```javascript
import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';
import { generateMixedOrder, randomShardASymbol } from './lib/orderGenerator.js';
import { seedShardDirect } from './lib/seedHelper.js';
import { ME_SHARD_A_URL, SHARD_A_SYMBOLS, LATENCY_THRESHOLD_MS } from './lib/config.js';

// Custom metric for match latency (end-to-end from k6 perspective)
const matchLatency = new Trend('match_latency_ms');

export const options = {
    scenarios: {
        normal_load: {
            executor: 'constant-arrival-rate',
            rate: 17,               // ~17 orders/sec = ~1,000/min
            timeUnit: '1s',
            duration: '5m',
            preAllocatedVUs: 30,
            maxVUs: 60,
        },
    },
    thresholds: {
        'http_req_duration': ['p(99)<200'],  // p99 < 200ms (end-to-end from k6)
        'match_latency_ms': ['p(99)<200'],   // Same threshold on custom metric
        'http_req_failed': ['rate<0.01'],     // Error rate < 1%
    },
};

export function setup() {
    // Pre-seed with 500 resting sell orders, 50 price levels
    seedShardDirect(SHARD_A_SYMBOLS, 500, 50, ME_SHARD_A_URL);
}

export default function () {
    const symbol = randomShardASymbol();
    const order = generateMixedOrder(symbol);
    const payload = JSON.stringify(order);

    const res = http.post(`${ME_SHARD_A_URL}/orders`, payload, {
        headers: { 'Content-Type': 'application/json' },
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

    matchLatency.add(res.timings.duration);
}
```

### 5.3 Test Case A3: Order Book Depth Variation

**File:** `test-asr1-a3-depth-variation.js`

```javascript
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend } from 'k6/metrics';
import { generateMixedOrder, randomShardASymbol } from './lib/orderGenerator.js';
import { seedShardDirect } from './lib/seedHelper.js';
import { ME_SHARD_A_URL, SHARD_A_SYMBOLS, LATENCY_THRESHOLD_MS } from './lib/config.js';

const matchLatency = new Trend('match_latency_ms');

export const options = {
    scenarios: {
        // Sub-test 1: Shallow (100 resting orders, 10 price levels)
        shallow: {
            executor: 'constant-arrival-rate',
            rate: 17,
            timeUnit: '1s',
            duration: '3m',
            preAllocatedVUs: 30,
            maxVUs: 60,
            startTime: '0s',
            env: { DEPTH_LABEL: 'shallow' },
        },
        // Sub-test 2: Medium (1,000 resting orders, 100 price levels)
        medium: {
            executor: 'constant-arrival-rate',
            rate: 17,
            timeUnit: '1s',
            duration: '3m',
            preAllocatedVUs: 30,
            maxVUs: 60,
            startTime: '3m30s',  // 30s gap for re-seeding
            env: { DEPTH_LABEL: 'medium' },
        },
        // Sub-test 3: Deep (10,000 resting orders, 500 price levels)
        deep: {
            executor: 'constant-arrival-rate',
            rate: 17,
            timeUnit: '1s',
            duration: '3m',
            preAllocatedVUs: 30,
            maxVUs: 60,
            startTime: '7m',  // 30s gap for re-seeding
            env: { DEPTH_LABEL: 'deep' },
        },
    },
    thresholds: {
        'http_req_duration': ['p(99)<200'],
        'match_latency_ms': ['p(99)<200'],
    },
};

export function setup() {
    // Seed for the shallow test first
    // Note: The ME must be restarted between sub-tests to reset the order book,
    // OR the seed endpoint must support clearing the book.
    // For simplicity, seed with the maximum (10,000) and let depth grow naturally.
    // Alternative: run each sub-test as a separate k6 invocation with different seed sizes.
    //
    // RECOMMENDED APPROACH: Run this as 3 separate k6 invocations:
    //   1. Seed 100 orders, run 3 min
    //   2. Restart ME or clear, seed 1000, run 3 min
    //   3. Restart ME or clear, seed 10000, run 3 min
    //
    // For a single-invocation approach, we seed with 10,000 and accept that depth
    // changes dynamically during the test (orders are consumed by matching).
    seedShardDirect(SHARD_A_SYMBOLS, 10000, 500, ME_SHARD_A_URL);
}

export default function () {
    const symbol = randomShardASymbol();
    const order = generateMixedOrder(symbol);
    const payload = JSON.stringify(order);

    const res = http.post(`${ME_SHARD_A_URL}/orders`, payload, {
        headers: { 'Content-Type': 'application/json' },
    });

    check(res, { 'status is 200': (r) => r.status === 200 });
    matchLatency.add(res.timings.duration);
}
```

**Implementation note:** For the cleanest depth variation test, run 3 separate k6 invocations with different seed sizes. Each invocation restarts the ME shard to ensure a clean order book. The infrastructure script (Spec 4) should provide a convenience script for this.

### 5.4 Test Case A4: Kafka Degradation (Decoupling Proof)

**File:** `test-asr1-a4-kafka-degradation.js`

```javascript
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend } from 'k6/metrics';
import { generateMixedOrder, randomShardASymbol } from './lib/orderGenerator.js';
import { seedShardDirect } from './lib/seedHelper.js';
import { ME_SHARD_A_URL, SHARD_A_SYMBOLS } from './lib/config.js';

const matchLatency = new Trend('match_latency_ms');

export const options = {
    scenarios: {
        kafka_degradation: {
            executor: 'constant-arrival-rate',
            rate: 17,
            timeUnit: '1s',
            duration: '3m',
            preAllocatedVUs: 30,
            maxVUs: 60,
        },
    },
    thresholds: {
        'http_req_duration': ['p(99)<200'],
        'match_latency_ms': ['p(99)<200'],
    },
};

export function setup() {
    seedShardDirect(SHARD_A_SYMBOLS, 500, 50, ME_SHARD_A_URL);
    console.log('IMPORTANT: At t=60s, manually pause the Redpanda pod:');
    console.log('  kubectl scale statefulset redpanda --replicas=0 -n matching-engine');
    console.log('Monitor that p99 latency does NOT spike during Kafka outage.');
    console.log('After the test, restore Redpanda:');
    console.log('  kubectl scale statefulset redpanda --replicas=1 -n matching-engine');
}

export default function () {
    const symbol = randomShardASymbol();
    const order = generateMixedOrder(symbol);
    const payload = JSON.stringify(order);

    const res = http.post(`${ME_SHARD_A_URL}/orders`, payload, {
        headers: { 'Content-Type': 'application/json' },
    });

    check(res, { 'status is 200': (r) => r.status === 200 });
    matchLatency.add(res.timings.duration);
}
```

**Operational note:** The Redpanda pause at t=60s must be done manually (or via a separate script) since k6 cannot execute kubectl commands. The infrastructure spec (Spec 4) should provide a helper script that pauses Redpanda on a timer. The pass criterion: p99 matching latency does NOT increase by > 10% when Kafka is degraded.

### 5.5 Test Case B1: Single Shard Baseline

**File:** `test-asr2-b1-baseline.js`

```javascript
import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';
import { generateMixedOrder, randomShardASymbol } from './lib/orderGenerator.js';
import { seedShardDirect } from './lib/seedHelper.js';
import { ME_SHARD_A_URL, SHARD_A_SYMBOLS } from './lib/config.js';

const matchLatency = new Trend('match_latency_ms');

export const options = {
    scenarios: {
        baseline: {
            executor: 'constant-arrival-rate',
            rate: 17,
            timeUnit: '1s',
            duration: '3m',
            preAllocatedVUs: 30,
            maxVUs: 60,
        },
    },
    thresholds: {
        'http_req_duration': ['p(99)<200'],
        'match_latency_ms': ['p(99)<200'],
    },
};

export function setup() {
    seedShardDirect(SHARD_A_SYMBOLS, 500, 50, ME_SHARD_A_URL);
}

export default function () {
    const symbol = randomShardASymbol();
    const order = generateMixedOrder(symbol);
    const payload = JSON.stringify(order);

    const res = http.post(`${ME_SHARD_A_URL}/orders`, payload, {
        headers: { 'Content-Type': 'application/json' },
    });

    check(res, { 'status is 200': (r) => r.status === 200 });
    matchLatency.add(res.timings.duration);
}
```

### 5.6 Test Case B2: Peak Sustained -- 3 Shards (PRIMARY ASR 2 TEST)

**File:** `test-asr2-b2-peak-sustained.js`

```javascript
import http from 'k6/http';
import { check } from 'k6';
import { Trend, Counter } from 'k6/metrics';
import { generateMixedOrder, randomSymbol } from './lib/orderGenerator.js';
import { seedShard } from './lib/seedHelper.js';
import { GATEWAY_URL, SHARD_A_SYMBOLS, SHARD_B_SYMBOLS, SHARD_C_SYMBOLS, ALL_SYMBOLS } from './lib/config.js';

const matchLatency = new Trend('match_latency_ms');
const matchCount = new Counter('match_count');

export const options = {
    scenarios: {
        peak_sustained: {
            executor: 'constant-arrival-rate',
            rate: 84,               // ~84 orders/sec = ~5,040/min (slightly above 5,000)
            timeUnit: '1s',
            duration: '5m',
            preAllocatedVUs: 100,
            maxVUs: 200,
        },
    },
    thresholds: {
        'http_req_duration': ['p(99)<200'],
        'match_latency_ms': ['p(99)<200'],
        'http_req_failed': ['rate<0.01'],
    },
};

export function setup() {
    // Seed all 3 shards via the gateway
    seedShard('a', SHARD_A_SYMBOLS, 500, 50, GATEWAY_URL);
    seedShard('b', SHARD_B_SYMBOLS, 500, 50, GATEWAY_URL);
    seedShard('c', SHARD_C_SYMBOLS, 500, 50, GATEWAY_URL);
}

export default function () {
    // Distribute orders evenly across all 12 symbols (4 per shard)
    const symbol = randomSymbol(ALL_SYMBOLS);
    const order = generateMixedOrder(symbol);
    const payload = JSON.stringify(order);

    const res = http.post(`${GATEWAY_URL}/orders`, payload, {
        headers: { 'Content-Type': 'application/json' },
    });

    check(res, {
        'status is 200': (r) => r.status === 200,
    });

    matchLatency.add(res.timings.duration);
    matchCount.add(1);
}
```

### 5.7 Test Case B3: Ramp Test

**File:** `test-asr2-b3-ramp.js`

```javascript
import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';
import { generateMixedOrder, randomSymbol, randomShardASymbol } from './lib/orderGenerator.js';
import { seedShard } from './lib/seedHelper.js';
import { GATEWAY_URL, SHARD_A_SYMBOLS, SHARD_B_SYMBOLS, SHARD_C_SYMBOLS, ALL_SYMBOLS } from './lib/config.js';

const matchLatency = new Trend('match_latency_ms');

export const options = {
    scenarios: {
        ramp: {
            executor: 'ramping-arrival-rate',
            startRate: 17,          // ~1,000/min
            timeUnit: '1s',
            preAllocatedVUs: 150,
            maxVUs: 300,
            stages: [
                { duration: '2m', target: 17 },    // t=0-2m: 1,000 matches/min (1 shard)
                { duration: '2m', target: 42 },    // t=2-4m: 2,500 matches/min (2 shards)
                { duration: '2m', target: 84 },    // t=4-6m: 5,000 matches/min (3 shards)
                { duration: '4m', target: 84 },    // t=6-10m: sustained 5,000/min
            ],
        },
    },
    thresholds: {
        'http_req_duration': ['p(99)<200'],
        'match_latency_ms': ['p(99)<200'],
    },
};

export function setup() {
    // Seed all 3 shards
    seedShard('a', SHARD_A_SYMBOLS, 500, 50, GATEWAY_URL);
    seedShard('b', SHARD_B_SYMBOLS, 500, 50, GATEWAY_URL);
    seedShard('c', SHARD_C_SYMBOLS, 500, 50, GATEWAY_URL);
    console.log('NOTE: All 3 ME shards must be running for the full ramp test.');
    console.log('Shard addition at t=2m and t=4m is assumed to already be done (all shards pre-deployed).');
}

export default function () {
    const symbol = randomSymbol(ALL_SYMBOLS);
    const order = generateMixedOrder(symbol);
    const payload = JSON.stringify(order);

    const res = http.post(`${GATEWAY_URL}/orders`, payload, {
        headers: { 'Content-Type': 'application/json' },
    });

    check(res, { 'status is 200': (r) => r.status === 200 });
    matchLatency.add(res.timings.duration);
}
```

### 5.8 Test Case B4: Hot Symbol Test

**File:** `test-asr2-b4-hot-symbol.js`

```javascript
import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';
import { generateMixedOrder, randomSymbol } from './lib/orderGenerator.js';
import { seedShard } from './lib/seedHelper.js';
import { GATEWAY_URL, SHARD_A_SYMBOLS, SHARD_B_SYMBOLS, SHARD_C_SYMBOLS, ALL_SYMBOLS } from './lib/config.js';

const matchLatency = new Trend('match_latency_ms');

// Hot symbol: TEST-ASSET-A on Shard A gets 80% of traffic
const HOT_SYMBOL = 'TEST-ASSET-A';

export const options = {
    scenarios: {
        hot_symbol: {
            executor: 'constant-arrival-rate',
            rate: 84,               // ~5,000/min total
            timeUnit: '1s',
            duration: '5m',
            preAllocatedVUs: 100,
            maxVUs: 200,
        },
    },
    thresholds: {
        'http_req_duration': ['p(99)<200'],
        'match_latency_ms': ['p(99)<200'],
    },
};

export function setup() {
    // Seed all 3 shards, with extra depth on shard A for the hot symbol
    seedShard('a', SHARD_A_SYMBOLS, 2000, 100, GATEWAY_URL);
    seedShard('b', SHARD_B_SYMBOLS, 500, 50, GATEWAY_URL);
    seedShard('c', SHARD_C_SYMBOLS, 500, 50, GATEWAY_URL);
}

export default function () {
    let symbol;
    if (Math.random() < 0.8) {
        // 80% of traffic to the hot symbol
        symbol = HOT_SYMBOL;
    } else {
        // 20% distributed across all other symbols
        const otherSymbols = ALL_SYMBOLS.filter(s => s !== HOT_SYMBOL);
        symbol = randomSymbol(otherSymbols);
    }

    const order = generateMixedOrder(symbol);
    const payload = JSON.stringify(order);

    const res = http.post(`${GATEWAY_URL}/orders`, payload, {
        headers: { 'Content-Type': 'application/json' },
    });

    check(res, { 'status is 200': (r) => r.status === 200 });
    matchLatency.add(res.timings.duration);
}
```

### 5.9 Standalone Seed Script

**File:** `seed-orderbooks.js`

A standalone script to seed order books without running load. Useful for manual testing.

```javascript
import { seedShard, seedShardDirect } from './lib/seedHelper.js';
import { GATEWAY_URL, ME_SHARD_A_URL, SHARD_A_SYMBOLS, SHARD_B_SYMBOLS, SHARD_C_SYMBOLS } from './lib/config.js';

export const options = {
    vus: 1,
    iterations: 1,
};

export default function () {
    const mode = __ENV.SEED_MODE || 'single';  // 'single' or 'multi'
    const depth = parseInt(__ENV.SEED_DEPTH || '500');
    const levels = parseInt(__ENV.SEED_LEVELS || '50');

    if (mode === 'single') {
        // Seed shard A directly
        seedShardDirect(SHARD_A_SYMBOLS, depth, levels, ME_SHARD_A_URL);
    } else {
        // Seed all 3 shards via gateway
        seedShard('a', SHARD_A_SYMBOLS, depth, levels, GATEWAY_URL);
        seedShard('b', SHARD_B_SYMBOLS, depth, levels, GATEWAY_URL);
        seedShard('c', SHARD_C_SYMBOLS, depth, levels, GATEWAY_URL);
    }
}
```

**Usage:**
```bash
# Seed single shard with 500 orders across 50 levels
k6 run -e SEED_MODE=single -e SEED_DEPTH=500 -e SEED_LEVELS=50 seed-orderbooks.js

# Seed all 3 shards
k6 run -e SEED_MODE=multi -e SEED_DEPTH=500 -e SEED_LEVELS=50 seed-orderbooks.js
```

---

## 6. Environment Variables (k6 invocation)

| Variable | Default | Used By |
|:---|:---|:---|
| `GATEWAY_URL` | `http://localhost:8080` | All multi-shard tests (B1-B4) |
| `ME_SHARD_A_URL` | `http://localhost:8080` | Single-shard tests (A1-A4, B1) |
| `SEED_MODE` | `single` | `seed-orderbooks.js` |
| `SEED_DEPTH` | `500` | `seed-orderbooks.js` |
| `SEED_LEVELS` | `50` | `seed-orderbooks.js` |

---

## 7. Integration Points

### 7.1 What This Component Consumes

| Source | Protocol | Data |
|:---|:---|:---|
| ME shard(s) | HTTP response | Order ACK JSON |
| Edge Gateway | HTTP response | Proxied order ACK JSON |

### 7.2 What This Component Produces

| Destination | Protocol | Data |
|:---|:---|:---|
| ME shard(s) / Edge Gateway | HTTP POST `/orders` | Order JSON |
| ME shard(s) / Edge Gateway | HTTP POST `/seed` or `/seed/{shardId}` | Seed orders JSON |
| Prometheus (via `--out experimental-prometheus-rw`) | Prometheus remote write | k6 metrics (http_req_duration, iterations, vus, custom trends) |

---

## 8. Running the Tests

### 8.1 ASR 1: Latency Tests (Single Shard)

```bash
# Port-forward ME shard A
kubectl port-forward svc/me-shard-a 8080:8080 -n matching-engine &

# 1. Warm-up (discard results)
k6 run -e ME_SHARD_A_URL=http://localhost:8080 src/k6/test-asr1-a1-warmup.js

# 2. Normal load latency (PRIMARY TEST)
k6 run \
  --out experimental-prometheus-rw=http://localhost:9090/api/v1/write \
  -e ME_SHARD_A_URL=http://localhost:8080 \
  src/k6/test-asr1-a2-normal-load.js

# 3. Depth variation (run as 3 separate invocations with ME restart between each)
# ... (see test script comments)

# 4. Kafka degradation
k6 run \
  --out experimental-prometheus-rw=http://localhost:9090/api/v1/write \
  -e ME_SHARD_A_URL=http://localhost:8080 \
  src/k6/test-asr1-a4-kafka-degradation.js
# At t=60s, in another terminal: kubectl scale statefulset redpanda --replicas=0 -n matching-engine
```

### 8.2 ASR 2: Scalability Tests (Multi-Shard)

```bash
# Port-forward Edge Gateway
kubectl port-forward svc/edge-gateway 8080:8080 -n matching-engine &

# 1. Baseline (single shard through gateway)
k6 run \
  --out experimental-prometheus-rw=http://localhost:9090/api/v1/write \
  -e GATEWAY_URL=http://localhost:8080 \
  src/k6/test-asr2-b1-baseline.js

# 2. Peak sustained (PRIMARY TEST)
k6 run \
  --out experimental-prometheus-rw=http://localhost:9090/api/v1/write \
  -e GATEWAY_URL=http://localhost:8080 \
  src/k6/test-asr2-b2-peak-sustained.js

# 3. Ramp test
k6 run \
  --out experimental-prometheus-rw=http://localhost:9090/api/v1/write \
  -e GATEWAY_URL=http://localhost:8080 \
  src/k6/test-asr2-b3-ramp.js

# 4. Hot symbol test
k6 run \
  --out experimental-prometheus-rw=http://localhost:9090/api/v1/write \
  -e GATEWAY_URL=http://localhost:8080 \
  src/k6/test-asr2-b4-hot-symbol.js
```

---

## 9. Acceptance Criteria

This role is "done" when:

1. **All 8 test scripts parse without errors:** `k6 inspect <script>` returns valid configuration for each.
2. **Seed script works:** `seed-orderbooks.js` successfully seeds an ME shard (verified via `me_orderbook_depth` gauge > 0).
3. **A2 normal load test executes:** 5-minute run at 17 orders/sec completes without crashing, with < 1% error rate.
4. **B2 peak sustained test executes:** 5-minute run at 84 orders/sec across 3 shards completes with < 1% error rate.
5. **B3 ramp test ramps correctly:** Rate increases from 17/sec to 42/sec to 84/sec as defined in the stages.
6. **B4 hot symbol test sends 80% to TEST-ASSET-A:** Verified by checking per-shard throughput (shard A should receive ~80% of total requests).
7. **Prometheus metrics are pushed:** When run with `--out experimental-prometheus-rw`, k6 metrics (`k6_http_req_duration`, `k6_http_reqs`, `k6_vus`) appear in Prometheus.
8. **Custom `match_latency_ms` trend is recorded:** The custom metric appears in k6 summary output and in Prometheus.
9. **k6 thresholds enforce pass/fail:** If p99 > 200ms, the test exits with a non-zero status code.
10. **Order generation produces realistic mix:** 60% aggressive orders (match immediately) and 40% passive orders (rest in book), verified by checking that `me_matches_total` grows at roughly 60% of the order submission rate.

---

## 10. Pass/Fail Criteria (from experiment-design.md)

### ASR 1 Pass Criteria (evaluated from test-asr1-a2-normal-load.js)

| Metric | Pass | Fail |
|:---|:---|:---|
| p99 `me_match_duration_seconds` (from Prometheus) | < 200 ms | >= 200 ms |
| p99 `http_req_duration` (from k6) | < 200 ms | >= 200 ms |
| Error rate | < 1% | >= 1% |
| GC pauses (`jvm_gc_pause_seconds_max`) | < 5 ms | >= 10 ms |

### ASR 2 Pass Criteria (evaluated from test-asr2-b2-peak-sustained.js)

| Metric | Pass | Fail |
|:---|:---|:---|
| Aggregate throughput `sum(rate(me_matches_total[1m]))` | >= 4,750 matches/min for >= 4 min | < 4,750 matches/min |
| Per-shard p99 `me_match_duration_seconds` | < 200 ms per shard | >= 200 ms on any shard |
| Linear scaling ratio | throughput(3 shards) >= 0.9 * 3 * throughput(1 shard) | Sub-linear |
| Shard isolation | Shard A p99 unchanged (+/- 5%) when Shard B load increases | > 5% degradation |
