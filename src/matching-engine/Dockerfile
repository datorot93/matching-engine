FROM eclipse-temurin:21-jre-alpine AS runtime
WORKDIR /app
COPY build/libs/matching-engine.jar matching-engine.jar
RUN mkdir -p /app/wal

ENV SHARD_ID=a
ENV SHARD_SYMBOLS=TEST-ASSET-A,TEST-ASSET-B,TEST-ASSET-C,TEST-ASSET-D
ENV HTTP_PORT=8080
ENV METRICS_PORT=9091
ENV KAFKA_BOOTSTRAP=redpanda:9092
ENV WAL_PATH=/app/wal
ENV WAL_SIZE_MB=64
ENV ENABLE_DETAILED_LOGGING=false

EXPOSE 8080 9091

ENTRYPOINT ["java", \
  "-XX:+UseZGC", \
  "-Xms256m", \
  "-Xmx512m", \
  "-XX:+AlwaysPreTouch", \
  "-jar", "matching-engine.jar"]
