---
title: Background interactions upstream delta
authority: draft
status: comparative-draft
baseline: 558518f8d78a44198cd428f6bf8bf48bfa38d76d
latest_upstream: 2b959b2bf5fdb13e3b333c078ba549996e477b7c
---

## Source diff

Latest-upstream changes background callbacks/init, adds builtin `tools_judge`, replaces chat wait handling, adds `chat/tools/runtime/queue.lua` and `utils/queue.lua`, and updates background/tool queue tests and stubs.

## Observable behavior delta

Background work now appears to have explicit queue primitives and a judge interaction for tool outcomes. Callback scheduling, waiting, ordering, and error propagation can therefore differ, especially when multiple tool/background jobs overlap.

## Compatibility impact

High for asynchronous integrations and custom callbacks; queue ordering and cancellation are externally observable. Synchronous/simple background use is likely lower risk but not established.

## Validation and unknowns

Reviewed source diff/stat and changed test/stub paths. Not run: concurrency, cancellation, duplicate callback, timeout, and failure propagation tests. Unknown: queue fairness, reentrancy, and whether old wait APIs remain as compatibility shims.
