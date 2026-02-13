FROM eclipse-temurin:21-jre-alpine AS runtime
WORKDIR /app
COPY build/libs/edge-gateway*.jar edge-gateway.jar

ENV HTTP_PORT=8080
ENV METRICS_PORT=9091
ENV ME_SHARD_MAP=a=http://me-shard-a:8080,b=http://me-shard-b:8080,c=http://me-shard-c:8080
ENV SHARD_SYMBOLS_MAP=a=TEST-ASSET-A:TEST-ASSET-B:TEST-ASSET-C:TEST-ASSET-D,b=TEST-ASSET-E:TEST-ASSET-F:TEST-ASSET-G:TEST-ASSET-H,c=TEST-ASSET-I:TEST-ASSET-J:TEST-ASSET-K:TEST-ASSET-L

EXPOSE 8080 9091

ENTRYPOINT ["java", \
  "-Xms128m", \
  "-Xmx256m", \
  "-jar", "edge-gateway.jar"]
