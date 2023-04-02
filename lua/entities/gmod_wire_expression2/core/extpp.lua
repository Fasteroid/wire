AddCSLuaFile()

local p_typename = "%l[%l%d]*"
local p_typeid = "%l[%l%d]?[%l%d]?"
local p_argname = "%a[%w_]*"
local p_funcname = "%l[%w_]*"
local p_func_operator = "[%-%+%*%%%/%^%=%!%>%<%&%|%$%[%]%w_]*"

local Operators = {
	["operator+"] = "add", ["operator-"] = "sub",
	["operator*"] = "mul", ["operator/"] = "div",
	["operator%"] = "mod", ["operator^"] = "exp",
	["operator=="] = "eq", ["operator>"] = "gth",
	["operator>="] = "geq", ["operator<"] = "lth",
	["operator<="] = "leq", ["operator_is"] = "is",
	["operator_neg"] = "neg",
	["operator_band"] = "band", ["operator_bor"] = "bor",
	["operator_bxor"] = "bxor", ["operator_bshl"] = "bshl",
	["operator_bshr"] = "bshr",
}

local RemovedOperators = {
	["operator!"] = true, ["operator!="] = true, -- These now use operator_is and operator== internally
	["operator&"] = true, ["operator&&"] = true, -- Despite && being binary AND in E2, the preprocessor used to handle this as logical AND.
	["operator|"] = true, ["operator||"] = true, -- Despite || being binary OR in E2, the preprocessor used to handle this as logical OR.
}

local ValidAttributes = { -- Expose to E2Lib?
	["deprecated"] = true,
	["nodiscard"] = true,
	["noreturn"] = true
}

E2Lib.ExtPP = {}

---@type table<string, string>
local preparsed_types

function E2Lib.ExtPP.Init()
	-- The 'n' type is actually 'normal'. Make an alias for number -> normal
	preparsed_types = { ["NUMBER"] = "n" }
end

function E2Lib.ExtPP.Pass1(contents)
	-- look for registerType lines and fill preparsed_types with them
	for typename, typeid in string.gmatch("\n" .. contents, '%WregisterType%(%s*"(' .. p_typename .. ')"%s*,%s*"(' .. p_typeid .. ')"') do
		preparsed_types[string.upper(typename)] = typeid
	end
end

-- This function checks whether its argument is a valid type id.
local function isValidTypeId(typeid)
	return (typeid:match("^[a-wy-zA-WY-Z]$") or typeid:match("^[xX][a-wy-zA-WY-Z0-9][a-wy-zA-WY-Z0-9]$")) and true
end

-- Returns the typeid associated with the given typename
---@return string?
local function getTypeId(ty)
	local upper = ty:upper()

	return (wire_expression_types[upper] and wire_expression_types[upper][1]) -- Already registered.
		or preparsed_types[upper]    -- Preparsed from registerType
		or (isValidTypeId(ty) and ty) -- It is a type id. Weird.
end

---@enum ArgsKind
local ArgsKind = {
	Static = 1,
	Variadic = 2,
	VariadicTbl = 3
}

-- Parses list of parameters
---@param raw string
---@param trace string
---@return { [1]: string, [2]: string }[], ArgsKind, string?
local function parseParameters(raw, trace)
	if not raw:match("%S") then return {}, ArgsKind.Static end

	local parsed, split = {}, raw:Split(",")
	local len = #split

	for k, raw_param in ipairs(split) do
		local name = raw_param:match("^%s*%.%.%.(%w+)%s*$")
		if name then -- Variadic table parameter
			assert(k == len, "PP syntax error: Ellipses table (..." .. name .. ") must be the last argument.")
			return parsed, ArgsKind.VariadicTbl, name
		elseif raw_param:match("^%s*%.%.%.%s*$") then -- Variadic lua parameter
			assert(k == len, "PP syntax error: Ellipses (...) must be the last argument.")
			return parsed, ArgsKind.Variadic
		else
			local typename, argname = string.match(raw_param, "^%s*(" .. p_typename .. ")%s+(" .. p_argname .. ")%s*$")
			if not typename then -- Implicit 'number' type
				argname, typename = string.match(raw_param, "^%s*(" .. p_argname .. ")%s*$"), "number"
			end

			parsed[k] = {
				assert(argname, "PP syntax error: Invalid function parameter syntax. " .. trace),
				assert(getTypeId(typename), "PP syntax error: Invalid parameter type '" .. typename .. "' for argument '" .. argname .. "'." .. trace)
			}
		end
	end

	return parsed, ArgsKind.Static
end

---@param attributes string
---@param trace string
---@return table<string, string>?
local function parseAttributes(attributes, trace)
	-- Parse attributes in order to pass to registerFunction/registerOperator
	if attributes ~= "" and attributes:sub(1, 1) == "[" and attributes:sub(-1, -1) == "]" then
		local attrs = { legacy = "false" } -- extpp can generate functions abiding by the new compiler.
		for _, tag in ipairs(attributes:sub(2, -2):Split(",")) do
			local k = tag:lower():Trim()

			if k:find("=", 1, true) then
				-- [xyz = 567, event = "Tick"]
				-- e2function number foo()
				local key, value = unpack(k:Split("="), 1, 2)
				attrs[key:lower():Trim()] = value:Trim()
			elseif not ValidAttributes[k] then
				ErrorNoHalt("Invalid attribute fed to ExtPP: " .. k .. " " .. trace .. "\n")
			else
				attrs[tag:lower():Trim()] = "true"
			end
		end

		return attrs
	end
end

--- Compact lua code to a single line to avoid changing lua's tracebacks.
local function compact(lua)
	return (lua:gsub("\n\t*", " "):Trim())
end

---@param contents string
---@param filename string
function E2Lib.ExtPP.Pass2(contents, filename)
	-- We add some stuff to both ends of the string so we can look for %W (non-word characters) at the ends of the patterns.
	local prelude = "local tempcosts, registeredfunctions = {}, {};"
	contents = ("\n" .. prelude .. contents .. "\n     ")

	-- this is a list of pieces that make up the final code
	local output = {}
	-- this is a list of registerFunction lines that will be put at the end of the file.
	local footer = {}
	-- We start from position 2, since char #1 is always the \n we added earlier
	local lastpos = 2

	local aliaspos, aliasdata = nil, nil

	-- This flag helps determine whether the preprocessor changed, so we can tell the environment about it.
	local changed = false
	for a_begin, attributes, h_begin, ret, thistype, colon, name, args, whitespace, equals, h_end in contents:gmatch("()(%[?[%w,_ =\"]*%]?)[\r\n\t ]*()e2function%s+(" .. p_typename .. ")%s+([a-z0-9]-)%s*(:?)%s*(" .. p_func_operator .. ")%(([^)]*)%)(%s*)(=?)()") do
		local line = select(2, contents:sub(1, h_begin):gsub("\n", ""))
		local trace = "(at line " .. line .. ")"
		local trace_ext = trace .. (E2Lib.currentextension and (" @" .. filename) or "")

		if contents:sub(h_begin - 1, h_begin - 1):match("%w") then
			ErrorNoHalt("Warning: Malformed e2function must not have characters before 'e2function' " .. trace_ext .. "\n")
		elseif RemovedOperators[name] then -- Old operator that no longer is needed.
			ErrorNoHalt("Warning: Operator " .. name .. " is now redundant. Ignoring registration. " .. trace_ext .. "\n")
		elseif not name:find("^" .. p_funcname .. "$") and not Operators[name] then
			error("PP syntax error: Invalid function name format " .. trace)
		elseif thistype ~= "" and colon == "" then
			error("PP syntax error: Function names may not start with a number. " .. trace)
		elseif thistype == "" and colon ~= "" then
			error("PP syntax error: No type for 'this' given." .. trace)
		elseif thistype ~= "" and not getTypeId(thistype) then
			error("PP syntax error: Invalid type for 'this': '" .. thistype .. "' " .. trace)
		elseif thistype:match("^%d") then
			error("PP syntax error: Type names may not start with a number." .. trace)
		elseif equals ~= "" and aliaspos then
			error("PP syntax error: Malformed alias definition. " .. trace)
		elseif ret ~= "void" and not getTypeId(ret) then
			error("PP syntax error: Invalid return type: '" .. ret .. "' " .. trace)
		else
			changed = true -- Mark as changed

			local aliasflag
			if equals == "" and aliaspos then -- Alias right hand side
				assert(not contents:sub(aliaspos, h_begin - 1):find("%S"), "PP syntax error: Malformed alias definition. " .. trace)
				aliasflag, aliaspos = 2, nil
			elseif equals ~= "" then -- Left hand side of alias
				aliasflag = 1
				aliaspos = h_end
			end

			local is_operator = false
			if Operators[name] then
				name, is_operator = Operators[name], true
			end

			local params, kind, vartbl_name = parseParameters(args, trace)

			local attributes = parseAttributes(attributes, trace)

			local attr_str
			if attributes then
				if kind == ArgsKind.Static then
					attributes.legacy = "false"
				end

				attr_str = "{"
				for k, v in pairs(attributes) do
					attr_str = attr_str .. k .. "=" .. v .. ","
				end
				attr_str = attr_str .. "}"

				table.insert(output, contents:sub(lastpos, a_begin - 1))
				table.insert(output, "-- attributes: " .. attr_str .. " \n") -- Add line for annotations
			else
				attr_str = kind ~= ArgsKind.Static and "{}" or "{ legacy = false }"
				table.insert(output, contents:sub(lastpos, h_begin - 1)) -- Append stuff in between functions
			end

			lastpos = h_end -- Advance to end of function header

			if thistype ~= "" then -- prepend a "this" argument to the list, with the parsed type
				if is_operator then -- allow pseudo-member-operators. example: e2function matrix:operator*(factor)
					table.insert(params, 1, {"this", getTypeId(thistype)})
				else
					table.insert(params, 1, {"this", getTypeId(thistype) .. ":"})
				end
			end

			local sig = {}
			for i, param in ipairs(params) do
				sig[i] = param[2]
			end

			local param_sig = table.concat(sig)
			local ret_typeid = getTypeId(ret) or ""

			local mangled = "e2_" .. (is_operator and ("operator_" .. name) or name) .. "_" .. param_sig:gsub("[:=]", "_")

			local param_names, param_names_quot = {}, {}
			for i, param in ipairs(params) do
				param_names[i], param_names_quot[i] = param[1], '"' .. param[1] .. '"'
			end

			if aliasflag == 1 then
				aliasdata = { is_operator, name, param_sig, ret_typeid, attributes }
			elseif aliasflag == 2 then
				local is_operator, name, param_sig, ret_typeid, attributes = aliasdata[1], aliasdata[2], aliasdata[3], aliasdata[4], aliasdata[5]
				table.insert(footer, compact([[
						if registeredfunctions.]] .. mangled .. [[ then
							]] .. (is_operator and "registerOperator" or "registerFunction") .. [[(
								"]] .. name .. [[",
								"]] .. param_sig .. [[",
								"]] .. ret_typeid .. [[",
								registeredfunctions.]] .. mangled .. [[,
								tempcosts.]] .. mangled .. [[,
								]] .. "{" .. table.concat(param_names_quot, ",", thistype ~= "" and 2 or 1) .. "}" .. [[,
								]] .. attr_str .. [[
							)
						end
					]]))
			else
				table.insert(output, compact([[
					tempcosts.]] .. mangled .. [[ = __e2getcost()
				]]))

				if kind == ArgsKind.Static then
					table.insert(footer, compact([[
						if registeredfunctions.]] .. mangled .. [[ then
							]] .. (is_operator and "registerOperator" or "registerFunction") .. [[(
								"]] .. name .. [[",
								"]] .. param_sig .. [[",
								"]] .. ret_typeid .. [[",
								registeredfunctions.]] .. mangled .. [[,
								tempcosts.]] .. mangled .. [[,
								]] .. "{" .. table.concat(param_names_quot, ",", thistype ~= "" and 2 or 1) .. "}" .. [[,
								]] .. attr_str .. [[
							)
						end
					]]))


					local param_get = {}
					for i = 1, #param_names do
						param_get[i] = "args[" .. i .. "]"
					end

					if #param_names == 0 then
						table.insert(output, compact([[
							function registeredfunctions.]] .. mangled .. [[(self, args, types)
						]]))
					else
						table.insert(output, compact([[
							function registeredfunctions.]] .. mangled .. [[(self, args, types)
								local ]] .. table.concat(param_names, ", ") .. [[ = ]] .. table.concat(param_get, ",") .. [[
						]]))
					end
				elseif kind == ArgsKind.VariadicTbl then
					table.insert(footer, compact([[
						if registeredfunctions.]] .. mangled .. [[ then
							]] .. (is_operator and "registerOperator" or "registerFunction") .. [[(
								"]] .. name .. [[",
								"]] .. (param_sig .. "...") .. [[",
								"]] .. ret_typeid .. [[",
								registeredfunctions.]] .. mangled .. [[,
								tempcosts.]] .. mangled .. [[,
								]] .. "{" .. table.concat(param_names_quot, ",", thistype ~= "" and 2 or 1) .. "}" .. [[,
								]] .. attr_str .. [[
							)
						end
					]]))

					-- Using __varargs_priv to avoid shadowing variables like `args` and breaking this implementation.
					table.insert(output, compact([[
						function registeredfunctions.]] .. mangled .. [[(self, args, typeids, __varargs_priv)
							if not typeids then
								__varargs_priv, typeids = {}, {}
								local source_typeids, tmp = args[#args]
								for i = ]] .. 2 + #params .. [[, #args - 1 do
									tmp = args[i]
									__varargs_priv[i - ]] .. 1 + #params .. [[] = tmp[1](self, tmp)
									typeids[i - ]] .. 1 + #params .. [[] = source_typeids[i - ]] .. (thistype ~= "" and 2 or 1) .. [[]
								end
							end

							]] .. ("local " .. vartbl_name .. " = __varargs_priv") .. [[
					]]))
				elseif kind == ArgsKind.Variadic then
					ErrorNoHalt("Warning: Use of variadic parameter with ExtPP is not recommended and deprecated. Instead use ...<name> which passes a table " .. trace_ext .. "\n")

					table.insert(footer, compact([[
						if registeredfunctions.]] .. mangled .. [[ then
							]] .. (is_operator and "registerOperator" or "registerFunction") .. [[(
								"]] .. name .. [[",
								"]] .. (param_sig .. "...") .. [[",
								"]] .. ret_typeid .. [[",
								registeredfunctions.]] .. mangled .. [[,
								tempcosts.]] .. mangled .. [[,
								]] .. "{" .. table.concat(param_names_quot, ",", thistype ~= "" and 2 or 1) .. "}" .. [[,
								]] .. attr_str .. [[
							)
						end
					]]))

					table.insert(output, compact([[
						function registeredfunctions.]] .. mangled .. [[(self, args, typeids, ...)
							if not typeids then
								local arr, typeids, source_typeids, tmp = {}, {}, args[#args]
								for i = ]] .. 2 + #params .. [[, #args - 1 do
									tmp = args[i]

									arr[i - ]] .. 1 + #params .. [[] = tmp[1](self, tmp)
									typeids[i - ]] .. 1 + #params .. [[] = source_typeids[i - ]] .. (thistype ~= "" and 2 or 1) .. [[]
								end
								return registeredfunctions.]] .. mangled .. [[(self, args, typeids, unpack(arr))
							end
					]]))
				else
					error("wtf")
				end
			end

			table.insert(output, whitespace)
		end
	end -- for contents:gmatch(e2function)

	-- did the preprocessor change anything?
	if changed then
		-- yes => sweep everything together into a neat pile of hopefully valid lua code
		return table.concat(output) .. contents:sub(lastpos, -6) .. table.concat(footer, "\n")
	else
		-- no => tell the environment about it, so it can include() the source file instead.
		return false
	end
end
