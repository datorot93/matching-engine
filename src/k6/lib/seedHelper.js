// =============================================================================
// Order Book seeding helpers for k6 load tests
// Spec 3, Section 4.3
//
// Two modes:
//   - seedShard()       : Seeds via the Edge Gateway POST /seed/{shardId}
//   - seedShardDirect() : Seeds directly to an ME shard POST /seed
//
// Both pre-populate the Order Book with resting SELL orders so incoming
// aggressive BUY orders have counterparties to match against.
// =============================================================================

import http from 'k6/http';
import { check } from 'k6';
import { generateSeedSellOrder } from './orderGenerator.js';
import { GATEWAY_URL, ME_SHARD_A_URL, JSON_HEADERS, SEED_TIMEOUT } from './config.js';

/**
 * Seed a shard via the Edge Gateway's /seed/{shardId} endpoint.
 * Used for ASR 2 multi-shard tests.
 *
 * @param {string}   shardId         - Shard identifier (a, b, c)
 * @param {string[]} symbols         - Symbols assigned to this shard
 * @param {number}   ordersPerSymbol - Total resting orders per symbol
 * @param {number}   priceLevels     - Number of distinct price levels to spread across
 * @param {string}   [targetUrl]     - Gateway base URL (defaults to GATEWAY_URL)
 * @returns {number} Total number of seed orders sent
 */
export function seedShard(shardId, symbols, ordersPerSymbol, priceLevels, targetUrl) {
    const baseUrl = targetUrl || GATEWAY_URL;
    const orders  = buildSeedOrders(symbols, ordersPerSymbol, priceLevels);
    const url     = `${baseUrl}/seed/${shardId}`;
    const payload = JSON.stringify({ orders: orders });
    const params  = { headers: JSON_HEADERS, timeout: SEED_TIMEOUT };

    const res = http.post(url, payload, params);

    const ok = check(res, {
        [`seed shard ${shardId} status is 200`]: (r) => r.status === 200,
    });

    if (!ok) {
        console.error(`SEED FAILED for shard ${shardId}: status=${res.status}, body=${res.body}`);
    }

    console.log(
        `Seeded shard ${shardId}: ${orders.length} orders across ` +
        `${symbols.length} symbols, ${priceLevels} price levels`
    );

    return orders.length;
}

/**
 * Seed directly to an ME shard via POST /seed (bypass gateway).
 * Used for ASR 1 single-shard tests.
 *
 * @param {string[]} symbols         - Symbols to seed
 * @param {number}   ordersPerSymbol - Total resting orders per symbol
 * @param {number}   priceLevels     - Number of distinct price levels
 * @param {string}   [meUrl]         - Direct ME base URL (defaults to ME_SHARD_A_URL)
 * @returns {number} Total number of seed orders sent
 */
export function seedShardDirect(symbols, ordersPerSymbol, priceLevels, meUrl) {
    const baseUrl = meUrl || ME_SHARD_A_URL;
    const orders  = buildSeedOrders(symbols, ordersPerSymbol, priceLevels);
    const url     = `${baseUrl}/seed`;
    const payload = JSON.stringify({ orders: orders });
    const params  = { headers: JSON_HEADERS, timeout: SEED_TIMEOUT };

    const res = http.post(url, payload, params);

    const ok = check(res, {
        'seed direct status is 200': (r) => r.status === 200,
    });

    if (!ok) {
        console.error(`SEED FAILED (direct): status=${res.status}, body=${res.body}`);
    }

    console.log(
        `Seeded ME directly: ${orders.length} orders across ` +
        `${symbols.length} symbols, ${priceLevels} price levels`
    );

    return orders.length;
}

/**
 * Build the array of seed SELL orders for the given symbols.
 * Orders are evenly distributed across the specified number of price levels.
 *
 * @param {string[]} symbols         - Symbols to generate orders for
 * @param {number}   ordersPerSymbol - Total orders per symbol
 * @param {number}   priceLevels     - Number of price levels
 * @returns {Object[]} Array of seed order objects
 */
function buildSeedOrders(symbols, ordersPerSymbol, priceLevels) {
    const orders        = [];
    const ordersPerLevel = Math.ceil(ordersPerSymbol / priceLevels);

    for (const symbol of symbols) {
        for (let level = 1; level <= priceLevels; level++) {
            for (let i = 0; i < ordersPerLevel; i++) {
                orders.push(generateSeedSellOrder(symbol, level, i));
            }
        }
    }

    return orders;
}
