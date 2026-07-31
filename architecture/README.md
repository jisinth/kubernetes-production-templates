# Architecture diagrams

This folder is the intended home for visual diagram assets — `production-cluster.drawio`/`.png`, `monitoring.png`, `networking.png`. Those are binary/editable diagram files and aren't something that can be authored as part of this pass; generate them with draw.io (or export from the Mermaid sources below) and drop them here as follow-up work.

In the meantime, the same three diagrams are provided inline as Mermaid, which renders directly on GitHub and stays diffable in Git.

## Overall production cluster architecture

```mermaid
flowchart TB
    subgraph external["External"]
        Client["Client / Browser"]
        DNSProvider["Cloud DNS\n(Route53 / Azure DNS / Cloud DNS)"]
    end

    subgraph cluster["Kubernetes Cluster"]
        LB["Cloud LoadBalancer\n(Service: ingress-nginx)"]
        Ingress["ingress-nginx controller"]
        CertMgr["cert-manager\n(ClusterIssuer + Certificates)"]
        ExtDNS["external-dns"]

        subgraph apps["Application namespaces"]
            SvcA["Service: nginx / nodejs / python"]
            SvcB["Service: springboot / flask"]
            PodA["Pods"]
            PodB["Pods"]
        end

        subgraph mon["monitoring namespace"]
            Prom["Prometheus"]
            Graf["Grafana"]
            LokiC["Loki"]
            TempoC["Tempo"]
            AlertM["Alertmanager"]
        end

        subgraph gitops["argocd namespace"]
            ArgoCD["ArgoCD"]
        end

        subgraph sec["security controllers"]
            Kyverno["Kyverno"]
            NetPol["NetworkPolicies"]
            SealedS["Sealed Secrets controller"]
        end
    end

    subgraph git["Git repository (this repo)"]
        Manifests["manifests/ + helm-values/"]
    end

    Client -->|HTTPS| LB --> Ingress
    Ingress --> SvcA --> PodA
    Ingress --> SvcB --> PodB
    CertMgr -. issues TLS certs .-> Ingress
    ExtDNS -->|manages records| DNSProvider
    ExtDNS -. watches Ingress/Service .-> Ingress

    Prom -->|scrapes /metrics| PodA
    Prom -->|scrapes /metrics| PodB
    Prom --> AlertM
    Graf -->|queries| Prom
    Graf -->|queries| LokiC
    Graf -->|queries| TempoC
    PodA -. logs/traces .-> LokiC
    PodA -. logs/traces .-> TempoC

    ArgoCD -->|sync| Manifests
    ArgoCD -->|reconciles| apps
    ArgoCD -->|reconciles| mon
    ArgoCD -->|reconciles| sec

    Kyverno -. admission control .-> apps
    NetPol -. traffic rules .-> apps
    SealedS -. decrypts .-> apps
```

## Monitoring data flow

```mermaid
flowchart LR
    subgraph workloads["Application pods"]
        App["App container\n(/metrics, stdout logs, OTLP traces)"]
    end

    Prom["Prometheus\n(scrape + TSDB + rules)"]
    Promtail["Log shipper\n(Promtail / Grafana Agent DaemonSet)"]
    LokiC["Loki"]
    TempoC["Tempo"]
    AlertM["Alertmanager"]
    Graf["Grafana"]
    OnCall["Slack / PagerDuty / Email"]

    App -->|"scrape /metrics"| Prom
    App -->|"stdout/stderr"| Promtail --> LokiC
    App -->|"OTLP spans"| TempoC

    Prom -->|"PrometheusRule alerts"| AlertM
    AlertM -->|"grouped, routed notifications"| OnCall

    Graf -->|"PromQL"| Prom
    Graf -->|"LogQL"| LokiC
    Graf -->|"TraceQL"| TempoC
    Graf -. "trace-to-log / trace-to-metric correlation" .-> LokiC
    Graf -. correlation .-> Prom
```

## Networking

```mermaid
flowchart TB
    Client["Client"]
    DNSProvider["Cloud DNS zone"]

    subgraph cluster["Cluster networking"]
        LB["Cloud LoadBalancer"]
        IngressC["ingress-nginx controller"]
        ExtDNS["external-dns"]
        CertMgr["cert-manager"]

        subgraph netpol["NetworkPolicy enforcement (CNI)"]
            direction TB
            DenyAll["Default-deny-all\n(per namespace)"]
            AllowIngress["Allow: ingress-nginx -> app pods"]
            AllowDNS["Allow: app pods -> kube-dns (53/UDP,TCP)"]
            AllowMon["Allow: monitoring -> app pods (scrape)"]
            AllowEgress["Allow: app pods -> declared dependencies"]
        end

        AppPod["Application pod"]
    end

    Client -->|"DNS lookup"| DNSProvider
    ExtDNS -->|"creates/updates A/CNAME"| DNSProvider
    Client -->|HTTPS| LB --> IngressC
    CertMgr -. "TLS cert for Ingress host" .-> IngressC
    IngressC -->|"allowed by AllowIngress"| AppPod
    AppPod -->|"allowed by AllowDNS"| kubeDNS["kube-dns / CoreDNS"]
    AppPod -->|"allowed by AllowEgress"| Dependency["DB / cache / external API"]

    DenyAll -. baseline .-> AppPod
    AllowIngress --> AppPod
    AllowDNS --> AppPod
    AllowMon --> AppPod
    AllowEgress --> AppPod
```

## Regenerating the binary assets

Once `production-cluster.drawio`, `monitoring.png`, and `networking.png` are produced (e.g. via draw.io, Mermaid CLI, or Excalidraw), place them in this folder alongside this README and link them in from `docs/architecture.md` and `docs/monitoring.md` as the canonical diagrams. Keep the Mermaid sources above in sync with any changes so the text-diffable version doesn't drift from the images.
