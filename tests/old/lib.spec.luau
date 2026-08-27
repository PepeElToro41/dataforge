--!strict

-- Each spec runs and reports itself; this file just runs them all.
require "./scheduler.spec"
require "./store.spec"
require "./lock.spec"
require "./tx.spec"
require "./lockless.spec"
