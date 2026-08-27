---
layout: home

hero:
  name: DataForge
  text: Transactional DataStores for Roblox
  tagline: Cross-key, cross-store transactions, session-locked and lockless profiles, migrations and an immutable data model.
  actions:
    - theme: brand
      text: Get Started
      link: /guide/introduction
    - theme: alt
      text: API Reference
      link: /api/dataforge

features:
  - title: Transactions
    details: Update any set of keys across any stores atomically. Every key commits or none of them does, even if the server dies halfway through.
  - title: Locked & lockless profiles
    details: Session-locked profiles for per-player data, lockless profiles for keys shared by many servers. Both take part in transactions.
  - title: Immutable data
    details: Transforms return new values, data is deep-frozen, change detection is a reference comparison. No accidental mutation.
  - title: Migrations
    details: Named, ordered migrations run on load and are recorded on the record, so every key is upgraded exactly once.
  - title: Crash safe
    details: Session locks expire, dangling transactions resolve the same way from any server, and unknown outcomes are never overwritten.
  - title: Unit-testable
    details: Run the whole library outside Roblox with deterministic time and failure injection.
---
