plugins {
    java
    application
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(21))
    }
}

application {
    mainClass.set("com.matchingengine.MatchingEngineApp")
}

repositories {
    mavenCentral()
}

dependencies {
    // LMAX Disruptor
    implementation("com.lmax:disruptor:4.0.0")

    // Kafka client
    implementation("org.apache.kafka:kafka-clients:3.7.0")

    // Prometheus metrics
    implementation("io.prometheus:prometheus-metrics-core:1.3.1")
    implementation("io.prometheus:prometheus-metrics-exporter-httpserver:1.3.1")
    implementation("io.prometheus:prometheus-metrics-instrumentation-jvm:1.3.1")

    // JSON
    implementation("com.google.code.gson:gson:2.11.0")

    // SLF4J + simple logger
    implementation("org.slf4j:slf4j-api:2.0.12")
    implementation("org.slf4j:slf4j-simple:2.0.12")
}

tasks.jar {
    manifest {
        attributes["Main-Class"] = "com.matchingengine.MatchingEngineApp"
    }
    // Create fat JAR
    from(configurations.runtimeClasspath.get().map { if (it.isDirectory) it else zipTree(it) })
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
}
