import http from 'k6/http';
import { check, sleep } from 'k6';
import { SharedArray } from 'k6/data';
import { Rate, Trend } from 'k6/metrics';

/**
 * K6 DUAL-CONFIG Performance Testing Script for Multi-Category Matching Engine
 * Based on LMAX Disruptor Architecture
 * 
 * ============================================================================
 * CONFIGURACIONES DISPONIBLES (BLOQUE 1 ACTIVO, BLOQUE 2 COMENTADO)
 * ============================================================================
 * 
 * 📦 BLOQUE 1 (ACTIVO): DISTRIBUIDO EN 3 MINUTOS
 * ------------------------------------------------
 * - Target: 1,300 órdenes/minuto
 * - Duración: 3 minutos continuos
 * - Total esperado: ~3,900 órdenes
 * - Distribución: 500 BUY (38.46%) | 800 SELL (61.54%)
 * - Naturaleza: Estocástico (proceso de Poisson)
 * 
 * 📦 BLOQUE 2 (COMENTADO): ULTRA AGRESIVO
 * ------------------------------------------------
 * - Target: 1,300 órdenes/segundo
 * - Duración: 10 segundos continuos
 * - Total esperado: ~13,000 órdenes
 * - Distribución: 500 BUY (38.46%) | 800 SELL (61.54%)
 * - Naturaleza: Estocástico (proceso de Poisson)
 * 
 * ASR Targets:
 * - Critical Latency: < 200ms (p99)
 * - Success rate: > 99%
 * 
 * @author Performance Testing Team
 * @version 3.0.0 - DUAL-CONFIG EDITION
 */

// ============================================================================
// CUSTOM METRICS
// ============================================================================
const matchingLatency = new Trend('matching_latency', true);
const orderSuccessRate = new Rate('order_success_rate');
const buyOrderRate = new Rate('buy_order_rate');
const sellOrderRate = new Rate('sell_order_rate');

// ============================================================================
// CONFIGURATION
// ============================================================================
const BASE_URL = 'http://localhost:8080';
const ENDPOINT = '/api/v1/orders';

// Order Distribution: 500 BUY / 800 SELL = 38.46% BUY / 61.54% SELL
const BUY_PROBABILITY = 0.3846;  // 500/1300 = 38.46%

// ============================================================================
// ⚙️ BLOQUE 1: DISTRIBUIDO EN 3 MINUTOS (ACTIVO)
// ============================================================================
/**
 * CÁLCULO BLOQUE 1:
 * - Target: 1,300 órdenes/minuto = 21.67 órdenes/segundo
 * - Fórmula: VUs × Lambda = 21.67
 * - Configuración: 10 VUs × 2.167 = 21.67 órds/seg
 * 
 * Durante 3 minutos (180s):
 * - Total: 21.67 × 180 = ~3,900 órdenes
 * - BUY: 3,900 × 0.3846 = ~1,500 órdenes
 * - SELL: 3,900 × 0.6154 = ~2,400 órdenes
 */
export const options = {
    stages: [
        // Stage 1: Warm-up - 10 segundos para establecer conexiones
        { duration: '5s', target: 10 },

        // Stage 2: Carga sostenida - 3 minutos a 1,300 órdenes/minuto
        { duration: '180s', target: 10 },  // 180 segundos = 3 minutos

        // Stage 3: Cool-down
        { duration: '5s', target: 0 },
    ],

    // Performance Thresholds (ASRs)
    thresholds: {
        'http_req_duration': ['p(99)<200'],
        'http_req_failed': ['rate<0.01'],
        'matching_latency': ['p(99)<200', 'p(95)<150', 'p(50)<100'],
        'order_success_rate': ['rate>0.99'],
    },

    batch: 1,
    batchPerHost: 1,
};

// Lambda para BLOQUE 1: 2.167 órdenes/segundo por VU
const LAMBDA_CONFIG = 2.167;

// ============================================================================
// ⚙️ BLOQUE 2: ULTRA AGRESIVO - 1,300 ÓRDENES/SEGUNDO (COMENTADO)
// ============================================================================
/**
 * CÁLCULO BLOQUE 2:
 * - Target: 1,300 órdenes/segundo
 * - Fórmula: VUs × Lambda = 1,300
 * - Configuración: 13 VUs × 100 = 1,300 órds/seg
 * 
 * Durante 10 segundos:
 * - Total: 1,300 × 10 = ~13,000 órdenes
 * - BUY: 13,000 × 0.3846 = ~5,000 órdenes
 * - SELL: 13,000 × 0.6154 = ~8,000 órdenes
 */

/*
// ⚠️ PARA ACTIVAR BLOQUE 2: Descomenta esta sección y comenta el BLOQUE 1 arriba

export const options = {
    stages: [
        // Stage 1: Quick warm-up - 2 segundos
        { duration: '2s', target: 13 },
        
        // Stage 2: AGGRESSIVE BLAST - 10 segundos a máxima velocidad
        { duration: '10s', target: 13 },
        
        // Stage 3: Shutdown inmediato
        { duration: '1s', target: 0 },
    ],
    
    // Performance Thresholds (ASRs)
    thresholds: {
        'http_req_duration': ['p(99)<200'],
        'http_req_failed': ['rate<0.01'],
        'matching_latency': ['p(99)<200', 'p(95)<150', 'p(50)<100'],
        'order_success_rate': ['rate>0.99'],
    },
    
    batch: 1,
    batchPerHost: 1,
};

// Lambda para BLOQUE 2: 100 órdenes/segundo por VU
const LAMBDA_CONFIG = 100;
*/

// ============================================================================
// MULTI-ASSET DATA MODEL
// ============================================================================
const assets = new SharedArray('assets', function () {
    return [
        {
            category: 'STOCKS',
            symbol: 'ECOPETROL',
            basePrice: 2500,           // COP
            volatility: 0.0005,        // 0.05% volatility
            priceStep: 10,             // Minimum price increment (COP)
        },
        {
            category: 'VEHICLES',
            symbol: 'MAZDA_CX5',
            basePrice: 140000000,      // COP
            volatility: 0.0005,        // 0.05% volatility
            priceStep: 100000,         // Minimum price increment (100k COP)
        },
        {
            category: 'REAL_ESTATE',
            symbol: 'APTO_CHAPINERO',
            basePrice: 450000000,      // COP
            volatility: 0.0005,        // 0.05% volatility
            priceStep: 500000,         // Minimum price increment (500k COP)
        },
    ];
});

// ============================================================================
// MARKET STATE TRACKING (Per-VU Initialization)
// ============================================================================
let marketPrices = {};

export function setup() {
    console.log('🚀 Initializing K6 DUAL-CONFIG Load Test for Matching Engine');
    console.log('');
    console.log('📦 ACTIVE CONFIGURATION: BLOQUE 1 - Distribuido en 3 minutos');
    console.log('   - Target Rate: 1,300 órdenes/minuto (21.67 órds/seg)');
    console.log('   - Duration: 3 minutos (180 segundos)');
    console.log('   - Expected Total: ~3,900 órdenes');
    console.log('   - Virtual Users: 10 VUs');
    console.log('   - Lambda: 2.167 órdenes/seg por VU');
    console.log('');
    console.log('📊 Order Distribution (Estocástico):');
    console.log('   - BUY: ~38.46% (~1,500 órdenes)');
    console.log('   - SELL: ~61.54% (~2,400 órdenes)');
    console.log('');
    console.log('🎯 Target ASRs:');
    console.log('   - Latency (p99): < 200ms');
    console.log('   - Success rate: > 99%');
    console.log('   - Endpoint: POST ' + BASE_URL + ENDPOINT);
    console.log('');
    console.log('💡 To switch to BLOQUE 2, uncomment the BLOQUE 2 section in the script');
    console.log('');

    // Initialize market prices with base prices
    const initialPrices = {};
    assets.forEach(asset => {
        initialPrices[asset.symbol] = asset.basePrice;
    });

    return { initialPrices };
}

export default function (data) {
    // Initialize VU-specific market state on first iteration
    if (__ITER === 0) {
        marketPrices = { ...data.initialPrices };
    }

    // Step 1: Randomly select an asset
    const asset = assets[Math.floor(Math.random() * assets.length)];

    // Step 2: Update market price using Gaussian Random Walk
    const newPrice = updateMarketPrice(asset);

    // Step 3: Generate aggressive order with controlled BUY/SELL distribution
    const order = generateAggressiveOrder(asset, newPrice);

    // Step 4: Send order to matching engine
    const startTime = Date.now();

    const payload = JSON.stringify(order);
    const params = {
        headers: {
            'Content-Type': 'application/json',
        },
        tags: {
            category: asset.category,
            symbol: asset.symbol,
            side: order.side,
        },
    };

    const response = http.post(`${BASE_URL}${ENDPOINT}`, payload, params);

    const duration = Date.now() - startTime;

    // Step 5: Record metrics and validate
    matchingLatency.add(duration);

    // Track BUY/SELL distribution
    if (order.side === 'BUY') {
        buyOrderRate.add(1);
        sellOrderRate.add(0);
    } else {
        buyOrderRate.add(0);
        sellOrderRate.add(1);
    }

    const success = check(response, {
        'status is 200': (r) => r.status === 200,
        'response has body': (r) => r.body && r.body.length > 0,
        'latency < 200ms': () => duration < 200,
    });

    orderSuccessRate.add(success);

    // Optional: Log failures for debugging (throttled to avoid spam)
    if (!success && __ITER % 100 === 0) {
        console.error(`❌ Order failed: ${asset.symbol} ${order.side} @ ${order.price} - Status: ${response.status}`);
    }

    // Step 6: Stochastic inter-arrival time using Poisson process
    sleepPoisson(LAMBDA_CONFIG);
}

// ============================================================================
// INTELLIGENT PRICE GENERATION - GAUSSIAN RANDOM WALK
// ============================================================================
/**
 * Updates the market price for an asset using a Gaussian Random Walk.
 * This creates realistic price movement with small, random fluctuations.
 * 
 * Formula:
 *   NewPrice = CurrentPrice * (1 + GaussianNoise * Volatility)
 * 
 * @param {Object} asset - The asset configuration object
 * @returns {number} - The updated market price
 */
function updateMarketPrice(asset) {
    const currentPrice = marketPrices[asset.symbol];

    // Generate Gaussian noise using Box-Muller transform
    const gaussianNoise = boxMullerRandom();

    // Apply random walk: price change = basePrice * volatility * noise
    const priceChange = currentPrice * asset.volatility * gaussianNoise;

    // Update price and round to nearest price step
    let newPrice = currentPrice + priceChange;
    newPrice = Math.round(newPrice / asset.priceStep) * asset.priceStep;

    // Ensure price doesn't deviate too far from base (±10%)
    const minPrice = asset.basePrice * 0.90;
    const maxPrice = asset.basePrice * 1.10;
    newPrice = Math.max(minPrice, Math.min(maxPrice, newPrice));

    // Update market state
    marketPrices[asset.symbol] = newPrice;

    return newPrice;
}

/**
 * Box-Muller Transform to generate Gaussian-distributed random numbers
 * Returns a random number from a standard normal distribution (mean=0, std=1)
 * 
 * @returns {number} - Gaussian random number
 */
function boxMullerRandom() {
    const u1 = Math.random();
    const u2 = Math.random();

    // Box-Muller formula
    const z0 = Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(2.0 * Math.PI * u2);

    return z0;
}

// ============================================================================
// AGGRESSIVE ORDER GENERATION WITH CONTROLLED BUY/SELL DISTRIBUTION
// ============================================================================
/**
 * Generates an aggressive order with controlled BUY/SELL distribution.
 * 
 * DISTRIBUTION CONTROL:
 * ---------------------
 * - BUY: 38.46% probability (500/1300)
 * - SELL: 61.54% probability (800/1300)
 * 
 * This creates a realistic imbalanced order book scenario where
 * selling pressure is higher than buying pressure.
 * 
 * MATCHING LOGIC:
 * ---------------
 * Orders are priced aggressively to cross the spread and force immediate matching:
 * - BUY: Price = MarketPrice * (1 + spreadCrossing)
 * - SELL: Price = MarketPrice * (1 - spreadCrossing)
 * 
 * @param {Object} asset - The asset configuration
 * @param {number} marketPrice - Current market price from random walk
 * @returns {Object} - Order payload
 */
function generateAggressiveOrder(asset, marketPrice) {
    // Controlled BUY/SELL distribution: 38.46% BUY / 61.54% SELL
    const side = Math.random() < BUY_PROBABILITY ? 'BUY' : 'SELL';

    // Spread crossing factor: 3.5% (aggressive enough to match)
    const spreadCrossing = 0.035;

    let orderPrice;

    if (side === 'BUY') {
        // BUY: Bid ABOVE market to cross the spread and hit sellers
        orderPrice = marketPrice * (1 + spreadCrossing);
    } else {
        // SELL: Offer BELOW market to cross the spread and hit buyers
        orderPrice = marketPrice * (1 - spreadCrossing);
    }

    // Round to asset's minimum price step
    orderPrice = Math.round(orderPrice / asset.priceStep) * asset.priceStep;

    // Generate realistic quantity (random variation)
    const baseQuantity = 10;
    const quantity = baseQuantity + Math.floor(Math.random() * 20);

    // Construct order payload
    return {
        category: asset.category,
        symbol: asset.symbol,
        side: side,
        price: orderPrice,
        quantity: quantity,
        orderType: 'LIMIT',
        timeInForce: 'GTC',
        timestamp: Date.now(),
        clientOrderId: `K6_DUAL_${__VU}_${__ITER}_${Date.now()}`,
        routingStrategy: 'DISRUPTOR',
    };
}

// ============================================================================
// STOCHASTIC POISSON PROCESS - REALISTIC INTER-ARRIVAL TIMES
// ============================================================================
/**
 * Simulates stochastic order arrival times using a Poisson process.
 * 
 * The lambda parameter controls the average arrival rate:
 * - BLOQUE 1: Lambda = 2.167 (distributed over 3 minutes)
 * - BLOQUE 2: Lambda = 100 (ultra-aggressive, 1 second bursts)
 * 
 * Formula:
 *   sleepTime = -ln(randomUniform) / lambda
 * 
 * @param {number} lambda - Average arrival rate (orders/sec per VU)
 */
function sleepPoisson(lambda) {
    // Generate exponentially-distributed inter-arrival time
    const u = Math.random();
    const sleepTime = -Math.log(u) / lambda;

    // Adaptive bounds based on lambda value
    let minSleep, maxSleep;

    if (lambda >= 50) {
        // High-frequency mode (BLOQUE 2)
        minSleep = 0.001;  // 1ms
        maxSleep = 0.05;   // 50ms
    } else {
        // Distributed mode (BLOQUE 1)
        minSleep = 0.01;   // 10ms
        maxSleep = 1.0;    // 1s
    }

    const boundedSleep = Math.max(minSleep, Math.min(maxSleep, sleepTime));

    sleep(boundedSleep);
}

// ============================================================================
// TEARDOWN - FINAL REPORT
// ============================================================================
export function teardown(data) {
    console.log('');
    console.log('✅ Load test completed');
    console.log('');
    console.log('📈 Review custom metrics:');
    console.log('   - matching_latency (p99, p95, p50)');
    console.log('   - order_success_rate');
    console.log('   - buy_order_rate (should be ~38.46%)');
    console.log('   - sell_order_rate (should be ~61.54%)');
    console.log('   - http_reqs (total orders sent)');
    console.log('');
    console.log('🔍 To analyze results, check K6 summary output above');
    console.log('');
    console.log('📊 Expected Distribution:');
    console.log('   - BUY: ~38.46% of total orders');
    console.log('   - SELL: ~61.54% of total orders');
    console.log('');
}
