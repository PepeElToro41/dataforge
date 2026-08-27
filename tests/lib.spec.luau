--!strict

local testlib = require "./testlib"

-- Each spec returns its plan; this file runs them all at once.
local report = testlib.run(
	require "./scheduler.spec",
	require "./store.spec",
	require "./migrations.spec",
	require "./profile.spec",
	require "./lockless.spec",
	require "./peek.spec",
	require "./tx.spec",
	require "./chaining.spec"
)
testlib.report(report)

return nil
