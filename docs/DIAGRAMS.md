# Component Diagrams

## 1. System Architecture (High Level)

A high-level view showing how user requests flow through the Edge Gateway to the Sharded Matching Engine cluster, and how data flows to downstream systems (Redpanda/Kafka) and observability tools (Prometheus/Grafana).

```mermaid
graph TD
    %% Actors
    User([User / k6 Load Generator])
    
    %% Infrastructure Boundary
    subgraph "Kubernetes Cluster (k3d)"
        
        %% Edge Layer
        subgraph "Edge Layer"
            Gateway[Edge Gateway]
        end
        
        %% Matching Engine Core
        subgraph "Matching Engine Cluster"
            ShardA["ME Shard A\n(Symbols: A-D)"]
            ShardB["ME Shard B\n(Symbols: E-H)"]
            ShardC["ME Shard C\n(Symbols: I-L)"]
        end
        
        %% Messaging & Persistence layer
        subgraph "Messaging & Persistence"
            RP[(Redpanda / Kafka)]
        end
        
        %% Observability Layer
        subgraph "Observability Stack"
            Prom[(Prometheus)]
            Graf[Grafana]
        end
    end

    %% Data Flow
    User -->|HTTP POST /orders| Gateway
    Gateway -->|Route by Symbol| ShardA
    Gateway -->|Route by Symbol| ShardB
    Gateway -->|Route by Symbol| ShardC
    
    ShardA -->|Publish Match Events| RP
    ShardB -->|Publish Match Events| RP
    ShardC -->|Publish Match Events| RP
    
    %% Monitoring Flow
    Prom -.->|Scrape /metrics| Gateway
    Prom -.->|Scrape /metrics| ShardA
    Prom -.->|Scrape /metrics| ShardB
    Prom -.->|Scrape /metrics| ShardC
    
    Graf -.->|Query PromQL| Prom
    User -.->|View Dashboards| Graf

    %% Styling
    classDef cluster fill:#f9f9f9,stroke:#333,stroke-width:2px;
    classDef actor fill:#e1f5fe,stroke:#01579b,stroke-width:2px;
    classDef component fill:#fff3e0,stroke:#ff6f00,stroke-width:2px;
    classDef bus fill:#f3e5f5,stroke:#4a148c,stroke-width:2px;
    
    class User,Graf actor;
    class Gateway,ShardA,ShardB,ShardC component;
    class RP,Prom bus;
```

## 2. Matching Engine Internals (Component Level)

A detailed view of a single Matching Engine instance, highlighting the LMAX Disruptor pattern and the single-threaded event processing pipeline.

```mermaid
graph LR
    %% External Inputs
    HTTP_REQ["HTTP Request\n(POST /orders)"]
    
    subgraph "Matching Engine (Global Context)"
        
        %% Input Layer
        subgraph "Input Layer"
            HttpHandler[OrderHttpHandler]
            Translator[OrderEventTranslator]
        end
        
        %% The Core Ring Buffer
        RingBuffer[("LMAX Disruptor\nRing Buffer (131k slots)")]
        
        %% Single Threaded Core
        subgraph "Single-Threaded Event Processor"
            direction TB
            EventHandler[OrderEventHandler]
            
            %% Core Components used by Handler
            subgraph "Domain Logic"
                subgraph "Data Structures"
                    OrderBook["OrderBook\n(TreeMap)"]
                    PriceLevels["PriceLevels\n(ArrayDeque)"]
                end
                Matcher[PriceTimePriorityMatcher]
            end
            
            subgraph "I/O Components"
                WAL["WriteAheadLog\n(MappedByteBuffer)"]
                Publisher["EventPublisher\n(Kafka Producer)"]
                Metrics[MetricsRegistry]
            end
        end
    end
    
    %% External Outputs
    HTTP_RES[HTTP 200 Accepted]
    Disk[("Disk Storage\n/tmp/wal")]
    Kafka[(Redpanda / Kafka)]
    
    %% Flow
    HTTP_REQ --> HttpHandler
    HttpHandler -->|1. Translate| Translator
    Translator -->|2. Publish Sequence| RingBuffer
    HttpHandler -.->|Return immediately| HTTP_RES
    
    %% Event Processing Flow
    RingBuffer -->|"3. OnEvent()"| EventHandler
    
    EventHandler -->|4. Validate| OrderBook
    EventHandler -->|5. Match| Matcher
    Matcher <--> |Read/Write| OrderBook
    OrderBook <--> |Queue| PriceLevels
    
    EventHandler -->|6. Append| WAL
    WAL -->|Flush EndOfBatch| Disk
    
    EventHandler -->|7. Publish| Publisher
    Publisher -.->|Async Send| Kafka
    
    EventHandler -->|8. Record| Metrics

    %% Styling
    classDef buffer fill:#e8f5e9,stroke:#1b5e20,stroke-width:4px;
    classDef core fill:#fff3e0,stroke:#e65100,stroke-width:2px;
    classDef io fill:#f3e5f5,stroke:#4a148c,stroke-width:2px;
    
    class RingBuffer buffer;
    class EventHandler,Matcher,OrderBook,PriceLevels core;
    class WAL,Publisher,Metrics io;
```
