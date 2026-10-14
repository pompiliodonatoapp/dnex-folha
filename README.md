# DNEX Folha — Sistema de Folha de Pagamento para Escritórios de Contabilidade

Produto independente do ecossistema DNEX, voltado para escritórios de contabilidade que precisam de folha de pagamento nativa com eSocial, cálculos trabalhistas completos e contabilização automática.

## O que é

O DNEX Folha é um **produto standalone** que pode ser contratado separadamente do DNEX Gestão. Ele oferece:

- **Motor de cálculo PL/pgSQL** nativo no PostgreSQL (IRRF, INSS, FGTS, férias, 13º, rescisão)
- **eSocial nativo** (S-1200 remuneração, S-2200 admissão) sem dependência de integrações externas
- **Contabilização automática** com lançamento débito/crédito via outbox pattern
- **Multi-tenant** com RLS (Row Level Security) por account_id
- **Dashboard operacional** com KPIs, gráficos e fallback via RPC `folha.dashboard_completo`
- **Conformidade Lei 15.270/2025** (nova tabela IRRF)

## Arquitetura

```
Schema: folha (isolado no Supabase)
├── 16 tabelas (employee, payroll_run, payroll_result, accounting_outbox, esocial_event_outbox, ...)
├── 21 funções PL/pgSQL (calc_irrf, calc_inss, calc_fgts, calc_ferias, calc_13o, calc_rescisao, ...)
├── RLS por account_id (multi-tenant)
└── Outbox pattern para eSocial e contabilização
```

## Migrations

| # | Arquivo | Descrição |
|---|---------|-----------|
| 0014 | `folha_foundation` | Schema + RLS + roles + isolamento multi-tenant |
| 0015 | `folha_tax_tables_seed_2026` | Tabelas IRRF/INSS 2026 (Lei 15.270/2025) |
| 0016 | `folha_calculation_engine` | Motor de cálculo PL/pgSQL |
| 0017 | `folha_rubricas_core_seed` | 40 rubricas core (proventos + descontos) |
| 0018 | `folha_integrations` | Outbox eSocial + contabilização |
| 0019 | `folha_eventos_vida` | Eventos de vida (admissão, férias, 13º, rescisão) |
| 0020 | `folha_esocial_contabil` | build_esocial_s1200/s2200 + build_contabil_folha |
| 0021 | `folha_dashboard_rpc` | RPC dashboard_completo para UI |

## Testes

- **pgTAP**: isolamento RLS, golden cases de cálculo, eventos de vida, dashboard RPC
- **Python**: runner de testes de eventos de vida

## Integração com DNEX Gestão

O DNEX Folha comunica-se com o DNEX Gestão via:
- **Contrato de integração**: `gestao.folha-handoff.v1` (eventos de contabilização)
- **Schema compartilhado**: nenhum — o schema `folha` é 100% isolado
- **Autenticação**: via `gestao_auth` do DNEX Gestão (token JWT com claim `account_id`)

## Licença

Proprietário — DNEX / Pompilio Donato.