
E2Lib.RegisterExtension("coroutine", true)
print("Coroutine Init")

__e2setcost(0)
e2function void yield()

	coroutine.yield(true, "")

end