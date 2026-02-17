# Diagrama de Despliegue - Oracle Cloud Infrastructure (OCI)
## Matching Engine - Arquitectura UML 2.5

**Costo Total Mensual: $0.00** (OCI Always Free Tier)

---

## 🏗️ Arquitectura de Despliegue

```
                              Internet
                                 │
                                 ▼
                   ┌─────────────────────────────┐
                   │  Internet Gateway (IGW)     │
                   │  Cost: $0.00                │
                   └─────────────┬───────────────┘
                                 │
    ┌────────────────────────────┴────────────────────────────┐
    │                                                          │
    │  VCN: matching-engine-vcn (10.0.0.0/16)                │
    │  Region: us-ashburn-1                                   │
    │                                                          │
    │  ┌─────────────────────────────────────────────────┐   │
    │  │  Public Subnet (10.0.0.0/24)                    │   │
    │  │                                                  │   │
    │  │  ┌──────────────────┐  ┌────────────────────┐  │   │
    │  │  │  bastion-host    │  │  Load Balancer     │  │   │
    │  │  │  ───────────     │  │  ──────────────    │  │   │
    │  │  │  Micro (x86)     │  │  Flexible 10 Mbps  │  │   │
    │  │  │  1 OCPU, 1 GB    │  │  Backend: :8080    │  │   │
    │  │  │  SSH jump host   │  │  Health: /health   │  │   │
    │  │  │  $0.00           │  │  $0.00             │  │   │
    │  │  └──────────────────┘  └──────────┬─────────┘  │   │
    │  └──────────────────────────────────┼─────────────┘   │
    │                                      │                 │
    │                                      │ HTTP :80        │
    │                                      ▼                 │
    │  ┌─────────────────────────────────────────────────┐   │
    │  │  Private Subnet (10.0.1.0/24)                   │   │
    │  │                                                  │   │
    │  │  ┌───────────┐  ┌───────────┐  ┌───────────┐   │   │
    │  │  │ me-shard-a│  │ me-shard-b│  │ me-shard-c│   │   │
    │  │  │ ───────── │  │ ───────── │  │ ───────── │   │   │
    │  │  │ A1.Flex   │  │ A1.Flex   │  │ A1.Flex   │   │   │
    │  │  │ 1O/6G ARM │  │ 1O/6G ARM │  │ 1O/6G ARM │   │   │
    │  │  │ :8080     │  │ :8080     │  │ :8080+    │   │   │
    │  │  │ A,B,C,D   │  │ E,F,G,H   │  │ I,J,K,L   │   │   │
    │  │  │ $0.00     │  │ $0.00     │  │ +Redpanda │   │   │
    │  │  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘   │   │
    │  │        └───────────────┼──────────────┘         │   │
    │  │                        │                        │   │
    │  │                        ▲                        │   │
    │  │                        │ Symbol routing         │   │
    │  │                        │ (hash-based)           │   │
    │  │                  ┌─────┴──────┐                 │   │
    │  │                  │edge-gateway│                 │   │
    │  │                  │ ──────────│                 │   │
    │  │                  │ A1.Flex    │                 │   │
    │  │                  │ 1O/6G ARM  │                 │   │
    │  │                  │ :8080      │                 │   │
    │  │                  │ +Prometheus│                 │   │
    │  │                  │ +Grafana   │                 │   │
    │  │                  │ +k6        │                 │   │
    │  │                  │ $0.00      │                 │   │
    │  │                  └────────────┘                 │   │
    │  │                                                  │   │
    │  │  ┌──────────────────┐                           │   │
    │  │  │  NAT Gateway     │ ────► Internet (egress)   │   │
    │  │  │  Cost: $0.00     │                           │   │
    │  │  └──────────────────┘                           │   │
    │  └──────────────────────────────────────────────────┘   │
    └──────────────────────────────────────────────────────────┘
```

---

## 📊 Recursos OCI - Resumen Detallado

### Instancias de Cómputo (5 total)

| Instancia | Shape | Specs | IP Privada | Propósito | Costo |
|:----------|:------|:------|:-----------|:----------|:------|
| **bastion-host** | VM.Standard.E2.1.Micro | 1 OCPU (x86), 1 GB RAM, 40 GB boot | 10.0.0.10 | SSH jump host para acceso seguro | $0.00 |
| **me-shard-a** | VM.Standard.A1.Flex | 1 OCPU (ARM64), 6 GB RAM, 30 GB boot | 10.0.1.20 | Matching Engine shard A (símbolos A-D) | $0.00 |
| **me-shard-b** | VM.Standard.A1.Flex | 1 OCPU (ARM64), 6 GB RAM, 30 GB boot | 10.0.1.21 | Matching Engine shard B (símbolos E-H) | $0.00 |
| **me-shard-c** | VM.Standard.A1.Flex | 1 OCPU (ARM64), 6 GB RAM, 30 GB boot | 10.0.1.22 | ME shard C (I-L) + Redpanda (Kafka) | $0.00 |
| **edge-and-tools** | VM.Standard.A1.Flex | 1 OCPU (ARM64), 6 GB RAM, 40 GB boot | 10.0.1.30 | Edge Gateway, Prometheus, Grafana, k6 | $0.00 |

**Total Cómputo:** 4 OCPUs ARM64 + 1 OCPU x86, 25 GB RAM
**Total Storage:** 170 GB boot volumes (30+30+30+40+40)
**Límites Always Free:** 4 OCPUs ARM (✓), 24 GB RAM (✓), 200 GB storage (✓)

### Componentes de Red

| Recurso | Tipo | Detalles | Costo |
|:--------|:-----|:---------|:------|
| **VCN** | Virtual Cloud Network | CIDR: 10.0.0.0/16, us-ashburn-1 | $0.00 |
| **Public Subnet** | Subnet | CIDR: 10.0.0.0/24, con IGW | $0.00 |
| **Private Subnet** | Subnet | CIDR: 10.0.1.0/24, con NAT | $0.00 |
| **Internet Gateway** | Gateway | Acceso público entrante/saliente | $0.00 |
| **NAT Gateway** | Gateway | Acceso solo saliente para subnet privada | $0.00 |
| **Load Balancer** | Flexible LB | 10 Mbps min/max, backend: edge-gateway:8080 | $0.00 |

---

## 🔧 Stack Tecnológico por Componente

### Matching Engine Shards (A, B, C)
```yaml
Artifact: matching-engine:experiment-v1
Base Image: eclipse-temurin:21-jre-alpine (ARM64)
Runtime: Java 21 con ZGC
Heap: -Xms256m -Xmx512m
Puerto HTTP: 8080
Puerto Métricas: 9091

Dependencias:
  - LMAX Disruptor 4.0.0 (ring buffer lock-free)
  - Kafka Client 3.7.0 (publicación asíncrona)
  - Prometheus Metrics 1.3.1
  - Gson 2.11.0 (JSON parsing)

Características:
  - Single-threaded matching (sin locks)
  - TreeMap-based Order Book (O(log n))
  - Memory-mapped WAL (64 MB)
  - Fire-and-publish HTTP (respuesta inmediata)
```

### Edge Gateway
```yaml
Artifact: edge-gateway:experiment-v1
Base Image: eclipse-temurin:21-jre-alpine (ARM64)
Runtime: Java 21
Puerto HTTP: 8080
Puerto Métricas: 9091

Función:
  - Symbol-hash routing a shards
  - Map: a=10.0.1.20:8080, b=10.0.1.21:8080, c=10.0.1.22:8080
  - Health check proxy
  - Seed endpoint proxy (/seed/{shardId})
```

### Redpanda (Message Broker)
```yaml
Artifact: redpanda:latest (ARM64 compatible)
Versión: v23.x
Puerto Kafka: 9092
Puerto Admin: 9644
Recursos: 1 GB RAM, 1 core, --smp=1

Topics:
  - orders (12 partitions)
  - matches (12 partitions)

Configuración:
  - Single-node cluster
  - Advertise: 10.0.1.22:9092
  - Kafka-compatible API
```

### Prometheus (Monitoring)
```yaml
Artifact: prom/prometheus:latest
Puerto: 9090
Scrape Interval: 5s

Targets:
  - me-shard-a:9091
  - me-shard-b:9091
  - me-shard-c:9091
  - edge-gateway:9091

Métricas Clave:
  - me_match_duration_seconds (histograma)
  - me_matches_total (counter)
  - me_orderbook_depth (gauge)
  - jvm_gc_collection_seconds
```

### Grafana (Dashboards)
```yaml
Artifact: grafana/grafana:latest
Puerto: 3000
Credenciales: admin / admin

Datasource: Prometheus (http://localhost:9090)

Dashboard: matching-engine-experiment
  - Panel 1: p99/p95/p50 latency (todas las shards)
  - Panel 2: Throughput (matches/min)
  - Panel 3: Order Book Depth
  - Panel 4: Error Rate
```

### k6 (Load Testing)
```yaml
Binario: k6 (Grafana Labs)
Arquitectura: ARM64
Ubicación: /usr/local/bin/k6

Tests:
  - ASR 1: Latency (p99 < 200ms @ 1,000 matches/min)
  - ASR 2: Scalability (>= 5,000 matches/min @ 3 shards)

Prometheus Remote Write:
  - URL: http://localhost:9090/api/v1/write
  - Métricas k6 → Prometheus para correlación
```

---

## 🔐 Modelo de Seguridad

### Security Lists

**Public Subnet Security List**
```
Ingress:
  - 0.0.0.0/0:80 (HTTP) → Load Balancer
  - <YOUR_IP>:22 (SSH) → Bastion host

Egress:
  - 0.0.0.0/0:all (unrestricted)
```

**Private Subnet Security List**
```
Ingress:
  - 10.0.0.0/24:22 (SSH desde bastion)
  - 10.0.1.0/24:8080 (HTTP interno entre shards)
  - 10.0.1.0/24:9090-9092 (Prometheus, Kafka)
  - 10.0.0.0/24:8080 (HTTP desde LB a edge-gateway)

Egress:
  - 0.0.0.0/0:all (vía NAT Gateway)
```

### Patrón de Acceso

```
Usuario → LB (IP pública) → Edge Gateway (privada) → ME Shards (privadas)
         ↓
    SSH → Bastion (IP pública) → Instancias privadas (jump host)
```

---

## 📈 Capacidad y Performance

### Latencia (ASR 1)
- **Objetivo:** p99 < 200ms en una sola shard
- **Capacidad:** 1,000 matches/min por shard
- **Validación:** Test stochastic con 20 runs normales + 20 agresivos

### Escalabilidad (ASR 2)
- **Objetivo:** >= 5,000 matches/min agregado (3 shards)
- **Capacidad Teórica:** 3 × 1,000 = 3,000 matches/min base
- **Pico Sostenido:** 5,040 orders/min (84 orders/sec)
- **Validación:** Tests B2 (peak sustained), B3 (ramp), B4 (hot symbol)

### Throughput por Componente
```
Load Balancer: 10 Mbps (suficiente para ~2,000 req/sec JSON pequeños)
Edge Gateway: ~5,000 req/sec (Java 21, async HTTP)
ME Shard: ~1,000 matches/sec (single-threaded, LMAX Disruptor)
Redpanda: ~10,000 msg/sec (Kafka-compatible, single-node)
```

---

## 💰 Análisis de Costos

### Always Free Tier - OCI

| Recurso | Cantidad | Límite Free | Usado | Estado |
|:--------|:---------|:------------|:------|:-------|
| ARM Compute (OCPU) | 4 | 4 | 4 | ✓ 100% |
| ARM Memory (GB) | 24 | 24 | 24 | ✓ 100% |
| x86 Micro (OCPU) | 1 | 2 | 1 | ✓ 50% |
| Boot Volumes (GB) | 170 | 200 | 170 | ✓ 85% |
| Load Balancer | 1 (10 Mbps) | 1 (10 Mbps) | 1 | ✓ 100% |
| VCN | 2 | 2 | 2 | ✓ 100% |
| Public IP | 2 (reserved) | 2 | 2 | ✓ 100% |
| Outbound Data | Variable | 10 TB/month | <1 GB | ✓ <1% |

**Costo Mensual:** $0.00
**Costo Anual:** $0.00

### Comparación con AWS (estimado)

Si se desplegara en AWS con instancias equivalentes:

| Componente | AWS Instancia | Costo/hora | Costo/mes (730h) |
|:-----------|:--------------|:-----------|:-----------------|
| 3× ME Shards | 3× c7g.medium | 3 × $0.0361 | $79.14 |
| Edge + Tools | 1× c7g.large | 1 × $0.0722 | $52.71 |
| Redpanda | (incluido en shard C) | — | — |
| Load Balancer | NLB | $0.0225/hora + LCU | ~$25.00 |
| **Total AWS** | | | **~$156.85/mes** |

**Ahorro con OCI Always Free:** $156.85/mes × 12 = **$1,882.20/año**

---

## 🚀 Flujo de Despliegue

### Scripts de Despliegue (infra/cloud/oci/)

```bash
# 1. Verificar prerrequisitos
./00-prerequisites.sh
# ✓ OCI CLI configurado
# ✓ Imágenes ARM64/x86 resueltas
# ✓ SSH key pair generado

# 2. Crear VCN y redes
./01-create-network.sh
# ✓ VCN: 10.0.0.0/16
# ✓ Subnets: pública (10.0.0.0/24), privada (10.0.1.0/24)
# ✓ IGW, NAT, route tables, security lists

# 3. Lanzar instancias
./02-launch-instances.sh
# ✓ 5 instancias: bastion + 4× A1.Flex
# ✓ IPs privadas: .20, .21, .22, .30
# ✓ Bastion IP pública dinámica

# 4. Instalar software
./03-setup-software.sh
# ✓ Docker en todas las instancias privadas
# ✓ Java 21 (OpenJDK ARM64)
# ✓ k6, rpk (Redpanda CLI)

# 5. Desplegar aplicaciones
./04-deploy-me.sh
# ✓ Build ARM64 images localmente
# ✓ Transfer vía SCP + bastion
# ✓ Deploy: Redpanda → ME shards → Edge → Prom → Grafana

# 6. Crear Load Balancer
./05-create-load-balancer.sh
# ✓ Flexible LB (10 Mbps)
# ✓ Backend: edge-and-tools:8080
# ✓ Health check: /health

# 7. Ejecutar tests
./06-run-tests.sh asr1  # o asr2, o all
# ✓ k6 tests con métricas a Prometheus
# ✓ Resultados: pass/fail vs thresholds

# 8. Cleanup
./99-teardown.sh
# ✓ Reverse-order deletion
# ✓ State file cleanup
```

**Tiempo Total de Despliegue:** ~15-20 minutos
**Tiempo Total de Tests:** ~67 minutos (ASR 1 + ASR 2)

---

## 📋 Estereotipos UML Utilizados

### UML 2.5 Deployment Diagram Stereotypes

- **«compute»**: Nodos de cómputo (instancias EC2/OCI)
- **«artifact»**: Imágenes Docker, binarios
- **«gateway»**: Internet Gateway, NAT Gateway
- **«loadBalancer»**: OCI Flexible Load Balancer
- **«database»**: Redpanda (message broker)
- **«monitoring»**: Prometheus, Grafana

### Relaciones
- **─────** : Dependencia (deployment)
- **- - - -** : Comunicación (HTTP, SSH)
- **═════** : Asociación fuerte (colocación)

---

## 🔍 Puntos Clave de la Arquitectura

1. **100% Serverless en OCI Always Free Tier**
   - No hay costos operativos mensuales
   - Límites generosos (4 OCPUs ARM64, 24 GB RAM)

2. **Arquitectura ARM64-first**
   - Todas las aplicaciones en ARM64 (Ampere A1)
   - Eclipse Temurin 21 con soporte multi-arch nativo

3. **Seguridad por Capas**
   - Subnet privada para toda la aplicación
   - Bastion jump host para acceso SSH
   - Load Balancer como único punto de entrada HTTP

4. **Alta Disponibilidad Simulada**
   - 3 shards independientes (fault isolation)
   - Symbol-based sharding (A-D, E-H, I-L)
   - Edge Gateway con health checks

5. **Observabilidad Completa**
   - Prometheus: métricas time-series
   - Grafana: dashboards visuales
   - k6: synthetic load testing con métricas a Prometheus

6. **Despliegue Automatizado**
   - Scripts idempotentes (safe para re-run)
   - State management (OCIDs persisted)
   - Teardown completo en orden inverso

---

## 📄 Referencias

- **Documentación Completa:** `docs/experiment-cloud-oci.md`
- **Diagrama Draw.io:** `docs/oci-deployment-diagram.drawio`
- **Scripts de Despliegue:** `infra/cloud/oci/`
- **Guía ASR Unificada:** `docs/UNIFIED_ASR_TESTING.md`

---

**Creado:** 2026-02-15
**Versión:** 1.0
**Arquitecto:** Matching Engine Team
**Plataforma:** Oracle Cloud Infrastructure (OCI)
