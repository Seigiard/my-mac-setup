---
title: "Replace child ask/reply with a sandbox-safe mailbox"
short_description: "A host-owned durable broker must let sandboxed parent and child agents exchange typed, authorized messages and wake recipients without exposing Herdr control; the policy prototype is preserved on branch `prototype-logic-2026-08-18`."
type: "idea"
category: "agent-platform"
tags: ["agent-platform","agent-mailbox","sandbox"]
date: "2026-09-12"
status: "open"
priority: "high"
---

## Why this exists

The current `herdr-child ask/reply` path lets a child invoke host-side Herdr control directly. A sandbox that preserves that access keeps a broad escape path, while removing it breaks the mandatory return channel. ADR-0013 selects a host-owned mailbox broker as the target communication boundary.

## Scope

Replace only the current parent-child ask/reply flow. Persist each message before delivery, wake an idle recipient through a host-side Herdr adapter, authenticate both agents from their launch relationship, and enforce typed role-based message authority. Keep direct ask/reply until parity is proved, then remove it. Peer-to-peer messaging, file reservations, attachments, cross-project delivery, task orchestration, and selection of a sandbox runtime are outside this first slice.

## Open decisions

Choose whether the first backend is a narrow repository-owned broker or an adapter over an existing MCP mailbox; define acknowledgement, retry, deduplication, retention, and cleanup behavior; prove that a sandbox can reach only the mailbox capability while the host adapter alone can reach Herdr.
