package com.matchingengine.publishing;

import com.google.gson.Gson;
import com.google.gson.JsonObject;
import com.matchingengine.domain.MatchResult;
import com.matchingengine.domain.Order;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.serialization.StringSerializer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Properties;

/**
 * Async Kafka producer wrapper for publishing match and order events.
 *
 * Critical constraint: max.block.ms=1 ensures the Kafka producer never blocks
 * the matching thread. If the broker is unreachable or the buffer is full,
 * send() returns immediately (or throws), and errors are logged but never
 * propagated to the matching logic.
 */
public class EventPublisher {

    private static final Logger logger = LoggerFactory.getLogger(EventPublisher.class);
    private static final String MATCHES_TOPIC = "matches";
    private static final String ORDERS_TOPIC = "orders";

    private final KafkaProducer<String, String> producer;
    private final Gson gson;

    public EventPublisher(String kafkaBootstrap) {
        this.gson = new Gson();

        Properties props = new Properties();
        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, kafkaBootstrap);
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        props.put(ProducerConfig.ACKS_CONFIG, "0");                  // fire-and-forget
        props.put(ProducerConfig.LINGER_MS_CONFIG, "5");             // batch for 5ms
        props.put(ProducerConfig.BATCH_SIZE_CONFIG, "16384");        // 16 KB batch
        props.put(ProducerConfig.BUFFER_MEMORY_CONFIG, "33554432");  // 32 MB buffer
        props.put(ProducerConfig.MAX_BLOCK_MS_CONFIG, "1");          // NEVER block matching thread

        KafkaProducer<String, String> p = null;
        try {
            p = new KafkaProducer<>(props);
            logger.info("Kafka producer initialized. Bootstrap: {}", kafkaBootstrap);
        } catch (Exception e) {
            logger.error("Failed to initialize Kafka producer: {}. "
                    + "Events will not be published.", e.getMessage());
        }
        this.producer = p;
    }

    /**
     * Publish a match result to the "matches" topic.
     * Non-blocking: KafkaProducer.send() returns immediately.
     * Errors are logged but never propagated.
     */
    public void publishMatch(MatchResult result) {
        if (producer == null) {
            return;
        }
        try {
            JsonObject json = new JsonObject();
            json.addProperty("type", "MATCH_EXECUTED");
            json.addProperty("matchId", result.getMatchId());
            json.addProperty("takerOrderId", result.getTakerOrderId());
            json.addProperty("makerOrderId", result.getMakerOrderId());
            json.addProperty("symbol", result.getSymbol());
            json.addProperty("executionPrice", result.getExecutionPrice());
            json.addProperty("executionQuantity", result.getExecutionQuantity());
            json.addProperty("takerSide", result.getTakerSide().name());
            json.addProperty("timestamp", result.getTimestamp());

            String value = gson.toJson(json);
            ProducerRecord<String, String> record =
                    new ProducerRecord<>(MATCHES_TOPIC, result.getSymbol(), value);
            producer.send(record, (metadata, exception) -> {
                if (exception != null) {
                    logger.warn("Failed to publish match event: {}", exception.getMessage());
                }
            });
        } catch (Exception e) {
            logger.warn("Error publishing match event: {}", e.getMessage());
        }
    }

    /**
     * Publish an order-placed event to the "orders" topic.
     * Non-blocking: errors are logged but never propagated.
     */
    public void publishOrderPlaced(Order order) {
        if (producer == null) {
            return;
        }
        try {
            JsonObject json = new JsonObject();
            json.addProperty("type", "ORDER_PLACED");
            json.addProperty("orderId", order.getId().value());
            json.addProperty("symbol", order.getSymbol());
            json.addProperty("side", order.getSide().name());
            json.addProperty("price", order.getLimitPrice().cents());
            json.addProperty("quantity", order.getOriginalQuantity());
            json.addProperty("timestamp", System.currentTimeMillis());

            String value = gson.toJson(json);
            ProducerRecord<String, String> record =
                    new ProducerRecord<>(ORDERS_TOPIC, order.getSymbol(), value);
            producer.send(record, (metadata, exception) -> {
                if (exception != null) {
                    logger.warn("Failed to publish order event: {}", exception.getMessage());
                }
            });
        } catch (Exception e) {
            logger.warn("Error publishing order event: {}", e.getMessage());
        }
    }

    /**
     * Flush and close the Kafka producer.
     */
    public void close() {
        if (producer != null) {
            try {
                producer.flush();
                producer.close();
                logger.info("Kafka producer closed.");
            } catch (Exception e) {
                logger.warn("Error closing Kafka producer: {}", e.getMessage());
            }
        }
    }
}
