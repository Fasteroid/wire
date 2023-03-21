--[[
	Expression 2 Compiler for Garry's Mod
		by Vurv

	todo:
		- [x] reimplement prf counter
		- [x] reimplement all verification
		- [] optimizing step
		- [x] make break and continue work
		- [x] make return work
		- [] reimplement all warnings
			- [] unused variables
]]

AddCSLuaFile()

local Trace, Warning, Error = E2Lib.Debug.Trace, E2Lib.Debug.Warning, E2Lib.Debug.Error
local Token, TokenVariant = E2Lib.Tokenizer.Token, E2Lib.Tokenizer.Variant
local Node, NodeVariant = E2Lib.Parser.Node, E2Lib.Parser.Variant
local Keyword, Grammar, Operator = E2Lib.Keyword, E2Lib.Grammar, E2Lib.Operator

local TickQuota = GetConVar("wire_expression2_quotatick"):GetInt()

cvars.RemoveChangeCallback("wire_expression2_quotatick", "compiler_quota_check")
cvars.AddChangeCallback("wire_expression2_quotatick", function(_, old, new)
	TickQuota = tonumber(new)
end, "compiler_quota_check")

---@class ScopeData
---@field dead boolean?
---@field loop boolean?
---@field switch_case boolean?
---@field function { [1]: string, [2]: EnvFunction}?
---@field ops integer

---@alias VarData { type: string, trace_if_unused: Trace?, initialized: boolean, scope: Scope }

---@class Scope
---@field parent Scope?
---@field data ScopeData
---@field vars table<string, VarData>
local Scope = {}
Scope.__index = Scope

---@param parent Scope?
function Scope.new(parent)
	return setmetatable({ data = { ops = 0 }, vars = {}, parent = parent }, Scope)
end

function Scope:Depth()
	return self.parent and (1 + self.parent:Depth()) or 0
end

---@param name string
---@param data VarData
function Scope:DeclVar(name, data)
	data.scope = self
	self.vars[name] = data
end

function Scope:IsGlobalScope()
	return self.parent == nil
end

---@param name string
---@return VarData?
function Scope:LookupVar(name)
	return self.vars[name] or (self.parent and self.parent:LookupVar(name))
end

---@param field string
function Scope:ResolveData(field)
	return self.data[field] or (self.parent and self.parent:ResolveData(field))
end

---@class Compiler
--- Base Data
---@field warnings table<number|string, Warning> # Array of warnings (main file) with keys to included file warnings.
---@field global_scope Scope
---@field scope Scope
--- Below is analyzed data
---@field include string? # Current include file or nil if main file
---@field registered_events table<string, function>
---@field user_functions table<string, table<string, EnvFunction>> # applyForce -> v
---@field user_methods table<string, table<string, table<string, EnvFunction>>> # e: -> applyForce -> vava
--- External Data
---@field includes table<string, Node>
---@field delta_vars table<string, true> # Variable: True
---@field persist table<string, string> # Variable: Type
---@field inputs table<string, string> # Variable: Type
---@field outputs table<string, string> # Variable: Type
local Compiler = {}
Compiler.__index = Compiler

E2Lib.Compiler = Compiler

function Compiler.new()
	local global_scope = Scope.new()
	return setmetatable({
		global_scope = global_scope, scope = global_scope, warnings = {}, registered_events = {},
		user_functions = {}, user_methods = {}, delta_vars = {}
	}, Compiler)
end

---@param directives PPDirectives
---@param dvars table<string, true>?
---@param includes table<string, Node>?
function Compiler.from(directives, dvars, includes)
	local global_scope = Scope.new()
	return setmetatable({
		persist = directives.persist[3], inputs = directives.inputs[3], outputs = directives.outputs[3],
		global_scope = global_scope, scope = global_scope, warnings = {}, registered_events = {}, user_functions = {}, user_methods = {},
		delta_vars = dvars or {}, includes = includes or {}
	}, Compiler)
end

local BLOCKED_ARRAY_TYPES = E2Lib.blocked_array_types

---@param ast Node
---@param directives PPDirectives
---@param dvars table<string, boolean>
---@param includes table<string, Node>
---@return boolean ok, function|Error script, Compiler self
function Compiler.Execute(ast, directives, dvars, includes)
	local instance = Compiler.from(directives, dvars, includes)
	local ok, script = xpcall(Compiler.Process, E2Lib.errorHandler, instance, ast)
	return ok, script, instance
end

---@param message string
---@param trace Trace
function Compiler:Error(message, trace)
	error( Error.new(message, trace), 0)
end

---@generic T
---@param v? T
---@param message string
---@param trace Trace
---@return T
function Compiler:Assert(v, message, trace)
	if not v then error( Error.new(message, trace), 0) end
	return v
end

---@param message string
---@param trace Trace
function Compiler:Warning(message, trace)
	if self.include then
		local tbl = self.warnings[self.include]
		tbl[#tbl + 1] = Warning.new(message, trace)
	else
		self.warnings[#self.warnings + 1] = Warning.new(message, trace)
	end
end

---@generic T
---@generic T2
---@param fn fun(scope: Scope): T?, T2?
---@return T?, T2?
function Compiler:Scope(fn)
	self.scope = Scope.new(self.scope)
	local ret, ret2 = fn(self.scope)
	self.scope = self.scope.parent
	return ret, ret2
end

--- Ensure that a token of variant LowerIdent is a valid type
---@param ty Token<string>
---@return string? type_id # Type id or nil if void
function Compiler:CheckType(ty)
	-- if not E2Lib.Env.Types[ty.value] then self:Error("Invalid type (" .. ty.value .. ")", ty.trace) end
	if ty.value == "number" then return "n" end
	if ty.value == "void" then return end
	return self:Assert(wire_expression_types[ty.value:upper()], "Invalid type (" .. ty.value .. ")", ty.trace)[1]
end

---@alias RuntimeOperator fun(self: RuntimeContext, ...): any

---@type fun(self: Compiler, trace: Trace, data: { [1]: Node, [2]: Operator, [3]: self }): RuntimeOperator, string?
local function handleInfixOperation(self, trace, data)
	local lhs, lhs_ty = self:CompileExpr(data[1])
	local rhs, rhs_ty = self:CompileExpr(data[3])

	local op, op_ret, legacy = self:GetOperator(E2Lib.OperatorNames[data[2]]:lower(), { lhs_ty, rhs_ty }, trace)

	if legacy then
		-- legacy
		local largs = { [1] = {}, [2] = { lhs }, [3] = { rhs }, [4] = { lhs_ty, rhs_ty } }

		return function(state)
			return op(state, largs)
		end, op_ret
	else
		return function(state)
			return op(state, lhs(state), rhs(state))
		end, op_ret
	end
end

---@type table<NodeVariant, fun(self: Compiler, trace: Trace, data: table): RuntimeOperator|nil, string?>
local CompileVisitors = {
	---@param data Node[]
	[NodeVariant.Block] = function(self, trace, data)
		local stmts, traces = {}, {}
		for _, node in ipairs(data) do
			if not self.scope.data.dead then
				local trace, stmt = node.trace, self:CompileStmt(node)
				if stmt then -- Need to append because Compile* can return nil (despite me not annotating it as such) for compile time constructs
					local i = #stmts + 1
					stmts[i], traces[i] = stmt, trace

					if node.variant == NodeVariant.ExprCall then -- Check if nodiscard (hacky :\)
						local name, argtypes = node.data[1].value, {}
						for k, arg in ipairs(node.data[2]) do
							argtypes[k] = select(2, self:CompileExpr(arg))
						end
						local fn = self:Assert(self:GetFunction(name, argtypes), "Unreachable", trace)
						if fn.attrs["nodiscard"] then
							self:Warning("Cannot discard return value of pure function", node.trace)
						end
						if fn.attrs["deprecated"] then
							local value = fn.attrs["deprecated"]
							if type(value) == "string" then
								self:Warning("Use of deprecated function (" .. name .. "): " .. value, node.trace)
							else
								self:Warning("Use of deprecated function (" .. name .. ")", node.trace)
							end
						end
					elseif node.variant == NodeVariant.ExprMethodCall then
						local method, name, types = node.data[1], node.data[2], {}
						for k, arg in ipairs(node.data[3]) do
							types[k] = select(2, self:CompileExpr(arg))
						end

						local meta_type = select(2, self:CompileExpr(method))
						local fn = self:Assert(self:GetFunction(name.value, types, meta_type), "Unreachable", name.trace)

						if fn.attrs["nodiscard"] then
							self:Warning("Cannot discard return value of pure method", node.trace)
						end
						if fn.attrs["deprecated"] then
							local value = fn.attrs["deprecated"]
							if type(value) == "string" then
								self:Warning("Use of deprecated function (" .. name .. "): " .. value, node.trace)
							else
								self:Warning("Use of deprecated function (" .. name .. ")", node.trace)
							end
						end
					elseif node:isExpr() and node.variant ~= NodeVariant.ExprStringCall then
						self:Warning("This expression has no effect", node.trace)
					end
				end
			else
				self:Warning("Unreachable code detected", node.trace)
				break
			end
		end

		local cost = self.scope.data.ops
		self.scope.data.ops = 0

		if self.scope:ResolveData("loop") then -- Inside loop, check if continued or broken
			return function(state) ---@param state RuntimeContext
				state.prf = state.prf + cost
				if state.prf > TickQuota then error("perf", 0) end

				for i, stmt in ipairs(stmts) do
					if state.__break__ or state.__return__ then break end
					if not state.__continue__ then
						state.trace = traces[i]
						stmt(state)
					end
				end
			end
		elseif self.scope:ResolveData("function") then -- If inside a function, check if returned.
			return function(state) ---@param state RuntimeContext
				state.prf = state.prf + cost
				if state.prf > TickQuota then error("perf", 0) end

				for i, stmt in ipairs(stmts) do
					if state.__return__ then break end
					state.trace = traces[i]
					stmt(state)
				end
			end
		else -- Most optimized case, not inside a function or loop.
			return function(state) ---@param state RuntimeContext
				state.prf = state.prf + cost
				if state.prf > TickQuota then error("perf", 0) end

				for i, stmt in ipairs(stmts) do
					state.trace = traces[i]
					stmt(state)
				end
			end
		end
	end,

	---@param data { [1]: Node?, [2]: Node }[]
	[NodeVariant.If] = function (self, trace, data)
		local chain = {} ---@type { [1]: RuntimeOperator?, [2]: RuntimeOperator }[]
		for i, ifeif in ipairs(data) do
			self:Scope(function()
				chain[i] = {ifeif[1] and self:CompileExpr(ifeif[1]), self:CompileStmt(ifeif[2])}
			end)
		end
		return function(state) ---@param state RuntimeContext
			for _, data in ipairs(chain) do
				local cond, block = data[1], data[2]
				if cond then
					if cond(state) ~= 0 then
						state:PushScope()
						block(state)
						state:PopScope()
						break
					end
				else
					-- Else block
					state:PushScope()
					block(state)
					state:PopScope()
					break
				end
			end
		end
	end,

	---@param data { [1]: Node, [2]: Node, [3]: boolean }
	[NodeVariant.While] = function(self, trace, data)
		local expr, block, cost = nil, nil, 1 / 10
		self:Scope(function(scope)
			expr = self:CompileExpr(data[1])
			scope.data.loop = true
			block = self:CompileStmt(data[2])
			cost = cost + scope.data.ops
		end)

		if data[3] then
			-- do while
			return function(state) ---@param state RuntimeContext
				state:PushScope()
				repeat
					state.prf = state.prf + cost
					if state.__continue__ then
						if state.prf > TickQuota then error("perf", 0) end
						state.__continue__ = false
					else
						block(state)
						if state.__break__ or state.__return__ then break end
					end
				until expr(state) == 0
				state:PopScope()
			end
		else
			return function(state) ---@param state RuntimeContext
				state:PushScope()
				while expr(state) ~= 0 do
					state.prf = state.prf + cost
					if state.__continue__ then
						if state.prf > TickQuota then error("perf", 0) end
						state.__continue__ = false
					else
						block(state)
						if state.__break__ or state.__return__ then break end
					end
				end
				state:PopScope()
			end
		end
	end,

	---@param data { [1]: Token<string>, [2]: Node, [3]: Node, [4]: Node?, [5]: Node } var start stop step block
	[NodeVariant.For] = function (self, trace, data)
		local var, start, stop, step = data[1], self:CompileExpr(data[2]), self:CompileExpr(data[3]), data[4] and self:CompileExpr(data[4]) or data[4]

		local block, cost = self:Scope(function(scope)
			scope.data.loop = true
			scope:DeclVar(var.value, { initialized = true, type = "n", trace_if_unused = var.trace })

			block = self:CompileStmt(data[5])
			return block, 1 / 20 + scope.data.ops
		end)

		local var = var.value
		return function(state) ---@param state RuntimeContext
			state:PushScope()
			local step = step and step(state) or 1
			for i = start(state), stop(state), step do
				state.prf = state.prf + cost
				state.Scope[var] = i

				if state.__continue__ then
					if state.prf > TickQuota then error("perf", 0) end
					state.__continue__ = false
				else
					block(state)
					if state.__break__ or state.__return__ then break end
				end
			end
			state:PopScope()
		end
	end,

	---@param data { [1]: Token<string>, [2]: Token<string>?, [3]: Token<string>, [4]: Token<string>, [5]: Node, [6]: Node } key key_type value value_type iterator block
	[NodeVariant.Foreach] = function (self, trace, data)
		local key, key_type, value, value_type = data[1], data[2] and self:CheckType(data[2]) or "n", data[3], self:CheckType(data[4])

		local iterator, iterator_ty = self:CompileExpr(data[5])
		local block, cost = self:Scope(function(scope)
			scope.data.loop = true

			scope:DeclVar(key.value, { initialized = true, trace_if_unused = key.trace, type = key_type })
			scope:DeclVar(value.value, { initialized = true, trace_if_unused = value.trace, type = value_type })

			return self:CompileStmt(data[6]), 1 / 15 + scope.data.ops
		end)

		local foreach, _, ops = self:GetOperator("iter", { key_type, value_type, "=", iterator_ty }, trace)
		local key, value = key.value, value.value
		return function(state) ---@param state RuntimeContext
			local iter = foreach(state, iterator(state))

			for k, v in iter() do
				state:PushScope()

				state.prf = state.prf + cost

				state.Scope[key] = k
				state.Scope[value] = v

				block(state)

				state:PopScope()
			end
		end
	end,

	---@param data { [1]: Node, [2]: {[1]: Node, [2]: Node}[], [3]: Node? }
	[NodeVariant.Switch] = function (self, trace, data)
		local expr, expr_ty = self:CompileExpr(data[1])

		local cases = {} ---@type { [1]: RuntimeOperator, [2]: RuntimeOperator }[]
		for i, case in ipairs(data[2]) do
			local cond, cond_ty = self:CompileExpr(case[1])
			local block
			self:Scope(function(scope)
				scope.data.switch_case = true
				block = self:CompileStmt(case[2])
			end)

			local eq =  self:GetOperator("eq", { expr_ty, cond_ty }, case[1].trace)
			cases[i] = {
				function(state, expr)
					return eq(state, cond(state), expr)
				end,
				block
			}
		end

		local default = data[3] and self:Scope(function() return self:CompileStmt(data[3]) end)
		return function(state) ---@param state RuntimeContext
			local expr = expr(state)
			for i, case in ipairs(cases) do
				if case[1](state, expr) ~= 0 then
					case[2](state)
					return
				end
			end

			default(state)
		end
	end,

	---@param data { [1]: Node, [2]: Token<string>, [3]: Node }
	[NodeVariant.Try] = function (self, trace, data)
		local try_block, catch_block, err_var = nil, nil, data[2]
		self:Scope(function(scope)
			try_block = self:CompileStmt(data[1])
		end)

		self:Scope(function (scope)
			scope:DeclVar(err_var.value, { initialized = true, trace_if_unused = err_var.trace, type = "s" })
			catch_block = self:CompileStmt(data[3])
		end)

		self.scope.data.ops = self.scope.data.ops + 1

		return function(state) ---@param state RuntimeContext
			state:PushScope()
			local ok, err = pcall(try_block, state)
			state:PopScope()
			if not ok then
				local catchable, msg, trace = E2Lib.unpackException(err)
				if catchable then
					state.Scope[err_var.value] = (type(msg) == "string") and msg or ""
					state:PushScope()
					catch_block(state)
					state:PopScope()
				else
					error(err, 0)
				end
			end
		end
	end,

	---@param data { [1]: Token<string>, [2]: Token<string>?, [3]: Token<string>, [4]: Parameter[], [5]: Node }
	[NodeVariant.Function] = function (self, trace, data)
		local name = data[3]

		local return_type
		if data[1] then
			return_type = self:CheckType(data[1])
		end

		local meta_type
		if data[2] then
			meta_type = self:CheckType(data[2])
			if meta_type == "" then
				self:Error("Cannot use void as meta type", trace)
			end
		end

		local param_types, param_names, variadic, variadic_ty = {}, {}, nil, nil
		if data[4] then
			for i, param in ipairs(data[4]) do
				if param.type then
					local t = self:CheckType(param.type)
					if param.variadic then
						self:Assert(t == "r" or t == "t", "Variadic parameter must be of type array or table", param.type.trace)
						param_types[i] = ".." .. t
						variadic, variadic_ty = param.name, t
					else
						param_types[i] = t
					end
				elseif param.variadic then
					self:Error("Variadic parameter requires explicit type", param.name.trace)
				else
					param_types[i] = "n"
					self:Warning("Use of implicit parameter type is deprecated (add :number)", param.name.trace)
				end
				param_names[i] = param.name.value
			end
		end

		local fn_data, variadic, userfunction = self:GetFunction(name.value, param_types, meta_type)
		if fn_data then
			if not userfunction then
				if not variadic then
					self:Error("Cannot overwrite existing function: " .. (meta_type and (meta_type .. ":") or "") .. name.value .. "(" .. table.concat(param_types, ", ") .. ")", name.trace)
				end
			else
				self:Assert(fn_data.returns[1] == return_type, "Cannot override with differing return type", trace)
			end
		end

		-- Code below is gargantuan as it's duplicated for each scenario at compile time for
		-- the least amount of runtime overhead (and the variadic syntax sugar is annoying)

		local block, op
		if return_type then
			if variadic then
				local last, non_variadic = #param_types, #param_types - 1
				if variadic_ty == "r" then
					function op(state, args) ---@param state RuntimeContext
						local save = state:SaveScopes()

						local scope = { vclk = {} } -- Hack in the fact that functions don't have upvalues right now.
						state.Scopes = { [0] = state.GlobalScope, [1] = scope }
						state.Scope = scope
						state.ScopeID = 1

						for i = 1, non_variadic do
							scope[param_names[i]] = args[i]
						end

						local a, n = {}, 1
						for i = last, #args do
							a[n] = args[i]
							n = n + 1
						end

						scope[param_names[last]] = a
						block(state)
						state:LoadScopes(save)
						if state.__return__ then
							state.__return__ = false
							return state.__returnval__
						else
							E2Lib.raiseException("Expected function return at runtime of type (" .. return_type .. ")", 0, state.trace)
						end
					end
				else -- table
					function op(state, args, arg_types) ---@param state RuntimeContext
						local save = state:SaveScopes()

						local scope = { vclk = {} } -- Hack in the fact that functions don't have upvalues right now.
						state.Scopes = { [0] = state.GlobalScope, [1] = scope }
						state.Scope = scope
						state.ScopeID = 1

						for i = 1, non_variadic do
							scope[param_names[i]] = args[i]
						end

						local n, ntypes = {}, {}
						for i = last, #args do
							n[i], ntypes[i] = args[i], arg_types[i]
						end

						scope[param_names[last]] = { s = {}, stypes = {}, n = n, ntypes = ntypes, size = last }

						block(state)
						state:LoadScopes(save)

						if state.__return__ then
							state.__return__ = false
							return state.__returnval__
						else
							E2Lib.raiseException("Expected function return at runtime of type (" .. return_type .. ")", 0, state.trace)
						end
					end
				end
			else
				function op(state, args) ---@param state RuntimeContext
					local save = state:SaveScopes()

					local scope = { vclk = {} } -- Hack in the fact that functions don't have upvalues right now.
					state.Scopes = { [0] = state.GlobalScope, [1] = scope }
					state.Scope = scope
					state.ScopeID = 1

					for i, arg in ipairs(args) do
						scope[param_names[i]] = arg
					end

					block(state)
					state:LoadScopes(save)

					if state.__return__ then
						state.__return__ = false
						return state.__returnval__
					else
						E2Lib.raiseException("Expected function return at runtime of type (" .. return_type .. ")", 0, state.trace)
					end
				end
			end
		elseif variadic then
			local last, non_variadic = #param_types, #param_types - 1
			if variadic_ty == "r" then
				function op(state, args) ---@param state RuntimeContext
					local save = state:SaveScopes()

					local scope = { vclk = {} } -- Hack in the fact that functions don't have upvalues right now.
					state.Scopes = { [0] = state.GlobalScope, [1] = scope }
					state.Scope = scope
					state.ScopeID = 1

					for i = 1, non_variadic do
						scope[param_names[i]] = args[i]
					end

					local a, n = {}, 1
					for i = last, #args do
						a[n] = args[i]
						n = n + 1
					end

					scope[param_names[last]] = a
					block(state)

					state:LoadScopes(save)
				end
			else -- table
				function op(state, args, arg_types) ---@param state RuntimeContext
					local save = state:SaveScopes()

					local scope = { vclk = {} } -- Hack in the fact that functions don't have upvalues right now.
					state.Scopes = { [0] = state.GlobalScope, [1] = scope }
					state.Scope = scope
					state.ScopeID = 1

					for i = 1, non_variadic do
						scope[param_names[i]] = args[i]
					end

					local n, ntypes = {}, {}
					for i = last, #args do
						n[i], ntypes[i] = args[i], arg_types[i]
					end

					scope[param_names[last]] = { s = {}, stypes = {}, n = n, ntypes = ntypes, size = last }
					block(state)

					state:LoadScopes(save)
				end
			end
		elseif #param_types == 0 then -- Fastest case, no arguments to push
			function op(state) ---@param state RuntimeContext
				local save = state:SaveScopes()

				local scope = { vclk = {} } -- Hack in the fact that functions don't have upvalues right now.
				state.Scopes = { [0] = state.GlobalScope, [1] = scope }
				state.Scope = scope
				state.ScopeID = 1

				block(state)

				state:LoadScopes(save)
			end
		else
			function op(state, args) ---@param state RuntimeContext
				local save = state:SaveScopes()

				local scope = { vclk = {} } -- Hack in the fact that functions don't have upvalues right now.
				state.Scopes = { [0] = state.GlobalScope, [1] = scope }
				state.Scope = scope
				state.ScopeID = 1

				for i, arg in ipairs(args) do
					scope[param_names[i]] = arg
				end

				block(state)
				state:LoadScopes(save)
			end
		end

		local fn = { args = param_types, returns = return_type and { return_type }, meta = meta_type, op = op, cost = 20, attrs = {} }
		local sig = table.concat(param_types)

		if meta_type then
			self.user_methods[meta_type] = self.user_methods[meta_type] or {}

			self.user_methods[meta_type][name.value] = self.user_methods[meta_type][name.value] or {}

			if variadic then
				local opposite = variadic_ty == "r" and "t" or "r"
				if self.user_methods[meta_type][name.value][sig:gsub(".." .. variadic_ty, ".." .. opposite)] then
					self:Error("Cannot override variadic " .. opposite .. " function with variadic " .. variadic_ty .. " function to avoid ambiguity.", trace)
				end
			end

			self.user_methods[meta_type][name.value][sig] = fn

			-- Insert "This" variable
			table.insert(param_names, 1, "This")
			table.insert(param_types, 1, meta_type)
		else
			self.user_functions[name.value] = self.user_functions[name.value] or {}
			if variadic then
				local opposite = variadic_ty == "r" and "t" or "r"
				if self.user_functions[name.value][sig:gsub(".." .. variadic_ty, ".." .. opposite)] then
					self:Error("Cannot override variadic " .. opposite .. " function with variadic " .. variadic_ty .. " function to avoid ambiguity.", trace)
				end
			end
			self.user_functions[name.value][sig] = fn
		end

		self:Scope(function (scope)
			for i, type in ipairs(param_types) do
				scope:DeclVar(param_names[i], { type = type, initialized = true })
			end

			scope.data["function"] = { name.value, fn }

			block = self:CompileStmt(data[5])
		end)

		-- No `return` statement found. Returns void
		if not fn.returns then
			fn.returns = {}
		end

		self:Assert(fn.returns[1] == return_type, "Function " .. name.value .. " expects to return type (" .. (return_type or "void") .. ") but got type (" .. (fn.returns[1] or "void") .. ")", trace)

		local sig = name.value .. "(" .. sig .. ")"
		return function(state) ---@param state RuntimeContext
			state.funcs[sig] = op
			state.funcs_ret[sig] = return_type
		end
	end,

	---@param data string
	[NodeVariant.Include] = function (self, trace, data)
		local include = self.includes[data]
		if not include or not include[1] then
			self:Error("Problem including file '" .. data .. "'", trace)
		end

		if not include[2] then
			include[2] = true -- Prevent self-compiling infinite loop

			local old_scope = self.scope
			self.scope = Scope.new()

			local last_file = self.include
			self.include = data
			self.warnings[data] = self.warnings[data] or {}

			local root = include[1]
			local status, script = pcall(self.CompileStmt, self, root)

			if not status then ---@cast script Error
				local reason = script.message
				if reason:find("C stack overflow") then reason = "Include depth too deep" end

				if not self.IncludeError then
					-- Otherwise Errors messages will be wrapped inside other error messages!
					self.IncludeError = true
					self:Error("include '" .. data .. "' -> " .. reason, trace)
				else
					error(script, 0) -- re-throw
				end
			else
				self.include = last_file

				local nwarnings = #self.warnings[data]
				if nwarnings ~= 0 then
					self:Warning("include '" .. data .. "' has " .. nwarnings .. " warning(s).", trace)
				end
			end

			include[2] = script
			self.scope = old_scope -- Reload the old enviroment
		end

		return function(state) ---@param state RuntimeContext
			include[2](state) -- todo: separate scope when it's properly implemented
		end
	end,

	---@param data {}
	[NodeVariant.Continue] = function(self, trace, data)
		self.scope.data.dead = true
		return function(state) ---@param state RuntimeContext
			state.__continue__ = true
		end
	end,

	---@param data {}
	[NodeVariant.Break] = function(self, trace, data)
		self.scope.data.dead = true
		return function(state) ---@param state RuntimeContext
			state.__break__ = true
		end
	end,

	---@param data Node?
	[NodeVariant.Return] = function (self, trace, data)
		local fn = self.scope:ResolveData("function")
		self:Assert(fn, "Cannot use `return` outside of a function", trace)

		local retval, ret_ty
		if data then
			retval, ret_ty = self:CompileExpr(data)

			local name, fn = fn[1], fn[2]

			if fn.returns then
				self:Assert(fn.returns[1] == ret_ty, "Function " .. name .. " expects return type (" .. (fn.returns[1] or "void") .. ") but was given (" .. (ret_ty or "void") .. ")", trace)
			end

			fn.returns = { ret_ty }
		end

		return function(state) ---@param state RuntimeContext
			state.__returnval__, state.__return__ = retval(state), true
		end
	end,

	---@param data { [1]: boolean, [2]: { [1]: Token<string>, [2]: { [1]: Node, [2]: Token<string>?, [3]: Trace }[] }[], [3]: Node } is_local, vars, value
	[NodeVariant.Assignment] = function (self, trace, data)
		local value, value_ty = self:CompileExpr(data[3])
		self:Assert(value_ty, "Cannot assign variable to expression of type void", data[3].trace)

		if data[1] then
			-- Local declaration.
			local var_name = data[2][1][1].value
			self:Assert(not self.scope.vars[var_name], "Cannot redeclare existing variable " .. var_name, trace)
			self.scope:DeclVar(var_name, { initialized = true, type = value_ty })
			return function(state) ---@param state RuntimeContext
				state.Scope[var_name] = value(state)
			end
		end

		local stmts = {}
		for i, v in ipairs(data[2]) do
			local var, indices, trace = v[1].value, v[2], v[3]

			local existing = self.scope:LookupVar(var)
			if existing then
				local op, expr_ty = nil, existing.type

				-- It can have indices, it already exists
				if #indices > 0 then
					local setter, id = table.remove(indices), existing.scope:Depth()
					stmts[i] = function(state)
						return state.Scopes[id][var]
					end

					for j, index in ipairs(indices) do
						local key, key_ty = self:CompileExpr(index[1])

						if index[2] then -- <EXPR>[<EXPR>, <type>]
							local ty = self:CheckType(index[2])
							op, expr_ty = self:GetOperator("idx", { ty, "=", expr_ty, key_ty }, index[3])
						else -- <EXPR>[<EXPR>]
							op, expr_ty = self:GetOperator("idx", { expr_ty, key_ty }, index[3])
						end

						local handle = stmts[i] -- need this, or stack overflow...
						stmts[i] = function(state)
							return op(state, handle(state), key(state))
						end
					end

					local key, key_ty = self:CompileExpr(setter[1])

					if setter[2] then -- <EXPR>[<EXPR>, <type>]
						local ty = self:CheckType(setter[2])
						op, expr_ty = self:GetOperator("idx", { ty, "=", expr_ty, key_ty, ty }, setter[3])
					else -- <EXPR>[<EXPR>]
						op, expr_ty = self:GetOperator("idx", { expr_ty, key_ty, value_ty }, setter[3])
					end

					local handle = stmts[i] -- need this, or stack overflow...
					stmts[i] = function(state) ---@param state RuntimeContext
						return op(state, handle(state), key(state), value(state))
					end
				else
					self:Assert(existing.type == value_ty, "Cannot assign type (" .. value_ty .. ") to variable of type (" .. existing.type .. ")", trace)

					local id = existing.scope:Depth()
					if id == 0 then
						stmts[i] = function(state) ---@param state RuntimeContext
							local val = value(state)
							state.GlobalScope[var] = val
							state.GlobalScope.vclk[var] = true

							if state.GlobalScope.lookup[val] then
								state.GlobalScope.lookup[val][var] = true
							else
								state.GlobalScope.lookup[val] = { [var] = true }
							end
						end
					else
						stmts[i] = function(state) ---@param state RuntimeContext
							state.Scopes[id][var] = value(state)
						end
					end
				end
			else
				-- Cannot have indices.
				self:Assert(#indices == 0, "Variable (" .. var .. ") does not exist", trace)
				self.global_scope:DeclVar(var, { type = value_ty, initialized = true, trace_if_unused = trace })

				stmts[i] = function(state) ---@param state RuntimeContext
					local val = value(state)
					state.GlobalScope[var] = val
					state.GlobalScope.vclk[var] = true

					if state.GlobalScope.lookup[val] then
						state.GlobalScope.lookup[val][var] = true
					else
						state.GlobalScope.lookup[val] = { [var] = true }
					end
				end
			end
		end

		return function(state) ---@param state RuntimeContext
			local expr = value(state)
			for _, stmt in ipairs(stmts) do
				stmt(state, expr)
			end
		end
	end,

	---@param data Token<string>
	[NodeVariant.Increment] = function (self, trace, data)
		local var = data.value
		local existing = self:Assert(self.scope:LookupVar(var), "Unknown variable to increment: " .. var, trace)
		self:Assert(existing.type == "n", "Cannot increment type of " .. existing.type, trace)

		local id = existing.scope:Depth()
		return function(state) ---@param state RuntimeContext
			state.Scopes[id][var] = state.Scopes[id][var] + 1
		end
	end,

	---@param data Token<string>
	[NodeVariant.Decrement] = function (self, trace, data)
		local var = data.value
		local existing = self:Assert(self.scope:LookupVar(var), "Unknown variable to decrement: " .. var, trace)
		self:Assert(existing.type == "n", "Cannot increment type of " .. existing.type, trace)

		local id = existing.scope:Depth()
		return function(state) ---@param state RuntimeContext
			state.Scopes[id][var] = state.Scopes[id][var] - 1
		end
	end,

	---@param data { [1]: Token<string>, [2]: Operator, [3]: Node }
	[NodeVariant.CompoundArithmetic] = function(self, trace, data)
		local var = self:Assert(self.scope:LookupVar(data[1].value), "Variable " .. data[1].value .. " does not exist.", trace)
		local expr, expr_ty = self:CompileExpr(data[3])

		local op, op_ty = self:GetOperator(E2Lib.OperatorNames[data[2]]:lower():sub(2), { var.type, expr_ty }, trace)
		self:Assert(op_ty == var.type, "Cannot use compound arithmetic on differing types", trace)

		local name = data[1].value
		return function(state)
			state.Scope[name] = op(state, state.Scope[name], expr(state))
		end
	end,

	---@param data { [1]: Node, [2]: Node }
	[NodeVariant.ExprDefault] = function(self, trace, data)
		local cond, cond_ty = self:CompileExpr(data[1])
		local expr, expr_ty = self:CompileExpr(data[2])

		self:Assert(cond_ty == expr_ty, "Cannot use default (?:) operator with differing types", trace)

		local op = self:GetOperator("is", { cond_ty }, trace)

		return function(state) ---@param state RuntimeContext
			local iff = cond(state)
			return op(state, iff) ~= 0 and iff or expr(state)
		end, cond_ty
	end,

	---@param data { [1]: Node, [2]: Node }
	[NodeVariant.ExprTernary] = function(self, trace, data)
		local cond, cond_ty = self:CompileExpr(data[1])
		local iff, iff_ty = self:CompileExpr(data[2])
		local els, els_ty = self:CompileExpr(data[2])

		self:Assert(iff_ty == els_ty, "Cannot use ternary (A ? B : C) operator with differing types", trace)

		local op = self:GetOperator("is", { cond_ty }, trace)

		return function(state) ---@param state RuntimeContext
			return op(state, cond(state)) ~= 0 and iff(state) or els(state)
		end, iff_ty
	end,

	---@param data { [1]: string, [2]: string|number|table }
	[NodeVariant.ExprLiteral] = function (self, trace, data)
		local val = data[2]

		self.scope.data.ops = self.scope.data.ops + 1 / 8
		return function()
			return val
		end, data[1]
	end,

	---@param data Token<string>
	[NodeVariant.ExprIdent] = function (self, trace, data)
		local var, name = self:Assert(self.scope:LookupVar(data.value), "Undefined variable: " .. data.value, trace), data.value

		self.scope.data.ops = self.scope.data.ops + 1

		local id = var.scope:Depth()
		return function(state) ---@param state RuntimeContext
			return state.Scopes[id][name]
		end, var.type
	end,

	---@param data Node[]|{ [1]: Node, [2]:Node }[]
	[NodeVariant.ExprArray] = function (self, trace, data)
		if #data == 0 then
			return function()
				return {}
			end, "r"
		elseif data[1][2] then -- key value array
			---@cast data { [1]: Node, [2]: Node }[] # Key value pair arguments

			local numbers = {}
			for _, kvpair in ipairs(data) do
				local key, key_ty = self:CompileExpr(kvpair[1])

				if key_ty == "n" then
					local value, ty = self:CompileExpr(kvpair[2])
					self:Assert(not BLOCKED_ARRAY_TYPES[ty], "Cannot use type " .. ty .. " as array value", kvpair[2].trace)
					numbers[key] = value
				else
					self:Error("Cannot use type " .. key_ty .. " as array key", kvpair[1].trace)
				end
			end

			return function(state) ---@param state RuntimeContext
				local array = {}

				for key, value in pairs(numbers) do
					array[key(state)] = value(state)
				end

				return array
			end, "r"
		else
			local args = {}
			for k, arg in ipairs(data) do
				local value, ty = self:CompileExpr(arg)
				self:Assert(not BLOCKED_ARRAY_TYPES[ty], "Cannot use type " .. ty .. " as array value", trace)
				args[k] = value
			end

			return function(state) ---@param state RuntimeContext
				local array = {}
				for i, val in ipairs(args) do
					array[i] = val(state)
				end
				return array
			end, "r"
		end
	end,

	[NodeVariant.ExprTable] = function (self, trace, data)
		if #data == 0 then
			return function()
				return { n = {}, ntypes = {}, s = {}, stypes = {}, size = 0 }
			end, "t"
		elseif data[1][2] then
			---@cast data { [1]: Node, [2]: Node }[] # Key value pair arguments

			local strings, numbers, size = {}, {}, #data
			for _, kvpair in ipairs(data) do
				local key, key_ty = self:CompileExpr(kvpair[1])
				local value, value_ty = self:CompileExpr(kvpair[2])

				if key_ty == "s" then
					strings[key] = { value, value_ty }
				elseif key_ty == "n" then
					numbers[key] = { value, value_ty }
				else
					self:Error("Cannot use type " .. key_ty .. " as table key", kvpair[1].trace)
				end
			end

			return function(state) ---@param state RuntimeContext
				local s, stypes, n, ntypes = {}, {}, {}, {}

				for key, data in pairs(strings) do
					local k = key(state)
					s[k], stypes[k] = data[1](state), data[2]
				end

				for key, data in pairs(numbers) do
					local k = key(state)
					n[k], ntypes[k] = data[1](state), data[2]
				end

				return { s = s, stypes = stypes, n = n, ntypes = ntypes, size = size }
			end, "t"
		else
			---@cast data Node[]
			local args, argtypes = {}, {}
			for k, arg in ipairs(data) do
				args[k], argtypes[k] = self:CompileExpr(arg)
			end

			return function(state) ---@param state RuntimeContext
				local array = {}
				for i, val in ipairs(args) do
					array[i] = val(state)
				end
				return { n = array, ntypes = argtypes, s = {}, stypes = {}, size = #array }
			end, "t"
		end
	end,

	[NodeVariant.ExprArithmetic] = handleInfixOperation,


	---@param data { [1]: Node, [2]: Operator, [3]: self }
	[NodeVariant.ExprLogicalOp] = function(self, trace, data)
		local lhs, lhs_ty = self:CompileExpr(data[1])
		local rhs, rhs_ty = self:CompileExpr(data[3])

		-- self:Assert(lhs_ty == rhs_ty, "Cannot perform logical operation on differing types", trace)

		local op_lhs, op_lhs_ret, legacy = self:GetOperator("is", { lhs_ty }, trace)
		local op_rhs, op_rhs_ret, legacy2 = self:GetOperator("is", { rhs_ty }, trace)

		self:Assert(op_lhs_ret == "n", "Cannot perform logical operation on type " .. op_lhs_ret, trace)
		self:Assert(op_rhs_ret == "n", "Cannot perform logical operation on type " .. op_rhs_ret, trace)

		self:Assert(legacy == legacy2, "Internal error", trace)

		-- local op, op_ret, legacy = self:GetOperator("is", { lhs_ty }, trace)
		-- self:Assert(op_ret == "n", "Cannot use perform logical operation on type " .. lhs_ty, trace)

		if data[2] == Operator.Or then
			if legacy then
				local largs_lhs = { [1] = {}, [2] = { lhs }, [3] = { lhs_ty } }
				local largs_rhs = { [1] = {}, [2] = { rhs }, [3] = { rhs_ty } }
				return function(state)
					return ((op_lhs(state, largs_lhs) ~= 0) or (op_rhs(state, largs_rhs) ~= 0)) and 1 or 0
				end, "n"
			else
				return function(state)
					return ((op_lhs(state, lhs(state)) ~= 0) or (op_rhs(state, rhs(state)) ~= 0)) and 1 or 0
				end, "n"
			end
		else -- Operator.And
			if legacy then
				local largs_lhs = { [1] = {}, [2] = { lhs }, [3] = { lhs_ty } }
				local largs_rhs = { [1] = {}, [2] = { rhs }, [3] = { rhs_ty } }
				return function(state)
					return (op_lhs(state, lhs(state, largs_lhs)) ~= 0 and op_rhs(state, rhs(state, largs_rhs)) ~= 0) and 1 or 0
				end
			else
				return function(state)
					return (op_lhs(state, lhs(state)) ~= 0 and op_rhs(state, rhs(state)) ~= 0) and 1 or 0
				end, "n"
			end
		end
	end,

	[NodeVariant.ExprBinaryOp] = handleInfixOperation,
	[NodeVariant.ExprComparison] = handleInfixOperation,

	[NodeVariant.ExprEquals] = function(self, trace, data)
		local lhs, lhs_ty = self:CompileExpr(data[1])
		local rhs, rhs_ty = self:CompileExpr(data[3])

		self:Assert(lhs_ty == rhs_ty, "Cannot perform equality operation on differing types", trace)

		local op, op_ret, legacy = self:GetOperator("eq", { lhs_ty, rhs_ty }, trace)
		self:Assert(op_ret == "n", "Cannot use perform equality operation on type " .. lhs_ty, trace)

		if data[2] == Operator.Eq then
			if legacy then
				local largs = { [1] = {}, [2] = { lhs }, [3] = { rhs }, [4] = { lhs_ty, rhs_ty } }
				return function(state)
					return op(state, largs) ~= 0 and 1 or 0
				end, "n"
			else
				return function(state)
					return op(state, lhs(state), rhs(state)) ~= 0 and 1 or 0
				end, "n"
			end
		else -- Operator.Neq
			if legacy then
				local largs = { [1] = {}, [2] = { lhs }, [3] = { rhs }, [4] = { lhs_ty, rhs_ty } }
				return function(state)
					return op(state, largs) == 0 and 1 or 0
				end, "n"
			else
				return function(state)
					return op(state, lhs(state), rhs(state)) == 0 and 1 or 0
				end, "n"
			end
		end
	end,

	[NodeVariant.ExprBitShift] = handleInfixOperation,

	---@param data { [1]: Operator, [2]: Node, [3]: self }
	[NodeVariant.ExprUnaryOp] = function(self, trace, data)
		local exp, ty = self:CompileExpr(data[2])

		if data[1] == Operator.Not then -- Return opposite of operator_is result
			local op, op_ret, legacy = self:GetOperator("is", { ty }, trace)
			self:Assert(op_ret == "n", "Cannot perform not operation on type " .. ty, trace)

			if legacy then
				local largs = { [1] = {}, [2] = { exp }, [3] = { ty } }
				return function(state)
					return op(state, largs)
				end, "n"
			else
				return function(state)
					return op(state, exp(state)) == 0 and 1 or 0
				end, "n"
			end
		else
			local op, op_ret, legacy = self:GetOperator(data[1] == Operator.Sub and "neg" or E2Lib.OperatorNames[data[1]]:lower(), { ty }, trace)
			if legacy then
				local largs = { [1] = {}, [2] = { exp }, [3] = { ty } }
				return function(state)
					return op(state, largs)
				end
			else
				return function(state)
					return op(state, exp(state))
				end, op_ret
			end
		end
	end,

	---@param data { [1]: Operator, [2]: Token<string> }
	[NodeVariant.ExprUnaryWire] = function(self, trace, data)
		local var_name = data[2].value
		local var = self:Assert(self.scope:LookupVar(var_name), "Undefined variable (" .. var_name .. ")", trace)

		if data[1] == Operator.Dlt then -- $
			self:Assert(var.scope:IsGlobalScope(), "Delta operator ($) can not be used on temporary variables", trace)
			self.delta_vars[var_name] = true

			local sub_op, sub_ty = self:GetOperator("sub", { var.type, var.type }, trace)
			local var = Node.new(NodeVariant.ExprIdent, data[2])

			local tok = Token.new(TokenVariant.Ident, "$" .. data[2].value)
			tok.trace = data[2].trace
			local var_dlt = Node.new(NodeVariant.ExprIdent, tok)

			return function(state) ---@param state RuntimeContext
				sub_op(state, var, var_dlt)
			end, sub_ty
		elseif data[1] == Operator.Trg then -- ~
			local op, op_ret = self:GetOperator("trg", {}, trace)
			return function(state) ---@param state RuntimeContext
				return op(state, var_name)
			end, op_ret
		elseif data[1] == Operator.Imp then -- ->
			if self.inputs[var_name] then
				local op, op_ret = self:GetOperator("iwc", {}, trace)
				return function(state) ---@param state RuntimeContext
					return op(state, var_name)
				end, op_ret
			elseif self.outputs[var_name] then
				local op, op_ret = self:GetOperator("owc", {}, trace)
				return function(state) ---@param state RuntimeContext
					return op(state, var_name)
				end, op_ret
			else
				self:Error("Can only use connected (->) operator on inputs or outputs", trace)
			end
		end
	end,

	---@param data { [1]: Node, [2]: Index[] }
	[NodeVariant.ExprIndex] = function (self, trace, data)
		local expr, expr_ty = self:CompileExpr(data[1])
		for i, index in ipairs(data[2]) do
			local key, key_ty = self:CompileExpr(index[1])

			local op
			if index[2] then -- <EXPR>[<EXPR>, <type>]
				local ty = self:CheckType(index[2])
				op, expr_ty = self:GetOperator("idx", { ty, "=", expr_ty, key_ty }, index[3])
			else -- <EXPR>[<EXPR>]
				op, expr_ty = self:GetOperator("idx", { expr_ty, key_ty }, index[3])
			end

			local handle = expr -- need this, or stack overflow...
			expr = function(state)
				return op(state, handle(state), key(state))
			end
		end

		return expr, expr_ty
	end,

	---@param data { [1]: Token<string>, [2]: Node[] }
	[NodeVariant.ExprCall] = function (self, trace, data)
		local args, types = {}, {}
		for k, arg in ipairs(data[2]) do
			args[k], types[k] = self:CompileExpr(arg)
			self:Assert(types[k], "Cannot use void expression as call argument", arg.trace)
		end

		local fn_data = self:Assert(self:GetFunction(data[1].value, types), "No such function: " .. data[1].value .. "(" .. table.concat(types, ", ") .. ")", data[1].trace)
		local fn = fn_data.op

		self.scope.data.ops = self.scope.data.ops + ((fn_data.cost or 20) + (fn_data.attrs["legacy"] and 10 or 0))

		if fn_data.attrs["noreturn"] then
			self.scope.data.dead = true
		end

		if fn_data.attrs["legacy"] then
			local largs = { [1] = {}, [#args + 2] = types }
			for i, arg in ipairs(args) do
				largs[i + 1] = { [1] = arg }
			end
			return function(state) ---@param state RuntimeContext
				return fn(state, largs)
			end, fn_data.returns[1]
		else
			return function(state) ---@param state RuntimeContext
				local rargs = {}
				for k, arg in ipairs(args) do
					rargs[k] = arg(state)
				end

				return fn(state, rargs, types)
			end, fn_data.returns[1]
		end
	end,

	---@param data { [1]: Node, [2]: Token<string>, [3]: Node[] }
	[NodeVariant.ExprMethodCall] = function (self, trace, data)
		local name, args, types = data[2], {}, {}
		for k, arg in ipairs(data[3]) do
			args[k], types[k] = self:CompileExpr(arg)
		end

		local meta, meta_type = self:CompileExpr(data[1])

		local fn_data = self:Assert(self:GetFunction(name.value, types, meta_type), "No such method: " .. (meta_type or "void") .. ":" .. name.value .. "(" .. table.concat(types, ", ") .. ")", name.trace)
		local fn = fn_data.op

		if fn_data.attrs["legacy"] then
			local largs = { [#args + 3] = types, [2] = { [1] = meta } }
			for i, arg in ipairs(args) do
				largs[i + 2] = { [1] = arg }
			end

			return function(state) ---@param state RuntimeContext
				return fn(state, largs)
			end, fn_data.returns[1]
		else
			return function(state) ---@param state RuntimeContext
				local rargs = { meta }
				for k, arg in ipairs(args) do
					rargs[k + 1] = arg(state)
				end

				return fn(state, rargs)
			end, fn_data.returns[1]
		end
	end,

	---@param data { [1]: Node, [2]: Node[], [3]: Token<string>? }
	[NodeVariant.ExprStringCall] = function (self, trace, data)
		local expr = self:CompileExpr(data[1])

		local args, arg_types = {}, {}
		for i, arg in ipairs(data[2]) do
			args[i], arg_types[i] = self:CompileExpr(arg)
		end

		local arg_sig = table.concat(arg_types)
		local ret_type = data[3] and self:CheckType(data[3])

		return function(state) ---@param state RuntimeContext
			local rargs = {}
			for k, arg in ipairs(args) do
				rargs[k] = arg(state)
			end

			local fn = expr(state)
			local sig = fn .. "(" .. arg_sig .. ")"
			if state.funcs[sig] then
				local r = state.funcs_ret[sig]
				if r ~= ret_type then
					error( "Mismatching return types. Got " .. (r or "void") .. ", expected " .. (ret_type or "void"), 0)
				end

				return state.funcs[sig](state, rargs)
			else
				E2Lib.raiseException("No such function: " .. fn .. "(" .. arg_sig .. ")", 0, state.trace)
			end
		end, ret_type
	end,

	---@param data { [1]: Token<string>, [2]: Parameter[], [3]: Node }
	[NodeVariant.Event] = function (self, trace, data)
		if self.scope.parent then
			self:Error("Events cannot be nested inside of statements, they are compile time constructs", trace)
		end

		local name, params = data[1].value, {}
		for i, param in ipairs(data[2]) do
			params[i] = { param.name.value, param.type and self:CheckType(param.type) or "n" }
		end

		local event = E2Lib.Env.Events[name]
		if not event then
			self:Error("No such event exists: '" .. name .. "'", trace)
		end

		if #params > #event.args then
			local extra_arg_types = {}
			for i = #event.args + 1, #params do
				-- name, type, variadic
				extra_arg_types[#extra_arg_types + 1] = params[i][2]
			end

			self:Error("Event '" .. name .. "' does not take arguments (" .. table.concat(extra_arg_types, ", ") .. ")", trace)
		end

		for k, arg in ipairs(event.args) do
			if not params[k] then
				-- TODO: Maybe this should be a warning so that events can have extra params added without breaking old code?
				self:Error("Event '" .. name .. "' missing argument #" .. k .. " of type " .. tostring(arg), trace)
			end

			if arg ~= params[k][2] then
				self:Error("Mismatched event argument: " .. tostring(arg) .. " vs " .. tostring(param_id), trace)
			end
		end

		if (self.registered_events[name] and self.registered_events[name][self.include or "__main__"]) then
			self:Error("You can only register one event callback per file", trace)
		end

		self.registered_events[name] = self.registered_events[name] or {}

		local block = self:Scope(function(scope)
			for k, arg in ipairs(event.args) do
				if not params[k].discard then
					scope:DeclVar(params[k][1], { type = arg, initialized = true, trace_if_unused = params[k][3] })
				end
			end

			return self:CompileStmt(data[3])
		end)

		self.registered_events[name][self.include or "__main__"] = function(state, args) ---@param state RuntimeContext
			local save = state:SaveScopes()

			local scope = { vclk = {} } -- Hack in the fact that functions don't have upvalues right now.
			state.Scopes = { [0] = state.GlobalScope, [1] = scope }
			state.Scope = scope
			state.ScopeID = 1

			for i, param in ipairs(params) do
				state.Scope[param[1]] = args[i]
			end

			block(state)

			state:LoadScopes(save)
		end

		return nil
	end
}

---@alias TypeSignature string

---@param variant string
---@param types TypeSignature[]
---@param trace Trace
---@return RuntimeOperator fn
---@return TypeSignature signature
---@return boolean legacy
function Compiler:GetOperator(variant, types, trace)
	local fn = wire_expression2_funcs["op:" .. variant .. "(" .. table.concat(types) .. ")"]
	if fn then
		self.scope.data.ops = self.scope.data.ops + (fn[4] or 3)
		return fn[3], fn[2], fn.attributes.legacy
	end

	self:Error("No such operator: " .. variant .. " (" .. table.concat(types, ", ") .. ")", trace)
end

---@param name string
---@param types TypeSignature[]
---@param method? string
---@return EnvFunction? function
---@return boolean? variadic
function Compiler:GetUserFunction(name, types, method)
	---@type EnvFunction
	local overloads
	if method then
		overloads = self.user_methods[method]
		if not overloads then return end
		overloads = overloads[name]
	else
		overloads = self.user_functions[name]
	end
	if not overloads then return end

	local param_sig = table.concat(types)
	if overloads[param_sig] then return overloads[param_sig], false end

	for i = #types, 0, -1 do
		local sig = table.concat(types, "", 1, i)

		local fn = overloads[sig .. "..r"]
		if fn then
			for j = i, #types do
				if BLOCKED_ARRAY_TYPES[types[j]] then
					self:Error("Cannot call variadic array function (" .. name .. ") with a " .. tostring(types[j]) .. " value.", trace)
				end
			end
			return fn, true
		end

		fn = overloads[sig .. "..t"]
		if fn then return fn, true end
	end
end

---@param name string
---@param types TypeSignature[]
---@param method? string
---@return EnvFunction?
---@return boolean? variadic
---@return boolean? userfunction
function Compiler:GetFunction(name, types, method)
	local sig, method_prefix = table.concat(types), method and (method .. ":") or ""

	local fn = wire_expression2_funcs[name .. "(" .. method_prefix .. sig .. ")"]
	if fn then return { op = fn[3], returns = { fn[2] }, args = types, cost = fn[4], attrs = fn.attributes }, false, false end

	local fn, variadic = self:GetUserFunction(name, types, method)
	if fn then return fn, variadic, true end

	for i = #sig, 0, -1 do
		fn = wire_expression2_funcs[name .. "(" .. method_prefix .. sig:sub(1, i) .. "...)"]
		if fn then return { op = fn[3], returns = { fn[2] }, args = types, cost = fn[4], attrs = fn.attributes }, true, false end
	end
end

---@param node Node
---@return RuntimeOperator
---@return string? expr_type
function Compiler:CompileExpr(node)
	if not node.trace then
		error("Incomplete node: " .. tostring(node), 2)
	end

	local op, ty = assert(CompileVisitors[node.variant], "Unimplemented Compile Step: " .. node:instr())(self, node.trace, node.data)
	self:Assert(ty, "Cannot use void in expression position", node.trace)
	return op, ty
end

---@return RuntimeOperator
function Compiler:CompileStmt(node)
	if not node.trace then
		error("Incomplete node: " .. tostring(node), 2)
	end

	return assert(CompileVisitors[node.variant], "Unimplemented Compile Step: " .. node:instr())(self, node.trace, node.data)
end

---@param ast Node
---@return RuntimeOperator
function Compiler:Process(ast)
	for var, type in pairs(self.persist) do
		self.scope:DeclVar(var, { initialized = false, type = type })
	end

	for var, type in pairs(self.inputs) do
		self.scope:DeclVar(var, { initialized = true, type = type })
	end

	for var, type in pairs(self.outputs) do
		self.scope:DeclVar(var, { initialized = false, type = type })
	end

	return self:CompileStmt(ast)
end