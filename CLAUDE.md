# Project Context: Matching Engine

## 1. Overview and Objective
The primary goal of this project is to design a software architecture for a **Matching Engine (ME)** and implement architectural experiments to validate design hypotheses. The system acts as a third-party intermediary (exchange) that manages the trading of assets between buyers and sellers by maintaining a centralized **Order Book**.

## 2. Core Business Processes
* **Sell Offer Registration:** Owners submit sale conditions. The system records these in the Order Book and triggers notifications.
* **Buy Offer Registration:** Buyers submit asset requirements and conditions. The system records these intentions in the Order Book.
* **Matching Process:** The engine scans Order Books to pair buy and sell orders based on business rules. This can be reactive (per order) or proactive (periodic).
* **Information Delivery:** A subscription-based service that broadcasts Order Book events to stakeholders.
* **Analytics:** A value-added service providing insights based on historical transaction data.

## 3. Quality Attributes and Constraints (ASRs)
The architecture is driven by high-performance requirements, specifically focusing on **Latency** and **Scalability**.

### 3.1 Latency Requirements
| Operation | Target Latency |
| :--- | :--- |
| Sell offer registration & availability | < 0.5 seconds |
| Buy offer registration & availability | < 0.3 seconds |
| Matching execution & transaction completion | < 200 milliseconds |

### 3.2 Scalability and Load Profiles
* **Normal Throughput:** 500 sell orders/min and 800 buy orders/min.
* **Standard Matching Capacity:** 1,000 matches per minute.
* **Peak Demand:** The system must scale to handle **5,000 matches per minute** for bursts of up to 30 minutes.

## 4. Revenue Models & Functional Constraints
The architecture must support the following monetization strategies:
1.  **Transaction Fees:** Commissions on successful trades.
2.  **Premium Tier:** Near-real-time data delivery (Critical path: Low latency).
3.  **Basic Tier:** Delayed data delivery (Non-critical path: Throughput oriented).
4.  **Data Monetization:** Analytical services via historical data access.

---

## 5. Architectural Guidance for AI Agents
When designing the solution, prioritize:
* **Decoupling:** Use asynchronous patterns (e.g., Event Sourcing or Pub/Sub) to ensure the Notification and Analytics services do not increase the latency of the core Matching Engine.
* **In-Memory Processing:** Consider in-memory data structures for the Order Book to meet the < 200ms requirement.
* **Elasticity:** Ensure the Matching Engine can scale horizontally or vertically to handle the 5x increase during peak periods.